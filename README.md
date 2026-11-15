# msm8909-mifi-linux

把一根**停产的 4G MiFi 上网棒**（高通 MSM8909，美格 MEIG 模组，型号 XJ19）从 Android 5.1
改成**开机直接进入原生 Alpine Linux**。

不需要原厂套餐，不需要原厂 App，不改 Android 系统——boot 分区里放一个混合引导镜像，
默认进 Alpine，异常时自动退回 Android，`fastboot flash` 一条命令就能还原。

```
上电 → bootloader → 自建 initramfs → 挂 cache 分区 → 配 RNDIS 网卡
     → switch_root → Alpine（OpenRC）→ udhcpd + sshd
                                     → wifi-connect（WCNSS/prima，后台 11 秒）
                                       ↑ 电脑这边 ssh root@192.168.42.129 即可
                                       ↑ 或直接 ssh root@<WiFi 地址>，不插 USB 也行
```

**板载 WiFi 已经跑起来了**（WCNSS + prima），设备自己连 AP、自己上网，
`ping`/`apk`/`curl` 全通，不需要电脑、不需要代理隧道。这是本仓库最关键的一块。

## 成果

| 项 | 值 |
|---|---|
| 内核 | 原厂 3.10.49（未替换，`armv7l`） |
| 用户空间 | Alpine Linux 3.24.4 / musl / OpenRC / busybox init |
| 根文件系统 | `mmcblk0p23`（cache 分区，256 MB ext4，占用 48 MB） |
| 数据盘 | `mmcblk0p29`（原 Android userdata，1.79 GB）挂 `/data`，`/home` 绑过去 |
| 内存占用 | 空载 36 MB / 383 MB |
| **WiFi** | **WCNSS `/dev/wcnss_wlan` + prima `pronto_wlan.ko`，`wlan0` 自连 AP，TCP/UDP/ICMP 全通** |
| USB 网络 | RNDIS，设备 `192.168.42.129`，自带 `udhcpd` 给电脑发地址 |
| 登录 | SSH，密钥或密码；RNDIS MAC 已固定，Windows 不会每次都新建网卡 |
| 软件源 | `apk` 可用（27112 个包），**WiFi 直连，不需要任何代理** |
| Android | 完整保留，可随时退回（连续 3 次启动失败自动退回） |

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
│   ├── wifi-connect.sh        WiFi 主流程：NV 就位 → 上电 → 等 cold boot → insmod → 关联 → DHCP
│   ├── wifi-tui.sh            交互式 WiFi 配置器（dialog TUI）：扫描 / 连 / 存 / 删
│   ├── wpa_supplicant.conf.example  WiFi 凭据模板（复制成 .conf 填自己的 SSID/密码，真实凭据不入库）
│   ├── net-mode.sh            ics / tunnel 模式切换（WiFi 不可用时的兜底）
│   ├── profile-proxy.sh       仅在隧道模式下导出 http_proxy
│   └── wifi-probe.sh          WiFi 分步排障脚本（手动执行）
├── initramfs/
│   ├── hybrid/init            现役：默认进 Alpine，连续 3 次失败才退回 Android
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
│   ├── dev.sh                 一条命令 = 校时 + shell（`up` 子命令开隧道兜底）
│   ├── deploy-native.sh       幂等推送 device/ 下的配置
│   ├── status.sh              一页体检报告（含 WiFi 与联网实测）
│   ├── backup-rootfs.sh       双份备份（tar + cache 分区裸镜像）
│   └── verify-persist.sh      冷启动后核对挂载/时间/计数/代理
├── images/
│   ├── boot-hybrid-v14.img    现役镜像，13.9 MB，可直接刷
│   └── boot-hybrid-v13.img    上一版，回退用
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
scripts/dev.sh                      # 校时 + shell
scripts/status.sh                   # 一页体检报告（含 WiFi 与联网实测）
```

图形客户端见 `docs/SSH-CLIENT.md`（MobaXterm 用密码 `password` 即可）。

### 7. 配 WiFi（可选，但很值得）

SSH 进去，敲 `wifi-tui` 就有交互界面：

```bash
apk add dialog          # 只有这一个依赖
wifi-tui                # 扫描 → 选网 → 输密码 → 连上 → 自动存
```

也可非交互：`wifi-tui scan` / `wifi-tui status` / `wifi-tui list` /
`wifi-tui connect "SSID" "密码"`。

想从电脑侧预置（换机器时省事）：

```bash
cp device/wpa_supplicant.conf.example device/wpa_supplicant.conf
vi device/wpa_supplicant.conf       # 填自己的 SSID / 密码
scripts/deploy-native.sh            # 推到设备
# 重启（拔插），或手动：ssh xj19 '/usr/local/sbin/wifi-connect.sh'
```

开机时 `boot-native.sh` 会**后台**拉起 `wifi-connect.sh`（约 11 秒），
不挡 sshd —— USB 那条路是保命线，必须最先可用。

`wifi-tui` 有两个非显然但很重要的行为：**连失败会自动回滚配置**（并把原来的网络连回来），
**连上后会校验 SSID**。前者防止一次密码输错就在无屏设备上留下"开机连不上但看起来正常"的
坑；后者防止 wpa_supplicant 挑中别的已保存网络而被误报成功。

## WiFi：WCNSS + prima 是怎么打通的

这块的公开资料很少，绝大多数结论是"必须复刻 Android 的 `wcnss_service`，musl 跑不了"。
**这个结论是错的**，`wcnss_service` 其实不喂任何数据——NV 标定由内核自己
`request_firmware("wlan/prima/WCNSS_qcom_wlan_nv.bin")` 下载。

真正的三个卡点全是环境准备问题：

| 症状 | 真实原因 | 修法 |
|---|---|---|
| `echo 1 > /dev/wcnss_wlan` 后芯片"通电"但固件没加载 | **`/firmware`（p1）没挂载**，PIL 找不到 `wcnss.mdt` | `mount -t vfat -o ro /dev/mmcblk0p1 /firmware` |
| `insmod` 报 `WCNSS driver not ready`，接着内核调度停摆 | `request_firmware` 在所有路径都没找到 NV，退到用户态 hotplug helper，3.10 上**不可中断等 60 秒并占住 workqueue** | 把 NV + cfg.ini 复制到 `/lib/firmware/wlan/prima/`（内核默认搜索路径，且在可写根分区上） |
| `Association request to the driver failed` | prima 只实现了 nl80211 的一个子集 | `wpa_supplicant -Dwext`（不是 nl80211） |

正确顺序（`device/wifi-connect.sh` 已固化）：

```sh
mount -t vfat -o ro /dev/mmcblk0p1 /firmware        # 给 PIL 取 wcnss.mdt + b00~b12
mkdir -p /lib/firmware/wlan/prima                    # 给内核 request_firmware 取 NV
cp /etc/firmware/wlan/prima/* /lib/firmware/wlan/prima/
echo 1 > /dev/wcnss_wlan 2>/dev/null                 # 上电（写 1 字节返回 EFAULT 属预期）
while ! dmesg | grep -q WCNSS_CBC_COMPLETE_IND; do sleep 1; done   # ← 这道门槛不能跳
insmod /root/wlan/pronto_wlan.ko
echo sta > /sys/module/wlan/parameters/fwpath
wpa_supplicant -Dwext -B -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant.conf
udhcpc -i wlan0 -n -q
```

**为什么"等 cold boot"这道门槛不能跳**：prima 的 `hdd_driver_init` 里有

```c
while (!wcnss_device_ready() && 10 >= ++max_retries) msleep(1000);
if (max_retries >= 10) return -ENODEV;      /* "WCNSS driver not ready" */
```

而 `wcnss_device_ready()` 只看 `nv_downloaded && !shutdown`。NV 没下完就 `insmod`，
会先白等 5 秒再失败，并且那次失败会把内核 workqueue 一起拖死。

素材位置（本机实测）：

- 固件 `wcnss.mdt` + `wcnss.b00~b12`：`mmcblk0p1` 的 `image/`
- 射频校准 `WCNSS_qcom_wlan_nv.bin`（31723 B）+ `WCNSS_qcom_cfg.ini`：persist 分区（p22）/ system 分区（p21）
- 驱动 `pronto_wlan.ko`：system 分区 `lib/modules/pronto/`，vermagic 与运行内核完全一致
- 内核配置正好对上：`CONFIG_CFG80211=y`、`WEXT_CORE=y`，`MAC80211` 关闭（prima 本来就不走 mac80211）

冷启动实测日志：

```
[00:45:42] NV 就位: 31723 字节
[00:45:42] 已触发 WCNSS 上电
[00:45:49] cold boot 完成（6s）
[00:45:49] insmod rc=0
[00:45:52] 已关联: bssid=d4:a1:48:9d:70:e0
[00:45:53] udhcpc rc=0 addr=192.168.3.108/24
[00:45:53] ==== WiFi 就绪: wlan0 192.168.3.108/24 gw=192.168.3.1 ====
```

已知小毛病：`wlan0` 的 MAC 是 cfg.ini 里的占位值 `00:0a:f5:89:89:ff`
（dmesg 有 `Failed to generate wlan interface mac addr`）。WPA2-PSK 不受影响，
只有 MAC 绑定的网络才需要处理。另外 `iw dev wlan0 link` 显示未连接是 nl80211 状态回报不全，
判状态要看 `wpa_cli status` 或 `iwconfig`。

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
8. **CRLF 会让脚本报 "not found"**。Windows 上编辑出的脚本传到设备后 `#!/bin/sh\r`
   让内核找不到解释器，错误信息极具误导性——文件明明在、权限也对，就是不执行。
   `scripts/deploy-native.sh` 的 `put` 现在统一 `tr -d '\r'`，从传输环节根治。
