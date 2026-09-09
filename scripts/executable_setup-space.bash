# space - temporary workspace management with symlinks
# Creates workspaces in $dev_dir/space/$name/ with symlinks to dev paths

_space_dir() {
  printf '%s\n' "$dev_dir/space"
}

# Derive a symlink name from a dev path
# microservices/foo -> foo
# components/foo   -> foo-component
# config/foo       -> foo-config
# bar/foo          -> foo (generic)
# foo              -> foo
_space_link_name() {
  local devpath="$1"
  local base parent

  # Strip trailing slash
  devpath="${devpath%/}"

  base="$(basename -- "$devpath")"
  parent="$(basename -- "$(dirname -- "$devpath")")"

  case "$parent" in
    components)  printf '%s\n' "${base}-component" ;;
    config)      printf '%s\n' "${base}-config" ;;
    gitrepositories) printf '%s\n' "${base}-gitrepo" ;;
    .)           printf '%s\n' "$base" ;;
    *)           printf '%s\n' "$base" ;;
  esac
}

# Find all git repos under a path (non-recursive, depth 1)
_space_find_repos() {
  local dir="$1"
  local d
  for d in "$dir"/*/; do
    [[ -d "$d/.git" ]] && printf '%s\n' "$d"
  done
}

# Create symlinks for a given dev path into a space directory
# Supports explicit naming with :name suffix (e.g. microservices/foo:my-name)
_space_add_link() {
  local space_path="$1"
  local arg="$2"
  local devpath link_name source_path

  # Parse optional :name suffix
  if [[ "$arg" == *:* ]]; then
    devpath="${arg%:*}"
    link_name="${arg##*:}"
  else
    devpath="$arg"
    link_name="$(_space_link_name "$devpath")"
  fi

  source_path="$(_dev_path "$devpath")"

  if [[ ! -e "$source_path" ]]; then
    printf 'warning: source does not exist: %s\n' "$source_path" >&2
    return 1
  fi

  # Fully resolve the path so the space never links to another symlink
  source_path="$(readlink -f "$source_path")"

  # Resolve collisions
  local final_name="$link_name"
  local i=2
  while [[ -e "$space_path/$final_name" || -L "$space_path/$final_name" ]]; do
    final_name="${link_name}-${i}"
    ((i++))
  done

  ln -s "$source_path" "$space_path/$final_name"
  printf '  %s -> %s\n' "$final_name" "$source_path"

  # Return the link info for space.json
  printf '%s\n' "$final_name" >> "$space_path/.space_links_tmp"
  printf '%s\n' "$source_path" >> "$space_path/.space_sources_tmp"
}

# Write space.json from temp files
_space_write_json() {
  local space_path="$1"
  local name="$2"
  local created="${3:-$(date -Iseconds)}"

  local json='{\n  "name": "'"$name"'",\n  "created": "'"$created"'",\n  "links": {'

  local first=true
  if [[ -f "$space_path/.space_links_tmp" && -f "$space_path/.space_sources_tmp" ]]; then
    local -a links sources
    mapfile -t links < "$space_path/.space_links_tmp"
    mapfile -t sources < "$space_path/.space_sources_tmp"

    for i in "${!links[@]}"; do
      if [[ "$first" == true ]]; then
        first=false
      else
        json="$json,"
      fi
      json="$json"'\n    "'"${links[$i]}"'": "'"${sources[$i]}"'"'
    done
  fi

  json="$json"'\n  }\n}'

  printf "$json\n" > "$space_path/space.json"
  rm -f "$space_path/.space_links_tmp" "$space_path/.space_sources_tmp"

  # Regenerate .code-workspace file
  _space_write_code_workspace "$space_path" "$name"

  # Regenerate opencode.json
  _space_write_opencode_json "$space_path"
}

# Generate a .code-workspace file so VS Code recognises git repos in symlinks
_space_write_code_workspace() {
  local space_path="$1"
  local name="$2"
  local ws_file="$space_path/${name}.code-workspace"

  local ws='{\n  "folders": ['

  local first=true
  local entry
  for entry in $(_space_read_json "$space_path"); do
    local link_name="${entry%%:*}"
    if [[ "$first" == true ]]; then
      first=false
    else
      ws="$ws,"
    fi
    ws="$ws"'\n    { "path": "'"$link_name"'" }'
  done

  ws="$ws"'\n  ],\n  "settings": {\n    "terminal.integrated.cwd": "'"$space_path"'"\n  }\n}'

  printf "$ws\n" > "$ws_file"
}

# Generate an opencode.json declaring every link target as a named reference,
# plus an explicit external_directory allow for each of them.
_space_write_opencode_json() {
  local space_path="$1"
  local oc_file="$space_path/opencode.json"

  local -a names=() targets=()

  local entry
  for entry in $(_space_read_json "$space_path"); do
    local link_name="${entry%%:*}"
    local source="${entry#*:}"

    local resolved
    resolved="$(readlink -f "$space_path/$link_name" 2>/dev/null)"
    [[ -z "$resolved" ]] && resolved="$(readlink -f "$source" 2>/dev/null)"
    [[ -z "$resolved" || ! -d "$resolved" ]] && continue

    names+=("$link_name")
    targets+=("$resolved")
  done

  local oc='{\n  "$schema": "https://opencode.ai/config.json",\n  "permission": {\n    "external_directory": {'

  local first=true
  local i
  for i in "${!targets[@]}"; do
    if [[ "$first" == true ]]; then
      first=false
    else
      oc="$oc,"
    fi
    oc="$oc"'\n      "'"${targets[$i]}"'/*": "allow"'
  done

  oc="$oc"'\n    }\n  },\n  "references": {'

  first=true
  for i in "${!names[@]}"; do
    if [[ "$first" == true ]]; then
      first=false
    else
      oc="$oc,"
    fi
    oc="$oc"'\n    "'"${names[$i]}"'": { "path": "'"${targets[$i]}"'" }'
  done

  oc="$oc"'\n  }\n}'

  printf "$oc\n" > "$oc_file"
}

# Read space.json and return links as link_name:source pairs
_space_read_json() {
  local space_path="$1"
  if [[ ! -f "$space_path/space.json" ]]; then
    return 1
  fi
  # Simple json parsing with sed - extract link entries
  sed -n '/"links"/,/^  }/{ s/.*"\([^"]*\)": "\([^"]*\)".*/\1:\2/p }' "$space_path/space.json"
}

