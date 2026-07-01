#!/usr/bin/env bash
set -eo pipefail

# =========================================================
# NMU Tunnel V9.4 - 旗舰稳健版
# - 修复：改用 pgrep 实现无依赖包管理器锁检测
# - 修复：增强 GitHub API 版本号解析逻辑
# - 修复：完善 Systemd [Install] 块与生命周期联动 (PartOf)
# =========================================================

APP_NAME="nmu-tunnel"
SERVICE_USER="nmu-tunnel"
ETC_DIR="/etc/${APP_NAME}"
LIB_DIR="/var/lib/${APP_NAME}"
BIN_DIR="${LIB_DIR}/bin"
LOG_DIR="/var/log/${APP_NAME}"

SB_SERVICE="nmu-singbox.service"
XT_SERVICE="nmu-xtunnel.service"
CF_SERVICE="nmu-cloudflared.service"

say() { echo -e "\033[0;34m[NMU-V9.4]\033[0m $*"; }
err() { echo -e "\033[0;31m[ERROR]\033[0m $*"; exit 1; }

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "请使用 root 权限执行此脚本 (sudo)"
    fi
}

# --- 1. 无依赖包管理器锁检测 ---
wait_for_apt() {
    local count=0
    # 检测常见包管理器进程，无需 fuser 依赖
    while pgrep -x "apt|apt-get|dpkg|unattended-upgr" >/dev/null 2>&1; do
        if [ $count -eq 0 ]; then say "检测到系统后台正在更新，脚本已进入排队状态..."; fi
        sleep 5
        ((count++))
        if [ $count -gt 120 ]; then err "等待包管理器释放超时 (10分钟)，请手动检查。"; fi
    done
}

install_deps() {
    say "同步环境依赖..."
    wait_for_apt
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y
        apt-get install -y curl ca-certificates iproute2 file tar gzip
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl ca-certificates iproute2 file tar gzip bash
    fi
}

# --- 2. 稳健获取远程版本 ---
get_sb_version() {
    local version
    version=$(curl -sL --connect-timeout 10 https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/' || echo "")
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        err "获取 Sing-box 版本失败，请检查网络或 GitHub API 限制。"
    fi
    echo "$version"
}

create_env() {
    say "同步最新二进制组件..."
    id "$SERVICE_USER" >/dev/null 2>&1 || useradd -r -m -d "$LIB_DIR" -s /usr/sbin/nologin "$SERVICE_USER"
    mkdir -p "$ETC_DIR" "$BIN_DIR" "$LOG_DIR"

    ARCH="amd64"; [[ "$(uname -m)" != "x86_64" ]] && ARCH="arm64"
    
    # 核心组件下载
    curl -fL --retry 3 --connect-timeout 10 "https://github.com/nmu-glitch/my-tunnels/releases/download/v1.0.0/x-tunnel-linux-${ARCH}" -o "${BIN_DIR}/xtunnel"
    curl -fL --retry 3 --connect-timeout 10 "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" -o "${BIN_DIR}/cloudflared"
    
    SB_VER=$(get_sb_version)
    say "获取到 Sing-box 最新版本: v$SB_VER"
    curl -fL --retry 3 "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${ARCH}.tar.gz" -o /tmp/sb.tar.gz
    tar -zxf /tmp/sb.tar.gz --strip-components=1 -C "${BIN_DIR}"
    [ -f "${BIN_DIR}/sing-box" ] && mv "${BIN_DIR}/sing-box" "${BIN_DIR}/singbox"

    chmod +x "${BIN_DIR}/"*
    chown -R "$SERVICE_USER":"$SERVICE_USER" "$LIB_DIR" "$LOG_DIR"
}

# --- 3. 配置交互 ---
write_configs() {
    say "配置参数交互..."
    read -p "请输入隧道 Token: " token
    [ -z "$token" ] && err "Token 不能为空"
    read -p "监听端口 (默认 56908): " ws_port; ws_port=${ws_port:-56908}
    read -p "CF Tunnel Token (留空则用临时域名): " cf_token
    read -p "额外分流域名 (逗号隔开): " extra_domains

    local sb_port=$((RANDOM % 10000 + 40001))
    local metrics_port=$((RANDOM % 10000 + 30000))

    cat > "${ETC_DIR}/env" <<EOF
WS_PORT=${ws_port}
SB_PORT=${sb_port}
METRICS_PORT=${metrics_port}
TOKEN=${token}
CF_TOKEN=${cf_token}
EOF

    local domains='"netflix.com","chatgpt.com","openai.com","ip.sb"'
    [[ -n "$extra_domains" ]] && for d in $(echo $extra_domains | tr ',' ' '); do domains="${domains},\"$d\""; done

    cat > "${ETC_DIR}/singbox.json" <<EOF
{
  "inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": ${sb_port}}],
  "outbounds": [{"type": "direct", "tag": "direct"},{"type": "socks", "tag": "warp", "server": "127.0.0.1", "server_port": 40000}],
  "route": { "rules": [{"domain": [ ${domains} ], "outbound": "warp"}], "final": "direct" }
}
EOF
    chown -R root:"$SERVICE_USER" "$ETC_DIR"
    chmod 640 "${ETC_DIR}/"*
}

