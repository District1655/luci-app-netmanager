-- 静态 IP / IPv6 分配 - v1.4.7
-- v1.4.7 更新：
--   on_before_commit 以 pcall 包裹：重复条目合并/幽灵清理异常不再中断保存，
--   错误文本透传到页面消息（ucode LuCI 环境差异导致的问题可被用户直接看到）
-- v1.4.6 更新：
--   1. 重复 host 合并改为"仅检测、提交时执行"（原页面加载即 commit，GET 刷新就会改配置）
--   2. DUID 误判修复：排除 DHCPv4 clientid 中的 MAC 原文型 / 01+MAC 硬件型标识
--   3. WAN 侧过滤增强：设备名匹配 wan 前缀同时覆盖 pppoe-wan / pppoe-wan6 等命名
--   4. odhcpd 重启改为按需（m.changed 才 restart，无改动不扰动 IPv6 分配）
-- v1.4.3 历史：
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
    -- v1.4.6 兼容性修复：不再调用 uci:get_first()，改用 foreach 实现同语义。
    -- 原因：iStoreOS 24.10 / OpenWrt 24.10+ 的 ucode 版 LuCI 中，Lua CBI 经
    --       ucodebridge 桥接执行，桥接的 uci cursor 没有 get_first 扩展方法，
    --       报 "attempt to call method 'get_first' (a nil value)"。
    --       foreach/get/set/commit 桥接均支持（merge_duplicate_hosts 已验证）。
    local dhcp_leasefile = "/tmp/dhcp.leases"
    local od_leasefile = "/tmp/odhcpd.leases"
    if uci then
        local function first_opt(stype, opt)
            local v
            uci:foreach("dhcp", stype, function(sec)
                if not v and sec[opt] and sec[opt] ~= "" then
                    v = sec[opt]
                end
            end)
            return v
        end
        local lf = first_opt("dnsmasq", "leasefile")
        if lf then dhcp_leasefile = lf end
        lf = first_opt("odhcpd", "leasefile")
        if lf then od_leasefile = lf end
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
                    -- 【v1.4.6 误判修复】排除两种"伪 DUID"：
                    --   a) MAC 原文型：部分客户端直接把 MAC 塞进 clientid（dnsmasq 去掉冒号后 12 位 hex 与本条目 MAC 相同）
                    --   b) 01+MAC 硬件型：DUID-LLT/DUID-EN 前缀形如 01:xx:xx:xx:xx:xx:xx...，其中含 MAC 的非真正 DUID
                    local cid = clientid:gsub("^id:", ""):gsub(":", "")
                    if looks_like_duid(cid) then
                        local mac_nocolon = mac:gsub(":", ""):lower()
                        local is_mac_itself = (cid:lower() == mac_nocolon)
                        local is_01mac_type = cid:lower():sub(1, 2) == "01" and cid:lower():find(mac_nocolon, 1, true)
                        if not is_mac_itself and not is_01mac_type then
                            d.duid = cid
                        end
                    end
                end
            end
        end
        f:close()
    end

    -- 【v1.4.6】WAN 侧设备判定：设备名或命名以 wan 结尾/包含 wan 词段（覆盖 wan / wan6 /
    -- pppoe-wan / pppoe-wan6 / ppp0-wan / wan-eth 等），避免把 PPPoE 拨号对端误判为 LAN 设备
    local function is_wan_side(dev)
        if not dev or dev == "" then return false end
        return dev:match("wan") ~= nil
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
                if mac and ip and mac ~= "00:00:00:00:00:00" and not is_wan_side(dev) then
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
            if addr and dev and not is_wan_side(dev) and not addr:match("^fe80") then
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
-- 【v1.4.6】拆分为两步：
--   1. detect_duplicate_hosts()：页面加载时只统计不写库（原实现 GET 刷新页面
--      就会静默 commit 修改 /etc/config/dhcp）
--   2. do_merge_duplicate_hosts()：真正执行合并，挪到 on_before_commit
--      （仅用户点击「保存并应用」时触发）
-- ============================================================
local function detect_duplicate_hosts()
    local x = require "uci".cursor()
    local mac_seen = {}
    local count = 0

    x:foreach("dhcp", "host", function(s)
        local mac = s.mac
        if mac and mac ~= "" then
            mac = mac:upper()
            if mac_seen[mac] then
                count = count + 1
            else
                mac_seen[mac] = true
            end
        end
    end)

    return count
end

-- 提交时真正执行合并（保留首条字段较全的条目，补齐其缺失字段后删除重复项）
local function do_merge_duplicate_hosts(uci_handle)
    local x = uci_handle or require "uci".cursor()
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

    return #to_delete
end

-- ============================================================
-- 页面加载时执行：仅检测重复（只读）+ 获取在线设备 + 已绑定 MAC
-- ============================================================
local merged_count = detect_duplicate_hosts()
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

