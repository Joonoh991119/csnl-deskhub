import SwiftUI
import AppKit

// MARK: - 1.0.0 Main 탭 (C2, #55 R3 R4 R5)
// 그림 그대로(전체 화면 기준): 왼쪽 열 = 큰 시계 · 오늘 일정 · GRM 순번 / 오른쪽 위 = 학회 D-Day / 오른쪽 아래 = 논문 3편 / 오른쪽 아래 모서리 = 챗봇 단추.
// 네 칸의 판정은 순수 함수(MainToday·MainGRM·MainDDay·MainPapers) — 화면·main.txt 덤프·text-check main-* 가 같은 함수.
// 적색은 접수 중 학회 마감 D≤3 두 곳(오늘 일정 학회 행·D-Day 첫째)뿐. 보고서·리마인더·그랜트 마감은 넣지 않는다(SMJ §4-3).

enum MainV1 {
    /// 'D-n' (오늘 = D-0)
    static func dn(_ days: Int) -> String { days >= 0 ? "D-\(days)" : "D+\(-days)" }
    /// 날짜 차 — 같은 달력의 자정끼리
    static func days(from today: Date, to d: Date) -> Int {
        let c = Calendar.current
        return c.dateComponents([.day], from: c.startOfDay(for: today), to: c.startOfDay(for: d)).day ?? 0
    }
    /// 'M.d(요일)'
    static func dayLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "M.d(E)"; return f.string(from: d)
    }
    /// 'HH:mm'
    static func clock(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }
    /// 'k=v;k=v' (text-check 입력)
    static func kv(_ input: String) -> [String: String] {
        var k: [String: String] = [:]
        for part in input.components(separatedBy: ";") {
            let p = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if p.count == 2 { k[p[0].trimmingCharacters(in: .whitespaces)] = p[1] }
        }
        return k
    }
    /// 커뮤니티 창 (§5 ③ — 갈래 B 가 NSApplication 에 정의). 응답자가 없으면 삐
    @MainActor static func openCommunity(_ p: PaperRec) {
        if !NSApp.sendAction(Selector(("openDeskHubCommunity:")), to: nil, from: p.id as NSString) { NSSound.beep() }
    }
    /// 챗봇 창 (§5 ③)
    @MainActor static func openChat() {
        if !NSApp.sendAction(Selector(("openDeskHubChat:")), to: nil, from: nil) { NSSound.beep() }
    }
}

// MARK: 오늘 일정 (R3, 결정 D-4)

enum MainToday {
    enum Kind: Equatable { case allDay, slot, conf }
    struct Row: Hashable {
        let kind: Kind
        let time: String
        let title: String
        let source: String
        /// 학회 초록 마감 D≤3 — 이 행의 D-n 만 적색
        let urgent: Bool
        let dday: String
        /// 덤프·text-check 한 줄
        let text: String
    }
    /// estimated = 학회 파일 마감 라벨이 '[예상]'(작년 날짜로 잡은 추정치) — 글에 '(예상)', 적색 없음 (1.0.0 검증 1 리뷰)
    struct Conf { let name: String; let deadline: Date?; var estimated = false }
    /// '[예상]' 라벨 판정 — ConferenceRow.deadlineLabel
    static func isEstimated(_ label: String) -> Bool { label.contains("[예상]") }
    /// text-check 입력의 마감 날짜 'yyyy-MM-dd?' — 끝의 '?' 는 예상
    static func parseDeadline(_ raw: String) -> (date: Date?, estimated: Bool) {
        let est = raw.hasSuffix("?")
        return (MetricDefs.parseDay(est ? String(raw.dropLast()) : raw), est)
    }
    /// 학회 마감을 오늘 일정에 넣는 창 — 접수 중 초록 마감 D-0…D-7 (경보와 같은 창)
    static let confWindow = 7

