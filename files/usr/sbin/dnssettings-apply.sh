#!/bin/sh
# ============================================================
# DNS设置插件 - 应用配置脚本 (v1.4.6)
# 读取 /etc/config/dnssettings，写入系统 network/dhcp 配置并重载服务
#
# v1.4.6 更新：
#   1. WAN 接口自动探测（用户配置 → 默认路由反查 → 兜底 wan/wan6），
#      不再硬编码 network.wan / network.wan6
#   2. dhcp_option 改 delete + add_list 正确写法（list 类型）
#   3. PPPoE 双栈 fallback 并入 wan.dns 前先 delete 全量重写去重
#      （修复重复应用时 add_list 逐次累积）
#   4. logger 输出过滤控制字符（防 syslog 注入转义序列）
#
# v1.4.5 防护逻辑（修复空值断网）：
#   1. peerdns=0 但自定义 DNS 全空 → 拒绝写入该接口（保持现状），
#      否则路由器将失去全部上游解析导致断网
#   2. list 字段（network.wan.dns 等）改用 delete + add_list 正确写法，
#      切换配置时先清残留，不再 set 单元素覆盖
#   3. dnsmasq 转发关闭时清空旧 server 列表，使"关闭"真正生效
#   4. 应用前自动备份 network/dhcp 到 /root/backup/（保留最近 5 份）
# ============================================================

CONFIG_FILE="/etc/config/dnssettings"
LOG_TAG="dnssettings"
BACKUP_DIR="/root/backup"

