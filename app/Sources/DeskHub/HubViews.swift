import SwiftUI
import AppKit

// MARK: - v24 멀티 뷰 (랩장 2026-10-14: "여러 버전의 뷰를 디자인해 두는 편이 하나의 갈래보다 낫다")
// 같은 NotionHubModel 위에 화면 구성만 다른 뷰 다섯 개. 첫 탭에서 고르고, 이 맥에 저장한다.
// `DeskHub --view hub|today|grm|me|ambient` 로도 바꾼다 (스냅샷 비교용).

enum HubViewMode: String, CaseIterable, Identifiable {
    case tower, process, board, hub, today, grm, me, ambient
    var id: String { rawValue }
    /// 디자인 계획 2차(10-14) 이전의 뷰 — 메뉴 '이전' 묶음, 2주 비교 뒤 랩장이 정리 (결정 18)
    var legacy: Bool { ![.tower, .process, .board].contains(self) }
    var title: String {
        switch self {
        case .tower: return "관제탑"
        case .process: return "공정 보드"
        case .board: return "안내판"
        case .hub: return "랩 허브"
        case .today: return "오늘 집중"
        case .grm: return "GRM 주간"
        case .me: return "나"
        case .ambient: return "앰비언트"
        }
    }
    var symbol: String {
        switch self {
        case .tower: return "exclamationmark.triangle"
        case .process: return "rectangle.split.3x1"
        case .board: return "tram"
        case .hub: return "square.grid.2x2"
        case .today: return "sun.max"
        case .grm: return "person.3"
        case .me: return "person.crop.circle"
        case .ambient: return "clock"
        }
    }
    var blurb: String {
        switch self {
        case .tower: return "경보 먼저, 나머지는 한 줄 요약·제자리 펼침"
        case .process: return "공정이 행, 단계가 칸 — 막힌 칸만 적색"
        case .board: return "시간순 한 줄 보드 — 멀리서도 읽힘 (보조·세로 모니터)"
        case .hub: return "가까운 일정·마감 먼저, 나머지는 펼쳐 보기"
        case .today: return "오늘 일정·실험·리마인더만"
        case .grm: return "발표 순번·회의록·Paper Blitz"
        case .me: return "이 맥 사용자의 추천·프로젝트·차례"
        case .ambient: return "보조 모니터·벽용 큰 글자"
        }
    }
}

@MainActor
final class ViewModeStore: ObservableObject {
    static let shared = ViewModeStore()
    @Published var mode: HubViewMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "DeskHub.viewMode"); UsageLog.viewShown(mode.rawValue) }
    }
    private init() {
        mode = HubViewMode(rawValue: UserDefaults.standard.string(forKey: "DeskHub.viewMode") ?? "") ?? .hub
    }
}

/// 첫 탭 내용 — 고른 뷰
struct HubViewSwitch: View {
    @ObservedObject var model: NotionHubModel
    @ObservedObject var store = ViewModeStore.shared
    var body: some View {
        content.keyLayer(model)
    }

    @ViewBuilder private var content: some View {
        switch store.mode {
        case .tower: TowerView(model: model)
        case .process: ProcessBoardView(model: model)
        case .board: BoardView(model: model)
        case .hub: Dashboard(model: model)
        case .today: TodayFocusView(model: model)
        case .grm: GRMWeekView(model: model)
        case .me: MeView(model: model)
        case .ambient: AmbientView(model: model)
        }
    }
}

