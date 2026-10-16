#!/bin/zsh
# DeskHub 빌드 → .app 번들 조립 → /Applications 설치
set -e
setopt pipefail   # 0.37.0 리뷰 2: `swift build | tail` 이 실패해도 exit 0 이던 것 — 파이프 실패를 실패로
cd "$(dirname "$0")"
rm -f .build/release/DeskHub   # 빌드가 실패하면 옛 바이너리를 쓰지 않게
swift build -c release 2>&1 | tail -5
(( ${pipestatus[1]} == 0 )) || { echo "빌드 실패"; exit 1; }
[ -x .build/release/DeskHub ] || { echo "빌드 실패: 바이너리 없음"; exit 1; }
BIN=".build/release/DeskHub"
# 범용(arm64+x86_64) — publish 는 늘, 그 밖은 DESKHUB_UNIVERSAL=1 일 때 (0.37.0 검증 1 리뷰: R3 0.36.0 이 범용인데
# build.sh publish 가 arm64 단일이면 Intel 맥(SYJ x86_64)이 '새 버전 받기' 뒤 'Bad CPU type'). CLT 만 있어도 --triple 로 x86_64 를 따로 빌드해 lipo 로 합친다.
# 한쪽이라도 실패하면 set -e 로 멈춤 — arm64 단일본을 배포하지 않게
if [ "$1" = "publish" ] || [ "$2" = "publish" ] || [ "${DESKHUB_UNIVERSAL:-}" = "1" ]; then
  # 옛 아키텍처별 바이너리를 먼저 지운다 — 빌드가 실패해도 lipo 가 옛 것을 합치지 않게 (0.37.0 리뷰 2)
  rm -f .build/arm64-apple-macosx/release/DeskHub .build/x86_64-apple-macosx/release/DeskHub
  swift build -c release --triple arm64-apple-macosx 2>&1 | tail -3
  (( ${pipestatus[1]} == 0 )) || { echo "arm64 빌드 실패"; exit 1; }
  swift build -c release --triple x86_64-apple-macosx 2>&1 | tail -3
  (( ${pipestatus[1]} == 0 )) || { echo "x86_64 빌드 실패"; exit 1; }
  for a in arm64 x86_64; do
    [ -x ".build/$a-apple-macosx/release/DeskHub" ] || { echo "$a 빌드 실패: 바이너리 없음"; exit 1; }
  done
  mkdir -p build
  lipo -create .build/arm64-apple-macosx/release/DeskHub .build/x86_64-apple-macosx/release/DeskHub -output build/DeskHub-universal
  BIN="build/DeskHub-universal"
fi
APP="build/DeskHub.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DeskHub"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/DeskHub" 2>/dev/null || uname -m)"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 버전·빌드 표기 (조사 P1-⑦: 멤버 맥 구버전 구분) — ../VERSION + git SHA + 빌드 시각
VER="$(cat ../VERSION 2>/dev/null || echo 0.0.0)"; SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
git diff --quiet HEAD -- . 2>/dev/null || SHA="$SHA+"
PB=/usr/libexec/PlistBuddy
$PB -c "Set :CFBundleShortVersionString $VER" "$APP/Contents/Info.plist"
$PB -c "Set :CFBundleVersion $SHA" "$APP/Contents/Info.plist"
$PB -c "Add :DeskHubBuilt string $(date '+%Y-%m-%d %H:%M')" "$APP/Contents/Info.plist" 2>/dev/null || $PB -c "Set :DeskHubBuilt $(date '+%Y-%m-%d %H:%M')" "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
[ -f Resources/themes.json ] && cp Resources/themes.json "$APP/Contents/Resources/themes.json"
[ -f Resources/pipelines.json ] && cp Resources/pipelines.json "$APP/Contents/Resources/pipelines.json"
[ -f Resources/apps.json ] && cp Resources/apps.json "$APP/Contents/Resources/apps.json"
[ -f Resources/scoreboard-sample.json ] && cp Resources/scoreboard-sample.json "$APP/Contents/Resources/scoreboard-sample.json"
[ -f Resources/research-topics.json ] && cp Resources/research-topics.json "$APP/Contents/Resources/research-topics.json"
echo 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - "$APP" 2>&1 | grep -v 'replacing existing signature' || true
# 리뷰 라운드 배포 (리뷰 방식 개선 B1, 2026-10-15): `./build.sh install publish` 또는 `./build.sh publish`
#   NAS Grant/_ssot/deskhub/DeskHub-<버전>.zip + latest.json — 멤버 맥은 /deskhub:update 나 앱 메뉴 '새 버전 받기'로 컴파일 없이 받는다
if [ "$1" = "publish" ] || [ "$2" = "publish" ]; then
  PUB="${DESKHUB_PUBLISH_DIR:-/Volumes/CSNL_new/Grant/_ssot/deskhub}"
  if [ -d "$(dirname "$PUB")" ]; then
    case " $ARCHS " in *" x86_64 "*) ;; *) echo "publish 중단: 범용 아님 ($ARCHS)"; exit 1;; esac
    mkdir -p "$PUB"
    ZIP="$PUB/DeskHub-$VER.zip"
    ditto -c -k --keepParent "$APP" "$ZIP.tmp" && mv "$ZIP.tmp" "$ZIP"
    /usr/bin/python3 -c 'import json,sys; json.dump({"version":sys.argv[1],"sha":sys.argv[2],"built":sys.argv[3],"round":sys.argv[4],"zip":sys.argv[5],"archs":sys.argv[7]},open(sys.argv[6]+".tmp","w"),ensure_ascii=False,indent=1)' \
      "$VER" "$SHA" "$(date '+%Y-%m-%d %H:%M')" "${DESKHUB_ROUND:-}" "$(basename "$ZIP")" "$PUB/latest.json" "$ARCHS" && mv "$PUB/latest.json.tmp" "$PUB/latest.json"
    # 교수님 사용 안내·설치 안내 (0.37.0 C8) — docs 의 두 파일을 manual/ 로 복사만 (지우기·이름 바꾸기 없음)
    mkdir -p "$PUB/manual"
    for f in ../docs/professor-manual-2026-10-16.html ../docs/professor-install-guide-2026-10-16.md; do
      if [ -f "$f" ]; then cp "$f" "$PUB/manual/"; fi
    done
    echo "published: $ZIP (round ${DESKHUB_ROUND:-—})"
  else
    echo "publish 건너뜀: NAS 없음 ($PUB)"
  fi
fi
if [ "$1" = "install" ]; then
  pkill -x DeskHub 2>/dev/null || true
  rm -rf /Applications/DeskHub.app
  cp -R "$APP" /Applications/DeskHub.app
  echo "installed: /Applications/DeskHub.app"
fi
echo "built: $APP ($VER $SHA · $ARCHS)"
