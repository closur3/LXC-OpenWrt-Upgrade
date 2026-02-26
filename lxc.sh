#!/bin/bash
set -euo pipefail
export LC_ALL=C

############################# 全局配置项 #############################
SCRIPT_URL="https://raw.githubusercontent.com/closur3/LXC-OpenWrt-Upgrade/main/lxc.sh"
vmid_min=100
vmid_max=999
backup_enabled="1"
backup_file="/tmp/backup.tar.gz"
download_url="https://github.com/closur3/OpenWrt-Mainline/releases/latest/download/openwrt-x86-64-generic-rootfs.tar.gz"
network_check_url="https://www.google.com/generate_204"

# 容器默认/基础参数
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

# 运行时状态变量（全局共享）
IS_NEW_INSTALL=0
OLD_VMID=""
NEW_VMID=""
HOST_BACKUP_FILE=""
######################################################################

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

# 统一的故障回滚机制
rollback() {
    log "正在启动故障保护：关闭新容器，回滚启动旧容器..."
    pct stop "$NEW_VMID" 2>/dev/null || true
    [ -n "$OLD_VMID" ] && pct start "$OLD_VMID" 2>/dev/null || true
    exit 1
}

# 智能轮询等待容器就绪 (支持自定义探测命令)
wait_container_ready() {
    local vmid=$1
    local max_retries=${2:-30}
    local check_cmd=${3:-"true"} # 默认执行 true，也可传入更高阶的检查命令
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

check_update() {
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

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -off) backup_enabled="0" ;;
            *) log "未知选项：$1"; exit 1 ;;
        esac
        shift
    done

    case "$backup_enabled" in
        0) log "备份：已禁用" ;;
        1) log "备份：已启用" ;;
        *) log "备份选项未知，已关闭"; backup_enabled="0" ;;
    esac
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
        log "全新容器已成功创建。默认未启动，请进入 Proxmox 面板或使用终端配置网络后再手动启动。"
        exit 0
    fi

    log "启动新容器..."
    pct start "$NEW_VMID"
    check_result $? "启动新容器失败。"

    log "正在主动轮询等待新容器系统初始化..."
    # 核心组件检查：ubus call system board
    if ! wait_container_ready "$NEW_VMID" 15 "ubus call system board"; then
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

        # ================= 终极精准轮询方案：内存标记法 =================
        log "正在设置内存重置标记..."
        # /tmp 在 OpenWrt 中是 tmpfs (内存盘)，系统一旦重启必定清空
        pct exec "$NEW_VMID" -- touch /tmp/reboot_marker
        
        log "通过容器原生指令触发系统软重启..."
        pct exec "$NEW_VMID" -- reboot
        
        log "正在监控内存标记，等待旧系统服务卸载..."
        local offline_count=0
        
        # 只要文件还在且能连通，就说明重启还没真正发生
        # 一旦文件消失(内存清空) 或 pct exec 连不上(进程隔离重置)，立刻跳出循环！
        while pct exec "$NEW_VMID" -- test -f /tmp/reboot_marker >/dev/null 2>&1; do
            offline_count=$((offline_count + 1))
            if [ "$offline_count" -ge 20 ]; then
                log "严重警告：容器未响应重启信号，可能发生死锁。"
                rollback
            fi
            sleep 1
        done
        
        log "检测到旧内存已清空，系统已进入重置引导阶段 (耗时约 $offline_count 秒)。"
        
        log "正在等待新容器 ubus 核心总线重新拉起..."
        if ! wait_container_ready "$NEW_VMID" 30 "ubus call system board"; then
            log "严重错误：新容器还原配置并重启后无响应。"
            rollback
        fi
        # ================================================================
    fi
}

verify_network_and_cleanup() {
    if [ "$backup_enabled" = "1" ] && [ "$IS_NEW_INSTALL" -eq 0 ]; then
        log "正在等待代理插件启动并进行海外连通性测试 (目标: $network_check_url)..."
        local max_retries=30
        local retry_count=0
        local network_up=0

        while [ $retry_count -lt $max_retries ]; do
            # 设置极短的 1 秒超时时间，避免叠加导致的 6 分钟延迟漏洞
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
    check_update "$@"
    
    log "开始执行脚本主流程..."
    parse_args "$@"
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
