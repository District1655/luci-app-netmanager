#!/bin/sh
# ============================================================
# DNS设置插件 - 应用配置脚本 (v1.8.6)
# 读取 /etc/config/dnssettings，写入系统 network/dhcp 配置并重载服务
#
# v1.7.3 更新：
#   1. 【关键】PPPoE 场景下自动修正 network.wan6.device：
#      wan6 若与 wan 绑在同一物理网口，DHCPv6 客户端发不出 SOLICIT/RS
#      （syslog: "Failed to send SOLICIT ... (Address not available)"），
#      PD 前缀续租失败后 LAN 设备会丢失公网 IPv6。
#      现检测 wan.proto=pppoe 且 wan6.device==wan.device 时改为 @wan，
#      修正后自动 ifup wan6 重新协商，并在日志中回显 PD 获取结果。
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
#   4. 应用前自动备份 network/dhcp 到 /root/backup/（保留最近 3 份）
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

    # 【v1.8.3 修复】路由设备名不等于 UCI 节名的情况。
    # PPPoE 下默认路由 dev 是 pppoe-wan，而 UCI 节名是 wan；
    # 旧版这里直接 echo "$rt_dev"，导致后续 uci get network.pppoe-wan 失败、
    # WAN DNS 整段被跳过（这是「页面配置与实际 DNS 不一致」的根因）。
    case "$rt_dev" in
        pppoe-*)
            name=${rt_dev#pppoe-}
            if uci -q get "network.$name" >/dev/null 2>&1; then
                echo "$name"
                return
            fi
            ;;
    esac

    # 再用 netifd 运行时信息反查（覆盖 VLAN / 桥接 / 别名等场景）
    if command -v ubus >/dev/null 2>&1; then
        name=$(ubus call network.interface dump 2>/dev/null \
            | awk -v d="$rt_dev" '
                /"interface"/ { i=$0; gsub(/.*"interface": *"|",?$/,"",i) }
                /"device"/ { v=$0; gsub(/.*"device": *"|",?$/,"",v); if (v==d) { print i; exit } }
            ')
        if [ -n "$name" ] && uci -q get "network.$name" >/dev/null 2>&1; then
            echo "$name"
            return
        fi
    fi

    # 无法映射到 UCI 节名时返回空，由调用方兜底，绝不返回非法节名
    return
}

detect_wan_iface() {
    # $1: 4 或 6
    local custom rt fallback
    if [ "$1" = "4" ]; then
        fallback="wan"
        custom=$(uci -q get dnssettings.wan.wan_iface 2>/dev/null)
        [ -n "$custom" ] && uci -q get "network.$custom" >/dev/null 2>&1 && { echo "$custom"; return; }
        rt=$(iface_from_route -4)
        # v1.8.3：必须校验节名真实存在，否则回退，避免写入不存在的接口
        [ -n "$rt" ] && uci -q get "network.$rt" >/dev/null 2>&1 && { echo "$rt"; return; }
        echo "$fallback"
    else
        fallback="wan6"
        custom=$(uci -q get dnssettings.wan.wan6_iface 2>/dev/null)
        [ -n "$custom" ] && uci -q get "network.$custom" >/dev/null 2>&1 && { echo "$custom"; return; }
        # v1.8.3：IPv6 必须优先落在 wan6 节。
        # IPv6 默认路由的 dev 同样是 pppoe-wan，按路由反查会得到 wan，
        # 若据此写入就会用 IPv6 DNS 覆盖掉刚写好的 wan.dns（IPv4 列表丢失）。
        if uci -q get network.wan6 >/dev/null 2>&1; then
            echo "wan6"
            return
        fi
        rt=$(iface_from_route -6)
        if [ -n "$rt" ] && uci -q get "network.$rt" >/dev/null 2>&1; then
            # 仅当该节确实是 IPv6 协议时才采用
            case "$(uci -q get network.$rt.proto)" in
                dhcpv6|6in4|6to4|6rd) echo "$rt"; return ;;
            esac
        fi
        # 无独立 wan6：并入 wan（下游会把 IPv6 DNS 追加而非覆盖）
        echo "wan"
    fi
}

