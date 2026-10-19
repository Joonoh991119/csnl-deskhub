import SwiftUI
import AppKit

// MARK: - 멤버 상태 아이콘 (0.42.0 C5, R2 — 랩장 JOP 10-19 '실험중/수업중/휴가중 … 미팅중도 추가')
// 데이터 계약 (계획 0.42.0 §2 '멤버 상태'):
//   입력 ① 오늘 캘린더(CSNL·SLab ICS/EventKit) ② Notion Schedule & Events 오늘(시각만 있으면 끝 = 시작 + 60분, 결정 D-6)
//        ③ SLab 오늘 행(실험자 이니셜·프로젝트·'HH:mm - HH:mm'·상태) ④ 오늘 수업 슬롯(Timetable, 휴일 제외) ⑤ member_links.json away 라벨.
//   같은 일정(Notion·캘린더)은 Hub.eventKey 로 한 번만.
//   사람 붙이기: 제목을 Hub.canonicalNames + 멤버 이름 → 이니셜로 바꾼 뒤 영숫자 토큰으로 나눠 이니셜 토큰이 정확히 같을 때만(BHL ≠ BYL, 부분 문자열 금지).
//   우선순위: away(오늘을 덮는 종일 + 키워드 + 이니셜, 또는 away 라벨) > meeting(종일 아님 + start ≤ now < end + Meeting·미팅·MM·GRM + 이니셜,
//   이니셜 없는 GRM 시각 일정 = 활성 멤버 전원) > experiment(SLab + 확정 + 범위 안) > class(오늘 슬롯 범위 안). now == end 는 아님.
//   모델이 갱신·1분마다 한 번 계산(memberStatus) — 화면 넷(Members 카드·MemberGroup·관제탑 roster·Members 탭)은 그 값만 읽는다. 적색 없음.
//   시험 훅 DESKHUB_STATUS_FIXTURE=<json> — 입력 통째로 바꿈(스냅샷 결정성).

enum MemberStatusKind: String, Codable, CaseIterable {
    case away, meeting, experiment, `class`
    var symbol: String {
        switch self {
        case .away: return "airplane"
        case .meeting: return "person.2"
        case .experiment: return "flask"
        case .class: return "book.closed"
        }
    }
    var label: String {
        switch self {
        case .away: return "On leave"
        case .meeting: return "In meeting"
        case .experiment: return "Running experiment"
        case .class: return "In class"
        }
    }
}

struct MemberStatusValue: Equatable {
    let kind: MemberStatusKind
    let why: String
    let until: Date?
    let allDay: Bool
    /// '~17:30' · 종일 '~10.16'
    var untilText: String {
        guard let u = until else { return "" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = Timetable.kst.timeZone
        f.dateFormat = allDay ? "M.d" : "HH:mm"
        return "~" + f.string(from: u)
    }
    var line: String { [kind.rawValue, why, untilText].filter { !$0.isEmpty }.joined(separator: " · ") }
    var help: String { [kind.label, why, untilText].filter { !$0.isEmpty }.joined(separator: " · ") }
}

enum MemberStatus {
    /// 결정 D-4 — 휴가·출장류 키워드(대소문자 무시, 부분 일치)
    static let awayWords = ["휴가", "연차", "반차", "병가", "출장", "학회", "파견", "워크숍", "workshop", "vacation", "leave", "conference"]
    static let meetingTokens: Set<String> = ["MEETING", "미팅", "MM", "GRM"]
    static let notionMinutes: TimeInterval = 60 * 60

    struct Ev: Hashable { let title: String; let start: Date; let end: Date?; let allDay: Bool }
    struct Lab: Hashable { let owner: String; let project: String; let time: String; let status: String }
    struct ClassSlot: Hashable { let initials: String; let course: String; let start: String; let end: String }
    struct Inputs {
        var now: Date
        var calendar: [Ev] = []
        var notion: [Ev] = []
        var slab: [Lab] = []
        var classes: [ClassSlot] = []
        var away: [String: String] = [:]
        var members: [String] = []
        var names: [String: String] = [:]
    }

