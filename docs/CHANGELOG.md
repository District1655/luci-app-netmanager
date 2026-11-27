# 更新日志（docs/CHANGELOG.md）

> 本文件从 `README.md` 迁出（2026-11-26），是**全部历史版本记录的唯一出处**。
> `build.yml` 从这里提取当前版本段落作为 GitHub Release body，段落标题格式必须保持 `### vX.Y.Z (日期)`。
> **忘写不影响发版**：CI 会用 `tools/ensure_changelog.py` 按提交记录自动补一节（已存在则不改动，人工写的优先）。
> `README.md` 只保留「最近一版要点 + 指向本文件的链接」。

> **2026-11-26 工程更新（版本号不变，交付形态与 CI 变更）**：新增 ipk/apk 双格式打包（`tools/`）、iStore 软件中心上架元数据（`istore/app-meta/`）、Release 后自动构建并提 PR 到 `istoreos/istore-repo` 与 `istoreos/openwrt-app-meta` 的流水线（`.github/workflows/publish-istore.yml`）；README 安装章节按 apk/opkg 双体系重写。

### v1.8.16 (2026-11-27)
- **修复：上级光猫/网关访问不到路由器（issue #1）**。此前白名单规则为「`iifname {WAN}` 且 `ip saddr != @china_v4` → drop」，而 `china.txt` 只收录**大陆公网**地址段；光猫拨号/桥接场景下 WAN 口落在私网段（如 `192.168.1.0/24`），光猫自身的私网 IP 不在集合里 → 被当成境外地址丢弃。现在规则解析出 **WAN 口自身所在网段**，在 drop 之前放行该网段来源（`get_wan_prefixes`，纯 shell 算 CIDR，不依赖 ipcalc；PPP 点对点接口按 `peer` 后的掩码解析）。只放行“与自己同段”的地址，**不是**把整个 RFC1918 灌进去，攻击面几乎不变。
- **新增开关「放行上级网关」**：`uci netmanager.settings.china_filter_allow_wan_peers`（默认 1），设置页中国 IPv4 区块新增勾选框与保存按钮（`china_filter_set_allow_wan`），命令行 `netmanager china_filter allow_wan on|off|status`；`china_filter status` 增加 `ALLOW_WAN_PEERS` / `WAN_PEERS` 两行，设置页「生效WAN口 / 规则」一行同时显示放行网段。
- **IPv6 侧对称修复**：`china6` 链在 drop 前放行 `fd00::/8`（ULA）与 WAN 口自身 `/64`（此前只放行 `fe80::/10`、`ff00::/8` 与 DHCPv6），避免光猫用私网 IPv6 访问时被误杀。
- **调试钩子（不改变正常行为）**：`NM_WAN_DEVS_OVERRIDE` 可临时指定 WAN 设备列表、`NM_RULES_ONLY=1` 只打印生成的 nft 规则不落盘，供真机复现与排查。
- **真机验证（iStoreOS 25.12.6 / x86_64 / nft 1.1.6）**：用 veth + netns 构造「同段邻居」场景，老规则 4 个 SYN 全部命中 drop；新规则 24 个 SYN 全部命中 accept、drop 计数为 0；本机 PPPoE（`/32`）场景解析为 `223.167.209.134/32`，规则与 IPv4/IPv6 链均正常重建，drop 计数继续增长（境外扫描仍被拦）。

