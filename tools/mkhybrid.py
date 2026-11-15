#!/usr/bin/env python3
"""构建混合启动 ramdisk（用于写入 boot 分区）。

策略：以原厂 ramdisk 为基底，保证任何失败路径都能退回 Android。
  * 原厂 /init          -> /init.real（保留原厂 Android init）
  * sbin/ueventd、sbin/watchdogd 这两个 -> /init 的软链接改指 /init.real
    （实测：不改会导致 Android init 拉起 ueventd 时重跑我们的脚本，无限递归死锁）
  * 追加 busybox + applet 软链接（initramfs 里裸调 cat 会 command not found，
    导致所有 sysfs 回读变空串——这个坑踩过整整 7 个版本）
  * /init = 我们的混合 init

用法:
    python mkhybrid.py ../initramfs-hybrid/init ../hybrid-ramdisk.gz
    python mkboot.py --ramdisk ../hybrid-ramdisk.gz boot-hybrid.img
"""
import gzip
import io
import os
import sys

from mkh2 import write_cpio
from mkharness import read_cpio

HERE = os.path.dirname(os.path.abspath(__file__))
STOCK = os.environ.get("STOCK_RAMDISK") or os.path.join(HERE, "..", "vendor", "stock-ramdisk.gz")
BBSRC = os.environ.get("BUSYBOX_STATIC") or os.path.join(HERE, "..", "vendor", "busybox-static")

APPLETS = [
    "sh", "ash", "cat", "ls", "dd", "cp", "mv", "rm", "ln", "mkdir",
    "mknod", "mdev", "mount", "umount", "sleep", "sync", "switch_root",
    "reboot", "grep", "wc", "tr", "head", "tail", "dmesg", "uname",
    "printf", "find", "chmod", "chroot", "ps", "kill", "vi", "sed", "awk",
]

# 早期必需设备节点（原厂 ramdisk 的 dev/ 是空的，由 ueventd 后建）
DEVS = [
    ("dev/console", 0o020600, 5, 1),
    ("dev/null",    0o020666, 1, 3),
    ("dev/zero",    0o020666, 1, 5),
    ("dev/kmsg",    0o020600, 1, 11),
    ("dev/splash",  0o060600, 179, 16),
]


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    init_path, out_path = sys.argv[1], sys.argv[2]

    stock = read_cpio(gzip.decompress(open(STOCK, "rb").read()))
    print(f"原厂 ramdisk 条目: {len(stock)}")
    init = open(init_path, "rb").read()
    bb = open(BBSRC, "rb").read()
    print(f"hybrid init={len(init)}B  busybox={len(bb)}B")

    entries = []
    have_dev = set()
    for name, mode, data in stock:
        if name == "TRAILER!!!":
            continue
        typ = mode & 0o170000
        if name == "init":
            entries.append(("init.real", 0o100750, data, 0, 0))
            print("  /init -> /init.real（保留原厂 init）")
            continue
        if name in ("sbin/ueventd", "sbin/watchdogd") and typ == 0o120000:
            entries.append((name, mode, b"/init.real", 0, 0))
            print(f"  {name}: {data!r} -> b'/init.real'")
            continue
        entries.append((name, mode, data, 0, 0))
        if typ == 0o020000 or typ == 0o060000:
            have_dev.add(name)

    for nm, mode, maj, mn in DEVS:
        if nm not in have_dev:
            entries.append((nm, mode, b"", maj, mn))
            print(f"  + {nm}  ({maj}:{mn})")

    # 必须先建 bin 目录：cpio 里没有父目录条目时，内核解包会静默跳过 bin/*，
    # 导致 /init 的 #!/bin/busybox sh 找不到解释器 -> PID1 exec 失败 -> 内核 panic。
    # v10/v11/mini 三个镜像全部因此失败（设备零 USB 枚举，无任何日志）。
    if "bin" not in {e[0] for e in entries}:
        entries.append(("bin", 0o040755, b"", 0, 0))
        print("  + bin/ 目录条目")

    entries.append(("bin/busybox", 0o100755, bb, 0, 0))
    for a in APPLETS:
        entries.append((f"bin/{a}", 0o120777, b"busybox", 0, 0))
    entries.append(("init", 0o100755, init, 0, 0))
    print(f"  + bin/busybox + {len(APPLETS)} 个 applet 软链接 + /init")

    cpio = write_cpio(entries)
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", compresslevel=9, mtime=0) as gz:
        gz.write(cpio)
    blob = buf.getvalue()
    open(out_path, "wb").write(blob)
    print(f"wrote {out_path}  cpio={len(cpio)}  gz={len(blob)}  条目={len(entries)}")

    # 自检
    back = read_cpio(gzip.decompress(blob))
    names = [e[0] for e in back]
    for must in ("init", "init.real", "bin/busybox", "bin/cat", "dev/console"):
        assert must in names, f"缺少 {must}"
    d = {e[0]: e for e in back}
    assert d["init.real"][1] & 0o111, "init.real 不可执行"
    assert d["init"][1] & 0o111, "init 不可执行"
    for s in ("sbin/ueventd", "sbin/watchdogd"):
        if s in d:
            assert d[s][2] == b"/init.real", f"{s} 未改指 init.real: {d[s][2]!r}"
    # 校验：每个条目的父目录必须已经在它之前出现过（内核顺序解包，缺失会静默跳过）
    seen = set()
    for e in back:
        nm = e[0]
        if nm == "TRAILER!!!":
            break
        if "/" in nm:
            parent = nm.rsplit("/", 1)[0]
            assert parent in seen, f"父目录缺失: {nm} 的父 {parent} 不在归档中"
        seen.add(nm)

    print(f"自检 OK: {len(back)} 条目，末尾={names[-1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
