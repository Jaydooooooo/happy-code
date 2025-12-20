#!/usr/bin/env bash
set -Eeuo pipefail

# ================= UI =================
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"
OK="${GREEN}✔${RESET}"
FAIL="${RED}✘${RESET}"
WARN="${YELLOW}!${RESET}"

declare -A STEP_STATUS

ok(){ echo -e "${OK} $1"; STEP_STATUS["$1"]="OK"; }
bad(){ echo -e "${FAIL} $1"; STEP_STATUS["$1"]="FAIL"; }
warn(){ echo -e "${WARN} $1"; }

summary(){
  echo -e "\n${CYAN}================ 安装结果汇总 ================${RESET}"
  if [ "${#STEP_STATUS[@]}" -eq 0 ]; then
    echo -e "${WARN} 未记录到步骤状态"
  else
    for k in "${!STEP_STATUS[@]}"; do
      [[ "${STEP_STATUS[$k]}" == "OK" ]] && echo -e "${OK} $k" || echo -e "${FAIL} $k"
    done
  fi
  echo -e "${CYAN}=============================================${RESET}\n"
}

abort(){
  echo -e "\n${RED}ERROR:${RESET} ${1:-Unknown error}\n"
  summary
  exit 1
}

trap 'abort "脚本在第 $LINENO 行出错，请把终端输出原样贴出来"' ERR

if [[ $EUID -ne 0 ]]; then
  abort "请使用 root 执行（sudo -i 后运行或 sudo bash 脚本）"
fi

# ================= Step 1: OS check =================
echo -e "${CYAN}▶ 检查系统版本...${RESET}"
if ! command -v lsb_release >/dev/null 2>&1; then
  apt update -y >/dev/null 2>&1 || true
  apt install -y lsb-release >/dev/null
fi

OS_MAJOR="$(lsb_release -rs | cut -d. -f1 || true)"
if [[ -z "$OS_MAJOR" ]]; then
  warn "无法检测 Ubuntu 版本，可能失败"
  read -r -p "是否继续？(y/N): " cont
  [[ "$cont" =~ ^[Yy]$ ]] || exit 1
elif [[ "$OS_MAJOR" -lt 24 ]]; then
  warn "检测到 Ubuntu 版本低于 24，可能失败"
  read -r -p "是否继续？(y/N): " cont
  [[ "$cont" =~ ^[Yy]$ ]] || exit 1
fi
ok "系统版本检查通过"

# ================= Step 2: Domain + ping check =================
read -r -p "请输入已解析好的域名（例如 api.duduu.cc）: " DOMAIN
[[ -n "$DOMAIN" ]] || abort "域名不能为空"

echo -e "${CYAN}▶ ping 测试域名解析...${RESET}"
PING_IP="$(ping -c 1 "$DOMAIN" 2>/dev/null | sed -n 's/.*(\(.*\)).*/\1/p' | head -n1 || true)"
[[ -n "$PING_IP" ]] || abort "域名无法 ping 通：$DOMAIN"

SERVER_IP="$(curl -fsS https://api.ipify.org || true)"
echo "域名解析 IP: $PING_IP"
if [[ -n "$SERVER_IP" ]]; then
  echo "本机公网 IP: $SERVER_IP"
  if [[ "$PING_IP" != "$SERVER_IP" ]]; then
    warn "域名解析 IP 与本机公网 IP 不一致，可能不是目标服务器"
    read -r -p "是否继续？(y/N): " cont
    [[ "$cont" =~ ^[Yy]$ ]] || exit 1
  fi
else
  warn "无法获取本机公网 IP（ipify 不可用），仅完成 ping 校验"
  read -r -p "是否继续？(y/N): " cont
  [[ "$cont" =~ ^[Yy]$ ]] || exit 1
fi
ok "域名解析检查完成"

# ================= Step 3: Run commands =================
echo -e "${CYAN}▶ 安装 Docker 与基础依赖...${RESET}"
apt update
curl -fsSL https://get.docker.com | sh
apt install -y debian-keyring debian-archive-keyring apt-transport-https
ok "Docker 与基础依赖安装完成"

echo -e "${CYAN}▶ 安装 Caddy...${RESET}"
# ensure gpg exists
apt install -y gnupg curl >/dev/null 2>&1 || true
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
apt update && apt install -y caddy
ok "Caddy 安装完成"

mkdir -p /etc/ssl/cloudflare
ok "证书目录准备完成"

# ================= Step 4: Cert mode =================
echo
echo "请选择证书方式："
echo "1) Let's Encrypt【自动申请续期】"
echo "2) Cloudflare【橙云，自行上传证书】"
read -r -p "请输入选择 [1/2]: " CERT_MODE

