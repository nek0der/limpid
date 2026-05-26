# Limpid claude-shim zdotdir/.zshrc
# Forward to the user's real ~/.zshrc so all their interactive shell
# customisation (aliases, plugins, prompt) loads normally, then put
# the Limpid claude shim back at the front of PATH. Without this,
# `.zshrc` lines like `export PATH="/opt/homebrew/bin:$PATH"` push
# the shim past `/opt/homebrew/bin/claude` and our hook never fires.

if [[ -f "$HOME/.zshrc" ]]; then
  source "$HOME/.zshrc"
fi

# Re-prepend the shim. `typeset -aU` keeps PATH unique-on-the-fly so
# repeated tabs / sourcing won't grow it unbounded.
if [[ -n "$LIMPID_SHIM_DIR" && -d "$LIMPID_SHIM_DIR" ]]; then
  typeset -aU path
  path=("$LIMPID_SHIM_DIR" $path)
  export PATH
fi
