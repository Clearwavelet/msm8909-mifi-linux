# XJ19 —— MSM8909 棒子上的原生 Alpine Linux

一根停产的 4G dongle（MEIG 模组，高通 MSM8909），不带电池/屏幕/按键，原厂是 Android 5.1.1。
现在它跑的是**真正的原生 Linux**：Alpine 3.24.4 + musl + OpenRC，内核是原厂 3.10.49（没换内核，
所以所有外设驱动都是原厂的）。启动镜像写在 boot 分区，配置和文件都在 cache 分区上，掉电不丢。

## 三十秒上手

```bash
# 插上 USB（这就是开机；拔掉就是关机）
scripts/dev.sh                # 交互 shell，自动带代理隧道 + 校时
scripts/dev.sh cmd 'uname -a' # 跑一条命令
```

设备固定地址 `192.168.42.129`，Windows 侧会出现 "Remote NDIS based Internet Sharing Device"。

## 这台机器现在是什么样

| 项 | 值 |
|---|---|
| 内核 | Linux 3.10.49 armv7l（4×Cortex-A7，原厂内核未替换） |
| 发行版 | Alpine 3.24.4 / musl / OpenRC / busybox init |
| 根 | `/dev/mmcblk0p23` ext4，248 MB，用 33 MB |
| 数据 | `/dev/mmcblk0p29` ext4，1.3 GB，挂 `/data`；`/home` 绑到 `/data/home` |
| 内存 | 383 MB，用 27 MB |
| 服务 | `udhcpd`（给 PC 发地址）+ `sshd`（密钥或密码登录，密码 `password`，仅绑 RNDIS 地址） |
| 包管理 | `apk`，27112 个包可用（需要隧道） |

装好并验证过的包：`tzdata`、`curl`、`htop`；时区 `Asia/Shanghai`。

## 上外网：SSH 反向隧道

设备没有公网出口，它自己是 DHCP 服务器，PC 是客户端。所以**不能**用 Windows ICS
（会和设备的 udhcpd 抢 DHCP），也**不能**直接在 PC 上开代理服务器（Windows 防火墙入站全拦，
连 ping 都不通）。正确做法是让 PC 主动把连接建到设备上，再用反向隧道把 PC 的本地代理递进去：

```
ssh -R 127.0.0.1:7897:127.0.0.1:7897 root@192.168.42.129
```

PC 上跑着 Clash/mihomo（本地 7897），设备于是有了一个 `127.0.0.1:7897` 的代理。
好处：不动防火墙、不装软件、不要管理员权限。`scripts/dev.sh` 会把这一切自动做好。

设备侧 `/etc/profile.d/50-proxy.sh` 只在检测到 `/proc/net/tcp` 里真有 `127.0.0.1:7897`
监听时才导出 `http_proxy`，所以没开隧道时不会把 apk 卡死。

## 时间

板子没有 RTC 备电，上电永远是 1970。对策是两层：
- `/cache/.last_time` 存上次已知 UTC，`boot-native.sh` 在**挂载 /cache 之后**用它做残影恢复
  （这个顺序踩过坑：放在挂载之前会静默失效）
- `dev.sh` 每次连接都用 PC 时间精确校时，并回写残影

## 开机/关机和"重启"

- 开机 = 插 USB；关机 = 拔 USB
- **`reboot` / `poweroff` 在这块板子上等于断电，不会自己回来**，必须人工拔插
- 无屏无键：唯一通道是 RNDIS 网卡上的 SSH

## 文件地图

