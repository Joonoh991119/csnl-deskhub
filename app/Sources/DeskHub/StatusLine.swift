import SwiftUI
import AppKit

// MARK: - 연구실 상태 한 줄 · 8주 마감 띠 · '내 것' 배지 (0.40.0 C4, A3 — 수렴 문서 §3-2 A3, 정의서 A3-*)
// 허브·관제탑 맨 위 한 줄: '8주 마감 확정 n · 예상 n · 미정 학회 n·연구비 n | 자료 멈춤 n | 다음 GRM M.d | 현장 실험 마지막 n일'.
// 허브는 확정 마감 D≤3 이면 '확정 n' 한 칸만 Hub.signal — 카드(그랜트·학회·리마인더) D-day 적색은 quiet 로 이 한 칸에 모은다(결정 D-b).
// 관제탑은 경보 열이 같은 마감을 적색으로 갖고 있어 이 줄은 quiet(무채색). 클릭 1회 = 제자리 8주 띠(NSPopover 아님), Esc·--key band 로 닫음.

/// 띠·한 줄의 마감 표식 하나
struct BandMark: Identifiable {
    let id: String; let title: String; let date: Date; let confirmed: Bool; let link: HubLink?
}

enum StatusLine {
    enum Variant: String { case l = "L", m = "M", s = "S" }
    struct Parts: Equatable {
        var confirmed = 0, expected = 0, undecidedConf = 0, undecidedGrant = 0, stopped = 0
        var nextGRM = "—"
        var fieldDays: Int? = nil
        /// 확정 마감 중 D≤3 이 있나 — 허브 '확정 n' 칸 적색
        var soon = false
    }
    enum Role { case label, number, sep, signal }

    // MARK: 창 (A3-window, 결정 D-a)
    /// 이번 주 월요일 0시(한국시간)부터 56일 — 끝은 8주째 일요일
    static func window(today: Date) -> (start: Date, end: Date) {
        let start = MetricDefs.week(of: today).start
        return (start, MetricDefs.kst.date(byAdding: .day, value: 55, to: start)!)
    }

    // MARK: 마감 표식 (A3-confirmed·A3-expected)
    /// 창 안·오늘 이후 마감: 그랜트 due(확정) · 학회 deadline('[확정]' 이면 확정, 아니면 예상) ·
    /// 컨펌 리마인더 중 제출·보고이고 출처가 그랜트·학회 파일이 아닌 것(확정, AlertEngine.sameEvent 로 중복 하나)
    @MainActor static func marks(_ m: NotionHubModel, today: Date) -> [BandMark] {
        let w = window(today: today)
        let cal = Calendar.current
        func inWindow(_ d: Date) -> Bool { let x = cal.startOfDay(for: d); return x >= cal.startOfDay(for: today) && x <= w.end }
        let grantsDir = (m.cfg.grantsFile as NSString).deletingLastPathComponent
        var out: [BandMark] = []
        for g in m.grants { if let d = g.due, inWindow(d) {
            let dir = m.cfg.nasGRMRoot.replacingOccurrences(of: "/GRM", with: "") + "/" + g.folder
            out.append(BandMark(id: "grant-" + g.id, title: g.title, date: AlertEngine.grantDue(title: g.title, dueNote: g.dueNote, day: d).due, confirmed: true,
                                link: .nas(!g.folder.isEmpty && FileManager.default.fileExists(atPath: dir) ? dir : grantsDir)))
        } }
        for c in m.conferences { if let d = c.deadline, inWindow(d) {
            out.append(BandMark(id: "conf-" + c.id, title: c.conference, date: d, confirmed: c.deadlineLabel.contains("[확정]"),
                                link: c.link.map(HubLink.url) ?? .notion(c.id)))
        } }
        for r in m.confirmedReminders where ["제출", "보고"].contains(r.kind) && r.source != "grants_schedule.json" && r.source != "conferences_upcoming.json" {
            guard let d = r.day, inWindow(d) else { continue }
            if out.contains(where: { AlertEngine.sameEvent(reminderID: r.id, reminderTitle: r.title, grantTitle: $0.title) }) { continue }
            out.append(BandMark(id: "rem-" + r.id, title: r.title, date: d, confirmed: true,
                                link: r.source.hasPrefix("notion:") ? .notion(String(r.source.dropFirst(7))) : nil))
        }
        return out.sorted { $0.date < $1.date }
    }

