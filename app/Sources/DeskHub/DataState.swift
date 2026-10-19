import SwiftUI
import AppKit

// MARK: - 자료 신뢰도 (0.40.0 C3, A2 — 수렴 문서 §3-2 A2, 정의서 A2-*)
// '이 숫자를 믿어도 되나? 어디서 고치나?' — 카드 머리마다 내용 날짜 꼬리표, 관제탑 '자료 상태' 레일(원천 정렬 표 + 위생 목록).
// 앱이 직접 아는 원천(논문 추천·회의록·PB·GRM·리마인더·그랜트·학회 파일·MM)은 라이브 값을 먼저, 나머지는 집계(latest.json, 이 맥 전용).
// 적색은 쓰지 않는다 — 멈춤은 굵은 Hub.text, 지연·정상은 Hub.text2.

/// 원천 한 줄 — 정렬 표의 행
struct DataRow: Identifiable {
    let id: String
    let label: String
    let cycle: Int
    let cards: [String]
    let content: Date?
    let judge: ProducerRule.Judge?
    /// 내용 날짜가 없을 때의 이유 — '집계 없음' · 오류 코드 · '—'
    let note: String
    let live: Bool
}

/// 위생 한 줄 — '135 · SLab 날짜 지난 확정 · 고치러 가기 ↗'. link 는 Notion DB 만(검증 1) — DB 가 없는 항목(그랜트 마감 공란 = NAS grants_schedule.json)은
/// 링크 없이 고칠 곳(where)을 글로 적는다
struct HygieneLine: Identifiable {
    let id: String; let label: String; let n: Int; let of: Int?; let link: HubLink?
    var where_: String = ""
    var count: String { of.map { "\(n)/\($0)" } ?? "\(n)" }
}

enum DataSources {
    /// 원천 목록 — scripts/aggregate_daily.py SOURCES 와 같은 id·라벨·기대 주기(D6 'JOP 기본값 · 10-17')·영향 카드
    static let catalog: [(id: String, label: String, cycle: Int, cards: [String])] = [
        ("grm", "GRM Schedule", 7, ["grm", "nownext"]), ("minutes", "Meeting Notes", 7, ["minutes"]),
        ("blitz_archive", "Paper Blitz Archive", 7, ["blitz"]), ("paperrec", "논문 추천(paperRec)", 7, ["papers"]),
        ("slab", "SLab", 7, ["experiments"]), ("ics_slab", "SLab 캘린더", 7, ["experiments"]), ("prolific", "Prolific", 7, ["experiments"]),
        ("nas_grm", "NAS GRM 회차 폴더", 7, ["grm"]), ("nas_transcript", "NAS GRM 녹취", 7, ["minutes"]),
        ("paperblitz_json", "PaperBlitz.json", 7, ["blitz"]),
        ("members", "Members", 30, ["members"]), ("projects", "Projects", 30, ["members"]), ("project_people", "Project People", 30, ["experiments"]),
        ("resource", "Resource", 30, ["equipment"]), ("presentations", "Presentations", 30, ["members"]), ("nas_mm", "NAS MM", 30, ["members"]),
        ("ssot_conferences", "conferences_upcoming.json", 30, ["conferences"]), ("ssot_grants", "grants_schedule.json", 30, ["grants"]),
        ("ssot_reminders", "reminders.json", 30, ["reminders"]), ("ssot_latest", "SSOT latest(NAS)", 30, []),
        ("publications", "Publications", 90, ["preprints"]), ("conferences", "Conferences(Notion)", 90, ["conferences"]),
        ("talks", "Talks", 90, []), ("international", "International", 90, []),
    ]
    /// 상태 한 줄 '자료 멈춤' 에서 빼는 원천 — 현장 실험은 따로 적는다(이중 계산 방지, A3-stopped)
    static let slabSources: Set<String> = ["slab", "ics_slab"]

