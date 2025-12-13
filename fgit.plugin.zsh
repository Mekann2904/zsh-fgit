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

  # --- 1. コマンドの事前解決 (ループ内で判定しない) ---

  # ls / tree コマンド
  local list_cmd="ls -F"
  if command -v eza >/dev/null 2>&1; then
    list_cmd="eza --tree --level=2 --color=always"
  elif command -v tree >/dev/null 2>&1; then
    list_cmd="tree -L 2"
  fi

  # bat / cat コマンド
  local cat_cmd="head -n 120"
  if command -v bat >/dev/null 2>&1; then
    cat_cmd="bat --style=numbers --color=always --line-range :120"
  elif command -v batcat >/dev/null 2>&1; then
    cat_cmd="batcat --style=numbers --color=always --line-range :120"
  fi

  # リポジトリ検索コマンド (fd 優先)
  # .git フォルダ/ファイルを探し、その親ディレクトリ(リポジトリルート)を表示
  local cmd_repos_run
  if command -v fd >/dev/null 2>&1; then
    # fd: -H(隠し) -I(ignore無視) -t d/f(dir/file)
    # {//} で親ディレクトリのみ出力するため sed 不要
    cmd_repos_run="fd -H -I -t d -t f --max-depth $depth '^\\.git$' ${(q)base} -x echo {//}"
  else
    # find: 遅いがフォールバック用
    cmd_repos_run="find ${(q)base} -maxdepth $depth \\( -name .git -type d -o -name .git -type f \\) 2>/dev/null | sed 's|/\\.git\$||'"
  fi
  # 共通フィルタ: /.git/ 配下を除外してソート
  local cmd_repos="$cmd_repos_run | grep -v '/\\.git/' | LC_ALL=C sort -u"

  # README検索コマンド (rg 優先)
  local cmd_grep_gen
  if command -v rg >/dev/null 2>&1; then
    # rg: -m 1 (1行マッチしたら次へ), -l (ファイル名のみ), --no-messages
    # sed でファイル名を除去して親ディレクトリ化
    cmd_grep_gen() {
      echo "rg --files-with-matches --max-count 1 --glob 'README*' --smart-case --no-messages -- \"$1\" ${(q)base} | sed 's|/[^/]*\$||' | grep -v '/\\.git/' | LC_ALL=C sort -u"
    }
  else
    cmd_grep_gen() {
      echo "grep -rl --include='README*' -- \"$1\" ${(q)base} 2>/dev/null | sed 's|/[^/]*\$||' | grep -v '/\\.git/' | LC_ALL=C sort -u"
    }
  fi

  # --- 2. Preview コマンドの最適化 ---
  # シェル変数を埋め込んで、fzf内で条件分岐を極力減らす
  # git status は重い場合があるのでタイムアウトなどを考慮しても良いが、ここではシンプルに保持
  local preview_cmd="
    target={}; 
    if [ -d \"\$target\" ]; then
      if [ -d \"\$target/.git\" ] || [ -f \"\$target/.git\" ]; then
        echo -e \"\x1b[36m[git]\x1b[m \$(git -C \"\$target\" rev-parse --abbrev-ref HEAD 2>/dev/null)\";
        git -C \"\$target\" status -sb 2>/dev/null | head -n 20;
        echo;
      fi;
      readme=\$(find \"\$target\" -maxdepth 1 -iname \"readme*\" -type f -print -quit 2>/dev/null);
      if [ -n \"\$readme\" ]; then
        $cat_cmd \"\$readme\";
      else
        echo -e \"\x1b[33m[No README found]\x1b[m\";
        $list_cmd \"\$target\" 2>/dev/null | head -n 200;
      fi;
    else
      echo \"Not a directory: \$target\";
    fi
  "
  # 改行を詰めて1行にする（fzfへの渡しやすさのため）
  preview_cmd=${preview_cmd//  /} 
  preview_cmd=${preview_cmd//$'\n'/ }

  # --- 3. FZF 実行 ---

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
          echo 'change-prompt(Grep> )+clear-query+rebind(change)+reload:$(cmd_grep_gen {q})'
        else
          echo 'change-prompt(Repos> )+unbind(change)+reload($cmd_repos)'
        fi" \
      --bind "change:transform:
        if [[ \"{fzf:prompt}\" == \"Grep> \" ]]; then
          echo 'reload:$(cmd_grep_gen {q})'
        fi"
  )

  if [[ -n $selected && -d $selected ]]; then
    builtin cd -- "$selected" || return 1
    print -P "Moved to %F{green}$selected%f"
  fi
}