| 路径 | 作用 |
|---|---|
| `scripts/dev.sh` | 主力入口：隧道 + 校时 + shell（`cmd` / `up` 子命令） |
| `scripts/deploy-native.sh` | 把 `device/` 下的配置幂等推送到设备 |
| `scripts/backup-rootfs.sh` | 双份备份：tar 归档 + cache 分区裸镜像 |
| `scripts/status.sh` | 一页体检报告：时间/挂载/空间/网卡/服务/安全网/sshd 配置 |
| `scripts/verify-persist.sh` | 冷启动后逐项判定挂载/时间/计数/代理 |
| `docs/RECOVERY.md` | 三级恢复手册（配置 → 根文件系统 → boot 分区） |
| `docs/SSH-CLIENT.md` | MobaXterm / PuTTY / WinSCP 连接配法，密钥清单与兼容性坑 |
| `device/` | 设备侧配置的**唯一源头**，改这里再 deploy |
| `images/boot-hybrid-v13.img` | **现役启动镜像**：默认进 Alpine，有标志则进 Android；已固定 RNDIS MAC |
| `../images/boot-hybrid-v13.img` | 上一版（MAC 随机），作为回退保留 |
| `<你自己 dump 的原厂 boot>` | 原厂 boot 备份，33554432 字节，md5 `4a88b02797f7dad80ae09db1767c0167` |
| `tools/mkh2.py` | 打包 initramfs 用（注意：`mkhybrid.py` 有历史缺陷，别用） |
| `backup/` | 备份产物（tar / 裸镜像 / md5） |

## 启动链路

```
bootloader
  → kernel + initramfs（混合镜像，14 MB）
     挂 cache → 检查 .boot-android 标志 / 失败计数 → 配 RNDIS gadget → switch_root
  → Alpine /sbin/init（busybox，读 /etc/inittab）
     ::sysinit:/bin/sh /boot-native.sh    ← 挂 /cache、恢复时间、挂 /data、
                                            配 rndis0、起 udhcpd + sshd、清零计数
     ::sysinit:/sbin/openrc sysinit / boot
     ::wait:/sbin/openrc default
```

没有 getty（没 VT，RNDIS 模式下也没启用 ACM 串口）。

## 安全网

- initramfs 每次启动 `boot.count++`；Alpine 侧 sshd 起来后清零
- 连续 3 次没能进 Alpine → 自动回 Android（`.boot-android` 标志同理）
- 两个文件都在 cache 分区**根目录**（`/cache/`），因为 Alpine 根就是这块分区
- 回 Android：`touch /cache/.boot-android`，然后拔插

## 已知限制（都是确认过的，不是猜测）

- 无默认路由——上外网只能走 `dev.sh` 的隧道
- 内核没有 `CONFIG_WATCHDOG` / pstore / `CONFIG_FHANDLE` / `CONFIG_DEVTMPFS`，
  所以没有崩溃日志、不能用 systemd、`/dev` 靠 `mdev -s` 反生成
- `/hp`、`/hs`、`/mnt` 是 `switch_root` 留下的僵尸挂载：`/proc/mounts` 里看得见但路径 lookup 返回 ENOTDIR，
  无法 umount，只能靠重启清（而且下次启动 initramfs 又会造出来）。无害，不修
- 连带的**显示问题**：`df` 里根分区显示成 `/nd/cache on /mnt` —— `/nd/cache` 是 initramfs 里手工
  `mknod` 创建的设备节点名，`switch_root` 后该路径消失，`df` 照抄了当时的挂载源字符串。
  实际磁盘就是 `mmcblk0p23`（248 MB），与 `/cache` 是同一块，看 size 就能对上
- OpenRC 各 runlevel 基本是空的，服务由 `boot-native.sh` 手动拉起
- 板载 WiFi 未打通，见下

## 已完成：固定 RNDIS MAC（v13 已烧写并验证）

原问题：内核每次启动给网卡**随机生成 MAC**（实测两次是 `02:FF:7E:F3:C3:52`、`02:82:E6:65:57:E7`）。
Windows 按 MAC 区分网络设备，每开一次机就多一个"以太网 N"适配器，IP 配置和防火墙规则也各建一份。

修法只有一处：在 initramfs 里 `enable=1` **之前**写 `f_rndis/ethaddr`（使能后再改会触发重新枚举）。
旁证：原厂 `init.rc` 自己就有 `chown system system /sys/class/android_usb/android0/f_rndis/ethaddr`。

v13 的分段校验（只有 ramdisk 变了，内核和 38 个 DTB 一个字节没动）：

