#!/bin/bash
# NotchMusic.app을 build/ 폴더에 만든다. Apple Silicon과 Intel 맥에서 모두 돈다.
#   ./build.sh            앱만 만들기
#   ./build.sh --install  만든 뒤 ~/Applications에 복사하고 실행
#   ./build.sh --release  배포용 build/NotchMusic.zip, build/NotchMusic.dmg까지 만들기
set -euo pipefail
cd "$(dirname "$0")"

APP="build/NotchMusic.app"
VERSION="$(cat VERSION)"

echo "▸ Swift 빌드 (Apple Silicon, Intel)"
for arch in arm64 x86_64; do
    swift build -c release --triple "$arch-apple-macosx14.0"
done

echo "▸ 어댑터 빌드"
mkdir -p build
clang -dynamiclib -fobjc-arc -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
    -framework Foundation Adapter/adapter.m -o build/adapter.dylib

echo "▸ 앱 묶기 (v$VERSION)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create \
    .build/arm64-apple-macosx/release/NotchMusic \
    .build/x86_64-apple-macosx/release/NotchMusic \
    -output "$APP/Contents/MacOS/NotchMusic"
cp build/adapter.dylib Adapter/run.pl "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.dnjswldnd-3513.notchmusic</string>
    <key>CFBundleName</key><string>NotchMusic</string>
    <key>CFBundleDisplayName</key><string>NotchMusic</string>
    <key>CFBundleExecutable</key><string>NotchMusic</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 키체인에 "NotchMusic Signing" 인증서가 있으면 그걸로 서명한다. 서명이 버전마다 같아야
# 업데이트해도 손쉬운 사용 권한이 유지된다. 없으면(다른 사람이 빌드할 때) 임시 서명.
IDENTITY="$(security find-identity -p codesigning 2>/dev/null | awk '/"NotchMusic Signing"/ {print $2; exit}')"
codesign --force --deep --sign "${IDENTITY:--}" "$APP" >/dev/null
[[ -n "$IDENTITY" ]] && echo "  (NotchMusic Signing 인증서로 서명)" || echo "  (임시 서명: 업데이트 때마다 권한을 다시 줘야 함)"
echo "✓ $APP"

case "${1:-}" in
--install)
    mkdir -p ~/Applications
    pkill -x NotchMusic 2>/dev/null || true
    rm -rf ~/Applications/NotchMusic.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/NotchMusic.app
    echo "✓ ~/Applications/NotchMusic.app 실행"
    ;;
--release)
    # install.sh가 받는 zip
    rm -f build/NotchMusic.zip
    ditto -c -k --keepParent "$APP" build/NotchMusic.zip
    echo "✓ build/NotchMusic.zip"
    # 열면 "NotchMusic → 응용 프로그램" 끌어다 놓기 창이 뜨는 디스크 이미지
    STAGE="build/dmg"
    rm -rf "$STAGE" build/NotchMusic.dmg
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "NotchMusic" -srcfolder "$STAGE" -ov -format UDZO build/NotchMusic.dmg >/dev/null
    rm -rf "$STAGE"
    echo "✓ build/NotchMusic.dmg"
    ;;
esac
