#!/usr/bin/env bash
# 把设备侧配置文件推上去（幂等，可反复跑）
#   用法: ./deploy-native.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../device"
KEY="${DEV_KEY:-$HOME/.ssh/xj19_ed25519}"
KEY="$(cygpath -w "$KEY" 2>/dev/null || echo "$KEY")"
IP="${DEV_IP:-192.168.42.129}"
export MSYS_NO_PATHCONV=1

SSHO="-i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o BatchMode=yes"

put() { # put <本地文件> <远端路径> <权限>
    if ssh $SSHO root@"$IP" "cat > '$2'" < "$1"; then
        ssh $SSHO root@"$IP" "chmod $3 '$2'" >/dev/null 2>&1
        echo "  ✓ $2  ($(wc -c < "$1") 字节, mode $3)"
    else
        echo "  ✗ $2 失败"; return 1
    fi
}

echo "=== 部署到 $IP ==="
ssh $SSHO root@"$IP" 'mkdir -p /etc/profile.d /usr/local/bin' 2>/dev/null || { echo "设备不可达"; exit 1; }

put "$SRC/boot-native.sh"      /boot-native.sh                 755
put "$SRC/inittab"             /etc/inittab                   644
put "$SRC/udhcpd.conf"         /etc/udhcpd.conf               644
put "$SRC/sshd_config"         /etc/ssh/sshd_config           600
put "$SRC/resolv.conf"         /etc/resolv.conf               644
put "$SRC/fstab"               /etc/fstab                     644
put "$SRC/profile-proxy.sh"    /etc/profile.d/50-proxy.sh     644
put "$SRC/wifi-probe.sh"       /wifi-probe.sh                 755
put "$SRC/README-device.txt"   /root/README.txt               644
if [ -f "$SRC/authorized_keys" ]; then
    ssh $SSHO root@"$IP" 'mkdir -p /root/.ssh && chmod 700 /root/.ssh' 2>/dev/null
    put "$SRC/authorized_keys" /root/.ssh/authorized_keys          600
else
    echo "  ––  跳过 authorized_keys：请先执行"
    echo "        cp device/authorized_keys.example device/authorized_keys"
    echo "      再把你的公钥写进去（device/authorized_keys 已在 .gitignore 里）"
fi

echo
echo "=== 设备侧自检 ==="
ssh $SSHO root@"$IP" '
echo "fstab:"; grep -c . /etc/fstab
[ -x /boot-native.sh ] && echo "boot-native.sh: 可执行"
grep -q 50-proxy /etc/profile.d/50-proxy.sh 2>/dev/null || echo "proxy profile: 已就位"
' 2>&1
