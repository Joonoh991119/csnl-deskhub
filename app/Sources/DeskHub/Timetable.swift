import SwiftUI
import AppKit

// MARK: - 시간표 (0.42.0 C4, R1 — 랩장 JOP 10-19 DM '타임테이블')
// 데이터 계약 (계획 0.42.0 §2 'Courses'):
//   Notion 🎓 Courses 를 앱이 읽기만 한다 — 학기 select = 지금 학기, page_size 100, 1쪽, 6시간 캐시. 학기 안일 때만 부른다.
//   읽는 칸: 과목명·학기·상태·구분·수업시간·강의실·이니셜·본인확인. 담당교수·과목번호·출처는 읽지 않는다.
//   버리는 행: 상태 '드랍' · 과목명/이니셜/수업시간 중 하나라도 빈 행 · 수업시간을 못 읽은 행(개수만 unparsed).
//   학기 날짜·휴일: 번들 semesters.json(timetable 플러그인 config 사본) + 사용자 ~/Library/Application Support/DeskHub/semesters.json(같은 id 면 사용자 값).
//   시험 훅: DESKHUB_COURSES=<정규화 행 json>(Notion 을 부르지 않음) · DESKHUB_COURSES_DB=<db id>.
// 수업시간 파싱은 timetable 플러그인 tt.py 의 SLOT_RX·hhmm(1~7시는 오후)·parse_slots·slots_from_text(강의실 안 괄호 허용)를 옮긴 것.
// 색: Hub 토큰에 범주색이 없어 사람별 색 대신 같은 수업 묶기 + 이니셜 + 'Filter by person' 강조(결정 D-8). 적색 없음.

struct TTSlot: Codable, Hashable {
    var day: String
    var start: String
    var end: String
    var room: String = ""
}

/// 정규화 행 (DESKHUB_COURSES 파일 형식과 같음) — 담당교수 등 다른 키는 읽지 않는다
struct CourseRow: Codable, Hashable {
    var initials: String
    var course: String
    var kind: String
    var confirmed: Bool
    var slots: [TTSlot]
    enum CodingKeys: String, CodingKey { case initials = "init", course, kind, confirmed, slots }
    init(initials: String, course: String, kind: String, confirmed: Bool, slots: [TTSlot]) {
        self.initials = initials; self.course = course; self.kind = kind; self.confirmed = confirmed; self.slots = slots
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        initials = (try? c.decode(String.self, forKey: .initials)) ?? ""
        course = (try? c.decode(String.self, forKey: .course)) ?? ""
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "수강"
        confirmed = (try? c.decode(Bool.self, forKey: .confirmed)) ?? false
        slots = (try? c.decode([TTSlot].self, forKey: .slots)) ?? []
    }
}

struct SemesterInfo: Codable, Hashable {
    var label: String
    var start: String
    var end: String
    var makeupEnd: String?
    var holidays: [String]?
    enum CodingKeys: String, CodingKey { case label, start, end, makeupEnd = "makeup_end", holidays }
}

enum Timetable {
    /// Notion 🎓 Courses (결정 D-7 — Config 가 아니라 코드 상수)
    static let coursesDB = "b86b2c5e-1c58-4597-a031-dc53fd03fc05"
    static var dbID: String {
        if let v = ProcessInfo.processInfo.environment["DESKHUB_COURSES_DB"], !v.isEmpty { return v }
        return coursesDB
    }
    static var offlinePath: String? {
        guard let v = ProcessInfo.processInfo.environment["DESKHUB_COURSES"], !v.isEmpty else { return nil }
        return (v as NSString).expandingTildeInPath
    }
    static let cacheTTL: TimeInterval = 6 * 3600
    static let days = ["월", "화", "수", "목", "금", "토", "일"]
    static let kst: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Seoul")!; return c }()

    // MARK: 수업시간 파싱 (tt.py 옮김)

