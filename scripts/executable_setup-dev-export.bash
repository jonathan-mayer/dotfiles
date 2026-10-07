# dev-export / dev-import - move a $dev_dir setup to another machine
#
# dev-export writes a single tar.gz containing:
#   manifest.json      manually cloned repos (+ remotes), dev aliases and the
#                      space.json of every space
#   ignored.tar.gz     optional, gitignored files picked interactively
#
# Repos of the glab group tree ($dev_group_dir) are not listed, dev-import
# recreates them with dev-reclone. Branches are never recorded. Repos nested
# inside another repo (that are not submodules) are ignored.

_DEV_EXPORT_VERSION=1

# path components that are never offered when exporting gitignored files
_dev_export_skip_dirs=(
  node_modules build dist out target bin .venv venv __pycache__ .pytest_cache
  .mypy_cache .tox .gradle .next .nuxt .cache .terraform coverage .turbo
  .docusaurus .svelte-kit .parcel-cache .terragrunt-cache
)
# file name globs that are never offered when exporting gitignored files
_dev_export_skip_globs=('*.tsbuildinfo' '*.pyc')

# ask a yes/no question, default no
_dev_confirm() {
  local reply
  printf '%s [y/N] ' "$1"
  IFS= read -r reply || return 1
  [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]]
}

