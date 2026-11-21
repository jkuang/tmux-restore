# tmux-restore

Bring back your tmux windows, pane layouts, working directories, and scrollback after a restart.

## Quick start

Requires tmux 3.8+ and Bash on macOS or Linux.

```sh
git clone https://github.com/jkuang/tmux-restore.git
cd tmux-restore
./setup.sh
```

Approve the tmux config diff. Accept a Bash or zsh hook if you want command replay. If tmux is already running, use `tmux source-file PATH` with the file setup updated. Open a new pane to start recording commands.

## Everyday use

- **Save** with **Alt-S**. Autosave also runs in the background.
- **Restore** with `tmux attach` after a tmux server restart.
- **Replay** a suggested command with **r**. Press any other key to dismiss it.

[Spec and implementation notes](docs/SPEC.md)
