import SwiftUI
import AppKit

// MARK: - 모든 뷰가 함께 쓰는 행 부품 (디자인 계획 D1 — docs/design-plan-2026-10-14.md §3 P0-1~3)
// - Hub.relative: 상대 시간 표기 하나로 통일 ('35분 후' · '내일 18:00 · 22h' · 'D-4' · '10.30')
// - RowRail: 행에 마우스를 올렸을 때만 오른쪽에 작은 아이콘 버튼(최대 3개)을 띄운다 — 평소엔 조용하게
// - DelayedCommit: 제자리 상태 변경을 몇 초 미뤄 두고 그 사이 되돌릴 수 있게 (UndoToast)

/// 시계 — 화면에 쓰는 '지금'은 모두 여기서. 스냅샷을 같은 입력으로 비교하려고 환경변수로 고정할 수 있다 (D2)
///   DESKHUB_NOW=2026-10-14T20:07  → 그 시각에 멈춘 시계
///   DESKHUB_ME=BYL                → 이 맥의 사용자 이니셜 (HubPrefs.me)
///   DESKHUB_IDLE=far|near          → 안내판 거리 단계 고정 (D10)
///   DESKHUB_RAIL_FILL=0           → 관제탑 가로 2열 채우기 끔 (N1 (b) 안 비교용)
/// 캐시 만료·기록 시각 같은 실제 시간은 Date() 를 그대로 쓴다
enum HubClock {
    static let fixed: Date? = {
        guard let v = ProcessInfo.processInfo.environment["DESKHUB_NOW"], !v.isEmpty else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] { f.dateFormat = fmt; if let d = f.date(from: v) { return d } }
        return nil
    }()
    static var now: Date { fixed ?? Date() }
    /// 날짜 키 하나 (R-L1, 0.36.0) — 하루 한 번 결정·settledDay·touchedDay·D-day 가 모두 이 달력. model.now(1분 루프)는 표시용
    static var today: Date { Calendar.current.startOfDay(for: now) }
    static let idle: String? = ProcessInfo.processInfo.environment["DESKHUB_IDLE"].flatMap { $0.isEmpty ? nil : $0 }
}

/// 링크 해석기 — 고유명사(Notion 페이지·NAS 파일·DOI·캘린더 날짜·검색)를 한 곳에서 원본으로 (D2, 전수 적용은 D14)
enum HubLink {
    case notion(String)            // 페이지·DB id
    case nas(String)               // 절대 경로 (파일이면 열기, 폴더면 Finder)
    case doi(String)               // "10.xxxx/..." 또는 https://doi.org/...
    case url(URL)
    case calendarDay(Date)         // Google 캘린더 그 날
    case scholar(String)           // 제목으로 Google Scholar 검색

    var help: String {
        switch self {
        case .notion: return "Notion 에서 열기"
        case .nas(let p): return "NAS · " + (p as NSString).lastPathComponent
        case .doi(let d): return "DOI · " + d.replacingOccurrences(of: "https://doi.org/", with: "")
        case .url(let u): return u.host ?? u.absoluteString
        case .calendarDay(let d): return "Google 캘린더 · " + Hub.day(d)
        case .scholar: return "Google Scholar 검색"
        }
    }

    /// 누르면 실제로 열리나 — 없는 NAS 경로는 비프음뿐 (공정 보드 대체 링크 판정, UX 0.34.0)
    var opens: Bool {
        if case .nas(let p) = self { return FileManager.default.fileExists(atPath: p) }
        return true
    }
    /// 링크 종류 — 덤프용 (notion·nas·url·doi·cal·scholar). 없는 NAS 경로는 nas✗
    var kindLabel: String {
        switch self {
        case .notion: return "notion"
        case .nas: return opens ? "nas" : "nas✗"
        case .doi: return "doi"
        case .url: return "url"
        case .calendarDay: return "cal"
        case .scholar: return "scholar"
        }
    }

