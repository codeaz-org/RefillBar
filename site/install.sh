#!/bin/bash
# Installs UsageBar into /Applications and opens it.
#   curl -fsSL https://usagebar.codeaz.org/install.sh | bash
set -euo pipefail

[ "$(uname)" = "Darwin" ] || { echo "UsageBar only runs on macOS."; exit 1; }
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || { echo "UsageBar needs macOS 14 or later."; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading UsageBar..."
curl -fsSL https://github.com/codeaz-org/UsageBar/releases/latest/download/UsageBar.zip -o "$tmp/UsageBar.zip"

pkill -x UsageBar 2>/dev/null || true
rm -rf /Applications/UsageBar.app
ditto -x -k "$tmp/UsageBar.zip" /Applications
open /Applications/UsageBar.app

echo "Installed. Look for the meters in your menu bar, then sign in to each site in the window."
