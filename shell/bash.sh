# Source from ~/.bashrc to record the most recent command in each tmux pane.
[[ $- == *i* && -n ${TMUX_PANE:-} && -z ${_tmux_restore_bash_loaded:-} ]] || return 0

_tmux_restore_install_bash_hook() {
    local source_path=${BASH_SOURCE[0]} prompt_declaration bootstrap
    source "${source_path%/*}/command-record.sh" || return 1
    _tmux_restore_init_recorder || return 1

    _tmux_restore_bash_disarm() {
        local previous_status=$?
        _tmux_restore_bash_ready=0
        _tmux_restore_set_active 0 || :
        return "$previous_status"
    }

    _tmux_restore_bash_arm() {
        local previous_status=$?
        _tmux_restore_bash_ready=1
        return "$previous_status"
    }

    _tmux_restore_bash_capture() {
        [[ ${_tmux_restore_bash_ready:-0} == 1 && ${BASH_SUBSHELL:-0} == 0 ]] || return 0
        _tmux_restore_bash_ready=0
        [[ -o history ]] || return 0

        local seq=$((_tmux_restore_record_seq + 1)) file raw field
        file=$_tmux_restore_record_dir/slot.$((seq % 2))
        # Bash 3.2's history builtin provides the full entry and epoch. Write
        # it directly, then read it back with builtins to avoid forking Bash.
        if ! {
            printf '%s\0%s\0bash-history\0\0' "$seq" "$PWD" &&
            HISTTIMEFORMAT='%s ' builtin history 1 && printf '\0'
        } 2>/dev/null > "$file"; then
            return 0
        fi
        {
            IFS= read -r -d '' field && IFS= read -r -d '' field &&
            IFS= read -r -d '' field && IFS= read -r -d '' field &&
            IFS= read -r -d '' raw
        } 2>/dev/null < "$file" || return 0
        raw=${raw%$'\n'}
        # A history exclusion leaves the previous entry in place. Keep its
        # original directory and time instead of recording it again here.
        [[ -n $raw && $raw != "$_tmux_restore_bash_seen" ]] || return 0
        printf 'done.%s\0' "$seq" 2>/dev/null >> "$file" || return 0
        _tmux_restore_bash_seen=$raw
        _tmux_restore_record_seq=$seq
        _tmux_restore_set_active "$seq" || :
    }

    _tmux_restore_bash_enable() {
        # Ignore the last command imported at startup or the source command
        # that attached this hook to an existing interactive shell.
        _tmux_restore_bash_seen=$(HISTTIMEFORMAT='%s ' builtin history 1)
        if [[ $_tmux_restore_bash_prompt_kind == array ]]; then
            PROMPT_COMMAND=(_tmux_restore_bash_disarm "${_tmux_restore_bash_original[@]}" _tmux_restore_bash_arm)
        else
            PROMPT_COMMAND="_tmux_restore_bash_disarm"$'\n'"$_tmux_restore_bash_original"$'\n'"_tmux_restore_bash_arm"
        fi
        _tmux_restore_bash_ready=1
        trap 'case $BASH_COMMAND in _tmux_restore_bash_disarm|_tmux_restore_bash_arm) ;; *) _tmux_restore_bash_capture ;; esac' DEBUG
    }

    _tmux_restore_bash_conflict() {
        if [[ $_tmux_restore_bash_prompt_kind == array ]]; then
            PROMPT_COMMAND=("${_tmux_restore_bash_original[@]}")
        else
            PROMPT_COMMAND=$_tmux_restore_bash_original
        fi
        printf '%s\n' 'tmux-restore: command recording skipped because Bash already has a DEBUG trap.' >&2
    }

    # Sourcing a file or calling a function can temporarily hide DEBUG traps.
    # Check from the top-level first prompt, after the rc file has returned.
    bootstrap='if [[ -n $(trap -p DEBUG) ]]; then _tmux_restore_bash_conflict; else _tmux_restore_bash_enable; fi'
    prompt_declaration=$(declare -p PROMPT_COMMAND 2>/dev/null) || prompt_declaration=
    if [[ $prompt_declaration == 'declare -a'* ]]; then
        _tmux_restore_bash_prompt_kind=array
        _tmux_restore_bash_original=("${PROMPT_COMMAND[@]}")
        PROMPT_COMMAND+=("$bootstrap")
    else
        _tmux_restore_bash_prompt_kind=string
        _tmux_restore_bash_original=${PROMPT_COMMAND:-}
        PROMPT_COMMAND="$_tmux_restore_bash_original"$'\n'"$bootstrap"
    fi
    _tmux_restore_bash_loaded=1
}

_tmux_restore_install_bash_hook || :