/// 탭 막대의 뷰 고르기 메뉴
struct ViewModeMenu: View {
    @ObservedObject var store = ViewModeStore.shared
    var onPick: () -> Void = {}
    var body: some View {
        Menu {
            Section("새 뷰 (디자인 계획 2차)") {
                ForEach(HubViewMode.allCases.filter { !$0.legacy }) { m in
                    Button { store.mode = m; onPick() } label: { Label("\(m.title) — \(m.blurb)", systemImage: m.symbol) }
                }
            }
            Section("이전") {
                ForEach(HubViewMode.allCases.filter(\.legacy)) { m in
                    Button { store.mode = m; onPick() } label: { Label("\(m.title) — \(m.blurb)", systemImage: m.symbol) }
                }
            }
        } label: {
            Image(systemName: "chevron.down").font(.hub(10, weight: .bold)).foregroundStyle(Hub.text2)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("뷰 바꾸기 (이 맥에만 저장)")
    }
}

// MARK: B. 오늘 집중

struct TodayFocusView: View {
    @ObservedObject var model: NotionHubModel
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "오늘 · " + Hub.longDay(model.now))
                if let cal = model.todayCalendar {
                    TodayView(cal: cal).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
                } else {
                    Text("캘린더가 연결되지 않았습니다").foregroundStyle(Hub.text2).padding(12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    CompactGRMBar(model: model).fixedSize(horizontal: false, vertical: true)
                    RemindersSection(model: model)
                    ExperimentsCard(model: model)
                    UpcomingEventsCard(model: model, cal: model.todayCalendar)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(12)
    }
}

// MARK: C. GRM 주간

struct GRMWeekView: View {
    @ObservedObject var model: NotionHubModel
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            GRMOrderView(model: model, notionURL: nil)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.card.opacity(0.4)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: 12) {
                MinutesCard(model: model, minutesExpanded: true)
                BlitzCompact(model: model).frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(12)
    }
}

// MARK: D. 나

struct MeView: View {
    @ObservedObject var model: NotionHubModel
    @State private var me = HubPrefs.me

