import SwiftUI
import AppKit

// MARK: - 측정 기반 (0.40.0 C2, A1 — 수렴 문서 §3-2 A1, 정의서 docs/metrics-definitions.md)
// 숫자 하나 = 정의 id 하나 = 원천 하나. 앱 밖 집계(scripts/aggregate_daily.py, 하루 1회·읽기 전용·이 맥 전용)가 쓴 latest.json 을 읽고,
// 허브 카드 끝마다 '출처 · 기준 · n · 정의 id' 캡션을 단다. 정의의 순수 함수는 MetricDefs — --text-check 'metric' 이 같은 함수를 부른다.

/// 집계 파일 한 장 (schema 1). 필요한 필드만 — 모르는 키는 무시
struct MetricsSnapshot: Sendable {
    struct Source: Identifiable, Sendable {
        let id: String; let label: String; let kind: String
        let rows: Int?; let pages: Int?
        let contentDate: Date?; let editedMax: Date?
        let cycle: Int; let cards: [String]; let error: String?
    }
    struct Hygiene: Identifiable, Sendable { let id: String; let label: String; let n: Int; let of: Int?; let db: String }
    struct SlabKey: Sendable { let project: String; let experimenter: String; let sessions: Int; let lastDate: Date? }
    struct Prolific: Sendable { let studies: Int; let byMonth: [String: (studies: Int, submissions: Int)]; let activeUnderQuota: Int }

    var asOf: Date?
    var today: String = ""
    var sources: [Source] = []
    var hygiene: [Hygiene] = []
    var slabRows: Int?
    var slabSessions: Int?
    var slabLast: Date?
    var slabNoExperimenter: Int?
    var slabKeys: [SlabKey] = []
    var icsLast: Date?
    var prolific: Prolific?
    var grmMap: [String: Int] = [:]
    var mm: [String: Int] = [:]

    func source(_ id: String) -> Source? { sources.first { $0.id == id } }

    static func day(_ s: Any?) -> Date? {
        guard let s = s as? String, !s.isEmpty else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }
    static func instant(_ s: Any?) -> Date? {
        guard let s = s as? String, !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        for o: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            iso.formatOptions = o
            if let d = iso.date(from: s) { return d }
        }
        return nil
    }

    /// JSON → 스냅샷. schema ≠ 1 이면 (nil, 사유)
    static func parse(_ data: Data) -> (MetricsSnapshot?, String?) {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, "집계 파일을 읽지 못함") }
        guard (o["schema"] as? Int) == 1 else { return (nil, "집계 schema 가 1 이 아님") }
        var s = MetricsSnapshot()
        s.asOf = instant(o["as_of"])
        s.today = o["today"] as? String ?? ""
        // sources 는 집계 쪽 순서(정의서 순서)를 지킨다 — JSONSerialization 사전은 순서가 없어 기대 주기·id 순으로 다시 정렬
        let src = (o["sources"] as? [String: [String: Any]]) ?? [:]
        s.sources = src.map { id, v in
            Source(id: id, label: v["label"] as? String ?? id, kind: v["kind"] as? String ?? "",
                   rows: v["rows"] as? Int, pages: v["pages"] as? Int,
                   contentDate: day(v["content_date"]), editedMax: day(v["edited_max"]),
                   cycle: v["expected_cycle_days"] as? Int ?? 30, cards: v["cards"] as? [String] ?? [], error: v["error"] as? String)
        }.sorted { $0.cycle != $1.cycle ? $0.cycle < $1.cycle : $0.id < $1.id }
        s.hygiene = ((o["hygiene"] as? [[String: Any]]) ?? []).compactMap { h in
            guard let id = h["id"] as? String else { return nil }
            return Hygiene(id: id, label: h["label"] as? String ?? id, n: h["n"] as? Int ?? 0, of: h["of"] as? Int, db: h["db"] as? String ?? "")
        }
        if let sl = o["slab"] as? [String: Any] {
            s.slabRows = sl["rows"] as? Int
            s.slabSessions = sl["sessions"] as? Int
            s.slabLast = day(sl["last_date"])
            s.slabNoExperimenter = sl["no_experimenter"] as? Int
            s.slabKeys = ((sl["keys"] as? [[String: Any]]) ?? []).map {
                SlabKey(project: $0["project"] as? String ?? "", experimenter: $0["experimenter"] as? String ?? "",
                        sessions: $0["sessions"] as? Int ?? 0, lastDate: day($0["last_date"]))
            }
        }
        s.icsLast = day((o["ics_slab"] as? [String: Any])?["last_date"])
        if let p = o["prolific"] as? [String: Any] {
            var by: [String: (Int, Int)] = [:]
            for (k, v) in (p["by_published_month"] as? [String: [String: Any]]) ?? [:] { by[k] = (v["studies"] as? Int ?? 0, v["submissions"] as? Int ?? 0) }
            s.prolific = Prolific(studies: p["studies"] as? Int ?? 0, byMonth: by.mapValues { (studies: $0.0, submissions: $0.1) }, activeUnderQuota: p["active_under_quota"] as? Int ?? 0)
        }
        s.grmMap = ((o["grm_map"] as? [String: Any]) ?? [:]).compactMapValues { $0 as? Int }
        s.mm = ((o["mm"] as? [String: Any]) ?? [:]).compactMapValues { $0 as? Int }
        return (s, nil)
    }
}

