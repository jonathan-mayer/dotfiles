human() {
  local bytes=$1
  local sign=""
  if [[ "$bytes" -lt 0 ]]; then
    sign="-"
    bytes=$(( -bytes ))
  fi

  echo -n ${sign}$(numfmt --to=iec --suffix=B "$bytes")
}

disk_used_bytes() {
  df --output=used -B1 / | tail -n1 | tr -d ' '
}

# free up expendible disk space
makespace() {
  set -uo pipefail

  ask() {
    local prompt="$1"
    read -r -p "$prompt [y/N] " reply < /dev/tty
    [[ "$reply" =~ ^[Yy]$ ]]
  }

  before_total=$(disk_used_bytes)

  echo "Starting disk cleanup"
  echo

  # TODO ~/.cache folder cleanup

  # ------------------------------------------------------------------
  # Docker: explicit per-item cleanup
  # ------------------------------------------------------------------
  if command -v docker >/dev/null 2>&1; then
    echo "Docker cleanup (explicit, item-by-item)"
    echo
  
    # --------------------------------------------------------------
    # Running containers
    # --------------------------------------------------------------
    running=$(docker ps --format '{{.ID}} {{.Names}}')
  
    if [[ -n "$running" ]]; then
      echo "Running containers:"
      echo "$running"
      echo
  
      while read -r cid cname; do
        echo "Container: $cname ($cid)"
  
        if ask "Delete this container?"; then
            before=$(disk_used_bytes)
            docker stop "$cid"
            docker rm "$cid"
            after=$(disk_used_bytes)
            freed=$((before-after))
            echo "Freed approx $(human "$freed")"
        else
            echo "Ignored"
        fi
        echo
      done <<< "$running"
    fi
  
    # --------------------------------------------------------------
    # Stopped containers
    # --------------------------------------------------------------
    stopped=$(docker ps -a --filter status=exited --format '{{.ID}} {{.Names}}')
  
    if [[ -n "$stopped" ]]; then
      echo "Stopped containers:"
      echo
  
      while read -r cid cname; do
        echo "Container: $cname ($cid)"
  
        if ask "Remove this container?"; then
          before=$(disk_used_bytes)
          docker rm "$cid"
          after=$(disk_used_bytes)
          freed=$((before-after))
          echo "Freed approx $(human "$freed")"
        else
          echo "Kept"
        fi
        echo
      done <<< "$stopped"
    fi
  
    # --------------------------------------------------------------
    # Dangling / unused images
    # --------------------------------------------------------------
    images=$(docker images -f dangling=true --format '{{.ID}} {{.Repository}}:{{.Tag}}')
  
    if [[ -n "$images" ]]; then
      echo "Dangling images:"
      echo
  
      while read -r iid name; do
        echo "Image: $name ($iid)"
  
        if ask "Remove this image?"; then
          before=$(disk_used_bytes)
          docker rmi "$iid"
          after=$(disk_used_bytes)
          freed=$((before-after))
          echo "Freed approx $(human "$freed")"
        else
          echo "Kept"
        fi
        echo
      done <<< "$images"
    fi
  
    # --------------------------------------------------------------
    # Unused volumes
    # --------------------------------------------------------------
    volumes=$(docker volume ls -qf dangling=true)
  
    if [[ -n "$volumes" ]]; then
      echo "Unused volumes:"
      echo
  
      while read -r vol; do
        size=$(docker system df -v 2>/dev/null | awk -v v="$vol" '$1==v {print $3}')
        echo "Volume: $vol ${size:+($size)}"
  
        if ask "Remove this volume?"; then
          before=$(disk_used_bytes)
          docker volume rm "$vol"
          after=$(disk_used_bytes)
          freed=$((before-after))
          echo "Freed approx $(human "$freed")"
        else
          echo "Kept"
        fi
        echo
      done <<< "$volumes"
    fi
  
    # --------------------------------------------------------------
    # Unused networks
    # --------------------------------------------------------------
    networks=$(docker network ls --filter dangling=true --format '{{.ID}} {{.Name}}')
  
    if [[ -n "$networks" ]]; then
      echo "Unused networks:"
      echo
  
      while read -r nid name; do
        echo "Network: $name ($nid)"
  
        if ask "Remove this network?"; then
          before=$(disk_used_bytes)
          docker network rm "$nid"
          after=$(disk_used_bytes)
          freed=$((before-after))
          echo "Freed approx $(human "$freed")"
        else
          echo "Kept"
        fi
        echo
      done <<< "$networks"
    fi
  
    echo
  fi


  # ------------------------------------------------------------------
  # npm cache
  # ------------------------------------------------------------------
  if command -v npm >/dev/null 2>&1; then
    if ask "Clean npm cache?"; then
      before=$(disk_used_bytes)
      npm cache clean --force
      after=$(disk_used_bytes)
      freed=$((before-after))
      echo "Freed approx $(human "$freed")"
      echo
    fi
  fi

  # ------------------------------------------------------------------
  # Go module cache
  # ------------------------------------------------------------------
  if command -v go >/dev/null 2>&1; then
    if ask "Clean Go module cache?"; then
      before=$(disk_used_bytes)
      go clean -modcache
      after=$(disk_used_bytes)
      freed=$((before-after))
      echo "Freed approx $(human "$freed")"
      echo
    fi
  fi

  # ------------------------------------------------------------------
  # nvm-installed Node versions
  # ------------------------------------------------------------------
  if [[ -n "${NVM_DIR:-}" && -d "$NVM_DIR/versions/node" ]]; then
    for dir in "$NVM_DIR"/versions/node/*; do
      version=$(basename "$dir")

      echo "Node version $version"
      if ask "Remove this Node version?"; then
        before=$(disk_used_bytes)
        nvm uninstall "$version"
        after=$(disk_used_bytes)
        freed=$((before-after))
        echo "Freed approx $(human "$freed")"
      else
        echo "Skipped"
      fi
      echo
    done
  fi

  # ------------------------------------------------------------------
  # Homebrew cleanup
  # ------------------------------------------------------------------
  if command -v brew >/dev/null 2>&1; then
    if ask "Run brew cleanup?"; then
      before=$(disk_used_bytes)
      brew cleanup
      after=$(disk_used_bytes)
      freed=$((before-after))
      echo "Freed approx $(human "$freed")"
      echo
    fi
  fi

  # ------------------------------------------------------------------
  # Final report
  # ------------------------------------------------------------------
  after_total=$(disk_used_bytes)
  net_freed=$((before_total - after_total))

  echo "Cleanup complete"
  echo "Disk usage before: $(human "$before_total")"
  echo "Disk usage after: $(human "$after_total")"
  echo "Total space freed: $(human "$net_freed")"
  echo

  # ------------------------------------------------------------------
  # Large directories (>1GiB)
  # ------------------------------------------------------------------
  echo "These Directories are using more than 1GiB:"
  echo

  du -x -B1 -d 3 / 2>/dev/null \
    | awk '$1 > 1073741824 { printf "%s\t%s\n", $2, $1 }' \
    | sort -k2 -nr \
    | while read -r path size; do
        printf "%-60s %10s\n" "$path" "$(human "$size")"
      done
}

# track disk usage during command execution
disktracker() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: disktracker <command>"
        return 1
    fi

    local before after delta
    before=$(disk_used_bytes)

    # Run the command
    "$@"

    after=$(disk_used_bytes)
    delta=$((after - before))

    echo "Disk change for '$*': $(human "$delta")"
}

