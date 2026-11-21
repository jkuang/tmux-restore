# Shared Bash helpers. The public CLI sets TR_STATE, TR_SOCKET, and TR_REPO.

TR_FIELD=$'\037'
TR_ROW=$'\036'

tr_error() { printf 'tmux-restore: %s\n' "$*" >&2; }

tr_tmux() {
    # Without -u a C-locale client can turn record separators into underscores.
    if [[ -n ${TR_SOCKET:-} ]]; then
        command tmux -u -S "$TR_SOCKET" "$@"
    else
        command tmux -u "$@"
    fi
}

tr_uint() {
    [[ $1 =~ ^(0|[1-9][0-9]{0,11})$ ]]
}

tr_compatible() {
    local version=$1 pattern='^([0-9]+)\.([0-9]+)'
    [[ $version =~ $pattern ]] || return 1
    (( BASH_REMATCH[1] > 3 || BASH_REMATCH[1] == 3 && BASH_REMATCH[2] >= 8 ))
}

tr_option() {
    local value
    value=$(tr_tmux show-option -gqv "$1") || return
    printf '%s\n' "${value:-$2}"
}

tr_lock() {
    local lock=$1 kind=$2
    shift 2
    case $TR_PLATFORM:$kind in
        Darwin:try) lockf -k -t 0 "$lock" "$@" ;;
        Darwin:wait) lockf -k "$lock" "$@" ;;
        *:try) flock -x -n -E 75 "$lock" "$@" ;;
        *) flock -x "$lock" "$@" ;;
    esac
}

tr_latest() {
    local id
    [[ -r $TR_STATE/last ]] || return 1
    IFS= read -r id < "$TR_STATE/last" || return 1
    [[ $id =~ ^snap-[0-9]+-[0-9]+-[0-9]+$ && -r $TR_STATE/snapshots/$id/meta ]] || return 1
    printf '%s\n' "$TR_STATE/snapshots/$id"
}

tr_fields() {
    local row=${1#$'\n'} count=$2 index
    TR_FIELDS=()
    for (( index=0; index<count-1; index++ )); do
        [[ $row == *"$TR_FIELD"* ]] || return 1
        TR_FIELDS[index]=${row%%"$TR_FIELD"*}
        row=${row#*"$TR_FIELD"}
    done
    [[ $row != *"$TR_FIELD"* ]] || return 1
    TR_FIELDS[index]=$row
}

tr_session_id() { [[ $1 =~ ^\$[0-9]+$ ]]; }
tr_window_id() { [[ $1 =~ ^@[0-9]+$ ]]; }
tr_pane_id() { [[ $1 =~ ^%[0-9]+$ ]]; }

tr_reuse() { ln -- "$1" "$2" 2>/dev/null || cp -- "$1" "$2"; }

tr_record_dir() {
    printf '%s/commands/%s/pane-%s\n' "$TR_STATE" "$TR_SERVER" "${1#%}"
}

tr_timestamp() {
    local epoch=$1 format=${2:-'+%b %d %H:%M'}
    tr_uint "$epoch" || { printf '%s\n' 'unknown'; return; }
    if [[ $TR_PLATFORM == Darwin ]]; then
        LC_ALL=C date -r "$epoch" "$format" 2>/dev/null || printf '%s\n' 'unknown'
    else
        LC_ALL=C date -d "@$epoch" "$format" 2>/dev/null || printf '%s\n' 'unknown'
    fi
}
