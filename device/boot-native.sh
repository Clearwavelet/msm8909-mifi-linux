#!/bin/sh
# 原生启动时在 openrc 之前运行：挂 cache 分区 + 建立 USB 网络 + 启动 sshd
# 所有步骤写 /var/log/native-net.log，并同步落盘到 splash 分区供事后取证
LOG=/var/log/native-net.log
mkdir -p /var/log /run /var/lib/misc /root/.ssh
: > "$LOG"
log() { echo "[net] $*" >> "$LOG"; }
spl() { if [ -b /dev/mmcblk0p16 ]; then
          dd if="$LOG" of=/dev/mmcblk0p16 bs=4096 conv=notrunc 2>/dev/null
          sync
        fi; }

log "=== boot-native 启动 $(date 2>/dev/null) ==="
log "interfaces: $(ls /sys/class/net 2>/dev/null | tr '\n' ' ')"

# ---------------------------------------------------------------
# 0. 把 cache 分区根挂到 /cache
#    关键：initramfs 的"连续失败计数"(boot.count) 与 ".boot-android" 标志
#    都写在 cache 分区【根目录】上。若不挂载，Alpine 写的 /cache/boot.count
#    落在 rootfs 的 /cache 目录里，与 initramfs 读的不是同一个文件 ->
#    "连续 3 次失败自动回 Android" 的安全网会静默失效。
# ---------------------------------------------------------------
if [ -d /cache/alpine ]; then
    log "cache 已是分区根，跳过挂载"
else
    mkdir -p /cache
    if mount -t ext4 -o rw /dev/mmcblk0p23 /cache 2>>"$LOG"; then
        log "cache 分区已挂到 /cache: $(ls /cache 2>/dev/null | tr '\n' ' ')"
    else
        log "!! cache 分区挂载失败（/dev/mmcblk0p23），计数与标志将不可用"
    fi
fi
spl

# ---------------------------------------------------------------
# 0a. 板子没有 RTC 备电，上电后内核时间永远是 1970-01-01。
#     用上次掉电前写入的 UTC 时间做"残影"恢复，至少让文件时间戳合理。
#     （真正的校时由 PC 端 dev.sh 每次连接时推送）
#     【必须放在 0 之后】/cache 没挂载时这里读到的是根分区上的空目录，
#     曾经因此静默失效（2026-11-16 冷启动实测确认）。
# ---------------------------------------------------------------
if [ -s /cache/.last_time ]; then
    LT="$(cat /cache/.last_time 2>/dev/null)"
    case "$LT" in
        20[2-9][0-9]-*) date -u -s "$LT" 2>>"$LOG" && log "时间恢复自 /cache/.last_time: $LT (UTC)" ;;
        *) log "!! /cache/.last_time 内容不可用: [$LT]" ;;
    esac
else
    log "无 /cache/.last_time，时间从 1970 开始（等 dev.sh 校时）"
fi
spl

# ---------------------------------------------------------------
# 0b. 清掉 initramfs 留下的侧路挂载点
#     hybrid init 为了不污染 /dev /proc /sys，用了 /hp /hs 副挂载，
#     switch_root 之后它们会一直挂在根上，变成只占位无用的僵尸挂载。
# ---------------------------------------------------------------
for m in /hp /hs /mnt/t29; do
    if grep -q " $m " /proc/mounts 2>/dev/null; then
        umount "$m" 2>>"$LOG" && log "已卸载孤立挂载 $m" || log "!! $m 卸载失败（可能仍被占用，无害）"
    fi
done

# ---------------------------------------------------------------
# 0c. 挂 /data（userdata 分区 mmcblk0p29，1.79 GB ext4）
#     根分区只有 248 MB，装不下编译工具链/大包；把"大件"放这里。
#     注意：这块盘原是 Android 的 /data，误删会丢 Android 数据，
#     但本机已全盘 Alpine 化，Android 只作兜底不再使用。
# ---------------------------------------------------------------
if grep -q " /data " /proc/mounts 2>/dev/null; then
    log "data 已挂载，跳过"
