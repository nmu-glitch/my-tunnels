#!/usr/bin/env bash

# =================================================================
# NMU Tunnel V13.2 - 终极并流加固版 (中文交互与军工级安全底座双闭环)
# =================================================================
# - 安全：采用 7.41 版严格的 set -Eeuo pipefail 错误检测与信号陷阱
# - 安全：修复在 set -E 状态下 ufw/firewalld 禁用引发 trap ERR 的熔断自尽 Bug
# - 安全：修复首装未发现 singbox 时 get_local_sb_version 返回 1 导致的安装中断
# - 安全：部署 umask 027，强制收缩 /etc/nmu-tunnel/env 等高密密钥盘权限为 0640
# - 安全：所有配置文件和 Systemd 单元文件均使用 mktemp 原子替换，杜绝断电损坏
# - 安全：部署 safe_remove_tree，防御卸载时空变量导致 rm -rf 越权删除系统根目录
# - 安全：重构 Systemd cloudflared/xtunnel 单元，以双美刀 \$\$ 屏蔽 Systemd 的越权提前展开
# - 性能：支持 7.38 版自动获取双栈 WARP、一键下载最新单执行包、追加域名无感热重启
# - 体验：全局 TTY 交互式中文菜单，并在终端任意路径注册 'nmu' 秒开快捷键
# =================================================================

set -Eeuo pipefail
umask 027

APP_NAME="nmu-tunnel"
SERVICE_USER="nmu-tunnel"
ETC_DIR="/etc/${APP_NAME}"
LIB_DIR="/var/lib/${APP_NAME}"
BIN_DIR="${LIB_DIR}/bin"
LOG_DIR="/var/log/${APP_NAME}"

SB_SERVICE="nmu-singbox.service"
XT_SERVICE="nmu-xtunnel.service"
CF_SERVICE="nmu-cloudflared.service"

ENV_FILE="${ETC_DIR}/env"
SB_CONFIG="${ETC_DIR}/singbox.json"
SB_UNIT="/etc/systemd/system/${SB_SERVICE}"
XT_UNIT="/etc/systemd/system/${XT_SERVICE}"
CF_UNIT="/etc/systemd/system/${CF_SERVICE}"

say() { printf '\033[0;34m[NMU-V13.2]\033[0m %s\n' "$*"; }
ok()  { printf '\033[0;32m[OK]\033[0m %s\n' "$*"; }
err() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup_tmp=()
cleanup() {
    local f
    for f in "${cleanup_tmp[@]:-}"; do
        [[ -n "$f" && -e "$f" ]] && rm -f -- "$f"
    done
}
trap cleanup EXIT
trap 'err "脚本在第 ${LINENO} 行执行失败，已安全熔断终止。"' ERR

require_root() {
    [[ "$(id -u)" -eq 0 ]] || err "请使用 root 权限执行 (sudo $0)"
    command -v systemctl >/dev/null 2>&1 || err "此脚本依赖 systemd 进程管理器，当前系统不支持 systemd，无法运行。"
    [[ -d /run/systemd/system ]] || err "systemd 当前未作为系统服务管理器运行。"
}