### v1.8.15 (2026-11-26)
- **新增 ipk / apk 双格式安装包（随 Release 自动产出）**：iStoreOS 25.12+（apk-tools，系统内无 opkg）装 `luci-app-netmanager-<版本>-r<rel>.apk`；iStoreOS 24.10 / OpenWrt 23.05–24.10 装 `luci-app-netmanager_<版本>-r<rel>_all.ipk`；`tar.gz + install.sh` 保留为未适配架构与开发态的兜底路径。产物由 `tools/build_ipk.py`、`tools/build_apk.sh` 生成（固定 mtime、目录 755 / 文件 644、conffiles 与 postinst/prerm 钩子）。
- **iStore 软件中心上架材料**：新增 `istore/app-meta/`（META_TITLE/DESCRIPTION/AUTHOR/DEPENDS/TAGS/LUCI_ENTRY/WEBSITE + 256×256 图标），按官方目录规范（`all/nas_luci`）出包；`.github/workflows/publish-istore.yml` 在 Release 发布后自动向 `istoreos/istore-repo`（base `pending`）与 `istoreos/openwrt-app-meta`（base `main`）提收录 PR。
- **发版全自动化**：push main → 打 tag / 发 Release → 构建 ipk+apk → 上传 Release 资产 → 自动提 PR，一条链路到底；忘写更新日志时 CI 用 `tools/ensure_changelog.py` 按提交记录自动补一节（提交带 `[skip ci]`，不二次触发），不再出现空 Release body。
- **安装/卸载钩子在 25.12 真机验证**：`apk add` 后依赖全满足、自动清 LuCI 缓存、启用并启动 `netmanager-china`、重建 `inet netmanager`/`netmanager6`/`netmanager_ban` 三张表；`apk del` 清表并保留 `/etc/config/netmanager`、`/etc/config/dnssettings`。
- **修复**：`install.sh` 横幅、六个页面页脚与设置页版本显示统一到 1.8.15（此前分别滞留 1.8.11 / 1.8.14）。
- **文档归档**：源码全录移入 `docs/source-full.md`（PROJECT.md 第 5 章改为索引，全文从 1.2 万行降到 830 行），版本历史移入本文件（README 只留最近一版摘要）。

### v1.8.14 (2026-11-24)
- **备份/恢复覆盖整个插件**：备份包在原有 5 个 UCI 配置（firewall/network/dhcp/dnssettings/netmanager，含 v6track 跟踪锚点）之外，新增 `/etc/netmanager/` 状态文件——手动黑名单 `blacklist_v4/v6.list` 与中国 IPv4/IPv6 白名单 `china_v4/v6.list`（tar 内 `state/` 子目录，MANIFEST 增加 `STATE_COUNT`/`STATE_FILES`）。跨机恢复或离线恢复后白名单/黑名单无需重新下载订阅即可生效。
- **恢复后自动重应用与重建 cron**：恢复列表文件后按恢复出的配置重应用黑名单（`ban_apply_all`）与已启用的中国 IPv4/IPv6 白名单规则，并重建对应更新 cron；新增 `v6sync_cron_ensure` 在恢复与开机路径补建 `*/10` 前缀同步兜底 cron（此前仅 install.sh 安装时写入，跨机恢复/卸载重装后会缺失）。
- **恢复安全加固**：解压前对 tar 成员做路径预检，拒绝 `../` 与绝对路径成员，防止恶意备份包写穿临时工作目录（与 v1.4.4 更新包预检同口径）。
- **设置页备份列表**：「配置数」列改为「配置/列表」双计数，备份说明注明覆盖范围；旧格式备份（无 STATE_COUNT）列表数记 0，恢复旧备份时保留当前列表文件不动。

### v1.8.13 (2026-11-24)
- **转发与放行分页展示**：自动配套的 `Allow-IPv6-*` 直连放行规则不再显示在「防火墙规则管理」页，移至「端口转发」页新增的「IPv6 端口放行（直连）」区（复用 `port_list` 的 IPV6 段，口径不变：family=ipv6 且 dest=lan 带端口）。该区标注「自动配套 / 自定义」来源，自动配套规则提供启用/禁用开关（新增 `netmanager rule_toggle <索引> <1|0>`，禁用只断直连路径不影响转发，且有确认提示），自定义放行规则可删除；规则页对移出的规则显示条数迁移提示。
- **规则管理页新增「源IP / 目的IP」两列**：`rule_list` 输出末尾追加 `src_ip`/`dest_ip` 两字段（旧版前端按前 9 字段解析，向后兼容），表格空值显示「任意」。此前表格只画区域/协议/端口，dest_ip 锁定目标 GUA 的单机粒度规则看起来像整段 wan→lan 放行，易误读误删；现在粒度一眼可见。编辑表单行为不变（`rule_edit` 只改既有字段，不触碰 src_ip/dest_ip）。
- **插件页响应加 no-cache 头**：`Cache-Control: no-store` + `Pragma: no-cache`，避免版本更新后旧标签页滞留旧版前端 JS、用旧解析逻辑读新后端输出造成编辑表单/列表错乱；更新后普通刷新即可拿到新页面。

