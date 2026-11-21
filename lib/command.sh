# Normalize command records for Bash callers of the snapshot and replay code.

tmux_restore_decode_command() {
    local kind=$1 timestamp=$2 text=$3
    case $kind in
        bash-history)
            local entry='^[[:blank:]]*[0-9]+\*?[[:blank:]]+([0-9]+)[[:blank:]](.*)$'
            text=${text%$'\n'}
            [[ $text =~ $entry ]] || return 1
            tmux_restore_command_time=${BASH_REMATCH[1]}
            tmux_restore_command_text=${BASH_REMATCH[2]}
            tmux_restore_command_shell=bash
            ;;
        zsh|bash)
            case $timestamp in
                ''|*[!0-9]*) return 1 ;;
            esac
            tmux_restore_command_time=$timestamp
            tmux_restore_command_text=$text
            tmux_restore_command_shell=$kind
            ;;
        *) return 1 ;;
    esac
    [[ -n $tmux_restore_command_text ]]
}

tmux_restore_read_command_file() {
    _tmux_restore_read_slot "$1" || return 1
    tmux_restore_decode_command "$_tmux_restore_slot_shell" "$_tmux_restore_slot_time" \
        "$_tmux_restore_slot_command" || return 1
    tmux_restore_command_directory=$_tmux_restore_slot_cwd
}

tmux_restore_application_process() {
    case ${1##*/} in
        ''|sh|bash|zsh|fish|ksh|dash|ash|tcsh|csh|nu|restore-pane) return 1 ;;
        *) return 0 ;;
    esac
}

tmux_restore_read_active_command() {
    local directory=$1 process=$2 pane_pid=$3 active recorded_pid
    [[ -n $pane_pid ]] || return 1
    if [[ -f $directory/active ]]; then
        IFS=' ' read -r recorded_pid active < "$directory/active" || return 1
        [[ $recorded_pid == "$pane_pid" && -n $active && $active != 0 ]] || return 1
        _tmux_restore_latest_slot "$directory" || return 1
        [[ $_tmux_restore_latest_seq == "$active" && $(< "$directory/active") == "$pane_pid $active" ]] || return 1
    else
        # Shells already open at upgrade time may still use the original hook.
        tmux_restore_application_process "$process" && _tmux_restore_latest_slot "$directory" || return 1
    fi
    tmux_restore_decode_command "$_tmux_restore_latest_shell" "$_tmux_restore_latest_time" \
        "$_tmux_restore_latest_command"
}
