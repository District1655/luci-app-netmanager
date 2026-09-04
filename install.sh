#!/bin/ash
# ============================================================
# 网络管理插件 (luci-app-netmanager) - 一键安装脚本 v1.4.5
# 由 luci-app-fwmanager (防火墙管理) 与 luci-app-dnssettings (DNS设置) 合并而成
# ============================================================

echo "============================================"
echo "  网络管理插件 (luci-app-netmanager) v1.4.5"
echo "  防火墙管理 + DNS设置 一体化"
echo "============================================"
echo ""

# 检查是否root
if [ "$(id -u)" != "0" ]; then
    echo "错误: 请使用root用户运行"
    exit 1
fi

# 检查系统
if [ ! -f "/etc/openwrt_release" ] && [ ! -f "/etc/istoreos_release" ]; then
    echo "警告: 未检测到OpenWrt/iStoreOS系统，继续安装可能有风险"
    read -p "是否继续? (y/n): " confirm
    [ "$confirm" != "y" ] && exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files"

echo "[1/7] 复制后端脚本与 DNS 管理脚本..."
cp -f "$FILES_DIR/usr/sbin/netmanager" /usr/sbin/netmanager
chmod +x /usr/sbin/netmanager
ln -sf /usr/sbin/netmanager /bin/netmanager 2>/dev/null
cp -f "$FILES_DIR/usr/sbin/dnssettings-apply.sh" /usr/sbin/dnssettings-apply.sh
cp -f "$FILES_DIR/usr/sbin/dnssettings-backup.sh" /usr/sbin/dnssettings-backup.sh
chmod +x /usr/sbin/dnssettings-apply.sh
chmod +x /usr/sbin/dnssettings-backup.sh
echo "  ✓ /usr/sbin/netmanager"
echo "  ✓ /usr/sbin/dnssettings-apply.sh"
echo "  ✓ /usr/sbin/dnssettings-backup.sh"

echo "[2/7] 复制LuCI控制器..."
mkdir -p /usr/lib/lua/luci/controller
cp -f "$FILES_DIR/usr/lib/lua/luci/controller/netmanager.lua" /usr/lib/lua/luci/controller/netmanager.lua
echo "  ✓ controller/netmanager.lua"

echo "[3/7] 复制LuCI CBI模型（DNS设置/静态IPv6分配）..."
mkdir -p /usr/lib/lua/luci/model/cbi/netmanager
cp -f "$FILES_DIR/usr/lib/lua/luci/model/cbi/netmanager/"*.lua /usr/lib/lua/luci/model/cbi/netmanager/
echo "  ✓ model/cbi/netmanager/dns_settings.lua"
echo "  ✓ model/cbi/netmanager/dns_staticv6.lua"

echo "[4/7] 复制LuCI视图模板..."
mkdir -p /usr/lib/lua/luci/view/netmanager
cp -f "$FILES_DIR/usr/lib/lua/luci/view/netmanager/"*.htm /usr/lib/lua/luci/view/netmanager/
echo "  ✓ view/netmanager/*.htm (9个文件)"

echo "[5/7] 复制配置文件..."
if [ ! -f "/etc/config/netmanager" ]; then
    cp -f "$FILES_DIR/etc/config/netmanager" /etc/config/netmanager
    echo "  ✓ /etc/config/netmanager"
else
    echo "  - /etc/config/netmanager 已存在，跳过（新选项由插件自动补齐默认值）"
fi
if [ ! -f "/etc/config/dnssettings" ]; then
    cp -f "$FILES_DIR/etc/config/dnssettings" /etc/config/dnssettings
    echo "  ✓ /etc/config/dnssettings"
else
    echo "  - /etc/config/dnssettings 已存在，跳过（保留原有DNS配置）"
fi

echo "[6/7] 复制系统脚本（中国IPv4过滤开机自启）..."
mkdir -p /etc/init.d /etc/hotplug.d/iface
cp -f "$FILES_DIR/etc/init.d/netmanager-china" /etc/init.d/netmanager-china
chmod +x /etc/init.d/netmanager-china
cp -f "$FILES_DIR/etc/hotplug.d/iface/95-netmanager-china" /etc/hotplug.d/iface/95-netmanager-china
chmod +x /etc/hotplug.d/iface/95-netmanager-china 2>/dev/null
/etc/init.d/netmanager-china enable 2>/dev/null
echo "  ✓ /etc/init.d/netmanager-china (开机自启)"
echo "  ✓ /etc/hotplug.d/iface/95-netmanager-china (WAN上线重应用)"

echo "[7/7] 重启LuCI..."
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null

# 网页插件更新时：由调用方决定何时重启，避免 HTTP 连接被切断导致 UI 显示失败
# 环境变量 SKIP_UHTTPD_RESTART=1 表示跳过本次立即重启，由外部延迟重启
if [ "$SKIP_UHTTPD_RESTART" = "1" ] || [ "$SKIP_UHTTPD_RESTART" = "true" ]; then
    echo "  - 跳过立即重启LuCI（网页更新模式，稍后由系统延迟重启）"
else
    /etc/init.d/uhttpd restart 2>/dev/null
    echo "  ✓ LuCI已重启"
fi

echo ""
echo "============================================"
echo "  安装完成！"
echo "============================================"
echo ""
echo "访问方式:"
echo "  Web界面: 路由器管理页 -> 网络管理"
echo "  命令行:  netmanager overview"
echo "           netmanager port_list"
echo "           netmanager ssh_log"
echo "           netmanager access_log"
echo ""
echo "默认 DNS:"
echo "  IPv4: 223.5.5.5 / 119.29.29.29"
echo "  IPv6: 2400:3200::1 / 2402:4e00::"
echo ""
echo "============================================"
