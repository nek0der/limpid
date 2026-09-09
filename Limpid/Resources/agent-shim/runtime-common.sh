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
