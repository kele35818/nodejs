#!/bin/bash

# ==========================================
# VLESS + WebSocket (WS) 修复版
# ==========================================

# --- 颜色定义 (修复变量问题) ---
RED="\033[1;91m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RESET="\033[0m"

# --- 路径定义 ---
DIR="/etc/xray_simple"
CONFIG="${DIR}/config.json"
BIN="${DIR}/xray"

# --- 检查 Root 权限 ---
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：请使用 root 用户运行此脚本！${RESET}" && exit 1

# --- 工具函数 ---
check_cmd() { command -v "$1" >/dev/null 2>&1; }

# --- 获取公网 IP ---
get_ip() {
    local ip=$(curl -s4 --max-time 3 https://www.cloudflare.com/cdn-cgi/trace | grep "ip=" | cut -d= -f2)
    [ -z "$ip" ] && ip=$(curl -s6 --max-time 3 ipv6.ip.sb)
    echo "${ip:-127.0.0.1}"
}

# --- 端口开放 ---
open_port() {
    local port=$1
    if check_cmd iptables; then iptables -I INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null; fi
    if check_cmd firewall-cmd && systemctl is-active --quiet firewalld; then
        firewall-cmd --zone=public --add-port=$port/tcp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
    if check_cmd ufw && systemctl is-active --quiet ufw; then ufw allow $port/tcp >/dev/null 2>&1; fi
}

# --- 安装依赖 ---
install_deps() {
    echo -e "${YELLOW}正在检查并安装依赖...${RESET}"
    local pkgs=("curl" "wget" "unzip" "openssl")
    if check_cmd apt; then apt update -y >/dev/null 2>&1 && apt install -y "${pkgs[@]}" >/dev/null 2>&1;
    elif check_cmd yum; then yum install -y "${pkgs[@]}" >/dev/null 2>&1;
    elif check_cmd apk; then apk add "${pkgs[@]}" >/dev/null 2>&1; fi
}

# --- 主安装逻辑 ---
install_xray() {
    clear
    echo -e "${GREEN}=== VLESS + WebSocket 安装向导 ===${RESET}"
    
    # 1. 输入端口 (关键步骤)
    while true; do
        echo -e "${YELLOW}请输入 VLESS 内部端口 (NAT机器请填映射后的内部端口，如 9999): ${RESET}"
        read -r port
        [ -z "$port" ] && port=8080
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
             break
        else
            echo -e "${RED}无效端口，请输入 1-65535 之间的数字。${RESET}"
        fi
    done

    # 2. 输入 UUID
    echo -ne "${YELLOW}请输入 UUID (回车随机生成): ${RESET}"
    read -r uuid
    [ -z "$uuid" ] && uuid=$(cat /proc/sys/kernel/random/uuid)

    # 3. 下载核心
    mkdir -p "${DIR}"
    ARCH=$(uname -m)
    case "${ARCH}" in
        x86_64) XA="64" ;;
        aarch64|arm64) XA="arm64-v8a" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${RESET}"; exit 1 ;;
    esac

    if [ ! -f "${BIN}" ]; then
        echo -e "${YELLOW}正在下载 Xray Core...${RESET}"
        curl -sL "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XA}.zip" -o x.zip
        unzip -o x.zip -d "${DIR}" >/dev/null 2>&1 && rm x.zip
        chmod +x "${BIN}"
    fi

    # 4. 写入配置
    cat > "${CONFIG}" << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $port,
      "protocol": "vless",
      "settings": { "clients": [ { "id": "$uuid" } ], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/ws" } }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

    # 5. 配置服务并启动
    if [ -f /etc/alpine-release ]; then
        cat > /etc/init.d/xray_simple << EOF
#!/sbin/openrc-run
description="Xray VLESS"; command="${BIN}"; command_args="run -c ${CONFIG}"
command_background=true; pidfile="/var/run/xray_simple.pid"
EOF
        chmod +x /etc/init.d/xray_simple
        rc-update add xray_simple default; rc-service xray_simple restart
    else
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
        systemctl daemon-reload; systemctl enable xray_simple; systemctl restart xray_simple
    fi

    open_port "$port"
    check_status "$port" "$uuid"
}

check_status() {
    local port=$1
    local uuid=$2
    local ip=$(get_ip)
    
    sleep 2
    if pgrep -f "${BIN}" >/dev/null; then
        clear
        echo -e "${GREEN}==========================================${RESET}"
        echo -e "${GREEN}       VLESS + WS 安装成功！${RESET}"
        echo -e "${GREEN}==========================================${RESET}"
        echo ""
        echo -e "地址 (IP):   ${GREEN}$ip${RESET}"
        echo -e "内部端口:    ${GREEN}$port${RESET} (VPS内监听)"
        echo -e "用户 ID:     ${GREEN}$uuid${RESET}"
        echo -e "传输协议:    ${GREEN}ws${RESET}"
        echo -e "路径 (Path): ${GREEN}/ws${RESET}"
        echo ""
        echo -e "${YELLOW}注意：如果你是 NAT VPS，客户端连接时：${RESET}"
        echo -e "1. 地址填：${GREEN}$ip${RESET}"
        echo -e "2. 端口填：${GREEN}公网映射端口 (例如 12570)${RESET}"
        echo -e "3. UUID/路径保持一致"
        echo ""
    else
        echo -e "${RED}安装失败，服务未启动。${RESET}"
    fi
}

install_deps
install_xray