/// 집계 파일 읽기 — DESKHUB_METRICS=<경로>(시험 고정본) 또는 Application Support/DeskHub/metrics/latest.json. 없으면 (nil, '집계 없음')
enum MetricsStore {
    static var path: String {
        if let p = ProcessInfo.processInfo.environment["DESKHUB_METRICS"], !p.isEmpty { return (p as NSString).expandingTildeInPath }
        return Config.directory.appendingPathComponent("metrics/latest.json").path
    }
    static func load(path: String) -> (MetricsSnapshot?, String?) {
        guard let d = FileManager.default.contents(atPath: path) else { return (nil, "집계 없음") }
        return MetricsSnapshot.parse(d)
    }
}

extension NotionHubModel {
    /// refresh 끝(loadMilestones 뒤)에 — 메인 스레드 밖에서 읽는다. 적색 없음
    func loadMetrics() async {
        let p = MetricsStore.path
        let r = await Task.detached(priority: .utility) { MetricsStore.load(path: p) }.value
        metrics = r.0
        metricsNote = r.1
    }
}

// MARK: - 카드 출처 캡션 (CardMeta 레지스트리 — 허브 데이터 카드 14, 메일 초안은 도구라 제외)

enum CardMetas {
    /// 허브 데이터 카드 (정의서 CARD-<id>) — 윗줄 3 · 열1 3 · 열2 4 · 열3 3 + 장비(C5) + 미팅 후속(0.41.0 C3)
    static let hub = ["grm", "nownext", "members", "papers", "preprints", "apps", "reminders", "experiments", "equipment", "events", "grants", "minutes", "blitz", "conferences", "followups"]
    /// 관제탑 레일 id → 카드 id (도구·자료 상태 제외)
    static func cardID(forRail id: String) -> String? {
        ["papers", "minutes", "followups", "events", "blitz", "experiments", "grants", "conferences", "preprints", "members", "apps"].contains(id) ? id : nil
    }

    /// '기준' 글 — 오늘이면 HH:mm, 아니면 M.d (실제 시각 기준, 없으면 —)
    static func basis(_ d: Date?, now: Date = Date()) -> String {
        guard let d else { return "—" }
        let f = DateFormatter(); f.dateFormat = Calendar.current.isDate(d, inSameDayAs: now) ? "HH:mm" : "M.d"
        return f.string(from: d)
    }
    static func text(source: String, at: Date?, n: Int?, card: String, now: Date = Date()) -> String {
        MetricDefs.caption(source: source, basis: basis(at, now: now), n: n.map(String.init) ?? "—", id: "CARD-" + card)
    }

