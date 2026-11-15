#!/usr/bin/env python3
"""harness v2 ramdisk 构建器。

相比 mkharness.py 增加：
  * dev/ 下的设备节点（原厂 ramdisk 的 dev/ 是空的，节点由 ueventd 后建，
    但 /init 阶段它们还不存在 —— 脚本里 `exec 7>/dev/splash` 会因此失败）
  * cpio 写入器支持 rdevmajor/rdevminor

用法:
    python mkh2.py harness-init2.sh ../harness2-ramdisk.gz
    python mkboot.py --ramdisk ../harness2-ramdisk.gz boot-harness2.img
"""
import gzip
import io
import os
import sys

from mkharness import read_cpio

HERE = os.path.dirname(os.path.abspath(__file__))
STOCK = os.environ.get("STOCK_RAMDISK") or os.path.join(HERE, "..", "vendor", "stock-ramdisk.gz")

# 原厂 dev/ 为空；这里补上早期启动必需的节点
# (name, mode, dtype, major, minor)
DEVS = [
    ("dev/console", 0o020600, "c", 5, 1),
    ("dev/null",    0o020666, "c", 1, 3),
    ("dev/zero",    0o020666, "c", 1, 5),
    ("dev/kmsg",    0o020600, "c", 1, 11),
    ("dev/splash",  0o060600, "b", 179, 16),   # mmcblk0p16
]


def pad4(n):
    return (4 - n % 4) % 4


def write_cpio(entries):
    """entries: [(name, mode, data, rdevmajor, rdevminor)]"""
    out = io.BytesIO()
    for ino, (name, mode, data, rmaj, rmin) in enumerate(entries, start=1):
        isdir = (mode & 0o170000) == 0o040000
        namez = name.encode() + b"\x00"
        size = 0 if isdir else len(data)
        h = b"070701"
        h += b"%08X" % ino
        h += b"%08X" % mode
        h += b"%08X" % 0            # uid
        h += b"%08X" % 0            # gid
        h += b"%08X" % (2 if isdir else 1)   # nlink
        h += b"%08X" % 0            # mtime
        h += b"%08X" % size
        h += b"%08X" % 0            # devmajor
        h += b"%08X" % 0            # devminor
        h += b"%08X" % rmaj         # rdevmajor
        h += b"%08X" % rmin         # rdevminor
        h += b"%08X" % len(namez)
        h += b"%08X" % 0            # check
        out.write(h)
        out.write(namez)
        out.write(b"\x00" * pad4(len(h) + len(namez)))
        if size:
            out.write(data)
            out.write(b"\x00" * pad4(size))

    tn = b"TRAILER!!!\x00"
    th = b"070701" + b"%08X" % 0 + b"%08X" % 0 + b"%08X" % 0 + b"%08X" % 0
    th += b"%08X" % 1 + b"%08X" % 0 + b"%08X" % 0
    th += b"%08X" % 0 + b"%08X" % 0 + b"%08X" % 0 + b"%08X" % 0
    th += b"%08X" % len(tn) + b"%08X" % 0
    out.write(th)
    out.write(tn)
    out.write(b"\x00" * pad4(len(th) + len(tn)))
    return out.getvalue()


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    wrapper_path, out_path = sys.argv[1], sys.argv[2]

    raw = gzip.decompress(open(STOCK, "rb").read())
    src = read_cpio(raw)
    print(f"原厂条目: {len(src)}")

    busybox = open(os.environ.get("BUSYBOX_STATIC") or os.path.join(HERE, "..", "vendor", "busybox-static"), "rb").read()
    wrapper = open(wrapper_path, "rb").read()
    print(f"wrapper={len(wrapper)}B  busybox={len(busybox)}B")

    entries = []
    for name, mode, data in src:
        if name in ("TRAILER!!!",):
            continue
        if name == "init":
            name, mode = "init.real", 0o100750
            print("  /init -> /init.real")
        # 关键修复：原厂 sbin/ueventd、sbin/watchdogd 是 -> /init 的软链接。
        # /init 被换成我们的 wrapper 后，Android init 拉起 ueventd 会把 wrapper
        # 再跑一遍（实测 PID=202 argv0=/sbin/ueventd），进而递归 exec，
        # 最终整机死锁。改成指向 /init.real，argv[0] 仍是 /sbin/ueventd，
        # Android init 按 basename 分发，行为与原厂一致。
        if name in ("sbin/ueventd", "sbin/watchdogd") and (mode & 0o170000) == 0o120000:
            print(f"  {name}: {data!r} -> b'/init.real'")
            data = b"/init.real"
        entries.append((name, mode, data, 0, 0))

    names = [e[0] for e in entries]
    if "bin" not in names:
        entries.insert(0, ("bin", 0o040755, b"", 0, 0))
        print("  + bin/")
    if "dev" not in names:
        entries.insert(0, ("dev", 0o040755, b"", 0, 0))
        print("  + dev/")

    for nm, mode, _t, maj, mn in DEVS:
        entries.append((nm, mode, b"", maj, mn))
        print(f"  + {nm}  {_t} {maj}:{mn}")

    entries.append(("bin/busybox", 0o100755, busybox, 0, 0))
    entries.append(("init", 0o100755, wrapper, 0, 0))
    print("  + bin/busybox\n  + init (wrapper)")

    cpio = write_cpio(entries)
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", compresslevel=9, mtime=0) as gz:
        gz.write(cpio)
    blob = buf.getvalue()
    open(out_path, "wb").write(blob)
    print(f"wrote {out_path}  cpio={len(cpio)}  gz={len(blob)}")

    # 自检
    back = read_cpio(gzip.decompress(blob))
    bn = [e[0] for e in back]
    for must in ("init", "init.real", "bin/busybox", "dev/console", "dev/splash"):
        assert must in bn, f"缺少 {must}"
    print(f"自检 OK: 条目 {len(back)}  末尾={bn[-1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