### v1.8.12 (2026-11-24)
- **修复翻译端口映射把内部端口暴露公网直连**：v1.8.11 为所有 IPv6 DNAT 映射配套生成 `Allow-IPv6-<外部端口>-<协议>` 放行规则（dest_port=内部端口）。对**有翻译端口**的映射（如 853→38853），fw4 的 DNAT 真实生效打 `ct status dnat` 标记，内建 `ct status dnat accept` 已放行全部转发路径（含直连目标 GUA:外部端口被 dstnat_wan 翻译的路径），配套 ACCEPT 规则纯属冗余，反而让外部**直连目标 GUA:内部端口（38853）也被放行**，绕过了端口翻译。现改为：翻译端口映射不生成配套放行规则，仅**无翻译端口**（外部=内部，DNAT 空操作不打 ct 标记）保留 v1.8.11 机制。
- **存量自愈**：`port_sync_v6` 扫描全部 IPv6 映射（不限于跟踪锚点），发现内部端口≠外部端口且存在历史 `Allow-IPv6` 残留时自动删除并重载防火墙；升级后随每 10 分钟 cron / WAN hotplug 同步自动清理，无需手动干预。`port_add`/`port_edit` 对翻译端口同步清理旧残留，`port_del` 清理逻辑不变。

### v1.8.11 (2026-11-23)
- **IPv6 转发自动配套直连放行规则**：fw4 的 DNAT 无目的地址门槛，直连目标主机 GUA 的入站包同样会被翻译端口（外部→内部），故 forward 链看到的是内部端口。此前 v1.8.10 只建 DNAT，对「无翻译端口」（如 51116→51116，DNAT 空操作不打 ct 标记）直连路径会被默认丢弃（典型表现：RustDesk 等服务的 IPv6 直连不通）。现 port_add 创建 IPv6 DNAT 映射时同步生成 `Allow-IPv6-<外部端口>-<协议>` 放行规则，**dest_port 用内部端口**（匹配 DNAT 翻译后的包）、dest_ip 限定目标 GUA，并纳入 v6track 前缀跟踪；port_edit/port_del 按族联动更新/清理。有翻译端口由 DNAT+ct 放行、本规则兜底，无翻译端口由本规则放行。
- 放行规则按名称前缀（外部端口）精确匹配清理与同步，不误伤用户自定义规则；port_sync_v6 改按名称匹配改写 dest_ip，兼容翻译端口（内部端口≠外部端口）。

### v1.8.10 (2026-11-23)
- **端口转发页支持真正的 IPv6 端口映射**：添加转发选 IPv6/both 时创建 `redirect family=ipv6` 的 DNAT 映射（ipv6:port），与 IPv4 对称；不再默认生成「IPv6 端口放行」ACCEPT 规则。目标填 IPv4 时自动解析该主机当前公网 IPv6 并登记跟踪锚点；解析不到明确报错（DNAT 必须有目标地址）。
- **IPv6 端口放行移出端口转发页**：放行（ACCEPT）规则统一由「规则管理」页维护；端口转发页只保留 IPv4 DNAT 与 IPv6 DNAT 两张表，IPv6 映射表补齐 编辑/删除/跟踪 操作。
- **修复规则管理页「添加规则」无反应**：根因是 `nmFetch` 只给 FormData/string 形态补 CSRF token，`URLSearchParams` 形态漏补 → 403 静默失败。nmFetch 增加 URLSearchParams 分支，并为各操作补 catch 错误回显。
- **编辑/删除按族隔离**：port_edit/port_del 增加族参数，v4/v6 同端口条目互不误伤；删除 v6 映射时同步清理跟踪锚点。

### v1.8.9 (2026-11-21)
- **移除自动拉黑功能**（v1.8.8 引入）：经评估在 china 白名单模型下冗余——白名单外的境外流量默认已丢弃，自动拉黑只是把已丢弃的包再记一遍，无安全增量；SSH 为局域网绑定+仅密钥登录、无爆破面，改 SSH 防爆破同样空转。故整体下线（后端 autoban、cron、设置页面板/查看弹窗、概览计数卡片），安装时自动清理 v1.8.8 残留（定时任务/内存表/历史）。
- **保留**概览页 IPv6 状态（WAN PD 前缀/LAN GUA/默认网关）与 DNS 状态（模式/上游）展示，以及手动黑名单。

### v1.8.8 (2026-11-21)

