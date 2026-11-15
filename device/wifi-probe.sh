#!/bin/sh
# 逐步点亮板载 WiFi（WCNSS + prima），每步落盘并 sync。
# 内核若卡死，重启后看 /cache/wifi-test.log 的最后一 [N] 就知道死在哪一步。
#
# 用法（在设备上）: sh /wifi-probe.sh [步骤号]
#   不带参数 = 从第 1 步跑到底
#   带参数   = 只跑该步（一次只改一个变量，便于定位）
LOG=/cache/wifi-test.log
FW_SRC=/mnt/mdm/image
SYS=/mnt/sys
PERSIST=/mnt/persist
KO=/lib/modules/3.10.49/pronto_wlan.ko

say() { echo "[$(date '+%H:%M:%S')] [${STEP:-?}] $*" >> "$LOG"; sync; }

mount_all() {
    mkdir -p /mnt/mdm /mnt/sys /mnt/persist /lib/firmware /etc/firmware/wlan/prima /lib/modules/3.10.49 /data/misc/wifi
    mount -t vfat -o ro /dev/mmcblk0p1  /mnt/mdm     2>/dev/null
    mount -t ext4 -o ro /dev/mmcblk0p21 "$SYS"       2>/dev/null
    mount -t ext4 -o ro /dev/mmcblk0p22 "$PERSIST"   2>/dev/null
}

wcnss_state() { cat /sys/bus/platform/devices/a21b000.qcom,pronto/subsys1/state 2>/dev/null; }

step1_firmware() {
    STEP=1 say "开始：搬固件与 NV"
    mount_all
    cp -f $FW_SRC/wcnss.* /lib/firmware/ 2>>"$LOG"
    cp -f $FW_SRC/wcnss.* /etc/firmware/ 2>>"$LOG"
    cp -f $PERSIST/WCNSS_qcom_wlan_nv.bin     /etc/firmware/wlan/prima/ 2>>"$LOG"
    cp -f $PERSIST/WCNSS_wlan_dictionary.dat  /etc/firmware/wlan/prima/ 2>>"$LOG"
    cp -f $SYS/etc/firmware/wlan/prima/WCNSS_cfg.dat /etc/firmware/wlan/prima/ 2>>"$LOG"
    cp -f $SYS/etc/wifi/WCNSS_qcom_cfg.ini    /etc/firmware/wlan/prima/ 2>>"$LOG"
    cp -f $SYS/etc/wifi/WCNSS_qcom_cfg.ini    /etc/wifi/ 2>>"$LOG"
    cp -f $SYS/lib/modules/pronto/pronto_wlan.ko "$KO" 2>>"$LOG"
    say "固件: $(ls /lib/firmware | tr '\n' ' ')"
    say "prima 目录: $(ls /etc/firmware/wlan/prima | tr '\n' ' ')"
    say "模块: $([ -f $KO ] && echo 有 || echo 无) $(ls -l $KO | awk '{print $5}') 字节"
}

step2_serial() {
    STEP=2 say "写 serial_number（原厂脚本要求，缺失可能影响校准流程）"
    for f in /sys/devices/*wcnss-wlan/serial_number /sys/devices/platform/wcnss_wlan.0/serial_number; do
        if [ -w "$f" ]; then
            echo "XJ19-0001" > "$f" 2>>"$LOG" && say "已写入 $f = XJ19-0001"
        fi
    done
    say "serial_number 现状: $(cat /sys/devices/*wcnss-wlan/serial_number 2>/dev/null)"
}

step3_trigger() {
    STEP=3 say "握手：echo 1 > /dev/wcnss_wlan（告诉驱动用户态就绪）"
    say "握手前 state=$(wcnss_state)"
    echo 1 > /dev/wcnss_wlan 2>>"$LOG"; say "写入 rc=$?"
    i=0
    while [ $i -lt 20 ]; do
        s=$(wcnss_state)
        [ "$s" = "ONLINE" ] && { say "state=ONLINE（用时 $((i*500))ms）"; break; }
        sleep 0.5; i=$((i+1))
    done
    say "最终 state=$(wcnss_state) crash_count=$(cat /sys/bus/platform/devices/a21b000.qcom,pronto/subsys1/crash_count 2>/dev/null)"
    say "dmesg: $(dmesg | grep -c wcnss) 行 wcnss 记录"
}

step4_ctrl_reader() {
    STEP=4 say "起一个 /dev/wcnss_ctrl 读线程（模拟 wcnss_service 收 ready 事件）"
    # 只读不写，超时 30s 自动退出，日志留档
    ( timeout 30 cat /dev/wcnss_ctrl > /cache/wcnss-ctrl.bin 2>>"$LOG"; \
      say "ctrl reader 退出 rc=$? 读到 $(wc -c < /cache/wcnss-ctrl.bin 2>/dev/null) 字节" ) &
    say "reader pid=$!"
}

step5_insmod() {
    STEP=5 say "加载 prima: insmod $KO"
    if lsmod 2>/dev/null | grep -q wlan; then say "已加载，跳过"; return 0; fi
    # 上限 25s：卡在 D 态时 timeout 杀不掉，但日志已落盘
    timeout 25 insmod "$KO" 2>>"$LOG"
    rc=$?
    say "insmod rc=$rc（0=成功 19=ENODEV 124=超时挂住）"
    sleep 3
    say "接口: $(ls /sys/class/net | tr '\n' ' ')"
    say "wlan0 存在: $([ -e /sys/class/net/wlan0 ] && echo 是 || echo 否)"
    say "dmesg 尾部: $(dmesg | tail -6 | tr '\n' '|')"
}

step9_dmesg() {
    STEP=9 say "完整 wcnss dmesg 落盘"
    dmesg | grep -Ei "wcnss|prima|wlan|pil" > /cache/wifi-dmesg.log 2>/dev/null
    say "已写 /cache/wifi-dmesg.log（$(wc -l < /cache/wifi-dmesg.log) 行）"
}

# ---------------------------------------------------------------
: > "$LOG"
say "=== wifi-probe 启动，内核 $(uname -r)，uptime $(cut -d' ' -f1 /proc/uptime)s ==="
case "${1:-all}" in
    1) step1_firmware ;;
    2) step2_serial ;;
    3) step3_trigger ;;
    4) step4_ctrl_reader ;;
    5) step5_insmod ;;
    all)
        step1_firmware; step2_serial; step3_trigger; step9_dmesg
        say "前 3 步完成。insmod 是高风险步骤，需单独执行: sh /wifi-probe.sh 5"
        ;;
    *) echo "用法: sh $0 [1|2|3|4|5|all]" ;;
esac
say "=== 结束 ==="
tail -20 "$LOG"
