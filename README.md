# 网络管理插件 (luci-app-netmanager)

> 版本：v1.8.15
>
> 适配：iStoreOS 25.12+（apk）/ iStoreOS 24.10 及 OpenWrt 23.05+（opkg / ipk），fw4 + nftables，Lua LuCI
>
> 交付：**apk / ipk 双格式** + iStoreOS 软件中心上架 + `tar.gz` 一键脚本兜底
>
> 由 **luci-app-fwmanager**（防火墙管理）与 **luci-app-dnssettings**（上网设置）合并而成的网络管理一体化 LuCI 插件。

一站式管理路由器网络：端口转发、防火墙规则、SSH/访问日志、中国 IPv4/IPv6 访问限制、手动黑名单、WAN/LAN 口上网方式与双栈 DNS 统一管理、静态 IP 分配（IPv4/IPv6）、配置备份恢复、插件在线更新、一键卸载。

## 安装方式速览

| 系统 | 包格式 | 安装方式 |
|------|--------|----------|
| iStoreOS 25.12+（apk-tools，无 opkg） | `.apk` | 软件中心搜「网络管理」安装，或 `apk add --allow-untrusted luci-app-netmanager-<ver>-r<rel>.apk` |
| iStoreOS 24.10 / OpenWrt 23.05–24.10（opkg） | `.ipk` | `opkg install luci-app-netmanager_<ver>-r<rel>_all.ipk` |
| 任意（含未适配架构 / 开发机） | `.tar.gz` | 解压后 `sh install.sh` 脚本安装 |

三种方式装完效果一致（菜单「网络管理」，入口 `/cgi-bin/luci/admin/netmanager`）。包均随 Release 发布，文件名带版本与 release 号。

---

## 功能模块

### 防火墙管理（原 luci-app-fwmanager）

1. **系统概览**：防火墙状态 / 端口统计 / 网络信息 / 快捷操作
2. **端口转发管理**：IPv4 / IPv6 DNAT 端口映射统一管理，支持 TCP/UDP/双协议、单端口与端口范围；「IPv6 端口放行（直连）」区独立展示直连放行规则（转发是转发，放行是放行），自动配套规则随映射增删与前缀跟随，支持启用/禁用
3. **防火墙规则管理**：自定义通信规则增删改 + 常用模板一键应用 + 源IP/目的IP 粒度列；IPv6 端口放行规则不在此页（归端口转发页「IPv6 端口放行」区）
4. **SSH 登录日志**：成功/失败记录 + 失败 IP 排行 Top 10 + 自动刷新
5. **端口访问日志**：活跃连接 / 入站出站计数 / 拦截统计
6. **中国 IPv4 访问限制**：仅允许中国大陆 IPv4 访问已开放端口，境外 IPv4 新建连接丢弃；独立 nft 表 `inet netmanager`（fw4 reload 不影响）；订阅链接与 cron 更新计划可自定义；开机 init + WAN hotplug 自愈；旧版 nft 自动降级兼容
7. **中国 IPv6 访问限制（v1.7.0 新增）**：与 IPv4 版本对称，仅允许中国大陆 IPv6 访问已开放端口；独立 nft 表 `inet netmanager6`（与 IPv4/ fw4 互不影响）；订阅链接与 cron 更新计划可自定义；默认订阅 `https://ispip.clang.cn/all_cn_ipv6.txt`；开机 init + WAN hotplug 自愈
8. **手动黑名单（v1.7.0 新增）**：支持 IPv4/IPv6 单个 IP 与 CIDR 网段（如 `1.2.3.0/24`、`2001:db8::/32`）手动拉黑，入站与转发流量直接丢弃；独立 nft 表 `inet netmanager_ban`（fw4 reload 不影响），条目持久化并开机/WAN 重连自动恢复
9. **设置**：默认目标 IP / 整插件配置备份（UCI 配置 + 黑名单/白名单列表，恢复后自动重应用规则与 cron） / 插件在线更新 / 运行日志排错 / 一键卸载

### 上网设置（原 luci-app-dnssettings，CBI 标准表单）

