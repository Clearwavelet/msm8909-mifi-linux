#!/usr/bin/env bash
# 冷启动验证：设备上电后检查 1) 原生 Alpine 起来了 2) /cache 自动挂到 cache 分区根 3) 计数清零
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
export MSYS_NO_PATHCONV=1
# adb 位置：优先用 ADB_DIR，否则取 PATH 里的 adb
_d=""; if [ -n "${ADB_DIR:-}" ]; then _d="$ADB_DIR"; elif command -v adb >/dev/null 2>&1; then _d="$(dirname "$(command -v adb)")"; fi
[ -n "$_d" ] && export PATH="$PATH:$_d"
KEY="${DEV_KEY:-$HOME/.ssh/xj19_ed25519}"
KEY="$(cygpath -w "$KEY" 2>/dev/null || echo "$KEY")"
SSH="ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=6 -o BatchMode=yes"

adbs() { adb devices 2>/dev/null | tr -d '\r' | grep -v "List of" | grep -v '^$'; }
rndis() {
    local v
    v=$(powershell -NoProfile -Command "[Console]::WriteLine((@(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { \$_.InterfaceDescription -like '*NDIS*' })).Count)" 2>/dev/null | tr -d '\r\n ')
    case "$v" in ''|*[!0-9]*) echo -1 ;; *) echo "$v" ;; esac
}

echo "=== 阶段 A：等待拔出 USB（最多 180s）==="
gone=0
for i in $(seq 1 45); do
    if ! $SSH -o ConnectTimeout=4 root@192.168.42.129 true 2>/dev/null; then
        n=$(rndis)
        if [ "$n" = "0" ]; then gone=1; echo "  +$((i*4))s 已拔出（RNDIS 消失）"; break; fi
    fi
    sleep 4
done
[ "$gone" = "1" ] || echo "  (未检测到拔出，继续等上电判断)"

echo "=== 阶段 B：等待上电（最多 480s）==="
res=""
for i in $(seq 1 80); do
    n=$(rndis)
    if [ "$n" -ge 1 ] 2>/dev/null; then res=alpine; echo "  +$((i*4))s RNDIS 出现"; break; fi
    if [ -n "$(adbs)" ]; then res=android; echo "  +$((i*4))s adb 回来"; break; fi
    sleep 4
done

if [ "$res" != "alpine" ]; then
    echo "!! 结果=$res（空=无反应；android=兜底生效）"
    exit 1
fi

echo "=== SSH 验证冷启动状态 ==="
for t in $(seq 1 15); do
    out=$($SSH root@192.168.42.129 '
        echo "uptime=$(cat /proc/uptime | cut -d" " -f1)"
        echo "kernel=$(uname -r)"
        echo "alpine=$(cat /etc/alpine-release)"
        echo "pid1=$(cat /proc/1/comm)"
        if [ -d /cache/alpine ]; then echo "cache_mount=OK"; else echo "cache_mount=FAIL"; fi
        echo "cachedir=$(ls /cache 2>/dev/null | tr "\n" " ")"
        echo "bootcount=$(cat /cache/boot.count 2>/dev/null)"
        echo "usbnet=$(cat /cache/usbnet.name 2>/dev/null)"
        echo "sshd=$(pidof sshd 2>/dev/null)"
        echo "udhcpd=$(pidof udhcpd 2>/dev/null)"
    ' 2>/dev/null)
    case "$out" in
        *kernel=3.10*) echo "$out" | sed 's/^/    /'; break ;;
        *) sleep 5 ;;
    esac
done

echo
upt=$(echo "$out" | sed -n 's/^uptime=\([0-9]*\).*/\1/p' | cut -d. -f1)
if [ -n "${upt:-}" ] && [ "$upt" -lt 300 ] 2>/dev/null; then
    echo "    本次是全新启动（uptime=${upt}s）"
    fresh=1
else
    echo "!! uptime=${upt:-未知}s，可能没真正断电重启，结论不可信"
    fresh=0
fi

echo
if echo "$out" | grep -q "cache_mount=OK" && [ "$fresh" = "1" ]; then
    echo "==> 冷启动验证通过：/cache 自动挂到 cache 分区根，安全网与回 Android 标志均可用"
elif echo "$out" | grep -q "cache_mount=OK"; then
    echo "==> /cache 挂载正常，但本次不是冷启动，建议再拔插一次复验"
else
    echo "!! /cache 未挂载 —— boot-native.sh 的挂载步骤没生效，需检查 /var/log/native-net.log"
fi
