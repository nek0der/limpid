# Weir claude-shim zdotdir/.zshenv
# Forward to the user's real ~/.zshenv so their environment loads
# normally even though we relocated ZDOTDIR. We keep ZDOTDIR set so
# zsh continues to read the rest of its startup files from this
# Weir-managed directory.

if [[ -f "$HOME/.zshenv" ]]; then
  source "$HOME/.zshenv"
fi