    static var appsFileDate: Date? {
        let user = Config.directory.appendingPathComponent("apps.json")
        for url in [user, Bundle.main.url(forResource: "apps", withExtension: "json")].compactMap({ $0 }) {
            if let a = try? FileManager.default.attributesOfItem(atPath: url.path), let d = a[.modificationDate] as? Date { return d }
        }
        return nil
    }
    static func appsCaption() -> String { text(source: "apps.json", at: appsFileDate, n: MadeApps.load().apps.count, card: "apps") }
    @MainActor static func nownextCaption(_ cal: CalendarModel) -> String {
        let n = cal.events.filter { Calendar.current.isDate($0.start, inSameDayAs: cal.now) }.count
        return text(source: "CSNL·SLab 캘린더", at: cal.lastUpdated, n: n, card: "nownext")
    }

    /// 카드 하나의 캡션 — 허브 카드 끝·관제탑 펼친 레일 아래·text.txt [카드 출처] 가 같은 함수
    @MainActor static func caption(_ id: String, _ m: NotionHubModel) -> String {
        let at = m.lastUpdated
        switch id {
        case "grm": return text(source: "GRM Schedule", at: at, n: m.grm.count, card: id)
        case "nownext":
            if let cal = m.todayCalendar { return nownextCaption(cal) }
            return text(source: "CSNL·SLab 캘린더", at: nil, n: nil, card: id)
        case "members": return text(source: "Members·member_links", at: at, n: MembersProjectsStrip.shown(m).count, card: id)
        case "papers": return text(source: "논문 추천(paperRec)", at: at, n: m.papers.count, card: id)
        case "preprints": return text(source: "OpenAlex", at: m.preprintsAt, n: m.preprints.count, card: id)
        case "apps": return appsCaption()
        case "reminders": return text(source: "reminders.json", at: at, n: m.confirmedReminders.count, card: id)
        case "experiments": return text(source: "SLab·Prolific", at: at, n: m.experiments.count, card: id)
        case "equipment": return text(source: "Resource", at: at, n: m.equipmentCount, card: id)
        case "events":
            return text(source: "Schedule & Events·캘린더", at: at,
                        n: UpcomingEventsCard.items(model: m, cal: m.todayCalendar, excludeToday: false).count, card: id)
        case "grants": return text(source: "grants_schedule.json", at: at, n: m.grants.count, card: id)
        case "minutes": return text(source: "Meeting Notes", at: at, n: m.minutes.count, card: id)
        case "blitz": return text(source: m.blitzSource == "Notion" ? "Paper Blitz Archive" : "NAS 덱", at: at, n: m.blitz.count, card: id)
        case "conferences": return text(source: "Conferences·학회 파일", at: at, n: m.conferences.count, card: id)
        // 미팅 후속 (0.41.0 C3) — 기준 = 추출 생성 시각, n = 남은(보기 내용이면 내 것, 아니면 연구실). 못 읽으면 —
        case "followups":
            let n: Int? = m.followupRead == .ok ? (m.followupView == .full ? m.myFollowupOpen : m.followupOpen(who: nil).count) : nil
            return text(source: "미팅 후속 추출·상태 파일", at: m.followupsGenerated, n: n, card: id)
        default: return text(source: "—", at: nil, n: nil, card: id)
        }
    }

    /// text.txt [카드 출처] — '<id> · 꼬리표 <글|—> · 캡션 <글>'. 꼬리표는 C3 의 cardTag(없으면 —)
    @MainActor static func dumpLines(_ m: NotionHubModel) -> [String] {
        hub.map { id in "\(id) · 꼬리표 \(m.cardTagText(id) ?? "—") · 캡션 \(caption(id, m))" }
    }
}

/// 캡션 한 줄 — Hub.text3 · cs.cap · 한 줄(가운데 말줄임, 툴팁 전체)
struct SourceCaption: View {
    let text: String
    @Environment(\.cardStyle) private var cs
    var body: some View {
        Text(text).font(.hub(cs.cap)).foregroundStyle(Hub.text3).lineLimit(1).truncationMode(.middle)
            .help(text + " — 정의는 docs/metrics-definitions.md")
    }
}

// MARK: - 첫 그림까지 시간 (M5)

