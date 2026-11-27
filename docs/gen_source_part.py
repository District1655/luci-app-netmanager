#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_source_part.py - 重新生成 PROJECT.md 的「第 5 章 源码全录」与「第 9 章 快速索引」

用法（仓库根目录或任意目录）:
    python3 docs/gen_source_part.py              # 生成并直接改写 PROJECT.md
    python3 docs/gen_source_part.py --part out.md  # 只输出第 5 章片段到文件

设计说明:
- 取代原 docs/gen_source_part.sh（Windows 开发机没有 bash，无法执行）。
- 新增/删除受控文件时，只需在 FILES 列表里增删一条（path/lang/desc/note 四元组）。
- 第 5 章：按 FILES 顺序嵌入全文；内容含 ``` 的文件自动升级为 4 反引号围栏。
- 第 9 章：自动从源码里抓函数入口行号生成定位表，不再手工维护（旧表停在 v1.4.5）。
"""
import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = os.path.join(ROOT, "PROJECT.md")

# ---------------------------------------------------------------- 受控文件清单
# (路径, 语言, 用途, 维护要点)
FILES = [
    ("files/usr/sbin/netmanager", "bash",
     "后端核心脚本：全部 CLI 子命令（概览/端口转发/规则/日志/备份/上传/在线更新/中国 IPv4·IPv6 过滤/黑名单/卸载）",
     "单文件约 4200 行，v1.5+ 模块化拆分对象。PLUGIN_VERSION 在 L15（唯一权威源）；命令入口行号见 9.1"),
    ("files/usr/sbin/dnssettings-apply.sh", "bash",
     "上网设置应用脚本：把 /etc/config/dnssettings 写入 network/dhcp/dnsmasq 并 reload 服务",
     "空值断网防护（peerdns=0 且 DNS 全空 → 拒写）是核心红线，勿删；应用前自动备份保留 5 份"),
    ("files/usr/sbin/dnssettings-backup.sh", "bash",
     "上网设置备份脚本：独立备份 network/dhcp/dnssettings 到 /root/backup/",
     "逻辑简单，注意与 apply 脚本的保留策略一致"),
    ("files/usr/lib/lua/luci/controller/netmanager.lua", "lua",
     "LuCI 控制器：注册全部页面路由 + API 分发（action 到后端命令桥接）+ multipart 上传处理",
     "api_handler 强制 POST；所有拼命令参数必经 shell_escape；csrf_check 403；插件页加 no-store 头防旧 JS"),
    ("files/usr/lib/lua/luci/model/cbi/netmanager/dns_settings.lua", "lua",
     "上网设置 CBI 模型：Map 绑定 /etc/config/dnssettings（wan/lan/dnsmasq 三节 + 应用/备份按钮）",
     "forward_v4/forward_v6 为 DynamicList；按钮经 api 触发 POST 动作，不再走 GET 路由"),
    ("files/usr/lib/lua/luci/model/cbi/netmanager/dns_staticv6.lua", "lua",
     "静态 IP 分配 CBI 模型：绑定 dhcp.host + 在线客户端速览（四数据源交叉）+ 冲突检测",
     "get_online_devices 四源（dnsmasq 租约/ARP/odhcpd/NDP）；first_opt() 替代 ucode 桥无 get_first；merge 只在 on_before_commit 执行"),
    ("files/usr/lib/lua/luci/view/netmanager/common_head.htm", "html",
     "全部视图公共头：CSS 样式 + 公共 JS（escapeHtml / nmFetch / CSRF token / withBusy）",
     "nmFetch 支持 FormData/string/URLSearchParams 三种体，新增调用勿绕开它"),
    ("files/usr/lib/lua/luci/view/netmanager/nav.htm", "html",
     "页内导航条：防火墙 6 页 + 上网设置 / 静态 IP 两个 CBI 入口",
     "与 controller 菜单双维护，新增页面两处同步"),
    ("files/usr/lib/lua/luci/view/netmanager/cbi_nav.htm", "html",
     "CBI 页面专用导航条：自带内联样式，由两个 CBI 模型以 Template 节点注入",
     "CBI 页不加载 common_head，样式必须内联；active 判断带 nil 防护"),
    ("files/usr/lib/lua/luci/view/netmanager/overview.htm", "html",
     "系统概览页：防火墙状态 / 端口统计 / 网络信息 / 快捷操作",
     "footer 含版本号（登记处 4）"),
    ("files/usr/lib/lua/luci/view/netmanager/port_forward.htm", "html",
     "端口转发管理页：IPv4/IPv6 DNAT 列表 + 「IPv6 端口放行（直连）」区 + 添加/编辑/删除/跟踪",
     "放行区来源标注（自动配套/自定义）；删除/编辑一律数组下标传参，不传自由文本"),
    ("files/usr/lib/lua/luci/view/netmanager/firewall_rules.htm", "html",
     "防火墙规则管理页：自定义规则增删改 + 常用模板一键应用 + 源IP/目的IP 列",
     "IPv6 放行规则不在此页渲染（v1.8.13 移至端口转发页），保留迁移提示"),
    ("files/usr/lib/lua/luci/view/netmanager/ssh_log.htm", "html",
     "SSH 登录日志页：成功/失败记录 + 失败 IP Top10 + 自动刷新",
     "所有字段写 DOM 前转义（v1.4.4 修存储型 XSS）"),
    ("files/usr/lib/lua/luci/view/netmanager/access_log.htm", "html",
     "端口访问日志页：活跃连接 / 入站出站计数 / 拦截统计",
     "统一走 nmFetch；footer 版本号（登记处 5）"),
    ("files/usr/lib/lua/luci/view/netmanager/ip_filter.htm", "html",
     "IP过滤页（v1.8.19 新增）：中国 IPv4 / IPv6 访问限制 + 手动黑名单 / 白名单，四个子页签切换",
     "四个页签由 nmSwitchPane/nmInitPanes 控制（localStorage 记忆）；四块内容从 settings.htm 迁入，JS 同步迁入本页"),
    ("files/usr/lib/lua/luci/view/netmanager/settings.htm", "html",
     "设置页：默认转发目标 / 系统工具 / 备份恢复 / 在线更新 / 插件更新 / 运行日志 / 卸载",
     "三个版本号登记处（online_cur_version / plugin_version / footer）；v1.8.19 起过滤与名单已迁到 ip_filter.htm"),
    ("files/etc/config/netmanager", "uci",
     "防火墙模块 UCI 配置：默认目标 IP / 日志开关 / 中国 IPv4·IPv6 过滤参数 / 更新镜像",
     "china_filter_url/cron 与 china6_filter_url/cron 默认值即官方订阅源"),
    ("files/etc/config/dnssettings", "uci",
     "上网设置模块 UCI 配置：wan / lan / dnsmasq / actions 四节",
     "wan/lan/dnsmasq 三节由 dns_settings.lua 绑定；actions 为按钮占位"),
    ("files/etc/init.d/netmanager-china", "bash",
     "开机自启脚本：重建中国 IPv4/IPv6 过滤与黑名单 nft 规则",
     "START/STOP 顺序须晚于防火墙，确保 fw4 就绪"),
    ("files/etc/hotplug.d/iface/95-netmanager-china", "bash",
     "WAN 上线热插拔：接口 up 时重应用过滤与黑名单（自愈）",
     "编号 95 保证在 fw4 默认 hotplug 之后执行"),
    ("files/etc/hotplug.d/iface/96-netmanager-v6sync", "bash",
     "WAN 上线热插拔：同步 IPv6 转发目标（前缀变化跟随）",
     "与 */10 cron 兜底互补，两者都要保留"),
    ("install.sh", "bash",
     "一键安装脚本：7 步安装（复制文件/权限/符号链接/init/cron），支持 SKIP_UHTTPD_RESTART",
     "版本号登记处 2、3；新增安装产物须三处同步（install.sh / uninstall / files/）"),
    (".github/workflows/build.yml", "yaml",
     "CI：push main 时从 README 提版本 → 语法门禁 → 打 tar.gz → 打 tag → 发 Release（body 取自更新日志）",
     "tag 已存在则整条跳过；重发同版本用 workflow_dispatch 勾 force"),
    (".github/workflows/publish-istore.yml", "yaml",
     "CI：Release 发布后构建 ipk/apk、上传 Release 资产、自动向 istoreos/istore-repo（pending）与 openwrt-app-meta（main）提 PR",
     "依赖 ISTORE_TOKEN；未配置只构建不提 PR；支持 dry_run/version/release 三个手动入参"),
    (".github/workflows/extract_changelog.awk", "awk",
     "Release body 提取脚本：从 docs/CHANGELOG.md 取出指定版本段落",
     "注释里的版本号是历史记录，勿改"),
    ("tools/build_ipk.py", "python",
     "打 ipk 工具：固定 mtime、目录 755/文件 644、脚本可执行位，产出 tar.gz 外壳的 _all.ipk",
     "iStore CI 只认 tar.gz 外壳（ar 格式判 invalid）；支持 --version/--release/--files/--out"),
    ("tools/build_apk.sh", "bash",
     "打 apk 工具：缓存 openwrt-sdk-mini，chmod 规范化后调 apk mkpkg，再用 adbdump 自检",
     "字段名是 name/version（不是 pkgname/pkgver）；多个 depends 写在同一个 -I 值里空格分隔"),
    ("tools/publish_istore.sh", "bash",
     "上架 PR 工具：blob→tree(base_tree 取上游 pending/main)→commit→ref→PR，幂等（同 head 有 open PR 则跳过）",
     "GH_TOKEN 走 ISTORE_TOKEN；DRY_RUN=1 干跑；请求体走 stdin，避免 argv 过长"),
    ("tools/ensure_changelog.py", "python",
     "发布兜底：docs/CHANGELOG.md 缺当前版本段落时，按 git log 自动补一节（已存在则不动）",
     "CI 在 syntax gate 后调用；自动补的提交带 `[skip ci]`，避免二次触发发版；纯 docs/ci 提交默认不进 body"),
    ("istore/app-meta/Makefile", "make",
     "软件中心卡片元数据模板：META_TITLE/DESCRIPTION/AUTHOR/DEPENDS/TAGS/LUCI_ENTRY/WEBSITE + PKG_VERSION/PKG_RELEASE",
     "PKG_VERSION/PKG_RELEASE 由 publish 脚本 sed 注入，勿写死；末尾 include ../../meta.mk"),
    ("docs/gen_source_part.py", "python",
     "文档生成器：写 docs/source-full.md 源码全录 + PROJECT.md 第 5 章索引与第 9 章行号表",
     "新增受控文件时在 FILES 列表补一条；第 9 章行号自动抓取，无需手改"),
    ("docs/CHANGELOG.md", "markdown",
     "全部历史版本记录（v1.8.14 → v1.4.0 → 继承 fwmanager v1.3.33），GitHub Release body 的来源",
     "段落标题必须保持 `### vX.Y.Z (日期)`（build.yml 的 awk 按此匹配）；每版在顶部新增小节"),
    ("docs/istore-publish.md", "markdown",
     "iStore 上架与自动发版说明：一次性 Secret 配置、日常发版流程、本地出包、常见问题",
     "与 README「构建与发版」章节互补，改动流水线时两边同步"),
    (".gitattributes", "text",
     "git 属性：强制文本文件 LF（路由器 BusyBox ash 不能吃 CRLF）",
     "二进制文件单独标注；CRLF 警告可忽略"),
    (".gitignore", "text",
     "忽略构建产物（dist/、ipk/apk、临时 tar.gz）；docs/source-full.md 需要入库，别加进来",
     "新增构建输出目录时同步补一条"),
    ("README.md", "markdown",
     "用户文档：功能 / 安装（apk·ipk·脚本三路）/ CLI / 配置说明 / 构建与发版 / 更新日志",
     "L3 版本号是 build.yml 的 tag 提取源（登记处 12）；更新日志已迁到 docs/CHANGELOG.md，本文件只留最近一版摘要"),
]