    /// 오늘 종일 일정(앞) + NowNext.pick.rest(오늘 남은 캘린더 + 내 수업, 같은 수업 하나) + 접수 중 학회 초록 마감 D-0…D-7(뒤)
    static func rows(pick: NowNext.Pick, allDay: [(title: String, source: String)], confs: [Conf], today: Date) -> [Row] {
        var out = allDay.map { a in Row(kind: .allDay, time: "종일", title: a.title, source: a.source, urgent: false, dday: "", text: "종일 " + a.title) }
        out += pick.rest.map { s in
            Row(kind: .slot, time: Timetable.hm(s.start) + "–" + Timetable.hm(s.end), title: s.title, source: s.source, urgent: false, dday: "", text: NowNext.text(s))
        }
        let near = confs.compactMap { c -> (Conf, Int)? in
            guard let d = c.deadline else { return nil }
            let n = MainV1.days(from: today, to: d)
            return (0...confWindow).contains(n) ? (c, n) : nil
        }.sorted { ($0.1, $0.0.name) < ($1.1, $1.0.name) }
        out += near.map { c, n in
            let what = "초록 마감" + (c.estimated ? "(예상)" : "")
            return Row(kind: .conf, time: MainV1.dn(n), title: "\(c.name) \(what)", source: "학회", urgent: n <= 3 && !c.estimated, dday: MainV1.dn(n),
                       text: "학회 \(c.name) \(what) \(MainV1.dn(n))")
        }
        return out
    }

    /// text-check main-today — 'now=yyyy-MM-ddTHH:mm;cal=HH:mm-HH:mm/제목|…;allday=제목|…;cls=HH:mm-HH:mm/과목|…;conf=이름/yyyy-MM-dd|…' → 행 ' / ' | '없음'
    static func check(_ input: String) -> String {
        let k = MainV1.kv(input)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = Timetable.kst.timeZone; f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        guard let now = f.date(from: k["now"] ?? "") else { return "(입력 형식)" }
        let day = Timetable.kst.startOfDay(for: now)
        func slots(_ s: String, source: String) -> [NowNext.Slot]? {
            var out: [NowNext.Slot] = []
            for item in s.components(separatedBy: "|") where !item.isEmpty {
                let p = item.split(separator: "/", maxSplits: 1).map(String.init)
                let t = p.first?.components(separatedBy: "-") ?? []
                guard p.count == 2, t.count == 2 else { return nil }
                out.append(NowNext.Slot(title: p[1], start: NowNext.at(t[0], day: day), end: NowNext.at(t[1], day: day), source: source))
            }
            return out
        }
        guard let ev = slots(k["cal"] ?? "", source: "CSNL"), let cl = slots(k["cls"] ?? "", source: NowNext.classSource) else { return "(입력 형식)" }
        let allDay = (k["allday"] ?? "").components(separatedBy: "|").filter { !$0.isEmpty }.map { (title: $0, source: "CSNL") }
        var confs: [Conf] = []
        for item in (k["conf"] ?? "").components(separatedBy: "|") where !item.isEmpty {
            let p = item.components(separatedBy: "/")
            guard p.count == 2 else { return "(입력 형식)" }
            let dl = parseDeadline(p[1])
            guard let d = dl.date else { return "(입력 형식)" }
            confs.append(Conf(name: p[0], deadline: d, estimated: dl.estimated))
        }
        let r = rows(pick: NowNext.pick(events: ev, classes: cl, now: now), allDay: allDay, confs: confs, today: Calendar.current.startOfDay(for: now))
        return r.isEmpty ? "없음" : r.map(\.text).joined(separator: " / ")
    }
}

// MARK: GRM 순번 6회 (결정 D-5)

