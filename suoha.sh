#!/usr/bin/env bash

# =========================================================
# NMU Tunnel V9.7 - 生产级安全改良版
# - 修复：改用纯被动 /proc/locks 内核级无害化锁探测 (方案 A)
# - 修复：引入 WARP 端口状态感知，自动降级为直连防黑洞 (方案 B)
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

say() { echo -e "\033[0;34m[NMU-V9.7]\033[0m $*"; }
ok() { echo -e "\033[0;32m[OK]\033[0m $*"; }
err() { echo -e "\033[0;31m[ERROR]\033[0m $*"; exit 1; }

require_root() {
    [[ "$(id -u)" -ne 0 ]] && err "请使用 root 权限执行 (sudo $0 install)"
}

# --- 1. 无害化内核级锁探测 (方案 A) ---
is_dpkg_locked() {
    local lock_files=("/var/lib/dpkg/lock-frontend" "/var/lib/dpkg/lock" "/var/lib/apt/lists/lock")
    for lock_file in "${lock_files[@]}"; do
        if [[ -f "$lock_file" ]]; then
            local inode
            inode=$(stat -c '%i' "$lock_file" 2>/dev/null || true)
            if [[ -n "$inode" ]]; then
                # 在内核 /proc/locks 中检索该 Inode 是否有 active 锁
                if grep -q -E ":${inode}(\s|$)" /proc/locks 2>/dev/null; then
                    return 0 # 处于锁定状态
                fi
            fi
        fi
    done
    return 1 # 未锁定
}

wait_for_apt() {
    if command -v apt-get >/dev/null 2>&1; then
        say "检查系统包管理器锁状态 (内核只读探测)..."
        local max_wait=300
        local wait_time=0
        while is_dpkg_locked; do
            if [ $wait_time -ge $max_wait ]; then
                err "包管理器锁检测超时，请手动排查占用进程。"
            fi
            say "检测到系统后台有更新程序运行，排队中 (已等待 ${wait_time}s)..."
            sleep 10
            wait_time=$((wait_time + 10))
        done
    fi
}

install_deps() {
    wait_for_apt
    say "同步环境依赖..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y || err "apt-get update 失败"
        apt-get install -y curl ca-certificates iproute2 file tar gzip psmisc || err "apt 安装依赖失败"
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl ca-certificates iproute2 file tar gzip psmisc bash || err "apk 安装依赖失败"
    fi
}

# --- 2. WARP 部署引擎 ---
setup_warp() {
    if ss -lnt 2>/dev/null | grep -q ":40000"; then
        ok "WARP 代理已就绪 (40000 端口)。"
        return
    fi
    say "正在自动部署官方 WARP SOCKS5 代理..."
    if curl -fsSL https://raw.githubusercontent.com/P3TERX/warp.sh/main/warp.sh -o /tmp/warp.sh; then
        chmod +x /tmp/warp.sh
        /tmp/warp.sh s5 -p 40000 || say "警告: WARP 自动部署失败，分流层可能失效。"
    else
        say "警告: 无法下载 WARP 部署脚本，分流层可能失效。"
    fi
}

# --- 3. 组件同步 ---
get_sb_version() {
    local raw_json v
    raw_json=$(curl -sL --connect-timeout 10 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null)
    if [ -z "$raw_json" ]; then
        echo ""
        return
    fi
    v=$(echo "$raw_json" | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/' | head -n1 || true)
    if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$v"
    else
        echo ""
    fi
}

create_env() {
    say "同步核心二进制组件..."
    id "$SERVICE_USER" >/dev/null 2>&1 || useradd -r -m -d "$LIB_DIR" -s /usr/sbin/nologin "$SERVICE_USER" || err "用户创建失败"
    mkdir -p "$ETC_DIR" "$BIN_DIR" "$LOG_DIR" || err "目录初始化失败"

    local ARCH="amd64"
    if [[ "$(uname -m)" != "x86_64" ]]; then
        ARCH="arm64"
    fi
    
    say "正在同步 xtunnel 核心..."
    curl -fL --retry 3 "https://github.com/nmu-glitch/my-tunnels/releases/download/v1.0.0/x-tunnel-linux-${ARCH}" -o "${BIN_DIR}/xtunnel" || err "xtunnel 下载失败"
    
    say "正在同步 cloudflared 核心..."
    curl -fL --retry 3 "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" -o "${BIN_DIR}/cloudflared" || err "cloudflared 下载失败"
    
    local SB_VER
    SB_VER=$(get_sb_version)
    if [[ -z "$SB_VER" ]]; then
        SB_VER="1.8.11" # 安全回滚版本
        say "无法解析最新 Sing-box 版本，自动启用安全备用版本: v${SB_VER}"
    fi
    
    say "正在下载 Sing-box v${SB_VER}..."
    if curl -fL --retry 3 "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${ARCH}.tar.gz" -o /tmp/sb.tar.gz; then
        tar -zxf /tmp/sb.tar.gz --strip-components=1 -C "${BIN_DIR}" || err "Sing-box 解压失败"
        if [[ -f "${BIN_DIR}/sing-box" ]]; then
            mv "${BIN_DIR}/sing-box" "${BIN_DIR}/singbox"
        fi
        rm -f /tmp/sb.tar.gz
    else
        err "Sing-box 下载失败"
    fi

    chmod +x "${BIN_DIR}/"* || err "组件赋权失败"
    chown -R "$SERVICE_USER":"$SERVICE_USER" "$LIB_DIR" "$LOG_DIR" || err "权限归属分配失败"
}

# --- 4. 配置交互与感知分流模板 (方案 B) ---
write_configs() {
    say "配置交互..."
    read -p "请输入隧道连接 Token: " token
    [[ -z "$token" ]] && err "Token 不能为空"
    read -p "本地监听端口 (默认 56908): " ws_port; ws_port=${ws_port:-56908}
    read -p "CF Tunnel Token (留空用临时域名): " cf_token
    read -p "分流域名 (除默认外，逗号隔开): " extra_domains

    local sb_port=$((RANDOM % 10000 + 40001))
    local m_port=$((RANDOM % 10000 + 30000))

    cat > "${ETC_DIR}/env" <<EOF
WS_PORT=${ws_port}
SB_PORT=${sb_port}
METRICS_PORT=${m_port}
TOKEN=${token}
CF_TOKEN=${cf_token}
EOF

    local domains='"netflix.com","chatgpt.com","openai.com","ip.sb"'
    if [[ -n "$extra_domains" ]]; then
        for d in $(echo "$extra_domains" | tr ',' ' '); do
            domains="${domains},\"$d\""
        done
    fi

    # 方案 B：WARP 状态感知决策
    local warp_outbound
    if ss -lnt 2>/dev/null | grep -q ":40000"; then
        warp_outbound='{"type": "socks", "tag": "warp", "server": "127.0.0.1", "server_port": 40000}'
        ok "检测到本地 WARP 运行中，流媒体路由将通过 WARP 出口。"
    else
        warp_outbound='{"type": "direct", "tag": "warp"}'
        say "警告: 未检测到 WARP 代理。已自动将分流路由无缝降级为 [直连] 模式，防止黑洞异常。"
    fi

    cat > "${ETC_DIR}/singbox.json" <<EOF
{
  "inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": ${sb_port}}],
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    ${warp_outbound}
  ],
  "route": { 
    "rules": [{"domain": [ ${domains} ], "outbound": "warp"}], 
    "final": "direct" 
  }
}
EOF
    chown -R root:"$SERVICE_USER" "$ETC_DIR"
    chmod 640 "${ETC_DIR}/"*
}

