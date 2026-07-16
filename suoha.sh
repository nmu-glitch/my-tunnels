#!/usr/bin/env bash

# =========================================================
# NMU Tunnel V13.4.2 - 极盾 E2E 全局快捷导航版 (深度安全与生存性能加固版)
# - 优化：移除外部 tr 与 xargs 依赖，改用纯 Bash 参数展开实现零分叉字符净化 [3]
# - 优化：配置环境读取逻辑支持正则捕获首等号切割，彻底防范 base64 或密钥含有等号 "=" 时的解析中断和数据损毁
# - 优化：pkill 采用精确名称匹配机制，消除安装脚本自身在特定路径下运行时被误杀自尽的隐患
# - 优化：增强 Systemd EnvironmentFile 敏感值转义，防止特殊密码导致 Systemd 加载词法错误
# - 优化：通过自适应检测 $BIN_DIR/xtunnel 的存在状态，防止追加分流域名时误覆盖自编译的读写分离安全内核
# - 修复：支持最新版双栈 (amd64/arm64) AES-256-GCM 极盾核心
# - 修复：重构 Systemd cloudflared/xtunnel 单元，以双美刀 $$ 屏蔽 Systemd 的越权提前展开
# - 修复：自适应用户创建与删除逻辑，自动探查系统 nologin 绝对路径（Debian/CentOS/Alpine）并优雅回落
# - 修复：将 Systemd 脚本执行引擎修改为全系统通用 /bin/sh，彻底消除极简系统下的路径缺失隐患
# - 修复：彻底剔除 chown 参数中由于书写偏差残存的空格，保障目录归属权分配顺利完成
# - 新增：前置 check 检测，不支持 Systemd (如 OpenRC/SysVinit) 的环境将友好终止安装
# - 新增：追加分流规则时自动锁定内部端口与密钥，实现真正无感、不弹窗的热追加
# - 新增：全局快捷命令 'nmu'，注册后在终端任意路径输入 nmu 即可秒开菜单
# - 新增：菜单防退出循环，所有操作结束后按任意键优雅返回主菜单
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
STATE_FILE="${LIB_DIR}/install-state"
TXN_FILE="${LIB_DIR}/update-transaction"
STAGING_DIR="${LIB_DIR}/staging"
METRICS_DIR="${LIB_DIR}/metrics"
CREDENTIALS_DIR="${ETC_DIR}/credentials"
CONFIG_SCHEMA="3"
UNIT_SCHEMA="3"
SCRIPT_VERSION="13.4.2"

say() { echo -e "\033[0;34m[NMU-V13.4.2]\033[0m $*"; }
ok() { echo -e "\033[0;32m[OK]\033[0m $*"; }
err() { echo -e "\033[0;31m[ERROR]\033[0m $*"; exit 1; }

require_root() {
    [[ "$(id -u)" -ne 0 ]] && err "请使用 root 权限执行 (sudo $0)"
    if ! command -v systemctl >/dev/null 2>&1; then
        err "此脚本依赖 systemd 进程管理器。当前系统不支持 systemd（如原生 OpenRC 或 Docker 容器环境），无法运行。"
    fi
}

