#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 files/ 目录打成 iStore 仓库可接受的 ipk（tar.gz 外壳，内含 ./control.tar.gz 与 ./data.tar.gz）。

用法:
  python3 tools/build_ipk.py --version 1.8.14-r1 --files files --out dist
"""
import argparse
import io
import os
import tarfile

NAME = "luci-app-netmanager"
MTIME = 1795000000  # 固定时间戳，产出可复现

EXEC = {
    "usr/sbin/netmanager",
    "usr/sbin/dnssettings-apply.sh",
    "usr/sbin/dnssettings-backup.sh",
    "etc/init.d/netmanager-china",
    "etc/hotplug.d/iface/95-netmanager-china",
    "etc/hotplug.d/iface/96-netmanager-v6sync",
}

CONFFILES = "/etc/config/netmanager\n/etc/config/dnssettings\n"

POSTINST = r"""#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
/etc/init.d/netmanager-china enable >/dev/null 2>&1
/etc/init.d/netmanager-china restart >/dev/null 2>&1
/etc/init.d/uhttpd reload >/dev/null 2>&1
exit 0
"""

PRERM = r"""#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/netmanager-china stop >/dev/null 2>&1
/etc/init.d/netmanager-china disable >/dev/null 2>&1
which nft >/dev/null 2>&1 && {
	nft delete table inet netmanager 2>/dev/null
	nft delete table inet netmanager6 2>/dev/null
	nft delete table inet netmanager_ban 2>/dev/null
}
exit 0
"""


def collect(root):
    rows = []
    for dirpath, _, filenames in os.walk(root):
        for fn in filenames:
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root).replace("\\", "/")
            rows.append((rel, full))
    rows.sort()
    return rows


def add_entry(tf, name, data, mode):
    ti = tarfile.TarInfo(name)
    ti.mtime = MTIME
    ti.mode = mode
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = "root"
    ti.size = len(data)
    tf.addfile(ti, io.BytesIO(data))


def build(version, src, out_dir, release):
    files = collect(src)
    if not files:
        raise SystemExit("files 目录为空: %s" % src)

    data_buf = io.BytesIO()
    total = 0
    seen = set()
    with tarfile.open(fileobj=data_buf, mode="w:gz", compresslevel=9) as tf:
        for rel, full in files:
            parts = rel.split("/")[:-1]
            for i in range(1, len(parts) + 1):
                d = "./" + "/".join(parts[:i])
                if d not in seen:
                    seen.add(d)
                    ti = tarfile.TarInfo(d)
                    ti.mtime = MTIME
                    ti.mode = 0o755
                    ti.uid = ti.gid = 0
                    ti.uname = ti.gname = "root"
                    ti.type = tarfile.DIRTYPE
                    tf.addfile(ti)
            with open(full, "rb") as fh:
                blob = fh.read()
            total += len(blob)
            mode = 0o755 if rel in EXEC else 0o644
            ti = tarfile.TarInfo("./" + rel)
            ti.mtime = MTIME
            ti.mode = mode
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            ti.size = len(blob)
            tf.addfile(ti, io.BytesIO(blob))

    control = (
        "Package: %s\n"
        "Version: %s-r%s\n"
        "Depends: libc, luci-base, luci-compat, nftables-json, curl, ca-bundle, jsonfilter\n"
        "Section: luci\n"
        "Priority: optional\n"
        "Architecture: all\n"
        "Installed-Size: %d\n"
        "Maintainer: District1655\n"
        "Source: %s\n"
        "SourceName: %s\n"
        "License: MIT\n"
        "URL: https://github.com/District1655/luci-app-netmanager\n"
        "Description: Network manager for LuCI: port forward, firewall rules, SSH and access logs,\n"
        " China-only IPv4/IPv6 access control, manual blacklist, WAN/LAN settings and static IP binding.\n"
    ) % (NAME, version, release, total, NAME, NAME)

    ctrl_buf = io.BytesIO()
    with tarfile.open(fileobj=ctrl_buf, mode="w:gz", compresslevel=9) as tf:
        add_entry(tf, "./control", control.encode(), 0o644)
        add_entry(tf, "./conffiles", CONFFILES.encode(), 0o644)
        add_entry(tf, "./postinst", POSTINST.encode(), 0o755)
        add_entry(tf, "./prerm", PRERM.encode(), 0o755)

    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "%s_%s-r%s_all.ipk" % (NAME, version, release))
    with tarfile.open(path, "w:gz", compresslevel=9) as outer:
        for nm, blob in (
            ("./debian-binary", b"2.0\n"),
            ("./data.tar.gz", data_buf.getvalue()),
            ("./control.tar.gz", ctrl_buf.getvalue()),
        ):
            add_entry(outer, nm, blob, 0o644)
    return path, total, len(files)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True, help="如 1.8.14")
    ap.add_argument("--release", default="1", help="包修订号，默认 1")
    ap.add_argument("--files", default="files")
    ap.add_argument("--out", default="dist")
    a = ap.parse_args()
    path, total, count = build(a.version, a.files, a.out, a.release)
    print("ipk: %s (%d bytes, %d files, payload %d bytes)" % (path, os.path.getsize(path), count, total))


if __name__ == "__main__":
    main()
