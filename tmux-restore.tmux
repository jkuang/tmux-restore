#!/usr/bin/env bash
root=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P) || exit 1
exec "$root/bin/tmux-restore" _install
