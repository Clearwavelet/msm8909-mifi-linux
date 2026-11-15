# Alpine on XJ19 (MSM8909) —— 已完成部署

在 XJ19 4G dongle 上以 **chroot 方式**运行 Alpine Linux 3.24.4（armv7）。
Android 系统未被修改，未刷写任何分区，完全可逆。

## 当前状态（已实测通过）

| 项 | 值 |
|---|---|
| 位置 | 设备 `/data/alpine`（ext4，1.2G 可用） |
| 发行版 | Alpine Linux 3.24.4 armv7 |
| 包管理器 | apk-tools 3.0.9-r0（27112 个包可用） |
| 内核 | 原厂 3.10.49（未改动） |
| 内存 | 395MB 可用，空载占用约 155MB |
| 登录 | SSH root@127.0.0.1:2222（密钥免密） |
| 已装 | openssh 10.3p1、openrc、busybox-extras、htop、tmux |

## 日常使用

```bash
./tools/setup-rootfs.sh          # 首次：在设备里 chroot 执行，配置 Alpine 根
adb forward tcp:2222 tcp:22      # 把设备 22 端口映射出来
ssh -p 2222 root@127.0.0.1       # 登录（密钥见 docs/SSH-CLIENT.md）
ssh -p 2222 root@127.0.0.1 "apk info"
```

> 注意：这一阶段是**在 Android 里跑 chroot**，属于过程里程碑，不是最终形态。
> 最终形态是原生引导，见仓库根 `README.md`。

需要装包时先借网：

```bash
./net-on.sh           # 电脑侧起代理 + adb reverse
./ssh.sh
# 容器内：
export http_proxy=http://127.0.0.1:8888
export https_proxy=$http_proxy
apk add <包名>
```

## 四个必须知道的约束

**1. 仓库只能走 HTTP，不能走 HTTPS。**
`apk` 走 https 会段错误（`unhandled page fault at 0x294`），busybox 的 https 同样失败。根因是 musl + OpenSSL 在 3.10 内核上的 TLS 栈不兼容。`/etc/apk/repositories` 已改为 `http://`。由于 apk 对每个包都做 RSA 签名校验，完整性仍受保护，但传输内容对中间人可见。

**2. `/data` 以 `nosuid,nodev` 挂载，设备节点放不进去。**
所以 `/dev` 必须用独立 tmpfs 覆盖，再 `mknod` 建静态节点。这是 `boot-up.sh` 每次都要做的事，重启后必须重跑。

**3. 没有 devtmpfs，所以没有 init。**
systemd 硬依赖 devtmpfs，起不来。当前形态是"chroot 里手动起服务"，不是从内核启动的完整系统。要变成真系统需要重编内核（DTS 已在手）。

**4. `adb shell` 不传递远端退出码。**
老版 adbd 没有 shell_v2，脚本里不能依赖 `$?`，只能用输出内容判断（`ssh.sh` 已按此实现）。

## 文件说明

| 文件 | 作用 |
|---|---|
| `boot-up.sh` | 电脑侧：推送并执行设备端启动脚本 |
| `device-boot.sh` | 设备侧：挂载 proc/sys、建 /dev tmpfs 与设备节点、拉起 sshd |
| `ssh.sh` | 电脑侧：检查 sshd → adb forward → ssh 登录 |
| `net-on.sh` | 电脑侧：启动本地代理 + adb reverse，给设备借网 |
| `proxy.py` | 极简 HTTP/CONNECT 代理（只转发，不解析） |
| `setup-rootfs.sh` | 首次部署用：仓库/DNS/密码/sshd/policy-rc.d |
| `busybox-static` | 静态 busybox，设备侧唯一解包与救援工具 |
| `id_alpine`(.pub) | SSH 密钥对（root 免密登录用，密码为 `alpine`） |
| `alpine-minirootfs-*.tar.gz` | 原始 rootfs，重装时用 |

## 后续（已完成）

这一阶段的下一步就是原生引导：自建 initramfs、重打包 `boot.img`、`fastboot boot` 临时验证、
最后写入 boot 分区。**这一步后来已经跑通**，本仓库的 `initramfs/`、`tools/`、`images/` 就是成果，
详见仓库根 `README.md`。
