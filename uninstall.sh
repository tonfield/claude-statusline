#!/bin/bash
# Remove claude-statusline from ~/.claude/
set -e

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"

# Remove scripts
rm -f "$CLAUDE_DIR/statusline-command.sh" "$CLAUDE_DIR/fetch-usage.sh"
echo "Removed scripts from $CLAUDE_DIR/"

# Clean settings.json
if [ -f "$SETTINGS" ] && command -v jq &>/dev/null; then
  CLEANED=$(jq '
    del(.statusLine) |
    if .hooks then
      .hooks |= with_entries(
        .value |= map(select(
          (.hooks // []) | all(.command // "" | test("fetch-usage") | not)
        ))
      ) |
      .hooks |= with_entries(select(.value | length > 0)) |
      if .hooks == {} then del(.hooks) else . end
    else . end
  ' "$SETTINGS")
  echo "$CLEANED" > "$SETTINGS"
  echo "Removed statusLine and fetch-usage hooks from $SETTINGS"
fi

# Clean up cache
rm -f /tmp/.claude_usage_cache
rm -f "$CLAUDE_DIR/usage_costs.tsv"

echo ""
echo "Done! Restart Claude Code to apply."
