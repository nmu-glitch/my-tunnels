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

# --- 1. 系统依赖初始化 ---
install_deps() {
    if [ "$(id -u)" -ne 0 ]; then return; fi
    if command -v apt-get &>/dev/null; then
        apt-get update && apt-get -y install screen curl iproute2 sudo tar sed grep gzip
    elif command -v apk &>/dev/null; then
        apk update && apk add --no-cache screen curl iproute2 sudo tar sed grep gzip bash
    fi
}

# --- 2. 运行用户环境隔离 ---
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

# --- 3. 跨用户安全执行 ---
safe_run() {
    local cmd="$1"
    export EX_WS_PORT="${wsport:-}"
    export EX_TOKEN="${token:-}"
    export EX_CF_TOKEN="${cf_tunnel_token:-}"
    export EX_WARP_DOMAINS="${warp_domains:-}"
    export SCREENDIR="$SCREEN_DIR" 

    if [ "$(id -u)" -eq 0 ]; then
        sudo -u "$SERVICE_USER" --preserve-env=EX_WS_PORT,EX_TOKEN,EX_CF_TOKEN,EX_WARP_DOMAINS,SCREENDIR,TERM \
            bash -c "cd $WORK_DIR && $cmd"
    else
        bash -c "cd $WORK_DIR && $cmd"
    fi
}

# --- 4. 生成 Sing-box 配置 (核心逻辑) ---
write_sb_json() {
    safe_run "
        BASE_DOMAINS='\"netflix.com\",\"netflix.net\",\"nflximg.net\",\"nflxvideo.net\",\"nflxso.net\",\"chatgpt.com\",\"openai.com\",\"oaistatic.com\",\"oaiusercontent.com\"'
        if [[ -n \"\$EX_WARP_DOMAINS\" ]]; then
            for d in \$(echo \$EX_WARP_DOMAINS | tr ',' ' '); do
                BASE_DOMAINS=\"\$BASE_DOMAINS,\\\"\$d\\\"\"
            done
        fi
        cat > sb.json <<EOF
{
  \"inbounds\": [{\"type\": \"socks\", \"listen\": \"127.0.0.1\", \"listen_port\": 50000}],
  \"outbounds\": [
    {\"type\": \"direct\", \"tag\": \"direct\"},
    {\"type\": \"socks\", \"tag\": \"warp\", \"server\": \"127.0.0.1\", \"server_port\": 40000}
  ],
  \"route\": { 
    \"rules\": [{\"domain\": [ \$BASE_DOMAINS ], \"outbound\": \"warp\"}], 
    \"final\": \"direct\" 
  }
}
EOF
    "
}

# --- 5. 动态更新域名 (不重启隧道) ---
update_warp_domains() {
    if ! screen -ls | grep -q "$S_SINGBOX"; then
        say_err "服务未运行，请先执行选项 1 启动。"
        return
    fi
    read -p "请输入要增加走 WARP 的域名 (如: youtube.com,google.com): " warp_domains
    say "正在更新规则..."
    write_sb_json
    # 仅重启 Sing-box 会话
    if [ "$(id -u)" -eq 0 ]; then
        sudo -u "$SERVICE_USER" env SCREENDIR="$SCREEN_DIR" screen -S "$S_SINGBOX" -X quit || true
    else
        SCREENDIR="$SCREEN_DIR" screen -S "$S_SINGBOX" -X quit || true
    fi
    sleep 1
    safe_run "screen -dmUS $S_SINGBOX ./singbox run -c sb.json"
    say_ok "规则已更新！Argo 域名未受影响，分流已生效。"
}

# --- 6. 停止与启动服务 (略，见下文逻辑) ---
stop_services() {
    local sessions=("$S_X_TUNNEL" "$S_ARGO" "$S_SINGBOX" "$S_CFBIND")
    for s in "${sessions[@]}"; do
        if [ "$(id -u)" -eq 0 ]; then
            sudo -u "$SERVICE_USER" env SCREENDIR="$SCREEN_DIR" screen -S "$s" -X quit >/dev/null 2>&1 || true
        else
            SCREENDIR="$SCREEN_DIR" screen -S "$s" -X quit >/dev/null 2>&1 || true
        fi
    done
}

quicktunnel() {
    local arch; [[ "$(uname -m)" == "x86_64" ]] && arch="amd64" || arch="arm64"
    stop_services
    say "下载组件..."
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
    write_sb_json
    say "启动中..."
    safe_run "
        screen -dmUS $S_SINGBOX ./singbox run -c sb.json
        screen -dmUS $S_X_TUNNEL ./xtunnel -l 127.0.0.1:\$EX_WS_PORT -token \"\$EX_TOKEN\" -f socks5://127.0.0.1:50000
        screen -dmUS $S_ARGO ./cloudflared tunnel --protocol http2 --url 127.0.0.1:\$EX_WS_PORT --metrics 127.0.0.1:$metricsport
        [[ -n \"\$EX_CF_TOKEN\" ]] && screen -dmUS $S_CFBIND ./cloudflared tunnel run --token \"\$EX_CF_TOKEN\"
    "
    sleep 10
    TRY_DOMAIN=$(safe_run "curl -s http://127.0.0.1:$metricsport/metrics" | grep 'userHostname=' | sed -E 's/.*userHostname="https?:\/\/([^"]+)".*/\1/' | head -n1 || true)
    say_ok "启动成功！域名: https://${TRY_DOMAIN:-获取中}"
}

# --- 菜单界面 ---
install_deps
setup_env
clear
say "=================================================="
say "      NMU-Glitch 全能整合安全面板 (动态版)       "
say "=================================================="
echo " 1. 启动服务 (手动配置 + 初始分流)"
echo " 2. 停止服务"
echo " 3. 物理卸载"
echo " 4. 【动态更新】添加走 WARP 的域名 (不断域名)"
echo " 0. 退出"
read -p "选择操作: " mode

case "${mode:-1}" in
    1)
        read -p "Token: " token
        read -p "固定端口? (直接回车随机, 否则输入端口): " wsport
        read -p "CF Tunnel Token (可选): " cf_tunnel_token
        read -p "分流域名 (逗号隔开): " warp_domains
        quicktunnel ;;
    2) stop_services; say_ok "已停止" ;;
    3) stop_services; [[ "$(id -u)" -eq 0 ]] && userdel -r "$SERVICE_USER" || rm -rf "$WORK_DIR"; say_ok "已卸载" ;;
    4) update_warp_domains ;;
    *) exit 0 ;;
esac
