# Detect config files and review changes before writing them.

tr_setup_tmux_config() {
    local home_dir=$1 xdg_dir=$2 file found=
    # tmux loads these in reverse order. Prefer the last file it reads.
    for file in "$home_dir/.config/tmux/tmux.conf" \
        "${xdg_dir:+$xdg_dir/tmux/tmux.conf}" "$home_dir/.tmux.conf"; do
        if [[ -e $file || -L $file ]]; then
            [[ -n $found ]] || found=$file
            if [[ -f $file ]] && grep -Fqx -- '# >>> tmux-restore >>>' "$file"; then
                printf '%s\n' "$file"
                return
            fi
        fi
    done
    printf '%s\n' "${found:-$home_dir/.tmux.conf}"
}

tr_setup_config_target() {
    local file=$1 link count=0
    while [[ -L $file ]]; do
        if (( count >= 20 )); then tr_error "Too many symlinks resolving $1."; return 1; fi
        link=$(readlink "$file") || return 1
        case $link in
            /*) file=$link ;;
            *) file=${file%/*}/$link ;;
        esac
        count=$((count + 1))
    done
    printf '%s\n' "$file"
}

tr_setup_render_diff() {
    if [[ ! -t 1 || ${TERM:-dumb} == dumb || -n ${NO_COLOR:-} ]]; then
        cat "$1"
        return
    fi
    awk '
        BEGIN { esc = sprintf("%c", 27) }
        /^--- |^\+\+\+ |^@@ / { color = "1;36"; show(); next }
        /^\+/ { color = "32"; show(); next }
        /^-/ { color = "31"; show(); next }
        { color = "2"; show() }
        function show() { printf "%s[%sm%s%s[0m\n", esc, color, $0, esc }
    ' "$1"
}

tr_setup_offer() {
    local label=$1 config=$2 block=$3 tmux_path_line=${4:-} target original_label=/dev/null answer
    local before=$setup_temp/before after=$setup_temp/after changes=$setup_temp/diff
    target=$(tr_setup_config_target "$config") || return 1
    if [[ -e $target && ! -f $target ]]; then tr_error "Expected a regular file at $config."; return 1; fi
    if [[ -f $target ]]; then
        original_label=$config
        cat "$target" > "$before" || return 1
    else
        : > "$before"
    fi

    # Replace shell blocks. In tmux, update the generated path and keep user settings.
    if ! TR_SETUP_BLOCK=$block TR_SETUP_TMUX_PATH=$tmux_path_line awk '
        BEGIN {
            begin = "# >>> tmux-restore >>>"
            end = "# <<< tmux-restore <<<"
            block = ENVIRON["TR_SETUP_BLOCK"]
            tmux_path = ENVIRON["TR_SETUP_TMUX_PATH"]
        }
        $0 == begin {
            if (seen) { invalid = 1; exit 1 }
            seen = inside = 1
            print (tmux_path == "" ? block : $0)
            next
        }
        $0 == end {
            if (!inside) { invalid = 1; exit 1 }
            inside = 0
            if (tmux_path != "") print
            next
        }
        inside && tmux_path != "" && /^set -g @tmux-restore-install-dir / {
            print tmux_path
            next
        }
        !inside || tmux_path != "" { print }
        END {
            if (invalid || inside) exit 1
            if (!seen) {
                if (NR) print ""
                print block
            }
        }
    ' "$before" > "$after"; then
        tr_error "Could not update $config. Check for unmatched or duplicate tmux-restore markers."
        return 1
    fi

    if diff -u -L "$original_label" -L "$config" "$before" "$after" > "$changes"; then
        printf '%s is already configured.\n\n' "$config"
        return
    elif [[ $? != 1 ]]; then
        return 1
    fi
    printf 'Proposed changes for %s in %s\n' "$label" "$config"
    tr_setup_render_diff "$changes" || return 1
    while :; do
        printf 'Apply these changes? [y/N/q] '
        IFS= read -r answer || answer=
        [[ -t 0 ]] || printf '\n'
        case $answer in
            [Yy]|[Yy][Ee][Ss]) break ;;
            ''|[Nn]|[Nn][Oo]) printf 'Skipped %s.\n\n' "$config"; return ;;
            [Qq]|[Qq][Uu][Ii][Tt]) printf 'Setup stopped.\n'; exit 0 ;;
        esac
    done

    if [[ $(tr_setup_config_target "$config") != "$target" ]] ||
        { [[ $original_label == /dev/null ]] && [[ -e $target || -L $target ]]; } ||
        { [[ $original_label != /dev/null ]] && { [[ ! -f $target ]] || ! cmp -s "$before" "$target"; }; }; then
        tr_error "$config changed during review. Rerun setup to review the latest version."
        return 1
    fi
    mkdir -p -- "${target%/*}" || return 1
    setup_stage=$(mktemp "${target%/*}/.tmux-restore-config.XXXXXXXX") || return 1
    if [[ -f $target ]]; then
        cp -p -- "$target" "$setup_stage" || return 1
    fi
    cat "$after" > "$setup_stage" || return 1
    mv -f -- "$setup_stage" "$target" || return 1
    setup_stage=
    printf 'Updated %s.\n\n' "$config"
}

tr_setup_shell_block() {
    local source_word=$1 condition=$2
    cat <<CONF
# >>> tmux-restore >>>
# Managed by tmux-restore setup.
if ${condition}[ -r $source_word ]; then
    . $source_word
fi
# <<< tmux-restore <<<
CONF
}

tr_setup_offer_shells() {
    local home_dir=$1 zsh_dir=$2 default_shell=$3 destination=$4
    local shell order='zsh bash' zsh_rc=$zsh_dir/.zshrc bash_rc=$home_dir/.bashrc bash_login= file
    local block zsh_word bash_word
    if [[ $default_shell == bash ]]; then order='bash zsh'; fi
    zsh_word=$(tr_shell_word "$destination/shell/zsh.zsh")
    bash_word=$(tr_shell_word "$destination/shell/bash.sh")
    if [[ $destination == "$home_dir/.tmux/plugins/tmux-restore" ]]; then
        zsh_word='"$HOME/.tmux/plugins/tmux-restore/shell/zsh.zsh"'
        bash_word='"$HOME/.tmux/plugins/tmux-restore/shell/bash.sh"'
    fi

    for shell in $order; do
        case $shell in
            zsh)
                if [[ $default_shell == zsh || -e $zsh_rc || -L $zsh_rc ]]; then
                    block=$(tr_setup_shell_block "$zsh_word" '')
                    tr_setup_offer 'zsh command capture' "$zsh_rc" "$block" || return 1
                fi
                ;;
            bash)
                for file in "$home_dir/.bash_profile" "$home_dir/.bash_login" "$home_dir/.profile"; do
                    if [[ -r $file && -f $file ]]; then bash_login=$file; break; fi
                done
                block=$(tr_setup_shell_block "$bash_word" '[ -n "${BASH_VERSION:-}" ] && ')
                if [[ $default_shell == bash || -e $bash_rc || -L $bash_rc ]]; then
                    tr_setup_offer 'Bash command capture (non-login)' "$bash_rc" "$block" || return 1
                fi
                if [[ $default_shell == bash || -n $bash_login && $bash_login != "$home_dir/.profile" ]]; then
                    tr_setup_offer 'Bash command capture (login)' "${bash_login:-$home_dir/.bash_profile}" "$block" || return 1
                fi
                ;;
        esac
    done
}
