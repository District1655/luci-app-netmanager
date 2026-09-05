# luci-app-netmanager 项目全景文档（PROJECT.md）

> **基线**：v1.5.3（v1.4.6 CSRF 回归紧急修复：改用 LuCI 内建 authtoken + CBI 防御加固）· main 分支 · 更新时间 2026-09-05
>
> **用途**：本文件是项目的**单一查阅入口**——文件架构、全部源码、维护历史、开发计划、注意事项集中一处，供后续开发、排错与交接时快速定位。
>
> **分工**：README.md 面向用户（安装/使用）；本文档面向维护者（实现/历史/计划）。
>
> **源码收录**：第 5 章嵌入全部受控文件的完整源码（v1.4.5 基线 `90b2bf9` 全文 + v1.4.6 增量以工作区实际文件为准，可用 `docs/gen_source_part.sh` 重新生成）。

## 目录

| 章 | 内容 |
|----|------|
| 第 1 章 | 项目概述 |
| 第 2 章 | 完整文件架构 |
| 第 3 章 | 核心机制说明 |
| 第 4 章 | 后端命令参考（CLI） |
| 第 5 章 | 源码全录（文件全文） |
| 第 6 章 | 更新维护记录（版本/提交/发版流程） |
| 第 7 章 | 开发计划（v1.5 路线） |
| 第 8 章 | 注意事项（环境陷阱/规范/安全红线） |
| 第 9 章 | 快速索引（行号定位表） |

---

## 第 1 章 项目概述

### 1.1 项目定位

| 项 | 值 |
|----|----|
| 项目名 | luci-app-netmanager（网络管理插件） |
| 仓库 | District1655/luci-app-netmanager（GitHub，SSH 推送） |
| 形态 | LuCI 插件（Lua 控制器 + CBI 模型 + 自绘视图 + shell 后端） |
| 目标平台 | iStoreOS / OpenWrt 23.05+（fw4 / nftables） |
| 安装形态 | tar.gz + install.sh（非 ipk，原因见 8.1） |
| 当前版本 | v1.5.3（2026-09-05，CSRF 回归修复版） |
| 许可证 | MIT（仓库根目录 LICENSE 文件，v1.4.6 补齐） |
| 前身 | luci-app-fwmanager v1.3.33 + luci-app-dnssettings v1.2.1，v1.4.0 合并 |

### 1.2 功能模块速览

| # | 模块 | 页面 | 后端 |
|---|------|------|------|
| 1 | 系统概览 | overview.htm | overview |
| 2 | 端口转发（IPv4 DNAT + IPv6 放行） | port_forward.htm | port_* |
| 3 | 防火墙规则 | firewall_rules.htm | rule_* |
| 4 | SSH 登录日志 | ssh_log.htm | ssh_log |
| 5 | 端口访问日志 | access_log.htm | access_log |
| 6 | 中国 IPv4 访问限制 | settings.htm 内区块 | china_filter * |
| 7 | 设置（备份/更新/日志/卸载） | settings.htm | backup* / update_* / log_* / uninstall |
| 8 | DNS 设置（CBI 表单） | dns_settings.lua | dnssettings-apply.sh / backup.sh |
| 9 | 静态 IPv6 分配（CBI 表单） | dns_staticv6.lua | LuCI 内完成 + odhcpd |

### 1.3 技术栈

| 层 | 技术 | 说明 |
|----|------|------|
| 后端命令 | POSIX sh（BusyBox ash） | /usr/sbin/netmanager，无 bashism |
| Web 后端 | Lua（LuCI 框架） | controller 注册路由 + API 分发 |
| 表单 | LuCI CBI | DNS 两页用标准 Map/NamedSection |
| 自绘页面 | htm 模板 + 原生 JS | fetch 调后端 API，无框架 |
| 配置 | UCI | /etc/config/netmanager、dnssettings、firewall、dhcp、network |
| 防火墙 | fw4 / nftables | 独立表 inet netmanager 与 fw4 并存 |
| 交付 | tar.gz + install.sh | 7 步安装，支持 SKIP_UHTTPD_RESTART |
| CI | GitHub Actions | tag 触发打包 + Release body 自动提取 |

### 1.4 为什么不用 ipk

iStoreOS 的 /usr/bin/ 是只读 squashfs 分区，标准 ipk 安装会失败。本插件全部文件复制到可写分区，用 install.sh 完成权限/链接/init/cron，详见第 5 章 install.sh 源码。

---

## 第 2 章 完整文件架构

### 2.1 目录树（24 个受控文件，基线 90b2bf9）

```
luci-app-netmanager/
├── files/usr/sbin/                              # 后端命令层
│   ├── netmanager                               # 核心后端，2197 行（全部 CLI 子命令）
│   ├── dnssettings-apply.sh                     # 191 行（v1.4.5 重写）
│   └── dnssettings-backup.sh                    # 23 行
├── files/usr/lib/lua/luci/
│   ├── controller/netmanager.lua                # 353 行：路由 + API 分发 + 上传
│   ├── model/cbi/netmanager/
│   │   ├── dns_settings.lua                     # 125 行：DNS 设置表单（v1.4.6 注入 cbi_nav）
│   │   └── dns_staticv6.lua                     # 489 行：静态 IPv6 分配表单（v1.4.6 修 get_first + 注入 cbi_nav）
│   └── view/netmanager/                         # 自绘视图层（9 个 htm）
│       ├── common_head.htm                      # 148 行：公共 CSS+JS（escapeHtml/apiFetch）
│       ├── nav.htm                              # 10 行：页内导航
│       ├── cbi_nav.htm                          # 28 行：CBI 页面专用导航（v1.4.6 新增）
│       ├── overview.htm                         # 105 行：系统概览
│       ├── port_forward.htm                     # 181 行：端口转发
│       ├── firewall_rules.htm                   # 229 行：防火墙规则
│       ├── ssh_log.htm                          # 103 行：SSH 日志
│       ├── access_log.htm                       # 111 行：访问日志
│       └── settings.htm                         # 620 行：设置（最复杂视图）
├── files/etc/config/
│   ├── netmanager                               # 12 行：防火墙模块 UCI 配置
│   └── dnssettings                              # 19 行：DNS 模块 UCI 配置
├── files/etc/init.d/netmanager-china            # 21 行：开机自启
├── files/etc/hotplug.d/iface/95-netmanager-china# 19 行：WAN 上线自愈
├── install.sh                                   # 95 行：7 步安装
├── .github/workflows/
│   ├── build.yml                                # 138 行：tag 触发打包+Release
│   └── extract_changelog.awk                    # 17 行：Release body 提取
├── .gitattributes                               # 13 行：强制 LF
└── README.md                                    # 165 行：用户文档
```

> 注：行数为 wc -l 实际值；.gitattributes 等小文件行数不含末尾空行。

### 2.2 分层架构与调用链

```
浏览器
  │  fetch POST /admin/network/netmanager/api
  ▼
controller/netmanager.lua         ── api_handler（强制 POST，shell_escape 拼命令）
  │  io.popen("/usr/sbin/netmanager <action> <args>")
  ▼
/usr/sbin/netmanager             ── UCI 读写 /etc/config/firewall、netmanager
  │  uci commit → fw4 reload → nft（独立表 inet netmanager）
  ▼
系统层：fw4 / dnsmasq / odhcpd / netifd / procd
```

DNS 两页为 CBI 表单，不经 controller API，LuCI 框架直接提交 UCI，按钮 redirect 到 controller 的 dns_apply/dns_backup 路由执行脚本。

### 2.3 文件职责矩阵

| 文件 | 职责 | 上游调用方 | 下游 |
|------|------|-----------|------|
| netmanager | 全部 CLI 子命令 | controller、cron、init、hotplug、用户 | UCI、nft、wget、tar |
| controller | 路由+API 分发+上传 | 浏览器 fetch | netmanager（io.popen） |
| 各 htm 视图 | 页面渲染+交互 | controller entry() | api（fetch） |
| dns_settings.lua | DNS 表单 | LuCI CBI | UCI dnssettings |
| dns_staticv6.lua | IPv6 绑定表单 | LuCI CBI | UCI dhcp.host |
| dnssettings-apply.sh | DNS 应用 | controller dns_apply 路由 | UCI network/dhcp、服务重载 |
| dnssettings-backup.sh | DNS 备份 | controller dns_backup 路由 | tar |
| netmanager-china (init.d) | 开机加载规则 | procd | netmanager china_load_set |
| 95-netmanager-china (hotplug) | WAN 上线自愈 | netifd | 同上 |
| install.sh | 安装 | 用户 / plugin_update | 文件复制、init、cron |
| build.yml | CI | git tag push | tar.gz 资产、Release |

### 2.4 数据流：一次端口转发的完整路径

以「添加端口转发 8080/tcp → 192.168.31.5」为例：

1. port_forward.htm `savePort` → POST api `port_add 8080 tcp 192.168.31.5 ipv4`
2. controller api_handler → shell_escape 校验 → `io.popen netmanager port_add ...`
3. netmanager port_add：查重（proto_match）→ uci add redirect + rule → uci commit → fw4 reload
4. 前端轮询 / 刷新列表（port_list）
5. fw4 编译规则到 nftables 内核

---

## 第 3 章 核心机制说明

### 3.1 API 安全模型（v1.4.4 后现状）

```
请求 → controller api_handler
         ├─ 非 POST？→ 405 拒绝
         ├─ 参数 shell_escape（防命令注入）
         └─ io.popen 执行后端 → 输出回传 JSON
```

已知缺口（v1.4.6 待修，详见第 7 章）：无 CSRF Token（跨站 form POST 可带 cookie）；dns_apply/dns_backup 仍为 GET。

### 3.2 中国 IPv4 过滤（独立 nft 表）

- **为什么独立**：fw4 reload 不影响 `inet netmanager` 表，防火墙热重载不会丢过滤规则
- **表结构**：`china_v4` CIDR 集合（modern: flags interval + auto-merge 分片加载；compat: 单次原子加载+逐行回退）+ input/forward 两条 base chain（priority -50）
- **规则语义**：WAN 口新建 tcp/udp 连接，源 IP 不在 china_v4 集合 → drop
- **自愈**：init 开机 + hotplug WAN 上线自动重应用
- **数据**：/etc/netmanager/china_v4.list（默认订阅 metowolf special/china.txt），cron 定期更新
- **已知坑**：china_load_set 分片失败静默继续（待修）→ 可能误杀国内流量

### 3.3 DNS 应用机制（v1.4.5 重写后）

dnssettings-apply.sh 执行流程：

1. **前置**：`dnssettings` UCI 快照 → 自动备份 network/dhcp/dnssettings 到 /root/backup/（保留 5 份）
2. **写入 WAN**：peerdns=0 时写自定义 DNS（**空值防护**：DNS 全空则拒绝写入该接口，日志 WARN，防止断网）；`network.wan.dns` 用 delete+add_list（list 类型正确写法）；PPPoE 双栈 fallback 并入 dns list（netifd 按协议区分）
3. **写入 LAN**：dhcp.lan（dhcp_option / dns / ra / dhcpv6），关闭时清除旧列表使关闭真正生效
4. **写入 dnsmasq**：server 列表
5. **重载**：network reload（不重拨不重建接口）+ dnsmasq reload + odhcpd restart（RA 变更需重启进程）
6. **回传**：完整输出（含 WARN）通过 controller 捕获回传页面

已知待修：L145 dhcp_option 仍为单值写法；WAN 接口名硬编码 network.wan/wan6（非 wan 命名接口失效）。

### 3.4 在线更新机制

```
设置页 → update_check → GitHub API jsonfilter 解析 tag/资产 URL
                      └ API 失败降级 302 Location 解析
设置页 → update_apply → wget/uclient-fetch/curl 依次兜底下载
                      → 大小校验 + tar 成员预检（拒 ../、绝对路径）
                      → plugin_update 流程：解压 → install.sh → 延迟重启 uhttpd
镜像加速：set_update_mirror <url>，检查+下载 URL 自动拼前缀
```

**P0 已知风险**（v1.4.6 待修）：镜像 URL 无白名单校验 + 下载包无 sha256 校验，镜像被劫持可注入任意 install.sh 以 root 执行。修复方案见第 7 章 P0-1。

### 3.5 备份恢复体系

| 类别 | 触发 | 内容 | 位置 | 保留策略 |
|------|------|------|------|---------|
| 防火墙备份 | 设置页/backup 命令 | /etc/config/firewall | /root/ | 无限保留（列表管理） |
| DNS 自动备份 | 每次应用配置 | network/dhcp/dnssettings | /root/backup/ | 最近 5 份 |
| DNS 手动备份 | 页面按钮/dns_backup | network/dhcp | /root/backup/ | 无限保留 |
| 上传临时文件 | 页面上传插件包 | tar.gz | /tmp/netmanager/upload/ | 24h 清理（cleanup_uploads） |

### 3.6 UCI 配置全景

| 配置文件 | 写入方 | 读取方 |
|---------|--------|--------|
| /etc/config/netmanager | netmanager 后端（set_default_target/log/china 参数） | 后端自身 + init/hotplug |
| /etc/config/dnssettings | dns_settings.lua CBI 表单 | dnssettings-apply.sh |
| /etc/config/firewall | port_*/rule_*（redirect/rule 节） | fw4 |
| /etc/config/dhcp | dns_staticv6.lua（host 节）+ apply 脚本（lan/dnsmasq 节） | dnsmasq/odhcpd |
| /etc/config/network | apply 脚本（wan/wan6 dns/peerdns） | netifd |

---

## 第 4 章 后端命令参考（CLI）

> 完整参数以第 5 章源码 usage（netmanager L2145-2197）为准。本章为速查。

### 4.1 命令总表

| 分类 | 命令 | 说明 |
|------|------|------|
| 概览 | overview | 防火墙状态/端口统计/网络信息 |
| 端口转发 | port_list | 列出全部 DNAT+IPv6 放行 |
| | port_add <外部端口> <tcp\|udp\|both> <目标IP> <ipv4\|ipv6\|both> [内部端口] | 新增（内部端口可映射不同端号） |
| | port_del <外部端口> <协议> | 删除 |
| | port_edit <旧端口> <旧协议> <新端口> <新协议> <目标IP> <类型> [新内部端口] | 编辑（跨 IP 版本切换自动补建） |
| 规则 | rule_list / rule_add / rule_del / rule_edit | 自定义通信规则增删改查 |
| 日志 | ssh_log [条数] | SSH 登录记录 |
| | access_log [端口] [条数] | 活跃连接统计 |
| | log_set 1\|0 / log_get [行数] / log_clear | 运行日志开关/查看/清空 |
| 备份 | backup / backup_list / backup_restore <名> / backup_delete <名> | 防火墙配置备份 |
| 上传/更新 | upload_file <文件名>（stdin） | 页面上传通道 |
| | plugin_update <文件名> | 从上传包安装（tar 预检） |
| | plugin_version <文件名> | 查看包版本 |
| | cleanup_uploads | 清 24h 前临时文件 |
| | update_check | 检查新版本（API→302 两级容错） |
| | update_apply | 下载+校验+安装 |
| | set_update_mirror <url> | 镜像前缀（空=直连） |
| 中国过滤 | china_filter status/enable/disable/update | 状态/开关/更新 |
| | china_filter set_url <url> / set_cron "0 4 * * *" | 订阅/计划 |
| 设置 | settings / set_default_target <IP> | 查看/默认目标 |
| 防火墙 | restart / reload | fw4 操作 |
| DNS | （/usr/sbin/dnssettings-apply.sh / dnssettings-backup.sh） | 应用/备份（非 netmanager 子命令） |
| 卸载 | uninstall [full\|keep] | keep 保留三配置 |

### 4.2 输出约定

- `netmanager` 输出人类可读文本；页面 JS 解析约定：
  - 端口/规则列表：`name|...` 管道分隔（**name 含管道符会错位，v1.4.6 待修**）
  - china 状态：`key=value` 行
  - 错误：行首 `ERROR:`（controller 以此判成败，**待改退出码**）
- 备份列表：`文件名|大小|日期`

### 4.3 退出码与日志

- 运行日志：/tmp/netmanager/run.log（log_enable 控制，tmpfs 重启即失）
- 排错路径：页面报错 → log_get 20 → /tmp/netmanager/run.log → ssh 查 uci show netmanager

---


## 第 5 章 源码全录

> 本章由脚本自动嵌入（基线 commit 90b2bf9 / v1.4.5+两bug修复，生成时间 2026-09-04 23:22）。
> 收录全部 24 个受控文件的完整内容，每个文件附用途与维护要点。
> **源码是唯一事实来源**：前文描述与源码不一致时，以源码为准。


### 5.1 files/usr/sbin/netmanager

- **用途**：后端核心脚本：netmanager 命令全部子命令实现（概览/端口转发/规则/日志/备份/上传/在线更新/中国IPv4过滤/卸载）
- **规模**：2197 行
- **维护要点**：单文件约 2197 行，v1.5+ 模块化拆分对象。PLUGIN_VERSION 位于 L15（版本唯一权威源）；tar_list_check L68-86；proto_match 在头部；update_apply 约 L1495、set_update_mirror 约 L1502-1505（P0 镜像白名单待修）；china_load_set 约 L1736-1761；china_cron_install 约 L1920-1926；set_cron 约 L1973-1986；uninstall 约 L2059-2143（L2141 rm /tmp/luci-sessions 待修）

