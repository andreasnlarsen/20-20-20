#!/bin/bash
# Stops 20-20-20 and removes the app, its launchd agent and its saved state.
set -euo pipefail

label="com.andreaslar.twenty-twenty-twenty"

launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$label.plist"
rm -rf "$HOME/Applications/20-20-20.app" "/Applications/20-20-20.app"
rm -rf "$HOME/Library/Application Support/20-20-20"
rm -rf "$HOME/Library/Application Support/20-20-20-test"
echo "20-20-20 is removed."
