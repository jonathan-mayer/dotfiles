# dev-tmp - temporary git worktrees for branch-isolated work
# Creates worktrees in $dev_dir/.tmp/ for quick parallel branch work
# These are meant to be short-lived and deleted when done.

_dev_tmp_dir() {
  printf '%s\n' "$dev_dir/.tmp"
}

dev-tmp() {
  local devpath="$1"
  local branch="$2"

  if [[ -z "$devpath" ]]; then
    printf 'usage: dev-tmp <devpath> [branch]\n' >&2
    printf '\nCreates a temporary git worktree for branch-isolated work.\n' >&2
    printf 'If branch is omitted, creates a detached HEAD at current commit.\n' >&2
    printf 'If branch does not exist, creates it from HEAD.\n' >&2
    return 1
  fi

  local source_path link_name tmp_base tmp_path
  source_path="$(_dev_path "$devpath")"
  link_name="$(_space_link_name "$devpath")"
  tmp_base="$(_dev_tmp_dir)"

  if [[ ! -d "$source_path/.git" && ! -f "$source_path/.git" ]]; then
    printf 'error: not a git repo: %s\n' "$source_path" >&2
    return 1
  fi

  # Determine worktree directory name
  if [[ -n "$branch" ]]; then
    # Sanitize branch name for directory use
    local branch_safe="${branch//\//-}"
    tmp_path="$tmp_base/${link_name}--${branch_safe}"
  else
    tmp_path="$tmp_base/${link_name}--detached"
  fi

  if [[ -d "$tmp_path" ]]; then
    printf 'worktree already exists: %s\n' "$tmp_path"
    printf 'cd into it or remove with: dev-tmp-rm %s\n' "$devpath"
    cd "$tmp_path" || return 1
    return 0
  fi

  mkdir -p "$tmp_base"

  if [[ -n "$branch" ]]; then
    # Check if branch exists
    if git -C "$source_path" rev-parse --verify "$branch" >/dev/null 2>&1; then
      # Existing branch
      git -C "$source_path" worktree add "$tmp_path" "$branch"
    else
      # New branch from HEAD
      git -C "$source_path" worktree add -b "$branch" "$tmp_path"
    fi
  else
    # Detached HEAD
    git -C "$source_path" worktree add --detach "$tmp_path"
  fi

  if [[ $? -ne 0 ]]; then
    printf 'error: failed to create worktree\n' >&2
    return 1
  fi

  printf '\ncreated tmp worktree: %s\n' "$tmp_path"
  printf 'source: %s\n' "$source_path"
  [[ -n "$branch" ]] && printf 'branch: %s\n' "$branch"
  printf '\ncd-ing into worktree...\n'
  cd "$tmp_path" || return 1
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
    # Find by prefix (link_name--)
    local d
    for d in "$tmp_base/${link_name}--"*/; do
      [[ -d "$d" ]] && matches+=("${d%/}")
    done
  fi

  if [[ ${#matches[@]} -eq 0 ]]; then
    printf 'no tmp worktree found for: %s\n' "$devpath" >&2
    return 1
  fi

  if [[ ${#matches[@]} -gt 1 ]]; then
    printf 'multiple worktrees found for %s:\n' "$devpath" >&2
    local m
    for m in "${matches[@]}"; do
      printf '  %s\n' "$(basename -- "$m")"
    done
    printf '\nspecify the exact name from the list above.\n' >&2
    return 1
  fi

  local wt_path="${matches[0]}"
  local wt_name="$(basename -- "$wt_path")"

  # Find source repo by checking git worktree list from the worktree itself
  local source_repo
  source_repo="$(git -C "$wt_path" rev-parse --git-common-dir 2>/dev/null)"
  source_repo="$(dirname -- "$source_repo")"

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

  local d count=0
  for d in "$tmp_base"/*/; do
    [[ -d "$d" ]] || continue
    local name="$(basename -- "$d")"
    local branch
    branch="$(git -C "$d" branch --show-current 2>/dev/null)"
    [[ -z "$branch" ]] && branch="(detached)"
    printf '  %-40s %s\n' "$name" "$branch"
    ((count++))
  done

  if [[ $count -eq 0 ]]; then
    printf 'no temporary worktrees\n'
  fi
}

# Completion for dev-tmp
_dev_tmp_completion() {
  _dev_path_completion
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
