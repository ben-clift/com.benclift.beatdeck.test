#!/bin/bash
# Turns this Mac into your own private VPN exit using Tailscale (free).
# Run once in Terminal:  bash setup-mac.sh
set -e
if ! command -v brew >/dev/null; then
  echo "Install Homebrew first: https://brew.sh"; exit 1
fi
brew install --cask tailscale 2>/dev/null || true
open -a Tailscale
echo
echo "1) Sign in to Tailscale in the app that just opened (Google/Apple login is fine)."
read -p "Press Enter once you are signed in..."
CLI=/Applications/Tailscale.app/Contents/MacOS/Tailscale
# Let the phone send all its internet traffic through this Mac.
sudo sysctl -w net.inet.ip.forwarding=1 >/dev/null
"$CLI" up --advertise-exit-node --accept-dns=false
echo
echo "2) Open https://login.tailscale.com/admin/machines , click the three dots next to this Mac,"
echo "   choose 'Edit route settings' and tick 'Use as exit node'."
echo
echo "This Mac's private address (use it for BeatDeck's Mac address when away from home):"
"$CLI" ip -4
echo
echo "Keep the Mac awake: System Settings > Battery > Options > 'Prevent automatic sleeping when the display is off'."