# encode an absolute path for the manifest: relative to $dev_dir, ~/... or absolute
_dev_export_encode_path() {
  local p="$1"
  if [[ "$p" == "$dev_dir" ]]; then
    printf '.\n'
  elif [[ "$p" == "$dev_dir"/* ]]; then
    printf '%s\n' "${p#"$dev_dir"/}"
  elif [[ "$p" == "$HOME"/* ]]; then
    printf '~/%s\n' "${p#"$HOME"/}"
  else
    printf '%s\n' "$p"
  fi
}

# reverse of _dev_export_encode_path
_dev_import_decode_path() {
  local p="$1"
  case "$p" in
    .)     printf '%s\n' "$dev_dir" ;;
    /*)    printf '%s\n' "$p" ;;
    "~/"*) printf '%s\n' "$HOME/${p#"~/"}" ;;
    *)     printf '%s\n' "$dev_dir/$p" ;;
  esac
}

# namespace path of a git remote url
#   git@host:a/b.git | ssh://git@host:22/a/b.git | https://host/a/b -> a/b
_dev_url_path() {
  local url="$1"
  if [[ "$url" == *://* ]]; then
    url="${url#*://}" # scheme
    url="${url#*/}"   # [user@]host[:port]
  else
    url="${url#*:}"   # scp-like syntax
  fi
  url="${url%/}"
  printf '%s\n' "${url%.git}"
}

# remove user/token from http(s) urls
_dev_url_strip_creds() {
  sed -E 's#^(https?://)[^/@]*@#\1#' <<<"$1"
}

# find repos (real .git directories) below $dev_dir
# prints "R<TAB>path" for top-level repos and "N<TAB>path" for repos nested in another repo
_dev_export_find_repos() {
  local -a all=()
  local g
  while IFS= read -r -d '' g; do
    [[ "${g%/.git}" == "$dev_dir" ]] && continue
    all+=("${g%/.git}")
  done < <(find -H "$dev_dir" \( -name node_modules -o -path "$dev_dir/space" -o -path "$dev_dir/.tmp" \
    -o -path "$dev_tmp_dir" \) -prune -o -name .git -type d -prune -print0 2>/dev/null)

  local -A isrepo=()
  local r p kind
  for r in "${all[@]}"; do isrepo["$r"]=1; done

  for r in "${all[@]}"; do
    kind=R
    p="${r%/*}"
    while [[ "$p" == "$dev_dir"/* ]]; do
      if [[ -n "${isrepo[$p]:-}" ]]; then
        kind=N
        break
      fi
      p="${p%/*}"
    done
    printf '%s\t%s\n' "$kind" "$r"
  done | sort -t $'\t' -k2
}

# local state of a repo: space separated flags out of noremote dirty stash unpushed
_dev_export_repo_state() {
  local r="$1"
  local -a flags=()
  [[ -z "$(git -C "$r" remote 2>/dev/null)" ]] && flags+=(noremote)
  [[ -n "$(git -C "$r" status --porcelain 2>/dev/null | head -n1)" ]] && flags+=(dirty)
  git -C "$r" rev-parse -q --verify refs/stash >/dev/null 2>&1 && flags+=(stash)
  if [[ " ${flags[*]} " != *" noremote "* &&
    -n "$(git -C "$r" log --branches --not --remotes --oneline -n1 2>/dev/null)" ]]; then
    flags+=(unpushed)
  fi
  printf '%s\n' "${flags[*]}"
}

# gitignored entries of a repo (relative to the repo, NUL separated), without
# build/dependency dirs and nested repos
_dev_export_ignored_candidates() {
  local r="$1" e comp s skip
  local -A skipset=()
  for s in "${_dev_export_skip_dirs[@]}"; do skipset["$s"]=1; done

  local -a parts
  while IFS= read -r -d '' e; do
    e="${e%/}"
    skip=0
    IFS=/ read -ra parts <<<"$e"
    for comp in "${parts[@]}"; do
      if [[ -n "${skipset[$comp]:-}" ]]; then
        skip=1
        break
      fi
    done
    for s in "${_dev_export_skip_globs[@]}"; do
      # shellcheck disable=SC2053 # glob match intended
      [[ "${e##*/}" == $s ]] && skip=1
    done
    ((skip)) && continue
    [[ -e "$r/$e/.git" ]] && continue
    printf '%s\0' "$e"
  done < <(git -C "$r" ls-files -z --others --ignored --exclude-standard --directory --no-empty-directory 2>/dev/null)
}

# show a gitignored file or directory
_dev_export_view() {
  local p="$1"
  if [[ -d "$p" ]]; then
    {
      ls -la -- "$p"
      printf '\n-- contents (max 200 entries) --\n'
      find "$p" -mindepth 1 -printf '%P\n' 2>/dev/null | sort | head -n 200
    } | less -FRX
  elif [[ ! -s "$p" ]] || grep -Iq . -- "$p" 2>/dev/null; then
    less -FRX -- "$p"
  else
    printf '    binary file: %s\n' "$(file -b -- "$p" 2>/dev/null)"
  fi
}

# interactively pick gitignored entries of one repo
# appends picks (relative to $dev_dir) to $3, returns 3 when the user quits
_dev_export_pick_ignored() {
  local r="$1" rel="$2" out="$3"
  local -a cands=()
  mapfile -d '' -t cands < <(_dev_export_ignored_candidates "$r")
  ((${#cands[@]})) || return 0

  printf '\n%s (%d gitignored)\n' "$rel" "${#cands[@]}"
  local e size reply suffix all=0
  for e in "${cands[@]}"; do
    if ((all)); then
      printf '%s\n' "$rel/$e" >>"$out"
      printf '  + %s\n' "$e"
      continue
    fi
    size="$(du -sh -- "$r/$e" 2>/dev/null | cut -f1)"
    suffix=""
    [[ -d "$r/$e" && ! -L "$r/$e" ]] && suffix="/"
    while true; do
      printf '  %s%s (%s) [y/n/v/a/s/q/?] ' "$e" "$suffix" "${size:-?}"
      IFS= read -r reply || return 3
      case "$reply" in
        y|Y)    printf '%s\n' "$rel/$e" >>"$out"; break ;;
        n|N|"") break ;;
        v|V)    _dev_export_view "$r/$e" ;;
        a|A)    printf '%s\n' "$rel/$e" >>"$out"; all=1; break ;;
        s|S)    return 0 ;;
        q|Q)    return 3 ;;
        *)
          printf '    y = include, n = skip (default), v = view, a = include this and the rest of the repo,\n'
          printf '    s = skip the rest of the repo, q = stop selecting (keeps what was picked)\n'
          ;;
      esac
    done
  done
}

_dev_export_help() {
  printf 'usage: dev-export [-o FILE] [--no-ignored]\n\n'
  printf 'Export the %s setup into a single tar.gz for dev-import on another machine:\n' "$dev_dir"
  printf '  - manually cloned repos with their remotes, confirmed per repo (default yes)\n'
  printf '    (glab group repos are recreated by dev-reclone and not listed)\n'
  printf '  - dev aliases (symlinks to repos) and space.json of every space\n'
  printf '  - optionally gitignored files, confirmed per entry\n\n'
  printf 'options:\n'
  printf '  -o, --output FILE   output file (default: ~/dev-export-<host>-<date>.tar.gz)\n'
  printf '      --no-ignored    do not ask about gitignored files\n'
  printf '  -h, --help          show this help\n'
}

