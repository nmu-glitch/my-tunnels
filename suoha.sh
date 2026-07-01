#!/usr/bin/env bash
set -euo pipefail

# =========================================================
#  suoha x-tunnel (NMU-Glitch 终极加固版 - 完整环境补全)
#  - 补全：重新加入自动检测并安装依赖 (install_deps)
#  - 安全：防止 pkill 误杀，锁定精确会话名称
#  - 安全：使用环境变量传递参数，彻底消除命令注入漏洞
#  - 兼容：修正 sudo + screen 环境冲突，定义独立 SCREENDIR
# =========================================================

# --- 环境常量 ---
SERVICE_USER="nmu-tunnel"
SCREEN_NAME_PREFIX="nmu_tunnel_"
S_X_TUNNEL="${SCREEN_NAME_PREFIX}xtunnel"
S_ARGO="${SCREEN_NAME_PREFIX}argo"
S_SINGBOX="${SCREEN_NAME_PREFIX}singbox"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

say() { printf "${BLUE}[NMU-Tunnel]${NC} %s\n" "$*"; }
say_ok() { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
say_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
say_err() { printf "${RED}[FAIL]${NC} %s\n" "$*"; }

# --- 1. 依赖安装函数 (Root 权限) ---
install_deps() {
    if [ "$(id -u)" -ne 0 ]; then
        say_warn "当前是非 Root 用户，如果脚本运行失败，请先手动安装依赖: screen, curl, iproute2, sudo, tar"
        return
    fi

    say "正在检查并初始化系统依赖环境..."
    if command -v apt-get &>/dev/null; then
        apt-get update && apt-get -y install screen curl iproute2 sudo tar sed grep
    elif command -v apk &>/dev/null; then
        apk update && apk add --no-cache screen curl iproute2 sudo tar sed grep bash
    elif command -v dnf &>/dev/null; then
        dnf -y install screen curl iproute2 sudo tar sed grep
    elif command -v yum &>/dev/null; then
        yum -y install screen curl iproute2 sudo tar sed grep
    else
        say_err "未检测到支持的包管理器，请手动安装 screen, curl, sudo。"
    fi
}

# --- 2. 环境初始化 (用户与目录) ---
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
    # 定义私有的 Screen Socket 目录，解决跨用户启动权限问题
    SCREEN_DIR="$WORK_DIR/.screen"
    
    [ "$(id -u)" -eq 0 ] && mkdir -p "$WORK_DIR" && chown "$SERVICE_USER":"$SERVICE_USER" "$WORK_DIR"
    mkdir -p "$SCREEN_DIR"
    chmod 700 "$WORK_DIR" "$SCREEN_DIR"
}

# --- 3. 封装安全的跨用户执行 ---
safe_run() {
    local cmd="$1"
    # 环境变量传参，消除命令注入风险
    export EX_WS_PORT="${wsport:-}"
    export EX_METRICS_PORT="${metricsport:-}"
    export EX_TOKEN="${token:-}"
    export EX_IPS="${ips:-4}"
    export SCREENDIR="$SCREEN_DIR" 

    if [ "$(id -u)" -eq 0 ]; then
        # --preserve-env 确保自定义的环境变量能穿透到 sudo 内部
        sudo -u "$SERVICE_USER" --preserve-env=EX_WS_PORT,EX_METRICS_PORT,EX_TOKEN,EX_IPS,SCREENDIR,TERM \
            bash -c "cd $WORK_DIR && $cmd"
    else
        bash -c "cd $WORK_DIR && $cmd"
    fi
}

# --- 4. 进程精确管理 ---
stop_services() {
    say "清理旧的进程会话..."
    local sessions=("$S_X_TUNNEL" "$S_ARGO" "$S_SINGBOX")
    for s in "${sessions[@]}"; do
        if [ "$(id -u)" -eq 0 ]; then
            sudo -u "$SERVICE_USER" env SCREENDIR="$SCREEN_DIR" screen -S "$s" -X quit >/dev/null 2>&1 || true
        else
            SCREENDIR="$SCREEN_DIR" screen -S "$s" -X quit >/dev/null 2>&1 || true
        fi
    done
}

