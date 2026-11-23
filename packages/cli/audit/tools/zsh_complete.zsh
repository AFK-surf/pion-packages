# Drive a real interactive zsh (zle + compsys) through zsh/zpty and press TAB once.
# usage: zsh -f zsh_complete.zsh <completion-script> <workdir> <typed-line>
# The completion script is sourced exactly as a user's fpath/compinit setup would load it.
script=$1; dir=$2; line=$3
zmodload zsh/zpty
zpty z "zsh -f -i"
zpty -w z "cd $dir; PS1='READY> '; autoload -U compinit; compinit -u -D; source $script; compdef _app app; print MARK_\$((40+2))"
zpty -r -m z out '*MARK_42*'
# wait until zle has redrawn the prompt, so TAB goes to the line editor and not to the tty
zpty -r -m z out '*READY> *'
sleep 1
zpty -w -n z "$line"$'\t'
sleep 3
all=""
while zpty -rt z chunk; do all+=$chunk; done
print -r -- "$all" | tr -d '\r' | cat -v | tail -4
zpty -d z
