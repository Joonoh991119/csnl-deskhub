#!/bin/zsh
# DeskHub 품질 게이트 — git pre-commit·수동 실행 공용(세션 훅으로 쓰려면 사람이 .claude/settings.json 에 등록). 빠르게(≤5초).
#   zsh quality_gate.sh pre-bash     # 훅 JSON(stdin, tool_input.command)을 보고 commit/publish 때만 검사. 막을 때 exit 2 + 이유(stderr)
#   zsh quality_gate.sh pre-commit   # git 훅. 실패하면 exit 1
#   zsh quality_gate.sh check        # 수동 실행
set -u
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
APP="$ROOT/plugins/deskhub/app"; BIN="$APP/.build/release/DeskHub"
MODE="${1:-check}"; FAIL=0; MSG=()
say() { MSG+=("$1"); }
gate_textcheck() {
  [ -x "$BIN" ] || { say "text-check 건너뜀(빌드 산출물 없음)"; return; }
  for f in "$APP"/fixtures/*.tsv; do [ -f "$f" ] || continue
    out="$(cd "$APP" && "$BIN" --text-check "$f" 2>&1 | tail -1)"
    case "$out" in *"FAIL 0"*) ;; *) FAIL=1; say "text-check 실패: $(basename "$f") → $out";; esac
  done
}
gate_docs() {
  for f in "$ROOT"/plugins/deskhub/docs/deskhub-guide-*.html "$ROOT"/plugins/deskhub/docs/professor-manual-*.html; do [ -f "$f" ] || continue
    hits="$(grep -oE '\b(Opus|Sonnet|Haiku|Fable|SSOT|UserDefaults|LaunchAgent)\b' "$f" | sort -u | tr '\n' ' ')"
    [ -z "$hits" ] || { FAIL=1; say "안내문 약어·모델명: $(basename "$f") → $hits"; }
  done
}
gate_followups() {
  # 미팅 후속 추출 규칙 (0.41.0 C1) — 앱 빌드와 무관하게 파이썬만. aggregate_daily.py 함수 이름이 바뀌어 import 가 깨져도 여기서 잡힌다
  out="$(/usr/bin/python3 -I "$ROOT/plugins/deskhub/scripts/meeting_followups.py" --text-check "$ROOT/plugins/deskhub/scripts/fixtures/followup-check.tsv" 2>&1 | head -1)"
  case "$out" in *"FAIL 0"*) ;; *) FAIL=1; say "미팅 후속 규칙 실패: $out";; esac
}
gate_plugins() {
  # Joint projects 규칙 (0.42.0 C6) — plugin_status.py 를 미리 받은 응답으로만(네트워크 없음)
  out="$(/usr/bin/python3 -I "$ROOT/plugins/deskhub/scripts/plugin_status.py" --check "$ROOT/plugins/deskhub/scripts/fixtures/plugin-status" 2>&1 | head -1)"
  case "$out" in *"FAIL 0"*) ;; *) FAIL=1; say "플러그인 표 규칙 실패: $out";; esac
}
gate_reviewpoll() {
  # 리뷰 회수 규칙 (0.43.0 C6, R9) — review_poll.py 를 미리 적은 이슈·댓글로만(네트워크·토큰·상태 파일 없음)
  out="$(/usr/bin/python3 -I "$ROOT/plugins/deskhub/scripts/review_poll.py" --check "$ROOT/plugins/deskhub/scripts/fixtures/review-poll" 2>&1 | head -1)"
  case "$out" in *"FAIL 0"*) ;; *) FAIL=1; say "리뷰 회수 규칙 실패: $out";; esac
}
gate_issuereply() {
  # 이슈 답글·닫기 규칙 (10-21 하네스 개선) — issue_reply.py 순수 함수만(네트워크·gh 없음)
  out="$(/usr/bin/python3 -I "$ROOT/plugins/deskhub/scripts/issue_reply.py" --check "$ROOT/plugins/deskhub/scripts/fixtures/issue-reply" 2>&1 | head -1)"
  case "$out" in *"FAIL 0"*) ;; *) FAIL=1; say "이슈 답글 규칙 실패: $out";; esac
}
gate_reviewround() {
  # 리뷰 라운드 규칙 (10-21 하네스 개선) — review_round.py 순수 함수만(파일 쓰기 없음)
  out="$(/usr/bin/python3 -I "$ROOT/plugins/deskhub/scripts/review_round.py" --check "$ROOT/plugins/deskhub/scripts/fixtures/review-round" 2>&1 | head -1)"
  case "$out" in *"FAIL 0"*) ;; *) FAIL=1; say "리뷰 라운드 규칙 실패: $out";; esac
}
gate_weekly() {
  # 주간 정리 규칙 (0.44.0 C1, #61) — 덱 이름(PB_yymmdd, 밑줄 없는 것 경고)·NAS 다시 연결·대기·적용 건너뜀. 가짜 함수만(네트워크·대기·명령 실행 없음)
  out="$(/usr/bin/python3 -I "$ROOT/plugins/deskhub/scripts/weekly_pipeline.py" --self-check 2>&1 | tail -1)"
  case "$out" in *"FAIL 0"*) ;; *) FAIL=1; say "주간 정리 규칙 실패: $out";; esac
}
gate_version() {
  v="$(cat "$ROOT/plugins/deskhub/VERSION" 2>/dev/null)"
  p="$(/usr/bin/plutil -extract version raw -o - "$ROOT/plugins/deskhub/.claude-plugin/plugin.json" 2>/dev/null)"
  m="$(/usr/bin/python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print([x for x in d.get("plugins",[]) if x.get("name")=="deskhub"][0].get("version",""))' "$ROOT/.claude-plugin/marketplace.json" 2>/dev/null)"
  [ "$v" = "$p" ] && [ "$v" = "$m" ] || { FAIL=1; say "버전 불일치: VERSION=$v plugin.json=$p marketplace=$m"; }
}
gate_publish() {
  grep -q -- '--triple x86_64-apple-macosx' "$APP/build.sh" || { FAIL=1; say "build.sh 에 범용(x86_64) 빌드 절차가 없음"; }
  cur="$(/usr/bin/plutil -extract version raw -o - /Volumes/CSNL_new/Grant/_ssot/deskhub/latest.json 2>/dev/null || echo 0)"
  v="$(cat "$ROOT/plugins/deskhub/VERSION")"
  [ "$(printf '%s\n%s\n' "$cur" "$v" | sort -V | tail -1)" = "$v" ] && [ "$cur" != "$v" ] || say "주의: VERSION $v 가 NAS $cur 보다 새롭지 않음(--force 가 아니면 멤버 맥이 못 받음)"
}
case "$MODE" in
  pre-bash)
    cmd="$(/usr/bin/python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("tool_input",{}).get("command",""))
except Exception: print("")' 2>/dev/null)"
    case "$cmd" in
      *"git "*commit*) gate_textcheck; gate_followups; gate_plugins; gate_reviewpoll; gate_issuereply; gate_reviewround; gate_weekly; gate_docs; gate_version ;;
      *build.sh*publish*) gate_textcheck; gate_version; gate_publish ;;
      *) exit 0 ;;
    esac
    if [ "$FAIL" = 1 ]; then printf '품질 게이트 실패 — %s\n' "${(j: · :)MSG}" >&2; exit 2; fi
    [ ${#MSG[@]} -gt 0 ] && printf '품질 게이트: %s\n' "${(j: · :)MSG}"; exit 0 ;;
  pre-commit) gate_textcheck; gate_followups; gate_plugins; gate_reviewpoll; gate_issuereply; gate_reviewround; gate_weekly; gate_docs; gate_version; [ "$FAIL" = 1 ] && { printf '품질 게이트 실패 — %s\n' "${(j: · :)MSG}" >&2; exit 1; }; exit 0 ;;
  *) gate_textcheck; gate_followups; gate_plugins; gate_reviewpoll; gate_issuereply; gate_reviewround; gate_weekly; gate_docs; gate_version; gate_publish; printf '%s\n' "${MSG[@]:-모두 통과}"; exit $FAIL ;;
esac
