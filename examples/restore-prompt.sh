#!/usr/bin/env bash

source "${BASH_SOURCE[0]%/*}/../lib/restore-prompt.sh" || exit 1

command_line='printf "%s\n" "Restore confirmed." && pwd'
printf '%s\n' '$ npm ci && npm run dev' 'Local: http://localhost:5173/'
if tmux_restore_prompt 'Nov 19 09:12' '09:38' "$command_line" "$PWD"; then
    tmux_restore_replay bash "$PWD" "$command_line"
else
    printf '%s\n' 'Dismissed.'
fi