    /// 한 줄의 숫자들 — 뷰·덤프·text-check 가 같은 값
    @MainActor static func parts(_ m: NotionHubModel) -> Parts {
        let today = m.today
        let mk = marks(m, today: today)
        var p = Parts()
        p.confirmed = mk.filter(\.confirmed).count
        p.expected = mk.filter { !$0.confirmed }.count
        p.soon = mk.contains { $0.confirmed && (Calendar.current.dateComponents([.day], from: today, to: Calendar.current.startOfDay(for: $0.date)).day ?? 99) <= 3 }
        p.undecidedConf = m.conferences.filter { $0.deadline == nil }.count
        p.undecidedGrant = m.grants.filter { $0.due == nil }.count
        // 자료 멈춤 — A2 ×2 초과 원천에서 SLab·SLab 캘린더를 뺀 수 (A3-stopped, 현장은 따로)
        p.stopped = DataSources.rows(m, today: today).filter { $0.judge?.kind == .stopped && !DataSources.slabSources.contains($0.id) }.count
        p.nextGRM = m.nextGRM.map { Hub.shortDay($0.date) } ?? "—"
        p.fieldDays = fieldDays(slab: m.metrics?.slabLast, ics: m.metrics?.icsLast, today: today)
        return p
    }
    /// 현장 실험 마지막 n일 (A3-field) — 오늘 − max(slab, ics). 둘 다 없으면 nil
    static func fieldDays(slab: Date?, ics: Date?, today: Date) -> Int? {
        guard let last = [slab, ics].compactMap({ $0 }).max() else { return nil }
        let cal = Calendar.current
        return max(0, cal.dateComponents([.day], from: cal.startOfDay(for: last), to: cal.startOfDay(for: today)).day ?? 0)
    }

    // MARK: 글 (A3-variant)
    static func segments(_ v: Variant, _ p: Parts, quiet: Bool) -> [(String, Role)] {
        let red: Role = (!quiet && p.soon) ? .signal : .number
        switch v {
        case .l:
            return [("8주 마감 ", .label), ("확정 ", red == .signal ? .signal : .label), ("\(p.confirmed)", red), (" · 예상 ", .label), ("\(p.expected)", .number),
                    (" · 미정 학회 ", .label), ("\(p.undecidedConf)", .number), ("·연구비 ", .label), ("\(p.undecidedGrant)", .number),
                    (" | ", .sep), ("자료 멈춤 ", .label), ("\(p.stopped)", .number),
                    (" | ", .sep), ("다음 GRM ", .label), (p.nextGRM, .number),
                    (" | ", .sep), ("현장 실험 마지막 ", .label), (p.fieldDays.map { "\($0)일" } ?? "—", .number)]
        case .m:
            return [("마감 ", .label), ("확정 ", red == .signal ? .signal : .label), ("\(p.confirmed)", red), (" · 예상 ", .label), ("\(p.expected)", .number),
                    (" | ", .sep), ("자료 멈춤 ", .label), ("\(p.stopped)", .number)]
        case .s:
            return [("마감 ", red == .signal ? .signal : .label), ("\(p.confirmed)", red), (" | ", .sep), ("멈춤 ", .label), ("\(p.stopped)", .number)]
        }
    }
    static func text(_ v: Variant, _ p: Parts) -> String { segments(v, p, quiet: true).map(\.0).joined() }

