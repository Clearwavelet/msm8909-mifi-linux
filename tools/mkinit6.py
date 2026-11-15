#!/usr/bin/env python3
"""构建 v6 原生 Alpine initramfs（cpio newc + gzip）。

只放最小集合：静态 busybox + init 脚本 + 几个空目录。
根文件系统在 cache 分区上，不塞进 ramdisk。

用法:
    python mkinit6.py initramfs6 ../init6-ramdisk.gz
    python mkboot.py --ramdisk ../init6-ramdisk.gz boot-alpine-v6.img
"""
import gzip
import io
import os
import sys

from mkh2 import write_cpio

HERE = os.path.dirname(os.path.abspath(__file__))
BBSRC = os.environ.get("BUSYBOX_STATIC") or os.path.join(HERE, "..", "vendor", "busybox-static")

DIRS = ["bin", "dev", "dev/pts", "dev/shm", "proc", "sys", "tmp", "mnt", "newroot"]

# v8 关键修正：initramfs 里原本只有 /bin/busybox 本体，
# 脚本里裸调 `cat` / `ls` 会直接 command not found（stderr 被吞），
# 所有回读都变成空串 —— v1~v7 的 gadget 状态判断因此全是假数据。
# 这里把常用 applet 补成指向 busybox 的软链接。
APPLETS = [
    "sh", "ash", "cat", "ls", "dd", "cp", "mv", "rm", "ln", "mkdir",
    "mknod", "mdev", "mount", "umount", "sleep", "sync", "switch_root",
    "reboot", "grep", "wc", "tr", "head", "tail", "dmesg", "uname",
    "printf", "find", "chmod", "chroot", "ps", "kill", "vi", "sed", "awk",
]


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    src, out = sys.argv[1], sys.argv[2]

    init = open(os.path.join(src, "init"), "rb").read()
    bb = open(BBSRC, "rb").read()
    print(f"init={len(init)}B  busybox={len(bb)}B")

    entries = [(d, 0o040755, b"", 0, 0) for d in DIRS]
    entries.append(("bin/busybox", 0o100755, bb, 0, 0))
    for a in APPLETS:
        entries.append((f"bin/{a}", 0o120777, b"busybox", 0, 0))
    entries.append(("init", 0o100755, init, 0, 0))

    cpio = write_cpio(entries)
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", compresslevel=9, mtime=0) as gz:
        gz.write(cpio)
    blob = buf.getvalue()
    open(out, "wb").write(blob)
    print(f"wrote {out}  cpio={len(cpio)}  gz={len(blob)}  条目={len(entries)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
