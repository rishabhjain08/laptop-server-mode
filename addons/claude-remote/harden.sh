#!/bin/bash
# ClaudeBox hardening. Runs as root at boot and before every service start.
# Idempotent. Exits non-zero if the box isn't in a safe state.
set -u
BOX_UID=2501

# 1. WSLg bridge (GUI, clipboard, microphone, speakers): remove from this distro.
for m in /tmp/.X11-unix /mnt/wslg; do
  mountpoint -q "$m" 2>/dev/null && umount -R -l "$m"
done
rm -f /tmp/.X11-unix 2>/dev/null

# 2. Windows drives must not be mounted (automount is off; this is a backstop).
for m in $(awk '$3 ~ /^(9p|drvfs|virtiofs)$/ && $2 ~ /^\/mnt\/[a-z]$/ {print $2}' /proc/mounts); do
  umount -l "$m"
done

# 3. Windows programs: WSL launches them through sockets in /run/WSL.
#    Root-only access there means the box user can't start any .exe.
chmod 0700 /run/WSL 2>/dev/null

# 4. Network: the box user may reach the internet, but not the home network,
#    VPN peers (ZeroTier/Tailscale) or sensitive services on this laptop.
#    WSL distros share one network stack, so rules match the box user only.
# On-link global IPv6 prefixes = the home network's IPv6 range.
v6_lan=$(ip -6 route show 2>/dev/null | awk '$1 ~ /\/[0-9]+$/ && $1 !~ /^(fe80|ff|::)/ {print $1}' | sort -u | paste -sd, -)
nft delete table inet claudebox 2>/dev/null
nft -f - <<NFT
table inet claudebox {
  chain out {
    type filter hook output priority 0; policy accept;
    meta skuid != $BOX_UID accept
    ip daddr 10.255.255.254 meta l4proto { tcp, udp } th dport 53 accept
    ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10, 224.0.0.0/4 } reject
    ip6 daddr { fc00::/7, fe80::/10, ff00::/8${v6_lan:+, $v6_lan} } reject
    ip daddr 127.0.0.0/8 tcp dport { 0-1023, 3240, 5040, 7680, 9993, 49664-49699 } reject
    ip6 daddr ::1 tcp dport { 0-1023, 3240, 5040, 7680, 9993, 49664-49699 } reject
  }
}
NFT

# 5. Verify.
ok=1
nft list table inet claudebox >/dev/null 2>&1 || { echo "harden: firewall missing" >&2; ok=0; }
[ -e /mnt/wslg/PulseServer ] && { echo "harden: WSLg still present" >&2; ok=0; }
grep -qE ' /mnt/[a-z] ' /proc/mounts && { echo "harden: Windows drive mounted" >&2; ok=0; }
[ "$(stat -c %a /run/WSL 2>/dev/null)" = 700 ] || { echo "harden: /run/WSL open" >&2; ok=0; }
[ "$ok" = 1 ]
