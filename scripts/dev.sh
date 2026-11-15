#!/usr/bin/env bash
# 连到设备。一条命令同时搞定三件事：
#   1) 把 PC 的本地代理经 SSH 反向隧道递到设备 127.0.0.1:7897（设备因此能 apk/curl）
#   2) 用 PC 的时间给设备校时（板子无 RTC，上电永远是 1970）
#   3) 开一个登录 shell（此时 /etc/profile.d/50-proxy.sh 会自动导出代理）
#
# 用法:
#   ./dev.sh              交互 shell（带隧道 + 校时）
#   ./dev.sh cmd 'uname -a'   只跑一条命令
#   ./dev.sh up           只开隧道，不收 shell（后台常驻，Ctrl-C 断开）
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
KEY="${DEV_KEY:-$HOME/.ssh/xj19_ed25519}"
KEY="$(cygpath -w "$KEY" 2>/dev/null || echo "$KEY")"
IP="${DEV_IP:-192.168.42.129}"
export MSYS_NO_PATHCONV=1

SSHO=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
      -o ConnectTimeout=8 -o ServerAliveInterval=15)

# --- 找 PC 上的本地代理端口（Clash/mihomo 默认 7897/7890，v2ray 1080/10809）---
PORT=""
for p in 7897 7890 1080 10809 8889 8080; do
    if (exec 3<>/dev/tcp/127.0.0.1/$p) 2>/dev/null; then exec 3<&- 3>&-; PORT="$p"; break; fi
done
if [ -z "$PORT" ]; then
    echo "!! 没找到本机代理端口（7897/7890/1080/10809 都不在听）。"
    echo "   隧道跳过，但 SSH 仍可用；设备内需要联网时请先启动代理。"
    TUN=()
else
    echo "代理: PC 127.0.0.1:$PORT -> 设备 127.0.0.1:7897"
    TUN=(-R "127.0.0.1:7897:127.0.0.1:$PORT")
fi

# --- 校时 ---
sync_time() {
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')
    ssh "${SSHO[@]}" -o BatchMode=yes root@"$IP" \
        "date -s '$now' >/dev/null 2>&1; date -u +'%Y-%m-%d %H:%M:%S' > /cache/.last_time; sync" \
        >/dev/null 2>&1 && echo "校时: 设备已设为 $now"
}

case "${1:-shell}" in
    up)
        sync_time
        echo "隧道已开（前台）。Ctrl-C 结束。"
        exec ssh "${SSHO[@]}" -N "${TUN[@]}" root@"$IP"
        ;;
    cmd)
        shift
        sync_time
        # 非交互 ssh 不读 /etc/profile.d，代理要在这里显式带上
        if [ -n "$PORT" ]; then
            exec ssh "${SSHO[@]}" "${TUN[@]}" root@"$IP" \
                "export http_proxy=http://127.0.0.1:7897 https_proxy=http://127.0.0.1:7897 HTTP_PROXY=http://127.0.0.1:7897 HTTPS_PROXY=http://127.0.0.1:7897; $*"
        else
            exec ssh "${SSHO[@]}" root@"$IP" "$*"
        fi
        ;;
    *)
        sync_time
        echo "进入设备（exit 或 Ctrl-D 退出）"
        exec ssh "${SSHO[@]}" -t "${TUN[@]}" root@"$IP"
        ;;
esac
