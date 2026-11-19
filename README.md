# 网络管理插件 (luci-app-netmanager)

> 版本：v1.8.0
>
> 适配：iStoreOS / OpenWrt (fw4/nftables, Lua LuCI)
>
> 由 **luci-app-fwmanager**（防火墙管理）与 **luci-app-dnssettings**（DNS设置）合并而成的网络管理一体化 LuCI 插件。

一站式管理路由器网络：端口转发、防火墙规则、SSH/访问日志、中国 IPv4/IPv6 访问限制、手动黑名单、WAN/LAN 双栈 DNS 统一管理、静态 IPv6 分配、配置备份恢复、插件在线更新、一键卸载。

---

## 功能模块

### 防火墙管理（原 luci-app-fwmanager）

1. **系统概览**：防火墙状态 / 端口统计 / 网络信息 / 快捷操作
2. **端口转发管理**：IPv4 DNAT + IPv6 放行统一管理，支持 TCP/UDP/双协议、单端口与端口范围
3. **防火墙规则管理**：自定义通信规则增删改 + 常用模板一键应用
4. **SSH 登录日志**：成功/失败记录 + 失败 IP 排行 Top 10 + 自动刷新
5. **端口访问日志**：活跃连接 / 入站出站计数 / 拦截统计
6. **中国 IPv4 访问限制**：仅允许中国大陆 IPv4 访问已开放端口，境外 IPv4 新建连接丢弃；独立 nft 表 `inet netmanager`（fw4 reload 不影响）；订阅链接与 cron 更新计划可自定义；开机 init + WAN hotplug 自愈；旧版 nft 自动降级兼容
7. **中国 IPv6 访问限制（v1.7.0 新增）**：与 IPv4 版本对称，仅允许中国大陆 IPv6 访问已开放端口；独立 nft 表 `inet netmanager6`（与 IPv4/ fw4 互不影响）；订阅链接与 cron 更新计划可自定义；默认订阅 `https://ispip.clang.cn/all_cn_ipv6.txt`；开机 init + WAN hotplug 自愈
8. **手动黑名单（v1.7.0 新增）**：支持 IPv4/IPv6 单个 IP 与 CIDR 网段（如 `1.2.3.0/24`、`2001:db8::/32`）手动拉黑，入站与转发流量直接丢弃；独立 nft 表 `inet netmanager_ban`（fw4 reload 不影响），条目持久化并开机/WAN 重连自动恢复
9. **设置**：默认目标 IP / 配置备份 / 插件在线更新 / 运行日志排错 / 一键卸载

### DNS 设置（原 luci-app-dnssettings，CBI 标准表单）

10. **DNS 设置**：
   - WAN 口上游 DNS：PPPoE/DHCP 拨号自定义 IPv4/IPv6 DNS，或使用运营商下发（peerdns）
   - LAN 口设备 DNS：通过 DHCP option 6 与 RA 强制下发自定义 DNS，或走路由器缓存
   - dnsmasq 全局转发：统一配置上游解析服务器
   - 配置备份：一键备份当前系统 network/dhcp 配置到 `/root/backup/`
   - 应用配置：一键写入系统并重启 network/dnsmasq/odhcpd
11. **静态 IPv6 分配**：基于 MAC 绑定 hostid/ip6/DUID，自动合并重复条目、在线状态显示、hostid 冲突检测

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
│   ├── etc/init.d/netmanager-china           # 中国IPv4/IPv6过滤 + 黑名单 开机自启
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
    option china6_filter_enable '0'           # 中国IPv6过滤开关：0关闭 / 1开启
    option china6_filter_url 'https://ispip.clang.cn/all_cn_ipv6.txt'  # IPv6 IP库订阅链接
    option china6_filter_cron '0 3 * * 0'     # IPv6 更新计划cron表达式
    option china6_filter_last_update ''       # IPv6 上次成功下载时间
    option china6_filter_count '0'            # IPv6 当前列表CIDR条数
