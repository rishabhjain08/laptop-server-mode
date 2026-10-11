#!/usr/bin/env bash
# Claude Code with Remote Control, in a detached tmux session.
# Usage: claude.sh start|check|stop
# Optional overrides (set in ~/.profile):
#   LSM_CLAUDE_SESSION  tmux session name   (default: claude-server)
#   LSM_CLAUDE_DIR      working directory   (default: ~/projects)
set -u
SESSION="${LSM_CLAUDE_SESSION:-claude-server}"
DIR="${LSM_CLAUDE_DIR:-$HOME/projects}"

case "${1:-}" in
  start)
    tmux has-session -t "$SESSION" 2>/dev/null && exit 0
    command -v claude >/dev/null || { echo "claude not found in PATH" >&2; exit 1; }
    mkdir -p "$DIR"
    tmux new-session -d -s "$SESSION" -c "$DIR" "claude --remote-control"
    ;;
  check)
    tmux has-session -t "$SESSION" 2>/dev/null
    ;;
  stop)
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    ;;
  *)
    echo "usage: $0 start|check|stop" >&2
    exit 2
    ;;
esac