_space_get_created() {
  local space_path="$1"
  sed -n 's/.*"created": "\([^"]*\)".*/\1/p' "$space_path/space.json"
}

space() {
  local subcmd="${1:-help}"
  shift 2>/dev/null || true

  case "$subcmd" in
    create)  _space_create "$@" ;;
    delete)  _space_delete "$@" ;;
    rename)  _space_rename "$@" ;;
    add)     _space_add "$@" ;;
    rm)      _space_rm "$@" ;;
    list)    _space_list "$@" ;;
    show)    _space_show "$@" ;;
    open)    _space_open "$@" ;;
    sync)    _space_sync "$@" ;;
    help|*)  _space_help ;;
  esac
}

_space_create() {
  local name="$1"
  shift 2>/dev/null || true

  if [[ -z "$name" ]]; then
    printf 'usage: space create <name> [devpaths...]\n' >&2
    return 1
  fi

  local space_path="$(_space_dir)/$name"

  if [[ -d "$space_path" ]]; then
    printf 'space already exists: %s\n' "$name" >&2
    printf 'use "space add %s <paths...>" to add more links\n' "$name" >&2
    return 1
  fi

  mkdir -p "$space_path"
  printf 'created space: %s\n' "$name"

  # Add each path
  for devpath in "$@"; do
    _space_add_link "$space_path" "$devpath"
  done

  _space_write_json "$space_path" "$name"
  printf '\nspace ready: %s\n' "$space_path"
}

_space_delete() {
  local name="$1"

  if [[ -z "$name" ]]; then
    printf 'usage: space delete <name>\n' >&2
    return 1
  fi

  local space_path="$(_space_dir)/$name"

  if [[ ! -d "$space_path" ]]; then
    printf 'space not found: %s\n' "$name" >&2
    return 1
  fi

  rm -rf "$space_path"
  printf 'deleted space: %s\n' "$name"
}

_space_rename() {
  local old_name="$1"
  local new_name="$2"

  if [[ -z "$old_name" || -z "$new_name" ]]; then
    printf 'usage: space rename <old_name> <new_name>\n' >&2
    return 1
  fi

  local space_base="$(_space_dir)"
  local old_path="$space_base/$old_name"
  local new_path="$space_base/$new_name"

  if [[ ! -d "$old_path" ]]; then
    printf 'space not found: %s\n' "$old_name" >&2
    return 1
  fi

  if [[ -d "$new_path" ]]; then
    printf 'space already exists: %s\n' "$new_name" >&2
    return 1
  fi

  mv "$old_path" "$new_path"

  # Update name in space.json and regenerate .code-workspace
  if [[ -f "$new_path/space.json" ]]; then
    sed -i 's/"name": "'"$old_name"'"/"name": "'"$new_name"'"/' "$new_path/space.json"
  fi
  rm -f "$new_path/${old_name}.code-workspace"
  _space_write_code_workspace "$new_path" "$new_name"
  _space_write_opencode_json "$new_path"

  printf 'renamed: %s -> %s\n' "$old_name" "$new_name"
}

