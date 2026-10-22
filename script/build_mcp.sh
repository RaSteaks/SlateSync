#!/bin/zsh
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
# The optional executable owns its pinned SDK dependency graph. Keep build
# diagnostics off stdout so callers can capture the resulting binary path.
swift build --package-path "$project_root/MCP" --configuration release "$@" >&2
binary_dir="$(swift build --package-path "$project_root/MCP" --configuration release --show-bin-path)"
print -r -- "$binary_dir/slatesync-mcp"
