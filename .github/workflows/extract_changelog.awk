# extract_changelog.awk - 从 docs/CHANGELOG.md 提取指定版本的更新日志段
# 用法: awk -v ver="v1.4.5" -f extract_changelog.awk docs/CHANGELOG.md
# 逻辑：定位行首 "### v1.4.5 " 标题行，输出其后内容直到下一个 "### " 标题；
#       started 用于跳过段落前的空行，避免 Release body 顶部多余空行
# 防御：传入裸版本号（无 v 前缀）时自动补 v，两种传法均能匹配
# 备注：更新日志已从 README.md 迁出（2026-11-26），README 只留最近一版摘要
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