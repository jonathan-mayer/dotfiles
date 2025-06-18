#! /bin/bash

COLOR_RESET="\[\e[m\]"
COLOR_BOLD_CYAN="\[\e[1;36m\]"
COLOR_BOLD_GREEN="\[\e[1;32m\]"
COLOR_BOLD_BLUE="\[\e[1;34m\]"
COLOR_BOLD_RED="\[\e[1;31m\]"

ctx-prompt() {
    CONTEXT=$(kubectl config current-context 2>/dev/null)
    if [ -z "$CONTEXT" ]; then
        echo "${COLOR_BOLD_RED}none${COLOR_RESET}"
    else
        echo "${COLOR_BOLD_CYAN}$CONTEXT${COLOR_RESET}"
    fi
}

TIME_PROMPT="\A"
USER_PROMPT="$COLOR_BOLD_GREEN\u$COLOR_RESET"
WD_PROMPT="$COLOR_BOLD_BLUE\w$COLOR_RESET"

prompter() {
    export PS1="$TIME_PROMPT $USER_PROMPT:$WD_PROMPT $(ctx-prompt)\$ "
    history -a # save history to file
}

PROMPT_COMMAND=prompter
