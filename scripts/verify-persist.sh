#!/usr/bin/env bash
# 冷启动复核：确认新加的 /data 挂载、时间残影、代理 profile 都在重启后自动生效
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
KEY="${DEV_KEY:-$HOME/.ssh/xj19_ed25519}"
KEY="$(cygpath -w "$KEY" 2>/dev/null || echo "$KEY")"
IP="${DEV_IP:-192.168.42.129}"
export MSYS_NO_PATHCONV=1
SSH="ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=6 -o BatchMode=yes"

rndis() {
    local v
    v=$(powershell -NoProfile -Command "[Console]::WriteLine((@(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { \$_.InterfaceDescription -like '*NDIS*' })).Count)" 2>/dev/null | tr -d '\r\n ')
    case "$v" in ''|*[!0-9]*) echo -1 ;; *) echo "$v" ;; esac
}

echo "=== A：等设备掉线（最多 240s）==="
for i in $(seq 1 60); do
    if ! $SSH -o ConnectTimeout=4 root@$IP true 2>/dev/null && [ "$(rndis)" = "0" ]; then
        echo "  +$((i*4))s 已拔出"; break
    fi
    sleep 4
done

echo "=== B：等重新上电（最多 480s）==="
res=""
for i in $(seq 1 120); do
    if [ "$(rndis)" -ge 1 ] 2>/dev/null; then res=up; echo "  +$((i*4))s RNDIS 出现"; break; fi
    sleep 4
done
[ "$res" = up ] || { echo "!! 没等到设备上电"; exit 1; }

echo "=== C：SSH 复核 ==="
out=""
for t in $(seq 1 20); do
    out=$($SSH root@$IP '
        echo "uptime=$(cut -d" " -f1 /proc/uptime)"
        echo "kernel=$(uname -r)"
        echo "pid1=$(cat /proc/1/comm)"
        echo "clock=$(date "+%Y-%m-%d %H:%M:%S %Z")"
        echo "year=$(date +%Y)"
        grep -q " /data " /proc/mounts && echo "data=OK" || echo "data=FAIL"
        grep -q " /home " /proc/mounts && echo "home=OK" || echo "home=FAIL"
        grep -q " /cache " /proc/mounts && echo "cache=OK" || echo "cache=FAIL"
        echo "datasize=$(df -h /data 2>/dev/null | tail -1 | awk "{print \$2\" total, \"\$4\" free\"}")"
        echo "bootcount=$(cat /cache/boot.count 2>/dev/null)"
        echo "sshd=$(pidof sshd 2>/dev/null)"
        echo "udhcpd=$(pidof udhcpd 2>/dev/null)"
        echo "net=$(ls /sys/class/net | tr "\n" " ")"
        echo "proxyprofile=$([ -r /etc/profile.d/50-proxy.sh ] && echo yes || echo no)"
        echo "lasttime=$(cat /cache/.last_time 2>/dev/null)"
        echo "apk=$(apk info 2>/dev/null | wc -l) 个包"
    ' 2>/dev/null)
    case "$out" in *kernel=3.10*) break ;; *) sleep 5 ;; esac
done

echo "$out" | sed 's/^/    /'
echo
upt=$(echo "$out" | sed -n 's/^uptime=\([0-9]*\).*/\1/p')
yr=$(echo "$out" | sed -n 's/^year=\([0-9]*\).*/\1/p')
echo "-------- 判定 --------"
[ "${upt:-9999}" -lt 300 ] 2>/dev/null && echo "  ✓ 全新冷启动 (uptime=${upt}s)" || echo "  ! uptime=${upt}s，不是冷启动，结论不可信"
echo "$out" | grep -q data=OK && echo "  ✓ /data 自动挂载" || echo "  ✗ /data 未挂载"
echo "$out" | grep -q home=OK && echo "  ✓ /home 在 /data 上" || echo "  ✗ /home 未重定向"
echo "$out" | grep -q cache=OK && echo "  ✓ /cache 自动挂载" || echo "  ✗ /cache 未挂载"
[ "${yr:-0}" -gt 2020 ] 2>/dev/null && echo "  ✓ 时间残影恢复生效 (year=$yr)" || echo "  ! 时间仍是 1970，残影未生效"
echo "$out" | grep -q "^bootcount=0" && echo "  ✓ 启动计数已清零（安全网正常）" || echo "  ! boot.count 非 0"
echo "$out" | grep -q proxyprofile=yes && echo "  ✓ 代理 profile 就位" || echo "  ✗ 代理 profile 缺失"
