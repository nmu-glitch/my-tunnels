#!/usr/bin/env bash
set -euo pipefail

# =========================================================
#  suoha x-tunnel (NMU-Glitch Hardened v4 - FINAL)
#  - 安全：恢复环境变量传参逻辑，彻底封堵命令注入漏洞
#  - 安全：权限严格隔离，禁止代理进程以 Root 运行
#  - 健壮：Sing-box 端口随机化 (40001-50000)，解决 bind 冲突
#  - 修复：强制 xtunnel 采用 ws:// 前缀进入服务端模式
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

# --- 1. 依赖环境初始化 ---
install_deps() {
    if [ "$(id -u)" -ne 0 ]; then return; fi
    say "正在初始化系统依赖环境..."
    if command -v apt-get &>/dev/null; then
        apt-get update && apt-get -y install screen curl iproute2 sudo tar sed grep gzip psmisc
    elif command -v apk &>/dev/null; then
        apk update && apk add --no-cache screen curl iproute2 sudo tar sed grep gzip bash psmisc
    elif command -v yum &>/dev/null; then
        yum -y install screen curl iproute2 sudo tar sed grep gzip psmisc
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

# --- 3. 跨用户安全执行 (修复版：环境变量强制隔离) ---
safe_run() {
    local cmd="$1"
    # 将参数压入环境变量，拒绝字符串拼接
    export EX_WS_PORT="${final_wsport:-}"
    export EX_METRICS_PORT="${final_mport:-}"
    export EX_TOKEN="${token:-}"
    export EX_CF_TOKEN="${cf_tunnel_token:-}"
    export EX_IPS="${ips:-4}"
    export EX_SB_PORT="${sb_port:-}"
    export SCREENDIR="$SCREEN_DIR" 

    # 关键：sudo 必须配合 --preserve-env，否则环境变量无法穿透
    if [ "$(id -u)" -eq 0 ]; then
        sudo -u "$SERVICE_USER" --preserve-env=EX_WS_PORT,EX_METRICS_PORT,EX_TOKEN,EX_CF_TOKEN,EX_IPS,EX_SB_PORT,SCREENDIR,TERM \
            bash -c "cd $WORK_DIR && $cmd"
    else
        bash -c "cd $WORK_DIR && $cmd"
    fi
}

# --- 4. 进程与端口精确清理 ---
stop_services() {
    say "正在清理旧的进程与端口占用..."
    local sessions=("$S_X_TUNNEL" "$S_ARGO" "$S_SINGBOX" "$S_CFBIND")
    for s in "${sessions[@]}"; do
        if [ "$(id -u)" -eq 0 ]; then
            sudo -u "$SERVICE_USER" env SCREENDIR="$SCREEN_DIR" screen -S "$s" -X quit >/dev/null 2>&1 || true
        else
            SCREENDIR="$SCREEN_DIR" screen -S "$s" -X quit >/dev/null 2>&1 || true
        fi
    done
    # 彻底释放 Sing-box 占用的任何端口
    pkill -u "$SERVICE_USER" singbox 2>/dev/null || true
}

# --- 5. 核心启动逻辑 ---
quicktunnel() {
    local arch; [[ "$(uname -m)" == "x86_64" ]] && arch="amd64" || arch="arm64"
    stop_services

    say "正在安全下载核心组件..."
    SB_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d ":" -f2 | tr -d '\"v ,')
    
    # 提前计算启动参数
    final_wsport="${wsport:-$((RANDOM % 50000 + 10000))}"
    final_mport=$((RANDOM % 50000 + 10000))
    sb_port=$((RANDOM % 10000 + 40001)) # 分流端口 40001-50000
    
    export ARCH_F="$arch" SB_V="$SB_VER"
    safe_run "
        curl -fsSL https://github.com/nmu-glitch/my-tunnels/releases/download/v1.0.0/x-tunnel-linux-\$ARCH_F -o xtunnel
        curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-\$ARCH_F -o cloudflared
        curl -fsSL https://github.com/SagerNet/sing-box/releases/download/v\$SB_V/sing-box-\$SB_V-linux-\$ARCH_F.tar.gz -o sb.tar.gz
        tar -zxf sb.tar.gz --strip-components=1 && mv sing-box singbox && rm -f sb.tar.gz
        chmod 700 xtunnel cloudflared singbox
    "

    say "正在配置分流规则 (内部端口: $sb_port)..."
    # 使用单引号包裹 bash -c 的内容，防止本地 Shell 提前展开变量
    safe_run '
        cat > sb.json <<EOF
{
  "inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": $EX_SB_PORT}],
  "outbounds": [{"type": "direct", "tag": "direct"}, {"type": "socks", "tag": "warp", "server": "127.0.0.1", "server_port": 40000}],
  "route": { "rules": [{"domain": ["netflix.com","chatgpt.com","openai.com"], "outbound": "warp"}], "final": "direct" }
}
EOF
        screen -dmUS '$S_SINGBOX' ./singbox run -c sb.json
        sleep 2
        # 修正：加入 ws:// 协议头，并使用环境变量 EX_TOKEN 规避注入
        screen -dmUS '$S_X_TUNNEL' ./xtunnel -l ws://127.0.0.1:$EX_WS_PORT -token "$EX_TOKEN" -f socks5://127.0.0.1:$EX_SB_PORT
    '

    if [[ -z "$cf_tunnel_token" ]]; then
        say "正在启动临时模式..."
        safe_run 'screen -dmUS '$S_ARGO' ./cloudflared tunnel --protocol http2 --url 127.0.0.1:$EX_WS_PORT --metrics 127.0.0.1:$EX_METRICS_PORT'
        sleep 12
        TRY_DOMAIN=$(safe_run 'curl -s http://127.0.0.1:$EX_METRICS_PORT/metrics' | grep 'userHostname=' | sed -E 's/.*userHostname="https?:\/\/([^"]+)".*/\1/' | head -n1 || true)
        say_ok "启动成功！临时域名: https://${TRY_DOMAIN:-获取失败}"
    else
        say "正在启动固定域名模式..."
        safe_run 'screen -dmUS '$S_CFBIND' ./cloudflared tunnel run --token "$EX_CF_TOKEN"'
        clear
        say_ok "系统启动成功！"
        say "----------------------------------"
        say "域名地址: https://${fixed_domain:-已在 CF 后台关联}"
        say "本地监听: 127.0.0.1:$final_wsport"
        say "身份令牌: (已根据输入设置)"
        say "----------------------------------"
    fi
}

# --- 菜单界面 ---
install_deps
setup_env
clear
say "=================================================="
say "      NMU-Glitch 最终加固版 (安全防注入)        "
say "=================================================="
echo " 1. 启动服务"
echo " 2. 停止服务"
echo " 3. 完全卸载"
echo " 0. 退出"
read -p "选择操作: " mode

case "${mode:-1}" in
    1)
        read -p "1. Token (连接密码): " token
        read -p "2. 本地监听端口: " wsport
        read -p "3. CF Tunnel Token (留空用临时域名): " cf_tunnel_token
        [[ -n "$cf_tunnel_token" ]] && read -p "4. 绑定的域名 (仅显示): " fixed_domain || fixed_domain=""
        ips=4
        quicktunnel ;;
    2) stop_services; say_ok "服务已停止。" ;;
    3) stop_services; [[ "$(id -u)" -eq 0 ]] && userdel -r "$SERVICE_USER" 2>/dev/null || rm -rf "$WORK_DIR"; say_ok "已卸载。" ;;
    *) exit 0 ;;
esac