/// 앱 시작(applicationDidFinishLaunching) → 데이터 다 옴(settledAt) 뒤 기본 뷰 첫 그림까지 ms 를 한 번 잰다. UsageLog kind render · windows.txt 'render:'
@MainActor
enum RenderClock {
    private static var start: Date?
    private(set) static var measured: (ms: Int, view: String)?
    static func begin() { if start == nil { start = Date() } }
    /// 첫 settledAt 뒤 그 뷰가 그려진 다음 런루프에서 한 번
    static func mark(view: String) {
        guard measured == nil, let s = start else { return }
        let ms = Int((Date().timeIntervalSince(s) * 1000).rounded())
        measured = (ms, view)
        UsageLog.render(ms: ms, view: view)
    }
    static var line: String { measured.map { "render: 첫 실측 \($0.ms) ms · 뷰 \($0.view)" } ?? "render: 첫 실측 —" }
}

// MARK: - 정의의 순수 함수 (text-check 'metric' 과 앱이 같은 함수)

enum MetricDefs {
    /// 한국시간 달력 — 주 경계 월~일 (M-week)
    static let kst: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Seoul")!
        c.firstWeekday = 2
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()
    static func ymd(_ d: Date) -> String {
        let f = DateFormatter(); f.calendar = kst; f.timeZone = kst.timeZone; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
    static func parseDay(_ s: String) -> Date? {
        let f = DateFormatter(); f.calendar = kst; f.timeZone = kst.timeZone; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s.trimmingCharacters(in: .whitespaces))
    }
    /// '2026-10-15T17:00' (한국시간) · ISO(+09:00) · '2026-10-15'
    static func parseInstant(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let d = MetricsSnapshot.instant(t) { return d }
        let f = DateFormatter(); f.calendar = kst; f.timeZone = kst.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] { f.dateFormat = fmt; if let d = f.date(from: t) { return d } }
        return nil
    }

    /// M-week — 기준일이 든 주의 월요일 0시 ~ 일요일
    static func week(of d: Date) -> (start: Date, end: Date) {
        let start = kst.dateInterval(of: .weekOfYear, for: d)?.start ?? kst.startOfDay(for: d)
        return (start, kst.date(byAdding: .day, value: 6, to: start)!)
    }

    /// A1-asof — 지연 시간(시, 내림). 26시간 넘으면 지연
    static let asofLimitHours = 26
    static func asofHours(asOf: Date, now: Date) -> Int { max(0, Int(now.timeIntervalSince(asOf) / 3600)) }

    /// alias — cfg.initialsAliases 한 표 (대소문자 무시)
    static func alias(_ raw: String, aliases: [String: String]) -> String {
        let u = raw.trimmingCharacters(in: .whitespaces).uppercased()
        return (aliases[u] ?? u).uppercased()
    }

    /// caption — '출처 <원천> · 기준 <HH:mm|M.d> · n <n> · <정의 id>'
    static func caption(source: String, basis: String, n: String, id: String) -> String {
        "출처 \(source) · 기준 \(basis) · n \(n) · \(id)"
    }

    /// 'k=v,k=v' → 사전
    static func kv(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in s.components(separatedBy: ",") {
            let p = part.split(separator: "=", maxSplits: 1).map(String.init)
            if p.count == 2 { out[p[0].trimmingCharacters(in: .whitespaces)] = p[1].trimmingCharacters(in: .whitespaces) }
        }
        return out
    }

    /// 정의서 표의 id 집합 — '| <id> | …' 줄의 첫 칸(머리 'id'·구분선 제외)
    static func loadIDs(_ url: URL) -> Set<String> {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: Set<String> = []
        for line in text.components(separatedBy: "\n") where line.hasPrefix("| ") {
            let cells = line.components(separatedBy: "|")
            guard cells.count > 2 else { continue }
            let id = cells[1].trimmingCharacters(in: .whitespaces)
            if !id.isEmpty, id != "id", !id.hasPrefix("---") { out.insert(id) }
        }
        return out
    }

    /// --text-check 'metric' — '<정의 id>|<입력>' → 결과 글. 정의 id 가 정의서에 있는지는 TextCheck 가 먼저 본다
    static func eval(id: String, input: String, fixtureDir: String) -> String {
        switch id {
        case "M-week":
            guard let d = parseDay(input) else { return "(입력 형식)" }
            let w = week(of: d)
            return ymd(w.start) + ".." + ymd(w.end)
        case "A1-asof":
            let k = kv(input)
            guard let a = k["as_of"].flatMap(parseInstant), let n = k["now"].flatMap(parseInstant) else { return "(입력 형식)" }
            let h = asofHours(asOf: a, now: n)
            return "\(h)시간" + (h > asofLimitHours ? " · 지연" : "")
        case "alias":
            return alias(input, aliases: TextCheck.testAliases)
        case "caption":
            let k = kv(input)
            guard let at = k["at"].flatMap(parseInstant), let now = k["now"].flatMap(parseInstant) else { return "(입력 형식)" }
            let f = DateFormatter(); f.calendar = kst; f.timeZone = kst.timeZone
            f.dateFormat = kst.isDate(at, inSameDayAs: now) ? "HH:mm" : "M.d"
            return caption(source: k["src"] ?? "", basis: f.string(from: at), n: k["n"] ?? "—", id: k["id"] ?? "")
        default:
            return evalMore(id: id, input: input, fixtureDir: fixtureDir)
        }
    }
    /// C3 이후 정의(A2·A3·A4·A5·A6)
    static func evalMore(id: String, input: String, fixtureDir: String) -> String {
        let k = kv(input)
        switch id {
        // A2 — 'content=yyyy-MM-dd(빈 칸 = 없음),today=…,cycle=n' → '56일 · ×8.0 · 멈춤' (ProducerRule — 앱 꼬리표·자료 상태 표와 같은 함수)
        case "A2-stopped", "A2-late":
            guard let today = k["today"].flatMap(parseDay), let cyc = k["cycle"].flatMap(Int.init) else { return "(입력 형식)" }
            guard let j = ProducerRule.judge(content: k["content"].flatMap(parseDay), today: today, cycleDays: cyc) else { return "내용 없음" }
            return ProducerRule.label(j)
        case "A2-content":
            guard let today = k["today"].flatMap(parseDay), let cyc = k["cycle"].flatMap(Int.init) else { return "(입력 형식)" }
            guard let f = Freshness.content(k["content"].flatMap(parseDay), cycle: cyc, today: today) else { return "—" }
            return f.text + " · " + (f.state == .fresh ? "fresh" : "stale")
        default:
            return evalMore2(id: id, input: input, fixtureDir: fixtureDir)
        }
    }
    /// C4 이후 정의
    static func evalMore2(id: String, input: String, fixtureDir: String) -> String {
        let k = kv(input)
        switch id {
        // A3-window — 이번 주 월요일(한국시간)부터 56일 (StatusLine.window — 한 줄·8주 띠와 같은 함수)
        case "A3-window":
            guard let d = parseDay(input) else { return "(입력 형식)" }
            let w = StatusLine.window(today: d)
            return ymd(w.start) + ".." + ymd(w.end)
        // A3-field — 'slab=,ics=,today=' → 'n일' 또는 '—' (StatusLine.fieldDays)
        case "A3-field":
            guard let today = k["today"].flatMap(parseDay) else { return "(입력 형식)" }
            return StatusLine.fieldDays(slab: k["slab"].flatMap(parseDay), ics: k["ics"].flatMap(parseDay), today: today).map { "\($0)일" } ?? "—"
        default:
            return evalMore3(id: id, input: input, fixtureDir: fixtureDir)
        }
    }
    /// C5 이후 정의
    static func evalMore3(id: String, input: String, fixtureDir: String) -> String {
        let k = kv(input)
        // 예약 한 줄 'start=yyyy-MM-dd[THH:mm],end=,status=,user=' (장비 'M')
        func row() -> EquipmentRow? {
            guard let s = k["start"].flatMap(parseInstant) else { return nil }
            let hasTime = (k["start"] ?? "").contains("T")
            return EquipmentRow(id: "t", resources: ["M"], start: s, end: k["end"].flatMap { $0.isEmpty ? nil : parseInstant($0) }, hasTime: hasTime,
                                status: k["status"] ?? "", user: k["user"] ?? "")
        }
        switch id {
        // A5-now·A5-next — EquipmentBoard.current/upcoming (장비 카드와 같은 함수)
        case "A5-now":
            guard let r = row(), let now = k["now"].flatMap(parseInstant) else { return "(입력 형식)" }
            return EquipmentBoard.nowText(EquipmentBoard.current([r], now: now))
        case "A5-next":
            guard let r = row(), let now = k["now"].flatMap(parseInstant) else { return "(입력 형식)" }
            return EquipmentBoard.nextText(EquipmentBoard.upcoming([r], now: now))
        // A5-overdue — Running && (끝 ?? 시작) < 오늘 → '누락' | '정상'
        case "A5-overdue":
            guard let r = row(), let today = k["today"].flatMap(parseDay) else { return "(입력 형식)" }
            return EquipmentBoard.isOverdue(r, today: today) ? "누락" : "정상"
        // A5-machines — 장비 이름 목록(행마다 하나, 쉼표) → 행 수 내림차순(같으면 이름)
        case "A5-machines":
            let rows = input.components(separatedBy: ",").enumerated().map { i, n in
                EquipmentRow(id: "r\(i)", resources: [n.trimmingCharacters(in: .whitespaces)], start: Date(timeIntervalSinceReferenceDate: 0), end: nil, hasTime: false, status: "Done", user: "")
            }
            return EquipmentBoard.machines(rows).joined(separator: " · ")
        default:
            return evalMore4(id: id, input: input, fixtureDir: fixtureDir)
        }
    }
    /// C6 이후 정의
    static func evalMore4(id: String, input: String, fixtureDir: String) -> String {
        switch id {
        // A6 — 파일 이름 → '슬라이드' | 'PB' | '녹취' | '—'
        case "A6-slide", "A6-pb", "A6-transcript": return GRMMap.classify(input.trimmingCharacters(in: .whitespaces))
        // A6-minutes — 'rel=0|1,day=yyyy-MM-dd,notes=<Type>:<yyyy-MM-dd>[:<제목>];…' → '●' | '○'. 제목을 비우려면 '<Type>:<날짜>:' (검증 1)
        case "A6-minutes":
            let k = kv(input)
            guard let day = k["day"].flatMap(parseDay) else { return "(입력 형식)" }
            let notes: [(type: String, title: String, date: Date?)] = (k["notes"] ?? "").components(separatedBy: ";").compactMap { part in
                let f = part.components(separatedBy: ":")
                guard f.count >= 2 else { return nil }
                return (f[0], f.count >= 3 ? f[2] : "회의록", parseDay(f[1]))
            }
            return GRMMap.hasMinutes(relation: k["rel"] == "1", day: day, minuteDays: GRMMap.minuteDays(notes)) ? "●" : "○"
        default: return evalMore5(id: id, input: input, fixtureDir: fixtureDir)
        }
    }
    /// C7 이후 정의
    static func evalMore5(id: String, input: String, fixtureDir: String) -> String {
        // A4 — Prolific 픽스처(앱과 같은 ProlificClient.fixture 파싱)
        func studies(_ file: String) -> [ProlificStudy]? {
            let path = (fixtureDir as NSString).appendingPathComponent(file.trimmingCharacters(in: .whitespaces))
            if case .ok(let list) = ProlificClient.fixture(path: path) { return list }
            return nil
        }
        switch id {
        case "A4-online":
            let p = input.components(separatedBy: "|")
            guard p.count == 2, let list = studies(p[0]) else { return "(입력 형식·픽스처)" }
            let ym = p[1].split(separator: "-").compactMap { Int($0) }
            guard ym.count == 2 else { return "(입력 형식)" }
            return ExperimentStats.onlineMetricText(ExperimentStats.online(list, year: ym[0], month: ym[1]))
        case "A4-sum":
            guard let list = studies(input) else { return "(픽스처)" }
            let s = ExperimentStats.monthlySum(list)
            return (s.byMonth == s.total ? "월별 합 = 전체 합" : "월별 합 ≠ 전체 합") + " (\(s.byMonth)=\(s.total))"
        case "A4-field":
            let k = kv(input)
            guard let today = k["today"].flatMap(parseDay) else { return "(입력 형식)" }
            return ExperimentStats.field(slab: k["slab"].flatMap(parseDay), ics: k["ics"].flatMap(parseDay), today: today).text
        default:
            return "(함수 없음 \(id))"
        }
    }
}