    @MainActor func open() {
        UsageLog.action("open")
        switch self {
        case .notion(let id): NotionLink.open(id: id)
        case .nas(let p):
            guard FileManager.default.fileExists(atPath: p) else { NSSound.beep(); return }
            NSWorkspace.shared.open(URL(fileURLWithPath: p))
        case .doi(let d):
            if let u = URL(string: d.hasPrefix("http") ? d : "https://doi.org/" + d) { NSWorkspace.shared.open(u) }
        case .url(let u): NSWorkspace.shared.open(u)
        case .calendarDay(let d):
            let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
            if let y = c.year, let m = c.month, let dd = c.day, let u = URL(string: "https://calendar.google.com/calendar/r/day/\(y)/\(m)/\(dd)") { NSWorkspace.shared.open(u) }
        case .scholar(let t):
            if let u = URL(string: "https://scholar.google.com/scholar?q=" + (t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")) { NSWorkspace.shared.open(u) }
        }
    }
}

extension NotionHubModel {
    /// 이름·이니셜이 들어 있는 글자 → 그 사람 Members 페이지 (D14 고유명사 링크)
    func memberLink(_ text: String) -> HubLink? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if let m = member(initials: t) { return .notion(m.id) }
        if let m = members.first(where: { !$0.name.isEmpty && t.contains($0.name) }) { return .notion(m.id) }
        return nil
    }
}

extension View {
    /// 원본으로 가는 클릭 + 툴팁을 한 번에
    func link(_ l: HubLink?) -> some View {
        self.contentShape(Rectangle()).onTapGesture { MainActor.assumeIsolated { l?.open() } }.help(l?.help ?? "")
    }
}

extension Hub {
    /// 모든 뷰에서 숨길 반복 일정 (R2, JYK: 'SL research hours 는 어느 뷰든 안 보여도 됨').
    /// 기본값 + `defaults write kr.ac.snu.csnl.deskhub DeskHub.hideEvents -array "…"` 로 바꿈 (부분 일치, 대소문자 무시)
    static var hiddenEventPatterns: [String] {
        UserDefaults.standard.stringArray(forKey: "DeskHub.hideEvents") ?? ["SL research hours"]
    }
    static func isHiddenEvent(_ title: String) -> Bool {
        let t = title.lowercased()
        return hiddenEventPatterns.contains { !$0.isEmpty && t.contains($0.lowercased()) }
    }
    /// 요일 없는 "M.d" — 좁은 칸용
    static func shortDay(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "M.d"; return f.string(from: d) }
    /// 상대 시간. hasTime=false 면 날짜 단위로만 (D-day)
    static func relative(_ date: Date, now: Date, hasTime: Bool = true) -> String {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let day = cal.startOfDay(for: date)
        let days = cal.dateComponents([.day], from: today, to: day).day ?? 0
        if hasTime {
            let mins = Int(date.timeIntervalSince(now) / 60)
            if mins < 0 && mins > -60 { return "\(-mins)분 전" }
            if mins >= 0 && mins < 60 { return mins == 0 ? "지금" : "\(mins)분 후" }
            let hours = Int((Double(mins) / 60).rounded())
            if days == 0 { return mins < 0 ? "오늘 " + time(date) : "오늘 " + time(date) + " · \(hours)h" }
            if days == 1 { return "내일 " + time(date) + " · \(hours)h" }
        }
        if days < 0 { return days == -1 ? "어제" : "D+\(-days)" }
        if days == 0 { return "오늘" }
        if days == 1 && !hasTime { return "내일" }
        if days < 14 { return "D-\(days)" }
        return shortDay(date)
    }
}

/// 호버 레일 버튼 하나
struct RailButton: Identifiable {
    let id = UUID()
    let symbol: String
    let help: String
    let action: () -> Void
}

/// 행에 붙이는 호버 레일. 평소엔 아무것도 안 보이고, 마우스를 올리면 오른쪽 끝에 아이콘 ≤3개
struct RowRail: ViewModifier {
    let buttons: [RailButton]
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .trailing) {
                if hovering && !buttons.isEmpty {
                    HStack(spacing: 2) {
                        ForEach(buttons.prefix(3)) { b in
                            Button(action: b.action) {
                                Image(systemName: b.symbol).font(.hub(12, weight: .medium)).frame(width: 24, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).foregroundStyle(Hub.text2).help(b.help)
                        }
                    }
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Hub.surface).shadow(color: .black.opacity(0.12), radius: 3, y: 1))
                    .padding(.trailing, 8)
                    .transition(.opacity)
                }
            }
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

extension View {
    func rowRail(_ buttons: [RailButton]) -> some View { modifier(RowRail(buttons: buttons)) }
}

/// 미뤄 둔 상태 변경. seconds 안에 undo 하면 취소, 지나면 commit 실행
@MainActor
final class DelayedCommit: ObservableObject {
    struct Pending: Identifiable, Equatable {
        let id: String
        let label: String
        static func == (a: Pending, b: Pending) -> Bool { a.id == b.id }
    }
    @Published private(set) var pending: [Pending] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    let seconds: Double
    init(seconds: Double = 6) { self.seconds = seconds }

    func isPending(_ id: String) -> Bool { pending.contains { $0.id == id } }

