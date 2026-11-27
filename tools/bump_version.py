#!/usr/bin/env python3
"""版本号一键升级（v1.8.22）。

版本号唯一来源：files/usr/sbin/netmanager 的 PLUGIN_VERSION="x.y.z"
本脚本把它改成新版本，并同步 README 顶部的展示行，然后重生成 docs/source-full.md 与 PROJECT.md 索引。

用法：python tools/bump_version.py 1.8.22
（页面页脚、设置页版本、install.sh 横幅、CI 打包都直接读 PLUGIN_VERSION，无需再逐处改）
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NM = ROOT / "files/usr/sbin/netmanager"
README = ROOT / "README.md"


def main() -> int:
    if len(sys.argv) != 2 or not re.fullmatch(r"\d+\.\d+\.\d+", sys.argv[1]):
        print("用法: python tools/bump_version.py <x.y.z>")
        return 2
    new = sys.argv[1]

    nm = NM.read_text(encoding="utf-8")
    nm, n1 = re.subn(r'PLUGIN_VERSION="[^"]*"', f'PLUGIN_VERSION="{new}"', nm, count=1)
    if n1 != 1:
        print("✗ netmanager 里找不到 PLUGIN_VERSION")
        return 1
    NM.write_text(nm, encoding="utf-8")

    rd = README.read_text(encoding="utf-8")
    rd, n2 = re.subn(r"> 版本：v[0-9.]+", f"> 版本：v{new}", rd, count=1)
    if n2 != 1:
        print("✗ README 顶部找不到「> 版本：」行")
        return 1
    README.write_text(rd, encoding="utf-8")

    print(f"✓ PLUGIN_VERSION={new}  README 版本行已同步")
    subprocess.run([sys.executable, str(ROOT / "docs/gen_source_part.py")], cwd=ROOT, check=False)
    print("下一步：补 docs/CHANGELOG.md 的 v%s 段落后提交（CI 会按 PLUGIN_VERSION 打 tag）" % new)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
