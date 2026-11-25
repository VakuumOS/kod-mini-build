# shellcheck shell=bash
# /etc/bash.bashrc — interactive bash settings for kod-mini
case $- in
    *i*) ;;
    *) return ;;
esac

HISTSIZE=5000
HISTCONTROL=ignoredups:erasedups
shopt -s checkwinsize histappend

if [ "${EUID}" -eq 0 ]; then
    PS1='\[\e[1;36m\]kod-mini\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]# '
else
    PS1='\[\e[1;36m\]\u@kod-mini\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]$ '
fi

alias ls='ls --color=auto'
alias ll='ls -lh'
alias la='ls -lha'
alias grep='grep --color=auto'