```

> **手动黑名单存储**：条目持久化在 `/etc/netmanager/blacklist_v4.list` 与 `/etc/netmanager/blacklist_v6.list`（每行一个 IP 或 CIDR），无需 UCI 配置，页面增删即时生效。

### DNS 模块：`/etc/config/dnssettings`

```
config wan 'wan'          # WAN 口上游 DNS（peerdns / dns1_v4 / dns2_v4 / dns1_v6 / dns2_v6）
config lan 'lan'          # LAN 口下发 DNS（force_dns / dns1_v4 / dns2_v4 / dns1_v6 / dns2_v6）
config dnsmasq 'dnsmasq'  # dnsmasq 全局转发（enable / forward_v4 列表 / forward_v6 列表）
config actions 'actions'  # 操作按钮占位
```

> **DNS 应用原理**：点击「应用配置」后，`dnssettings-apply.sh` 将上述配置写入 `network.wan/wan6`（peerdns/dns/dns6）、`dhcp.lan`（dhcp_option/dns/ra/dhcpv6）与 `dhcp.@dnsmasq[0].server`，然后重启 network/dnsmasq/odhcpd。局域网设备需断开重连网络才能获取新 DNS。

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

卸载会完整清理：后端脚本、LuCI 控制器/CBI 模型/视图、init/hotplug、DNS 应用与备份脚本、nft 规则、cron 任务、配置文件。用户在 `/etc/config/firewall` 中的端口转发与防火墙规则不受影响。

---

## 注意事项

1. DNS「应用配置」会重启网络服务，期间会短暂断网
2. 设备端 DNS 有缓存，重连网络后才会拿到新 DNS
 3. v1.4.6+ WAN 接口自动探测（默认路由反查），自定义接口名可在 `dnssettings` 配置 `wan_iface`/`wan6_iface` 显式指定
4. DNS 备份文件保存在 `/root/backup/`，防火墙配置备份保存在 `/root/`
5. 更新前建议先备份配置；只支持 `.tar.gz` 或 `.tgz` 格式

## 更新日志

### v1.8.0 (2026-11-19)

**新增：IPv6 转发目标动态跟踪**

- 问题：运营商 PD 前缀会变化（实测一天内变更多次），IPv6 放行规则里写死的 `dest_ip` 前缀一变即失效；且旧逻辑在「仅 IPv6」模式下会把 IPv4 默认目标（如 `192.168.31.3`）直接写进 `family=ipv6` 的规则，属非法地址，导致整条规则不生效——实测 5 条 IPv6 放行规则全部没有 `dest_ip`，等于对整个内网开放端口
- 新增锚点跟踪机制：为规则登记目标主机的内网 IPv4 / MAC / 主机名作为锚点，由 `v6_resolve_target` 实时解析其当前公网 IPv6。解析优先级为 **DHCP 静态 hostid（前缀+固定后缀，最稳）→ DHCPv6 租约（按 DUID）→ 邻居表（按 MAC）**
- 新增命令 `port_track_v6 <端口> <tcp|udp> <锚点|off>` 与 `port_sync_v6 [--quiet]`
- 「仅 IPv6」添加规则时自动把 IPv4 目标解析为 IPv6 并登记跟踪；解析不到则不写 `dest_ip` 并明确告警，不再写入非法地址
- 端口转发页 IPv6 表格新增「目标地址」「跟踪锚点」两列，未限定目标的规则标红提示；提供「跟踪」与「立即同步」按钮
- 新增 hotplug `96-netmanager-v6sync`：WAN 上线后自动同步；同步时顺带清理旧前缀残留的源路由与 unreachable 条目

**修复：DNS 页面配置与实际生效不一致**

- `dnssettings.wan` 节存在但 DNS 选项缺失时，页面显示默认值而 `network.wan` 实际无 `dns`、`peerdns` 未设置（走运营商 DNS），二者不符。现在应用前自动回填缺失项（优先沿用 `network` 现值），CBI 初始化也补齐单个缺失选项而非仅判断节是否存在
- 新增 `noresolv` 开关：dnsmasq 默认除转发列表外还并用系统 resolv 上游（运营商下发、wan6 自动获取、LAN 接口 DNS），使「全局转发」名不副实。开启后严格只用转发列表
- DNS 设置页新增「当前实际生效的 DNS」只读面板，直接展示运行时 dnsmasq 转发列表、系统 resolv 上游（首页数据来源）与下发给内网设备的 DNS，并标注 noresolv 状态，便于与首页对照

**修复：应用 DNS 配置导致管理 SSH 中断**

- dropbear 若以 `DirectInterface` 绑定 br-lan，`network restart` 重建 br-lan 后监听套接字绑定的 ifindex 失效，表现为端口仍 LISTEN 但连接被 refused。DNS 应用改用 `network reload`，并在应用后自检 SSH 监听、异常时自动重启 dropbear
- 新增 hotplug 在 lan ifup 时做同样的 SSH 监听自检自愈

**修复：odhcpd 重复实例**

- 实测存在 `odhcpd -v` 与 `/usr/sbin/odhcpd` 两个实例并存，同时写 RFC9096 piofile 造成前缀记忆互相覆盖、RA 广播不一致。应用脚本改为先收敛实例再统一拉起，并回显实例数

**修复：WAN DNS 输入框在页面上根本不渲染**

- 问题：WAN 四个 DNS 选项使用 `o:depends("peerdns", "0")`，而 iStoreOS 24.10 的 CBI 对 Flag「等于 0」的依赖判定不成立，服务端直接省略这些选项——页面上看不到也无法配置 WAN DNS，只能沿用默认值，与实际生效的运营商 DNS 长期不一致（LAN 侧用的是 `="1"`，因此正常）
- 改为始终显示这四项，并在说明中标注「仅在未勾选『使用运营商下发的 DNS』时生效」
- `pcdata` 优先走 `luci.xml`，避免旧路径打印弃用告警污染页面输出

**修复：端口转发表混入不该出现的条目**

- IPv6 表此前会把系统自带规则（`Allow-DHCPv6`、`Allow-MLD`、`Allow-ICMPv6-*`）一并列出，标红「未限定目标」并提供删除按钮，误删会直接断 IPv6。现在只列出 `dest=lan` 的放行规则，系统规则天然被过滤
- `family=ipv6` 的端口映射此前混在 IPv4 表里，目标地址显示为 IPv6，且与同端口的 IPv4 条目共用按「端口+协议」匹配的编辑/删除，存在误删对方的风险。现在独立成「IPv6 端口映射 (DNAT)」表

**新增：IPv6 端口映射同样跟随前缀**

- 跟踪引擎此前只覆盖 `firewall rule`（放行），`family=ipv6` 的 `redirect`（DNAT）不在其列，前缀一变即失效。现在同步时按 `src_dport` 匹配并改写其 `dest_ip`，内部端口保持不变
- 实测修复了两条指向旧前缀临时地址、已失效的 IPv6 DNS 映射

### v1.7.3 (2026-11-19)

**修复：IPv6 白名单 forward 链缺少控制面放行，NDP/DHCPv6 relay 场景仍会误杀**

- 问题：v1.7.2 只在 `china6_input` 链补了放行（`fe80::/10`、`ff00::/8`、DHCPv6 546/547），`china6_forward` 链**一条放行规则都没有**，只有 `ip6 saddr != @china_v6 drop`。开启 NDP relay（`dhcp.wan.ndp='relay'`）或 DHCPv6 relay（`dhcp.wan.dhcpv6='relay'`）时，从 WAN 侧返回的邻居发现包与中继应答源地址同样是链路本地 `fe80::`，会被判成境外地址丢弃，导致 LAN 设备地址解析失败、DHCPv6 中继拿不到地址
- IPv6 修复：`china6_forward` 在 drop 之前补齐三条放行——`ip6 saddr fe80::/10`、`ip6 saddr ff00::/8`、`udp sport 547 udp dport 546`
- IPv4 同步加固：`china_forward` 补齐 `udp sport 67 udp dport 68` 与 `ip saddr 169.254.0.0/16`，覆盖 DHCP relay（LAN 设备经路由器向运营商续租）场景
- 已启用用户升级后会自动重应用规则，无需重新下载 IP 库

**修复：PPPoE 场景下 wan6 绑定物理网口导致 PD 前缀拿不到**

- 问题：`network.wan6.device` 与 `network.wan` 绑在同一物理网口时，DHCPv6 客户端在该口上没有可用的 IPv6 出口地址，`SOLICIT`/`RS` 发不出去（syslog 报 `Failed to send SOLICIT message to ff02::1:2 (Address not available)`），PD 前缀续租失败 → 前缀到期撤销 → 局域网设备全部丢失公网 IPv6。此时 `ifstatus wan6` 的 `ipv6-prefix` 为空，而 LAN 仍靠旧租约（`valid_lft` 倒计时）残着，到期即彻底断网
- 修复：「应用配置」时增加一致性校验——`wan.proto=pppoe` 且 `wan6.device == wan.device` 时自动改为 `@wan`（指向 PPPoE 逻辑接口），随后自动 `ifup wan6` 重新协商，并在日志中回显 PD 获取结果
- 排查提示：怀疑 IPv6 断流时按顺序核查 `ifstatus wan6` 的 `ipv6-prefix` 是否为空、`ip -6 addr show <LAN 设备>` 的 `valid_lft` 是否在倒计时、`logread | grep odhcp6c` 是否出现 `Address not available`

### v1.7.2 (2026-11-19)

**修复：开启中国 IPv6 白名单后 LAN 设备丢失公网 IPv6**

- 原因：白名单 drop 规则覆盖全部 TCP/UDP，DHCPv6-PD 应答源地址为链路本地 `fe80::`，不在 `china_v6` 公网集合中，被误判为境外地址丢弃；PD 续租失败后前缀到期撤销，LAN 设备拿不到/续不上公网 IPv6
- IPv6 修复：在 drop 规则之前新增放行规则
  - `ip6 saddr fe80::/10`（链路本地）
  - `ip6 saddr ff00::/8`（多播）
  - `udp sport 547 udp dport 546`（DHCPv6 服务端应答）
- IPv4 同步加固：在 drop 之前放行 `udp sport 67 udp dport 68`（DHCPv4 应答）与 `169.254.0.0/16`（链路本地）
- 已启用用户升级后会自动重应用规则，无需重新下载 IP 库

### v1.7.1 (2026-11-19)

**修复：手动黑名单添加 IPv6 地址被误判为 IPv4**

- `blacklist add/del` 入参清洗由 `tr -d '[:space:]'` 改为 `tr -d ' \t\r\n'`。部分 BusyBox 的 tr 不识别 POSIX 字符类，会把 `[:space:]` 按字面字符解析，连冒号与 `s/p/a/c/e` 等字母一起删除，导致 `2001:550:9005:e000::13` 被吞成 `2001550900500013` 后误报「非法 IPv4 地址」
- 该问题仅影响 iStoreOS/BusyBox 环境下的手动黑名单增删命令，IPv6 白名单订阅不受影响

### v1.7.0 (2026-11-19)

**新增：中国 IPv6 白名单订阅 + IPv4/IPv6 手动黑名单（支持网段）**

**① 中国 IPv6 访问限制（参考 IPv4 白名单实现）**
- 独立 nft 表 `inet netmanager6`：`china_v6` interval 集合 + `china6_input`/`china6_forward` 两条 base chain(priority -50)
- 规则 `iifname {wan} ct state new {tcp,udp} ip6 saddr != @china_v6 counter drop`，仅拦截境外 IPv6 新建 TCP/UDP 连接
- 默认订阅 `https://ispip.clang.cn/all_cn_ipv6.txt`（中国大陆全部 IPv6 地址段，国内可直连），支持自定义订阅链接与 cron 更新计划
- 下载后严格过滤为合法 IPv6 CIDR（BOM/CR/注释/空行自动清理），条数过少拒绝保存，防止空列表误杀
- 与 IPv4 版本相同的 nft 兼容策略：modern(`flags interval, auto-merge` 分片加载) / compat(`flags interval` 单次原子加载 + 逐行回退)
- 开机 init + WAN hotplug 自愈；`netmanager china6_filter status|enable|disable|update|set_url|set_cron`
- 设置页新增「中国IPv6访问限制」区块，与 IPv4 区块并列独立开关

