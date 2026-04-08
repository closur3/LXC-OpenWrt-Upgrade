#!/bin/bash
set -euo pipefail
export LC_ALL=C

###############################################################################
# 默认配置（请在同目录 .conf 覆盖，不要直接改本文件）
###############################################################################
SCRIPT_URL="https://raw.githubusercontent.com/closur3/LXC-OpenWrt-Upgrade/main/lxc.sh"
auto_update="1"
vmid_min=100
vmid_max=999
backup_enabled="1"
backup_file="/tmp/backup.tar.gz"
download_url="https://github.com/closur3/OpenWrt-Mainline/releases/latest/download/openwrt-x86-64-generic-rootfs.tar.gz"
network_check_url="https://www.google.com/generate_204"

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

###############################################################################
# 运行时状态
###############################################################################
IS_NEW_INSTALL=0
OLD_VMID=""
NEW_VMID=""
HOST_BACKUP_FILE=""
FIRMWARE_STATUS="unknown"
DRY_RUN=0
FORCE_SAME_VERSION_UPGRADE=0
UPDATE_ONLY=0
SCRIPT_ABS_PATH=""
CONFIG_FILE=""
EXAMPLE_FILE=""

# ================= 基础工具函数 =================

log() {
    echo "[$(basename "$0") $(date +'%Y-%m-%d %H:%M:%S')] $*"
}

die() {
    log "错误：$*"
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少必要命令: $1"
}

show_help() {
    cat << 'EOF'
用法:
  bash lxc.sh [选项]

选项:
  -n, --no-backup   跳过备份与恢复
  -u, --update      仅执行脚本自更新，然后退出
  -f, --force       即使固件版本未变化，也强制继续迁移流程
  -d, --dry-run     仅检查流程与条件，不执行任何变更操作
  -h, --help        显示本帮助并退出
EOF
}

init_paths() {
    local script_dir script_name
    script_dir=$(cd "$(dirname "$0")" && pwd)
    script_name=$(basename "$0")
    SCRIPT_ABS_PATH="${script_dir}/${script_name}"
    CONFIG_FILE="${SCRIPT_ABS_PATH%.*}.conf"
    EXAMPLE_FILE="${SCRIPT_ABS_PATH%.*}.conf.example"
}

ensure_example_config() {
    [ -f "$CONFIG_FILE" ] && return 0
    cat << 'EOF' > "$EXAMPLE_FILE"
# =================================================================
# LXC OpenWrt 自动升级脚本 - 全量配置参考手册 (Example)
# =================================================================
# 自动检查更新开关
# auto_update="1"
# vmid 范围
# vmid_min=100
# vmid_max=999
# 是否开启备份
# backup_enabled="1"
# 连通性测试地址
# network_check_url="https://www.google.com/generate_204"
# 存储池
# rootfs="local-lvm:1"
# CPU/内存
# cores="2"
# memory="1024"
# swap="0"
# 网络配置
# network_configs="--net0 name=eth0,bridge=vmbr0"
# 容器特性
# features="nesting=1"
EOF
}

load_user_config() {
    [ -f "$CONFIG_FILE" ] || return 0
    set +u
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    set -u
}

rollback() {
    log "正在启动故障保护：回滚启动旧容器，并彻底清理失败的新容器..."
    
    # 1. 如果新容器已经分配了 ID，就停止并销毁它
    if [ -n "$NEW_VMID" ]; then
        pct stop "$NEW_VMID" 2>/dev/null || true
        pct destroy "$NEW_VMID" --purge 2>/dev/null || true
        log "已清理残留的失败容器 ($NEW_VMID)。"
    fi
    
    # 2. 重新拉起旧容器恢复网络
    if [ -n "$OLD_VMID" ]; then
        pct start "$OLD_VMID" 2>/dev/null || true
        log "旧容器 ($OLD_VMID) 已重新启动，网络已恢复。"
    fi
    
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
    [ "$(id -u)" -eq 0 ] || die "请使用 root 权限运行此脚本"
    for cmd in pct qm wget curl awk grep sort uniq md5sum cat rm chmod gzip tar mv sed cut xargs seq wc mkdir dirname basename; do
        require_cmd "$cmd"
    done
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--no-backup) backup_enabled="0" ;; # 命令行强制跳过备份
            -u|--update) UPDATE_ONLY=1; auto_update="1" ;; # 仅更新脚本并退出
            -f|--force) FORCE_SAME_VERSION_UPGRADE=1 ;; # 命令行强制同版本也执行迁移
            -d|--dry-run) DRY_RUN=1 ;;            # 仅检查流程，不做任何变更
            -h|--help) show_help; exit 0 ;;
            *) log "未知选项：$1"; echo; show_help; exit 1 ;;
        esac
        shift
    done
}

