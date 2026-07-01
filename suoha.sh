#!/usr/bin/env bash
set -euo pipefail

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
        say "固定域名: https://${fixed_domain:-未填写}"
        say "固定端口: $wsport"
        say "身份令牌: $token"
        say "----------------------------------"
        say_warn "请确保 Cloudflare 控制面板中该域名已指向 http://127.0.0.1:$wsport"
    fi
}

# --- 菜单界面 ---
install_deps
setup_env
clear
say "=================================================="
say "      NMU-Glitch 极速隧道管理面板 (全能版)      "
say "=================================================="
echo " 1. 启动服务 (手动配置)"
echo " 2. 停止服务"
echo " 3. 彻底卸载"
echo " 0. 退出"
read -p "请选择 [0-3]: " mode

case "${mode:-1}" in
    1)
        echo -e "\n${YELLOW}--- 基础安全设置 ---${NC}"
        read -p "1. 设置隧道连接令牌 (Token): " token
        read -p "2. 设置本地固定端口 (例如 56908): " wsport
        
        echo -e "\n${YELLOW}--- Cloudflare 绑定设置 ---${NC}"
        read -p "3. 输入 CF Tunnel Token (eyJh...，留空则用临时域名): " cf_tunnel_token
        if [[ -n "$cf_tunnel_token" ]]; then
            read -p "4. 输入你在 CF 绑定的完整域名 (例如 nmutun.nmu.netlib.re): " fixed_domain
        else
            fixed_domain=""
        fi

        echo -e "\n${YELLOW}--- 智能分流设置 ---${NC}"
        read -p "5. 额外需要走 WARP 的域名 (逗号隔开，可选): " warp_domains
        
        quicktunnel ;;
    2)
        stop_services
        say_ok "服务已停止。" ;;
    3)
        stop_services
        [[ "$(id -u)" -eq 0 ]] && userdel -r "$SERVICE_USER" 2>/dev/null || rm -rf "$WORK_DIR"
        say_ok "物理卸载完成。" ;;
    *)
        exit 0 ;;
esac
