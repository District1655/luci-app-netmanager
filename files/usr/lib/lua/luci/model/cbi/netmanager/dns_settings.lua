-- DNS设置插件 - CBI 表单模型
-- 绑定 /etc/config/dnssettings

local m, s, o

m = Map("dnssettings", translate("DNS设置"),
    translate("统一管理 WAN/LAN 的 IPv4 和 IPv6 DNS 服务器。修改后点击「应用配置」生效。")
    .. "<br><em style='color:#6b7280;font-size:12px;'>"
    .. translate("防护说明：自定义 DNS 模式下若 DNS 留空，应用时将跳过该接口保持现状（防止断网）；每次应用前自动备份到 /root/backup/。")
    .. "</em>")

-- v1.4.6 修复：CBI 页面缺少页内导航（从自绘页面进入后页签消失），注入导航模板
m:append(Template("netmanager/cbi_nav"))

-- ============================================================
-- 第一部分：WAN 口 DNS（上游 DNS，路由器自己用）
-- ============================================================
s = m:section(NamedSection, "wan", "wan", translate("WAN 口上游 DNS"),
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

-- ============================================================
-- 第二部分：LAN 口 DNS（下发给设备的 DNS）
-- ============================================================
s = m:section(NamedSection, "lan", "lan", translate("LAN 口设备 DNS"),
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

-- ============================================================
-- 第三部分：dnsmasq 全局转发
-- ============================================================
s = m:section(NamedSection, "dnsmasq", "dnsmasq", translate("dnsmasq 全局转发"),
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

-- ============================================================
-- 第四部分：操作按钮（POST 化：原 GET 路由已并入 api_handler，redirect 会 404）
-- 按钮直接执行脚本并渲染结果页（CBI 框架按钮自带 token 校验，无 CSRF 风险）
-- ============================================================
s = m:section(NamedSection, "actions", "actions", translate("操作"))

-- 【v1.4.6】执行 DNS 脚本并返回结果：捕获输出与退出码（原 __RC__ 标记法）
local function run_dns_script(script)
    local out = luci.sys.exec(script .. " 2>&1; echo \"__RC__$?\"") or ""
    local rc = tonumber(out:match("__RC__(%-?%d+)")) or -1
    out = out:gsub("__RC__%-?%d+\n?$", "")
    return rc, out
end

-- 【v1.4.6】输出压缩为单行消息（alert 框内换行不渲染，pcdata 只转义文本）
local function to_one_line(s, max)
    s = (s or ""):gsub("%c", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #s > (max or 300) then s = s:sub(1, max) .. "..." end
    return s
end

o = s:option(Button, "_apply", translate("应用配置"))
o.inputtitle = translate("应用配置")
o.inputstyle = "apply"
o.write = function()
    -- 【v1.4.7 防御】脚本执行异常（如环境差异）不再炸整个 POST 请求，
    -- 错误文本透传到页面消息，便于定位
    local ok, rc, out = pcall(run_dns_script, "/usr/sbin/dnssettings-apply.sh")
    if not ok then
        m.message = "DNS 配置应用执行异常：" .. to_one_line(tostring(rc))
        return
    end
    if rc == 0 then
        m.message = "DNS 配置已应用成功，已写入 /etc/config/ 并重载网络服务（详细输出见「设置 → 运行日志」）"
    else
        m.message = "DNS 配置应用失败 (exit=" .. tostring(rc) .. ")：" .. to_one_line(out)
    end
end

o = s:option(Button, "_backup", translate("备份当前系统配置"))
o.inputtitle = translate("备份配置")
o.inputstyle = "save"
o.write = function()
    local ok, rc, out = pcall(run_dns_script, "/usr/sbin/dnssettings-backup.sh")
    if not ok then
        m.message = "配置备份执行异常：" .. to_one_line(tostring(rc))
        return
    end
    if rc == 0 then
        m.message = "配置已备份到 /root/backup/（保留最近 5 份）"
    else
        m.message = "配置备份失败 (exit=" .. tostring(rc) .. ")：" .. to_one_line(out)
    end
end

return m
