# DeskHub — 바탕화면 대시보드 (CSNL MacBook)

> 이 앱은 [csnl-admin](https://github.com/Joonoh991119/csnl-admin) 마켓플레이스의 `plugins/deskhub/app` 에서 관리한다. 데이터 규칙은 `../rules/01_single_rule.md`, 주간 파이프라인은 `../scripts/weekly_pipeline.py` (`/deskhub:weekly`). 예전 단독 저장소 Joonoh991119/DeskHub 는 보관용.

바탕화면 아이콘 바로 위·모든 앱 창 아래 레벨에 불투명 카드를 띄워 "위젯이 곧 배경화면"처럼 보이게 하는 macOS 네이티브 앱.
다른 창이 덮으면 바탕화면 클릭(또는 fn+F11)으로 드러난다. 메뉴막대 ▦ 아이콘으로 제어.

## 위젯 방식 (config v10, 2026-10-13)
바탕화면 전체를 덮던 방식(바닥판)을 기본에서 뺐다. 이제 카드만 **보조 모니터**에 띄우고, 필요할 때 치운다.
- `layout.mode`: `widget`(기본, 바닥판 없음·그림자) | `desktop`(예전처럼 화면 전체를 덮음). 메뉴막대 ▦ → 배치 방식.
- `layout.screen`: `secondary`(기본) | `main` | 모니터 이름 일부. 보조 모니터가 없으면 `layout.whenNoSecondary`=`hide`(기본) 로 **숨긴 채 시작**하고, 모니터를 꽂으면 저절로 그 화면에 뜬다. 메뉴 → 표시할 모니터.
- 치우기: 전역 단축키 `layout.hotkey`(기본 **⌃⌥D**) — 보이면 모두 숨기고, 숨어 있으면 다른 창 위로 꺼낸다. 카드 머리의 눈 아이콘, 메뉴 "모두 숨기기", 터미널 `DeskHub --show | --hide | --toggle` 도 같다. 꺼낸 카드는 메뉴 "바탕화면 층으로 내리기"로 제자리.
- 테마: `theme` = csnl · catppuccin · rosepine · nord · solarized · gruvbox · tokyonight, `appearance` = system | light | dark (메뉴 → 테마 / 외형). 팔레트 원본·라이선스는 `Resources/theme-sources/`, 색 토큰은 `scripts/build_themes.py` → `Resources/themes.json` (대비: 본문 ≥7, 보조·강조 ≥4.5, 흐린 글자 ≥3). 사용자 테마는 `~/Library/Application Support/DeskHub/themes.json`.
- v9 설정은 사용자 값을 새 기본값 위에 합쳐서 옮긴다(바닥판·여백·간격만 새 값).

## 이전 구성 (config v8, 2026-10-12)
| 슬롯 | 폭 | 내용 |
|---|---|---|
| `calendar` 오늘 일정 | 1/3 | 네이티브 하루 타임라인. 10~20시 강조(큰 글씨·밴드), 그 밖 시간은 압축. 현재 시각 선, 종일 일정 칩, 겹침 열 배치. **표시 캘린더는 lab-calendar@example.com 의 "CSNL Calendar"·"SLab Calendar" 만** (`calendar.includeCalendars`, 부분 일치·대소문자 무시) |
| `csnl-hub` CSNL | 2/3 | Notion API 로 직접 읽는 통합 대시보드. 위→아래: **다음 GRM 한 줄**(날짜·D-day·발표자·발표 노트/초록/슬라이드) / **Members 칩**(다음 발표자 네이비, 휴직 outline) / 3열 = **지난 Paper Blitz**(멤버별 제목·"첫저자 et al., 연도, 저널"·DOI) · **할 일**(Schedule 의 마감 Type, 우선도·마감 순, ○ → 완료) + **오늘의 실험**(SLab 예약·자원 예약 Running·Prolific 활성 study) + 일정 2주 4행 + GRM 자료 · 회의록(제목에서 유형 접두사를 pill 로, 결정이 있으면 결정 우선) / 하단 = **논문 진행**(Publications 의 Stage·Deadline·저널·저자 이니셜) · 다가오는 학회 · 논문 추천. 색은 네이비·녹색·적색 세 가지(적색은 D-3 이내·마감·오류에만). 탭 `Members`·`CSNL GRM`·`CSNL` 은 카드 안 웹뷰 |

예비 위젯(코드만 있음, 슬롯에 `type` 으로 추가하면 생김): `notion`(단일 페이지 웹뷰), `web`(아무 URL), `nas`(NAS 탐색기), `plaud`, `claude`.

### 캘린더 데이터 소스 (둘 중 하나, 최초 1회)
1. **EventKit** — 시스템 설정 > 인터넷 계정 > Google 에 lab-calendar@example.com 추가하고 '캘린더' 켜기 → 1~2분 뒤 자동 표시 (권한 창 '허용'). 이름 필터로 두 캘린더만 남김.
2. **ICS** — Google Calendar 설정 > 각 캘린더 > "iCal 형식의 비공개 주소" 를 `calendar.icsURLs` 에 넣기. RRULE(DAILY/WEEKLY/MONTHLY/YEARLY, INTERVAL/COUNT/UNTIL/BYDAY/BYMONTHDAY), EXDATE, RECURRENCE-ID 지원.
소스가 없으면 안내 오버레이가 뜬다. `calendar.mode` = `native`(기본) | `auto`(소스 없으면 Google 웹) | `web`.

### Notion 허브 데이터
토큰은 `notionHub.tokenEnvFile` (기본 `~/.claude/csnl-report/.env`) 의 `NOTION_TOKEN`. DB/페이지 ID 는 `notionHub.*` 에 있음
(Members 54e8d7dd…, GRM 발표 순번 2ffeb59a…, Presentations 23cd1c0d…, Schedule & Events 2fe2a38e…, GRM Resources 7b80d2f7…, CWLL Links 32c2a38e…, GRM Meeting Notes 669d4d56…, Conferences 3f72a38e…81f6, CSNL GRM 페이지 3022a38e…, CSNL 페이지 2df2a38e…). 10분마다 갱신.
- `notionHub.display`: `showEmail`(발표자 이메일, 기본 꺼짐·툴팁에는 있음), `showWeekday`(날짜 옆 요일, 기본 꺼짐), `showMemberInitials`, `hideEventTypes`(기본 `["GRM"]`).
- `notionHub.conferencesDB`: 비우면 "다가오는 학회" 를 빈 자리로 둔다. DB 조회 실패(공유 안 됨 등)는 다른 섹션에 영향 없이 빈 상태.
- **지난 Paper Blitz** 데이터: `notionHub.paperBlitzDB` 가 비어 있으면(기본) NAS `GRM/<yyyy>/<yyyymmdd>/PB_yymmdd.pptx` 를 `unzip -p` 로 읽어 제목 슬라이드(제목 / 저자·연도·저널 / "Core question" / "Initial" + 이니셜)를 파싱한다. DOI 는 Crossref(`api.crossref.org/works?query.bibliographic=`)로 찾아 `doi-cache.json` 에 저장, 못 찾으면 Google Scholar 검색 링크. 이니셜 별칭은 `initialsAliases`(SK→SJK, RJH→JHR). 아카이브 DB(JYK 파이프라인)가 생기면 ID 를 넣는다 — 기대 스키마: Title(title)·Presenter(select 이니셜)·Date·DOI(url)·Authors·Year(number)·Journal·Core question·Takeaway·Source·Session·Status.
  - 첫 실행 때 macOS 가 "DeskHub 이(가) 네트워크 볼륨의 파일에 접근하려고 합니다" 를 묻는다 → **허용**. 거부하면 이 칸은 "NAS 에서 읽는 중…" 에 머문다(시스템 설정 > 개인정보 보호 > 파일 및 폴더 > DeskHub > 네트워크 볼륨).
- **할 일 체크리스트**: Schedule & Events DB 에서 `checklistTypes`(Deadline·Milestone·Assignment·Exam·Paper·Experiment) 이고 상태 ≠ 완료, 날짜가 -14일~+`checklistDays` 인 항목. 랭크 = `우선도`(select 높음/중간/낮음 — DB 에 이 속성을 추가하면 반영, 없어도 동작) → 마감 임박 → Type 순. ○ 클릭 시 `PATCH /pages` 로 상태=완료.
- **회의록 최신화·상태 닫기·Paper Blitz 아카이브**: `../scripts/weekly_pipeline.py`(`/deskhub:weekly`). `paperBlitzDB` 가 비어 있으면 `~/.claude/csnl-report/notion_dbs.json` 의 "Paper Blitz Archive" 를 읽고, 그것도 없으면 NAS pptx 를 직접 파싱한다.
- **오늘의 실험**: `slabDB`(SLab 예약, 실험날짜 = 오늘, 취소 제외) · `resourceDB`(자원 예약 Status=Running, 오늘 포함) · Prolific(`prolific.*`: 토큰은 `.env` 의 `PROLIFIC_API_TOKEN` 또는 `~/.config/prolific/credentials.json`, 상태 ACTIVE/PAUSED/AWAITING REVIEW/SCHEDULED 만, 전체 목록 조회가 30초라 30분에 한 번).
- **논문 진행**: `publicationsDB` 에서 `Stage`(select) 가 `manuscriptStages` 중 하나인 행. `Deadline` 7일 이내·리비전은 적색. 속성 추가는 `../scripts/init_notion_props.py --apply`(Schedule 의 `우선도` 도 함께).
- **색·글자 토큰**: `Hub.ink/ok/signal`, `Hub.text/text2/text3`(대비 ≥ 13.8 / 5.2 / 3.3), `Hub.surface/heroBG/divider/fillNeutral/onAccent`. 캘린더 색도 같은 세 색(첫 캘린더 네이비, 둘째 녹색, 그 외 회색). 설계 근거는 `../docs/design-spec-2026-10-12.md`, UX 점검은 `../docs/ux-review-2026-10-12.md`.
- **진행 프로젝트**(팝오버 '내 것'·멤버 칩 줄, 0.36.0): NAS `Grant/_ssot/member_links.json`(Memory/<이니셜> 폴더, 수정 시각 최신순) 한 소스·같은 이니셜 매칭(이니셜 → `initialsAliases` → 이름). '나' 뷰 '내 진행 프로젝트'와 관제탑 멤버 레일 수는 Notion Projects(상태 In Progress·Review, Lab Chore 제외).
- `notionHub.paperRecDB`: 기본 `3722a38e-4f5f-8076-ba73-f82afa50de3d` = P23(CSNL-vnilab/csnl-paper-rec-v2, 월 09:00 KST) 이 배달하는 현행 "이번 주 논문 추천" DB (Title/저자/Tier/Researcher/DOI/Sent At). 2026-06-01 이후 P23 이 꺼져 새 추천이 없다 — 재가동은 docs/autopilot-2026-10-14.md 결정 4·5·6. 카드는 사람 필터·티어 순(#16).

## 설정 파일
`~/Library/Application Support/DeskHub/config.json` — 수정 후 메뉴 → "설정 다시 읽기".
- `layout`: `insets`, `avoidStageManagerStrip`(Stage Manager 켜져 있으면 왼쪽 176pt 비움), `gutter`, `cornerRadius`, `backdrop`(전체 불투명 바닥판), `opaqueCards`, `slots[]`
- `slots[]`: `{id, type, title, url?, frame{x,y,w,h: 0~1 비율}, visible}` — 드래그/리사이즈하면 비율로 다시 저장됨
- `calendar`, `notionHub`, `web.userAgent`, `nas`, `plaud`, `claude`
- `version` 이 코드의 `Config.currentVersion` 보다 낮으면 `config.vN.bak.json` 으로 백업 후 기본값으로 재생성

## 빌드·실행·검증
```
./build.sh            # swift build → build/DeskHub.app
./build.sh install    # + /Applications/DeskHub.app 교체(기존 프로세스 종료)
open -g -a /Applications/DeskHub.app
/Applications/DeskHub.app/Contents/MacOS/DeskHub --snapshot <dir>   # 각 카드 PNG + windows.txt
```
- 외형 검증: `DESKHUB_APPEARANCE=dark|light|flip` 으로 직접 실행하면 외형을 고정한다(`flip` = 다크로 띄웠다가 20초 뒤 라이트 — 자동 외형 전환 재현). 카드 색은 `AppearanceFillView` 가 외형이 바뀔 때마다 다시 칠한다(`.cgColor` 를 한 번 넣어 두면 그 시점 외형으로 굳는다).
- 툴체인: Command Line Tools (Swift 5.10, macOS 14.4 SDK). Xcode 없음. macOS 26 전용 API 는 런타임 조회(NSGlassEffectView).
- 자동 실행: `~/Library/LaunchAgents/kr.ac.snu.csnl.deskhub.plist` (`open -g -a`), 중복 실행은 main.swift 가 차단.
- 창 레벨: 바닥판 desktopIcon+1, 카드 +2. NSPanel `.nonactivatingPanel`, `canBecomeKey` 는 마우스/키 이벤트일 때만.

## 구조
```
Sources/DeskHub/
  main.swift           진입, --snapshot, 단일 인스턴스
  AppDelegate.swift    슬롯 → 창 생성, 비율 레이아웃, 메뉴막대, LaunchAgent, CalendarHost
  Config.swift         설정 모델(v5)·기본 슬롯·좌표 변환
  WidgetWindow.swift   DesktopPanel(peeking)/BackdropWindow/WidgetWindow, Palette, AppearanceFillView, 드래그·리사이즈
  Theme.swift          테마(themes.json) 로더, 토큰 → 동적 NSColor/Color
  HotKey.swift         전역 단축키 (Carbon, 권한 불필요)
  WidgetChrome.swift   공통 헤더
  CalendarNative.swift CalendarModel(EventKit+ICS), ICSParser, RRule, 타임라인 뷰
  NotionHub.swift      NotionAPI, NotionHubModel, 대시보드 뷰(Hub 팔레트)
  WebWidget.swift      WebController(WKWebView·팝업 로그인·UA·lazy), Notion/Plaud/Claude/Calendar(web)/Generic 웹 위젯
  NASExplorer.swift    NAS 탐색기
Resources/Info.plist, AppIcon.icns, makeicon.swift · backup/ (이전 설정·알림센터 plist)
```

## 시스템 변경 사항 (되돌리기)
- macOS 바탕화면 위젯 표시 끔: `defaults write com.apple.WindowManager StandardHideWidgets/StageManagerHideWidgets -bool false` 로 복원
- 설치한 앱: Notion, Claude 데스크톱 (brew cask)