10. **上网设置**：
   - WAN 口上网方式：PPPoE 拨号 / DHCP 自动获取 / 静态 IP
   - LAN 口地址：LAN 口 IP 地址与子网掩码
   - IPv6 获取与分发：WAN 前缀请求长度（PD）+ LAN 分发模式（状态化 / SLAAC / 中继 / 关闭）
   - WAN 口上游 DNS：PPPoE/DHCP 拨号自定义 IPv4/IPv6 DNS，或使用运营商下发（peerdns）
   - LAN 口设备 DNS：通过 DHCP option 6 与 RA 强制下发自定义 DNS，或走路由器缓存
   - dnsmasq 全局转发：统一配置上游解析服务器
   - 配置备份：一键备份当前系统 network/dhcp 配置到 `/root/backup/`
   - 应用配置：一键写入系统并重启 network/dnsmasq/odhcpd
11. **静态 IP 分配（IPv4 + IPv6）**：基于 MAC 绑定 IPv4 地址 / hostid / ip6 / DUID，支持在线客户端一键绑定与解绑、自动合并重复条目、在线状态显示、地址与 hostid 冲突检测；公网 GUA 随运营商前缀变化，静态 IPv6 仅允许绑定 ULA 后缀

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
│   │   ├── dnssettings-apply.sh              # 上网设置应用配置脚本（独立保留）
│   │   └── dnssettings-backup.sh             # 上网设置备份脚本（独立保留）
│   ├── usr/lib/lua/luci/
│   │   ├── controller/netmanager.lua         # LuCI 控制器（菜单+API+multipart上传+上网设置动作）
│   │   ├── model/cbi/netmanager/
│   │   │   ├── dns_settings.lua              # 上网设置 CBI 模型（绑定 /etc/config/dnssettings）
│   │   │   └── dns_staticv6.lua              # 静态 IP 分配 CBI 模型（绑定 dhcp.host）
│   │   └── view/netmanager/
│   │       ├── overview.htm                  # 系统概览
│   │       ├── port_forward.htm              # 端口转发（含「IPv6 端口放行」区）
│   │       ├── firewall_rules.htm            # 规则管理
│   │       ├── ssh_log.htm                   # SSH 日志
│   │       ├── access_log.htm                # 访问日志
│   │       ├── settings.htm                  # 设置（备份/更新/运行日志/中国IPv4/6过滤/卸载）
│   │       ├── common_head.htm               # 公共样式
│   │       ├── cbi_nav.htm                   # CBI 页面公共导航
│   │       └── nav.htm                       # 公共导航（含上网设置、静态IP分配入口）
│   ├── etc/config/
│   │   ├── netmanager                        # 防火墙模块配置
│   │   └── dnssettings                       # 上网设置模块配置（独立保留）
│   ├── etc/init.d/netmanager-china           # 中国IPv4/IPv6过滤 + 黑名单 开机自启
│   ├── etc/hotplug.d/iface/95-netmanager-china  # WAN上线重应用过滤/黑名单规则
│   └── etc/hotplug.d/iface/96-netmanager-v6sync # WAN上线同步 IPv6 转发目标跟踪
├── tools/
│   ├── build_ipk.py                          # 打 ipk（opkg 系统，tar.gz 外壳，CI/本地通用）
│   ├── build_apk.sh                          # 打 apk（iStoreOS 25.12+，用 openwrt-sdk-mini 的 apk mkpkg）
│   ├── publish_istore.sh                     # 向 istoreos/istore-repo、istoreos/openwrt-app-meta 提 PR
│   └── prune_history.sh                      # 只保留最近 10 个版本的 Tag/Release（KEEP/sort -V 可调）
├── istore/app-meta/
│   ├── Makefile                              # 软件中心卡片元数据模板（PKG_VERSION/PKG_RELEASE 由脚本注入）
│   └── logo.png                              # 软件中心图标（256×256，<50KB）
├── .github/workflows/
│   ├── build.yml                             # 打 tag + 发 Release（tar.gz + changelog 提取）
│   ├── publish-istore.yml                    # Release 后自动构建 ipk/apk + 提 PR 到 iStore 官方仓库
│   ├── prune-history.yml                     # 手动清理历史版本（可改保留数量 / 预演）
│   └── extract_changelog.awk                 # Release body 提取脚本
├── docs/
│   ├── CHANGELOG.md                          # 全部历史版本记录（Release body 的来源）
│   ├── istore-publish.md                     # iStore 上架/自动发版配置说明（一次性 Secret + 日常流程）
│   ├── source-full.md                        # 源码全录（自动生成，对应 PROJECT.md 第 5 章索引）
│   └── gen_source_part.py                    # 生成 source-full.md + PROJECT.md 第 5/9 章
├── install.sh                                # 一键安装脚本（支持 SKIP_UHTTPD_RESTART）
├── PROJECT.md                                # 维护者文档（架构/源码全录/发版流程）
└── README.md
```

---

## 安装方法

> 早期说法「iStoreOS 的 `/usr/bin` 只读所以装不了 ipk」已作废。实测真因是 **iStoreOS 25.12 起换成 apk-tools（系统里没有 opkg）**：25.12+ 只能装 apk，24.10 及更早装 ipk。两种包都由 CI 自动产出。

### 方式一：iStore 软件中心（iStoreOS 25.12+）

本插件已按 iStore 收录规范打包（纯 `all` 架构，落 `nas_luci` feed），并向上游提交了收录 PR（`istoreos/istore-repo`、`istoreos/openwrt-app-meta`）。官方合并后即可在 **iStore → 软件中心** 搜索「网络管理 / netmanager」一键安装，卡片图标与简介来自 `istore/app-meta/`。

在官方合并前，等价做法是手动安装 apk（见方式二）。

### 方式二：命令行安装包（推荐，可控版本）

在 [Releases](https://github.com/District1655/luci-app-netmanager/releases) 下载对应包，上传到路由器后执行：

```bash
# iStoreOS 25.12+ / OpenWrt 25.x（apk）
apk add --allow-untrusted luci-app-netmanager-<版本>-r<rel>.apk