```bash
#!/bin/ash
# ============================================================
# 网络管理插件 - 后端核心脚本 v1.1
# 
# 适配: iStoreOS / OpenWrt (fw4/nftables, BusyBox)
# ============================================================

DEFAULT_TARGET="192.168.31.196"
CONFIG_FILE="/etc/config/netmanager"
LOG_DIR="/tmp/netmanager"
LOG_FILE="$LOG_DIR/run.log"
LOG_ENABLED=0

# 在线更新配置：版本号与 GitHub 仓库（发版时同步修改 PLUGIN_VERSION）
PLUGIN_VERSION="1.4.5"
REPO_OWNER="District1655"
REPO_NAME="luci-app-netmanager"
REPO_BASE_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
REPO_API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"

# 确保日志目录存在（tmp每次重启会清，需要每次重建）
mkdir -p "$LOG_DIR" 2>/dev/null

# 检查并加载日志开关（调用 load_config 后 LOG_ENABLED 才有效）
reload_log_setting() {
    local val=$(uci get netmanager.settings.log_enable 2>/dev/null)
    [ "$val" = "1" ] && LOG_ENABLED=1 || LOG_ENABLED=0
}

# 写运行日志：[时间戳] [级别] 内容
write_log() {
    [ "$LOG_ENABLED" = "1" ] || return 0
    local level="$1"; shift
    local msg="$*"
    local ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%s')
    mkdir -p "$LOG_DIR" 2>/dev/null
    # 日志文件超过 2MB 自动截断保留最后 500 行
    if [ -f "$LOG_FILE" ]; then
        local sz=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$sz" -gt 2097152 ] 2>/dev/null; then
            tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null
            mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null
        fi
    fi
    echo "[$ts] [$level] $msg" >> "$LOG_FILE" 2>/dev/null
    return 0
}

# 公开的日志快捷函数（同时写标准输出 + 日志文件）
info() { echo "[INFO] $*"; write_log "INFO" "$*"; }
warn() { echo "[WARN] $*"; write_log "WARN" "$*"; }
error() { echo "[ERROR] $*"; write_log "ERROR" "$*"; }

# proto_match <条目proto> <待匹配proto>：返回0=匹配
# fw4 语义：proto 缺省（空）= tcp+udp（both）
proto_match() {
    local rp="$1" mp="$2"
    [ -z "$rp" ] && rp="tcp udp"
    case " $rp " in
        *" $mp "*) return 0 ;;
    esac
    return 1
}

# tar_list_check <tar包> <列表输出文件>：返回0=安全（成员可列出且无路径穿越）
# BusyBox tar 解压时不剥离 ../ 成员，恶意包可借此覆盖系统文件（配合在线更新=远程RCE链）
# 检查规则：列出失败（坏包）、成员含 ../ 段、或以绝对路径开头 → 全部拒绝
tar_list_check() {
    local pkg="$1" listfile="$2"
    # 尝试列出成员（gzip 直接列失败时退回 gunzip + tar tf）
    tar tzf "$pkg" > "$listfile" 2>/dev/null
    if [ $? -ne 0 ] && [ ! -s "$listfile" ]; then
        local ungz="${pkg%.gz}"
        if [ "$ungz" != "$pkg" ]; then
            gunzip -c "$pkg" > "$ungz" 2>/dev/null && tar tf "$ungz" > "$listfile" 2>/dev/null
            rm -f "$ungz" 2>/dev/null
        fi
    fi
    # 完全列不出来 = 坏包，拒绝
    [ ! -s "$listfile" ] && return 1
    # 检查非法成员：../ 段 或 绝对路径开头
    if grep -qE '(^|/)\.\.(/|$)|^/' "$listfile"; then
        return 1
    fi
    return 0
}

load_config() {
    [ -f "$CONFIG_FILE" ] || {
        uci set netmanager.settings=netmanager
        uci set netmanager.settings.default_target="$DEFAULT_TARGET"
        uci set netmanager.settings.log_days='7'
        uci set netmanager.settings.log_enable='0'
        uci commit netmanager
    }
    DEFAULT_TARGET=$(uci get netmanager.settings.default_target 2>/dev/null || echo "$DEFAULT_TARGET")
    reload_log_setting
    # 补齐中国IPv4过滤相关默认值（仅在选项缺失时写入，不覆盖用户已自定义值）
    if [ -z "$(uci get netmanager.settings.china_filter_enable 2>/dev/null)" ]; then
        uci set netmanager.settings.china_filter_enable='0'
        uci set netmanager.settings.china_filter_url='https://metowolf.github.io/iplist/data/special/china.txt'
        uci set netmanager.settings.china_filter_cron='0 3 * * 0'
        uci set netmanager.settings.china_filter_last_update=''
        uci set netmanager.settings.china_filter_count='0'
        uci commit netmanager 2>/dev/null
    fi
    # 补齐在线更新镜像前缀默认值（空=直连 GitHub）
    if [ -z "$(uci get netmanager.settings.update_mirror 2>/dev/null)" ]; then
        uci set netmanager.settings.update_mirror=''
        uci commit netmanager 2>/dev/null
    fi
}

# ========== 1. 系统概览 ==========
cmd_overview() {
    load_config
    echo "===NETMANAGER_OVERVIEW==="

    # 防火墙状态：检测 fw4 表是否存在
    # 用 nft list table 替代全量 nft list ruleset（原代码调用两次全量查询，规则多时很慢）
    if nft list table inet fw4 >/dev/null 2>&1; then
        echo "FW_STATUS=running"
    else
        echo "FW_STATUS=stopped"
    fi

    # 规则数量
    redirect_count=0; rule_count=0
    idx=0
    while uci -q get "firewall.@redirect[$idx]" >/dev/null 2>&1; do
        redirect_count=$((redirect_count+1)); idx=$((idx+1))
    done
    idx=0
    while uci -q get "firewall.@rule[$idx]" >/dev/null 2>&1; do
        rule_count=$((rule_count+1)); idx=$((idx+1))
    done
    echo "REDIRECT_COUNT=$redirect_count"
    echo "RULE_COUNT=$rule_count"

    # WAN口IP（通过路由获取，不写死接口名）
    wan_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [ -z "$wan_ip" ] && wan_ip=$(ip -4 addr show 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | grep -v '172\.' | grep -v '192.168' | awk '{print $2}' | cut -d/ -f1 | head -1)
    [ -z "$wan_ip" ] && wan_ip="N/A"
    echo "WAN_IP=$wan_ip"

    # WAN IPv6
    wan_ipv6=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [ -z "$wan_ipv6" ] && wan_ipv6=$(ip -6 addr show 2>/dev/null | grep 'scope global' | grep -v 'fd' | awk '{print $2}' | cut -d/ -f1 | head -1)
    [ -z "$wan_ipv6" ] && wan_ipv6="N/A"
    echo "WAN_IPV6=$wan_ipv6"

    # LAN口IP
    lan_ip=$(uci get network.lan.ipaddr 2>/dev/null || echo "192.168.1.1")
    echo "LAN_IP=$lan_ip"

    # 运行时间（从/proc/uptime计算）
    uptime_sec=$(cat /proc/uptime 2>/dev/null | awk '{print int($1)}')
    up_days=$((uptime_sec / 86400))
    up_hours=$(( (uptime_sec % 86400) / 3600 ))
    up_mins=$(( (uptime_sec % 3600) / 60 ))
    if [ $up_days -gt 0 ]; then
        uptime_str="${up_days}天${up_hours}小时${up_mins}分"
    elif [ $up_hours -gt 0 ]; then
        uptime_str="${up_hours}小时${up_mins}分"
    else
        uptime_str="${up_mins}分钟"
    fi
    echo "UPTIME=$uptime_str"

    # 负载
    load=$(cat /proc/loadavg 2>/dev/null | awk '{print $1" "$2" "$3}')
    echo "LOAD=$load"

    # 内存
    mem_info=$(free 2>/dev/null | grep Mem)
    mem_total=$(echo "$mem_info" | awk '{print $2}')
    mem_used=$(echo "$mem_info" | awk '{print $3}')
    if [ -n "$mem_total" ] && [ "$mem_total" -gt 0 ]; then
        mem_percent=$((mem_used * 100 / mem_total))
    else
        mem_percent=0
    fi
    echo "MEM_PERCENT=$mem_percent"

    echo "DEFAULT_TARGET=$DEFAULT_TARGET"

    # SSH失败次数（适配dropbear + BusyBox，不用grep -P）
    # dropbear失败: "Bad password attempt" / "Exit before auth" / "auth failed" / "invalid user"
    ssh_fail=0
    if command -v logread >/dev/null 2>&1; then
        ssh_fail=$(logread 2>/dev/null | grep -iE "dropbear|sshd" | grep -ciE "bad password|exit before auth|auth fail|invalid user|password auth fail|connection closed.*auth" 2>/dev/null)
    fi
    # 备用：从系统日志文件读取
    if [ "$ssh_fail" -eq 0 ] 2>/dev/null; then
        for logf in /var/log/messages /tmp/log/messages /var/log/syslog; do
            [ -f "$logf" ] && {
                f=$(grep -iE "dropbear|sshd" "$logf" 2>/dev/null | grep -ciE "bad password|exit before auth|auth fail|invalid user|password auth fail" 2>/dev/null)
                [ -n "$f" ] && [ "$f" -gt 0 ] 2>/dev/null && ssh_fail=$f && break
            }
        done
    fi
    [ -z "$ssh_fail" ] && ssh_fail=0
    echo "SSH_FAIL_24H=$ssh_fail"

    # 当前连接数（优先conntrack，其次/proc）
    conn_count=0
    if command -v conntrack >/dev/null 2>&1; then
        conn_count=$(conntrack -C 2>/dev/null)
    fi
    if [ -z "$conn_count" ] || [ "$conn_count" = "0" ]; then
        conn_count=$(wc -l < /proc/net/nf_conntrack 2>/dev/null || echo 0)
    fi
    [ -z "$conn_count" ] && conn_count=0
    echo "CONN_COUNT=$conn_count"

    echo "===END==="
}

# ========== 2. 端口转发列表 ==========
cmd_port_list() {
    load_config
    write_log "DEBUG" "port_list: 开始加载端口转发列表"
    echo "===PORT_FORWARD_LIST==="
    echo "DEFAULT_TARGET=$DEFAULT_TARGET"
    
    # 性能优化：nft list ruleset 全量查询在规则多时需 1~3 秒，
    # 改为只查 DNAT 链（输出量减少 90%），并加 2 秒文件缓存避免重复调用。
    # cmd_overview / port_list 共享同一缓存文件，2 秒内复用。
    NFT_CACHE_FILE="/tmp/.netmanager_nft_dstnat"
    NFT_TS_FILE="/tmp/.netmanager_nft_dstnat.ts"
    get_nft_dstnat() {
        local now mtime age out
        now=$(date +%s)
        mtime=0
        [ -f "$NFT_TS_FILE" ] && mtime=$(cat "$NFT_TS_FILE" 2>/dev/null)
        age=$((now - mtime))
        # 2 秒内直接复用文件缓存（毫秒级返回）
        if [ -f "$NFT_CACHE_FILE" ] && [ -n "$mtime" ] && [ "$age" -lt 2 ]; then
            cat "$NFT_CACHE_FILE" 2>/dev/null
            return
        fi
        out=$(nft list chain inet fw4 dstnat 2>/dev/null)
        printf '%s' "$out" > "$NFT_CACHE_FILE" 2>/dev/null
        echo "$now" > "$NFT_TS_FILE" 2>/dev/null
        printf '%s' "$out"
    }
    nft_cache=$(get_nft_dstnat)
    
    # 从nft缓存中提取指定端口的计数器
    get_port_pkts() {
        local dport="$1"
        local result=""
        result=$(echo "$nft_cache" | grep -E "dport[[:space:]]+${dport}[[:space:]]" | grep -o 'packets [0-9]*' | head -1 | awk '{print $2}')
        if [ -z "$result" ]; then
            result=$(echo "$nft_cache" | grep -E "sport[[:space:]]+${dport}[[:space:]]" | grep -o 'packets [0-9]*' | head -1 | awk '{print $2}')
        fi
        [ -n "$result" ] && echo "$result" || echo "0"
    }
    
    # 用 uci show 一次性读取所有防火墙配置
    uci_data=$(uci -q show firewall 2>/dev/null)
    
    echo "---IPV4---"
    
    # 解析 redirect 条目，输出到临时文件
    echo "$uci_data" | awk '
    /^firewall\.@redirect\[/ {
        idx = $0
        sub(/^firewall\.@redirect\[/, "", idx)
        sub(/\].*/, "", idx)
        idx = idx + 0
        attr = $0
        sub(/^firewall\.@redirect\[[0-9]+\]\./, "", attr)
        eq_pos = index(attr, "=")
        if (eq_pos > 0) {
            key = substr(attr, 1, eq_pos - 1)
            val = substr(attr, eq_pos + 1)
            # UCI show 输出用单引号，先去掉首尾的单引号，再去掉可能的双引号
            gsub(/^\047/, "", val)
            gsub(/\047$/, "", val)
            gsub(/^"/, "", val)
            gsub(/"$/, "", val)
        }
        if (key == "name") names[idx] = val
        else if (key == "proto") protos[idx] = val
        else if (key == "src_dport") sps[idx] = val
        else if (key == "dest_ip") dips[idx] = val
        else if (key == "dest_port") dps[idx] = val
        else if (key == "enabled") enableds[idx] = val
        if (idx > max_idx) max_idx = idx
    }
    END {
        for (i = 0; i <= max_idx; i++) {
            if (names[i] != "") {
                proto = (protos[i] != "") ? protos[i] : "tcp"
                sp = (sps[i] != "") ? sps[i] : ""
                dip = (dips[i] != "") ? dips[i] : ""
                dp = (dps[i] != "") ? dps[i] : sp
                en = (enableds[i] != "") ? enableds[i] : "1"
                printf "%d|%s|%s|%s|%s|%s|%s\n", i, names[i], proto, sp, dip, dp, en
            }
        }
    }' > /tmp/fwm_pv4.txt
    
    while IFS='|' read -r idx name proto sp dip dp en; do
        [ -z "$name" ] && continue
        pkts="0"
        [ -n "$sp" ] && pkts=$(get_port_pkts "$sp")
        echo "$idx|$name|$proto|$sp|$dip|$dp|$en|$pkts"
    done < /tmp/fwm_pv4.txt
    rm -f /tmp/fwm_pv4.txt
    
    echo "---IPV6---"
    
    # 解析 rule 条目，筛选 IPv6
    echo "$uci_data" | awk '
    /^firewall\.@rule\[/ {
        idx = $0
        sub(/^firewall\.@rule\[/, "", idx)
        sub(/\].*/, "", idx)
        idx = idx + 0
        attr = $0
        sub(/^firewall\.@rule\[[0-9]+\]\./, "", attr)
        eq_pos = index(attr, "=")
        if (eq_pos > 0) {
            key = substr(attr, 1, eq_pos - 1)
            val = substr(attr, eq_pos + 1)
            # 去掉单引号和双引号
            gsub(/^\047/, "", val)
            gsub(/\047$/, "", val)
            gsub(/^"/, "", val)
            gsub(/"$/, "", val)
        }
        if (key == "name") names[idx] = val
        else if (key == "family") fams[idx] = val
        else if (key == "proto") protos[idx] = val
        else if (key == "dest_port") dps[idx] = val
        else if (key == "enabled") enableds[idx] = val
        if (idx > max_idx) max_idx = idx
    }
    END {
        for (i = 0; i <= max_idx; i++) {
            if (names[i] != "" && fams[i] == "ipv6" && dps[i] != "") {
                proto = (protos[i] != "") ? protos[i] : "tcp"
                en = (enableds[i] != "") ? enableds[i] : "1"
                printf "%d|%s|%s|%s|%s\n", i, names[i], proto, dps[i], en
            }
        }
    }' > /tmp/fwm_pv6.txt
    
    while IFS='|' read -r idx name proto dp en; do
        [ -z "$name" ] && continue
        pkts=$(get_port_pkts "$dp")
        echo "$idx|$name|$proto|$dp|$en|$pkts"
    done < /tmp/fwm_pv6.txt
    rm -f /tmp/fwm_pv6.txt
    
    echo "===END==="
    write_log "DEBUG" "port_list: 列表加载完成"
}

# ========== 3. 添加端口转发 ==========
cmd_port_add() {
    port="$1"; proto="$2"; target="$3"; ipver="$4"; dport="$5"
    [ -z "$port" ] && { error "用法: netmanager port_add <外部端口> <tcp|udp|both> [目标IP] [v4|v6|both] [内部端口]"; exit 1; }
    write_log "INFO" "port_add: 请求添加 外部端口=$port 协议=$proto 目标=$target 版本=$ipver 内部端口=${dport:-同外部}"
    [ -z "$proto" ] && proto="tcp"
    load_config
    # 端口格式标准化：冒号转横线（OpenWrt要求 999-1520 而非 999:1520）
    port=$(echo "$port" | sed 's/:/-/g')
    dport=$(echo "$dport" | sed 's/:/-/g')
    # 内部端口：留空则与外部端口一致；非空仅允许数字/横线范围格式
    if [ -n "$dport" ]; then
        case "$dport" in
            *[!0-9-]*|-*) error "内部端口格式无效: $dport (应为 8080 或 1000-2000)"; exit 1 ;;
            *-|*-*-*) error "内部端口格式无效: $dport (应为 8080 或 1000-2000)"; exit 1 ;;
        esac
    else
        dport="$port"
    fi
    if [ -n "$target" ]; then
        case "$target" in
            both|v4|v6)
                # 参数错位：$3 实际是 ipver，target 用默认值
                ipver="$target"
                target="$DEFAULT_TARGET"
                ;;
            *)
                # 正常情况，$3 是IP
                ;;
        esac
    else
        target="$DEFAULT_TARGET"
    fi
    [ -z "$ipver" ] && ipver="both"

    if [ "$ipver" = "v4" ] || [ "$ipver" = "both" ]; then
        for p in $(echo "$proto" | sed 's/both/tcp udp/'); do
            exists=0; idx=0
            while true; do
                uci -q get "firewall.@redirect[$idx]" >/dev/null 2>&1 || break
                sp=$(uci get firewall.@redirect[$idx].src_dport 2>/dev/null)
                pr=$(uci get firewall.@redirect[$idx].proto 2>/dev/null)
                if [ "$sp" = "$port" ] && proto_match "$pr" "$p"; then exists=1; fi
                idx=$((idx+1))
            done
            if [ $exists -eq 0 ]; then
                uci add firewall redirect > /dev/null
                uci set firewall.@redirect[-1].name="Forward-${port}-${p}"
                uci set firewall.@redirect[-1].src="wan"
                uci set firewall.@redirect[-1].proto="$p"
                uci set firewall.@redirect[-1].src_dport="$port"
                uci set firewall.@redirect[-1].dest="lan"
                uci set firewall.@redirect[-1].dest_ip="$target"
                uci set firewall.@redirect[-1].dest_port="$dport"
                uci set firewall.@redirect[-1].target="DNAT"
                info "IPv4 DNAT: $port/$p -> $target:$dport"
            else
                warn "IPv4已存在: $port/$p"
            fi
        done
    fi

    if [ "$ipver" = "v6" ] || [ "$ipver" = "both" ]; then
        for p in $(echo "$proto" | sed 's/both/tcp udp/'); do
            exists=0; idx=0
            while true; do
                uci -q get "firewall.@rule[$idx]" >/dev/null 2>&1 || break
                fam=$(uci get firewall.@rule[$idx].family 2>/dev/null)
                dp=$(uci get firewall.@rule[$idx].dest_port 2>/dev/null)
                pr=$(uci get firewall.@rule[$idx].proto 2>/dev/null)
                if [ "$fam" = "ipv6" ] && [ "$dp" = "$port" ] && proto_match "$pr" "$p"; then exists=1; fi
                idx=$((idx+1))
            done
            if [ $exists -eq 0 ]; then
                uci add firewall rule > /dev/null
                uci set firewall.@rule[-1].name="Allow-IPv6-${port}-${p}"
                uci set firewall.@rule[-1].src="wan"
                uci set firewall.@rule[-1].proto="$p"
                uci set firewall.@rule[-1].dest="lan"
                uci set firewall.@rule[-1].dest_ip="$target"
                uci set firewall.@rule[-1].dest_port="$port"
                uci set firewall.@rule[-1].family="ipv6"
                uci set firewall.@rule[-1].target="ACCEPT"
                info "IPv6放行: $port/$p -> 仅放行到 $target"
            else
                warn "IPv6已存在: $port/$p"
            fi
        done
    fi

    uci commit firewall
    rm -f /tmp/.uci/firewall 2>/dev/null
    /etc/init.d/firewall reload > /dev/null 2>&1
    # 清除 nft 命中数缓存，确保下次 port_list 拿到最新数据
    rm -f /tmp/.netmanager_nft_dstnat /tmp/.netmanager_nft_dstnat.ts 2>/dev/null
    info "完成！"
}

# ========== 4. 编辑端口转发 ==========
cmd_port_edit() {
    old_port="$1"; old_proto="$2"; new_port="$3"; new_proto="$4"; new_target="$5"; new_ipver="$6"; new_dport="$7"
    [ -z "$old_port" ] && { error "用法: netmanager port_edit <旧端口> <旧协议> <新端口> <新协议> <新目标IP> [v4|v6|both] [新内部端口]"; exit 1; }
    [ -z "$old_proto" ] && old_proto="tcp"
    [ -z "$new_proto" ] && new_proto="tcp"
    # 归一化：both/tcpudp 统一为 fw4 合法值 tcpudp（一条规则同时覆盖tcp+udp）
    case "$new_proto" in
        both|tcpudp) new_proto="tcpudp" ;;
    esac
    load_config
    [ -z "$new_target" ] && new_target="$DEFAULT_TARGET"
    [ -z "$new_ipver" ] && new_ipver="both"
    # 新内部端口：留空则与新外部端口一致
    [ -z "$new_dport" ] && new_dport="$new_port"
    # 端口格式标准化（冒号转横线，OpenWrt要求 999-1520 而非 999:1520）
    new_port=$(echo "$new_port" | sed 's/:/-/g')
    old_port=$(echo "$old_port" | sed 's/:/-/g')
    new_dport=$(echo "$new_dport" | sed 's/:/-/g')
    # 内部端口格式校验：仅允许数字/横线范围（须在冒号转换之后进行）
    case "$new_dport" in
        *[!0-9-]*|-*) error "内部端口格式无效: $new_dport (应为 8080 或 1000-2000)"; exit 1 ;;
        *-|*-*-*) error "内部端口格式无效: $new_dport (应为 8080 或 1000-2000)"; exit 1 ;;
    esac

    modified=0
    # 生成要匹配的协议列表（处理 both/tcpudp/空值）
    match_old_protos=""
    case "$old_proto" in
        both|tcpudp)
            match_old_protos="tcp udp"
            ;;
        tcp|udp)
            match_old_protos="$old_proto"
            ;;
        *)
            match_old_protos="$old_proto"
            ;;
    esac

    # 修改IPv4 redirect
    idx=0
    while uci -q get "firewall.@redirect[$idx]" >/dev/null 2>&1; do
        sp=$(uci get firewall.@redirect[$idx].src_dport 2>/dev/null)
        pr=$(uci get firewall.@redirect[$idx].proto 2>/dev/null)
        if [ "$sp" = "$old_port" ]; then
            for mp in $match_old_protos; do
                if proto_match "$pr" "$mp"; then
                    if [ "$new_ipver" = "v6" ]; then
                        # 新规则只要IPv6：删除IPv4并补建IPv6放行（否则新旧规则全部消失）
                        uci delete firewall.@redirect[$idx]
                        info "删除IPv4转发: $old_port/$pr"
                        uci add firewall rule > /dev/null
                        uci set firewall.@rule[-1].name="Allow-IPv6-${new_port}-${new_proto}"
                        uci set firewall.@rule[-1].src="wan"
                        uci set firewall.@rule[-1].proto="$new_proto"
                        uci set firewall.@rule[-1].dest="lan"
                        uci set firewall.@rule[-1].dest_ip="$new_target"
                        uci set firewall.@rule[-1].dest_port="$new_port"
                        uci set firewall.@rule[-1].family="ipv6"
                        uci set firewall.@rule[-1].target="ACCEPT"
                        info "补建IPv6放行: $new_port/$new_proto -> $new_target"
                    else
                        uci set firewall.@redirect[$idx].src_dport="$new_port"
                        uci set firewall.@redirect[$idx].dest_port="$new_dport"
                        uci set firewall.@redirect[$idx].proto="$new_proto"
                        uci set firewall.@redirect[$idx].dest_ip="$new_target"
                        uci set firewall.@redirect[$idx].name="Forward-${new_port}"
                        info "更新IPv4转发: $old_port/$pr -> 外部$new_port/内部$new_dport -> $new_target"
                    fi
                    modified=1
                    break 2
                fi
            done
        fi
        idx=$((idx+1))
    done

    # 修改IPv6 rule（放宽条件，支持系统自带规则）
    idx=0
    while uci -q get "firewall.@rule[$idx]" >/dev/null 2>&1; do
        fam=$(uci get firewall.@rule[$idx].family 2>/dev/null)
        dp=$(uci get firewall.@rule[$idx].dest_port 2>/dev/null)
        pr=$(uci get firewall.@rule[$idx].proto 2>/dev/null)
        if [ "$fam" = "ipv6" ] && [ "$dp" = "$old_port" ]; then
            for mp in $match_old_protos; do
                if proto_match "$pr" "$mp"; then
                    if [ "$new_ipver" = "v4" ]; then
                        # 新规则只要IPv4：删除IPv6并补建IPv4 DNAT（否则新旧规则全部消失）
                        uci delete firewall.@rule[$idx]
                        info "删除IPv6放行: $old_port/$pr"
                        uci add firewall redirect > /dev/null
                        uci set firewall.@redirect[-1].name="Forward-${new_port}"
                        uci set firewall.@redirect[-1].src="wan"
                        uci set firewall.@redirect[-1].proto="$new_proto"
                        uci set firewall.@redirect[-1].src_dport="$new_port"
                        uci set firewall.@redirect[-1].dest="lan"
                        uci set firewall.@redirect[-1].dest_ip="$new_target"
                        uci set firewall.@redirect[-1].dest_port="$new_dport"
                        uci set firewall.@redirect[-1].target="DNAT"
                        info "补建IPv4转发: 外部$new_port/内部$new_dport -> $new_target"
                    else
                        uci set firewall.@rule[$idx].dest_port="$new_port"
                        uci set firewall.@rule[$idx].proto="$new_proto"
                        uci set firewall.@rule[$idx].name="Allow-IPv6-${new_port}-${new_proto}"
                        info "更新IPv6放行: $old_port/$pr -> $new_port/$new_proto"
                    fi
                    modified=1
                    break 2
                fi
            done
        fi
        idx=$((idx+1))
    done

    if [ "$modified" -eq 0 ]; then
        error "未找到旧规则: $old_port/$old_proto"
        exit 1
    fi

    uci commit firewall
    rm -f /tmp/.uci/firewall 2>/dev/null
    /etc/init.d/firewall reload > /dev/null 2>&1
    # 清除 nft 命中数缓存，确保下次 port_list 拿到最新数据
    rm -f /tmp/.netmanager_nft_dstnat /tmp/.netmanager_nft_dstnat.ts 2>/dev/null
    info "端口转发已更新"
}

# ========== 5. 删除端口转发 ==========
cmd_port_del() {
    port="$1"; proto="${2:-tcp}"
    [ -z "$port" ] && { error "用法: netmanager port_del <端口> [tcp|udp|both]"; exit 1; }
    load_config
    write_log "INFO" "port_del: 请求删除 端口=$port 协议=$proto"

    # 端口格式标准化：冒号转横线
    port=$(echo "$port" | sed 's/:/-/g')

    # 扩展proto匹配：处理 both/tcpudp/空值
    # 生成要匹配的协议列表
    match_protos=""
    case "$proto" in
        both|tcpudp)
            match_protos="tcp udp"
            ;;
        tcp|udp)
            match_protos="$proto"
            ;;
        *)
            match_protos="$proto"
            ;;
    esac

    # 收集所有需要删除的 redirect 索引（从后往前，避免索引移位）
    del_indices=""
    idx=0
    while true; do
        name=$(uci get firewall.@redirect[$idx].name 2>/dev/null)
        uci -q get "firewall.@redirect[$idx]" >/dev/null 2>&1 || break
        sp=$(uci get firewall.@redirect[$idx].src_dport 2>/dev/null)
        pr=$(uci get firewall.@redirect[$idx].proto 2>/dev/null)
        if [ "$sp" = "$port" ]; then
            for mp in $match_protos; do
                if proto_match "$pr" "$mp"; then
                    del_indices="$idx $del_indices"
                    break
                fi
            done
        fi
        idx=$((idx+1))
    done

    # 删除收集到的 redirect 规则
    for didx in $del_indices; do
        name=$(uci get firewall.@redirect[$didx].name 2>/dev/null)
        uci delete firewall.@redirect[$didx]
        info "删除IPv4: $name"
    done

    # 收集所有需要删除的 rule 索引（从后往前，避免索引移位）
    del_rule_indices=""
    idx=0
    while true; do
        name=$(uci get firewall.@rule[$idx].name 2>/dev/null)
        uci -q get "firewall.@rule[$idx]" >/dev/null 2>&1 || break
        fam=$(uci get firewall.@rule[$idx].family 2>/dev/null)
        dp=$(uci get firewall.@rule[$idx].dest_port 2>/dev/null)
        pr=$(uci get firewall.@rule[$idx].proto 2>/dev/null)
        if [ "$fam" = "ipv6" ] && [ "$dp" = "$port" ]; then
            for mp in $match_protos; do
                if proto_match "$pr" "$mp"; then
                    del_rule_indices="$idx $del_rule_indices"
                    break
                fi
            done
        fi
        idx=$((idx+1))
    done

    # 删除收集到的 rule 规则
    for didx in $del_rule_indices; do
        name=$(uci get firewall.@rule[$didx].name 2>/dev/null)
        uci delete firewall.@rule[$didx]
        info "删除IPv6: $name"
    done

    uci commit firewall
    rm -f /tmp/.uci/firewall 2>/dev/null
    /etc/init.d/firewall reload > /dev/null 2>&1
    # 清除 nft 命中数缓存，确保下次 port_list 拿到最新数据
    rm -f /tmp/.netmanager_nft_dstnat /tmp/.netmanager_nft_dstnat.ts 2>/dev/null
    info "完成！"
}

# ========== 5. 防火墙规则列表 ==========
cmd_rule_list() {
    echo "===FIREWALL_RULE_LIST==="
    idx=0
    while true; do
        name=$(uci get firewall.@rule[$idx].name 2>/dev/null)
        uci -q get "firewall.@rule[$idx]" >/dev/null 2>&1 || break
        src=$(uci get firewall.@rule[$idx].src 2>/dev/null)
        dst=$(uci get firewall.@rule[$idx].dest 2>/dev/null)
        proto=$(uci get firewall.@rule[$idx].proto 2>/dev/null)
        dp=$(uci get firewall.@rule[$idx].dest_port 2>/dev/null)
        target=$(uci get firewall.@rule[$idx].target 2>/dev/null)
        fam=$(uci get firewall.@rule[$idx].family 2>/dev/null)
        enabled=$(uci get firewall.@rule[$idx].enabled 2>/dev/null)
        [ -z "$enabled" ] && enabled="1"
        [ -z "$fam" ] && fam="any"
        echo "$idx|$name|$src|$dst|$proto|$dp|$target|$fam|$enabled"
        idx=$((idx+1))
    done
    echo "===END==="
}

# ========== 6. 添加防火墙规则 ==========
cmd_rule_add() {
    name="$1"; src="$2"; dst="$3"; proto="$4"; port="$5"; target="$6"; fam="${7:-any}"
    [ -z "$name" ] && { error "用法: netmanager rule_add <名称> <源zone> <目标zone> <协议> <端口> <ACCEPT|DROP|REJECT> [ipv4|ipv6|any]"; exit 1; }
    # 健壮性：检测参数错位。如果 $6 不是合法动作而是 any/ipv4/ipv6，说明 dst 为空被吞了
    case "$target" in
        any|ipv4|ipv6)
            # 参数错位：$3=proto $4=port $5=target $6=fam，dst 为空
            fam="$target"
            target="$port"
            port="$proto"
            proto="$dst"
            dst=""
            ;;
    esac
    [ -z "$proto" ] && proto="tcp"
    [ -z "$target" ] && target="ACCEPT"
    # 端口格式标准化：冒号转横线
    port=$(echo "$port" | sed 's/:/-/g')
    # 关键：@rule[-1] 只能引用已存在节点，必须先 add 才能落到新节点
    # （否则所有 set 会覆盖最后一条既有规则）
    uci add firewall rule > /dev/null
    uci set firewall.@rule[-1].name="$name"
    [ -n "$src" ] && uci set firewall.@rule[-1].src="$src"
    [ -n "$dst" ] && uci set firewall.@rule[-1].dest="$dst"
    uci set firewall.@rule[-1].proto="$proto"
    [ -n "$port" ] && uci set firewall.@rule[-1].dest_port="$port"
    uci set firewall.@rule[-1].target="$target"
    [ "$fam" != "any" ] && uci set firewall.@rule[-1].family="$fam"

    uci commit firewall
    rm -f /tmp/.uci/firewall 2>/dev/null
    /etc/init.d/firewall reload > /dev/null 2>&1
    info "规则已添加: $name ($target)"
}

# ========== 7. 编辑防火墙规则 ==========
cmd_rule_edit() {
    idx="$1"; name="$2"; src="$3"; dst="$4"; proto="$5"; port="$6"; target="$7"; fam="${8:-any}"
    [ -z "$idx" ] && { error "用法: netmanager rule_edit <索引> <名称> <源> <目标> <协议> <端口> <动作> [IP版本]"; exit 1; }
    old_name=$(uci get firewall.@rule[$idx].name 2>/dev/null)
    [ -z "$old_name" ] && { error "规则索引 $idx 不存在"; exit 1; }
    # 端口格式标准化
    port=$(echo "$port" | sed 's/:/-/g')
    # 修改字段（空值保留原值）
    [ -n "$name" ] && uci set firewall.@rule[$idx].name="$name"
    if [ -n "$src" ]; then uci set firewall.@rule[$idx].src="$src"; else uci delete firewall.@rule[$idx].src 2>/dev/null; fi
    if [ -n "$dst" ]; then uci set firewall.@rule[$idx].dest="$dst"; else uci delete firewall.@rule[$idx].dest 2>/dev/null; fi
    [ -n "$proto" ] && uci set firewall.@rule[$idx].proto="$proto"
    if [ -n "$port" ]; then uci set firewall.@rule[$idx].dest_port="$port"; else uci delete firewall.@rule[$idx].dest_port 2>/dev/null; fi
    [ -n "$target" ] && uci set firewall.@rule[$idx].target="$target"
    if [ "$fam" = "any" ] || [ -z "$fam" ]; then
        uci delete firewall.@rule[$idx].family 2>/dev/null
    else
        uci set firewall.@rule[$idx].family="$fam"
    fi
    uci commit firewall
    rm -f /tmp/.uci/firewall 2>/dev/null
    /etc/init.d/firewall reload > /dev/null 2>&1
    info "规则已更新: ${name:-$old_name} ($target)"
}

# ========== 8. 删除防火墙规则 ==========
cmd_rule_del() {
    idx="$1"
    [ -z "$idx" ] && { error "用法: netmanager rule_del <规则索引>"; exit 1; }
    name=$(uci get firewall.@rule[$idx].name 2>/dev/null)
    if [ -n "$name" ]; then
        uci delete firewall.@rule[$idx]
        uci commit firewall
        rm -f /tmp/.uci/firewall 2>/dev/null
        /etc/init.d/firewall reload > /dev/null 2>&1
        info "已删除规则: $name"
    else
        error "规则索引 $idx 不存在"
    fi
}

# ========== 8. SSH登录日志（适配dropbear + BusyBox） ==========
cmd_ssh_log() {
    limit="${1:-50}"
    echo "===SSH_LOG==="

    # dropbear日志格式示例:
    # Mon Aug 25 19:12:34 2026 authpriv.info dropbear[12345]: Password auth succeeded for 'root' from 192.168.31.100:52341
    # Mon Aug 25 19:13:00 2026 authpriv.warn dropbear[12346]: Bad password attempt for 'root' from 192.168.31.100:52342
    # Mon Aug 25 19:13:10 2026 authpriv.info dropbear[12347]: Exit before auth from <192.168.31.100:52343>

    # 成功登录
    echo "---SUCCESS---"
    logread 2>/dev/null | grep -i "dropbear" | grep -i "succeeded\|session opened" | tail -$limit | while read -r line; do
        # 时间：兼容 "Mon Aug 25 19:12:34 2026" 和 "Mon Aug 25 19:12:34" 两种格式
        log_time=$(echo "$line" | sed -n 's/^\([A-Z][a-z][a-z] [A-Z][a-z][a-z] [0-9]* [0-9:]*\).*/\1/p')
        [ -z "$log_time" ] && log_time=$(echo "$line" | awk '{print $1" "$2" "$3" "$4}')
        # 用户名: for 'root' -> 提取引号内
        user=$(echo "$line" | sed -n "s/.*for '\([^']*\)'.*/\1/p")
        [ -z "$user" ] && user="root"
        # IP: from 192.168.31.100:52341 -> 提取from后面的IP
        ip=$(echo "$line" | sed -n 's/.*from \([0-9.]*\):.*/\1/p')
        [ -z "$ip" ] && ip=$(echo "$line" | sed -n 's/.*from <\([0-9.]*\):.*/\1/p')
        [ -z "$ip" ] && ip="unknown"
        echo "$log_time|$user|$ip|success"
    done

    # 失败登录
    echo "---FAILED---"
    logread 2>/dev/null | grep -i "dropbear" | grep -i "bad password\|invalid user\|exit before auth\|auth fail" | tail -$limit | while read -r line; do
        log_time=$(echo "$line" | sed -n 's/^\([A-Z][a-z][a-z] [A-Z][a-z][a-z] [0-9]* [0-9:]*\).*/\1/p')
        [ -z "$log_time" ] && log_time=$(echo "$line" | awk '{print $1" "$2" "$3" "$4}')
        user=$(echo "$line" | sed -n "s/.*for '\([^']*\)'.*/\1/p")
        [ -z "$user" ] && user="unknown"
        ip=$(echo "$line" | sed -n 's/.*from \([0-9.]*\):.*/\1/p')
        [ -z "$ip" ] && ip=$(echo "$line" | sed -n 's/.*from <\([0-9.]*\):.*/\1/p')
        [ -z "$ip" ] && ip="unknown"
        if echo "$line" | grep -qi "bad password"; then
            reason="密码错误"
        elif echo "$line" | grep -qi "invalid user"; then
            reason="无效用户"
        elif echo "$line" | grep -qi "exit before auth"; then
            reason="未认证断开"
        else
            reason="认证失败"
        fi
        echo "$log_time|$user|$ip|$reason"
    done

    # 失败IP统计
    echo "---STATS---"
    logread 2>/dev/null | grep -i "dropbear" | grep -i "bad password\|invalid user\|exit before auth" | sed -n 's/.*from \([0-9.]*\):.*/\1/p' | sort | uniq -c | sort -rn | head -10 | while read -r count ip; do
        echo "$ip|$count"
    done

    echo "===END==="
}

# ========== 9. 端口访问日志 ==========
cmd_access_log() {
    port_filter="$1"
    limit="${2:-100}"
    load_config
    write_log "DEBUG" "access_log: 开始获取, 端口过滤=$port_filter 限制=$limit"
    echo "===ACCESS_LOG==="

    # 当前活跃连接（用awk提取第一个src/dst=原始方向，支持IPv4和IPv6）
    echo "---ACTIVE---"
    active_count=0
    if [ -f /proc/net/nf_conntrack ]; then
        cat /proc/net/nf_conntrack 2>/dev/null | grep "ESTABLISHED" | while read -r line; do
            proto=$(echo "$line" | awk '{print $3}')
            src=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^src=/) {print substr($i,5); exit}}')
            dst=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^dst=/) {print substr($i,5); exit}}')
            sport=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^sport=/) {print substr($i,7); exit}}')
            dport=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^dport=/) {print substr($i,7); exit}}')
            [ -z "$src" ] && src="?"
            [ -z "$dst" ] && dst="?"
            [ -z "$sport" ] && sport="?"
            [ -z "$dport" ] && dport="?"
            if [ -n "$port_filter" ] && [ "$dport" != "$port_filter" ] && [ "$sport" != "$port_filter" ]; then
                continue
            fi
            echo "$proto|$src:$sport|$dst:$dport|已建立"
        done | head -$limit
        active_count=$(cat /proc/net/nf_conntrack 2>/dev/null | grep -c "ESTABLISHED" || echo 0)
    fi
    echo "ACTIVE_COUNT=$active_count"

    # 入站连接统计（原始方向第一个dst是内网前缀 = 外部主动访问内网）
    in_count=0
    if [ -f /proc/net/nf_conntrack ]; then
        lan_prefix=$(uci get network.lan.ipaddr 2>/dev/null | cut -d. -f1-3)
        in_count=$(cat /proc/net/nf_conntrack 2>/dev/null | grep "ESTABLISHED" | awk -v lp="$lan_prefix" '{for(i=1;i<=NF;i++) if($i ~ /^dst=/) {if(index(substr($i,5),lp)==1) c++; break}} END{print c+0}')
    fi
    echo "IN_COUNT=$in_count"

    # 出站连接统计
    out_count=$((active_count - in_count))
    [ $out_count -lt 0 ] && out_count=0
    echo "OUT_COUNT=$out_count"

    # 防火墙拦截统计
    echo "---BLOCKED---"
    block_total=0
    block_output=""

    # 使用nftables列出所有规则
    nft_output=$(nft list ruleset 2>/dev/null)
    
    if [ -n "$nft_output" ]; then
        # 更健壮的解析：处理多种counter格式、行内/分离行、tab空格、policy counter等
        block_output=$(echo "$nft_output" | awk '
        BEGIN { 
            prev_pkts = 0; prev_dport = ""; prev_proto = "any"; 
            in_policy = 0; policy_drops = 0;
            delete port_map; delete port_proto;
        }
        {
            line = $0
            pkts = 0
            dport = ""
            proto = "any"
            
            # ========== 1. 提取counter packets数值 ==========
            # 格式A: counter packets 123 bytes 456
            if (match(line, /counter packets [0-9]+/)) {
                tmp = substr(line, RSTART, RLENGTH)
                gsub(/[^0-9]/, "", tmp)
                pkts = tmp + 0
            }
            # 格式B: packets 123 bytes 456 (行开头)
            if (pkts == 0 && match(line, /[[:space:]]packets [0-9]+/)) {
                tmp = substr(line, RSTART, RLENGTH)
                gsub(/[^0-9]/, "", tmp)
                pkts = tmp + 0
            }
            # 格式C: chain policy counter: "policy drop; counter packets N bytes M"
            if (match(line, /policy drop;[[:space:]]*counter packets [0-9]+/)) {
                tmp = substr(line, RSTART, RLENGTH)
                gsub(/[^0-9]/, "", tmp)
                policy_drops += tmp + 0
                next  # policy行不参与规则匹配
            }
            if (match(line, /policy drop[[:space:]]*$/)) {
                # 有些格式counter在下一行，标记一下
                in_policy = 1
                next
            }
            if (in_policy && pkts > 0) {
                policy_drops += pkts
                in_policy = 0
                next
            }
            
            # ========== 2. 提取dport ==========
            if (match(line, /dport [\x22\x27]?[0-9]+(-[0-9]+)?[\x22\x27]?/)) {
                tmp = substr(line, RSTART, RLENGTH)
                gsub(/dport[[:space:]]+/, "", tmp)
                gsub(/[\x22\x27]/, "", tmp)
                dport = tmp
            }
            
            # ========== 3. 提取协议 ==========
            if (line ~ /meta l4proto tcp/) proto = "tcp"
            else if (line ~ /meta l4proto udp/) proto = "udp"
            else if (line ~ /meta l4proto icmp/) proto = "icmp"
            else if (match(line, /[[:space:]]tcp[[:space:]]/)) proto = "tcp"
            else if (match(line, /[[:space:]]udp[[:space:]]/)) proto = "udp"
            else if (match(line, /[[:space:]]icmp[[:space:]]/)) proto = "icmp"
            
            # ========== 4. 检查是否为drop/reject动作 ==========
            is_drop = 0
            if (match(line, /[[:space:]]drop[[:space:];]/)) is_drop = 1
            else if (match(line, /[[:space:]]drop$/)) is_drop = 1
            else if (match(line, /[[:space:]]reject[[:space:];]/)) is_drop = 1
            else if (match(line, /[[:space:]]reject$/)) is_drop = 1
            
            if (is_drop) {
                use_pkts = (pkts > 0) ? pkts : prev_pkts
                use_dport = (dport != "") ? dport : prev_dport
                use_proto = (proto != "any") ? proto : prev_proto
                
                if (use_pkts > 0) {
                    key = use_proto "|" ((use_dport != "") ? use_dport : "默认规则")
                    port_map[key] += use_pkts
                    port_proto[key] = use_proto
                }
                prev_pkts = 0; prev_dport = ""; prev_proto = "any"
            } else {
                # 保存上下文
                if (pkts > 0) prev_pkts = pkts
                if (dport != "") prev_dport = dport
                if (proto != "any") prev_proto = proto
            }
        }
        END {
            # 输出聚合结果（按端口聚合，pkts从高到低）
            for (k in port_map) {
                pkts = port_map[k] + 0
                proto = port_proto[k]
                # k的格式是 "proto|dport"
                dp = k
                sub(/^[^|]*\|/, "", dp)  # 去掉proto|前缀
                printf "%s|%s|%d|拦截\n", proto, dp, pkts
            }
            # 输出默认policy drop（如果有）
            if (policy_drops > 0) {
                printf "%s|%s|%d|拦截\n", "any", "默认策略DROP", policy_drops
            }
        }')
        
        # 排序并计算总数
        if [ -n "$block_output" ]; then
            # 按pkts降序排序（第三列）
            block_output=$(echo "$block_output" | sort -t'|' -k3,3 -rn)
            block_total=$(echo "$block_output" | awk -F'|' '{sum+=$3} END{print sum+0}')
        fi
    fi

    # 输出结果
    if [ -n "$block_output" ]; then
        echo "$block_output"
    fi
    echo "BLOCK_TOTAL=${block_total:-0}"

    echo "===END==="
    write_log "DEBUG" "access_log: 完成, BLOCK_TOTAL=${block_total:-0}"
}

# ========== 10. 防火墙操作 ==========
cmd_restart() {
    /etc/init.d/firewall restart 2>&1
    info "防火墙已重启"
}
cmd_reload() {
    /etc/init.d/firewall reload 2>&1
    info "防火墙已重载"
}
cmd_backup() {
    backup_file="/root/firewall-$(date +%Y%m%d-%H%M%S).bak"
    cp /etc/config/firewall "$backup_file"
    info "已备份到 $backup_file"
    echo "$backup_file"
}

# ========== 备份恢复 ==========
cmd_backup_list() {
    echo "===BACKUP_LIST==="
    echo "---BACKUPS---"
    backup_dir="/root"
    count=0
    for f in "$backup_dir"/firewall-*.bak; do
        [ -f "$f" ] || continue
        fname=$(basename "$f")
        size=$(wc -c < "$f" 2>/dev/null)
        echo "${fname}|${size}"
        count=$((count+1))
    done
    echo "BACKUP_COUNT=$count"
    echo "===END==="
}

cmd_backup_restore() {
    backup_name="$1"
    [ -z "$backup_name" ] && { error "用法: netmanager backup_restore <备份文件名>"; exit 1; }
    
    backup_file="/root/$backup_name"
    [ ! -f "$backup_file" ] && { error "备份文件不存在: $backup_file"; exit 1; }
    
    # 安全检查：确保文件在 /root/ 目录下
    case "$backup_file" in
        /root/firewall-*.bak) ;;
        *) error "非法的备份文件名"; exit 1 ;;
    esac
    
    # 先备份当前配置
    pre_backup="/root/firewall-pre-restore-$(date +%Y%m%d-%H%M%S).bak"
    cp /etc/config/firewall "$pre_backup"
    
    # 恢复备份
    cp "$backup_file" /etc/config/firewall
    uci commit firewall
    rm -f /tmp/.uci/firewall 2>/dev/null
    
    # 重载防火墙
    /etc/init.d/firewall reload > /dev/null 2>&1
    
    info "已从 $backup_name 恢复配置"
    info "恢复前的配置已备份到: $pre_backup"
}

cmd_backup_delete() {
    backup_name="$1"
    [ -z "$backup_name" ] && { error "用法: netmanager backup_delete <备份文件名>"; exit 1; }
    
    backup_file="/root/$backup_name"
    [ ! -f "$backup_file" ] && { error "备份文件不存在: $backup_file"; exit 1; }
    
    # 安全检查
    case "$backup_file" in
        /root/firewall-*.bak) ;;
        *) error "非法的备份文件名"; exit 1 ;;
    esac
    
    rm -f "$backup_file"
    info "已删除备份: $backup_name"
}

# ========== 文件上传与插件更新 ==========
cmd_upload_file() {
    local filename="$1"
    local b64file="$2"
    [ -z "$filename" ] && { error "用法: netmanager upload_file <文件名> <base64文件>"; exit 1; }
    
    # 安全：文件名防路径穿越（filename=../../etc/xxx 可让root写任意路径）
    case "$filename" in
        */*|*\\*|.|..|"") error "非法的文件名（不允许包含路径分隔符）"; exit 1 ;;
    esac
    # 只保留最后一段文件名，防御双保险
    filename=$(basename -- "$filename")
    case "$filename" in
        .|..|"") error "非法的文件名"; exit 1 ;;
    esac
    
    local upload_dir="/tmp/netmanager_upload"
    mkdir -p "$upload_dir"
    
    local outfile="$upload_dir/$filename"
    
    # 从base64文件解码（避免shell命令行长度限制）
    if [ -n "$b64file" ] && [ -f "$b64file" ]; then
        # BusyBox base64解码：base64 -d 从文件读取
        base64 -d < "$b64file" > "$outfile" 2>/dev/null
        if [ $? -ne 0 ]; then
            # 备选：某些BusyBox版本用 -o 指定输出
            base64 -d -o "$outfile" "$b64file" 2>/dev/null
            if [ $? -ne 0 ]; then
                # 最后备选：直接复制（如果上传的就是原始文件而非base64）
                warn "base64解码失败，尝试按原始文件处理"
                cp "$b64file" "$outfile"
                if [ $? -ne 0 ]; then
                    rm -f "$b64file" 2>/dev/null
                    error "文件保存失败（base64解码且复制均失败）"
                    exit 1
                fi
            fi
        fi
    fi
    
    rm -f "$b64file" 2>/dev/null
    [ -f "$outfile" ] && info "文件已保存: $outfile ($(wc -c < "$outfile" 2>/dev/null)字节)"
    [ ! -f "$outfile" ] && { error "文件保存失败（未收到有效数据）"; exit 1; }
}

cmd_plugin_update() {
    local filename="${1:-}"
    [ -z "$filename" ] && { error "用法: netmanager plugin_update <tar.gz文件名>"; exit 1; }
    load_config
    write_log "INFO" "plugin_update: 开始更新插件, 文件=$filename"
    
    local upload_dir="/tmp/netmanager_upload"
    local package_file="$upload_dir/$filename"
    
    [ ! -f "$package_file" ] && { error "上传的插件包不存在: $package_file"; write_log "ERROR" "plugin_update: 插件包不存在 $package_file"; exit 1; }
    
    # 验证是tar.gz文件
    case "$filename" in
        *.tar.gz|*.tgz) ;;
        *) error "只支持 .tar.gz 格式的插件包"; exit 1 ;;
    esac
    
    # 获取文件大小，写入日志
    local pkg_size=$(wc -c < "$package_file" 2>/dev/null || echo 0)
    write_log "INFO" "plugin_update: 包大小=$pkg_size 字节"
    info "插件包大小: $pkg_size 字节"
    
    # 创建解压工作目录
    local work_dir="/tmp/netmanager_update_$(date +%s)"
    mkdir -p "$work_dir"
    
    # ========== 关键：按用户手动安装的方式 ==========
    # 复制一份到工作目录，避免文件名混乱
    local work_pkg="$work_dir/update.tar.gz"
    cp -f "$package_file" "$work_pkg"
    
    # 安全：tar成员预检（拒绝 ../ 路径穿越与绝对路径成员，防止恶意包覆盖系统文件）
    if ! tar_list_check "$work_pkg" "$work_dir/tar.list"; then
        error "插件包含非法成员（../ 路径穿越或绝对路径），拒绝解压"
        write_log "ERROR" "plugin_update: tar成员预检失败, 非法成员: $(grep -hE '(^|/)\.\.(/|$)|^/' "$work_dir/tar.list" 2>/dev/null | head -5 | tr '\n' ' ')"
        rm -rf "$work_dir"
        exit 1
    fi
    
    info "正在解压插件包 (tar xzvf)..."
    write_log "DEBUG" "plugin_update: 执行 tar xzvf $work_pkg"
    
    # 直接 tar xzvf 解压（-v 打印解压内容方便排查）
    local tar_log="$work_dir/tar.log"
    cd "$work_dir" && tar xzvf "$work_pkg" > "$tar_log" 2>&1
    local tar_rc=$?
    
    # 打印解压输出到前端
    if [ -f "$tar_log" ]; then
        cat "$tar_log"
    fi
    
    if [ $tar_rc -ne 0 ]; then
        # tar xzvf 失败 -> 尝试 BusyBox 兼容方案：gunzip + tar
        info "tar xzvf 失败，尝试 gunzip + tar ..."
        write_log "WARN" "plugin_update: tar xzvf 返回 $tar_rc，尝试 gunzip 方案"
        local ungz="$work_dir/update.tar"
        gunzip -c "$work_pkg" > "$ungz" 2> "$tar_log"
        if [ $? -eq 0 ]; then
            cd "$work_dir" && tar xvf "$ungz" > "$tar_log" 2>&1
            tar_rc=$?
            cat "$tar_log"
        else
            cat "$tar_log"
            tar_rc=99
        fi
    fi
    
    if [ $tar_rc -ne 0 ]; then
        local file_type=$(file "$package_file" 2>/dev/null || echo "unknown")
        error "解压失败 (返回码=$tar_rc, 文件类型=$file_type, 大小=$pkg_size)，请检查插件包"
        write_log "ERROR" "plugin_update: 解压失败 rc=$tar_rc type=$file_type size=$pkg_size"
        rm -rf "$work_dir"
        exit 1
    fi
    
    write_log "DEBUG" "plugin_update: 解压成功, 工作目录=$work_dir"
    info "解压完成，开始安装..."
    
    # 查找 install.sh（可能在根目录，也可能在子目录）
    local install_script=""
    for p in "$work_dir/install.sh" "$work_dir"/*/install.sh; do
        if [ -f "$p" ]; then install_script="$p"; break; fi
    done
    if [ -z "$install_script" ]; then
        install_script=$(find "$work_dir" -name "install.sh" -type f 2>/dev/null | head -1)
    fi
    
    if [ -z "$install_script" ] || [ ! -f "$install_script" ]; then
        error "插件包错误: 未找到 install.sh（请确保是完整安装包）"
        write_log "ERROR" "plugin_update: 未找到 install.sh，解压目录内容: $(ls -R "$work_dir" 2>/dev/null | head -30)"
        rm -rf "$work_dir"
        exit 1
    fi
    
    # ========== 按用户命令执行：chmod +x install.sh && sh install.sh ==========
    # 网页更新模式（默认）：SKIP_UHTTPD_RESTART=1，避免 uhttpd restart 打断当前 HTTP 响应导致 UI 显示 Failed
    info "执行: chmod +x install.sh && SKIP_UHTTPD_RESTART=1 sh install.sh"
    write_log "INFO" "plugin_update: 执行 SKIP_UHTTPD_RESTART=1 sh $install_script"
    chmod +x "$install_script"
    
    local install_log="$work_dir/install.log"
    cd "$(dirname "$install_script")" && SKIP_UHTTPD_RESTART=1 sh install.sh > "$install_log" 2>&1
    local install_rc=$?
    
    # 输出安装日志
    if [ -f "$install_log" ]; then
        cat "$install_log"
    fi
    
    if [ $install_rc -eq 0 ]; then
        info "插件更新完成！请刷新页面 (Ctrl+Shift+R)"
        info "(LuCI 将在 3 秒后自动重启，请勿关闭页面)"
        write_log "INFO" "plugin_update: 更新成功, install_rc=0"
        
        # 关键：先把所有内容刷新到 stdout（HTTP 响应体写完），然后后台延迟 3s 重启 uhttpd
        # 这样浏览器 fetch 能完整收到响应，不会显示 "Failed to fetch"
        sleep 1
        nohup sh -c "sleep 3; /etc/init.d/uhttpd restart >/dev/null 2>&1" >/dev/null 2>&1 &
    else
        error "安装脚本执行失败 (返回码=$install_rc)"
        write_log "ERROR" "plugin_update: 安装失败 install_rc=$install_rc, 日志: $(cat "$install_log" 2>/dev/null | tr '\n' ' ')"
    fi
    
    # 清理临时文件
    rm -rf "$work_dir" 2>/dev/null
    rm -f "$package_file" 2>/dev/null
}

cmd_plugin_version() {
    local plugin_file="$1"
    [ -z "$plugin_file" ] && { error "用法: netmanager plugin_version <tar.gz文件名>"; exit 1; }
    
    local upload_dir="/tmp/netmanager_upload"
    local package_file="$upload_dir/$plugin_file"
    
    [ ! -f "$package_file" ] && { error "插件包不存在: $package_file"; exit 1; }
    
    # 安全：tar成员预检（拒绝 ../ 路径穿越与绝对路径成员）
    if ! tar_list_check "$package_file" "/tmp/.netmanager_pv.list"; then
        error "插件包含非法成员（../ 路径穿越或绝对路径），拒绝解压"
        rm -f /tmp/.netmanager_pv.list
        exit 1
    fi
    rm -f /tmp/.netmanager_pv.list
    
    local extract_dir="/tmp/netmanager_check_$(date +%s)"
    mkdir -p "$extract_dir"
    
    # BusyBox兼容性解压
    local tar_ok=0
    tar xzf "$package_file" -C "$extract_dir" 2>/dev/null && tar_ok=1
    if [ $tar_ok -eq 0 ]; then
        local tar_file="${package_file%.gz}"
        if [ "$tar_file" != "$package_file" ]; then
            gunzip -c "$package_file" > "$tar_file" 2>/dev/null
            if [ $? -eq 0 ]; then
                tar xf "$tar_file" -C "$extract_dir" 2>/dev/null && tar_ok=1
                rm -f "$tar_file"
            fi
        fi
    fi
    if [ $tar_ok -eq 0 ]; then
        echo "ERROR:无法解压插件包"
        rm -rf "$extract_dir"
        exit 1
    fi
    
    # 尝试读取版本信息
    local version="未知版本"
    local readme="$extract_dir/README.md"
    
    if [ -f "$readme" ]; then
        version=$(head -20 "$readme" 2>/dev/null | grep -i "版本" | head -1 | grep -oE '[vV][0-9]+\.[0-9]+\.[0-9]+' | head -1)
        [ -z "$version" ] && version=$(head -20 "$readme" 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fi
    
    echo "===PLUGIN_VERSION==="
    echo "FILE=$plugin_file"
    echo "VERSION=${version:-未知}"
    echo "SIZE=$(wc -c < "$package_file" 2>/dev/null)"
    echo "UPLOAD_TIME=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "===END==="
    
    rm -rf "$extract_dir"
}

cmd_cleanup_uploads() {
    local upload_dir="/tmp/netmanager_upload"
    if [ -d "$upload_dir" ]; then
        rm -rf "$upload_dir"
        info "已清理上传临时文件"
    else
        info "没有需要清理的文件"
    fi
}

# ========== 10.5 在线更新（GitHub Releases） ==========
# 用法:
#   netmanager update_check                 检查最新版本（GitHub API → 302重定向兜底）
#   netmanager update_apply                 下载最新 release 资产并安装（复用 plugin_update 流程）
#   netmanager set_update_mirror <url|''>   设置镜像/加速前缀（空=直连），如 https://gh-proxy.com
#
# 检查策略（两级容错）:
#   1) GitHub API + jsonfilter 解析（可拿到资产 URL/大小）
#   2) 失败则用 /releases/latest 的 302 Location 头解析最新 tag（无需 API，兼容直连受限场景+镜像前缀）
# 版本比较: 语义化 major.minor.patch 数值比较，仅提示升级，不自动降级

# 语义化版本比较: version_gt 1.10.0 1.9.9 → 返回 0(真)
version_gt() {
    local v1="${1#v}" v2="${2#v}"
    local a1 a2 a3 b1 b2 b3
    a1=$(echo "$v1" | cut -d. -f1); a2=$(echo "$v1" | cut -d. -f2); a3=$(echo "$v1" | cut -d. -f3)
    b1=$(echo "$v2" | cut -d. -f1); b2=$(echo "$v2" | cut -d. -f2); b3=$(echo "$v2" | cut -d. -f3)
    a1=${a1:-0}; a2=${a2:-0}; a3=${a3:-0}
    b1=${b1:-0}; b2=${b2:-0}; b3=${b3:-0}
    [ "$a1" -gt "$b1" ] 2>/dev/null && return 0
    [ "$a1" -eq "$b1" ] 2>/dev/null || return 1
    [ "$a2" -gt "$b2" ] 2>/dev/null && return 0
    [ "$a2" -eq "$b2" ] 2>/dev/null || return 1
    [ "$a3" -gt "$b3" ] 2>/dev/null && return 0
    return 1
}

# HTTP GET：兼容 wget / uclient-fetch / curl，输出 body 到 stdout
update_http_get() {
    local url="$1"
    if command -v wget >/dev/null 2>&1; then
        wget -q -T 15 -O - "$url" 2>/dev/null && return 0
    fi
    if command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q -T 15 -O - "$url" 2>/dev/null && return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -sS --max-time 15 "$url" 2>/dev/null && return 0
    fi
    return 1
}

cmd_update_check() {
    load_config
    local mirror=$(uci get netmanager.settings.update_mirror 2>/dev/null | tr -d ' ')
    local api_url="$REPO_API_URL"
    [ -n "$mirror" ] && api_url="${mirror%/}/$REPO_API_URL"

    echo "===UPDATE_CHECK==="
    echo "CURRENT_VERSION=v$PLUGIN_VERSION"
    echo "REPO=${REPO_OWNER}/${REPO_NAME}"
    echo "MIRROR=${mirror:-(直连)}"

    local latest_tag="" asset_url="" asset_size=0 api_ok=0

    # ---- 方式1: GitHub API + jsonfilter ----
    if command -v jsonfilter >/dev/null 2>&1; then
        local api_json
        api_json=$(update_http_get "$api_url")
        if [ -n "$api_json" ] && echo "$api_json" | grep -q '"tag_name"'; then
            latest_tag=$(echo "$api_json" | jsonfilter -e '@.tag_name' 2>/dev/null)
            asset_url=$(echo "$api_json" | jsonfilter -e '@.assets[0].browser_download_url' 2>/dev/null)
            asset_size=$(echo "$api_json" | jsonfilter -e '@.assets[0].size' 2>/dev/null)
            api_ok=1
        fi
    fi

    # ---- 方式2: /releases/latest 302 Location 解析 tag（无需 API） ----
    if [ -z "$latest_tag" ]; then
        local latest_url="$REPO_BASE_URL/releases/latest"
        [ -n "$mirror" ] && latest_url="${mirror%/}/$latest_url"
        latest_tag=$( (wget -S --spider -T 15 -O /dev/null "$latest_url" 2>&1 || true) | grep -i 'location:' | sed -n 's/.*\/releases\/tag\/\(v[0-9][0-9.]*\).*/\1/p' | tail -1)
        if [ -z "$latest_tag" ] && command -v curl >/dev/null 2>&1; then
            latest_tag=$(curl -sIL --max-time 15 -o /dev/null -w '%{url_effective}' "$latest_url" 2>/dev/null | sed -n 's/.*\/releases\/tag\/\(v[0-9][0-9.]*\).*/\1/p')
        fi
    fi

    if [ -z "$latest_tag" ]; then
        echo "UPDATE_AVAILABLE=unknown"
        echo "ERROR=无法获取最新版本（网络不通或 GitHub 直连受限，可设置镜像加速后重试）"
        echo "===END==="
        write_log "WARN" "update_check: 无法获取最新版本 (mirror=${mirror:-无})"
        return 1
    fi

    # 构造资产下载 URL（CI 固定命名规则兜底；API 获取的真实 URL 优先）
    local asset_name="luci-app-netmanager-install_${latest_tag}.tar.gz"
    local dl_url="${REPO_BASE_URL}/releases/download/${latest_tag}/${asset_name}"
    [ -z "$asset_url" ] && asset_url="$dl_url"
    [ -n "$mirror" ] && asset_url="${mirror%/}/$asset_url"

    local update_available=0
    version_gt "$latest_tag" "v$PLUGIN_VERSION" && update_available=1

    echo "LATEST_VERSION=$latest_tag"
    echo "ASSET_URL=$asset_url"
    echo "ASSET_SIZE=$asset_size"
    echo "UPDATE_AVAILABLE=$update_available"
    if [ "$update_available" = "1" ]; then
        echo "MESSAGE=发现新版本 $latest_tag（当前 v$PLUGIN_VERSION）"
    else
        echo "MESSAGE=当前已是最新版本 (v$PLUGIN_VERSION)"
    fi
    echo "===END==="
    write_log "INFO" "update_check: current=v$PLUGIN_VERSION latest=$latest_tag available=$update_available (api_ok=$api_ok)"
    return 0
}

cmd_update_apply() {
    load_config
    write_log "INFO" "update_apply: 开始在线更新 (current=v$PLUGIN_VERSION)"

    # 1. 检查最新版本（内部结构化输出同时展示给用户）
    local check_out
    check_out=$(cmd_update_check)
    local latest_tag=$(echo "$check_out" | sed -n 's/^LATEST_VERSION=//p')
    local asset_url=$(echo "$check_out" | sed -n 's/^ASSET_URL=//p')
    echo "$check_out"
    if [ -z "$latest_tag" ] || [ -z "$asset_url" ]; then
        error "在线更新失败：无法获取最新版本信息"
        exit 1
    fi
    if echo "$check_out" | grep -q '^UPDATE_AVAILABLE=0$'; then
        info "当前已是最新版本 (v$PLUGIN_VERSION)，无需更新"
        return 0
    fi
    info "准备在线更新: v$PLUGIN_VERSION -> $latest_tag"

    # 2. 下载资产（wget/uclient-fetch/curl 依次兜底；GitHub release URL 302 由客户端自动跟随）
    local download_dir="/tmp/netmanager_upload"
    mkdir -p "$download_dir" 2>/dev/null
    local dest_name="luci-app-netmanager-install_${latest_tag}.tar.gz"
    local dest_file="$download_dir/$dest_name"
    info "开始下载: $asset_url"
    write_log "INFO" "update_apply: 下载 $asset_url -> $dest_file"
    local dl_rc=1
    if command -v wget >/dev/null 2>&1; then
        wget -T 60 -O "$dest_file" "$asset_url" >/dev/null 2>&1 && dl_rc=0
    fi
    if [ $dl_rc -ne 0 ] && command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -T 60 -O "$dest_file" "$asset_url" >/dev/null 2>&1 && dl_rc=0
    fi
    if [ $dl_rc -ne 0 ] && command -v curl >/dev/null 2>&1; then
        curl -sSL --max-time 300 -o "$dest_file" "$asset_url" >/dev/null 2>&1 && dl_rc=0
    fi
    if [ $dl_rc -ne 0 ] || [ ! -s "$dest_file" ]; then
        rm -f "$dest_file" 2>/dev/null
        error "下载失败（网络不通或镜像不可用，可设置镜像加速后重试）"
        write_log "ERROR" "update_apply: 下载失败 url=$asset_url"
        exit 1
    fi

    # 3. 下载校验：大小 + tar 完整性预检，杜绝半截包/HTML 错误页进入安装流程
    local pkg_size=$(wc -c < "$dest_file" 2>/dev/null | tr -d ' ')
    if [ "${pkg_size:-0}" -lt 2000 ]; then
        rm -f "$dest_file" 2>/dev/null
        error "下载的文件异常（仅 ${pkg_size:-0} 字节），已放弃更新"
        write_log "ERROR" "update_apply: 下载文件过小 size=$pkg_size"
        exit 1
    fi
    if ! tar tzf "$dest_file" >/dev/null 2>&1; then
        rm -f "$dest_file" 2>/dev/null
        error "下载的文件不是有效的 tar.gz 包（可能不完整），已放弃更新"
        write_log "ERROR" "update_apply: tar 校验失败 size=$pkg_size"
        exit 1
    fi
    info "下载完成: $pkg_size 字节，完整性校验通过"
    write_log "INFO" "update_apply: 下载校验通过 size=$pkg_size"

    # 4. 复用 plugin_update 安装流程（解压 + install.sh + 延迟重启 uhttpd）
    cmd_plugin_update "$dest_name"
}

cmd_set_update_mirror() {
    local m="$1"
    load_config
    if [ -n "$m" ]; then
        case "$m" in
            http://*|https://*) ;;
            *) error "镜像前缀必须以 http:// 或 https:// 开头（留空表示直连 GitHub）"; exit 1 ;;
        esac
        m="${m%/}"
    fi
    uci set netmanager.settings.update_mirror="$m"
    uci commit netmanager
    if [ -n "$m" ]; then
        info "更新镜像已设置: $m"
    else
        info "更新镜像已清空（直连 GitHub）"
    fi
}

# ========== 11. 设置管理 ==========
cmd_set_default_target() {
    ip="$1"
    [ -z "$ip" ] && { error "用法: netmanager set_default_target <IP>"; exit 1; }
    load_config
    uci set netmanager.settings.default_target="$ip"
    uci commit netmanager
    info "默认目标IP已设置为: $ip"
}

cmd_log_set() {
    local enable="${1:-0}"
    load_config
    if [ "$enable" = "1" ] || [ "$enable" = "on" ] || [ "$enable" = "true" ]; then
        uci set netmanager.settings.log_enable='1'
        uci commit netmanager
        reload_log_setting
        mkdir -p "$LOG_DIR" 2>/dev/null
        info "运行日志已开启（输出目录: $LOG_DIR）"
        write_log "INFO" "===== 日志开启 ====="
    else
        write_log "INFO" "===== 日志关闭 ====="
        uci set netmanager.settings.log_enable='0'
        uci commit netmanager
        reload_log_setting
        info "运行日志已关闭"
    fi
}

cmd_log_get() {
    local lines="${1:-200}"
    mkdir -p "$LOG_DIR" 2>/dev/null
    echo "===RUN_LOG==="
    echo "LOG_ENABLED=$LOG_ENABLED"
    echo "LOG_FILE=$LOG_FILE"
    if [ -f "$LOG_FILE" ]; then
        local total=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        local sz=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
        echo "LOG_LINES=$total"
        echo "LOG_SIZE=$sz"
        echo "---CONTENT---"
        tail -n "$lines" "$LOG_FILE" 2>/dev/null
    else
        echo "LOG_LINES=0"
        echo "LOG_SIZE=0"
    fi
    echo "===END==="
}

cmd_log_clear() {
    if [ -f "$LOG_FILE" ]; then
        rm -f "$LOG_FILE" 2>/dev/null
        info "运行日志已清空"
    else
        info "日志文件不存在，无需清理"
    fi
}

cmd_settings() {
    load_config
    echo "===SETTINGS==="
    echo "DEFAULT_TARGET=$DEFAULT_TARGET"
    echo "LOG_DAYS=$(uci get netmanager.settings.log_days 2>/dev/null || echo 7)"
    echo "LOG_ENABLE=$LOG_ENABLED"
    echo "LOG_FILE=$LOG_FILE"
    echo "CHINA_FILTER_ENABLED=$(uci get netmanager.settings.china_filter_enable 2>/dev/null || echo 0)"
    echo "CHINA_FILTER_URL=$(uci get netmanager.settings.china_filter_url 2>/dev/null || echo 'https://metowolf.github.io/iplist/data/special/china.txt')"
    echo "CHINA_FILTER_CRON=$(uci get netmanager.settings.china_filter_cron 2>/dev/null || echo '0 3 * * 0')"
    echo "CHINA_FILTER_LAST_UPDATE=$(uci get netmanager.settings.china_filter_last_update 2>/dev/null)"
    echo "CHINA_FILTER_COUNT=$(uci get netmanager.settings.china_filter_count 2>/dev/null || echo 0)"
    echo "UPDATE_MIRROR=$(uci get netmanager.settings.update_mirror 2>/dev/null)"
    echo "===END==="
}

# ========== 12. 版本信息 ==========
cmd_version() {
    echo "网络管理插件 v$PLUGIN_VERSION"
    echo ""
    echo "功能: 系统概览 / 端口转发 / 规则管理 / SSH日志 / 访问日志 / 备份恢复 / 在线更新 / 插件更新 / 运行日志 / 中国IPv4访问限制"
    echo "适配: iStoreOS / OpenWrt (fw4/nftables)"
}

# ========== 13. 中国IPv4访问限制 ==========
# 原理：独立 nft 表 inet netmanager（与 fw4 分离，fw4 reload 不影响本表），
#       内含 china_v4 CIDR 集合 + input/forward 两条 base chain(priority -50)，
#       规则：iifname {wan_devs} ct state new {tcp,udp} 且 ip saddr 不在中国集合 -> drop。
#       仅拦截境外 IPv4 新建连接到已开放端口，不影响已建立连接/出站/局域网间转发。
CHINA_LIST_DIR="/etc/netmanager"
CHINA_LIST_FILE="$CHINA_LIST_DIR/china_v4.list"
CHINA_NFT_TABLE="inet netmanager"
CHINA_DEFAULT_URL="https://metowolf.github.io/iplist/data/special/china.txt"
CHINA_DEFAULT_CRON="0 3 * * 0"

china_get_url() {
    local u=$(uci get netmanager.settings.china_filter_url 2>/dev/null)
    echo "${u:-$CHINA_DEFAULT_URL}"
}

china_get_cron() {
    local c=$(uci get netmanager.settings.china_filter_cron 2>/dev/null)
    echo "${c:-$CHINA_DEFAULT_CRON}"
}

china_get_enable() {
    local e=$(uci get netmanager.settings.china_filter_enable 2>/dev/null)
    [ "$e" = "1" ] && echo 1 || echo 0
}

# 探测 WAN 设备名（去重、空格分隔），用于 iifname 匹配
get_wan_devs() {
    local devs="" d nd val zn net
    # 1) 默认路由设备
    d=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ -n "$d" ] && devs="$d"
    # 2) network.wan / wan6 的 device / ifname
    for n in wan wan6; do
        nd=$(uci get network.$n.device 2>/dev/null)
        [ -z "$nd" ] && nd=$(uci get network.$n.ifname 2>/dev/null)
        [ -n "$nd" ] && devs="$devs $nd"
    done
    # 3) firewall wan/wan6 zone 的 device 与 network（network 需解析到 device）
    idx=0
    while uci get firewall.@zone[$idx].name >/dev/null 2>&1; do
        zn=$(uci get firewall.@zone[$idx].name 2>/dev/null)
        case "$zn" in
            wan|wan6)
                val=$(uci get firewall.@zone[$idx].device 2>/dev/null)
                [ -n "$val" ] && devs="$devs $val"
                val=$(uci get firewall.@zone[$idx].network 2>/dev/null)
                [ -n "$val" ] && for net in $val; do
                    nd=$(uci get network.$net.device 2>/dev/null)
                    [ -z "$nd" ] && nd=$(uci get network.$net.ifname 2>/dev/null)
                    [ -n "$nd" ] && devs="$devs $nd"
                done
                ;;
        esac
        idx=$((idx+1))
    done
    # 去重 + 仅保留合法接口名
    echo "$devs" | tr ' ' '\n' | grep -E '^[a-zA-Z0-9._@-]+$' | sort -u | grep -v '^$' | tr '\n' ' '
}

# 创建 china_v4 集合（兼容旧版 nft：先尝试 interval,auto-merge；失败则降级仅 interval）
# 成功后设置全局 CHINA_SET_FLAGS = "modern" 或 "compat"
china_create_set() {
    CHINA_SET_FLAGS=""
    # 先确保表存在
    nft add table inet netmanager 2>/dev/null
    local nft_err
    nft_err=$( ( nft 'add set inet netmanager china_v4 { type ipv4_addr; flags interval, auto-merge; }' ) 2>&1 )
    if [ -z "$nft_err" ]; then
        CHINA_SET_FLAGS="modern"
        return 0
    fi
    # 失败且含 "unexpected auto-merge" → 旧版 nft，降级
    case "$nft_err" in
        *unexpected\ auto-merge*|*auto-merge*)
            write_log "INFO" "china_filter: 旧版 nft 不支持 auto-merge，降级为 flags interval + 一次性原子加载"
            local nft_err2
            nft_err2=$( ( nft 'add set inet netmanager china_v4 { type ipv4_addr; flags interval; }' ) 2>&1 )
            if [ -z "$nft_err2" ]; then
                CHINA_SET_FLAGS="compat"
                return 0
            fi
            write_log "ERROR" "china_filter: 降级 add set interval 也失败: $nft_err2"
            error "nft 创建 china_v4 集合失败（降级后）: $nft_err2"
            return 1
            ;;
        *)
            write_log "ERROR" "china_filter: add set china_v4 失败: $nft_err"
            error "nft 创建 china_v4 集合失败: $nft_err"
            return 1
            ;;
    esac
}

# 载入 CIDR 到 china_v4 集合
#   modern(有auto-merge)  → 分片 500 条批量 add element（CIDR 重叠容忍）
#   compat(仅interval)    → 所有 CIDR 在同一条 add element 中，让内核原子合并重叠区间
# 返回成功载入条数；失败返回 0
china_load_set() {
    [ -f "$CHINA_LIST_FILE" ] || { echo 0; return; }
    # 若 china_apply_rules 未先调用则 CHINA_SET_FLAGS 为空，自行确保表+集存在
    if [ -z "$CHINA_SET_FLAGS" ]; then
        if nft list chain inet netmanager 2>/dev/null; then
            :
        else
            nft add table inet netmanager 2>/dev/null
        fi
        # 检测集合是否存在并推断模式
        if nft list set inet netmanager china_v4 2>/dev/null | grep -q 'auto-merge'; then
            CHINA_SET_FLAGS="modern"
        elif nft list set inet netmanager china_v4 >/dev/null 2>&1; then
            CHINA_SET_FLAGS="compat"
        else
            china_create_set || { echo 0; return; }
        fi
    fi

    local clean="/tmp/netmanager_china_clean.list"
    local ef="/tmp/netmanager_china_elem.nft"
    local total=0 loaded=0
    local nft_err=""
    rm -f "$clean" "$ef" /tmp/netmanager_china_nft.err 2>/dev/null

    # 先过滤出纯净的 CIDR 行
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$CHINA_LIST_FILE" > "$clean" 2>/dev/null
    total=$(wc -l < "$clean" 2>/dev/null | tr -d ' ')
    [ "${total:-0}" -lt 50 ] && { rm -f "$clean"; echo 0; return; }

    if [ "$CHINA_SET_FLAGS" = "modern" ]; then
        # ========= 分片加载（auto-merge 允许重叠逐批加） =========
        local batch=500 buf="" buf_n=0 line
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            if [ "$buf_n" -ge "$batch" ]; then
                {
                    printf 'add element inet netmanager china_v4 { %s }\n' "$buf"
                } > "$ef"
                if nft -f "$ef" 2>/tmp/netmanager_china_nft.err; then
                    loaded=$((loaded + buf_n))
                else
                    nft_err=$(cat /tmp/netmanager_china_nft.err 2>/dev/null | tr '\n' ' ')
                    write_log "WARN" "china_filter: (modern) nft batch add element failed (size=$buf_n, head=$(echo "$buf" | cut -c1-80)): $nft_err"
                fi
                buf="" buf_n=0
            fi
            if [ "$buf_n" -eq 0 ]; then
                buf="$line"
            else
                buf="$buf, $line"
            fi
            buf_n=$((buf_n + 1))
        done < "$clean"
        # 尾批
        if [ "$buf_n" -gt 0 ]; then
            {
                printf 'add element inet netmanager china_v4 { %s }\n' "$buf"
            } > "$ef"
            if nft -f "$ef" 2>/tmp/netmanager_china_nft.err; then
                loaded=$((loaded + buf_n))
            else
                nft_err=$(cat /tmp/netmanager_china_nft.err 2>/dev/null | tr '\n' ' ')
                write_log "WARN" "china_filter: (modern) nft tail batch add element failed (size=$buf_n, head=$(echo "$buf" | cut -c1-80)): $nft_err"
            fi
        fi
    else
        # ========= 一次性原子加载（compat：无 auto-merge，全部 CIDR 一条 add element 让内核合并重叠区间） =========
        # 组装 "add element inet netmanager china_v4 { a, b, c, ... }"
        {
            printf 'add element inet netmanager china_v4 { '
            awk 'BEGIN{ORS=""}{if(NR>1)printf ", ";printf "%s",$0}' "$clean"
            printf ' }\n'
        } > "$ef"
        if nft -f "$ef" 2>/tmp/netmanager_china_nft.err; then
            loaded="$total"
        else
            nft_err=$(cat /tmp/netmanager_china_nft.err 2>/dev/null | tr '\n' ' ')
            # 部分老 nft 即使 atomic 也对特别长的行敏感；失败后回退单条 add element 逐行（慢但稳）
            local ok_rows=0 bad_rows=0 l
            write_log "WARN" "china_filter: (compat) atomic add element 失败，回退逐行加载: $nft_err"
            while IFS= read -r l; do
                [ -z "$l" ] && continue
                if nft "add element inet netmanager china_v4 { $l }" 2>/dev/null; then
                    ok_rows=$((ok_rows + 1))
                else
                    bad_rows=$((bad_rows + 1))
                fi
            done < "$clean"
            loaded="$ok_rows"
            write_log "INFO" "china_filter: (compat) 逐行回退完成: 成功=$ok_rows 失败=$bad_rows"
        fi
    fi

    rm -f "$clean" "$ef" /tmp/netmanager_china_nft.err 2>/dev/null
    echo "${loaded:-0}"
}

# 创建表/集合、载入CIDR、安装 input+forward 两条 drop 规则
china_apply_rules() {
    [ -f "$CHINA_LIST_FILE" ] || { error "中国IP列表文件不存在: $CHINA_LIST_FILE"; return 1; }
    # 先强制删除旧表，彻底防止遗留脏结构（旧 flag / 错误 size）
    nft delete table inet netmanager 2>/dev/null
    local nft_err
    if ! nft add table inet netmanager 2>/tmp/netmanager_china_nft.err; then
        nft_err=$(cat /tmp/netmanager_china_nft.err 2>/dev/null | tr '\n' ' ')
        write_log "ERROR" "china_filter: add table inet netmanager 失败: $nft_err"
        rm -f /tmp/netmanager_china_nft.err 2>/dev/null
        error "nft 创建 inet netmanager 表失败: $nft_err"
        return 1
    fi
    rm -f /tmp/netmanager_china_nft.err 2>/dev/null

    # 根据 nft 版本自动选择 set flag 策略
    CHINA_SET_FLAGS=""
    if ! china_create_set; then
        # china_create_set 内部已经写过诊断+error
        return 1
    fi
    write_log "INFO" "china_filter: 使用 nft china_v4 集合模式: $CHINA_SET_FLAGS"

    local count
    count=$(china_load_set)
    if [ "${count:-0}" -lt 50 ]; then
        error "中国IP列表载入失败或条数过少($count)，已中止应用规则"
        return 1
    fi

    local devs
    devs=$(get_wan_devs)
    if [ -z "$devs" ]; then
        error "未探测到WAN设备，无法安装过滤规则（请检查 wan 接口/默认路由）"
        return 1
    fi
    # 构造 iifname { "eth0", "pppoe-wan" }（带双引号）
    local ifname_set
    ifname_set=$(echo "$devs" | awk '{for(i=1;i<=NF;i++){if(i>1)printf ", ";printf "\"%s\"",$i}}')

    # 删除旧链（幂等）
    nft delete chain inet netmanager china_input 2>/dev/null
    nft delete chain inet netmanager china_forward 2>/dev/null

    local rf="/tmp/netmanager_china_rules.nft"
    {
        echo "add chain inet netmanager china_input { type filter hook input priority -50; policy accept; }"
        echo "add chain inet netmanager china_forward { type filter hook forward priority -50; policy accept; }"
        printf 'add rule inet netmanager china_forward iifname { %s } ct state new meta l4proto { tcp, udp } ip saddr != @china_v4 counter drop\n' "$ifname_set"
        printf 'add rule inet netmanager china_input iifname { %s } ct state new meta l4proto { tcp, udp } ip saddr != @china_v4 counter drop\n' "$ifname_set"
    } > "$rf"
    if ! nft -f "$rf" 2>/tmp/netmanager_china_rules.err; then
        write_log "ERROR" "china_filter: 规则链安装失败: $(cat /tmp/netmanager_china_rules.err 2>/dev/null | tr '\n' ' ')"
        rm -f "$rf" /tmp/netmanager_china_rules.err 2>/dev/null
        error "nft 规则安装失败（nft -f 返回错误）"
        return 1
    fi
    rm -f "$rf" /tmp/netmanager_china_rules.err 2>/dev/null

    uci set netmanager.settings.china_filter_count="$count"
    uci commit netmanager 2>/dev/null
    info "中国IPv4过滤规则已应用: 条数=$count WAN设备=[$(echo $devs)]"
    write_log "INFO" "china_filter apply: count=$count devs=$devs"
    return 0
}

china_clear_kernel() {
    nft delete table inet netmanager 2>/dev/null
}

# 下载中国IP列表（URL 取自配置），校验后存到持久化路径
china_download() {
    local url=$(china_get_url)
    local tmp="/tmp/netmanager_china.tmp"
    info "下载中国IP列表: $url"
    write_log "INFO" "china_filter: 下载 $url"
    mkdir -p "$CHINA_LIST_DIR" 2>/dev/null
    if command -v wget >/dev/null 2>&1; then
        wget -q -T 30 -O "$tmp" "$url" 2>/dev/null
    elif command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q -T 30 -O "$tmp" "$url" 2>/dev/null
    elif command -v curl >/dev/null 2>&1; then
        curl -sS --max-time 30 -o "$tmp" "$url" 2>/dev/null
    else
        error "未找到 wget/uclient-fetch/curl，无法下载"
        return 1
    fi
    if [ ! -s "$tmp" ]; then
        error "下载失败：文件为空或不存在（请检查订阅链接与网络）"
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
    # 纯化：去 UTF-8 BOM(首字节EFBBBF)、去 CR(\r)、去以#开头注释/空行，仅保留合法 IPv4 CIDR
    local clean="/tmp/netmanager_china_clean.tmp"
    rm -f "$clean" 2>/dev/null
    if command -v sed >/dev/null 2>&1; then
        sed '1s/^\xef\xbb\xbf//' "$tmp" 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' > "$clean" 2>/dev/null
    else
        tr -d '\r' < "$tmp" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' > "$clean" 2>/dev/null
    fi
    local n
    n=$(wc -l < "$clean" 2>/dev/null | tr -d ' ')
    if [ "${n:-0}" -lt 100 ]; then
        error "下载内容不像 CIDR 列表（有效行数=$n），已拒绝保存"
        rm -f "$tmp" "$clean" 2>/dev/null
        return 1
    fi
    mv -f "$clean" "$CHINA_LIST_FILE"
    rm -f "$tmp" 2>/dev/null
    uci set netmanager.settings.china_filter_count="$n"
    uci set netmanager.settings.china_filter_last_update="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    uci commit netmanager 2>/dev/null
    info "下载完成：$n 条CIDR"
    return 0
}

china_cron_remove() {
    local cr="/etc/crontabs/root"
    [ -f "$cr" ] || return 0
    grep -v 'netmanager china_filter update' "$cr" > "$cr.tmp" 2>/dev/null
    mv -f "$cr.tmp" "$cr" 2>/dev/null
    /etc/init.d/cron reload 2>/dev/null
    return 0
}

china_cron_install() {
    local cr="/etc/crontabs/root"
    mkdir -p /etc/crontabs 2>/dev/null
    [ -f "$cr" ] || touch "$cr"
    china_cron_remove
    local expr=$(china_get_cron)
    echo "$expr /usr/sbin/netmanager china_filter update" >> "$cr"
    /etc/init.d/cron reload 2>/dev/null
    info "已安装 cron 更新计划: $expr"
}

cmd_china_status() {
    load_config
    local en=$(china_get_enable)
    local url=$(china_get_url)
    local cron=$(china_get_cron)
    local lu=$(uci get netmanager.settings.china_filter_last_update 2>/dev/null)
    local cnt=$(uci get netmanager.settings.china_filter_count 2>/dev/null)
    [ -z "$cnt" ] && cnt=0
    local devs=$(get_wan_devs)
    [ -z "$devs" ] && devs="(未探测到)"
    local active=0
    if nft list table inet netmanager >/dev/null 2>&1; then
        if nft list chain inet netmanager china_forward 2>/dev/null | grep -q 'china_v4'; then
            active=1
        fi
    fi
    echo "===CHINA_FILTER==="
    echo "CHINA_FILTER_ENABLED=$en"
    echo "URL=$url"
    echo "CRON=$cron"
    echo "LAST_UPDATE=${lu:-未更新}"
    echo "COUNT=$cnt"
    echo "WAN_DEVS=$devs"
    echo "RULE_ACTIVE=$active"
    echo "LIST_FILE=$CHINA_LIST_FILE"
    echo "===END==="
}

cmd_china_set_url() {
    local url="$1"
    [ -z "$url" ] && { error "用法: netmanager china_filter set_url <url>"; exit 1; }
    case "$url" in
        http://*|https://*) ;;
        *) error "URL 必须以 http:// 或 https:// 开头"; exit 1 ;;
    esac
    load_config
    uci set netmanager.settings.china_filter_url="$url"
    uci commit netmanager
    info "订阅链接已保存: $url"
    info "点击「更新IP库」或重新启用以生效"
}

cmd_china_set_cron() {
    local expr="$1"
    [ -z "$expr" ] && { error "用法: netmanager china_filter set_cron \"<5段cron表达式>\""; exit 1; }
    local fields=$(echo "$expr" | awk '{print NF}')
    [ "$fields" != "5" ] && { error "cron表达式必须为5段（分 时 日 月 周），当前 $fields 段"; exit 1; }
    if echo "$expr" | tr ' ' '\n' | grep -qE '[^0-9*,/\-]'; then
        error "cron表达式含非法字符（仅允许 0-9 * / , -）"; exit 1
    fi
    load_config
    uci set netmanager.settings.china_filter_cron="$expr"
    uci commit netmanager
    info "更新计划已保存: $expr"
    [ "$(china_get_enable)" = "1" ] && china_cron_install
}

cmd_china_enable() {
    load_config
    if [ ! -f "$CHINA_LIST_FILE" ]; then
        china_download || { error "启用失败：无法获取中国IP列表"; exit 1; }
    fi
    uci set netmanager.settings.china_filter_enable='1'
    uci commit netmanager
    if ! china_apply_rules; then
        uci set netmanager.settings.china_filter_enable='0'
        uci commit netmanager
        error "启用失败：规则应用失败，已回滚为关闭状态"
        exit 1
    fi
    china_cron_install
    /etc/init.d/netmanager-china enable 2>/dev/null
    info "中国IPv4访问限制已开启（仅中国大陆IPv4可访问已开放端口）"
}

cmd_china_disable() {
    load_config
    china_clear_kernel
    uci set netmanager.settings.china_filter_enable='0'
    uci commit netmanager
    china_cron_remove
    info "中国IPv4访问限制已关闭（境外IPv4可恢复访问）"
}

cmd_china_update() {
    load_config
    if ! china_download; then
        error "更新失败：下载未成功，保留旧列表"
        exit 1
    fi
    if [ "$(china_get_enable)" = "1" ]; then
        china_apply_rules
    else
        info "功能未启用，仅更新了本地列表，未应用规则"
    fi
}

cmd_china_boot() {
    load_config
    [ "$(china_get_enable)" = "1" ] || return 0
    if [ ! -f "$CHINA_LIST_FILE" ]; then
        write_log "WARN" "china_filter boot: 已启用但本地列表不存在，跳过重应用"
        return 0
    fi
    china_apply_rules >/dev/null 2>&1
    write_log "INFO" "china_filter boot: 已重新应用规则"
}

cmd_china_filter() {
    local sub="${1:-status}"
    shift 2>/dev/null
    case "$sub" in
        status)   cmd_china_status ;;
        enable)   cmd_china_enable ;;
        disable)  cmd_china_disable ;;
        update)   cmd_china_update ;;
        set_url)  cmd_china_set_url "$@" ;;
        set_cron) cmd_china_set_cron "$@" ;;
        boot)     cmd_china_boot ;;
        *) echo "用法: netmanager china_filter status|enable|disable|update|set_url <url>|set_cron <expr>"; exit 1 ;;
    esac
}

# ========== 14. 卸载插件 ==========
# 用法: netmanager uninstall [full|keep]
#   full = 全删（后端/LuCI/CBI模型/配置/CIDR/DNS配置与脚本/init/hotplug/缓存）
#   keep = 保留 /etc/config/netmanager、/etc/netmanager/ 与 /etc/config/dnssettings，其余全删
# 卸载后由后台子进程延迟2秒自删 /usr/sbin/netmanager 并重启 uhttpd（让本次响应先完整返回）
cmd_uninstall() {
    local mode="${1:-full}"
    local keep_config=0
    [ "$mode" = "keep" ] && keep_config=1

    info "开始卸载网络管理插件 (mode=$mode)..."
    write_log "INFO" "uninstall: 开始卸载 (mode=$mode keep_config=$keep_config)"

    # 1. 先关闭中国IPv4过滤：清nft规则 + 移除cron + 删表
    echo "[1/8] 关闭中国IPv4过滤（清理nft规则、移除cron）..."
    cmd_china_disable >/dev/null 2>&1
    nft delete table inet netmanager 2>/dev/null
    crontab -l 2>/dev/null | grep -v 'netmanager china_filter' | crontab - 2>/dev/null

    # 2. 停止并禁用开机自启
    echo "[2/8] 停止并禁用 init 服务..."
    /etc/init.d/netmanager-china stop 2>/dev/null
    /etc/init.d/netmanager-china disable 2>/dev/null

    # 3. 删除 init / hotplug 脚本与 DNS 管理脚本
    echo "[3/8] 删除 init/hotplug 脚本与 DNS 管理脚本..."
    rm -f /etc/init.d/netmanager-china
    rm -f /etc/hotplug.d/iface/95-netmanager-china
    rm -f /usr/sbin/dnssettings-apply.sh
    rm -f /usr/sbin/dnssettings-backup.sh

    # 4. 删除 LuCI 控制器、CBI 模型与视图页面
    echo "[4/8] 删除 LuCI 控制器/CBI模型/视图页面..."
    rm -f /usr/lib/lua/luci/controller/netmanager.lua
    rm -rf /usr/lib/lua/luci/model/cbi/netmanager
    rm -rf /usr/lib/lua/luci/view/netmanager

    # 5. 删除配置与CIDR列表（保留模式下跳过）
    echo "[5/8] 删除配置与CIDR列表..."
    if [ "$keep_config" = "1" ]; then
        echo "  (保留模式：保留 /etc/config/netmanager、/etc/netmanager/ 与 /etc/config/dnssettings)"
    else
        rm -f /etc/config/netmanager
        rm -rf /etc/netmanager
        rm -f /etc/config/dnssettings
    fi

    # 6. 清理临时文件与缓存
    echo "[6/8] 清理临时文件与缓存..."
    rm -f /tmp/.netmanager_nft_dstnat 2>/dev/null
    rm -rf /tmp/netmanager 2>/dev/null
    rm -rf /tmp/netmanager_upload 2>/dev/null
    rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null

    # 7. 输出卸载完成摘要
    echo "[7/8] 卸载完成。"
    echo ""
    echo "===UNINSTALL_DONE==="
    echo "已删除："
    echo "  - /usr/lib/lua/luci/controller/netmanager.lua"
    echo "  - /usr/lib/lua/luci/model/cbi/netmanager/ (DNS设置与静态IPv6 CBI模型)"
    echo "  - /usr/lib/lua/luci/view/netmanager/ (全部视图)"
    echo "  - /etc/init.d/netmanager-china"
    echo "  - /etc/hotplug.d/iface/95-netmanager-china"
    echo "  - /usr/sbin/dnssettings-apply.sh /usr/sbin/dnssettings-backup.sh"
    if [ "$keep_config" = "1" ]; then
        echo "  - (保留) /etc/config/netmanager"
        echo "  - (保留) /etc/netmanager/"
        echo "  - (保留) /etc/config/dnssettings"
    else
        echo "  - /etc/config/netmanager"
        echo "  - /etc/netmanager/"
        echo "  - /etc/config/dnssettings"
    fi
    echo "  - nft 表 inet netmanager（中国IPv4过滤规则）"
    echo "  - crontab 中国IPv4过滤计划任务"
    echo "  - /tmp/netmanager* 临时文件与缓存"
    echo ""
    echo "用户在 /etc/config/firewall 中的端口转发与防火墙规则不受影响，保留不动。"
    write_log "INFO" "uninstall: 文件清理完成，2秒后自删后端脚本并重启uhttpd"

    # 8. 后台延迟2秒：删除自身 + 重启uhttpd（确保本次响应能完整返回浏览器）
    echo "[8/8] 2秒后将自动删除后端脚本 /usr/sbin/netmanager 并重启 uhttpd..."
    (
        sleep 2
        rm -f /usr/sbin/netmanager
        /etc/init.d/uhttpd restart >/dev/null 2>&1
        rm -rf /tmp/luci-indexcache /tmp/luci-modulecache /tmp/luci-sessions 2>/dev/null
    ) >/dev/null 2>&1 &
}

# ========== 主入口 ==========
usage() {
    echo "网络管理插件"
    echo ""
    echo "用法: netmanager <命令> [参数]"
    echo ""
    echo "系统: overview | version | settings"
    echo "端口转发: port_list | port_add | port_del | port_edit | set_default_target"
    echo "防火墙规则: rule_list | rule_add | rule_del | rule_edit"
    echo "日志: ssh_log [行数] | access_log [端口] [行数] | log_set 0/1 | log_get [行数] | log_clear"
    echo "操作: restart | reload"
    echo "备份: backup | backup_list | backup_restore <文件> | backup_delete <文件>"
    echo "插件: upload_file <文件名> <b64文件> | plugin_update <文件> | plugin_version <文件> | cleanup_uploads"
    echo "在线更新: update_check | update_apply | set_update_mirror <url|''>"
    echo "中国IPv4过滤: china_filter status | enable | disable | update | set_url <url> | set_cron <expr>"
    echo "卸载: uninstall [full|keep]   # full=全删(默认) keep=保留配置与备份"
}

case "$1" in
    overview)           cmd_overview ;;
    version)            cmd_version ;;
    settings)           cmd_settings ;;
    port_list)          cmd_port_list ;;
    port_add)           shift; cmd_port_add "$@" ;;
    port_del)           shift; cmd_port_del "$@" ;;
    port_edit)          shift; cmd_port_edit "$@" ;;
    set_default_target) shift; cmd_set_default_target "$@" ;;
    rule_list)          cmd_rule_list ;;
    rule_add)           shift; cmd_rule_add "$@" ;;
    rule_del)           shift; cmd_rule_del "$@" ;;
    rule_edit)          shift; cmd_rule_edit "$@" ;;
    ssh_log)            shift; cmd_ssh_log "$@" ;;
    access_log)         shift; cmd_access_log "$@" ;;
    log_set)            shift; cmd_log_set "$@" ;;
    log_get)            shift; cmd_log_get "$@" ;;
    log_clear)          cmd_log_clear ;;
    restart)            cmd_restart ;;
    reload)             cmd_reload ;;
    backup)             cmd_backup ;;
    backup_list)        cmd_backup_list ;;
    backup_restore)     shift; cmd_backup_restore "$@" ;;
    backup_delete)      shift; cmd_backup_delete "$@" ;;
    upload_file)        shift; cmd_upload_file "$@" ;;
    plugin_update)      shift; cmd_plugin_update "$@" ;;
    plugin_version)     shift; cmd_plugin_version "$@" ;;
    cleanup_uploads)    cmd_cleanup_uploads ;;
    update_check)       cmd_update_check ;;
    update_apply)       cmd_update_apply ;;
    set_update_mirror)  shift; cmd_set_update_mirror "$@" ;;
    china_filter)       shift; cmd_china_filter "$@" ;;
    uninstall)          shift; cmd_uninstall "$@" ;;
    *)                  usage ;;
esac
```

