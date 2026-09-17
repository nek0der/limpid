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

# One uppercase UUID on stdout, or a failure. `uuidgen` is part of macOS,
# so the random fallback is only there because a hosted launch now refuses
# to run at all without an id, and a PATH the user narrowed is not a reason
# to lose an agent. The fallback fixes the version and variant nibbles so
# what we print is a version 4 UUID rather than 16 random bytes.
limpid_new_uuid() {
  lnu_value=$(/usr/bin/uuidgen 2>/dev/null || uuidgen 2>/dev/null || true)
  if [ -z "$lnu_value" ]; then
    lnu_hex=$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n')
    case "$lnu_hex" in
      ????????????????????????????????) ;;
      *) return 1 ;;
    esac
    lnu_value="$(printf '%s' "$lnu_hex" | cut -c1-8)-$(printf '%s' "$lnu_hex" | cut -c9-12)"
    lnu_value="$lnu_value-4$(printf '%s' "$lnu_hex" | cut -c14-16)"
    lnu_value="$lnu_value-8$(printf '%s' "$lnu_hex" | cut -c18-20)"
    lnu_value="$lnu_value-$(printf '%s' "$lnu_hex" | cut -c21-32)"
  fi
  printf '%s' "$lnu_value" | tr 'a-f' 'A-F'
}

limpid_ensure_run_id() {
  # We exec the real agent (not this shim) when handing off to tmux, so
  # every shim entry is a new invocation, including an agent's child.
  LIMPID_AGENT_RUN_ID=$(limpid_new_uuid 2>/dev/null || true)
  export LIMPID_AGENT_RUN_ID
}

# One JSON string literal, escaped, on stdout. Only `"` and `\` can occur
# in what we pass through here — a socket path may hold either — and a
# control character would make the file unreadable, so the caller checks
# the fields for shape before it builds the object.
limpid_json_string() {
  printf '"%s"' "$(printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

limpid_is_decimal() {
  case "${1:-}" in
    '' | *[!0-9]*) return 1 ;;
  esac
  return 0
}

# Removes what a launch left half-done. Installed as the `EXIT` trap for
# the whole of `limpid_host_agent_in_tmux`, so an interrupt or a failure
# part way through leaves neither a hidden temporary file in the request
# directory nor a session no tab will ever be opened for.
#
# `limpid_host_session` is only ever set to a session this invocation made
# (see where it is armed), because killing by a name we merely intended to
# use would kill whatever else answers to it — another agent of the user's.
limpid_host_abort() {
  [ -z "${limpid_host_tmp:-}" ] || rm -f "$limpid_host_tmp"
  limpid_host_tmp=""
  if [ -n "${limpid_host_session:-}" ]; then
    "$LIMPID_AGENT_TMUX" -L "${LIMPID_AGENT_TMUX_SOCKET:-limpid}" -f /dev/null \
      kill-session -t "$limpid_host_session" 2>/dev/null || :
    limpid_host_session=""
  fi
}