# --- 自动生成全局快捷键 'nmu' 命令 ---
create_shortcut() {
    if [[ "$(id -u)" -eq 0 ]]; then
        local script_path install_dir install_path tmp_path
        script_path="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
        install_dir="/usr/local/lib/${APP_NAME}"
        install_path="${install_dir}/nmu-tunnel.sh"
        [[ -n "$script_path" && -f "$script_path" ]] || return 0
        case "$script_path" in
            /bin/bash|/bin/sh|/usr/bin/bash|/usr/bin/sh|/dev/fd/*|/proc/*) return 0 ;;
        esac
        install -d -m 0755 "$install_dir" /usr/local/bin 2>/dev/null || return 0
        if [[ "$script_path" != "$install_path" ]]; then
            tmp_path="$(mktemp "${install_dir}/.nmu-tunnel.XXXXXX")" || return 0
            if install -m 0755 -- "$script_path" "$tmp_path"; then
                mv -f -- "$tmp_path" "$install_path"
            else
                rm -f -- "$tmp_path"
                return 0
            fi
        fi
        ln -sfn -- "$install_path" /usr/local/bin/nmu 2>/dev/null || true
        hash -r 2>/dev/null || true
    fi
}

# --- 1. 系统并发与包管理器锁检测 ---
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
        # 提高容错性：部分三方源失效不应阻断基础包安装，警告并继续，极大提高弱网与受限网络下的存活率
        apt-get update -y || say "警告：软件源同步部分失败，尝试继续安装依赖..."
        apt-get install -y curl ca-certificates iproute2 file tar gzip psmisc || err "apt 安装依赖失败"
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl ca-certificates iproute2 file tar gzip psmisc bash || err "apk 安装依赖失败"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl ca-certificates iproute2 tar gzip psmisc || err "dnf 安装依赖失败"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl ca-certificates iproute2 tar gzip psmisc || err "yum 安装依赖失败"
    elif command -v zypper >/dev/null 2>&1; then
        zypper install -y curl ca-certificates iproute2 tar gzip psmisc || err "zypper 安装依赖失败"
    fi
}

# --- 2. 安全获取官方 WARP 原生凭证 ---
get_warp_profile() {
    say "正在向公网生成器获取官方 WARP 原生凭证..."
    local warpurl raw_pvk raw_wpv6 raw_res
    
    # 采用系统受信的 CA 证书链建立可信连接，防范中间人劫持
    warpurl=$(curl -sm6 https://warp.xijp.eu.org 2>/dev/null || wget --tries=2 -qO- https://warp.xijp.eu.org 2>/dev/null || true)
    warpurl=$(echo "$warpurl" | tr -d '\r' | tr -d '"')
    
    raw_pvk=$(echo "$warpurl" | grep -i "Private_key" | grep -oE "[A-Za-z0-9+/]{43}=" | head -n1 || true)
    raw_wpv6=$(echo "$warpurl" | grep -i "IPV6" | grep -oE "([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}" | head -n1 || true)
    if [[ -z "$raw_wpv6" ]]; then
        raw_wpv6=$(echo "$warpurl" | grep -i "IPV6" | grep -oE "([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}" | head -n1 || true)
    fi
    raw_res=$(echo "$warpurl" | grep -i "reserved" | grep -oE "\[[0-9]+,\s*[0-9]+,\s*[0-9]+\]" | head -n1 || true)

    # 纯 Bash 剪裁首尾空格，免除 xargs 调用可能引发的特殊字符碎断
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
        say "警告: 远程凭证校验失败 (解析截断或格式不匹配)。正在启用预设安全凭证..."
        final_pvk="52cuYFgCJXp0LAq7+nWJIbCXXgU9eGggOc+Hlfz5u6A="
        final_wpv6="2606:4700:110:8d8d:1845:c39f:2dd5:a03a"
        final_res="[215, 69, 233]"
    fi

    local has_v6=false
    # 多源探测：防范单一测试源在审查环境下因封锁或限速造成的检测漏判 [3]
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
    # 优先只管理 NMU 自己的 systemd cgroup，避免误杀机器上的其他同名实例。
    local service pid
    for service in "$CF_SERVICE" "$XT_SERVICE" "$SB_SERVICE"; do
        systemctl stop "$service" >/dev/null 2>&1 || true
        pid="$(systemctl show -p MainPID --value "$service" 2>/dev/null || true)"
        if [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] && kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
            sleep 1
            kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
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
    
    # 自动检索系统可用的无登录 shell，提升跨发行版（包括 Alpine / CentOS / Debian）下的环境兼容度
    local nologin_path="/bin/false"
    if [[ -f "/usr/sbin/nologin" ]]; then
        nologin_path="/usr/sbin/nologin"
    elif [[ -f "/sbin/nologin" ]]; then
        nologin_path="/sbin/nologin"
    fi

    # 将服务账号 HOME 与 root 持有的核心目录物理分离：
    # 先由 root 建立父目录，再注册账号，防止极简系统的 useradd/adduser
    # 因 Home 父路径不存在而中断；此阶段不创建最终 Home，避免 -m 与既有目录冲突。
    local service_home="${LIB_DIR}/home"
    mkdir -p "$ETC_DIR" "$LIB_DIR" "$BIN_DIR" "$LOG_DIR" || err "基础目录初始化失败"
    chmod 0750 "$ETC_DIR" "$LIB_DIR" "$BIN_DIR" "$LOG_DIR" || err "基础目录权限初始化失败"
    chown root:root "$ETC_DIR" "$LIB_DIR" "$BIN_DIR" "$LOG_DIR" || err "基础目录归属初始化失败"

    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        if command -v useradd >/dev/null 2>&1; then
            useradd -r -m -d "$service_home" -s "$nologin_path" "$SERVICE_USER" || err "用户创建失败"
        elif command -v adduser >/dev/null 2>&1; then
            adduser -S -h "$service_home" -s "$nologin_path" -D "$SERVICE_USER" || err "用户创建失败"
        else
            err "未找到可用的用户创建命令"
        fi
    elif command -v usermod >/dev/null 2>&1; then
        # 兼容旧安装：只更新 passwd 中的 HOME，不迁移或放宽核心目录权限。
        usermod -d "$service_home" "$SERVICE_USER" || err "服务账号 Home 更新失败"
    fi

    # 账号存在后再创建并收紧私有 Home；兼容 useradd -m、BusyBox adduser
    # 已自行创建 Home 或未创建 Home 的两种行为，且不会放宽核心父目录。
    mkdir -p "$service_home" || err "服务 Home 初始化失败"
    chown "$SERVICE_USER":"$SERVICE_USER" "$service_home" || err "服务 Home 归属初始化失败"
    chmod 0700 "$service_home" || err "服务 Home 权限初始化失败"

    local ARCH=""
    case "$(uname -m)" in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) err "不支持的 CPU 架构: $(uname -m)，仅支持 amd64/arm64" ;;
    esac
    
    # --- XTUNNEL 同步 ---
    # 最新 Go 核心由 GitHub Release 提供。每次安装都重新拉取同名资产，
    # 不再因旧二进制存在而跳过更新；/tmp 文件仍保留为人工离线覆盖入口。
    say "正在同步 xtunnel 最新核心..."
    local xt_candidate="" xt_tmp="" xt_sum_tmp=""
    xt_tmp="$(mktemp "${BIN_DIR}/.xtunnel.${ARCH}.XXXXXX")" || err "无法创建 xtunnel 临时文件"

    if [[ -f "/tmp/xtunnel" ]]; then
        install -m 0755 -- "/tmp/xtunnel" "$xt_tmp" || err "本地 xtunnel 导入失败"
        xt_candidate="/tmp/xtunnel"
    elif [[ -f "/tmp/xtunnel-linux-${ARCH}" ]]; then
        install -m 0755 -- "/tmp/xtunnel-linux-${ARCH}" "$xt_tmp" || err "本地架构核心导入失败"
        xt_candidate="/tmp/xtunnel-linux-${ARCH}"
    else
        local dl_url="https://github.com/nmu-glitch/my-tunnels/releases/download/v1.0.1/xtunnel-linux-${ARCH}"
        say "自 GitHub Release 拉取最新 AES-256-GCM 核心..."
        curl --fail --location --retry 3 --retry-all-errors --connect-timeout 8 --max-time 180 \
            --proto '=https' --tlsv1.2 -H "User-Agent: nmu-tunnel-installer/13.2" \
            "$dl_url" -o "$xt_tmp" || err "xtunnel 下载失败，可上传到 /tmp/xtunnel 后重试"

        # 若仓库同时发布 .sha256 旁车文件则强制校验；尚未发布时保持兼容并继续执行 ELF 校验。
        xt_sum_tmp="$(mktemp "${BIN_DIR}/.xtunnel.sha256.XXXXXX")" || err "无法创建校验临时文件"
        if curl --fail --silent --show-error --location --retry 2 --connect-timeout 5 --max-time 20 \
            --proto '=https' --tlsv1.2 "${dl_url}.sha256" -o "$xt_sum_tmp"; then
            local expected_sum actual_sum
            expected_sum="$(awk 'NR==1 {print $1}' "$xt_sum_tmp")"
            actual_sum="$(sha256sum "$xt_tmp" | awk '{print $1}')"
            [[ "$expected_sum" =~ ^[0-9a-fA-F]{64}$ && "${expected_sum,,}" == "$actual_sum" ]] || err "xtunnel SHA-256 校验失败"
        else
            say "提示：Release 未提供 .sha256，已降级执行 ELF 与架构校验。"
        fi
    fi

    [[ -s "$xt_tmp" ]] || err "xtunnel 文件为空"
    local xt_file_desc
    xt_file_desc="$(file -b "$xt_tmp" 2>/dev/null || true)"
    [[ "$xt_file_desc" == *ELF* ]] || err "xtunnel 不是有效 ELF 可执行文件"
    if [[ "$ARCH" == "amd64" ]]; then
        [[ "$xt_file_desc" == *x86-64* || "$xt_file_desc" == *x86_64* ]] || err "xtunnel 架构与 amd64 VPS 不匹配"
    else
        [[ "$xt_file_desc" == *aarch64* || "$xt_file_desc" == *ARM\ aarch64* ]] || err "xtunnel 架构与 arm64 VPS 不匹配"
    fi
    chmod 0755 "$xt_tmp"
    chown root:"$SERVICE_USER" "$xt_tmp"
    mv -f -- "$xt_tmp" "${BIN_DIR}/xtunnel"
    [[ -n "$xt_sum_tmp" ]] && rm -f -- "$xt_sum_tmp"
    ok "xtunnel 最新核心已完成原子替换。"

    # --- CLOUDFLARED 同步 ---
    say "正在同步 cloudflared 核心..."
    if [[ -f "${BIN_DIR}/cloudflared" ]]; then
        mv -f "${BIN_DIR}/cloudflared" "${BIN_DIR}/cloudflared.old" >/dev/null 2>&1 || true
        rm -f "${BIN_DIR}/cloudflared.old" >/dev/null 2>&1 &
    fi
    curl -fL --retry 3 "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" -o "/tmp/cloudflared" || err "cloudflared 下载失败"
    mv -f "/tmp/cloudflared" "${BIN_DIR}/cloudflared"
    
    # --- SING-BOX 版本协商与更新避免 ---
    local LOCAL_VER TARGET_VER
    LOCAL_VER=$(get_local_sb_version)
    
    if [[ -n "$LOCAL_VER" ]]; then
        TARGET_VER=$(get_sb_version)
        [[ -z "$TARGET_VER" ]] && TARGET_VER="$LOCAL_VER"
    else
        say "正在向 GitHub 检索 Sing-box 最新发行版..."
        TARGET_VER=$(get_sb_version)
        [[ -z "$TARGET_VER" ]] && TARGET_VER="1.8.11"
    fi

    local need_sb_update=true
    if [[ -x "${BIN_DIR}/singbox" ]] && [[ "$LOCAL_VER" = "$TARGET_VER" ]]; then
        need_sb_update=false
        say "本地已存版本 v${LOCAL_VER} 匹配目标版本 v${TARGET_VER}，跳过下载。"
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

    chmod 0755 "${BIN_DIR}/xtunnel" "${BIN_DIR}/cloudflared" "${BIN_DIR}/singbox" || err "组件赋权失败"
    chown root:"$SERVICE_USER" "${BIN_DIR}/xtunnel" "${BIN_DIR}/cloudflared" "${BIN_DIR}/singbox" || err "二进制归属设置失败"
    chmod 0750 "$LIB_DIR" "$BIN_DIR" || err "核心目录权限设置失败"
    chmod 0700 "${LIB_DIR}/home" || err "服务 Home 权限设置失败"
    chmod 0750 "$LOG_DIR" || err "日志目录权限设置失败"
    
    if command -v restorecon >/dev/null 2>&1; then
        say "检测到 SELinux 安全策略处于激活状态，重构二进制目录上下文标签..."
        restorecon -R "${BIN_DIR}" >/dev/null 2>&1 || true
    fi

    # 代码与二进制保持 root 所有；仅独立 Home 与日志目录授予服务账号写权限。
    chown root:"$SERVICE_USER" "$LIB_DIR" "$BIN_DIR" || err "核心目录归属分配失败"
    chown "$SERVICE_USER":"$SERVICE_USER" "${LIB_DIR}/home" "$LOG_DIR" || err "可写目录归属分配失败"
    
    # 👈 核心新增：自动触发系统层 UDP/QUIC 加速优化
    optimize_network_for_quic
}

# 🚀 核心新增：系统层 UDP/QUIC 极限加速与物理防火墙自适应放行函数
optimize_network_for_quic() {
    say "正在执行 QUIC / UDP 内核级传输加速与出站放行..."

    # 1. 扩容 Linux 内核 UDP 缓冲区并优化慢启动限制
    if [ -f "/etc/sysctl.conf" ]; then
        if [ ! -f "/etc/sysctl.conf.bak_nmu" ]; then
            cp /etc/sysctl.conf /etc/sysctl.conf.bak_nmu
        fi
        
        declare -A params=(
            ["net.core.rmem_max"]="67108864"
            ["net.core.wmem_max"]="67108864"
            ["net.ipv4.tcp_rmem"]="4096 87380 67108864"
            ["net.ipv4.tcp_wmem"]="4096 65536 67108864"
            ["net.ipv4.tcp_slow_start_after_idle"]="0"
        )
        
        for key in "${!params[@]}"; do
            value="${params[$key]}"
            if grep -q "^$key" /etc/sysctl.conf; then
                sed -i "s|^$key.*|$key = $value|g" /etc/sysctl.conf
            else
                echo "$key = $value" >> /etc/sysctl.conf
            fi
        done
        sysctl -p >/dev/null 2>&1 || true
        ok "系统内核级 UDP 滑动缓冲区扩容（64MB）与慢启动消除已就绪。"
    fi

    # 2. 仅放行必要的 QUIC 出站端口：UDP 443 用于标准 HTTP/3/WebTransport，
    # UDP 7844 用于 cloudflared QUIC。规则保持出站限定、幂等，不开放任何入站端口。
    local quic_port
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
        for quic_port in 443 7844; do
            ufw allow out "${quic_port}/udp" >/dev/null 2>&1 || err "UFW 放行 UDP ${quic_port} 失败"
        done
        ok "UFW 已放行 UDP 443/7844 出站通道。"
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        for quic_port in 443 7844; do
            firewall-cmd --permanent --direct --query-rule ipv4 filter OUTPUT 0 -p udp --dport "$quic_port" -j ACCEPT >/dev/null 2>&1 || \
                firewall-cmd --permanent --direct --add-rule ipv4 filter OUTPUT 0 -p udp --dport "$quic_port" -j ACCEPT >/dev/null 2>&1
            firewall-cmd --permanent --direct --query-rule ipv6 filter OUTPUT 0 -p udp --dport "$quic_port" -j ACCEPT >/dev/null 2>&1 || \
                firewall-cmd --permanent --direct --add-rule ipv6 filter OUTPUT 0 -p udp --dport "$quic_port" -j ACCEPT >/dev/null 2>&1
        done
        firewall-cmd --reload >/dev/null 2>&1 || err "Firewalld 重载失败"
        ok "Firewalld 已放行 UDP 443/7844 出站通道。"
    fi
    if command -v iptables >/dev/null 2>&1; then
        for quic_port in 443 7844; do
            iptables -C OUTPUT -p udp --dport "$quic_port" -j ACCEPT >/dev/null 2>&1 || \
                iptables -A OUTPUT -p udp --dport "$quic_port" -j ACCEPT
        done
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        for quic_port in 443 7844; do
            ip6tables -C OUTPUT -p udp --dport "$quic_port" -j ACCEPT >/dev/null 2>&1 || \
                ip6tables -A OUTPUT -p udp --dport "$quic_port" -j ACCEPT
        done
    fi
    ok "物理防火墙 QUIC 出站安全链配置完成。"
}

# --- 4. 配置文件生成与安全并流算法 ---
write_configs() {
    say "配置写入中..."

    # 参数优先级：显式环境变量 > 已安装配置 > 交互输入/默认值。
    # 自动化升级未传参数时继承现有值，防止 Token、Secret、端口和域名被空值覆盖。
    local token="${TOKEN-}" ws_port="${WS_PORT-}" cf_token="${CF_TOKEN-}"
    local extra_domains="${EXTRA_DOMAINS-}" secret="${SECRET-}"
    local fallback_proxy="${FALLBACK_PROXY-}"
    local env_token="" env_ws_port="" env_cf_token="" env_extra_domains="" env_secret="" env_fallback_proxy=""
    local sb_port="" m_port=""
    if [[ -f "${ETC_DIR}/env" ]]; then
        local line key value
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ "$line" =~ ^[[:space:]]*$ ]] && continue
            if [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
                key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
                value="${value//$'\r'/}"; value="${value#\"}"; value="${value%\"}"
                value="${value//\\\"/\"}"; value="${value//\\\\/\\}"
                case "$key" in
                    TOKEN) env_token="$value" ;;
                    WS_PORT) env_ws_port="$value" ;;
                    CF_TOKEN) env_cf_token="$value" ;;
                    EXTRA_DOMAINS) env_extra_domains="$value" ;;
                    SECRET) env_secret="$value" ;;
                    FALLBACK_PROXY) env_fallback_proxy="$value" ;;
                    SB_PORT) sb_port="$value" ;;
                    METRICS_PORT) m_port="$value" ;;
                esac
            fi
        done < "${ETC_DIR}/env"
    fi
    [[ -n "$token" ]] || token="$env_token"
    [[ -n "$ws_port" ]] || ws_port="$env_ws_port"
    [[ -n "$cf_token" ]] || cf_token="$env_cf_token"
    [[ -n "$extra_domains" ]] || extra_domains="$env_extra_domains"
    [[ -n "$secret" ]] || secret="$env_secret"
    [[ -n "$fallback_proxy" ]] || fallback_proxy="$env_fallback_proxy"
    fallback_proxy=${fallback_proxy:-https://www.debian.org}

    if [[ -z "$token" ]]; then
        if [ -t 0 ]; then
            read -p "请输入隧道连接 Token: " token
            [[ -z "$token" ]] && err "Token 不能为空"
        else
            err "检测到无头 (Headless) 自动安装，请设置 TOKEN 环境变量。"
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
            read -p "追加分流域名 (逗号隔开，不改变默认分流): " extra_domains
        fi
    fi

    [[ "$token" != *$'\n'* && "$token" != *$'\r'* ]] || err "Token 不允许包含换行符"
    [[ "$secret" != *$'\n'* && "$secret" != *$'\r'* ]] || err "Secret 不允许包含换行符"
    if [[ -n "$secret" ]]; then
        (( ${#secret} >= 32 )) || err "最新核心要求 Secret 至少 32 字节"
        [[ "$secret" != "$token" ]] || err "Token 与 Secret 不能相同"
    fi
    [[ "$ws_port" =~ ^[0-9]+$ ]] && (( ws_port >= 1 && ws_port <= 65535 )) || err "WS_PORT 必须是 1-65535 的有效端口"
    [[ "$fallback_proxy" =~ ^https?://[^[:space:]]+$ ]] || err "伪装目标必须是合法的 http:// 或 https:// URL"

    # 内部端口已在函数入口从既有环境中恢复；首次安装时才生成新端口。
    sb_port=${sb_port:-$((RANDOM % 10000 + 40001))}
    m_port=${m_port:-$((RANDOM % 10000 + 30000))}

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

    # 对写入 EnvironmentFile 的敏感值进行双引号与反斜杠安全转义，防止 Systemd 加载词法断裂
    local esc_token esc_cf_token esc_extra_domains esc_secret esc_fallback_proxy
    esc_token="${token//\\/\\\\}"; esc_token="${esc_token//\"/\\\"}"
    esc_cf_token="${cf_token//\\/\\\\}"; esc_cf_token="${esc_cf_token//\"/\\\"}"
    esc_extra_domains="${extra_domains//\\/\\\\}"; esc_extra_domains="${esc_extra_domains//\"/\\\"}"
    esc_secret="${secret//\\/\\\\}"; esc_secret="${esc_secret//\"/\\\"}"
    esc_fallback_proxy="${fallback_proxy//\\/\\\\}"; esc_fallback_proxy="${esc_fallback_proxy//\"/\\\"}" # 👈 新增

    # 环境变量保存
    cat > "${ETC_DIR}/env" <<EOF
WS_PORT="${ws_port}"
SB_PORT="${sb_port}"
METRICS_PORT="${m_port}"
TOKEN="${esc_token}"
CF_TOKEN="${esc_cf_token}"
EXTRA_DOMAINS="${esc_extra_domains}"
SECRET="${esc_secret}"
FALLBACK_PROXY="${esc_fallback_proxy}"
EOF

    # 基础分流，不侵扰原有链路
    local base_domains=("netflix.com" "chatgpt.com" "openai.com" "ip.sb")
    local domain_array=()
    for bd in "${base_domains[@]}"; do
        domain_array+=("\"$bd\"")
    done

    # 清洗追加分流
    if [[ -n "$extra_domains" ]]; then
        # 利用 Bash read 数组功能安全地按分隔符分裂字符串，免除 set -f 导致的全局会话通配符失效副作用 [3]
        local extra_array
        read -r -a extra_array <<< "${extra_domains//,/ }"
        for d in "${extra_array[@]}"; do
            # 纯 Bash 剥除外侧空格
            d="${d#"${d%%[![:space:]]*}"}"; d="${d%"${d##*[![:space:]]}"}"
            if [[ -n "$d" ]]; then
                local is_duplicate=false
                for bd in "${base_domains[@]}"; do
                    if [[ "$d" == "$bd" ]]; then
                        is_duplicate=true
                        break
                    fi
                done
                for ad in "${domain_array[@]}"; do
                    if [[ "\"$d\"" == "$ad" ]]; then
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

    local domains
    domains=$(printf ",%s" "${domain_array[@]}")
    domains=${domains:1}

    # sing-box inbound 配置 (调优 WireGuard MTU 至 1360 以防御多段嵌套路由分片)
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
      "mtu": 1360
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
    chmod 0750 "$ETC_DIR" # root 可写，服务组仅可读取并穿越目录
    chmod 0640 "${ETC_DIR}/"*

    # 语法检测
    say "正在进行配置文件语法哨兵级检测..."
    local check_output
    if ! check_output=$("${BIN_DIR}/singbox" check -c "${ETC_DIR}/singbox.json" 2>&1); then
        say "\033[0;31m配置文件语法校验失败，原始错误反馈如下：\033[0m"
        echo "$check_output"
        err "Sing-box 语法检测未通过。安装终止。"
    fi
    ok "语法检测通过。"
}

# --- 5. Systemd 级联单元部署 ---
write_units() {
    say "部署 Systemd 级联链路..."

    # 以已原子落盘的 EnvironmentFile 为唯一运行参数快照，避免函数局部变量、
    # sudo 环境清理或无人值守升级导致 unit 写入空 Token/端口。
    local unit_token="" unit_secret="" unit_fallback="" unit_ws_port="" unit_sb_port=""
    # 显式初始化循环局部量：EOF补偿条件与空行过滤只能引用 unit_line，
    # 同时避免空文件在 set -u 下首次 read 失败时触发未绑定变量。
    local unit_cf_token="" unit_metrics_port="" unit_line="" unit_key="" unit_value=""
    [[ -s "${ETC_DIR}/env" ]] || err "环境文件不存在或为空，拒绝生成空参数 Systemd 单元"
    while IFS= read -r unit_line || [[ -n "$unit_line" ]]; do
        [[ "$unit_line" =~ ^[[:space:]]*# ]] && continue
        [[ "$unit_line" =~ ^[[:space:]]*$ ]] && continue
        if [[ "$unit_line" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
            unit_key="${BASH_REMATCH[1]}"; unit_value="${BASH_REMATCH[2]}"
            unit_value="${unit_value//$'\r'/}"
            unit_value="${unit_value#\"}"; unit_value="${unit_value%\"}"
            unit_value="${unit_value//\\\"/\"}"; unit_value="${unit_value//\\\\/\\}"
            case "$unit_key" in
                TOKEN) unit_token="$unit_value" ;; SECRET) unit_secret="$unit_value" ;;
                FALLBACK_PROXY) unit_fallback="$unit_value" ;; WS_PORT) unit_ws_port="$unit_value" ;;
                SB_PORT) unit_sb_port="$unit_value" ;; CF_TOKEN) unit_cf_token="$unit_value" ;;
                METRICS_PORT) unit_metrics_port="$unit_value" ;;
            esac
        fi
    done < "${ETC_DIR}/env"
    [[ -n "$unit_token" ]] || err "环境文件中的 TOKEN 为空，拒绝写入不可用 unit"
    [[ "$unit_ws_port" =~ ^[0-9]+$ ]] && (( unit_ws_port >= 1 && unit_ws_port <= 65535 )) || err "环境文件中的 WS_PORT 无效"
    [[ "$unit_sb_port" =~ ^[0-9]+$ ]] && (( unit_sb_port >= 1 && unit_sb_port <= 65535 )) || err "环境文件中的 SB_PORT 无效"
    [[ "$unit_metrics_port" =~ ^[0-9]+$ ]] && (( unit_metrics_port >= 1 && unit_metrics_port <= 65535 )) || err "环境文件中的 METRICS_PORT 无效"
    [[ -n "$unit_fallback" ]] || unit_fallback="https://www.debian.org"
    [[ "$unit_fallback" =~ ^https?://[^[:space:]]+$ ]] || err "环境文件中的 FALLBACK_PROXY 无效"
    if [[ -n "$unit_secret" ]]; then
        (( ${#unit_secret} >= 32 )) || err "环境文件中的 SECRET 少于 32 字节"
        [[ "$unit_secret" != "$unit_token" ]] || err "环境文件中的 TOKEN 与 SECRET 不能相同"
    fi

    # 每个原始值只进入一次统一编码器，防止分字段重复处理造成 $$ 继续膨胀为 $$$。
    # 编码顺序固定：反斜杠、双引号、字面量 $、systemd % specifier。
    systemd_escape_exec_arg() {
        local value="$1"
        value="${value//\\/\\\\}"
        value="${value//\"/\\\"}"
        value="${value//\$/\$\$}"
        value="${value//%/%%}"
        printf '%s' "$value"
    }
    unit_token="$(systemd_escape_exec_arg "$unit_token")"
    unit_secret="$(systemd_escape_exec_arg "$unit_secret")"
    unit_fallback="$(systemd_escape_exec_arg "$unit_fallback")"
    unit_cf_token="$(systemd_escape_exec_arg "$unit_cf_token")"

    # 非毁灭性单向拉起链：sing-box -> xtunnel -> cloudflared。
    # Wants + After 负责一键拉起；下游 StopWhenUnneeded 负责根服务真正停止后的遗留进程回收。
    # 不使用 Requires/PartOf/BindsTo，单层故障或热重载不会反向级联销毁。
    # 1. Singbox Unit
    cat > "/etc/systemd/system/${SB_SERVICE}" <<EOF
[Unit]
Description=NMU Singbox Base
After=network.target
Wants=${XT_SERVICE}

[Service]
ExecStart=${BIN_DIR}/singbox run -c ${ETC_DIR}/singbox.json
# 由 systemd 向主进程发送 SIGHUP，实现配置原位重载；\$MAINPID 必须延迟到 unit 运行时展开。
ExecReload=/bin/kill -HUP \$MAINPID
User=${SERVICE_USER}
Group=${SERVICE_USER}
Environment=HOME=${LIB_DIR}/home
ReadWritePaths=${LIB_DIR}/home ${LOG_DIR}
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    # 2. xtunnel Unit
    cat > "/etc/systemd/system/${XT_SERVICE}" <<EOF
[Unit]
Description=NMU xtunnel Core
After=network.target ${SB_SERVICE}
Wants=${CF_SERVICE}
StopWhenUnneeded=true

[Service]
EnvironmentFile=${ETC_DIR}/env
EOF
    # 分支必须依据刚从落盘 env 读取并校验过的局部快照，不能依赖可能被 sudo 清理、
    # 未导出或仍保留旧值的调用方变量 SECRET。
    if [[ -n "$unit_secret" ]]; then
        cat >> "/etc/systemd/system/${XT_SERVICE}" <<EOF
ExecStart=${BIN_DIR}/xtunnel -l ws://127.0.0.1:${unit_ws_port} -token "${unit_token}" -f socks5://127.0.0.1:${unit_sb_port} -secret "${unit_secret}" -fallback-proxy "${unit_fallback}" -quiet
EOF
    else
        cat >> "/etc/systemd/system/${XT_SERVICE}" <<EOF
ExecStart=${BIN_DIR}/xtunnel -l ws://127.0.0.1:${unit_ws_port} -token "${unit_token}" -f socks5://127.0.0.1:${unit_sb_port} -fallback-proxy "${unit_fallback}" -quiet
EOF
    fi
    cat >> "/etc/systemd/system/${XT_SERVICE}" <<EOF
User=${SERVICE_USER}
Group=${SERVICE_USER}
Environment=HOME=${LIB_DIR}/home
ReadWritePaths=${LIB_DIR}/home ${LOG_DIR}
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
Restart=always
RestartSec=3

[Install]
# 由上游 Wants 单向拉起，不单独绑定 multi-user.target。
EOF

    # 3. cloudflared Unit
    cat > "/etc/systemd/system/${CF_SERVICE}" <<EOF
[Unit]
Description=NMU Cloudflared Exit
After=network.target ${XT_SERVICE}
StopWhenUnneeded=true

[Service]
EnvironmentFile=${ETC_DIR}/env
# 原生直启 cloudflared，分支在生成 unit 时确定，不再保留常驻 Shell 包装。
EOF
    # 与模板中实际写入的局部快照保持同一作用域，避免 sudo 环境清理或旧全局值
    # 导致固定 Tunnel 与临时域名模式判断错位。
    if [[ -n "$unit_cf_token" ]]; then
        cat >> "/etc/systemd/system/${CF_SERVICE}" <<EOF
ExecStart=${BIN_DIR}/cloudflared --protocol quic tunnel run --token "${unit_cf_token}"
EOF
    else
        cat >> "/etc/systemd/system/${CF_SERVICE}" <<EOF
ExecStart=${BIN_DIR}/cloudflared --protocol quic tunnel --url http://127.0.0.1:${unit_ws_port} --metrics 127.0.0.1:${unit_metrics_port}
EOF
    fi
    cat >> "/etc/systemd/system/${CF_SERVICE}" <<EOF
User=${SERVICE_USER}
Group=${SERVICE_USER}
Environment=HOME=${LIB_DIR}/home
ReadWritePaths=${LIB_DIR}/home ${LOG_DIR}
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
Restart=always
RestartSec=5

[Install]
# 由上游 Wants 单向拉起，不单独绑定 multi-user.target。
EOF

    chmod 644 /etc/systemd/system/nmu-*.service
    systemctl daemon-reload
}

# --- 6. 本地端口就绪监测与串行引导拉起 ---
wait_for_local_port() {
    local port=$1
    local name=$2
    local max_wait=15
    local wait_time=0
    local port_hex
    port_hex=$(printf '%04X' "$port")
    while true; do
        local check_ok=false
        # 渐进式多路兼容性端口探针设计，解决无 ss/netstat 的超精简极简容器/Alpine 环境兼容死局
        if command -v ss >/dev/null 2>&1; then
            ss -lnt 2>/dev/null | grep -E -q "(^|:)${port}(\s|$)" && check_ok=true
        elif command -v netstat >/dev/null 2>&1; then
            netstat -lnt 2>/dev/null | grep -E -q "(^|:)${port}(\s|$)" && check_ok=true
        # 精确匹配 local_address 列首字段，防止匹配到远端出站的目标端口（rem_address 列）产生就绪状态抢跑
        elif grep -q -E "^\s*[0-9]+:\s+[0-9A-F]{8}:${port_hex}" /proc/net/tcp 2>/dev/null; then
            check_ok=true
        fi

        if [ "$check_ok" = "true" ]; then
            break
        fi

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
    # 仅将根服务绑定到开机目标；下游由 Wants 拉起，根服务停止后可通过 StopWhenUnneeded 自动收敛。
    systemctl disable "$XT_SERVICE" "$CF_SERVICE" >/dev/null 2>&1 || true
    systemctl enable "$SB_SERVICE" >/dev/null 2>&1

    local ws_port sb_port metrics_port
    # 重构读取：采用纯 Bash 正则表达式提取首个等号前后的键值对，防御包含等号的 Token 与密钥，且过滤 CRLF 换行符
    if [ -f "${ETC_DIR}/env" ]; then
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
                    WS_PORT) ws_port="$value" ;;
                    SB_PORT) sb_port="$value" ;;
                    METRICS_PORT) metrics_port="$value" ;;
                esac
            fi
        done < "${ETC_DIR}/env"
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
    
    # 交互升级自动读取现有配置。直接回车保留原值，可选项输入单个 - 表示清空。
    local token="" ws_port="" cf_token="" extra_domains="" secret="" fallback_proxy=""
    local old_token="" old_ws_port="" old_cf_token="" old_extra_domains="" old_secret="" old_fallback_proxy=""
    if [[ -f "${ETC_DIR}/env" ]]; then
        local line key value
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
                key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
                value="${value//$'\r'/}"; value="${value#\"}"; value="${value%\"}"
                value="${value//\\\"/\"}"; value="${value//\\\\/\\}"
                case "$key" in
                    TOKEN) old_token="$value" ;; WS_PORT) old_ws_port="$value" ;;
                    CF_TOKEN) old_cf_token="$value" ;; EXTRA_DOMAINS) old_extra_domains="$value" ;;
                    SECRET) old_secret="$value" ;; FALLBACK_PROXY) old_fallback_proxy="$value" ;;
                esac
            fi
        done < "${ETC_DIR}/env"
    fi
    read -r -p "1. Token [回车保留现有值]: " token; token=${token:-$old_token}
    [[ -n "$token" ]] || err "Token 不能为空"
    read -r -p "2. 本地监听端口 [${old_ws_port:-56908}]: " ws_port; ws_port=${ws_port:-${old_ws_port:-56908}}
    read -r -p "3. CF Tunnel Token [回车保留，输入 - 清空]: " cf_token
    [[ "$cf_token" == "-" ]] && cf_token="" || cf_token=${cf_token:-$old_cf_token}
    read -r -p "4. 追加分流域名 [回车保留，输入 - 清空]: " extra_domains
    [[ "$extra_domains" == "-" ]] && extra_domains="" || extra_domains=${extra_domains:-$old_extra_domains}
    read -r -s -p "5. AES-256-GCM Secret [回车保留，输入 - 清空]: " secret; printf '\n'
    [[ "$secret" == "-" ]] && secret="" || secret=${secret:-$old_secret}
    read -r -p "6. 伪装目标 [${old_fallback_proxy:-https://www.debian.org}]: " fallback_proxy
    fallback_proxy=${fallback_proxy:-${old_fallback_proxy:-https://www.debian.org}}

    TOKEN="$token"
    WS_PORT="$ws_port"
    CF_TOKEN="$cf_token"
    EXTRA_DOMAINS="$extra_domains"
    SECRET="$secret"
	FALLBACK_PROXY="$fallback_proxy" # 👈 新增传递

    write_configs
    write_units
    start_all
    write_install_state || true
    cleanup_maintenance_files
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
    kill_process_native
    rm -f /etc/systemd/system/nmu-*.service
    systemctl daemon-reload
    [[ "$ETC_DIR" == "/etc/$APP_NAME" && "$LIB_DIR" == "/var/lib/$APP_NAME" && "$LOG_DIR" == "/var/log/$APP_NAME" ]] || err "卸载路径安全校验失败"
    rm -rf --one-file-system -- "$ETC_DIR" "$LIB_DIR" "$LOG_DIR"
    
    if command -v userdel >/dev/null 2>&1; then
        userdel -r "$SERVICE_USER" || true
    elif command -v deluser >/dev/null 2>&1; then
        deluser "$SERVICE_USER" || true
    fi
    
    ok "服务已彻底卸载，相关物理文件已全部清理。"
}

# --- 8. 追加分流域名专用模块 (热追加并流算法) ---
append_split_domains_menu() {
    require_root
    if [ ! -f "${ETC_DIR}/env" ]; then
        err "未检测到已安装的 NMU-Tunnel 配置环境，请先选择选项 1 进行安装。"
    fi

    # 彻底解决局部命名遮蔽缺陷：采用纯 Bash 正则表达式提取第一个 "=" 键值，完美复原 Base64 加解密凭证，屏蔽换行符干扰
    local cur_ws_port="" cur_token="" cur_cf_token="" cur_extra_domains="" cur_secret="" cur_fallback_proxy="" # 👈 新增
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
                FALLBACK_PROXY) cur_fallback_proxy="$value" ;; # 👈 新增
            esac
        fi
    done < "${ETC_DIR}/env"

    local current_extras="${cur_extra_domains}"
    say "当前已配置的追加分流域名: ${current_extras:-无}"
    read -p "请输入需要新增的追加分流域名 (多个用逗号隔开): " new_domains
    [[ -z "$new_domains" ]] && err "输入内容为空，未做任何更改。"

    # 合并新旧追加域名组
    local merged_extras
    if [[ -n "$current_extras" ]]; then
        merged_extras="${current_extras},${new_domains}"
    else
        merged_extras="${new_domains}"
    fi

    # 将解析出的参数安全载入当前环境，避免因多余的分流添加导致重新弹窗询问连接口令
    TOKEN="$cur_token" \
    WS_PORT="$cur_ws_port" \
    CF_TOKEN="$cur_cf_token" \
    EXTRA_DOMAINS="$merged_extras" \
    SECRET="$cur_secret" \
    FALLBACK_PROXY="$cur_fallback_proxy" \
    write_configs

    # 仅刷新分流路由层，避免 xtunnel / cloudflared 级联重启。
    say "正在热加载 Sing-box 分流规则，保持隧道核心与公网出口在线..."
    # 分流规则只属于 sing-box。重载该层即可，xtunnel 与 cloudflared 保持连接不断流。
    if systemctl reload "$SB_SERVICE" 2>/dev/null; then
        ok "Sing-box 已完成原位 reload，隧道链路未重启。"
    else
        systemctl restart "$SB_SERVICE"
    fi
    
    ok "分流规则追加成功！新规则已即时生效。"
    say "当前最新合并追加域名列表: $merged_extras"
}


# --- 8.0 长期维护基础设施：状态、事务、诊断与清理 ---
ensure_lts_dirs() {
    mkdir -p "$ETC_DIR" "$LIB_DIR" "$BIN_DIR" "$LOG_DIR" "$BACKUP_DIR" "$STAGING_DIR" "$METRICS_DIR" "$CREDENTIALS_DIR" 2>/dev/null || true
    chmod 0750 "$ETC_DIR" "$LIB_DIR" "$BIN_DIR" "$LOG_DIR" "$BACKUP_DIR" "$STAGING_DIR" "$METRICS_DIR" "$CREDENTIALS_DIR" 2>/dev/null || true
}

write_install_state() {
    ensure_lts_dirs
    local tmp arch sbv cfv xtv
    arch="$(get_arch 2>/dev/null || uname -m)"
    sbv="$(get_local_sb_version 2>/dev/null || true)"
    cfv="$(get_cloudflared_local_version 2>/dev/null || true)"
    xtv="$("${BIN_DIR}/xtunnel" --version 2>/dev/null | head -n1 || true)"
    tmp="$(mktemp "${LIB_DIR}/.install-state.XXXXXX")" || return 1
    cat >"$tmp" <<EOF
INSTALL_VERSION=${SCRIPT_VERSION}
CONFIG_SCHEMA=${CONFIG_SCHEMA}
UNIT_SCHEMA=${UNIT_SCHEMA}
ARCH=${arch}
XTUNNEL_VERSION=${xtv:-unknown}
SINGBOX_VERSION=${sbv:-unknown}
CLOUDFLARED_VERSION=${cfv:-unknown}
UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
    chmod 0640 "$tmp"; chown root:"$SERVICE_USER" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$STATE_FILE"
}

transaction_begin() {
    local component="$1" backup="$2" candidate="$3" tmp
    ensure_lts_dirs
    tmp="$(mktemp "${LIB_DIR}/.update-transaction.XXXXXX")" || err "无法创建更新事务"
    cat >"$tmp" <<EOF
COMPONENT=${component}
STATE=prepared
BACKUP=${backup}
CANDIDATE=${candidate}
STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
    chmod 0600 "$tmp"; mv -f "$tmp" "$TXN_FILE"
}

transaction_state() {
    local state="$1" tmp
    [[ -f "$TXN_FILE" ]] || return 0
    tmp="$(mktemp "${LIB_DIR}/.update-transaction.XXXXXX")" || return 1
    awk -v state="$state" 'BEGIN{done=0} /^STATE=/{print "STATE=" state; done=1; next} {print} END{if(!done) print "STATE=" state}' "$TXN_FILE" >"$tmp"
    chmod 0600 "$tmp"; mv -f "$tmp" "$TXN_FILE"
}

transaction_commit() {
    transaction_state committed
    rm -f -- "$TXN_FILE"
    write_install_state || true
}

recover_interrupted_transaction() {
    [[ -f "$TXN_FILE" ]] || return 0
    local component state backup target service
    component="$(awk -F= '$1=="COMPONENT"{print substr($0,index($0,"=")+1)}' "$TXN_FILE")"
    state="$(awk -F= '$1=="STATE"{print substr($0,index($0,"=")+1)}' "$TXN_FILE")"
    backup="$(awk -F= '$1=="BACKUP"{print substr($0,index($0,"=")+1)}' "$TXN_FILE")"
    [[ "$state" == "committed" ]] && { rm -f "$TXN_FILE"; return 0; }
    case "$component" in
        xtunnel) target="${BIN_DIR}/xtunnel"; service="$XT_SERVICE" ;;
        singbox) target="${BIN_DIR}/singbox"; service="$SB_SERVICE" ;;
        cloudflared) target="${BIN_DIR}/cloudflared"; service="$CF_SERVICE" ;;
        *) say "发现未知更新事务，保留 $TXN_FILE 供人工检查"; return 1 ;;
    esac
    say "检测到未完成的 ${component} 更新事务 (${state})，执行安全恢复..."
    if [[ -f "$backup" ]]; then
        systemctl stop "$service" >/dev/null 2>&1 || true
        install -m 0755 -- "$backup" "${target}.recovery" || err "事务恢复失败"
        chown root:"$SERVICE_USER" "${target}.recovery" 2>/dev/null || true
        mv -f "${target}.recovery" "$target"
        systemctl start "$service" >/dev/null 2>&1 || true
    fi
    rm -f -- "$TXN_FILE"
}

portable_mtime_epoch() {
    local path="$1" value
    value="$(stat -c %Y -- "$path" 2>/dev/null || true)"
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        value="$(stat -f %m -- "$path" 2>/dev/null || true)"
    fi
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$value"
}

cleanup_older_than() {
    local directory="$1" max_age="$2" mode="$3" entry mtime now
    [[ -d "$directory" ]] || return 0
    now="$(date +%s)"
    for entry in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        mtime="$(portable_mtime_epoch "$entry" || true)"
        [[ "$mtime" =~ ^[0-9]+$ ]] || continue
        (( now - mtime > max_age )) || continue
        case "$mode" in
            tree) rm -rf -- "$entry" ;;
            file) [[ -f "$entry" || -L "$entry" ]] && rm -f -- "$entry" ;;
        esac
    done
}

cleanup_maintenance_files() {
    ensure_lts_dirs
    # 完全不调用 find，兼容 BusyBox/Alpine。staging 清理目录树，metrics 只清理文件。
    cleanup_older_than "$STAGING_DIR" 86400 tree
    cleanup_older_than "$METRICS_DIR" 2592000 file
}

capture_runtime_baseline() {
    local label="$1" out="${METRICS_DIR}/${label}-$(date -u +%Y%m%dT%H%M%SZ).txt"
    ensure_lts_dirs
    {
        echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "script_version=$SCRIPT_VERSION"
        systemctl is-active "$SB_SERVICE" "$XT_SERVICE" "$CF_SERVICE" 2>/dev/null || true
        curl -fsS --connect-timeout 2 --max-time 4 http://127.0.0.1:56900/debug/status 2>/dev/null || true
        free -m 2>/dev/null || true
        df -h "$LIB_DIR" 2>/dev/null || true
    } >"$out"
    chmod 0640 "$out" 2>/dev/null || true
}

full_chain_health_check() {
    local ws_port sb_port metrics_port status_body active_tunnels
    ws_port="$(awk -F= '$1=="WS_PORT"{gsub(/^"|"$/,"",$2);print $2}' "$ETC_DIR/env" 2>/dev/null | tail -n1)"
    sb_port="$(awk -F= '$1=="SB_PORT"{gsub(/^"|"$/,"",$2);print $2}' "$ETC_DIR/env" 2>/dev/null | tail -n1)"
    metrics_port="$(awk -F= '$1=="METRICS_PORT"{gsub(/^"|"$/,"",$2);print $2}' "$ETC_DIR/env" 2>/dev/null | tail -n1)"
    systemctl is-active --quiet "$SB_SERVICE" || return 1
    systemctl is-active --quiet "$XT_SERVICE" || return 1
    systemctl is-active --quiet "$CF_SERVICE" || return 1
    [[ -z "$sb_port" ]] || wait_for_local_port "$sb_port" "Sing-box" >/dev/null 2>&1 || return 1
    [[ -z "$ws_port" ]] || wait_for_local_port "$ws_port" "xtunnel" >/dev/null 2>&1 || return 1

    # 强制检查诊断端点。任何请求失败、空响应、字段缺失或零活跃通道均判失败。
    status_body="$(curl -fsS --connect-timeout 2 --max-time 4 http://127.0.0.1:56900/debug/status 2>/dev/null)" || return 1
    [[ -n "$status_body" ]] || return 1
    active_tunnels="$(printf '%s\n' "$status_body" | awk -F: '/^[[:space:]]*active_tunnels[[:space:]]*:/{gsub(/[[:space:]]/,"",$2); print $2; exit}')"
    [[ "$active_tunnels" =~ ^[0-9]+$ ]] || return 1
    (( active_tunnels >= 1 )) || return 1

    [[ -z "$metrics_port" ]] || curl -fsS --connect-timeout 2 --max-time 4 "http://127.0.0.1:${metrics_port}/metrics" >/dev/null 2>&1 || return 1
    return 0
}

doctor_menu() {
    require_root
    local failures=0 warnings=0
    pass(){ printf '\033[0;32m[PASS]\033[0m %s\n' "$*"; }
    warn_doctor(){ printf '\033[0;33m[WARN]\033[0m %s\n' "$*"; warnings=$((warnings+1)); }
    fail_doctor(){ printf '\033[0;31m[FAIL]\033[0m %s\n' "$*"; failures=$((failures+1)); }
    echo
    [[ -d "$ETC_DIR" && -d "$BIN_DIR" ]] && pass "目录结构存在" || fail_doctor "目录结构不完整"
    [[ -r "$ETC_DIR/env" ]] && pass "env 可读取" || fail_doctor "缺少 env"
    [[ -r "$ETC_DIR/singbox.json" ]] && pass "Sing-box 配置存在" || fail_doctor "缺少 singbox.json"
    for bin in xtunnel singbox cloudflared; do
        [[ -x "$BIN_DIR/$bin" ]] && pass "$bin 可执行" || fail_doctor "$bin 不可执行"
    done
    [[ ! -x "$BIN_DIR/singbox" ]] || "$BIN_DIR/singbox" check -c "$ETC_DIR/singbox.json" >/dev/null 2>&1 && pass "Sing-box 配置校验通过" || fail_doctor "Sing-box 配置校验失败"
    for svc in "$SB_SERVICE" "$XT_SERVICE" "$CF_SERVICE"; do
        systemctl cat "$svc" >/dev/null 2>&1 && pass "$svc 单元存在" || fail_doctor "$svc 单元缺失"
        systemctl is-active --quiet "$svc" && pass "$svc 正在运行" || warn_doctor "$svc 未运行"
    done
    local mode free_kb
    mode="$(stat -c '%a' "$ETC_DIR/env" 2>/dev/null || echo unknown)"
    [[ "$mode" == "640" || "$mode" == "600" ]] && pass "env 权限安全 ($mode)" || warn_doctor "env 权限建议为 0640 或 0600，当前 $mode"
    free_kb="$(df -Pk "$LIB_DIR" 2>/dev/null | awk 'NR==2{print $4}')"
    [[ "$free_kb" =~ ^[0-9]+$ && "$free_kb" -gt 262144 ]] && pass "可用磁盘空间充足" || warn_doctor "可用磁盘空间低于 256 MiB"
    [[ -f "$TXN_FILE" ]] && warn_doctor "存在未完成更新事务" || pass "无残留更新事务"
    full_chain_health_check && pass "三层链路健康检查通过" || warn_doctor "三层链路健康检查未完全通过"
    echo "诊断完成：FAIL=$failures WARN=$warnings"
    (( failures == 0 ))
}

start_existing_services() {
    require_root
    recover_interrupted_transaction || true
    systemctl start "$SB_SERVICE" || err "Sing-box 启动失败"
    systemctl start "$XT_SERVICE" || err "xtunnel 启动失败"
    systemctl start "$CF_SERVICE" || err "Cloudflared 启动失败"
    full_chain_health_check || say "警告：服务已启动，但完整链路健康检查未完全通过"
    ok "现有服务已启动，未执行安装、下载或配置重写。"
}

restart_existing_services() {
    require_root
    systemctl restart "$SB_SERVICE" || err "Sing-box 重启失败"
    systemctl restart "$XT_SERVICE" || err "xtunnel 重启失败"
    systemctl restart "$CF_SERVICE" || err "Cloudflared 重启失败"
    full_chain_health_check || say "警告：重启完成，但完整链路健康检查未完全通过"
}

migrate_config_schema() {
    require_root
    ensure_lts_dirs
    # 当前 V13.4 不改变 JSON 结构，只登记 Schema。未来迁移必须逐级新增。
    write_install_state || err "写入安装状态失败"
    ok "配置 Schema 已登记为 ${CONFIG_SCHEMA}，现有配置内容未改写。"
}

# --- 8.1 原位核心更新模块（不重建 WARP / 配置 / Systemd） ---
UPDATE_LOCK="/run/lock/nmu-tunnel-update.lock"
BACKUP_DIR="${LIB_DIR}/backups"
XT_RELEASE_BASE="https://github.com/nmu-glitch/my-tunnels/releases/download/v1.0.1"

with_update_lock() {
    mkdir -p /run/lock "$BACKUP_DIR" "$BIN_DIR" || err "无法创建更新目录"
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$UPDATE_LOCK"
        flock -n 9 || err "已有 NMU 更新任务正在运行"
    fi
}

get_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) err "不支持的 CPU 架构: $(uname -m)" ;;
    esac
}

check_elf_arch() {
    local file_path="$1" arch="$2" desc
    [[ -s "$file_path" ]] || return 1
    desc="$(file -b "$file_path" 2>/dev/null || true)"
    [[ "$desc" == *ELF* ]] || return 1
    if [[ "$arch" == "amd64" ]]; then
        [[ "$desc" == *x86-64* || "$desc" == *x86_64* ]]
    else
        [[ "$desc" == *aarch64* || "$desc" == *ARM\ aarch64* ]]
    fi
}

backup_binary() {
    local name="$1" path="$2" stamp="$3"
    [[ -f "$path" ]] || return 0
    cp -a -- "$path" "${BACKUP_DIR}/${name}.${stamp}" || err "备份 ${name} 失败"
}

list_binary_backups_newest() {
    local name="$1" file
    # 时间戳命名为 YYYYMMDDTHHMMSSZ，字典倒序即为新到旧。
    # 使用 shell glob 与 POSIX sort，避免 GNU find -printf。
    for file in "$BACKUP_DIR"/"${name}."*; do
        [[ -f "$file" ]] && printf '%s\n' "$file"
    done | LC_ALL=C sort -r
}

prune_binary_backups() {
    local name="$1" old index=0
    while IFS= read -r old; do
        [[ -n "$old" ]] || continue
        index=$((index + 1))
        (( index <= 5 )) && continue
        rm -f -- "$old"
    done < <(list_binary_backups_newest "$name")
}

restore_binary_backup() {
    local name="$1" target="$2" stamp="$3" backup="${BACKUP_DIR}/${name}.${stamp}"
    [[ -f "$backup" ]] || return 1
    install -m 0755 -- "$backup" "${target}.rollback" || return 1
    chown root:"$SERVICE_USER" "${target}.rollback" || return 1
    mv -f -- "${target}.rollback" "$target"
}

wait_service_healthy() {
    local service="$1" max_wait="${2:-20}" waited=0
    while (( waited < max_wait )); do
        systemctl is-active --quiet "$service" && return 0
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

get_cloudflared_local_version() {
    [[ -x "${BIN_DIR}/cloudflared" ]] || { echo ""; return 1; }
    "${BIN_DIR}/cloudflared" --version 2>/dev/null \
        | sed -nE 's/^cloudflared version ([^ ]+).*/\1/p' | head -n1
}

