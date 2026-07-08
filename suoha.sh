#!/usr/bin/env bash

# =========================================================
# NMU Tunnel V13.2 - 极盾 E2E 全局快捷导航版 (深度安全与生存性能加固版)
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

say() { echo -e "\033[0;34m[NMU-V13.2]\033[0m $*"; }
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
        local script_path
        script_path=$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")
        if [[ -n "$script_path" && -f "$script_path" ]]; then
            # 增加安全哨兵，防范管道/匿名套接字执行时意外劫持系统 shell
            if [[ "$script_path" != *"/bash" && "$script_path" != *"/sh" && "$script_path" != "/dev/fd/"* ]]; then
                ln -sf "$script_path" /usr/local/bin/nmu 2>/dev/null || true
                chmod +x /usr/local/bin/nmu 2>/dev/null || true
                chmod +x "$script_path" 2>/dev/null || true
            fi
        fi
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
    local proc_patterns=("cloudflared" "xtunnel" "singbox")
    for pattern in "${proc_patterns[@]}"; do
        # 使用 -x (精确名称匹配) 替代 -f (全文命令行匹配)，防止安装脚本因其路径或名称包含关键字而被意外 Self-Kill 故障
        pkill -9 -x "$pattern" >/dev/null 2>&1 || true
        local pids
        pids=$(pgrep -x "$pattern" 2>/dev/null || true)
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
    
    # 自动检索系统可用的无登录 shell，提升跨发行版（包括 Alpine / CentOS / Debian）下的环境兼容度
    local nologin_path="/bin/false"
    if [[ -f "/usr/sbin/nologin" ]]; then
        nologin_path="/usr/sbin/nologin"
    elif [[ -f "/sbin/nologin" ]]; then
        nologin_path="/sbin/nologin"
    fi

    # 兼容性逻辑：自适应用户创建逻辑，完美兼容 Debian/Ubuntu 和 Alpine Linux
    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        if command -v useradd >/dev/null 2>&1; then
            useradd -r -m -d "$LIB_DIR" -s "$nologin_path" "$SERVICE_USER" || err "用户创建失败"
        elif command -v adduser >/dev/null 2>&1; then
            adduser -S -h "$LIB_DIR" -s "$nologin_path" -D "$SERVICE_USER" || err "用户创建失败"
        else
            err "未找到可用的用户创建命令"
        fi
    fi

    mkdir -p "$ETC_DIR" "$BIN_DIR" "$LOG_DIR" || err "目录初始化失败"

    local ARCH="amd64"
    if [[ "$(uname -m)" != "x86_64" ]]; then
        ARCH="arm64"
    fi
    
    # --- XTUNNEL 同步 ---
    say "正在同步 xtunnel 核心..."
    local need_download=true
    if [[ -f "${BIN_DIR}/xtunnel" ]]; then
        # 哨兵策略：防止重新运行时覆盖用户自己在本地重新编译的读写分离安全版 xtunnel 核心
        if [[ ! -f "/tmp/xtunnel" && ! -f "/tmp/xtunnel-linux-${ARCH}" ]]; then
            say "检测到本地已存在自编译/优化的 xtunnel 安全核心，跳过远程下载以防覆盖。"
            need_download=false
        else
            mv -f "${BIN_DIR}/xtunnel" "${BIN_DIR}/xtunnel.old" >/dev/null 2>&1 || true
            rm -f "${BIN_DIR}/xtunnel.old" >/dev/null 2>&1 &
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
            # 构造带 User-Agent 的健壮性 curl 请求，防止被 GitHub 判定为异常请求而拦截
            local dl_url="https://github.com/nmu-glitch/my-tunnels/releases/download/v1.0.1/xtunnel-linux-${ARCH}"
            say "自 GitHub 仓库同步最新 AES-256-GCM 核心..."
            say "下载链接: ${dl_url}"
            
            if ! curl -fL --retry 3 -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/119.0" "${dl_url}" -o "/tmp/xtunnel"; then
                err "xtunnel 下载失败，如果海外服务器网络解析存在异常，请手动在本地下载并上传至服务器 /tmp/xtunnel 后重新运行。"
            fi
        fi
        mv -f "/tmp/xtunnel" "${BIN_DIR}/xtunnel"
    fi
    
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

    chmod +x "${BIN_DIR}/xtunnel" "${BIN_DIR}/cloudflared" "${BIN_DIR}/singbox" || err "组件赋权失败"
    
    if command -v restorecon >/dev/null 2>&1; then
        say "检测到 SELinux 安全策略处于激活状态，重构二进制目录上下文标签..."
        restorecon -R "${BIN_DIR}" >/dev/null 2>&1 || true
    fi

    chown -R "$SERVICE_USER":"$SERVICE_USER" "$LIB_DIR" "$LOG_DIR" || err "权限归属分配失败"
}