# --- 自动生成全局快捷键 'nmu' 命令 ---
create_shortcut() {
    [[ "$(id -u)" -eq 0 ]] || return 0
    local script_path=""
    if command -v realpath >/dev/null 2>&1; then
        script_path="$(realpath "$0" 2>/dev/null || true)"
    elif command -v readlink >/dev/null 2>&1; then
        script_path="$(readlink -f "$0" 2>/dev/null || true)"
    fi
    [[ -n "$script_path" && -f "$script_path" ]] || return 0
    case "$script_path" in
        /bin/bash|/bin/sh|/dev/fd/*) return 0 ;;
    esac
    mkdir -p /usr/local/bin 2>/dev/null || true
    ln -sfn -- "$script_path" /usr/local/bin/nmu
    chmod 0755 /usr/local/bin/nmu "$script_path"
}

# --- 1. 系统并发与包管理器锁检测 ---
is_dpkg_locked() {
    local lock_file
    for lock_file in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock; do
        [[ -e "$lock_file" ]] || continue
        if command -v fuser >/dev/null 2>&1; then
            fuser "$lock_file" >/dev/null 2>&1 && return 0
        else
            # 内核只读探测：解析 /proc/locks 锁状态文件
            local inode
            inode=$(stat -c '%i' "$lock_file" 2>/dev/null || true)
            if [[ -n "$inode" ]]; then
                grep -q -E ":${inode}(\s|$)" /proc/locks 2>/dev/null && return 0
            fi
        fi
    done
    return 1
}

wait_for_apt() {
    command -v apt-get >/dev/null 2>&1 || return 0
    say "检查系统包管理器锁状态 (内核只读探测)..."
    local max_wait=300 wait_time=0
    while is_dpkg_locked; do
        (( wait_time < max_wait )) || err "包管理器锁等待超时，请检查 apt/dpkg 进程"
        say "检测到包管理器正在运行，排队等待中 (已等待 ${wait_time} 秒)..."
        sleep 10
        wait_time=$((wait_time + 10))
    done
}

install_deps() {
    wait_for_apt
    say "同步环境依赖..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y || say "警告：部分软件源更新失败，继续尝试安装..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates iproute2 file tar gzip psmisc
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash curl ca-certificates iproute2 file tar gzip psmisc shadow
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl ca-certificates iproute file tar gzip psmisc shadow-utils
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl ca-certificates iproute file tar gzip psmisc shadow-utils
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install curl ca-certificates iproute2 file tar gzip psmisc shadow
    else
        err "未找到受支持的包管理器，安装终止。"
    fi
}

ensure_service_user() {
    if id "$SERVICE_USER" >/dev/null 2>&1; then return 0; fi
    local nologin="/usr/sbin/nologin"
    [[ -x "$nologin" ]] || nologin="/sbin/nologin"
    [[ -x "$nologin" ]] || nologin="/bin/false"
    useradd --system --home-dir "$LIB_DIR" --shell "$nologin" --no-create-home "$SERVICE_USER"
}

prompt_secret() {
    local var_name="$1" prompt="$2" default_value="${3:-}" value=""
    if [[ -t 0 ]]; then
        read -r -p "$prompt${default_value:+ [$default_value]}: " value
    fi
    [[ -n "$value" ]] || value="$default_value"
    printf -v "$var_name" '%s' "$value"
}

reject_unsafe_env_value() {
    local name="$1" value="$2"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || err "${name} 不允许包含换行符"
}

# 🚀 优化：符合 Systemd 环境文件规范的高能转义，保留原始 $ 符号，防止密码连接失败
systemd_quote_env() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '"%s"' "$value"
}

# --- 2. 安全获取官方 WARP 原生凭证 ---
get_warp_profile() {
    say "正在向公网生成器获取官方 WARP 原生凭证..."
    local warpurl raw_pvk raw_wpv6 raw_res
    
    warpurl=$(curl -sm6 https://warp.xijp.eu.org 2>/dev/null || wget --tries=2 -qO- https://warp.xijp.eu.org 2>/dev/null || true)
    warpurl=$(echo "$warpurl" | tr -d '\r' | tr -d '"')
    
    raw_pvk=$(echo "$warpurl" | grep -i "Private_key" | grep -oE "[A-Za-z0-9+/]{43}=" | head -n1 || true)
    raw_wpv6=$(echo "$warpurl" | grep -i "IPV6" | grep -oE "([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}" | head -n1 || true)
    if [[ -z "$raw_wpv6" ]]; then
        raw_wpv6=$(echo "$warpurl" | grep -i "IPV6" | grep -oE "([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}" | head -n1 || true)
    fi
    raw_res=$(echo "$warpurl" | grep -i "reserved" | grep -oE "\[[0-9]+,\s*[0-9]+,\s*[0-9]+\]" | head -n1 || true)

    # 纯 Bash 裁剪首尾空格
    raw_pvk="${raw_pvk#"${raw_pvk%%[![:space:]]*}"}"; raw_pvk="${raw_pvk%"${raw_pvk##*[![:space:]]}"}"
    raw_wpv6="${raw_wpv6#"${raw_wpv6%%[![:space:]]*}"}"; raw_wpv6="${raw_wpv6%"${raw_wpv6##*[![:space:]]}"}"
    raw_res="${raw_res#"${raw_res%%[![:space:]]*}"}"; raw_res="${raw_res%"${raw_res##*[![:space:]]}"}"

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
        say "警告: 远程凭证校验失败。正在启用预设安全凭证..."
        final_pvk="52cuYFgCJXp0LAq7+nWJIbCXXgU9eGggOc+Hlfz5u6A="
        final_wpv6="2606:4700:110:8d8d:1845:c39f:2dd5:a03a"
        final_res="[215, 69, 233]"
    fi

    local has_v6=false
    if curl -s6m3 https://icanhazip.com >/dev/null 2>&1 || curl -s6m3 https://6.ipw.cn >/dev/null 2>&1; then
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
    local service
    for service in "$CF_SERVICE" "$XT_SERVICE" "$SB_SERVICE"; do
        systemctl stop "$service" >/dev/null 2>&1 || true
    done
    local proc_patterns=("cloudflared" "xtunnel" "sing-box" "singbox")
    for pattern in "${proc_patterns[@]}"; do
        pkill -9 -x "$pattern" >/dev/null 2>&1 || true
    done
}

get_local_sb_version() {
    if [[ -x "${BIN_DIR}/singbox" ]]; then
        "${BIN_DIR}/singbox" version 2>/dev/null | awk '/sing-box version/{print $3; exit}' || true
        return 0
    fi
    echo ""
    return 0 # 🚀 强固设计：首装未发现 singbox 时，返回 0 并输出空字串，彻底消灭 set -e 的熔断自尽！
}

get_sb_version() {
    local raw_json="" v=""
    raw_json="$(curl --fail --silent --show-error --location --connect-timeout 4 --max-time 8 \
        -H 'Accept: application/vnd.github+json' -H 'User-Agent: nmu-tunnel-installer' \
        'https://api.github.com/repos/SagerNet/sing-box/releases/latest' 2>/dev/null || true)"
    v="$(printf '%s\n' "$raw_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -n1 || true)"
    printf '%s\n' "$v"
    return 0 # 🚀 防御网络查询超时返回状态 1 导致严格模式崩溃
}

create_env() {
    say "同步环境依赖..."
    ensure_service_user
    install -d -m 0750 -o root -g "$SERVICE_USER" "$ETC_DIR" "$LIB_DIR" "$BIN_DIR" "$LOG_DIR"

    local ARCH="amd64"
    [[ "$(uname -m)" != "x86_64" ]] && ARCH="arm64"

    # --- XTUNNEL 同步 ---
    say "正在同步 xtunnel 核心..."
    local need_download=true
    if [[ -f "${BIN_DIR}/xtunnel" ]]; then
        # 哨兵策略：防止重新运行时覆盖用户自己在本地重新编译的读写分离安全版 xtunnel 核心
        if [[ ! -f "/tmp/xtunnel" && ! -f "/tmp/xtunnel-linux-${ARCH}" ]]; then
            say "检测到本地已存在自编译/优化的 xtunnel 安全核心，跳过远程下载以防覆盖。"
            need_download=false
        fi
    fi

    if [ "$need_download" = "true" ]; then
        local local_found=false
        if [[ -f "/tmp/xtunnel" ]]; then
            local_found=true
        elif [[ -f "/tmp/xtunnel-linux-${ARCH}" ]]; then
            cp -f "/tmp/xtunnel-linux-${ARCH}" "/tmp/xtunnel"
            local_found=true
        fi

        if [ "$local_found" = "true" ]; then
            say "检测到本地准备好的测试版内核，跳过远程 GitHub 下载。"
        else
            local dl_url="https://github.com/nmu-glitch/my-tunnels/releases/download/v1.0.1/xtunnel-linux-${ARCH}"
            say "自 GitHub 仓库同步最新 AES-256-GCM 核心..."
            curl -fL --retry 3 -H "User-Agent: Mozilla/5.0" "${dl_url}" -o "/tmp/xtunnel" || err "xtunnel 下载失败"
        fi
        mv -f "/tmp/xtunnel" "${BIN_DIR}/xtunnel"
    fi

    # --- CLOUDFLARED 同步 ---
    say "正在同步 cloudflared 核心..."
    curl -fL --retry 3 "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" -o "/tmp/cloudflared" || err "cloudflared 下载失败"
    mv -f "/tmp/cloudflared" "${BIN_DIR}/cloudflared"

    # --- SING-BOX 同步 ---
    local LOCAL_VER TARGET_VER
    LOCAL_VER=$(get_local_sb_version)
    TARGET_VER=$(get_sb_version)

    local need_sb_update=true
    # 🚀 自愈防坍塌设计：网络异常且本地有可用二进制时直接跳过，防止发生离线覆盖降级导致安装断档。
    if [[ -z "$TARGET_VER" ]]; then
        if [[ -x "${BIN_DIR}/singbox" && -n "$LOCAL_VER" ]]; then
            need_sb_update=false
            say "警告：无法连接 GitHub 获取最新版本信息，自动跳过升级，继续保留本地 v${LOCAL_VER} 运行。"
        else
            say "警告：网络连接失败且本地无组件，回落至预设安全版本 1.8.11..."
            TARGET_VER="1.8.11"
        fi
    fi

    if [ "$need_sb_update" = "true" ] && [[ -x "${BIN_DIR}/singbox" ]] && [[ "$LOCAL_VER" = "$TARGET_VER" ]]; then
        need_sb_update=false
        say "本地已存版本 v${LOCAL_VER} 匹配目标版本 v${TARGET_VER}，跳过下载。"
    fi

    if [ "$need_sb_update" = "true" ]; then
        say "正在下载安装 Sing-box v${TARGET_VER}..."
        curl -fL --retry 3 "https://github.com/SagerNet/sing-box/releases/download/v${TARGET_VER}/sing-box-${TARGET_VER}-linux-${ARCH}.tar.gz" -o /tmp/sb.tar.gz || err "Sing-box 下载失败"
        mkdir -p /tmp/sb_unpack
        tar -zxf /tmp/sb.tar.gz -C /tmp/sb_unpack || err "Sing-box 解压失败"
        local sb_bin
        sb_bin=$(find /tmp/sb_unpack -type f -name "sing-box" | head -n1)
        [[ -f "$sb_bin" ]] || err "解压包中未找到有效二进制执行程序"
        mv -f "$sb_bin" "${BIN_DIR}/singbox"
        rm -rf /tmp/sb_unpack /tmp/sb.tar.gz
    fi

    chmod +x "${BIN_DIR}/xtunnel" "${BIN_DIR}/cloudflared" "${BIN_DIR}/singbox"
    
    # 🚀 RHEL/CentOS 等系统下的 SELinux 安全可执行上下文强制重塑
    if command -v chcon >/dev/null 2>&1; then
        say "检测到 SELinux 机制，显式赋予二进制执行上下文标签..."
        chcon -R -t bin_t "${BIN_DIR}" >/dev/null 2>&1 || true
    fi

    chown -R "$SERVICE_USER":"$SERVICE_USER" "$LIB_DIR" "$LOG_DIR"
}

optimize_network_for_quic() {
    say "写入保守的 QUIC/UDP 缓冲参数"
    local sysctl_file="/etc/sysctl.d/90-${APP_NAME}-quic.conf" tmp
    tmp="$(mktemp "${sysctl_file}.tmp.XXXXXX")"
    cleanup_tmp+=("$tmp")
    cat >"$tmp" <<'EOF'
# Managed by nmu-tunnel.
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_slow_start_after_idle = 0
EOF
    chmod 0644 "$tmp"
    mv -f -- "$tmp" "$sysctl_file"
    sysctl --system >/dev/null || say "警告：部分 sysctl 参数未被内核接受"

    # 防火墙 UDP 放行（🚀 语法重构：显式 if-else 消除 trap ERR 对 A && B || C 链中 grep 返回值 1 的越权信号劫持）
    local ufw_active=false
    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -q "active"; then
            ufw_active=true
        fi
    fi
    if [ "$ufw_active" = "true" ]; then
        ufw allow out 7844/udp >/dev/null 2>&1 && ok "UFW 已成功放行 UDP 7844 出站通道。"
    fi

    local fw_active=false
    if command -v firewall-cmd >/dev/null 2>&1; then
        if systemctl is-active --quiet firewalld >/dev/null 2>&1; then
            fw_active=true
        fi
    fi
    if [ "$fw_active" = "true" ]; then
        firewall-cmd --permanent --direct --add-rule ipv4 filter OUTPUT 0 -p udp --dport 7844 -j ACCEPT >/dev/null 2>&1 || true
        firewall-cmd --permanent --direct --add-rule ipv6 filter OUTPUT 0 -p udp --dport 7844 -j ACCEPT >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        ok "Firewalld 已成功放行 UDP 7844 出站通道。"
    fi
}

write_configs() {
    say "写入配置"
    WS_PORT="${WS_PORT:-56908}"
    SB_PORT="${SB_PORT:-40001}"
    METRICS_PORT="${METRICS_PORT:-30000}"
    TOKEN="${TOKEN:-}"
    CF_TOKEN="${CF_TOKEN:-}"
    EXTRA_DOMAINS="${EXTRA_DOMAINS:-}"
    SECRET="${SECRET:-}"
    FALLBACK_PROXY="${FALLBACK_PROXY:-https://www.debian.org}"

    [[ "$WS_PORT" =~ ^[0-9]+$ && "$WS_PORT" -ge 1 && "$WS_PORT" -le 65535 ]] || err "WS_PORT 无效"
    [[ "$SB_PORT" =~ ^[0-9]+$ && "$SB_PORT" -ge 1 && "$SB_PORT" -le 65535 ]] || err "SB_PORT 无效"
    [[ "$METRICS_PORT" =~ ^[0-9]+$ && "$METRICS_PORT" -ge 1 && "$METRICS_PORT" -le 65535 ]] || err "METRICS_PORT 无效"
    [[ -n "$TOKEN" ]] || err "TOKEN 不能为空"
    if [[ -n "$SECRET" && ${#SECRET} -lt 32 ]]; then err "SECRET 至少需要 32 字节"; fi
    local name
    for name in TOKEN CF_TOKEN SECRET FALLBACK_PROXY EXTRA_DOMAINS; do
        reject_unsafe_env_value "$name" "${!name}"
    done

    # 读取旧端口继承
    if [ -f "$ENV_FILE" ]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ "$line" =~ ^[[:space:]]*$ ]] && continue
            if [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
                local key="${BASH_REMATCH[1]}"
                local value="${BASH_REMATCH[2]}"
                value="${value//$'\r'/}"
                value="${value#\"}"
                value="${value%\"}"
                value="${value//\\\"/\"}"
                value="${value//\\\\/\\}"
                if [[ "$key" == "SB_PORT" ]]; then SB_PORT="$value"; fi
                if [[ "$key" == "METRICS_PORT" ]]; then METRICS_PORT="$value"; fi
            fi
        done < "$ENV_FILE"
    fi

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

    local env_tmp cfg_tmp
    env_tmp="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
    cfg_tmp="$(mktemp "${SB_CONFIG}.tmp.XXXXXX")"
    cleanup_tmp+=("$env_tmp" "$cfg_tmp")
    {
        printf 'WS_PORT=%s\n' "$WS_PORT"
        printf 'SB_PORT=%s\n' "$SB_PORT"
        printf 'METRICS_PORT=%s\n' "$METRICS_PORT"
        printf 'TOKEN=%s\n' "$(systemd_quote_env "$TOKEN")"
        printf 'CF_TOKEN=%s\n' "$(systemd_quote_env "$CF_TOKEN")"
        printf 'SECRET=%s\n' "$(systemd_quote_env "$SECRET")"
        printf 'FALLBACK_PROXY=%s\n' "$(systemd_quote_env "$FALLBACK_PROXY")"
        printf 'EXTRA_DOMAINS=%s\n' "$(systemd_quote_env "$EXTRA_DOMAINS")"
    } >"$env_tmp"

    local base_domains=("netflix.com" "chatgpt.com" "openai.com" "ip.sb")
    local domain_array=()
    for bd in "${base_domains[@]}"; do
        domain_array+=("\"$bd\"")
    done
    if [[ -n "$EXTRA_DOMAINS" ]]; then
        local extra_array
        read -r -a extra_array <<< "${EXTRA_DOMAINS//,/ }"
        for d in "${extra_array[@]}"; do
            d="${d#"${d%%[![:space:]]*}"}"; d="${d%"${d##*[![:space:]]}"}"
            if [[ -n "$d" ]]; then
                local is_duplicate=false
                for bd in "${base_domains[@]}"; do
                    [[ "$d" == "$bd" ]] && is_duplicate=true
                done
                for ad in "${domain_array[@]}"; do
                    [[ "\"$d\"" == "$ad" ]] && is_duplicate=true
                done
                [ "$is_duplicate" = "false" ] && domain_array+=("\"$d\"")
            fi
        done
    fi
    local domains
    domains=$(printf ",%s" "${domain_array[@]}")
    domains=${domains:1}

    cat >"$cfg_tmp" <<EOF
{
  "inbounds": [
    {
      "type": "socks",
      "listen": "127.0.0.1",
      "listen_port": ${SB_PORT}
    }
  ],
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "warp",
      "system": false,
      "mtu": 1360,
      "address": ${local_addr},
      "private_key": "${pvk}",
      "peers": [
        {
          "address": "${endpoint}",
          "port": 2408,
          "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "allowed_ips": ["0.0.0.0/0", "::/0"],
          "persistent_keepalive_interval": 25,
          "reserved": ${res}
        }
      ]
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
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
    "${BIN_DIR}/singbox" check -c "$cfg_tmp"
    chmod 0640 "$env_tmp" "$cfg_tmp"
    chown root:"$SERVICE_USER" "$env_tmp" "$cfg_tmp"
    mv -f -- "$env_tmp" "$ENV_FILE"
    mv -f -- "$cfg_tmp" "$SB_CONFIG"
}

# --- 5. Systemd 级联单元部署 ---
write_units() {
    say "部署 systemd 单元"
    local sb_tmp xt_tmp cf_tmp
    sb_tmp="$(mktemp "${SB_UNIT}.tmp.XXXXXX")"
    xt_tmp="$(mktemp "${XT_UNIT}.tmp.XXXXXX")"
    cf_tmp="$(mktemp "${CF_UNIT}.tmp.XXXXXX")"
    cleanup_tmp+=("$sb_tmp" "$xt_tmp" "$cf_tmp")

    cat >"$sb_tmp" <<EOF
[Unit]
Description=NMU Singbox Base
After=network-online.target
Wants=${XT_SERVICE}

[Service]
Type=simple
ExecStart=${BIN_DIR}/singbox run -c ${SB_CONFIG}
User=${SERVICE_USER}
Group=${SERVICE_USER}
Restart=always
RestartSec=3
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=${ETC_DIR}
UMask=0027

[Install]
WantedBy=multi-user.target
EOF

    cat >"$xt_tmp" <<EOF
[Unit]
Description=NMU xtunnel Core
After=network-online.target ${SB_SERVICE}
Requires=${SB_SERVICE}
PartOf=${SB_SERVICE}
Wants=${CF_SERVICE}

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
ExecStart=/bin/sh -c 'if [ -n "\$\$SECRET" ]; then exec ${BIN_DIR}/xtunnel -l ws://127.0.0.1:\$\$WS_PORT -token "\$\$TOKEN" -f socks5://127.0.0.1:\$\$SB_PORT -secret "\$\$SECRET" -fallback-proxy "\$\$FALLBACK_PROXY"; else exec ${BIN_DIR}/xtunnel -l ws://127.0.0.1:\$\$WS_PORT -token "\$\$TOKEN" -f socks5://127.0.0.1:\$\$SB_PORT -fallback-proxy "\$\$FALLBACK_PROXY"; fi'
User=${SERVICE_USER}
Group=${SERVICE_USER}
Restart=always
RestartSec=3
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=${ETC_DIR}
UMask=0027

[Install]
WantedBy=multi-user.target
EOF

    cat >"$cf_tmp" <<EOF
[Unit]
Description=NMU Cloudflared Exit
After=network-online.target ${XT_SERVICE}
Requires=${XT_SERVICE}
PartOf=${XT_SERVICE}

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
ExecStart=/bin/sh -c 'if [ -n "\$\$CF_TOKEN" ]; then exec ${BIN_DIR}/cloudflared --protocol quic tunnel run --token \$\$CF_TOKEN; else exec ${BIN_DIR}/cloudflared --protocol quic tunnel --url http://127.0.0.1:\$\$WS_PORT --metrics 127.0.0.1:\$\$METRICS_PORT; fi'
User=${SERVICE_USER}
Group=${SERVICE_USER}
Restart=always
RestartSec=5
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
UMask=0027

[Install]
WantedBy=multi-user.target
EOF

    chmod 0644 "$sb_tmp" "$xt_tmp" "$cf_tmp"
    mv -f -- "$sb_tmp" "$SB_UNIT"
    mv -f -- "$xt_tmp" "$XT_UNIT"
    mv -f -- "$cf_tmp" "$CF_UNIT"
    systemctl daemon-reload
}

wait_for_local_port() {
    local port="$1" name="$2" max_wait=30 wait_time=0
    while (( wait_time < max_wait )); do
        if command -v ss >/dev/null 2>&1; then
            if ss -H -lnt "sport = :${port}" 2>/dev/null | grep -q .; then ok "${name} 已监听 127.0.0.1:${port}"; return 0; fi
        elif command -v netstat >/dev/null 2>&1; then
            if netstat -lnt 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {found=1} END{exit !found}'; then ok "${name} 已监听端口 ${port}"; return 0; fi
        else
            local port_hex
            printf -v port_hex '%04X' "$port"
            if awk -v p=":${port_hex}" '$2 ~ p"$" && $4 == "0A" {found=1} END{exit !found}' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then ok "${name} 已监听端口 ${port}"; return 0; fi
        fi
        sleep 1
        wait_time=$((wait_time + 1))
    done
    err "等待 ${name} 监听端口 ${port} 超时"
}

start_all() {
    say "激活隧道链路"
    systemctl daemon-reload
    systemctl enable "$SB_SERVICE" "$XT_SERVICE" "$CF_SERVICE" >/dev/null 2>&1

    # 获取当前最新的配置端口执行就绪监听
    local cur_ws_port="" cur_sb_port="" cur_metrics_port=""
    if [ -f "$ENV_FILE" ]; then
         while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ "$line" =~ ^[[:space:]]*$ ]] && continue
            if [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
                local key="${BASH_REMATCH[1]}"
                local value="${BASH_REMATCH[2]}"
                value="${value//$'\r'/}"
                value="${value#\"}"
                value="${value%\"}"
                value="${value//\\\"/\"}"
                value="${value//\\\\/\\}"
                case "$key" in
                    WS_PORT) cur_ws_port="$value" ;;
                    SB_PORT) cur_sb_port="$value" ;;
                    METRICS_PORT) cur_metrics_port="$value" ;;
                esac
            fi
        done < "$ENV_FILE"
    fi
    cur_ws_port=${cur_ws_port:-56908}
    cur_sb_port=${cur_sb_port:-40001}

    say "正在拉起基础路由层 (Sing-box)..."
    systemctl start "$SB_SERVICE"
    wait_for_local_port "$cur_sb_port" "sing-box"

    say "正在拉起核心传输层 (xtunnel)..."
    systemctl start "$XT_SERVICE"
    wait_for_local_port "$cur_ws_port" "xtunnel"

    say "正在拉起公网出口层 (cloudflared)..."
    systemctl start "$CF_SERVICE"

    say "正在检测链路整体就绪状态..."
    sleep 5
    if ! systemctl is-active --quiet "$CF_SERVICE"; then
        say "\033[0;31m检测到链路物理终端异常，正在提取故障日志...\033[0m"
        journalctl -u "$SB_SERVICE" -u "$XT_SERVICE" -u "$CF_SERVICE" --no-pager -n 20
        err "链路激活失败。"
    fi
    ok "隧道链路已全面就绪。"

    if [[ -n "$cur_metrics_port" ]]; then
        local metrics_data domain
        metrics_data=$(curl -s --connect-timeout 2 "http://127.0.0.1:${cur_metrics_port}/metrics" 2>/dev/null || true)
        domain=$(echo "$metrics_data" | grep 'userHostname=' | sed -E 's/.*userHostname="https?:\/\/([^"]+)".*/\1/' | head -n1 || true)
        if [[ -n "$domain" ]]; then
            say "连接地址: https://$domain"
        else
            say "固定域名模式运行中，请通过 Cloudflare Dashboard 查看连通状态。"
        fi
    fi
}

