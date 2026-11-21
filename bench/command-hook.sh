#!/bin/bash
# Measure a prototype command hook in interactive shells without user rc files.
set -eu
umask 077

root=$(mktemp -d "${TMPDIR:-/tmp}/tmux-restore-bench.XXXXXXXX")
trap 'rm -rf -- "$root"' EXIT
commands=${1:-1000}
rounds=${2:-5}
[[ $commands =~ ^[1-9][0-9]*$ && $rounds =~ ^[1-9][0-9]*$ ]]
export BENCH_ROOT=$root BENCH_COMMANDS=$commands BENCH_CWD=$PWD
export HISTFILE=/dev/null INPUTRC=/dev/null TERM=dumb
export BASH_SILENCE_DEPRECATION_WARNING=1

cat > "$root/hook.sh" <<'SH'
PS1=
PS2=
HISTCONTROL=
HISTIGNORE=
unset HISTFILE

bench_finish() {
    if [[ $BENCH_MODE != baseline ]]; then
        [[ $bench_count -eq $BENCH_COMMANDS ]] || exit 21
    fi
}

if [[ $BENCH_MODE == baseline ]]; then
    return
fi

bench_count=0
bench_record() {
    local timestamp=$1 command=$2 destination=$BENCH_ROOT/record
    if [[ $BENCH_MODE == atomic ]]; then
        destination=$destination.tmp
    fi
    printf '%s\0%s\0%s\0' "$PWD" "$timestamp" "$command" > "$destination" || exit 22
    if [[ $BENCH_MODE == atomic ]]; then
        /bin/mv -f "$destination" "$BENCH_ROOT/record" || exit 23
    fi
    bench_count=$((bench_count + 1))
}

bench_bash_record_in_place() {
    bench_count=$((bench_count + 1))
    {
        printf '%s\0%s\0' "$PWD" "$bench_count" || exit 26
        HISTTIMEFORMAT='%s ' builtin history 1 || exit 26
        printf '\0done\0' || exit 26
    } > "$BENCH_ROOT/slot.$((bench_count % 2))" || exit 26
}

bench_zsh_record_in_place() {
    bench_count=$((bench_count + 1))
    printf '%s\0%s\0%s\0%s\0done\0' "$PWD" "$bench_count" "$EPOCHSECONDS" "$1" \
        > "$BENCH_ROOT/slot.$((bench_count % 2))" || exit 26
}

if [[ -n ${BASH_VERSION:-} ]]; then
    bench_arm() { bench_ready=1; }
    bench_bash_preexec() {
        local entry pattern='^[[:blank:]]*[0-9]+[[:blank:]]+([0-9]+)[[:blank:]](.*)$'
        entry=$(HISTTIMEFORMAT='%s ' builtin history 1)
        [[ $entry =~ $pattern ]] || exit 24
        bench_record "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    }
    PROMPT_COMMAND=bench_arm
    if [[ $BENCH_MODE == slots ]]; then
        trap 'case $BASH_COMMAND in bench_arm|bench_finish|exit) ;; *) if [[ ${bench_ready:-0} == 1 ]]; then bench_ready=0; bench_bash_record_in_place; fi ;; esac' DEBUG
    else
        trap 'case $BASH_COMMAND in bench_arm|bench_finish|exit) ;; *) if [[ ${bench_ready:-0} == 1 ]]; then bench_ready=0; bench_bash_preexec; fi ;; esac' DEBUG
    fi
else
    zmodload zsh/datetime || exit 25
    preexec() {
        case $1 in bench_finish|exit) return ;; esac
        if [[ $BENCH_MODE == slots ]]; then
            bench_zsh_record_in_place "$1"
        else
            bench_record "$EPOCHSECONDS" "$1"
        fi
    }
fi
SH

cat > "$root/input" <<'SH'
. "$BENCH_ROOT/hook.sh"
SH
for ((i=1; i<commands; i++)); do
    printf ': fixture-%s && : same-line\n' "$i"
done >> "$root/input"
last_command='cd /private/tmp && : final-fixture'
printf '%s\n' "$last_command" bench_finish exit >> "$root/input"

run() {
    local shell=$1 mode=$2 round=$3 elapsed cwd epoch command seq entry footer
    local shell_args=()
    case $shell in
        bash) shell_args=(--noprofile --norc -i) ;;
        zsh) shell_args=(-f -i) ;;
    esac
    local TIMEFORMAT='%R'
    {
        time BENCH_MODE=$mode "/bin/$shell" "${shell_args[@]}" \
            < "$root/input" > /dev/null 2> "$root/shell.stderr"
    } 2> "$root/elapsed" || { tail -n 10 "$root/shell.stderr" >&2; exit 1; }
    read -r elapsed < "$root/elapsed"
    if [[ $mode == slots ]]; then
        {
            IFS= read -r -d '' cwd
            IFS= read -r -d '' seq
            if [[ $shell == bash ]]; then
                IFS= read -r -d '' entry
                local pattern='^[[:blank:]]*[0-9]+[[:blank:]]+([0-9]+)[[:blank:]](.*)$'
                [[ ${entry%$'\n'} =~ $pattern ]] || exit 27
                epoch=${BASH_REMATCH[1]}
                command=${BASH_REMATCH[2]}
            else
                IFS= read -r -d '' epoch
                IFS= read -r -d '' command
            fi
            IFS= read -r -d '' footer
        } < "$root/slot.$((commands % 2))"
        [[ $seq == "$commands" && $footer == done ]] || exit 28
    elif [[ $mode != baseline ]]; then
        {
            IFS= read -r -d '' cwd
            IFS= read -r -d '' epoch
            IFS= read -r -d '' command
        } < "$root/record"
    fi
    if [[ $mode != baseline ]]; then
        [[ $cwd == "$BENCH_CWD" && $epoch =~ ^[0-9]+$ && $command == "$last_command" ]] || {
            printf 'Last record incorrect for %s %s: %q | %q | %q\n' "$shell" "$mode" "$cwd" "$epoch" "$command" >&2
            exit 1
        }
    fi
    printf '%s\t%s\t%s\t%s\n' "$shell" "$mode" "$round" "$elapsed"
}

printf 'shell\tmode\tround\twall_seconds\n'
for ((round=1; round<=rounds; round++)); do
    for shell in bash zsh; do
        if [[ ${3:-} == slots-only ]]; then
            if ((round % 2)); then order=(baseline slots); else order=(slots baseline); fi
        else
            case $((round % 4)) in
                1) order=(baseline direct atomic slots) ;;
                2) order=(atomic slots baseline direct) ;;
                3) order=(direct atomic slots baseline) ;;
                0) order=(slots baseline direct atomic) ;;
            esac
        fi
        for mode in "${order[@]}"; do
            run "$shell" "$mode" "$round"
        done
    done
done
