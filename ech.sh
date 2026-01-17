#!/bin/bash

# =========================================================
# ECH Tunnel 一键管理脚本 (最终优化版)
# 地址：https://github.com/kele35818/nodejs
# 功能：自动安装、多实例管理、配置智能补全
# =========================================================

# --- 全局变量 ---
# 二进制文件下载地址
GITHUB_BIN_URL="https://github.com/kele35818/nodejs/raw/refs/heads/main/ech-tunnel-linux-amd64"
BIN_PATH="/usr/local/bin/ech-tunnel"
CONF_BASE_DIR="/etc/ech-tunnel"
SHORTCUT_CMD="/usr/bin/ech"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# --- 基础检查 ---
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误: 请使用 root 用户运行此脚本！${PLAIN}"
        exit 1
    fi
}

install_dependencies() {
    if ! command -v wget &> /dev/null; then
        echo -e "${YELLOW}正在安装 wget...${PLAIN}"
        if [ -x "$(command -v apt)" ]; then
            apt update && apt install -y wget
        elif [ -x "$(command -v yum)" ]; then
            yum install -y wget
        fi
    fi
}

# --- 核心逻辑：实例选择 ---
select_instance() {
    clear
    echo -e "${SKYBLUE}====================================${PLAIN}"
    echo -e "${SKYBLUE}      ECH Tunnel 多实例管理系统      ${PLAIN}"
    echo -e "${SKYBLUE}====================================${PLAIN}"
    echo -e "${YELLOW}提示：你可以为不同的配置设置不同的名称（如 client1, game）${PLAIN}"
    echo ""
    
    # 列出已有的配置文件
    if [ -d "$CONF_BASE_DIR" ] && [ "$(ls -A $CONF_BASE_DIR)" ]; then
        echo -e "当前已存在的实例："
        for conf in "$CONF_BASE_DIR"/*.conf; do
            filename=$(basename -- "$conf")
            name="${filename%.*}"
            # 检查运行状态
            if systemctl is-active --quiet "ech-tunnel-${name}"; then
                status="${GREEN}[运行中]${PLAIN}"
            else
                status="${RED}[已停止]${PLAIN}"
            fi
            echo -e " -> ${SKYBLUE}${name}${PLAIN} ${status}"
        done
        echo ""
    fi

    read -p "请输入实例名称 (默认: default): " INSTANCE_NAME
    [ -z "$INSTANCE_NAME" ] && INSTANCE_NAME="default"
    
    # 定义该实例的变量
    CONF_FILE="${CONF_BASE_DIR}/${INSTANCE_NAME}.conf"
    SERVICE_NAME="ech-tunnel-${INSTANCE_NAME}"
    
    # 创建配置目录
    mkdir -p "$CONF_BASE_DIR"
    
    # 读取配置或初始化默认值
    if [ -f "$CONF_FILE" ]; then
        source "$CONF_FILE"
    else
        # 默认值
        [ -z "$CFG_IP" ] && CFG_IP="104.16.1.1" 
        [ -z "$CFG_SERVER" ] && CFG_SERVER=""
        [ -z "$CFG_LISTEN" ] && CFG_LISTEN="proxy://0.0.0.0:30003"
        [ -z "$CFG_TOKEN" ] && CFG_TOKEN=""
    fi
}

# --- 功能函数 ---

download_bin() {
    if [ -f "$BIN_PATH" ]; then
        filesize=$(wc -c <"$BIN_PATH")
        if [ $filesize -lt 1000 ]; then
             echo -e "${RED}检测到二进制文件异常，重新下载...${PLAIN}"
             rm -f "$BIN_PATH"
        fi
    fi

    if [ ! -f "$BIN_PATH" ]; then
        echo -e "${YELLOW}正在下载 ECH Tunnel 二进制文件...${PLAIN}"
        wget --no-check-certificate -O "$BIN_PATH" "$GITHUB_BIN_URL"
        if [ $? -ne 0 ]; then
            echo -e "${RED}下载失败，请检查网络连接或 GitHub 地址！${PLAIN}"
            rm -f "$BIN_PATH"
            exit 1
        fi
        chmod +x "$BIN_PATH"
        echo -e "${GREEN}下载并赋权成功！${PLAIN}"
    fi
    
    if [ ! -f "$SHORTCUT_CMD" ]; then
        cat > "$SHORTCUT_CMD" <<EOF
#!/bin/bash
bash $(realpath "$0")
EOF
        chmod +x "$SHORTCUT_CMD"
        echo -e "${GREEN}快捷指令 'ech' 已创建，以后输入 ech 即可管理。${PLAIN}"
    fi
}

save_config() {
    cat > "$CONF_FILE" <<EOF
CFG_IP="${CFG_IP}"
CFG_SERVER="${CFG_SERVER}"
CFG_LISTEN="${CFG_LISTEN}"
CFG_TOKEN="${CFG_TOKEN}"
EOF
}

create_service() {
    echo -e "${YELLOW}正在生成 Systemd 服务文件...${PLAIN}"
    
    # 构建启动参数
    CMD_ARGS="-l ${CFG_LISTEN} -f ${CFG_SERVER} -ip ${CFG_IP}"
    if [ ! -z "$CFG_TOKEN" ]; then
        CMD_ARGS="${CMD_ARGS} -token ${CFG_TOKEN}"
    fi
    CMD_ARGS="${CMD_ARGS} -n 4"

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=ECH Tunnel Client - Instance: ${INSTANCE_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} ${CMD_ARGS}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}"
    echo -e "${GREEN}服务 ${SERVICE_NAME} 已配置。${PLAIN}"
}

start_service() {
    if [ -z "$CFG_SERVER" ]; then
        echo -e "${RED}错误：服务端地址未设置！请先选择选项 [2] 进行设置。${PLAIN}"
        read -p "按回车键返回菜单..."
        return
    fi

    # === 启动前强制检查并自动补全配置 ===
    FIXED=0
    
    # 1. 修复服务端地址 (补全 wss://)
    if [[ "$CFG_SERVER" != wss://* ]]; then
        CFG_SERVER="wss://${CFG_SERVER}"
        FIXED=1
    fi
    
    # 2. 修复监听地址 (补全 proxy://)
    # 如果用户只在文件里存了纯数字或 IP:端口
    if [[ "$CFG_LISTEN" != proxy://* && "$CFG_LISTEN" != tcp://* ]]; then
        # 如果是纯数字，默认监听 0.0.0.0
        if [[ "$CFG_LISTEN" =~ ^[0-9]+$ ]]; then
            CFG_LISTEN="proxy://0.0.0.0:${CFG_LISTEN}"
        else
            CFG_LISTEN="proxy://${CFG_LISTEN}"
        fi
        FIXED=1
    fi

    if [ $FIXED -eq 1 ]; then
        echo -e "${GREEN}检测到配置格式简略，已自动补全协议头并保存！${PLAIN}"
        save_config
    fi
    # ========================================

    download_bin
    create_service 
    
    echo -e "${YELLOW}正在启动服务...${PLAIN}"
    systemctl restart "${SERVICE_NAME}"
    
    sleep 2
    
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        echo -e "${GREEN}服务启动成功！${PLAIN}"
        echo -e "监听地址: ${CFG_LISTEN}"
        echo -e "服务端  : ${CFG_SERVER}"
        echo -e "优选 IP : ${CFG_IP}"
    else
        echo -e "${RED}服务启动失败！${PLAIN}"
        echo -e "${YELLOW}最后 10 行错误日志：${PLAIN}"
        journalctl -u "${SERVICE_NAME}" -n 10 --no-pager
    fi
}

stop_service() {
    systemctl stop "${SERVICE_NAME}"
    systemctl disable "${SERVICE_NAME}"
    echo -e "${YELLOW}服务 ${SERVICE_NAME} 已停止。${PLAIN}"
}

view_log() {
    echo -e "${YELLOW}正在查看日志 (Ctrl+C 退出)...${PLAIN}"
    journalctl -u "${SERVICE_NAME}" -f
}

uninstall_service() {
    echo -e "${RED}警告：删除实例 [${INSTANCE_NAME}]。${PLAIN}"
    read -p "确定要继续吗？[y/n]: " choice
    if [[ "$choice" == "y" ]]; then
        systemctl stop "${SERVICE_NAME}"
        systemctl disable "${SERVICE_NAME}"
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        rm -f "$CONF_FILE"
        systemctl daemon-reload
        echo -e "${GREEN}实例 ${INSTANCE_NAME} 已卸载。${PLAIN}"
    else
        echo -e "已取消。"
    fi
}

show_menu() {
    clear
    echo -e "${SKYBLUE}====================================${PLAIN}"
    echo -e "${SKYBLUE}   ECH Tunnel 管理脚本 ${YELLOW}[${INSTANCE_NAME}]${PLAIN}"
    echo -e "${SKYBLUE}====================================${PLAIN}"
    
    echo -e "当前配置："
    echo -e " 1. 优选 IP/域名 : ${GREEN}${CFG_IP}${PLAIN}"
    echo -e " 2. 服务端地址   : ${GREEN}${CFG_SERVER:-[未设置]}${PLAIN}"
    echo -e " 3. 本地监听地址 : ${GREEN}${CFG_LISTEN}${PLAIN}"
    echo -e " 4. Token (可选) : ${GREEN}${CFG_TOKEN:-[未设置]}${PLAIN}"
    echo -e "------------------------------------"
    
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        echo -e " 运行状态: ${GREEN}运行中 (PID: $(pgrep -f "${SERVICE_NAME}" | head -n 1))${PLAIN}"
    else
        echo -e " 运行状态: ${RED}未运行${PLAIN}"
    fi
    echo -e "------------------------------------"
    echo -e " 5. ${YELLOW}启动 / 重启服务${PLAIN}"
    echo -e " 6. 停止服务"
    echo -e " 7. 查看实时日志"
    echo -e " 8. 卸载当前实例"
    echo -e " 0. 退出脚本"
    echo -e "------------------------------------"
    echo -e " 9. 切换/新建其他实例"
    echo ""
    read -p "请选择 [0-9]: " choice
    
    case "$choice" in
        1) 
            read -p "请输入优选IP: " input_ip
            [ ! -z "$input_ip" ] && CFG_IP="$input_ip" && save_config 
            ;;
        2) 
            echo -e "请输入服务端域名 ${YELLOW}(例如: ech.xxx.com:443)${PLAIN}"
            read -p "地址: " input_server
            if [ ! -z "$input_server" ]; then
                # 去除可能误复制的 wss://
                input_server=${input_server#wss://}
                CFG_SERVER="wss://${input_server}"
                save_config
            fi
            ;;
        3) 
            echo -e "请输入 IP:端口 ${YELLOW}(例如 0.0.0.0:30003 或仅端口 30003)${PLAIN}"
            read -p "地址: " input_listen
            if [ ! -z "$input_listen" ]; then
                # 1. 去除可能存在的 proxy:// 前缀，只保留干净的 IP:Port
                clean_listen=${input_listen#proxy://}
                
                # 2. 如果只是纯数字，拼接 0.0.0.0
                if [[ "$clean_listen" =~ ^[0-9]+$ ]]; then
                    CFG_LISTEN="proxy://0.0.0.0:${clean_listen}"
                else
                    CFG_LISTEN="proxy://${clean_listen}"
                fi
                save_config
            fi
            ;;
        4) 
            read -p "Token: " input_token
            CFG_TOKEN="$input_token"
            save_config 
            ;;
        5) start_service; read -p "按回车继续..." ;;
        6) stop_service; read -p "按回车继续..." ;;
        7) view_log ;;
        8) uninstall_service; read -p "按回车继续..." ;;
        9) exec bash "$0" ;;
        0) exit 0 ;;
        *) echo "错误选择"; sleep 1 ;;
    esac
}

check_root
install_dependencies
select_instance

while true; do
    show_menu
done
