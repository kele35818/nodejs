#!/usr/bin/env bash

# --- 1. Environment Variables ---
FILE_PATH="${FILE_PATH:-./tmp}"
SUB_PATH="${SUB_PATH:-kele666}"
PORT="${SERVER_PORT:-${PORT:-3000}}"
UUID="${UUID:-6948adff-5e1e-4f52-9c9c-11b707390b8b}"
ARGO_DOMAIN="${ARGO_DOMAIN:-2.oxxx.qzz.io}"
ARGO_AUTH="${ARGO_AUTH:-eyJhIjoiNTA0NmI1ODdjNmU0YmRhN2FlNTM2ZGZjZGVjM2M1NDkiLCJ0IjoiNWQ5M2I0ZmMtODhiOC00Zjk3LWE2ZTYtOTk1ZTM0ZjNjYWU2IiwicyI6IllqWXlPRFE0TURrdE5qTXlNQzAwTlRjMkxUazBabU10WW1aaVptSmxZVGhsWm1JNSJ9}"
ARGO_PORT="${ARGO_PORT:-8001}"
CFIP="${CFIP:-cfip.xooo.qzz.io}"
CFPORT="${CFPORT:-443}"
NAME="${NAME:-SAP}"

# --- 2. Setup Directory and File Names ---
if [ ! -d "$FILE_PATH" ]; then
    mkdir -p "$FILE_PATH"
    echo "$FILE_PATH is created"
else
    echo "$FILE_PATH already exists"
    # Cleanup old files
    rm -f "$FILE_PATH"/* 2>/dev/null
fi

# Generate 6-letter random names for the binaries
WEB_NAME=$(tr -dc a-z </dev/urandom | head -c 6)
BOT_NAME=$(tr -dc a-z </dev/urandom | head -c 6)

WEB_PATH="$FILE_PATH/$WEB_NAME"
BOT_PATH="$FILE_PATH/$BOT_NAME"
SUB_PATH_FILE="$FILE_PATH/sub.txt"
CONFIG_PATH="$FILE_PATH/config.json"

# --- 3. Generate Configuration File ---
cat <<EOF > "$CONFIG_PATH"
{
  "log": {
    "access": "/dev/null",
    "error": "/dev/null",
    "loglevel": "none"
  },
  "policy": {
    "levels": {
      "0": {
        "handshake": 3,
        "connIdle": 60,
        "uplinkOnly": 2,
        "downlinkOnly": 5,
        "bufferSize": 512,
        "statsUserUplink": false,
        "statsUserDownlink": false
      }
    }
  },
  "inbounds": [
    {
      "port": $ARGO_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$UUID", "level": 0}],
        "decryption": "none",
        "fallbacks": [
          {"dest": 3001},
          {"path": "/vless-argo", "dest": 3002}
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none",
        "sockopt": {
          "tcpFastOpen": true,
          "tcpNoDelay": true,
          "tcpKeepAliveInterval": 15,
          "tfoQueueLength": 4096
        }
      }
    },
    {
      "port": 3001,
      "listen": "127.0.0.1",
      "protocol": "http",
      "settings": {
        "clients": [{"id": "$UUID", "level": 0}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none",
        "sockopt": {"tcpFastOpen": true, "tcpNoDelay": true}
      }
    },
    {
      "port": 3002,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$UUID", "level": 0}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "/vless-argo",
          "maxEarlyData": 2560,
          "earlyDataHeaderName": "Sec-WebSocket-Protocol"
        },
        "sockopt": {"tcpFastOpen": true, "tcpNoDelay": true}
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "metadataOnly": false
      }
    }
  ],
  "dns": {
    "servers": ["https+local://8.8.8.8/dns-query", "8.8.8.8", "https+local://1.1.1.1/dns-query"],
    "queryStrategy": "UseIPv4",
    "disableCache": false
  },
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]
}
EOF

# --- 4. Download Binaries ---
echo "Downloading files..."
curl -sL -o "$WEB_PATH" "https://github.com/guoziyou/SOCKS5/raw/refs/heads/main/web"
curl -sL -o "$BOT_PATH" "https://github.com/guoziyou/SOCKS5/raw/refs/heads/main/bot"

chmod 755 "$WEB_PATH" "$BOT_PATH" 2>/dev/null

# --- 5. Start Web (VLESS Proxy) ---
nohup "$WEB_PATH" -c "$CONFIG_PATH" > /dev/null 2>&1 &
echo "$WEB_NAME is running"
sleep 1

# --- 6. Configure & Start Argo Tunnel (Bot) ---
if [[ -n "$ARGO_AUTH" && -n "$ARGO_DOMAIN" ]]; then
    if [[ "$ARGO_AUTH" =~ ^[A-Z0-9a-z=]{120,250}$ ]]; then
        echo "Using ARGO_AUTH Token to connect to tunnel."
        RUN_BOT_CMD="tunnel --edge-ip-version 4 --no-autoupdate --protocol http2 run --token $ARGO_AUTH"
    elif [[ "$ARGO_AUTH" == *"TunnelSecret"* ]]; then
        echo "Using JSON credentials to connect to tunnel."
        echo "$ARGO_AUTH" > "$FILE_PATH/tunnel.json"
        
        # Extract TunnelID safely without needing jq
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
    else
        echo "ARGO_AUTH is invalid. Fixed tunnel will not start."
        RUN_BOT_CMD=""
    fi

    if [[ -n "$RUN_BOT_CMD" ]]; then
        nohup "$BOT_PATH" $RUN_BOT_CMD > /dev/null 2>&1 &
        echo "$BOT_NAME is running"
        sleep 2
    fi
else
    echo "ARGO_DOMAIN or ARGO_AUTH variable is empty. Fixed tunnel required."
fi

# --- 7. Extract Domains & Generate Link ---
if [[ -n "$ARGO_AUTH" && -n "$ARGO_DOMAIN" ]]; then
    echo "Using fixed ARGO_DOMAIN: $ARGO_DOMAIN"
    
    VLESS_LINK="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${ARGO_DOMAIN}&type=ws&host=${ARGO_DOMAIN}&path=%2Fvless-argo%3Fed%3D2560#${NAME}"
    VLESS_BASE64=$(echo -n "$VLESS_LINK" | base64 | tr -d '\n')
    
    echo "$VLESS_BASE64" > "$SUB_PATH_FILE"
    
    echo ""
    echo "Subscription Content (Base64):"
    echo "$VLESS_BASE64"
    echo "$FILE_PATH/sub.txt saved successfully"
    echo "Empowerment success for  $VLESS_LINK"
else
    echo "ARGO_DOMAIN and/or ARGO_AUTH are not set. Skipping link generation."
fi

# --- 8. Auto-cleanup Background Task ---
(
    sleep 90
    rm -f "$CONFIG_PATH" "$WEB_PATH" "$BOT_PATH" >/dev/null 2>&1
    clear
    echo "App is running"
    echo "Thank you for using this script, enjoy!"
) &

# Keep script running if you need to keep a container alive, otherwise let it exit.
# wait
