# Limpid claude-shim zdotdir/.zshrc
# Forward to the user's real ~/.zshrc so all their interactive shell
# customisation (aliases, plugins, prompt) loads normally, then put
# the Limpid claude shim back at the front of PATH. Without this,
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

# Re-prepend the shim. `typeset -aU` keeps PATH unique-on-the-fly so
# repeated tabs / sourcing won't grow it unbounded.
if [[ -n "$LIMPID_SHIM_DIR" && -d "$LIMPID_SHIM_DIR" ]]; then
  typeset -aU path
  path=("$LIMPID_SHIM_DIR" $path)
  export PATH
fi

# Chain Ghostty's zsh shell integration. Relocating ZDOTDIR for the
# shim bypasses libghostty's own integration (it also injects via
# ZDOTDIR), which otherwise silently disables OSC 7 cwd reporting,
# prompt marks (OSC 133), and title updates. We run the integration
# script ourselves — it is explicitly safe to source manually (unlike
# Ghostty's own zdotdir/.zshenv) and re-orders its hooks last, so it
# coexists with the user's starship/fnm/zsh-* precmd hooks loaded
# above. `GHOSTTY_RESOURCES_DIR` is exported by Limpid before
# `ghostty_init` (see `GhosttyApp.bootstrap`).
if [[ -o interactive && -n "$GHOSTTY_RESOURCES_DIR" ]]; then
  _limpid_gi="$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"
  if [[ -r "$_limpid_gi" ]]; then
    builtin autoload -Uz -- "$_limpid_gi"
    ghostty-integration
    builtin unfunction -- ghostty-integration 2>/dev/null
  fi
  builtin unset _limpid_gi
fi
