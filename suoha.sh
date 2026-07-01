#!/usr/bin/env bash
set -euo pipefail

# =========================================================
#  suoha x-tunnel (Universal Public Edition)
#  - 安全：移除所有硬编码的个人信息与特定配置示例
#  - 隔离：进程与权限严格隔离，支持动态分流
#  - 适配：支持 AMD64 和 ARM64 架构
# =========================================================

# --- 环境常量 ---
SERVICE_USER="nmu-tunnel"
SCREEN_NAME_PREFIX="nmu_tunnel_"
S_X_TUNNEL="${SCREEN_NAME_PREFIX}xtunnel"
S_ARGO="${SCREEN_NAME_PREFIX}argo"
S_SINGBOX="${SCREEN_NAME_PREFIX}singbox"
S_CFBIND="${SCREEN_NAME_PREFIX}cfbind"

# 颜色定义
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

say() { printf "${BLUE}[NMU-Tunnel]${NC} %s\n" "$*"; }
say_ok() { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
say_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
say_err() { printf "${RED}[FAIL]${NC} %s\n" "$*"; }

# --- 1. 基础依赖初始化 ---
install_deps() {
    if [ "$(id -u)" -ne 0 ]; then return; fi
    say "正在初始化系统依赖环境..."
    if command -v apt-get &>/dev/null; then
        apt-get update && apt-get -y install screen curl iproute2 sudo tar sed grep gzip
    elif command -v apk &>/dev/null; then
        apk update && apk add --no-cache screen curl iproute2 sudo tar sed grep gzip bash
    fi
}

# --- 2. 运行环境隔离 ---
setup_env() {
    if [ "$(id -u)" -eq 0 ]; then
        if ! id "$SERVICE_USER" &>/dev/null; then
            say "正在创建专用安全用户: $SERVICE_USER ..."
            useradd -m -s /usr/sbin/nologin "$SERVICE_USER" || useradd -m -s /bin/false "$SERVICE_USER"
        fi
        USER_HOME=$(eval echo "~$SERVICE_USER")
    else
        SERVICE_USER=$(whoami)
        USER_HOME="$HOME"
    fi
    WORK_DIR="$USER_HOME/.suoha_x_tunnel"
    SCREEN_DIR="$WORK_DIR/.screen"
    [ "$(id -u)" -eq 0 ] && mkdir -p "$WORK_DIR" && chown "$SERVICE_USER":"$SERVICE_USER" "$WORK_DIR"
    mkdir -p "$SCREEN_DIR"
    chmod 700 "$WORK_DIR" "$SCREEN_DIR"
}

# --- 3. 跨用户安全执行 (环境变量传参) ---
safe_run() {
    local cmd="$1"
    export EX_WS_PORT="${wsport:-}"
    export EX_TOKEN="${token:-}"
    export EX_CF_TOKEN="${cf_tunnel_token:-}"
    export EX_WARP_DOMAINS="${warp_domains:-}"
    export SCREENDIR="$SCREEN_DIR" 
    if [ "$(id -u)" -eq 0 ]; then
        sudo -u "$SERVICE_USER" --preserve-env=EX_WS_PORT,EX_TOKEN,EX_CF_TOKEN,EX_WARP_DOMAINS,SCREENDIR,TERM bash -c "cd $WORK_DIR && $cmd"
    else
        bash -c "cd $WORK_DIR && $cmd"
    fi
}

# --- 4. 精确进程清理 ---
stop_services() {
    say "正在清理旧的进程会话..."
    local sessions=("$S_X_TUNNEL" "$S_ARGO" "$S_SINGBOX" "$S_CFBIND")
    for s in "${sessions[@]}"; do
        if [ "$(id -u)" -eq 0 ]; then
            sudo -u "$SERVICE_USER" env SCREENDIR="$SCREEN_DIR" screen -S "$s" -X quit >/dev/null 2>&1 || true
        else
            SCREENDIR="$SCREEN_DIR" screen -S "$s" -X quit >/dev/null 2>&1 || true
        fi
    done
}

# --- 5. 核心下载与启动逻辑 ---
quicktunnel() {
    local arch; [[ "$(uname -m)" == "x86_64" ]] && arch="amd64" || arch="arm64"
    stop_services
    say "正在安全下载核心组件..."
    SB_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d ":" -f2 | tr -d '\"v ,')
    export ARCH_F="$arch" SB_V="$SB_VER"
    # 注意：此处使用的链接为您的 GitHub 仓库路径占位符
    safe_run "
        curl -fsSL https://github.com/nmu-glitch/my-tunnels/releases/download/v1.0.0/x-tunnel-linux-\$ARCH_F -o xtunnel
        curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-\$ARCH_F -o cloudflared
        curl -fsSL https://github.com/SagerNet/sing-box/releases/download/v\$SB_V/sing-box-\$SB_V-linux-\$ARCH_F.tar.gz -o sb.tar.gz
        tar -zxf sb.tar.gz --strip-components=1 && mv sing-box singbox && rm -f sb.tar.gz
        chmod 700 xtunnel cloudflared singbox
    "
    
    wsport="${wsport:-$((RANDOM % 50000 + 10000))}"
    metricsport=$((RANDOM % 50000 + 10000))

    # 生成分流配置
    safe_run "
        BASE_DOMAINS='\"netflix.com\",\"netflix.net\",\"nflximg.net\",\"nflxvideo.net\",\"nflxso.net\",\"chatgpt.com\",\"openai.com\"'
        if [[ -n \"\$EX_WARP_DOMAINS\" ]]; then
            for d in \$(echo \$EX_WARP_DOMAINS | tr ',' ' '); do
                BASE_DOMAINS=\"\$BASE_DOMAINS,\\\"\$d\\\"\"
            done
        fi
        cat > sb.json <<EOF
{
  \"inbounds\": [{\"type\": \"socks\", \"listen\": \"127.0.0.1\", \"listen_port\": 50000}],
  \"outbounds\": [{\"type\": \"direct\", \"tag\": \"direct\"}, {\"type\": \"socks\", \"tag\": \"warp\", \"server\": \"127.0.0.1\", \"server_port\": 40000}],
  \"route\": { \"rules\": [{\"domain\": [ \$BASE_DOMAINS ], \"outbound\": \"warp\"}], \"final\": \"direct\" }
}
EOF
    "

    say "正在启动服务进程..."
    safe_run "
        screen -dmUS $S_SINGBOX ./singbox run -c sb.json
        screen -dmUS $S_X_TUNNEL ./xtunnel -l 127.0.0.1:\$EX_WS_PORT -token \"\$EX_TOKEN\" -f socks5://127.0.0.1:50000
    "

    if [[ -z "$cf_tunnel_token" ]]; then
        say "未检测到 Tunnel Token，启动临时隧道模式..."
        safe_run "screen -dmUS $S_ARGO ./cloudflared tunnel --protocol http2 --url 127.0.0.1:\$EX_WS_PORT --metrics 127.0.0.1:$metricsport"
        sleep 12
        TRY_DOMAIN=$(safe_run "curl -s http://127.0.0.1:$metricsport/metrics" | grep 'userHostname=' | sed -E 's/.*userHostname="https?:\/\/([^"]+)".*/\1/' | head -n1 || true)
        say_ok "启动成功！临时域名: https://${TRY_DOMAIN:-获取失败}"
    else
        say_ok "检测到 Token，启动固定域名模式..."
        safe_run "screen -dmUS $S_CFBIND ./cloudflared tunnel run --token \"\$EX_CF_TOKEN\""
        clear
        say_ok "系统启动成功！"
        say "----------------------------------"
        say "固定域名: https://${fixed_domain:-未指定}"
        say "本地监听端口: $wsport"
        say "身份连接令牌: ${token:-未设置}"
        say "----------------------------------"
        say_warn "请确保 Cloudflare 面板中 Public Hostname 指向 http://127.0.0.1:$wsport"
    fi
}

# --- 菜单界面 ---
install_deps
setup_env
clear
say "=================================================="
say "      NMU-Glitch 极速隧道管理面板 (通用版)      "
say "=================================================="
echo " 1. 启动服务 (交互式配置)"
echo " 2. 停止服务"
echo " 3. 彻底卸载 (删除运行环境与用户)"
echo " 0. 退出"
read -p "请选择 [0-3]: " mode

case "${mode:-1}" in
    1)
        echo -e "\n${YELLOW}--- [1] 隧道安全基础设置 ---${NC}"
        read -p "请输入隧道连接令牌 (Token/密码): " token
        read -p "请输入本地监听端口 (建议 10000-60000): " wsport
        
        echo -e "\n${YELLOW}--- [2] Cloudflare 隧道设置 ---${NC}"
        read -p "请输入 CF Tunnel Token (留空则使用临时域名): " cf_tunnel_token
        if [[ -n "$cf_tunnel_token" ]]; then
            read -p "请输入您在 CF 绑定的域名 (仅用于显示): " fixed_domain
        else
            fixed_domain=""
        fi

        echo -e "\n${YELLOW}--- [3] 智能分流设置 ---${NC}"
        read -p "请输入需要走 WARP 的额外域名 (逗号隔开): " warp_domains
        
        quicktunnel ;;
    2)
        stop_services
        say_ok "服务已停止。" ;;
    3)
        stop_services
        if [ "$(id -u)" -eq 0 ]; then
            userdel -r "$SERVICE_USER" 2>/dev/null || rm -rf "$WORK_DIR"
        else
            rm -rf "$WORK_DIR"
        fi
        say_ok "系统环境已物理清理。" ;;
    *)
        exit 0 ;;
esac