    func schedule(id: String, label: String, commit: @escaping @MainActor () -> Void) {
        tasks[id]?.cancel()
        withAnimation(.easeOut(duration: 0.15)) {
            pending.removeAll { $0.id == id }
            pending.append(Pending(id: id, label: label))
        }
        let ns = UInt64(seconds * 1_000_000_000)
        // 강하게 잡는다 — 뷰가 바뀌어 소유자가 사라져도 (6초 안) 커밋은 실행돼야 한다
        tasks[id] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled, self.isPending(id) else { return }
            withAnimation(.easeOut(duration: 0.6)) { self.pending.removeAll { $0.id == id } }
            self.tasks[id] = nil
            commit()
        }
    }

    func undo(_ id: String) {
        tasks[id]?.cancel(); tasks[id] = nil
        withAnimation(.easeOut(duration: 0.15)) { pending.removeAll { $0.id == id } }
    }
}

/// 미뤄 둔 변경을 보여 주는 한 줄 — '되돌리기'
struct UndoToast: View {
    @ObservedObject var commits: DelayedCommit
    @Environment(\.cardStyle) private var cs
    var body: some View {
        if let p = commits.pending.last {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Hub.ok)
                Text(p.label).font(.hub(cs.aux, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                if commits.pending.count > 1 { Text("+\(commits.pending.count - 1)").font(.hub(cs.tag)).foregroundStyle(Hub.text3) }
                Button("되돌리기") { commits.undo(p.id) }
                    .buttonStyle(.plain).font(.hub(cs.aux, weight: .semibold)).foregroundStyle(Hub.ink)
                    .help("\(Int(commits.seconds))초 안에 누르면 취소")
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Hub.ink.opacity(0.08)))
            .transition(.opacity)
        }
    }
}

// MARK: - 카드 글자 역할 (0.37.0, 랩장 10-16 18:12 '여백 줄이고 글자 크게')
/// 카드 안 글자를 리터럴 대신 역할로 — 제목(SectionTitle) · 본문(행 제목) · 보조(날짜·설명·출처) · 꼬리표(이니셜·D-day·상태·TypePill) · 큰 값(다음 GRM 발표자)
/// + 행 가로·세로 여백 · 제목↔본문 간격 · 빈 상태 여백. 기본(.standard)은 0.36.0 값, 랩 허브(Dashboard)만 .large 를 환경으로 내려 준다.
/// 다음 크기 요청은 이 두 값만 고친다 (계획 0.37.0 §5 ⑤ — 리터럴 344곳을 다시 고치지 않게)
struct CardStyle: Equatable {
    var title: CGFloat, body: CGFloat, aux: CGFloat, tag: CGFloat, big: CGFloat
    var rowH: CGFloat, rowV: CGFloat, gap: CGFloat, empty: CGFloat
    /// 글자가 든 고정 폭(날짜·D-day·출처 칸)의 배율 — 큰 글자에서 '…' 로 잘리지 않게
    var colScale: CGFloat
    /// × 글자 배율(HubDisplay.scale, 0.37.0 C3) — 슬라이더로 키워도 날짜·D-day 칸이 '…' 로 잘리지 않게
    func col(_ w: CGFloat) -> CGFloat { (w * colScale * HubDisplay.scale).rounded() }

    static let standard = CardStyle(title: 12, body: 13, aux: 12, tag: 11, big: 14, rowH: 12, rowV: 8, gap: 8, empty: 12, colScale: 1)
    /// 랩 허브 — 제목 ≥16 · 본문 ≥14 (교수님 기본 화면)
    static let large = CardStyle(title: 16, body: 15, aux: 14, tag: 14, big: 20, rowH: 10, rowV: 5, gap: 4, empty: 8, colScale: 1.2)

    private static func n(_ v: CGFloat) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", Double(v)) }
    /// text.txt [허브 글자] 한 줄
    var dumpLine: String {
        "제목 \(Self.n(title)) · 본문 \(Self.n(body)) · 보조 \(Self.n(aux)) · 꼬리표 \(Self.n(tag)) · 큰 값 \(Self.n(big)) · 행 여백 \(Self.n(rowH))×\(Self.n(rowV))"
            + " · 카드 간격 \(Self.n(HubSpace.card)) · 바깥 \(Self.n(HubSpace.outer))"
    }
}

private struct CardStyleKey: EnvironmentKey { static let defaultValue = CardStyle.standard }
extension EnvironmentValues {
    var cardStyle: CardStyle {
        get { self[CardStyleKey.self] }
        set { self[CardStyleKey.self] = newValue }
    }
}