    // MARK: 숫자 클릭 (0.44.0 B2, #63) — 숫자를 누르면 그 카드로. 받는 쪽은 알림 "DeskHub.focusCard"(object = 카드 id)
    /// 조각 이름 → 대상 카드 id. 확정·예상은 8주 띠(band)
    static let targetIDs: [(segment: String, target: String)] = [
        ("확정", "band"), ("예상", "band"), ("학회", "conferences"), ("연구비", "grants"), ("멈춤", "datastate"), ("GRM", "grm"), ("현장", "experiments"),
    ]
    /// 순수 — 누를 수 있는 숫자(0·'—' 은 빠짐)와 대상. 뷰·text-check sl-target 이 같은 함수
    static func targets(_ p: Parts) -> [(segment: String, target: String)] {
        let live: [String: Bool] = [
            "확정": p.confirmed > 0, "예상": p.expected > 0, "학회": p.undecidedConf > 0, "연구비": p.undecidedGrant > 0,
            "멈춤": p.stopped > 0, "GRM": !p.nextGRM.isEmpty && p.nextGRM != "—", "현장": (p.fieldDays ?? 0) > 0,
        ]
        return targetIDs.filter { live[$0.segment] == true }
    }
    /// 숫자 조각 바로 앞 라벨 → 조각 이름 (segments 의 라벨 글과 짝). S 갈래 '마감 n' 은 확정 수
    static func segmentName(afterLabel label: String) -> String? {
        let l = label.trimmingCharacters(in: CharacterSet(charactersIn: " ·|"))
        switch l {
        case "확정", "마감": return "확정"
        case "예상": return "예상"
        case "미정 학회": return "학회"
        case "연구비": return "연구비"
        case "자료 멈춤", "멈춤": return "멈춤"
        case "다음 GRM": return "GRM"
        case "현장 실험 마지막": return "현장"
        default: return nil
        }
    }
    /// 도움말에 쓰는 대상 이름
    static func targetTitle(_ id: String) -> String {
        if id == "band" { return "8주 마감 띠" }
        if HubCardTitle.hint(id) != nil { return HubCardTitle.title(id) }
        return id == "datastate" ? "Data status" : id
    }
    /// 숫자 클릭 1회 — band 면 띠 열기·닫기, 아니면 그 카드로(받는 쪽이 펼침·테두리). Notification.Name 확장 멤버는 만들지 않는다(갈래 약속)
    @MainActor static func focus(_ id: String) {
        if id == "band" { StatusBand.shared.toggle(); return }
        NotificationCenter.default.post(name: Notification.Name("DeskHub.focusCard"), object: id)
    }
    /// text-check sl-target — '확정→band · 학회→conferences · …' | '—'
    static func targetsText(_ p: Parts) -> String {
        let t = targets(p)
        return t.isEmpty ? "—" : t.map { "\($0.segment)→\($0.target)" }.joined(separator: " · ")
    }