WAN_IFACE=$(detect_wan_iface 4)
WAN6_IFACE=$(detect_wan_iface 6)

# ---------- v1.8.3：回填 dnssettings 缺失项（必须在读取配置之前）----------
# 历史版本只建了 wan 节却没写 DNS 值，导致页面显示默认值、
# 而 network.wan 无 dns 且 peerdns 未设置（实际走运营商 DNS），两者不一致。
# 缺失时优先取 network 现值回填，保证「页面所见 = 实际生效」。
if [ "$(uci -q get dnssettings.wan.peerdns)" = "0" ]; then
    _cur4=$(uci -q get network.wan.dns)
    _cur6=$(uci -q get network.wan6.dns)
    if [ -z "$(uci -q get dnssettings.wan.dns1_v4)" ]; then
        _v=$(echo "$_cur4" | awk '{print $1}')
        uci set dnssettings.wan.dns1_v4="${_v:-223.5.5.5}"
    fi
    if [ -z "$(uci -q get dnssettings.wan.dns2_v4)" ]; then
        _v=$(echo "$_cur4" | awk '{print $2}')
        uci set dnssettings.wan.dns2_v4="${_v:-119.29.29.29}"
    fi
    if [ -z "$(uci -q get dnssettings.wan.dns1_v6)" ]; then
        _v=$(echo "$_cur6" | awk '{print $1}')
        uci set dnssettings.wan.dns1_v6="${_v:-2400:3200::1}"
    fi
    if [ -z "$(uci -q get dnssettings.wan.dns2_v6)" ]; then
        _v=$(echo "$_cur6" | awk '{print $2}')
        uci set dnssettings.wan.dns2_v6="${_v:-2402:4e00::}"
    fi
    uci commit dnssettings 2>/dev/null
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
# 0. 应用前自动备份（network/dhcp/dnssettings 三配置）
#    保留最近 3 份自动备份，防止堆积占满 /root
# ============================================================
AUTO_BAK="$BACKUP_DIR/dnssettings-auto-$(date +%Y%m%d-%H%M%S).tar.gz"
if mkdir -p "$BACKUP_DIR" && tar -czf "$AUTO_BAK" /etc/config/network /etc/config/dhcp "$CONFIG_FILE" 2>/dev/null; then
    log "已自动备份当前配置: $AUTO_BAK"
    # 清理旧自动备份（按修改时间排序，保留最新 3 份）
    ls -1t "$BACKUP_DIR"/dnssettings-auto-*.tar.gz 2>/dev/null | tail -n +4 | while read -r old; do
        rm -f "$old"
        log "清理旧自动备份: $old"
    done
else
    log "WARN: 自动备份失败（继续应用，建议先手动备份）"
fi

# ============================================================
# 0.5 【v1.7.3】WAN 一致性校验：PPPoE 场景修正 wan6 绑定
#     现象：wan6.device 若仍指向物理网口（与 wan.device 相同），
#     DHCPv6 客户端在物理口上缺乏可用的 IPv6 出口地址，
#     SOLICIT / RS 发不出去（syslog 报 "Failed to send SOLICIT
#     message to ff02::1:2 (Address not available)"），
#     PD 前缀续租失败 → 前缀到期撤销 → LAN 设备丢失公网 IPv6。
#     修正条件：wan.proto=pppoe 且 wan6.device 与 wan.device 相同。
# ============================================================
FIXED_WAN6=0
if [ "$(uci -q get network.wan.proto)" = "pppoe" ]; then
    WAN_DEV_RAW=$(uci -q get network.wan.device)
    WAN6_DEV_RAW=$(uci -q get network.wan6.device)
    if [ -n "$WAN_DEV_RAW" ] && [ -n "$WAN6_DEV_RAW" ] && [ "$WAN6_DEV_RAW" = "$WAN_DEV_RAW" ]; then
        uci set network.wan6.device='@wan'
        uci commit network 2>/dev/null
        FIXED_WAN6=1
        log "修正 wan6 绑定: $WAN6_DEV_RAW -> @wan（PPPoE 必须挂在逻辑接口上）"
    fi