# Starts the agent in "$@" in a detached session of this build's agent
# server and asks Limpid to show that session as a mirror tab, then
# returns to the prompt. The agent is never a child of this shell, which
# is what lets it outlive Limpid.
#
# The caller sets `limpid_agent_provider` (an `AgentKind` id) and
# `limpid_hosted_env_names` (the variables the session is given rather
# than left to inherit; a session created on a server that already exists
# inherits that server's environment for everything outside tmux's
# `update-environment`).
#
# We return non-zero rather than running the agent directly when any of
# this fails. The alternative — an agent that silently runs where the user
# cannot see it after asking for a tab — is the failure that is hard to
# notice, and `tmux` is only offered at all once Limpid knows a mirror can
# attach to it (`AgentTmuxSupport`), so a failure here is a real fault.
limpid_host_agent_in_tmux() {
  limpid_host_tmp=""
  limpid_host_session=""
  trap 'limpid_host_abort' EXIT
  trap 'exit 1' HUP INT TERM

  lha_requests="${LIMPID_AGENT_MIRROR_REQUESTS_DIR:-}"
  if [ -z "$lha_requests" ] || [ ! -d "$lha_requests" ]; then
    printf 'limpid: not starting the agent: no directory to ask for a tab in\n' >&2
    return 1
  fi
  lha_launch_pane="${LIMPID_PANE_ID:-}"
  if ! limpid_is_uuid "$lha_launch_pane"; then
    printf 'limpid: not starting the agent: this pane has no id to open the tab beside\n' >&2
    return 1
  fi
  if ! lha_leaf=$(limpid_new_uuid) || [ -z "$lha_leaf" ]; then
    printf 'limpid: not starting the agent: cannot make an id for the tab\n' >&2
    return 1
  fi

  # Unique per invocation, because the leaf id is: a process id repeats
  # after a wrap, and two agents from one pane would then ask for the same
  # name. `-A` is deliberately absent: with the name already taken it
  # attaches and silently drops the command, handing back the running agent
  # instead of starting the one that was asked for. A name that collides
  # all the same fails the launch and kills nothing, since cleanup is armed
  # only once tmux says it made the session.
  lha_session="limpid-$(printf '%s' "$lha_launch_pane" | tr -cd 'A-Za-z0-9' | cut -c1-8)"
  lha_session="$lha_session-$(printf '%s' "$lha_leaf" | tr -cd 'A-Za-z0-9' | cut -c1-8)"
  lha_tab=$(printf '\t')
  # `stty` reads the terminal we were started on. A session sized here
  # opens at the size of the pane the command was typed in, so the agent
  # does not draw once at tmux's default and reflow when the tab attaches.
  lha_size=$(stty size 2>/dev/null || true)
  lha_rows="${lha_size%% *}"
  lha_cols="${lha_size##* }"

  # The agent command is in "$@" and the tmux command line has to come
  # before it. We append the tmux side after it and then rotate the
  # agent command to the end, which is how a list whose values may hold
  # spaces is built in POSIX sh.
  lha_count=$#
  set -- "$@" -L "${LIMPID_AGENT_TMUX_SOCKET:-limpid}" -u -f /dev/null \
    set -s escape-time 10 ";" \
    set -s default-terminal tmux-256color ";" \
    set -sa terminal-overrides ",*:RGB" ";" \
    set -g prefix None ";" \
    new-session -d -s "$lha_session" -P -F \
    "#{socket_path}$lha_tab#{session_id}$lha_tab#{window_id}$lha_tab#{pane_id}$lha_tab#{pid}$lha_tab#{start_time}"
  if limpid_is_decimal "$lha_rows" && limpid_is_decimal "$lha_cols" &&
    [ "$lha_rows" -gt 0 ] && [ "$lha_cols" -gt 0 ]
  then
    set -- "$@" -x "$lha_cols" -y "$lha_rows"
  fi
  # The leaf of the mirror tab is the agent's pane as far as every record
  # is concerned, so the agent is given that id and not the one belonging
  # to the pane the command was typed in. The launching pane travels in
  # the request instead, as where to put the tab.
  LIMPID_PANE_ID="$lha_leaf"
  for lha_name in ${limpid_hosted_env_names:-}; do
    eval "lha_value=\${$lha_name:-}"
    [ -n "$lha_value" ] || continue
    set -- "$@" -e "$lha_name=$lha_value"
  done
  # `/usr/bin/env` guarantees more than one argument after the options,
  # which is what makes tmux exec our argv directly rather than passing
  # a single string to `sh -c` — so nothing here needs quoting.
  set -- "$@" /usr/bin/env
  while [ "$lha_count" -gt 0 ]; do
    lha_arg="$1"
    shift
    set -- "$@" "$lha_arg"
    lha_count=$((lha_count - 1))
  done

  # Nothing is armed before the call. `new-session` without `-A` creates
  # nothing when the name is taken, and a cleanup armed with a name we had
  # only planned to use would then kill the session already answering to
  # it — an agent of the user's that is still running.
  if ! lha_report=$("$LIMPID_AGENT_TMUX" "$@"); then
    printf 'limpid: not starting the agent: tmux could not create its session\n' >&2
    return 1
  fi
  IFS="$lha_tab" read -r lha_socket lha_session_id lha_window_id lha_pane_id \
    lha_server_pid lha_started <<LIMPID_TMUX_REPORT
$lha_report
LIMPID_TMUX_REPORT
  # A session exists from here on, so cleanup is armed before anything else
  # can fail. By id when tmux gave us one, since an id names one session
  # and nothing else; by the name we passed otherwise, which is ours
  # because the creation succeeded under it.
  limpid_host_session="$lha_session"
  case "${lha_session_id:-}" in
    '$'[0-9]*)
      if limpid_is_decimal "${lha_session_id#?}"; then
        limpid_host_session="$lha_session_id"
      fi
      ;;
  esac
  if ! limpid_host_report_is_whole; then
    printf 'limpid: not starting the agent: tmux did not say where it put the session\n' >&2
    return 1
  fi

  lha_tmp="$lha_requests/.$lha_leaf.json.tmp"
  limpid_host_tmp="$lha_tmp"
  # Written under a hidden name and renamed, so Limpid only ever sees a
  # whole request; 077 because the file says which server to attach to.
  if ! (
    umask 077
    printf '{"version":1,"socket":%s,"sessionID":%s,"sessionName":%s,"windowID":%s,"paneID":%s,"serverPID":%s,"serverStartedAt":%s,"leafID":%s,"launchPaneID":%s,"provider":%s}\n' \
      "$(limpid_json_string "$lha_socket")" \
      "$(limpid_json_string "$lha_session_id")" \
      "$(limpid_json_string "$lha_session")" \
      "$(limpid_json_string "$lha_window_id")" \
      "$(limpid_json_string "$lha_pane_id")" \
      "$(limpid_json_string "$lha_server_pid")" \
      "$(limpid_json_string "$lha_started")" \
      "$(limpid_json_string "$lha_leaf")" \
      "$(limpid_json_string "$lha_launch_pane")" \
      "$(limpid_json_string "${limpid_agent_provider:-}")" \
      > "$lha_tmp"
  ) || ! mv -f "$lha_tmp" "$lha_requests/$lha_leaf.json"; then
    printf 'limpid: not starting the agent: cannot ask for a tab in %s\n' "$lha_requests" >&2
    return 1
  fi

  limpid_host_tmp=""
  limpid_host_session=""
  trap - EXIT HUP INT TERM
  printf 'Opened in a Limpid tab.\n'
  return 0
}

# Every field tmux reported has the shape the request format promises.
# Checked here because the ids are spliced into tmux commands on the
# other side, and because an empty report is what a tmux too old for one
# of these variables would leave behind.
limpid_host_report_is_whole() {
  case "${lha_socket:-}" in /*) ;; *) return 1 ;; esac
  case "${lha_session_id:-}" in '$'[0-9]*) ;; *) return 1 ;; esac
  case "${lha_window_id:-}" in '@'[0-9]*) ;; *) return 1 ;; esac
  case "${lha_pane_id:-}" in '%'[0-9]*) ;; *) return 1 ;; esac
  limpid_is_decimal "${lha_session_id#?}" || return 1
  limpid_is_decimal "${lha_window_id#?}" || return 1
  limpid_is_decimal "${lha_pane_id#?}" || return 1
  limpid_is_decimal "${lha_server_pid:-}" || return 1
  limpid_is_decimal "${lha_started:-}" || return 1
  return 0
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
