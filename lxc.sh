#!/bin/bash

# 默认值
backup_and_clash="1"

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        -off)
            backup_and_clash="0"
            shift
            ;;
        *)
            echo "未知选项：$1"
            exit 1
            ;;
    esac
done

# 设置变量
container_ids=(110 111)
backup_file="/tmp/backup.tar.gz"
download_url="https://github.com/closur3/OpenWrt-Mainline/releases/latest/download/openwrt-x86-64-generic-rootfs.tar.gz"

# 容器参数
template="local:vztmpl/openwrt-x86-64-generic-rootfs.tar.gz"
rootfs="local-lvm:1"
ostype="unmanaged"
hostname="OpenWrt"
arch="amd64"
cores=2
memory=1024
swap=0
onboot="yes"
features="nesting=1"
net0="name=eth0,bridge=vmbr0,firewall=1"

# 函数：记录日志
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# 函数：检查命令执行结果
check_result() {
    if [ $1 -ne 0 ]; then
        log "Error: $2"
        try_restart_old_container
        exit 1
    fi
}

# 函数：尝试重新启动旧容器
try_restart_old_container() {
    local old_container_status=$(pct status $old_container_id | grep -oP 'status: \K(\w+)')
    if [ "$old_container_status" != "running" ]; then
        log "Old container is not running. Attempting to restart..."
        pct start $old_container_id
        local start_result=$?
        if [ $start_result -ne 0 ]; then
            log "Failed to restart old container."
        else
            log "Old container restarted successfully."
        fi
    else
        log "Old container is already running. No need to restart."
    fi
}

# 函数：获取正在运行的容器的 VMID
get_running_vmid() {
    pct list | grep OpenWrt | awk '{print $1}'
}

# 开始执行脚本
log "Starting script..."

# 检查备份是否开启
if [ "$backup_and_clash" == "0" ]; then
    log "Backup & Start OpenClash: disabled"
else
    log "Backup & Start OpenClash: enabled"
fi

# 获取正在运行的容器的 VMID
running_vmid=$(get_running_vmid)

# 根据正在运行的容器的 VMID 确定旧容器ID和新容器ID
old_container_id=${container_ids[0]}
new_container_id=${container_ids[1]}
if [ "$running_vmid" == "${container_ids[1]}" ]; then
    old_container_id=${container_ids[1]}
    new_container_id=${container_ids[0]}
elif [ -z "$running_vmid" ]; then
    log "Error: Cannot determine running VMID."
    exit 1
fi

# 下载最新的 OpenWrt 发布
log "Downloading OpenWrt release..."
wget_output=$(wget -N $download_url -P /var/lib/vz/template/cache/ 2>&1)
if echo "$wget_output" | grep -q "Omitting download"; then
    read -t 30 -p "The firmware doesn't seem to be updated. Do you want to continue? [y/n]: " choice
    if [ "$choice" != "y" ]; then
        log "Script execution aborted due to timeout or user input."
        exit 0
    fi
else
    log "Download successful."	
fi

# 创建备份并从容器中拉取备份
if [ "$backup_and_clash" == "1" ]; then
    log "Creating and pulling backup..."
    pct exec $old_container_id -- sysupgrade -b $backup_file
    check_result $? "Failed to create backup."
    pct pull $old_container_id $backup_file ~/backup.tar.gz
    check_result $? "Failed to pull backup from container."
fi

# 停止旧容器
log "Stopping old container..."
pct stop $old_container_id
check_result $? "Failed to stop old container."

# 创建新容器
log "Creating new container..."
pct create $new_container_id $template --rootfs $rootfs --ostype $ostype --hostname $hostname --arch $arch --cores $cores --memory $memory --swap $swap --onboot $onboot --features $features --net0 $net0
check_result $? "Failed to create new container."
pct start $new_container_id
check_result $? "Failed to start new container."
sleep 10

# 将备份推送到新容器并还原备份
if [ "$backup_and_clash" == "1" ]; then
    log "Performing sysupgrade in new container..."
    pct push $new_container_id ~/backup.tar.gz $backup_file
    check_result $? "Failed to push backup to new container."
    pct exec $new_container_id -- sysupgrade -r $backup_file
    check_result $? "Failed to perform sysupgrade in new container."
    sleep 5
fi

# 启用并启动 openclash 服务
if [ "$backup_and_clash" == "1" ]; then
    log "Enabling and starting openclash service in new container..."
    pct exec $new_container_id -- uci set openclash.config.enable='1'
    pct exec $new_container_id -- uci commit openclash
    pct exec $new_container_id -- /etc/init.d/openclash start
    check_result $? "Failed to enable or start openclash service in new container."
fi

# 销毁旧容器
log "Destroying old container..."
pct destroy $old_container_id --purge
check_result $? "Failed to destroy old container."

# 记录脚本执行完成
log "Script execution completed."
