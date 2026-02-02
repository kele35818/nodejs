#!/bin/bash

# ==========================================
# VLESS + WebSocket (WS) 最终版 (带卸载)
# ==========================================

# --- 定义颜色变量 (防止报错) ---
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# --- 路径定义 ---
DIR="/etc/xray_simple"
CONFIG="${DIR}/config.json"
BIN="${DIR}/xray"
SERVICE_NAME="xray_simple"

# --- 检查 Root 权限 ---
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：请使用 root 用户运行此脚本！${PLAIN}" && exit 1

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
    echo -e "${YELLOW}正在检查并安装依赖...${PLAIN}"
    local pkgs=("curl" "wget" "unzip" "openssl")
    if check_cmd apt; then apt update -y >/dev/null 2>&1 && apt install -y "${pkgs[@]}" >/dev/null 2>&1;
    elif check_cmd yum; then yum install -y "${pkgs[@]}" >/dev/null 2>&1;
    elif check_cmd apk; then apk add "${pkgs[@]}" >/dev/null 2>&1; fi
}

# --- 安装核心逻辑 ---
install_xray() {
    install_deps
    clear
    echo -e "${GREEN}=== VLESS + WebSocket 安装向导 ===${PLAIN}"
    
    # 1. 输入端口
    while true; do
        echo -e "${YELLOW}请输入 VLESS 内部端口 (NAT机器请填映射后的内部端口，如 9999): ${PLAIN}"
        read -r port
        [ -z "$port" ] && port=8080
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
             break
        else
            echo -e "${RED}无效端口，请输入 1-65535 之间的数字。${PLAIN}"
        fi
    done

    # 2. 输入 UUID
    echo -ne "${YELLOW}请输入 UUID (回车随机生成): ${PLAIN}"
    read -r uuid
    [ -z "$uuid" ] && uuid=$(cat /proc/sys/kernel/random/uuid)

    # 3. 下载核心
    mkdir -p "${DIR}"
    ARCH=$(uname -m)
    case "${ARCH}" in
        x86_64) XA="64" ;;
        aarch64|arm64) XA="arm64-v8a" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
    esac

    if [ ! -f "${BIN}" ]; then
        echo -e "${YELLOW}正在下载 Xray Core...${PLAIN}"
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

    # 5. 配置服务
    if [ -f /etc/alpine-release ]; then
        cat > /etc/init.d/${SERVICE_NAME} << EOF
#!/sbin/openrc-run
description="Xray VLESS"; command="${BIN}"; command_args="run -c ${CONFIG}"
command_background=true; pidfile="/var/run/${SERVICE_NAME}.pid"
EOF
        chmod +x /etc/init.d/${SERVICE_NAME}
        rc-update add ${SERVICE_NAME} default; rc-service ${SERVICE_NAME} restart
    else
        cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=Xray VLESS Service
After=network.target
[Service]
ExecStart=${BIN} run -c ${CONFIG}
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload; systemctl enable ${SERVICE_NAME}; systemctl restart ${SERVICE_NAME}
    fi

    open_port "$port"
    
    # 6. 显示结果
    local ip=$(get_ip)
    sleep 2
    if pgrep -f "${BIN}" >/dev/null; then
        clear
        echo -e "${GREEN}==========================================${PLAIN}"
        echo -e "${GREEN}       VLESS + WS 安装成功！${PLAIN}"
        echo -e "${GREEN}==========================================${PLAIN}"
        echo ""
        echo -e "地址 (IP):   ${GREEN}$ip${PLAIN}"
        echo -e "内部端口:    ${GREEN}$port${PLAIN} (VPS监听)"
        echo -e "UUID:        ${GREEN}$uuid${PLAIN}"
        echo -e "流控 (Flow): 空 (不填)"
        echo -e "协议 (Type): ${GREEN}ws${PLAIN}"
        echo -e "路径 (Path): ${GREEN}/ws${PLAIN}"
        echo ""
        echo -e "${YELLOW}--- 客户端(v2rayN/Shadowrocket)填写指南 ---${PLAIN}"
        echo -e "如果你是 NAT VPS，请注意："
        echo -e "1. 地址(address) 填：${GREEN}$ip${PLAIN}"
        echo -e "2. 端口(port)    填：${GREEN}公网端口 (例如 12570)${PLAIN}"
        echo -e "3. UUID 和 路径  填：上面的信息"
        echo ""
        # 生成标准分享链接
        # 注意：链接里的端口是内部端口，复制后需要在客户端里手动改成公网端口
        local link="vless://${uuid}@${ip}:${port}?encryption=none&security=none&type=ws&path=%2Fws#VLESS_Internal_Port"
        echo -e "分享链接 (注意修改端口):"
        echo -e "${PLAIN}$link${PLAIN}"
        echo ""
    else
        echo -e "${RED}安装失败，服务未启动。${PLAIN}"
    fi
}

# --- 卸载逻辑 ---
uninstall_xray() {
    echo -e "${YELLOW}正在停止并卸载服务...${PLAIN}"
    if [ -f /etc/alpine-release ]; then
        rc-service ${SERVICE_NAME} stop 2>/dev/null
        rc-update del ${SERVICE_NAME} default 2>/dev/null
        rm /etc/init.d/${SERVICE_NAME} 2>/dev/null
    else
        systemctl stop ${SERVICE_NAME} 2>/dev/null
        systemctl disable ${SERVICE_NAME} 2>/dev/null
        rm /etc/systemd/system/${SERVICE_NAME}.service 2>/dev/null
        systemctl daemon-reload
    fi
    rm -rf "${DIR}"
    echo -e "${GREEN}卸载完成！所有相关文件已删除。${PLAIN}"
}

# --- 主菜单 ---
clear
echo -e "${GREEN}=== VLESS 简易管理脚本 ===${PLAIN}"
echo -e "1. 安装 / 重装 (Install)"
echo -e "2. 卸载 (Uninstall)"
echo -e "0. 退出 (Exit)"
echo ""
read -p "请输入选项 [0-2]: " choice

case $choice in
    1) install_xray ;;
    2) uninstall_xray ;;
    0) exit 0 ;;
    *) echo -e "${RED}无效选项${PLAIN}" ;;
esac