# --- 4. 配置文件生成与安全并流算法 ---
write_configs() {
    say "配置写入中..."
    
    local token="${TOKEN}"
    local ws_port="${WS_PORT}"
    local cf_token="${CF_TOKEN}"
    local extra_domains="${EXTRA_DOMAINS}"
    local secret="${SECRET}" 

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

    # 深度优化：如果配置文件已存在，锁定并继承原有的内部端口，防止重复生成导致端口错位/重复绑定
    local sb_port=""
    local m_port=""
    if [ -f "${ETC_DIR}/env" ]; then
        # 采用纯 Bash 正则表达式匹配机制提取第一个 "=" 符号两边的键值，解决 token 或 secret 中包含 "=" 时造成的截断损坏缺陷 [3]
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
                if [[ "$key" == "SB_PORT" ]]; then sb_port="$value"; fi
                if [[ "$key" == "METRICS_PORT" ]]; then m_port="$value"; fi
            fi
        done < "${ETC_DIR}/env"
    fi
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
    local esc_token esc_cf_token esc_extra_domains esc_secret
    esc_token="${token//\\/\\\\}"; esc_token="${esc_token//\"/\\\"}"
    esc_cf_token="${cf_token//\\/\\\\}"; esc_cf_token="${esc_cf_token//\"/\\\"}"
    esc_extra_domains="${extra_domains//\\/\\\\}"; esc_extra_domains="${esc_extra_domains//\"/\\\"}"
    esc_secret="${secret//\\/\\\\}"; esc_secret="${esc_secret//\"/\\\"}"

    # 环境变量保存
    cat > "${ETC_DIR}/env" <<EOF
WS_PORT="${ws_port}"
SB_PORT="${sb_port}"
METRICS_PORT="${m_port}"
TOKEN="${esc_token}"
CF_TOKEN="${esc_cf_token}"
EXTRA_DOMAINS="${esc_extra_domains}"
SECRET="${esc_secret}"
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
    chmod 750 "$ETC_DIR" # 必须明确授予配置目录可执行权(r-x)，否则在严格的系统 umask 下非特权用户将无法进入该目录读取配置
    chmod 640 "${ETC_DIR}/"*

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

    # 1. Singbox Unit
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

    # 2. xtunnel Unit
    cat > "/etc/systemd/system/${XT_SERVICE}" <<EOF
[Unit]
Description=NMU xtunnel Core
After=network.target ${SB_SERVICE}
Requires=${SB_SERVICE}
PartOf=${SB_SERVICE}

[Service]
EnvironmentFile=${ETC_DIR}/env
ExecStart=/bin/sh -c 'if [ -n "\$\$SECRET" ]; then exec ${BIN_DIR}/xtunnel -l ws://127.0.0.1:\$\$WS_PORT -token "\$\$TOKEN" -f socks5://127.0.0.1:\$\$SB_PORT -secret "\$\$SECRET"; else exec ${BIN_DIR}/xtunnel -l ws://127.0.0.1:\$\$WS_PORT -token "\$\$TOKEN" -f socks5://127.0.0.1:\$\$SB_PORT; fi'
User=${SERVICE_USER}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    # 3. cloudflared Unit
    cat > "/etc/systemd/system/${CF_SERVICE}" <<EOF
[Unit]
Description=NMU Cloudflared Exit
After=network.target ${XT_SERVICE}
Requires=${XT_SERVICE}
PartOf=${XT_SERVICE}

[Service]
EnvironmentFile=${ETC_DIR}/env
ExecStart=/bin/sh -c 'if [ -n "\$\$CF_TOKEN" ]; then exec ${BIN_DIR}/cloudflared tunnel run --token \$\$CF_TOKEN; else exec ${BIN_DIR}/cloudflared tunnel --url http://127.0.0.1:\$\$WS_PORT --metrics 127.0.0.1:\$\$METRICS_PORT; fi'
User=${SERVICE_USER}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
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
    systemctl enable "$SB_SERVICE" "$XT_SERVICE" "$CF_SERVICE" >/dev/null 2>&1

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
    
    # 交互引导
    local token ws_port cf_token extra_domains secret
    read -p "1. Token (连接密码): " token
    [[ -z "$token" ]] && err "Token 不能为空"
    read -p "2. 本地监听端口 (默认 56908): " ws_port; ws_port=${ws_port:-56908}
    read -p "3. CF Tunnel Token (留空用临时域名): " cf_token
    read -p "4. 追加分流域名 (用逗号隔开，不改变默认分流): " extra_domains
    read -p "5. AES-256-GCM 极盾对称密钥 (留空则不开启对称加密): " secret

    TOKEN="$token"
    WS_PORT="$ws_port"
    CF_TOKEN="$cf_token"
    EXTRA_DOMAINS="$extra_domains"
    SECRET="$secret"

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
    kill_process_native
    rm -f /etc/systemd/system/nmu-*.service
    systemctl daemon-reload
    rm -rf "$ETC_DIR" "$LIB_DIR" "$LOG_DIR"
    
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
    local cur_ws_port="" cur_token="" cur_cf_token="" cur_extra_domains="" cur_secret=""
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
    write_configs

    # 优雅重启 Sing-box 服务应用新规则
    say "正在优雅重启基础路由服务应用新分流规则..."
    systemctl restart "$SB_SERVICE"
    
    ok "分流规则追加成功！新规则已即时生效。"
    say "当前最新合并追加域名列表: $merged_extras"
}

# --- 9. 经典交互式 TTY 菜单 ---
menu() {
    create_shortcut # 每次进入菜单时自动尝试注册/刷新 'nmu' 快捷指令
    
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
            kill_process_native
            rm -f /etc/systemd/system/nmu-*.service
            systemctl daemon-reload
            rm -rf "$ETC_DIR" "$LIB_DIR" "$LOG_DIR"
            
            if command -v userdel >/dev/null 2>&1; then
                userdel -r "$SERVICE_USER" || true
            elif command -v deluser >/dev/null 2>&1; then
                deluser "$SERVICE_USER" || true
            fi
            
            ok "环境已彻底物理清理。"
            ;;
        *)
            echo "用法: $0 {install|stop|logs|uninstall} 或无参数运行进入经典交互菜单"
            ;;
    esac
fi
