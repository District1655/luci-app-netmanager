-- 静态 IP / IPv6 分配 - v1.4.3
-- v1.4.3 更新：
--   1. 在线客户端识别增强：IPv4（dnsmasq 租约 + ARP）+ IPv6（odhcpd 租约 + NDP 邻居表，覆盖 SLAAC 地址）
--   2. 自动捕获 DUID：dnsmasq clientid / odhcpd 租约 / 主机名关联，在线设备 DUID 直接可见
--   3. 冲突检测增强：MAC / IPv4 / 完整IPv6 / hostid 全部实时查重（修复旧版快照导致同批提交漏检）
--   4. 修复幽灵条目：MAC 与 DUID 均为空的条目在保存时自动清理，不再"消失但占位"
--   5. ARP / NDP 过滤 WAN 侧条目；dnsmasq 由 restart 改为 reload，避免 DNS 短暂中断
-- v1.2.1 历史：移除 luci.sys.net 依赖（iStoreOS 24.10 ucode 版 LuCI 不存在该模块），
--              改用直接读取系统文件获取在线设备

local sys = require "luci.sys"

-- ============================================================
-- 工具函数：HTML 转义（主机名/IP 来自外部数据，输出前必须转义）
-- ============================================================
local function esc(s)
    s = tostring(s or "")
    s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub("\"", "&quot;")
    return s
end

