#!/bin/sh
# 开机拉起 WCNSS(prima) WiFi 并连上热点。
#
# 每一步都对应一个实测出来的硬依赖，顺序不能换：
#
#  1) NV / cfg 必须在 /lib/firmware/wlan/prima/
#     内核的 wcnssctrl_nvbin_dnld_work 用 request_firmware("wlan/prima/...") 找它们。
#     找不到会退到用户态 hotplug helper，本机没有 udev，于是不可中断地等 60 秒
#     并占住 workqueue —— 现象就是"内核调度停摆，只能拔插"。
#     （2026-11-16 实测：把 NV 放进 /lib/firmware/wlan/prima 后 NV 立刻下发成功）
#
#  2) echo 1 > /dev/wcnss_wlan
#     触发 PIL 从 /firmware/image 或 /lib/firmware 取 wcnss.mdt+b*，把芯片扶起来。
#
#  3) 等固件回 WCNSS_CBC_COMPLETE_IND
#     prima 的 hdd_driver_init 轮询 wcnss_device_ready()，判据是 nv_downloaded；
#     这个标志只在 NV 下发完成后置位。没置位就 insmod 会返回 -ENODEV
#     ("WCNSS driver not ready")，然后 5 秒超时把内核拖死。
#
#  4) insmod prima + fwpath=sta
#
#  5) wpa_supplicant -Dwext
#     prima 的 nl80211 connect 实现不完整，-Dnl80211 会报
#     "Association request to the driver failed"；wext 后端才能走通（含 WPA2 四次握手）。
#
#  6) udhcpc 拿地址 + 写 resolv.conf
#
# 用法: wifi-connect.sh [--iface wlan0] [--wait N]
set -u
LOG=/var/log/wifi.log
mkdir -p /var/log /run
log() { echo "[$(date +%H:%M:%S 2>/dev/null || echo --:--:--)] $*" >>"$LOG"; }
say() { log "$*"; echo "$*"; }

IFACE=wlan0
WAIT=20
while [ $# -gt 0 ]; do
    case "$1" in
        --iface) IFACE="$2"; shift 2 ;;
        --wait)  WAIT="$2"; shift 2 ;;
        *) shift ;;
    esac
done

MOD=/lib/modules/pronto_wlan.ko
NV_DIR=/lib/firmware/wlan/prima
SRC_DIR=/etc/firmware/wlan/prima

: > "$LOG"
say "==== wifi-connect 开始 ===="

# ---------- 1) NV / cfg 就位 ----------
mkdir -p "$NV_DIR"
for f in WCNSS_qcom_wlan_nv.bin WCNSS_qcom_cfg.ini WCNSS_cfg.dat WCNSS_wlan_dictionary.dat; do
    if [ ! -f "$NV_DIR/$f" ] && [ -f "$SRC_DIR/$f" ]; then
        cp -f "$SRC_DIR/$f" "$NV_DIR/$f" && log "复制 $f -> $NV_DIR"
    fi
done
if [ -f "$NV_DIR/WCNSS_qcom_wlan_nv.bin" ]; then
    log "NV 就位: $(wc -c < "$NV_DIR/WCNSS_qcom_wlan_nv.bin") 字节"
else
    say "!! 缺 NV，放弃（继续会有 60 秒不可中阻塞，宁可不动）"
    exit 1
fi

# ---------- 模块来源：从 system 分区取一次 ----------
if [ ! -f "$MOD" ]; then
    mkdir -p /lib/modules /system
    mountpoint -q /system || mount -t ext4 -o ro /dev/mmcblk0p21 /system 2>>"$LOG"
    if [ -f /system/lib/modules/pronto/pronto_wlan.ko ]; then
        cp -f /system/lib/modules/pronto/pronto_wlan.ko "$MOD"
        log "已从 /system 复制 prima 模块到 $MOD"
    else
        say "!! 找不到 pronto_wlan.ko"
        exit 1
    fi
fi