# 【v1.4.6】logger 过滤控制字符：防止配置值中的转义序列污染 syslog/终端
log() {
    local msg
    msg=$(printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037')
    logger -t "$LOG_TAG" "$msg"
    echo "[$LOG_TAG] $msg"
}

# 检查配置文件是否存在
if [ ! -f "$CONFIG_FILE" ]; then
    log "ERROR: 配置文件 $CONFIG_FILE 不存在"
    exit 1
fi

# ============================================================
# 【v1.4.6】WAN 接口自动探测
# 优先级：1. dnssettings.wan.wan_iface / wan6_iface 用户显式配置
#         2. 默认路由所在接口反查 network 节名
#         3. 兜底 wan / wan6（保持旧版行为）
# ============================================================
iface_from_route() {
    # $1: -4 或 -6；输出默认路由 dev 对应的 network 节名（找不到则空）
    local rt_dev family
    family="$1"
    rt_dev=$(ip "$family" route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ -z "$rt_dev" ] && return
    # 遍历 network 接口节，匹配 device/ifname/name
    local idx=0 name dev
    while uci -q get "network.@interface[$idx]" >/dev/null 2>&1; do
        name=$(uci -q get "network.@interface[$idx]" 2>/dev/null | awk -F. '{print $2}')
        dev=$(uci -q get "network.@interface[$idx].device" 2>/dev/null)
        [ -z "$dev" ] && dev=$(uci -q get "network.@interface[$idx].ifname" 2>/dev/null)
        # device 可能是 logical 或 physical 名，任一命中即可
        if [ "$dev" = "$rt_dev" ] || [ "$name" = "$rt_dev" ]; then
            echo "$name"
            return
        fi
        idx=$((idx+1))
    done
    echo "$rt_dev"
}

detect_wan_iface() {
    # $1: 4 或 6
    local custom rt
    if [ "$1" = "4" ]; then
        custom=$(uci -q get dnssettings.wan.wan_iface 2>/dev/null)
        [ -n "$custom" ] && uci -q get "network.$custom" >/dev/null 2>&1 && { echo "$custom"; return; }
        rt=$(iface_from_route -4)
        [ -n "$rt" ] && { echo "$rt"; return; }
        echo "wan"
    else
        custom=$(uci -q get dnssettings.wan.wan6_iface 2>/dev/null)
        [ -n "$custom" ] && uci -q get "network.$custom" >/dev/null 2>&1 && { echo "$custom"; return; }
        rt=$(iface_from_route -6)
        [ -n "$rt" ] && { echo "$rt"; return; }
        echo "wan6"
    fi
}

WAN_IFACE=$(detect_wan_iface 4)
WAN6_IFACE=$(detect_wan_iface 6)

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
# 0. 应用前自动备份（network/dhcp/dnssettings 三配置）
#    保留最近 5 份自动备份，防止堆积占满 /root
# ============================================================
AUTO_BAK="$BACKUP_DIR/dnssettings-auto-$(date +%Y%m%d-%H%M%S).tar.gz"
if mkdir -p "$BACKUP_DIR" && tar -czf "$AUTO_BAK" /etc/config/network /etc/config/dhcp "$CONFIG_FILE" 2>/dev/null; then
    log "已自动备份当前配置: $AUTO_BAK"
    # 清理旧自动备份（按名字排序，保留最新 5 份）
    ls -1t "$BACKUP_DIR"/dnssettings-auto-*.tar.gz 2>/dev/null | tail -n +6 | while read -r old; do
        rm -f "$old"
        log "清理旧自动备份: $old"
    done
else
    log "WARN: 自动备份失败（继续应用，建议先手动备份）"
fi

# ============================================================
# 1. 配置 WAN 口 IPv4 DNS
# ============================================================
if uci get "network.$WAN_IFACE" >/dev/null 2>&1; then
    if [ "$WAN_PEERDNS" = "1" ]; then
        uci set "network.$WAN_IFACE.peerdns='1'"
        uci delete "network.$WAN_IFACE.dns" 2>/dev/null
        log "WAN IPv4 ($WAN_IFACE): 使用运营商下发 DNS"
    else
        # 【防护】自定义模式必须至少提供一个 DNS，否则保持现状防止断网
        WAN_V4_DNS=""
        [ -n "$WAN_DNS1_V4" ] && WAN_V4_DNS="$WAN_DNS1_V4"
        [ -n "$WAN_DNS2_V4" ] && WAN_V4_DNS="$WAN_V4_DNS $WAN_DNS2_V4"
        if [ -z "$WAN_V4_DNS" ]; then
            log "WARN: WAN IPv4 自定义 DNS 为空，跳过该接口（保持现状，防止断网）"
        else
            uci set "network.$WAN_IFACE.peerdns='0'"
            # list 字段：先清残留，再逐个 add_list（uci set 单元素是错误写法）
            uci delete "network.$WAN_IFACE.dns" 2>/dev/null
            for dns in $WAN_V4_DNS; do
                uci add_list "network.$WAN_IFACE.dns=$dns"
            done
            log "WAN IPv4 ($WAN_IFACE): $WAN_V4_DNS"
        fi
    fi
else
    log "WARN: 未找到 network.$WAN_IFACE 接口，跳过 WAN IPv4 配置"
fi

# ============================================================
# 2. 配置 WAN6 口 IPv6 DNS
# ============================================================
if uci get "network.$WAN6_IFACE" >/dev/null 2>&1; then
    if [ "$WAN_PEERDNS" = "1" ]; then
        uci set "network.$WAN6_IFACE.peerdns='1'"
        uci delete "network.$WAN6_IFACE.dns" 2>/dev/null
        log "WAN6 IPv6 ($WAN6_IFACE): 使用运营商下发 DNS"
    else
        WAN_V6_DNS=""
        [ -n "$WAN_DNS1_V6" ] && WAN_V6_DNS="$WAN_DNS1_V6"
        [ -n "$WAN_DNS2_V6" ] && WAN_V6_DNS="$WAN_V6_DNS $WAN_DNS2_V6"
        if [ -z "$WAN_V6_DNS" ]; then
            log "WARN: WAN6 IPv6 自定义 DNS 为空，跳过该接口（保持现状，防止断网）"
        else
            uci set "network.$WAN6_IFACE.peerdns='0'"
            uci delete "network.$WAN6_IFACE.dns" 2>/dev/null
            for dns in $WAN_V6_DNS; do
                uci add_list "network.$WAN6_IFACE.dns=$dns"
            done
            log "WAN6 IPv6 ($WAN6_IFACE): $WAN_V6_DNS"
        fi
    fi
else
    log "WARN: 未找到 network.$WAN6_IFACE 接口"
    # PPPoE 双栈：IPv6 DNS 可并入 wan 接口的 dns list（netifd 自动区分协议）
    # 【v1.4.6 去重】并入前先 delete 整个 dns list 再重写（IPv4+IPv6 全量），
    # 修复重复应用时 add_list 逐次累积导致 dns 列表无限增长的 bug
    if uci get "network.$WAN_IFACE" >/dev/null 2>&1 && [ "$WAN_PEERDNS" != "1" ]; then
        WAN_V6_DNS=""
        [ -n "$WAN_DNS1_V6" ] && WAN_V6_DNS="$WAN_DNS1_V6"
        [ -n "$WAN_DNS2_V6" ] && WAN_V6_DNS="$WAN_V6_DNS $WAN_DNS2_V6"
        if [ -n "$WAN_V6_DNS" ]; then
            # 重写全量 list：IPv4 自定义值 + IPv6 并入值，跳过重复值
            # WAN_V4_DNS 显式初始化（第 1 节为空跳过时该变量可能未赋值）
            [ -z "$WAN_V4_DNS" ] && WAN_V4_DNS=""
            uci delete "network.$WAN_IFACE.dns" 2>/dev/null
            ADDED_DNS=" "
            for dns in $WAN_V4_DNS $WAN_V6_DNS; do
                case "$ADDED_DNS" in
                    *" $dns "*) ;;  # 已写入，跳过
                    *) uci add_list "network.$WAN_IFACE.dns=$dns"; ADDED_DNS="$ADDED_DNS$dns " ;;
                esac
            done
            log "WAN IPv6(双栈并入 $WAN_IFACE.dns): $WAN_V6_DNS"
        else
            log "（IPv6 自定义 DNS 为空，不并入 $WAN_IFACE）"
        fi
    fi
