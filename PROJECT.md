# luci-app-netmanager 项目全景文档（PROJECT.md）

> **基线**：v1.8.14 · main（`ac90559`） · 更新时间 2026-11-26
>
> **本次更新**：①交付形态从「tar.gz 脚本安装」扩展到 **ipk / apk 双格式 + iStore 软件中心上架**，新增 `tools/`、`istore/`、`docs/istore-publish.md` 与 `.github/workflows/publish-istore.yml`（详见 1.4、2.1、3.7、6.3）；②**文档归档**：源码全录迁到 `docs/source-full.md`（本文件第 5 章只留索引）、README 历史更新日志迁到 `docs/CHANGELOG.md`（`build.yml` 也改为从那里提取 Release body）。
>
> **用途**：本文件是维护者的**导航中枢**——文件架构、核心机制、命令参考、发版流程、开发计划、注意事项集中一处，需要细节时按链接进 `docs/` 取全文。
>
> **分工**：README.md 面向用户（安装/使用/发布）；PROJECT.md 面向维护者；docs/source-full.md 存全量源码；docs/CHANGELOG.md 存全部版本历史。
>
> **源码收录**：`docs/source-full.md` 收录除本文件与 LICENSE 外的全部受控文件，由 `docs/gen_source_part.py` 生成；**源码是唯一事实来源**，前文描述与源码冲突时以源码为准。

## 目录

| 章 | 内容 |
|----|------|
| 第 1 章 | 项目概述 |
| 第 2 章 | 完整文件架构 |
| 第 3 章 | 核心机制说明 |
| 第 4 章 | 后端命令参考（CLI） |
| 第 5 章 | 源码索引（每个文件的用途/规模/维护要点；全录见 docs/source-full.md） |
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
| 目标平台 | iStoreOS 25.12+（apk-tools）/ iStoreOS 24.10 及 OpenWrt 23.05–24.10（opkg），fw4 / nftables |
| 交付形态 | **apk（25.12+）/ ipk（opkg 系统）/ tar.gz+install.sh 兜底**，三种等价 |
| 上架渠道 | iStoreOS 软件中心（`istoreos/istore-repo` + `istoreos/openwrt-app-meta`，PR #852 / #743 待合并） |
| 当前版本 | v1.8.14（2026-11-24） |
| 许可证 | MIT（仓库根目录 LICENSE） |
| 前身 | luci-app-fwmanager v1.3.33 + luci-app-dnssettings v1.2.1，v1.4.0 合并 |

### 1.2 功能模块速览

| # | 模块 | 页面 | 后端 |
|---|------|------|------|
| 1 | 系统概览 | overview.htm | overview |
| 2 | 端口转发（IPv4/IPv6 DNAT + IPv6 直连放行区） | port_forward.htm | port_* / port_track_v6 / port_sync_v6 |
| 3 | 防火墙规则 | firewall_rules.htm | rule_* / rule_toggle |
| 4 | SSH 登录日志 | ssh_log.htm | ssh_log |
| 5 | 端口访问日志 | access_log.htm | access_log / block_detail |
| 6 | 中国 IPv4 访问限制 | settings.htm 内区块 | china_filter * |
| 7 | 中国 IPv6 访问限制（v1.7.0） | settings.htm 内区块 | china6_filter * |
| 8 | 手动黑名单 IPv4/IPv6（v1.7.0，支持 CIDR） | settings.htm 内区块 | blacklist * / ban_* |
| 9 | 设置（备份/更新/日志/卸载） | settings.htm | backup* / update_* / log_* / uninstall |
| 10 | 上网设置（CBI 表单） | dns_settings.lua | dnssettings-apply.sh / backup.sh |
| 11 | 静态 IP 分配 IPv4/IPv6（CBI 表单） | dns_staticv6.lua | LuCI 内完成 + static_bind/unbind + odhcpd |

### 1.3 技术栈

| 层 | 技术 | 说明 |
|----|------|------|
| 后端命令 | POSIX sh（BusyBox ash） | /usr/sbin/netmanager，无 bashism |
| Web 后端 | Lua（LuCI 框架） | controller 注册路由 + API 分发 |
| 表单 | LuCI CBI | DNS 两页用标准 Map/NamedSection |
| 自绘页面 | htm 模板 + 原生 JS | fetch 调后端 API，无框架 |
| 配置 | UCI | /etc/config/netmanager、dnssettings、firewall、dhcp、network |
| 防火墙 | fw4 / nftables | 独立表 inet netmanager / netmanager6 / netmanager_ban 与 fw4 并存 |
| 交付 | apk / ipk / tar.gz | 包格式由 `tools/build_apk.sh`、`tools/build_ipk.py` 产出；install.sh 兜底 |
| CI | GitHub Actions | `build.yml`（tag + Release + tar.gz）、`publish-istore.yml`（ipk/apk + 自动提 PR 到 iStore 官方仓库） |

### 1.4 交付格式：为什么同时要 apk 和 ipk

早期文档写过「iStoreOS 的 `/usr/bin/` 是只读 squashfs 分区，标准 ipk 装不了」，实测**不成立**：真因是 **iStoreOS 25.12 起改用 apk-tools，系统里根本没有 opkg**，ipk 自然装不上。

| 系统 | 包管理器 | 该给的包 |
|------|----------|----------|
| iStoreOS 25.12+ / OpenWrt 25.x（apk-tools 3.x） | `apk` | `luci-app-netmanager-<ver>-r<rel>.apk` |
| iStoreOS 24.10 / OpenWrt 23.05–24.10（opkg） | `opkg` | `luci-app-netmanager_<ver>-r<rel>_all.ipk` |
| 任意架构 / 开发态 | 手动 | `tar.gz` + `install.sh` |

