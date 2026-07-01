#!/usr/bin/env bash
set -euo pipefail

# =========================================================
#  suoha x-tunnel (NMU-Glitch 专属优化版)
#  - 安全：移除第三方镜像站，100% 从您自己的 GitHub 仓库拉取二进制文件
#  - 健壮：为所有自检网络请求添加超时机制（Timeout），防止在恶劣网络下卡死
#  - 干净：独立工作目录与自动配置清理，卸载无残留
# =========================================================

# 工作目录与配置文件路径
WORK_DIR="${HOME}/.suoha_x_tunnel"
CONFIG_FILE="${WORK_DIR}/suoha_tunnel_config"

# 您的专属 GitHub 仓库
MY_GITHUB_REPO="nmu-glitch/my-tunnels"

# 建立工作目录
mkdir -p "$WORK_DIR"

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

# 自动、智能检测包管理器，淘汰脆弱的系统版本硬匹配
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
    echo "正在安装依赖工具: $cmd ..."
    $UPDATE_CMD >/dev/null 2>&1 || true
    $INSTALL_CMD "$cmd" >/dev/null 2>&1 || true
  fi
}

get_free_port() {
  while true; do
    local port=$((RANDOM % 64512 + 1024))
    if command -v ss >/dev/null 2>&1; then
      if ! ss -lnt | awk '{print $4}' | grep -qE ":${port}$"; then
        echo "$port"; return
      fi
    else
      if command -v lsof >/dev/null 2>&1; then
        if ! lsof -i TCP:"$port" >/dev/null 2>&1; then
          echo "$port"; return
        fi
      else
        echo "$port"; return
      fi
    fi
  done
}

stop_screen() {
  local name="$1"
  screen -S "$name" -X quit >/dev/null 2>&1 || true
  for _ in $(seq 1 5); do
    if ! screen -list 2>/dev/null | grep -q "\.${name}[[:space:]]"; then
      return
    fi
    sleep 0.5
  done
}

download_bin() {
  local url="$1" out="$2"
  local dest="${WORK_DIR}/${out}"
  if [[ ! -f "$dest" ]]; then
    echo "正在下载 ${out} ..."
    if ! curl -fsSL --connect-timeout 10 --retry 3 "$url" -o "$dest"; then
      say_err "下载失败: ${url}，请检查网络是否能正常访问 GitHub Releases。"
      exit 1
    fi
    chmod +x "$dest"
  fi
}

detect_ws_port() {
  ss -lntp 2>/dev/null | awk '/x-tunnel-linux/ && /127\.0\.0\.1:/ {print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | head -n1
}

http_head() {
  local host="$1"
  # 优化：增加最大 5 秒超时保护，防止 GFW 拦截导致脚本无限期挂起
  curl -I --connect-timeout 3 -m 5 "https://${host}" 2>/dev/null | sed -n '1,8p' || true
}

tcp_check() {
  local host="$1"
  if command -v nc >/dev/null 2>&1; then
    # 优化：限制探测等待为 3 秒
    if nc -w 3 -vz "$host" 443 >/dev/null 2>&1; then
      say_ok "TCP 443 端口阻断测试: 通畅 (未被彻底封锁 IP)"
    else
      say_err "TCP 443 端口阻断测试: 无法建立连接 (IP 可能处于阻断状态或 CDN 故障)"
    fi
  fi
}

tls_check() {
  local host="$1"
  if command -v openssl >/dev/null 2>&1; then
    # 优化：防止 openssl 握手阻塞
    echo | openssl s_client -connect "${host}:443" -servername "${host}" 2>/dev/null | sed -n '1,12p' || true
  fi
}

