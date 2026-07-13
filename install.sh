#!/bin/zsh
# ProjBar kurulumu: script'leri yerine koy, app'i derle-kur.
# NOT: ~/.claude/settings.json hook'unu ELLE ekle (config/claude-hook-snippet.json).
set -e
cd "$(dirname "$0")"
mkdir -p "$HOME/.local/bin"
cp bin/projbar-set bin/projbar-hook bin/projbar-task bin/projbar-session-end "$HOME/.local/bin/"
chmod +x "$HOME/.local/bin/"projbar-*
if [ ! -f "$HOME/.tmux-proj.zsh" ]; then
  cp shell/tmux-proj.zsh "$HOME/.tmux-proj.zsh"
  grep -q "tmux-proj.zsh" "$HOME/.zshrc" 2>/dev/null || \
    printf '\n[ -f "$HOME/.tmux-proj.zsh" ] && source "$HOME/.tmux-proj.zsh"\n' >> "$HOME/.zshrc"
else
  echo "~/.tmux-proj.zsh zaten var — üzerine yazılmadı (repo kopyası: shell/tmux-proj.zsh)"
fi
./build.sh
