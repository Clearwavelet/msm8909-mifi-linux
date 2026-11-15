#!/usr/bin/env bash
# 从源码重建 boot 镜像。
#
#   ./build.sh hybrid            -> build/boot-hybrid.img
#   ./build.sh hybrid out.img    -> 指定输出
#   ./build.sh native            -> 只用 initramfs/native/init（会被 mkh2 当作 wrapper，
#                                   所以 native 变体建议直接改 hybrid/init 里的分支）
#
# 依赖（都在仓库里，不需要额外下载）：
#   vendor/stock-ramdisk.gz   原厂 ramdisk，提供 /init.real 等需要保留的条目
#   vendor/busybox-static     armv7 静态 busybox，作为 initramfs 里的解释器
#   images/boot-hybrid-v13.img  提供 kernel / QCDT / cmdline（可用 STOCK_BOOT 覆盖）
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
VARIANT="${1:-hybrid}"
OUT="${2:-$HERE/../build/boot-$VARIANT.img}"
INIT="$HERE/../initramfs/$VARIANT/init"

[ -f "$INIT" ] || { echo "!! 找不到 $INIT"; exit 1; }

PY=python3
command -v python3 >/dev/null 2>&1 || PY=python

mkdir -p "$(dirname "$OUT")"
TMP="${TMPDIR:-/tmp}/xj19-ramdisk-$VARIANT.gz"

echo "=== 1/2 打 ramdisk（保留原厂条目 + 注入 init） ==="
"$PY" "$HERE/mkh2.py" "$INIT" "$TMP"

echo
echo "=== 2/2 与原厂 kernel/QCDT 组装 boot.img ==="
"$PY" "$HERE/mkboot.py" --ramdisk "$TMP" "$OUT"

echo
echo "产物: $OUT"
ls -l "$OUT"
md5sum "$OUT" 2>/dev/null || true
