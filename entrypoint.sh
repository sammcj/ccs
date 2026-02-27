#!/usr/bin/env bash
# Entrypoint for ccs container.
# Claude Code stores config at $HOME/.claude.json (outside ~/.claude/).
# Since ~/.claude/ is our persistent mount, we copy .claude.json in on start
# and save it back on exit. Symlinks don't work here because Claude Code does
# atomic writes (write tmp + rename) which replace symlinks with regular files.

set -euo pipefail

PERSISTENT="$HOME/.claude/.claude.json"

# Restore .claude.json from persistent storage on startup
if [[ -f "$PERSISTENT" ]]; then
  cp "$PERSISTENT" "$HOME/.claude.json"
  chmod 600 "$HOME/.claude.json"
fi

# Seed settings with bypass-permissions default if no settings exist yet.
# This means `claude` (without --dangerously-skip-permissions) also defaults
# to bypass mode inside the container.
SETTINGS="$HOME/.claude/settings.json"
SL_CMD="/usr/local/bin/statusline-command.sh"
if [[ ! -f "$SETTINGS" ]]; then
  cat > "$SETTINGS" <<EOJSON
{
  "permissions": {
    "defaultMode": "bypassPermissions"
  },
  "statusLine": {
    "type": "command",
    "command": "$SL_CMD"
  }
}
EOJSON
elif ! jq -e '.statusLine' "$SETTINGS" &>/dev/null; then
  # Inject statusLine config into existing settings via jq
  jq --arg cmd "$SL_CMD" '. + {"statusLine": {"type": "command", "command": $cmd}}' \
    "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
fi

# Ensure any MCP tool binaries in the persistent dir are executable.
# Downloads via the mount can lose the execute bit.
BIN_DIR="$HOME/.claude/usr/local/bin"
if [[ -d "$BIN_DIR" ]]; then
  find "$BIN_DIR" -type f ! -perm -111 -size +0c -exec chmod +x {} +
fi

# Save .claude.json back to persistent storage on exit
# shellcheck disable=SC2329
save_config() {
  if [[ -f "$HOME/.claude.json" ]]; then
    cp "$HOME/.claude.json" "$PERSISTENT"
    chmod 600 "$PERSISTENT"
  fi
}

# Set up traps before forking to avoid a race window where signals
# arrive between fork and trap registration.
CHILD_PID=
# shellcheck disable=SC2329
cleanup() {
  local sig="$1"
  if [[ -n "$CHILD_PID" ]]; then
    kill "-$sig" "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
  fi
  save_config
  exit 1
}
trap 'cleanup INT' INT
trap 'cleanup TERM' TERM
trap save_config EXIT

# Run as child process so EXIT trap fires
"$@" &
CHILD_PID=$!
EXIT_CODE=0
wait "$CHILD_PID" || EXIT_CODE=$?
exit "$EXIT_CODE"
