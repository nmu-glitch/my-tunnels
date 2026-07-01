#!/usr/bin/env bash
# =========================================================
# NMU Tunnel V9.2 - 健壮修复版
# =========================================================
set -eo pipefail

APP_NAME="nmu-tunnel"
SERVICE_USER="nmu-tunnel"
ETC_DIR="/etc/${APP_NAME}"
LIB_DIR="/var/lib/${APP_NAME}"
BIN_DIR="${LIB_DIR}/bin"
LOG_DIR="/var/log/${APP_NAME}"
SCRIPT_DIR="/usr/local/lib/${APP_NAME}"

XT_SERVICE="nmu-xtunnel.service"
CF_SERVICE="nmu-cloudflared.service"
SB_SERVICE="nmu-singbox.service"

say() { echo -e "[NMU-V9.2] $*"; }
err() { echo -e "[ERROR] $*"; exit 1; }

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "请使用 root 执行：sudo $0 install"
    fi
}

install_deps() {
    say "正在安装系统依赖，请稍候..."
    # 强制清理可能存在的 apt 锁
    if command -v apt-get >/dev/null 2>&1; then
        rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock* || true
        apt-get update -y || say "警告: apt-get update 失败，尝试继续安装..."
        apt-get install -y curl ca-certificates iproute2 file tar gzip psmisc || err "依赖安装失败"
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl ca-certificates iproute2 file tar gzip psmisc bash
    fi
}

setup_warp() {
    if ss -lnt | grep -q ":40000"; then
        say "WARP 已就绪。"
        return
    fi
    say "自动部署官方 WARP SOCKS5..."
    curl -fsSL https://raw.githubusercontent.com/P3TERX/warp.sh/main/warp.sh -o /tmp/warp.sh && chmod +x /tmp/warp.sh
    /tmp/warp.sh s5 -p 40000 || say "WARP 安装可能不完整，请稍后检查"
}

create_env() {
    say "初始化运行环境..."
    id "$SERVICE_USER" >/dev/null 2>&1 || useradd -r -m -d "$LIB_DIR" -s /usr/sbin/nologin "$SERVICE_USER"
    mkdir -p "$ETC_DIR" "$BIN_DIR" "$LOG_DIR" "$SCRIPT_DIR"

    ARCH="amd64"; [[ "$(uname -m)" != "x86_64" ]] && ARCH="arm64"
    
    say "下载核心组件 ($ARCH)..."
    curl -fL "https://github.com/nmu-glitch/my-tunnels/releases/download/v1.0.0/x-tunnel-linux-${ARCH}" -o "${BIN_DIR}/xtunnel"
    curl -fL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" -o "${BIN_DIR}/cloudflared"
    
    SB_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d ":" -f2 | tr -d '\"v ,')
    curl -fL "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${ARCH}.tar.gz" -o /tmp/sb.tar.gz
    tar -zxf /tmp/sb.tar.gz --strip-components=1 -C "${BIN_DIR}"
    [ -f "${BIN_DIR}/sing-box" ] && mv "${BIN_DIR}/sing-box" "${BIN_DIR}/singbox"

    chmod +x "${BIN_DIR}/"*
    chown -R "$SERVICE_USER":"$SERVICE_USER" "$LIB_DIR" "$LOG_DIR"
}

write_configs() {
    say "--- 配置交互 ---"
    read -p "请输入 xtunnel Token: " token
    [ -z "$token" ] && err "Token 不能为空"
    read -p "本地监听端口 (默认 56908): " ws_port; ws_port=${ws_port:-56908}
    read -p "CF Tunnel Token (留空则使用临时域名): " cf_token
    read -p "分流域名 (除默认外，逗号隔开): " extra_domains

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

write_units() {
    cat > "/etc/systemd/system/${SB_SERVICE}" <<EOF
[Unit]
Description=NMU Singbox
[Service]
ExecStart=${BIN_DIR}/singbox run -c ${ETC_DIR}/singbox.json
User=${SERVICE_USER}
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    cat > "/etc/systemd/system/${XT_SERVICE}" <<EOF
[Unit]
Description=NMU xtunnel
After=${SB_SERVICE}
[Service]
EnvironmentFile=${ETC_DIR}/env
ExecStart=${BIN_DIR}/xtunnel -l ws://127.0.0.1:\${WS_PORT} -token \${TOKEN} -f socks5://127.0.0.1:\${SB_PORT}
User=${SERVICE_USER}
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    cat > "/etc/systemd/system/${CF_SERVICE}" <<EOF
[Unit]
Description=NMU Cloudflared
After=${XT_SERVICE}
[Service]
EnvironmentFile=${ETC_DIR}/env
ExecStart=/usr/bin/bash -c 'if [ -n "\$CF_TOKEN" ]; then exec ${BIN_DIR}/cloudflared tunnel run --token \$CF_TOKEN; else exec ${BIN_DIR}/cloudflared tunnel --url http://127.0.0.1:\$WS_PORT --metrics 127.0.0.1:\$METRICS_PORT; fi'
User=${SERVICE_USER}
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

start_all() {
    systemctl enable --now "$SB_SERVICE" "$XT_SERVICE" "$CF_SERVICE"
    say "服务已启动，正在等待隧道建立..."
    sleep 10
    if systemctl is-active --quiet "$CF_SERVICE"; then
        source "${ETC_DIR}/env"
        domain=$(curl -s http://127.0.0.1:${METRICS_PORT}/metrics | grep 'userHostname=' | sed -E 's/.*userHostname="https?:\/\/([^"]+)".*/\1/' | head -n1 || true)
        [ -n "$domain" ] && say "临时域名: https://$domain" || say "隧道已建立，请在 CF 面板查看。"
    fi
}

case "${1:-help}" in
    install)
        require_root
        install_deps
        setup_warp
        create_env
        write_configs
        write_units
        start_all
        ;;
    stop)
        systemctl stop "$CF_SERVICE" "$XT_SERVICE" "$SB_SERVICE"
        say "服务已停止。"
        ;;
    uninstall)
        systemctl disable --now "$CF_SERVICE" "$XT_SERVICE" "$SB_SERVICE" || true
        rm -f /etc/systemd/system/nmu-*.service
        rm -rf "$ETC_DIR" "$LIB_DIR"
        userdel -r "$SERVICE_USER" || true
        say "已完全卸载。"
        ;;
    *)
        echo "用法: $0 {install|stop|uninstall}"
        ;;
esac
