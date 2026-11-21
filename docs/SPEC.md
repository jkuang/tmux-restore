# tmux-restore spec

## What to expect

### Setup

Run `./setup.sh` on macOS or Linux, including WSL, with tmux 3.8+ and Bash 3.2+. Setup installs the plugin in `~/.tmux/plugins/tmux-restore` by default. It shows the config changes for each file and asks for approval. Approve the tmux config to enable workspace snapshots and a Bash or zsh hook to enable command replay.

If tmux is already running, reload the edited config and open a new pane for command recording. When switching from another saver, remove its config and take a confirmed save with tmux-restore while your workspace is open.

### Save your workspace

A snapshot includes session and window names, window order and links, pane splits and zoom, working directories, and the plain-text scrollback tmux still holds.

- **Alt-S** requests a save. Wait for `Tmux workspace saved.` before a planned restart.
- Autosave runs after ten seconds of quiet following a structural change, such as reordering windows or changing pane splits. It also runs about five minutes after the last save, and after the last client detaches.
- Switching between existing windows, typing shell commands, and generating terminal output are picked up by the next snapshot. The periodic timer keeps these changes backed up even when the layout stays the same.
- The latest ten snapshots are kept by default. Edit the timing, retention, or save key in the marked tmux config block.

### Restore and replay

Run `tmux attach` after the server restarts. A fresh server loads the latest snapshot and rebuilds the workspace with fresh shells. Each pane shows its saved scrollback and opens in its saved directory.

A command that was running at save time can be offered for replay. The prompt shows the full command and when it ran and was saved. **r** or **R** reruns the command from its original starting directory. Any other key dismisses the suggestion and opens the shell in the pane’s saved directory. For example, a saved `cd api && npm run dev` runs from the directory that originally contained `api`. When replay finishes, the pane opens a shell in its saved directory.

Panes saved at an idle shell prompt open directly. An unanswered restore prompt keeps its command through further saves. Application memory and unsaved work depend on each application’s own recovery features.

### Check or restore manually

Run `~/.tmux/plugins/tmux-restore/bin/tmux-restore status` to check the last save and any errors. The same tool accepts `save` for a synchronous snapshot and `load` for a manual restore. Manual restore reports a conflict if a saved session name is already in use.

Snapshots include scrollback and recorded commands. They live under `~/.local/state/tmux-restore` by default. Keep that directory private and use separate state directories if you run independent tmux servers.

## Implementation notes

### Installation and configuration

- [setup.sh](../setup.sh) checks the installed tmux binary and the platform lock utility, then copies `bin`, `lib`, `libexec`, `shell`, and the tmux entry point into the install directory. The CLI separately checks the version of the running server. Locking uses `lockf` on macOS and `flock` on Linux.
- [lib/setup-config.sh](../lib/setup-config.sh) looks for `~/.tmux.conf`, `$XDG_CONFIG_HOME/tmux/tmux.conf`, and `~/.config/tmux/tmux.conf`. It gives an existing managed block priority and otherwise prefers the last existing user config tmux reads. If none exists, setup offers to create `~/.tmux.conf`.
- Setup takes `--install-dir PATH` and `--tmux-conf PATH` with absolute paths. `--no-shell-hook` skips shell config changes. The shell comes from tmux’s `default-shell` when available, then `$SHELL`. zsh uses `${ZDOTDIR:-$HOME}/.zshrc`. Bash can use `~/.bashrc` and the first readable login file among `~/.bash_profile`, `~/.bash_login`, and `~/.profile`. A login file that sources `~/.bashrc` already picks up the hook there.
- Config edits are bounded by `# >>> tmux-restore >>>` and `# <<< tmux-restore <<<`. Setup previews a unified diff, preserves symlinks by updating their targets, and checks that the file still matches the preview before replacing it. `y` applies, Enter or `n` skips, and `q` ends review. On rerun, setup updates the tmux install path and preserves user settings in the block.
- The block sets `@tmux-restore-debounce` and `@tmux-restore-autosave` in seconds and `@tmux-restore-retain` as a snapshot count. Set autosave to `0` to disable periodic saves. Set `@tmux-restore-auto-load off` before the plugin loads to make restoration manual. A config reload replaces the hooks. Restart the server to apply interval changes to its already running worker.

