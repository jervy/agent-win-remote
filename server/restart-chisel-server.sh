#!/usr/bin/env bash
# Restart chisel server
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/stop-chisel-server.sh"
sleep 1
bash "$SCRIPT_DIR/start-chisel-server.sh"