fi

# ============================================================
# 1. 配置 WAN 口 IPv4 DNS
# ============================================================
if uci get "network.$WAN_IFACE" >/dev/null 2>&1; then
    if [ "$WAN_PEERDNS" = "1" ]; then
        uci set "network.$WAN_IFACE.peerdns=1"
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
            uci set "network.$WAN_IFACE.peerdns=0"
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
        uci set "network.$WAN6_IFACE.peerdns=1"
        uci delete "network.$WAN6_IFACE.dns" 2>/dev/null
        log "WAN6 IPv6 ($WAN6_IFACE): 使用运营商下发 DNS"
    else
        WAN_V6_DNS=""
        [ -n "$WAN_DNS1_V6" ] && WAN_V6_DNS="$WAN_DNS1_V6"
        [ -n "$WAN_DNS2_V6" ] && WAN_V6_DNS="$WAN_V6_DNS $WAN_DNS2_V6"
        if [ -z "$WAN_V6_DNS" ]; then
            log "WARN: WAN6 IPv6 自定义 DNS 为空，跳过该接口（保持现状，防止断网）"
        else
            uci set "network.$WAN6_IFACE.peerdns=0"
            # v1.8.3：与 WAN 同节时（无独立 wan6）必须保留已写入的 IPv4 DNS，
            # 否则这里的 delete 会把上一步的 IPv4 列表清空，只剩 IPv6。
            if [ "$WAN6_IFACE" != "$WAN_IFACE" ]; then
                uci delete "network.$WAN6_IFACE.dns" 2>/dev/null
            fi
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
# 2.5 【v1.8.6】清除 wan6 的 dns_search 残留
#     本平台（iStoreOS 25.12 / netifd dhcpv6）不接受 dns_search 选项，
#     残留会使 netifd setup 报 "ubus error: Invalid argument" 并无限重试，
#     PD 续租失败 → LAN 设备丢失公网 IPv6。pppoe 的 wan 接受该选项不受影响。
#     dns_search 多由运营商 DHCP 下发后残留进 uci，本插件不主动写入，应用时清除。
# ============================================================
if [ "$WAN6_IFACE" != "$WAN_IFACE" ] && uci -q get "network.$WAN6_IFACE" >/dev/null 2>&1; then
    if uci -q delete "network.$WAN6_IFACE.dns_search" 2>/dev/null; then
        uci commit network 2>/dev/null
        log "清除 $WAN6_IFACE.dns_search（dhcpv6 不支持，防止 Invalid argument 抖动）"
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
# 4. 配置 LAN 口 IPv6（v1.8.4：分发模式 + RDNSS）
#    与 iStoreOS 原生网络管理共用 dhcp.lan 配置。模式存 dnssettings.ipv6.lan_mode，
#    旧版在此硬写 ra/dhcpv6=server，会覆盖用户所选模式，现改为按模式写入。
# ============================================================
V6MODE=$(uci -q get dnssettings.ipv6.lan_mode)
[ -z "$V6MODE" ] && V6MODE="server"
case "$V6MODE" in
    relay)
        uci set dhcp.lan.ra='relay'
        uci set dhcp.lan.dhcpv6='relay'
        uci set dhcp.lan.ndp='relay'
        uci delete dhcp.lan.ra_flags 2>/dev/null
        uci delete dhcp.lan.dns 2>/dev/null
        # 中继需上游接口作 master（iStoreOS 原生中继同样如此）
        if uci -q get network.wan6 >/dev/null 2>&1; then
            uci set dhcp.wan6=dhcp 2>/dev/null
            uci set dhcp.wan6.interface='wan6'
            uci set dhcp.wan6.ra='relay'
            uci set dhcp.wan6.dhcpv6='relay'
            uci set dhcp.wan6.ndp='relay'
            uci set dhcp.wan6.master='1'
        fi
        log "LAN IPv6: 中继模式（ra/dhcpv6/ndp=relay，wan6=master）"
        ;;
    disabled)
        uci set dhcp.lan.ra='disabled'
        uci set dhcp.lan.dhcpv6='disabled'
        uci set dhcp.lan.ndp='disabled'
        uci delete dhcp.lan.ra_flags 2>/dev/null
        uci delete dhcp.lan.dns 2>/dev/null
        uci delete dhcp.wan6 2>/dev/null
        log "LAN IPv6: 已关闭分发"
        ;;
    slaac)
        uci set dhcp.lan.ra='server'
        uci set dhcp.lan.dhcpv6='disabled'
        uci set dhcp.lan.ndp='disabled'
        uci delete dhcp.lan.ra_flags 2>/dev/null
        uci add_list dhcp.lan.ra_flags='other-config'
        uci set dhcp.lan.ra_slaac='1'
        # v1.8.7：强制宣告默认网关。pppoe 关闭 wan.ipv6 后默认路由可能缺失，
        # odhcpd 默认 ra_default=0 只在有默认路由时才宣告网关，会导致客户端
        # 拿到 SLAAC 地址却没有默认网关。设 1 确保始终宣告（路由由 v6gw 守护补）。
        uci set dhcp.lan.ra_default='1'
        uci delete dhcp.wan6 2>/dev/null
        log "LAN IPv6: 服务器模式（SLAAC 无状态）"
        ;;
    *)
        uci set dhcp.lan.ra='server'
        uci set dhcp.lan.dhcpv6='server'
        uci set dhcp.lan.ndp='disabled'
        uci delete dhcp.lan.ra_flags 2>/dev/null
        uci add_list dhcp.lan.ra_flags='managed-config'
        uci add_list dhcp.lan.ra_flags='other-config'
        uci set dhcp.lan.ra_slaac='1'
        uci set dhcp.lan.ra_default='1'   # v1.8.7：强制宣告默认网关（见 slaac 分支说明）
        uci delete dhcp.wan6 2>/dev/null
        log "LAN IPv6: 服务器模式（RA + DHCPv6 状态化）"
        ;;