/// 랩 허브 여백 (0.37.0) — 바깥 테두리 · 열 사이 · 같은 열 카드 사이. 0.36.0 은 모두 12
enum HubSpace {
    static let outer: CGFloat = 8
    static let column: CGFloat = 8
    static let card: CGFloat = 8
}

// MARK: - 허브 '가까운 것만' + 제자리 펼침 (0.37.0 C2, 랩장 10-16 18:12 '가까운 정보만 노출되고 토글로 펼쳐지게')

/// 카드 하나의 접힘·펼침 목록. near = 접힘에서 보일 것(가까운 것), full = '더 보기' 를 눌렀을 때 보일 것
struct NearCut<T> {
    let near: [T]
    let full: [T]
    /// '가장 가까운 1' 처럼 기준 밖에서 골라 보인 경우의 메모 (덤프 끝 괄호)
    let note: String?
    /// 펼치면 더 보이는 수 — '▸ 더 보기 · n개'
    var more: Int { max(0, full.count - near.count) }
    func shown(open: Bool) -> [T] { open ? full : near }
    func hidden(open: Bool) -> Int { open ? 0 : more }
}

/// 순수 함수 — 카드마다 (model, 지금) → (보일 것, 펼칠 것, 메모). 뷰와 text.txt [허브 카드] 가 같은 함수를 쓴다.
/// 공통 규칙: 가까운 것이 0개인데 자료가 있으면 가장 가까운 1개(카드가 빈 것처럼 보이지 않게). 기준값은 계획 0.37.0 §2 C2 표 — 교수님 사용 뒤 조정(§4-3)
@MainActor
enum HubNear {
    static let keys = ["events", "reminders", "grants", "conferences", "experiments", "minutes", "blitz", "papers", "preprints", "apps"]

    static func days(_ model: NotionHubModel, _ d: Date) -> Int {
        Calendar.current.dateComponents([.day], from: model.today, to: Calendar.current.startOfDay(for: d)).day ?? 0
    }
    /// "D-3" · "D-0" · "D+2" — 덤프용 (화면은 Hub.dday·relative)
    static func dLabel(_ n: Int) -> String { n >= 0 ? "D-\(n)" : "D+\(-n)" }

    /// near 가 비면 full 앞 fallback 개 (fallback 0 이면 그대로 빈 접힘)
    static func cut<T>(full: [T], near: [T], fallback: Int = 1, note: String = "가장 가까운 1") -> NearCut<T> {
        if near.isEmpty, !full.isEmpty, fallback > 0 { return NearCut(near: Array(full.prefix(fallback)), full: full, note: note) }
        return NearCut(near: near, full: full, note: nil)
    }
    /// 원래 순서를 지키며 near 를 모두 담고, 나머지는 limit 까지 — 펼쳤을 때 접힘에 있던 행이 빠지지 않게
    static func union<T: Identifiable>(_ all: [T], near: [T], limit: Int) -> [T] {
        let ids = Set(near.map { AnyHashable($0.id) })
        var room = max(0, limit - near.count)
        return all.filter { x in
            if ids.contains(AnyHashable(x.id)) { return true }
            if room > 0 { room -= 1; return true }
            return false
        }
    }

    // 다가오는 일정 — 오늘·내일(시작 < 오늘 0시 + 2일) 최대 6 · 펼침 maxRows(8)
    static func events(_ model: NotionHubModel, items: [UpcomingEventsCard.Item], maxRows: Int = 8) -> NearCut<UpcomingEventsCard.Item> {
        let end = Calendar.current.date(byAdding: .day, value: 2, to: model.today)!
        let near = Array(items.filter { $0.date < end }.prefix(6))
        return cut(full: union(items, near: near, limit: maxRows), near: near)
    }

    /// 리마인더 한 줄 — 확정(proposal=false) 또는 제안
    struct ReminderLine: Identifiable { let item: ReminderItem; let proposal: Bool; var id: String { (proposal ? "p:" : "c:") + item.id } }
    // 리마인더 — 확정 D≤7(지난 것 포함) 최대 6 · 제안 D≤7 최대 2 · 펼침 확정 6 + 제안 4 (0.36.0 동작)
    static func reminders(_ model: NotionHubModel) -> NearCut<ReminderLine> {
        let soon = Calendar.current.date(byAdding: .day, value: 7, to: model.today)!
        let conf = Array(model.confirmedReminders.prefix(6))
        let props = Array(model.reminderProposals.filter { !model.reminderCommits.isPending($0.id) }.prefix(4))
        var nearC = conf.filter { $0.day.map { $0 <= soon } ?? false }
        let nearP = Array(props.filter { $0.day.map { $0 <= soon } ?? false }.prefix(2))
        // 7일 안 확정이 없어도 확정이 있으면 가장 가까운 1 — 제안만 보이며 '등록된 리마인더 없음' 이 뜨지 않게 (검증 1 리뷰)
        var note: String? = nil
        if nearC.isEmpty, let first = conf.first { nearC = [first]; note = "가장 가까운 확정 1" }
        let full = conf.map { ReminderLine(item: $0, proposal: false) } + props.map { ReminderLine(item: $0, proposal: true) }
        let near = nearC.map { ReminderLine(item: $0, proposal: false) } + nearP.map { ReminderLine(item: $0, proposal: true) }
        if let note { return NearCut(near: near, full: full, note: note) }
        return cut(full: full, near: near)
    }