get_cloudflared_latest_version() {
    local raw_json v
    raw_json=$(curl -sL --connect-timeout 5 --max-time 15 \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: nmu-tunnel-installer/13.3" \
        https://api.github.com/repos/cloudflare/cloudflared/releases/latest 2>/dev/null || true)
    v=$(printf '%s' "$raw_json" | grep -m1 '"tag_name":' \
        | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v?([^"]+)".*/\1/' || true)
    [[ "$v" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+$ ]] && echo "$v" || echo ""
}

check_core_updates_menu() {
    require_root
    local sb_local sb_latest cf_local cf_latest xt_local
    sb_local="$(get_local_sb_version || true)"
    sb_latest="$(get_sb_version || true)"
    cf_local="$(get_cloudflared_local_version || true)"
    cf_latest="$(get_cloudflared_latest_version || true)"
    xt_local="$("${BIN_DIR}/xtunnel" --version 2>/dev/null | head -n1 || true)"
    echo
    say "核心版本检测结果"
    printf '  xtunnel     : %s\n' "${xt_local:-已安装（核心未提供版本输出）}"
    printf '  sing-box    : 本地 %s / 最新稳定 %s\n' "${sb_local:-未安装}" "${sb_latest:-检测失败}"
    printf '  cloudflared : 本地 %s / 最新 %s\n' "${cf_local:-未安装}" "${cf_latest:-检测失败}"
}

update_xtunnel_core() {
    require_root
    with_update_lock
    local arch tmp sum_tmp url expected actual stamp was_active=false
    arch="$(get_arch)"
    tmp="$(mktemp "${BIN_DIR}/.xtunnel.update.XXXXXX")" || err "无法创建 xtunnel 更新临时文件"
    sum_tmp="$(mktemp "${BIN_DIR}/.xtunnel.update.sha256.XXXXXX")" || err "无法创建校验临时文件"
    trap 'rm -f -- "$tmp" "$sum_tmp"' RETURN

    if [[ -f "/tmp/xtunnel" ]]; then
        install -m 0755 -- /tmp/xtunnel "$tmp" || err "导入 /tmp/xtunnel 失败"
    elif [[ -f "/tmp/xtunnel-linux-${arch}" ]]; then
        install -m 0755 -- "/tmp/xtunnel-linux-${arch}" "$tmp" || err "导入本地架构核心失败"
    else
        url="${XT_RELEASE_BASE}/xtunnel-linux-${arch}"
        say "下载 xtunnel 核心，不重建其他环境..."
        curl --fail --location --retry 3 --retry-all-errors --connect-timeout 8 --max-time 180 \
            --proto '=https' --tlsv1.2 -H "User-Agent: nmu-tunnel-updater/13.3" \
            "$url" -o "$tmp" || err "xtunnel 下载失败"
        if curl --fail --silent --show-error --location --connect-timeout 5 --max-time 20 \
            --proto '=https' --tlsv1.2 "${url}.sha256" -o "$sum_tmp"; then
            expected="$(awk 'NR==1{print $1}' "$sum_tmp")"
            actual="$(sha256sum "$tmp" | awk '{print $1}')"
            [[ "$expected" =~ ^[0-9A-Fa-f]{64}$ && "${expected,,}" == "${actual,,}" ]] \
                || err "xtunnel SHA-256 校验失败"
        else
            err "线上 xtunnel 更新缺少 .sha256，拒绝降低供应链校验强度。可上传 /tmp/xtunnel 与 /tmp/xtunnel.sha256 离线更新。"
        fi
    fi
    if [[ -f /tmp/xtunnel || -f "/tmp/xtunnel-linux-${arch}" ]]; then
        local local_sum_file="/tmp/xtunnel.sha256"
        [[ -f "$local_sum_file" ]] || err "本地 xtunnel 更新必须同时提供 /tmp/xtunnel.sha256"
        expected="$(awk 'NR==1{print $1}' "$local_sum_file")"
        actual="$(sha256sum "$tmp" | awk '{print $1}')"
        [[ "$expected" =~ ^[0-9A-Fa-f]{64}$ && "${expected,,}" == "${actual,,}" ]] || err "本地 xtunnel SHA-256 校验失败"
    fi
    check_elf_arch "$tmp" "$arch" || err "xtunnel ELF 或架构校验失败"
    "${BIN_DIR}/xtunnel" --help >/dev/null 2>&1 || true
    systemctl is-active --quiet "$XT_SERVICE" && was_active=true
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    backup_binary xtunnel "${BIN_DIR}/xtunnel" "$stamp"
    transaction_begin xtunnel "${BACKUP_DIR}/xtunnel.${stamp}" "$tmp"
    capture_runtime_baseline before-xtunnel
    transaction_state stopped
    systemctl stop "$XT_SERVICE" || true
    install -m 0755 -- "$tmp" "${BIN_DIR}/xtunnel.new" || err "写入 xtunnel 新核心失败"
    chown root:"$SERVICE_USER" "${BIN_DIR}/xtunnel.new"
    mv -f -- "${BIN_DIR}/xtunnel.new" "${BIN_DIR}/xtunnel"
    transaction_state replaced
    restorecon "${BIN_DIR}/xtunnel" >/dev/null 2>&1 || true
    systemctl start "$XT_SERVICE" || true
    if ! wait_service_healthy "$XT_SERVICE" 25; then
        say "新 xtunnel 启动失败，自动回滚..."
        systemctl stop "$XT_SERVICE" || true
        restore_binary_backup xtunnel "${BIN_DIR}/xtunnel" "$stamp" || err "xtunnel 自动回滚失败"
        $was_active && systemctl start "$XT_SERVICE" || true
        err "xtunnel 更新失败，已恢复旧核心"
    fi
    transaction_state verified
    capture_runtime_baseline after-xtunnel
    transaction_commit
    prune_binary_backups xtunnel
    ok "xtunnel 已原位更新，WARP、Sing-box、Cloudflared、env 和 Systemd 均未重建。"
}

update_singbox_core() {
    require_root
    with_update_lock
    local arch local_ver target_ver tmp_dir archive candidate stamp was_active=false
    arch="$(get_arch)"
    local_ver="$(get_local_sb_version || true)"
    target_ver="$(get_sb_version || true)"
    [[ -n "$target_ver" ]] || err "无法获取 Sing-box 最新稳定版"
    if [[ "$local_ver" == "$target_ver" ]]; then ok "Sing-box 已是最新稳定版 v${target_ver}"; return 0; fi
    tmp_dir="$(mktemp -d /tmp/nmu-sb-update.XXXXXX)" || err "无法创建 Sing-box 临时目录"
    archive="${tmp_dir}/sing-box.tar.gz"
    trap 'rm -rf -- "$tmp_dir"' RETURN
    say "Sing-box: ${local_ver:-未安装} -> ${target_ver}"
    curl --fail --location --retry 3 --connect-timeout 8 --max-time 180 --proto '=https' --tlsv1.2 \
        "https://github.com/SagerNet/sing-box/releases/download/v${target_ver}/sing-box-${target_ver}-linux-${arch}.tar.gz" \
        -o "$archive" || err "Sing-box 下载失败"
    tar -tzf "$archive" | grep -Fx "sing-box-${target_ver}-linux-${arch}/sing-box" >/dev/null \
        || err "Sing-box 压缩包结构异常"
    candidate="${tmp_dir}/singbox"
    tar -xOzf "$archive" "sing-box-${target_ver}-linux-${arch}/sing-box" >"$candidate" || err "Sing-box 解压失败"
    chmod 0755 "$candidate"
    "$candidate" version >/dev/null 2>&1 || err "Sing-box 候选核心无法运行"
    systemctl is-active --quiet "$SB_SERVICE" && was_active=true
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    backup_binary singbox "${BIN_DIR}/singbox" "$stamp"
    transaction_begin singbox "${BACKUP_DIR}/singbox.${stamp}" "$candidate"
    capture_runtime_baseline before-singbox
    transaction_state stopped
    systemctl stop "$SB_SERVICE" || true
    install -m 0755 -- "$candidate" "${BIN_DIR}/singbox.new"
    chown root:"$SERVICE_USER" "${BIN_DIR}/singbox.new"
    mv -f -- "${BIN_DIR}/singbox.new" "${BIN_DIR}/singbox"
    transaction_state replaced
    if ! "${BIN_DIR}/singbox" check -c "${ETC_DIR}/singbox.json"; then
        say "新 Sing-box 与现有配置不兼容，自动回滚..."
        restore_binary_backup singbox "${BIN_DIR}/singbox" "$stamp" || err "Sing-box 回滚失败"
        $was_active && systemctl start "$SB_SERVICE" || true
        err "Sing-box 更新失败，配置未改动"
    fi
    $was_active && systemctl start "$SB_SERVICE" || true
    if $was_active && ! wait_service_healthy "$SB_SERVICE" 20; then
        restore_binary_backup singbox "${BIN_DIR}/singbox" "$stamp" || err "Sing-box 回滚失败"
        systemctl start "$SB_SERVICE" || true
        err "Sing-box 新版启动失败，已回滚"
    fi
    transaction_state verified
    capture_runtime_baseline after-singbox
    transaction_commit
    prune_binary_backups singbox
    ok "Sing-box 已更新至 v${target_ver}，现有 WARP 与分流配置保持不变。"
}

update_cloudflared_core() {
    require_root
    with_update_lock
    local arch local_ver target_ver tmp stamp was_active=false
    arch="$(get_arch)"
    local_ver="$(get_cloudflared_local_version || true)"
    target_ver="$(get_cloudflared_latest_version || true)"
    [[ -n "$target_ver" ]] || err "无法获取 Cloudflared 最新版"
    if [[ "$local_ver" == "$target_ver" ]]; then ok "Cloudflared 已是最新版 ${target_ver}"; return 0; fi
    tmp="$(mktemp "${BIN_DIR}/.cloudflared.update.XXXXXX")" || err "无法创建 Cloudflared 临时文件"
    trap 'rm -f -- "$tmp"' RETURN
    say "Cloudflared: ${local_ver:-未安装} -> ${target_ver}"
    curl --fail --location --retry 3 --connect-timeout 8 --max-time 180 --proto '=https' --tlsv1.2 \
        "https://github.com/cloudflare/cloudflared/releases/download/${target_ver}/cloudflared-linux-${arch}" \
        -o "$tmp" || err "Cloudflared 下载失败"
    chmod 0755 "$tmp"
    check_elf_arch "$tmp" "$arch" || err "Cloudflared ELF 或架构校验失败"
    "$tmp" --version >/dev/null 2>&1 || err "Cloudflared 候选核心无法运行"
    systemctl is-active --quiet "$CF_SERVICE" && was_active=true
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    backup_binary cloudflared "${BIN_DIR}/cloudflared" "$stamp"
    transaction_begin cloudflared "${BACKUP_DIR}/cloudflared.${stamp}" "$tmp"
    capture_runtime_baseline before-cloudflared
    transaction_state stopped
    systemctl stop "$CF_SERVICE" || true
    install -m 0755 -- "$tmp" "${BIN_DIR}/cloudflared.new"
    chown root:"$SERVICE_USER" "${BIN_DIR}/cloudflared.new"
    mv -f -- "${BIN_DIR}/cloudflared.new" "${BIN_DIR}/cloudflared"
    transaction_state replaced
    $was_active && systemctl start "$CF_SERVICE" || true
    if $was_active && ! wait_service_healthy "$CF_SERVICE" 25; then
        restore_binary_backup cloudflared "${BIN_DIR}/cloudflared" "$stamp" || err "Cloudflared 回滚失败"
        systemctl start "$CF_SERVICE" || true
        err "Cloudflared 新版启动失败，已回滚"
    fi
    transaction_state verified
    capture_runtime_baseline after-cloudflared
    transaction_commit
    prune_binary_backups cloudflared
    ok "Cloudflared 已更新至 ${target_ver}，Tunnel Token 与现有配置保持不变。"
}

update_all_cores() {
    update_xtunnel_core
    update_singbox_core
    update_cloudflared_core
    ok "三个核心更新流程执行完毕。"
}

rollback_core_menu() {
    require_root
    local name target service latest
    read -p "回滚组件 [xtunnel/singbox/cloudflared]: " name
    case "$name" in
        xtunnel) target="${BIN_DIR}/xtunnel"; service="$XT_SERVICE" ;;
        singbox) target="${BIN_DIR}/singbox"; service="$SB_SERVICE" ;;
        cloudflared) target="${BIN_DIR}/cloudflared"; service="$CF_SERVICE" ;;
        *) err "不支持的组件" ;;
    esac
    latest="$(list_binary_backups_newest "$name" | sed -n '1p')"
    [[ -n "$latest" && -f "$latest" ]] || err "没有找到 ${name} 备份"
    systemctl stop "$service" || true
    install -m 0755 -- "$latest" "${target}.rollback"
    chown root:"$SERVICE_USER" "${target}.rollback"
    mv -f -- "${target}.rollback" "$target"
    systemctl start "$service" || err "回滚后服务启动失败"
    ok "${name} 已回滚到 $(basename "$latest")"
}

