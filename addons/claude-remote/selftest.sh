#!/bin/bash
# ClaudeBox isolation self-test. Run as root inside the box:
#   wsl.exe -d ClaudeBox -u root -- bash -s < addons/claude-remote/selftest.sh
# Every line should end in BLOCKED/none, except internet and DNS.
t() { printf '%-30s' "$1"; out=$(runuser -l claude -c "$2" </dev/null 2>&1 | tail -1); echo "${out:-<none>}"; }
port() { echo "timeout 4 bash -c '</dev/tcp/$1/$2' 2>/dev/null && echo OPEN || echo BLOCKED"; }
echo "boot hardening:      $(nft list table inet claudebox >/dev/null 2>&1 && echo active || echo MISSING)"
echo "/run/WSL mode:       $(stat -c %a /run/WSL)"
[ -f /tmp/test.exe ] && t "run a Windows .exe:" '/tmp/test.exe >/dev/null 2>&1 && echo RAN || echo BLOCKED'
t "C: drive:"            'ls -d /mnt/c 2>/dev/null || echo none'
t "WSLg (mic/GUI):"      'ls /mnt/wslg/PulseServer 2>/dev/null || echo none'
t "sudo:"                'sudo -n true 2>/dev/null && echo ALLOWED || echo BLOCKED'
t "internet (Claude API):" 'c=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 https://api.anthropic.com); [ "$c" != 000 ] && echo "ok (HTTP $c)" || echo FAIL'
t "DNS:"                 'getent hosts github.com >/dev/null && echo ok || echo FAIL'
gw=$(ip route show default | awk '{print $3; exit}')
t "router $gw:53"        "$(port "$gw" 53)"
t "router $gw:80"        "$(port "$gw" 80)"
t "laptop SSH :22"       "$(port 127.0.0.1 22)"
t "Windows SMB :445"     "$(port 127.0.0.1 445)"
t "ZeroTier API :9993"   "$(port 127.0.0.1 9993)"