esac

# RDNSS：仅 server/slaac 模式给设备下发 IPv6 DNS
if [ "$V6MODE" = "server" ] || [ "$V6MODE" = "slaac" ]; then
    if [ "$LAN_FORCE" = "1" ]; then
        LAN_V6_DNS=""
        [ -n "$LAN_DNS1_V6" ] && LAN_V6_DNS="$LAN_DNS1_V6"
        [ -n "$LAN_DNS2_V6" ] && LAN_V6_DNS="$LAN_V6_DNS $LAN_DNS2_V6"
        if [ -z "$LAN_V6_DNS" ]; then
            log "WARN: 勾选强制下发但 LAN IPv6 DNS 为空，跳过 RDNSS（保持现状）"
        else
            uci delete dhcp.lan.dns 2>/dev/null
            for dns in $LAN_V6_DNS; do
                uci add_list dhcp.lan.dns="$dns"
            done
            log "LAN IPv6 RDNSS: $LAN_V6_DNS"
        fi
    else
        uci delete dhcp.lan.dns 2>/dev/null
        log "LAN IPv6 RDNSS: 不强制下发（设备走路由器缓存）"
    fi
fi

# ============================================================
# 4.5 WAN IPv6 前缀请求长度（PD，v1.8.4）
# ============================================================
CHANGED_PREFIX=0
V6PREFIX=$(uci -q get dnssettings.ipv6.wan_prefix)
if [ -n "$V6PREFIX" ] && uci -q get network.wan6 >/dev/null 2>&1; then
    CUR_PREFIX=$(uci -q get network.wan6.reqprefix)
    [ -z "$CUR_PREFIX" ] && CUR_PREFIX="auto"
    if [ "$V6PREFIX" != "$CUR_PREFIX" ]; then
        uci set network.wan6.reqprefix="$V6PREFIX"
        CHANGED_PREFIX=1
        log "WAN6 前缀请求: $CUR_PREFIX -> $V6PREFIX"
    fi
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

    # v1.8.3：noresolv —— 决定是否只用上面的转发列表。
    # dnsmasq 默认还会读 /tmp/resolv.conf.d/resolv.conf.auto（含运营商下发、
    # wan_6 自动获取、lan 接口 DNS），导致「全局转发」名不副实、
    # 页面配置与首页显示的实际 DNS 不一致。开启后严格只用转发列表。
    NORESOLV=$(uci -q get dnssettings.dnsmasq.noresolv)
    if [ "$NORESOLV" = "1" ]; then
        uci set dhcp.@dnsmasq[0].noresolv='1'
        log "dnsmasq noresolv=1：仅使用上方转发列表，忽略运营商下发 DNS"
    else
        uci delete dhcp.@dnsmasq[0].noresolv 2>/dev/null
        log "dnsmasq noresolv=0：转发列表之外仍会并用系统 resolv 上游"
    fi
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