    /// 앱이 직접 아는 원천의 내용 날짜 (없으면 nil → 집계 값)
    @MainActor static func liveContent(_ id: String, _ m: NotionHubModel) -> Date? {
        let today = m.today
        func le(_ ds: [Date]) -> Date? { ds.filter { Calendar.current.startOfDay(for: $0) <= today }.max() }
        switch id {
        case "paperrec": return le(m.papers.compactMap(\.sentAt))
        case "minutes": return le(m.minutes.compactMap(\.date))
        case "blitz_archive": return m.blitzSource == "Notion" ? m.blitzDate : nil
        case "grm": return m.lastGRMContent
        case "ssot_reminders": return le(m.reminders.compactMap { MetricsSnapshot.instant($0.at ?? "") ?? MetricsSnapshot.day($0.at) })
        case "ssot_grants": return le(m.grants.compactMap(\.checkedAt))
        case "ssot_conferences": return m.conferencesGenerated
        case "nas_mm": return le((m.milestones ?? [:]).values.filter(\.fromName).map(\.date))
        case "resource": return m.equipmentContent
        default: return nil
        }
    }

    /// 정렬 표 — 경과일 내림차순(내용 날짜 없는 행은 끝, 라벨 순). 집계가 없어도 라이브 원천은 값이 있다
    @MainActor static func rows(_ m: NotionHubModel, today: Date) -> [DataRow] {
        let snap = m.metrics
        let out = catalog.map { c -> DataRow in
            let live = liveContent(c.id, m)
            let src = snap?.source(c.id)
            let content = live ?? src?.contentDate
            let note = content != nil ? "" : (snap == nil ? "집계 없음" : (src?.error ?? "—"))
            return DataRow(id: c.id, label: c.label, cycle: c.cycle, cards: c.cards, content: content,
                           judge: ProducerRule.judge(content: content, today: today, cycleDays: c.cycle), note: note, live: live != nil)
        }
        return out.sorted { a, b in
            switch (a.judge, b.judge) {
            case let (x?, y?): return x.age != y.age ? x.age > y.age : a.label < b.label
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.label < b.label
            }
        }
    }
    @MainActor static func counts(_ m: NotionHubModel) -> (stopped: Int, late: Int) {
        let r = rows(m, today: m.today)
        return (r.filter { $0.judge?.kind == .stopped }.count, r.filter { $0.judge?.kind == .late }.count)
    }

    /// 위생 목록 — n=0 은 사라진다. 장비 '닫기 누락' 은 앱 실측(장비 카드)이 있으면 그 값. 링크 = Notion DB 만.
    /// DB 가 없는 항목(그랜트 마감 공란)은 링크 없이 'NAS <파일 이름>에서 고침' — 수용 기준 '링크는 모두 notion' (검증 1)
    @MainActor static func hygiene(_ m: NotionHubModel) -> [HygieneLine] {
        let grantsName = (m.cfg.grantsFile as NSString).lastPathComponent
        return (m.metrics?.hygiene ?? []).compactMap { h -> HygieneLine? in
            var n = h.n
            if h.id == "resource-running-overdue", let live = m.equipmentOverdueCount { n = live }
            guard n > 0 else { return nil }
            if h.db.isEmpty { return HygieneLine(id: h.id, label: h.label, n: n, of: h.of, link: nil, where_: "NAS \(grantsName)에서 고침") }
            return HygieneLine(id: h.id, label: h.label, n: n, of: h.of, link: .notion(h.db))
        }
    }
    static let hygieneLimit = 7

    /// 집계가 26시간 넘게 늦으면 그 시간 (HubClock 기준 — DESKHUB_NOW 와 같은 달력)
    @MainActor static func delayHours(_ m: NotionHubModel) -> Int? {
        guard let a = m.metrics?.asOf else { return nil }
        let h = MetricDefs.asofHours(asOf: a, now: HubClock.now)
        return h > MetricDefs.asofLimitHours ? h : nil
    }
    static func asOfText(_ d: Date?) -> String {
        guard let d else { return "없음" }
        let f = DateFormatter(); f.dateFormat = "M.d HH:mm"
        return f.string(from: d) + " (이 맥 전용)"
    }
    /// 관제탑 접힌 줄 — '멈춤 n · 지연 n · 집계 M.d HH:mm (이 맥 전용)' / '… · 집계 없음'
    @MainActor static func summary(_ m: NotionHubModel) -> String {
        let c = counts(m)
        return "멈춤 \(c.stopped) · 지연 \(c.late) · 집계 " + asOfText(m.metrics?.asOf)
    }

    /// 캘린더(라이브) 꼬리표 — '갱신 HH:mm'
    @MainActor static func calendarTag(_ cal: CalendarModel?) -> Freshness? {
        guard let cal else { return nil }
        if !cal.isSettled { return Freshness(state: .pending, text: "불러오는 중", help: "캘린더 첫 조회 전") }
        return Freshness.live(cal.lastUpdated, help: "라이브 원천 — CSNL·SLab 캘린더 마지막 조회 (5분 주기)")
    }

