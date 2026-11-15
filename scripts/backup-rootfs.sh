#!/usr/bin/env bash
# 把设备的 Alpine 根文件系统（cache 分区 mmcblk0p23）备份到 PC，双份：
#   1) rootfs-<日期>.tar.gz   可检视/可局部还原的归档
#   2) cache-<日期>.img.gz    p23 裸镜像，灾难恢复时一条 fastboot flash cache 复活
#
# 用法: ./backup-rootfs.sh [输出目录，默认 ../backup]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/../backup}"
KEY="$(cygpath -w "$HERE/alpine/id_alpine" 2>/dev/null || echo "$HERE/alpine/id_alpine")"
IP="${DEV_IP:-192.168.42.129}"
export MSYS_NO_PATHCONV=1
SSHO=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -o ServerAliveInterval=10)
DATE=$(date +%Y%m%d-%H%M)
mkdir -p "$OUT"

echo "=== 连通性检查 ==="
ssh "${SSHO[@]}" root@"$IP" 'echo ok' >/dev/null 2>&1 || { echo "设备不可达"; exit 1; }

# 顶层的挂载点不能进 tar（/proc /sys /dev /run 是内核的，/cache /data /home /mnt 是别的分区）
echo "=== 1/2 打包 tar ==="
INCL=$(ssh "${SSHO[@]}" root@"$IP" 'for d in $(ls -A /); do case "$d" in proc|sys|dev|run|mnt|cache|data|home|tmp) ;; *) printf "%s " "$d";; esac; done')
echo "  顶层条目: $INCL"
TAR="$OUT/rootfs-$DATE.tar.gz"
ssh "${SSHO[@]}" root@"$IP" "tar -cf - -C / $INCL 2>/dev/null | gzip -1" > "$TAR"
sz=$(wc -c < "$TAR")
if [ "$sz" -lt 1000000 ]; then echo "  ✗ tar 太小（$sz 字节），可能失败"; exit 1; fi
echo "  ✓ $(basename "$TAR")  $((sz/1024/1024)) MB"
echo "  条目数: $(gzip -dc "$TAR" | tar -tf - 2>/dev/null | wc -l)"

echo "=== 2/2 裸镜像 p23（256 MB，压缩后传）==="
IMG="$OUT/cache-$DATE.img.gz"
ssh "${SSHO[@]}" root@"$IP" 'dd if=/dev/mmcblk0p23 bs=1M 2>/dev/null | gzip -1' > "$IMG"
isz=$(wc -c < "$IMG")
echo "  ✓ $(basename "$IMG")  $((isz/1024/1024)) MB"
echo "  原始大小: $(gzip -dc "$IMG" 2>/dev/null | wc -c) 字节（应为 268435456）"

echo "=== 校验和 ==="
( cd "$OUT" && md5sum "$(basename "$TAR")" "$(basename "$IMG")" | tee md5-$DATE.txt )
echo
echo "备份目录: $OUT"
echo "恢复办法见 dev/RECOVERY.md"