### 5.2 files/usr/sbin/dnssettings-apply.sh

- **用途**：DNS 应用脚本：把 /etc/config/dnssettings 写入 network/dhcp/dnsmasq 并重载服务（v1.4.5 重写）
- **规模**：224 行
- **维护要点**：v1.4.5 重写：空值断网防护 / 应用前自动备份 / list 字段正确写法 / network reload 化。已知待修：L145 dhcp_option 单值写法应 delete+add_list；L68/L97 WAN 接口名硬编码 network.wan/wan6；L120-132 PPPoE 双栈 fallback 未去重即 add_list

```bash
#!/bin/sh
# ============================================================
# DNS设置插件 - 应用配置脚本 (v1.4.5)
# 读取 /etc/config/dnssettings，写入系统 network/dhcp 配置并重载服务
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
if uci get network.wan >/dev/null 2>&1; then
    if [ "$WAN_PEERDNS" = "1" ]; then
        uci set network.wan.peerdns='1'
        uci delete network.wan.dns 2>/dev/null
        log "WAN IPv4: 使用运营商下发 DNS"
    else
        # 【防护】自定义模式必须至少提供一个 DNS，否则保持现状防止断网
        WAN_V4_DNS=""
        [ -n "$WAN_DNS1_V4" ] && WAN_V4_DNS="$WAN_DNS1_V4"
        [ -n "$WAN_DNS2_V4" ] && WAN_V4_DNS="$WAN_V4_DNS $WAN_DNS2_V4"
        if [ -z "$WAN_V4_DNS" ]; then
            log "WARN: WAN IPv4 自定义 DNS 为空，跳过该接口（保持现状，防止断网）"
        else
            uci set network.wan.peerdns='0'
            # list 字段：先清残留，再逐个 add_list（uci set 单元素是错误写法）
            uci delete network.wan.dns 2>/dev/null
            for dns in $WAN_V4_DNS; do
                uci add_list network.wan.dns="$dns"
            done
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
        WAN_V6_DNS=""
        [ -n "$WAN_DNS1_V6" ] && WAN_V6_DNS="$WAN_DNS1_V6"
        [ -n "$WAN_DNS2_V6" ] && WAN_V6_DNS="$WAN_V6_DNS $WAN_DNS2_V6"
        if [ -z "$WAN_V6_DNS" ]; then
            log "WARN: WAN6 IPv6 自定义 DNS 为空，跳过该接口（保持现状，防止断网）"
        else
            uci set network.wan6.peerdns='0'
            uci delete network.wan6.dns 2>/dev/null
            for dns in $WAN_V6_DNS; do
                uci add_list network.wan6.dns="$dns"
            done
            log "WAN6 IPv6: $WAN_V6_DNS"
        fi
    fi
else
    log "WARN: 未找到 network.wan6 接口"
    # PPPoE 双栈：IPv6 DNS 可并入 wan 接口的 dns list（netifd 自动区分协议）
    if uci get network.wan >/dev/null 2>&1 && [ "$WAN_PEERDNS" != "1" ]; then
        WAN_V6_DNS=""
        [ -n "$WAN_DNS1_V6" ] && WAN_V6_DNS="$WAN_DNS1_V6"
        [ -n "$WAN_DNS2_V6" ] && WAN_V6_DNS="$WAN_V6_DNS $WAN_DNS2_V6"
        if [ -n "$WAN_V6_DNS" ]; then
            for dns in $WAN_V6_DNS; do
                uci add_list network.wan.dns="$dns"
            done
            log "WAN IPv6(双栈并入 wan.dns): $WAN_V6_DNS"
        else
            log "（IPv6 自定义 DNS 为空，不并入 wan）"
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
    if [ "$LAN_V4_OPTION" = "6" ]; then
        log "WARN: 勾选强制下发但 LAN IPv4 DNS 为空，跳过（保持现状，防止设备断解析）"
    else
        uci set dhcp.lan.dhcp_option="$LAN_V4_OPTION"
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
```

