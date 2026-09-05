-- ============================================================
-- 网络管理插件 - LuCI 控制器 v1.1
-- 
-- ============================================================
module("luci.controller.netmanager", package.seeall)

function index()
    entry({"admin", "netmanager"}, alias("admin", "netmanager", "overview"), _("网络管理"), 60).dependent = true
    entry({"admin", "netmanager", "overview"}, template("netmanager/overview"), _("系统概览"), 1)
    entry({"admin", "netmanager", "port_forward"}, template("netmanager/port_forward"), _("端口转发"), 2)
    entry({"admin", "netmanager", "firewall_rules"}, template("netmanager/firewall_rules"), _("规则管理"), 3)
    entry({"admin", "netmanager", "ssh_log"}, template("netmanager/ssh_log"), _("SSH登录日志"), 4)
    entry({"admin", "netmanager", "access_log"}, template("netmanager/access_log"), _("端口访问日志"), 5)
    -- DNS 设置（CBI 标准表单，绑定 /etc/config/dnssettings）
    entry({"admin", "netmanager", "dns"}, cbi("netmanager/dns_settings"), _("DNS设置"), 6)
    entry({"admin", "netmanager", "dns_staticv6"}, cbi("netmanager/dns_staticv6"), _("静态IPv6分配"), 7)
    entry({"admin", "netmanager", "settings"}, template("netmanager/settings"), _("设置"), 8)
    entry({"admin", "netmanager", "api"}, call("api_handler"))
    -- 【v1.4.6】dns_apply / dns_backup 原 GET 路由已改为 api_handler 内 POST action
    -- 【v1.4.7】保留两个兼容路由重定向到 DNS 设置页（v1.4.5 的书签/浏览器缓存仍
    --  指向旧 GET 路由会 404；仅重定向不执行脚本，不复活"刷新即重复执行"问题）
    entry({"admin", "netmanager", "dns_apply"}, call("dns_legacy_redirect"))
    entry({"admin", "netmanager", "dns_backup"}, call("dns_legacy_redirect"))
end

-- 【v1.4.7】v1.4.5 旧 GET 路由兼容：重定向到 DNS 设置页（不执行任何脚本）
function dns_legacy_redirect()
    luci.http.redirect(luci.dispatcher.build_url("admin", "netmanager", "dns"))
end

-- ============================================================
-- 【v1.4.7】CSRF 防护：对齐 LuCI 内建 authtoken 机制
-- v1.4.6 曾用 luci.dispatcher.context.session.id 自派生 token——ucode 版 LuCI
-- 的 context 没有 session.id（会话 ID 实际存于 context.authsession，框架内建
-- CSRF token 存于 context.authtoken），导致 sid 取空 → 所有 API 被 fail-closed
-- 拒绝 403。现改为直接比对框架 authtoken（与 CBI 表单 token 同源，由 ucode
-- 分发器为每个已认证会话生成，跨站页面无法获得）。
-- ============================================================
function csrf_token()
    local ctx = luci.dispatcher.context
    return (ctx and ctx.authtoken) and tostring(ctx.authtoken) or ""
end

local function csrf_check()
    local expected = csrf_token()
    -- authtoken 缺失说明未通过认证（正常到不了这里，防御性 fail-closed）
    if expected == "" then return false end
    local got = luci.http.formvalue("token") or ""
    if type(got) == "table" then got = "" end
    return (got == expected)
end

-- 安全转义，防止命令注入
local function shell_escape(s)
    if not s or s == "" then return "" end
    -- 处理formvalue可能返回table的情况（multipart文件上传）
    if type(s) == "table" then
        s = s.tmpname or s.name or ""
    end
    if s == "" then return "" end
    return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- 从formvalue获取字符串值，兼容table返回（multipart上传）
local function form_str(key)
    local v = luci.http.formvalue(key)
    if type(v) == "table" then
        return v.tmpname or v.name or ""
    end
    return v or ""
end

-- 【v1.4.6 P2】命令参数包装：空值传 ''（防 shell 吞掉空参数错位），非空转义
-- （原 arg() 在 4 个分支内重复定义，提取为模块级）
local function arg(v)
    if v == "" or v == nil then return "''" end
    return shell_escape(v)
