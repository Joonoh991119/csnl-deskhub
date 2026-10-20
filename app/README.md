# DeskHub — 바탕화면 대시보드 (CSNL MacBook)

> 이 앱은 [csnl-admin](https://github.com/Joonoh991119/csnl-admin) 마켓플레이스의 `plugins/deskhub/app` 에서 관리한다. 데이터 규칙은 `../rules/01_single_rule.md`, 주간 파이프라인은 `../scripts/weekly_pipeline.py` (`/deskhub:weekly`). 예전 단독 저장소 Joonoh991119/DeskHub 는 보관용.

바탕화면 아이콘 바로 위·모든 앱 창 아래 레벨에 불투명 카드를 띄워 "위젯이 곧 배경화면"처럼 보이게 하는 macOS 네이티브 앱.
다른 창이 덮으면 바탕화면 클릭(또는 fn+F11)으로 드러난다. 메뉴막대 ▦ 아이콘으로 제어.

## 위젯 방식 (config v10, 2026-10-13)
바탕화면 전체를 덮던 방식(바닥판)을 기본에서 뺐다. 이제 카드만 **보조 모니터**에 띄우고, 필요할 때 치운다.
- `layout.mode`: `widget`(기본, 바닥판 없음·그림자) | `desktop`(예전처럼 화면 전체를 덮음). 메뉴막대 ▦ → 배치 방식.
- `layout.screen`: `secondary`(기본) | `main` | 모니터 이름 일부. 보조 모니터가 없으면 `layout.whenNoSecondary`=`hide`(기본) 로 **숨긴 채 시작**하고, 모니터를 꽂으면 저절로 그 화면에 뜬다. 메뉴 → 표시할 모니터.
- 치우기: 전역 단축키 `layout.hotkey`(기본 **⌃⌥D**) — 보이면 모두 숨기고, 숨어 있으면 다른 창 위로 꺼낸다. 카드 머리의 눈 아이콘, 메뉴 "모두 숨기기", 터미널 `DeskHub --show | --hide | --toggle` 도 같다. 꺼낸 카드는 메뉴 "바탕화면 층으로 내리기"로 제자리.
- 테마: `theme` = csnl · catppuccin · rosepine · nord · solarized · gruvbox · tokyonight, 0.42.0 부터 + primer · carbon · radix · tokyonight-daynight · catppuccin-frappe · catppuccin-macchiato · everforest (14개), `appearance` = system | light | dark (메뉴 → Theme / Appearance). 테마 이름은 원 출처 영어 이름 그대로(CSNL · Tokyo Night Storm · GitHub Primer · IBM Carbon …). 시험 훅 `DESKHUB_THEME=<id>` 는 시작할 때만 그 테마로 띄우고 config 에 쓰지 않는다. 팔레트 원본·라이선스는 `Resources/theme-sources/`, 색 토큰은 `scripts/build_themes.py` → `Resources/themes.json` (대비: 본문 ≥7, 보조·강조 ≥4.5, 흐린 글자 ≥3 — 0.42.0 부터 미달이면 `build_themes.py` 가 종료 1). 사용자 테마는 `~/Library/Application Support/DeskHub/themes.json`.
- v9 설정은 사용자 값을 새 기본값 위에 합쳐서 옮긴다(바닥판·여백·간격만 새 값).

## 이전 구성 (config v8, 2026-10-12)
| 슬롯 | 폭 | 내용 |
|---|---|---|
| `calendar` 오늘 일정 | 1/3 | 네이티브 하루 타임라인. 10~20시 강조(큰 글씨·밴드), 그 밖 시간은 압축. 현재 시각 선, 종일 일정 칩, 겹침 열 배치. **표시 캘린더는 lab-calendar@example.com 의 "CSNL Calendar"·"SLab Calendar" 만** (`calendar.includeCalendars`, 부분 일치·대소문자 무시) |
| `csnl-hub` CSNL | 2/3 | Notion API 로 직접 읽는 통합 대시보드. 위→아래: **다음 GRM 한 줄**(날짜·D-day·발표자·발표 노트/초록/슬라이드) / **Members 칩**(다음 발표자 네이비, 휴직 outline) / 3열 = **지난 Paper Blitz**(멤버별 제목·"첫저자 et al., 연도, 저널"·DOI) · **리마인더**(NAS reminders.json 에서 컨펌한 것만, 날짜순) + **오늘의 실험**(SLab 예약 — 실험자는 '실험자' relation 이니셜·자원 예약 Running·Prolific 진행·준비 중 study) + 일정 2주(날짜순) · 회의록(제목에서 유형 접두사를 pill 로, 결정이 있으면 결정 우선) / 하단 = **최신 원고**(OpenAlex, `manuscriptAuthors`) · 다가오는 학회 · 논문 추천. (0.40.0: '논문 진행'(Publications Stage·Deadline) 섹션과 Schedule `우선도` 정렬은 없다 — 값이 늘 비어 있어 뺐다) 색은 네이비·녹색·적색 세 가지(적색은 D-3 이내·마감·오류에만). 탭 `Members`·`CSNL GRM`·`CSNL` 은 카드 안 웹뷰 |

예비 위젯(코드만 있음, 슬롯에 `type` 으로 추가하면 생김): `notion`(단일 페이지 웹뷰), `web`(아무 URL), `nas`(NAS 탐색기), `plaud`, `claude`.

### 캘린더 데이터 소스 (둘 중 하나, 최초 1회)
1. **EventKit** — 시스템 설정 > 인터넷 계정 > Google 에 lab-calendar@example.com 추가하고 '캘린더' 켜기 → 1~2분 뒤 자동 표시 (권한 창 '허용'). 이름 필터로 두 캘린더만 남김.
2. **ICS** — Google Calendar 설정 > 각 캘린더 > "iCal 형식의 비공개 주소" 를 `calendar.icsURLs` 에 넣기. RRULE(DAILY/WEEKLY/MONTHLY/YEARLY, INTERVAL/COUNT/UNTIL/BYDAY/BYMONTHDAY), EXDATE, RECURRENCE-ID 지원.
소스가 없으면 안내 오버레이가 뜬다. `calendar.mode` = `native`(기본) | `auto`(소스 없으면 Google 웹) | `web`.

### Notion 허브 데이터
토큰은 `notionHub.tokenEnvFile` (기본 `~/.claude/csnl-report/.env`) 의 `NOTION_TOKEN`. DB/페이지 ID 는 `notionHub.*` 에 있음
(Members 54e8d7dd…, GRM 발표 순번 2ffeb59a…, Presentations 23cd1c0d…, Schedule & Events 2fe2a38e…, CWLL Links 32c2a38e…, GRM Meeting Notes 669d4d56…, Conferences 3f72a38e…81f6, CSNL GRM 페이지 3022a38e…, CSNL 페이지 2df2a38e…). 10분마다 갱신.
- `notionHub.display`: `showEmail`(발표자 이메일, 기본 꺼짐·툴팁에는 있음), `showWeekday`(날짜 옆 요일, 기본 꺼짐), `showMemberInitials`, `hideEventTypes`(기본 `["GRM"]`).
- `notionHub.conferencesDB`: 비우면 "다가오는 학회" 를 빈 자리로 둔다. DB 조회 실패(공유 안 됨 등)는 다른 섹션에 영향 없이 빈 상태.
- **지난 Paper Blitz** 데이터: `notionHub.paperBlitzDB` 가 비어 있으면(기본) NAS `GRM/<yyyy>/<yyyymmdd>/PB_yymmdd.pptx` 를 `unzip -p` 로 읽어 제목 슬라이드(제목 / 저자·연도·저널 / "Core question" / "Initial" + 이니셜)를 파싱한다. DOI 는 Crossref(`api.crossref.org/works?query.bibliographic=`)로 찾아 `doi-cache.json` 에 저장, 못 찾으면 Google Scholar 검색 링크. 이니셜 별칭은 `initialsAliases`(SK→SJK, RJH→JHR). 아카이브 DB(JYK 파이프라인)가 생기면 ID 를 넣는다 — 기대 스키마: Title(title)·Presenter(select 이니셜)·Date·DOI(url)·Authors·Year(number)·Journal·Core question·Takeaway·Source·Session·Status.
  - 첫 실행 때 macOS 가 "DeskHub 이(가) 네트워크 볼륨의 파일에 접근하려고 합니다" 를 묻는다 → **허용**. 거부하면 이 칸은 "NAS 에서 읽는 중…" 에 머문다(시스템 설정 > 개인정보 보호 > 파일 및 폴더 > DeskHub > 네트워크 볼륨).
- **다가오는 일정·리마인더**: Schedule & Events 는 일정이지 마감이 아니다(랩장 2026-10-14). 일정은 날짜순으로만 보이고(`우선도` 는 0.40.0 에서 읽지 않음), 리마인더는 NAS `Grant/_ssot/reminders.json` 에서 컨펌한 것만 — 제안은 제목에 제출·방문 등이 있는 다가오는 일정·그랜트·학회 마감. `checklistTypes` 설정 키는 남아 있지만 쓰지 않는다.
- **미팅 후속 체크리스트**(0.41.0, R1): NAS `<grantsFile 폴더>/followups/` 의 파일 두 종류 — `proposals.json`(제안, `../scripts/meeting_followups.py` 만 씀 · 앱은 읽기만)과 `state-<이니셜>.json`(그 이니셜의 앱만 씀: 확정·끝남·아님 + 직접 적은 MM 항목 `fu-self-`). 스크립트는 세션 사이클이 하루 1회 부른다(`python3 -I ../scripts/meeting_followups.py`, LaunchAgent 없음 — aggregate_daily.py 와 같은 방식). Meeting Notes(Type GRM·Focus, 최근 60일)의 녹취 JSON `plaud_notes` 와 Key Decisions, NAS MM 최근 pptx 2개의 계획·피드백 제목 슬라이드에서 규칙으로 뽑고(발표자 노트는 열지 않음), 개인정보 꼴은 버리고 멤버 이름은 이니셜로 바꾼다. 보기 규칙: 확인한 이니셜 = 담당 → 내용·쓰기, 교수님(`FollowupLogic.supervisors` = SL) → 읽기만, 그 밖 → 수만(관제탑 레일·Members 전광판·상태 한 줄은 늘 수만). 폴더·proposals 를 못 읽으면 '?' 와 단추 잠김, 그 사람 상태 파일만 깨졌으면 그 사람만 '?'. 폴더가 없으면 만들지 않는다. 시험 훅 `DESKHUB_FOLLOWUPS=<폴더>`(fixture `fixtures/followups` 를 복사해 씀).
- **Courses · Classes 카드 · Timetable 화면**(0.42.0, R1): Notion 🎓 Courses 를 읽기만 한다. DB id 는 Config 키가 아니라 코드 상수 `Timetable.coursesDB`(`b86b2c5e-1c58-4597-a031-dc53fd03fc05`), 시험 훅 `DESKHUB_COURSES_DB=<id>`, 오프라인 훅 `DESKHUB_COURSES=<json>`(정규화 행 배열 — `fixtures/courses/` — 을 그대로 읽고 Notion 을 부르지 않음). 질의는 `학기` = 지금 학기 filter, 학기 안일 때만, 6시간 캐시(갱신마다 부르지 않음). 읽는 칸: 과목명·학기·상태·구분·수업시간·강의실·이니셜·본인확인(담당교수·과목번호·출처는 읽지 않음). 버리는 행: 상태 '드랍', 과목명·이니셜·수업시간 중 빈 칸, 수업시간 파싱 실패(개수만 '못 읽은 행'). 파싱은 timetable 플러그인 `tt.py` 규칙(요일 묶음 '화목', `h-h`·`HH:mm-HH:mm`, 1~7시는 오후, 끝 괄호 = 강의실). 이니셜 별칭은 `initialsAliases`. 학기 날짜·휴일은 번들 `Resources/semesters.json`(timetable `config/semesters.json` 사본) + 사용자 파일 `~/Library/Application Support/DeskHub/semesters.json`(같은 id 면 사용자 값 — 다음 학기는 여기에 더한다). 오늘이 [start, makeup_end] 밖이면 Classes 카드는 '학기 밖' 한 줄, 휴일이면 그날 수업 없음. 화면: `--view timetable`(숫자 키 9, 기존 뷰 뒤에 붙임), 'Filter by person' 칩, 내 수업은 왼쪽 `Hub.ink` 막대 + 2pt 테두리(0.43.1, 바탕 채움 없음 · 사람별 색 없음 — 범주색 토큰이 없어서). 덤프 text.txt `[Timetable]`, text-check `fixtures/timetable-check.tsv`(tt-slots·tt-sem·tt-today).
- **멤버 상태 아이콘**(0.42.0, R2): `MemberStatus.resolve` 한 곳에서 갱신·1분마다 계산하고 Members 카드·MemberGroup·Tower roster·Members 탭이 같은 값을 읽는다. 입력 = 오늘 캘린더 일정(CSNL·SLab) · Notion Schedule & Events · SLab 오늘 행 · 오늘 수업 슬롯 · `member_links.json` away 라벨(같은 일정은 `eventKey` 로 한 번). 사람 붙이기는 이름→이니셜로 바꾼 제목을 토큰으로 나눠 **이니셜 토큰이 정확히 같을 때만**(BHL ≠ BYL). 우선순위(겹치면 위의 것): **away**(오늘을 덮는 종일 일정 + 키워드 `휴가·연차·반차·병가·출장·학회·파견·워크숍·workshop·vacation·leave·conference`, 또는 away 라벨) > **meeting**(시각 일정 + `Meeting`·`미팅`·`MM`·`GRM`, 끝 시각 없는 Notion 'Meeting: XX' 는 시작 + 60분 가정, 이니셜 없는 GRM 시각 일정은 활성 멤버 전원) > **experiment**(SLab 확정 행, 실험자 = 그 사람, 'HH:mm - HH:mm' 안) > **class**(수업 슬롯 안). 끝 시각은 경계 밖(`now == end` 면 아님). 아이콘 airplane · person.2 · flask · book.closed, 색 `Hub.text2`(내 것 `Hub.ink`) — 적색 없음, 알림 없음. 피험자·참여자 칸은 읽지 않는다. 시험 훅 `DESKHUB_STATUS_FIXTURE=<json>`(입력을 통째로 바꿈, `fixtures/status/`), 덤프 `[멤버 상태]`·`[Members 카드]`, text-check `fixtures/status-check.tsv`(mstatus). Members 카드의 Activity log · Claude usage 칸은 출처가 정해질 때까지 '준비 중'.
- **Joint projects**(0.42.0, R9-d): 공동연구 자리 — 지금은 연구실 플러그인 버전·담당·리뷰 완료/대기. `../scripts/plugin_status.py` 가 담당자 표 `Resources/plugin-owners.json` 과 GitHub(`gh api`: 기본 브랜치 `.claude-plugin/marketplace.json` 버전 · 라운드 이슈 `since` 이후 댓글 · 열린 PR 리뷰)을 합쳐 NAS `<grantsFile 폴더>/plugins/plugin_status.json` 에 쓰고, 앱은 그 파일을 읽기만 한다(시험 훅 `DESKHUB_PLUGINS=<파일>`, 못 읽으면 카드만 한 줄). 세션 사이클이 하루 1회 부른다(`python3 -I ../scripts/plugin_status.py`, LaunchAgent 없음 — aggregate_daily.py 와 같은 방식). 미리 보기 `--dry`(stdout 만), 다른 곳에 쓰기 `--out <dir>`, 규칙 검사 `--check ../scripts/fixtures/plugin-status`(품질 게이트 gate_plugins). 토큰은 다루지 않는다(gh 로그인된 맥에서만 돈다).
  - **owners 고치는 법**: `plugin-owners.json` 의 `plugins[]` 한 줄 = `id`(카드 이름) · `repo` · `plugin`(marketplace 의 이름) · `owner`(담당 이니셜) · `reviewers`(리뷰 대상 이니셜) · `round`(`issue` 번호 · `since` 날짜 — 이 날짜 이후 댓글만 '완료') · `pr_prefix`(브랜치 접두) · `manual`(`version`·`done`·`waiting` — 비어 있지 않으면 GitHub 값 대신 이것만) · `note`. `logins` 는 GitHub 로그인 → 이니셜 표(비어 있으면 그 사람 댓글을 못 풀어 '대기' 로 남음). DM·메일로 받은 답을 랩장이 이슈에 옮길 때 댓글에 `BHL 옮김` 처럼 쓰면(`relay` 정규식) 그 사람이 '완료' 가 된다. 담당자는 완료·대기에서 빠진다. 고친 뒤 다음 하루 1회 실행(또는 직접 실행)에서 반영.
- **0.43.0 변경 요약** (계획 `../docs/plan-0.43.0-2026-10-20.md`, SMJ 10-19 리뷰 #44–#51 — 줄 끝 C 번호의 커밋이 없으면 그 줄은 지운다)
  - 지난 마감(0.43.0 C1, #46): `HubAlert.overdue` = 마감 날이 어제 이전(달력 날짜, 결정 D-1). `AlertEngine.order` 한 곳에서 등급 안 맨 뒤 · 상한 밖으로 두고 팝오버 '할 것'(`PopoverTodo.split`)은 맨 아래 '지난 마감 n건' 한 줄로 접는다(관제탑은 같은 순서 그대로). 안내판·상태 한 줄·8주 띠는 지금처럼 오늘 이후만, 안내판 '지남' 은 리마인더·그랜트·학회 마감 행 모두. fixture `fixtures/todo-check.tsv`(kind `todo`).
  - Members 탭(0.43.0 C2, #44 #45): 열은 `MembersBoardRow.Column` 표 한 곳(머리·행 폭·덤프 '열:' 공용) — 'Paper reactions' → 'Reactions'(머리 칩 '실제'), 예시 'Claude usage'. 표 아래 상태 아이콘 범례 한 줄, 이니셜 앞 아이콘 칸 폭 고정. 머리 잘림 실측 판정 kind `mb-head`(`fixtures/members-check.tsv`, 1.0·1.3·1.6).
  - 시간표(0.43.0 C3, #47 #48): `Timetable.prepare` 한 곳 — 조교(`구분` = 조교) 행 제외(청강은 유지), 같은 학기·정규화 과목명·요일이 겹치는 행은 대표 슬롯으로 합치고 차이는 `note`('입력 시간 다름', 도움말에만). Classes 카드·Timetable·멤버 상태 '수업 중'·Metrics 가 같은 결과를 읽는다. kind `tt-merge`, fixture `fixtures/courses/courses-merge.json`.
  - 연구 탭 태그(0.43.0 C4, #49): `Resources/research-topics.json` 의 `title` 영어·`slot`(id 그대로), 칩 색 `Hub.tag(slot)`(테마 토큰에서 계산, 적색 계열 없음, 대비 ≥ 4.5), 'Filter'(여러 개 OR) — 이 맥 `DeskHub.feedTags` 에 저장. 키 `--key feedtags:<id,id>`(빈 값 = 지움) · `--key feedfilter`. fixture `fixtures/research-check.tsv`(kind `topiclabel`·`tagcolor`·`feedtags`).
  - CSNL GRM 탭(0.43.0 C5, #50): `GRMOrderView` 가 `ViewThatFits` 로 두 열(일정 왼쪽 · 로테이션 오른쪽, 제목 같은 높이)과 한 열(일정 위)을 고르고 windows.txt `choices:` 에 `grm-tab`(위젯 탭)·`grm-week`(GRM 주간 뷰) `2열|1열` 을 남긴다. 날짜·D-day 칸 폭은 `Hub.s()` 배율. 로테이션 행 계산(`GRMRotation.rows`)은 그대로.
  - 창(0.43.0 C7, #51): 제목 막대 더블클릭은 시스템 `AppleActionOnDoubleClick`(옛 `AppleMiniaturizeOnDoubleClick`)을 따라 확대 · 내리기 · 없음, 꺼낸 상태에서만 왼쪽 위 무채색 단추(닫기 = 모두 숨기기 · − = 바탕화면 층 · ⤢ = 확대). 확대 중에는 슬롯 비율을 저장하지 않고 화면 바뀜·숨기기 때 먼저 푼다. 훅 `DESKHUB_DBLCLICK=<값>`, 키 `--key window:zoom|lower|close|dblclick[:<slot>]` · `--key hotkey` · `--key peek`, windows.txt `window:` 줄, fixture `fixtures/window-check.tsv`(kind `dblclick`).
  - 리뷰 회수(0.43.0 C6, R9): `../scripts/review_poll.py` 가 #21 댓글만 보던 것을 'deskhub-review' 라벨 · 제목 '[DeskHub]' 이슈 + #21 의 새 이슈 · 새/고친 댓글(`(수정)`) · 닫힘으로 넓혔다(읽기만 — `gh issue list`·`gh api` GET). 상태 키 `known_issues`·`issue_state`·`comment_seen`, 옵션 `--check <dir>`(네트워크 없음, `../scripts/fixtures/review-poll/cases.json`, 품질 게이트 `gate_reviewpoll`) · `--only gh` · `--state <사본>`. 작성자는 이니셜(saemi-bot → SMJ, bolee0755 → BYL — BHL ≠ BYL), 랩장 계정 글은 뺀다. 같은 로그인 두 개를 `Resources/plugin-owners.json` `logins` 에도 더했다(결정 D-10).
- **0.43.1**(계획 `../docs/feedback-1020-1830-plan.md`, SMJ 10-20 #53): 내 수업 = `Timetable.meKey(HubPrefs.me, initialsAliases)` 가 덩어리 이니셜에 있음(병합 인원 포함·조교 제외) — 격자 칸 왼쪽 3pt `Hub.ink` 막대 + 2pt 테두리, Classes 행 2pt 막대·이니셜 ink, 바탕 채움 없음(토큰이 surface 위 대비 하한에 맞춰져 있어서). 덤프 `[Timetable]` '나 · 내 수업 n'·'★'·'내 수업:' 줄, windows.txt `choices` `tt-mine:`·`classes-mine:`, text-check `tt-today`/`tt-merge` 선택 키 `me=` · 새 kind `tt-mine`.
- **글꼴(Font)**(0.42.0, R4): `Resources/Fonts/` 에 OFL 1.1 글꼴 셋(Pretendard 1.3.9 static OTF 4굵기 · IBM Plex Sans KR OTF 4굵기 · SUIT 2.0.5 Variable TTF)과 `licenses/`·`README.md`(파일·버전·출처·sha256). 등록은 Info.plist `ATSApplicationFontsPath = Fonts`(코드 등록 없음), build.sh 가 폴더를 복사. 고르기 = Display 판의 Font 줄(System · Pretendard · IBM Plex Sans KR · SUIT), `--key font:<system|pretendard|plex|suit>`, 이 맥 `DeskHub.fontFamily`, 시험 훅 `DESKHUB_FONT=<id>`. **기본은 System**(지금과 같음). 글꼴을 찾지 못하면 System 으로 대체하고 windows.txt 에 `font: system (대체)`.
- **회의록 최신화·상태 닫기·Paper Blitz 아카이브**: `../scripts/weekly_pipeline.py`(`/deskhub:weekly`). `paperBlitzDB` 가 비어 있으면 `~/.claude/csnl-report/notion_dbs.json` 의 "Paper Blitz Archive" 를 읽고, 그것도 없으면 NAS pptx 를 직접 파싱한다.
- **오늘의 실험**: `slabDB`(SLab 예약, 실험날짜 = 오늘, 취소 제외 — 실험자 = '실험자' relation → Project People 제목 이니셜, 멤버가 아니면 '외부', 비면 '실험자 미확인'. 줄 제목 = '프로젝트' 칸 · n회차, 둘째 줄 = 시간 — 실험명(제목 칸)에 피험자 이름·ID 가 들어 있어 쓰지 않는다. 피험자 이름·ID 는 읽지 않는다, 0.40.0 F0-1·검증 1) · `resourceDB`(자원 예약 Status=Running, 오늘 포함) · Prolific(`prolific.*`: 토큰은 `.env` 의 `PROLIFIC_API_TOKEN` 또는 `~/.config/prolific/credentials.json`, 진행(ACTIVE)·준비(UNPUBLISHED) 중만, 전체 목록 조회가 30초라 30분에 한 번). 시험 훅 `DESKHUB_SLAB_SIM=all` = SLab 날짜 조건 없이 전 페이지(시험 전용, 카드가 넘침).
- **최신 원고**: OpenAlex 에서 `manuscriptAuthors`(이니셜 → 저자 id)의 최근 `manuscriptLookbackDays` 일 프리프린트·논문. Publications DB 의 `Stage`·`Deadline` 질의는 0.40.0 에서 뺐다(채움 0/13 — 늘 빈 목록과 상시 안내문만 남겼음). 설정 키(`publicationsDB`·`manuscript*`·`resourcesDB`)는 Config 에 남아 있지만 읽지 않는다 — Publications 열기 링크만 `publicationsDB` 를 쓴다.
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
- 미팅 후속 시험 키(0.41.0): `DESKHUB_FOLLOWUPS=<scratch 폴더>` 일 때만 `--key fu-done:<id 앞>`·`fu-dismiss:<id 앞>`(6초 미룸)·`fu-confirm:<id 앞>`(즉시)·`fu-undo`·`fu-add:<종류>|<글>` 이 동작한다(훅이 없으면 삐 — NAS 원본에 쓰지 않게). `--key fu-ack` = 상태 한 줄 칩 '그날 확인'(이 맥 `DeskHub.fuAck` 만, 훅 불필요). 덤프 text.txt `[미팅 후속]`, text-check `fixtures/followup-check.tsv`(fu-status·fu-visible·fu-count·fu-remind·fu-mm·fu-choices)·`fixtures/grmweek-check.tsv`. 추출 규칙은 `python3 -I ../scripts/meeting_followups.py --text-check ../scripts/fixtures/followup-check.tsv`(품질 게이트 gate_followups).
- 0.42.0 시험 훅·키 요약: 훅 `DESKHUB_COURSES`·`DESKHUB_COURSES_DB`(Courses) · `DESKHUB_STATUS_FIXTURE`(멤버 상태) · `DESKHUB_PLUGINS`(Joint projects) · `DESKHUB_THEME`(테마, 시작할 때만) · `DESKHUB_FONT`(글꼴). 키 `--key font:<id>` · `--key expand:equipment`(Equipment 카드 펼침/접힘 — 기본 접힘) · `--key expand:members`(Members 카드 '더 보기') — 펼침은 이 맥 `DeskHub.hubExpanded` 에 남으니 시험 뒤 같은 키로 닫는다. 뷰 `--view timetable`. 카드 제목은 `CardTitles.swift` 한 표(id → 영어 제목 · 도움말), 덤프 `[카드 제목]`.
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