# iStoreOS 24.10 / OpenWrt 23.05–24.10（opkg）
opkg install luci-app-netmanager_<版本>-r<rel>_all.ipk

# 卸载（配置会保留，加 --purge / --force-remove 才会连配置一起删）
apk del luci-app-netmanager
opkg remove luci-app-netmanager
```

安装/卸载的钩子已内置：装完自动清 LuCI 缓存、启用并启动 `netmanager-china`、reload uhttpd 重建 nft 规则；卸载时清掉 `inet netmanager` / `netmanager6` / `netmanager_ban` 三张表，`/etc/config/netmanager` 与 `/etc/config/dnssettings` 默认保留（升级时系统会生成 `.apk-new`，属 OpenWrt 配置保护行为，确认后可覆盖）。

### 方式三：一键脚本（未适配架构 / 开发态兜底）

```bash
cd /tmp
tar xzvf luci-app-netmanager-install_v<版本>.tar.gz
chmod +x install.sh
sh install.sh
```

适用于任意 OpenWrt 衍生系统（含 CI 未覆盖的架构），装完左侧菜单出现「网络管理」，浏览器 `Ctrl+Shift+R` 强制刷新。

### 在线更新

「设置」页面的「插件更新 / 在线更新」区块可直接检查并安装最新 Release（`update_check` / `update_apply`，支持镜像加速前缀）；也可上传新的 `tar.gz` 包离线更新，安装成功后延迟 3 秒自动重启 LuCI。

---

## 构建与发版

### 本地出包

```bash
# ipk（tar.gz 外壳，iStore CI 只认这种；ar 格式会被判 invalid）
python3 tools/build_ipk.py --version 1.8.14 --release 1 --files files --out dist

# apk（需要 apk-tools；脚本会自己下 openwrt-sdk-mini 取 mkpkg）
VERSION=1.8.14 RELEASE=1 FILES=files OUT=dist bash tools/build_apk.sh
```

两个脚本固定 mtime、目录 755 / 文件 644、脚本可执行位，产物可直接进 iStore 官方仓库目录结构（`bin/packages/all/nas_luci/`、`bin/apks/all/nas_luci/`）。

### 发版（push main 一条链路到底）

1. 改两处版本号：`files/usr/sbin/netmanager` 的 `PLUGIN_VERSION`（权威源，L15）与 `README.md` 头部 `> 版本：vX.Y.Z`
2. （可选）在 [`docs/CHANGELOG.md`](docs/CHANGELOG.md) 顶部手写 `### vX.Y.Z (日期)` 小节——**忘写不会阻塞发版**：CI 会按 `git log` 自动补一节（提交即带 `[skip ci]`，不会触发二次发版），Release body 照样有内容；手写的版本优先，CI 不覆盖已有段落
3. `git push origin main`
4. `build.yml`：校验两处版本一致 → `sh -n` / `luac -p` 门禁 → 打 `tar.gz` → 打 tag → 发 Release（tag 已存在则整条跳过，可手动 `workflow_dispatch` 勾 `force`）
5. `publish-istore.yml`（Release published 事件触发）：构建 `ipk` + `apk` → 上传为 Release 资产 → 自动向 `istoreos/istore-repo`（base `pending`）与 `istoreos/openwrt-app-meta`（base `main`）提 PR
6. 官方合并 `pending` 后，上游 `ci-pending.yml` 会把包 cherry-pick 到 main、删同名旧包、刷新索引，软件中心即更新
7. 发版末尾自动清理历史：`tools/prune_history.sh` 只保留版本号最高的 10 个 Tag 与 Release，更早的连 Release 带 tag 一起删（按版本号排序，不是按发布时间；`docs/CHANGELOG.md` 里的文字记录不受影响）

