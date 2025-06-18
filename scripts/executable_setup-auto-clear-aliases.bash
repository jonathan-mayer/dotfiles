#! /bin/bash

command_not_found_handle() {
    # Invoke the default command-not-found handler (if it exists)
    if [ -x /usr/lib/command-not-found ]; then
        /usr/lib/command-not-found "$1"
    else
        echo "$1: command not found"
    fi

    #Custom logic
    if [ $# -eq 1 ]; then # unknown command was run without arguments
        echo "--------------------------------------------------------"
        echo "Detected possible clear alias. Type 'clear add' to add '$1' as an clear alias."
        echo "$1" >/tmp/possible_clear_alias.txt
    fi

    return 127
}
clear() {
    if [ ! -f "/tmp/possible_clear_alias.txt" ] || [ ! -s "/tmp/possible_clear_alias.txt" ] || [ ! $# -eq 1 ]; then
        bash -c clear
        return 1
    fi

    local POSSIBLE_CLEAR_ALIAS=$(cat "/tmp/possible_clear_alias.txt")

    echo "alias $POSSIBLE_CLEAR_ALIAS='clear'" >>~/.clear_aliases
    source ~/.clear_aliases
    echo "Clear alias '$POSSIBLE_CLEAR_ALIAS' added to ~/.clear_aliases"

    local untrimmed=$(wc -l <~/.clear_aliases)
    awk -i inplace '!seen[$0]++' ~/.clear_aliases
    local now=$(wc -l <~/.clear_aliases)
    echo "Removed $((untrimmed - now)) duplicate clear aliases from ~/.clear_aliases"

    echo "~/.clear_aliases now contains $now aliases"
    echo "If this was a mistake type 'ohno' to remove the alias"
    rm /tmp/possible_clear_alias.txt
    return 0
}
ohno() {
    if [ ! -f "$HOME/.clear_aliases" ] || [ ! -s "$HOME/.clear_aliases" ]; then
        echo "No clear aliases set yet."
        return 1
    fi

    local removedAlias=$(
        sed -n '$ s/^alias \([^=]*\)=.*/\1/p' ~/.clear_aliases
        sed -i '$d' ~/.clear_aliases
    )
    source ~/.clear_aliases
    unalias $removedAlias
    echo "Removed clear alias '$removedAlias' from ~/.clear_aliases"
    echo "~/.clear_aliases now contains $(wc -l <~/.clear_aliases) aliases"
    return 0
}
if [ -f ~/.clear_aliases ]; then
    . ~/.clear_aliases
fi
