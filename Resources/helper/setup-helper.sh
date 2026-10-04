#!/bin/bash
#  setup-helper.sh — 앱이 관리자 권한으로 실행하는 설치 스크립트
#  인자 1: 앱 번들의 Resources 경로 (실행 파일들이 들어 있는 곳)
set -euo pipefail

RES="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
LABEL="com.fandeck.daemon"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
HELPER="/usr/local/libexec/fandeckd"
CLI="/usr/local/bin/fandeck"

[ -f "$RES/fandeckd" ] || { echo "설치 파일을 찾을 수 없습니다: $RES/fandeckd"; exit 1; }

launchctl bootout system/"$LABEL" 2>/dev/null || true
sleep 1

mkdir -p /usr/local/libexec /usr/local/bin
install -m 755 -o root -g wheel "$RES/fandeckd" "$HELPER"
[ -f "$RES/fandeck" ] && install -m 755 -o root -g wheel "$RES/fandeck" "$CLI"

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>              <string>$LABEL</string>
    <key>ProgramArguments</key>   <array><string>$HELPER</string></array>
    <key>RunAtLoad</key>          <true/>
    <key>KeepAlive</key>          <true/>
    <key>ProcessType</key>        <string>Background</string>
    <key>StandardErrorPath</key>  <string>/var/log/fandeck.err.log</string>
</dict>
</plist>
PLISTEOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

launchctl bootstrap system "$PLIST"
sleep 2
launchctl print system/"$LABEL" >/dev/null 2>&1 || { echo "시작 실패"; exit 1; }
echo "ok"