**新增：自动拉黑（端口扫描防护）+ 系统概览补 IPv6 / DNS 状态**

- 自动拉黑：窗口期内同一境外源 IP 被拦截（NM_DROP4/6 日志）累计 ≥ 阈值次数（默认 5 次 / 10 分钟）自动拉黑。数据源与拦截明细相同，仅作用于已被境外过滤丢包的扫描源
- **纯内存存储**：拉黑列表 / 历史 / 日志全部位于 `/tmp/netmanager`（tmpfs），重启清零、不写闪存；独立 nft 表 `inet netmanager_autoban`，与手动黑名单（闪存持久化）互不影响
- 可配置：启用开关、拦截次数、窗口(分)、**条数上限**（默认 1000，保留最新防内存膨胀）、**TTL 自动过期**（默认 24h，0=不过期，误伤自愈）、**IPv6 按 /64 聚合**（默认开，防扫描源同段换地址）、**白名单**（IP / IPv4 CIDR，护住自家监控/VPS/探针）
- 保护名单：私网 / LAN / 环回 / 链路本地 / ULA / CGNAT / 组播永不拉黑
- 设置页新增自动拉黑面板：只显示数量 + 「查看 / 搜索 / 解封」按钮，弹窗列表支持搜索与一键解封，条目区分「自动 / 手动」标签，自包含高对比配色（亮暗主题均清晰）；境外过滤关闭时给出空转提示
- 每 5 分钟 cron 自动扫描；`netmanager autoban run|status|apply|clear|enable|disable|config` 命令行齐全；卸载自动清理 cron 与内存表
- 系统概览：新增 IPv6 状态（出口 / WAN IPv6 / PD 前缀 / LAN 分发 / 默认路由）、DNS（模式 / 上游服务器）与自动拉黑计数卡片

### v1.8.7 (2026-11-21)

**新增：IPv6 默认网关自愈（v6gw），修复 pppoe 关闭 wan.ipv6 后客户端拿到 SLAAC 地址却没有默认网关、上不了网**

- 新增 `netmanager v6gw [--quiet]` 网关自愈命令，处理两类实测故障：① pppoe 场景为抑制 netifd 自动 `wan_6` 与手动 `wan6` 双 IPv6 WAN 接口冲突（手动 wan6 持续 `Invalid argument` 抖动、频繁重载防火墙搅乱 RA）而关闭 `network.wan.ipv6` 后，pppoe 自带的 IPv6 默认路由随之消失，手动 wan6 只做 PD 委派不装默认路由 → 路由器无 IPv6 默认路由；② odhcpd 默认 `ra_default=0` 仅在路由器有默认路由时才宣告网关 → RA 的 Router lifetime=0，LAN 客户端拿到 SLAAC 地址却没有默认网关。`v6gw` 在 pppoe 且默认路由缺失/指向失效设备时补 `default dev <wan-l3> metric 512`，并在 LAN `ra=server` 时强制 `ra_default=1` 确保始终宣告网关
- 自愈触发：WAN `ifup`/重拨 hotplug 延迟 12s 先跑 `v6gw` 再同步端口目标；`port_sync_v6` 末尾顺带调用 `v6gw`（复用现有每 10 分钟 cron 兜底，前缀续租静默变化也能自愈）；上网设置应用脚本在 SLAAC / RA+DHCPv6 两个 server 分支同步写入 `ra_default=1`
- 说明：`planb` 为 iStoreOS 应急兜底接口（br-lan 上 DHCP 客户端，默认 `auto=0` 不开机启动），正常上网无需启用，与网关故障无关

### v1.8.6 (2026-11-21)

**修复：重启后 LAN 公网 IPv6 分发中断（wan6 dns_search 残留 + peerdns 引号）；静态IP禁止绑定公网 GUA；拦截明细文字看不清；调整：上网设置 IPv6 段移到 WAN 下方**