enum MainGRM {
    static let count = 6
    /// 지난 회차 — 날짜 < 오늘, 또는 오늘이고 now ≥ 12:00 (GRMSchedule.last 와 같은 정오 규칙)
    static func isPast(_ g: GRMSlot, today: Date, now: Date) -> Bool {
        let cal = Calendar.current
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: today)!
        return g.date < today || (cal.isDate(g.date, inSameDayAs: today) && now >= noon)
    }
    /// GRMSchedule.rows(같은 회차 합침)에서 지난 회차를 뺀 앞 6행
    static func next(_ slots: [GRMSlot], today: Date, now: Date) -> [GRMSlot] {
        Array(GRMSchedule.rows(slots, today: today, now: now).rows.filter { !isPast($0, today: today, now: now) }.prefix(count))
    }
    /// 이니셜 토큰 규칙(NotionHubModel.isMine 과 같은 토큰 단위) — me=SL 이 'JSL' 에 걸리지 않는다
    static func tokenMine(_ text: String, me: String) -> Bool {
        let m = me.trimmingCharacters(in: .whitespaces).uppercased()
        guard !m.isEmpty else { return false }
        return text.uppercased().split { !($0.isLetter || $0.isNumber) }.map(String.init).contains(m)
    }
    /// text-check main-grm — 'now=yyyy-MM-ddTHH:mm;me=;slots=yyyy-MM-dd/발표자/Type|…' → 'M.d 발표자[ ★] · …' | '—'
    static func check(_ input: String) -> String {
        let k = MainV1.kv(input)
        guard let now = MetricDefs.parseInstant(k["now"] ?? "") else { return "(입력 형식)" }
        let today = Calendar.current.startOfDay(for: now)
        let slots: [GRMSlot] = (k["slots"] ?? "").components(separatedBy: "|").enumerated().compactMap { i, s in
            let f = s.components(separatedBy: "/")
            guard f.count >= 3, let d = MetricDefs.parseDay(f[0]) else { return nil }
            return GRMSlot(id: "s\(i + 1)", date: d, presenters: f[1], type: f[2], notified: false, abstractDone: false, docURL: nil, noteIDs: [])
        }
        let r = next(slots, today: today, now: now)
        guard !r.isEmpty else { return "—" }
        return r.map { g in
            let who = g.presenters.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            return Hub.shortDay(g.date) + " " + (who.isEmpty ? "미정" : who) + (tokenMine(g.presenters, me: k["me"] ?? "") ? " ★" : "")
        }.joined(separator: " · ")
    }
}

// MARK: 학회 D-Day (R4, 결정 D-6)

enum MainDDay {
    /// estimated = 마감 라벨 '[예상]' (MainToday.isEstimated)
    struct Conf { let name: String; let start: Date; let deadline: Date?; var estimated = false }
    struct Pick: Hashable { let name: String; let date: Date; let isDeadline: Bool; let days: Int; var estimated = false
        var label: String { isDeadline ? (estimated ? "마감(예상)" : "마감") : "개최" }
        /// 첫째만 적색 — 접수 중 확정 마감 D≤3 (예상 마감은 적색 없음)
        var urgent: Bool { isDeadline && !estimated && days <= 3 }
    }
    /// 기준일 = 접수 중 초록 마감(≥오늘), 없으면 개최 시작일(≥오늘 — 개최 중·지난 것은 뺌). 기준일 오름차순, 같으면 이름순.
    /// 같은 학회(이름 소문자)는 처음 것 하나 — Notion Conferences 는 발표 한 건이 한 행이라 여러 명이 가면 겹친다 (검증 1 리뷰)
    static func pick(_ confs: [Conf], today: Date) -> [Pick] {
        var seen = Set<String>()
        return confs.compactMap { c -> Pick? in
            if let d = c.deadline, MainV1.days(from: today, to: d) >= 0 {
                return Pick(name: c.name, date: d, isDeadline: true, days: MainV1.days(from: today, to: d), estimated: c.estimated)
            }
            let n = MainV1.days(from: today, to: c.start)
            return n >= 0 ? Pick(name: c.name, date: c.start, isDeadline: false, days: n) : nil
        }
        .sorted { ($0.days, $0.name) < ($1.days, $1.name) }
        .filter { seen.insert($0.name.lowercased()).inserted }
    }
    /// text-check main-dday — 'today=yyyy-MM-dd;confs=이름/개최 yyyy-MM-dd/마감 yyyy-MM-dd[?]|-|…' ('?' = 예상 마감) → '큰 <이름> <마감|개최> D-n | 작게 <…>, <…>, <…>' | '—'
    static func check(_ input: String) -> String {
        let k = MainV1.kv(input)
        guard let today = MetricDefs.parseDay(k["today"] ?? "") else { return "(입력 형식)" }
        var confs: [Conf] = []
        for item in (k["confs"] ?? "").components(separatedBy: "|") where !item.isEmpty {
            let p = item.components(separatedBy: "/")
            guard p.count == 3, let s = MetricDefs.parseDay(p[1]) else { return "(입력 형식)" }
            let dl = p[2] == "-" ? (date: nil, estimated: false) : MainToday.parseDeadline(p[2])
            confs.append(Conf(name: p[0], start: s, deadline: dl.date, estimated: dl.estimated))
        }
        let r = pick(confs, today: today)
        guard let first = r.first else { return "—" }
        func t(_ p: Pick) -> String { "\(p.name) \(p.label) \(MainV1.dn(p.days))" }
        let rest = r.dropFirst().prefix(3)
        return "큰 " + t(first) + " | 작게 " + (rest.isEmpty ? "—" : rest.map(t).joined(separator: ", "))
    }
}

