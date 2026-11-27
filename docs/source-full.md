# 源码全录（docs/source-full.md）

> 本文件由 `docs/gen_source_part.py` 自动生成，请勿手改；改动源码后重跑脚本。
> 收录除 `PROJECT.md` / `LICENSE` 外的全部受控文件（33 个）。**源码是唯一事实来源**：
> `PROJECT.md` 里的描述与这里不一致时，以本文件（即实际源码）为准。
> 章节号 §5.x 与 `PROJECT.md` 第 5 章索引表一一对应。

### 5.1 files/usr/sbin/netmanager

- **用途**：后端核心脚本：全部 CLI 子命令（概览/端口转发/规则/日志/备份/上传/在线更新/中国 IPv4·IPv6 过滤/黑名单/卸载）
- **规模**：4575 行
- **维护要点**：单文件约 4200 行，v1.5+ 模块化拆分对象。PLUGIN_VERSION 在 L15（唯一权威源）；命令入口行号见 9.1

```bash
#!/bin/ash
# ============================================================
# 网络管理插件 - 后端核心脚本 v1.1
# 
# 适配: iStoreOS / OpenWrt (fw4/nftables, BusyBox)
# ============================================================

DEFAULT_TARGET="192.168.31.196"
CONFIG_FILE="/etc/config/netmanager"
LOG_DIR="/tmp/netmanager"
LOG_FILE="$LOG_DIR/run.log"
LOG_ENABLED=0

# 在线更新配置：版本号与 GitHub 仓库（发版时同步修改 PLUGIN_VERSION）
PLUGIN_VERSION="1.8.17"
REPO_OWNER="District1655"
REPO_NAME="luci-app-netmanager"
REPO_BASE_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
REPO_API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"

# 【v1.4.6 P0 安全】更新镜像域名白名单：镜像被劫持可注入恶意 install.sh 以 root 执行，
# 仅允许知名 GitHub 加速代理；新增镜像需维护此列表。拒绝裸 IP。
MIRROR_HOST_ALLOWLIST="gh-proxy.com ghproxy.net gh-proxy.net mirror.ghproxy.com github.moeyy.xyz"

# 确保日志目录存在（tmp每次重启会清，需要每次重建）
mkdir -p "$LOG_DIR" 2>/dev/null

# 检查并加载日志开关（调用 load_config 后 LOG_ENABLED 才有效）
reload_log_setting() {
    local val=$(uci get netmanager.settings.log_enable 2>/dev/null)
    [ "$val" = "1" ] && LOG_ENABLED=1 || LOG_ENABLED=0
}

# 写运行日志：[时间戳] [级别] 内容
write_log() {
    [ "$LOG_ENABLED" = "1" ] || return 0
    local level="$1"; shift
    local msg="$*"
    local ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%s')
    mkdir -p "$LOG_DIR" 2>/dev/null
    # 日志文件超过 2MB 自动截断保留最后 500 行
    if [ -f "$LOG_FILE" ]; then
        local sz=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$sz" -gt 2097152 ] 2>/dev/null; then
            tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null
            mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null
        fi
    fi
    echo "[$ts] [$level] $msg" >> "$LOG_FILE" 2>/dev/null
    return 0
}

# 公开的日志快捷函数（同时写标准输出 + 日志文件）
info() { echo "[INFO] $*"; write_log "INFO" "$*"; }
warn() { echo "[WARN] $*"; write_log "WARN" "$*"; }
error() { echo "[ERROR] $*"; write_log "ERROR" "$*"; }

# proto_match <条目proto> <待匹配proto>：返回0=匹配
# fw4 语义：proto 缺省（空）= tcp+udp（both）
proto_match() {
    local rp="$1" mp="$2"
    [ -z "$rp" ] && rp="tcp udp"
    case " $rp " in
        *" $mp "*) return 0 ;;
    esac
    return 1
}

# tar_list_check <tar包> <列表输出文件>：返回0=安全（成员可列出且无路径穿越/symlink）
# BusyBox tar 解压时不剥离 ../ 成员，恶意包可借此覆盖系统文件（配合在线更新=远程RCE链）
# 检查规则：列出失败（坏包）、成员含 ../ 段、以绝对路径开头、或成员为 symlink → 全部拒绝
# 【v1.4.6】新增 symlink 防护：tar 列表首字符 'l' 即符号链接成员，解压后可指向 /etc/shadow 等任意系统文件
tar_list_check() {
    local pkg="$1" listfile="$2"
    # 尝试列出成员（gzip 直接列失败时退回 gunzip + tar tf；-tv 显示类型，首字符 l=链接）
    tar tzvf "$pkg" > "$listfile" 2>/dev/null
    if [ $? -ne 0 ] && [ ! -s "$listfile" ]; then
        local ungz="${pkg%.gz}"
        if [ "$ungz" != "$pkg" ]; then
            gunzip -c "$pkg" > "$ungz" 2>/dev/null && tar tvf "$ungz" > "$listfile" 2>/dev/null
            rm -f "$ungz" 2>/dev/null
        fi
    fi
    # 完全列不出来 = 坏包，拒绝
    [ ! -s "$listfile" ] && return 1
    # 检查非法成员：../ 段、绝对路径开头、symlink 成员（-tv 首字符 l）
    if grep -qE '(^|/)\.\.(/|$)|^/|^l' "$listfile"; then
        return 1
    fi
    return 0
}

load_config() {
    [ -f "$CONFIG_FILE" ] || {
        uci set netmanager.settings=netmanager
        uci set netmanager.settings.default_target="$DEFAULT_TARGET"
        uci set netmanager.settings.log_days='7'
        uci set netmanager.settings.log_enable='0'
        uci commit netmanager
    }
    DEFAULT_TARGET=$(uci get netmanager.settings.default_target 2>/dev/null || echo "$DEFAULT_TARGET")
    reload_log_setting
    # 补齐中国IPv4过滤相关默认值（仅在选项缺失时写入，不覆盖用户已自定义值）
    if [ -z "$(uci get netmanager.settings.china_filter_enable 2>/dev/null)" ]; then
        uci set netmanager.settings.china_filter_enable='0'
        uci set netmanager.settings.china_filter_url='https://metowolf.github.io/iplist/data/special/china.txt'
        uci set netmanager.settings.china_filter_cron='0 3 * * 0'
        uci set netmanager.settings.china_filter_last_update=''
        uci set netmanager.settings.china_filter_count='0'
        uci commit netmanager 2>/dev/null
    fi
    # v1.8.17：放行 WAN 口同网段来源（上级光猫/网关等私网邻居）
    # 默认开启；选项缺失时补写，不覆盖用户已有设置
    if [ -z "$(uci get netmanager.settings.china_filter_allow_wan_peers 2>/dev/null)" ]; then
        uci set netmanager.settings.china_filter_allow_wan_peers='1'
        uci commit netmanager 2>/dev/null
    fi
    # 补齐中国IPv6过滤相关默认值（仅在选项缺失时写入，不覆盖用户已自定义值）
    if [ -z "$(uci get netmanager.settings.china6_filter_enable 2>/dev/null)" ]; then
        uci set netmanager.settings.china6_filter_enable='0'
        uci set netmanager.settings.china6_filter_url='https://ispip.clang.cn/all_cn_ipv6.txt'
        uci set netmanager.settings.china6_filter_cron='0 3 * * 0'
        uci set netmanager.settings.china6_filter_last_update=''
        uci set netmanager.settings.china6_filter_count='0'
        uci commit netmanager 2>/dev/null
    fi
    # 补齐在线更新镜像前缀默认值（空=直连 GitHub）
    if [ -z "$(uci get netmanager.settings.update_mirror 2>/dev/null)" ]; then
        uci set netmanager.settings.update_mirror=''
        uci commit netmanager 2>/dev/null
    fi
}

# ========== 1. 系统概览 ==========
cmd_overview() {
    load_config
    echo "===NETMANAGER_OVERVIEW==="

    # 防火墙状态：检测 fw4 表是否存在
    # 用 nft list table 替代全量 nft list ruleset（原代码调用两次全量查询，规则多时很慢）
    if nft list table inet fw4 >/dev/null 2>&1; then
        echo "FW_STATUS=running"
    else
        echo "FW_STATUS=stopped"
    fi

    # 规则数量
    redirect_count=0; rule_count=0
    idx=0
    while uci -q get "firewall.@redirect[$idx]" >/dev/null 2>&1; do
        redirect_count=$((redirect_count+1)); idx=$((idx+1))
    done
    idx=0
    while uci -q get "firewall.@rule[$idx]" >/dev/null 2>&1; do
        rule_count=$((rule_count+1)); idx=$((idx+1))
    done
    echo "REDIRECT_COUNT=$redirect_count"
    echo "RULE_COUNT=$rule_count"

    # WAN口IP（通过路由获取，不写死接口名）
    wan_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    # 【v1.4.6 P3】私网过滤按 RFC1918 精确网段（旧 grep -v '172\.' 会误伤 172.x 公网 IP 段）
    [ -z "$wan_ip" ] && wan_ip=$(ip -4 addr show 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | grep -vE 'inet (10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' | awk '{print $2}' | cut -d/ -f1 | head -1)
    [ -z "$wan_ip" ] && wan_ip="N/A"
    echo "WAN_IP=$wan_ip"

    # WAN IPv6
    wan_ipv6=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [ -z "$wan_ipv6" ] && wan_ipv6=$(ip -6 addr show 2>/dev/null | grep 'scope global' | grep -v 'fd' | awk '{print $2}' | cut -d/ -f1 | head -1)
    [ -z "$wan_ipv6" ] && wan_ipv6="N/A"
    echo "WAN_IPV6=$wan_ipv6"

    # LAN口IP
    lan_ip=$(uci get network.lan.ipaddr 2>/dev/null || echo "192.1.8.3.1")
    echo "LAN_IP=$lan_ip"

    # 运行时间（从/proc/uptime计算）
    uptime_sec=$(cat /proc/uptime 2>/dev/null | awk '{print int($1)}')
    up_days=$((uptime_sec / 86400))
    up_hours=$(( (uptime_sec % 86400) / 3600 ))
    up_mins=$(( (uptime_sec % 3600) / 60 ))
    if [ $up_days -gt 0 ]; then
        uptime_str="${up_days}天${up_hours}小时${up_mins}分"
    elif [ $up_hours -gt 0 ]; then
        uptime_str="${up_hours}小时${up_mins}分"
    else
        uptime_str="${up_mins}分钟"
    fi
    echo "UPTIME=$uptime_str"

    # 负载
    load=$(cat /proc/loadavg 2>/dev/null | awk '{print $1" "$2" "$3}')
    echo "LOAD=$load"

    # 内存
    mem_info=$(free 2>/dev/null | grep Mem)
    mem_total=$(echo "$mem_info" | awk '{print $2}')
    mem_used=$(echo "$mem_info" | awk '{print $3}')
    if [ -n "$mem_total" ] && [ "$mem_total" -gt 0 ]; then
        mem_percent=$((mem_used * 100 / mem_total))
    else
        mem_percent=0
    fi
    echo "MEM_PERCENT=$mem_percent"

    echo "DEFAULT_TARGET=$DEFAULT_TARGET"

    # SSH失败次数（适配dropbear + BusyBox，不用grep -P）
    # dropbear失败: "Bad password attempt" / "Exit before auth" / "auth failed" / "invalid user"
    ssh_fail=0
    if command -v logread >/dev/null 2>&1; then
        ssh_fail=$(logread 2>/dev/null | grep -iE "dropbear|sshd" | grep -ciE "bad password|exit before auth|auth fail|invalid user|password auth fail|connection closed.*auth" 2>/dev/null)
    fi
    # 备用：从系统日志文件读取
    if [ "$ssh_fail" -eq 0 ] 2>/dev/null; then
        for logf in /var/log/messages /tmp/log/messages /var/log/syslog; do
            [ -f "$logf" ] && {
                f=$(grep -iE "dropbear|sshd" "$logf" 2>/dev/null | grep -ciE "bad password|exit before auth|auth fail|invalid user|password auth fail" 2>/dev/null)
                [ -n "$f" ] && [ "$f" -gt 0 ] 2>/dev/null && ssh_fail=$f && break
            }
        done
    fi
    [ -z "$ssh_fail" ] && ssh_fail=0
    echo "SSH_FAIL_24H=$ssh_fail"

    # 当前连接数（优先conntrack，其次/proc）
    conn_count=0
    if command -v conntrack >/dev/null 2>&1; then
        conn_count=$(conntrack -C 2>/dev/null)
    fi
    if [ -z "$conn_count" ] || [ "$conn_count" = "0" ]; then
        conn_count=$(wc -l < /proc/net/nf_conntrack 2>/dev/null || echo 0)
    fi
    [ -z "$conn_count" ] && conn_count=0
    echo "CONN_COUNT=$conn_count"

    # 【v1.8.8】IPv6 状态（出口/PD前缀/LAN分发/默认路由）
    local pd_prefix lan_v6 v6gw ipv6_status
    pd_prefix=$(ip -6 route show 2>/dev/null | grep 'dev br-lan' | grep -v default | awk '{print $1}' | head -1)
    [ -z "$pd_prefix" ] && pd_prefix="N/A"
    lan_v6=$(ip -6 addr show br-lan 2>/dev/null | grep 'scope global' | grep -v 'fd' | awk '{print $2}' | head -1)
    [ -z "$lan_v6" ] && lan_v6="N/A"
    if ip -6 route show default 2>/dev/null | grep -q 'pppoe-wan'; then
        v6gw="有"; ipv6_status="正常"
    else
        v6gw="无"; ipv6_status="无默认路由"
    fi
    echo "IPV6_STATUS=$ipv6_status"
    echo "PD_PREFIX=$pd_prefix"
    echo "LAN_IPV6=$lan_v6"
    echo "IPV6_GW=$v6gw"

    # 【v1.8.8】DNS 模式与上游
    local dns_mode dns_servers dm
    dm=$(uci -q get netmanager.settings.dns_mode)
    case "$dm" in
        custom) dns_mode="自定义" ;;
        dot)    dns_mode="加密 DoT" ;;
        doh)    dns_mode="加密 DoH" ;;
        *)      dns_mode="运营商自动" ;;
    esac
    dns_servers=$(grep -h '^nameserver' /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
    [ -z "$dns_servers" ] && dns_servers=$(uci -q get netmanager.settings.dns_server1)
    [ -z "$dns_servers" ] && dns_servers="N/A"
    echo "DNS_MODE=$dns_mode"
    echo "DNS_SERVERS=$dns_servers"

    echo "===END==="
}

# ========== 2. 端口转发列表 ==========
cmd_port_list() {
    load_config
    write_log "DEBUG" "port_list: 开始加载端口转发列表"
    echo "===PORT_FORWARD_LIST==="
    echo "DEFAULT_TARGET=$DEFAULT_TARGET"
    
    # 性能优化：nft list ruleset 全量查询在规则多时需 1~3 秒，
    # 改为只查 DNAT 链（输出量减少 90%），并加 2 秒文件缓存避免重复调用。
    # cmd_overview / port_list 共享同一缓存文件，2 秒内复用。
    NFT_CACHE_FILE="/tmp/.netmanager_nft_dstnat"
    NFT_TS_FILE="/tmp/.netmanager_nft_dstnat.ts"
    get_nft_dstnat() {
        local now mtime age out
        now=$(date +%s)
        mtime=0
        [ -f "$NFT_TS_FILE" ] && mtime=$(cat "$NFT_TS_FILE" 2>/dev/null)
        age=$((now - mtime))
        # 2 秒内直接复用文件缓存（毫秒级返回）
        if [ -f "$NFT_CACHE_FILE" ] && [ -n "$mtime" ] && [ "$age" -lt 2 ]; then
            cat "$NFT_CACHE_FILE" 2>/dev/null
            return
        fi
        out=$(nft list chain inet fw4 dstnat 2>/dev/null)
        printf '%s' "$out" > "$NFT_CACHE_FILE" 2>/dev/null
        echo "$now" > "$NFT_TS_FILE" 2>/dev/null
        printf '%s' "$out"
    }
    nft_cache=$(get_nft_dstnat)
    
    # 从nft缓存中提取指定端口的计数器
    get_port_pkts() {
        local dport="$1"
        local result=""
        result=$(echo "$nft_cache" | grep -E "dport[[:space:]]+${dport}[[:space:]]" | grep -o 'packets [0-9]*' | head -1 | awk '{print $2}')
        if [ -z "$result" ]; then
            result=$(echo "$nft_cache" | grep -E "sport[[:space:]]+${dport}[[:space:]]" | grep -o 'packets [0-9]*' | head -1 | awk '{print $2}')
        fi
        [ -n "$result" ] && echo "$result" || echo "0"
    }
    
    # 用 uci show 一次性读取所有防火墙配置
    uci_data=$(uci -q show firewall 2>/dev/null)
    
    echo "---IPV4---"
    
    # 解析 redirect 条目，输出到临时文件
    echo "$uci_data" | awk '
    /^firewall\.@redirect\[/ {
        idx = $0
        sub(/^firewall\.@redirect\[/, "", idx)
        sub(/\].*/, "", idx)
        idx = idx + 0
        attr = $0
        sub(/^firewall\.@redirect\[[0-9]+\]\./, "", attr)
        eq_pos = index(attr, "=")
        if (eq_pos > 0) {
            key = substr(attr, 1, eq_pos - 1)
            val = substr(attr, eq_pos + 1)
            # UCI show 输出用单引号，先去掉首尾的单引号，再去掉可能的双引号
            gsub(/^\047/, "", val)
            gsub(/\047$/, "", val)
            gsub(/^"/, "", val)
            gsub(/"$/, "", val)
        }
        if (key == "name") names[idx] = val
        else if (key == "family") fams[idx] = val
        else if (key == "proto") protos[idx] = val
        else if (key == "src_dport") sps[idx] = val
        else if (key == "dest_ip") dips[idx] = val
        else if (key == "dest_port") dps[idx] = val
        else if (key == "enabled") enableds[idx] = val
        if (idx > max_idx) max_idx = idx
    }
    END {
        for (i = 0; i <= max_idx; i++) {
            # v1.8.3：family=ipv6 的映射不属于 IPv4 表。
            # 混进来会让「目标地址」显示成 IPv6，且与同端口的 IPv4 条目
            # 共用 编辑/删除（按 端口+协议 匹配）时误伤对方。
            if (names[i] != "" && fams[i] != "ipv6") {
                proto = (protos[i] != "") ? protos[i] : "tcp"
                sp = (sps[i] != "") ? sps[i] : ""
                dip = (dips[i] != "") ? dips[i] : ""
                dp = (dps[i] != "") ? dps[i] : sp
                en = (enableds[i] != "") ? enableds[i] : "1"
                printf "%d|%s|%s|%s|%s|%s|%s\n", i, names[i], proto, sp, dip, dp, en
            }
        }
    }' > /tmp/fwm_pv4.txt
    
    while IFS='|' read -r idx name proto sp dip dp en; do
        [ -z "$name" ] && continue
        pkts="0"
        [ -n "$sp" ] && pkts=$(get_port_pkts "$sp")
        echo "$idx|$name|$proto|$sp|$dip|$dp|$en|$pkts"
    done < /tmp/fwm_pv4.txt
    rm -f /tmp/fwm_pv4.txt
    
    echo "---IPV6---"
    
    # 解析 rule 条目，筛选 IPv6
    echo "$uci_data" | awk '
    /^firewall\.@rule\[/ {
        idx = $0
        sub(/^firewall\.@rule\[/, "", idx)
        sub(/\].*/, "", idx)
        idx = idx + 0
        attr = $0
        sub(/^firewall\.@rule\[[0-9]+\]\./, "", attr)
        eq_pos = index(attr, "=")
        if (eq_pos > 0) {
            key = substr(attr, 1, eq_pos - 1)
            val = substr(attr, eq_pos + 1)
            # 去掉单引号和双引号
            gsub(/^\047/, "", val)
            gsub(/\047$/, "", val)
            gsub(/^"/, "", val)
            gsub(/"$/, "", val)
        }
        if (key == "name") names[idx] = val
        else if (key == "family") fams[idx] = val
        else if (key == "proto") protos[idx] = val
        else if (key == "dest_port") dps[idx] = val
        else if (key == "dest_ip") dips[idx] = val
        else if (key == "dest") dests[idx] = val
        else if (key == "enabled") enableds[idx] = val
        if (idx > max_idx) max_idx = idx
    }
    END {
        for (i = 0; i <= max_idx; i++) {
            # v1.8.3：只列出转发到 lan 的 IPv6 放行规则。
            # 系统自带规则（Allow-DHCPv6 / Allow-MLD / Allow-ICMPv6-Input
            # 无 dest，Allow-ICMPv6-Forward 的 dest 为 *）不属于端口转发，
            # 混进来会被误标「未限定目标」，且提供删除按钮易误删导致 IPv6 异常。
            if (names[i] != "" && fams[i] == "ipv6" && dps[i] != "" && dests[i] == "lan") {
                proto = (protos[i] != "") ? protos[i] : "tcp"
                en = (enableds[i] != "") ? enableds[i] : "1"
                dip = (dips[i] != "") ? dips[i] : ""
                printf "%d|%s|%s|%s|%s|%s\n", i, names[i], proto, dps[i], en, dip
            }
        }
    }' > /tmp/fwm_pv6.txt

    # v1.8.3：读取跟踪锚点，供前端展示「动态跟随」状态
    track_data=$(uci -q show netmanager 2>/dev/null | grep '@v6track')

    while IFS='|' read -r idx name proto dp en dip; do
        [ -z "$name" ] && continue
        pkts=$(get_port_pkts "$dp")
        anchor=$(echo "$track_data" | awk -v P="$dp" -v R="$proto" '
            /\.port=/ { v=$0; sub(/.*=/,"",v); gsub(/\047/,"",v); cur_p=v }
            /\.proto=/ { v=$0; sub(/.*=/,"",v); gsub(/\047/,"",v); cur_r=v }
            /\.anchor=/ {
                v=$0; sub(/.*=/,"",v); gsub(/\047/,"",v)
                if (cur_p==P && cur_r==R) { print v; exit }
            }')
        echo "$idx|$name|$proto|$dp|$en|$pkts|$dip|$anchor"
    done < /tmp/fwm_pv6.txt
    rm -f /tmp/fwm_pv6.txt

    # v1.8.3：IPv6 端口映射（family=ipv6 的 DNAT redirect）单独成表。
    # 这类条目此前混在 IPv4 表里，目标显示为 IPv6，且与同端口 IPv4 条目
    # 共用按「端口+协议」匹配的编辑/删除，存在误删风险。
    echo "---IPV6DNAT---"
    echo "$uci_data" | awk '
    /^firewall\.@redirect\[/ {
        idx = $0
        sub(/^firewall\.@redirect\[/, "", idx)
        sub(/\].*/, "", idx)
        idx = idx + 0
        attr = $0
        sub(/^firewall\.@redirect\[[0-9]+\]\./, "", attr)
        eq_pos = index(attr, "=")
        if (eq_pos > 0) {
            key = substr(attr, 1, eq_pos - 1)
            val = substr(attr, eq_pos + 1)
            gsub(/^\047/, "", val)
            gsub(/\047$/, "", val)
            gsub(/^"/, "", val)
            gsub(/"$/, "", val)
        }
        if (key == "name") names[idx] = val
        else if (key == "family") fams[idx] = val
        else if (key == "proto") protos[idx] = val
        else if (key == "src_dport") sps[idx] = val
        else if (key == "dest_ip") dips[idx] = val
        else if (key == "dest_port") dps[idx] = val
        else if (key == "enabled") enableds[idx] = val
        if (idx > max_idx) max_idx = idx
    }
    END {
        for (i = 0; i <= max_idx; i++) {
            if (names[i] != "" && fams[i] == "ipv6") {
                proto = (protos[i] != "") ? protos[i] : "tcp"
                sp = (sps[i] != "") ? sps[i] : ""
                dip = (dips[i] != "") ? dips[i] : ""
                dp = (dps[i] != "") ? dps[i] : sp
                en = (enableds[i] != "") ? enableds[i] : "1"
                printf "%d|%s|%s|%s|%s|%s|%s\n", i, names[i], proto, sp, dip, dp, en
            }
        }
    }' > /tmp/fwm_pv6d.txt

    while IFS='|' read -r idx name proto sp dip dp en; do
        [ -z "$name" ] && continue
        pkts=$(get_port_pkts "$sp")
        anchor=$(echo "$track_data" | awk -v P="$sp" -v R="$proto" '
            /\.port=/ { v=$0; sub(/.*=/,"",v); gsub(/\047/,"",v); cur_p=v }
            /\.proto=/ { v=$0; sub(/.*=/,"",v); gsub(/\047/,"",v); cur_r=v }
            /\.anchor=/ {
                v=$0; sub(/.*=/,"",v); gsub(/\047/,"",v)
                if (cur_p==P && cur_r==R) { print v; exit }
            }')
        echo "$idx|$name|$proto|$sp|$en|$pkts|$dip|$anchor|$dp"
    done < /tmp/fwm_pv6d.txt
    rm -f /tmp/fwm_pv6d.txt

    echo "===END==="
    write_log "DEBUG" "port_list: 列表加载完成"
}

# ========== IPv6 直连放行规则辅助（v1.8.11 新增，v1.8.12 收敛适用范围）==========
# 机制：fw4 的 dstnat_wan 无目的地址门槛，直连目标 GUA 的入站包同样会被 DNAT。
# - 有翻译端口（如 853→38853）：DNAT 真实生效打 ct status dnat，fw4 内建
#   "ct status dnat accept" 已放行（含直连目标 GUA:外部端口被翻译的路径），
#   绝不能再建 dest_port=内部端口 的 ACCEPT 规则——那会把内部端口直接暴露
#   公网直连（直连目标 GUA:38853 也被放行，绕过端口翻译）。v1.8.12 起对
#   翻译端口映射不生成配套规则，并清理历史残留。
# - 无翻译端口（如 51116→51116）：DNAT 为空操作不打标记，直连路径必须靠
#   本规则放行，dest_ip 限定目标 GUA。
# 规则名按「外部端口」命名（Allow-IPv6-<外部端口>-<协议>）便于增删改生命周期匹配，
# 并随 v6track 锚点跟随前缀变化（port_sync_v6 按名称匹配改写 dest_ip）。
# $1=外部端口(命名用) $2=协议 $3=目标GUA $4=内部端口(dest_port，留空同外部)
v6_ensure_allow_rule() {
    _ap="$1"; _apr="$2"; _agua="$3"; _adp="$4"
    { [ -z "$_ap" ] || [ -z "$_agua" ]; } && return 0
    [ -z "$_adp" ] && _adp="$_ap"
    # v1.8.12：翻译端口映射不需要也不允许配套放行规则（见上方注释），
    # 存在历史残留（v1.8.11 生成）则删除。
    if [ "$_adp" != "$_ap" ]; then
        v6_remove_allow_rule "$_ap" "$_apr"
        return 0
    fi
    _aname="Allow-IPv6-${_ap}-${_apr}"
    _ai=0; _asec=""
    while uci -q get "firewall.@rule[$_ai]" >/dev/null 2>&1; do
        if [ "$(uci -q get firewall.@rule[$_ai].name)" = "$_aname" ]; then
            _asec="@rule[$_ai]"; break
        fi
        _ai=$((_ai+1))
    done
    if [ -z "$_asec" ]; then
        uci add firewall rule >/dev/null
        _asec="@rule[-1]"
        uci set "firewall.$_asec.name=$_aname"
        uci set "firewall.$_asec.src=wan"
        uci set "firewall.$_asec.dest=lan"
        uci set "firewall.$_asec.target=ACCEPT"
        uci set "firewall.$_asec.family=ipv6"
    fi
    uci set "firewall.$_asec.proto=$_apr"
    uci set "firewall.$_asec.dest_port=$_adp"
    uci set "firewall.$_asec.dest_ip=$_agua"
}
# 删除指定端口的配套直连放行规则；$2 为协议列表（空=该端口全部协议）
v6_remove_allow_rule() {
    _rp="$1"; _rprs="$2"
    [ -z "$_rp" ] && return 0
    _ri=0
    while uci -q get "firewall.@rule[$_ri]" >/dev/null 2>&1; do
        _rn=$(uci -q get "firewall.@rule[$_ri].name")
        _rpr=$(uci -q get "firewall.@rule[$_ri].proto")
        _hit=0
        case "$_rn" in Allow-IPv6-${_rp}-*) _hit=1 ;; esac
        if [ "$_hit" = "1" ] && [ -n "$_rprs" ]; then
            _hit=0
            for _m in $_rprs; do proto_match "$_rpr" "$_m" && _hit=1; done
        fi
        if [ "$_hit" = "1" ]; then
            uci delete "firewall.@rule[$_ri]"
            info "删除IPv6直连放行: $_rn"
        else
            _ri=$((_ri+1))
        fi
    done
}

# ========== 3. 添加端口转发 ==========
cmd_port_add() {
    port="$1"; proto="$2"; target="$3"; ipver="$4"; dport="$5"
    [ -z "$port" ] && { error "用法: netmanager port_add <外部端口> <tcp|udp|both> [目标IP] [v4|v6|both] [内部端口]"; exit 1; }
    write_log "INFO" "port_add: 请求添加 外部端口=$port 协议=$proto 目标=$target 版本=$ipver 内部端口=${dport:-同外部}"
    [ -z "$proto" ] && proto="tcp"
    load_config
    # 端口格式标准化：冒号转横线（OpenWrt要求 999-1520 而非 999:1520）
    port=$(echo "$port" | sed 's/:/-/g')
    dport=$(echo "$dport" | sed 's/:/-/g')
    # 内部端口：留空则与外部端口一致；非空仅允许数字/横线范围格式
    if [ -n "$dport" ]; then
        case "$dport" in
            *[!0-9-]*|-*) error "内部端口格式无效: $dport (应为 8080 或 1000-2000)"; exit 1 ;;
            *-|*-*-*) error "内部端口格式无效: $dport (应为 8080 或 1000-2000)"; exit 1 ;;
        esac
    else
        dport="$port"
    fi
    if [ -n "$target" ]; then
        case "$target" in
            both|v4|v6)
                # 参数错位：$3 实际是 ipver，target 用默认值
                ipver="$target"
                target="$DEFAULT_TARGET"
                ;;
            *)
                # 正常情况，$3 是IP
                ;;
        esac
    else
        target="$DEFAULT_TARGET"
    fi
    [ -z "$ipver" ] && ipver="both"

    if [ "$ipver" = "v4" ] || [ "$ipver" = "both" ]; then
        for p in $(echo "$proto" | sed 's/both/tcp udp/'); do
            exists=0; idx=0
            while true; do
                uci -q get "firewall.@redirect[$idx]" >/dev/null 2>&1 || break
                sp=$(uci get firewall.@redirect[$idx].src_dport 2>/dev/null)
                pr=$(uci get firewall.@redirect[$idx].proto 2>/dev/null)
                if [ "$sp" = "$port" ] && proto_match "$pr" "$p"; then exists=1; fi
                idx=$((idx+1))
            done
            if [ $exists -eq 0 ]; then
                uci add firewall redirect > /dev/null
                uci set firewall.@redirect[-1].name="Forward-${port}-${p}"
                uci set firewall.@redirect[-1].src="wan"
                uci set firewall.@redirect[-1].proto="$p"
                uci set firewall.@redirect[-1].src_dport="$port"
                uci set firewall.@redirect[-1].dest="lan"
                uci set firewall.@redirect[-1].dest_ip="$target"
                uci set firewall.@redirect[-1].dest_port="$dport"
                uci set firewall.@redirect[-1].target="DNAT"
                info "IPv4 DNAT: $port/$p -> $target:$dport"
            else
                warn "IPv4已存在: $port/$p"
            fi
        done
    fi

    if [ "$ipver" = "v6" ] || [ "$ipver" = "both" ]; then
        for p in $(echo "$proto" | sed 's/both/tcp udp/'); do
            exists=0; idx=0
            while true; do
                uci -q get "firewall.@redirect[$idx]" >/dev/null 2>&1 || break
                fam=$(uci get firewall.@redirect[$idx].family 2>/dev/null)
                sp=$(uci get firewall.@redirect[$idx].src_dport 2>/dev/null)
                pr=$(uci get firewall.@redirect[$idx].proto 2>/dev/null)
                if [ "$fam" = "ipv6" ] && [ "$sp" = "$port" ] && proto_match "$pr" "$p"; then exists=1; fi
                idx=$((idx+1))
            done
            if [ $exists -eq 0 ]; then
                # v1.8.10：IPv6 与 IPv4 对称，创建 DNAT 端口映射（redirect family=ipv6）。
                # v1.8.12：仅无翻译端口（外部=内部）配套创建 Allow-IPv6 直连放行规则
                # （见 v6_ensure_allow_rule）；翻译端口由 DNAT + ct status dnat accept
                # 放行，不再生成（避免内部端口暴露公网直连）。
                # dest_ip 必须是 IPv6 地址：传入 IPv6 直用；传入 IPv4/留空默认目标时
                # 按该主机解析当前公网 IPv6（SLAAC 优先），并登记跟踪锚点跟随前缀变化。
                v6_target=""
                case "$target" in
                    *:*) v6_target="$target" ;;
                    *)
                        v6_target=$(v6_resolve_target "$target")
                        if [ -n "$v6_target" ]; then
                            info "目标 $target 解析为 IPv6: $v6_target"
                            # 登记跟踪锚点（前缀变更时 port_sync_v6 自动改写 dest_ip）
                            _ti=0; _tfound=0
                            while uci -q get "netmanager.@v6track[$_ti]" >/dev/null 2>&1; do
                                if [ "$(uci -q get netmanager.@v6track[$_ti].port)" = "$port" ] && \
                                   [ "$(uci -q get netmanager.@v6track[$_ti].proto)" = "$p" ]; then
                                    _tfound=1; break
                                fi
                                _ti=$((_ti+1))
                            done
                            if [ $_tfound -eq 0 ]; then
                                uci add netmanager v6track >/dev/null
                                uci set netmanager.@v6track[-1].port="$port"
                                uci set netmanager.@v6track[-1].proto="$p"
                                uci set netmanager.@v6track[-1].anchor="$target"
                                uci set netmanager.@v6track[-1].enabled='1'
                                uci commit netmanager
                            fi
                        fi
                        ;;
                esac
                if [ -z "$v6_target" ]; then
                    error "IPv6映射创建失败: 无法解析 $target 的公网 IPv6（DNAT 必须有目标地址，请确认主机在线且已获取 IPv6，或直接填写 IPv6 地址）"
                    continue
                fi
                uci add firewall redirect > /dev/null
                uci set firewall.@redirect[-1].name="Forward-v6-${port}-${p}"
                uci set firewall.@redirect[-1].src="wan"
                uci set firewall.@redirect[-1].proto="$p"
                uci set firewall.@redirect[-1].src_dport="$port"
                uci set firewall.@redirect[-1].dest="lan"
                uci set firewall.@redirect[-1].dest_ip="$v6_target"
                uci set firewall.@redirect[-1].dest_port="$dport"
                uci set firewall.@redirect[-1].family="ipv6"
                uci set firewall.@redirect[-1].target="DNAT"
                info "IPv6 DNAT: $port/$p -> [$v6_target]:$dport"
                # v1.8.12：仅无翻译端口生成配套直连放行规则；翻译端口清理历史残留
                v6_ensure_allow_rule "$port" "$p" "$v6_target" "$dport"
            else
                warn "IPv6映射已存在: $port/$p"
            fi
        done
    fi

    uci commit firewall
    rm -f /tmp/.uci/firewall 2>/dev/null
    /etc/init.d/firewall reload > /dev/null 2>&1
    # 清除 nft 命中数缓存，确保下次 port_list 拿到最新数据
    rm -f /tmp/.netmanager_nft_dstnat /tmp/.netmanager_nft_dstnat.ts 2>/dev/null
    info "完成！"
}

# ========== 4. 编辑端口转发 ==========
cmd_port_edit() {
    old_port="$1"; old_proto="$2"; new_port="$3"; new_proto="$4"; new_target="$5"; new_ipver="$6"; new_dport="$7"; old_ipver="$8"
    [ -z "$old_port" ] && { error "用法: netmanager port_edit <旧端口> <旧协议> <新端口> <新协议> <新目标IP> [v4|v6|both] [新内部端口] [旧族v4|v6]"; exit 1; }
    [ -z "$old_proto" ] && old_proto="tcp"
    [ -z "$new_proto" ] && new_proto="tcp"
    # 归一化：both/tcpudp 统一为 fw4 合法值 tcpudp（一条规则同时覆盖tcp+udp）
    case "$new_proto" in
        both|tcpudp) new_proto="tcpudp" ;;
    esac
    load_config
    [ -z "$new_target" ] && new_target="$DEFAULT_TARGET"
    [ -z "$new_ipver" ] && new_ipver="both"
    [ -z "$old_ipver" ] && old_ipver="v4"
    # 新内部端口：留空则与新外部端口一致
    [ -z "$new_dport" ] && new_dport="$new_port"
    # 端口格式标准化（冒号转横线，OpenWrt要求 999-1520 而非 999:1520）
    new_port=$(echo "$new_port" | sed 's/:/-/g')
    old_port=$(echo "$old_port" | sed 's/:/-/g')
    new_dport=$(echo "$new_dport" | sed 's/:/-/g')
    # 内部端口格式校验：仅允许数字/横线范围（须在冒号转换之后进行）
    case "$new_dport" in
        *[!0-9-]*|-*) error "内部端口格式无效: $new_dport (应为 8080 或 1000-2000)"; exit 1 ;;
        *-|*-*-*) error "内部端口格式无效: $new_dport (应为 8080 或 1000-2000)"; exit 1 ;;
    esac

    # 生成要匹配的协议列表（处理 both/tcpudp/空值）
    match_old_protos=""
    case "$old_proto" in
        both|tcpudp) match_old_protos="tcp udp" ;;
        *) match_old_protos="$old_proto" ;;
    esac

    # v1.8.10：按族定位旧条目（v4/v6 各自独立的 redirect，互不误伤）。
    # 旧版按 端口+协议 全局匹配，同端口的 v4/v6 条目会互相覆盖/误删。
    old_idx=""
    idx=0
    while uci -q get "firewall.@redirect[$idx]" >/dev/null 2>&1; do
        fam=$(uci -q get "firewall.@redirect[$idx].family")
        sp=$(uci -q get "firewall.@redirect[$idx].src_dport")
        pr=$(uci -q get "firewall.@redirect[$idx].proto")
        if [ "$sp" = "$old_port" ]; then
            if { [ "$old_ipver" = "v6" ] && [ "$fam" = "ipv6" ]; } || \
               { [ "$old_ipver" != "v6" ] && [ "$fam" != "ipv6" ]; }; then
                for mp in $match_old_protos; do
                    if proto_match "$pr" "$mp"; then old_idx="$idx"; break; fi
                done
            fi
        fi
        [ -n "$old_idx" ] && break
        idx=$((idx+1))
    done
    [ -z "$old_idx" ] && { error "未找到旧转发条目: $old_port/$old_proto ($old_ipver)"; exit 1; }

    # v1.8.11：旧条目为 IPv6 时先清掉其配套直连放行规则（端口/协议可能变化），
    # 若新族仍为 v6 会在下方按新参数重建。
    if [ "$old_ipver" = "v6" ]; then
        v6_remove_allow_rule "$old_port" ""
    fi

    # 目标族解析：both=保留原族；v4/v6=切换到指定族
    want_v6=0
    case "$new_ipver" in
        v6) want_v6=1 ;;
        v4) want_v6=0 ;;
        *) [ "$old_ipver" = "v6" ] && want_v6=1 ;;
    esac

    # v6 目标地址解析（IPv6 直用；IPv4/锚点解析当前公网 IPv6）
    v6_target=""
    if [ "$want_v6" = "1" ]; then
        case "$new_target" in
            *:*) v6_target="$new_target" ;;
            *)
                v6_target=$(v6_resolve_target "$new_target")
                [ -z "$v6_target" ] && { error "无法解析 $new_target 的公网 IPv6，IPv6 映射必须有目标地址（主机需在线且已获取 IPv6，或直接填写 IPv6 地址）"; exit 1; }
                info "目标 $new_target 解析为 IPv6: $v6_target"
                ;;
        esac
    fi

    if [ "$want_v6" = "1" ]; then
        uci set firewall.@redirect[$old_idx].name="Forward-v6-${new_port}-${new_proto}"
        uci set firewall.@redirect[$old_idx].family="ipv6"
        uci set firewall.@redirect[$old_idx].dest_ip="$v6_target"
        # 登记/更新跟踪锚点（目标为 IPv4 锚点时）
        case "$new_target" in
            *:*) ;;
            *)
                _ti=0; _tsec=""
                while uci -q get "netmanager.@v6track[$_ti]" >/dev/null 2>&1; do
                    if [ "$(uci -q get netmanager.@v6track[$_ti].port)" = "$new_port" ] && \
                       [ "$(uci -q get netmanager.@v6track[$_ti].proto)" = "$new_proto" ]; then
                        _tsec="@v6track[$_ti]"; break
                    fi
                    _ti=$((_ti+1))
                done
                [ -z "$_tsec" ] && { uci add netmanager v6track >/dev/null; _tsec="@v6track[-1]"; }
                uci set "netmanager.$_tsec.port=$new_port"
                uci set "netmanager.$_tsec.proto=$new_proto"
                uci set "netmanager.$_tsec.anchor=$new_target"
                uci set "netmanager.$_tsec.enabled=1"
                uci commit netmanager
                ;;
        esac
        # v1.8.11：按新参数重建配套直连放行规则（dest_port 用新内部端口）
        v6_ensure_allow_rule "$new_port" "$new_proto" "$v6_target" "$new_dport"
    else
        uci set firewall.@redirect[$old_idx].name="Forward-${new_port}"
        uci delete firewall.@redirect[$old_idx].family 2>/dev/null
        uci set firewall.@redirect[$old_idx].dest_ip="$new_target"
    fi
    uci set firewall.@redirect[$old_idx].src="wan"
    uci set firewall.@redirect[$old_idx].dest="lan"
    uci set firewall.@redirect[$old_idx].proto="$new_proto"
    uci set firewall.@redirect[$old_idx].src_dport="$new_port"
    uci set firewall.@redirect[$old_idx].dest_port="$new_dport"
    uci set firewall.@redirect[$old_idx].target="DNAT"
    info "更新转发($([ "$want_v6" = "1" ] && echo IPv6 || echo IPv4)): 外部$new_port/内部$new_dport -> $([ "$want_v6" = "1" ] && echo "$v6_target" || echo "$new_target")"

    uci commit firewall
    rm -f /tmp/.uci/firewall 2>/dev/null
    /etc/init.d/firewall reload > /dev/null 2>&1
    # 清除 nft 命中数缓存，确保下次 port_list 拿到最新数据
    rm -f /tmp/.netmanager_nft_dstnat /tmp/.netmanager_nft_dstnat.ts 2>/dev/null
    info "端口转发已更新"
}

# ========== 5. 删除端口转发 ==========
cmd_port_del() {
    port="$1"; proto="${2:-tcp}"; ipver="${3:-both}"
    [ -z "$port" ] && { error "用法: netmanager port_del <端口> [tcp|udp|both] [v4|v6|both]"; exit 1; }
    load_config
    write_log "INFO" "port_del: 请求删除 端口=$port 协议=$proto 族=$ipver"

    # 端口格式标准化：冒号转横线
    port=$(echo "$port" | sed 's/:/-/g')

    # 扩展proto匹配：处理 both/tcpudp/空值
    # 生成要匹配的协议列表
    match_protos=""
    case "$proto" in
        both|tcpudp)
            match_protos="tcp udp"
            ;;
        tcp|udp)
            match_protos="$proto"
            ;;
        *)
            match_protos="$proto"
            ;;
    esac

    # 收集所有需要删除的 redirect 索引（从后往前，避免索引移位）
    # v1.8.10：按族过滤——v4 只删非 ipv6 条目，v6 只删 ipv6 条目，both 全删。
    # 旧版不分族，删 IPv4 条目会连带误删同端口的 IPv6 映射。
    del_indices=""
    idx=0
    while true; do
        name=$(uci get firewall.@redirect[$idx].name 2>/dev/null)
        uci -q get "firewall.@redirect[$idx]" >/dev/null 2>&1 || break
        fam=$(uci -q get firewall.@redirect[$idx].family 2>/dev/null)
        sp=$(uci get firewall.@redirect[$idx].src_dport 2>/dev/null)
        pr=$(uci get firewall.@redirect[$idx].proto 2>/dev/null)
        if [ "$sp" = "$port" ]; then
            if { [ "$ipver" = "v6" ] && [ "$fam" = "ipv6" ]; } || \
               { [ "$ipver" = "v4" ] && [ "$fam" != "ipv6" ]; } || \
               [ "$ipver" = "both" ]; then
                for mp in $match_protos; do
                    if proto_match "$pr" "$mp"; then
                        del_indices="$idx $del_indices"
                        break
                    fi
                done
            fi
        fi
        idx=$((idx+1))
    done

    # 删除收集到的 redirect 规则
    for didx in $del_indices; do
        name=$(uci get firewall.@redirect[$didx].name 2>/dev/null)
        uci delete firewall.@redirect[$didx]
        info "删除转发: $name"
    done

    # v1.8.11：删除 v6/both 映射时同步清理配套的 Allow-IPv6 直连放行规则
    # （由 port_add 随映射创建，按名称前缀精确匹配，不误伤用户自定义规则）。
    if [ "$ipver" != "v4" ]; then
        v6_remove_allow_rule "$port" "$match_protos"
    fi

    # v1.8.10：删除 v6/both 映射时同步清理跟踪锚点，避免遗留无效 v6track
    if [ "$ipver" != "v4" ]; then
        _ti=0
        while uci -q get "netmanager.@v6track[$_ti]" >/dev/null 2>&1; do
            _tp=$(uci -q get "netmanager.@v6track[$_ti].port")
            _tr=$(uci -q get "netmanager.@v6track[$_ti].proto")
            _hit=0
            if [ "$_tp" = "$port" ]; then
                for mp in $match_protos; do
                    proto_match "$_tr" "$mp" && _hit=1
                done
            fi
            if [ "$_hit" = "1" ]; then
                uci delete "netmanager.@v6track[$_ti]"
            else
                _ti=$((_ti+1))
            fi
        done
        uci commit netmanager 2>/dev/null
    fi

    uci commit firewall
    rm -f /tmp/.uci/firewall 2>/dev/null
    /etc/init.d/firewall reload > /dev/null 2>&1
    # 清除 nft 命中数缓存，确保下次 port_list 拿到最新数据
    rm -f /tmp/.netmanager_nft_dstnat /tmp/.netmanager_nft_dstnat.ts 2>/dev/null
    info "完成！"
}

# ========== 4.5 IPv6 转发目标动态跟踪（v1.8.3 新增）==========
# 背景：运营商 PD 前缀会变化（实测一天内变更多次）。IPv6 放行规则若把
#       目标地址写死，前缀一变规则即失效；而目标主机的接口后缀通常稳定
#       （DHCPv6 静态分配如 ::3，或 SLAAC 的固定 IID）。
# 方案：为规则登记一个「锚点」（IPv4 地址 / MAC / 主机名），
#       由 v6_resolve_target 实时解析该主机当前的公网 IPv6，
#       前缀变更时由 hotplug / 定时任务自动改写 dest_ip。

# 取 br-lan 当前公网 IPv6 前缀（/64，形如 2408:xxxx:xxxx:xxxx:）
v6_current_prefix() {
    local p
    p=$(ip -6 addr show dev br-lan scope global 2>/dev/null \
        | awk '/inet6/{print $2}' | cut -d/ -f1 \
        | grep -viE '^fd|^fc' | head -1)
    [ -z "$p" ] && return 1
    # 取前 4 段作为 /64 前缀
    echo "$p" | awk -F: '{printf "%s:%s:%s:%s:\n", $1,$2,$3,$4}'
}

# 按锚点解析目标主机当前公网 IPv6
# 锚点支持：IPv4 地址 / MAC 地址 / 主机名
# 解析优先级（v1.8.3）：邻居表 SLAAC 地址（对齐目标机
#   `ip -6 addr show scope global | grep -v deprecated` 选出的 /64 地址）
#   → DHCP 静态 hostid（兜底）→ DHCPv6 租约 → 邻居表任意全局地址
v6_resolve_target() {
    local anchor="$1" prefix mac hostid duid addr hostname i h_ip h_mac h_hostid h_name
    local hostid_addr="" m_duid="" hex
    [ -z "$anchor" ] && return 1
    prefix=$(v6_current_prefix) || return 1

    # 归一化 MAC 为小写
    case "$anchor" in
        *:*:*:*:*:*) mac=$(echo "$anchor" | tr 'A-Z' 'a-z') ;;
        *) mac="" ;;
    esac

    # 1) 由锚点在 dhcp host 静态绑定中找 hostid / duid / mac（只收集，不抢先返回）
    i=0
    while uci -q get "dhcp.@host[$i]" >/dev/null 2>&1; do
        h_ip=$(uci -q get "dhcp.@host[$i].ip")
        h_mac=$(uci -q get "dhcp.@host[$i].mac" | tr 'A-Z' 'a-z')
        h_hostid=$(uci -q get "dhcp.@host[$i].hostid")
        h_name=$(uci -q get "dhcp.@host[$i].name")
        duid=$(uci -q get "dhcp.@host[$i].duid")
        if [ "$anchor" = "$h_ip" ] || [ "$mac" = "$h_mac" ] || [ "$anchor" = "$h_name" ]; then
            # 1a) hostid 拼出静态地址，留作兜底
            if [ -n "$h_hostid" ]; then
                case "$h_hostid" in
                    *:*) hostid_addr="${prefix}${h_hostid#:}" ;;
                    *)
                        # 十进制 hostid 转十六进制
                        hex=$(printf '%x' "$h_hostid" 2>/dev/null)
                        [ -n "$hex" ] && hostid_addr="${prefix}:${hex}"
                        ;;
                esac
            fi
            # 1b) DUID 留作次级兜底
            m_duid="$duid"
            # 1c) 落到 MAC 解析
            [ -z "$mac" ] && mac="$h_mac"
            break
        fi
        i=$((i+1))
    done

    # 2) 锚点是 IPv4：先从 DHCP 租约换算 MAC
    if [ -z "$mac" ]; then
        case "$anchor" in
            *.*.*.*)
                mac=$(awk -v ip="$anchor" '$3==ip{print tolower($2)}' /tmp/dhcp.leases 2>/dev/null | head -1)
                ;;
        esac
    fi

    # 3) 锚点是主机名：从 DHCP 租约取 MAC
    if [ -z "$mac" ]; then
        mac=$(awk -v h="$anchor" '$4==h{print tolower($2)}' /tmp/dhcp.leases 2>/dev/null | head -1)
    fi

    # 4) 首选：邻居表中该 MAC 在当前前缀下的 SLAAC 地址。
    #    目标机对外通信用的是 SLAAC /64 地址（如 Debian 的 mngtmpaddr），
    #    hostid 静态地址（::3 等）只是锚点，不应作为转发目标。
    #    排除 FAILED/INCOMPLETE 死条目；REACHABLE（近期有流量）优先，
    #    近似目标机侧 "grep -v deprecated" 的效果。
    if [ -n "$mac" ]; then
        addr=$(ip -6 neigh show dev br-lan 2>/dev/null \
            | awk -v m="$mac" -v p="$prefix" -v x="$hostid_addr" '
                tolower($0) ~ m && index($1, p) == 1 && $1 != x &&
                $0 !~ /FAILED|INCOMPLETE/ {
                    print ($0 ~ /REACHABLE/ ? "0 " : "1 ") $1
                }' | sort | head -1 | cut -d' ' -f2)
        [ -n "$addr" ] && { echo "$addr"; return 0; }
    fi

    # 5) 兜底：hostid 静态地址（主机离线/邻居表空时仍可跟住前缀）
    [ -n "$hostid_addr" ] && { echo "$hostid_addr"; return 0; }

    # 6) 兜底：DUID 查 DHCPv6 租约
    if [ -n "$m_duid" ]; then
        addr=$(v6_lease_by_duid "$m_duid")
        [ -n "$addr" ] && { echo "$addr"; return 0; }
    fi

    # 7) 最后兜底：邻居表按 MAC 找任意公网 IPv6（排除 ULA / 链路本地）
    if [ -n "$mac" ]; then
        addr=$(ip -6 neigh show dev br-lan 2>/dev/null \
            | awk -v m="$mac" 'tolower($0) ~ m {print $1}' \
            | grep -viE '^fe80|^fd|^fc' | head -1)
        [ -n "$addr" ] && { echo "$addr"; return 0; }
    fi

    return 1
}

# 从 odhcpd 租约中按 DUID 取公网 IPv6
v6_lease_by_duid() {
    local want="$1"
    command -v ubus >/dev/null 2>&1 || return 1
    ubus call dhcp ipv6leases 2>/dev/null | awk -v d="$want" '
        /"duid"/ { cur=$0; gsub(/.*"duid": *"|",?$/,"",cur); hit=(cur==d) }
        /"address"/ && hit {
            a=$0; gsub(/.*"address": *"|",?$/,"",a)
            if (a !~ /^fd/ && a !~ /^fc/ && a !~ /^fe80/) { print a; exit }
        }
    '
}

# 登记/取消某条 IPv6 放行规则的目标跟踪
# 用法: netmanager port_track_v6 <端口> <tcp|udp> <锚点|off>
cmd_port_track_v6() {
    local port="$1" proto="$2" anchor="$3" i found=0 sec
    [ -z "$port" ] && { error "用法: netmanager port_track_v6 <端口> <tcp|udp> <锚点IPv4/MAC/主机名|off>"; exit 1; }
    port=$(echo "$port" | sed 's/:/-/g')
    [ -z "$proto" ] && proto="tcp"

    # 找到已存在的跟踪节
    i=0
    while uci -q get "netmanager.@v6track[$i]" >/dev/null 2>&1; do
        if [ "$(uci -q get netmanager.@v6track[$i].port)" = "$port" ] && \
           [ "$(uci -q get netmanager.@v6track[$i].proto)" = "$proto" ]; then
            sec="@v6track[$i]"; found=1; break
        fi
        i=$((i+1))
    done

    if [ "$anchor" = "off" ] || [ -z "$anchor" ]; then
        if [ $found -eq 1 ]; then
            uci delete "netmanager.$sec"
            uci commit netmanager
            info "已取消 $port/$proto 的 IPv6 目标跟踪"
        else
            info "$port/$proto 未启用跟踪"
        fi
        return 0
    fi

    # 先验证锚点当前能否解析，避免登记一个无效锚点
    local resolved
    resolved=$(v6_resolve_target "$anchor")
    if [ -z "$resolved" ]; then
        warn "锚点 $anchor 当前无法解析出公网 IPv6（主机可能离线），仍登记跟踪，待其上线后自动生效"
    else
        info "锚点 $anchor 当前解析为 $resolved"
    fi

    if [ $found -eq 0 ]; then
        uci add netmanager v6track >/dev/null
        sec="@v6track[-1]"
    fi
    uci set "netmanager.$sec.port=$port"
    uci set "netmanager.$sec.proto=$proto"
    uci set "netmanager.$sec.anchor=$anchor"
    uci set "netmanager.$sec.enabled=1"
    uci commit netmanager
    info "已登记 $port/$proto 跟踪锚点 $anchor"
    # 立即同步一次
    cmd_port_sync_v6
}

# 同步所有已跟踪的 IPv6 放行规则目标地址
# 用法: netmanager port_sync_v6 [--quiet]
cmd_port_sync_v6() {
    local quiet=0
    [ "$1" = "--quiet" ] && quiet=1
    local i port proto anchor enabled resolved idx fam dp pr changed=0 checked=0
    local sp _cprs _ri _rn _rpr _hit _m
    local prefix
    prefix=$(v6_current_prefix)
    if [ -z "$prefix" ]; then
        [ $quiet -eq 0 ] && warn "当前无公网 IPv6 前缀，跳过同步"
        return 0
    fi
    [ $quiet -eq 0 ] && info "当前 LAN 前缀: ${prefix}:/64"

    i=0
    while uci -q get "netmanager.@v6track[$i]" >/dev/null 2>&1; do
        enabled=$(uci -q get "netmanager.@v6track[$i].enabled")
        port=$(uci -q get "netmanager.@v6track[$i].port")
        proto=$(uci -q get "netmanager.@v6track[$i].proto")
        anchor=$(uci -q get "netmanager.@v6track[$i].anchor")
        i=$((i+1))
        [ "$enabled" = "0" ] && continue
        [ -z "$port" ] || [ -z "$anchor" ] && continue
        checked=$((checked+1))

        resolved=$(v6_resolve_target "$anchor")
        if [ -z "$resolved" ]; then
            [ $quiet -eq 0 ] && warn "$port/$proto 锚点 $anchor 暂时解析不到，保留原目标"
            continue
        fi

        # 定位对应的 IPv6 放行规则并改写 dest_ip。
        # v1.8.11：配套规则按名称 Allow-IPv6-<外部端口>-* 匹配（其 dest_port 为内部端口，
        # 翻译端口下不等于外部端口，故不能按 dest_port 匹配）；兼容旧版按 dest_port 匹配。
        idx=0
        while uci -q get "firewall.@rule[$idx]" >/dev/null 2>&1; do
            fam=$(uci -q get "firewall.@rule[$idx].family")
            dp=$(uci -q get "firewall.@rule[$idx].dest_port")
            pr=$(uci -q get "firewall.@rule[$idx].proto")
            rn=$(uci -q get "firewall.@rule[$idx].name")
            _namehit=0
            case "$rn" in Allow-IPv6-${port}-*) _namehit=1 ;; esac
            if [ "$fam" = "ipv6" ] && proto_match "$pr" "$proto" && \
               { [ "$_namehit" = "1" ] || [ "$dp" = "$port" ]; }; then
                local old
                old=$(uci -q get "firewall.@rule[$idx].dest_ip")
                if [ "$old" != "$resolved" ]; then
                    uci set "firewall.@rule[$idx].dest_ip=$resolved"
                    changed=$((changed+1))
                    [ $quiet -eq 0 ] && info "$port/$proto 目标 ${old:-未设置} -> $resolved"
                fi
            fi
            idx=$((idx+1))
        done

        # v1.8.3：family=ipv6 的端口映射(DNAT)同样需要跟随前缀。
        # 这类条目匹配的是外部端口 src_dport，内部端口 dest_port 保持不变。
        idx=0
        while uci -q get "firewall.@redirect[$idx]" >/dev/null 2>&1; do
            fam=$(uci -q get "firewall.@redirect[$idx].family")
            dp=$(uci -q get "firewall.@redirect[$idx].src_dport")
            pr=$(uci -q get "firewall.@redirect[$idx].proto")
            if [ "$fam" = "ipv6" ] && [ "$dp" = "$port" ] && proto_match "$pr" "$proto"; then
                local oldr
                oldr=$(uci -q get "firewall.@redirect[$idx].dest_ip")
                if [ "$oldr" != "$resolved" ]; then
                    uci set "firewall.@redirect[$idx].dest_ip=$resolved"
                    changed=$((changed+1))
                    [ $quiet -eq 0 ] && info "映射 $port/$proto 目标 ${oldr:-未设置} -> $resolved"
                fi
            fi
            idx=$((idx+1))
        done
    done

    # v1.8.12：清理翻译端口映射历史残留的配套放行规则（v1.8.11 曾为所有
    # IPv6 映射生成 Allow-IPv6 规则）。翻译端口由 DNAT + ct status dnat accept
    # 放行，dest_port=内部端口 的 ACCEPT 规则会把内部端口暴露公网直连
    # （如 853→38853 时直连 38853 也通）。扫描全部 IPv6 映射（不限于跟踪
    # 锚点），存量安装升级后随 cron / hotplug 同步自愈。
    idx=0
    while uci -q get "firewall.@redirect[$idx]" >/dev/null 2>&1; do
        fam=$(uci -q get "firewall.@redirect[$idx].family")
        sp=$(uci -q get "firewall.@redirect[$idx].src_dport")
        dp=$(uci -q get "firewall.@redirect[$idx].dest_port")
        pr=$(uci -q get "firewall.@redirect[$idx].proto")
        if [ "$fam" = "ipv6" ] && [ -n "$sp" ] && [ -n "$dp" ] && [ "$dp" != "$sp" ]; then
            case "$pr" in both|tcpudp) _cprs="tcp udp" ;; *) _cprs="$pr" ;; esac
            _ri=0
            while uci -q get "firewall.@rule[$_ri]" >/dev/null 2>&1; do
                _rn=$(uci -q get "firewall.@rule[$_ri].name")
                _rpr=$(uci -q get "firewall.@rule[$_ri].proto")
                _hit=0
                case "$_rn" in Allow-IPv6-${sp}-*) _hit=1 ;; esac
                if [ "$_hit" = "1" ]; then
                    _hit=0
                    for _m in $_cprs; do proto_match "$_rpr" "$_m" && _hit=1; done
                fi
                if [ "$_hit" = "1" ]; then
                    v6_remove_allow_rule "$sp" "$_cprs"
                    changed=$((changed+1))
                    [ $quiet -eq 0 ] && info "清理翻译端口映射 $sp->$dp 的多余直连放行规则（内部端口不再暴露直连）"
                    break
                fi
                _ri=$((_ri+1))
            done
        fi
        idx=$((idx+1))
    done

    if [ $changed -gt 0 ]; then
        uci commit firewall
        rm -f /tmp/.uci/firewall 2>/dev/null
        /etc/init.d/firewall reload >/dev/null 2>&1
        rm -f /tmp/.netmanager_nft_dstnat /tmp/.netmanager_nft_dstnat.ts 2>/dev/null
        write_log "INFO" "port_sync_v6: 前缀 ${prefix}:/64，更新 $changed 条 IPv6 转发目标"
        [ $quiet -eq 0 ] && info "已更新 $changed 条规则并重载防火墙"
    else
        [ $quiet -eq 0 ] && info "检查 $checked 项，目标地址均为最新，无需改动"
    fi

    # 顺带清理旧前缀遗留的源路由（前缀变更后 netifd 可能留下不可达条目）
    v6_cleanup_stale_routes "$prefix" "$quiet"
    # v1.8.3：同步清理 piofolder 前缀记忆，止住 RA 对失效前缀的持续广播
    v6_cleanup_piofolder "$prefix" "$quiet"
    # v1.8.7：顺带做 IPv6 默认网关自愈（复用本命令的 cron / hotplug 触发）
    cmd_v6gw --quiet
}

# v1.8.7：IPv6 默认网关自愈
# 背景：pppoe 场景为抑制 netifd 自动 wan_6 与手动 wan6 双接口冲突而关闭
#   network.wan.ipv6 后，pppoe 自带的 IPv6 默认路由也随之消失；手动 wan6
#   只做 PD 委派、不装默认路由。odhcpd 默认 ra_default=0 仅在路由器有默认
#   路由时才宣告网关 —— 于是 LAN 客户端拿到 SLAAC 地址却没有默认网关、上不了网。
# 本命令做两件事：
#   ① pppoe 且默认路由缺失/指向失效设备时，补 default dev <wan-l3> metric 512；
#   ② LAN ra=server 时强制 ra_default=1，确保始终宣告网关。
# 用法: netmanager v6gw [--quiet]
cmd_v6gw() {
    local quiet=0
    [ "$1" = "--quiet" ] && quiet=1
    local proto wandev cur changed=0
    proto=$(uci -q get network.wan.proto)
    wandev=$(ubus call network.interface.wan status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
    [ -z "$wandev" ] && [ "$proto" = "pppoe" ] && wandev="pppoe-wan"

    # ① 补默认路由（仅 pppoe 点对点；缺失或指向其它设备时纠正）
    if [ "$proto" = "pppoe" ] && [ -n "$wandev" ] && [ -d "/sys/class/net/$wandev" ]; then
        cur=$(ip -6 route show default 2>/dev/null | head -1)
        case "$cur" in
            *"dev $wandev"*) : ;;   # 已正确，无需改动
            *)
                if ip -6 route replace default dev "$wandev" metric 512 2>/dev/null; then
                    changed=1
                    [ $quiet -eq 0 ] && info "已补 IPv6 默认路由: default dev $wandev metric 512"
                    write_log "INFO" "v6gw: 补 IPv6 默认路由 dev $wandev（原: ${cur:-无}）"
                fi
                ;;
        esac
    fi

    # ② 强制宣告网关（LAN 为 RA 服务器模式时）
    if [ "$(uci -q get dhcp.lan.ra)" = "server" ]; then
        if [ "$(uci -q get dhcp.lan.ra_default)" != "1" ]; then
            uci set dhcp.lan.ra_default='1'
            uci commit dhcp
            /etc/init.d/odhcpd reload >/dev/null 2>&1
            changed=1
            [ $quiet -eq 0 ] && info "已设 ra_default=1（强制宣告 IPv6 网关）"
            write_log "INFO" "v6gw: 设 dhcp.lan.ra_default=1"
        fi
    fi

    [ $quiet -eq 0 ] && [ $changed -eq 0 ] && info "IPv6 网关状态正常，无需改动"
    return 0
}

# 清理不属于当前前缀的 IPv6 默认源路由与 unreachable 条目
v6_cleanup_stale_routes() {
    local prefix="$1" quiet="$2" p removed=0
    [ -z "$prefix" ] && return 0
    # 形如: default from 2408:xxxx:xxxx:xxxx::/64 via fe80::... dev pppoe-wan
    ip -6 route show 2>/dev/null | grep '^default from' | while read -r line; do
        p=$(echo "$line" | awk '{print $3}')
        case "$p" in
            ${prefix}*) ;;                       # 当前前缀，保留
            fd*|fc*) ;;                          # ULA，保留
            *)
                ip -6 route del $line 2>/dev/null && removed=$((removed+1))
                ;;
        esac
    done
    # unreachable 兜底路由同样按前缀清理
    ip -6 route show 2>/dev/null | grep '^unreachable' | while read -r line; do
        p=$(echo "$line" | awk '{print $2}')
        case "$p" in
            ${prefix}*) ;;
            fd*|fc*) ;;
            *) ip -6 route del $line 2>/dev/null ;;
        esac
    done
    [ "$quiet" = "0" ] && [ $removed -gt 0 ] && info "清理旧前缀残留路由 $removed 条"
    return 0
}

# v1.8.3：清理 odhcpd 的 RFC9096 前缀记忆(piofolder)中的失效前缀。
# odhcpd 把历史前缀记在 piofolder，并在每次 RA 里以 lifetime=0 持续广播
# （实测旧前缀失效两小时后仍在播）。客户端按 RFC4862 会保留这些 deprecated
# 地址直到记忆过期 —— 这是客户端"堆一堆旧 IP"的路由端根因。
# 只剔除既非当前前缀、也非 ULA 的 slaac 条目；重写后重启 odhcpd 生效，
# RA 随即只含当前前缀 + ULA。
v6_cleanup_piofolder() {
    local prefix="$1" quiet="$2" folder pf new changed=0
    [ -z "$prefix" ] && return 0
    folder=$(uci -q get dhcp.odhcpd.piofolder)
    [ -z "$folder" ] && folder="/tmp/odhcpd-piofolder"
    [ -d "$folder" ] || return 0
    for pf in "$folder"/*; do
        [ -f "$pf" ] || continue
        new=$(awk -v P="$prefix" '
            {
                line=$0; out=""
                n=split(line, parts, "},")
                for (i=1; i<=n; i++) {
                    seg=parts[i]
                    if (seg ~ /"prefix"/) {
                        p=seg
                        sub(/.*"prefix"[ ]*:[ ]*"/, "", p)
                        sub(/".*/, "", p)
                        keep=0
                        if (index(p, P)==1) keep=1
                        if (p ~ /^fd/ || p ~ /^fc/) keep=1
                        if (!keep) continue
                    }
                    out = out seg (i<n ? "}," : "")
                }
                print out
            }' "$pf" 2>/dev/null)
        if [ -n "$new" ] && [ "$new" != "$(cat "$pf" 2>/dev/null)" ]; then
            printf '%s' "$new" > "$pf"
            changed=1
        fi
    done
    if [ $changed -eq 1 ]; then
        /etc/init.d/odhcpd stop >/dev/null 2>&1
        sleep 1
        killall odhcpd 2>/dev/null
        sleep 1
        /etc/init.d/odhcpd start >/dev/null 2>&1
        [ "$quiet" = "0" ] && info "已清理 piofolder 失效前缀记忆并重启 odhcpd"
        write_log "INFO" "v6_cleanup_piofolder: 剔除失效前缀记忆，前缀=${prefix}"
    fi
    return 0
}

# ========== 5. 防火墙规则列表 ==========
cmd_rule_list() {
    echo "===FIREWALL_RULE_LIST==="
    idx=0
    while true; do
        name=$(uci get firewall.@rule[$idx].name 2>/dev/null)
        uci -q get "firewall.@rule[$idx]" >/dev/null 2>&1 || break
        src=$(uci get firewall.@rule[$idx].src 2>/dev/null)
        dst=$(uci get firewall.@rule[$idx].dest 2>/dev/null)
        proto=$(uci get firewall.@rule[$idx].proto 2>/dev/null)
        dp=$(uci get firewall.@rule[$idx].dest_port 2>/dev/null)
        target=$(uci get firewall.@rule[$idx].target 2>/dev/null)
        fam=$(uci get firewall.@rule[$idx].family 2>/dev/null)
        enabled=$(uci get firewall.@rule[$idx].enabled 2>/dev/null)
        sip=$(uci get firewall.@rule[$idx].src_ip 2>/dev/null)
        dip=$(uci get firewall.@rule[$idx].dest_ip 2>/dev/null)
        [ -z "$enabled" ] && enabled="1"
        [ -z "$fam" ] && fam="any"
        # 【v1.4.6 P1】输出侧兜底：UCI 直接编辑塞入管道符的历史数据替换为全角，防列表错位
        name=$(echo "$name" | tr '|' '｜')
        # v1.8.13：末尾追加 src_ip/dest_ip（旧版前端按前 9 字段解析，向后兼容）
        echo "$idx|$name|$src|$dst|$proto|$dp|$target|$fam|$enabled|$sip|$dip"
        idx=$((idx+1))
    done
    echo "===END==="
}

# ========== 6. 添加防火墙规则 ==========
# 【v1.4.6 P1】name 管道符过滤：列表输出以 | 分隔，name 含 | 会错位导致前端解析混乱
rule_name_check() {
    case "$1" in
        *\|*|*'('*')'*)
            error "规则名称不允许包含 | ( ) 字符（与列表输出格式冲突）"; return 1 ;;
    esac
    return 0
}

cmd_rule_add() {
    name="$1"; src="$2"; dst="$3"; proto="$4"; port="$5"; target="$6"; fam="${7:-any}"
    write_log "INFO" "rule_add: 请求添加 名称=$name 源=$src 目标=$dst 协议=$proto 端口=$port 动作=$target IP版本=$fam"
    [ -z "$name" ] && { error "用法: netmanager rule_add <名称> <源zone> <目标zone> <协议> <端口> <ACCEPT|DROP|REJECT> [ipv4|ipv6|any]"; exit 1; }
    rule_name_check "$name" || exit 1
    # 健壮性：检测参数错位。如果 $6 不是合法动作而是 any/ipv4/ipv6，说明 dst 为空被吞了
    case "$target" in
        any|ipv4|ipv6)
            # 参数错位：$3=proto $4=port $5=target $6=fam，dst 为空
            fam="$target"
            target="$port"
            port="$proto"
            proto="$dst"
            dst=""
            ;;
    esac
    [ -z "$proto" ] && proto="tcp"
    [ -z "$target" ] && target="ACCEPT"
    # 端口格式标准化：冒号转横线
    port=$(echo "$port" | sed 's/:/-/g')
    # 关键：@rule[-1] 只能引用已存在节点，必须先 add 才能落到新节点
    # （否则所有 set 会覆盖最后一条既有规则）
    uci add firewall rule > /dev/null
    uci set firewall.@rule[-1].name="$name"
    [ -n "$src" ] && uci set firewall.@rule[-1].src="$src"
    [ -n "$dst" ] && uci set firewall.@rule[-1].dest="$dst"
    uci set firewall.@rule[-1].proto="$proto"
    [ -n "$port" ] && uci set firewall.@rule[-1].dest_port="$port"
    uci set firewall.@rule[-1].target="$target"
    [ "$fam" != "any" ] && uci set firewall.@rule[-1].family="$fam"

    uci commit firewall
    rm -f /tmp/.uci/firewall 2>/dev/null
    /etc/init.d/firewall reload > /dev/null 2>&1
    info "规则已添加: $name ($target)"
}

# ========== 7. 编辑防火墙规则 ==========
cmd_rule_edit() {
    idx="$1"; name="$2"; src="$3"; dst="$4"; proto="$5"; port="$6"; target="$7"; fam="${8:-any}"
    write_log "INFO" "rule_edit: 请求编辑 索引=$idx 名称=$name 源=$src 目标=$dst 协议=$proto 端口=$port 动作=$target IP版本=$fam"
    [ -z "$idx" ] && { error "用法: netmanager rule_edit <索引> <名称> <源> <目标> <协议> <端口> <动作> [IP版本]"; exit 1; }
    old_name=$(uci get firewall.@rule[$idx].name 2>/dev/null)
    [ -z "$old_name" ] && { error "规则索引 $idx 不存在"; exit 1; }
    # 【v1.4.6 P1】name 管道符校验（同 rule_add）
    [ -n "$name" ] && { rule_name_check "$name" || exit 1; }
    # 端口格式标准化
    port=$(echo "$port" | sed 's/:/-/g')
    # 修改字段（空值保留原值）
    [ -n "$name" ] && uci set firewall.@rule[$idx].name="$name"
    if [ -n "$src" ]; then uci set firewall.@rule[$idx].src="$src"; else uci delete firewall.@rule[$idx].src 2>/dev/null; fi
    if [ -n "$dst" ]; then uci set firewall.@rule[$idx].dest="$dst"; else uci delete firewall.@rule[$idx].dest 2>/dev/null; fi
    [ -n "$proto" ] && uci set firewall.@rule[$idx].proto="$proto"
    if [ -n "$port" ]; then uci set firewall.@rule[$idx].dest_port="$port"; else uci delete firewall.@rule[$idx].dest_port 2>/dev/null; fi
    [ -n "$target" ] && uci set firewall.@rule[$idx].target="$target"
    if [ "$fam" = "any" ] || [ -z "$fam" ]; then
        uci delete firewall.@rule[$idx].family 2>/dev/null
    else
        uci set firewall.@rule[$idx].family="$fam"
    fi
    uci commit firewall
    rm -f /tmp/.uci/firewall 2>/dev/null
    /etc/init.d/firewall reload > /dev/null 2>&1
    info "规则已更新: ${name:-$old_name} ($target)"
}

# ========== 7.5 启用/禁用防火墙规则（v1.8.13 新增）==========
# 供端口转发页「IPv6 端口放行」区的开关使用；enabled=1 以删除选项表示（默认启用）
cmd_rule_toggle() {
    idx="$1"; en="$2"
    [ -z "$idx" ] && { error "用法: netmanager rule_toggle <索引> <1|0>"; exit 1; }
    case "$en" in 0|1) ;; *) error "启用值必须为 1 或 0"; exit 1 ;; esac
    name=$(uci get firewall.@rule[$idx].name 2>/dev/null)
    [ -z "$name" ] && { error "规则索引 $idx 不存在"; exit 1; }
    if [ "$en" = "1" ]; then
        uci delete firewall.@rule[$idx].enabled 2>/dev/null
    else
        uci set firewall.@rule[$idx].enabled='0'
    fi
    uci commit firewall
    rm -f /tmp/.uci/firewall 2>/dev/null
    /etc/init.d/firewall reload > /dev/null 2>&1
    if [ "$en" = "1" ]; then info "规则已启用: $name"; else info "规则已禁用: $name"; fi
}

# ========== 8. 删除防火墙规则 ==========
cmd_rule_del() {
    idx="$1"
    write_log "INFO" "rule_del: 请求删除 索引=$idx"
    [ -z "$idx" ] && { error "用法: netmanager rule_del <规则索引>"; exit 1; }
    name=$(uci get firewall.@rule[$idx].name 2>/dev/null)
    if [ -n "$name" ]; then
        uci delete firewall.@rule[$idx]
        uci commit firewall
        rm -f /tmp/.uci/firewall 2>/dev/null
        /etc/init.d/firewall reload > /dev/null 2>&1
        info "已删除规则: $name"
    else
        error "规则索引 $idx 不存在"
    fi
}

# ========== 8. SSH登录日志（适配dropbear + BusyBox） ==========
cmd_ssh_log() {
    limit="${1:-50}"
    echo "===SSH_LOG==="

    # dropbear日志格式示例:
    # Mon Aug 25 19:12:34 2026 authpriv.info dropbear[12345]: Password auth succeeded for 'root' from 192.168.31.100:52341
    # Mon Aug 25 19:13:00 2026 authpriv.warn dropbear[12346]: Bad password attempt for 'root' from 192.168.31.100:52342
    # Mon Aug 25 19:13:10 2026 authpriv.info dropbear[12347]: Exit before auth from <192.168.31.100:52343>

    # 成功登录
    echo "---SUCCESS---"
    logread 2>/dev/null | grep -i "dropbear" | grep -i "succeeded\|session opened" | tail -$limit | while read -r line; do
        # 时间：兼容 "Mon Aug 25 19:12:34 2026" 和 "Mon Aug 25 19:12:34" 两种格式
        log_time=$(echo "$line" | sed -n 's/^\([A-Z][a-z][a-z] [A-Z][a-z][a-z] [0-9]* [0-9:]*\).*/\1/p')
        [ -z "$log_time" ] && log_time=$(echo "$line" | awk '{print $1" "$2" "$3" "$4}')
        # 用户名: for 'root' -> 提取引号内
        user=$(echo "$line" | sed -n "s/.*for '\([^']*\)'.*/\1/p")
        [ -z "$user" ] && user="root"
        # IP: from 192.168.31.100:52341 -> 提取from后面的IP
        ip=$(echo "$line" | sed -n 's/.*from \([0-9.]*\):.*/\1/p')
        [ -z "$ip" ] && ip=$(echo "$line" | sed -n 's/.*from <\([0-9.]*\):.*/\1/p')
        [ -z "$ip" ] && ip="unknown"
        echo "$log_time|$user|$ip|success"
    done

    # 失败登录
    echo "---FAILED---"
    logread 2>/dev/null | grep -i "dropbear" | grep -i "bad password\|invalid user\|exit before auth\|auth fail" | tail -$limit | while read -r line; do
        log_time=$(echo "$line" | sed -n 's/^\([A-Z][a-z][a-z] [A-Z][a-z][a-z] [0-9]* [0-9:]*\).*/\1/p')
        [ -z "$log_time" ] && log_time=$(echo "$line" | awk '{print $1" "$2" "$3" "$4}')
        user=$(echo "$line" | sed -n "s/.*for '\([^']*\)'.*/\1/p")
        [ -z "$user" ] && user="unknown"
        ip=$(echo "$line" | sed -n 's/.*from \([0-9.]*\):.*/\1/p')
        [ -z "$ip" ] && ip=$(echo "$line" | sed -n 's/.*from <\([0-9.]*\):.*/\1/p')
        [ -z "$ip" ] && ip="unknown"
        if echo "$line" | grep -qi "bad password"; then
            reason="密码错误"
        elif echo "$line" | grep -qi "invalid user"; then
            reason="无效用户"
        elif echo "$line" | grep -qi "exit before auth"; then
            reason="未认证断开"
        else
            reason="认证失败"
        fi
        echo "$log_time|$user|$ip|$reason"
    done

    # 失败IP统计
    echo "---STATS---"
    logread 2>/dev/null | grep -i "dropbear" | grep -i "bad password\|invalid user\|exit before auth" | sed -n 's/.*from \([0-9.]*\):.*/\1/p' | sort | uniq -c | sort -rn | head -10 | while read -r count ip; do
        echo "$ip|$count"
    done

    echo "===END==="
}

# ========== 9. 端口访问日志 ==========
cmd_access_log() {
    port_filter="$1"
    limit="${2:-100}"
    load_config
    write_log "DEBUG" "access_log: 开始获取, 端口过滤=$port_filter 限制=$limit"
    echo "===ACCESS_LOG==="

    # 当前活跃连接（用awk提取第一个src/dst=原始方向，支持IPv4和IPv6）
    echo "---ACTIVE---"
    active_count=0
    if [ -f /proc/net/nf_conntrack ]; then
        cat /proc/net/nf_conntrack 2>/dev/null | grep "ESTABLISHED" | while read -r line; do
            proto=$(echo "$line" | awk '{print $3}')
            src=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^src=/) {print substr($i,5); exit}}')
            dst=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^dst=/) {print substr($i,5); exit}}')
            sport=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^sport=/) {print substr($i,7); exit}}')
            dport=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^dport=/) {print substr($i,7); exit}}')
            [ -z "$src" ] && src="?"
            [ -z "$dst" ] && dst="?"
            [ -z "$sport" ] && sport="?"
            [ -z "$dport" ] && dport="?"
            if [ -n "$port_filter" ] && [ "$dport" != "$port_filter" ] && [ "$sport" != "$port_filter" ]; then
                continue
            fi
            echo "$proto|$src:$sport|$dst:$dport|已建立"
        done | head -$limit
        active_count=$(cat /proc/net/nf_conntrack 2>/dev/null | grep -c "ESTABLISHED" || echo 0)
    fi
    echo "ACTIVE_COUNT=$active_count"

    # 入站连接统计（原始方向第一个dst是内网前缀 = 外部主动访问内网）
    in_count=0
    if [ -f /proc/net/nf_conntrack ]; then
        lan_prefix=$(uci get network.lan.ipaddr 2>/dev/null | cut -d. -f1-3)
        in_count=$(cat /proc/net/nf_conntrack 2>/dev/null | grep "ESTABLISHED" | awk -v lp="$lan_prefix" '{for(i=1;i<=NF;i++) if($i ~ /^dst=/) {if(index(substr($i,5),lp)==1) c++; break}} END{print c+0}')
    fi
    echo "IN_COUNT=$in_count"

    # 出站连接统计
    out_count=$((active_count - in_count))
    [ $out_count -lt 0 ] && out_count=0
    echo "OUT_COUNT=$out_count"

    # 防火墙拦截统计（v1.8.4 重写）
    # 旧版用 prev_pkts/prev_dport/prev_proto 跨行借用上下文，会把前面 accept 规则
    # （如 Allow-DHCP-Renew 的 udp dport 68）的端口/协议/计数错误套到后面无端口的
    # drop 规则（china/ban IP 段拦截）上，导致「端口68拦截几万」这类明显错误。
    # 新版逐行独立解析：计数器/端口/协议只取本行，绝不跨行借用；无端口规则按用途标注。
    echo "---BLOCKED---"
    block_total=0
    block_output=""

    nft_output=$(nft list ruleset 2>/dev/null)

    if [ -n "$nft_output" ]; then
        block_output=$(echo "$nft_output" | awk '
        function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); return s }
        {
            line=$0
            # 跳过 chain 定义与 policy 行（fw4 的 policy drop 不挂计数器，非规则）
            if (line ~ /policy[ \t]+(drop|accept)/) next
            if (line ~ /^[ \t]*chain[ \t]/) next
            # 只认本行裁决为 drop/reject 的规则（独立词，排除 drop_from_wan 等链名）
            is_drop=0
            if (line ~ /[ \t]drop([ \t;]|$)/) is_drop=1
            else if (line ~ /[ \t]reject([ \t;]|$)/) is_drop=1
            if (!is_drop) next

            # 本行内联计数器；没有则计0，不借用上一行
            pkts=0
            if (match(line, /counter packets [0-9]+/)) {
                t=substr(line,RSTART,RLENGTH); gsub(/[^0-9]/,"",t); pkts=t+0
            }

            # 本行协议：多协议集合 {tcp,udp} / 单协议 / icmp
            proto="any"
            if (line ~ /l4proto[ \t]*\{[^}]*tcp[^}]*udp[^}]*\}/ || line ~ /l4proto[ \t]*\{[^}]*udp[^}]*tcp[^}]*\}/) proto="tcp/udp"
            else if (line ~ /l4proto[ \t]+tcp/ || line ~ /[ \t]tcp[ \t]+dport/) proto="tcp"
            else if (line ~ /l4proto[ \t]+udp/ || line ~ /[ \t]udp[ \t]+dport/) proto="udp"
            else if (line ~ /icmpv6/) proto="icmpv6"
            else if (line ~ /[ \t]icmp[ \t]/) proto="icmp"

            # 本行端口（单值/范围/集合）；无端口则按用途标注
            label=""
            if (match(line, /dport[ \t]+[0-9]+(-[0-9]+)?/)) {
                t=substr(line,RSTART,RLENGTH); gsub(/dport[ \t]+/,"",t); label=t
            } else if (match(line, /dport[ \t]*\{[^}]*\}/)) {
                t=substr(line,RSTART,RLENGTH); gsub(/dport[ \t]*/,"",t); gsub(/[{} \t]/,"",t); label=t
            }
            if (label=="") {
                if (line ~ /@china_v4/) label="境外IP拦截(v4)"
                else if (line ~ /@china_v6/) label="境外IP拦截(v6)"
                else if (line ~ /@ban_v4/) label="黑名单拦截(v4)"
                else if (line ~ /@ban_v6/) label="黑名单拦截(v6)"
                else if (line ~ /iifname.*wan/ || line ~ /oifname.*wan/) label="WAN口丢弃"
                else if (line ~ /ct state invalid/) label="无效连接丢弃"
                else if (line ~ /echo-request/) label="Ping丢弃"
                else if (line ~ /reject/) label="拒绝连接"
                else label="其他丢弃"
            }

            if (pkts>0) {
                key=proto "|" label
                m[key]+=pkts
            }
        }
        END {
            for (k in m) printf "%s|%d|拦截\n", k, m[k]
        }')

        # 排序并计算总数
        if [ -n "$block_output" ]; then
            block_output=$(echo "$block_output" | sort -t'|' -k3,3 -rn)
            block_total=$(echo "$block_output" | awk -F'|' '{sum+=$3} END{print sum+0}')
        fi
    fi

    # 输出结果
    if [ -n "$block_output" ]; then
        echo "$block_output"
    fi
    echo "BLOCK_TOTAL=${block_total:-0}"

    echo "===END==="
    write_log "DEBUG" "access_log: 完成, BLOCK_TOTAL=${block_total:-0}"
}

# ========== 9.4 拦截明细（v1.8.5） ==========
# 点击「防火墙拦截统计(按端口)」某行时调用，返回被拦截的源IP明细，便于拉黑。
# 数据源：china_input/china6_input 的限速日志（NM_DROP4/NM_DROP6 前缀，10/分钟）。
# 参数 key：纯端口号(按DPT过滤) / 含v4|v6(按族过滤) / 空或all(全部已记录源IP)。
cmd_block_detail() {
    local key="$1"
    load_config
    echo "===BLOCK_DETAIL==="
    echo "KEY=${key}"
    local raw
    raw=$(logread 2>/dev/null | grep -E 'NM_DROP[46]:' | tail -n 3000)
    if [ -z "$raw" ]; then
        echo "NO_LOG=1"
        echo "===END==="
        return 0
    fi
    echo "$raw" | awk -v key="$key" '
    {
        line=$0
        fam=""
        if (line ~ /NM_DROP4:/) fam="v4"
        else if (line ~ /NM_DROP6:/) fam="v6"
        else next
        if (key ~ /v4/ && fam!="v4") next
        if (key ~ /v6/ && fam!="v6") next
        src=""; dpt=""; proto=""
        if (match(line, /SRC=[^ ]+/)) src=substr(line,RSTART+4,RLENGTH-4)
        if (match(line, /DPT=[0-9]+/)) dpt=substr(line,RSTART+4,RLENGTH-4)
        if (match(line, /PROTO=[A-Za-z0-9]+/)) proto=substr(line,RSTART+6,RLENGTH-6)
        if (src=="") next
        if (key ~ /^[0-9]+(-[0-9]+)?$/ && dpt!=key) next
        cnt[src]++
        if (dpt!="" && index(","ports[src]",", ","dpt",")==0)
            ports[src]=ports[src] (ports[src]==""?"":",") dpt
        if (proto!="") pr[src]=proto
        ts=line; sub(/kernel:.*/,"",ts); gsub(/^[ \t]+|[ \t]+$/,"",ts)
        last[src]=ts
    }
    END {
        n=0
        for (s in cnt) { printf "%s|%s|%s|%d|%s\n", s, pr[s], ports[s], cnt[s], last[s]; n++ }
        if (n==0) print "NO_MATCH=1"
    }' | sort -t'|' -k4,4 -rn | head -100
    echo "===END==="
}

# ========== 9.5 静态IP一键绑定（v1.8.4） ==========
# 从在线客户端速览直接绑定：创建 dhcp host（MAC + 当前IPv4 + 主机名 + DUID）。
# 与「静态IP分配」页设备列表共用同一套 dhcp.host 配置，绑定后页面可见可编辑。
nm_valid_mac() {
    case "$1" in
        [0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) return 0 ;;
        *) return 1 ;;
    esac
}
cmd_static_bind() {
    local mac="$1" ip="$2" name="$3" duid="$4"
    load_config
    # MAC 必填且格式合法
    if [ -z "$mac" ] || ! nm_valid_mac "$mac"; then
        error "MAC 地址格式无效（应为 AA:BB:CC:DD:EE:FF）"
        return 1
    fi
    mac=$(echo "$mac" | tr 'a-f' 'A-F')
    # 去重：同 MAC 已绑定则拒绝
    local exist
    exist=$(uci show dhcp 2>/dev/null | grep "=host" | cut -d. -f2 | cut -d= -f1 | while read -r s; do
        [ "$(uci -q get dhcp.$s.mac | tr 'a-f' 'A-F')" = "$mac" ] && echo "$s"
    done | head -n1)
    if [ -n "$exist" ]; then
        error "该 MAC 已绑定（条目 $exist），请在设备列表中编辑"
        return 1
    fi
    # IPv4 校验（可选）：格式 + 不等于路由器LAN IP + 落在LAN网段
    if [ -n "$ip" ] && [ "$ip" != "*" ]; then
        if ! echo "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
            error "IPv4 地址格式无效：$ip"
            return 1
        fi
        local lanip lanprefix ipprefix
        lanip=$(uci -q get network.lan.ipaddr)
        if [ -n "$lanip" ]; then
            [ "$ip" = "$lanip" ] && { error "该 IPv4 是路由器自身地址，不可绑定"; return 1; }
            lanprefix=$(echo "$lanip" | cut -d. -f1-3)
            ipprefix=$(echo "$ip" | cut -d. -f1-3)
            if [ "$lanprefix" != "$ipprefix" ]; then
                error "IPv4 $ip 不在 LAN 网段 ${lanprefix}.0/24 内"
                return 1
            fi
        fi
    else
        ip=""
    fi
    # 主机名清洗（仅允许字母数字下划线连字符）
    if [ -n "$name" ] && [ "$name" != "*" ]; then
        name=$(echo "$name" | tr -cd 'A-Za-z0-9_-' | cut -c1-32)
    else
        name=""
    fi
    # DUID 去冒号
    if [ -n "$duid" ]; then
        duid=$(echo "$duid" | tr -d ':' | tr 'A-F' 'a-f')
        echo "$duid" | grep -Eq '^[0-9a-f]+$' || duid=""
    fi
    local sec
    sec=$(uci add dhcp host)
    uci set dhcp.$sec.mac="$mac"
    [ -n "$ip" ] && uci set dhcp.$sec.ip="$ip"
    [ -n "$name" ] && uci set dhcp.$sec.name="$name"
    [ -n "$duid" ] && uci set dhcp.$sec.duid="$duid"
    uci set dhcp.$sec.enabled='1'
    uci commit dhcp
    /etc/init.d/dnsmasq reload >/dev/null 2>&1
    info "已绑定 $mac ${ip:+→ $ip }${name:+($name)}，条目 $sec"
    write_log "INFO" "static_bind: mac=$mac ip=$ip name=$name sec=$sec"
    return 0
}

# ========== 9.6 静态IP解绑（v1.8.5） ==========
# 按 MAC 删除 dhcp host 静态绑定（在线客户端速览「解绑」按钮调用）。
# 同 MAC 可能有多条（历史重复），全部删除；按下标降序删避免移位误删。
cmd_static_unbind() {
    local mac="$1"
    load_config
    if [ -z "$mac" ] || ! nm_valid_mac "$mac"; then
        error "MAC 地址格式无效（应为 AA:BB:CC:DD:EE:FF）"
        return 1
    fi
    mac=$(echo "$mac" | tr 'a-f' 'A-F')
    local idx=0 hits=""
    while uci -q get "dhcp.@host[$idx]" >/dev/null 2>&1; do
        if [ "$(uci -q get dhcp.@host[$idx].mac | tr 'a-f' 'A-F')" = "$mac" ]; then
            hits="$idx $hits"
        fi
        idx=$((idx+1))
    done
    if [ -z "$hits" ]; then
        error "未找到 MAC $mac 的绑定条目"
        return 1
    fi
    local n=0 i
    for i in $hits; do
        uci delete "dhcp.@host[$i]"
        n=$((n+1))
    done
    uci commit dhcp
    /etc/init.d/dnsmasq reload >/dev/null 2>&1
    info "已解绑 $mac（删除 $n 条绑定），DHCP 已重载"
    write_log "INFO" "static_unbind: mac=$mac removed=$n"
    return 0
}

# ========== 10. 防火墙操作 ==========
cmd_restart() {
    write_log "INFO" "firewall_restart: 用户请求重启防火墙"
    /etc/init.d/firewall restart 2>&1
    info "防火墙已重启"
}
cmd_reload() {
    write_log "INFO" "firewall_reload: 用户请求重载防火墙"
    /etc/init.d/firewall reload 2>&1
    info "防火墙已重载"
}
cmd_backup() {
    write_log "INFO" "backup: 用户请求创建全配置备份"
    # v1.5.0 增强：全配置备份（firewall/network/dhcp/dnssettings/netmanager），统一目录 /root/backup
    local backup_dir="/root/backup"
    mkdir -p "$backup_dir" 2>/dev/null
    local ts=$(date +%Y%m%d-%H%M%S)
    local backup_file="$backup_dir/netmanager-full-${ts}.tar.gz"
    local work_dir="/tmp/netmanager_backup_$$"
    mkdir -p "$work_dir" 2>/dev/null

    # 收集存在的配置文件
    local configs="firewall network dhcp dnssettings netmanager"
    local copied=0
    for cfg in $configs; do
        if [ -f "/etc/config/$cfg" ]; then
            cp "/etc/config/$cfg" "$work_dir/$cfg" 2>/dev/null && copied=$((copied+1))
        fi
    done

    # v1.8.14：整插件备份——/etc/netmanager 状态文件（手动黑名单 + 中国IPv4/IPv6白名单列表）
    # 随包携带，跨机恢复/离线恢复后白名单与黑名单无需重新下载即可生效
    # 子目录名用 state：work_dir/netmanager 已被同名 UCI 配置文件占用（文件），不能同名建目录
    local state_dir="$work_dir/state"
    local state_copied=0
    mkdir -p "$state_dir" 2>/dev/null
    for sf in blacklist_v4.list blacklist_v6.list china_v4.list china_v6.list; do
        if [ -f "$CHINA_LIST_DIR/$sf" ]; then
            cp "$CHINA_LIST_DIR/$sf" "$state_dir/$sf" 2>/dev/null && state_copied=$((state_copied+1))
        fi
    done

    # 写入元信息
    cat > "$work_dir/MANIFEST.txt" <<EOF
BACKUP_TIME=$(date '+%Y-%m-%d %H:%M:%S')
BACKUP_VERSION=v$PLUGIN_VERSION
CONFIG_FILES=$(ls "$work_dir" 2>/dev/null | grep -v MANIFEST | grep -v '^state$' | tr '\n' ' ')
CONFIG_COUNT=$copied
STATE_FILES=$(ls "$state_dir" 2>/dev/null | tr '\n' ' ')
STATE_COUNT=$state_copied
HOSTNAME=$(cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown)
EOF

    # 打包
    tar czf "$backup_file" -C "$work_dir" . 2>/dev/null
    local rc=$?
    rm -rf "$work_dir" 2>/dev/null

    if [ $rc -ne 0 ] || [ ! -s "$backup_file" ]; then
        error "备份失败（tar 打包错误）"
        rm -f "$backup_file" 2>/dev/null
        return 1
    fi

    local size=$(wc -c < "$backup_file" 2>/dev/null || echo 0)
    info "已创建整插件备份: $backup_file (${size}字节, ${copied}个配置文件 + ${state_copied}个列表文件)"
    echo "$backup_file"

    # v1.5.0 自动保留策略：超过 20 个自动清理最旧的
    local count=$(ls -1 "$backup_dir"/netmanager-full-*.tar.gz 2>/dev/null | wc -l)
    if [ "${count:-0}" -gt 20 ]; then
        local to_remove=$((count - 20))
        ls -1t "$backup_dir"/netmanager-full-*.tar.gz 2>/dev/null | tail -n "$to_remove" | xargs rm -f 2>/dev/null
        info "自动清理旧备份: 保留最近20个，已删除${to_remove}个"
    fi
}

# ========== 备份恢复 ==========
cmd_backup_list() {
    echo "===BACKUP_LIST==="
    echo "---BACKUPS---"
    local backup_dir="/root/backup"
    local count=0

    # v1.5.0 同时列出新格式（/root/backup/netmanager-full-*.tar.gz）和旧格式（/root/firewall-*.bak）
    if [ -d "$backup_dir" ]; then
        for f in "$backup_dir"/netmanager-full-*.tar.gz; do
            [ -f "$f" ] || continue
            local fname=$(basename "$f")
            local size=$(wc -c < "$f" 2>/dev/null || echo 0)
            local mtime=$(date -r "$f" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)
            # 从 MANIFEST 读取配置数量（tar -C . 打包成员带 ./ 前缀，两种名字都试）
            local mf=$(tar xzf "$f" -O ./MANIFEST.txt 2>/dev/null)
            [ -z "$mf" ] && mf=$(tar xzf "$f" -O MANIFEST.txt 2>/dev/null)
            local cfg_count=$(echo "$mf" | grep '^CONFIG_COUNT=' | cut -d= -f2)
            [ -z "$cfg_count" ] && cfg_count="?"
            # v1.8.14：列表文件数（旧备份无 STATE_COUNT 记 0）
            local state_count=$(echo "$mf" | grep '^STATE_COUNT=' | cut -d= -f2)
            [ -z "$state_count" ] && state_count="0"
            echo "${fname}|${size}|${mtime}|full|${cfg_count}|${state_count}"
            count=$((count+1))
        done
    fi

    # 兼容旧格式（/root/firewall-*.bak）
    for f in /root/firewall-*.bak; do
        [ -f "$f" ] || continue
        local fname=$(basename "$f")
        local size=$(wc -c < "$f" 2>/dev/null || echo 0)
        local mtime=$(date -r "$f" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)
        echo "${fname}|${size}|${mtime}|legacy|1"
        count=$((count+1))
    done

    echo "BACKUP_COUNT=$count"
    echo "BACKUP_DIR=$backup_dir"
    echo "===END==="
}

cmd_backup_restore() {
    backup_name="$1"
    write_log "INFO" "backup_restore: 用户请求恢复备份 $backup_name"
    [ -z "$backup_name" ] && { error "用法: netmanager backup_restore <备份文件名>"; exit 1; }

    # v1.5.0 支持两种格式：新格式 tar.gz（/root/backup/）和旧格式 .bak（/root/）
    local backup_file=""
    local backup_type=""

    if [ -f "/root/backup/$backup_name" ]; then
        backup_file="/root/backup/$backup_name"
        backup_type="full"
    elif [ -f "/root/$backup_name" ]; then
        backup_file="/root/$backup_name"
        backup_type="legacy"
    else
        error "备份文件不存在: $backup_name"
        exit 1
    fi

    # 安全检查：文件名白名单
    case "$backup_name" in
        netmanager-full-*.tar.gz|firewall-*.bak) ;;
        *) error "非法的备份文件名"; exit 1 ;;
    esac

    # 恢复前自动备份当前配置（全配置）
    local pre_backup
    pre_backup=$(cmd_backup 2>/dev/null | tail -1)
    info "恢复前已自动备份当前配置: $pre_backup"

    if [ "$backup_type" = "full" ]; then
        # v1.5.0 全配置恢复：解压 tar.gz，逐个恢复配置文件
        local work_dir="/tmp/netmanager_restore_$$"
        mkdir -p "$work_dir" 2>/dev/null
        # v1.8.14 安全加固：解压前成员路径预检，拒绝 ../ 与绝对路径成员（防写穿工作目录）
        if tar tzf "$backup_file" 2>/dev/null | grep -Eq '(^|/)\.\./|^/'; then
            error "备份包含非法路径成员（../ 或绝对路径），已拒绝恢复"
            rm -rf "$work_dir" 2>/dev/null
            exit 1
        fi
        tar xzf "$backup_file" -C "$work_dir" 2>/dev/null
        if [ $? -ne 0 ]; then
            error "备份文件解压失败（可能已损坏）"
            rm -rf "$work_dir" 2>/dev/null
            exit 1
        fi

        local restored=0
        for cfg in firewall network dhcp dnssettings netmanager; do
            if [ -f "$work_dir/$cfg" ]; then
                cp "$work_dir/$cfg" "/etc/config/$cfg" 2>/dev/null && restored=$((restored+1))
            fi
        done
        # v1.8.14：恢复 /etc/netmanager 状态文件（黑名单/白名单列表）；旧备份无此目录则保留现状
        local state_restored=0
        if [ -d "$work_dir/state" ]; then
            mkdir -p "$CHINA_LIST_DIR" 2>/dev/null
            for sf in blacklist_v4.list blacklist_v6.list china_v4.list china_v6.list; do
                if [ -f "$work_dir/state/$sf" ]; then
                    cp "$work_dir/state/$sf" "$CHINA_LIST_DIR/$sf" 2>/dev/null && state_restored=$((state_restored+1))
                fi
            done
        fi
        rm -rf "$work_dir" 2>/dev/null

        # 提交所有配置
        uci commit firewall 2>/dev/null
        uci commit network 2>/dev/null
        uci commit dhcp 2>/dev/null
        uci commit dnssettings 2>/dev/null
        uci commit netmanager 2>/dev/null
        rm -f /tmp/.uci/firewall /tmp/.uci/network /tmp/.uci/dhcp /tmp/.uci/dnssettings /tmp/.uci/netmanager 2>/dev/null

        # 重载相关服务
        /etc/init.d/firewall reload > /dev/null 2>&1
        /etc/init.d/dnsmasq reload > /dev/null 2>&1
        /etc/init.d/odhcpd restart > /dev/null 2>&1

        # v1.8.14：按恢复后的配置重应用黑名单/白名单规则并重建 cron（跨机恢复后无需手动再保存）
        if [ -s "$BAN_V4_FILE" ] || [ -s "$BAN_V6_FILE" ]; then
            ban_apply_all > /dev/null 2>&1
        fi
        # v1.8.17：恢复备份后同样重建白名单表
        if [ -s "$WL_V4_FILE" ] || [ -s "$WL_V6_FILE" ]; then
            wl_apply_all > /dev/null 2>&1
        fi
        if [ "$(china_get_enable)" = "1" ] && [ -f "$CHINA_LIST_FILE" ]; then
            china_apply_rules > /dev/null 2>&1
            china_cron_install > /dev/null 2>&1
        fi
        if [ "$(china6_get_enable)" = "1" ] && [ -f "$CHINA6_LIST_FILE" ]; then
            china6_apply_rules > /dev/null 2>&1
            china6_cron_install > /dev/null 2>&1
        fi
        v6sync_cron_ensure

        info "已从整插件备份 $backup_name 恢复 ${restored} 个配置文件 + ${state_restored} 个列表文件"
    else
        # 旧格式：仅 firewall 配置
        cp "$backup_file" /etc/config/firewall
        uci commit firewall
        rm -f /tmp/.uci/firewall 2>/dev/null
        /etc/init.d/firewall reload > /dev/null 2>&1
        info "已从 $backup_name 恢复 firewall 配置（旧格式）"
    fi

    info "恢复前的配置已备份到: $pre_backup"
}

cmd_backup_delete() {
    backup_name="$1"
    write_log "INFO" "backup_delete: 用户请求删除备份 $backup_name"
    [ -z "$backup_name" ] && { error "用法: netmanager backup_delete <备份文件名>"; exit 1; }

    # v1.5.0 支持两种位置
    local backup_file=""
    if [ -f "/root/backup/$backup_name" ]; then
        backup_file="/root/backup/$backup_name"
    elif [ -f "/root/$backup_name" ]; then
        backup_file="/root/$backup_name"
    else
        error "备份文件不存在: $backup_name"
        exit 1
    fi

    # 安全检查
    case "$backup_name" in
        netmanager-full-*.tar.gz|firewall-*.bak) ;;
        *) error "非法的备份文件名"; exit 1 ;;
    esac

    rm -f "$backup_file"
    info "已删除备份: $backup_name"
}

# ========== v1.5.0 新增：备份导入（从上传的 tar.gz 导入到备份目录） ==========
cmd_backup_import() {
    local filename="$1"
    [ -z "$filename" ] && { error "用法: netmanager backup_import <上传的tar.gz文件名>"; exit 1; }

    local upload_dir="/tmp/netmanager_upload"
    local src_file="$upload_dir/$filename"
    [ ! -f "$src_file" ] && { error "上传的备份文件不存在: $src_file"; exit 1; }

    # 校验是有效的 tar.gz 且包含 MANIFEST.txt 或 firewall 配置
    if ! tar tzf "$src_file" >/dev/null 2>&1; then
        error "文件不是有效的 tar.gz 备份包"
        exit 1
    fi
    local has_manifest=$(tar tzf "$src_file" 2>/dev/null | grep -c 'MANIFEST.txt')
    local has_firewall=$(tar tzf "$src_file" 2>/dev/null | grep -c 'firewall')
    if [ "$has_manifest" -eq 0 ] && [ "$has_firewall" -eq 0 ]; then
        error "备份包中未找到有效配置文件（需要 MANIFEST.txt 或 firewall 配置）"
        exit 1
    fi

    local backup_dir="/root/backup"
    mkdir -p "$backup_dir" 2>/dev/null
    local ts=$(date +%Y%m%d-%H%M%S)
    local dest_file="$backup_dir/netmanager-imported-${ts}.tar.gz"
    cp "$src_file" "$dest_file" 2>/dev/null

    if [ ! -s "$dest_file" ]; then
        error "备份导入失败"
        exit 1
    fi

    local size=$(wc -c < "$dest_file" 2>/dev/null || echo 0)
    info "备份已导入: $dest_file (${size}字节)"
    echo "$dest_file"
}

# ========== v1.5.0 新增：备份清理（按保留数量） ==========
cmd_backup_prune() {
    local keep="${1:-20}"
    local backup_dir="/root/backup"
    [ ! -d "$backup_dir" ] && { info "备份目录不存在，无需清理"; return 0; }

    local count=$(ls -1 "$backup_dir"/netmanager-*.tar.gz 2>/dev/null | wc -l)
    if [ "${count:-0}" -le "$keep" ]; then
        info "当前备份数量 ${count}，未超过保留上限 ${keep}，无需清理"
        return 0
    fi

    local to_remove=$((count - keep))
    local removed=0
    ls -1t "$backup_dir"/netmanager-*.tar.gz 2>/dev/null | tail -n "$to_remove" | while read f; do
        rm -f "$f" 2>/dev/null && removed=$((removed+1))
    done
    info "已清理 ${to_remove} 个旧备份（保留最近 ${keep} 个）"
}

# ========== 文件上传与插件更新 ==========
# 【v1.4.6】上传大小上限（50MB）：/tmp 是 tmpfs，无上限会耗尽内存导致 OOM
MAX_UPLOAD_SIZE=$((50 * 1024 * 1024))

cmd_upload_file() {
    local filename="$1"
    local b64file="$2"
    [ -z "$filename" ] && { error "用法: netmanager upload_file <文件名> <base64文件>"; exit 1; }
    
    # 安全：文件名防路径穿越（filename=../../etc/xxx 可让root写任意路径）
    case "$filename" in
        */*|*\\*|.|..|"") error "非法的文件名（不允许包含路径分隔符）"; exit 1 ;;
    esac
    # 只保留最后一段文件名，防御双保险
    filename=$(basename -- "$filename")
    case "$filename" in
        .|..|"") error "非法的文件名"; exit 1 ;;
    esac
    
    local upload_dir="/tmp/netmanager_upload"
    mkdir -p "$upload_dir"
    
    # 【v1.4.6】大小上限校验（解码前查源文件，base64 膨胀按 2 倍估算）
    if [ -n "$b64file" ] && [ -f "$b64file" ]; then
        local src_size=$(wc -c < "$b64file" 2>/dev/null | tr -d ' ')
        if [ "${src_size:-0}" -gt $((MAX_UPLOAD_SIZE * 2)) ]; then
            rm -f "$b64file" 2>/dev/null
            error "上传内容超过大小上限（${MAX_UPLOAD_SIZE} 字节），已拒绝（防 tmpfs OOM）"
            exit 1
        fi
    fi
    
    local outfile="$upload_dir/$filename"
    
    # 从base64文件解码（避免shell命令行长度限制）
    if [ -n "$b64file" ] && [ -f "$b64file" ]; then
        # BusyBox base64解码：base64 -d 从文件读取
        base64 -d < "$b64file" > "$outfile" 2>/dev/null
        if [ $? -ne 0 ]; then
            # 备选：某些BusyBox版本用 -o 指定输出
            base64 -d -o "$outfile" "$b64file" 2>/dev/null
            if [ $? -ne 0 ]; then
                # 最后备选：直接复制（如果上传的就是原始文件而非base64）
                warn "base64解码失败，尝试按原始文件处理"
                cp "$b64file" "$outfile"
                if [ $? -ne 0 ]; then
                    rm -f "$b64file" 2>/dev/null
                    error "文件保存失败（base64解码且复制均失败）"
                    exit 1
                fi
            fi
        fi
    fi
    
    rm -f "$b64file" 2>/dev/null
    [ -f "$outfile" ] || { error "文件保存失败（未收到有效数据）"; exit 1; }
    # 【v1.4.6】解码产物二次校验 + 权限收紧（600）
    local out_size=$(wc -c < "$outfile" 2>/dev/null | tr -d ' ')
    if [ "${out_size:-0}" -gt "$MAX_UPLOAD_SIZE" ]; then
        rm -f "$outfile" 2>/dev/null
        error "解码后文件超过大小上限（${MAX_UPLOAD_SIZE} 字节），已拒绝（防 tmpfs OOM）"
        exit 1
    fi
    chmod 600 "$outfile" 2>/dev/null
    info "文件已保存: $outfile (${out_size}字节)"
}

cmd_plugin_update() {
    local filename="${1:-}"
    [ -z "$filename" ] && { error "用法: netmanager plugin_update <tar.gz文件名>"; exit 1; }
    load_config
    write_log "INFO" "plugin_update: 开始更新插件, 文件=$filename"
    
    local upload_dir="/tmp/netmanager_upload"
    local package_file="$upload_dir/$filename"
    
    [ ! -f "$package_file" ] && { error "上传的插件包不存在: $package_file"; write_log "ERROR" "plugin_update: 插件包不存在 $package_file"; exit 1; }
    
    # 验证是tar.gz文件
    case "$filename" in
        *.tar.gz|*.tgz) ;;
        *) error "只支持 .tar.gz 格式的插件包"; exit 1 ;;
    esac
    
    # 获取文件大小，写入日志
    local pkg_size=$(wc -c < "$package_file" 2>/dev/null || echo 0)
    write_log "INFO" "plugin_update: 包大小=$pkg_size 字节"
    info "插件包大小: $pkg_size 字节"
    
    # 创建解压工作目录
    local work_dir="/tmp/netmanager_update_$(date +%s)"
    mkdir -p "$work_dir"
    
    # ========== 关键：按用户手动安装的方式 ==========
    # 复制一份到工作目录，避免文件名混乱
    local work_pkg="$work_dir/update.tar.gz"
    cp -f "$package_file" "$work_pkg"
    
    # 安全：tar成员预检（拒绝 ../ 路径穿越与绝对路径成员，防止恶意包覆盖系统文件）
    if ! tar_list_check "$work_pkg" "$work_dir/tar.list"; then
        error "插件包含非法成员（../ 路径穿越或绝对路径），拒绝解压"
        write_log "ERROR" "plugin_update: tar成员预检失败, 非法成员: $(grep -hE '(^|/)\.\.(/|$)|^/' "$work_dir/tar.list" 2>/dev/null | head -5 | tr '\n' ' ')"
        rm -rf "$work_dir"
        exit 1
    fi
    
    info "正在解压插件包 (tar xzvf)..."
    write_log "DEBUG" "plugin_update: 执行 tar xzvf $work_pkg"
    
    # 直接 tar xzvf 解压（-v 打印解压内容方便排查）
    local tar_log="$work_dir/tar.log"
    cd "$work_dir" && tar xzvf "$work_pkg" > "$tar_log" 2>&1
    local tar_rc=$?
    
    # 打印解压输出到前端
    if [ -f "$tar_log" ]; then
        cat "$tar_log"
    fi
    
    if [ $tar_rc -ne 0 ]; then
        # tar xzvf 失败 -> 尝试 BusyBox 兼容方案：gunzip + tar
        info "tar xzvf 失败，尝试 gunzip + tar ..."
        write_log "WARN" "plugin_update: tar xzvf 返回 $tar_rc，尝试 gunzip 方案"
        local ungz="$work_dir/update.tar"
        gunzip -c "$work_pkg" > "$ungz" 2> "$tar_log"
        if [ $? -eq 0 ]; then
            cd "$work_dir" && tar xvf "$ungz" > "$tar_log" 2>&1
            tar_rc=$?
            cat "$tar_log"
        else
            cat "$tar_log"
            tar_rc=99
        fi
    fi
    
    if [ $tar_rc -ne 0 ]; then
        local file_type=$(file "$package_file" 2>/dev/null || echo "unknown")
        error "解压失败 (返回码=$tar_rc, 文件类型=$file_type, 大小=$pkg_size)，请检查插件包"
        write_log "ERROR" "plugin_update: 解压失败 rc=$tar_rc type=$file_type size=$pkg_size"
        rm -rf "$work_dir"
        exit 1
    fi
    
    write_log "DEBUG" "plugin_update: 解压成功, 工作目录=$work_dir"
    info "解压完成，开始安装..."
    
    # 查找 install.sh（可能在根目录，也可能在子目录）
    local install_script=""
    for p in "$work_dir/install.sh" "$work_dir"/*/install.sh; do
        if [ -f "$p" ]; then install_script="$p"; break; fi
    done
    if [ -z "$install_script" ]; then
        install_script=$(find "$work_dir" -name "install.sh" -type f 2>/dev/null | head -1)
    fi
    
    if [ -z "$install_script" ] || [ ! -f "$install_script" ]; then
        error "插件包错误: 未找到 install.sh（请确保是完整安装包）"
        write_log "ERROR" "plugin_update: 未找到 install.sh，解压目录内容: $(ls -R "$work_dir" 2>/dev/null | head -30)"
        rm -rf "$work_dir"
        exit 1
    fi
    
    # ========== 按用户命令执行：chmod +x install.sh && sh install.sh ==========
    # 网页更新模式（默认）：SKIP_UHTTPD_RESTART=1，避免 uhttpd restart 打断当前 HTTP 响应导致 UI 显示 Failed
    info "执行: chmod +x install.sh && SKIP_UHTTPD_RESTART=1 sh install.sh"
    write_log "INFO" "plugin_update: 执行 SKIP_UHTTPD_RESTART=1 sh $install_script"
    chmod +x "$install_script"
    
    local install_log="$work_dir/install.log"
    cd "$(dirname "$install_script")" && SKIP_UHTTPD_RESTART=1 sh install.sh > "$install_log" 2>&1
    local install_rc=$?
    
    # 输出安装日志
    if [ -f "$install_log" ]; then
        cat "$install_log"
    fi
    
    if [ $install_rc -eq 0 ]; then
        info "插件更新完成！请刷新页面 (Ctrl+Shift+R)"
        info "(LuCI 将在 3 秒后自动重启，请勿关闭页面)"
        write_log "INFO" "plugin_update: 更新成功, install_rc=0"
        
        # 关键：先把所有内容刷新到 stdout（HTTP 响应体写完），然后后台延迟 3s 重启 uhttpd
        # 这样浏览器 fetch 能完整收到响应，不会显示 "Failed to fetch"
        sleep 1
        nohup sh -c "sleep 3; /etc/init.d/uhttpd restart >/dev/null 2>&1" >/dev/null 2>&1 &
    else
        error "安装脚本执行失败 (返回码=$install_rc)"
        write_log "ERROR" "plugin_update: 安装失败 install_rc=$install_rc, 日志: $(cat "$install_log" 2>/dev/null | tr '\n' ' ')"
    fi
    
    # 清理临时文件
    rm -rf "$work_dir" 2>/dev/null
    rm -f "$package_file" 2>/dev/null
}

cmd_plugin_version() {
    local plugin_file="$1"
    [ -z "$plugin_file" ] && { error "用法: netmanager plugin_version <tar.gz文件名>"; exit 1; }
    
    local upload_dir="/tmp/netmanager_upload"
    local package_file="$upload_dir/$plugin_file"
    
    [ ! -f "$package_file" ] && { error "插件包不存在: $package_file"; exit 1; }
    
    # 安全：tar成员预检（拒绝 ../ 路径穿越与绝对路径成员）
    if ! tar_list_check "$package_file" "/tmp/.netmanager_pv.list"; then
        error "插件包含非法成员（../ 路径穿越或绝对路径），拒绝解压"
        rm -f /tmp/.netmanager_pv.list
        exit 1
    fi
    rm -f /tmp/.netmanager_pv.list
    
    local extract_dir="/tmp/netmanager_check_$(date +%s)"
    mkdir -p "$extract_dir"
    
    # BusyBox兼容性解压
    local tar_ok=0
    tar xzf "$package_file" -C "$extract_dir" 2>/dev/null && tar_ok=1
    if [ $tar_ok -eq 0 ]; then
        local tar_file="${package_file%.gz}"
        if [ "$tar_file" != "$package_file" ]; then
            gunzip -c "$package_file" > "$tar_file" 2>/dev/null
            if [ $? -eq 0 ]; then
                tar xf "$tar_file" -C "$extract_dir" 2>/dev/null && tar_ok=1
                rm -f "$tar_file"
            fi
        fi
    fi
    if [ $tar_ok -eq 0 ]; then
        echo "ERROR:无法解压插件包"
        rm -rf "$extract_dir"
        exit 1
    fi
    
    # 尝试读取版本信息
    local version="未知版本"
    local readme="$extract_dir/README.md"
    
    if [ -f "$readme" ]; then
        version=$(head -20 "$readme" 2>/dev/null | grep -i "版本" | head -1 | grep -oE '[vV][0-9]+\.[0-9]+\.[0-9]+' | head -1)
        [ -z "$version" ] && version=$(head -20 "$readme" 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fi
    
    echo "===PLUGIN_VERSION==="
    echo "FILE=$plugin_file"
    echo "VERSION=${version:-未知}"
    echo "SIZE=$(wc -c < "$package_file" 2>/dev/null)"
    echo "UPLOAD_TIME=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "===END==="
    
    rm -rf "$extract_dir"
}

cmd_cleanup_uploads() {
    local upload_dir="/tmp/netmanager_upload"
    if [ -d "$upload_dir" ]; then
        rm -rf "$upload_dir"
        info "已清理上传临时文件"
    else
        info "没有需要清理的文件"
    fi
}

# ========== 10.5 在线更新（GitHub Releases） ==========
# 用法:
#   netmanager update_check                 检查最新版本（GitHub API → 302重定向兜底）
#   netmanager update_apply                 下载最新 release 资产并安装（复用 plugin_update 流程）
#   netmanager set_update_mirror <url|''>   设置镜像/加速前缀（空=直连），如 https://gh-proxy.com
#
# 检查策略（两级容错）:
#   1) GitHub API + jsonfilter 解析（可拿到资产 URL/大小）
#   2) 失败则用 /releases/latest 的 302 Location 头解析最新 tag（无需 API，兼容直连受限场景+镜像前缀）
# 版本比较: 语义化 major.minor.patch 数值比较，仅提示升级，不自动降级

# 语义化版本比较: version_gt 1.10.0 1.9.9 → 返回 0(真)
version_gt() {
    local v1="${1#v}" v2="${2#v}"
    local a1 a2 a3 b1 b2 b3
    a1=$(echo "$v1" | cut -d. -f1); a2=$(echo "$v1" | cut -d. -f2); a3=$(echo "$v1" | cut -d. -f3)
    b1=$(echo "$v2" | cut -d. -f1); b2=$(echo "$v2" | cut -d. -f2); b3=$(echo "$v2" | cut -d. -f3)
    a1=${a1:-0}; a2=${a2:-0}; a3=${a3:-0}
    b1=${b1:-0}; b2=${b2:-0}; b3=${b3:-0}
    [ "$a1" -gt "$b1" ] 2>/dev/null && return 0
    [ "$a1" -eq "$b1" ] 2>/dev/null || return 1
    [ "$a2" -gt "$b2" ] 2>/dev/null && return 0
    [ "$a2" -eq "$b2" ] 2>/dev/null || return 1
    [ "$a3" -gt "$b3" ] 2>/dev/null && return 0
    return 1
}

# HTTP GET：兼容 wget / uclient-fetch / curl，输出 body 到 stdout
update_http_get() {
    local url="$1"
    if command -v wget >/dev/null 2>&1; then
        wget -q -T 15 -O - "$url" 2>/dev/null && return 0
    fi
    if command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q -T 15 -O - "$url" 2>/dev/null && return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -sS --max-time 15 "$url" 2>/dev/null && return 0
    fi
    return 1
}

cmd_update_check() {
    load_config
    local mirror=$(uci get netmanager.settings.update_mirror 2>/dev/null | tr -d ' ')
    # 【v1.4.6 P0】UCI 里的镜像也过白名单（防绕过 set 命令直接 uci set 注入恶意镜像）
    if ! mirror_check "$mirror"; then
        echo "===UPDATE_CHECK==="
        echo "UPDATE_AVAILABLE=unknown"
        echo "ERROR=已配置的镜像不安全，已拒绝使用（详见上方错误）；请重新设置合法镜像或清空直连"
        echo "===END==="
        return 1
    fi
    local api_url="$REPO_API_URL"
    [ -n "$mirror" ] && api_url="${mirror%/}/$REPO_API_URL"

    echo "===UPDATE_CHECK==="
    echo "CURRENT_VERSION=v$PLUGIN_VERSION"
    echo "REPO=${REPO_OWNER}/${REPO_NAME}"
    echo "MIRROR=${mirror:-(直连)}"

    local latest_tag="" asset_url="" asset_size=0 api_ok=0

    # ---- 方式1: GitHub API + jsonfilter ----
    if command -v jsonfilter >/dev/null 2>&1; then
        local api_json
        api_json=$(update_http_get "$api_url")
        if [ -n "$api_json" ] && echo "$api_json" | grep -q '"tag_name"'; then
            latest_tag=$(echo "$api_json" | jsonfilter -e '@.tag_name' 2>/dev/null)
            asset_url=$(echo "$api_json" | jsonfilter -e '@.assets[0].browser_download_url' 2>/dev/null)
            asset_size=$(echo "$api_json" | jsonfilter -e '@.assets[0].size' 2>/dev/null)
            api_ok=1
        fi
    fi

    # ---- 方式2: /releases/latest 302 Location 解析 tag（无需 API） ----
    if [ -z "$latest_tag" ]; then
        local latest_url="$REPO_BASE_URL/releases/latest"
        [ -n "$mirror" ] && latest_url="${mirror%/}/$latest_url"
        latest_tag=$( (wget -S --spider -T 15 -O /dev/null "$latest_url" 2>&1 || true) | grep -i 'location:' | sed -n 's/.*\/releases\/tag\/\(v[0-9][0-9.]*\).*/\1/p' | tail -1)
        if [ -z "$latest_tag" ] && command -v curl >/dev/null 2>&1; then
            latest_tag=$(curl -sIL --max-time 15 -o /dev/null -w '%{url_effective}' "$latest_url" 2>/dev/null | sed -n 's/.*\/releases\/tag\/\(v[0-9][0-9.]*\).*/\1/p')
        fi
    fi

    if [ -z "$latest_tag" ]; then
        echo "UPDATE_AVAILABLE=unknown"
        echo "ERROR=无法获取最新版本（网络不通或 GitHub 直连受限，可设置镜像加速后重试）"
        echo "===END==="
        write_log "WARN" "update_check: 无法获取最新版本 (mirror=${mirror:-无})"
        return 1
    fi

    # 构造资产下载 URL（CI 固定命名规则兜底；API 获取的真实 URL 优先）
    local asset_name="luci-app-netmanager-install_${latest_tag}.tar.gz"
    local dl_url="${REPO_BASE_URL}/releases/download/${latest_tag}/${asset_name}"
    [ -z "$asset_url" ] && asset_url="$dl_url"
    [ -n "$mirror" ] && asset_url="${mirror%/}/$asset_url"

    local update_available=0
    version_gt "$latest_tag" "v$PLUGIN_VERSION" && update_available=1

    echo "LATEST_VERSION=$latest_tag"
    echo "ASSET_URL=$asset_url"
    echo "ASSET_SIZE=$asset_size"
    # 【v1.4.6 S2】同 tag 的 sha256 校验文件 URL（CI 生成 .tar.gz.sha256 资产；旧版本无此资产时 update_apply 跳过校验）
    echo "SHA256_URL=${asset_url}.sha256"
    echo "UPDATE_AVAILABLE=$update_available"
    if [ "$update_available" = "1" ]; then
        echo "MESSAGE=发现新版本 $latest_tag（当前 v$PLUGIN_VERSION）"
    else
        echo "MESSAGE=当前已是最新版本 (v$PLUGIN_VERSION)"
    fi
    echo "===END==="
    write_log "INFO" "update_check: current=v$PLUGIN_VERSION latest=$latest_tag available=$update_available (api_ok=$api_ok)"
    return 0
}

cmd_update_apply() {
    load_config
    write_log "INFO" "update_apply: 开始在线更新 (current=v$PLUGIN_VERSION)"

    # 1. 检查最新版本（内部结构化输出同时展示给用户）
    local check_out
    check_out=$(cmd_update_check)
    local latest_tag=$(echo "$check_out" | sed -n 's/^LATEST_VERSION=//p')
    local asset_url=$(echo "$check_out" | sed -n 's/^ASSET_URL=//p')
    echo "$check_out"
    if [ -z "$latest_tag" ] || [ -z "$asset_url" ]; then
        error "在线更新失败：无法获取最新版本信息"
        exit 1
    fi
    if echo "$check_out" | grep -q '^UPDATE_AVAILABLE=0$'; then
        info "当前已是最新版本 (v$PLUGIN_VERSION)，无需更新"
        return 0
    fi
    info "准备在线更新: v$PLUGIN_VERSION -> $latest_tag"

    # 2. 下载资产（wget/uclient-fetch/curl 依次兜底；GitHub release URL 302 由客户端自动跟随）
    local download_dir="/tmp/netmanager_upload"
    mkdir -p "$download_dir" 2>/dev/null
    local dest_name="luci-app-netmanager-install_${latest_tag}.tar.gz"
    local dest_file="$download_dir/$dest_name"
    info "开始下载: $asset_url"
    write_log "INFO" "update_apply: 下载 $asset_url -> $dest_file"
    local dl_rc=1
    if command -v wget >/dev/null 2>&1; then
        wget -T 60 -O "$dest_file" "$asset_url" >/dev/null 2>&1 && dl_rc=0
    fi
    if [ $dl_rc -ne 0 ] && command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -T 60 -O "$dest_file" "$asset_url" >/dev/null 2>&1 && dl_rc=0
    fi
    if [ $dl_rc -ne 0 ] && command -v curl >/dev/null 2>&1; then
        curl -sSL --max-time 300 -o "$dest_file" "$asset_url" >/dev/null 2>&1 && dl_rc=0
    fi
    if [ $dl_rc -ne 0 ] || [ ! -s "$dest_file" ]; then
        rm -f "$dest_file" 2>/dev/null
        error "下载失败（网络不通或镜像不可用，可设置镜像加速后重试）"
        write_log "ERROR" "update_apply: 下载失败 url=$asset_url"
        exit 1
    fi

    # 3. 下载校验：大小 + tar 完整性预检，杜绝半截包/HTML 错误页进入安装流程
    local pkg_size=$(wc -c < "$dest_file" 2>/dev/null | tr -d ' ')
    if [ "${pkg_size:-0}" -lt 2000 ]; then
        rm -f "$dest_file" 2>/dev/null
        error "下载的文件异常（仅 ${pkg_size:-0} 字节），已放弃更新"
        write_log "ERROR" "update_apply: 下载文件过小 size=$pkg_size"
        exit 1
    fi
    if ! tar tzf "$dest_file" >/dev/null 2>&1; then
        rm -f "$dest_file" 2>/dev/null
        error "下载的文件不是有效的 tar.gz 包（可能不完整），已放弃更新"
        write_log "ERROR" "update_apply: tar 校验失败 size=$pkg_size"
        exit 1
    fi
    info "下载完成: $pkg_size 字节，完整性校验通过"
    write_log "INFO" "update_apply: 下载校验通过 size=$pkg_size"

    # 【v1.4.6 S2】sha256 签名校验：供应链防护（GitHub 账号被入侵/镜像劫持时拦截恶意包）
    # 校验文件来自同 Release 的 .sha256 资产；旧版本 Release 无此资产时 warn 跳过（向后兼容）
    local sha_url=$(echo "$check_out" | sed -n 's/^SHA256_URL=//p')
    if [ -n "$sha_url" ]; then
        local sha_file="$download_dir/${dest_name}.sha256"
        update_http_get "$sha_url" > "$sha_file" 2>/dev/null
        if [ -s "$sha_file" ] && cat "$sha_file" | grep -qE '^[0-9a-f]{64}'; then
            local expected=$(awk '{print $1}' "$sha_file")
            local actual=$(sha256sum "$dest_file" 2>/dev/null | awk '{print $1}')
            if [ -n "$expected" ] && [ -n "$actual" ] && [ "$expected" != "$actual" ]; then
                rm -f "$dest_file" "$sha_file" 2>/dev/null
                error "下载文件 sha256 校验失败（预期=$expected 实际=$actual），已放弃更新（可能被篡改，建议直连 GitHub 重试）"
                write_log "ERROR" "update_apply: sha256 mismatch expected=$expected actual=$actual"
                exit 1
            fi
            info "sha256 校验通过: $actual"
            write_log "INFO" "update_apply: sha256 ok=$actual"
        else
            warn "未获取到有效 sha256 校验文件（旧版本 Release 或网络受限），跳过校验"
            write_log "WARN" "update_apply: sha256 文件缺失，跳过校验 sha_url=$sha_url"
        fi
        rm -f "$sha_file" 2>/dev/null
    else
        warn "本次更新源未提供 sha256 校验（旧版本），跳过校验"
    fi

    # 4. 复用 plugin_update 安装流程（解压 + install.sh + 延迟重启 uhttpd）
    cmd_plugin_update "$dest_name"
}

# 【v1.4.6 P0】镜像安全校验：非空时必须在域名白名单内（防镜像劫持注入恶意安装包）
# 返回 0=安全/空镜像；1=不安全（已输出错误）
mirror_check() {
    local m="$1"
    [ -z "$m" ] && return 0
    local host=$(echo "$m" | sed -n 's|^https\?://\([^/:]*\).*|\1|p')
    [ -z "$host" ] && { error "镜像 URL 格式无效（应为 http(s)://域名/...）"; return 1; }
    # 拒绝裸 IP（含 IPv6 简写），白名单只认域名
    case "$host" in
        *[0-9].[0-9]*|*[0-9]:*[0-9]*|localhost)
            error "禁止使用 IP 直连镜像: $host"; return 1 ;;
    esac
    local ok=0 h
    for h in $MIRROR_HOST_ALLOWLIST; do
        [ "$host" = "$h" ] && ok=1
    done
    [ "$ok" = "1" ] || { error "镜像域名 '$host' 不在允许列表（允许: $(echo $MIRROR_HOST_ALLOWLIST | tr ' ' ', ')）；如需新增请编辑 /usr/sbin/netmanager 的 MIRROR_HOST_ALLOWLIST"; return 1; }
    return 0
}

cmd_set_update_mirror() {
    local m="$1"
    load_config
    if [ -n "$m" ]; then
        case "$m" in
            http://*|https://*) ;;
            *) error "镜像前缀必须以 http:// 或 https:// 开头（留空表示直连 GitHub）"; exit 1 ;;
        esac
        m="${m%/}"
        # 【v1.4.6 P0】域名白名单校验
        mirror_check "$m" || exit 1
    fi
    uci set netmanager.settings.update_mirror="$m"
    uci commit netmanager
    if [ -n "$m" ]; then
        info "更新镜像已设置: $m"
    else
        info "更新镜像已清空（直连 GitHub）"
    fi
}

# ========== 11. 设置管理 ==========
cmd_set_default_target() {
    ip="$1"
    write_log "INFO" "set_default_target: 用户设置默认目标IP=$ip"
    [ -z "$ip" ] && { error "用法: netmanager set_default_target <IP>"; exit 1; }
    load_config
    uci set netmanager.settings.default_target="$ip"
    uci commit netmanager
    info "默认目标IP已设置为: $ip"
}

cmd_log_set() {
    local enable="${1:-0}"
    load_config
    if [ "$enable" = "1" ] || [ "$enable" = "on" ] || [ "$enable" = "true" ]; then
        uci set netmanager.settings.log_enable='1'
        uci commit netmanager
        reload_log_setting
        mkdir -p "$LOG_DIR" 2>/dev/null
        info "运行日志已开启（输出目录: $LOG_DIR）"
        write_log "INFO" "===== 日志开启 ====="
    else
        write_log "INFO" "===== 日志关闭 ====="
        uci set netmanager.settings.log_enable='0'
        uci commit netmanager
        reload_log_setting
        info "运行日志已关闭"
    fi
}

cmd_log_get() {
    local lines="${1:-200}"
    mkdir -p "$LOG_DIR" 2>/dev/null
    echo "===RUN_LOG==="
    echo "LOG_ENABLED=$LOG_ENABLED"
    echo "LOG_FILE=$LOG_FILE"
    if [ -f "$LOG_FILE" ]; then
        local total=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        local sz=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
        echo "LOG_LINES=$total"
        echo "LOG_SIZE=$sz"
        echo "---CONTENT---"
        tail -n "$lines" "$LOG_FILE" 2>/dev/null
    else
        echo "LOG_LINES=0"
        echo "LOG_SIZE=0"
    fi
    echo "===END==="
}

cmd_log_clear() {
    write_log "INFO" "log_clear: 用户请求清空运行日志"
    if [ -f "$LOG_FILE" ]; then
        rm -f "$LOG_FILE" 2>/dev/null
        info "运行日志已清空"
    else
        info "日志文件不存在，无需清理"
    fi
}

# ========== v1.5.0 增强：日志查询（级别过滤 + 关键词搜索 + 统计） ==========
# 用法: netmanager log_query [级别] [关键词] [行数]
#   级别: ALL|INFO|WARN|ERROR|DEBUG（默认 ALL）
#   关键词: 任意字符串（grep 模糊匹配，空=不过滤）
#   行数: 返回最后 N 行（默认 200）
cmd_log_query() {
    local level="${1:-ALL}"
    local keyword="${2:-}"
    local lines="${3:-200}"
    mkdir -p "$LOG_DIR" 2>/dev/null

    echo "===LOG_QUERY==="
    echo "LOG_ENABLED=$LOG_ENABLED"
    echo "LOG_FILE=$LOG_FILE"
    echo "FILTER_LEVEL=$level"
    echo "FILTER_KEYWORD=$keyword"

    if [ ! -f "$LOG_FILE" ]; then
        echo "TOTAL_LINES=0"
        echo "COUNT_INFO=0"
        echo "COUNT_WARN=0"
        echo "COUNT_ERROR=0"
        echo "COUNT_DEBUG=0"
        echo "---CONTENT---"
        echo "===END==="
        return 0
    fi

    # 全量统计（不受过滤影响）
    local total=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    local cnt_info=$(grep -c '\[INFO\]' "$LOG_FILE" 2>/dev/null || echo 0)
    local cnt_warn=$(grep -c '\[WARN\]' "$LOG_FILE" 2>/dev/null || echo 0)
    local cnt_error=$(grep -c '\[ERROR\]' "$LOG_FILE" 2>/dev/null || echo 0)
    local cnt_debug=$(grep -c '\[DEBUG\]' "$LOG_FILE" 2>/dev/null || echo 0)
    echo "TOTAL_LINES=$total"
    echo "COUNT_INFO=$cnt_info"
    echo "COUNT_WARN=$cnt_warn"
    echo "COUNT_ERROR=$cnt_error"
    echo "COUNT_DEBUG=$cnt_debug"

    # 构建过滤管道
    local filtered="$LOG_FILE"
    local tmp_filter="/tmp/netmanager_log_filter_$$"
    local need_tmp=0

    if [ "$level" != "ALL" ]; then
        grep "\[${level}\]" "$LOG_FILE" > "$tmp_filter" 2>/dev/null
        filtered="$tmp_filter"
        need_tmp=1
    fi

    if [ -n "$keyword" ]; then
        if [ $need_tmp -eq 1 ]; then
            grep -i -- "$keyword" "$filtered" > "${tmp_filter}_2" 2>/dev/null
            mv "${tmp_filter}_2" "$filtered" 2>/dev/null
        else
            grep -i -- "$keyword" "$LOG_FILE" > "$tmp_filter" 2>/dev/null
            filtered="$tmp_filter"
            need_tmp=1
        fi
    fi

    echo "MATCHED_LINES=$(wc -l < "$filtered" 2>/dev/null || echo 0)"
    echo "---CONTENT---"
    tail -n "$lines" "$filtered" 2>/dev/null
    echo "===END==="

    [ -f "$tmp_filter" ] && rm -f "$tmp_filter" 2>/dev/null
    return 0
}

# ========== v1.5.0 增强：日志导出（下载完整日志文件） ==========
# 用法: netmanager log_export
# 输出: 日志文件路径 + base64 内容（前端解码下载）
cmd_log_export() {
    mkdir -p "$LOG_DIR" 2>/dev/null
    echo "===LOG_EXPORT==="
    if [ -f "$LOG_FILE" ]; then
        echo "LOG_FILE=$LOG_FILE"
        echo "LOG_SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)"
        echo "LOG_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)"
        echo "---BASE64---"
        base64 "$LOG_FILE" 2>/dev/null
    else
        echo "LOG_FILE=$LOG_FILE"
        echo "LOG_SIZE=0"
        echo "LOG_LINES=0"
        echo "---BASE64---"
    fi
    echo "===END==="
}

cmd_settings() {
    load_config
    echo "===SETTINGS==="
    echo "DEFAULT_TARGET=$DEFAULT_TARGET"
    echo "LOG_DAYS=$(uci get netmanager.settings.log_days 2>/dev/null || echo 7)"
    echo "LOG_ENABLE=$LOG_ENABLED"
    echo "LOG_FILE=$LOG_FILE"
    echo "CHINA_FILTER_ENABLED=$(uci get netmanager.settings.china_filter_enable 2>/dev/null || echo 0)"
    echo "CHINA_FILTER_URL=$(uci get netmanager.settings.china_filter_url 2>/dev/null || echo 'https://metowolf.github.io/iplist/data/special/china.txt')"
    echo "CHINA_FILTER_CRON=$(uci get netmanager.settings.china_filter_cron 2>/dev/null || echo '0 3 * * 0')"
    echo "CHINA_FILTER_LAST_UPDATE=$(uci get netmanager.settings.china_filter_last_update 2>/dev/null)"
    echo "CHINA_FILTER_COUNT=$(uci get netmanager.settings.china_filter_count 2>/dev/null || echo 0)"
    echo "CHINA_FILTER_ALLOW_WAN_PEERS=$(uci get netmanager.settings.china_filter_allow_wan_peers 2>/dev/null || echo 1)"
    echo "CHINA6_FILTER_ENABLED=$(uci get netmanager.settings.china6_filter_enable 2>/dev/null || echo 0)"
    echo "CHINA6_FILTER_URL=$(uci get netmanager.settings.china6_filter_url 2>/dev/null || echo 'https://ispip.clang.cn/all_cn_ipv6.txt')"
    echo "CHINA6_FILTER_CRON=$(uci get netmanager.settings.china6_filter_cron 2>/dev/null || echo '0 3 * * 0')"
    echo "CHINA6_FILTER_LAST_UPDATE=$(uci get netmanager.settings.china6_filter_last_update 2>/dev/null)"
    echo "CHINA6_FILTER_COUNT=$(uci get netmanager.settings.china6_filter_count 2>/dev/null || echo 0)"
    echo "UPDATE_MIRROR=$(uci get netmanager.settings.update_mirror 2>/dev/null)"
    echo "===END==="
}

# ========== 12. 版本信息 ==========
cmd_version() {
    echo "网络管理插件 v$PLUGIN_VERSION"
    echo ""
    echo "功能: 系统概览 / 端口转发 / 规则管理 / SSH日志 / 访问日志 / 备份恢复 / 在线更新 / 插件更新 / 运行日志 / 中国IPv4+IPv6访问限制 / 手动黑名单 / 手动白名单(IPv4+IPv6)"
    echo "适配: iStoreOS / OpenWrt (fw4/nftables)"
}

# ========== 13. 中国IPv4访问限制 ==========
# 原理：独立 nft 表 inet netmanager（与 fw4 分离，fw4 reload 不影响本表），
#       内含 china_v4 CIDR 集合 + input/forward 两条 base chain(priority -50)，
#       规则：iifname {wan_devs} ct state new {tcp,udp} 且 ip saddr 不在中国集合 -> drop。
#       仅拦截境外 IPv4 新建连接到已开放端口，不影响已建立连接/出站/局域网间转发。
CHINA_LIST_DIR="/etc/netmanager"
CHINA_LIST_FILE="$CHINA_LIST_DIR/china_v4.list"
CHINA_NFT_TABLE="inet netmanager"
CHINA_DEFAULT_URL="https://metowolf.github.io/iplist/data/special/china.txt"
CHINA_DEFAULT_CRON="0 3 * * 0"

china_get_url() {
    local u=$(uci get netmanager.settings.china_filter_url 2>/dev/null)
    echo "${u:-$CHINA_DEFAULT_URL}"
}

china_get_cron() {
    local c=$(uci get netmanager.settings.china_filter_cron 2>/dev/null)
    echo "${c:-$CHINA_DEFAULT_CRON}"
}

china_get_enable() {
    local e=$(uci get netmanager.settings.china_filter_enable 2>/dev/null)
    [ "$e" = "1" ] && echo 1 || echo 0
}

# 探测 WAN 设备名（去重、空格分隔），用于 iifname 匹配
get_wan_devs() {
    local devs="" d nd val zn net
    # 0) 调试/测试钩子：直接指定设备列表（真机复现与 CI 用，正常运行时为空）
    if [ -n "${NM_WAN_DEVS_OVERRIDE:-}" ]; then
        echo "$NM_WAN_DEVS_OVERRIDE" | tr ' ' '\n' | grep -E '^[a-zA-Z0-9._@-]+$' | sort -u | tr '\n' ' '
        return 0
    fi
    # 1) 默认路由设备（IPv4/IPv6 双栈都纳入，避免仅 v6 有默认路由时探测失败）
    d=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ -n "$d" ] && devs="$d"
    d=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ -n "$d" ] && devs="$devs $d"
    # 2) network.wan / wan6 的 device / ifname
    for n in wan wan6; do
        nd=$(uci get network.$n.device 2>/dev/null)
        [ -z "$nd" ] && nd=$(uci get network.$n.ifname 2>/dev/null)
        [ -n "$nd" ] && devs="$devs $nd"
    done
    # 3) firewall wan/wan6 zone 的 device 与 network（network 需解析到 device）
    idx=0
    while uci get firewall.@zone[$idx].name >/dev/null 2>&1; do
        zn=$(uci get firewall.@zone[$idx].name 2>/dev/null)
        case "$zn" in
            wan|wan6)
                val=$(uci get firewall.@zone[$idx].device 2>/dev/null)
                [ -n "$val" ] && devs="$devs $val"
                val=$(uci get firewall.@zone[$idx].network 2>/dev/null)
                [ -n "$val" ] && for net in $val; do
                    nd=$(uci get network.$net.device 2>/dev/null)
                    [ -z "$nd" ] && nd=$(uci get network.$net.ifname 2>/dev/null)
                    [ -n "$nd" ] && devs="$devs $nd"
                done
                ;;
        esac
        idx=$((idx+1))
    done
    # 去重 + 仅保留合法接口名
    echo "$devs" | tr ' ' '\n' | grep -E '^[a-zA-Z0-9._@-]+$' | sort -u | grep -v '^$' | tr '\n' ' '
}

# IPv4 地址 + 前缀长度 → 网段 CIDR（如 192.168.1.5/24 → 192.168.1.0/24）
# 纯 shell 实现，不依赖 ipcalc（OpenWrt 默认没有）
cidr_of_addr() {
    local ip="$1" p="$2" a b c d oct i=0 rem size out=""
    set -- $(echo "$ip" | tr '.' ' ')
    a=$1; b=$2; c=$3; d=$4
    for oct in "$a" "$b" "$c" "$d"; do
        rem=$(( p - i * 8 ))
        if [ "$rem" -le 0 ]; then
            oct=0
        elif [ "$rem" -ge 8 ]; then
            oct=$oct
        else
            size=$(( 1 << (8 - rem) ))
            oct=$(( oct - oct % size ))
        fi
        out="${out}${out:+.}${oct}"
        i=$(( i + 1 ))
    done
    echo "${out}/${p}"
}

# 探测 WAN 口自身所在的 IPv4 网段（上级光猫/网关通常就在这段里）
# 只放行"与自己同段"的来源，比直接放行整个 RFC1918 精确得多
get_wan_prefixes() {
    local devs="${1:-}" dev addr out="" parsed a b
    for dev in $devs; do
        # 注意 PPP 点对点接口的 `ip -o addr` 输出是 "inet 223.x.x.x peer 223.x.x.1/32"
        # 只有 /32 掩码信息在 peer 后面，必须单独解析，否则拿不到前缀
        parsed=$(ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{
            ip=""; p="32";
            for (i=1;i<=NF;i++) {
                if ($i=="inet") { v=$(i+1); if (v ~ /\//) { split(v,z,"/"); ip=z[1]; p=z[2] } else { ip=v } }
                else if ($i=="peer") { v=$(i+1); if (v ~ /\//) { split(v,z,"/"); p=z[2] } }
            }
            if (ip!="") print ip, p
        }')
        set -- $parsed
        while [ $# -gt 0 ]; do
            a=$1; b=${2:-32}; shift 2
            [ -n "$a" ] && out="$out $(cidr_of_addr "$a" "$b")"
        done
    done
    echo "$out" | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' | sort -u | tr '\n' ' '
}

# 探测 WAN 口自身所在的 IPv6 网段（按 /64 取前 4 组；链路本地 fe80 已单独放行，不重复加）
get_wan_prefixes6() {
    local devs="${1:-}" dev addr out=""
    for dev in $devs; do
        for addr in $(ip -6 -o addr show dev "$dev" 2>/dev/null | awk '{print $4}'); do
            case "$addr" in
                *fe80*) continue ;;
            esac
            # 只处理标准 8 组写法，压缩写法（::）交给集合兜底
            local groups
            groups=$(echo "$addr" | cut -d/ -f1 | awk -F: 'NF>=8{print $1":"$2":"$3":"$4"::/64"}')
            [ -n "$groups" ] && out="$out $groups"
        done
    done
    echo "$out" | tr ' ' '\n' | grep -E '^[0-9a-fA-F:]+::/64$' | sort -u | tr '\n' ' '
}

# 创建 china_v4 集合（兼容旧版 nft：先尝试 interval,auto-merge；失败则降级仅 interval）
# 成功后设置全局 CHINA_SET_FLAGS = "modern" 或 "compat"
china_create_set() {
    CHINA_SET_FLAGS=""
    # 先确保表存在
    nft add table inet netmanager 2>/dev/null
    local nft_err
    nft_err=$( ( nft 'add set inet netmanager china_v4 { type ipv4_addr; flags interval, auto-merge; }' ) 2>&1 )
    if [ -z "$nft_err" ]; then
        CHINA_SET_FLAGS="modern"
        return 0
    fi
    # 失败且含 "unexpected auto-merge" → 旧版 nft，降级
    case "$nft_err" in
        *unexpected\ auto-merge*|*auto-merge*)
            write_log "INFO" "china_filter: 旧版 nft 不支持 auto-merge，降级为 flags interval + 一次性原子加载"
            local nft_err2
            nft_err2=$( ( nft 'add set inet netmanager china_v4 { type ipv4_addr; flags interval; }' ) 2>&1 )
            if [ -z "$nft_err2" ]; then
                CHINA_SET_FLAGS="compat"
                return 0
            fi
            write_log "ERROR" "china_filter: 降级 add set interval 也失败: $nft_err2"
            error "nft 创建 china_v4 集合失败（降级后）: $nft_err2"
            return 1
            ;;
        *)
            write_log "ERROR" "china_filter: add set china_v4 失败: $nft_err"
            error "nft 创建 china_v4 集合失败: $nft_err"
            return 1
            ;;
    esac
}

# 载入 CIDR 到 china_v4 集合
#   modern(有auto-merge)  → 分片 500 条批量 add element（CIDR 重叠容忍）
#   compat(仅interval)    → 所有 CIDR 在同一条 add element 中，让内核原子合并重叠区间
# 返回成功载入条数；失败返回 0
china_load_set() {
    [ -f "$CHINA_LIST_FILE" ] || { echo 0; return; }
    # 若 china_apply_rules 未先调用则 CHINA_SET_FLAGS 为空，自行确保表+集存在
    if [ -z "$CHINA_SET_FLAGS" ]; then
        if nft list chain inet netmanager 2>/dev/null; then
            :
        else
            nft add table inet netmanager 2>/dev/null
        fi
        # 检测集合是否存在并推断模式
        if nft list set inet netmanager china_v4 2>/dev/null | grep -q 'auto-merge'; then
            CHINA_SET_FLAGS="modern"
        elif nft list set inet netmanager china_v4 >/dev/null 2>&1; then
            CHINA_SET_FLAGS="compat"
        else
            china_create_set || { echo 0; return; }
        fi
    fi

    local clean="/tmp/netmanager_china_clean.list"
    local ef="/tmp/netmanager_china_elem.nft"
    local total=0 loaded=0
    local nft_err=""
    rm -f "$clean" "$ef" /tmp/netmanager_china_nft.err 2>/dev/null

    # 先过滤出纯净的 CIDR 行
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$CHINA_LIST_FILE" > "$clean" 2>/dev/null
    total=$(wc -l < "$clean" 2>/dev/null | tr -d ' ')
    [ "${total:-0}" -lt 50 ] && { rm -f "$clean"; echo 0; return; }

    if [ "$CHINA_SET_FLAGS" = "modern" ]; then
        # ========= 分片加载（auto-merge 允许重叠逐批加） =========
        # 【v1.4.6 P1】分片失败不再静默继续：部分加载的 CIDR 集合会误杀国内流量
        # （规则语义是"不在集合内即 drop"，缺一大段 = 国内 IP 被当境外丢弃）
        # 任何一批失败 → 记 failed_batches，循环结束后 loaded 按 0 返回，上层
        # china_apply_rules 因 count<50 中止应用并删除表（fail-closed，安全方向）
        local batch=500 buf="" buf_n=0 line failed_batches=0
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            if [ "$buf_n" -ge "$batch" ]; then
                {
                    printf 'add element inet netmanager china_v4 { %s }\n' "$buf"
                } > "$ef"
                if nft -f "$ef" 2>/tmp/netmanager_china_nft.err; then
                    loaded=$((loaded + buf_n))
                else
                    nft_err=$(cat /tmp/netmanager_china_nft.err 2>/dev/null | tr '\n' ' ')
                    failed_batches=$((failed_batches + 1))
                    write_log "WARN" "china_filter: (modern) nft batch add element failed (size=$buf_n, head=$(echo "$buf" | cut -c1-80)): $nft_err"
                fi
                buf="" buf_n=0
            fi
            if [ "$buf_n" -eq 0 ]; then
                buf="$line"
            else
                buf="$buf, $line"
            fi
            buf_n=$((buf_n + 1))
        done < "$clean"
        # 尾批
        if [ "$buf_n" -gt 0 ]; then
            {
                printf 'add element inet netmanager china_v4 { %s }\n' "$buf"
            } > "$ef"
            if nft -f "$ef" 2>/tmp/netmanager_china_nft.err; then
                loaded=$((loaded + buf_n))
            else
                nft_err=$(cat /tmp/netmanager_china_nft.err 2>/dev/null | tr '\n' ' ')
                failed_batches=$((failed_batches + 1))
                write_log "WARN" "china_filter: (modern) nft tail batch add element failed (size=$buf_n, head=$(echo "$buf" | cut -c1-80)): $nft_err"
            fi
        fi
        if [ "$failed_batches" -gt 0 ]; then
            # 有失败批次 → 集合不完整，按整体失败处理（上层 count<50 会中止并删表，不会带病生效）
            write_log "ERROR" "china_filter: (modern) $failed_batches 批分片加载失败，集合不完整，按整体失败处理（防止残缺集合误杀国内流量）"
            error "中国IP列表分片加载有 $failed_batches 批失败，已中止应用（防止不完整集合误杀国内流量）"
            rm -f "$clean" "$ef" /tmp/netmanager_china_nft.err 2>/dev/null
            echo 0
            return
        fi
    else
        # ========= 一次性原子加载（compat：无 auto-merge，全部 CIDR 一条 add element 让内核合并重叠区间） =========
        # 组装 "add element inet netmanager china_v4 { a, b, c, ... }"
        {
            printf 'add element inet netmanager china_v4 { '
            awk 'BEGIN{ORS=""}{if(NR>1)printf ", ";printf "%s",$0}' "$clean"
            printf ' }\n'
        } > "$ef"
        if nft -f "$ef" 2>/tmp/netmanager_china_nft.err; then
            loaded="$total"
        else
            nft_err=$(cat /tmp/netmanager_china_nft.err 2>/dev/null | tr '\n' ' ')
            # 部分老 nft 即使 atomic 也对特别长的行敏感；失败后回退单条 add element 逐行（慢但稳）
            local ok_rows=0 bad_rows=0 l
            write_log "WARN" "china_filter: (compat) atomic add element 失败，回退逐行加载: $nft_err"
            while IFS= read -r l; do
                [ -z "$l" ] && continue
                if nft "add element inet netmanager china_v4 { $l }" 2>/dev/null; then
                    ok_rows=$((ok_rows + 1))
                else
                    bad_rows=$((bad_rows + 1))
                fi
            done < "$clean"
            loaded="$ok_rows"
            write_log "INFO" "china_filter: (compat) 逐行回退完成: 成功=$ok_rows 失败=$bad_rows"
        fi
    fi

    rm -f "$clean" "$ef" /tmp/netmanager_china_nft.err 2>/dev/null
    echo "${loaded:-0}"
}

# 创建表/集合、载入CIDR、安装 input+forward 两条 drop 规则
china_apply_rules() {
    [ -f "$CHINA_LIST_FILE" ] || { error "中国IP列表文件不存在: $CHINA_LIST_FILE"; return 1; }
    # 先强制删除旧表，彻底防止遗留脏结构（旧 flag / 错误 size）
    nft delete table inet netmanager 2>/dev/null
    local nft_err
    if ! nft add table inet netmanager 2>/tmp/netmanager_china_nft.err; then
        nft_err=$(cat /tmp/netmanager_china_nft.err 2>/dev/null | tr '\n' ' ')
        write_log "ERROR" "china_filter: add table inet netmanager 失败: $nft_err"
        rm -f /tmp/netmanager_china_nft.err 2>/dev/null
        error "nft 创建 inet netmanager 表失败: $nft_err"
        return 1
    fi
    rm -f /tmp/netmanager_china_nft.err 2>/dev/null

    # 根据 nft 版本自动选择 set flag 策略
    CHINA_SET_FLAGS=""
    if ! china_create_set; then
        # china_create_set 内部已经写过诊断+error
        return 1
    fi
    write_log "INFO" "china_filter: 使用 nft china_v4 集合模式: $CHINA_SET_FLAGS"

    local count
    count=$(china_load_set)
    if [ "${count:-0}" -lt 50 ]; then
        error "中国IP列表载入失败或条数过少($count)，已中止应用规则"
        return 1
    fi

    # v1.8.17：把手动白名单并进 china_v4 集合（等价于人工补充的允许列表）
    if [ -n "${WL_V4_FILE:-}" ] && [ -s "$WL_V4_FILE" ]; then
        wl_add_to_set netmanager china_v4 "$WL_V4_FILE" || \
            write_log "ERROR" "china_filter: 手动白名单(IPv4)并入失败"
    fi

    local devs
    devs=$(get_wan_devs)
    if [ -z "$devs" ]; then
        error "未探测到WAN设备，无法安装过滤规则（请检查 wan 接口/默认路由）"
        return 1
    fi
    # 构造 iifname { "eth0", "pppoe-wan" }（带双引号）
    local ifname_set
    ifname_set=$(echo "$devs" | awk '{for(i=1;i<=NF;i++){if(i>1)printf ", ";printf "\"%s\"",$i}}')

    # v1.8.17：放行 WAN 口自身所在网段的来源。
    # 典型场景：光猫拨号/桥接时，光猫管理 IP 与路由器 WAN 同处一个私网段（如 192.168.1.1），
    # 该 IP 不在 china.txt（公网库）里 → 会被「saddr != @china_v4 drop」误杀，导致上级光猫访问不到路由器。
    # 只放行"与自己同段"的地址，比放行整个 RFC1918 精确得多。
    local allow_peers wan_prefixes
    allow_peers=$(uci get netmanager.settings.china_filter_allow_wan_peers 2>/dev/null)
    [ -z "$allow_peers" ] && allow_peers=1
    wan_prefixes=""
    [ "$allow_peers" = "1" ] && wan_prefixes=$(get_wan_prefixes "$devs")

    # 删除旧链（幂等）
    nft delete chain inet netmanager china_input 2>/dev/null
    nft delete chain inet netmanager china_forward 2>/dev/null

    local rf="/tmp/netmanager_china_rules.nft"
    {
        echo "add chain inet netmanager china_input { type filter hook input priority -50; policy accept; }"
        echo "add chain inet netmanager china_forward { type filter hook forward priority -50; policy accept; }"
        # v1.7.2 修复：先放行 DHCPv4 服务端应答(67->68)与链路本地网段，
        # 避免白名单规则误伤 DHCP 续租导致 WAN/LAN 地址丢失
        printf 'add rule inet netmanager china_input iifname { %s } udp sport 67 udp dport 68 counter accept\n' "$ifname_set"
        printf 'add rule inet netmanager china_input iifname { %s } ip saddr 169.254.0.0/16 counter accept\n' "$ifname_set"
        # v1.7.3 修复：forward 链同样需放行 DHCPv4 应答与链路本地地址。
        # 否则 DHCP relay（LAN 设备经路由器向运营商续租）的应答会被
        # 「ip saddr != @china_v4 drop」误判为境外 IPv4 直接丢弃，导致租约续不上。
        printf 'add rule inet netmanager china_forward iifname { %s } udp sport 67 udp dport 68 counter accept\n' "$ifname_set"
        printf 'add rule inet netmanager china_forward iifname { %s } ip saddr 169.254.0.0/16 counter accept\n' "$ifname_set"
        # v1.8.17：WAN 同网段来源（上级光猫/网关）在两条链上都要放行，且在 drop 之前
        local pfx
        for pfx in $wan_prefixes; do
            printf 'add rule inet netmanager china_input iifname { %s } ip saddr %s counter accept\n' "$ifname_set" "$pfx"
            printf 'add rule inet netmanager china_forward iifname { %s } ip saddr %s counter accept\n' "$ifname_set" "$pfx"
        done
        printf 'add rule inet netmanager china_forward iifname { %s } ct state new meta l4proto { tcp, udp } ip saddr != @china_v4 counter drop\n' "$ifname_set"
        printf 'add rule inet netmanager china_input iifname { %s } ct state new meta l4proto { tcp, udp } ip saddr != @china_v4 limit rate 10/minute burst 20 packets log prefix "NM_DROP4: " level warn\n' "$ifname_set"
        printf 'add rule inet netmanager china_input iifname { %s } ct state new meta l4proto { tcp, udp } ip saddr != @china_v4 counter drop\n' "$ifname_set"
    } > "$rf"
    # 调试钩子：只打印生成的规则不落盘应用（真机排查 / CI 用）
    if [ -n "${NM_RULES_ONLY:-}" ] || [ "${NM_RULES_ONLY:-0}" = "1" ]; then
        echo "=== 生成的 nft 规则（NM_RULES_ONLY）==="
        cat "$rf"
        echo "=== WAN 设备: $devs | 放行同段: ${wan_prefixes:-无} ==="
        rm -f "$rf"
        return 0
    fi
    if ! nft -f "$rf" 2>/tmp/netmanager_china_rules.err; then
        write_log "ERROR" "china_filter: 规则链安装失败: $(cat /tmp/netmanager_china_rules.err 2>/dev/null | tr '\n' ' ')"
        rm -f "$rf" /tmp/netmanager_china_rules.err 2>/dev/null
        error "nft 规则安装失败（nft -f 返回错误）"
        return 1
    fi
    rm -f "$rf" /tmp/netmanager_china_rules.err 2>/dev/null

    uci set netmanager.settings.china_filter_count="$count"
    uci commit netmanager 2>/dev/null
    info "中国IPv4过滤规则已应用: 条数=$count WAN设备=[$(echo $devs)] 放行同段=[${wan_prefixes:-无}]"
    write_log "INFO" "china_filter apply: count=$count devs=$devs allow_wan_peers=$allow_peers peers=${wan_prefixes:-none}"
    return 0
}

china_clear_kernel() {
    nft delete table inet netmanager 2>/dev/null
}

# 下载中国IP列表（URL 取自配置），校验后存到持久化路径
china_download() {
    local url=$(china_get_url)
    local tmp="/tmp/netmanager_china.tmp"
    info "下载中国IP列表: $url"
    write_log "INFO" "china_filter: 下载 $url"
    mkdir -p "$CHINA_LIST_DIR" 2>/dev/null
    if command -v wget >/dev/null 2>&1; then
        wget -q -T 30 -O "$tmp" "$url" 2>/dev/null
    elif command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q -T 30 -O "$tmp" "$url" 2>/dev/null
    elif command -v curl >/dev/null 2>&1; then
        curl -sS --max-time 30 -o "$tmp" "$url" 2>/dev/null
    else
        error "未找到 wget/uclient-fetch/curl，无法下载"
        return 1
    fi
    if [ ! -s "$tmp" ]; then
        error "下载失败：文件为空或不存在（请检查订阅链接与网络）"
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
    # 纯化：去 UTF-8 BOM(首字节EFBBBF)、去 CR(\r)、去以#开头注释/空行，仅保留合法 IPv4 CIDR
    local clean="/tmp/netmanager_china_clean.tmp"
    rm -f "$clean" 2>/dev/null
    if command -v sed >/dev/null 2>&1; then
        sed '1s/^\xef\xbb\xbf//' "$tmp" 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' > "$clean" 2>/dev/null
    else
        tr -d '\r' < "$tmp" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' > "$clean" 2>/dev/null
    fi
    local n
    n=$(wc -l < "$clean" 2>/dev/null | tr -d ' ')
    if [ "${n:-0}" -lt 100 ]; then
        error "下载内容不像 CIDR 列表（有效行数=$n），已拒绝保存"
        rm -f "$tmp" "$clean" 2>/dev/null
        return 1
    fi
    mv -f "$clean" "$CHINA_LIST_FILE"
    rm -f "$tmp" 2>/dev/null
    uci set netmanager.settings.china_filter_count="$n"
    uci set netmanager.settings.china_filter_last_update="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    uci commit netmanager 2>/dev/null
    info "下载完成：$n 条CIDR"
    return 0
}

china_cron_remove() {
    local cr="/etc/crontabs/root"
    [ -f "$cr" ] || return 0
    grep -v 'netmanager china_filter update' "$cr" > "$cr.tmp" 2>/dev/null
    mv -f "$cr.tmp" "$cr" 2>/dev/null
    /etc/init.d/cron reload 2>/dev/null
    return 0
}

china_cron_install() {
    local cr="/etc/crontabs/root"
    mkdir -p /etc/crontabs 2>/dev/null
    [ -f "$cr" ] || touch "$cr"
    china_cron_remove
    local expr=$(china_get_cron)
    # 【v1.4.6 P2】装载前二次校验（UCI 可能被直接编辑，绕过 set_cron 的校验）；
    # 非法 cron 会导致 cron 服务加载整表失败，影响所有计划任务
    local fields=$(echo "$expr" | awk '{print NF}')
    if [ "$fields" != "5" ] || echo "$expr" | tr ' ' '\n' | grep -qE '[^0-9*,/\-]'; then
        write_log "ERROR" "china_filter: UCI 中的 cron 表达式非法: '$expr'，跳过安装 cron（请用 set_cron 重新设置）"
        warn "cron 表达式非法（$fields 段/含非法字符），已跳过安装，其余功能不受影响"
        return 1
    fi
    echo "$expr /usr/sbin/netmanager china_filter update" >> "$cr"
    /etc/init.d/cron reload 2>/dev/null
    info "已安装 cron 更新计划: $expr"
}

cmd_china_status() {
    load_config
    local en=$(china_get_enable)
    local url=$(china_get_url)
    local cron=$(china_get_cron)
    local lu=$(uci get netmanager.settings.china_filter_last_update 2>/dev/null)
    local cnt=$(uci get netmanager.settings.china_filter_count 2>/dev/null)
    [ -z "$cnt" ] && cnt=0
    local devs=$(get_wan_devs)
    [ -z "$devs" ] && devs="(未探测到)"
    local active=0
    if nft list table inet netmanager >/dev/null 2>&1; then
        if nft list chain inet netmanager china_forward 2>/dev/null | grep -q 'china_v4'; then
            active=1
        fi
    fi
    echo "===CHINA_FILTER==="
    echo "CHINA_FILTER_ENABLED=$en"
    echo "URL=$url"
    echo "CRON=$cron"
    echo "LAST_UPDATE=${lu:-未更新}"
    echo "COUNT=$cnt"
    echo "WAN_DEVS=$devs"
    echo "RULE_ACTIVE=$active"
    local awp=$(uci get netmanager.settings.china_filter_allow_wan_peers 2>/dev/null)
    [ -z "$awp" ] && awp=1
    local peers="-"
    [ "$awp" = "1" ] && peers=$(get_wan_prefixes "$devs")
    echo "ALLOW_WAN_PEERS=$awp"
    echo "WAN_PEERS=${peers:--}"
    echo "LIST_FILE=$CHINA_LIST_FILE"
    echo "===END==="
}

cmd_china_set_url() {
    local url="$1"
    [ -z "$url" ] && { error "用法: netmanager china_filter set_url <url>"; exit 1; }
    case "$url" in
        http://*|https://*) ;;
        *) error "URL 必须以 http:// 或 https:// 开头"; exit 1 ;;
    esac
    load_config
    uci set netmanager.settings.china_filter_url="$url"
    uci commit netmanager
    info "订阅链接已保存: $url"
    info "点击「更新IP库」或重新启用以生效"
}

cmd_china_set_cron() {
    local expr="$1"
    [ -z "$expr" ] && { error "用法: netmanager china_filter set_cron \"<5段cron表达式>\""; exit 1; }
    local fields=$(echo "$expr" | awk '{print NF}')
    [ "$fields" != "5" ] && { error "cron表达式必须为5段（分 时 日 月 周），当前 $fields 段"; exit 1; }
    if echo "$expr" | tr ' ' '\n' | grep -qE '[^0-9*,/\-]'; then
        error "cron表达式含非法字符（仅允许 0-9 * / , -）"; exit 1
    fi
    load_config
    uci set netmanager.settings.china_filter_cron="$expr"
    uci commit netmanager
    info "更新计划已保存: $expr"
    [ "$(china_get_enable)" = "1" ] && china_cron_install
}

cmd_china_enable() {
    write_log "INFO" "china_enable: 用户请求启用中国IPv4访问限制"
    load_config
    if [ ! -f "$CHINA_LIST_FILE" ]; then
        china_download || { error "启用失败：无法获取中国IP列表"; exit 1; }
    fi
    uci set netmanager.settings.china_filter_enable='1'
    uci commit netmanager
    if ! china_apply_rules; then
        uci set netmanager.settings.china_filter_enable='0'
        uci commit netmanager
        error "启用失败：规则应用失败，已回滚为关闭状态"
        exit 1
    fi
    china_cron_install
    /etc/init.d/netmanager-china enable 2>/dev/null
    info "中国IPv4访问限制已开启（仅中国大陆IPv4可访问已开放端口）"
}

cmd_china_disable() {
    write_log "INFO" "china_disable: 用户请求关闭中国IPv4访问限制"
    load_config
    china_clear_kernel
    uci set netmanager.settings.china_filter_enable='0'
    uci commit netmanager
    china_cron_remove
    info "中国IPv4访问限制已关闭（境外IPv4可恢复访问）"
}

cmd_china_update() {
    write_log "INFO" "china_update: 用户请求更新中国IPv4列表"
    load_config
    if ! china_download; then
        error "更新失败：下载未成功，保留旧列表"
        exit 1
    fi
    if [ "$(china_get_enable)" = "1" ]; then
        china_apply_rules
    else
        info "功能未启用，仅更新了本地列表，未应用规则"
    fi
}

# v1.8.14：确保 */10 兜底 cron 存在（install.sh 全新安装时会装；
# 恢复/开机路径补建，避免跨机恢复或卸载重装后兜底缺失）
v6sync_cron_ensure() {
    local cr="/etc/crontabs/root"
    mkdir -p /etc/crontabs 2>/dev/null
    [ -f "$cr" ] || touch "$cr"
    grep -qF 'netmanager port_sync_v6' "$cr" 2>/dev/null && return 0
    echo '*/10 * * * * /usr/sbin/netmanager port_sync_v6 --quiet >/dev/null 2>&1' >> "$cr"
    /etc/init.d/cron reload 2>/dev/null
    write_log "INFO" "v6sync: 已补建 */10 兜底 cron"
}

cmd_china_boot() {
    load_config
    # IPv4 白名单
    if [ "$(china_get_enable)" = "1" ]; then
        if [ -f "$CHINA_LIST_FILE" ]; then
            china_apply_rules >/dev/null 2>&1
            write_log "INFO" "china_filter boot: 已重新应用IPv4规则"
        else
            write_log "WARN" "china_filter boot: 已启用但本地列表不存在，跳过重应用"
        fi
    fi
    # IPv6 白名单
    if [ "$(china6_get_enable)" = "1" ]; then
        if [ -f "$CHINA6_LIST_FILE" ]; then
            china6_apply_rules >/dev/null 2>&1
            write_log "INFO" "china6_filter boot: 已重新应用IPv6规则"
        else
            write_log "WARN" "china6_filter boot: 已启用但本地列表不存在，跳过重应用"
        fi
    fi
    # 手动黑名单（nft 表在内存中，重启/防火墙重载后需恢复）
    if [ -s "$BAN_V4_FILE" ] || [ -s "$BAN_V6_FILE" ]; then
        ban_apply_all >/dev/null 2>&1
        write_log "INFO" "blacklist boot: 已重新应用黑名单规则"
    fi
    # v1.8.17：手动白名单（同样只在内存里，需重建）
    if [ -s "$WL_V4_FILE" ] || [ -s "$WL_V6_FILE" ]; then
        wl_apply_all >/dev/null 2>&1
        write_log "INFO" "whitelist boot: 已重新应用白名单规则"
    fi
    # v1.8.14：开机补建 */10 兜底 cron
    v6sync_cron_ensure
    return 0
}

cmd_china_filter() {
    local sub="${1:-status}"
    shift 2>/dev/null
    case "$sub" in
        status)   cmd_china_status ;;
        enable)   cmd_china_enable ;;
        disable)  cmd_china_disable ;;
        update)   cmd_china_update ;;
        set_url)  cmd_china_set_url "$@" ;;
        set_cron) cmd_china_set_cron "$@" ;;
        allow_wan) cmd_china_allow_wan "$@" ;;
        boot)     cmd_china_boot ;;
        *) echo "用法: netmanager china_filter status|enable|disable|update|set_url <url>|set_cron <expr>|allow_wan on|off"; exit 1 ;;
    esac
}

# v1.8.17：是否放行 WAN 口同网段来源（上级光猫/网关等私网邻居）
# 用法: netmanager china_filter allow_wan on|off|status
cmd_china_allow_wan() {
    local v="$1"
    case "$v" in
        on|1|enable)
            uci set netmanager.settings.china_filter_allow_wan_peers='1'
            uci commit netmanager
            info "已开启：放行 WAN 同网段来源（上级光猫/网关可访问）"
            ;;
        off|0|disable)
            uci set netmanager.settings.china_filter_allow_wan_peers='0'
            uci commit netmanager
            info "已关闭：WAN 同网段来源不再放行（严格白名单模式）"
            ;;
        status|'')
            local awp=$(uci get netmanager.settings.china_filter_allow_wan_peers 2>/dev/null)
            [ -z "$awp" ] && awp=1
            echo "ALLOW_WAN_PEERS=$awp"
            echo "WAN_PEERS=$(get_wan_prefixes "$(get_wan_devs)")"
            return 0
            ;;
        *) echo "用法: netmanager china_filter allow_wan on|off|status"; exit 1 ;;
    esac
    # 改完设置后，若规则已启用则立即重应用（要求本地列表存在）
    if [ "$(china_get_enable)" = "1" ] && [ -f "$CHINA_LIST_FILE" ]; then
        china_apply_rules || return 1
        info "规则已重新应用"
    fi
    return 0
}

# ========== 14. 中国IPv6访问限制（v1.7.0 新增） ==========
# 与 IPv4 版本对称：独立 nft 表 inet netmanager6（与 fw4/IPv4 过滤互不影响），
#       内含 china_v6 CIDR 集合 + input/forward 两条 base chain(priority -50)，
#       规则：iifname {wan_devs} ct state new {tcp,udp} 且 ip6 saddr 不在中国集合 -> drop。
#       默认订阅为国内可直连的 ispip.clang.cn 中国 IPv6 地址段（每行一个 CIDR）。
CHINA6_LIST_FILE="$CHINA_LIST_DIR/china_v6.list"
CHINA6_DEFAULT_URL="https://ispip.clang.cn/all_cn_ipv6.txt"
CHINA6_DEFAULT_CRON="0 3 * * 0"
CHINA6_MIN_COUNT=20

china6_get_url() {
    local u=$(uci get netmanager.settings.china6_filter_url 2>/dev/null)
    echo "${u:-$CHINA6_DEFAULT_URL}"
}

china6_get_cron() {
    local c=$(uci get netmanager.settings.china6_filter_cron 2>/dev/null)
    echo "${c:-$CHINA6_DEFAULT_CRON}"
}

china6_get_enable() {
    local e=$(uci get netmanager.settings.china6_filter_enable 2>/dev/null)
    [ "$e" = "1" ] && echo 1 || echo 0
}

# 创建 china_v6 集合（兼容旧版 nft：先 interval,auto-merge，失败降级仅 interval）
china6_create_set() {
    CHINA6_SET_FLAGS=""
    nft add table inet netmanager6 2>/dev/null
    local nft_err
    nft_err=$( ( nft 'add set inet netmanager6 china_v6 { type ipv6_addr; flags interval, auto-merge; }' ) 2>&1 )
    if [ -z "$nft_err" ]; then
        CHINA6_SET_FLAGS="modern"
        return 0
    fi
    case "$nft_err" in
        *auto-merge*)
            write_log "INFO" "china6_filter: 旧版 nft 不支持 auto-merge，降级为 flags interval + 一次性原子加载"
            local nft_err2
            nft_err2=$( ( nft 'add set inet netmanager6 china_v6 { type ipv6_addr; flags interval; }' ) 2>&1 )
            if [ -z "$nft_err2" ]; then
                CHINA6_SET_FLAGS="compat"
                return 0
            fi
            write_log "ERROR" "china6_filter: 降级 add set interval 也失败: $nft_err2"
            error "nft 创建 china_v6 集合失败（降级后）: $nft_err2"
            return 1
            ;;
        *)
            write_log "ERROR" "china6_filter: add set china_v6 失败: $nft_err"
            error "nft 创建 china_v6 集合失败: $nft_err"
            return 1
            ;;
    esac
}

# 载入 IPv6 CIDR 到 china_v6 集合（逻辑同 IPv4 版本）
china6_load_set() {
    [ -f "$CHINA6_LIST_FILE" ] || { echo 0; return; }
    if [ -z "$CHINA6_SET_FLAGS" ]; then
        if nft list table inet netmanager6 >/dev/null 2>&1; then
            :
        else
            nft add table inet netmanager6 2>/dev/null
        fi
        if nft list set inet netmanager6 china_v6 2>/dev/null | grep -q 'auto-merge'; then
            CHINA6_SET_FLAGS="modern"
        elif nft list set inet netmanager6 china_v6 >/dev/null 2>&1; then
            CHINA6_SET_FLAGS="compat"
        else
            china6_create_set || { echo 0; return; }
        fi
    fi

    local clean="/tmp/netmanager_china6_clean.list"
    local ef="/tmp/netmanager_china6_elem.nft"
    local total=0 loaded=0
    local nft_err=""
    rm -f "$clean" "$ef" /tmp/netmanager_china6_nft.err 2>/dev/null

    # 仅保留合法 IPv6 CIDR 行
    grep -E '^[0-9a-fA-F:]+/[0-9]{1,3}$' "$CHINA6_LIST_FILE" > "$clean" 2>/dev/null
    total=$(wc -l < "$clean" 2>/dev/null | tr -d ' ')
    [ "${total:-0}" -lt "$CHINA6_MIN_COUNT" ] && { rm -f "$clean"; echo 0; return; }

    if [ "$CHINA6_SET_FLAGS" = "modern" ]; then
        local batch=500 buf="" buf_n=0 line failed_batches=0
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            if [ "$buf_n" -ge "$batch" ]; then
                {
                    printf 'add element inet netmanager6 china_v6 { %s }\n' "$buf"
                } > "$ef"
                if nft -f "$ef" 2>/tmp/netmanager_china6_nft.err; then
                    loaded=$((loaded + buf_n))
                else
                    nft_err=$(cat /tmp/netmanager_china6_nft.err 2>/dev/null | tr '\n' ' ')
                    failed_batches=$((failed_batches + 1))
                    write_log "WARN" "china6_filter: (modern) nft batch add element failed (size=$buf_n): $nft_err"
                fi
                buf="" buf_n=0
            fi
            if [ "$buf_n" -eq 0 ]; then
                buf="$line"
            else
                buf="$buf, $line"
            fi
            buf_n=$((buf_n + 1))
        done < "$clean"
        if [ "$buf_n" -gt 0 ]; then
            {
                printf 'add element inet netmanager6 china_v6 { %s }\n' "$buf"
            } > "$ef"
            if nft -f "$ef" 2>/tmp/netmanager_china6_nft.err; then
                loaded=$((loaded + buf_n))
            else
                nft_err=$(cat /tmp/netmanager_china6_nft.err 2>/dev/null | tr '\n' ' ')
                failed_batches=$((failed_batches + 1))
                write_log "WARN" "china6_filter: (modern) nft tail batch add element failed (size=$buf_n): $nft_err"
            fi
        fi
        if [ "$failed_batches" -gt 0 ]; then
            write_log "ERROR" "china6_filter: (modern) $failed_batches 批分片加载失败，集合不完整，按整体失败处理（防止残缺集合误杀国内IPv6流量）"
            error "中国IPv6列表分片加载有 $failed_batches 批失败，已中止应用（防止不完整集合误杀国内IPv6流量）"
            rm -f "$clean" "$ef" /tmp/netmanager_china6_nft.err 2>/dev/null
            echo 0
            return
        fi
    else
        {
            printf 'add element inet netmanager6 china_v6 { '
            awk 'BEGIN{ORS=""}{if(NR>1)printf ", ";printf "%s",$0}' "$clean"
            printf ' }\n'
        } > "$ef"
        if nft -f "$ef" 2>/tmp/netmanager_china6_nft.err; then
            loaded="$total"
        else
            nft_err=$(cat /tmp/netmanager_china6_nft.err 2>/dev/null | tr '\n' ' ')
            local ok_rows=0 bad_rows=0 l
            write_log "WARN" "china6_filter: (compat) atomic add element 失败，回退逐行加载: $nft_err"
            while IFS= read -r l; do
                [ -z "$l" ] && continue
                if nft "add element inet netmanager6 china_v6 { $l }" 2>/dev/null; then
                    ok_rows=$((ok_rows + 1))
                else
                    bad_rows=$((bad_rows + 1))
                fi
            done < "$clean"
            loaded="$ok_rows"
            write_log "INFO" "china6_filter: (compat) 逐行回退完成: 成功=$ok_rows 失败=$bad_rows"
        fi
    fi

    rm -f "$clean" "$ef" /tmp/netmanager_china6_nft.err 2>/dev/null
    echo "${loaded:-0}"
}

# 创建表/集合、载入 IPv6 CIDR、安装 input+forward 两条 drop 规则
china6_apply_rules() {
    [ -f "$CHINA6_LIST_FILE" ] || { error "中国IPv6列表文件不存在: $CHINA6_LIST_FILE"; return 1; }
    nft delete table inet netmanager6 2>/dev/null
    local nft_err
    if ! nft add table inet netmanager6 2>/tmp/netmanager_china6_rules.err; then
        nft_err=$(cat /tmp/netmanager_china6_rules.err 2>/dev/null | tr '\n' ' ')
        write_log "ERROR" "china6_filter: add table inet netmanager6 失败: $nft_err"
        rm -f /tmp/netmanager_china6_rules.err 2>/dev/null
        error "nft 创建 inet netmanager6 表失败: $nft_err"
        return 1
    fi
    rm -f /tmp/netmanager_china6_rules.err 2>/dev/null

    CHINA6_SET_FLAGS=""
    if ! china6_create_set; then
        return 1
    fi
    write_log "INFO" "china6_filter: 使用 nft china_v6 集合模式: $CHINA6_SET_FLAGS"

    local count
    count=$(china6_load_set)
    if [ "${count:-0}" -lt "$CHINA6_MIN_COUNT" ]; then
        error "中国IPv6列表载入失败或条数过少($count)，已中止应用规则"
        return 1
    fi

    # v1.8.17：手动白名单并进 china_v6 集合（与 IPv4 对称）
    if [ -n "${WL_V6_FILE:-}" ] && [ -s "$WL_V6_FILE" ]; then
        wl_add_to_set netmanager6 china_v6 "$WL_V6_FILE" || \
            write_log "ERROR" "china6_filter: 手动白名单(IPv6)并入失败"
    fi

    local devs
    devs=$(get_wan_devs)
    if [ -z "$devs" ]; then
        error "未探测到WAN设备，无法安装IPv6过滤规则（请检查 wan 接口/默认路由）"
        return 1
    fi
    local ifname_set
    ifname_set=$(echo "$devs" | awk '{for(i=1;i<=NF;i++){if(i>1)printf ", ";printf "\"%s\"",$i}}')

    # v1.8.17：与 IPv4 对称——放行 WAN 口自身网段与 ULA(fd00::/8) 来源，
    # 避免上级光猫用私网 IPv6（ULA）访问时被当成“境外地址”丢弃
    local allow_peers wan_prefixes6
    allow_peers=$(uci get netmanager.settings.china_filter_allow_wan_peers 2>/dev/null)
    [ -z "$allow_peers" ] && allow_peers=1
    wan_prefixes6=""
    [ "$allow_peers" = "1" ] && wan_prefixes6=$(get_wan_prefixes6 "$devs")

    nft delete chain inet netmanager6 china6_input 2>/dev/null
    nft delete chain inet netmanager6 china6_forward 2>/dev/null

    local rf="/tmp/netmanager_china6_rules.nft"
    {
        echo "add chain inet netmanager6 china6_input { type filter hook input priority -50; policy accept; }"
        echo "add chain inet netmanager6 china6_forward { type filter hook forward priority -50; policy accept; }"
        # v1.7.2 修复：必须在 drop 之前放行 IPv6 控制面流量，
        # 否则 DHCPv6-PD 应答（源为 fe80:: 链路本地）被当作“境外地址”丢弃，
        # 导致前缀续租失败、LAN 设备拿不到/续不上公网 IPv6
        printf 'add rule inet netmanager6 china6_input iifname { %s } ip6 saddr fe80::/10 counter accept\n' "$ifname_set"
        printf 'add rule inet netmanager6 china6_input iifname { %s } ip6 saddr ff00::/8 counter accept\n' "$ifname_set"
        printf 'add rule inet netmanager6 china6_input iifname { %s } udp sport 547 udp dport 546 counter accept\n' "$ifname_set"
        # v1.7.3 修复：forward 链此前完全没有放行规则（v1.7.2 只补了 input 链），
        # 而 NDP relay / DHCPv6 relay 场景下邻居发现与中继应答的源地址同样是
        # 链路本地 fe80::（或组播 ff00::/8），会被「ip6 saddr != @china_v6 drop」
        # 判成境外地址丢弃，导致 LAN 设备地址解析失败、DHCPv6 中继拿不到地址。
        printf 'add rule inet netmanager6 china6_forward iifname { %s } ip6 saddr fe80::/10 counter accept\n' "$ifname_set"
        printf 'add rule inet netmanager6 china6_forward iifname { %s } ip6 saddr ff00::/8 counter accept\n' "$ifname_set"
        printf 'add rule inet netmanager6 china6_forward iifname { %s } udp sport 547 udp dport 546 counter accept\n' "$ifname_set"
        # v1.8.17：WAN 同网段 / ULA 来源放行（须在 drop 之前）
        if [ "$allow_peers" = "1" ]; then
            local pfx6
            printf 'add rule inet netmanager6 china6_input iifname { %s } ip6 saddr fd00::/8 counter accept\n' "$ifname_set"
            printf 'add rule inet netmanager6 china6_forward iifname { %s } ip6 saddr fd00::/8 counter accept\n' "$ifname_set"
            for pfx6 in $wan_prefixes6; do
                printf 'add rule inet netmanager6 china6_input iifname { %s } ip6 saddr %s counter accept\n' "$ifname_set" "$pfx6"
                printf 'add rule inet netmanager6 china6_forward iifname { %s } ip6 saddr %s counter accept\n' "$ifname_set" "$pfx6"
            done
        fi
        printf 'add rule inet netmanager6 china6_forward iifname { %s } ct state new meta l4proto { tcp, udp } ip6 saddr != @china_v6 counter drop\n' "$ifname_set"
        printf 'add rule inet netmanager6 china6_input iifname { %s } ct state new meta l4proto { tcp, udp } ip6 saddr != @china_v6 limit rate 10/minute burst 20 packets log prefix "NM_DROP6: " level warn\n' "$ifname_set"
        printf 'add rule inet netmanager6 china6_input iifname { %s } ct state new meta l4proto { tcp, udp } ip6 saddr != @china_v6 counter drop\n' "$ifname_set"
    } > "$rf"
    if ! nft -f "$rf" 2>/tmp/netmanager_china6_rules.err; then
        write_log "ERROR" "china6_filter: 规则链安装失败: $(cat /tmp/netmanager_china6_rules.err 2>/dev/null | tr '\n' ' ')"
        rm -f "$rf" /tmp/netmanager_china6_rules.err 2>/dev/null
        error "nft IPv6 规则安装失败（nft -f 返回错误）"
        return 1
    fi
    rm -f "$rf" /tmp/netmanager_china6_rules.err 2>/dev/null

    uci set netmanager.settings.china6_filter_count="$count"
    uci commit netmanager 2>/dev/null
    info "中国IPv6过滤规则已应用: 条数=$count WAN设备=[$(echo $devs)]"
    write_log "INFO" "china6_filter apply: count=$count devs=$devs"
    return 0
}

# 下载中国 IPv6 列表（URL 取自配置），校验后存到持久化路径
china6_download() {
    local url=$(china6_get_url)
    local tmp="/tmp/netmanager_china6.tmp"
    info "下载中国IPv6列表: $url"
    write_log "INFO" "china6_filter: 下载 $url"
    mkdir -p "$CHINA_LIST_DIR" 2>/dev/null
    if command -v wget >/dev/null 2>&1; then
        wget -q -T 30 -O "$tmp" "$url" 2>/dev/null
    elif command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q -T 30 -O "$tmp" "$url" 2>/dev/null
    elif command -v curl >/dev/null 2>&1; then
        curl -sS --max-time 30 -o "$tmp" "$url" 2>/dev/null
    else
        error "未找到 wget/uclient-fetch/curl，无法下载"
        return 1
    fi
    if [ ! -s "$tmp" ]; then
        error "下载失败：文件为空或不存在（请检查订阅链接与网络）"
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
    # 纯化：去 BOM、去 CR、仅保留合法 IPv6 CIDR
    local clean="/tmp/netmanager_china6_clean.tmp"
    rm -f "$clean" 2>/dev/null
    if command -v sed >/dev/null 2>&1; then
        sed '1s/^\xef\xbb\xbf//' "$tmp" 2>/dev/null | tr -d '\r' | grep -E '^[0-9a-fA-F:]+/[0-9]{1,3}$' > "$clean" 2>/dev/null
    else
        tr -d '\r' < "$tmp" | grep -E '^[0-9a-fA-F:]+/[0-9]{1,3}$' > "$clean" 2>/dev/null
    fi
    local n
    n=$(wc -l < "$clean" 2>/dev/null | tr -d ' ')
    if [ "${n:-0}" -lt "$CHINA6_MIN_COUNT" ]; then
        error "下载内容不像 IPv6 CIDR 列表（有效行数=$n），已拒绝保存"
        rm -f "$tmp" "$clean" 2>/dev/null
        return 1
    fi
    mv -f "$clean" "$CHINA6_LIST_FILE"
    rm -f "$tmp" 2>/dev/null
    uci set netmanager.settings.china6_filter_count="$n"
    uci set netmanager.settings.china6_filter_last_update="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    uci commit netmanager 2>/dev/null
    info "下载完成：$n 条IPv6 CIDR"
    return 0
}

china6_cron_remove() {
    local cr="/etc/crontabs/root"
    [ -f "$cr" ] || return 0
    grep -v 'netmanager china6_filter update' "$cr" > "$cr.tmp" 2>/dev/null
    mv -f "$cr.tmp" "$cr" 2>/dev/null
    /etc/init.d/cron reload 2>/dev/null
    return 0
}

china6_cron_install() {
    local cr="/etc/crontabs/root"
    mkdir -p /etc/crontabs 2>/dev/null
    [ -f "$cr" ] || touch "$cr"
    china6_cron_remove
    local expr=$(china6_get_cron)
    local fields=$(echo "$expr" | awk '{print NF}')
    if [ "$fields" != "5" ] || echo "$expr" | tr ' ' '\n' | grep -qE '[^0-9*,/\-]'; then
        write_log "ERROR" "china6_filter: UCI 中的 cron 表达式非法: '$expr'，跳过安装 cron"
        warn "cron 表达式非法（$fields 段/含非法字符），已跳过安装，其余功能不受影响"
        return 1
    fi
    echo "$expr /usr/sbin/netmanager china6_filter update" >> "$cr"
    /etc/init.d/cron reload 2>/dev/null
    info "已安装IPv6更新 cron 计划: $expr"
}

cmd_china6_status() {
    load_config
    local en=$(china6_get_enable)
    local url=$(china6_get_url)
    local cron=$(china6_get_cron)
    local lu=$(uci get netmanager.settings.china6_filter_last_update 2>/dev/null)
    local cnt=$(uci get netmanager.settings.china6_filter_count 2>/dev/null)
    [ -z "$cnt" ] && cnt=0
    local devs=$(get_wan_devs)
    [ -z "$devs" ] && devs="(未探测到)"
    local active=0
    if nft list table inet netmanager6 >/dev/null 2>&1; then
        if nft list chain inet netmanager6 china6_forward 2>/dev/null | grep -q 'china_v6'; then
            active=1
        fi
    fi
    echo "===CHINA6_FILTER==="
    echo "CHINA6_FILTER_ENABLED=$en"
    echo "URL=$url"
    echo "CRON=$cron"
    echo "LAST_UPDATE=${lu:-未更新}"
    echo "COUNT=$cnt"
    echo "WAN_DEVS=$devs"
    echo "RULE_ACTIVE=$active"
    echo "LIST_FILE=$CHINA6_LIST_FILE"
    echo "===END==="
}

cmd_china6_set_url() {
    local url="$1"
    [ -z "$url" ] && { error "用法: netmanager china6_filter set_url <url>"; exit 1; }
    case "$url" in
        http://*|https://*) ;;
        *) error "URL 必须以 http:// 或 https:// 开头"; exit 1 ;;
    esac
    load_config
    uci set netmanager.settings.china6_filter_url="$url"
    uci commit netmanager
    info "IPv6订阅链接已保存: $url"
    info "点击「更新IP库」或重新启用以生效"
}

cmd_china6_set_cron() {
    local expr="$1"
    [ -z "$expr" ] && { error "用法: netmanager china6_filter set_cron \"<5段cron表达式>\""; exit 1; }
    local fields=$(echo "$expr" | awk '{print NF}')
    [ "$fields" != "5" ] && { error "cron表达式必须为5段（分 时 日 月 周），当前 $fields 段"; exit 1; }
    if echo "$expr" | tr ' ' '\n' | grep -qE '[^0-9*,/\-]'; then
        error "cron表达式含非法字符（仅允许 0-9 * / , -）"; exit 1
    fi
    load_config
    uci set netmanager.settings.china6_filter_cron="$expr"
    uci commit netmanager
    info "IPv6更新计划已保存: $expr"
    [ "$(china6_get_enable)" = "1" ] && china6_cron_install
}

cmd_china6_enable() {
    write_log "INFO" "china6_enable: 用户请求启用中国IPv6访问限制"
    load_config
    if [ ! -f "$CHINA6_LIST_FILE" ]; then
        china6_download || { error "启用失败：无法获取中国IPv6列表"; exit 1; }
    fi
    uci set netmanager.settings.china6_filter_enable='1'
    uci commit netmanager
    if ! china6_apply_rules; then
        uci set netmanager.settings.china6_filter_enable='0'
        uci commit netmanager
        error "启用失败：规则应用失败，已回滚为关闭状态"
        exit 1
    fi
    china6_cron_install
    /etc/init.d/netmanager-china enable 2>/dev/null
    info "中国IPv6访问限制已开启（仅中国大陆IPv6可访问已开放端口）"
}

cmd_china6_disable() {
    write_log "INFO" "china6_disable: 用户请求关闭中国IPv6访问限制"
    load_config
    nft delete table inet netmanager6 2>/dev/null
    uci set netmanager.settings.china6_filter_enable='0'
    uci commit netmanager
    china6_cron_remove
    info "中国IPv6访问限制已关闭（境外IPv6可恢复访问）"
}

cmd_china6_update() {
    write_log "INFO" "china6_update: 用户请求更新中国IPv6列表"
    load_config
    if ! china6_download; then
        error "更新失败：下载未成功，保留旧列表"
        exit 1
    fi
    if [ "$(china6_get_enable)" = "1" ]; then
        china6_apply_rules
    else
        info "功能未启用，仅更新了本地列表，未应用规则"
    fi
}

cmd_china6_boot() {
    load_config
    [ "$(china6_get_enable)" = "1" ] || return 0
    [ -f "$CHINA6_LIST_FILE" ] || return 0
    china6_apply_rules >/dev/null 2>&1
    write_log "INFO" "china6_filter boot: 已重新应用规则"
}

cmd_china6_filter() {
    local sub="${1:-status}"
    shift 2>/dev/null
    case "$sub" in
        status)   cmd_china6_status ;;
        enable)   cmd_china6_enable ;;
        disable)  cmd_china6_disable ;;
        update)   cmd_china6_update ;;
        set_url)  cmd_china6_set_url "$@" ;;
        set_cron) cmd_china6_set_cron "$@" ;;
        boot)     cmd_china6_boot ;;
        *) echo "用法: netmanager china6_filter status|enable|disable|update|set_url <url>|set_cron <expr>"; exit 1 ;;
    esac
}

# ========== 15. 手动黑名单（IPv4/IPv6，支持单IP与CIDR网段） ==========
# 独立 nft 表 inet netmanager_ban，input/forward 两条 base chain，
# 规则：ip saddr @ban_v4 drop / ip6 saddr @ban_v6 drop（对全部入站与转发流量生效）。
# 条目持久化：/etc/netmanager/blacklist_v4.list、blacklist_v6.list（每行一个 IP 或 CIDR）。
BAN_V4_FILE="$CHINA_LIST_DIR/blacklist_v4.list"
BAN_V6_FILE="$CHINA_LIST_DIR/blacklist_v6.list"

ban_count_file() {
    [ -f "$1" ] || { echo 0; return; }
    grep -c -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null | tr -d ' '
}

ban_valid_v4() {
    local e="$1" addr="" pfx=""
    case "$e" in
        */*)
            addr="${e%%/*}"; pfx="${e##*/}"
            [ -z "$pfx" ] && return 1
            ;;
        *) addr="$e" ;;
    esac
    echo "$addr" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' || return 1
    echo "$addr" | awk -F. '{for(i=1;i<=4;i++){if($i+0>255 || $i ~ /^0[0-9]/) exit 1}}' || return 1
    if [ -n "$pfx" ]; then
        echo "$pfx" | grep -qE '^[0-9]{1,2}$' || return 1
        [ "$pfx" -le 32 ] 2>/dev/null || return 1
    fi
    return 0
}

ban_valid_v6() {
    local e="$1" addr="" pfx=""
    case "$e" in
        */*)
            addr="${e%%/*}"; pfx="${e##*/}"
            [ -z "$pfx" ] && return 1
            ;;
        *) addr="$e" ;;
    esac
    echo "$addr" | grep -qE '^[0-9a-fA-F:]+$' || return 1
    echo "$addr" | grep -q ':' || return 1
    local dc
    dc=$(echo "$addr" | awk '{print gsub(/::/,"::")}')
    [ "${dc:-0}" -le 1 ] || return 1
    echo "$addr" | awk -F: '{for(i=1;i<=NF;i++){g=$i; if(g!="" && (g !~ /^[0-9a-fA-F]+$/ || length(g)>4)) exit 1}}' || return 1
    local groups
    groups=$(echo "$addr" | awk -F: '{c=0; for(i=1;i<=NF;i++) if($i!="") c++; print c}')
    case "$addr" in
        *::*) [ "${groups:-0}" -le 7 ] || return 1 ;;
        *)    [ "${groups:-0}" -eq 8 ] || return 1 ;;
    esac
    if [ -n "$pfx" ]; then
        echo "$pfx" | grep -qE '^[0-9]{1,3}$' || return 1
        [ "$pfx" -le 128 ] 2>/dev/null || return 1
    fi
    return 0
}

# 从文件加载条目到指定集合；返回 0=成功
ban_load_family() {
    local fam="$1" file="$2" mode="$3" set="ban_v4"
    [ "$fam" = "v6" ] && set="ban_v6"
    [ -s "$file" ] || return 0
    local ef="/tmp/netmanager_ban_${fam}_elem.nft"
    local ok=1
    rm -f "$ef" 2>/dev/null

    if [ "$mode" = "modern" ]; then
        # 分片批量添加（auto-merge 容忍重叠网段）
        local batch=500 buf="" buf_n=0 line
        while IFS= read -r line; do
            line=$(echo "$line" | tr -d '\r ')
            case "$line" in ""|"#"*) continue ;; esac
            if [ "$buf_n" -ge "$batch" ]; then
                printf 'add element inet netmanager_ban %s { %s }\n' "$set" "$buf" > "$ef"
                nft -f "$ef" 2>/dev/null || ok=0
                buf="" buf_n=0
            fi
            if [ "$buf_n" -eq 0 ]; then buf="$line"; else buf="$buf, $line"; fi
            buf_n=$((buf_n + 1))
        done < "$file"
        if [ "$buf_n" -gt 0 ]; then
            printf 'add element inet netmanager_ban %s { %s }\n' "$set" "$buf" > "$ef"
            nft -f "$ef" 2>/dev/null || ok=0
        fi
    else
        # 无 auto-merge：整段一次性原子添加，让内核合并可能重叠的网段
        {
            printf 'add element inet netmanager_ban %s { ' "$set"
            awk 'NF && $1 !~ /^#/ {printf "%s%s", (c++ ? ", " : ""), $1}' "$file"
            printf ' }\n'
        } > "$ef"
        if ! nft -f "$ef" 2>/dev/null; then
            # 回退逐条添加（重叠网段可能失败，但至少加载可用的部分）
            local okr=0 l
            while IFS= read -r l; do
                l=$(echo "$l" | tr -d '\r ')
                case "$l" in ""|"#"*) continue ;; esac
                nft "add element inet netmanager_ban $set { $l }" 2>/dev/null && okr=$((okr + 1))
            done < "$file"
            [ "$okr" -gt 0 ] || ok=0
        fi
    fi
    rm -f "$ef" 2>/dev/null
    [ "$ok" = "1" ]
}

# 重建黑名单表与规则
ban_apply_all() {
    mkdir -p "$CHINA_LIST_DIR" 2>/dev/null
    local v4n v6n
    v4n=$(ban_count_file "$BAN_V4_FILE")
    v6n=$(ban_count_file "$BAN_V6_FILE")
    [ -z "$v4n" ] && v4n=0
    [ -z "$v6n" ] && v6n=0

    # 无条目：删除黑名单表即可（幂等）
    if [ "$v4n" -eq 0 ] && [ "$v6n" -eq 0 ]; then
        nft delete table inet netmanager_ban 2>/dev/null
        write_log "INFO" "blacklist apply: 无条目，已清空表"
        return 0
    fi

    nft delete table inet netmanager_ban 2>/dev/null
    if ! nft add table inet netmanager_ban 2>/dev/null; then
        error "创建黑名单 nft 表失败（nft 不可用？）"
        return 1
    fi

    local m4="compat" m6="compat"
    if nft 'add set inet netmanager_ban ban_v4 { type ipv4_addr; flags interval, auto-merge; }' 2>/dev/null; then
        m4="modern"
    elif ! nft 'add set inet netmanager_ban ban_v4 { type ipv4_addr; flags interval; }' 2>/dev/null; then
        error "创建 IPv4 黑名单集合失败"
        return 1
    fi
    if nft 'add set inet netmanager_ban ban_v6 { type ipv6_addr; flags interval, auto-merge; }' 2>/dev/null; then
        m6="modern"
    elif ! nft 'add set inet netmanager_ban ban_v6 { type ipv6_addr; flags interval; }' 2>/dev/null; then
        error "创建 IPv6 黑名单集合失败"
        return 1
    fi

    if ! nft 'add chain inet netmanager_ban ban_input { type filter hook input priority -50; policy accept; }' 2>/dev/null || \
       ! nft 'add chain inet netmanager_ban ban_forward { type filter hook forward priority -50; policy accept; }' 2>/dev/null; then
        error "创建黑名单过滤链失败"
        return 1
    fi

    if ! ban_load_family v4 "$BAN_V4_FILE" "$m4"; then
        error "IPv4 黑名单条目加载失败（可能存在非法或重叠网段）"
        return 1
    fi
    if ! ban_load_family v6 "$BAN_V6_FILE" "$m6"; then
        error "IPv6 黑名单条目加载失败（可能存在非法或重叠网段）"
        return 1
    fi

    if ! nft add rule inet netmanager_ban ban_input ip saddr @ban_v4 counter drop 2>/dev/null || \
       ! nft add rule inet netmanager_ban ban_input ip6 saddr @ban_v6 counter drop 2>/dev/null || \
       ! nft add rule inet netmanager_ban ban_forward ip saddr @ban_v4 counter drop 2>/dev/null || \
       ! nft add rule inet netmanager_ban ban_forward ip6 saddr @ban_v6 counter drop 2>/dev/null; then
        error "安装黑名单 drop 规则失败"
        return 1
    fi

    info "黑名单规则已应用: IPv4=$v4n 条 IPv6=$v6n 条"
    write_log "INFO" "blacklist apply: v4=$v4n v6=$v6n"
    return 0
}

cmd_ban_list() {
    local v4="" v6="" v4n=0 v6n=0 active=0
    v4n=$(ban_count_file "$BAN_V4_FILE")
    v6n=$(ban_count_file "$BAN_V6_FILE")
    [ -z "$v4n" ] && v4n=0
    [ -z "$v6n" ] && v6n=0
    if [ -f "$BAN_V4_FILE" ]; then
        v4=$(grep -vE '^[[:space:]]*(#|$)' "$BAN_V4_FILE" 2>/dev/null | tr '\n' ',')
        v4=${v4%,}
    fi
    if [ -f "$BAN_V6_FILE" ]; then
        v6=$(grep -vE '^[[:space:]]*(#|$)' "$BAN_V6_FILE" 2>/dev/null | tr '\n' ',')
        v6=${v6%,}
    fi
    nft list table inet netmanager_ban >/dev/null 2>&1 && active=1
    echo "===BLACKLIST==="
    echo "V4_COUNT=$v4n"
    echo "V6_COUNT=$v6n"
    echo "V4=$v4"
    echo "V6=$v6"
    echo "ACTIVE=$active"
    echo "===END==="
}

cmd_ban_add() {
    # 【v1.7.1 修复】不能使用 tr -d '[:space:]'：部分 BusyBox tr 会把该集合按字面字符
    # 解析（连 ': s p a c e [ ]' 一起删除），导致 IPv6 地址被吞掉冒号后误判为 IPv4
    local entry=$(printf '%s' "$1" | tr -d ' \t\r\n')
    [ -z "$entry" ] && { error "用法: netmanager blacklist add <IPv4/IPv6 地址或CIDR>"; exit 1; }
    local fam file
    case "$entry" in
        *:*)
            fam="v6"; file="$BAN_V6_FILE"
            ban_valid_v6 "$entry" || { error "非法 IPv6 地址/网段: $entry"; exit 1; }
            ;;
        *)
            fam="v4"; file="$BAN_V4_FILE"
            ban_valid_v4 "$entry" || { error "非法 IPv4 地址/网段: $entry"; exit 1; }
            ;;
    esac
    mkdir -p "$CHINA_LIST_DIR" 2>/dev/null
    [ -f "$file" ] || touch "$file"
    if grep -Fxq "$entry" "$file" 2>/dev/null; then
        info "条目已存在: $entry"
        return 0
    fi
    echo "$entry" >> "$file"
    if ! ban_apply_all >/dev/null 2>&1; then
        # 应用失败 → 回滚文件
        grep -Fxv "$entry" "$file" > "$file.tmp" 2>/dev/null
        mv -f "$file.tmp" "$file" 2>/dev/null
        ban_apply_all >/dev/null 2>&1
        error "添加失败：nft 规则应用失败（请检查地址格式或 nft 版本）"
        exit 1
    fi
    info "已拉黑 $fam 条目: $entry"
}

cmd_ban_del() {
    # 【v1.7.1 修复】不能使用 tr -d '[:space:]'：部分 BusyBox tr 会把该集合按字面字符
    # 解析（连 ': s p a c e [ ]' 一起删除），导致 IPv6 地址被吞掉冒号后误判为 IPv4
    local entry=$(printf '%s' "$1" | tr -d ' \t\r\n')
    [ -z "$entry" ] && { error "用法: netmanager blacklist del <IPv4/IPv6 地址或CIDR>"; exit 1; }
    local file found=0
    case "$entry" in
        *:*) file="$BAN_V6_FILE" ;;
        *)   file="$BAN_V4_FILE" ;;
    esac
    if [ -f "$file" ] && grep -Fxq "$entry" "$file" 2>/dev/null; then
        grep -Fxv "$entry" "$file" > "$file.tmp" 2>/dev/null
        mv -f "$file.tmp" "$file" 2>/dev/null
        ban_apply_all >/dev/null 2>&1
        found=1
    fi
    [ "$found" = "1" ] || { error "条目不存在: $entry"; exit 1; }
    info "已移除黑名单条目: $entry"
}

cmd_ban_clear() {
    local target="${1:-all}"
    mkdir -p "$CHINA_LIST_DIR" 2>/dev/null
    case "$target" in
        v4)  : > "$BAN_V4_FILE" ;;
        v6)  : > "$BAN_V6_FILE" ;;
        all) : > "$BAN_V4_FILE"; : > "$BAN_V6_FILE" ;;
        *) error "用法: netmanager blacklist clear [v4|v6|all]"; exit 1 ;;
    esac
    ban_apply_all >/dev/null 2>&1
    info "已清空黑名单: $target"
}

cmd_blacklist() {
    local sub="${1:-list}"
    shift 2>/dev/null
    case "$sub" in
        list)            cmd_ban_list ;;
        add)             cmd_ban_add "$@" ;;
        del|remove)      cmd_ban_del "$@" ;;
        clear)           cmd_ban_clear "$@" ;;
        apply|boot)      ban_apply_all ;;
        *) echo "用法: netmanager blacklist list|add <ip/cidr>|del <ip/cidr>|clear [v4|v6|all]|apply"; exit 1 ;;
    esac
}


# ========== 15.5 手动白名单（v1.8.17，IPv4/IPv6 双栈，支持单IP与CIDR） ==========
# 作用：给「中国IPv4/IPv6访问限制」开例外——白名单里的 IP/网段会被并进
#       inet netmanager china_v4 / inet netmanager6 china_v6 集合，等价于“人工补充的允许列表”，
#       这些来源就不再命中 `ip saddr != @china_v4 drop`。
# 为什么不用独立的 -60 accept 链：netfilter 的 NF_ACCEPT 只结束当前 base chain，
#       同一 hook 上其它 base chain 仍会继续执行（-50 的中国过滤照样丢包）。
#       真机实测：独立 accept 链的计数在涨、中国过滤的 drop 计数同时在涨，包还是进不来。
# 只在中国IP限制启用时生效（未启用时白名单仅保存条目，不起作用）。
# 条目持久化：/etc/netmanager/whitelist_v4.list、whitelist_v6.list（每行一个 IP 或 CIDR）。
WL_V4_FILE="$CHINA_LIST_DIR/whitelist_v4.list"
WL_V6_FILE="$CHINA_LIST_DIR/whitelist_v6.list"

wl_count_file() {
    [ -f "$1" ] || { echo 0; return; }
    grep -c -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null | tr -d ' '
}

# 把白名单文件并进指定集合：$1=table $2=set $3=文件
# 先整段原子添加（重叠网段交给内核合并），失败再逐条回退
wl_add_to_set() {
    local table="$1" set="$2" file="$3"
    [ -s "$file" ] || return 0
    local ef="/tmp/netmanager_wl_${set}_elem.nft" ok=1 l okr=0
    rm -f "$ef" 2>/dev/null
    {
        printf 'add element inet %s %s { ' "$table" "$set"
        awk 'NF && $1 !~ /^#/ {printf "%s%s", (c++ ? ", " : ""), $1}' "$file"
        printf ' }\n'
    } > "$ef"
    if ! nft -f "$ef" 2>/dev/null; then
        ok=0
        while IFS= read -r l; do
            l=$(echo "$l" | tr -d '\r ')
            case "$l" in ""|"#"*) continue ;; esac
            nft "add element inet $table $set { $l }" 2>/dev/null && okr=$((okr + 1))
        done < "$file"
        [ "$okr" -gt 0 ] && ok=1
    fi
    rm -f "$ef" 2>/dev/null
    [ "$ok" = "1" ] || { write_log "ERROR" "whitelist: 并入集合失败 table=$table set=$set file=$file"; return 1; }
    return 0
}

# 应用白名单：重建已启用的中国IP规则（重建时会把白名单并入集合，删条目也随之移除）
wl_apply_all() {
    mkdir -p "$CHINA_LIST_DIR" 2>/dev/null
    # 清理 v1.8.17 早期版本留下的独立表（改用集合注入方案后不再需要）
    nft delete table inet netmanager_wl 2>/dev/null

    local v4n v6n en4 en6 rc=0
    v4n=$(wl_count_file "$WL_V4_FILE"); [ -z "$v4n" ] && v4n=0
    v6n=$(wl_count_file "$WL_V6_FILE"); [ -z "$v6n" ] && v6n=0
    en4=$(china_get_enable)
    en6=$(china6_get_enable)

    if [ "$en4" = "1" ] && [ -f "$CHINA_LIST_FILE" ]; then
        china_apply_rules >/dev/null 2>&1 || rc=1
    fi
    if [ "$en6" = "1" ] && [ -f "$CHINA6_LIST_FILE" ]; then
        china6_apply_rules >/dev/null 2>&1 || rc=1
    fi

    write_log "INFO" "whitelist apply: v4=$v4n v6=$v6n china4=$en4 china6=$en6"
    if [ "$rc" != "0" ]; then
        error "白名单应用失败：中国IP规则重应用出错（条目已保存，可稍后 whitelist apply 重试）"
        return 1
    fi
    if [ "$en4" != "1" ] && [ "$en6" != "1" ]; then
        info "白名单已保存（IPv4=$v4n / IPv6=$v6n），但中国IP限制未启用，规则暂不生效"
    else
        info "白名单已生效: IPv4=$v4n 条 IPv6=$v6n 条（已并入中国IP集合）"
    fi
    return 0
}

cmd_wl_list() {
    local v4="" v6="" v4n=0 v6n=0 active=0
    v4n=$(wl_count_file "$WL_V4_FILE"); [ -z "$v4n" ] && v4n=0
    v6n=$(wl_count_file "$WL_V6_FILE"); [ -z "$v6n" ] && v6n=0
    [ -f "$WL_V4_FILE" ] && { v4=$(grep -vE '^[[:space:]]*(#|$)' "$WL_V4_FILE" 2>/dev/null | tr '\n' ','); v4=${v4%,}; }
    [ -f "$WL_V6_FILE" ] && { v6=$(grep -vE '^[[:space:]]*(#|$)' "$WL_V6_FILE" 2>/dev/null | tr '\n' ','); v6=${v6%,}; }
    nft list set inet netmanager china_v4 >/dev/null 2>&1 && active=1
    nft list set inet netmanager6 china_v6 >/dev/null 2>&1 && active=1
    echo "===WHITELIST==="
    echo "V4_COUNT=$v4n"
    echo "V6_COUNT=$v6n"
    echo "V4=$v4"
    echo "V6=$v6"
    echo "ACTIVE=$active"
    echo "===END==="
}

cmd_wl_add() {
    local entry=$(printf '%s' "$1" | tr -d ' \t\r\n')
    [ -z "$entry" ] && { error "用法: netmanager whitelist add <IPv4/IPv6 地址或CIDR>"; exit 1; }
    local fam file
    case "$entry" in
        *:*)
            fam="v6"; file="$WL_V6_FILE"
            ban_valid_v6 "$entry" || { error "非法 IPv6 地址/网段: $entry"; exit 1; }
            ;;
        *)
            fam="v4"; file="$WL_V4_FILE"
            ban_valid_v4 "$entry" || { error "非法 IPv4 地址/网段: $entry"; exit 1; }
            ;;
    esac
    mkdir -p "$CHINA_LIST_DIR" 2>/dev/null
    [ -f "$file" ] || touch "$file"
    if grep -Fxq "$entry" "$file" 2>/dev/null; then
        info "条目已存在: $entry"
        return 0
    fi
    echo "$entry" >> "$file"
    if ! wl_apply_all >/dev/null 2>&1; then
        grep -Fxv "$entry" "$file" > "$file.tmp" 2>/dev/null
        mv -f "$file.tmp" "$file" 2>/dev/null
        wl_apply_all >/dev/null 2>&1
        error "添加失败：nft 规则应用失败（请检查地址格式或 nft 版本）"
        exit 1
    fi
    info "已加入白名单 $fam 条目: $entry"
}

cmd_wl_del() {
    local entry=$(printf '%s' "$1" | tr -d ' \t\r\n')
    [ -z "$entry" ] && { error "用法: netmanager whitelist del <IPv4/IPv6 地址或CIDR>"; exit 1; }
    local file found=0
    case "$entry" in
        *:*) file="$WL_V6_FILE" ;;
        *)   file="$WL_V4_FILE" ;;
    esac
    if [ -f "$file" ] && grep -Fxq "$entry" "$file" 2>/dev/null; then
        grep -Fxv "$entry" "$file" > "$file.tmp" 2>/dev/null
        mv -f "$file.tmp" "$file" 2>/dev/null
        wl_apply_all >/dev/null 2>&1
        found=1
    fi
    [ "$found" = "1" ] || { error "条目不存在: $entry"; exit 1; }
    info "已移除白名单条目: $entry"
}

cmd_wl_clear() {
    local target="${1:-all}"
    mkdir -p "$CHINA_LIST_DIR" 2>/dev/null
    case "$target" in
        v4)  : > "$WL_V4_FILE" ;;
        v6)  : > "$WL_V6_FILE" ;;
        all) : > "$WL_V4_FILE"; : > "$WL_V6_FILE" ;;
        *) error "用法: netmanager whitelist clear [v4|v6|all]"; exit 1 ;;
    esac
    wl_apply_all >/dev/null 2>&1
    info "已清空白名单: $target"
}

cmd_whitelist() {
    local sub="${1:-list}"
    shift 2>/dev/null
    case "$sub" in
        list)            cmd_wl_list ;;
        add)             cmd_wl_add "$@" ;;
        del|remove)      cmd_wl_del "$@" ;;
        clear)           cmd_wl_clear "$@" ;;
        apply|boot)      wl_apply_all ;;
        *) echo "用法: netmanager whitelist list|add <ip/cidr>|del <ip/cidr>|clear [v4|v6|all]|apply"; exit 1 ;;
    esac
}


# ========== 16. 卸载插件 ==========
# 用法: netmanager uninstall [full|keep]
#   full = 全删（后端/LuCI/CBI模型/配置/CIDR/DNS配置与脚本/init/hotplug/缓存）
#   keep = 保留 /etc/config/netmanager、/etc/netmanager/ 与 /etc/config/dnssettings，其余全删
# 卸载后由后台子进程延迟2秒自删 /usr/sbin/netmanager 并重启 uhttpd（让本次响应先完整返回）
cmd_uninstall() {
    local mode="${1:-full}"
    local keep_config=0
    [ "$mode" = "keep" ] && keep_config=1

    info "开始卸载网络管理插件 (mode=$mode)..."
    write_log "INFO" "uninstall: 开始卸载 (mode=$mode keep_config=$keep_config)"

    # 1. 先关闭中国IPv4/IPv6过滤与黑名单：清nft规则 + 移除cron + 删表
    echo "[1/8] 关闭中国IPv4/IPv6过滤与手动黑名单（清理nft规则、移除cron）..."
    cmd_china_disable >/dev/null 2>&1
    cmd_china6_disable >/dev/null 2>&1
    nft delete table inet netmanager 2>/dev/null
    nft delete table inet netmanager6 2>/dev/null
    nft delete table inet netmanager_ban 2>/dev/null
    nft delete table inet netmanager_wl 2>/dev/null
    crontab -l 2>/dev/null | grep -v 'netmanager china_filter' | grep -v 'netmanager china6_filter' | crontab - 2>/dev/null

    # 2. 停止并禁用开机自启
    echo "[2/8] 停止并禁用 init 服务..."
    /etc/init.d/netmanager-china stop 2>/dev/null
    /etc/init.d/netmanager-china disable 2>/dev/null

    # 3. 删除 init / hotplug 脚本与 DNS 管理脚本
    echo "[3/8] 删除 init/hotplug 脚本与 DNS 管理脚本..."
    rm -f /etc/init.d/netmanager-china
    rm -f /etc/hotplug.d/iface/95-netmanager-china
    rm -f /etc/hotplug.d/iface/96-netmanager-v6sync
    # v1.8.3：移除 IPv6 目标同步定时任务
    if [ -f /etc/crontabs/root ] && grep -qF 'netmanager port_sync_v6' /etc/crontabs/root 2>/dev/null; then
        grep -vF 'netmanager port_sync_v6' /etc/crontabs/root > /tmp/.nm_cron 2>/dev/null
        cat /tmp/.nm_cron > /etc/crontabs/root
        rm -f /tmp/.nm_cron
        /etc/init.d/cron restart >/dev/null 2>&1
    fi
    rm -f /usr/sbin/dnssettings-apply.sh
    rm -f /usr/sbin/dnssettings-backup.sh

    # 4. 删除 LuCI 控制器、CBI 模型与视图页面
    echo "[4/8] 删除 LuCI 控制器/CBI模型/视图页面..."
    rm -f /usr/lib/lua/luci/controller/netmanager.lua
    rm -rf /usr/lib/lua/luci/model/cbi/netmanager
    rm -rf /usr/lib/lua/luci/view/netmanager

    # 5. 删除配置与CIDR列表（保留模式下跳过）
    echo "[5/8] 删除配置与CIDR列表..."
    if [ "$keep_config" = "1" ]; then
        echo "  (保留模式：保留 /etc/config/netmanager、/etc/netmanager/ 与 /etc/config/dnssettings)"
    else
        rm -f /etc/config/netmanager
        rm -rf /etc/netmanager
        rm -f /etc/config/dnssettings
    fi

    # 6. 清理临时文件与缓存
    echo "[6/8] 清理临时文件与缓存..."
    rm -f /bin/netmanager 2>/dev/null
    rm -f /tmp/.netmanager_nft_dstnat 2>/dev/null
    rm -rf /tmp/netmanager 2>/dev/null
    rm -rf /tmp/netmanager_upload 2>/dev/null
    rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null
    # 【v1.4.6】不再删除 /tmp/luci-sessions（会踢掉所有已登录用户，包括正在执行卸载的会话）

    # 7. 输出卸载完成摘要
    echo "[7/8] 卸载完成。"
    echo ""
    echo "===UNINSTALL_DONE==="
    echo "已删除："
    echo "  - /usr/lib/lua/luci/controller/netmanager.lua"
    echo "  - /usr/lib/lua/luci/model/cbi/netmanager/ (DNS设置与静态IPv6 CBI模型)"
    echo "  - /usr/lib/lua/luci/view/netmanager/ (全部视图)"
    echo "  - /etc/init.d/netmanager-china"
    echo "  - /etc/hotplug.d/iface/95-netmanager-china"
    echo "  - /usr/sbin/dnssettings-apply.sh /usr/sbin/dnssettings-backup.sh"
    if [ "$keep_config" = "1" ]; then
        echo "  - (保留) /etc/config/netmanager"
        echo "  - (保留) /etc/netmanager/"
        echo "  - (保留) /etc/config/dnssettings"
    else
        echo "  - /etc/config/netmanager"
        echo "  - /etc/netmanager/"
        echo "  - /etc/config/dnssettings"
    fi
    echo "  - nft 表 inet netmanager / inet netmanager6 / inet netmanager_ban（IPv4/IPv6过滤与黑名单规则）"
    echo "  - crontab 中国IPv4/IPv6过滤计划任务"
    echo "  - /tmp/netmanager* 临时文件与缓存"
    echo ""
    echo "用户在 /etc/config/firewall 中的端口转发与防火墙规则不受影响，保留不动。"
    write_log "INFO" "uninstall: 文件清理完成，2秒后自删后端脚本并重启uhttpd"

    # 8. 后台延迟2秒：删除自身 + 重启uhttpd（确保本次响应能完整返回浏览器）
    echo "[8/8] 2秒后将自动删除后端脚本 /usr/sbin/netmanager 并重启 uhttpd..."
    (
        sleep 2
        rm -f /usr/sbin/netmanager
        rm -f /bin/netmanager 2>/dev/null
        /etc/init.d/uhttpd restart >/dev/null 2>&1
        # 【v1.4.6】保留 /tmp/luci-sessions：删掉会踢掉所有已登录用户（含刚执行卸载的会话）
        rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null
    ) >/dev/null 2>&1 &
}

# ========== 主入口 ==========
usage() {
    echo "网络管理插件"
    echo ""
    echo "用法: netmanager <命令> [参数]"
    echo ""
    echo "系统: overview | version | settings"
    echo "端口转发: port_list | port_add <端口> <proto> [目标] [v4|v6|both] [内部端口] | port_del <端口> [proto] [v4|v6|both] | port_edit | set_default_target"
    echo "IPv6目标跟踪: port_track_v6 <端口> <tcp|udp> <锚点|off> | port_sync_v6 [--quiet]"
    echo "IPv6网关自愈: v6gw [--quiet]   # 补pppoe默认路由 + 强制ra_default=1"
    echo "防火墙规则: rule_list | rule_add | rule_del | rule_edit"
    echo "日志: ssh_log [行数] | access_log [端口] [行数] | log_set 0/1 | log_get [行数] | log_clear"
    echo "操作: restart | reload"
    echo "备份: backup | backup_list | backup_restore <文件> | backup_delete <文件> | backup_import <文件> | backup_prune [保留数]"
    echo "插件: upload_file <文件名> <b64文件> | plugin_update <文件> | plugin_version <文件> | cleanup_uploads"
    echo "在线更新: update_check | update_apply | set_update_mirror <url|''>"
    echo "中国IPv4过滤: china_filter status | enable | disable | update | set_url <url> | set_cron <expr> | allow_wan on|off"
    echo "中国IPv6过滤: china6_filter status | enable | disable | update | set_url <url> | set_cron <expr>"
    echo "手动黑名单: blacklist list | add <ip/cidr> | del <ip/cidr> | clear [v4|v6|all] | apply"
    echo "手动白名单: whitelist list | add <ip/cidr> | del <ip/cidr> | clear [v4|v6|all] | apply"
    echo "手动白名单: whitelist list | add <ip/cidr> | del <ip/cidr> | clear [v4|v6|all] | apply   # 绕过中国IPv4/IPv6限制"
    echo "卸载: uninstall [full|keep]   # full=全删(默认) keep=保留配置与备份"
}

case "$1" in
    overview)           cmd_overview ;;
    version)            cmd_version ;;
    settings)           cmd_settings ;;
    port_list)          cmd_port_list ;;
    port_add)           shift; cmd_port_add "$@" ;;
    port_del)           shift; cmd_port_del "$@" ;;
    port_edit)          shift; cmd_port_edit "$@" ;;
    port_track_v6)      shift; cmd_port_track_v6 "$@" ;;
    port_sync_v6)       shift; cmd_port_sync_v6 "$@" ;;
    v6gw)               shift; cmd_v6gw "$@" ;;
    set_default_target) shift; cmd_set_default_target "$@" ;;
    rule_list)          cmd_rule_list ;;
    rule_add)           shift; cmd_rule_add "$@" ;;
    rule_del)           shift; cmd_rule_del "$@" ;;
    rule_edit)          shift; cmd_rule_edit "$@" ;;
    rule_toggle)        shift; cmd_rule_toggle "$@" ;;
    ssh_log)            shift; cmd_ssh_log "$@" ;;
    access_log)         shift; cmd_access_log "$@" ;;
    block_detail)       shift; cmd_block_detail "$@" ;;
    static_bind)        shift; cmd_static_bind "$@" ;;
    static_unbind)      shift; cmd_static_unbind "$@" ;;
    log_set)            shift; cmd_log_set "$@" ;;
    log_get)            shift; cmd_log_get "$@" ;;
    log_query)          shift; cmd_log_query "$@" ;;
    log_export)         cmd_log_export ;;
    log_clear)          cmd_log_clear ;;
    restart)            cmd_restart ;;
    reload)             cmd_reload ;;
    backup)             cmd_backup ;;
    backup_list)        cmd_backup_list ;;
    backup_restore)     shift; cmd_backup_restore "$@" ;;
    backup_delete)      shift; cmd_backup_delete "$@" ;;
    backup_import)      shift; cmd_backup_import "$@" ;;
    backup_prune)       shift; cmd_backup_prune "$@" ;;
    upload_file)        shift; cmd_upload_file "$@" ;;
    plugin_update)      shift; cmd_plugin_update "$@" ;;
    plugin_version)     shift; cmd_plugin_version "$@" ;;
    cleanup_uploads)    cmd_cleanup_uploads ;;
    update_check)       cmd_update_check ;;
    update_apply)       cmd_update_apply ;;
    set_update_mirror)  shift; cmd_set_update_mirror "$@" ;;
    china_filter)       shift; cmd_china_filter "$@" ;;
    china6_filter)      shift; cmd_china6_filter "$@" ;;
    blacklist)          shift; cmd_blacklist "$@" ;;
    whitelist)          shift; cmd_whitelist "$@" ;;
    uninstall)          shift; cmd_uninstall "$@" ;;
    *)                  usage ;;
esac


```

### 5.2 files/usr/sbin/dnssettings-apply.sh

- **用途**：上网设置应用脚本：把 /etc/config/dnssettings 写入 network/dhcp/dnsmasq 并 reload 服务
- **规模**：540 行
- **维护要点**：空值断网防护（peerdns=0 且 DNS 全空 → 拒写）是核心红线，勿删；应用前自动备份保留 5 份

```bash
#!/bin/sh
# ============================================================
# DNS设置插件 - 应用配置脚本 (v1.8.6)
# 读取 /etc/config/dnssettings，写入系统 network/dhcp 配置并重载服务
#
# v1.7.3 更新：
#   1. 【关键】PPPoE 场景下自动修正 network.wan6.device：
#      wan6 若与 wan 绑在同一物理网口，DHCPv6 客户端发不出 SOLICIT/RS
#      （syslog: "Failed to send SOLICIT ... (Address not available)"），
#      PD 前缀续租失败后 LAN 设备会丢失公网 IPv6。
#      现检测 wan.proto=pppoe 且 wan6.device==wan.device 时改为 @wan，
#      修正后自动 ifup wan6 重新协商，并在日志中回显 PD 获取结果。
#
# v1.4.6 更新：
#   1. WAN 接口自动探测（用户配置 → 默认路由反查 → 兜底 wan/wan6），
#      不再硬编码 network.wan / network.wan6
#   2. dhcp_option 改 delete + add_list 正确写法（list 类型）
#   3. PPPoE 双栈 fallback 并入 wan.dns 前先 delete 全量重写去重
#      （修复重复应用时 add_list 逐次累积）
#   4. logger 输出过滤控制字符（防 syslog 注入转义序列）
#
# v1.4.5 防护逻辑（修复空值断网）：
#   1. peerdns=0 但自定义 DNS 全空 → 拒绝写入该接口（保持现状），
#      否则路由器将失去全部上游解析导致断网
#   2. list 字段（network.wan.dns 等）改用 delete + add_list 正确写法，
#      切换配置时先清残留，不再 set 单元素覆盖
#   3. dnsmasq 转发关闭时清空旧 server 列表，使"关闭"真正生效
#   4. 应用前自动备份 network/dhcp 到 /root/backup/（保留最近 3 份）
# ============================================================

CONFIG_FILE="/etc/config/dnssettings"
LOG_TAG="dnssettings"
BACKUP_DIR="/root/backup"

# 【v1.4.6】logger 过滤控制字符：防止配置值中的转义序列污染 syslog/终端
log() {
    local msg
    msg=$(printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037')
    logger -t "$LOG_TAG" "$msg"
    echo "[$LOG_TAG] $msg"
}

# 检查配置文件是否存在
if [ ! -f "$CONFIG_FILE" ]; then
    log "ERROR: 配置文件 $CONFIG_FILE 不存在"
    exit 1
fi

# ============================================================
# 【v1.4.6】WAN 接口自动探测
# 优先级：1. dnssettings.wan.wan_iface / wan6_iface 用户显式配置
#         2. 默认路由所在接口反查 network 节名
#         3. 兜底 wan / wan6（保持旧版行为）
# ============================================================
iface_from_route() {
    # $1: -4 或 -6；输出默认路由 dev 对应的 network 节名（找不到则空）
    local rt_dev family
    family="$1"
    rt_dev=$(ip "$family" route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ -z "$rt_dev" ] && return
    # 遍历 network 接口节，匹配 device/ifname/name
    local idx=0 name dev
    while uci -q get "network.@interface[$idx]" >/dev/null 2>&1; do
        name=$(uci -q get "network.@interface[$idx]" 2>/dev/null | awk -F. '{print $2}')
        dev=$(uci -q get "network.@interface[$idx].device" 2>/dev/null)
        [ -z "$dev" ] && dev=$(uci -q get "network.@interface[$idx].ifname" 2>/dev/null)
        # device 可能是 logical 或 physical 名，任一命中即可
        if [ "$dev" = "$rt_dev" ] || [ "$name" = "$rt_dev" ]; then
            echo "$name"
            return
        fi
        idx=$((idx+1))
    done

    # 【v1.8.3 修复】路由设备名不等于 UCI 节名的情况。
    # PPPoE 下默认路由 dev 是 pppoe-wan，而 UCI 节名是 wan；
    # 旧版这里直接 echo "$rt_dev"，导致后续 uci get network.pppoe-wan 失败、
    # WAN DNS 整段被跳过（这是「页面配置与实际 DNS 不一致」的根因）。
    case "$rt_dev" in
        pppoe-*)
            name=${rt_dev#pppoe-}
            if uci -q get "network.$name" >/dev/null 2>&1; then
                echo "$name"
                return
            fi
            ;;
    esac

    # 再用 netifd 运行时信息反查（覆盖 VLAN / 桥接 / 别名等场景）
    if command -v ubus >/dev/null 2>&1; then
        name=$(ubus call network.interface dump 2>/dev/null \
            | awk -v d="$rt_dev" '
                /"interface"/ { i=$0; gsub(/.*"interface": *"|",?$/,"",i) }
                /"device"/ { v=$0; gsub(/.*"device": *"|",?$/,"",v); if (v==d) { print i; exit } }
            ')
        if [ -n "$name" ] && uci -q get "network.$name" >/dev/null 2>&1; then
            echo "$name"
            return
        fi
    fi

    # 无法映射到 UCI 节名时返回空，由调用方兜底，绝不返回非法节名
    return
}

detect_wan_iface() {
    # $1: 4 或 6
    local custom rt fallback
    if [ "$1" = "4" ]; then
        fallback="wan"
        custom=$(uci -q get dnssettings.wan.wan_iface 2>/dev/null)
        [ -n "$custom" ] && uci -q get "network.$custom" >/dev/null 2>&1 && { echo "$custom"; return; }
        rt=$(iface_from_route -4)
        # v1.8.3：必须校验节名真实存在，否则回退，避免写入不存在的接口
        [ -n "$rt" ] && uci -q get "network.$rt" >/dev/null 2>&1 && { echo "$rt"; return; }
        echo "$fallback"
    else
        fallback="wan6"
        custom=$(uci -q get dnssettings.wan.wan6_iface 2>/dev/null)
        [ -n "$custom" ] && uci -q get "network.$custom" >/dev/null 2>&1 && { echo "$custom"; return; }
        # v1.8.3：IPv6 必须优先落在 wan6 节。
        # IPv6 默认路由的 dev 同样是 pppoe-wan，按路由反查会得到 wan，
        # 若据此写入就会用 IPv6 DNS 覆盖掉刚写好的 wan.dns（IPv4 列表丢失）。
        if uci -q get network.wan6 >/dev/null 2>&1; then
            echo "wan6"
            return
        fi
        rt=$(iface_from_route -6)
        if [ -n "$rt" ] && uci -q get "network.$rt" >/dev/null 2>&1; then
            # 仅当该节确实是 IPv6 协议时才采用
            case "$(uci -q get network.$rt.proto)" in
                dhcpv6|6in4|6to4|6rd) echo "$rt"; return ;;
            esac
        fi
        # 无独立 wan6：并入 wan（下游会把 IPv6 DNS 追加而非覆盖）
        echo "wan"
    fi
}

WAN_IFACE=$(detect_wan_iface 4)
WAN6_IFACE=$(detect_wan_iface 6)

# ---------- v1.8.3：回填 dnssettings 缺失项（必须在读取配置之前）----------
# 历史版本只建了 wan 节却没写 DNS 值，导致页面显示默认值、
# 而 network.wan 无 dns 且 peerdns 未设置（实际走运营商 DNS），两者不一致。
# 缺失时优先取 network 现值回填，保证「页面所见 = 实际生效」。
if [ "$(uci -q get dnssettings.wan.peerdns)" = "0" ]; then
    _cur4=$(uci -q get network.wan.dns)
    _cur6=$(uci -q get network.wan6.dns)
    if [ -z "$(uci -q get dnssettings.wan.dns1_v4)" ]; then
        _v=$(echo "$_cur4" | awk '{print $1}')
        uci set dnssettings.wan.dns1_v4="${_v:-223.5.5.5}"
    fi
    if [ -z "$(uci -q get dnssettings.wan.dns2_v4)" ]; then
        _v=$(echo "$_cur4" | awk '{print $2}')
        uci set dnssettings.wan.dns2_v4="${_v:-119.29.29.29}"
    fi
    if [ -z "$(uci -q get dnssettings.wan.dns1_v6)" ]; then
        _v=$(echo "$_cur6" | awk '{print $1}')
        uci set dnssettings.wan.dns1_v6="${_v:-2400:3200::1}"
    fi
    if [ -z "$(uci -q get dnssettings.wan.dns2_v6)" ]; then
        _v=$(echo "$_cur6" | awk '{print $2}')
        uci set dnssettings.wan.dns2_v6="${_v:-2402:4e00::}"
    fi
    uci commit dnssettings 2>/dev/null
fi

# ---------- 读取 WAN 配置 ----------
WAN_PEERDNS=$(uci get dnssettings.wan.peerdns 2>/dev/null)
WAN_DNS1_V4=$(uci get dnssettings.wan.dns1_v4 2>/dev/null)
WAN_DNS2_V4=$(uci get dnssettings.wan.dns2_v4 2>/dev/null)
WAN_DNS1_V6=$(uci get dnssettings.wan.dns1_v6 2>/dev/null)
WAN_DNS2_V6=$(uci get dnssettings.wan.dns2_v6 2>/dev/null)

# ---------- 读取 LAN 配置 ----------
LAN_FORCE=$(uci get dnssettings.lan.force_dns 2>/dev/null)
LAN_DNS1_V4=$(uci get dnssettings.lan.dns1_v4 2>/dev/null)
LAN_DNS2_V4=$(uci get dnssettings.lan.dns2_v4 2>/dev/null)
LAN_DNS1_V6=$(uci get dnssettings.lan.dns1_v6 2>/dev/null)
LAN_DNS2_V6=$(uci get dnssettings.lan.dns2_v6 2>/dev/null)

# ---------- 读取 dnsmasq 配置 ----------
DNSMASQ_ENABLE=$(uci get dnssettings.dnsmasq.enable 2>/dev/null)

log "========== 开始应用 DNS 配置 =========="

# ============================================================
# 0. 应用前自动备份（network/dhcp/dnssettings 三配置）
#    保留最近 3 份自动备份，防止堆积占满 /root
# ============================================================
AUTO_BAK="$BACKUP_DIR/dnssettings-auto-$(date +%Y%m%d-%H%M%S).tar.gz"
if mkdir -p "$BACKUP_DIR" && tar -czf "$AUTO_BAK" /etc/config/network /etc/config/dhcp "$CONFIG_FILE" 2>/dev/null; then
    log "已自动备份当前配置: $AUTO_BAK"
    # 清理旧自动备份（按修改时间排序，保留最新 3 份）
    ls -1t "$BACKUP_DIR"/dnssettings-auto-*.tar.gz 2>/dev/null | tail -n +4 | while read -r old; do
        rm -f "$old"
        log "清理旧自动备份: $old"
    done
else
    log "WARN: 自动备份失败（继续应用，建议先手动备份）"
fi

# ============================================================
# 0.5 【v1.7.3】WAN 一致性校验：PPPoE 场景修正 wan6 绑定
#     现象：wan6.device 若仍指向物理网口（与 wan.device 相同），
#     DHCPv6 客户端在物理口上缺乏可用的 IPv6 出口地址，
#     SOLICIT / RS 发不出去（syslog 报 "Failed to send SOLICIT
#     message to ff02::1:2 (Address not available)"），
#     PD 前缀续租失败 → 前缀到期撤销 → LAN 设备丢失公网 IPv6。
#     修正条件：wan.proto=pppoe 且 wan6.device 与 wan.device 相同。
# ============================================================
FIXED_WAN6=0
if [ "$(uci -q get network.wan.proto)" = "pppoe" ]; then
    WAN_DEV_RAW=$(uci -q get network.wan.device)
    WAN6_DEV_RAW=$(uci -q get network.wan6.device)
    if [ -n "$WAN_DEV_RAW" ] && [ -n "$WAN6_DEV_RAW" ] && [ "$WAN6_DEV_RAW" = "$WAN_DEV_RAW" ]; then
        uci set network.wan6.device='@wan'
        uci commit network 2>/dev/null
        FIXED_WAN6=1
        log "修正 wan6 绑定: $WAN6_DEV_RAW -> @wan（PPPoE 必须挂在逻辑接口上）"
    fi
fi

# ============================================================
# 1. 配置 WAN 口 IPv4 DNS
# ============================================================
if uci get "network.$WAN_IFACE" >/dev/null 2>&1; then
    if [ "$WAN_PEERDNS" = "1" ]; then
        uci set "network.$WAN_IFACE.peerdns=1"
        uci delete "network.$WAN_IFACE.dns" 2>/dev/null
        log "WAN IPv4 ($WAN_IFACE): 使用运营商下发 DNS"
    else
        # 【防护】自定义模式必须至少提供一个 DNS，否则保持现状防止断网
        WAN_V4_DNS=""
        [ -n "$WAN_DNS1_V4" ] && WAN_V4_DNS="$WAN_DNS1_V4"
        [ -n "$WAN_DNS2_V4" ] && WAN_V4_DNS="$WAN_V4_DNS $WAN_DNS2_V4"
        if [ -z "$WAN_V4_DNS" ]; then
            log "WARN: WAN IPv4 自定义 DNS 为空，跳过该接口（保持现状，防止断网）"
        else
            uci set "network.$WAN_IFACE.peerdns=0"
            # list 字段：先清残留，再逐个 add_list（uci set 单元素是错误写法）
            uci delete "network.$WAN_IFACE.dns" 2>/dev/null
            for dns in $WAN_V4_DNS; do
                uci add_list "network.$WAN_IFACE.dns=$dns"
            done
            log "WAN IPv4 ($WAN_IFACE): $WAN_V4_DNS"
        fi
    fi
else
    log "WARN: 未找到 network.$WAN_IFACE 接口，跳过 WAN IPv4 配置"
fi

# ============================================================
# 2. 配置 WAN6 口 IPv6 DNS
# ============================================================
if uci get "network.$WAN6_IFACE" >/dev/null 2>&1; then
    if [ "$WAN_PEERDNS" = "1" ]; then
        uci set "network.$WAN6_IFACE.peerdns=1"
        uci delete "network.$WAN6_IFACE.dns" 2>/dev/null
        log "WAN6 IPv6 ($WAN6_IFACE): 使用运营商下发 DNS"
    else
        WAN_V6_DNS=""
        [ -n "$WAN_DNS1_V6" ] && WAN_V6_DNS="$WAN_DNS1_V6"
        [ -n "$WAN_DNS2_V6" ] && WAN_V6_DNS="$WAN_V6_DNS $WAN_DNS2_V6"
        if [ -z "$WAN_V6_DNS" ]; then
            log "WARN: WAN6 IPv6 自定义 DNS 为空，跳过该接口（保持现状，防止断网）"
        else
            uci set "network.$WAN6_IFACE.peerdns=0"
            # v1.8.3：与 WAN 同节时（无独立 wan6）必须保留已写入的 IPv4 DNS，
            # 否则这里的 delete 会把上一步的 IPv4 列表清空，只剩 IPv6。
            if [ "$WAN6_IFACE" != "$WAN_IFACE" ]; then
                uci delete "network.$WAN6_IFACE.dns" 2>/dev/null
            fi
            for dns in $WAN_V6_DNS; do
                uci add_list "network.$WAN6_IFACE.dns=$dns"
            done
            log "WAN6 IPv6 ($WAN6_IFACE): $WAN_V6_DNS"
        fi
    fi
else
    log "WARN: 未找到 network.$WAN6_IFACE 接口"
    # PPPoE 双栈：IPv6 DNS 可并入 wan 接口的 dns list（netifd 自动区分协议）
    # 【v1.4.6 去重】并入前先 delete 整个 dns list 再重写（IPv4+IPv6 全量），
    # 修复重复应用时 add_list 逐次累积导致 dns 列表无限增长的 bug
    if uci get "network.$WAN_IFACE" >/dev/null 2>&1 && [ "$WAN_PEERDNS" != "1" ]; then
        WAN_V6_DNS=""
        [ -n "$WAN_DNS1_V6" ] && WAN_V6_DNS="$WAN_DNS1_V6"
        [ -n "$WAN_DNS2_V6" ] && WAN_V6_DNS="$WAN_V6_DNS $WAN_DNS2_V6"
        if [ -n "$WAN_V6_DNS" ]; then
            # 重写全量 list：IPv4 自定义值 + IPv6 并入值，跳过重复值
            # WAN_V4_DNS 显式初始化（第 1 节为空跳过时该变量可能未赋值）
            [ -z "$WAN_V4_DNS" ] && WAN_V4_DNS=""
            uci delete "network.$WAN_IFACE.dns" 2>/dev/null
            ADDED_DNS=" "
            for dns in $WAN_V4_DNS $WAN_V6_DNS; do
                case "$ADDED_DNS" in
                    *" $dns "*) ;;  # 已写入，跳过
                    *) uci add_list "network.$WAN_IFACE.dns=$dns"; ADDED_DNS="$ADDED_DNS$dns " ;;
                esac
            done
            log "WAN IPv6(双栈并入 $WAN_IFACE.dns): $WAN_V6_DNS"
        else
            log "（IPv6 自定义 DNS 为空，不并入 $WAN_IFACE）"
        fi
    fi
fi

# ============================================================
# 2.5 【v1.8.6】清除 wan6 的 dns_search 残留
#     本平台（iStoreOS 25.12 / netifd dhcpv6）不接受 dns_search 选项，
#     残留会使 netifd setup 报 "ubus error: Invalid argument" 并无限重试，
#     PD 续租失败 → LAN 设备丢失公网 IPv6。pppoe 的 wan 接受该选项不受影响。
#     dns_search 多由运营商 DHCP 下发后残留进 uci，本插件不主动写入，应用时清除。
# ============================================================
if [ "$WAN6_IFACE" != "$WAN_IFACE" ] && uci -q get "network.$WAN6_IFACE" >/dev/null 2>&1; then
    if uci -q delete "network.$WAN6_IFACE.dns_search" 2>/dev/null; then
        uci commit network 2>/dev/null
        log "清除 $WAN6_IFACE.dns_search（dhcpv6 不支持，防止 Invalid argument 抖动）"
    fi
fi

# ============================================================
# 3. 配置 LAN 口 IPv4 DHCP 下发 DNS
#    【v1.4.6】dhcp_option 在 OpenWrt 中是 list 类型（可多实例并存），
#    uci set 覆盖单值会在残留旧 list 上叠加，改用 delete + add_list 正确写法
# ============================================================
if [ "$LAN_FORCE" = "1" ]; then
    if [ -z "$LAN_DNS1_V4" ] && [ -z "$LAN_DNS2_V4" ]; then
        log "WARN: 勾选强制下发但 LAN IPv4 DNS 为空，跳过（保持现状，防止设备断解析）"
    else
        uci delete dhcp.lan.dhcp_option 2>/dev/null
        LAN_V4_OPTION="6"
        [ -n "$LAN_DNS1_V4" ] && LAN_V4_OPTION="$LAN_V4_OPTION,$LAN_DNS1_V4"
        [ -n "$LAN_DNS2_V4" ] && LAN_V4_OPTION="$LAN_V4_OPTION,$LAN_DNS2_V4"
        uci add_list dhcp.lan.dhcp_option="$LAN_V4_OPTION"
        log "LAN IPv4 DHCP: $LAN_V4_OPTION"
    fi
else
    # 关闭时清除残留，使"不强制下发"真正生效
    uci delete dhcp.lan.dhcp_option 2>/dev/null
    log "LAN IPv4 DHCP: 不强制下发（设备走路由器缓存）"
fi

# ============================================================
# 4. 配置 LAN 口 IPv6（v1.8.4：分发模式 + RDNSS）
#    与 iStoreOS 原生网络管理共用 dhcp.lan 配置。模式存 dnssettings.ipv6.lan_mode，
#    旧版在此硬写 ra/dhcpv6=server，会覆盖用户所选模式，现改为按模式写入。
# ============================================================
V6MODE=$(uci -q get dnssettings.ipv6.lan_mode)
[ -z "$V6MODE" ] && V6MODE="server"
case "$V6MODE" in
    relay)
        uci set dhcp.lan.ra='relay'
        uci set dhcp.lan.dhcpv6='relay'
        uci set dhcp.lan.ndp='relay'
        uci delete dhcp.lan.ra_flags 2>/dev/null
        uci delete dhcp.lan.dns 2>/dev/null
        # 中继需上游接口作 master（iStoreOS 原生中继同样如此）
        if uci -q get network.wan6 >/dev/null 2>&1; then
            uci set dhcp.wan6=dhcp 2>/dev/null
            uci set dhcp.wan6.interface='wan6'
            uci set dhcp.wan6.ra='relay'
            uci set dhcp.wan6.dhcpv6='relay'
            uci set dhcp.wan6.ndp='relay'
            uci set dhcp.wan6.master='1'
        fi
        log "LAN IPv6: 中继模式（ra/dhcpv6/ndp=relay，wan6=master）"
        ;;
    disabled)
        uci set dhcp.lan.ra='disabled'
        uci set dhcp.lan.dhcpv6='disabled'
        uci set dhcp.lan.ndp='disabled'
        uci delete dhcp.lan.ra_flags 2>/dev/null
        uci delete dhcp.lan.dns 2>/dev/null
        uci delete dhcp.wan6 2>/dev/null
        log "LAN IPv6: 已关闭分发"
        ;;
    slaac)
        uci set dhcp.lan.ra='server'
        uci set dhcp.lan.dhcpv6='disabled'
        uci set dhcp.lan.ndp='disabled'
        uci delete dhcp.lan.ra_flags 2>/dev/null
        uci add_list dhcp.lan.ra_flags='other-config'
        uci set dhcp.lan.ra_slaac='1'
        # v1.8.7：强制宣告默认网关。pppoe 关闭 wan.ipv6 后默认路由可能缺失，
        # odhcpd 默认 ra_default=0 只在有默认路由时才宣告网关，会导致客户端
        # 拿到 SLAAC 地址却没有默认网关。设 1 确保始终宣告（路由由 v6gw 守护补）。
        uci set dhcp.lan.ra_default='1'
        uci delete dhcp.wan6 2>/dev/null
        log "LAN IPv6: 服务器模式（SLAAC 无状态）"
        ;;
    *)
        uci set dhcp.lan.ra='server'
        uci set dhcp.lan.dhcpv6='server'
        uci set dhcp.lan.ndp='disabled'
        uci delete dhcp.lan.ra_flags 2>/dev/null
        uci add_list dhcp.lan.ra_flags='managed-config'
        uci add_list dhcp.lan.ra_flags='other-config'
        uci set dhcp.lan.ra_slaac='1'
        uci set dhcp.lan.ra_default='1'   # v1.8.7：强制宣告默认网关（见 slaac 分支说明）
        uci delete dhcp.wan6 2>/dev/null
        log "LAN IPv6: 服务器模式（RA + DHCPv6 状态化）"
        ;;
esac

# RDNSS：仅 server/slaac 模式给设备下发 IPv6 DNS
if [ "$V6MODE" = "server" ] || [ "$V6MODE" = "slaac" ]; then
    if [ "$LAN_FORCE" = "1" ]; then
        LAN_V6_DNS=""
        [ -n "$LAN_DNS1_V6" ] && LAN_V6_DNS="$LAN_DNS1_V6"
        [ -n "$LAN_DNS2_V6" ] && LAN_V6_DNS="$LAN_V6_DNS $LAN_DNS2_V6"
        if [ -z "$LAN_V6_DNS" ]; then
            log "WARN: 勾选强制下发但 LAN IPv6 DNS 为空，跳过 RDNSS（保持现状）"
        else
            uci delete dhcp.lan.dns 2>/dev/null
            for dns in $LAN_V6_DNS; do
                uci add_list dhcp.lan.dns="$dns"
            done
            log "LAN IPv6 RDNSS: $LAN_V6_DNS"
        fi
    else
        uci delete dhcp.lan.dns 2>/dev/null
        log "LAN IPv6 RDNSS: 不强制下发（设备走路由器缓存）"
    fi
fi

# ============================================================
# 4.5 WAN IPv6 前缀请求长度（PD，v1.8.4）
# ============================================================
CHANGED_PREFIX=0
V6PREFIX=$(uci -q get dnssettings.ipv6.wan_prefix)
if [ -n "$V6PREFIX" ] && uci -q get network.wan6 >/dev/null 2>&1; then
    CUR_PREFIX=$(uci -q get network.wan6.reqprefix)
    [ -z "$CUR_PREFIX" ] && CUR_PREFIX="auto"
    if [ "$V6PREFIX" != "$CUR_PREFIX" ]; then
        uci set network.wan6.reqprefix="$V6PREFIX"
        CHANGED_PREFIX=1
        log "WAN6 前缀请求: $CUR_PREFIX -> $V6PREFIX"
    fi
fi

# ============================================================
# 5. 配置 dnsmasq 全局转发
# ============================================================
if [ "$DNSMASQ_ENABLE" = "1" ]; then
    # 清空旧的 server 列表（切换配置不留残留）
    uci delete dhcp.@dnsmasq[0].server 2>/dev/null

    # 添加 IPv4 转发
    for dns in $(uci get dnssettings.dnsmasq.forward_v4 2>/dev/null); do
        uci add_list dhcp.@dnsmasq[0].server="$dns"
        log "dnsmasq 转发 IPv4: $dns"
    done

    # 添加 IPv6 转发
    for dns in $(uci get dnssettings.dnsmasq.forward_v6 2>/dev/null); do
        uci add_list dhcp.@dnsmasq[0].server="$dns"
        log "dnsmasq 转发 IPv6: $dns"
    done

    # 【防护】启用转发但两个列表全空 → 提示（不清旧值，dnsmasq 仍有默认上游）
    uci -q get dhcp.@dnsmasq[0].server >/dev/null 2>&1 || log "WARN: 启用转发但未配置任何转发 DNS"

    # v1.8.3：noresolv —— 决定是否只用上面的转发列表。
    # dnsmasq 默认还会读 /tmp/resolv.conf.d/resolv.conf.auto（含运营商下发、
    # wan_6 自动获取、lan 接口 DNS），导致「全局转发」名不副实、
    # 页面配置与首页显示的实际 DNS 不一致。开启后严格只用转发列表。
    NORESOLV=$(uci -q get dnssettings.dnsmasq.noresolv)
    if [ "$NORESOLV" = "1" ]; then
        uci set dhcp.@dnsmasq[0].noresolv='1'
        log "dnsmasq noresolv=1：仅使用上方转发列表，忽略运营商下发 DNS"
    else
        uci delete dhcp.@dnsmasq[0].noresolv 2>/dev/null
        log "dnsmasq noresolv=0：转发列表之外仍会并用系统 resolv 上游"
    fi
else
    # 关闭转发时清空 server 列表，使"关闭"真正生效
    uci delete dhcp.@dnsmasq[0].server 2>/dev/null
    log "dnsmasq 全局转发: 未启用（已清空旧转发列表）"
fi

# ============================================================
# 6. 提交配置并重载服务
#    reload 而非 restart：不重建接口，PPPoE 不重拨，不断网
# ============================================================
uci commit network
uci commit dhcp

log "重载网络服务（不重拨）..."
/etc/init.d/network reload

log "重载 dnsmasq..."
/etc/init.d/dnsmasq reload

log "重启 odhcpd (IPv6 RA/DHCPv6)..."
# v1.8.3：必须 restart，不能只 start。
# 实测 odhcpd 已在运行时，procd 的 start 是空操作、不会重读配置，
# 导致改了 dhcp.lan.dns 后 RA 里播的仍是旧 RDNSS（抓包确认）。
# 同时收敛重复实例：曾出现 procd 实例与手动实例并存，两者都写 piofile，
# 造成 RFC9096 前缀记忆互相覆盖、RA 广播不一致。
ODHCPD_N=$(ps w 2>/dev/null | grep -c '[o]dhcpd')
[ "$ODHCPD_N" -gt 1 ] && log "检测到 $ODHCPD_N 个 odhcpd 实例，一并收敛"
/etc/init.d/odhcpd stop 2>/dev/null
sleep 1
killall odhcpd 2>/dev/null
sleep 1
/etc/init.d/odhcpd start 2>/dev/null
sleep 2
ODHCPD_N=$(ps w 2>/dev/null | grep -c '[o]dhcpd')
log "odhcpd 实例数: $ODHCPD_N"
[ "$ODHCPD_N" -gt 1 ] && log "WARN: odhcpd 仍有多个实例，请检查是否有额外启动项"

# v1.8.3：前缀可能已变化，同步 IPv6 转发目标并清理旧前缀残留路由
# v1.8.3：无条件同步 —— 即使没登记跟踪，也要清理 piofolder 失效前缀记忆，
# 止住 RA 对旧前缀的持续广播（客户端堆旧地址的根因）
if uci -q get netmanager.@v6track[0] >/dev/null 2>&1; then
    log "同步 IPv6 端口转发目标..."
else
    log "清理 IPv6 前缀残留..."
fi
/usr/sbin/netmanager port_sync_v6 2>&1 | while read -r l; do log "  $l"; done

# 【v1.7.3】wan6 绑定被修正后必须重新协商，否则新绑定不生效、PD 仍拿不到
# 【v1.8.4】前缀请求长度变化同样需要重新协商 wan6
if [ "$FIXED_WAN6" = "1" ] || [ "$CHANGED_PREFIX" = "1" ]; then
    log "重启 wan6 接口以应用新绑定/前缀请求并重新获取 PD 前缀..."
    ifup wan6 2>/dev/null
    sleep 12
    PD_INFO=$(ifstatus wan6 2>/dev/null | awk '/"ipv6-prefix"/{f=1} f&&/"mask"/{print; exit}')
    if [ -n "$PD_INFO" ]; then
        log "wan6 已重新获取 PD 前缀（$PD_INFO）"
    else
        log "WARN: wan6 暂未获取到 PD 前缀，请稍后执行 ifstatus wan6 复核"
    fi
fi

log "========== DNS 配置应用完成 =========="
log "若设备 DNS 未生效，请重连 WiFi/网线清除设备端缓存"
exit 0


```

### 5.3 files/usr/sbin/dnssettings-backup.sh

- **用途**：上网设置备份脚本：独立备份 network/dhcp/dnssettings 到 /root/backup/
- **规模**：27 行
- **维护要点**：逻辑简单，注意与 apply 脚本的保留策略一致

```bash
#!/bin/sh
# ============================================================
# DNS设置插件 - 备份当前系统配置
# 备份 /etc/config/ 下的 network 和 dhcp 配置
# ============================================================

BACKUP_DIR="/root/backup"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$BACKUP_DIR/dnssettings-system-backup-$TIMESTAMP.tar.gz"

mkdir -p "$BACKUP_DIR"

# 备份 network 和 dhcp 配置（DNS 相关的核心配置）
tar -czf "$BACKUP_FILE" \
    /etc/config/network \
    /etc/config/dhcp \
    /etc/config/dnssettings 2>/dev/null

if [ $? -eq 0 ]; then
    echo "备份成功: $BACKUP_FILE"
    logger -t dnssettings "系统配置已备份到 $BACKUP_FILE"
    exit 0
else
    echo "备份失败"
    logger -t dnssettings "ERROR: 系统配置备份失败"
    exit 1
fi


```

### 5.4 files/usr/lib/lua/luci/controller/netmanager.lua

- **用途**：LuCI 控制器：注册全部页面路由 + API 分发（action 到后端命令桥接）+ multipart 上传处理
- **规模**：554 行
- **维护要点**：api_handler 强制 POST；所有拼命令参数必经 shell_escape；csrf_check 403；插件页加 no-store 头防旧 JS

```lua
-- ============================================================
-- 网络管理插件 - LuCI 控制器 v1.1
-- 
-- ============================================================
module("luci.controller.netmanager", package.seeall)

function index()
    -- v1.8.13：插件页禁止浏览器缓存，避免更新后旧标签页滞留旧版 JS，
    -- 用旧解析逻辑读新后端输出导致编辑表单/列表状态错乱
    luci.http.header("Cache-Control", "no-store, no-cache, must-revalidate")
    luci.http.header("Pragma", "no-cache")
    entry({"admin", "netmanager"}, alias("admin", "netmanager", "overview"), _("网络管理"), 60).dependent = true
    entry({"admin", "netmanager", "overview"}, template("netmanager/overview"), _("系统概览"), 1)
    entry({"admin", "netmanager", "port_forward"}, template("netmanager/port_forward"), _("端口转发"), 2)
    entry({"admin", "netmanager", "firewall_rules"}, template("netmanager/firewall_rules"), _("规则管理"), 3)
    entry({"admin", "netmanager", "ssh_log"}, template("netmanager/ssh_log"), _("SSH登录日志"), 4)
    entry({"admin", "netmanager", "access_log"}, template("netmanager/access_log"), _("端口访问日志"), 5)
    -- 上网设置（CBI 标准表单，绑定 network + dhcp + dnssettings）
    entry({"admin", "netmanager", "dns"}, cbi("netmanager/dns_settings"), _("上网设置"), 6)
    entry({"admin", "netmanager", "dns_staticv6"}, cbi("netmanager/dns_staticv6"), _("静态IP分配"), 7)
    entry({"admin", "netmanager", "settings"}, template("netmanager/settings"), _("设置"), 8)
    entry({"admin", "netmanager", "api"}, call("api_handler"))
    -- 【v1.4.6】dns_apply / dns_backup 原 GET 路由已改为 api_handler 内 POST action
    -- 【v1.4.7】保留两个兼容路由重定向到 DNS 设置页（v1.4.5 的书签/浏览器缓存仍
    --  指向旧 GET 路由会 404；仅重定向不执行脚本，不复活"刷新即重复执行"问题）
    entry({"admin", "netmanager", "dns_apply"}, call("dns_legacy_redirect"))
    entry({"admin", "netmanager", "dns_backup"}, call("dns_legacy_redirect"))
end

-- 【v1.4.7】v1.4.5 旧 GET 路由兼容：重定向到 DNS 设置页（不执行任何脚本）
function dns_legacy_redirect()
    luci.http.redirect(luci.dispatcher.build_url("admin", "netmanager", "dns"))
end

-- ============================================================
-- 【v1.4.7】CSRF 防护：对齐 LuCI 内建 authtoken 机制
-- v1.4.6 曾用 luci.dispatcher.context.session.id 自派生 token——ucode 版 LuCI
-- 的 context 没有 session.id（会话 ID 实际存于 context.authsession，框架内建
-- CSRF token 存于 context.authtoken），导致 sid 取空 → 所有 API 被 fail-closed
-- 拒绝 403。现改为直接比对框架 authtoken（与 CBI 表单 token 同源，由 ucode
-- 分发器为每个已认证会话生成，跨站页面无法获得）。
-- ============================================================
function csrf_token()
    local ctx = luci.dispatcher.context
    return (ctx and ctx.authtoken) and tostring(ctx.authtoken) or ""
end

local function csrf_check()
    local expected = csrf_token()
    -- authtoken 缺失说明未通过认证（正常到不了这里，防御性 fail-closed）
    if expected == "" then return false end
    local got = luci.http.formvalue("token") or ""
    if type(got) == "table" then got = "" end
    return (got == expected)
end

-- 安全转义，防止命令注入
local function shell_escape(s)
    if not s or s == "" then return "" end
    -- 处理formvalue可能返回table的情况（multipart文件上传）
    if type(s) == "table" then
        s = s.tmpname or s.name or ""
    end
    if s == "" then return "" end
    return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- 从formvalue获取字符串值，兼容table返回（multipart上传）
local function form_str(key)
    local v = luci.http.formvalue(key)
    if type(v) == "table" then
        return v.tmpname or v.name or ""
    end
    return v or ""
end

-- 【v1.4.6 P2】命令参数包装：空值传 ''（防 shell 吞掉空参数错位），非空转义
-- （原 arg() 在 4 个分支内重复定义，提取为模块级）
local function arg(v)
    if v == "" or v == nil then return "''" end
    return shell_escape(v)
end

-- ============================================================
-- LuCI multipart 文件上传：必须在首次 formvalue() 之前设置文件处理器
-- 否则 formvalue() 解析 multipart 时不会保存上传的文件内容
-- ============================================================
local uploaded_tmp_file = nil
local uploaded_file_size = 0
-- 【v1.4.6 P1】multipart 上传大小上限 50MB（/tmp 是 tmpfs，无上限会 OOM）
local MAX_UPLOAD_BYTES = 50 * 1024 * 1024

local function setup_upload_handler()
    local upload_dir = "/tmp/netmanager_upload"
    luci.sys.call("mkdir -p " .. upload_dir)
    math.randomseed(os.time() + math.floor(os.clock() * 1000))
    uploaded_tmp_file = upload_dir .. "/plugin_update_" .. os.time() .. "_" .. math.random(1000, 9999) .. ".tar.gz"
    uploaded_file_size = 0
    -- v1.6.1 备份文件上传临时路径
    backup_tmp_file = upload_dir .. "/backup_import_" .. os.time() .. "_" .. math.random(1000, 9999) .. ".tar.gz"
    backup_file_size = 0

    local fout = nil
    local backup_fout = nil
    luci.http.setfilehandler(function(meta, chunk, eof)
        if not meta or not meta.name then return end
        -- 处理 plugin_file 字段（插件更新）
        if meta.name == "plugin_file" then
            if uploaded_file_size > MAX_UPLOAD_BYTES then
                if fout then fout:close() end
                fout = nil
                return
            end
            if not fout then
                fout = io.open(uploaded_tmp_file, "wb")
                if not fout then
                    uploaded_tmp_file = nil
                    return
                end
            end
            if fout and chunk and #chunk > 0 then
                fout:write(chunk)
                uploaded_file_size = uploaded_file_size + #chunk
            end
            if eof and fout then
                fout:close()
            end
        end
        -- v1.6.1 处理 backup_file 字段（备份导入）
        if meta.name == "backup_file" then
            if backup_file_size > MAX_UPLOAD_BYTES then
                if backup_fout then backup_fout:close() end
                backup_fout = nil
                return
            end
            if not backup_fout then
                backup_fout = io.open(backup_tmp_file, "wb")
                if not backup_fout then
                    backup_tmp_file = nil
                    return
                end
            end
            if backup_fout and chunk and #chunk > 0 then
                backup_fout:write(chunk)
                backup_file_size = backup_file_size + #chunk
            end
            if eof and backup_fout then
                backup_fout:close()
            end
        end
    end)
end

function api_handler()
    -- 【安全】仅接受 POST：防止 <img src="...?action=uninstall"> 之类的跨站 GET 触发
    -- （LuCI 的会话认证仅证明"登录页有效"，不阻止 GET 请求携带会话执行操作）
    if luci.http.getenv("REQUEST_METHOD") ~= "POST" then
        luci.http.status(405, "Method Not Allowed")
        luci.http.prepare_content("text/plain; charset=utf-8")
        luci.http.write('[ERROR] 仅允许 POST 请求')
        return
    end

    -- 【v1.4.6 安全】CSRF Token 校验：跨站 form POST 虽满足 POST-only，但可携带登录
    -- cookie；token 由视图渲染时注入（common_head.htm apiFetch 自动附带），跨站页面无法获得
    if not csrf_check() then
        luci.http.status(403, "Forbidden")
        luci.http.prepare_content("text/plain; charset=utf-8")
        luci.http.write('[ERROR] CSRF 校验失败：请刷新页面后重试（会话已过期或非本站请求）')
        return
    end

    -- 【关键】先设置文件上传处理器，再读任何formvalue（包括action）
    setup_upload_handler()
    
    local action = luci.http.formvalue("action") or ""
    local result = ""
    local cmd = ""
    local dns_action = nil

    if action == "overview" then
        cmd = "/usr/sbin/netmanager overview"
    elseif action == "port_list" then
        cmd = "/usr/sbin/netmanager port_list"
    elseif action == "port_add" then
        local port = luci.http.formvalue("port") or ""
        local proto = luci.http.formvalue("proto") or "tcp"
        local target = luci.http.formvalue("target") or ""
        local ipver = luci.http.formvalue("ipver") or "both"
        local dport = luci.http.formvalue("dport") or ""

        -- 关键修复：target为空时不传第3参数，避免shell吞掉空参数导致错位
        -- dport为内部端口，留空传''占位（后端默认与外部端口一致）
        if target ~= "" then
            cmd = string.format("/usr/sbin/netmanager port_add %s %s %s %s %s",
                shell_escape(port), shell_escape(proto), shell_escape(target), shell_escape(ipver), arg(dport))
        else
            cmd = string.format("/usr/sbin/netmanager port_add %s %s '' %s %s",
                shell_escape(port), shell_escape(proto), shell_escape(ipver), arg(dport))
        end
    elseif action == "port_del" then
        local port = luci.http.formvalue("port") or ""
        local proto = luci.http.formvalue("proto") or "tcp"
        local ipver = luci.http.formvalue("ipver") or "both"
        cmd = string.format("/usr/sbin/netmanager port_del %s %s %s", shell_escape(port), shell_escape(proto), shell_escape(ipver))
    elseif action == "port_edit" then
        local old_port = luci.http.formvalue("old_port") or ""
        local old_proto = luci.http.formvalue("old_proto") or "tcp"
        local new_port = luci.http.formvalue("new_port") or ""
        local new_proto = luci.http.formvalue("new_proto") or "tcp"
        local new_target = luci.http.formvalue("new_target") or ""
        local new_ipver = luci.http.formvalue("new_ipver") or "both"
        local new_dport = luci.http.formvalue("new_dport") or ""
        local old_ipver = luci.http.formvalue("old_ipver") or "v4"

        cmd = string.format("/usr/sbin/netmanager port_edit %s %s %s %s %s %s %s %s",
            shell_escape(old_port), shell_escape(old_proto),
            shell_escape(new_port), shell_escape(new_proto),
            arg(new_target), shell_escape(new_ipver), arg(new_dport), shell_escape(old_ipver))
    elseif action == "port_track_v6" then
        -- v1.8.0：登记/取消 IPv6 转发目标跟踪锚点
        local port = luci.http.formvalue("port") or ""
        local proto = luci.http.formvalue("proto") or "tcp"
        local anchor = luci.http.formvalue("anchor") or ""
        cmd = string.format("/usr/sbin/netmanager port_track_v6 %s %s %s",
            shell_escape(port), shell_escape(proto), shell_escape(anchor))
    elseif action == "port_sync_v6" then
        cmd = "/usr/sbin/netmanager port_sync_v6"
    elseif action == "rule_list" then
        cmd = "/usr/sbin/netmanager rule_list"
    elseif action == "rule_add" then
        local name = luci.http.formvalue("name") or ""
        local src = luci.http.formvalue("src") or ""
        local dst = luci.http.formvalue("dst") or ""
        local proto = luci.http.formvalue("proto") or "tcp"
        local port = luci.http.formvalue("port") or ""
        local target = luci.http.formvalue("target") or "ACCEPT"
        local fam = luci.http.formvalue("family") or "any"
        -- 修复：所有可能为空的参数都传 '' 空引号，防止shell吞掉空参数导致错位

        cmd = string.format("/usr/sbin/netmanager rule_add %s %s %s %s %s %s %s",
            arg(name), arg(src), arg(dst),
            arg(proto), arg(port), arg(target), arg(fam))
    elseif action == "rule_del" then
        local idx = luci.http.formvalue("idx") or ""
        cmd = string.format("/usr/sbin/netmanager rule_del %s", shell_escape(idx))
    elseif action == "rule_edit" then
        local idx = luci.http.formvalue("idx") or ""
        local name = luci.http.formvalue("name") or ""
        local src = luci.http.formvalue("src") or ""
        local dst = luci.http.formvalue("dst") or ""
        local proto = luci.http.formvalue("proto") or "tcp"
        local port = luci.http.formvalue("port") or ""
        local target = luci.http.formvalue("target") or "ACCEPT"
        local fam = luci.http.formvalue("family") or "any"

        cmd = string.format("/usr/sbin/netmanager rule_edit %s %s %s %s %s %s %s %s",
            shell_escape(idx), arg(name), arg(src), arg(dst),
            arg(proto), arg(port), arg(target), arg(fam))
    elseif action == "rule_toggle" then
        local idx = luci.http.formvalue("idx") or ""
        local en = luci.http.formvalue("en") or ""
        cmd = string.format("/usr/sbin/netmanager rule_toggle %s %s", shell_escape(idx), shell_escape(en))
    elseif action == "ssh_log" then
        local limit = luci.http.formvalue("limit") or "50"
        cmd = string.format("/usr/sbin/netmanager ssh_log %s", shell_escape(limit))
    elseif action == "access_log" then
        local port = luci.http.formvalue("port") or ""
        local limit = luci.http.formvalue("limit") or "100"
        if port ~= "" then
            cmd = string.format("/usr/sbin/netmanager access_log %s %s", shell_escape(port), shell_escape(limit))
        else
            cmd = string.format("/usr/sbin/netmanager access_log '' %s", shell_escape(limit))
        end
    elseif action == "static_bind" then
        -- v1.8.4：在线客户端一键绑定静态IP（创建 dhcp host）
        local mac = luci.http.formvalue("mac") or ""
        local ip = luci.http.formvalue("ip") or ""
        local name = luci.http.formvalue("name") or ""
        local duid = luci.http.formvalue("duid") or ""
        cmd = string.format("/usr/sbin/netmanager static_bind %s %s %s %s",
            shell_escape(mac), arg(ip), arg(name), arg(duid))
    elseif action == "static_unbind" then
        -- v1.8.5：在线客户端一键解绑（按 MAC 删除 dhcp host）
        local mac = luci.http.formvalue("mac") or ""
        cmd = string.format("/usr/sbin/netmanager static_unbind %s", shell_escape(mac))
    elseif action == "block_detail" then
        -- v1.8.5：拦截统计点击查看被拦截源IP明细（便于拉黑）
        local key = luci.http.formvalue("key") or ""
        cmd = string.format("/usr/sbin/netmanager block_detail %s", arg(key))
    elseif action == "restart" then
        cmd = "/usr/sbin/netmanager restart"
    elseif action == "reload" then
        cmd = "/usr/sbin/netmanager reload"
    elseif action == "backup" then
        cmd = "/usr/sbin/netmanager backup"
    elseif action == "backup_list" then
        cmd = "/usr/sbin/netmanager backup_list"
    elseif action == "backup_restore" then
        local filename = luci.http.formvalue("filename") or ""
        cmd = string.format("/usr/sbin/netmanager backup_restore %s", shell_escape(filename))
    elseif action == "backup_delete" then
        local filename = luci.http.formvalue("filename") or ""
        cmd = string.format("/usr/sbin/netmanager backup_delete %s", shell_escape(filename))
    elseif action == "backup_import" then
        local filename = luci.http.formvalue("filename") or ""
        cmd = string.format("/usr/sbin/netmanager backup_import %s", shell_escape(filename))
    elseif action == "backup_prune" then
        local keep = luci.http.formvalue("keep") or "20"
        cmd = string.format("/usr/sbin/netmanager backup_prune %s", shell_escape(keep))
    elseif action == "backup_import_upload" then
        -- v1.6.1 备份文件上传导入
        local upload_dir = "/tmp/netmanager_upload"
        local dest_file = upload_dir .. "/backup_import.tar.gz"
        luci.sys.call("mkdir -p " .. upload_dir)
        local src = backup_tmp_file
        local got_file = false
        if src and luci.sys.call("test -f " .. shell_escape(src) .. " && test -s " .. shell_escape(src)) == 0 then
            got_file = true
        end
        if not got_file then
            local alt_path = form_str("backup_file")
            if alt_path ~= "" and alt_path ~= "backup_file" and luci.sys.call("test -f " .. shell_escape(alt_path)) == 0 then
                src = alt_path
                got_file = true
            end
        end
        if not got_file then
            result = '{"error":"未接收到上传的备份文件，请重新选择 .tar.gz 文件"}'
        else
            luci.sys.call("cp -f " .. shell_escape(src) .. " " .. shell_escape(dest_file) .. " 2>/dev/null || mv -f " .. shell_escape(src) .. " " .. shell_escape(dest_file) .. " 2>/dev/null")
            if luci.sys.call("test -f " .. shell_escape(dest_file) .. " && test -s " .. shell_escape(dest_file)) == 0 then
                local sz_str = luci.sys.exec("ls -nl " .. shell_escape(dest_file) .. " 2>/dev/null | awk '{print $5}'") or ""
                local sz_num = tonumber(sz_str) or 0
                if sz_num < 100 then
                    result = '{"error":"上传的文件太小（' .. sz_num .. '字节），可能不是有效的备份文件"}'
                else
                    local import_cmd = "/usr/sbin/netmanager backup_import backup_import.tar.gz"
                    result = "[CMD] " .. import_cmd .. "\n"
                        .. "[DEBUG] dest_file=" .. dest_file .. " size=" .. sz_num .. "字节\n"
                        .. (luci.sys.exec(import_cmd) or "")
                end
            else
                result = '{"error":"备份文件保存失败"}'
            end
        end
    elseif action == "plugin_upload_update" then
        -- 文件已通过 setfilehandler() 在读取formvalue时自动保存
        local upload_dir = "/tmp/netmanager_upload"
        local dest_file = upload_dir .. "/plugin_update.tar.gz"
        luci.sys.call("mkdir -p " .. upload_dir)
        
        local src = uploaded_tmp_file
        local got_file = false
        local src_info = {}
        table.insert(src_info, "setfilehandler_tmp=" .. tostring(src or "nil") .. " size=" .. tostring(uploaded_file_size or 0))
        
        -- 优先使用 setfilehandler 保存的临时文件
        if src and luci.sys.call("test -f " .. shell_escape(src) .. " && test -s " .. shell_escape(src)) == 0 then
            got_file = true
        end
        
        -- 备选：某些版本的 formvalue("plugin_file") 可能直接返回临时文件路径（字符串/table两种情况）
        if not got_file then
            local alt_path = form_str("plugin_file")
            table.insert(src_info, "form_str_plugin_file=" .. tostring(alt_path))
            if alt_path ~= "" and alt_path ~= "plugin_file" and luci.sys.call("test -f " .. shell_escape(alt_path)) == 0 then
                src = alt_path
                got_file = true
            end
        end
        
        if not got_file then
            result = '[DEBUG] ' .. table.concat(src_info, " | ") .. '\n{"error":"未接收到上传的插件包，请重新选择文件。请确保浏览器支持FormData（现代浏览器均支持）"}'
        else
            -- 复制/移动到标准路径
            luci.sys.call("cp -f " .. shell_escape(src) .. " " .. shell_escape(dest_file) .. " 2>/dev/null || mv -f " .. shell_escape(src) .. " " .. shell_escape(dest_file) .. " 2>/dev/null")
            
            if luci.sys.call("test -f " .. shell_escape(dest_file) .. " && test -s " .. shell_escape(dest_file)) == 0 then
                -- 检查文件大小
                local sz_str = luci.sys.exec("ls -nl " .. shell_escape(dest_file) .. " 2>/dev/null | awk '{print $5}'") or ""
                local sz_num = tonumber(sz_str) or 0
                local update_cmd = "/usr/sbin/netmanager plugin_update plugin_update.tar.gz"
                if sz_num < 2000 then
                    result = '[DEBUG] src=' .. tostring(src) .. ' dest=' .. dest_file .. ' size=' .. sz_num .. '字节\n'
                        .. '{"error":"上传的文件太小（' .. sz_num .. '字节），可能上传失败，请重新选择完整的 .tar.gz 包"}'
                else
                    result = "[CMD] " .. update_cmd .. "\n"
                        .. "[DEBUG] dest_file=" .. dest_file .. " size=" .. sz_num .. "字节, src来源: " .. table.concat(src_info, " | ") .. "\n"
                        .. (luci.sys.exec(update_cmd) or "")
                end
            else
                result = '[DEBUG] src=' .. tostring(src) .. ' dest=' .. dest_file .. "\n"
                    .. '{"error":"文件保存失败，src=' .. tostring(src) .. '"}'
            end
        end
    elseif action == "upload_file" then
        local filename = luci.http.formvalue("filename") or ""
        if filename == "" then
            result = '{"error":"filename required"}'
        else
            local filecontent = luci.http.formvalue("filecontent") or ""
            local upload_dir = "/tmp/netmanager_upload"
            -- 确保目录存在
            os.execute("mkdir -p " .. upload_dir)
            -- 写入base64临时文件（避免shell命令行长度限制和特殊字符问题）
            -- 【v1.4.6 P1】时间戳+随机数防同秒冲突（与 setup_upload_handler 同策略）
            local b64file = upload_dir .. "/.b64_" .. os.time() .. "_" .. math.random(1000, 9999)
            local f = io.open(b64file, "w")
            if f then
                f:write(filecontent)
                f:close()
                cmd = string.format("/usr/sbin/netmanager upload_file %s %s",
                    shell_escape(filename), b64file)
            else
                result = '{"error":"无法创建临时文件"}'
            end
        end
    elseif action == "plugin_update" then
        local filename = luci.http.formvalue("filename") or ""
        cmd = string.format("/usr/sbin/netmanager plugin_update %s", shell_escape(filename))
    elseif action == "plugin_version" then
        local filename = luci.http.formvalue("filename") or ""
        cmd = string.format("/usr/sbin/netmanager plugin_version %s", shell_escape(filename))
    elseif action == "cleanup_uploads" then
        cmd = "/usr/sbin/netmanager cleanup_uploads"
    elseif action == "settings" then
        cmd = "/usr/sbin/netmanager settings"
    elseif action == "set_default_target" then
        local ip = luci.http.formvalue("ip") or ""
        cmd = string.format("/usr/sbin/netmanager set_default_target %s", shell_escape(ip))
    elseif action == "log_set" then
        local enable = luci.http.formvalue("enable") or "0"
        cmd = string.format("/usr/sbin/netmanager log_set %s", shell_escape(enable))
    elseif action == "log_get" then
        local lines = luci.http.formvalue("lines") or "200"
        cmd = string.format("/usr/sbin/netmanager log_get %s", shell_escape(lines))
    elseif action == "log_clear" then
        cmd = "/usr/sbin/netmanager log_clear"
    elseif action == "log_query" then
        local level = luci.http.formvalue("level") or "ALL"
        local keyword = luci.http.formvalue("keyword") or ""
        local lines = luci.http.formvalue("lines") or "200"
        -- 【v1.6.1 修复】keyword 可能为空，必须用 arg() 包装传 ''，
        -- 否则 shell_escape("") 返回空字符串导致参数错位（lines 的值被当作 keyword）
        cmd = string.format("/usr/sbin/netmanager log_query %s %s %s",
            shell_escape(level), arg(keyword), shell_escape(lines))
    elseif action == "log_export" then
        cmd = "/usr/sbin/netmanager log_export"
    elseif action == "china_filter_status" then
        cmd = "/usr/sbin/netmanager china_filter status"
    elseif action == "china_filter_enable" then
        cmd = "/usr/sbin/netmanager china_filter enable"
    elseif action == "china_filter_disable" then
        cmd = "/usr/sbin/netmanager china_filter disable"
    elseif action == "china_filter_update" then
        cmd = "/usr/sbin/netmanager china_filter update"
    elseif action == "china_filter_set_url" then
        local url = luci.http.formvalue("url") or ""
        cmd = string.format("/usr/sbin/netmanager china_filter set_url %s", shell_escape(url))
    elseif action == "china_filter_set_cron" then
        local cron = luci.http.formvalue("cron") or ""
        cmd = string.format("/usr/sbin/netmanager china_filter set_cron %s", shell_escape(cron))
    elseif action == "china_filter_set_allow_wan" then
        -- v1.8.16：放行 WAN 同网段来源开关（上级光猫/网关访问）
        local v = luci.http.formvalue("value") or "1"
        if v ~= "1" and v ~= "0" then v = "1" end
        cmd = string.format("/usr/sbin/netmanager china_filter allow_wan %s",
            v == "1" and "on" or "off")
    elseif action == "china6_filter_status" then
        cmd = "/usr/sbin/netmanager china6_filter status"
    elseif action == "china6_filter_enable" then
        cmd = "/usr/sbin/netmanager china6_filter enable"
    elseif action == "china6_filter_disable" then
        cmd = "/usr/sbin/netmanager china6_filter disable"
    elseif action == "china6_filter_update" then
        cmd = "/usr/sbin/netmanager china6_filter update"
    elseif action == "china6_filter_set_url" then
        local url = luci.http.formvalue("url") or ""
        cmd = string.format("/usr/sbin/netmanager china6_filter set_url %s", shell_escape(url))
    elseif action == "china6_filter_set_cron" then
        local cron = luci.http.formvalue("cron") or ""
        cmd = string.format("/usr/sbin/netmanager china6_filter set_cron %s", shell_escape(cron))
    elseif action == "blacklist_list" then
        cmd = "/usr/sbin/netmanager blacklist list"
    elseif action == "blacklist_add" then
        local ip = luci.http.formvalue("ip") or ""
        cmd = string.format("/usr/sbin/netmanager blacklist add %s", shell_escape(ip))
    elseif action == "blacklist_del" then
        local ip = luci.http.formvalue("ip") or ""
        cmd = string.format("/usr/sbin/netmanager blacklist del %s", shell_escape(ip))
    elseif action == "blacklist_clear" then
        local family = luci.http.formvalue("family") or "all"
        cmd = string.format("/usr/sbin/netmanager blacklist clear %s", shell_escape(family))
    elseif action == "whitelist_list" then
        cmd = "/usr/sbin/netmanager whitelist list"
    elseif action == "whitelist_add" then
        local ip = luci.http.formvalue("ip") or ""
        cmd = string.format("/usr/sbin/netmanager whitelist add %s", shell_escape(ip))
    elseif action == "whitelist_del" then
        local ip = luci.http.formvalue("ip") or ""
        cmd = string.format("/usr/sbin/netmanager whitelist del %s", shell_escape(ip))
    elseif action == "whitelist_clear" then
        local family = luci.http.formvalue("family") or "all"
        cmd = string.format("/usr/sbin/netmanager whitelist clear %s", shell_escape(family))
    elseif action == "update_check" then
        cmd = "/usr/sbin/netmanager update_check"
    elseif action == "update_apply" then
        -- 在线更新：下载可能较慢，浏览器端需耐心等待完整响应
        cmd = "/usr/sbin/netmanager update_apply"
    elseif action == "set_update_mirror" then
        local mirror = luci.http.formvalue("mirror") or ""
        cmd = string.format("/usr/sbin/netmanager set_update_mirror %s", shell_escape(mirror))
    elseif action == "uninstall" then
        local keep = luci.http.formvalue("keep") or "0"
        local mode = (keep == "1") and "keep" or "full"
        cmd = string.format("/usr/sbin/netmanager uninstall %s", shell_escape(mode))
    elseif action == "dns_apply" then
        -- 【v1.4.6】DNS 应用配置由 GET 路由并入 POST action（原路由刷新即重复执行）
        dns_action = "apply"
    elseif action == "dns_backup" then
        -- 【v1.4.6】DNS 备份系统配置同上
        dns_action = "backup"
    else
        result = '{"error":"unknown action"}'
    end

    -- 【v1.4.6】DNS 动作执行（单次调用同时捕获输出与退出码）
    if dns_action then
        local script = (dns_action == "apply")
            and "/usr/sbin/dnssettings-apply.sh" or "/usr/sbin/dnssettings-backup.sh"
        local out = luci.sys.exec(script .. " 2>&1; echo \"__RC__$?\"") or ""
        local rc = tonumber(out:match("__RC__(%-?%d+)")) or -1
        out = out:gsub("__RC__%-?%d+\n?$", "")
        if rc == 0 then
            result = "[CMD] " .. script .. " (exit=0)\n" ..
                ((dns_action == "apply") and "DNS配置已应用" or "配置已备份") ..
                "，详细输出：\n" .. out
        else
            result = "[CMD] " .. script .. " (exit=" .. tostring(rc) .. ")\n" ..
                "执行失败，详细输出：\n" .. out
        end
    end

    if cmd ~= "" then
        -- ucode版LuCI的luci.sys.exec在命令失败/无输出时可能返回nil，用 or "" 兜底避免拼接报错
        local exec_out = luci.sys.exec(cmd) or ""
        -- 在结果开头加上执行的命令，方便用户确认
        result = "[CMD] " .. cmd .. "\n" .. exec_out
    end

    luci.http.prepare_content("text/plain; charset=utf-8")
    luci.http.write(result)
end


```

### 5.5 files/usr/lib/lua/luci/model/cbi/netmanager/dns_settings.lua

- **用途**：上网设置 CBI 模型：Map 绑定 /etc/config/dnssettings（wan/lan/dnsmasq 三节 + 应用/备份按钮）
- **规模**：405 行
- **维护要点**：forward_v4/forward_v6 为 DynamicList；按钮经 api 触发 POST 动作，不再走 GET 路由

```lua
-- 上网设置插件 - CBI 表单模型
-- 原 DNS 设置模块，v1.6.1 扩展为上网设置：WAN口上网方式 + LAN口地址 + DNS设置
-- 绑定 /etc/config/network + /etc/config/dnssettings

local m, s, o

-- v1.8.4：模块级 trim（IPv6 模式读取运行时配置用）
local function trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end

-- ============================================================
-- 第一部分：上网设置（WAN口 + LAN口，绑定 network 配置）
-- v1.6.1：隐藏 Map 级别标题栏，统一用 section 级别标题（灰色标题栏）
-- ============================================================
m = Map("network", nil,
    translate("统一管理 WAN 口上网方式、LAN 口地址与 DNS 服务器。修改后点击「应用配置」生效。")
    .. "<br><em style='color:#6b7280;font-size:12px;'>"
    .. translate("修改 WAN/LAN 口设置会重载网络服务，期间可能短暂断网；DNS 配置应用前自动备份到 /root/backup/。")
    .. "</em>")
m.pageaction = false  -- v1.8.6：关闭本 Map 默认保存按钮，统一由底部「应用配置」提交

-- v1.4.6 修复：CBI 页面缺少页内导航，注入导航模板
m:append(Template("netmanager/cbi_nav"))

-- ---------- WAN 口上网方式 ----------
s = m:section(NamedSection, "wan", "interface", translate("WAN 口上网方式"),
    translate("路由器接入互联网的方式，PPPoE 拨号 / DHCP 自动获取 / 静态 IP。"))

o = s:option(ListValue, "proto", translate("上网方式"))
o:value("pppoe", translate("PPPoE 拨号"))
o:value("dhcp", translate("DHCP 自动获取"))
o:value("static", translate("静态 IP"))
o.default = "dhcp"
o.rmempty = false

-- PPPoE 拨号
o = s:option(Value, "username", translate("PPPoE 账号"))
o:depends("proto", "pppoe")
o.placeholder = "宽带账号"

o = s:option(Value, "password", translate("PPPoE 密码"))
o:depends("proto", "pppoe")
o.password = true
o.placeholder = "宽带密码"

-- 静态 IP
o = s:option(Value, "ipaddr", translate("IP 地址"))
o:depends("proto", "static")
o.datatype = "ip4addr"
o.placeholder = "192.168.1.100"

o = s:option(Value, "netmask", translate("子网掩码"))
o:depends("proto", "static")
o.datatype = "ip4addr"
o.placeholder = "255.255.255.0"

o = s:option(Value, "gateway", translate("网关"))
o:depends("proto", "static")
o.datatype = "ip4addr"
o.placeholder = "192.168.1.1"

o = s:option(DynamicList, "dns", translate("WAN 口 DNS"))
o:depends("proto", "static")
o.datatype = "ip4addr"
o.placeholder = "223.5.5.5"
o.description = translate("静态 IP 模式下手动指定 DNS，可添加多个")

-- ============================================================
-- IPv6 获取与分发（v1.8.6：独立 Map，渲染在 WAN 上网方式之后、LAN 口地址之前）
-- 页面顺序：WAN上网方式 → IPv6获取分发 → LAN口地址 → WAN-DNS → LAN-DNS → dnsmasq → 操作
-- CBI 每个 Map 绑定单一配置、写入只走本 Map 配置，交错顺序需拆成多 Map 按序渲染。
-- ============================================================
local m_v6 = Map("dnssettings", nil, nil)
m_v6.pageaction = false  -- v1.8.6：关闭默认保存按钮

-- ---------- IPv6 获取与分发模式 ----------
-- 与 iStoreOS 原生网络管理共用同一套 dhcp.lan / network.wan6 配置，两边互通：
-- 这里改的模式，原生「网络→接口→LAN→DHCP服务器→IPv6设置」里同步可见，反之亦然。
-- 选项值存 dnssettings.ipv6，点「应用配置」时由 dnssettings-apply.sh 翻译写入 dhcp/network。
s = m_v6:section(NamedSection, "ipv6", "dnssettings", translate("IPv6 获取与分发"),
    translate("管理 WAN 口 IPv6 前缀获取（PD）与 LAN 口 IPv6 分发模式。配置写入 iStoreOS 原生网络管理同一套参数，互不冲突。"))

o = s:option(ListValue, "wan_prefix", translate("WAN 前缀请求长度 (PD)"))
o:value("auto", translate("自动（运营商决定）"))
o:value("60", "/60")
o:value("56", "/56")
o:value("64", "/64")
o:value("no", translate("不请求前缀（关闭 PD）"))
o.default = "auto"
o.rmempty = false
function o.cfgvalue(self, section)
    local v = trim(luci.sys.exec("uci -q get network.wan6.reqprefix 2>/dev/null"))
    return (v ~= "") and v or "auto"
end
o.description = translate("向运营商请求的 IPv6 前缀长度。前缀越短可划分的子网越多；「不请求」则关闭前缀委托。修改后应用会重新协商 wan6。")

o = s:option(ListValue, "lan_mode", translate("LAN 口 IPv6 分发模式"))
o:value("server", translate("服务器模式（RA + DHCPv6 状态化）"))
o:value("slaac", translate("服务器模式（SLAAC 无状态）"))
o:value("relay", translate("中继模式（透传上级路由 IPv6）"))
o:value("disabled", translate("关闭 IPv6 分发"))
o.default = "server"
o.rmempty = false
function o.cfgvalue(self, section)
    local ra = trim(luci.sys.exec("uci -q get dhcp.lan.ra 2>/dev/null"))
    local d6 = trim(luci.sys.exec("uci -q get dhcp.lan.dhcpv6 2>/dev/null"))
    if ra == "relay" or d6 == "relay" then return "relay" end
    if ra == "disabled" and (d6 == "disabled" or d6 == "") then return "disabled" end
    if d6 == "server" then return "server" end
    if ra == "server" then return "slaac" end
    return "server"
end
o.description = translate("服务器模式：由本机给内网设备分配 IPv6（状态化=DHCPv6 分配地址；SLAAC=设备按 RA 前缀自行生成）。中继模式：上级路由已有 IPv6 时透传给内网（需上级支持）。关闭：内网不再分发 IPv6。")

-- ============================================================
-- LAN 口地址（v1.8.6：独立 Map，绑定 network，渲染在 IPv6 之后）
-- ============================================================
local m_lan = Map("network", nil, nil)
m_lan.pageaction = false  -- v1.8.6：关闭默认保存按钮

-- ---------- LAN 口地址设置 ----------
s = m_lan:section(NamedSection, "lan", "interface", translate("LAN 口地址"),
    translate("路由器局域网管理地址与子网掩码，修改后需用新地址登录管理页面。"))

o = s:option(Value, "ipaddr", translate("LAN 口 IP 地址"))
o.datatype = "ip4addr"
o.placeholder = "192.168.1.1"
o.rmempty = false

o = s:option(Value, "netmask", translate("子网掩码"))
o.datatype = "ip4addr"
o.placeholder = "255.255.255.0"
o.rmempty = false

-- ============================================================
-- DNS 设置（绑定 dnssettings 配置）
-- v1.6.1：隐藏 Map 级别标题栏，统一用 section 级别标题（灰色标题栏）
-- ============================================================
local m2 = Map("dnssettings", nil, nil)
m2.pageaction = false  -- v1.8.6：关闭默认「保存并应用」，仅保留自定义「应用配置」按钮

-- ---------- WAN 口上游 DNS ----------
s = m2:section(NamedSection, "wan", "dnssettings", translate("WAN 口上游 DNS"),
    translate("路由器本身解析域名使用的 DNS，PPPoE/DHCP 拨号时生效。"))

o = s:option(Flag, "peerdns", translate("使用运营商下发的 DNS"),
    translate("勾选则使用拨号时运营商自动分配的 DNS；取消则使用下方自定义 DNS。"))
o.default = "0"
o.rmempty = false

-- v1.8.0 修复：原先这四个字段用 o:depends("peerdns", "0")，
-- 但 iStoreOS 24.10 的 CBI 对 Flag「等于0」的依赖判定不成立，
-- 服务端直接不渲染这些选项 —— 页面上看不到也无法配置 WAN DNS，
-- 只能沿用默认值，与实际生效的运营商 DNS 长期不一致。
-- 改为始终显示，并在说明中标注生效条件。
o = s:option(Value, "dns1_v4", translate("IPv4 主 DNS"))
o.datatype = "ip4addr"
o.placeholder = "223.5.5.5"
o.default = "223.5.5.5"
o.description = translate("以下四项仅在未勾选「使用运营商下发的 DNS」时生效")

o = s:option(Value, "dns2_v4", translate("IPv4 备 DNS"))
o.datatype = "ip4addr"
o.placeholder = "119.29.29.29"
o.default = "119.29.29.29"

o = s:option(Value, "dns1_v6", translate("IPv6 主 DNS"))
o.datatype = "ip6addr"
o.placeholder = "2400:3200::1"
o.default = "2400:3200::1"

o = s:option(Value, "dns2_v6", translate("IPv6 备 DNS"))
o.datatype = "ip6addr"
o.placeholder = "2402:4e00::"
o.default = "2402:4e00::"

-- ---------- LAN 口设备 DNS ----------
s = m2:section(NamedSection, "lan", "dnssettings", translate("LAN 口设备 DNS"),
    translate("通过 DHCP/RA 下发给手机、电脑等局域网设备的 DNS 服务器。"))

o = s:option(Flag, "force_dns", translate("强制下发自定义 DNS 给设备"),
    translate("勾选：设备直接使用下方指定的 DNS；取消：设备使用路由器 LAN IP 作为 DNS（走 dnsmasq 缓存转发）。"))
o.default = "1"
o.rmempty = false

o = s:option(Value, "dns1_v4", translate("IPv4 主 DNS"))
o.datatype = "ip4addr"
o.placeholder = "223.5.5.5"
o.default = "223.5.5.5"
o:depends("force_dns", "1")

o = s:option(Value, "dns2_v4", translate("IPv4 备 DNS"))
o.datatype = "ip4addr"
o.placeholder = "119.29.29.29"
o.default = "119.29.29.29"
o:depends("force_dns", "1")

o = s:option(Value, "dns1_v6", translate("IPv6 主 DNS"))
o.datatype = "ip6addr"
o.placeholder = "2400:3200::1"
o.default = "2400:3200::1"
o:depends("force_dns", "1")

o = s:option(Value, "dns2_v6", translate("IPv6 备 DNS"))
o.datatype = "ip6addr"
o.placeholder = "2402:4e00::"
o.default = "2402:4e00::"
o:depends("force_dns", "1")

-- ---------- dnsmasq 全局转发 ----------
s = m2:section(NamedSection, "dnsmasq", "dnssettings", translate("dnsmasq 全局转发"),
    translate("dnsmasq 上游解析服务器，设备走路由器缓存时实际使用的 DNS。"))

o = s:option(Flag, "enable", translate("启用全局转发"),
    translate("将上述 DNS 同时写入 dnsmasq 全局转发列表。"))
o.default = "1"
o.rmempty = false

-- v1.8.0：noresolv —— 解决「页面配置的 DNS」与「首页/实际生效 DNS」不一致
o = s:option(Flag, "noresolv", translate("只用上方转发列表（忽略运营商 DNS）"),
    translate("dnsmasq 默认除转发列表外，还会并用系统 resolv 里的上游（运营商拨号下发、wan6 自动获取、LAN 接口 DNS）。"
        .. "这会让实际解析路径与本页配置不一致。勾选后严格只使用上方列表。"))
o.default = "0"
o.rmempty = false
o:depends("enable", "1")

o = s:option(DynamicList, "forward_v4", translate("IPv4 转发 DNS"))
o.datatype = "ip4addr"
o.placeholder = "223.5.5.5"
o:depends("enable", "1")

o = s:option(DynamicList, "forward_v6", translate("IPv6 转发 DNS"))
o.datatype = "ip6addr"
o.placeholder = "2400:3200::1"
o:depends("enable", "1")

-- ---------- 操作按钮（v1.6.1 移除备份按钮，统一由设置页面备份模块管理） ----------
-- ---------- v1.8.0：实际生效 DNS 只读面板 ----------
-- 首页显示的是运行时真实上游，本页配置的是期望值，二者来源不同容易看着「冲突」。
-- 这里把运行时实际值直接摊开，并标注每项来源，便于对照。
local function _runtime_dns_panel()
    -- iStoreOS 24.10 起 pcdata 迁到 luci.xml，旧路径会打印弃用告警污染页面
    local esc
    local okx, xml = pcall(require, "luci.xml")
    if okx and xml and xml.pcdata then
        esc = function(s) return xml.pcdata(tostring(s or "")) end
    else
        local util = require "luci.util"
        esc = function(s) return util.pcdata(tostring(s or "")) end
    end
    local function trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end

    -- dnsmasq 实际转发列表
    local srv = trim(luci.sys.exec("uci -q get dhcp.@dnsmasq[0].server 2>/dev/null"))
    local nr = trim(luci.sys.exec("uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null"))
    -- 系统 resolv 上游（运营商 / 各接口自动下发）
    local auto = luci.sys.exec("cat /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null")
    -- 下发给 LAN 设备的 DNS
    local opt4 = trim(luci.sys.exec("uci -q get dhcp.lan.dhcp_option 2>/dev/null"))
    local opt6 = trim(luci.sys.exec("uci -q get dhcp.lan.dns 2>/dev/null"))

    local html = "<div style='background:#f8fafc;border:1px solid #e5e7eb;border-radius:6px;padding:10px 12px;margin:8px 0;font-size:12px;line-height:1.9;'>"
    html = html .. "<b style='color:#374151;'>当前实际生效的 DNS（运行时读取，非本页配置值）</b><br>"
    html = html .. "<span style='color:#6b7280;'>路由器自身解析：</span> dnsmasq (127.0.0.1) → "
    if srv ~= "" then
        html = html .. "<code>" .. esc(srv) .. "</code>"
    else
        html = html .. "<i>未配置转发列表</i>"
    end
    if nr == "1" then
        html = html .. " <span style='color:#059669;'>[noresolv=1，只用上述列表]</span>"
    else
        html = html .. " <span style='color:#d97706;'>[noresolv=0，还会并用下方系统上游]</span>"
    end
    html = html .. "<br><span style='color:#6b7280;'>系统 resolv 上游（首页数据来源）：</span><br>"
    html = html .. "<pre style='margin:4px 0;padding:6px 8px;background:#fff;border:1px solid #e5e7eb;border-radius:4px;max-height:160px;overflow:auto;'>"
    html = html .. esc(trim(auto) ~= "" and auto or "(空)") .. "</pre>"
    html = html .. "<span style='color:#6b7280;'>下发给内网设备：</span> IPv4 <code>"
        .. esc(opt4 ~= "" and opt4 or "(未下发，设备用路由器 IP)")
        .. "</code> ／ IPv6 <code>" .. esc(opt6 ~= "" and opt6 or "(未下发)") .. "</code>"
    html = html .. "</div>"
    return html
end

s = m2:section(NamedSection, "actions", "dnssettings", translate("操作"))
s.description = _runtime_dns_panel()

-- 执行 DNS 脚本并返回结果
local function run_dns_script(script)
    local out = luci.sys.exec(script .. " 2>&1; echo \"__RC__$?\"") or ""
    local rc = tonumber(out:match("__RC__(%-?%d+)")) or -1
    out = out:gsub("__RC__%-?%d+\n?$", "")
    return rc, out
end

-- 输出压缩为单行消息
local function to_one_line(str, max)
    str = (str or ""):gsub("%c", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #str > (max or 300) then str = str:sub(1, max) .. "..." end
    return str
end

o = s:option(Button, "_apply", translate("应用配置"))
o.inputtitle = translate("应用配置")
o.inputstyle = "apply"
o.write = function()
    -- v1.8.6：四个 Map 各持独立 cursor，需逐一提交（WAN/LAN 属 network，IPv6/DNS 属 dnssettings）
    m.uci:commit("network")        -- WAN 上网方式
    m_lan.uci:commit("network")    -- LAN 口地址
    m_v6.uci:commit("dnssettings") -- IPv6 获取分发
    m2.uci:commit("dnssettings")   -- DNS 各节

    -- 执行 DNS 应用脚本
    local ok, rc, out = pcall(run_dns_script, "/usr/sbin/dnssettings-apply.sh")
    if not ok then
        m2.message = "DNS 配置应用执行异常：" .. to_one_line(tostring(rc))
        return
    end

    -- v1.8.0：改用 reload 而非 restart。
    -- restart 会重建 br-lan，导致以 DirectInterface 绑定该网卡的 dropbear
    -- 监听套接字失效（端口仍 LISTEN 但连接被拒），管理 SSH 随之中断。
    -- apply 脚本内部已做 network reload，这里仅在 WAN 口参数确有变化时才重启接口。
    luci.sys.exec("/etc/init.d/network reload >/dev/null 2>&1")

    -- v1.8.1：此处不再做 SSH 自连探测。
    -- dropbear 绑 DirectInterface 时，本机连自身地址走回环路由必然失败，
    -- 探测无法区分"真失效"与"绑定特性"，只会造成无谓重启并踢掉在线会话。
    -- 应用走的是 reload（不重建 br-lan），本就无需重启 dropbear；
    -- 真正重建网卡的场景由 hotplug 96-netmanager-v6sync 按 ifindex 变化处理。

    if rc == 0 then
        m2.message = "配置已应用成功，已写入 /etc/config/ 并重载网络服务（详细输出见「设置 → 运行日志」）"
    else
        m2.message = "配置应用失败 (exit=" .. tostring(rc) .. ")：" .. to_one_line(out)
    end
end

-- v1.6.1 修复：/etc/config/dnssettings 为空或缺失节时，自动初始化默认节
-- v1.8.0 增强：节存在但个别选项缺失时也要补齐（历史版本只建了 wan 节
--              却没写 DNS 值，导致页面显示默认值而实际未生效）
local function _ensure_dns_defaults()
    local defaults = {
        wan = {
            peerdns = "0",
            dns1_v4 = "223.5.5.5", dns2_v4 = "119.29.29.29",
            dns1_v6 = "2400:3200::1", dns2_v6 = "2402:4e00::",
        },
        lan = {
            force_dns = "1",
            dns1_v4 = "223.5.5.5", dns2_v4 = "119.29.29.29",
            dns1_v6 = "2400:3200::1", dns2_v6 = "2402:4e00::",
        },
        dnsmasq = { enable = "1", noresolv = "0" },
        ipv6 = { lan_mode = "server", wan_prefix = "auto" },
    }
    local changed = false

    for sec, opts in pairs(defaults) do
        if not m2.uci:get("dnssettings", sec) then
            -- 建节走命令行，避免桥接 cursor 对三参 set 支持不一致
            luci.sys.exec("uci set dnssettings." .. sec .. "=dnssettings")
            changed = true
        end
        for k, v in pairs(opts) do
            if not m2.uci:get("dnssettings", sec, k) then
                -- WAN DNS 缺失时优先沿用 network 现值，避免覆盖用户已有设置
                local cur = nil
                if sec == "wan" then
                    if k == "dns1_v4" then
                        cur = (luci.sys.exec("uci -q get network.wan.dns 2>/dev/null"):match("(%S+)"))
                    elseif k == "dns1_v6" then
                        cur = (luci.sys.exec("uci -q get network.wan6.dns 2>/dev/null"):match("(%S+)"))
                    end
                end
                local val = (cur and cur ~= "") and cur or v
                luci.sys.exec("uci set dnssettings." .. sec .. "." .. k .. "='" .. val .. "'")
                changed = true
            end
        end
    end

    if not m2.uci:get("dnssettings", "actions") then
        luci.sys.exec("uci set dnssettings.actions=dnssettings")
        changed = true
    end

    -- 转发列表为空时补默认
    -- 注意：iStoreOS 24.10 的 ucode uci 桥接不提供 cursor:list_add，
    -- 必须走命令行 uci add_list，否则页面加载即报错。
    if not m2.uci:get("dnssettings", "dnsmasq", "forward_v4") then
        luci.sys.exec("uci add_list dnssettings.dnsmasq.forward_v4='223.5.5.5'")
        luci.sys.exec("uci add_list dnssettings.dnsmasq.forward_v4='119.29.29.29'")
        changed = true
    end
    if not m2.uci:get("dnssettings", "dnsmasq", "forward_v6") then
        luci.sys.exec("uci add_list dnssettings.dnsmasq.forward_v6='2400:3200::1'")
        luci.sys.exec("uci add_list dnssettings.dnsmasq.forward_v6='2402:4e00::'")
        changed = true
    end

    if changed then luci.sys.exec("uci commit dnssettings") end
end
_ensure_dns_defaults()

return m, m_v6, m_lan, m2


```

### 5.6 files/usr/lib/lua/luci/model/cbi/netmanager/dns_staticv6.lua

- **用途**：静态 IP 分配 CBI 模型：绑定 dhcp.host + 在线客户端速览（四数据源交叉）+ 冲突检测
- **规模**：693 行
- **维护要点**：get_online_devices 四源（dnsmasq 租约/ARP/odhcpd/NDP）；first_opt() 替代 ucode 桥无 get_first；merge 只在 on_before_commit 执行

```lua
-- 静态 IP / IPv6 分配 - v1.4.7
-- v1.4.7 更新：
--   on_before_commit 以 pcall 包裹：重复条目合并/幽灵清理异常不再中断保存，
--   错误文本透传到页面消息（ucode LuCI 环境差异导致的问题可被用户直接看到）
-- v1.4.6 更新：
--   1. 重复 host 合并改为"仅检测、提交时执行"（原页面加载即 commit，GET 刷新就会改配置）
--   2. DUID 误判修复：排除 DHCPv4 clientid 中的 MAC 原文型 / 01+MAC 硬件型标识
--   3. WAN 侧过滤增强：设备名匹配 wan 前缀同时覆盖 pppoe-wan / pppoe-wan6 等命名
--   4. odhcpd 重启改为按需（m.changed 才 restart，无改动不扰动 IPv6 分配）
-- v1.4.3 历史：
--   1. 在线客户端识别增强：IPv4（dnsmasq 租约 + ARP）+ IPv6（odhcpd 租约 + NDP 邻居表，覆盖 SLAAC 地址）
--   2. 自动捕获 DUID：dnsmasq clientid / odhcpd 租约 / 主机名关联，在线设备 DUID 直接可见
--   3. 冲突检测增强：MAC / IPv4 / 完整IPv6 / hostid 全部实时查重（修复旧版快照导致同批提交漏检）
--   4. 修复幽灵条目：MAC 与 DUID 均为空的条目在保存时自动清理，不再"消失但占位"
--   5. ARP / NDP 过滤 WAN 侧条目；dnsmasq 由 restart 改为 reload，避免 DNS 短暂中断
-- v1.2.1 历史：移除 luci.sys.net 依赖（iStoreOS 24.10 ucode 版 LuCI 不存在该模块），
--              改用直接读取系统文件获取在线设备

local sys = require "luci.sys"

-- ============================================================
-- 工具函数：HTML 转义（主机名/IP 来自外部数据，输出前必须转义）
-- ============================================================
local function esc(s)
    s = tostring(s or "")
    s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub("\"", "&quot;")
    return s
end

-- ============================================================
-- 工具函数：获取在线设备信息（IPv4 + IPv6 + DUID）
-- 数据源（4 份交叉关联，均不依赖 luci.sys.net）：
--   1. dnsmasq 租约  <leasefile>        -> MAC / IPv4 / 主机名 / clientid(可能为 DUID)
--   2. ARP 表        /proc/net/arp      -> MAC / IPv4（静态设备），过滤 WAN 侧
--   3. odhcpd 租约   <leasefile>        -> DUID / IPv6 地址(DHCPv6) / 主机名
--   4. NDP 邻居表    ip -6 neigh show   -> IPv6 <-> MAC（含 SLAAC 隐私地址），过滤 WAN 侧
-- 返回 { [MAC_UPPER] = { ip, ip6s={}, hostname, duid, online } }
-- 在线判定：ARP 完成态(Flags != 0x0) 或 NDP 表中出现 lladdr（租约存在仅作信息，不算在线）
-- ============================================================
local function get_online_devices()
    local devices = {}
    local uci = require "uci".cursor()

    -- 租约文件路径允许 UCI 覆盖（默认与 OpenWrt 一致）
    -- v1.4.6 兼容性修复：不再调用 uci:get_first()，改用 foreach 实现同语义。
    -- 原因：iStoreOS 24.10 / OpenWrt 24.10+ 的 ucode 版 LuCI 中，Lua CBI 经
    --       ucodebridge 桥接执行，桥接的 uci cursor 没有 get_first 扩展方法，
    --       报 "attempt to call method 'get_first' (a nil value)"。
    --       foreach/get/set/commit 桥接均支持（merge_duplicate_hosts 已验证）。
    local dhcp_leasefile = "/tmp/dhcp.leases"
    local od_leasefile = "/tmp/odhcpd.leases"
    if uci then
        local function first_opt(stype, opt)
            local v
            uci:foreach("dhcp", stype, function(sec)
                if not v and sec[opt] and sec[opt] ~= "" then
                    v = sec[opt]
                end
            end)
            return v
        end
        local lf = first_opt("dnsmasq", "leasefile")
        if lf then dhcp_leasefile = lf end
        lf = first_opt("odhcpd", "leasefile")
        if lf then od_leasefile = lf end
    end

    local function ensure(mac_upper)
        local d = devices[mac_upper]
        if not d then
            d = { ip = "", ip6s = {}, hostname = "", duid = "", online = false }
            devices[mac_upper] = d
        end
        return d
    end

    local function push_ip6(d, addr)
        for _, a in ipairs(d.ip6s) do
            if a == addr then return end
        end
        table.insert(d.ip6s, addr)
    end

    local function looks_like_duid(s)
        return s and #s >= 8 and #s <= 64 and s:match("^[0-9a-fA-F]+$") ~= nil
    end

    -- 1. dnsmasq DHCPv4 租约: <ts> <mac> <ip> <hostname> [clientid]
    local f = io.open(dhcp_leasefile, "r")
    if f then
        for line in f:lines() do
            local mac, ip, hostname, clientid = line:match("^%S+%s+(%S+)%s+(%S+)%s+(%S+)%s*(%S*)")
            if mac and ip then
                local d = ensure(mac:upper())
                if d.ip == "" then d.ip = ip end
                if hostname and hostname ~= "" and hostname ~= "*" and d.hostname == "" then
                    d.hostname = hostname
                end
                if clientid and clientid ~= "" then
                    -- DHCPv6 客户端通常以 DUID 作为 DHCPv4 的 clientid（形如 id:00:01:...）
                    -- 【v1.4.6 误判修复】排除两种"伪 DUID"：
                    --   a) MAC 原文型：部分客户端直接把 MAC 塞进 clientid（dnsmasq 去掉冒号后 12 位 hex 与本条目 MAC 相同）
                    --   b) 01+MAC 硬件型：DUID-LLT/DUID-EN 前缀形如 01:xx:xx:xx:xx:xx:xx...，其中含 MAC 的非真正 DUID
                    local cid = clientid:gsub("^id:", ""):gsub(":", "")
                    if looks_like_duid(cid) then
                        local mac_nocolon = mac:gsub(":", ""):lower()
                        local is_mac_itself = (cid:lower() == mac_nocolon)
                        local is_01mac_type = cid:lower():sub(1, 2) == "01" and cid:lower():find(mac_nocolon, 1, true)
                        if not is_mac_itself and not is_01mac_type then
                            d.duid = cid
                        end
                    end
                end
            end
        end
        f:close()
    end

    -- 【v1.4.6】WAN 侧设备判定：设备名或命名以 wan 结尾/包含 wan 词段（覆盖 wan / wan6 /
    -- pppoe-wan / pppoe-wan6 / ppp0-wan / wan-eth 等），避免把 PPPoE 拨号对端误判为 LAN 设备
    local function is_wan_side(dev)
        if not dev or dev == "" then return false end
        return dev:match("wan") ~= nil
    end

    -- 2. ARP 表: IP | HWtype | Flags | HWaddress | Mask | Device
    f = io.open("/proc/net/arp", "r")
    if f then
        local first = true
        for line in f:lines() do
            if first then
                first = false
            else
                local ip, flags, mac, dev = line:match("^(%S+)%s+%S+%s+(%S+)%s+(%S+)%s+%S+%s+(%S+)")
                if mac and ip and mac ~= "00:00:00:00:00:00" and not is_wan_side(dev) then
                    local d = ensure(mac:upper())
                    if d.ip == "" then d.ip = ip end
                    if flags ~= "0x0" then d.online = true end
                end
            end
        end
        f:close()
    end


    -- 3. odhcpd DHCPv6 租约: <duid> <iaid> <name> <ts> <id> <len> <addr>
    --    行首 '#' 为前缀委托(PD)行，跳过；len=128 为地址分配
    local addr_duid = {}  -- [ipv6addr] = duid
    local name_duid = {}  -- [hostname] = duid（主机名兜底关联）
    f = io.open(od_leasefile, "r")
    if f then
        for line in f:lines() do
            if line:sub(1, 1) ~= "#" then
                local duid, name, len, addr = line:match("^(%S+)%s+%S+%s+(%S+)%s+%S+%s+%S+%s+(%S+)%s+(%S+)")
                if duid and addr then
                    addr_duid[addr] = duid
                    if name and name ~= "" and name ~= "*" and not name_duid[name] then
                        name_duid[name] = duid
                    end
                end
            end
        end
        f:close()
    end

    -- 4. NDP 邻居表: <addr> dev <dev> lladdr <mac> <state>（排除链路本地与 WAN 侧）
    f = io.popen("ip -6 neigh show 2>/dev/null", "r")
    if f then
        for line in f:lines() do
            local addr, dev, rest = line:match("^(%S+)%s+dev%s+(%S+)%s*(.-)%s*$")
            if addr and dev and not is_wan_side(dev) and not addr:match("^fe80") then
                local mac6 = rest:match("lladdr%s+(%S+)")
                if mac6 and mac6 ~= "00:00:00:00:00:00" then
                    local d = ensure(mac6:upper())
                    d.online = true
                    push_ip6(d, addr)
                    if d.duid == "" and addr_duid[addr] then d.duid = addr_duid[addr] end
                end
            end
        end
        f:close()
    end

    -- 5. 主机名兜底关联 DUID（DHCPv4 租约无 DUID 型 clientid 时）
    for _, d in pairs(devices) do
        if d.duid == "" and d.hostname ~= "" and name_duid[d.hostname] then
            d.duid = name_duid[d.hostname]
        end
    end

    return devices
end

-- ============================================================
-- 工具函数：合并同 MAC 的重复 host 条目
-- 【v1.4.6】拆分为两步：
--   1. detect_duplicate_hosts()：页面加载时只统计不写库（原实现 GET 刷新页面
--      就会静默 commit 修改 /etc/config/dhcp）
--   2. do_merge_duplicate_hosts()：真正执行合并，挪到 on_before_commit
--      （仅用户点击「保存并应用」时触发）
-- ============================================================
local function detect_duplicate_hosts()
    local x = require "uci".cursor()
    local mac_seen = {}
    local count = 0

    x:foreach("dhcp", "host", function(s)
        local mac = s.mac
        if mac and mac ~= "" then
            mac = mac:upper()
            if mac_seen[mac] then
                count = count + 1
            else
                mac_seen[mac] = true
            end
        end
    end)

    return count
end

-- 提交时真正执行合并（保留首条字段较全的条目，补齐其缺失字段后删除重复项）
local function do_merge_duplicate_hosts(uci_handle)
    local x = uci_handle or require "uci".cursor()
    local mac_seen = {}
    local to_delete = {}

    x:foreach("dhcp", "host", function(s)
        local mac = s.mac
        if mac and mac ~= "" then
            mac = mac:upper()
            if mac_seen[mac] then
                local keep = mac_seen[mac]
                if s.duid and s.duid ~= "" and not keep.duid then
                    x:set("dhcp", keep[".name"], "duid", s.duid)
                end
                if s.ip and s.ip ~= "" and not keep.ip then
                    x:set("dhcp", keep[".name"], "ip", s.ip)
                end
                if s.hostid and s.hostid ~= "" and (not keep.hostid or keep.hostid == "") then
                    x:set("dhcp", keep[".name"], "hostid", s.hostid)
                end
                if s.ip6 and s.ip6 ~= "" and not keep.ip6 then
                    x:set("dhcp", keep[".name"], "ip6", s.ip6)
                end
                if s.name and s.name ~= "" and not keep.name then
                    x:set("dhcp", keep[".name"], "name", s.name)
                end
                if s.enabled and not keep.enabled then
                    x:set("dhcp", keep[".name"], "enabled", s.enabled)
                end
                table.insert(to_delete, s[".name"])
            else
                mac_seen[mac] = s
            end
        end
    end)

    for _, name in ipairs(to_delete) do
        x:delete("dhcp", name)
    end

    return #to_delete
end

-- ============================================================
-- 页面加载时执行：仅检测重复（只读）+ 获取在线设备 + 已绑定 MAC
-- ============================================================
local merged_count = detect_duplicate_hosts()
local online_devices = get_online_devices()

-- 已绑定 MAC（在线速览标记用）
local bound_macs = {}
local uci_cursor = require "uci".cursor()
uci_cursor:foreach("dhcp", "host", function(s)
    if s.mac and s.mac ~= "" then
        bound_macs[s.mac:upper()] = true
    end
end)

-- 在线客户端速览行（MAC 排序，仅列出至少有一个 IP 的设备）
local ov_rows = {}
for mac, d in pairs(online_devices) do
    local has_ip = (d.ip ~= "") or (#d.ip6s > 0)
    if has_ip then
        table.insert(ov_rows, {
            mac = mac, name = d.hostname, ip = d.ip,
            ip6s = d.ip6s, duid = d.duid,
            bound = bound_macs[mac] and true or false
        })
    end
end
table.sort(ov_rows, function(a, b) return a.mac < b.mac end)

-- 生成在线客户端速览 HTML（v1.6.1 优化：IPv6 地址折叠、彩色徽章、在线状态、DUID 显示）
local function build_online_html()
    local out = {}
    if #ov_rows == 0 then
        table.insert(out, '<div style="padding:20px;text-align:center;color:#9ca3af;font-size:13px;">' .. translate("未发现任何在线客户端") .. '</div>')
        return table.concat(out, "\n")
    end

    -- 内联样式 + JS（IPv6 折叠展开）
    table.insert(out, '<style>')
    table.insert(out, '.nm-ov-table { width:100%; border-collapse:collapse; font-size:13px; margin-bottom:0; }')
    table.insert(out, '.nm-ov-table th { background:#f9fafb; padding:10px 12px; text-align:left; font-weight:600; color:#6b7280; font-size:12px; border-bottom:2px solid #e5e7eb; }')
    table.insert(out, '.nm-ov-table td { padding:9px 12px; border-bottom:1px solid #f3f4f6; vertical-align:top; }')
    table.insert(out, '.nm-ov-table tr:hover td { background:#f9fafb; }')
    table.insert(out, '.nm-ov-mono { font-family:"Consolas","Monaco",monospace; font-size:12px; }')
    table.insert(out, '.nm-ov-v6-main { color:#2563eb; font-family:"Consolas","Monaco",monospace; font-size:12px; word-break:break-all; }')
    table.insert(out, '.nm-ov-v6-more { color:#6b7280; font-size:11px; cursor:pointer; text-decoration:underline; margin-left:4px; }')
    table.insert(out, '.nm-ov-v6-all { display:none; margin-top:4px; }')
    table.insert(out, '.nm-ov-v6-all span { display:block; color:#2563eb; font-family:"Consolas","Monaco",monospace; font-size:11px; word-break:break-all; margin-bottom:2px; }')
    table.insert(out, '.nm-ov-badge { display:inline-block; padding:2px 10px; border-radius:10px; font-size:11px; font-weight:600; }')
    table.insert(out, '.nm-ov-badge-bound { background:#d1fae5; color:#059669; }')
    table.insert(out, '.nm-ov-badge-unbound { background:#fef3c7; color:#d97706; }')
    table.insert(out, '.nm-ov-online { display:inline-block; width:8px; height:8px; border-radius:50%; background:#10b981; margin-right:5px; box-shadow:0 0 4px #10b981; }')
    table.insert(out, '.nm-ov-offline { display:inline-block; width:8px; height:8px; border-radius:50%; background:#d1d5db; margin-right:5px; }')
    table.insert(out, '.nm-ov-duid { color:#9ca3af; font-size:10px; font-family:"Consolas",monospace; word-break:break-all; max-width:160px; }')
    table.insert(out, '.nm-bind-btn { background:#2563eb; color:#fff; border:none; border-radius:5px; padding:3px 12px; font-size:12px; cursor:pointer; }')
    table.insert(out, '.nm-bind-btn:hover { opacity:0.85; }')
    table.insert(out, '.nm-bind-btn:disabled { opacity:0.5; cursor:default; }')
    table.insert(out, '.nm-unbind-btn { background:#dc2626; color:#fff; border:none; border-radius:5px; padding:3px 12px; font-size:12px; cursor:pointer; }')
    table.insert(out, '.nm-unbind-btn:hover { opacity:0.85; }')
    table.insert(out, '.nm-unbind-btn:disabled { opacity:0.5; cursor:default; }')
    table.insert(out, '</style>')

    -- v1.8.4：一键绑定 API 地址与 CSRF token（与控制器 csrf_token 同源）
    local nm_api = luci.dispatcher.build_url("admin", "netmanager", "api")
    local nm_tok = (luci.dispatcher.context and luci.dispatcher.context.authtoken) and tostring(luci.dispatcher.context.authtoken) or ""
    table.insert(out, '<script>')
    table.insert(out, 'function nmToggleV6(id){var el=document.getElementById(id);var btn=document.getElementById(id+"_btn");if(el.style.display==="block"){el.style.display="none";btn.textContent=btn.getAttribute("data-more");}else{el.style.display="block";btn.textContent="收起";}}')
    table.insert(out, 'var NM_API="' .. nm_api .. '";var NM_TOKEN="' .. nm_tok .. '";')
    table.insert(out, 'function nmBind(btn){var mac=btn.getAttribute("data-mac"),ip=btn.getAttribute("data-ip"),name=btn.getAttribute("data-name"),duid=btn.getAttribute("data-duid");btn.disabled=true;btn.textContent="绑定中";var body=new URLSearchParams();body.set("action","static_bind");body.set("token",NM_TOKEN);body.set("mac",mac);body.set("ip",ip||"");body.set("name",name||"");body.set("duid",duid||"");fetch(NM_API,{method:"POST",headers:{"Content-Type":"application/x-www-form-urlencoded; charset=UTF-8"},body:body.toString(),credentials:"same-origin"}).then(function(r){return r.text();}).then(function(t){if(t.indexOf("[ERROR]")>=0){alert("绑定失败："+t.replace(/\\[CMD\\][^\\n]*\\n?/,"").trim());btn.disabled=false;btn.textContent="绑定";}else{location.reload();}}).catch(function(e){alert("请求失败："+e);btn.disabled=false;btn.textContent="绑定";});}')
    table.insert(out, 'function nmUnbind(btn){var mac=btn.getAttribute("data-mac");if(!confirm("确定解绑 "+mac+" ？解绑后该设备恢复动态分配。"))return;btn.disabled=true;btn.textContent="解绑中";var body=new URLSearchParams();body.set("action","static_unbind");body.set("token",NM_TOKEN);body.set("mac",mac);fetch(NM_API,{method:"POST",headers:{"Content-Type":"application/x-www-form-urlencoded; charset=UTF-8"},body:body.toString(),credentials:"same-origin"}).then(function(r){return r.text();}).then(function(t){if(t.indexOf("[ERROR]")>=0){alert("解绑失败："+t.replace(/\\[CMD\\][^\\n]*\\n?/,"").trim());btn.disabled=false;btn.textContent="解绑";}else{location.reload();}}).catch(function(e){alert("请求失败："+e);btn.disabled=false;btn.textContent="解绑";});}')
    table.insert(out, 'document.addEventListener("click",function(e){if(!e.target.closest)return;var b=e.target.closest(".nm-bind-btn");if(b){nmBind(b);return;}var u=e.target.closest(".nm-unbind-btn");if(u){nmUnbind(u);}});')
    table.insert(out, '</script>')

    table.insert(out, '<table class="nm-ov-table">')
    table.insert(out, '<tr><th style="width:130px">' .. translate("状态") .. '</th><th style="width:140px">MAC</th><th>' .. translate("主机名") .. '</th><th style="width:130px">IPv4</th><th>IPv6</th><th style="width:90px">' .. translate("绑定") .. '</th><th style="width:80px">' .. translate("操作") .. '</th></tr>')

    local row_idx = 0
    for _, r in ipairs(ov_rows) do
        row_idx = row_idx + 1
        local v4 = r.ip ~= "" and esc(r.ip) or '<span style="color:#d1d5db">—</span>'
        local name = r.name ~= "" and esc(r.name) or '<span style="color:#d1d5db">—</span>'

        -- IPv6 地址折叠：过滤掉链路本地地址(fe80)，全局地址第一个显示，其余折叠
        local global_v6 = {}
        for _, a in ipairs(r.ip6s) do
            if not a:match("^fe80") then
                table.insert(global_v6, a)
            end
        end

        local v6_html = ""
        -- v1.8.6：标注地址性质——公网 GUA(2000::/3) 随前缀/SLAAC 变化属动态，
        -- ULA(fd/fc) 才是可静态绑定的稳定地址，避免把动态公网误认为静态绑定。
        local function v6tag(a)
            if a:match("^[23]") then
                return '<span style="color:#9ca3af;font-size:10px;">动态公网 </span>'
            elseif a:lower():match("^f[cd]") then
                return '<span style="color:#059669;font-size:10px;">ULA </span>'
            end
            return ''
        end
        if #global_v6 == 0 then
            v6_html = '<span style="color:#d1d5db">—</span>'
        else
            v6_html = '<span class="nm-ov-v6-main">' .. v6tag(global_v6[1]) .. esc(global_v6[1]) .. '</span>'
            if #global_v6 > 1 then
                local more_count = #global_v6 - 1
                local all_id = 'nm_v6_all_' .. row_idx
                local btn_id = all_id .. '_btn'
                v6_html = v6_html .. '<span class="nm-ov-v6-more" id="' .. btn_id .. '" data-more="+' .. more_count .. ' 个" onclick="nmToggleV6(\'' .. all_id .. '\')">+' .. more_count .. ' 个</span>'
                v6_html = v6_html .. '<div class="nm-ov-v6-all" id="' .. all_id .. '">'
                for i = 2, #global_v6 do
                    v6_html = v6_html .. '<span>' .. v6tag(global_v6[i]) .. esc(global_v6[i]) .. '</span>'
                end
                v6_html = v6_html .. '</div>'
            end
        end

        -- 绑定状态徽章
        local badge = r.bound
            and '<span class="nm-ov-badge nm-ov-badge-bound">' .. translate("已绑定") .. '</span>'
            or '<span class="nm-ov-badge nm-ov-badge-unbound">' .. translate("未绑定") .. '</span>'

        -- 在线状态 + DUID
        local status_html = '<span class="nm-ov-online"></span><span style="color:#059669;font-size:11px;font-weight:600;">在线</span>'
        if r.duid and r.duid ~= "" then
            status_html = status_html .. '<br><span class="nm-ov-duid" title="DUID: ' .. esc(r.duid) .. '">DUID: ' .. esc(r.duid:sub(1, 16)) .. '...</span>'
        end

        -- v1.8.5：操作列——已绑定设备可一键解绑，未绑定设备一键绑定（data 属性传参，委托点击）
        local action_html
        if r.bound then
            action_html = '<button class="nm-unbind-btn" data-mac="' .. esc(r.mac) .. '">' .. translate("解绑") .. '</button>'
        else
            action_html = '<button class="nm-bind-btn" data-mac="' .. esc(r.mac) .. '" data-ip="' .. esc(r.ip)
                .. '" data-name="' .. esc(r.name) .. '" data-duid="' .. esc(r.duid) .. '">' .. translate("绑定") .. '</button>'
        end

        table.insert(out, string.format(
            '<tr><td>%s</td><td class="nm-ov-mono">%s</td><td>%s</td>' ..
            '<td class="nm-ov-mono">%s</td><td>%s</td><td>%s</td><td>%s</td></tr>',
            status_html, esc(r.mac), name, v4, v6_html, badge, action_html))
    end
    table.insert(out, '</table>')
    return table.concat(out, "\n")
end
local online_html = build_online_html()

-- ============================================================
-- 页面描述
-- ============================================================
local desc = translate("为设备绑定静态 IPv4 / IPv6 地址。IPv4 填 ip；IPv6 推荐填 hostid（地址后缀），运营商前缀变化时地址仍保持一致；ip6 填完整地址，仅适合 ULA 或前缀固定场景。")
if merged_count > 0 then
    desc = desc .. " \n\n" .. translate("注意") .. "：" .. translate("检测到") .. " " .. merged_count .. " " ..
        translate("个重复的 MAC 绑定条目，点击「保存并应用」时将自动合并。")
end

m = Map("dhcp", translate("静态 IP / IPv6 分配"), desc)

-- v1.4.6 修复：CBI 页面缺少页内导航（从自绘页面进入后页签消失），注入导航模板
m:append(Template("netmanager/cbi_nav"))

-- 保存前：合并重复 MAC 条目 + 清理幽灵条目（MAC 与 DUID 均为空，避免"消失但占位"无法删除）
-- 【v1.4.6】合并由页面加载时移入此处（仅在真实提交时写库，GET 刷新不再改配置）
-- 【v1.4.7 防御】pcall 包裹：合并/清理异常不阻断用户保存，错误透传到页面消息
m.on_before_commit = function(self)
    local ok, err = pcall(function()
        do_merge_duplicate_hosts(self.uci)
        local to_del = {}
        self.uci:foreach("dhcp", "host", function(s)
            local mac = s.mac or ""
            local duid = s.duid or ""
            if mac == "" and duid == "" then
                table.insert(to_del, s[".name"])
            end
        end)
        for _, n in ipairs(to_del) do
            self.uci:delete("dhcp", n)
        end
    end)
    if not ok then
        self.message = "重复条目合并/幽灵清理失败（保存仍已继续）：" .. tostring(err)
    end
end

-- 保存后应用配置（dnsmasq 用 reload 避免 DNS 中断）
-- 【v1.4.6】odhcpd 由无条件 restart 改为按需：仅本次有实际改动（changed）才重启，
-- 避免每次保存（甚至无改动提交）都导致 IPv6 租约重置、设备短暂掉线
m.on_after_commit = function(self)
    if self.changed then
        -- v1.8.0：先收敛可能存在的重复 odhcpd 实例再统一拉起。
        -- 直接 restart 在已有手动实例时会留下两个进程同时写 RFC9096 piofile，
        -- 造成前缀记忆互相覆盖、RA 广播不一致。
        sys.call([=[
            n=$(ps w 2>/dev/null | grep -c '[o]dhcpd')
            if [ "$n" -gt 1 ]; then
                /etc/init.d/odhcpd stop >/dev/null 2>&1
                sleep 1
                killall odhcpd 2>/dev/null
                sleep 1
                /etc/init.d/odhcpd start >/dev/null 2>&1
            else
                /etc/init.d/odhcpd restart >/dev/null 2>&1
            fi
        ]=])
        -- v1.8.0：hostid / 静态绑定变化会改变主机的 IPv6 后缀，
        -- 已登记跟踪的端口转发目标需要随之重算。
        sys.call("/usr/sbin/netmanager port_sync_v6 --quiet >/dev/null 2>&1 &")
    end
    sys.call("/etc/init.d/dnsmasq reload >/dev/null 2>&1")
end

-- ============================================================
-- 在线客户端速览（含未绑定设备，方便复制 MAC / DUID 到下方新增绑定）
-- ============================================================
local ss = m:section(SimpleSection, translate("在线客户端"), translate("列出当前识别到的在线设备（IPv4 + IPv6）。未绑定设备可直接复制其 MAC 地址，在下方「设备列表」新增绑定。"))
local ov = ss:option(DummyValue, "_online_clients")
ov.rawhtml = true
function ov.cfgvalue(self, section)
    return online_html
end

-- ============================================================
-- 设备列表
-- ============================================================
s = m:section(TypedSection, "host", translate("设备列表"))
s.addremove = true
s.anonymous = true
s.sortable = false
s.template = "cbi/tblsection"

-- 显示有 MAC 或有 DUID 的条目（支持 IPv6-only 绑定；全空条目由 on_before_commit 清理）
function s.filter(self, section)
    local mac = m.uci:get("dhcp", section, "mac")
    local duid = m.uci:get("dhcp", section, "duid")
    return (mac ~= nil and mac ~= "") or (duid ~= nil and duid ~= "")
end

-- ---------- 主机名 ----------
o_hostname = s:option(Value, "name", translate("主机名"))
o_hostname.rmempty = true
o_hostname.datatype = "hostname"
o_hostname.size = 14

-- ---------- MAC 地址 ----------
o_mac = s:option(Value, "mac", translate("MAC 地址"))
o_mac.rmempty = false
o_mac.datatype = "macaddr"
o_mac.size = 18
o_mac.description = translate("MAC 与 DUID 至少填一个；留空 MAC 仅适用于纯 DHCPv6(DUID) 绑定")
function o_mac.validate(self, value, section)
    if value and value ~= "" then
        value = value:upper()
        if not value:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
            return nil, translate("MAC 地址格式无效（应为 AA:BB:CC:DD:EE:FF）")
        end
        -- 实时查重（含同批提交的新值，而非页面加载时快照）
        local conflict
        m.uci:foreach("dhcp", "host", function(s2)
            if s2[".name"] ~= section and s2.mac and s2.mac ~= "" and s2.mac:upper() == value then
                conflict = s2.name or s2.mac
            end
        end)
        if conflict then
            return nil, translate("该 MAC 已被其他条目绑定") .. ": " .. esc(conflict)
        end
        return value
    end
    return value
end

-- ---------- 当前在线 IP（只读，IPv4 + IPv6 折叠显示） ----------
o_cur_ip = s:option(DummyValue, "_current_ip", translate("当前在线IP"))
o_cur_ip.rawhtml = true
local cur_ip_row = 0
function o_cur_ip.cfgvalue(self, section)
    cur_ip_row = cur_ip_row + 1
    local mac_val = m.uci:get("dhcp", section, "mac")
    if mac_val then
        local dev = online_devices[mac_val:upper()]
        if dev then
            local parts = {}
            if dev.ip and dev.ip ~= "" then
                table.insert(parts, '<span style="font-family:monospace;font-size:12px;color:#111827">' .. esc(dev.ip) .. '</span>')
            end
            -- IPv6 全局地址折叠（过滤 fe80 链路本地）
            local global_v6 = {}
            for _, a in ipairs(dev.ip6s) do
                if not a:match("^fe80") then
                    table.insert(global_v6, a)
                end
            end
            if #global_v6 > 0 then
                local v6_html = '<span style="font-family:monospace;font-size:11px;color:#2563eb;word-break:break-all">' .. esc(global_v6[1]) .. '</span>'
                if #global_v6 > 1 then
                    local more = #global_v6 - 1
                    local aid = 'nm_cur_v6_' .. cur_ip_row
                    v6_html = v6_html .. '<span class="nm-ov-v6-more" id="' .. aid .. '_btn" data-more="+' .. more .. '" onclick="nmToggleV6(\'' .. aid .. '\')">+' .. more .. '</span>'
                    v6_html = v6_html .. '<div class="nm-ov-v6-all" id="' .. aid .. '">'
                    for i = 2, #global_v6 do
                        v6_html = v6_html .. '<span>' .. esc(global_v6[i]) .. '</span>'
                    end
                    v6_html = v6_html .. '</div>'
                end
                table.insert(parts, v6_html)
            end
            if dev.duid and dev.duid ~= "" then
                table.insert(parts, '<span style="color:#9ca3af;font-family:monospace;font-size:10px" title="DUID: ' .. esc(dev.duid) .. '">DUID: ' .. esc(dev.duid:sub(1, 12)) .. '…</span>')
            end
            if #parts > 0 then
                local dot = dev.online and '<span class="nm-ov-online"></span>' or '<span class="nm-ov-offline"></span>'
                local label = dev.online and '<span style="color:#059669;font-size:10px;font-weight:600">在线</span>' or '<span style="color:#9ca3af;font-size:10px">离线</span>'
                return dot .. label .. '<br>' .. table.concat(parts, '<br>')
            end
        end
    end
    return '<span class="nm-ov-offline"></span><span style="color:#9ca3af;font-size:11px">' .. translate("离线/未发现") .. '</span>'
end

-- ---------- IPv4 静态地址 ----------
o_ip4 = s:option(Value, "ip", translate("IPv4静态地址"))
o_ip4.rmempty = true
o_ip4.datatype = "ip4addr"
o_ip4.size = 15
function o_ip4.validate(self, value, section)
    if value and value ~= "" then
        local conflict
        m.uci:foreach("dhcp", "host", function(s2)
            if s2[".name"] ~= section and s2.ip and s2.ip ~= "" and s2.ip == value then
                conflict = s2.mac or s2.name or s2[".name"]
            end
        end)
        if conflict then
            return nil, translate("该 IPv4 已被其他条目使用") .. ": " .. esc(conflict)
        end
        -- v1.8.4：校验落在 LAN 网段且不等于路由器自身地址
        local lanip = sys.exec("uci -q get network.lan.ipaddr 2>/dev/null"):gsub("%s+", "")
        if lanip ~= "" then
            if value == lanip then
                return nil, translate("该 IPv4 是路由器自身地址，不可绑定")
            end
            local lp = lanip:match("^(%d+%.%d+%.%d+)%.")
            local vp = value:match("^(%d+%.%d+%.%d+)%.")
            if lp and vp and lp ~= vp then
                return nil, translate("该 IPv4 不在 LAN 网段") .. " " .. lp .. ".0/24 " .. translate("内")
            end
        end
    end
    return value
end

-- ---------- IPv6 hostid ----------
o_hostid = s:option(Value, "hostid", translate("IPv6 hostid"))
o_hostid.rmempty = true
o_hostid.size = 10
o_hostid.description = translate("十六进制后缀，如 fbe = 前缀::fbe")
function o_hostid.validate(self, value, section)
    if value and value ~= "" then
        if not value:match("^[0-9a-fA-F]+$") then
            return nil, translate("hostid 必须是十六进制字符（0-9, a-f）")
        end
        if #value > 8 then
            return nil, translate("hostid 最多 8 位十六进制")
        end
        local val_lower = value:lower()
        local conflict
        m.uci:foreach("dhcp", "host", function(s2)
            if s2[".name"] ~= section and s2.hostid and s2.hostid ~= "" and s2.hostid:lower() == val_lower then
                conflict = s2.mac or s2.name or s2[".name"]
            end
        end)
        if conflict then
            return nil, translate("hostid 与其他设备冲突，请换一个值") .. ": " .. esc(conflict)
        end
    end
    return value
end

-- ---------- 完整 IPv6 地址 ----------
o_ip6 = s:option(Value, "ip6", translate("完整IPv6地址(可选)"))
o_ip6.rmempty = true
o_ip6.datatype = "ip6addr"
o_ip6.size = 28
o_ip6.description = translate("仅适合 ULA(fd开头)，留空则用 hostid 自动生成")
function o_ip6.validate(self, value, section)
    if value and value ~= "" then
        local val_lower = value:lower()
        -- v1.8.6：完整 IPv6 仅允许 ULA（fc00::/7，实际 fd 开头）。
        -- 公网 GUA（2000::/3，如 24xx/2408）随运营商前缀重拨变化、SLAAC 后缀随机，
        -- 设为静态必失效；公网地址请改用 hostid 后缀（按当前前缀自动合成，前缀变仍一致）。
        if not val_lower:match("^f[cd]") then
            return nil, translate("完整IPv6仅支持 ULA(fd/fc 开头)；公网地址(如2408)会随前缀变化失效，请改用 hostid 后缀")
        end
        local conflict
        m.uci:foreach("dhcp", "host", function(s2)
            if s2[".name"] ~= section and s2.ip6 and s2.ip6 ~= "" and s2.ip6:lower() == val_lower then
                conflict = s2.mac or s2.name or s2[".name"]
            end
        end)
        if conflict then
            return nil, translate("该完整 IPv6 地址已被其他条目使用") .. ": " .. esc(conflict)
        end
    end
    return value
end

-- ---------- DUID（可编辑，统一无冒号 hex 存储） ----------
o_duid = s:option(Value, "duid", translate("DUID(可选)"))
o_duid.rmempty = true
o_duid.size = 24
o_duid.description = translate("DHCPv6 专有标识，用于 IPv6-only 绑定；设备在线时可在「当前在线IP」列查看捕获值")
function o_duid.validate(self, value, section)
    if value and value ~= "" then
        local stripped = value:gsub(":", "")
        if not stripped:match("^[0-9a-fA-F]+$") or #stripped < 4 or #stripped > 130 then
            return nil, translate("DUID 格式无效（应为十六进制，可带冒号）")
        end
        return stripped  -- odhcpd 用 unheximize 解析，必须无冒号
    end
    return value
end

-- ---------- 启用开关 ----------
o_enabled = s:option(Flag, "enabled", translate("启用"))
o_enabled.rmempty = false
o_enabled.default = "1"

return m


```

### 5.7 files/usr/lib/lua/luci/view/netmanager/common_head.htm

- **用途**：全部视图公共头：CSS 样式 + 公共 JS（escapeHtml / nmFetch / CSRF token / withBusy）
- **规模**：232 行
- **维护要点**：nmFetch 支持 FormData/string/URLSearchParams 三种体，新增调用勿绕开它

```html
<style>
/* 网络管理 - 简洁风格 v1.1 */
.netmanager-container { max-width: 1200px; margin: 0 auto; padding: 16px; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", sans-serif; color: #1f2937; }
.netmanager-header { display: flex; justify-content: space-between; align-items: center; padding: 14px 20px; background: #fff; border-radius: 8px; margin-bottom: 12px; box-shadow: 0 1px 2px rgba(0,0,0,0.06); border: 1px solid #e5e7eb; }
.netmanager-header h1 { margin: 0; font-size: 18px; font-weight: 600; color: #111827; }
.netmanager-author { font-size: 12px; color: #9ca3af; }
.netmanager-nav { display: flex; gap: 2px; background: #fff; padding: 6px; border-radius: 8px; margin-bottom: 12px; box-shadow: 0 1px 2px rgba(0,0,0,0.06); border: 1px solid #e5e7eb; flex-wrap: wrap; }
.netmanager-nav a { padding: 7px 14px; text-decoration: none; color: #6b7280; border-radius: 6px; font-size: 13px; transition: all 0.15s; }
.netmanager-nav a:hover { background: #f3f4f6; color: #111827; }
.netmanager-nav a.active { background: #2563eb; color: #fff; }
.netmanager-content { background: #fff; border-radius: 8px; padding: 20px; box-shadow: 0 1px 2px rgba(0,0,0,0.06); border: 1px solid #e5e7eb; }
.netmanager-content h2 { margin: 0 0 16px 0; font-size: 16px; font-weight: 600; color: #111827; padding-bottom: 12px; border-bottom: 1px solid #f3f4f6; }
.netmanager-content h3 { margin: 20px 0 10px 0; font-size: 14px; font-weight: 600; color: #374151; }
/* 统计卡片 */
.netmanager-cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px; margin-bottom: 20px; }
.netmanager-card { background: #f9fafb; border-radius: 8px; padding: 14px; text-align: center; border: 1px solid #e5e7eb; }
.netmanager-card .card-icon { font-size: 20px; margin-bottom: 4px; }
.netmanager-card .card-label { font-size: 11px; color: #9ca3af; margin-bottom: 4px; }
.netmanager-card .card-value { font-size: 22px; font-weight: 700; color: #111827; }
.netmanager-card .card-value.green { color: #10b981; }
.netmanager-card .card-value.red { color: #ef4444; }
.netmanager-card .card-value.orange { color: #f59e0b; }
.netmanager-card .card-value.blue { color: #2563eb; }
/* 表格 */
.netmanager-table { width: 100%; border-collapse: collapse; font-size: 13px; }
.netmanager-table th { background: #f9fafb; padding: 9px 12px; text-align: left; font-weight: 600; color: #6b7280; border-bottom: 1px solid #e5e7eb; font-size: 12px; }
.netmanager-table td { padding: 9px 12px; border-bottom: 1px solid #f3f4f6; color: #374151; }
.netmanager-table tr:hover td { background: #f9fafb; }
/* 按钮 */
.btn { padding: 6px 14px; border: none; border-radius: 6px; font-size: 13px; cursor: pointer; transition: opacity 0.15s; text-decoration: none; display: inline-block; }
.btn:hover { opacity: 0.85; }
.btn-primary { background: #2563eb; color: #fff; }
.btn-success { background: #10b981; color: #fff; }
.btn-danger { background: #ef4444; color: #fff; }
.btn-warning { background: #f59e0b; color: #fff; }
.btn-secondary { background: #6b7280; color: #fff; }
.btn-sm { padding: 4px 10px; font-size: 12px; }
/* 表单 */
.netmanager-form { background: #f9fafb; padding: 14px; border-radius: 8px; margin-bottom: 16px; border: 1px solid #e5e7eb; }
.netmanager-form label { display: inline-block; font-size: 12px; color: #6b7280; margin-right: 6px; font-weight: 500; }
.netmanager-form input, .netmanager-form select { padding: 5px 9px; border: 1px solid #d1d5db; border-radius: 5px; font-size: 13px; margin-right: 10px; margin-bottom: 6px; background: #fff; }
.netmanager-form input:focus, .netmanager-form select:focus { outline: none; border-color: #2563eb; }
/* 日志 */
.netmanager-log { background: #1f2937; color: #d1d5db; padding: 12px; border-radius: 6px; font-family: "Consolas", "Monaco", "Courier New", monospace; font-size: 12px; line-height: 1.9; max-height: 450px; overflow-y: auto; }
.netmanager-log .log-success { color: #34d399; }
.netmanager-log .log-fail { color: #f87171; }
.netmanager-log .log-time { color: #9ca3af; }
.netmanager-log .log-ip { color: #60a5fa; }
/* 状态标签 */
.badge { display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 11px; font-weight: 600; }
.badge-green { background: #d1fae5; color: #059669; }
.badge-red { background: #fee2e2; color: #dc2626; }
.badge-gray { background: #f3f4f6; color: #6b7280; }
.badge-blue { background: #dbeafe; color: #2563eb; }
.badge-orange { background: #fef3c7; color: #d97706; }
.badge-purple { background: #ede9fe; color: #7c3aed; }
/* 底部 */
.footer-sign { text-align: center; padding: 14px; color: #d1d5db; font-size: 11px; margin-top: 12px; }
/* 空状态 */
.empty-state { text-align: center; padding: 24px; color: #9ca3af; font-size: 13px; }
/* 工具栏 */
.netmanager-toolbar { display: flex; gap: 8px; align-items: center; margin-bottom: 14px; flex-wrap: wrap; }
.netmanager-toolbar select, .netmanager-toolbar input { padding: 5px 9px; border: 1px solid #d1d5db; border-radius: 5px; font-size: 13px; background: #fff; }
/* 结果区 */
.result-pre { background: #1f2937; color: #d1d5db; padding: 10px; border-radius: 6px; overflow-x: auto; font-size: 12px; line-height: 1.6; margin-top: 10px; }
.netmanager-result { margin-top: 10px; }
/* 提示文字 */
.text-muted { color: #9ca3af; font-size: 12px; }
.text-success { color: #10b981; }
.text-danger { color: #ef4444; }
.text-warning { color: #f59e0b; }
.text-info { color: #2563eb; }
</style>
<script>
/* ===== 公共 JS（v1.4.7）：HTML转义 + API 调用封装（token/超时/会话过期） =====
   背景：命令输出（含用户可控的文件名/用户名/日志内容）此前直接拼 innerHTML，
   构成存储型 XSS；统一走本封装消除注入面。
   v1.4.6：API 强制 CSRF Token（渲染时注入变量），apiFetch 自动携带。
   v1.4.7：改用 LuCI 框架内建模板变量 token（= context.authtoken，与 CBI 表单
   同源），不再 require controller 模块（v1.4.6 的自派生 token 在 ucode LuCI
   下因 context.session.id 不存在而恒为空，导致全部 API 403）。 */

/* CSRF Token：框架 authtoken，所有 API 调用必须携带（跨站页面拿不到）
   注：CBI 页面不加载本文件，其表单按钮由 LuCI 框架自身 token 机制保护
   v1.4.7 修复：不依赖模板变量 token（ucode LuCI 中该变量可能为空导致全部 API 403），
   直接从 luci.dispatcher.context.authtoken 获取，与控制器 csrf_token() 同源 */
<% local _nm_authtok = (luci.dispatcher.context and luci.dispatcher.context.authtoken) and tostring(luci.dispatcher.context.authtoken) or "" %>
var CSRF_TOKEN = '<%=pcdata(_nm_authtok)%>';

/* HTML 转义：任何要写入 innerHTML 的动态内容必须先过此函数 */
function escapeHtml(s) {
	if (s === null || s === undefined) return '';
	return String(s).replace(/[&<>"']/g, function (c) {
		switch (c) {
			case '&': return '&amp;';
			case '<': return '&lt;';
			case '>': return '&gt;';
			case '"': return '&quot;';
			case "'": return '&#39;';
		}
	});
}

/* 将命令输出安全渲染到结果容器（自动转义，带 [CMD] 行灰色样式）
   el: 结果容器 DOM；data: 后端返回的纯文本 */
function showResult(el, data) {
	if (!el) return;
	if (typeof data !== 'string') data = String(data == null ? '' : data);
	var lines = data.split('\n').map(function (l) {
		var e = escapeHtml(l);
		return (/^\[CMD\]/.test(l)) ? '<span style="color:#9ca3af">' + e + '</span>' : e;
	});
	el.innerHTML = '<pre class="result-pre">' + lines.join('\n') + '</pre>';
}

/* API 调用封装：POST + CSRF Token + 超时控制 + 错误提示
   v1.4.6 兼容三种调用形态：
   1) apiFetch('action', {k: 'v'}, opts)   —— 常规调用（推荐）
   2) apiFetch('action=x&k=v')              —— 兼容旧 fetch 的原始 body 字符串
      （首参含 '=' 视为原始 body，自动追加 token）
   3) apiFetch(null, formData)              —— FormData 上传（调用方自行 append action，
      本函数只补 token） */
function apiFetch(action, params, opts) {
	opts = opts || {};
	var isForm = (params instanceof FormData);
	var body;
	if (isForm) {
		body = params;
		body.append('token', CSRF_TOKEN);
	} else if (typeof action === 'string' && action.indexOf('=') > 0) {
		// 原始 body 字符串形态：直接追加 token
		body = action + '&token=' + encodeURIComponent(CSRF_TOKEN);
	} else {
		params = params || {};
		body = new URLSearchParams();
		body.set('action', action);
		body.set('token', CSRF_TOKEN);
		for (var k in params) { if (params.hasOwnProperty(k)) body.set(k, params[k]); }
		body = body.toString();
	}

	var ctrl = new AbortController();
	var timer = setTimeout(function () { ctrl.abort(); }, opts.timeout || 30000);

	// 与各视图一致：用 LuCI dispatcher 生成 API 绝对地址（避免依赖 REQUEST_URI 推导）
	var API_URL = '<%=luci.dispatcher.build_url("admin/netmanager/api")%>';
	return fetch(API_URL, {
		method: 'POST',
		headers: isForm ? {} : { 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8' },
		body: body,
		signal: ctrl.signal,
		credentials: 'same-origin'
	}).then(function (res) {
		clearTimeout(timer);
		if (res.redirected && /\/login\.html|\/admin\/login/.test(res.url)) {
			throw new Error('会话已过期，请刷新页面重新登录');
		}
		if (res.status === 403) {
			return res.text().then(function (t) { throw new Error(t.replace('[ERROR] ', '') || 'CSRF 校验失败，请刷新页面'); });
		}
		if (!res.ok) throw new Error('服务器响应异常: HTTP ' + res.status);
		return res.text();
	}).catch(function (err) {
		clearTimeout(timer);
		if (err.name === 'AbortError') throw new Error('请求超时，请稍后重试');
		throw err;
	});
}

/* nmFetch：v1.4.6 兼容层——原 fetch(API_URL, {...}) 调用的零改动迁移
   自动完成：POST + CSRF Token 附加 + 超时 + 会话过期/403 检测 + FormData 支持
   形态1：nmFetch({method:'POST', headers:{...}, body:'action=x&k=v'})
   形态2：nmFetch({method:'POST', body: formData})  // multipart 上传，token 附加到 FormData
   v1.4.9 修复：返回 Response 对象（与原生 fetch 一致），此前内部已 res.text() 返回字符串，
   但调用方仍写 .then(r => r.text()) 导致 "r.text is not a function" 全部 API 失败 */
function nmFetch(opts) {
	opts = opts || {};
	var isForm = (opts.body instanceof FormData);
	if (isForm) {
		opts.body.append('token', CSRF_TOKEN);
	} else if (typeof URLSearchParams !== 'undefined' && opts.body instanceof URLSearchParams) {
		// v1.8.10：URLSearchParams 形态此前漏补 token → 403 静默失败（规则页"添加无反应"根因）
		opts.body.set('token', CSRF_TOKEN);
		opts.body = opts.body.toString();
	} else if (typeof opts.body === 'string') {
		opts.body = opts.body + (opts.body ? '&' : '') + 'token=' + encodeURIComponent(CSRF_TOKEN);
	}

	var ctrl = new AbortController();
	var timer = setTimeout(function () { ctrl.abort(); }, 90000); // 在线更新下载等长操作给足 90s

	var API_URL = '<%=luci.dispatcher.build_url("admin/netmanager/api")%>';
	return fetch(API_URL, {
		method: opts.method || 'POST',
		headers: isForm ? {} : (opts.headers || { 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8' }),
		body: opts.body,
		signal: ctrl.signal,
		credentials: 'same-origin'
	}).then(function (res) {
		clearTimeout(timer);
		if (res.redirected && /\/login\.html|\/admin\/login/.test(res.url)) {
			throw new Error('会话已过期，请刷新页面重新登录');
		}
		if (res.status === 403) {
			return res.text().then(function (t) { throw new Error(t.replace('[ERROR] ', '') || 'CSRF 校验失败，请刷新页面'); });
		}
		if (!res.ok) throw new Error('服务器响应异常: HTTP ' + res.status);
		return res;  // v1.4.9：返回 Response 对象，调用方自行 .text() / .json()
	}).catch(function (err) {
		clearTimeout(timer);
		if (err.name === 'AbortError') throw new Error('请求超时，请稍后重试');
		throw err;
	});
}

/* 按钮防抖：执行期间禁用按钮，防止重复提交
   用法: withBusy(btn, function(){ return fetch...; }) */
function withBusy(btn, fn) {
	if (!btn) { return Promise.resolve().then(fn); }
	if (btn.disabled) { return Promise.resolve(); }
	btn.disabled = true;
	btn.style.opacity = '0.6';
	var restore = function () {
		btn.disabled = false;
		btn.style.opacity = '';
	};
	return Promise.resolve().then(fn).then(
		function (v) { restore(); return v; },
		function (e) { restore(); throw e; }
	);
}
</script>


```

### 5.8 files/usr/lib/lua/luci/view/netmanager/nav.htm

- **用途**：页内导航条：防火墙 6 页 + 上网设置 / 静态 IP 两个 CBI 入口
- **规模**：10 行
- **维护要点**：与 controller 菜单双维护，新增页面两处同步

```html
<div class="netmanager-nav">
    <a href="<%=luci.dispatcher.build_url("admin/netmanager/overview")%>" class="<% if luci.dispatcher.context.requestpath[3] == 'overview' then %>active<% end %>">📊 系统概览</a>
    <a href="<%=luci.dispatcher.build_url("admin/netmanager/port_forward")%>" class="<% if luci.dispatcher.context.requestpath[3] == 'port_forward' then %>active<% end %>">🔄 端口转发</a>
    <a href="<%=luci.dispatcher.build_url("admin/netmanager/firewall_rules")%>" class="<% if luci.dispatcher.context.requestpath[3] == 'firewall_rules' then %>active<% end %>">📋 规则管理</a>
    <a href="<%=luci.dispatcher.build_url("admin/netmanager/ssh_log")%>" class="<% if luci.dispatcher.context.requestpath[3] == 'ssh_log' then %>active<% end %>">🔐 SSH登录日志</a>
    <a href="<%=luci.dispatcher.build_url("admin/netmanager/access_log")%>" class="<% if luci.dispatcher.context.requestpath[3] == 'access_log' then %>active<% end %>">🌐 端口访问日志</a>
    <a href="<%=luci.dispatcher.build_url("admin/netmanager/dns")%>" class="<% if luci.dispatcher.context.requestpath[3] == 'dns' then %>active<% end %>">🌐 上网设置</a>
    <a href="<%=luci.dispatcher.build_url("admin/netmanager/dns_staticv6")%>" class="<% if luci.dispatcher.context.requestpath[3] == 'dns_staticv6' then %>active<% end %>">📮 静态IP分配</a>
    <a href="<%=luci.dispatcher.build_url("admin/netmanager/settings")%>" class="<% if luci.dispatcher.context.requestpath[3] == 'settings' then %>active<% end %>">⚙️ 设置</a>
</div>


```

### 5.9 files/usr/lib/lua/luci/view/netmanager/cbi_nav.htm

- **用途**：CBI 页面专用导航条：自带内联样式，由两个 CBI 模型以 Template 节点注入
- **规模**：114 行
- **维护要点**：CBI 页不加载 common_head，样式必须内联；active 判断带 nil 防护

```html
<%#
    netmanager/cbi_nav.htm - CBI 页面专用页内导航 + 布局对齐
    v1.8.4：让 CBI 页面（上网设置 / 静态IPv6分配）与自绘页面（端口转发等）布局一致：
            主题头 → 「网络管理」标题栏 → 导航条 → 单一白卡内容区（h2页标题 + 各h3子节）。
    做法：模板输出标题栏+导航+样式+脚本；脚本在 DOMContentLoaded 把两个 cbi-map
          （连同各自 form 整体移动，不破坏表单提交）合并进一个 .netmanager-content 卡片，
          页标题/描述移到导航下方。CBI 页面不加载 common_head.htm，样式在此自带。
    注意：LuCI 模板注释用井号语法，注释内不可出现百分号加大于号组合。
%>
<%
local path = luci.dispatcher.context.requestpath
local cur = (type(path) == "table") and (path[3] or "") or ""
local function url(...) return luci.dispatcher.build_url("admin", "netmanager", ...) end
local function cls(id) return (cur == id) and ' class="active"' or '' end
%>
<div class="netmanager-header">
    <h1>网络管理</h1>
    <span class="netmanager-author">吾爱破解liyu0828</span>
</div>
<div class="netmanager-nav">
    <a href="<%=url('overview')%>"<%=cls('overview')%>>📊 系统概览</a>
    <a href="<%=url('port_forward')%>"<%=cls('port_forward')%>>🔄 端口转发</a>
    <a href="<%=url('firewall_rules')%>"<%=cls('firewall_rules')%>>📋 规则管理</a>
    <a href="<%=url('ssh_log')%>"<%=cls('ssh_log')%>>🔐 SSH登录日志</a>
    <a href="<%=url('access_log')%>"<%=cls('access_log')%>>🌐 端口访问日志</a>
    <a href="<%=url('dns')%>"<%=cls('dns')%>>🌐 上网设置</a>
    <a href="<%=url('dns_staticv6')%>"<%=cls('dns_staticv6')%>>📮 静态IP分配</a>
    <a href="<%=url('settings')%>"<%=cls('settings')%>>⚙️ 设置</a>
</div>
<style>
/* ===== 与 common_head.htm 一致的框架样式（CBI 页面不加载 common_head，自带） ===== */
.netmanager-header { display:flex; justify-content:space-between; align-items:center; padding:14px 20px; background:#fff; border-radius:8px; margin-bottom:12px; box-shadow:0 1px 2px rgba(0,0,0,0.06); border:1px solid #e5e7eb; }
.netmanager-header h1 { margin:0; font-size:18px; font-weight:600; color:#111827; }
.netmanager-author { font-size:12px; color:#9ca3af; }
.netmanager-nav { display:flex; gap:2px; background:#fff; padding:6px; border-radius:8px; margin-bottom:12px; box-shadow:0 1px 2px rgba(0,0,0,0.06); border:1px solid #e5e7eb; flex-wrap:wrap; }
.netmanager-nav a { padding:7px 14px; text-decoration:none; color:#6b7280; border-radius:6px; font-size:13px; transition:all 0.15s; }
.netmanager-nav a:hover { background:#f3f4f6; color:#111827; }
.netmanager-nav a.active { background:#2563eb; color:#fff; }
.netmanager-content { background:#fff; border-radius:8px; padding:20px; box-shadow:0 1px 2px rgba(0,0,0,0.06); border:1px solid #e5e7eb; max-width:1200px; }
.netmanager-content > h2 { margin:0 0 16px 0; font-size:16px; font-weight:600; color:#111827; padding-bottom:12px; border-bottom:1px solid #f3f4f6; }
.nm-page-intro { color:#6b7280; font-size:13px; line-height:1.7; margin:0 0 18px 0; }
/* ===== CBI 元素改为内容卡内的扁平子节（对齐端口转发页的 h3 子节风格） ===== */
.cbi-map { background:transparent !important; border:none !important; box-shadow:none !important; padding:0 !important; margin:0 !important; max-width:none; }
.cbi-map > h2 { display:none; }
.cbi-section { background:transparent !important; border:none !important; box-shadow:none !important; padding:0 !important; margin:0 0 22px 0 !important; }
.cbi-section > h3 { color:#374151 !important; font-size:14px; font-weight:600; margin:0 0 10px 0; padding:0; border:none; }
.cbi-section-descr { color:#6b7280; font-size:13px; line-height:1.6; margin-bottom:12px; }
.cbi-value { padding:8px 0; border-bottom:1px solid #f9fafb; }
.cbi-value-title { color:#374151; font-weight:500; font-size:13px; }
.cbi-value-field { font-size:13px; color:#374151; }
.cbi-input-text, .cbi-input-select, .cbi-input-textarea,
input.cbi-input-text, select.cbi-input-select, textarea.cbi-input-textarea {
    border:1px solid #d1d5db !important; border-radius:5px; padding:5px 9px; font-size:13px; background:#fff; color:#1f2937; }
.cbi-input-text:focus, .cbi-input-select:focus, textarea:focus { outline:none; border-color:#2563eb !important; }
.cbi-button { border-radius:6px; font-size:13px; padding:6px 14px; border:none; cursor:pointer; }
.cbi-button-apply, .cbi-button-save { background:#2563eb !important; color:#fff !important; }
.cbi-button-neutral { background:#6b7280 !important; color:#fff !important; }
.cbi-button-reset, .cbi-button-link { background:#f3f4f6 !important; color:#374151 !important; }
.cbi-section-table, table.cbi-section-table { width:100%; border-collapse:collapse; font-size:13px; }
.cbi-section-table th { background:#f9fafb; color:#6b7280; font-weight:600; font-size:12px; padding:9px 12px; border-bottom:1px solid #e5e7eb; text-align:left; }
.cbi-section-table td { padding:9px 12px; border-bottom:1px solid #f3f4f6; vertical-align:top; }
.cbi-section-table tr:hover td { background:#f9fafb; }
.cbi-page-actions { padding:12px 0 0 0; text-align:right; }
</style>
<script>
/* v1.8.4：把 CBI 页面结构对齐自绘页面。
   将标题栏/导航提到内容卡之外，两个 cbi-map（含 form 整体）合并进单一 .netmanager-content，
   页标题取首个 map 的 h2（无则取导航 active 文本），描述作为引言置于标题下。
   整体移动 map 节点（form 随之移动），不拆解 form，保证 CBI 表单提交不受影响。 */
document.addEventListener('DOMContentLoaded', function () {
    var maps = Array.prototype.slice.call(document.querySelectorAll('.cbi-map'));
    if (!maps.length) return;
    var nav = document.querySelector('.netmanager-nav');
    var hdr = document.querySelector('.netmanager-header');
    if (!nav || !hdr) return;
    var first = maps[0];
    var parent = first.parentNode;
    if (!parent) return;

    var content = document.createElement('div');
    content.className = 'netmanager-content';
    parent.insertBefore(hdr, first);
    parent.insertBefore(nav, first);
    parent.insertBefore(content, first);

    /* 页标题：优先首个 map 自带 h2，否则用导航 active 文本（去掉开头 emoji） */
    var mh = first.querySelector(':scope > h2');
    var title = (mh && mh.textContent.trim()) ? mh.textContent.trim() : '';
    if (!title) {
        var active = nav.querySelector('a.active');
        title = active ? active.textContent.trim() : '';
        title = title.replace(/^[^一-龥A-Za-z]+/, '').trim();
    }
    if (title) {
        var h2 = document.createElement('h2');
        h2.textContent = title;
        content.appendChild(h2);
    }
    /* 描述作为引言 */
    var descr = first.querySelector('.cbi-map-descr');
    if (descr) { descr.className = 'nm-page-intro'; content.appendChild(descr); }

    /* 整体移动各 map（保留 form），去掉 map 级重复 h2 */
    maps.forEach(function (mp) {
        var h = mp.querySelector(':scope > h2');
        if (h && h.parentNode) h.parentNode.removeChild(h);
        content.appendChild(mp);
    });

    /* 框架保存按钮栏移入内容卡底部（与自绘页面按钮在卡内一致） */
    var acts = document.querySelector('.cbi-page-actions');
    if (acts) content.appendChild(acts);
});
</script>


```

### 5.10 files/usr/lib/lua/luci/view/netmanager/overview.htm

- **用途**：系统概览页：防火墙状态 / 端口统计 / 网络信息 / 快捷操作
- **规模**：118 行
- **维护要点**：footer 含版本号（登记处 4）

```html
<%+header%>
<%+netmanager/common_head%>
<div class="netmanager-container">
    <div class="netmanager-header">
        <h1>网络管理</h1>
        <span class="netmanager-author">吾爱破解liyu0828</span>
    </div>
    <%+netmanager/nav%>
    <div class="netmanager-content">
        <h2>系统概览</h2>
        <div class="netmanager-cards">
            <div class="netmanager-card">
                <div class="card-icon">🛡️</div>
                <div class="card-label">防火墙状态</div>
                <div class="card-value" id="fw_status">--</div>
            </div>
            <div class="netmanager-card">
                <div class="card-icon">🔄</div>
                <div class="card-label">端口转发</div>
                <div class="card-value blue" id="redirect_count">--</div>
            </div>
            <div class="netmanager-card">
                <div class="card-icon">📋</div>
                <div class="card-label">防火墙规则</div>
                <div class="card-value blue" id="rule_count">--</div>
            </div>
            <div class="netmanager-card">
                <div class="card-icon">⚠️</div>
                <div class="card-label">SSH失败(24h)</div>
                <div class="card-value orange" id="ssh_fail_24h">--</div>
            </div>
            <div class="netmanager-card">
                <div class="card-icon">🔗</div>
                <div class="card-label">当前连接</div>
                <div class="card-value blue" id="conn_count">--</div>
            </div>
            <div class="netmanager-card">
                <div class="card-icon">💾</div>
                <div class="card-label">内存使用</div>
                <div class="card-value" id="mem_percent">--</div>
            </div>
        </div>
        <h3>网络信息</h3>
        <table class="netmanager-table">
            <tr><td width="30%">WAN IP</td><td id="wan_ip">--</td></tr>
            <tr><td>LAN IP</td><td id="lan_ip">--</td></tr>
            <tr><td>默认转发目标</td><td id="default_target">--</td></tr>
            <tr><td>运行时间</td><td id="uptime">--</td></tr>
            <tr><td>系统负载</td><td id="load">--</td></tr>
        </table>
        <h3>IPv6 状态</h3>
        <table class="netmanager-table">
            <tr><td width="30%">IPv6 出口</td><td id="ipv6_status">--</td></tr>
            <tr><td>WAN IPv6</td><td id="wan_ipv6">--</td></tr>
            <tr><td>PD 前缀</td><td id="pd_prefix">--</td></tr>
            <tr><td>LAN 分发地址</td><td id="lan_ipv6">--</td></tr>
            <tr><td>IPv6 默认路由</td><td id="ipv6_gw">--</td></tr>
        </table>
        <h3>DNS</h3>
        <table class="netmanager-table">
            <tr><td width="30%">DNS 模式</td><td id="dns_mode">--</td></tr>
            <tr><td>上游服务器</td><td id="dns_servers">--</td></tr>
        </table>
        <h3>快捷操作</h3>
        <div class="netmanager-toolbar">
            <button class="btn btn-primary" onclick="fwAction('reload')">重载防火墙</button>
            <button class="btn btn-warning" onclick="fwAction('restart')">重启防火墙</button>
            <button class="btn btn-success" onclick="fwAction('backup')">备份配置</button>
            <button class="btn btn-secondary" onclick="loadOverview()">刷新数据</button>
        </div>
        <div id="action_result" class="netmanager-result"></div>
    </div>
    <div class="footer-sign">网络管理插件 v1.8.17</div>
</div>
<script>
const API_URL = '<%=luci.dispatcher.build_url("admin/netmanager/api")%>';
function loadOverview() {
    nmFetch({
        method: 'POST',
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: 'action=overview'
    }).then(r => r.text()).then(data => {
        const lines = data.split('\n');
        lines.forEach(line => {
            if (line.includes('=') && !line.includes('===')) {
                const idx = line.indexOf('=');
                const key = line.substring(0, idx);
                const value = line.substring(idx + 1);
                const el = document.getElementById(key.toLowerCase());
                if (el) {
                    if (key === 'FW_STATUS') {
                        el.innerHTML = value === 'running' ? '<span class="badge badge-green">运行中</span>' : '<span class="badge badge-red">已停止</span>';
                    } else if (key === 'MEM_PERCENT') {
                        el.textContent = value + '%';
                    } else {
                        el.textContent = value;
                    }
                }
            }
        });
    });
}
function fwAction(action) {
    const resultDiv = document.getElementById('action_result');
    resultDiv.innerHTML = '<span class="text-info">执行中...</span>';
    nmFetch({
        method: 'POST',
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: 'action=' + action
    }).then(r => r.text()).then(data => {
        resultDiv.innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(loadOverview, 2000);
    });
}
loadOverview();
setInterval(loadOverview, 30000);
</script>
<%+footer%>


```

### 5.11 files/usr/lib/lua/luci/view/netmanager/port_forward.htm

- **用途**：端口转发管理页：IPv4/IPv6 DNAT 列表 + 「IPv6 端口放行（直连）」区 + 添加/编辑/删除/跟踪
- **规模**：284 行
- **维护要点**：放行区来源标注（自动配套/自定义）；删除/编辑一律数组下标传参，不传自由文本

```html
<%+header%>
<%+netmanager/common_head%>
<div class="netmanager-container">
    <div class="netmanager-header">
        <h1>网络管理</h1>
        <span class="netmanager-author">吾爱破解liyu0828</span>
    </div>
    <%+netmanager/nav%>
    <div class="netmanager-content">
        <h2>端口转发管理</h2>
        <!-- 添加表单 -->
        <div class="netmanager-form" id="add_form">
            <div style="margin-bottom:8px;"><b>添加端口转发</b></div>
            <div>
                <label>外部端口:</label>
                <input type="text" id="add_port" placeholder="如 443 或 1000-2000" style="width:120px;">
                <label>内部端口:</label>
                <input type="text" id="add_dport" placeholder="留空同外部" style="width:110px;">
                <label>协议:</label>
                <select id="add_proto">
                    <option value="tcp">TCP</option>
                    <option value="udp">UDP</option>
                    <option value="both">TCP+UDP</option>
                </select>
                <label>目标IP:</label>
                <input type="text" id="add_target" placeholder="留空用默认" style="width:130px;">
                <label>IP版本:</label>
                <select id="add_ipver">
                    <option value="both">IPv4+IPv6</option>
                    <option value="v4">仅IPv4</option>
                    <option value="v6">仅IPv6</option>
                </select>
                <button class="btn btn-success btn-sm" onclick="addPortForward()">添加</button>
            </div>
            <div class="text-muted" style="margin-top:6px;">默认目标IP: <span id="default_target_display">加载中...</span> | 可在「设置」中修改</div>
        </div>
        <!-- 编辑表单（默认隐藏） -->
        <div class="netmanager-form" id="edit_form" style="display:none;border-left:3px solid #f0ad4e;">
            <div style="margin-bottom:8px;"><b>编辑端口转发</b> <span class="text-muted" id="edit_old_info"></span></div>
            <div>
                <label>新外部端口:</label>
                <input type="text" id="edit_port" placeholder="如 443" style="width:110px;">
                <label>内部端口:</label>
                <input type="text" id="edit_dport" placeholder="留空同外部" style="width:110px;">
                <label>协议:</label>
                <select id="edit_proto">
                    <option value="tcp">TCP</option>
                    <option value="udp">UDP</option>
                    <option value="both">TCP+UDP</option>
                </select>
                <label>目标IP:</label>
                <input type="text" id="edit_target" placeholder="留空用默认" style="width:130px;">
                <label>IP版本:</label>
                <select id="edit_ipver">
                    <option value="both">IPv4+IPv6</option>
                    <option value="v4">仅IPv4</option>
                    <option value="v6">仅IPv6</option>
                </select>
                <button class="btn btn-primary btn-sm" onclick="savePortEdit()">保存修改</button>
                <button class="btn btn-secondary btn-sm" onclick="cancelPortEdit()">取消</button>
            </div>
            <input type="hidden" id="edit_old_port">
            <input type="hidden" id="edit_old_proto">
            <input type="hidden" id="edit_old_ipver">
        </div>
        <h3>IPv4 端口转发 (DNAT)</h3>
        <table class="netmanager-table" id="ipv4_table">
            <thead><tr><th>名称</th><th>协议</th><th>外部端口</th><th>目标地址</th><th>命中数</th><th>状态</th><th>操作</th></tr></thead>
            <tbody><tr><td colspan="7" class="empty-state">—</td></tr></tbody>
        </table>
        <h3>IPv6 端口映射 (DNAT)</h3>
        <div class="text-muted" style="margin-bottom:6px;">
            与 IPv4 对称：外部端口映射到内网主机的 IPv6 地址（ipv6:port）。目标填 IPv4 时自动解析该主机当前公网 IPv6，
            并登记「跟踪锚点」，运营商前缀变化时自动跟随。添加无翻译端口（外部=内部）的 IPv6 映射时，会在下方
            「IPv6 端口放行」区同步生成配套 Allow-IPv6 直连放行规则（随映射自动增删与前缀跟随），无需手动维护。
            <button class="btn btn-secondary btn-sm" onclick="syncV6()">立即同步</button>
        </div>
        <table class="netmanager-table" id="ipv6dnat_table">
            <thead><tr><th>名称</th><th>协议</th><th>外部端口</th><th>目标地址</th><th>跟踪锚点</th><th>命中数</th><th>状态</th><th>操作</th></tr></thead>
            <tbody><tr><td colspan="8" class="empty-state">—</td></tr></tbody>
        </table>
        <h3>IPv6 端口放行（直连）</h3>
        <div class="text-muted" style="margin-bottom:6px;">
            转发是转发，放行是放行：上表 DNAT 管「连路由器 WAN 地址」的翻译路径；本表放行规则管「域名直连内网主机 GUA」
            的路径（无翻译端口时 DNAT 为空操作、不打 ct 标记，必须靠放行规则）。目的IP 锁定单台主机，非整段放行。
            「自动配套」规则随 IPv6 映射自动增删；禁用只断直连路径，不影响转发。
        </div>
        <table class="netmanager-table" id="ipv6allow_table">
            <thead><tr><th>名称</th><th>协议</th><th>放行端口</th><th>目的IP</th><th>来源</th><th>状态</th><th>操作</th></tr></thead>
            <tbody><tr><td colspan="7" class="empty-state">—</td></tr></tbody>
        </table>
        <div id="action_result" class="netmanager-result"></div>
    </div>
    <div class="footer-sign">网络管理插件 v1.8.17</div>
</div>
<script>
const API_URL = '<%=luci.dispatcher.build_url("admin/netmanager/api")%>';
function loadPortList() {
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=port_list'})
    .then(r => r.text()).then(data => {
        const sections = data.split('---');
        let ipv4Html = '', ipv6dHtml = '', ipv6aHtml = '';
        let currentSection = '';
        // 【安全】行数据存入 JS 数组，onclick 只传纯数字下标，杜绝自由文本注入 onclick
        window.PORT_ROWS = [];
        window.ALLOW_ROWS = [];
        sections.forEach(section => {
            if (section.includes('IPV6DNAT')) currentSection = 'ipv6dnat';
            else if (section.includes('IPV4')) currentSection = 'ipv4';
            else if (section.includes('IPV6')) currentSection = 'ipv6allow'; // v1.8.13：放行规则回归本页「IPv6 端口放行」区
            else if (section.includes('DEFAULT_TARGET')) {
                const m = section.match(/DEFAULT_TARGET=(.+)/);
                if (m) document.getElementById('default_target_display').textContent = m[1].trim();
            }
            const lines = section.split('\n').filter(l => l.includes('|'));
            lines.forEach(line => {
                const parts = line.split('|');
                if (currentSection === 'ipv4' && parts.length >= 8) {
                    const [idx, name, proto, sp, dip, dp, enabled, pkts] = parts;
                    const status = enabled === '1' ? '<span class="badge badge-green">启用</span>' : '<span class="badge badge-gray">禁用</span>';
                    const protoBadge = proto === 'tcp' ? '<span class="badge badge-blue">TCP</span>' : proto === 'udp' ? '<span class="badge badge-purple">UDP</span>' : '<span class="badge badge-blue">TCP+UDP</span>';
                    // 【安全 v1.4.7 P1-2】delPort 改数组下标传参（escapeHtml 在 onclick 属性上下文
                    // 可被 &#39; 实体还原绕过，自由文本入 onclick 仍可注入）
                    const rowId = window.PORT_ROWS.push({sp: sp, proto: proto, dip: dip, dp: dp, v6: false}) - 1;
                    ipv4Html += `<tr><td>${escapeHtml(name)}</td><td>${protoBadge}</td><td><b>${escapeHtml(sp)}</b></td><td>${escapeHtml(dip)}:${escapeHtml(dp)}</td><td>${escapeHtml(pkts)}</td><td>${status}</td><td><button class="btn btn-primary btn-sm" onclick="editPort(${rowId})">编辑</button> <button class="btn btn-danger btn-sm" onclick="delPort(${rowId})">删除</button></td></tr>`;
                } else if (currentSection === 'ipv6dnat' && parts.length >= 9) {
                    const [idx, name, proto, sp, enabled, pkts, dip, anchor, dp] = parts;
                    const status = enabled === '1' ? '<span class="badge badge-green">启用</span>' : '<span class="badge badge-gray">禁用</span>';
                    const protoBadge = proto === 'tcp' ? '<span class="badge badge-blue">TCP</span>' : proto === 'udp' ? '<span class="badge badge-purple">UDP</span>' : '<span class="badge badge-blue">TCP+UDP</span>';
                    const rowId = window.PORT_ROWS.push({sp: sp, proto: proto, dip: dip || '', dp: dp, v6: true, anchor: anchor || ''}) - 1;
                    const dipCell = dip ? '[' + escapeHtml(dip) + ']:' + escapeHtml(dp) : '<span class="badge badge-red">未设置目标</span>';
                    const anchorCell = anchor
                        ? '<span class="badge badge-green">跟随 ' + escapeHtml(anchor) + '</span>'
                        : '<span class="text-muted">未跟踪</span>';
                    ipv6dHtml += `<tr><td>${escapeHtml(name)}</td><td>${protoBadge}</td><td><b>${escapeHtml(sp)}</b></td><td>${dipCell}</td><td>${anchorCell}</td><td>${escapeHtml(pkts)}</td><td>${status}</td><td><button class="btn btn-success btn-sm" onclick="trackV6(${rowId})">跟踪</button> <button class="btn btn-primary btn-sm" onclick="editPort(${rowId})">编辑</button> <button class="btn btn-danger btn-sm" onclick="delPort(${rowId})">删除</button></td></tr>`;
                } else if (currentSection === 'ipv6allow' && parts.length >= 8) {
                    // v1.8.13：IPv6 端口放行区（idx|name|proto|dp|en|pkts|dip|anchor）
                    const [idx, name, proto, dp, en, pkts, dip, anchor] = parts;
                    const auto = (name === 'Allow-IPv6-' + dp + '-' + proto);
                    const status = en === '1' ? '<span class="badge badge-green">启用</span>' : '<span class="badge badge-gray">禁用</span>';
                    const protoBadge = proto === 'tcp' ? '<span class="badge badge-blue">TCP</span>' : proto === 'udp' ? '<span class="badge badge-purple">UDP</span>' : '<span class="badge badge-blue">TCP+UDP</span>';
                    const srcBadge = auto ? '<span class="badge badge-blue">自动配套</span>' : '<span class="badge badge-gray">自定义</span>';
                    const aRowId = window.ALLOW_ROWS.push({idx: idx, en: en, auto: auto, name: name}) - 1;
                    const toggleLabel = en === '1' ? '禁用' : '启用';
                    let ops = `<button class="btn btn-secondary btn-sm" onclick="toggleAllow(${aRowId})">${toggleLabel}</button>`;
                    if (!auto) ops += ` <button class="btn btn-danger btn-sm" onclick="delAllow(${aRowId})">删除</button>`;
                    ipv6aHtml += `<tr><td><b>${escapeHtml(name)}</b></td><td>${protoBadge}</td><td><b>${escapeHtml(dp)}</b></td><td>${dip ? escapeHtml(dip) : '<span class="text-muted">任意</span>'}</td><td>${srcBadge}</td><td>${status}</td><td>${ops}</td></tr>`;
                }
            });
        });
        document.querySelector('#ipv4_table tbody').innerHTML = ipv4Html || '<tr><td colspan="7" class="empty-state">暂无规则</td></tr>';
        document.querySelector('#ipv6dnat_table tbody').innerHTML = ipv6dHtml || '<tr><td colspan="8" class="empty-state">暂无规则</td></tr>';
        document.querySelector('#ipv6allow_table tbody').innerHTML = ipv6aHtml || '<tr><td colspan="7" class="empty-state">暂无放行规则</td></tr>';
    });
}
// v1.8.13：IPv6 端口放行区 启用/禁用 与 删除（仅自定义规则可删）
function toggleAllow(rowId) {
    const r = window.ALLOW_ROWS && window.ALLOW_ROWS[rowId];
    if (!r) return;
    const en = r.en === '1' ? '0' : '1';
    if (en === '0' && r.auto && !confirm('禁用自动配套放行规则 ' + r.name + ' 后，域名直连该主机 IPv6 的路径将不通（转发路径不受影响）。确定禁用？')) return;
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=rule_toggle&idx=' + encodeURIComponent(r.idx) + '&en=' + en})
    .then(r2 => r2.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(loadPortList, 500);
    }).catch(e => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">[ERROR] ' + escapeHtml(e.message || String(e)) + '</pre>';
    });
}
function delAllow(rowId) {
    const r = window.ALLOW_ROWS && window.ALLOW_ROWS[rowId];
    if (!r || r.auto) return;
    if (!confirm('确定删除放行规则 ' + r.name + ' ?')) return;
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=rule_del&idx=' + encodeURIComponent(r.idx)})
    .then(r2 => r2.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(loadPortList, 500);
    }).catch(e => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">[ERROR] ' + escapeHtml(e.message || String(e)) + '</pre>';
    });
}
// v1.8.3：登记/取消 IPv6 目标跟踪锚点
function trackV6(rowId) {
    const r = window.PORT_ROWS && window.PORT_ROWS[rowId];
    if (!r) return;
    const cur = r.anchor || '';
    const input = prompt('请输入跟踪锚点（目标主机的内网 IPv4 / MAC / 主机名）\n'
        + '例如 192.168.31.3；输入 off 取消跟踪。\n\n'
        + '登记后，运营商前缀变化时会自动重算该主机的 IPv6 并更新映射目标。', cur);
    if (input === null) return;
    const anchor = input.trim();
    if (!anchor) { alert('锚点不能为空（取消跟踪请输入 off）'); return; }
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},
        body:'action=port_track_v6&port=' + encodeURIComponent(r.sp) + '&proto=' + encodeURIComponent(r.proto) + '&anchor=' + encodeURIComponent(anchor)})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(loadPortList, 500);
    });
}
function syncV6() {
    document.getElementById('action_result').innerHTML = '<span class="text-info">同步中...</span>';
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=port_sync_v6'})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(loadPortList, 500);
    });
}
function addPortForward() {
    const port = document.getElementById('add_port').value.trim();
    const dport = document.getElementById('add_dport').value.trim();
    const proto = document.getElementById('add_proto').value;
    const target = document.getElementById('add_target').value.trim();
    const ipver = document.getElementById('add_ipver').value;
    if (!port) { alert('请输入端口号'); return; }
    const body = 'action=port_add&port=' + encodeURIComponent(port) + '&dport=' + encodeURIComponent(dport) + '&proto=' + proto + '&target=' + encodeURIComponent(target) + '&ipver=' + ipver;
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:body})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        document.getElementById('add_port').value = '';
        document.getElementById('add_dport').value = '';
        document.getElementById('add_target').value = '';
        setTimeout(loadPortList, 400);
    }).catch(e => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">[ERROR] ' + escapeHtml(e.message || String(e)) + '</pre>';
    });
}
function delPort(rowId) {
    // 【安全 v1.4.7 P1-2】由 onclick 传入数组下标，再从 window.PORT_ROWS 取端口/协议
    const r = (window.PORT_ROWS && window.PORT_ROWS[rowId]) || {};
    const port = r.sp, proto = r.proto;
    if (!port || !proto) return;
    const ipver = r.v6 ? 'v6' : 'v4';
    if (!confirm('确定删除 ' + (r.v6 ? 'IPv6' : 'IPv4') + ' 端口映射 ' + port + '/' + proto + ' ?')) return;
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=port_del&port=' + encodeURIComponent(port) + '&proto=' + encodeURIComponent(proto) + '&ipver=' + ipver})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(loadPortList, 300);
    }).catch(e => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">[ERROR] ' + escapeHtml(e.message || String(e)) + '</pre>';
    });
}
function editPort(rowId) {
    const r = window.PORT_ROWS && window.PORT_ROWS[rowId];
    if (!r) return;
    const port = r.sp, proto = r.proto, target = r.dip, dport = r.dp;
    document.getElementById('add_form').style.display = 'none';
    document.getElementById('edit_form').style.display = 'block';
    document.getElementById('edit_old_port').value = port;
    document.getElementById('edit_old_proto').value = proto;
    document.getElementById('edit_old_ipver').value = r.v6 ? 'v6' : 'v4';
    document.getElementById('edit_port').value = port;
    document.getElementById('edit_proto').value = proto;
    document.getElementById('edit_ipver').value = r.v6 ? 'v6' : 'v4';
    document.getElementById('edit_target').value = target || '';
    document.getElementById('edit_dport').value = dport || '';
    document.getElementById('edit_old_info').textContent = '(原: ' + (r.v6 ? 'IPv6 ' : 'IPv4 ') + port + '/' + proto + ')';
    document.getElementById('edit_form').scrollIntoView({behavior:'smooth', block:'center'});
}
function cancelPortEdit() {
    document.getElementById('edit_form').style.display = 'none';
    document.getElementById('add_form').style.display = 'block';
}
function savePortEdit() {
    const old_port = document.getElementById('edit_old_port').value;
    const old_proto = document.getElementById('edit_old_proto').value;
    const new_port = document.getElementById('edit_port').value.trim();
    const new_dport = document.getElementById('edit_dport').value.trim();
    const new_proto = document.getElementById('edit_proto').value;
    const new_target = document.getElementById('edit_target').value.trim();
    const new_ipver = document.getElementById('edit_ipver').value;
    if (!new_port) { alert('请输入新端口号'); return; }
    const body = 'action=port_edit&old_port=' + encodeURIComponent(old_port) + '&old_proto=' + old_proto + '&old_ipver=' + document.getElementById('edit_old_ipver').value + '&new_port=' + encodeURIComponent(new_port) + '&new_dport=' + encodeURIComponent(new_dport) + '&new_proto=' + new_proto + '&new_target=' + encodeURIComponent(new_target) + '&new_ipver=' + new_ipver;
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:body})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        cancelPortEdit();
        setTimeout(loadPortList, 300);
    }).catch(e => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">[ERROR] ' + escapeHtml(e.message || String(e)) + '</pre>';
    });
}
loadPortList();
</script>
<%+footer%>


```

### 5.12 files/usr/lib/lua/luci/view/netmanager/firewall_rules.htm

- **用途**：防火墙规则管理页：自定义规则增删改 + 常用模板一键应用 + 源IP/目的IP 列
- **规模**：251 行
- **维护要点**：IPv6 放行规则不在此页渲染（v1.8.13 移至端口转发页），保留迁移提示

```html
<%+header%>
<%+netmanager/common_head%>
<div class="netmanager-container">
    <div class="netmanager-header">
        <h1>网络管理</h1>
        <span class="netmanager-author">吾爱破解liyu0828</span>
    </div>
    <%+netmanager/nav%>
    <div class="netmanager-content">
        <h2>防火墙规则管理</h2>
        <div class="text-muted" style="margin-bottom:8px;">管理 ACCEPT / DROP / REJECT 通用通信规则。IPv6 端口放行规则（wan→lan 带端口）在「端口转发」页「IPv6 端口放行」区管理，转发与放行分离。</div>
        <div class="text-muted" id="allow_moved_hint" style="margin-bottom:6px;display:none;"></div>
        <!-- 添加表单 -->
        <div class="netmanager-form" id="add_form">
            <div style="margin-bottom:8px;"><b>添加自定义规则</b></div>
            <div>
                <label>规则名称:</label>
                <input type="text" id="rule_name" placeholder="如 Block-SSH-WAN" style="width:150px;">
                <label>源区域:</label>
                <select id="rule_src">
                    <option value="wan">wan</option>
                    <option value="lan">lan</option>
                    <option value="">任意</option>
                </select>
                <label>目标区域:</label>
                <select id="rule_dst">
                    <option value="">本机/任意</option>
                    <option value="lan">lan</option>
                    <option value="wan">wan</option>
                </select>
            </div>
            <div style="margin-top:6px;">
                <label>协议:</label>
                <select id="rule_proto">
                    <option value="tcp">TCP</option>
                    <option value="udp">UDP</option>
                    <option value="tcpudp">TCP+UDP</option>
                    <option value="icmp">ICMP</option>
                    <option value="all">全部</option>
                </select>
                <label>目标端口:</label>
                <input type="text" id="rule_port" placeholder="如 22 或 80-90" style="width:120px;">
                <label>动作:</label>
                <select id="rule_target">
                    <option value="ACCEPT">允许</option>
                    <option value="DROP">丢弃</option>
                    <option value="REJECT">拒绝</option>
                </select>
                <label>IP版本:</label>
                <select id="rule_family">
                    <option value="any">IPv4+IPv6</option>
                    <option value="ipv4">仅IPv4</option>
                    <option value="ipv6">仅IPv6</option>
                </select>
                <button class="btn btn-success btn-sm" onclick="addRule()">添加规则</button>
            </div>
        </div>
        <!-- 编辑表单（默认隐藏） -->
        <div class="netmanager-form" id="edit_form" style="display:none;border-left:3px solid #f0ad4e;">
            <div style="margin-bottom:8px;"><b>编辑规则 #<span id="edit_idx_display"></span></b></div>
            <div>
                <label>规则名称:</label>
                <input type="text" id="edit_name" style="width:150px;">
                <label>源区域:</label>
                <select id="edit_src">
                    <option value="wan">wan</option>
                    <option value="lan">lan</option>
                    <option value="">任意</option>
                </select>
                <label>目标区域:</label>
                <select id="edit_dst">
                    <option value="">本机/任意</option>
                    <option value="lan">lan</option>
                    <option value="wan">wan</option>
                </select>
            </div>
            <div style="margin-top:6px;">
                <label>协议:</label>
                <select id="edit_proto">
                    <option value="tcp">TCP</option>
                    <option value="udp">UDP</option>
                    <option value="tcpudp">TCP+UDP</option>
                    <option value="icmp">ICMP</option>
                    <option value="all">全部</option>
                </select>
                <label>目标端口:</label>
                <input type="text" id="edit_port" placeholder="如 22 或 80-90" style="width:120px;">
                <label>动作:</label>
                <select id="edit_target">
                    <option value="ACCEPT">允许</option>
                    <option value="DROP">丢弃</option>
                    <option value="REJECT">拒绝</option>
                </select>
                <label>IP版本:</label>
                <select id="edit_family">
                    <option value="any">IPv4+IPv6</option>
                    <option value="ipv4">仅IPv4</option>
                    <option value="ipv6">仅IPv6</option>
                </select>
                <button class="btn btn-primary btn-sm" onclick="saveRuleEdit()">保存修改</button>
                <button class="btn btn-secondary btn-sm" onclick="cancelRuleEdit()">取消</button>
            </div>
            <input type="hidden" id="edit_idx">
        </div>
        <h3>当前所有规则</h3>
        <table class="netmanager-table" id="rule_table">
            <thead><tr><th>#</th><th>名称</th><th>源</th><th>目标</th><th>协议</th><th>端口</th><th>源IP</th><th>目的IP</th><th>动作</th><th>IP版本</th><th>状态</th><th>操作</th></tr></thead>
            <tbody><tr><td colspan="12" class="empty-state">加载中...</td></tr></tbody>
        </table>
        <h3>常用规则模板</h3>
        <div class="netmanager-toolbar">
            <button class="btn btn-secondary btn-sm" onclick="applyTemplate('block_ssh_wan')">禁止WAN口SSH</button>
            <button class="btn btn-secondary btn-sm" onclick="applyTemplate('block_ping')">禁止Ping</button>
            <button class="btn btn-secondary btn-sm" onclick="applyTemplate('allow_web')">允许Web(80/443)</button>
            <button class="btn btn-secondary btn-sm" onclick="applyTemplate('block_rpcbind')">禁止rpcbind(111)</button>
        </div>
        <div id="action_result" class="netmanager-result"></div>
    </div>
    <div class="footer-sign">网络管理插件 v1.8.17</div>
</div>
<script>
const API_URL = '<%=luci.dispatcher.build_url("admin/netmanager/api")%>';
function loadRuleList() {
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=rule_list'})
    .then(r => r.text()).then(data => {
        let html = '';
        let allowMoved = 0;
        // 【安全】行数据存入 JS 数组，onclick 只传纯数字下标，杜绝 UCI 自由文本注入 onclick
        window.RULE_ROWS = [];
        const lines = data.split('\n').filter(l => l.includes('|') && !l.includes('---'));
        lines.forEach(line => {
            const parts = line.split('|');
            if (parts.length >= 9) {
                const [idx, name, src, dst, proto, port, target, fam, enabled] = parts;
                // v1.8.13：IPv6 端口放行规则（与 port_list IPV6 区同口径）移至端口转发页，本页不渲染
                if (fam === 'ipv6' && port && dst === 'lan') { allowMoved++; return; }
                // v1.8.13：末尾追加的源IP/目的IP（旧后端无这两字段时显示「任意」）
                const sip = parts[9] || '', dip = parts[10] || '';
                const tBadge = target === 'ACCEPT' ? '<span class="badge badge-green">ACCEPT</span>' : target === 'DROP' ? '<span class="badge badge-red">DROP</span>' : '<span class="badge badge-orange">REJECT</span>';
                const fBadge = fam === 'any' ? '全部' : escapeHtml(fam.toUpperCase());
                const status = enabled === '1' ? '<span class="badge badge-green">启用</span>' : '<span class="badge badge-gray">禁用</span>';
                const sipCell = sip ? escapeHtml(sip) : '<span class="text-muted">任意</span>';
                const dipCell = dip ? escapeHtml(dip) : '<span class="text-muted">任意</span>';
                const rowId = window.RULE_ROWS.length;
                window.RULE_ROWS.push({idx: idx, name: name, src: src, dst: dst, proto: proto, port: port, target: target, fam: fam, sip: sip, dip: dip});
                html += `<tr><td>${escapeHtml(idx)}</td><td><b>${escapeHtml(name)}</b></td><td>${escapeHtml(src || '-')}</td><td>${escapeHtml(dst || '-')}</td><td>${escapeHtml(proto || '-')}</td><td>${escapeHtml(port || '-')}</td><td>${sipCell}</td><td>${dipCell}</td><td>${tBadge}</td><td>${fBadge}</td><td>${status}</td><td><button class="btn btn-primary btn-sm" onclick="editRule(${parseInt(idx)},${rowId})">编辑</button> <button class="btn btn-danger btn-sm" onclick="delRule(${parseInt(idx)})">删除</button></td></tr>`;
            }
        });
        document.querySelector('#rule_table tbody').innerHTML = html || '<tr><td colspan="12" class="empty-state">暂无规则</td></tr>';
        const hint = document.getElementById('allow_moved_hint');
        if (allowMoved > 0) {
            hint.textContent = '另有 ' + allowMoved + ' 条 IPv6 端口放行规则已在「端口转发」页「IPv6 端口放行」区管理（含自动配套直连放行），本页不再列出。';
            hint.style.display = 'block';
        } else {
            hint.style.display = 'none';
        }
    });
}
function addRule() {
    const name = document.getElementById('rule_name').value.trim();
    if (!name) { alert('请输入规则名称'); return; }
    const body = new URLSearchParams({
        action:'rule_add', name:name,
        src:document.getElementById('rule_src').value,
        dst:document.getElementById('rule_dst').value,
        proto:document.getElementById('rule_proto').value,
        port:document.getElementById('rule_port').value,
        target:document.getElementById('rule_target').value,
        family:document.getElementById('rule_family').value
    });
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:body})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        document.getElementById('rule_name').value = '';
        document.getElementById('rule_port').value = '';
        setTimeout(loadRuleList, 1500);
    }).catch(e => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">[ERROR] ' + escapeHtml(e.message || String(e)) + '</pre>';
    });
}
function delRule(idx) {
    if (!confirm('确定删除规则 #' + idx + ' ?')) return;
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=rule_del&idx=' + idx})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(loadRuleList, 1500);
    }).catch(e => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">[ERROR] ' + escapeHtml(e.message || String(e)) + '</pre>';
    });
}
function editRule(idx, rowId) {
    const r = window.RULE_ROWS && window.RULE_ROWS[rowId];
    if (!r) return;
    document.getElementById('add_form').style.display = 'none';
    document.getElementById('edit_form').style.display = 'block';
    document.getElementById('edit_idx').value = idx;
    document.getElementById('edit_idx_display').textContent = idx;
    document.getElementById('edit_name').value = r.name;
    document.getElementById('edit_src').value = r.src || '';
    document.getElementById('edit_dst').value = r.dst || '';
    document.getElementById('edit_proto').value = r.proto || 'tcp';
    document.getElementById('edit_port').value = r.port || '';
    document.getElementById('edit_target').value = r.target || 'ACCEPT';
    document.getElementById('edit_family').value = r.fam || 'any';
    document.getElementById('edit_form').scrollIntoView({behavior:'smooth', block:'center'});
}
function cancelRuleEdit() {
    document.getElementById('edit_form').style.display = 'none';
    document.getElementById('add_form').style.display = 'block';
}
function saveRuleEdit() {
    const idx = document.getElementById('edit_idx').value;
    const body = new URLSearchParams({
        action:'rule_edit', idx:idx,
        name:document.getElementById('edit_name').value.trim(),
        src:document.getElementById('edit_src').value,
        dst:document.getElementById('edit_dst').value,
        proto:document.getElementById('edit_proto').value,
        port:document.getElementById('edit_port').value,
        target:document.getElementById('edit_target').value,
        family:document.getElementById('edit_family').value
    });
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:body})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        cancelRuleEdit();
        setTimeout(loadRuleList, 1500);
    }).catch(e => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">[ERROR] ' + escapeHtml(e.message || String(e)) + '</pre>';
    });
}
function applyTemplate(type) {
    const t = {
        block_ssh_wan:['Block-SSH-WAN','wan','','tcp','22','DROP','any'],
        block_ping:['Block-Ping-WAN','wan','','icmp','','DROP','ipv4'],
        allow_web:['Allow-Web-WAN','wan','lan','tcp','80 443','ACCEPT','any'],
        block_rpcbind:['Block-rpcbind-WAN','wan','','tcpudp','111','DROP','any']
    };
    const v = t[type];
    document.getElementById('rule_name').value = v[0];
    document.getElementById('rule_src').value = v[1];
    document.getElementById('rule_dst').value = v[2];
    document.getElementById('rule_proto').value = v[3];
    document.getElementById('rule_port').value = v[4];
    document.getElementById('rule_target').value = v[5];
    document.getElementById('rule_family').value = v[6];
    alert('模板已填充，点击「添加规则」确认');
}
loadRuleList();
</script>
<%+footer%>


```

### 5.13 files/usr/lib/lua/luci/view/netmanager/ssh_log.htm

- **用途**：SSH 登录日志页：成功/失败记录 + 失败 IP Top10 + 自动刷新
- **规模**：103 行
- **维护要点**：所有字段写 DOM 前转义（v1.4.4 修存储型 XSS）

```html
<%+header%>
<%+netmanager/common_head%>
<div class="netmanager-container">
    <div class="netmanager-header">
        <h1>网络管理</h1>
        <span class="netmanager-author">吾爱破解liyu0828</span>
    </div>
    <%+netmanager/nav%>
    <div class="netmanager-content">
        <h2>SSH 登录日志</h2>
        <div class="netmanager-toolbar">
            <label style="font-size:13px;color:#6b7280;">显示行数:</label>
            <select id="log_limit">
                <option value="20">最近20条</option>
                <option value="50" selected>最近50条</option>
                <option value="100">最近100条</option>
                <option value="200">最近200条</option>
            </select>
            <button class="btn btn-primary btn-sm" onclick="loadSshLog()">刷新</button>
            <button class="btn btn-secondary btn-sm" onclick="toggleAuto()">自动刷新</button>
            <span id="auto_status" class="text-muted"></span>
        </div>
        <div class="netmanager-cards" style="grid-template-columns: repeat(3, 1fr);">
            <div class="netmanager-card">
                <div class="card-label">成功登录</div>
                <div class="card-value green" id="success_count">0</div>
            </div>
            <div class="netmanager-card">
                <div class="card-label">失败登录</div>
                <div class="card-value red" id="failed_count">0</div>
            </div>
            <div class="netmanager-card">
                <div class="card-label">可疑IP数</div>
                <div class="card-value orange" id="suspicious_count">0</div>
            </div>
        </div>
        <h3>失败登录IP排行 (Top 10)</h3>
        <table class="netmanager-table" id="stats_table">
            <thead><tr><th>IP地址</th><th>失败次数</th><th>风险等级</th></tr></thead>
            <tbody><tr><td colspan="3" class="empty-state">加载中...</td></tr></tbody>
        </table>
        <h3>成功登录记录</h3>
        <div class="netmanager-log" id="success_log"><div class="text-muted">加载中...</div></div>
        <h3>失败登录记录</h3>
        <div class="netmanager-log" id="failed_log"><div class="text-muted">加载中...</div></div>
    </div>
    <div class="footer-sign">网络管理插件 v1.8.17</div>
</div>
<script>
const API_URL = '<%=luci.dispatcher.build_url("admin/netmanager/api")%>';
let autoTimer = null;
function loadSshLog() {
    const limit = document.getElementById('log_limit').value;
    apiFetch('ssh_log', {limit: limit}, {timeout: 15000}).then(data => {
        // 后端输出带分节标记行（---SUCCESS--- 等），按行首标记解析，不再用 includes 模糊匹配
        let current = '';
        let successHtml = '', failedHtml = '', statsHtml = '';
        let successCount = 0, failedCount = 0;
        data.split('\n').forEach(line => {
            if (/^---[A-Z]+---$/.test(line.trim())) {
                // 分节标记行：SUCCESS / FAILED / STATS
                if (line.includes('SUCCESS')) current = 'success';
                else if (line.includes('FAILED')) current = 'failed';
                else if (line.includes('STATS')) current = 'stats';
                else current = '';
                return;
            }
            if (!current || !line.includes('|')) return;
            const parts = line.split('|');
            // 【安全】SSH用户名/IP/原因均为外部可控内容，写入前必须转义
            const t = escapeHtml(parts[0]), u = escapeHtml(parts[1]), ip = escapeHtml(parts[2]);
            if (current === 'success' && parts.length >= 3) {
                successCount++;
                successHtml += `<div><span class="log-time">[${t}]</span> <span class="log-success">成功</span> 用户:<b>${u}</b> 来自:<span class="log-ip">${ip}</span></div>`;
            } else if (current === 'failed' && parts.length >= 4) {
                failedCount++;
                failedHtml += `<div><span class="log-time">[${t}]</span> <span class="log-fail">失败</span> 用户:<b>${u}</b> 来自:<span class="log-ip">${ip}</span> 原因:${escapeHtml(parts[3])}</div>`;
            } else if (current === 'stats' && parts.length >= 2) {
                const count = parseInt(parts[1]);
                if (isNaN(count)) return;
                let risk = '<span class="badge badge-green">低</span>';
                if (count >= 10) risk = '<span class="badge badge-red">高危</span>';
                else if (count >= 5) risk = '<span class="badge badge-orange">中危</span>';
                statsHtml += `<tr><td><span class="log-ip">${ip}</span></td><td><b>${count}</b></td><td>${risk}</td></tr>`;
            }
        });
        document.getElementById('success_count').textContent = successCount;
        document.getElementById('failed_count').textContent = failedCount;
        document.getElementById('suspicious_count').textContent = statsHtml ? (statsHtml.match(/<tr>/g) || []).length : 0;
        document.querySelector('#stats_table tbody').innerHTML = statsHtml || '<tr><td colspan="3" class="empty-state">暂无失败记录</td></tr>';
        document.getElementById('success_log').innerHTML = successHtml || '<div class="text-muted">暂无成功登录记录</div>';
        document.getElementById('failed_log').innerHTML = failedHtml || '<div class="text-muted">暂无失败登录记录</div>';
    }).catch(err => {
        document.getElementById('success_log').innerHTML = `<div class="text-danger">加载失败: ${escapeHtml(err.message)}</div>`;
    });
}
function toggleAuto() {
    if (autoTimer) { clearInterval(autoTimer); autoTimer = null; document.getElementById('auto_status').textContent = '自动刷新已关闭'; }
    else { autoTimer = setInterval(loadSshLog, 10000); document.getElementById('auto_status').textContent = '自动刷新中(10s)'; }
}
loadSshLog();
</script>
<%+footer%>


```

### 5.14 files/usr/lib/lua/luci/view/netmanager/access_log.htm

- **用途**：端口访问日志页：活跃连接 / 入站出站计数 / 拦截统计
- **规模**：171 行
- **维护要点**：统一走 nmFetch；footer 版本号（登记处 5）

```html
<%+header%>
<%+netmanager/common_head%>
<div class="netmanager-container">
    <div class="netmanager-header">
        <h1>网络管理</h1>
        <span class="netmanager-author">吾爱破解liyu0828</span>
    </div>
    <%+netmanager/nav%>
    <div class="netmanager-content">
        <h2>端口访问日志</h2>
        <div class="netmanager-toolbar">
            <label style="font-size:13px;color:#6b7280;">筛选端口:</label>
            <input type="text" id="filter_port" placeholder="留空全部" style="width:100px;">
            <label style="font-size:13px;color:#6b7280;">条数:</label>
            <select id="access_limit">
                <option value="50">50条</option>
                <option value="100" selected>100条</option>
                <option value="200">200条</option>
            </select>
            <button class="btn btn-primary btn-sm" onclick="loadAccessLog()">刷新</button>
            <button class="btn btn-secondary btn-sm" onclick="toggleAuto()">自动刷新</button>
            <span id="auto_status" class="text-muted"></span>
        </div>
        <div class="netmanager-cards" style="grid-template-columns: repeat(4, 1fr);">
            <div class="netmanager-card">
                <div class="card-label">活跃连接</div>
                <div class="card-value blue" id="active_count">0</div>
            </div>
            <div class="netmanager-card">
                <div class="card-label">入站连接</div>
                <div class="card-value green" id="inbound_count">0</div>
            </div>
            <div class="netmanager-card">
                <div class="card-label">出站连接</div>
                <div class="card-value" id="outbound_count">0</div>
            </div>
            <div class="netmanager-card">
                <div class="card-label">累计拦截</div>
                <div class="card-value red" id="blocked_count">0</div>
            </div>
        </div>
        <h3>当前活跃连接</h3>
        <div class="netmanager-log" id="active_log"><div class="text-muted">加载中...</div></div>
        <h3>防火墙拦截统计 (按端口)</h3>
        <div class="text-muted" style="font-size:12px;margin-bottom:6px;">点击任意一行可查看被拦截的源 IP 明细并一键拉黑（境外IP拦截已启用限速源IP记录）。</div>
        <div class="netmanager-log" id="blocked_log"><div class="text-muted">加载中...</div></div>
        <div id="block_detail_panel" style="display:none;margin-top:12px;border:1px solid #e5e7eb;border-radius:8px;padding:12px;background:#f9fafb;color:#1f2937;">
            <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px;">
                <b id="bd_title" style="color:#111827;">拦截明细</b>
                <button class="btn btn-secondary btn-sm" onclick="closeBlockDetail()">关闭</button>
            </div>
            <div id="bd_body" style="background:#ffffff;border:1px solid #e5e7eb;border-radius:6px;padding:4px;color:#1f2937;max-height:420px;overflow-y:auto;"></div>
        </div>
    </div>
    <div class="footer-sign">网络管理插件 v1.8.17</div>
</div>
<script>
const API_URL = '<%=luci.dispatcher.build_url("admin/netmanager/api")%>';
let autoTimer = null;
const PORT_SVC = {'22':'SSH','21':'FTP','23':'Telnet','25':'SMTP','53':'DNS','80':'HTTP','110':'POP3','143':'IMAP','443':'HTTPS','445':'SMB','3306':'MySQL','3389':'RDP','5432':'PostgreSQL','6379':'Redis','8080':'HTTP-Alt','8443':'HTTPS-Alt','8888':'HTTP-Alt','21115':'RustDesk','21116':'RustDesk','21117':'RustDesk','25550':'SSH(改)','853':'DoT','51133':'Bitwarden','53000':'Joyflix','53002':'SunPanel','58013':'Music-DL'};
function loadAccessLog() {
    const port = document.getElementById('filter_port').value.trim();
    const limit = document.getElementById('access_limit').value;
    nmFetch({
        method: 'POST',
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: 'action=access_log&port=' + encodeURIComponent(port) + '&limit=' + limit
    }).then(r => r.text()).then(data => {
        const sections = data.split('---');
        let activeHtml = '', blockedHtml = '';
        let activeCount = 0, inboundCount = 0, outboundCount = 0, blockedTotal = 0;
        let current = '';
        sections.forEach(section => {
            if (section.includes('ACTIVE')) current = 'active';
            else if (section.includes('BLOCKED')) current = 'blocked';
            const lines = section.split('\n').filter(l => l.trim());
            lines.forEach(line => {
                // 统计行（带=号）
                if (line.includes('=') && !line.includes('|')) {
                    const idx = line.indexOf('=');
                    const k = line.substring(0, idx), v = line.substring(idx + 1);
                    if (k === 'ACTIVE_COUNT') activeCount = parseInt(v) || 0;
                    if (k === 'IN_COUNT') inboundCount = parseInt(v) || 0;
                    if (k === 'OUT_COUNT') outboundCount = parseInt(v) || 0;
                    if (k === 'BLOCK_TOTAL') blockedTotal = parseInt(v) || 0;
                    return;
                }
                // 数据行（带|）
                if (!line.includes('|')) return;
                const parts = line.split('|');
                if (current === 'active' && parts.length >= 4) {
                    const proto = parts[0], src = parts[1], dst = parts[2], state = parts[3];
                    const isInbound = !src.match(/^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.)/);
                    const dirBadge = isInbound ? '<span class="badge badge-green">入</span>' : '<span class="badge badge-blue">出</span>';
                    const protoBadge = proto === 'tcp' ? '<span class="badge badge-blue">TCP</span>' : '<span class="badge badge-purple">UDP</span>';
                    activeHtml += `<div>${protoBadge} ${dirBadge} <span class="log-ip">${escapeHtml(src)}</span> → <span class="log-ip">${escapeHtml(dst)}</span> <span style="color:#9ca3af;">[${escapeHtml(state)}]</span></div>`;
                } else if (current === 'blocked' && parts.length >= 3) {
                    const proto = parts[0], dport = parts[1], pkts = parts[2];
                    if (parseInt(pkts) > 0) {
                        // v1.8.4：dport 可能是端口号，也可能是用途标签（境外IP拦截/黑名单/WAN口丢弃）
                        const target = /^\d+(-\d+)?$/.test(dport)
                            ? ('端口 <b>' + escapeHtml(dport) + '</b>')
                            : ('<b>' + escapeHtml(dport) + '</b>');
                        const protoLabel = (proto === 'any') ? '全部协议' : escapeHtml(proto.toUpperCase());
                        blockedHtml += `<div class="nm-block-row" data-key="${escapeHtml(dport)}" style="cursor:pointer;" title="点击查看被拦截源IP明细"><span class="log-fail">拦截</span> ${protoLabel} ${target} 累计 <b>${escapeHtml(pkts)}</b> 个包 <span style="color:#2563eb;font-size:11px;">🔍明细</span></div>`;
                    }
                }
            });
            // v1.8.4：===END 重置放在解析之后——拦截数据行与 ===END=== 同段，
            // 若在段首重置 current 会漏掉本段拦截行（明细区一直空白的根因）
            if (section.includes('===END')) current = '';
        });
        document.getElementById('active_count').textContent = activeCount;
        document.getElementById('inbound_count').textContent = inboundCount;
        document.getElementById('outbound_count').textContent = outboundCount;
        document.getElementById('blocked_count').textContent = blockedTotal;
        document.getElementById('active_log').innerHTML = activeHtml || '<div class="text-muted">暂无活跃连接</div>';
        document.getElementById('blocked_log').innerHTML = blockedHtml || '<div class="text-muted">暂无拦截记录（防火墙DROP规则计数器为0）</div>';
    });
}
function toggleAuto() {
    if (autoTimer) { clearInterval(autoTimer); autoTimer = null; document.getElementById('auto_status').textContent = '自动刷新已关闭'; }
    else { autoTimer = setInterval(loadAccessLog, 5000); document.getElementById('auto_status').textContent = '自动刷新中(5s)'; }
}
// v1.8.5：点击拦截统计行 → 查看被拦截源IP明细 → 一键拉黑
function showBlockDetail(key) {
    const panel = document.getElementById('block_detail_panel');
    panel.style.display = 'block';
    document.getElementById('bd_title').textContent = '拦截明细 — ' + key;
    document.getElementById('bd_body').innerHTML = '<div class="text-muted">加载中...</div>';
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=block_detail&key=' + encodeURIComponent(key)})
    .then(r => r.text()).then(data => {
        if (data.indexOf('NO_LOG=1') >= 0) {
            document.getElementById('bd_body').innerHTML = '<div class="text-muted">暂无源IP日志。境外IP拦截启用限速记录(10条/分钟)，需有拦截发生后才记录；黑名单/WAN/Ping 等类别不记录源IP。</div>';
            return;
        }
        const lines = data.split('\n').filter(l => l.includes('|'));
        if (data.indexOf('NO_MATCH=1') >= 0 || lines.length === 0) {
            document.getElementById('bd_body').innerHTML = '<div class="text-muted">该类别暂无匹配的源IP记录（可能拦截发生在日志记录之前，或属未启用源IP记录的类别）。</div>';
            return;
        }
        let html = '<table style="width:100%;border-collapse:collapse;font-size:12px;color:#1f2937;"><tr style="background:#f3f4f6;color:#374151;"><th style="padding:6px;text-align:left;">源IP</th><th style="padding:6px;">协议</th><th style="padding:6px;">命中端口</th><th style="padding:6px;">次数</th><th style="padding:6px;">最近时间</th><th style="padding:6px;">操作</th></tr>';
        lines.forEach(line => {
            const p = line.split('|'); if (p.length < 5) return;
            const src = p[0], proto = p[1], ports = p[2], cnt = p[3], last = p[4];
            html += `<tr style="border-bottom:1px solid #e5e7eb;"><td style="padding:6px;font-family:monospace;">${escapeHtml(src)}</td><td style="text-align:center;">${escapeHtml(proto)}</td><td style="text-align:center;">${escapeHtml(ports)}</td><td style="text-align:center;"><b>${escapeHtml(cnt)}</b></td><td style="color:#6b7280;">${escapeHtml(last)}</td><td style="text-align:center;"><button class="btn btn-danger btn-sm nm-ban-btn" data-ip="${escapeHtml(src)}">拉黑</button></td></tr>`;
        });
        html += '</table>';
        document.getElementById('bd_body').innerHTML = html;
    });
}
function closeBlockDetail() { document.getElementById('block_detail_panel').style.display = 'none'; }
function banIP(ip, btn) {
    if (!confirm('确定拉黑 ' + ip + ' ？拉黑后该IP的所有访问将被丢弃。')) return;
    if (btn) { btn.disabled = true; btn.textContent = '拉黑中'; }
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=blacklist_add&ip=' + encodeURIComponent(ip)})
    .then(r => r.text()).then(data => {
        if (data.indexOf('[ERROR]') >= 0) { alert('拉黑失败：' + data.replace(/\[CMD\][^\n]*\n?/,'').trim()); if (btn) { btn.disabled = false; btn.textContent = '拉黑'; } }
        else { alert('已拉黑 ' + ip); if (btn) { btn.textContent = '已拉黑'; } loadAccessLog(); }
    }).catch(e => { alert('请求失败：' + e); if (btn) { btn.disabled = false; btn.textContent = '拉黑'; } });
}
document.addEventListener('click', function(e) {
    if (!e.target.closest) return;
    const row = e.target.closest('.nm-block-row');
    if (row) { showBlockDetail(row.getAttribute('data-key')); return; }
    const ban = e.target.closest('.nm-ban-btn');
    if (ban) { banIP(ban.getAttribute('data-ip'), ban); }
});
loadAccessLog();
</script>
<%+footer%>


```

### 5.15 files/usr/lib/lua/luci/view/netmanager/settings.htm

- **用途**：设置页（最复杂视图，1100 行）：默认目标 / 备份恢复 / 插件更新 / 在线更新 / 中国 IPv4·IPv6 过滤 / 黑名单 / 运行日志 / 卸载
- **规模**：1243 行
- **维护要点**：三个版本号登记处（L186/L305/L338）；备份列表与过滤状态均需 escapeHtml + 数组下标传参

```html
<%+header%>
<%+netmanager/common_head%>
<div class="netmanager-container">
    <div class="netmanager-header">
        <h1>网络管理</h1>
        <span class="netmanager-author">吾爱破解liyu0828</span>
    </div>
    <%+netmanager/nav%>
    <div class="netmanager-content">
        <h2>插件设置</h2>
        <h3>默认转发目标</h3>
        <table class="netmanager-table">
            <tr>
                <td width="35%">默认目标IP</td>
                <td>
                    <input type="text" id="default_target" style="width:170px;" placeholder="如 192.168.31.196">
                    <button class="btn btn-primary btn-sm" onclick="saveDefaultTarget()">保存</button>
                    <span class="text-muted" style="margin-left:8px;">添加端口转发时留空目标IP将使用此地址</span>
                </td>
            </tr>
        </table>
        <h3>系统工具</h3>
        <div class="netmanager-toolbar">
            <button class="btn btn-primary btn-sm" onclick="runAction('reload')">重载防火墙</button>
            <button class="btn btn-warning btn-sm" onclick="runAction('restart')">重启防火墙</button>
            <button class="btn btn-success btn-sm" onclick="doBackup()">备份配置</button>
            <button class="btn btn-secondary btn-sm" onclick="loadSettings()">刷新</button>
        </div>

        <!-- 中国IPv4访问限制 -->
        <h3>中国IPv4访问限制</h3>
        <div class="netmanager-form" style="border-left:3px solid #f97316;">
            <div style="margin-bottom:10px;">
                <b>仅允许中国大陆 IPv4 访问已开放端口</b>
                <span class="text-muted" style="margin-left:8px;">境外IPv4新建连接将被丢弃；已建立连接/出站/局域网间转发不受影响；IPv6不在范围内</span>
            </div>
            <table class="netmanager-table" style="margin-bottom:10px;">
                <tr>
                    <td width="35%">当前状态</td>
                    <td id="china_status_cell"><span class="text-muted">加载中...</span></td>
                </tr>
                <tr>
                    <td>IP库订阅链接</td>
                    <td>
                        <input type="text" id="china_url" style="width:70%;" placeholder="以 http:// 或 https:// 开头，每行一个 CIDR 的纯文本订阅">
                        <button class="btn btn-secondary btn-sm" onclick="saveChinaUrl()">保存链接</button>
                    </td>
                </tr>
                <tr>
                    <td>更新计划</td>
                    <td>
                        <select id="china_cron_preset" onchange="onCronPresetChange()" style="padding:2px 5px;">
                            <option value="0 3 * * *">每天凌晨3点</option>
                            <option value="0 3 * * 0">每周日凌晨3点(默认)</option>
                            <option value="0 3 1 * *">每月1日凌晨3点</option>
                            <option value="0 */12 * * *">每12小时</option>
                            <option value="__custom__">自定义...</option>
                        </select>
                        <input type="text" id="china_cron_custom" placeholder="5段cron: 分 时 日 月 周" style="width:200px; display:none; margin-left:8px;">
                        <button class="btn btn-secondary btn-sm" onclick="saveChinaCron()">保存计划</button>
                        <span class="text-muted" style="margin-left:8px; font-size:12px;">仅允许 0-9 * / , - 字符</span>
                    </td>
                </tr>
                <tr>
                    <td>放行上级网关</td>
                    <td>
                        <label style="margin-right:8px;"><input type="checkbox" id="china_allow_wan"> 放行 WAN 同网段来源</label>
                        <button class="btn btn-secondary btn-sm" onclick="saveChinaAllowWan()">保存</button>
                        <span class="text-muted" style="margin-left:8px; font-size:12px;">光猫拨号/桥接时，上级光猫的私网地址不在 china.txt 里；开启后只放行“与本机 WAN 同网段”的地址</span>
                    </td>
                </tr>
                <tr>
                    <td>上次更新 / 条数</td>
                    <td id="china_update_cell"><span class="text-muted">—</span></td>
                </tr>
                <tr>
                    <td>生效WAN口 / 规则</td>
                    <td id="china_wan_cell"><span class="text-muted">—</span></td>
                </tr>
            </table>
            <div class="netmanager-toolbar">
                <button class="btn btn-success btn-sm" id="btn_china_enable" onclick="enableChinaFilter()">立即启用</button>
                <button class="btn btn-warning btn-sm" id="btn_china_disable" onclick="disableChinaFilter()">关闭</button>
                <button class="btn btn-primary btn-sm" id="btn_china_update" onclick="updateChinaFilter()">更新IP库</button>
                <button class="btn btn-secondary btn-sm" onclick="loadChinaStatus()">刷新状态</button>
            </div>
        </div>

        <!-- 中国IPv6访问限制 -->
        <h3>中国IPv6访问限制</h3>
        <div class="netmanager-form" style="border-left:3px solid #8b5cf6;">
            <div style="margin-bottom:10px;">
                <b>仅允许中国大陆 IPv6 访问已开放端口</b>
                <span class="text-muted" style="margin-left:8px;">境外IPv6新建TCP/UDP连接将被丢弃；已建立连接/出站/局域网间转发不受影响；与IPv4过滤相互独立</span>
            </div>
            <table class="netmanager-table" style="margin-bottom:10px;">
                <tr>
                    <td width="35%">当前状态</td>
                    <td id="china6_status_cell"><span class="text-muted">加载中...</span></td>
                </tr>
                <tr>
                    <td>IP库订阅链接</td>
                    <td>
                        <input type="text" id="china6_url" style="width:70%;" placeholder="以 http:// 或 https:// 开头，每行一个 IPv6 CIDR 的纯文本订阅">
                        <button class="btn btn-secondary btn-sm" onclick="saveChina6Url()">保存链接</button>
                    </td>
                </tr>
                <tr>
                    <td>更新计划</td>
                    <td>
                        <select id="china6_cron_preset" onchange="onCronPresetChangeFor('china6_cron_preset','china6_cron_custom')" style="padding:2px 5px;">
                            <option value="0 3 * * *">每天凌晨3点</option>
                            <option value="0 3 * * 0">每周日凌晨3点(默认)</option>
                            <option value="0 3 1 * *">每月1日凌晨3点</option>
                            <option value="0 */12 * * *">每12小时</option>
                            <option value="__custom__">自定义...</option>
                        </select>
                        <input type="text" id="china6_cron_custom" placeholder="5段cron: 分 时 日 月 周" style="width:200px; display:none; margin-left:8px;">
                        <button class="btn btn-secondary btn-sm" onclick="saveChina6Cron()">保存计划</button>
                        <span class="text-muted" style="margin-left:8px; font-size:12px;">仅允许 0-9 * / , - 字符</span>
                    </td>
                </tr>
                <tr>
                    <td>上次更新 / 条数</td>
                    <td id="china6_update_cell"><span class="text-muted">—</span></td>
                </tr>
                <tr>
                    <td>生效WAN口 / 规则</td>
                    <td id="china6_wan_cell"><span class="text-muted">—</span></td>
                </tr>
            </table>
            <div class="netmanager-toolbar">
                <button class="btn btn-success btn-sm" id="btn_china6_enable" onclick="enableChina6Filter()">立即启用</button>
                <button class="btn btn-warning btn-sm" id="btn_china6_disable" onclick="disableChina6Filter()">关闭</button>
                <button class="btn btn-primary btn-sm" id="btn_china6_update" onclick="updateChina6Filter()">更新IP库</button>
                <button class="btn btn-secondary btn-sm" onclick="loadChina6Status()">刷新状态</button>
            </div>
        </div>

        <!-- 手动黑名单（IPv4/IPv6） -->
        <h3>手动黑名单（IPv4 / IPv6）</h3>
        <div class="netmanager-form" style="border-left:3px solid #ef4444;">
            <div style="margin-bottom:10px;">
                <b>手动拉黑 IP / IP段</b>
                <span class="text-muted" style="margin-left:8px;">支持单个 IP 与 CIDR 网段（如 1.2.3.4、1.2.3.0/24、2001:db8::1、2001:db8::/32）；入站与转发流量直接丢弃，独立 nft 表 inet netmanager_ban，fw4 重载不影响</span>
            </div>
            <div class="netmanager-toolbar" style="margin-bottom:10px;">
                <input type="text" id="ban_input" placeholder="输入 IP 或 CIDR，如 10.0.0.0/8 或 2001:db8::/32" style="width:45%;">
                <button class="btn btn-danger btn-sm" onclick="addBlacklistEntry()">添加拉黑</button>
                <button class="btn btn-secondary btn-sm" onclick="loadBlacklist()">刷新</button>
                <button class="btn btn-warning btn-sm" onclick="clearBlacklist('v4')">清空IPv4</button>
                <button class="btn btn-warning btn-sm" onclick="clearBlacklist('v6')">清空IPv6</button>
            </div>
            <table class="netmanager-table">
                <tr>
                    <td width="22%">IPv4 黑名单 (<span id="ban_v4_count">0</span>)</td>
                    <td id="ban_v4_list"><span class="text-muted">—</span></td>
                </tr>
                <tr>
                    <td>IPv6 黑名单 (<span id="ban_v6_count">0</span>)</td>
                    <td id="ban_v6_list"><span class="text-muted">—</span></td>
                </tr>
            </table>
            <div class="text-muted" style="margin-top:6px;font-size:11px;">
                规则状态: <span id="ban_active_cell">—</span> | 条目持久化于 <code>/etc/netmanager/blacklist_v4.list</code> / <code>blacklist_v6.list</code>，重启或WAN重连后自动恢复
            </div>
        </div>

        <!-- 手动白名单（IPv4/IPv6，v1.8.17） -->
        <h3>手动白名单（IPv4 / IPv6）</h3>
        <div class="netmanager-form" style="border-left:3px solid #22c55e;">
            <div style="margin-bottom:10px;">
                <b>给中国IP限制开例外，放行指定 IP / IP段</b>
                <span class="text-muted" style="margin-left:8px;">支持单个 IP 与 CIDR 网段（如 8.8.8.8、203.0.113.0/24、2001:db8::1、2001:db8::/32）；这些条目会被并入 china_v4 / china_v6 集合，等于给中国IP限制加了一份“人工允许列表”，不受订阅更新影响；仅在中国IP限制启用时生效</span>
            </div>
            <div class="netmanager-toolbar" style="margin-bottom:10px;">
                <input type="text" id="wl_input" placeholder="输入 IP 或 CIDR，如 203.0.113.0/24 或 2001:db8::/32" style="width:45%;">
                <button class="btn btn-success btn-sm" onclick="addWhitelistEntry()">添加放行</button>
                <button class="btn btn-secondary btn-sm" onclick="loadWhitelist()">刷新</button>
                <button class="btn btn-warning btn-sm" onclick="clearWhitelist('v4')">清空IPv4</button>
                <button class="btn btn-warning btn-sm" onclick="clearWhitelist('v6')">清空IPv6</button>
            </div>
            <table class="netmanager-table">
                <tr>
                    <td width="22%">IPv4 白名单 (<span id="wl_v4_count">0</span>)</td>
                    <td id="wl_v4_list"><span class="text-muted">—</span></td>
                </tr>
                <tr>
                    <td>IPv6 白名单 (<span id="wl_v6_count">0</span>)</td>
                    <td id="wl_v6_list"><span class="text-muted">—</span></td>
                </tr>
            </table>
            <div class="text-muted" style="margin-top:6px;font-size:11px;">
                规则状态: <span id="wl_active_cell">—</span> | 条目持久化于 <code>/etc/netmanager/whitelist_v4.list</code> / <code>whitelist_v6.list</code>，重启、WAN重连或 china 列表更新后自动重新并入
            </div>
        </div>

        <!-- 备份管理 -->
        <h3>备份管理</h3>
        <div class="netmanager-form" style="border-left:3px solid #10b981;">
            <div style="margin-bottom:10px;">
                <b>配置备份</b>
                <span class="text-muted" style="margin-left:8px;">v1.6.1 全配置备份（firewall/network/dhcp/dnssettings/netmanager），支持导入导出与自动保留</span>
            </div>
            <div class="netmanager-toolbar">
                <button class="btn btn-success btn-sm" onclick="doBackup()">立即备份</button>
                <button class="btn btn-secondary btn-sm" onclick="listBackups()">刷新列表</button>
                <button class="btn btn-info btn-sm" onclick="document.getElementById('backup_import_file').click()">导入备份</button>
                <button class="btn btn-warning btn-sm" onclick="pruneBackups()">清理旧备份</button>
                <button class="btn btn-secondary btn-sm" onclick="runAction('cleanup_uploads')">清理临时文件</button>
                <input type="file" id="backup_import_file" style="display:none;" accept=".tar.gz,.tgz" onchange="importBackup(this)">
            </div>
            <div style="margin-top:6px;font-size:11px;color:#9ca3af;">备份内容: firewall/network/dhcp/dnssettings/netmanager 配置 + 黑名单/中国白名单列表（/etc/netmanager/） | 目录: <code>/root/backup/</code> | 自动保留最近 20 个 | 恢复前自动备份当前配置</div>
            <div id="backup_list" style="margin-top:10px;"></div>
        </div>

        <!-- 在线更新 -->
        <h3>在线更新</h3>
        <div class="netmanager-form" style="border-left:3px solid #10b981;">
            <table class="netmanager-table" style="margin-bottom:10px;">
                <tr>
                    <td width="30%">当前版本</td>
                    <td><b id="online_cur_version">v1.8.17</b></td>
                </tr>
                <tr>
                    <td>最新版本</td>
                    <td id="online_latest_version"><span class="text-muted">未检查（点击「检查更新」）</span></td>
                </tr>
                <tr>
                    <td>更新镜像</td>
                    <td>
                        <input type="text" id="update_mirror" placeholder="留空直连 GitHub；直连受限可填加速前缀，如 https://gh-proxy.com" style="width:65%;">
                        <button class="btn btn-secondary btn-sm" onclick="saveUpdateMirror()">保存镜像</button>
                    </td>
                </tr>
            </table>
            <div class="netmanager-toolbar">
                <button class="btn btn-primary btn-sm" id="btn_check_update" onclick="checkUpdate()">检查更新</button>
                <button class="btn btn-success btn-sm" id="btn_apply_update" onclick="applyUpdate()" style="display:none;">一键更新</button>
            </div>
            <div id="update_status" style="margin-top:10px;"></div>
            <div class="text-muted" style="margin-top:8px; font-size:12px;">
                说明：自动从 GitHub Releases 检查最新版本并下载安装（与手动上传等效，免下载传包）。下载前会做大小与 tar 完整性校验；安装完成后 LuCI 将延迟重启，请勿关闭页面。
            </div>
        </div>

        <!-- 插件更新 -->
        <h3>插件更新</h3>
        <div class="netmanager-form" style="border-left:3px solid #2563eb;">
            <div style="margin-bottom:10px;">
                <b>上传插件包 (.tar.gz)</b>
                <span class="text-muted" style="margin-left:8px;">从本地上传新版本插件包进行更新</span>
            </div>
            <div>
                <form id="upload_form" enctype="multipart/form-data" style="display:flex; gap:10px; align-items:center;">
                    <input type="file" id="plugin_file" accept=".tar.gz,.tgz" style="padding:5px;">
                    <button type="button" class="btn btn-primary btn-sm" onclick="uploadPlugin()">上传并更新</button>
                </form>
            </div>
            <div id="upload_status" style="margin-top:10px;"></div>
            <div class="text-muted" style="margin-top:8px; font-size:12px;">
                <b>更新说明：</b><br>
                1. 下载最新版 luci-app-netmanager-install_*.tar.gz<br>
                2. 点击"选择文件"选择下载的压缩包<br>
                3. 点击"上传并更新"按钮<br>
                4. 更新过程中会自动备份当前版本<br>
                5. 更新完成后需要刷新页面 (Ctrl+Shift+R)
            </div>
        </div>

        <div id="action_result" class="netmanager-result"></div>

        <h3>安全建议</h3>
        <div style="background:#fef3c7; padding:14px; border-radius:8px; border-left:3px solid #f59e0b; font-size:13px; line-height:2;">
            <b>基础安全检查清单：</b><br>
            1. 管理页面仅内网访问（uhttpd绑定LAN口IP）<br>
            2. SSH修改默认端口 + 仅内网或密钥登录<br>
            3. 关闭不必要的服务（rpcbind/NFS/ttyd/wsdd2）<br>
            4. 防火墙默认拒绝WAN口入站<br>
            5. 端口转发只开放必要端口<br>
            6. 定期查看SSH登录日志，发现异常IP及时封禁<br>
            7. 建议安装fail2ban自动封禁爆破IP<br>
            8. 建议开启SSH密钥登录，禁用密码登录
        </div>

        <!-- 运行日志 -->
        <h3>运行日志</h3>
        <div class="card" style="padding:15px;">
            <table class="netmanager-table" style="margin-bottom:10px;">
                <tr>
                    <td width="30%">启用日志记录</td>
                    <td>
                        <label><input type="checkbox" id="log_enable"> 将运行日志写入 /tmp/netmanager/run.log</label>
                        <span class="text-muted" style="margin-left:10px;">重启路由器后/tmp内容自动清空</span>
                    </td>
                    <td width="280px">
                        <button class="btn btn-primary btn-sm" onclick="saveLogSetting()">保存</button>
                        <button class="btn btn-secondary btn-sm" onclick="loadRunLog()">刷新日志</button>
                        <button class="btn btn-warning btn-sm" onclick="clearRunLog()">清空</button>
                    </td>
                </tr>
                <tr>
                    <td>日志路径</td>
                    <td id="log_path" colspan="2"><span class="text-muted">加载中...</span></td>
                </tr>
            </table>
            <!-- v1.6.1 日志过滤工具栏 -->
            <div style="display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-bottom:8px;padding:8px 10px;background:#f9fafb;border-radius:4px;border:1px solid #e5e7eb;">
                <label style="font-size:12px;color:#6b7280;">级别：
                    <select id="log_level" onchange="loadRunLog()" style="padding:2px 6px;font-size:12px;">
                        <option value="ALL" selected>全部</option>
                        <option value="INFO">INFO</option>
                        <option value="WARN">WARN</option>
                        <option value="ERROR">ERROR</option>
                        <option value="DEBUG">DEBUG</option>
                    </select>
                </label>
                <label style="font-size:12px;color:#6b7280;">搜索：
                    <input type="text" id="log_keyword" placeholder="关键词..." style="padding:2px 6px;font-size:12px;width:140px;" onkeydown="if(event.key==='Enter')loadRunLog()">
                </label>
                <label style="font-size:12px;color:#6b7280;">显示最后
                    <select id="log_lines" onchange="loadRunLog()" style="padding:2px 5px;font-size:12px;">
                        <option value="100">100</option>
                        <option value="200" selected>200</option>
                        <option value="500">500</option>
                        <option value="1000">1000</option>
                    </select>
                    行
                </label>
                <button class="btn btn-secondary btn-sm" style="font-size:11px;padding:2px 8px;" onclick="exportLog()">导出下载</button>
                <span style="flex:1;"></span>
                <!-- 日志统计 -->
                <span id="log_stats" style="font-size:11px;color:#9ca3af;"></span>
            </div>
            <!-- v1.6.1 彩色日志显示区 -->
            <div id="run_log_box" style="width:100%;height:280px;overflow-y:auto;background:#0f172a;color:#e2e8f0;border:1px solid #334155;border-radius:4px;padding:8px;font-family:Consolas,'Courier New',monospace;font-size:12px;line-height:1.6;"></div>
        </div>

        <h3>关于插件</h3>
        <table class="netmanager-table">
            <tr><td width="30%">插件名称</td><td>网络管理 (luci-app-netmanager)</td></tr>
            <tr><td>版本</td><td id="plugin_version">v1.8.17</td></tr>
            <tr><td>作者</td><td><b>吾爱破解liyu0828</b></td></tr>
            <tr><td>仓库地址</td><td><a href="https://github.com/District1655/luci-app-netmanager" target="_blank" style="color:#2563eb;">https://github.com/District1655/luci-app-netmanager</a></td></tr>
            <tr><td>适配系统</td><td>iStoreOS / OpenWrt (fw4/nftables)</td></tr>
            <tr><td>功能模块</td><td>系统概览 / 端口转发 / 规则管理 / SSH日志 / 访问日志</td></tr>
            <tr><td>后端脚本</td><td>/usr/sbin/netmanager</td></tr>
            <tr><td>配置文件</td><td>/etc/config/netmanager</td></tr>
        </table>

        <h3>卸载插件</h3>
        <div class="netmanager-form" style="border-left:3px solid #dc2626;">
            <div style="margin-bottom:10px;">
                <b style="color:#dc2626;">⚠ 危险操作（不可撤销）</b>
                <span class="text-muted" style="margin-left:8px;">将删除后端脚本、LuCI页面、init/hotplug脚本、nft规则、cron任务与缓存；2秒后自动重启uhttpd。用户在 /etc/config/firewall 中的端口转发与防火墙规则不受影响。</span>
            </div>
            <table class="netmanager-table" style="margin-bottom:10px;">
                <tr>
                    <td width="35%">卸载范围</td>
                    <td>
                        <label style="font-size:13px;cursor:pointer;">
                            <input type="checkbox" id="uninstall_keep_config" style="vertical-align:middle;margin-right:4px;">
                            保留配置与CIDR列表（/etc/config/netmanager 与 /etc/netmanager/）
                        </label>
                        <span class="text-muted" style="display:block;margin-top:4px;">不勾选则全删；勾选后下次重装可继承原配置</span>
                    </td>
                </tr>
            </table>
            <div class="netmanager-toolbar">
                <button class="btn btn-danger btn-sm" onclick="uninstallPlugin()">一键卸载插件</button>
                <span class="text-muted" style="margin-left:8px;">卸载后浏览器将自动跳转到首页，左侧菜单不再显示「网络管理」</span>
            </div>
        </div>
    </div>
    <div class="footer-sign">网络管理插件 v1.8.17<br><span style="font-size:10px;">适配 iStoreOS / OpenWrt | 基于 fw4/nftables</span></div>
</div>
<script>
const API_URL = '<%=luci.dispatcher.build_url("admin/netmanager/api")%>';

function loadSettings() {
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=settings'})
    .then(r => r.text()).then(data => {
        data.split('\n').forEach(line => {
            if (line.includes('=')) {
                const idx = line.indexOf('=');
                const k = line.substring(0, idx), v = line.substring(idx + 1);
                if (k === 'DEFAULT_TARGET') document.getElementById('default_target').value = v;
                if (k === 'LOG_ENABLE') document.getElementById('log_enable').checked = (v === '1');
                if (k === 'LOG_FILE') document.getElementById('log_path').innerHTML = `<code style="background:#f1f5f9;padding:2px 6px;border-radius:3px;">${escapeHtml(v)}</code> <span class="text-muted">(路由器重启后自动清空)</span>`;
                if (k === 'UPDATE_MIRROR') document.getElementById('update_mirror').value = v;
            }
        });
    });
    setTimeout(loadRunLog, 300);
    setTimeout(loadChinaStatus, 300);
}

// ========== 在线更新功能 ==========
function checkUpdate() {
    const box = document.getElementById('update_status');
    const btn = document.getElementById('btn_check_update');
    btn.disabled = true;
    box.innerHTML = '<span class="text-info">正在连接 GitHub 检查最新版本（最长约 15 秒，直连受限时请先保存镜像加速）...</span>';
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=update_check'})
    .then(r => r.text()).then(data => {
        let latest = '', avail = '', msg = '', mirror = '';
        data.split('\n').forEach(line => {
            const i = line.indexOf('=');
            if (i < 1) return;
            const k = line.substring(0, i), v = line.substring(i + 1);
            if (k === 'LATEST_VERSION') latest = v;
            else if (k === 'UPDATE_AVAILABLE') avail = v;
            else if (k === 'MESSAGE') msg = v;
            else if (k === 'MIRROR') mirror = v;
        });
        if (mirror === '(直连)') mirror = '';
        if (mirror !== '') document.getElementById('update_mirror').value = mirror;
        if (!latest) {
            box.innerHTML = '<pre class="result-pre" style="color:#f87171;">' + escapeHtml(data) + '</pre>';
        } else {
            document.getElementById('online_latest_version').innerHTML = '<b>' + escapeHtml(latest) + '</b>';
            if (avail === '1') {
                box.innerHTML = '<span class="text-success">✓ ' + escapeHtml(msg || '发现新版本') + '</span>';
                document.getElementById('btn_apply_update').style.display = '';
            } else if (avail === '0') {
                box.innerHTML = '<span class="text-success">✓ ' + escapeHtml(msg || '当前已是最新版本') + '</span>';
                document.getElementById('btn_apply_update').style.display = 'none';
            } else {
                box.innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
            }
        }
    })
    .catch(e => {
        box.innerHTML = '<span class="text-danger">检查失败: ' + escapeHtml(e.message) + '</span>';
    })
    .then(() => { btn.disabled = false; });
}

function applyUpdate() {
    if (!confirm('确定在线更新到最新版本吗？\n\n• 将从 GitHub 下载最新安装包并自动安装\n• 安装完成后 LuCI 将延迟重启，请勿关闭页面\n• 建议先在上方「系统工具」备份当前配置')) return;
    const box = document.getElementById('update_status');
    const btn = document.getElementById('btn_apply_update');
    btn.disabled = true;
    box.innerHTML = '<span class="text-info">正在下载并安装最新版（取决于网速，可能需要 1~3 分钟），请勿关闭或刷新页面...</span>';
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=update_apply'})
    .then(r => r.text()).then(data => {
        box.innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        if (data.indexOf('插件更新完成') >= 0 || data.indexOf('install_rc=0') >= 0) {
            box.innerHTML += '<div class="text-success" style="margin-top:8px;"><b>更新成功！</b>LuCI 将在数秒后重启导致连接断开（属正常现象），之后按 Ctrl+Shift+R 强制刷新浏览器即可使用新版本。</div>';
        }
    })
    .catch(e => {
        box.innerHTML = '<span class="text-warning">更新请求中断: ' + escapeHtml(e.message) + '（若因 LuCI 重启断开属正常现象，稍后刷新页面查看「关于插件」中的版本号确认）</span>';
    })
    .then(() => { btn.disabled = false; });
}

function saveUpdateMirror() {
    const m = document.getElementById('update_mirror').value.trim();
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=set_update_mirror&mirror=' + encodeURIComponent(m)})
    .then(r => r.text()).then(data => {
        document.getElementById('update_status').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
    });
}

// ========== 运行日志功能（v1.6.1 增强：级别过滤/关键词搜索/统计/彩色渲染/导出） ==========
function saveLogSetting() {
    const en = document.getElementById('log_enable').checked ? '1' : '0';
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=log_set&enable=' + en})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        loadSettings();
    });
}

function loadRunLog() {
    const level = document.getElementById('log_level').value;
    const keyword = document.getElementById('log_keyword').value.trim();
    const lines = document.getElementById('log_lines').value;
    const box = document.getElementById('run_log_box');
    box.innerHTML = '<span style="color:#64748b;">加载中...</span>';

    const body = 'action=log_query&level=' + encodeURIComponent(level)
        + '&keyword=' + encodeURIComponent(keyword)
        + '&lines=' + lines;

    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:body})
    .then(r => r.text()).then(data => {
        let content = '';
        let inContent = false;
        let totalLines = 0, matchedLines = 0;
        let cntInfo = 0, cntWarn = 0, cntError = 0, cntDebug = 0;

        data.split('\n').forEach(line => {
            if (line === '---CONTENT---') { inContent = true; return; }
            if (line === '===END===') return;
            if (inContent) {
                content += line + '\n';
            } else {
                if (line.startsWith('TOTAL_LINES=')) totalLines = parseInt(line.split('=')[1]) || 0;
                else if (line.startsWith('MATCHED_LINES=')) matchedLines = parseInt(line.split('=')[1]) || 0;
                else if (line.startsWith('COUNT_INFO=')) cntInfo = parseInt(line.split('=')[1]) || 0;
                else if (line.startsWith('COUNT_WARN=')) cntWarn = parseInt(line.split('=')[1]) || 0;
                else if (line.startsWith('COUNT_ERROR=')) cntError = parseInt(line.split('=')[1]) || 0;
                else if (line.startsWith('COUNT_DEBUG=')) cntDebug = parseInt(line.split('=')[1]) || 0;
            }
        });

        // 统计显示
        const statsEl = document.getElementById('log_stats');
        if (statsEl) {
            statsEl.innerHTML = `总计 <b style="color:#e2e8f0">${totalLines}</b> 条 | `
                + `<span style="color:#60a5fa">INFO ${cntInfo}</span> | `
                + `<span style="color:#fbbf24">WARN ${cntWarn}</span> | `
                + `<span style="color:#f87171">ERROR ${cntError}</span> | `
                + `<span style="color:#a78bfa">DEBUG ${cntDebug}</span>`
                + (matchedLines !== totalLines ? ` | 匹配 <b>${matchedLines}</b> 条` : '');
        }

        // 彩色渲染
        if (totalLines === 0) {
            box.innerHTML = '<div style="color:#64748b;padding:10px;">（暂无日志记录，请先在上方勾选"启用日志记录"并保存，然后操作页面功能以产生日志）</div>';
        } else if (matchedLines === 0 && (level !== 'ALL' || keyword)) {
            box.innerHTML = '<div style="color:#64748b;padding:10px;">（当前过滤条件下无匹配日志）</div>';
        } else {
            let html = '';
            content.trim().split('\n').forEach(line => {
                if (!line.trim()) return;
                // 解析 [时间] [级别] 内容
                const m = line.match(/^\[([^\]]+)\]\s+\[([^\]]+)\]\s+(.*)$/);
                if (m) {
                    const ts = escapeHtml(m[1]);
                    const lvl = m[2].toUpperCase();
                    const msg = escapeHtml(m[3]);
                    let lvlColor = '#e2e8f0', lvlBg = 'transparent';
                    if (lvl === 'INFO') { lvlColor = '#60a5fa'; }
                    else if (lvl === 'WARN') { lvlColor = '#fbbf24'; }
                    else if (lvl === 'ERROR') { lvlColor = '#f87171'; }
                    else if (lvl === 'DEBUG') { lvlColor = '#a78bfa'; }
                    html += `<div style="white-space:pre-wrap;word-break:break-all;"><span style="color:#64748b;">[${ts}]</span> <span style="color:${lvlColor};font-weight:600;">[${lvl}]</span> ${msg}</div>`;
                } else {
                    html += `<div style="white-space:pre-wrap;word-break:break-all;color:#94a3b8;">${escapeHtml(line)}</div>`;
                }
            });
            box.innerHTML = html;
        }
        // 自动滚动到底部
        setTimeout(() => { box.scrollTop = box.scrollHeight; }, 50);
    }).catch(e => {
        box.innerHTML = '<span style="color:#f87171;">加载日志失败: ' + escapeHtml(e.message) + '</span>';
    });
}

function clearRunLog() {
    if (!confirm('确定要清空运行日志吗？')) return;
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=log_clear'})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(loadRunLog, 500);
    });
}

// v1.6.1 日志导出下载
function exportLog() {
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=log_export'})
    .then(r => r.text()).then(data => {
        let inB64 = false;
        let b64 = '';
        let logSize = 0, logLines = 0;
        data.split('\n').forEach(line => {
            if (line === '---BASE64---') { inB64 = true; return; }
            if (line === '===END===') return;
            if (inB64) b64 += line.trim();
            else {
                if (line.startsWith('LOG_SIZE=')) logSize = parseInt(line.split('=')[1]) || 0;
                else if (line.startsWith('LOG_LINES=')) logLines = parseInt(line.split('=')[1]) || 0;
            }
        });
        if (logSize === 0 || !b64) {
            alert('日志文件为空，无法导出');
            return;
        }
        // base64 解码为 Blob 并下载
        const binary = atob(b64);
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
        const blob = new Blob([bytes], {type: 'text/plain'});
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        const ts = new Date().toISOString().replace(/[:.]/g, '-').substring(0, 19);
        a.href = url;
        a.download = `netmanager-runlog-${ts}.log`;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
    }).catch(e => {
        alert('导出失败: ' + e.message);
    });
}

function saveDefaultTarget() {
    const ip = document.getElementById('default_target').value.trim();
    if (!ip) { alert('请输入IP地址'); return; }
    if (!/^(\d{1,3}\.){3}\d{1,3}$/.test(ip)) { alert('IP格式不正确'); return; }
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=set_default_target&ip=' + ip})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
    });
}

function runAction(action) {
    document.getElementById('action_result').innerHTML = '<span class="text-info">执行中...</span>';
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=' + action})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
    });
}

// 备份功能（v1.6.1 增强：全配置备份、导入、清理、详情显示）
function doBackup() {
    if (!confirm('确定要创建全配置备份吗？\n\n将备份：firewall / network / dhcp / dnssettings / netmanager')) return;
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=backup'})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(listBackups, 1500);
    });
}

function listBackups() {
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=backup_list'})
    .then(r => r.text()).then(data => {
        let html = '';
        const lines = data.split('\n');
        let backups = [];
        let backupCount = 0;

        lines.forEach(line => {
            if (line.includes('|') && !line.startsWith('=')) {
                const parts = line.split('|');
                // v1.6.1 新格式：文件名|大小|时间|类型|配置数；旧格式：文件名|大小
                if (parts.length >= 5 && (parts[0].startsWith('netmanager-') || parts[0].startsWith('firewall-'))) {
                    backups.push({name: parts[0], size: parseInt(parts[1]) || 0, time: parts[2], type: parts[3], cfgCount: parts[4], stateCount: parts[5] || '0'});
                } else if (parts.length >= 2 && parts[0].startsWith('firewall-')) {
                    backups.push({name: parts[0], size: parseInt(parts[1]) || 0, time: '—', type: 'legacy', cfgCount: '1'});
                }
            }
            if (line.startsWith('BACKUP_COUNT=')) {
                backupCount = parseInt(line.split('=')[1]) || 0;
            }
        });

        if (backups.length === 0) {
            html = '<div class="text-muted" style="padding:15px;text-align:center;">暂无备份文件，点击上方「立即备份」创建</div>';
        } else {
            html = `<table class="netmanager-table"><thead><tr><th>备份文件名</th><th style="width:140px;">创建时间</th><th style="width:70px;">类型</th><th style="width:80px;">配置/列表</th><th style="width:80px;">大小</th><th style="width:160px;">操作</th></tr></thead><tbody>`;
            window.BACKUP_ROWS = [];
            backups.forEach(b => {
                const rowId = window.BACKUP_ROWS.push(b.name) - 1;
                const typeBadge = b.type === 'full'
                    ? '<span class="badge badge-green">全配置</span>'
                    : '<span class="badge badge-gray">旧版</span>';
                html += `<tr>
                    <td><code style="font-size:11px;">${escapeHtml(b.name)}</code></td>
                    <td style="font-size:12px;color:#6b7280;">${escapeHtml(b.time)}</td>
                    <td>${typeBadge}</td>
                    <td style="text-align:center;"><b>${escapeHtml(b.cfgCount)}</b> / ${escapeHtml(b.stateCount)}</td>
                    <td>${escapeHtml(formatSize(b.size))}</td>
                    <td>
                        <button class="btn btn-primary btn-sm" onclick="restoreBackup(${rowId})">恢复</button>
                        <button class="btn btn-danger btn-sm" onclick="deleteBackup(${rowId})">删除</button>
                    </td>
                </tr>`;
            });
            html += '</tbody></table>';
            html += `<div style="margin-top:6px;font-size:11px;color:#9ca3af;">共 ${backups.length} 个备份</div>`;
        }

        document.getElementById('backup_list').innerHTML = html;
    });
}

// v1.6.1 备份导入
function importBackup(input) {
    const file = input.files[0];
    if (!file) return;
    if (!file.name.endsWith('.tar.gz') && !file.name.endsWith('.tgz')) {
        alert('只支持 .tar.gz 格式的备份文件');
        input.value = '';
        return;
    }
    if (!confirm('确定导入备份文件 ' + file.name + ' 吗？\n\n导入后可在备份列表中选择恢复。')) {
        input.value = '';
        return;
    }
    const formData = new FormData();
    formData.append('action', 'backup_import_upload');
    formData.append('backup_file', file);
    nmFetch({method: 'POST', body: formData})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        input.value = '';
        setTimeout(listBackups, 1000);
    }).catch(e => {
        alert('导入失败: ' + e.message);
        input.value = '';
    });
}

// v1.6.1 清理旧备份
function pruneBackups() {
    const keep = prompt('保留最近多少个备份？（默认 20）', '20');
    if (keep === null) return;
    if (!/^\d+$/.test(keep) || parseInt(keep) < 1) {
        alert('请输入有效的正整数');
        return;
    }
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=backup_prune&keep=' + keep})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(listBackups, 1000);
    });
}

function formatSize(bytes) {
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1048576) return (bytes / 1024).toFixed(1) + ' KB';
    return (bytes / 1048576).toFixed(1) + ' MB';
}

function restoreBackup(rowId) {
    // 【安全 v1.4.7】onclick 传数组下标，从 window.BACKUP_ROWS 取文件名（避免自由文本入 onclick）
    const filename = (window.BACKUP_ROWS && window.BACKUP_ROWS[rowId]) || '';
    if (!filename) return;
    if (!confirm(`确定要从备份 ${filename} 恢复配置吗？\n\n⚠️ 恢复前会自动备份当前配置！`)) return;
    nmFetch({
        method:'POST',
        headers:{'Content-Type':'application/x-www-form-urlencoded'},
        body:'action=backup_restore&filename=' + encodeURIComponent(filename)
    })
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(listBackups, 1500);
    });
}

function deleteBackup(rowId) {
    const filename = (window.BACKUP_ROWS && window.BACKUP_ROWS[rowId]) || '';
    if (!filename) return;
    if (!confirm(`确定要删除备份 ${filename} 吗？此操作不可恢复！`)) return;
    nmFetch({
        method:'POST',
        headers:{'Content-Type':'application/x-www-form-urlencoded'},
        body:'action=backup_delete&filename=' + encodeURIComponent(filename)
    })
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(listBackups, 1500);
    });
}

// 插件更新功能 - 使用 multipart/form-data 原生文件上传
function uploadPlugin() {
    const fileInput = document.getElementById('plugin_file');
    const file = fileInput.files[0];
    
    if (!file) {
        alert('请先选择一个 .tar.gz 插件包');
        return;
    }
    
    if (!file.name.endsWith('.tar.gz') && !file.name.endsWith('.tgz')) {
        alert('只支持 .tar.gz 格式的插件包');
        return;
    }
    
    const statusEl = document.getElementById('upload_status');
    statusEl.innerHTML = '<span class="text-info">正在上传并更新插件...</span>';
    
    // 使用 FormData 实现 multipart/form-data 原生文件上传
    // LuCI natively supports multipart file uploads via formvalue()
    const formData = new FormData();
    formData.append('action', 'plugin_upload_update');
    formData.append('plugin_file', file);
    
    nmFetch({
        method: 'POST',
        body: formData
    })
    .then(r => r.text())
    .then(data => {
        statusEl.innerHTML = '';
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        if (data.includes('完成') || data.includes('成功')) {
            statusEl.innerHTML = '<div class="text-success" style="margin-top:10px;">✅ 插件更新完成！请刷新页面 (Ctrl+Shift+R)</div>';
            fileInput.value = '';
        }
    })
    .catch(err => {
        statusEl.innerHTML = '<div class="text-danger">❌ 更新失败: ' + escapeHtml(err.message) + '</div>';
    });
}

// ========== 中国IPv4访问限制 ==========
function loadChinaStatus() {
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=china_filter_status'})
    .then(r => r.text()).then(data => {
        let en='0', url='', cron='', lu='', cnt='0', devs='', active='0', peers='1', peersList='-';
        data.split('\n').forEach(line => {
            const idx = line.indexOf('=');
            if (idx > 0) {
                const k = line.substring(0, idx), v = line.substring(idx + 1);
                if (k === 'CHINA_FILTER_ENABLED') en = v;
                else if (k === 'URL') url = v;
                else if (k === 'CRON') cron = v;
                else if (k === 'LAST_UPDATE') lu = v;
                else if (k === 'COUNT') cnt = v;
                else if (k === 'WAN_DEVS') devs = v;
                else if (k === 'RULE_ACTIVE') active = v;
                else if (k === 'ALLOW_WAN_PEERS') peers = v;
                else if (k === 'WAN_PEERS') peersList = v;
            }
        });
        const ruleBadge = active === '1'
            ? ' <span class="badge badge-blue">规则已加载</span>'
            : (en === '1' ? ' <span class="badge badge-gray" style="background:#94a3b8;color:#fff;">规则未加载</span>' : '');
        const statusBadge = en === '1' ? '<span class="badge badge-green">已启用</span>' + ruleBadge : '<span class="badge badge-gray">已关闭</span>';
        document.getElementById('china_status_cell').innerHTML = statusBadge;
        document.getElementById('china_url').value = url;
        const aw = document.getElementById('china_allow_wan');
        if (aw) aw.checked = (peers === '1');
        // 【安全 v1.4.7】lu/cnt/devs 来自后端命令输出（WAN_DEVS 含接口名），写入前必须转义
        document.getElementById('china_update_cell').innerHTML = '上次更新: ' + escapeHtml(lu || '未更新') + ' | CIDR条数: <b>' + escapeHtml(cnt) + '</b>';
        document.getElementById('china_wan_cell').innerHTML = 'WAN设备: <code>' + escapeHtml(devs || '(未探测到)') + '</code> | 规则: ' + (active === '1' ? '<span class="text-success">生效中</span>' : '<span class="text-muted">未生效</span>')
            + ' | 放行同段: ' + (peers === '1' ? '<code>' + escapeHtml(peersList && peersList !== '-' ? peersList : '无') + '</code>' : '<span class="text-muted">已关闭</span>');
        // cron 预设回填
        const sel = document.getElementById('china_cron_preset');
        const customInput = document.getElementById('china_cron_custom');
        let matched = false;
        for (let i = 0; i < sel.options.length; i++) {
            if (sel.options[i].value === cron && sel.options[i].value !== '__custom__') { sel.selectedIndex = i; matched = true; break; }
        }
        if (!matched) {
            sel.value = '__custom__';
            customInput.value = cron;
            customInput.style.display = '';
        } else {
            customInput.value = '';
            customInput.style.display = 'none';
        }
    }).catch(e => {
        document.getElementById('china_status_cell').innerHTML = '<span class="text-danger">加载失败: ' + escapeHtml(e.message) + '</span>';
    });
}

function onCronPresetChangeFor(presetId, customId) {
    const sel = document.getElementById(presetId);
    const customInput = document.getElementById(customId);
    if (sel.value === '__custom__') { customInput.style.display = ''; }
    else { customInput.style.display = 'none'; customInput.value = ''; }
}

function onCronPresetChange() {
    onCronPresetChangeFor('china_cron_preset', 'china_cron_custom');
}

function saveChinaUrl() {
    const url = document.getElementById('china_url').value.trim();
    if (!url) { alert('请输入订阅链接'); return; }
    if (!/^https?:\/\//.test(url)) { alert('链接必须以 http:// 或 https:// 开头'); return; }
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=china_filter_set_url&url=' + encodeURIComponent(url)})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
    });
}

// v1.8.17：保存"放行 WAN 同网段来源"开关（上级光猫/网关访问）
function saveChinaAllowWan() {
    const el = document.getElementById('china_allow_wan');
    const val = el && el.checked ? '1' : '0';
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=china_filter_set_allow_wan&value=' + val})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        loadChinaStatus();
    });
}

function saveChinaCron() {
    const sel = document.getElementById('china_cron_preset');
    let cron = sel.value;
    if (cron === '__custom__') {
        cron = document.getElementById('china_cron_custom').value.trim();
        if (!cron) { alert('请输入自定义cron表达式(5段: 分 时 日 月 周)'); return; }
    }
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=china_filter_set_cron&cron=' + encodeURIComponent(cron)})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(loadChinaStatus, 300);
    });
}

function setChinaBtns(enabled) {
    ['btn_china_enable','btn_china_disable','btn_china_update'].forEach(id => {
        const b = document.getElementById(id);
        if (b) b.disabled = !enabled;
    });
}

function enableChinaFilter() {
    if (!confirm('确定开启中国IPv4访问限制吗？\n\n开启后仅中国大陆IPv4可访问已开放端口（端口转发与路由器本地放行端口），境外IPv4新建连接将被丢弃。')) return;
    setChinaBtns(false);
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=china_filter_enable'})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(() => { loadChinaStatus(); setChinaBtns(true); }, 600);
    }).catch(e => { setChinaBtns(true); alert('启用失败: ' + e.message); });
}

function disableChinaFilter() {
    if (!confirm('确定关闭中国IPv4访问限制吗？\n\n关闭后境外IPv4可恢复访问已开放端口。')) return;
    setChinaBtns(false);
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=china_filter_disable'})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(() => { loadChinaStatus(); setChinaBtns(true); }, 400);
    }).catch(e => { setChinaBtns(true); alert('关闭失败: ' + e.message); });
}

function updateChinaFilter() {
    setChinaBtns(false);
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=china_filter_update'})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(() => { loadChinaStatus(); setChinaBtns(true); }, 600);
    }).catch(e => { setChinaBtns(true); alert('更新失败: ' + e.message); });
}

// ========== 中国IPv6访问限制 ==========
function loadChina6Status() {
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=china6_filter_status'})
    .then(r => r.text()).then(data => {
        let en='0', url='', cron='', lu='', cnt='0', devs='', active='0';
        data.split('\n').forEach(line => {
            const idx = line.indexOf('=');
            if (idx > 0) {
                const k = line.substring(0, idx), v = line.substring(idx + 1);
                if (k === 'CHINA6_FILTER_ENABLED') en = v;
                else if (k === 'URL') url = v;
                else if (k === 'CRON') cron = v;
                else if (k === 'LAST_UPDATE') lu = v;
                else if (k === 'COUNT') cnt = v;
                else if (k === 'WAN_DEVS') devs = v;
                else if (k === 'RULE_ACTIVE') active = v;
            }
        });
        const ruleBadge = active === '1'
            ? ' <span class="badge badge-blue">规则已加载</span>'
            : (en === '1' ? ' <span class="badge badge-gray" style="background:#94a3b8;color:#fff;">规则未加载</span>' : '');
        document.getElementById('china6_status_cell').innerHTML = (en === '1' ? '<span class="badge badge-purple">已启用</span>' + ruleBadge : '<span class="badge badge-gray">已关闭</span>');
        document.getElementById('china6_url').value = url;
        document.getElementById('china6_update_cell').innerHTML = '上次更新: ' + escapeHtml(lu || '未更新') + ' | IPv6 CIDR条数: <b>' + escapeHtml(cnt) + '</b>';
        document.getElementById('china6_wan_cell').innerHTML = 'WAN设备: <code>' + escapeHtml(devs || '(未探测到)') + '</code> | 规则: ' + (active === '1' ? '<span class="text-success">生效中</span>' : '<span class="text-muted">未生效</span>');
        const sel = document.getElementById('china6_cron_preset');
        const customInput = document.getElementById('china6_cron_custom');
        let matched = false;
        for (let i = 0; i < sel.options.length; i++) {
            if (sel.options[i].value === cron && sel.options[i].value !== '__custom__') { sel.selectedIndex = i; matched = true; break; }
        }
        if (!matched) {
            sel.value = '__custom__';
            customInput.value = cron;
            customInput.style.display = '';
        } else {
            customInput.value = '';
            customInput.style.display = 'none';
        }
    }).catch(e => {
        document.getElementById('china6_status_cell').innerHTML = '<span class="text-danger">加载失败: ' + escapeHtml(e.message) + '</span>';
    });
}

function saveChina6Url() {
    const url = document.getElementById('china6_url').value.trim();
    if (!url) { alert('请输入订阅链接'); return; }
    if (!/^https?:\/\//.test(url)) { alert('链接必须以 http:// 或 https:// 开头'); return; }
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=china6_filter_set_url&url=' + encodeURIComponent(url)})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
    });
}

function saveChina6Cron() {
    const sel = document.getElementById('china6_cron_preset');
    let cron = sel.value;
    if (cron === '__custom__') {
        cron = document.getElementById('china6_cron_custom').value.trim();
        if (!cron) { alert('请输入自定义cron表达式(5段: 分 时 日 月 周)'); return; }
    }
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=china6_filter_set_cron&cron=' + encodeURIComponent(cron)})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(loadChina6Status, 300);
    });
}

function setChina6Btns(enabled) {
    ['btn_china6_enable','btn_china6_disable','btn_china6_update'].forEach(id => {
        const b = document.getElementById(id);
        if (b) b.disabled = !enabled;
    });
}

function enableChina6Filter() {
    if (!confirm('确定开启中国IPv6访问限制吗？\n\n开启后仅中国大陆IPv6可访问已开放端口，境外IPv6新建连接将被丢弃。')) return;
    setChina6Btns(false);
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=china6_filter_enable'})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(() => { loadChina6Status(); setChina6Btns(true); }, 600);
    }).catch(e => { setChina6Btns(true); alert('启用失败: ' + e.message); });
}

function disableChina6Filter() {
    if (!confirm('确定关闭中国IPv6访问限制吗？\n\n关闭后境外IPv6可恢复访问已开放端口。')) return;
    setChina6Btns(false);
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=china6_filter_disable'})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(() => { loadChina6Status(); setChina6Btns(true); }, 400);
    }).catch(e => { setChina6Btns(true); alert('关闭失败: ' + e.message); });
}

function updateChina6Filter() {
    setChina6Btns(false);
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=china6_filter_update'})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(() => { loadChina6Status(); setChina6Btns(true); }, 600);
    }).catch(e => { setChina6Btns(true); alert('更新失败: ' + e.message); });
}

// ========== 手动黑名单（IPv4 / IPv6） ==========
let _banV4 = [], _banV6 = [];

function renderBanList(family) {
    const list = (family === 'v4') ? _banV4 : _banV6;
    const el = document.getElementById(family === 'v4' ? 'ban_v4_list' : 'ban_v6_list');
    if (!el) return;
    if (!list.length) { el.innerHTML = '<span class="text-muted">（空）</span>'; return; }
    let html = '';
    list.forEach((entry, i) => {
        html += '<span class="badge badge-gray" style="display:inline-block;margin:2px 4px 2px 0;padding:3px 8px;font-family:monospace;">'
             + escapeHtml(entry)
             + ' <a href="javascript:void(0)" style="color:#dc2626;text-decoration:none;margin-left:4px;font-weight:bold;" '
             + 'onclick="deleteBlacklistEntry(\'' + family + '\',' + i + ')" title="删除">×</a></span>';
    });
    el.innerHTML = html;
}

function loadBlacklist() {
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=blacklist_list'})
    .then(r => r.text()).then(data => {
        let v4='', v6='', v4n='0', v6n='0', active='0';
        data.split('\n').forEach(line => {
            const idx = line.indexOf('=');
            if (idx > 0) {
                const k = line.substring(0, idx), v = line.substring(idx + 1);
                if (k === 'V4') v4 = v;
                else if (k === 'V6') v6 = v;
                else if (k === 'V4_COUNT') v4n = v;
                else if (k === 'V6_COUNT') v6n = v;
                else if (k === 'ACTIVE') active = v;
            }
        });
        _banV4 = v4 ? v4.split(',') : [];
        _banV6 = v6 ? v6.split(',') : [];
        document.getElementById('ban_v4_count').textContent = v4n;
        document.getElementById('ban_v6_count').textContent = v6n;
        document.getElementById('ban_active_cell').innerHTML = active === '1'
            ? '<span class="text-success">规则生效中</span>'
            : '<span class="text-muted">未生效（无条目或未应用）</span>';
        renderBanList('v4');
        renderBanList('v6');
    }).catch(e => {
        document.getElementById('ban_v4_list').innerHTML = '<span class="text-danger">加载失败: ' + escapeHtml(e.message) + '</span>';
    });
}

function addBlacklistEntry() {
    const ip = document.getElementById('ban_input').value.trim();
    if (!ip) { alert('请输入 IP 或 CIDR 网段'); return; }
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=blacklist_add&ip=' + encodeURIComponent(ip)})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        if (data.indexOf('已拉黑') >= 0) document.getElementById('ban_input').value = '';
        setTimeout(loadBlacklist, 300);
    }).catch(e => alert('添加失败: ' + e.message));
}

function deleteBlacklistEntry(family, idx) {
    const list = (family === 'v4') ? _banV4 : _banV6;
    const entry = list[idx];
    if (!entry) return;
    if (!confirm('确定从黑名单移除该条目吗？\n\n' + entry)) return;
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=blacklist_del&ip=' + encodeURIComponent(entry)})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(loadBlacklist, 300);
    }).catch(e => alert('删除失败: ' + e.message));
}

function clearBlacklist(family) {
    if (!confirm('确定清空 ' + (family === 'v4' ? 'IPv4' : 'IPv6') + ' 黑名单吗？此操作不可撤销。')) return;
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=blacklist_clear&family=' + encodeURIComponent(family)})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(loadBlacklist, 300);
    }).catch(e => alert('清空失败: ' + e.message));
}

// ========== 手动白名单（IPv4 / IPv6，v1.8.17） ==========
let _wlV4 = [], _wlV6 = [];

function renderWlList(family) {
    const list = (family === 'v4') ? _wlV4 : _wlV6;
    const el = document.getElementById(family === 'v4' ? 'wl_v4_list' : 'wl_v6_list');
    if (!el) return;
    if (!list.length) { el.innerHTML = '<span class="text-muted">（空）</span>'; return; }
    let html = '';
    list.forEach((entry, i) => {
        html += '<span class="badge badge-gray" style="display:inline-block;margin:2px 4px 2px 0;padding:3px 8px;font-family:monospace;">'
             + escapeHtml(entry)
             + ' <a href="javascript:void(0)" style="color:#dc2626;text-decoration:none;margin-left:4px;font-weight:bold;" '
             + 'onclick="deleteWhitelistEntry(\'' + family + '\',' + i + ')" title="删除">×</a></span>';
    });
    el.innerHTML = html;
}

function loadWhitelist() {
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=whitelist_list'})
    .then(r => r.text()).then(data => {
        let v4='', v6='', v4n='0', v6n='0', active='0';
        data.split('\n').forEach(line => {
            const idx = line.indexOf('=');
            if (idx > 0) {
                const k = line.substring(0, idx), v = line.substring(idx + 1);
                if (k === 'V4') v4 = v;
                else if (k === 'V6') v6 = v;
                else if (k === 'V4_COUNT') v4n = v;
                else if (k === 'V6_COUNT') v6n = v;
                else if (k === 'ACTIVE') active = v;
            }
        });
        _wlV4 = v4 ? v4.split(',') : [];
        _wlV6 = v6 ? v6.split(',') : [];
        const c4 = document.getElementById('wl_v4_count'), c6 = document.getElementById('wl_v6_count');
        if (c4) c4.textContent = v4n;
        if (c6) c6.textContent = v6n;
        const ac = document.getElementById('wl_active_cell');
        if (ac) ac.innerHTML = active === '1'
            ? '<span class="text-success">规则生效中（白名单来源已放行）</span>'
            : '<span class="text-muted">未生效（无条目或未应用）</span>';
        renderWlList('v4');
        renderWlList('v6');
    }).catch(e => {
        const el = document.getElementById('wl_v4_list');
        if (el) el.innerHTML = '<span class="text-danger">加载失败: ' + escapeHtml(e.message) + '</span>';
    });
}

function addWhitelistEntry() {
    const ip = document.getElementById('wl_input').value.trim();
    if (!ip) { alert('请输入 IP 或 CIDR 网段'); return; }
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=whitelist_add&ip=' + encodeURIComponent(ip)})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        if (data.indexOf('已加入白名单') >= 0) document.getElementById('wl_input').value = '';
        setTimeout(loadWhitelist, 300);
    }).catch(e => alert('添加失败: ' + e.message));
}

function deleteWhitelistEntry(family, idx) {
    const list = (family === 'v4') ? _wlV4 : _wlV6;
    const entry = list[idx];
    if (!entry) return;
    if (!confirm('确定从白名单移除该条目吗？\n\n' + entry)) return;
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=whitelist_del&ip=' + encodeURIComponent(entry)})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(loadWhitelist, 300);
    }).catch(e => alert('删除失败: ' + e.message));
}

function clearWhitelist(family) {
    if (!confirm('确定清空 ' + (family === 'v4' ? 'IPv4' : 'IPv6') + ' 白名单吗？此操作不可撤销。')) return;
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=whitelist_clear&family=' + encodeURIComponent(family)})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        setTimeout(loadWhitelist, 300);
    }).catch(e => alert('清空失败: ' + e.message));
}

// ========== 卸载插件 ==========
function uninstallPlugin() {
    const keep = document.getElementById('uninstall_keep_config').checked ? '1' : '0';
    const keepTxt = keep === '1' ? '• 保留 /etc/config/netmanager、/etc/netmanager/ 与 /etc/config/dnssettings\n' : '• 删除 /etc/config/netmanager、/etc/netmanager/ 与 /etc/config/dnssettings\n';
    const msg = '⚠ 确定卸载「网络管理插件」吗？\n\n此操作将：\n'
        + '• 关闭中国IPv4过滤并清理 nft 规则、cron 任务\n'
        + '• 删除后端脚本 /usr/sbin/netmanager\n'
        + '• 删除 LuCI 控制器、DNS CBI 模型与全部视图页面\n'
        + '• 删除 DNS 应用/备份脚本 (dnssettings-apply.sh / dnssettings-backup.sh)\n'
        + '• 删除 init / hotplug 自启脚本\n'
        + keepTxt
        + '• 清理 /tmp 临时文件与 LuCI 缓存\n'
        + '• 2秒后自动重启 uhttpd\n\n'
        + '用户在 /etc/config/firewall 中的端口转发与防火墙规则不受影响，保留不动。\n\n'
        + '卸载后浏览器将自动跳转到首页，左侧菜单不再显示「网络管理」。';
    if (!confirm(msg)) return;
    if (!confirm('⚠ 二次确认：这是最终确认，卸载后无法撤销，确定继续？')) return;
    document.getElementById('action_result').innerHTML = '<pre class="result-pre" style="color:#dc2626;">卸载进行中，请勿关闭页面...（uhttpd 重启会导致连接断开，属正常现象）</pre>';
    nmFetch({method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=uninstall&keep=' + keep})
    .then(r => r.text()).then(data => {
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">' + escapeHtml(data) + '</pre>';
        // 3秒后uhttpd已重启，跳转首页
        setTimeout(() => {
            alert('卸载已完成，uhttpd 正在重启。\n点击确定后浏览器将跳转到首页。');
            window.location.href = '/';
        }, 3000);
    }).catch(e => {
        // uhttpd重启会断开连接，属正常
        document.getElementById('action_result').innerHTML = '<pre class="result-pre">卸载请求已发出（uhttpd重启导致连接断开属正常现象）。\n请等待3秒后刷新浏览器或访问路由器首页。</pre>';
        setTimeout(() => { window.location.href = '/'; }, 3000);
    });
}

// 初始化
loadSettings();
listBackups();
loadChina6Status();
loadBlacklist();
loadWhitelist();
</script>
<%+footer%>


```

### 5.16 files/etc/config/netmanager

- **用途**：防火墙模块 UCI 配置：默认目标 IP / 日志开关 / 中国 IPv4·IPv6 过滤参数 / 更新镜像
- **规模**：17 行
- **维护要点**：china_filter_url/cron 与 china6_filter_url/cron 默认值即官方订阅源

```uci
config netmanager 'settings'
    option default_target '192.168.31.196'
    option log_days '7'
    option auto_ban '0'
    option auto_ban_threshold '5'
    option log_enable '0'
    option china_filter_enable '0'
    option china_filter_url 'https://metowolf.github.io/iplist/data/special/china.txt'
    option china_filter_cron '0 3 * * 0'
    option china_filter_last_update ''
    option china_filter_count '0'
    option china6_filter_enable '0'
    option china6_filter_url 'https://ispip.clang.cn/all_cn_ipv6.txt'
    option china6_filter_cron '0 3 * * 0'
    option china6_filter_last_update ''
    option china6_filter_count '0'
    option update_mirror ''


```

### 5.17 files/etc/config/dnssettings

- **用途**：上网设置模块 UCI 配置：wan / lan / dnsmasq / actions 四节
- **规模**：22 行
- **维护要点**：wan/lan/dnsmasq 三节由 dns_settings.lua 绑定；actions 为按钮占位

```uci
config wan 'wan'
    option peerdns '0'
    option dns1_v4 '223.5.5.5'
    option dns2_v4 '119.29.29.29'
    option dns1_v6 '2400:3200::1'
    option dns2_v6 '2402:4e00::'

config lan 'lan'
    option force_dns '1'
    option dns1_v4 '223.5.5.5'
    option dns2_v4 '119.29.29.29'
    option dns1_v6 '2400:3200::1'
    option dns2_v6 '2402:4e00::'

config dnsmasq 'dnsmasq'
    option enable '1'
    list forward_v4 '223.5.5.5'
    list forward_v4 '119.29.29.29'
    list forward_v6 '2400:3200::1'
    list forward_v6 '2402:4e00::'

config actions 'actions'


```

### 5.18 files/etc/init.d/netmanager-china

- **用途**：开机自启脚本：重建中国 IPv4/IPv6 过滤与黑名单 nft 规则
- **规模**：26 行
- **维护要点**：START/STOP 顺序须晚于防火墙，确保 fw4 就绪

```bash
#!/bin/sh /etc/rc.common
# ============================================================
# 网络管理插件 - 中国IPv4/IPv6访问限制 + 手动黑名单 开机自启
# 
# 作用: 开机后从本地持久化列表重建 nft 集合与过滤/黑名单规则
#       (nft 规则在内核内存中，重启即清空，需重新应用)
# ============================================================

START=99

boot() {
    # 后台延迟执行，等待网络/防火墙就绪，避免阻塞开机
    sh -c 'sleep 8; /usr/sbin/netmanager china_filter boot' >/dev/null 2>&1 &
}

start() {
    /usr/sbin/netmanager china_filter boot
}

stop() {
    :
}

restart() {
    /usr/sbin/netmanager china_filter boot
}


```

### 5.19 files/etc/hotplug.d/iface/95-netmanager-china

- **用途**：WAN 上线热插拔：接口 up 时重应用过滤与黑名单（自愈）
- **规模**：30 行
- **维护要点**：编号 95 保证在 fw4 默认 hotplug 之后执行

```bash
#!/bin/sh
# ============================================================
# 网络管理插件 - 中国IPv4/IPv6访问限制 + 手动黑名单 WAN接口事件
# 
# 作用: WAN 接口 up 时重新应用过滤/黑名单规则，刷新 WAN 设备名
#       (解决 PPPoE 重连 / DHCP 续约导致设备名漂移后规则失效)
# ============================================================

# 仅处理 ifup 事件
[ "$ACTION" = "ifup" ] || exit 0

# 仅对 wan 类接口生效（INTERFACE 形如 wan / wan6 / wan-xxx）
case "$INTERFACE" in
    wan|wan6|wan-*|wan6-*) ;;
    *) exit 0 ;;
esac

# 仅在功能已启用或存在黑名单条目时重应用（避免无谓执行）
en4=$(uci -q get netmanager.settings.china_filter_enable 2>/dev/null)
en6=$(uci -q get netmanager.settings.china6_filter_enable 2>/dev/null)
if [ "$en4" != "1" ] && [ "$en6" != "1" ] \
   && [ ! -s /etc/netmanager/blacklist_v4.list ] \
   && [ ! -s /etc/netmanager/blacklist_v6.list ]; then
    exit 0
fi

# 后台重应用，不阻塞 hotplug
( sleep 2; /usr/sbin/netmanager china_filter boot ) >/dev/null 2>&1 &

exit 0


```

### 5.20 files/etc/hotplug.d/iface/96-netmanager-v6sync

- **用途**：WAN 上线热插拔：同步 IPv6 转发目标（前缀变化跟随）
- **规模**：62 行
- **维护要点**：与 */10 cron 兜底互补，两者都要保留

```bash
#!/bin/sh
# ============================================================
# 网络管理插件 - IPv6 前缀变更自愈 + SSH 监听自愈（v1.8.0 新增）
#
# 处理两类实测故障：
#
# 1) 运营商 PD 前缀变更后，IPv6 端口放行规则里写死的 dest_ip 失效。
#    wan6/wan up 后延迟同步一次，按锚点重算目标主机的当前 IPv6。
#
# 2) dropbear 若以 DirectInterface 绑定到 br-lan（SO_BINDTODEVICE），
#    netifd 重建 br-lan 后监听套接字绑定的 ifindex 失效：
#    表现为端口仍 LISTEN、但连接被 refused。
#    此时重启 dropbear 即可恢复。lan ifup 时做一次自检。
# ============================================================

[ "$ACTION" = "ifup" ] || exit 0

case "$INTERFACE" in
    wan|wan6|wan_6|wan-*|wan6-*)
        # v1.8.7：WAN 上线/重拨后先自愈 IPv6 默认网关（pppoe 补默认路由 +
        # 强制 ra_default=1 宣告网关），再按锚点同步端口放行目标。
        # 前缀可能刚下发，延迟等待地址与租约就绪后再执行。
        (
            sleep 12
            /usr/sbin/netmanager v6gw --quiet
            if uci -q get netmanager.@v6track[0] >/dev/null 2>&1; then
                /usr/sbin/netmanager port_sync_v6 --quiet
            fi
        ) >/dev/null 2>&1 &
        ;;
    lan)
        # 仅当 dropbear 绑定了具体接口时才需要自愈（未绑定不受影响）
        dif=$(uci -q get dropbear.@dropbear[0].DirectInterface 2>/dev/null)
        [ -z "$dif" ] && exit 0
        (
            sleep 5
            # v1.8.1：不能用本机 TCP 自连判断。dropbear 设 DirectInterface 后
            # 以 SO_BINDTODEVICE 绑在该接口，而本机连自身地址走回环路由，
            # 无论用 127.0.0.1 还是 LAN IP 都连不通 —— 探测必然失败，
            # 会导致每次 lan ifup 都无谓重启 dropbear（并踢掉在线会话）。
            # 真正的判据是网卡 ifindex 是否变过：变了才说明旧套接字失效。
            dev="br-$dif"
            [ -d "/sys/class/net/$dev" ] || dev="$dif"
            cur=$(cat "/sys/class/net/$dev/ifindex" 2>/dev/null)
            [ -z "$cur" ] && exit 0
            state="/tmp/.netmanager_db_ifindex.$dif"
            old=$(cat "$state" 2>/dev/null)
            if [ -z "$old" ]; then
                # 首次观测：dropbear 是在 lan 就绪后启动的，认定当前绑定有效
                echo "$cur" > "$state"
                exit 0
            fi
            if [ "$cur" != "$old" ]; then
                logger -t netmanager "SSH 绑定网卡 $dev ifindex $old -> $cur，重启 dropbear 恢复监听"
                /etc/init.d/dropbear restart >/dev/null 2>&1
                echo "$cur" > "$state"
            fi
        ) >/dev/null 2>&1 &
        ;;
esac

exit 0


```

### 5.21 install.sh

- **用途**：一键安装脚本：7 步安装（复制文件/权限/符号链接/init/cron），支持 SKIP_UHTTPD_RESTART
- **规模**：143 行
- **维护要点**：版本号登记处 2、3；新增安装产物须三处同步（install.sh / uninstall / files/）

```bash
#!/bin/ash
# ============================================================
# 网络管理插件 (luci-app-netmanager) - 一键安装脚本 v1.8.17
# 由 luci-app-fwmanager (防火墙管理) 与 luci-app-dnssettings (DNS设置) 合并而成
# ============================================================

echo "============================================"
echo "  网络管理插件 (luci-app-netmanager) v1.8.17"
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

echo "[6/7] 复制系统脚本（IPv4/IPv6过滤与黑名单开机自启）..."
mkdir -p /etc/init.d /etc/hotplug.d/iface
cp -f "$FILES_DIR/etc/init.d/netmanager-china" /etc/init.d/netmanager-china
chmod +x /etc/init.d/netmanager-china
cp -f "$FILES_DIR/etc/hotplug.d/iface/95-netmanager-china" /etc/hotplug.d/iface/95-netmanager-china
chmod +x /etc/hotplug.d/iface/95-netmanager-china 2>/dev/null
cp -f "$FILES_DIR/etc/hotplug.d/iface/96-netmanager-v6sync" /etc/hotplug.d/iface/96-netmanager-v6sync
chmod +x /etc/hotplug.d/iface/96-netmanager-v6sync 2>/dev/null
/etc/init.d/netmanager-china enable 2>/dev/null
echo "  ✓ /etc/init.d/netmanager-china (开机自启)"
echo "  ✓ /etc/hotplug.d/iface/95-netmanager-china (WAN上线重应用)"
echo "  ✓ /etc/hotplug.d/iface/96-netmanager-v6sync (IPv6前缀变更同步 + SSH监听自愈)"

# v1.8.3：IPv6 目标同步定时兜底。
# PD 前缀可能在续租时静默变化而不触发 ifup，hotplug 会漏掉；
# 每 10 分钟检查一次，前缀未变时开销极小（仅读一次地址与配置）。
CRON_LINE='*/10 * * * * /usr/sbin/netmanager port_sync_v6 --quiet >/dev/null 2>&1'
if [ -f /etc/crontabs/root ]; then
    if ! grep -qF 'netmanager port_sync_v6' /etc/crontabs/root 2>/dev/null; then
        echo "$CRON_LINE" >> /etc/crontabs/root
        /etc/init.d/cron restart >/dev/null 2>&1
        echo "  ✓ 已添加 IPv6 目标同步定时任务（每10分钟）"
    else
        echo "  - IPv6 目标同步定时任务已存在"
    fi
else
    mkdir -p /etc/crontabs
    echo "$CRON_LINE" > /etc/crontabs/root
    /etc/init.d/cron enable >/dev/null 2>&1
    /etc/init.d/cron restart >/dev/null 2>&1
    echo "  ✓ 已创建 crontab 并添加 IPv6 目标同步任务"
fi

# 【v1.8.9】自动拉黑功能下线，清理 v1.8.8 残留（定时任务/内存表/历史）
if [ -f /etc/crontabs/root ] && grep -qF 'netmanager autoban' /etc/crontabs/root 2>/dev/null; then
    grep -vF 'netmanager autoban' /etc/crontabs/root > /tmp/.nm_ab_cron 2>/dev/null
    cat /tmp/.nm_ab_cron > /etc/crontabs/root
    rm -f /tmp/.nm_ab_cron
    /etc/init.d/cron restart >/dev/null 2>&1
    echo "  ✓ 已移除自动拉黑定时扫描"
fi
rm -f /tmp/netmanager/autoban.list 2>/dev/null
nft delete table inet netmanager_autoban 2>/dev/null

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


```

### 5.22 .github/workflows/build.yml

- **用途**：CI：push main 时从 README 提版本 → 语法门禁 → 打 tar.gz → 打 tag → 发 Release（body 取自更新日志）
- **规模**：276 行
- **维护要点**：tag 已存在则整条跳过；重发同版本用 workflow_dispatch 勾 force

````yaml
name: Build Install Package
on:
  workflow_dispatch:
    inputs:
      force:
        description: '强制重新打包（忽略版本已存在检查）'
        required: false
        type: boolean
        default: false
  push:
    branches:
      - main
      - master
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      # 用于触发 publish-istore.yml（GITHUB_TOKEN 不能触发 release 事件，但可以调 workflow_dispatch）
      actions: write
    steps:
      - uses: actions/checkout@v4
        with:
          # 需要完整提交历史：缺更新日志时按 git log 自动补一节
          fetch-depth: 0

      - name: Read version from README
        id: version
        run: |
          # 从 README.md 头部「版本：vX.Y.Z」提取最新版本号（-m1 取第一处匹配）
          # 提取失败时用当前日期兜底，保证流水线不中断
          VERSION=$(grep -m1 -oE '版本：v[0-9]+\.[0-9]+\.[0-9]+' README.md | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
          if [ -z "$VERSION" ]; then
            VERSION=$(date +'%Y.%m.%d')
            echo "WARN: 未从 README.md 提取到版本号，使用日期兜底: $VERSION"
          fi
          TAG="v${VERSION}"
          echo "version=${VERSION}" >> $GITHUB_OUTPUT
          echo "tag=${TAG}" >> $GITHUB_OUTPUT
          echo "Version: ${TAG}"

      - name: Check if tag already exists
        id: check
        run: |
          TAG="${{ steps.version.outputs.tag }}"
          if git ls-remote --exit-code --tags origin "refs/tags/${TAG}" >/dev/null 2>&1; then
            echo "exists=true" >> $GITHUB_OUTPUT
            echo "Tag ${TAG} 已存在，跳过打包与发布（如需强制重新发布，请手动运行本 workflow 并勾选 force）"
          else
            echo "exists=false" >> $GITHUB_OUTPUT
            echo "Tag ${TAG} 不存在，开始打包发布"
          fi

      # 【v1.4.6 CI 门禁】语法检查：任何 shell 脚本或 Lua 文件语法错误即终止流水线
      - name: Shell & Lua syntax check (gate)
        if: steps.check.outputs.exists == 'false' || inputs.force == true
        run: |
          FAIL=0
          echo "===== Shell 语法检查 (sh -n) ====="
          for f in files/usr/sbin/netmanager \
                   files/usr/sbin/dnssettings-apply.sh \
                   files/usr/sbin/dnssettings-backup.sh \
                   install.sh \
                   files/etc/init.d/netmanager-china \
                   files/etc/hotplug.d/iface/95-netmanager-china; do
            if [ -f "$f" ]; then
              if sh -n "$f"; then
                echo "PASS: $f"
              else
                echo "FAIL: $f"
                FAIL=1
              fi
            else
              echo "WARN: $f 不存在（跳过）"
            fi
          done
          echo "===== Lua 语法检查 (luac -p) ====="
          sudo apt-get update -qq && sudo apt-get install -y -qq lua5.1 >/dev/null
          FOUND_LUA=0
          while IFS= read -r f; do
            FOUND_LUA=1
            if luac5.1 -p "$f" 2>&1; then
              echo "PASS: $f"
            else
              echo "FAIL: $f"
              FAIL=1
            fi
          done < <(find files/usr/lib/lua -name '*.lua' 2>/dev/null)
          if [ "$FOUND_LUA" = "0" ]; then
            echo "WARN: 未找到任何 .lua 文件"
          fi
          if [ "$FAIL" = "1" ]; then
            echo "::error::语法检查未通过，流水线终止（修复后再发布）"
            exit 1
          fi
          echo "===== 全部语法检查通过 ====="

      # 【v1.8.15 CI 兜底】忘写更新日志不再出空 Release：缺段落就按 git log 自动补一节并提交
      - name: Ensure changelog section (auto-generate if missing)
        id: changelog
        if: steps.check.outputs.exists == 'false' || inputs.force == true
        run: |
          OUT=$(python3 tools/ensure_changelog.py --version "${{ steps.version.outputs.version }}") || {
            echo "::warning::ensure_changelog.py 执行失败，跳过自动补日志"
            exit 0
          }
          echo "$OUT"
          STATUS=$(echo "$OUT" | grep -m1 'status=' | cut -d= -f2)
          if [ "$STATUS" = "generated" ]; then
            git config user.name "github-actions[bot]"
            git config user.email "github-actions[bot]@users.noreply.github.com"
            git add docs/CHANGELOG.md
            git commit -m "docs: v${{ steps.version.outputs.version }} 更新日志（CI 自动生成）[skip ci]"
            # [skip ci] 防止本提交再触发一次发版流水线；推失败也不阻塞发版（本次用工作区文件）
            git push origin HEAD:main || echo "::warning::自动补的日志未推送到远端，请在本地 git push"
            echo "generated=true" >> $GITHUB_OUTPUT
          else
            echo "generated=false" >> $GITHUB_OUTPUT
          fi

      - name: Build tar.gz install package
        if: steps.check.outputs.exists == 'false' || inputs.force == true
        run: |
          chmod +x install.sh files/usr/sbin/netmanager files/usr/sbin/dnssettings-apply.sh files/usr/sbin/dnssettings-backup.sh files/etc/init.d/netmanager-china files/etc/hotplug.d/iface/95-netmanager-china 2>/dev/null || true
          # 打包安装包（iStoreOS 不支持标准 ipk，使用 tar.gz + install.sh 脚本安装）
          # 使用 GNU tar --owner=0 --group=0 保证在路由器上属主正确；--mode 保证脚本可执行
          tar --owner=0 --group=0 --mode='u=rwX,go=rX' -czvf luci-app-netmanager-install_${{ steps.version.outputs.tag }}.tar.gz install.sh files/
          ls -lh luci-app-netmanager-install_*.tar.gz
          # 【v1.4.6】产物校验：打包后 tar tzf 预检成员完整可读 + 生成 sha256（供 update_apply 校验）
          echo "===== 产物 tar 完整性预检 ====="
          tar tzf luci-app-netmanager-install_*.tar.gz >/dev/null && echo "tar 预检通过"
          echo "===== 生成 sha256 校验文件 ====="
          for f in luci-app-netmanager-install_*.tar.gz; do
            sha256sum "$f" > "${f}.sha256"
            cat "${f}.sha256"
          done

      - name: Create and push tag
        if: steps.check.outputs.exists == 'false' || inputs.force == true
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git tag -f ${{ steps.version.outputs.tag }}
          git push -f origin ${{ steps.version.outputs.tag }}

      - name: Extract changelog from docs/CHANGELOG.md
        id: extract
        if: steps.check.outputs.exists == 'false' || inputs.force == true
        run: |
          # 从 docs/CHANGELOG.md 提取当前版本的段落，作为 Release body 的变更内容
          # 注意：日志标题是 "### vX.Y.Z (日期)"（带 v 前缀），必须补 v 再匹配
          # 历史记录已从 README.md 迁到 docs/CHANGELOG.md（README 只留最近一版摘要 + 链接）
          CHANGELOG=$(awk -v ver="v${{ steps.version.outputs.version }}" -f .github/workflows/extract_changelog.awk docs/CHANGELOG.md)
          if [ -z "$(echo "$CHANGELOG" | tr -d '[:space:]')" ]; then
            CHANGELOG="（docs/CHANGELOG.md 中未找到 v${{ steps.version.outputs.version }} 的更新日志段落）"
            echo "WARN: 未提取到更新日志，Release 将使用占位文案"
          fi
          # 写入多行 output（heredoc 定界符语法，GitHub Actions 官方推荐，保留换行）
          echo "changelog<<CHANGELOG_EOF" >> $GITHUB_OUTPUT
          echo "$CHANGELOG" >> $GITHUB_OUTPUT
          echo "CHANGELOG_EOF" >> $GITHUB_OUTPUT
          echo "提取到的更新日志行数: $(echo "$CHANGELOG" | wc -l)"

      - name: Release
        if: steps.check.outputs.exists == 'false' || inputs.force == true
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ steps.version.outputs.tag }}
          files: |
            luci-app-netmanager-install_*.tar.gz
            luci-app-netmanager-install_*.tar.gz.sha256
          generate_release_notes: true
          body: |
            ## 网络管理插件 ${{ steps.version.outputs.tag }}

            > 适配：iStoreOS / OpenWrt (fw4/nftables)
            >
            > 由 luci-app-fwmanager 与 luci-app-dnssettings 合并而成

            ### 本次更新（v${{ steps.version.outputs.version }}）

            ${{ steps.extract.outputs.changelog }}

            ---

            ### 功能模块
            - 系统概览（防火墙状态/端口统计/网络信息/快捷操作）
            - 端口转发管理（IPv4 DNAT + IPv6放行，支持TCP/UDP/双协议）
            - 防火墙规则管理（自定义增删规则 + 常用模板）
            - SSH登录日志（成功/失败记录 + 失败IP排行 + 自动刷新）
            - 端口访问日志（活跃连接/入站出站计数/拦截统计）
            - **DNS设置（v1.4.0 新增）**：WAN口上游DNS / LAN口设备下发DNS / dnsmasq全局转发，IPv4+IPv6双栈，一键应用与配置备份
            - **静态IPv6分配（v1.4.0 新增）**：基于MAC绑定 hostid/ip6/DUID，自动合并重复条目与 hostid 冲突检测
            - 设置（默认目标IP/安全建议/系统工具/配置备份/插件在线更新/运行日志排错）
            - **中国IPv4访问限制（继承自 v1.3.33）**：仅允许中国大陆 IPv4 访问已开放端口（DNAT+路由器本地开放端口），境外 IPv4 新建连接丢弃；默认订阅 `https://metowolf.github.io/iplist/data/special/china.txt`，支持自定义订阅链接与自定义 cron 更新计划；开机 init + WAN hotplug 自愈；**旧版 nft 自动降级兼容**（modern `flags interval, auto-merge` 分片加载 / compat `flags interval` 单次原子加载 + 逐行回退）；**v1.8.16 起自动放行 WAN 口同网段来源**（上级光猫/网关在私网段时不再被误杀，可用 `china_filter allow_wan off` 关闭）
            - **中国IPv6访问限制（v1.7.0 新增）**：与 IPv4 对称，独立 nft 表 `inet netmanager6`，仅允许中国大陆 IPv6 访问已开放端口；默认订阅 `https://ispip.clang.cn/all_cn_ipv6.txt`，订阅与 cron 可自定义；开机/WAN hotplug 自愈
            - **手动黑名单（v1.7.0 新增）**：IPv4/IPv6 单 IP 与 CIDR 网段拉黑，独立 nft 表 `inet netmanager_ban`，条目持久化并自动恢复

            ### 安装方法（iStoreOS 推荐脚本安装）
            1. 下载 `luci-app-netmanager-install_*.tar.gz` 上传到路由器 `/tmp`
            2. SSH 登录路由器，执行：
            ```bash
            cd /tmp
            tar xzvf luci-app-netmanager-install_*.tar.gz
            ./install.sh
            ```
            3. 安装后左侧菜单出现「网络管理」，浏览器 Ctrl+Shift+R 强制刷新

            ### 中国IPv4访问限制 使用指引
            1. 左侧进入「网络管理 → 设置」→ 找到「中国IPv4访问限制」区块
            2. 确认 IP库订阅链接（默认 `https://metowolf.github.io/iplist/data/special/china.txt`，可改自定义订阅）
            3. 选择更新计划（预设每天/每周/每月/每12小时或自定义 cron）
            4. 先点「更新IP库」下载最新 CIDR 列表，再点「立即启用」应用 nft 规则
            5. 状态显示 "已启用 / RULE_ACTIVE=1" 即代表过滤生效；若路由器 nft 过旧，运行日志会显示自动降级 `旧版 nft 不支持 auto-merge，降级为 flags interval + 一次性原子加载`

            ### 命令行用法
            ```bash
            netmanager overview       # 系统概览
            netmanager port_list      # 端口转发列表
            netmanager ssh_log        # SSH登录日志
            netmanager access_log     # 端口访问日志
            netmanager rule_list      # 防火墙规则列表

            # DNS设置（v1.4.0+，等价于页面「应用配置」按钮）
            dnssettings-apply.sh      # 应用 /etc/config/dnssettings 到系统
            dnssettings-backup.sh     # 备份 network/dhcp 配置到 /root/backup/

            # 中国IPv4访问限制（继承自 v1.3.33）
            netmanager china_filter status                 # 查看状态
            netmanager china_filter enable                 # 开启（应用规则 + 装cron + 自启）
            netmanager china_filter disable                # 关闭（清规则 + 移cron，保留列表与设置）
            netmanager china_filter update                 # 更新IP库并重应用规则
            netmanager china_filter set_url <url>          # 自定义订阅链接
            netmanager china_filter set_cron "0 4 * * *"   # 自定义更新计划cron

            # 中国IPv6访问限制（v1.7.0+）
            netmanager china6_filter status                # 查看状态
            netmanager china6_filter enable                # 开启
            netmanager china6_filter disable               # 关闭
            netmanager china6_filter update                # 更新IPv6 IP库

            # 手动黑名单（v1.7.0+，支持单IP与CIDR）
            netmanager blacklist list
            netmanager blacklist add 10.0.0.0/8
            netmanager blacklist add 2001:db8::/32
            netmanager blacklist del 10.0.0.0/8
            netmanager blacklist clear v4|v6|all

            # 卸载插件
            netmanager uninstall                # 全删（含 DNS 配置与脚本）
            netmanager uninstall keep           # 保留 /etc/config/netmanager、/etc/netmanager/ 与 /etc/config/dnssettings，其余全删
            ```

            > 也可在「设置」页面点击「一键卸载插件」按钮卸载（支持保留配置勾选）。卸载不影响用户在 /etc/config/firewall 中的端口转发与防火墙规则。

      # 说明：GitHub 规定 GITHUB_TOKEN 产生的 release 事件不会递归触发其它 workflow，
      #       所以这里显式触发 publish-istore.yml（workflow_dispatch 属于允许的例外），
      #       否则 Release 里永远只有 tar.gz，没有 ipk/apk，也不会提上架 PR。
      - name: Trigger istore publish workflow
        if: steps.check.outputs.exists == 'false' || inputs.force == true
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh workflow run publish-istore.yml \
            -f version="${{ steps.version.outputs.version }}" \
            -f release=1 \
            --repo "${{ github.repository }}"
          echo "已触发 Publish to iStore（version=${{ steps.version.outputs.version }} / release=1）"

      # 版本历史只留最近 10 个：Tag 与 Release 同步清理，避免页面越堆越长
      - name: Prune old releases & tags (keep latest 10)
        if: steps.check.outputs.exists == 'false' || inputs.force == true
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          KEEP: '10'
        run: bash tools/prune_history.sh


````

### 5.23 .github/workflows/publish-istore.yml

- **用途**：CI：Release 发布后构建 ipk/apk、上传 Release 资产、自动向 istoreos/istore-repo（pending）与 openwrt-app-meta（main）提 PR
- **规模**：118 行
- **维护要点**：依赖 ISTORE_TOKEN；未配置只构建不提 PR；支持 dry_run/version/release 三个手动入参

```yaml
name: Publish to iStore

# 触发：GitHub Release 发布后自动跑；也可手动指定版本
on:
  release:
    types: [published]
  workflow_dispatch:
    inputs:
      version:
        description: '版本号，如 1.8.15（不带 v）'
        required: true
      release:
        description: '包修订号（同版本重发时递增）'
        required: false
        default: '1'
      dry_run:
        description: '只构建、不提 PR'
        required: false
        type: boolean
        default: false

permissions:
  contents: write

jobs:
  publish:
    runs-on: ubuntu-latest
    env:
      ISTORE_TOKEN: ${{ secrets.ISTORE_TOKEN }}
    steps:
      - uses: actions/checkout@v4

      - name: 计算版本号
        id: ver
        run: |
          if [ -n "${{ inputs.version }}" ]; then
            V="${{ inputs.version }}"
          else
            V="${GITHUB_REF_NAME#v}"
          fi
          R="${{ inputs.release }}"; [ -n "$R" ] || R=1
          echo "version=$V" >> $GITHUB_OUTPUT
          echo "release=$R" >> $GITHUB_OUTPUT
          echo "版本: $V  修订: $R"

      - name: 校验 PLUGIN_VERSION 与发布版本一致
        run: |
          PV=$(grep -m1 '^PLUGIN_VERSION=' files/usr/sbin/netmanager | cut -d'"' -f2)
          echo "PLUGIN_VERSION=$PV  发布版本=${{ steps.ver.outputs.version }}"
          if [ "$PV" != "${{ steps.ver.outputs.version }}" ]; then
            echo "::error::files/usr/sbin/netmanager 里的 PLUGIN_VERSION=$PV 与发布版本不一致，请先改一致再发版"
            exit 1
          fi

      - uses: actions/setup-python@v5
        with:
          python-version: '3.x'

      - name: 构建 ipk（opkg / 24.10 及更早）
        run: |
          python3 tools/build_ipk.py \
            --version "${{ steps.ver.outputs.version }}" \
            --release "${{ steps.ver.outputs.release }}" \
            --files files --out dist

      - name: 构建 apk（25.12）
        run: |
          VERSION="${{ steps.ver.outputs.version }}" \
          RELEASE="${{ steps.ver.outputs.release }}" \
          OUT=dist bash tools/build_apk.sh

      - name: 产物清单
        run: ls -lh dist

      # 两种触发方式都要能挂资产：release 事件用 event.release.tag_name，
      # workflow_dispatch（含 build.yml 末尾显式触发）用计算出的 v<version>
      - name: 追加到 Release 资产
        if: inputs.dry_run != true
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          TAG="${{ github.event.release.tag_name }}"
          [ -n "$TAG" ] || TAG="v${{ steps.ver.outputs.version }}"
          echo "上传到 Release: $TAG"
          if gh release view "$TAG" >/dev/null 2>&1; then
            gh release upload "$TAG" dist/* --clobber
            gh release view "$TAG" --json assets --jq '.assets[]|"\(.name)  \(.size)"'
          else
            echo "::warning::Release $TAG 不存在，跳过上传（先让 build.yml 发版）"
          fi

      - name: 检查是否配置了 ISTORE_TOKEN
        id: token
        env:
          TOKEN: ${{ secrets.ISTORE_TOKEN }}
        run: |
          if [ -n "$TOKEN" ]; then
            echo "ok=1" >> $GITHUB_OUTPUT
          else
            echo "ok=0" >> $GITHUB_OUTPUT
            echo "::notice::未配置 ISTORE_TOKEN，将跳过自动提 PR"
          fi

      - name: 提交 PR 到 iStore（istore-repo + openwrt-app-meta）
        if: steps.token.outputs.ok == '1' && inputs.dry_run != true
        env:
          GH_TOKEN: ${{ secrets.ISTORE_TOKEN }}
        run: |
          VERSION="${{ steps.ver.outputs.version }}" \
          RELEASE="${{ steps.ver.outputs.release }}" \
          DIST=dist \
          bash tools/publish_istore.sh

      - name: 未配置 ISTORE_TOKEN 时的提示
        if: steps.token.outputs.ok == '0'
        run: |
          echo "::notice::没有配置 ISTORE_TOKEN，已跳过自动提 PR。产物在 dist/ 与 Release 里，可手动提交。"
          echo "配置方法见 docs/istore-publish.md"


```

### 5.24 .github/workflows/extract_changelog.awk

- **用途**：Release body 提取脚本：从 docs/CHANGELOG.md 取出指定版本段落
- **规模**：18 行
- **维护要点**：注释里的版本号是历史记录，勿改

```awk
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


```

### 5.25 tools/build_ipk.py

- **用途**：打 ipk 工具：固定 mtime、目录 755/文件 644、脚本可执行位，产出 tar.gz 外壳的 _all.ipk
- **规模**：152 行
- **维护要点**：iStore CI 只认 tar.gz 外壳（ar 格式判 invalid）；支持 --version/--release/--files/--out

```python
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


```

### 5.26 tools/build_apk.sh

- **用途**：打 apk 工具：缓存 openwrt-sdk-mini，chmod 规范化后调 apk mkpkg，再用 adbdump 自检
- **规模**：77 行
- **维护要点**：字段名是 name/version（不是 pkgname/pkgver）；多个 depends 写在同一个 -I 值里空格分隔

```bash
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


```

### 5.27 tools/publish_istore.sh

- **用途**：上架 PR 工具：blob→tree(base_tree 取上游 pending/main)→commit→ref→PR，幂等（同 head 有 open PR 则跳过）
- **规模**：160 行
- **维护要点**：GH_TOKEN 走 ISTORE_TOKEN；DRY_RUN=1 干跑；请求体走 stdin，避免 argv 过长

```bash
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
BRANCH="auto/$PKG-$VERSION-r$RELEASE"
META_BRANCH="auto/app-meta-$PKG-$VERSION"
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
    local repo=$1 head=$2 base=$3 title=$4 body=$5 existing
    if [ "$DRY_RUN" = "1" ]; then say "DRY: PR $repo $head -> $base"; echo "https://github.com/$repo/pulls"; return 0; fi
    existing=$(api GET "/repos/$repo/pulls?state=open&head=$OWNER:$head" | jq 'length')
    if [ "$existing" != "0" ]; then
        say "==> $repo 已有同分支的 PR，跳过"
        api GET "/repos/$repo/pulls?state=open&head=$OWNER:$head" | jqv '.[0].html_url'
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


```

### 5.28 tools/ensure_changelog.py

- **用途**：发布兜底：docs/CHANGELOG.md 缺当前版本段落时，按 git log 自动补一节（已存在则不动）
- **规模**：146 行
- **维护要点**：CI 在 syntax gate 后调用；自动补的提交带 `[skip ci]`，避免二次触发发版；纯 docs/ci 提交默认不进 body

```python
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


```

### 5.29 istore/app-meta/Makefile

- **用途**：软件中心卡片元数据模板：META_TITLE/DESCRIPTION/AUTHOR/DEPENDS/TAGS/LUCI_ENTRY/WEBSITE + PKG_VERSION/PKG_RELEASE
- **规模**：17 行
- **维护要点**：PKG_VERSION/PKG_RELEASE 由 publish 脚本 sed 注入，勿写死；末尾 include ../../meta.mk

```make
include $(TOPDIR)/rules.mk

PKG_VERSION:=1.8.14
PKG_RELEASE:=1

META_TITLE:=网络管理
META_TITLE.en:=NetManager
META_DESCRIPTION:=一站式网络管理：端口转发（IPv4/IPv6）、防火墙规则、SSH 与端口访问日志、仅中国大陆 IP 访问限制、手动黑名单、WAN/LAN 上网方式与双栈 DNS、静态 IP 分配
META_DESCRIPTION.en:=All-in-one network manager: IPv4/IPv6 port forwarding, firewall rules, SSH and port access logs, China-mainland-only access control, manual blacklist, WAN/LAN settings with dual-stack DNS, and static IP binding.
META_AUTHOR:=District1655
META_DEPENDS:=+luci-app-netmanager
META_TAGS:=networking firewall
META_LUCI_ENTRY:=/cgi-bin/luci/admin/netmanager
META_WEBSITE:=https://github.com/District1655/luci-app-netmanager
META_TUTORIAL:=https://github.com/District1655/luci-app-netmanager#readme

include ../../meta.mk


```

### 5.30 docs/gen_source_part.py

- **用途**：文档生成器：写 docs/source-full.md 源码全录 + PROJECT.md 第 5 章索引与第 9 章行号表
- **规模**：310 行
- **维护要点**：新增受控文件时在 FILES 列表补一条；第 9 章行号自动抓取，无需手改

````python
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
    ("files/usr/lib/lua/luci/view/netmanager/settings.htm", "html",
     "设置页（最复杂视图，1100 行）：默认目标 / 备份恢复 / 插件更新 / 在线更新 / 中国 IPv4·IPv6 过滤 / 黑名单 / 运行日志 / 卸载",
     "三个版本号登记处（L186/L305/L338）；备份列表与过滤状态均需 escapeHtml + 数组下标传参"),
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


````

### 5.31 docs/CHANGELOG.md

- **用途**：全部历史版本记录（v1.8.14 → v1.4.0 → 继承 fwmanager v1.3.33），GitHub Release body 的来源
- **规模**：403 行
- **维护要点**：段落标题必须保持 `### vX.Y.Z (日期)`（build.yml 的 awk 按此匹配）；每版在顶部新增小节

```markdown
# 更新日志（docs/CHANGELOG.md）

> 本文件从 `README.md` 迁出（2026-11-26），是**全部历史版本记录的唯一出处**。
> `build.yml` 从这里提取当前版本段落作为 GitHub Release body，段落标题格式必须保持 `### vX.Y.Z (日期)`。
> **忘写不影响发版**：CI 会用 `tools/ensure_changelog.py` 按提交记录自动补一节（已存在则不改动，人工写的优先）。
> `README.md` 只保留「最近一版要点 + 指向本文件的链接」。

> **2026-11-26 工程更新（版本号不变，交付形态与 CI 变更）**：新增 ipk/apk 双格式打包（`tools/`）、iStore 软件中心上架元数据（`istore/app-meta/`）、Release 后自动构建并提 PR 到 `istoreos/istore-repo` 与 `istoreos/openwrt-app-meta` 的流水线（`.github/workflows/publish-istore.yml`）；README 安装章节按 apk/opkg 双体系重写。

### v1.8.17 (2026-11-27)
- **新增手动白名单（IPv4 / IPv6 双栈）**：`netmanager whitelist list|add|del|clear|apply`，支持单个 IP 与 CIDR 网段（`8.8.8.8`、`203.0.113.0/24`、`2001:db8::1`、`2001:db8::/32`）。实现方式是**把手动条目直接并进中国过滤的 `china_v4` / `china_v6` 集合**，等于给订阅列表加了一份“人工补充的允许列表”——这些来源不再命中 `ip saddr != @china_v4 drop`；条目不受 china.txt 订阅更新影响。
- **为什么不用独立 accept 链**：netfilter 里 `accept` 只结束当前 base chain，同一个 hook 上的其它 base chain（中国过滤 -50）仍会继续执行。真机实测独立的 -60 `accept` 链：accept 计数在涨、drop 计数同时也在涨，包照样被丢；因此改为集合注入，行为可预期。
- **持久化与自愈**：条目存 `/etc/netmanager/whitelist_v4.list` / `whitelist_v6.list`，重启、WAN 重连、china 列表更新或备份恢复后都会重新并入集合（`wl_apply_all` 重建规则）；删条目同样立刻从集合里消失。
- **设置页新增「手动白名单」区块**：输入框 + 添加/删除/清空 + IPv4/IPv6 条目列表与规则状态，交互与「手动黑名单」一致；控制器新增 `whitelist_list/add/del/clear` 四个 action。
- **与自动化配合**：v1.8.16 的「放行 WAN 同网段来源」解决“上级光猫恰好同段”的普遍场景；白名单用于逐条精确放行（境外 VPS、跨网段光猫、临时排障），两者互不冲突。注意：白名单只在中国IP限制启用时生效。
- **真机验证（iStoreOS 25.12.6 / x86_64 / nft 1.1.6）**：`whitelist add 203.0.113.0/24`、`2001:db8::/32` 后集合内可见该条目；用 veth+netns 构造同构校验规则做 A/B——白名单在场时 drop 计数 0，`del` 后集合里消失；`clear all` 后 china_v4 回到 5570 条、china6 1719 条，规则正常。

### v1.8.16 (2026-11-27)
- **修复：上级光猫/网关访问不到路由器（issue #1）**。此前白名单规则为「`iifname {WAN}` 且 `ip saddr != @china_v4` → drop」，而 `china.txt` 只收录**大陆公网**地址段；光猫拨号/桥接场景下 WAN 口落在私网段（如 `192.168.1.0/24`），光猫自身的私网 IP 不在集合里 → 被当成境外地址丢弃。现在规则解析出 **WAN 口自身所在网段**，在 drop 之前放行该网段来源（`get_wan_prefixes`，纯 shell 算 CIDR，不依赖 ipcalc；PPP 点对点接口按 `peer` 后的掩码解析）。只放行“与自己同段”的地址，**不是**把整个 RFC1918 灌进去，攻击面几乎不变。
- **新增开关「放行上级网关」**：`uci netmanager.settings.china_filter_allow_wan_peers`（默认 1），设置页中国 IPv4 区块新增勾选框与保存按钮（`china_filter_set_allow_wan`），命令行 `netmanager china_filter allow_wan on|off|status`；`china_filter status` 增加 `ALLOW_WAN_PEERS` / `WAN_PEERS` 两行，设置页「生效WAN口 / 规则」一行同时显示放行网段。
- **IPv6 侧对称修复**：`china6` 链在 drop 前放行 `fd00::/8`（ULA）与 WAN 口自身 `/64`（此前只放行 `fe80::/10`、`ff00::/8` 与 DHCPv6），避免光猫用私网 IPv6 访问时被误杀。
- **调试钩子（不改变正常行为）**：`NM_WAN_DEVS_OVERRIDE` 可临时指定 WAN 设备列表、`NM_RULES_ONLY=1` 只打印生成的 nft 规则不落盘，供真机复现与排查。
- **真机验证（iStoreOS 25.12.6 / x86_64 / nft 1.1.6）**：用 veth + netns 构造「同段邻居」场景，老规则 4 个 SYN 全部命中 drop；新规则 24 个 SYN 全部命中 accept、drop 计数为 0；本机 PPPoE（`/32`）场景解析为 `223.167.209.134/32`，规则与 IPv4/IPv6 链均正常重建，drop 计数继续增长（境外扫描仍被拦）。

### v1.8.15 (2026-11-26)
- **新增 ipk / apk 双格式安装包（随 Release 自动产出）**：iStoreOS 25.12+（apk-tools，系统内无 opkg）装 `luci-app-netmanager-<版本>-r<rel>.apk`；iStoreOS 24.10 / OpenWrt 23.05–24.10 装 `luci-app-netmanager_<版本>-r<rel>_all.ipk`；`tar.gz + install.sh` 保留为未适配架构与开发态的兜底路径。产物由 `tools/build_ipk.py`、`tools/build_apk.sh` 生成（固定 mtime、目录 755 / 文件 644、conffiles 与 postinst/prerm 钩子）。
- **iStore 软件中心上架材料**：新增 `istore/app-meta/`（META_TITLE/DESCRIPTION/AUTHOR/DEPENDS/TAGS/LUCI_ENTRY/WEBSITE + 256×256 图标），按官方目录规范（`all/nas_luci`）出包；`.github/workflows/publish-istore.yml` 在 Release 发布后自动向 `istoreos/istore-repo`（base `pending`）与 `istoreos/openwrt-app-meta`（base `main`）提收录 PR。
- **发版全自动化**：push main → 打 tag / 发 Release → 构建 ipk+apk → 上传 Release 资产 → 自动提 PR，一条链路到底；忘写更新日志时 CI 用 `tools/ensure_changelog.py` 按提交记录自动补一节（提交带 `[skip ci]`，不二次触发），不再出现空 Release body。
- **安装/卸载钩子在 25.12 真机验证**：`apk add` 后依赖全满足、自动清 LuCI 缓存、启用并启动 `netmanager-china`、重建 `inet netmanager`/`netmanager6`/`netmanager_ban` 三张表；`apk del` 清表并保留 `/etc/config/netmanager`、`/etc/config/dnssettings`。
- **修复**：`install.sh` 横幅、六个页面页脚与设置页版本显示统一到 1.8.15（此前分别滞留 1.8.11 / 1.8.14）。
- **文档归档**：源码全录移入 `docs/source-full.md`（PROJECT.md 第 5 章改为索引，全文从 1.2 万行降到 830 行），版本历史移入本文件（README 只留最近一版摘要）。

### v1.8.14 (2026-11-24)
- **备份/恢复覆盖整个插件**：备份包在原有 5 个 UCI 配置（firewall/network/dhcp/dnssettings/netmanager，含 v6track 跟踪锚点）之外，新增 `/etc/netmanager/` 状态文件——手动黑名单 `blacklist_v4/v6.list` 与中国 IPv4/IPv6 白名单 `china_v4/v6.list`（tar 内 `state/` 子目录，MANIFEST 增加 `STATE_COUNT`/`STATE_FILES`）。跨机恢复或离线恢复后白名单/黑名单无需重新下载订阅即可生效。
- **恢复后自动重应用与重建 cron**：恢复列表文件后按恢复出的配置重应用黑名单（`ban_apply_all`）与已启用的中国 IPv4/IPv6 白名单规则，并重建对应更新 cron；新增 `v6sync_cron_ensure` 在恢复与开机路径补建 `*/10` 前缀同步兜底 cron（此前仅 install.sh 安装时写入，跨机恢复/卸载重装后会缺失）。
- **恢复安全加固**：解压前对 tar 成员做路径预检，拒绝 `../` 与绝对路径成员，防止恶意备份包写穿临时工作目录（与 v1.4.4 更新包预检同口径）。
- **设置页备份列表**：「配置数」列改为「配置/列表」双计数，备份说明注明覆盖范围；旧格式备份（无 STATE_COUNT）列表数记 0，恢复旧备份时保留当前列表文件不动。

### v1.8.13 (2026-11-24)
- **转发与放行分页展示**：自动配套的 `Allow-IPv6-*` 直连放行规则不再显示在「防火墙规则管理」页，移至「端口转发」页新增的「IPv6 端口放行（直连）」区（复用 `port_list` 的 IPV6 段，口径不变：family=ipv6 且 dest=lan 带端口）。该区标注「自动配套 / 自定义」来源，自动配套规则提供启用/禁用开关（新增 `netmanager rule_toggle <索引> <1|0>`，禁用只断直连路径不影响转发，且有确认提示），自定义放行规则可删除；规则页对移出的规则显示条数迁移提示。
- **规则管理页新增「源IP / 目的IP」两列**：`rule_list` 输出末尾追加 `src_ip`/`dest_ip` 两字段（旧版前端按前 9 字段解析，向后兼容），表格空值显示「任意」。此前表格只画区域/协议/端口，dest_ip 锁定目标 GUA 的单机粒度规则看起来像整段 wan→lan 放行，易误读误删；现在粒度一眼可见。编辑表单行为不变（`rule_edit` 只改既有字段，不触碰 src_ip/dest_ip）。
- **插件页响应加 no-cache 头**：`Cache-Control: no-store` + `Pragma: no-cache`，避免版本更新后旧标签页滞留旧版前端 JS、用旧解析逻辑读新后端输出造成编辑表单/列表错乱；更新后普通刷新即可拿到新页面。

### v1.8.12 (2026-11-24)
- **修复翻译端口映射把内部端口暴露公网直连**：v1.8.11 为所有 IPv6 DNAT 映射配套生成 `Allow-IPv6-<外部端口>-<协议>` 放行规则（dest_port=内部端口）。对**有翻译端口**的映射（如 853→38853），fw4 的 DNAT 真实生效打 `ct status dnat` 标记，内建 `ct status dnat accept` 已放行全部转发路径（含直连目标 GUA:外部端口被 dstnat_wan 翻译的路径），配套 ACCEPT 规则纯属冗余，反而让外部**直连目标 GUA:内部端口（38853）也被放行**，绕过了端口翻译。现改为：翻译端口映射不生成配套放行规则，仅**无翻译端口**（外部=内部，DNAT 空操作不打 ct 标记）保留 v1.8.11 机制。
- **存量自愈**：`port_sync_v6` 扫描全部 IPv6 映射（不限于跟踪锚点），发现内部端口≠外部端口且存在历史 `Allow-IPv6` 残留时自动删除并重载防火墙；升级后随每 10 分钟 cron / WAN hotplug 同步自动清理，无需手动干预。`port_add`/`port_edit` 对翻译端口同步清理旧残留，`port_del` 清理逻辑不变。

### v1.8.11 (2026-11-23)
- **IPv6 转发自动配套直连放行规则**：fw4 的 DNAT 无目的地址门槛，直连目标主机 GUA 的入站包同样会被翻译端口（外部→内部），故 forward 链看到的是内部端口。此前 v1.8.10 只建 DNAT，对「无翻译端口」（如 51116→51116，DNAT 空操作不打 ct 标记）直连路径会被默认丢弃（典型表现：RustDesk 等服务的 IPv6 直连不通）。现 port_add 创建 IPv6 DNAT 映射时同步生成 `Allow-IPv6-<外部端口>-<协议>` 放行规则，**dest_port 用内部端口**（匹配 DNAT 翻译后的包）、dest_ip 限定目标 GUA，并纳入 v6track 前缀跟踪；port_edit/port_del 按族联动更新/清理。有翻译端口由 DNAT+ct 放行、本规则兜底，无翻译端口由本规则放行。
- 放行规则按名称前缀（外部端口）精确匹配清理与同步，不误伤用户自定义规则；port_sync_v6 改按名称匹配改写 dest_ip，兼容翻译端口（内部端口≠外部端口）。

### v1.8.10 (2026-11-23)
- **端口转发页支持真正的 IPv6 端口映射**：添加转发选 IPv6/both 时创建 `redirect family=ipv6` 的 DNAT 映射（ipv6:port），与 IPv4 对称；不再默认生成「IPv6 端口放行」ACCEPT 规则。目标填 IPv4 时自动解析该主机当前公网 IPv6 并登记跟踪锚点；解析不到明确报错（DNAT 必须有目标地址）。
- **IPv6 端口放行移出端口转发页**：放行（ACCEPT）规则统一由「规则管理」页维护；端口转发页只保留 IPv4 DNAT 与 IPv6 DNAT 两张表，IPv6 映射表补齐 编辑/删除/跟踪 操作。
- **修复规则管理页「添加规则」无反应**：根因是 `nmFetch` 只给 FormData/string 形态补 CSRF token，`URLSearchParams` 形态漏补 → 403 静默失败。nmFetch 增加 URLSearchParams 分支，并为各操作补 catch 错误回显。
- **编辑/删除按族隔离**：port_edit/port_del 增加族参数，v4/v6 同端口条目互不误伤；删除 v6 映射时同步清理跟踪锚点。

### v1.8.9 (2026-11-21)
- **移除自动拉黑功能**（v1.8.8 引入）：经评估在 china 白名单模型下冗余——白名单外的境外流量默认已丢弃，自动拉黑只是把已丢弃的包再记一遍，无安全增量；SSH 为局域网绑定+仅密钥登录、无爆破面，改 SSH 防爆破同样空转。故整体下线（后端 autoban、cron、设置页面板/查看弹窗、概览计数卡片），安装时自动清理 v1.8.8 残留（定时任务/内存表/历史）。
- **保留**概览页 IPv6 状态（WAN PD 前缀/LAN GUA/默认网关）与 DNS 状态（模式/上游）展示，以及手动黑名单。

### v1.8.8 (2026-11-21)

**新增：自动拉黑（端口扫描防护）+ 系统概览补 IPv6 / DNS 状态**

- 自动拉黑：窗口期内同一境外源 IP 被拦截（NM_DROP4/6 日志）累计 ≥ 阈值次数（默认 5 次 / 10 分钟）自动拉黑。数据源与拦截明细相同，仅作用于已被境外过滤丢包的扫描源
- **纯内存存储**：拉黑列表 / 历史 / 日志全部位于 `/tmp/netmanager`（tmpfs），重启清零、不写闪存；独立 nft 表 `inet netmanager_autoban`，与手动黑名单（闪存持久化）互不影响
- 可配置：启用开关、拦截次数、窗口(分)、**条数上限**（默认 1000，保留最新防内存膨胀）、**TTL 自动过期**（默认 24h，0=不过期，误伤自愈）、**IPv6 按 /64 聚合**（默认开，防扫描源同段换地址）、**白名单**（IP / IPv4 CIDR，护住自家监控/VPS/探针）
- 保护名单：私网 / LAN / 环回 / 链路本地 / ULA / CGNAT / 组播永不拉黑
- 设置页新增自动拉黑面板：只显示数量 + 「查看 / 搜索 / 解封」按钮，弹窗列表支持搜索与一键解封，条目区分「自动 / 手动」标签，自包含高对比配色（亮暗主题均清晰）；境外过滤关闭时给出空转提示
- 每 5 分钟 cron 自动扫描；`netmanager autoban run|status|apply|clear|enable|disable|config` 命令行齐全；卸载自动清理 cron 与内存表
- 系统概览：新增 IPv6 状态（出口 / WAN IPv6 / PD 前缀 / LAN 分发 / 默认路由）、DNS（模式 / 上游服务器）与自动拉黑计数卡片

### v1.8.7 (2026-11-21)

**新增：IPv6 默认网关自愈（v6gw），修复 pppoe 关闭 wan.ipv6 后客户端拿到 SLAAC 地址却没有默认网关、上不了网**

- 新增 `netmanager v6gw [--quiet]` 网关自愈命令，处理两类实测故障：① pppoe 场景为抑制 netifd 自动 `wan_6` 与手动 `wan6` 双 IPv6 WAN 接口冲突（手动 wan6 持续 `Invalid argument` 抖动、频繁重载防火墙搅乱 RA）而关闭 `network.wan.ipv6` 后，pppoe 自带的 IPv6 默认路由随之消失，手动 wan6 只做 PD 委派不装默认路由 → 路由器无 IPv6 默认路由；② odhcpd 默认 `ra_default=0` 仅在路由器有默认路由时才宣告网关 → RA 的 Router lifetime=0，LAN 客户端拿到 SLAAC 地址却没有默认网关。`v6gw` 在 pppoe 且默认路由缺失/指向失效设备时补 `default dev <wan-l3> metric 512`，并在 LAN `ra=server` 时强制 `ra_default=1` 确保始终宣告网关
- 自愈触发：WAN `ifup`/重拨 hotplug 延迟 12s 先跑 `v6gw` 再同步端口目标；`port_sync_v6` 末尾顺带调用 `v6gw`（复用现有每 10 分钟 cron 兜底，前缀续租静默变化也能自愈）；上网设置应用脚本在 SLAAC / RA+DHCPv6 两个 server 分支同步写入 `ra_default=1`
- 说明：`planb` 为 iStoreOS 应急兜底接口（br-lan 上 DHCP 客户端，默认 `auto=0` 不开机启动），正常上网无需启用，与网关故障无关

### v1.8.6 (2026-11-21)

**修复：重启后 LAN 公网 IPv6 分发中断（wan6 dns_search 残留 + peerdns 引号）；静态IP禁止绑定公网 GUA；拦截明细文字看不清；调整：上网设置 IPv6 段移到 WAN 下方**

- 修复重启/重拨后应用 DNS 配置导致 LAN 公网 IPv6 分发中断：**根因**是 `network.wan6` 残留运营商下发的 `dns_search` 选项，本平台（iStoreOS 25.12）netifd 的 dhcpv6 proto 不接受该选项 → `wan_6` setup 报 `ubus error: Invalid argument` 无限重试、PD 续租失败、odhcpd 租约清空、LAN 设备拿不到公网 IPv6。应用脚本现在配置 wan6 后主动清除 `dns_search`（pppoe 的 wan 接受该选项，不受影响）；同时修复写 `peerdns` 时把单引号包进值里（存成带引号的 `'0'`）的隐患，去掉内层引号
- 静态IP分配「完整IPv6地址」字段强制仅允许 ULA（fd/fc 开头）：公网 GUA（2000::/3，如 2408）随运营商前缀重拨变化、SLAAC 后缀随机，设为静态必失效，校验直接拒绝并引导改用 hostid 后缀；在线客户端 IPv6 列新增「动态公网 / ULA」性质标注，避免把动态公网误认为静态绑定
- 上网设置页面顺序调整为 **WAN上网方式 → IPv6获取分发 → LAN口地址 → WAN-DNS → LAN-DNS → dnsmasq → 操作**（CBI 每 Map 绑定单一配置，拆成 4 个 Map 按序渲染，应用按钮逐一提交各 cursor）；关闭各 Map 默认「保存/保存并应用」按钮（`pageaction=false`），全页仅保留一个「应用配置」，消除重复提交入口
- 修复拦截明细面板文字看不清：明细容器误用深色日志样式（`netmanager-log` 浅灰字）导致表头浅底浅字，改为白底深色字表格

### v1.8.5 (2026-11-20)

**新增：拦截明细查看与一键拉黑、静态IP解绑；修复：离线目标 IPv6 放行未正确添加；调整：DNS 自动备份保留 3 份**

- 端口访问日志「防火墙拦截统计(按端口)」支持点击任意行查看被拦截源 IP 明细（源IP/协议/命中端口/次数/最近时间），并可一键拉黑。china_input/china6_input 新增限速日志（`NM_DROP4/NM_DROP6` 前缀，10 条/分钟 burst 20，不影响丢包裁决），后端 `block_detail` 解析 logread 按源 IP 聚合，前端明细面板复用 `blacklist_add` 拉黑
- 静态IP分配在线客户端速览：已绑定设备新增「解绑」按钮（后端 `static_unbind` 按 MAC 降序下标删除 dhcp host，避免多条移位误删，删除后重载 dnsmasq）
- 修复端口转发选 IPv4+IPv6 且目标主机离线/无 IPv6 时「IPv6 没正确添加」：旧版仅在 IPv6 解析成功时登记跟踪锚点，解析失败时放行规则永久「未限定目标」且 `port_sync_v6` 无法自动修正。改为无论解析成功与否都登记 v6track 锚点，主机上线后定时同步自动改写 dest_ip 到正确主机
- DNS 应用前自动备份由保留最近 5 份改为 3 份（`dnssettings-auto-*`，按修改时间排序清理）
- 核实拦截计数无重复累加：解析总和等于各独立 nft 规则计数器之和（china_input 与 china_forward 不叠加，fw4 与 netmanager 表不同优先级丢不同包），白名单 5569 条 CIDR 正常加载；计数增长为公网 IP 被境外扫描的真实累计流量

### v1.8.4 (2026-11-20)

**新增：IPv6 获取与分发模式管理；修复：拦截计数误报、CBI 页面布局；完善：静态IP一键绑定**

- 上网设置新增「IPv6 获取与分发」：WAN 前缀请求长度（PD，auto/60/56/64/不请求）+ LAN 分发模式（服务器状态化 / SLAAC 无状态 / 中继 / 关闭）。写入 iStoreOS 原生网络管理同一套 `dhcp.lan` / `network.wan6` 配置，两边互通；应用脚本不再硬写 `ra/dhcpv6=server`，改为按所选模式生效，中继模式自动配置 wan6 master，前缀长度变化自动重新协商 wan6
- 修复「端口访问日志」累计拦截计数明显错误：旧版 awk 用 `prev_pkts/prev_dport/prev_proto` 跨行借用上下文，把前面 accept 规则（如 Allow-DHCP-Renew 的 udp dport 68）的端口/协议/计数错误套到无端口的 drop 规则（china/ban IP 段拦截）上，出现「端口68拦截几万」的误报。重写为逐行独立解析，计数器/端口/协议只取本行，无端口规则按用途标注（境外IP拦截/黑名单/WAN口丢弃），多协议 `{tcp,udp}` 正确识别
- 修复「上网设置」「静态IP分配」两个 CBI 页面布局与其他菜单不一致：注入标题栏 + 导航 + 单一白卡内容区，页标题/描述移到导航下方，主题头与自绘页面一致；整体移动 cbi-map（保留 form）不破坏表单提交
- 完善静态IP设置：在线客户端速览新增「一键绑定」（创建 dhcp host，含 MAC 校验/去重/IPv4 网段与路由IP 校验）；IPv4 静态地址增加 LAN 网段校验；菜单「静态IPv6分配」更名「静态IP分配」（页面实际管理 IPv4+IPv6）

### v1.8.3 (2026-11-20)

**修正：IPv6 跟踪目标应选 SLAAC 地址，而非 hostid 静态锚点**

- 问题：v6_resolve_target 原先最优先返回「前缀 + hostid」拼出的静态地址（如 `...::3`），但目标主机对外通信实际用的是 SLAAC /64 地址（如 Debian 的 mngtmpaddr `...:17aa:e56e:f552:cdbd`），部分服务只监听/回应该地址
- 解析优先级改为：邻居表中该主机 MAC 在当前前缀下的 SLAAC 地址（排除 hostid 静态地址与 FAILED/INCOMPLETE 死条目，REACHABLE 优先，近似目标机 `grep -v deprecated` 的选址）→ hostid 静态地址兜底 → DHCPv6 租约 → 邻居表任意全局地址
- 修正 hostid 冒号形式拼接：`::3` 与 `/64` 前缀拼接不再产生三冒号非法地址
- SLAAC 临时地址轮换由既有 hotplug / 每 10 分钟 cron 同步自动跟随

### v1.8.2 (2026-11-20)

**新增：收敛客户端 IPv6 地址堆积（路由端根因治理）**

- 问题：odhcpd 按 RFC9096 把历史前缀记在 piofolder，并在每次 RA 中以 `lifetime=0` 持续广播（实测旧前缀失效两小时后仍在播）。客户端按 RFC4862 必须保留这些 deprecated 地址直到记忆过期，表现为"一台设备堆一堆旧前缀 IP"
- 新增 `v6_cleanup_piofolder`：同步时剔除 piofolder 中既非当前前缀、也非 ULA 的条目，重启 odhcpd 后 RA 只含当前前缀 + ULA
- 挂入 `port_sync_v6`（hotplug / 每 10 分钟 cron / DNS 应用三条触发路径自动生效）；DNS 应用脚本改为无条件同步，未登记跟踪也清理
- 建议配合缩短租期：`dhcp.lan.ra_lifetime='1800'`、`max_valid_lifetime='30m'`、`max_preferred_lifetime='15m'`（选项名以 odhcpd 源码 config.c 为准；`ra_valid`/`ra_preferred` 不存在，写了会被忽略），前缀变更后客户端收敛更快；ULA 是否保留由用户按需决定（关闭后 LAN IPv6 DNS 需改用稳定后缀的公网地址）

### v1.8.1 (2026-11-20)

**修复：SSH 自愈判据错误，导致每次 lan ifup 都无谓重启 dropbear**

- v1.8.0 用本机 TCP 自连（`nc 127.0.0.1 <port>`）判断 dropbear 监听是否失效。但 dropbear 设了 `DirectInterface` 后以 `SO_BINDTODEVICE` 绑在该接口上，而本机连自身地址走回环路由，**无论用回环还是 LAN IP 都连不通**——探测恒失败，于是每次 lan ifup 都会重启 dropbear 并踢掉在线会话
- 改为比对绑定网卡的 `ifindex` 是否变化（`/sys/class/net/<dev>/ifindex`），这才是套接字失效的真实判据；首次观测只记录基线、不重启
- DNS 应用路径移除该探测：应用走 `network reload` 不重建 br-lan，本就无需重启 dropbear

**修复：改了 LAN IPv6 DNS 后 RA 仍播旧值**

- 应用脚本在 odhcpd 只有单实例时仅调 `/etc/init.d/odhcpd start`，而服务已在运行时 procd 的 start 是空操作、**不会重读配置**。实测 `dhcp.lan.dns` 已更新，抓包看到的 RDNSS 却仍是旧地址
- 改为无条件 stop + killall + start，强制重读；抓包复验 RDNSS 与配置一致

### v1.8.0 (2026-11-19)

**新增：IPv6 转发目标动态跟踪**

- 问题：运营商 PD 前缀会变化（实测一天内变更多次），IPv6 放行规则里写死的 `dest_ip` 前缀一变即失效；且旧逻辑在「仅 IPv6」模式下会把 IPv4 默认目标（如 `192.168.31.3`）直接写进 `family=ipv6` 的规则，属非法地址，导致整条规则不生效——实测 5 条 IPv6 放行规则全部没有 `dest_ip`，等于对整个内网开放端口
- 新增锚点跟踪机制：为规则登记目标主机的内网 IPv4 / MAC / 主机名作为锚点，由 `v6_resolve_target` 实时解析其当前公网 IPv6。解析优先级为 **DHCP 静态 hostid（前缀+固定后缀，最稳）→ DHCPv6 租约（按 DUID）→ 邻居表（按 MAC）**
- 新增命令 `port_track_v6 <端口> <tcp|udp> <锚点|off>` 与 `port_sync_v6 [--quiet]`
- 「仅 IPv6」添加规则时自动把 IPv4 目标解析为 IPv6 并登记跟踪；解析不到则不写 `dest_ip` 并明确告警，不再写入非法地址
- 端口转发页 IPv6 表格新增「目标地址」「跟踪锚点」两列，未限定目标的规则标红提示；提供「跟踪」与「立即同步」按钮
- 新增 hotplug `96-netmanager-v6sync`：WAN 上线后自动同步；同步时顺带清理旧前缀残留的源路由与 unreachable 条目

**修复：DNS 页面配置与实际生效不一致**

- `dnssettings.wan` 节存在但 DNS 选项缺失时，页面显示默认值而 `network.wan` 实际无 `dns`、`peerdns` 未设置（走运营商 DNS），二者不符。现在应用前自动回填缺失项（优先沿用 `network` 现值），CBI 初始化也补齐单个缺失选项而非仅判断节是否存在
- 新增 `noresolv` 开关：dnsmasq 默认除转发列表外还并用系统 resolv 上游（运营商下发、wan6 自动获取、LAN 接口 DNS），使「全局转发」名不副实。开启后严格只用转发列表
- DNS 设置页新增「当前实际生效的 DNS」只读面板，直接展示运行时 dnsmasq 转发列表、系统 resolv 上游（首页数据来源）与下发给内网设备的 DNS，并标注 noresolv 状态，便于与首页对照

**修复：应用 DNS 配置导致管理 SSH 中断**

- dropbear 若以 `DirectInterface` 绑定 br-lan，`network restart` 重建 br-lan 后监听套接字绑定的 ifindex 失效，表现为端口仍 LISTEN 但连接被 refused。DNS 应用改用 `network reload`，并在应用后自检 SSH 监听、异常时自动重启 dropbear
- 新增 hotplug 在 lan ifup 时做同样的 SSH 监听自检自愈

**修复：odhcpd 重复实例**

- 实测存在 `odhcpd -v` 与 `/usr/sbin/odhcpd` 两个实例并存，同时写 RFC9096 piofile 造成前缀记忆互相覆盖、RA 广播不一致。应用脚本改为先收敛实例再统一拉起，并回显实例数

**修复：WAN DNS 输入框在页面上根本不渲染**

- 问题：WAN 四个 DNS 选项使用 `o:depends("peerdns", "0")`，而 iStoreOS 24.10 的 CBI 对 Flag「等于 0」的依赖判定不成立，服务端直接省略这些选项——页面上看不到也无法配置 WAN DNS，只能沿用默认值，与实际生效的运营商 DNS 长期不一致（LAN 侧用的是 `="1"`，因此正常）
- 改为始终显示这四项，并在说明中标注「仅在未勾选『使用运营商下发的 DNS』时生效」
- `pcdata` 优先走 `luci.xml`，避免旧路径打印弃用告警污染页面输出

**修复：端口转发表混入不该出现的条目**

- IPv6 表此前会把系统自带规则（`Allow-DHCPv6`、`Allow-MLD`、`Allow-ICMPv6-*`）一并列出，标红「未限定目标」并提供删除按钮，误删会直接断 IPv6。现在只列出 `dest=lan` 的放行规则，系统规则天然被过滤
- `family=ipv6` 的端口映射此前混在 IPv4 表里，目标地址显示为 IPv6，且与同端口的 IPv4 条目共用按「端口+协议」匹配的编辑/删除，存在误删对方的风险。现在独立成「IPv6 端口映射 (DNAT)」表

**新增：IPv6 端口映射同样跟随前缀**

- 跟踪引擎此前只覆盖 `firewall rule`（放行），`family=ipv6` 的 `redirect`（DNAT）不在其列，前缀一变即失效。现在同步时按 `src_dport` 匹配并改写其 `dest_ip`，内部端口保持不变
- 实测修复了两条指向旧前缀临时地址、已失效的 IPv6 DNS 映射

### v1.7.3 (2026-11-19)

**修复：IPv6 白名单 forward 链缺少控制面放行，NDP/DHCPv6 relay 场景仍会误杀**

- 问题：v1.7.2 只在 `china6_input` 链补了放行（`fe80::/10`、`ff00::/8`、DHCPv6 546/547），`china6_forward` 链**一条放行规则都没有**，只有 `ip6 saddr != @china_v6 drop`。开启 NDP relay（`dhcp.wan.ndp='relay'`）或 DHCPv6 relay（`dhcp.wan.dhcpv6='relay'`）时，从 WAN 侧返回的邻居发现包与中继应答源地址同样是链路本地 `fe80::`，会被判成境外地址丢弃，导致 LAN 设备地址解析失败、DHCPv6 中继拿不到地址
- IPv6 修复：`china6_forward` 在 drop 之前补齐三条放行——`ip6 saddr fe80::/10`、`ip6 saddr ff00::/8`、`udp sport 547 udp dport 546`
- IPv4 同步加固：`china_forward` 补齐 `udp sport 67 udp dport 68` 与 `ip saddr 169.254.0.0/16`，覆盖 DHCP relay（LAN 设备经路由器向运营商续租）场景
- 已启用用户升级后会自动重应用规则，无需重新下载 IP 库

**修复：PPPoE 场景下 wan6 绑定物理网口导致 PD 前缀拿不到**

- 问题：`network.wan6.device` 与 `network.wan` 绑在同一物理网口时，DHCPv6 客户端在该口上没有可用的 IPv6 出口地址，`SOLICIT`/`RS` 发不出去（syslog 报 `Failed to send SOLICIT message to ff02::1:2 (Address not available)`），PD 前缀续租失败 → 前缀到期撤销 → 局域网设备全部丢失公网 IPv6。此时 `ifstatus wan6` 的 `ipv6-prefix` 为空，而 LAN 仍靠旧租约（`valid_lft` 倒计时）残着，到期即彻底断网
- 修复：「应用配置」时增加一致性校验——`wan.proto=pppoe` 且 `wan6.device == wan.device` 时自动改为 `@wan`（指向 PPPoE 逻辑接口），随后自动 `ifup wan6` 重新协商，并在日志中回显 PD 获取结果
- 排查提示：怀疑 IPv6 断流时按顺序核查 `ifstatus wan6` 的 `ipv6-prefix` 是否为空、`ip -6 addr show <LAN 设备>` 的 `valid_lft` 是否在倒计时、`logread | grep odhcp6c` 是否出现 `Address not available`

### v1.7.2 (2026-11-19)

**修复：开启中国 IPv6 白名单后 LAN 设备丢失公网 IPv6**

- 原因：白名单 drop 规则覆盖全部 TCP/UDP，DHCPv6-PD 应答源地址为链路本地 `fe80::`，不在 `china_v6` 公网集合中，被误判为境外地址丢弃；PD 续租失败后前缀到期撤销，LAN 设备拿不到/续不上公网 IPv6
- IPv6 修复：在 drop 规则之前新增放行规则
  - `ip6 saddr fe80::/10`（链路本地）
  - `ip6 saddr ff00::/8`（多播）
  - `udp sport 547 udp dport 546`（DHCPv6 服务端应答）
- IPv4 同步加固：在 drop 之前放行 `udp sport 67 udp dport 68`（DHCPv4 应答）与 `169.254.0.0/16`（链路本地）
- 已启用用户升级后会自动重应用规则，无需重新下载 IP 库

### v1.7.1 (2026-11-19)

**修复：手动黑名单添加 IPv6 地址被误判为 IPv4**

- `blacklist add/del` 入参清洗由 `tr -d '[:space:]'` 改为 `tr -d ' \t\r\n'`。部分 BusyBox 的 tr 不识别 POSIX 字符类，会把 `[:space:]` 按字面字符解析，连冒号与 `s/p/a/c/e` 等字母一起删除，导致 `2001:550:9005:e000::13` 被吞成 `2001550900500013` 后误报「非法 IPv4 地址」
- 该问题仅影响 iStoreOS/BusyBox 环境下的手动黑名单增删命令，IPv6 白名单订阅不受影响

### v1.7.0 (2026-11-19)

**新增：中国 IPv6 白名单订阅 + IPv4/IPv6 手动黑名单（支持网段）**

**① 中国 IPv6 访问限制（参考 IPv4 白名单实现）**
- 独立 nft 表 `inet netmanager6`：`china_v6` interval 集合 + `china6_input`/`china6_forward` 两条 base chain(priority -50)
- 规则 `iifname {wan} ct state new {tcp,udp} ip6 saddr != @china_v6 counter drop`，仅拦截境外 IPv6 新建 TCP/UDP 连接
- 默认订阅 `https://ispip.clang.cn/all_cn_ipv6.txt`（中国大陆全部 IPv6 地址段，国内可直连），支持自定义订阅链接与 cron 更新计划
- 下载后严格过滤为合法 IPv6 CIDR（BOM/CR/注释/空行自动清理），条数过少拒绝保存，防止空列表误杀
- 与 IPv4 版本相同的 nft 兼容策略：modern(`flags interval, auto-merge` 分片加载) / compat(`flags interval` 单次原子加载 + 逐行回退)
- 开机 init + WAN hotplug 自愈；`netmanager china6_filter status|enable|disable|update|set_url|set_cron`
- 设置页新增「中国IPv6访问限制」区块，与 IPv4 区块并列独立开关

**② 手动黑名单（IPv4 / IPv6，支持单 IP 与 CIDR 网段）**
- 独立 nft 表 `inet netmanager_ban`，`ban_v4`/`ban_v6` 两个 interval 集合，支持 `1.2.3.4`、`1.2.3.0/24`、`2001:db8::1`、`2001:db8::/32`
- input/forward 两条 base chain 分别以 `ip saddr @ban_v4 drop`、`ip6 saddr @ban_v6 drop` 丢弃入站与转发流量
- 条目持久化到 `/etc/netmanager/blacklist_v4.list`、`/etc/netmanager/blacklist_v6.list`，重启/WAN 重连自动恢复
- 格式校验：IPv4 校验每段 0-255 且拒绝前导零，IPv6 校验分组数量/位数/前缀长度（0-32 / 0-128）
- 设置页新增「手动黑名单」区块：输入框一键添加、条目徽标逐个删除、IPv4/IPv6 分别清空
- 命令行 `netmanager blacklist list|add <ip/cidr>|del <ip/cidr>|clear [v4|v6|all]|apply`

**③ 其他**
- WAN 设备探测同时参考 IPv4/IPv6 默认路由，纯 IPv6 上联场景也能正确安装规则
- 卸载流程清理 `inet netmanager6`、`inet netmanager_ban` 与两类 cron 任务
- 热插拔脚本改为「任一过滤启用或存在黑名单条目」即恢复规则

### v1.6.1 (2026-09-05)

**功能重构：DNS设置模块升级为「上网设置」，新增WAN口上网方式 + LAN口地址设置，备份功能统一管理**

**① 模块改名与扩展**
- 原「DNS设置」模块改名为**「上网设置」**（菜单/导航/页面标题同步更新）
- 页面从单一 DNS 配置扩展为三大区块：WAN 口上网方式 + LAN 口地址 + DNS 设置
- 参考小米路由器上网设置交互，统一在一个页面管理路由器上网相关配置

**② 新增 WAN 口上网方式设置**
- 支持三种上网方式：**PPPoE 拨号** / **DHCP 自动获取** / **静态 IP**
- PPPoE 模式：账号、密码输入框（密码字段隐藏显示）
- 静态 IP 模式：IP 地址、子网掩码、网关、WAN 口 DNS（支持多个，DynamicList）
- 上网方式切换时自动显示/隐藏对应字段（depends 联动）
- 绑定 `/etc/config/network` 的 wan 接口

**③ 新增 LAN 口地址设置**
- LAN 口 IP 地址、子网掩码配置
- 绑定 `/etc/config/network` 的 lan 接口
- 修改后需用新地址重新登录管理页面（页面有提示）

**④ DNS 设置保留并优化**
- WAN 口上游 DNS（运营商下发 / 自定义 IPv4+IPv6）
- LAN 口设备 DNS（强制下发 / 路由器缓存）
- dnsmasq 全局转发（DynamicList 支持多个 DNS）
- 自动初始化：配置文件为空时自动创建默认配置，确保表单正常渲染

**⑤ 备份功能统一管理**
- 移除「上网设置」页面的「备份当前系统配置」按钮
- 所有备份功能统一由「设置 → 备份管理」模块管理（全配置备份/恢复/删除/导入/清理）
- 应用配置时仍自动备份到 `/root/backup/`（防误操作回滚）

**⑥ 应用配置统一生效**
- 「应用配置」按钮同时保存 network（WAN/LAN口）和 dnssettings（DNS）配置
- 执行 `dnssettings-apply.sh` 应用 DNS 配置
- 重启 network 服务使 WAN/LAN 口设置生效
- 成功/失败结果显示在页面顶部消息栏

### v1.4.9 (2026-09-05)

**紧急修复：v1.4.8 两处回归导致插件完全不可用**

- **修复全部页面 API 调用失败 `r.text is not a function`**：v1.4.6 引入的 `nmFetch` 兼容层内部已 `.then(res => res.text())` 返回**字符串**，但全部 30+ 处调用方仍按原生 fetch 习惯写 `.then(r => r.text())`，对字符串调用 `.text()` 报 `is not a function`，导致系统概览/端口转发/规则/日志/设置/在线更新/中国IP过滤**所有页面数据加载全部失败**。现 `nmFetch` 改为返回 Response 对象（与原生 fetch 一致），调用方零改动即可正常工作
- **修复 DNS设置 / 静态IPv6 页面 Runtime error 崩溃**：v1.4.8 修复 `cbi_nav.htm` 注释语法时，注释内容中包含了 `%>` 字符（用于说明正确/错误语法），LuCI 模板解析器在注释块内扫描到 `%>` 即**提前结束注释**，后续内容被当 Lua 代码解析报 `unexpected symbol near '-'`；现注释内容改写为不含 `%>` 组合的描述，两个 CBI 页面恢复正常

### v1.4.8 (2026-09-05)

**紧急修复：v1.4.7 两处线上崩溃回归**

- **修复 DNS 设置 / 静态 IPv6 页面 Runtime error 崩溃**：`cbi_nav.htm` 文件头部误用 JSP 风格注释 `<%-- --%>`，LuCI 模板解析器不支持该语法（`<%` 后遇单个 `-` 报 `unexpected symbol near '-'`），导致两个 CBI 页面加载即崩溃；现改为 LuCI 标准注释 `<%# %>`
- **修复 CSRF Token 在 ucode 版 LuCI 上仍可能全部 403**：v1.4.7 视图端改用框架模板变量 `<%=token%>`，但部分 ucode LuCI 版本的 include 子模板（common_head.htm）上下文中 `token` 变量未传递，导致 `CSRF_TOKEN` 恒为空字符串；现改为在 common_head.htm 内联 Lua 代码直接从 `luci.dispatcher.context.authtoken` 取值（与控制器 `csrf_token()` 完全同源），不再依赖模板变量传递链

### v1.4.7 (2026-09-04)

**紧急修复：v1.4.6 CSRF 机制在 ucode 版 LuCI 上全部 API 403 的回归**

- **修复 CSRF Token 全量失效**：v1.4.6 的 token 由 `luci.dispatcher.context.session.id` 派生——**ucode 版 LuCI（iStoreOS 24.10）的 context 没有 `session` 字段**（会话 ID 实际存于 `context.authsession`，框架内建 CSRF token 存于 `context.authtoken`），导致 token 恒为空、`csrf_check` fail-closed 将**所有 API 请求拒绝 403**（页面可打开但全部数据加载失败）。现改为直接使用 **LuCI 内建 `authtoken`**（与 CBI 表单 token 同源，由分发器为每个已认证会话生成），视图端同步改用框架模板变量 `<%=token%>`，不再 require 控制器模块
- **修复旧版 DNS 页签 404**：v1.4.5 书签/浏览器缓存指向的 `dns_apply`/`dns_backup` GET 路由已被删除；现恢复为**安全重定向**（仅跳转到 DNS 设置页，不执行脚本，不复活"刷新即重复执行"问题）
- **CBI 操作按钮防御加固**：「应用配置」「备份配置」与静态 IPv6「保存并应用」的脚本执行/条目合并环节以 `pcall` 包裹，异常不再中断整个请求，错误文本透传到页面消息（便于精确反馈问题）

### v1.4.6 (2026-09-04)

**安全加固（阶段一 P0 全量落地）**

- **新增 CSRF Token 校验**：API 此前仅强制 POST，跨站恶意页面仍可构造自动提交的 `<form method=POST>` 携带登录 cookie 触发卸载/关闭过滤等危险操作；现每个请求必须携带由会话派生的 token（`csrf_token`，视图渲染时注入 `common_head.htm`，`apiFetch`/`nmFetch` 自动附带），跨站页面无法获得 → 返回 403；无 token 的 curl 直接调用被拒绝
- **在线更新 sha256 供应链校验**：CI 为 Release 生成 `.tar.gz.sha256` 校验资产，`update_apply` 下载后自动校验 sha256（GitHub 账号被入侵/镜像劫持注入恶意包时拦截并放弃更新）；旧版本 Release 无校验资产时 warn 跳过（向后兼容）
- **镜像域名白名单**：`set_update_mirror` 与已保存镜像均须通过域名白名单校验（拒绝裸 IP/localhost/非白名单域名），防镜像前缀被注入指向攻击者服务器
- **上传文件权限收紧**：上传的插件包/配置文件统一 `chmod 600`（其他本地用户不可读）
- **卸载保留登录会话**：卸载不再删除 `/tmp/luci-sessions`（此前会踢掉所有登录用户导致看不到卸载结果页），仅清 LuCI 页面缓存
- **XSS 补漏 3 处**：中国IP过滤状态单元格（上次更新时间/CIDR条数/WAN设备名）、备份列表文件名（并改数组下标传参杜绝 onclick 注入）、修复 `restoreBackup`/`deleteBackup` 的自由文本入 onclick
- **multipart 上传加固**：50MB 大小上限（超限即丢弃，防 /tmp tmpfs OOM）；临时文件名加时间戳+随机数（防同秒并发上传互相覆盖）
- **logger 控制字符过滤**：DNS 应用脚本写入 syslog 前剔除控制字符（防日志注入转义序列）

**功能与逻辑修复**

- **DNS 应用按钮 POST 化**：`dns_apply`/`dns_backup` 由独立 GET 路由并入 `api_handler` 的 POST action（此前浏览器刷新页面即重复执行应用/备份）；CBI「应用配置」按钮直接执行脚本并显示成功/失败结果（alert 消息，含退出码）
- **DNS 应用脚本 WAN 接口自动探测**：不再硬编码 `network.wan`/`network.wan6`，按「用户显式配置（`wan_iface`/`wan6_iface`）→ 默认路由反查 → 兜底 wan/wan6」三级探测；`pppoe-wan` 等自定义接口名可正确写入
- **PPPoE 双栈 fallback 去重**：IPv6 DNS 并入 `wan.dns` 前先 delete 全量重写（修复重复应用配置时 `add_list` 逐次累积导致 DNS 列表无限增长）
- **`dhcp_option` list 化**：改为 `delete + add_list` 正确写法（UCI 中是 list 类型，旧 `uci set` 单值写法在多实例残留时行为未定义）
- **静态 IPv6 分配页**：
  - 重复 MAC 条目合并改为「页面只检测提示、点保存才真正合并」（此前每次打开页面 GET 刷新即静默 commit 修改 `/etc/config/dhcp`）
  - DUID 自动捕获排除「MAC 原文型」与「01+MAC 硬件型」伪 DUID（此前会被误存为 DUID 导致绑定错乱）
  - 在线设备 WAN 侧过滤覆盖 `pppoe-wan`/`pppoe-wan6` 等 PPPoE 接口命名（此前仅匹配 `wan` 前缀，PPPoE 拨号对端会被误列为 LAN 设备）
  - `odhcpd` 改为按需重启（仅本次有实际改动才 restart，无改动保存不再重置 IPv6 租约）；CBI 页面注入页内导航（修复从自绘页面进入后页签消失）
- **控制器健壮性**：`arg()` 空参数包装函数提取为模块级（原 4 处重复定义）；DNS 动作单次调用同时捕获输出与退出码（`__RC__` 标记法，脚本失败不再静默当成功）

**工程化**

- **CI 语法门禁**：打包前强制 `sh -n`（6 个 shell 脚本）+ `luac -p`（全部 Lua 文件）语法检查，失败即终止流水线；打包后 `tar tzf` 产物预检
- **仓库补齐 LICENSE 文件**（README 早已声明 MIT）

### v1.4.5 (2026-09-04)

**DNS 应用脚本重写（修复空值断网 + 防护体系）**

- **修复空值断网（核心）**：`peerdns=0`（自定义 DNS 模式）但 DNS 字段全空时，旧脚本仍写入 `peerdns='0'` 却不写任何 DNS → 路由器失去全部上游解析直接断网；现该场景**拒绝写入该接口并保持现状**，日志输出 `WARN: ... 跳过（防止断网）` 提示（WAN IPv4 / WAN6 IPv6 / LAN IPv4 / LAN IPv6 四处全部防护）
- **应用前自动备份**：每次「应用配置」自动备份 `network`/`dhcp`/`dnssettings` 三配置到 `/root/backup/dnssettings-auto-*.tar.gz`，仅保留最近 5 份自动备份防堆积（此前备份是独立按钮，用户容易忘按）
- **修复 list 字段错误写法**：`network.wan.dns` / `network.wan6.dns` / `dhcp.lan.dns` 在 UCI 中是 list 类型，旧脚本 `uci set dns="a b"` 是错误写法（会产生含空格的单元素）；现改为 `delete 残留 + 逐个 add_list` 正确写法，切换配置不再残留旧值
- **修复"关闭"不生效**：dnsmasq 全局转发关闭时、LAN 不强制下发时，旧脚本不清除旧 `server`/`dhcp_option`/`dns` 列表 → 关闭后旧 DNS 仍残留下发；现全部清除使关闭真正生效
- **修复无效的 `dns6` 字段**：PPPoE 双栈 fallback 旧脚本写 `network.wan.dns6`——UCI network 无此字段，netifd 不识别等于没设；现改为并入 `network.wan.dns` list（netifd 自动按协议区分）
- **`network restart` 改 `reload`**：应用 DNS 不再重建网络接口，PPPoE 不重拨、LAN 不断网；odhcpd 保持 restart（RA 配置变更需重启进程）
- **输出可观测**：`dns_apply`/`dns_backup` 接口改为捕获脚本完整输出回传页面（含全部 WARN 防护提示），DNS 设置页顶部新增防护行为说明文案

### v1.4.4 (2026-09-04)

**安全修复**

- **修复上传文件名路径穿越**：`upload_file` 的 `filename` 参数此前可传 `../../etc/xxx` 之类值让 root 写任意路径；现拒绝路径分隔符并强制 `basename`，base64 解码与复制全部失败时明确报错（此前静默失败）
- **修复插件包 tar 路径穿越（RCE 链）**：BusyBox tar 解压不剥离 `../` 成员，恶意/被劫持的插件包可覆盖系统任意文件；`plugin_update` / `plugin_version` 解压前新增成员预检（`tar tzf` 列表校验，拒绝 `../` 段与绝对路径成员）
- **修复 SSH 登录日志存储型 XSS**：攻击者可控制的 SSH 用户名/来源 IP 此前直接拼 innerHTML；现在所有字段（用户名/IP/原因/时间）写入前全部 HTML 转义，分节解析改按行首标记匹配
- **前端全量输出转义**：新增公共 `escapeHtml()`（common_head.htm），全部 25 处命令结果 `+ data +` 拼接及各表格单元格动态内容均改为转义后输出；`editRule`/`editPort` 改为数组下标传参，杜绝 UCI 自由文本注入 onclick
- **API 强制 POST**：控制器 `api_handler` 拒绝非 POST 请求（返回 405），阻断 `<img src="...?action=uninstall">` 类跨站 GET 触发

**逻辑修复**

- **修复 `rule_add` 覆盖最后一条规则**：`uci set firewall.@rule[-1].xxx` 不会创建节点，此前所有新增规则字段全部落到最后一条既有规则上（覆盖破坏）；现先 `uci add firewall rule` 再 set
- **修复端口转发编辑跨 IP 版本切换规则凭空消失**：`port_edit` 从 IPv4 切到 IPv6（或反向）此前只删旧规则不建新规则；现删除后按新参数补建完整的 DNAT redirect / IPv6 放行 rule
- **修复 fw4 空 proto 语义错误**：fw4 中 `proto` 缺省 = tcp+udp（both）而非 tcp；新增 `proto_match` 匹配函数，端口删除/编辑的查重不再误将 both 条目当成 tcp 处理（此前 `port_del 8080 tcp` 会误删 both 条目）
- **修复 IPv6 放行范围过宽**：`port_add` IPv6 分支此前缺 `dest_ip`，放行整个 LAN 网段而非目标单机；现与 IPv4 DNAT 语义对称，仅放行到指定目标
- **修复规则遍历提前截断**：以 `name` 字段存在性作为 redirect/rule 遍历终止判据（8 处）会漏掉系统自带的无名规则；改用 `uci -q get firewall.@xxx[$idx]` 节点存在性判断
- **`port_edit` 协议归一**：`both` 输入自动转为 fw4 合法单值 `tcpudp`

### v1.4.3 (2026-09-04)

- **修复静态 IP 分配模块：在线客户端识别补全 IPv6**。旧版仅读 `/tmp/dhcp.leases` 与 ARP 表（纯 IPv4），现在交叉关联 4 个数据源：dnsmasq 租约（IPv4/主机名/clientid）、`/proc/net/arp`（静态设备）、odhcpd 租约（DUID/DHCPv6 地址）、`ip -6 neigh` NDP 邻居表（**覆盖 SLAAC 隐私地址**）
- 「当前在线IP」列同时显示 IPv4 + 全部全局 IPv6 + 在线捕获的 DUID；租约存在不再误判为在线（以 ARP 完成态 / NDP 邻居为准）
- **新增「在线客户端」速览区**：列出所有在线设备（含未绑定设备）的 MAC / 主机名 / IPv4 / IPv6 / 绑定状态，可直接复制 MAC 到下方新增绑定
- **修复幽灵条目**：MAC 与 DUID 均为空的条目在保存时自动清理；此前只填部分字段的条目会从列表消失但残留在 UCI 中，无法再编辑删除
- **修复 hostid 冲突检测快照失效**：改为实时遍历 UCI 查重，同一批提交的 MAC / IPv4 / 完整 IPv6 / hostid 互相冲突均可拦截；新增 IPv4 与完整 IPv6 地址查重（旧版完全没有）
- **DUID 改为可编辑**：自动去冒号规范化存储（odhcpd `unheximize` 仅认无冒号 hex，带冒号会解析错乱）；支持 MAC+DUID 至少填其一的 IPv6-only 绑定
- ARP / NDP 过滤 WAN 侧条目（上游网关不再混入设备列表）；dnsmasq 由 restart 改为 reload，保存后 DNS 不再短暂中断

### v1.4.2 (2026-09-04)

- **修复：端口转发支持外部端口与内部端口不一致映射**（如外部 80 → 内部 8080）。此前后端将 `dest_port` 硬编码为外部端口，内外只能同端口
- 页面「添加端口转发」与「编辑」表单新增**内部端口**输入框，留空则与外部端口一致（兼容旧用法）
- 命令行 `port_add` / `port_edit` 新增可选内部端口参数（置于末位，旧命令行为不变）
- 内部端口格式校验：仅允许数字或横线范围（`8080` / `1000-2000`），冒号自动转横线
- IPv6 放行规则不受影响（放行无 DNAT，端口不变）；命中数统计仍按外部端口计数

### v1.4.1 (2026-09-03)

- **新增「在线更新」功能**：设置页新增「在线更新」区块，一键从 GitHub Releases（`District1655/luci-app-netmanager`）检查并安装最新版
- **检查两级容错**：优先 GitHub API + `jsonfilter` 解析最新 tag 与资产 URL；API 不可达时自动降级用 `/releases/latest` 的 302 Location 头解析 tag（无需 API，直连受限场景仍可用）
- **`netmanager update_apply`**：自动下载最新 `luci-app-netmanager-install_*.tar.gz`（wget / uclient-fetch / curl 依次兜底），下载后做**大小校验 + tar 完整性预检**（杜绝半截包/错误页进入安装），再复用 plugin_update 流程安装（解压 + install.sh + 延迟重启 uhttpd）
- **镜像加速可配置**：`netmanager set_update_mirror <url>` 或设置页输入框，检查与下载 URL 均自动拼接加速前缀（如 `https://gh-proxy.com`），应对 GitHub 直连受限
- **语义化版本比较**：major.minor.patch 数值比较，仅提示升级不误报降级；版本号统一收敛到后端 `PLUGIN_VERSION` 变量（`netmanager version` / 在线更新共用）
- UI：设置页显示当前版本/最新版本/更新状态，检查与更新按钮带禁用态与结果展示

### v1.4.0 (2026-09-02)

- **合并 luci-app-dnssettings (v1.2.1)**：新增「DNS设置」「静态IPv6分配」两个子页面（CBI 标准表单），统一入口到「网络管理」菜单
- DNS 配置 `/etc/config/dnssettings` 与应用/备份脚本独立保留，老用户已有配置无损保留
- 原 `fwmanager` 全部命令/配置/路径统一更名为 `netmanager`（命令 `netmanager`、配置 `/etc/config/netmanager`、日志 `/tmp/netmanager/`、nft 表 `inet netmanager`、CIDR 目录 `/etc/netmanager/`）
- `netmanager uninstall` 卸载流程增加 DNS 模块清理（CBI 模型 / dnssettings 配置 / apply-backup 脚本）
- install.sh 扩展为 7 步安装（新增 DNS 脚本、CBI 模型、dnssettings 配置）

### 继承自 luci-app-fwmanager v1.3.33

- 中国 IPv4 访问限制（独立 nft 表 / 旧版 nft 自动降级 / 订阅与 cron 自定义 / init + hotplug 自愈）
- 一键卸载插件、运行日志排错、配置备份恢复、插件在线更新、性能优化（nft dstnat 链缓存）


```

### 5.32 docs/istore-publish.md

- **用途**：iStore 上架与自动发版说明：一次性 Secret 配置、日常发版流程、本地出包、常见问题
- **规模**：51 行
- **维护要点**：与 README「构建与发版」章节互补，改动流水线时两边同步

````markdown
# 自动发版：Release → 构建 ipk/apk → 自动提 PR 到 iStore

## 它做了什么

`push main`（改 README 里的版本号）→ 原有 `Build Install Package` 打 tag、发 Release（tar.gz 安装包，body 从 `docs/CHANGELOG.md` 提取）
→ `Publish to iStore`（本流程）被 Release 触发，会：

1. 校验 `files/usr/sbin/netmanager` 里的 `PLUGIN_VERSION` 与发布版本一致，不一致直接失败（避免发出去的包版本对不上）
2. `tools/build_ipk.py` 打出 `luci-app-netmanager_<ver>-r<rel>_all.ipk`（opkg / 24.10 及更早）
3. `tools/build_apk.sh` 用官方 `openwrt-sdk-mini-25.12.2` 的 `apk mkpkg` 打出 `luci-app-netmanager-<ver>-r<rel>.apk`（25.12）
4. 两个包自动上传到对应的 Release 资产
5. `tools/publish_istore.sh` 向官方仓库提两个 PR：
   - `istoreos/istore-repo`，base `pending`，包放到 `bin/packages/all/nas_luci/` 与 `bin/apks/all/nas_luci/`
   - `istoreos/openwrt-app-meta`，base `main`，更新 `applications/app-meta-netmanager/`（版本号取自 `istore/app-meta/Makefile` 模板）

合并进 `pending` 后，官方 CI 会自动销旧包、重建索引并同步到 `repo.istoreos.com`，用户侧几分钟后即可在软件中心看到。

## 一次性配置

1. 建一个 PAT（Classic token，勾 `repo` 权限；或 Fine-grained 勾两个 fork 的 `Contents: Read and write` + `Pull requests: Read and write`）
2. 仓库 `Settings → Secrets and variables → Actions → New repository secret`
   - 名称：`ISTORE_TOKEN`
   - 值：上面那个 PAT
3. 没配 token 也能跑：只构建并挂到 Release，跳过提 PR（日志里会有提示）

## 日常发版

1. 改代码
2. 改两处版本号，保持一致：
   - `README.md` 头部的 `版本：vX.Y.Z`
   - `files/usr/sbin/netmanager` 里的 `PLUGIN_VERSION="X.Y.Z"`
3. push 到 `main`

流水线跑完，Release 里就有 tar.gz + ipk + apk，iStore 两个 PR 也已自动开好。

## 同版本重发

改了包内容但版本号不变时，手动跑 `Publish to iStore`，`release` 填 `2`、`3`…（apk 版本会变成 `X.Y.Z-r2`）。

## 只在本地出包

```bash
python3 tools/build_ipk.py --version 1.8.14 --release 1 --files files --out dist
VERSION=1.8.14 RELEASE=1 OUT=dist bash tools/build_apk.sh
```

## 常见问题

- **PR 打回**：官方只收 x86_64 / aarch64 架构；纯脚本包 `Architecture: all`（apk 是 `noarch`）没问题，带二进制要按架构分别出包
- **官方说包名冲突**：`luci-app-netmanager` 若与 OpenWrt 官方仓库重名，需改包名（如 `luci-app-nmgr`），同步改 `tools/build_*` 与 `istore/app-meta/Makefile`
- **apk 装不上**：本地验证用 `apk add --allow-untrusted xxx.apk`；进了官方 feed 后由签名索引兜底，用户侧不用加参数


````

### 5.33 .gitattributes

- **用途**：git 属性：强制文本文件 LF（路由器 BusyBox ash 不能吃 CRLF）
- **规模**：15 行
- **维护要点**：二进制文件单独标注；CRLF 警告可忽略

```text
# 强制所有文本文件使用 LF 换行
# 路由器（BusyBox ash）上的 shell 脚本必须使用 LF，CRLF 会导致 shebang 解析失败
* text=auto eol=lf

# Windows 专用文件例外
*.bat text eol=crlf
*.cmd text eol=crlf

# 二进制文件
*.png binary
*.jpg binary
*.gif binary
*.ico binary
*.tar.gz binary
*.ipk binary


```

### 5.34 .gitignore

- **用途**：忽略构建产物（dist/、ipk/apk、临时 tar.gz）；docs/source-full.md 需要入库，别加进来
- **规模**：7 行
- **维护要点**：新增构建输出目录时同步补一条

```text
# PROJECT.md 第 5/9 章生成产物（由 docs/gen_source_part.py 生成后合并入 PROJECT.md）
docs/source_part.md
# 构建产物由 CI 发布，本地不入库
*.tar.gz
*.ipk
*.apk
dist/


```

### 5.35 README.md

- **用途**：用户文档：功能 / 安装（apk·ipk·脚本三路）/ CLI / 配置说明 / 构建与发版 / 更新日志
- **规模**：415 行
- **维护要点**：L3 版本号是 build.yml 的 tag 提取源（登记处 12）；更新日志已迁到 docs/CHANGELOG.md，本文件只留最近一版摘要

````markdown
# 网络管理插件 (luci-app-netmanager)

> 版本：v1.8.17
>
> 适配：iStoreOS 25.12+（apk）/ iStoreOS 24.10 及 OpenWrt 23.05+（opkg / ipk），fw4 + nftables，Lua LuCI
>
> 交付：**apk / ipk 双格式** + iStoreOS 软件中心上架 + `tar.gz` 一键脚本兜底
>
> 由 **luci-app-fwmanager**（防火墙管理）与 **luci-app-dnssettings**（上网设置）合并而成的网络管理一体化 LuCI 插件。

一站式管理路由器网络：端口转发、防火墙规则、SSH/访问日志、中国 IPv4/IPv6 访问限制、手动黑名单、WAN/LAN 口上网方式与双栈 DNS 统一管理、静态 IP 分配（IPv4/IPv6）、配置备份恢复、插件在线更新、一键卸载。

## 安装方式速览

| 系统 | 包格式 | 安装方式 |
|------|--------|----------|
| iStoreOS 25.12+（apk-tools，无 opkg） | `.apk` | 软件中心搜「网络管理」安装，或 `apk add --allow-untrusted luci-app-netmanager-<ver>-r<rel>.apk` |
| iStoreOS 24.10 / OpenWrt 23.05–24.10（opkg） | `.ipk` | `opkg install luci-app-netmanager_<ver>-r<rel>_all.ipk` |
| 任意（含未适配架构 / 开发机） | `.tar.gz` | 解压后 `sh install.sh` 脚本安装 |

三种方式装完效果一致（菜单「网络管理」，入口 `/cgi-bin/luci/admin/netmanager`）。包均随 Release 发布，文件名带版本与 release 号。

---

## 功能模块

### 防火墙管理（原 luci-app-fwmanager）

1. **系统概览**：防火墙状态 / 端口统计 / 网络信息 / 快捷操作
2. **端口转发管理**：IPv4 / IPv6 DNAT 端口映射统一管理，支持 TCP/UDP/双协议、单端口与端口范围；「IPv6 端口放行（直连）」区独立展示直连放行规则（转发是转发，放行是放行），自动配套规则随映射增删与前缀跟随，支持启用/禁用
3. **防火墙规则管理**：自定义通信规则增删改 + 常用模板一键应用 + 源IP/目的IP 粒度列；IPv6 端口放行规则不在此页（归端口转发页「IPv6 端口放行」区）
4. **SSH 登录日志**：成功/失败记录 + 失败 IP 排行 Top 10 + 自动刷新
5. **端口访问日志**：活跃连接 / 入站出站计数 / 拦截统计
6. **中国 IPv4 访问限制**：仅允许中国大陆 IPv4 访问已开放端口，境外 IPv4 新建连接丢弃；独立 nft 表 `inet netmanager`（fw4 reload 不影响）；订阅链接与 cron 更新计划可自定义；开机 init + WAN hotplug 自愈；旧版 nft 自动降级兼容
7. **中国 IPv6 访问限制（v1.7.0 新增）**：与 IPv4 版本对称，仅允许中国大陆 IPv6 访问已开放端口；独立 nft 表 `inet netmanager6`（与 IPv4/ fw4 互不影响）；订阅链接与 cron 更新计划可自定义；默认订阅 `https://ispip.clang.cn/all_cn_ipv6.txt`；开机 init + WAN hotplug 自愈
8. **手动黑名单（v1.7.0 新增）**：支持 IPv4/IPv6 单个 IP 与 CIDR 网段（如 `1.2.3.0/24`、`2001:db8::/32`）手动拉黑，入站与转发流量直接丢弃；独立 nft 表 `inet netmanager_ban`（fw4 reload 不影响），条目持久化并开机/WAN 重连自动恢复
9. **设置**：默认目标 IP / 整插件配置备份（UCI 配置 + 黑名单/白名单列表，恢复后自动重应用规则与 cron） / 插件在线更新 / 运行日志排错 / 一键卸载

### 上网设置（原 luci-app-dnssettings，CBI 标准表单）

10. **上网设置**：
   - WAN 口上网方式：PPPoE 拨号 / DHCP 自动获取 / 静态 IP
   - LAN 口地址：LAN 口 IP 地址与子网掩码
   - IPv6 获取与分发：WAN 前缀请求长度（PD）+ LAN 分发模式（状态化 / SLAAC / 中继 / 关闭）
   - WAN 口上游 DNS：PPPoE/DHCP 拨号自定义 IPv4/IPv6 DNS，或使用运营商下发（peerdns）
   - LAN 口设备 DNS：通过 DHCP option 6 与 RA 强制下发自定义 DNS，或走路由器缓存
   - dnsmasq 全局转发：统一配置上游解析服务器
   - 配置备份：一键备份当前系统 network/dhcp 配置到 `/root/backup/`
   - 应用配置：一键写入系统并重启 network/dnsmasq/odhcpd
11. **静态 IP 分配（IPv4 + IPv6）**：基于 MAC 绑定 IPv4 地址 / hostid / ip6 / DUID，支持在线客户端一键绑定与解绑、自动合并重复条目、在线状态显示、地址与 hostid 冲突检测；公网 GUA 随运营商前缀变化，静态 IPv6 仅允许绑定 ULA 后缀

### 默认 DNS

| 类型 | 主 DNS | 备 DNS |
|------|--------|--------|
| IPv4 | 223.5.5.5 (阿里) | 119.29.29.29 (腾讯) |
| IPv6 | 2400:3200::1 (阿里) | 2402:4e00:: (腾讯) |

---

## 文件结构

```
luci-app-netmanager/
├── files/
│   ├── usr/sbin/
│   │   ├── netmanager                        # 后端核心脚本（防火墙管理，含日志/更新/备份/卸载）
│   │   ├── dnssettings-apply.sh              # 上网设置应用配置脚本（独立保留）
│   │   └── dnssettings-backup.sh             # 上网设置备份脚本（独立保留）
│   ├── usr/lib/lua/luci/
│   │   ├── controller/netmanager.lua         # LuCI 控制器（菜单+API+multipart上传+上网设置动作）
│   │   ├── model/cbi/netmanager/
│   │   │   ├── dns_settings.lua              # 上网设置 CBI 模型（绑定 /etc/config/dnssettings）
│   │   │   └── dns_staticv6.lua              # 静态 IP 分配 CBI 模型（绑定 dhcp.host）
│   │   └── view/netmanager/
│   │       ├── overview.htm                  # 系统概览
│   │       ├── port_forward.htm              # 端口转发（含「IPv6 端口放行」区）
│   │       ├── firewall_rules.htm            # 规则管理
│   │       ├── ssh_log.htm                   # SSH 日志
│   │       ├── access_log.htm                # 访问日志
│   │       ├── settings.htm                  # 设置（备份/更新/运行日志/中国IPv4/6过滤/卸载）
│   │       ├── common_head.htm               # 公共样式
│   │       ├── cbi_nav.htm                   # CBI 页面公共导航
│   │       └── nav.htm                       # 公共导航（含上网设置、静态IP分配入口）
│   ├── etc/config/
│   │   ├── netmanager                        # 防火墙模块配置
│   │   └── dnssettings                       # 上网设置模块配置（独立保留）
│   ├── etc/init.d/netmanager-china           # 中国IPv4/IPv6过滤 + 黑名单 开机自启
│   ├── etc/hotplug.d/iface/95-netmanager-china  # WAN上线重应用过滤/黑名单规则
│   └── etc/hotplug.d/iface/96-netmanager-v6sync # WAN上线同步 IPv6 转发目标跟踪
├── tools/
│   ├── build_ipk.py                          # 打 ipk（opkg 系统，tar.gz 外壳，CI/本地通用）
│   ├── build_apk.sh                          # 打 apk（iStoreOS 25.12+，用 openwrt-sdk-mini 的 apk mkpkg）
│   ├── publish_istore.sh                     # 向 istoreos/istore-repo、istoreos/openwrt-app-meta 提 PR
│   └── prune_history.sh                      # 只保留最近 10 个版本的 Tag/Release（KEEP/sort -V 可调）
├── istore/app-meta/
│   ├── Makefile                              # 软件中心卡片元数据模板（PKG_VERSION/PKG_RELEASE 由脚本注入）
│   └── logo.png                              # 软件中心图标（256×256，<50KB）
├── .github/workflows/
│   ├── build.yml                             # 打 tag + 发 Release（tar.gz + changelog 提取）
│   ├── publish-istore.yml                    # Release 后自动构建 ipk/apk + 提 PR 到 iStore 官方仓库
│   ├── prune-history.yml                     # 手动清理历史版本（可改保留数量 / 预演）
│   └── extract_changelog.awk                 # Release body 提取脚本
├── docs/
│   ├── CHANGELOG.md                          # 全部历史版本记录（Release body 的来源）
│   ├── istore-publish.md                     # iStore 上架/自动发版配置说明（一次性 Secret + 日常流程）
│   ├── source-full.md                        # 源码全录（自动生成，对应 PROJECT.md 第 5 章索引）
│   └── gen_source_part.py                    # 生成 source-full.md + PROJECT.md 第 5/9 章
├── install.sh                                # 一键安装脚本（支持 SKIP_UHTTPD_RESTART）
├── PROJECT.md                                # 维护者文档（架构/源码全录/发版流程）
└── README.md
```

---

## 安装方法

> 早期说法「iStoreOS 的 `/usr/bin` 只读所以装不了 ipk」已作废。实测真因是 **iStoreOS 25.12 起换成 apk-tools（系统里没有 opkg）**：25.12+ 只能装 apk，24.10 及更早装 ipk。两种包都由 CI 自动产出。

### 方式一：iStore 软件中心（iStoreOS 25.12+）

本插件已按 iStore 收录规范打包（纯 `all` 架构，落 `nas_luci` feed），并向上游提交了收录 PR（`istoreos/istore-repo`、`istoreos/openwrt-app-meta`）。官方合并后即可在 **iStore → 软件中心** 搜索「网络管理 / netmanager」一键安装，卡片图标与简介来自 `istore/app-meta/`。

在官方合并前，等价做法是手动安装 apk（见方式二）。

### 方式二：命令行安装包（推荐，可控版本）

在 [Releases](https://github.com/District1655/luci-app-netmanager/releases) 下载对应包，上传到路由器后执行：

```bash
# iStoreOS 25.12+ / OpenWrt 25.x（apk）
apk add --allow-untrusted luci-app-netmanager-<版本>-r<rel>.apk

# iStoreOS 24.10 / OpenWrt 23.05–24.10（opkg）
opkg install luci-app-netmanager_<版本>-r<rel>_all.ipk

# 卸载（配置会保留，加 --purge / --force-remove 才会连配置一起删）
apk del luci-app-netmanager
opkg remove luci-app-netmanager
```

安装/卸载的钩子已内置：装完自动清 LuCI 缓存、启用并启动 `netmanager-china`、reload uhttpd 重建 nft 规则；卸载时清掉 `inet netmanager` / `netmanager6` / `netmanager_ban` 三张表，`/etc/config/netmanager` 与 `/etc/config/dnssettings` 默认保留（升级时系统会生成 `.apk-new`，属 OpenWrt 配置保护行为，确认后可覆盖）。

### 方式三：一键脚本（未适配架构 / 开发态兜底）

```bash
cd /tmp
tar xzvf luci-app-netmanager-install_v<版本>.tar.gz
chmod +x install.sh
sh install.sh
```

适用于任意 OpenWrt 衍生系统（含 CI 未覆盖的架构），装完左侧菜单出现「网络管理」，浏览器 `Ctrl+Shift+R` 强制刷新。

### 在线更新

「设置」页面的「插件更新 / 在线更新」区块可直接检查并安装最新 Release（`update_check` / `update_apply`，支持镜像加速前缀）；也可上传新的 `tar.gz` 包离线更新，安装成功后延迟 3 秒自动重启 LuCI。

---

## 构建与发版

### 本地出包

```bash
# ipk（tar.gz 外壳，iStore CI 只认这种；ar 格式会被判 invalid）
python3 tools/build_ipk.py --version 1.8.14 --release 1 --files files --out dist

# apk（需要 apk-tools；脚本会自己下 openwrt-sdk-mini 取 mkpkg）
VERSION=1.8.14 RELEASE=1 FILES=files OUT=dist bash tools/build_apk.sh
```

两个脚本固定 mtime、目录 755 / 文件 644、脚本可执行位，产物可直接进 iStore 官方仓库目录结构（`bin/packages/all/nas_luci/`、`bin/apks/all/nas_luci/`）。

### 发版（push main 一条链路到底）

1. 改两处版本号：`files/usr/sbin/netmanager` 的 `PLUGIN_VERSION`（权威源，L15）与 `README.md` 头部 `> 版本：vX.Y.Z`
2. （可选）在 [`docs/CHANGELOG.md`](docs/CHANGELOG.md) 顶部手写 `### vX.Y.Z (日期)` 小节——**忘写不会阻塞发版**：CI 会按 `git log` 自动补一节（提交即带 `[skip ci]`，不会触发二次发版），Release body 照样有内容；手写的版本优先，CI 不覆盖已有段落
3. `git push origin main`
4. `build.yml`：校验两处版本一致 → `sh -n` / `luac -p` 门禁 → 打 `tar.gz` → 打 tag → 发 Release（tag 已存在则整条跳过，可手动 `workflow_dispatch` 勾 `force`）
5. `publish-istore.yml`（Release published 事件触发）：构建 `ipk` + `apk` → 上传为 Release 资产 → 自动向 `istoreos/istore-repo`（base `pending`）与 `istoreos/openwrt-app-meta`（base `main`）提 PR
6. 官方合并 `pending` 后，上游 `ci-pending.yml` 会把包 cherry-pick 到 main、删同名旧包、刷新索引，软件中心即更新
7. 发版末尾自动清理历史：`tools/prune_history.sh` 只保留版本号最高的 10 个 Tag 与 Release，更早的连 Release 带 tag 一起删（按版本号排序，不是按发布时间；`docs/CHANGELOG.md` 里的文字记录不受影响）

### 版本历史保留策略

仓库不无限堆历史版本：`build.yml` 每次发版后调用 `tools/prune_history.sh`，只留最近 10 个。想改数量或先看要删什么：

```bash
# 预演（不删任何东西）
gh workflow run prune-history.yml -f keep=10 -f dry_run=true
# 真删（如改成保留 20 个）
gh workflow run prune-history.yml -f keep=20
```

本地同样可跑（需要 `gh` 已登录）：`KEEP=10 DRY_RUN=1 bash tools/prune_history.sh`。

### 一次性配置（已配好）

仓库 `Settings → Secrets and variables → Actions` 里的 `ISTORE_TOKEN` 是一个 classic PAT（`repo` scope），用于把分支和 PR 推到两个 fork。**不配也能跑**：此时只构建并挂 Release 资产，跳过自动提 PR（日志里会有 notice 提示）。

手工重跑 / 干跑：

```bash
# 只验证构建，不提 PR（会上传 Release 资产，--clobber）
gh workflow run publish-istore.yml -f version=1.8.14 -f release=1 -f dry_run=true

# 同版本重发，换个 release 号即可（1.8.14-r2）
gh workflow run publish-istore.yml -f version=1.8.14 -f release=2
```

细节与常见问题见 [`docs/istore-publish.md`](docs/istore-publish.md)。

---

## 命令行用法

安装后可直接使用 `netmanager` 命令：

```bash
# 系统概览
netmanager overview
netmanager version              # 查看插件版本

# 端口转发
netmanager port_list
netmanager port_add <外部端口> <tcp|udp|both> <目标IP> <ipv4|ipv6|both> [内部端口]
netmanager port_del <外部端口> <协议> [ipv4|ipv6|both]
netmanager port_edit <旧端口> <旧协议> <新端口> <新协议> <目标IP> <类型> [新内部端口]

# IPv6 转发目标跟踪（v1.8.0+，前缀变化自动跟随）
netmanager port_track_v6 <端口> <tcp|udp> <锚点|off>   # 设置/清除 IPv6 跟踪锚点（MAC/主机名/IPv4）
netmanager port_sync_v6 [--quiet]                       # 立即按锚点重算并同步 IPv6 目标地址

# IPv6 网关自愈（v1.8.7+）
netmanager v6gw [--quiet]        # 补 PPPoE 缺失的 IPv6 默认路由，并强制 ra_default=1 宣告网关

# 防火墙规则
netmanager rule_list
netmanager rule_add <名称> <源> <目标> <协议> <端口> <动作> <ipv4|ipv6|any>
netmanager rule_del <索引>
netmanager rule_edit <索引> <名称> <源> <目标> <协议> <端口> <动作> <类型>
netmanager rule_toggle <索引> <1|0>        # 启用/禁用规则（v1.8.13+，端口放行区开关）

# 日志
netmanager ssh_log [条数]
netmanager access_log [筛选端口] [条数]
netmanager block_detail <端口|v4|v6>   # 查看被拦截源 IP 明细（源/协议/端口/次数/最近时间）

# 运行日志
netmanager log_set 1|0          # 开启/关闭运行日志（持久化到UCI）
netmanager log_get [行数]       # 查看最后 N 行运行日志
netmanager log_query [级别] [关键词] [行数]  # 按级别（INFO/WARN/ERROR/DEBUG）与关键词过滤查询
netmanager log_export           # 导出完整运行日志（输出 base64，供前端下载）
netmanager log_clear            # 清空运行日志

# 设置
netmanager settings
netmanager set_default_target <IP>

# 操作
netmanager restart    # 重启防火墙
netmanager reload     # 重载防火墙

# 备份管理
netmanager backup                    # 立即备份整插件配置（5 个 UCI 配置 + /etc/netmanager 黑名单/白名单列表）
netmanager backup_list               # 查看所有备份
netmanager backup_restore <文件名>   # 从备份恢复
netmanager backup_delete <文件名>    # 删除备份
netmanager backup_import <文件名>     # 将已上传的备份包导入备份目录（校验 tar.gz 与配置内容）
netmanager backup_prune [保留数]     # 清理旧备份，默认保留最近 20 份

# 插件管理
netmanager upload_file <文件名>      # 上传文件（通过stdin）
netmanager plugin_update <文件名>    # 从上传的包更新插件
netmanager plugin_version <文件名>   # 查看插件包版本信息
netmanager cleanup_uploads           # 清理临时上传文件

# 在线更新（v1.4.1+，从 GitHub Releases 自动检查下载安装）
netmanager update_check              # 检查最新版本（GitHub API → 302重定向两级容错）
netmanager update_apply              # 下载最新 release 资产并自动安装（大小+tar 完整性校验）
netmanager set_update_mirror <url>   # 设置镜像/加速前缀（空=直连），如 https://gh-proxy.com

# 中国IPv4访问限制
netmanager china_filter status                 # 查看状态
netmanager china_filter enable                 # 开启（应用规则 + 装cron + 自启）
netmanager china_filter disable                # 关闭（清规则 + 移cron，保留列表与设置）
netmanager china_filter update                 # 更新IP库并重应用规则
netmanager china_filter set_url <url>          # 自定义订阅链接
netmanager china_filter set_cron "0 4 * * *"   # 自定义更新计划cron
netmanager china_filter allow_wan on|off       # 是否放行 WAN 同网段来源（上级光猫/网关），v1.8.16+

# 中国IPv6访问限制（v1.7.0+）
netmanager china6_filter status                # 查看状态
netmanager china6_filter enable                # 开启（应用规则 + 装cron + 自启）
netmanager china6_filter disable               # 关闭（清规则 + 移cron，保留列表与设置）
netmanager china6_filter update                # 更新IPv6 IP库并重应用规则
netmanager china6_filter set_url <url>         # 自定义IPv6订阅链接
netmanager china6_filter set_cron "0 4 * * *"  # 自定义IPv6更新计划cron

# 手动黑名单（v1.7.0+，支持单IP与CIDR网段）
netmanager blacklist list                      # 查看黑名单条目与规则状态
netmanager blacklist add <IP|CIDR>             # 添加拉黑，如 1.2.3.4 / 10.0.0.0/8 / 2001:db8::/32
netmanager blacklist del <IP|CIDR>             # 移除条目
netmanager blacklist clear [v4|v6|all]         # 清空黑名单
netmanager blacklist apply                     # 重建黑名单 nft 规则

# 静态 IP 绑定（等价于页面在线客户端「一键绑定 / 解绑」）
netmanager static_bind <MAC> [IPv4] [主机名] [DUID]   # 按 MAC 创建 dhcp host 静态绑定
netmanager static_unbind <MAC>                        # 按 MAC 删除全部静态绑定条目

# 上网设置（命令行应用脚本，等价于页面「应用配置」按钮）
/usr/sbin/dnssettings-apply.sh                 # 应用 /etc/config/dnssettings 到系统
/usr/sbin/dnssettings-backup.sh                # 备份 network/dhcp 配置到 /root/backup/

# 卸载插件
netmanager uninstall                # 全删（后端/LuCI/CBI/配置/DNS配置与脚本/CIDR/init/hotplug/nft规则/cron/缓存）
netmanager uninstall keep           # 保留 /etc/config/netmanager、/etc/netmanager/ 与 /etc/config/dnssettings，其余全删
```

---

## 配置说明

### 防火墙模块：`/etc/config/netmanager`

```
config netmanager 'settings'
    option default_target '192.168.31.196'   # 默认转发目标IP
    option log_days '7'                       # 日志保留天数（预留）
    option log_enable '0'                     # 运行日志开关：0关闭 / 1开启
    option china_filter_enable '0'            # 中国IPv4过滤开关：0关闭 / 1开启
    option china_filter_url 'https://metowolf.github.io/iplist/data/special/china.txt'  # IP库订阅链接
    option china_filter_cron '0 3 * * 0'      # 更新计划cron表达式：默认每周日3点
    option china_filter_last_update ''        # 上次成功下载时间
    option china_filter_count '0'             # 当前列表CIDR条数
    option china6_filter_enable '0'           # 中国IPv6过滤开关：0关闭 / 1开启
    option china6_filter_url 'https://ispip.clang.cn/all_cn_ipv6.txt'  # IPv6 IP库订阅链接
    option china6_filter_cron '0 3 * * 0'     # IPv6 更新计划cron表达式
    option china6_filter_last_update ''       # IPv6 上次成功下载时间
    option china6_filter_count '0'            # IPv6 当前列表CIDR条数
    option update_mirror ''                    # 在线更新镜像/加速前缀（空=直连，需在白名单域名内）
```

> **手动黑名单存储**：条目持久化在 `/etc/netmanager/blacklist_v4.list` 与 `/etc/netmanager/blacklist_v6.list`（每行一个 IP 或 CIDR），无需 UCI 配置，页面增删即时生效。

### 上网设置模块：`/etc/config/dnssettings`

```
config wan 'wan'          # WAN 口上游 DNS（peerdns / dns1_v4 / dns2_v4 / dns1_v6 / dns2_v6）
config lan 'lan'          # LAN 口下发 DNS（force_dns / dns1_v4 / dns2_v4 / dns1_v6 / dns2_v6）
config dnsmasq 'dnsmasq'  # dnsmasq 全局转发（enable / forward_v4 列表 / forward_v6 列表）
config actions 'actions'  # 操作按钮占位
```

> **上网设置应用原理**：点击「应用配置」后，`dnssettings-apply.sh` 将上述配置写入 `network.wan/wan6`（peerdns/dns/dns6）、`dhcp.lan`（dhcp_option/dns/ra/dhcpv6）与 `dhcp.@dnsmasq[0].server`，然后重启 network/dnsmasq/odhcpd。局域网设备需断开重连网络才能获取新 DNS。

> **中国IPv4过滤原理**：独立 nft 表 `inet netmanager`（与 fw4 分离，fw4 reload 不影响）含 `china_v4` CIDR 集合 + input/forward 两条 base chain(priority -50)，规则 `iifname {wan} ct state new {tcp,udp} ip saddr != @china_v4 drop`。CIDR 列表存 `/etc/netmanager/china_v4.list`，开机 init + WAN 上线 hotplug 自动重应用。兼容新旧 nft：modern(`flags interval, auto-merge` 分片加载) / compat(`flags interval` 单次原子加载 + 逐行回退)。

> **中国IPv6过滤原理（v1.7.0）**：与 IPv4 完全对称，独立 nft 表 `inet netmanager6` 含 `china_v6` 集合 + `china6_input`/`china6_forward` 两条 base chain，规则 `iifname {wan} ct state new {tcp,udp} ip6 saddr != @china_v6 drop`。列表存 `/etc/netmanager/china_v6.list`，默认订阅 `https://ispip.clang.cn/all_cn_ipv6.txt`，同样支持 modern/compat 两种 nft 加载模式。

> **手动黑名单原理（v1.7.0）**：独立 nft 表 `inet netmanager_ban`，`ban_v4`/`ban_v6` 两个 interval 集合支持单 IP 与 CIDR 网段，input/forward 两条 base chain 上分别以 `ip saddr @ban_v4 drop`、`ip6 saddr @ban_v6 drop` 丢弃入站与转发流量。条目持久化在 `/etc/netmanager/blacklist_v4.list`、`blacklist_v6.list`，重启与 WAN 重连后由 init/hotplug 自动恢复。

### 中国 IP 订阅参考源

IPv6（每行一个 CIDR）：

| 源 | 地址 | 说明 |
|----|------|------|
| ispip.clang.cn（默认） | `https://ispip.clang.cn/all_cn_ipv6.txt` | 中国大陆全部 IPv6 地址段，国内直连 |
| china-operator-ip | `https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china6.txt` | 按国内运营商 ASN 自动生成，更新频繁（GitHub raw 直连受限时需镜像） |
| APNIC 原始数据 | `https://ftp.apnic.net/apnic/stats/apnic/delegated-apnic-latest` | 官方分配数据，需自行转换为 CIDR |

IPv4（每行一个 CIDR）：

| 源 | 地址 | 说明 |
|----|------|------|
| metowolf/iplist（默认） | `https://metowolf.github.io/iplist/data/special/china.txt` | 社区维护，格式与插件一致 |
| ispip.clang.cn | `https://ispip.clang.cn/all_cn.txt` | 中国大陆全部 IPv4 地址段，国内直连 |
| china-operator-ip | `https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt` | 按国内运营商 ASN 自动生成 |

---

## 卸载

- Web 界面：「设置」页面 →「卸载插件」区块（支持「保留配置」勾选）
- 命令行：`netmanager uninstall [full|keep]`

卸载会完整清理：后端脚本、LuCI 控制器/CBI 模型/视图、init/hotplug、上网设置应用与备份脚本、nft 规则、cron 任务、配置文件。用户在 `/etc/config/firewall` 中的端口转发与防火墙规则不受影响。

---

## 注意事项

1. DNS「应用配置」会重启网络服务，期间会短暂断网
2. 设备端 DNS 有缓存，重连网络后才会拿到新 DNS
3. v1.4.6+ WAN 接口自动探测（默认路由反查），自定义接口名可在 `dnssettings` 配置 `wan_iface`/`wan6_iface` 显式指定
4. DNS 备份文件保存在 `/root/backup/`，防火墙配置备份保存在 `/root/`
5. 插件在线更新只接受 `.tar.gz` / `.tgz` 安装包（`.ipk`/`.apk` 请走软件中心或 apk/opkg 命令）
6. apk 体系升级时，`/etc/config/netmanager`、`/etc/config/dnssettings` 可能落地成 `*.apk-new`（配置保护），确认新版本无误后再覆盖
7. 卸载默认保留两份 UCI 配置；要彻底清干净用 `netmanager uninstall`（full）

## 更新日志

完整历史版本记录（v1.8.17 → v1.4.0 → 继承 fwmanager v1.3.33）已归档到 **[`docs/CHANGELOG.md`](docs/CHANGELOG.md)**，`build.yml` 从那里提取当前版本段落作为 GitHub Release body。

**最近一版：v1.8.17（2026-11-27）**

- **新增手动白名单（IPv4/IPv6 双栈）**：`netmanager whitelist add 203.0.113.0/24` / `2001:db8::/32`，设置页同样有输入框与列表；实现是把条目并进 `china_v4` / `china_v6` 集合，等于给中国IP限制加一份人工允许列表（不受 china.txt 订阅更新影响）
- **持久化自愈**：条目存 `/etc/netmanager/whitelist_v4.list`、`whitelist_v6.list`，重启/WAN 重连/china 列表更新/备份恢复后都会重新并入集合；删条目立刻从集合移除
- **修复上级光猫/网关访问不到路由器**（v1.8.16 延续）：自动放行 WAN 口同网段来源，「放行上级网关」可在设置页开关

## 许可证

MIT License


````

> 第 5 章结束。以下为第 6 章起的手写章节。
