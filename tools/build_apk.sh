#!/usr/bin/env bash
# 用官方 openwrt-sdk-mini 的 apk mkpkg 打 25.12(apk) 包
# 用法: VERSION=1.8.14 RELEASE=1 ./tools/build_apk.sh
set -euo pipefail

VERSION=${VERSION:?需要 VERSION，例如 1.8.14}
RELEASE=${RELEASE:-1}
FILES=${FILES:-files}
OUT=${OUT:-dist}
PKG=luci-app-netmanager
SDK_URL="https://github.com/linkease/istore-repo/releases/download/tools/openwrt-sdk-mini-25.12.2.tar.xz"
SDK_TGZ=${SDK_TGZ:-/tmp/openwrt-sdk-mini.tar.xz}
SDK_DIR=${SDK_DIR:-/tmp/openwrt-sdk-mini}

mkdir -p "$OUT"

if [ ! -x "$SDK_DIR/staging_dir/host/bin/apk" ]; then
    echo "==> 下载 SDK mini"
    curl -fL --retry 3 -o "$SDK_TGZ" "$SDK_URL"
    rm -rf "$SDK_DIR"
    mkdir -p "$SDK_DIR"
    tar -xJf "$SDK_TGZ" -C "$SDK_DIR" --strip-components=1
fi
APK="$SDK_DIR/staging_dir/host/bin/apk"
"$APK" --version | head -1

# 规范权限：目录 755、普通文件 644、脚本 755
find "$FILES" -type d -exec chmod 755 {} +
find "$FILES" -type f -exec chmod 644 {} +
for f in usr/sbin/netmanager usr/sbin/dnssettings-apply.sh usr/sbin/dnssettings-backup.sh \
         etc/init.d/netmanager-china etc/hotplug.d/iface/95-netmanager-china \
         etc/hotplug.d/iface/96-netmanager-v6sync; do
    [ -f "$FILES/$f" ] && chmod 755 "$FILES/$f"
done

cat > /tmp/nm-post-install.sh <<'EOS'
#!/bin/sh
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
/etc/init.d/netmanager-china enable >/dev/null 2>&1
/etc/init.d/netmanager-china restart >/dev/null 2>&1
/etc/init.d/uhttpd reload >/dev/null 2>&1
exit 0
EOS

cat > /tmp/nm-pre-deinstall.sh <<'EOS'
#!/bin/sh
/etc/init.d/netmanager-china stop >/dev/null 2>&1
/etc/init.d/netmanager-china disable >/dev/null 2>&1
command -v nft >/dev/null 2>&1 && {
  nft delete table inet netmanager 2>/dev/null
  nft delete table inet netmanager6 2>/dev/null
  nft delete table inet netmanager_ban 2>/dev/null
}
exit 0
EOS
chmod +x /tmp/nm-post-install.sh /tmp/nm-pre-deinstall.sh

OUTFILE="$OUT/$PKG-$VERSION-r$RELEASE.apk"
rm -f "$OUTFILE"
"$APK" mkpkg -F "$FILES" \
    -I name:$PKG \
    -I version:$VERSION-r$RELEASE \
    -I description:"Network manager for LuCI" \
    -I arch:noarch \
    -I license:MIT \
    -I origin:$PKG \
    -I maintainer:District1655 \
    -I url:https://github.com/District1655/luci-app-netmanager \
    -I "depends:libc luci-base luci-compat nftables-json curl ca-bundle jsonfilter" \
    -I provides:$PKG-any \
    -s post-install:/tmp/nm-post-install.sh \
    -s pre-deinstall:/tmp/nm-pre-deinstall.sh \
    -o "$OUTFILE"

echo "==> 自检"
"$APK" adbdump "$OUTFILE" | sed -n '1,16p'
ls -lh "$OUTFILE"
