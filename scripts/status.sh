#!/usr/bin/env bash
# 一页体检报告：这台无屏无键的机器，随时想知道"它还正常吗"就跑这个
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
KEY="$(cygpath -w "$HERE/alpine/id_alpine" 2>/dev/null || echo "$HERE/alpine/id_alpine")"
IP="${DEV_IP:-192.168.42.129}"
export MSYS_NO_PATHCONV=1

ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=8 -o BatchMode=yes root@"$IP" '
up=$(cut -d" " -f1 /proc/uptime | cut -d. -f1)
yr=$(date +%Y)
printf "%-14s %s\n" "内核"      "$(uname -r)  ($(nproc) 核)"
printf "%-14s %s\n" "发行版"    "$(cat /etc/alpine-release) / $(cat /proc/1/comm) PID1"
printf "%-14s %s   [已连续运行 %dh%02dm]\n" "时间" "$(date "+%F %T %Z")" $((up/3600)) $((up%3600/60))
[ "$yr" -lt 2020 ] && printf "%-14s %s\n" "" "⚠ 时间是 1970，说明没校过时（用 dev.sh 连一次即可）"

echo
printf "%-14s %s\n" "挂载" "$(grep -q " /cache " /proc/mounts && echo -n "cache✓ " || echo -n "cache✗ ")$(grep -q " /data " /proc/mounts && echo -n "data✓ " || echo -n "data✗ ")$(grep -q " /home " /proc/mounts && echo -n "home✓ " || echo -n "home✗ ")"
printf "%-14s %s\n" "根分区" "$(df -h / | tail -1 | awk "{print \$3\" / \"\$2\" (\"\$5\")\"}")"
printf "%-14s %s\n" "/data" "$(df -h /data 2>/dev/null | tail -1 | awk "{print \$3\" / \"\$2\" (\"\$5\")\"}")"
printf "%-14s %s\n" "内存" "$(free -m | sed -n 2p | awk "{print \$3\"MB / \"\$2\"MB\"}")"

echo
printf "%-14s %s\n" "网卡" "$(ls /sys/class/net | tr "\n" " ")"
printf "%-14s %s\n" "地址" "$(ifconfig 2>/dev/null | grep "inet addr" | grep -v 127.0.0.1 | awk "{print \$2\" \"\$4}" | tr "\n" " ")"
printf "%-14s %s\n" "服务" "sshd=$(pidof sshd >/dev/null && echo ✓ || echo ✗) udhcpd=$(pidof udhcpd >/dev/null && echo ✓ || echo ✗) wpa=$(pidof wpa_supplicant >/dev/null && echo ✓ || echo ✗)"

# 联网：主路径是 WiFi（WCNSS/prima 自己连 AP），有真默认路由，TCP/UDP/ICMP 全通。
# 隧道那套（SSH -R + unbound + proxychains）已退役，但这里仍看一眼是否残留。
wif=$(ip -4 addr show wlan0 2>/dev/null | awk "/inet /{print \$2}")
gw=$(ip route 2>/dev/null | awk "/^default/{print \$3; exit}")
printf "%-14s " "WiFi"
if [ -n "$wif" ]; then
    echo -n "wlan0=$wif"
    [ -n "$gw" ] && echo -n "  默认路由=$gw" || echo -n "  ⚠ 无默认路由"
    echo -n "  模块=$(lsmod 2>/dev/null | awk "/^wlan /{print \"loaded\"; exit}")"
    ssid=$(wpa_cli -i wlan0 status 2>/dev/null | awk -F= "/^ssid=/{print \$2}")
    [ -n "$ssid" ] && echo -n "  SSID=$ssid"
else
    echo -n "wlan0 无地址（看 /var/log/wifi.log）"
fi
echo

if [ -n "$wif" ] && [ -n "$gw" ]; then
    # 关键：必须清掉代理变量，否则 ssh 会话继承的 SetEnv 会让流量绕回 PC，
    # 测出来的是 PC 的网，不是这台设备的网。
    rip=$(env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
          getent hosts alpinelinux.org 2>/dev/null | awk "NR==1{print \$1}")
    code=$(env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
           curl -s -m 10 -o /dev/null -w "%{http_code}" https://alpinelinux.org/ 2>/dev/null)
    pg=$(ping -c 1 -W 3 "$gw" >/dev/null 2>&1 && echo ✓ || echo ✗)
    printf "%-14s %s\n" "联网实测" "ping网关=$pg  解析=$([ -n "$rip" ] && echo "$rip" || echo 失败)  出网HTTPS=${code:-超时}"
fi

# 隧道残留检测：正常应为"未建立"，出现反而说明有人在跑 dev.sh up
if grep -qi "0100007F:1ED9" /proc/net/tcp 2>/dev/null; then
    printf "%-14s %s\n" "隧道" "代理端口在听（dev.sh up 的残留，WiFi 下不需要）"
fi

echo
printf "%-14s %s\n" "安全网" "boot.count=$(cat /cache/boot.count 2>/dev/null)  Android 标志=$([ -f /cache/.boot-android ] && echo 存在 || echo 无)"
printf "%-14s %s\n" "时间残影" "$(cat /cache/.last_time 2>/dev/null)"
printf "%-14s %s 个包\n" "已装" "$(apk info 2>/dev/null | wc -l)"

err=$(dmesg | grep -icE "ext4.*error|i/o error|remount-ro")
printf "%-14s %s\n" "ext4 错误" "$([ "$err" -eq 0 ] && echo 无 || echo "$err 条！")"

# 配置合法性：与 /var/log 里的历史报错区分开。
# native-net.log 是 append 的，旧的 Unsupported option 行会一直留在里面，
# 只有 sshd -t 才是"当前配置"的判据。
sc=$(sshd -t -f /etc/ssh/sshd_config 2>&1)
printf "%-14s %s\n" "sshd 配置" "$([ -z "$sc" ] && echo "合法 (sshd -t 无输出)" || echo "有问题: $sc")"

echo
echo "── 本次启动日志（/var/log/native-net.log 尾部，超长行已截断）──"
tail -8 /var/log/native-net.log 2>/dev/null | cut -c1-160 | sed "s/^/  /"
' 2>&1 | grep -v "^Warning: Permanently"
