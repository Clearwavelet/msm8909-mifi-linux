#!/bin/sh
# wifi-tui.sh — XJ19 的交互式 WiFi 配置器（dialog TUI）
#
# 设计取向：宁可用最笨的办法，也不引入新的依赖链。
#   - 只用 busybox sh + dialog + iw/wpa_cli/udhcpc（都是已有的）
#   - 配置写回 /etc/wpa_supplicant/wpa_supplicant.conf 这个"唯一真相"，
#     不另建数据库 —— 开机 wifi-connect.sh 读的就是它，
#     两边各存一份迟早会对不上。
#   - 新建连接一律"改配置 + 重启 wpa_supplicant + 重新 DHCP"，
#     不用热切。prima 在 wext 后端下的 reassociate 路径实现不全，
#     重启只多花 1~2 秒，行为可预测得多。
#   - 连已保存的网络则走 `wpa_cli select_network <id>`，这是官方接口，
#     不需要密码（PSK 已经在配置里），也不会动别的 network 块。
#
# 用法:
#   wifi-tui.sh              交互界面（默认）
#   wifi-tui.sh status       打印当前连接状态（脚本友好，key=value）
#   wifi-tui.sh scan         打印扫描结果（TSV: ssid / 加密 / 信号 / bssid）
#
# 依赖：dialog（apk add dialog）。硬件必须已由 wifi-connect.sh 拉起；
#       没拉起时本脚本会提示并自动调用 `wifi-connect.sh --hw-only`。
set -u

CONF=/etc/wpa_supplicant/wpa_supplicant.conf
IFACE=wlan0
LOG=/var/log/wifi-tui.log
CTL=/var/run/wpa_supplicant
BT="XJ19 WiFi 配置器"
TAB=$(printf '\t')

mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date '+%F %T')] $*" >>"$LOG" 2>/dev/null; }

# ------------------------------------------------------------------ 工具

die() { echo "$*" >&2; exit 1; }

# dialog 把结果写在 stderr，这个包装送回 stdout，顺便统一 backtitle
dlg() { dialog --backtitle "$BT" "$@" 3>&1 1>&2 2>&3; }

msg() { dialog --backtitle "$BT" --title "${2:-提示}" --msgbox "$1" 0 0; }
err() { dialog --backtitle "$BT" --title "出错了" --msgbox "$1" 0 0; }
ask() { dialog --backtitle "$BT" --title "${2:-确认}" --yesno "$1" 0 0; }

hr_sig() {
    # -45 -> ####，越弱格子越少。纯 ASCII，不赌终端字符集。
    case "$1" in
        -[0-9]|-1[0-9]|-2[0-9]|-3[0-9]|-4[0-9]) echo "####" ;;
        -5[0-9]) echo "###." ;;
        -6[0-9]) echo "##.." ;;
        -7[0-9]) echo "#..." ;;
        *)       echo "...." ;;
    esac
}

# ------------------------------------------------------------------ 扫描