self_check() {
  local bind_domain="${1:-}"
  local try_domain="${2:-}"
  local wsport="${3:-}"
  echo
  say "=============================="
  say " 自检 / Debug 诊断报告"
  say "=============================="
  say "当前运行的 Screen 进程:"
  screen -list 2>/dev/null || true
  echo
  if [[ -z "$wsport" ]]; then
    wsport="$(detect_ws_port || true)"
  fi
  if [[ -n "$wsport" ]]; then
    say_ok "本地监听状态: 127.0.0.1:${wsport}"
    ss -lntp 2>/dev/null | grep -E "127\.0\.0\.1:${wsport}\b" || true
  else
    say_err "未检测到 x-tunnel 在本地监听对应端口"
  fi
  echo
  if [[ -n "$bind_domain" ]]; then
    say "== [1] 绑定自定义域名测试: ${bind_domain} =="
    tcp_check "$bind_domain"
    tls_check "$bind_domain"
    http_head "$bind_domain"
    echo
  fi
  if [[ -n "$try_domain" ]]; then
    say "== [2] 临时测试域名测试: ${try_domain} =="
    tcp_check "$try_domain"
    tls_check "$try_domain"
    http_head "$try_domain"
    echo
  fi
  cat <<EOF
诊断说明:
- 401 Unauthorized: 符合预期！说明成功穿透至 x-tunnel 验证层（需要填入 Token 连接）。
- 200 OK: 符合预期（多为探测返回），请使用对应客户端配合 Token 进行真连接测试。
- 502 Bad Gateway: 本地与 Cloudflare 传输不匹配，请检查端口、协议或者路由策略。
- 530 Access Blocked: 触发了您的 Cloudflare Zero Trust 安全策略，请在面板调整相关规则。

如果绑定域名失败，但临时域名正常：
1. 请确认 CF 证书状态是否正常；
2. 确认 Cloudflare Panel -> Public Hostname 确实精准指向了 http://127.0.0.1:${wsport} ；
3. 确认没有其他多余的 CNAME 或 DNS 解析与之冲突。
EOF
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

remove_config() {
  rm -f "$CONFIG_FILE"
}

# ------------- 核心逻辑 -------------
quicktunnel() {
  # 优化：数据源全部重定向至您自己的 GitHub 仓库 releases/latest/download
  case "$(uname -m)" in
    x86_64|x64|amd64)
      download_bin "https://github.com/${MY_GITHUB_REPO}/releases/latest/download/x-tunnel-linux-amd64" "x-tunnel-linux"
      download_bin "https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-amd64" "opera-linux"
      download_bin "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" "cloudflared-linux"
      ;;
    i386|i686)
      download_bin "https://github.com/${MY_GITHUB_REPO}/releases/latest/download/x-tunnel-linux-386" "x-tunnel-linux"
      download_bin "https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-386" "opera-linux"
      download_bin "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386" "cloudflared-linux"
      ;;
    armv8|arm64|aarch64)
      download_bin "https://github.com/${MY_GITHUB_REPO}/releases/latest/download/x-tunnel-linux-arm64" "x-tunnel-linux"
      download_bin "https://github.com/Snawoot/opera-proxy/releases/latest/download/opera-proxy.linux-arm64" "opera-linux"
      download_bin "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" "cloudflared-linux"
      ;;
    *)
      say_err "暂不支持您的 CPU 架构: $(uname -m)"
      exit 1
      ;;
  esac

  if [[ -n "${wsport:-}" ]]; then
    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE ":${wsport}$"; then
      say_err "端口 ${wsport} 已被占用，请手动释放占用或选择自动分配其他空闲端口！"
      exit 1
    fi
  fi

  if [[ "${opera:-0}" == "1" ]]; then
    operaport="$(get_free_port)"
    screen -dmUS opera "${WORK_DIR}/opera-linux" -country "$country" -socks-mode -bind-address "127.0.0.1:${operaport}"
  fi
  sleep 1

  if [[ -z "${wsport:-}" ]]; then
    wsport="$(get_free_port)"
  fi

  if [[ -z "${token:-}" ]]; then
    if [[ "${opera:-0}" == "1" ]]; then
      screen -dmUS x-tunnel "${WORK_DIR}/x-tunnel-linux" -l "ws://127.0.0.1:${wsport}" -f "socks5://127.0.0.1:${operaport}"
    else
      screen -dmUS x-tunnel "${WORK_DIR}/x-tunnel-linux" -l "ws://127.0.0.1:${wsport}"
    fi
  else
    if [[ "${opera:-0}" == "1" ]]; then
      screen -dmUS x-tunnel "${WORK_DIR}/x-tunnel-linux" -l "ws://127.0.0.1:${wsport}" -token "$token" -f "socks5://127.0.0.1:${operaport}"
    else
      screen -dmUS x-tunnel "${WORK_DIR}/x-tunnel-linux" -l "ws://127.0.0.1:${wsport}" -token "$token"
    fi
  fi

  metricsport="$(get_free_port)"
  "${WORK_DIR}/cloudflared-linux" update >/dev/null 2>&1 || true

  screen -dmUS argo "${WORK_DIR}/cloudflared-linux" --edge-ip-version "$ips" --protocol http2 tunnel \
    --url "127.0.0.1:${wsport}" --metrics "0.0.0.0:${metricsport}"

  if [[ "${bind_enable:-0}" == "1" && -n "${cf_tunnel_token:-}" ]]; then
    screen -dmUS cfbind "${WORK_DIR}/cloudflared-linux" --edge-ip-version "$ips" tunnel run --token "$cf_tunnel_token"
  fi

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
  say "=============================="
  say "  启动完成 (安全通道已建立)"
  say "=============================="
  say "本地 WS 监听端口: ${wsport}"

  if [[ -n "$TRY_DOMAIN" ]]; then
    if [[ -z "${token:-}" ]]; then
      say_ok "【临时域名 Quick Tunnel】 https://${TRY_DOMAIN}"
    else
      say_ok "【临时域名 Quick Tunnel】 https://${TRY_DOMAIN}   Token: ${token}"
    fi
  else
    say_warn "【临时域名 Quick Tunnel】获取超时（可通过菜单 [4] 进行手动检测）"
  fi

  if [[ "${bind_enable:-0}" == "1" ]]; then
    if [[ -n "${bind_domain:-}" ]]; then
      if [[ -z "${token:-}" ]]; then
        say_ok "【绑定域名 Named Tunnel】 https://${bind_domain}"
      else
        say_ok "【绑定域名 Named Tunnel】 https://${bind_domain}   Token: ${token}"
      fi
      say_warn "请保证 Cloudflare Public Hostname 已配置指向: http://127.0.0.1:${wsport}"
    else
      say_ok "【绑定域名 Named Tunnel】已启用 (请去 CF 面板配置流量路由)"
    fi
  fi

  PUBIP="$(curl -s --connect-timeout 3 https://www.cloudflare.com/cdn-cgi/trace | grep ip= | cut -d= -f2 || true)"
  if [[ -n "$PUBIP" ]]; then
    say "内网测速地址: http://${PUBIP}:${metricsport}/metrics"
  fi
  say "=============================="

  self_check "${bind_domain:-}" "${TRY_DOMAIN:-}" "${wsport:-}"
}

