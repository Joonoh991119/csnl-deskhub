import SwiftUI
import AppKit

// MARK: - 허브 배치 (0.44.0 A3 — #70 #56 #63)
// 세 리뷰어 공통: 카드가 너무 많고 강약이 비슷해 구분이 안 된다 → 묶음(Research · This week · Deadlines) + 기본 접힘 7종(이 맥 기억) + 'Mine'.
// 한 표(HubGroups)를 Dashboard·HubFill·덤프·키가 같이 쓴다. 관제탑 레일 묶음은 TowerView.railColumns.
// 카드 찾아가기: 알림 "DeskHub.focusCard"(object = 카드 id) — 보내는 쪽은 상태 한 줄 숫자·'--key focus:<id>', 받는 쪽은 Dashboard·관제탑.

extension Notification.Name {
    /// 카드 찾아가기 (0.44.0 #63) — object = 카드 id 문자열. 상태 한 줄은 같은 문자열 "DeskHub.focusCard" 로 보낸다
    static let deskhubFocusCard = Notification.Name("DeskHub.focusCard")
}

/// 허브 묶음 표 — 윗줄 · 열 세 개(라벨 · 카드 순서). ▸ = 기본 접힘(defaultFolded)
enum HubGroups {
    struct Column { let n: String; let label: String; let cards: [String] }
    /// 윗줄: Next GRM · Now·Next(세로, 폭 320) | Mine(넓게)
    static let top = ["grm", "nownext", "mine"]
    /// 열 순서 (결정 D-1) — 논문 펼침 갈래·probe '1' 은 열1 그대로
    static let columns: [Column] = [
        Column(n: "1", label: "Research", cards: ["papers", "followups", "minutes", "blitz", "preprints"]),
        Column(n: "2", label: "This week", cards: ["reminders", "events", "experiments", "equipment", "joint", "classes", "tools"]),
        Column(n: "3", label: "Deadlines", cards: ["conferences", "grants", "members", "apps"]),
    ]
    /// 기본 접힘 7종 (리뷰 #70 목록 그대로, 결정 D-2) — 이 맥에서 바꾼 것은 HubFold 가 기억
    static let defaultFolded: Set<String> = ["minutes", "blitz", "preprints", "classes", "tools", "members", "apps"]
    static var allCards: [String] { columns.flatMap(\.cards) }
    static func column(of id: String) -> String? { columns.first { $0.cards.contains(id) }?.n }
    /// 이 맥에 설치된 앱이 하나도 없으면 Apps 는 접힌 줄도 숨긴다 (#56 '빈 Apps 카드') — 앱 설치는 실행 중 거의 안 바뀌므로 한 번만
    static let appsHidden: Bool = !MadeApps.load().apps.contains(where: \.exists)
    static func shown(_ c: Column) -> [String] { c.cards.filter { $0 != "apps" || !appsHidden } }

    /// text.txt [허브 배치] — 다섯 줄. ▸ = 이 맥 저장 상태로 접힘(찾아가기 임시 펼침은 저장이 아니므로 그대로 ▸)
    @MainActor static func dumpLines() -> [String] {
        let fold = HubFold.shared
        var out = ["윗줄: " + top.joined(separator: " · ")]
        out += columns.map { c in "열\(c.n) \(c.label): " + c.cards.map { (fold.isStoredFolded($0) ? "▸" : "") + $0 }.joined(separator: " · ") }
        var mac = fold.overrides.keys.sorted().map { "\($0)=\(fold.overrides[$0] == true ? "off" : "on")" }
        if appsHidden { mac.append("apps 숨김(설치 0)") }
        out.append("이 맥: " + (mac.isEmpty ? "—" : mac.joined(separator: " ")))
        return out
    }
}

