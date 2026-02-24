#!/bin/bash
set -euo pipefail
export LC_ALL=C

############################# 配置项 #############################
# 脚本在线地址（用于自动更新）
SCRIPT_URL="https://raw.githubusercontent.com/closur3/LXC-OpenWrt-Upgrade/main/lxc.sh"

# VMID分配范围
vmid_min=100
vmid_max=999

# 备份设置
backup_enabled="1"

# 容器设置
backup_file="/tmp/backup.tar.gz"
download_url="https://github.com/closur3/OpenWrt-Mainline/releases/latest/download/openwrt-x86-64-generic-rootfs.tar.gz"

# 容器参数（全新创建时提供默认值）
template="local:vztmpl/openwrt-x86-64-generic-rootfs.tar.gz"
rootfs="local-lvm:1"
hostname="OpenWrt"
ostype=""
arch=""
cores=""
memory=""
swap=""
onboot=""
startup=""
features=""
network_configs=""

# 网络检测目标 (使用海外 204 页面，精准测试代理是否生效)
network_check_url="https://www.google.com/generate_204"
############################# 配置项 #############################

# 日志函数
log() {
    echo "[$(basename "$0") $(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# 检查命令执行结果
check_result() {
    local code=$1 msg=$2
    if [ "$code" -ne 0 ]; then
        log "错误：$msg"
        exit 1
    fi
}

# 检查命令是否存在
check_command() {
    command -v "$1" >/dev/null 2>&1 || { log "缺少必要命令: $1"; exit 1; }
}

# 读取配置参数
get_container_config() {
    local vmid=$1
    local config_file="/etc/pve/lxc/${vmid}.conf"
    if [ ! -f "$config_file" ]; then
        log "错误：无法找到容器 $vmid 的配置文件"
        exit 1
    fi

    local current_config
    current_config=$(awk '/^\[.*\]/{exit} {print}' "$config_file")

    if [ -z "$ostype" ]; then ostype=$(echo "$current_config" | grep "^ostype:" | head -1 | cut -d: -f2 | xargs); fi
    if [ -z "$arch" ]; then arch=$(echo "$current_config" | grep "^arch:" | head -1 | cut -d: -f2 | xargs); fi
    if [ -z "$cores" ]; then cores=$(echo "$current_config" | grep "^cores:" | head -1 | cut -d: -f2 | xargs); fi
    if [ -z "$memory" ]; then memory=$(echo "$current_config" | grep "^memory:" | head -1 | cut -d: -f2 | xargs); fi
    if [ -z "$swap" ]; then swap=$(echo "$current_config" | grep "^swap:" | head -1 | cut -d: -f2 | xargs); fi
    if [ -z "$onboot" ]; then onboot=$(echo "$current_config" | grep "^onboot:" | head -1 | cut -d: -f2 | xargs); fi
    if [ -z "$startup" ]; then startup=$(echo "$current_config" | grep "^startup:" | head -1 | cut -d: -f2- | xargs); fi
    if [ -z "$features" ]; then features=$(echo "$current_config" | grep "^features:" | head -1 | cut -d: -f2- | xargs); fi

    if [ -z "$network_configs" ]; then
        network_configs=""
        while IFS= read -r line; do
            if [[ "$line" =~ ^net[0-9]+: ]]; then
                net_key=$(echo "$line" | cut -d: -f1)
                net_value=$(echo "$line" | cut -d: -f2- | xargs)
                net_value_clean=$(echo "$net_value" | sed 's/,hwaddr=[^,]*//g' | sed 's/hwaddr=[^,]*,//g' | sed 's/hwaddr=[^,]*$//g')
                network_configs="$network_configs --${net_key} $net_value_clean"
            fi
        done <<< "$current_config"
    fi
}

# root 权限检测
[ "$(id -u)" -eq 0 ] || { log "请使用 root 权限运行此脚本"; exit 1; }

# 检查依赖（已加入 curl 用于宿主机代理检测）
for cmd in pct qm wget curl awk grep sort uniq md5sum cat rm chmod; do
    check_command "$cmd"
done

# 自动检查并更新脚本
check_update() {
    log "正在检查脚本更新..."
    local temp_file="/tmp/lxc_update_remote.sh"
    
    # 使用 wget 静默下载并设置 5 秒超时
    if wget -q -T 5 -O "$temp_file" "$SCRIPT_URL"; then
        local local_md5
        local remote_md5
        local_md5=$(md5sum "$0" | awk '{print $1}')
        remote_md5=$(md5sum "$temp_file" | awk '{print $1}')
        
        if [ "$local_md5" != "$remote_md5" ]; then
            log "🎉 发现新版本脚本！正在自动覆盖更新..."
            cat "$temp_file" > "$0"
            chmod +x "$0"
            rm -f "$temp_file"
            log "✅ 更新完成！正在应用新版本重启脚本..."
            # 替换当前进程，并传递所有原有参数
            exec "$0" "$@"
        else
            log "当前已是最新版本。"
        fi
        rm -f "$temp_file"
    else
        log "⚠️ 检查更新失败（可能是网络超时或访问受限），将继续运行当前版本。"
    fi
}

# 触发更新检查（带上启动参数以防重启丢失参数）
check_update "$@"

# 参数解析
while [[ $# -gt 0 ]]; do
    case "$1" in
        -off) backup_enabled="0" ;;
        *) log "未知选项：$1"; exit 1 ;;
    esac
    shift
done

log "开始执行脚本主流程..."

case "$backup_enabled" in
    0) log "备份：已禁用" ;;
    1) log "备份：已启用" ;;
    *) log "备份选项未知，已关闭"; backup_enabled="0" ;;
