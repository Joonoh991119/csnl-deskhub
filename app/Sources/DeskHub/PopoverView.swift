import SwiftUI
import AppKit

// MARK: - 메뉴 막대 팝오버 '조각' (디자인 계획 D12 — §2 D)
// 창 없이: 메뉴 막대 아이콘 왼쪽 클릭 → 이 팝오버, 오른쪽 클릭 → 기존 메뉴.
// 세 칸: 지금·다음 / 할 것(경보 W·C 4줄, 내 것 먼저) / 내 것(다음 GRM 차례·반응 안 한 추천·프로젝트) + '새 것 1줄'
// 새 것 = 마지막으로 본 뒤 들어온 회의록·Paper Blitz·추천 — 이 맥 로컬 seen-<이니셜>.json

enum SeenStore {
    /// cards — '내 것' 배지 기준선: 카드 → 행 id → 화면 필드 해시 (0.40.0 C4, A3-badge — SeenCards). 옛 파일은 nil 로 읽힌다
    struct Seen: Codable { var minutes: Date?; var blitz: Date?; var papers: Date?; var cards: [String: [String: String]]? }
    static func url(_ me: String) -> URL { Config.directory.appendingPathComponent("seen-\(me.isEmpty ? "anon" : me).json") }
    static func load(_ me: String) -> Seen {
        guard let d = try? Data(contentsOf: url(me)), let s = try? JSONDecoder().decode(Seen.self, from: d) else { return Seen() }
        return s
    }
    static func save(_ s: Seen, _ me: String) {
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: url(me), options: .atomic) }
    }
}

/// 팝오버를 열 때 TTL 지난 소스만 다시 조회 (UX menubar-glance-67, 0.34.0). 화면은 캐시 값으로 먼저 그리고, 조회가 끝나면 @Published 로 제자리에서 바뀐다.
/// AppDelegate 의 팝오버 열기(statusClicked)와 스냅샷의 popover.png 가 같은 함수를 부른다 — 팝오버 그림 = 팝오버 열기 (QA 가 같은 경로로 확인)
@MainActor
enum PopoverRefresh {
    /// 기본 120초. 팝오버 재조회는 가벼운 경로(refresh(light:)) — Notion DB 쿼리 약 14개 + NAS 파일이라 2분마다 열어도 분당 7회 남짓.
    /// 논문 댓글(논문마다 GET, 최대 100건)은 자체 TTL 10분(NotionHubModel.commentsTTL), Paper Blitz 는 주기 갱신에만 (검증 1).
    /// 같은 토큰을 쓰는 맥이 여럿이면 합산된다. 테스트: DESKHUB_POPOVER_TTL=<초> (설정 스키마는 바꾸지 않음)
    static let ttl: TimeInterval = {
        if let v = ProcessInfo.processInfo.environment["DESKHUB_POPOVER_TTL"], let s = Double(v), s > 0 { return s }
        return 120
    }()
    static func willOpen(_ m: NotionHubModel) {
        m.refreshIfStale(ttl: ttl)
        m.todayCalendar?.refreshIfStale(ttl: ttl)
    }
}

struct PopoverView: View {
    @ObservedObject var model: NotionHubModel
    @ObservedObject private var commits: DelayedCommit
    var onOpenDashboard: () -> Void = {}
    var onClose: () -> Void = {}
    /// 스냅샷(ImageRenderer)은 버튼·메뉴를 못 그리므로 그땐 숨긴다
    var forSnapshot = false
    /// 가용 높이보다 길면 이 높이의 스크롤 안에 넣는다 (R-33, 0.36.0) — nil 이면 지금처럼 자연 높이
    var scrollHeight: CGFloat? = nil
    @State private var seen: SeenStore.Seen

    init(model: NotionHubModel, forSnapshot: Bool = false, scrollHeight: CGFloat? = nil, onOpenDashboard: @escaping () -> Void = {}, onClose: @escaping () -> Void = {}) {
        self.model = model
        self.forSnapshot = forSnapshot
        self.scrollHeight = scrollHeight
        self.onOpenDashboard = onOpenDashboard
        self.onClose = onClose
        _commits = ObservedObject(wrappedValue: model.reminderCommits)
        _seen = State(initialValue: SeenStore.load(HubPrefs.me))
    }

