#!/bin/bash
set -e

#================================================================================
# 常量和全局变量
#================================================================================
VERSION="1.2.0-LB"
SCRIPT_URL="https://raw.githubusercontent.com/hkfires/onekey-tun2socks/main/onekey-tun2socks.sh"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# 备用 DNS64 服务器
ALTERNATE_DNS64_SERVERS=(
    "2a00:1098:2b::1"
    "2a01:4f8:c2c:123f::1"
    "2a01:4f9:c010:3f02::1"
    "2001:67c:2b0::4"
    "2001:67c:2b0::6"
)

# 脚本操作的全局变量
ACTION=""
MODE="alice" 

#================================================================================
# 工具函数
#================================================================================
info() { echo -e "${BLUE}[信息]${NC} $1"; }
success() { echo -e "${GREEN}[成功]${NC} $1"; }
warning() { echo -e "${YELLOW}[警告]${NC} $1"; }
error() { echo -e "${RED}[错误]${NC} $1"; }
step() { echo -e "${PURPLE}[步骤]${NC} $1"; }

require_root() {
    if [ "$EUID" -ne 0 ]; then
        error "请使用 root 权限运行此脚本。"
        exit 1
    fi
}

#================================================================================
# 负载均衡器配置 (HAProxy)
#================================================================================
setup_haproxy_lb() {
    step "正在配置 HAProxy 8 端口负载均衡..."
    
    # 1. 安装 HAProxy
    if ! command -v haproxy &>/dev/null; then
        info "正在安装 HAProxy..."
        if [ -f /etc/debian_version ]; then
            apt-get update && apt-get install -y haproxy
        elif [ -f /etc/redhat-release ]; then
            yum install -y haproxy
        else
            error "不支持的操作系统，请手动安装 haproxy。"
            exit 1
        fi
    fi

    # 2. 写入负载均衡配置
    # 监听本地 10000 端口，分发到 10001-10008
    cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    maxconn 4096
    user haproxy
    group haproxy
    daemon

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 5s
    timeout client 1m
    timeout server 1m

frontend socks_in
    bind 127.0.0.1:10000
    default_backend socks_out

backend socks_out
    balance roundrobin
    # 台湾家宽 8 端口后端配置
    server tw1 [2a14:67c0:116::1]:10001 check inter 2000 rise 2 fall 3
    server tw2 [2a14:67c0:116::1]:10002 check inter 2000 rise 2 fall 3
    server tw3 [2a14:67c0:116::1]:10003 check inter 2000 rise 2 fall 3
    server tw4 [2a14:67c0:116::1]:10004 check inter 2000 rise 2 fall 3
    server tw5 [2a14:67c0:116::1]:10005 check inter 2000 rise 2 fall 3
    server tw6 [2a14:67c0:116::1]:10006 check inter 2000 rise 2 fall 3
    server tw7 [2a14:67c0:116::1]:10007 check inter 2000 rise 2 fall 3
    server tw8 [2a14:67c0:116::1]:10008 check inter 2000 rise 2 fall 3
EOF

    systemctl restart haproxy
    systemctl enable haproxy
    success "HAProxy 负载均衡已就绪 (127.0.0.1:10000)"
}

#================================================================================
# 核心逻辑 (基于原脚本修改)
#================================================================================

