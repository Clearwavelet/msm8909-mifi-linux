# msm8909-mifi-linux

把一根**停产的 4G MiFi 上网棒**（高通 MSM8909，美格 MEIG 模组，型号 XJ19）从 Android 5.1
改成**开机直接进入原生 Alpine Linux**。

不需要原厂套餐，不需要原厂 App，不改 Android 系统——boot 分区里放一个混合引导镜像，
默认进 Alpine，异常时自动退回 Android，`fastboot flash` 一条命令就能还原。

```
上电 → bootloader → 自建 initramfs → 挂 cache 分区 → 配 RNDIS 网卡
     → switch_root → Alpine（OpenRC）→ udhcpd + sshd
                                       ↑ 电脑这边 ssh root@192.168.42.129 即可
```

## 成果

| 项 | 值 |
|---|---|
| 内核 | 原厂 3.10.49（未替换，`armv7l`） |
| 用户空间 | Alpine Linux 3.24.4 / musl / OpenRC / busybox init |
| 根文件系统 | `mmcblk0p23`（cache 分区，256 MB ext4，占用 30 MB） |
| 数据盘 | `mmcblk0p29`（原 Android userdata，1.79 GB）挂 `/data`，`/home` 绑过去 |
| 内存占用 | 空载 28 MB / 383 MB |
| 网络 | USB RNDIS，设备 `192.168.42.129`，自带 `udhcpd` 给电脑发地址 |
| 登录 | SSH，密钥或密码；MAC 已固定，Windows 不会每次都新建网卡 |
| 软件源 | `apk` 可用（27112 个包），经 SSH 反向隧道借用电脑代理 |
| Android | 完整保留，可随时退回（连按 3 次启动失败自动退回） |

## 硬件事实（实测，非猜测）

| 项 | 值 |
|---|---|
| SoC | MSM8909，4×Cortex-A7 ARMv7 + VFPv3/NEON |
| 基带 | `M8909EAAAANVZM-1`，模组厂 MEIG |
| 内存 / 存储 | 512 MB / 4 GB eMMC |
| 原系统 | Android 5.1.1 `LMY47V eng.Data.BU.20201105`，`ro.secure=0`，SELinux Permissive |
| 形态 | **无屏幕、无按键、无电池、无 RTC 备电**——插上 USB 就是开机，拔掉就是断电 |
| 引导 | aboot/LK + Android boot v0（page 2048），QCDT 137 项 / 38 个 DTB，`qcom,msm8909-qrd_skua` |

内核 3.10.49 的几个硬限制直接决定了方案选型：

- **没有 `CONFIG_DEVTMPFS`** → `/dev` 得靠 `mdev -s` 反向生成
- **没有 `CONFIG_FHANDLE` / `AUTOFS4_FS`** → systemd 完全跑不起来，所以选 Alpine + OpenRC
- **没有 `CONFIG_WATCHDOG`、没有 pstore** → 崩溃后没有任何日志，也没有自动重启
- `BINFMT_SCRIPT=y`、`EXT4_FS=y`、`CONFIG_USB_G_ANDROID=y` → 脚本解释器、ext4 根、USB gadget 都有

## 目录结构

