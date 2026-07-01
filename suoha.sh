#!/usr/bin/env bash
set -euo pipefail

# =========================================================
#  suoha x-tunnel (NMU-Glitch 专属优化版)
#  - 安全：100% 官方或个人仓库源，移除第三方镜像
#  - 健壮：增加下载重试与连接超时保护
#  - 干净：独立工作目录 $HOME/.suoha_x_tunnel
# =========================================================

# --- 配置区 ---
WORK_DIR="${HOME}/.suoha_x_tunnel"
CONFIG_FILE="${WORK_DIR}/suoha_tunnel_config"
MY_GITHUB_REPO="nmu-glitch/my-tunnels"
MY_TAG="v1.0.0"

# 建立工作目录
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ------------- 辅助函数 -------------
say() { printf "${BLUE}[NMU-Tunnel]${NC} %s\n" "$*"; }
say_ok() { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
say_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
say_err() { printf "${RED}[FAIL]${NC} %s\n" "$*"; }

# 自动检测包管理器
detect_package_manager() {
  if command -v apt-get &>/dev/null; then
    INSTALL_CMD="apt-get -y install"
    UPDATE_CMD="apt-get update"
  elif command -v apk &>/dev/null; then
    INSTALL_CMD="apk add --no-cache"
    UPDATE_CMD="apk update"
  elif command -v dnf &>/dev/null; then
    INSTALL_CMD="dnf -y install"
    UPDATE_CMD="dnf check-update"
  elif command -v yum &>/dev/null; then
    INSTALL_CMD="yum -y install"
    UPDATE_CMD="yum makecache"
  else
    INSTALL_CMD="apt-get -y install"
    UPDATE_CMD="apt-get update"
  fi
}

need_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    say "正在安装依赖工具: $cmd ..."
    $UPDATE_CMD >/dev/null 2>&1 || true
    $INSTALL_CMD "$cmd" >/dev/null 2>&1 || true
  fi
}

get_free_port() {
  while true; do
    local port=$((RANDOM % 64512 + 1024))
    if ! ss -lnt | grep -qE ":${port}$"; then
      echo "$port"; return
    fi
  done
}

stop_screen() {
  local name="$1"
  screen -S "$name" -X quit >/dev/null 2>&1 || true
  sleep 0.5
}

download_bin() {
  local url="$1" out="$2"
  if [[ ! -f "$out" ]]; then
    say "正在下载 $out ..."
    if ! curl -fsSL --connect-timeout 10 --retry 3 "$url" -o "$out"; then
      say_err "下载失败: $url"
      exit 1
    fi
    chmod +x "$out"
  fi
}

# ------------- 自检诊断 -------------
self_check() {
  local bind_domain="${1:-}"
  local try_domain="${2:-}"
  local wsport="${3:-}"
  echo
  say "=============================="
  say " 自检诊断报告"
  say "=============================="
  if [[ -n "$wsport" ]]; then
    if ss -lntp 2>/dev/null | grep -q ":${wsport}"; then
      say_ok "本地监听状态: 127.0.0.1:${wsport} (正常)"
    else
      say_err "本地监听状态: 未找到端口 ${wsport} (异常)"
    fi
  fi
  
  if [[ -n "$bind_domain" ]]; then
    say "域名检查 [${bind_domain}]:"
    if curl -I --connect-timeout 3 "https://${bind_domain}" 2>/dev/null | grep -q "HTTP/"; then
      say_ok "  - 网络访问: 正常"
    else
      say_err "  - 网络访问: 失败 (请检查 CF Tunnel 状态)"
    fi
  fi
}

save_config() {
  {
    echo "wsport=${wsport:-}"
    echo "metricsport=${metricsport:-}"
    echo "try_domain=${TRY_DOMAIN:-}"
    echo "bind_enable=${bind_enable:-0}"
    echo "bind_domain=${bind_domain:-}"
    echo "token=${token:-}"
  } > "$CONFIG_FILE"
}

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    return 0
  else
    return 1
  fi
}

