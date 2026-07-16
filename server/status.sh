#!/usr/bin/env bash
# Show chisel server status
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG="${AGENT_CONFIG:-$PROJECT_ROOT/relay-secrets/relay-settings.json}"
PID_FILE="$PROJECT_ROOT/logs/chisel-server.pid"
LOG_FILE="$PROJECT_ROOT/logs/chisel-server.log"

SERVER_PORT=$(jq -r .server_port "$CONFIG")
REMOTE_PORT=$(jq -r .remote_port "$CONFIG")
SERVER_URL=$(jq -r .server_url "$CONFIG")

echo "========================================="
echo "  Agent Win Remote - Chisel Server 状态"
echo "========================================="
echo ""
echo "部署目录: $PROJECT_ROOT"
echo "服务端口: $SERVER_PORT"
echo "反向端口: $REMOTE_PORT"
echo "日志路径: $LOG_FILE"
echo ""

# PID
if [[ -f "$PID_FILE" ]]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        echo "chisel PID: $PID (运行中)"
    else
        echo "chisel PID: $PID (已退出)"
    fi
else
    echo "chisel PID: 无 PID 文件"
fi

# Port check
echo ""
if ss -lntp 2>/dev/null | grep -q ":$SERVER_PORT "; then
    echo "端口 $SERVER_PORT: 已监听"
else
    echo "端口 $SERVER_PORT: 未监听"
fi

if ss -lntp 2>/dev/null | grep -q ":$REMOTE_PORT "; then
    echo "端口 $REMOTE_PORT: 已监听 (反向隧道活跃)"
else
    echo "端口 $REMOTE_PORT: 未监听"
fi

# server_url placeholder check
echo ""
if echo "$SERVER_URL" | grep -q "PORTAL"; then
    echo "server_url: ⚠ 仍为占位符，需替换"
    echo "  当前值: $SERVER_URL"
else
    echo "server_url: $SERVER_URL"
fi

# Recent logs
echo ""
echo "-------- 最近 50 行日志 --------"
if [[ -f "$LOG_FILE" ]]; then
    tail -50 "$LOG_FILE"
else
    echo "(日志文件不存在)"
fi
