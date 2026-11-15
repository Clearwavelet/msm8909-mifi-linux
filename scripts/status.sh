#!/usr/bin/env bash
# 一页体检报告：这台无屏无键的机器，随时想知道"它还正常吗"就跑这个
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
KEY="${DEV_KEY:-$HOME/.ssh/xj19_ed25519}"
KEY="$(cygpath -w "$KEY" 2>/dev/null || echo "$KEY")"
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
printf "%-14s %s\n" "服务" "sshd=$(pidof sshd >/dev/null && echo ✓ || echo ✗) udhcpd=$(pidof udhcpd >/dev/null && echo ✓ || echo ✗)"

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
