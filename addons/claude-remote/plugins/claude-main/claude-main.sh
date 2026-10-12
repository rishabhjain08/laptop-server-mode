#!/bin/bash
# Claude Code with Remote Control in your MAIN distro, as you, in tmux.
# After a restart it resumes the most recent conversation in DIR, so a
# /clear or a conversation you started there by hand carries on.
# Unlike ClaudeBox it has your full access (keys, gh login, Windows), so it
# is off by default; turn it on in the tray flyout.
#
# Settings (plugin.json defaults, your settings.json overrides; empty means
# the default in brackets):
#   mode            session: one conversation in tmux that resumes after restarts
#                   server:  `claude remote-control`, new sessions on demand from the app
#   permissionMode  [default] asks on your phone; or acceptEdits, auto, plan, dontAsk,
#                   bypassPermissions (full access to your account: think twice)
#   name            [claude-main] tmux session and name in the Claude app
#   folder          [~] working directory; must be trusted (run `claude` there once)
# Older installs may set NAME, DIR and FLAGS in
# ~/.config/laptop-server-mode/claude-main.env instead; settings win.
# Usage: claude-main.sh start|check|stop
set -u
NAME=claude-main
DIR=$HOME
FLAGS=
CONF=$HOME/.config/laptop-server-mode/claude-main.env
[ -f "$CONF" ] && . "$CONF"
[ -n "${LSM_SETTING_NAME:-}" ] && NAME=$LSM_SETTING_NAME
[ -n "${LSM_SETTING_FOLDER:-}" ] && DIR=${LSM_SETTING_FOLDER/#\~/$HOME}
MODE=${LSM_SETTING_MODE:-session}
PERM=${LSM_SETTING_PERMISSION_MODE:-}
if [ -z "$PERM" ]; then   # from FLAGS (older installs), else default
  case "$FLAGS" in *--dangerously-skip-permissions*) PERM=bypassPermissions ;; *) PERM=default ;; esac
fi
STATE=$HOME/.local/state/laptop-server-mode
SIG="$MODE|$PERM|$NAME|$DIR"   # what the running Claude was started with
ME=${LSM_PLUGIN:-claude-main}   # state files are per plugin, so copies of it never collide
SIGF=$STATE/$ME.settings
# Claude keeps DIR's conversations in a folder named after the path.
PROJECT=$HOME/.claude/projects/$(printf %s "$DIR" | sed 's/[^a-zA-Z0-9]/-/g')

export PATH="$HOME/.local/bin:$PATH"
# Started by the boot task, whose WSL session ends; the init socket stays
# valid, so Windows programs keep working inside the session.
export WSL_INTEROP=/run/WSL/1_interop

has() { tmux has-session -t "=$NAME" 2>/dev/null; }

settings_ok() {
  case "$MODE" in session|server) ;; *) echo "Setting mode must be session or server, not '$MODE'" >&2; return 1;; esac
  case "$PERM" in default|acceptEdits|auto|bypassPermissions|dontAsk|plan) ;;
    *) echo "Setting permissionMode '$PERM' isn't one of: default, acceptEdits, auto, bypassPermissions, dontAsk, plan" >&2; return 1;; esac
  case "$NAME" in *[!A-Za-z0-9._-]*|'') echo "Setting name may only use letters, digits, '.', '_' and '-'" >&2; return 1;; esac
  [ -d "$DIR" ] || { echo "Folder $DIR doesn't exist" >&2; return 1; }
  [ "$DIR" != "$HOME" ] || { echo "Claude can't remember trust for your home folder. Set \"folder\" in this plugin's settings.json to a subfolder, e.g. ~/projects" >&2; return 1; }
}

# Remote Control tries once to reconnect a resumed conversation and gives up
# if that fails (seen right after boot). If the conversation's last Remote
# Control event is a disconnect, run /remote-control in it: at most once a
# minute, and only while Claude is idle at its prompt.
pane() { tmux capture-pane -p -t "=$NAME:"; }
key() { tmux send-keys -t "=$NAME:" "$@"; }
# Only the last lines: the menu and the status bar live there, while
# older conversation text further up may mention the same words.
bottom() { pane | grep -v '^[[:space:]]*$' | tail -4; }
# Is DIR (or a folder above it) trusted in Claude? Unknown (no python3): yes.
trusted() {
  command -v python3 >/dev/null || return 0
  [ "$(python3 -c '
import json, os, sys
d = json.load(open(os.path.expanduser("~/.claude.json"))).get("projects", {})
p = os.path.abspath(sys.argv[1])
while not d.get(p, {}).get("hasTrustDialogAccepted"):
    if p == os.path.dirname(p): print("no"); break
    p = os.path.dirname(p)
' "$DIR" 2>/dev/null)" != no ]
}

# Server mode: starts `claude remote-control` in tmux and watches its first
# seconds: an untrusted folder makes it exit, and the first run waits for
# "Enable Remote Control? (y/n)". The trailing sleep keeps the pane readable
# after Claude exits. Returns 0 running, 3 needs a person, 1 failed.
server_start() {
  local out
  FAIL=
  tmux new-session -d -s "$NAME" -c "$DIR" "$1; sleep 30"
  for _ in $(seq 20); do
    sleep 1
    out=$(pane 2>/dev/null)
    case "$out" in
      *"not trusted"*) tmux kill-session -t "=$NAME"
        echo "Folder $DIR isn't trusted yet. Run: cd $DIR && claude (accept the trust prompt, then /exit)" >&2; return 3 ;;
      *"Enable Remote Control?"*) tmux kill-session -t "=$NAME"
        echo "Remote Control isn't switched on yet. Run: cd $DIR && claude remote-control (answer y, wait for Ready, then Ctrl+C)" >&2; return 3 ;;
      *Ready*) return 0 ;;
    esac
    if exited; then
      tmux kill-session -t "=$NAME"
      FAIL="Claude exited: $(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -2 | tr '\n' ' ')"
      return 1
    fi
  done
}
# Claude is gone and only the trailing sleep is left in its pane.
exited() { [ "$(tmux display-message -p -t "=$NAME:" '#{pane_current_command}' 2>/dev/null)" = sleep ]; }