# 输出四列：ssid <TAB> 加密 <TAB> 信号dBm <TAB> bssid，当前连接排最前。
# 同一 SSID 有多个 BSS（mesh / 多频）时只留最强的那个。
scan_aps() {
    raw=$(iw dev "$IFACE" scan 2>/dev/null | awk '
        BEGIN { RS = "BSS " }
        NR > 1 {
            bssid = $0
            sub(/\(.*/, "", bssid)
            gsub(/[ \t]/, "", bssid)

            ssid = ""; sig = ""; sec = ""
            n = split($0, L, "\n")
            for (i = 1; i <= n; i++) {
                ln = L[i]
                if (ln ~ /^[ \t]*SSID:/) {
                    v = ln; sub(/^[ \t]*SSID:[ \t]*/, "", v)
                    sub(/[ \t]+$/, "", v)
                    ssid = v
                } else if (ln ~ /^[ \t]*signal:/) {
                    v = ln; sub(/^[ \t]*signal:[ \t]*/, "", v); sub(/[ \t]*dBm.*/, "", v)
                    sub(/\..*/, "", v)          # -68.00 -> -68，否则下面的格子判断全落空
                    sig = v
                } else if (ln ~ /^[ \t]*RSN:/) {
                    sec = "WPA2"
                } else if (ln ~ /^[ \t]*WPA:/) {
                    if (sec == "") sec = "WPA"
                } else if (ln ~ /capability:.*Privacy/) {
                    if (sec == "") sec = "WEP"
                }
            }
            if (ssid == "") next
            if (sig == "") sig = "?"
            if (sec == "") sec = "OPEN"

            key = 100 + sig               # 信号转正数，避免 sort 处理负号的口味差异
            if (!(ssid in best) || (sig != "?" && key > bestk[ssid])) {
                best[ssid] = sec; bestk[ssid] = key; bestb[ssid] = bssid
                bests[ssid] = sig
            }
        }
        END {
            for (s in best)
                printf "%s\t%s\t%s\t%s\n", s, best[s], bests[s], bestb[s]
        }')

    # iw 会把 SSID 里的非打印字节转义成字面文本 "\xNN"（C locale 下 >0x7F 也算，
    # 所以中文 SSID 会变成 "\xe4\xb8\xad..."）。必须解回来：
    #   - 不解码，中文 SSID 拿去连必然失败
    #   - 隐藏网络的 SSID 是整串 "\x00"，解码后是空串，正好可以据此跳过
    raw=$(printf '%s\n' "$raw" | while IFS="$TAB" read -r s sec sig bss; do
              [ -z "$s" ] && continue
              if printf '%s' "$s" | grep -q '\\x'; then
                  s=$(printf '%b' "$s" | tr -d '\000')
                  [ -z "$s" ] && continue        # 纯 \x00 = 隐藏网络
              fi
              printf '%s\t%s\t%s\t%s\n' "$s" "$sec" "$sig" "$bss"
          done)

    # 解码之后必须再去重一次：同一个 SSID 的不同 BSS 里，有的 SSID 带 \x00 尾巴、
    # 有的不带，解码前是两个不同的 key，解码后变成同一条 —— 不去重就会在列表里
    # 出现两行一模一样的网名（实测 SUDA_WIFI 就是这样冒出来的）。
    # 保留信号最强的；"?" 当 0 处理，所以当前连接那条会优先留下。
    raw=$(printf '%s\n' "$raw" | awk -F'\t' 'BEGIN { OFS = "\t" }
        {
            s = $1; v = $3 + 0
            if (!(s in bestv))            { bestv[s] = v; line[s] = $0 }
            else if (v > bestv[s])        { bestv[s] = v; line[s] = $0 }
        }
        END { for (s in line) print line[s] }')

    # 已连接的那个 AP 还有个坑：prima 上报扫描结果时不带 RSN 段、信号恒为 0。
    # 不处理的话它会被标成 "WEP"（只剩 capability 的 Privacy 位可看），
    # 而用户最可能点的就是它。加密类型改用 wpa_cli 报的真实值覆盖；
    # 信号标成未知 —— signal_poll 在 prima 上直接返回 FAIL，编不出来。
    cur=$(link_ssid)
    if [ -n "$cur" ]; then
        ckm=$(wpa_cli -i "$IFACE" status 2>/dev/null | sed -n 's/^key_mgmt=//p')
        raw=$(printf '%s\n' "$raw" | awk -F'\t' -v cur="$cur" -v ckm="$ckm" 'BEGIN { OFS = "\t" }
            $1 == cur {
                if (ckm ~ /WPA2/)       $2 = "WPA2"
                else if (ckm ~ /WPA/)   $2 = "WPA"
                else if (ckm == "NONE") $2 = "OPEN"
                if ($3 + 0 == 0)        $3 = "?"
            }
            { print }')
    fi

    # 当前连接置顶，其余按信号从强到弱
    curline=$(printf '%s\n' "$raw" | awk -F'\t' -v c="$cur" 'c != "" && $1 == c')
    others=$(printf '%s\n' "$raw" | awk -F'\t' -v c="$cur" 'c == "" || $1 != c' \
             | sort -t"$TAB" -k3 -rn)
    [ -n "$curline" ] && printf '%s\n' "$curline"
    [ -n "$others" ]  && printf '%s\n' "$others"
}

# 菜单里那一行说明文字：格子 + dBm + 加密。信号未知时不编数字。
fmt_desc() {
    sig=$1; sec=$2
    if [ "$sig" != "?" ] && [ "$sig" -lt 0 ] 2>/dev/null; then
        printf '%s  %sdBm  %s' "$(hr_sig "$sig")" "$sig" "$sec"
    else
        printf '[ ? ]  信号读不到  %s' "$sec"
    fi
}

# ------------------------------------------------------------------ 配置文件

conf_init() {
    [ -f "$CONF" ] && return 0
    mkdir -p "$(dirname "$CONF")"
    {
        echo "# 由 wifi-tui.sh / wifi-connect.sh 使用"
        echo "# 注意：必须用 wpa_supplicant -Dwext（prima 的 nl80211 不完整）"
        echo "ctrl_interface=$CTL"
        echo "ctrl_interface_group=0"
        echo "ap_scan=1"
    } > "$CONF"
    chmod 600 "$CONF"
}

conf_ssids() {
    [ -f "$CONF" ] || return 0
    awk '
        /^[ \t]*network[ \t]*=/ { inb = 1; ssid = ""; next }
        inb && /^[ \t]*ssid[ \t]*=/ {
            v = $0; sub(/^[^=]*=[ \t]*/, "", v)
            gsub(/^"/, "", v); gsub(/"[ \t]*$/, "", v)
            ssid = v
        }
        inb && /^[ \t]*\}/ { if (ssid != "") print ssid; inb = 0; ssid = "" }
    ' "$CONF"
}

conf_keymgmt() {
    [ -f "$CONF" ] || return 0
    awk -v want="$1" '
        /^[ \t]*network[ \t]*=/ { inb = 1; ssid = ""; km = ""; next }
        inb && /^[ \t]*ssid[ \t]*=/ {
            v = $0; sub(/^[^=]*=[ \t]*/, "", v)
            gsub(/^"/, "", v); gsub(/"[ \t]*$/, "", v); ssid = v
        }
        inb && /^[ \t]*key_mgmt[ \t]*=/ {
            v = $0; sub(/^[^=]*=[ \t]*/, "", v); gsub(/[ \t]/, "", v); km = v
        }
        inb && /^[ \t]*\}/ {
            if (ssid == want && km != "") { print km; exit }
            inb = 0
        }
    ' "$CONF"
}

# 删掉指定 SSID 的整个 network 块（保留注释和其它块）
conf_drop() {
    want=$1
    [ -f "$CONF" ] || return 0
    tmp="$CONF.tmp.$$"
    awk -v want="$want" '
        function unq(s) { gsub(/^[ \t]*"/, "", s); gsub(/"[ \t]*$/, "", s); return s }
        /^[ \t]*network[ \t]*=/ { inb = 1; buf = $0 "\n"; hit = 0; next }
        inb {
            buf = buf $0 "\n"
            if ($0 ~ /^[ \t]*ssid[ \t]*=/) {
                v = $0; sub(/^[^=]*=[ \t]*/, "", v)
                if (unq(v) == want) hit = 1
            }
            if ($0 ~ /^[ \t]*\}/) {
                inb = 0
                if (!hit) printf "%s", buf
                buf = ""
            }
            next
        }
        { print }
        END { if (inb && !hit) printf "%s", buf }
    ' "$CONF" > "$tmp" && mv "$tmp" "$CONF"
    chmod 600 "$CONF"
}

# 追加一个 network 块。psk 传 "" 表示开放网络，否则传已渲染好的值
# （64 位 hex PSK，或带引号的明文密码 —— 由调用方决定）。
conf_add() {
    ssid=$1; psk=$2; km=$3
    conf_init
    esc=$(printf '%s' "$ssid" | sed 's/["\\]/\\&/g')
    {
        echo ""
        echo "network={"
        printf '\tssid="%s"\n' "$esc"
        if [ "$km" = "NONE" ]; then
            printf '\tkey_mgmt=NONE\n'
        else
            printf '\tpsk=%s\n' "$psk"
            printf '\tkey_mgmt=WPA-PSK\n'
        fi
        printf '\tscan_ssid=1\n'
        printf '\tpriority=10\n'
        echo "}"
    } >> "$CONF"
    chmod 600 "$CONF"
}

# ------------------------------------------------------------------ 硬件 / 状态

hw_ready()    { [ -e "/sys/class/net/$IFACE" ]; }
iface_up()    { ip link set "$IFACE" up 2>>"$LOG"; }
wpa_running() { pidof wpa_supplicant >/dev/null 2>&1; }
wpa_state()   { wpa_cli -i "$IFACE" status 2>/dev/null | sed -n 's/^wpa_state=//p'; }
link_ssid()   { wpa_cli -i "$IFACE" status 2>/dev/null | sed -n 's/^ssid=//p' | head -1; }
iface_ip()    { ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2; exit}'; }
iface_gw()    { ip route 2>/dev/null | awk '/^default/{print $3; exit}'; }

iface_signal() {
    iwconfig "$IFACE" 2>/dev/null | sed -n 's/.*Signal level=\(-\{0,1\}[0-9]*\).*/\1/p' | head -1
}

# 信号在这块芯片上可能读不到（prima 不填 /proc/net/wireless，iwconfig 不报，
# wpa_cli signal_poll 直接 FAIL）。读不到就返回 "?"，别显示 0 让人以为信号极差。
# 注意：这里必须短。主菜单的标题区宽度有限，长句子会把 dialog 的边框撑破。
sig_text() {
    v=$(iface_signal)
    if [ -n "$v" ] && [ "$v" -lt 0 ] 2>/dev/null; then
        echo "$v dBm"
    else
        echo "?"
    fi
}

ensure_hw() {
    hw_ready && return 0
    [ -x /usr/local/sbin/wifi-connect.sh ] || return 1
    dialog --backtitle "$BT" --infobox "正在初始化 WiFi 硬件（WCNSS/prima）...\n\n约 10-20 秒，请勿中断" 7 56
    /usr/local/sbin/wifi-connect.sh --hw-only >>"$LOG" 2>&1
    hw_ready
}

# 写 resolv.conf。DHCP 下发的是网关，通常就是链路上最靠得住的解析器；
# 第二个放公共 DNS，防网关 DNS 被限速时整体卡死。
sync_dns() {
    gw=$(iface_gw)
    if [ -n "$gw" ]; then
        printf 'nameserver %s\nnameserver 223.5.5.5\n' "$gw" > /etc/resolv.conf
    else
        printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\n' > /etc/resolv.conf
    fi
}

wait_assoc() {
    n=0
    while [ "$n" -lt 25 ]; do
        [ "$(wpa_state)" = "COMPLETED" ] && return 0
        sleep 1
        n=$((n + 1))
    done
    return 1
}

dhcp_get() {
    ip -4 addr flush dev "$IFACE" 2>/dev/null
    udhcpc -i "$IFACE" -n -q -t 8 >>"$LOG" 2>&1 || return 1
    sync_dns
    return 0
}

# 连一个新网络：写配置 -> 重启 wpa_supplicant -> 等关联 -> DHCP
# 返回 0 成功 / 1 关联失败 / 2 DHCP 失败
#
# 失败会自动回滚配置。这一步不是可选的：配置是开机自动连的唯一依据，
# 一次密码输错如果把错凭据留在里面，下次开机就是"连不上且看起来一切正常"，
# 无屏设备上极难自查。回滚后还会用旧配置把原来的网络连回来，别把设备晾在离线状态。
connect_new() {
    ssid=$1; pass=$2; sec=$3
    log "connect_new ssid=[$ssid] sec=$sec"

    bak="$CONF.bak.$$"
    cp "$CONF" "$bak" 2>/dev/null
    chmod 600 "$bak" 2>/dev/null

    conf_drop "$ssid"
    if [ "$sec" = "OPEN" ]; then
        conf_add "$ssid" "" NONE
    else
        # 优先存 64 位 PSK，配置文件里就不留密码原文。
        # wpa_passphrase 对 8~63 字符的密码做 PBKDF2，输出 psk= 后面那串 hex。
        #
        # 注意这里必须用 [[:space:]] 而不是 [ \t]：busybox 的 sed 不把方括号里的
        # \t 当制表符（会当成字面的 t），而 wpa_passphrase 输出的正是制表符缩进。
        # 用错了会静默匹配失败、悄悄退到"存明文"，看起来一切正常。
        hexpsk=$(wpa_passphrase "$ssid" "$pass" 2>/dev/null \
                 | sed -n 's/^[[:space:]]*psk=\([0-9a-f]\{64\}\)[[:space:]]*$/\1/p' | head -1)
        if [ -n "$hexpsk" ]; then
            conf_add "$ssid" "$hexpsk" WPA-PSK
        else
            # 退路：直接存明文（密码里有怪字符时 wpa_passphrase 可能失败）
            escp=$(printf '%s' "$pass" | sed 's/["\\]/\\&/g')
            conf_add "$ssid" "\"$escp\"" WPA-PSK
        fi
    fi

    iface_up
    pkill -f "wpa_supplicant.*$IFACE" 2>/dev/null
    sleep 1
    rm -f "$CTL/$IFACE" 2>/dev/null
    wpa_supplicant -Dwext -B -i "$IFACE" -c "$CONF" >>"$LOG" 2>&1

    if ! wait_assoc; then
        log "关联失败: $(wpa_cli -i "$IFACE" status 2>/dev/null | tr '\n' ' ')"
        connect_rollback "$bak"
        return 1
    fi

    # 关键校验：wpa_supplicant 会从配置里所有 network 中挑一个能连的，
    # 不一定是我们刚写的那个。不校验 SSID 的话，"密码错了但机器上还有
    # 别的可用网络"会被误报成连接成功 —— 用户以为存对了，重启后才发现不对。
    got=$(link_ssid)
    if [ "$got" != "$ssid" ]; then
        log "关联到了 [$got]，但目标是 [$ssid]（凭据可能有误）"
        connect_rollback "$bak"
        return 1
    fi

    if ! dhcp_get; then
        connect_rollback "$bak"
        return 2
    fi

    rm -f "$bak"
    log "连上 ip=$(iface_ip) gw=$(iface_gw)"
    return 0
}

# 把配置还原成连接前的样子，并用它把原来的网络重新连上
connect_rollback() {
    bak=$1
    if [ -f "$bak" ]; then
        mv "$bak" "$CONF"
        chmod 600 "$CONF"
        log "已回滚配置"
        # 用旧配置重启，让设备回到连接前的状态（通常就是之前那个网络）
        pkill -f "wpa_supplicant.*$IFACE" 2>/dev/null
        sleep 1
        rm -f "$CTL/$IFACE" 2>/dev/null
        if [ -s "$CONF" ] && grep -q '^network=' "$CONF"; then
            wpa_supplicant -Dwext -B -i "$IFACE" -c "$CONF" >>"$LOG" 2>&1
            wait_assoc && dhcp_get && log "已恢复原连接: $(link_ssid)"
        fi
    fi
}

# 连配置里已保存的网络：wpa_cli select_network <id>
# 不需要密码（PSK 已在配置里），也不会改动别的 network 块。
connect_saved() {
    ssid=$1
    iface_up

    if ! wpa_running; then
        wpa_supplicant -Dwext -B -i "$IFACE" -c "$CONF" >>"$LOG" 2>&1
        sleep 1
    fi

    id=$(wpa_cli -i "$IFACE" list_networks 2>/dev/null \
         | awk -F'\t' -v s="$ssid" '$2 == s { print $1; exit }')
    if [ -z "$id" ]; then
        log "connect_saved: 配置里找不到 [$ssid]"
        return 1
    fi
    log "connect_saved ssid=[$ssid] network_id=$id"
    wpa_cli -i "$IFACE" select_network "$id" >>"$LOG" 2>&1

    wait_assoc || return 1
    dhcp_get || return 2
    return 0
}

# ------------------------------------------------------------------ 界面

status_text() {
    if ! hw_ready; then
        echo "硬件未就绪（prima 未加载）"
        return
    fi
    if [ "$(wpa_state)" = "COMPLETED" ]; then
        echo "已连接: $(link_ssid)   $(iface_ip)   信号 $(sig_text)"
    else
        echo "未连接（wlan0 在，wpa_state=$(wpa_state)）"
    fi
}

show_status() {
    hw_ready || { msg "wlan0 不存在。\n\n先在主菜单选「重新初始化 WiFi 硬件」。"; return; }
    st=$(wpa_cli -i "$IFACE" status 2>/dev/null)
    [ -z "$st" ] && st="(wpa_supplicant 未运行)"
    sig=$(sig_text)
    sigline="信号    $sig"
    [ "$sig" = "?" ] && sigline="信号    ? （prima 不报 WEXT 统计，读不到属正常）"
    msg "接口    $IFACE
状态    $(wpa_state)
SSID    $(link_ssid)
地址    $(iface_ip)
网关    $(iface_gw)
$sigline
DNS     $(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf 2>/dev/null)

—— wpa_cli status ——
$st" "连接状态"
}

do_scan_connect() {
    ensure_hw || { err "WiFi 硬件起不来。\n\n先看 /var/log/wifi.log，或重新初始化硬件。"; return; }
    iface_up

    dialog --backtitle "$BT" --infobox "正在扫描附近的 WiFi...\n\n约 3-5 秒" 6 48
    aps=$(scan_aps)

    set --
    cnt=0
    while IFS="$TAB" read -r s sec sig bss; do
        [ -z "$s" ] && continue
        cnt=$((cnt + 1))
        set -- "$@" "$s" "$(fmt_desc "$sig" "$sec")"
    done <<EOF
$aps
EOF

    if [ "$cnt" -eq 0 ]; then
        msg "一个都没扫到。\n\n可能原因：\n- 射频刚起来还没稳（等几秒再扫）\n- 附近没有 2.4G 网络（这块芯片不支持 5G）"
        return
    fi

    set -- "$@" "[手动]" "手动输入 SSID（隐藏网络）"
    set -- "$@" "[重扫]" "重新扫描一遍"

    sel=$(dlg --title "选择网络（扫到 $cnt 个）" \
              --menu "格子越满信号越好，最后是加密方式。" 22 72 14 "$@") || return

    case "$sel" in
        "[重扫]") do_scan_connect; return ;;
        "[手动]")
            ssid=$(dlg --title "手动输入" --inputbox "SSID（区分大小写）:" 0 60) || return
            [ -z "$ssid" ] && return
            sec="WPA2"
            ;;
        *)
            ssid="$sel"
            sec=$(printf '%s\n' "$aps" | while IFS="$TAB" read -r s c g b; do
                      [ "$s" = "$ssid" ] && { printf '%s' "$c"; break; }
                  done)
            [ -z "$sec" ] && sec="WPA2"
            ;;
    esac

    pass=""
    if [ "$sec" = "OPEN" ]; then
        ask "「$ssid」是开放网络（无密码）。\n\n直接连？" "开放网络" || return
    elif [ "$sec" = "WEP" ]; then
        msg "「$ssid」用的是 WEP。\n\nprima 在 wext 后端下对 WEP 支持很差，大概率连不上。\n建议换 WPA2 网络。"
        pass=$(dlg --insecure --title "WEP 密钥" --passwordbox "网络: $ssid\n\n输入 WEP 密钥:" 10 60) || return
    else
        pass=$(dlg --insecure --title "输入密码" \
                   --passwordbox "网络: $ssid\n加密: $sec\n\n密码（8-63 字符）:" 12 62) || return
        if [ -z "$pass" ]; then
            ask "密码是空的。\n\n按「是」当作开放网络连，按「否」重来。" "空密码" || return
            sec="OPEN"
        elif [ ${#pass} -lt 8 ]; then
            ask "密码只有 ${#pass} 位，WPA 要求至少 8 位。\n\n仍然试一下？" "密码太短" || return
        fi
    fi

    dialog --backtitle "$BT" --infobox "正在连接 $ssid ...\n\n关联 + 拿地址，约 10-25 秒" 8 56
    connect_new "$ssid" "$pass" "$sec"
    rc=$?

    case "$rc" in
        0) msg "连上了。\n\nSSID    $ssid\n地址    $(iface_ip)\n网关    $(iface_gw)\n信号    $(sig_text)\n\n已写入 $CONF，重启后自动连。" "成功" ;;
        1) err "关联失败。\n\n常见原因：\n- 密码错（最可能）\n- 要求 WPA3 / 802.1X，prima 不支持\n- 信号太弱\n\n日志: /var/log/wifi.log" ;;
        2) err "关联成功，但 DHCP 没拿到地址。\n\n路由器可能关了 DHCP，或地址池满了。" ;;
        *) err "未知错误 rc=$rc，见 /var/log/wifi-tui.log" ;;
    esac
}