    /// 실제 폭(NSFont 13×배율, 숫자 굵게와 같은 semibold 로 넉넉히)으로 갈래를 고른다 — 420pt 미만은 M·S 만. 하나도 안 맞으면 (S, 잘림)
    static let horizontalPadding: CGFloat = 24
    /// weight — 기본 semibold(상태 한 줄). Members 열 머리 실측은 bold (0.43.0 C2)
    static func measure(_ s: String, size: CGFloat, weight: NSFont.Weight = .semibold) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: HubDisplay.nsFont(size: size, weight: weight)]).width)
    }
    static func variant(width: CGFloat, scale: CGFloat, parts: Parts, chips: [String] = []) -> (variant: Variant, fits: Bool) {
        // 뷰와 같은 자리 — 좌우 여백 24 + 오른쪽 띠 화살표(HStack 간격 8 이 Spacer 양쪽에 두 번 = 16, 10pt 굵은 글리프 ≈ 11pt × 배율 → 12 × 배율)
        // + 굵은 숫자 여유 4 + 칩들(칩마다 글 폭 + 좌우 안쪽 16 + 간격 8 — '내 GRM 바뀜'·'미팅 후속 n · 내일 GRM', 0.41.0 C4). 칩이 먼저 자리를 받는다.
        // 예전 10×배율+8 은 600pt·1.0× 에서 L 을 '맞음'으로 고르고 실제로는 잘렸다 (리뷰, 검증 1)
        let chevron = 16 + 12 * scale
        let slack: CGFloat = 8  // semibold 측정과 실제(보통 글 + 굵은 숫자) 차 최대 8pt — 809pt·1.3× 에서 L 오판 (리뷰 2)
        let chipW = chips.reduce(CGFloat(0)) { $0 + measure($1, size: 12 * scale) + 16 + 8 }
        let avail = width - horizontalPadding - chevron - slack - chipW
        let order: [Variant] = width < 420 ? [.m, .s] : [.l, .m, .s]
        for v in order where measure(text(v, parts), size: 13 * scale) <= avail { return (v, true) }
        return (.s, false)
    }

    // MARK: 8주 띠
    struct Week: Identifiable { let id: Int; let start: Date; let end: Date; let marks: [BandMark]; let grm: [String]; let current: Bool }
    @MainActor static func weeks(_ m: NotionHubModel) -> [Week] {
        let today = m.today
        let w = window(today: today)
        let mk = marks(m, today: today)
        let cal = Calendar.current
        return (0..<8).map { i in
            let s = MetricDefs.kst.date(byAdding: .day, value: 7 * i, to: w.start)!
            let e = MetricDefs.kst.date(byAdding: .day, value: 6, to: s)!
            func inWeek(_ d: Date) -> Bool { let x = cal.startOfDay(for: d); return x >= cal.startOfDay(for: s) && x <= cal.startOfDay(for: e) }
            let grm = m.grm.filter { inWeek($0.date) }.flatMap { m.initialsList($0.presenters).components(separatedBy: ", ") }.filter { !$0.isEmpty }
            return Week(id: i, start: s, end: e, marks: mk.filter { inWeek($0.date) }, grm: grm, current: i == 0)
        }
    }
    static func rangeText(_ s: Date, _ e: Date) -> String { Hub.shortDay(s) + "–" + Hub.shortDay(e) }
    /// 8주 띠 범례 두 줄 (0.44.0 B2, #63) — 뷰·덤프 '범례: …' 같은 글
    static let legend: [String] = [
        "◆ 확정 = 날짜가 정해진 연구비·리마인더·학회 마감 · ◇ 예상 = 아직 공지 전, 작년 날짜로 잡은 학회 마감",
        "GRM = 그 주 발표자 · 미정 = 마감일이 아직 없는 학회·연구비",
    ]
    /// 띠 왼쪽 줄 이름 열
    static let rowNames = ["주", "마감", "GRM"]

    // MARK: 덤프
    /// text.txt [상태 한 줄] — L 전체 글 + 300·420·600pt × 1.0·1.3·1.6 갈래
    @MainActor static func dumpLines(_ m: NotionHubModel) -> [String] {
        let p = parts(m)
        var out = ["L: " + text(.l, p) + (p.soon ? " (확정 D≤3 — 허브 적색 1칸)" : "")]
        out.append("M: " + text(.m, p))
        out.append("S: " + text(.s, p))
        for w in [300, 420, 600] as [CGFloat] {
            out.append("\(Int(w))pt · " + [1.0, 1.3, 1.6].map { sc -> String in
                let v = variant(width: w, scale: CGFloat(sc), parts: p)
                return String(format: "%.1f배 ", sc) + v.variant.rawValue + (v.fits ? "" : " 잘림")
            }.joined(separator: " · "))
        }
        if (SeenCards.shared.counts["grm-mine"] ?? 0) > 0 { out.append("고정 칩: 내 GRM 바뀜 · 확인") }
        // 칩 (0.41.0 C4) — 뷰와 같은 chips(m): '내 GRM 바뀜 · 확인' · '미팅 후속 n · 내일 GRM'. 없으면 '—'
        let cs = chips(m)
        out.append("칩: " + (cs.isEmpty ? "—" : cs.map(\.text).joined(separator: " · ")))
        return out
    }

    // MARK: 칩 (0.41.0 C4, R1-e)
    struct Chip: Identifiable, Equatable { let id: String; let text: String; let help: String }
    /// 맨 위 한 줄 왼쪽 칩 — 'grm-mine'(내 GRM 바뀜) + 'fu'(미팅 후속 n · 내일 GRM — 다음 MM·GRM 전날·당일, 보기 내용·남은 > 0·그날 미확인일 때만).
    /// fu 칩은 수만 담으므로 관제탑(quiet)에도 같은 칩이 뜬다. 적색 아님
    @MainActor static func chips(_ m: NotionHubModel) -> [Chip] {
        var out: [Chip] = []
        if (SeenCards.shared.counts["grm-mine"] ?? 0) > 0 {
            out.append(Chip(id: "grm-mine", text: "내 GRM 바뀜 · 확인", help: "내가 발표자인 GRM 의 날짜·종류가 바뀜 — 누르면 확인(이 맥)"))
        }
        if let r = m.followupReminder(), let n = m.myFollowupOpen {
            out.append(Chip(id: "fu", text: "미팅 후속 \(n) · \(r)", help: "다음 미팅 전에 남은 미팅 후속 \(n)개 — 누르면 오늘은 확인(이 맥), 허브에서는 카드를 펼침"))
        }
        return out
    }
    /// text.txt [8주 띠] — W1~W8 'M.d–M.d · ◆ 제목 M.d · ◇ … · GRM 이니셜' + 미정 줄
    @MainActor static func bandDumpLines(_ m: NotionHubModel) -> [String] {
        let p = parts(m)
        var out = weeks(m).map { w -> String in
            var f = ["W\(w.id + 1) " + rangeText(w.start, w.end) + (w.current ? " (이번 주)" : "")]
            f += w.marks.map { ($0.confirmed ? "◆ " : "◇ ") + $0.title + " " + Hub.shortDay($0.date) }
            f.append("GRM " + (w.grm.isEmpty ? "—" : w.grm.joined(separator: ",")))
            return f.joined(separator: " · ")
        }
        out.append("마감 미정 학회 \(p.undecidedConf) · 연구비 \(p.undecidedGrant)")
        out.append("범례: " + legend.joined(separator: " · "))
        return out
    }
}