```
├── README.md                  你正在看的这份
├── docs/
│   ├── METHOD.md              完整实现记录：每一步怎么试出来的、踩了什么坑
│   ├── RECOVERY.md            三级恢复手册（改坏配置 → 根坏了 → boot 也坏了）
│   ├── SSH-CLIENT.md          MobaXterm / WinSCP / 命令行连接配法
│   └── STAGE1-CHROOT.md       第一阶段：在 Android 里跑 chroot（过程里程碑）
├── device/                    推到设备上的配置（改这里，再跑 scripts/deploy-native.sh）
│   ├── boot-native.sh         openrc 之前执行：挂 /cache /data、校时、配网卡、起服务
│   ├── inittab  sshd_config  udhcpd.conf  fstab  resolv.conf
│   ├── profile-proxy.sh       检测到代理端口才导出 http_proxy
│   └── wifi-probe.sh          板载 WiFi 试验脚本（分步、可中断，默认不自启）
├── initramfs/
│   ├── hybrid/init            现役：默认进 Alpine，失败退回 Android
│   ├── native/init            早期纯原生版（无退回分支）
│   └── mini/init              15 行诊断版（排查"零日志冻死"时用的）
├── tools/
│   ├── mkboot.py              initramfs 目录 → cpio.gz → 与原厂 kernel/QCDT 组装 boot.img
│   ├── mkh2.py                打包 initramfs（保留原厂条目、注入 /init.real）
│   ├── mkinit6.py  mkhybrid.py  mkharness.py   其它打包变体与历史版本
│   ├── fb.py                  自写的 fastboot 客户端（Windows 下绕开 fastboot.exe 枚举 bug）
│   ├── build.sh               一键重建镜像
│   ├── verify-boot.sh         冷启动后逐项判定是否真的进了 Alpine
│   └── wait-alpine.sh         上电后判定：RNDIS 出现=Alpine，adb 回来=退回成功
├── scripts/                   电脑侧日常运维
│   ├── dev.sh                 一条命令 = 反向代理隧道 + 校时 + shell
│   ├── deploy-native.sh       幂等推送 device/ 下的配置
│   ├── status.sh              一页体检报告
│   ├── backup-rootfs.sh       双份备份（tar + cache 分区裸镜像）
│   └── verify-persist.sh      冷启动后核对挂载/时间/计数/代理
├── images/
│   └── boot-hybrid-v13.img    编译好的现役镜像，13.9 MB，可直接刷
├── vendor/
│   ├── busybox-static         armv7 静态 busybox，initramfs 里的解释器
│   └── stock-ramdisk.gz       原厂 ramdisk，提供 /init.real 等需保留的条目
└── reference/                 取证数据：分区表、内核配置、usb.rc、cpuinfo
```

## 快速开始

> 前提：设备已解锁 bootloader（本机 `ro.secure=0`，`fastboot` 直接可用），
> 电脑装好 adb/fastboot，Windows 用 Zadig 给设备装 WinUSB 驱动。

### 1. 先备份 boot 分区

设备上（Android 里需要 root，或进 fastboot）：

```bash
adb shell su -c "dd if=/dev/block/bootdevice/by-name/boot of=/sdcard/boot-backup.img"
adb pull /sdcard/boot-backup.img
# 记录 md5，后面要用它校验
```

同时用 `STOCK_BOOT=boot-backup.img` 让构建脚本认这个文件（默认用仓库里的
`images/boot-hybrid-v13.img` 提取 kernel / QCDT，两者内容一致）。

### 2. 重建镜像（可选，直接用 `images/` 里的成品也行）

```bash
cd tools
STOCK_BOOT=/path/to/boot-backup.img ./build.sh hybrid
```

输出应逐字节等于 `images/boot-hybrid-v13.img`
（md5 `df82151ffa40983a5dd5ea9a4b15eae7`）——这一点在本机验证过。

### 3. 先临时引导，不要直接刷

```bash
python tools/fb.py boot images/boot-hybrid-v13.img
```

`fastboot boot` 只在内存里跑一次，不写 flash。20 秒内电脑应出现一个新的 RNDIS 网卡，
说明原生系统真的起来了。**这一步成功之后**才去刷分区。

### 4. 写 boot 分区

```bash
fastboot flash boot images/boot-hybrid-v13.img
fastboot reboot          # 没电池，这里是断电；直接拔插更直接
```

### 5. 准备根文件系统

仓库不含根文件系统镜像（体积大且与设备绑定），需要自己 bootstrap 一个 armv7 Alpine：

```bash
# 在任意 Linux 上
wget https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/armv7/alpine-minirootfs-3.24.4-armv7.tar.gz
mkdir rootfs && tar -xzf alpine-minirootfs-3.24.4-armv7.tar.gz -C rootfs
# 然后按 docs/METHOD.md 里"根文件系统"一节放置 device/ 下的配置
```

最后把 rootfs 写进 `mmcblk0p23`（cache 分区）：

```bash
fastboot flash cache rootfs.img        # 或 dd 到 /dev/mmcblk0p23
```

### 6. 连上去