### 5.3 files/usr/sbin/dnssettings-backup.sh

- **用途**：DNS 备份脚本：独立备份 network/dhcp/dnssettings 到 /root/backup/
- **规模**：27 行
- **维护要点**：逻辑简单，注意保持与 apply 脚本一致的保留 5 份自动备份策略

```bash
#!/bin/sh
# ============================================================
# DNS设置插件 - 备份当前系统配置
# 备份 /etc/config/ 下的 network 和 dhcp 配置
# ============================================================

BACKUP_DIR="/root/backup"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$BACKUP_DIR/dnssettings-system-backup-$TIMESTAMP.tar.gz"

mkdir -p "$BACKUP_DIR"

# 备份 network 和 dhcp 配置（DNS 相关的核心配置）
tar -czf "$BACKUP_FILE" \
    /etc/config/network \
    /etc/config/dhcp \
    /etc/config/dnssettings 2>/dev/null

if [ $? -eq 0 ]; then
    echo "备份成功: $BACKUP_FILE"
    logger -t dnssettings "系统配置已备份到 $BACKUP_FILE"
    exit 0
else
    echo "备份失败"
    logger -t dnssettings "ERROR: 系统配置备份失败"
    exit 1
fi
```

### 5.4 files/usr/lib/lua/luci/controller/netmanager.lua

- **用途**：LuCI 控制器：注册全部页面路由 + API 分发（action 到后端命令桥接）+ multipart 上传处理
- **规模**：365 行
- **维护要点**：api_handler 强制 POST（约 L115）；shell_escape 约 L56-64（所有拼命令参数必经）；L20-21 dns_apply/dns_backup 仍为 GET 路由（v1.4.6 待修 POST 化）；L85/L294 上传临时文件 .b64_<秒级时间戳> 同秒冲突待修；arg() 在 4 处重复定义待提取

```lua
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
    -- DNS 动作：应用配置 / 备份系统配置（由 DNS 页面按钮跳转调用）
    entry({"admin", "netmanager", "dns_apply"}, call("action_dns_apply"), nil)
    entry({"admin", "netmanager", "dns_backup"}, call("action_dns_backup"), nil)
end

-- ============================================================
-- DNS 设置：应用配置
-- 读取 /etc/config/dnssettings，写入 network/dhcp 并重载网络/dnsmasq/odhcpd
-- v1.4.5：用 exec 捕获脚本完整输出回传（含 WARN 空值防护提示）
-- ============================================================
function action_dns_apply()
    -- ucode版LuCI的exec在无输出时可能返回nil，用 or "" 兜底
    local out = luci.sys.exec("/usr/sbin/dnssettings-apply.sh 2>&1") or ""
    luci.http.prepare_content("text/plain; charset=utf-8")
    -- 通过输出内容判断成败（脚本致命错误时含 ERROR）
    if out:match("ERROR:") then
        luci.http.write("应用失败，详细输出：\n" .. out)
    else
        luci.http.write("DNS配置已应用，详细输出：\n" .. out .. "\n提示: 若有 WARN 行为空值防护跳过项，请补全对应 DNS 后重新应用\n")
    end
end

-- ============================================================
-- DNS 设置：备份当前系统 network/dhcp 配置到 /root/backup/
-- v1.4.5：同样捕获完整输出回传
-- ============================================================
function action_dns_backup()
    local out = luci.sys.exec("/usr/sbin/dnssettings-backup.sh 2>&1") or ""
    luci.http.prepare_content("text/plain; charset=utf-8")
    if out:match("备份失败") or out == "" then
        luci.http.write("备份失败，详细输出：\n" .. out)
    else
        luci.http.write("配置已备份，详细输出：\n" .. out)
    end
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

-- ============================================================
-- LuCI multipart 文件上传：必须在首次 formvalue() 之前设置文件处理器
-- 否则 formvalue() 解析 multipart 时不会保存上传的文件内容
-- ============================================================
local uploaded_tmp_file = nil
local uploaded_file_size = 0

local function setup_upload_handler()
    local upload_dir = "/tmp/netmanager_upload"
    luci.sys.call("mkdir -p " .. upload_dir)
    uploaded_tmp_file = upload_dir .. "/plugin_update_" .. os.time() .. ".tar.gz"
    uploaded_file_size = 0
    
    local fout = nil
    luci.http.setfilehandler(function(meta, chunk, eof)
        -- meta: {name=表单字段名, file=原始文件名}
        if not meta or not meta.name then return end
        -- 只处理 plugin_file 字段
        if meta.name ~= "plugin_file" then return end
        
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

    -- 【关键】先设置文件上传处理器，再读任何formvalue（包括action）
    setup_upload_handler()
    
    local action = luci.http.formvalue("action") or ""
    local result = ""
    local cmd = ""

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
        local function arg(v)
            if v == "" then return "''" end
            return shell_escape(v)
        end
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
        local function arg(v)
            if v == "" then return "''" end
            return shell_escape(v)
        end
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
        local function arg(v)
            if v == "" then return "''" end
            return shell_escape(v)
        end
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
        local function arg(v)
            if v == "" then return "''" end
            return shell_escape(v)
        end
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
            local b64file = upload_dir .. "/.b64_" .. os.time()
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
    else
        result = '{"error":"unknown action"}'
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
```

### 5.5 files/usr/lib/lua/luci/model/cbi/netmanager/dns_settings.lua

- **用途**：DNS 设置 CBI 模型：Map 绑定 /etc/config/dnssettings（wan/lan/dnsmasq 三节 + 应用/备份按钮）
- **规模**：125 行
- **维护要点**：forward_v4/forward_v6 为 DynamicList（L93-101）；L108-120 apply/backup 按钮通过 redirect 触发 GET 路由（v1.4.6 待修 POST 化）；v1.4.6 已注入 cbi_nav 导航模板（L14-16）

```lua
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
-- 第四部分：操作按钮（通过自定义 HTML 模板注入）
-- ============================================================
s = m:section(NamedSection, "actions", "actions", translate("操作"))

o = s:option(Button, "_apply", translate("应用配置"))
o.inputtitle = translate("应用配置")
o.inputstyle = "apply"
o.write = function()
    luci.http.redirect(luci.dispatcher.build_url("admin", "netmanager", "dns_apply"))
end

o = s:option(Button, "_backup", translate("备份当前系统配置"))
o.inputtitle = translate("备份配置")
o.inputstyle = "save"
o.write = function()
    luci.http.redirect(luci.dispatcher.build_url("admin", "netmanager", "dns_backup"))
end

return m
```

### 5.6 files/usr/lib/lua/luci/model/cbi/netmanager/dns_staticv6.lua

- **用途**：静态 IPv6 分配 CBI 模型：绑定 dhcp.host + 在线客户端速览（4 数据源交叉）+ 冲突检测
- **规模**：489 行
- **维护要点**：L32-166 get_online_devices 四数据源（dnsmasq 租约/ARP/odhcpd 租约/NDP）；v1.4.6 修复：L45-54 first_opt 用 foreach 替代 get_first（ucode 桥无此方法）；L171-216 merge_duplicate_hosts；L221 页面 GET 加载即执行 merge+commit（v1.4.6 待修）；L290 已注入 cbi_nav；L293/L308 on_before_commit/on_after_commit；L469-481 DUID 校验 4-130 hex

```lua
-- 静态 IP / IPv6 分配 - v1.4.4
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

-- v1.4.6 修复：CBI 页面缺少页内导航（从自绘页面进入后页签消失），注入导航模板
m:append(Template("netmanager/cbi_nav"))

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
```

### 5.7 files/usr/lib/lua/luci/view/netmanager/common_head.htm

- **用途**：全部视图公共头：CSS 样式 + 公共 JS（escapeHtml / apiFetch / withBusy）
- **规模**：156 行
- **维护要点**：L74-155 公共 JS 区。apiFetch 带超时与会话过期处理，但目前仅 ssh_log 使用（v1.4.6 统一）；withBusy 为死代码待启用或删除；L75 附近版本注释是版本号登记处之一

```html
<style>
/* 网络管理 - 简洁风格 v1.1 */
.netmanager-container { max-width: 1200px; margin: 0 auto; padding: 16px; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", sans-serif; color: #1f2937; }
.netmanager-header { display: flex; justify-content: space-between; align-items: center; padding: 14px 20px; background: #fff; border-radius: 8px; margin-bottom: 12px; box-shadow: 0 1px 2px rgba(0,0,0,0.06); border: 1px solid #e5e7eb; }
.netmanager-header h1 { margin: 0; font-size: 18px; font-weight: 600; color: #111827; }
.netmanager-author { font-size: 12px; color: #9ca3af; }
.netmanager-nav { display: flex; gap: 2px; background: #fff; padding: 6px; border-radius: 8px; margin-bottom: 12px; box-shadow: 0 1px 2px rgba(0,0,0,0.06); border: 1px solid #e5e7eb; flex-wrap: wrap; }
.netmanager-nav a { padding: 7px 14px; text-decoration: none; color: #6b7280; border-radius: 6px; font-size: 13px; transition: all 0.15s; }
.netmanager-nav a:hover { background: #f3f4f6; color: #111827; }
.netmanager-nav a.active { background: #2563eb; color: #fff; }
.netmanager-content { background: #fff; border-radius: 8px; padding: 20px; box-shadow: 0 1px 2px rgba(0,0,0,0.06); border: 1px solid #e5e7eb; }
.netmanager-content h2 { margin: 0 0 16px 0; font-size: 16px; font-weight: 600; color: #111827; padding-bottom: 12px; border-bottom: 1px solid #f3f4f6; }
.netmanager-content h3 { margin: 20px 0 10px 0; font-size: 14px; font-weight: 600; color: #374151; }
/* 统计卡片 */
.netmanager-cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px; margin-bottom: 20px; }
.netmanager-card { background: #f9fafb; border-radius: 8px; padding: 14px; text-align: center; border: 1px solid #e5e7eb; }
.netmanager-card .card-icon { font-size: 20px; margin-bottom: 4px; }
.netmanager-card .card-label { font-size: 11px; color: #9ca3af; margin-bottom: 4px; }
.netmanager-card .card-value { font-size: 22px; font-weight: 700; color: #111827; }
.netmanager-card .card-value.green { color: #10b981; }
.netmanager-card .card-value.red { color: #ef4444; }
.netmanager-card .card-value.orange { color: #f59e0b; }
.netmanager-card .card-value.blue { color: #2563eb; }
/* 表格 */
.netmanager-table { width: 100%; border-collapse: collapse; font-size: 13px; }
.netmanager-table th { background: #f9fafb; padding: 9px 12px; text-align: left; font-weight: 600; color: #6b7280; border-bottom: 1px solid #e5e7eb; font-size: 12px; }
.netmanager-table td { padding: 9px 12px; border-bottom: 1px solid #f3f4f6; color: #374151; }
.netmanager-table tr:hover td { background: #f9fafb; }
/* 按钮 */
.btn { padding: 6px 14px; border: none; border-radius: 6px; font-size: 13px; cursor: pointer; transition: opacity 0.15s; text-decoration: none; display: inline-block; }
.btn:hover { opacity: 0.85; }
.btn-primary { background: #2563eb; color: #fff; }
.btn-success { background: #10b981; color: #fff; }
.btn-danger { background: #ef4444; color: #fff; }
.btn-warning { background: #f59e0b; color: #fff; }
.btn-secondary { background: #6b7280; color: #fff; }
.btn-sm { padding: 4px 10px; font-size: 12px; }
/* 表单 */
.netmanager-form { background: #f9fafb; padding: 14px; border-radius: 8px; margin-bottom: 16px; border: 1px solid #e5e7eb; }
.netmanager-form label { display: inline-block; font-size: 12px; color: #6b7280; margin-right: 6px; font-weight: 500; }
.netmanager-form input, .netmanager-form select { padding: 5px 9px; border: 1px solid #d1d5db; border-radius: 5px; font-size: 13px; margin-right: 10px; margin-bottom: 6px; background: #fff; }
.netmanager-form input:focus, .netmanager-form select:focus { outline: none; border-color: #2563eb; }
/* 日志 */
.netmanager-log { background: #1f2937; color: #d1d5db; padding: 12px; border-radius: 6px; font-family: "Consolas", "Monaco", "Courier New", monospace; font-size: 12px; line-height: 1.9; max-height: 450px; overflow-y: auto; }
.netmanager-log .log-success { color: #34d399; }
.netmanager-log .log-fail { color: #f87171; }
.netmanager-log .log-time { color: #9ca3af; }
.netmanager-log .log-ip { color: #60a5fa; }
/* 状态标签 */
.badge { display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 11px; font-weight: 600; }
.badge-green { background: #d1fae5; color: #059669; }
.badge-red { background: #fee2e2; color: #dc2626; }
.badge-gray { background: #f3f4f6; color: #6b7280; }
.badge-blue { background: #dbeafe; color: #2563eb; }
.badge-orange { background: #fef3c7; color: #d97706; }
.badge-purple { background: #ede9fe; color: #7c3aed; }
/* 底部 */
.footer-sign { text-align: center; padding: 14px; color: #d1d5db; font-size: 11px; margin-top: 12px; }
/* 空状态 */
.empty-state { text-align: center; padding: 24px; color: #9ca3af; font-size: 13px; }
/* 工具栏 */
.netmanager-toolbar { display: flex; gap: 8px; align-items: center; margin-bottom: 14px; flex-wrap: wrap; }
.netmanager-toolbar select, .netmanager-toolbar input { padding: 5px 9px; border: 1px solid #d1d5db; border-radius: 5px; font-size: 13px; background: #fff; }
/* 结果区 */
.result-pre { background: #1f2937; color: #d1d5db; padding: 10px; border-radius: 6px; overflow-x: auto; font-size: 12px; line-height: 1.6; margin-top: 10px; }
.netmanager-result { margin-top: 10px; }
/* 提示文字 */
.text-muted { color: #9ca3af; font-size: 12px; }
.text-success { color: #10b981; }
.text-danger { color: #ef4444; }
.text-warning { color: #f59e0b; }
.text-info { color: #2563eb; }
</style>
<script>
/* ===== 公共 JS（v1.4.5）：HTML转义 + API 调用封装 =====
   背景：命令输出（含用户可控的文件名/用户名/日志内容）此前直接拼 innerHTML，
   构成存储型 XSS；统一走本封装消除注入面。 */

/* HTML 转义：任何要写入 innerHTML 的动态内容必须先过此函数 */
function escapeHtml(s) {
	if (s === null || s === undefined) return '';
	return String(s).replace(/[&<>"']/g, function (c) {
		switch (c) {
			case '&': return '&amp;';
			case '<': return '&lt;';
			case '>': return '&gt;';
			case '"': return '&quot;';
			case "'": return '&#39;';
		}
	});
}

/* 将命令输出安全渲染到结果容器（自动转义，带 [CMD] 行灰色样式）
   el: 结果容器 DOM；data: 后端返回的纯文本 */
function showResult(el, data) {
	if (!el) return;
	if (typeof data !== 'string') data = String(data == null ? '' : data);
	var lines = data.split('\n').map(function (l) {
		var e = escapeHtml(l);
		return (/^\[CMD\]/.test(l)) ? '<span style="color:#9ca3af">' + e + '</span>' : e;
	});
	el.innerHTML = '<pre class="result-pre">' + lines.join('\n') + '</pre>';
}

/* API 调用封装：POST + 超时控制 + 错误提示
   action: API 动作名；params: 参数对象；opts: {timeout, parseFn}
   返回 Promise<response 文本>；失败时 reject Error（message 已可读） */
function apiFetch(action, params, opts) {
	opts = opts || {};
	params = params || {};
	var body = new URLSearchParams();
	body.set('action', action);
	for (var k in params) { if (params.hasOwnProperty(k)) body.set(k, params[k]); }

	var ctrl = new AbortController();
	var timer = setTimeout(function () { ctrl.abort(); }, opts.timeout || 30000);

	// 与各视图一致：用 LuCI dispatcher 生成 API 绝对地址（避免依赖 REQUEST_URI 推导）
	var API_URL = '<%=luci.dispatcher.build_url("admin/netmanager/api")%>';
	return fetch(API_URL, {
		method: 'POST',
		headers: { 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8' },
		body: body.toString(),
		signal: ctrl.signal,
		credentials: 'same-origin'
	}).then(function (res) {
		clearTimeout(timer);
		if (res.redirected && /\/login\.html|\/admin\/login/.test(res.url)) {
			throw new Error('会话已过期，请刷新页面重新登录');
		}
		if (!res.ok) throw new Error('服务器响应异常: HTTP ' + res.status);
		return res.text();
	}).catch(function (err) {
		clearTimeout(timer);
		if (err.name === 'AbortError') throw new Error('请求超时，请稍后重试');
		throw err;
	});
}

/* 按钮防抖：执行期间禁用按钮，防止重复提交
   用法: withBusy(btn, function(){ return fetch...; }) */
function withBusy(btn, fn) {
	if (!btn) { return Promise.resolve().then(fn); }
	if (btn.disabled) { return Promise.resolve(); }
	btn.disabled = true;
	btn.style.opacity = '0.6';
	var restore = function () {
		btn.disabled = false;
		btn.style.opacity = '';
	};
	return Promise.resolve().then(fn).then(
		function (v) { restore(); return v; },
		function (e) { restore(); throw e; }
	);
}
</script>
```

### 5.8 files/usr/lib/lua/luci/view/netmanager/nav.htm

- **用途**：页内导航条：防火墙 6 页 + DNS 设置 / 静态 IPv6 两个 CBI 入口
- **规模**：10 行
- **维护要点**：与 controller 菜单双维护：新增页面需两处同步修改

```html
<div class="netmanager-nav">
    <a href="<%=luci.dispatcher.build_url("admin/netmanager/overview")%>" class="<% if luci.dispatcher.context.requestpath[3] == 'overview' then %>active<% end %>">📊 系统概览</a>
    <a href="<%=luci.dispatcher.build_url("admin/netmanager/port_forward")%>" class="<% if luci.dispatcher.context.requestpath[3] == 'port_forward' then %>active<% end %>">🔄 端口转发</a>
    <a href="<%=luci.dispatcher.build_url("admin/netmanager/firewall_rules")%>" class="<% if luci.dispatcher.context.requestpath[3] == 'firewall_rules' then %>active<% end %>">📋 规则管理</a>
    <a href="<%=luci.dispatcher.build_url("admin/netmanager/ssh_log")%>" class="<% if luci.dispatcher.context.requestpath[3] == 'ssh_log' then %>active<% end %>">🔐 SSH登录日志</a>
    <a href="<%=luci.dispatcher.build_url("admin/netmanager/access_log")%>" class="<% if luci.dispatcher.context.requestpath[3] == 'access_log' then %>active<% end %>">🌐 端口访问日志</a>
    <a href="<%=luci.dispatcher.build_url("admin/netmanager/dns")%>" class="<% if luci.dispatcher.context.requestpath[3] == 'dns' then %>active<% end %>">🧭 DNS设置</a>
    <a href="<%=luci.dispatcher.build_url("admin/netmanager/dns_staticv6")%>" class="<% if luci.dispatcher.context.requestpath[3] == 'dns_staticv6' then %>active<% end %>">📮 静态IPv6分配</a>
    <a href="<%=luci.dispatcher.build_url("admin/netmanager/settings")%>" class="<% if luci.dispatcher.context.requestpath[3] == 'settings' then %>active<% end %>">⚙️ 设置</a>
</div>
```

