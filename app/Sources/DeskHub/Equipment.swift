import SwiftUI
import AppKit

// MARK: - 장비 예약 (0.40.0 C5, A5 · F0-2 — 수렴 문서 §3-2 A5, 정의서 A5-*)
// '지금 써도 되나? 닫지 않은 내 예약은?' — 허브 열2 '오늘의 실험' 아래, 장비 6줄 × (지금 | 다음) + 닫기 누락 칩.
// 예전 '자원' Running 줄(오늘의 실험 카드)과 그 guard((끝 ?? 시작) ≥ 오늘, F0-2 — 기한 지난 Running 3건이 사라짐)를 대체한다. 적색 없음.

/// Resource Management 한 행 (Status ≠ Canceled)
struct EquipmentRow: Identifiable, Hashable {
    let id: String
    let resources: [String]
    let start: Date
    let end: Date?
    let hasTime: Bool
    let status: String
    /// 예약자 이니셜(ownerInitials — 멤버가 아니면 '외부', 비면 '')
    let user: String
    /// 끝 순간 — 시간이 없으면(종일) 그날 끝, 끝이 없으면 시작 날 끝
    var endInstant: Date {
        let cal = Calendar.current
        if let e = end { return hasTime ? e : cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: e))!.addingTimeInterval(-1) }
        return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: start))!.addingTimeInterval(-1)
    }
    /// 끝 날짜(날짜 비교용) — (끝 ?? 시작)
    var lastDay: Date { Calendar.current.startOfDay(for: end ?? start) }
}

/// 장비 한 줄 (뷰·덤프 공용)
struct EquipmentLine: Identifiable {
    let machine: String
    let now: String; let busy: Bool; let nowMine: Bool
    let next: String; let nextMine: Bool
    var id: String { machine }
}

enum EquipmentBoard {
    static let limit = 6