end

-- ============================================================
-- LuCI multipart 文件上传：必须在首次 formvalue() 之前设置文件处理器
-- 否则 formvalue() 解析 multipart 时不会保存上传的文件内容
-- ============================================================
local uploaded_tmp_file = nil
local uploaded_file_size = 0
-- 【v1.4.6 P1】multipart 上传大小上限 50MB（/tmp 是 tmpfs，无上限会 OOM）
local MAX_UPLOAD_BYTES = 50 * 1024 * 1024

local function setup_upload_handler()
    local upload_dir = "/tmp/netmanager_upload"
    luci.sys.call("mkdir -p " .. upload_dir)
    math.randomseed(os.time() + math.floor(os.clock() * 1000))
    uploaded_tmp_file = upload_dir .. "/plugin_update_" .. os.time() .. "_" .. math.random(1000, 9999) .. ".tar.gz"
    uploaded_file_size = 0
    -- v1.5.0 备份文件上传临时路径
    backup_tmp_file = upload_dir .. "/backup_import_" .. os.time() .. "_" .. math.random(1000, 9999) .. ".tar.gz"
    backup_file_size = 0

    local fout = nil
    local backup_fout = nil
    luci.http.setfilehandler(function(meta, chunk, eof)
        if not meta or not meta.name then return end
        -- 处理 plugin_file 字段（插件更新）
        if meta.name == "plugin_file" then
            if uploaded_file_size > MAX_UPLOAD_BYTES then
                if fout then fout:close() end
                fout = nil
                return
            end
            if not fout then
                fout = io.open(uploaded_tmp_file, "wb")
                if not fout then
                    uploaded_tmp_file = nil
                    return
                end
            end
            if fout and chunk and #chunk > 0 then
                fout:write(chunk)
                uploaded_file_size = uploaded_file_size + #chunk
            end
            if eof and fout then
                fout:close()
            end
        end
        -- v1.5.0 处理 backup_file 字段（备份导入）
        if meta.name == "backup_file" then
            if backup_file_size > MAX_UPLOAD_BYTES then
                if backup_fout then backup_fout:close() end
                backup_fout = nil
                return
            end
            if not backup_fout then
                backup_fout = io.open(backup_tmp_file, "wb")
                if not backup_fout then
                    backup_tmp_file = nil
                    return
                end
            end
            if backup_fout and chunk and #chunk > 0 then
                backup_fout:write(chunk)
                backup_file_size = backup_file_size + #chunk
            end
            if eof and backup_fout then
                backup_fout:close()
            end
        end
    end)
end