### Entry points and scheduling

- [tmux-restore.tmux](../tmux-restore.tmux) invokes `_install` in [bin/tmux-restore](../bin/tmux-restore). The CLI selects the server from an explicit `--socket PATH` before the command, from `$TMUX`, or from tmux’s default socket. The server identity combines its start time and PID.
- [lib/schedule.sh](../lib/schedule.sh) attempts automatic load once on a server without sessions. Numbered hook slots mark structural changes dirty and suppress those notifications during restore. A detach hook saves when the last client leaves. A lock allows one timer worker per server, even without clients or a status bar.
- The worker polls tmux’s dirty flag and last-save timestamp. It waits for a quiet period before saving a burst of layout changes. A successful save resets the periodic deadline. The worker takes the snapshot lock without waiting and retries when another operation owns it.

### Snapshot and restore

- The state root is `TMUX_RESTORE_STATE_DIR` when set, otherwise `${XDG_STATE_HOME:-$HOME/.local/state}/tmux-restore`. Set it before starting the server. It holds `snapshots/`, the `last` pointer, per-pane command records, and the worker and snapshot locks.
- [lib/snapshot.sh](../lib/snapshot.sh) captures tmux metadata into a staging directory under `snapshots/`. It reuses pane text by hard link or copy when the server identity, pane output and history counters, and dimensions match. It checks window and pane topology again before publishing. It renames the complete snapshot into place, atomically replaces `last`, then prunes older snapshots. Each retained snapshot has its own usable pane files.
- Metadata uses ASCII unit and record separators. The tmux wrapper uses `-u` to preserve them even in a C locale.
- Snapshot metadata is on version 2 and records pane ownership. [lib/restore.sh](../lib/restore.sh) also reads version 1, filtering records from idle shells when their saved foreground process identifies a shell. A saved pending prompt is still eligible. Restore checks session names before creating any sessions, reconstructs linked windows and layouts with new tmux IDs, and expands the history limit when needed for saved text.
- The snapshot lock serializes save and load. An interrupted save leaves the last published pointer usable. If the worker detects an interrupted restore, it pauses autosave to protect the last completed snapshot. A successful manual save or load clears the pause. `status` reports the snapshot path, activity, pause, and last error.

### Command capture and replay

- [shell/zsh.zsh](../shell/zsh.zsh) takes the full command from `preexec` and clears its active marker in `precmd`. [shell/bash.sh](../shell/bash.sh) reads the full Bash history entry on the first DEBUG event after each prompt and clears the marker on return to the prompt. It leaves an existing DEBUG trap in place. Shell history exclusions are respected.
- [shell/command-record.sh](../shell/command-record.sh) accepts writes from the shell that owns the pane. It alternates between two NUL-delimited record slots and validates a completion marker so a partial write cannot become a command. The active marker binds a command sequence to the pane PID. The saver checks that marker against the recorded sequence and live pane identity. Shells still running an older hook fall back to tmux’s reported foreground process.
- [libexec/restore-pane](../libexec/restore-pane) enters the pane’s saved directory and prints its scrollback. A missing directory falls back to the home directory. The prompt appears on the alternate screen and publishes the original text and command under `pending/` so a save cannot turn the prompt into scrollback or lose the suggestion.
- [lib/restore-prompt.sh](../lib/restore-prompt.sh) renders the orange question and bold teal command. On approval, the pane wrapper keeps the command active until replay finishes. Replay passes the full command as one argument to the original shell, starting in the recorded command directory. The wrapper then opens the interactive shell in the saved pane directory. If the saved command or starting directory is unavailable, the pane opens directly and can show the last observed process as context.

### Local checks

Run these from the checkout. The tests use temporary configs, sockets, and state directories.

```sh
bash tests/setup-shell.sh
bash tests/command-hook.sh
bash tests/workspace.sh
```

[bench/command-hook.sh](../bench/command-hook.sh) measures shell capture overhead. [bench/workspace.sh](../bench/workspace.sh) compares initial, reorder-only, and single-pane saves in a 30-pane fixture. [The prompt preview](../examples/restore-prompt.html) shows the selected palette as option 6.
