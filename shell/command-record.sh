# Internal helpers shared by the interactive Bash and zsh hooks.

_tmux_restore_record_root() {
    printf '%s\n' "${TMUX_RESTORE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/tmux-restore}/commands"
}

_tmux_restore_record_context() {
    local tmux_socket info server started pane pane_pid extra
    [[ -n ${TMUX:-} && -n ${TMUX_PANE:-} ]] || return 1
    tmux_socket=${TMUX%,*}
    tmux_socket=${tmux_socket%,*}
    info=$(command tmux -S "$tmux_socket" display-message -p -t "$TMUX_PANE" \
        '#{pid} #{start_time} #{pane_id} #{pane_pid}') || return 1
    read -r server started pane pane_pid extra <<< "$info"
    case $server:$started:${pane#%}:$pane_pid in
        *[!0-9:]*|:*|*::*|*:) return 1 ;;
    esac
    [[ $pane == "$TMUX_PANE" && $pane == %* && -z $extra ]] || return 1
    _tmux_restore_record_pane_pid=$pane_pid
    _tmux_restore_record_dir=$(_tmux_restore_record_root)/$started-$server/pane-${pane#%}
}

# The final NUL-terminated marker makes a partial write distinguishable from
# a complete record. Only one interactive pane-owner shell writes these files.
_tmux_restore_read_slot() {
    local file=$1 footer extra
    {
        IFS= read -r -d '' _tmux_restore_slot_seq &&
        IFS= read -r -d '' _tmux_restore_slot_cwd &&
        IFS= read -r -d '' _tmux_restore_slot_shell &&
        IFS= read -r -d '' _tmux_restore_slot_time &&
        IFS= read -r -d '' _tmux_restore_slot_command &&
        IFS= read -r -d '' footer && [[ $footer == "done.$_tmux_restore_slot_seq" ]] &&
        ! IFS= read -r -d '' extra && [[ -z $extra ]]
    } < "$file" || return 1
    case $_tmux_restore_slot_seq in
        ''|0*|*[!0-9]*) return 1 ;;
    esac
    [[ ${#_tmux_restore_slot_seq} -le 12 ]] || return 1
    if [[ $_tmux_restore_slot_shell != bash-history ]]; then
        case $_tmux_restore_slot_time in
            ''|*[!0-9]*) return 1 ;;
        esac
    fi
    [[ $_tmux_restore_slot_cwd == /* && -n $_tmux_restore_slot_command ]]
}

_tmux_restore_latest_slot() {
    local directory=$1 file latest=0
    local _tmux_restore_slot_seq _tmux_restore_slot_cwd _tmux_restore_slot_shell
    local _tmux_restore_slot_time _tmux_restore_slot_command
    for file in "$directory/slot.0" "$directory/slot.1"; do
        [[ -r $file ]] && _tmux_restore_read_slot "$file" 2>/dev/null || continue
        if (( _tmux_restore_slot_seq > latest )); then
            latest=$_tmux_restore_slot_seq
            _tmux_restore_latest_cwd=$_tmux_restore_slot_cwd
            _tmux_restore_latest_shell=$_tmux_restore_slot_shell
            _tmux_restore_latest_time=$_tmux_restore_slot_time
            _tmux_restore_latest_command=$_tmux_restore_slot_command
        fi
    done
    _tmux_restore_latest_seq=$latest
    (( latest > 0 ))
}

_tmux_restore_set_active() {
    [[ ${_tmux_restore_active_seq:-} != "$1" ]] || return 0
    printf '%s %s\n' "$$" "$1" 2>/dev/null > "$_tmux_restore_record_dir/active" || return 1
    _tmux_restore_active_seq=$1
}

_tmux_restore_init_recorder() {
    _tmux_restore_record_context 2>/dev/null || return 1
    [[ $_tmux_restore_record_pane_pid == "$$" ]] || return 1
    (umask 077; mkdir -p -- "$_tmux_restore_record_dir") || return 1
    _tmux_restore_latest_slot "$_tmux_restore_record_dir" || :
    _tmux_restore_record_seq=$_tmux_restore_latest_seq
    _tmux_restore_set_active 0
}