// MARK: 논문 3편 (R5, 결정 D-7)

enum MainPapers {
    /// since = 보기 대상의 가장 최근 Sent At (머리 '6.1 이후 새 추천 없음')
    struct Result { let rotate: Bool; let items: [PaperRec]; let n: Int; let start: Int; var since: Date? = nil }
    /// 보기 대상 = researcher == me(없거나 0편이면 전체). 대상의 가장 최근 Sent At 이 기대 주기 7일 ×2 를 넘었으면(ProducerRule 멈춤) 순환
    /// (티어 S→A→B→C · Sent At 최신 · id 순, KST 연중 날짜 d × 3 mod n 에서 3편, 감음), 아니면 새 추천(Sent At 최신 3편).
    /// 멈춤 판정을 모델 전체가 아니라 대상 기준으로 — 다른 사람에게만 새 추천이 와도 내 순환은 계속 (검증 1 리뷰, R5)
    static func pick(_ papers: [PaperRec], me: String, today: Date) -> Result {
        let m = me.trimmingCharacters(in: .whitespaces).uppercased()
        let mine = m.isEmpty ? [] : papers.filter { $0.researcher.trimmingCharacters(in: .whitespaces).uppercased() == m }
        let pool = mine.isEmpty ? papers : mine
        let n = pool.count
        let since = pool.compactMap(\.sentAt).max()
        let stopped = ProducerRule.judge(content: since, today: today, cycleDays: 7).map { $0.kind == .stopped } ?? true
        guard n > 0 else { return Result(rotate: stopped, items: [], n: 0, start: 0, since: since) }
        let distant = Date.distantPast
        if !stopped {
            let s = pool.sorted { a, b in ((a.sentAt ?? distant), b.id) > ((b.sentAt ?? distant), a.id) }
            return Result(rotate: false, items: Array(s.prefix(3)), n: n, start: 0, since: since)
        }
        let s = pool.sorted { a, b in
            let ra = HubPrefs.tierRank(a.tier), rb = HubPrefs.tierRank(b.tier)
            if ra != rb { return ra < rb }
            let sa = a.sentAt ?? distant, sb = b.sentAt ?? distant
            if sa != sb { return sa > sb }
            return a.id < b.id
        }
        let d = (Timetable.kst.ordinality(of: .day, in: .year, for: today) ?? 1) - 1
        let start = (d * 3) % n
        let items = (0..<min(3, n)).map { s[(start + $0) % n] }
        return Result(rotate: true, items: items, n: n, start: start, since: since)
    }
    /// 카드용 짧은 저자 — 첫 저자 성 + 여럿이면 ' et al.' ('Edden, R. A. E., … & Singh, K. D.' → 'Edden et al.'). 비면 빈 글
    static func shortAuthors(_ raw: String) -> String {
        let toks = raw.components(separatedBy: ",").map { $0.replacingOccurrences(of: "&", with: "").trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = toks.first else { return "" }
        let named = toks.filter { t in t.contains { $0.isLowercase } }   // 이름 조각(이니셜 'R. A. E.' 는 소문자 없음)
        let apa = toks.count > 1 && !toks[1].contains { $0.isLowercase }
        let lead = apa ? first : (first.split(separator: " ").last.map(String.init) ?? first)
        return lead + (named.count > 1 ? " et al." : "")
    }
    /// 연도 — APA 의 '(yyyy' (Notion 원값 그대로). 없으면 '—'
    static func year(_ apa: String) -> String {
        guard let r = apa.range(of: #"\((\d{4})"#, options: .regularExpression) else { return "—" }
        return String(apa[r].dropFirst())
    }
    /// text-check main-papers — 'today=yyyy-MM-dd;me=;stopped=0|1;papers=id/researcher/tier/yyyy-MM-dd|…' → '<rotate|fresh> id,id,id'
    /// (stopped 는 옛 입력 호환으로 받기만 한다 — 멈춤은 대상 Sent At 으로 pick 이 정한다)
    static func check(_ input: String) -> String {
        let k = MainV1.kv(input)
        guard let today = MetricDefs.parseDay(k["today"] ?? "") else { return "(입력 형식)" }
        var ps: [PaperRec] = []
        for item in (k["papers"] ?? "").components(separatedBy: "|") where !item.isEmpty {
            let p = item.components(separatedBy: "/")
            guard p.count == 4 else { return "(입력 형식)" }
            ps.append(PaperRec(id: p[0], title: p[0], authors: "", tier: p[2], researcher: p[1], doi: nil, sentAt: MetricDefs.parseDay(p[3])))
        }
        let r = pick(ps, me: k["me"] ?? "", today: today)
        return (r.rotate ? "rotate " : "fresh ") + (r.items.isEmpty ? "—" : r.items.map(\.id).joined(separator: ","))
    }
}

// MARK: 덤프 (main.txt)

extension NotionHubModel {
    /// 오늘 일정 입력 — text.txt [Timetable] '지금·다음 후보' 와 같은 입력(model.now · 캘린더 · 이 맥 이니셜의 수업)
    var mainTodayPick: NowNext.Pick {
        let feed = TimetableFeed(rows: courses, aliases: cfg.initialsAliases)
        return NowNext.pick(events: NowNext.eventSlots(todayCalendar?.events ?? [], now: now),
                            classes: NowNext.classSlots(feed, me: HubPrefs.me, now: now), now: now)
    }
    var mainTodayRows: [MainToday.Row] {
        let cal = todayCalendar
        let allDay = (cal?.allDay ?? []).filter { Calendar.current.isDate($0.start, inSameDayAs: today) || ($0.start <= today && $0.end > today) }
            .map { (title: Hub.canonicalNames($0.title), source: $0.calendarName.localizedCaseInsensitiveContains("slab") ? "SLab" : "CSNL") }
        return MainToday.rows(pick: mainTodayPick, allDay: allDay,
                              confs: conferences.map { MainToday.Conf(name: InterestFile.displayName($0), deadline: $0.deadline,
                                                                       estimated: MainToday.isEstimated($0.deadlineLabel)) }, today: today)
    }
    /// 오늘 일정이 비었을 때 한 줄 — 불러오는 중 · 캘린더 읽지 못함 · 남은 일정 없음
    var mainTodayEmpty: String {
        guard let cal = todayCalendar else { return "캘린더 읽지 못함" }
        if !cal.isSettled { return "불러오는 중…" }
        return cal.status == .noSource || cal.status == .denied ? "캘린더 읽지 못함" : "남은 일정 없음"
    }
    var mainGRM: [GRMSlot] { MainGRM.next(grm, today: today, now: now) }
    func mainGRMWho(_ g: GRMSlot) -> String { let i = initialsList(g.presenters); return i.isEmpty ? "미정" : i }
    func mainGRMMine(_ g: GRMSlot) -> Bool {
        let me = HubPrefs.me
        return isMine(g.presenters, me: me) || MainGRM.tokenMine(initialsList(g.presenters), me: me)
    }
    var mainDDay: [MainDDay.Pick] {
        MainDDay.pick(conferences.map { MainDDay.Conf(name: InterestFile.displayName($0), start: $0.start, deadline: $0.deadline,
                                                      estimated: MainToday.isEstimated($0.deadlineLabel)) }, today: today)
    }
    var mainPapers: MainPapers.Result { MainPapers.pick(papers, me: HubPrefs.me, today: today) }

    /// main.txt 의 [Main] 절 (탭 절은 NotionHubWidget 이 앞에 붙인다)
    func mainDumpLines() -> [String] {
        let me = HubPrefs.me
        var out = ["[Main] 시계 \(MainV1.clock(HubClock.now)) · 나 \(me.isEmpty ? "—" : me)" + (HubPrefs.meChosen ? "" : " (확인 전)")]
        let rows = mainTodayRows
        out.append("오늘 일정 \(rows.count)" + (rows.isEmpty ? " · " + mainTodayEmpty : ""))
        out += rows.map(\.text)
        let g = mainGRM
        out.append("GRM \(g.count)")
        out += g.map { s in "\(Hub.shortDay(s.date)) · \(MainV1.dn(MainV1.days(from: today, to: s.date))) · \(mainGRMWho(s))" + (mainGRMMine(s) ? " · 내 차례" : "") }
        let dd = mainDDay
        func line(_ p: MainDDay.Pick) -> String { "\(p.name) · \(p.label) · \(Hub.shortDay(p.date)) · \(MainV1.dn(p.days))" }
        if let f = dd.first { out.append("D-Day 큰 " + line(f)) } else { out.append("D-Day 큰 —") }
        out += dd.dropFirst().prefix(3).map { "D-Day 작게 " + line($0) }
        let p = mainPapers
        out.append("논문 \(p.rotate ? "rotate" : "fresh") \(p.items.count)/\(p.n) · 시작 \(p.start)")
        out += p.items.map { r in
            [r.tier.isEmpty ? "—" : r.tier, String(r.title.prefix(40)), String(r.authors.prefix(30)), MainPapers.year(r.apa), r.researcher.isEmpty ? "—" : r.researcher].joined(separator: " · ")
        }
        let h = V1HeightProbe.min(group: MainV1View.buttonProbe)
        out.append("단추 최소 높이 " + (h > 0 ? "\(Int(h.rounded(.down)))" : "—"))
        return out
    }
}

// MARK: - 화면

struct MainV1View: View {
    @ObservedObject var model: NotionHubModel
    static let buttonProbe = "main-btn-min"
    private let cs = CardStyle.large

    var body: some View {
        GeometryReader { geo in
            let leftW = min(max(Hub.s(320), geo.size.width * 0.30), geo.size.width * 0.45)
            HStack(alignment: .top, spacing: 12) {
                // 두 열 모두 넘치면 스크롤 — 기본 창·1.5배에서 셋째 논문 카드·GRM 순번이 창 밖으로 잘리던 것 (검증 1).
                // 다 들어가면 Spacer 로 논문을 열 바닥에 붙이고(그림 그대로), 아니면 ScrollView. 고른 갈래 = choices main-papers-fit 맞음|스크롤
                ViewThatFits(in: .vertical) {
                    left(geo, spacer: true)
                    ScrollView(.vertical) { left(geo, spacer: false) }
                }
                .frame(width: leftW)
                ViewThatFits(in: .vertical) {
                    right(spacer: true).layoutChoice("main-papers-fit", "맞음")
                    ScrollView(.vertical) { right(spacer: false) }.layoutChoice("main-papers-fit", "스크롤")
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(12)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .overlay(alignment: .bottomTrailing) { MainChatButton().padding(16) }
        }
        .environment(\.cardStyle, cs)
        .keyLayer(model)
        .onChange(of: model.settledAt != nil, initial: true) { _, settled in
            guard settled else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { RenderClock.mark(view: "main") } }
        }
    }

    @ViewBuilder private func left(_ geo: GeometryProxy, spacer: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MeConfirmBar(model: model)
            MainClockCard()
            MainTodayCard(model: model, cal: model.todayCalendar, maxHeight: geo.size.height * 0.5)
            MainGRMCard(model: model)
            if spacer { Spacer(minLength: 0) }
        }
    }

    @ViewBuilder private func right(spacer: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MainDDayCard(model: model)
            if spacer { Spacer(minLength: 0) }
            MainPapersSection(model: model)
                .padding(.trailing, 64 + 16)    // 챗봇 단추 자리
                .padding(.bottom, spacer ? 0 : 64)
        }
    }
}

/// 카드 바탕 한 모양
private struct MainCard<Content: View>: View {
    var title: String? = nil
    var tail: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.hub(18, weight: .bold)).foregroundStyle(Hub.text)
                    if let tail { Text(tail).font(.hub(13)).foregroundStyle(Hub.text2).lineLimit(2) }
                    Spacer(minLength: 0)
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Hub.surface))
    }
}

