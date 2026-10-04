#!/bin/bash
#  uninstall.sh — 데몬/CLI 제거 (root 필요)
#  제거 전에 팬 제어를 반드시 시스템에 돌려준다.
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "sudo $0 로 실행하세요."
    exit 1
fi

LABEL="com.fandeck.daemon"

echo "▸ 팬 제어를 시스템 자동으로 반환"
/usr/local/bin/fandeck release 2>/dev/null || true
sleep 1

echo "▸ 데몬 중지 및 제거"
launchctl bootout system/"$LABEL" 2>/dev/null || true
rm -f "/Library/LaunchDaemons/$LABEL.plist"
rm -f /usr/local/libexec/fandeckd
rm -f /usr/local/bin/fandeck
rm -f /var/run/fandeck.sock

echo "▸ 설정 파일은 남겨둡니다: /Library/Application Support/FanDeck"
echo "  완전히 지우려면: sudo rm -rf '/Library/Application Support/FanDeck'"
echo ""
echo "제거 완료. 팬은 macOS 가 다시 관리합니다."