两份包都由 CI 产出并附到同一个 Release；`install.sh` 保留为未适配架构与本地开发时的兜底路径，不再是唯一安装方式。

---

## 第 2 章 完整文件架构

### 2.1 目录树（39 个受控文件，基线 v1.8.14 / `ac90559`）

```
luci-app-netmanager/
├── files/usr/sbin/                              # 后端命令层
│   ├── netmanager                               # 核心后端，4226 行（全部 CLI 子命令）
│   ├── dnssettings-apply.sh                     # 540 行（上网设置应用）
│   └── dnssettings-backup.sh                    # 27 行
├── files/usr/lib/lua/luci/
│   ├── controller/netmanager.lua                # 537 行：路由 + API 分发 + 上传
│   ├── model/cbi/netmanager/
│   │   ├── dns_settings.lua                     # 405 行：上网设置表单
│   │   └── dns_staticv6.lua                     # 693 行：静态 IP 分配表单
│   └── view/netmanager/                         # 自绘视图层（9 个 htm）
│       ├── common_head.htm                      # 232 行：公共 CSS+JS（escapeHtml/nmFetch/token）
│       ├── nav.htm                              # 10 行：页内导航
│       ├── cbi_nav.htm                          # 114 行：CBI 页面专用导航
│       ├── overview.htm                         # 118 行：系统概览
│       ├── port_forward.htm                     # 284 行：端口转发（含 IPv6 放行区）
│       ├── firewall_rules.htm                   # 251 行：防火墙规则
│       ├── ssh_log.htm                          # 103 行：SSH 日志
│       ├── access_log.htm                       # 171 行：访问日志
│       └── settings.htm                         # 1107 行：设置（最复杂视图）
├── files/etc/config/
│   ├── netmanager                               # 17 行：防火墙模块 UCI 配置
│   └── dnssettings                              # 22 行：上网设置模块 UCI 配置
├── files/etc/init.d/netmanager-china            # 26 行：开机自启（IPv4/IPv6 过滤 + 黑名单）
├── files/etc/hotplug.d/iface/
│   ├── 95-netmanager-china                      # 30 行：WAN 上线重应用过滤/黑名单
│   └── 96-netmanager-v6sync                     # 62 行：WAN 上线同步 IPv6 转发目标
├── tools/                                       # 打包/发布/文档兜底工具（本地与 CI 共用）
│   ├── build_ipk.py                             # 152 行：打 ipk（tar.gz 外壳）
│   ├── build_apk.sh                             # 77 行：打 apk（openwrt-sdk-mini 的 apk mkpkg）
│   ├── publish_istore.sh                        # 160 行：向两个 iStore 官方仓库提 PR
│   └── ensure_changelog.py                      # 146 行：缺更新日志时按 git log 自动补一节
├── istore/app-meta/
│   ├── Makefile                                 # 17 行：软件中心卡片元数据模板
│   └── logo.png                                 # 40,930 字节，256×256
├── .github/workflows/
│   ├── build.yml                                # 225 行：tag 触发打包 tar.gz + Release
│   ├── publish-istore.yml                       # 107 行：Release 后出 ipk/apk + 自动提 PR
│   └── extract_changelog.awk                    # 17 行：Release body 提取
├── docs/
│   ├── CHANGELOG.md                             # 全部历史版本记录（build.yml 从这里提取 Release body）
│   ├── istore-publish.md                        # 51 行：上架/自动发版配置说明
│   ├── source-full.md                           # 自动生成的源码全录（第 5 章索引指向它）
│   └── gen_source_part.py                       # 271 行：生成 source-full.md + 第 5/9 章
├── install.sh                                   # 143 行：7 步兜底安装
├── .gitattributes                               # 15 行：强制 LF
├── .gitignore                                   # 7 行
├── LICENSE                                      # 21 行（MIT）
├── PROJECT.md                                   # 本文档
└── README.md                                    # 用户文档（安装/CLI/配置/更新日志/发版）
```

> 注：行数为实际值；`logo.png` 二进制按字节计。`PROJECT.md` 与 `LICENSE` 不进入第 5 章源码全录。

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

**发布链（v1.8.14 起新增，与运行链独立）**

```
git push main
  │
  ▼
build.yml ── 校验 README/PLUGIN_VERSION 一致 → sh -n / luac -p 门禁
  │           → tar.gz → 打 tag → Release（body 取自 README 更新日志）
  ▼
release[published] 事件
  │
  ▼
publish-istore.yml ── tools/build_ipk.py → tools/build_apk.sh
  │                  → gh release upload（--clobber）
  │                  → tools/publish_istore.sh（blob→tree→commit→ref→PR）
  ▼
istoreos/istore-repo(base pending)  +  istoreos/openwrt-app-meta(base main)
  │
  ▼
上游 ci-pending.yml：cherry-pick 到 main → 删同名旧包 → ci.yml 刷索引 → 软件中心可见
```

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
| 96-netmanager-v6sync (hotplug) | WAN 上线同步 IPv6 转发目标 | netifd | netmanager port_sync_v6 |
| install.sh | 兜底安装 | 用户 / plugin_update | 文件复制、init、cron |
| build_ipk.py | 打 ipk | CI publish-istore / 本地 | files/、control、data.tar.gz |
| build_apk.sh | 打 apk | CI publish-istore / 本地 | openwrt-sdk-mini、files/ |
| publish_istore.sh | 提上架 PR | publish-istore.yml | GitHub API（两个 fork + 上游 base） |
| build.yml | CI：Release | git push main | tar.gz 资产、tag、Release |
| publish-istore.yml | CI：上架 | release 发布 / workflow_dispatch | ipk+apk 资产、两个官方仓库 PR |
| istore/app-meta/Makefile | 软件中心卡片元数据 | publish_istore.sh（注入版本） | app-meta-<pkg> 包 |

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