### 5.9 files/usr/lib/lua/luci/view/netmanager/cbi_nav.htm

- **用途**：CBI 页面专用导航条（v1.4.6 新增）：自带内联样式，由 dns_settings / dns_staticv6 以 Template 节点注入，修复 CBI 页页签消失
- **规模**：28 行
- **维护要点**：CBI 页面专用导航（v1.4.6 新增修复 bug2）：自带内联样式（CBI 页不加载 common_head）；active 判断 requestpath[3] 带 nil 防护

```html
<%--
    netmanager/cbi_nav.htm - CBI 页面专用页内导航条
    用途：DNS设置 / 静态IPv6分配 两个 CBI 表单页面无自绘视图的 nav.htm 页内导航，
         从自绘页面进入后页签消失（bug2），本模板以 CBI Template 节点注入补齐。
    特点：自带内联样式（CBI 页面不加载 common_head.htm，不能依赖外部样式类）；
         active 判断与 nav.htm 一致（requestpath[3]）。
--%>
<%
local path = luci.dispatcher.context.requestpath
local cur = (type(path) == "table") and (path[3] or "") or ""
local function url(...) return luci.dispatcher.build_url("admin", "netmanager", ...) end
local function cls(id) return (cur == id) and ' class="active"' or '' end
%>
<style>
.netmanager-nav { display: flex; gap: 2px; background: #fff; padding: 6px; border-radius: 8px; margin: 0 0 14px 0; box-shadow: 0 1px 2px rgba(0,0,0,0.06); border: 1px solid #e5e7eb; flex-wrap: wrap; }
.netmanager-nav a { padding: 7px 14px; text-decoration: none; color: #6b7280; border-radius: 6px; font-size: 13px; transition: all 0.15s; }
.netmanager-nav a:hover { background: #f3f4f6; color: #111827; }
.netmanager-nav a.active { background: #2563eb; color: #fff; }
</style>
<div class="netmanager-nav">
    <a href="<%=url('overview')%>"<%=cls('overview')%>>📊 系统概览</a>
    <a href="<%=url('port_forward')%>"<%=cls('port_forward')%>>🔄 端口转发</a>
    <a href="<%=url('firewall_rules')%>"<%=cls('firewall_rules')%>>📋 规则管理</a>
    <a href="<%=url('ssh_log')%>"<%=cls('ssh_log')%>>🔐 SSH登录日志</a>
    <a href="<%=url('access_log')%>"<%=cls('access_log')%>>🌐 端口访问日志</a>
    <a href="<%=url('dns')%>"<%=cls('dns')%>>🧭 DNS设置</a>
    <a href="<%=url('dns_staticv6')%>"<%=cls('dns_staticv6')%>>📮 静态IPv6分配</a>
    <a href="<%=url('settings')%>"<%=cls('settings')%>>⚙️ 设置</a>
</div>
```

### 5.10 files/usr/lib/lua/luci/view/netmanager/overview.htm

- **用途**：系统概览页：防火墙状态 / 端口统计 / 网络信息 / 快捷操作
- **规模**：105 行
- **维护要点**：裸 fetch（v1.4.6 统一 apiFetch）；L142 附近 grep -v '172\.' / grep -v '192.168' 过滤会误伤公网 IP（待修）

```html
<%+header%>
<%+netmanager/common_head%>
<div class="netmanager-container">
    <div class="netmanager-header">
        <h1>网络管理</h1>
        <span class="netmanager-author">Network Manager</span>
    </div>
    <%+netmanager/nav%>
    <div class="netmanager-content">
        <h2>系统概览</h2>
        <div class="netmanager-cards">
            <div class="netmanager-card">
                <div class="card-icon">🛡️</div>
                <div class="card-label">防火墙状态</div>
                <div class="card-value" id="fw_status">--</div>
            </div>
            <div class="netmanager-card">
                <div class="card-icon">🔄</div>
                <div class="card-label">端口转发</div>
                <div class="card-value blue" id="redirect_count">--</div>
            </div>
            <div class="netmanager-card">
                <div class="card-icon">📋</div>
                <div class="card-label">防火墙规则</div>
                <div class="card-value blue" id="rule_count">--</div>
            </div>
            <div class="netmanager-card">
                <div class="card-icon">⚠️</div>
                <div class="card-label">SSH失败(24h)</div>
                <div class="card-value orange" id="ssh_fail_24h">--</div>
            </div>
            <div class="netmanager-card">
                <div class="card-icon">🔗</div>
                <div class="card-label">当前连接</div>
                <div class="card-value blue" id="conn_count">--</div>
            </div>
            <div class="netmanager-card">
                <div class="card-icon">💾</div>
                <div class="card-label">内存使用</div>
                <div class="card-value" id="mem_percent">--</div>
            </div>
        </div>
        <h3>网络信息</h3>
        <table class="netmanager-table">
            <tr><td width="30%">WAN IP</td><td id="wan_ip">--</td></tr>
            <tr><td>LAN IP</td><td id="lan_ip">--</td></tr>
            <tr><td>默认转发目标</td><td id="default_target">--</td></tr>
            <tr><td>运行时间</td><td id="uptime">--</td></tr>
            <tr><td>系统负载</td><td id="load">--</td></tr>
        </table>
        <h3>快捷操作</h3>
        <div class="netmanager-toolbar">
            <button class="btn btn-primary" onclick="fwAction('reload')">重载防火墙</button>
            <button class="btn btn-warning" onclick="fwAction('restart')">重启防火墙</button>
            <button class="btn btn-success" onclick="fwAction('backup')">备份配置</button>
            <button class="btn btn-secondary" onclick="loadOverview()">刷新数据</button>
        </div>
        <div id="action_result" class="netmanager-result"></div>
    </div>
    <div class="footer-sign">网络管理插件 v1.4.5</div>
</div>
<script>
const API_URL = '<%=luci.dispatcher.build_url("admin/netmanager/api")%>';
function loadOverview() {
    fetch(API_URL, {
        method: 'POST',
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: 'action=overview'
    }).then(r => r.text()).then(data => {
        const lines = data.split('\n');
        lines.forEach(line => {
            if (line.includes('=') && !line.includes('===')) {
                const idx = line.indexOf('=');
                const key = line.substring(0, idx);
                const value = line.substring(idx + 1);
                const el = document.getElementById(key.toLowerCase());
                if (el) {
                    if (key === 'FW_STATUS') {
                        el.innerHTML = value === 'running' ? '<span class="badge badge-green">运行中</span>' : '<span class="badge badge-red">已停止</span>';
                    } else if (key === 'MEM_PERCENT') {
                        el.textContent = value + '%';
                    } else {
                        el.textContent = value;
                    }
                }
            }
        });
    });
}
function fwAction(action) {
    const resultDiv = document.getElementById('action_result');
    resultDiv.innerHTML = '<span class="text-info">执行中...</span>';
    fetch(API_URL, {
        method: 'POST',
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: 'action=' + action
    }).then(r => r.text()).then(data => {
        resultDiv.innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(loadOverview, 2000);
    });
}
loadOverview();
setInterval(loadOverview, 30000);
</script>
<%+footer%>
```

### 5.11 files/usr/lib/lua/luci/view/netmanager/port_forward.htm

- **用途**：端口转发管理页：列表 / 添加 / 编辑 / 删除，外部端口到内部端口映射
- **规模**：181 行
- **维护要点**：L104/L110 delPort onclick 传自由文本（escapeHtml 在 onclick 属性上下文无效，v1.4.6 P1 待修，方案改数组下标传参）；L135-142 delPort；L143-157 editPort 已用数组下标（v1.4.4 修复）；L162-178 savePortEdit

```html
<%+header%>
<%+netmanager/common_head%>
<div class="netmanager-container">
    <div class="netmanager-header">
        <h1>网络管理</h1>
        <span class="netmanager-author">Network Manager</span>
    </div>
    <%+netmanager/nav%>
    <div class="netmanager-content">
        <h2>端口转发管理</h2>
        <!-- 添加表单 -->
        <div class="netmanager-form" id="add_form">
            <div style="margin-bottom:8px;"><b>添加端口转发</b></div>
            <div>
                <label>外部端口:</label>
                <input type="text" id="add_port" placeholder="如 443 或 1000-2000" style="width:120px;">
                <label>内部端口:</label>
                <input type="text" id="add_dport" placeholder="留空同外部" style="width:110px;">
                <label>协议:</label>
                <select id="add_proto">
                    <option value="tcp">TCP</option>
                    <option value="udp">UDP</option>
                    <option value="both">TCP+UDP</option>
                </select>
                <label>目标IP:</label>
                <input type="text" id="add_target" placeholder="留空用默认" style="width:130px;">
                <label>IP版本:</label>
                <select id="add_ipver">
                    <option value="both">IPv4+IPv6</option>
                    <option value="v4">仅IPv4</option>
                    <option value="v6">仅IPv6</option>
                </select>
                <button class="btn btn-success btn-sm" onclick="addPortForward()">添加</button>
            </div>
            <div class="text-muted" style="margin-top:6px;">默认目标IP: <span id="default_target_display">加载中...</span> | 可在「设置」中修改</div>
        </div>
        <!-- 编辑表单（默认隐藏） -->
        <div class="netmanager-form" id="edit_form" style="display:none;border-left:3px solid #f0ad4e;">
            <div style="margin-bottom:8px;"><b>编辑端口转发</b> <span class="text-muted" id="edit_old_info"></span></div>
            <div>
                <label>新外部端口:</label>
                <input type="text" id="edit_port" placeholder="如 443" style="width:110px;">
                <label>内部端口:</label>
                <input type="text" id="edit_dport" placeholder="留空同外部" style="width:110px;">
                <label>协议:</label>
                <select id="edit_proto">
                    <option value="tcp">TCP</option>
                    <option value="udp">UDP</option>
                    <option value="both">TCP+UDP</option>
                </select>
                <label>目标IP:</label>
                <input type="text" id="edit_target" placeholder="留空用默认" style="width:130px;">
                <label>IP版本:</label>
                <select id="edit_ipver">
                    <option value="both">IPv4+IPv6</option>
                    <option value="v4">仅IPv4</option>
                    <option value="v6">仅IPv6</option>
                </select>
                <button class="btn btn-primary btn-sm" onclick="savePortEdit()">保存修改</button>
                <button class="btn btn-secondary btn-sm" onclick="cancelPortEdit()">取消</button>
            </div>
            <input type="hidden" id="edit_old_port">
            <input type="hidden" id="edit_old_proto">
        </div>
        <h3>IPv4 端口转发 (DNAT)</h3>
        <table class="netmanager-table" id="ipv4_table">
            <thead><tr><th>名称</th><th>协议</th><th>外部端口</th><th>目标地址</th><th>命中数</th><th>状态</th><th>操作</th></tr></thead>
            <tbody><tr><td colspan="7" class="empty-state">—</td></tr></tbody>
        </table>
        <h3>IPv6 端口放行</h3>
        <table class="netmanager-table" id="ipv6_table">
            <thead><tr><th>名称</th><th>协议</th><th>端口</th><th>命中数</th><th>状态</th><th>操作</th></tr></thead>
            <tbody><tr><td colspan="6" class="empty-state">—</td></tr></tbody>
        </table>
        <div id="action_result" class="netmanager-result"></div>
    </div>
    <div class="footer-sign">网络管理插件 v1.4.5</div>
</div>
<script>
const API_URL = '<%=luci.dispatcher.build_url("admin/netmanager/api")%>';
function loadPortList() {
    fetch(API_URL, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=port_list'})
    .then(r => r.text()).then(data => {
        const sections = data.split('---');
        let ipv4Html = '', ipv6Html = '';
        let currentSection = '';
        // 【安全】行数据存入 JS 数组，onclick 只传纯数字下标，杜绝自由文本注入 onclick
        window.PORT_ROWS = [];
        sections.forEach(section => {
            if (section.includes('IPV4')) currentSection = 'ipv4';
            else if (section.includes('IPV6')) currentSection = 'ipv6';
            else if (section.includes('DEFAULT_TARGET')) {
                const m = section.match(/DEFAULT_TARGET=(.+)/);
                if (m) document.getElementById('default_target_display').textContent = m[1].trim();
            }
            const lines = section.split('\n').filter(l => l.includes('|'));
            lines.forEach(line => {
                const parts = line.split('|');
                if (currentSection === 'ipv4' && parts.length >= 8) {
                    const [idx, name, proto, sp, dip, dp, enabled, pkts] = parts;
                    const status = enabled === '1' ? '<span class="badge badge-green">启用</span>' : '<span class="badge badge-gray">禁用</span>';
                    const protoBadge = proto === 'tcp' ? '<span class="badge badge-blue">TCP</span>' : proto === 'udp' ? '<span class="badge badge-purple">UDP</span>' : '<span class="badge badge-blue">TCP+UDP</span>';
                    const rowId = window.PORT_ROWS.push({sp: sp, proto: proto, dip: dip, dp: dp}) - 1;
                    ipv4Html += `<tr><td>${escapeHtml(name)}</td><td>${protoBadge}</td><td><b>${escapeHtml(sp)}</b></td><td>${escapeHtml(dip)}:${escapeHtml(dp)}</td><td>${escapeHtml(pkts)}</td><td>${status}</td><td><button class="btn btn-primary btn-sm" onclick="editPort(${rowId})">编辑</button> <button class="btn btn-danger btn-sm" onclick="delPort('${escapeHtml(sp)}','${escapeHtml(proto)}')">删除</button></td></tr>`;
                } else if (currentSection === 'ipv6' && parts.length >= 6) {
                    const [idx, name, proto, dp, enabled, pkts] = parts;
                    const status = enabled === '1' ? '<span class="badge badge-green">启用</span>' : '<span class="badge badge-gray">禁用</span>';
                    const protoBadge = proto === 'tcp' ? '<span class="badge badge-blue">TCP</span>' : proto === 'udp' ? '<span class="badge badge-purple">UDP</span>' : '<span class="badge badge-blue">TCP+UDP</span>';
                    const rowId = window.PORT_ROWS.push({sp: dp, proto: proto, dip: '', dp: dp}) - 1;
                    ipv6Html += `<tr><td>${escapeHtml(name)}</td><td>${protoBadge}</td><td><b>${escapeHtml(dp)}</b></td><td>${escapeHtml(pkts)}</td><td>${status}</td><td><button class="btn btn-primary btn-sm" onclick="editPort(${rowId})">编辑</button> <button class="btn btn-danger btn-sm" onclick="delPort('${escapeHtml(dp)}','${escapeHtml(proto)}')">删除</button></td></tr>`;
                }
            });
        });
        document.querySelector('#ipv4_table tbody').innerHTML = ipv4Html || '<tr><td colspan="7" class="empty-state">暂无规则</td></tr>';
        document.querySelector('#ipv6_table tbody').innerHTML = ipv6Html || '<tr><td colspan="6" class="empty-state">暂无规则</td></tr>';
    });
}
function addPortForward() {
    const port = document.getElementById('add_port').value.trim();
    const dport = document.getElementById('add_dport').value.trim();
    const proto = document.getElementById('add_proto').value;
    const target = document.getElementById('add_target').value.trim();
    const ipver = document.getElementById('add_ipver').value;
    if (!port) { alert('请输入端口号'); return; }
    const body = 'action=port_add&port=' + encodeURIComponent(port) + '&dport=' + encodeURIComponent(dport) + '&proto=' + proto + '&target=' + encodeURIComponent(target) + '&ipver=' + ipver;
    fetch(API_URL, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:body})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        document.getElementById('add_port').value = '';
        document.getElementById('add_dport').value = '';
        document.getElementById('add_target').value = '';
        setTimeout(loadPortList, 400);
    });
}
function delPort(port, proto) {
    if (!confirm('确定删除端口 ' + port + '/' + proto + ' ?')) return;
    fetch(API_URL, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=port_del&port=' + encodeURIComponent(port) + '&proto=' + encodeURIComponent(proto)})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(loadPortList, 300);
    });
}
function editPort(rowId) {
    const r = window.PORT_ROWS && window.PORT_ROWS[rowId];
    if (!r) return;
    const port = r.sp, proto = r.proto, target = r.dip, dport = r.dp;
    document.getElementById('add_form').style.display = 'none';
    document.getElementById('edit_form').style.display = 'block';
    document.getElementById('edit_old_port').value = port;
    document.getElementById('edit_old_proto').value = proto;
    document.getElementById('edit_port').value = port;
    document.getElementById('edit_proto').value = proto;
    document.getElementById('edit_target').value = target || '';
    document.getElementById('edit_dport').value = dport || '';
    document.getElementById('edit_old_info').textContent = '(原: ' + port + '/' + proto + ')';
    document.getElementById('edit_form').scrollIntoView({behavior:'smooth', block:'center'});
}
function cancelPortEdit() {
    document.getElementById('edit_form').style.display = 'none';
    document.getElementById('add_form').style.display = 'block';
}
function savePortEdit() {
    const old_port = document.getElementById('edit_old_port').value;
    const old_proto = document.getElementById('edit_old_proto').value;
    const new_port = document.getElementById('edit_port').value.trim();
    const new_dport = document.getElementById('edit_dport').value.trim();
    const new_proto = document.getElementById('edit_proto').value;
    const new_target = document.getElementById('edit_target').value.trim();
    const new_ipver = document.getElementById('edit_ipver').value;
    if (!new_port) { alert('请输入新端口号'); return; }
    const body = 'action=port_edit&old_port=' + encodeURIComponent(old_port) + '&old_proto=' + old_proto + '&new_port=' + encodeURIComponent(new_port) + '&new_dport=' + encodeURIComponent(new_dport) + '&new_proto=' + new_proto + '&new_target=' + encodeURIComponent(new_target) + '&new_ipver=' + new_ipver;
    fetch(API_URL, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:body})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        cancelPortEdit();
        setTimeout(loadPortList, 300);
    });
}
loadPortList();
</script>
<%+footer%>
```

### 5.12 files/usr/lib/lua/luci/view/netmanager/firewall_rules.htm

- **用途**：防火墙规则管理页：自定义规则增删改 + 常用模板一键应用
- **规模**：229 行
- **维护要点**：L137 editRule 已改数组下标传参（v1.4.4 修复）

```html
<%+header%>
<%+netmanager/common_head%>
<div class="netmanager-container">
    <div class="netmanager-header">
        <h1>网络管理</h1>
        <span class="netmanager-author">Network Manager</span>
    </div>
    <%+netmanager/nav%>
    <div class="netmanager-content">
        <h2>防火墙规则管理</h2>
        <!-- 添加表单 -->
        <div class="netmanager-form" id="add_form">
            <div style="margin-bottom:8px;"><b>添加自定义规则</b></div>
            <div>
                <label>规则名称:</label>
                <input type="text" id="rule_name" placeholder="如 Block-SSH-WAN" style="width:150px;">
                <label>源区域:</label>
                <select id="rule_src">
                    <option value="wan">wan</option>
                    <option value="lan">lan</option>
                    <option value="">任意</option>
                </select>
                <label>目标区域:</label>
                <select id="rule_dst">
                    <option value="">本机/任意</option>
                    <option value="lan">lan</option>
                    <option value="wan">wan</option>
                </select>
            </div>
            <div style="margin-top:6px;">
                <label>协议:</label>
                <select id="rule_proto">
                    <option value="tcp">TCP</option>
                    <option value="udp">UDP</option>
                    <option value="tcpudp">TCP+UDP</option>
                    <option value="icmp">ICMP</option>
                    <option value="all">全部</option>
                </select>
                <label>目标端口:</label>
                <input type="text" id="rule_port" placeholder="如 22 或 80-90" style="width:120px;">
                <label>动作:</label>
                <select id="rule_target">
                    <option value="ACCEPT">允许</option>
                    <option value="DROP">丢弃</option>
                    <option value="REJECT">拒绝</option>
                </select>
                <label>IP版本:</label>
                <select id="rule_family">
                    <option value="any">IPv4+IPv6</option>
                    <option value="ipv4">仅IPv4</option>
                    <option value="ipv6">仅IPv6</option>
                </select>
                <button class="btn btn-success btn-sm" onclick="addRule()">添加规则</button>
            </div>
        </div>
        <!-- 编辑表单（默认隐藏） -->
        <div class="netmanager-form" id="edit_form" style="display:none;border-left:3px solid #f0ad4e;">
            <div style="margin-bottom:8px;"><b>编辑规则 #<span id="edit_idx_display"></span></b></div>
            <div>
                <label>规则名称:</label>
                <input type="text" id="edit_name" style="width:150px;">
                <label>源区域:</label>
                <select id="edit_src">
                    <option value="wan">wan</option>
                    <option value="lan">lan</option>
                    <option value="">任意</option>
                </select>
                <label>目标区域:</label>
                <select id="edit_dst">
                    <option value="">本机/任意</option>
                    <option value="lan">lan</option>
                    <option value="wan">wan</option>
                </select>
            </div>
            <div style="margin-top:6px;">
                <label>协议:</label>
                <select id="edit_proto">
                    <option value="tcp">TCP</option>
                    <option value="udp">UDP</option>
                    <option value="tcpudp">TCP+UDP</option>
                    <option value="icmp">ICMP</option>
                    <option value="all">全部</option>
                </select>
                <label>目标端口:</label>
                <input type="text" id="edit_port" placeholder="如 22 或 80-90" style="width:120px;">
                <label>动作:</label>
                <select id="edit_target">
                    <option value="ACCEPT">允许</option>
                    <option value="DROP">丢弃</option>
                    <option value="REJECT">拒绝</option>
                </select>
                <label>IP版本:</label>
                <select id="edit_family">
                    <option value="any">IPv4+IPv6</option>
                    <option value="ipv4">仅IPv4</option>
                    <option value="ipv6">仅IPv6</option>
                </select>
                <button class="btn btn-primary btn-sm" onclick="saveRuleEdit()">保存修改</button>
                <button class="btn btn-secondary btn-sm" onclick="cancelRuleEdit()">取消</button>
            </div>
            <input type="hidden" id="edit_idx">
        </div>
        <h3>当前所有规则</h3>
        <table class="netmanager-table" id="rule_table">
            <thead><tr><th>#</th><th>名称</th><th>源</th><th>目标</th><th>协议</th><th>端口</th><th>动作</th><th>IP版本</th><th>状态</th><th>操作</th></tr></thead>
            <tbody><tr><td colspan="10" class="empty-state">加载中...</td></tr></tbody>
        </table>
        <h3>常用规则模板</h3>
        <div class="netmanager-toolbar">
            <button class="btn btn-secondary btn-sm" onclick="applyTemplate('block_ssh_wan')">禁止WAN口SSH</button>
            <button class="btn btn-secondary btn-sm" onclick="applyTemplate('block_ping')">禁止Ping</button>
            <button class="btn btn-secondary btn-sm" onclick="applyTemplate('allow_web')">允许Web(80/443)</button>
            <button class="btn btn-secondary btn-sm" onclick="applyTemplate('block_rpcbind')">禁止rpcbind(111)</button>
        </div>
        <div id="action_result" class="netmanager-result"></div>
    </div>
    <div class="footer-sign">网络管理插件 v1.4.5</div>
</div>
<script>
const API_URL = '<%=luci.dispatcher.build_url("admin/netmanager/api")%>';
function loadRuleList() {
    fetch(API_URL, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=rule_list'})
    .then(r => r.text()).then(data => {
        let html = '';
        // 【安全】行数据存入 JS 数组，onclick 只传纯数字下标，杜绝 UCI 自由文本注入 onclick
        window.RULE_ROWS = [];
        const lines = data.split('\n').filter(l => l.includes('|') && !l.includes('---'));
        lines.forEach(line => {
            const parts = line.split('|');
            if (parts.length >= 9) {
                const [idx, name, src, dst, proto, port, target, fam, enabled] = parts;
                const tBadge = target === 'ACCEPT' ? '<span class="badge badge-green">ACCEPT</span>' : target === 'DROP' ? '<span class="badge badge-red">DROP</span>' : '<span class="badge badge-orange">REJECT</span>';
                const fBadge = fam === 'any' ? '全部' : escapeHtml(fam.toUpperCase());
                const status = enabled === '1' ? '<span class="badge badge-green">启用</span>' : '<span class="badge badge-gray">禁用</span>';
                const rowId = window.RULE_ROWS.length;
                window.RULE_ROWS.push({idx: idx, name: name, src: src, dst: dst, proto: proto, port: port, target: target, fam: fam});
                html += `<tr><td>${escapeHtml(idx)}</td><td><b>${escapeHtml(name)}</b></td><td>${escapeHtml(src || '-')}</td><td>${escapeHtml(dst || '-')}</td><td>${escapeHtml(proto || '-')}</td><td>${escapeHtml(port || '-')}</td><td>${tBadge}</td><td>${fBadge}</td><td>${status}</td><td><button class="btn btn-primary btn-sm" onclick="editRule(${parseInt(idx)},${rowId})">编辑</button> <button class="btn btn-danger btn-sm" onclick="delRule(${parseInt(idx)})">删除</button></td></tr>`;
            }
        });
        document.querySelector('#rule_table tbody').innerHTML = html || '<tr><td colspan="10" class="empty-state">暂无规则</td></tr>';
    });
}
function addRule() {
    const name = document.getElementById('rule_name').value.trim();
    if (!name) { alert('请输入规则名称'); return; }
    const body = new URLSearchParams({
        action:'rule_add', name:name,
        src:document.getElementById('rule_src').value,
        dst:document.getElementById('rule_dst').value,
        proto:document.getElementById('rule_proto').value,
        port:document.getElementById('rule_port').value,
        target:document.getElementById('rule_target').value,
        family:document.getElementById('rule_family').value
    });
    fetch(API_URL, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:body})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        document.getElementById('rule_name').value = '';
        document.getElementById('rule_port').value = '';
        setTimeout(loadRuleList, 1500);
    });
}
function delRule(idx) {
    if (!confirm('确定删除规则 #' + idx + ' ?')) return;
    fetch(API_URL, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=rule_del&idx=' + idx})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(loadRuleList, 1500);
    });
}
function editRule(idx, rowId) {
    const r = window.RULE_ROWS && window.RULE_ROWS[rowId];
    if (!r) return;
    document.getElementById('add_form').style.display = 'none';
    document.getElementById('edit_form').style.display = 'block';
    document.getElementById('edit_idx').value = idx;
    document.getElementById('edit_idx_display').textContent = idx;
    document.getElementById('edit_name').value = r.name;
    document.getElementById('edit_src').value = r.src || '';
    document.getElementById('edit_dst').value = r.dst || '';
    document.getElementById('edit_proto').value = r.proto || 'tcp';
    document.getElementById('edit_port').value = r.port || '';
    document.getElementById('edit_target').value = r.target || 'ACCEPT';
    document.getElementById('edit_family').value = r.fam || 'any';
    document.getElementById('edit_form').scrollIntoView({behavior:'smooth', block:'center'});
}
function cancelRuleEdit() {
    document.getElementById('edit_form').style.display = 'none';
    document.getElementById('add_form').style.display = 'block';
}
function saveRuleEdit() {
    const idx = document.getElementById('edit_idx').value;
    const body = new URLSearchParams({
        action:'rule_edit', idx:idx,
        name:document.getElementById('edit_name').value.trim(),
        src:document.getElementById('edit_src').value,
        dst:document.getElementById('edit_dst').value,
        proto:document.getElementById('edit_proto').value,
        port:document.getElementById('edit_port').value,
        target:document.getElementById('edit_target').value,
        family:document.getElementById('edit_family').value
    });
    fetch(API_URL, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:body})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        cancelRuleEdit();
        setTimeout(loadRuleList, 1500);
    });
}
function applyTemplate(type) {
    const t = {
        block_ssh_wan:['Block-SSH-WAN','wan','','tcp','22','DROP','any'],
        block_ping:['Block-Ping-WAN','wan','','icmp','','DROP','ipv4'],
        allow_web:['Allow-Web-WAN','wan','lan','tcp','80 443','ACCEPT','any'],
        block_rpcbind:['Block-rpcbind-WAN','wan','','tcpudp','111','DROP','any']
    };
    const v = t[type];
    document.getElementById('rule_name').value = v[0];
    document.getElementById('rule_src').value = v[1];
    document.getElementById('rule_dst').value = v[2];
    document.getElementById('rule_proto').value = v[3];
    document.getElementById('rule_port').value = v[4];
    document.getElementById('rule_target').value = v[5];
    document.getElementById('rule_family').value = v[6];
    alert('模板已填充，点击「添加规则」确认');
}
loadRuleList();
</script>
<%+footer%>
```

### 5.13 files/usr/lib/lua/luci/view/netmanager/ssh_log.htm

- **用途**：SSH 登录日志页：成功/失败记录 + 失败 IP Top10 + 自动刷新
- **规模**：103 行
- **维护要点**：L54 已用 apiFetch；SSH 用户名/IP 等字段写入前已转义（v1.4.4 修复存储型 XSS）

```html
<%+header%>
<%+netmanager/common_head%>
<div class="netmanager-container">
    <div class="netmanager-header">
        <h1>网络管理</h1>
        <span class="netmanager-author">Network Manager</span>
    </div>
    <%+netmanager/nav%>
    <div class="netmanager-content">
        <h2>SSH 登录日志</h2>
        <div class="netmanager-toolbar">
            <label style="font-size:13px;color:#6b7280;">显示行数:</label>
            <select id="log_limit">
                <option value="20">最近20条</option>
                <option value="50" selected>最近50条</option>
                <option value="100">最近100条</option>
                <option value="200">最近200条</option>
            </select>
            <button class="btn btn-primary btn-sm" onclick="loadSshLog()">刷新</button>
            <button class="btn btn-secondary btn-sm" onclick="toggleAuto()">自动刷新</button>
            <span id="auto_status" class="text-muted"></span>
        </div>
        <div class="netmanager-cards" style="grid-template-columns: repeat(3, 1fr);">
            <div class="netmanager-card">
                <div class="card-label">成功登录</div>
                <div class="card-value green" id="success_count">0</div>
            </div>
            <div class="netmanager-card">
                <div class="card-label">失败登录</div>
                <div class="card-value red" id="failed_count">0</div>
            </div>
            <div class="netmanager-card">
                <div class="card-label">可疑IP数</div>
                <div class="card-value orange" id="suspicious_count">0</div>
            </div>
        </div>
        <h3>失败登录IP排行 (Top 10)</h3>
        <table class="netmanager-table" id="stats_table">
            <thead><tr><th>IP地址</th><th>失败次数</th><th>风险等级</th></tr></thead>
            <tbody><tr><td colspan="3" class="empty-state">加载中...</td></tr></tbody>
        </table>
        <h3>成功登录记录</h3>
        <div class="netmanager-log" id="success_log"><div class="text-muted">加载中...</div></div>
        <h3>失败登录记录</h3>
        <div class="netmanager-log" id="failed_log"><div class="text-muted">加载中...</div></div>
    </div>
    <div class="footer-sign">网络管理插件 v1.4.5</div>
</div>
<script>
const API_URL = '<%=luci.dispatcher.build_url("admin/netmanager/api")%>';
let autoTimer = null;
function loadSshLog() {
    const limit = document.getElementById('log_limit').value;
    apiFetch('ssh_log', {limit: limit}, {timeout: 15000}).then(data => {
        // 后端输出带分节标记行（---SUCCESS--- 等），按行首标记解析，不再用 includes 模糊匹配
        let current = '';
        let successHtml = '', failedHtml = '', statsHtml = '';
        let successCount = 0, failedCount = 0;
        data.split('\n').forEach(line => {
            if (/^---[A-Z]+---$/.test(line.trim())) {
                // 分节标记行：SUCCESS / FAILED / STATS
                if (line.includes('SUCCESS')) current = 'success';
                else if (line.includes('FAILED')) current = 'failed';
                else if (line.includes('STATS')) current = 'stats';
                else current = '';
                return;
            }
            if (!current || !line.includes('|')) return;
            const parts = line.split('|');
            // 【安全】SSH用户名/IP/原因均为外部可控内容，写入前必须转义
            const t = escapeHtml(parts[0]), u = escapeHtml(parts[1]), ip = escapeHtml(parts[2]);
            if (current === 'success' && parts.length >= 3) {
                successCount++;
                successHtml += `<div><span class="log-time">[${t}]</span> <span class="log-success">成功</span> 用户:<b>${u}</b> 来自:<span class="log-ip">${ip}</span></div>`;
            } else if (current === 'failed' && parts.length >= 4) {
                failedCount++;
                failedHtml += `<div><span class="log-time">[${t}]</span> <span class="log-fail">失败</span> 用户:<b>${u}</b> 来自:<span class="log-ip">${ip}</span> 原因:${escapeHtml(parts[3])}</div>`;
            } else if (current === 'stats' && parts.length >= 2) {
                const count = parseInt(parts[1]);
                if (isNaN(count)) return;
                let risk = '<span class="badge badge-green">低</span>';
                if (count >= 10) risk = '<span class="badge badge-red">高危</span>';
                else if (count >= 5) risk = '<span class="badge badge-orange">中危</span>';
                statsHtml += `<tr><td><span class="log-ip">${ip}</span></td><td><b>${count}</b></td><td>${risk}</td></tr>`;
            }
        });
        document.getElementById('success_count').textContent = successCount;
        document.getElementById('failed_count').textContent = failedCount;
        document.getElementById('suspicious_count').textContent = statsHtml ? (statsHtml.match(/<tr>/g) || []).length : 0;
        document.querySelector('#stats_table tbody').innerHTML = statsHtml || '<tr><td colspan="3" class="empty-state">暂无失败记录</td></tr>';
        document.getElementById('success_log').innerHTML = successHtml || '<div class="text-muted">暂无成功登录记录</div>';
        document.getElementById('failed_log').innerHTML = failedHtml || '<div class="text-muted">暂无失败登录记录</div>';
    }).catch(err => {
        document.getElementById('success_log').innerHTML = `<div class="text-danger">加载失败: ${escapeHtml(err.message)}</div>`;
    });
}
function toggleAuto() {
    if (autoTimer) { clearInterval(autoTimer); autoTimer = null; document.getElementById('auto_status').textContent = '自动刷新已关闭'; }
    else { autoTimer = setInterval(loadSshLog, 10000); document.getElementById('auto_status').textContent = '自动刷新中(10s)'; }
}
loadSshLog();
</script>
<%+footer%>
```

### 5.14 files/usr/lib/lua/luci/view/netmanager/access_log.htm

- **用途**：端口访问日志页：活跃连接 / 入站出站计数 / 拦截统计
- **规模**：112 行
- **维护要点**：裸 fetch（v1.4.6 统一 apiFetch）