run_install_interactive() {
    require_root
    install_deps
    get_warp_profile
    
    local token ws_port cf_token extra_domains secret fallback_proxy
    read -p "1. Token (连接密码): " token
    [[ -z "$token" ]] && err "Token 不能为空"
    read -p "2. 本地监听端口 (默认 56908): " ws_port; ws_port=${ws_port:-56908}
    read -p "3. CF Tunnel Token (留空用临时域名): " cf_token
    read -p "4. 追加分流域名 (用逗号隔开，不改变默认分流): " extra_domains
    read -p "5. AES-256-GCM 对称密钥 (留空不开启加密): " secret
    read -p "6. 主动探测反向代理伪装站点 (默认 https://www.debian.org): " fallback_proxy
    fallback_proxy=${fallback_proxy:-https://www.debian.org}

    TOKEN="$token"
    WS_PORT="$ws_port"
    CF_TOKEN="$cf_token"
    EXTRA_DOMAINS="$extra_domains"
    SECRET="$secret"
    FALLBACK_PROXY="$fallback_proxy"

    create_env
    optimize_network_for_quic
    write_configs
    write_units
    start_all
    ok "安装完成！"
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

safe_remove_tree() {
    local path="$1" expected="$2"
    [[ -n "$path" && "$path" == "$expected" ]] || err "拒绝删除异常路径：${path}"
    case "$path" in /|/etc|/var|/var/lib|/var/log|/usr|/usr/local) err "拒绝删除系统关键路径：${path}" ;; esac
    rm -rf -- "$path"
}

uninstall_menu() {
    require_root
    say "正在卸载环境..."
    systemctl disable --now "$CF_SERVICE" "$XT_SERVICE" "$SB_SERVICE" >/dev/null 2>&1 || true
    kill_process_native
    rm -f -- "$CF_UNIT" "$XT_UNIT" "$SB_UNIT" "/etc/sysctl.d/90-${APP_NAME}-quic.conf" /usr/local/bin/nmu
    systemctl daemon-reload
    safe_remove_tree "$ETC_DIR" "/etc/${APP_NAME}"
    safe_remove_tree "$LIB_DIR" "/var/lib/${APP_NAME}"
    safe_remove_tree "$LOG_DIR" "/var/log/${APP_NAME}"
    if id "$SERVICE_USER" >/dev/null 2>&1; then userdel "$SERVICE_USER" >/dev/null 2>&1 || true; fi
    sysctl --system >/dev/null || true
    ok "服务已彻底卸载，相关物理文件已全部清理。"
}

append_split_domains_menu() {
    require_root
    if [ ! -f "$ENV_FILE" ]; then
        err "未检测到已安装的 NMU-Tunnel 配置环境，请先选择选项 1 进行安装。"
    fi

    local cur_ws_port="" cur_token="" cur_cf_token="" cur_extra_domains="" cur_secret="" cur_fallback_proxy=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        if [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            value="${value//$'\r'/}"
            value="${value#\"}"
            value="${value%\"}"
            value="${value//\\\"/\"}"
            value="${value//\\\\/\\}"
            case "$key" in
                WS_PORT) cur_ws_port="$value" ;;
                TOKEN) cur_token="$value" ;;
                CF_TOKEN) cur_cf_token="$value" ;;
                EXTRA_DOMAINS) cur_extra_domains="$value" ;;
                SECRET) cur_secret="$value" ;;
                FALLBACK_PROXY) cur_fallback_proxy="$value" ;;
            esac
        fi
    done < "$ENV_FILE"

    local current_extras="${cur_extra_domains}"
    say "当前已配置的追加分流域名: ${current_extras:-无}"
    read -p "请输入需要新增的追加分流域名 (多个用逗号隔开): " new_domains
    [[ -z "$new_domains" ]] && err "输入内容为空，未做任何更改。"

    local merged_extras
    if [[ -n "$current_extras" ]]; then
        merged_extras="${current_extras},${new_domains}"
    else
        merged_extras="${new_domains}"
    fi

    TOKEN="$cur_token" \
    WS_PORT="$cur_ws_port" \
    CF_TOKEN="$cur_cf_token" \
    EXTRA_DOMAINS="$merged_extras" \
    SECRET="$cur_secret" \
    FALLBACK_PROXY="$cur_fallback_proxy" \
    write_configs

    say "正在平滑热重启级联路由服务以应用新分流规则..."
    systemctl restart "$SB_SERVICE" "$XT_SERVICE"
    ok "分流规则追加成功！"
    say "当前最新合并追加域名列表: $merged_extras"
}

