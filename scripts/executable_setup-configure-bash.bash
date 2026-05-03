#! /bin/bash

# Ensure system python3 takes priority over linuxbrew's
export PATH="/usr/bin:$PATH"

export EDITOR=vim
export HISTSIZE=-1
export HISTFILESIZE=-1
export HISTCONTROL=ignoreboth
shopt -s histappend
shopt -s checkwinsize