do_saved() {
    list=$(conf_ssids)
    if [ -z "$list" ]; then
        msg "配置里还没有保存过网络。\n\n先用「扫描并连接新网络」。"
        return
    fi
    cur=$(link_ssid)
    set --
    while IFS= read -r s; do
        [ -z "$s" ] && continue
        km=$(conf_keymgmt "$s")
        [ -z "$km" ] && km="-"
        if [ "$km" = "NONE" ]; then tag="开放"; else tag="加密"; fi
        mark="  "; [ "$s" = "$cur" ] && mark="* "
        set -- "$@" "$s" "${mark}${tag} (${km})"
    done <<EOF
$list
EOF

    sel=$(dlg --title "已保存的网络" \
              --menu "带 * 的是当前连接。选中后可以连接或删除。" 22 72 14 "$@") || return
    [ -z "$sel" ] && return

    act=$(dlg --title "$sel" --menu "要对这个网络做什么？" 12 56 3 \
               connect "连接它" \
               delete  "从配置里删除" \
               cancel  "返回") || return

    case "$act" in
        connect)
            dialog --backtitle "$BT" --infobox "正在连接 $sel ..." 5 50
            connect_saved "$sel"
            case $? in
                0) msg "已连上 $sel\n\n地址 $(iface_ip)\n网关 $(iface_gw)" "成功" ;;
                1) err "关联失败。\n\n密码可能变了，或热点不在范围内。\n\n可以删掉它重新扫描连接。" ;;
                2) err "关联上了但没拿到 DHCP 地址。" ;;
            esac
            ;;
        delete)
            ask "确定删除「$sel」？\n\n只从配置里移除，不影响其它网络。" "删除" || return
            conf_drop "$sel"
            msg "已删除 $sel"
            ;;
    esac
}

