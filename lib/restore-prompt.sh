# Prompt rendering and one-shot replay. Source this file from Bash.

tmux_restore_prompt() {
    local ran=$1 saved=$2 command_line=$3 replay_directory=$4
    local header_color='' command_color='' reset='' key=''
    if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR+x} ]]; then
        # Regular amber header and bold teal command.
        header_color=$'\033[22;38;2;255;208;117m'
        command_color=$'\033[1;38;2;94;234;212m'
        reset=$'\033[0m'
    fi

    printf '\n%sTmux restored · ran %s · saved %s' "$header_color" "$ran" "$saved"
    if [[ $replay_directory != "$PWD" ]]; then
        printf ' · from '
        printf '%s' "$replay_directory" | LC_ALL=C tr -d '\000-\037\177'
    fi
    printf ' · [r]estore / any other key to dismiss%s\n%s' "$reset" "$command_color"
    printf '%s' "$command_line" | LC_ALL=C tr -d '\000-\010\013-\037\177'
    printf '%s\n' "$reset"

    IFS= read -r -s -n 1 key || return 1
    [[ $key == r || $key == R ]]
}

tmux_restore_replay() (
    local shell_name=$1 directory=$2 command_line=$3
    case $shell_name in bash|zsh) ;; *) return 1 ;; esac
    if ! cd -- "$directory"; then
        printf '%s\n' 'tmux-restore: the command directory is unavailable.' >&2
        return 1
    fi
    command "$shell_name" -ic "$command_line"
)