    /// Notion 행 → EquipmentRow. owner = 예약자 이니셜 규칙(ownerInitials)
    static func parse(_ p: [String: Any], owner: (String) -> String) -> EquipmentRow? {
        guard let d = NotionAPI.dateRange(p, "date") else { return nil }
        let res = ((NotionAPI.prop(p, "Resource")?["multi_select"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        let id = p["id"] as? String ?? UUID().uuidString
        return EquipmentRow(id: id, resources: res, start: d.start, end: d.end, hasTime: d.hasTime, status: NotionAPI.text(p, "Status"),
                            user: owner(NotionAPI.text(p, "User")))
    }
    /// 앱 창 — (끝 ?? 시작) ≥ 오늘−14 이거나 Running (기한 지난 Running 을 숨기지 않는다, F0-2)
    static func window(_ rows: [EquipmentRow], today: Date) -> [EquipmentRow] {
        let from = Calendar.current.date(byAdding: .day, value: -14, to: today)!
        return rows.filter { $0.status == "Running" || $0.lastDay >= from }
    }
    /// 장비 목록 — 받은 행의 Resource 이름을 행 수 내림차순(같으면 이름), 6개까지 (A5-machines)
    static func machines(_ rows: [EquipmentRow], limit: Int = limit) -> [String] {
        var n: [String: Int] = [:]
        for r in rows { for m in r.resources { n[m, default: 0] += 1 } }
        return Array(n.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key))
    }
    /// 지금 쓰는 예약 — 시작 ≤ 지금 ≤ 끝(종일이면 그날 끝)이고 Done 아님 (A5-now)
    static func current(_ rows: [EquipmentRow], now: Date) -> EquipmentRow? {
        rows.filter { $0.status != "Done" && $0.start <= now && now <= $0.endInstant }.min { $0.start < $1.start }
    }
    /// 다음 예약 — 시작 > 지금 인 가장 이른 것(Done 제외) (A5-next)
    static func upcoming(_ rows: [EquipmentRow], now: Date) -> EquipmentRow? {
        rows.filter { $0.status != "Done" && $0.start > now }.min { $0.start < $1.start }
    }
    static func nowText(_ r: EquipmentRow?) -> String {
        guard let r else { return "비어 있음" }
        return "사용 중" + (r.user.isEmpty ? "" : " " + r.user) + " ~" + Hub.shortDay(r.end ?? r.start)
    }
    static func nextText(_ r: EquipmentRow?) -> String {
        guard let r else { return "—" }
        return Hub.shortDay(r.start) + (r.user.isEmpty ? "" : " " + r.user)
    }
    /// 닫기 누락 — Running 이고 (끝 ?? 시작) < 오늘 (A5-overdue)
    static func isOverdue(_ r: EquipmentRow, today: Date) -> Bool { r.status == "Running" && r.lastDay < Calendar.current.startOfDay(for: today) }
    static func overdue(_ rows: [EquipmentRow], today: Date, me: String) -> (n: Int, mine: Int, rows: [EquipmentRow]) {
        let o = rows.filter { isOverdue($0, today: today) }.sorted { $0.lastDay < $1.lastDay }
        return (o.count, me.isEmpty ? 0 : o.filter { $0.user.uppercased() == me.uppercased() }.count, o)
    }
    /// 장비 6줄 (뷰·덤프 같은 함수)
    static func lines(machines: [String], rows: [EquipmentRow], now: Date, me: String) -> [EquipmentLine] {
        let my = me.uppercased()
        func mine(_ r: EquipmentRow?) -> Bool { !my.isEmpty && (r?.user.uppercased() == my) }
        return machines.map { m in
            let rs = rows.filter { $0.resources.contains(m) }
            let c = current(rs, now: now), n = upcoming(rs, now: now)
            return EquipmentLine(machine: m, now: nowText(c), busy: c != nil, nowMine: mine(c), next: nextText(n), nextMine: mine(n))
        }
    }
}

extension NotionHubModel {
    /// 장비 예약 수(앱 창) — 카드 캡션 n
    var equipmentCount: Int { equipment.count }
    /// 장비 꼬리표·자료 상태 Resource 행 — 오늘 이하 예약 시작일 최댓값. 받은 예약 전체(창 적용 전)가 기준, 없으면 창 안 예약 (리뷰, 검증 1)
    var equipmentContent: Date? {
        equipmentLatestStart ?? equipment.map { Calendar.current.startOfDay(for: $0.start) }.filter { $0 <= today }.max()
    }
    /// 닫기 누락 실측 — Resource 조회가 성공했을 때만(실패면 nil → 위생은 집계 값)
    var equipmentOverdueCount: Int? { equipmentLoaded ? EquipmentBoard.overdue(equipment, today: today, me: HubPrefs.me).n : nil }
    /// 배지 카드(C5) — equip-mine · fu-mine(미팅 후속 내 제안, 0.41.0 C3)
    var extraSeenCards: [String] { ["equip-mine", "fu-mine"] }
    /// equip-mine — 내 예약: 행 id → 시작·끝·상태·장비 해시 · fu-mine — followupSeenRows
    func seenRows(_ card: String, me: String) -> [String: String]? {
        if card == "fu-mine" { return followupSeenRows(me: me) }
        guard card == "equip-mine", equipmentLoaded else { return nil }
        var out: [String: String] = [:]
        for r in equipment where !me.isEmpty && r.user.uppercased() == me.uppercased() {
            out[r.id] = SeenCards.hash([MetricDefs.ymd(r.start), r.end.map(MetricDefs.ymd) ?? "", r.status, r.resources.joined(separator: ",")])
        }
        return out
    }
    /// text.txt [장비] — 장비 6줄 '장비 · 지금 · 다음'(내 것 표시) + '닫기 누락 n (내 것 m) →notion'
    func equipmentDumpLines() -> [String] {
        let me = HubPrefs.me
        let ls = EquipmentBoard.lines(machines: equipmentMachines, rows: equipment, now: now, me: me)
        var out = ["장비 \(ls.count) · 받은 예약 \(equipmentReceived) · 창 \(equipment.count)" + (equipmentLoaded ? "" : " · 조회 실패·없음")]
        out += ls.map { l in [l.machine, l.now + (l.nowMine ? " (내 것)" : ""), l.next + (l.nextMine ? " (내 것)" : "")].joined(separator: " · ") }
        let o = EquipmentBoard.overdue(equipment, today: today, me: me)
        out.append("닫기 누락 \(o.n) (내 것 \(o.mine)) →notion")
        return out
    }
}

/// 장비 예약 카드 — 허브 열2 '오늘의 실험' 아래
struct EquipmentCard: View {
    @ObservedObject var model: NotionHubModel
    @Environment(\.cardStyle) private var cs

    var body: some View {
        let me = HubPrefs.me
        let lines = EquipmentBoard.lines(machines: model.equipmentMachines, rows: model.equipment, now: model.now, me: me)
        let over = EquipmentBoard.overdue(model.equipment, today: model.today, me: me)
        VStack(alignment: .leading, spacing: cs.gap) {
            title
            VStack(alignment: .leading, spacing: 0) {
                if lines.isEmpty { empty } else { grid(lines) }
                if over.n > 0 { overdueChip(n: over.n, mine: over.mine, rows: over.rows) }
                CardFooter(caption: CardMetas.caption("equipment", model))
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
        }
    }

    private var title: some View {
        let at = model.lastUpdated.map(Hub.time) ?? "—"
        return SectionTitle(text: "장비 예약 (예약 기준 · 갱신 \(at))", trailing: "Resource", fresh: model.cardTag("equipment"), badge: "equip-mine") {
            model.openInApp(id: model.cfg.resourceDB)
        }
    }

    private var empty: some View {
        Text(model.loading ? "불러오는 중…" : (model.equipmentLoaded ? "예약 없음" : "Resource 를 읽지 못함"))
            .font(.hub(cs.body)).foregroundStyle(Hub.text2).padding(cs.empty).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func grid(_ lines: [EquipmentLine]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { i, l in
                gridRow(l)
                if i < lines.count - 1 { RowDivider().gridCellUnsizedAxes(.horizontal) }
            }
        }
        .padding(.horizontal, cs.rowH)
    }

    private func gridRow(_ l: EquipmentLine) -> some View {
        let nowColor: Color = l.nowMine ? Hub.ink : (l.busy ? Hub.text : Hub.text3)
        let nextColor: Color = l.nextMine ? Hub.ink : Hub.text2
        let mine = l.nowMine || l.nextMine
        return GridRow {
            Text(l.machine).font(.hub(cs.body, weight: .semibold)).lineLimit(1)
                .frame(width: Hub.s(84), alignment: .leading)
            Text(l.now).font(.hub(cs.aux, weight: l.nowMine ? .bold : .regular)).lineLimit(1)
                .foregroundStyle(nowColor).frame(maxWidth: .infinity, alignment: .leading)
            Text(l.next).font(.hub(cs.aux, weight: l.nextMine ? .bold : .regular)).lineLimit(1)
                .foregroundStyle(nextColor).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, cs.rowV)
        .help(l.machine + " — 지금 " + l.now + " · 다음 " + l.next + (mine ? " (내 것)" : ""))
    }

    /// 점선 테두리 칩(Hub.text2) — 적색 아님. 한 건이면 그 예약, 여러 건이면 Resource DB
    private func overdueChip(n: Int, mine: Int, rows: [EquipmentRow]) -> some View {
        Button {
            if rows.count == 1, let r = rows.first { model.openInApp(id: r.id) } else { model.openInApp(id: model.cfg.resourceDB) }
        } label: {
            Text("닫기 누락 \(n) (내 것 \(mine))").font(.hub(cs.tag, weight: .semibold)).foregroundStyle(Hub.text2).lineLimit(1).fixedSize()
                .padding(.horizontal, 8).padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Hub.text2, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
        .help("Running 인데 끝난 예약 — 예약한 본인이 Notion 에서 Done 으로 (A5-overdue). " + (rows.count == 1 ? "누르면 그 예약" : "누르면 Resource DB"))
    }
}
