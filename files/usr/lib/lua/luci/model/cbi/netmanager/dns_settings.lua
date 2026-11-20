-- 上网设置插件 - CBI 表单模型
-- 原 DNS 设置模块，v1.6.1 扩展为上网设置：WAN口上网方式 + LAN口地址 + DNS设置
-- 绑定 /etc/config/network + /etc/config/dnssettings

local m, s, o

-- v1.8.4：模块级 trim（IPv6 模式读取运行时配置用）
local function trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end

-- ============================================================
-- 第一部分：上网设置（WAN口 + LAN口，绑定 network 配置）
-- v1.6.1：隐藏 Map 级别标题栏，统一用 section 级别标题（灰色标题栏）
-- ============================================================
m = Map("network", nil,
    translate("统一管理 WAN 口上网方式、LAN 口地址与 DNS 服务器。修改后点击「应用配置」生效。")
    .. "<br><em style='color:#6b7280;font-size:12px;'>"
    .. translate("修改 WAN/LAN 口设置会重载网络服务，期间可能短暂断网；DNS 配置应用前自动备份到 /root/backup/。")
    .. "</em>")
m.pageaction = false  -- v1.8.6：关闭本 Map 默认保存按钮，统一由底部「应用配置」提交

-- v1.4.6 修复：CBI 页面缺少页内导航，注入导航模板
m:append(Template("netmanager/cbi_nav"))

-- ---------- WAN 口上网方式 ----------
s = m:section(NamedSection, "wan", "interface", translate("WAN 口上网方式"),
    translate("路由器接入互联网的方式，PPPoE 拨号 / DHCP 自动获取 / 静态 IP。"))

o = s:option(ListValue, "proto", translate("上网方式"))
o:value("pppoe", translate("PPPoE 拨号"))
o:value("dhcp", translate("DHCP 自动获取"))
o:value("static", translate("静态 IP"))
o.default = "dhcp"
o.rmempty = false

-- PPPoE 拨号
o = s:option(Value, "username", translate("PPPoE 账号"))
o:depends("proto", "pppoe")
o.placeholder = "宽带账号"

o = s:option(Value, "password", translate("PPPoE 密码"))
o:depends("proto", "pppoe")
o.password = true
o.placeholder = "宽带密码"

-- 静态 IP
o = s:option(Value, "ipaddr", translate("IP 地址"))
o:depends("proto", "static")
o.datatype = "ip4addr"
o.placeholder = "192.168.1.100"

o = s:option(Value, "netmask", translate("子网掩码"))
o:depends("proto", "static")
o.datatype = "ip4addr"
o.placeholder = "255.255.255.0"

o = s:option(Value, "gateway", translate("网关"))
o:depends("proto", "static")
o.datatype = "ip4addr"
o.placeholder = "192.168.1.1"

o = s:option(DynamicList, "dns", translate("WAN 口 DNS"))
o:depends("proto", "static")
o.datatype = "ip4addr"
o.placeholder = "223.5.5.5"
o.description = translate("静态 IP 模式下手动指定 DNS，可添加多个")

-- ============================================================
-- IPv6 获取与分发（v1.8.6：独立 Map，渲染在 WAN 上网方式之后、LAN 口地址之前）
-- 页面顺序：WAN上网方式 → IPv6获取分发 → LAN口地址 → WAN-DNS → LAN-DNS → dnsmasq → 操作
-- CBI 每个 Map 绑定单一配置、写入只走本 Map 配置，交错顺序需拆成多 Map 按序渲染。
-- ============================================================
local m_v6 = Map("dnssettings", nil, nil)
m_v6.pageaction = false  -- v1.8.6：关闭默认保存按钮

-- ---------- IPv6 获取与分发模式 ----------
-- 与 iStoreOS 原生网络管理共用同一套 dhcp.lan / network.wan6 配置，两边互通：
-- 这里改的模式，原生「网络→接口→LAN→DHCP服务器→IPv6设置」里同步可见，反之亦然。
-- 选项值存 dnssettings.ipv6，点「应用配置」时由 dnssettings-apply.sh 翻译写入 dhcp/network。
s = m_v6:section(NamedSection, "ipv6", "dnssettings", translate("IPv6 获取与分发"),
    translate("管理 WAN 口 IPv6 前缀获取（PD）与 LAN 口 IPv6 分发模式。配置写入 iStoreOS 原生网络管理同一套参数，互不冲突。"))