    private static let slotRX = try! NSRegularExpression(pattern:
        "(?<![가-힣A-Za-z])(?<days>[월화수목금토일](?:\\s*[,·/]?\\s*[월화수목금토일])*)\\s*(?:요일)?\\s*[\\(\\[]?\\s*"
        + "(?<h1>\\d{1,2})(?:[:.](?<m1>\\d{2})|\\s*시\\s*(?:(?<m1b>\\d{1,2})\\s*분)?)?"
        + "\\s*[-~–—]\\s*"
        + "(?<h2>\\d{1,2})(?:[:.](?<m2>\\d{2})|\\s*시\\s*(?:(?<m2b>\\d{1,2})\\s*분)?)?\\s*[\\)\\]]?")
    private static let enDays: [(String, String)] = [("\\b(?:Mon|Monday)\\b", "월"), ("\\b(?:Tue|Tues|Tuesday)\\b", "화"), ("\\b(?:Wed|Wednesday)\\b", "수"),
                                                     ("\\b(?:Thu|Thur|Thurs|Thursday)\\b", "목"), ("\\b(?:Fri|Friday)\\b", "금"), ("\\b(?:Sat|Saturday)\\b", "토"),
                                                     ("\\b(?:Sun|Sunday)\\b", "일")]

    /// 1~7시는 오후로 본다('3-5' → 15:00–17:00)
    static func hhmm(_ h: Int, _ m: Int) -> String {
        let hh = (1...7).contains(h) ? h + 12 : h
        return String(format: "%02d:%02d", hh, m)
    }
    /// parse_slots — 슬롯과 남은 글
    static func parseSlots(_ input: String) -> (slots: [TTSlot], rest: String) {
        var text = input
        for (rx, ko) in enDays { text = text.replacingOccurrences(of: rx, with: ko, options: [.regularExpression, .caseInsensitive]) }
        let ns = text as NSString
        var slots: [TTSlot] = [], spans: [NSRange] = []
        for m in slotRX.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            func g(_ n: String) -> String? { let r = m.range(withName: n); return r.location == NSNotFound ? nil : ns.substring(with: r) }
            guard let h1 = g("h1").flatMap(Int.init), let h2 = g("h2").flatMap(Int.init) else { continue }
            let start = hhmm(h1, Int(g("m1") ?? g("m1b") ?? "") ?? 0), end = hhmm(h2, Int(g("m2") ?? g("m2b") ?? "") ?? 0)
            guard start < end else { continue }
            for ch in g("days") ?? "" where days.contains(String(ch)) { slots.append(TTSlot(day: String(ch), start: start, end: end)) }
            spans.append(m.range)
        }
        var rest = text
        for r in spans.reversed() { rest = (rest as NSString).replacingCharacters(in: r, with: " ") }
        return (slots, rest)
    }
    /// slots_from_text — Notion '수업시간' 칸 '화 14:00-15:15 (43-1 201) · 목 14:00-15:15 (43-1 201)'. 강의실 안 괄호 허용 '(목암홀(500동))'
    static func slots(_ text: String) -> [TTSlot] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let split = try! NSRegularExpression(pattern: "\\s*[·/\\n]\\s*(?=[월화수목금토일])")
        let ns = text as NSString
        var parts: [String] = [], last = 0
        for m in split.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: last, length: m.range.location - last))); last = m.range.location + m.range.length
        }
        parts.append(ns.substring(from: last))
        var out: [TTSlot] = []
        for p in parts {
            let (ss, rest) = parseSlots(p)
            let r = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            var room = ""
            if let rr = r.range(of: "\\((.*)\\)\\s*$", options: .regularExpression) {
                room = String(r[rr]).trimmingCharacters(in: .whitespaces)
                room = String(room.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
            out += ss.map { var s = $0; s.room = room; return s }
        }
        return out
    }
    /// '수 14:00–16:50 (500-L308) · 목 …' (빈 슬롯 → 빈 글)
    static func slotsText(_ ss: [TTSlot]) -> String {
        ss.map { "\($0.day) \($0.start)–\($0.end)" + ($0.room.isEmpty ? "" : " (\($0.room))") }.joined(separator: " · ")
    }

    // MARK: Notion 행

    enum RowResult { case row(CourseRow), drop, unparsed }
    /// rows_from_notion 한 행 — 상태 '드랍' · 빈 칸은 drop, 수업시간을 못 읽으면 unparsed. 담당교수·과목번호·출처는 읽지 않는다
    static func row(_ p: [String: Any], aliases: [String: String]) -> RowResult {
        if NotionAPI.text(p, "상태") == "드랍" { return .drop }
        let course = NotionAPI.title(p).trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = NotionAPI.text(p, "이니셜").trimmingCharacters(in: .whitespaces).uppercased()
        let ini = (aliases[raw] ?? raw).uppercased()
        let time = NotionAPI.text(p, "수업시간")
        guard !course.isEmpty, !ini.isEmpty, !time.trimmingCharacters(in: .whitespaces).isEmpty else { return .drop }
        var ss = slots(time)
        guard !ss.isEmpty else { return .unparsed }
        let room = NotionAPI.text(p, "강의실").trimmingCharacters(in: .whitespaces)
        if !room.isEmpty { ss = ss.map { var s = $0; if s.room.isEmpty { s.room = room }; return s } }
        let kind = NotionAPI.text(p, "구분")
        return .row(CourseRow(initials: ini, course: course, kind: kind.isEmpty ? "수강" : kind, confirmed: NotionAPI.bool(p, "본인확인"), slots: ss))
    }

    // MARK: 학기

    /// 번들 + 사용자 파일 (같은 id 면 사용자 값). bundleURL 은 text-check 가 tsv 옆 Resources 로 준다
    static func loadSemesters(bundleURL: URL? = Bundle.main.url(forResource: "semesters", withExtension: "json"),
                              userURL: URL? = Config.directory.appendingPathComponent("semesters.json")) -> [String: SemesterInfo] {
        var out: [String: SemesterInfo] = [:]
        for u in [bundleURL, userURL].compactMap({ $0 }) {
            guard let d = try? Data(contentsOf: u), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let sems = o["semesters"] as? [String: Any] else { continue }
            for (id, v) in sems {
                guard let vd = try? JSONSerialization.data(withJSONObject: v), let s = try? JSONDecoder().decode(SemesterInfo.self, from: vd) else { continue }
                out[id] = s
            }
        }
        return out
    }
    nonisolated(unsafe) static var semesters: [String: SemesterInfo] = loadSemesters()

    static func ymd(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = kst.timeZone; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
    /// 오늘이 [start, makeup_end] 안인 학기 · 휴일인가. 없으면 nil('학기 밖')
    static func semester(on d: Date, in sems: [String: SemesterInfo] = semesters) -> (id: String, label: String, holiday: Bool)? {
        let t = ymd(d)
        for (id, s) in sems.sorted(by: { $0.key < $1.key }) where s.start <= t && t <= (s.makeupEnd ?? s.end) {
            return (id, s.label, (s.holidays ?? []).contains(t))
        }
        return nil
    }
    /// 그날 요일 '월'…'일'
    static func weekday(_ d: Date) -> String { ["일", "월", "화", "수", "목", "금", "토"][kst.component(.weekday, from: d) - 1] }

    // MARK: 묶음

    /// 같은 (과목, 요일, 시작, 끝) = 한 덩어리 — 이니셜을 모은다 (timetable 플러그인 '같은 수업 묶기')
    struct Block: Hashable, Identifiable {
        let course: String, day: String, start: String, end: String, room: String
        let initials: [String]
        var id: String { [course, day, start, end].joined(separator: "|") }
        func mine(_ me: String) -> Bool { !me.isEmpty && initials.contains(me.uppercased()) }
        func live(_ now: Date) -> Bool { let t = hm(now); return start <= t && t < end }
    }
    static func hm(_ d: Date) -> String {
        let c = kst.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
    static func blocks(_ rows: [CourseRow]) -> [Block] {
        var by: [String: (TTSlot, String, Set<String>)] = [:]
        var order: [String] = []
        for r in rows { for s in r.slots {
            let k = [r.course, s.day, s.start, s.end].joined(separator: "|")
            if by[k] == nil { by[k] = (s, r.course, []); order.append(k) }
            by[k]!.2.insert(r.initials)
            if by[k]!.0.room.isEmpty && !s.room.isEmpty { by[k]!.0.room = s.room }
        } }
        return order.compactMap { k in by[k].map { Block(course: $0.1, day: $0.0.day, start: $0.0.start, end: $0.0.end, room: $0.0.room, initials: $0.2.sorted()) } }
            .sorted { ($0.start, $0.end, $0.course) < ($1.start, $1.end, $1.course) }
    }
    /// 오늘 덩어리 — 휴일·학기 밖이면 빈 목록
    static func todayGroups(_ rows: [CourseRow], now: Date, sems: [String: SemesterInfo] = semesters) -> [Block] {
        guard let s = semester(on: now, in: sems), !s.holiday else { return [] }
        let d = weekday(now)
        return blocks(rows).filter { $0.day == d }
    }
    /// 요일별 덩어리 수 (월–금, 그리고 토·일은 있을 때만)
    static func weekCounts(_ rows: [CourseRow]) -> [(String, Int)] {
        let bs = blocks(rows)
        return days.compactMap { d in
            let n = bs.filter { $0.day == d }.count
            return (["토", "일"].contains(d) && n == 0) ? nil : (d, n)
        }
    }
    static func weekLine(_ rows: [CourseRow]) -> String { weekCounts(rows).map { "\($0.0) \($0.1)" }.joined(separator: " · ") }
    static func blockText(_ b: Block, now: Date) -> String {
        (b.live(now) ? "● " : "") + "\(b.start)–\(b.end) \(b.course) · " + b.initials.joined(separator: ",")
    }
    /// '오늘(목): 18:00–20:50 과목 · BHL,JYK / …' · '오늘(금): 휴일' · '오늘(토): 없음' · '학기 밖'
    static func todayLine(_ rows: [CourseRow], now: Date, sems: [String: SemesterInfo] = semesters) -> String {
        guard let s = semester(on: now, in: sems) else { return "학기 밖" }
        let head = "오늘(\(weekday(now))): "
        if s.holiday { return head + "휴일" }
        let g = todayGroups(rows, now: now, sems: sems)
        return head + (g.isEmpty ? "없음" : g.map { blockText($0, now: now) }.joined(separator: " / "))
    }

    // MARK: text-check (main.swift)

    /// tt-slots · tt-sem · tt-today — 화면과 같은 함수. 학기 파일 = <tsv 디렉터리>/../Resources/semesters.json
    static func check(_ kind: String, _ input: String, tsv: String) -> String {
        let sems = loadSemesters(bundleURL: URL(fileURLWithPath: tsv).deletingLastPathComponent().appendingPathComponent("../Resources/semesters.json").standardizedFileURL,
                                 userURL: nil)
        func kv(_ s: String) -> [String: String] {
            var o: [String: String] = [:]
            for part in s.components(separatedBy: ";") {
                let p = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                if p.count == 2 { o[p[0].trimmingCharacters(in: .whitespaces)] = p[1] }
            }
            return o
        }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = kst.timeZone
        func date(_ s: String) -> Date? {
            for fmt in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] { f.dateFormat = fmt; if let d = f.date(from: s) { return d } }
            return nil
        }
        switch kind {
        case "tt-slots": return slotsText(slots(input))
        case "tt-sem":
            guard let d = date(input) else { return "(입력 형식)" }
            guard let s = semester(on: d, in: sems) else { return "학기 밖" }
            return s.id + (s.holiday ? " 휴일" : "")
        case "tt-today":
            // 'now=yyyy-MM-ddTHH:mm;rows=이니셜/과목/수업시간|…'
            let k = kv(input)
            guard let now = date(k["now"] ?? "") else { return "(입력 형식)" }
            let rows: [CourseRow] = (k["rows"] ?? "").components(separatedBy: "|").compactMap { r in
                let p = r.components(separatedBy: "/")
                guard p.count >= 3 else { return nil }
                let ss = slots(p[2...].joined(separator: "/"))
                return ss.isEmpty ? nil : CourseRow(initials: p[0], course: p[1], kind: "수강", confirmed: true, slots: ss)
            }
            return todayLine(rows, now: now, sems: sems)
        default: return "(모르는 종류 \(kind))"
        }
    }
}

// MARK: - 모델

extension NotionHubModel {
    /// refresh 끝(loadMetrics 뒤) — 학기 안일 때만, 6시간 캐시. 실패면 이전 행을 그대로 두고 coursesNote 에 원인(적색 아님)
    func loadCourses(_ api: NotionAPI?) async {
        guard let sem = Timetable.semester(on: now) else { coursesSemester = nil; return }
        if let path = Timetable.offlinePath {
            let rows: [CourseRow]? = await Task.detached(priority: .utility) {
                guard let d = FileManager.default.contents(atPath: path) else { return nil }
                if let a = try? JSONDecoder().decode([CourseRow].self, from: d) { return a }
                struct W: Decodable { var rows: [CourseRow] }
                return (try? JSONDecoder().decode(W.self, from: d))?.rows
            }.value
            coursesSource = "fixture"; coursesSemester = sem.id
            if let rows {
                courses = rows.filter { !$0.course.isEmpty && !$0.initials.isEmpty && !$0.slots.isEmpty }
                coursesUnparsed = rows.count - courses.count; coursesNote = nil; coursesFetchedAt = Date()
            } else { coursesNote = "Courses 파일을 읽지 못함" }
            return
        }
        if coursesSemester == sem.id, let at = coursesFetchedAt, Date().timeIntervalSince(at) < Timetable.cacheTTL { return }
        guard let api else { coursesNote = "Notion 토큰 없음"; return }
        do {
            NotionQueryStats.addCourses()
            let raw = try await api.query(db: Timetable.dbID, body: ["page_size": 100, "filter": ["property": "학기", "select": ["equals": sem.id]]], maxPages: 1)
            var rows: [CourseRow] = [], bad = 0
            for p in raw {
                switch Timetable.row(p, aliases: cfg.initialsAliases) {
                case .row(let r): rows.append(r)
                case .unparsed: bad += 1
                case .drop: break
                }
            }
            courses = rows; coursesUnparsed = bad; coursesNote = nil
            coursesFetchedAt = Date(); coursesSemester = sem.id; coursesSource = "Notion"
        } catch {
            coursesNote = "Courses 를 읽지 못함 · " + error.localizedDescription
        }
    }

    /// text.txt [Timetable]
    func timetableDumpLines() -> [String] {
        guard let sem = Timetable.semester(on: now) else { return ["학기 밖 · 출처 —"] + (coursesNote.map { ["오류 · " + $0] } ?? []) }
        let names = Set(courses.map(\.course)).count, people = Set(courses.map(\.initials)).count
        var out = ["학기 \(sem.id) · 출처 \(coursesSource) · 과목 \(names) · 행 \(courses.count) · 사람 \(people) · 못 읽은 행 \(coursesUnparsed) · " + (sem.holiday ? "휴일" : "휴일 아님")]
        out.append(Timetable.todayLine(courses, now: now))
        out.append("주간: " + Timetable.weekLine(courses))
        if let n = coursesNote { out.append("오류 · " + n) }
        return out
    }
}

// MARK: - 사람 고르기 칩 (Timetable 화면·관제탑 roster 공용)

/// 'Filter by person' 라벨 + 이니셜 칩. 고르면 ink 채움, 다시 누르면 해제, 내 칩은 ink 1.5pt 테두리.
/// 폭이 모자라면 라벨 → 'Filter' → 라벨 없음 (ViewThatFits). badge = 칩 앞 작은 아이콘(C5 상태 아이콘)
struct PersonFilterChips: View {
    let people: [String]
    @Binding var selected: String?
    var me: String = HubPrefs.me
    var fontSize: CGFloat = 12
    var chipHeight: CGFloat? = nil
    var badge: ((String) -> AnyView)? = nil
    var help: ((String) -> String)? = nil
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(label: "Filter by person")
            row(label: "Filter")
            row(label: nil)
        }
    }
    private func row(label: String?) -> some View {
        HStack(spacing: 5) {
            if let label { Text(label).font(.hub(10.5)).foregroundStyle(Hub.text3).lineLimit(1).fixedSize() }
            ForEach(people, id: \.self) { ini in chip(ini) }
        }
        .fixedSize()
    }
    private func chip(_ ini: String) -> some View {
        let on = selected == ini
        let mine = !me.isEmpty && ini.uppercased() == me.uppercased()
        return Button { selected = on ? nil : ini } label: {
            HStack(spacing: 3) {
                if let b = badge { b(ini) }
                Text(ini).font(.hub(fontSize, weight: .bold, design: .rounded))
            }
            .padding(.horizontal, 7).padding(.vertical, 2)
            .frame(height: chipHeight)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Hub.ink : Hub.fillNeutral))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(mine ? Hub.ink : Color.clear, lineWidth: 1.5))
            .foregroundStyle(on ? Hub.onAccent : Hub.text)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help?(ini) ?? ((mine ? "나 (\(ini))" : ini) + (on ? " · 다시 누르면 해제" : " · 이 사람만 강조")))
    }
}

