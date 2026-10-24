#!/bin/bash
# One-time Mac-side setup for the RemoteMac host.
set -uo pipefail

echo "==> Tailscale"
if command -v tailscale >/dev/null 2>&1; then
  tailscale ip -4 2>/dev/null | sed 's/^/    mac tailnet IP: /'
else
  echo "    tailscale CLI not found — is the Mac in your tailnet?"
fi

echo
echo "==> Power settings"
echo "    Current:"
pmset -g custom | grep -E "sleep|displaysleep|womp" | sed 's/^/      /'
echo "    Setting AC power to never sleep (battery settings are left alone):"
sudo pmset -c sleep 0 displaysleep 0 disksleep 0 womp 1

echo
echo "==> Firewall"
if /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null | grep -q enabled; then
  echo "    Firewall is on. The host only listens on the tailnet interface, and"
  echo "    Tailscale traffic is already allowed, so no rule is needed."
else
  echo "    Firewall is off. Nothing is exposed to the internet anyway: the"
  echo "    server binds to the Tailscale address only."
fi

echo
echo "==> Reminder"
cat <<'EOF'
    Grant these to "RemoteMac Host" in System Settings > Privacy & Security:
      1. Screen & System Audio Recording  (required to see the screen)
      2. Accessibility                    (required to control the Mac)

    Then start the host with:  open build/RemoteMacHost.app
EOF
