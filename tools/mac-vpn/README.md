# Mac VPN (Tailscale)

Your own private VPN, using your Mac as the exit point.

## Mac (once)
1. Open Terminal, run: `bash setup-mac.sh`
2. Sign in to Tailscale when asked.
3. In the Tailscale admin page, approve this Mac as an **exit node**.

## Phone (once)
1. Install the **Tailscale** app from the Play Store and sign in with the same account.
2. Tap **Exit node** and choose your Mac. All phone traffic now goes through the Mac.

## BeatDeck
The Mac's Tailscale address (100.x.x.x) works as the Mac address in BeatDeck from anywhere, not only at home.

Notes: the Mac must be on and awake. Turning on the exit node routes everything (including Soulseek) through your home internet connection.