**② 手动黑名单（IPv4 / IPv6，支持单 IP 与 CIDR 网段）**
- 独立 nft 表 `inet netmanager_ban`，`ban_v4`/`ban_v6` 两个 interval 集合，支持 `1.2.3.4`、`1.2.3.0/24`、`2001:db8::1`、`2001:db8::/32`
- input/forward 两条 base chain 分别以 `ip saddr @ban_v4 drop`、`ip6 saddr @ban_v6 drop` 丢弃入站与转发流量
- 条目持久化到 `/etc/netmanager/blacklist_v4.list`、`/etc/netmanager/blacklist_v6.list`，重启/WAN 重连自动恢复
- 格式校验：IPv4 校验每段 0-255 且拒绝前导零，IPv6 校验分组数量/位数/前缀长度（0-32 / 0-128）
- 设置页新增「手动黑名单」区块：输入框一键添加、条目徽标逐个删除、IPv4/IPv6 分别清空
- 命令行 `netmanager blacklist list|add <ip/cidr>|del <ip/cidr>|clear [v4|v6|all]|apply`

**③ 其他**
- WAN 设备探测同时参考 IPv4/IPv6 默认路由，纯 IPv6 上联场景也能正确安装规则
- 卸载流程清理 `inet netmanager6`、`inet netmanager_ban` 与两类 cron 任务
- 热插拔脚本改为「任一过滤启用或存在黑名单条目」即恢复规则

