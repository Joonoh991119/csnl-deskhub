#!/bin/zsh
# DeskHub 한 줄 설치 (교수님 Mac mini 용, 개발 도구 불필요 — zsh·ditto·plutil·PlistBuddy·xattr·defaults·osascript 만 사용)
#   zsh install_professor.sh <이니셜> [Notion 연결 열쇠]
#   예) zsh ~/Downloads/install_professor.sh SL ntn_xxxxxxxx      (열쇠를 안 적으면 화면에 안 보이게 물어봄)
# 하는 일: ① 앱 파일 찾기(~/Downloads 또는 공용 저장소) → ② /Applications 에 설치(격리 표시 제거) → ③ 설정 파일(~/.claude/csnl-report/.env)
#         → ④ 기본 화면 = 랩 허브 → ⑤ 로그인 시 자동 실행 → ⑥ 실행. 공용 저장소(NAS)가 안 붙어 있으면 연결을 한 번 시도하고, 안 되면 Notion·캘린더만으로 먼저 뜬다.
set -u
INIT="${1:-}"; TOK="${2:-}"
[ -n "$INIT" ] || { echo "사용법: zsh install_professor.sh <이니셜> [연결 열쇠]   예) zsh install_professor.sh SL"; exit 1; }
INIT="${INIT:u}"
say() { printf '\n▶ %s\n' "$1"; }
NAS=/Volumes/CSNL_new; PUB="$NAS/Grant/_ssot/deskhub"

say "1/6 공용 저장소 확인"
if [ ! -d "$PUB" ]; then
  echo "   공용 저장소가 연결되어 있지 않아 연결을 시도합니다(계정을 물으면 연구실 저장소 계정을 넣어 주세요. 취소해도 설치는 계속됩니다)."
  osascript -e 'try' -e 'mount volume "smb://147.47.70.15/CSNL_new"' -e 'end try' >/dev/null 2>&1 || true
  sleep 2
fi
[ -d "$PUB" ] && echo "   연결됨: $NAS" || echo "   연결 안 됨 — 앱 파일은 ~/Downloads 에서 찾고, 저장소가 필요한 카드는 나중에 채워집니다."

say "2/6 앱 파일 찾기"
ZIP=""
if [ -d "$PUB" ] && [ -f "$PUB/latest.json" ]; then
  Z="$(/usr/bin/plutil -extract zip raw -o - "$PUB/latest.json" 2>/dev/null || true)"; [ -n "$Z" ] && [ -f "$PUB/$Z" ] && ZIP="$PUB/$Z"
fi
if [ -z "$ZIP" ]; then ZIP="$(ls -t ~/Downloads/DeskHub-*.zip 2>/dev/null | head -1 || true)"; fi
if [ -z "$ZIP" ] && [ -n "${DESKHUB_GITHUB_ZIP:-__GITHUB_ZIP_URL__}" ] && [ "${DESKHUB_GITHUB_ZIP:-__GITHUB_ZIP_URL__}" != "__GITHUB_ZIP_URL__" ]; then
  echo "   GitHub 에서 받습니다…"; /usr/bin/curl -fsSL -o ~/Downloads/DeskHub-latest.zip "${DESKHUB_GITHUB_ZIP:-__GITHUB_ZIP_URL__}" && ZIP=~/Downloads/DeskHub-latest.zip
fi
[ -n "$ZIP" ] || { echo "   DeskHub 앱 파일(DeskHub-<버전>.zip)을 ~/Downloads 나 공용 저장소에서 찾지 못했습니다. Slack 으로 받은 zip 을 다운로드 폴더에 두고 다시 실행해 주세요."; exit 1; }
echo "   사용: $ZIP"