| 段 | 原厂 | v12 | v13 |
|---|---|---|---|
| kernel md5 | `7aa6f0b774364da2` | 同 | **同** |
| QCDT/DTB md5 | `9e2b9487cb07363e` | 同 | **同** |
| ramdisk | 583 KB | 1.21 MB | 1.21 MB（+304 B） |

烧写与验证结果（已完成）：

- 设备内 `dd if=/data/recovery/boot-v13.img of=/dev/mmcblk0p20 bs=1M conv=fsync`
- 回读校验逐字节一致：`df82151ffa40983a5dd5ea9a4b15eae7`；boot 分区前 16 KB 由
  `d2aa8b2c…`（v12）变为 `1f0e946b…`（v13）
- 冷启动后 `f_rndis/ethaddr = 02:1a:7d:da:71:19`，**Windows 侧看到的适配器 MAC 也是 `02-1A-7D-DA-71-19`**

一点容易看错的地方：`/sys/class/net/rndis0/address` 仍然是每次随机（如 `2e:16:fc:f0:f3:e7`），
那是内核给设备侧接口分配的本机地址，不走 RNDIS OID，**与 Windows 识别无关**。
判断修复是否生效要看 Windows 侧 `Get-NetAdapter` 的 `MacAddress`，或设备上的 `f_rndis/ethaddr`。

回退（不需要 fastboot，设备里就有镜像）：`/data/recovery/` 下有 `boot-v12.img`、`boot-v13.img`
和中文说明 `README-A.txt`；在 Alpine 里 `dd if=/data/recovery/boot-v12.img of=/dev/mmcblk0p20 bs=1M`，或在 Android 里用 `/dev/block/bootdevice/by-name/boot`。

## 板载 WiFi（WCNSS）——已暂停

能走到哪一步都验证过了：

- 固件 `wcnss.mdt` + `wcnss.b00~b12` 在 `mmcblk0p1`（modem 分区）`image/` 下，已拷到 `/lib/firmware`
- 射频校准 `WCNSS_qcom_wlan_nv.bin` 在 `mmcblk0p22`（`/persist`），已拷到 `/etc/firmware/wlan/prima/`
- 驱动模块 `pronto_wlan.ko` 在 `mmcblk0p21`（system 分区），vermagic 与运行内核完全一致
- `echo 1 > /dev/wcnss_wlan` 能唤醒芯片：`state` 由 `OFFLINE`→`ONLINE`，
  日志有 `wcnss: loading from 0x8d500000 to 0x8d9fb000` / `Brought out of reset` / `Power/Clock ready interrupt received`

**卡点**：prima 要求一个 ready 通知，原厂由 Android 的 `wcnss_service`（bionic 动态链接，musl 跑不了）
通过 `/dev/wcnss_ctrl` 喂完 NV 数据才发出。

**风险**：`insmod pronto_wlan.ko` 会让内核**调度停摆**（不是 panic，TCP 还能握手但 sshd 发不出 banner），
没有看门狗，只能拔插。已经因此挂死过一次。

因此：`/etc/modules` 是空的，**没有任何自启动会去加载它**，日常启动完全不受影响。
`device/wifi-probe.sh` 保留着（分 5 步、每步 sync 落盘，卡死也能看出死在哪步），
但必须手动、一次只改一个变量地执行。

## 改配置的正确姿势

1. 改 `device/` 下的文件（不要在设备上直接改）
2. `scripts/deploy-native.sh`
3. 涉及 `boot-native.sh` 的改动要下一次上电才生效；想立即验证就手动跑对应片段

## 踩过的坑（避免重犯）

- Git Bash 脚本里用 `MSYS_NO_PATHCONV=1` 后，`ssh -i /d/...` 这种 POSIX 路径 Windows 的
  `ssh.exe` 认不了 → 统一用 `cygpath -w`
- 写 `boot-native.sh` 这类开机脚本时，任何读 `/cache` 的代码都必须排在挂载之后
- `mkhybrid.py` 不创建 `bin` 目录条目，导致 `bin/busybox` 创建失败、PID 1 exec 失败、
  零日志冻死。打包一律用 `mkh2.py`
- busybox 改名后所有 applet 失效（按 `argv[0]` 分发），不要重命名 `busybox`
