#!/bin/bash
#  install.sh — 데몬/CLI 설치 (root 필요)
#
#  SMC 에 쓰려면 root 권한이 필요해서, 제어는 LaunchDaemon 으로 도는 fandeckd 가 맡는다.
#  앱은 일반 권한으로 돌면서 유닉스 소켓으로 데몬에 요청만 보낸다.
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "이 스크립트는 관리자 권한이 필요합니다:"
    echo "  sudo $0"
    exit 1
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$PROJECT_DIR/build"
LABEL="com.fandeck.daemon"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
DAEMON_PATH="/usr/local/libexec/fandeckd"
CLI_PATH="/usr/local/bin/fandeck"

if [ ! -f "$BUILD/fandeckd" ]; then
    echo "빌드 결과물이 없습니다. 먼저 Scripts/build.sh 를 실행하세요."
    exit 1
fi

echo "▸ 기존 데몬 정리"
launchctl bootout system/"$LABEL" 2>/dev/null || true
sleep 1

echo "▸ 바이너리 설치"
mkdir -p /usr/local/libexec /usr/local/bin
install -m 755 -o root -g wheel "$BUILD/fandeckd" "$DAEMON_PATH"
install -m 755 -o root -g wheel "$BUILD/fandeck" "$CLI_PATH"

echo "▸ LaunchDaemon 등록"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>              <string>$LABEL</string>
    <key>ProgramArguments</key>   <array><string>$DAEMON_PATH</string></array>
    <key>RunAtLoad</key>          <true/>
    <key>KeepAlive</key>          <true/>
    <key>ProcessType</key>        <string>Background</string>
    <key>StandardErrorPath</key>  <string>/var/log/fandeck.err.log</string>
</dict>
</plist>
PLISTEOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

echo "▸ 데몬 시작"
launchctl bootstrap system "$PLIST"
sleep 3

if launchctl print system/"$LABEL" >/dev/null 2>&1; then
    echo ""
    echo "설치 완료."
    echo ""
    "$CLI_PATH" status || true
    echo ""
    echo "  앱 실행 : open \"$BUILD/FanDeck.app\""
    echo "  제거    : sudo $PROJECT_DIR/Scripts/uninstall.sh"
else
    echo "데몬이 시작되지 않았습니다. 로그를 확인하세요: /var/log/fandeck.err.log"
    exit 1
fi