# --- 4. 完善 Systemd 强联动链 ---
write_units() {
    say "部署 systemd 联动服务链..."
    
    # 基础分流层
    cat > "/etc/systemd/system/${SB_SERVICE}" <<EOF
[Unit]
Description=NMU Singbox Base
After=network.target

[Service]
ExecStart=${BIN_DIR}/singbox run -c ${ETC_DIR}/singbox.json
User=${SERVICE_USER}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    # 核心转换层
    cat > "/etc/systemd/system/${XT_SERVICE}" <<EOF
[Unit]
Description=NMU xtunnel Core
After=${SB_SERVICE}
Requires=${SB_SERVICE}
PartOf=${SB_SERVICE}

[Service]
EnvironmentFile=${ETC_DIR}/env
ExecStart=${BIN_DIR}/xtunnel -l ws://127.0.0.1:\${WS_PORT} -token \${TOKEN} -f socks5://127.0.0.1:\${SB_PORT}
User=${SERVICE_USER}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    # 外部出口层
    cat > "/etc/systemd/system/${CF_SERVICE}" <<EOF
[Unit]
Description=NMU Cloudflared Exit
After=${XT_SERVICE}
Requires=${XT_SERVICE}
PartOf=${XT_SERVICE}

[Service]
EnvironmentFile=${ETC_DIR}/env
ExecStart=/usr/bin/bash -c 'if [ -n "\$CF_TOKEN" ]; then exec ${BIN_DIR}/cloudflared tunnel run --token \$CF_TOKEN; else exec ${BIN_DIR}/cloudflared tunnel --url http://127.0.0.1:\$WS_PORT --metrics 127.0.0.1:\$METRICS_PORT; fi'
User=${SERVICE_USER}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

# --- 5. 启动与诊断 ---
start_all() {
    say "正在激活服务链路..."
    # 依次启用
    systemctl enable "$SB_SERVICE" "$XT_SERVICE" "$CF_SERVICE" >/dev/null 2>&1
    # 联动重启
    systemctl restart "$SB_SERVICE"
    
    say "等待隧道热启动..."
    sleep 6
    
    if ! systemctl is-active --quiet "$CF_SERVICE"; then
        say "\033[0;31m启动链路异常，开始回溯日志...\033[0m"
        journalctl -u "$CF_SERVICE" --no-pager -n 15
        err "链路建立失败。"
    fi

    say "链路已全面就绪。"
    source "${ETC_DIR}/env"
    domain=$(curl -s http://127.0.0.1:${METRICS_PORT}/metrics | grep 'userHostname=' | sed -E 's/.*userHostname="https?:\/\/([^"]+)".*/\1/' | head -n1 || true)
    [ -n "$domain" ] && say "连接地址: https://$domain"
}

# --- 6. 执行入口 ---
case "${1:-help}" in
    install)
        require_root
        install_deps
        create_env
        write_configs
        write_units
        start_all
        ;;
    stop)
        systemctl stop "$CF_SERVICE" "$XT_SERVICE" "$SB_SERVICE"
        say "链路已断开。"
        ;;
    logs)
        journalctl -u "$CF_SERVICE" -u "$XT_SERVICE" -f
        ;;
    uninstall)
        systemctl disable --now "$CF_SERVICE" "$XT_SERVICE" "$SB_SERVICE" >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/nmu-*.service
        systemctl daemon-reload
        rm -rf "$ETC_DIR" "$LIB_DIR" "$LOG_DIR"
        userdel -r "$SERVICE_USER" 2>/dev/null || true
        say "清理完毕。"
        ;;
    *)
        echo "用法: $0 {install|stop|logs|uninstall}"
        ;;
esac
