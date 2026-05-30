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

  # --- 0. 除外したいディレクトリの設定 ---
  # uv, conda, npm, cargo などのキャッシュやシステムディレクトリを指定
  local ignore_dirs=(
    ".cache"        # uv, pip, yarn などのキャッシュ
    "anaconda3"     # Anaconda
    "miniconda3"    # Miniconda
    ".conda"        # Conda environments
    ".npm"          # npm cache
    "node_modules"  # プロジェクト内の依存パッケージ
    ".cargo"        # Rust cargo registry
    ".pyenv"        # pyenv versions (ソースコードを含む場合があるため)
    ".rbenv"        # rbenv versions
    "Library"       # macOS Library
    ".local"        # Linux local/share など
    "go"            # Go path (意図して管理している場合は外してください)
  )

  # --- 1. コマンドの事前解決 ---

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

  # --- 2. 検索コマンドの構築 (除外設定の反映) ---

  local cmd_repos_run
  local cmd_grep_base

  if command -v fd >/dev/null 2>&1; then
    # fd 用の除外オプション生成 (-E "dir1" -E "dir2" ...)
    local fd_excludes=""
    for d in $ignore_dirs; do fd_excludes+=" -E ${(q)d}"; done
    
    # リポジトリ検索 (fd) — base からの相対パスで出力（fzf マッチが /Users/... に汚染されないように）
    cmd_repos_run="fd -H -I -t d -t f --max-depth $depth --base-directory ${(q)base} $fd_excludes '^\\.git$' -x echo {//}"
    
    # Grep検索用 (rg) - fdと同様の除外をglobで指定
    local rg_excludes=""
    for d in $ignore_dirs; do rg_excludes+=" --glob '!${(q)d}'"; done
    
    cmd_grep_base="cd ${(q)base} && rg --files-with-matches --max-count 1 --glob 'README*' --smart-case --no-messages $rg_excludes"
    cmd_grep_gen() {
      echo "$cmd_grep_base -- \"$1\" . 2>/dev/null | sed 's|/[^/]*\$||' | grep -v '/\\.git/' | LC_ALL=C sort -u"
    }

  else
    # find 用の除外オプション生成 (-name "dir1" -prune -o -name "dir2" -prune -o ...)
    local find_prunes=""
    for d in $ignore_dirs; do find_prunes+=" -name ${(q)d} -prune -o"; done
    
    # リポジトリ検索 (find) — base からの相対パスで出力
    cmd_repos_run="cd ${(q)base} && find . -maxdepth $depth \\( $find_prunes -name .git -type d -print -o -name .git -type f -print \\) 2>/dev/null | sed 's|/\\.git\$||' | sed 's|^\\./||'"
    
    # Grep検索用 (grep) - grepはディレクトリ除外が苦手なので、findで見つけてからgrepする形か、exclude-dirを使用
    # ここではシンプルにするため --exclude-dir が使える前提(GNU grep)または findベース
    cmd_grep_gen() {
      echo "cd ${(q)base} && grep -rl --include='README*' -- \"$1\" . 2>/dev/null | sed 's|/[^/]*\$||' | grep -v '/\\.git/' | LC_ALL=C sort -u"
    }
  fi

  # 共通フィルタ（fd/find の出力は base 相対）
  local cmd_repos="$cmd_repos_run | grep -v '/\\.git/' | LC_ALL=C sort -u"


  # --- 3. Preview コマンド（{} は base 相対なので絶対パスに復元） ---
  local preview_cmd="
    target=\"${base}/{}\";
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
  preview_cmd=${preview_cmd//  /} 
  preview_cmd=${preview_cmd//$'\n'/ }

  # --- 4. FZF 実行 ---

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

  # 選択結果は base 相対なので絶対パスに復元
  if [[ -n $selected ]]; then
    local full_path="${base}/${selected}"
    if [[ -d $full_path ]]; then
      builtin cd -- "$full_path" || return 1
      print -P "Moved to %F{green}$full_path%f"
    fi
  fi
}