# ---------- 2) 触发上电 ----------
if ! lsmod 2>/dev/null | grep -q '^wlan '; then
    if [ -c /dev/wcnss_wlan ]; then
        # 这个字符设备的 write 只认校准数据的特定长度，写 "1\n" 会返回 EFAULT，
        # 但 open+write 的副作用足以触发上电（Android 的 wcnss_service 同款做法）。
        # 所以这里的 "Bad address" 是预期内的，吞掉，别污染日志。
        echo 1 > /dev/wcnss_wlan 2>/dev/null
        log "已触发 WCNSS 上电"
    else
        say "!! /dev/wcnss_wlan 不存在（wcnss_wlan 驱动未内置？）"
        exit 1
    fi

    # ---------- 3) 等 NV 下发 / cold boot 完成 ----------
    i=0; ok=0
    while [ "$i" -lt "$WAIT" ]; do
        if dmesg | grep -q "WCNSS_CBC_COMPLETE_IND"; then ok=1; break; fi
        if dmesg | grep -qi "Failed to load nv file"; then
            say "!! NV 加载失败（request_firmware 没命中）"
            exit 1
        fi
        sleep 1
        i=$((i + 1))
    done
    [ "$ok" = 1 ] || { say "!! ${WAIT}s 内没等到 cold boot 完成，停止（不 insmod）"; exit 1; }
    log "cold boot 完成（${i}s）"

    # ---------- 4) 加载 prima ----------
    insmod "$MOD" 2>>"$LOG"
    rc=$?
    log "insmod rc=$rc"
    [ "$rc" -eq 0 ] || { say "!! insmod 失败 rc=$rc"; exit 1; }
    echo sta > /sys/module/wlan/parameters/fwpath 2>>"$LOG"
    log "fwpath=sta"
else
    log "prima 已加载，跳过上电"
fi

# ---------- 网卡 up ----------
ip link set "$IFACE" up 2>>"$LOG" || { say "!! $IFACE up 失败"; exit 1; }
log "$IFACE 已 up"

# ---------- 5) wpa_supplicant（wext）----------
CONF=/etc/wpa_supplicant/wpa_supplicant.conf
[ -f "$CONF" ] || { say "!! 缺 $CONF"; exit 1; }
pkill -f "wpa_supplicant.*$IFACE" 2>/dev/null
sleep 1
wpa_supplicant -Dwext -B -i "$IFACE" -c "$CONF" 2>>"$LOG"
log "wpa_supplicant rc=$?"

i=0; ok=0
while [ "$i" -lt 25 ]; do
    if wpa_cli -i "$IFACE" status 2>/dev/null | grep -q "wpa_state=COMPLETED"; then ok=1; break; fi
    sleep 1
    i=$((i + 1))
done
[ "$ok" = 1 ] || { say "!! ${i}s 内未关联成功"; wpa_cli -i "$IFACE" status 2>/dev/null | tail -5; exit 1; }
log "已关联: $(wpa_cli -i "$IFACE" status 2>/dev/null | grep -E '^(ssid|bssid)=' | tr '\n' ' ')"

# ---------- 6) DHCP + DNS ----------
ip -4 addr flush dev "$IFACE" 2>/dev/null
udhcpc -i "$IFACE" -n -q -t 8 >>"$LOG" 2>&1
rc=$?
log "udhcpc rc=$rc addr=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2}')"
[ "$rc" -eq 0 ] || { say "!! DHCP 失败"; exit 1; }

# resolv.conf：优先用 DHCP 下发的网关做 DNS。之前的 127.0.0.1(unbound) 只服务于
# SSH 隧道时代（隧道只能承载 TCP，UDP 出不去才需要本地转发器），WiFi 下不需要了。
GW=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')
if [ -n "$GW" ]; then
    printf 'nameserver %s\nnameserver 223.5.5.5\n' "$GW" > /etc/resolv.conf
else
    printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\n' > /etc/resolv.conf
fi
log "resolv.conf: $(tr '\n' ' ' < /etc/resolv.conf)"

say "==== WiFi 就绪: $IFACE $(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2}') gw=${GW:-none} ===="
exit 0