# runs in a subshell so the cleanup trap and shell options stay local
dev-export() (
  local out="" ask_ignored=1
  while (($#)); do
    case "$1" in
      -o|--output)
        [[ -n "${2:-}" ]] || { echo "dev-export: $1 needs a file" >&2; exit 1; }
        out="$2"
        shift 2
        ;;
      --no-ignored) ask_ignored=0; shift ;;
      -h|--help) _dev_export_help; exit 0 ;;
      *) _dev_export_help >&2; exit 1 ;;
    esac
  done

  local tool
  for tool in jq git tar; do
    command -v "$tool" >/dev/null || { echo "dev-export: $tool is required" >&2; exit 1; }
  done
  [[ -d "$dev_dir" ]] || { echo "dev-export: no such directory: $dev_dir" >&2; exit 1; }

  local host="${HOSTNAME:-$(uname -n)}"
  out="${out:-$HOME/dev-export-${host%%.*}-$(date +%Y%m%d-%H%M).tar.gz}"
  out="${out/#\~/$HOME}"
  if [[ -e "$out" ]] && ! _dev_confirm "dev-export: $out exists, overwrite?"; then
    echo "Aborted."
    exit 0
  fi

  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dev-export.XXXXXX")" || exit 1
  trap 'rm -rf -- "$tmp"' EXIT
  trap 'exit 130' INT TERM
  shopt -s nullglob dotglob

  # --- repos -----------------------------------------------------------------
  local -a repos=() nested=()
  local kind path
  while IFS=$'\t' read -r kind path; do
    if [[ "$kind" == R ]]; then repos+=("$path"); else nested+=("$path"); fi
  done < <(_dev_export_find_repos)

  echo "dev-export: inspecting ${#repos[@]} repos under $dev_dir ..."

  local i max_jobs=8
  for i in "${!repos[@]}"; do
    _dev_export_repo_state "${repos[$i]}" >"$tmp/state.$i" &
    while (($(jobs -rp | wc -l) >= max_jobs)); do wait -n; done
  done
  wait

  local -a manual=() group=() noremote=() changes=()
  local -A manual_origin=()
  local r rel key url name origin state
  : >"$tmp/repos.all.tsv"
  for i in "${!repos[@]}"; do
    r="${repos[$i]}"
    rel="${r#"$dev_dir"/}"
    state="$(<"$tmp/state.$i")"

    if [[ " $state " == *" noremote "* ]]; then
      noremote+=("$rel")
      continue
    fi

    local -a remote_lines=()
    mapfile -t remote_lines < <(git -C "$r" config --get-regexp '^remote\..*\.url$' 2>/dev/null)
    origin=""
    for key in "${remote_lines[@]}"; do
      url="${key#* }"
      name="${key%% *}"
      name="${name#remote.}"
      name="${name%.url}"
      [[ "$name" == origin ]] && origin="$url"
    done

    if [[ -n "$state" ]]; then
      changes+=("$(printf '%-50s %s' "$rel" "$state")")
    fi

    if [[ "$r" == "$dev_group_dir"/* && -n "$origin" &&
      "$(_dev_url_path "$origin")" == "$gitlab_group/${r#"$dev_group_dir"/}" ]]; then
      group+=("$rel")
      continue
    fi

    manual+=("$rel")
    for key in "${remote_lines[@]}"; do
      url="$(_dev_url_strip_creds "${key#* }")"
      name="${key%% *}"
      name="${name#remote.}"
      name="${name%.url}"
      printf '%s\t%s\t%s\n' "$rel" "$name" "$url" >>"$tmp/repos.all.tsv"
      [[ -z "${manual_origin[$rel]:-}" || "$name" == origin ]] && manual_origin["$rel"]="$url"
    done
  done

  # --- things that will not be exported ---------------------------------------
  local -A isrepo=() container=()
  local p e
  container["$dev_dir"]=1
  for r in "${repos[@]}"; do
    isrepo["$r"]=1
    p="${r%/*}"
    while [[ "$p" == "$dev_dir"/* ]]; do
      container["$p"]=1
      p="${p%/*}"
    done
  done

  local -a nonrepo=()
  for p in "${!container[@]}"; do
    for e in "$p"/*; do
      [[ -L "$e" ]] && continue
      [[ -n "${isrepo[$e]:-}" || -n "${container[$e]:-}" ]] && continue
      [[ "$e" == "$dev_dir/space" || "$e" == "$dev_dir/.tmp" || "$e" == "$dev_tmp_dir" ]] && continue
      nonrepo+=("${e#"$dev_dir"/}")
    done
  done

  local warned=0
  if ((${#changes[@]})); then
    warned=1
    printf '\nLocal work that will NOT be exported (dirty = uncommitted, stash, unpushed = commits on no remote):\n'
    printf '  %s\n' "${changes[@]}"
  fi
  if ((${#noremote[@]})); then
    warned=1
    printf '\nRepos without any remote (not exported):\n'
    printf '  %s\n' "${noremote[@]}"
  fi
  if ((${#nonrepo[@]})); then
    warned=1
    printf '\nNot a git repo (not exported):\n'
    printf '%s\n' "${nonrepo[@]}" | sort | sed 's/^/  /'
  fi
  if ((${#nested[@]})); then
    printf '\nIgnored repos nested inside another repo:\n'
    printf '  %s\n' "${nested[@]#"$dev_dir"/}"
  fi
  if ((warned)); then
    echo
    _dev_confirm "Continue with the export?" || { echo "Aborted."; exit 0; }
  fi

  # --- pick manual repos (default yes) ------------------------------------------
  local -a excluded=()
  if ((${#manual[@]})); then
    local -a picked=()
    local reply mode=ask
    printf '\nManually cloned repos (not recreated by dev-reclone), include? [Y/n/a/s/?]\n'
    for rel in "${manual[@]}"; do
      if [[ "$mode" == all ]]; then
        picked+=("$rel")
        continue
      elif [[ "$mode" == skip ]]; then
        excluded+=("$rel")
        continue
      fi
      while true; do
        printf '  %-45s %s [Y/n/a/s/?] ' "$rel" "${manual_origin[$rel]}"
        # EOF (non-interactive) keeps the default for everything left
        if ! IFS= read -r reply; then
          echo
          reply=a
        fi
        case "$reply" in
          ""|y|Y) picked+=("$rel"); break ;;
          n|N)    excluded+=("$rel"); break ;;
          a|A)    picked+=("$rel"); mode=all; break ;;
          s|S)    excluded+=("$rel"); mode=skip; break ;;
          *)
            printf '    y = include (default), n = exclude, a = include this and all remaining,\n'
            printf '    s = exclude this and all remaining\n'
            ;;
        esac
      done
    done
    manual=("${picked[@]}")
  fi

  # remotes of the picked repos only
  local -A keep=()
  for rel in "${manual[@]}"; do keep["$rel"]=1; done
  : >"$tmp/repos.tsv"
  while IFS=$'\t' read -r rel name url; do
    [[ -n "${keep[$rel]:-}" ]] && printf '%s\t%s\t%s\n' "$rel" "$name" "$url" >>"$tmp/repos.tsv"
  done <"$tmp/repos.all.tsv"

  # --- aliases -----------------------------------------------------------------
  local link target
  : >"$tmp/aliases.tsv"
  while IFS=$'\t' read -r link target; do
    printf '%s\t%s\n' "$(_dev_export_encode_path "$link")" "$(_dev_export_encode_path "$target")" >>"$tmp/aliases.tsv"
  done < <(_dev_alias_pairs)

  # --- spaces ------------------------------------------------------------------
  local d
  : >"$tmp/spaces.ndjson"
  for d in "$dev_dir/space"/*/; do
    d="${d%/}"
    [[ -L "$d" ]] && continue
    if [[ ! -f "$d/space.json" ]]; then
      echo "dev-export: warning: no space.json in ${d#"$dev_dir"/}, skipped" >&2
      continue
    fi
    jq -c --arg dir "${d##*/}" '{dir: $dir, json: .}' "$d/space.json" >>"$tmp/spaces.ndjson" ||
      echo "dev-export: warning: invalid ${d#"$dev_dir"/}/space.json, skipped" >&2
  done

  # --- gitignored files --------------------------------------------------------
  : >"$tmp/ignored.list"
  if ((ask_ignored)); then
    echo
    if _dev_confirm "Select gitignored files to include (asks per entry)?"; then
      for rel in "${manual[@]}" "${group[@]}"; do
        _dev_export_pick_ignored "$dev_dir/$rel" "$rel" "$tmp/ignored.list"
        (($? == 3)) && break
      done
    fi
  fi

  local -a pack=(manifest.json)
  if [[ -s "$tmp/ignored.list" ]]; then
    local -a excludes=(--exclude-vcs)
    local s
    for s in "${_dev_export_skip_dirs[@]}" "${_dev_export_skip_globs[@]}"; do excludes+=("--exclude=$s"); done
    if ! tar -C "$dev_dir" -czf "$tmp/ignored.tar.gz" "${excludes[@]}" \
      --verbatim-files-from -T "$tmp/ignored.list"; then
      echo "dev-export: packing gitignored files failed" >&2
      exit 1
    fi
    pack+=(ignored.tar.gz)
    echo
    echo "dev-export: note: gitignored files may contain secrets, keep the export safe."
  fi

  # --- manifest ----------------------------------------------------------------
  jq -n \
    --argjson version "$_DEV_EXPORT_VERSION" \
    --arg created "$(date -Iseconds)" \
    --arg host "$host" \
    --arg dev_dir "$dev_dir" \
    --arg home "$HOME" \
    --arg gitlab_group "$gitlab_group" \
    --argjson group_repos "${#group[@]}" \
    --argjson repos "$(jq -R -s 'split("\n") | map(select(length > 0) | split("\t"))
      | group_by(.[0]) | map({path: .[0][0], remotes: (map({key: .[1], value: .[2]}) | from_entries)})' "$tmp/repos.tsv")" \
    --argjson aliases "$(jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {path: .[0], target: .[1]})' "$tmp/aliases.tsv")" \
    --slurpfile spaces "$tmp/spaces.ndjson" \
    --argjson ignored "$(jq -R -s 'split("\n") | map(select(length > 0))' "$tmp/ignored.list")" \
    '{version: $version, created: $created, host: $host, dev_dir: $dev_dir, home: $home,
      gitlab_group: $gitlab_group, group_repos: $group_repos, repos: $repos, aliases: $aliases,
      spaces: $spaces, ignored: $ignored}' >"$tmp/manifest.json" || exit 1

  mkdir -p -- "$(dirname -- "$out")" || exit 1
  (umask 077 && tar -C "$tmp" -czf "$out" "${pack[@]}") || exit 1
  chmod 600 -- "$out"

  printf '\ndev-export: wrote %s\n' "$out"
  printf '  %d manual repos, %d group repos (via dev-reclone), %d aliases, %d spaces, %d gitignored entries\n' \
    "${#manual[@]}" "${#group[@]}" "$(wc -l <"$tmp/aliases.tsv")" "$(wc -l <"$tmp/spaces.ndjson")" \
    "$(wc -l <"$tmp/ignored.list")"
  if ((${#excluded[@]})); then
    printf '  excluded repos:\n'
    printf '    %s\n' "${excluded[@]}"
  fi
)

_dev_import_help() {
  printf 'usage: dev-import <file> [--dry-run] [--skip-group-clone] [--no-ignored]\n\n'
  printf 'Recreate a setup exported with dev-export in %s:\n' "$dev_dir"
  printf '  1. dev-reclone (glab group clone, default branches)\n'
  printf '  2. clone manually cloned repos and add their remotes\n'
  printf '  3. recreate dev aliases and spaces\n'
  printf '  4. restore gitignored files (never overwrites existing files)\n\n'
  printf 'options:\n'
  printf '      --dry-run           only print what would be done\n'
  printf '      --skip-group-clone  do not run dev-reclone\n'
  printf '      --no-ignored        do not restore gitignored files\n'
  printf '  -h, --help              show this help\n'
}

# runs in a subshell so the cleanup trap and shell options stay local
dev-import() (
  local file="" dry=0 skip_group=0 no_ignored=0
  while (($#)); do
    case "$1" in
      --dry-run) dry=1 ;;
      --skip-group-clone) skip_group=1 ;;
      --no-ignored) no_ignored=1 ;;
      -h|--help) _dev_import_help; exit 0 ;;
      -*) _dev_import_help >&2; exit 1 ;;
      *)
        [[ -z "$file" ]] || { _dev_import_help >&2; exit 1; }
        file="$1"
        ;;
    esac
    shift
  done
  [[ -n "$file" ]] || { _dev_import_help >&2; exit 1; }
  file="${file/#\~/$HOME}"
  [[ -f "$file" ]] || { echo "dev-import: no such file: $file" >&2; exit 1; }

  local tool
  for tool in jq git tar; do
    command -v "$tool" >/dev/null || { echo "dev-import: $tool is required" >&2; exit 1; }
  done

  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dev-import.XXXXXX")" || exit 1
  trap 'rm -rf -- "$tmp"' EXIT
  trap 'exit 130' INT TERM

  tar -xzf "$file" -C "$tmp" || { echo "dev-import: cannot unpack $file" >&2; exit 1; }
  local m="$tmp/manifest.json"
  [[ -f "$m" ]] || { echo "dev-import: no manifest.json in $file" >&2; exit 1; }

  local version
  version="$(jq -r '.version' "$m")"
  if [[ "$version" != "$_DEV_EXPORT_VERSION" ]]; then
    echo "dev-import: unsupported manifest version '$version' (expected $_DEV_EXPORT_VERSION)" >&2
    exit 1
  fi

  local old_dev_dir old_home old_group group_repos n_repos n_aliases n_spaces n_ignored
  old_dev_dir="$(jq -r '.dev_dir' "$m")"
  old_home="$(jq -r '.home' "$m")"
  old_group="$(jq -r '.gitlab_group' "$m")"
  group_repos="$(jq -r '.group_repos' "$m")"
  n_repos="$(jq '.repos | length' "$m")"
  n_aliases="$(jq '.aliases | length' "$m")"
  n_spaces="$(jq '.spaces | length' "$m")"
  n_ignored="$(jq '.ignored | length' "$m")"

  printf 'dev-import: %s\n' "$file"
  printf '  exported from %s at %s (%s)\n' "$(jq -r '.host' "$m")" "$(jq -r '.created' "$m")" "$old_dev_dir"
  printf '  importing into %s\n\n' "$dev_dir"
  if ((skip_group)); then
    printf '  group clone:     skipped (--skip-group-clone)\n'
  elif ((group_repos == 0)); then
    printf '  group clone:     skipped (export had no group repos)\n'
    skip_group=1
  else
    printf '  group clone:     dev-reclone of "%s" (%s repos at export time)\n' "$gitlab_group" "$group_repos"
  fi
  printf '  manual repos:    %s\n' "$n_repos"
  printf '  aliases:         %s\n' "$n_aliases"
  printf '  spaces:          %s\n' "$n_spaces"
  printf '  gitignored:      %s%s\n' "$n_ignored" "$( ((no_ignored && n_ignored)) && printf ' (skipped, --no-ignored)')"
  if [[ "$old_group" != "$gitlab_group" ]]; then
    printf '\n  warning: export was made for gitlab group "%s", this machine uses "%s"\n' "$old_group" "$gitlab_group"
  fi
  echo

  if ((dry)); then
    echo "(dry-run, nothing will be changed)"
  else
    _dev_confirm "Start import?" || { echo "Aborted."; exit 0; }
  fi

  # run a command, or only print it in dry-run mode
  _run() {
    if ((dry)); then
      printf '    [dry-run] %s\n' "$*"
    else
      "$@"
    fi
  }

  local -a failed=() skipped=()
  local cloned=0 linked=0 spaces_made=0

  if ((!dry)); then
    mkdir -p -- "$dev_dir" || { echo "dev-import: cannot create $dev_dir" >&2; exit 1; }
  fi

  # --- 1. group clone ------------------------------------------------------------
  if ((!skip_group)); then
    printf '\n== group clone (%s)\n' "$gitlab_group"
    local do_group=1
    if [[ -d "$dev_group_dir" ]] && [[ -n "$(find "$dev_group_dir" -name .git -print -quit 2>/dev/null)" ]]; then
      if ((dry)); then
        echo "    $dev_group_dir already contains repos, would ask before re-running dev-reclone"
      elif ! _dev_confirm "$dev_group_dir already contains repos, run dev-reclone anyway?"; then
        do_group=0
        skipped+=("group clone (declined)")
      fi
    fi
    if ((do_group)); then
      if ! command -v glab >/dev/null; then
        failed+=("group clone: glab not installed")
      elif ! _run dev-reclone; then
        failed+=("group clone: dev-reclone failed")
      fi
    fi
  fi

  # --- 2. manual repos -----------------------------------------------------------
  if ((n_repos)); then
    printf '\n== repos\n'
    local -a paths=()
    local -A remotes=()
    local path name url
    while IFS=$'\t' read -r path name url; do
      [[ -n "${remotes[$path]+x}" ]] || paths+=("$path")
      remotes["$path"]+="$name"$'\t'"$url"$'\n'
    done < <(jq -r '.repos[] | .path as $p | .remotes | to_entries[] | [$p, .key, .value] | @tsv' "$m")

    local i=0 dest primary primary_url line current
    for path in "${paths[@]}"; do
      ((i++))
      dest="$(_dev_import_decode_path "$path")"

      primary="" primary_url=""
      while IFS=$'\t' read -r name url; do
        [[ -z "$name" ]] && continue
        if [[ -z "$primary" || "$name" == origin ]]; then
          primary="$name"
          primary_url="$url"
        fi
      done <<<"${remotes[$path]}"

      printf '[%d/%d] %s\n' "$i" "${#paths[@]}" "$path"
      if [[ -e "$dest" || -L "$dest" ]]; then
        current="$(git -C "$dest" config --get "remote.$primary.url" 2>/dev/null)"
        if [[ -e "$dest/.git" && "$current" == "$primary_url" ]]; then
          echo "    exists, skipped"
        else
          echo "    warning: $dest exists but is not a clone of $primary_url, skipped" >&2
          skipped+=("repo $path (exists with other content)")
        fi
        continue
      fi

      _run mkdir -p -- "$(dirname -- "$dest")"
      if ! _run git clone --recurse-submodules -o "$primary" -- "$primary_url" "$dest"; then
        failed+=("clone $path ($primary_url)")
        continue
      fi
      ((cloned++))
      while IFS=$'\t' read -r name url; do
        [[ -z "$name" || "$name" == "$primary" ]] && continue
        _run git -C "$dest" remote add "$name" "$url" || failed+=("remote $name in $path")
      done <<<"${remotes[$path]}"
    done
  fi

  # --- 3a. aliases ---------------------------------------------------------------
  if ((n_aliases)); then
    printf '\n== aliases\n'
    local link target lp tp
    while IFS=$'\t' read -r lp tp; do
      link="$(_dev_import_decode_path "$lp")"
      target="$(_dev_import_decode_path "$tp")"
      if [[ -L "$link" ]]; then
        if [[ "$(readlink -f -- "$link")" == "$(readlink -f -- "$target")" ]]; then
          echo "    $lp exists, skipped"
        else
          echo "    warning: $lp already links to $(readlink -- "$link"), skipped" >&2
          skipped+=("alias $lp (links elsewhere)")
        fi
        continue
      fi
      if [[ -e "$link" ]]; then
        echo "    warning: $lp exists and is not a symlink, skipped" >&2
        skipped+=("alias $lp (path exists)")
        continue
      fi
      if [[ ! -e "$target" ]] && ((!dry)); then
        echo "    warning: target of $lp is missing: $target, skipped" >&2
        skipped+=("alias $lp (target missing)")
        continue
      fi
      printf '    %s -> %s\n' "$lp" "$target"
      _run mkdir -p -- "$(dirname -- "$link")"
      if _run ln -s -- "$target" "$link"; then
        ((linked++))
      else
        failed+=("alias $lp")
      fi
    done < <(jq -r '.aliases[] | [.path, .target] | @tsv' "$m")
  fi

  # --- 3b. spaces ----------------------------------------------------------------
  if ((n_spaces)); then
    printf '\n== spaces\n'
    if ! declare -F _space_sync >/dev/null; then
      failed+=("spaces: space command not loaded")
    else
      local dir json space_path
      while IFS= read -r dir; do
        if [[ -z "$dir" || "$dir" == */* || "$dir" == . || "$dir" == .. ]]; then
          failed+=("space with invalid name '$dir'")
          continue
        fi
        space_path="$dev_dir/space/$dir"
        if [[ -e "$space_path" ]]; then
          echo "    warning: space $dir already exists, skipped" >&2
          skipped+=("space $dir (exists)")
          continue
        fi
        json="$(jq --arg dir "$dir" --arg od "$old_dev_dir" --arg nd "$dev_dir" --arg oh "$old_home" --arg nh "$HOME" '
          .spaces[] | select(.dir == $dir) | .json | .name = $dir
          | .links |= map_values(
              if startswith($od + "/") then $nd + .[($od | length):]
              elif startswith($oh + "/") then $nh + .[($oh | length):]
              else . end)' "$m")"

        printf '    %s\n' "$dir"
        if ((dry)); then
          printf '    [dry-run] create %s and run space sync\n' "$space_path"
          ((spaces_made++))
          continue
        fi
        mkdir -p -- "$space_path" && printf '%s\n' "$json" >"$space_path/space.json" || {
          failed+=("space $dir")
          continue
        }
        # space sync drops links whose source is missing and warns about them
        _space_sync "$dir" 2>&1 | sed 's/^ */      /'
        ((spaces_made++))
      done < <(jq -r '.spaces[].dir' "$m")
    fi
  fi

  # --- 4. gitignored files -------------------------------------------------------
  if ((n_ignored && !no_ignored)); then
    printf '\n== gitignored files\n'
    if [[ ! -f "$tmp/ignored.tar.gz" ]]; then
      failed+=("gitignored files: ignored.tar.gz missing in export")
    else
      local -A members=()
      local mem entry
      while IFS= read -r mem; do
        members["${mem%/}"]=1
      done < <(tar -tzf "$tmp/ignored.tar.gz")

      : >"$tmp/extract.list"
      while IFS= read -r entry; do
        if [[ -z "${members[$entry]:-}" ]]; then
          echo "    warning: $entry not in archive, skipped" >&2
        elif [[ ! -d "$dev_dir/$(dirname -- "$entry")" ]] && ((!dry)); then
          echo "    warning: parent of $entry missing (repo not cloned?), skipped" >&2
          skipped+=("gitignored $entry (parent missing)")
        else
          printf '    %s\n' "$entry"
          printf '%s\n' "$entry" >>"$tmp/extract.list"
        fi
      done < <(jq -r '.ignored[]' "$m")

      if [[ -s "$tmp/extract.list" ]]; then
        if ((dry)); then
          echo "    [dry-run] extract the entries above (existing files are kept)"
        elif _dev_confirm "Restore these entries (existing files are never overwritten)?"; then
          tar -xzf "$tmp/ignored.tar.gz" -C "$dev_dir" --skip-old-files \
            --verbatim-files-from -T "$tmp/extract.list" || failed+=("gitignored files: extraction errors")
        else
          skipped+=("gitignored files (declined)")
        fi
      fi
    fi
  fi

  # --- summary -------------------------------------------------------------------
  printf '\n== summary%s\n' "$( ((dry)) && printf ' (dry-run)')"
  if ((dry)); then
    printf '  would clone %d repos, create %d aliases, %d spaces\n' "$cloned" "$linked" "$spaces_made"
  else
    printf '  cloned %d repos, created %d aliases, %d spaces\n' "$cloned" "$linked" "$spaces_made"
  fi
  if ((${#skipped[@]})); then
    printf '  skipped:\n'
    printf '    %s\n' "${skipped[@]}"
  fi
  if ((${#failed[@]})); then
    printf '  FAILED:\n'
    printf '    %s\n' "${failed[@]}"
    exit 1
  fi
)

_dev_export_completion() {
  local cur="${COMP_WORDS[COMP_CWORD]}" prev="${COMP_WORDS[COMP_CWORD-1]}"
  COMPREPLY=()
  if [[ "$prev" == -o || "$prev" == --output ]]; then
    compopt -o filenames 2>/dev/null
    mapfile -t COMPREPLY < <(compgen -f -- "$cur")
    return 0
  fi
  mapfile -t COMPREPLY < <(compgen -W "-o --output --no-ignored -h --help" -- "$cur")
}
complete -F _dev_export_completion dev-export

_dev_import_completion() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  COMPREPLY=()
  if [[ "$cur" == -* ]]; then
    mapfile -t COMPREPLY < <(compgen -W "--dry-run --skip-group-clone --no-ignored -h --help" -- "$cur")
    return 0
  fi
  compopt -o filenames -o plusdirs 2>/dev/null
  mapfile -t COMPREPLY < <(compgen -f -X '!*.tar.gz' -- "$cur")
}
complete -F _dev_import_completion dev-import
