#!/usr/bin/env python3
"""把 initramfs 目录打成 cpio.gz，并与原厂 kernel + QCDT 重新组装为 boot.img。

原厂镜像布局（已实测）：
    page_size   = 2048
    kernel_size = 7076080  @ 2048         addr 0x80008000
    ramdisk     = 583119   @ 7079936      addr 0x81000000
    QCDT        = 5675008  @ 7663616      (second 区，dt_size=0x569800)
    tags_addr   = 0x80000100

用法：
    python mkboot.py <initramfs_dir> <out_boot.img>
"""
import gzip
import hashlib
import io
import os
import stat
import struct
import sys

# 原厂 boot 镜像来源：优先 STOCK_BOOT 环境变量（建议用自己设备 dump 出的 boot 分区），
# 否则回退到仓库内的 boot-hybrid-v13.img —— 它的 kernel / QCDT / cmdline 均与原厂一致。
ORIG = os.environ.get("STOCK_BOOT") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "images", "boot-hybrid-v13.img")
PAGE = 2048


def pad4(n):
    return (4 - (n % 4)) % 4


def cpio_trailer():
    """newc 结尾标记。c_namesize 必须是 len("TRAILER!!!\\0")=12，
    填 0 会让内核读不到结束标记，越过末尾解析垃圾 → 解包失败 → panic。"""
    name = b"TRAILER!!!\x00"
    hdr = b"070701"
    hdr += b"%08X" % 0            # ino
    hdr += b"%08X" % 0            # mode
    hdr += b"%08X" % 0            # uid
    hdr += b"%08X" % 0            # gid
    hdr += b"%08X" % 1            # nlink
    hdr += b"%08X" % 0            # mtime
    hdr += b"%08X" % 0            # filesize
    hdr += b"%08X" % 0            # devmajor
    hdr += b"%08X" % 0            # devminor
    hdr += b"%08X" % 0            # rdevmajor
    hdr += b"%08X" % 0            # rdevminor
    hdr += b"%08X" % len(name)    # namesize
    hdr += b"%08X" % 0            # check
    return hdr + name + b"\x00" * pad4(len(hdr) + len(name))


def verify_cpio(cpio):
    """自检：必须能完整解析、最后一条必须是 TRAILER!!!"""
    p = 0
    names = []
    while cpio[p:p + 6] in (b"070701", b"070702"):
        f = [int(cpio[p + 6 + i * 8:p + 14 + i * 8], 16) for i in range(13)]
        size, nsz = f[6], f[11]
        hp = p + 110
        name = cpio[hp:hp + nsz - 1].decode("utf8", "replace")
        dp = (hp + nsz + 3) & ~3
        p = (dp + size + 3) & ~3
        names.append(name)
        if name == "TRAILER!!!":
            break
    assert names and names[-1] == "TRAILER!!!", "cpio 结尾标记无效: %r" % (names[-1:] or None)
    assert p <= len(cpio), "cpio 越界"
    return names


def write_cpio_newc(entries, out):
    """entries: [(name, mode, data_or_None_for_dir)]"""
    ino = 1
    for name, mode, data in entries:
        namez = name.encode() + b"\x00"
        if data is None:  # 目录
            size = 0
            payload = b""
            nlink = 2
        else:
            size = len(data)
            payload = data
            nlink = 1
        hdr = b"070701"
        hdr += b"%08X" % ino
        hdr += b"%08X" % mode
        hdr += b"%08X" % 0          # uid
        hdr += b"%08X" % 0          # gid
        hdr += b"%08X" % nlink
        hdr += b"%08X" % 0          # mtime（置 0 保证可复现）
        hdr += b"%08X" % size
        hdr += b"%08X" % 0          # devmajor
        hdr += b"%08X" % 0          # devminor
        hdr += b"%08X" % 0          # rdevmajor
        hdr += b"%08X" % 0          # rdevminor
        hdr += b"%08X" % len(namez)
        hdr += b"%08X" % 0          # check
        out.write(hdr)
        out.write(namez)
        out.write(b"\x00" * pad4(len(hdr) + len(namez)))
        if payload:
            out.write(payload)
            out.write(b"\x00" * pad4(size))
        ino += 1
    out.write(cpio_trailer())