/// 8주 띠 열림 상태 — 허브·관제탑 공용(한 번에 하나). 열 때 UsageLog panel 'band'
@MainActor
final class StatusBand: ObservableObject {
    static let shared = StatusBand()
    @Published var open = false
    func toggle() {
        withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
        if open { UsageLog.panel("band") }
    }
    func close() { if open { withAnimation(.easeOut(duration: 0.15)) { open = false } } }
}

/// 맨 위 한 줄 — 허브(quiet false)·관제탑(quiet true)
struct StatusLineView: View {
    @ObservedObject var model: NotionHubModel
    var quiet = false
    @ObservedObject private var band = StatusBand.shared
    @ObservedObject private var seen = SeenCards.shared
    /// 마우스가 올라간 숫자 조각(밑줄)
    @State private var hovered: String?
    static var height: CGFloat { Hub.s(26) }

    var body: some View {
        GeometryReader { g in
            let p = StatusLine.parts(model)
            let chips = StatusLine.chips(model)
            let v = StatusLine.variant(width: g.size.width, scale: HubDisplay.scale, parts: p, chips: chips.map(\.text))
            HStack(spacing: 8) {
                ForEach(chips) { c in
                    Button { tap(c) } label: {
                        // 미팅 후속 칩은 Hub.ink 굵게(적색 아님), 내 GRM 바뀜은 Hub.text2 — 바탕은 둘 다 Hub.fillNeutral
                        Text(c.text).font(.hub(12, weight: .semibold)).foregroundStyle(c.id == "fu" ? Hub.ink : Hub.text2).lineLimit(1).fixedSize()
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill(Hub.fillNeutral))
                    }
                    .buttonStyle(.plain).help(c.help)
                }
                line(StatusLine.segments(v.variant, p, quiet: quiet), targets: StatusLine.targets(p))
                Spacer(minLength: 0)
                Image(systemName: band.open ? "chevron.up" : "chevron.down").font(.hub(10, weight: .bold)).foregroundStyle(Hub.text3)
            }
            .padding(.horizontal, StatusLine.horizontalPadding / 2)
            .frame(width: g.size.width, height: g.size.height, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Hub.surface))
            .contentShape(Rectangle())
            .onTapGesture { band.toggle() }
            .help("8주 마감 띠 열기·닫기 (Esc) — 정의 A3-* (docs/metrics-definitions.md)")
            .onAppear { LayoutChoice.record("status-line", v.variant.rawValue + (v.fits ? "" : " 잘림")) }
            .onChange(of: v.variant.rawValue + (v.fits ? "" : " 잘림")) { _, s in LayoutChoice.record("status-line", s) }
            .overlay(alignment: .topLeading) {
                if band.open {
                    EightWeekBand(model: model, width: min(g.size.width - 24, Hub.s(560)))
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(x: 12, y: g.size.height + 4)
                        .transition(.opacity)
                }
            }
        }
        .frame(height: Self.height)
        .zIndex(10)
    }

    /// 칩 클릭 1회 — 내 GRM 바뀜은 확인, 미팅 후속은 그날 확인 + (허브면) 카드 제자리 펼침
    private func tap(_ c: StatusLine.Chip) {
        switch c.id {
        case "grm-mine": seen.acknowledge("grm-mine")
        case "fu":
            model.ackFollowupReminder()
            if !quiet, !HubExpansion.shared.isOpen("followups") { HubExpansion.shared.toggle("followups") }
        default: break
        }
    }

    /// 조각을 Text 여러 개로(글 폭은 이어붙인 글과 같음 — variant 판정 그대로). 대상이 있는 숫자만 누를 수 있고(밑줄·도움말), 그 밖은 줄 전체 = 띠 열기·닫기 (0.44.0 B2, #63)
    private func line(_ segs: [(String, StatusLine.Role)], targets: [(segment: String, target: String)]) -> some View {
        let byName = Dictionary(targets.map { ($0.segment, $0.target) }, uniquingKeysWith: { a, _ in a })
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(segs.enumerated()), id: \.offset) { i, s in
                let isNum = s.1 == .number || s.1 == .signal
                let name = isNum && i > 0 ? StatusLine.segmentName(afterLabel: segs[i - 1].0) : nil
                if let name, let target = byName[name] {
                    piece(s).underline(hovered == name).fixedSize()
                        .contentShape(Rectangle())
                        .onTapGesture { StatusLine.focus(target) }
                        .onHover { h in hovered = h ? name : (hovered == name ? nil : hovered) }
                        .help("눌러서 \(StatusLine.targetTitle(target)) 보기")
                } else {
                    piece(s).lineLimit(1)
                }
            }
        }
        .font(.hub(13))
    }
    private func piece(_ s: (String, StatusLine.Role)) -> Text {
        let t = Text(s.0)
        switch s.1 {
        case .label: return t.foregroundStyle(Hub.text2)
        case .number: return t.fontWeight(.bold).foregroundStyle(Hub.text)
        case .sep: return t.foregroundStyle(Hub.divider)
        case .signal: return t.fontWeight(.bold).foregroundStyle(Hub.signal)
        }
    }
}