CH5_BEGIN = "## 第 5 章 源码索引（全录见 docs/source-full.md）"
CH5_END_MARK = "## 第 6 章 更新维护记录"
CH9_BEGIN = "## 第 9 章 快速索引（行号定位表）"
CH9_END_MARK = "## 附录 A：项目信息卡"
FULL_DOC = os.path.join(ROOT, "docs", "source-full.md")


def read_text(path):
    with open(path, "r", encoding="utf-8", newline="") as f:
        return f.read().replace("\r\n", "\n")


# ---------------------------------------------------------------- 第 5 章（全录，写进 docs/source-full.md）
def build_ch5_full():
    out = []
    out.append("# 源码全录（docs/source-full.md）")
    out.append("")
    out.append("> 本文件由 `docs/gen_source_part.py` 自动生成，请勿手改；改动源码后重跑脚本。")
    out.append("> 收录除 `PROJECT.md` / `LICENSE` 外的全部受控文件（33 个）。**源码是唯一事实来源**：")
    out.append("> `PROJECT.md` 里的描述与这里不一致时，以本文件（即实际源码）为准。")
    out.append("> 章节号 §5.x 与 `PROJECT.md` 第 5 章索引表一一对应。")
    out.append("")
    for n, (rel, lang, desc, note) in enumerate(FILES, start=1):
        full = os.path.join(ROOT, rel.replace("/", os.sep))
        if not os.path.isfile(full):
            sys.exit("!! 文件缺失: %s" % rel)
        body = read_text(full)
        lines = body.count("\n") + (0 if body.endswith("\n") else 1)
        fence = "````" if "```" in body else "```"
        out.append("### 5.%d %s" % (n, rel))
        out.append("")
        out.append("- **用途**：%s" % desc)
        out.append("- **规模**：%d 行" % lines)
        out.append("- **维护要点**：%s" % note)
        out.append("")
        out.append(fence + lang)
        out.append(body if body.endswith("\n") else body + "\n")
        out.append("")
        out.append(fence)
        out.append("")
    out.append("> 第 5 章结束。以下为第 6 章起的手写章节。")
    return "\n".join(out)


