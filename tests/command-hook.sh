#!/usr/bin/env bash
set -eu

repo=$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd)
source "$repo/shell/command-record.sh"
source "$repo/lib/command.sh"
source "$repo/lib/restore-prompt.sh"
fixture=$(mktemp -d /tmp/tmux-restore-test.XXXXXXXX)
fixture=$(cd -- "$fixture" && pwd -P)
socket=$fixture/tmux.sock

cleanup() {
    tmux -S "$socket" kill-server >/dev/null 2>&1 || :
    rm -rf -- "$fixture"
}
trap cleanup EXIT

export TMUX_RESTORE_STATE_DIR=$fixture/state
export TMUX_RESTORE_TEST_REPO=$repo
export BASH_SILENCE_DEPRECATION_WARNING=1
export HISTFILE=$fixture/history
mkdir -p "$fixture/a dir" "$fixture/b dir"
cd -- "$fixture/a dir"

test_tmux() { command tmux -S "$socket" "$@"; }

enter() {
    test_tmux send-keys -l -t "$TMUX_PANE" -- "$1"
    test_tmux send-keys -t "$TMUX_PANE" Enter
}

wait_for_screen() {
    local count output
    for ((count=0; count<120; count++)); do
        output=$(test_tmux capture-pane -p -t "$TMUX_PANE")
        if [[ $output == *"$1"* ]]; then return 0; fi
        sleep 0.05
    done
    printf 'Did not find %s in pane output:\n%s\n' "$1" "$output" >&2
    return 1
}

last_command() {
    _tmux_restore_record_context && _tmux_restore_latest_slot "$_tmux_restore_record_dir" &&
        tmux_restore_decode_command "$_tmux_restore_latest_shell" "$_tmux_restore_latest_time" \
            "$_tmux_restore_latest_command"
}

saved_command() {
    "$repo/bin/tmux-restore" --socket "$socket" save >/dev/null || return 1
    printf '%s\n' "$TMUX_RESTORE_STATE_DIR/snapshots/$(< "$TMUX_RESTORE_STATE_DIR/last")/panes/${TMUX_PANE#%}.command"
}

wait_for_idle() {
    local count activity
    for ((count=0; count<100; count++)); do
        activity=$(< "$_tmux_restore_record_dir/active")
        if [[ $activity == "$_tmux_restore_record_pane_pid 0" ]]; then return 0; fi
        sleep .05
    done
    printf '%s\n' 'Shell did not mark the command as finished.' >&2
    return 1
}

test_hook() {
    local shell_name=$1 activate hook command_file
    case $shell_name in
        bash)
            activate='HISTCONTROL=ignorespace; PROMPT_COMMAND=":"; '
            hook=bash.sh
            TMUX_PANE=$(test_tmux new-window -d -P -F '#{pane_id}' -c "$PWD" -n bash "$BASH" --noprofile --norc -i)
            ;;
        zsh)
            activate='setopt hist_ignore_space; '
            hook=zsh.zsh
            TMUX_PANE=$(test_tmux new-window -d -P -F '#{pane_id}' -c "$PWD" -n zsh zsh -f -i)
            ;;
    esac
    enter "${activate}source \"\$TMUX_RESTORE_TEST_REPO/shell/$hook\"; printf '%s\n' HOOK- READY"
    wait_for_screen $'HOOK-\nREADY'

    local line='cd "../b dir" && printf "%s\n" CHAIN- COMPLETE && read -r fixture_pause'
    enter "$line"
    wait_for_screen $'CHAIN-\nCOMPLETE'
    last_command
    [[ $tmux_restore_command_text == "$line" ]]
    [[ $tmux_restore_command_shell == "$shell_name" ]]
    [[ $_tmux_restore_latest_cwd == "$fixture/a dir" ]]
    [[ $tmux_restore_command_time =~ ^[0-9]+$ ]]
    local seq=$_tmux_restore_latest_seq

    command_file=$(saved_command)
    tmux_restore_read_command_file "$command_file"
    [[ $tmux_restore_command_text == "$line" && $tmux_restore_command_directory == "$fixture/a dir" ]]

    test_tmux send-keys -t "$TMUX_PANE" Enter
    wait_for_idle
    command_file=$(saved_command)
    [[ ! -e $command_file ]]

    enter ' printf "%s\n" IGNORED- FINISHED; read -r fixture_pause'
    wait_for_screen $'IGNORED-\nFINISHED'
    last_command
    [[ $_tmux_restore_latest_seq == "$seq" && $tmux_restore_command_text == "$line" ]]
    [[ $_tmux_restore_latest_cwd == "$fixture/a dir" ]]
    command_file=$(saved_command)
    [[ ! -e $command_file ]]
    test_tmux send-keys -t "$TMUX_PANE" Enter

    # Simulate an interrupted write to the other slot.
    printf '%s\0%s\0' "$((seq + 1))" "$fixture/b dir" \
        > "$_tmux_restore_record_dir/slot.$(((seq + 1) % 2))"
    last_command
    [[ $_tmux_restore_latest_seq == "$seq" ]]
    printf '%s running command, idle prompt, and history exclusion passed\n' "$shell_name"
}