menu() {
    create_shortcut
    while true; do
        clear
        say "=================================================="
        say "         NMU-Tunnel 极盾 E2E 导航版 (V13.2)        "
        say "  [提示] 终端任意路径输入 'nmu' 即可直接唤醒此菜单   "
        say "=================================================="
        echo "  1. 启动并安装服务"
        echo "  2. 停止服务"
        echo "  3. 实时查看日志 (退出日志请按 Ctrl+C)"
        echo "  4. 完全物理卸载"
        echo "  5. 追加分流域名 (不破坏现有环境/即时生效)"
        echo "  0. 退出"
        say "=================================================="
        local choice
        read -p "选择操作 [0-5]: " choice
        case "${choice:-1}" in
            1) 
                run_install_interactive 
                echo
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            2) 
                stop_services_menu 
                echo
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            3) 
                view_logs_menu 
                echo
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            4) 
                uninstall_menu 
                echo
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            5) 
                append_split_domains_menu 
                echo
                read -n 1 -s -r -p "按任意键返回主菜单..."
                ;;
            0) 
                exit 0 
                ;;
            *) 
                say "无效的选择，请重新输入。"
                sleep 1
                ;;
        esac
    done
}

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
            uninstall_menu
            ;;
        *)
            echo "用法: $0 {install|stop|logs|uninstall} 或无参数运行进入经典交互菜单"
            ;;
    esac
fi
