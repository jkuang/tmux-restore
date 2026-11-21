# Tmux records changes using its own command queue. One worker per server
# combines those notifications and runs the timer even without a client.

tr_shell_word() {
    local word=${1//\'/\'\\\'\'}
    printf "'%s'" "$word"
}

tr_background_command() {
    local line
    line="$(tr_shell_word "$TR_CLI") --socket $(tr_shell_word "$TR_SOCKET") $1"
    # run-shell expands tmux formats before passing the string to /bin/sh.
    printf '%s\n' "${line//#/##}"
}

tr_bootstrap() {
    local event command output start_attempted auto
    auto=$(tr_option @tmux-restore-auto-load on) || return 1
    start_attempted=$(tr_option @tmux-restore-start-attempted no) || return 1
    if [[ $start_attempted == no ]]; then
        tr_tmux set-option -g @tmux-restore-start-attempted yes || return 1
        if [[ $auto == on ]] && ! tr_tmux has-session 2>/dev/null && tr_latest >/dev/null; then
            if ! output=$(tr_lock "$TR_STATE/snapshot.lock" wait "$TR_CLI" --socket "$TR_SOCKET" _load 2>&1); then
                tr_tmux set-option -g @tmux-restore-paused 1 || return 1
                tr_error "Automatic restore failed. Autosave is paused. $output"
            fi
        fi
    fi

    # Numbered entries survive config reloads and leave other hook slots alone.
    for event in session-created session-closed session-renamed window-created window-closed \
        window-linked window-unlinked after-rename-window after-swap-window window-layout-changed \
        window-zoomed window-unzoomed; do
        tr_tmux set-hook -g "$event[684]" \
            'if-shell -F "#{!=:#{@tmux-restore-phase},restoring}" "set-option -g @tmux-restore-dirty 1"' || return 1
    done
    command=$(tr_background_command _detach) || return 1
    tr_tmux set-hook -g 'client-detached[684]' "run-shell -b $(tr_shell_word "$command")" || return 1
    command=$(tr_background_command _worker) || return 1
    tr_tmux run-shell -b "$command"
}

tr_worker() {
    local debounce interval output dirty last_save paused phase pending=0 last_change=0 previous= deadline code poll
    debounce=$(tr_option @tmux-restore-debounce 10) || return 1
    interval=$(tr_option @tmux-restore-autosave 300) || return 1
    if ! tr_uint "$debounce" || ! tr_uint "$interval"; then
        tr_error 'Debounce and autosave intervals must be whole seconds.'; return 1
    fi
    deadline=$((SECONDS + interval))
    while output=$(tr_tmux display-message -p '#{@tmux-restore-dirty}|#{@tmux-restore-last-save}|#{@tmux-restore-paused}|#{@tmux-restore-phase}' \
        \; set-option -gu @tmux-restore-dirty 2>/dev/null); do
        IFS='|' read -r dirty last_save paused phase <<< "$output"
        if [[ $last_save != "$previous" ]]; then
            previous=$last_save
            deadline=$((SECONDS + interval))
        fi
        if [[ $dirty == 1 ]]; then pending=1; last_change=$SECONDS; fi
        if [[ -n $phase ]]; then
            # The lock makes this a no-op for a real ongoing transaction.
            tr_lock "$TR_STATE/snapshot.lock" try "$TR_CLI" --socket "$TR_SOCKET" _recover || :
        elif [[ $paused != 1 ]] && { (( pending && SECONDS >= last_change + debounce )) ||
            (( interval > 0 && SECONDS >= deadline )); }; then
            code=0
            tr_lock "$TR_STATE/snapshot.lock" try "$TR_CLI" --socket "$TR_SOCKET" _save || code=$?
            if [[ $code != 75 ]]; then
                pending=0
                deadline=$((SECONDS + interval))
            fi
        fi
        poll=2
        if (( pending )); then poll=1; fi
        sleep "$poll"
    done
}

tr_recover() {
    local phase
    phase=$(tr_option @tmux-restore-phase idle) || return 1
    [[ $phase != idle ]] || return 0
    if [[ $phase == restoring ]]; then
        tr_tmux set-option -g @tmux-restore-paused 1 || return 1
        tr_tmux set-option -g @tmux-restore-error 'Restore interrupted. Autosave paused to preserve the last snapshot.' || return 1
    else
        tr_tmux set-option -g @tmux-restore-error 'Save interrupted. The last completed snapshot is still available.' || return 1
    fi
    tr_tmux set-option -gu @tmux-restore-phase
}