    // MARK: 덤프

    /// text.txt [꼬리표] — 허브 데이터 카드 14 + 관제탑 레일 데이터 항목 10: '<id> · <글|—> · fresh|stale|pending|—'
    @MainActor static func tagDumpLines(_ m: NotionHubModel) -> [String] {
        func line(_ key: String, _ f: Freshness?) -> String {
            let st: String = f.map { $0.state == .fresh ? "fresh" : ($0.state == .stale ? "stale" : "pending") } ?? "—"
            return "\(key) · \(f?.text ?? "—") · \(st)"
        }
        let hub = CardMetas.hub.map { ($0, m.cardTag($0)) }
        let tower = TowerView.railDataItems.map { ("tower:" + $0, m.cardTag($0)) }
        return ["허브 \(hub.filter { $0.1 != nil }.count)/\(hub.count) · 관제탑 레일 \(tower.filter { $0.1 != nil }.count)/\(tower.count)"]
            + hub.map { line($0.0, $0.1) } + tower.map { line($0.0, $0.1) }
    }
    /// text.txt [자료 상태] — 머리 줄 + '원천 | 내용 날짜 | 경과일 | ×기대 주기 | 영향 카드' (뷰와 같은 정렬)
    @MainActor static func dumpLines(_ m: NotionHubModel) -> [String] {
        var out = [summary(m) + (delayHours(m).map { " · 집계 \($0)시간 지연" } ?? "") + (m.metricsNote.map { " · " + $0 } ?? "")]
        out.append("원천 | 내용 날짜 | 경과일 | ×기대 주기 | 영향 카드")
        for r in rows(m, today: m.today) { out.append(cells(r).joined(separator: " | ")) }
        return out
    }
    /// text.txt [위생] — 머리 '항목 n · 보임 k' + 보이는 줄 'n · 라벨 · →링크 종류' (링크 없는 항목은 '링크 없음(고칠 곳)')
    @MainActor static func hygieneDumpLines(_ m: NotionHubModel) -> [String] {
        let h = hygiene(m)
        let shown = h.prefix(hygieneLimit)
        return ["항목 \(h.count) · 보임 \(shown.count)" + (h.count > hygieneLimit ? " · +\(h.count - hygieneLimit)" : "")]
            + shown.map { "\($0.count) · \($0.label) · " + ($0.link.map { "→" + $0.kindLabel } ?? "링크 없음(\($0.where_))") }
    }
    /// 표 한 행의 다섯 칸 (뷰·덤프 공용)
    static func cells(_ r: DataRow) -> [String] {
        [r.label, r.content.map(Hub.shortDay) ?? r.note, r.judge.map { "\($0.age)일" } ?? "—",
         r.judge.map { "×" + String(format: "%.1f", $0.ratio) } ?? "—", r.cards.isEmpty ? "—" : r.cards.joined(separator: "·")]
    }
}

extension NotionHubModel {
    /// 카드 머리 꼬리표 (A2-content) — 허브 카드·관제탑 레일 줄·[꼬리표] 덤프가 같은 함수. 없으면 nil('—')
    func cardTag(_ id: String) -> Freshness? {
        let t = today
        switch id {
        case "grm": return Freshness.content(lastGRMContent ?? metrics?.source("grm")?.contentDate, cycle: 7, today: t, help: "지난 GRM 날짜 — 올해 GRM Schedule 전체, 연초 공백이면 집계(연도 무관) (A2-src-grm)")
        case "nownext", "events": return DataSources.calendarTag(todayCalendar)
        case "members":
            if let d = metrics?.source("members")?.editedMax { return Freshness.content(d, cycle: 30, today: t, help: "Members 편집 시각(집계, 날짜 필드 없음)") }
            return Freshness.live(lastUpdated, help: "Notion 마지막 조회")
        case "papers": return papersFreshness
        case "preprints":
            return Freshness.content(preprints.compactMap(\.date).filter { Calendar.current.startOfDay(for: $0) <= t }.max(), cycle: 90, today: t, help: "가장 최근 원고 날짜(OpenAlex)")
                ?? Freshness.live(preprintsAt, help: "OpenAlex 마지막 조회 — 날짜 있는 원고 없음")
        case "apps": return Freshness.content(CardMetas.appsFileDate, cycle: 30, today: t, help: "apps.json 수정일")
        case "reminders":
            return Freshness.content(reminders.compactMap { MetricsSnapshot.instant($0.at ?? "") ?? MetricsSnapshot.day($0.at) }.max(), cycle: 30, today: t,
                                     help: "리마인더 마지막 변경(at)")
        case "experiments": return Freshness.content(metrics?.slabLast, cycle: 7, today: t, help: "SLab 마지막 실험날짜(집계, 이 맥 전용)")
        case "equipment": return Freshness.content(equipmentContent ?? metrics?.source("resource")?.contentDate, cycle: 30, today: t, help: "오늘 이하 예약 시작일 최댓값")
        case "grants": return Freshness.content(grants.compactMap(\.checkedAt).max(), cycle: 30, today: t, help: "그랜트 날짜 마지막 확인(checkedAt)")
        case "minutes": return minutesFreshness
        case "blitz": return blitzFreshness
        case "conferences": return Freshness.content(conferencesGenerated, cycle: 30, today: t, help: "conferences_upcoming.json 생성일")
        default: return nil
        }
    }
    func cardTagText(_ id: String) -> String? { cardTag(id)?.text }
}

