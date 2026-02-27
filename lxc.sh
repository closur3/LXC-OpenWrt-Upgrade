#!/bin/bash
set -euo pipefail
export LC_ALL=C

############################# 1. 默认全局配置项 (基座) #############################
# 【警告】请勿修改本文件中的默认值！以免未来脚本自动更新时发生冲突。
# 如需自定义参数，脚本运行后会在同级目录自动生成 .conf.example 参考手册。
# 请创建一个同名的 .conf 文件来进行差量覆盖。

SCRIPT_URL="https://raw.githubusercontent.com/closur3/LXC-OpenWrt-Upgrade/main/lxc.sh"
auto_update="1"          # 自动检查更新开关 (1=开启, 0=关闭)
vmid_min=100
vmid_max=999
backup_enabled="1"       # 备份还原开关 (1=开启, 0=关闭)
backup_file="/tmp/backup.tar.gz"
download_url="https://github.com/closur3/OpenWrt-Mainline/releases/latest/download/openwrt-x86-64-generic-rootfs.tar.gz"
network_check_url="https://www.google.com/generate_204"

# 容器默认/基础参数 (全新安装时生效，升级时会自动继承旧容器配置)
template="local:vztmpl/openwrt-x86-64-generic-rootfs.tar.gz"
rootfs="local-lvm:1"
config_hostname="OpenWrt"
ostype=""
arch=""
cores=""
memory=""
swap=""
onboot=""
startup=""
features=""
network_configs=""

# 运行时状态变量（全局共享，无需干预）
IS_NEW_INSTALL=0
OLD_VMID=""
NEW_VMID=""
HOST_BACKUP_FILE=""
##################################################################################

# ==================== 2. 动态配置管理 (生成与加载) ====================
SCRIPT_ABS_PATH=$(readlink -f "$0")
CONFIG_FILE="${SCRIPT_ABS_PATH%.*}.conf"
EXAMPLE_FILE="${SCRIPT_ABS_PATH%.*}.conf.example"

# 永远生成/刷新最新的配置说明书 (.example)
cat << 'EOF' > "$EXAMPLE_FILE"
# =================================================================
# LXC OpenWrt 自动升级脚本 - 全量配置参考手册 (Example)
# =================================================================
# 【注意】此文件由脚本自动生成，每次运行都会刷新。请勿直接修改！
# 
# 【如何自定义配置？】
# 1. 脚本默认使用内置参数运行，如果你不需要更改，什么都不用做。
# 2. 如果你需要覆盖默认参数，请在同级目录下手动创建一个同名的 .conf 文件 (例如: lxc.conf)。
# 3. 将本文件中你想要修改的行（去掉开头的 # 号）复制到你的 .conf 中并修改其值即可。
# =================================================================

# 自动检查更新开关 (1=开启自动检查并覆盖自身, 0=关闭纯本地运行)
# auto_update="1"

# 新容器 VMID 寻址范围 (脚本会在此范围内自动寻找空闲 ID)
# vmid_min=100
# vmid_max=999

# 是否开启配置备份与还原 (1=开启, 0=不备份/不还原)
# backup_enabled="1"

# 网络连通性测试目标 URL (用于判断科学上网代理是否启动成功)
# network_check_url="https://www.google.com/generate_204"

# ----------------- 容器高级硬件/网络参数 -----------------
# PVE 存储池名称 (根据你的 PVE 实际情况修改，通常是 local-lvm 或 local-zfs)
# rootfs="local-lvm:1"

# 容器分配的 CPU 核心数与内存大小 (MB)
# cores="2"
# memory="1024"
# swap="0"

# 容器网络接口配置 (务必匹配你宿主机的网桥名称)
# network_configs="--net0 name=eth0,bridge=vmbr0"

# 容器特权与嵌套功能 (软路由通常需要开启嵌套以支持各种功能)
# features="nesting=1"
EOF

# 加载用户的实际配置文件 (差量覆盖)
if [ -f "$CONFIG_FILE" ]; then
    set +u # 临时关闭未绑定变量报错，包容配置文件的随意性
    source "$CONFIG_FILE"
    set -u