### 版本历史保留策略

仓库不无限堆历史版本：`build.yml` 每次发版后调用 `tools/prune_history.sh`，只留最近 10 个。想改数量或先看要删什么：

```bash
# 预演（不删任何东西）
gh workflow run prune-history.yml -f keep=10 -f dry_run=true
# 真删（如改成保留 20 个）
gh workflow run prune-history.yml -f keep=20
```

本地同样可跑（需要 `gh` 已登录）：`KEEP=10 DRY_RUN=1 bash tools/prune_history.sh`。

### 一次性配置（已配好）

仓库 `Settings → Secrets and variables → Actions` 里的 `ISTORE_TOKEN` 是一个 classic PAT（`repo` scope），用于把分支和 PR 推到两个 fork。**不配也能跑**：此时只构建并挂 Release 资产，跳过自动提 PR（日志里会有 notice 提示）。

手工重跑 / 干跑：

```bash
# 只验证构建，不提 PR（会上传 Release 资产，--clobber）
gh workflow run publish-istore.yml -f version=1.8.14 -f release=1 -f dry_run=true

# 同版本重发，换个 release 号即可（1.8.14-r2）
gh workflow run publish-istore.yml -f version=1.8.14 -f release=2
```

细节与常见问题见 [`docs/istore-publish.md`](docs/istore-publish.md)。

---

## 命令行用法

安装后可直接使用 `netmanager` 命令：

