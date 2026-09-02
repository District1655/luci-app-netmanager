-- 静态 IPv6 分配 - v1.2.1
-- 修复：移除 luci.sys.net 依赖（iStoreOS 24.10 ucode 版 LuCI 不存在该模块）
--      改用直接读取 /tmp/dhcp.leases 和 /proc/net/arp 获取在线设备

local sys = require "luci.sys"

-- ============================================================
-- 工具函数：获取在线设备信息
-- 直接读取系统文件，不依赖 luci.sys.net
-- 返回 { [MAC_UPPER] = { ip=..., hostname=..., online=bool } }
-- ============================================================
local function get_online_devices()
    local devices = {}

    -- 1. 读取 DHCPv4 租约文件 /tmp/dhcp.leases
    -- 格式: <timestamp> <mac> <ip> <hostname> <clientid>
    local f = io.open("/tmp/dhcp.leases", "r")
    if f then
        for line in f:lines() do
            local ts, mac, ip, hostname = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
            if mac and ip and mac ~= "" then
                devices[mac:upper()] = {
                    ip = ip,
                    hostname = hostname or "",
                    online = true
                }
            end
        end
        f:close()
    end

    -- 2. 读取 ARP 表 /proc/net/arp（补充静态设备）
    -- 格式: IP HWtype Flags HWaddress Mask Device
    f = io.open("/proc/net/arp", "r")
    if f then
        local first = true
        for line in f:lines() do
            if first then
                first = false  -- 跳过表头
            else
                local ip, hwtype, flags, mac = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
                if mac and mac ~= "00:00:00:00:00:00" and mac ~= "" then
                    local mac_upper = mac:upper()
                    if not devices[mac_upper] then
                        devices[mac_upper] = {
                            ip = ip,
                            hostname = "",
                            online = (flags ~= "0x0")
                        }
                    end
                end
            end
        end
        f:close()
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
-- 页面加载时执行合并 + 获取在线设备
-- ============================================================
local merged_count = merge_duplicate_hosts()
local online_devices = get_online_devices()

-- 收集已使用的 hostid（用于冲突检测）
local used_hostids = {}
local uci_cursor = require "uci".cursor()
uci_cursor:foreach("dhcp", "host", function(s)
    if s.hostid and s.hostid ~= "" and s.mac then
        used_hostids[s[".name"]] = s.hostid:lower()
    end
end)

-- ============================================================
-- 页面描述
-- ============================================================
local desc = translate("为已绑定 MAC 的设备设置固定 IPv6 地址。推荐填写 hostid（地址后缀），运营商前缀变化时地址仍保持一致；ip6 填完整地址，仅适合 ULA 或前缀固定场景。")
if merged_count > 0 then
    desc = desc .. " \n\n" .. translate("注意") .. "：" .. translate("已自动合并") .. " " .. merged_count .. " " .. translate("个重复的 MAC 绑定条目。")
end

m = Map("dhcp", translate("静态 IPv6 分配"), desc)

-- 保存后自动重启服务
m.on_after_commit = function(self)
    sys.call("/etc/init.d/odhcpd restart >/dev/null 2>&1")
    sys.call("/etc/init.d/dnsmasq restart >/dev/null 2>&1")
end

-- ============================================================
-- 设备列表
-- ============================================================
s = m:section(TypedSection, "host", translate("设备列表"))
s.addremove = true
s.anonymous = true
s.sortable = false
s.template = "cbi/tblsection"

-- 只显示有 MAC 地址的条目
function s.filter(self, section)
    local mac = m.uci:get("dhcp", section, "mac")
    return mac ~= nil and mac ~= ""
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

-- ---------- 当前在线 IP（只读） ----------
o_cur_ip = s:option(DummyValue, "_current_ip", translate("当前在线IP"))
o_cur_ip.rawhtml = true
function o_cur_ip.cfgvalue(self, section)
    local mac_val = m.uci:get("dhcp", section, "mac")
    if mac_val then
        local dev = online_devices[mac_val:upper()]
        if dev and dev.ip then
            local status = dev.online and "●" or "○"
            local color = dev.online and "#2ecc71" or "#999"
            return string.format('<span style="color:%s">%s</span> <span style="font-family:monospace">%s</span>',
                color, status, dev.ip)
        end
    end
    return '<span style="color:#999">○ ' .. translate("离线/未发现") .. '</span>'
end

-- ---------- IPv4 静态地址 ----------
o_ip4 = s:option(Value, "ip", translate("IPv4静态地址"))
o_ip4.rmempty = true
o_ip4.datatype = "ip4addr"
o_ip4.size = 15

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
        for sid, hid in pairs(used_hostids) do
            if sid ~= section and hid == val_lower then
                return nil, translate("hostid 与其他设备冲突，请换一个值")
            end
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

-- ---------- DUID（只读显示） ----------
o_duid = s:option(DummyValue, "duid", translate("DUID"))
o_duid.rawhtml = true
function o_duid.cfgvalue(self, section)
    local val = m.uci:get("dhcp", section, "duid")
    if val and val ~= "" then
        return string.format('<span style="font-family:monospace;font-size:11px;color:#333">%s</span>', val)
    end
    local mac_val = m.uci:get("dhcp", section, "mac")
    if mac_val then
        local dev = online_devices[mac_val:upper()]
        if dev and dev.online then
            return '<span style="color:#e67e22">' .. translate("无(设备在线但未记录DUID，重启网络后自动获取)") .. '</span>'
        end
    end
    return '<span style="color:#999">' .. translate("无") .. '</span>'
end

-- ---------- 启用开关 ----------
o_enabled = s:option(Flag, "enabled", translate("启用"))
o_enabled.rmempty = false
o_enabled.default = "1"

return m