-- ============================================================
-- 工具函数：获取在线设备信息（IPv4 + IPv6 + DUID）
-- 数据源（4 份交叉关联，均不依赖 luci.sys.net）：
--   1. dnsmasq 租约  <leasefile>        -> MAC / IPv4 / 主机名 / clientid(可能为 DUID)
--   2. ARP 表        /proc/net/arp      -> MAC / IPv4（静态设备），过滤 WAN 侧
--   3. odhcpd 租约   <leasefile>        -> DUID / IPv6 地址(DHCPv6) / 主机名
--   4. NDP 邻居表    ip -6 neigh show   -> IPv6 <-> MAC（含 SLAAC 隐私地址），过滤 WAN 侧
-- 返回 { [MAC_UPPER] = { ip, ip6s={}, hostname, duid, online } }
-- 在线判定：ARP 完成态(Flags != 0x0) 或 NDP 表中出现 lladdr（租约存在仅作信息，不算在线）
-- ============================================================
local function get_online_devices()
    local devices = {}
    local uci = require "uci".cursor()

    -- 租约文件路径允许 UCI 覆盖（默认与 OpenWrt 一致）
    local dhcp_leasefile = "/tmp/dhcp.leases"
    local od_leasefile = "/tmp/odhcpd.leases"
    if uci then
        local lf = uci:get_first("dhcp", "dnsmasq", "leasefile")
        if lf and lf ~= "" then dhcp_leasefile = lf end
        lf = uci:get_first("dhcp", "odhcpd", "leasefile")
        if lf and lf ~= "" then od_leasefile = lf end
    end

    local function ensure(mac_upper)
        local d = devices[mac_upper]
        if not d then
            d = { ip = "", ip6s = {}, hostname = "", duid = "", online = false }
            devices[mac_upper] = d
        end
        return d
    end

    local function push_ip6(d, addr)
        for _, a in ipairs(d.ip6s) do
            if a == addr then return end
        end
        table.insert(d.ip6s, addr)
    end

    local function looks_like_duid(s)
        return s and #s >= 8 and #s <= 64 and s:match("^[0-9a-fA-F]+$") ~= nil
    end

    -- 1. dnsmasq DHCPv4 租约: <ts> <mac> <ip> <hostname> [clientid]
    local f = io.open(dhcp_leasefile, "r")
    if f then
        for line in f:lines() do
            local mac, ip, hostname, clientid = line:match("^%S+%s+(%S+)%s+(%S+)%s+(%S+)%s*(%S*)")
            if mac and ip then
                local d = ensure(mac:upper())
                if d.ip == "" then d.ip = ip end
                if hostname and hostname ~= "" and hostname ~= "*" and d.hostname == "" then
                    d.hostname = hostname
                end
                if clientid and clientid ~= "" then
                    -- DHCPv6 客户端通常以 DUID 作为 DHCPv4 的 clientid（形如 id:00:01:...）
                    local cid = clientid:gsub("^id:", ""):gsub(":", "")
                    if looks_like_duid(cid) then d.duid = cid end
                end
            end
        end
        f:close()
    end

    -- 2. ARP 表: IP | HWtype | Flags | HWaddress | Mask | Device
    f = io.open("/proc/net/arp", "r")
    if f then
        local first = true
        for line in f:lines() do
            if first then
                first = false
            else
                local ip, flags, mac, dev = line:match("^(%S+)%s+%S+%s+(%S+)%s+(%S+)%s+%S+%s+(%S+)")
                if mac and ip and mac ~= "00:00:00:00:00:00" and dev and not dev:match("^wan") then
                    local d = ensure(mac:upper())
                    if d.ip == "" then d.ip = ip end
                    if flags ~= "0x0" then d.online = true end
                end
            end
        end
        f:close()
    end

    -- 3. odhcpd DHCPv6 租约: <duid> <iaid> <name> <ts> <id> <len> <addr>
    --    行首 '#' 为前缀委托(PD)行，跳过；len=128 为地址分配
    local addr_duid = {}  -- [ipv6addr] = duid
    local name_duid = {}  -- [hostname] = duid（主机名兜底关联）
    f = io.open(od_leasefile, "r")
    if f then
        for line in f:lines() do
            if line:sub(1, 1) ~= "#" then
                local duid, name, len, addr = line:match("^(%S+)%s+%S+%s+(%S+)%s+%S+%s+%S+%s+(%S+)%s+(%S+)")
                if duid and addr then
                    addr_duid[addr] = duid
                    if name and name ~= "" and name ~= "*" and not name_duid[name] then
                        name_duid[name] = duid
                    end
                end
            end
        end
        f:close()
    end

    -- 4. NDP 邻居表: <addr> dev <dev> lladdr <mac> <state>（排除链路本地与 WAN 侧）
    f = io.popen("ip -6 neigh show 2>/dev/null", "r")
    if f then
        for line in f:lines() do
            local addr, dev, rest = line:match("^(%S+)%s+dev%s+(%S+)%s*(.-)%s*$")
            if addr and dev and not dev:match("^wan") and not addr:match("^fe80") then
                local mac6 = rest:match("lladdr%s+(%S+)")
                if mac6 and mac6 ~= "00:00:00:00:00:00" then
                    local d = ensure(mac6:upper())
                    d.online = true
                    push_ip6(d, addr)
                    if d.duid == "" and addr_duid[addr] then d.duid = addr_duid[addr] end
                end
            end
        end
        f:close()
    end

    -- 5. 主机名兜底关联 DUID（DHCPv4 租约无 DUID 型 clientid 时）
    for _, d in pairs(devices) do
        if d.duid == "" and d.hostname ~= "" and name_duid[d.hostname] then
            d.duid = name_duid[d.hostname]
        end
    end

    return devices
end

-- ============================================================
-- 工具函数：合并同 MAC 的重复 host 条目
-- ============================================================
local function merge_duplicate_hosts()
    local x = require "uci".cursor()
    local mac_seen = {}
    local to_delete = {}

    x:foreach("dhcp", "host", function(s)
        local mac = s.mac
        if mac and mac ~= "" then
            mac = mac:upper()
            if mac_seen[mac] then
                local keep = mac_seen[mac]
                if s.duid and s.duid ~= "" and not keep.duid then
                    x:set("dhcp", keep[".name"], "duid", s.duid)
                end
                if s.ip and s.ip ~= "" and not keep.ip then
                    x:set("dhcp", keep[".name"], "ip", s.ip)
                end
                if s.hostid and s.hostid ~= "" and (not keep.hostid or keep.hostid == "") then
                    x:set("dhcp", keep[".name"], "hostid", s.hostid)
                end
                if s.ip6 and s.ip6 ~= "" and not keep.ip6 then
                    x:set("dhcp", keep[".name"], "ip6", s.ip6)
                end
                if s.name and s.name ~= "" and not keep.name then
                    x:set("dhcp", keep[".name"], "name", s.name)
                end
                if s.enabled and not keep.enabled then
                    x:set("dhcp", keep[".name"], "enabled", s.enabled)
                end
                table.insert(to_delete, s[".name"])
            else
                mac_seen[mac] = s
            end
        end
    end)

    for _, name in ipairs(to_delete) do
        x:delete("dhcp", name)
    end

    if #to_delete > 0 then
        x:commit("dhcp")
    end

    return #to_delete
