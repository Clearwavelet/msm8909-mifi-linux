# vendor/

构建 `boot.img` 所需要的两个二进制输入。都来自设备自身或 Alpine 官方仓库，可自由再分发。

| 文件 | 大小 | 来源 | 作用 |
|---|---|---|---|
| `stock-ramdisk.gz` | 583 KB | 从设备 boot 分区解出（`mkboot.py` 的逆过程，或 `boot-backup.img` 里挖） | `mkh2.py` / `mkhybrid.py` 用它保留原厂条目——最关键的是 `/init.real`，退回 Android 就靠它 |
| `busybox-static` | 886 KB | Alpine `busybox-static` 包的 armv7 ELF（`apk add busybox-static` 后从 `/bin/busybox.static` 取出） | initramfs 里没有 libc，所有命令都靠这个静态二进制；`bin/busybox` 被 `init` 通过 shebang 调用 |

校验：

```
bb206417baa5c062a451b8405a7091e3  busybox-static
792eaf85d958c07f257b29b5ec69e5c0  stock-ramdisk.gz
```

被 `mkboot.py` 当作 kernel / QCDT 来源的 `images/boot-hybrid-v13.img` 里的 kernel 与 QCDT
与原厂 boot 分区逐字节一致（这是当初校验过的），所以不需要额外保存原厂 33 MB 的完整镜像。
如果你要用自己设备的镜像，设 `STOCK_BOOT=/path/to/your-boot.img` 即可。
