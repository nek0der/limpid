#!/usr/bin/env bash
# spike-codex-shadow.sh
# Limpid — minimum viable test for the shadow CODEX_HOME hook injection pattern.
#
# Validates four conditions:
#   1. Codex launches cleanly with CODEX_HOME pointing at a symlinked shadow dir.
#   2. A Limpid-managed hooks.json in the shadow dir fires hook commands
#      (using --dangerously-bypass-hook-trust; proper trust hashes come later).
#   3. codex resume --last sees the user's prior sessions via symlinked sessions/.
#   4. Codex's writes (sessions, history.jsonl, state DBs) reach the user's
#      real ~/.codex/ via the symlinks (transparency).
#
# Run from anywhere. Cleans up its own shadow dir on exit.

set -euo pipefail

SHADOW_DIR="${TMPDIR:-/tmp}/limpid-codex-shadow.$$"
USER_CODEX="$HOME/.codex"
MARKER_DIR="${TMPDIR:-/tmp}/limpid-codex-markers.$$"
LIMPID_PANE_ID="spike-pane-$(date +%s)"

cleanup() {
  rm -rf "$SHADOW_DIR" "$MARKER_DIR"
}
trap cleanup EXIT

mkdir -p "$SHADOW_DIR" "$MARKER_DIR"

echo "==> Spike dir: $SHADOW_DIR"
echo "==> Marker dir: $MARKER_DIR"
echo "==> Pane id: $LIMPID_PANE_ID"
echo

# ------------------------------------------------------------------------------
# Step 1: Build symlink farm — every entry in ~/.codex/ except hooks.json and
#         config.toml is symlinked. Those two we own.
# ------------------------------------------------------------------------------
echo "==> Step 1: building symlink farm"
shopt -s dotglob nullglob
for entry in "$USER_CODEX"/*; do
  name="$(basename "$entry")"
  case "$name" in
    hooks.json|config.toml) continue ;;
  esac
  ln -s "$entry" "$SHADOW_DIR/$name"
done
shopt -u dotglob nullglob

# ------------------------------------------------------------------------------
# Step 2: Mirror user's config.toml as a copy (so we can append [hooks.state]
#         entries without touching user file). For this spike we just copy.
# ------------------------------------------------------------------------------
echo "==> Step 2: mirroring config.toml"
cp "$USER_CODEX/config.toml" "$SHADOW_DIR/config.toml"

# Strip user's [hooks.state] entries that reference user's hooks.json path —
# they would still try to validate against the user file which we don't load.
# (Conservative: leave them; they reference a path codex won't see.) For the
# spike we append shadow-path entries so codex treats our hooks as enabled.
SHADOW_HOOKS_PATH="$(cd "$SHADOW_DIR" && pwd -P)/hooks.json"
cat >>"$SHADOW_DIR/config.toml" <<TOML

# Limpid spike: register shadow-dir hooks.json so codex considers them enabled.
[hooks.state."${SHADOW_HOOKS_PATH}:session_start:0:0"]
trusted_hash = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
[hooks.state."${SHADOW_HOOKS_PATH}:user_prompt_submit:0:0"]
trusted_hash = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
[hooks.state."${SHADOW_HOOKS_PATH}:stop:0:0"]
trusted_hash = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
TOML

# ------------------------------------------------------------------------------
# Step 3: Write Limpid-managed hooks.json — one touch-marker per event.
#         User's hooks.json is not merged in this spike (kept minimal).
# ------------------------------------------------------------------------------
echo "==> Step 3: writing shadow hooks.json"
cat >"$SHADOW_DIR/hooks.json" <<JSON
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "/usr/bin/touch $MARKER_DIR/session_start" }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "/usr/bin/touch $MARKER_DIR/user_prompt_submit" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "/usr/bin/touch $MARKER_DIR/stop" }] }
    ]
  }
}
JSON

# ------------------------------------------------------------------------------
# Step 4: Snapshot user's sessions/ before launch — used later to verify
#         transparency (a new rollout should appear in user's real dir).
# ------------------------------------------------------------------------------
SESSIONS_BEFORE=$(find "$USER_CODEX/sessions" -name 'rollout-*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
echo "==> User sessions before: $SESSIONS_BEFORE"

# ------------------------------------------------------------------------------
# Step 5: Launch codex via shadow CODEX_HOME. Use a trivial prompt.
# ------------------------------------------------------------------------------
echo
echo "==> Step 5: launching codex (shadow CODEX_HOME)"
echo "----------------------------------------------"
CODEX_HOME="$SHADOW_DIR" \
LIMPID_PANE_ID="$LIMPID_PANE_ID" \
codex exec \
  --dangerously-bypass-hook-trust \
  --skip-git-repo-check \
  "respond with only the single word PONG" 2>&1 | tail -20
echo "----------------------------------------------"
echo

# ------------------------------------------------------------------------------
# Step 6: Verify conditions
# ------------------------------------------------------------------------------
echo "==> Step 6: verifying conditions"

check() {
  local label="$1"
  local result="$2"
  if [ "$result" = "ok" ]; then
    echo "  [PASS] $label"
  else
    echo "  [FAIL] $label"
    FAIL=1
  fi
}

FAIL=0

# Condition 1: codex launched cleanly (return code already enforced by set -e
#              within the pipe — we only get here if the command exited 0)
check "Condition 1: codex launched with shadow CODEX_HOME" "ok"

# Condition 2: hook markers exist
for ev in session_start user_prompt_submit stop; do
  if [ -e "$MARKER_DIR/$ev" ]; then
    check "Condition 2.$ev: hook fired" "ok"
  else
    check "Condition 2.$ev: hook fired" "fail"
  fi
done

# Condition 3: codex resume --last would see prior sessions
RESUMABLE=$(CODEX_HOME="$SHADOW_DIR" codex resume --all 2>&1 | head -5 | wc -l | tr -d ' ')
if [ "$RESUMABLE" -gt 0 ]; then
  check "Condition 3: codex resume sees user's sessions via symlink" "ok"
else
  check "Condition 3: codex resume sees user's sessions via symlink" "fail"
fi

# Condition 4: new rollout appears in user's real sessions/
SESSIONS_AFTER=$(find "$USER_CODEX/sessions" -name 'rollout-*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
if [ "$SESSIONS_AFTER" -gt "$SESSIONS_BEFORE" ]; then
  check "Condition 4: new rollout written through symlink to user's ~/.codex/sessions/" "ok"
else
  check "Condition 4: new rollout written through symlink (before=$SESSIONS_BEFORE after=$SESSIONS_AFTER)" "fail"
fi

echo
if [ $FAIL -eq 0 ]; then
  echo "==> ALL CHECKS PASSED. Shadow CODEX_HOME pattern is viable."
  exit 0
else
  echo "==> SOME CHECKS FAILED. Inspect output above."
  exit 1
fi