# ---------------------------------------------------------------- 第 5 章（索引，写进 PROJECT.md）
def build_ch5_index():
    out = [CH5_BEGIN, ""]
    out.append("> 本章只留索引：每个受控文件的用途、规模、维护要点。**完整源码已归档到 "
               "[`docs/source-full.md`](source-full.md)**（§5.x 与下表一一对应，由 `docs/gen_source_part.py` 自动生成）。")
    out.append("> 这样 PROJECT.md 保持可快速通读，又不必为查一段代码去翻 1 万多行。")
    out.append("")
    out.append("| § | 文件 | 规模 | 用途 | 维护要点 |")
    out.append("|---|------|------|------|----------|")
    for n, (rel, lang, desc, note) in enumerate(FILES, start=1):
        full = os.path.join(ROOT, rel.replace("/", os.sep))
        if not os.path.isfile(full):
            sys.exit("!! 文件缺失: %s" % rel)
        body = read_text(full)
        lines = body.count("\n") + (0 if body.endswith("\n") else 1)
        # 表格里不能有裸换行与竖线
        out.append("| §5.%d | `%s` | %d 行 | %s | %s |"
                   % (n, rel, lines, desc.replace("|", "\\|"), note.replace("|", "\\|")))
    out.append("")
    out.append("> 需要看某个文件的完整内容或某段实现，直接翻 [`docs/source-full.md`](source-full.md) 对应 §5.x 小节；")
    out.append("> 想知道命令/函数在源码里的行号，见第 9 章（同样是自动抓取）。")
    return "\n".join(out)