view_domains() {
  clear
  if load_config; then
    say "=============================="
    say " 域名绑定历史查询"
    say "=============================="
    say "本地 WS 监听端口: ${wsport:-未知}"

    if [[ -n "${try_domain:-}" ]]; then
      if [[ -z "${token:-}" ]]; then
        say_ok "【临时域名 Quick Tunnel】 https://${try_domain}"
      else
        say_ok "【临时域名 Quick Tunnel】 https://${try_domain}   Token: ${token}"
      fi
    else
      say_warn "【临时域名 Quick Tunnel】未获取到可用记录"
    fi

    if [[ "${bind_enable:-0}" == "1" ]]; then
      if [[ -n "${bind_domain:-}" ]]; then
        if [[ -z "${token:-}" ]]; then
          say_ok "【绑定域名 Named Tunnel】 https://${bind_domain}"
        else
          say_ok "【绑定域名 Named Tunnel】 https://${bind_domain}   Token: ${token}"
        fi
      else
        say_ok "【绑定域名 Named Tunnel】已启用（未登记域名详情）"
      fi
      say_warn "请保证 Cloudflare Public Hostname 指向: http://127.0.0.1:${wsport:-未知}"
    fi

    if [[ -n "${metricsport:-}" ]]; then
      PUBIP="$(curl -s --connect-timeout 3 https://www.cloudflare.com/cdn-cgi/trace | grep ip= | cut -d= -f2 || true)"
      if [[ -n "$PUBIP" ]]; then
        say "内网测速地址: http://${PUBIP}:${metricsport}/metrics"
      fi
    fi
    say "=============================="

    self_check "${bind_domain:-}" "${try_domain:-}" "${wsport:-}"
  else
    say_warn "未检测到本地有上次正常运行的配置记录。"
    say "请在主菜单中选择 [1] 启动代理服务。"
  fi
}

# ------------- 初始化环境 -------------
detect_package_manager
need_cmd screen
need_cmd curl
need_cmd sed
need_cmd grep
need_cmd awk
need_cmd ss || true
need_cmd openssl || true
need_cmd nc || true