    /// 제목 → 이니셜로 바꾼 글 (멤버 이름 → 이니셜, 옛 이니셜·별칭)
    static func canonical(_ title: String, names: [String: String]) -> String {
        var t = Hub.canonicalNames(title)
        for (n, ini) in names.sorted(by: { $0.key.count > $1.key.count }) where n.count >= 2 { t = t.replacingOccurrences(of: n, with: ini) }
        return t
    }
    static func tokens(_ s: String) -> Set<String> {
        Set(s.uppercased().split { !($0.isLetter || $0.isNumber) }.map(String.init))
    }
    /// 캘린더 + Notion(같은 일정은 캘린더 쪽 하나) — Notion 시각만 있으면 끝 = 시작 + 60분
    static func merged(_ inp: Inputs) -> [Ev] {
        let keys = Set(inp.calendar.map { Hub.eventKey($0.title, $0.start) })
        let n = inp.notion.filter { !keys.contains(Hub.eventKey($0.title, $0.start)) }
            .map { Ev(title: $0.title, start: $0.start, end: $0.allDay ? $0.end : ($0.end ?? $0.start.addingTimeInterval(notionMinutes)), allDay: $0.allDay) }
        return inp.calendar + n
    }
    /// 'HH:mm - HH:mm' → 오늘 시각 (못 읽으면 nil)
    static func range(_ text: String, on day: Date) -> (Date, Date)? {
        let p = text.components(separatedBy: CharacterSet(charactersIn: "-~–")).map { $0.trimmingCharacters(in: .whitespaces) }
        guard p.count == 2 else { return nil }
        func at(_ s: String) -> Date? {
            let q = s.split(separator: ":").compactMap { Int($0) }
            guard q.count == 2 else { return nil }
            return Timetable.kst.date(bySettingHour: q[0], minute: q[1], second: 0, of: day)
        }
        guard let a = at(p[0]), let b = at(p[1]), a < b else { return nil }
        return (a, b)
    }
    /// 종일 일정이 지금(오늘)을 덮는가 — end 가 없으면 시작 날 하루
    static func coversToday(_ e: Ev, now: Date) -> Bool {
        let c = Timetable.kst
        let s = c.startOfDay(for: e.start)
        let end = e.end.map { $0 > s ? $0 : c.date(byAdding: .day, value: 1, to: s)! } ?? c.date(byAdding: .day, value: 1, to: s)!
        return s <= now && now < end
    }

    static func resolve(_ ini: String, _ inp: Inputs) -> MemberStatusValue? {
        let me = ini.uppercased()
        let now = inp.now
        let evs = merged(inp)
        let memberSet = Set(inp.members.map { $0.uppercased() })
        // away — 종일 + 키워드 + 이니셜, 또는 away 라벨
        for e in evs where e.allDay && coversToday(e, now: now) {
            let t = canonical(e.title, names: inp.names)
            let low = t.lowercased()
            if awayWords.contains(where: { low.contains($0.lowercased()) }) && tokens(t).contains(me) {
                let last = e.end.map { $0.addingTimeInterval(-1) } ?? e.start
                return MemberStatusValue(kind: .away, why: t, until: last, allDay: true)
            }
        }
        if let label = inp.away[me], !label.isEmpty { return MemberStatusValue(kind: .away, why: label, until: nil, allDay: true) }
        // meeting — 시각 일정, 지금 안, 미팅 토큰 + 이니셜(이니셜 없는 GRM = 활성 멤버 전원)
        for e in evs.sorted(by: { $0.start < $1.start }) where !e.allDay {
            guard let end = e.end, e.start <= now, now < end else { continue }
            let t = canonical(e.title, names: inp.names)
            let toks = tokens(t)
            guard !toks.isDisjoint(with: meetingTokens) else { continue }
            let named = !toks.isDisjoint(with: memberSet)
            if toks.contains(me) || (!named && toks.contains("GRM") && memberSet.contains(me)) {
                return MemberStatusValue(kind: .meeting, why: t, until: end, allDay: false)
            }
        }
        // experiment — SLab 확정 + 실험자 = 그 사람 + 범위 안
        for l in inp.slab where l.owner.uppercased() == me && l.status == "확정" {
            guard let r = range(l.time, on: now), r.0 <= now, now < r.1 else { continue }
            let proj = l.project.components(separatedBy: " · ").first ?? l.project
            return MemberStatusValue(kind: .experiment, why: "SLab · " + proj, until: r.1, allDay: false)
        }
        // class — 오늘 슬롯 범위 안
        let hm = Timetable.hm(now)
        for c in inp.classes where c.initials.uppercased() == me && c.start <= hm && hm < c.end {
            let p = c.end.split(separator: ":").compactMap { Int($0) }
            let until = p.count == 2 ? Timetable.kst.date(bySettingHour: p[0], minute: p[1], second: 0, of: now) : nil
            return MemberStatusValue(kind: .class, why: c.course, until: until, allDay: false)
        }
        return nil
    }