### v1.6.1 (2026-09-05)

**功能重构：DNS设置模块升级为「上网设置」，新增WAN口上网方式 + LAN口地址设置，备份功能统一管理**

**① 模块改名与扩展**
- 原「DNS设置」模块改名为**「上网设置」**（菜单/导航/页面标题同步更新）
- 页面从单一 DNS 配置扩展为三大区块：WAN 口上网方式 + LAN 口地址 + DNS 设置
- 参考小米路由器上网设置交互，统一在一个页面管理路由器上网相关配置

**② 新增 WAN 口上网方式设置**
- 支持三种上网方式：**PPPoE 拨号** / **DHCP 自动获取** / **静态 IP**
- PPPoE 模式：账号、密码输入框（密码字段隐藏显示）
- 静态 IP 模式：IP 地址、子网掩码、网关、WAN 口 DNS（支持多个，DynamicList）
- 上网方式切换时自动显示/隐藏对应字段（depends 联动）
- 绑定 `/etc/config/network` 的 wan 接口

**③ 新增 LAN 口地址设置**
- LAN 口 IP 地址、子网掩码配置
- 绑定 `/etc/config/network` 的 lan 接口
- 修改后需用新地址重新登录管理页面（页面有提示）

**④ DNS 设置保留并优化**
- WAN 口上游 DNS（运营商下发 / 自定义 IPv4+IPv6）
- LAN 口设备 DNS（强制下发 / 路由器缓存）
- dnsmasq 全局转发（DynamicList 支持多个 DNS）
- 自动初始化：配置文件为空时自动创建默认配置，确保表单正常渲染