-- 生成在线客户端速览 HTML（v1.5.1 优化：IPv6 地址折叠、彩色徽章、在线状态、DUID 显示）
local function build_online_html()
    local out = {}
    if #ov_rows == 0 then
        table.insert(out, '<div style="padding:20px;text-align:center;color:#9ca3af;font-size:13px;">' .. translate("未发现任何在线客户端") .. '</div>')
        return table.concat(out, "\n")
    end

    -- 内联样式 + JS（IPv6 折叠展开）
    table.insert(out, '<style>')
    table.insert(out, '.nm-ov-table { width:100%; border-collapse:collapse; font-size:13px; margin-bottom:0; }')
    table.insert(out, '.nm-ov-table th { background:#f9fafb; padding:10px 12px; text-align:left; font-weight:600; color:#6b7280; font-size:12px; border-bottom:2px solid #e5e7eb; }')
    table.insert(out, '.nm-ov-table td { padding:9px 12px; border-bottom:1px solid #f3f4f6; vertical-align:top; }')
    table.insert(out, '.nm-ov-table tr:hover td { background:#f9fafb; }')
    table.insert(out, '.nm-ov-mono { font-family:"Consolas","Monaco",monospace; font-size:12px; }')
    table.insert(out, '.nm-ov-v6-main { color:#2563eb; font-family:"Consolas","Monaco",monospace; font-size:12px; word-break:break-all; }')
    table.insert(out, '.nm-ov-v6-more { color:#6b7280; font-size:11px; cursor:pointer; text-decoration:underline; margin-left:4px; }')
    table.insert(out, '.nm-ov-v6-all { display:none; margin-top:4px; }')
    table.insert(out, '.nm-ov-v6-all span { display:block; color:#2563eb; font-family:"Consolas","Monaco",monospace; font-size:11px; word-break:break-all; margin-bottom:2px; }')
    table.insert(out, '.nm-ov-badge { display:inline-block; padding:2px 10px; border-radius:10px; font-size:11px; font-weight:600; }')
    table.insert(out, '.nm-ov-badge-bound { background:#d1fae5; color:#059669; }')
    table.insert(out, '.nm-ov-badge-unbound { background:#fef3c7; color:#d97706; }')
    table.insert(out, '.nm-ov-online { display:inline-block; width:8px; height:8px; border-radius:50%; background:#10b981; margin-right:5px; box-shadow:0 0 4px #10b981; }')
    table.insert(out, '.nm-ov-offline { display:inline-block; width:8px; height:8px; border-radius:50%; background:#d1d5db; margin-right:5px; }')
    table.insert(out, '.nm-ov-duid { color:#9ca3af; font-size:10px; font-family:"Consolas",monospace; word-break:break-all; max-width:160px; }')
    table.insert(out, '</style>')

    table.insert(out, '<script>')
    table.insert(out, 'function nmToggleV6(id){var el=document.getElementById(id);var btn=document.getElementById(id+"_btn");if(el.style.display==="block"){el.style.display="none";btn.textContent=btn.getAttribute("data-more");}else{el.style.display="block";btn.textContent="收起";}}')
    table.insert(out, '</script>')

    table.insert(out, '<table class="nm-ov-table">')
    table.insert(out, '<tr><th style="width:130px">' .. translate("状态") .. '</th><th style="width:140px">MAC</th><th>' .. translate("主机名") .. '</th><th style="width:130px">IPv4</th><th>IPv6</th><th style="width:90px">' .. translate("绑定") .. '</th></tr>')

    local row_idx = 0
    for _, r in ipairs(ov_rows) do
        row_idx = row_idx + 1
        local v4 = r.ip ~= "" and esc(r.ip) or '<span style="color:#d1d5db">—</span>'
        local name = r.name ~= "" and esc(r.name) or '<span style="color:#d1d5db">—</span>'

        -- IPv6 地址折叠：过滤掉链路本地地址(fe80)，全局地址第一个显示，其余折叠
        local global_v6 = {}
        for _, a in ipairs(r.ip6s) do
            if not a:match("^fe80") then
                table.insert(global_v6, a)
            end
        end

        local v6_html = ""
        if #global_v6 == 0 then
            v6_html = '<span style="color:#d1d5db">—</span>'
        else
            v6_html = '<span class="nm-ov-v6-main">' .. esc(global_v6[1]) .. '</span>'
            if #global_v6 > 1 then
                local more_count = #global_v6 - 1
                local all_id = 'nm_v6_all_' .. row_idx
                local btn_id = all_id .. '_btn'
                v6_html = v6_html .. '<span class="nm-ov-v6-more" id="' .. btn_id .. '" data-more="+' .. more_count .. ' 个" onclick="nmToggleV6(\'' .. all_id .. '\')">+' .. more_count .. ' 个</span>'
                v6_html = v6_html .. '<div class="nm-ov-v6-all" id="' .. all_id .. '">'
                for i = 2, #global_v6 do
                    v6_html = v6_html .. '<span>' .. esc(global_v6[i]) .. '</span>'
                end
                v6_html = v6_html .. '</div>'
            end
        end

        -- 绑定状态徽章
        local badge = r.bound
            and '<span class="nm-ov-badge nm-ov-badge-bound">' .. translate("已绑定") .. '</span>'
            or '<span class="nm-ov-badge nm-ov-badge-unbound">' .. translate("未绑定") .. '</span>'

        -- 在线状态 + DUID
        local status_html = '<span class="nm-ov-online"></span><span style="color:#059669;font-size:11px;font-weight:600;">在线</span>'
        if r.duid and r.duid ~= "" then
            status_html = status_html .. '<br><span class="nm-ov-duid" title="DUID: ' .. esc(r.duid) .. '">DUID: ' .. esc(r.duid:sub(1, 16)) .. '...</span>'
        end

        table.insert(out, string.format(
            '<tr><td>%s</td><td class="nm-ov-mono">%s</td><td>%s</td>' ..
            '<td class="nm-ov-mono">%s</td><td>%s</td><td>%s</td></tr>',
            status_html, esc(r.mac), name, v4, v6_html, badge))
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
    desc = desc .. " \n\n" .. translate("注意") .. "：" .. translate("检测到") .. " " .. merged_count .. " " ..
        translate("个重复的 MAC 绑定条目，点击「保存并应用」时将自动合并。")