- 修复重启/重拨后应用 DNS 配置导致 LAN 公网 IPv6 分发中断：**根因**是 `network.wan6` 残留运营商下发的 `dns_search` 选项，本平台（iStoreOS 25.12）netifd 的 dhcpv6 proto 不接受该选项 → `wan_6` setup 报 `ubus error: Invalid argument` 无限重试、PD 续租失败、odhcpd 租约清空、LAN 设备拿不到公网 IPv6。应用脚本现在配置 wan6 后主动清除 `dns_search`（pppoe 的 wan 接受该选项，不受影响）；同时修复写 `peerdns` 时把单引号包进值里（存成带引号的 `'0'`）的隐患，去掉内层引号
- 静态IP分配「完整IPv6地址」字段强制仅允许 ULA（fd/fc 开头）：公网 GUA（2000::/3，如 2408）随运营商前缀重拨变化、SLAAC 后缀随机，设为静态必失效，校验直接拒绝并引导改用 hostid 后缀；在线客户端 IPv6 列新增「动态公网 / ULA」性质标注，避免把动态公网误认为静态绑定
- 上网设置页面顺序调整为 **WAN上网方式 → IPv6获取分发 → LAN口地址 → WAN-DNS → LAN-DNS → dnsmasq → 操作**（CBI 每 Map 绑定单一配置，拆成 4 个 Map 按序渲染，应用按钮逐一提交各 cursor）；关闭各 Map 默认「保存/保存并应用」按钮（`pageaction=false`），全页仅保留一个「应用配置」，消除重复提交入口
- 修复拦截明细面板文字看不清：明细容器误用深色日志样式（`netmanager-log` 浅灰字）导致表头浅底浅字，改为白底深色字表格

### v1.8.5 (2026-11-20)

**新增：拦截明细查看与一键拉黑、静态IP解绑；修复：离线目标 IPv6 放行未正确添加；调整：DNS 自动备份保留 3 份**

- 端口访问日志「防火墙拦截统计(按端口)」支持点击任意行查看被拦截源 IP 明细（源IP/协议/命中端口/次数/最近时间），并可一键拉黑。china_input/china6_input 新增限速日志（`NM_DROP4/NM_DROP6` 前缀，10 条/分钟 burst 20，不影响丢包裁决），后端 `block_detail` 解析 logread 按源 IP 聚合，前端明细面板复用 `blacklist_add` 拉黑
- 静态IP分配在线客户端速览：已绑定设备新增「解绑」按钮（后端 `static_unbind` 按 MAC 降序下标删除 dhcp host，避免多条移位误删，删除后重载 dnsmasq）
- 修复端口转发选 IPv4+IPv6 且目标主机离线/无 IPv6 时「IPv6 没正确添加」：旧版仅在 IPv6 解析成功时登记跟踪锚点，解析失败时放行规则永久「未限定目标」且 `port_sync_v6` 无法自动修正。改为无论解析成功与否都登记 v6track 锚点，主机上线后定时同步自动改写 dest_ip 到正确主机
- DNS 应用前自动备份由保留最近 5 份改为 3 份（`dnssettings-auto-*`，按修改时间排序清理）
- 核实拦截计数无重复累加：解析总和等于各独立 nft 规则计数器之和（china_input 与 china_forward 不叠加，fw4 与 netmanager 表不同优先级丢不同包），白名单 5569 条 CIDR 正常加载；计数增长为公网 IP 被境外扫描的真实累计流量

### v1.8.4 (2026-11-20)

**新增：IPv6 获取与分发模式管理；修复：拦截计数误报、CBI 页面布局；完善：静态IP一键绑定**

- 上网设置新增「IPv6 获取与分发」：WAN 前缀请求长度（PD，auto/60/56/64/不请求）+ LAN 分发模式（服务器状态化 / SLAAC 无状态 / 中继 / 关闭）。写入 iStoreOS 原生网络管理同一套 `dhcp.lan` / `network.wan6` 配置，两边互通；应用脚本不再硬写 `ra/dhcpv6=server`，改为按所选模式生效，中继模式自动配置 wan6 master，前缀长度变化自动重新协商 wan6
- 修复「端口访问日志」累计拦截计数明显错误：旧版 awk 用 `prev_pkts/prev_dport/prev_proto` 跨行借用上下文，把前面 accept 规则（如 Allow-DHCP-Renew 的 udp dport 68）的端口/协议/计数错误套到无端口的 drop 规则（china/ban IP 段拦截）上，出现「端口68拦截几万」的误报。重写为逐行独立解析，计数器/端口/协议只取本行，无端口规则按用途标注（境外IP拦截/黑名单/WAN口丢弃），多协议 `{tcp,udp}` 正确识别
- 修复「上网设置」「静态IP分配」两个 CBI 页面布局与其他菜单不一致：注入标题栏 + 导航 + 单一白卡内容区，页标题/描述移到导航下方，主题头与自绘页面一致；整体移动 cbi-map（保留 form）不破坏表单提交
- 完善静态IP设置：在线客户端速览新增「一键绑定」（创建 dhcp host，含 MAC 校验/去重/IPv4 网段与路由IP 校验）；IPv4 静态地址增加 LAN 网段校验；菜单「静态IPv6分配」更名「静态IP分配」（页面实际管理 IPv4+IPv6）