    private var me: String { HubPrefs.me }

    /// 머리 '갱신 HH:mm' — Notion 마지막 조회 시각. 조회 중이면 '갱신 중', 주기(refreshMinutes)의 두 배를 넘으면 stale. 무채색(FreshnessTag)
    private var updatedTag: Freshness {
        if model.loading { return Freshness(state: .pending, text: "갱신 중", help: "Notion·NAS 를 다시 읽는 중") }
        guard let t = model.lastUpdated else { return Freshness(state: .pending, text: "갱신 전", help: "아직 Notion 을 읽지 못함") }
        let limit = Double(2 * max(2, model.cfg.refreshMinutes)) * 60
        let stale = Date().timeIntervalSince(t) > limit
        return Freshness(state: stale ? .stale : .fresh, text: "갱신 " + Hub.time(t),
                         help: "Notion 마지막 조회 \(Hub.time(t))" + (stale ? " — \(Int(limit / 60))분 넘게 갱신 안 됨" : "") + " · 팝오버를 열 때 \(Int(PopoverRefresh.ttl))초 지난 소스만 다시 조회")
    }

    /// 마지막으로 본 뒤 새로 들어온 것 한 줄
    private var newLine: String? {
        var parts: [String] = []
        if let d = model.minutes.compactMap(\.date).max(), d > (seen.minutes ?? .distantPast) {
            let h = model.minutes.first.map(model.minutesHeader)
            parts.append("회의록 \(Hub.day(d))" + (h.map { " " + $0.who } ?? ""))
        }
        if let d = model.blitzDate, d > (seen.blitz ?? .distantPast) { parts.append("Blitz \(Hub.day(d)) \(model.blitz.count)편") }
        if let d = model.papers.compactMap(\.sentAt).max(), d > (seen.papers ?? .distantPast) { parts.append("추천 \(Hub.day(d))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        Group {
            if let h = scrollHeight {
                ScrollView(.vertical, showsIndicators: true) { content }.frame(width: Hub.s(380), height: h)
            } else {
                content
            }
        }
        .onDisappear(perform: markSeen)
    }

    @ViewBuilder
    private var content: some View {
        let now = model.now
        let set = AlertEngine.evaluate(model, cal: model.todayCalendar, now: now, me: me)
        let todo = Array(set.alerts.filter { $0.level != .advisory }.prefix(4))
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(Hub.longDay(now)).font(.hub(13, weight: .bold))
                FreshnessTag(f: updatedTag)
                Spacer()
                if !me.isEmpty { Text(me).font(.hub(11.5, weight: .bold, design: .rounded)).foregroundStyle(Hub.text2) }
                // 닫기 — 누르기 쉬운 크기 (R2, JYK: '잘 안 꺼짐')
                if !forSnapshot {
                    Button { onClose() } label: {
                        Image(systemName: "xmark").font(.hub(12, weight: .bold)).frame(width: 28, height: 28)
                            .background(Circle().fill(Hub.surface)).contentShape(Circle())
                    }
                    .buttonStyle(.plain).foregroundStyle(Hub.text2).help("닫기 (Esc)").keyboardShortcut(.cancelAction)
                }
            }
            MeConfirmBar(model: model, compact: true)
            if let n = newLine {
                Label("새로: " + n, systemImage: "sparkle").font(.hub(12, weight: .medium)).foregroundStyle(Hub.ink).lineLimit(1)
            }
            section("지금 · 다음") {
                if let cal = model.todayCalendar { NowNextLine(cal: cal) } else { Text("캘린더 없음").foregroundStyle(Hub.text3) }
            }
            section("할 것 \(set.counts[.warning] ?? 0 > 0 ? "■\(set.counts[.warning]!)" : "")") {
                if todo.isEmpty { Text("경보 없음").font(.hub(12)).foregroundStyle(Hub.text3) }
                ForEach(todo) { a in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(a.level.mark).font(.hub(11, weight: .bold)).foregroundStyle(a.level == .warning ? Hub.signal : Hub.text2)
                        Text(a.title).font(.hub(12.5, weight: a.level == .warning ? .semibold : .regular)).lineLimit(1)
                        Spacer(minLength: 4)
                        if let d = a.due { Text(MenuBarLine.compact(d, now: now)).font(.hub(11.5, weight: .bold, design: .rounded)).foregroundStyle(Hub.text2) }
                    }
                    .link(a.link)
                }
            }
            section("내 것") { mine(now: now) }
            HintBar(compact: true)
            if !forSnapshot { HStack {
                Button("대시보드 앞으로 (\(DeskHubNotice.hotkeyLabel))") { onOpenDashboard() }
                    .help("바탕화면 층에 깔린 대시보드를 다른 창 위로 꺼냅니다. 같은 단축키로 다시 숨깁니다")
                Spacer()
                Menu("뷰") {
                    ForEach(HubViewMode.allCases) { m in Button(m.title) { ViewModeStore.shared.mode = m; onOpenDashboard() } }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .font(.hub(12)) }
        }
        .padding(14)
        .frame(width: Hub.s(380))
    }