log "重启 odhcpd (IPv6 RA/DHCPv6)..."
# v1.8.3：必须 restart，不能只 start。
# 实测 odhcpd 已在运行时，procd 的 start 是空操作、不会重读配置，
# 导致改了 dhcp.lan.dns 后 RA 里播的仍是旧 RDNSS（抓包确认）。
# 同时收敛重复实例：曾出现 procd 实例与手动实例并存，两者都写 piofile，
# 造成 RFC9096 前缀记忆互相覆盖、RA 广播不一致。
ODHCPD_N=$(ps w 2>/dev/null | grep -c '[o]dhcpd')
[ "$ODHCPD_N" -gt 1 ] && log "检测到 $ODHCPD_N 个 odhcpd 实例，一并收敛"
/etc/init.d/odhcpd stop 2>/dev/null
sleep 1
killall odhcpd 2>/dev/null
sleep 1
/etc/init.d/odhcpd start 2>/dev/null
sleep 2
ODHCPD_N=$(ps w 2>/dev/null | grep -c '[o]dhcpd')
log "odhcpd 实例数: $ODHCPD_N"
[ "$ODHCPD_N" -gt 1 ] && log "WARN: odhcpd 仍有多个实例，请检查是否有额外启动项"

# v1.8.3：前缀可能已变化，同步 IPv6 转发目标并清理旧前缀残留路由
# v1.8.3：无条件同步 —— 即使没登记跟踪，也要清理 piofolder 失效前缀记忆，
# 止住 RA 对旧前缀的持续广播（客户端堆旧地址的根因）
if uci -q get netmanager.@v6track[0] >/dev/null 2>&1; then
    log "同步 IPv6 端口转发目标..."
else
    log "清理 IPv6 前缀残留..."
fi
/usr/sbin/netmanager port_sync_v6 2>&1 | while read -r l; do log "  $l"; done

# 【v1.7.3】wan6 绑定被修正后必须重新协商，否则新绑定不生效、PD 仍拿不到
# 【v1.8.4】前缀请求长度变化同样需要重新协商 wan6
if [ "$FIXED_WAN6" = "1" ] || [ "$CHANGED_PREFIX" = "1" ]; then
    log "重启 wan6 接口以应用新绑定/前缀请求并重新获取 PD 前缀..."
    ifup wan6 2>/dev/null
    sleep 12
    PD_INFO=$(ifstatus wan6 2>/dev/null | awk '/"ipv6-prefix"/{f=1} f&&/"mask"/{print; exit}')
    if [ -n "$PD_INFO" ]; then
        log "wan6 已重新获取 PD 前缀（$PD_INFO）"
    else
        log "WARN: wan6 暂未获取到 PD 前缀，请稍后执行 ifstatus wan6 复核"
    fi
fi

log "========== DNS 配置应用完成 =========="
log "若设备 DNS 未生效，请重连 WiFi/网线清除设备端缓存"
exit 0