/// 8주 띠 — 8열(주, 한국시간 월~일) × 1행. 칸 바탕 Hub.fillNeutral, 이번 주만 Hub.ink 1pt 테두리. ◆ 확정(Hub.ink) · ◇ 예상(Hub.text2)
struct EightWeekBand: View {
    @ObservedObject var model: NotionHubModel
    let width: CGFloat
    private let gap: CGFloat = 4

    var body: some View {
        let weeks = StatusLine.weeks(model)
        let p = StatusLine.parts(model)
        let inner = max(160, width - 24)
        // 왼쪽 줄 이름 열('주'·'마감'·'GRM') 만큼 칸이 좁아진다 (0.44.0 B2, #63)
        let nameW = Hub.s(30)
        let cellW = (inner - nameW - gap * 8) / 8
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("8주 마감 띠").font(.hub(13, weight: .bold))
                Spacer(minLength: 4)
                Button { StatusBand.shared.close() } label: { Image(systemName: "xmark").font(.hub(11, weight: .bold)).frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(Hub.text2).help("닫기 (Esc)")
            }
            VStack(alignment: .leading, spacing: 3) {
                // 주 — 그 주 월요일
                HStack(alignment: .firstTextBaseline, spacing: gap) {
                    rowName(StatusLine.rowNames[0], width: nameW)
                    ForEach(weeks) { w in
                        Text(Hub.shortDay(w.start)).font(.hub(11, weight: w.current ? .bold : .regular)).foregroundStyle(w.current ? Hub.ink : Hub.text3).lineLimit(1)
                            .frame(width: cellW).help(StatusLine.rangeText(w.start, w.end))
                    }
                }
                // 마감 — ◆ 확정 · ◇ 예상
                HStack(alignment: .center, spacing: gap) {
                    rowName(StatusLine.rowNames[1], width: nameW)
                    ForEach(weeks) { w in
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Hub.fillNeutral)
                            if w.current { RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Hub.ink, lineWidth: 1) }
                            HStack(spacing: 2) {
                                ForEach(w.marks.prefix(3)) { mk in
                                    Text(mk.confirmed ? "◆" : "◇").font(.hub(14, weight: .bold)).foregroundStyle(mk.confirmed ? Hub.ink : Hub.text2)
                                        .help(mk.title + " · " + Hub.shortDay(mk.date) + (mk.confirmed ? " · 확정" : " · 예상"))
                                        .onTapGesture { mk.link?.open() }
                                        .accessibilityLabel("\(Hub.shortDay(mk.date)) \(mk.title) \(mk.confirmed ? "확정" : "예상") 마감")
                                }
                                if w.marks.count > 3 { Text("+\(w.marks.count - 3)").font(.hub(10.5, weight: .semibold)).foregroundStyle(Hub.text2) }
                            }
                        }
                        .frame(width: cellW, height: Hub.s(44))
                        .help(StatusLine.rangeText(w.start, w.end))
                    }
                }
                // GRM — 그 주 발표자
                HStack(alignment: .firstTextBaseline, spacing: gap) {
                    rowName(StatusLine.rowNames[2], width: nameW)
                    ForEach(weeks) { w in
                        Text(w.grm.isEmpty ? " " : w.grm.joined(separator: " ")).font(.hub(10.5)).foregroundStyle(Hub.text3).lineLimit(1).truncationMode(.tail)
                            .frame(width: cellW)
                    }
                }
            }
            Text("마감 미정 학회 \(p.undecidedConf) · 연구비 \(p.undecidedGrant)").font(.hub(12)).foregroundStyle(Hub.text2)
            // 범례 두 줄 — 적색 없음, 줄바꿈 허용 (0.44.0 B2, #63). 출처 캡션은 뺐다(#65)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(StatusLine.legend, id: \.self) { l in
                    Text(l).font(.hub(11)).foregroundStyle(Hub.text2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Hub.card).shadow(color: .black.opacity(0.22), radius: 12, y: 4))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Hub.divider))
        .foregroundStyle(Hub.text)
    }
    private func rowName(_ t: String, width: CGFloat) -> some View {
        Text(t).font(.hub(10.5)).foregroundStyle(Hub.text3).lineLimit(1).frame(width: width, alignment: .leading)
    }
}

