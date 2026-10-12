#!/bin/bash
# Claude Code with Remote Control, inside the isolated ClaudeBox distro.
# The watchdog pipes this in as root. Claude itself runs as the unprivileged
# "claude" user with permission prompts skipped (the box is the sandbox), capped at 6 GB RAM / 4 CPU cores.
# Settings (plugin.json defaults, your settings.json overrides):
#   mode            session: one conversation in tmux that resumes after restarts
#                   server:  `claude remote-control`, new sessions on demand from the app
#   permissionMode  bypassPermissions (default here), default, acceptEdits, auto, dontAsk, plan
#   name            name shown in the Claude app (empty: Claude's default)
# Usage: claude.sh start|check|stop
set -u
SESSION=claude-server
CG=/sys/fs/cgroup/claude-server
MODE=${LSM_SETTING_MODE:-session}
PERM=${LSM_SETTING_PERMISSION_MODE:-bypassPermissions}
RCNAME=${LSM_SETTING_NAME:-}
SIG="$MODE|$PERM|$RCNAME"   # what the running Claude was started with
SIGF=/run/claude-settings

# -l resets the environment; keep WSL_DISTRO_NAME so Claude can tell which distro it is in.
as_claude() { runuser -l -w WSL_DISTRO_NAME claude -c "$1" </dev/null; }

# Exit 3 = needs one-time setup by a person (sign-in, folder trust).
ready() {
  [ -s /home/claude/.claude/.credentials.json ] || { echo "Claude in ClaudeBox isn't signed in. Run: wsl -d ClaudeBox, then: cd ~/work && claude" >&2; return 1; }
  grep -q '"hasTrustDialogAccepted": *true' /home/claude/.claude.json 2>/dev/null || { echo "Folder ~/work isn't trusted yet. Run: wsl -d ClaudeBox, then: cd ~/work && claude" >&2; return 1; }
}

settings_ok() {
  case "$MODE" in session|server) ;; *) echo "Setting mode must be session or server, not '$MODE'" >&2; return 1;; esac
  case "$PERM" in default|acceptEdits|auto|bypassPermissions|dontAsk|plan) ;;
    *) echo "Setting permissionMode '$PERM' isn't one of: default, acceptEdits, auto, bypassPermissions, dontAsk, plan" >&2; return 1;; esac
  case "$RCNAME" in *"'"*|*'"'*) echo "Setting name can't contain quotes" >&2; return 1;; esac
}

