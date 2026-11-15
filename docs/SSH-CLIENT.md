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
ListenAddress 0.0.0.0          ← 必须 0.0.0.0，否则 WiFi 入口进不来
```

> **⚠ 安全提醒（2026-11-16 WiFi 打通后升级）**：`password` 是弱口令，而 `ListenAddress`
> 已经不能绑在 RNDIS 的 `192.168.42.129` 上了（那样 WiFi 的 `192.168.3.x` 进不来）。
> 也就是说 **22 端口现在对整个 WiFi 局域网开放，且用的是 root/`password`**。
> 只要设备连着的那个网络里有别人，就等于把 root 送出去。
>
> 三条出路，按推荐顺序：
> 1. **改强密码**：设备上 `passwd`，然后同步改客户端配置
> 2. **关掉密码登录**（`PasswordAuthentication no`），只留密钥 —— MobaXterm 里配 `xj19_ed25519` 即可
> 3. 确信所连 WiFi 是可信的私有网络（家里/自己热点），维持现状
>
> 另外 `PermitRootLogin yes` + 弱口令这个组合，比单纯弱口令更值得处理。

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

### 不用配隧道了（WiFi 已打通）

设备自己有 WiFi 出口，`apk add` 直连即可，**不需要任何隧道**。下面这段只有 WiFi
连不上、非要借电脑上网时才用。

会话里点工具栏 **`Tunneling`** 图标，加 **两条** Remote port forwarding：

| Remote port | Remote server | Local port | 作用 |
|---|---|---|---|
| `7897` | `127.0.0.1` | `7897` | 代理（mihomo 混合端口，HTTP + SOCKS5） |
| `5353` | `127.0.0.1` | `53` | DNS（mihomo 的 dns 服务） |

（前提是 PC 上的 verge-mihomo 仍在 `127.0.0.1` 监听这两个端口。）

**两条都要加**：只加 7897 的话 `apk` 能用，但所有域名都解析不了——
因为 musl 只会发 UDP 查询，而 SSH 隧道只承载 TCP，设备上的 unbound 需要 5353 这个 TCP 上游。

设备侧 `/etc/profile.d/50-proxy.sh` 只在检测到 7897 有监听时才导出 `http_proxy`，
所以没配隧道也不会卡住 apk。不想折腾隧道就在 PC 上跑 `dev/dev.sh`，它自带两条隧道和校时。

验证是否通了（在设备里）：

```sh
netstat -ln | grep -E '7897|5353'   # 两个端口都应该在听
getent hosts alpinelinux.org        # 应返回 198.18.x.x（mihomo 的 fake-ip）
curl -s -o /dev/null -w '%{http_code}\n' https://alpinelinux.org/   # 应返回 200
```

## 命令行（推荐密钥，不用敲密码）

`~/.ssh/config` 里已有别名：

```bash
ssh xj19                      # USB 入口：192.168.42.129，插上就一定通（保命线）
ssh xj19w                     # WiFi 入口：192.168.3.108，不插 USB 也行（同一网段才通）
ssh xj19t                     # 隧道模式：192.168.42.129 + 反向代理/DNS（WiFi 不可用时兜底）
ssh xj19 'df -h /'            # 执行一条命令
scp 本地文件 xj19:/data/       # 传文件
```

**平时用 `ssh xj19w` 或 `ssh xj19`，两个地址都干净、不带代理变量** ——
设备自己的 WiFi 就能上网，没必要再绕电脑。

```
Host xj19
  HostName 192.168.42.129
  User root
  IdentityFile ~/.ssh/xj19_ed25519
  IdentitiesOnly yes

Host xj19w
  HostName 192.168.3.108          # WiFi 是 DHCP 下发的，换网络/换热点要改
  User root
  IdentityFile ~/.ssh/xj19_ed25519
  IdentitiesOnly yes

Host xj19t                        # 只有 WiFi 不可用、需要借电脑上网时才用
  HostName 192.168.42.129
  User root
  IdentityFile ~/.ssh/xj19_ed25519
  IdentitiesOnly yes
  RemoteForward 127.0.0.1:7897 127.0.0.1:7897
  RemoteForward 127.0.0.1:5353 127.0.0.1:53
  SetEnv http_proxy=http://127.0.0.1:7897 https_proxy=http://127.0.0.1:7897 all_proxy=socks5h://127.0.0.1:7897
```

`xj19t` 最后那行 `SetEnv` 是隧道模式的关键：**非交互 ssh（`ssh xj19t '命令'`）不读 `/etc/profile.d`**，
拿不到设备上导出的 `http_proxy`，会出现"隧道明明通了却 curl 不出网"的怪现象。
`SetEnv` 把变量直接从客户端送进去，设备侧 `sshd_config` 的
`AcceptEnv http_proxy https_proxy all_proxy ...` 负责放行（只放行这几个名字）。
进了设备还要 `touch /run/proxy-enabled`，`50-proxy.sh` 才会真的导出。

`xj19` / `xj19w` 故意**不带** `SetEnv` 和 `RemoteForward`——WiFi 直连时多带一层代理只会绕远路，
而且一旦 PC 那边代理没开，`apk` 会卡死在死地址上。

想用密码就临时覆盖一下：

```bash
ssh -o PubkeyAuthentication=no root@192.168.42.129
```

## 密钥清单（`C:\Users\Clearwave\.ssh\`）

| 文件 | 说明 |
|---|---|
| `xj19_ed25519` | ed25519，无口令，主用 |
| `xj19_rsa` | RSA 2048，无口令，老客户端备用 |

设备端 `/root/.ssh/authorized_keys` 里两把都在，源头是 `dev/alpine/native/authorized_keys`，
改完跑 `dev/deploy-native.sh` 推送。

## 改密码 / 关掉密码登录

设备上直接改（立即生效，不用重启 sshd）：

```bash
printf 'root:新密码\n' | chpasswd
```

要恢复成纯密钥登录：把 `dev/alpine/native/sshd_config` 里
`PasswordAuthentication yes` 改回 `no`，然后 `dev/deploy-native.sh`，
再 `kill -HUP $(pidof sshd | awk '{print $NF}')` 重载监听器。

## 已知的兼容性坑

- **MobaXterm 版本太老**（大概 v12 以前）可能既不支持 ed25519，也只提供 SHA-1 的 `ssh-rsa`，
  而 OpenSSH 9+ 默认禁用 SHA-1。现在有密码登录兜底，一般不会卡在这一步。
- **WinSCP / FileZilla** 两种方式都支持：密码直接填，或指定 `xj19_ed25519`（不用转 `.ppk`）。
- **`KbdInteractiveAuthentication no`** 是故意的：Alpine 的 OpenSSH 没编译 PAM，
  键盘交互式认证没有后端可答，开着只会让客户端多试一轮再失败。
