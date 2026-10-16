#!/bin/zsh
# DeskHub 연결 설정 — 토큰을 물어 ~/.claude/csnl-report/.env 를 만들고 앱을 다시 켠다.
#   사용: zsh /Volumes/CSNL_new/Grant/_ssot/deskhub/setup_env.sh <이니셜>     예) … setup_env.sh SYJ
#   토큰은 화면에 보이지 않게 입력받고(read -s) 파일에만 쓴다. 이미 있는 키는 덮어쓰지 않는다.
set -e
INIT="${1:?이니셜을 적어 주세요. 예) zsh setup_env.sh SYJ}"
INIT="${INIT:u}"
ENVF="$HOME/.claude/csnl-report/.env"
mkdir -p "$(dirname "$ENVF")"; touch "$ENVF"; chmod 600 "$ENVF"
has() { grep -q "^$1=" "$ENVF"; }
if has NOTION_TOKEN; then echo "Notion 토큰은 이미 있습니다 (그대로 둠)."; else
  printf "랩장께 받은 Notion 토큰을 붙여넣고 엔터 (글자는 보이지 않습니다): "; read -rs TOK; echo
  [ -n "$TOK" ] || { echo "토큰이 비어 있어 중단합니다."; exit 1; }
  printf 'NOTION_TOKEN=%s\n' "$TOK" >> "$ENVF"; echo "Notion 토큰 저장."
fi
has NAS_ROOT || { printf 'NAS_ROOT=%s\n' "/Volumes/CSNL_new" >> "$ENVF"; echo "NAS 경로 저장."; }
if has MY_INIT; then echo "이니셜은 이미 있습니다: $(grep '^MY_INIT=' "$ENVF" | cut -d= -f2)"; else printf 'MY_INIT=%s\n' "$INIT" >> "$ENVF"; echo "이니셜 저장: $INIT"; fi
if [ -d /Applications/DeskHub.app ]; then
  pkill -x DeskHub 2>/dev/null || true; sleep 1
  nohup /Applications/DeskHub.app/Contents/MacOS/DeskHub > "$HOME/.claude/csnl-report/deskhub-app.log" 2>&1 &
  echo "DeskHub 를 다시 켰습니다. 30초쯤 뒤 일정·GRM·논문 카드가 채워지면 끝입니다."
else
  echo "DeskHub 가 아직 설치되지 않았습니다: zsh /Volumes/CSNL_new/Grant/_ssot/deskhub/update.sh"
fi