do_disconnect() {
    ask "断开 WiFi？\n\n不插 USB 的话就彻底失联了（只能拔插重启）。\n插着 USB 仍可从 192.168.42.129 进来。" "断开" || return
    pkill -f "wpa_supplicant.*$IFACE" 2>/dev/null
    ip -4 addr flush dev "$IFACE" 2>/dev/null
    ip link set "$IFACE" down 2>/dev/null
    msg "已断开。\n\n要重新连接，从主菜单选「连接已保存的网络」。"
}

do_reinit_hw() {
    ask "重新初始化 WiFi 硬件？\n\n会重走 WCNSS 上电 + prima 加载（约 10-20 秒）。\n已连接的话会短暂断开。" "重新初始化" || return
    pkill -f "wpa_supplicant.*$IFACE" 2>/dev/null
    sleep 1
    dialog --backtitle "$BT" --infobox "正在重新初始化硬件..." 5 50
    out=$(/usr/local/sbin/wifi-connect.sh --hw-only 2>&1)
    if hw_ready; then
        msg "硬件就绪。\n\n$(printf '%s' "$out" | tail -3)" "完成"
    else
        err "初始化失败。\n\n$(printf '%s' "$out" | tail -6)"
    fi
}

# ------------------------------------------------------------------ 入口