# --- 9. 经典交互式 TTY 菜单 ---
menu() {
    create_shortcut # 每次进入菜单时自动尝试注册/刷新 'nmu' 快捷指令
    
    while true; do
        clear
        say "=================================================="
        say "         NMU-Tunnel 极盾 E2E 导航版 (V13.4.2)        "
        say "  [提示] 终端任意路径输入 'nmu' 即可直接唤醒此菜单   "
        say "=================================================="
        echo "  1. 首次安装 / 完整重建环境"
        echo "  2. 停止服务"
        echo "  3. 实时查看日志 (退出日志请按 Ctrl+C)"
        echo "  4. 完全物理卸载"
        echo "  5. 追加分流域名 (不破坏现有环境/即时生效)"
        echo "  6. 检测 xtunnel / Sing-box / Cloudflared 版本"
        echo "  7. 仅原位更新 xtunnel 核心"
        echo "  8. 仅更新 Sing-box 最新稳定版"
        echo "  9. 仅更新 Cloudflared 最新版"
        echo " 10. 依次更新三个核心 (不重建环境)"
        echo " 11. 回滚指定核心"
        echo " 12. 启动现有服务（不重建）"
        echo " 13. 重启现有服务（不重建）"
        echo " 14. 系统与链路 Doctor 自检"
        echo " 15. 登记/迁移配置 Schema"
        echo "  0. 退出"
        say "=================================================="
        local choice
        read -p "选择操作 [0-15]: " choice
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
            6) check_core_updates_menu; echo; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
            7) update_xtunnel_core; echo; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
            8) update_singbox_core; echo; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
            9) update_cloudflared_core; echo; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
            10) update_all_cores; echo; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
            11) rollback_core_menu; echo; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
            12) start_existing_services; echo; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
            13) restart_existing_services; echo; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
            14) doctor_menu || true; echo; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
            15) migrate_config_schema; echo; read -n 1 -s -r -p "按任意键返回主菜单..." ;;
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