```bash
# 系统概览
netmanager overview
netmanager version              # 查看插件版本

# 端口转发
netmanager port_list
netmanager port_add <外部端口> <tcp|udp|both> <目标IP> <ipv4|ipv6|both> [内部端口]
netmanager port_del <外部端口> <协议> [ipv4|ipv6|both]
netmanager port_edit <旧端口> <旧协议> <新端口> <新协议> <目标IP> <类型> [新内部端口]

# IPv6 转发目标跟踪（v1.8.0+，前缀变化自动跟随）
netmanager port_track_v6 <端口> <tcp|udp> <锚点|off>   # 设置/清除 IPv6 跟踪锚点（MAC/主机名/IPv4）
netmanager port_sync_v6 [--quiet]                       # 立即按锚点重算并同步 IPv6 目标地址

# IPv6 网关自愈（v1.8.7+）
netmanager v6gw [--quiet]        # 补 PPPoE 缺失的 IPv6 默认路由，并强制 ra_default=1 宣告网关

# 防火墙规则
netmanager rule_list
netmanager rule_add <名称> <源> <目标> <协议> <端口> <动作> <ipv4|ipv6|any>
netmanager rule_del <索引>
netmanager rule_edit <索引> <名称> <源> <目标> <协议> <端口> <动作> <类型>
netmanager rule_toggle <索引> <1|0>        # 启用/禁用规则（v1.8.13+，端口放行区开关）

# 日志
netmanager ssh_log [条数]
netmanager access_log [筛选端口] [条数]
netmanager block_detail <端口|v4|v6>   # 查看被拦截源 IP 明细（源/协议/端口/次数/最近时间）

# 运行日志
netmanager log_set 1|0          # 开启/关闭运行日志（持久化到UCI）
netmanager log_get [行数]       # 查看最后 N 行运行日志
netmanager log_query [级别] [关键词] [行数]  # 按级别（INFO/WARN/ERROR/DEBUG）与关键词过滤查询
netmanager log_export           # 导出完整运行日志（输出 base64，供前端下载）
netmanager log_clear            # 清空运行日志

# 设置
netmanager settings
netmanager set_default_target <IP>

# 操作
netmanager restart    # 重启防火墙
netmanager reload     # 重载防火墙

# 备份管理
netmanager backup                    # 立即备份整插件配置（5 个 UCI 配置 + /etc/netmanager 黑名单/白名单列表）
netmanager backup_list               # 查看所有备份
netmanager backup_restore <文件名>   # 从备份恢复
netmanager backup_delete <文件名>    # 删除备份
netmanager backup_import <文件名>     # 将已上传的备份包导入备份目录（校验 tar.gz 与配置内容）
netmanager backup_prune [保留数]     # 清理旧备份，默认保留最近 20 份

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

# 中国IPv6访问限制（v1.7.0+）
netmanager china6_filter status                # 查看状态
netmanager china6_filter enable                # 开启（应用规则 + 装cron + 自启）
netmanager china6_filter disable               # 关闭（清规则 + 移cron，保留列表与设置）
netmanager china6_filter update                # 更新IPv6 IP库并重应用规则
netmanager china6_filter set_url <url>         # 自定义IPv6订阅链接
netmanager china6_filter set_cron "0 4 * * *"  # 自定义IPv6更新计划cron

# 手动黑名单（v1.7.0+，支持单IP与CIDR网段）
netmanager blacklist list                      # 查看黑名单条目与规则状态
netmanager blacklist add <IP|CIDR>             # 添加拉黑，如 1.2.3.4 / 10.0.0.0/8 / 2001:db8::/32
netmanager blacklist del <IP|CIDR>             # 移除条目
netmanager blacklist clear [v4|v6|all]         # 清空黑名单
netmanager blacklist apply                     # 重建黑名单 nft 规则

# 静态 IP 绑定（等价于页面在线客户端「一键绑定 / 解绑」）
netmanager static_bind <MAC> [IPv4] [主机名] [DUID]   # 按 MAC 创建 dhcp host 静态绑定
netmanager static_unbind <MAC>                        # 按 MAC 删除全部静态绑定条目

# 上网设置（命令行应用脚本，等价于页面「应用配置」按钮）
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
    option log_enable '0'                     # 运行日志开关：0关闭 / 1开启
    option china_filter_enable '0'            # 中国IPv4过滤开关：0关闭 / 1开启
    option china_filter_url 'https://metowolf.github.io/iplist/data/special/china.txt'  # IP库订阅链接
    option china_filter_cron '0 3 * * 0'      # 更新计划cron表达式：默认每周日3点
    option china_filter_last_update ''        # 上次成功下载时间
    option china_filter_count '0'             # 当前列表CIDR条数
    option china6_filter_enable '0'           # 中国IPv6过滤开关：0关闭 / 1开启
    option china6_filter_url 'https://ispip.clang.cn/all_cn_ipv6.txt'  # IPv6 IP库订阅链接
    option china6_filter_cron '0 3 * * 0'     # IPv6 更新计划cron表达式
    option china6_filter_last_update ''       # IPv6 上次成功下载时间
    option china6_filter_count '0'            # IPv6 当前列表CIDR条数
    option update_mirror ''                    # 在线更新镜像/加速前缀（空=直连，需在白名单域名内）
```

> **手动黑名单存储**：条目持久化在 `/etc/netmanager/blacklist_v4.list` 与 `/etc/netmanager/blacklist_v6.list`（每行一个 IP 或 CIDR），无需 UCI 配置，页面增删即时生效。

### 上网设置模块：`/etc/config/dnssettings`

```
config wan 'wan'          # WAN 口上游 DNS（peerdns / dns1_v4 / dns2_v4 / dns1_v6 / dns2_v6）
config lan 'lan'          # LAN 口下发 DNS（force_dns / dns1_v4 / dns2_v4 / dns1_v6 / dns2_v6）
config dnsmasq 'dnsmasq'  # dnsmasq 全局转发（enable / forward_v4 列表 / forward_v6 列表）
config actions 'actions'  # 操作按钮占位
```

> **上网设置应用原理**：点击「应用配置」后，`dnssettings-apply.sh` 将上述配置写入 `network.wan/wan6`（peerdns/dns/dns6）、`dhcp.lan`（dhcp_option/dns/ra/dhcpv6）与 `dhcp.@dnsmasq[0].server`，然后重启 network/dnsmasq/odhcpd。局域网设备需断开重连网络才能获取新 DNS。

> **中国IPv4过滤原理**：独立 nft 表 `inet netmanager`（与 fw4 分离，fw4 reload 不影响）含 `china_v4` CIDR 集合 + input/forward 两条 base chain(priority -50)，规则 `iifname {wan} ct state new {tcp,udp} ip saddr != @china_v4 drop`。CIDR 列表存 `/etc/netmanager/china_v4.list`，开机 init + WAN 上线 hotplug 自动重应用。兼容新旧 nft：modern(`flags interval, auto-merge` 分片加载) / compat(`flags interval` 单次原子加载 + 逐行回退)。