self_update() {
    local force_update="${1:-0}"
    shift || true

    if [ "$DRY_RUN" -eq 1 ] && [ "$force_update" -ne 1 ]; then
        log "dry-run 模式：跳过脚本自更新。"
        return 0
    fi

    if [ "$auto_update" != "1" ] && [ "$force_update" -ne 1 ]; then
        log "自动更新已禁用，直接运行本地版本。"
        return 0
    fi

    log "正在检查脚本更新..."
    local temp_file="/tmp/lxc_update_remote.sh"

    rm -f "$temp_file"
    if ! wget -q -T 8 -O "$temp_file" "$SCRIPT_URL"; then
        rm -f "$temp_file"
        if [ "$force_update" -eq 1 ]; then
            die "检查更新失败，无法完成仅更新模式。"
        fi
        log "检查更新失败，将继续运行当前版本。"
        return 0
    fi

    if ! grep -q "^#!/bin/bash" "$temp_file"; then
        rm -f "$temp_file"
        if [ "$force_update" -eq 1 ]; then
            die "下载的更新脚本验证失败，已终止。"
        fi
        log "下载的文件验证失败，跳过更新。"
        return 0
    fi

    local local_md5 remote_md5
    local_md5=$(md5sum "$SCRIPT_ABS_PATH" | awk '{print $1}')
    remote_md5=$(md5sum "$temp_file" | awk '{print $1}')
    if [ "$local_md5" = "$remote_md5" ]; then
        rm -f "$temp_file"
        log "当前已是最新版本。"
        return 0
    fi

    log "发现新版本脚本，正在覆盖更新..."
    cat "$temp_file" > "$SCRIPT_ABS_PATH"
    chmod +x "$SCRIPT_ABS_PATH"
    rm -f "$temp_file"
    log "更新完成，正在重启脚本应用新版本..."
    exec "$SCRIPT_ABS_PATH" "$@"
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

validate_firmware_archive() {
    local file="$1"
    [ -s "$file" ] || return 1
    gzip -t "$file" >/dev/null 2>&1 || return 1
    tar -tzf "$file" >/dev/null 2>&1 || return 1
    return 0
}

resolve_latest_firmware_url() {
    local effective_url
    effective_url=$(curl -fsSIL -o /dev/null -w '%{url_effective}' "$download_url" 2>/dev/null || true)
    [ -n "$effective_url" ] || return 1
    printf '%s\n' "$effective_url"
    return 0
}

normalize_firmware_source_id() {
    local url="$1"
    # GitHub release-assets URL includes expiring query params (jwt/se/sig).
    # We only keep the stable URL body for version comparison.
    printf '%s\n' "${url%%\?*}"
}

download_firmware() {
    log "正在下载 OpenWrt 最新版本..."
    local cache_dir="/var/lib/vz/template/cache"
    local firmware_file="$cache_dir/openwrt-x86-64-generic-rootfs.tar.gz"
    local temp_file="${firmware_file}.download.$$"
    local state_file="${firmware_file}.source_url"
    local latest_url=""
    local latest_source_id=""
    local cached_source_id=""

    mkdir -p "$cache_dir"
    rm -f "$temp_file"

    if [ -f "$state_file" ]; then
        cached_source_id=$(cat "$state_file" 2>/dev/null || true)
    fi

    if latest_url=$(resolve_latest_firmware_url); then
        latest_source_id=$(normalize_firmware_source_id "$latest_url")
        if [ "$latest_source_id" = "$cached_source_id" ] && validate_firmware_archive "$firmware_file"; then
            FIRMWARE_STATUS="same"
            log "检测到固件版本未变化，且本地缓存可用，跳过下载。"
            return 0
        fi
    else
        log "版本探测失败，尝试使用本地缓存固件..."
        if validate_firmware_archive "$firmware_file"; then
            FIRMWARE_STATUS="unknown"
            log "本地缓存固件可用，继续执行。"
            return 0
        fi
        log "错误：无法探测最新版本，且本地缓存不可用。"
        exit 1
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        FIRMWARE_STATUS="new"
        log "dry-run 模式：检测到可能有新固件，将跳过实际下载。"
        return 0
    fi

    if wget --tries=2 --timeout=15 --dns-timeout=5 --connect-timeout=5 --read-timeout=15 -O "$temp_file" "$latest_url"; then
        if validate_firmware_archive "$temp_file"; then
            mv -f "$temp_file" "$firmware_file"
            printf '%s\n' "$latest_source_id" > "$state_file"
            FIRMWARE_STATUS="new"
            log "下载成功，且固件完整性校验通过。"
            return 0
        fi
        rm -f "$temp_file"
        log "错误：下载得到的固件文件不完整或已损坏（GitHub 不可达时常见）。"
        exit 1
    fi

    rm -f "$temp_file"
    log "下载失败，尝试使用本地缓存固件..."
    if validate_firmware_archive "$firmware_file"; then
        log "本地缓存固件可用，继续执行。"
        return 0
    fi

    log "错误：下载失败且本地缓存固件不可用，终止执行以避免停机后升级失败。"
    exit 1
}

perform_backup_and_stop_old() {
    if [ "$IS_NEW_INSTALL" -eq 0 ]; then
        if [ "$backup_enabled" = "1" ]; then
            log "创建备份并从旧容器中拉取备份..."
            pct exec "$OLD_VMID" -- sysupgrade -b "$backup_file" || die "创建备份失败。"
            pct pull "$OLD_VMID" "$backup_file" "$HOST_BACKUP_FILE" || die "从容器中拉取备份失败。"
        fi

        log "停止旧容器以避免网络冲突..."
        pct stop "$OLD_VMID" || die "停止旧容器失败。"
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

    if ! pct create "${create_args[@]}"; then
        log "创建新容器失败，触发回滚。"
        rollback
    fi

    if [ "$IS_NEW_INSTALL" -eq 1 ]; then
        log "全新容器已成功创建。默认未启动，请进入 Proxmox 面板手动启动。"
        exit 0
    fi

    log "启动新容器..."
    pct start "$NEW_VMID" || die "启动新容器失败。"

    log "正在主动轮询等待新容器系统初始化..."
    # 彻底解决环境变量缺失，使用 /bin/sh -c 引导执行原生 ubus 探测
    if ! wait_container_ready "$NEW_VMID" 15 "/bin/ubus call system board"; then
        log "严重错误：新容器启动后长时间无响应，无法继续执行还原。"
        rollback
    fi
}

perform_restore() {
    if [ "$backup_enabled" = "1" ]; then
        log "在新容器中还原备份..."
        pct push "$NEW_VMID" "$HOST_BACKUP_FILE" "$backup_file" || die "将备份推送到新容器失败。"
        pct exec "$NEW_VMID" -- sysupgrade -r "$backup_file" || die "在新容器中还原备份失败。"
        
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
        if ! wait_container_ready "$NEW_VMID" 30 "/bin/ubus call system board"; then
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
    pct destroy "$OLD_VMID" --purge || die "销毁旧容器失败。"
    log "脚本执行完成。"
}

run_upgrade_flow() {
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

    if [ "$IS_NEW_INSTALL" -eq 0 ] && [ "$FIRMWARE_STATUS" = "same" ] && [ "$FORCE_SAME_VERSION_UPGRADE" -ne 1 ]; then
        log "固件版本未变化，默认跳过本次升级迁移（避免无意义切换容器）。"
        log "如需强制同版本重装，可使用 --force。"
        exit 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log "dry-run 模式：检查完成。后续将执行备份、停旧容器、创建新容器、恢复并切换。"
        exit 0
    fi
    
    perform_backup_and_stop_old
    provision_and_start_new
    perform_restore
    verify_network_and_cleanup
}

main() {
    init_paths
    ensure_example_config
    load_user_config
    parse_args "$@"
    init_environment

    self_update "$UPDATE_ONLY" "$@"
    if [ "$UPDATE_ONLY" -eq 1 ]; then
        log "仅更新模式执行完成，脚本已退出。"
        exit 0
    fi

    run_upgrade_flow
}

# 启动入口
main "$@"