o = s:option(ListValue, "wan_prefix", translate("WAN 前缀请求长度 (PD)"))
o:value("auto", translate("自动（运营商决定）"))
o:value("60", "/60")
o:value("56", "/56")
o:value("64", "/64")
o:value("no", translate("不请求前缀（关闭 PD）"))
o.default = "auto"
o.rmempty = false
function o.cfgvalue(self, section)
    local v = trim(luci.sys.exec("uci -q get network.wan6.reqprefix 2>/dev/null"))
    return (v ~= "") and v or "auto"
end
o.description = translate("向运营商请求的 IPv6 前缀长度。前缀越短可划分的子网越多；「不请求」则关闭前缀委托。修改后应用会重新协商 wan6。")

o = s:option(ListValue, "lan_mode", translate("LAN 口 IPv6 分发模式"))
o:value("server", translate("服务器模式（RA + DHCPv6 状态化）"))
o:value("slaac", translate("服务器模式（SLAAC 无状态）"))
o:value("relay", translate("中继模式（透传上级路由 IPv6）"))
o:value("disabled", translate("关闭 IPv6 分发"))
o.default = "server"
o.rmempty = false
function o.cfgvalue(self, section)
    local ra = trim(luci.sys.exec("uci -q get dhcp.lan.ra 2>/dev/null"))
    local d6 = trim(luci.sys.exec("uci -q get dhcp.lan.dhcpv6 2>/dev/null"))
    if ra == "relay" or d6 == "relay" then return "relay" end
    if ra == "disabled" and (d6 == "disabled" or d6 == "") then return "disabled" end
    if d6 == "server" then return "server" end
    if ra == "server" then return "slaac" end
    return "server"
end
o.description = translate("服务器模式：由本机给内网设备分配 IPv6（状态化=DHCPv6 分配地址；SLAAC=设备按 RA 前缀自行生成）。中继模式：上级路由已有 IPv6 时透传给内网（需上级支持）。关闭：内网不再分发 IPv6。")

-- ============================================================
-- LAN 口地址（v1.8.6：独立 Map，绑定 network，渲染在 IPv6 之后）
-- ============================================================
local m_lan = Map("network", nil, nil)
m_lan.pageaction = false  -- v1.8.6：关闭默认保存按钮

-- ---------- LAN 口地址设置 ----------
s = m_lan:section(NamedSection, "lan", "interface", translate("LAN 口地址"),
    translate("路由器局域网管理地址与子网掩码，修改后需用新地址登录管理页面。"))

o = s:option(Value, "ipaddr", translate("LAN 口 IP 地址"))
o.datatype = "ip4addr"
o.placeholder = "192.168.1.1"
o.rmempty = false

o = s:option(Value, "netmask", translate("子网掩码"))
o.datatype = "ip4addr"
o.placeholder = "255.255.255.0"
o.rmempty = false

-- ============================================================
-- DNS 设置（绑定 dnssettings 配置）
-- v1.6.1：隐藏 Map 级别标题栏，统一用 section 级别标题（灰色标题栏）
-- ============================================================
local m2 = Map("dnssettings", nil, nil)
m2.pageaction = false  -- v1.8.6：关闭默认「保存并应用」，仅保留自定义「应用配置」按钮

-- ---------- WAN 口上游 DNS ----------
s = m2:section(NamedSection, "wan", "dnssettings", translate("WAN 口上游 DNS"),
    translate("路由器本身解析域名使用的 DNS，PPPoE/DHCP 拨号时生效。"))

o = s:option(Flag, "peerdns", translate("使用运营商下发的 DNS"),
    translate("勾选则使用拨号时运营商自动分配的 DNS；取消则使用下方自定义 DNS。"))
o.default = "0"
o.rmempty = false

-- v1.8.0 修复：原先这四个字段用 o:depends("peerdns", "0")，
-- 但 iStoreOS 24.10 的 CBI 对 Flag「等于0」的依赖判定不成立，
-- 服务端直接不渲染这些选项 —— 页面上看不到也无法配置 WAN DNS，
-- 只能沿用默认值，与实际生效的运营商 DNS 长期不一致。
-- 改为始终显示，并在说明中标注生效条件。
o = s:option(Value, "dns1_v4", translate("IPv4 主 DNS"))
o.datatype = "ip4addr"
o.placeholder = "223.5.5.5"
o.default = "223.5.5.5"
o.description = translate("以下四项仅在未勾选「使用运营商下发的 DNS」时生效")

