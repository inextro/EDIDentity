#!/bin/zsh
# Build, install to ~/.local/bin, and register a LaunchAgent that runs `edidentity watch` at login.
# usage: scripts/install.sh <alphanumeric serial> [numeric serial]
set -e
[[ -n "$1" ]] || { echo "usage: $0 <alphanumeric serial> [numeric serial]"; echo "find it with: edidentity list"; exit 1 }
cd "${0:A:h}/.."

mkdir -p build ~/.local/bin ~/Library/LaunchAgents ~/Library/Logs
swiftc -O Sources/main.swift -o build/edidentity
install -m 755 build/edidentity ~/.local/bin/edidentity

label=com.inextro.edidentity
plist=~/Library/LaunchAgents/$label.plist
serial_args=""
[[ -n "$2" ]] && serial_args="<string>--serial</string><string>$2</string>"
cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HOME/.local/bin/edidentity</string>
        <string>watch</string>
        <string>--target</string><string>$1</string>
        $serial_args
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Background</string>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/edidentity.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/edidentity.log</string>
</dict>
</plist>
EOF

launchctl bootout gui/$(id -u)/$label 2>/dev/null || true
launchctl bootstrap gui/$(id -u) "$plist"
echo "installed: ~/.local/bin/edidentity, $plist"
echo "log: ~/Library/Logs/edidentity.log"
