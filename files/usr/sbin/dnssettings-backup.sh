#!/bin/sh
# ============================================================
# DNS设置插件 - 备份当前系统配置
# 备份 /etc/config/ 下的 network 和 dhcp 配置
# ============================================================

BACKUP_DIR="/root/backup"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$BACKUP_DIR/dnssettings-system-backup-$TIMESTAMP.tar.gz"

mkdir -p "$BACKUP_DIR"

# 备份 network 和 dhcp 配置（DNS 相关的核心配置）
tar -czf "$BACKUP_FILE" \
    /etc/config/network \
    /etc/config/dhcp \
    /etc/config/dnssettings 2>/dev/null

if [ $? -eq 0 ]; then
    echo "备份成功: $BACKUP_FILE"
    logger -t dnssettings "系统配置已备份到 $BACKUP_FILE"
    exit 0
else
    echo "备份失败"
    logger -t dnssettings "ERROR: 系统配置备份失败"
    exit 1
fi
