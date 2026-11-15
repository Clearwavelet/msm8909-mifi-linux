# /etc/profile.d/50-proxy.sh
#
# 联网方式的演进（2026-11-16）：
#   WiFi 已打通（WCNSS/prima，见 wifi-connect.sh），设备自己就有默认路由和 DNS，
#   apk / curl 直连即可。代理只在"退回到 SSH 隧道"时才需要，因此这里默认
#   一个代理变量都不导出，避免白白绕一圈 PC。
#
# 隧道模式仍保留备用（PC 不允许共享网络时的兜底）：
#     ssh -R 127.0.0.1:7897:127.0.0.1:7897 -R 127.0.0.1:5353:127.0.0.1:53 root@192.168.42.129
#   手动执行 /usr/local/sbin/net-mode.sh tunnel 后，/run/net-mode 变成 tunnel，
#   本脚本才会把 PC 上的本地代理（mihomo 混合端口）和 DNS 递到设备回环上。
#
# 判据仍带上 7897 是否在听（十六进制 0100007F:1ED9）：隧道断了就不能导出，
# 否则 apk 会连一个死地址然后卡住。
if [ -f /run/proxy-enabled ] && grep -qi '0100007F:1ED9' /proc/net/tcp 2>/dev/null; then
    export http_proxy=http://127.0.0.1:7897
    export https_proxy=$http_proxy
    export ftp_proxy=$http_proxy
    export HTTP_PROXY=$http_proxy
    export HTTPS_PROXY=$http_proxy
    # 支持 all_proxy 的程序（curl/pip/npm 等）默认走 SOCKS5，覆盖面更广。
    # socks5h 表示域名交给代理端解析，避免本地解出 fake-ip 后再被二次解析。
    export all_proxy=socks5h://127.0.0.1:7897
    export ALL_PROXY=$all_proxy

    # 给"不读代理变量"的程序留一条路：px <命令>
    # 必须先清掉上面这些变量 —— proxychains 是劫持 connect() 的，
    # 如果 curl 一边看 all_proxy 去连 7897、一边又被劫持，会自我套娃
    # 直接变成 HTTP 000。这一条是实测踩出来的。
    alias px='env -u http_proxy -u https_proxy -u ftp_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY proxychains4 -q'
else
    # 直连模式（WiFi）：清掉可能从父进程 / sshd SetEnv 继承来的代理设置，
    # 避免流量被无谓地绕进隧道，也避免隧道断了以后连死地址。
    unset http_proxy https_proxy ftp_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
fi
