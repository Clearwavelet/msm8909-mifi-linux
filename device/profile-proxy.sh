# /etc/profile.d/50-proxy.sh
#
# 设备本身没有公网出口。上网靠 PC 端一条 SSH 反向隧道：
#     ssh -R 127.0.0.1:7897:127.0.0.1:7897 root@192.168.42.129
# 把 PC 上的本地代理（Clash/mihomo 的混合端口）递到设备回环上。
# 好处：不改 Windows 防火墙、不装任何东西、不需要管理员权限。
#
# 这里只在隧道真的在听的时候才导出变量，否则 apk 会连不上代理而失败。
if grep -qi '0100007F:1ED9' /proc/net/tcp 2>/dev/null; then
    export http_proxy=http://127.0.0.1:7897
    export https_proxy=$http_proxy
    export ftp_proxy=$http_proxy
    export HTTP_PROXY=$http_proxy
    export HTTPS_PROXY=$http_proxy
fi
