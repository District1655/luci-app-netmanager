#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ensure_changelog.py - 保证 docs/CHANGELOG.md 里有当前版本的段落

背景：
    Release body 由 build.yml 从 docs/CHANGELOG.md 提取（### vX.Y.Z 段落）。
    以前靠人记「发版前手动加一节」，忘写就出空 body。现在 CI 先跑本脚本：
    缺了就从 git 提交记录自动生成一节并写回文件，再照常发版。

用法（仓库根目录）：
    python3 tools/ensure_changelog.py --version 1.8.15
    python3 tools/ensure_changelog.py --version 1.8.15 --print      # 只打印，不改文件
    python3 tools/ensure_changelog.py --version 1.8.15 --date 2026-11-27

输出（供 CI 解析）：
    status=exists|generated
    range=<上一 tag>..<HEAD>      # 生成时才有意义
    file=docs/CHANGELOG.md

设计约束：
- 已存在同名段落时**绝不改动**（人工润色的内容优先，CI 不覆盖人写的东西）。
- git 不可用 / 是浅克隆 / 一个提交都取不到时，仍写一条占位 bullets，保证 body 不为空，且退出码 0。
- 只插到「最后一个文件头 > 引用块」之后、「第一个 ### 版本段」之前，保持倒序（新版本在上）。
"""
import argparse
import datetime
import os
import re
import subprocess
import sys

DEFAULT_FILE = "docs/CHANGELOG.md"
MAX_BULLETS = 20
SKIP_PATTERNS = re.compile(r"^(merge |revert )|\[skip ci\]", re.I)
# 纯工程类提交（不影响用户可见行为）默认不进 Release body
NOISE_PATTERN = re.compile(r"^(docs|ci|chore|build|test|style)(\(|:|$)", re.I)
VERSION_PREFIX = re.compile(r"^v?\d+\.\d+\.\d+[:\s]+")


def git(*args):
    try:
        return subprocess.check_output(["git"] + list(args), stderr=subprocess.DEVNULL).decode(
            "utf-8", "replace").strip()
    except Exception:
        return ""


def last_tag():
    tag = git("describe", "--tags", "--abbrev=0")
    if tag:
        return tag
    # describe 失败时退一步：列出所有 tag 取最新
    tags = [t for t in git("tag", "--list", "v*").split("\n") if t.strip()]
    return tags[-1] if tags else ""


def commits_since(tag, limit=MAX_BULLETS):
    rng = "%s..HEAD" % tag if tag else "HEAD"
    raw = git("log", "--no-merges", "--pretty=%s", "-n", str(limit * 2), rng)
    all_subj, useful = [], []
    for line in raw.split("\n"):
        s = line.strip()
        if not s or SKIP_PATTERNS.search(s):
            continue
        s = VERSION_PREFIX.sub("", s)
        if s in all_subj:
            continue
        all_subj.append(s)
        if NOISE_PATTERN.search(s):
            continue
        useful.append(s)
    # 全是 docs/ci 这类工程提交时，别把发布说明留空，退回用全部提交
    picked = useful or all_subj
    return rng, picked[:limit]


def build_section(version, date, rng, subjects):
    lines = ["### v%s (%s)" % (version, date), ""]
    lines.append("> 本节由 CI 依据提交记录自动生成（未人工润色），需要更完整的说明请直接在这段里补写。")
    lines.append("")
    if subjects:
        for s in subjects:
            lines.append("- %s" % s)
    else:
        lines.append("- 版本号提升至 v%s（提交记录不可用，请人工补充说明）" % version)
    lines.append("")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True, help="版本号，不带 v，如 1.8.15")
    ap.add_argument("--file", default=DEFAULT_FILE)
    ap.add_argument("--date", default=None, help="日期，默认今天（YYYY-MM-DD）")
    ap.add_argument("--max", type=int, default=MAX_BULLETS, help="最多列多少条提交")
    ap.add_argument("--print", dest="dry", action="store_true", help="只打印，不改文件")
    args = ap.parse_args()

    path = os.path.join(os.getcwd(), args.file)
    if not os.path.isfile(path):
        print("!! 找不到 %s" % args.file)
        return 2

    with open(path, "r", encoding="utf-8", newline="") as f:
        doc = f.read().replace("\r\n", "\n")

    ver = args.version.lstrip("v")
    heading_re = re.compile(r"^### v%s\b" % re.escape(ver), re.M)
    if heading_re.search(doc):
        print("status=exists")
        print("file=%s" % args.file)
        print("v%s 段落已存在，不做改动" % ver)
        return 0

    date = args.date or datetime.date.today().isoformat()
    rng, subjects = commits_since(last_tag(), args.max)
    section = build_section(ver, date, rng, subjects)

    if args.dry:
        print("status=generated")
        print("range=%s" % rng)
        print("file=%s" % args.file)
        print("----")
        print(section)
        return 0

    # 插到第一个 "### " 版本段之前（保持新版本在上）
    m = re.search(r"^### ", doc, re.M)
    if m:
        new_doc = doc[:m.start()] + section + "\n" + doc[m.start():]
    else:
        new_doc = doc.rstrip("\n") + "\n\n" + section

    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(new_doc)

    print("status=generated")
    print("range=%s" % rng)
    print("file=%s" % args.file)
    print("已写入 %d 条提交摘要" % len(subjects))
    return 0


if __name__ == "__main__":
    sys.exit(main())
