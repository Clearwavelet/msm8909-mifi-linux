#!/usr/bin/env python3
"""无损改造原厂 ramdisk：保留全部条目（含符号链接/权限），
把 /init 改名为 /init.real，插入 wrapper /init 和静态 busybox。

用法：
    python mkharness.py <wrapper_script> <out_ramdisk.gz>
然后：
    python mkboot.py --ramdisk <out_ramdisk.gz> boot-harness.img
"""
import gzip
import io
import os
import sys

STOCK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "stock-ramdisk.gz")


def read_cpio(raw):
    """解析 newc cpio，返回 [(name, mode, data)]，data 为 bytes（目录为空）。"""
    entries = []
    p = 0
    while raw[p:p + 6] in (b"070701", b"070702"):
        f = [int(raw[p + 6 + i * 8:p + 14 + i * 8], 16) for i in range(13)]
        mode, fsize, nsz = f[1], f[6], f[11]
        hp = p + 110
        name = raw[hp:hp + nsz - 1].decode("utf8", "replace")
        dp = (hp + nsz + 3) & ~3
        data = raw[dp:dp + fsize]
        p = (dp + fsize + 3) & ~3
        if name == "TRAILER!!!":
            entries.append([name, mode, data])
            break
        entries.append([name, mode, data])
    return entries


def pad4(n):
    return (4 - n % 4) % 4


def write_cpio(entries):
    out = io.BytesIO()
    ino = 1
    for name, mode, data in entries:
        isdir = (mode & 0o170000) == 0o040000
        namez = name.encode() + b"\x00"
        size = 0 if isdir else len(data)
        hdr = b"070701"
        hdr += b"%08X" % ino
        hdr += b"%08X" % mode
        hdr += b"%08X" % 0     # uid
        hdr += b"%08X" % 0     # gid
        hdr += b"%08X" % (2 if isdir else 1)
        hdr += b"%08X" % 0     # mtime
        hdr += b"%08X" % size
        hdr += b"%08X" % 0     # devmajor
        hdr += b"%08X" % 0     # devminor
        hdr += b"%08X" % 0     # rdevmajor
        hdr += b"%08X" % 0     # rdevminor
        hdr += b"%08X" % len(namez)
        hdr += b"%08X" % 0     # check
        out.write(hdr)
        out.write(namez)
        out.write(b"\x00" * pad4(len(hdr) + len(namez)))
        if size:
            out.write(data)
            out.write(b"\x00" * pad4(size))
        ino += 1
    trailer_name = b"TRAILER!!!\x00"
    thdr = b"070701"
    thdr += b"%08X" % 0                  # ino
    thdr += b"%08X" % 0                  # mode
    thdr += b"%08X" % 0                  # uid
    thdr += b"%08X" % 0                  # gid
    thdr += b"%08X" % 1                  # nlink
    thdr += b"%08X" % 0                  # mtime
    thdr += b"%08X" % 0                  # filesize
    thdr += b"%08X" % 0                  # devmajor
    thdr += b"%08X" % 0                  # devminor
    thdr += b"%08X" % 0                  # rdevmajor
    thdr += b"%08X" % 0                  # rdevminor
    thdr += b"%08X" % len(trailer_name)  # namesize（必须为 12）
    thdr += b"%08X" % 0                  # check
    out.write(thdr)
    out.write(trailer_name)
    out.write(b"\x00" * pad4(len(thdr) + len(trailer_name)))
    return out.getvalue()


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    wrapper_path, out_path = sys.argv[1], sys.argv[2]

    raw = gzip.decompress(open(STOCK, "rb").read())
    entries = read_cpio(raw)
    print(f"原厂条目: {len(entries)}")

    wrapper = open(wrapper_path, "rb").read()
    busybox = open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "alpine", "busybox-static"), "rb").read()
    print(f"wrapper: {len(wrapper)} bytes   busybox: {len(busybox)} bytes")

    changed = False
    names = [e[0] for e in entries]
    if "init" in names:
        idx = names.index("init")
        entries[idx][0] = "init.real"
        changed = True
        print("  /init -> /init.real")

    # 需要 bin/ 目录
    if "bin" not in names:
        entries.insert(0, ["bin", 0o040755, b""])
        print("  + bin/")
    # 去掉可能冲突的同名项，再追加
    # 去掉结尾标记与待替换项，追加新内容；结尾标记由 write_cpio 统一补
    entries = [e for e in entries
               if e[0] not in ("TRAILER!!!", "init", "init.real.harness")]
    entries.append(["bin/busybox", 0o100755, busybox])
    entries.append(["init", 0o100755, wrapper])
    print("  + bin/busybox")
    print("  + init (wrapper)")

    if not changed:
        print("!! 警告：原厂 ramdisk 里没有 init")

    cpio = write_cpio(entries)
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", compresslevel=9, mtime=0) as gz:
        gz.write(cpio)
    blob = buf.getvalue()
    open(out_path, "wb").write(blob)
    print(f"wrote {out_path}  cpio={len(cpio)}  gz={len(blob)}")

    # 自检：重新读回，必须能完整解析且结尾标记有效
    back = read_cpio(gzip.decompress(blob))
    bn = [e[0] for e in back]
    assert "init" in bn and "init.real" in bn and "bin/busybox" in bn, "改造后条目缺失"
    print(f"自检: 条目 {len(back)}  init=OK  init.real=OK  busybox=OK  末尾={bn[-1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
