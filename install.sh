#!/bin/bash
# Builds 20-20-20 from source, installs it in ~/Applications and opens it once.
# On that first open the app hands itself over to launchd, which starts it at
# login and restarts it whenever it is killed.
set -euo pipefail
cd "$(dirname "$0")"

app="$HOME/Applications/20-20-20.app"
service="gui/$(id -u)/com.andreaslar.twenty-twenty-twenty"

./build.sh

# Stop a previous install and wait until launchd has let go of it,
# so the new copy is the one that gets started.
launchctl bootout "$service" 2>/dev/null || true
for _ in $(seq 1 50); do
  launchctl print "$service" >/dev/null 2>&1 || break
  sleep 0.2
done

mkdir -p "$HOME/Applications"
rm -rf "$app"
cp -R "build/20-20-20.app" "$app"

"$app/Contents/MacOS/20-20-20"
echo "20-20-20 is installed and running. To remove it: ./uninstall.sh"