    // 그랜트 — 마감 D≤7 · 펼침 전체(D>7·미정·'확인 필요')
    static func grants(_ model: NotionHubModel) -> NearCut<GrantRow> {
        let near = model.grants.filter { g in g.due.map { days(model, $0) <= 7 } ?? false }
        return cut(full: model.grants, near: near)
    }

    /// 학회 행의 기준 — 접수 중 초록 마감 D≤14 면 '마감 D-n', 아니면 '개최 D-n'
    static func conferenceBasis(_ model: NotionHubModel, _ c: ConferenceRow) -> (label: String, near: Bool) {
        if let d = c.deadline, d >= model.today {
            let n = days(model, d)
            if n <= 14 { return ("마감 " + dLabel(n), true) }
        }
        let h = days(model, c.start)
        return ("개최 " + dLabel(h), h <= 30)
    }
    // 학회 — 접수 중 초록 마감 D≤14 또는 개최 D≤30 최대 3 · 펼침 limit(설정 conferencesCount·maxRows)
    static func conferences(_ model: NotionHubModel, limit: Int) -> NearCut<ConferenceRow> {
        let near = Array(model.conferences.filter { conferenceBasis(model, $0).near }.prefix(3))
        return cut(full: union(model.conferences, near: near, limit: limit), near: near)
    }

    // 실험 — SLab·자원(오늘) + Prolific 진행 중 최대 4 · 펼침 + 준비 중, 최대 6
    // 가까운 것이 없으면 대체 1 을 고르지 않는다 — 아무도 돌리지 않는 준비 중 초안이 기본 화면을 채우지 않게.
    // 카드는 '오늘 예약·진행 중 없음 · 준비 중 n개는 더 보기' 한 줄 (0.37.0 검증 1)
    static func experiments(_ model: NotionHubModel) -> NearCut<ExperimentRow> {
        let near = Array(model.experiments.filter { $0.source != "Prolific" || $0.status == ProlificFilter.activeLabel }.prefix(4))
        return cut(full: union(model.experiments, near: near, limit: 6), near: near, fallback: 0)
    }

    // 회의록 — 최근 1 (+ '녹취 도착' 줄은 늘 보임) · 펼침 recentMinutesCount
    static func minutes(_ model: NotionHubModel) -> NearCut<MeetingNote> {
        let full = Array(model.minutes.prefix(max(1, model.cfg.recentMinutesCount)))
        return NearCut(near: Array(full.prefix(1)), full: full, note: nil)
    }

    /// Blitz 순서 — 내 발표가 있으면 맨 앞, 나머지는 덱 순서
    static func blitzOrdered(_ model: NotionHubModel, me: String) -> [BlitzPaper] {
        guard let mine = model.myMember(me) else { return model.blitz }
        let isMine: (BlitzPaper) -> Bool = { model.member(initials: $0.presenter)?.id == mine.id }
        return model.blitz.filter(isMine) + model.blitz.filter { !isMine($0) }
    }
    // 지난 Paper Blitz — 최신 회차 첫 3편(내 발표 먼저) · 펼침 그 회차 전체
    static func blitz(_ model: NotionHubModel, me: String) -> NearCut<BlitzPaper> {
        let all = blitzOrdered(model, me: me)
        return NearCut(near: Array(all.prefix(3)), full: all, note: nil)
    }

    // 논문 추천 — 지금 '보기' 대상 중 7일 안에 보낸 것, 없으면 티어 순 첫 2 · 펼침 전체(스크롤)
    static func papers(_ model: NotionHubModel, visible: [PaperRec]) -> NearCut<PaperRec> {
        let since = Calendar.current.date(byAdding: .day, value: -7, to: model.today)!
        let near = visible.filter { $0.sentAt.map { Calendar.current.startOfDay(for: $0) >= since } ?? false }
        return cut(full: visible, near: near, fallback: 2, note: "티어 순 2")
    }

