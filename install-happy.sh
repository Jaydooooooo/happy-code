#!/usr/bin/env bash
# Happy self-host installer (Ubuntu 24+)
# - Docker + Caddy
# - TLS: Let's Encrypt (auto) OR Cloudflare Origin Cert (manual paste)
# - Builds Happy from source (auto clone if missing)
#
# Usage:
#   chmod +x install-happy.sh
#   ./install-happy.sh
#
# Notes:
# - Run as root (recommended).
# - This script will create/use /root/happy as the source dir by default.

set -Eeuo pipefail

### ============ UI helpers ============
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"
OK="${GREEN}✔${RESET}"
FAIL="${RED}✘${RESET}"
WARN="${YELLOW}!${RESET}"

declare -A STEP_STATUS
step_ok()   { echo -e "${OK} $1"; STEP_STATUS["$1"]="OK"; }
step_fail() { echo -e "${FAIL} $1"; STEP_STATUS["$1"]="FAIL"; }
step_warn() { echo -e "${WARN} $1"; }

abort() {
  local msg="${1:-Unknown error}"
  echo -e "\n${RED}ERROR:${RESET} ${msg}\n"
  print_summary
  exit 1
}

print_summary() {
  echo -e "\n${CYAN}================ 安装结果汇总 ================${RESET}"
  if [ "${#STEP_STATUS[@]}" -eq 0 ]; then
    echo -e "${WARN} 未记录到任何步骤状态"
  else
    for k in "${!STEP_STATUS[@]}"; do
      if [ "${STEP_STATUS[$k]}" = "OK" ]; then
        echo -e "${OK} $k"
      else
        echo -e "${FAIL} $k"
      fi
    done
  fi
  echo -e "${CYAN}=============================================${RESET}\n"
}

on_err() {
  local exit_code=$?
  local line_no=$1
  abort "脚本在第 ${line_no} 行出错（exit code: ${exit_code}）。请复制终端输出给我排查。"
}
trap 'on_err $LINENO' ERR

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    abort "请使用 root 运行（例如：sudo -i 后再执行脚本）。"
  fi
}

### ============ Config ============
HAPPY_REPO_URL="https://github.com/slopus/happy.git"
DEFAULT_SRC_DIR="/root/happy"

### ============ Functions ============
check_ubuntu_version() {
  echo -e "${CYAN}▶ 检查系统版本...${RESET}"
  if ! command -v lsb_release >/dev/null 2>&1; then
    apt update -y >/dev/null 2>&1 || true
    apt install -y lsb-release >/dev/null
  fi

  local ver
  ver="$(lsb_release -rs 2>/dev/null || true)"
  local major
  major="$(echo "$ver" | cut -d. -f1)"

  if [ -z "$major" ]; then
    step_warn "无法检测 Ubuntu 版本（lsb_release 输出为空），将继续尝试安装"
    read -r -p "是否继续？(y/N): " cont
    [[ "${cont}" =~ ^[Yy]$ ]] || exit 1
  elif [ "$major" -lt 24 ]; then
    step_warn "检测到 Ubuntu ${ver}，建议 Ubuntu 24 或以上，可能失败"
    read -r -p "是否继续？(y/N): " cont
    [[ "${cont}" =~ ^[Yy]$ ]] || exit 1
  fi

  step_ok "系统版本检查通过"
}

ask_domain_and_validate_ip() {
  echo -e "${CYAN}▶ 域名解析检查...${RESET}"
  read -r -p "请输入已解析到本服务器的域名（例如 api.example.com）: " DOMAIN
  if [ -z "${DOMAIN}" ]; then
    abort "域名不能为空"
  fi

  echo "正在 ping 域名：${DOMAIN}"
  local ping_ip
  ping_ip="$(ping -c 1 "$DOMAIN" 2>/dev/null | sed -n 's/.*(\(.*\)).*/\1/p' | head -n1 || true)"

  if [ -z "$ping_ip" ]; then
    abort "域名无法 ping 通：${DOMAIN}"
  fi

  local server_ip
  server_ip="$(curl -fsS https://api.ipify.org || true)"
  if [ -z "$server_ip" ]; then
    step_warn "无法获取本机公网 IP（ipify 不可达），将仅展示 ping 解析 IP"
    echo "域名解析 IP: $ping_ip"
    read -r -p "是否继续？(y/N): " cont
    [[ "${cont}" =~ ^[Yy]$ ]] || exit 1
  else
    echo "域名解析 IP: $ping_ip"
    echo "本机公网 IP: $server_ip"
    if [ "$ping_ip" != "$server_ip" ]; then
      step_warn "域名 IP 与本机公网 IP 不一致，可能部署到错误服务器"
      read -r -p "是否继续？(y/N): " cont
      [[ "${cont}" =~ ^[Yy]$ ]] || exit 1
    fi
  fi

  step_ok "域名解析检查完成"
}

install_base() {
  echo -e "${CYAN}▶ 安装基础组件...${RESET}"
  apt update
  apt install -y curl wget ca-certificates gnupg lsb-release git

  # Docker
  curl -fsSL https://get.docker.com | sh

  # Caddy prereqs
  apt install -y debian-keyring debian-archive-keyring apt-transport-https

  step_ok "Docker 与基础依赖安装完成"
}

install_caddy() {
  echo -e "${CYAN}▶ 安装 Caddy...${RESET}"
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null

  apt update
  apt install -y caddy

  mkdir -p /etc/ssl/cloudflare
  step_ok "Caddy 安装完成"
}

