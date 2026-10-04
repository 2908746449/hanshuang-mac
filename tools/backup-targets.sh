#!/bin/zsh
# 测试前备份各目标的注入点，测试后可按需还原。
# 只备份会被注入改写的文件，不整目录复制。
set -u
DEST="$(cd "$(dirname "$0")/.." && pwd)/backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DEST"

copy() {
  local src="$1"
  if [ -e "$src" ]; then
    local rel="${src#$HOME/}"
    mkdir -p "$DEST/$(dirname "$rel")"
    cp -R "$src" "$DEST/$rel" 2>/dev/null && echo "  saved  $src"
  else
    echo "  absent $src"
  fi
}

echo "备份到 $DEST"
copy "$HOME/.codex/config.toml"
copy "$HOME/.codex/AGENTS.md"
copy "$HOME/.claude/CLAUDE.md"
copy "$HOME/.claude/config.toml"
copy "$HOME/.claude/skills"
copy "$HOME/.cursor/rules"
copy "$HOME/.cursorrules"
copy "$HOME/.zcode/AGENTS.md"
copy "$HOME/.zcode/v2/setting.json"
copy "$HOME/.zcode/install-state.json"
copy "$HOME/.dsh/AGENTS.md"
copy "$HOME/.workbuddy-ai/MEMORY.md"
copy "$HOME/.workbuddy-ai/app/app-config.json"
copy "$HOME/.workbuddy-ai/settings.json"
copy "$HOME/.workbuddy-ai/memory"
copy "$HOME/.workbuddy-ai/skills"
copy "$HOME/.doubao"
echo "$DEST"
