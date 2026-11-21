#!/usr/bin/env bash
set -eu

repo=$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)
fixture=$(mktemp -d /tmp/tmux-restore-setup.XXXXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
zsh_path=$(command -v zsh)
zdotdir=$fixture/zsh
mkdir -- "$zdotdir"

rc=$fixture/zshrc
tmux_conf=$fixture/tmux.conf
printf '%s\n' 'set -g mouse on' > "$tmux_conf"
cp -- "$tmux_conf" "$fixture/tmux-before"
cat > "$rc" <<'RC'
# Right prompt and language tools
# >>> conda initialize >>>
export OTHER_TOOL=kept
# <<< conda initialize <<<
RC
ln -s ../zshrc "$zdotdir/.zshrc"
cp -- "$rc" "$fixture/before"

destination=$fixture/"plugin dir's copy"
install() {
    TMUX= TMUX_TMPDIR=$fixture SHELL=$zsh_path ZDOTDIR=$zdotdir \
        "$repo/setup.sh" --install-dir "$destination" --tmux-conf "$tmux_conf" "$@"
}

# Show both diffs in order, and apply only the accepted config.
printf 'n\ny\n' | install > "$fixture/output"
cmp "$tmux_conf" "$fixture/tmux-before"
awk '/^Proposed changes for / { print $4; if (++n == 2) exit }' "$fixture/output" > "$fixture/labels"
printf '%s\n' tmux zsh | cmp "$fixture/labels" -
[[ $(< "$fixture/output") == *$'\n+run-shell '* ]]
[[ -L $zdotdir/.zshrc ]]
head -n 4 "$rc" | cmp "$fixture/before" -
[[ $(awk '/^# >>> tmux-restore >>>$/{n++} END{print n+0}' "$rc") == 1 ]]
[[ $(awk '/^# <<< tmux-restore <<<$/{n++} END{print n+0}' "$rc") == 1 ]]
"$zsh_path" -n "$rc"
cp -- "$rc" "$fixture/once"
printf 'y\n' | install > "$fixture/output"
[[ $(< "$tmux_conf") == *$'\n# >>> tmux-restore >>>\n'* ]]
[[ $(< "$fixture/output") == *"$zdotdir/.zshrc is already configured."* ]]
cmp "$rc" "$fixture/once"

# A new installation path updates both blocks and preserves the chosen save key.
sed 's/bind-key -n M-s/bind-key -n M-S/' "$tmux_conf" > "$fixture/custom-tmux"
mv -- "$fixture/custom-tmux" "$tmux_conf"
destination=$fixture/another-install
printf 'yes\nyes\n' | install > "$fixture/output"
[[ $(< "$rc") == *"$destination/shell/zsh.zsh"* ]]
[[ $(awk '/^# >>> tmux-restore >>>$/{n++} END{print n+0}' "$rc") == 1 ]]
[[ $(< "$tmux_conf") == *"\"$destination\""* && $(< "$tmux_conf") == *'bind-key -n M-S'* ]]

# Quitting at the first preview skips the remaining files.
zdotdir=$fixture/quit
tmux_conf=$fixture/quit-config
printf 'q\n' | install > "$fixture/output"
[[ ! -e $tmux_conf && ! -e $zdotdir ]]
[[ $(< "$fixture/output") == *'Setup stopped.'* ]]

# An opt-out neither creates nor edits the file.
zdotdir=$fixture/opt-out
install --no-shell-hook < /dev/null > "$fixture/output"
[[ ! -e $zdotdir && ! -e $tmux_conf ]]

# Malformed markers produce an error with the startup file intact.
zdotdir=$fixture/malformed
mkdir -- "$zdotdir"
printf '%s\n' 'export OTHER_TOOL=kept' '# >>> tmux-restore >>>' > "$zdotdir/.zshrc"
cp -- "$zdotdir/.zshrc" "$fixture/malformed-before"
if printf 'n\n' | install > "$fixture/output" 2> "$fixture/error"; then exit 1; fi
[[ $(< "$fixture/error") == *'unmatched or duplicate tmux-restore markers'* ]]
cmp "$zdotdir/.zshrc" "$fixture/malformed-before"

# Check discovery and Bash prompts using an isolated set of dotfiles.
source "$repo/lib/common.sh"
source "$repo/lib/schedule.sh"
source "$repo/lib/setup-config.sh"
dotfiles=$fixture/dotfiles
setup_temp=$fixture/review
mkdir -p "$setup_temp" "$dotfiles/.config/tmux" "$fixture/xdg/tmux"
[[ $(tr_setup_tmux_config "$dotfiles" "") == "$dotfiles/.tmux.conf" ]]
touch "$fixture/xdg/tmux/tmux.conf"
[[ $(tr_setup_tmux_config "$dotfiles" "$fixture/xdg") == "$fixture/xdg/tmux/tmux.conf" ]]
touch "$dotfiles/.config/tmux/tmux.conf"
[[ $(tr_setup_tmux_config "$dotfiles" "$fixture/xdg") == "$dotfiles/.config/tmux/tmux.conf" ]]
printf '%s\n' '# >>> tmux-restore >>>' '# <<< tmux-restore <<<' > "$dotfiles/.tmux.conf"
[[ $(tr_setup_tmux_config "$dotfiles" "$fixture/xdg") == "$dotfiles/.tmux.conf" ]]

touch "$dotfiles/.profile" "$dotfiles/.zshrc"
printf 'y\ny\nn\n' | tr_setup_offer_shells "$dotfiles" "$dotfiles" bash "$destination" > "$fixture/output"
awk '/^Proposed changes for / { print $4 }' "$fixture/output" > "$fixture/labels"
printf '%s\n' Bash Bash zsh | cmp "$fixture/labels" -
[[ $(< "$dotfiles/.profile") == *"$destination/shell/bash.sh"* ]]
[[ $(< "$dotfiles/.bashrc") == *"$destination/shell/bash.sh"* ]]
[[ ! -s $dotfiles/.zshrc ]]
sh -n "$dotfiles/.profile"
printf 'y\nn\n' | tr_setup_offer_shells "$dotfiles" "$dotfiles" zsh "$destination" > "$fixture/output"
[[ $(< "$dotfiles/.zshrc") == *"$destination/shell/zsh.zsh"* ]]

printf '%s\n' 'Config discovery, per-file review, Bash and zsh hooks, symlinks, and repeat setup passed'