fi

# ============================================================
# 3. 配置 LAN 口 IPv4 DHCP 下发 DNS
#    【v1.4.6】dhcp_option 在 OpenWrt 中是 list 类型（可多实例并存），
#    uci set 覆盖单值会在残留旧 list 上叠加，改用 delete + add_list 正确写法
# ============================================================
if [ "$LAN_FORCE" = "1" ]; then
    if [ -z "$LAN_DNS1_V4" ] && [ -z "$LAN_DNS2_V4" ]; then
        log "WARN: 勾选强制下发但 LAN IPv4 DNS 为空，跳过（保持现状，防止设备断解析）"
    else
        uci delete dhcp.lan.dhcp_option 2>/dev/null
        LAN_V4_OPTION="6"
        [ -n "$LAN_DNS1_V4" ] && LAN_V4_OPTION="$LAN_V4_OPTION,$LAN_DNS1_V4"
        [ -n "$LAN_DNS2_V4" ] && LAN_V4_OPTION="$LAN_V4_OPTION,$LAN_DNS2_V4"
        uci add_list dhcp.lan.dhcp_option="$LAN_V4_OPTION"
        log "LAN IPv4 DHCP: $LAN_V4_OPTION"
    fi
else
    # 关闭时清除残留，使"不强制下发"真正生效
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
    if [ -z "$LAN_V6_DNS" ]; then
        log "WARN: 勾选强制下发但 LAN IPv6 DNS 为空，跳过（保持现状）"
    else
        # list 字段：清残留 + 逐个写入
        uci delete dhcp.lan.dns 2>/dev/null
        for dns in $LAN_V6_DNS; do
            uci add_list dhcp.lan.dns="$dns"
        done
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
    # 清空旧的 server 列表（切换配置不留残留）
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

    # 【防护】启用转发但两个列表全空 → 提示（不清旧值，dnsmasq 仍有默认上游）
    uci -q get dhcp.@dnsmasq[0].server >/dev/null 2>&1 || log "WARN: 启用转发但未配置任何转发 DNS"
else
    # 关闭转发时清空 server 列表，使"关闭"真正生效
    uci delete dhcp.@dnsmasq[0].server 2>/dev/null
    log "dnsmasq 全局转发: 未启用（已清空旧转发列表）"
fi

# ============================================================
# 6. 提交配置并重载服务
#    reload 而非 restart：不重建接口，PPPoE 不重拨，不断网
# ============================================================
uci commit network
uci commit dhcp

log "重载网络服务（不重拨）..."
/etc/init.d/network reload

log "重载 dnsmasq..."
/etc/init.d/dnsmasq reload

log "重载 odhcpd (IPv6 RA/DHCPv6)..."
/etc/init.d/odhcpd restart

log "========== DNS 配置应用完成 =========="
log "若设备 DNS 未生效，请重连 WiFi/网线清除设备端缓存"
exit 0