```html
<%+header%>
<%+netmanager/common_head%>
<div class="netmanager-container">
    <div class="netmanager-header">
        <h1>网络管理</h1>
        <span class="netmanager-author">Network Manager</span>
    </div>
    <%+netmanager/nav%>
    <div class="netmanager-content">
        <h2>端口访问日志</h2>
        <div class="netmanager-toolbar">
            <label style="font-size:13px;color:#6b7280;">筛选端口:</label>
            <input type="text" id="filter_port" placeholder="留空全部" style="width:100px;">
            <label style="font-size:13px;color:#6b7280;">条数:</label>
            <select id="access_limit">
                <option value="50">50条</option>
                <option value="100" selected>100条</option>
                <option value="200">200条</option>
            </select>
            <button class="btn btn-primary btn-sm" onclick="loadAccessLog()">刷新</button>
            <button class="btn btn-secondary btn-sm" onclick="toggleAuto()">自动刷新</button>
            <span id="auto_status" class="text-muted"></span>
        </div>
        <div class="netmanager-cards" style="grid-template-columns: repeat(4, 1fr);">
            <div class="netmanager-card">
                <div class="card-label">活跃连接</div>
                <div class="card-value blue" id="active_count">0</div>
            </div>
            <div class="netmanager-card">
                <div class="card-label">入站连接</div>
                <div class="card-value green" id="inbound_count">0</div>
            </div>
            <div class="netmanager-card">
                <div class="card-label">出站连接</div>
                <div class="card-value" id="outbound_count">0</div>
            </div>
            <div class="netmanager-card">
                <div class="card-label">累计拦截</div>
                <div class="card-value red" id="blocked_count">0</div>
            </div>
        </div>
        <h3>当前活跃连接</h3>
        <div class="netmanager-log" id="active_log"><div class="text-muted">加载中...</div></div>
        <h3>防火墙拦截统计 (按端口)</h3>
        <div class="netmanager-log" id="blocked_log"><div class="text-muted">加载中...</div></div>
    </div>
    <div class="footer-sign">网络管理插件 v1.4.5</div>
</div>
<script>
const API_URL = '<%=luci.dispatcher.build_url("admin/netmanager/api")%>';
let autoTimer = null;
const PORT_SVC = {'22':'SSH','21':'FTP','23':'Telnet','25':'SMTP','53':'DNS','80':'HTTP','110':'POP3','143':'IMAP','443':'HTTPS','445':'SMB','3306':'MySQL','3389':'RDP','5432':'PostgreSQL','6379':'Redis','8080':'HTTP-Alt','8443':'HTTPS-Alt','8888':'HTTP-Alt','21115':'RustDesk','21116':'RustDesk','21117':'RustDesk','25550':'SSH(改)','853':'DoT','51133':'Bitwarden','53000':'Joyflix','53002':'SunPanel','58013':'Music-DL'};
function loadAccessLog() {
    const port = document.getElementById('filter_port').value.trim();
    const limit = document.getElementById('access_limit').value;
    fetch(API_URL, {
        method: 'POST',
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: 'action=access_log&port=' + encodeURIComponent(port) + '&limit=' + limit
    }).then(r => r.text()).then(data => {
        const sections = data.split('---');
        let activeHtml = '', blockedHtml = '';
        let activeCount = 0, inboundCount = 0, outboundCount = 0, blockedTotal = 0;
        let current = '';
        sections.forEach(section => {
            if (section.includes('ACTIVE')) current = 'active';
            else if (section.includes('BLOCKED')) current = 'blocked';
            else if (section.includes('===END')) current = '';
            const lines = section.split('\n').filter(l => l.trim());
            lines.forEach(line => {
                // 统计行（带=号）
                if (line.includes('=') && !line.includes('|')) {
                    const idx = line.indexOf('=');
                    const k = line.substring(0, idx), v = line.substring(idx + 1);
                    if (k === 'ACTIVE_COUNT') activeCount = parseInt(v) || 0;
                    if (k === 'IN_COUNT') inboundCount = parseInt(v) || 0;
                    if (k === 'OUT_COUNT') outboundCount = parseInt(v) || 0;
                    if (k === 'BLOCK_TOTAL') blockedTotal = parseInt(v) || 0;
                    return;
                }
                // 数据行（带|）
                if (!line.includes('|')) return;
                const parts = line.split('|');
                if (current === 'active' && parts.length >= 4) {
                    const proto = parts[0], src = parts[1], dst = parts[2], state = parts[3];
                    const isInbound = !src.match(/^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.)/);
                    const dirBadge = isInbound ? '<span class="badge badge-green">入</span>' : '<span class="badge badge-blue">出</span>';
                    const protoBadge = proto === 'tcp' ? '<span class="badge badge-blue">TCP</span>' : '<span class="badge badge-purple">UDP</span>';
                    activeHtml += `<div>${protoBadge} ${dirBadge} <span class="log-ip">${escapeHtml(src)}</span> → <span class="log-ip">${escapeHtml(dst)}</span> <span style="color:#9ca3af;">[${escapeHtml(state)}]</span></div>`;
                } else if (current === 'blocked' && parts.length >= 3) {
                    const proto = parts[0], dport = parts[1], pkts = parts[2];
                    if (parseInt(pkts) > 0) {
                        blockedHtml += `<div><span class="log-fail">拦截</span> ${escapeHtml(proto.toUpperCase())} 端口 <b>${escapeHtml(dport)}</b> 累计 <b>${escapeHtml(pkts)}</b> 个包</div>`;
                    }
                }
            });
        });
        document.getElementById('active_count').textContent = activeCount;
        document.getElementById('inbound_count').textContent = inboundCount;
        document.getElementById('outbound_count').textContent = outboundCount;
        document.getElementById('blocked_count').textContent = blockedTotal;
        document.getElementById('active_log').innerHTML = activeHtml || '<div class="text-muted">暂无活跃连接</div>';
        document.getElementById('blocked_log').innerHTML = blockedHtml || '<div class="text-muted">暂无拦截记录（防火墙DROP规则计数器为0）</div>';
    });
}
function toggleAuto() {
    if (autoTimer) { clearInterval(autoTimer); autoTimer = null; document.getElementById('auto_status').textContent = '自动刷新已关闭'; }
    else { autoTimer = setInterval(loadAccessLog, 5000); document.getElementById('auto_status').textContent = '自动刷新中(5s)'; }
}
loadAccessLog();
</script>
<%+footer%>
```

### 5.15 files/usr/lib/lua/luci/view/netmanager/settings.htm

- **用途**：设置页：默认目标 / 备份恢复 / 插件更新 / 在线更新 / 中国IPv4过滤 / 运行日志 / 卸载
- **规模**：660 行
- **维护要点**：最复杂视图。L101/L202 footer 版本号（登记处）；L236-260 API_URL+loadSettings；L396-435 listBackups（L421-429 b[0] 直拼 innerHTML 未转义，v1.4.6 P1 待修）；L443-467 restoreBackup/deleteBackup；L512-555 loadChinaStatus（L535-536 lu/cnt/devs 三处未转义待修）；L564-586 saveChinaUrl/saveChinaCron；L595-622 enable/disable/updateChinaFilter；L624-655 uninstallPlugin

```html
<%+header%>
<%+netmanager/common_head%>
<div class="netmanager-container">
    <div class="netmanager-header">
        <h1>网络管理</h1>
        <span class="netmanager-author">Network Manager</span>
    </div>
    <%+netmanager/nav%>
    <div class="netmanager-content">
        <h2>插件设置</h2>
        <h3>默认转发目标</h3>
        <table class="netmanager-table">
            <tr>
                <td width="35%">默认目标IP</td>
                <td>
                    <input type="text" id="default_target" style="width:170px;" placeholder="如 192.168.31.196">
                    <button class="btn btn-primary btn-sm" onclick="saveDefaultTarget()">保存</button>
                    <span class="text-muted" style="margin-left:8px;">添加端口转发时留空目标IP将使用此地址</span>
                </td>
            </tr>
        </table>
        <h3>系统工具</h3>
        <div class="netmanager-toolbar">
            <button class="btn btn-primary btn-sm" onclick="runAction('reload')">重载防火墙</button>
            <button class="btn btn-warning btn-sm" onclick="runAction('restart')">重启防火墙</button>
            <button class="btn btn-success btn-sm" onclick="doBackup()">备份配置</button>
            <button class="btn btn-secondary btn-sm" onclick="loadSettings()">刷新</button>
        </div>

        <!-- 中国IPv4访问限制 -->
        <h3>中国IPv4访问限制</h3>
        <div class="netmanager-form" style="border-left:3px solid #f97316;">
            <div style="margin-bottom:10px;">
                <b>仅允许中国大陆 IPv4 访问已开放端口</b>
                <span class="text-muted" style="margin-left:8px;">境外IPv4新建连接将被丢弃；已建立连接/出站/局域网间转发不受影响；IPv6不在范围内</span>
            </div>
            <table class="netmanager-table" style="margin-bottom:10px;">
                <tr>
                    <td width="35%">当前状态</td>
                    <td id="china_status_cell"><span class="text-muted">加载中...</span></td>
                </tr>
                <tr>
                    <td>IP库订阅链接</td>
                    <td>
                        <input type="text" id="china_url" style="width:70%;" placeholder="以 http:// 或 https:// 开头，每行一个 CIDR 的纯文本订阅">
                        <button class="btn btn-secondary btn-sm" onclick="saveChinaUrl()">保存链接</button>
                    </td>
                </tr>
                <tr>
                    <td>更新计划</td>
                    <td>
                        <select id="china_cron_preset" onchange="onCronPresetChange()" style="padding:2px 5px;">
                            <option value="0 3 * * *">每天凌晨3点</option>
                            <option value="0 3 * * 0">每周日凌晨3点(默认)</option>
                            <option value="0 3 1 * *">每月1日凌晨3点</option>
                            <option value="0 */12 * * *">每12小时</option>
                            <option value="__custom__">自定义...</option>
                        </select>
                        <input type="text" id="china_cron_custom" placeholder="5段cron: 分 时 日 月 周" style="width:200px; display:none; margin-left:8px;">
                        <button class="btn btn-secondary btn-sm" onclick="saveChinaCron()">保存计划</button>
                        <span class="text-muted" style="margin-left:8px; font-size:12px;">仅允许 0-9 * / , - 字符</span>
                    </td>
                </tr>
                <tr>
                    <td>上次更新 / 条数</td>
                    <td id="china_update_cell"><span class="text-muted">—</span></td>
                </tr>
                <tr>
                    <td>生效WAN口 / 规则</td>
                    <td id="china_wan_cell"><span class="text-muted">—</span></td>
                </tr>
            </table>
            <div class="netmanager-toolbar">
                <button class="btn btn-success btn-sm" id="btn_china_enable" onclick="enableChinaFilter()">立即启用</button>
                <button class="btn btn-warning btn-sm" id="btn_china_disable" onclick="disableChinaFilter()">关闭</button>
                <button class="btn btn-primary btn-sm" id="btn_china_update" onclick="updateChinaFilter()">更新IP库</button>
                <button class="btn btn-secondary btn-sm" onclick="loadChinaStatus()">刷新状态</button>
            </div>
        </div>

        <!-- 备份管理 -->
        <h3>备份管理</h3>
        <div class="netmanager-form" style="border-left:3px solid #10b981;">
            <div style="margin-bottom:10px;">
                <b>配置备份</b>
                <span class="text-muted" style="margin-left:8px;">支持查看、恢复、删除历史备份</span>
            </div>
            <div class="netmanager-toolbar">
                <button class="btn btn-success btn-sm" onclick="listBackups()">刷新备份列表</button>
                <button class="btn btn-secondary btn-sm" onclick="runAction('cleanup_uploads')">清理临时文件</button>
            </div>
            <div id="backup_list" style="margin-top:10px;"></div>
        </div>

        <!-- 在线更新 -->
        <h3>在线更新</h3>
        <div class="netmanager-form" style="border-left:3px solid #10b981;">
            <table class="netmanager-table" style="margin-bottom:10px;">
                <tr>
                    <td width="30%">当前版本</td>
                    <td><b id="online_cur_version">v1.4.5</b></td>
                </tr>
                <tr>
                    <td>最新版本</td>
                    <td id="online_latest_version"><span class="text-muted">未检查（点击「检查更新」）</span></td>
                </tr>
                <tr>
                    <td>更新镜像</td>
                    <td>
                        <input type="text" id="update_mirror" placeholder="留空直连 GitHub；直连受限可填加速前缀，如 https://gh-proxy.com" style="width:65%;">
                        <button class="btn btn-secondary btn-sm" onclick="saveUpdateMirror()">保存镜像</button>
                    </td>
                </tr>
            </table>
            <div class="netmanager-toolbar">
                <button class="btn btn-primary btn-sm" id="btn_check_update" onclick="checkUpdate()">检查更新</button>
                <button class="btn btn-success btn-sm" id="btn_apply_update" onclick="applyUpdate()" style="display:none;">一键更新</button>
            </div>
            <div id="update_status" style="margin-top:10px;"></div>
            <div class="text-muted" style="margin-top:8px; font-size:12px;">
                说明：自动从 GitHub Releases 检查最新版本并下载安装（与手动上传等效，免下载传包）。下载前会做大小与 tar 完整性校验；安装完成后 LuCI 将延迟重启，请勿关闭页面。
            </div>
        </div>

        <!-- 插件更新 -->
        <h3>插件更新</h3>
        <div class="netmanager-form" style="border-left:3px solid #2563eb;">
            <div style="margin-bottom:10px;">
                <b>上传插件包 (.tar.gz)</b>
                <span class="text-muted" style="margin-left:8px;">从本地上传新版本插件包进行更新</span>
            </div>
            <div>
                <form id="upload_form" enctype="multipart/form-data" style="display:flex; gap:10px; align-items:center;">
                    <input type="file" id="plugin_file" accept=".tar.gz,.tgz" style="padding:5px;">
                    <button type="button" class="btn btn-primary btn-sm" onclick="uploadPlugin()">上传并更新</button>
                </form>
            </div>
            <div id="upload_status" style="margin-top:10px;"></div>
            <div class="text-muted" style="margin-top:8px; font-size:12px;">
                <b>更新说明：</b><br>
                1. 下载最新版 luci-app-netmanager-install_*.tar.gz<br>
                2. 点击"选择文件"选择下载的压缩包<br>
                3. 点击"上传并更新"按钮<br>
                4. 更新过程中会自动备份当前版本<br>
                5. 更新完成后需要刷新页面 (Ctrl+Shift+R)
            </div>
        </div>

        <div id="action_result" class="netmanager-result"></div>

        <h3>安全建议</h3>
        <div style="background:#fef3c7; padding:14px; border-radius:8px; border-left:3px solid #f59e0b; font-size:13px; line-height:2;">
            <b>基础安全检查清单：</b><br>
            1. 管理页面仅内网访问（uhttpd绑定LAN口IP）<br>
            2. SSH修改默认端口 + 仅内网或密钥登录<br>
            3. 关闭不必要的服务（rpcbind/NFS/ttyd/wsdd2）<br>
            4. 防火墙默认拒绝WAN口入站<br>
            5. 端口转发只开放必要端口<br>
            6. 定期查看SSH登录日志，发现异常IP及时封禁<br>
            7. 建议安装fail2ban自动封禁爆破IP<br>
            8. 建议开启SSH密钥登录，禁用密码登录
        </div>

        <!-- 运行日志 -->
        <h3>运行日志</h3>
        <div class="card" style="padding:15px;">
            <table class="netmanager-table" style="margin-bottom:10px;">
                <tr>
                    <td width="30%">启用日志记录</td>
                    <td>
                        <label><input type="checkbox" id="log_enable"> 将运行日志写入 /tmp/netmanager/run.log</label>
                        <span class="text-muted" style="margin-left:10px;">重启路由器后/tmp内容自动清空</span>
                    </td>
                    <td width="280px">
                        <button class="btn btn-primary btn-sm" onclick="saveLogSetting()">保存</button>
                        <button class="btn btn-secondary btn-sm" onclick="loadRunLog()">刷新日志</button>
                        <button class="btn btn-warning btn-sm" onclick="clearRunLog()">清空</button>
                    </td>
                </tr>
                <tr>
                    <td>日志路径</td>
                    <td id="log_path" colspan="2"><span class="text-muted">加载中...</span></td>
                </tr>
            </table>
            <div>
                <label style="font-size:12px;color:#666;">显示最后
                    <select id="log_lines" onchange="loadRunLog()" style="padding:2px 5px;">
                        <option value="100">100</option>
                        <option value="200" selected>200</option>
                        <option value="500">500</option>
                        <option value="1000">1000</option>
                    </select>
                    行
                </label>
            </div>
            <textarea id="run_log_box" readonly style="width:100%;height:260px;margin-top:8px;font-family:Consolas,'Courier New',monospace;font-size:12px;line-height:1.5;background:#0f172a;color:#e2e8f0;border:1px solid #334155;border-radius:4px;padding:8px;resize:vertical;"></textarea>
        </div>

        <h3>关于插件</h3>
        <table class="netmanager-table">
            <tr><td width="30%">插件名称</td><td>网络管理 (luci-app-netmanager)</td></tr>
            <tr><td>版本</td><td id="plugin_version">v1.4.5</td></tr>
            <tr><td>作者</td><td><b>Network Manager</b></td></tr>
            <tr><td>适配系统</td><td>iStoreOS / OpenWrt (fw4/nftables)</td></tr>
            <tr><td>功能模块</td><td>系统概览 / 端口转发 / 规则管理 / SSH日志 / 访问日志</td></tr>
            <tr><td>后端脚本</td><td>/usr/sbin/netmanager</td></tr>
            <tr><td>配置文件</td><td>/etc/config/netmanager</td></tr>
        </table>

        <h3>卸载插件</h3>
        <div class="netmanager-form" style="border-left:3px solid #dc2626;">
            <div style="margin-bottom:10px;">
                <b style="color:#dc2626;">⚠ 危险操作（不可撤销）</b>
                <span class="text-muted" style="margin-left:8px;">将删除后端脚本、LuCI页面、init/hotplug脚本、nft规则、cron任务与缓存；2秒后自动重启uhttpd。用户在 /etc/config/firewall 中的端口转发与防火墙规则不受影响。</span>
            </div>
            <table class="netmanager-table" style="margin-bottom:10px;">
                <tr>
                    <td width="35%">卸载范围</td>
                    <td>
                        <label style="font-size:13px;cursor:pointer;">
                            <input type="checkbox" id="uninstall_keep_config" style="vertical-align:middle;margin-right:4px;">
                            保留配置与CIDR列表（/etc/config/netmanager 与 /etc/netmanager/）
                        </label>
                        <span class="text-muted" style="display:block;margin-top:4px;">不勾选则全删；勾选后下次重装可继承原配置</span>
                    </td>
                </tr>
            </table>
            <div class="netmanager-toolbar">
                <button class="btn btn-danger btn-sm" onclick="uninstallPlugin()">一键卸载插件</button>
                <span class="text-muted" style="margin-left:8px;">卸载后浏览器将自动跳转到首页，左侧菜单不再显示「网络管理」</span>
            </div>
        </div>
    </div>
    <div class="footer-sign">网络管理插件 v1.4.5<br><span style="font-size:10px;">适配 iStoreOS / OpenWrt | 基于 fw4/nftables</span></div>
</div>
<script>
const API_URL = '<%=luci.dispatcher.build_url("admin/netmanager/api")%>';

function loadSettings() {
    fetch(API_URL, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=settings'})
    .then(r => r.text()).then(data => {
        data.split('\n').forEach(line => {
            if (line.includes('=')) {
                const idx = line.indexOf('=');
                const k = line.substring(0, idx), v = line.substring(idx + 1);
                if (k === 'DEFAULT_TARGET') document.getElementById('default_target').value = v;
                if (k === 'LOG_ENABLE') document.getElementById('log_enable').checked = (v === '1');
                if (k === 'LOG_FILE') document.getElementById('log_path').innerHTML = `<code style="background:#f1f5f9;padding:2px 6px;border-radius:3px;">${escapeHtml(v)}</code> <span class="text-muted">(路由器重启后自动清空)</span>`;
                if (k === 'UPDATE_MIRROR') document.getElementById('update_mirror').value = v;
            }
        });
    });
    setTimeout(loadRunLog, 300);
    setTimeout(loadChinaStatus, 300);
}

// ========== 在线更新功能 ==========
function checkUpdate() {
    const box = document.getElementById('update_status');
    const btn = document.getElementById('btn_check_update');
    btn.disabled = true;
    box.innerHTML = '<span class="text-info">正在连接 GitHub 检查最新版本（最长约 15 秒，直连受限时请先保存镜像加速）...</span>';
    fetch(API_URL, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=update_check'})
    .then(r => r.text()).then(data => {
        let latest = '', avail = '', msg = '', mirror = '';
        data.split('\n').forEach(line => {
            const i = line.indexOf('=');
            if (i < 1) return;
            const k = line.substring(0, i), v = line.substring(i + 1);
            if (k === 'LATEST_VERSION') latest = v;
            else if (k === 'UPDATE_AVAILABLE') avail = v;
            else if (k === 'MESSAGE') msg = v;
            else if (k === 'MIRROR') mirror = v;
        });
        if (mirror === '(直连)') mirror = '';
        if (mirror !== '') document.getElementById('update_mirror').value = mirror;
        if (!latest) {
            box.innerHTML = '<pre class="result-pre" style="color:#f87171;">' + escapeHtml(data) + '</pre>';
        } else {
            document.getElementById('online_latest_version').innerHTML = '<b>' + escapeHtml(latest) + '</b>';
            if (avail === '1') {
                box.innerHTML = '<span class="text-success">✓ ' + escapeHtml(msg || '发现新版本') + '</span>';
                document.getElementById('btn_apply_update').style.display = '';
            } else if (avail === '0') {
                box.innerHTML = '<span class="text-success">✓ ' + escapeHtml(msg || '当前已是最新版本') + '</span>';
                document.getElementById('btn_apply_update').style.display = 'none';
            } else {
                box.innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
            }
        }
    })
    .catch(e => {
        box.innerHTML = '<span class="text-danger">检查失败: ' + escapeHtml(e.message) + '</span>';
    })
    .then(() => { btn.disabled = false; });
}

function applyUpdate() {
    if (!confirm('确定在线更新到最新版本吗？\n\n• 将从 GitHub 下载最新安装包并自动安装\n• 安装完成后 LuCI 将延迟重启，请勿关闭页面\n• 建议先在上方「系统工具」备份当前配置')) return;
    const box = document.getElementById('update_status');
    const btn = document.getElementById('btn_apply_update');
    btn.disabled = true;
    box.innerHTML = '<span class="text-info">正在下载并安装最新版（取决于网速，可能需要 1~3 分钟），请勿关闭或刷新页面...</span>';
    fetch(API_URL, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=update_apply'})
    .then(r => r.text()).then(data => {
        box.innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        if (data.indexOf('插件更新完成') >= 0 || data.indexOf('install_rc=0') >= 0) {
            box.innerHTML += '<div class="text-success" style="margin-top:8px;"><b>更新成功！</b>LuCI 将在数秒后重启导致连接断开（属正常现象），之后按 Ctrl+Shift+R 强制刷新浏览器即可使用新版本。</div>';
        }
    })
    .catch(e => {
        box.innerHTML = '<span class="text-warning">更新请求中断: ' + escapeHtml(e.message) + '（若因 LuCI 重启断开属正常现象，稍后刷新页面查看「关于插件」中的版本号确认）</span>';
    })
    .then(() => { btn.disabled = false; });
}

function saveUpdateMirror() {
    const m = document.getElementById('update_mirror').value.trim();
    fetch(API_URL, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=set_update_mirror&mirror=' + encodeURIComponent(m)})
    .then(r => r.text()).then(data => {
        document.getElementById('update_status').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
    });
}

// ========== 运行日志功能 ==========
function saveLogSetting() {
    const en = document.getElementById('log_enable').checked ? '1' : '0';
    fetch(API_URL, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=log_set&enable=' + en})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        loadSettings();
    });
}

function loadRunLog() {
    const lines = document.getElementById('log_lines').value;
    const box = document.getElementById('run_log_box');
    fetch(API_URL, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=log_get&lines=' + lines})
    .then(r => r.text()).then(data => {
        let content = '';
        let inContent = false;
        data.split('\n').forEach(line => {
            if (line === '---CONTENT---') { inContent = true; return; }
            if (line === '===END===') return;
            if (inContent) content += line + '\n';
            else if (line.startsWith('LOG_LINES=')) {
                const n = parseInt(line.split('=')[1]) || 0;
                if (n === 0) content = '（暂无日志记录，请先在上方勾选"启用日志记录"并保存，然后操作页面功能以产生日志）\n';
            }
        });
        box.value = content.trim();
        // 自动滚动到底部
        setTimeout(() => { box.scrollTop = box.scrollHeight; }, 50);
    }).catch(e => {
        box.value = '加载日志失败: ' + e.message;
    });
}

function clearRunLog() {
    if (!confirm('确定要清空运行日志吗？')) return;
    fetch(API_URL, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=log_clear'})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(loadRunLog, 500);
    });
}

function saveDefaultTarget() {
    const ip = document.getElementById('default_target').value.trim();
    if (!ip) { alert('请输入IP地址'); return; }
    if (!/^(\d{1,3}\.){3}\d{1,3}$/.test(ip)) { alert('IP格式不正确'); return; }
    fetch(API_URL, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=set_default_target&ip=' + ip})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
    });
}

function runAction(action) {
    document.getElementById('action_result').innerHTML = '<span class="text-info">执行中...</span>';
    fetch(API_URL, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=' + action})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
    });
}

// 备份功能
function doBackup() {
    if (!confirm('确定要备份当前防火墙配置吗？')) return;
    fetch(API_URL, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=backup'})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(listBackups, 1500);
    });
}

function listBackups() {
    fetch(API_URL, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=backup_list'})
    .then(r => r.text()).then(data => {
        let html = '';
        const lines = data.split('\n');
        let backups = [];
        let backupCount = 0;
        
        lines.forEach(line => {
            if (line.includes('|') && !line.startsWith('=')) {
                const parts = line.split('|');
                if (parts.length >= 2 && parts[0].startsWith('firewall-')) {
                    backups.push(parts);
                }
            }
            if (line.startsWith('BACKUP_COUNT=')) {
                backupCount = parseInt(line.split('=')[1]) || 0;
            }
        });
        
        if (backups.length === 0) {
            html = '<div class="text-muted" style="padding:10px;">暂无备份文件</div>';
        } else {
            html = `<table class="netmanager-table"><thead><tr><th>备份文件名</th><th>大小</th><th>操作</th></tr></thead><tbody>`;
            backups.forEach(b => {
                html += `<tr>
                    <td><code>${b[0]}</code></td>
                    <td>${formatSize(parseInt(b[1]) || 0)}</td>
                    <td>
                        <button class="btn btn-primary btn-sm" onclick="restoreBackup('${b[0]}')">恢复</button>
                        <button class="btn btn-danger btn-sm" onclick="deleteBackup('${b[0]}')">删除</button>
                    </td>
                </tr>`;
            });
            html += '</tbody></table>';
        }
        
        document.getElementById('backup_list').innerHTML = html;
    });
}

function formatSize(bytes) {
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1048576) return (bytes / 1024).toFixed(1) + ' KB';
    return (bytes / 1048576).toFixed(1) + ' MB';
}

function restoreBackup(filename) {
    if (!confirm(`确定要从备份 ${filename} 恢复配置吗？\n\n⚠️ 恢复前会自动备份当前配置！`)) return;
    fetch(API_URL, {
        method:'POST',
        headers:{'Content-Type':'application/x-www-form-urlencoded'},
        body:'action=backup_restore&filename=' + encodeURIComponent(filename)
    })
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(listBackups, 1500);
    });
}

function deleteBackup(filename) {
    if (!confirm(`确定要删除备份 ${filename} 吗？此操作不可恢复！`)) return;
    fetch(API_URL, {
        method:'POST',
        headers:{'Content-Type':'application/x-www-form-urlencoded'},
        body:'action=backup_delete&filename=' + encodeURIComponent(filename)
    })
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(listBackups, 1500);
    });
}

// 插件更新功能 - 使用 multipart/form-data 原生文件上传
function uploadPlugin() {
    const fileInput = document.getElementById('plugin_file');
    const file = fileInput.files[0];
    
    if (!file) {
        alert('请先选择一个 .tar.gz 插件包');
        return;
    }
    
    if (!file.name.endsWith('.tar.gz') && !file.name.endsWith('.tgz')) {
        alert('只支持 .tar.gz 格式的插件包');
        return;
    }
    
    const statusEl = document.getElementById('upload_status');
    statusEl.innerHTML = '<span class="text-info">正在上传并更新插件...</span>';
    
    // 使用 FormData 实现 multipart/form-data 原生文件上传
    // LuCI natively supports multipart file uploads via formvalue()
    const formData = new FormData();
    formData.append('action', 'plugin_upload_update');
    formData.append('plugin_file', file);
    
    fetch(API_URL, {
        method: 'POST',
        body: formData
    })
    .then(r => r.text())
    .then(data => {
        statusEl.innerHTML = '';
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        if (data.includes('完成') || data.includes('成功')) {
            statusEl.innerHTML = '<div class="text-success" style="margin-top:10px;">✅ 插件更新完成！请刷新页面 (Ctrl+Shift+R)</div>';
            fileInput.value = '';
        }
    })
    .catch(err => {
        statusEl.innerHTML = '<div class="text-danger">❌ 更新失败: ' + escapeHtml(err.message) + '</div>';
    });
}

// ========== 中国IPv4访问限制 ==========
function loadChinaStatus() {
    fetch(API_URL, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=china_filter_status'})
    .then(r => r.text()).then(data => {
        let en='0', url='', cron='', lu='', cnt='0', devs='', active='0';
        data.split('\n').forEach(line => {
            const idx = line.indexOf('=');
            if (idx > 0) {
                const k = line.substring(0, idx), v = line.substring(idx + 1);
                if (k === 'CHINA_FILTER_ENABLED') en = v;
                else if (k === 'URL') url = v;
                else if (k === 'CRON') cron = v;
                else if (k === 'LAST_UPDATE') lu = v;
                else if (k === 'COUNT') cnt = v;
                else if (k === 'WAN_DEVS') devs = v;
                else if (k === 'RULE_ACTIVE') active = v;
            }
        });
        const ruleBadge = active === '1'
            ? ' <span class="badge badge-blue">规则已加载</span>'
            : (en === '1' ? ' <span class="badge badge-gray" style="background:#94a3b8;color:#fff;">规则未加载</span>' : '');
        const statusBadge = en === '1' ? '<span class="badge badge-green">已启用</span>' + ruleBadge : '<span class="badge badge-gray">已关闭</span>';
        document.getElementById('china_status_cell').innerHTML = statusBadge;
        document.getElementById('china_url').value = url;
        document.getElementById('china_update_cell').innerHTML = '上次更新: ' + (lu || '未更新') + ' | CIDR条数: <b>' + cnt + '</b>';
        document.getElementById('china_wan_cell').innerHTML = 'WAN设备: <code>' + (devs || '(未探测到)') + '</code> | 规则: ' + (active === '1' ? '<span class="text-success">生效中</span>' : '<span class="text-muted">未生效</span>');
        // cron 预设回填
        const sel = document.getElementById('china_cron_preset');
        const customInput = document.getElementById('china_cron_custom');
        let matched = false;
        for (let i = 0; i < sel.options.length; i++) {
            if (sel.options[i].value === cron && sel.options[i].value !== '__custom__') { sel.selectedIndex = i; matched = true; break; }
        }
        if (!matched) {
            sel.value = '__custom__';
            customInput.value = cron;
            customInput.style.display = '';
        } else {
            customInput.value = '';
            customInput.style.display = 'none';
        }
    }).catch(e => {
        document.getElementById('china_status_cell').innerHTML = '<span class="text-danger">加载失败: ' + escapeHtml(e.message) + '</span>';
    });
}

function onCronPresetChange() {
    const sel = document.getElementById('china_cron_preset');
    const customInput = document.getElementById('china_cron_custom');
    if (sel.value === '__custom__') { customInput.style.display = ''; }
    else { customInput.style.display = 'none'; customInput.value = ''; }
}

function saveChinaUrl() {
    const url = document.getElementById('china_url').value.trim();
    if (!url) { alert('请输入订阅链接'); return; }
    if (!/^https?:\/\//.test(url)) { alert('链接必须以 http:// 或 https:// 开头'); return; }
    fetch(API_URL, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=china_filter_set_url&url=' + encodeURIComponent(url)})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
    });
}

function saveChinaCron() {
    const sel = document.getElementById('china_cron_preset');
    let cron = sel.value;
    if (cron === '__custom__') {
        cron = document.getElementById('china_cron_custom').value.trim();
        if (!cron) { alert('请输入自定义cron表达式(5段: 分 时 日 月 周)'); return; }
    }
    fetch(API_URL, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=china_filter_set_cron&cron=' + encodeURIComponent(cron)})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(loadChinaStatus, 300);
    });
}

function setChinaBtns(enabled) {
    ['btn_china_enable','btn_china_disable','btn_china_update'].forEach(id => {
        const b = document.getElementById(id);
        if (b) b.disabled = !enabled;
    });
}

function enableChinaFilter() {
    if (!confirm('确定开启中国IPv4访问限制吗？\n\n开启后仅中国大陆IPv4可访问已开放端口（端口转发与路由器本地放行端口），境外IPv4新建连接将被丢弃。')) return;
    setChinaBtns(false);
    fetch(API_URL, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=china_filter_enable'})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(() => { loadChinaStatus(); setChinaBtns(true); }, 600);
    }).catch(e => { setChinaBtns(true); alert('启用失败: ' + e.message); });
}

function disableChinaFilter() {
    if (!confirm('确定关闭中国IPv4访问限制吗？\n\n关闭后境外IPv4可恢复访问已开放端口。')) return;
    setChinaBtns(false);
    fetch(API_URL, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=china_filter_disable'})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(() => { loadChinaStatus(); setChinaBtns(true); }, 400);
    }).catch(e => { setChinaBtns(true); alert('关闭失败: ' + e.message); });
}

function updateChinaFilter() {
    setChinaBtns(false);
    fetch(API_URL, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=china_filter_update'})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(() => { loadChinaStatus(); setChinaBtns(true); }, 600);
    }).catch(e => { setChinaBtns(true); alert('更新失败: ' + e.message); });
}

// ========== 卸载插件 ==========
function uninstallPlugin() {
    const keep = document.getElementById('uninstall_keep_config').checked ? '1' : '0';
    const keepTxt = keep === '1' ? '• 保留 /etc/config/netmanager、/etc/netmanager/ 与 /etc/config/dnssettings\n' : '• 删除 /etc/config/netmanager、/etc/netmanager/ 与 /etc/config/dnssettings\n';
    const msg = '⚠ 确定卸载「网络管理插件」吗？\n\n此操作将：\n'
        + '• 关闭中国IPv4过滤并清理 nft 规则、cron 任务\n'
        + '• 删除后端脚本 /usr/sbin/netmanager\n'
        + '• 删除 LuCI 控制器、DNS CBI 模型与全部视图页面\n'
        + '• 删除 DNS 应用/备份脚本 (dnssettings-apply.sh / dnssettings-backup.sh)\n'
        + '• 删除 init / hotplug 自启脚本\n'
        + keepTxt
        + '• 清理 /tmp 临时文件与 LuCI 缓存\n'
        + '• 2秒后自动重启 uhttpd\n\n'
        + '用户在 /etc/config/firewall 中的端口转发与防火墙规则不受影响，保留不动。\n\n'
        + '卸载后浏览器将自动跳转到首页，左侧菜单不再显示「网络管理」。';
    if (!confirm(msg)) return;
    if (!confirm('⚠ 二次确认：这是最终确认，卸载后无法撤销，确定继续？')) return;
    document.getElementById('action_result').innerHTML = '<pre class="result-pre" style="color:#dc2626;">卸载进行中，请勿关闭页面...（uhttpd 重启会导致连接断开，属正常现象）</pre>';
    fetch(API_URL, {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=uninstall&keep=' + keep})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        // 3秒后uhttpd已重启，跳转首页
        setTimeout(() => {
            alert('卸载已完成，uhttpd 正在重启。\n点击确定后浏览器将跳转到首页。');
            window.location.href = '/';
        }, 3000);
    }).catch(e => {
        // uhttpd重启会断开连接，属正常
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">卸载请求已发出（uhttpd重启导致连接断开属正常现象）。\n请等待3秒后刷新浏览器或访问路由器首页。</pre>';
        setTimeout(() => { window.location.href = '/'; }, 3000);
    });
}

// 初始化
loadSettings();
listBackups();
</script>
<%+footer%>
```

