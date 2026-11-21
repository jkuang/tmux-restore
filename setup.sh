#!/usr/bin/env bash
set -eu

source_dir=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)
destination=$HOME/.tmux/plugins/tmux-restore
tmux_conf=
shell_hook=on
usage() { printf '%s\n' 'Usage: ./setup.sh [--install-dir PATH] [--tmux-conf PATH] [--no-shell-hook]'; }
while (( $# )); do
    case $1 in
        --install-dir)
            if (( $# < 2 )); then usage >&2; exit 2; fi
            destination=$2
            shift 2
            ;;
        --tmux-conf)
            if (( $# < 2 )) || [[ $2 != /* ]]; then usage >&2; exit 2; fi
            tmux_conf=$2
            shift 2
            ;;
        --no-shell-hook) shell_hook=off; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
if [[ $destination != /* || $destination == / || $destination == "$source_dir" ]]; then
    printf '%s\n' 'Choose an absolute install directory separate from the checkout.' >&2
    exit 2
fi

source "$source_dir/lib/common.sh"
source "$source_dir/lib/schedule.sh"
source "$source_dir/lib/setup-config.sh"
if ! command -v tmux >/dev/null || ! tr_compatible "$(tmux -V | awk '{print $2}')"; then
    tr_error 'Install tmux 3.8 or newer, then rerun setup.'
    exit 1
fi
case $(uname -s) in Darwin) helper=lockf ;; *) helper=flock ;; esac
if ! command -v "$helper" >/dev/null; then tr_error "$helper is required."; exit 1; fi

mkdir -p -- "$destination"
for directory in bin lib libexec shell; do
    mkdir -p -- "$destination/$directory"
    for file in "$source_dir/$directory/"*; do
        cp -p -- "$file" "$destination/$directory/"
    done
done
cp -p -- "$source_dir/tmux-restore.tmux" "$destination/"
printf 'Installed tmux-restore in %s\n\n' "$destination"

tmux_quote() {
    local line=$1
    line=${line//\\/\\\\}
    line=${line//\"/\\\"}
    line=${line//\$/\\\$}
    printf '"%s"' "$line"
}

setup_temp=$(mktemp -d "${TMPDIR:-/tmp}/tmux-restore-setup.XXXXXXXX")
setup_stage=
cleanup() {
    rm -rf -- "$setup_temp"
    if [[ -n $setup_stage ]]; then rm -f -- "$setup_stage"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 1' HUP TERM

if [[ -z $tmux_conf ]]; then
    tmux_conf=$(tr_setup_tmux_config "$HOME" "${XDG_CONFIG_HOME:-}")
fi
install_line="set -g @tmux-restore-install-dir $(tmux_quote "$destination")"
tmux_block=$(cat <<CONF
# >>> tmux-restore >>>
# Edit these values to change the save timing (seconds). 0 disables the timer.
set -g @tmux-restore-debounce 10
set -g @tmux-restore-autosave 300
set -g @tmux-restore-retain 10

$install_line
run-shell "#{q:@tmux-restore-install-dir}/tmux-restore.tmux"

# Change M-s to choose another save shortcut. M-s means Alt-s.
bind-key -n M-s run-shell -b "#{q:@tmux-restore-install-dir}/bin/tmux-restore save >/dev/null"
# <<< tmux-restore <<<
CONF
)
tr_setup_offer 'tmux' "$tmux_conf" "$tmux_block" "$install_line"

if [[ $shell_hook == on ]]; then
    pane_shell=$(tmux -N show-options -gqv default-shell 2>/dev/null) || pane_shell=
    pane_shell=${pane_shell:-${SHELL:-}}
    zsh_dir=${ZDOTDIR:-$HOME}
    if [[ $zsh_dir != /* ]]; then zsh_dir=$PWD/$zsh_dir; fi
    tr_setup_offer_shells "$HOME" "$zsh_dir" "${pane_shell##*/}" "$destination"
fi
