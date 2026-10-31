# Weir claude-shim zdotdir/.zshrc
# Forward to the user's real ~/.zshrc so all their interactive shell
# customisation (aliases, plugins, prompt) loads normally, then put
# the Weir claude shim back at the front of PATH. Without this,
# `.zshrc` lines like `export PATH="/opt/homebrew/bin:$PATH"` push
# the shim past `/opt/homebrew/bin/claude` and our hook never fires.

if [[ -f "$HOME/.zshrc" ]]; then
  source "$HOME/.zshrc"
fi

# /etc/zshrc (system-wide, loaded before this file) does
#   HISTFILE=${ZDOTDIR:-$HOME}/.zsh_history
# unconditionally. Because we relocated ZDOTDIR to the read-only
# `claude-shim/zdotdir/` directory inside the signed app bundle,
# that resolves to a path zsh can't lock — every interactive shell
# prints `locking failed for .../zsh_history: operation not
# permitted: reading anyway` and silently fails to persist history.
# Redirect to $HOME/.zsh_history after both /etc/zshrc and the
# user's ~/.zshrc have had their say, but only when the value
# still looks like /etc/zshrc's untouched default — that way a
# user who explicitly set HISTFILE in their own dotfile keeps
# their choice.
if [[ "$HISTFILE" == "$ZDOTDIR/.zsh_history" ]]; then
  HISTFILE="$HOME/.zsh_history"
fi

# Re-prepend the shims. `typeset -aU` keeps PATH unique-on-the-fly so
# repeated tabs / sourcing won't grow it unbounded. Both agents need this:
# whichever directory the user's own PATH edits push down stops
# intercepting, and the hooks for that agent silently never load.
typeset -aU path
for _weir_shim in "${WEIR_SHIM_DIR:-}" "${WEIR_CODEX_SHIM_DIR:-}"; do
  if [[ -n "$_weir_shim" && -d "$_weir_shim" ]]; then
    path=("$_weir_shim" $path)
    export PATH
  fi
done
builtin unset _weir_shim

# Record the PATH this shell ended up with, after the user's .zshrc has
# turned on whatever version manager (nvm, mise, asdf, volta, ...) adds to
# it. Weir's new workspace sheet looks for the installed agents on this
# PATH: the login shell it can ask itself reads only .zprofile, and would
# miss an agent installed under one of them. Each project's panes name a
# record of their own, and a scratch pane none: this PATH can hold the
# pane's own folders ($PWD/bin), which must never start as another
# project's agent (`AgentCatalog.panePathRecordURL`). We write the record
# to a temporary file and move it into place, so a reader never sees half a
# line; zsh's own mv saves a fork per shell. Errors are dropped: the record
# is a hint.
if [[ -n "${WEIR_PANE_PATH_RECORD:-}" && -d "${WEIR_PANE_PATH_RECORD:h}" ]]; then
  {
    builtin print -r -- "$PATH" >| "${WEIR_PANE_PATH_RECORD}.$$" &&
      if builtin zmodload -F zsh/files b:zf_mv 2>/dev/null; then
        zf_mv -f -- "${WEIR_PANE_PATH_RECORD}.$$" "$WEIR_PANE_PATH_RECORD"
      else
        command mv -f -- "${WEIR_PANE_PATH_RECORD}.$$" "$WEIR_PANE_PATH_RECORD"
      fi
  } 2>/dev/null
fi

# Chain Ghostty's zsh shell integration. Relocating ZDOTDIR for the
# shim bypasses libghostty's own integration (it also injects via
# ZDOTDIR), which otherwise silently disables OSC 7 cwd reporting,
# prompt marks (OSC 133), and title updates. We run the integration
# script ourselves — it is explicitly safe to source manually (unlike
# Ghostty's own zdotdir/.zshenv) and re-orders its hooks last, so it
# coexists with the user's starship/fnm/zsh-* precmd hooks loaded
# above. `GHOSTTY_RESOURCES_DIR` is exported by Weir before
# `ghostty_init` (see `GhosttyApp.bootstrap`).
if [[ -o interactive && -n "$GHOSTTY_RESOURCES_DIR" ]]; then
  _weir_gi="$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"
  if [[ -r "$_weir_gi" ]]; then
    builtin autoload -Uz -- "$_weir_gi"
    ghostty-integration
    builtin unfunction -- ghostty-integration 2>/dev/null
  fi
  builtin unset _weir_gi
fi