    // MARK: 입력 만들기

    /// 모델 → 입력 (DESKHUB_STATUS_FIXTURE 가 있으면 그 파일)
    @MainActor static func inputs(_ m: NotionHubModel) -> Inputs {
        let now = m.now
        let members = m.members.filter(\.active).map(\.initials).filter { !$0.isEmpty }
        var names: [String: String] = [:]
        for x in m.members where !x.name.isEmpty && !x.initials.isEmpty { names[x.name] = x.initials }
        if let path = fixturePath, let f = Fixture.load(path, now: now) {
            var i = f; if i.members.isEmpty { i.members = members }; if i.names.isEmpty { i.names = names }
            return i
        }
        let c = Timetable.kst
        let cal = m.todayCalendar.map { $0.events + $0.allDay } ?? []
        let calEvs = cal.filter { c.isDate($0.start, inSameDayAs: now) || ($0.isAllDay && $0.start <= now && now < $0.end) }
            .map { Ev(title: $0.title, start: $0.start, end: $0.end, allDay: $0.isAllDay) }
        let notion = m.events.filter { c.isDate($0.date, inSameDayAs: now) }.map { Ev(title: $0.title, start: $0.date, end: nil, allDay: !$0.hasTime) }
        let slab = m.experiments.filter { $0.source == "SLab" }.map { Lab(owner: $0.owner, project: $0.title, time: $0.detail, status: $0.status) }
        let classes = Timetable.todayGroups(m.courses, now: now).flatMap { b in b.initials.map { ClassSlot(initials: $0, course: b.course, start: b.start, end: b.end) } }
        var away: [String: String] = [:]
        for (k, v) in m.memberLinks.away where !v.label.isEmpty { away[k.uppercased()] = v.label }
        return Inputs(now: now, calendar: calEvs, notion: notion, slab: slab, classes: classes, away: away, members: members, names: names)
    }
    static var fixturePath: String? {
        guard let v = ProcessInfo.processInfo.environment["DESKHUB_STATUS_FIXTURE"], !v.isEmpty else { return nil }
        return (v as NSString).expandingTildeInPath
    }

    /// 입력 fixture (스냅샷·text-check) — 시각은 'yyyy-MM-ddTHH:mm'(한국시간), 날짜만이면 종일
    enum Fixture {
        static func date(_ s: String) -> (Date, Bool)? {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = Timetable.kst.timeZone
            for (fmt, allDay) in [("yyyy-MM-dd'T'HH:mm", false), ("yyyy-MM-dd", true)] { f.dateFormat = fmt; if let d = f.date(from: s) { return (d, allDay) } }
            return nil
        }
        static func ev(_ o: [String: Any]) -> Ev? {
            guard let t = o["title"] as? String, let s = (o["start"] as? String).flatMap(date) else { return nil }
            let e = (o["end"] as? String).flatMap(date)?.0
            return Ev(title: t, start: s.0, end: e, allDay: (o["allDay"] as? Bool) ?? s.1)
        }
        static func load(_ path: String, now: Date) -> Inputs? {
            guard let d = FileManager.default.contents(atPath: path), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            var i = Inputs(now: now)
            i.calendar = ((o["calendar"] as? [[String: Any]]) ?? []).compactMap(ev)
            i.notion = ((o["notion"] as? [[String: Any]]) ?? []).compactMap(ev)
            i.slab = ((o["slab"] as? [[String: Any]]) ?? []).map { Lab(owner: $0["owner"] as? String ?? "", project: $0["project"] as? String ?? "", time: $0["time"] as? String ?? "", status: $0["status"] as? String ?? "") }
            i.classes = ((o["classes"] as? [[String: Any]]) ?? []).map { ClassSlot(initials: $0["init"] as? String ?? "", course: $0["course"] as? String ?? "", start: $0["start"] as? String ?? "", end: $0["end"] as? String ?? "") }
            i.away = (o["away"] as? [String: String]) ?? [:]
            i.members = (o["members"] as? [String]) ?? []
            i.names = (o["names"] as? [String: String]) ?? [:]
            return i
        }
    }

