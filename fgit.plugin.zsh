## === fgit (高速リポジトリ/プロジェクト移動) === 
fgit() {
  emulate -L zsh
  setopt localoptions pipefail no_aliases

  local base=${1:-$HOME}
  local depth=${FGIT_DEPTH:-5}

  # 直前に作ったプロジェクトも拾いたい場合の「目印ファイル」
  # ':' 区切りで上書き可。空にすると Git リポジトリのみ。
  local markers_default='package.json:pyproject.toml:Cargo.toml:go.mod:Gemfile:pom.xml:build.gradle:build.gradle.kts:Makefile:.tool-versions:Pipfile:poetry.lock'
  local markers=${FGIT_MARKERS:-$markers_default}

  # スキャン結果キャッシュ（短TTLで “連打/フォーカスリロード” を軽くする）
  # 0 で無効
  local cache_ttl=${FGIT_CACHE_TTL:-2}

  # スキャン除外（':' 区切り）
  local exclude=${FGIT_EXCLUDE:-'node_modules:.cache'}

  base=${base:A}
  if [[ ! -d $base ]]; then
    print -u2 "fgit: base is not a directory: $base"
    return 2
  fi
  if ! command -v fzf >/dev/null 2>&1; then
    print -u2 "fgit: fzf not found"
    return 127
  fi

  local base_q=${(q)base}
  local depth_q=${(q)depth}
  local markers_q=${(q)markers}
  local cache_ttl_q=${(q)cache_ttl}
  local exclude_q=${(q)exclude}

  # ---- 一覧生成（Git + markers） ----
  # ・fd があれば fd 優先
  # ・短TTLキャッシュ（1回の起動中に何度もreloadしても安定/高速）
  local cmd_list
  cmd_list="zsh -c '
    emulate -L zsh
    setopt pipefail no_aliases

    base=\$1
    depth=\$2
    markers_str=\$3
    ttl=\$4
    exclude_str=\$5

    local now=\${EPOCHSECONDS:-\$(date +%s)}
    local cache_dir=\${XDG_CACHE_HOME:-\$HOME/.cache}/fgit
    command mkdir -p -- \"\$cache_dir\" 2>/dev/null || true

    local key_src=\"\$base|\$depth|\$markers_str|\$exclude_str\"
    local key
    if command -v sha1sum >/dev/null 2>&1; then
      key=\$(print -nr -- \"\$key_src\" | sha1sum | awk \"{print \\$1}\")
    elif command -v shasum >/dev/null 2>&1; then
      key=\$(print -nr -- \"\$key_src\" | shasum -a 1 | awk \"{print \\$1}\")
    elif command -v md5sum >/dev/null 2>&1; then
      key=\$(print -nr -- \"\$key_src\" | md5sum | awk \"{print \\$1}\")
    elif command -v md5 >/dev/null 2>&1; then
      key=\$(print -nr -- \"\$key_src\" | md5 | awk \"{print \\$NF}\")
    else
      key=\$(print -nr -- \"\$key_src\" | cksum | awk \"{print \\$1}\")
    fi

    local cache_file=\"\$cache_dir/list-\$key.txt\"
    if (( ttl > 0 )) && [[ -f \$cache_file ]]; then
      local first=\$(command head -n 1 -- \"\$cache_file\" 2>/dev/null)
      if [[ \$first == \"#ts=\"* ]]; then
        local ts=\${first#\\#ts=}
        if [[ \$ts == <-> ]] && (( now - ts <= ttl )); then
          command tail -n +2 -- \"\$cache_file\" 2>/dev/null
          exit 0
        fi
      fi
    fi

    local tmp=\"\$cache_file.\$\$.\$RANDOM\"

    {
      print -r -- \"#ts=\$now\"

      # ---- Git repos ----
      if command -v fd >/dev/null 2>&1; then
        local fd_opts
        fd_opts=( -H -t d -t f --max-depth \"\$depth\" --regex \"^\\\\.git\$\" \"\$base\" )

        # 除外
        local ex
        for ex in \${(s.:.)exclude_str}; do
          [[ -n \$ex ]] && fd_opts+=( --exclude \"\$ex\" )
        done

        fd \"\${fd_opts[@]}\" -x echo {//} 2>/dev/null
      else
        # find fallback：.git 自体は降りない（-prune）で少し軽くする
        command find \"\$base\" -maxdepth \"\$depth\" \
          \\( -name .git -type d -prune -print -o -name .git -type f -print \\) 2>/dev/null \
          | sed \"s|/\\\\.git\$||\"
      fi

      # ---- non-git projects by marker files (markers_str が空ならスキップ) ----
      if [[ -n \$markers_str ]] && command -v fd >/dev/null 2>&1; then
        local mopts=( -H -t f --max-depth \"\$depth\" \"\$base\" )
        local ex
        for ex in \${(s.:.)exclude_str}; do
          [[ -n \$ex ]] && mopts+=( --exclude \"\$ex\" )
        done

        local m
        for m in \${(s.:.)markers_str}; do
          [[ -n \$m ]] || continue
          fd \"\${mopts[@]}\" -g \"\$m\" -x echo {//} 2>/dev/null
        done
      fi

    } | command grep -v \"/\\\\.git/\" | LC_ALL=C sort -u >| \"\$tmp\" && command mv -f -- \"\$tmp\" \"\$cache_file\"

    command tail -n +2 -- \"\$cache_file\" 2>/dev/null
  ' _ $base_q $depth_q $markers_q $cache_ttl_q $exclude_q"

  # ---- Grep (README*) ----
  # ※Grepモードでは fzf の検索を disable して「READMEでヒットしたがパスにクエリが無いので消える」を防ぐ
  local cmd_grep
  cmd_grep="zsh -c '
    emulate -L zsh
    setopt pipefail no_aliases

    q=\$1
    base=\$2
    exclude_str=\$3
    [[ -n \$q ]] || exit 0

    if command -v rg >/dev/null 2>&1; then
      local ropts=( --files-with-matches --glob \"README*\" --smart-case -- \"\$q\" \"\$base\" )
      local ex
      for ex in \${(s.:.)exclude_str}; do
        [[ -n \$ex ]] && ropts=( --glob \"!\$ex/**\" \"\${ropts[@]}\" )
      done
      rg \"\${ropts[@]}\" 2>/dev/null
    else
      # grep fallback（環境差があるので最低限）
      grep -rl --include=\"README*\" -- \"\$q\" \"\$base\" 2>/dev/null
    fi \
      | sed \"s|/[^/]*\$||\" \
      | command grep -v \"/\\\\.git/\" \
      | LC_ALL=C sort -u
  ' _ {q} $base_q $exclude_q"

  # ---- Preview（重い処理を抑える） ----
  local preview_cmd
  preview_cmd="zsh -c '
    emulate -L zsh
    setopt pipefail no_aliases

    target=\$1
    [[ -d \$target ]] || { print -r -- \"Not a directory: \$target\"; exit 0; }

    # bat / batcat
    local bat_cmd=
    if command -v bat >/dev/null 2>&1; then
      bat_cmd=bat
    elif command -v batcat >/dev/null 2>&1; then
      bat_cmd=batcat
    fi

    # git info（-uno で未追跡の走査を避けて安定化/高速化）
    if command -v git >/dev/null 2>&1 && git -C \"\$target\" rev-parse --git-dir >/dev/null 2>&1; then
      local br=\$(git -C \"\$target\" rev-parse --abbrev-ref HEAD 2>/dev/null)
      print -P \"%F{cyan}%B[git]%b%f \${br}\"
      git -C \"\$target\" status -sb -uno 2>/dev/null | head -n 20
      print
    fi

    # README（find ではなく glob で軽く拾う）
    local readme
    readme=(\"\$target\"/(#i)readme*(N[1]))
    if [[ -n \$readme ]]; then
      if [[ -n \$bat_cmd ]]; then
        \$bat_cmd --style=numbers --color=always --line-range :120 \"\$readme\"
      else
        command head -n 120 \"\$readme\"
      fi
      exit 0
    fi

    print -P \"%F{yellow}[No README found]%f\"
    if command -v eza >/dev/null 2>&1; then
      eza --tree --level=2 --color=always \"\$target\" 2>/dev/null | head -n 200
    elif command -v tree >/dev/null 2>&1; then
      tree -L 2 \"\$target\" 2>/dev/null | head -n 200
    else
      ls -F \"\$target\" 2>/dev/null | head -n 60
    fi
  ' _ {}"

  local selected
  selected=$(
    fzf --ansi \
      --layout=reverse --border --prompt='Repos> ' \
      --header=$'ENTER:Go | CTRL-G:Switch (Repos <-> Grep) | CTRL-R:Refresh | CTRL-P:Toggle preview' \
      --preview="$preview_cmd" \
      --preview-window='right:60%:border-rounded:wrap' \
      --bind "start:reload:$cmd_list" \
      --bind "focus:reload:$cmd_list" \
      --bind "ctrl-p:toggle-preview" \
      --bind "ctrl-r:transform:
        if [[ \"{fzf:prompt}\" == \"Grep> \" ]]; then
          echo 'reload($cmd_grep)'
        else
          echo 'reload($cmd_list)'
        fi" \
      --bind "ctrl-g:transform:
        if [[ \"{fzf:prompt}\" == \"Repos> \" ]]; then
          echo 'change-prompt(Grep> )+disable-search+clear-query+rebind(change)+reload($cmd_grep)'
        else
          echo 'change-prompt(Repos> )+enable-search+clear-query+unbind(change)+reload($cmd_list)'
        fi" \
      --bind "change:transform:
        if [[ \"{fzf:prompt}\" == \"Grep> \" ]]; then
          echo 'reload(sleep 0.12; $cmd_grep)'
        fi"
  )

  if [[ -n $selected && -d $selected ]]; then
    builtin cd -- "$selected" || return 1
    print -P "Moved to %F{green}$selected%f"
  fi
}

