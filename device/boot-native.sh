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