    private var member: Member? { me.isEmpty ? nil : model.member(initials: me) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: 12) {
                PaperRecBoard(model: model)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        myTurn
                        myProjects
                        myBlitz
                        RemindersSection(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(12)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(member?.name ?? "이 맥의 사용자 미정").font(.hub(20, weight: .bold))
            if !me.isEmpty { Text(me).font(.hub(13, weight: .bold, design: .rounded)).foregroundStyle(Hub.text2) }
            Spacer()
            Menu {
                ForEach(model.members.filter { !$0.initials.isEmpty }) { m in
                    Button("\(m.name) (\(m.initials))") { HubPrefs.me = m.initials; me = m.initials }
                }
            } label: { Text("사용자 바꾸기").font(.hub(12)) }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    /// 다음 내 GRM 차례
    private var myTurn: some View {
        let slot = member.flatMap { m in model.grm.first { $0.date >= model.today && ($0.presenters.contains(m.name) || $0.presenters.contains(m.initials)) } }
        return VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "내 다음 GRM 차례")
            HStack(spacing: 10) {
                if let s = slot {
                    Text(Hub.day(s.date)).font(.hub(15, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(Hub.dday(s.date)).font(.hub(12, weight: .bold)).foregroundStyle(Hub.onAccent)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Hub.ink))
                    TypePill(text: s.type)
                    Spacer()
                    SmallAction(symbol: "folder", label: "슬라이드") { model.openSlides(for: s) }
                } else {
                    Text(member == nil ? "사용자를 고르면 보입니다" : "GRM Schedule 에 예정된 차례 없음").font(.hub(13)).foregroundStyle(Hub.text2)
                    Spacer()
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
        }
    }

    private var myProjects: some View {
        let ps = member.map { model.projects(for: $0) } ?? []
        return VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "내 진행 프로젝트 · \(ps.count)")
            VStack(spacing: 0) {
                if ps.isEmpty { Text("Projects & Chores 에 담당 프로젝트 없음").font(.hub(13)).foregroundStyle(Hub.text2).padding(12).frame(maxWidth: .infinity, alignment: .leading) }
                ForEach(Array(ps.enumerated()), id: \.element.id) { i, p in
                    Button { model.openInApp(id: p.id) } label: {
                        HStack { Text(p.name).font(.hub(13, weight: .medium)).lineLimit(1); Spacer(); Text(p.status).font(.hub(11, weight: .bold)).foregroundStyle(Hub.text2) }
                            .padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if i < ps.count - 1 { RowDivider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
        }
    }

    /// 지난 Paper Blitz 에서 내가 고른 논문
    private var myBlitz: some View {
        let mine = model.blitz.filter { !me.isEmpty && model.member(initials: $0.presenter)?.initials == member?.initials }
        return VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "지난 Paper Blitz 내 논문" + (model.blitzDate.map { " · " + Hub.day($0) } ?? ""))
            VStack(alignment: .leading, spacing: 4) {
                if mine.isEmpty { Text("이번 Blitz 에 내 논문 없음").font(.hub(13)).foregroundStyle(Hub.text2) }
                ForEach(mine) { p in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.title).font(.hub(13, weight: .medium)).lineLimit(2)
                        if !p.citation.isEmpty { Text(Hub.citationLine(p).text).font(.hub(12)).foregroundStyle(Hub.text2).lineLimit(1).truncationMode(.tail).help(p.citation) }
                    }
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
        }
    }
}

// MARK: E. 앰비언트 (보조 모니터·벽)

struct AmbientView: View {
    @ObservedObject var model: NotionHubModel

    /// 가까운 D-day 3개: 컨펌한 리마인더 + 학회 초록 마감 + 다음 GRM
    private var countdowns: [(String, Date)] {
        var out: [(String, Date)] = model.confirmedReminders.compactMap { r in r.day.flatMap { $0 >= model.today ? (r.title, $0) : nil } }
        for c in model.conferences { if let d = c.deadline, d >= model.today, !out.contains(where: { $0.0.contains(c.conference) }) { out.append(("\(c.conference) 초록", d)) } }
        return Array(out.sorted { $0.1 < $1.1 }.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(Hub.time(model.now)).font(.hub(96, weight: .bold, design: .rounded)).monospacedDigit()
                Text(Hub.longDay(model.now)).font(.hub(28, weight: .semibold)).foregroundStyle(Hub.text2)
                Spacer()
            }
            if let g = model.nextGRM {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text("다음 GRM").font(.hub(22, weight: .bold)).foregroundStyle(Hub.text2)
                    Text(Hub.day(g.date)).font(.hub(30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(Hub.dday(g.date)).font(.hub(22, weight: .bold)).foregroundStyle(Hub.onAccent)
                        .padding(.horizontal, 12).padding(.vertical, 4).background(Capsule().fill(Hub.ink))
                    Text(g.presenters.isEmpty ? "발표자 미정" : g.presenters).font(.hub(40, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            if let cal = model.todayCalendar {
                NowNextLine(cal: cal).scaleEffect(1.8, anchor: .topLeading).frame(height: 70, alignment: .topLeading)
            }
            HStack(spacing: 16) {
                ForEach(Array(countdowns.enumerated()), id: \.offset) { _, c in
                    let n = Calendar.current.dateComponents([.day], from: model.today, to: c.1).day ?? 99
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Hub.dday(c.1)).font(.hub(44, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(n <= 3 ? Hub.signal : Hub.ink)
                        Text(c.0).font(.hub(17, weight: .semibold)).lineLimit(2)
                        Text(Hub.day(c.1)).font(.hub(14)).foregroundStyle(Hub.text2)
                    }
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Hub.surface))
                }
            }
            // 아래 절반: 오늘 남은 일정 + 다가오는 일정 (멀리서도 읽히게 큰 글자)
            if let cal = model.todayCalendar { AmbientAgenda(cal: cal) }
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 앰비언트 아래 — 오늘 남은 일정과 내일 일정 (CSNL·SLab 캘린더)
struct AmbientAgenda: View {
    @ObservedObject var cal: CalendarModel
    var body: some View {
        let now = cal.now
        let tomorrowEnd = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: now))!
        let rows = cal.upcoming(days: 2).filter { $0.end > now && $0.start < tomorrowEnd }.prefix(6)
        VStack(alignment: .leading, spacing: 10) {
            Text("오늘·내일 일정").font(.hub(18, weight: .bold)).foregroundStyle(Hub.text2)
            if rows.isEmpty { Text(cal.isSettled ? "남은 일정 없음" : "불러오는 중…").font(.hub(20)).foregroundStyle(Hub.text3) }   // 첫 조회 전 (0.37.0 C6)
            ForEach(Array(rows), id: \.id) { e in
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(Calendar.current.isDate(e.start, inSameDayAs: HubClock.now) ? "오늘" : "내일").font(.hub(16, weight: .bold)).foregroundStyle(Hub.text3).frame(width: 44, alignment: .leading)
                    Text(Hub.time(e.start)).font(.hub(24, weight: .semibold, design: .rounded)).monospacedDigit().frame(width: 90, alignment: .leading)
                    Text(Hub.canonicalNames(e.title)).font(.hub(24, weight: .medium)).lineLimit(1)
                }
            }
        }
    }
}