else
    mkdir -p /data /data/home
    if mount -t ext4 -o rw,noatime /dev/mmcblk0p29 /data 2>>"$LOG"; then
        log "data 已挂到 /data: $(df -h /data 2>/dev/null | tail -1)"
        # /home 放到大分区上，避免往 248 MB 的根里塞用户文件
        mkdir -p /data/home
        if ! grep -q " /home " /proc/mounts 2>/dev/null; then
            mount --bind /data/home /home 2>>"$LOG" && log "/home -> /data/home"
        fi
    else
        log "!! data 分区挂载失败（/dev/mmcblk0p29），/home 仍在根分区"
    fi
fi
spl

# loopback
ifconfig lo 127.0.0.1 netmask 255.0.0.0 up 2>>"$LOG"
log "lo: $(ifconfig lo 2>&1 | tr '\n' ' ')"

# 网卡名由 initramfs 探测后写在 /usbnet.name（v9 起不再硬编码 usb0）
NET=""
if [ -r /usbnet.name ]; then
    NET="$(cat /usbnet.name 2>/dev/null | tr -d ' \n')"
fi
if [ -z "$NET" ] || [ ! -e "/sys/class/net/$NET" ]; then
    for c in usb0 rndis0 eth0 usb1; do
        if [ -e "/sys/class/net/$c" ]; then NET="$c"; break; fi
    done
fi
# 最后兜底：取第一个非 lo 的接口
if [ -z "$NET" ]; then
    for c in $(ls /sys/class/net 2>/dev/null); do
        case "$c" in lo) ;; *) NET="$c"; break;; esac
    done
fi
log "选用网卡 NET=[$NET]"

if [ -n "$NET" ] && [ -e "/sys/class/net/$NET" ]; then
    ifconfig "$NET" 192.168.42.129 netmask 255.255.255.0 up 2>>"$LOG"
    log "$NET: $(ifconfig "$NET" 2>&1 | tr '\n' ' ')"
    # 同时挂上 ICS 网段的固定地址（这一条只配地址，不配路由）。
    # 原因：Windows 一开启「Internet 连接共享」，就会把 RNDIS 侧改成
    # 192.168.137.1，PC 上 192.168.42.0/24 的路由随之消失 —— 如果设备这边
    # 还没配 137 网段地址，两边会互相看不见，改个共享就把自己锁在门外。
    # 所以这里无条件先配上，让 sshd 在任何模式下都有入口。
    ip addr add 192.168.137.50/24 dev "$NET" 2>>"$LOG"
    log "$NET 地址: $(ip -4 addr show dev "$NET" 2>/dev/null | awk '/inet /{printf "%s ", $2}')"
    sed -i "s/^interface .*/interface $NET/" /etc/udhcpd.conf 2>/dev/null
else
    log "!! 没有任何可用网卡"
fi
spl

# DHCP，让 Windows 的 RNDIS 网卡自动拿到地址
touch /var/lib/misc/udhcpd.leases 2>/dev/null
udhcpd /etc/udhcpd.conf 2>>"$LOG"
log "udhcpd rc=$? pid=$(pidof udhcpd 2>/dev/null)"
spl

hostname xj19 2>/dev/null
echo xj19 > /etc/hostname 2>/dev/null

# ---------------------------------------------------------------
# WiFi（WCNSS / prima）—— 设备真正的联网方式，2026-11-16 打通
#   整条链路是：NV 就位 -> echo 1 上电 -> 等 cold boot -> insmod -> 关联 -> DHCP
#   耗时 10~20 秒，因此放后台，不能挡住 sshd（否则 USB 入口会晚起）。
#   细节与踩过的坑都写在 /usr/local/sbin/wifi-connect.sh 里。
# ---------------------------------------------------------------
if [ -x /usr/local/sbin/wifi-connect.sh ]; then
    ( setsid /usr/local/sbin/wifi-connect.sh >/var/log/wifi-boot.log 2>&1 </dev/null & )
    log "wifi-connect 已后台启动（日志 /var/log/wifi.log）"
else
    log "wifi-connect.sh 未部署，跳过 WiFi"
fi
spl

