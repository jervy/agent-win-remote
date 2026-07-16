#!/usr/bin/env bash
# Start chisel server (run on the private Linux/VPS host)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Read configuration from a private path when provided; fall back to the local file.
CONFIG="${HERMES_CONFIG:-$PROJECT_ROOT/relay-secrets/relay-settings.json}"
if [[ ! -f "$CONFIG" ]]; then
    echo "配置文件不存在: $CONFIG" >&2
    exit 1
fi
CHISEL_AUTH="$(jq -r .chisel_auth "$CONFIG")"
SERVER_PORT="${CHISEL_PORT:-$(jq -r .server_port "$CONFIG")}"
CHISEL_HOST="${CHISEL_HOST:-127.0.0.1}"

CHISEL_BIN="$PROJECT_ROOT/bin/chisel"
PID_FILE="$PROJECT_ROOT/logs/chisel-server.pid"
LOG_FILE="$PROJECT_ROOT/logs/chisel-server.log"

# Ensure dirs
mkdir -p "$PROJECT_ROOT/logs"

# Check if already running
if [[ -f "$PID_FILE" ]]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "[chisel-server] 已在运行 (PID=$OLD_PID)"
        exit 0
    fi
    rm -f "$PID_FILE"
fi

echo "[chisel-server] 启动中..."
echo "  监听: $CHISEL_HOST:$SERVER_PORT"
echo "  Auth: ${CHISEL_AUTH%%:*}:***"
echo "  日志: $LOG_FILE"

nohup "$CHISEL_BIN" server \
    --reverse \
    --host "$CHISEL_HOST" \
    --port "$SERVER_PORT" \
    --auth "$CHISEL_AUTH" \
    >> "$LOG_FILE" 2>&1 &

echo $! > "$PID_FILE"
echo "[chisel-server] 启动成功 (PID=$(cat "$PID_FILE"))"
