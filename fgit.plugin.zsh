## === fgit (高速リポジトリ移動) ===
fgit() {
  emulate -L zsh
  local base=${1:-$HOME}
  local cmd_repos cmd_grep

  if command -v fd >/dev/null 2>&1; then
    cmd_repos="fd -H -I -t d --max-depth 5 '^.git$' '$base' -x echo {//}"
  else
    cmd_repos="find '$base' -maxdepth 5 -name .git -type d 2>/dev/null | sed 's|/\.git$||'"
  fi

  if command -v rg >/dev/null 2>&1; then
    cmd_grep="rg --files-with-matches --glob 'README*' --smart-case {q} '$base' | sed 's|/[^/]*$||'"
  else
    cmd_grep="grep -rl --include='README*' {q} '$base' 2>/dev/null | sed 's|/[^/]*$||'"
  fi

  local preview_cmd='
    target={}
    if [ -d "$target" ]; then
      readme=$(find "$target" -maxdepth 1 -iname "readme*" -print -quit 2>/dev/null)
      if [ -n "$readme" ]; then
        if command -v bat >/dev/null 2>&1; then
          bat --style=numbers --color=always --line-range :100 "$readme"
        else
          head -n 100 "$readme"
        fi
      else
        echo "\x1b[33m[No README found]\x1b[0m"
        if command -v eza >/dev/null 2>&1; then
          eza --tree --level=1 --color=always "$target"
        else
          ls -F --color=always "$target" | head -n 20
        fi
      fi
    else
      echo "Not a directory: $target"
    fi
  '

  local selected
  selected=$(fzf --ansi \
    --layout=reverse --border --prompt='Repos> ' \
    --header='ENTER:Go | CTRL-G:Switch Mode (Repos <-> Grep)' \
    --preview="$preview_cmd" \
    --preview-window='right:60%:border-rounded:wrap' \
    --bind "start:reload:$cmd_repos" \
    --bind "ctrl-g:transform:
      if [[ \"{fzf:prompt}\" == \"Repos> \" ]]; then
        echo 'change-prompt(Grep> )+clear-query+rebind(change)+reload($cmd_grep)'
      else
        echo 'change-prompt(Repos> )+unbind(change)+reload($cmd_repos)'
      fi" \
    --bind "change:transform:
      if [[ \"{fzf:prompt}\" == \"Grep> \" ]]; then
        echo 'reload($cmd_grep)'
      fi"
  )

  if [[ -n "$selected" && -d "$selected" ]]; then
    cd "$selected" || return 1
    echo "Moved to \033[32m$selected\033[0m"
  fi
}