# ---------------------------------------------------------------
# DNS 转发器（仅隧道时代的遗留，WiFi 通了以后不再需要）
#   设备唯一对外通道曾是 PC 端的 SSH 反向隧道（只承载 TCP），而 musl 的
#   resolver 只会发 UDP —— 当时必须由 unbound 把 UDP:53 翻成 TCP 转发到
#   隧道的另一端（127.0.0.1:5353 -> PC 上 mihomo 的 DNS）。
#   现在 WiFi 直连，resolv.conf 由 wifi-connect.sh 指向真实 DNS，
#   unbound 若仍起来也只会占着 127.0.0.1:53，属无害遗留；这里直接跳过。
# ---------------------------------------------------------------
if [ -x /usr/local/sbin/wifi-connect.sh ]; then
    pkill unbound 2>/dev/null
    log "WiFi 接管联网，跳过 unbound 与隧道判定"
elif [ -x /usr/sbin/unbound ]; then
    pkill unbound 2>/dev/null
    /usr/sbin/unbound -c /etc/unbound/unbound.conf 2>>"$LOG"
    sleep 1
    if [ -n "$(pidof unbound 2>/dev/null)" ]; then
        log "unbound 已启动 pid=$(pidof unbound 2>/dev/null)（DNS 依赖 PC 隧道就位）"
    else
        log "!! unbound 启动失败（/etc/unbound/unbound.conf）"
    fi
else
    log "unbound 未安装，跳过 DNS 转发器（域名将无法解析）"
fi
spl

# ---------------------------------------------------------------
# 出网方式：优先 ICS，退而求其次用 SSH 隧道
#   ICS = Windows「Internet 连接共享」。PC 端把能上网的网卡共享给 RNDIS 后，
#   设备就是 192.168.137.0/24 里的普通客户端，TCP/UDP/ICMP 全通。
#   探测方式：连接 192.168.137.1:53（ICS 的 DNS 代理）。
#   必须放在 sshd 之前 —— sshd 现在监听 0.0.0.0，与地址无关，但 DNS 要就位。
# ---------------------------------------------------------------
if [ -x /usr/local/sbin/wifi-connect.sh ]; then
    # WiFi 是主路径，不再做 ICS/隧道判定（net-mode 会改 resolv.conf 和默认路由，
    # 与 wifi-connect 抢同一个位置，容易互相覆盖）。手动要切模式仍可执行
    # /usr/local/sbin/net-mode.sh ics|tunnel。
    log "联网方式: WiFi（net-mode 自动判定已停用）"
elif [ -x /usr/local/sbin/net-mode.sh ]; then
    /usr/local/sbin/net-mode.sh auto 2>>"$LOG"
    log "net-mode=$(cat /run/net-mode 2>/dev/null)（ics=Windows连接共享 / tunnel=SSH反向隧道）"
else
    log "!! net-mode.sh 未部署，保持 tunnel 模式"
fi
spl

# sshd 的前置条件：私钥分离目录 + 严格权限（StrictModes 会检查）
mkdir -p /run/sshd /var/empty
chmod 711 /var/empty 2>/dev/null
chmod 700 /root 2>/dev/null
chmod 700 /root/.ssh 2>/dev/null
chmod 600 /root/.ssh/authorized_keys 2>/dev/null
log "perm: root=$(stat -c '%a %U' /root 2>/dev/null) sshdir=$(stat -c '%a' /root/.ssh 2>/dev/null) ak=$(stat -c '%a' /root/.ssh/authorized_keys 2>/dev/null)"

# sshd
mkdir -p /run/sshd
/usr/bin/ssh-keygen -A >>"$LOG" 2>&1
log "hostkeys: $(ls /etc/ssh/ 2>/dev/null | tr '\n' ' ')"
/usr/sbin/sshd -f /etc/ssh/sshd_config 2>>"$LOG"
log "sshd rc=$? pid=$(pidof sshd 2>/dev/null)"
spl

# 系统确实可用了 -> 清零 initramfs 的"连续失败计数"，
# 否则连续 3 次上电后会误判为坏镜像而退回 Android。
if [ -n "$(pidof sshd 2>/dev/null)" ]; then
    echo 0 > /cache/boot.count 2>/dev/null && sync 2>/dev/null
    log "启动计数清零: [$(cat /cache/boot.count 2>/dev/null)]"
fi

log "=== ready: ssh -i id_alpine root@192.168.42.129 ==="
spl