**⑤ 备份功能统一管理**
- 移除「上网设置」页面的「备份当前系统配置」按钮
- 所有备份功能统一由「设置 → 备份管理」模块管理（全配置备份/恢复/删除/导入/清理）
- 应用配置时仍自动备份到 `/root/backup/`（防误操作回滚）

**⑥ 应用配置统一生效**
- 「应用配置」按钮同时保存 network（WAN/LAN口）和 dnssettings（DNS）配置
- 执行 `dnssettings-apply.sh` 应用 DNS 配置
- 重启 network 服务使 WAN/LAN 口设置生效
- 成功/失败结果显示在页面顶部消息栏

### v1.4.9 (2026-09-05)

**紧急修复：v1.4.8 两处回归导致插件完全不可用**

- **修复全部页面 API 调用失败 `r.text is not a function`**：v1.4.6 引入的 `nmFetch` 兼容层内部已 `.then(res => res.text())` 返回**字符串**，但全部 30+ 处调用方仍按原生 fetch 习惯写 `.then(r => r.text())`，对字符串调用 `.text()` 报 `is not a function`，导致系统概览/端口转发/规则/日志/设置/在线更新/中国IP过滤**所有页面数据加载全部失败**。现 `nmFetch` 改为返回 Response 对象（与原生 fetch 一致），调用方零改动即可正常工作
- **修复 DNS设置 / 静态IPv6 页面 Runtime error 崩溃**：v1.4.8 修复 `cbi_nav.htm` 注释语法时，注释内容中包含了 `%>` 字符（用于说明正确/错误语法），LuCI 模板解析器在注释块内扫描到 `%>` 即**提前结束注释**，后续内容被当 Lua 代码解析报 `unexpected symbol near '-'`；现注释内容改写为不含 `%>` 组合的描述，两个 CBI 页面恢复正常

