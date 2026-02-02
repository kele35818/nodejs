#!/bin/bash

# ==========================================
# VLESS + WebSocket (WS) 纯净独立版
# ==========================================

# --- 颜色定义 ---
red() { echo -e "\033[1;91m$1\033[0m"; }
green() { echo -e "\033[1;32m$1\033[0m"; }
yellow() { echo -e "\033[1;33m$1\033[0m"; }

# --- 路径定义 ---
DIR="/etc/xray_simple"
CONFIG="${DIR}/config.json"
BIN="${DIR}/xray"

# --- 检查 Root 权限 ---
[[ $EUID -ne 0 ]] && red "错误：请使用 root 用户运行此脚本！" && exit 1

# --- 工具函数 ---
check_cmd() { command -v "$1" >/dev/null 2>&1; }

# --- 获取公网 IP (用于生成链接) ---
get_ip() {
    local ip=$(curl -s4 --max-time 3 https://www.cloudflare.com/cdn-cgi/trace | grep "ip=" | cut -d= -f2)
    [ -z "$ip" ] && ip=$(curl -s6 --max-time 3 ipv6.ip.sb)
    echo "${ip:-127.0.0.1}"
}

# --- 端口开放 (兼容各种防火墙) ---
open_port() {
    local port=$1
    # iptables
    if check_cmd iptables; then 
        iptables -I INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null
    fi
    # firewalld
    if check_cmd firewall-cmd && systemctl is-active --quiet firewalld; then
        firewall-cmd --zone=public --add-port=$port/tcp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
    # ufw
    if check_cmd ufw && systemctl is-active --quiet ufw; then 
        ufw allow $port/tcp >/dev/null 2>&1
    fi
}

# --- 安装依赖 ---
install_deps() {
    yellow "正在检查并安装依赖..."
    local pkgs=("curl" "wget" "unzip" "openssl")
    if check_cmd apt; then 
        apt update -y >/dev/null 2>&1
        apt install -y "${pkgs[@]}" >/dev/null 2>&1
    elif check_cmd yum; then 
        yum install -y "${pkgs[@]}" >/dev/null 2>&1
    elif check_cmd apk; then
        apk add "${pkgs[@]}" >/dev/null 2>&1
    fi
}

# --- 主安装逻辑 ---
install_xray() {
    clear
    green "=== VLESS + WebSocket 安装向导 ==="
    
    # 1. 输入端口
    while true; do
        echo -ne "\033[1;33m请输入 VLESS 端口 (默认 8080): \033[0m"
        read -r port
        [ -z "$port" ] && port=8080
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            if lsof -i :$port >/dev/null 2>&1; then
                red "端口 $port 已被占用，请更换！"
            else
                break
            fi
        else
            red "无效端口，请输入 1-65535 之间的数字。"
        fi
    done

    # 2. 输入 UUID
    echo -ne "\033[1;33m请输入 UUID (回车随机生成): \033[0m"
    read -r uuid
    [ -z "$uuid" ] && uuid=$(cat /proc/sys/kernel/random/uuid)

    # 3. 下载核心
    mkdir -p "${DIR}"
    ARCH=$(uname -m)
    case "${ARCH}" in
        x86_64) XA="64" ;;
        aarch64|arm64) XA="arm64-v8a" ;;
        *) red "不支持的架构: $ARCH"; exit 1 ;;
    esac

    if [ ! -f "${BIN}" ]; then
        yellow "正在下载 Xray Core..."
        curl -sL "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XA}.zip" -o x.zip
        unzip -o x.zip -d "${DIR}" >/dev/null 2>&1 && rm x.zip
        chmod +x "${BIN}"
    fi

    # 4. 写入配置 (仅 VLESS+WS)
    cat > "${CONFIG}" << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$uuid" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/ws" }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

    # 5. 配置服务并启动
    if [ -f /etc/alpine-release ]; then
        # OpenRC (Alpine)
        cat > /etc/init.d/xray_simple << EOF
#!/sbin/openrc-run
description="Xray VLESS"
command="${BIN}"
command_args="run -c ${CONFIG}"
command_background=true
pidfile="/var/run/xray_simple.pid"
EOF
        chmod +x /etc/init.d/xray_simple
        rc-update add xray_simple default
        rc-service xray_simple restart
    else
        # Systemd (Debian/Ubuntu/CentOS)
        cat > /etc/systemd/system/xray_simple.service << EOF
[Unit]
Description=Xray VLESS Service
After=network.target
[Service]
ExecStart=${BIN} run -c ${CONFIG}
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable xray_simple
        systemctl restart xray_simple
    fi

    # 6. 放行防火墙
    open_port "$port"

    # 7. 显示结果
    check_status "$port" "$uuid"
}

check_status() {
    local port=$1
    local uuid=$2
    local ip=$(get_ip)
    
    sleep 2
    if pgrep -f "${BIN}" >/dev/null; then
        clear
        green "=========================================="
        green "       VLESS + WS 安装成功！"
        green "=========================================="
        echo ""
        echo -e "地址 (IP):   ${green}$ip${0m}"
        echo -e "端口 (Port): ${green}$port${0m}"
        echo -e "用户 ID:     ${green}$uuid${0m}"
        echo -e "传输协议:    ${green}ws${0m}"
        echo -e "路径 (Path): ${green}/ws${0m}"
        echo ""
        
        # 生成 VLESS 链接
        local link="vless://${uuid}@${ip}:${port}?encryption=none&security=none&type=ws&path=%2Fws#VLESS_WS_${ip}"
        echo -e "=== 分享链接 (复制导入) ==="
        yellow "$link"
        echo ""
    else
        red "安装失败，服务未启动。请检查日志。"
    fi
}

install_deps
install_xray
