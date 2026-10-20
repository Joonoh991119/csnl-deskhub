import AppKit

@MainActor
func runApp() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
let args = CommandLine.arguments
// DeskHub --text-check <tsv> : 화면 글자 규칙(제목·저자·인용·팝오버 클램프)을 fixture 로 검사한다 (0.36.0). 앱을 띄우지 않고 네트워크도 쓰지 않는다.
// 단일 실행 검사보다 앞 — 앱이 떠 있어도 돈다. FAIL 이 있으면 종료 코드 1
if args.count >= 3, args[1] == "--text-check" {
    exit(TextCheck.run(path: args[2]))
}
// DeskHub --show | --hide | --toggle : 실행 중인 앱에 알린다 (단축키와 같은 동작, 다른 런처에서 쓰기 좋게)
if args.count >= 2, ["--show", "--hide", "--toggle"].contains(args[1]) {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("kr.ac.snu.csnl.deskhub." + args[1].dropFirst(2)), object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}
// DeskHub --view hub|today|grm|me|ambient : 첫 탭의 뷰를 바꾼다 (v24 멀티 뷰)
if args.count >= 3, args[1] == "--view" {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("kr.ac.snu.csnl.deskhub.view"), object: args[2], userInfo: nil, deliverImmediately: true)
    exit(0)
}
// DeskHub --dump-alerts <dir> : 실행 중인 앱이 경보 목록을 <dir>/alerts.txt 로 쓴다 (D3)
if args.count >= 2, args[1] == "--dump-alerts" {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("kr.ac.snu.csnl.deskhub.dumpalerts"), object: args.count >= 3 ? args[2] : NSTemporaryDirectory(), userInfo: nil, deliverImmediately: true)
    exit(0)
}
// DeskHub --key <키> : 키 입력 흉내 (스냅샷 검증용, D6) — 예: --key j, --key ?, --key 1
if args.count >= 3, args[1] == "--key" {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("kr.ac.snu.csnl.deskhub.key"), object: args[2], userInfo: nil, deliverImmediately: true)
    exit(0)
}
// DeskHub --dump-pipeline <dir> : 공정 판정 결과를 <dir>/pipeline.txt 로 (D7)
if args.count >= 2, args[1] == "--dump-pipeline" {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("kr.ac.snu.csnl.deskhub.dumppipeline"), object: args.count >= 3 ? args[2] : NSTemporaryDirectory(), userInfo: nil, deliverImmediately: true)
    exit(0)
}
// DeskHub --dump-phase <dir> : 안내판 주인공 국면 표 (D9)
if args.count >= 2, args[1] == "--dump-phase" {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("kr.ac.snu.csnl.deskhub.dumpphase"), object: args.count >= 3 ? args[2] : NSTemporaryDirectory(), userInfo: nil, deliverImmediately: true)
    exit(0)
}
// DeskHub --dump-text <dir> : 화면에 그리는 글자(논문 추천 …)를 <dir>/text.txt 로 (0.36.0)
if args.count >= 2, args[1] == "--dump-text" {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("kr.ac.snu.csnl.deskhub.dumptext"), object: args.count >= 3 ? args[2] : NSTemporaryDirectory(), userInfo: nil, deliverImmediately: true)
    exit(0)
}
// DeskHub --line <dir> : 메뉴 막대 한 줄 L·M·S 를 <dir>/line.txt 로 (D11)
if args.count >= 2, args[1] == "--line" {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("kr.ac.snu.csnl.deskhub.line"), object: args.count >= 3 ? args[2] : NSTemporaryDirectory(), userInfo: nil, deliverImmediately: true)
    exit(0)
}
// DeskHub --usage <dir> : 사용 기록 요약 <dir>/usage.txt (D13, 기록은 기본 꺼짐)
if args.count >= 2, args[1] == "--usage" {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("kr.ac.snu.csnl.deskhub.usage"), object: args.count >= 3 ? args[2] : NSTemporaryDirectory(), userInfo: nil, deliverImmediately: true)
    exit(0)
}
if args.count >= 2, args[1] == "--snapshot" {
    let dir = args.count >= 3 ? args[2] : NSTemporaryDirectory()
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("kr.ac.snu.csnl.deskhub.snapshot"), object: dir, userInfo: nil, deliverImmediately: true)
    exit(0)
}
// 중복 실행 방지 (LaunchAgent + 수동 실행이 겹쳐도 하나만)
let running = NSRunningApplication.runningApplications(withBundleIdentifier: "kr.ac.snu.csnl.deskhub")
if running.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    exit(0)
}
MainActor.assumeIsolated { runApp() }