// MARK: - 관제탑 '자료 상태' 레일 펼침

/// 위생(고치면 사라짐)을 표 위에 — 표가 길어 카드 안에서 스크롤해도 위생은 첫 화면에 보인다 (검증 1).
/// 표는 배율 안전(검증 1, 1.3×에서 '영향 카드' 열이 잘림): 넓으면 5열(열 너비 = 가장 긴 칸, Grid), 좁으면 4열 + 영향 카드는 원천 아래 둘째 줄.
/// 원천 칸은 남은 너비를 받고 넘치면 말줄임 + 도움말(전체 이름)
struct DataStateRail: View {
    @ObservedObject var model: NotionHubModel
    private var wDate: CGFloat { Hub.s(64) }
    private var wNum: CGFloat { Hub.s(44) }
    /// 화면 머리 — 덤프(dumpLines)는 '×기대 주기' 그대로, 화면은 짧게(도움말에 뜻)
    static let viewHead = ["원천", "내용 날짜", "경과일", "×주기", "영향 카드"]
    static let ratioHelp = "×주기 = 경과일 ÷ 기대 주기 — 2 를 넘으면 멈춤(굵게)"

    var body: some View {
        let rows = DataSources.rows(model, today: model.today)
        let hyg = DataSources.hygiene(model)
        VStack(alignment: .leading, spacing: 8) {
            if let h = DataSources.delayHours(model) {
                Text("집계 \(h)시간 지연").font(.hub(12, weight: .semibold)).foregroundStyle(Hub.text2)
                    .help("latest.json 이 26시간 넘게 갱신되지 않음 — 세션 사이클이 하루 1회 scripts/aggregate_daily.py 를 부른다")
            }
            if model.metrics == nil {
                Text((model.metricsNote ?? "집계 없음") + " — 집계 원천은 '집계 없음'. 이 맥에서 하루 1회 scripts/aggregate_daily.py")
                    .font(.hub(11.5)).foregroundStyle(Hub.text2).fixedSize(horizontal: false, vertical: true)
            }
            if !hyg.isEmpty { hygiene(hyg) }
            ViewThatFits(in: .horizontal) {
                wide(rows)
                narrow(rows)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Hub.surface))
            SourceCaption(text: MetricDefs.caption(source: "집계 latest.json", basis: DataSources.asOfText(model.metrics?.asOf), n: "\(rows.count)", id: "A2-stopped"))
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
    }

    private func hygiene(_ hyg: [HygieneLine]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("위생 · 고치면 사라집니다").font(.hub(12, weight: .bold)).foregroundStyle(Hub.text2)
            ForEach(hyg.prefix(DataSources.hygieneLimit)) { h in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(h.count).font(.hub(12, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(Hub.text).fixedSize()
                    Text("· " + h.label).font(.hub(12)).foregroundStyle(Hub.text2).lineLimit(1).truncationMode(.tail).help(h.label)
                    if h.link != nil {
                        Text("· 고치러 가기 ↗").font(.hub(12, weight: .semibold)).foregroundStyle(Hub.ink).fixedSize()
                    } else if !h.where_.isEmpty {
                        Text("· " + h.where_).font(.hub(11.5)).foregroundStyle(Hub.text3).lineLimit(1).truncationMode(.middle).help(h.where_)
                    }
                    Spacer(minLength: 0)
                }
                .link(h.link)
            }
            if hyg.count > DataSources.hygieneLimit {
                Text("+\(hyg.count - DataSources.hygieneLimit)").font(.hub(11.5)).foregroundStyle(Hub.text3)
            }
        }
    }

