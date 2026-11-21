# Source from ~/.zshrc to record the most recent command in each tmux pane.
[[ -o interactive && -n ${TMUX_PANE:-} && -z ${_tmux_restore_zsh_loaded:-} ]] || return 0

source "${${(%):-%x}:A:h}/command-record.sh" || return 0
_tmux_restore_init_recorder || return 0
zmodload zsh/datetime || return 0
autoload -Uz add-zsh-hook

_tmux_restore_zsh_preexec() {
    local command_line=$1 seq=$((_tmux_restore_record_seq + 1))
    [[ -n $command_line ]] || return 0
    if [[ -o hist_ignore_space && $command_line == ' '* ]]; then
        return 0
    fi
    printf '%s\0%s\0zsh\0%s\0%s\0done.%s\0' "$seq" "$PWD" "$EPOCHSECONDS" "$command_line" "$seq" \
        2>/dev/null > "$_tmux_restore_record_dir/slot.$((seq % 2))" || return 0
    _tmux_restore_record_seq=$seq
    _tmux_restore_set_active "$seq" || :
}

_tmux_restore_zsh_precmd() { _tmux_restore_set_active 0 || :; }

add-zsh-hook preexec _tmux_restore_zsh_preexec
add-zsh-hook precmd _tmux_restore_zsh_precmd
_tmux_restore_zsh_loaded=1
