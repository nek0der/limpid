#!/bin/sh
# Limpid shared agent runtime helpers — stable invocation identity and tmux
# endpoint discovery used by every agent shim and hook receiver.

limpid_is_uuid() {
  liu_value="${1:-}"
  case "$liu_value" in
    ????????-????-????-????-????????????) ;;
    *) return 1 ;;
  esac
  case "$liu_value" in
    *[!0-9A-Fa-f-]*) return 1 ;;
  esac
  return 0
}

limpid_ensure_run_id() {
  # We exec the real agent (not this shim) when handing off to tmux, so
  # every shim entry is a new invocation, including an agent's child.
  LIMPID_AGENT_RUN_ID=$(/usr/bin/uuidgen 2>/dev/null || true)
  LIMPID_AGENT_RUN_ID=$(printf '%s' "$LIMPID_AGENT_RUN_ID" | tr 'a-f' 'A-F')
  export LIMPID_AGENT_RUN_ID
}

limpid_capture_tmux_endpoint() {
  LIMPID_RUNTIME_TMUX_SOCKET=""
  LIMPID_RUNTIME_TMUX_SESSION=""
  LIMPID_RUNTIME_TMUX_PANE=""
  LIMPID_RUNTIME_TMUX_SERVER_PID=""
  LIMPID_RUNTIME_TMUX_SERVER_START=""
  # TMUX ends in ,server-pid,session-index. Removing fields from the
  # right preserves commas in a custom socket path. Session membership
  # is mutable and belongs to the Swift topology probe, not this hook.
  case "${TMUX:-}" in /*,*,*) ;; *) return 1 ;; esac
  case "${TMUX_PANE:-}" in '%'[0-9]*) ;; *) return 1 ;; esac
  case "${TMUX_PANE#?}" in *[!0-9]*) return 1 ;; esac
  lcte_prefix=${TMUX%,*}
  lcte_pid=${lcte_prefix##*,}
  case "$lcte_pid" in ''|*[!0-9]*) return 1 ;; esac
  LIMPID_RUNTIME_TMUX_SOCKET=${lcte_prefix%,*}
  LIMPID_RUNTIME_TMUX_PANE=$TMUX_PANE
  LIMPID_RUNTIME_TMUX_SERVER_PID=$lcte_pid
  lcte_start=$(LC_ALL=C TZ=UTC /bin/ps -p "$lcte_pid" -o lstart= 2>/dev/null)
  if [ -n "$lcte_start" ]; then
    LIMPID_RUNTIME_TMUX_SERVER_START=$(LC_ALL=C TZ=UTC /bin/date -j -f '%a %b %e %T %Y' "$lcte_start" '+%s' 2>/dev/null || true)
  fi
  return 0
}

limpid_next_revision() {
  lnr_file="$1"
  lnr_previous=$(plutil -extract revision raw -o - "$lnr_file" 2>/dev/null || true)
  case "$lnr_previous" in
    '' | *[!0-9]*) lnr_previous=0 ;;
  esac
  printf '%s' $((lnr_previous + 1))
}

limpid_acquire_record_lock() {
  # A persistent inode plus a kernel lock avoids stale-owner recovery.
  # FD 9 stays open in our shell; exit (including SIGKILL) releases it.
  exec 9>"$1.flock" || return 1
  larl_attempt=0
  while ! /usr/bin/lockf -s -t 0 9; do
    larl_attempt=$((larl_attempt + 1))
    [ "$larl_attempt" -lt 20 ] || { exec 9>&-; return 1; }
    sleep 0.01
  done
  return 0
}

limpid_release_record_lock() {
  exec 9>&-
}

limpid_snapshot_turn_base() {
  # Keep the real index untouched: a seeded private index takes about 20 ms in
  # both 530-file and 5,880-file repositories, while an unseeded cold snapshot
  # took about 650 ms in the 5,880-file repository.
  LIMPID_TURN_BASE_TREE=""
  LIMPID_TURN_ROOT=""
  lstd_cwd="${1:-$(pwd)}"
  lstd_pane_id="${2:-}"

  [ "${LIMPID_TURN_SNAPSHOT:-1}" != "0" ] || return 0
  [ -n "$lstd_pane_id" ] || return 0
  lstd_pane_key=$(printf '%s' "$lstd_pane_id" | tr '[:upper:]' '[:lower:]')
  command -v git >/dev/null 2>&1 || return 0

  lstd_inside=$(GIT_OPTIONAL_LOCKS=0 git -C "$lstd_cwd" rev-parse --is-inside-work-tree 2>/dev/null) || return 0
  [ "$lstd_inside" = "true" ] || return 0
  lstd_bare=$(GIT_OPTIONAL_LOCKS=0 git -C "$lstd_cwd" rev-parse --is-bare-repository 2>/dev/null) || return 0
  [ "$lstd_bare" = "false" ] || return 0
  lstd_git_dir=$(GIT_OPTIONAL_LOCKS=0 git -C "$lstd_cwd" rev-parse --absolute-git-dir 2>/dev/null) || return 0
  lstd_root=$(GIT_OPTIONAL_LOCKS=0 git -C "$lstd_cwd" rev-parse --show-toplevel 2>/dev/null) || return 0
  [ -n "$lstd_git_dir" ] && [ -n "$lstd_root" ] || return 0

  lstd_directory="$lstd_git_dir/limpid"
  lstd_index="$lstd_directory/turn-$lstd_pane_key.index"
  mkdir -p "$lstd_directory" 2>/dev/null || return 0
  cp "$lstd_git_dir/index" "$lstd_index" 2>/dev/null || :

  GIT_OPTIONAL_LOCKS=0 GIT_INDEX_FILE="$lstd_index" git -C "$lstd_root" add -A 2>/dev/null || return 0
  lstd_tree=$(GIT_OPTIONAL_LOCKS=0 GIT_INDEX_FILE="$lstd_index" git -C "$lstd_root" write-tree 2>/dev/null) || return 0
  case "$lstd_tree" in
    ????????????????????????????????????????) ;;
    *) return 0 ;;
  esac
  case "$lstd_tree" in
    *[!0-9A-Fa-f]*) return 0 ;;
  esac
  GIT_OPTIONAL_LOCKS=0 git -C "$lstd_root" update-ref "refs/limpid/turn/$lstd_pane_key" "$lstd_tree" 2>/dev/null || return 0

  LIMPID_TURN_BASE_TREE="$lstd_tree"
  LIMPID_TURN_ROOT="$lstd_root"
}

limpid_remove_turn_snapshot() {
  lrt_cwd="${1:-}"
  lrt_pane_id="${2:-}"
  [ -n "$lrt_cwd" ] && [ -n "$lrt_pane_id" ] || return 0
  lrt_pane_key=$(printf '%s' "$lrt_pane_id" | tr '[:upper:]' '[:lower:]')
  command -v git >/dev/null 2>&1 || return 0
  lrt_git_dir=$(GIT_OPTIONAL_LOCKS=0 git -C "$lrt_cwd" rev-parse --absolute-git-dir 2>/dev/null) || return 0
  GIT_OPTIONAL_LOCKS=0 git -C "$lrt_cwd" update-ref -d "refs/limpid/turn/$lrt_pane_key" 2>/dev/null || :
  rm -f "$lrt_git_dir/limpid/turn-$lrt_pane_key.index" 2>/dev/null || :
  rm -f "$lrt_git_dir/limpid/turn-$lrt_pane_key.read.index" 2>/dev/null || :
  # Remove paths from builds before pane UUIDs were normalized as well.
  if [ "$lrt_pane_key" != "$lrt_pane_id" ]; then
    GIT_OPTIONAL_LOCKS=0 git -C "$lrt_cwd" update-ref -d "refs/limpid/turn/$lrt_pane_id" 2>/dev/null || :
    rm -f "$lrt_git_dir/limpid/turn-$lrt_pane_id.index" 2>/dev/null || :
  fi
}