# Server mode: starts `claude remote-control` in tmux and watches its first
# seconds: an untrusted folder makes it exit, and the first run waits for
# "Enable Remote Control? (y/n)". The trailing sleep keeps the pane readable
# after Claude exits. Returns 0 running, 3 needs a person, 1 failed.
server_start() {
  local out
  FAIL=
  as_claude "cd ~/work && tmux new-session -d -s $SESSION \"$1; sleep 30\""
  for _ in $(seq 20); do
    sleep 1
    out=$(pane 2>/dev/null)
    case "$out" in
      *"not trusted"*) as_claude "tmux kill-session -t $SESSION"
        echo "Folder ~/work isn't trusted yet. Run: wsl -d ClaudeBox, then: cd ~/work && claude" >&2; return 3 ;;
      *"Enable Remote Control?"*) as_claude "tmux kill-session -t $SESSION"
        echo "Remote Control isn't switched on in ClaudeBox yet. Run: wsl -d ClaudeBox, then: cd ~/work && claude remote-control (answer y, wait for Ready, then Ctrl+C)" >&2; return 3 ;;
      *Ready*) return 0 ;;
    esac
    if exited; then
      as_claude "tmux kill-session -t $SESSION"
      FAIL="Claude exited: $(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -2 | tr '\n' ' ')"
      return 1
    fi
  done
}
# Claude is gone and only the trailing sleep is left in its pane.
exited() { [ "$(as_claude "tmux display-message -p -t $SESSION '#{pane_current_command}'" 2>/dev/null)" = sleep ]; }

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
  local f s
  # The transcript of the Claude running in this tmux session (see
  # ~/.claude/sessions/<pid>.json), not just the newest file: an older
  # conversation's file gets touched too, and its stale 403 would kill a
  # healthy session.
  for s in /home/claude/.claude/sessions/*.json; do
    grep -q "\"tmux\":\"$SESSION:" "$s" 2>/dev/null || continue
    # Still that process? PIDs get reused; procStart is its start time.
    [ "$(cut -d' ' -f22 "/proc/$(basename "$s" .json)/stat" 2>/dev/null)" = \
      "$(grep -o '"procStart":"[^"]*"' "$s" | cut -d'"' -f4)" ] || continue
    f=/home/claude/.claude/projects/-home-claude-work/$(grep -o '"sessionId":"[^"]*"' "$s" | cut -d'"' -f4).jsonl
  done
  [ -f "$f" ] || f=$(ls -t /home/claude/.claude/projects/-home-claude-work/*.jsonl 2>/dev/null | head -1)
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
    settings_ok || exit 3
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
    echo "$SIG" > "$SIGF"
    if [ "$MODE" = server ]; then
      CMD="claude remote-control --permission-mode $PERM${RCNAME:+ --name '$RCNAME'}"
      # Reattach to the same server in the app if ~/work had one (Claude
      # allows about 4 hours; if that fails right away, register a new one).
      if [ -f /home/claude/.claude/projects/-home-claude-work/bridge-pointer.json ]; then
        server_start "$CMD --continue"; r=$?
        [ $r = 1 ] || exit $r
      fi
      server_start "$CMD"; r=$?
      # Claude's record of the last server here blocks a new one. If that
      # server is gone, the record is stale: drop it and start fresh.
      if [ $r = 1 ] && [ -f "/home/claude/.claude/projects/-home-claude-work/bridge-pointer.json" ] && case "$FAIL" in *"already served"*) true;; *) false;; esac; then
        old=$(grep -o '"pid":[0-9]*' "/home/claude/.claude/projects/-home-claude-work/bridge-pointer.json" | cut -d: -f2)
        if [ -n "$old" ] && [ -d "/proc/$old" ]; then
          echo "Another claude remote-control (PID $old) already serves ~/work. Stop it, or set a different folder." >&2; exit 3
        fi
        rm -f "/home/claude/.claude/projects/-home-claude-work/bridge-pointer.json"
        server_start "$CMD"; r=$?
      fi
      [ $r = 1 ] && echo "$FAIL" >&2
      exit $r
    fi
    if [ "$PERM" = bypassPermissions ]; then P=--dangerously-skip-permissions; else P="--permission-mode $PERM"; fi
    # Resume the conversation with the latest message; start fresh if there is
    # none or it can't load. Not --continue: it picks the newest file, and
    # Claude also appends notices to old ones.
    CMD="claude --remote-control${RCNAME:+ '$RCNAME'} $P"
    id=
    bt=
    for f in /home/claude/.claude/projects/-home-claude-work/*.jsonl; do
      [ -f "$f" ] || continue
      t=$(tac "$f" | grep -a -m1 -E '"type":"(user|assistant)"' | grep -o '"timestamp":"[^"]*"')
      [[ "$t" > "$bt" ]] && { bt=$t; id=$(basename "$f" .jsonl); }
    done
    if [ -f /run/claude-fresh-next ] || [ -z "$id" ]; then   # see rc_heal
      rm -f /run/claude-fresh-next
      as_claude "cd ~/work && tmux new-session -d -s $SESSION \"$CMD\""
    else
      as_claude "cd ~/work && tmux new-session -d -s $SESSION \"$CMD --resume $id || $CMD\""
    fi
    ;;
  check)
    as_claude "tmux has-session -t $SESSION" 2>/dev/null || exit 1
    # Settings changed since start: restart with the new ones. (No record yet,
    # e.g. started by an older version: adopt the running one as is.)
    [ -f "$SIGF" ] || echo "$SIG" > "$SIGF"
    if [ "$(cat "$SIGF")" != "$SIG" ]; then
      as_claude "tmux kill-session -t $SESSION"
      echo "Settings changed; restarting Claude" >&2
      exit 1
    fi
    if [ "$MODE" = server ] && exited; then
      as_claude "tmux kill-session -t $SESSION"; echo "Claude exited; restarting" >&2; exit 1
    fi
    [ "$MODE" = session ] && rc_heal
    true
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