    // MARK: text-check (main.swift kind mstatus)

    /// 'now=;ini=;cal=제목@HH:mm-HH:mm|제목@종일;notion=제목@HH:mm|제목@종일;slab=이니셜/프로젝트/HH:mm - HH:mm/상태|…;class=이니셜/과목/수업시간|…;away=이니셜:라벨,…;members=…'
    /// → 'kind · why · ~HH:mm' 또는 '—'. class 는 Timetable.todayGroups(휴일 제외, 학기 파일 = tsv 옆 Resources)
    static func check(_ input: String, tsv: String) -> String {
        var k: [String: String] = [:]
        for part in input.components(separatedBy: ";") {
            let p = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if p.count == 2 { k[p[0].trimmingCharacters(in: .whitespaces)] = p[1] }
        }
        guard let now = Fixture.date(k["now"] ?? "")?.0 else { return "(입력 형식)" }
        let day = Timetable.kst.startOfDay(for: now)
        func evs(_ s: String?, notion: Bool) -> [Ev] {
            (s ?? "").components(separatedBy: "|").compactMap { e in
                let p = e.components(separatedBy: "@")
                guard p.count == 2 else { return nil }
                if p[1] == "종일" { return Ev(title: p[0], start: day, end: Timetable.kst.date(byAdding: .day, value: 1, to: day), allDay: true) }
                if notion {
                    let q = p[1].split(separator: ":").compactMap { Int($0) }
                    guard q.count == 2, let st = Timetable.kst.date(bySettingHour: q[0], minute: q[1], second: 0, of: day) else { return nil }
                    return Ev(title: p[0], start: st, end: nil, allDay: false)
                }
                guard let r = range(p[1], on: day) else { return nil }
                return Ev(title: p[0], start: r.0, end: r.1, allDay: false)
            }
        }
        var i = Inputs(now: now)
        i.calendar = evs(k["cal"], notion: false)
        i.notion = evs(k["notion"], notion: true)
        i.slab = (k["slab"] ?? "").components(separatedBy: "|").compactMap { s in
            let p = s.components(separatedBy: "/"); return p.count == 4 ? Lab(owner: p[0], project: p[1], time: p[2], status: p[3]) : nil
        }
        let sems = Timetable.loadSemesters(bundleURL: URL(fileURLWithPath: tsv).deletingLastPathComponent().appendingPathComponent("../Resources/semesters.json").standardizedFileURL, userURL: nil)
        let rows: [CourseRow] = (k["class"] ?? "").components(separatedBy: "|").compactMap { r in
            let p = r.components(separatedBy: "/")
            guard p.count >= 3 else { return nil }
            let ss = Timetable.slots(p[2...].joined(separator: "/"))
            return ss.isEmpty ? nil : CourseRow(initials: p[0], course: p[1], kind: "수강", confirmed: true, slots: ss)
        }
        i.classes = Timetable.todayGroups(rows, now: now, sems: sems).flatMap { b in b.initials.map { ClassSlot(initials: $0, course: b.course, start: b.start, end: b.end) } }
        for a in (k["away"] ?? "").components(separatedBy: ",") {
            let p = a.split(separator: ":", maxSplits: 1).map(String.init); if p.count == 2 { i.away[p[0]] = p[1] }
        }
        i.members = (k["members"] ?? "JOP,BHL,BYL,JYK,SMJ,MSY,SYJ").components(separatedBy: ",").filter { !$0.isEmpty }
        return resolve(k["ini"] ?? "", i)?.line ?? "—"
    }
}

// MARK: - 모델

extension NotionHubModel {
    /// 갱신 끝·1분 시계마다 한 번 (화면 넷은 이 값만 읽는다)
    func updateMemberStatus() {
        let inp = MemberStatus.inputs(self)
        var out: [String: MemberStatusValue] = [:]
        let people = Set(members.map(\.initials).filter { !$0.isEmpty } + inp.members)
        for ini in people { if let s = MemberStatus.resolve(ini, inp) { out[ini.uppercased()] = s } }
        if out != memberStatus { memberStatus = out }
    }
    func status(of ini: String) -> MemberStatusValue? { memberStatus[ini.uppercased()] }