/// 허브 카드 접기 — 이 맥(UserDefaults DeskHub.hubFold = 기본값과 다른 것만 [id: 접힘]). 모든 허브 데이터 카드를 접고 펼 수 있다(7종은 기본 접힘일 뿐).
/// 찾아가기(#63)로 연 것은 임시(temp) — 저장하지 않는다(결정 D-9)
@MainActor
final class HubFold: ObservableObject {
    static let shared = HubFold()
    static let defaultsKey = "DeskHub.hubFold"
    @Published private(set) var overrides: [String: Bool]
    @Published private(set) var temp: Set<String> = []
    private init() { overrides = (UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: Bool]) ?? [:] }

    func isStoredFolded(_ id: String) -> Bool { overrides[id] ?? HubGroups.defaultFolded.contains(id) }
    func isFolded(_ id: String) -> Bool { !temp.contains(id) && isStoredFolded(id) }

    /// 클릭(접힌 줄·제목 화살표)·'--key fold:<id>' 가 같은 경로. 기본값으로 돌아가면 그 id 를 지우고, 모두 기본이면 키를 지운다. 펼 때 UsageLog panel
    func toggle(_ id: String) {
        let folding = !isFolded(id)
        withAnimation(.easeOut(duration: 0.2)) {
            temp.remove(id)
            if folding == HubGroups.defaultFolded.contains(id) { overrides[id] = nil } else { overrides[id] = folding }
        }
        if !folding { UsageLog.panel("fold:" + id) }
        if overrides.isEmpty { UserDefaults.standard.removeObject(forKey: Self.defaultsKey) }
        else { UserDefaults.standard.set(overrides, forKey: Self.defaultsKey) }
    }
    /// 찾아가기 — 접혀 있으면 이번 실행 동안만 편다(저장 안 함)
    func openTemporarily(_ id: String) {
        guard isFolded(id) else { return }
        withAnimation(.easeOut(duration: 0.2)) { _ = temp.insert(id) }
    }
}

/// SectionTitle 앞 접기 화살표 — HubLayout(Dashboard 카드 칸)이 넣을 때만 보인다. 다른 뷰(관제탑·팝오버·Today)는 nil
private struct CardFoldKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues {
    var cardFold: (() -> Void)? {
        get { self[CardFoldKey.self] }
        set { self[CardFoldKey.self] = newValue }
    }
}

/// 접힌 카드 한 줄 — chevron · 제목(SectionTitle 과 같은 글자) · 요약(CardSummary) · ↗. 클릭 1회 = 제자리 펼침(이 맥 저장). 높이 ≤34pt(1.0배)
struct FoldedCardRow: View {
    @ObservedObject var model: NotionHubModel
    let id: String
    @Environment(\.cardStyle) private var cs
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right").font(.hub(max(9, cs.aux - 3), weight: .bold)).foregroundStyle(Hub.text3).frame(width: 12)
            Text(HubCardTitle.title(id)).font(.hub(cs.title, weight: .bold)).foregroundStyle(Hub.text).tracking(0.2).lineLimit(1).fixedSize()
            Text(CardSummary.text(id, model)).font(.hub(cs.aux)).foregroundStyle(Hub.text2).lineLimit(1)
            Spacer(minLength: 4)
            if let l = CardSummary.link(id, model) {
                Button { l.open() } label: { Image(systemName: "arrow.up.forward").font(.hub(cs.aux)) }
                    .buttonStyle(.plain).foregroundStyle(Hub.text2).help(l.help)
            }
        }
        .padding(.horizontal, cs.rowH).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
        .contentShape(Rectangle())
        .onTapGesture { HubFold.shared.toggle(id) }
        .help((HubCardTitle.hint(id).map { $0 + " — " } ?? "") + "눌러서 펼치기 (이 맥에 기억)")
    }
}

/// 카드 한 줄 요약 — 관제탑 접힌 레일 줄과 허브 접힌 줄이 같은 함수 (0.44.0 #70, 예전 TowerView.railItems 안 글을 옮김)
@MainActor
enum CardSummary {
    /// Mail drafts 요약 — 항목 표가 AppsScriptSection 안 private 라 이 한 곳의 상수 (계획 §3)
    static let tools = "메일 초안 4 · GRM 안내·공지·청소·휴가"

    /// 내일부터 eventsDays 일 캘린더 일정 (오늘 것은 관제탑 경보 열 '오늘 남은 일정' 몫)
    static func upcomingEvents(_ m: NotionHubModel) -> [CalEvent] {
        m.todayCalendar?.upcoming(days: m.cfg.eventsDays).filter { $0.end > m.now && !Calendar.current.isDate($0.start, inSameDayAs: m.now) } ?? []
    }

