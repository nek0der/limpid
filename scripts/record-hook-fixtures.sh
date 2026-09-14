#!/usr/bin/env bash
# Starts one agent session under the Debug build's shim with hook recording
# enabled, inside a detached tmux session the caller then drives.
#
# Usage: scripts/record-hook-fixtures.sh <claude|codex> <case-name> <record-root>
#            [--tmux-hosted] [--env NAME=VALUE]... [-- <agent args>]
#
# The agent runs against the developer's real provider configuration and
# credentials, because a fresh HOME would not be logged in. Everything Limpid
# writes goes to a scratch directory instead: the state, session, and cwd
# directories are temporary, and the raw payloads land in
# <record-root>/<provider>/<case-name>/. The working directory is a throwaway git
# repository with one commit so turn snapshots and worktree creation have
# something to act on.
#
# tmux is only the transport for send-keys. `TMUX` and `TMUX_PANE` are removed
# from the agent's environment so the hooks record the ordinary non-hosted
# shape; pass --tmux-hosted to keep them for the tmux-hosted case.
#
# Codex refuses hooks whose trust hash is not in ~/.codex/config.toml, and only
# the app writes that block. Launch the Debug app once before recording Codex
# so the block matches the Debug bundle; this script checks and stops early
# when it does not.
set -euo pipefail

usage() {
  # Print the header comment only: stop at the first line that is not a
  # comment so the range cannot run into the code below it.
  awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0" >&2
  exit 2
}

[[ $# -ge 3 ]] || usage
provider="$1"
case_name="$2"
record_root="$3"
shift 3
tmux_hosted=0
extra_env=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tmux-hosted) tmux_hosted=1; shift ;;
    # Extra variables for the agent itself, such as an invalid API key to
    # provoke a failure; tmux would otherwise hand the agent its own server
    # environment rather than this shell's.
    --env)
      [[ $# -ge 2 ]] || usage
      # tmux takes NAME=VALUE pairs, so a bare name would silently become
      # part of the command rather than an environment entry.
      [[ "$2" == *=* ]] || usage
      extra_env+=("$2")
      shift 2
      ;;
    --) shift; break ;;
    *) break ;;
  esac
done

case "$provider" in
  claude | codex) ;;
  *) usage ;;
esac
case "$case_name" in
  '' | *[!A-Za-z0-9_-]*) echo "error: case name must be [A-Za-z0-9_-]+" >&2; exit 2 ;;
esac

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
apps=("$HOME"/Library/Developer/Xcode/DerivedData/Limpid-*/Build/Products/Debug/"Limpid Dev.app")
app="${apps[0]}"
if [[ ! -d "$app" ]]; then
  echo "error: no Debug build found; run make build first" >&2
  exit 1
fi
shim_dir="$app/Contents/Resources/${provider}-shim"
[[ -x "$shim_dir/$provider" ]] || { echo "error: shim missing at $shim_dir" >&2; exit 1; }

record_dir="$record_root/$provider/$case_name"
if [[ -e "$record_dir" ]]; then
  echo "error: $record_dir already exists; choose another case name or remove it" >&2
  exit 1
fi
# Recordings hold unscrubbed prompts until the scrub step runs.
(umask 077 && mkdir -p "$record_dir")

scratch="$(mktemp -d "${TMPDIR:-/tmp}/limpid-record-$case_name.XXXXXX")"
workdir="$scratch/repo"
mkdir -p "$workdir"
git -C "$workdir" init -q -b main
git -C "$workdir" -c user.name=fixture -c user.email=fixture@example.com commit -q --allow-empty -m "fixture base"
printf 'fixture\n' > "$workdir/README.md"
git -C "$workdir" add README.md
git -C "$workdir" -c user.name=fixture -c user.email=fixture@example.com commit -q -m "add README"

# The user's own shells may already carry an installed Limpid's shim on
# PATH, and a shim treats whatever `command -v` finds next as the real
# binary. Resolve the agent outside every shim directory and hand it over
# explicitly so the Debug shim is the only one in the chain.
real_agent=""
IFS=: read -r -a path_entries <<< "$PATH"
for entry in "${path_entries[@]}"; do
  case "$entry" in */Contents/Resources/*-shim) continue ;; esac
  if [[ -x "$entry/$provider" ]]; then
    real_agent="$entry/$provider"
    break
  fi
done
[[ -n "$real_agent" ]] || { echo "error: $provider not found on PATH outside the shim directories" >&2; exit 1; }
real_variable="LIMPID_REAL_CLAUDE"
[[ "$provider" == "codex" ]] && real_variable="LIMPID_REAL_CODEX"

pane_id="$(uuidgen)"
session="rec-$provider-$case_name"

env_args=(
  "LIMPID_HOOK_RECORD_DIR=$record_dir"
  "LIMPID_PANE_ID=$pane_id"
  "LIMPID_CLAUDE_HOOK_NAMESPACE=fixture-recording"
  "LIMPID_AGENT_STATES_DIR=$scratch/agent-states"
  "LIMPID_SESSIONS_DIR=$scratch/sessions"
  "LIMPID_CWD_EVENTS_DIR=$scratch/cwd-events"
  "LIMPID_CODEX_AGENT_STATES_DIR=$scratch/codex-agent-states"
  "LIMPID_CODEX_SESSIONS_DIR=$scratch/codex-sessions"
  "PATH=$shim_dir:$PATH"
  "$real_variable=$real_agent"
)
if [[ ${#extra_env[@]} -gt 0 ]]; then
  env_args+=("${extra_env[@]}")
fi

if [[ "$provider" == "codex" ]]; then
  hook_args="$(python3 "$repo_root/scripts/codex-hook-args.py" "$shim_dir")" || {
    echo "error: could not build LIMPID_CODEX_HOOK_ARGS; launch the Debug app once so ~/.codex/config.toml trusts its hooks" >&2
    exit 1
  }
  env_args+=("LIMPID_CODEX_HOOK_ARGS=$hook_args")
fi

unset_args=(-u CODEX_HOME)
if [[ "$tmux_hosted" == 0 ]]; then
  unset_args+=(-u TMUX -u TMUX_PANE)
fi

tmux new-session -d -s "$session" -x 140 -y 40 -c "$workdir" \
  /usr/bin/env "${unset_args[@]}" "${env_args[@]}" "$provider" "$@"

cat <<INFO
session:    $session
record dir: $record_dir
scratch:    $scratch
drive it:   tmux send-keys -t $session '<text>' Enter
watch it:   tmux capture-pane -p -t $session
stop it:    tmux kill-session -t $session
INFO
