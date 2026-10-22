#!/bin/zsh
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
binary="$project_root/MCP/.build/release/slatesync-mcp"
if [[ ! -x "$binary" ]]; then
    print -u2 'SlateSync MCP is not built. Run script/build_mcp.sh first.'
    exit 1
fi
# Resolve trusted Paddle resources independently of the MCP client's working
# directory. No GUI application is started and stdout stays protocol-only.
exec "$binary" --paddle-resources "$project_root/SlateSyncApp/Resources/PaddleOCR" "$@"