9. **busybox 的 `sed` 不认方括号里的 `\t`**（当成字面的字母 t），而 `awk` 认。
   解析 `wpa_passphrase` 输出时用 `[ \t]` 会静默匹配失败、悄悄退到"存明文密码"，
   表面看一切正常。解析空白一律用 `[[:space:]]`。
10. **`iw` 把 SSID 里的非打印字节转义成字面文本 `\xNN`**（C locale 下中文也算）。
    不解码的话中文 SSID 拿去连必然失败；隐藏 SSID 是整串 `\x00`，解码后为空，
    正好据此跳过。用 `printf '%b'` 还原。
11. **别在部署脚本里推 `resolv.conf`**。它由 DHCP / `wifi-connect.sh` 动态写，
    推一次就把 DNS 打回隧道时代的 `127.0.0.1`（而 WiFi 模式下 unbound 是跳过的），
    表现为 `apk` 报 "DNS: transient error"。

## 安全网

- initramfs 每次启动 `boot.count++`，Alpine 里 sshd 起来后清零
- 连续 3 次没能进 Alpine → 自动 `exec /init.real` 回 Android
- 手动回 Android：`touch /cache/.boot-android`，然后拔插
- boot 分区镜像在设备 `/data/recovery/` 里也存了一份，回退不需要 fastboot