esac

config_hostname="${hostname:-OpenWrt}"

existing_vmids=$(pct list | awk -v container="$config_hostname" 'NR>1 && $3 == container {print $1}')
container_count=$(echo "$existing_vmids" | awk 'NF' | wc -l)

is_new_install=0
old_container_id=""

if [ "$container_count" -eq 0 ]; then
    log "未发现名为 $config_hostname 的容器。"
    if [[ -t 0 && -t 1 ]]; then
        while :; do
            read -t 30 -p "是否要创建一个全新的 $config_hostname 容器？ [y/n]: " choice || choice="n"
            case "$choice" in
                y|Y) 
                    log "开始引导创建全新容器..."
                    is_new_install=1
                    break ;;
                n|N) 
                    log "脚本执行中止。"
                    exit 0 ;;
                *) echo "请输入 y 或 n。" ;;
            esac
        done
    else
        log "非交互式环境，跳过全新创建。"
        exit 1
    fi
elif [ "$container_count" -gt 1 ]; then
    log "有多个名为 $config_hostname 的容器，请确保环境中只有一个目标容器。"
    exit 1
else
    old_container_id=$(echo "$existing_vmids" | head -n 1)
    if ! pct status "$old_container_id" | grep -q "running"; then
        log "容器 $old_container_id 未运行。请先启动该容器以确保可以进行备份和升级。"
        exit 1
    fi
fi

if [ "$is_new_install" -eq 1 ]; then
    ostype=${ostype:-unmanaged}
    arch=${arch:-amd64}
    cores=${cores:-2}
    memory=${memory:-1024}
    swap=${swap:-0}
    onboot=${onboot:-1}
    features=${features:-"nesting=1"}
    network_configs=${network_configs:-"--net0 name=eth0,bridge=vmbr0"}
else
    get_container_config "$old_container_id"
    log "旧LXC容器ID为: $old_container_id"
    host_backup_file="/tmp/openwrt_backup_${old_container_id}.tar.gz"
fi

lxc_vmids=($(pct list | awk 'NR>1 {print $1}'))
kvm_vmids=($(qm list | awk 'NR>1 {print $1}'))
all_vmids=($(printf "%s\n" "${lxc_vmids[@]:-}" "${kvm_vmids[@]:-}" | sort -n | uniq))

vmid_min=${vmid_min:-100}
vmid_max=${vmid_max:-999}
seg_min=$((vmid_min / 100))
seg_max=$((vmid_max / 100))

declare -A kvm_hundred_flag
for vmid in "${kvm_vmids[@]:-}"; do
    if ((vmid >= vmid_min && vmid <= vmid_max)); then
        segment=$((vmid / 100))
        kvm_hundred_flag[$segment]=1
    fi
done

new_container_id=""
for seg in $(seq $seg_min $seg_max); do
    seg_start=$((seg*100))
    seg_end=$((seg_start+99))
    [ $seg_start -lt $vmid_min ] && seg_start=$vmid_min
    [ $seg_end -gt $vmid_max ] && seg_end=$vmid_max
    if [ -z "${kvm_hundred_flag[$seg]+x}" ]; then
        for ((i=seg_start; i<=seg_end; i++)); do
            if [ "$i" != "$old_container_id" ] && ! printf '%s\n' "${all_vmids[@]:-}" | grep -qx "$i"; then
                new_container_id=$i
                break 2
            fi
        done
    fi
done

if [ -z "$new_container_id" ]; then
    for seg in $(seq $seg_min $seg_max); do
        seg_start=$((seg*100))
        seg_end=$((seg_start+99))
        [ $seg_start -lt $vmid_min ] && seg_start=$vmid_min
        [ $seg_end -gt $vmid_max ] && seg_end=$vmid_max
        for ((i=seg_start; i<=seg_end; i++)); do
            if [ "$i" != "$old_container_id" ] && ! printf '%s\n' "${all_vmids[@]:-}" | grep -qx "$i"; then
                new_container_id=$i
                break 2
            fi
        done
    done
fi

if [ -z "$new_container_id" ]; then
    log "错误：$vmid_min~$vmid_max 范围内均无可用VMID"
    exit 1