    static func text(_ id: String, _ m: NotionHubModel) -> String {
        let me = HubPrefs.me
        switch id {
        case "papers":
            let mine = m.papers.filter { me.isEmpty || $0.researcher == me }
            let unreacted = mine.filter { (m.paperComments[$0.id] ?? []).filter(\.isReaction).isEmpty }.count
            return m.papersStopped ? "새 추천 없음 (\(m.papersStoppedSince)~)" : "\(mine.count)편" + (me.isEmpty ? "" : " · \(me)") + " · 반응 없음 \(unreacted)"
        case "minutes":
            return m.minutes.first.map { x -> String in let h = m.minutesHeader(x); return (x.date.map(Hub.day) ?? "") + " " + h.who + " | " + h.title } ?? "없음"
        case "followups": return m.followupRailSummary()
        case "events":
            if m.todayCalendar?.isSettled == false { return "캘린더 불러오는 중…" }
            let ev = upcomingEvents(m)
            return "내일부터 \(m.cfg.eventsDays)일 · \(ev.count)건" + (ev.first.map { " · 다음 " + Hub.relative($0.start, now: m.now) + " " + Hub.canonicalNames($0.title) } ?? "")
        case "blitz": return (m.blitzDate.map(Hub.day) ?? "—") + " · \(m.blitz.count)편"
        // Prolific 연결 상태는 요약에서 뺀다 (#56 — 설정 상태라 매일 볼 말이 아님, 카드 안 한 줄은 C2)
        case "experiments": return "\(m.experiments.count)건"
        case "grants":
            let checks = m.grants.filter { $0.needsCheck(today: m.today) }.count
            return "\(m.grants.count)건" + (checks > 0 ? " · 확인 필요 \(checks)" : "")
        case "conferences":
            let c = m.conferences.first.map { c in c.conference + (c.deadline.map { " 초록 " + Hub.relative($0, now: m.now, hasTime: false) } ?? "") } ?? "없음"
            return "\(m.conferences.count)건 · " + c
        case "preprints": return "\(m.preprints.count)편" + (m.preprints.first.map { " · " + $0.title } ?? "")
        case "members": return "\(m.members.filter(\.active).count)명 · 프로젝트 \(m.projects.count)"
        case "apps": return MadeApps.summary
        case "tools": return tools
        case "datastate": return DataSources.summary(m)
        case "reminders":
            let up = HubNear.upcomingReminders(m), lapsed = HubNear.lapsedReminders(m).count
            return "다가올 \(up.count)" + (up.first.map { r in " · " + (r.day.map { Hub.relative($0, now: m.now, hasTime: false) } ?? "미정") + " " + r.title } ?? "")
                + (lapsed > 0 ? " · 지난 \(lapsed)" : "")
        case "equipment":
            let ls = EquipmentBoard.lines(machines: m.equipmentMachines, rows: m.equipment, now: m.now, me: me)
            return EquipmentBoard.summary(lines: ls, overdue: EquipmentBoard.overdue(m.equipment, today: m.today, me: me).n).text
        case "joint": return m.jointNote ?? "\(m.jointRows.count)개"
        case "classes": return "이번 주 · " + Timetable.weekLine(m.courses)
        case "mine": return MineSummary.rows(m, me: me)?.first.map(\.text) ?? "이니셜 미확인"
        default: return ""
        }
    }

    static func link(_ id: String, _ m: NotionHubModel) -> HubLink? {
        switch id {
        case "papers": return .notion(m.cfg.paperRecDB)
        case "minutes": return .notion(m.cfg.meetingNotesDB)
        case "events": return .notion(m.cfg.eventsDB)
        case "blitz": return m.blitzDeckPath.map(HubLink.nas)
        case "experiments": return .notion(m.cfg.slabDB)
        case "grants": return .nas((m.cfg.grantsFile as NSString).deletingLastPathComponent)
        case "conferences": return .notion(m.cfg.conferencesDB)
        case "preprints": return .notion(m.cfg.publicationsDB)
        case "members": return .notion(m.cfg.membersDB)
        case "reminders": return .nas((m.remindersPath as NSString).deletingLastPathComponent)
        case "equipment": return .notion(m.cfg.resourceDB)
        default: return nil
        }
    }
}

