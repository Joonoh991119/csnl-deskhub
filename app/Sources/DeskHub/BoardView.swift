import SwiftUI
import AppKit

// MARK: - 안내판 뷰 (디자인 계획 D9 — §2 C, 출발 안내판식 시간 열차)
// near(가까이): 위(세로) 또는 왼쪽 1/3(가로) = 오늘 — ① 시계 ② 마감(앞 2개) ③ 오늘 일정 (BHL R2, 0.35.0).
//   글자는 BoardType 3단계, 색은 Hub.text·Hub.ink 둘(첫 마감 남은 시간이 D≤3 일 때만 Hub.signal). Phase 주인공은 쓰지 않는다.
// 나머지 = 내일 0시부터의 '날짜 | 시각 | 무엇 | 누구 | 상태' 시간순 보드(날짜는 그날 첫 행에만), 그 위에 GRM 순번 띠 한 줄.
//   상태 열은 계산된 말(진행 중 · 35분 후 · D-4)이라 뺄셈이 필요 없다. 오늘 일은 왼쪽에만, 한 항목은 한 곳에만.
// 데이터는 순수 함수 BoardView.data(model:now:me:) — 같은 입력이면 같은 결과. `--dump-phase` 의 안내판 블록으로 확인.
// far(멀리서, 0.38.0 BHL B-2): 맨 위 시각 한 줄 + '급한 마감'(D≤7) · '오늘 남은 일정' 두 블록만, 내용 중복 없음(farData). 글자는 FarType 3단계.
// 날짜 없는 것(실험·미정 그랜트)은 표 끝(Hub.text2 칸). 아래 아코디언 7종.

struct BoardItem: Identifiable {
    enum Kind { case event, deadline, grm, conference, experiment, undated }
    let id: String
    let date: Date?
    var hasTime: Bool = true
    var end: Date? = nil
    let what: String
    var who: String = ""
    let kind: Kind
    var link: HubLink? = nil
    var mine: Bool = false
    /// 이 행이 가리키는 학회(ConferenceRow.id) — 학회 행과, 같은 사건으로 판정된 리마인더 행 (0.38.0 C1, 관심 칩 C4)
    var confKey: String? = nil
}

/// 안내판 한 화면의 데이터 (0.35.0) — 왼쪽(마감·오늘)과 오른쪽(내일부터)을 나눈다
struct BoardData {
    /// 마감 블록 — 마감·학회 행 중 아직 안 지난 앞 2개
    var deadlines: [BoardItem] = []
    /// 오늘(내일 0시 전) 행 — 끝난 일정 제외, 지난 오늘 리마인더는 남김, 마감 블록 항목 제외. 오늘 GRM(끝나기 전) 포함
    var today: [BoardItem] = []
    /// 내일 0시 이후 행 — 캘린더는 내일 0시+72h 까지, 리마인더·학회(60일)·그랜트는 그대로. 마감 블록 항목도 남긴다(표에서 흐리게). GRM 행 없음
    var later: [BoardItem] = []
    /// GRM 순번 띠 — 내일 이후 GRM 앞 8개
    var grmBand: [GRMSlot] = []
    /// 날짜 없는 것(실험·미정 그랜트)
    var tail: [BoardItem] = []
}

/// 안내판 왼쪽 열 글자 3단계 (BHL R2, 0.35.0) — 왼쪽 열 안의 글자는 이 셋만. 다음 수정이 크기를 다시 늘어놓지 않게 한곳에 고정
/// static var (0.37.0 C3) — 글자 배율(HubDisplay)이 바뀌면 읽을 때마다 다시 계산
private enum BoardType {
    /// 큰 숫자 — 시계·첫 마감 남은 시간
    static var big: Font { Font.hub(60, weight: .bold, design: .rounded).monospacedDigit() }
    /// 제목 — 마감 제목·오늘 일정 행
    static var title: Font { Font.hub(18, weight: .semibold) }
    /// 보조 — 날짜·블록 이름·둘째 마감·'지남'·'+n건'
    static var aux: Font { Font.hub(13, weight: .regular) }
}

/// 안내판 far(멀리서) 글자 3단계 (0.38.0 C2, BHL B-2) — far 안의 글자는 이 셋만 (0.37.0 의 9종을 셋으로)
private enum FarType {
    /// 큰 숫자 — 급한 마감 남은 시간
    static var big: Font { Font.hub(64, weight: .bold, design: .rounded).monospacedDigit() }
    /// 제목 — 급한 마감 제목·오늘 남은 일정 행
    static var title: Font { Font.hub(36, weight: .semibold) }
    /// 보조 — 맨 위 시각 줄·블록 이름·'지남'·'+n건'
    static var aux: Font { Font.hub(20, weight: .regular) }
}

struct BoardView: View {
    @ObservedObject var model: NotionHubModel
    @State private var open: String? = nil
    @State private var didAutoOpen = false
    @ObservedObject private var commits: DelayedCommit
    init(model: NotionHubModel) { self.model = model; _commits = ObservedObject(wrappedValue: model.reminderCommits) }
    /// 거리 사다리 (D10): 포인터가 움직이면 near, 3분 무입력이면 far (멀리서 3항목 + 큰 보드 3행). DESKHUB_IDLE=far|near 로 고정
    @State private var far: Bool = HubClock.idle == "far"
    @State private var lastActivity = Date()
    private let idleTimer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    private var me: String { HubPrefs.me }

    // MARK: 데이터 (순수 함수)