o = s:option(Value, "dns2_v4", translate("IPv4 备 DNS"))
o.datatype = "ip4addr"
o.placeholder = "119.29.29.29"
o.default = "119.29.29.29"

o = s:option(Value, "dns1_v6", translate("IPv6 主 DNS"))
o.datatype = "ip6addr"
o.placeholder = "2400:3200::1"
o.default = "2400:3200::1"

o = s:option(Value, "dns2_v6", translate("IPv6 备 DNS"))
o.datatype = "ip6addr"
o.placeholder = "2402:4e00::"
o.default = "2402:4e00::"

-- ---------- LAN 口设备 DNS ----------
s = m2:section(NamedSection, "lan", "dnssettings", translate("LAN 口设备 DNS"),
    translate("通过 DHCP/RA 下发给手机、电脑等局域网设备的 DNS 服务器。"))

o = s:option(Flag, "force_dns", translate("强制下发自定义 DNS 给设备"),
    translate("勾选：设备直接使用下方指定的 DNS；取消：设备使用路由器 LAN IP 作为 DNS（走 dnsmasq 缓存转发）。"))
o.default = "1"
o.rmempty = false

o = s:option(Value, "dns1_v4", translate("IPv4 主 DNS"))
o.datatype = "ip4addr"
o.placeholder = "223.5.5.5"
o.default = "223.5.5.5"
o:depends("force_dns", "1")

o = s:option(Value, "dns2_v4", translate("IPv4 备 DNS"))
o.datatype = "ip4addr"
o.placeholder = "119.29.29.29"
o.default = "119.29.29.29"
o:depends("force_dns", "1")

o = s:option(Value, "dns1_v6", translate("IPv6 主 DNS"))
o.datatype = "ip6addr"
o.placeholder = "2400:3200::1"
o.default = "2400:3200::1"
o:depends("force_dns", "1")

o = s:option(Value, "dns2_v6", translate("IPv6 备 DNS"))
o.datatype = "ip6addr"
o.placeholder = "2402:4e00::"
o.default = "2402:4e00::"
o:depends("force_dns", "1")

-- ---------- dnsmasq 全局转发 ----------
s = m2:section(NamedSection, "dnsmasq", "dnssettings", translate("dnsmasq 全局转发"),
    translate("dnsmasq 上游解析服务器，设备走路由器缓存时实际使用的 DNS。"))

o = s:option(Flag, "enable", translate("启用全局转发"),
    translate("将上述 DNS 同时写入 dnsmasq 全局转发列表。"))
o.default = "1"
o.rmempty = false

-- v1.8.0：noresolv —— 解决「页面配置的 DNS」与「首页/实际生效 DNS」不一致
o = s:option(Flag, "noresolv", translate("只用上方转发列表（忽略运营商 DNS）"),
    translate("dnsmasq 默认除转发列表外，还会并用系统 resolv 里的上游（运营商拨号下发、wan6 自动获取、LAN 接口 DNS）。"
        .. "这会让实际解析路径与本页配置不一致。勾选后严格只使用上方列表。"))
o.default = "0"
o.rmempty = false
o:depends("enable", "1")

o = s:option(DynamicList, "forward_v4", translate("IPv4 转发 DNS"))
o.datatype = "ip4addr"
o.placeholder = "223.5.5.5"
o:depends("enable", "1")

o = s:option(DynamicList, "forward_v6", translate("IPv6 转发 DNS"))
o.datatype = "ip6addr"
o.placeholder = "2400:3200::1"
o:depends("enable", "1")