# The conversation in DIR whose last user or assistant message is newest.
latest() {
  local f t best= bt=
  for f in "$PROJECT"/*.jsonl; do
    [ -f "$f" ] || continue
    t=$(tac "$f" | grep -a -m1 -E '"type":"(user|assistant)"' | grep -o '"timestamp":"[^"]*"')
    [[ "$t" > "$bt" ]] && { bt=$t; best=$(basename "$f" .jsonl); }
  done
  echo "$best"
}
rc_heal() {
  local f stamp s
  # The transcript of the Claude running in this tmux session (Claude records
  # it in ~/.claude/sessions/<pid>.json). Not just the newest file: an older
  # conversation's file gets touched too, and its stale 403 would kill a
  # healthy session.
  for s in "$HOME"/.claude/sessions/*.json; do
    grep -q "\"tmux\":\"$NAME:" "$s" 2>/dev/null || continue
    # Still that process? PIDs get reused; procStart is its start time.
    [ "$(cut -d' ' -f22 "/proc/$(basename "$s" .json)/stat" 2>/dev/null)" = \
      "$(grep -o '"procStart":"[^"]*"' "$s" | cut -d'"' -f4)" ] || continue
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
    [ -n "$(find "$STATE/$ME.rc-fresh" -mmin -60 2>/dev/null)" ] && return 0
    bottom | grep -q 'esc to interrupt' && return 0
    touch "$STATE/$ME.rc-fresh" "$STATE/$ME.fresh-next"
    tmux kill-session -t "=$NAME"
    echo "Remote Control refused this conversation (HTTP 403); restarting with a fresh one"
    return 0;;
  esac
  # After a disconnect, /remote-control asks to confirm ("1. Enable Remote
  # Control", "2. Never mind"); option 1 is selected.
  if bottom | grep -q 'Never mind'; then key Enter; echo "Remote Control: confirmed reconnect"; return 0; fi
  stamp=$STATE/$ME.rc-heal
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
    settings_ok || exit 3
    trusted || { echo "Folder $DIR isn't trusted yet. Run: cd $DIR && claude (accept the trust prompt, then /exit)" >&2; exit 3; }
    # Right after boot the network can lag behind; Claude then fails its one
    # Remote Control reconnect and its update check. Wait up to 40 s for it.
    for _ in $(seq 10); do curl -s -o /dev/null --max-time 2 https://api.anthropic.com && break; sleep 2; done
    mkdir -p "$STATE"; echo "$SIG" > "$SIGF"
    if [ "$MODE" = server ]; then
      CMD="claude remote-control --name $NAME --permission-mode $PERM"
      # Reattach to the same server in the app if this folder had one (Claude
      # allows about 4 hours; if that fails right away, register a new one).
      if [ -f "$PROJECT/bridge-pointer.json" ]; then
        server_start "$CMD --continue"; r=$?
        [ $r = 1 ] || exit $r
      fi
      server_start "$CMD"; r=$?
      # Claude's record of the last server here blocks a new one. If that
      # server is gone, the record is stale: drop it and start fresh.
      if [ $r = 1 ] && [ -f "$PROJECT/bridge-pointer.json" ] && case "$FAIL" in *"already served"*) true;; *) false;; esac; then
        old=$(grep -o '"pid":[0-9]*' "$PROJECT/bridge-pointer.json" | cut -d: -f2)
        if [ -n "$old" ] && [ -d "/proc/$old" ]; then
          echo "Another claude remote-control (PID $old) already serves $DIR. Stop it, or set a different folder." >&2; exit 3
        fi
        rm -f "$PROJECT/bridge-pointer.json"
        server_start "$CMD"; r=$?
      fi
      [ $r = 1 ] && echo "$FAIL" >&2
      exit $r
    fi
    if [ "$PERM" = bypassPermissions ]; then P=--dangerously-skip-permissions; else P="--permission-mode $PERM"; fi
    CMD="claude -n '$NAME' --remote-control '$NAME' $P"
    # Resume the conversation with the latest message; start a fresh one if
    # there is none or it can't be resumed, rather than loop. Not --continue:
    # it picks the newest file, and Claude also appends notices to old ones.
    id=$(latest)
    if [ -f "$STATE/$ME.fresh-next" ] || [ -z "$id" ]; then   # see rc_heal
      rm -f "$STATE/$ME.fresh-next"
      tmux new-session -d -s "$NAME" -c "$DIR" "$CMD"
    else
      tmux new-session -d -s "$NAME" -c "$DIR" "$CMD --resume $id || $CMD"
    fi
    ;;
  check)
    has || exit 1
    # Settings changed since start: restart with the new ones. (No record yet,
    # e.g. started by an older version: adopt the running one as is.)
    mkdir -p "$STATE"; [ -f "$SIGF" ] || echo "$SIG" > "$SIGF"
    if [ "$(cat "$SIGF")" != "$SIG" ]; then
      tmux kill-session -t "=$NAME"
      echo "Settings changed; restarting Claude" >&2
      exit 1
    fi
    if [ "$MODE" = server ] && exited; then
      tmux kill-session -t "=$NAME"; echo "Claude exited; restarting" >&2; exit 1
    fi
    [ "$MODE" = session ] && rc_heal
    true
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
