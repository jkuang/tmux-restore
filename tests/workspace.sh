#!/usr/bin/env bash
set -eo pipefail

repo=$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd)
fixture=$(mktemp -d /tmp/tmux-restore-workspace.XXXXXXXX)
fixture=$(cd -- "$fixture" && pwd -P)
source_socket=$fixture/source.sock
restore_socket=$fixture/restore.sock
timer_socket=$fixture/timer.sock

cleanup() {
    for socket in "$source_socket" "$restore_socket" "$timer_socket"; do
        tmux -S "$socket" kill-server >/dev/null 2>&1 || :
    done
    rm -rf -- "$fixture"
}
trap cleanup EXIT
export TMUX_RESTORE_STATE_DIR=$fixture/state
mkdir "$fixture/one dir" "$fixture/two dir"

t() { command tmux -S "$source_socket" "$@"; }
r() { command tmux -S "$restore_socket" "$@"; }
timer() { command tmux -S "$timer_socket" "$@"; }
save() { "$repo/bin/tmux-restore" --socket "$source_socket" save; }
latest() { cat "$TMUX_RESTORE_STATE_DIR/last"; }
assert_eq() {
    if [[ $1 != "$2" ]]; then printf 'Expected <%s>, got <%s>\n' "$2" "$1" >&2; return 1; fi
}
wait_for() {
    local i
    for ((i=0; i<100; i++)); do
        if "$@"; then return 0; fi
        sleep 0.1
    done
    printf 'Timeout waiting for %s\n' "$*" >&2
    return 1
}

t -f /dev/null new-session -d -s 'active work' -n 'Main' -x 140 -y 45 -c "$fixture/one dir" /bin/cat
t set -g default-shell /bin/sh
p0=$(t list-panes -t 'active work:0' -F '#{pane_id}')
p1=$(t split-window -h -d -P -F '#{pane_id}' -t "$p0" -c "$fixture/two dir" /bin/cat)
p2=$(t split-window -v -d -P -F '#{pane_id}' -t "$p1" -c "$fixture/one dir" /bin/cat)
t new-window -d -t 'active work:4' -n 'Second' /bin/cat
t rename-window -t 'active work:4' 'Task ##{session_name} with spaces'
t new-session -d -s parked -c "$fixture/two dir" /bin/cat
t link-window -d -s 'active work:4' -t 'parked:2'
t select-pane -t "$p2"
for pane in "$p0" "$p1" "$p2"; do
    t send-keys -t "$pane" -l "SCROLLBACK-$pane"
    t send-keys -t "$pane" Enter