/// 큰 시계 — HH:mm + 날짜 한 줄 (DESKHUB_NOW 면 그 시각)
private struct MainClockCard: View {
    var body: some View {
        TimelineView(.everyMinute) { _ in
            let now = HubClock.now
            MainCard {
                Text(MainV1.clock(now)).font(.hub(72, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Hub.text).lineLimit(1).minimumScaleFactor(0.5)
                Text(Hub.longDay(now)).font(.hub(18, weight: .semibold)).foregroundStyle(Hub.text2).lineLimit(1)
            }
        }
    }
}

/// 오늘 일정 — 캘린더 모델을 직접 관찰(todayCalendar 는 @Published 가 아님)
private struct MainTodayCard: View {
    @ObservedObject var model: NotionHubModel
    let cal: CalendarModel?
    let maxHeight: CGFloat
    var body: some View {
        if let cal { CalObserved(model: model, cal: cal, maxHeight: maxHeight) } else { MainTodayList(model: model, maxHeight: maxHeight) }
    }
    private struct CalObserved: View {
        @ObservedObject var model: NotionHubModel
        @ObservedObject var cal: CalendarModel
        let maxHeight: CGFloat
        var body: some View { MainTodayList(model: model, maxHeight: maxHeight) }
    }
}

private struct MainTodayList: View {
    @ObservedObject var model: NotionHubModel
    let maxHeight: CGFloat
    var body: some View {
        let rows = model.mainTodayRows
        MainCard(title: "오늘 일정 · \(rows.count)") {
            if rows.isEmpty {
                Text(model.mainTodayEmpty).font(.hub(15)).foregroundStyle(Hub.text2)
            } else {
                ViewThatFits(in: .vertical) {
                    list(rows)
                    ScrollView { list(rows) }.frame(maxHeight: max(80, maxHeight - 60))
                }
                .frame(maxHeight: max(80, maxHeight - 60))
            }
        }
    }
    private func list(_ rows: [MainToday.Row]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.self) { r in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(r.time).font(.hub(14, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(r.kind == .conf && r.urgent ? Hub.signal : Hub.text2)
                        .lineLimit(1).fixedSize()
                    Text(r.title).font(.hub(15, weight: r.kind == .conf ? .semibold : .regular)).foregroundStyle(Hub.text)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Text(r.source).font(.hub(12)).foregroundStyle(Hub.text3).lineLimit(1).fixedSize()
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// GRM 순번 — 다음 6회, 내 차례는 Hub.ink 굵게 + ink 12% 바탕 + '내 차례'(적색 아님)
private struct MainGRMCard: View {
    @ObservedObject var model: NotionHubModel
    var body: some View {
        let rows = model.mainGRM
        MainCard(title: "GRM 순번") {
            if rows.isEmpty {
                Text("다음 GRM 일정 없음").font(.hub(15)).foregroundStyle(Hub.text2)
            }
            ForEach(rows, id: \.id) { g in
                let mine = model.mainGRMMine(g)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(MainV1.dayLabel(g.date)).font(.hub(15, weight: mine ? .bold : .medium)).monospacedDigit().lineLimit(1).fixedSize()
                    Text(MainV1.dn(MainV1.days(from: model.today, to: g.date))).font(.hub(13, weight: .semibold, design: .rounded))
                        .foregroundStyle(mine ? Hub.ink : Hub.text2).lineLimit(1).fixedSize()
                    Text(model.mainGRMWho(g)).font(.hub(15, weight: mine ? .bold : .regular)).lineLimit(1)
                    Spacer(minLength: 4)
                    if mine { Text("내 차례").font(.hub(12, weight: .bold)).lineLimit(1).fixedSize() }
                }
                .foregroundStyle(mine ? Hub.ink : Hub.text)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(mine ? Hub.ink.opacity(0.12) : Color.clear))
            }
        }
    }
}

/// 학회 D-Day — 가장 가까운 하나 크게 + 다음 3개 작게. 적색은 첫째가 마감 D≤3 일 때만
private struct MainDDayCard: View {
    @ObservedObject var model: NotionHubModel
    var body: some View {
        let picks = model.mainDDay
        MainCard(title: "학회 D-Day") {
            if let f = picks.first {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(MainV1.dn(f.days)).font(.hub(64, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(f.urgent ? Hub.signal : Hub.ink).lineLimit(1).fixedSize()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.name).font(.hub(22, weight: .bold)).foregroundStyle(Hub.text).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        // '[예상]' 마감은 '초록 마감(예상)' — 작년 날짜로 잡은 추정치를 확정처럼 보이지 않게 (검증 1 리뷰)
                        Text("\(f.isDeadline ? "초록 " + f.label : "개최") · \(MainV1.dayLabel(f.date))").font(.hub(15)).foregroundStyle(Hub.text2)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(Array(picks.dropFirst().prefix(3)), id: \.self) { p in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(MainV1.dn(p.days)).font(.hub(14, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Hub.text2).lineLimit(1).fixedSize()
                        Text(p.name).font(.hub(15)).foregroundStyle(Hub.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Text("\(p.label) \(MainV1.dayLabel(p.date))").font(.hub(13)).foregroundStyle(Hub.text2).lineLimit(1).fixedSize()
                        Spacer(minLength: 0)
                    }
                }
            } else {
                Text("다가오는 학회 없음").font(.hub(15)).foregroundStyle(Hub.text2)
            }
        }
    }
}

/// 논문 3편 — 카드(티어 칩 · 제목 2줄 · '저자 · 연도' · '커뮤니티'). 가로 3, 좁으면 세로
private struct MainPapersSection: View {
    @ObservedObject var model: NotionHubModel
    var body: some View {
        let r = model.mainPapers
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) { heading; tail(r).fixedSize(); Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 2) { heading; tail(r).fixedSize(horizontal: false, vertical: true) }
            }
            if r.items.isEmpty {
                Text("논문 추천 없음").font(.hub(15)).foregroundStyle(Hub.text2)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(r.items) { p in MainPaperCard(paper: p).frame(minWidth: Hub.s(200), maxWidth: .infinity) }
                    }
                    .layoutChoice("main-papers", "가로")
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(r.items) { p in MainPaperCard(paper: p) }
                    }
                    .layoutChoice("main-papers", "세로")
                }
            }
        }
    }
    private var heading: some View { Text("오늘의 논문").font(.hub(18, weight: .bold)).foregroundStyle(Hub.text) }
    /// 순환일 때만 — 대상의 마지막 추천일 이후 새 추천 없음
    @ViewBuilder private func tail(_ r: MainPapers.Result) -> some View {
        if r.rotate {
            Text("\(r.since.map(Hub.shortDay) ?? "—") 이후 새 추천 없음 · 날마다 3편씩 바뀝니다").font(.hub(13)).foregroundStyle(Hub.text2).lineLimit(2)
        }
    }
}

