#!/bin/bash
# Claude Code with Remote Control, inside the isolated ClaudeBox distro.
# The watchdog pipes this in as root. Claude itself runs as the unprivileged
# "claude" user with permission prompts skipped (the box is the sandbox), capped at 6 GB RAM / 4 CPU cores.
# Usage: claude.sh start|check|stop
set -u
SESSION=claude-server
CG=/sys/fs/cgroup/claude-server

# -l resets the environment; keep WSL_DISTRO_NAME so Claude can tell which distro it is in.
as_claude() { runuser -l -w WSL_DISTRO_NAME claude -c "$1" </dev/null; }

# Exit 3 = needs one-time setup by a person (sign-in, folder trust).
ready() {
  [ -s /home/claude/.claude/.credentials.json ] || { echo "Claude in ClaudeBox isn't signed in. Run: wsl -d ClaudeBox, then: cd ~/work && claude" >&2; return 1; }
  grep -q '"hasTrustDialogAccepted": *true' /home/claude/.claude.json 2>/dev/null || { echo "Folder ~/work isn't trusted yet. Run: wsl -d ClaudeBox, then: cd ~/work && claude" >&2; return 1; }
}

# Remote Control tries once to reconnect a resumed conversation and gives up
# if that fails (seen right after boot). If the latest conversation's last
# Remote Control event is a disconnect, run /remote-control in it: at most
# once a minute, and only while Claude is idle at its prompt.
pane() { as_claude "tmux capture-pane -p -t $SESSION"; }
key() { as_claude "tmux send-keys -t $SESSION $*"; }
# Only the last lines: the menu and the status bar live there, while
# older conversation text further up may mention the same words.
bottom() { pane | grep -v '^[[:space:]]*$' | tail -4; }
rc_heal() {
  local f
  f=$(ls -t /home/claude/.claude/projects/-home-claude-work/*.jsonl 2>/dev/null | head -1)
  [ -n "$f" ] || return 0
  local last
  last=$(grep -a '"type":"system"' "$f" | grep -E '"subtype":"bridge_status"|"content":"Remote Control disconnected' | tail -1)
  case "$last" in *'"content":"Remote Control disconnected'*) ;; *) return 0;; esac
  # A refused session (HTTP 403, e.g. after this device was removed from the
  # account, then "disabled after repeated failures") can't be fixed with
  # /remote-control: the server won't reattach the resumed conversation. Start
  # a fresh conversation instead (the old one stays on disk), at most hourly.
  case "$last" in *'HTTP 403'*|*'disabled after repeated failures'*)
    [ -n "$(find "/run/claude-rc-fresh" -mmin -60 2>/dev/null)" ] && return 0
    bottom | grep -q 'esc to interrupt' && return 0
    touch "/run/claude-rc-fresh" "/run/claude-fresh-next"
    as_claude "tmux kill-session -t $SESSION"
    echo "Remote Control refused this conversation (HTTP 403); restarting with a fresh one"
    return 0;;
  esac
  # After a disconnect, /remote-control asks to confirm ("1. Enable Remote
  # Control", "2. Never mind"); option 1 is selected.
  if bottom | grep -q 'Never mind'; then key Enter; echo "Remote Control: confirmed reconnect"; return 0; fi
  [ -n "$(find /run/claude-rc-heal -mmin -1 2>/dev/null)" ] && return 0
  bottom | grep -q 'esc to interrupt' && return 0
  touch /run/claude-rc-heal
  key -l /remote-control; sleep 1; key Enter; sleep 2
  bottom | grep -q 'Never mind' && key Enter
  echo "Remote Control was disconnected; ran /remote-control"
}

case "${1:-}" in
  start)
    /usr/local/sbin/claudebox-harden || { echo "box isn't hardened; refusing to start" >&2; exit 1; }
    as_claude "tmux has-session -t $SESSION" 2>/dev/null && exit 0
    ready || exit 3
    mkdir -p "$CG"
    echo 5G > "$CG/memory.high"           # reclaim pressure starts here
    echo 6G > "$CG/memory.max"            # hard cap
    echo "400000 100000" > "$CG/cpu.max"  # 4 cores
    echo 2000 > "$CG/pids.max"
    echo $$ > "$CG/cgroup.procs"          # tmux and Claude inherit the caps
    # A tmux server you started by hand (e.g. the WezTerm shortcut) would
    # spawn Claude outside the caps, so move it in first.
    pid=$(as_claude "tmux display-message -p '#{pid}'" 2>/dev/null) && echo "$pid" > "$CG/cgroup.procs"
    # Right after boot the network can lag behind; Claude then fails its one
    # Remote Control reconnect and its update check. Wait up to 40 s for it.
    for _ in $(seq 10); do curl -s -o /dev/null --max-time 2 https://api.anthropic.com && break; sleep 2; done
    # Resume the last conversation; start fresh if there is none or it can't load.
    CMD='claude --remote-control --dangerously-skip-permissions'
    if [ -f /run/claude-fresh-next ]; then   # see rc_heal
      rm -f /run/claude-fresh-next
      as_claude "cd ~/work && tmux new-session -d -s $SESSION '$CMD'"
    else
      as_claude "cd ~/work && tmux new-session -d -s $SESSION '$CMD --continue || $CMD'"
    fi
    ;;
  check)
    as_claude "tmux has-session -t $SESSION" 2>/dev/null || exit 1
    rc_heal
    ;;
  stop)
    as_claude "tmux kill-server" 2>/dev/null
    true
    ;;
  *)
    echo "usage: $0 start|check|stop" >&2
    exit 2
    ;;
esac