    // 최신 원고 — 30일 안 최대 2 · 펼침 4
    static func preprints(_ model: NotionHubModel) -> NearCut<PreprintRow> {
        let full = Array(model.preprints.prefix(4))
        let since = Calendar.current.date(byAdding: .day, value: -30, to: model.today)!
        let near = Array(full.filter { $0.date.map { $0 >= since } ?? false }.prefix(2))
        return cut(full: full, near: near)
    }

    // 만든 앱 — 머리 한 줄만 · 펼침 전체
    static func apps(_ apps: [MadeApp]) -> NearCut<MadeApp> { NearCut(near: [], full: apps, note: nil) }

    /// text.txt [허브 카드] — 카드마다 '<key> · 보임 n · 숨김 k · 펼침 on|off · <보인 행의 기준값>' (+ ' (가장 가까운 1)')
    static func dumpLines(_ model: NotionHubModel) -> [String] {
        let ex = HubExpansion.shared
        func line<T>(_ key: String, _ c: NearCut<T>, _ basis: (T) -> String) -> String {
            let open = ex.isOpen(key)
            let shown = c.shown(open: open)
            let vals = shown.map(basis).joined(separator: ", ")
            return "\(key) · 보임 \(shown.count) · 숨김 \(c.hidden(open: open)) · 펼침 \(open ? "on" : "off") · \(vals.isEmpty ? "—" : vals)" + (c.note.map { " (\($0))" } ?? "")
        }
        let me = HubPrefs.me
        let items = UpcomingEventsCard.items(model: model, cal: model.todayCalendar, excludeToday: false)
        let who = PaperRecBoard.who(filter: HubPrefs.paperFilter, me: me)
        return [
            line("events", events(model, items: items)) { Hub.shortDay($0.date) },
            line("reminders", reminders(model)) { r in (r.proposal ? "제안 " : "") + (r.item.day.map { dLabel(days(model, $0)) } ?? "미정") },
            line("grants", grants(model)) { g in g.due.map { dLabel(days(model, $0)) } ?? "미정" },
            line("conferences", conferences(model, limit: min(model.cfg.conferencesCount, 5))) { conferenceBasis(model, $0).label },
            line("experiments", experiments(model)) { x in [x.source, x.status].filter { !$0.isEmpty }.joined(separator: " ") },
            line("minutes", minutes(model)) { m in m.date.map(Hub.shortDay) ?? "—" },
            line("blitz", blitz(model, me: me)) { p in (model.blitzDate.map(Hub.shortDay) ?? "—") + " " + (p.presenter.isEmpty ? "?" : p.presenter) },
            line("papers", papers(model, visible: PaperRecBoard.visible(model, who: who))) { p in p.sentAt.map(Hub.shortDay) ?? "—" },
            line("preprints", preprints(model)) { r in r.date.map(Hub.shortDay) ?? "—" },
            line("apps", apps(MadeApps.load().apps)) { $0.name },
        ]
    }
}

/// 허브 카드 펼침 상태 — 이 맥(UserDefaults DeskHub.hubExpanded, 문자열 배열). 공용 맥이면 모두가 공유(계획 §4-5)
@MainActor
final class HubExpansion: ObservableObject {
    static let shared = HubExpansion()
    static let defaultsKey = "DeskHub.hubExpanded"
    @Published private(set) var open: Set<String>
    private init() { open = Set(UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []) }
    func isOpen(_ key: String) -> Bool { open.contains(key) }
    /// 클릭·--key expand:<key> 가 같은 경로. 다 접히면 키를 지운다(defaults read 에 남지 않게)
    func toggle(_ key: String) {
        withAnimation(.easeOut(duration: 0.2)) {
            if open.contains(key) { open.remove(key) } else { open.insert(key) }
        }
        if open.isEmpty { UserDefaults.standard.removeObject(forKey: Self.defaultsKey) }
        else { UserDefaults.standard.set(open.sorted(), forKey: Self.defaultsKey) }
    }
}