## 已知限制

- **WiFi 模式下网络是全通的**（TCP/UDP/ICMP/QUIC 都行）。只有在 WiFi 连不上、退回到
  SSH 反向隧道兜底时，才有"UDP 不通、`ping` 不通、必须电脑在线"那些限制
- 设备**没有 RTC 备电**，上电时间是 1970，靠 `/cache/.last_time` 残影 + 电脑校时纠正
- 内核无 `CONFIG_WATCHDOG` / pstore，挂死时没有任何日志可看
- `/hp`、`/hs`、`/mnt` 是 `switch_root` 留下的僵尸挂载，`df` 里根分区会显示成
  `/nd/cache on /mnt`——纯显示问题，实际就是 `mmcblk0p23`
- `wlan0` 的 MAC 是 cfg.ini 里的占位值 `00:0a:f5:89:89:ff`，WPA2-PSK 不受影响

## 声明

- 仅用于**自己拥有**的设备。设备厂商已停止运营，本仓库不涉及任何绕过计费或破解服务的手段，
  只是把这台设备的硬件用起来跑自己的系统。
- `device/` 里的 `sshd_config` 默认允许密码登录且示例密码是弱口令 `password`。
  `ListenAddress` 必须是 `0.0.0.0`（否则 WiFi 入口进不来），所以**一旦设备连上 WiFi，
  22 端口就对整个局域网开放，而且凭据是 root/弱口令**。这是"能远程管理"和"安全"之间
  必须自己权衡的地方：**请在第一次连 WiFi 前改掉密码**（设备上执行 `passwd`），
  或改成仅密钥登录（`sshd_config` 里 `PasswordAuthentication no`）。
  只在可信私有网络里用、且不在意的话，维持默认也能跑。
- `vendor/`、`reference/` 下的固件片段与配置来自设备自身，版权归原厂；此处仅作
  个人设备恢复与研究用途。

## 许可

MIT（见 `LICENSE`）。`vendor/`、`reference/` 中的第三方内容除外。
