#!/usr/bin/env bash
set +e

### ===== 颜色 & 符号 =====
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"
OK="${GREEN}✔${RESET}"
FAIL="${RED}✘${RESET}"

declare -A STEP_STATUS

log_ok()   { echo -e "$OK $1"; STEP_STATUS["$1"]="OK"; }
log_fail() { echo -e "$FAIL $1"; STEP_STATUS["$1"]="FAIL"; }
log_warn() { echo -e "${YELLOW}! $1${RESET}"; }

### ===== Step 1: 系统检查 =====
echo "▶ 检查系统版本..."
if ! command -v lsb_release >/dev/null 2>&1; then
  log_fail "无法检测系统版本"
  exit 1
fi

OS_VERSION=$(lsb_release -rs | cut -d. -f1)
if [ "$OS_VERSION" -lt 24 ]; then
  log_warn "检测到 Ubuntu $OS_VERSION，建议 Ubuntu 24 或以上"
  read -p "是否继续安装？(y/N): " cont
  [[ "$cont" != "y" && "$cont" != "Y" ]] && exit 1
fi
log_ok "系统版本检查通过"

### ===== Step 2: 域名与 IP 校验 =====
read -p "请输入已解析到本服务器的域名（例如 api.example57.com）: " DOMAIN

echo "▶ 正在 ping 域名 $DOMAIN ..."
PING_IP=$(ping -c 1 "$DOMAIN" 2>/dev/null | sed -n 's/.*(\(.*\)).*/\1/p')
if [ -z "$PING_IP" ]; then
  log_fail "域名无法 ping 通"
  exit 1
fi

SERVER_IP=$(curl -s https://api.ipify.org)
echo "域名解析 IP: $PING_IP"
echo "本机公网 IP: $SERVER_IP"

if [ "$PING_IP" != "$SERVER_IP" ]; then
  log_warn "域名 IP 与本机 IP 不一致，可能安装到错误服务器"
  read -p "是否继续？(y/N): " cont
  [[ "$cont" != "y" && "$cont" != "Y" ]] && exit 1
fi
log_ok "域名解析检查完成"

### ===== Step 3: 基础依赖 =====
echo "▶ 安装基础组件..."
apt update && \
apt install -y curl wget ca-certificates gnupg lsb-release git && \
curl -fsSL https://get.docker.com | sh && \
apt install -y debian-keyring debian-archive-keyring apt-transport-https && \
log_ok "Docker 与基础依赖安装完成" || log_fail "基础依赖安装失败"

### ===== Step 4: 安装 Caddy =====
echo "▶ 安装 Caddy..."
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg && \
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list && \
apt update && apt install -y caddy && \
log_ok "Caddy 安装完成" || log_fail "Caddy 安装失败"

mkdir -p /etc/ssl/cloudflare

### ===== Step 5: 证书选择 =====
echo
echo "请选择证书方式："
echo "1) Let's Encrypt（自动申请 & 续期）"
echo "2) Cloudflare Origin Cert（橙云，手动粘贴）"
read -p "请输入选择 [1/2]: " CERT_TYPE

if [ "$CERT_TYPE" == "1" ]; then
  cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
    reverse_proxy 127.0.0.1:3000
}
EOF

  systemctl reload caddy || systemctl restart caddy
  log_ok "Caddy + Let's Encrypt 配置完成"

elif [ "$CERT_TYPE" == "2" ]; then
  PEM="/etc/ssl/cloudflare/$DOMAIN.pem"
  KEY="/etc/ssl/cloudflare/$DOMAIN.key"
  touch "$PEM" "$KEY"

  echo "▶ 请粘贴 Cloudflare Origin PEM（Ctrl+D 结束）"
  cat > "$PEM"
  echo "▶ 请粘贴 Cloudflare Origin KEY（Ctrl+D 结束）"
  cat > "$KEY"

  cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
    tls $PEM $KEY

    encode gzip

    reverse_proxy 127.0.0.1:3000 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto https
    }
}
EOF

  systemctl reload caddy || systemctl restart caddy
  log_ok "Cloudflare 证书配置完成"
else
  log_fail "无效的证书选择"
  exit 1
fi

### ===== Step 6: 验证 443 =====
ss -lntp | grep ':443' >/dev/null \
  && log_ok "443 端口监听正常" \
  || log_fail "443 未监听"

### ===== Step 7: 定位/获取 Happy 源码目录 =====
echo "▶ 定位 Happy 源码目录..."

HAPPY_DIR=""

# 1) 优先使用当前目录（如果有 Dockerfile）
if [ -f "./Dockerfile" ] && [ -f "./package.json" ]; then
  HAPPY_DIR="$(pwd)"
fi

# 2) 尝试 /root/happy
if [ -z "$HAPPY_DIR" ] && [ -f "/root/happy/Dockerfile" ]; then
  HAPPY_DIR="/root/happy"
fi

# 3) 尝试 /etc/happy（你现在就在这里）
if [ -z "$HAPPY_DIR" ] && [ -f "/etc/happy/Dockerfile" ]; then
  HAPPY_DIR="/etc/happy"
fi

# 4) 找不到就 clone 到 /root/happy
if [ -z "$HAPPY_DIR" ]; then
  log_warn "未找到 Happy 源码，将自动 clone 到 /root/happy"
  rm -rf /root/happy
  if git clone https://github.com/slopus/happy.git /root/happy; then
    HAPPY_DIR="/root/happy"
    log_ok "Happy 源码获取成功"
  else
    log_fail "Happy 源码获取失败"
    exit 1
  fi
else
  log_ok "已找到 Happy 源码：$HAPPY_DIR"
fi

# 最终兜底检查
if [ ! -f "$HAPPY_DIR/Dockerfile" ]; then
  log_fail "Happy 源码目录无 Dockerfile：$HAPPY_DIR"
  exit 1
fi

### ===== Step 8: 构建 Happy（使用找到的 HAPPY_DIR） =====
echo "▶ 构建 Happy 镜像（路径：$HAPPY_DIR）..."
if docker build -t happy:local "$HAPPY_DIR"; then
  log_ok "Happy 镜像构建成功"
else
  log_fail "Happy 镜像构建失败（建议使用更高内存服务器）"
  exit 1
fi

### ===== Step 9: 运行容器 =====
docker rm -f happy >/dev/null 2>&1

docker run -d \
  --name happy \
  --restart unless-stopped \
  -p 127.0.0.1:3000:80 \
  happy:local \
  && log_ok "Happy 容器启动成功" \
  || log_fail "Happy 容器启动失败"

### ===== Step 10: 最终验证 =====
echo "▶ 验证访问..."
if curl -Ik "https://$DOMAIN" >/dev/null 2>&1; then
  log_ok "HTTPS 访问成功"
else
  log_fail "HTTPS 访问失败"
fi

### ===== 总结 =====
echo
echo "================ 安装结果汇总 ================"
for k in "${!STEP_STATUS[@]}"; do
  [[ "${STEP_STATUS[$k]}" == "OK" ]] \
    && echo -e "$OK $k" \
    || echo -e "$FAIL $k"
done

echo
echo -e "${GREEN}服务器已部署完毕！${RESET}"
echo "👉 使用浏览器访问：https://$DOMAIN"
echo "👉 你应该会看到网页已顺利打开"