function api_handler()
    -- 【安全】仅接受 POST：防止 <img src="...?action=uninstall"> 之类的跨站 GET 触发
    -- （LuCI 的会话认证仅证明"登录页有效"，不阻止 GET 请求携带会话执行操作）
    if luci.http.getenv("REQUEST_METHOD") ~= "POST" then
        luci.http.status(405, "Method Not Allowed")
        luci.http.prepare_content("text/plain; charset=utf-8")
        luci.http.write('[ERROR] 仅允许 POST 请求')
        return
    end

    -- 【v1.4.6 安全】CSRF Token 校验：跨站 form POST 虽满足 POST-only，但可携带登录
    -- cookie；token 由视图渲染时注入（common_head.htm apiFetch 自动附带），跨站页面无法获得
    if not csrf_check() then
        luci.http.status(403, "Forbidden")
        luci.http.prepare_content("text/plain; charset=utf-8")
        luci.http.write('[ERROR] CSRF 校验失败：请刷新页面后重试（会话已过期或非本站请求）')
        return
    end

    -- 【关键】先设置文件上传处理器，再读任何formvalue（包括action）
    setup_upload_handler()
    
    local action = luci.http.formvalue("action") or ""
    local result = ""
    local cmd = ""
    local dns_action = nil

    if action == "overview" then
        cmd = "/usr/sbin/netmanager overview"
    elseif action == "port_list" then
        cmd = "/usr/sbin/netmanager port_list"
    elseif action == "port_add" then
        local port = luci.http.formvalue("port") or ""
        local proto = luci.http.formvalue("proto") or "tcp"
        local target = luci.http.formvalue("target") or ""
        local ipver = luci.http.formvalue("ipver") or "both"
        local dport = luci.http.formvalue("dport") or ""

        -- 关键修复：target为空时不传第3参数，避免shell吞掉空参数导致错位
        -- dport为内部端口，留空传''占位（后端默认与外部端口一致）
        if target ~= "" then
            cmd = string.format("/usr/sbin/netmanager port_add %s %s %s %s %s",
                shell_escape(port), shell_escape(proto), shell_escape(target), shell_escape(ipver), arg(dport))
        else
            cmd = string.format("/usr/sbin/netmanager port_add %s %s '' %s %s",
                shell_escape(port), shell_escape(proto), shell_escape(ipver), arg(dport))
        end
    elseif action == "port_del" then
        local port = luci.http.formvalue("port") or ""
        local proto = luci.http.formvalue("proto") or "tcp"
        cmd = string.format("/usr/sbin/netmanager port_del %s %s", shell_escape(port), shell_escape(proto))
    elseif action == "port_edit" then
        local old_port = luci.http.formvalue("old_port") or ""
        local old_proto = luci.http.formvalue("old_proto") or "tcp"
        local new_port = luci.http.formvalue("new_port") or ""
        local new_proto = luci.http.formvalue("new_proto") or "tcp"
        local new_target = luci.http.formvalue("new_target") or ""
        local new_ipver = luci.http.formvalue("new_ipver") or "both"
        local new_dport = luci.http.formvalue("new_dport") or ""

        cmd = string.format("/usr/sbin/netmanager port_edit %s %s %s %s %s %s %s",
            shell_escape(old_port), shell_escape(old_proto),
            shell_escape(new_port), shell_escape(new_proto),
            arg(new_target), shell_escape(new_ipver), arg(new_dport))
    elseif action == "rule_list" then
        cmd = "/usr/sbin/netmanager rule_list"
    elseif action == "rule_add" then
        local name = luci.http.formvalue("name") or ""
        local src = luci.http.formvalue("src") or ""
        local dst = luci.http.formvalue("dst") or ""
        local proto = luci.http.formvalue("proto") or "tcp"
        local port = luci.http.formvalue("port") or ""
        local target = luci.http.formvalue("target") or "ACCEPT"
        local fam = luci.http.formvalue("family") or "any"
        -- 修复：所有可能为空的参数都传 '' 空引号，防止shell吞掉空参数导致错位

        cmd = string.format("/usr/sbin/netmanager rule_add %s %s %s %s %s %s %s",
            arg(name), arg(src), arg(dst),
            arg(proto), arg(port), arg(target), arg(fam))
    elseif action == "rule_del" then
        local idx = luci.http.formvalue("idx") or ""
        cmd = string.format("/usr/sbin/netmanager rule_del %s", shell_escape(idx))
    elseif action == "rule_edit" then
        local idx = luci.http.formvalue("idx") or ""
        local name = luci.http.formvalue("name") or ""
        local src = luci.http.formvalue("src") or ""
        local dst = luci.http.formvalue("dst") or ""
        local proto = luci.http.formvalue("proto") or "tcp"
        local port = luci.http.formvalue("port") or ""
        local target = luci.http.formvalue("target") or "ACCEPT"
        local fam = luci.http.formvalue("family") or "any"

        cmd = string.format("/usr/sbin/netmanager rule_edit %s %s %s %s %s %s %s %s",
            shell_escape(idx), arg(name), arg(src), arg(dst),
            arg(proto), arg(port), arg(target), arg(fam))
    elseif action == "ssh_log" then
        local limit = luci.http.formvalue("limit") or "50"
        cmd = string.format("/usr/sbin/netmanager ssh_log %s", shell_escape(limit))
    elseif action == "access_log" then
        local port = luci.http.formvalue("port") or ""
        local limit = luci.http.formvalue("limit") or "100"
        if port ~= "" then
            cmd = string.format("/usr/sbin/netmanager access_log %s %s", shell_escape(port), shell_escape(limit))
        else
            cmd = string.format("/usr/sbin/netmanager access_log '' %s", shell_escape(limit))
        end
    elseif action == "restart" then
        cmd = "/usr/sbin/netmanager restart"
    elseif action == "reload" then
        cmd = "/usr/sbin/netmanager reload"
    elseif action == "backup" then
        cmd = "/usr/sbin/netmanager backup"
    elseif action == "backup_list" then
        cmd = "/usr/sbin/netmanager backup_list"
    elseif action == "backup_restore" then
        local filename = luci.http.formvalue("filename") or ""
        cmd = string.format("/usr/sbin/netmanager backup_restore %s", shell_escape(filename))
    elseif action == "backup_delete" then
        local filename = luci.http.formvalue("filename") or ""
        cmd = string.format("/usr/sbin/netmanager backup_delete %s", shell_escape(filename))
    elseif action == "backup_import" then
        local filename = luci.http.formvalue("filename") or ""
        cmd = string.format("/usr/sbin/netmanager backup_import %s", shell_escape(filename))
    elseif action == "backup_prune" then
        local keep = luci.http.formvalue("keep") or "20"
        cmd = string.format("/usr/sbin/netmanager backup_prune %s", shell_escape(keep))
    elseif action == "backup_import_upload" then
        -- v1.5.0 备份文件上传导入
        local upload_dir = "/tmp/netmanager_upload"
        local dest_file = upload_dir .. "/backup_import.tar.gz"
        luci.sys.call("mkdir -p " .. upload_dir)
        local src = backup_tmp_file
        local got_file = false
        if src and luci.sys.call("test -f " .. shell_escape(src) .. " && test -s " .. shell_escape(src)) == 0 then
            got_file = true
        end
        if not got_file then
            local alt_path = form_str("backup_file")
            if alt_path ~= "" and alt_path ~= "backup_file" and luci.sys.call("test -f " .. shell_escape(alt_path)) == 0 then
                src = alt_path
                got_file = true
            end
        end
        if not got_file then
            result = '{"error":"未接收到上传的备份文件，请重新选择 .tar.gz 文件"}'
        else
            luci.sys.call("cp -f " .. shell_escape(src) .. " " .. shell_escape(dest_file) .. " 2>/dev/null || mv -f " .. shell_escape(src) .. " " .. shell_escape(dest_file) .. " 2>/dev/null")
            if luci.sys.call("test -f " .. shell_escape(dest_file) .. " && test -s " .. shell_escape(dest_file)) == 0 then
                local sz_str = luci.sys.exec("ls -nl " .. shell_escape(dest_file) .. " 2>/dev/null | awk '{print $5}'") or ""
                local sz_num = tonumber(sz_str) or 0
                if sz_num < 100 then
                    result = '{"error":"上传的文件太小（' .. sz_num .. '字节），可能不是有效的备份文件"}'
                else
                    local import_cmd = "/usr/sbin/netmanager backup_import backup_import.tar.gz"
                    result = "[CMD] " .. import_cmd .. "\n"
                        .. "[DEBUG] dest_file=" .. dest_file .. " size=" .. sz_num .. "字节\n"
                        .. (luci.sys.exec(import_cmd) or "")
                end
            else
                result = '{"error":"备份文件保存失败"}'
            end
        end
    elseif action == "plugin_upload_update" then
        -- 文件已通过 setfilehandler() 在读取formvalue时自动保存
        local upload_dir = "/tmp/netmanager_upload"
        local dest_file = upload_dir .. "/plugin_update.tar.gz"
        luci.sys.call("mkdir -p " .. upload_dir)
        
        local src = uploaded_tmp_file
        local got_file = false
        local src_info = {}
        table.insert(src_info, "setfilehandler_tmp=" .. tostring(src or "nil") .. " size=" .. tostring(uploaded_file_size or 0))
        
        -- 优先使用 setfilehandler 保存的临时文件
        if src and luci.sys.call("test -f " .. shell_escape(src) .. " && test -s " .. shell_escape(src)) == 0 then
            got_file = true
        end
        
        -- 备选：某些版本的 formvalue("plugin_file") 可能直接返回临时文件路径（字符串/table两种情况）
        if not got_file then
            local alt_path = form_str("plugin_file")
            table.insert(src_info, "form_str_plugin_file=" .. tostring(alt_path))
            if alt_path ~= "" and alt_path ~= "plugin_file" and luci.sys.call("test -f " .. shell_escape(alt_path)) == 0 then
                src = alt_path
                got_file = true
            end
        end
        
        if not got_file then
            result = '[DEBUG] ' .. table.concat(src_info, " | ") .. '\n{"error":"未接收到上传的插件包，请重新选择文件。请确保浏览器支持FormData（现代浏览器均支持）"}'
        else
            -- 复制/移动到标准路径
            luci.sys.call("cp -f " .. shell_escape(src) .. " " .. shell_escape(dest_file) .. " 2>/dev/null || mv -f " .. shell_escape(src) .. " " .. shell_escape(dest_file) .. " 2>/dev/null")
            
            if luci.sys.call("test -f " .. shell_escape(dest_file) .. " && test -s " .. shell_escape(dest_file)) == 0 then
                -- 检查文件大小
                local sz_str = luci.sys.exec("ls -nl " .. shell_escape(dest_file) .. " 2>/dev/null | awk '{print $5}'") or ""
                local sz_num = tonumber(sz_str) or 0
                local update_cmd = "/usr/sbin/netmanager plugin_update plugin_update.tar.gz"
                if sz_num < 2000 then
                    result = '[DEBUG] src=' .. tostring(src) .. ' dest=' .. dest_file .. ' size=' .. sz_num .. '字节\n'
                        .. '{"error":"上传的文件太小（' .. sz_num .. '字节），可能上传失败，请重新选择完整的 .tar.gz 包"}'
                else
                    result = "[CMD] " .. update_cmd .. "\n"
                        .. "[DEBUG] dest_file=" .. dest_file .. " size=" .. sz_num .. "字节, src来源: " .. table.concat(src_info, " | ") .. "\n"
                        .. (luci.sys.exec(update_cmd) or "")
                end
            else
                result = '[DEBUG] src=' .. tostring(src) .. ' dest=' .. dest_file .. "\n"
                    .. '{"error":"文件保存失败，src=' .. tostring(src) .. '"}'
            end
        end
    elseif action == "upload_file" then
        local filename = luci.http.formvalue("filename") or ""
        if filename == "" then
            result = '{"error":"filename required"}'
        else
            local filecontent = luci.http.formvalue("filecontent") or ""
            local upload_dir = "/tmp/netmanager_upload"
            -- 确保目录存在
            os.execute("mkdir -p " .. upload_dir)
            -- 写入base64临时文件（避免shell命令行长度限制和特殊字符问题）
            -- 【v1.4.6 P1】时间戳+随机数防同秒冲突（与 setup_upload_handler 同策略）
            local b64file = upload_dir .. "/.b64_" .. os.time() .. "_" .. math.random(1000, 9999)
            local f = io.open(b64file, "w")
            if f then
                f:write(filecontent)
                f:close()
                cmd = string.format("/usr/sbin/netmanager upload_file %s %s",
                    shell_escape(filename), b64file)
            else
                result = '{"error":"无法创建临时文件"}'
            end
        end
    elseif action == "plugin_update" then
        local filename = luci.http.formvalue("filename") or ""
        cmd = string.format("/usr/sbin/netmanager plugin_update %s", shell_escape(filename))
    elseif action == "plugin_version" then
        local filename = luci.http.formvalue("filename") or ""
        cmd = string.format("/usr/sbin/netmanager plugin_version %s", shell_escape(filename))
    elseif action == "cleanup_uploads" then
        cmd = "/usr/sbin/netmanager cleanup_uploads"
    elseif action == "settings" then
        cmd = "/usr/sbin/netmanager settings"
    elseif action == "set_default_target" then
        local ip = luci.http.formvalue("ip") or ""
        cmd = string.format("/usr/sbin/netmanager set_default_target %s", shell_escape(ip))
    elseif action == "log_set" then
        local enable = luci.http.formvalue("enable") or "0"
        cmd = string.format("/usr/sbin/netmanager log_set %s", shell_escape(enable))
    elseif action == "log_get" then
        local lines = luci.http.formvalue("lines") or "200"
        cmd = string.format("/usr/sbin/netmanager log_get %s", shell_escape(lines))
    elseif action == "log_clear" then
        cmd = "/usr/sbin/netmanager log_clear"
    elseif action == "log_query" then
        local level = luci.http.formvalue("level") or "ALL"
        local keyword = luci.http.formvalue("keyword") or ""
        local lines = luci.http.formvalue("lines") or "200"
        cmd = string.format("/usr/sbin/netmanager log_query %s %s %s",
            shell_escape(level), shell_escape(keyword), shell_escape(lines))
    elseif action == "log_export" then
        cmd = "/usr/sbin/netmanager log_export"
    elseif action == "china_filter_status" then
        cmd = "/usr/sbin/netmanager china_filter status"
    elseif action == "china_filter_enable" then
        cmd = "/usr/sbin/netmanager china_filter enable"
    elseif action == "china_filter_disable" then
        cmd = "/usr/sbin/netmanager china_filter disable"
    elseif action == "china_filter_update" then
        cmd = "/usr/sbin/netmanager china_filter update"
    elseif action == "china_filter_set_url" then
        local url = luci.http.formvalue("url") or ""
        cmd = string.format("/usr/sbin/netmanager china_filter set_url %s", shell_escape(url))
    elseif action == "china_filter_set_cron" then
        local cron = luci.http.formvalue("cron") or ""
        cmd = string.format("/usr/sbin/netmanager china_filter set_cron %s", shell_escape(cron))
    elseif action == "update_check" then
        cmd = "/usr/sbin/netmanager update_check"
    elseif action == "update_apply" then
        -- 在线更新：下载可能较慢，浏览器端需耐心等待完整响应
        cmd = "/usr/sbin/netmanager update_apply"
    elseif action == "set_update_mirror" then
        local mirror = luci.http.formvalue("mirror") or ""
        cmd = string.format("/usr/sbin/netmanager set_update_mirror %s", shell_escape(mirror))
    elseif action == "uninstall" then
        local keep = luci.http.formvalue("keep") or "0"
        local mode = (keep == "1") and "keep" or "full"
        cmd = string.format("/usr/sbin/netmanager uninstall %s", shell_escape(mode))
    elseif action == "dns_apply" then
        -- 【v1.4.6】DNS 应用配置由 GET 路由并入 POST action（原路由刷新即重复执行）
        dns_action = "apply"
    elseif action == "dns_backup" then
        -- 【v1.4.6】DNS 备份系统配置同上
        dns_action = "backup"
    else
        result = '{"error":"unknown action"}'
    end

    -- 【v1.4.6】DNS 动作执行（单次调用同时捕获输出与退出码）
    if dns_action then
        local script = (dns_action == "apply")
            and "/usr/sbin/dnssettings-apply.sh" or "/usr/sbin/dnssettings-backup.sh"
        local out = luci.sys.exec(script .. " 2>&1; echo \"__RC__$?\"") or ""
        local rc = tonumber(out:match("__RC__(%-?%d+)")) or -1
        out = out:gsub("__RC__%-?%d+\n?$", "")
        if rc == 0 then
            result = "[CMD] " .. script .. " (exit=0)\n" ..
                ((dns_action == "apply") and "DNS配置已应用" or "配置已备份") ..
                "，详细输出：\n" .. out
        else
            result = "[CMD] " .. script .. " (exit=" .. tostring(rc) .. ")\n" ..
                "执行失败，详细输出：\n" .. out
        end
    end

    if cmd ~= "" then
        -- ucode版LuCI的luci.sys.exec在命令失败/无输出时可能返回nil，用 or "" 兜底避免拼接报错
        local exec_out = luci.sys.exec(cmd) or ""
        -- 在结果开头加上执行的命令，方便用户确认
        result = "[CMD] " .. cmd .. "\n" .. exec_out
    end

    luci.http.prepare_content("text/plain; charset=utf-8")
    luci.http.write(result)
end