### 5.16 files/etc/config/netmanager

- **用途**：防火墙模块 UCI 配置：默认目标 IP / 日志开关 / 中国过滤全部参数
- **规模**：12 行
- **维护要点**：默认订阅 metowolf china.txt；china_filter_cron 默认每周日 3 点

```uci
config netmanager 'settings'
    option default_target '192.168.31.196'
    option log_days '7'
    option auto_ban '0'
    option auto_ban_threshold '5'
    option log_enable '0'
    option china_filter_enable '0'
    option china_filter_url 'https://metowolf.github.io/iplist/data/special/china.txt'
    option china_filter_cron '0 3 * * 0'
    option china_filter_last_update ''
    option china_filter_count '0'
    option update_mirror ''
```

### 5.17 files/etc/config/dnssettings

- **用途**：DNS 模块 UCI 配置：wan / lan / dnsmasq / actions 四节
- **规模**：22 行
- **维护要点**：wan/lan/dnsmasq 三节为 dns_settings.lua 表单绑定；actions 节为按钮占位

```uci
config wan 'wan'
    option peerdns '0'
    option dns1_v4 '223.5.5.5'
    option dns2_v4 '119.29.29.29'
    option dns1_v6 '2400:3200::1'
    option dns2_v6 '2402:4e00::'

config lan 'lan'
    option force_dns '1'
    option dns1_v4 '223.5.5.5'
    option dns2_v4 '119.29.29.29'
    option dns1_v6 '2400:3200::1'
    option dns2_v6 '2402:4e00::'

config dnsmasq 'dnsmasq'
    option enable '1'
    list forward_v4 '223.5.5.5'
    list forward_v4 '119.29.29.29'
    list forward_v6 '2400:3200::1'
    list forward_v6 '2402:4e00::'

config actions 'actions'
```

### 5.18 files/etc/init.d/netmanager-china

- **用途**：开机自启脚本：重应用中国 IPv4 过滤规则
- **规模**：26 行
- **维护要点**：START/STOP 顺序：参考 OpenWrt 规范，启动晚于防火墙以确保 fw4 就绪

```bash
#!/bin/sh /etc/rc.common
# ============================================================
# 网络管理插件 - 中国IPv4访问限制 开机自启
# 
# 作用: 开机后从本地持久化列表重建 nft 集合与过滤规则
#       (nft 规则在内核内存中，重启即清空，需重新应用)
# ============================================================

START=99

boot() {
    # 后台延迟执行，等待网络/防火墙就绪，避免阻塞开机
    sh -c 'sleep 8; /usr/sbin/netmanager china_filter boot' >/dev/null 2>&1 &
}

start() {
    /usr/sbin/netmanager china_filter boot
}

stop() {
    :
}

restart() {
    /usr/sbin/netmanager china_filter boot
}
```

### 5.19 files/etc/hotplug.d/iface/95-netmanager-china

- **用途**：WAN 上线热插拔脚本：接口上线自动重应用规则（自愈机制）
- **规模**：24 行
- **维护要点**：编号 95 确保在 fw4 默认 hotplug 之后执行

```bash
#!/bin/sh
# ============================================================
# 网络管理插件 - 中国IPv4访问限制 WAN接口事件
# 
# 作用: WAN 接口 up 时重新应用过滤规则，刷新 WAN 设备名
#       (解决 PPPoE 重连 / DHCP 续约导致设备名漂移后规则失效)
# ============================================================

# 仅处理 ifup 事件
[ "$ACTION" = "ifup" ] || exit 0

# 仅对 wan 类接口生效（INTERFACE 形如 wan / wan6 / wan-xxx）
case "$INTERFACE" in
    wan|wan6|wan-*|wan6-*) ;;
    *) exit 0 ;;
esac

# 仅在功能已启用时重应用（避免无谓执行）
[ "$(uci -q get netmanager.settings.china_filter_enable 2>/dev/null)" = "1" ] || exit 0

# 后台重应用，不阻塞 hotplug
( sleep 2; /usr/sbin/netmanager china_filter boot ) >/dev/null 2>&1 &

exit 0
```

### 5.20 install.sh

- **用途**：一键安装脚本：7 步安装，复制文件 / 权限 / /bin/netmanager 符号链接 / init / cron，支持 SKIP_UHTTPD_RESTART
- **规模**：109 行
- **维护要点**：L3/L8 版本号（登记处）；L32 ln -sf /bin/netmanager 符号链接——uninstall 未清理该链接（v1.4.6 待修）

```bash
#!/bin/ash
# ============================================================
# 网络管理插件 (luci-app-netmanager) - 一键安装脚本 v1.4.5
# 由 luci-app-fwmanager (防火墙管理) 与 luci-app-dnssettings (DNS设置) 合并而成
# ============================================================

echo "============================================"
echo "  网络管理插件 (luci-app-netmanager) v1.4.5"
echo "  防火墙管理 + DNS设置 一体化"
echo "============================================"
echo ""

# 检查是否root
if [ "$(id -u)" != "0" ]; then
    echo "错误: 请使用root用户运行"
    exit 1
fi

# 检查系统
if [ ! -f "/etc/openwrt_release" ] && [ ! -f "/etc/istoreos_release" ]; then
    echo "警告: 未检测到OpenWrt/iStoreOS系统，继续安装可能有风险"
    read -p "是否继续? (y/n): " confirm
    [ "$confirm" != "y" ] && exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files"

echo "[1/7] 复制后端脚本与 DNS 管理脚本..."
cp -f "$FILES_DIR/usr/sbin/netmanager" /usr/sbin/netmanager
chmod +x /usr/sbin/netmanager
ln -sf /usr/sbin/netmanager /bin/netmanager 2>/dev/null
cp -f "$FILES_DIR/usr/sbin/dnssettings-apply.sh" /usr/sbin/dnssettings-apply.sh
cp -f "$FILES_DIR/usr/sbin/dnssettings-backup.sh" /usr/sbin/dnssettings-backup.sh
chmod +x /usr/sbin/dnssettings-apply.sh
chmod +x /usr/sbin/dnssettings-backup.sh
echo "  ✓ /usr/sbin/netmanager"
echo "  ✓ /usr/sbin/dnssettings-apply.sh"
echo "  ✓ /usr/sbin/dnssettings-backup.sh"

echo "[2/7] 复制LuCI控制器..."
mkdir -p /usr/lib/lua/luci/controller
cp -f "$FILES_DIR/usr/lib/lua/luci/controller/netmanager.lua" /usr/lib/lua/luci/controller/netmanager.lua
echo "  ✓ controller/netmanager.lua"

echo "[3/7] 复制LuCI CBI模型（DNS设置/静态IPv6分配）..."
mkdir -p /usr/lib/lua/luci/model/cbi/netmanager
cp -f "$FILES_DIR/usr/lib/lua/luci/model/cbi/netmanager/"*.lua /usr/lib/lua/luci/model/cbi/netmanager/
echo "  ✓ model/cbi/netmanager/dns_settings.lua"
echo "  ✓ model/cbi/netmanager/dns_staticv6.lua"

echo "[4/7] 复制LuCI视图模板..."
mkdir -p /usr/lib/lua/luci/view/netmanager
cp -f "$FILES_DIR/usr/lib/lua/luci/view/netmanager/"*.htm /usr/lib/lua/luci/view/netmanager/
echo "  ✓ view/netmanager/*.htm (9个文件)"

echo "[5/7] 复制配置文件..."
if [ ! -f "/etc/config/netmanager" ]; then
    cp -f "$FILES_DIR/etc/config/netmanager" /etc/config/netmanager
    echo "  ✓ /etc/config/netmanager"
else
    echo "  - /etc/config/netmanager 已存在，跳过（新选项由插件自动补齐默认值）"
fi
if [ ! -f "/etc/config/dnssettings" ]; then
    cp -f "$FILES_DIR/etc/config/dnssettings" /etc/config/dnssettings
    echo "  ✓ /etc/config/dnssettings"
else
    echo "  - /etc/config/dnssettings 已存在，跳过（保留原有DNS配置）"
fi

echo "[6/7] 复制系统脚本（中国IPv4过滤开机自启）..."
mkdir -p /etc/init.d /etc/hotplug.d/iface
cp -f "$FILES_DIR/etc/init.d/netmanager-china" /etc/init.d/netmanager-china
chmod +x /etc/init.d/netmanager-china
cp -f "$FILES_DIR/etc/hotplug.d/iface/95-netmanager-china" /etc/hotplug.d/iface/95-netmanager-china
chmod +x /etc/hotplug.d/iface/95-netmanager-china 2>/dev/null
/etc/init.d/netmanager-china enable 2>/dev/null
echo "  ✓ /etc/init.d/netmanager-china (开机自启)"
echo "  ✓ /etc/hotplug.d/iface/95-netmanager-china (WAN上线重应用)"

echo "[7/7] 重启LuCI..."
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null

# 网页插件更新时：由调用方决定何时重启，避免 HTTP 连接被切断导致 UI 显示失败
# 环境变量 SKIP_UHTTPD_RESTART=1 表示跳过本次立即重启，由外部延迟重启
if [ "$SKIP_UHTTPD_RESTART" = "1" ] || [ "$SKIP_UHTTPD_RESTART" = "true" ]; then
    echo "  - 跳过立即重启LuCI（网页更新模式，稍后由系统延迟重启）"
else
    /etc/init.d/uhttpd restart 2>/dev/null
    echo "  ✓ LuCI已重启"
fi

echo ""
echo "============================================"
echo "  安装完成！"
echo "============================================"
echo ""
echo "访问方式:"
echo "  Web界面: 路由器管理页 -> 网络管理"
echo "  命令行:  netmanager overview"
echo "           netmanager port_list"
echo "           netmanager ssh_log"
echo "           netmanager access_log"
echo ""
echo "默认 DNS:"
echo "  IPv4: 223.5.5.5 / 119.29.29.29"
echo "  IPv6: 2400:3200::1 / 2402:4e00::"
echo ""
echo "============================================"
```

### 5.21 .github/workflows/build.yml

- **用途**：GitHub Actions 工作流：tag 推送时打包 tar.gz 资产并创建 Release
- **规模**：156 行
- **维护要点**：tag 推送触发；产物命名 luci-app-netmanager-install_<ver>.tar.gz；Release body 由 extract_changelog.awk 自动填充

````yaml
name: Build Install Package
on:
  workflow_dispatch:
    inputs:
      force:
        description: '强制重新打包（忽略版本已存在检查）'
        required: false
        type: boolean
        default: false
  push:
    branches:
      - main
      - master
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4

      - name: Read version from README
        id: version
        run: |
          # 从 README.md 头部「版本：vX.Y.Z」提取最新版本号（-m1 取第一处匹配）
          # 提取失败时用当前日期兜底，保证流水线不中断
          VERSION=$(grep -m1 -oE '版本：v[0-9]+\.[0-9]+\.[0-9]+' README.md | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
          if [ -z "$VERSION" ]; then
            VERSION=$(date +'%Y.%m.%d')
            echo "WARN: 未从 README.md 提取到版本号，使用日期兜底: $VERSION"
          fi
          TAG="v${VERSION}"
          echo "version=${VERSION}" >> $GITHUB_OUTPUT
          echo "tag=${TAG}" >> $GITHUB_OUTPUT
          echo "Version: ${TAG}"

      - name: Check if tag already exists
        id: check
        run: |
          TAG="${{ steps.version.outputs.tag }}"
          if git ls-remote --exit-code --tags origin "refs/tags/${TAG}" >/dev/null 2>&1; then
            echo "exists=true" >> $GITHUB_OUTPUT
            echo "Tag ${TAG} 已存在，跳过打包与发布（如需强制重新发布，请手动运行本 workflow 并勾选 force）"
          else
            echo "exists=false" >> $GITHUB_OUTPUT
            echo "Tag ${TAG} 不存在，开始打包发布"
          fi

      - name: Build tar.gz install package
        if: steps.check.outputs.exists == 'false' || inputs.force == true
        run: |
          chmod +x install.sh files/usr/sbin/netmanager files/usr/sbin/dnssettings-apply.sh files/usr/sbin/dnssettings-backup.sh files/etc/init.d/netmanager-china files/etc/hotplug.d/iface/95-netmanager-china 2>/dev/null || true
          # 打包安装包（iStoreOS 不支持标准 ipk，使用 tar.gz + install.sh 脚本安装）
          # 使用 GNU tar --owner=0 --group=0 保证在路由器上属主正确；--mode 保证脚本可执行
          tar --owner=0 --group=0 --mode='u=rwX,go=rX' -czvf luci-app-netmanager-install_${{ steps.version.outputs.tag }}.tar.gz install.sh files/
          ls -lh luci-app-netmanager-install_*.tar.gz

      - name: Create and push tag
        if: steps.check.outputs.exists == 'false' || inputs.force == true
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git tag -f ${{ steps.version.outputs.tag }}
          git push -f origin ${{ steps.version.outputs.tag }}

      - name: Extract changelog from README
        id: extract
        if: steps.check.outputs.exists == 'false' || inputs.force == true
        run: |
          # 从 README 更新日志提取当前版本的段落，作为 Release body 的变更内容
          # 注意：README 日志标题是 "### vX.Y.Z"（带 v 前缀），必须补 v 再匹配
          CHANGELOG=$(awk -v ver="v${{ steps.version.outputs.version }}" -f .github/workflows/extract_changelog.awk README.md)
          if [ -z "$(echo "$CHANGELOG" | tr -d '[:space:]')" ]; then
            CHANGELOG="（README 中未找到 v${{ steps.version.outputs.version }} 的更新日志段落）"
            echo "WARN: 未提取到更新日志，Release 将使用占位文案"
          fi
          # 写入多行 output（heredoc 定界符语法，GitHub Actions 官方推荐，保留换行）
          echo "changelog<<CHANGELOG_EOF" >> $GITHUB_OUTPUT
          echo "$CHANGELOG" >> $GITHUB_OUTPUT
          echo "CHANGELOG_EOF" >> $GITHUB_OUTPUT
          echo "提取到的更新日志行数: $(echo "$CHANGELOG" | wc -l)"

      - name: Release
        if: steps.check.outputs.exists == 'false' || inputs.force == true
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ steps.version.outputs.tag }}
          files: luci-app-netmanager-install_*.tar.gz
          generate_release_notes: true
          body: |
            ## 网络管理插件 ${{ steps.version.outputs.tag }}

            > 适配：iStoreOS / OpenWrt (fw4/nftables)
            >
            > 由 luci-app-fwmanager 与 luci-app-dnssettings 合并而成

            ### 本次更新（v${{ steps.version.outputs.version }}）

            ${{ steps.extract.outputs.changelog }}

            ---

            ### 功能模块
            - 系统概览（防火墙状态/端口统计/网络信息/快捷操作）
            - 端口转发管理（IPv4 DNAT + IPv6放行，支持TCP/UDP/双协议）
            - 防火墙规则管理（自定义增删规则 + 常用模板）
            - SSH登录日志（成功/失败记录 + 失败IP排行 + 自动刷新）
            - 端口访问日志（活跃连接/入站出站计数/拦截统计）
            - **DNS设置（v1.4.0 新增）**：WAN口上游DNS / LAN口设备下发DNS / dnsmasq全局转发，IPv4+IPv6双栈，一键应用与配置备份
            - **静态IPv6分配（v1.4.0 新增）**：基于MAC绑定 hostid/ip6/DUID，自动合并重复条目与 hostid 冲突检测
            - 设置（默认目标IP/安全建议/系统工具/配置备份/插件在线更新/运行日志排错）
            - **中国IPv4访问限制（继承自 v1.3.33）**：仅允许中国大陆 IPv4 访问已开放端口（DNAT+路由器本地开放端口），境外 IPv4 新建连接丢弃；默认订阅 `https://metowolf.github.io/iplist/data/special/china.txt`，支持自定义订阅链接与自定义 cron 更新计划；开机 init + WAN hotplug 自愈；**旧版 nft 自动降级兼容**（modern `flags interval, auto-merge` 分片加载 / compat `flags interval` 单次原子加载 + 逐行回退）

            ### 安装方法（iStoreOS 推荐脚本安装）
            1. 下载 `luci-app-netmanager-install_*.tar.gz` 上传到路由器 `/tmp`
            2. SSH 登录路由器，执行：
            ```bash
            cd /tmp
            tar xzvf luci-app-netmanager-install_*.tar.gz
            ./install.sh
            ```
            3. 安装后左侧菜单出现「网络管理」，浏览器 Ctrl+Shift+R 强制刷新

            ### 中国IPv4访问限制 使用指引
            1. 左侧进入「网络管理 → 设置」→ 找到「中国IPv4访问限制」区块
            2. 确认 IP库订阅链接（默认 `https://metowolf.github.io/iplist/data/special/china.txt`，可改自定义订阅）
            3. 选择更新计划（预设每天/每周/每月/每12小时或自定义 cron）
            4. 先点「更新IP库」下载最新 CIDR 列表，再点「立即启用」应用 nft 规则
            5. 状态显示 "已启用 / RULE_ACTIVE=1" 即代表过滤生效；若路由器 nft 过旧，运行日志会显示自动降级 `旧版 nft 不支持 auto-merge，降级为 flags interval + 一次性原子加载`

            ### 命令行用法
            ```bash
            netmanager overview       # 系统概览
            netmanager port_list      # 端口转发列表
            netmanager ssh_log        # SSH登录日志
            netmanager access_log     # 端口访问日志
            netmanager rule_list      # 防火墙规则列表

            # DNS设置（v1.4.0+，等价于页面「应用配置」按钮）
            dnssettings-apply.sh      # 应用 /etc/config/dnssettings 到系统
            dnssettings-backup.sh     # 备份 network/dhcp 配置到 /root/backup/

            # 中国IPv4访问限制（继承自 v1.3.33）
            netmanager china_filter status                 # 查看状态
            netmanager china_filter enable                 # 开启（应用规则 + 装cron + 自启）
            netmanager china_filter disable                # 关闭（清规则 + 移cron，保留列表与设置）
            netmanager china_filter update                 # 更新IP库并重应用规则
            netmanager china_filter set_url <url>          # 自定义订阅链接
            netmanager china_filter set_cron "0 4 * * *"   # 自定义更新计划cron

            # 卸载插件
            netmanager uninstall                # 全删（含 DNS 配置与脚本）
            netmanager uninstall keep           # 保留 /etc/config/netmanager、/etc/netmanager/ 与 /etc/config/dnssettings，其余全删
            ```

            > 也可在「设置」页面点击「一键卸载插件」按钮卸载（支持保留配置勾选）。卸载不影响用户在 /etc/config/firewall 中的端口转发与防火墙规则。
````

### 5.22 .github/workflows/extract_changelog.awk

- **用途**：Release body 提取脚本：从 README.md 更新日志提取指定版本段落
- **规模**：16 行
- **维护要点**：注释中的版本号是有意保留的历史记录，发版时勿动

```awk
# extract_changelog.awk - 从 README.md 提取指定版本的更新日志段
# 用法: awk -v ver="v1.4.5" -f extract_changelog.awk README.md
# 逻辑：定位行首 "### v1.4.5 " 标题行，输出其后内容直到下一个 "### " 标题；
#       started 用于跳过段落前的空行，避免 Release body 顶部多余空行
# 防御：传入裸版本号（无 v 前缀）时自动补 v，两种传法均能匹配
BEGIN {
	found = 0
	started = 0
	if (ver !~ /^v/) ver = "v" ver
}
!found && index($0, "### " ver " ") == 1 { found = 1; next }
found && /^### / { exit }
found {
	if (!started && $0 == "") { next }
	started = 1
	print
}
```

### 5.23 .gitattributes

- **用途**：git 属性：强制 LF 行尾（.gitattributes，CRLF 警告可忽略）
- **规模**：14 行
- **维护要点**：13 行，强制 * text=auto eol=lf

```text
# 强制所有文本文件使用 LF 换行
# 路由器（BusyBox ash）上的 shell 脚本必须使用 LF，CRLF 会导致 shebang 解析失败
* text=auto eol=lf

# Windows 专用文件例外
*.bat text eol=crlf
*.cmd text eol=crlf

# 二进制文件
*.png binary
*.jpg binary
*.gif binary
*.ico binary
*.tar.gz binary
*.ipk binary
```

### 5.24 README.md

- **用途**：项目主文档：功能 / 安装 / CLI / 配置说明 / 更新日志 / 许可证
- **规模**：301 行
- **维护要点**：L3 版本号（登记处，CI 从此提取最新 tag）；L227-302 更新日志段（Release body 来源，发版必须新增对应小节）

````markdown
# 网络管理插件 (luci-app-netmanager)

> 版本：v1.4.5
>
> 适配：iStoreOS / OpenWrt (fw4/nftables, Lua LuCI)
>
> 由 **luci-app-fwmanager**（防火墙管理）与 **luci-app-dnssettings**（DNS设置）合并而成的网络管理一体化 LuCI 插件。

一站式管理路由器网络：端口转发、防火墙规则、SSH/访问日志、中国 IPv4 访问限制、WAN/LAN 双栈 DNS 统一管理、静态 IPv6 分配、配置备份恢复、插件在线更新、一键卸载。

---

## 功能模块

### 防火墙管理（原 luci-app-fwmanager）

1. **系统概览**：防火墙状态 / 端口统计 / 网络信息 / 快捷操作
2. **端口转发管理**：IPv4 DNAT + IPv6 放行统一管理，支持 TCP/UDP/双协议、单端口与端口范围
3. **防火墙规则管理**：自定义通信规则增删改 + 常用模板一键应用
4. **SSH 登录日志**：成功/失败记录 + 失败 IP 排行 Top 10 + 自动刷新
5. **端口访问日志**：活跃连接 / 入站出站计数 / 拦截统计
6. **中国 IPv4 访问限制**：仅允许中国大陆 IPv4 访问已开放端口，境外 IPv4 新建连接丢弃；独立 nft 表 `inet netmanager`（fw4 reload 不影响）；订阅链接与 cron 更新计划可自定义；开机 init + WAN hotplug 自愈；旧版 nft 自动降级兼容
7. **设置**：默认目标 IP / 配置备份 / 插件在线更新 / 运行日志排错 / 一键卸载

### DNS 设置（原 luci-app-dnssettings，CBI 标准表单）

8. **DNS 设置**：
   - WAN 口上游 DNS：PPPoE/DHCP 拨号自定义 IPv4/IPv6 DNS，或使用运营商下发（peerdns）
   - LAN 口设备 DNS：通过 DHCP option 6 与 RA 强制下发自定义 DNS，或走路由器缓存
   - dnsmasq 全局转发：统一配置上游解析服务器
   - 配置备份：一键备份当前系统 network/dhcp 配置到 `/root/backup/`
   - 应用配置：一键写入系统并重启 network/dnsmasq/odhcpd
9. **静态 IPv6 分配**：基于 MAC 绑定 hostid/ip6/DUID，自动合并重复条目、在线状态显示、hostid 冲突检测

### 默认 DNS

| 类型 | 主 DNS | 备 DNS |
|------|--------|--------|
| IPv4 | 223.5.5.5 (阿里) | 119.29.29.29 (腾讯) |
| IPv6 | 2400:3200::1 (阿里) | 2402:4e00:: (腾讯) |

---

## 文件结构

```
luci-app-netmanager/
├── files/
│   ├── usr/sbin/
│   │   ├── netmanager                        # 后端核心脚本（防火墙管理，含日志/更新/备份/卸载）
│   │   ├── dnssettings-apply.sh              # DNS 应用配置脚本（独立保留）
│   │   └── dnssettings-backup.sh             # DNS 备份脚本（独立保留）
│   ├── usr/lib/lua/luci/
│   │   ├── controller/netmanager.lua         # LuCI 控制器（菜单+API+multipart上传+DNS动作）
│   │   ├── model/cbi/netmanager/
│   │   │   ├── dns_settings.lua              # DNS 设置 CBI 模型（绑定 /etc/config/dnssettings）
│   │   │   └── dns_staticv6.lua              # 静态 IPv6 分配 CBI 模型（绑定 dhcp.host）
│   │   └── view/netmanager/
│   │       ├── overview.htm                  # 系统概览
│   │       ├── port_forward.htm              # 端口转发
│   │       ├── firewall_rules.htm            # 规则管理
│   │       ├── ssh_log.htm                   # SSH 日志
│   │       ├── access_log.htm                # 访问日志
│   │       ├── settings.htm                  # 设置（备份/更新/运行日志/中国IPv4过滤/卸载）
│   │       ├── common_head.htm               # 公共样式
│   │       └── nav.htm                       # 公共导航（含 DNS 两个入口）
│   ├── etc/config/
│   │   ├── netmanager                        # 防火墙模块配置
│   │   └── dnssettings                       # DNS 模块配置（独立保留）
│   ├── etc/init.d/netmanager-china           # 中国IPv4过滤开机自启
│   └── etc/hotplug.d/iface/95-netmanager-china # WAN上线重应用
├── .github/workflows/build.yml               # GitHub Actions 自动打包
├── install.sh                                # 一键安装脚本（支持 SKIP_UHTTPD_RESTART）
└── README.md
```

---

## 安装方法

### 一键脚本安装（推荐）

iStoreOS 的 `/usr/bin/` 是只读 squashfs 分区，标准 IPK 包无法正常安装，本插件采用 `tar.gz + install.sh` 脚本方式安装。

1. 下载 `luci-app-netmanager-install_*.tar.gz`，上传到路由器 `/tmp` 目录
2. SSH 登录路由器，执行：

```bash
cd /tmp
tar xzvf luci-app-netmanager-install_*.tar.gz
chmod +x install.sh
sh install.sh
```

3. 安装完成后，左侧菜单出现「网络管理」
4. 浏览器按 `Ctrl+Shift+R` 强制刷新页面

### 在线更新

在「设置」页面的「插件更新」区域，上传新的 tar.gz 包进行在线更新（安装成功后延迟 3 秒自动重启 LuCI）。

---

## 命令行用法

安装后可直接使用 `netmanager` 命令：

```bash
# 系统概览
netmanager overview

# 端口转发
netmanager port_list
netmanager port_add <外部端口> <tcp|udp|both> <目标IP> <ipv4|ipv6|both> [内部端口]
netmanager port_del <外部端口> <协议>
netmanager port_edit <旧端口> <旧协议> <新端口> <新协议> <目标IP> <类型> [新内部端口]

# 防火墙规则
netmanager rule_list
netmanager rule_add <名称> <源> <目标> <协议> <端口> <动作> <ipv4|ipv6|any>
netmanager rule_del <索引>
netmanager rule_edit <索引> <名称> <源> <目标> <协议> <端口> <动作> <类型>

# 日志
netmanager ssh_log [条数]
netmanager access_log [筛选端口] [条数]

# 运行日志
netmanager log_set 1|0          # 开启/关闭运行日志（持久化到UCI）
netmanager log_get [行数]       # 查看最后 N 行运行日志
netmanager log_clear            # 清空运行日志

# 设置
netmanager settings
netmanager set_default_target <IP>

# 操作
netmanager restart    # 重启防火墙
netmanager reload     # 重载防火墙

# 备份管理
netmanager backup                    # 立即备份当前配置
netmanager backup_list               # 查看所有备份
netmanager backup_restore <文件名>   # 从备份恢复
netmanager backup_delete <文件名>    # 删除备份

# 插件管理
netmanager upload_file <文件名>      # 上传文件（通过stdin）
netmanager plugin_update <文件名>    # 从上传的包更新插件
netmanager plugin_version <文件名>   # 查看插件包版本信息
netmanager cleanup_uploads           # 清理临时上传文件

# 在线更新（v1.4.1+，从 GitHub Releases 自动检查下载安装）
netmanager update_check              # 检查最新版本（GitHub API → 302重定向两级容错）
netmanager update_apply              # 下载最新 release 资产并自动安装（大小+tar 完整性校验）
netmanager set_update_mirror <url>   # 设置镜像/加速前缀（空=直连），如 https://gh-proxy.com

# 中国IPv4访问限制
netmanager china_filter status                 # 查看状态
netmanager china_filter enable                 # 开启（应用规则 + 装cron + 自启）
netmanager china_filter disable                # 关闭（清规则 + 移cron，保留列表与设置）
netmanager china_filter update                 # 更新IP库并重应用规则
netmanager china_filter set_url <url>          # 自定义订阅链接
netmanager china_filter set_cron "0 4 * * *"   # 自定义更新计划cron

# DNS 设置（命令行方式应用，等价于页面「应用配置」按钮）
/usr/sbin/dnssettings-apply.sh                 # 应用 /etc/config/dnssettings 到系统
/usr/sbin/dnssettings-backup.sh                # 备份 network/dhcp 配置到 /root/backup/

# 卸载插件
netmanager uninstall                # 全删（后端/LuCI/CBI/配置/DNS配置与脚本/CIDR/init/hotplug/nft规则/cron/缓存）
netmanager uninstall keep           # 保留 /etc/config/netmanager、/etc/netmanager/ 与 /etc/config/dnssettings，其余全删
```

---

## 配置说明

### 防火墙模块：`/etc/config/netmanager`

```
config netmanager 'settings'
    option default_target '192.168.31.196'   # 默认转发目标IP
    option log_days '7'                       # 日志保留天数（预留）
    option auto_ban '0'                       # 是否自动封禁 SSH 爆破
    option auto_ban_threshold '5'             # 自动封禁失败次数阈值
    option log_enable '0'                     # 运行日志开关：0关闭 / 1开启
    option china_filter_enable '0'            # 中国IPv4过滤开关：0关闭 / 1开启
    option china_filter_url 'https://metowolf.github.io/iplist/data/special/china.txt'  # IP库订阅链接
    option china_filter_cron '0 3 * * 0'      # 更新计划cron表达式：默认每周日3点
    option china_filter_last_update ''        # 上次成功下载时间
    option china_filter_count '0'             # 当前列表CIDR条数
```

### DNS 模块：`/etc/config/dnssettings`

```
config wan 'wan'          # WAN 口上游 DNS（peerdns / dns1_v4 / dns2_v4 / dns1_v6 / dns2_v6）
config lan 'lan'          # LAN 口下发 DNS（force_dns / dns1_v4 / dns2_v4 / dns1_v6 / dns2_v6）
config dnsmasq 'dnsmasq'  # dnsmasq 全局转发（enable / forward_v4 列表 / forward_v6 列表）
config actions 'actions'  # 操作按钮占位
```

> **DNS 应用原理**：点击「应用配置」后，`dnssettings-apply.sh` 将上述配置写入 `network.wan/wan6`（peerdns/dns/dns6）、`dhcp.lan`（dhcp_option/dns/ra/dhcpv6）与 `dhcp.@dnsmasq[0].server`，然后重启 network/dnsmasq/odhcpd。局域网设备需断开重连网络才能获取新 DNS。

> **中国IPv4过滤原理**：独立 nft 表 `inet netmanager`（与 fw4 分离，fw4 reload 不影响）含 `china_v4` CIDR 集合 + input/forward 两条 base chain(priority -50)，规则 `iifname {wan} ct state new {tcp,udp} ip saddr != @china_v4 drop`。CIDR 列表存 `/etc/netmanager/china_v4.list`，开机 init + WAN 上线 hotplug 自动重应用。兼容新旧 nft：modern(`flags interval, auto-merge` 分片加载) / compat(`flags interval` 单次原子加载 + 逐行回退)。

---

## 卸载

- Web 界面：「设置」页面 →「卸载插件」区块（支持「保留配置」勾选）
- 命令行：`netmanager uninstall [full|keep]`

卸载会完整清理：后端脚本、LuCI 控制器/CBI 模型/视图、init/hotplug、DNS 应用与备份脚本、nft 规则、cron 任务、配置文件。用户在 `/etc/config/firewall` 中的端口转发与防火墙规则不受影响。

---

## 注意事项

1. DNS「应用配置」会重启网络服务，期间会短暂断网
2. 设备端 DNS 有缓存，重连网络后才会拿到新 DNS
3. 如果 WAN 接口名不是 `wan` 或 `wan6`，请在 `dnssettings-apply.sh` 中修改对应接口名
4. DNS 备份文件保存在 `/root/backup/`，防火墙配置备份保存在 `/root/`
5. 更新前建议先备份配置；只支持 `.tar.gz` 或 `.tgz` 格式

## 更新日志

### v1.4.5 (2026-09-04)

**DNS 应用脚本重写（修复空值断网 + 防护体系）**

- **修复空值断网（核心）**：`peerdns=0`（自定义 DNS 模式）但 DNS 字段全空时，旧脚本仍写入 `peerdns='0'` 却不写任何 DNS → 路由器失去全部上游解析直接断网；现该场景**拒绝写入该接口并保持现状**，日志输出 `WARN: ... 跳过（防止断网）` 提示（WAN IPv4 / WAN6 IPv6 / LAN IPv4 / LAN IPv6 四处全部防护）
- **应用前自动备份**：每次「应用配置」自动备份 `network`/`dhcp`/`dnssettings` 三配置到 `/root/backup/dnssettings-auto-*.tar.gz`，仅保留最近 5 份自动备份防堆积（此前备份是独立按钮，用户容易忘按）
- **修复 list 字段错误写法**：`network.wan.dns` / `network.wan6.dns` / `dhcp.lan.dns` 在 UCI 中是 list 类型，旧脚本 `uci set dns="a b"` 是错误写法（会产生含空格的单元素）；现改为 `delete 残留 + 逐个 add_list` 正确写法，切换配置不再残留旧值
- **修复"关闭"不生效**：dnsmasq 全局转发关闭时、LAN 不强制下发时，旧脚本不清除旧 `server`/`dhcp_option`/`dns` 列表 → 关闭后旧 DNS 仍残留下发；现全部清除使关闭真正生效
- **修复无效的 `dns6` 字段**：PPPoE 双栈 fallback 旧脚本写 `network.wan.dns6`——UCI network 无此字段，netifd 不识别等于没设；现改为并入 `network.wan.dns` list（netifd 自动按协议区分）
- **`network restart` 改 `reload`**：应用 DNS 不再重建网络接口，PPPoE 不重拨、LAN 不断网；odhcpd 保持 restart（RA 配置变更需重启进程）
- **输出可观测**：`dns_apply`/`dns_backup` 接口改为捕获脚本完整输出回传页面（含全部 WARN 防护提示），DNS 设置页顶部新增防护行为说明文案