```bash
scripts/dev.sh                      # 隧道 + 校时 + shell
scripts/status.sh                   # 一页体检报告
```

图形客户端见 `docs/SSH-CLIENT.md`（MobaXterm 用密码 `password` 即可）。

## 几个值得记录的坑

这些是真正卡住过进度的地方，细节见 `docs/METHOD.md`：

1. **initramfs 里没有 applet 软链接**。只有 `/bin/busybox` 和 `/init`，裸 `cat` 不存在、
   `stderr` 又被吞掉，所有 `$(cat /sys/...)` 全返回空串——整整几轮都在读假数据。
2. **`sbin/ueventd`、`sbin/watchdogd` 是指向 `/init` 的软链接**。原样保留会递归执行自己，
   整机死锁，表现为"零日志冻死"。必须改成绝对路径指向 `/init.real`。
3. **cpio 里漏了 `bin` 目录条目**。父目录不存在 → `bin/busybox` 创建失败 →
   shebang 找不到解释器 → PID 1 exec 失败 → 内核 panic。打包器已加断言。
4. **RNDIS 网卡名叫 `rndis0`，不是 `usb0`**。硬编码 `usb0` 导致前几版全被误判为失败，
   后来改成"基线差集"探测新增网卡才对。
5. **MAC 要写 `f_rndis/ethaddr`，不是网卡的 address**。`/sys/class/net/rndis0/address`
   每次启动都随机，但那不是 Windows 看到的地址；必须在 gadget `enable=1` 之前写
   `ethaddr`，否则每个新 MAC 都会让 Windows 多建一个"以太网 N"。
6. **`/cache` 必须是分区根**。initramfs 的"连续失败计数"和 `.boot-android` 标志都写在
   cache 分区根目录，Alpine 侧如果不重新挂载，写的不是同一个文件，安全网会静默失效。
7. **没有 RTC 备电**，每次上电都是 1970。用 `/cache/.last_time` 存"上次已知时间"做残影恢复，
   精确时间由 `scripts/dev.sh` 每次连接时从电脑推过去。

## 安全网

- initramfs 每次启动 `boot.count++`，Alpine 里 sshd 起来后清零
- 连续 3 次没能进 Alpine → 自动 `exec /init.real` 回 Android
- 手动回 Android：`touch /cache/.boot-android`，然后拔插
- boot 分区镜像在设备 `/data/recovery/` 里也存了一份，回退不需要 fastboot

## 已知限制

- **没有默认路由**：设备只能访问电脑，外网要经 SSH 反向隧道借电脑的代理
- **板载 WiFi（WCNSS）未打通**：芯片能被唤醒（`echo 1 > /dev/wcnss_wlan` 后状态
  `OFFLINE`→`ONLINE`、固件确实加载出复位），但 `prima` 驱动等的是原厂 `wcnss_service`
  通过 `/dev/wcnss_ctrl` 喂 NV 数据后的 ready 通知，而它是 bionic 动态链接、musl 上跑不了；
  强行 `insmod` 会把内核调度搞停（不是 panic，没有看门狗，只能拔插）。**默认没有任何自启动
  会加载该模块**
- 内核无 `CONFIG_WATCHDOG` / pstore，挂死时没有任何日志可看
- `/hp`、`/hs`、`/mnt` 是 `switch_root` 留下的僵尸挂载，`df` 里根分区会显示成
  `/nd/cache on /mnt`——纯显示问题，实际就是 `mmcblk0p23`

## 声明

- 仅用于**自己拥有**的设备。设备厂商已停止运营，本仓库不涉及任何绕过计费或破解服务的手段，
  只是把这台设备的硬件用起来跑自己的系统。
- `device/` 里的 `sshd_config` 默认允许密码登录且示例密码是弱口令 `password`。
  当前 `ListenAddress` 绑在 RNDIS 点对点地址上，局域网不可达，风险有限；**如果你要把它
  桥接进局域网或做端口转发，请先改密码**。
- `vendor/`、`reference/` 下的固件片段与配置来自设备自身，版权归原厂；此处仅作
  个人设备恢复与研究用途。

## 许可

MIT（见 `LICENSE`）。`vendor/`、`reference/` 中的第三方内容除外。
