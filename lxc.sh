#!/bin/bash
set -euo pipefail
export LC_ALL=C

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

# root 权限检测
[ "$(id -u)" -eq 0 ] || { log "请使用 root 权限运行此脚本"; exit 1; }

# 必要命令检测
for cmd in pct qm wget awk grep sort uniq ping; do
    check_command "$cmd"
done

INI_FILE="$(dirname "$0")/lxc.sh.ini"
if [ ! -f "$INI_FILE" ]; then
    cat > "$INI_FILE" <<EOF
# lxc.sh 配置文件

# VMID分配范围
vmid_min=100
vmid_max=999

# 备份设置
backup_enabled="1"
openclash_enabled="1"

# 容器设置
backup_file="/tmp/backup.tar.gz"
download_url="https://github.com/closur3/OpenWrt-Mainline/releases/latest/download/openwrt-x86-64-generic-rootfs.tar.gz"

# 容器参数
template="local:vztmpl/openwrt-x86-64-generic-rootfs.tar.gz"
rootfs="local-lvm:1"
ostype="unmanaged"
hostname="OpenWrt"
arch="amd64"
cores="2"
memory="1024"
swap="0"
onboot="yes"
startup="order=2"
features="nesting=1"
net0="name=eth0,bridge=vmbr0,firewall=1"

# 网络检测目标
network_check_host="www.qq.com"
network_check_count=3
EOF
    log "检测到首次运行脚本，请先配置 $INI_FILE"
    exit 1
fi

# 读取配置
source "$INI_FILE"

# 参数解析
while [[ $# -gt 0 ]]; do
    case "$1" in
        -off)
            backup_enabled="0"
            openclash_enabled="0"
            ;;
        *)
            log "未知选项：$1"
            exit 1
            ;;
    esac
    shift
done

# 网络连通性检测
check_network_connectivity() {
    local target="${network_check_host:-www.qq.com}"
    local ping_count="${network_check_count:-3}"
    ping -q -c "$ping_count" "$target" >/dev/null
}

# 获取正在运行的容器数量
get_running_container_count() {
    local container_name="$1"
    pct list | awk -v container="$container_name" '$0 ~ container && /running/ {print $1}' | wc -l
}

# 获取正在运行容器的 VMID
get_running_vmid() {
    local container_name="$1"
    pct list | awk -v container="$container_name" '$0 ~ container && /running/ {print $1}'
}

log "开始执行脚本..."

# 备份与 OpenClash 状态输出
case "$backup_enabled" in
    0) log "备份：已禁用"; openclash_enabled="0" ;;
    1) log "备份：已启用" ;;
    *) log "备份选项未知，已关闭"; backup_enabled="0"; openclash_enabled="0" ;;
esac

case "$openclash_enabled" in
    0) log "OpenClash：已禁用" ;;
    1) log "OpenClash：已启用" ;;
    *) log "OpenClash选项未知，已关闭"; openclash_enabled="0" ;;
esac

running_container_count=$(get_running_container_count "$hostname")
if [ "$running_container_count" -eq 0 ]; then
    log "未发现正在运行的 $hostname 容器，请确保至少一个容器正在运行。"
    exit 1
elif [ "$running_container_count" -gt 1 ]; then
    log "有多个 $hostname 容器正在运行，请确保只有一个容器正在运行。"
    exit 1
fi

running_vmid=$(get_running_vmid "$hostname")
if [ -z "$running_vmid" ]; then
    log "错误：无法确定运行中的 VMID。"
    exit 1
fi

# 自动分配新容器ID，确保与KVM不在同一百段并取最小空闲段
lxc_vmids=($(pct list | awk 'NR>1 {print $1}'))
kvm_vmids=($(qm list | awk 'NR>1 {print $1}'))
all_vmids=($(printf "%s\n" "${lxc_vmids[@]}" "${kvm_vmids[@]}" | sort -n | uniq))

old_container_id="$running_vmid"

vmid_min=${vmid_min:-100}
vmid_max=${vmid_max:-999}
seg_min=$((vmid_min / 100))
seg_max=$((vmid_max / 100))

declare -A kvm_hundred_flag
for vmid in "${kvm_vmids[@]}"; do
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
            if [ "$i" != "$old_container_id" ] && ! printf '%s\n' "${all_vmids[@]}" | grep -qx "$i"; then
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
            if [ "$i" != "$old_container_id" ] && ! printf '%s\n' "${all_vmids[@]}" | grep -qx "$i"; then
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
log "旧LXC容器ID为: $old_container_id"
log "新LXC容器ID为: $new_container_id"

# 下载 OpenWrt 最新版本
log "正在下载 OpenWrt 最新版本..."
wget_output=$(wget -N "$download_url" -P /var/lib/vz/template/cache/ 2>&1 || true)

if echo "$wget_output" | grep -q "Omitting download"; then
    if [[ -t 0 && -t 1 ]]; then
        while :; do
            read -t 30 -p "固件没有更新。是否强制继续？ [y/n]: " choice
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
else
    log "下载成功"
fi

# 创建备份
if [ "$backup_enabled" = "1" ]; then
    log "创建备份并从旧容器中拉取备份..."
    pct exec $old_container_id -- sysupgrade -b "$backup_file"
    check_result $? "创建备份失败。"
    pct pull $old_container_id "$backup_file" ~/backup.tar.gz
    check_result $? "从容器中拉取备份失败。"
else
    log "未启用备份，将跳过备份步骤。"
fi

# 预创建新容器
log "预创建新容器..."
pct create $new_container_id "$template" \
    --rootfs "$rootfs" --ostype "$ostype" --hostname "$hostname" --arch "$arch" \
    --cores "$cores" --memory "$memory" --swap "$swap" --onboot "$onboot" \
    --startup "$startup" --features "$features" --net0 "$net0"
check_result $? "创建新容器失败。"

# 停止旧容器
log "停止旧容器..."
pct stop $old_container_id
check_result $? "停止旧容器失败。"

# 启动新容器
log "启动新容器..."
pct start $new_container_id
check_result $? "启动新容器失败。"
sleep 3

# 还原备份
if [ "$backup_enabled" = "1" ]; then
    log "在新容器中还原备份..."
    pct push $new_container_id ~/backup.tar.gz "$backup_file"
    check_result $? "将备份推送到新容器失败。"
    pct exec $new_container_id -- sysupgrade -r "$backup_file"
    check_result $? "在新容器中还原备份失败。"
    sleep 3
fi

# 启动 OpenClash
if [ "$openclash_enabled" = "1" ]; then
    log "在新容器中启动 OpenClash..."
    pct exec $new_container_id -- uci set openclash.config.enable='1'
    pct exec $new_container_id -- uci commit openclash
    pct exec $new_container_id -- /etc/init.d/openclash start
    check_result $? "在新容器中启动 OpenClash 失败。"
fi

# 网络连通性测试
if [ "$backup_enabled" = "1" ]; then
    log "当前网络检测目标: $network_check_host"
    if ! check_network_connectivity; then
        while :; do
            read -t 30 -p "网络连通性检测失败。是否继续销毁旧容器？ [y/n]: " choice
            case "$choice" in
                y|Y) break ;;
                n|N) log "不销毁旧容器。"; exit 0 ;;
                *) echo "请输入 y 或 n。" ;;
            esac
        done
    fi
fi

# 销毁旧容器
log "正在销毁旧容器..."
pct destroy $old_container_id --purge
check_result $? "销毁旧容器失败。"

log "脚本执行完成。"