-- ---------- 操作按钮（v1.6.1 移除备份按钮，统一由设置页面备份模块管理） ----------
-- ---------- v1.8.0：实际生效 DNS 只读面板 ----------
-- 首页显示的是运行时真实上游，本页配置的是期望值，二者来源不同容易看着「冲突」。
-- 这里把运行时实际值直接摊开，并标注每项来源，便于对照。
local function _runtime_dns_panel()
    -- iStoreOS 24.10 起 pcdata 迁到 luci.xml，旧路径会打印弃用告警污染页面
    local esc
    local okx, xml = pcall(require, "luci.xml")
    if okx and xml and xml.pcdata then
        esc = function(s) return xml.pcdata(tostring(s or "")) end
    else
        local util = require "luci.util"
        esc = function(s) return util.pcdata(tostring(s or "")) end
    end
    local function trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end

    -- dnsmasq 实际转发列表
    local srv = trim(luci.sys.exec("uci -q get dhcp.@dnsmasq[0].server 2>/dev/null"))
    local nr = trim(luci.sys.exec("uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null"))
    -- 系统 resolv 上游（运营商 / 各接口自动下发）
    local auto = luci.sys.exec("cat /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null")
    -- 下发给 LAN 设备的 DNS
    local opt4 = trim(luci.sys.exec("uci -q get dhcp.lan.dhcp_option 2>/dev/null"))
    local opt6 = trim(luci.sys.exec("uci -q get dhcp.lan.dns 2>/dev/null"))

    local html = "<div style='background:#f8fafc;border:1px solid #e5e7eb;border-radius:6px;padding:10px 12px;margin:8px 0;font-size:12px;line-height:1.9;'>"
    html = html .. "<b style='color:#374151;'>当前实际生效的 DNS（运行时读取，非本页配置值）</b><br>"
    html = html .. "<span style='color:#6b7280;'>路由器自身解析：</span> dnsmasq (127.0.0.1) → "
    if srv ~= "" then
        html = html .. "<code>" .. esc(srv) .. "</code>"
    else
        html = html .. "<i>未配置转发列表</i>"
    end
    if nr == "1" then
        html = html .. " <span style='color:#059669;'>[noresolv=1，只用上述列表]</span>"
    else
        html = html .. " <span style='color:#d97706;'>[noresolv=0，还会并用下方系统上游]</span>"
    end
    html = html .. "<br><span style='color:#6b7280;'>系统 resolv 上游（首页数据来源）：</span><br>"
    html = html .. "<pre style='margin:4px 0;padding:6px 8px;background:#fff;border:1px solid #e5e7eb;border-radius:4px;max-height:160px;overflow:auto;'>"
    html = html .. esc(trim(auto) ~= "" and auto or "(空)") .. "</pre>"
    html = html .. "<span style='color:#6b7280;'>下发给内网设备：</span> IPv4 <code>"
        .. esc(opt4 ~= "" and opt4 or "(未下发，设备用路由器 IP)")
        .. "</code> ／ IPv6 <code>" .. esc(opt6 ~= "" and opt6 or "(未下发)") .. "</code>"
    html = html .. "</div>"
    return html
end

s = m2:section(NamedSection, "actions", "dnssettings", translate("操作"))
s.description = _runtime_dns_panel()

-- 执行 DNS 脚本并返回结果
local function run_dns_script(script)
    local out = luci.sys.exec(script .. " 2>&1; echo \"__RC__$?\"") or ""
    local rc = tonumber(out:match("__RC__(%-?%d+)")) or -1
    out = out:gsub("__RC__%-?%d+\n?$", "")
    return rc, out
end