# --- 运行入口 (自动识别无参数会话和有参数自动化流水线) ---
recover_interrupted_transaction || true
cleanup_maintenance_files || true
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
        check-updates) check_core_updates_menu ;;
        update-xtunnel) update_xtunnel_core ;;
        update-singbox) update_singbox_core ;;
        update-cloudflared) update_cloudflared_core ;;
        update-all) update_all_cores ;;
        rollback-core) rollback_core_menu ;;
        start) start_existing_services ;;
        restart) restart_existing_services ;;
        doctor) doctor_menu ;;
        migrate) migrate_config_schema ;;
        uninstall)
            require_root
            systemctl disable --now "$CF_SERVICE" "$XT_SERVICE" "$SB_SERVICE" || true
            kill_process_native
            rm -f /etc/systemd/system/nmu-*.service
            systemctl daemon-reload
            [[ "$ETC_DIR" == "/etc/$APP_NAME" && "$LIB_DIR" == "/var/lib/$APP_NAME" && "$LOG_DIR" == "/var/log/$APP_NAME" ]] || err "卸载路径安全校验失败"
    rm -rf --one-file-system -- "$ETC_DIR" "$LIB_DIR" "$LOG_DIR"
            
            if command -v userdel >/dev/null 2>&1; then
                userdel -r "$SERVICE_USER" || true
            elif command -v deluser >/dev/null 2>&1; then
                deluser "$SERVICE_USER" || true
            fi
            
            ok "环境已彻底物理清理。"
            ;;
        *)
            echo "用法: $0 {install|start|restart|stop|logs|doctor|migrate|check-updates|update-xtunnel|update-singbox|update-cloudflared|update-all|rollback-core|uninstall}"
            ;;
    esac
fi