> **中国IPv6过滤原理（v1.7.0）**：与 IPv4 完全对称，独立 nft 表 `inet netmanager6` 含 `china_v6` 集合 + `china6_input`/`china6_forward` 两条 base chain，规则 `iifname {wan} ct state new {tcp,udp} ip6 saddr != @china_v6 drop`。列表存 `/etc/netmanager/china_v6.list`，默认订阅 `https://ispip.clang.cn/all_cn_ipv6.txt`，同样支持 modern/compat 两种 nft 加载模式。

> **手动黑名单原理（v1.7.0）**：独立 nft 表 `inet netmanager_ban`，`ban_v4`/`ban_v6` 两个 interval 集合支持单 IP 与 CIDR 网段，input/forward 两条 base chain 上分别以 `ip saddr @ban_v4 drop`、`ip6 saddr @ban_v6 drop` 丢弃入站与转发流量。条目持久化在 `/etc/netmanager/blacklist_v4.list`、`blacklist_v6.list`，重启与 WAN 重连后由 init/hotplug 自动恢复。

### 中国 IP 订阅参考源

IPv6（每行一个 CIDR）：

| 源 | 地址 | 说明 |
|----|------|------|
| ispip.clang.cn（默认） | `https://ispip.clang.cn/all_cn_ipv6.txt` | 中国大陆全部 IPv6 地址段，国内直连 |
| china-operator-ip | `https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china6.txt` | 按国内运营商 ASN 自动生成，更新频繁（GitHub raw 直连受限时需镜像） |
| APNIC 原始数据 | `https://ftp.apnic.net/apnic/stats/apnic/delegated-apnic-latest` | 官方分配数据，需自行转换为 CIDR |

IPv4（每行一个 CIDR）：

| 源 | 地址 | 说明 |
|----|------|------|
| metowolf/iplist（默认） | `https://metowolf.github.io/iplist/data/special/china.txt` | 社区维护，格式与插件一致 |
| ispip.clang.cn | `https://ispip.clang.cn/all_cn.txt` | 中国大陆全部 IPv4 地址段，国内直连 |
| china-operator-ip | `https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt` | 按国内运营商 ASN 自动生成 |

---

## 卸载

- Web 界面：「设置」页面 →「卸载插件」区块（支持「保留配置」勾选）
- 命令行：`netmanager uninstall [full|keep]`

卸载会完整清理：后端脚本、LuCI 控制器/CBI 模型/视图、init/hotplug、上网设置应用与备份脚本、nft 规则、cron 任务、配置文件。用户在 `/etc/config/firewall` 中的端口转发与防火墙规则不受影响。

---

## 注意事项

1. DNS「应用配置」会重启网络服务，期间会短暂断网
2. 设备端 DNS 有缓存，重连网络后才会拿到新 DNS
3. v1.4.6+ WAN 接口自动探测（默认路由反查），自定义接口名可在 `dnssettings` 配置 `wan_iface`/`wan6_iface` 显式指定
4. DNS 备份文件保存在 `/root/backup/`，防火墙配置备份保存在 `/root/`
5. 插件在线更新只接受 `.tar.gz` / `.tgz` 安装包（`.ipk`/`.apk` 请走软件中心或 apk/opkg 命令）
6. apk 体系升级时，`/etc/config/netmanager`、`/etc/config/dnssettings` 可能落地成 `*.apk-new`（配置保护），确认新版本无误后再覆盖
7. 卸载默认保留两份 UCI 配置；要彻底清干净用 `netmanager uninstall`（full）

## 更新日志

完整历史版本记录（v1.8.15 → v1.4.0 → 继承 fwmanager v1.3.33）已归档到 **[`docs/CHANGELOG.md`](docs/CHANGELOG.md)**，`build.yml` 从那里提取当前版本段落作为 GitHub Release body。

**最近一版：v1.8.15（2026-11-26）**

- **Release 同时提供 `.apk` 与 `.ipk`**：25.12+ 用 apk，24.10 及更早用 ipk，`tar.gz` 保留兜底
- **iStore 软件中心上架进行中**：`istore/app-meta/` 元数据 + 官方目录规范出包，发版后自动向 `istoreos/istore-repo`、`istoreos/openwrt-app-meta` 提 PR
- **发版全自动**：Release 发布即构建 ipk/apk、上传资产、提 PR；忘写更新日志时 CI 自动按提交记录补一节
- **修复**：install.sh 横幅与各页面页脚版本号统一到 1.8.15

## 许可证

MIT License