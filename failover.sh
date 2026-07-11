#!/bin/sh
# ==========================================================
# 主/备路由自动切换脚本（OpenWrt）
# 功能：
#   - 检测主路由(192.168.1.1)是否存活
#   - 主路由离线 -> 启用备用线路：拨号WAN、WireGuard、daed、ddns-go、本机DHCP
#   - 主路由恢复 -> 关闭备用线路，并重启LAN口，让局域网设备
#                   重新走DHCP发现流程，拿到主路由分配的地址
#   - 开机启动时会先真实探测一次主路由状态，再决定初始动作，
#     不会想当然地假设主路由一定在线或离线
# 用法：
# 实际监控脚本的完整路径，按需修改
# "/etc/storage/scripts/failover.sh"配合failover文件使用
#   service failover enable    # 设置开机自启
#   service failover start     # 启动
#   service failover stop      # 停止
#   service failover restart   # 重启
#   service failover status    # 查看运行状态
#   logread -e failover -f     # 实时看日志
# ==========================================================

# === 配置区域 ===
MAIN_ROUTE="192.168.1.1"       # 主路由IP（用于探测存活）
INTERFACE="wan"                 # 本机WAN接口(uci网络配置名)
WG_INTERFACE="WireGuard"        # WireGuard接口(uci网络配置名)
LAN_INTERFACE="lan"             # LAN接口(uci网络配置名)
LAN_PHY_IF="eth0"               # br-lan桥接的物理接口，用于强制断链逼客户端重新DHCP
CHECK_INTERVAL=5                # 检测间隔(秒)
FAIL_THRESHOLD=3                # 连续失败多少次才判定主路由离线(防抖)
RECOVER_THRESHOLD=2             # 连续成功多少次才判定主路由恢复(防抖)
INIT_PROBE_COUNT=3              # 开机启动时，先探测几次来判断初始真实状态
LOCK_FILE="/var/run/failover.lock"
LOG_TAG="failover"
# ================

# --- 防止脚本重复运行 ---
if [ -f "$LOCK_FILE" ]; then
    OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        logger -t "$LOG_TAG" "脚本已在运行 (PID $OLD_PID)，本次启动退出"
        exit 1
    fi
fi
echo "$$" > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"; exit 0' INT TERM EXIT

log() {
    logger -t "$LOG_TAG" "$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1"
}

# --- 探测主路由是否存活 ---
check_main_alive() {
    ping -c 1 -W 1 "$MAIN_ROUTE" >/dev/null 2>&1
}

# --- 强制刷新LAN物理链路，逼客户端重新走DHCP流程 ---
# 因为主/备网关IP不同(192.168.1.1 / 192.168.1.3)，客户端必须
# 真正重新获取一次DHCP租约才能拿到新网关，仅靠软件层ifdown/ifup
# 桥接口不一定会让物理链路真断，所以这里直接操作物理口。
flap_lan_link() {
    log "刷新LAN物理链路(${LAN_PHY_IF})，逼客户端重新DHCP"

    # 清空DHCP租约表，避免下发旧租约信息
    [ -f /tmp/dhcp.leases ] && : > /tmp/dhcp.leases

    # 直接拉闸物理口，让接在LAN口上的设备真正掉线重连
    ip link set "$LAN_PHY_IF" down
    sleep 2
    ip link set "$LAN_PHY_IF" up

    # 顺带重启协议层，确保netifd状态和网络栈同步刷新
    /sbin/ifdown "$LAN_INTERFACE" >/dev/null 2>&1
    sleep 1
    /sbin/ifup "$LAN_INTERFACE" >/dev/null 2>&1

    log "LAN物理链路刷新完成"
}

