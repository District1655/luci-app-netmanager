#!/bin/bash
# ============================================================
# gen_source_part.sh - 生成 PROJECT.md 第 5 章「源码全录」
# 用法: 在仓库根目录执行  bash docs/gen_source_part.sh
# 输出: docs/source_part.md
# 合并: 用 docs/source_part.md 替换 PROJECT.md 中第 5 章内容
#       （从「## 第 5 章 源码全录」到「> 第 5 章结束」标记）
# 说明: 按固定顺序嵌入全部 24 个受控文件；内容含 ``` 围栏的
#       文件（README.md）自动升级为 4 反引号围栏包裹。
#       新增受控文件时，在 paths/langs/descs/notes 四个数组
#       同步添加条目，并更新 PROJECT.md 第 2 章目录树。
# ============================================================

# 仓库根 = 脚本所在目录的上一级
script_dir="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$script_dir")"
out="$script_dir/source_part.md"

paths=(
"files/usr/sbin/netmanager"
"files/usr/sbin/dnssettings-apply.sh"
"files/usr/sbin/dnssettings-backup.sh"
"files/usr/lib/lua/luci/controller/netmanager.lua"
"files/usr/lib/lua/luci/model/cbi/netmanager/dns_settings.lua"
"files/usr/lib/lua/luci/model/cbi/netmanager/dns_staticv6.lua"
"files/usr/lib/lua/luci/view/netmanager/common_head.htm"
"files/usr/lib/lua/luci/view/netmanager/nav.htm"
"files/usr/lib/lua/luci/view/netmanager/cbi_nav.htm"
"files/usr/lib/lua/luci/view/netmanager/overview.htm"
"files/usr/lib/lua/luci/view/netmanager/port_forward.htm"
"files/usr/lib/lua/luci/view/netmanager/firewall_rules.htm"
"files/usr/lib/lua/luci/view/netmanager/ssh_log.htm"
"files/usr/lib/lua/luci/view/netmanager/access_log.htm"
"files/usr/lib/lua/luci/view/netmanager/settings.htm"
"files/etc/config/netmanager"
"files/etc/config/dnssettings"
"files/etc/init.d/netmanager-china"
"files/etc/hotplug.d/iface/95-netmanager-china"
"install.sh"
".github/workflows/build.yml"
".github/workflows/extract_changelog.awk"
".gitattributes"
"README.md"
)

langs=(
"bash" "bash" "bash"
"lua" "lua" "lua"
"html" "html" "html" "html" "html" "html" "html" "html" "html"
"uci" "uci"
"bash" "bash" "bash"
"yaml" "awk"
"text"
"markdown"
)