/// '내 것' 네 줄 — 허브 'Mine' 카드와 팝오버 '내 것' 이 같은 함수 (0.44.0 #56). 이니셜이 Members 에 없으면 nil
@MainActor
enum MineSummary {
    struct Row: Identifiable {
        let label: String; let value: String; var link: HubLink? = nil; var focus: String? = nil
        var id: String { label }
        var text: String { label + " " + value }
    }
    static func rows(_ model: NotionHubModel, me: String) -> [Row]? {
        guard let m = model.member(initials: me) else { return nil }
        let turn = model.grm.first { $0.date >= model.today && ($0.presenters.contains(m.name) || $0.presenters.contains(m.initials)) }
        let turnText: String = turn.map { t in
            let n = Calendar.current.dateComponents([.day], from: model.today, to: t.date).day ?? 0
            return Hub.day(t.date) + " · " + (n == 0 ? "오늘" : "D-\(n)")
        } ?? "—"
        let myPapers = model.papers.filter { $0.researcher == me }
        let unreacted = myPapers.filter { p in !(model.paperComments[p.id] ?? []).contains { $0.isReaction && $0.who == me } }.count
        // 칩 줄과 같은 소스·같은 매칭 (NAS member_links.json, R-32)
        let projects = PopoverView.myProjects(model, m)
        return [
            Row(label: "내 GRM 차례", value: turnText, link: turn.map { .notion($0.id) }),
            Row(label: "추천 논문", value: "\(myPapers.count)편 · 반응 안 함 \(unreacted)", link: .notion(model.cfg.paperRecDB)),
            // 누르면 첫 프로젝트 폴더 — 칩 클릭과 같은 동작
            Row(label: "진행 프로젝트", value: PopoverView.projectsText(projects), link: projects.first.map { .nas($0.path) }),
            Row(label: "미팅 후속", value: model.myFollowupOpen.map { "남은 \($0)" } ?? "?", focus: "followups"),
        ]
    }
    /// text.txt [내 것]
    static func dumpLines(_ model: NotionHubModel) -> [String] {
        rows(model, me: HubPrefs.me)?.map(\.text) ?? ["이니셜 미확인 — 내 것 없음"]
    }
}

/// 허브 윗줄 오른쪽 'Mine' 카드 (0.44.0 #56, 결정 D-13) — 내 GRM 차례 · 추천 논문 · 진행 프로젝트 · 미팅 후속. 이니셜 미확인이면 확인 줄 한 줄
struct MineCard: View {
    @ObservedObject var model: NotionHubModel
    @Environment(\.cardStyle) private var cs
    var body: some View {
        VStack(alignment: .leading, spacing: cs.gap) {
            SectionTitle(card: "mine")
            VStack(alignment: .leading, spacing: 0) {
                if !HubPrefs.meChosen { MeConfirmBar(model: model, compact: true).padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV) }
                if let rows = MineSummary.rows(model, me: HubPrefs.me) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(r.label).font(.hub(cs.aux)).foregroundStyle(Hub.text2).lineLimit(1).frame(width: cs.col(100), alignment: .leading)
                            Text(r.value).font(.hub(cs.body, weight: .medium)).foregroundStyle(Hub.text).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let l = r.link { l.open() }
                            else if let f = r.focus { NotificationCenter.default.post(name: .deskhubFocusCard, object: f) }
                        }
                        if i < rows.count - 1 { RowDivider() }
                    }
                } else if HubPrefs.meChosen {
                    Text("이니셜이 Members 에 없음").font(.hub(cs.body)).foregroundStyle(Hub.text2).padding(cs.empty)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
        }
    }
}

/// 관제탑으로 넘긴 찾아가기(Dashboard 에 없는 datastate) — 관제탑이 나타날 때 받아 간다
@MainActor
enum HubFocus {
    static var pending: String? = nil
}

extension View {
    /// 찾아간 카드 강조 — Hub.ink 2pt 테두리(적색 아님). on 이 아니면 투명
    func focusRing(_ on: Bool) -> some View {
        overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Hub.ink, lineWidth: 2).opacity(on ? 1 : 0).allowsHitTesting(false))
    }
}
