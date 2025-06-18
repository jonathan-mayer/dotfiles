#! /bin/bash

color_red=$'\e[31m'
color_yellow=$'\e[33m'
color_reset=$'\e[0m'
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
        if [[ $(git for-each-ref --format '%(upstream:short)' refs/heads/$branch) == "" ]]; then
            read -p "${color_red}Do you want to delete the local branch '$branch'? (This branch only exists locally.)${color_reset} (y/n) " confirm
        else
            read -p "${color_yellow}Do you want to delete the local branch '$branch'?${color_reset} (y/n) " confirm
        fi

        if [[ $confirm == [yY] ]]; then
            # delete branch
            git branch -D "$branch"
            echo "Deleted branch '$branch'."
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