end

-- ============================================================
-- 页面加载时执行合并 + 获取在线设备 + 已绑定 MAC
-- ============================================================
local merged_count = merge_duplicate_hosts()
local online_devices = get_online_devices()

-- 已绑定 MAC（在线速览标记用）
local bound_macs = {}
local uci_cursor = require "uci".cursor()
uci_cursor:foreach("dhcp", "host", function(s)
    if s.mac and s.mac ~= "" then
        bound_macs[s.mac:upper()] = true
    end
end)

-- 在线客户端速览行（MAC 排序，仅列出至少有一个 IP 的设备）
local ov_rows = {}
for mac, d in pairs(online_devices) do
    local has_ip = (d.ip ~= "") or (#d.ip6s > 0)
    if has_ip then
        table.insert(ov_rows, {
            mac = mac, name = d.hostname, ip = d.ip,
            ip6s = d.ip6s, duid = d.duid,
            bound = bound_macs[mac] and true or false
        })
    end
end
table.sort(ov_rows, function(a, b) return a.mac < b.mac end)

-- 生成在线客户端速览 HTML
local function build_online_html()
    local out = {}
    if #ov_rows == 0 then
        table.insert(out, '<em style="color:#999">' .. translate("未发现任何在线客户端") .. '</em>')
        return table.concat(out, "\n")
    end
    table.insert(out, '<table class="table" style="width:auto;min-width:70%;margin-bottom:0;font-size:13px;">')
    table.insert(out, '<tr><th>MAC</th><th>' .. translate("主机名") .. '</th><th>IPv4</th><th>IPv6</th><th>' .. translate("绑定状态") .. '</th></tr>')
    for _, r in ipairs(ov_rows) do
        local v4 = r.ip ~= "" and esc(r.ip) or '-'
        local v6s = {}
        for _, a in ipairs(r.ip6s) do
            table.insert(v6s, '<span style="color:#2471a3">' .. esc(a) .. '</span>')
        end
        local v6 = (#v6s > 0) and table.concat(v6s, '<br>') or '-'
        local name = r.name ~= "" and esc(r.name) or '-'
        local badge = r.bound
            and '<span style="color:#2ecc71">●</span> ' .. translate("已绑定")
            or '<span style="color:#e67e22">○</span> ' .. translate("未绑定")
        table.insert(out, string.format(
            '<tr><td style="font-family:monospace">%s</td><td>%s</td>' ..
            '<td style="font-family:monospace">%s</td>' ..
            '<td style="font-family:monospace;word-break:break-all;max-width:280px">%s</td>' ..
            '<td>%s</td></tr>',
            esc(r.mac), name, v4, v6, badge))
    end
    table.insert(out, '</table>')
    return table.concat(out, "\n")
end
local online_html = build_online_html()

-- ============================================================
-- 页面描述
-- ============================================================
local desc = translate("为设备绑定静态 IPv4 / IPv6 地址。IPv4 填 ip；IPv6 推荐填 hostid（地址后缀），运营商前缀变化时地址仍保持一致；ip6 填完整地址，仅适合 ULA 或前缀固定场景。")
if merged_count > 0 then
    desc = desc .. " \n\n" .. translate("注意") .. "：" .. translate("已自动合并") .. " " .. merged_count .. " " .. translate("个重复的 MAC 绑定条目。")
end

m = Map("dhcp", translate("静态 IP / IPv6 分配"), desc)

-- 保存前清理幽灵条目（MAC 与 DUID 均为空，避免"消失但占位"无法删除）
m.on_before_commit = function(self)
    local to_del = {}
    self.uci:foreach("dhcp", "host", function(s)
        local mac = s.mac or ""
        local duid = s.duid or ""
        if mac == "" and duid == "" then
            table.insert(to_del, s[".name"])
        end
    end)
    for _, n in ipairs(to_del) do
        self.uci:delete("dhcp", n)
    end
end

-- 保存后应用配置（odhcpd 需 restart；dnsmasq 用 reload 避免 DNS 中断）
m.on_after_commit = function(self)
    sys.call("/etc/init.d/odhcpd restart >/dev/null 2>&1")
    sys.call("/etc/init.d/dnsmasq reload >/dev/null 2>&1")
end

-- ============================================================
-- 在线客户端速览（含未绑定设备，方便复制 MAC / DUID 到下方新增绑定）
-- ============================================================
local ss = m:section(SimpleSection, translate("在线客户端"), translate("列出当前识别到的在线设备（IPv4 + IPv6）。未绑定设备可直接复制其 MAC 地址，在下方「设备列表」新增绑定。"))
local ov = ss:option(DummyValue, "_online_clients")
ov.rawhtml = true
function ov.cfgvalue(self, section)
    return online_html
end

-- ============================================================
-- 设备列表
-- ============================================================
s = m:section(TypedSection, "host", translate("设备列表"))
s.addremove = true
s.anonymous = true
s.sortable = false
s.template = "cbi/tblsection"

-- 显示有 MAC 或有 DUID 的条目（支持 IPv6-only 绑定；全空条目由 on_before_commit 清理）
function s.filter(self, section)
    local mac = m.uci:get("dhcp", section, "mac")
    local duid = m.uci:get("dhcp", section, "duid")
    return (mac ~= nil and mac ~= "") or (duid ~= nil and duid ~= "")
end

-- ---------- 主机名 ----------
o_hostname = s:option(Value, "name", translate("主机名"))
o_hostname.rmempty = true
o_hostname.datatype = "hostname"
o_hostname.size = 14

-- ---------- MAC 地址 ----------
o_mac = s:option(Value, "mac", translate("MAC 地址"))
o_mac.rmempty = false
o_mac.datatype = "macaddr"
o_mac.size = 18
o_mac.description = translate("MAC 与 DUID 至少填一个；留空 MAC 仅适用于纯 DHCPv6(DUID) 绑定")
function o_mac.validate(self, value, section)
    if value and value ~= "" then
        value = value:upper()
        if not value:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
            return nil, translate("MAC 地址格式无效（应为 AA:BB:CC:DD:EE:FF）")
        end
        -- 实时查重（含同批提交的新值，而非页面加载时快照）
        local conflict
        m.uci:foreach("dhcp", "host", function(s2)
            if s2[".name"] ~= section and s2.mac and s2.mac ~= "" and s2.mac:upper() == value then
                conflict = s2.name or s2.mac
            end
        end)
        if conflict then
            return nil, translate("该 MAC 已被其他条目绑定") .. ": " .. esc(conflict)
        end
        return value
    end
    return value
end

-- ---------- 当前在线 IP（只读，IPv4 + IPv6） ----------
o_cur_ip = s:option(DummyValue, "_current_ip", translate("当前在线IP"))
o_cur_ip.rawhtml = true
function o_cur_ip.cfgvalue(self, section)
    local mac_val = m.uci:get("dhcp", section, "mac")
    if mac_val then
        local dev = online_devices[mac_val:upper()]
        if dev then
            local parts = {}
            if dev.ip and dev.ip ~= "" then
                table.insert(parts, '<span style="font-family:monospace">' .. esc(dev.ip) .. '</span>')
            end
            for _, a in ipairs(dev.ip6s) do
                table.insert(parts, '<span style="font-family:monospace;color:#2471a3;word-break:break-all">' .. esc(a) .. '</span>')
            end
            if dev.duid and dev.duid ~= "" then
                table.insert(parts, '<span style="color:#e67e22;font-family:monospace;font-size:10px">DUID: ' .. esc(dev.duid) .. '</span>')
            end
            if #parts > 0 then
                local dot = dev.online and '<span style="color:#2ecc71">●</span>' or '<span style="color:#999">○</span>'
                return dot .. ' ' .. table.concat(parts, '<br>')
            end
        end
    end
    return '<span style="color:#999">○ ' .. translate("离线/未发现") .. '</span>'
end

-- ---------- IPv4 静态地址 ----------
o_ip4 = s:option(Value, "ip", translate("IPv4静态地址"))
o_ip4.rmempty = true
o_ip4.datatype = "ip4addr"
o_ip4.size = 15
function o_ip4.validate(self, value, section)
    if value and value ~= "" then
        local conflict
        m.uci:foreach("dhcp", "host", function(s2)
            if s2[".name"] ~= section and s2.ip and s2.ip ~= "" and s2.ip == value then
                conflict = s2.mac or s2.name or s2[".name"]
            end
        end)
        if conflict then
            return nil, translate("该 IPv4 已被其他条目使用") .. ": " .. esc(conflict)
        end
    end
    return value
end

-- ---------- IPv6 hostid ----------
o_hostid = s:option(Value, "hostid", translate("IPv6 hostid"))
o_hostid.rmempty = true
o_hostid.size = 10
o_hostid.description = translate("十六进制后缀，如 fbe = 前缀::fbe")
function o_hostid.validate(self, value, section)
    if value and value ~= "" then
        if not value:match("^[0-9a-fA-F]+$") then
            return nil, translate("hostid 必须是十六进制字符（0-9, a-f）")
        end
        if #value > 8 then
            return nil, translate("hostid 最多 8 位十六进制")
        end
        local val_lower = value:lower()
        local conflict
        m.uci:foreach("dhcp", "host", function(s2)
            if s2[".name"] ~= section and s2.hostid and s2.hostid ~= "" and s2.hostid:lower() == val_lower then
                conflict = s2.mac or s2.name or s2[".name"]
            end
        end)
        if conflict then
            return nil, translate("hostid 与其他设备冲突，请换一个值") .. ": " .. esc(conflict)
        end
    end
    return value
end

-- ---------- 完整 IPv6 地址 ----------
o_ip6 = s:option(Value, "ip6", translate("完整IPv6地址(可选)"))
o_ip6.rmempty = true
o_ip6.datatype = "ip6addr"
o_ip6.size = 28
o_ip6.description = translate("仅适合 ULA(fd开头)，留空则用 hostid 自动生成")
function o_ip6.validate(self, value, section)
    if value and value ~= "" then
        local val_lower = value:lower()
        local conflict
        m.uci:foreach("dhcp", "host", function(s2)
            if s2[".name"] ~= section and s2.ip6 and s2.ip6 ~= "" and s2.ip6:lower() == val_lower then
                conflict = s2.mac or s2.name or s2[".name"]
            end
        end)
        if conflict then
            return nil, translate("该完整 IPv6 地址已被其他条目使用") .. ": " .. esc(conflict)
        end
    end
    return value
end

-- ---------- DUID（可编辑，统一无冒号 hex 存储） ----------
o_duid = s:option(Value, "duid", translate("DUID(可选)"))
o_duid.rmempty = true
o_duid.size = 24
o_duid.description = translate("DHCPv6 专有标识，用于 IPv6-only 绑定；设备在线时可在「当前在线IP」列查看捕获值")
function o_duid.validate(self, value, section)
    if value and value ~= "" then
        local stripped = value:gsub(":", "")
        if not stripped:match("^[0-9a-fA-F]+$") or #stripped < 4 or #stripped > 130 then
            return nil, translate("DUID 格式无效（应为十六进制，可带冒号）")
        end
        return stripped  -- odhcpd 用 unheximize 解析，必须无冒号
    end
    return value
end

-- ---------- 启用开关 ----------
o_enabled = s:option(Flag, "enabled", translate("启用"))
o_enabled.rmempty = false
o_enabled.default = "1"

return m