test_tmux -f /dev/null new-session -d -s hooks /bin/cat
export TMUX="$socket,$(test_tmux display-message -p '#{pid}'),0"
export TMUX_PANE
test_hook bash
test_hook zsh

TMUX_PANE=$(test_tmux new-window -d -P -F '#{pane_id}' -n original-trap "$BASH" --noprofile --norc -i)
enter 'trap '\''printf "%s\n" DEBUG-ORIGINAL'\'' DEBUG; source "$TMUX_RESTORE_TEST_REPO/shell/bash.sh"'
wait_for_screen 'Bash already has a DEBUG trap.'
enter 'printf "%s\n" CHECK- ORIGINAL'
wait_for_screen $'DEBUG-ORIGINAL\nCHECK-\nORIGINAL'
if last_command; then exit 1; fi
printf '%s\n' 'Existing Bash DEBUG trap preserved'

for key in r R; do
    tmux_restore_prompt 'Nov 19 09:12' '09:38' 'npm ci && npm run dev' "$fixture/b dir" \
        <<< "$key" > "$fixture/prompt"
    content=$(< "$fixture/prompt")
    [[ $content == *'[r]estore / any other key to dismiss'* ]]
    [[ $content == *'npm ci && npm run dev'* ]]
done
if tmux_restore_prompt 'Nov 19 09:12' '09:38' 'npm ci && npm run dev' "$PWD" <<< x >/dev/null; then
    exit 1
fi
(
    # The replay runs a shell with harmless fixtures and leaves the parent cwd in place.
    unset TMUX TMUX_PANE
    mkdir "$fixture/bin"
    printf '#!/bin/sh\nexec "%s" --noprofile --norc "$@"\n' "$BASH" > "$fixture/bin/bash"
    chmod +x "$fixture/bin/bash"
    export PATH="$fixture/bin:$PATH"
    [[ $(tmux_restore_replay bash "$fixture/b dir" 'printf "%s" "$PWD"' 2>/dev/null) == "$fixture/b dir" ]]
    [[ $PWD == "$fixture/a dir" ]]

    # Exercise the entry point used to bootstrap a newly restored pane.
    printf '#!/bin/sh\nprintf "PANE=%%s\\n" "$PWD"\n' > "$fixture/shell"
    chmod +x "$fixture/shell"
    printf 'OLD OUTPUT\n' > "$fixture/scrollback"
    printf '%s\0%s\0bash\0%s\0%s\0done.1\0' 1 "$fixture/b dir" 1795076018 \
        'printf "REPLAY=%s\n" "$PWD"' > "$fixture/command"
    for key in x r R; do
        restored=$("$repo/libexec/restore-pane" "$fixture/a dir" "$fixture/scrollback" \
            1795077018 "$fixture/shell" "$fixture/command" 2>/dev/null <<< "$key")
        [[ $restored == 'OLD OUTPUT'*'Tmux restored'*'[r]estore / any other key to dismiss'* ]]
        [[ $restored == *"PANE=$fixture/a dir" ]]
        if [[ $key == x ]]; then
            [[ $restored != *"REPLAY=$fixture/b dir"* ]]
        else
            [[ $restored == *"REPLAY=$fixture/b dir"* ]]
        fi
    done
)
printf '%s\n' 'Prompt keys and command replay directory passed'