# --- 启用备用线路（主路由离线时） ---
enable_backup() {
    log "主路由离线，启用备用线路：DHCP + WAN拨号 + WireGuard + daed + ddns-go"

    # 删掉lan接口上指向主路由的网关/DNS配置，避免和自己WAN的默认路由冲突
    uci -q delete network.lan.gateway
    uci -q delete network.lan.dns
    uci commit network

    uci set dhcp.lan.ignore='0'
    uci commit dhcp
    /etc/init.d/dnsmasq restart

    /sbin/ifup "$INTERFACE"

    # 等待WAN真正获取到地址，而不是固定sleep（最多等30秒）
    i=0
    while [ "$i" -lt 30 ]; do
        WAN_IP=$(ubus call network.interface."$INTERFACE" status 2>/dev/null \
                 | grep -o '"address":"[^"]*"' | head -n1 | cut -d'"' -f4)
        [ -n "$WAN_IP" ] && break
        sleep 1
        i=$((i+1))
    done
    if [ -n "$WAN_IP" ]; then
        log "WAN已获取地址: $WAN_IP"
    else
        log "警告：等待30秒后WAN仍未获取到地址，继续尝试启动WireGuard"
    fi

    /sbin/ifup "$WG_INTERFACE"
    /etc/init.d/daed start
    /etc/init.d/ddns-go start

    flap_lan_link

    log "备用线路启用完成"
}

# --- 关闭备用线路（主路由恢复时） ---
disable_backup() {
    log "主路由已恢复，关闭备用线路：WireGuard + daed + ddns-go + WAN + DHCP，并重启LAN口"

    /sbin/ifdown "$WG_INTERFACE"
    /etc/init.d/daed stop
    /etc/init.d/ddns-go stop
    /sbin/ifdown "$INTERFACE"

    uci set dhcp.lan.ignore='1'
    uci commit dhcp
    /etc/init.d/dnsmasq restart
    /etc/init.d/firewall restart

    # 给lan接口配置网关/DNS指向主路由，让本机自身也能联网
    # (netifd在flap_lan_link里ifup lan时会自动应用，加默认路由+写resolv.conf.auto)
    uci set network.lan.gateway="$MAIN_ROUTE"
    uci set network.lan.dns="$MAIN_ROUTE"
    uci commit network

    log "已配置lan网关和DNS，本机将经主路由(${MAIN_ROUTE})联网"

    flap_lan_link

    log "备用线路已关闭"
}

# ==========================================================
# 初始化：开机启动时，先真实探测几次主路由状态，
# 再决定第一次到底该跑 enable_backup() 还是 disable_backup()，
# 不再无条件假设开机时主路由一定在线或离线。
# ==========================================================
log "脚本启动，开始探测主路由初始状态..."

INIT_OK=0
i=0
while [ "$i" -lt "$INIT_PROBE_COUNT" ]; do
    if check_main_alive; then
        INIT_OK=$((INIT_OK+1))
    fi
    i=$((i+1))
    sleep 1
done

if [ "$INIT_OK" -ge 2 ]; then
    # 3次里至少2次成功，判定主路由当前在线
    log "初始探测结果：主路由在线 (${INIT_OK}/${INIT_PROBE_COUNT})，按主路由在线状态初始化"
    disable_backup
    STATE="MAIN_ALIVE"
else
    # 主路由离线或探测结果不明确，保守起见按离线处理，主动接管
    log "初始探测结果：主路由离线或不稳定 (${INIT_OK}/${INIT_PROBE_COUNT})，按主路由离线状态初始化，主动接管"
    enable_backup
    STATE="MAIN_DEAD"
fi

log "初始化完成，进入监测循环 (检测间隔 ${CHECK_INTERVAL}s)，当前状态: $STATE"

FAIL_COUNT=0
OK_COUNT=0

while true; do
    if check_main_alive; then
        OK_COUNT=$((OK_COUNT+1))
        FAIL_COUNT=0
    else
        FAIL_COUNT=$((FAIL_COUNT+1))
        OK_COUNT=0
    fi

    if [ "$STATE" = "MAIN_DEAD" ] && [ "$OK_COUNT" -ge "$RECOVER_THRESHOLD" ]; then
        disable_backup
        STATE="MAIN_ALIVE"
        OK_COUNT=0
        FAIL_COUNT=0
    elif [ "$STATE" = "MAIN_ALIVE" ] && [ "$FAIL_COUNT" -ge "$FAIL_THRESHOLD" ]; then
        enable_backup
        STATE="MAIN_DEAD"
        OK_COUNT=0
        FAIL_COUNT=0
    fi

    sleep "$CHECK_INTERVAL"
done
