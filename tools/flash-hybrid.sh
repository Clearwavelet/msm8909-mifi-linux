#!/usr/bin/env bash
# 混合镜像：彩排 + 烧写 boot 分区
#
# 安全设计（重要）：
#   boot-hybrid.img 的 ramdisk 里保留了原厂 /init.real，init 里任何一步失败
#   都会 exec /init.real 回到 Android，不会断电、不会变砖。
#   所以烧写前必须先证明"兜底分支"真的能回到 Android —— 脚本第 2 步就是干这个。
#
# 流程：
#   [1] 等 Android + 校验 boot 分区备份
#   [2] 放 .boot-android 标志 -> fastboot boot -> 应回到 Android（验证兜底）
#   [3] 删标志 -> fastboot flash boot -> 重启
#   [4] 判定：出现 RNDIS 网卡 = 原生 Alpine 成功；adb 回来 = 兜底生效
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ADBP="${ADB_DIR:-$(dirname "$(command -v adb 2>/dev/null || echo /usr/bin/adb)")}"
export MSYS_NO_PATHCONV=1
export PATH="$PATH:$ADBP"

adbs() { adb devices 2>/dev/null | tr -d '\r' | grep -v "List of" | grep -v '^$'; }
# RNDIS 网卡数：返回整数，异常一律返回 -1（避免误判为 1 或 0）
rndis() {
    local v
    v=$(powershell -NoProfile -Command "[Console]::WriteLine((@(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { \$_.InterfaceDescription -like '*NDIS*' })).Count)" 2>/dev/null | tr -d '\r\n ')
    case "$v" in ''|*[!0-9]*) echo -1 ;; *) echo "$v" ;; esac
}
wait_adb() {  # $1 = 最多等多少秒
    local n=$(( $1 / 3 ))
    for i in $(seq 1 $n); do
        [ -n "$(adbs)" ] && { echo "    +$((i*3))s adb 已就绪"; return 0; }
        sleep 3
    done
    return 1
}

echo "=== [1] 等待设备进入 Android ==="
if ! wait_adb 60; then
    echo "!! 设备未就绪。请拔掉 USB 等 3 秒插回，再重跑本脚本"
    exit 1
fi

echo "=== [1b] 校验 boot 分区备份完整性 ==="
adb exec-out "dd if=/dev/block/bootdevice/by-name/boot 2>/dev/null" > /tmp/boot_now.img 2>/dev/null
sz_now=$(stat -c %s /tmp/boot_now.img 2>/dev/null || echo 0)
sz_bak=$(stat -c %s "$HERE/boot-backup.img" 2>/dev/null || echo 0)
echo "    当前分区 ${sz_now}B   备份 ${sz_bak}B"
if [ "$sz_now" != "$sz_bak" ] || [ "$sz_bak" = "0" ]; then
    echo "!! 备份尺寸不符，拒绝继续（备份是唯一的救砖材料）"
    exit 1
fi
md5n=$(md5sum /tmp/boot_now.img | cut -d' ' -f1)
md5b=$(md5sum "$HERE/boot-backup.img" | cut -d' ' -f1)
echo "    当前 ${md5n}"
echo "    备份 ${md5b}"
if [ "$md5n" != "$md5b" ]; then
    echo "!! boot 分区内容与备份不一致，拒绝继续"
    exit 1
fi
echo "    OK：备份与原分区逐字节一致"

echo
echo "=== [1c] 部署 Alpine 侧文件 ==="
DEV="$(cd "$HERE/.." && pwd)"
cd "$DEV" || exit 1
adb push vendor/busybox-static /data/local/tmp/busybox >/dev/null 2>&1
adb shell "chmod 755 /data/local/tmp/busybox" >/dev/null 2>&1
fail=0
for f in boot-native.sh udhcpd.conf sshd_config resolv.conf authorized_keys inittab; do
    if adb push "device/$f" "/data/local/tmp/$f" 2>&1 | grep -qi "error\|failed"; then
        echo "  !! push 失败: $f"; fail=1
    fi
