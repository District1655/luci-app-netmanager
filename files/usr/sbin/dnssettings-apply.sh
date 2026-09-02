#!/bin/sh
# ============================================================
# DNS设置插件 - 应用配置脚本
# 读取 /etc/config/dnssettings，写入系统 network/dhcp 配置并重启服务
# ============================================================

CONFIG_FILE="/etc/config/dnssettings"
LOG_TAG="dnssettings"

log() {
    logger -t "$LOG_TAG" "$1"
    echo "[$LOG_TAG] $1"
}

# 检查配置文件是否存在
if [ ! -f "$CONFIG_FILE" ]; then
    log "ERROR: 配置文件 $CONFIG_FILE 不存在"
    exit 1
fi

# ---------- 读取 WAN 配置 ----------
WAN_PEERDNS=$(uci get dnssettings.wan.peerdns 2>/dev/null)
WAN_DNS1_V4=$(uci get dnssettings.wan.dns1_v4 2>/dev/null)
WAN_DNS2_V4=$(uci get dnssettings.wan.dns2_v4 2>/dev/null)
WAN_DNS1_V6=$(uci get dnssettings.wan.dns1_v6 2>/dev/null)
WAN_DNS2_V6=$(uci get dnssettings.wan.dns2_v6 2>/dev/null)

# ---------- 读取 LAN 配置 ----------
LAN_FORCE=$(uci get dnssettings.lan.force_dns 2>/dev/null)
LAN_DNS1_V4=$(uci get dnssettings.lan.dns1_v4 2>/dev/null)
LAN_DNS2_V4=$(uci get dnssettings.lan.dns2_v4 2>/dev/null)
LAN_DNS1_V6=$(uci get dnssettings.lan.dns1_v6 2>/dev/null)
LAN_DNS2_V6=$(uci get dnssettings.lan.dns2_v6 2>/dev/null)

# ---------- 读取 dnsmasq 配置 ----------
DNSMASQ_ENABLE=$(uci get dnssettings.dnsmasq.enable 2>/dev/null)

log "========== 开始应用 DNS 配置 =========="

# ============================================================
# 1. 配置 WAN 口 IPv4 DNS
# ============================================================
if uci get network.wan >/dev/null 2>&1; then
    if [ "$WAN_PEERDNS" = "1" ]; then
        uci set network.wan.peerdns='1'
        uci delete network.wan.dns 2>/dev/null
        log "WAN IPv4: 使用运营商下发 DNS"
    else
        uci set network.wan.peerdns='0'
        # 组合 IPv4 DNS（过滤空值）
        WAN_V4_DNS=""
        [ -n "$WAN_DNS1_V4" ] && WAN_V4_DNS="$WAN_DNS1_V4"
        [ -n "$WAN_DNS2_V4" ] && WAN_V4_DNS="$WAN_V4_DNS $WAN_DNS2_V4"
        if [ -n "$WAN_V4_DNS" ]; then
            uci set network.wan.dns="$WAN_V4_DNS"
            log "WAN IPv4: $WAN_V4_DNS"
        fi
    fi
else
    log "WARN: 未找到 network.wan 接口，跳过 WAN IPv4 配置"
fi

# ============================================================
# 2. 配置 WAN6 口 IPv6 DNS
# ============================================================
if uci get network.wan6 >/dev/null 2>&1; then
    if [ "$WAN_PEERDNS" = "1" ]; then
        uci set network.wan6.peerdns='1'
        uci delete network.wan6.dns 2>/dev/null
        log "WAN6 IPv6: 使用运营商下发 DNS"
    else
        uci set network.wan6.peerdns='0'
        WAN_V6_DNS=""
        [ -n "$WAN_DNS1_V6" ] && WAN_V6_DNS="$WAN_DNS1_V6"
        [ -n "$WAN_DNS2_V6" ] && WAN_V6_DNS="$WAN_V6_DNS $WAN_DNS2_V6"
        if [ -n "$WAN_V6_DNS" ]; then
            uci set network.wan6.dns="$WAN_V6_DNS"
            log "WAN6 IPv6: $WAN_V6_DNS"
        fi
    fi
