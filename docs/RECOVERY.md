# 恢复手册（XJ19 / MSM8909）

设备现状：boot 分区里是混合镜像，cache 分区（p23）上是完整的 Alpine 根。
**只要 boot 分区和 cache 分区还能写，就没有真正变砖的可能** —— 最坏情况走 fastboot。

## 分区表（实测，1 KB 块）

| 分区 | 大小 | 文件系统 | 内容 |
|---|---|---|---|
| mmcblk0p1 | 64 MB | vfat | modem 分区，`image/` 下有 `modem.*` / `mba.mbn` / **`wcnss.*`** |
| mmcblk0p16 | 10 MB | raw | splash（启动日志取证用，`dd` 写它） |
| mmcblk0p20 | 32 MB | raw | **boot**（Android boot v0，page 2048） |
| mmcblk0p21 | 1.2 GB | ext4 | Android system（保留，未改动） |
| mmcblk0p22 | 32 MB | ext4 | **persist**，含 `WCNSS_qcom_wlan_nv.bin` 射频校准 |
| mmcblk0p23 | 256 MB | ext4 | **cache = Alpine 根文件系统** |
| mmcblk0p29 | 1.79 GB | ext4 | userdata → 挂到 `/data` |

## 三级恢复

### 第 1 级：系统能启动，只是改坏了某个配置
不需要恢复，直接改回来：
```bash
dev/dev.sh cmd 'vi /boot-native.sh'   # 或任何 /etc 下的文件
```
配置的"源头"都在 PC 的 `dev/alpine/native/` 下，跑 `dev/deploy-native.sh` 就能整体覆盖回去。

### 第 2 级：根文件系统坏了（起不来，但 fastboot 可用）
用裸镜像一条命令复活：
```bash
cd dev/img
LATEST=$(ls -t ../backup/cache-*.img.gz | head -1)   # 现役备份取最新的一份
gunzip -c "$LATEST" > /tmp/cache.img
fastboot flash cache /tmp/cache.img
fastboot reboot
```
> `fastboot flash cache` 写的就是 mmcblk0p23，即整个 Alpine 根，连带
> `/cache/boot.count`、`/cache/.boot-android`、`/cache/.last_time`、root 密码一起回到备份时刻。
> 当前最新是 `cache-20261116-0145`（**WiFi 已打通** / v14 已烧写 / 密码登录已开 / 固件去重）。
> 这一份是最值钱的快照：恢复它就能直接回到"设备自己连 WiFi 上网"的状态。
> `backup/old/` 里是更早的快照，只作历史参考，别用来恢复。

进 fastboot 的办法：拔插后若 3 次进 Alpine 失败，initramfs 会自动回 Android；
在 Android 里 `adb reboot bootloader`。或者用 EDL（9008）兜底。

### 第 3 级：boot 分区也不对了（进 Android 也异常）
先恢复原厂 boot，确认设备还活着：
```bash
cd dev/img
fastboot flash boot boot-backup.img     # 原厂，33554432 字节
fastboot reboot
```
md5 `4a88b02797f7dad80ae09db1767c0167`。确认 Android 正常后，再重做原生系统：
```bash
fastboot flash boot boot-hybrid-v14.img  # 现役混合镜像：默认进 Alpine，连续 3 次失败才进 Android
fastboot flash cache <解压后的 cache 镜像>
fastboot reboot
```

## 不用 fastboot 的回退通道（设备里就有镜像）

`/data/recovery/`（= userdata 分区 p29，Android 侧路径也是 `/data/recovery/`）常驻以下文件：

| 文件 | 说明 |
|---|---|
| `boot-v14.img` | **现役**混合镜像，13969408 字节（安全网改成连续 3 次失败才回 Android） |
| `boot-v13.img` | 上一版，13969408 字节 |
| `boot-v12.img` | 更早一版（MAC 随机），13967360 字节 |
| `README-A.txt` | 中文操作说明 |

在 Alpine 里回退 boot 分区（约 1 秒）：
```bash
md5sum /data/recovery/boot-v14.img          # 先确认完整性
dd if=/data/recovery/boot-v12.img of=/dev/mmcblk0p20 bs=1M conv=fsync
sync
# 然后拔插
```
在 Android 里回退（`adb root` 之后）：
```bash
adb shell "dd if=/data/recovery/boot-v14.img of=/dev/block/bootdevice/by-name/boot"
```
> 注意 boot 分区是 32 MB，镜像只有 13.9 MB，`dd` 写完镜像长度即可，不用管剩下部分。

## 从 tar 重建（跨设备 / 手工场景）
```bash
# 在任意可用的 Linux shell 里（设备自身、或 PC 上的 WSL 挂载 ext4）
mkfs.ext4 -L cache /dev/mmcblk0p23
mount /dev/mmcblk0p23 /mnt
tar -xzf rootfs-<日期>.tar.gz -C /mnt
mkdir -p /mnt/{proc,sys,dev,run,mnt,home,tmp}
dev/deploy-native.sh      # 补回 /boot-native.sh、fstab、profile.d 等
```

## 换到第二根同型号的棒子
1. `fastboot flash boot boot-hybrid-v14.img`
2. 把备份的 cache 镜像 `fastboot flash cache`（或按上面 tar 流程重建）
3. 注意：SSH 主机密钥会沿用旧设备的，authorized_keys 里是同一把 `id_alpine`，直接能连。
   若要区分，改 `/etc/hostname` 并重跑 `ssh-keygen -A`。

## 备份
```bash
dev/backup-rootfs.sh              # 生成 tar + 裸镜像 + md5，默认放 dev/../backup/
```

## WCNSS（板载 WiFi）现状 —— 已暂停
- 固件（`wcnss.mdt`/`wcnss.b00~b12`）与射频校准（`/persist/WCNSS_qcom_wlan_nv.bin`）都已定位并拷到
  `/lib/firmware`、`/etc/firmware/wlan/prima`；驱动模块 `pronto_wlan.ko` 在 `/lib/modules/3.10.49/`
  （`/etc/firmware/wcnss.*` 那份重复副本已删——固件加载走 `/lib/firmware`，留着只是白占 3.3 MB）
- `echo 1 > /dev/wcnss_wlan` 能把芯片从 `OFFLINE` 拉到 `ONLINE`（固件确实加载并出了复位）
- **卡点**：prima 要求一个 ready 通知，原厂由 Android 的 `wcnss_service` 通过 `/dev/wcnss_ctrl`
  喂 NV 数据后触发；该程序是 bionic 动态链接，musl 上跑不了
- **风险**：`insmod pronto_wlan.ko` 会让内核卡死（不是 panic，是调度停摆），只能拔插恢复
- 因此：**没有任何自启动会加载该模块**（`/etc/modules` 为空），日常启动完全不受影响。
  试验脚本 `/wifi-probe.sh` 保留但必须手动执行，且逐步骤验证。
