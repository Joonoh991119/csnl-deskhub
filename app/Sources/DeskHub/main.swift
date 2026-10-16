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
