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
    /// 캡션 — 카드 끝 '출처 · 기준 · n · 정의 id' 한 줄 (0.40.0 C2, A1)
    var cap: CGFloat
    var rowH: CGFloat, rowV: CGFloat, gap: CGFloat, empty: CGFloat
    /// 글자가 든 고정 폭(날짜·D-day·출처 칸)의 배율 — 큰 글자에서 '…' 로 잘리지 않게
    var colScale: CGFloat
    /// × 글자 배율(HubDisplay.scale, 0.37.0 C3) — 슬라이더로 키워도 날짜·D-day 칸이 '…' 로 잘리지 않게
    func col(_ w: CGFloat) -> CGFloat { (w * colScale * HubDisplay.scale).rounded() }

    static let standard = CardStyle(title: 12, body: 13, aux: 12, tag: 11, big: 14, cap: 10.5, rowH: 12, rowV: 8, gap: 8, empty: 12, colScale: 1)
    /// 랩 허브 — 제목 ≥16 · 본문 ≥14 (교수님 기본 화면)
    static let large = CardStyle(title: 16, body: 15, aux: 14, tag: 14, big: 20, cap: 12, rowH: 10, rowV: 5, gap: 4, empty: 8, colScale: 1.2)

    private static func n(_ v: CGFloat) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", Double(v)) }
    /// text.txt [허브 글자] 한 줄
    var dumpLine: String {
        "제목 \(Self.n(title)) · 본문 \(Self.n(body)) · 보조 \(Self.n(aux)) · 꼬리표 \(Self.n(tag)) · 큰 값 \(Self.n(big)) · 행 여백 \(Self.n(rowH))×\(Self.n(rowV))"
            + " · 카드 간격 \(Self.n(HubSpace.card)) · 바깥 \(Self.n(HubSpace.outer)) · 캡션 \(Self.n(cap))"
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

extension NearCut where T: Identifiable {
    /// 채움(HubFill, 0.38.0 C3) 반영 — 펼침이면 full, 접힘이면 near + near 밖 앞 extra 개(full 의 원래 순서 — HubNear.union 과 같은 규칙)
    func shown(open: Bool, extra: Int) -> [T] {
        if open || extra <= 0 { return shown(open: open) }
        let ids = Set(near.map { AnyHashable($0.id) })
        var room = extra
        return full.filter { x in
            if ids.contains(AnyHashable(x.id)) { return true }
            if room > 0 { room -= 1; return true }
            return false
        }
    }
    /// 접힘에서 숨은 수(채움으로 보인 것 뺌) — text.txt '숨김'
    func hidden(open: Bool, extra: Int) -> Int { open ? 0 : max(0, more - max(0, extra)) }
    /// MoreToggle 에 넘길 수 — 접힘이면 남은 수('▸ 더 보기 · n개', 0 이면 바 없음), 펼침이면 more('▾ 접기' 가 보이게)
    func toggleCount(open: Bool, extra: Int) -> Int { open ? more : hidden(open: false, extra: extra) }
}

/// 순수 함수 — 카드마다 (model, 지금) → (보일 것, 펼칠 것, 메모). 뷰와 text.txt [허브 카드] 가 같은 함수를 쓴다.
/// 공통 규칙: 가까운 것이 0개인데 자료가 있으면 가장 가까운 1개(카드가 빈 것처럼 보이지 않게). 기준값은 계획 0.37.0 §2 C2 표 — 교수님 사용 뒤 조정(§4-3)
@MainActor
enum HubNear {
    static let keys = ["events", "reminders", "grants", "conferences", "experiments", "minutes", "blitz", "papers", "preprints", "apps", "followups"]

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

    /// text.txt [허브 카드] — 카드마다 '<key> · 보임 n · 숨김 k · 펼침 on|off · <보인 행의 기준값>' (+ ' · 채움 +k' 0.38.0 C3) (+ ' (가장 가까운 1)')
    static func dumpLines(_ model: NotionHubModel) -> [String] {
        let ex = HubExpansion.shared
        let fill = HubFill.shared
        func line<T: Identifiable>(_ key: String, _ c: NearCut<T>, _ basis: (T) -> String) -> String {
            let open = ex.isOpen(key)
            let e = fill.extra[key] ?? 0
            let shown = c.shown(open: open, extra: e)
            let filled = open ? 0 : min(e, c.more)
            let vals = shown.map(basis).joined(separator: ", ")
            return "\(key) · 보임 \(shown.count) · 숨김 \(c.hidden(open: open, extra: e)) · 펼침 \(open ? "on" : "off") · \(vals.isEmpty ? "—" : vals)"
                + (filled > 0 ? " · 채움 +\(filled)" : "") + (c.note.map { " (\($0))" } ?? "")
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
            line("papers", papers(model, visible: PaperRecBoard.visible(model, who: who))) { p in p.sentAt.map(Hub.shortDay) ?? "—" }
                + (model.papersStopped ? " · 접힘(멈춤 \(model.papersStoppedSince))" : ""),
            line("preprints", preprints(model)) { r in r.date.map(Hub.shortDay) ?? "—" },
            line("apps", apps(MadeApps.load().apps)) { $0.name },
            // 미팅 후속 (0.41.0 C3) — 기준값은 상태·회의 날짜만(글 없음). 교수님 보기는 담당 이니셜
            line("followups", followups(model)) { it in
                (model.followupStatus(it) == "confirmed" ? "확정 " : "제안 ") + (it.day.map(Hub.shortDay) ?? "—")
                    + (model.followupView == .read ? " " + (it.who.isEmpty ? "미정" : it.who) : "")
            },
        ]
    }
}

// MARK: - 허브 접힘 빈 면 채우기 (0.38.0 C3, H-FOLD — 0.37.0 접힘에서 세 열 바닥 305~392pt 가 비었음)

/// 열마다 남는 높이(HubLayoutProbe 실측)로 '다음으로 가까운 행'을 카드당 ≤3 더 보인다 — 관제탑 decideExpansion 처럼 데이터가 다 온 뒤·실측 높이·하루 한 번, 단 행 단위.
/// 결정 키 = (오늘, 글자 배율, 열 높이 20pt 단위) — 같으면 다시 정하지 않는다(10분 갱신마다 행이 흔들리지 않게), 바뀌면 그 열을 0 으로 되돌린 뒤 다음 측정에서 다시.
/// 결정 뒤 그 열이 넘치면(스크롤) 마지막에 더한 행 하나씩 뺀다(줄기만 하므로 수렴). 펼친 카드가 있는 열은 정하지도 고치지도 않는다(사용자가 연 것).
/// 잠깐 늘어나는 것(되돌리기 토스트 6초·논문 댓글 칸·'나:' 고르기)이 떠 있는 열도 정하지도 고치지도 않는다 — 토스트 때문에 뺀 행이
/// 그날 내내 돌아오지 않던 것(검증 1 리뷰). 행 높이는 추정 상수(rowH) 대신 실측 평균이 있으면 그것(논문 추천 — 1.3배에서 135×1.3 로 넣었다가 넘쳐 뺐음, 검증 1).
/// 끄기·비교: DESKHUB_HUB_FILL=0. windows.txt 'hub-fill: …' — 열마다 '<카드> +n', 남은 행이 있는데 한 행도 더 안 들어가는 카드는 '(안 맞음 <카드>[ 행 Npt])'
@MainActor
final class HubFill: ObservableObject {
    static let shared = HubFill()
    static let enabled = ProcessInfo.processInfo.environment["DESKHUB_HUB_FILL"] != "0"
    /// 열 → 채움 후보(우선순위 순, 시간에 민감한 것 먼저). 실험(준비 중 초안)·회의록(최근 1)·만든 앱(머리 한 줄)은 0.37.0 '가까운 것' 예외 규칙대로 제외
    static let candidates: [(col: String, keys: [String])] = [("1", ["preprints", "papers"]), ("2", ["events", "reminders", "grants"]), ("3", ["conferences", "blitz"])]
    /// 열 → 그 열의 모든 카드(HubExpansion 키) — 하나라도 펼쳐져 있으면 그 열은 건드리지 않는다
    static let columnCards: [String: [String]] = ["1": ["papers", "preprints", "apps"], "2": ["reminders", "experiments", "events", "grants"], "3": ["followups", "minutes", "blitz", "conferences"]]
    /// 행 높이 추정 (1.0배, CardStyle.large — 0.37.0 그림 실측). × HubDisplay.scale. qa 가 잰 값으로 이 한 곳만 고친다
    static let rowH: [String: CGFloat] = ["events": 30, "reminders": 32, "grants": 66, "conferences": 66, "blitz": 42, "preprints": 62, "papers": 135]
    /// 카드당 더하는 행 상한
    static let cap = 3

    /// 카드 키 → 더 보일 행 수 (접힘일 때만 쓰임)
    @Published private(set) var extra: [String: Int] = [:]
    private weak var model: NotionHubModel?
    private var decided: [String: (key: String, at: Date)] = [:]
    /// 열 → 더한 순서 (넘침 고침은 뒤에서 하나씩)
    private var added: [String: [String]] = [:]
    /// 열의 extra 를 바꾼 때 — 그 뒤 내용 높이 측정이 올 때까지(최대 1초) 결정·고침을 미룬다(바뀌기 전 높이로 정하지 않게)
    private var changedAt: [String: Date] = [:]
    private var waiting: [String: String] = [:]
    private var queued = false
    private var retryQueued = false
    /// 카드 → 보인 행의 실측 평균 높이(그때 배율) — rowsMeasured. 있으면 rowH 추정 대신 쓴다
    private var measuredRowH: [String: (h: CGFloat, scale: CGFloat)] = [:]
    /// 열 → 잠깐 열린 것(논문 댓글 칸·이니셜 고르기 'papers-ui', 학회 이니셜 확인 줄 'conf-me') — setHold. 되돌리기 토스트는 model 의 DelayedCommit 을 직접 본다
    private var holds: [String: Set<String>] = [:]
    /// 열 → 마지막으로 본 측정 서명(내용·보이는 높이 반올림)과 처음 본 때 — 같은 값이 0.5초 넘게 이어질 때만 결정·넘침 고침 (0.39.0 C0, 리뷰 0.38.0 medium).
    /// 펼침·접힘 애니메이션 중간 값, 접은 직후 펼친 상태에서 잰 묵은 값으로 행을 빼던 경로를 막는다
    private var seen: [String: (sig: String, at: Date)] = [:]

    /// Dashboard 가 나타날 때
    func attach(_ m: NotionHubModel) { model = m; poke() }

    /// 카드의 접힘 목록(보인 행들) 높이 — 행 수로 나눈 평균을 그 카드의 행 높이로 (지금은 논문 추천만 단다: 행마다 이유·반응 줄 수가 달라 추정이 크게 틀림)
    func rowsMeasured(_ key: String, height: CGFloat, rows: Int) {
        guard rows > 0, height > 0 else { return }
        measuredRowH[key] = (height / CGFloat(rows), HubDisplay.scale)
    }

    /// 잠깐 열린 것이 열을 늘리는 동안 그 열의 결정·넘침 고침을 멈춘다. 닫히면 한 번 다시 본다
    func setHold(_ id: String, col: String, _ on: Bool) {
        var h = holds[col] ?? []
        if on { h.insert(id) } else { h.remove(id) }
        guard h != (holds[col] ?? []) else { return }
        holds[col] = h.isEmpty ? nil : h
        if !on { poke() }
    }

    /// 열이 잠깐 늘어나 있는가 — 열2 할 일 되돌리기 토스트(끝남·아님), 열3 학회 관심 토스트, 열1 논문 댓글 칸·'나:' 고르기
    private func transient(_ col: String, _ m: NotionHubModel) -> Bool {
        if !(holds[col] ?? []).isEmpty { return true }
        switch col {
        case "2": return !m.reminderCommits.pending.isEmpty
        case "3": return !m.interestCommits.pending.isEmpty || !m.followupCommits.pending.isEmpty   // 미팅 후속 되돌리기 (0.41.0 C3) · 입력 칸은 hold 'fu-input'
        default: return false
        }
    }

    /// 카드의 행 높이 — 같은 배율의 실측 평균이 있으면 그것, 없으면 추정 × 배율
    private func rowHeight(_ key: String, scale: CGFloat) -> CGFloat {
        if let r = measuredRowH[key], abs(r.scale - scale) < 0.01 { return r.h }
        return (Self.rowH[key] ?? 60) * scale
    }

    /// 허브 카드를 펼치거나 접었을 때 (Dashboard onChange(of: expansion.open)) — 모든 열을 '바뀐 뒤 측정 대기'로 두고 다시 본다.
    /// 다음 내용 높이 측정(또는 1초)까지 정하지도 빼지도 않는다 — 애니메이션 중간·옛 높이로 고치지 않게 (0.39.0 C0)
    func expansionChanged() {
        let now = Date()
        for c in Self.candidates { changedAt[c.col] = now }
        poke()
    }

    /// HubLayoutProbe.record 가 부른다 — 내용 높이가 새로 왔으면 그 열의 '바뀐 뒤 측정 대기'를 푼다
    func measured(col: String, part: HubLayoutProbe.Part) {
        guard Self.columnCards[col] != nil else { return }
        if part == .content { changedAt[col] = nil }
        poke()
    }

    /// 다음 런루프에서 한 번 — 측정·데이터·캘린더·펼침이 바뀔 때
    func poke() {
        guard Self.enabled, !queued else { return }
        queued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.queued = false
            for c in Self.candidates { self.step(c.col, c.keys) }
        }
    }

    private func retryLater() {
        guard !retryQueued else { return }
        retryQueued = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            self?.retryQueued = false
            self?.poke()
        }
    }

    private func step(_ col: String, _ keys: [String]) {
        guard let m = model else { waiting[col] = "허브 안 보임"; return }
        // 논문 추천이 멈춰 접혀 있으면(R4) 펼침 저장값은 화면에 없다 — 그 열은 접힌 열로 본다 (0.40.0 C8)
        if (Self.columnCards[col] ?? []).contains(where: { HubExpansion.shared.isOpen($0) && !($0 == "papers" && m.papersStopped) }) {
            waiting[col] = "펼친 카드"; seen[col] = nil; return
        }
        guard let v = HubLayoutProbe.value(col) else { waiting[col] = "측정 전"; return }
        // 토스트·댓글 칸이 떠 있는 동안 잰 높이로는 정하지도 빼지도 않는다 — 닫히면 높이가 바뀌어 probe 가 다시 깨운다(토스트는 6초 뒤 한 번 더 확인)
        if transient(col, m) {
            seen[col] = nil
            if decided[col] == nil { waiting[col] = "잠깐 열린 줄" }
            if (holds[col] ?? []).isEmpty { retryLater() }
            return
        }
        if let t = changedAt[col] {
            if Date().timeIntervalSince(t) < 1.0 { retryLater(); return }
            changedAt[col] = nil
        }
        // 측정 안정화 (0.39.0 C0) — 같은 (내용, 보이는) 높이를 0.5초 넘게 두 번 본 뒤에만 결정·넘침 고침. 아니면 서명을 갈아 넣고 1.1초 뒤 다시
        let sig = "\(Int(v.content.rounded())) \(Int(v.visible.rounded()))"
        let now = Date()
        if let s = seen[col], s.sig == sig {
            if now.timeIntervalSince(s.at) < 0.5 { waiting[col] = "확인 대기"; retryLater(); return }
        } else {
            seen[col] = (sig, now)
            waiting[col] = "확인 대기"
            retryLater()
            return
        }
        let scale = HubDisplay.scale
        let key = "\(Int(HubClock.today.timeIntervalSince1970)) \(String(format: "%.1f", Double(scale))) \(Int((v.visible / 20).rounded()))"
        if let d = decided[col] {
            if d.key == key {
                // 넘침 고침 — 갱신 중(행이 잠깐 바뀜)에는 하지 않는다
                if v.content > v.visible + 0.5, !m.loading, var a = added[col], let last = a.popLast() {
                    added[col] = a
                    setExtra(last, (extra[last] ?? 1) - 1, col: col)
                }
                return
            }
            // 키가 바뀜 → 0 으로 되돌리고 다음 측정에서 다시 정한다
            decided[col] = nil
            added[col] = []
            if keys.contains(where: { (extra[$0] ?? 0) > 0 }) {
                for k in keys { setExtra(k, 0, col: col) }
                waiting[col] = "다시 재는 중"
                return
            }
        }
        guard m.settledDay == HubClock.today, !m.loading, m.lastUpdated != nil else { waiting[col] = "Notion 갱신 중"; return }
        guard m.todayCalendar?.isSettled != false else { waiting[col] = "캘린더 첫 조회 전"; return }
        let cards = keys.map { (key: $0, more: Self.fillable($0, m), rowH: rowHeight($0, scale: scale)) }
        let order = Self.planOrder(free: v.visible - v.content, cards: cards, margin: 16 * scale, cap: Self.cap)
        let counts = Self.counts(order)
        for k in keys { setExtra(k, counts[k] ?? 0, col: col) }
        added[col] = order
        decided[col] = (key, Date())
        waiting[col] = nil
    }

    private func setExtra(_ k: String, _ n: Int, col: String) {
        guard (extra[k] ?? 0) != n else { return }
        if n <= 0 { extra[k] = nil } else { extra[k] = n }
        changedAt[col] = Date()
    }

    /// 순수 함수 — 우선순위 순 라운드로빈(한 바퀴에 카드마다 +1), 카드마다 min(cap, more) 까지, 남는 높이 − 행 높이 ≥ margin 일 때만. 더한 순서를 돌려준다
    static func planOrder(free: CGFloat, cards: [(key: String, more: Int, rowH: CGFloat)], margin: CGFloat, cap: Int = 3) -> [String] {
        var left = free, n: [String: Int] = [:], out: [String] = []
        var progress = true
        while progress {
            progress = false
            for c in cards {
                let have = n[c.key] ?? 0
                guard have < min(cap, c.more), c.rowH > 0, left - c.rowH >= margin else { continue }
                left -= c.rowH; n[c.key] = have + 1; out.append(c.key); progress = true
            }
        }
        return out
    }
    /// planOrder 의 카드별 수
    static func plan(free: CGFloat, cards: [(key: String, more: Int, rowH: CGFloat)], margin: CGFloat, cap: Int = 3) -> [String: Int] {
        counts(planOrder(free: free, cards: cards, margin: margin, cap: cap))
    }
    private static func counts(_ order: [String]) -> [String: Int] { order.reduce(into: [:]) { $0[$1, default: 0] += 1 } }

    /// 카드의 채울 수 있는 행 수 — 허브 카드와 같은 인자(일정 maxRows 8 · 학회 maxRows 5).
    /// 그랜트는 미정도 (날짜 있는 것이 앞, GrantsFile 정렬) — 채움으로 보인 미정 행은 '확인 필요' 를 적색 없이 무채색으로 그린다(GrantsSection).
    /// 0.38.0 처음엔 날짜 있는 것만이라 숨은 그랜트 3건이 모두 미정인 날 열2 바닥 255pt 가 비었다(검증 1)
    static func fillable(_ key: String, _ m: NotionHubModel) -> Int {
        switch key {
        case "events": return HubNear.events(m, items: UpcomingEventsCard.items(model: m, cal: m.todayCalendar, excludeToday: false)).more
        case "reminders": return HubNear.reminders(m).more
        case "grants": return HubNear.grants(m).more
        case "conferences": return HubNear.conferences(m, limit: min(m.cfg.conferencesCount, 5)).more
        case "blitz": return HubNear.blitz(m, me: HubPrefs.me).more
        case "papers":
            // 접힌 보드(R4)는 행을 그리지 않으니 채울 행도 없다 — 열1 빈 면은 최신 원고가 받는다
            if m.papersStopped { return 0 }
            return HubNear.papers(m, visible: PaperRecBoard.visible(m, who: PaperRecBoard.who(filter: HubPrefs.paperFilter, me: HubPrefs.me))).more
        case "preprints": return HubNear.preprints(m).more
        default: return 0
        }
    }

    /// windows.txt — 'hub-fill: 1 preprints +1 papers +2 · 2 events +3 grants +2 · 3 conferences +3 (결정 HH:mm:ss · 1.0배)' / '꺼짐' / '대기(<이유>)'
    var line: String {
        guard Self.enabled else { return "hub-fill: 꺼짐" }
        if decided.isEmpty {
            let reasons = Set(Self.candidates.map { waiting[$0.col] ?? "측정 전" })
            if reasons.count == 1, let r = reasons.first { return "hub-fill: 대기(\(r))" + holdsText }
        }
        var last: Date? = nil
        let parts = Self.candidates.map { c -> String in
            guard let d = decided[c.col] else { return "\(c.col) 대기(\(waiting[c.col] ?? "측정 전"))" }
            if last.map({ d.at > $0 }) ?? true { last = d.at }
            let s = c.keys.compactMap { k in (extra[k] ?? 0) > 0 ? "\(k) +\(extra[k] ?? 0)" : nil }
            // 남은 행이 있는데 상한(min(3, 남은 수)) 아래에서 멈춘 카드 = 다음 한 행이 남는 높이에 안 들어감(계획 또는 넘침 고침)
            let unfit = model.map { m in c.keys.filter { k in let e = extra[k] ?? 0; return e < min(Self.cap, Self.fillable(k, m)) } } ?? []
            // 실측 행 높이가 있으면 함께 — qa 가 '빈 높이 < 행 높이 + 여백' 을 바로 대조 (예 '(안 맞음 papers 행 212pt)')
            let unfitText = unfit.map { k in measuredRowH[k].flatMap { abs($0.scale - HubDisplay.scale) < 0.01 ? "\(k) 행 \(Int($0.h.rounded()))pt" : nil } ?? k }
            return "\(c.col) " + (s.isEmpty ? "없음" : s.joined(separator: " ")) + (unfit.isEmpty ? "" : " (안 맞음 " + unfitText.joined(separator: " ") + ")")
        }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let tail: String = last.map { " (결정 \(f.string(from: $0)) · " + String(format: "%.1f배", Double(HubDisplay.scale)) + ")" } ?? ""
        return "hub-fill: " + parts.joined(separator: " · ") + tail + holdsText
    }

    /// ' · 보류 1:papers-ui 3:conf-me' — 지금 걸린 보류(열 순서, id 정렬). 없으면 빈 문자열 (0.39.0 C0, qa 가 보류를 windows.txt 로 확인)
    private var holdsText: String {
        let parts = holds.keys.sorted().flatMap { col in (holds[col] ?? []).sorted().map { "\(col):\($0)" } }
        return parts.isEmpty ? "" : " · 보류 " + parts.joined(separator: " ")
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
    /// 클릭·--key expand:<key> 가 같은 경로. 다 접히면 키를 지운다(defaults read 에 남지 않게). 열 때 UsageLog panel(키) (0.40.0 C2, A1)
    func toggle(_ key: String) {
        let opening = !open.contains(key)
        withAnimation(.easeOut(duration: 0.2)) {
            if open.contains(key) { open.remove(key) } else { open.insert(key) }
        }
        if opening { UsageLog.panel(key) }
        if open.isEmpty { UserDefaults.standard.removeObject(forKey: Self.defaultsKey) }
        else { UserDefaults.standard.set(open.sorted(), forKey: Self.defaultsKey) }
    }
}

