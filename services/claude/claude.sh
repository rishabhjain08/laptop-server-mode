#!/bin/bash
# Claude Code with Remote Control, inside the isolated ClaudeBox distro.
# The watchdog pipes this in as root. Claude itself runs as the unprivileged
# "claude" user in auto permission mode, capped at 6 GB RAM / 4 CPU cores.
# Usage: claude.sh start|check|stop
set -u
SESSION=claude-server
CG=/sys/fs/cgroup/claude-server

as_claude() { runuser -l claude -c "$1" </dev/null; }

# Exit 3 = needs one-time setup by a person (sign-in, folder trust).
ready() {
  [ -s /home/claude/.claude/.credentials.json ] || { echo "Claude in ClaudeBox isn't signed in. Run: wsl -d ClaudeBox, then: cd ~/work && claude" >&2; return 1; }
  grep -q '"hasTrustDialogAccepted": *true' /home/claude/.claude.json 2>/dev/null || { echo "Folder ~/work isn't trusted yet. Run: wsl -d ClaudeBox, then: cd ~/work && claude" >&2; return 1; }
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
    as_claude "cd ~/work && tmux new-session -d -s $SESSION 'claude --remote-control --permission-mode auto'"
    ;;
  check)
    as_claude "tmux has-session -t $SESSION" 2>/dev/null
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