case "${1:-tui}" in
    status)
        echo "hw=$(hw_ready && echo ready || echo missing)"
        echo "state=$(wpa_state)"
        echo "ssid=$(link_ssid)"
        echo "ip=$(iface_ip)"
        echo "gw=$(iface_gw)"
        echo "signal=$(iface_signal)"
        exit 0
        ;;
    scan)
        hw_ready || die "wlan0 不存在，先跑 wifi-connect.sh"
        scan_aps
        exit 0
        ;;
    list)
        # 列出配置里已保存的网络：ssid <TAB> key_mgmt
        conf_ssids | while IFS= read -r s; do
            printf '%s\t%s\n' "$s" "$(conf_keymgmt "$s")"
        done
        exit 0
        ;;
    connect)
        # 非交互连接：wifi-tui.sh connect <SSID> [密码]
        # 没有密码参数就当开放网络。成功率与 TUI 里完全一样（走同一个 connect_new）。
        [ -n "${2:-}" ] || die "用法: wifi-tui.sh connect <SSID> [密码]"
        _ssid=$2
        _pass=${3:-}
        ensure_hw || die "硬件未就绪（wifi-connect.sh --hw-only 失败）"
        if [ -z "$_pass" ]; then _sec="OPEN"; else _sec="WPA2"; fi
        connect_new "$_ssid" "$_pass" "$_sec"
        _rc=$?
        if [ "$_rc" -eq 0 ]; then
            echo "OK ip=$(iface_ip) gw=$(iface_gw) ssid=$(link_ssid)"
        else
            echo "失败 rc=$_rc（1=关联失败 2=DHCP 失败），详见 $LOG"
        fi
        exit "$_rc"
        ;;