def grep_lines(rel, pattern, flags=0):
    path = os.path.join(ROOT, rel.replace("/", os.sep))
    rx = re.compile(pattern, flags)
    res = []
    for i, line in enumerate(read_text(path).split("\n"), start=1):
        if rx.search(line):
            res.append((i, line.strip()))
    return res


def build_ch9():
    nm = "files/usr/sbin/netmanager"
    ctrl = "files/usr/lib/lua/luci/controller/netmanager.lua"
    settings = "files/usr/lib/lua/luci/view/netmanager/settings.htm"

    nm_total = read_text(os.path.join(ROOT, nm.replace("/", os.sep))).count("\n")
    ctrl_total = read_text(os.path.join(ROOT, ctrl.replace("/", os.sep))).count("\n")
    st_total = read_text(os.path.join(ROOT, settings.replace("/", os.sep))).count("\n")

    out = [CH9_BEGIN, "",
           "> 行号由 `docs/gen_source_part.py` 从当前源码自动抓取（v1.8.14 / main），改动后重跑本脚本即可刷新。",
           "",
           "### 9.1 后端 netmanager（%d 行）—— 命令入口" % nm_total, "",
           "| 行 | 命令 | 行 | 命令 |", "|----|------|----|------|"]

    cmds = grep_lines(nm, r"^cmd_[a-z0-9_]+\(\)")
    for i in range(0, len(cmds), 2):
        left = cmds[i]
        right = cmds[i + 1] if i + 1 < len(cmds) else (0, "")
        if right[0]:
            out.append("| L%s | `%s` | L%s | `%s` |" % (left[0], left[1].split("(")[0], right[0], right[1].split("(")[0]))
        else:
            out.append("| L%s | `%s` | | |" % (left[0], left[1].split("(")[0]))

    out += ["", "### 9.2 controller/netmanager.lua（%d 行）" % ctrl_total, "",
            "| 行 | 函数/职责 |", "|----|-----------|"]
    for ln, text in grep_lines(ctrl, r"^(local |)function "):
        name = re.sub(r"^local function |^function ", "", text)
        name = name.split("(")[0]
        out.append("| L%d | `%s()` |" % (ln, name))

    out += ["", "### 9.3 视图 settings.htm（%d 行）—— 前端函数" % st_total, "",
            "| 行 | 函数 |", "|----|------|"]
    for ln, text in grep_lines(settings, r"function [a-zA-Z_]+"):
        m = re.search(r"function ([a-zA-Z_]+)", text)
        if m:
            out.append("| L%d | `%s()` |" % (ln, m.group(1)))

    out += ["", "### 9.4 其余文件快速定位", "",
            "| 文件 | 定位方式 |", "|------|----------|",
            "| dnssettings-apply.sh | 抓 `WARN`/`detect_wan_iface`/`ADDED_DNS` 三个关键字 |",
            "| dns_staticv6.lua | 抓 `get_online_devices` / `merge_duplicate_hosts` / `first_opt` / `on_before_commit` |",
            "| dns_settings.lua | 抓 `cbi_nav`（注入导航）与 `dns_apply`/`dns_backup` |",
            "| common_head.htm | 抓 `escapeHtml` / `nmFetch` / `withBusy` |",
            "| install.sh | 版本号 L3/L8；符号链接 `/bin/netmanager` |",
            "| build.yml | 版本提取、tag 判重、tar.gz 打包、Release 四段 |",
            "| publish-istore.yml | 版本校验 → 构建 ipk → 构建 apk → Release 上传 → token 探测 → 提 PR 六段 |",
            "| tools/build_apk.sh | 抓 `apk mkpkg`（字段与 depends 写法是坑点） |",
            "| tools/publish_istore.sh | 抓 `base_tree` / `pulls`（PR 幂等与干跑逻辑） |",
            "", "---", ""]
    return "\n".join(out)


