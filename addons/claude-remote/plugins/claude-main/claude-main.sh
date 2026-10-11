#!/bin/bash
# Claude Code with Remote Control in your MAIN distro, as you, in tmux.
# Resumes the same named conversation after every restart.
# Unlike ClaudeBox it has your full access (keys, gh login, Windows), so it
# is off by default; turn it on in the tray flyout.
#
# Optional settings in ~/.config/laptop-server-mode/claude-main.env:
#   NAME=my-laptop                 session name (tmux, Remote Control, /resume)
#   DIR=$HOME                      working directory
#   FLAGS="--dangerously-skip-permissions"
# Usage: claude-main.sh start|check|stop
set -u
NAME=claude-main
DIR=$HOME
FLAGS=
CONF=$HOME/.config/laptop-server-mode/claude-main.env
[ -f "$CONF" ] && . "$CONF"
IDFILE=$HOME/.local/state/laptop-server-mode/claude-main.id

export PATH="$HOME/.local/bin:$PATH"
# Started by the boot task, whose WSL session ends; the init socket stays
# valid, so Windows programs keep working inside the session.
export WSL_INTEROP=/run/WSL/1_interop

has() { tmux has-session -t "=$NAME" 2>/dev/null; }

case "${1:-}" in
  start)
    has && exit 0
    command -v claude >/dev/null || { echo "Claude Code isn't installed in this distro" >&2; exit 3; }
    [ -s "$HOME/.claude/.credentials.json" ] || { echo "Claude isn't signed in. Run: claude" >&2; exit 3; }
    mkdir -p "$(dirname "$IDFILE")"
    [ -s "$IDFILE" ] || cat /proc/sys/kernel/random/uuid > "$IDFILE"
    ID=$(cat "$IDFILE")
    # Resume the conversation if it exists, otherwise start it with this ID.
    if ls "$HOME"/.claude/projects/*/"$ID.jsonl" >/dev/null 2>&1; then
      SESSION="--resume $ID"
    else
      SESSION="--session-id $ID"
    fi
    CMD="claude -n '$NAME' --remote-control '$NAME' $FLAGS"
    # If the conversation can't be resumed, start a fresh one rather than loop.
    tmux new-session -d -s "$NAME" -c "$DIR" "$CMD $SESSION || $CMD"
    ;;
  check)
    has
    ;;
  stop)
    tmux kill-session -t "=$NAME" 2>/dev/null   # only this session, not your tmux
    true
    ;;
  *)
    echo "usage: $0 start|check|stop" >&2
    exit 2
    ;;
esac