### v1.4.8 (2026-09-05)

**紧急修复：v1.4.7 两处线上崩溃回归**

- **修复 DNS 设置 / 静态 IPv6 页面 Runtime error 崩溃**：`cbi_nav.htm` 文件头部误用 JSP 风格注释 `<%-- --%>`，LuCI 模板解析器不支持该语法（`<%` 后遇单个 `-` 报 `unexpected symbol near '-'`），导致两个 CBI 页面加载即崩溃；现改为 LuCI 标准注释 `<%# %>`
- **修复 CSRF Token 在 ucode 版 LuCI 上仍可能全部 403**：v1.4.7 视图端改用框架模板变量 `<%=token%>`，但部分 ucode LuCI 版本的 include 子模板（common_head.htm）上下文中 `token` 变量未传递，导致 `CSRF_TOKEN` 恒为空字符串；现改为在 common_head.htm 内联 Lua 代码直接从 `luci.dispatcher.context.authtoken` 取值（与控制器 `csrf_token()` 完全同源），不再依赖模板变量传递链

### v1.4.7 (2026-09-04)

**紧急修复：v1.4.6 CSRF 机制在 ucode 版 LuCI 上全部 API 403 的回归**

- **修复 CSRF Token 全量失效**：v1.4.6 的 token 由 `luci.dispatcher.context.session.id` 派生——**ucode 版 LuCI（iStoreOS 24.10）的 context 没有 `session` 字段**（会话 ID 实际存于 `context.authsession`，框架内建 CSRF token 存于 `context.authtoken`），导致 token 恒为空、`csrf_check` fail-closed 将**所有 API 请求拒绝 403**（页面可打开但全部数据加载失败）。现改为直接使用 **LuCI 内建 `authtoken`**（与 CBI 表单 token 同源，由分发器为每个已认证会话生成），视图端同步改用框架模板变量 `<%=token%>`，不再 require 控制器模块
- **修复旧版 DNS 页签 404**：v1.4.5 书签/浏览器缓存指向的 `dns_apply`/`dns_backup` GET 路由已被删除；现恢复为**安全重定向**（仅跳转到 DNS 设置页，不执行脚本，不复活"刷新即重复执行"问题）
- **CBI 操作按钮防御加固**：「应用配置」「备份配置」与静态 IPv6「保存并应用」的脚本执行/条目合并环节以 `pcall` 包裹，异常不再中断整个请求，错误文本透传到页面消息（便于精确反馈问题）

### v1.4.6 (2026-09-04)

**安全加固（阶段一 P0 全量落地）**

