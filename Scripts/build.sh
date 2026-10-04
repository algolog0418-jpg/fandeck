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
    <key>CFBundleVersion</key>              <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>   <string>1.0.0</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>       <string>15.0</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>NSHumanReadableCopyright</key>     <string>FanDeck</string>
    <key>LSApplicationCategoryType</key>    <string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

# 서명이 없으면 Gatekeeper 가 막는다. 로컬 전용 ad-hoc 서명을 붙인다.
echo "▸ ad-hoc 코드서명"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (서명 생략됨)"

echo ""
echo "빌드 완료"
echo "  앱    : $APP"
echo "  데몬  : $BUILD/fandeckd"
echo "  CLI   : $BUILD/fandeck"