end

m = Map("dhcp", translate("静态 IP / IPv6 分配"), desc)

-- v1.4.6 修复：CBI 页面缺少页内导航（从自绘页面进入后页签消失），注入导航模板
m:append(Template("netmanager/cbi_nav"))

-- 保存前：合并重复 MAC 条目 + 清理幽灵条目（MAC 与 DUID 均为空，避免"消失但占位"无法删除）
-- 【v1.4.6】合并由页面加载时移入此处（仅在真实提交时写库，GET 刷新不再改配置）
-- 【v1.4.7 防御】pcall 包裹：合并/清理异常不阻断用户保存，错误透传到页面消息
m.on_before_commit = function(self)
    local ok, err = pcall(function()
        do_merge_duplicate_hosts(self.uci)
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
    end)
    if not ok then
        self.message = "重复条目合并/幽灵清理失败（保存仍已继续）：" .. tostring(err)
    end
end

-- 保存后应用配置（dnsmasq 用 reload 避免 DNS 中断）
-- 【v1.4.6】odhcpd 由无条件 restart 改为按需：仅本次有实际改动（changed）才重启，
-- 避免每次保存（甚至无改动提交）都导致 IPv6 租约重置、设备短暂掉线
m.on_after_commit = function(self)
    if self.changed then
        sys.call("/etc/init.d/odhcpd restart >/dev/null 2>&1")
    end
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

-- ---------- 当前在线 IP（只读，IPv4 + IPv6 折叠显示） ----------
o_cur_ip = s:option(DummyValue, "_current_ip", translate("当前在线IP"))
o_cur_ip.rawhtml = true
local cur_ip_row = 0
function o_cur_ip.cfgvalue(self, section)
    cur_ip_row = cur_ip_row + 1
    local mac_val = m.uci:get("dhcp", section, "mac")
    if mac_val then
        local dev = online_devices[mac_val:upper()]
        if dev then
            local parts = {}
            if dev.ip and dev.ip ~= "" then
                table.insert(parts, '<span style="font-family:monospace;font-size:12px;color:#111827">' .. esc(dev.ip) .. '</span>')
            end
            -- IPv6 全局地址折叠（过滤 fe80 链路本地）
            local global_v6 = {}
            for _, a in ipairs(dev.ip6s) do
                if not a:match("^fe80") then
                    table.insert(global_v6, a)
                end
            end
            if #global_v6 > 0 then
                local v6_html = '<span style="font-family:monospace;font-size:11px;color:#2563eb;word-break:break-all">' .. esc(global_v6[1]) .. '</span>'
                if #global_v6 > 1 then
                    local more = #global_v6 - 1
                    local aid = 'nm_cur_v6_' .. cur_ip_row
                    v6_html = v6_html .. '<span class="nm-ov-v6-more" id="' .. aid .. '_btn" data-more="+' .. more .. '" onclick="nmToggleV6(\'' .. aid .. '\')">+' .. more .. '</span>'
                    v6_html = v6_html .. '<div class="nm-ov-v6-all" id="' .. aid .. '">'
                    for i = 2, #global_v6 do
                        v6_html = v6_html .. '<span>' .. esc(global_v6[i]) .. '</span>'
                    end
                    v6_html = v6_html .. '</div>'
                end
                table.insert(parts, v6_html)
            end
            if dev.duid and dev.duid ~= "" then
                table.insert(parts, '<span style="color:#9ca3af;font-family:monospace;font-size:10px" title="DUID: ' .. esc(dev.duid) .. '">DUID: ' .. esc(dev.duid:sub(1, 12)) .. '…</span>')
            end
            if #parts > 0 then
                local dot = dev.online and '<span class="nm-ov-online"></span>' or '<span class="nm-ov-offline"></span>'
                local label = dev.online and '<span style="color:#059669;font-size:10px;font-weight:600">在线</span>' or '<span style="color:#9ca3af;font-size:10px">离线</span>'
                return dot .. label .. '<br>' .. table.concat(parts, '<br>')
            end
        end
    end
    return '<span class="nm-ov-offline"></span><span style="color:#9ca3af;font-size:11px">' .. translate("离线/未发现") .. '</span>'
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