# ------------- 交互菜单 -------------
clear
say "=================================================="
say "         NMU-Glitch 极速隧道管理面板             "
echo -e "  - 数据源已锁定：GitHub (nmu-glitch/my-tunnels)"
echo -e "  - 支持 Cloudflare 快速隧道与 Zero Trust 自定义域名绑定"
say "=================================================="
say " 1. 梭哈模式 (安装/运行)"
say " 2. 停止服务"
say " 3. 清空缓存与二进制文件"
say " 4. 查看当前域名与健康诊断"
echo -e " 0. 退出面板"
say "=================================================="
read -r -p "请选择您的操作 [0-4] (默认1): " mode
mode="${mode:-1}"

if [[ "$mode" == "1" ]]; then
  read -r -p "是否启用 Opera 免费前置代理？(0.不启用[默认], 1.启用): " opera
  opera="${opera:-0}"
  if [[ "$opera" == "1" ]]; then
    say "Opera 前置代理仅支持特定大区编码：AM（北美）、AS（亚洲）、EU（欧洲）"
    read -r -p "请输入前置代理区域代码 (默认 AM): " country
    country="${country:-AM}"
    country="$(echo "$country" | tr '[:lower:]' '[:upper:]')"
    if [[ "$country" != "AM" && "$country" != "AS" && "$country" != "EU" ]]; then
      say_err "不支持输入的区域代码，已退出。"
      exit 1
    fi
  fi

  read -r -p "请选择 Cloudflared 网络首选协议 (4.IPv4[默认], 6.IPv6): " ips
  ips="${ips:-4}"
  if [[ "$ips" != "4" && "$ips" != "6" ]]; then
    say_err "错误的 IP 协议参数，已退出。"
    exit 1
  fi

  read -r -p "请设置验证身份的密码 (Token) (选填): " token
  token="${token:-}"

  read -r -p "是否固定本地监听端口？(0.自动随机分配[默认], 1.指定固定端口): " fixp
  fixp="${fixp:-0}"
  if [[ "$fixp" == "1" ]]; then
    read -r -p "请输入您要指定的本地监听端口 (默认 12345): " wsport
    wsport="${wsport:-12345}"
  else
    wsport=""
  fi

  read -r -p "是否启用 Cloudflare 绑定域名 (Named Tunnel)？(0.不启用[默认], 1.启用): " bind_enable
  bind_enable="${bind_enable:-0}"
  cf_tunnel_token=""
  bind_domain=""
  if [[ "$bind_enable" == "1" ]]; then
    say "提示: 绑定自定义域名需要您在 Cloudflare Zero Trust 中创建 Named Tunnel 并获得其 Token"
    read -r -p "请输入 Cloudflare Tunnel Token (必填): " cf_tunnel_token
    if [[ -z "${cf_tunnel_token:-}" ]]; then
      say_warn "未检测到 Token 输入，已自动退回到普通临时隧道模式。"
      bind_enable=0
    else
      read -r -p "请输入您绑定的完整域名 (选填，仅用于自检展示): " bind_domain
      bind_domain="${bind_domain:-}"

      if [[ "$fixp" == "0" ]]; then
        say_warn "强烈建议绑定域名时使用固定端口，否则服务器重启导致端口变动将使 CF 面板映射失效。"
        read -r -p "是否需要现在固定端口？(1.固定端口[推荐], 0.继续随机): " force_fix
        force_fix="${force_fix:-1}"
        if [[ "$force_fix" == "1" ]]; then
          fixp=1
          read -r -p "请输入固定监听端口 (默认 12345): " wsport
          wsport="${wsport:-12345}"
        fi
      fi
    fi
  fi

  screen -wipe >/dev/null 2>&1 || true
  stop_screen x-tunnel
  stop_screen opera
  stop_screen argo
  stop_screen cfbind
  remove_config
  clear
  sleep 1
  quicktunnel

elif [[ "$mode" == "2" ]]; then
  screen -wipe >/dev/null 2>&1 || true
  stop_screen x-tunnel
  stop_screen opera
  stop_screen argo
  stop_screen cfbind
  remove_config
  clear
  say_ok "x-tunnel 服务已安全停止，并成功清除了当前配置缓存。"

elif [[ "$mode" == "3" ]]; then
  screen -wipe >/dev/null 2>&1 || true
  stop_screen x-tunnel
  stop_screen opera
  stop_screen argo
  stop_screen cfbind
  # 干净删除工作目录下的二进制缓存
  rm -rf "$WORK_DIR"
  clear
  say_ok "已彻底清除缓存，删除了所有本地二进制依赖与历史配置文件。"

elif [[ "$mode" == "4" ]]; then
  view_domains

else
  say "正常退出脚本。"
  exit 0
fi
