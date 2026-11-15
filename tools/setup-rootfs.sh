#!/bin/sh
# Alpine rootfs 落地配置 —— 在设备上以 chroot 执行
# 目标：得到一个可通过 adb forward 登录的 Alpine 环境
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export http_proxy=http://127.0.0.1:8888
export https_proxy=http://127.0.0.1:8888

echo "===== 1. 基础配置 ====="
printf 'alpine\n' > /etc/hostname
printf '127.0.0.1\tlocalhost alpine\n::1\t\tlocalhost\n' > /etc/hosts
printf 'nameserver 223.5.5.5\nnameserver 1.1.1.1\n' > /etc/resolv.conf

# 仓库走 HTTP：本机 TLS 栈不可用（musl+OpenSSL 在 3.10 内核上失败）
printf 'http://dl-cdn.alpinelinux.org/alpine/v3.24/main\nhttp://dl-cdn.alpinelinux.org/alpine/v3.24/community\n' > /etc/apk/repositories

# 禁止安装期自动起服务
cat > /usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x /usr/sbin/policy-rc.d

echo "===== 2. 更新索引 ====="
apk update 2>&1 | tail -3

echo "===== 3. 安装 sshd 与常用工具 ====="
apk add --no-progress openssh openrc busybox-extras 2>&1 | tail -6

echo "===== 4. root 密码 ====="
printf 'root:alpine\n' | chpasswd && echo "root password = alpine"

echo "===== 5. sshd 配置 ====="
mkdir -p /run/sshd /var/log
sed -i \
  -e 's/^#*PermitRootLogin.*/PermitRootLogin yes/' \
  -e 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' \
  -e 's/^#*Port .*/Port 2222/' \
  /etc/ssh/sshd_config
grep -E '^(Port|PermitRootLogin|PasswordAuthentication)' /etc/ssh/sshd_config
ssh-keygen -A 2>&1 | tail -2

cat > /usr/local/bin/start-sshd.sh <<'EOF'
#!/bin/sh
mkdir -p /run/sshd
[ -f /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -A
exec /usr/sbin/sshd -D -p 2222 -o PermitRootLogin=yes -o PasswordAuthentication=yes
EOF
chmod +x /usr/local/bin/start-sshd.sh

echo "===== 6. 结果 ====="
echo "alpine-release: $(cat /etc/alpine-release)"
echo "apk: $(apk --version)"
echo "sshd: $(/usr/sbin/sshd -V 2>&1 | head -1)"
df -h / 2>/dev/null | tail -1
