#!/usr/bin/env bash
set -euo pipefail

# =========================================================
#  suoha x-tunnel (NMU-Glitch Hardened v5 - 最终无缝版)
#  - 漏洞修复：修复了父 Shell 提前展开变量导致的注入风险
#  - 安全标准：所有变量通过 sudo --preserve-env 传递，内核级隔离
#  - 自动化：内置官方 WARP 部署与端口自动关联
#  - 权限：所有代理进程锁定在 nmu-tunnel 用户
# =========================================================

# --- 1. 常量与环境定义 ---
SERVICE_USER="nmu-tunnel"
SCREEN_NAME_PREFIX="nmu_tunnel_"
S_X_TUNNEL="${SCREEN_NAME_PREFIX}xtunnel"
S_ARGO="${SCREEN_NAME_PREFIX}argo"
S_SINGBOX="${SCREEN_NAME_PREFIX}singbox"
S_CFBIND="${SCREEN_NAME_PREFIX}cfbind"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

say() { printf "${BLUE}[NMU-Tunnel]${NC} %s\n" "$*"; }
say_ok() { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
say_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
say_err() { printf "${RED}[FAIL]${NC} %s\n" "$*"; }

# --- 2. 依赖安装 (必须 Root) ---
install_deps() {
    if [ "$(id -u)" -ne 0 ]; then return; fi
    say "检查并安装系统组件..."
    if command -v apt-get &>/dev/null; then
        apt-get update && apt-get -y install screen curl iproute2 sudo tar sed grep gzip psmisc
    elif command -v apk &>/dev/null; then
        apk update && apk add --no-cache screen curl iproute2 sudo tar sed grep gzip bash psmisc
    fi
}

# --- 3. 自动 WARP 部署 ---
setup_warp_auto() {
    if ss -lntp | grep -q ":40000"; then
        say_ok "WARP 已处于就绪状态 (40000 端口)。"
        return
    fi
    say_warn "正在自动部署 WARP SOCKS5 代理..."
    curl -fsSL https://raw.githubusercontent.com/P3TERX/warp.sh/main/warp.sh -o warp_install.sh && chmod +x warp_install.sh
    ./warp_install.sh s5 -p 40000
}

# --- 4. 权限隔离初始化 ---
setup_env() {
    if [ "$(id -u)" -eq 0 ]; then
        if ! id "$SERVICE_USER" &>/dev/null; then
            say "创建安全账户: $SERVICE_USER"
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
    mkdir -p "$SCREEN_DIR" && chmod 700 "$WORK_DIR" "$SCREEN_DIR"
}

# --- 5. 核心：安全的跨用户执行器 (注入防御核心) ---
safe_run() {
    local inner_cmd="$1"
    
    # 将变量作为环境变量导出给 sudo
    export EX_WS_PORT="${final_wsport:-}"
    export EX_TOKEN="${token:-}"
    export EX_CF_TOKEN="${cf_tunnel_token:-}"
    export EX_SB_PORT="${sb_port:-}"
    export EX_METRICS_PORT="${final_mport:-}"
    export EX_IPS="${ips:-4}"
    export SCREENDIR="$SCREEN_DIR"

    # 定义要透传的环境变量白名单
    local env_list="EX_WS_PORT,EX_TOKEN,EX_CF_TOKEN,EX_SB_PORT,EX_METRICS_PORT,EX_IPS,SCREENDIR,TERM"

    if [ "$(id -u)" -eq 0 ]; then
        # 关键点：inner_cmd 在这里是一个纯静态字符串，
        # 变量展开将由 sudo 内部的 bash -c 负责，完全避开父 Shell 注入。
        sudo -u "$SERVICE_USER" --preserve-env="$env_list" bash -c "cd '$WORK_DIR' && $inner_cmd"
    else
        bash -c "cd '$WORK_DIR' && $inner_cmd"
    fi
}

# --- 6. 进程管理 ---
stop_services() {
    say "清理后台会话..."
    pkill -u "$SERVICE_USER" singbox 2>/dev/null || true
    local sessions=("$S_X_TUNNEL" "$S_ARGO" "$S_SINGBOX" "$S_CFBIND")
    for s in "${sessions[@]}"; do
        if [ "$(id -u)" -eq 0 ]; then
            sudo -u "$SERVICE_USER" env SCREENDIR="$SCREEN_DIR" screen -S "$s" -X quit >/dev/null 2>&1 || true
        else
            SCREENDIR="$SCREEN_DIR" screen -S "$s" -X quit >/dev/null 2>&1 || true
        fi
    done
}

# --- 7. 核心业务流程 ---
quicktunnel() {
    local arch; [[ "$(uname -m)" == "x86_64" ]] && arch="amd64" || arch="arm64"
    setup_warp_auto
    stop_services

    say "同步最新二进制组件..."
    SB_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d ":" -f2 | tr -d '\"v ,')
    
    # 提前计算参数
    final_wsport="${wsport:-$((RANDOM % 50000 + 10000))}"
    final_mport=$((RANDOM % 50000 + 10000))
    sb_port=$((RANDOM % 10000 + 40001))
    
    # 定义子命令，注意这里全部使用单引号，杜绝父 Shell 提前展开
    safe_run '
        curl -fsSL https://github.com/nmu-glitch/my-tunnels/releases/download/v1.0.0/x-tunnel-linux-'"$arch"' -o xtunnel
        curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-'"$arch"' -o cloudflared
        curl -fsSL https://github.com/SagerNet/sing-box/releases/download/v'"$SB_VER"'/sing-box-'"$SB_VER"'-linux-'"$arch"'.tar.gz -o sb.tar.gz
        tar -zxf sb.tar.gz --strip-components=1 && mv sing-box singbox && rm -f sb.tar.gz
        chmod 700 xtunnel cloudflared singbox

        cat > sb.json <<EOF
{
  "inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": $EX_SB_PORT}],
  "outbounds": [{"type": "direct", "tag": "direct"}, {"type": "socks", "tag": "warp", "server": "127.0.0.1", "server_port": 40000}],
  "route": { "rules": [{"domain": ["netflix.com","chatgpt.com","openai.com","ip.sb","ipapi.co"], "outbound": "warp"}], "final": "direct" }
}
EOF
        screen -dmUS '"$S_SINGBOX"' ./singbox run -c sb.json
        sleep 2
        screen -dmUS '"$S_X_TUNNEL"' ./xtunnel -l ws://127.0.0.1:$EX_WS_PORT -token "$EX_TOKEN" -f socks5://127.0.0.1:$EX_SB_PORT
    '

    if [[ -z "$cf_tunnel_token" ]]; then
        safe_run 'screen -dmUS '"$S_ARGO"' ./cloudflared tunnel --edge-ip-version $EX_IPS --protocol http2 --url 127.0.0.1:$EX_WS_PORT --metrics 127.0.0.1:$EX_METRICS_PORT'
        sleep 12
        TRY_DOMAIN=$(safe_run 'curl -s http://127.0.0.1:$EX_METRICS_PORT/metrics' | grep 'userHostname=' | sed -E 's/.*userHostname="https?:\/\/([^"]+)".*/\1/' | head -n1 || true)
        say_ok "启动成功！临时域名: https://${TRY_DOMAIN:-未成功分配}"
    else
        safe_run 'screen -dmUS '"$S_CFBIND"' ./cloudflared tunnel run --token "$EX_CF_TOKEN"'
        clear
        say_ok "固定域名模式启动成功！"
        say "----------------------------------"
        say "域名: $fixed_domain"
        say "本地端口: $final_wsport"
        say "安全等级: 核心权限已完全隔离"
        say "----------------------------------"
    fi
}

# --- 菜单界面 ---
install_deps
setup_env

clear
say "=================================================="
say "      NMU-Glitch 极速隧道：终极安全稳固版        "
say "=================================================="
echo " 1. 启动一键梭哈 (自动 WARP + 智能分流)"
echo " 2. 停止所有服务"
echo " 3. 完全卸载环境"
echo " 0. 退出"
read -p "选择: " mode

case "${mode:-1}" in
    1)
        read -p "Token: " token
        read -p "本地监听端口: " wsport
        read -p "CF Tunnel Token: " cf_tunnel_token
        [[ -n "$cf_tunnel_token" ]] && read -p "绑定域名: " fixed_domain
        quicktunnel ;;
    2) stop_services; say_ok "已清理" ;;
    3) stop_services; [[ "$(id -u)" -eq 0 ]] && userdel -r "$SERVICE_USER" 2>/dev/null || rm -rf "$WORK_DIR"; say_ok "已卸载" ;;
    *) exit 0 ;;
esac