/// 카드 꼬리 전체 폭 바 — '▸ 더 보기 · n개' / '▾ 접기'. 클릭 1회·제자리(관제탑 railLine·회의록 펼치기 바와 같은 easeOut 0.2). 더 보일 것이 없으면 그리지 않는다
struct MoreToggle: View {
    let key: String
    /// 펼치면 더 보이는 수 (NearCut.more)
    let more: Int
    /// 위 구분선 — 행이 하나도 없는 접힘(만든 앱)에서는 뺀다
    let divider: Bool
    @ObservedObject private var store = HubExpansion.shared
    @Environment(\.cardStyle) private var cs
    init(key: String, more: Int, divider: Bool = true) { self.key = key; self.more = more; self.divider = divider }
    var body: some View {
        if more > 0 {
            let open = store.isOpen(key)
            VStack(spacing: 0) {
                if divider { RowDivider() }
                Button { store.toggle(key) } label: {
                    Text(open ? "▾ 접기" : "▸ 더 보기 · \(more)개")
                        .font(.hub(cs.aux, weight: .medium)).foregroundStyle(Hub.text2)
                        .frame(maxWidth: .infinity).padding(.vertical, cs.rowV).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(open ? "접기 — 가까운 것만 (이 맥에 저장)" : "이 카드의 나머지 \(more)개를 제자리에서 펼침 (이 맥에 저장)")
            }
        }
    }
}

// MARK: - 글자 크기·색 프리셋 (0.37.0 C3, 랩장 10-16 18:12 '폰트사이즈 조절, 색상조절도 간단하게 버튼이나 슬라이더로')
// 방식 (b) 중앙 글자 헬퍼: 모든 글자를 Font.hub 로 그려 배율을 곱한다. 루트 확대(scale 변환)는 쓰지 않는다 —
// 창 안 NSViewRepresentable(창 끌기·손잡이·Notion 웹뷰)이 SwiftUI 변환을 따르지 않아 클릭 좌표가 어긋나고 글자가 흐려지므로

extension Font {
    /// 시스템 글꼴 × 글자 배율(HubDisplay.scale). 앱 안 글자 크기는 모두 이것으로 그린다 (0.37.0 기계 치환)
    static func hub(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size * HubDisplay.scale, weight: weight, design: design)
    }
}

extension Hub {
    /// 글자가 든 고정 폭 × 글자 배율 — 날짜·시각·누구 칸, 팝오버 폭 (카드 안은 CardStyle.col)
    static func s(_ w: CGFloat) -> CGFloat { (w * HubDisplay.scale).rounded() }
}

/// 이 맥의 글자 배율·색 프리셋 — UserDefaults DeskHub.textScale(0.9…1.6, 0.1 단위)·DeskHub.colorPreset(default|contrast|dark).
/// config.json 에는 쓰지 않는다. 값이 바뀌면 revision 이 올라 창 본문을 다시 만든다(Notion 재조회·창 재생성 없음).
/// 시작 값 훅(스냅샷용): DESKHUB_TEXT_SCALE=1.3 · DESKHUB_COLOR_PRESET=contrast
@MainActor
final class HubDisplay: ObservableObject {
    static let shared = HubDisplay()
    static let range: ClosedRange<Double> = 0.9...1.6
    static let presets = ["default", "contrast", "dark"]
    static let presetNames = ["default": "기본", "contrast": "고대비", "dark": "어두움"]
    /// Font.hub 가 읽는 배율 (뷰 밖에서도 읽도록 정적)
    nonisolated(unsafe) static private(set) var scale: CGFloat = 1

    @Published private(set) var textScale: Double
    @Published private(set) var colorPreset: String
    /// 바뀔 때마다 +1 — 창 본문 .id
    @Published private(set) var revision = 0
    /// 허브 머리 '글자' 단추가 여는 작은 판
    @Published var panelOpen = false
    /// AppDelegate 가 단다 — 색 프리셋이 바뀌면 테마·외형 다시 적용 + 바닥판 다시 칠하기
    var onPresetChange: (() -> Void)?

    private init() {
        let env = ProcessInfo.processInfo.environment, d = UserDefaults.standard
        var s = d.object(forKey: "DeskHub.textScale") as? Double ?? 1.0
        if let v = env["DESKHUB_TEXT_SCALE"].flatMap(Double.init) { s = v }
        textScale = Self.clamp(s)
        var p = d.string(forKey: "DeskHub.colorPreset") ?? "default"
        if let v = env["DESKHUB_COLOR_PRESET"], !v.isEmpty { p = v }
        colorPreset = Self.presets.contains(p) ? p : "default"
        Self.scale = CGFloat(textScale)
    }

    /// 범위 안으로 자르고 0.1 단위로
    static func clamp(_ v: Double) -> Double { (min(max(v, range.lowerBound), range.upperBound) * 10).rounded() / 10 }

