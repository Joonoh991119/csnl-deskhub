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
// 0.43.0 C3 (#48 #47): Timetable.prepare 한 곳 — 구분 '조교' 행은 빼고(청강은 남김), 같은 과목(정규화 이름)을 한 수업으로 합친다(다수 슬롯).
//   Classes 카드·Timetable 화면·수업 중 상태·Metrics 가 같은 결과(model.courses)를 읽는다. Notion 원본은 고치지 않는다.
// 색: Hub 토큰에 범주색이 없어 사람별 색 대신 같은 수업 묶기 + 이니셜 + 'Filter by person' 강조(결정 D-8). 적색 없음.
// 0.43.1 C1 (#53): 내 수업 = 이 맥 이니셜(HubPrefs 의 me, 별칭 풀기 — Timetable.meKey · model.timetableMe)이 덩어리 이니셜에 있음 — 병합 인원 포함·조교 제외.

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
    /// 병합 메모 (0.43.0 C3) — 이 사람이 적은 시간이 대표와 달라 대표 슬롯으로 바꿨을 때 '입력 시간 다름: SMJ 목 18:00–20:00'. 선택 키(기본 "")
    var note: String = ""
    enum CodingKeys: String, CodingKey { case initials = "init", course, kind, confirmed, slots, note }
    init(initials: String, course: String, kind: String, confirmed: Bool, slots: [TTSlot], note: String = "") {
        self.initials = initials; self.course = course; self.kind = kind; self.confirmed = confirmed; self.slots = slots; self.note = note
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        initials = (try? c.decode(String.self, forKey: .initials)) ?? ""
        course = (try? c.decode(String.self, forKey: .course)) ?? ""
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "수강"
        confirmed = (try? c.decode(Bool.self, forKey: .confirmed)) ?? false
        slots = (try? c.decode([TTSlot].self, forKey: .slots)) ?? []
        note = (try? c.decode(String.self, forKey: .note)) ?? ""
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

    // MARK: 정리 — 조교 제외 · 같은 과목 합치기 (0.43.0 C3, #48 #47)

    struct Prepared { var rows: [CourseRow]; var ta: Int; var notes: [String] }
    /// 과목 키 — 전각→반각 · 소문자 · 괄호 모양 통일(［］【】〔〕（） → ()) · 모든 공백 제거. 괄호 안 글은 지우지 않는다(분반 표기 보호, 결정 D-4)
    static func courseKey(_ name: String) -> String {
        var t = name.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? name
        t = t.lowercased()
        for (a, b) in [("［", "("), ("］", ")"), ("【", "("), ("】", ")"), ("〔", "("), ("〕", ")"), ("（", "("), ("）", ")"), ("[", "("), ("]", ")")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t.filter { !$0.isWhitespace }
    }
    private static func minutes(_ s: String) -> Int { let p = s.split(separator: ":").compactMap { Int($0) }; return p.count == 2 ? p[0] * 60 + p[1] : 0 }
    /// 서명 — 슬롯 (요일, 시작, 끝) 정렬 목록(강의실 없이)
    private static func signature(_ ss: [TTSlot]) -> [String] {
        Array(Set(ss.map { "\(days.firstIndex(of: $0.day) ?? 9)|\($0.start)|\($0.end)" })).sorted()
    }
    /// 순수 함수. ① 구분 '조교' 행 제외(본인·타인 모두, 청강은 남김 — 결정 D-5) ② 같은 과목 키 안에서 대표 서명 = 사람 수 많은 것 → 본인확인 많은 것 →
    /// 총 수업 시간 긴 것 → 먼저 나온 것. 대표와 요일이 하나라도 겹치는 다른 서명 행은 대표 슬롯(강의실 포함)으로 바꾸고 note 를 단다.
    /// 요일이 전혀 겹치지 않으면 다른 분반으로 보고 그대로(결정 D-3). 표시 과목명 = 대표 첫 행의 원래 철자
    static func prepare(_ raw: [CourseRow]) -> Prepared {
        let ta = raw.filter { $0.kind.trimmingCharacters(in: .whitespaces) == "조교" }.count
        var rows = raw.filter { $0.kind.trimmingCharacters(in: .whitespaces) != "조교" }
        var groups: [String: [Int]] = [:], keyOrder: [String] = []
        for (i, r) in rows.enumerated() {
            let k = courseKey(r.course)
            if groups[k] == nil { keyOrder.append(k) }
            groups[k, default: []].append(i)
        }
        var notes: [String] = []
        for k in keyOrder {
            let idx = groups[k]!
            // 서명별 (사람, 본인확인 수, 총 분, 첫 위치)
            var sigs: [[String]: (people: Set<String>, confirmed: Int, total: Int, first: Int)] = [:]
            for i in idx {
                let sig = signature(rows[i].slots)
                var e = sigs[sig] ?? ([], 0, rows[i].slots.reduce(0) { $0 + minutes($1.end) - minutes($1.start) }, i)
                e.people.insert(rows[i].initials); if rows[i].confirmed { e.confirmed += 1 }
                sigs[sig] = e
            }
            guard let best = sigs.max(by: { a, b in
                let x = a.value, y = b.value
                if x.people.count != y.people.count { return x.people.count < y.people.count }
                if x.confirmed != y.confirmed { return x.confirmed < y.confirmed }
                if x.total != y.total { return x.total < y.total }
                return x.first > y.first
            }) else { continue }
            let repRow = rows[best.value.first]
            let repDays = Set(repRow.slots.map(\.day))
            // 대표 슬롯 — 대표 서명 행들 중 강의실이 있는 값을 채운다
            var repSlots = repRow.slots
            for i in idx where signature(rows[i].slots) == best.key {
                for (j, s) in repSlots.enumerated() where s.room.isEmpty {
                    if let o = rows[i].slots.first(where: { $0.day == s.day && $0.start == s.start && $0.end == s.end && !$0.room.isEmpty }) { repSlots[j].room = o.room }
                }
            }
            for i in idx {
                let sig = signature(rows[i].slots)
                if sig == best.key { rows[i].course = repRow.course; continue }
                guard !repDays.isDisjoint(with: rows[i].slots.map(\.day)) else { continue }   // 다른 분반
                let before = slotsText(rows[i].slots.map { TTSlot(day: $0.day, start: $0.start, end: $0.end) })
                let note = "입력 시간 다름: \(rows[i].initials) \(before)"
                notes.append(note + " → " + slotsText(repSlots.map { TTSlot(day: $0.day, start: $0.start, end: $0.end) }) + " (\(repRow.course))")
                rows[i].course = repRow.course; rows[i].slots = repSlots; rows[i].note = note
            }
        }
        return Prepared(rows: rows, ta: ta, notes: notes)
    }

    // MARK: 묶음

    /// 같은 (과목, 요일, 시작, 끝) = 한 덩어리 — 이니셜을 모은다 (timetable 플러그인 '같은 수업 묶기')
    struct Block: Hashable, Identifiable {
        let course: String, day: String, start: String, end: String, room: String
        let initials: [String]
        /// 같은 덩어리 행들의 병합 메모(중복 없이 정렬) — 도움말에만 (0.43.0 C3)
        var notes: [String] = []
        var id: String { [course, day, start, end].joined(separator: "|") }
        func mine(_ me: String) -> Bool { !me.isEmpty && initials.contains(me.uppercased()) }
        func live(_ now: Date) -> Bool { let t = hm(now); return start <= t && t < end }
    }
    static func hm(_ d: Date) -> String {
        let c = kst.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
    static func blocks(_ rows: [CourseRow]) -> [Block] {
        var by: [String: (TTSlot, String, Set<String>, Set<String>)] = [:]
        var order: [String] = []
        for r in rows { for s in r.slots {
            let k = [r.course, s.day, s.start, s.end].joined(separator: "|")
            if by[k] == nil { by[k] = (s, r.course, [], []); order.append(k) }
            by[k]!.2.insert(r.initials)
            if !r.note.isEmpty { by[k]!.3.insert(r.note) }
            if by[k]!.0.room.isEmpty && !s.room.isEmpty { by[k]!.0.room = s.room }
        } }
        return order.compactMap { k in by[k].map { Block(course: $0.1, day: $0.0.day, start: $0.0.start, end: $0.0.end, room: $0.0.room, initials: $0.2.sorted(), notes: $0.3.sorted()) } }
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
    /// 내 수업이면 '★ ', 진행 중이면 '● ' 를 앞에 (★ 가 맨 앞 — 0.43.1 C1, #53). me = 정본 이니셜(meKey 결과), 빈 값이면 ★ 없음
    static func blockText(_ b: Block, now: Date, me: String = "") -> String {
        (b.mine(me) ? "★ " : "") + (b.live(now) ? "● " : "") + "\(b.start)–\(b.end) \(b.course) · " + b.initials.joined(separator: ",")
    }
    /// '오늘(목): 18:00–20:50 과목 · BHL,JYK / …' · '오늘(금): 휴일' · '오늘(토): 없음' · '학기 밖'
    static func todayLine(_ rows: [CourseRow], now: Date, sems: [String: SemesterInfo] = semesters, me: String = "") -> String {
        guard let s = semester(on: now, in: sems) else { return "학기 밖" }
        let head = "오늘(\(weekday(now))): "
        if s.holiday { return head + "휴일" }
        let g = todayGroups(rows, now: now, sems: sems)
        return head + (g.isEmpty ? "없음" : g.map { blockText($0, now: now, me: me) }.joined(separator: " / "))
    }

    // MARK: 내 수업 (0.43.1 C1, #53)

    /// 판정 원천 한 곳 — 이 맥 이니셜을 별칭으로 풀어 정본 이니셜로(trim → 별칭 → 대문자, 빈 값이면 ""). Block.mine 은 정확 일치 그대로
    static func meKey(_ me: String, aliases: [String: String]) -> String { FollowupLogic.canon(me, aliases: aliases) }
    /// 내 덩어리 — 요일(days 순) → 시작 → 끝 → 과목
    static func mineBlocks(_ rows: [CourseRow], me: String) -> [Block] {
        blocks(rows).filter { $0.mine(me) }.sorted { a, b in
            let da = days.firstIndex(of: a.day) ?? 9, db = days.firstIndex(of: b.day) ?? 9
            return (da, a.start, a.end, a.course) < (db, b.start, b.end, b.course)
        }
    }
    /// '내 수업: — (이니셜 없음)' | '내 수업: 없음' | '내 수업: <요일> <시작>–<끝> <과목> / …'
    static func mineLine(_ rows: [CourseRow], me: String) -> String {
        if me.isEmpty { return "내 수업: — (이니셜 없음)" }
        let bs = mineBlocks(rows, me: me)
        return "내 수업: " + (bs.isEmpty ? "없음" : bs.map { "\($0.day) \($0.start)–\($0.end) \($0.course)" }.joined(separator: " / "))
    }

    // MARK: text-check (main.swift)

    /// text-check 행 'BHL/과목/수업시간[@구분]|…' → CourseRow (구분 없으면 '수강', 본인확인 true). tt-today · tt-merge · mstatus class 공용 (0.43.0 C3)
    static func fixtureRows(_ s: String) -> [CourseRow] {
        s.components(separatedBy: "|").compactMap { r in
            let p = r.components(separatedBy: "/")
            guard p.count >= 3 else { return nil }
            var time = p[2...].joined(separator: "/"), kind = "수강"
            if let at = time.range(of: "@", options: .backwards) { kind = String(time[at.upperBound...]); time = String(time[..<at.lowerBound]) }
            let ss = slots(time)
            return ss.isEmpty ? nil : CourseRow(initials: p[0], course: p[1], kind: kind, confirmed: true, slots: ss)
        }
    }

    /// tt-slots · tt-sem · tt-today · tt-merge · tt-mine — 화면과 같은 함수. 학기 파일 = <tsv 디렉터리>/../Resources/semesters.json
    /// 선택 키 me=(0.43.1 C1, #53) — aliases 로 풀어 내 수업 판정. 없으면 지금 출력 그대로
    static func check(_ kind: String, _ input: String, tsv: String, aliases: [String: String] = [:]) -> String {
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
            // 'now=yyyy-MM-ddTHH:mm;rows=이니셜/과목/수업시간[@구분]|…' — 앱과 같이 prepare 를 거친다 (0.43.0 C3)
            let k = kv(input)
            guard let now = date(k["now"] ?? "") else { return "(입력 형식)" }
            return todayLine(prepare(fixtureRows(k["rows"] ?? "")).rows, now: now, sems: sems, me: meKey(k["me"] ?? "", aliases: aliases))
        case "tt-merge":
            // '[me=;]rows=…' → 모든 덩어리를 요일·시작 순으로 '[★ ]<요일> <시작>–<끝> <과목> · <이니셜,…>[ [<note>; …]]' 를 ' / ' 로 (0.43.0 C3 · ★ 0.43.1 C1)
            let k = kv(input)
            let me = meKey(k["me"] ?? "", aliases: aliases)
            let p = prepare(fixtureRows(k["rows"] ?? ""))
            return blocks(p.rows).sorted { a, b in
                let da = days.firstIndex(of: a.day) ?? 9, db = days.firstIndex(of: b.day) ?? 9
                return (da, a.start, a.end, a.course) < (db, b.start, b.end, b.course)
            }.map { (b: Block) -> String in
                let star: String = b.mine(me) ? "★ " : ""
                let note: String = b.notes.isEmpty ? "" : " [" + b.notes.joined(separator: "; ") + "]"
                return star + "\(b.day) \(b.start)–\(b.end) \(b.course) · " + b.initials.joined(separator: ",") + note
            }
            .joined(separator: " / ")
        case "tt-mine":
            // '[me=;]rows=…' → prepare 뒤 mineLine (0.43.1 C1, #53)
            let k = kv(input)
            return mineLine(prepare(fixtureRows(k["rows"] ?? "")).rows, me: meKey(k["me"] ?? "", aliases: aliases))
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
                let kept = rows.filter { !$0.course.isEmpty && !$0.initials.isEmpty && !$0.slots.isEmpty }
                let p = Timetable.prepare(kept); courses = p.rows   // 조교 제외·같은 과목 합치기 (0.43.0 C3)
                coursesTA = p.ta; coursesMergeNotes = p.notes
                coursesUnparsed = rows.count - kept.count; coursesNote = nil; coursesFetchedAt = Date()
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
            let p = Timetable.prepare(rows); courses = p.rows
            coursesTA = p.ta; coursesMergeNotes = p.notes; coursesUnparsed = bad; coursesNote = nil
            coursesFetchedAt = Date(); coursesSemester = sem.id; coursesSource = "Notion"
        } catch {
            coursesNote = "Courses 를 읽지 못함 · " + error.localizedDescription
        }
    }

    /// 이 맥 이니셜의 정본 — 격자·Classes 카드·덤프가 같은 값으로 내 수업을 고른다 (0.43.1 C1, #53)
    var timetableMe: String { Timetable.meKey(HubPrefs.me, aliases: cfg.initialsAliases) }

    /// text.txt [Timetable]
    func timetableDumpLines() -> [String] {
        guard let sem = Timetable.semester(on: now) else { return ["학기 밖 · 출처 —"] + (coursesNote.map { ["오류 · " + $0] } ?? []) }
        let names = Set(courses.map(\.course)).count, people = Set(courses.map(\.initials)).count
        let me = timetableMe
        var out = ["학기 \(sem.id) · 출처 \(coursesSource) · 과목 \(names) · 행 \(courses.count) · 사람 \(people) · 못 읽은 행 \(coursesUnparsed) · " + (sem.holiday ? "휴일" : "휴일 아님")
                   + " · 조교 제외 \(coursesTA) · 병합 \(coursesMergeNotes.count)"
                   + " · 나 \(me.isEmpty ? "—" : me) · 내 수업 \(Timetable.mineBlocks(courses, me: me).count)"]
        out.append(Timetable.todayLine(courses, now: now, me: me))
        out.append("주간: " + Timetable.weekLine(courses))
        out.append(Timetable.mineLine(courses, me: me))
        out += coursesMergeNotes
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
                // 첫·끝 행의 내 수업 막대가 둥근 모서리 밖으로 나가지 않게 카드 쪽에서 자른다 (0.43.2 C2, #54)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    @ViewBuilder private func content(_ sem: (id: String, label: String, holiday: Bool)) -> some View {
        let me = model.timetableMe
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

    /// windows.txt choices 'classes-bar <막대>/<행>pt' (0.43.2 C2) — 막대 = 행 − 4pt
    private static func recordBar(_ h: CGFloat) {
        guard h > 0 else { return }
        let row = Int(h.rounded())
        MainActor.assumeIsolated { LayoutChoice.record("classes-bar", "\(row - 4)/\(row)pt") }
    }

    private func blockRow(_ b: Timetable.Block, me: String) -> some View {
        let mine = b.mine(me), live = b.live(model.now)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(live ? "●" : " ").font(.hub(cs.tag)).foregroundStyle(Hub.ink).frame(width: cs.col(10))
            Text("\(b.start)–\(b.end)").font(.hub(cs.aux, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(Hub.text2).lineLimit(1).fixedSize()
            Text(b.course).font(.hub(cs.body, weight: mine ? .semibold : .regular)).foregroundStyle(mine ? Hub.ink : Hub.text).lineLimit(1)
            Spacer(minLength: 4)
            Text(b.initials.joined(separator: ",")).font(.hub(cs.tag, weight: .semibold, design: .rounded)).foregroundStyle(mine ? Hub.ink : Hub.text2).lineLimit(1).fixedSize()
            if !b.room.isEmpty { Text(b.room).font(.hub(cs.tag)).foregroundStyle(Hub.text3).lineLimit(1).fixedSize() }
        }
        .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
        // 내 행 왼쪽 2pt ink 막대 — 안내판 '내 것' 막대와 같은 폭, 채움 없음 (0.43.1 C3, #53). 높이 = 행 − 4pt(위아래 2pt, 이웃 내 행과 4pt 틈),
        // 둥근 모서리는 카드 clipShape 가 자른다 (0.43.2 C2, #54 — 0.43.1 은 위아래 10pt 라 막대가 ≈9pt 로 짧았음)
        .overlay(alignment: .leading) { if mine { Rectangle().fill(Hub.ink).frame(width: 2).padding(.vertical, 2) } }
        .background { if mine { GeometryReader { g in Color.clear.onChange(of: g.size.height, initial: true) { _, h in Self.recordBar(h) } } } }
        .help("\(b.day) \(b.start)–\(b.end) \(b.course) · \(b.initials.joined(separator: ","))" + (b.room.isEmpty ? "" : " · \(b.room)") + (live ? " · 진행 중" : "") + (mine ? " · 내 수업" : "")
              + (b.notes.isEmpty ? "" : "\n" + b.notes.joined(separator: "\n")))
        .layoutChoice(mine ? "classes-mine:\(b.start)" : nil, b.course)
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
                if sem != nil { PersonFilterChips(people: Array(Set(model.courses.map(\.initials))).sorted(), selected: $person, me: model.timetableMe) }
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
        let me = model.timetableMe
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
        .padding(.leading, mine ? 3 : 0)   // 내 칸: 왼쪽 막대와 글자가 겹치지 않게 (0.43.1 C2, #53)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Hub.surface))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(mine ? Hub.ink : Hub.divider, lineWidth: mine ? 2 : 1))
        // 내 칸 왼쪽 ink 막대 — 위아래 6pt(모서리 반지름) 안쪽이라 clip 없이 둥근 모서리 밖으로 안 나감. 바탕 채움 없음(대비 하한, 결정 D-2)
        .overlay(alignment: .leading) { if mine { Rectangle().fill(Hub.ink).frame(width: 3).padding(.vertical, 6) } }
        .opacity(dim ? 0.35 : 1)
        .help("\(b.day) \(b.start)–\(b.end) \(b.course) · \(b.initials.joined(separator: ","))" + (b.room.isEmpty ? "" : " · \(b.room)") + (mine ? " · 내 수업" : "")
              + (b.notes.isEmpty ? "" : "\n" + b.notes.joined(separator: "\n")))
        .layoutChoice(mine ? "tt-mine:\(b.day)\(b.start)" : nil, b.course)
    }
}
