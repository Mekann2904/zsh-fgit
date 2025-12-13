## === fgit (高速リポジトリ移動) ===
fgit() {
  emulate -L zsh
  setopt localoptions pipefail no_aliases

  local base=${1:-$HOME}
  local depth=${FGIT_DEPTH:-5}

  base=${base:A}
  if [[ ! -d $base ]]; then
    print -u2 "fgit: base is not a directory: $base"
    return 2
  fi
  if ! command -v fzf >/dev/null 2>&1; then
    print -u2 "fgit: fzf not found"
    return 127
  fi

  # 外側シェル（この関数）用にクォート済みの base
  local base_q=${(q)base}
  local depth_q=${(q)depth}

  # bat / batcat 吸収
  local bat_cmd=bat
  command -v bat >/dev/null 2>&1 || { command -v batcat >/dev/null 2>&1 && bat_cmd=batcat; }

  # リポジトリ列挙（.git がディレクトリ/ファイル両方に対応。/.git/ 配下は除外）
  local cmd_repos
  cmd_repos="zsh -c '
    base=\$1
    depth=\$2

    if command -v fd >/dev/null 2>&1; then
      fd -H -I -t d -t f --max-depth \"\$depth\" \"^\\\\.git\$\" \"\$base\" -x echo {//} 2>/dev/null
    else
      find \"\$base\" -maxdepth \"\$depth\" \\( -name .git -type d -o -name .git -type f \\) 2>/dev/null \
        | sed \"s|/\\\\.git\$||\"
    fi \
      | command grep -v \"/\\\\.git/\" \
      | LC_ALL=C sort -u
  ' _ $base_q $depth_q"

  # README 内を検索して候補ディレクトリを返す（クエリは引数で受け取る）
  local cmd_grep
  cmd_grep="zsh -c '
    q=\$1
    base=\$2
    [[ -n \$q ]] || exit 0

    if command -v rg >/dev/null 2>&1; then
      rg --files-with-matches --glob \"README*\" --smart-case -- \"\$q\" \"\$base\" 2>/dev/null
    else
      grep -rl --include=\"README*\" -- \"\$q\" \"\$base\" 2>/dev/null
    fi \
      | sed \"s|/[^/]*\$||\" \
      | command grep -v \"/\\\\.git/\" \
      | LC_ALL=C sort -u
  ' _ {q} $base_q"

  # プレビュー（README 優先。ついでに軽い Git 情報を表示）
  local preview_cmd
  preview_cmd="zsh -c '
    target=\$1
    [[ -d \$target ]] || { print -r -- \"Not a directory: \$target\"; exit 0; }

    if command -v git >/dev/null 2>&1 && git -C \"\$target\" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      print -P \"%F{cyan}%B[git]%b%f \$(git -C \"\$target\" rev-parse --abbrev-ref HEAD 2>/dev/null)\"
      git -C \"\$target\" status -sb 2>/dev/null | head -n 20
      print
    fi

    readme=\$(find \"\$target\" -maxdepth 1 -iname \"readme*\" -type f -print -quit 2>/dev/null)
    if [[ -n \$readme ]]; then
      if command -v $bat_cmd >/dev/null 2>&1; then
        $bat_cmd --style=numbers --color=always --line-range :120 \"\$readme\"
      else
        head -n 120 \"\$readme\"
      fi
      exit 0
    fi

    print -P \"%F{yellow}[No README found]%f\"
    if command -v eza >/dev/null 2>&1; then
      eza --tree --level=2 --color=always \"\$target\" 2>/dev/null | head -n 200
    elif command -v tree >/dev/null 2>&1; then
      tree -L 2 \"\$target\" 2>/dev/null | head -n 200
    else
      ls -F \"\$target\" 2>/dev/null | head -n 40
    fi
  ' _ {}"

  local selected
  selected=$(
    fzf --ansi \
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

  if [[ -n $selected && -d $selected ]]; then
    builtin cd -- "$selected" || return 1
    print -P "Moved to %F{green}$selected%f"
  fi
}