/// 허브 카드 끝 한 줄 (0.40.0 C2, A1·결정 D-h) — 왼쪽 캡션('출처 · 기준 · n · 정의 id', Hub.text3·cs.cap), 오른쪽 '▸ 더 보기 · n개'(있을 때만).
/// 허브의 MoreToggle 자리를 대신한다 — 토글이 있는 카드는 높이가 그대로(캡션 글자가 토글 글자보다 작다), 없는 카드는 캡션 한 줄만큼 늘어난다
struct CardFooter: View {
    let caption: String
    var toggleKey: String? = nil
    /// 펼치면 더 보이는 수 (MoreToggle 과 같은 값) — 0 이면 토글 없이 캡션만
    var more: Int = 0
    var divider: Bool = true
    @ObservedObject private var store = HubExpansion.shared
    @Environment(\.cardStyle) private var cs
    var body: some View {
        VStack(spacing: 0) {
            if divider { RowDivider() }
            HStack(spacing: 8) {
                // 캡션이 먼저 폭을 받는다 — 토글은 제 글자 폭(fixedSize)만 남기고, 남는 오른쪽 면은 토글 클릭 영역
                SourceCaption(text: caption).layoutPriority(1)
                if let key = toggleKey, more > 0 {
                    let open = store.isOpen(key)
                    Button { store.toggle(key) } label: {
                        Text(open ? "▾ 접기" : "▸ 더 보기 · \(more)개")
                            .font(.hub(cs.aux, weight: .medium)).foregroundStyle(Hub.text2).lineLimit(1).fixedSize()
                            .frame(maxWidth: .infinity, alignment: .trailing).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(open ? "접기 — 가까운 것만 (이 맥에 저장)" : "이 카드의 나머지 \(more)개를 제자리에서 펼침 (이 맥에 저장)")
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
        }
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
    /// 시스템 글꼴 × 글자 배율(HubDisplay.scale). 앱 안 글자 크기는 모두 이것으로 그린다 (0.37.0 기계 치환).
    /// 0.42.0 C7: Display 판에서 번들 글꼴을 고르면(기본 system) 그 PostScript 이름으로 — design(.rounded 등)은 빠지고(숫자 정렬은 monospacedDigit 이 맡음),
    /// .monospaced 는 시스템 그대로
    static func hub(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        let s = size * HubDisplay.scale
        if design != .monospaced, let ps = HubDisplay.faceName(weight) { return .custom(ps, fixedSize: s) }
        return .system(size: s, weight: weight, design: design)
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
    static let presetNames = ["default": "Default", "contrast": "High Contrast", "dark": "Dark"]
    /// Font.hub 가 읽는 배율 (뷰 밖에서도 읽도록 정적)
    nonisolated(unsafe) static private(set) var scale: CGFloat = 1

    // MARK: 글꼴 (0.42.0 C7, R4) — UserDefaults DeskHub.fontFamily · 훅 DESKHUB_FONT · --key font:<id>. 기본 system(결정 D-9).
    // 번들 OFL 글꼴은 Info.plist ATSApplicationFontsPath=Fonts 로 등록된다. 등록 확인(NSFont(name:))에 실패하면 시스템으로 대체
    static let fonts = ["system", "pretendard", "plex", "suit"]
    static let fontNames = ["system": "System", "pretendard": "Pretendard", "plex": "IBM Plex Sans KR", "suit": "SUIT"]
    /// 굵기 → PostScript 이름 (regular · medium · semibold · bold). SUIT 는 가변 글꼴의 이름 붙은 인스턴스
    nonisolated static let fontFaces: [String: [String]] = [
        "pretendard": ["Pretendard-Regular", "Pretendard-Medium", "Pretendard-SemiBold", "Pretendard-Bold"],
        "plex": ["IBMPlexSansKR", "IBMPlexSansKR-Medm", "IBMPlexSansKR-SmBld", "IBMPlexSansKR-Bold"],
        "suit": ["SUITVariable-Regular", "SUITVariable-Medium", "SUITVariable-SemiBold", "SUITVariable-Bold"],
    ]
    /// 지금 쓰는 글꼴 id (대체 뒤) · 고른 값 · 고른 글꼴이 없어 시스템으로 대체했나
    nonisolated(unsafe) static private(set) var family = "system"
    nonisolated(unsafe) static private(set) var familyRequested = "system"
    nonisolated(unsafe) static private(set) var familyFallback = false
    /// 그 글꼴이 이 앱에 등록됐나 (네 굵기 모두)
    nonisolated static func registered(_ id: String) -> Bool {
        guard let faces = fontFaces[id] else { return false }
        return faces.allSatisfy { NSFont(name: $0, size: 12) != nil }
    }
    /// Font.hub · nsFont 가 쓰는 PostScript 이름 — 시스템이면 nil
    nonisolated static func faceName(_ w: Font.Weight) -> String? {
        guard family != "system", let f = fontFaces[family] else { return nil }
        switch w {
        case .medium: return f[1]
        case .semibold: return f[2]
        case .bold, .heavy, .black: return f[3]
        default: return f[0]
        }
    }
    /// AppKit 폭 재기(StatusLine) 도 같은 글꼴로 — 시스템이면 지금과 같다
    nonisolated static func nsFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let w: Font.Weight = weight == .medium ? .medium : (weight == .semibold ? .semibold : (weight == .bold || weight == .heavy || weight == .black ? .bold : .regular))
        if let ps = faceName(w), let f = NSFont(name: ps, size: size) { return f }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }
    private static func applyFamily(_ id: String) {
        familyRequested = id
        if id == "system" || !fonts.contains(id) { family = "system"; familyFallback = id != "system" }
        else if registered(id) { family = id; familyFallback = false }
        else { family = "system"; familyFallback = true }
    }
    /// windows.txt 'font: <id> (등록됨|대체|기본)'
    static var fontLine: String {
        "font: \(family) " + (familyFallback ? "(대체) · 고른 값 \(familyRequested)" : (family == "system" ? "(default)" : "(등록됨)"))
    }
    @Published private(set) var fontFamily = "system"

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
        var ff = d.string(forKey: "DeskHub.fontFamily") ?? "system"
        if let v = env["DESKHUB_FONT"], !v.isEmpty { ff = v }
        Self.applyFamily(ff)
        fontFamily = Self.family
    }

    /// 판의 Font 단추·--key font:<id> — 같은 경로. 등록이 안 된 글꼴이면 시스템으로 대체(저장 값은 고른 id)
    func setFont(_ id: String) {
        guard Self.fonts.contains(id) else { NSSound.beep(); return }
        UserDefaults.standard.set(id, forKey: "DeskHub.fontFamily")
        Self.applyFamily(id)
        guard Self.family != fontFamily else { return }
        fontFamily = Self.family
        revision += 1
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
                Text("Display").font(.hub(14, weight: .bold))
                Text("이 맥에만 저장").font(.hub(11)).foregroundStyle(Hub.text3)
                Spacer(minLength: 4)
                Button { display.panelOpen = false } label: {
                    Image(systemName: "xmark").font(.hub(11, weight: .bold)).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Hub.text2).help("닫기 (Esc)")
            }
            Text("Text size").font(.hub(12, weight: .semibold)).foregroundStyle(Hub.text2)
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
            Text("Font").font(.hub(12, weight: .semibold)).foregroundStyle(Hub.text2)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(HubDisplay.fonts, id: \.self) { f in
                    let on = display.fontFamily == f
                    let ok = f == "system" || HubDisplay.registered(f)
                    Button { display.setFont(f) } label: {
                        Text((HubDisplay.fontNames[f] ?? f) + (ok ? "" : " (없음)")).font(.hub(12.5, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Hub.ink : Hub.fillNeutral))
                            .foregroundStyle(on ? Hub.onAccent : (ok ? Hub.text : Hub.text3))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(f == "system" ? "시스템 글꼴 — default" : (ok ? "번들 글꼴 · SIL OFL 1.1" : "이 앱에 글꼴 파일이 없어 시스템 글꼴로 대체됩니다"))
                }
            }
            Text("Color").font(.hub(12, weight: .semibold)).foregroundStyle(Hub.text2)
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

/// 학회 관심 이니셜 칩 묶음 (0.38.0 C4, CI-VIEWS) — InitialChip 앞 limit 개 + 넘치면 '+n'(Hub.text2). 안내판 학회 행·관제탑 접힌 학회 레일 줄 공용.
/// 이름은 늘 model.interestNames(_:) 한 소스(허브·관제탑·안내판 같은 값, 6초 대기 중이면 바뀔 상태). 보기만 — 토글은 허브·관제탑 학회 카드의 '관심' 단추
struct InterestChips: View {
    let names: [String]
    var me: String = HubPrefs.me.uppercased()
    var limit: Int = 3
    @Environment(\.cardStyle) private var cs
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(names.prefix(limit)), id: \.self) { n in InitialChip(text: n, mine: !me.isEmpty && n == me) }
            if names.count > limit {
                Text("+\(names.count - limit)").font(.hub(cs.tag - 0.5, weight: .semibold, design: .rounded)).foregroundStyle(Hub.text2)
            }
        }
        .fixedSize()
        .help("관심 표시 · " + names.joined(separator: ", "))
    }
}
