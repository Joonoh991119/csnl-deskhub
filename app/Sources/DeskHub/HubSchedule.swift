import SwiftUI
import AppKit

// MARK: - v23 (2026-10-14, JYK 리뷰 #13 #14 #18)
// - 다음 GRM 과 오늘 캘린더(지금·다음)를 다른 카드로
// - 다가오는 일정 = Notion Schedule & Events + CSNL·SLab 캘린더(겹치면 하나만), 출처 표시
// - 일정 제목의 이름·옛 이니셜은 정본 이니셜로 (Min Jin · MinJin → MJC)
// - 'CSNL GRM' 탭은 웹뷰 대신 발표 순번

extension Hub {
    /// 일정 제목 안의 이름·옛 이니셜 → Members 정본 이니셜. scripts/weekly_pipeline.py NAME_ALIASES 와 같은 표 (#14)
    static let nameAliases: [(pattern: String, initials: String)] = [
        ("(?i)\\bmin\\s*jin\\b", "MJC"), ("\\bSK\\b", "SJK"), ("\\bRJH\\b", "JHR"),
    ]
    static func canonicalNames(_ s: String) -> String {
        nameAliases.reduce(s) { $0.replacingOccurrences(of: $1.pattern, with: $1.initials, options: .regularExpression) }
    }
    /// 두 소스(Notion·캘린더)의 같은 일정을 맞추는 열쇠: 정본 이니셜, 소문자, 글자·숫자만
    static func eventKey(_ title: String, _ date: Date) -> String {
        let t = canonicalNames(title).lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"
        return f.string(from: date) + "|" + String(String.UnicodeScalarView(t))
    }
}

/// 윗줄 가운데 — 오늘 캘린더의 지금·다음 (다음 GRM 카드와 분리, #13)
struct NowNextCard: View {
    @ObservedObject var cal: CalendarModel
    /// 랩 허브만 — 카드 끝 캡션 한 줄 (0.40.0 C2, A1)
    var caption = false
    @Environment(\.cardStyle) private var cs
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(HubCardTitle.title("nownext")).font(.hub(cs.aux, weight: .bold)).foregroundStyle(Hub.text2).lineLimit(1).fixedSize()
                    .help(HubCardTitle.hint("nownext") ?? "")
                if caption, let f = DataSources.calendarTag(cal) { FreshnessTag(f: f).layoutPriority(-1) }   // 라이브 '갱신 HH:mm' (허브만, 0.40.0 C3)
                Spacer(minLength: 0)
            }
            NowNextLine(cal: cal)
            if caption { Spacer(minLength: 0); SourceCaption(text: CardMetas.nownextCaption(cal)) }
        }
        .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV + 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
    }
}

/// 다가오는 일정 — Notion Schedule & Events 와 CSNL·SLab 캘린더를 합친다 (#13).
/// Schedule & Events 는 일정이지 마감이 아니다(랩장 2026-10-14) — 리마인더는 RemindersSection 에서 컨펌한 것만.
struct UpcomingEventsCard: View {
    @ObservedObject var model: NotionHubModel
    var cal: CalendarModel?
    /// 보일 줄 수 (nil 이면 설정값·최소 6). 관제탑은 남은 높이로 계산해 넘긴다
    var maxRows: Int? = nil
    /// 오늘 분 제외 — 관제탑 레일은 경보 열 '오늘 남은 일정' 과 겹치지 않게 내일부터 (R2-02)
    var excludeToday = false
    /// 랩 허브만 — 오늘·내일만 보이고 나머지는 '▸ 더 보기' (0.37.0 C2, HubNear.events)
    var nearOnly = false

    struct Item: Identifiable {
        let id: String; let date: Date; let hasTime: Bool; let title: String; let source: String; let type: String
        let notionID: String?
    }

    var body: some View {
        if let cal { Observed(model: model, cal: cal, maxRows: maxRows, excludeToday: excludeToday, nearOnly: nearOnly) } else { Inner(model: model, cal: nil, maxRows: maxRows, excludeToday: excludeToday, nearOnly: nearOnly) }
    }

