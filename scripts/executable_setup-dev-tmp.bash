# dev-tmp - temporary git worktrees for branch-isolated work
# Creates worktrees in $dev_dir/.tmp/ and opens them in VS Code.
#
# Workflow:
#   dev-tmp <repo>            always creates a NEW scratch worktree (detached HEAD).
#                             Branch it later with gitb/gitcb if the work turns out
#                             to be worth keeping.
#   dev-tmp <repo> <branch>   always opens THE SAME worktree for that branch:
#                             reuses the existing one if there is any, otherwise
#                             creates it (from a local branch, a remote-only branch,
#                             or brand new from HEAD).
#
# Worktree directories are named <repo>-<random>, because the branch a worktree
# holds can change over its lifetime (a scratch worktree gets branched later).
# Branches are always looked up through git's worktree administration instead.
#
# Housekeeping:
#   automatic   worktrees untouched for $DEV_TMP_MAX_AGE_DAYS days that hold no
#               unpushed work are pruned in the background, no command needed
#   dev-tmp-cleanup   manually removes ALL temporary worktrees

# days after which an untouched, fully pushed worktree is pruned automatically
: "${DEV_TMP_MAX_AGE_DAYS:=30}"

_dev_tmp_dir() {
  printf '%s\n' "$dev_dir/.tmp"
}

# short random token used to make worktree directory names unique
_dev_tmp_token() {
  local t
  t="$(od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [[ -n "$t" ]] || printf -v t '%02x%02x%02x' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256))
  printf '%s\n' "$t"
}

# an unused worktree directory for a repo: <tmp_base>/<link_name>-<random>
_dev_tmp_new_path() {
  local tmp_base="$1" link_name="$2" path
  while :; do
    path="$tmp_base/${link_name}-$(_dev_tmp_token)"
    [[ -e "$path" ]] || break
  done
  printf '%s\n' "$path"
}

# worktree directories belonging to a repo, matched on the <link_name>-<token>
# naming scheme so that e.g. "foo" does not also match "foo-bar-a1b2c3"
_dev_tmp_paths_for() {
  local tmp_base="$1" link_name="$2" d name
  for d in "$tmp_base/${link_name}-"*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"
    name="$(basename -- "$d")"
    [[ "$name" =~ ^"$link_name"-[0-9a-f]{6}$ ]] && printf '%s\n' "$d"
  done
}

# resolve a devpath to a git repo, printing the repo path
# fails (with a message) if it is not a git repo
_dev_tmp_repo() {
  local devpath="$1" source_path
  source_path="$(_dev_path "$devpath")"

  if [[ ! -d "$source_path/.git" && ! -f "$source_path/.git" ]]; then
    printf 'error: not a git repo: %s\n' "$source_path" >&2
    return 1
  fi

  printf '%s\n' "$source_path"
}

# the source repo a worktree belongs to
_dev_tmp_source_repo() {
  local common_dir
  common_dir="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || return 1
  dirname -- "$common_dir"
}

# print the path of the worktree that has <branch> checked out, if any.
# Looks at git's own worktree administration rather than at directory names,
# so a worktree that was created detached and branched later (via gitb/gitcb)
# is still found by its branch.
_dev_tmp_find_by_branch() {
  local repo="$1" branch="$2"
  local wt="" line

  while IFS= read -r line; do
    case "$line" in
      "worktree "*) wt="${line#worktree }" ;;
      "branch refs/heads/"*)
        if [[ "${line#branch refs/heads/}" == "$branch" ]]; then
          printf '%s\n' "$wt"
          return 0
        fi
        ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)

  return 1
}

# print the remote-tracking ref (e.g. origin/foo) for a branch, if any remote has it
_dev_tmp_remote_ref() {
  local repo="$1" branch="$2" r
  for r in $(git -C "$repo" remote 2>/dev/null); do
    if git -C "$repo" show-ref --verify --quiet "refs/remotes/$r/$branch"; then
      printf '%s\n' "$r/$branch"
      return 0
    fi
  done
  return 1
}

# local + remote branch names of a repo, for completion
_dev_tmp_branches() {
  local repo
  repo="$(_dev_path "$1")"
  [[ -d "$repo/.git" || -f "$repo/.git" ]] || return 0

  {
    git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null
    git -C "$repo" for-each-ref --format='%(refname:lstrip=3)' refs/remotes 2>/dev/null \
      | grep -vx 'HEAD'
  } | sort -u
}

