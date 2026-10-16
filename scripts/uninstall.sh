#!/bin/zsh
# Stop the LaunchAgent and remove the installed files. The override itself goes away on the next reconnect,
# or immediately with `edidentity reset --target <serial>` before running this.
label=com.inextro.edidentity
launchctl bootout gui/$(id -u)/$label 2>/dev/null || true
rm -f ~/Library/LaunchAgents/$label.plist ~/.local/bin/edidentity
echo "uninstalled"