// MARK: - 허브 Classes 카드 (열2 Upcoming 아래)

struct ClassesCard: View {
    @ObservedObject var model: NotionHubModel
    @Environment(\.cardStyle) private var cs
    static let maxRows = 4

    var body: some View {
        let sem = Timetable.semester(on: model.now)
        VStack(alignment: .leading, spacing: cs.gap) {
            if sem == nil {
                // 학기 밖 — 제목 + 한 줄로 접힘
                HStack(spacing: 8) {
                    SectionTitle(card: "classes").fixedSize()
                    Text("학기 밖").font(.hub(cs.aux)).foregroundStyle(Hub.text2).lineLimit(1)
                    Spacer(minLength: 0)
                }
            } else {
                SectionTitle(card: "classes", trailing: "Timetable") { ViewModeStore.shared.mode = .timetable }
                VStack(alignment: .leading, spacing: 0) {
                    content(sem!)
                    CardFooter(caption: CardMetas.caption("classes", model))
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
            }
        }
    }

    @ViewBuilder private func content(_ sem: (id: String, label: String, holiday: Bool)) -> some View {
        let me = HubPrefs.me
        if model.courses.isEmpty, model.coursesNote != nil {
            Text("Courses 를 읽지 못함").font(.hub(cs.aux)).foregroundStyle(Hub.text2).lineLimit(1)
                .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV).help(model.coursesNote ?? "")
        } else {
            let today = Timetable.todayGroups(model.courses, now: model.now)
            if sem.holiday {
                line("오늘 휴일")
            } else if today.isEmpty {
                line("오늘 수업 없음")
            } else {
                ForEach(today.prefix(Self.maxRows)) { b in blockRow(b, me: me) }
                if today.count > Self.maxRows { line("+\(today.count - Self.maxRows)") }
            }
            let names = Set(model.courses.map(\.course)).count
            Text("이번 주 \(names)과목 · " + Timetable.weekLine(model.courses))
                .font(.hub(cs.tag)).foregroundStyle(Hub.text2).lineLimit(1).truncationMode(.tail)
                .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
                .help(sem.label + (model.coursesUnparsed > 0 ? " · 못 읽은 행 \(model.coursesUnparsed)" : ""))
        }
    }

