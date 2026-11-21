# tmux-restore

Save tmux sessions, window order, layouts, working directories, and scrollback. After restarting tmux, return to fresh shells in the saved workspace. Optional Bash and zsh hooks let you approve rerunning the last command pane by pane.

## Install

Use tmux **3.8 or newer** on macOS or Linux, including WSL. The plugin uses Bash 3.2+ and standard system utilities. Locking uses `lockf` on macOS or `flock` from util-linux on Linux.

Run `./setup.sh` from your checkout. Setup copies the plugin to `~/.tmux/plugins/tmux-restore`, then shows a unified diff for each proposed configuration change. Press `y` to apply, Enter or `n` to skip the file, or `q` to end the review. Diffs are colored in a terminal.

Setup checks `~/.tmux.conf`, `$XDG_CONFIG_HOME/tmux/tmux.conf`, and `~/.config/tmux/tmux.conf`. It prefers one already containing the managed block, then the last existing user config tmux reads. It proposes creating `~/.tmux.conf` if none exist. Use `--tmux-conf /absolute/path` if you start tmux with a custom config. The `# >>> tmux-restore >>>` block includes editable save timing and shortcut settings. Rerunning setup preserves those settings.

If you use another snapshot tool, remove its config block before adding this one. On the first migration, reload the updated config and take a confirmed save while your current workspace is still open. The new plugin uses its own snapshots. A fresh tmux server starts with only the plugins in the updated config.

### Commands

- **Alt-s** saves in the background. Wait for `Tmux workspace saved.` before a planned reboot.
- **`tmux attach`** starts or attaches to tmux. On a fresh server, the plugin looks for its last snapshot automatically. An explicit `tmux new-session` still creates the session you requested.
- **`~/.tmux/plugins/tmux-restore/bin/tmux-restore status`** shows the last save, current activity, and errors.
- Use the same executable with **`save`** for a synchronous save or **`load`** for manual restore. `load` checks all saved session names before creating anything and refuses conflicts. Add `--socket PATH` before the command to select a specific server.

The default schedule saves after ten seconds of quiet following a layout change, about every five minutes without a save, and after the last client detaches. The periodic timer runs without a status bar or attached client. A config reload replaces the hook entries. Restart the server after changing the intervals to update its existing timer. Set `@tmux-restore-auto-load` to `off` before loading the plugin if you prefer manual restoration.

### Command replay

After the tmux config, setup offers hooks for zsh and Bash. It uses tmux's `default-shell` when available and falls back to `$SHELL`. It offers the detected shell first, plus an existing config for the other shell. Pass `--no-shell-hook` to skip shell setup entirely.

For zsh, setup uses `${ZDOTDIR:-$HOME}/.zshrc`. For Bash, it offers `~/.bashrc` for non-login panes and the active Bash profile for login panes. If your Bash profile already sources `~/.bashrc`, approving the `~/.bashrc` change covers both. Open a new pane to enable recording. Bash leaves an existing DEBUG trap in place and skips recording in that shell.

The hook records the full command and its starting directory. A snapshot taken while that command is running offers it for replay. A pane sitting at a shell prompt restores directly to a shell with its saved working directory and scrollback. **`r` or `R`** reruns the full recorded command from its original starting directory. Another key dismisses the suggestion and opens the shell in the saved directory. An unanswered restore prompt retains its original text and command when saved again. Tmux's last observed process name can provide context when the full command is unavailable.

The shell reruns commands from the beginning. Application memory, active jobs, and unsaved buffers need their application's own recovery mechanism.

## Local state

The latest ten snapshots are stored in `${XDG_STATE_HOME:-$HOME/.local/state}/tmux-restore` by default. Set `TMUX_RESTORE_STATE_DIR` before starting tmux to use another location. This state includes terminal text and recorded command lines. Keep it private. Use a separate state directory for each independent tmux server if you run several.

Unchanged pane captures are reused between snapshots. Each retained snapshot has the files it needs even after older snapshots are pruned. The status command reports errors from failed saves. If an interrupted restore leaves partial sessions, autosave pauses to protect the last completed backup. A successful manual save or load clears the pause.

## Local checks

```sh
bash tests/setup-shell.sh
bash tests/command-hook.sh
bash tests/workspace.sh
bash bench/workspace.sh
open examples/restore-prompt.html
```

The checks use temporary servers and sample text. The palette preview labels the selected regular amber header and bold teal command as option 6.
