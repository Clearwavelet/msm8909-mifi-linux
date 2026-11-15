XJ19 (MSM8909 / MEIG) —— 原生 Alpine Linux
==========================================

系统概况
  Linux 3.10.49 armv7l / Alpine 3.24.4 / musl / OpenRC
  根文件系统: /dev/mmcblk0p23 (ext4, 248MB, 挂载点 /)
  cache 分区: /dev/mmcblk0p23 根目录 → 挂载到 /cache
  数据分区:   /dev/mmcblk0p29 (ext4, 1.79GB) → 挂载到 /data，/home 绑定到 /data/home
  PID 1: /sbin/init (busybox init，读 /etc/inittab)

连接方式（唯一的交互通道：USB RNDIS 网卡）
  Windows 侧出现 "Remote NDIS based Internet Sharing Device"，自动获得 192.168.42.1xx
  设备固定地址: 192.168.42.129
  ssh -i id_alpine root@192.168.42.129

  注意：设备无屏、无键盘、无按键、无电池，也没有 RTC 电池。
        上电后时间先按 /cache/.last_time 的"残影"恢复，再由 PC 端 dev.sh 校准。

上外网（apk / curl）
  设备本身没有公网出口。不要在 Windows 上开 ICS 或改防火墙 —— 用 PC 端脚本：
      dev/dev.sh              # 交互 shell，自带隧道 + 校时
      dev/dev.sh cmd 'sudo apk add ...'
      dev/dev.sh up           # 只开隧道，前台常驻
  原理：ssh -R 127.0.0.1:7897:127.0.0.1:7897，把 PC 的本机代理递到设备回环。
  设备侧 /etc/profile.d/50-proxy.sh 检测到监听才导出 http_proxy，不会污染无隧道的情况。

开关机
  开机 = 插上 USB（VBUS 供电）
  关机 = 拔掉 USB
  【重要】reboot / poweroff / sysrq-b 在这块板子上都是"断电"，不会自动重启，
          必须人工拔插。不要指望软件重启。

回到 Android（原厂系统）
  方法一（推荐，需要能 SSH）:
      touch /cache/.boot-android
      然后拔插 USB
  方法二（SSH 不通时）:
      touch /.boot-android          # Alpine 根目录下的标志，initramfs 也会识别
      然后拔插 USB
  说明: boot 分区里的混合镜像保留了原厂 /init.real，标志存在时直接执行它，
        等价于原厂启动，adb 会正常工作。

恢复原厂固件（彻底）
  在 Android 里:
      adb reboot bootloader
      fastboot flash boot boot-backup.img     # 备份在工作区 dev/img/
  备份 md5: 4a88b02797f7dad80ae09db1767c0167 (33554432 字节)

安全网
  initramfs 每次启动会把 /cache/boot.count 加 1；Alpine 侧 sshd 起来后清零。
  连续 3 次没能进 Alpine 就自动回 Android，避免坏镜像把设备困死。
  注意 boot.count 与 .boot-android 都在 cache 分区【根目录】，即 /cache 下。

启动流程
  bootloader → kernel + initramfs(混合镜像)
    → mount cache → 检查标志/计数 → 配 RNDIS (05C6:F00E) → switch_root
    → Alpine /sbin/init → /etc/inittab
        ::sysinit:/bin/sh /boot-native.sh     ← 恢复时间、挂 /cache+/data、配网卡、起 udhcpd+sshd
        ::sysinit:/sbin/openrc sysinit
        ::sysinit:/sbin/openrc boot
        ::wait:/sbin/openrc default

实用命令
  apk add <pkg>            需先经 dev.sh 连上（代理已就绪）
  df -h /data              1.1GB 可用，大文件/编译产物放这里
  tail -f /var/log/native-net.log   启动过程日志
  dd if=/var/log/native-net.log of=/dev/mmcblk0p16 bs=4096 conv=notrunc   # 落盘取证

已知限制
  - /hp /hs /mnt 是 initramfs 遗留的孤立挂载点（ENOTDIR，无法 umount，重启即清），无害
  - OpenRC 各 runlevel 为空（服务由 boot-native.sh 手动拉起）
  - 内核无 CONFIG_WATCHDOG / pstore / FHANDLE，故不能用 systemd、无崩溃日志
  - 无后台自动对时（无 RTC、NTP 走不了代理），只在每次 dev.sh 连接时校准
