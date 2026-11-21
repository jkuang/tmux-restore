# Restore into newly created sessions. Never replace a pre-existing session.

tr_literal_format() { printf '%s\n' "${1//#/##}"; }

tr_restore_window() {
    local snapshot=$1 old_window=$2 new_window=$3 width=$4 height=$5 layout=$6 zoomed=$7
    local row key directory pane first count=0 index=0 output command recorded_shell signature
    local -a keys directories commands
    keys=() directories=() commands=()
    while IFS= read -r -d "$TR_ROW" row; do
        tr_fields "$row" "$TR_PANE_FIELDS" || return 1
        [[ ${TR_FIELDS[0]} == "$old_window" ]] || continue
        tr_pane_id "${TR_FIELDS[1]}" || return 1
        key=${TR_FIELDS[1]#%}
        [[ -f $snapshot/panes/$key.screen ]] || return 1
        # A linked window repeats its panes in the server-wide listing.
        for pane in "${keys[@]}"; do [[ $pane != "$key" ]] || key=; done
        [[ -n $key ]] || continue
        directory=${TR_FIELDS[4]}
        if [[ $directory != /* || ! -d $directory ]]; then directory=$HOME; fi
        command=$snapshot/panes/$key.command
        if [[ $TR_SNAPSHOT_VERSION == 1 && -r $command ]] &&
            ! tmux_restore_application_process "${TR_FIELDS[5]}"; then
            # An old snapshot could contain a stale command from an idle shell.
            signature=$snapshot/panes/$key.signature
            if [[ ! -r $signature || $(< "$signature") != pending:* ]]; then command=; fi
        fi
        keys[count]=$key
        directories[count]=$directory
        commands[count]=$command
        count=$((count + 1))
    done < "$snapshot/panes.meta"
    (( count > 0 )) || return 1

    tr_tmux resize-window -t "$new_window" -x "$width" -y "$height" || return 1
    first=$(tr_tmux display-message -p -t "$new_window" '#{pane_id}') || return 1
    for ((index=1; index<count; index++)); do
        # Empty floating panes need no additional room in the current grid.
        # The saved v2 layout assigns their real positions and pane order.
        tr_tmux new-pane -d -E -t "$first" || return 1
    done
    tr_tmux select-layout -t "$new_window" "$layout" || return 1
    output=$(tr_tmux list-panes -t "$new_window" -F '#{pane_id}') || return 1
    index=0
    while IFS= read -r pane; do
        tr_pane_id "$pane" && (( index < count )) || return 1
        key=${keys[index]}
        command=${commands[index]}
        recorded_shell=$TR_DEFAULT_SHELL
        if [[ -r $command ]] && tmux_restore_read_command_file "$command" &&
            command -v "$tmux_restore_command_shell" >/dev/null; then
            recorded_shell=$(command -v "$tmux_restore_command_shell")
        fi
        tr_tmux respawn-pane -t "$pane" "$TR_REPO/libexec/restore-pane" "${directories[index]}" \
            "$snapshot/panes/$key.screen" "$TR_SAVED_AT" "$recorded_shell" "$command" "$snapshot/panes/$key.process" || return 1
        index=$((index + 1))
    done <<< "$output"
    (( index == count )) || return 1
    if [[ $zoomed == 1 && $count -gt 1 ]]; then tr_tmux resize-pane -Z -t "$new_window" || return 1; fi
    tr_tmux set-option -wu -t "$new_window" window-size || return 1
}

tr_load() (
    local snapshot=$1 row saved_session session name active index=0 slot=99999 chosen=0
    local saved_window window zoom width height layout win_name existing found state=building id placeholder
    local TR_SAVED_AT TR_DEFAULT_SHELL TR_SNAPSHOT_VERSION TR_PANE_FIELDS meta_server meta_active
    local needed_history=0 current_history _output _generation lines _added _collected _width pane_height
    local -a old_sessions names active_windows sessions placeholders old_windows windows
    old_sessions=() names=() active_windows=() sessions=() placeholders=() old_windows=() windows=()
    {
        IFS= read -r TR_SNAPSHOT_VERSION && IFS= read -r TR_SAVED_AT &&
        IFS= read -r meta_server && IFS= read -r meta_active
    } < "$snapshot/meta" || return 1
    case $TR_SNAPSHOT_VERSION in
        1) TR_PANE_FIELDS=6 ;;
        2) TR_PANE_FIELDS=7 ;;
        *) tr_error 'Unsupported snapshot format.'; return 1 ;;
    esac
    tr_uint "$TR_SAVED_AT" || { tr_error 'Invalid snapshot timestamp.'; return 1; }
    TR_DEFAULT_SHELL=$(tr_tmux show-option -gqv default-shell) || return 1
    [[ -x $TR_DEFAULT_SHELL ]] || TR_DEFAULT_SHELL=/bin/sh
    current_history=$(tr_option history-limit 2000) || return 1
    tr_uint "$current_history" || return 1
    while IFS= read -r -d "$TR_ROW" row; do
        tr_fields "$row" "$TR_PANE_FIELDS" || return 1
        IFS=: read -r _output _generation lines _added _collected _width pane_height <<< "${TR_FIELDS[3]}"
        tr_uint "$lines" && tr_uint "$pane_height" || return 1
        if (( lines + pane_height + 16 > needed_history )); then needed_history=$((lines + pane_height + 16)); fi
    done < "$snapshot/panes.meta"

    while IFS= read -r -d "$TR_ROW" row; do
        tr_fields "$row" 3 && tr_session_id "${TR_FIELDS[0]}" && tr_uint "${TR_FIELDS[2]}" || return 1
        name=${TR_FIELDS[1]}
        if tr_tmux has-session -t "=$name" 2>/dev/null; then
            tr_error "Session '$name' already exists. Load into a fresh server or choose a different existing session name."
            return 1
        fi
        old_sessions[index]=${TR_FIELDS[0]} names[index]=$name active_windows[index]=${TR_FIELDS[2]}
        index=$((index + 1))
    done < "$snapshot/sessions"
    (( index > 0 )) || return 1

    # Reserve an unused index for each temporary empty bootstrap window.
    while IFS= read -r -d "$TR_ROW" row; do
        tr_fields "$row" 8 && tr_uint "${TR_FIELDS[2]}" || return 1
        if (( TR_FIELDS[2] >= slot )); then slot=$((TR_FIELDS[2] + 1)); fi
    done < "$snapshot/windows"
    (( slot <= 2147483647 )) || return 1

    trap 'if [[ $state == building ]]; then
        for id in "${sessions[@]}"; do tr_tmux kill-session -t "$id" >/dev/null 2>&1 || :; done
    fi' EXIT
    trap 'exit 130' INT TERM HUP

    for ((index=0; index<${#old_sessions[@]}; index++)); do
        session=$(tr_tmux new-session -d -E -P -F '#{session_id}' -s "tmux-restore-$$-$index-$RANDOM") || return 1
        tr_session_id "$session" || return 1
        sessions[index]=$session
        tr_tmux set-option -t "$session" renumber-windows off || return 1
        if (( needed_history > current_history )); then
            tr_tmux set-option -t "$session" history-limit "$needed_history" || return 1
        fi
        placeholder=$(tr_tmux display-message -p -t "$session" '#{window_id}') || return 1
        placeholders[index]=$placeholder
        tr_tmux move-window -s "$placeholder" -t "$session:$slot" || return 1
        if [[ ${old_sessions[index]} == "$meta_active" ]]; then chosen=$index; fi
    done

    while IFS= read -r -d "$TR_ROW" row; do
        tr_fields "$row" 8 || return 1
        saved_session=${TR_FIELDS[0]} saved_window=${TR_FIELDS[1]} index=${TR_FIELDS[2]}
        zoom=${TR_FIELDS[3]} width=${TR_FIELDS[4]} height=${TR_FIELDS[5]} win_name=${TR_FIELDS[6]} layout=${TR_FIELDS[7]}
        tr_window_id "$saved_window" && tr_uint "$index" && tr_uint "$zoom" && tr_uint "$width" &&
            tr_uint "$height" && [[ $layout == \{* ]] || return 1
        session=
        for ((found=0; found<${#old_sessions[@]}; found++)); do
            if [[ ${old_sessions[found]} == "$saved_session" ]]; then session=${sessions[found]}; break; fi
        done
        [[ -n $session ]] || return 1
        existing=
        for ((found=0; found<${#old_windows[@]}; found++)); do
            if [[ ${old_windows[found]} == "$saved_window" ]]; then existing=${windows[found]}; break; fi
        done
        if [[ -n $existing ]]; then
            tr_tmux link-window -d -s "$existing" -t "$session:$index" || return 1
        else
            window=$(tr_tmux new-window -d -E -P -F '#{window_id}' -n restoring -t "$session:$index") || return 1
            tr_window_id "$window" || return 1
            tr_tmux rename-window -t "$window" -- "$(tr_literal_format "$win_name")" || return 1
            tr_restore_window "$snapshot" "$saved_window" "$window" "$width" "$height" "$layout" "$zoom" || return 1
            old_windows[found]=$saved_window windows[found]=$window
        fi
    done < "$snapshot/windows"

    for ((index=0; index<${#sessions[@]}; index++)); do
        session=${sessions[index]}
        tr_tmux select-window -t "$session:${active_windows[index]}" || return 1
        tr_tmux kill-window -t "${placeholders[index]}" || return 1
        tr_tmux set-option -u -t "$session" renumber-windows || return 1
        tr_tmux rename-session -t "$session" -- "$(tr_literal_format "${names[index]}")" || return 1
    done
    state=done
    tr_tmux set-option -g @tmux-restore-restored-session "${sessions[chosen]}"
)