descs=(
"后端核心脚本：netmanager 命令全部子命令实现（概览/端口转发/规则/日志/备份/上传/在线更新/中国IPv4过滤/卸载）"
"DNS 应用脚本：把 /etc/config/dnssettings 写入 network/dhcp/dnsmasq 并重载服务（v1.4.5 重写）"
"DNS 备份脚本：独立备份 network/dhcp/dnssettings 到 /root/backup/"
"LuCI 控制器：注册全部页面路由 + API 分发（action 到后端命令桥接）+ multipart 上传处理"
"DNS 设置 CBI 模型：Map 绑定 /etc/config/dnssettings（wan/lan/dnsmasq 三节 + 应用/备份按钮）"
"静态 IPv6 分配 CBI 模型：绑定 dhcp.host + 在线客户端速览（4 数据源交叉）+ 冲突检测"
"全部视图公共头：CSS 样式 + 公共 JS（escapeHtml / apiFetch / withBusy）"
"页内导航条：防火墙 6 页 + DNS 设置 / 静态 IPv6 两个 CBI 入口"
"CBI 页面专用导航条（v1.4.6 新增）：自带内联样式，由 dns_settings / dns_staticv6 以 Template 节点注入，修复 CBI 页页签消失"
"系统概览页：防火墙状态 / 端口统计 / 网络信息 / 快捷操作"
"端口转发管理页：列表 / 添加 / 编辑 / 删除，外部端口到内部端口映射"
"防火墙规则管理页：自定义规则增删改 + 常用模板一键应用"
"SSH 登录日志页：成功/失败记录 + 失败 IP Top10 + 自动刷新"
"端口访问日志页：活跃连接 / 入站出站计数 / 拦截统计"
"设置页：默认目标 / 备份恢复 / 插件更新 / 在线更新 / 中国IPv4过滤 / 运行日志 / 卸载"
"防火墙模块 UCI 配置：默认目标 IP / 日志开关 / 中国过滤全部参数"
"DNS 模块 UCI 配置：wan / lan / dnsmasq / actions 四节"
"开机自启脚本：重应用中国 IPv4 过滤规则"
"WAN 上线热插拔脚本：接口上线自动重应用规则（自愈机制）"
"一键安装脚本：7 步安装，复制文件 / 权限 / /bin/netmanager 符号链接 / init / cron，支持 SKIP_UHTTPD_RESTART"
"GitHub Actions 工作流：tag 推送时打包 tar.gz 资产并创建 Release"
"Release body 提取脚本：从 README.md 更新日志提取指定版本段落"
"git 属性：强制 LF 行尾（.gitattributes，CRLF 警告可忽略）"
"项目主文档：功能 / 安装 / CLI / 配置说明 / 更新日志 / 许可证"
)

notes=(
"单文件约 2197 行，v1.5+ 模块化拆分对象。PLUGIN_VERSION 位于 L15（版本唯一权威源）；tar_list_check L68-86；proto_match 在头部；update_apply 约 L1495、set_update_mirror 约 L1502-1505（P0 镜像白名单待修）；china_load_set 约 L1736-1761；china_cron_install 约 L1920-1926；set_cron 约 L1973-1986；uninstall 约 L2059-2143（L2141 rm /tmp/luci-sessions 待修）"
"v1.4.5 重写：空值断网防护 / 应用前自动备份 / list 字段正确写法 / network reload 化。已知待修：L145 dhcp_option 单值写法应 delete+add_list；L68/L97 WAN 接口名硬编码 network.wan/wan6；L120-132 PPPoE 双栈 fallback 未去重即 add_list"
"逻辑简单，注意保持与 apply 脚本一致的保留 5 份自动备份策略"
"api_handler 强制 POST（约 L115）；shell_escape 约 L56-64（所有拼命令参数必经）；L20-21 dns_apply/dns_backup 仍为 GET 路由（v1.4.6 待修 POST 化）；L85/L294 上传临时文件 .b64_<秒级时间戳> 同秒冲突待修；arg() 在 4 处重复定义待提取"
"forward_v4/forward_v6 为 DynamicList（L93-101）；L108-120 apply/backup 按钮通过 redirect 触发 GET 路由（v1.4.6 待修 POST 化）；v1.4.6 已注入 cbi_nav 导航模板（L14-16）"
"L32-166 get_online_devices 四数据源（dnsmasq 租约/ARP/odhcpd 租约/NDP）；v1.4.6 修复：L45-54 first_opt 用 foreach 替代 get_first（ucode 桥无此方法）；L171-216 merge_duplicate_hosts；L221 页面 GET 加载即执行 merge+commit（v1.4.6 待修）；L290 已注入 cbi_nav；L293/L308 on_before_commit/on_after_commit；L469-481 DUID 校验 4-130 hex"
"L74-155 公共 JS 区。apiFetch 带超时与会话过期处理，但目前仅 ssh_log 使用（v1.4.6 统一）；withBusy 为死代码待启用或删除；L75 附近版本注释是版本号登记处之一"
"与 controller 菜单双维护：新增页面需两处同步修改"
"CBI 页面专用导航（v1.4.6 新增修复 bug2）：自带内联样式（CBI 页不加载 common_head）；active 判断 requestpath[3] 带 nil 防护"
"裸 fetch（v1.4.6 统一 apiFetch）；L142 附近 grep -v '172\\.' / grep -v '192.168' 过滤会误伤公网 IP（待修）"
"L104/L110 delPort onclick 传自由文本（escapeHtml 在 onclick 属性上下文无效，v1.4.6 P1 待修，方案改数组下标传参）；L135-142 delPort；L143-157 editPort 已用数组下标（v1.4.4 修复）；L162-178 savePortEdit"
"L137 editRule 已改数组下标传参（v1.4.4 修复）"
"L54 已用 apiFetch；SSH 用户名/IP 等字段写入前已转义（v1.4.4 修复存储型 XSS）"
"裸 fetch（v1.4.6 统一 apiFetch）"
"最复杂视图。L101/L202 footer 版本号（登记处）；L236-260 API_URL+loadSettings；L396-435 listBackups（L421-429 b[0] 直拼 innerHTML 未转义，v1.4.6 P1 待修）；L443-467 restoreBackup/deleteBackup；L512-555 loadChinaStatus（L535-536 lu/cnt/devs 三处未转义待修）；L564-586 saveChinaUrl/saveChinaCron；L595-622 enable/disable/updateChinaFilter；L624-655 uninstallPlugin"
"默认订阅 metowolf china.txt；china_filter_cron 默认每周日 3 点"
"wan/lan/dnsmasq 三节为 dns_settings.lua 表单绑定；actions 节为按钮占位"
"START/STOP 顺序：参考 OpenWrt 规范，启动晚于防火墙以确保 fw4 就绪"
"编号 95 确保在 fw4 默认 hotplug 之后执行"
"L3/L8 版本号（登记处）；L32 ln -sf /bin/netmanager 符号链接——uninstall 未清理该链接（v1.4.6 待修）"
"tag 推送触发；产物命名 luci-app-netmanager-install_<ver>.tar.gz；Release body 由 extract_changelog.awk 自动填充"
"注释中的版本号是有意保留的历史记录，发版时勿动"
"13 行，强制 * text=auto eol=lf"
"L3 版本号（登记处，CI 从此提取最新 tag）；L227-302 更新日志段（Release body 来源，发版必须新增对应小节）"
)