if [[ "$CERT_MODE" != "1" && "$CERT_MODE" != "2" ]]; then
  abort "无效选择：$CERT_MODE"
fi

# ---------- Mode 1: Let's Encrypt ----------
if [[ "$CERT_MODE" == "1" ]]; then
  echo -e "${CYAN}▶ Let's Encrypt 方式：申请证书并自动续期...${RESET}"
  apt install -y certbot

  # stop caddy to free :80 for certbot standalone
  systemctl stop caddy >/dev/null 2>&1 || true

  certbot certonly --standalone --non-interactive --agree-tos \
    -m "admin@${DOMAIN}" -d "${DOMAIN}" \
    || abort "Let's Encrypt 证书申请失败（确认 80 端口可达、域名指向本机）"

  cat > /etc/caddy/Caddyfile <<EOF
${DOMAIN} {
    tls /etc/letsencrypt/live/${DOMAIN}/fullchain.pem /etc/letsencrypt/live/${DOMAIN}/privkey.pem

    encode gzip

    reverse_proxy 127.0.0.1:3000 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto https
    }
}
EOF

  systemctl start caddy
  systemctl reload caddy || systemctl restart caddy

  # renew every 60 days
  cat > /etc/cron.d/happy-certbot <<EOF
# Happy certbot renew (every 60 days)
0 3 */60 * * root certbot renew --quiet --deploy-hook 'systemctl reload caddy || systemctl restart caddy'
EOF

  ok "Let's Encrypt 配置完成"
fi

# ---------- Mode 2: Cloudflare (Ctrl+D end) ----------
if [[ "$CERT_MODE" == "2" ]]; then
  echo -e "${CYAN}▶ Cloudflare 方式：粘贴 pem/key（用 Ctrl+D 结束）...${RESET}"

  PEM="/etc/ssl/cloudflare/${DOMAIN}.pem"
  KEY="/etc/ssl/cloudflare/${DOMAIN}.key"

  : > "$PEM"
  : > "$KEY"
  chmod 600 "$PEM" "$KEY" || true

  echo
  echo -e "${YELLOW}请粘贴 Cloudflare Origin PEM，粘贴完成后按 Ctrl+D 结束：${RESET}"
  cat > "$PEM"

  echo
  echo -e "${YELLOW}请粘贴 Cloudflare Origin KEY，粘贴完成后按 Ctrl+D 结束：${RESET}"
  cat > "$KEY"

  cat > /etc/caddy/Caddyfile <<EOF
${DOMAIN} {
    tls ${PEM} ${KEY}

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
  ok "Cloudflare 证书配置完成"
fi

# ================= Step 5: Caddy reload + 443 check =================
echo -e "${CYAN}▶ 检查 443 监听...${RESET}"
if ss -lntp | grep -q ':443'; then
  ok "443 端口监听正常"
else
  bad "443 未监听"
fi

# ================= Step 6: Build Happy =================
echo -e "${CYAN}▶ 准备 Happy 源码...${RESET}"
apt install -y git >/dev/null 2>&1 || true

if [[ ! -d /root/happy ]]; then
  git clone https://github.com/slopus/happy /root/happy
  ok "Happy 源码已拉取"
else
  ok "Happy 源码目录已存在"
fi

echo -e "${CYAN}▶ 构建 Happy 镜像...${RESET}"
set +e
BUILD_OUT="$(docker build -t happy:local /root/happy 2>&1)"
RC=$?
set -e
if [[ $RC -ne 0 ]]; then
  echo "$BUILD_OUT"
  bad "Happy 镜像构建失败"
  echo "$BUILD_OUT" | grep -qiE "heap out of memory|Reached heap limit|Allocation failed" \
    && warn "检测到构建内存不足（OOM），请提高服务器内存规格后重试。"
  abort "docker build 失败"
fi
ok "Happy 镜像构建成功"

# ================= Step 7: Run container =================
echo -e "${CYAN}▶ 启动 Happy 容器...${RESET}"
docker rm -f happy >/dev/null 2>&1 || true
docker run -d \
  --name happy \
  --restart unless-stopped \
  -p 127.0.0.1:3000:80 \
  happy:local >/dev/null
ok "Happy 容器启动成功"

# ================= Step 8: Final curl =================
echo -e "${CYAN}▶ 最终验证...${RESET}"
if curl -I "https://${DOMAIN}" >/dev/null 2>&1; then
  ok "HTTPS 访问成功（curl 验证通过）"
else
  bad "HTTPS 访问失败（curl 未通过）"
  warn "如使用 Cloudflare Origin 证书且未开橙云，curl 直连可能会失败；请用浏览器验证。"
fi

summary
echo -e "${GREEN}服务器已部署完毕！${RESET}"
echo "使用浏览器访问：https://${DOMAIN} 你应该会看到网页已顺利打开"