### 3.7 iStore 软件中心上架机制

**上游仓库规则（读源码 `linkease/istore` 与两个官方仓库实测确认）**

- iStore 软件中心**没有开发者自助上传入口**，源地址写死在 `/usr/bin/is-opkg`（`https://istore.istoreos.com/repo`，镜像 `repo.istoreos.com`），只读官方 feed；应用卡片来自 `app-meta-<name>` 包的 `meta/<name>.json` + `app-icons/<name>.png`。
- 包目录：ipk 进 `bin/packages/<arch>/<feed>/`，apk 进 `bin/apks/<arch>/<feed>/`；纯 `all` 架构 LuCI 插件统一落 `nas_luci` feed。只收 x86_64 与 aarch64（ipk 用 `aarch64_cortex-a53`，apk 用 `aarch64_generic`）。
- PR 必须打 `pending` 分支；PR 不得改 `repo/` 与 `.github/`（否则 "Don't HACK my workflows"）；CI 用 `tar -xOf <ipk> ./control.tar.gz` 校验，**ipk 必须是 tar.gz 外壳**（内含 `./debian-binary`、`./control.tar.gz`、`./data.tar.gz`），`ar` 格式判 invalid。
- 元数据仓库 `istoreos/openwrt-app-meta`：`applications/app-meta-<name>/` 放 `Makefile`（META_TITLE/META_DESCRIPTION/META_AUTHOR/META_DEPENDS/META_TAGS/META_LUCI_ENTRY/META_WEBSITE/PKG_VERSION/PKG_RELEASE，末尾 `include ../../meta.mk`）+ `logo.png`（≤256×256，≤50KB）。

**本仓库的落地方式**

