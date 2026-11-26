#!/usr/bin/env bash
# 只保留"版本号最高"的最近 KEEP 个版本（默认 10 个）的 tag 与 Release，更早的一律删除。
#
# 排序口径：按版本号排序（1.4.10 排在 1.4.9 之后，而不是按发布时间），
#           这样页面上的版本序列不会出现"留着更老的、删了更新的"。
# 删除口径：某个版本不在保留名单里 → 有 Release 就先删 Release（--cleanup-tag 顺带删 tag），
#           没有 Release 的孤儿 tag 直接删远端 tag。
#
# 用法：
#   KEEP=10 bash tools/prune_history.sh          # 真删
#   KEEP=10 DRY_RUN=1 bash tools/prune_history.sh # 只打印计划，不动远端
#
# CI 里由 .github/workflows/prune-history.yml 手动触发，或 build.yml 发版后自动调用。

set -euo pipefail

KEEP="${KEEP:-10}"
DRY_RUN="${DRY_RUN:-0}"
REPO="${REPO:-${GITHUB_REPOSITORY:-District1655/luci-app-netmanager}}"

case "$KEEP" in
  ''|*[!0-9]*) echo "::error::KEEP 必须是正整数，当前值: '$KEEP'"; exit 1 ;;
esac
[ "$KEEP" -ge 1 ] || { echo "::error::KEEP 至少要保留 1 个版本"; exit 1; }

echo "仓库: $REPO   保留版本数: $KEEP   模式: $([ "$DRY_RUN" = "1" ] && echo 预演 || echo 真删)"

# 1) 按版本号倒序取全部 tag（sort -V 让 1.4.10 > 1.4.9）
ALL_TAGS=$(git tag -l 'v*' | sort -V -r)
TOTAL=$(printf '%s\n' "$ALL_TAGS" | grep -c . || true)
echo "当前 tag 总数: $TOTAL"

KEEP_TAGS=$(printf '%s\n' "$ALL_TAGS" | head -n "$KEEP")
DROP_TAGS=$(printf '%s\n' "$ALL_TAGS" | tail -n +$((KEEP + 1)))

echo "===== 保留的版本 ====="
printf '%s\n' "$KEEP_TAGS"

if [ -z "$(printf '%s\n' "$DROP_TAGS" | grep -c . || true)" ] || [ "$TOTAL" -le "$KEEP" ]; then
  echo "版本数量未超过 $KEEP 个，无需删除。"
  exit 0
fi

echo "===== 待删除的版本 ====="
printf '%s\n' "$DROP_TAGS"

DEL_RELEASE=0
DEL_TAG=0
while IFS= read -r t; do
  [ -n "$t" ] || continue
  if gh release view "$t" --repo "$REPO" >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "1" ]; then
      echo "[dry-run] 将删除 Release + tag: $t"
    else
      gh release delete "$t" --repo "$REPO" --yes --cleanup-tag && echo "已删除 Release + tag: $t"
    fi
    DEL_RELEASE=$((DEL_RELEASE + 1))
  else
    if [ "$DRY_RUN" = "1" ]; then
      echo "[dry-run] 将删除孤儿 tag: $t"
    else
      git push origin ":refs/tags/$t" >/dev/null 2>&1 && echo "已删除孤儿 tag: $t" || echo "::warning::删除 tag 失败: $t"
    fi
    DEL_TAG=$((DEL_TAG + 1))
  fi
done <<< "$DROP_TAGS"

if [ "$DRY_RUN" = "1" ]; then
  echo "计划：删除 $DEL_RELEASE 个 Release、$DEL_TAG 个孤儿 tag"
else
  echo "===== 清理后状态 ====="
  gh release list --repo "$REPO" --limit 50 --json tagName,createdAt --jq '.[] | "\(.tagName)  \(.createdAt)"'
  echo "远端 tag 数: $(git ls-remote --tags --refs origin 2>/dev/null | wc -l)"
  echo "已删除 Release $DEL_RELEASE 个、孤儿 tag $DEL_TAG 个"
fi