done
contains_text() { [[ $(t capture-pane -p -t "$p2") == *"SCROLLBACK-$p2"* ]]; }
wait_for contains_text
source_identity=$(t display-message -p '#{start_time}-#{pid}')
record_dir=$TMUX_RESTORE_STATE_DIR/commands/$source_identity/pane-${p2#%}
mkdir -p "$record_dir"
printf '1\0%s\0bash\0%s\0%s\0done.1\0' "$fixture/two dir" 1795076018 \
    'printf "RERAN: %s\n" "$PWD"' > "$record_dir/slot.1"
printf '%s 1\n' "$(t display-message -p -t "$p2" '#{pane_pid}')" > "$record_dir/active"
save >/dev/null
first=$(latest)
assert_eq "$(cat "$TMUX_RESTORE_STATE_DIR/snapshots/$first/stats")" '5 0'

t swap-window -d -s 'active work:0' -t 'active work:4'
save >/dev/null
second=$(latest)
[[ $first != "$second" ]]
assert_eq "$(cat "$TMUX_RESTORE_STATE_DIR/snapshots/$second/stats")" '0 5'
[[ $TMUX_RESTORE_STATE_DIR/snapshots/$first/panes/${p0#%}.screen -ef $TMUX_RESTORE_STATE_DIR/snapshots/$second/panes/${p0#%}.screen ]]
expected_windows=$(t list-windows -a -F '#{session_name}|#{window_index}|#{window_name}')
expected_geometry=$(t list-panes -t 'active work:4' -F '#{pane_current_path}|#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}')
if "$repo/bin/tmux-restore" --socket "$source_socket" load > "$fixture/conflict" 2>&1; then exit 1; fi
[[ $(< "$fixture/conflict") == *'already exists'* ]]
assert_eq "$(latest)" "$second"

# Force the capture of new output to fail midway through staging.
t send-keys -t "$p2" -l 'FRESH-OUTPUT'
t send-keys -t "$p2" Enter
has_fresh_output() { [[ $(t capture-pane -p -t "$p2") == *'FRESH-OUTPUT'* ]]; }
wait_for has_fresh_output
mkdir "$fixture/failing-bin"
cat > "$fixture/failing-bin/tmux" <<'SH'
#!/bin/sh
if [ "$1" = -u ] && [ "$2" = -S ] && [ "$4" = capture-pane ]; then exit 9; fi
exec "$TMUX_RESTORE_TEST_REAL_TMUX" "$@"
SH
chmod +x "$fixture/failing-bin/tmux"
if (export TMUX_RESTORE_TEST_REAL_TMUX=$(command -v tmux); PATH="$fixture/failing-bin:$PATH" save) > /dev/null 2>&1; then exit 1; fi
assert_eq "$(latest)" "$second"
[[ -z $(find "$TMUX_RESTORE_STATE_DIR/snapshots" -name '.staging.*' -type d) ]]

t set -g @tmux-restore-retain 0
if save >/dev/null 2>&1; then exit 1; fi
assert_eq "$(latest)" "$second"
t set -g @tmux-restore-retain 1
save >/dev/null
third=$(latest)
[[ ! -e $TMUX_RESTORE_STATE_DIR/snapshots/$first && ! -e $TMUX_RESTORE_STATE_DIR/snapshots/$second ]]
assert_eq "$(cat "$TMUX_RESTORE_STATE_DIR/snapshots/$third/stats")" '1 4'
printf '%s\n' 'Atomic saves, conflict refusal, retention, and scrollback reuse passed'

# Load the approved config with a plugin path containing special characters.
printf '%s\n' 'set -g default-shell /bin/sh' > "$fixture/restore-config"
printf 'yes\n' | "$repo/setup.sh" --no-shell-hook --tmux-conf "$fixture/restore-config" \
    --install-dir "$fixture/plugin install's #1 canned \$PATH" > "$fixture/install-output"
r -f "$fixture/restore-config" start-server
if ! r has-session; then
    cat "$fixture/restore-config" >&2
    r show-options -g | awk '/tmux-restore/' >&2
    r show-messages >&2 || :
fi
assert_eq "$(r list-windows -a -F '#{session_name}|#{window_index}|#{window_name}')" "$expected_windows"
assert_eq "$(r list-panes -t 'active work:4' -F '#{pane_current_path}|#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}')" "$expected_geometry"
assert_eq "$(r display-message -p -t 'active work:0' '#{window_id}')" "$(r display-message -p -t 'parked:2' '#{window_id}')"
pane_text_ready() {
    local restored_pane index=0
    local -a original
    original=("$p0" "$p1" "$p2")
    while IFS= read -r restored_pane; do
        [[ $(r capture-pane -p -S - -t "$restored_pane") == *"SCROLLBACK-${original[index]}"* ]] || return 1
        index=$((index + 1))
    done < <(r list-panes -t 'active work:4' -F '#{pane_id}')
    (( index == 3 ))
}
wait_for pane_text_ready
restored_p2=$(r list-panes -t 'active work:4' -F '#{pane_id}' | tail -n 1)
restore_identity=$(r display-message -p '#{start_time}-#{pid}')
pending=$TMUX_RESTORE_STATE_DIR/commands/$restore_identity/pane-${restored_p2#%}/pending
is_pending() { [[ -f $pending/command ]]; }
wait_for is_pending
"$repo/bin/tmux-restore" --socket "$restore_socket" save >/dev/null
snapshot=$TMUX_RESTORE_STATE_DIR/snapshots/$(latest)
restored_record=$snapshot/panes/${restored_p2#%}
cmp "$record_dir/slot.1" "$restored_record.command"
cmp "$pending/screen" "$restored_record.screen"
[[ $(< "$restored_record.screen") != *'Tmux restored'* ]]
r send-keys -t "$restored_p2" x
is_dismissed() { [[ ! -e $pending ]]; }
wait_for is_dismissed
"$repo/bin/tmux-restore" --socket "$restore_socket" save >/dev/null
snapshot=$TMUX_RESTORE_STATE_DIR/snapshots/$(latest)
[[ ! -e $snapshot/panes/${restored_p2#%}.command ]]
[[ $(< "$snapshot/panes/${restored_p2#%}.screen") != *'Tmux restored'* ]]
printf '%s\n' 'Pending replay retains original text and command; dismissal removes the suggestion and banner'
binding=$(r list-keys -T root M-s)
[[ $binding == *'M-s'*'run-shell -b'*'/bin/tmux-restore'*' save '* ]]
r source-file "$fixture/restore-config"
assert_eq "$(r show-hooks -g after-swap-window | awk '/\[684\]/{n++} END{print n+0}')" 1
printf '%s\n' 'Setup, automatic cold restore, window links, geometry, directory and text round trip passed'

export TMUX_RESTORE_STATE_DIR=$fixture/timer-state
cat > "$fixture/timer-config" <<CONF
set -g status off
set -g @tmux-restore-debounce 2
set -g @tmux-restore-autosave 6
run-shell '$repo/tmux-restore.tmux'
CONF
timer -f "$fixture/timer-config" new-session -d -s timer /bin/cat
for ((i=0; i<10; i++)); do timer rename-window -t timer:0 "change-$i"; done
[[ ! -f $TMUX_RESTORE_STATE_DIR/last ]]
has_snapshot() { [[ -f $TMUX_RESTORE_STATE_DIR/last ]]; }
wait_for has_snapshot
baseline=$(latest)
assert_eq "$(find "$TMUX_RESTORE_STATE_DIR/snapshots" -name 'snap-*' -type d | wc -l | tr -d '[:space:]')" 1
next_snapshot() { [[ $(latest) != "$baseline" ]]; }
wait_for next_snapshot
[[ -z $(timer list-clients) ]]
printf '%s\n' 'One save for ten rapid edits and periodic autosave without clients or status bar passed'

previous=$(latest)
# A control-mode client detaches when this input pipe closes.
timer -C attach-session -t timer < <(sleep 0.4) > /dev/null
is_detach_saved() { [[ $(latest) != "$previous" ]]; }
wait_for is_detach_saved
printf '%s\n' 'Last client detach requests an immediate save'

previous=$(latest)
timer set -g @tmux-restore-phase restoring
is_paused() { [[ $(timer show-option -gqv @tmux-restore-paused) == 1 ]]; }
wait_for is_paused
assert_eq "$(latest)" "$previous"
[[ $(timer show-option -gqv @tmux-restore-error) == *'Restore interrupted'* ]]
printf '%s\n' 'Interrupted restore state pauses autosave and preserves the published snapshot'