    private func line(_ t: String) -> some View {
        Text(t).font(.hub(cs.aux)).foregroundStyle(Hub.text2).lineLimit(1)
            .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func blockRow(_ b: Timetable.Block, me: String) -> some View {
        let mine = b.mine(me), live = b.live(model.now)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(live ? "●" : " ").font(.hub(cs.tag)).foregroundStyle(Hub.ink).frame(width: cs.col(10))
            Text("\(b.start)–\(b.end)").font(.hub(cs.aux, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(Hub.text2).lineLimit(1).fixedSize()
            Text(b.course).font(.hub(cs.body, weight: mine ? .semibold : .regular)).foregroundStyle(mine ? Hub.ink : Hub.text).lineLimit(1)
            Spacer(minLength: 4)
            Text(b.initials.joined(separator: ",")).font(.hub(cs.tag, weight: .semibold, design: .rounded)).foregroundStyle(Hub.text2).lineLimit(1).fixedSize()
            if !b.room.isEmpty { Text(b.room).font(.hub(cs.tag)).foregroundStyle(Hub.text3).lineLimit(1).fixedSize() }
        }
        .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
        .help("\(b.day) \(b.start)–\(b.end) \(b.course) · \(b.initials.joined(separator: ","))" + (b.room.isEmpty ? "" : " · \(b.room)") + (live ? " · 진행 중" : ""))
    }
}

// MARK: - Timetable 화면 (--view timetable, 숫자 키 9)

struct TimetableView: View {
    @ObservedObject var model: NotionHubModel
    @State private var person: String? = nil

    var body: some View {
        let sem = Timetable.semester(on: model.now)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Timetable" + (sem.map { " · " + $0.label } ?? "")).font(.hub(18, weight: .bold)).foregroundStyle(Hub.text).lineLimit(1)
                Spacer(minLength: 8)
                if sem != nil { PersonFilterChips(people: Array(Set(model.courses.map(\.initials))).sorted(), selected: $person) }
            }
            if sem == nil {
                Text("학기 밖 — 학기 정보가 없습니다").font(.hub(14)).foregroundStyle(Hub.text2)
                Spacer(minLength: 0)
            } else if model.courses.isEmpty {
                Text(model.coursesNote ?? "수업 없음").font(.hub(14)).foregroundStyle(Hub.text2)
                Spacer(minLength: 0)
            } else {
                grid(sem!)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Hub.card)
    }

    private func minutes(_ s: String) -> Int { let p = s.split(separator: ":").compactMap { Int($0) }; return p.count == 2 ? p[0] * 60 + p[1] : 0 }

    private func grid(_ sem: (id: String, label: String, holiday: Bool)) -> some View {
        let bs = Timetable.blocks(model.courses)
        let dayCols = Timetable.days.filter { d in !["토", "일"].contains(d) || bs.contains { $0.day == d } }
        let lo = ((bs.map { minutes($0.start) }.min() ?? 540) / 60) * 60
        let hi = Int((Double(bs.map { minutes($0.end) }.max() ?? 1080) / 60).rounded(.up)) * 60
        let today = Timetable.weekday(model.now)
        let me = HubPrefs.me
        let nowMin = minutes(Timetable.hm(model.now))
        return GeometryReader { g in
            let timeW: CGFloat = 46, headH: CGFloat = 24
            let colW = (g.size.width - timeW) / CGFloat(max(dayCols.count, 1))
            let perMin = (g.size.height - headH) / CGFloat(max(hi - lo, 60))
            ZStack(alignment: .topLeading) {
                // 30분 줄 · 시각
                ForEach(Array(stride(from: lo, through: hi, by: 30)), id: \.self) { m in
                    let y = headH + CGFloat(m - lo) * perMin
                    Rectangle().fill(Hub.divider.opacity(m % 60 == 0 ? 1 : 0.45)).frame(width: g.size.width - timeW, height: 1).offset(x: timeW, y: y)
                    if m % 60 == 0 && m < hi {
                        Text(String(format: "%02d:00", m / 60)).font(.hub(10.5).monospacedDigit()).foregroundStyle(Hub.text3).offset(x: 4, y: y - 6)
                    }
                }
                // 요일 머리 — 오늘 열은 ink
                ForEach(Array(dayCols.enumerated()), id: \.element) { i, d in
                    Text(d).font(.hub(13, weight: d == today ? .bold : .semibold)).foregroundStyle(d == today ? Hub.ink : Hub.text2)
                        .frame(width: colW, height: headH).offset(x: timeW + CGFloat(i) * colW, y: 0)
                }
                // 덩어리 — 겹치면 나란히
                ForEach(Array(dayCols.enumerated()), id: \.element) { i, d in
                    let lanes = Self.lanes(bs.filter { $0.day == d }, minutes: minutes)
                    ForEach(lanes) { p in
                        let x = timeW + CGFloat(i) * colW + 2 + CGFloat(p.lane) * (colW - 4) / CGFloat(p.of)
                        let y = headH + CGFloat(minutes(p.block.start) - lo) * perMin
                        let h = max(CGFloat(minutes(p.block.end) - minutes(p.block.start)) * perMin - 2, 14)
                        block(p.block, me: me).frame(width: (colW - 4) / CGFloat(p.of) - 2, height: h).offset(x: x, y: y)
                    }
                }
                // 지금 시각선 — 오늘 열, ink 1pt (휴일·범위 밖이면 없음)
                if !sem.holiday, let ti = dayCols.firstIndex(of: today), nowMin >= lo, nowMin <= hi {
                    Rectangle().fill(Hub.ink).frame(width: colW, height: 1)
                        .offset(x: timeW + CGFloat(ti) * colW, y: headH + CGFloat(nowMin - lo) * perMin)
                }
            }
        }
    }

    struct Placed: Identifiable { let block: Timetable.Block; let lane: Int; let of: Int; var id: String { block.id } }
    /// 하루 덩어리 → (덩어리, 칸 번호, 겹친 묶음의 칸 수)
    static func lanes(_ bs: [Timetable.Block], minutes: (String) -> Int) -> [Placed] {
        let sorted = bs.sorted { minutes($0.start) < minutes($1.start) }
        var out: [Placed] = []
        var cluster: [(Timetable.Block, Int)] = [], laneEnds: [Int] = [], clusterEnd = -1
        func flush() { let n = max(laneEnds.count, 1); out += cluster.map { Placed(block: $0.0, lane: $0.1, of: n) }; cluster = []; laneEnds = [] }
        for b in sorted {
            let s = minutes(b.start), e = minutes(b.end)
            if s >= clusterEnd && !cluster.isEmpty { flush() }
            if let i = laneEnds.firstIndex(where: { $0 <= s }) { laneEnds[i] = e; cluster.append((b, i)) }
            else { laneEnds.append(e); cluster.append((b, laneEnds.count - 1)) }
            clusterEnd = max(clusterEnd, e)
        }
        if !cluster.isEmpty { flush() }
        return out
    }

    private func block(_ b: Timetable.Block, me: String) -> some View {
        let mine = b.mine(me)
        let dim = person.map { !b.initials.contains($0) } ?? false
        return VStack(alignment: .leading, spacing: 2) {
            Text(b.course).font(.hub(12, weight: mine ? .semibold : .medium)).foregroundStyle(Hub.text).lineLimit(2)
            Text(b.initials.joined(separator: ",")).font(.hub(11, weight: .semibold, design: .rounded)).foregroundStyle(mine ? Hub.ink : Hub.text2).lineLimit(1)
            if !b.room.isEmpty { Text(b.room).font(.hub(10.5)).foregroundStyle(Hub.text3).lineLimit(1) }
            Spacer(minLength: 0)
        }
        .padding(5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Hub.surface))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(mine ? Hub.ink : Hub.divider, lineWidth: mine ? 1.5 : 1))
        .opacity(dim ? 0.35 : 1)
        .help("\(b.day) \(b.start)–\(b.end) \(b.course) · \(b.initials.joined(separator: ","))" + (b.room.isEmpty ? "" : " · \(b.room)"))
    }
}