    /// 보드 행: 캘린더(내일 0시+72h) + 컨펌 리마인더 + GRM + 학회 초록 마감(60일) + 날짜 있는 그랜트 → 오늘·이후로 나눔, 끝에 날짜 없는 것
    @MainActor
    static func data(model: NotionHubModel, now: Date, me: String) -> BoardData {
        let c = Calendar.current
        let todayStart = c.startOfDay(for: now)
        let tomorrow = c.date(byAdding: .day, value: 1, to: todayStart)!
        // 캘린더·GRM 지평 = 내일 0시 + 72h — upcoming(days: 4) 의 끝과 같다 (오른쪽 표 = 내일부터 3일)
        let horizon = tomorrow.addingTimeInterval(72 * 3600)
        var out: [BoardItem] = []
        // 내 것 판정 — AlertEngine 과 같은 코드(NotionHubModel.isMine): me 비면·빈 이름·빈 이니셜 행이면 false (R2-03 BHL, 검증 1 리뷰)
        func isMine(_ text: String) -> Bool { model.isMine(text, me: me) }
        func initials(_ names: String) -> String { whoInitials(model, names) }
        for e in model.todayCalendar?.upcoming(days: 4) ?? [] where e.end > now && e.start < horizon && !e.title.lowercased().hasPrefix("grm") {
            let title = Hub.canonicalNames(e.title)
            out.append(BoardItem(id: "ev-" + e.id + "\(e.start.timeIntervalSince1970)", date: e.start, hasTime: !e.isAllDay, end: e.end,
                                 what: title, kind: .event, link: .calendarDay(e.start), mine: isMine(title)))
        }
        for r in model.confirmedReminders {
            guard let d = r.day, d >= todayStart else { continue }
            let due = Phase.deadlineTime(r.title, day: d)
            out.append(BoardItem(id: "rem-" + r.id, date: due, hasTime: r.title.contains(":"), what: "◆ " + r.title, kind: .deadline,
                                 link: r.source.hasPrefix("notion:") ? .notion(String(r.source.dropFirst(7))) : nil, mine: isMine(r.title)))
        }
        // GRM 행은 오늘 것만 왼쪽 오늘 일정에 (내일 이후는 grmBand 띠)
        var grmRows: [BoardItem] = []
        for g in model.grm where g.date >= todayStart && g.date < horizon {
            let at = c.date(bySettingHour: 10, minute: 0, second: 0, of: g.date)!
            if at.addingTimeInterval(5400) <= now { continue }   // 끝난 GRM 은 내림
            grmRows.append(BoardItem(id: "grm-" + g.id, date: at, end: at.addingTimeInterval(5400), what: "GRM" + (g.notified ? "" : " · 공지—"),
                                     who: initials(g.presenters), kind: .grm, link: .notion(g.id), mine: isMine(g.presenters)))
        }
        for cf in model.conferences {
            guard let d = cf.deadline, d >= todayStart, d < now.addingTimeInterval(60 * 86400) else { continue }
            // 같은 사건인 리마인더 행이 있을 때만 학회 행을 뺀다 — 그 리마인더 행에 학회 연결(confKey)을 단다(제목은 사용자 글이라 그대로).
            // 날짜가 다른 준비 리마인더('… 포스터 초안')는 학회 행을 숨기지 않는다 → 학회 마감은 늘 마감일 행으로 보인다 (BHL B-4, 0.38.0)
            if let i = out.firstIndex(where: { sameConference($0, cf, deadline: d) }) { out[i].confKey = cf.id; continue }
            // 마감일 00:00 이면 그날 아침에 이미 '지남'(date >= now 실패)이 되어 마감 블록에서 빠진다 → 그랜트·리마인더처럼 그날 23:59 (검증 1 리뷰)
            // 제목 = '<학회> 초록 마감' — 리마인더 제안 제목(NotionHub reminderProposals)과 같은 꼴, 날짜 칸 = 마감일 (BHL B-4)
            out.append(BoardItem(id: "conf-" + cf.id, date: Phase.deadlineTime(cf.conference, day: d), hasTime: false,
                                 what: "◆ \(InterestFile.displayName(cf)) 초록 마감", kind: .conference, link: cf.link.map(HubLink.url),
                                 mine: isMine(cf.conference + " " + cf.title), confKey: cf.id))
        }
        for g in model.grants {
            guard let d = g.due, d >= todayStart else { continue }
            if out.contains(where: { $0.kind == .deadline && $0.date.map { c.isDate($0, inSameDayAs: d) } == true }) { continue }
            out.append(BoardItem(id: "grant-" + g.id, date: Phase.deadlineTime(g.title, day: d), hasTime: false, what: "◆ " + g.title, kind: .deadline, mine: isMine(g.title)))
        }
        let byDate: (BoardItem, BoardItem) -> Bool = { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        let rows = out.sorted(by: byDate)
        let withGRM = (out + grmRows).sorted(by: byDate)
        let deadlines = Array(rows.filter { ($0.kind == .deadline || $0.kind == .conference) && ($0.date ?? .distantPast) >= now }.prefix(2))
        let inBlock = Set(deadlines.map(\.id))
        var tail: [BoardItem] = model.experiments.map { x in
            BoardItem(id: "x-" + x.id, date: nil, what: "실험 \(x.source) · \(x.title)", who: initials(x.owner), kind: .experiment, link: x.url.map(HubLink.url), mine: isMine(x.owner))
        }
        let undated = model.grants.filter { $0.due == nil }
        if !undated.isEmpty { tail.append(BoardItem(id: "grant-undated", date: nil, what: "그랜트 일정 미정 \(undated.count)건", kind: .undated)) }
        return BoardData(deadlines: deadlines,
                         today: withGRM.filter { ($0.date ?? .distantFuture) < tomorrow && !inBlock.contains($0.id) },
                         later: rows.filter { ($0.date ?? .distantPast) >= tomorrow },
                         grmBand: Array(model.grm.filter { $0.date >= tomorrow }.prefix(8)),
                         tail: tail)
    }

    /// far 두 블록의 데이터 (0.38.0 C2, BHL B-2) — 순수 함수, 화면과 `--dump-phase` 가 같이 쓴다.
    /// urgent = 마감 블록(앞 2개) 중 D≤7(허브 '가까운 것' 마감 기준과 같음), today = 오늘 남은 일정(마감 블록 항목·끝난 일정은 이미 빠짐) — 둘은 서로소
    static func farData(_ d: BoardData, now: Date) -> (urgent: [BoardItem], today: [BoardItem]) {
        (d.deadlines.filter { daysUntil($0.date, now: now) <= 7 }, d.today)
    }

    /// '누구' 이니셜 — 표 '누구' 칸·GRM 띠·덤프 공용 (0.38.0 C1). 멤버가 아닌 이름(외부 발표자·Guest)은 72pt 칸에 긴 이름이 들어가 깨진다
    /// → 멤버 이니셜만, 아니면 짧은 '외부' (리뷰 10-15 low). 공백으로 잇는다
    @MainActor
    static func whoInitials(_ model: NotionHubModel, _ names: String) -> String {
        names.components(separatedBy: ",").map { raw -> String in
            let n = raw.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return "" }
            let i = model.initials(forName: n); return i == n && model.member(initials: n) == nil ? "외부" : i
        }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// 행이 가리키는 학회(confKey)의 관심 이니셜 — 없으면 [] (0.38.0 C4)
    @MainActor
    static func interestNames(_ model: NotionHubModel, _ it: BoardItem) -> [String] {
        guard let k = it.confKey, let c = model.conferences.first(where: { $0.id == k }) else { return [] }
        return model.interestNames(c)
    }

    /// 학회 마감과 같은 사건인 리마인더 행인가 — 제안 id 'conf:'+행 id 를 확정한 것, 또는 (학회 이름이 비어 있지 않고 제목에 들어 있고 마감일과 같은 날)
    static func sameConference(_ it: BoardItem, _ cf: ConferenceRow, deadline d: Date) -> Bool {
        guard it.kind == .deadline, it.id.hasPrefix("rem-") else { return false }
        if it.id == "rem-conf:" + cf.id { return true }
        guard !cf.conference.isEmpty, it.what.contains(cf.conference), let rd = it.date else { return false }
        return Calendar.current.isDate(rd, inSameDayAs: d)
    }

    /// 상태 열 — 계산된 말. 시각 열과 겹치지 않게 '남은 양'만 (35분 후 · 13시간 후 · D-4 · D-57), 뺄셈이 필요한 날짜 표기 없음
    static func status(_ it: BoardItem, now: Date) -> (String, Bool) {
        guard let d = it.date else { return ("", false) }
        if let e = it.end, d <= now && now < e { return ("진행 중 · 남은 \(Int(e.timeIntervalSince(now) / 60))분", true) }
        let mins = Int(d.timeIntervalSince(now) / 60)
        if mins < 0 { return ("지남", false) }
        if it.hasTime && mins < 60 { return ("\(max(mins, 1))분 후", false) }
        if it.hasTime && mins < 48 * 60 { return ("\(Int((Double(mins) / 60).rounded()))시간 후", false) }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now), to: Calendar.current.startOfDay(for: d)).day ?? 0
        return (days == 0 ? "오늘" : days == 1 ? "내일" : "D-\(days)", false)
    }

    /// 'M.d E' (ko_KR, 예: '10.16 금') — 오른쪽 표 날짜 칸·GRM 띠·덤프 공용
    static func dayLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "M.d E"; return f.string(from: d)
    }
    /// 오늘 0시부터 그날까지 며칠 (D-n 의 n)
    static func daysUntil(_ d: Date?, now: Date) -> Int {
        guard let d else { return Int.max }
        let c = Calendar.current
        return c.dateComponents([.day], from: c.startOfDay(for: now), to: c.startOfDay(for: d)).day ?? Int.max
    }
    static func clean(_ what: String) -> String { what.replacingOccurrences(of: "◆ ", with: "") }
    /// 진행 중 일정 (시작했고 끝나기 전)
    static func isLive(_ it: BoardItem, now: Date) -> Bool { it.end.map { e in (it.date ?? .distantFuture) <= now && now < e } ?? false }
    /// 시각 칸 글자 — 종일 일정은 '종일', 시각 없는 마감은 '—'
    static func timeText(_ it: BoardItem) -> String { it.hasTime ? (it.date.map(Hub.time) ?? "") : (it.kind == .event ? "종일" : "—") }

    /// `--dump-phase` 끝에 붙는 안내판 블록 (0.35.0) — 같은 입력이면 같은 글
    @MainActor
    static func dump(model: NotionHubModel, now: Date, me: String) -> String {
        let d = data(model: model, now: now, me: me)
        let muted = Set(d.deadlines.map(\.id))
        var lines = ["[안내판] \(dayLabel(now)) \(Hub.time(now)) · 나 \(me.isEmpty ? "—" : me)"]
        func section(_ head: String, _ items: [String]) { lines.append(head); lines += items.isEmpty ? ["  (없음)"] : items.map { "  " + $0 } }
        func who(_ it: BoardItem) -> String { (it.who.isEmpty ? "" : " @" + it.who) + (it.mine ? " (내 것)" : "") }
        func todayLine(_ it: BoardItem) -> String {
            (isLive(it, now: now) ? "● " : "") + "\(timeText(it)) \(it.what)\(who(it)) [\(status(it, now: now).0)]"
                + (it.id.hasPrefix("rem-") && (it.date ?? .distantFuture) < now ? " (지남)" : "")
        }
        section("마감:", d.deadlines.map { "\(clean($0.what)) [\(status($0, now: now).0)]" })
        section("오늘:", d.today.map(todayLine))
        // 학회 행(과 같은 사건 리마인더 행) 끝에 관심 이니셜 ' 관심[JOP,JYK,SMJ]' — 화면 칩과 같은 소스 (0.38.0 C4)
        section("오른쪽:", d.later.map { it in
            let ci = interestNames(model, it)
            return "\(it.date.map(dayLabel) ?? "") \(timeText(it)) \(it.what)\(who(it)) [\(status(it, now: now).0)]" + (muted.contains(it.id) ? " (흐림)" : "")
                + (ci.isEmpty ? "" : " 관심[" + ci.joined(separator: ",") + "]")
        })
        // 띠 칩과 같은 글자 'M.d 이니셜'(요일 없음) + 내 차례면 ' [굵게]' (BHL B-3, 0.38.0)
        section("GRM 띠:", d.grmBand.map { g in
            let notice = !g.notified && daysUntil(g.date, now: now) <= 5 ? " · 공지—" : ""
            return grmChipText(model, g) + (model.isMine(g.presenters, me: me) ? " [굵게]" : "") + notice
        })
        section("끝:", d.tail.map { $0.what + who($0) })
        // far 두 블록 (0.38.0 C2) — 형식은 '마감:'·'오늘:' 과 같다. 화면은 급한 마감 최대 2·오늘 최대 6 + '+n건'
        let f = farData(d, now: now)
        section("far 급한 마감:", f.urgent.map { "\(clean($0.what)) [\(status($0, now: now).0)]" })
        section("far 오늘 남은 일정:", f.today.map(todayLine))
        return lines.joined(separator: "\n")
    }

    var body: some View {
        let now = model.now
        let data = Self.data(model: model, now: now, me: me)
        let hour = Calendar.current.component(.hour, from: now)
        let night = hour >= 22 || hour < 8
        Group {
            // far = 급한 마감·오늘 남은 일정 두 블록 (0.38.0), near = 왼쪽 시계·마감·오늘 일정 + 오른쪽 표 (0.35.0)
            if far { farMode(data, now: now) } else { nearMode(data, now: now) }
        }
        .padding(16)
        // 밤(22–08)엔 휘도 35% — 위에 어두운 막 (클릭은 통과)
        .overlay { if night { Color.black.opacity(0.62).allowsHitTesting(false) } }
        .onContinuousHover { phase in
            guard HubClock.idle == nil else { return }
            if case .active = phase {
                lastActivity = Date()
                if far { withAnimation(.easeOut(duration: 0.4)) { far = false } }
            }
        }
        .onReceive(idleTimer) { _ in
            guard HubClock.idle == nil, !far, Date().timeIntervalSince(lastActivity) > 180 else { return }
            withAnimation(.easeOut(duration: 0.8)) { far = true }
        }
    }

    /// far — 2~3m 거리 (0.38.0 C2, BHL B-2 '급한 마감 일정과 오늘 남은 일정만, 내용 중복 없게'): 맨 위 시각 한 줄(블록 아님) +
    /// '급한 마감'(D≤7, 최대 2 — 없으면 블록 없음) + '오늘 남은 일정'(최대 6 + '+n건'). 두 목록은 farData 로 서로소.
    /// 글자는 FarType 셋, 색은 Hub.text·Hub.ink(첫 급한 마감 D≤3 이면 남은 시간만 Hub.signal)
    private func farMode(_ data: BoardData, now: Date) -> some View {
        let f = Self.farData(data, now: now)
        let maxRows = 6
        return VStack(alignment: .leading, spacing: 36) {
            Text(Hub.time(now) + " · " + Hub.longDay(now)).font(FarType.aux).lineLimit(1)
            if !f.urgent.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text("급한 마감").font(FarType.aux)
                    ForEach(Array(f.urgent.prefix(2).enumerated()), id: \.element.id) { i, it in
                        deadlineLine(it, now: now, title: FarType.title, big: FarType.big, minTitle: Hub.s(240), alert: i == 0, choice: i == 0 ? "board-far" : nil)
                            .link(it.link)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("오늘 남은 일정").font(FarType.aux)
                // 캘린더 첫 조회 전엔 '없음' 이 아니다 (near 와 같은 규칙)
                if f.today.isEmpty { Text(model.todayCalendar?.isSettled == false ? "불러오는 중…" : "남은 일정 없음").font(FarType.aux) }
                ForEach(f.today.prefix(maxRows)) { it in farRow(it, now: now) }
                if f.today.count > maxRows { Text("+\(f.today.count - maxRows)건").font(FarType.aux) }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Hub.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// far '오늘 남은 일정' 한 줄 — 시각(폭 120) · 제목. 진행 중 ●(ink), 내 것 왼쪽 2pt ink 막대, 지난 리마인더 '지남' (near leftRow 와 같은 규칙)
    private func farRow(_ it: BoardItem, now: Date) -> some View {
        let overdue = it.id.hasPrefix("rem-") && (it.date ?? .distantFuture) < now
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Self.timeText(it)).font(FarType.title.monospacedDigit()).frame(width: Hub.s(120), alignment: .leading)
            if Self.isLive(it, now: now) { Text("●").font(FarType.aux).foregroundStyle(Hub.ink) }
            Text(it.what + (it.who.isEmpty ? "" : " · " + it.who)).font(FarType.title).lineLimit(1)
            if overdue { Text("지남").font(FarType.aux) }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10).padding(.vertical, 2)
        .overlay(alignment: .leading) { if it.mine { Rectangle().fill(Hub.ink).frame(width: 2) } }
        .opacity(pendingOpacity(it))
        .link(it.link)
    }

    /// 마감 한 건 '<제목>  D-n' (BHL B-1, 0.38.0 — D-day 만 크고 대상이 안 보이던 것) — 넓으면 나란히(제목은 남는 폭에서 2줄까지),
    /// 남은 시간이 길거나('13시간 후') 칸이 좁으면 제목 위·남은 시간 아래(0.37.0 모양). near 마감 블록·far 급한 마감 공용.
    /// 남은 시간 색: alert 이고 D≤3 이면 Hub.signal, 아니면 Hub.ink. 고른 갈래는 windows.txt 'choices:'(LayoutChoice)
    private func deadlineLine(_ it: BoardItem, now: Date, title: Font, big: Font, minTitle: CGFloat, alert: Bool, choice: String?) -> some View {
        let name = Self.clean(it.what)
        let st = Self.status(it, now: now).0
        let color = alert && Self.daysUntil(it.date, now: now) <= 3 ? Hub.signal : Hub.ink
        // 제목은 fixedSize(vertical) — 세로 반쪽 칸(nearLeft 가 fixedSize(vertical) 로 재는 곳)에서 한 줄 높이만 받아
        // 'BK21 자체평가 항목별…' 로 잘리던 것(0.38.0 검증 1, v38-board-tall). 받은 폭에서 2줄까지 제 높이를 쓴다
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                Text(name).font(title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: minTitle, idealWidth: minTitle, maxWidth: .infinity, alignment: .leading)
                Text(st).font(big).foregroundStyle(color).lineLimit(1).fixedSize()
            }
            .layoutChoice(choice, "한 줄")
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(st).font(big).lineLimit(1).minimumScaleFactor(0.5).foregroundStyle(color)
            }
            .layoutChoice(choice, "두 줄")
        }
        .help(name)
    }

    private func nearMode(_ data: BoardData, now: Date) -> some View {
        GeometryReader { geo in
            let h = geo.size.height
            let tall = h / max(geo.size.width, 1) > 1.4   // TowerView 와 같은 기준 (R2)
            // 마감 블록에 크게 보인 것은 표에서 흐리게 (R2-04 BHL — 같은 것이 두 번 강조되지 않게)
            let mutedIDs = Set(data.deadlines.map(\.id))
            let tableRows = tableRowCount(data)
            Group {
                if tall {
                    VStack(alignment: .leading, spacing: 14) {
                        // 세로: 위층은 내용 높이(최대 35%), 보드가 나머지 (R2-01 JYK)
                        nearLeft(data, now: now, tall: true).fixedSize(horizontal: false, vertical: true).frame(maxHeight: h * 0.35, alignment: .top)
                        board(data, now: now, height: h * 0.65, mutedIDs: mutedIDs)
                    }
                } else {
                    HStack(alignment: .top, spacing: 18) {
                        nearLeft(data, now: now, tall: false).frame(width: geo.size.width / 3)
                        board(data, now: now, height: h, mutedIDs: mutedIDs)
                    }
                }
            }
            // 세로·높은 화면(5K)은 아래 빈 면이 크므로 논문 추천을 처음부터 펼쳐 둔다
            // 표 아래가 300pt 넘게 남으면 논문 추천을 처음부터 펼쳐 둔다 (R2-01: 가로 1313×1155 에서도 아래 절반이 비었음)
            .onAppear { autoOpen(tall: tall, h: h, rows: tableRows) }
            // 데이터 로드 전에 나타나면(기본 뷰) 행 0 으로 판정해 버림 → Notion 이 온 뒤 한 번 더 (리뷰 2)
            .onChange(of: model.lastUpdated) { _, _ in autoOpen(tall: tall, h: h, rows: tableRows) }
        }
    }

    /// 오른쪽 표의 행 수 (autoOpen 추정용) — 표는 내일부터(later)와 날짜 없는 것(tail). GRM 띠는 표 밖
    private func tableRowCount(_ data: BoardData) -> Int { data.later.count + data.tail.count }

    /// 표 아래가 300pt 넘게 남으면(또는 세로) 논문 추천을 처음부터 펼친다 — Notion 데이터가 온 뒤 한 번만 확정
    private func autoOpen(tall: Bool, h: CGFloat, rows: Int) {
        guard !didAutoOpen, model.lastUpdated != nil else { return }
        didAutoOpen = true
        let est = h - CGFloat(rows + 1) * 46 - 120
        if open == nil && (tall || est > 300) { open = "papers" }
    }

    // MARK: 왼쪽 열 (near) — ① 시계 ② 마감 ③ 오늘 일정. 글자는 BoardType 셋만, 색은 Hub.text·Hub.ink (첫 마감 D≤3 만 Hub.signal)

    private func nearLeft(_ data: BoardData, now: Date, tall: Bool) -> some View {
        Group {
            if tall {
                // 세로: 위층 높이(창의 35% 이하)를 넘지 않게 [시계·마감 | 오늘 일정] 두 칸
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 28) {
                        leftClock(now)
                        leftDeadlines(data.deadlines, now: now)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    leftToday(data.today, now: now, maxRows: 4).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                VStack(alignment: .leading, spacing: 28) {
                    leftClock(now)
                    leftDeadlines(data.deadlines, now: now)
                    leftToday(data.today, now: now, maxRows: 8)
                    Spacer(minLength: 0)
                }
            }
        }
        .foregroundStyle(Hub.text)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func leftClock(_ now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Hub.time(now)).font(BoardType.big)
            Text(Hub.longDay(now)).font(BoardType.aux).lineLimit(1)
        }
    }

    /// 마감 — 블록 이름 · 첫 마감 '<제목>  남은 시간(큰 숫자)' 나란히(넘치면 두 줄, deadlineLine) · 둘째 마감 한 줄(보조)
    @ViewBuilder
    private func leftDeadlines(_ ds: [BoardItem], now: Date) -> some View {
        if let first = ds.first {
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("마감").font(BoardType.aux)
                    deadlineLine(first, now: now, title: BoardType.title, big: BoardType.big, minTitle: Hub.s(160), alert: true, choice: "board-deadline")
                }
                .link(first.link)
                if ds.count > 1 {
                    let second = ds[1]
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Self.clean(second.what)).font(BoardType.aux).lineLimit(1)
                        Text(Self.status(second, now: now).0).font(BoardType.aux).foregroundStyle(Hub.ink).fixedSize()
                    }
                    .link(second.link)
                }
            }
        }
    }

    /// 오늘 일정 — 시각(폭 64) + 제목. 진행 중 ●(ink), 내 것 왼쪽 2pt ink 막대, 지난 리마인더 '지남'. 넘치면 '+n건'
    private func leftToday(_ rows: [BoardItem], now: Date, maxRows: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("오늘 일정").font(BoardType.aux)
            // 캘린더 첫 조회 전엔 '없음' 이 아니다 (0.37.0 C6)
            if rows.isEmpty { Text(model.todayCalendar?.isSettled == false ? "불러오는 중…" : "남은 일정 없음").font(BoardType.aux) }
            ForEach(rows.prefix(maxRows)) { it in leftRow(it, now: now) }
            if rows.count > maxRows { Text("+\(rows.count - maxRows)건").font(BoardType.aux) }
            // 리마인더 행만 있고 캘린더는 아직 — 오른쪽 표·허브·관제탑과 같은 규칙 (0.37.0 리뷰 2)
            if !rows.isEmpty, model.todayCalendar?.isSettled == false {
                Text("캘린더 불러오는 중…").font(BoardType.aux).foregroundStyle(Hub.text2)
            }
        }
    }

    private func leftRow(_ it: BoardItem, now: Date) -> some View {
        let overdue = it.id.hasPrefix("rem-") && (it.date ?? .distantFuture) < now
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Self.timeText(it)).font(BoardType.title.monospacedDigit()).frame(width: Hub.s(64), alignment: .leading)
            if Self.isLive(it, now: now) { Text("●").font(BoardType.aux).foregroundStyle(Hub.ink) }
            Text(it.what + (it.who.isEmpty ? "" : " · " + it.who)).font(BoardType.title).lineLimit(1)
            if overdue { Text("지남").font(BoardType.aux) }
            Spacer(minLength: 0)
        }
        .padding(.leading, 8).padding(.vertical, 2)
        // 내 것: 왼쪽 2pt 막대 (오른쪽 표와 같은 표시, Hub.ink — 적색 예산 밖)
        .overlay(alignment: .leading) { if it.mine { Rectangle().fill(Hub.ink).frame(width: 2) } }
        .opacity(pendingOpacity(it))
        .link(it.link)
        .rowRail(reminderRail(it))
    }

    // MARK: 리마인더 행 공용 — 왼쪽 오늘 일정과 오른쪽 표가 같은 레일·같은 흐림을 쓴다

    /// ◆ 리마인더 행 호버 레일: 끝남(6초 되돌리기) · 원본
    private func reminderRail(_ it: BoardItem) -> [RailButton] {
        guard it.id.hasPrefix("rem-") else { return [] }
        return [RailButton(symbol: "checkmark", help: "끝남 (6초 안에 되돌리기)") { finish(String(it.id.dropFirst(4))) }]
            + (it.link.map { l in [RailButton(symbol: "arrow.up.forward", help: l.help) { l.open() }] } ?? [])
    }
    /// '끝남' 을 눌러 되돌리기 대기 중인 리마인더 행은 흐리게
    private func pendingOpacity(_ it: BoardItem) -> Double {
        it.id.hasPrefix("rem-") && commits.isPending(String(it.id.dropFirst(4))) ? 0.4 : 1
    }

    // MARK: 보드 — 오른쪽 = 내일 0시부터 (캘린더 72h, 마감은 그대로), 날짜·요일 칸은 그날 첫 행에만. GRM 순번은 표 위 독립 띠 (BHL R2 B3·B4, 0.35.0)

    private func board(_ data: BoardData, now: Date, height: CGFloat, mutedIDs: Set<String> = []) -> some View {
        let rows = data.later
        let c = Calendar.current
        // 아코디언을 펼쳤을 때 표는 내용 높이(행 ~44pt 추정, 최대 55%)만 쓰고 펼친 카드가 나머지를 채운다 (R2-01). GRM 띠는 표 밖이라 빼고 셈
        let rowsH = CGFloat(max(rows.count, 1)) * 44 + CGFloat(data.tail.count) * 32 + 12
        // '누구' 열: 전부 비면 숨김, 아니면 이니셜만 72pt (R2-03 BHL '빈 칸')
        let showWho = (rows + data.tail).contains { !$0.who.isEmpty || $0.mine }
        return VStack(alignment: .leading, spacing: 8) {
            // GRM 순번 — 표 머리 위 고정 한 줄. 표 ScrollView 가 남은 높이를 받으므로 '표 아래' 는 행 수에 따라 위치가 흔들린다 (제자리)
            if !data.grmBand.isEmpty { grmBand(data.grmBand, now: now) }
            HStack(spacing: 0) {
                Text("날짜").frame(width: Hub.s(76), alignment: .leading)
                Text("시각").frame(width: Hub.s(56), alignment: .leading)
                Text("무엇").frame(maxWidth: .infinity, alignment: .leading)
                if showWho { Text("누구").frame(width: Hub.s(72), alignment: .leading) }
                Text("상태").frame(width: Hub.s(170), alignment: .leading)
            }
            .font(.hub(11.5, weight: .bold)).foregroundStyle(Hub.text3).padding(.horizontal, 12)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    if rows.isEmpty {
                        Text(model.todayCalendar?.isSettled == false ? "불러오는 중…" : "내일부터 3일 일정 없음").font(.hub(13)).foregroundStyle(Hub.text2)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 12)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, it in
                        // 그날 첫 행에만 날짜, 날짜가 바뀌는 곳은 위 여백을 조금 더 (뺄셈 없이 날짜 묶음이 보이게)
                        let firstOfDay = i == 0 || !(rows[i - 1].date.flatMap { p in it.date.map { c.isDate(p, inSameDayAs: $0) } } ?? false)
                        boardRow(it, now: now, muted: mutedIDs.contains(it.id), showWho: showWho, showDate: firstOfDay)
                            .padding(.top, firstOfDay && i > 0 ? 6 : 0)
                            .transition(.opacity)
                        if i < rows.count - 1 { RowDivider() }
                    }
                    // 마감 행만 있고 캘린더는 아직 — 끝난 목록처럼 보이지 않게 한 줄 (0.37.0 C6 검증 1)
                    if !rows.isEmpty, model.todayCalendar?.isSettled == false {
                        RowDivider()
                        Text("캘린더 불러오는 중…").font(.hub(13)).foregroundStyle(Hub.text2)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                    }
                    // 날짜 없는 끝 행 — 통째로 흐리게(투명도) 하지 않고 날짜·시각·누구·상태 칸만 Hub.text2, '무엇' 은 다른 행과 같은 색 (BHL B-4, 0.38.0)
                    ForEach(data.tail) { it in RowDivider(); boardRow(it, now: now, dim: true, showWho: showWho) }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Hub.surface))
                .overlay(alignment: .bottom) { UndoToast(commits: commits).padding(8) }
                // 끝난 행은 1.5초 페이드로 퇴장 (위치 이동 애니메이션 없음)
                .animation(.easeOut(duration: 1.5), value: rows.map(\.id))
            }
            .frame(maxHeight: open == nil ? .infinity : min(rowsH, height * 0.55))
            accordion.padding(.top, 2).frame(maxHeight: open == nil ? nil : .infinity, alignment: .top)
            HStack(spacing: 10) {
                // 무엇의 시각인지 혼자서도 읽히게 — 'Notion 갱신 HH:mm' (UX smartwatch-19)
                Text("Notion 갱신 " + (model.lastUpdated.map(Hub.time) ?? "—")).font(.hub(10.5)).foregroundStyle(Hub.text3)
                Spacer()
                Text("DeskHub \(Hub.buildLabel)").font(.hub(10.5)).foregroundStyle(Hub.text3)
            }
        }
    }

    /// muted = 마감 블록에 크게 보인 행(굵기만 regular·상태 적색 없음), dim = 날짜 없는 끝 행(실험·미정 그랜트 — 날짜·시각·누구·상태 칸만 Hub.text2).
    /// '무엇' 칸은 모든 행이 Hub.text 한 색 (BHL B-4, 0.38.0 — 흐림은 굵기로만)
    private func boardRow(_ it: BoardItem, now: Date, muted: Bool = false, dim: Bool = false, showWho: Bool = true, showDate: Bool = false) -> some View {
        let (st, live) = Self.status(it, now: now)
        let c = Calendar.current
        // 날짜 칸 'M.d E'(그날 첫 행만) + 시각 칸(매 행). '내일 ' 같은 접두는 쓰지 않는다 — 날짜 칸이 맡는다
        let dayText = showDate ? (it.date.map(Self.dayLabel) ?? "") : ""
        // 시각 없는 마감·학회 행도 왼쪽·덤프와 같은 '—' (0.38.0 C1)
        let timeText = Self.timeText(it)
        let soon = it.date.map { $0.timeIntervalSince(now) < 48 * 3600 && $0 > now } ?? false
        // 오늘·내일만 크게, 모레부터는 작게 (R2, JYK: '며칠 뒤 일정까지 크게 보일 필요 없음').
        // 날짜 없는 끝 행(dim)도 작게 — 0.38.0 에서 투명도 0.55 를 뺀 뒤 17pt 로 날짜 있는 마감 행보다 커 보였다(검증 1 리뷰). '무엇' 색은 그대로 Hub.text 한 토큰
        let later = dim || (it.date.map { $0 >= c.date(byAdding: .day, value: 2, to: c.startOfDay(for: now))! } ?? false)
        return HStack(spacing: 0) {
            Text(dayText).font(.hub(later ? 13 : 16, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Hub.text2)
                .lineLimit(1).minimumScaleFactor(0.8).frame(width: Hub.s(76), alignment: .leading)
            Text(timeText).font(.hub(later ? 13 : 16, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Hub.text2)
                .lineLimit(1).minimumScaleFactor(0.8).frame(width: Hub.s(56), alignment: .leading)
            // 학회 행(과 같은 사건 리마인더 행)은 무엇 오른쪽에 관심 이니셜 칩 — 보기만, 토글은 허브·관제탑 (0.38.0 C4)
            let interest = Self.interestNames(model, it)
            HStack(spacing: 6) {
                Text(it.what).font(.hub(later ? 13.5 : 17, weight: !muted && !dim && (it.kind == .deadline || it.kind == .grm || it.mine) ? .semibold : .regular)).lineLimit(1)
                    .foregroundStyle(Hub.text)
                    .layoutPriority(1)
                if !interest.isEmpty { InterestChips(names: interest, me: me.uppercased()) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showWho {
                // 이니셜만. 내 행인데 담당 칸이 비면 내 이니셜 칩 (R2-03)
                Group {
                    if it.who.isEmpty && it.mine {
                        Text(me).font(.hub(11.5, weight: .bold, design: .rounded)).foregroundStyle(Hub.ink)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Hub.ink.opacity(0.6), lineWidth: 1))
                    } else {
                        Text(it.who).font(.hub(13, weight: .bold, design: .rounded)).foregroundStyle(it.mine && !dim ? Hub.ink : Hub.text2).lineLimit(1)
                            .link(model.memberLink(it.who.components(separatedBy: " ").first ?? ""))   // 이니셜 → Members 페이지 (행 클릭과 별도)
                    }
                }
                .frame(width: Hub.s(72), alignment: .leading)
            }
            HStack(spacing: 6) {
                Text(st).font(.hub(later ? 12.5 : 15, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(dim ? Hub.text2 : live ? Hub.ok : (!muted && (it.kind == .deadline || it.kind == .conference) && soon ? Hub.signal : Hub.text2))
                    .lineLimit(1)
                // 시각 CTA — 10분 안에 시작하면 [열기]
                if let d = it.date, it.hasTime, d > now, d.timeIntervalSince(now) <= 600, let l = it.link {
                    Button { l.open() } label: {
                        Text("열기").font(.hub(12, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Hub.ink.opacity(0.16))).foregroundStyle(Hub.ink)
                    }.buttonStyle(.plain)
                }
            }
            .frame(width: Hub.s(170), alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, later ? 5 : 10)
        // 내 이니셜 관련 행: 옅은 배경 + 왼쪽 2pt 막대 (Hub.ink — 적색 예산 밖)
        .background(it.mine ? Hub.ink.opacity(0.08) : Color.clear)
        .overlay(alignment: .leading) { if it.mine { Rectangle().fill(Hub.ink).frame(width: 2) } }
        .opacity(pendingOpacity(it))
        .link(it.link)
        // ◆ 리마인더 행 호버 레일: 끝남(6초 되돌리기) · 원본 — 왼쪽 오늘 일정과 같은 헬퍼
        .rowRail(reminderRail(it))
    }

    private func finish(_ id: String) {
        guard let r = model.reminders.first(where: { $0.id == id }) else { return }
        if commits.isPending(id) { commits.undo(id) } else { commits.schedule(id: id, label: "\(r.title) · 끝남") { model.setReminder(r, status: "done") } }
    }

    /// GRM 띠 칩 글자 'M.d 이니셜' — GRM 은 늘 수요일이라 요일을 쓰지 않는다 (BHL B-3, 0.38.0). 발표자가 비면 '미정'
    @MainActor
    static func grmChipText(_ model: NotionHubModel, _ g: GRMSlot) -> String {
        let who = whoInitials(model, g.presenters)
        return Hub.shortDay(g.date) + " " + (who.isEmpty ? "미정" : who)
    }

    /// GRM 순번 띠 — 내일 이후 GRM 앞 8개, 한 줄(넘치면 가로 스크롤). 칩 = 'M.d 이니셜', 내 차례는 굵게만(테두리·글자 표시 없음, 툴팁),
    /// 5일 안인데 공지 미발송이면 그 칩에 '공지—' (관제탑 경보 'GRM 공지 아직' 과 같은 기준). 표 안에는 GRM 행이 없다(오늘 GRM 은 왼쪽 오늘 일정)
    private func grmBand(_ slots: [GRMSlot], now: Date) -> some View {
        HStack(spacing: 8) {
            Text("GRM 순번").font(.hub(12, weight: .bold)).foregroundStyle(Hub.text3).fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Hub.s(14)) {
                    ForEach(slots) { g in
                        // 내 것 판정은 NotionHubModel.isMine 한 규칙(이름 전체 또는 이니셜 토큰), 보이는 글자는 이니셜 — 표시는 굵기 하나 (BHL B-3)
                        let mine = model.isMine(g.presenters, me: me)
                        let noticeMissing = !g.notified && Self.daysUntil(g.date, now: now) <= 5
                        let link = HubLink.notion(g.id)
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(Self.grmChipText(model, g))
                                .font(.hub(13, weight: mine ? .bold : .regular)).foregroundStyle(Hub.text)
                                .help(mine ? "내 차례 — " + link.help : link.help)
                            if noticeMissing { Text("공지—").font(.hub(11.5, weight: .medium)).foregroundStyle(Hub.text2) }
                        }
                        .lineLimit(1)
                        .padding(.vertical, 4)
                        .link(link)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
    }

    // MARK: 아코디언 — 7종 한 줄, 하나만 펼침

    private var accordion: some View {
        // 숫자엔 단위 — 안내판은 멀리서 한 번 보고 지나가므로 '5' 만으로는 무엇의 수인지 모른다 (UX smartwatch-19)
        // 논문 추천 생산자가 멈췄으면 '논문 · 6.1 이후 없음' + 펼쳐도 한 줄 (0.40.0 C8, R4)
        let papersLabel = model.papersStopped ? "논문 · \(model.papersStoppedSince) 이후 없음" : "논문 \(model.papers.count)편"
        let items: [(String, String)] = [("papers", papersLabel), ("minutes", "회의록"), ("blitz", "Blitz \(model.blitz.count)편"),
                                         ("grants", "그랜트 \(model.grants.count)건"), ("preprints", "원고 \(model.preprints.count)편"),
                                         ("members", "멤버 \(model.members.filter(\.active).count)명"), ("tools", "메일 초안")]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(items, id: \.0) { k, label in
                    Text((open == k ? "▾ " : "▸ ") + label).font(.hub(12.5, weight: .semibold))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(open == k ? Hub.ink.opacity(0.14) : Hub.surface))
                        .foregroundStyle(open == k ? Hub.ink : Hub.text2)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { open = open == k ? nil : k } }
                }
            }
            if let k = open {
                // 펼친 카드는 남은 높이를 채운다 (안쪽 스크롤). 짧은 카드는 내용 높이 + 아래 Spacer
                Group {
                    switch k {
                    case "papers": PaperRecBoard(model: model, fold: true).frame(maxHeight: model.papersStopped ? nil : .infinity)
                    case "minutes": ScrollView(.vertical, showsIndicators: false) { MinutesCard(model: model, minutesExpanded: true) }.frame(maxHeight: .infinity)
                    case "blitz": BlitzCompact(model: model).frame(maxHeight: .infinity)
                    case "grants": GrantsSection(model: model)
                    case "preprints": LatestManuscripts(model: model)
                    case "members": MembersProjectsStrip(model: model)
                    default: AppsScriptSection(model: model)
                    }
                }
                .transition(.opacity)
                Spacer(minLength: 0)
            }
        }
    }
}
