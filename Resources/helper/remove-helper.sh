#!/bin/bash
#  remove-helper.sh — 팬 제어 기능 끄기. 반드시 팬을 시스템에 돌려주고 지운다.
set -euo pipefail
LABEL="com.fandeck.daemon"
/usr/local/bin/fandeck release 2>/dev/null || true
sleep 1
launchctl bootout system/"$LABEL" 2>/dev/null || true
rm -f "/Library/LaunchDaemons/$LABEL.plist" /usr/local/libexec/fandeckd /usr/local/bin/fandeck /var/run/fandeck.sock
echo "ok"