{
echo ""
echo "---"
echo ""
echo "## 第 5 章 源码全录"
echo ""
echo "> 本章由脚本自动嵌入（基线 commit 90b2bf9 / v1.4.5+两bug修复，生成时间 $(date '+%Y-%m-%d %H:%M')）。"
echo "> 收录全部 24 个受控文件的完整内容，每个文件附用途与维护要点。"
echo "> **源码是唯一事实来源**：前文描述与源码不一致时，以源码为准。"
echo ""

n=0
for i in "${!paths[@]}"; do
  n=$((n+1))
  p="${paths[$i]}"
  lang="${langs[$i]}"
  full="$root/$p"
  if [ ! -f "$full" ]; then
    echo "!! 文件缺失: $full" >&2
    exit 1
  fi
  lines=$(wc -l < "$full" | tr -d ' ')
  fence='```'
  if grep -q '```' "$full" 2>/dev/null; then
    fence='````'
  fi
  echo ""
  echo "### 5.$n $p"
  echo ""
  echo "- **用途**：${descs[$i]}"
  echo "- **规模**：$lines 行"
  echo "- **维护要点**：${notes[$i]}"
  echo ""
  echo "$fence$lang"
  cat "$full"
  if [ -n "$(tail -c 1 "$full")" ]; then
    echo ""
  fi
  echo "$fence"
done

echo ""
echo "> 第 5 章结束。以下为第 6 章起的手写章节。"
} > "$out"

echo "OK 已生成: $out"
echo "总行数: $(wc -l < "$out")"