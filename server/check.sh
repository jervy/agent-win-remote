#!/usr/bin/env bash
# Pre-flight check for agent-win-remote

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0; WARN=0

check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  [PASS] $desc"
        PASS=$((PASS+1))
    else
        echo "  [FAIL] $desc"
        FAIL=$((FAIL+1))
    fi
}

warn_check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  [PASS] $desc"
        PASS=$((PASS+1))
    else
        echo "  [WARN] $desc"
        WARN=$((WARN+1))
    fi
}

echo "========================================="
echo "  Agent Win Remote - 部署检查"
echo "========================================="
echo ""

echo "目录结构:"
check "bin/chisel 存在且可执行" test -x "$PROJECT_ROOT/bin/chisel"
check "public/chisel.exe 存在" test -f "$PROJECT_ROOT/public/chisel.exe"
check "relay-secrets/relay-settings.json 存在" test -f "$PROJECT_ROOT/relay-secrets/relay-settings.json"
check "public/agent.ps1 存在" test -f "$PROJECT_ROOT/public/agent.ps1"
check "public/start.ps1 存在" test -f "$PROJECT_ROOT/public/start.ps1"
check "public/stop.ps1 存在" test -f "$PROJECT_ROOT/public/stop.ps1"
check "public/status.ps1 存在" test -f "$PROJECT_ROOT/public/status.ps1"
check "server/start-chisel-server.sh 存在" test -f "$PROJECT_ROOT/server/start-chisel-server.sh"

echo ""
echo "配置检查:"
CONFIG="${AGENT_CONFIG:-$PROJECT_ROOT/relay-secrets/relay-settings.json}"
check "relay-settings.json 可解析" jq . "$CONFIG"
check "server_port 字段存在" jq -e .server_port "$CONFIG"
check "remote_port 字段存在" jq -e .remote_port "$CONFIG"
check "chisel_auth 字段存在" jq -e .chisel_auth "$CONFIG"
check "agent_token 字段存在" jq -e .agent_token "$CONFIG"

SERVER_PORT=$(jq -r .server_port "$CONFIG")
REMOTE_PORT=$(jq -r .remote_port "$CONFIG")
SERVER_URL=$(jq -r .server_url "$CONFIG")

echo ""
echo "端口检查:"
warn_check "server_port ($SERVER_PORT) 已监听" ss -lntp
warn_check "remote_port ($REMOTE_PORT) 空闲" bash -c "! ss -lntp 2>/dev/null | grep -q ':$REMOTE_PORT '"

echo ""
echo "连通性检查:"
if echo "$SERVER_URL" | grep -q "PORTAL"; then
    echo "  [WARN] server_url 仍为占位符"
    WARN=$((WARN+1))
else
    echo "  [PASS] server_url 已配置"
    PASS=$((PASS+1))
fi

warn_check "chisel server 可访问" curl -sf "http://127.0.0.1:$SERVER_PORT/"

echo ""
echo "========================================="
echo "  结果: PASS=$PASS  FAIL=$FAIL  WARN=$WARN"
echo "========================================="
