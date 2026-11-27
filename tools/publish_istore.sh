#!/usr/bin/env bash
# 自动把 luci-app-netmanager 的新版本提到 iStore 的两个官方仓库（PR 到 istore-repo:pending 与 openwrt-app-meta:main）
# 依赖：curl、jq、base64；环境变量 GH_TOKEN（PAT，repo 权限）必填
# 用法: GH_TOKEN=xxx VERSION=1.8.15 ./tools/publish_istore.sh
set -euo pipefail

OWNER=${OWNER:-District1655}
VERSION=${VERSION:?需要 VERSION}
RELEASE=${RELEASE:-1}
DIST=${DIST:-dist}
DRY_RUN=${DRY_RUN:-0}
PKG=luci-app-netmanager
UP_REPO=istoreos/istore-repo
UP_META=istoreos/openwrt-app-meta
# 固定分支名：每个仓库只保留一个自动分支 / 一个 PR，版本升级时强制更新同一分支内容，
# 避免每次发版都新开 PR 把上游 PR 列表刷满
BRANCH="auto/$PKG"
META_BRANCH="auto/app-meta-$PKG"
API=https://api.github.com

[ "$DRY_RUN" = "1" ] || : "${GH_TOKEN:?需要 GH_TOKEN（PAT）}"

say() { printf '%s\n' "$*" >&2; }

api() { # method path [body]
    local m=$1 p=$2 b=${3:-}
    if [ "$DRY_RUN" = "1" ]; then
        say "DRY: $m $p"
        echo '{}'
        return 0
    fi
    if [ -n "$b" ]; then
        printf '%s' "$b" | curl -fsS -X "$m" -H "Authorization: Bearer $GH_TOKEN" \
            -H "Accept: application/vnd.github+json" "$API$p" --data-binary @-
    else
        curl -fsS -X "$m" -H "Authorization: Bearer $GH_TOKEN" \
            -H "Accept: application/vnd.github+json" "$API$p"
    fi
}

jqv() { jq -r "$1"; }

blob_sha() { # repo file
    local repo=$1 f=$2 body
    base64 -w0 "$f" > /tmp/.istore_b64 || return 1
    body=$(jq -n --rawfile c /tmp/.istore_b64 '{content:$c,encoding:"base64"}')
    api POST "/repos/$repo/git/blobs" "$body" | jqv .sha
}

upstream_base() { # repo branch -> "<commit_sha> <tree_sha>"
    local repo=$1 br=$2 c
    if [ "$DRY_RUN" = "1" ]; then printf '%s %s' "dryrun0sha" "dryrun0tree"; return 0; fi
    c=$(api GET "/repos/$repo/git/ref/heads/$br" | jqv .object.sha)
    [ "$c" = "null" ] && { say "拿不到 $repo:$br 的最新提交"; return 1; }
    printf '%s %s' "$c" "$(api GET "/repos/$repo/git/commits/$c" | jqv .tree.sha)"
}

ensure_ref() { # repo branch sha
    local repo=$1 br=$2 sha=$3
    if [ "$DRY_RUN" = "1" ]; then say "DRY: ref $br -> $sha"; return 0; fi
    api DELETE "/repos/$repo/git/refs/heads/$br" >/dev/null 2>&1 || true
    api POST "/repos/$repo/git/refs" \
        "$(jq -n --arg r "refs/heads/$br" --arg s "$sha" '{ref:$r,sha:$s}')" >/dev/null
    say "==> 推送分支 $br"
}

pr_open() { # repo head base title body
    local repo=$1 head=$2 base=$3 title=$4 body=$5 existing num
    if [ "$DRY_RUN" = "1" ]; then say "DRY: PR $repo $head -> $base"; echo "https://github.com/$repo/pulls"; return 0; fi
    existing=$(api GET "/repos/$repo/pulls?state=open&head=$OWNER:$head")
    num=$(printf '%s' "$existing" | jq -r 'if length > 0 then .[0].number else "" end')
    if [ -n "$num" ]; then
        # 固定分支：已存在同一个 PR，直接把标题与说明更新到最新版本
        say "==> $repo 复用已有 PR #$num，更新标题与说明"
        api PATCH "/repos/$repo/pulls/$num" \
            "$(jq -n --arg t "$title" --arg d "$body" '{title:$t,body:$d}')" >/dev/null
        printf '%s' "$existing" | jqv '.[0].html_url'
        return 0
    fi
    api POST "/repos/$repo/pulls" \
        "$(jq -n --arg t "$title" --arg h "$OWNER:$head" --arg b "$base" --arg d "$body" \
            '{title:$t,head:$h,base:$b,body:$d}')" | jqv .html_url
}

