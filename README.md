# tmux-restore

Bring back your tmux sessions, window order, pane layouts, working directories, and scrollback after a restart.

## Quick start

Requires tmux 3.8+ and Bash on macOS or Linux.

```sh
git clone https://github.com/jkuang/tmux-restore.git
cd tmux-restore
./setup.sh
```

Approve the tmux config diff. Accept a Bash or zsh hook if you want command replay. If tmux is already running, use `tmux source-file PATH` with the file setup updated. Open a new pane to start recording commands.

## Everyday use

**Autosave** runs after 10 seconds of quiet following a layout change. After about 5 minutes without a save, a periodic snapshot picks up changes like new scrollback from ordinary shell activity. Press **Alt-S** to save on demand.

**Restore** with `tmux attach` after a tmux server restart. Panes reopen in their saved directories with their scrollback.

**Optional command replay** is available with a Bash or zsh hook. If a recorded command was running at save time, the pane offers to rerun it. Press **r** or **R** to run the full command from its original starting directory. Press any other key to continue in the restored pane.

[Spec and implementation notes](docs/SPEC.md)
