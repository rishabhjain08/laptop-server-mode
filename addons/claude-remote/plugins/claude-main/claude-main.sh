#!/bin/bash
# Claude Code with Remote Control in your MAIN distro, as you, in tmux.
# After a restart it resumes the most recent conversation in DIR, so a
# /clear or a conversation you started there by hand carries on.
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
STATE=$HOME/.local/state/laptop-server-mode
# Claude keeps DIR's conversations in a folder named after the path.
PROJECT=$HOME/.claude/projects/$(printf %s "$DIR" | sed 's/[^a-zA-Z0-9]/-/g')

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
# Only the last lines: the menu and the status bar live there, while
# older conversation text further up may mention the same words.
bottom() { pane | grep -v '^[[:space:]]*$' | tail -4; }
rc_heal() {
  local f stamp s
  # The transcript of the Claude running in this tmux session (Claude records
  # it in ~/.claude/sessions/<pid>.json). Not just the newest file: an older
  # conversation's file gets touched too, and its stale 403 would kill a
  # healthy session.
  for s in "$HOME"/.claude/sessions/*.json; do
    grep -q "\"tmux\":\"$NAME:" "$s" 2>/dev/null || continue
    kill -0 "$(basename "$s" .json)" 2>/dev/null || continue
    f=$PROJECT/$(grep -o '"sessionId":"[^"]*"' "$s" | cut -d'"' -f4).jsonl
  done
  [ -f "$f" ] || f=$(ls -t "$PROJECT"/*.jsonl 2>/dev/null | head -1)
  [ -n "$f" ] || return 0
  local last
  last=$(grep -a '"type":"system"' "$f" | grep -E '"subtype":"bridge_status"|"content":"Remote Control disconnected' | tail -1)
  case "$last" in *'"content":"Remote Control disconnected'*) ;; *) return 0;; esac
  mkdir -p "$STATE"
  # A refused session (HTTP 403, e.g. after this device was removed from the
  # account, then "disabled after repeated failures") can't be fixed with
  # /remote-control: the server won't reattach the resumed conversation. Start
  # a fresh conversation instead (the old one stays on disk), at most hourly.
  case "$last" in *'HTTP 403'*|*'disabled after repeated failures'*)
    [ -n "$(find "$STATE/rc-fresh" -mmin -60 2>/dev/null)" ] && return 0
    bottom | grep -q 'esc to interrupt' && return 0
    touch "$STATE/rc-fresh" "$STATE/fresh-next"
    tmux kill-session -t "=$NAME"
    echo "Remote Control refused this conversation (HTTP 403); restarting with a fresh one"
    return 0;;
  esac
  # After a disconnect, /remote-control asks to confirm ("1. Enable Remote
  # Control", "2. Never mind"); option 1 is selected.
  if bottom | grep -q 'Never mind'; then key Enter; echo "Remote Control: confirmed reconnect"; return 0; fi
  stamp=$STATE/rc-heal
  [ -n "$(find "$stamp" -mmin -1 2>/dev/null)" ] && return 0
  bottom | grep -q 'esc to interrupt' && return 0
  mkdir -p "$STATE"; touch "$stamp"
  key -l '/remote-control'; sleep 1; key Enter; sleep 2
  bottom | grep -q 'Never mind' && key Enter
  echo "Remote Control was disconnected; ran /remote-control"
}

case "${1:-}" in
  start)
    has && exit 0
    command -v claude >/dev/null || { echo "Claude Code isn't installed in this distro" >&2; exit 3; }
    [ -s "$HOME/.claude/.credentials.json" ] || { echo "Claude isn't signed in. Run: claude" >&2; exit 3; }
    # Right after boot the network can lag behind; Claude then fails its one
    # Remote Control reconnect and its update check. Wait up to 40 s for it.
    for _ in $(seq 10); do curl -s -o /dev/null --max-time 2 https://api.anthropic.com && break; sleep 2; done
    CMD="claude -n '$NAME' --remote-control '$NAME' $FLAGS"
    # Resume the most recent conversation; start a fresh one if there is none
    # or it can't be resumed, rather than loop.
    if [ -f "$STATE/fresh-next" ]; then   # see rc_heal
      rm -f "$STATE/fresh-next"
      tmux new-session -d -s "$NAME" -c "$DIR" "$CMD"
    else
      tmux new-session -d -s "$NAME" -c "$DIR" "$CMD --continue || $CMD"
    fi
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