# --- 5. 核心业务逻辑 ---
quicktunnel() {
    local arch
    case "$(uname -m)" in
        x86_64|x64|amd64) arch="amd64" ;;
        armv8|arm64|aarch64) arch="arm64" ;;
        *) say_err "不支持架构 $(uname -m)"; exit 1 ;;
    esac

    # 停止已有服务
    stop_services

    # 下载所需二进制
    say "正在下载核心组件..."
    safe_run "
        curl -fsSL https://github.com/nmu-glitch/my-tunnels/releases/download/v1.0.0/x-tunnel-linux-$arch -o xtunnel
        curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$arch -o cloudflared
        curl -fsSL https://github.com/Snawoot/sing-box-static/releases/latest/download/sing-box-linux-$arch -o singbox
        chmod 700 xtunnel cloudflared singbox
    "

    wsport=$((RANDOM % 50000 + 10000))
    metricsport=$((RANDOM % 50000 + 10000))

    # 生成配置并启动
    say "正在启动智能分流代理系统..."
    safe_run "
        cat > sb.json <<EOF
{
  \"inbounds\": [{\"type\": \"socks\", \"listen\": \"127.0.0.1\", \"listen_port\": 50000}],
  \"outbounds\": [
    {\"type\": \"direct\", \"tag\": \"direct\"},
    {\"type\": \"socks\", \"tag\": \"warp\", \"server\": \"127.0.0.1\", \"server_port\": 40000}
  ],
  \"route\": { 
    \"rules\": [{\"domain\": [\"netflix.com\",\"chatgpt.com\",\"openai.com\"], \"outbound\": \"warp\"}], 
    \"final\": \"direct\" 
  }
}
EOF
        # 按照链路顺序启动进程
        screen -dmUS $S_SINGBOX ./singbox run -c sb.json
        screen -dmUS $S_X_TUNNEL ./xtunnel -l 127.0.0.1:\$EX_WS_PORT -token \"\$EX_TOKEN\" -f socks5://127.0.0.1:50000
        screen -dmUS $S_ARGO ./cloudflared tunnel --edge-ip-version \$EX_IPS --protocol http2 --url 127.0.0.1:\$EX_WS_PORT --metrics 127.0.0.1:\$EX_METRICS_PORT
    "

    say "正在等待 Cloudflare 分配安全隧道域名..."
    sleep 15
    TRY_DOMAIN=$(safe_run "curl -s http://127.0.0.1:$metricsport/metrics" | grep 'userHostname=' | sed -E 's/.*userHostname="https?:\/\/([^"]+)".*/\1/' | head -n1 || true)

    clear
    say_ok "系统启动成功！"
    say "----------------------------------"
    say "运行状态: 环境已加固 & 权限已隔离"
    say "运行用户: $SERVICE_USER"
    say "临时域名: https://${TRY_DOMAIN:-域名获取慢，请稍后手动检查}"
    say "分流策略: 默认 Netflix/ChatGPT 走 WARP(40000)"
    say "----------------------------------"
}

# --- 执行入口 ---
# 1. 首先确保安装了所有必要工具
install_deps
# 2. 初始化运行环境
setup_env

clear
say "=================================================="
say "      NMU-Glitch 终极安全代理管理面板           "
say "=================================================="
echo " 1. 梭哈：一键开启智能分流代理"
echo " 2. 停止服务"
echo " 3. 卸载环境 (物理删除)"
echo " 0. 退出"
read -p "请选择操作 [0-3]: " mode
mode="${mode:-1}"

case "$mode" in
    1)
        read -p "设置 Token (留空则不设): " token
        read -p "IP 协议版本 (4/6, 默认4): " ips; ips=${ips:-4}
        quicktunnel
        ;;
    2)
        stop_services
        say_ok "所有服务已通过精确 Session 匹配停止。"
        ;;
    3)
        stop_services
        if [ "$(id -u)" -eq 0 ]; then
            userdel -r "$SERVICE_USER" 2>/dev/null || rm -rf "$WORK_DIR"
        else
            rm -rf "$WORK_DIR"
        fi
        say_ok "系统环境已彻底物理卸载。"
        ;;
    *) exit 0 ;;
esac
