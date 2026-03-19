#!/bin/sh
# Fetches Claude API usage stats → /tmp/.claude_usage_cache
# Skips if cache is fresh (<60s old). Meant to run backgrounded.

CACHE="/tmp/.claude_usage_cache"

# Staleness guard: skip if cache is <60s old
if [ -f "$CACHE" ]; then
  age=$(( $(date +%s) - $(stat -f %m "$CACHE") ))
  [ "$age" -lt 60 ] && exit 0
fi

# Extract OAuth token from macOS Keychain (stored as JSON)
raw=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
[ -z "$raw" ] && exit 0
token=$(printf '%s' "$raw" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
[ -z "$token" ] && exit 0

# Fetch usage
json=$(curl -s -m 10 \
  -H "accept: application/json" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "authorization: Bearer $token" \
  -H "user-agent: claude-code/2.1.11" \
  "https://api.anthropic.com/oauth/usage" 2>/dev/null)
[ -z "$json" ] && exit 0

# Parse and write cache (4 lines: 5h%, 7d%, 5h_reset, 7d_reset)
five_h=$(printf '%s' "$json" | jq -r '.five_hour.utilization // empty')
seven_d=$(printf '%s' "$json" | jq -r '.seven_day.utilization // empty')
[ -z "$five_h" ] || [ -z "$seven_d" ] && exit 0

printf '%.0f\n%.0f\n%s\n%s\n' \
  "$five_h" "$seven_d" \
  "$(printf '%s' "$json" | jq -r '.five_hour.resets_at // ""')" \
  "$(printf '%s' "$json" | jq -r '.seven_day.resets_at // ""')" \
  > "$CACHE"