fi
# ========================================================================

# ================= 基础工具函数 =================

log() {
    echo "[$(basename "$0") $(date +'%Y-%m-%d %H:%M:%S')] $*"
}

check_result() {
    local code=$1 msg=$2
    if [ "$code" -ne 0 ]; then
        log "错误：$msg"
        exit 1
    fi
}

check_command() {
    command -v "$1" >/dev/null 2>&1 || { log "缺少必要命令: $1"; exit 1; }
}

rollback() {
    log "正在启动故障保护：关闭新容器，回滚启动旧容器..."
    pct stop "$NEW_VMID" 2>/dev/null || true
    [ -n "$OLD_VMID" ] && pct start "$OLD_VMID" 2>/dev/null || true
    exit 1
}

# 智能轮询核心探针
wait_container_ready() {
    local vmid=$1
    local max_retries=${2:-30}
    local check_cmd=${3:-"true"}
    local count=0
    
    while ! pct exec "$vmid" -- $check_cmd >/dev/null 2>&1; do
        count=$((count + 1))
        [ "$count" -ge "$max_retries" ] && return 1
        sleep 1
    done
    
    log "容器 $vmid 系统核心组件已就绪，耗时约 $count 秒。"
    return 0
}

# ================= 核心业务逻辑函数 =================

init_environment() {
    [ "$(id -u)" -eq 0 ] || { log "请使用 root 权限运行此脚本"; exit 1; }
    for cmd in pct qm wget curl awk grep sort uniq md5sum cat rm chmod; do
        check_command "$cmd"
    done
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--no-backup) backup_enabled="0" ;; # 命令行强制跳过备份
            -u|--update) auto_update="1" ;;       # 命令行强制开启本次更新
            *) log "未知选项：$1"; exit 1 ;;
        esac
        shift
    done
}

check_update() {
    if [ "$auto_update" != "1" ]; then
        log "自动更新已禁用，直接运行本地版本。"
        return 0
    fi

    log "正在检查脚本更新..."
    local temp_file="/tmp/lxc_update_remote.sh"
    
    if wget -q -T 5 -O "$temp_file" "$SCRIPT_URL"; then
        if grep -q "^#!/bin/bash" "$temp_file"; then
            local local_md5 remote_md5
            local_md5=$(md5sum "$0" | awk '{print $1}')
            remote_md5=$(md5sum "$temp_file" | awk '{print $1}')
            
            if [ "$local_md5" != "$remote_md5" ]; then
                log "发现新版本脚本！正在自动覆盖更新..."
                cat "$temp_file" > "$0"
                chmod +x "$0"
                rm -f "$temp_file"
                log "更新完成！正在应用新版本重启脚本..."
                exec "$0" "$@"
            else
                log "当前已是最新版本。"
            fi
        else
            log "下载的文件验证失败，跳过更新。"
        fi
        rm -f "$temp_file"
    else
        log "检查更新失败，将继续运行当前版本。"
    fi
}

find_target_container() {
    set +e +o pipefail
    local pct_output=$(pct list 2>&1)
    set -e -o pipefail

    local existing_vmids=$(echo "$pct_output" | awk -v container="$config_hostname" 'NR>1 && ($3 == container || $4 == container) {print $1}' || true)
    local container_count=0
    [ -n "$existing_vmids" ] && container_count=$(echo "$existing_vmids" | wc -w)

    if [ "$container_count" -eq 0 ]; then
        log "未发现名为 $config_hostname 的容器。"
        if [[ -t 0 && -t 1 ]]; then
            while :; do
                read -t 30 -p "是否要创建一个全新的 $config_hostname 容器？ [y/n]: " choice || choice="n"
                case "$choice" in
                    y|Y) IS_NEW_INSTALL=1; break ;;
                    n|N) log "脚本执行中止。"; exit 0 ;;
                    *) echo "请输入 y 或 n。" ;;
                esac
            done
        else
            log "非交互式环境，跳过全新创建。"; exit 1
        fi
    elif [ "$container_count" -gt 1 ]; then
        log "有多个名为 $config_hostname 的容器，请确保环境中只有一个目标容器。"; exit 1
    else
        OLD_VMID=$(echo "$existing_vmids" | awk 'NR==1 {print $1}')
        if ! pct status "$OLD_VMID" | grep -q "running"; then
            log "容器 $OLD_VMID 未运行。请先启动该容器以确保可以进行备份和升级。"; exit 1
        fi
    fi
}

