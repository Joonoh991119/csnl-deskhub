#!/bin/zsh
# DeskHub 업데이트 — NAS 의 리뷰 라운드 빌드를 받아 설치·재실행 (컴파일·CLT 불필요, 리뷰 방식 개선 B1)
#   NAS Grant/_ssot/deskhub/latest.json 의 version 이 설치본보다 새로우면 zip 을 풀어 /Applications/DeskHub.app 을 바꾼다.
#   --force 면 버전이 같아도 다시 깐다.
set -e
PUB="${DESKHUB_PUBLISH_DIR:-/Volumes/CSNL_new/Grant/_ssot/deskhub}"
[ -f "$PUB/latest.json" ] || { echo "NAS 에 배포본이 없습니다 ($PUB/latest.json) — NAS 연결 확인"; exit 1; }
# 파이썬 없이(교수님 Mac mini 등 개발 도구 없는 맥) macOS 기본 plutil 로 읽는다 (10-16)
NEW="$(/usr/bin/plutil -extract version raw -o - "$PUB/latest.json")"; ZIP="$(/usr/bin/plutil -extract zip raw -o - "$PUB/latest.json")"; ROUND="$(/usr/bin/plutil -extract round raw -o - "$PUB/latest.json" 2>/dev/null || echo -)"
CUR="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/DeskHub.app/Contents/Info.plist 2>/dev/null || echo 0)"
if [ "$CUR" = "$NEW" ] && [ "$1" != "--force" ]; then echo "이미 최신: $CUR (라운드 $ROUND)"; exit 0; fi
TMP="$(mktemp -d)"
ditto -x -k "$PUB/$ZIP" "$TMP"
pkill -x DeskHub 2>/dev/null || true; sleep 1
rm -rf /Applications/DeskHub.app && ditto "$TMP/DeskHub.app" /Applications/DeskHub.app && rm -rf "$TMP"
mkdir -p ~/.claude/csnl-report/deskhub
nohup /Applications/DeskHub.app/Contents/MacOS/DeskHub > ~/.claude/csnl-report/deskhub/app.log 2>&1 &
echo "업데이트: $CUR → $NEW (라운드 $ROUND) · 재실행함"