    /// Notion Schedule & Events + CSNL·SLab 캘린더(겹치면 하나), 날짜순 — 카드와 text.txt [허브 카드] 가 같이 쓴다
    @MainActor
    static func items(model: NotionHubModel, cal: CalendarModel?, excludeToday: Bool) -> [Item] {
        let c = Calendar.current
        let notion = model.visibleEvents.filter { !excludeToday || !c.isDate($0.date, inSameDayAs: model.now) }
        var out: [Item] = notion.map {
            Item(id: $0.id, date: $0.date, hasTime: $0.hasTime, title: model.displayTitle(forEvent: $0), source: "Notion", type: $0.type, notionID: $0.id)
        }
        var keys = Set(model.visibleEvents.map { Hub.eventKey($0.title, $0.date) })
        if let cal {
            let hidden = model.cfg.display.hideEventTypes.map { $0.lowercased() }
            for e in cal.upcoming(days: model.cfg.eventsDays) where e.end > model.now && !(excludeToday && c.isDate(e.start, inSameDayAs: model.now)) {
                let lower = e.title.lowercased()
                if hidden.contains(where: { lower.hasPrefix($0) }) { continue }    // GRM 은 위 카드에
                guard keys.insert(Hub.eventKey(e.title, e.start)).inserted else { continue }
                let src = e.calendarName.localizedCaseInsensitiveContains("slab") ? "SLab" : "CSNL"
                out.append(Item(id: "cal-" + e.id + "\(e.start.timeIntervalSince1970)", date: e.start, hasTime: !e.isAllDay,
                                title: Hub.canonicalNames(e.title), source: src, type: "", notionID: nil))
            }
        }
        return out.sorted { $0.date < $1.date }
    }

    /// 캘린더 모델이 갱신될 때도 다시 그리도록
    private struct Observed: View {
        @ObservedObject var model: NotionHubModel
        @ObservedObject var cal: CalendarModel
        let maxRows: Int?
        let excludeToday: Bool
        let nearOnly: Bool
        var body: some View { Inner(model: model, cal: cal, maxRows: maxRows, excludeToday: excludeToday, nearOnly: nearOnly) }
    }

    private struct Inner: View {
        @ObservedObject var model: NotionHubModel
        let cal: CalendarModel?
        let maxRows: Int?
        let excludeToday: Bool
        let nearOnly: Bool
        @Environment(\.cardStyle) private var cs
        @ObservedObject private var expansion = HubExpansion.shared
        @ObservedObject private var fill = HubFill.shared

        init(model: NotionHubModel, cal: CalendarModel?, maxRows: Int?, excludeToday: Bool, nearOnly: Bool) {
            self.model = model; self.cal = cal; self.maxRows = maxRows; self.excludeToday = excludeToday; self.nearOnly = nearOnly
        }