### v1.8.3 (2026-11-20)

**修正：IPv6 跟踪目标应选 SLAAC 地址，而非 hostid 静态锚点**

- 问题：v6_resolve_target 原先最优先返回「前缀 + hostid」拼出的静态地址（如 `...::3`），但目标主机对外通信实际用的是 SLAAC /64 地址（如 Debian 的 mngtmpaddr `...:17aa:e56e:f552:cdbd`），部分服务只监听/回应该地址
- 解析优先级改为：邻居表中该主机 MAC 在当前前缀下的 SLAAC 地址（排除 hostid 静态地址与 FAILED/INCOMPLETE 死条目，REACHABLE 优先，近似目标机 `grep -v deprecated` 的选址）→ hostid 静态地址兜底 → DHCPv6 租约 → 邻居表任意全局地址
- 修正 hostid 冒号形式拼接：`::3` 与 `/64` 前缀拼接不再产生三冒号非法地址
- SLAAC 临时地址轮换由既有 hotplug / 每 10 分钟 cron 同步自动跟随

### v1.8.2 (2026-11-20)

**新增：收敛客户端 IPv6 地址堆积（路由端根因治理）**

- 问题：odhcpd 按 RFC9096 把历史前缀记在 piofolder，并在每次 RA 中以 `lifetime=0` 持续广播（实测旧前缀失效两小时后仍在播）。客户端按 RFC4862 必须保留这些 deprecated 地址直到记忆过期，表现为"一台设备堆一堆旧前缀 IP"
- 新增 `v6_cleanup_piofolder`：同步时剔除 piofolder 中既非当前前缀、也非 ULA 的条目，重启 odhcpd 后 RA 只含当前前缀 + ULA
- 挂入 `port_sync_v6`（hotplug / 每 10 分钟 cron / DNS 应用三条触发路径自动生效）；DNS 应用脚本改为无条件同步，未登记跟踪也清理
- 建议配合缩短租期：`dhcp.lan.ra_lifetime='1800'`、`max_valid_lifetime='30m'`、`max_preferred_lifetime='15m'`（选项名以 odhcpd 源码 config.c 为准；`ra_valid`/`ra_preferred` 不存在，写了会被忽略），前缀变更后客户端收敛更快；ULA 是否保留由用户按需决定（关闭后 LAN IPv6 DNS 需改用稳定后缀的公网地址）

### v1.8.1 (2026-11-20)

**修复：SSH 自愈判据错误，导致每次 lan ifup 都无谓重启 dropbear**

- v1.8.0 用本机 TCP 自连（`nc 127.0.0.1 <port>`）判断 dropbear 监听是否失效。但 dropbear 设了 `DirectInterface` 后以 `SO_BINDTODEVICE` 绑在该接口上，而本机连自身地址走回环路由，**无论用回环还是 LAN IP 都连不通**——探测恒失败，于是每次 lan ifup 都会重启 dropbear 并踢掉在线会话
- 改为比对绑定网卡的 `ifindex` 是否变化（`/sys/class/net/<dev>/ifindex`），这才是套接字失效的真实判据；首次观测只记录基线、不重启
- DNS 应用路径移除该探测：应用走 `network reload` 不重建 br-lan，本就无需重启 dropbear

**修复：改了 LAN IPv6 DNS 后 RA 仍播旧值**

- 应用脚本在 odhcpd 只有单实例时仅调 `/etc/init.d/odhcpd start`，而服务已在运行时 procd 的 start 是空操作、**不会重读配置**。实测 `dhcp.lan.dns` 已更新，抓包看到的 RDNSS 却仍是旧地址
- 改为无条件 stop + killall + start，强制重读；抓包复验 RDNSS 与配置一致

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
