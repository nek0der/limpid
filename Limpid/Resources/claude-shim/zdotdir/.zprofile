# Limpid claude-shim zdotdir/.zprofile
# Login-shell file; forward to the user's real ~/.zprofile.

if [[ -f "$HOME/.zprofile" ]]; then
  source "$HOME/.zprofile"
fi