prepare_container_config() {
    if [ "$IS_NEW_INSTALL" -eq 1 ]; then
        ostype=${ostype:-unmanaged}; arch=${arch:-amd64}; cores=${cores:-2}
        memory=${memory:-1024}; swap=${swap:-0}; onboot=${onboot:-1}
        features=${features:-"nesting=1"}
        network_configs=${network_configs:-"--net0 name=eth0,bridge=vmbr0"}
    else
        local config_file="/etc/pve/lxc/${OLD_VMID}.conf"
        [ ! -f "$config_file" ] && { log "错误：无法找到容器 $OLD_VMID 的配置文件"; exit 1; }

        local current_config=$(awk '/^\[.*\]/{exit} {print}' "$config_file")
        [ -z "$ostype" ] && ostype=$(echo "$current_config" | grep "^ostype:" | head -1 | cut -d: -f2 | xargs || true)
        [ -z "$arch" ] && arch=$(echo "$current_config" | grep "^arch:" | head -1 | cut -d: -f2 | xargs || true)
        [ -z "$cores" ] && cores=$(echo "$current_config" | grep "^cores:" | head -1 | cut -d: -f2 | xargs || true)
        [ -z "$memory" ] && memory=$(echo "$current_config" | grep "^memory:" | head -1 | cut -d: -f2 | xargs || true)
        [ -z "$swap" ] && swap=$(echo "$current_config" | grep "^swap:" | head -1 | cut -d: -f2 | xargs || true)
        [ -z "$onboot" ] && onboot=$(echo "$current_config" | grep "^onboot:" | head -1 | cut -d: -f2 | xargs || true)
        [ -z "$startup" ] && startup=$(echo "$current_config" | grep "^startup:" | head -1 | cut -d: -f2- | xargs || true)
        [ -z "$features" ] && features=$(echo "$current_config" | grep "^features:" | head -1 | cut -d: -f2- | xargs || true)

        if [ -z "$network_configs" ]; then
            while IFS= read -r line; do
                if [[ "$line" =~ ^net[0-9]+: ]]; then
                    local net_key=$(echo "$line" | cut -d: -f1)
                    local net_value=$(echo "$line" | cut -d: -f2- | xargs | sed 's/,hwaddr=[^,]*//g' | sed 's/hwaddr=[^,]*,//g' | sed 's/hwaddr=[^,]*$//g')
                    network_configs="$network_configs --${net_key} $net_value"
                fi
            done <<< "$current_config"
        fi
        
        log "旧LXC容器ID为: $OLD_VMID"
        HOST_BACKUP_FILE="/tmp/openwrt_backup_${OLD_VMID}.tar.gz"
    fi
}