# --- 5. Systemd 级联链路 ---
write_units() {
    say "部署 Systemd 强耦合链路..."

    # 1. Singbox (基础设施层)
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

    # 2. xtunnel (依赖 Singbox，通过 PartOf 保证联动，不牺牲独立崩溃自愈能力)
    cat > "/etc/systemd/system/${XT_SERVICE}" <<EOF
[Unit]
Description=NMU xtunnel Core
After=network.target ${SB_SERVICE}
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

    # 3. cloudflared (依赖 xtunnel)
    cat > "/etc/systemd/system/${CF_SERVICE}" <<EOF
[Unit]
Description=NMU Cloudflared Exit
After=network.target ${XT_SERVICE}
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

# --- 6. 启动与日志诊断 ---
start_all() {
    say "正在激活隧道链路..."
    systemctl daemon-reload
    systemctl enable "$SB_SERVICE" "$XT_SERVICE" "$CF_SERVICE" >/dev/null 2>&1
    
    # 仅需拉起最上游，系统将依依赖链自动唤醒底层服务
    systemctl restart "$CF_SERVICE"
    
    say "正在检测链路连通性..."
    sleep 8
    
    if ! systemctl is-active --quiet "$CF_SERVICE"; then
        say "\033[0;31m检测到链路异常，正在提取报错...\033[0m"
        journalctl -u "$SB_SERVICE" -u "$XT_SERVICE" -u "$CF_SERVICE" --no-pager -n 20
        err "链路激活失败。"
    fi

    ok "隧道链路已全面就绪。"
    
    if [ -f "${ETC_DIR}/env" ]; then
        local WS_PORT SB_PORT METRICS_PORT TOKEN CF_TOKEN
        while IFS='=' read -r key value; do
            if [[ "$key" =~ ^[A-Z0-9_]+$ ]]; then
                eval "$key=\"$value\""
            fi
        done < "${ETC_DIR}/env"

        if [[ -n "$METRICS_PORT" ]]; then
            local metrics_data domain
            metrics_data=$(curl -s --connect-timeout 2 "http://127.0.0.1:${METRICS_PORT}/metrics" 2>/dev/null || true)
            domain=$(echo "$metrics_data" | grep 'userHostname=' | sed -E 's/.*userHostname="https?:\/\/([^"]+)".*/\1/' | head -n1 || true)
            if [[ -n "$domain" ]]; then
                say "连接地址: https://$domain"
            else
                say "固定域名模式运行中，请检查 CF Dashboard。"
            fi
        fi
    fi
}

# --- 运行入口 ---
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
        ok "链路已安全关闭。"
        ;;
    logs)
        journalctl -u "$SB_SERVICE" -u "$XT_SERVICE" -u "$CF_SERVICE" -f
        ;;
    uninstall)
        require_root
        systemctl disable --now "$CF_SERVICE" "$XT_SERVICE" "$SB_SERVICE" || true
        rm -f /etc/systemd/system/nmu-*.service
        systemctl daemon-reload
        rm -rf "$ETC_DIR" "$LIB_DIR" "$LOG_DIR"
        userdel -r "$SERVICE_USER" || true
        ok "环境已彻底物理清理。"
        ;;
    *)
        echo "用法: $0 {install|stop|logs|uninstall}"
        ;;
esac