# ---------- 1. istore-repo：ipk + apk ----------
IPK=$(ls "$DIST"/*_all.ipk 2>/dev/null | head -1 || true)
APK=$(ls "$DIST"/*.apk 2>/dev/null | head -1 || true)
[ -n "$IPK" ] || { say "dist 里找不到 ipk，先跑 tools/build_ipk.py"; exit 1; }

read -r UP_PENDING PEND_TREE <<EOF
$(upstream_base "$UP_REPO" pending)
EOF
say "==> istore-repo pending 基线: $UP_PENDING"

ENTRIES=$(jq -n '[]')
IPK_BLOB=$(blob_sha "$OWNER/istore-repo" "$IPK")
ENTRIES=$(echo "$ENTRIES" | jq --arg p "bin/packages/all/nas_luci/$(basename "$IPK")" --arg s "$IPK_BLOB" '. + [{path:$p,mode:"100644",type:"blob",sha:$s}]')
if [ -n "$APK" ]; then
    APK_BLOB=$(blob_sha "$OWNER/istore-repo" "$APK")
    ENTRIES=$(echo "$ENTRIES" | jq --arg p "bin/apks/all/nas_luci/$(basename "$APK")" --arg s "$APK_BLOB" '. + [{path:$p,mode:"100644",type:"blob",sha:$s}]')
fi

# 固定分支复用 PR：把上一版本的 ipk/apk 从提交树里删掉，保证一个 PR 只有最新版本文件
OLD_LIST=$(api GET "/repos/$UP_REPO/git/trees/$PEND_TREE?recursive=1" | \
    jq -r --arg n "$PKG" '(.tree // [])[] | select(.type=="blob") | .path
        | select(contains("/nas_luci/") and contains($n))' 2>/dev/null || true)
if [ -n "$OLD_LIST" ]; then
    DEL=$(printf '%s\n' "$OLD_LIST" | jq -R -s \
        --arg a "bin/packages/all/nas_luci/$(basename "$IPK")" \
        --arg b "bin/apks/all/nas_luci/$(basename "${APK:-__none__}")" \
        'split("\n") | map(select(length > 0))
         | map(select(. != $a and . != $b))
         | map({path: ., mode: "100644", type: "blob", sha: null})')
    ENTRIES=$(echo "$ENTRIES" | jq --argjson d "$DEL" '. + $d')
fi

TREE=$(api POST "/repos/$OWNER/istore-repo/git/trees" \
    "$(jq -n --arg bt "$PEND_TREE" --argjson t "$ENTRIES" '{base_tree:$bt,tree:$t}')" | jqv .sha)
COMMIT=$(api POST "/repos/$OWNER/istore-repo/git/commits" \
    "$(jq -n --arg m "add $PKG $VERSION-r$RELEASE" --arg tr "$TREE" --arg p "$UP_PENDING" \
        '{message:$m,tree:$tr,parents:[$p]}')" | jqv .sha)
ensure_ref "$OWNER/istore-repo" "$BRANCH" "$COMMIT"

IPK_PR=$(pr_open "$UP_REPO" "$BRANCH" "pending" \
    "add $PKG $VERSION-r$RELEASE" \
    "$(cat <<EOM
自动提交：$PKG $VERSION-r$RELEASE

* [x] 文件已经上传（ipk + apk）
* [x] 目标分支为 pending
* [x] 元数据仓库 PR 见 openwrt-app-meta 同名分支

| 项 | 值 |
| --- | --- |
| ipk | bin/packages/all/nas_luci/$(basename "$IPK") |
| apk | bin/apks/all/nas_luci/$(basename "${APK:-无}") |
| 依赖 | libc, luci-base, luci-compat, nftables-json, curl, ca-bundle, jsonfilter |

由 https://github.com/District1655/luci-app-netmanager 的 Release 自动生成。
EOM
)")

# ---------- 2. openwrt-app-meta：卡片元数据 ----------
read -r UP_META_SHA META_TREE <<EOF
$(upstream_base "$UP_META" main)
EOF

TMP_MK=$(mktemp)
sed -e "s/^PKG_VERSION:=.*/PKG_VERSION:=$VERSION/" \
    -e "s/^PKG_RELEASE:=.*/PKG_RELEASE:=$RELEASE/" \
    istore/app-meta/Makefile > "$TMP_MK"

MK_BLOB=$(blob_sha "$OWNER/openwrt-app-meta" "$TMP_MK")
PNG_BLOB=$(blob_sha "$OWNER/openwrt-app-meta" istore/app-meta/logo.png)
META_ENTRIES=$(jq -n --arg mk "$MK_BLOB" --arg png "$PNG_BLOB" '[
  {path:"applications/app-meta-'"$PKG"'/Makefile",mode:"100644",type:"blob",sha:$mk},
  {path:"applications/app-meta-'"$PKG"'/logo.png",mode:"100644",type:"blob",sha:$png}]')
rm -f "$TMP_MK"

META_TREE_NEW=$(api POST "/repos/$OWNER/openwrt-app-meta/git/trees" \
    "$(jq -n --arg bt "$META_TREE" --argjson t "$META_ENTRIES" '{base_tree:$bt,tree:$t}')" | jqv .sha)
META_COMMIT=$(api POST "/repos/$OWNER/openwrt-app-meta/git/commits" \
    "$(jq -n --arg m "app-meta-$PKG: bump to $VERSION" --arg tr "$META_TREE_NEW" --arg p "$UP_META_SHA" \
        '{message:$m,tree:$tr,parents:[$p]}')" | jqv .sha)
ensure_ref "$OWNER/openwrt-app-meta" "$META_BRANCH" "$META_COMMIT"

META_PR=$(pr_open "$UP_META" "$META_BRANCH" "main" \
    "app-meta-$PKG: $VERSION" \
    "自动更新 $PKG 的软件中心元数据到 $VERSION（PKG_RELEASE=$RELEASE）。\n\n配套运行包 PR：$IPK_PR")

say ""
say "istore-repo PR:     $IPK_PR"
say "openwrt-app-meta:   $META_PR"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "## iStore 自动提交结果"
        echo "- istore-repo: $IPK_PR"
        echo "- openwrt-app-meta: $META_PR"
    } >> "$GITHUB_STEP_SUMMARY"
fi