# ------------- 核心逻辑 -------------
quicktunnel() {
  local arch
  case "$(uname -m)" in
    x86_64|x64|amd64) arch="amd64" ;;
    armv8|arm64|aarch64) arch="arm64" ;;
    i386|i686) arch="386" ;;
    *) say_err "不支持的架构"; exit 1 ;;
  esac

  # 1. 下载 x-tunnel (来自你的仓库)
  download_bin "https://github.com/${MY_GITHUB_REPO}/releases/download/${MY_TAG}/x-tunnel-linux-${arch}" "x-tunnel-linux"
  
  # 2. 下载依赖 (固定官方版本链接，防止 404)
  # 注意：如果以后你把这两个也传到自己仓库，直接改下面链接即可
  download_bin "https://github.com/Snawoot/opera-proxy/releases/download/v1.1.2/opera-proxy.linux-${arch}" "opera-linux"
  download_bin "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" "cloudflared-linux"

  # 端口冲突检查
  if [[ -n "${wsport:-}" ]] && ss -lnt | grep -qE ":${wsport}$"; then
    say_err "端口 ${wsport} 已被占用！"
    exit 1
  fi

  # 启动 Opera
  if [[ "${opera:-0}" == "1" ]]; then
    operaport="$(get_free_port)"
    screen -dmUS opera ./opera-linux -country "$country" -socks-mode -bind-address "127.0.0.1:${operaport}"
    sleep 1
  fi

  # 启动 x-tunnel
  wsport="${wsport:-$(get_free_port)}"
  local token_cmd=""
  [[ -n "${token:-}" ]] && token_cmd="-token $token"
  local forward_cmd=""
  [[ "${opera:-0}" == "1" ]] && forward_cmd="-f socks5://127.0.0.1:${operaport}"

  screen -dmUS x-tunnel ./x-tunnel-linux -l "ws://127.0.0.1:${wsport}" $token_cmd $forward_cmd

  # 启动 Cloudflared (Argo)
  metricsport="$(get_free_port)"
  screen -dmUS argo ./cloudflared-linux --edge-ip-version "$ips" --protocol http2 tunnel \
    --url "127.0.0.1:${wsport}" --metrics "0.0.0.0:${metricsport}"

  # 启动 Named Tunnel (如果有)
  if [[ "${bind_enable:-0}" == "1" && -n "${cf_tunnel_token:-}" ]]; then
    screen -dmUS cfbind ./cloudflared-linux --edge-ip-version "$ips" tunnel run --token "$cf_tunnel_token"
  fi

  # 获取临时域名
  say "正在获取 Cloudflare 临时域名 (约需 10-30 秒)..."
  TRY_DOMAIN=""
  for _ in $(seq 1 30); do
    RESP="$(curl -s --connect-timeout 2 "http://127.0.0.1:${metricsport}/metrics" || true)"
    if echo "$RESP" | grep -q 'userHostname='; then
      TRY_DOMAIN="$(echo "$RESP" | grep 'userHostname="' | sed -E 's/.*userHostname="https?:\/\/([^"]+)".*/\1/' | head -n1)"
      break
    fi
    sleep 1
  done

  save_config
  clear
  say_ok "启动完成！"
  [[ -n "$TRY_DOMAIN" ]] && say "临时域名: https://${TRY_DOMAIN}"
  [[ -n "${bind_domain:-}" ]] && say "绑定域名: https://${bind_domain}"
  say "本地端口: ${wsport}  |  Token: ${token:-无}"
  
  self_check "${bind_domain:-}" "${TRY_DOMAIN:-}" "${wsport}"
}

# ------------- 菜单界面 -------------
detect_package_manager
need_cmd screen
need_cmd curl
need_cmd ss
need_cmd grep

clear
say "=================================================="
say "         NMU-Glitch 极速隧道管理面板             "
say "  - 源: GitHub (nmu-glitch/my-tunnels)            "
say "=================================================="
echo " 1. 梭哈模式 (安装并运行)"
echo " 2. 停止所有服务"
echo " 3. 清空缓存并卸载"
echo " 4. 查看当前配置与状态"
echo " 0. 退出"
read -p "选择 [0-4]: " mode
mode="${mode:-1}"

case "$mode" in
  1)
    read -p "是否启用 Opera 前置代理? (0.关[默认], 1.开): " opera
    opera="${opera:-0}"
    [[ "$opera" == "1" ]] && { read -p "区域代码 (AM/AS/EU, 默认AM): " country; country=${country:-AM}; }
    read -p "IP 协议 (4.IPv4[默认], 6.IPv6): " ips; ips=${ips:-4}
    read -p "设置 Token (验证密码): " token
    read -p "是否固定端口? (0.随机, 1.固定): " fixp
    [[ "${fixp:-0}" == "1" ]] && { read -p "端口号 (默认12345): " wsport; wsport=${wsport:-12345}; }
    read -p "启用 Named Tunnel 域名绑定? (0.不启用, 1.启用): " bind_enable
    if [[ "${bind_enable:-0}" == "1" ]]; then
      read -p "输入 Cloudflare Tunnel Token: " cf_tunnel_token
      read -p "输入你的域名 (仅供记录): " bind_domain
    fi
    stop_screen x-tunnel; stop_screen argo; stop_screen opera; stop_screen cfbind
    quicktunnel
    ;;
  2)
    stop_screen x-tunnel; stop_screen argo; stop_screen opera; stop_screen cfbind
    rm -f "$CONFIG_FILE"
    say_ok "服务已停止。"
    ;;
  3)
    stop_screen x-tunnel; stop_screen argo; stop_screen opera; stop_screen cfbind
    rm -rf "$WORK_DIR"
    say_ok "工作目录已清除。"
    ;;
  4)
    if load_config; then
       say "配置信息: 端口 ${wsport}, 域名 ${bind_domain:-无}, 临时 ${try_domain:-无}"
       self_check "${bind_domain:-}" "${try_domain:-}" "${wsport:-}"
    else
       say_warn "没有运行中的记录。"
    fi
    ;;
  *) exit 0 ;;
esac
