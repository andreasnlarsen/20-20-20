#!/bin/bash
# Builds 20-20-20, installs it in ~/Applications and hands it to launchd,
# which starts it at login and restarts it whenever it is killed.
set -euo pipefail
cd "$(dirname "$0")"

label="com.andreaslar.twenty-twenty-twenty"
app="$HOME/Applications/20-20-20.app"
agent="$HOME/Library/LaunchAgents/$label.plist"
service="gui/$(id -u)/$label"

./build.sh

# Stop a previous install and wait until launchd has let go of it.
launchctl bootout "$service" 2>/dev/null || true
for _ in $(seq 1 50); do
  launchctl print "$service" >/dev/null 2>&1 || break
  sleep 0.2
done

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$app"
cp -R "build/20-20-20.app" "$app"

cat > "$agent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>$app/Contents/MacOS/20-20-20</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>1</integer>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$agent"
echo "20-20-20 is installed and running. To remove it: ./uninstall.sh"