private struct MainPaperCard: View {
    let paper: PaperRec
    var body: some View {
        // 티어 칩과 '커뮤니티' 단추를 한 줄에 — 카드 셋이 1.5·2.0배에서도 열에 들어가게. 제목은 자르지 않고 줄바꿈,
        // 저자는 '첫 저자 et al. · 연도' (전체 목록은 도움말) — 검증 1 '…' 지적
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                if !paper.tier.isEmpty {
                    Text(paper.tier).font(.hub(12, weight: .bold)).foregroundStyle(Hub.ink)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Hub.ink.opacity(paper.tier == "S" ? 0.22 : 0.12)))
                }
                Spacer(minLength: 0)
                Button { MainV1.openCommunity(paper) } label: {
                    HStack(spacing: 6) { Image(systemName: "bubble.left.and.bubble.right"); Text("커뮤니티") }.lineLimit(1).fixedSize()
                }
                .buttonStyle(V1TabButtonStyle(selected: false, probeID: "community-" + paper.id, probeGroup: MainV1View.buttonProbe))
            }
            Button { MainV1.openCommunity(paper) } label: {
                Text(paper.title).font(.hub(15, weight: .semibold)).foregroundStyle(Hub.text)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("커뮤니티 — abstract · 추천 이유 · 반응 · 댓글")
            let au = MainPapers.shortAuthors(paper.authors)
            Text([au.isEmpty ? nil : au, MainPapers.year(paper.apa)].compactMap { $0 }.joined(separator: " · "))
                .font(.hub(13)).foregroundStyle(Hub.text2).fixedSize(horizontal: false, vertical: true)
                .help(paper.authors)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Hub.surface))
    }
}

/// 챗봇 단추 — 지름 64pt 둥근 캐릭터(원 Hub.ink + 눈 두 개 · 웃는 입 Hub.onAccent, 외부 그림 없음)
private struct MainChatButton: View {
    var body: some View {
        Button { MainV1.openChat() } label: {
            ZStack {
                Circle().fill(Hub.ink)
                HStack(spacing: 14) {
                    Circle().fill(Hub.onAccent).frame(width: 8, height: 8)
                    Circle().fill(Hub.onAccent).frame(width: 8, height: 8)
                }
                .offset(y: -7)
                MainSmile().stroke(Hub.onAccent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 24, height: 10).offset(y: 10)
            }
            .frame(width: 64, height: 64)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("챗봇 — 다음 GRM 발표자, 장비 예약 방법…")
        .v1HeightProbe(MainV1View.buttonProbe, "chat")
    }
}

private struct MainSmile: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY * 2))
        return p
    }
}
