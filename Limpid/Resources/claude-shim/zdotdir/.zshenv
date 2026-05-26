# Limpid claude-shim zdotdir/.zshenv
# Forward to the user's real ~/.zshenv so their environment loads
# normally even though we relocated ZDOTDIR. We keep ZDOTDIR set so
# zsh continues to read the rest of its startup files from this
# Limpid-managed directory.

if [[ -f "$HOME/.zshenv" ]]; then
  source "$HOME/.zshenv"
fi