/// `--text-check` 실행기 (0.36.0). 줄 형식 `종류<TAB>입력<TAB>기대값[<TAB>제목[<TAB>연도]]`, `#` 으로 시작하는 줄과 빈 줄은 건너뛴다.
/// 빈 칸 = 빈 값. 종류: title(Hub.cleanPaperTitle) · authors(Hub.cleanAuthors) · cite(Hub.citationLine — 넷째 칸 제목, 다섯째 칸 연도) · clamp(PopoverPlacement.clamp)
/// · prolific(ProlificFilter.keep → yes|no, 0.37.0) · topic(TopicFilter.match → 주제 id ',' 로, 0.39.0) · comment(PaperComment.settle → talkLine, 0.39.0)
/// · tally(PaperComment.settle → ScoreboardLive.tally → '반응 n · 사람 n · 댓글 n', 0.39.0 검증 1) · feed(BioRxivFeed.isSettled → 확정|미확정, 0.39.0 리뷰 2)
/// · slab(NotionHubModel.slabRow → 'title|owner|detail'|'제외', 0.40.0 C1·검증 1) · owner(NotionHubModel.ownerInitials) · mm(MilestoneFiles.fileDate → yyyy-MM-dd|—, 넷째 칸 이니셜)
/// · metric('<정의 id>|<입력>' → MetricDefs.eval, 정의서에 없는 id 는 FAIL — 0.40.0 C2) · statusline(StatusLine.variant → 'L|맞음', 0.40.0 C4)
enum TextCheck {
    static func run(path: String) -> Int32 {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("text-check: 파일을 읽지 못함 — \(path)"); return 2
        }
        var ok = 0, fails: [String] = []
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            let raw = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if raw.trimmingCharacters(in: .whitespaces).isEmpty || raw.hasPrefix("#") { continue }
            let f = raw.components(separatedBy: "\t")
            let kind = f[0], input = f.count > 1 ? f[1] : "", want = f.count > 2 ? f[2] : ""
            let got: String
            switch kind {
            case "title": got = Hub.cleanPaperTitle(input)
            case "authors": got = Hub.cleanAuthors(input)
            case "cite": got = Hub.citationLine(input, year: f.count > 4 ? Int(f[4]) : nil, title: f.count > 3 ? f[3] : "").text
            case "clamp": got = clamp(input)
            // Prolific 상태 → 허브에 보이나 (0.37.0 C4) — fixtures/prolific-check.tsv
            case "prolific": got = ProlificFilter.keep(input) ? "yes" : "no"
            // 관심 주제 (0.39.0 C3) — 입력 '제목 | 초록', 기대 = 주제 id 를 ',' 로(없으면 빈 칸). 주제 파일 = <tsv 디렉터리>/../Resources/research-topics.json
            case "topic": got = topic(input, tsv: path)
            // 논문 댓글 판정 (0.39.0 C5) — 입력 '[XX] 내용@분' 을 ';' 로, 기대 '반응 n · 같이 BHL,JOP|— · 댓글 n[ · 모임 후보]'
            case "comment": got = comment(input)
            // 전광판 집계 (0.39.0 C4, 검증 1) — 입력은 comment 와 같은 형식, 기대 '반응 n · 사람 n · 댓글 n'. 제안·취소는 댓글로 세지 않는다
            case "tally": got = tally(input)
            // 피드 확정 날 (0.39.0 리뷰 2) — 입력 '오늘 yyyy-MM-dd|날 yyyy-MM-dd', 기대 '확정' | '미확정'(오늘·어제는 늘 다시 받음)
            case "feed": got = feed(input)
            // SLab 한 행 (0.40.0 C1, F0-1) — 입력 'rel=;who=;sbj=;name=;proj=;time=;round=;status=', 기대 'title|owner|detail' 또는 '제외'. fixtures/slab-check.tsv
            case "slab": got = slab(input)
            // 실험자·예약자 칸 (0.40.0 C1) — NotionHubModel.ownerInitials, 기대 = 이니셜 · '외부' · 빈 칸
            case "owner": got = NotionHubModel.ownerInitials(raw: input, members: testRoster, aliases: testAliases)
            // MM 파일 날짜 (0.40.0 C1, F0-4) — 입력 상대 경로, 기대 'yyyy-MM-dd' 또는 '—'. 넷째 칸 = 폴더 이니셜(쉼표, 기본 JOP). fixtures/mm-check.tsv
            case "mm": got = mm(input, initials: f.count > 3 && !f[3].isEmpty ? f[3].components(separatedBy: ",") : ["JOP"])
            // 지표 정의 (0.40.0 C2, A1) — 입력 '<정의 id>|<입력>', 앱과 같은 MetricDefs. 정의 id 가 ../../docs/metrics-definitions.md 표에 없으면 FAIL. fixtures/metric-check.tsv
            case "metric": got = metric(input, tsv: path)
            // 상태 한 줄 갈래 (0.40.0 C4, A3-variant) — 입력 '폭=;배율=;확정=;예상=;학회=;연구비=;멈춤=;GRM=;현장=', 기대 'L|M|S' + '|맞음|잘림'. fixtures/statusline-check.tsv
            case "statusline": got = statusline(input)
            // 미팅 후속 판정 (0.41.0 C2) — fu-status · fu-visible · fu-count · fu-remind · fu-mm (FollowupLogic, 화면과 같은 함수). fixtures/followup-check.tsv
            case _ where FollowupCheck.kinds.contains(kind): got = FollowupCheck.eval(kind, input, aliases: testAliases)
            // GRM 자료 지도 허브 한 줄 (0.41.0 C6, R2) — 'today=;rows=날짜 이니셜 ●○●–?|…;sched=날짜|…' → '이번 주 … · 지난주 …'. fixtures/grmweek-check.tsv
            case "grmweek": got = GRMMap.weekCheck(input)
            // 연구비 마감 시각 (0.42.0 C1, #39) — 'now=yyyy-MM-ddTHH:mm;title=…;day=yyyy-MM-dd[;note=…][;rem=1]' → MenuBarLine.compact(AlertEngine.grantDue(...).due)
            case "grantdue": got = grantdue(input)
            // 논문 반응 줄 (0.42.0 C1, #23) — 'me=;r=👍:JOP,BHL|✅:SMJ;notes=n;hover=0|1' → PaperReact.text(line)
            case "react": got = PaperReact.check(input)
            // 시간표 (0.42.0 C4, R1) — tt-slots(수업시간 → '요일 HH:mm–HH:mm (강의실)') · tt-sem(날짜 → 학기 id[ 휴일]|학기 밖) · tt-today. fixtures/timetable-check.tsv
            // tt-merge (0.43.0 C3, #47 #48) — Timetable.prepare(조교 제외·같은 과목 합치기) 뒤 모든 덩어리
            // tt-mine (0.43.1 C1, #53) — 'me=;rows=' → '내 수업: …'. tt-today·tt-merge 도 선택 키 me= (별칭은 testAliases 로 풂, 내 덩어리 앞 '★ ')
            case "tt-slots", "tt-sem", "tt-today", "tt-merge", "tt-mine": got = Timetable.check(kind, input, tsv: path, aliases: testAliases)
            // 멤버 상태 (0.42.0 C5, R2) — 'now=;ini=;cal=;notion=;slab=;class=;away=;members=' → 'kind · why · ~HH:mm' | '—'. fixtures/status-check.tsv
            case "mstatus": got = MemberStatus.check(input, tsv: path)
            // Joint projects 한 줄 (0.42.0 C6, R9-d) — 'id=;v=;owner=;done=;waiting=' → JointProjects.line. fixtures/joint-check.tsv
            case "jp-row": got = JointProjects.check(input)
            // 팝오버 '할 것' (0.43.0 C1, #46) — 'now=yyyy-MM-ddTHH:mm;a=<W|C|A>/<제목>/<yyyy-MM-dd[THH:mm]>[/mine]|…' → AlertEngine.order → PopoverTodo.split.
            // 출력 = rows 의 PopoverTodo.line 을 ' / ' 로 + 지난 것이 있으면 ' | 지난 n'. fixtures/todo-check.tsv
            case "todo": got = todo(input)
            // Members 열 머리 (0.43.0 C2, #45) — 'scale=1.3' → '맞음 7/7 · 고정 폭 <합>' | '잘림 <id,…>' (예시 열은 tsv 옆 ../Resources/scoreboard-sample.json).
            // 단일 열 'scale=;title=;chip=;width=' → '맞음' | '잘림'. fixtures/members-check.tsv
            case "mb-head": got = mbHead(input, tsv: path)
            // 연구 탭 태그 (0.43.0 C4, #49) — topiclabel(id → 칩 이름, '*' → 이름들의 한글 글자 수) · tagcolor(테마 id → 'ok 7' | 실패 목록)
            // · feedtags('sel=;topic=0|1;items=id,id|…' → 보이는 항목 번호 ','). fixtures/research-check.tsv
            case "topiclabel", "tagcolor", "feedtags": got = research(kind, input, tsv: path)
            // 제목 막대 더블클릭 (0.43.0 C7, #51) — 'action=<AppleActionOnDoubleClick 값>;legacy=0|1' → zoom|lower|none. fixtures/window-check.tsv
            case "dblclick":
                let k = kv(input)
                got = WindowChrome.doubleClickAction(action: k["action"], legacyMiniaturize: k["legacy"] == "1").rawValue
            default: got = "(모르는 종류 \(kind))"
            }
            if got == want { ok += 1 } else { fails.append("  \(i + 1): \(kind) \"\(input)\" → \"\(got)\" (기대 \"\(want)\")") }
        }
        print("text-check: OK \(ok) · FAIL \(fails.count)")
        fails.forEach { print($0) }
        return fails.isEmpty ? 0 : 1
    }
    /// topic — 앱과 같은 TopicFilter.match. NSApplication 앞이라 Bundle.main 대신 tsv 옆 Resources 경로로 읽는다(한 번)
    private static var topicFile: ResearchTopicFile??
    static func topic(_ input: String, tsv: String) -> String {
        if topicFile == nil {
            let url = URL(fileURLWithPath: tsv).deletingLastPathComponent().appendingPathComponent("../Resources/research-topics.json").standardizedFileURL
            topicFile = .some(TopicFilter.load(url: url))
        }
        guard let f = topicFile ?? nil else { return "(주제 파일 없음)" }
        let parts = input.components(separatedBy: " | ")
        let title = parts.first ?? "", abstract = parts.dropFirst().joined(separator: " | ")
        return TopicFilter.match(title: title, abstract: abstract, topics: f.topics).map(\.id).joined(separator: ",")
    }
    /// comment — PaperComment.parse → settle → talkLine (앱과 같은 함수). '@분' 은 만든 시각(분), 없으면 줄 순서
    static func comment(_ input: String) -> String {
        PaperComment.talkLine(PaperComment.settle(parseComments(input)))
    }
    /// tally — 한 논문 페이지로 settle 뒤 ScoreboardLive.tally(앱과 같은 함수). 기간은 입력 시각 전후 하루를 덮고, 로스터는 비워 반응은 목록 밖 합계로
    static func tally(_ input: String) -> String {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let t = ScoreboardLive.tally(["p": PaperComment.settle(parseComments(input))], roster: [], aliases: [:],
                                     from: base.addingTimeInterval(-86_400), to: base.addingTimeInterval(86_400))
        return "반응 \(t.total) · 사람 \(t.people) · 댓글 \(t.notes)"
    }
    /// feed — BioRxivFeed.isSettled (applyFeed·캐시·'받은 날 m/7' 과 같은 함수)
    static func feed(_ input: String) -> String {
        let p = input.components(separatedBy: "|")
        guard p.count == 2, let today = FeedItem.dayFormatter.date(from: p[0]) else { return "(입력 형식)" }
        return BioRxivFeed.isSettled(p[1], today: today) ? "확정" : "미확정"
    }
    /// statusline — 앱과 같은 StatusLine.variant(NSFont 실측)
    static func statusline(_ input: String) -> String {
        let k = kv(input)
        guard let w = k["폭"].flatMap(Double.init), let sc = k["배율"].flatMap(Double.init) else { return "(입력 형식)" }
        var p = StatusLine.Parts()
        p.confirmed = Int(k["확정"] ?? "") ?? 0; p.expected = Int(k["예상"] ?? "") ?? 0
        p.undecidedConf = Int(k["학회"] ?? "") ?? 0; p.undecidedGrant = Int(k["연구비"] ?? "") ?? 0
        p.stopped = Int(k["멈춤"] ?? "") ?? 0; p.nextGRM = k["GRM"] ?? "—"; p.fieldDays = k["현장"].flatMap(Int.init)
        // 선택 키 '칩=<글>|<글>' (0.41.0 C4) — 뷰와 같은 칩 폭 빼기
        let chips = (k["칩"] ?? "").components(separatedBy: "|").filter { !$0.isEmpty }
        let v = StatusLine.variant(width: CGFloat(w), scale: CGFloat(sc), parts: p, chips: chips)
        return v.variant.rawValue + "|" + (v.fits ? "맞음" : "잘림")
    }
    /// grantdue — 경보·8주 띠·메뉴 막대와 같은 AlertEngine.grantDue → MenuBarLine.compact
    static func grantdue(_ input: String) -> String {
        let k = kv(input)
        let tf = DateFormatter(); tf.locale = Locale(identifier: "en_US_POSIX"); tf.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"
        guard let now = k["now"].flatMap(tf.date(from:)), let day = k["day"].flatMap(df.date(from:)) else { return "(입력 형식)" }
        // 선택 키 note=<dueNote> (검증 1) · rem=1 → 컨펌 리마인더 경로(AlertEngine 리마인더 줄과 같은 Phase.deadlineTime)
        if k["rem"] == "1" { return MenuBarLine.compact(Phase.deadlineTime(k["title"] ?? "", day: day), now: now) }
        return MenuBarLine.compact(AlertEngine.grantDue(title: k["title"] ?? "", dueNote: k["note"] ?? "", day: day).due, now: now)
    }
    /// todo — 시각 없는 날짜는 그날 23:59(Phase.deadlineTime, 제목에 HH:mm 이 있으면 그 시각) · overdue = 마감 날 < 오늘(앱 리마인더 n < 0 과 같음)
    static func todo(_ input: String) -> String {
        let k = kv(input)
        let tf = DateFormatter(); tf.locale = Locale(identifier: "en_US_POSIX"); tf.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"
        guard let now = k["now"].flatMap(tf.date(from:)) else { return "(입력 형식)" }
        let cal = Calendar.current
        var alerts: [HubAlert] = []
        for (i, item) in (k["a"] ?? "").components(separatedBy: "|").enumerated() where !item.isEmpty {
            let f = item.components(separatedBy: "/")
            guard f.count >= 3 else { return "(입력 형식 \(item))" }
            let level: HubAlert.Level = f[0] == "W" ? .warning : f[0] == "C" ? .caution : .advisory
            let due: Date, hasTime: Bool
            if let t = tf.date(from: f[2]) { due = t; hasTime = true }
            else if let d = df.date(from: f[2]) { due = Phase.deadlineTime(f[1], day: d); hasTime = f[1].range(of: "\\d{1,2}:\\d{2}", options: .regularExpression) != nil }
            else { return "(날짜 형식 \(f[2]))" }
            let overdue = cal.startOfDay(for: due) < cal.startOfDay(for: now)
            alerts.append(HubAlert(id: "t\(i)", level: level, title: f[1], due: due, hasTime: hasTime, mine: f.count > 3 && f[3] == "mine", overdue: overdue))
        }
        let (rows, lapsed) = PopoverTodo.split(AlertEngine.order(alerts))
        return rows.map { PopoverTodo.line($0, now: now) }.joined(separator: " / ") + (lapsed.isEmpty ? "" : " | 지난 \(lapsed.count)")
    }
    /// mb-head — MembersBoardRow.headerFits 실측(시스템 글꼴 기준)
    static func mbHead(_ input: String, tsv: String) -> String {
        let k = kv(input)
        guard let scale = k["scale"].flatMap(Double.init).map({ CGFloat($0) }) else { return "(입력 형식)" }
        if let title = k["title"] {
            let c = MembersBoardRow.Column(id: "one", title: title, chip: (k["chip"] ?? "").isEmpty ? nil : k["chip"], width: CGFloat(Double(k["width"] ?? "") ?? 0))
            return MembersBoardRow.headerFits(c, scale: scale) ? "맞음" : "잘림"
        }
        let url = URL(fileURLWithPath: tsv).deletingLastPathComponent().appendingPathComponent("../Resources/scoreboard-sample.json").standardizedFileURL
        let sample = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ScoreboardSample.self, from: $0) }
        let cols = MembersBoardRow.columns(sample: sample, milestone: true)
        // avail=<pt> (검증 1) — 그 탭 폭에 fittedWidths 로 맞춘 표: 줄 전체 폭 ≤ avail 이고 머리가 다 들어가면 '들어감 n/n', 아니면 '넘침 <pt>' · '잘림 <id들>'
        if let avail = k["avail"].flatMap(Double.init).map({ CGFloat($0) }) {
            let ws = MembersBoardRow.fittedWidths(cols, scale: scale, avail: avail)
            let total = MembersBoardRow.rowWidth(ws, scale: scale)
            let cut = cols.indices.filter { MembersBoardRow.headerNeed(cols[$0], scale: scale) > ws[$0] }.map { cols[$0].id }
            if total > avail { return "넘침 \(Int((total - avail).rounded(.up)))" }
            return cut.isEmpty ? "들어감 \(cols.count)/\(cols.count)" : "잘림 " + cut.joined(separator: ",")
        }
        let cut = cols.filter { !MembersBoardRow.headerFits($0, scale: scale) }.map(\.id)
        return cut.isEmpty ? "맞음 \(cols.count)/\(cols.count) · 고정 폭 \(Int(MembersBoardRow.fixedWidthSum))" : "잘림 " + cut.joined(separator: ",")
    }
    /// topiclabel · tagcolor · feedtags — 주제 파일·테마 파일은 tsv 옆 ../Resources (앱 번들과 같은 내용)
    static func research(_ kind: String, _ input: String, tsv: String) -> String {
        let res = URL(fileURLWithPath: tsv).deletingLastPathComponent().appendingPathComponent("../Resources").standardizedFileURL
        if topicFile == nil { topicFile = .some(TopicFilter.load(url: res.appendingPathComponent("research-topics.json"))) }
        let topics = (topicFile ?? nil)
        switch kind {
        case "topiclabel":
            guard let f = topics else { return "(주제 파일 없음)" }
            if input == "*" { return String(f.topics.map(\.title).joined().unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) || (0x3131...0x318E).contains($0.value) }.count) }
            return f.topics.contains { $0.id == input } ? f.label(input) + " · slot \(f.slot(input))" : "(모르는 id)"
        case "tagcolor":
            var all: [String: ThemeDef] = ["csnl": Theme.builtin]
            if let d = try? Data(contentsOf: res.appendingPathComponent("themes.json")), let m = try? JSONDecoder().decode([String: ThemeDef].self, from: d) {
                all.merge(m) { _, new in new }
            }
            all["contrast"] = Theme.contrast
            guard let def = all[input] else { return "(모르는 테마)" }
            return TagPalette.check(def)
        default:
            let k = kv(input)
            let known = topics?.topics.map(\.id) ?? []
            let sel = Set(FeedPrefs.sanitize((k["sel"] ?? "").split(separator: ",").map(String.init), known: known))
            let items = (k["items"] ?? "").components(separatedBy: "|").map { $0.split(separator: ",").map(String.init) }
            return FeedFilter.shown(matches: items, tags: sel, topicOnly: k["topic"] != "0").map(String.init).joined(separator: ",")
        }
    }
    /// metric — 정의서 표 첫 칸 id 집합(한 번 읽음) → MetricDefs.eval
    private static var defIDs: Set<String>??
    static func metric(_ input: String, tsv: String) -> String {
        let dir = URL(fileURLWithPath: tsv).deletingLastPathComponent()
        if defIDs == nil { defIDs = .some(MetricDefs.loadIDs(dir.appendingPathComponent("../../docs/metrics-definitions.md").standardizedFileURL)) }
        let parts = input.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let id = parts[0].trimmingCharacters(in: .whitespaces), arg = parts.count > 1 ? parts[1] : ""
        guard let ids = defIDs ?? nil, !ids.isEmpty else { return "(정의서를 읽지 못함)" }
        guard ids.contains(id) else { return "(정의서에 없음 \(id))" }
        return MetricDefs.eval(id: id, input: arg, fixtureDir: dir.path)
    }
    /// 시험 로스터 (0.40.0 C1) — 이니셜은 랩 고정 목록, 이름·이메일은 가짜(규칙 시험용). 별칭은 Config 기본값과 같다
    static let testAliases = ["SK": "SJK", "RJH": "JHR"]
    static let testRoster: [Member] = [
        ("JOP", "Alpha Kim", "alpha@lab.test"), ("BHL", "Beta Lee", "beta@lab.test"), ("BYL", "Betty Lee", "betty@lab.test"),
        ("JYK", "Gamma Jo", "gamma@lab.test"), ("SMJ", "Delta Song", ""), ("MSY", "Echo Moon", ""), ("SJK", "Foxtrot Kim", ""),
        ("JSL", "Golf Lim", ""), ("SYJ", "Hotel Jang", ""), ("JHR", "India Ryu", ""), ("MJC", "Juliet Cho", ""),
    ].enumerated().map { i, x in Member(id: "m\(i)", name: x.1, initials: x.0, email: x.2, active: true, order: i) }
    /// 'k=v;k=v' → 사전 (값 안의 '=' 는 그대로)
    private static func kv(_ input: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in input.components(separatedBy: ";") {
            let p = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if p.count == 2 { out[p[0].trimmingCharacters(in: .whitespaces)] = p[1] }
        }
        return out
    }
    /// slab — 앱과 같은 NotionHubModel.slabRow. rel = people 해석이 끝난 Project People 제목(빈칸 = relation 없음, '?' = relation 은 있는데 풀리지 않음).
    /// who·sbj 는 피험자 칸 흉내 — 페이지에 (다른 이름의 키로) 넣고, 결과에 그 값이 섞이면 '(원문 노출)'.
    /// name = 실험명(제목 칸, 기본 '시험 실험') — 실제 실험명에 피험자 이름·ID 가 들어 있으므로 결과(title·owner·detail)에 섞이면 '(원문 노출)' (검증 1).
    /// proj = '프로젝트' text (title 의 출처)
    static func slab(_ input: String) -> String {
        let k = kv(input)
        let rel = k["rel"] ?? "", who = k["who"] ?? "", sbj = k["sbj"] ?? "", name = k["name"] ?? "시험 실험"
        func rich(_ s: String) -> [String: Any] { ["type": "rich_text", "rich_text": [["plain_text": s]]] }
        var props: [String: Any] = [
            "실험명": ["type": "title", "title": [["plain_text": name]]],
            "프로젝트": rich(k["proj"] ?? ""),
            "시간": rich(k["time"] ?? ""), "상태": ["type": "select", "select": ["name": k["status"] ?? ""]],
            "who": rich(who), "sbj": rich(sbj),
        ]
        if let r = k["round"], let n = Double(r) { props["회차"] = ["type": "number", "number": n] }
        var people: [String: String] = [:]
        if !rel.isEmpty {
            props["실험자"] = ["type": "relation", "relation": [["id": "rel-1"]]]
            if rel != "?" { people["rel1"] = rel.uppercased() }
        }
        let canonical: (String) -> String? = { raw in
            let ini = (testAliases[raw.uppercased()] ?? raw).uppercased()
            return testRoster.first { $0.initials == ini }?.initials
        }
        guard let row = NotionHubModel.slabRow(["id": "t", "properties": props], people: people, canonical: canonical) else { return "제외" }
        let out = row.title + "|" + row.owner + "|" + row.detail
        // 실험명은 통째로, 그리고 낱말마다(공백·'_' 로 나눔) — 프로젝트·회차와 같은 낱말은 정당한 출처라 뺀다
        let proj = k["proj"] ?? "", roundText = k["round"].map { "\($0)회차" } ?? ""
        let nameTokens = name.components(separatedBy: CharacterSet(charactersIn: " _")).filter { $0.count >= 2 && !proj.contains($0) && $0 != roundText }
        for v in [who, sbj, name] + nameTokens where v.count >= 2 && out.contains(v) { return "(원문 노출) " + out }
        return out
    }
    /// mm — MilestoneFiles.fileDate (Members 전광판 Milestone 열·'MM 고유 날짜' 와 같은 함수)
    static func mm(_ rel: String, initials: [String]) -> String {
        guard let d = MilestoneFiles.fileDate(rel, initials: initials) else { return "—" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
    /// '[XX] 내용@분' 을 ';' 로 → PaperComment (comment·tally 공용)
    private static func parseComments(_ input: String) -> [PaperComment] {
        let parts = input.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let cs: [PaperComment] = parts.enumerated().compactMap { i, part in
            var raw = part, minute = Double(i)
            if let at = part.range(of: "@", options: .backwards), let m = Double(part[at.upperBound...].trimmingCharacters(in: .whitespaces)) {
                raw = String(part[..<at.lowerBound]); minute = m
            }
            return PaperComment.parse(raw: raw, id: "t\(i)", created: Date(timeIntervalSinceReferenceDate: minute * 60))
        }
        return cs
    }
    /// clamp 입력 `screen=x,y,w,h;visible=x,y,w,h;bar=Y|-;pop=x,y,w,h` → PopoverPlacement.clamp 결과 "x,y,w,h"
    static func clamp(_ input: String) -> String {
        var kv: [String: String] = [:]
        for part in input.split(separator: ";") {
            let p = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if p.count == 2 { kv[p[0]] = p[1] }
        }
        guard let screen = kv["screen"].flatMap(PopoverPlacement.parse), let visible = kv["visible"].flatMap(PopoverPlacement.parse),
              let pop = kv["pop"].flatMap(PopoverPlacement.parse) else { return "(입력 형식 오류)" }
        let bar = kv["bar"].flatMap { Double($0) }.map { CGFloat($0) }
        return PopoverPlacement.format(PopoverPlacement.clamp(pop, screen: screen, visible: visible, barBottom: bar))
    }
}