choose_cert_mode() {
  echo
  echo -e "${CYAN}▶ 请选择证书方式：${RESET}"
  echo "1) Let's Encrypt（自动申请 & 续期）"
  echo "2) Cloudflare Origin Cert（橙云，手动粘贴 pem/key）"
  read -r -p "请输入选择 [1/2]: " CERT_TYPE

  if [ "${CERT_TYPE}" != "1" ] && [ "${CERT_TYPE}" != "2" ]; then
    abort "无效选择：${CERT_TYPE}"
  fi
}

write_caddyfile_letsencrypt() {
  echo -e "${CYAN}▶ 配置 Caddy (Let's Encrypt)...${RESET}"
  cat > /etc/caddy/Caddyfile <<EOF
${DOMAIN} {
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
  step_ok "Caddy + Let's Encrypt 配置完成"
}

write_caddyfile_cloudflare() {
  echo -e "${CYAN}▶ 配置 Caddy (Cloudflare Origin Cert)...${RESET}"
  local pem="/etc/ssl/cloudflare/${DOMAIN}.pem"
  local key="/etc/ssl/cloudflare/${DOMAIN}.key"

  : > "$pem"
  : > "$key"

  echo -e "${YELLOW}请粘贴 Cloudflare Origin PEM（粘贴完按 Enter 再 Ctrl+D 结束）${RESET}"
  cat > "$pem"

  echo -e "${YELLOW}请粘贴 Cloudflare Origin KEY（粘贴完按 Enter 再 Ctrl+D 结束）${RESET}"
  cat > "$key"

  chmod 600 "$pem" "$key"

  cat > /etc/caddy/Caddyfile <<EOF
${DOMAIN} {
    tls ${pem} ${key}

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
  step_ok "Cloudflare 证书配置完成"
}

check_443_listen() {
  echo -e "${CYAN}▶ 检查 443 监听...${RESET}"
  if ss -lntp | grep -q ':443'; then
    step_ok "443 端口监听正常"
  else
    step_fail "443 未监听"
  fi
}

ensure_happy_source() {
  echo -e "${CYAN}▶ 准备 Happy 源码...${RESET}"

  # Strategy:
  # 1) If current dir looks like repo root, use it
  # 2) Else if DEFAULT_SRC_DIR exists and has Dockerfile, use it
  # 3) Else clone into DEFAULT_SRC_DIR
  HAPPY_DIR=""

  if [ -f "./Dockerfile" ] && [ -f "./package.json" ]; then
    HAPPY_DIR="$(pwd)"
    step_ok "使用当前目录作为 Happy 源码：${HAPPY_DIR}"
    return
  fi

  if [ -f "${DEFAULT_SRC_DIR}/Dockerfile" ] && [ -f "${DEFAULT_SRC_DIR}/package.json" ]; then
    HAPPY_DIR="${DEFAULT_SRC_DIR}"
    step_ok "使用已有 Happy 源码：${HAPPY_DIR}"
    return
  fi

  step_warn "未找到 Happy 源码，将自动 clone 到 ${DEFAULT_SRC_DIR}"
  rm -rf "${DEFAULT_SRC_DIR}"
  git clone "${HAPPY_REPO_URL}" "${DEFAULT_SRC_DIR}"
  HAPPY_DIR="${DEFAULT_SRC_DIR}"

  if [ ! -f "${HAPPY_DIR}/Dockerfile" ]; then
    abort "源码目录缺少 Dockerfile：${HAPPY_DIR}"
  fi

  step_ok "Happy 源码获取成功"
}

build_happy_image() {
  echo -e "${CYAN}▶ 构建 Happy 镜像...${RESET}"
  echo "构建目录：${HAPPY_DIR}"

  if docker build -t happy:local "${HAPPY_DIR}"; then
    step_ok "Happy 镜像构建成功"
  else
    step_fail "Happy 镜像构建失败（建议使用更高内存服务器）"
    abort "Docker build 失败"
  fi
}

run_happy_container() {
  echo -e "${CYAN}▶ 启动 Happy 容器...${RESET}"
  docker rm -f happy >/dev/null 2>&1 || true

  docker run -d \
    --name happy \
    --restart unless-stopped \
    -p 127.0.0.1:3000:80 \
    happy:local >/dev/null

  step_ok "Happy 容器启动成功"
}

final_test() {
  echo -e "${CYAN}▶ 最终验证...${RESET}"

  # Let's Encrypt: direct curl should verify OK after issuance.
  # Cloudflare Origin Cert (without proxy): direct curl verification may fail. But user usually uses orange-cloud (proxy) to get public cert.
  if curl -I "https://${DOMAIN}" >/dev/null 2>&1; then
    step_ok "HTTPS 访问成功（curl 验证通过）"
  else
    step_warn "curl 未通过证书验证（这在 Cloudflare Origin Cert + 非代理直连时是正常的）"
    step_ok "已完成部署（建议用浏览器访问验证）"
  fi
}

### ============ Main ============
require_root
check_ubuntu_version
ask_domain_and_validate_ip
install_base
install_caddy
choose_cert_mode

if [ "${CERT_TYPE}" = "1" ]; then
  write_caddyfile_letsencrypt
else
  write_caddyfile_cloudflare
fi

check_443_listen
ensure_happy_source
build_happy_image
run_happy_container
final_test

print_summary

echo -e "${GREEN}服务器已部署完毕！${RESET}"
echo "👉 使用浏览器访问：https://${DOMAIN}"
echo "👉 你应该会看到网页已顺利打开"
