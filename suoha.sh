#!/usr/bin/env bash

# =========================================================
# NMU Tunnel V12.7 - 终极稳定版
# - 修复：校准入站配置字段，恢复为标准 "listen_port"，彻底通关 v1.13.x 哨兵检测
# - 安全：经典 TTY 交互式菜单，保留双模无头自适应识别
# - 修复：支持在保持默认流媒体分流绝对不受侵扰的前提下，去重并流追加新域名分流
# - 健壮：整合进程强杀、VFS 原子重命名避让、SELinux 标签修复
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

say() { echo -e "\033[0;34m[NMU-V12.7]\033[0m $*"; }
ok() { echo -e "\033[0;32m[OK]\033[0m $*"; }
err() { echo -e "\033[0;31m[ERROR]\033[0m $*"; exit 1; }

require_root() {
    [[ "$(id -u)" -ne 0 ]] && err "请使用 root 权限执行 (sudo $0)"
}

# --- 1. 内核级锁检测 ---
is_dpkg_locked() {
    local lock_files=("/var/lib/dpkg/lock-frontend" "/var/lib/dpkg/lock" "/var/lib/apt/lists/lock")
    for lock_file in "${lock_files[@]}"; do
        if [[ -f "$lock_file" ]]; then
            local inode
            inode=$(stat -c '%i' "$lock_file" 2>/dev/null || true)
            if [[ -n "$inode" ]]; then
                if grep -q -E ":${inode}(\s|$)" /proc/locks 2>/dev/null; then
                    return 0
                fi
            fi
        fi
    done
    return 1
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

# --- 2. 强正则凭证提取与自适应栈探测 ---
get_warp_profile() {
    say "正在向公网生成器获取官方 WARP 原生凭证..."
    local warpurl raw_pvk raw_wpv6 raw_res
    
    warpurl=$(curl -sm6 -k https://warp.xijp.eu.org 2>/dev/null || wget --tries=2 -qO- https://warp.xijp.eu.org 2>/dev/null || true)
    warpurl=$(echo "$warpurl" | tr -d '\r' | tr -d '"')
    
    raw_pvk=$(echo "$warpurl" | grep -i "Private_key" | grep -oE "[A-Za-z0-9+/]{43}=" | head -n1 || true)
    raw_wpv6=$(echo "$warpurl" | grep -i "IPV6" | grep -oE "([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}" | head -n1 || true)
    if [[ -z "$raw_wpv6" ]]; then
        raw_wpv6=$(echo "$warpurl" | grep -i "IPV6" | grep -oE "([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}" | head -n1 || true)
    fi
    raw_res=$(echo "$warpurl" | grep -i "reserved" | grep -oE "\[[0-9]+,\s*[0-9]+,\s*[0-9]+\]" | head -n1 || true)

    raw_pvk=$(echo "$raw_pvk" | xargs || true)
    raw_wpv6=$(echo "$raw_wpv6" | xargs || true)
    raw_res=$(echo "$raw_res" | xargs || true)

    local pvk_valid=false
    local wpv6_valid=false
    local res_valid=false

    [[ "$raw_pvk" =~ ^[A-Za-z0-9+/]{43}=$ ]] && pvk_valid=true
    [[ "$raw_wpv6" =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]] && wpv6_valid=true
    [[ "$raw_res" =~ ^\[[0-9]+,\s*[0-9]+,\s*[0-9]+\]$ ]] && res_valid=true

    local final_pvk final_wpv6 final_res
    
    if [ "$pvk_valid" = "true" ] && [ "$wpv6_valid" = "true" ] && [ "$res_valid" = "true" ]; then
        final_pvk="$raw_pvk"
        final_wpv6="$raw_wpv6"
        final_res="$raw_res"
        ok "成功拉取并验证动态 WARP 凭证。"
    else
        say "警告: 远程凭证校验失败 (解析截断或格式不匹配)。正在启用预设安全凭证..."
        final_pvk="52cuYFgCJXp0LAq7+nWJIbCXXgU9eGggOc+Hlfz5u6A="
        final_wpv6="2606:4700:110:8d8d:1845:c39f:2dd5:a03a"
        final_res="[215, 69, 233]"
    fi

    local has_v6=false
    if curl -s6m3 https://icanhazip.com >/dev/null 2>&1; then
        has_v6=true
    fi

    local endpoint="162.159.192.1"
    local local_address_json='["172.16.0.2/32"]'

    if [ "$has_v6" = "true" ]; then
        endpoint="[2606:4700:d0::a29f:c001]"
        local_address_json="[\"172.16.0.2/32\", \"${final_wpv6}/128\"]"
        say "检测到原生双栈环境，开启双栈内网代理，Endpoint 调整为 IPv6 节点。"
    else
        say "检测到单栈 (IPv4) 环境，主动剥离虚拟 IPv6 地址，消除半断网隐患。"
    fi

    mkdir -p "$ETC_DIR"
    cat > "${ETC_DIR}/warp_profile" <<EOF
WARP_PVK="${final_pvk}"
WARP_RES="${final_res}"
WARP_ENDPOINT="${endpoint}"
WARP_LOCAL_ADDR='${local_address_json}'
EOF
    ok "WARP 凭证状态库建立完成。"
}

# --- 3. 进程原生切断器 & 动态版本探针 ---
kill_process_native() {
    local proc_patterns=("cloudflared" "xtunnel" "singbox")
    for pattern in "${proc_patterns[@]}"; do
        pkill -9 -f "$pattern" >/dev/null 2>&1 || true
        local pids
        pids=$(ps -ef 2>/dev/null | grep "$pattern" | grep -v grep | awk '{print $2}' || true)
        if [[ -n "$pids" ]]; then
            echo "$pids" | xargs -r kill -9 >/dev/null 2>&1 || true
        fi
    done
}

get_local_sb_version() {
    if [[ -x "${BIN_DIR}/singbox" ]]; then
        local v
        v=$("${BIN_DIR}/singbox" version 2>/dev/null | awk '/sing-box version/{print $3}' | head -n1 || true)
        v=$(echo "$v" | tr -d '\r' | xargs || true)
        if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$v"
            return 0
        fi
    fi
    echo ""
    return 1
}

get_sb_version() {
    local raw_json v
    raw_json=$(curl -sL --connect-timeout 4 --max-time 8 -H "User-Agent: Mozilla/5.0" https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null || true)
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
    
    systemctl stop "$CF_SERVICE" "$XT_SERVICE" "$SB_SERVICE" >/dev/null 2>&1 || true
    kill_process_native
    
    id "$SERVICE_USER" >/dev/null 2>&1 || useradd -r -m -d "$LIB_DIR" -s /usr/sbin/nologin "$SERVICE_USER" || err "用户创建失败"
    mkdir -p "$ETC_DIR" "$BIN_DIR" "$LOG_DIR" || err "目录初始化失败"

    local ARCH="amd64"
    if [[ "$(uname -m)" != "x86_64" ]]; then
        ARCH="arm64"
    fi
    
    # --- XTUNNEL 同步 (恒定 VFS 重命名避让) ---
    say "正在同步 xtunnel 核心..."
    if [[ -f "${BIN_DIR}/xtunnel" ]]; then
        mv -f "${BIN_DIR}/xtunnel" "${BIN_DIR}/xtunnel.old" >/dev/null 2>&1 || true
        rm -f "${BIN_DIR}/xtunnel.old" >/dev/null 2>&1 &
    fi
    curl -fL --retry 3 "https://github.com/nmu-glitch/my-tunnels/releases/download/v1.0.0/x-tunnel-linux-${ARCH}" -o "/tmp/xtunnel" || err "xtunnel 下载失败"
    mv -f "/tmp/xtunnel" "${BIN_DIR}/xtunnel"
    
    # --- CLOUDFLARED 同步 (恒定 VFS 重命名避让) ---
    say "正在同步 cloudflared 核心..."
    if [[ -f "${BIN_DIR}/cloudflared" ]]; then
        mv -f "${BIN_DIR}/cloudflared" "${BIN_DIR}/cloudflared.old" >/dev/null 2>&1 || true
        rm -f "${BIN_DIR}/cloudflared.old" >/dev/null 2>&1 &
    fi
    curl -fL --retry 3 "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" -o "/tmp/cloudflared" || err "cloudflared 下载失败"
    mv -f "/tmp/cloudflared" "${BIN_DIR}/cloudflared"
    
    # --- SING-BOX 确定版本与按需避让 ---
    local LOCAL_VER TARGET_VER
    LOCAL_VER=$(get_local_sb_version)
    
    if [[ -n "$LOCAL_VER" ]]; then
        TARGET_VER=$(get_sb_version)
        [[ -z "$TARGET_VER" ]] && TARGET_VER="$LOCAL_VER"
    else
        say "未检测到本地已存组件，正在向 GitHub 检索 Sing-box 最新发行版..."
        TARGET_VER=$(get_sb_version)
        [[ -z "$TARGET_VER" ]] && TARGET_VER="1.8.11"
    fi

    local need_sb_update=true
    if [[ -x "${BIN_DIR}/singbox" ]] && [[ "$LOCAL_VER" = "$TARGET_VER" ]]; then
        need_sb_update=false
        say "本地已存版本 v${LOCAL_VER} 匹配目标版本 v${TARGET_VER}，跳过避让与下载，彻底规避哨兵死锁。"
    fi

    if [ "$need_sb_update" = "true" ]; then
        say "正在下载安装 Sing-box v${TARGET_VER}..."
        if [[ -f "${BIN_DIR}/singbox" ]]; then
            mv -f "${BIN_DIR}/singbox" "${BIN_DIR}/singbox.old" >/dev/null 2>&1 || true
            rm -f "${BIN_DIR}/singbox.old" >/dev/null 2>&1 &
        fi
        
        if curl -fL --retry 3 "https://github.com/SagerNet/sing-box/releases/download/v${TARGET_VER}/sing-box-${TARGET_VER}-linux-${ARCH}.tar.gz" -o /tmp/sb.tar.gz; then
            mkdir -p /tmp/sb_unpack
            tar -zxf /tmp/sb.tar.gz -C /tmp/sb_unpack || err "Sing-box 解压失败"
            
            local sb_bin
            sb_bin=$(find /tmp/sb_unpack -type f -name "sing-box" | head -n1)
            if [[ -f "$sb_bin" ]]; then
                mv -f "$sb_bin" "${BIN_DIR}/singbox"
            else
                err "解压包中未找到有效的 sing-box 二进制执行程序"
            fi
            rm -rf /tmp/sb_unpack /tmp/sb.tar.gz
        else
            err "下载 Sing-box 失败"
        fi
    fi

    chmod +x "${BIN_DIR}/xtunnel" "${BIN_DIR}/cloudflared" "${BIN_DIR}/singbox" || err "组件赋权失败"
    
    if command -v restorecon >/dev/null 2>&1; then
        say "检测到 SELinux 安全策略处于激活状态，正在强制重构二进制目录上下文标签..."
        restorecon -R "${BIN_DIR}" >/dev/null 2>&1 || true
    fi

    chown -R "$SERVICE_USER":"$SERVICE_USER" "$LIB_DIR" "$LOG_DIR" || err "权限归属分配失败"
}

# --- 4. 配置写入 (去重追加分流并流算法) ---
write_configs() {
    say "配置写入中..."
    
    local token="${TOKEN}"
    local ws_port="${WS_PORT}"
    local cf_token="${CF_TOKEN}"
    local extra_domains="${EXTRA_DOMAINS}"

    # 检测 TTY 状态，支持 Headless 自动化非阻塞集成
    if [[ -z "$token" ]]; then
        if [ -t 0 ]; then
            read -p "请输入隧道连接 Token: " token
            [[ -z "$token" ]] && err "Token 不能为空"
        else
            err "检测到无头 (Headless) 自动化环境，必须提供 TOKEN 环境变量"
        fi
    fi

    if [[ -z "$ws_port" ]]; then
        if [ -t 0 ]; then
            read -p "本地监听端口 (默认 56908): " ws_port
        fi
        ws_port=${ws_port:-56908}
    fi

    if [[ -z "$cf_token" ]]; then
        if [ -t 0 ]; then
            read -p "CF Tunnel Token (留空用临时域名): " cf_token
        fi
    fi

    if [[ -z "$extra_domains" ]]; then
        if [ -t 0 ]; then
            read -p "追加分流域名 (除默认外，逗号隔开，不改变默认分流): " extra_domains
        fi
    fi

    local sb_port=$((RANDOM % 10000 + 40001))
    local m_port=$((RANDOM % 10000 + 30000))

    local pvk res endpoint local_addr
    if [ -f "${ETC_DIR}/warp_profile" ]; then
        source "${ETC_DIR}/warp_profile"
        pvk="$WARP_PVK"
        res="$WARP_RES"
        endpoint="$WARP_ENDPOINT"
        local_addr="$WARP_LOCAL_ADDR"
    fi

    pvk=${pvk:-"52cuYFgCJXp0LAq7+nWJIbCXXgU9eGggOc+Hlfz5u6A="}
    res=${res:-"[215, 69, 233]"}
    endpoint=${endpoint:-"162.159.192.1"}
    local_addr=${local_addr:-'["172.16.0.2/32"]'}

    cat > "${ETC_DIR}/env" <<EOF
WS_PORT=${ws_port}
SB_PORT=${sb_port}
METRICS_PORT=${m_port}
TOKEN=${token}
CF_TOKEN=${cf_token}
EOF

    # === 安全并流算法：保持默认基础流媒体分流绝对不受侵扰 ===
    local base_domains=("netflix.com" "chatgpt.com" "openai.com" "ip.sb")
    local domain_array=()
    for bd in "${base_domains[@]}"; do
        domain_array+=("\"$bd\"")
    done

    # 安全清洗并合并追加域名，执行去重校验
    if [[ -n "$extra_domains" ]]; then
        local clean_extras
        clean_extras=$(echo "$extra_domains" | tr ',' ' ' | tr -d '"' | tr -d "'")
        if [[ -n "$clean_extras" ]]; then
            for d in $clean_extras; do
                d=$(echo "$d" | xargs || true)
                if [[ -n "$d" ]]; then
                    local is_duplicate=false
                    for bd in "${base_domains[@]}"; do
                        if [[ "$d" == "$bd" ]]; then
                            is_duplicate=true
                            break
                        fi
                    done
                    if [ "$is_duplicate" = "false" ]; then
                        domain_array+=("\"$d\"")
                    fi
                fi
            done
        fi
    fi

    local domains
    domains=$(printf ",%s" "${domain_array[@]}")
    domains=${domains:1}

    # 【深度修复】：坚决回归官方标准的 "listen_port" 字段，保障全版本 Sing-box 架构兼容
    cat > "${ETC_DIR}/singbox.json" <<EOF
{
  "inbounds": [
    {
      "type": "socks",
      "listen": "127.0.0.1",
      "listen_port": ${sb_port}
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "wireguard",
      "tag": "warp",
      "server": "${endpoint}",
      "server_port": 2408,
      "local_address": ${local_addr},
      "private_key": "${pvk}",
      "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
      "reserved": ${res},
      "mtu": 1420
    }
  ],
  "route": { 
    "rules": [
      {
        "domain": [ ${domains} ],
        "outbound": "warp"
      }
    ]
  }
}
EOF
    chown -R root:"$SERVICE_USER" "$ETC_DIR"
    chmod 640 "${ETC_DIR}/"*

    # 执行 Sing-box 语法校验哨兵机制
    say "正在进行配置文件语法哨兵级检测..."
    local check_output
    if ! check_output=$("${BIN_DIR}/singbox" check -c "${ETC_DIR}/singbox.json" 2>&1); then
        say "\033[0;31m配置文件语法校验失败，原始错误反馈如下：\033[0m"
        echo "$check_output"
        err "Sing-box 语法检测未通过 (防护拦截：JSON Schema 校验不适配)。安装终止。"
    fi
    ok "语法检测通过。JSON 配置结构安全。"
}

# --- 5. Systemd 级联链路 ---
write_units() {
    say "部署 Systemd 级联链路..."

    # 1. Singbox
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

    # 2. xtunnel
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

    # 3. cloudflared
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

# --- 6. 端口 Socket 检测与强时序串行拉起 ---
wait_for_local_port() {
    local port=$1
    local name=$2
    local max_wait=15
    local wait_time=0
    while ! ss -lnt 2>/dev/null | grep -E -q "(^|:)${port}(\s|$)"; do
        if [ $wait_time -ge $max_wait ]; then
            err "本地套接字端口 ${port} (${name}) 绑定超时，组件启动可能异常。"
        fi
        sleep 1
        wait_time=$((wait_time + 1))
    done
    ok "本地套接字端口 ${port} (${name}) 绑定就绪。"
}

start_all() {
    say "正在激活隧道链路..."
    systemctl daemon-reload
    systemctl enable "$SB_SERVICE" "$XT_SERVICE" "$CF_SERVICE" >/dev/null 2>&1

    local ws_port sb_port metrics_port
    if [ -f "${ETC_DIR}/env" ]; then
        while IFS='=' read -r key value; do
            if [[ "$key" =~ ^[A-Z0-9_]+$ ]]; then
                eval "$key=\"$value\""
            fi
        done < "${ETC_DIR}/env"
        ws_port="$WS_PORT"
        sb_port="$SB_PORT"
        metrics_port="$METRICS_PORT"
    fi
    ws_port=${ws_port:-56908}
    sb_port=${sb_port:-40001}

    # 强时序串行拉起控制
    say "正在拉起基础路由层 (Sing-box)..."
    systemctl start "$SB_SERVICE" || err "无法拉起 Sing-box 基础服务"
    wait_for_local_port "$sb_port" "Sing-box SOCKS5"

    say "正在拉起隧道核心桥接层 (xtunnel)..."
    systemctl start "$XT_SERVICE" || err "无法拉起 xtunnel 传输服务"
    wait_for_local_port "$ws_port" "xtunnel WebSocket"

    say "正在拉起公网出口层 (cloudflared)..."
    systemctl start "$CF_SERVICE" || err "无法拉起 cloudflared 出口服务"
    
    say "正在检测链路整体就绪状态..."
    sleep 5
    
    if ! systemctl is-active --quiet "$CF_SERVICE"; then
        say "\033[0;31m检测到链路物理终端异常，正在提取故障日志...\033[0m"
        journalctl -u "$SB_SERVICE" -u "$XT_SERVICE" -u "$CF_SERVICE" --no-pager -n 20
        err "链路激活失败。"
    fi

    ok "隧道链路已全面就绪。"
    
    if [[ -n "$metrics_port" ]]; then
        local metrics_data domain
        metrics_data=$(curl -s --connect-timeout 2 "http://127.0.0.1:${metrics_port}/metrics" 2>/dev/null || true)
        domain=$(echo "$metrics_data" | grep 'userHostname=' | sed -E 's/.*userHostname="https?:\/\/([^"]+)".*/\1/' | head -n1 || true)
        if [[ -n "$domain" ]]; then
            say "连接地址: https://$domain"
        else
            say "固定域名模式运行中，请检查 CF Dashboard。"
        fi
    fi
}

# --- 7. 交互功能业务块 ---
run_install_interactive() {
    require_root
    install_deps
    get_warp_profile
    create_env
    
    # 交互引导
    local token ws_port cf_token extra_domains
    read -p "1. Token (连接密码): " token
    [[ -z "$token" ]] && err "Token 不能为空"
    read -p "2. 本地监听端口 (默认 56908): " ws_port; ws_port=${ws_port:-56908}
    read -p "3. CF Tunnel Token (留空用临时域名): " cf_token
    read -p "4. 追加分流域名 (用逗号隔开，不改变默认分流): " extra_domains

    TOKEN="$token"
    WS_PORT="$ws_port"
    CF_TOKEN="$cf_token"
    EXTRA_DOMAINS="$extra_domains"

    write_configs
    write_units
    start_all
}

stop_services_menu() {
    say "正在关停服务..."
    systemctl stop "$CF_SERVICE" "$XT_SERVICE" "$SB_SERVICE" >/dev/null 2>&1 || true
    kill_process_native
    ok "服务已成功停止。"
}

view_logs_menu() {
    say "正在实时加载日志，按 Ctrl+C 退出..."
    journalctl -u "$SB_SERVICE" -u "$XT_SERVICE" -u "$CF_SERVICE" -f
}

uninstall_menu() {
    require_root
    say "正在卸载环境..."
    systemctl disable --now "$CF_SERVICE" "$XT_SERVICE" "$SB_SERVICE" || true
    rm -f /etc/systemd/system/nmu-*.service
    systemctl daemon-reload
    rm -rf "$ETC_DIR" "$LIB_DIR" "$LOG_DIR"
    userdel -r "$SERVICE_USER" || true
    ok "服务已彻底卸载，相关物理文件已全部清理。"
}

# --- 8. 经典交互式 TTY 菜单 ---
menu() {
    clear
    say "=================================================="
    say "         NMU-Tunnel 最终加固导航版 (V12.7)         "
    say "=================================================="
    echo "  1. 启动并安装服务"
    echo "  2. 停止服务"
    echo "  3. 实时查看日志"
    echo "  4. 完全物理卸载"
    echo "  0. 退出"
    say "=================================================="
    local choice
    read -p "选择操作 [0-4]: " choice
    case "${choice:-1}" in
        1) run_install_interactive ;;
        2) stop_services_menu ;;
        3) view_logs_menu ;;
        4) uninstall_menu ;;
        *) exit 0 ;;
    esac
}

# --- 运行入口 (自动识别无参数会话和有参数自动化流水线) ---
if [[ $# -eq 0 ]]; then
    menu
else
    case "${1}" in
        install)
            require_root
            install_deps
            get_warp_profile
            create_env
            write_configs
            write_units
            start_all
            ;;
        stop)
            systemctl stop "$CF_SERVICE" "$XT_SERVICE" "$SB_SERVICE"
            ok "服务已安全关闭。"
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
            ok "环境已彻底物理解理。"
            ;;
        *)
            echo "用法: $0 {install|stop|logs|uninstall} 或无参数运行进入经典交互菜单"
            ;;
    esac
fi