say "3/6 설치"
TMP="$(mktemp -d)"
/usr/bin/ditto -x -k "$ZIP" "$TMP" || { echo "   압축을 풀지 못했습니다."; exit 1; }
[ -d "$TMP/DeskHub.app" ] || { echo "   zip 안에 DeskHub.app 이 없습니다."; exit 1; }
/usr/bin/xattr -dr com.apple.quarantine "$TMP/DeskHub.app" 2>/dev/null || true
pkill -x DeskHub 2>/dev/null || true; sleep 1
DEST=/Applications/DeskHub.app
if rm -rf "$DEST" 2>/dev/null && /usr/bin/ditto "$TMP/DeskHub.app" "$DEST" 2>/dev/null; then :; else
  mkdir -p ~/Applications; DEST=~/Applications/DeskHub.app; rm -rf "$DEST"; /usr/bin/ditto "$TMP/DeskHub.app" "$DEST" || { echo "   설치 위치에 쓸 수 없습니다."; exit 1; }
  echo "   /Applications 에 권한이 없어 ~/Applications 에 설치했습니다."
fi
rm -rf "$TMP"
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null || echo ?)"
ARCH="$(uname -m)"; echo "   설치됨: $DEST (버전 $VER, 이 맥 $ARCH)"

say "4/6 설정 파일"
ENVF="$HOME/.claude/csnl-report/.env"; mkdir -p "$(dirname "$ENVF")"; touch "$ENVF"; chmod 600 "$ENVF"
has() { grep -q "^$1=" "$ENVF"; }
if ! has NOTION_TOKEN; then
  # 공용 저장소의 공용 열쇠 파일이 읽히면 그것을 쓴다(랩장 10-16 20:51: NAS _ssot 의 토큰은 연구실 누구나 접근 가능)
  if [ -z "$TOK" ] && [ -r "$NAS/Grant/_ssot/credentials/tokens.env" ]; then TOK="$(grep '^NOTION_TOKEN=' "$NAS/Grant/_ssot/credentials/tokens.env" | head -1 | cut -d= -f2-)"; [ -n "$TOK" ] && echo "   공용 저장소의 연결 열쇠를 사용합니다."; fi
  if [ -z "$TOK" ]; then printf "   Notion 연결 열쇠를 붙여넣고 엔터(글자는 보이지 않습니다): "; read -rs TOK; echo; fi
  if [ -n "$TOK" ]; then printf 'NOTION_TOKEN=%s\n' "$TOK" >> "$ENVF"; echo "   연결 열쇠 저장"; else echo "   연결 열쇠가 없어 Notion 카드는 비어 보입니다(나중에 setup_env.sh 로 추가 가능)."; fi
else echo "   연결 열쇠는 이미 있습니다."; fi
has NAS_ROOT || printf 'NAS_ROOT=%s\n' "$NAS" >> "$ENVF"
has MY_INIT || printf 'MY_INIT=%s\n' "$INIT" >> "$ENVF"
echo "   이니셜: $(grep '^MY_INIT=' "$ENVF" | cut -d= -f2)"

say "5/6 기본 화면 = 랩 허브, 로그인 시 자동 실행"
/usr/bin/defaults write kr.ac.snu.csnl.deskhub DeskHub.viewMode hub 2>/dev/null || true
osascript -e 'try' -e "tell application \"System Events\" to if not (exists login item \"DeskHub\") then make login item at end with properties {path:\"$DEST\", hidden:false}" -e 'end try' >/dev/null 2>&1 && echo "   로그인 항목 등록" || echo "   로그인 항목 등록은 건너뜀(시스템 설정 → 일반 → 로그인 항목에서 추가 가능)"

say "6/6 실행"
/usr/bin/open "$DEST" 2>/dev/null || nohup "$DEST/Contents/MacOS/DeskHub" >/dev/null 2>&1 &
sleep 3
pgrep -x DeskHub >/dev/null && echo "   DeskHub 가 켜졌습니다. 30초쯤 뒤 바탕화면에 현황판이 채워집니다. 잠시 치우려면 컨트롤·옵션·D." || echo "   켜지지 않았습니다. 터미널 출력 그대로 박준오에게 보내 주세요."
echo
echo "끝. 처음 뜨는 권한 요청(캘린더·네트워크 볼륨)은 '허용' 해 주세요."
