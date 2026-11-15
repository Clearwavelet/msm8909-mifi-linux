#!/usr/bin/env bash
# 把设备侧配置文件推上去（幂等，可反复跑）
#   用法: ./deploy-native.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/alpine/native"
KEY="$(cygpath -w "$HERE/alpine/id_alpine" 2>/dev/null || echo "$HERE/alpine/id_alpine")"
IP="${DEV_IP:-192.168.42.129}"
export MSYS_NO_PATHCONV=1

SSHO="-i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o BatchMode=yes"

put() { # put <本地文件> <远端路径> <权限>
    # 传输时统一剥掉 CR。
    # 本仓库在 Windows 上编辑，编辑器/工具会间歇性写出 CRLF；脚本带上 CR 传到设备后
    # `#!/bin/sh\r` 会让内核找不到解释器，报一个极具误导性的 "not found"（文件明明在、
    # 权限也对）。在这里一次性挡掉，比每次手工 dos2unix 靠谱。
    if tr -d '\r' < "$1" | ssh $SSHO root@"$IP" "cat > '$2'"; then
        ssh $SSHO root@"$IP" "chmod $3 '$2'" >/dev/null 2>&1
        echo "  ✓ $2  ($(wc -c < "$1") 字节, mode $3)"
    else
        echo "  ✗ $2 失败"; return 1
    fi
}

echo "=== 部署到 $IP ==="
ssh $SSHO root@"$IP" 'mkdir -p /etc/profile.d /usr/local/bin /usr/local/sbin /etc/unbound /etc/proxychains /etc/wpa_supplicant /lib/modules /var/run' 2>/dev/null || { echo "设备不可达"; exit 1; }

put "$SRC/boot-native.sh"      /boot-native.sh                 755
put "$SRC/net-mode.sh"         /usr/local/sbin/net-mode.sh    755
put "$SRC/inittab"             /etc/inittab                   644
put "$SRC/udhcpd.conf"         /etc/udhcpd.conf               644
put "$SRC/sshd_config"         /etc/ssh/sshd_config           600
# 注意：故意不推 resolv.conf。
# 它由 udhcpc（WiFi 连上后）和 wifi-connect.sh 动态写，内容随热点而变（网关地址）。
# 早期推过，结果每次部署都把 DNS 打回隧道时代的 "nameserver 127.0.0.1"，
# 而 WiFi 模式下 unbound 是被跳过的 —— 表现为 apk 报 "DNS: transient error"。
# 需要手工修 DNS 时用 `wifi-tui.sh` 或直接改设备上的文件，别从这里推。
put "$SRC/fstab"               /etc/fstab                     644
put "$SRC/profile-proxy.sh"    /etc/profile.d/50-proxy.sh     644
put "$SRC/unbound.conf"        /etc/unbound/unbound.conf      644
put "$SRC/proxychains.conf"    /etc/proxychains/proxychains.conf 644
put "$SRC/wifi-up.sh"          /wifi-up.sh                    755
put "$SRC/wifi-connect.sh"     /usr/local/sbin/wifi-connect.sh 755
put "$SRC/wifi-tui.sh"         /usr/local/sbin/wifi-tui.sh    755
put "$SRC/wpa_supplicant.conf" /etc/wpa_supplicant/wpa_supplicant.conf 600
put "$SRC/net-up.sh"           /usr/local/bin/net-up.sh       755
put "$SRC/README-device.txt"   /root/README.txt               644
if [ -f "$SRC/authorized_keys" ]; then
    ssh $SSHO root@"$IP" 'mkdir -p /root/.ssh && chmod 700 /root/.ssh' 2>/dev/null
    put "$SRC/authorized_keys" /root/.ssh/authorized_keys          600
fi

echo
echo "=== 设备侧自检 ==="
ssh $SSHO root@"$IP" '
echo "fstab:"; grep -c . /etc/fstab
[ -x /boot-native.sh ] && echo "boot-native.sh: 可执行"
grep -q 50-proxy /etc/profile.d/50-proxy.sh 2>/dev/null || echo "proxy profile: 已就位"
' 2>&1