### v1.4.4 (2026-09-04)

**安全修复**

- **修复上传文件名路径穿越**：`upload_file` 的 `filename` 参数此前可传 `../../etc/xxx` 之类值让 root 写任意路径；现拒绝路径分隔符并强制 `basename`，base64 解码与复制全部失败时明确报错（此前静默失败）
- **修复插件包 tar 路径穿越（RCE 链）**：BusyBox tar 解压不剥离 `../` 成员，恶意/被劫持的插件包可覆盖系统任意文件；`plugin_update` / `plugin_version` 解压前新增成员预检（`tar tzf` 列表校验，拒绝 `../` 段与绝对路径成员）
- **修复 SSH 登录日志存储型 XSS**：攻击者可控制的 SSH 用户名/来源 IP 此前直接拼 innerHTML；现在所有字段（用户名/IP/原因/时间）写入前全部 HTML 转义，分节解析改按行首标记匹配
- **前端全量输出转义**：新增公共 `escapeHtml()`（common_head.htm），全部 25 处命令结果 `+ data +` 拼接及各表格单元格动态内容均改为转义后输出；`editRule`/`editPort` 改为数组下标传参，杜绝 UCI 自由文本注入 onclick
- **API 强制 POST**：控制器 `api_handler` 拒绝非 POST 请求（返回 405），阻断 `<img src="...?action=uninstall">` 类跨站 GET 触发

**逻辑修复**

- **修复 `rule_add` 覆盖最后一条规则**：`uci set firewall.@rule[-1].xxx` 不会创建节点，此前所有新增规则字段全部落到最后一条既有规则上（覆盖破坏）；现先 `uci add firewall rule` 再 set
- **修复端口转发编辑跨 IP 版本切换规则凭空消失**：`port_edit` 从 IPv4 切到 IPv6（或反向）此前只删旧规则不建新规则；现删除后按新参数补建完整的 DNAT redirect / IPv6 放行 rule
- **修复 fw4 空 proto 语义错误**：fw4 中 `proto` 缺省 = tcp+udp（both）而非 tcp；新增 `proto_match` 匹配函数，端口删除/编辑的查重不再误将 both 条目当成 tcp 处理（此前 `port_del 8080 tcp` 会误删 both 条目）
- **修复 IPv6 放行范围过宽**：`port_add` IPv6 分支此前缺 `dest_ip`，放行整个 LAN 网段而非目标单机；现与 IPv4 DNAT 语义对称，仅放行到指定目标
- **修复规则遍历提前截断**：以 `name` 字段存在性作为 redirect/rule 遍历终止判据（8 处）会漏掉系统自带的无名规则；改用 `uci -q get firewall.@xxx[$idx]` 节点存在性判断
- **`port_edit` 协议归一**：`both` 输入自动转为 fw4 合法单值 `tcpudp`

### v1.4.3 (2026-09-04)

- **修复静态 IP 分配模块：在线客户端识别补全 IPv6**。旧版仅读 `/tmp/dhcp.leases` 与 ARP 表（纯 IPv4），现在交叉关联 4 个数据源：dnsmasq 租约（IPv4/主机名/clientid）、`/proc/net/arp`（静态设备）、odhcpd 租约（DUID/DHCPv6 地址）、`ip -6 neigh` NDP 邻居表（**覆盖 SLAAC 隐私地址**）
- 「当前在线IP」列同时显示 IPv4 + 全部全局 IPv6 + 在线捕获的 DUID；租约存在不再误判为在线（以 ARP 完成态 / NDP 邻居为准）
- **新增「在线客户端」速览区**：列出所有在线设备（含未绑定设备）的 MAC / 主机名 / IPv4 / IPv6 / 绑定状态，可直接复制 MAC 到下方新增绑定
- **修复幽灵条目**：MAC 与 DUID 均为空的条目在保存时自动清理；此前只填部分字段的条目会从列表消失但残留在 UCI 中，无法再编辑删除
- **修复 hostid 冲突检测快照失效**：改为实时遍历 UCI 查重，同一批提交的 MAC / IPv4 / 完整 IPv6 / hostid 互相冲突均可拦截；新增 IPv4 与完整 IPv6 地址查重（旧版完全没有）
- **DUID 改为可编辑**：自动去冒号规范化存储（odhcpd `unheximize` 仅认无冒号 hex，带冒号会解析错乱）；支持 MAC+DUID 至少填其一的 IPv6-only 绑定
- ARP / NDP 过滤 WAN 侧条目（上游网关不再混入设备列表）；dnsmasq 由 restart 改为 reload，保存后 DNS 不再短暂中断

### v1.4.2 (2026-09-04)

- **修复：端口转发支持外部端口与内部端口不一致映射**（如外部 80 → 内部 8080）。此前后端将 `dest_port` 硬编码为外部端口，内外只能同端口
- 页面「添加端口转发」与「编辑」表单新增**内部端口**输入框，留空则与外部端口一致（兼容旧用法）
- 命令行 `port_add` / `port_edit` 新增可选内部端口参数（置于末位，旧命令行为不变）
- 内部端口格式校验：仅允许数字或横线范围（`8080` / `1000-2000`），冒号自动转横线
- IPv6 放行规则不受影响（放行无 DNAT，端口不变）；命中数统计仍按外部端口计数

### v1.4.1 (2026-09-03)

- **新增「在线更新」功能**：设置页新增「在线更新」区块，一键从 GitHub Releases（`District1655/luci-app-netmanager`）检查并安装最新版
- **检查两级容错**：优先 GitHub API + `jsonfilter` 解析最新 tag 与资产 URL；API 不可达时自动降级用 `/releases/latest` 的 302 Location 头解析 tag（无需 API，直连受限场景仍可用）
- **`netmanager update_apply`**：自动下载最新 `luci-app-netmanager-install_*.tar.gz`（wget / uclient-fetch / curl 依次兜底），下载后做**大小校验 + tar 完整性预检**（杜绝半截包/错误页进入安装），再复用 plugin_update 流程安装（解压 + install.sh + 延迟重启 uhttpd）
- **镜像加速可配置**：`netmanager set_update_mirror <url>` 或设置页输入框，检查与下载 URL 均自动拼接加速前缀（如 `https://gh-proxy.com`），应对 GitHub 直连受限
- **语义化版本比较**：major.minor.patch 数值比较，仅提示升级不误报降级；版本号统一收敛到后端 `PLUGIN_VERSION` 变量（`netmanager version` / 在线更新共用）
- UI：设置页显示当前版本/最新版本/更新状态，检查与更新按钮带禁用态与结果展示

### v1.4.0 (2026-09-02)

- **合并 luci-app-dnssettings (v1.2.1)**：新增「DNS设置」「静态IPv6分配」两个子页面（CBI 标准表单），统一入口到「网络管理」菜单
- DNS 配置 `/etc/config/dnssettings` 与应用/备份脚本独立保留，老用户已有配置无损保留
- 原 `fwmanager` 全部命令/配置/路径统一更名为 `netmanager`（命令 `netmanager`、配置 `/etc/config/netmanager`、日志 `/tmp/netmanager/`、nft 表 `inet netmanager`、CIDR 目录 `/etc/netmanager/`）
- `netmanager uninstall` 卸载流程增加 DNS 模块清理（CBI 模型 / dnssettings 配置 / apply-backup 脚本）
- install.sh 扩展为 7 步安装（新增 DNS 脚本、CBI 模型、dnssettings 配置）

### 继承自 luci-app-fwmanager v1.3.33

- 中国 IPv4 访问限制（独立 nft 表 / 旧版 nft 自动降级 / 订阅与 cron 自定义 / init + hotplug 自愈）
- 一键卸载插件、运行日志排错、配置备份恢复、插件在线更新、性能优化（nft dstnat 链缓存）

## 许可证

MIT License
````

> 第 5 章结束。以下为第 6 章起的手写章节。

---

## 第 6 章 更新维护记录

### 6.1 提交历史（基线 90b2bf9，全 13 commit）

| commit | 日期 | 版本 | 摘要 |
|--------|------|------|------|
| 743c1e8 | 2026-09-02 | v1.4.0 | 合并 fwmanager + dnssettings 为 netmanager |
| fa21ed8 | 2026-09-03 | v1.4.1 | 在线更新功能（检查/安装/镜像加速） |
| b9dfaa6 | 2026-09-04 | v1.4.2 | 端口转发内外端口映射 |
| 05eff5b | 2026-09-04 | v1.4.3 | 静态 IPv6 模块：IPv6 在线识别+幽灵条目+冲突检测 |
| 65ee03f | 2026-09-04 | — | settings footer 版本号补齐 v1.4.3（审查遗漏修复） |
| fde25ca | 2026-09-04 | v1.4.4 | 紧急安全与逻辑修复包（15 处） |
| aad4460 | 2026-09-04 | — | 补 v1.4.4 更新日志段落 |
| dcfeecd | 2026-09-04 | — | CI Release body 自动提取 README 更新日志 |
| d3bfcc4 | 2026-09-04 | v1.4.5 | DNS 应用脚本重写（空值断网防护） |
| 686582f | 2026-09-04 | — | CI 修复：Release 提取 v 前缀不匹配 |
| fc62f27 | 2026-09-04 | — | docs: 项目全景文档 PROJECT.md + 源码嵌入生成脚本 |
| 90b2bf9 | 2026-09-04 | — | fix: ucode LuCI 两处线上问题（静态IPv6页崩溃 + CBI页缺页内导航） |
| （后续） | — | — | 待提交：PROJECT.md 同步更新 + 生成脚本 24 文件化 |

### 6.2 各版本要点

**线上紧急修复（2026-09-04，commit 90b2bf9，用户实机报障）**

用户在 iStoreOS 24.10（ucode 版 LuCI）实机使用中发现两个问题：

1. **静态 IPv6 分配页崩溃**（Runtime error: `attempt to call method 'get_first' (a nil value)`）
   - 根因：`dns_staticv6.lua` 使用 `uci:get_first()`，该方法仅存在于原生 libuci-lua；ucode 版 LuCI 中 Lua CBI 经 ucodebridge 桥接执行，桥接的 uci cursor 无此扩展方法（foreach/get/set/commit 桥接支持，同函数上方 merge_duplicate_hosts 已成功执行佐证）
   - 修复：新增局部函数 `first_opt()`，用 `uci:foreach` 遍历取第一个非空值实现同语义；不依赖回调 return false 中止语义（桥接环境最大兼容）；默认路径 /tmp/dhcp.leases 兜底不变
   - 排查确认：全项目仅此 2 处 get_first，无其他 libuci-lua 独有 API
2. **DNS 设置页进入后页内导航消失**
   - 根因：DNS设置/静态IPv6 是 CBI 框架渲染页面，不含自绘视图的 nav.htm 页内导航条；从自绘页面（带 8 页签）进入 CBI 页后页签全部消失，观感为"菜单丢失"
   - 修复：新建 `view/netmanager/cbi_nav.htm`（自带内联样式，CBI 页不加载 common_head.htm 不能依赖外部样式类；active 判断带 nil 防护），两个 CBI 模型以 `m:append(Template("netmanager/cbi_nav"))` 注入（Template 节点在 luci-compat cbi.lua 为标准节点，已查证源码）
   - install.sh 文案 8→9 个文件同步

**v1.4.0（2026-09-02）合并**

- luci-app-fwmanager v1.3.33 + luci-app-dnssettings v1.2.1 合并为 luci-app-netmanager
- 全路径统一更名：命令 netmanager、配置 /etc/config/netmanager、日志 /tmp/netmanager/、nft 表 inet netmanager、CIDR 目录 /etc/netmanager/
- install.sh 扩展 7 步，uninstall 增加 DNS 模块清理

**v1.4.1（2026-09-03）在线更新**

- update_check：GitHub API + jsonfilter，失败降级 302 Location 解析（直连受限可用）
- update_apply：三工具兜底下载 + 大小校验 + tar 完整性预检 + plugin_update 流程
- set_update_mirror 镜像加速；语义化版本比较；版本号收敛 PLUGIN_VERSION

**v1.4.2（2026-09-04）端口映射**

- port_add/port_edit 新增内部端口参数（外部 80 → 内部 8080）；冒号自动转横线；命令行旧用法兼容

**v1.4.3（2026-09-04）静态 IPv6**

- 在线识别四数据源交叉：dnsmasq 租约 + /proc/net/arp + odhcpd 租约（DUID）+ ip -6 neigh（覆盖 SLAAC 隐私地址）
- 新增「在线客户端」速览区；幽灵条目自动清理；冲突检测改实时遍历（MAC/IPv4/完整 IPv6/hostid 互斥查重）；DUID 可编辑规范化；dnsmasq restart→reload

**v1.4.4（2026-09-04）安全修复包（15 处）**

- 上传文件名路径穿越（强制 basename）；插件包 tar 成员预检（拒 ../与绝对路径，断 RCE 链）；SSH 日志存储型 XSS 全字段转义
- 前端全量输出转义：公共 escapeHtml()，25 处拼接改转义；editRule/editPort 改数组下标传参
- API 强制 POST（405）；rule_add 先 uci add 再 set（修复覆盖最后一条）；port_edit 跨 IP 版本切换补建规则；fw4 proto 语义（proto_match）；IPv6 放行补 dest_ip；遍历终止判据改节点存在性（8 处）

**v1.4.5（2026-09-04）DNS 应用重写**

- 空值断网核心防护（peerdns=0 且 DNS 全空 → 拒写保持现状，四场景全覆盖）
- 应用前自动备份（保留 5 份）；list 字段正确写法（delete+add_list）；关闭时清除残留；无效 dns6 字段并入 dns list；network restart→reload；输出可观测（WARN 回传页面）

### 6.3 发版流程（标准操作）

```
1. 修复/开发完成，工作区干净
2. 升 13 处版本号（位置见 6.4）
3. README 更新日志段新增对应小节（CI 从此提取 Release body）
4. git add -A && git commit -m "fix: v1.4.6 xxx"
5. git push（SSH）
6. CI（build.yml）：从 README 头部 > 版本：vX.Y.Z 提取 tag → 打 tag →
   打包 luci-app-netmanager-install_<ver>.tar.gz → 创建 Release（body 自动提取）
7. 路由器设置页 update_check 验证升级链路
```

### 6.4 版本号登记处（13 处，发版必改）

| # | 文件 | 位置 |
|---|------|------|
| 1 | files/usr/sbin/netmanager | L15 PLUGIN_VERSION（唯一权威源） |
| 2 | install.sh | L3 注释 |
| 3 | install.sh | L8 VERSION 变量 |
| 4-9 | 6 个视图 footer | overview/port_forward/firewall_rules/ssh_log/access_log/settings 各页脚 |
| 10 | settings.htm | L101 |
| 11 | settings.htm | L202 |
| 12 | common_head.htm | L75 附近注释 |
| 13 | README.md | L3 `> 版本：vX.Y.Z`（CI 提取源） |

**不要动的版本号**（有意保留的历史记录）：

- files/usr/sbin/dns_staticv6.lua L1 头注释版本
- .github/workflows/extract_changelog.awk 注释中的版本

### 6.5 维护节奏约定

- 修复轮发版：收集一轮问题 → 批量修复 → 一次 commit + tag（如 v1.4.4 15 处一包）
- 更新日志：每个版本必须写 README 小节（漏写会导致 Release body 为空，v1.4.4 曾发生，aad4460 补救）
- 发版后验证：GitHub Release 页面 + 路由器在线更新两处检查

---

## 第 7 章 开发计划

### 7.1 v1.4.6 修复总清单（✅ 已于 2026-09-04 全量实施完毕，发版 v1.4.6）

> 来源标注：[审] = 本人第二轮审查 29 项；[豆] = 豆包报告发现；[双] = 双方一致。
> 优先级 P0（供应链 RCE）> P1（安全/正确性）> P2（健壮性）> P3（工程化）。
> **状态**：v1.4.6 已全部落地（P3-1 模块化拆分、P3-7 RFC1918 精确匹配、P3-12 批量 commit 推迟 v1.5+，见 7.3）。

#### P0 供应链 RCE（1 项）✅ 已修

| # | 问题 | 位置 | 来源 | 修复状态 |
|---|------|------|------|---------|
| P0-1 | 在线更新镜像无白名单 + 无 sha256 校验：镜像 URL 可指向任意服务器，下载包仅大小+tar 校验即 root 执行 install.sh | netmanager L1495/L1502-1505 | [双] | ✅ mirror_check 域名白名单（MIRROR_HOST_ALLOWLIST，拒绝裸 IP）+ cmd_update_check 输出 SHA256_URL + cmd_update_apply sha256 校验（mismatch 即放弃）+ CI 生成 .sha256 资产 |

#### P1 安全/正确性（12 项）✅ 已修

| # | 问题 | 位置 | 来源 | 修复状态 |
|---|------|------|------|---------|
| P1-1 | backup_list 渲染零转义（b[0] 直拼 innerHTML + onclick 自由文本） | settings.htm L421-429 | [审] | ✅ escapeHtml + window.BACKUP_ROWS 数组下标传参 |
| P1-2 | delPort onclick 仍传自由文本（escapeHtml 在 onclick 属性上下文无效，&#39; 还原为 '） | port_forward.htm L104/L110 | [审] | ✅ delPort 改数组下标传参（window.PORT_ROWS） |
| P1-3 | china 状态 lu/cnt/devs 三处未转义 | settings.htm L535-536 | [审] | ✅ 补 escapeHtml |
| P1-4 | CSRF Token 缺失：跨站 form POST 可带 cookie 触发 API | controller 全局 | [豆] | ✅ csrf_token()（sid 派生 sha256）+ csrf_check() 403 + common_head 注入 + apiFetch/nmFetch 自动携带 |
| P1-5 | dns_apply/dns_backup 为 GET 路由，刷新即重复执行 | controller L20-21 | [审] | ✅ 并入 api_handler POST action；dns_settings.lua 按钮改执行脚本+m.message alert |
| P1-6 | 页面 GET 加载即执行 merge_duplicate_hosts + uci commit | dns_staticv6.lua L207-217 | [审] | ✅ detect（只读检测）+ do_merge 挪 on_before_commit |
| P1-7 | port_edit both→v6 切换产生重复 IPv6 规则（break 2 跳过 rule 循环） | netmanager L508-521 | [审] | ✅ 修正循环跳出逻辑，切换时删旧建新 |
| P1-8 | name 含 \| 时 port_list/rule_list 输出错位 | netmanager 列表输出 | [审] | ✅ name 字符白名单过滤 |
| P1-9 | tar_list_check 不防 symlink 成员（xxx → /etc/shadow） | netmanager L68-86 | [审] | ✅ 预检拒绝 symlink 成员（tar -tv 首字符 l） |
| P1-10 | china_load_set 分片失败静默继续 → 未加载 CIDR 误杀国内流量 | netmanager L1736-1761 | [审] | ✅ 分片失败即中止并回滚，日志 WARN |
| P1-11 | upload_file 无大小上限（tmpfs OOM）+ .b64_<秒级> 同秒冲突 | netmanager upload_file / controller L294 | [审][豆] | ✅ 50MB 上限 + 时间戳+随机数防同秒冲突 |
| P1-12 | uninstall rm -rf /tmp/luci-sessions 踢掉所有登录用户 | netmanager L2141 | [豆] | ✅ 仅清 indexcache/modulecache |

#### P2 健壮性（10 项）✅ 已修

| # | 问题 | 位置 | 来源 | 修复状态 |
|---|------|------|------|---------|
| P2-1 | dhcp_option 写单值与注释矛盾（应 delete+add_list） | dnssettings-apply.sh L145 | [审] | ✅ list 化写入 |
| P2-2 | controller 以 out:match("ERROR:") 判成败 | controller L34/L48 | [审] | ✅ DNS 动作 __RC__ 退出码捕获 |
| P2-3 | 30+ 处裸 fetch 无超时/会话过期处理；withBusy 死代码 | 各视图 | [审] | ✅ 统一 apiFetch/nmFetch（超时+403+会话过期） |
| P2-4 | china_cron_install 不校验 cron 格式（set_cron 已校验，读 UCI 无二次校验） | netmanager L1920-1926 | [审] | ✅ 装载前复用 set_cron 同款校验 |
| P2-5 | uninstall 不删 install.sh L32 的 /bin/netmanager 符号链接 | netmanager uninstall | [审] | ✅ 卸载时 rm -f /bin/netmanager |
| P2-6 | WAN 接口名硬编码 network.wan/wan6 | dnssettings-apply.sh L68/L97 | [豆] | ✅ detect_wan_iface 三级探测（用户配置→默认路由反查→兜底） |
| P2-7 | PPPoE 双栈 fallback 未去重即 add_list | dnssettings-apply.sh L120-132 | [豆] | ✅ delete 全量重写 + ADDED_DNS 去重 |
| P2-8 | 上传文件未 chmod 600 | netmanager upload_file | [豆] | ✅ 落盘后 chmod 600 |
| P2-9 | arg() 在 controller 4 处重复定义 | controller L139/L164/L183/L202 | [豆] | ✅ 提取模块级函数 |
| P2-10 | update_http_get/china_download/cmd_update_apply 三处下载逻辑重复 | netmanager | [豆] | ⏳ 推迟 v1.5（与 P3-1 模块化拆分一并处理，避免本轮改动面过大） |

#### P3 工程化/小项（12 项）

| # | 问题 | 来源 | 处置 |
|---|------|------|------|
| P3-1 | 后端单文件 90KB 2200 行，模块化拆分（port.sh/rule.sh/china.sh/update.sh） | [豆] | ⏳ **v1.5+ 处理**（见 7.3） |
| P3-2 | CI 增加 sh -n / luac -p / shellcheck / 产物校验 | [豆] | ✅ sh -n + luac -p 门禁 + tar tzf 产物预检 + Release sha256（shellcheck 推 v1.5） |
| P3-3 | LICENSE 文件缺失（README 声明 MIT 无文件） | [审] | ✅ 已创建 LICENSE（MIT） |
| P3-4 | DUID 长度校验两处不一致（8-64 vs 4-130）；DHCPv4 clientid 误判 DUID | [审] | ✅ 统一 4-130 + 排除 MAC 原文型/01+MAC 硬件型伪 DUID |
| P3-5 | dns_staticv6 WAN 过滤 ^wan 漏 pppoe-wan | [审] | ✅ is_wan_side 覆盖 pppoe-wan/wan-eth 等命名 |
| P3-6 | on_after_commit 无差别 restart odhcpd | [审] | ✅ 仅 self.changed 时 restart |
| P3-7 | overview grep -v '172\.'/192.168 误伤公网 IP | [审] | ⏳ 推迟 v1.5（显示优化，非安全问题） |
| P3-8 | port_del L617/L643 与 rule_list L679 死代码 | [审] | ⏳ 推迟 v1.5（无功能影响） |
| P3-9 | nav.htm 与 controller 双维护 | [审] | 接受现状，已记录到注意事项 |
| P3-10 | logger 控制字符未过滤 | [豆] | ✅ tr -d 控制字符 |
| P3-11 | 备份文件未显式 chmod 600 | [豆] | ✅ 已补权限 |
| P3-12 | uci set 未批量 commit | [豆] | ⏳ 推迟 v1.5（与模块化一并梳理） |

#### 已完成（2026-09-04 线上报障修复，commit 90b2bf9）

| 问题 | 来源 | 状态 |
|------|------|------|
| ucode LuCI 兼容：dns_staticv6 用 uci:get_first（桥接无此方法）页面崩溃 | [线上实机] | ✅ 已修：first_opt 用 foreach 实现同语义 |
| CBI 页面（DNS设置/静态IPv6）无页内导航，进入后页签消失 | [线上实机] | ✅ 已修：新增 cbi_nav.htm + Template 节点注入两个 CBI 模型 |

### 7.2 实施记录（v1.4.6，2026-09-04 已全部完成）

| 批次 | 内容 | 对应项 | 状态 |
|------|------|--------|------|
| 1（安全核心） | 镜像白名单+sha256、CSRF Token、3 处转义补漏、tar symlink、dns_apply POST 化 | P0-1、P1-1/2/3/4/5/9 | ✅ |
| 2（正确性） | port_edit 重复规则、name 过滤、china 分片中止、上传大小+时间戳、dhcp_option list 化 | P1-7/8/10/11、P2-1 | ✅ |
| 3（健壮性） | 退出码判定、apiFetch 统一、cron 校验、卸载清链接+不删 sessions、WAN 探测、chmod 600 | P1-12、P2-2/3/4/5/6/8 | ✅ |
| 4（小项+文档） | P3 小项 + LICENSE + CI 增强 | P3-2~12 | ✅（除推迟 v1.5 的 4 项） |

### 7.3 v1.5+ 路线图

1. **后端模块化拆分**（P3-1 + P2-10）：netmanager 单文件拆为 main + port/rule/china/update/backup 模块，公共 HTTP 下载函数合并，install.sh 同步调整
2. **CI 质量门禁增强**：shellcheck 加入门禁
3. **ipk 双形态交付**：保留 tar.gz 主线，增加标准 ipk（非 squashfs 只读分区设备可用）
4. **LuCI 主分支适配评估**：JS 界面（client controller）迁移调研
5. **单元测试可行性调研**（OpenWrt shell 单测框架选型）
6. **次要修复积压**：P3-7 RFC1918 精确匹配、P3-8 死代码清理、P3-12 uci 批量 commit

---

## 第 8 章 注意事项

### 8.1 设计约束（为什么这样设计）

1. **非 ipk 安装**：iStoreOS /usr/bin/ 只读 squashfs，ipk 无法安装 → tar.gz + install.sh 方案
2. **独立 nft 表**：fw4 reload 重建 fw4 表会清用户链 → 中国过滤用独立 inet netmanager 表
3. **tar.gz 包成员预检**：BusyBox tar 不剥离 ../，必须 tar tzf 预检（v1.4.4 已建防护）
4. **双维护**：nav.htm 与 controller 菜单新增页面需两处同步
5. **CBI vs 自绘**：DNS 两页用 CBI（LuCI 原生表单/校验/无自研 JS）；防火墙页自绘 htm（灵活交互）
6. **退出码缺失**：后端 POSIX sh 无统一退出码约定 → controller 靠 ERROR: 前缀判断（待改造）

### 8.2 环境陷阱（开发机 Windows + PowerShell 5.1）

| 陷阱 | 对策 |
|------|------|
| PowerShell 不支持 && | 分步执行或写 .ps1/.sh 脚本文件 |
| 命令含中文引号会破坏解析器 | 复杂命令一律写脚本文件再执行 |
| sed 内联表达式引号被吞 | 先写 .sed 脚本文件再 sed -i -f |
| bash/sed/grep 不在 PATH | 用全路径：C:\xm\PortableGit\bin\bash.exe、usr\bin\ 下 GNU 工具 |
| CRLF 警告 | .gitattributes 强制 LF，警告可忽略 |
| Edit 工具前必须 Read 目标区域 | 严格 mtime 检测 |
| 多轮编辑同一文件后"假成功" | 必须 git diff 全量核对关键段落（v1.4.4 事故教训） |

### 8.3 编码与提交规范

- UTF-8 无 BOM + LF；shell 用 tab 缩进无 bashism（BusyBox ash 兼容）
- Lua 遵循 LuCI 官方风格（tab 缩进）
- 用户可见字符串 translate()/_() 包裹（当前中英文硬编码待 i18n 改造）
- commit 格式：`fix: v1.4.6 xxx` / `feat: xxx` / `docs: xxx` / `ci: xxx`
- **禁止**：git config 修改、--amend（除非用户明确要求）、force push

### 8.4 安全红线（改动必读）

1. **所有拼 shell 命令的参数必经 shell_escape**（controller L56-64），新增 API 动作时不得绕过
2. **API 强制 POST**（L115），新增路由必须 POST-only + 白名单 action
3. **所有动态内容写入 DOM 前必须 escapeHtml**，onclick 传参改数组下标（属性上下文转义无效）
4. **tar 成员预检不可省**：../ 与绝对路径拒绝（v1.4.4 RCE 链修复）
5. **上传文件名强制 basename**（路径穿越修复）
6. **DNS 空值防护不可移除**（v1.4.5 断网防护核心）：peerdns=0 且 DNS 全空 → 拒绝写入
7. **uninstall keep 模式语义**：保留 /etc/config/netmanager、/etc/netmanager/、/etc/config/dnssettings，其余全删——新增安装产物时同步更新 uninstall 清理清单与 keep 保留清单
8. **新增安装产物三处同步**：install.sh 复制清单 + uninstall 清理清单 + 仓库 files/ 目录

### 8.5 排错路径速查

| 症状 | 检查顺序 |
|------|---------|
| 页面 500 | logread -e uhttpd / uhttpd 日志 → controller Lua 语法 → view 文件名拼写 |
| API 返回异常 | 浏览器 F12 Network 看原始响应 → controller api_handler 分支 → 手动 netmanager <action> 复现 |
| 按钮/数据不显示 | view JS console 报错 → API_URL 路径 → 输出格式约定（管道符/ERROR:） |
| 端口转发不生效 | netmanager port_list → uci show firewall | grep -A5 netmanager → nft list chain inet fw4 dstnat → fw4 check |
| 中国过滤不生效 | netmanager china_filter status → nft list set inet netmanager china_v4 → /etc/netmanager/china_v4.list 行数 → logread -e netmanager-china |
| DNS 应用后断网 | /root/backup/ 自动备份恢复 → dnssettings-apply.sh WARN 日志 → uci show network.wan（检查 peerdns/dns） |
| 在线更新失败 | set_update_mirror 检查镜像 → wget 手动下载测速 → tar tzf 完整性 → install.sh 日志 |
| 上传后无反应 | ls -l /tmp/netmanager/upload/ → cleanup_uploads → F12 看上传请求状态码 |

### 8.6 与 iStoreOS/OpenWrt 兼容性

- 适配 fw4/nftables（OpenWrt 22.03+）；旧 iptables 不支持（fw3 时代不可用）
- BusyBox ash 兼容：脚本无 bashism，wget/uclient-fetch/curl 三工具兜底下载
- jsonfilter 依赖（update_check API 解析），系统默认自带
- LuCI Lua 版（23.05 Lua controller 架构）；OpenWrt 主分支 JS 化迁移评估在 v1.5+ 路线

---

## 第 9 章 快速索引（行号定位表）

> 行号基于 v1.4.5 + 线上修复基线（commit 90b2bf9）。大改动后需同步更新本表。

### 9.1 后端 netmanager（2197 行）

| 功能区 | 行号 |
|--------|------|
| PLUGIN_VERSION / 头部配置 | L1-36 |
| proto_match / tar_list_check | L37-86 |
| load_config / overview | L87-362 |
| port_list / port_add/edit/del | L363-772 |
| rule_list / rule_add/edit/del | L573-772 |
| ssh_log | L773-829 |
| access_log | L831-1001 |
| restart / reload / backup 系 | L1003-1080 |
| upload_file / plugin_update / plugin_version / cleanup_uploads | L1082-1323 |
| update_check / update_apply / set_update_mirror | L1325-1573 |
| log_set / log_get / log_clear | L1575-1612 |
| settings / version | L1575-1612 |
| china 全系（get_wan_devs / create_set / load_set / apply_rules / clear / download / cron / status / set_url / set_cron / enable / disable / update / boot） | L1614-2052 |
| cmd_uninstall | L2059-2143 |
| usage / 主入口 case | L2145-2197 |

### 9.2 controller/netmanager.lua（353 行）

| 功能区 | 行号 |
|--------|------|
| entry() 菜单/路由注册 | L1-35 |
| action_dns_apply / action_dns_backup | L29-53 |
| shell_escape | L56-64 |
| setup_upload_handler（multipart 解析） | L82-110 |
| api_handler（强制 POST L115） | L112-365 |
| arg() 4 处重复定义 | L139/L164/L183/L202 |
| upload_file 分支（.b64_<秒>） | L284-303 |

### 9.3 视图 settings.htm（620 行）

| 功能区 | 行号 |
|--------|------|
| footer 版本号 | L101/L202 |
| API_URL + loadSettings | L236-260 |
| listBackups（b[0] 直拼待修） | L396-435 |
| restoreBackup / deleteBackup | L443-467 |
| loadChinaStatus（未转义待修） | L512-555 |
| saveChinaUrl / saveChinaCron | L564-586 |
| enable/disable/updateChinaFilter | L595-622 |
| uninstallPlugin | L624-655 |

### 9.4 其余文件关键行号

| 文件 | 功能区:行号 |
|------|------------|
| dnssettings-apply.sh | 空值防护: 全文贯穿；dhcp_option 待修: L145；WAN 硬编码待修: L68/L97；PPPoE fallback 待去重: L120-132 |
| dns_staticv6.lua | get_online_devices: L32-166（v1.4.6 已修 get_first→first_opt: L45-54）；merge_duplicate_hosts: L171-216；页面加载即执行待修: L221；cbi_nav 注入: L290；on_before_commit: L293；on_after_commit: L308；DUID 校验: L469-481 |
| cbi_nav.htm | CBI 专用导航（v1.4.6 新增）：L9-12 requestpath nil 防护；L13-18 内联样式 |
| dns_settings.lua | cbi_nav 注入: L14-16；按钮 redirect: L111-124 |
| port_forward.htm | delPort onclick 待修: L104/L110；editPort 已修: L143-157 |
| common_head.htm | escapeHtml/apiFetch/withBusy: L74-155 |
| install.sh | 符号链接 /bin/netmanager: L32；版本: L3/L8 |
| build.yml | tag 提取 README 头部: 全局；产物命名: 全局 |
| README.md | 版本行: L3；更新日志: L227-302 |

---

## 附录 A：项目信息卡

| 项 | 值 |
|----|----|
| 仓库 | District1655/luci-app-netmanager |
| 分支 | main |
| 基线 commit | 90b2bf9（代码）/ 本文档随后提交 |
| 版本 | v1.4.5 + 线上修复（2026-09-04） |
| 受控文件 | 24 个 |
| 代码量 | 约 6,000 行（含文档） |
| CI | GitHub Actions（tag 触发打包+Release） |
| 推送方式 | SSH |
| 文档生成 | 本文档由脚本自动嵌入源码 + 手写章节（生成时间见头部） |

## 附录 B：文档维护约定

1. **发版时**：第 6 章新增版本小节 + 6.1 表格加行 + 6.4 版本号登记表核对
2. **大改动时**：第 9 章行号表同步更新；涉及源码全录需重新嵌入时，运行生成脚本 `docs/gen_source_part.sh`（详见脚本头部注释）
3. **修复待办时**：第 7 章清单状态更新（修完移到第 6 章对应版本小节）
4. **本文档随仓库维护**：作为项目单一查阅入口提交至仓库。源码全录（第 5 章）与源码文件天然冗余，但冗余是**有意的**——保证查阅者无需跳转即可在一处看到全部源码 + 维护要点；发版前如源码有改动，请重新嵌入以保持第 5 章与 HEAD 一致
