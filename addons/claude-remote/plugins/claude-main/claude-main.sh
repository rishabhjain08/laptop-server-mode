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

# Remote Control tries once to reconnect a resumed conversation and gives up
# if that fails (seen right after boot). If the conversation's last Remote
# Control event is a disconnect, run /remote-control in it: at most once a
# minute, and only while Claude is idle at its prompt.
pane() { tmux capture-pane -p -t "=$NAME:"; }
key() { tmux send-keys -t "=$NAME:" "$@"; }
rc_heal() {
  local f stamp
  f=$(ls "$HOME"/.claude/projects/*/"$(cat "$IDFILE" 2>/dev/null)".jsonl 2>/dev/null | head -1)
  [ -n "$f" ] || return 0
  grep '"type":"system"' "$f" | grep -E '"subtype":"bridge_status"|"content":"Remote Control disconnected' |
    tail -1 | grep -q '"content":"Remote Control disconnected' || return 0
  # After a disconnect, /remote-control asks to confirm; option 1 is selected.
  if pane | grep -q 'Enable Remote Control'; then key Enter; echo "Remote Control: confirmed reconnect"; return 0; fi
  stamp="$(dirname "$IDFILE")/rc-heal"
  [ -n "$(find "$stamp" -mmin -1 2>/dev/null)" ] && return 0
  pane | grep -q 'esc to interrupt' && return 0
  touch "$stamp"
  key -l '/remote-control'; sleep 1; key Enter; sleep 2
  pane | grep -q 'Enable Remote Control' && key Enter
  echo "Remote Control was disconnected; ran /remote-control"
}

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
    has || exit 1
    rc_heal
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
