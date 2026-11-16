#!/bin/bash
# NotchMusic 설치 스크립트. 터미널에 아래 한 줄을 붙여 넣으면 된다.
#   curl -fsSL https://raw.githubusercontent.com/dnjswldnd-3513/notch-music/main/install.sh | bash
set -euo pipefail

URL="https://github.com/dnjswldnd-3513/notch-music/releases/latest/download/NotchMusic.zip"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "NotchMusic 내려받는 중..."
curl -fsSL "$URL" -o "$TMP/NotchMusic.zip"
ditto -x -k "$TMP/NotchMusic.zip" "$TMP"

# 이미 켜져 있으면 끄고 새 버전으로 바꾼다.
pkill -x NotchMusic 2>/dev/null || true

DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/NotchMusic.app"
ditto "$TMP/NotchMusic.app" "$DEST/NotchMusic.app"
xattr -dr com.apple.quarantine "$DEST/NotchMusic.app" 2>/dev/null || true

open "$DEST/NotchMusic.app"
echo ""
echo "설치 완료: $DEST/NotchMusic.app"
echo "음악이나 유튜브를 틀면 노치에 나타납니다."