done
[ "$fail" = "1" ] && { echo "!! 部署中止"; exit 1; }
adb shell '
B=/data/local/tmp/busybox
A=/cache/alpine
$B mkdir -p $A/root/.ssh $A/var/lib/misc $A/run $A/var/log
$B cp /data/local/tmp/boot-native.sh  $A/boot-native.sh; $B chmod 755 $A/boot-native.sh
$B cp /data/local/tmp/udhcpd.conf     $A/etc/udhcpd.conf
$B cp /data/local/tmp/sshd_config     $A/etc/ssh/sshd_config
$B cp /data/local/tmp/resolv.conf     $A/etc/resolv.conf
$B cp /data/local/tmp/authorized_keys $A/root/.ssh/authorized_keys; $B chmod 600 $A/root/.ssh/authorized_keys
$B cp /data/local/tmp/inittab         $A/etc/inittab
$B rm -f $A/boot.count /cache/boot.count /cache/.boot-android
echo "计数文件: [$($B cat /cache/boot.count 2>/dev/null)]"
echo "boot-native 清零点: $($B grep -c "boot.count" $A/boot-native.sh)"
echo "inittab:"; $B cat $A/etc/inittab
' 2>&1 | tr -d '\r' | sed 's/^/    /'

echo
echo "=== [2] 彩排：验证兜底能回 Android ==="
IMG=../images/boot-hybrid-v13.img
adb shell "touch /cache/.boot-android && ls -l /cache/.boot-android" 2>&1 | tr -d '\r'
adb reboot bootloader >/dev/null 2>&1
sleep 14
adb kill-server >/dev/null 2>&1
( cd "$HERE" && python fb.py boot "$IMG" 2>&1 | tail -3 | sed 's/^/      /' )
echo "    等待结果（兜底生效=adb 回来；若进了 Alpine 则会出现 RNDIS 网卡）..."
rehearsal=""
for i in $(seq 1 34); do
    sleep 3
    if [ -n "$(adbs)" ]; then
        rehearsal=android
        echo "    +$((i*3))s adb 回来"
        break
    fi
    n=$(rndis)
    if [ "$n" -ge 1 ] 2>/dev/null; then
        rehearsal=alpine
        echo "    +$((i*3))s 出现 RNDIS 网卡"
        break
    fi
done
case "$rehearsal" in
    android) echo "    ==> 兜底分支验证通过：混合镜像会自动退回 Android" ;;
    alpine)  echo "!! 标志文件没生效，它进了 Alpine。停止，不烧写。" ; exit 2 ;;
    *)       echo "!! 100s 内既无 adb 也无 RNDIS。停止，不烧写。请拔插后读 splash 日志" ; exit 2 ;;
esac

echo
echo "=== [3] 烧写 boot 分区 ==="
adb shell "rm -f /cache/.boot-android; ls /cache/.boot-android 2>/dev/null || echo 标志已删除" 2>&1 | tr -d '\r'
adb reboot bootloader >/dev/null 2>&1
sleep 14
adb kill-server >/dev/null 2>&1
( cd "$HERE" && python fb.py flash boot "$IMG" 2>&1 | tail -4 | sed 's/^/      /' )
echo "    烧写完成，重启设备..."
( cd "$HERE" && python fb.py reboot 2>&1 | tail -2 | sed 's/^/      /' )

echo
echo "=== [4] 判定（最多 180 秒）==="
for i in $(seq 1 60); do
    sleep 3
    if [ -n "$(adbs)" ]; then
        echo "  !! +$((i*3))s adb 回来 -> 兜底生效，设备在 Android（未变砖）"
        exit 3
    fi
    n=$(rndis)
    if [ "$n" -ge 1 ] 2>/dev/null; then
        echo "  ==> +$((i*3))s RNDIS 网卡出现 -> 原生 Alpine 启动成功"
        sleep 10
        exit 0
    fi
done
echo "  !! 180s 内既无 RNDIS 也无 adb，请拔插后读 splash"
exit 4