        var body: some View {
            let all = UpcomingEventsCard.items(model: model, cal: cal, excludeToday: excludeToday)
            let cut = nearOnly ? HubNear.events(model, items: all, maxRows: maxRows ?? 8) : nil
            let isOpen = expansion.isOpen("events")
            let e = fill.extra["events"] ?? 0
            let rows = cut.map { $0.shown(open: isOpen, extra: e) } ?? Array(all.prefix(maxRows ?? max(model.cfg.eventsMaxRows, 6)))
            // 채움(HubFill)으로 내일 뒤 행이 더해지면 '오늘·내일' 이 거짓말이 되므로 '~M.d'(보인 마지막 행 날짜) (0.38.0 C3)
            let filledTo = cut.flatMap { c in !isOpen && rows.count > c.near.count ? rows.last.map { "~" + Hub.shortDay($0.date) } : nil }
            VStack(alignment: .leading, spacing: cs.gap) {
                HStack(spacing: 6) {
                    // 범위 글(내일부터 n일 · 오늘·내일 · ~M.d · n일)은 도움말로 (0.42.0 C3, R9-a) — 같은 계산
                    SectionTitle(card: "events", hint: "범위: " + (excludeToday ? "내일부터 \(model.cfg.eventsDays)일"
                                 : (nearOnly && !isOpen ? (filledTo ?? "오늘·내일") : "\(model.cfg.eventsDays)일")) + " — Notion Schedule + CSNL·SLab 캘린더, GRM 제외",
                                 fresh: nearOnly ? model.cardTag("events") : nil)
                    Spacer(minLength: 0)
                    // 허브(큰 글자)는 행마다 출처 꼬리표가 있어 머리 설명을 뺀다 — 좁은 열에서 제목과 겹치지 않게
                    if !nearOnly { Text("Notion Schedule + CSNL·SLab 캘린더 · GRM 제외").font(.hub(cs.tag - 0.5)).foregroundStyle(Hub.text3).lineLimit(1) }
                }
                VStack(spacing: 0) {
                    if rows.isEmpty {
                        // Notion 조회 중이거나 캘린더 첫 조회 전 (0.37.0 C6)
                        Text(model.loading || cal?.isSettled == false ? "불러오는 중…" : "GRM 외 예정된 일정 없음").font(.hub(cs.body)).foregroundStyle(Hub.text2).padding(cs.empty).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, e in
                        let past = e.hasTime && e.date.addingTimeInterval(3600) < model.now
                        Button { open(e) } label: {
                            HStack(spacing: 8) {
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text(Hub.day(e.date)).font(.hub(cs.aux, weight: .semibold, design: .rounded)).foregroundStyle(Hub.text2).monospacedDigit()
                                    if e.hasTime { Text(Hub.time(e.date)).font(.hub(cs.aux - 0.5)).foregroundStyle(Hub.text2).monospacedDigit() }
                                }
                                .frame(width: cs.col(Hub.dateColumn + 36), alignment: .leading)
                                Text(e.title).font(.hub(cs.body, weight: .medium)).lineLimit(1)
                                Spacer()
                                if !e.type.isEmpty { TypePill(text: e.type) }
                                Text(e.source).font(.hub(cs.tag - 0.5, weight: .semibold)).foregroundStyle(Hub.text3)
                            }
                            .opacity(past ? 0.45 : 1)
                            .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(e.notionID == nil ? "\(e.source) 캘린더 일정 · 클릭하면 Google 캘린더" : "Notion Schedule & Events")
                        if i < rows.count - 1 { RowDivider() }
                    }
                    // Notion 행만 있고 캘린더는 아직 — 끝난 목록처럼 보이지 않게 한 줄 (0.37.0 C6 검증 1)
                    if !rows.isEmpty, cal?.isSettled == false {
                        RowDivider()
                        Text("캘린더 불러오는 중…").font(.hub(cs.aux)).foregroundStyle(Hub.text2)
                            .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // 허브 접힘은 '▸ 더 보기' 가 맡고, 펼친 뒤에도 남는 것은 Notion 으로 ('+n건 더')
                    if all.count > rows.count && (cut == nil || isOpen) {
                        Button { model.openInApp(id: model.cfg.eventsDB) } label: {
                            Text("+\(all.count - rows.count)건 더").font(.hub(cs.aux - 0.5)).foregroundStyle(Hub.text2).padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
                        }.buttonStyle(.plain)
                    }
                    if let cut { CardFooter(caption: CardMetas.caption("events", model), toggleKey: "events", more: cut.toggleCount(open: isOpen, extra: e)) }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }

        private func open(_ e: Item) {
            if let n = e.notionID { model.openInApp(id: n); return }
            let c = Calendar.current.dateComponents([.year, .month, .day], from: e.date)
            if let y = c.year, let m = c.month, let d = c.day, let u = URL(string: "https://calendar.google.com/calendar/r/day/\(y)/\(m)/\(d)") { NSWorkspace.shared.open(u) }
        }
    }
}

/// 'CSNL GRM' 탭 — 발표 순번 (랩장 2026-10-14 #18: 이 탭은 순번을 알기 위한 것)
struct GRMOrderView: View {
    @ObservedObject var model: NotionHubModel
    let notionURL: URL?
    /// 전체 지도(GRM 주간 뷰 — 기본) · 한 줄(위젯 'CSNL GRM' 탭, 0.41.0 C6 R2 — '지난 GRM 을 너무 확대할 필요 없음')
    var mapDetail = true

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text("GRM 발표 순번").font(.hub(16, weight: .bold))
                    Text("GRM Schedule · 예정 발표자 순서").font(.hub(11.5)).foregroundStyle(Hub.text3)
                    Spacer()
                    if let u = notionURL {
                        Button { NotionLink.open(url: u) } label: { Label("Notion 에서 열기", systemImage: "arrow.up.forward.app").font(.hub(12)) }
                            .buttonStyle(.plain).foregroundStyle(Hub.text2)
                    }
                }
                // 0.43.0 C5 (#50, R7): 일정 왼쪽 · 로테이션 오른쪽 — 두 제목이 같은 높이. 좁으면 위아래(일정이 위)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        schedule.frame(minWidth: Hub.s(340), maxWidth: .infinity, alignment: .topLeading)
                        rotation.fixedSize(horizontal: true, vertical: false)
                    }
                    .layoutChoice(mapDetail ? "grm-week" : "grm-tab", "2열")
                    VStack(alignment: .leading, spacing: 14) {
                        schedule
                        rotation
                    }
                    .layoutChoice(mapDetail ? "grm-week" : "grm-tab", "1열")
                }
                // 지난 회차 자료 — 점 행렬 (0.40.0 C6, A6)은 GRM 주간 뷰에만, 'CSNL GRM' 탭은 이번 주·지난주 한 줄 (0.41.0 C6)
                if mapDetail { GRMMapView(model: model) } else { GRMMapSummaryLine(model: model) }
            }
            .padding(16)
        }
    }

    /// 로테이션 순서 — GRM Schedule 의 예정 발표자가 나오는 순서(실제 순환), 다음 발표자부터 한 바퀴.
    /// Members 의 'Rotation order' 는 실제 순환과 달라(BHL R1 10-15) 예정 일정이 없을 때만 쓴다.
    /// 0.40.0 C6 (A6): 칩 대신 4열 표 — 순번 | 이름(이니셜) | 지난 GRM n일 전 | 다음 M.d. 횟수 열은 두지 않는다(D8 — 공개 일정이라도 순위로 읽힌다)
    private var rotation: some View {
        let fromSchedule = Self.cycle(model.grm.filter { $0.date >= model.today }, members: model.members)
        let source = fromSchedule.count >= 3 ? "GRM Schedule 예정 순서" : "Members · Rotation order"
        let rows = GRMRotation.rows(model)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("로테이션 순서").font(.hub(12, weight: .bold)).foregroundStyle(Hub.text2)
                Text(source).font(.hub(11)).foregroundStyle(Hub.text3)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
                GridRow {
                    Text("순번"); Text("이름"); Text("지난 GRM"); Text("다음")
                }
                .font(.hub(11, weight: .semibold)).foregroundStyle(Hub.text3)
                .padding(.vertical, 4)
                ForEach(rows, id: \.member.id) { r in rotationRow(r) }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
        }
    }

    private func rotationRow(_ r: GRMRotation) -> some View {
        let fg: Color = r.isNext ? Hub.onAccent : Hub.text
        return GridRow {
            Text("\(r.order)").font(.hub(11, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(r.isNext ? Hub.onAccent.opacity(0.85) : Hub.text3)
            Text(r.member.name.isEmpty ? r.initials : "\(r.member.name) (\(r.initials))").font(.hub(13, weight: .semibold)).foregroundStyle(fg).lineLimit(1)
            Text(r.last).font(.hub(12)).monospacedDigit().foregroundStyle(r.isNext ? Hub.onAccent : Hub.text2)
            Text(r.next).font(.hub(12, weight: r.isNext ? .bold : .regular)).monospacedDigit().foregroundStyle(r.isNext ? Hub.onAccent : Hub.text2)
        }
        .padding(.vertical, 5)
        .background(r.isNext ? RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Hub.ink).padding(.horizontal, -6) : nil)
        .help(r.isNext ? "다음 GRM 발표 · Members 페이지" : r.initials + " · Members 페이지")
        .link(.notion(r.member.id))
    }

    /// 예정 GRM(일반 GRM 우선, 모자라면 Focus 포함)의 발표자를 처음 나온 순서대로 — 같은 사람이 다시 나오면 한 바퀴 끝
    static func cycle(_ upcoming: [GRMSlot], members: [Member]) -> [Member] {
        func names(_ slots: [GRMSlot]) -> [String] {
            var out: [String] = []
            for g in slots.sorted(by: { $0.date < $1.date }) {
                for raw in g.presenters.components(separatedBy: ",") {
                    let n = raw.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { continue }
                    if out.contains(n) { return out }   // 한 바퀴 돌아 처음 사람이 다시 나옴
                    out.append(n)
                }
            }
            return out
        }
        var ns = names(upcoming.filter { $0.type == "GRM" })
        if ns.count < 3 { ns = names(upcoming) }
        return ns.compactMap { n in members.first { $0.name == n || $0.initials == n } ?? members.first { n.contains($0.name) } }
    }

    /// 지난 한 번 + 앞으로의 GRM 일정 — GRMSchedule.rows(같은 회차 한 번, 같은 날·발표자·Type 하나로, 0.43.2 C1 #54)
    private var schedule: some View {
        let rows = GRMSchedule.rows(model.grm, today: model.today, now: model.now).rows
        let nextKey = model.nextGRM.map(GRMSchedule.key)
        return VStack(alignment: .leading, spacing: 6) {
            Text("일정").font(.hub(12, weight: .bold)).foregroundStyle(Hub.text2)
            VStack(spacing: 0) {
                if rows.isEmpty {
                    Text(model.loading ? "불러오는 중…" : "GRM Schedule 에 예정된 순번 없음").font(.hub(13)).foregroundStyle(Hub.text2)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, g in
                    let isPast = g.date < model.today
                    let isNext = GRMSchedule.key(g) == nextKey   // 합친 행의 id 가 nextGRM 과 달라도 강조
                    HStack(spacing: 10) {
                        Text(Hub.day(g.date)).font(.hub(13, weight: .semibold, design: .rounded)).monospacedDigit().frame(width: Hub.s(52), alignment: .leading)
                        Text(isPast ? "지난" : Hub.dday(g.date)).font(.hub(11, weight: .bold)).monospacedDigit()
                            .foregroundStyle(isNext ? Hub.onAccent : Hub.text2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(isNext ? Hub.ink : Color.clear))
                            .frame(width: Hub.s(56), alignment: .leading)
                        TypePill(text: g.type)
                        Text(g.presenters.isEmpty ? "발표자 미정" : g.presenters).font(.hub(14, weight: isNext ? .bold : .medium)).lineLimit(1)
                        Spacer()
                        if !isPast {
                            Label("공지", systemImage: g.notified ? "checkmark.circle.fill" : "circle").font(.hub(11)).foregroundStyle(g.notified ? Hub.ok : Hub.text3)
                            Label("초록", systemImage: g.abstractDone ? "checkmark.circle.fill" : "circle").font(.hub(11)).foregroundStyle(g.abstractDone ? Hub.ok : Hub.text3)
                        }
                    }
                    .opacity(isPast ? 0.5 : 1)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .contentShape(Rectangle())
                    .onTapGesture { model.openInApp(id: g.id) }
                    if i < rows.count - 1 { RowDivider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
        }
    }
}