// MARK: - '내 것' 배지 (A3-badge) — 카드별 행 id → 화면 필드 해시(FNV-1a 64, 실행마다 같은 값). 숫자는 내 것만

@MainActor
final class SeenCards: ObservableObject {
    static let shared = SeenCards()
    /// 화면에 '새 n' 을 내는 카드 — events 는 계산·덤프만(랩 전체 변경 수는 화면 숫자로 내지 않음, §3)
    static let shown: Set<String> = ["grm-mine", "rem-mine", "equip-mine", "fu-mine"]
    @Published private(set) var counts: [String: Int] = [:]
    /// 이번 실행에서 기준선을 새로 만든 카드
    private(set) var created: Set<String> = []
    private var current: [String: [String: String]] = [:]
    private var baselines: [String: [String: String]] = [:]
    private var me = ""

    nonisolated static func fnv(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }
    static func hash(_ fields: [String]) -> String { fnv(fields.joined(separator: "|")) }
    static func ymd(_ d: Date?) -> String { d.map(MetricDefs.ymd) ?? "" }

    /// 카드의 지금 행 — grm-mine(내가 발표자: 날짜·종류) · rem-mine(제목이 내 것이거나 내가 바꾼 리마인더: 날짜·상태·제목) · events(캘린더 시각·제목).
    /// nil = 아직 판단할 자료가 없음(멤버 미확인·리마인더 파일 못 읽음) → 기준선을 만들지도, 세지도 않는다. [:] 를 돌려주면 빈 기준선이 저장돼
    /// 자료가 들어온 뒤 전부 '새 n' 이 된다 (리뷰, 검증 1)
    static func rows(_ card: String, _ m: NotionHubModel, me: String) -> [String: String]? {
        switch card {
        case "grm-mine":
            guard let my = m.myMember(me) else { return nil }
            var out: [String: String] = [:]
            for g in m.grm where m.isMine(g.presenters, me: me) || m.initialsList(g.presenters).components(separatedBy: ", ").contains(my.initials) {
                out[g.id] = hash([ymd(g.date), g.type])
            }
            return out
        case "rem-mine":
            guard m.remindersLoadedOK else { return nil }
            var out: [String: String] = [:]
            for r in m.reminders where m.isMine(r.title, me: me) || (r.by ?? "").uppercased() == me.uppercased() {
                out[r.id] = hash([r.date, r.status, r.title])
            }
            return out
        case "events":
            guard let cal = m.todayCalendar, cal.isSettled else { return nil }
            var out: [String: String] = [:]
            for e in cal.upcoming(days: m.cfg.eventsDays) { out[e.id + "@" + ymd(e.start)] = hash([ISO8601DateFormatter().string(from: e.start), e.title]) }
            return out
        default:
            return m.seenRows(card, me: me)
        }
    }

