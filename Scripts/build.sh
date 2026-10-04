#!/bin/bash
#  build.sh — FanDeck 전체 빌드
#
#  Xcode 없이 Command Line Tools 만으로 빌드한다.
#  결과물: build/FanDeck.app, build/fandeckd, build/fandeck
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="arm64-apple-macosx15.0"
BUILD="$PROJECT_DIR/build"
APP="$BUILD/FanDeck.app"

mkdir -p "$BUILD"

# ── 버전 ──
# VERSION 은 사람이 정하는 번호(1.0.0), BUILD_NUMBER 는 빌드할 때마다 하나씩 오른다.
# 고친 내용이 실제로 설치됐는지 눈으로 확인할 수 있어야, 앱만 새로 깔고
# 서비스는 옛것이 남은 상황을 알아챌 수 있다.
# (파일 이름을 BUILD 로 두면 macOS 가 대소문자를 구분하지 않아 build/ 디렉터리와 겹친다.)
VERSION="$(cat "$PROJECT_DIR/VERSION" 2>/dev/null || echo 1.0.0)"
BUILD_NUMBER=$(( $(cat "$PROJECT_DIR/BUILD_NUMBER" 2>/dev/null || echo 0) + 1 ))
echo "$BUILD_NUMBER" > "$PROJECT_DIR/BUILD_NUMBER"
BUILD_DATE="$(date '+%Y-%m-%d %H:%M')"
echo "▸ 버전 $VERSION (빌드 $BUILD_NUMBER)"

# 소스에서 읽을 수 있도록 파일로 떨어뜨린다. 빌드가 만들어 내는 파일이라 직접 고치지 않는다.
cat > "$PROJECT_DIR/Sources/FanDeckCore/BuildInfo.swift" <<SWIFTEOF
//  BuildInfo.swift — 빌드가 자동으로 만드는 파일. 직접 고치지 말 것.
//  Scripts/build.sh 가 빌드할 때마다 새로 쓴다.

import Foundation

public enum BuildInfo {
    public static let version = "$VERSION"
    public static let build = $BUILD_NUMBER
    public static let date = "$BUILD_DATE"

    /// "1.0.0 (빌드 42)" 처럼 사람이 읽는 형태.
    public static var full: String { "\\(version) (\\(L.t("빌드", "build")) \\(build))" }
}
SWIFTEOF

echo "▸ SMC C 레이어 컴파일"
clang -c -O2 -mmacosx-version-min=15.0 -o "$BUILD/smc.o" Sources/FanDeckCore/smc.c

CORE=(Sources/FanDeckCore/*.swift)
COMMON=(-O -target "$TARGET" -sdk "$SDK" -import-objc-header Sources/FanDeckCore/smc.h)

echo "▸ 데몬 빌드 (fandeckd)"
swiftc "${COMMON[@]}" -o "$BUILD/fandeckd" "${CORE[@]}" Sources/fandeckd/main.swift "$BUILD/smc.o"

echo "▸ CLI 빌드 (fandeck)"
swiftc "${COMMON[@]}" -o "$BUILD/fandeck" "${CORE[@]}" Sources/fandeck-cli/main.swift "$BUILD/smc.o"

echo "▸ 앱 빌드 (FanDeck)"
swiftc "${COMMON[@]}" -parse-as-library -o "$BUILD/FanDeck.bin" \
    "${CORE[@]}" Sources/FanDeck/*.swift "$BUILD/smc.o"

echo "▸ 앱 번들 구성"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BUILD/FanDeck.bin" "$APP/Contents/MacOS/FanDeck"
cp Resources/FanDeck.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 앱 안에서 "팬 제어 켜기"를 누르면 쓰는 파일들. 번들에 같이 넣어야
# 사용자가 터미널을 열 필요가 없다.
cp "$BUILD/fandeckd" "$APP/Contents/Resources/fandeckd"
cp "$BUILD/fandeck"  "$APP/Contents/Resources/fandeck"
cp Resources/helper/setup-helper.sh  "$APP/Contents/Resources/setup-helper.sh"
cp Resources/helper/remove-helper.sh "$APP/Contents/Resources/remove-helper.sh"
chmod 755 "$APP/Contents/Resources/"*.sh "$APP/Contents/Resources/fandeckd" "$APP/Contents/Resources/fandeck"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>FanDeck</string>
    <key>CFBundleDisplayName</key>          <string>FanDeck</string>
    <key>CFBundleExecutable</key>           <string>FanDeck</string>
    <key>CFBundleIdentifier</key>           <string>com.fandeck.app</string>
    <key>CFBundleVersion</key>              <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key>   <string>$VERSION</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>       <string>15.0</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>NSHumanReadableCopyright</key>     <string>FanDeck</string>
    <key>LSApplicationCategoryType</key>    <string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

# heredoc 안에서 변수 치환이 기대대로 되지 않는 경우가 있어, 버전은 만든 뒤에
# 직접 덮어쓴다. 이 값이 틀리면 설치된 앱이 어느 빌드인지 알 수 없게 된다.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist" >/dev/null

# 서명이 없으면 Gatekeeper 가 막는다. 로컬 전용 ad-hoc 서명을 붙인다.
echo "▸ ad-hoc 코드서명"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (서명 생략됨)"

# 결과물이 실제로 만들어졌는지 확인한다.
# 중간에 조용히 실패하면 예전 번들이 그대로 남아, 고친 내용이 반영된 줄 알고
# 한참을 헤매게 된다(실제로 그런 일이 있었다).
for artifact in "$APP/Contents/MacOS/FanDeck" "$BUILD/fandeckd" "$BUILD/fandeck"; do
    if [ ! -x "$artifact" ]; then
        echo "빌드 실패: $artifact 가 만들어지지 않았습니다" >&2
        exit 1
    fi
done
# 번들 버전이 이번 빌드 번호와 맞는지도 본다.
PLIST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo '')"
if [ "$PLIST_BUILD" != "$BUILD_NUMBER" ]; then
    echo "빌드 실패: 번들 버전($PLIST_BUILD)이 빌드 번호($BUILD_NUMBER)와 다릅니다" >&2
    exit 1
fi

echo ""
echo "빌드 완료 — $VERSION (빌드 $BUILD_NUMBER)"
echo "  앱    : $APP"
echo "  데몬  : $BUILD/fandeckd"
echo "  CLI   : $BUILD/fandeck"