fi
log "新LXC容器ID为: $new_container_id"

log "正在下载 OpenWrt 最新版本..."
wget_output=$(wget -N "$download_url" -P /var/lib/vz/template/cache/ 2>&1 || true)

if echo "$wget_output" | grep -q "Omitting download"; then
    if [ "$is_new_install" -eq 1 ]; then
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
            log "固件没有更新，在非交互式环境中自动跳过更新。"
            exit 0
        fi
    fi
else
    log "下载成功"
fi

# 升级模式下的备份与旧容器启停逻辑
if [ "$is_new_install" -eq 0 ]; then
    if [ "$backup_enabled" = "1" ]; then
        log "创建备份并从旧容器中拉取备份..."
        pct exec $old_container_id -- sysupgrade -b "$backup_file"
        check_result $? "创建备份失败。"
        pct pull $old_container_id "$backup_file" "$host_backup_file"
        check_result $? "从容器中拉取备份失败。"
    fi

    log "停止旧容器以避免网络冲突..."
    pct stop $old_container_id
    check_result $? "停止旧容器失败。"
fi

# 使用数组动态构建 pct create 命令参数（安全可靠）
log "预创建新容器..."
create_args=(
    "$new_container_id" "$template"
    --rootfs "$rootfs"
    --ostype "$ostype"
    --hostname "$config_hostname"
    --arch "$arch"
    --cores "$cores"
    --memory "$memory"
    --swap "$swap"
    --onboot "$onboot"
    --unprivileged 0
)

[ -n "$startup" ] && create_args+=(--startup "$startup")
[ -n "$features" ] && create_args+=(--features "$features")

# 将网络配置字符串按空格拆分并追加到数组中
if [ -n "$network_configs" ]; then
    read -ra net_arr <<< "$network_configs"
    create_args+=("${net_arr[@]}")
fi

pct create "${create_args[@]}"
check_result $? "创建新容器失败。"

# 修改：如果是全新安装，创建完毕后直接退出，不启动容器
if [ "$is_new_install" -eq 1 ]; then
    log "全新容器已成功创建并启动，请进入 Proxmox 面板或使用终端进行后续配置。"
    exit 0
fi

log "启动新容器..."
pct start $new_container_id
check_result $? "启动新容器失败。"
sleep 3

# 还原备份（升级模式）
if [ "$backup_enabled" = "1" ]; then
    log "在新容器中还原备份..."
    pct push $new_container_id "$host_backup_file" "$backup_file"
    check_result $? "将备份推送到新容器失败。"
    pct exec $new_container_id -- sysupgrade -r "$backup_file"
    check_result $? "在新容器中还原备份失败。"
    
    # 清理宿主机的临时备份文件
    rm -f "$host_backup_file"

    log "重启新容器以应用所有更改..."
    pct exec $new_container_id -- reboot
fi

# 轮询网络连通性测试 (应用层TCP测试)
if [ "$backup_enabled" = "1" ] && [ "$is_new_install" -eq 0 ]; then
    log "正在等待代理插件启动并进行海外连通性测试 (目标: $network_check_url)..."
    
    # 代理软件启动通常较慢，将最大重试次数增加到 30 次 (约 90 秒)
    max_retries=30  
    retry_count=0
    network_up=0

    while [ $retry_count -lt $max_retries ]; do
        # 优先在容器内部发起 HTTP 请求，使用 OpenWrt 自带的 wget
        if pct exec $new_container_id -- wget -q -O /dev/null -T 3 "$network_check_url" >/dev/null 2>&1; then
            network_up=1
            log "网络已连通！容器海外访问恢复，耗时约 $((retry_count * 3)) 秒。"
            break
            
        # 备选：如果容器自身网络不走代理，但宿主机(PVE)的网关指向了OpenWrt，则使用宿主机的 curl 测试
        elif curl -s -o /dev/null -m 3 "$network_check_url" >/dev/null 2>&1; then
            network_up=1
            log "网络已连通！宿主机海外访问恢复，耗时约 $((retry_count * 3)) 秒。"
            break
        fi

        retry_count=$((retry_count + 1))
        sleep 3
    done

    if [ "$network_up" -eq 0 ]; then
        while :; do
            read -t 30 -p "海外网络连通性检测失败 (代理可能未启动)。是否继续销毁旧容器？ [y/n]: " choice || choice="n"
            case "$choice" in
                y|Y) break ;;
                n|N) 
                    log "保留旧容器。你可以手动检查新容器的代理插件配置，或者重新启动旧容器。"
                    exit 0 ;;
                *) echo "请输入 y 或 n。" ;;
            esac
        done
    fi
fi

# 销毁旧容器
log "正在销毁旧容器 ($old_container_id)..."
pct destroy $old_container_id --purge
check_result $? "销毁旧容器失败。"

log "脚本执行完成。"