allocate_new_vmid() {
    set +e +o pipefail
    local lxc_vmids=($(pct list | awk 'NR>1 {print $1}' || true))
    local kvm_vmids=($(qm list 2>/dev/null | awk 'NR>1 {print $1}' || true))
    local all_vmids=($(printf "%s\n" "${lxc_vmids[@]:-}" "${kvm_vmids[@]:-}" | sort -n | uniq || true))
    set -e -o pipefail

    local seg_min=$((vmid_min / 100))
    local seg_max=$((vmid_max / 100))
    declare -A kvm_hundred_flag
    
    for vmid in "${kvm_vmids[@]:-}"; do
        if ((vmid >= vmid_min && vmid <= vmid_max)); then
            kvm_hundred_flag[$((vmid / 100))]=1
        fi
    done

    for search_mode in "strict" "fallback"; do
        for seg in $(seq $seg_min $seg_max); do
            if [ "$search_mode" == "strict" ] && [ -n "${kvm_hundred_flag[$seg]+x}" ]; then continue; fi
            
            local seg_start=$((seg*100))
            local seg_end=$((seg_start+99))
            [ $seg_start -lt $vmid_min ] && seg_start=$vmid_min
            [ $seg_end -gt $vmid_max ] && seg_end=$vmid_max
            
            for ((i=seg_start; i<=seg_end; i++)); do
                if [ "$i" != "$OLD_VMID" ] && ! printf '%s\n' "${all_vmids[@]:-}" | grep -qx "$i"; then
                    NEW_VMID=$i
                    log "新LXC容器ID为: $NEW_VMID"
                    return 0
                fi
            done
        done
        [ -n "$NEW_VMID" ] && break
    done

    log "错误：$vmid_min~$vmid_max 范围内均无可用VMID"; exit 1
}

download_firmware() {
    log "正在下载 OpenWrt 最新版本..."
    local wget_output=$(wget -N "$download_url" -P /var/lib/vz/template/cache/ 2>&1 || true)

    if echo "$wget_output" | grep -q "Omitting download"; then
        if [ "$IS_NEW_INSTALL" -eq 1 ]; then
            log "本地已有固件缓存，继续创建。"
        else
            if [[ -t 0 && -t 1 ]]; then
                while :; do
                    read -t 30 -p "固件没有更新。是否强制继续？ [y/n]: " choice || choice="n"
                    case "$choice" in
                        y|Y) break ;;
                        n|N) log "脚本执行中止。"; exit 0 ;;
                        *) echo "请输入 y 或 n。" ;;
                    esac
                done
            else
                log "固件没有更新，自动跳过更新。"; exit 0
            fi
        fi
    else
        log "下载成功"
    fi
}

perform_backup_and_stop_old() {
    if [ "$IS_NEW_INSTALL" -eq 0 ]; then
        if [ "$backup_enabled" = "1" ]; then
            log "创建备份并从旧容器中拉取备份..."
            pct exec "$OLD_VMID" -- sysupgrade -b "$backup_file"
            check_result $? "创建备份失败。"
            pct pull "$OLD_VMID" "$backup_file" "$HOST_BACKUP_FILE"
            check_result $? "从容器中拉取备份失败。"
        fi

        log "停止旧容器以避免网络冲突..."
        pct stop "$OLD_VMID"
        check_result $? "停止旧容器失败。"
    fi
}

provision_and_start_new() {
    log "预创建新容器..."
    local create_args=("$NEW_VMID" "$template" --rootfs "$rootfs" --ostype "$ostype" --hostname "$config_hostname" --arch "$arch" --cores "$cores" --memory "$memory" --swap "$swap" --onboot "$onboot" --unprivileged 0)
    [ -n "$startup" ] && create_args+=(--startup "$startup")
    [ -n "$features" ] && create_args+=(--features "$features")

    if [ -n "$network_configs" ]; then
        read -ra net_arr <<< "$network_configs"
        create_args+=("${net_arr[@]}")
    fi

    pct create "${create_args[@]}"
    check_result $? "创建新容器失败。"

    if [ "$IS_NEW_INSTALL" -eq 1 ]; then
        log "全新容器已成功创建。默认未启动，请进入 Proxmox 面板手动启动。"
        exit 0
    fi

    log "启动新容器..."
    pct start "$NEW_VMID"
    check_result $? "启动新容器失败。"

    log "正在主动轮询等待新容器系统初始化..."
    # 彻底解决环境变量缺失，使用 /bin/sh -c 引导执行原生 ubus 探测
    if ! wait_container_ready "$NEW_VMID" 15 "/bin/sh -c 'ubus call system board'"; then
        log "严重错误：新容器启动后长时间无响应，无法继续执行还原。"
        rollback
    fi
}

