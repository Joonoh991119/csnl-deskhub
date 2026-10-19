# DeskHub — CSNL 바탕화면 대시보드 (0.40.0 공개 사본)

연구실 일정·마감·GRM 발표 순번·회의록·Paper Blitz·그랜트·학회 마감을 맥 바탕화면(서브 모니터 배경)에 늘 띄워 두는 macOS 앱입니다. Intel·Apple Silicon 모두 지원합니다.
이 저장소는 연구실 내부 저장소(csnl-admin)의 `plugins/deskhub` 를 0.40.0 시점에 복제한 **임시 공개 사본**입니다. 설치 파일 배포용이며, 개발·이슈는 내부 저장소에서 합니다.

## 설치 (5분)
**A. 연구실 공용 저장소(CSNL_new)가 연결된 맥**
```
zsh /Volumes/CSNL_new/Grant/_ssot/deskhub/update.sh
```
**B. 저장소 없이 (GitHub 에서 받기)**
1. [Releases](../../releases) 에서 `DeskHub-0.40.0.zip` 과 `install_professor.sh` 를 내려받아 **다운로드 폴더**에 둡니다.
2. 터미널(응용 프로그램 → 유틸리티 → 터미널)에 한 줄:
```
zsh ~/Downloads/install_professor.sh <본인 이니셜>
```
   앱 설치 → 설정 파일 → 기본 화면(랩 허브) → 로그인 시 자동 실행 → 실행까지 진행합니다. Notion 연결 열쇠를 물으면 랩장께 받은 값을 붙여넣습니다(공용 저장소가 연결돼 있으면 자동).
3. 처음 뜨는 권한 요청(캘린더·네트워크 볼륨)은 '허용'.

## 사용
- 그냥 봅니다. 잠시 치울 때는 **컨트롤·옵션·D**(윈도우식 키보드는 Alt 가 옵션). 다시 누르면 돌아옵니다.
- 화면 전환: 대시보드를 클릭한 뒤 숫자 **1~4**(1 관제탑 · 2 공정 보드 · 3 안내판 · 4 랩 허브). 기본은 랩 허브.
- 글자 크기·색: 랩 허브 머리의 설정 단추(가가) → 슬라이더·프리셋(기본·고대비·어두움).
- 새 버전: 메뉴 막대 DeskHub 아이콘 오른쪽 클릭 → '새 버전 받기'.
- 자세한 안내: [docs/professor-manual-2026-10-16.html](docs/professor-manual-2026-10-16.html) (브라우저로 열기)

## 실제 자료와 예시
일정·마감·GRM·회의록·Paper Blitz·그랜트·학회는 실제 자료입니다. 연구원별 활동 현황판(Members 탭의 Claude 사용량·GitHub 반영 횟수)과 논문 추천 일부는 **예시**로 표시되어 있습니다.

## 빌드 (개발자)
```
cd app && ./build.sh install      # 이 맥에 설치
cd app && ./build.sh publish      # 범용(arm64+x86_64) zip 생성
```
Swift 5.9+, macOS 13+. 설정은 `~/Library/Application Support/DeskHub/config.json`, 토큰은 `~/.claude/csnl-report/.env` 에만 둡니다(저장소에 없음).
