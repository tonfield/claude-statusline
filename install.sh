#!/bin/bash
# Install claude-statusline into ~/.claude/
set -e

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Check dependencies
if ! command -v jq &>/dev/null; then
  echo "Error: jq is required. Install with: brew install jq"
  exit 1
fi

# Create ~/.claude if needed
mkdir -p "$CLAUDE_DIR"

# Copy scripts
cp "$SCRIPT_DIR/statusline-command.sh" "$CLAUDE_DIR/statusline-command.sh"
cp "$SCRIPT_DIR/fetch-usage.sh" "$CLAUDE_DIR/fetch-usage.sh"
chmod +x "$CLAUDE_DIR/statusline-command.sh" "$CLAUDE_DIR/fetch-usage.sh"
echo "Copied scripts to $CLAUDE_DIR/"

# Merge settings into existing settings.json
PATCH=$(cat <<'PATCH_EOF'
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline-command.sh"
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/fetch-usage.sh > /dev/null 2>&1 &"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/fetch-usage.sh > /dev/null 2>&1 &"
          }
        ]
      }
    ]
  }
}
PATCH_EOF
)

if [ -f "$SETTINGS" ]; then
  # Merge: patch wins for statusLine, hooks are appended to existing arrays
  MERGED=$(jq --argjson patch "$PATCH" '
    # Set statusLine
    .statusLine = $patch.statusLine |

    # Merge hooks: append patch entries to existing arrays (skip duplicates)
    .hooks = ((.hooks // {}) as $existing |
      ($patch.hooks | to_entries) | reduce .[] as $h (
        $existing;
        .[$h.key] = ((.[$h.key] // []) as $arr |
          # Only add if the fetch-usage hook is not already there
          if ($arr | map(.hooks[]?.command // "") | any(test("fetch-usage")))
          then $arr
          else $arr + $h.value
          end
        )
      )
    )
  ' "$SETTINGS")
  echo "$MERGED" > "$SETTINGS"
  echo "Merged statusLine and hooks into $SETTINGS"
else
  echo "$PATCH" | jq '.' > "$SETTINGS"
  echo "Created $SETTINGS"
fi

echo ""
echo "Done! Restart Claude Code to see the statusline."
echo "The rate-limit bars will appear after the first API call."
