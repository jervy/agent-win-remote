#!/usr/bin/env bash
# Stop chisel server (CloudStudio side)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PID_FILE="$PROJECT_ROOT/logs/chisel-server.pid"

stop_by_pid() {
    if [[ -f "$PID_FILE" ]]; then
        local PID
        PID=$(cat "$PID_FILE")
        if kill -0 "$PID" 2>/dev/null; then
            kill "$PID"
            echo "[chisel-server] 已停止 (PID=$PID)"
        else
            echo "[chisel-server] PID=$PID 已不存在"
        fi
        rm -f "$PID_FILE"
        return 0
    fi
    return 1
}

stop_by_match() {
    local CHISEL_BIN="$PROJECT_ROOT/bin/chisel"
    local PID
    PID=$(pgrep -f "$CHISEL_BIN.*server.*--reverse" 2>/dev/null | head -1 || true)
    if [[ -n "$PID" ]]; then
        kill "$PID"
        echo "[chisel-server] 按命令行匹配停止 (PID=$PID)"
        rm -f "$PID_FILE"
        return 0
    fi
    return 1
}

if stop_by_pid; then
    exit 0
fi

echo "[chisel-server] PID 文件不存在，尝试命令行匹配..."
if stop_by_match; then
    exit 0
fi

echo "[chisel-server] 未发现运行中的进程"
