#!/bin/bash
# Installs RefillBar into /Applications and opens it.
#   curl -fsSL https://refillbar.codeaz.org/install.sh | bash
set -euo pipefail

[ "$(uname)" = "Darwin" ] || { echo "RefillBar only runs on macOS."; exit 1; }
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || { echo "RefillBar needs macOS 14 or later."; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading RefillBar..."
curl -fsSL https://github.com/codeaz-org/RefillBar/releases/latest/download/RefillBar.zip -o "$tmp/RefillBar.zip"

pkill -x RefillBar 2>/dev/null || true
rm -rf /Applications/RefillBar.app
ditto -x -k "$tmp/RefillBar.zip" /Applications
open /Applications/RefillBar.app

echo "Installed. Look for the meters in your menu bar, then sign in to each site in the window."
