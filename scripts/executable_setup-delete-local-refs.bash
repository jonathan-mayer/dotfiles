#! /bin/bash

color_red=$'\e[31m'
color_yellow=$'\e[33m'
color_reset=$'\e[0m'
# A branch that is checked out in a worktree cannot be deleted, not even with
# -D. Remove the worktrees holding <branch> so that it can be.
# Worktrees holding work that exists nowhere else are only removed after
# confirmation; skipping one makes this fail, so the branch is kept too.
_delete_branch_worktrees() {
    local branch="$1"
    local main_wt="" wt="" line
    local -a wts=()

    while IFS= read -r line; do
        case "$line" in
            "worktree "*)
                wt="${line#worktree }"
                # the main worktree is always listed first
                [[ -z "$main_wt" ]] && main_wt="$wt"
                ;;
            "branch refs/heads/"*)
                if [[ "${line#branch refs/heads/}" == "$branch" && "$wt" != "$main_wt" ]]; then
                    wts+=("$wt")
                fi
                ;;
        esac
    done < <(git worktree list --porcelain 2>/dev/null)

    (( ${#wts[@]} == 0 )) && return 0

    local rc=0 confirm
    for wt in "${wts[@]}"; do
        if [[ "$(pwd)" == "$wt"* ]]; then
            echo "${color_yellow}Branch '$branch' is checked out in the worktree you are in ('$wt'), skipping.${color_reset}"
            rc=1
            continue
        fi

        if declare -F _dev_tmp_has_unpushed >/dev/null && _dev_tmp_has_unpushed "$wt"; then
            read -p "${color_red}Worktree '$wt' holds work that exists nowhere else. Delete it anyway?${color_reset} (y/N) " confirm
            if [[ "$confirm" != [yY] ]]; then
                echo "Skipped worktree '$wt'."
                rc=1
                continue
            fi
        elif [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then
            echo "${color_red}Worktree '$wt' has uncommitted changes:${color_reset}"
            git -C "$wt" status --short
            read -p "${color_red}Delete it anyway? These changes cannot be recovered.${color_reset} (y/N) " confirm
            if [[ "$confirm" != [yY] ]]; then
                echo "Skipped worktree '$wt'."
                rc=1
                continue
            fi
        fi

        if git worktree remove --force "$wt"; then
            echo "Deleted worktree '$wt'."
        else
            echo "${color_red}Failed to delete worktree '$wt'.${color_reset}" >&2
            rc=1
        fi
    done

    return $rc
}

# delete-local-refs deletes all local refs whose remote ref was deleted on the remote
delete-local-refs() {
    current_branch=$(git rev-parse --abbrev-ref HEAD)
    default_branch=$(git remote show origin | grep 'HEAD branch' | awk '{print $NF}')

    git fetch -p # prune all no longer existing remote refs
    # iterate over all local refs with no remote ref
    for branch in $(git for-each-ref --format '%(refname) track:%(upstream:track) upstream:%(upstream:short)' refs/heads | awk '$2 == "track:[gone]" || $3 == "upstream:" {sub("refs/heads/", "", $1); print $1}'); do
        if [[ "$branch" == "$current_branch" ]]; then
            # inform user of being on branch which is about to be deleted
            read -p "${color_red}You are currently on branch '$branch'.${color_reset} Do you want to checkout '$default_branch' to be able to delete it? (yes/no) " confirm
            if [[ "${confirm,,}" == "yes" ]]; then
                # check out main
                git checkout $default_branch
                echo "Checked out main."
            else
                # skip branch
                echo "Skipped branch '$branch'."
                continue
            fi
        fi

        # ask user for permission to delete branch
        local should_delete=false
        if [[ $(git for-each-ref --format '%(upstream:short)' refs/heads/$branch) == "" ]]; then
            read -p "${color_red}Do you want to delete the local branch '$branch'? (This branch only exists locally.)${color_reset} (y/N) " confirm
            [[ $confirm == [yY] ]] && should_delete=true
        else
            # Remote branch is gone, safe to delete without asking
            should_delete=true
        fi

        if $should_delete; then
            # a branch checked out in a worktree can only be deleted once that
            # worktree is gone
            if ! _delete_branch_worktrees "$branch"; then
                echo "Skipped branch '$branch'."
                continue
            fi

            if git branch -D "$branch"; then
                echo "Deleted branch '$branch'."
            else
                echo "${color_red}Failed to delete branch '$branch'.${color_reset}" >&2
            fi
        else
            # skip branch
            echo "Skipped branch '$branch'."
            continue
        fi
    done

    mapfile -t stash_list < <(git stash list | tac)
    if [[ ${#stash_list[@]} -gt 0 ]]; then
        for stash in "${stash_list[@]}"; do
            stash_id=$(echo "$stash" | awk '{print $1}' | tr -d ':')
            stash_desc=$(echo "$stash" | cut -d':' -f2- | sed 's/^ //')
            read -p "${color_yellow}Do you want to delete stash '$stash_id' ($stash_desc)?${color_reset} (y/n) " confirm
            if [[ $confirm == [yY] ]]; then
                git stash drop "$stash_id"
                echo "Deleted stash '$stash_id'."
            else
                echo "Skipped stash '$stash_id' ($stash_desc)."
            fi
        done
    fi

    echo "All branches and stashes checked."
}