-- 输出压缩为单行消息
local function to_one_line(str, max)
    str = (str or ""):gsub("%c", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #str > (max or 300) then str = str:sub(1, max) .. "..." end
    return str
end

o = s:option(Button, "_apply", translate("应用配置"))
o.inputtitle = translate("应用配置")
o.inputstyle = "apply"
o.write = function()
    -- v1.8.6：四个 Map 各持独立 cursor，需逐一提交（WAN/LAN 属 network，IPv6/DNS 属 dnssettings）
    m.uci:commit("network")        -- WAN 上网方式
    m_lan.uci:commit("network")    -- LAN 口地址
    m_v6.uci:commit("dnssettings") -- IPv6 获取分发
    m2.uci:commit("dnssettings")   -- DNS 各节

    -- 执行 DNS 应用脚本
    local ok, rc, out = pcall(run_dns_script, "/usr/sbin/dnssettings-apply.sh")
    if not ok then
        m2.message = "DNS 配置应用执行异常：" .. to_one_line(tostring(rc))
        return
    end

    -- v1.8.0：改用 reload 而非 restart。
    -- restart 会重建 br-lan，导致以 DirectInterface 绑定该网卡的 dropbear
    -- 监听套接字失效（端口仍 LISTEN 但连接被拒），管理 SSH 随之中断。
    -- apply 脚本内部已做 network reload，这里仅在 WAN 口参数确有变化时才重启接口。
    luci.sys.exec("/etc/init.d/network reload >/dev/null 2>&1")

    -- v1.8.1：此处不再做 SSH 自连探测。
    -- dropbear 绑 DirectInterface 时，本机连自身地址走回环路由必然失败，
    -- 探测无法区分"真失效"与"绑定特性"，只会造成无谓重启并踢掉在线会话。
    -- 应用走的是 reload（不重建 br-lan），本就无需重启 dropbear；
    -- 真正重建网卡的场景由 hotplug 96-netmanager-v6sync 按 ifindex 变化处理。

    if rc == 0 then
        m2.message = "配置已应用成功，已写入 /etc/config/ 并重载网络服务（详细输出见「设置 → 运行日志」）"
    else
        m2.message = "配置应用失败 (exit=" .. tostring(rc) .. ")：" .. to_one_line(out)
    end
end

-- v1.6.1 修复：/etc/config/dnssettings 为空或缺失节时，自动初始化默认节
-- v1.8.0 增强：节存在但个别选项缺失时也要补齐（历史版本只建了 wan 节
--              却没写 DNS 值，导致页面显示默认值而实际未生效）
local function _ensure_dns_defaults()
    local defaults = {
        wan = {
            peerdns = "0",
            dns1_v4 = "223.5.5.5", dns2_v4 = "119.29.29.29",
            dns1_v6 = "2400:3200::1", dns2_v6 = "2402:4e00::",
        },
        lan = {
            force_dns = "1",
            dns1_v4 = "223.5.5.5", dns2_v4 = "119.29.29.29",
            dns1_v6 = "2400:3200::1", dns2_v6 = "2402:4e00::",
        },
        dnsmasq = { enable = "1", noresolv = "0" },
        ipv6 = { lan_mode = "server", wan_prefix = "auto" },
    }
    local changed = false

    for sec, opts in pairs(defaults) do
        if not m2.uci:get("dnssettings", sec) then
            -- 建节走命令行，避免桥接 cursor 对三参 set 支持不一致
            luci.sys.exec("uci set dnssettings." .. sec .. "=dnssettings")
            changed = true
        end
        for k, v in pairs(opts) do
            if not m2.uci:get("dnssettings", sec, k) then
                -- WAN DNS 缺失时优先沿用 network 现值，避免覆盖用户已有设置
                local cur = nil
                if sec == "wan" then
                    if k == "dns1_v4" then
                        cur = (luci.sys.exec("uci -q get network.wan.dns 2>/dev/null"):match("(%S+)"))
                    elseif k == "dns1_v6" then
                        cur = (luci.sys.exec("uci -q get network.wan6.dns 2>/dev/null"):match("(%S+)"))
                    end
                end
                local val = (cur and cur ~= "") and cur or v
                luci.sys.exec("uci set dnssettings." .. sec .. "." .. k .. "='" .. val .. "'")
                changed = true
            end
        end
    end

    if not m2.uci:get("dnssettings", "actions") then
        luci.sys.exec("uci set dnssettings.actions=dnssettings")
        changed = true
    end

    -- 转发列表为空时补默认
    -- 注意：iStoreOS 24.10 的 ucode uci 桥接不提供 cursor:list_add，
    -- 必须走命令行 uci add_list，否则页面加载即报错。
    if not m2.uci:get("dnssettings", "dnsmasq", "forward_v4") then
        luci.sys.exec("uci add_list dnssettings.dnsmasq.forward_v4='223.5.5.5'")
        luci.sys.exec("uci add_list dnssettings.dnsmasq.forward_v4='119.29.29.29'")
        changed = true
    end
    if not m2.uci:get("dnssettings", "dnsmasq", "forward_v6") then
        luci.sys.exec("uci add_list dnssettings.dnsmasq.forward_v6='2400:3200::1'")
        luci.sys.exec("uci add_list dnssettings.dnsmasq.forward_v6='2402:4e00::'")
        changed = true
    end

    if changed then luci.sys.exec("uci commit dnssettings") end
end
_ensure_dns_defaults()

return m, m_v6, m_lan, m2