else
    log "WARN: 未找到 network.wan6 接口，跳过 WAN6 IPv6 配置（PPPoE 双栈可能在 wan 接口上）"
    # 有些 PPPoE 双栈配置直接在 wan 接口上设置 IPv6 DNS
    if uci get network.wan >/dev/null 2>&1 && [ "$WAN_PEERDNS" != "1" ]; then
        WAN_V6_DNS=""
        [ -n "$WAN_DNS1_V6" ] && WAN_V6_DNS="$WAN_DNS1_V6"
        [ -n "$WAN_DNS2_V6" ] && WAN_V6_DNS="$WAN_V6_DNS $WAN_DNS2_V6"
        if [ -n "$WAN_V6_DNS" ]; then
            # 尝试设置 dns6 字段（部分版本支持）
            uci set network.wan.dns6="$WAN_V6_DNS" 2>/dev/null
            log "WAN IPv6(双栈): $WAN_V6_DNS"
        fi
    fi
fi

# ============================================================
# 3. 配置 LAN 口 IPv4 DHCP 下发 DNS
# ============================================================
if [ "$LAN_FORCE" = "1" ]; then
    LAN_V4_OPTION="6"
    [ -n "$LAN_DNS1_V4" ] && LAN_V4_OPTION="$LAN_V4_OPTION,$LAN_DNS1_V4"
    [ -n "$LAN_DNS2_V4" ] && LAN_V4_OPTION="$LAN_V4_OPTION,$LAN_DNS2_V4"
    if [ "$LAN_V4_OPTION" != "6" ]; then
        uci set dhcp.lan.dhcp_option="$LAN_V4_OPTION"
        log "LAN IPv4 DHCP: $LAN_V4_OPTION"
    fi
else
    uci delete dhcp.lan.dhcp_option 2>/dev/null
    log "LAN IPv4 DHCP: 不强制下发（设备走路由器缓存）"
fi

# ============================================================
# 4. 配置 LAN 口 IPv6 RA/DHCPv6 下发 DNS
# ============================================================
if [ "$LAN_FORCE" = "1" ]; then
    LAN_V6_DNS=""
    [ -n "$LAN_DNS1_V6" ] && LAN_V6_DNS="$LAN_DNS1_V6"
    [ -n "$LAN_DNS2_V6" ] && LAN_V6_DNS="$LAN_V6_DNS $LAN_DNS2_V6"
    if [ -n "$LAN_V6_DNS" ]; then
        uci set dhcp.lan.dns="$LAN_V6_DNS"
        # 确保 RA 和 DHCPv6 服务开启
        uci set dhcp.lan.ra='server'
        uci set dhcp.lan.dhcpv6='server'
        log "LAN IPv6 RA/DHCPv6: $LAN_V6_DNS"
    fi
else
    uci delete dhcp.lan.dns 2>/dev/null
    log "LAN IPv6 RA/DHCPv6: 不强制下发（设备走路由器缓存）"
fi

# ============================================================
# 5. 配置 dnsmasq 全局转发
# ============================================================
if [ "$DNSMASQ_ENABLE" = "1" ]; then
    # 清空旧的 server 列表
    uci delete dhcp.@dnsmasq[0].server 2>/dev/null

    # 添加 IPv4 转发
    for dns in $(uci get dnssettings.dnsmasq.forward_v4 2>/dev/null); do
        uci add_list dhcp.@dnsmasq[0].server="$dns"
        log "dnsmasq 转发 IPv4: $dns"
    done

    # 添加 IPv6 转发
    for dns in $(uci get dnssettings.dnsmasq.forward_v6 2>/dev/null); do
        uci add_list dhcp.@dnsmasq[0].server="$dns"
        log "dnsmasq 转发 IPv6: $dns"
    done
else
    log "dnsmasq 全局转发: 未启用"
fi

# ============================================================
# 6. 提交配置并重启服务
# ============================================================
uci commit network
uci commit dhcp

log "重启网络服务..."
/etc/init.d/network restart

log "重启 dnsmasq..."
/etc/init.d/dnsmasq restart

log "重启 odhcpd (IPv6 RA/DHCPv6)..."
/etc/init.d/odhcpd restart

log "========== DNS 配置应用完成 =========="
exit 0
