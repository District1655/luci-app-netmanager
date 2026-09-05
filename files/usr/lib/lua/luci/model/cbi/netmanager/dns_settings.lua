-- 上网设置插件 - CBI 表单模型
-- 原 DNS 设置模块，v1.6.0 扩展为上网设置：WAN口上网方式 + LAN口地址 + DNS设置
-- 绑定 /etc/config/network + /etc/config/dnssettings

local m, s, o

-- ============================================================
-- 第一部分：上网设置（WAN口 + LAN口，绑定 network 配置）
-- ============================================================
m = Map("network", translate("上网设置"),
    translate("统一管理 WAN 口上网方式、LAN 口地址与 DNS 服务器。修改后点击「应用配置」生效。")
    .. "<br><em style='color:#6b7280;font-size:12px;'>"
    .. translate("修改 WAN/LAN 口设置会重启网络服务，期间短暂断网；DNS 配置应用前自动备份到 /root/backup/。")
    .. "</em>")

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

-- ---------- LAN 口地址设置 ----------
s = m:section(NamedSection, "lan", "interface", translate("LAN 口地址"),
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
-- 第二部分：DNS 设置（绑定 dnssettings 配置）
-- ============================================================
local m2 = Map("dnssettings", translate("DNS 设置"),
    translate("统一管理 WAN/LAN 的 IPv4 和 IPv6 DNS 服务器。"))

-- ---------- WAN 口上游 DNS ----------
s = m2:section(NamedSection, "wan", "dnssettings", translate("WAN 口上游 DNS"),
    translate("路由器本身解析域名使用的 DNS，PPPoE/DHCP 拨号时生效。"))

o = s:option(Flag, "peerdns", translate("使用运营商下发的 DNS"),
    translate("勾选则使用拨号时运营商自动分配的 DNS；取消则使用下方自定义 DNS。"))
o.default = "0"
o.rmempty = false

o = s:option(Value, "dns1_v4", translate("IPv4 主 DNS"))
o.datatype = "ip4addr"
o.placeholder = "223.5.5.5"
o.default = "223.5.5.5"
o:depends("peerdns", "0")

o = s:option(Value, "dns2_v4", translate("IPv4 备 DNS"))
o.datatype = "ip4addr"
o.placeholder = "119.29.29.29"
o.default = "119.29.29.29"
o:depends("peerdns", "0")

o = s:option(Value, "dns1_v6", translate("IPv6 主 DNS"))
o.datatype = "ip6addr"
o.placeholder = "2400:3200::1"
o.default = "2400:3200::1"
o:depends("peerdns", "0")

o = s:option(Value, "dns2_v6", translate("IPv6 备 DNS"))
o.datatype = "ip6addr"
o.placeholder = "2402:4e00::"
o.default = "2402:4e00::"
o:depends("peerdns", "0")

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

o = s:option(DynamicList, "forward_v4", translate("IPv4 转发 DNS"))
o.datatype = "ip4addr"
o.placeholder = "223.5.5.5"
o:depends("enable", "1")

o = s:option(DynamicList, "forward_v6", translate("IPv6 转发 DNS"))
o.datatype = "ip6addr"
o.placeholder = "2400:3200::1"
o:depends("enable", "1")

-- ---------- 操作按钮（v1.6.0 移除备份按钮，统一由设置页面备份模块管理） ----------
s = m2:section(NamedSection, "actions", "dnssettings", translate("操作"))

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
    -- 先保存 network 配置（WAN/LAN 口设置）
    m.uci:commit("network")
    -- 再保存 dnssettings 配置
    m2.uci:commit("dnssettings")

    -- 执行 DNS 应用脚本
    local ok, rc, out = pcall(run_dns_script, "/usr/sbin/dnssettings-apply.sh")
    if not ok then
        m2.message = "DNS 配置应用执行异常：" .. to_one_line(tostring(rc))
        return
    end

    -- 重启网络服务（应用 WAN/LAN 口设置）
    luci.sys.exec("/etc/init.d/network restart >/dev/null 2>&1")

    if rc == 0 then
        m2.message = "配置已应用成功，已写入 /etc/config/ 并重启网络服务（详细输出见「设置 → 运行日志」）"
    else
        m2.message = "配置应用失败 (exit=" .. tostring(rc) .. ")：" .. to_one_line(out)
    end
end

-- v1.6.0 修复：/etc/config/dnssettings 为空或缺失节时，自动初始化默认节
local function _ensure_dns_defaults()
    local need_init = false
    for _, sec in ipairs({"wan", "lan", "dnsmasq", "actions"}) do
        if not m2.uci:get("dnssettings", sec) then
            need_init = true
            break
        end
    end
    if not need_init then return end

    local cmds = {
        "uci set dnssettings.wan=dnssettings",
        "uci set dnssettings.wan.peerdns='0'",
        "uci set dnssettings.wan.dns1_v4='223.5.5.5'",
        "uci set dnssettings.wan.dns2_v4='119.29.29.29'",
        "uci set dnssettings.wan.dns1_v6='2400:3200::1'",
        "uci set dnssettings.wan.dns2_v6='2402:4e00::'",
        "uci set dnssettings.lan=dnssettings",
        "uci set dnssettings.lan.force_dns='1'",
        "uci set dnssettings.lan.dns1_v4='223.5.5.5'",
        "uci set dnssettings.lan.dns2_v4='119.29.29.29'",
        "uci set dnssettings.lan.dns1_v6='2400:3200::1'",
        "uci set dnssettings.lan.dns2_v6='2402:4e00::'",
        "uci set dnssettings.dnsmasq=dnssettings",
        "uci set dnssettings.dnsmasq.enable='1'",
        "uci delete dnssettings.dnsmasq.forward_v4",
        "uci delete dnssettings.dnsmasq.forward_v6",
        "uci add_list dnssettings.dnsmasq.forward_v4='223.5.5.5'",
        "uci add_list dnssettings.dnsmasq.forward_v4='119.29.29.29'",
        "uci add_list dnssettings.dnsmasq.forward_v6='2400:3200::1'",
        "uci add_list dnssettings.dnsmasq.forward_v6='2402:4e00::'",
        "uci set dnssettings.actions=dnssettings",
        "uci commit dnssettings",
    }
    for _, cmd in ipairs(cmds) do
        luci.sys.exec(cmd)
    end
end
_ensure_dns_defaults()

return m, m2
