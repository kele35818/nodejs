#!/usr/bin/env bash

# ==========================================
# 调试版配置区 (请直接修改)
# ==========================================
FILE_PATH="./tmp"
UUID="6948adff-5e1e-4f52-9c9c-11b707390b8b"
ARGO_DOMAIN="5.oxxx.qzz.io"
ARGO_AUTH="eyJhIjoiNTA0NmI1ODdjNmU0YmRhN2FlNTM2ZGZjZGVjM2M1NDkiLCJ0IjoiZjZjODQ2OGYtZDFjMy00NmVmLTgwOWUtNDM5YTMyMzU2NTVjIiwicyI6IllUQTNNRFU0TTJNdE1HWXlNeTAwWW1WbExUazNNV1F0Wm1GbU9UaGlaak00WkdGbSJ9"
ARGO_PORT=8001
CFIP="cfip.xooo.qzz.io"
CFPORT=443
NAME="SAP"
# ==========================================

echo "====== [DEBUG MODE] STARTING ======"

# --- 1. 环境准备 ---
if [ ! -d "$FILE_PATH" ]; then
    mkdir -p "$FILE_PATH"
    echo "Directory $FILE_PATH is created"
else
    echo "Directory $FILE_PATH already exists, cleaning up old files..."
    rm -f "$FILE_PATH"/* 2>/dev/null
fi

WEB_NAME=$(tr -dc a-z </dev/urandom | head -c 6)
BOT_NAME=$(tr -dc a-z </dev/urandom | head -c 6)

WEB_PATH="$FILE_PATH/$WEB_NAME"
BOT_PATH="$FILE_PATH/$BOT_NAME"
SUB_PATH_FILE="$FILE_PATH/sub.txt"
CONFIG_PATH="$FILE_PATH/config.json"
WEB_LOG="$FILE_PATH/web.log"
BOT_LOG="$FILE_PATH/bot.log"

# --- 2. 生成代理配置文件 ---
cat <<EOF > "$CONFIG_PATH"
{
  "log": {
    "access": "/dev/null",
    "error": "/dev/null",
    "loglevel": "warning"
  },
  "policy": {
    "levels": {
      "0": {"handshake": 3, "connIdle": 60, "uplinkOnly": 2, "downlinkOnly": 5, "bufferSize": 512}
    }
  },
  "inbounds": [
    {
      "port": $ARGO_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$UUID", "level": 0}],
        "decryption": "none",
        "fallbacks": [{"dest": 3001}, {"path": "/vless-argo", "dest": 3002}]
      },
      "streamSettings": {"network": "tcp", "security": "none"}
    },
    {
      "port": 3001,
      "listen": "127.0.0.1",
      "protocol": "http",
      "settings": {"clients": [{"id": "$UUID", "level": 0}], "decryption": "none"},
      "streamSettings": {"network": "tcp", "security": "none"}
    },
    {
      "port": 3002,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {"clients": [{"id": "$UUID", "level": 0}], "decryption": "none"},
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {"path": "/vless-argo", "maxEarlyData": 2560, "earlyDataHeaderName": "Sec-WebSocket-Protocol"}
      }
    }
  ],
  "dns": {"servers": ["8.8.8.8", "1.1.1.1"], "queryStrategy": "UseIPv4"},
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]
}
EOF

# --- 3. 下载核心组件 ---
echo "Downloading files from GitHub..."
curl -sL -o "$WEB_PATH" "https://github.com/guoziyou/SOCKS5/raw/refs/heads/main/web"
curl -sL -o "$BOT_PATH" "https://github.com/guoziyou/SOCKS5/raw/refs/heads/main/bot"

chmod 755 "$WEB_PATH" "$BOT_PATH" 2>/dev/null

echo "--- Check Downloaded File Sizes ---"
ls -lh "$WEB_PATH" "$BOT_PATH"
echo "-----------------------------------"

# --- 4. 启动代理核心 (Web) 并记录日志 ---
echo "Starting Proxy core..."
nohup "$WEB_PATH" -c "$CONFIG_PATH" > "$WEB_LOG" 2>&1 &
sleep 2

# --- 5. 配置并启动 Argo Tunnel (Bot) 并记录日志 ---
if [[ -n "$ARGO_AUTH" && -n "$ARGO_DOMAIN" ]]; then
    if [[ "$ARGO_AUTH" =~ ^[A-Z0-9a-z=]{120,250}$ ]]; then
        RUN_BOT_CMD="tunnel --edge-ip-version 4 --no-autoupdate --protocol http2 run --token $ARGO_AUTH"
    elif [[ "$ARGO_AUTH" == *"TunnelSecret"* ]]; then
        echo "$ARGO_AUTH" > "$FILE_PATH/tunnel.json"
        TUNNEL_ID=$(echo "$ARGO_AUTH" | grep -o '"TunnelID":"[^"]*' | cut -d'"' -f4)
        cat <<EOF > "$FILE_PATH/tunnel.yml"
tunnel: $TUNNEL_ID
credentials-file: $FILE_PATH/tunnel.json
ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:$ARGO_PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
        RUN_BOT_CMD="tunnel --edge-ip-version 4 --config $FILE_PATH/tunnel.yml run"
    fi

    if [[ -n "$RUN_BOT_CMD" ]]; then
        echo "Starting Tunnel client..."
        nohup "$BOT_PATH" $RUN_BOT_CMD > "$BOT_LOG" 2>&1 &
        sleep 2
    fi
fi

# --- 6. 打印 VLESS 节点信息 ---
echo ""
VLESS_LINK="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${ARGO_DOMAIN}&type=ws&host=${ARGO_DOMAIN}&path=%2Fvless-argo%3Fed%3D2560#${NAME}"
VLESS_BASE64=$(echo -n "$VLESS_LINK" | base64 | tr -d '\n')
echo "$VLESS_BASE64" > "$SUB_PATH_FILE"
echo "Subscription Content (Base64):"
echo "$VLESS_BASE64"
echo ""

# --- 7. 打印错误日志 (关键步骤) ---
echo "====== [DEBUG INFO] WEB CORE LOG ======"
cat "$WEB_LOG"
echo "======================================="

# 已移除后台清理功能，方便调试
