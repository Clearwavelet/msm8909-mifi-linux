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
KEY="$(cygpath -w "$HERE/alpine/id_alpine" 2>/dev/null || echo "$HERE/alpine/id_alpine")"
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
    TUN=(-R "127.0.0.1:7897:127.0.0.1:$PORT")
    echo "代理: PC 127.0.0.1:$PORT -> 设备 127.0.0.1:7897"
    # DNS 也一起递进去：设备上的 unbound 会把 UDP:53 翻成 TCP 转发到 5353，
    # 而 5353 在这里被映射到 PC 上 mihomo 的 DNS(53)。没有这一条设备就解析不了域名。
    if (exec 3<>/dev/tcp/127.0.0.1/53) 2>/dev/null; then
        exec 3<&- 3>&-
        TUN+=(-R "127.0.0.1:5353:127.0.0.1:53")
        echo "DNS : PC 127.0.0.1:53   -> 设备 127.0.0.1:5353"
    else
        echo "!! PC 上没有 DNS 在 53 监听（mihomo 的 dns 未开启？），域名将无法解析"
    fi

    # 如果设备上已经有别的会话开好了隧道（例如另开终端跑着 ./dev.sh up），
    # 就不要再 -R 一遍，否则会因端口占用报 "remote port forwarding failed"。
    if ssh "${SSHO[@]}" -o BatchMode=yes root@"$IP" \
         'grep -qi 0100007F:1ED9 /proc/net/tcp' 2>/dev/null; then
        echo "复用: 设备上已有隧道在监听 7897，本次不再重复转发"
        TUN=()
    fi
fi

# 设备侧把 DNS 转发器拉起来（仅当它没在跑；强制重启用 ./dev.sh net）
BOOTNET='if ! pidof unbound >/dev/null 2>&1 && [ -x /usr/local/bin/net-up.sh ]; then /usr/local/bin/net-up.sh >/dev/null 2>&1; fi'

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
        echo "首次使用或改了配置后，另开一个终端跑: ./dev.sh net"
        exec ssh "${SSHO[@]}" -N "${TUN[@]}" root@"$IP"
        ;;
    net)
        # 完整自检：起 DNS、实测解析与出网，打印用法
        sync_time
        exec ssh "${SSHO[@]}" "${TUN[@]}" root@"$IP" "/usr/local/bin/net-up.sh"
        ;;
    cmd)
        shift
        sync_time
        # 非交互 ssh 不读 /etc/profile.d，代理要在这里显式带上
        if [ -n "$PORT" ]; then
            exec ssh "${SSHO[@]}" "${TUN[@]}" root@"$IP" \
                "$BOOTNET
export http_proxy=http://127.0.0.1:7897 https_proxy=http://127.0.0.1:7897 HTTP_PROXY=http://127.0.0.1:7897 HTTPS_PROXY=http://127.0.0.1:7897 all_proxy=socks5h://127.0.0.1:7897
$*"
        else
            exec ssh "${SSHO[@]}" root@"$IP" "$*"
        fi
        ;;
    *)
        sync_time
        echo "进入设备（exit 或 Ctrl-D 退出）"
        exec ssh "${SSHO[@]}" -t "${TUN[@]}" root@"$IP" "$BOOTNET; exec /bin/sh -l"
        ;;
esac