    /// 내가 마지막으로 바꾼 행(by == 나) — 내 확정·끝남·미루기는 '새' 로 세지 않고 기준선에 바로 흡수한다 (리뷰, 검증 1)
    static func ownEdits(_ card: String, _ m: NotionHubModel, me: String) -> Set<String> {
        guard card == "rem-mine", !me.isEmpty else { return [] }
        return Set(m.reminders.filter { ($0.by ?? "").uppercased() == me.uppercased() }.map(\.id))
    }

    /// 갱신이 다 끝날 때(markSettled) — 첫 실행은 기준선만 저장(새 0). 새 n = 기준선에 없는 행 + 해시가 바뀐 행(창 밖으로 밀린 행은 세지 않음).
    /// 내가 바꾼 행(ownEdits)은 세기 전에 기준선을 지금 값으로 맞춘다
    func update(_ m: NotionHubModel) {
        let me = HubPrefs.me.uppercased()
        guard !me.isEmpty, m.lastUpdated != nil, m.error == nil else { return }
        if me != self.me { self.me = me; created = []; baselines = SeenStore.load(me).cards ?? [:] }
        var changed = false
        var next = counts
        for card in ["grm-mine", "rem-mine", "events"] + m.extraSeenCards {
            guard let rows = Self.rows(card, m, me: me) else { continue }
            current[card] = rows
            if var base = baselines[card] {
                var absorbed = false
                for id in Self.ownEdits(card, m, me: me) { if let v = rows[id], base[id] != v { base[id] = v; absorbed = true } }
                if absorbed { baselines[card] = base; changed = true }
                next[card] = rows.filter { base[$0.key] != $0.value }.count
            } else {
                baselines[card] = rows; created.insert(card); changed = true; next[card] = 0
            }
        }
        if next != counts { counts = next }
        if changed { persist() }
    }
    /// '새 n' 칩·'내 GRM 바뀜 · 확인'·--key seen:<카드> — 그 카드 기준선을 지금 행으로
    func acknowledge(_ card: String) {
        guard !me.isEmpty, let rows = current[card] else { return }
        baselines[card] = rows
        counts[card] = 0
        persist()
    }
    private func persist() {
        var s = SeenStore.load(me)
        s.cards = baselines
        SeenStore.save(s, me)
    }
    /// text.txt [배지] — '<카드> · 기준선 있음|새로 · 새 n' (events 는 '화면 숫자 없음')
    func dumpLines(_ m: NotionHubModel) -> [String] {
        let me = HubPrefs.me
        guard !me.isEmpty else { return ["이니셜 없음 — 배지 계산 안 함"] }
        return (["grm-mine", "rem-mine", "events"] + m.extraSeenCards).map { c in
            let state = created.contains(c) ? "새로" : (baselines[c] != nil ? "기준선 있음" : "기준선 없음")
            return "\(c) · \(state) · 새 \(counts[c] ?? 0)" + (Self.shown.contains(c) ? "" : " (화면 숫자 없음)")
        }
    }
}

/// 카드 꼬리표 옆 '새 n' 칩 (Hub.text2 글자 · Hub.fillNeutral 바탕) — 누르면 그 카드 기준선 갱신
struct SeenBadge: View {
    let card: String
    @ObservedObject private var seen = SeenCards.shared
    var body: some View {
        if let n = seen.counts[card], n > 0, SeenCards.shown.contains(card) {
            Button { seen.acknowledge(card) } label: {
                Text("새 \(n)").font(.hub(11, weight: .semibold)).foregroundStyle(Hub.text2).lineLimit(1).fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Hub.fillNeutral))
            }
            .buttonStyle(.plain).help("내 것 중 바뀐 행 \(n) — 누르면 확인(이 맥)")
        }
    }
}