    @ViewBuilder
    private func mine(now: Date) -> some View {
        if let m = model.member(initials: me) {
            let turn = model.grm.first { $0.date >= model.today && ($0.presenters.contains(m.name) || $0.presenters.contains(m.initials)) }
            let myPapers = model.papers.filter { $0.researcher == me }
            let unreacted = myPapers.filter { p in !(model.paperComments[p.id] ?? []).contains { $0.isReaction && $0.who == me } }.count
            // 칩 줄과 같은 소스·같은 매칭 (NAS member_links.json, R-32)
            let projects = Self.myProjects(model, m)
            VStack(alignment: .leading, spacing: 4) {
                if let t = turn {
                    let n = Calendar.current.dateComponents([.day], from: model.today, to: t.date).day ?? 0
                    row("내 GRM 차례", Hub.day(t.date) + " · " + (n == 0 ? "오늘" : "D-\(n)")).link(.notion(t.id))
                }
                row("추천 논문", "\(myPapers.count)편 · 반응 안 함 \(unreacted)").link(.notion(model.cfg.paperRecDB))
                // 누르면 첫 프로젝트 폴더 — 칩 클릭과 같은 동작
                row("진행 프로젝트", Self.projectsText(projects)).link(projects.first.map { .nas($0.path) })
            }
        } else {
            Text("이 맥의 사용자 이니셜이 없음 — 대시보드 '나' 뷰에서 고르기").font(.hub(12)).foregroundStyle(Hub.text3)
        }
    }

    /// 팝오버 '진행 프로젝트' 목록 = 칩과 같은 chipProjects (text.txt [진행 프로젝트] 의 '팝오버' 칸도 이 함수)
    static func myProjects(_ model: NotionHubModel, _ m: Member) -> [MemberLinks.Project] { model.chipProjects(for: m) }
    /// 앞 2개(칩 표시 이름) + ' +n', 비면 '없음'
    static func projectsText(_ p: [MemberLinks.Project]) -> String {
        p.isEmpty ? "없음" : p.prefix(2).map { MemberGroup.display($0.name) }.joined(separator: " · ") + (p.count > 2 ? " +\(p.count - 2)" : "")
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(spacing: 8) {
            Text(k).font(.hub(12)).foregroundStyle(Hub.text2).frame(width: Hub.s(84), alignment: .leading)
            Text(v).font(.hub(12.5, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.hub(11, weight: .bold)).foregroundStyle(Hub.text3)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Hub.surface))
    }

    /// 팝오버를 닫으면 지금 것까지 '봤음'
    private func markSeen() {
        var s = seen
        s.minutes = model.minutes.compactMap(\.date).max() ?? s.minutes
        s.blitz = model.blitzDate ?? s.blitz
        s.papers = model.papers.compactMap(\.sentAt).max() ?? s.papers
        // 배지 기준선은 SeenCards 가 따로 쓴다 — 팝오버를 연 뒤 바뀐 기준선을 옛 값으로 덮지 않게 파일에서 다시 읽어 둔다 (0.40.0 C4)
        s.cards = SeenStore.load(me).cards
        SeenStore.save(s, me)
    }
}