    /// 슬라이더를 놓을 때·−/+·기본·--key scale:<x> — 같은 경로
    func setScale(_ v: Double) {
        let c = Self.clamp(v)
        UserDefaults.standard.set(c, forKey: "DeskHub.textScale")
        guard c != textScale else { return }
        textScale = c
        Self.scale = CGFloat(c)
        revision += 1
    }
    /// 색 단추·--key preset:<id> — 같은 경로
    func setPreset(_ p: String) {
        guard Self.presets.contains(p) else { return }
        UserDefaults.standard.set(p, forKey: "DeskHub.colorPreset")
        guard p != colorPreset else { return }
        colorPreset = p
        onPresetChange?()
        revision += 1
    }
    var scaleLabel: String { String(format: "%.1f배", textScale) }
    var presetLabel: String { Self.presetNames[colorPreset] ?? "기본" }
}

/// 허브 밖 위젯 창의 본문 — 글자·색이 바뀌면 다시 만든다 (WidgetWindow.setContent 가 감싼다)
struct DisplayRefresh<Content: View>: View {
    @ObservedObject private var display = HubDisplay.shared
    let content: Content
    init(_ content: Content) { self.content = content }
    var body: some View { content.id(display.revision) }
}

/// '글자' 단추로 여는 작은 판 — 본문 오른쪽 위에 겹친다(NSPopover 아님: 비활성 패널에서도 확실히 뜨고 스냅샷에 찍힘). ✕·Esc 로 닫음
struct DisplaySettingsPanel: View {
    @ObservedObject private var display = HubDisplay.shared
    /// 끄는 동안은 숫자만 바뀌고, 놓을 때 한 번 반영 — 끄는 매 프레임마다 창을 다시 만들지 않게
    @State private var draft: Double = HubDisplay.shared.textScale

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("글자 크기 · 색").font(.hub(14, weight: .bold))
                Text("이 맥에만 저장").font(.hub(11)).foregroundStyle(Hub.text3)
                Spacer(minLength: 4)
                Button { display.panelOpen = false } label: {
                    Image(systemName: "xmark").font(.hub(11, weight: .bold)).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Hub.text2).help("닫기 (Esc)")
            }
            Text("글자 크기").font(.hub(12, weight: .semibold)).foregroundStyle(Hub.text2)
            HStack(spacing: 8) {
                stepButton("가−", by: -0.1).help("작게 (0.1배)")
                Slider(value: $draft, in: HubDisplay.range, step: 0.1) { editing in if !editing { display.setScale(draft) } }
                    .frame(minWidth: Hub.s(120))
                stepButton("가+", by: 0.1).help("크게 (0.1배)")
                Text(String(format: "%.1f배", draft)).font(.hub(13, weight: .semibold, design: .rounded)).monospacedDigit()
                    .frame(width: Hub.s(44), alignment: .trailing)
                Button("기본") { draft = 1.0; display.setScale(1.0) }
                    .buttonStyle(.plain).font(.hub(12, weight: .medium)).foregroundStyle(Hub.ink).help("1.0배로")
            }
            Text("색").font(.hub(12, weight: .semibold)).foregroundStyle(Hub.text2)
            HStack(spacing: 6) {
                ForEach(HubDisplay.presets, id: \.self) { p in
                    let on = display.colorPreset == p
                    Button { display.setPreset(p) } label: {
                        Text(HubDisplay.presetNames[p] ?? p).font(.hub(12.5, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Hub.ink : Hub.fillNeutral))
                            .foregroundStyle(on ? Hub.onAccent : Hub.text)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(p == "default" ? "설정 파일의 테마·외형 그대로" : (p == "contrast" ? "글자를 더 진하게 — 밝은 곳·먼 거리" : "어두운 바탕"))
                }
            }
        }
        .padding(14)
        .frame(width: Hub.s(360))
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Hub.card).shadow(color: .black.opacity(0.22), radius: 14, y: 4))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Hub.divider))
        .foregroundStyle(Hub.text)
        .onChange(of: display.textScale) { _, v in draft = v }
    }

    private func stepButton(_ label: String, by d: Double) -> some View {
        Button { let v = HubDisplay.clamp(display.textScale + d); draft = v; display.setScale(v) } label: {
            Text(label).font(.hub(12, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Hub.fillNeutral))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 이니셜 칩 (0.37.0 C5 — 학회 관심) — 무채색 캡슐, 내 것은 남색 1.5pt 테두리
struct InitialChip: View {
    let text: String
    var mine = false
    @Environment(\.cardStyle) private var cs
    var body: some View {
        Text(text).font(.hub(cs.tag - 0.5, weight: .bold, design: .rounded))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Hub.fillNeutral))
            .overlay(Capsule().stroke(mine ? Hub.ink : Color.clear, lineWidth: 1.5))
            .foregroundStyle(mine ? Hub.ink : Hub.text2)
            .help(mine ? "\(text) · 나 — 관심 표시함" : "\(text) · 관심 표시함")
    }
}