esac

[ -n "${TERM:-}" ] || die "TERM 没设，dialog 画不出来。用交互式 ssh 登录再跑。"
command -v dialog >/dev/null 2>&1 || die "缺 dialog：apk add dialog"
for c in iw wpa_supplicant wpa_cli udhcpc; do
    command -v "$c" >/dev/null 2>&1 || die "缺 $c"
done

conf_init

if ! hw_ready; then
    if ask "WiFi 硬件还没就绪（prima 驱动未加载）。\n\n现在初始化吗？约 10-20 秒。" "硬件未就绪"; then
        ensure_hw || { err "初始化失败，见 /var/log/wifi.log"; exit 1; }
    else
        exit 0
    fi
fi

while :; do
    choice=$(dlg --title "主菜单" --menu "$(status_text)\n\n选择操作:" 20 72 8 \
        1 "扫描并连接新网络" \
        2 "连接已保存的网络" \
        3 "查看详细状态" \
        4 "断开连接" \
        5 "重新初始化 WiFi 硬件" \
        0 "退出") || exit 0

    case "$choice" in
        1) do_scan_connect ;;
        2) do_saved ;;
        3) show_status ;;
        4) do_disconnect ;;
        5) do_reinit_hw ;;
        0) exit 0 ;;
    esac
done
