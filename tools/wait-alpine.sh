#!/usr/bin/env bash
# 上电后判定：出现 RNDIS = 原生 Alpine 启动成功；adb 回来 = 兜底回了 Android
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
export MSYS_NO_PATHCONV=1
# adb 位置：优先用 ADB_DIR，否则取 PATH 里的 adb
_d=""; if [ -n "${ADB_DIR:-}" ]; then _d="$ADB_DIR"; elif command -v adb >/dev/null 2>&1; then _d="$(dirname "$(command -v adb)")"; fi
[ -n "$_d" ] && export PATH="$PATH:$_d"
KEY="${DEV_KEY:-$HOME/.ssh/xj19_ed25519}"
KEY="$(cygpath -w "$KEY" 2>/dev/null || echo "$KEY")"

adbs() { adb devices 2>/dev/null | tr -d '\r' | grep -v "List of" | grep -v '^$'; }
rndis() {
    local v
    v=$(powershell -NoProfile -Command "[Console]::WriteLine((@(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { \$_.InterfaceDescription -like '*NDIS*' })).Count)" 2>/dev/null | tr -d '\r\n ')
    case "$v" in ''|*[!0-9]*) echo -1 ;; *) echo "$v" ;; esac
}

echo "=== 等待上电（最多 480 秒）==="
res=""
for i in $(seq 1 80); do
    n=$(rndis)
    if [ "$n" -ge 1 ] 2>/dev/null; then res=alpine; echo "  +$((i*4))s RNDIS 网卡出现 (count=$n)"; break; fi
    if [ -n "$(adbs)" ]; then res=android; echo "  +$((i*4))s adb 回来"; break; fi
    sleep 4
done

echo
if [ "$res" = "alpine" ]; then
    echo "=== 原生 Alpine 已启动，等待网络就绪后 SSH ==="
    for t in $(seq 1 15); do
        out=$(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                   -o ConnectTimeout=6 -o BatchMode=yes root@192.168.42.129 \
                   'uname -r; cat /etc/alpine-release; cat /proc/1/comm; cat /proc/uptime' 2>&1)
        case "$out" in
            *3.10.49*) echo "  +$((t*5))s SSH 成功"; echo "$out" | sed 's/^/    /'; break ;;
        esac
        sleep 5
    done
    echo
    echo "=== 系统状态 ==="
    ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
        root@192.168.42.129 'echo "根文件系统:"; df -h / | tail -1; echo "启动计数: $(cat /cache/boot.count 2>/dev/null)"; echo "进程:"; ps | grep -E "sshd|udhcpd" | grep -v grep; echo "内存:"; free -m | sed -n 2p' 2>&1 | sed 's/^/    /'
    echo
    echo "==> 持久化成功：每次上电都直接进原生 Alpine"
elif [ "$res" = "android" ]; then
    echo "=== 兜底生效，设备在 Android（未变砖）==="
    adb exec-out "dd if=/dev/block/bootdevice/by-name/boot bs=4096 count=8 2>/dev/null" > "$HERE/boot-head.bin" 2>/dev/null
    python - <<PY
d=open(r"$HERE/boot-head.bin","rb").read()
print("    boot 分区头:", d[:8], " 大小前 48B:", d[:48].hex()[:32])
PY
else
    echo "!! 480s 内既无 RNDIS 也无 adb。请再拔插一次（会触发 boot.count 计数，累计 3 次自动回 Android）"
fi