- **新增 CSRF Token 校验**：API 此前仅强制 POST，跨站恶意页面仍可构造自动提交的 `<form method=POST>` 携带登录 cookie 触发卸载/关闭过滤等危险操作；现每个请求必须携带由会话派生的 token（`csrf_token`，视图渲染时注入 `common_head.htm`，`apiFetch`/`nmFetch` 自动附带），跨站页面无法获得 → 返回 403；无 token 的 curl 直接调用被拒绝
- **在线更新 sha256 供应链校验**：CI 为 Release 生成 `.tar.gz.sha256` 校验资产，`update_apply` 下载后自动校验 sha256（GitHub 账号被入侵/镜像劫持注入恶意包时拦截并放弃更新）；旧版本 Release 无校验资产时 warn 跳过（向后兼容）
- **镜像域名白名单**：`set_update_mirror` 与已保存镜像均须通过域名白名单校验（拒绝裸 IP/localhost/非白名单域名），防镜像前缀被注入指向攻击者服务器
- **上传文件权限收紧**：上传的插件包/配置文件统一 `chmod 600`（其他本地用户不可读）
- **卸载保留登录会话**：卸载不再删除 `/tmp/luci-sessions`（此前会踢掉所有登录用户导致看不到卸载结果页），仅清 LuCI 页面缓存
- **XSS 补漏 3 处**：中国IP过滤状态单元格（上次更新时间/CIDR条数/WAN设备名）、备份列表文件名（并改数组下标传参杜绝 onclick 注入）、修复 `restoreBackup`/`deleteBackup` 的自由文本入 onclick
- **multipart 上传加固**：50MB 大小上限（超限即丢弃，防 /tmp tmpfs OOM）；临时文件名加时间戳+随机数（防同秒并发上传互相覆盖）
- **logger 控制字符过滤**：DNS 应用脚本写入 syslog 前剔除控制字符（防日志注入转义序列）

**功能与逻辑修复**

- **DNS 应用按钮 POST 化**：`dns_apply`/`dns_backup` 由独立 GET 路由并入 `api_handler` 的 POST action（此前浏览器刷新页面即重复执行应用/备份）；CBI「应用配置」按钮直接执行脚本并显示成功/失败结果（alert 消息，含退出码）
- **DNS 应用脚本 WAN 接口自动探测**：不再硬编码 `network.wan`/`network.wan6`，按「用户显式配置（`wan_iface`/`wan6_iface`）→ 默认路由反查 → 兜底 wan/wan6」三级探测；`pppoe-wan` 等自定义接口名可正确写入
- **PPPoE 双栈 fallback 去重**：IPv6 DNS 并入 `wan.dns` 前先 delete 全量重写（修复重复应用配置时 `add_list` 逐次累积导致 DNS 列表无限增长）
- **`dhcp_option` list 化**：改为 `delete + add_list` 正确写法（UCI 中是 list 类型，旧 `uci set` 单值写法在多实例残留时行为未定义）
- **静态 IPv6 分配页**：
  - 重复 MAC 条目合并改为「页面只检测提示、点保存才真正合并」（此前每次打开页面 GET 刷新即静默 commit 修改 `/etc/config/dhcp`）
  - DUID 自动捕获排除「MAC 原文型」与「01+MAC 硬件型」伪 DUID（此前会被误存为 DUID 导致绑定错乱）
  - 在线设备 WAN 侧过滤覆盖 `pppoe-wan`/`pppoe-wan6` 等 PPPoE 接口命名（此前仅匹配 `wan` 前缀，PPPoE 拨号对端会被误列为 LAN 设备）
  - `odhcpd` 改为按需重启（仅本次有实际改动才 restart，无改动保存不再重置 IPv6 租约）；CBI 页面注入页内导航（修复从自绘页面进入后页签消失）
- **控制器健壮性**：`arg()` 空参数包装函数提取为模块级（原 4 处重复定义）；DNS 动作单次调用同时捕获输出与退出码（`__RC__` 标记法，脚本失败不再静默当成功）

**工程化**

- **CI 语法门禁**：打包前强制 `sh -n`（6 个 shell 脚本）+ `luac -p`（全部 Lua 文件）语法检查，失败即终止流水线；打包后 `tar tzf` 产物预检
- **仓库补齐 LICENSE 文件**（README 早已声明 MIT）

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