def splice(doc, begin_mark, end_mark, new_block):
    """把 doc 中 [begin_mark, end_mark) 换成 new_block。

    两个标记都要求出现在行首（前面是换行），避免误命中源码片段里作为字符串字面量出现
    的同名标题（第 5 章会嵌入生成脚本自己的源码）。
    """
    i = doc.find("\n" + begin_mark)
    if i < 0:
        sys.exit("!! 找不到起始标记: %s" % begin_mark)
    i += 1
    j = doc.find("\n" + end_mark, i)
    if j < 0:
        sys.exit("!! 找不到结束标记: %s" % end_mark)
    j += 1
    return doc[:i] + new_block + "\n\n---\n\n" + doc[j:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--part", help="只把全录写到指定文件（默认 docs/source-full.md）")
    args = ap.parse_args()

    full = build_ch5_full()

    if args.part:
        with open(args.part, "w", encoding="utf-8", newline="\n") as f:
            f.write(full + "\n")
        print("OK 已生成: %s" % args.part)
        return

    # 1) 全录落到 docs/source-full.md
    with open(FULL_DOC, "w", encoding="utf-8", newline="\n") as f:
        f.write(full + "\n")

    # 2) PROJECT.md 只保留索引 + 第 9 章行号表
    doc = read_text(PROJECT)
    doc = splice(doc, CH5_BEGIN, CH5_END_MARK, build_ch5_index())
    doc = splice(doc, CH9_BEGIN, CH9_END_MARK, build_ch9())
    with open(PROJECT, "w", encoding="utf-8", newline="\n") as f:
        f.write(doc)

    print("OK 全录 -> %s（%d 个文件，%d 行）" % (
        os.path.relpath(FULL_DOC, ROOT), len(FILES), full.count("\n")))
    print("OK 索引 -> %s（总 %d 行）" % (os.path.relpath(PROJECT, ROOT), doc.count("\n")))


if __name__ == "__main__":
    main()