dev-tmp() {
  local devpath="$1"
  local branch="$2"

  if [[ -z "$devpath" ]]; then
    printf 'usage: dev-tmp <devpath> [branch]\n' >&2
    printf '\nCreates/opens a temporary git worktree in VS Code.\n' >&2
    printf '  without branch  always creates a new scratch worktree (detached HEAD)\n' >&2
    printf '  with branch     always opens the same worktree for that branch,\n' >&2
    printf '                  creating it if needed (local, remote-only or new branch)\n' >&2
    printf '\nsee also: dev-tmp-list, dev-tmp-rm, dev-tmp-cleanup\n' >&2
    return 1
  fi

  local source_path link_name tmp_base tmp_path
  source_path="$(_dev_tmp_repo "$devpath")" || return 1
  link_name="$(_space_link_name "$devpath")"
  tmp_base="$(_dev_tmp_dir)"

  _dev_tmp_autoprune

  # ---- open the existing worktree for this branch, if there is one ----------
  if [[ -n "$branch" ]]; then
    local existing
    if existing="$(_dev_tmp_find_by_branch "$source_path" "$branch")" && [[ -d "$existing" ]]; then
      if [[ "$existing" == "$tmp_base"/* ]]; then
        printf 'reusing tmp worktree: %s\n' "$existing"
      else
        printf 'branch %s is already checked out at: %s\n' "$branch" "$existing"
      fi
      printf 'branch: %s\n' "$branch"
      printf '\nopening worktree in VS Code...\n'
      code "$existing"
      return 0
    fi
  fi

  # ---- otherwise create a worktree ----------------------------------------
  mkdir -p "$tmp_base"
  tmp_path="$(_dev_tmp_new_path "$tmp_base" "$link_name")"

  if [[ -z "$branch" ]]; then
    git -C "$source_path" worktree add --detach "$tmp_path" || {
      printf 'error: failed to create worktree\n' >&2
      return 1
    }
  elif git -C "$source_path" show-ref --verify --quiet "refs/heads/$branch"; then
    # existing local branch
    git -C "$source_path" worktree add "$tmp_path" "$branch" || {
      printf 'error: failed to create worktree\n' >&2
      return 1
    }
  else
    # remote-only branch? check the remote-tracking refs, then ask the remote once
    local remote_ref=""
    remote_ref="$(_dev_tmp_remote_ref "$source_path" "$branch")" || remote_ref=""

    if [[ -z "$remote_ref" ]] && git -C "$source_path" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
      printf 'fetching branch %s from origin...\n' "$branch"
      git -C "$source_path" fetch --quiet origin "$branch"
      # fetch also updates the remote-tracking ref, which is what we want to
      # track; FETCH_HEAD is only a fallback for exotic remote configurations
      remote_ref="$(_dev_tmp_remote_ref "$source_path" "$branch")" || remote_ref="FETCH_HEAD"
    fi

    if [[ -n "$remote_ref" ]]; then
      git -C "$source_path" worktree add --track -b "$branch" "$tmp_path" "$remote_ref" \
        || git -C "$source_path" worktree add -b "$branch" "$tmp_path" "$remote_ref" || {
          printf 'error: failed to create worktree\n' >&2
          return 1
        }
    else
      # brand new branch from HEAD
      git -C "$source_path" worktree add -b "$branch" "$tmp_path" || {
        printf 'error: failed to create worktree\n' >&2
        return 1
      }
    fi
  fi

  printf '\ncreated tmp worktree: %s\n' "$tmp_path"
  printf 'source: %s\n' "$source_path"
  if [[ -n "$branch" ]]; then
    printf 'branch: %s\n' "$branch"
  else
    printf 'branch: (detached) - use gitb/gitcb to branch this work\n'
  fi
  printf '\nopening worktree in VS Code...\n'
  code "$tmp_path"
}

dev-tmp-rm() {
  local devpath="$1"

  if [[ -z "$devpath" ]]; then
    printf 'usage: dev-tmp-rm <devpath|name>\n' >&2
    printf '\nRemoves a temporary worktree. Accepts:\n' >&2
    printf '  - The original devpath used to create it\n' >&2
    printf '  - The worktree directory name from dev-tmp-list\n' >&2
    return 1
  fi

  local tmp_base
  tmp_base="$(_dev_tmp_dir)"

  # Try to find matching worktree(s)
  local link_name matches=()
  link_name="$(_space_link_name "$devpath")"

  if [[ -d "$tmp_base/$devpath" ]]; then
    # Exact directory name match
    matches+=("$tmp_base/$devpath")
  else
    # All worktrees belonging to that repo
    local d
    while IFS= read -r d; do
      matches+=("$d")
    done < <(_dev_tmp_paths_for "$tmp_base" "$link_name")
  fi

  if [[ ${#matches[@]} -eq 0 ]]; then
    printf 'no tmp worktree found for: %s\n' "$devpath" >&2
    return 1
  fi

  if [[ ${#matches[@]} -gt 1 ]]; then
    printf 'multiple worktrees found for %s:\n' "$devpath" >&2
    local m mb
    for m in "${matches[@]}"; do
      mb="$(git -C "$m" branch --show-current 2>/dev/null)"
      [[ -z "$mb" ]] && mb="(detached)"
      printf '  %-30s %s\n' "$(basename -- "$m")" "$mb" >&2
    done
    printf '\nspecify the exact name from the list above.\n' >&2
    return 1
  fi

  local wt_path="${matches[0]}"
  local wt_name="$(basename -- "$wt_path")"

  # Find source repo by checking git worktree list from the worktree itself
  local source_repo
  source_repo="$(_dev_tmp_source_repo "$wt_path")"

  # If we're currently in the worktree, cd out first
  if [[ "$(pwd)" == "$wt_path"* ]]; then
    printf 'leaving worktree directory...\n'
    cd "$dev_dir" || cd "$HOME"
  fi

  git -C "$source_repo" worktree remove "$wt_path" 2>/dev/null
  if [[ $? -ne 0 ]]; then
    # Force remove if there are changes
    printf 'worktree has uncommitted changes. force remove? [y/N] '
    local reply
    read -r reply
    if [[ "$reply" == [yY] ]]; then
      git -C "$source_repo" worktree remove --force "$wt_path"
    else
      printf 'aborted\n'
      return 1
    fi
  fi

  printf 'removed: %s\n' "$wt_name"
}

dev-tmp-list() {
  local tmp_base
  tmp_base="$(_dev_tmp_dir)"

  if [[ ! -d "$tmp_base" ]]; then
    printf 'no temporary worktrees\n'
    return 0
  fi

  _dev_tmp_autoprune

  local d count=0
  for d in "$tmp_base"/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"
    local name branch age state
    name="$(basename -- "$d")"
    branch="$(git -C "$d" branch --show-current 2>/dev/null)"
    [[ -z "$branch" ]] && branch="(detached)"
    age="$(_dev_tmp_age_days "$d")"

    if _dev_tmp_has_unpushed "$d"; then
      state="unpushed work"
    else
      state="pushed"
    fi

    printf '  %-40s %-28s %3sd  %s\n' "$name" "$branch" "$age" "$state"
    ((count++))
  done

  if [[ $count -eq 0 ]]; then
    printf 'no temporary worktrees\n'
  fi
}

# ---------------------------------------------------------------------------
# cleanup
# ---------------------------------------------------------------------------

# newest mtime (epoch seconds) of the files in a worktree, ignoring bulky
# generated directories.
# Only the worktree's own content is considered: git's administration files are
# deliberately excluded because read-only commands (git status refreshing the
# index, for example) touch them and would make every worktree look freshly
# used. Real work - editing, checkout, commit, merge - always writes to the
# working tree itself, and the .git link file gives a floor of the creation
# time for an untouched worktree.
_dev_tmp_last_activity() {
  local wt="$1"
  local newest=0 t

  t="$(find "$wt" \
        \( -name node_modules -o -name .venv -o -name venv -o -name target \
           -o -name dist -o -name build -o -name .next -o -name .gradle \) -prune -o \
        -printf '%T@\n' 2>/dev/null | sort -rn | head -1)"
  t="${t%%.*}"
  [[ -n "$t" ]] && newest="$t"

  printf '%s\n' "$newest"
}

_dev_tmp_age_days() {
  local last now
  last="$(_dev_tmp_last_activity "$1")"
  [[ -z "$last" || "$last" -eq 0 ]] && { printf '?\n'; return 0; }
  now="$(date +%s)"
  printf '%s\n' "$(( (now - last) / 86400 ))"
}

# true if the worktree holds work that exists nowhere else:
# uncommitted changes, untracked files, or commits not contained in any remote
# branch. Deliberately conservative - anything unknown counts as unpushed.
_dev_tmp_has_unpushed() {
  local wt="$1"

  git -C "$wt" rev-parse --git-dir >/dev/null 2>&1 || return 0

  # uncommitted changes and untracked files
  [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]] && return 0

  local head
  head="$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null)" || return 0

  # commits that no remote branch contains yet
  [[ -z "$(git -C "$wt" branch -r --contains "$head" 2>/dev/null)" ]] && return 0

  return 1
}

# remove a worktree directory, keeping git's administration in sync
_dev_tmp_remove() {
  local wt="$1" source_repo
  source_repo="$(_dev_tmp_source_repo "$wt")"

  if [[ -n "$source_repo" ]] && git -C "$source_repo" worktree remove --force "$wt" 2>/dev/null; then
    return 0
  fi

  rm -rf "$wt" || return 1
  [[ -n "$source_repo" ]] && git -C "$source_repo" worktree prune 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# automatic pruning of stale worktrees
# ---------------------------------------------------------------------------

# Removes worktrees untouched for $DEV_TMP_MAX_AGE_DAYS days that hold no
# unpushed work. Never touches the worktree the shell is currently in.
# This runs on its own (see _dev_tmp_autoprune) - there is no command for it.
_dev_tmp_prune_stale() {
  local tmp_base days now cutoff removed=0
  tmp_base="$(_dev_tmp_dir)"
  [[ -d "$tmp_base" ]] || return 0

  days="$DEV_TMP_MAX_AGE_DAYS"
  [[ "$days" =~ ^[0-9]+$ ]] || return 0
  (( days == 0 )) && return 0

  now="$(date +%s)"
  cutoff=$(( now - days * 86400 ))

  local d
  for d in "$tmp_base"/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"

    # never touch the worktree we are currently sitting in
    [[ "$(pwd)" == "$d"* ]] && continue

    local last
    last="$(_dev_tmp_last_activity "$d")"
    [[ -z "$last" || "$last" -eq 0 || "$last" -gt "$cutoff" ]] && continue

    # anything not safely on a remote stays, however old it is
    _dev_tmp_has_unpushed "$d" && continue

    local name age
    name="$(basename -- "$d")"
    age="$(_dev_tmp_age_days "$d")"
    if _dev_tmp_remove "$d"; then
      printf 'dev-tmp: pruned stale worktree %s (%sd untouched, fully pushed)\n' "$name" "$age"
      ((removed++))
    fi
  done

  return 0
}

# Runs the stale prune at most once a day, silent unless it removes something.
# Hooked into the dev-tmp commands so no explicit command run is needed.
_dev_tmp_autoprune() {
  local tmp_base stamp last now
  tmp_base="$(_dev_tmp_dir)"
  [[ -d "$tmp_base" ]] || return 0

  stamp="$tmp_base/.last-prune"
  now="$(date +%s)"
  last=0
  [[ -f "$stamp" ]] && last="$(cat "$stamp" 2>/dev/null)"
  [[ "$last" =~ ^[0-9]+$ ]] || last=0

  (( now - last < 86400 )) && return 0

  printf '%s\n' "$now" > "$stamp"
  _dev_tmp_prune_stale
}

# ---------------------------------------------------------------------------
# manual cleanup
# ---------------------------------------------------------------------------

# Removes ALL temporary worktrees.
dev-tmp-cleanup() {
  local dry_run=false assume_yes=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run) dry_run=true; shift ;;
      -y|--yes)     assume_yes=true; shift ;;
      -h|--help)
        printf 'usage: dev-tmp-cleanup [-n|--dry-run] [-y|--yes]\n'
        printf '\nRemoves ALL temporary worktrees.\n'
        printf 'Worktrees holding unpushed work are listed and confirmed separately.\n'
        printf '\n  -n  show what would be removed, remove nothing\n'
        printf '  -y  do not ask for confirmation\n'
        printf '\nWorktrees untouched for %s days that hold no unpushed work are\n' "$DEV_TMP_MAX_AGE_DAYS"
        printf 'pruned automatically, so this is only needed to wipe the slate.\n'
        return 0
        ;;
      *) printf 'dev-tmp-cleanup: unknown option: %s\n' "$1" >&2; return 1 ;;
    esac
  done

  local tmp_base
  tmp_base="$(_dev_tmp_dir)"
  [[ -d "$tmp_base" ]] || { printf 'no temporary worktrees\n'; return 0; }

  local all=() dirty=() current=""
  local d
  for d in "$tmp_base"/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"
    if [[ "$(pwd)" == "$d"* ]]; then
      current="$d"
      continue
    fi
    all+=("$d")
    _dev_tmp_has_unpushed "$d" && dirty+=("$d")
  done

  [[ -n "$current" ]] && printf 'skipping %s (current directory)\n' "$(basename -- "$current")"

  if [[ ${#all[@]} -eq 0 ]]; then
    printf 'no temporary worktrees to remove\n'
    return 0
  fi

  printf 'about to remove %d temporary worktree(s):\n' "${#all[@]}"
  local wt b
  for wt in "${all[@]}"; do
    b="$(git -C "$wt" branch --show-current 2>/dev/null)"
    [[ -z "$b" ]] && b="(detached)"
    printf '  %-30s %s\n' "$(basename -- "$wt")" "$b"
  done

  if [[ ${#dirty[@]} -gt 0 ]]; then
    printf '\nWARNING: %d of them hold work that exists nowhere else\n' "${#dirty[@]}"
    printf '(uncommitted changes, untracked files or unpushed commits):\n'
    for wt in "${dirty[@]}"; do
      printf '  %s\n' "$(basename -- "$wt")"
    done
  fi

  if $dry_run; then
    printf '\ndry run - nothing removed\n'
    return 0
  fi

  if ! $assume_yes; then
    local reply
    if [[ ${#dirty[@]} -gt 0 ]]; then
      printf '\nThis discards the unpushed work listed above. Type "yes" to continue: '
      IFS= read -r reply
      if [[ "$reply" != "yes" ]]; then
        printf 'aborted\n'
        return 1
      fi
    else
      printf '\nRemove all %d worktree(s)? [y/N] ' "${#all[@]}"
      IFS= read -r reply
      case "$reply" in
        [yY]|[yY][eE][sS]) ;;
        *) printf 'aborted\n'; return 1 ;;
      esac
    fi
  fi

  local removed=0 failed=0
  for wt in "${all[@]}"; do
    if _dev_tmp_remove "$wt"; then
      printf '  removed: %s\n' "$(basename -- "$wt")"
      ((removed++))
    else
      printf '  failed:  %s\n' "$(basename -- "$wt")" >&2
      ((failed++))
    fi
  done

  printf 'removed %d worktree(s)' "$removed"
  [[ $failed -gt 0 ]] && printf ', %d failed' "$failed"
  printf '\n'
  [[ $failed -eq 0 ]]
}

# ---------------------------------------------------------------------------
# completion
# ---------------------------------------------------------------------------

# Completion for dev-tmp: devpath first, then the repo's branches
_dev_tmp_completion() {
  local cur
  cur="${COMP_WORDS[COMP_CWORD]}"

  if [[ $COMP_CWORD -le 1 ]]; then
    _dev_path_completion
    return 0
  fi

  COMPREPLY=()
  if [[ $COMP_CWORD -eq 2 ]]; then
    local branches
    branches="$(_dev_tmp_branches "${COMP_WORDS[1]}")"
    COMPREPLY=($(compgen -W "$branches" -- "$cur"))
  fi
  return 0
}
complete -F _dev_tmp_completion dev-tmp

# Completion for dev-tmp-rm: list existing tmp worktrees
_dev_tmp_rm_completion() {
  local cur tmp_base
  cur="${COMP_WORDS[COMP_CWORD]}"
  tmp_base="$(_dev_tmp_dir)"

  COMPREPLY=()
  if [[ -d "$tmp_base" ]]; then
    local names
    names=$(find "$tmp_base" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null)
    COMPREPLY=($(compgen -W "$names" -- "$cur"))
  fi
}
complete -F _dev_tmp_rm_completion dev-tmp-rm