    /// text.txt [멤버 상태] — 보이는 멤버마다 'JOP · meeting · Meeting: JOP · ~17:30' 또는 'JOP · —'
    func memberStatusDumpLines() -> [String] {
        MembersProjectsStrip.shown(self).map { m in
            m.initials + " · " + (status(of: m.initials)?.line ?? "—")
        }
    }
}

// MARK: - 아이콘

/// 상태 아이콘 하나 — Hub.text2(내 것 Hub.ink), 적색 없음. 상태가 없으면 빈 칸(placeholder 면 같은 폭)
struct MemberStatusIcon: View {
    let status: MemberStatusValue?
    var mine = false
    var size: CGFloat? = nil
    var placeholder = false
    @Environment(\.cardStyle) private var cs
    var body: some View {
        if let s = status {
            Image(systemName: s.kind.symbol).font(.hub(size ?? cs.tag, weight: .semibold))
                .foregroundStyle(mine ? Hub.ink : Hub.text2)
                .help(s.help)
                .accessibilityLabel(s.help)
        } else if placeholder {
            Color.clear.frame(width: 1, height: 1)
        }
    }
}

// MARK: - 허브 Members 카드 (R9-c — 랩장 '멤버 카드가 너무 작음 … 활동로그, 클로드 사용량(둘다 아직 미구현)이 잘 보여지면')

struct MembersCard: View {
    @ObservedObject var model: NotionHubModel
    @ObservedObject private var expansion = HubExpansion.shared
    @Environment(\.cardStyle) private var cs
    static let perColumn = 6
    static let key = "members"
    /// 지금 그려진 열 수 (ViewThatFits 가 고른 갈래 — text.txt [Members 카드])
    @MainActor static var columns = 0

    var body: some View {
        let all = MembersProjectsStrip.shown(model)
        let open = expansion.isOpen(Self.key)
        VStack(alignment: .leading, spacing: cs.gap) {
            HStack(spacing: 6) {
                SectionTitle(card: "members").fixedSize()
                if let f = model.cardTag("members") { FreshnessTag(f: f).layoutPriority(-1) }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Status · Member · Projects · Activity log · 준비 중 · Claude usage · 준비 중")
                    .font(.hub(cs.tag)).foregroundStyle(Hub.text3).lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
                    .help("Activity log·Claude usage 는 출처가 정해지면 채웁니다 — 평가·순위용 아님")
                ViewThatFits(in: .horizontal) {
                    twoColumns(all, open: open)
                    oneColumn(all, open: open)
                }
                CardFooter(caption: CardMetas.caption("members", model), toggleKey: Self.key, more: moreCount(all.count, open: open))
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
        }
    }

    /// 접힘이면 넘친 수(지금 열 수 기준), 펼침이면 접을 수 있게 넘쳤던 수
    private func moreCount(_ n: Int, open: Bool) -> Int {
        let cap = Self.perColumn * max(Self.columns, 1)
        return max(n - cap, 0)
    }

    private func twoColumns(_ all: [Member], open: Bool) -> some View {
        let shown = open ? all : Array(all.prefix(Self.perColumn * 2))
        let half = Int((Double(shown.count) / 2).rounded(.up))
        return HStack(alignment: .top, spacing: 16) {
            column(Array(shown.prefix(half)))
            column(Array(shown.dropFirst(half)))
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutChoice("members-cols", "2열")
        .background(Color.clear.onAppear { MainActor.assumeIsolated { Self.columns = 2 } })
    }

    private func oneColumn(_ all: [Member], open: Bool) -> some View {
        column(open ? all : Array(all.prefix(Self.perColumn)))
            .layoutChoice("members-cols", "1열")
            .background(Color.clear.onAppear { MainActor.assumeIsolated { Self.columns = 1 } })
    }

    private func column(_ ms: [Member]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ms) { m in row(m) }
        }
    }