| 环节 | 实现 |
|------|------|
| 出包 | `tools/build_ipk.py`（固定 mtime、目录 755/文件 644、conffiles/postinst/prerm）、`tools/build_apk.sh`（`apk mkpkg`，depends 含 `luci-base luci-compat nftables-json curl ca-bundle jsonfilter`） |
| 提 PR | `tools/publish_istore.sh`：blob→tree(base_tree 取上游 pending/main 的 tree)→commit→ref(`auto/<pkg>-<ver>-r<rel>`）→PR；已有同 head 的 open PR 则跳过（幂等）；`DRY_RUN=1` 干跑 |
| 触发 | `.github/workflows/publish-istore.yml`（`release[published]` + `workflow_dispatch`），凭 `ISTORE_TOKEN`（classic PAT，`repo` scope）写两个 fork |
| 卡片元数据 | `istore/app-meta/Makefile` + `logo.png`，PKG_VERSION/PKG_RELEASE 由 publish 脚本 sed 注入 |

**实测（真机 iStoreOS 25.12.6 / x86_64 / apk-tools 3.0.5）**：`apk add --allow-untrusted --force-overwrite` 依赖全满足，post-install 清缓存 + 启用 `netmanager-china` + reload uhttpd，三张 nft 表重建；`apk del` 后文件全删、三张表清空、两份 UCI 配置原样保留（无 `.apk-new` 残留）。详见 6.2「v1.8.14 上架验证」。

---

## 第 4 章 后端命令参考（CLI）

> 完整参数以第 5 章源码 usage 与 9.1 命令入口表为准。本章为速查。

### 4.1 命令总表

| 分类 | 命令 | 说明 |
|------|------|------|
| 概览 | overview / version | 防火墙状态、端口统计、网络信息 |
| 端口转发 | port_list | 列出全部 DNAT + IPv6 放行 |
| | port_add <外部端口> <tcp\|udp\|both> <目标IP> <ipv4\|ipv6\|both> [内部端口] | 新增（内部端口可映射不同端号） |
| | port_del <外部端口> <协议> [ipv4\|ipv6\|both] | 删除（按族隔离） |
| | port_edit <旧端口> <旧协议> <新端口> <新协议> <目标IP> <类型> [新内部端口] | 编辑（跨族切换自动补建/清理） |
| | port_track_v6 <端口> <协议> <锚点\|off> / port_sync_v6 | IPv6 目标跟踪与立即同步（v1.8.0+） |
| | v6gw [--quiet] | 补 PPPoE 缺失的 IPv6 默认路由 + ra_default=1（v1.8.7+） |
| 规则 | rule_list / rule_add / rule_edit / rule_del | 自定义通信规则增删改查 |
| | rule_toggle <索引> <1\|0> | 启用/禁用（含 IPv6 放行区开关，v1.8.13+） |
| 日志 | ssh_log [条数] / access_log [端口] [条数] / block_detail <端口\|v4\|v6> | 登录/访问/拦截明细 |
| | log_set 1\|0 / log_get [行数] / log_query [级别] [关键词] [行数] / log_export / log_clear | 运行日志全套 |
| 备份 | backup / backup_list / backup_restore <名> / backup_delete <名> / backup_import <名> / backup_prune [保留数] | 整插件备份（UCI + 黑白名单列表） |
| 上传/更新 | upload_file <文件名>（stdin） / plugin_update / plugin_version / cleanup_uploads | 页面通道与离线更新 |
| | update_check / update_apply / set_update_mirror <url> | 在线更新（Release 资产） |
| 中国过滤 | china_filter status/enable/disable/update/set_url/set_cron | IPv4 白名单（v1.7.0+ 有对称的 china6_filter） |
| 黑名单 | blacklist list/add/del/clear/apply | 手动黑名单，支持单 IP 与 CIDR（v1.7.0+） |
| 静态 IP | static_bind <MAC> [IPv4] [主机名] [DUID] / static_unbind <MAC> | 等价页面一键绑定/解绑 |
| 设置 | settings / set_default_target <IP> | 查看/默认目标 |
| 防火墙 | restart / reload | fw4 操作 |
| DNS | （/usr/sbin/dnssettings-apply.sh / dnssettings-backup.sh） | 应用/备份（非 netmanager 子命令） |
| 卸载 | uninstall [full\|keep] | keep 保留两份 UCI 配置 |

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


## 第 5 章 源码索引（全录见 docs/source-full.md）

> 本章只留索引：每个受控文件的用途、规模、维护要点。**完整源码已归档到 [`docs/source-full.md`](source-full.md)**（§5.x 与下表一一对应，由 `docs/gen_source_part.py` 自动生成）。
> 这样 PROJECT.md 保持可快速通读，又不必为查一段代码去翻 1 万多行。

| § | 文件 | 规模 | 用途 | 维护要点 |
|---|------|------|------|----------|
| §5.1 | `files/usr/sbin/netmanager` | 4226 行 | 后端核心脚本：全部 CLI 子命令（概览/端口转发/规则/日志/备份/上传/在线更新/中国 IPv4·IPv6 过滤/黑名单/卸载） | 单文件约 4200 行，v1.5+ 模块化拆分对象。PLUGIN_VERSION 在 L15（唯一权威源）；命令入口行号见 9.1 |
| §5.2 | `files/usr/sbin/dnssettings-apply.sh` | 540 行 | 上网设置应用脚本：把 /etc/config/dnssettings 写入 network/dhcp/dnsmasq 并 reload 服务 | 空值断网防护（peerdns=0 且 DNS 全空 → 拒写）是核心红线，勿删；应用前自动备份保留 5 份 |
| §5.3 | `files/usr/sbin/dnssettings-backup.sh` | 27 行 | 上网设置备份脚本：独立备份 network/dhcp/dnssettings 到 /root/backup/ | 逻辑简单，注意与 apply 脚本的保留策略一致 |
| §5.4 | `files/usr/lib/lua/luci/controller/netmanager.lua` | 537 行 | LuCI 控制器：注册全部页面路由 + API 分发（action 到后端命令桥接）+ multipart 上传处理 | api_handler 强制 POST；所有拼命令参数必经 shell_escape；csrf_check 403；插件页加 no-store 头防旧 JS |
| §5.5 | `files/usr/lib/lua/luci/model/cbi/netmanager/dns_settings.lua` | 405 行 | 上网设置 CBI 模型：Map 绑定 /etc/config/dnssettings（wan/lan/dnsmasq 三节 + 应用/备份按钮） | forward_v4/forward_v6 为 DynamicList；按钮经 api 触发 POST 动作，不再走 GET 路由 |
| §5.6 | `files/usr/lib/lua/luci/model/cbi/netmanager/dns_staticv6.lua` | 693 行 | 静态 IP 分配 CBI 模型：绑定 dhcp.host + 在线客户端速览（四数据源交叉）+ 冲突检测 | get_online_devices 四源（dnsmasq 租约/ARP/odhcpd/NDP）；first_opt() 替代 ucode 桥无 get_first；merge 只在 on_before_commit 执行 |
| §5.7 | `files/usr/lib/lua/luci/view/netmanager/common_head.htm` | 232 行 | 全部视图公共头：CSS 样式 + 公共 JS（escapeHtml / nmFetch / CSRF token / withBusy） | nmFetch 支持 FormData/string/URLSearchParams 三种体，新增调用勿绕开它 |
| §5.8 | `files/usr/lib/lua/luci/view/netmanager/nav.htm` | 10 行 | 页内导航条：防火墙 6 页 + 上网设置 / 静态 IP 两个 CBI 入口 | 与 controller 菜单双维护，新增页面两处同步 |
| §5.9 | `files/usr/lib/lua/luci/view/netmanager/cbi_nav.htm` | 114 行 | CBI 页面专用导航条：自带内联样式，由两个 CBI 模型以 Template 节点注入 | CBI 页不加载 common_head，样式必须内联；active 判断带 nil 防护 |
| §5.10 | `files/usr/lib/lua/luci/view/netmanager/overview.htm` | 118 行 | 系统概览页：防火墙状态 / 端口统计 / 网络信息 / 快捷操作 | footer 含版本号（登记处 4） |
| §5.11 | `files/usr/lib/lua/luci/view/netmanager/port_forward.htm` | 284 行 | 端口转发管理页：IPv4/IPv6 DNAT 列表 + 「IPv6 端口放行（直连）」区 + 添加/编辑/删除/跟踪 | 放行区来源标注（自动配套/自定义）；删除/编辑一律数组下标传参，不传自由文本 |
| §5.12 | `files/usr/lib/lua/luci/view/netmanager/firewall_rules.htm` | 251 行 | 防火墙规则管理页：自定义规则增删改 + 常用模板一键应用 + 源IP/目的IP 列 | IPv6 放行规则不在此页渲染（v1.8.13 移至端口转发页），保留迁移提示 |
| §5.13 | `files/usr/lib/lua/luci/view/netmanager/ssh_log.htm` | 103 行 | SSH 登录日志页：成功/失败记录 + 失败 IP Top10 + 自动刷新 | 所有字段写 DOM 前转义（v1.4.4 修存储型 XSS） |
| §5.14 | `files/usr/lib/lua/luci/view/netmanager/access_log.htm` | 171 行 | 端口访问日志页：活跃连接 / 入站出站计数 / 拦截统计 | 统一走 nmFetch；footer 版本号（登记处 5） |
| §5.15 | `files/usr/lib/lua/luci/view/netmanager/settings.htm` | 1107 行 | 设置页（最复杂视图，1100 行）：默认目标 / 备份恢复 / 插件更新 / 在线更新 / 中国 IPv4·IPv6 过滤 / 黑名单 / 运行日志 / 卸载 | 三个版本号登记处（L186/L305/L338）；备份列表与过滤状态均需 escapeHtml + 数组下标传参 |
| §5.16 | `files/etc/config/netmanager` | 17 行 | 防火墙模块 UCI 配置：默认目标 IP / 日志开关 / 中国 IPv4·IPv6 过滤参数 / 更新镜像 | china_filter_url/cron 与 china6_filter_url/cron 默认值即官方订阅源 |
| §5.17 | `files/etc/config/dnssettings` | 22 行 | 上网设置模块 UCI 配置：wan / lan / dnsmasq / actions 四节 | wan/lan/dnsmasq 三节由 dns_settings.lua 绑定；actions 为按钮占位 |
| §5.18 | `files/etc/init.d/netmanager-china` | 26 行 | 开机自启脚本：重建中国 IPv4/IPv6 过滤与黑名单 nft 规则 | START/STOP 顺序须晚于防火墙，确保 fw4 就绪 |
| §5.19 | `files/etc/hotplug.d/iface/95-netmanager-china` | 30 行 | WAN 上线热插拔：接口 up 时重应用过滤与黑名单（自愈） | 编号 95 保证在 fw4 默认 hotplug 之后执行 |
| §5.20 | `files/etc/hotplug.d/iface/96-netmanager-v6sync` | 62 行 | WAN 上线热插拔：同步 IPv6 转发目标（前缀变化跟随） | 与 */10 cron 兜底互补，两者都要保留 |
| §5.21 | `install.sh` | 143 行 | 一键安装脚本：7 步安装（复制文件/权限/符号链接/init/cron），支持 SKIP_UHTTPD_RESTART | 版本号登记处 2、3；新增安装产物须三处同步（install.sh / uninstall / files/） |
| §5.22 | `.github/workflows/build.yml` | 252 行 | CI：push main 时从 README 提版本 → 语法门禁 → 打 tar.gz → 打 tag → 发 Release（body 取自更新日志） | tag 已存在则整条跳过；重发同版本用 workflow_dispatch 勾 force |
| §5.23 | `.github/workflows/publish-istore.yml` | 107 行 | CI：Release 发布后构建 ipk/apk、上传 Release 资产、自动向 istoreos/istore-repo（pending）与 openwrt-app-meta（main）提 PR | 依赖 ISTORE_TOKEN；未配置只构建不提 PR；支持 dry_run/version/release 三个手动入参 |
| §5.24 | `.github/workflows/extract_changelog.awk` | 18 行 | Release body 提取脚本：从 docs/CHANGELOG.md 取出指定版本段落 | 注释里的版本号是历史记录，勿改 |
| §5.25 | `tools/build_ipk.py` | 152 行 | 打 ipk 工具：固定 mtime、目录 755/文件 644、脚本可执行位，产出 tar.gz 外壳的 _all.ipk | iStore CI 只认 tar.gz 外壳（ar 格式判 invalid）；支持 --version/--release/--files/--out |
| §5.26 | `tools/build_apk.sh` | 77 行 | 打 apk 工具：缓存 openwrt-sdk-mini，chmod 规范化后调 apk mkpkg，再用 adbdump 自检 | 字段名是 name/version（不是 pkgname/pkgver）；多个 depends 写在同一个 -I 值里空格分隔 |
| §5.27 | `tools/publish_istore.sh` | 160 行 | 上架 PR 工具：blob→tree(base_tree 取上游 pending/main)→commit→ref→PR，幂等（同 head 有 open PR 则跳过） | GH_TOKEN 走 ISTORE_TOKEN；DRY_RUN=1 干跑；请求体走 stdin，避免 argv 过长 |
| §5.28 | `tools/ensure_changelog.py` | 146 行 | 发布兜底：docs/CHANGELOG.md 缺当前版本段落时，按 git log 自动补一节（已存在则不动） | CI 在 syntax gate 后调用；自动补的提交带 `[skip ci]`，避免二次触发发版；纯 docs/ci 提交默认不进 body |
| §5.29 | `istore/app-meta/Makefile` | 17 行 | 软件中心卡片元数据模板：META_TITLE/DESCRIPTION/AUTHOR/DEPENDS/TAGS/LUCI_ENTRY/WEBSITE + PKG_VERSION/PKG_RELEASE | PKG_VERSION/PKG_RELEASE 由 publish 脚本 sed 注入，勿写死；末尾 include ../../meta.mk |
| §5.30 | `docs/gen_source_part.py` | 310 行 | 文档生成器：写 docs/source-full.md 源码全录 + PROJECT.md 第 5 章索引与第 9 章行号表 | 新增受控文件时在 FILES 列表补一条；第 9 章行号自动抓取，无需手改 |
| §5.31 | `docs/CHANGELOG.md` | 380 行 | 全部历史版本记录（v1.8.14 → v1.4.0 → 继承 fwmanager v1.3.33），GitHub Release body 的来源 | 段落标题必须保持 `### vX.Y.Z (日期)`（build.yml 的 awk 按此匹配）；每版在顶部新增小节 |
| §5.32 | `docs/istore-publish.md` | 51 行 | iStore 上架与自动发版说明：一次性 Secret 配置、日常发版流程、本地出包、常见问题 | 与 README「构建与发版」章节互补，改动流水线时两边同步 |
| §5.33 | `.gitattributes` | 15 行 | git 属性：强制文本文件 LF（路由器 BusyBox ash 不能吃 CRLF） | 二进制文件单独标注；CRLF 警告可忽略 |
| §5.34 | `.gitignore` | 7 行 | 忽略构建产物（dist/、ipk/apk、临时 tar.gz）；docs/source-full.md 需要入库，别加进来 | 新增构建输出目录时同步补一条 |
| §5.35 | `README.md` | 399 行 | 用户文档：功能 / 安装（apk·ipk·脚本三路）/ CLI / 配置说明 / 构建与发版 / 更新日志 | L3 版本号是 build.yml 的 tag 提取源（登记处 12）；更新日志已迁到 docs/CHANGELOG.md，本文件只留最近一版摘要 |

> 需要看某个文件的完整内容或某段实现，直接翻 [`docs/source-full.md`](source-full.md) 对应 §5.x 小节；
> 想知道命令/函数在源码里的行号，见第 9 章（同样是自动抓取）。

---

## 第 6 章 更新维护记录

### 6.1 提交历史

> 本工作副本为浅克隆，仅保留最近提交；完整历史见 GitHub `District1655/luci-app-netmanager/commits/main`。

| commit | 日期 | 版本 | 摘要 |
|--------|------|------|------|
| `ac90559` | 2026-11-26 | — | ci: 发版自动构建 ipk/apk 并提 PR 到 iStore（PR #2，7 文件） |
| `bf9d65c` | 2026-11-24 | v1.8.14 | 备份恢复覆盖整插件、恢复后重应用规则与 cron、tar 成员路径预检、修复 MANIFEST `./` 前缀读取 |
| （更早） | 2026-11-19 → 09-02 | v1.4.0–v1.8.13 | fwmanager/dnssettings 合并、在线更新、静态 IPv6、安全修复包、中国 IPv4/IPv6 过滤、手动黑名单、IPv6 端口转发与跟踪 |

**v1.4.6 之前的 13 个基线提交**（`90b2bf9` 时代记录，仅存档）：v1.4.0 合并、v1.4.1 在线更新、v1.4.2 端口映射、v1.4.3 静态 IPv6、v1.4.4 安全修复包（15 处）、v1.4.5 DNS 应用重写、CI Release body 提取、ucode 两处线上问题修复。

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

**v1.8.14 上架验证（2026-11-26，真机 iStoreOS 25.12.6 / x86_64）**

- 真机是 apk 体系（apk-tools 3.0.5，无 opkg），ipk 完全装不上 → 用官方 `openwrt-sdk-mini-25.12.2` 的 `apk mkpkg` 打出 `luci-app-netmanager-1.8.14-r1.apk`（108,363 字节）
- 安装：`apk add --allow-untrusted --force-overwrite` 依赖全满足；post-install 清 LuCI 缓存、启用并启动 `netmanager-china`、reload uhttpd，`inet netmanager`/`netmanager6`/`netmanager_ban` 三张表重建；控制器与 CBI 模型 `loadfile` 全通过
- 卸载：`apk del` 文件全删、pre-deinstall 清三张表、`/etc/config/netmanager` 与 `dnssettings` 原样保留（uci 条目数未变）、无 `.apk-new` 残留
- 上游 PR：`istoreos/istore-repo#852`（base `pending`，ipk+apk 双包）、`istoreos/openwrt-app-meta#743`（base `main`，Makefile+logo），两者 `PR Validate` 均 pass
- 自动化：`publish-istore.yml` 已用 `dry_run=true` 冒烟通过（版本校验、ipk 构建、apk 构建、Secret 探测全绿，提 PR 步骤按预期跳过）

### 6.3 发版流程（标准操作，全程自动化）

```
1. 改版本：files/usr/sbin/netmanager L15 PLUGIN_VERSION（权威源）+ README.md L3 `> 版本：vX.Y.Z`（CI 提取源）
   —— 两处必须一致，publish-istore.yml 第 4 步会校验，不一致直接失败
2. （可选）在 `docs/CHANGELOG.md` 顶部写 `### vX.Y.Z (日期)` 小节。**忘写不阻塞**：CI 的 `Ensure changelog section` 步骤会跑 `tools/ensure_changelog.py`，缺段落就按 `git log` 自动补一节并提交（带 `[skip ci]`，不会二次触发发版）；段落已存在则一律不动
3. git add -A && git commit -m "vX.Y.Z: xxx" && git push origin main
4. build.yml：从 README 提 tag → sh -n / luac -p 门禁 → 打 tar.gz → 打 tag → 发 Release
   （tag 已存在则整条跳过；需要重发同版本时手动 workflow_dispatch 勾 force）
5. publish-istore.yml（release[published] 自动触发）：
   校验版本一致 → build_ipk.py → build_apk.sh → ls dist → gh release upload --clobber
   → 探测 ISTORE_TOKEN → publish_istore.sh（两个官方仓库各开一个 PR）
6. 官方合并 pending 后：上游 ci-pending.yml cherry-pick 到 main、删同名旧包、ci.yml 刷索引
7. 验证：GitHub Release 资产（含 ipk/apk）、两个 PR 的 PR Validate、软件中心能否搜到
```

**一次性配置（已就位）**

| 项 | 值/位置 |
|----|---------|
| Secret | 仓库 `Settings → Secrets and variables → Actions → ISTORE_TOKEN`（classic PAT，勾 `repo`；不需要 `workflow`，发布只推分支/开 PR，不改 `.github/`） |
| 未配 Secret 时 | 流水线照常构建并挂 Release，只跳过提 PR，日志有 `::notice::` 提示 |
| 干跑 | `gh workflow run publish-istore.yml -f version=1.8.14 -f release=1 -f dry_run=true` |
| 同版本重发 | 换 release 号：`-f release=2` → 文件名变 `-r2`，PR 分支名同步变化 |
| 分支命名 | `auto/luci-app-netmanager-<ver>-r<rel>`、`auto/app-meta-luci-app-netmanager-<ver>`；同 head 已有 open PR 则跳过（幂等） |

> 注意：官方 PR 未合并前不要急着升版本发 Release，否则会多开一个「新增新版本包」的重复 PR。等 `istoreos/istore-repo#852` / `istoreos/openwrt-app-meta#743` 落地后再走日常节奏。

### 6.4 版本号登记处（12 处，发版必改）

| # | 文件 | 位置 |
|---|------|------|
| 1 | files/usr/sbin/netmanager | L15 `PLUGIN_VERSION`（唯一权威源） |
| 2 | install.sh | L3 头注释 |
| 3 | install.sh | L8 横幅 |
| 4 | view/netmanager/overview.htm | L73 footer |
| 5 | view/netmanager/port_forward.htm | L94 footer |
| 6 | view/netmanager/firewall_rules.htm | L119 footer |
| 7 | view/netmanager/ssh_log.htm | L47 footer |
| 8 | view/netmanager/access_log.htm | L55 footer |
| 9 | view/netmanager/settings.htm | L186 `online_cur_version` |
| 10 | view/netmanager/settings.htm | L305 `plugin_version` |
| 11 | view/netmanager/settings.htm | L338 footer |
| 12 | README.md | L3 `> 版本：vX.Y.Z`（build.yml 提取 tag 的源；publish-istore 也会校验与 PLUGIN_VERSION 一致） |

**不要动的版本号**（有意保留的历史记录，注释里的 `v1.8.x` 是变更标记）：

- 各文件里形如 `v1.8.10：`、`v1.8.12：` 的注释
- `.github/workflows/extract_changelog.awk` 注释中的版本

### 6.5 维护节奏约定

- 修复轮发版：收集一轮问题 → 批量修复 → 一次 commit + tag（如 v1.4.4 15 处一包）
- 更新日志：每个版本必须写 README 小节（漏写会导致 Release body 为空，v1.4.4 曾发生，aad4460 补救）
- 发版后验证三处：GitHub Release 资产（tar.gz + ipk + apk）、`publish-istore.yml` 跑出的两个 PR 的 `PR Validate`、路由器在线更新链路
- 上架节奏：官方 PR 在审期间只做修复不加版本；官方合并后每版等上游 pending→main 同步（通常几分钟）再发下一个版本

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
- **包管理器分水岭**：iStoreOS 25.12 / OpenWrt 25.x 起是 apk-tools（无 opkg）→ 出 `.apk`；iStoreOS 24.10 及更早、OpenWrt 23.05–24.10 是 opkg → 出 `.ipk`。两者不可互换，别拿 ipk 去 25.12 上试
- 包内 `Depends` 统一声明：`libc luci-base luci-compat nftables-json curl ca-bundle jsonfilter`；25.12 真机实测全满足
- BusyBox ash 兼容：脚本无 bashism，wget/uclient-fetch/curl 三工具兜底下载
- jsonfilter 依赖（update_check API 解析），系统默认自带
- LuCI Lua 版（23.05 Lua controller + luci-compat）；OpenWrt 主分支 JS 化迁移评估在 v1.5+ 路线
- 配置保护：apk 升级会把改过的 `/etc/config/*` 落成 `.apk-new`，属正常行为；重装/卸载不会删 UCI 配置

---

## 第 9 章 快速索引（行号定位表）

> 行号由 `docs/gen_source_part.py` 从当前源码自动抓取（v1.8.14 / main），改动后重跑本脚本即可刷新。

### 9.1 后端 netmanager（4226 行）—— 命令入口

| 行 | 命令 | 行 | 命令 |
|----|------|----|------|
| L129 | `cmd_overview` | L266 | `cmd_port_list` |
| L553 | `cmd_port_add` | L691 | `cmd_port_edit` |
| L819 | `cmd_port_del` | L1040 | `cmd_port_track_v6` |
| L1092 | `cmd_port_sync_v6` | L1229 | `cmd_v6gw` |
| L1347 | `cmd_rule_list` | L1383 | `cmd_rule_add` |
| L1421 | `cmd_rule_edit` | L1451 | `cmd_rule_toggle` |
| L1469 | `cmd_rule_del` | L1486 | `cmd_ssh_log` |
| L1543 | `cmd_access_log` | L1674 | `cmd_block_detail` |
| L1725 | `cmd_static_bind` | L1791 | `cmd_static_unbind` |
| L1823 | `cmd_restart` | L1828 | `cmd_reload` |
| L1833 | `cmd_backup` | L1900 | `cmd_backup_list` |
| L1941 | `cmd_backup_restore` | L2047 | `cmd_backup_delete` |
| L2074 | `cmd_backup_import` | L2111 | `cmd_backup_prune` |
| L2134 | `cmd_upload_file` | L2197 | `cmd_plugin_update` |
| L2326 | `cmd_plugin_version` | L2384 | `cmd_cleanup_uploads` |
| L2436 | `cmd_update_check` | L2512 | `cmd_update_apply` |
| L2623 | `cmd_set_update_mirror` | L2645 | `cmd_set_default_target` |
| L2655 | `cmd_log_set` | L2674 | `cmd_log_get` |
| L2694 | `cmd_log_clear` | L2709 | `cmd_log_query` |
| L2778 | `cmd_log_export` | L2796 | `cmd_settings` |
| L2818 | `cmd_version` | L3191 | `cmd_china_status` |
| L3219 | `cmd_china_set_url` | L3233 | `cmd_china_set_cron` |
| L3248 | `cmd_china_enable` | L3267 | `cmd_china_disable` |
| L3277 | `cmd_china_update` | L3303 | `cmd_china_boot` |
| L3333 | `cmd_china_filter` | L3652 | `cmd_china6_status` |
| L3680 | `cmd_china6_set_url` | L3694 | `cmd_china6_set_cron` |
| L3709 | `cmd_china6_enable` | L3728 | `cmd_china6_disable` |
| L3738 | `cmd_china6_update` | L3752 | `cmd_china6_boot` |
| L3760 | `cmd_china6_filter` | L3946 | `cmd_ban_list` |
| L3970 | `cmd_ban_add` | L4004 | `cmd_ban_del` |
| L4024 | `cmd_ban_clear` | L4037 | `cmd_blacklist` |
| L4056 | `cmd_uninstall` | | |

### 9.2 controller/netmanager.lua（537 行）

| 行 | 函数/职责 |
|----|-----------|
| L7 | `index()` |
| L31 | `dns_legacy_redirect()` |
| L43 | `csrf_token()` |
| L48 | `csrf_check()` |
| L58 | `shell_escape()` |
| L69 | `form_str()` |
| L79 | `arg()` |
| L93 | `setup_upload_handler()` |
| L154 | `api_handler()` |

### 9.3 视图 settings.htm（1107 行）—— 前端函数

| 行 | 函数 |
|----|------|
| L343 | `loadSettings()` |
| L362 | `checkUpdate()` |
| L402 | `applyUpdate()` |
| L421 | `saveUpdateMirror()` |
| L430 | `saveLogSetting()` |
| L439 | `loadRunLog()` |
| L517 | `clearRunLog()` |
| L527 | `exportLog()` |
| L565 | `saveDefaultTarget()` |
| L575 | `runAction()` |
| L584 | `doBackup()` |
| L593 | `listBackups()` |
| L647 | `importBackup()` |
| L674 | `pruneBackups()` |
| L688 | `formatSize()` |
| L694 | `restoreBackup()` |
| L710 | `deleteBackup()` |
| L726 | `uploadPlugin()` |
| L768 | `loadChinaStatus()` |
| L814 | `onCronPresetChangeFor()` |
| L821 | `onCronPresetChange()` |
| L825 | `saveChinaUrl()` |
| L835 | `saveChinaCron()` |
| L849 | `setChinaBtns()` |
| L856 | `enableChinaFilter()` |
| L866 | `disableChinaFilter()` |
| L876 | `updateChinaFilter()` |
| L886 | `loadChina()` |
| L929 | `saveChina()` |
| L939 | `saveChina()` |
| L953 | `setChina()` |
| L960 | `enableChina()` |
| L970 | `disableChina()` |
| L980 | `updateChina()` |
| L992 | `renderBanList()` |
| L1007 | `loadBlacklist()` |
| L1036 | `addBlacklistEntry()` |
| L1047 | `deleteBlacklistEntry()` |
| L1059 | `clearBlacklist()` |
| L1069 | `uninstallPlugin()` |

### 9.4 其余文件快速定位

| 文件 | 定位方式 |
|------|----------|
| dnssettings-apply.sh | 抓 `WARN`/`detect_wan_iface`/`ADDED_DNS` 三个关键字 |
| dns_staticv6.lua | 抓 `get_online_devices` / `merge_duplicate_hosts` / `first_opt` / `on_before_commit` |
| dns_settings.lua | 抓 `cbi_nav`（注入导航）与 `dns_apply`/`dns_backup` |
| common_head.htm | 抓 `escapeHtml` / `nmFetch` / `withBusy` |
| install.sh | 版本号 L3/L8；符号链接 `/bin/netmanager` |
| build.yml | 版本提取、tag 判重、tar.gz 打包、Release 四段 |
| publish-istore.yml | 版本校验 → 构建 ipk → 构建 apk → Release 上传 → token 探测 → 提 PR 六段 |
| tools/build_apk.sh | 抓 `apk mkpkg`（字段与 depends 写法是坑点） |
| tools/publish_istore.sh | 抓 `base_tree` / `pulls`（PR 幂等与干跑逻辑） |

---


---

## 附录 A：项目信息卡

| 项 | 值 |
|----|----|
| 仓库 | District1655/luci-app-netmanager |
| 分支 | main |
| 基线 commit | `ac90559`（v1.8.14 + iStore 发版 CI） |
| 版本 | v1.8.14（2026-11-24） |
| 受控文件 | 38 个（文本 34 个进源码全录，`.gitattributes`/`LICENSE` 等按需） |
| 代码量 | 约 830 行文档 + 11,400 行源码全录 + 约 9,000 行受控源码 |
| 交付 | apk（25.12+）/ ipk（opkg）/ tar.gz 脚本 / iStore 软件中心 |
| CI | `build.yml`（Release）+ `publish-istore.yml`（ipk/apk + 自动提 PR） |
| 推送方式 | SSH |
| 文档生成 | `docs/source-full.md`（全录）+ 第 5 章索引 + 第 9 章行号表由 `python3 docs/gen_source_part.py` 生成；其余手写 |

## 附录 B：文档维护约定

1. **发版时**：改两处版本号即可；`docs/CHANGELOG.md` 段落可选（漏写由 CI 自动补）+ 第 6 章与 6.4 按需更新
2. **源码改动后**：跑 `python3 docs/gen_source_part.py`，一条命令同时刷新 `docs/source-full.md`、第 5 章索引规模、第 9 章行号表
3. **流水线改动后**：同步 `README.md`「构建与发版」、`docs/istore-publish.md`、3.7、6.3 四处
4. **新增受控文件**：`docs/gen_source_part.py` 的 `FILES` 列表加一条 + 2.1 目录树补一行（行数写实际值）
5. **修复待办时**：第 7 章清单状态更新（修完移到第 6 章对应版本小节）
6. **文档归档边界（2026-11-26 起）**：全量源码只在 `docs/source-full.md`，本文件第 5 章不放正文；版本历史只在 `docs/CHANGELOG.md`，README 只留最近一版摘要。本文件负责"结构、机制、流程、索引"，字数控制在 1000 行以内，超了就该往外挪
7. **不要手改生成物**：`docs/source-full.md`、第 5 章表格、第 9 章行号表都由脚本产出，手改会在下次重跑时被覆盖