# 复用原脚本的 DNS 和下载逻辑...
test_github_access() { curl -s -m 10 https://github.com >/dev/null; }

set_dns64_servers() {
    local resolv_conf=$1
    step "设置临时 DNS64 以支持下载..."
    echo "nameserver 2602:fc59:b0:9e::64" > "$resolv_conf"
    if test_github_access; then return 0; fi
    for dns in "${ALTERNATE_DNS64_SERVERS[@]}"; do
        echo "nameserver $dns" > "$resolv_conf"
        if test_github_access; then return 0; fi
    done
    return 1
}

cleanup_ip_rules() {
    step "清理残留 IP 规则..."
    ip rule del fwmark 438 lookup main pref 10 2>/dev/null || true
    ip -6 rule del fwmark 438 lookup main pref 10 2>/dev/null || true
    ip route del default dev tun0 table 20 2>/dev/null || true
    ip rule del lookup 20 pref 20 2>/dev/null || true
    while ip rule del pref 15 2>/dev/null; do :; done
    ip rule del to 127.0.0.0/8 lookup main pref 16 2>/dev/null || true
    ip rule del to 10.0.0.0/8 lookup main pref 16 2>/dev/null || true
    ip rule del to 172.16.0.0/12 lookup main pref 16 2>/dev/null || true
    ip rule del to 192.168.0.0/16 lookup main pref 16 2>/dev/null || true
}

uninstall_tun2socks() {
    cleanup_ip_rules
    systemctl stop tun2socks haproxy 2>/dev/null || true
    systemctl disable tun2socks haproxy 2>/dev/null || true
    rm -f /etc/systemd/system/tun2socks.service /usr/local/bin/tun2socks
    rm -rf /etc/tun2socks
    success "卸载完成，HAProxy 已同步停止。"
}

install_tun2socks() {
    cleanup_ip_rules
    RESOLV_CONF="/etc/resolv.conf"
    RESOLV_BAK="/etc/resolv.conf.bak"
    cp "$RESOLV_CONF" "$RESOLV_BAK"
    
    if ! set_dns64_servers "$RESOLV_CONF"; then
        error "网络不可达，无法下载组件。"
        mv "$RESOLV_BAK" "$RESOLV_CONF"
        exit 1
    fi

    # 下载二进制文件
    DOWNLOAD_URL=$(curl -s https://api.github.com/repos/heiher/hev-socks5-tunnel/releases/latest | grep "browser_download_url" | grep "linux-x86_64" | cut -d '"' -f 4)
    curl -L -o /usr/local/bin/tun2socks "$DOWNLOAD_URL"
    chmod +x /usr/local/bin/tun2socks
    mv "$RESOLV_BAK" "$RESOLV_CONF"

    # 配置模式
    mkdir -p /etc/tun2socks
    if [ "$MODE" = "alice" ]; then
        setup_haproxy_lb
        cat > /etc/tun2socks/config.yaml <<EOF
tunnel:
  name: tun0
  mtu: 8500
  multi-queue: true
  ipv4: 198.18.0.1
socks5:
  port: 10000
  address: '127.0.0.1'
  udp: 'udp'
  username: 'alice'
  password: 'alicefofo123..OVO'
  mark: 438
EOF
    else
        error "当前 LB 增强版仅支持 Alice 模式。其他模式请使用原版脚本。"
        exit 1
    fi

    # 生成 Systemd 服务 (复用原脚本路由逻辑)
    MAIN_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
    cat > /etc/systemd/system/tun2socks.service <<EOF
[Unit]
Description=Tun2Socks LB Service
After=network.target haproxy.service

[Service]
Type=simple
ExecStart=/usr/local/bin/tun2socks /etc/tun2socks/config.yaml
ExecStartPost=/bin/sleep 1
ExecStartPost=/sbin/ip rule add fwmark 438 lookup main pref 10
ExecStartPost=/sbin/ip -6 rule add fwmark 438 lookup main pref 10
ExecStartPost=/sbin/ip route add default dev tun0 table 20
ExecStartPost=/sbin/ip rule add lookup 20 pref 20
ExecStartPost=/sbin/ip rule add from $MAIN_IP lookup main pref 15
ExecStartPost=/sbin/ip rule add to 127.0.0.0/8 lookup main pref 16
ExecStartPost=/sbin/ip rule add to 10.0.0.0/8 lookup main pref 16
ExecStartPost=/sbin/ip rule add to 172.16.0.0/12 lookup main pref 16
ExecStartPost=/sbin/ip rule add to 192.168.0.0/16 lookup main pref 16

ExecStop=/sbin/ip rule del fwmark 438 lookup main pref 10
ExecStop=/sbin/ip -6 rule del fwmark 438 lookup main pref 10
ExecStop=/sbin/ip route del default dev tun0 table 20
ExecStop=/sbin/ip rule del lookup 20 pref 20
ExecStop=/sbin/ip rule del from $MAIN_IP lookup main pref 15
ExecStop=/sbin/ip rule del to 127.0.0.0/8 lookup main pref 16
ExecStop=/sbin/ip rule del to 10.0.0.0/8 lookup main pref 16
ExecStop=/sbin/ip rule del to 172.16.0.0/12 lookup main pref 16
ExecStop=/sbin/ip rule del to 192.168.0.0/16 lookup main pref 16
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable tun2socks
    systemctl start tun2socks
    success "负载均衡版安装完成！流量将自动分发至 8 个台湾出口。"
}

#================================================================================
# 主程序入口
#================================================================================
main() {
    require_root
    case "$1" in
        -i|--install) install_tun2socks ;;
        -r|--remove)  uninstall_tun2socks ;;
        *) echo "使用方法: $0 {-i|-r}"; exit 1 ;;
    esac
}

main "$@"