_space_add() {
  local name="$1"
  shift 2>/dev/null || true

  if [[ -z "$name" || $# -eq 0 ]]; then
    printf 'usage: space add <name> <devpaths...>\n' >&2
    return 1
  fi

  local space_path="$(_space_dir)/$name"

  if [[ ! -d "$space_path" ]]; then
    printf 'space not found: %s\n' "$name" >&2
    return 1
  fi

  # Read existing links into temp files for appending
  local entry
  for entry in $(_space_read_json "$space_path"); do
    printf '%s\n' "${entry%%:*}" >> "$space_path/.space_links_tmp"
    printf '%s\n' "${entry#*:}" >> "$space_path/.space_sources_tmp"
  done

  for devpath in "$@"; do
    _space_add_link "$space_path" "$devpath"
  done

  local created
  created="$(_space_get_created "$space_path")"
  _space_write_json "$space_path" "$name" "$created"
}

_space_rm() {
  local name="$1"
  shift 2>/dev/null || true

  if [[ -z "$name" || $# -eq 0 ]]; then
    printf 'usage: space rm <name> <link_names_or_devpaths...>\n' >&2
    return 1
  fi

  local space_path="$(_space_dir)/$name"

  if [[ ! -d "$space_path" ]]; then
    printf 'space not found: %s\n' "$name" >&2
    return 1
  fi

  # For each argument, try to match by link name or by source path
  for target in "$@"; do
    local found=false
    # Also match against the fully resolved form, since space.json stores
    # resolved absolute paths while the user may pass a devpath/alias.
    local target_resolved
    target_resolved="$(readlink -f "$(_dev_path "$target")" 2>/dev/null)"
    local entry
    for entry in $(_space_read_json "$space_path"); do
      local link_name="${entry%%:*}"
      local source="${entry#*:}"
      if [[ "$link_name" == "$target" || "$source" == "$target" \
            || ( -n "$target_resolved" && "$source" == "$target_resolved" ) ]]; then
        rm -f "$space_path/$link_name"
        printf '  removed: %s\n' "$link_name"
        found=true
        break
      fi
    done
    if [[ "$found" == false ]]; then
      printf '  not found: %s\n' "$target" >&2
    fi
  done

  # Rebuild space.json from remaining symlinks
  rm -f "$space_path/.space_links_tmp" "$space_path/.space_sources_tmp"
  local entry
  for entry in $(_space_read_json "$space_path"); do
    local link_name="${entry%%:*}"
    local source="${entry#*:}"
    if [[ -L "$space_path/$link_name" ]]; then
      printf '%s\n' "$link_name" >> "$space_path/.space_links_tmp"
      printf '%s\n' "$source" >> "$space_path/.space_sources_tmp"
    fi
  done

  local created
  created="$(_space_get_created "$space_path")"
  _space_write_json "$space_path" "$name" "$created"
}

_space_list() {
  local space_base="$(_space_dir)"

  if [[ ! -d "$space_base" ]]; then
    printf 'no spaces found\n'
    return 0
  fi

  local d
  for d in "$space_base"/*/; do
    [[ -d "$d" ]] || continue
    local name="$(basename -- "$d")"
    local count
    count=$(find "$d" -maxdepth 1 -type l | wc -l)
    printf '  %-20s (%d links)\n' "$name" "$count"
  done
}

_space_show() {
  local name="$1"

  if [[ -z "$name" ]]; then
    printf 'usage: space show <name>\n' >&2
    return 1
  fi

  local space_path="$(_space_dir)/$name"

  if [[ ! -d "$space_path" ]]; then
    printf 'space not found: %s\n' "$name" >&2
    return 1
  fi

  printf 'space: %s\n' "$name"
  printf 'path:  %s\n' "$space_path"

  if [[ -f "$space_path/space.json" ]]; then
    local created
    created="$(_space_get_created "$space_path")"
    printf 'created: %s\n' "$created"
  fi

  printf '\nlinks:\n'
  local entry
  for entry in $(_space_read_json "$space_path"); do
    local link_name="${entry%%:*}"
    local source="${entry#*:}"
    printf '  %-30s -> %s\n' "$link_name" "$source"
  done
}

_space_open() {
  local name="$1"

  if [[ -z "$name" ]]; then
    printf 'usage: space open <name>\n' >&2
    return 1
  fi

  local space_path="$(_space_dir)/$name"

  if [[ ! -d "$space_path" ]]; then
    printf 'space not found: %s\n' "$name" >&2
    return 1
  fi

  code "space/$name"
}

_space_sync() {
  local name="$1"

  if [[ -z "$name" ]]; then
    printf 'usage: space sync <name>\n' >&2
    return 1
  fi

  local space_path="$(_space_dir)/$name"

  if [[ ! -d "$space_path" ]]; then
    printf 'space not found: %s\n' "$name" >&2
    return 1
  fi

  printf 'syncing space: %s\n' "$name"

  rm -f "$space_path/.space_links_tmp" "$space_path/.space_sources_tmp"

  # Re-resolve every source, repair missing/stale symlinks and rewrite
  # space.json with fully resolved absolute paths.
  local entry
  for entry in $(_space_read_json "$space_path"); do
    local link_name="${entry%%:*}"
    local source="${entry#*:}"
    local source_path
    source_path="$(readlink -f "$(_dev_path "$source")" 2>/dev/null)"

    if [[ -z "$source_path" || ! -e "$source_path" ]]; then
      printf '  warning: source gone: %s (%s)\n' "$link_name" "$source" >&2
      continue
    fi

    if [[ ! -L "$space_path/$link_name" ]]; then
      printf '  link missing, recreating: %s -> %s\n' "$link_name" "$source_path"
      rm -rf "$space_path/$link_name"
      ln -s "$source_path" "$space_path/$link_name"
    else
      local current
      current="$(readlink "$space_path/$link_name")"
      if [[ "$current" != "$source_path" ]]; then
        printf '  relinked: %s -> %s\n' "$link_name" "$source_path"
        rm -f "$space_path/$link_name"
        ln -s "$source_path" "$space_path/$link_name"
      fi
    fi

    printf '%s\n' "$link_name" >> "$space_path/.space_links_tmp"
    printf '%s\n' "$source_path" >> "$space_path/.space_sources_tmp"
  done

  # Rewrites space.json plus the .code-workspace and opencode.json files
  local created
  created="$(_space_get_created "$space_path")"
  _space_write_json "$space_path" "$name" "$created"

  printf 'sync complete\n'
}

_space_help() {
  printf 'usage: space <command> [args...]\n\n'
  printf 'commands:\n'
  printf '  create <name> [devpaths...]    Create a new workspace with symlinks\n'
  printf '  delete <name>                  Delete a workspace\n'
  printf '  rename <old> <new>             Rename a workspace\n'
  printf '  add <name> <devpaths...>       Add links to an existing workspace\n'
  printf '  rm <name> <names_or_paths...>  Remove links from a workspace\n'
  printf '  list                           List all workspaces\n'
  printf '  show <name>                    Show workspace details\n'
  printf '  open <name>                    Open workspace in VS Code\n'
  printf '  sync <name>                    Sync workspace (re-resolve symlinks, fix broken links,\n'
  printf '                                 regenerate .code-workspace and opencode.json)\n'
}

# Completion for space command
_space_completion() {
  local cur prev subcmd
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  COMPREPLY=()

  # First argument: subcommand
  if [[ $COMP_CWORD -eq 1 ]]; then
    COMPREPLY=($(compgen -W "create delete rename add rm list show open sync help" -- "$cur"))
    return 0
  fi

  subcmd="${COMP_WORDS[1]}"

  # Second argument: space name for commands that need it
  if [[ $COMP_CWORD -eq 2 ]]; then
    case "$subcmd" in
      delete|rename|add|rm|show|open|sync)
        local space_base="$(_space_dir)"
        if [[ -d "$space_base" ]]; then
          local names
          names=$(find "$space_base" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null)
          COMPREPLY=($(compgen -W "$names" -- "$cur"))
        fi
        return 0
        ;;
      create)
        # No completion for the name (user picks freely)
        return 0
        ;;
    esac
  fi

  # Third+ arguments: dev paths for create/add
  if [[ $COMP_CWORD -ge 3 && ("$subcmd" == "create" || "$subcmd" == "add") ]]; then
    _dev_path_completion
    return 0
  fi

  # Third+ arguments for rm: existing link names in the space
  if [[ $COMP_CWORD -ge 3 && "$subcmd" == "rm" ]]; then
    local name="${COMP_WORDS[2]}"
    local space_path="$(_space_dir)/$name"
    if [[ -d "$space_path" ]]; then
      local links
      links=$(find "$space_path" -maxdepth 1 -type l -printf '%f\n' 2>/dev/null)
      COMPREPLY=($(compgen -W "$links" -- "$cur"))
    fi
    return 0
  fi

  return 0
}
complete -F _space_completion space
