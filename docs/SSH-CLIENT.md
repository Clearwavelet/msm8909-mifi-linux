# 用 MobaXterm / 其他 SSH 客户端连 XJ19

## 当前认证方式

| 方式 | 状态 | 说明 |
|---|---|---|
| **密码** | **已开启** | 用户 `root`，密码 `password` |
| 公钥 | 已开启 | `xj19_ed25519`（主用）/ `xj19_rsa`（备用） |

两种都能用。命令行推荐用密钥（不用敲密码），图形客户端用密码最省事。

设备侧 `sshd_config` 关键项：

```
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitEmptyPasswords no
ListenAddress 192.168.42.129     ← 只在这个地址上监听
```

> **安全提醒**：`password` 是弱口令。目前风险可控，因为 `ListenAddress` 把 sshd 绑在
> `192.168.42.129`（USB RNDIS 点对点链路上的设备地址），局域网里其他机器根本路由不到这个网段。
> 但如果以后把 RNDIS 桥接进 LAN、或做端口转发，这个密码就等于没有防护，届时请改掉。

## MobaXterm（现在两步就够）

### 建会话

`Session` → `SSH`：

| 字段 | 值 |
|---|---|
| Remote host | `192.168.42.129` |
| Specify username | `root` |
| Port | `22` |

### 确认没勾私钥

如果之前照着旧文档勾过 `Advanced SSH settings` 里的 **`Use private key`**，现在要么取消勾选
（走密码），要么继续保留（走密钥，同样能进）。**勾了但密钥文件路径失效会导致登录失败**，
所以改密码登录时记得把这一项清掉。

点 `OK` → 双击会话 → 提示密码时输 `password`。

### 可选：把 PC 代理也递进去

设备没有默认路由，`apk add` 必须借 PC 的代理。会话里点工具栏 **`Tunneling`** 图标，
加一条 **Remote port forwarding**：

| 字段 | 值 |
|---|---|
| Remote port | `7897` |
| Remote server | `127.0.0.1` |
| Local port | `7897` |

（前提是 PC 上的 verge-mihomo 仍在 `127.0.0.1:7897` 监听。）

设备侧 `/etc/profile.d/50-proxy.sh` 只在检测到 7897 有监听时才导出 `http_proxy`，
所以没配隧道也不会卡住 apk。不想折腾隧道就在 PC 上跑 `scripts/dev.sh`，它自带隧道和校时。

## 命令行（推荐密钥，不用敲密码）

`~/.ssh/config` 里已有别名：

```bash
ssh xj19                      # 登录（自带反向代理隧道）
ssh xj19 'df -h /'            # 执行一条命令
scp 本地文件 xj19:/data/       # 传文件
```

```
Host xj19
  HostName 192.168.42.129
  User root
  IdentityFile ~/.ssh/xj19_ed25519
  IdentitiesOnly yes
  RemoteForward 127.0.0.1:7897 127.0.0.1:7897
```

想用密码就临时覆盖一下：

```bash
ssh -o PubkeyAuthentication=no root@192.168.42.129
```

## 密钥清单（`C:\Users\Clearwave\.ssh\`）

| 文件 | 说明 |
|---|---|
| `xj19_ed25519` | ed25519，无口令，主用 |
| `xj19_rsa` | RSA 2048，无口令，老客户端备用 |

设备端 `/root/.ssh/authorized_keys` 里两把都在，源头是 `device/authorized_keys`，
改完跑 `scripts/deploy-native.sh` 推送。

## 改密码 / 关掉密码登录

设备上直接改（立即生效，不用重启 sshd）：

```bash
printf 'root:新密码\n' | chpasswd
```

要恢复成纯密钥登录：把 `device/sshd_config` 里
`PasswordAuthentication yes` 改回 `no`，然后 `scripts/deploy-native.sh`，
再 `kill -HUP $(pidof sshd | awk '{print $NF}')` 重载监听器。

## 已知的兼容性坑

- **MobaXterm 版本太老**（大概 v12 以前）可能既不支持 ed25519，也只提供 SHA-1 的 `ssh-rsa`，
  而 OpenSSH 9+ 默认禁用 SHA-1。现在有密码登录兜底，一般不会卡在这一步。
- **WinSCP / FileZilla** 两种方式都支持：密码直接填，或指定 `xj19_ed25519`（不用转 `.ppk`）。
- **`KbdInteractiveAuthentication no`** 是故意的：Alpine 的 OpenSSH 没编译 PAM，
  键盘交互式认证没有后端可答，开着只会让客户端多试一轮再失败。