    private func row(_ m: Member) -> some View {
        let mine = !HubPrefs.me.isEmpty && m.initials.uppercased() == HubPrefs.me.uppercased()
        let e = model.memberLinkEntry(for: m)
        let projs = e?.projects ?? []
        let away = MembersProjectsStrip.awayLabel(model, m)
        return HStack(spacing: 6) {
            MemberStatusIcon(status: model.status(of: m.initials), mine: mine).frame(width: cs.col(16), alignment: .center)
            Text(m.initials).font(.hub(cs.aux, weight: .bold, design: .rounded)).foregroundStyle(mine ? Hub.ink : Hub.text)
                .lineLimit(1).frame(width: cs.col(38), alignment: .leading)
            Button { model.openInApp(id: m.id) } label: {
                Text(m.name).font(.hub(cs.tag)).foregroundStyle(Hub.text2).lineLimit(1).truncationMode(.tail)
            }
            .buttonStyle(.plain).frame(width: cs.col(64), alignment: .leading)
            .help([m.name, m.initials, away ?? ""].filter { !$0.isEmpty }.joined(separator: " · ") + " — Notion 에서 열기")
            HStack(spacing: 4) {
                if let p = projs.first {
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: p.path)) } label: {
                        Text(MemberGroup.display(p.name)).font(.hub(cs.tag, weight: .medium)).lineLimit(1).truncationMode(.tail)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Hub.card))
                            .foregroundStyle(Hub.text2)
                    }
                    .buttonStyle(.plain).help("\(p.name) — NAS Memory 폴더 열기")
                    if projs.count > 1 {
                        Text("+\(projs.count - 1)").font(.hub(cs.tag)).foregroundStyle(Hub.text3).fixedSize()
                            .help(projs.dropFirst().map { MemberGroup.display($0.name) }.joined(separator: ", "))
                    }
                } else {
                    Text(away ?? "—").font(.hub(cs.tag)).foregroundStyle(Hub.text3).lineLimit(1)
                }
            }
            .frame(width: cs.col(112), alignment: .leading)
            HStack(spacing: 4) {
                if let pos = e?.poster {
                    Button { NSWorkspace.shared.open(pos.url) } label: { Image(systemName: "doc.richtext").font(.hub(10.5)).foregroundStyle(Hub.text3) }
                        .buttonStyle(.plain).help("최근 포스터 — \(pos.venue) \(pos.date) · \(pos.title)")
                }
                if let g = e?.github {
                    Button { NSWorkspace.shared.open(g) } label: { Image(systemName: "chevron.left.forwardslash.chevron.right").font(.hub(10)).foregroundStyle(Hub.text3) }
                        .buttonStyle(.plain).help(g.absoluteString)
                }
            }
            .frame(width: cs.col(28), alignment: .leading)
            Text("—").font(.hub(cs.tag)).foregroundStyle(Hub.text3).frame(width: cs.col(34), alignment: .leading).help("Activity log · 준비 중")
            Text("—").font(.hub(cs.tag)).foregroundStyle(Hub.text3).frame(width: cs.col(34), alignment: .leading).help("Claude usage · 준비 중")
        }
        .padding(.horizontal, cs.rowH).padding(.vertical, max(cs.rowV - 1, 2))
    }

    /// text.txt [Members 카드] — '열 2 · 행 6/6 · 더 보기 0 · Activity log 준비 중 · Claude usage 준비 중'
    @MainActor static func dumpLine(_ m: NotionHubModel) -> String {
        let n = MembersProjectsStrip.shown(m).count
        let cols = max(columns, 1)
        let open = HubExpansion.shared.isOpen(key)
        let shownN = open ? n : min(n, perColumn * cols)
        let rows = Int((Double(shownN) / Double(cols)).rounded(.up))
        return "열 \(columns == 0 ? "—" : String(columns)) · 행 \(rows)/\(perColumn) · 더 보기 \(max(n - perColumn * cols, 0)) · " + (open ? "펼침 · " : "")
            + "Activity log 준비 중 · Claude usage 준비 중"
    }
}