perform_restore() {
    if [ "$backup_enabled" = "1" ]; then
        log "在新容器中还原备份..."
        pct push "$NEW_VMID" "$HOST_BACKUP_FILE" "$backup_file"
        check_result $? "将备份推送到新容器失败。"
        pct exec "$NEW_VMID" -- sysupgrade -r "$backup_file"
        check_result $? "在新容器中还原备份失败。"
        
        rm -f "$HOST_BACKUP_FILE"

        # 内存重置标记法：彻底解决软重启假死误判
        log "正在设置内存重置标记..."
        pct exec "$NEW_VMID" -- touch /tmp/reboot_marker
        
        log "通过容器原生指令触发系统软重启..."
        pct exec "$NEW_VMID" -- reboot
        
        log "正在监控内存标记，等待旧系统服务卸载..."
        local offline_count=0
        
        while pct exec "$NEW_VMID" -- test -f /tmp/reboot_marker >/dev/null 2>&1; do
            offline_count=$((offline_count + 1))
            if [ "$offline_count" -ge 20 ]; then
                log "严重警告：容器未响应重启信号，可能发生死锁。"
                rollback
            fi
            sleep 1
        done
        
        log "检测到旧内存已清空，系统已进入重置引导阶段 (耗时约 $offline_count 秒)。"
        
        log "正在等待新容器系统核心总线重新拉起..."
        if ! wait_container_ready "$NEW_VMID" 30 "/bin/sh -c 'ubus call system board'"; then
            log "严重错误：新容器还原配置并重启后无响应。"
            rollback
        fi
    fi
}

verify_network_and_cleanup() {
    if [ "$backup_enabled" = "1" ] && [ "$IS_NEW_INSTALL" -eq 0 ]; then
        log "正在等待代理插件启动并进行海外连通性测试 (目标: $network_check_url)..."
        local max_retries=45
        local retry_count=0
        local network_up=0

        while [ $retry_count -lt $max_retries ]; do
            if pct exec "$NEW_VMID" -- wget -q -O /dev/null -T 1 "$network_check_url" >/dev/null 2>&1; then
                network_up=1
                log "网络已连通！容器海外访问恢复，耗时约 $((retry_count * 2)) 秒。"
                break
            elif curl -s -o /dev/null -m 1 "$network_check_url" >/dev/null 2>&1; then
                network_up=1
                log "网络已连通！宿主机海外访问恢复，耗时约 $((retry_count * 2)) 秒。"
                break
            fi
            retry_count=$((retry_count + 1))
            sleep 2
        done

        if [ "$network_up" -eq 0 ]; then
            while :; do
                read -t 30 -p "海外网络连通性检测失败 (代理可能未启动)。是否继续销毁旧容器？ [y/n]: " choice || choice="n"
                case "$choice" in
                    y|Y) break ;;
                    n|N) log "保留旧容器。你可以手动检查新容器的代理配置，或者重新启动旧容器。"; exit 0 ;;
                    *) echo "请输入 y 或 n。" ;;
                esac
            done
        fi
    fi

    log "正在销毁旧容器 ($OLD_VMID)..."
    pct destroy "$OLD_VMID" --purge
    check_result $? "销毁旧容器失败。"
    log "脚本执行完成。"
}

# ================= 主控制流 =================
main() {
    init_environment
    
    # 1. 解析外部参数，接收 -u 或 -n 强行接管
    parse_args "$@"
    
    # 2. 判断是否执行远程自更新
    check_update "$@"
    
    log "开始执行脚本主流程..."
    [ -f "$CONFIG_FILE" ] && log "已加载外部自定义配置文件: $CONFIG_FILE"
    
    case "$backup_enabled" in
        0) log "备份：已禁用" ;;
        1) log "备份：已启用" ;;
        *) log "备份选项未知，已关闭"; backup_enabled="0" ;;
    esac

    find_target_container
    prepare_container_config
    allocate_new_vmid
    download_firmware
    
    perform_backup_and_stop_old
    provision_and_start_new
    perform_restore
    verify_network_and_cleanup
}

# 启动入口
main "$@"