def build_initramfs(root_dir):
    # 注意：不要写 "." 条目。原厂 ramdisk 也没有；内核 sys_mkdir(".") 会 EEXIST，
    # 触发 initramfs 的 error() → 解包判失败 → panic。
    entries = []
    for dirpath, dirnames, filenames in os.walk(root_dir):
        dirnames.sort()
        filenames.sort()
        rel = os.path.relpath(dirpath, root_dir).replace("\\", "/")
        if rel != ".":
            entries.append((rel, stat.S_IFDIR | 0o755, None))
        for fn in filenames:
            full = os.path.join(dirpath, fn)
            ap = os.path.relpath(full, root_dir).replace("\\", "/")
            with open(full, "rb") as fh:
                data = fh.read()
            # Windows 上 exec 位不可靠，按位置显式判定
            base = os.path.basename(full)
            parent = os.path.basename(dirpath)
            execish = (base in ("init", "busybox")
                       or base.endswith(".sh")
                       or parent in ("bin", "sbin", "usr"))
            perm = 0o755 if execish else 0o644
            entries.append((ap, stat.S_IFREG | perm, data))
    raw = io.BytesIO()
    write_cpio_newc(entries, raw)
    cpio = raw.getvalue()
    names = verify_cpio(cpio)
    print(f"cpio 条目 {len(names)}，结尾 {names[-1]}")
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", compresslevel=9, mtime=0) as gz:
        gz.write(cpio)
    return buf.getvalue(), cpio


def main():
    # 用法：
    #   mkboot.py <initramfs_dir> <out.img>
    #   mkboot.py --ramdisk <ramdisk.gz> <out.img>     # 原样使用给定 ramdisk（用于 A/B 对照）
    raw_ramdisk = None
    args = sys.argv[1:]
    if len(args) == 3 and args[0] == "--ramdisk":
        raw_ramdisk = args[1]
        out_path = args[2]
        root = None
    elif len(args) == 2:
        root, out_path = args[0], args[1]
    else:
        print(__doc__)
        return 1

    orig = open(ORIG, "rb").read()
    f = struct.unpack("<10I", orig[8:48])
    ksize, kaddr, rsize, raddr, _, saddr, taddr, page, dtsize, _ = f
    assert page == PAGE, "page size 不符"
    kernel = orig[PAGE:PAGE + ksize]
    ridx = orig.find(b"QCDT")
    qcdt = orig[ridx:ridx + dtsize]
    cmdline = orig[64:576].split(b"\x00")[0]

    if raw_ramdisk:
        with open(raw_ramdisk, "rb") as fh:
            ramdisk = fh.read()
        cpio = b"(given verbatim)"
        print(f"ramdisk {len(ramdisk)} bytes (verbatim from {raw_ramdisk})")
        print(f"  与原厂 ramdisk 字节一致: {ramdisk == orig[PAGE + ((ksize + PAGE - 1)//PAGE)*PAGE :][:len(ramdisk)]}")
    else:
        ramdisk, cpio = build_initramfs(root)
        print(f"cpio    {len(cpio)} bytes")
        print(f"ramdisk {len(ramdisk)} bytes (gzip)")
    print(f"kernel  {ksize} bytes")
    print(f"qcdt    {len(qcdt)} bytes")

    sha = hashlib.sha1()
    sha.update(kernel)
    sha.update(struct.pack("<I", len(kernel)))
    sha.update(ramdisk)
    sha.update(struct.pack("<I", len(ramdisk)))
    sha.update(struct.pack("<I", 0))
    sha.update(qcdt)
    sha.update(struct.pack("<I", len(qcdt)))
    img_id = sha.digest()          # SHA1 = 20 字节

    hdr = b"ANDROID!"
    hdr += struct.pack("<10I", len(kernel), kaddr, len(ramdisk), raddr,
                       0, saddr, taddr, page, len(qcdt), 0)
    hdr += b"\x00" * 16
    hdr += cmdline.ljust(512, b"\x00")
    # id 字段必须是完整 20 字节 SHA1，后跟 12 字节 0（共 32 字节）。
    # 只写前 8 字节时 LK 会因哈希不符拒绝引导。
    hdr += img_id.ljust(32, b"\x00")
    hdr = hdr.ljust(page, b"\x00")

    def align(b):
        return b + b"\x00" * ((page - len(b) % page) % page)

    blob = hdr + align(kernel) + align(ramdisk) + align(qcdt)
    with open(out_path, "wb") as fh:
        fh.write(blob)
    print(f"wrote {out_path}  {len(blob)} bytes ({len(blob)/1048576:.2f} MiB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
