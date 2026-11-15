#!/bin/sh
# 设备侧的出网方式切换
#
#   ics     Windows 的「Internet 连接共享」(ICS)：在能上网的那块网卡上勾选
#           "允许其他网络用户通过此计算机的 Internet 连接来连接"，目标选 RNDIS。
#           Windows 随后把 RNDIS 那侧设成 192.168.137.1，并自带 DHCP + DNS 代理。
#           设备在这里只是同一网段里的一个普通客户端：加地址 + 加默认路由 + 指 DNS。
#           好处：TCP/UDP/ICMP 全通（apk、ntp、ping、QUIC 都正常），PC 端零脚本。
#
#   tunnel  老的 SSH 反向隧道（只承载 TCP）。PC 端 ssh 要带 -R 7897/5353，
#           设备侧的 unbound 把 UDP:53 翻成 TCP 送给隧道另一端。
#           只在没法开 ICS 时当后备。
#
#   auto    先探测 ICS 网关的 53 端口（Windows 连接共享的 DNS 代理监听在这里），
#           通就用 ics，不通退回 tunnel。
#
# 关键：两种模式下 usb0 都保留 192.168.42.129，所以即使 auto 判错了、
# 或者 ICS 被关掉，`ssh root@192.168.42.129` 依然进得来，不会把自己关在门外。

NET=""
if [ -r /usbnet.name ]; then
    NET="$(cat /usbnet.name 2>/dev/null | tr -d ' \n')"
fi
if [ -z "$NET" ] || [ ! -e "/sys/class/net/$NET" ]; then
    for c in usb0 rndis0 eth0 usb1; do
        [ -e "/sys/class/net/$c" ] && { NET="$c"; break; }
    done
fi
[ -z "$NET" ] && NET=usb0

ICS_GW=192.168.137.1
ICS_SELF=192.168.137.50
MODE_FILE=/run/net-mode

log() { echo "net-mode: $*"; }

to_ics() {
    ip link set "$NET" up 2>/dev/null
    ip addr add "$ICS_SELF/24" dev "$NET" 2>/dev/null
    # metric 比隧道那侧的任何默认路由都小，确保优先走 ICS
    ip route replace default via "$ICS_GW" dev "$NET" metric 50 2>/dev/null
    {
        echo "# ICS 模式：192.168.137.1 同时是网关、DHCP 服务器和 DNS 代理"
        echo "nameserver $ICS_GW"
    } > /etc/resolv.conf
    # 走 ICS 时 unbound 是多余的（UDP 本来就通），留着反而多一跳
    pkill unbound 2>/dev/null
    echo ics > "$MODE_FILE"
    log "已切到 ics: $NET=$ICS_SELF/24 default via $ICS_GW"
}

to_tunnel() {
    ip route del default via "$ICS_GW" dev "$NET" 2>/dev/null
    printf '# 指向本机 unbound：把 UDP 查询翻成 TCP 送给 SSH 隧道\nnameserver 127.0.0.1\n' > /etc/resolv.conf
    if [ -x /usr/sbin/unbound ]; then
        pkill unbound 2>/dev/null
        /usr/sbin/unbound -c /etc/unbound/unbound.conf 2>/dev/null
    fi
    echo tunnel > "$MODE_FILE"
    log "已切到 tunnel: DNS -> 127.0.0.1(unbound), 依赖 PC 端 ssh -R"
}

probe_ics() {
    # Windows 连接共享的 DNS 代理在 192.168.137.1:53 上；连得上说明 ICS 真的开了。
    # 用 TCP 探测（busybox nc），不依赖 ICMP。
    # 冷启动时 RNDIS 链路刚起来，ARP 可能还没通，所以重试几轮。
    i=0
    while [ "$i" -lt 4 ]; do
        nc -w 2 "$ICS_GW" 53 </dev/null >/dev/null 2>&1 && return 0
        i=$((i + 1))
        sleep 1
    done
    return 1
}

case "${1:-auto}" in
    ics)    to_ics ;;
    tunnel) to_tunnel ;;
    auto)
        if probe_ics; then
            log "探测到 $ICS_GW:53 可连，采用 ics"
            to_ics
        else
            log "探测不到 $ICS_GW:53，采用 tunnel"
            to_tunnel
        fi
        ;;
    status)
        echo "mode   : $(cat "$MODE_FILE" 2>/dev/null || echo unknown)"
        echo "netdev : $NET"
        echo "addr   : $(ip -4 addr show dev "$NET" 2>/dev/null | awk '/inet /{printf "%s ", $2}')"
        echo "default: $(ip route show default 2>/dev/null | tr '\n' ' ')"
        echo "dns    : $(grep -v '^#' /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
        ;;
    *)
        echo "用法: $0 {auto|ics|tunnel|status}" >&2
        exit 1
        ;;
esac
