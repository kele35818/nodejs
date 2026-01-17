#!/bin/bash

# =========================================================
# ECH Tunnel 一键管理脚本 (多实例版)
# 支持：自动安装、Systemd服务管理、多开、优选IP配置
# =========================================================

# --- 全局变量 ---
GITHUB_URL="https://github.com/kele35818/nodejs/raw/refs/heads/main/ech-tunnel-linux-amd64"
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
    echo -e "${YELLOW}提示：你可以为不同的配置设置不同的名称（如 client1, game, office）${PLAIN}"
    echo -e "${YELLOW}如果名称相同，将覆盖之前的配置。${PLAIN}"
    echo ""
    
    # 列出已有的配置文件
    if [ -d "$CONF_BASE_DIR" ] && [ "$(ls -A $CONF_BASE_DIR)" ]; then
        echo -e "当前已存在的实例配置："
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
        [ -z "$CFG_SERVER" ] && CFG_SERVER="wss://example.com:443"
        [ -z "$CFG_LISTEN" ] && CFG_LISTEN="proxy://0.0.0.0:30003"
        [ -z "$CFG_TOKEN" ] && CFG_TOKEN=""
    fi
}

# --- 功能函数 ---

download_bin() {
    if [ -f "$BIN_PATH" ]; then
        echo -e "${GREEN}检测到主程序已存在，跳过下载。${PLAIN}"
        echo -e "如果需要更新，请选择卸载后重新安装，或手动删除 ${BIN_PATH}"
    else
        echo -e "${YELLOW}正在下载 ECH Tunnel 二进制文件...${PLAIN}"
        wget --no-check-certificate -O "$BIN_PATH" "$GITHUB_URL"
        if [ $? -ne 0 ]; then
            echo -e "${RED}下载失败，请检查网络连接或 GitHub 地址！${PLAIN}"
            rm -f "$BIN_PATH"
            exit 1
        fi
        chmod +x "$BIN_PATH"
        echo -e "${GREEN}下载并赋权成功！${PLAIN}"
    fi
    
    # 创建快捷指令
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
    
    # 始终添加 -n 连接数优化
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
    echo -e "${GREEN}服务 ${SERVICE_NAME} 已创建并设置开机自启。${PLAIN}"
}

start_service() {
    download_bin # 确保二进制存在
    save_config  # 保存当前配置
    create_service # 重新生成服务文件（应用新配置）
    
    echo -e "${YELLOW}正在启动服务...${PLAIN}"
    systemctl restart "${SERVICE_NAME}"
    sleep 2
    
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        echo -e "${GREEN}服务启动成功！${PLAIN}"
        echo -e "监听地址: ${CFG_LISTEN}"
        echo -e "优选 IP : ${CFG_IP}"
    else
        echo -e "${RED}服务启动失败！请查看日志。${PLAIN}"
        systemctl status "${SERVICE_NAME}" --no-pager
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
    echo -e "${RED}警告：这将停止并删除实例 [${INSTANCE_NAME}] 的服务和配置。${PLAIN}"
    read -p "确定要继续吗？[y/n]: " choice
    if [[ "$choice" == "y" ]]; then
        systemctl stop "${SERVICE_NAME}"
        systemctl disable "${SERVICE_NAME}"
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        rm -f "$CONF_FILE"
        systemctl daemon-reload
        echo -e "${GREEN}实例 ${INSTANCE_NAME} 已卸载。${PLAIN}"
        echo -e "注：主程序二进制文件未删除，如需彻底清除请运行: rm -f ${BIN_PATH}"
    else
        echo -e "已取消。"
    fi
}

# --- 菜单界面 ---
show_menu() {
    clear
    echo -e "${SKYBLUE}====================================${PLAIN}"
    echo -e "${SKYBLUE}   ECH Tunnel 管理脚本 ${YELLOW}[${INSTANCE_NAME}]${PLAIN}"
    echo -e "${SKYBLUE}====================================${PLAIN}"
    
    # 显示当前配置状态
    echo -e "当前配置："
    echo -e " 1. 优选 IP/域名 : ${GREEN}${CFG_IP}${PLAIN}"
    echo -e " 2. 服务端地址   : ${GREEN}${CFG_SERVER}${PLAIN}"
    echo -e " 3. 本地监听地址 : ${GREEN}${CFG_LISTEN}${PLAIN}"
    echo -e " 4. Token (可选) : ${GREEN}${CFG_TOKEN:-[未设置]}${PLAIN}"
    echo -e "------------------------------------"
    
    # 显示运行状态
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        echo -e " 运行状态: ${GREEN}运行中 (PID: $(pgrep -f "${SERVICE_NAME}" | head -n 1))${PLAIN}"
    else
        echo -e " 运行状态: ${RED}未运行${PLAIN}"
    fi
    echo -e "------------------------------------"
    
    echo -e " 5. ${YELLOW}启动 / 重启服务 (应用修改)${PLAIN}"
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
            read -p "请输入优选IP或域名: " input_ip
            [ ! -z "$input_ip" ] && CFG_IP="$input_ip" && save_config
            ;;
        2)
            read -p "请输入服务端地址 (格式 wss://host:port): " input_server
            [ ! -z "$input_server" ] && CFG_SERVER="$input_server" && save_config
            ;;
        3)
            read -p "请输入监听地址 (格式 proxy://0.0.0.0:端口): " input_listen
            [ ! -z "$input_listen" ] && CFG_LISTEN="$input_listen" && save_config
            ;;
        4)
            read -p "请输入 Token (留空则删除): " input_token
            CFG_TOKEN="$input_token"
            save_config
            ;;
        5)
            start_service
            read -p "按回车键继续..."
            ;;
        6)
            stop_service
            read -p "按回车键继续..."
            ;;
        7)
            view_log
            ;;
        8)
            uninstall_service
            read -p "按回车键继续..."
            ;;
        9)
            exec bash "$0" # 重新运行脚本以选择实例
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}输入错误，请重新选择${PLAIN}"
            sleep 1
            ;;
    esac
}

# --- 主程序入口 ---
check_root
install_dependencies
select_instance

while true; do
    show_menu
done