    private func font(head: Bool, strong: Bool) -> Font { .hub(head ? 11 : 12, weight: head ? .semibold : (strong ? .bold : .regular)) }
    private func color(head: Bool, strong: Bool) -> Color { head ? Hub.text3 : (strong ? Hub.text : Hub.text2) }
    private func rowHelp(_ r: DataRow) -> String {
        var parts: [String] = [r.label, "기대 주기 \(r.cycle)일", r.live ? "앱 라이브 값" : "집계"]
        if let j = r.judge { parts.append(ProducerRule.label(j)) }
        if !r.cards.isEmpty { parts.append("영향 카드 " + r.cards.joined(separator: "·")) }
        return parts.joined(separator: " · ")
    }

    /// 넓은 레일(세로 1열 등) — 5열 Grid, 칸은 줄이지 않는다(fixedSize). 넓이가 모자라면 ViewThatFits 가 narrow 를 고른다.
    /// GridRow 에 수식어를 달면 한 칸으로 합쳐지므로 칸마다 단다
    private func wide(_ rows: [DataRow]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<5, id: \.self) { i in
                    cell(Self.viewHead[i], head: true, strong: false)
                        .gridColumnAlignment(i == 2 || i == 3 ? .trailing : .leading)
                        .help(i == 3 ? Self.ratioHelp : Self.viewHead[i])
                }
            }
            RowDivider().gridCellUnsizedAxes(.horizontal)
            ForEach(rows) { r in
                let c = DataSources.cells(r), strong = r.judge?.kind == .stopped, help = rowHelp(r)
                GridRow {
                    ForEach(0..<5, id: \.self) { i in cell(c[i], head: false, strong: strong).help(help) }
                }
                RowDivider().gridCellUnsizedAxes(.horizontal)
            }
        }
        .padding(.horizontal, 8)
    }
    private func cell(_ t: String, head: Bool, strong: Bool) -> some View {
        Text(t).font(font(head: head, strong: strong)).monospacedDigit().foregroundStyle(color(head: head, strong: strong))
            .lineLimit(1).fixedSize().padding(.vertical, 3)
    }

    /// 좁은 레일(가로 2열·1.3× 이상) — 4열(원천 | 내용 날짜 | 경과일 | ×주기), 영향 카드는 원천 아래 작은 둘째 줄.
    /// 숫자 칸은 고정 너비(Hub.s), 원천 칸이 남은 너비 — 말줄임은 원천 칸에서만
    private func narrow(_ rows: [DataRow]) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("원천 · 영향 카드").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text("내용 날짜").lineLimit(1).minimumScaleFactor(0.8).frame(width: wDate, alignment: .leading)
                Text("경과일").lineLimit(1).frame(width: wNum, alignment: .trailing)
                Text("×주기").lineLimit(1).frame(width: wNum, alignment: .trailing).help(Self.ratioHelp)
            }
            .font(font(head: true, strong: false)).foregroundStyle(color(head: true, strong: false))
            .padding(.horizontal, 8).padding(.vertical, 3)
            RowDivider()
            ForEach(rows) { r in
                let c = DataSources.cells(r), strong = r.judge?.kind == .stopped
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c[0]).lineLimit(1).truncationMode(.tail)
                        Text(c[4]).font(.hub(10.5)).foregroundStyle(Hub.text3).lineLimit(1).truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(c[1]).lineLimit(1).minimumScaleFactor(0.8).truncationMode(.tail).frame(width: wDate, alignment: .leading)
                    Text(c[2]).lineLimit(1).minimumScaleFactor(0.8).monospacedDigit().frame(width: wNum, alignment: .trailing)
                    Text(c[3]).lineLimit(1).minimumScaleFactor(0.8).monospacedDigit().frame(width: wNum, alignment: .trailing)
                }
                .font(font(head: false, strong: strong)).foregroundStyle(color(head: false, strong: strong))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .help(rowHelp(r))
                RowDivider()
            }
        }
    }
}
