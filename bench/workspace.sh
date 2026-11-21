#!/usr/bin/env bash
# Reproduce the 10-window, 30-pane benchmark with synthetic scrollback.
set -eo pipefail
repo=$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)
fixture=$(mktemp -d /tmp/tmux-restore-large.XXXXXXXX)
fixture=$(cd -- "$fixture" && pwd -P)
socket=$fixture/bench.sock
t() { command tmux -S "$socket" "$@"; }
trap 't kill-server >/dev/null 2>&1 || :; rm -rf -- "$fixture"' EXIT
export TMUX_RESTORE_STATE_DIR=$fixture/state
cat > "$fixture/config" <<'CONF'
set -g history-limit 12000
set -g status off
CONF
cat > "$fixture/generate" <<'SH'
#!/usr/bin/env bash
while [[ ! -f $1 ]]; do sleep 0.05; done
awk -v n="$2" -v pane="$3" 'BEGIN {
  for (i=1; i<=n+73; i++) printf "INFO pane=%02d line=%05d id=%08x path=/api/billing/workspaces/%05d status=200\n", pane, i, i*i+pane, i
}'
exec /bin/cat
SH
chmod +x "$fixture/generate"

pane_number=0
for ((index=0; index<10; index++)); do
    if (( index == 0 )); then
        window=$(t -f "$fixture/config" new-session -d -P -F '#{window_id}' -x 426 -y 74 -s bench \
            "$fixture/generate" "$fixture/go" 10000 "$pane_number")
    else
        lines=10000
        if (( pane_number % 2 )); then lines=500; fi
        window=$(t new-window -d -P -F '#{window_id}' -t "bench:$index" \
            "$fixture/generate" "$fixture/go" "$lines" "$pane_number")
    fi
    pane_number=$((pane_number + 1))
    for split in 1 2; do
        lines=10000
        if (( pane_number % 2 )); then lines=500; fi
        t split-window -h -d -t "$window" "$fixture/generate" "$fixture/go" "$lines" "$pane_number"
        pane_number=$((pane_number + 1))
    done
    t select-layout -t "$window" even-horizontal
done
touch "$fixture/go"
for ((i=0; i<200; i++)); do
    panes=$(t list-panes -a -F '#{pane_current_command} #{history_size}')
    total=$(awk '$1=="cat" {n++; sum+=$2} END {if(n==30) print sum}' <<< "$panes")
    if [[ -n $total ]]; then break; fi
    sleep 0.1
done
[[ ${total:-0} == 157500 ]] || { printf 'Unexpected scrollback: %s\n' "${total:-not ready}" >&2; exit 1; }
printf '10 windows, 30 panes, %s retained scrollback lines\n' "$total"
benchmark_save() {
    local label=$1 id elapsed
    local TIMEFORMAT='%R'
    { time "$repo/bin/tmux-restore" --socket "$socket" save > /dev/null; } 2> "$fixture/time"
    read -r elapsed < "$fixture/time"
    id=$(< "$TMUX_RESTORE_STATE_DIR/last")
    printf '%s\t%s s\t%s (captured, reused)\n' "$label" "$elapsed" \
        "$(< "$TMUX_RESTORE_STATE_DIR/snapshots/$id/stats")"
}
benchmark_save 'First save'
t swap-window -s bench:9 -t bench:0
benchmark_save 'Reorder only'
pane=$(t list-panes -t bench:0 -F '#{pane_id}' | head -n1)
t send-keys -t "$pane" -l 'SINGLE-PANE-CHANGE'
t send-keys -t "$pane" Enter
for ((i=0; i<50; i++)); do
    output=$(t capture-pane -p -t "$pane")
    if [[ $output == *'SINGLE-PANE-CHANGE'* ]]; then break; fi
    sleep 0.05
done
[[ $output == *'SINGLE-PANE-CHANGE'* ]]
benchmark_save 'One pane changed'
