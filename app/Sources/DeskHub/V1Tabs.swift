import SwiftUI
import AppKit

// MARK: - 1.0.0 탭 화면 셋 (A2, #55 — R7·R8) — 일정 · GRM/Blitz · 실험/장비
// HubViewMode rawValue schedule · grmblitz · lab 이 이 화면을 그린다(HubViewSwitch). 위 탭 줄(C 갈래)은 rawValue 로만 부른다(§5 ②).
// 모두 기존 카드 조합 — 새 데이터 읽기 없음. 적색은 그랜트 마감 D≤3 한 곳뿐(학회 열은 quiet = ink).

/// 일정 탭 — 왼쪽 1/3 오늘 캘린더 · 가운데 학회(Conferences) · 오른쪽 Grant 일정
struct ScheduleTabView: View {
    @ObservedObject var model: NotionHubModel

    var body: some View {
        GeometryReader { geo in
            let gap = HubSpace.column
            let cols = Self.columns(width: geo.size.width, scale: HubDisplay.scale)
            let inner = max(0, geo.size.width - HubSpace.outer * 2 - gap * CGFloat(cols - 1))
            let leftW = (inner / CGFloat(cols)).rounded()
            Group {
                switch cols {
                case 3:
                    HStack(alignment: .top, spacing: gap) {
                        todayColumn
                            .frame(width: leftW)
                            .frame(maxHeight: .infinity, alignment: .top)
                        ScrollView(.vertical) {
                            ConferencesCard(model: model, maxRows: 99, quiet: true, wrap: true)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        GrantScheduleColumn(model: model)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    .layoutChoice("schedule-cols", "3열")
                case 2:
                    // 캘린더 | 학회+그랜트 세로 쌓기 — 열이 좁아 장소가 한 글자씩 꺾이던 것 (1.0.0 검증 2, 2.0배)
                    HStack(alignment: .top, spacing: gap) {
                        todayColumn
                            .frame(width: leftW)
                            .frame(maxHeight: .infinity, alignment: .top)
                        ScrollView(.vertical) { stacked }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    .layoutChoice("schedule-cols", "2열")
                default:
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: HubSpace.card) {
                            todayColumn.frame(height: max(Hub.s(420), geo.size.height * 0.7))
                            stacked
                        }
                    }
                    .layoutChoice("schedule-cols", "1열")
                }
            }
            .padding(HubSpace.outer)
            .onAppear { Self.recordLeft(leftW, geo.size.width) }
            .onChange(of: geo.size.width) { _, w in
                let n = Self.columns(width: w, scale: HubDisplay.scale)
                Self.recordLeft(((max(0, w - HubSpace.outer * 2 - gap * CGFloat(n - 1))) / CGFloat(n)).rounded(), w)
            }
        }
        .environment(\.cardStyle, .large)
    }

    /// 학회 + 그랜트 위아래 (2열 오른쪽·1열) — 바깥 ScrollView 하나만 쓴다
    private var stacked: some View {
        VStack(alignment: .leading, spacing: HubSpace.card) {
            ConferencesCard(model: model, maxRows: 99, quiet: true, wrap: true)
                .fixedSize(horizontal: false, vertical: true)
            GrantScheduleColumn(model: model, scrolls: false)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 열 수 — 3열 열 폭이 Hub.s(260) 보다 좁거나 배율 1.8 이상이면 2열, 2열 폭도 좁으면 1열 (1.0.0 검증 2: 2.0배에서 '…'·한 글자 줄바꿈)
    static func columns(width: CGFloat, scale: CGFloat) -> Int {
        let minW = (260 * scale).rounded()
        let avail = width - HubSpace.outer * 2
        let w3 = (avail - HubSpace.column * 2) / 3, w2 = (avail - HubSpace.column) / 2
        if scale < 1.8 && w3 >= minW { return 3 }
        return w2 >= minW ? 2 : 1
    }

    /// windows.txt choices 'schedule-left <왼쪽 열 폭 / 창 폭>'
    private static func recordLeft(_ left: CGFloat, _ total: CGFloat) {
        guard total > 0 else { return }
        LayoutChoice.record("schedule-left", String(format: "%.2f", Double(left / total)))
    }

    @ViewBuilder private var todayColumn: some View {
        if let cal = model.todayCalendar {
            TodayView(cal: cal)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
        } else {
            Text("캘린더가 연결되지 않았습니다")
                .font(.hub(15)).foregroundStyle(Hub.text2)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// text.txt '[일정 탭] 캘린더 <상태> · 학회 n · 그랜트 n'
    @MainActor static func dumpLine(_ m: NotionHubModel) -> String {
        let calState: String
        if let c = m.todayCalendar {
            calState = !c.isSettled ? "불러오는 중" : (c.status == .noSource || c.status == .denied ? "읽지 못함" : "일정 \(c.events.count + c.allDay.count)개")
        } else { calState = "없음" }
        return "[일정 탭] 캘린더 \(calState) · 학회 \(m.conferences.count) · 그랜트 \(m.grants.count)"
    }
}

/// Grant 일정 — 순수 함수 (뷰·덤프 공용)
enum GrantSchedule {
    /// 종류 칩 — 과제가 끝났으면 '결과보고'
    static func kind(_ g: GrantRow, today: Date) -> String { g.isEnded(today: today) ? "결과보고" : g.kind }

    /// 기간 글 — dueNote 의 yyyy.M[M]~yyyy.M[M](구분자 ~ – - 허용) → 'yyyy.MM–yyyy.MM', 없으면 ended → '~ yyyy.MM 종료', 없으면 '미기재' (앞의 '기간' 은 부르는 쪽이 붙인다 — 검증 1 '과제 기간 기간 미기재')
    static func period(dueNote: String, ended: Date?) -> String {
        let pattern = #"(\d{4})\s*\.\s*(\d{1,2})\s*[~–\-]\s*(\d{4})\s*\.\s*(\d{1,2})"#
        if let re = try? NSRegularExpression(pattern: pattern),
           let m = re.firstMatch(in: dueNote, range: NSRange(dueNote.startIndex..., in: dueNote)), m.numberOfRanges == 5 {
            let part: (Int) -> String = { i in Range(m.range(at: i), in: dueNote).map { String(dueNote[$0]) } ?? "" }
            let mm: (String) -> String = { s in (Int(s).map { String(format: "%02d", $0) }) ?? s }
            return "\(part(1)).\(mm(part(2)))–\(part(3)).\(mm(part(4)))"
        }
        if let e = ended {
            let c = Calendar.current.dateComponents([.year, .month], from: e)
            return String(format: "~ %04d.%02d 종료", c.year ?? 0, c.month ?? 0)
        }
        return "미기재"
    }
    static func period(_ g: GrantRow) -> String { period(dueNote: g.dueNote, ended: g.ended) }

    /// 'D-n' · '오늘' · '미정' (GrantsSection 과 같은 Hub.dday)
    static func dueLabel(_ g: GrantRow) -> String { g.due.map(Hub.dday) ?? "미정" }

    /// 접수·제출 마감 D≤3 — 적색 조건 (화면당 ≤3, 이 탭의 유일한 적색)
    static func soon(_ g: GrantRow, today: Date) -> Bool {
        g.due.map { (Calendar.current.dateComponents([.day], from: today, to: $0).day ?? 99) <= 3 } ?? false
    }

    /// text.txt '[Grant 일정] n' + 행 '<종류> · <제목 앞 24자> · <D-n|미정> · 기간 <…>'
    @MainActor static func dumpLines(_ m: NotionHubModel) -> [String] {
        ["[Grant 일정] \(m.grants.count)"] + m.grants.map { g in
            [kind(g, today: m.today), String(g.title.prefix(24)), dueLabel(g), "기간 " + period(g)].joined(separator: " · ")
        }
    }
}

/// 일정 탭 오른쪽 열 — 그랜트 행: 종류 칩 · 제목 · D-n|미정 · dueNote · 기간 한 줄
struct GrantScheduleColumn: View {
    @ObservedObject var model: NotionHubModel
    /// false = 바깥 ScrollView 안에 쌓일 때(일정 탭 2열·1열) — 안쪽 스크롤 없음
    var scrolls = true
    @Environment(\.cardStyle) private var cs

    var body: some View {
        VStack(alignment: .leading, spacing: cs.gap) {
            SectionTitle(text: "Grant 일정", trailing: "NAS") {
                NSWorkspace.shared.open(URL(fileURLWithPath: (model.cfg.grantsFile as NSString).deletingLastPathComponent))
            }
            if scrolls { ScrollView(.vertical) { list } } else { list }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            if model.grants.isEmpty {
                Text(FileManager.default.fileExists(atPath: model.cfg.grantsFile) ? "없음" : "NAS 의 그랜트 일정 파일을 읽지 못함")
                    .font(.hub(cs.body)).foregroundStyle(Hub.text2).padding(cs.empty).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(model.grants.enumerated()), id: \.element.id) { i, g in
                row(g)
                if i < model.grants.count - 1 { RowDivider() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
    }

    private func row(_ g: GrantRow) -> some View {
        Button {
            let p = model.cfg.nasGRMRoot.replacingOccurrences(of: "/GRM", with: "") + "/" + g.folder
            if FileManager.default.fileExists(atPath: p) { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                let soon = GrantSchedule.soon(g, today: model.today)
                Text(GrantSchedule.dueLabel(g))
                    .font(.hub(cs.tag, weight: .bold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).fixedSize()
                    .frame(minWidth: cs.col(40), alignment: .leading)
                    .foregroundStyle(soon ? Hub.signal : Hub.text2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        let kind = GrantSchedule.kind(g, today: model.today)
                        Text(kind).font(.hub(cs.tag - 0.5, weight: .bold)).lineLimit(1).fixedSize()
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill((g.kind == "보고" ? Hub.ink : Hub.ok).opacity(0.12)))
                            .foregroundStyle(g.kind == "보고" ? Hub.ink : Hub.ok)
                        Text(g.title).font(.hub(cs.body, weight: .semibold)).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                    }
                    if !g.dueNote.isEmpty || g.due != nil {
                        Text([g.due.map(Hub.day) ?? "", g.dueNote].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.hub(cs.aux)).foregroundStyle(Hub.text2).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("과제 기간 " + GrantSchedule.period(g))
                        .font(.hub(cs.aux, weight: .medium)).foregroundStyle(Hub.text).monospacedDigit()
                        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                    // 일정 미정은 마지막 확인일 — '확인 필요' 도 무채색(적색은 마감 D≤3 만)
                    if g.due == nil {
                        let stale = g.needsCheck(today: model.today)
                        Text((stale ? "확인 필요 · " : "") + "마지막 확인 " + (g.checkedAt.map(Hub.day) ?? "기록 없음"))
                            .font(.hub(cs.tag, weight: stale ? .semibold : .regular))
                            .foregroundStyle(stale ? Hub.text2 : Hub.text3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV + 3).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help([g.agency, g.folder].filter { !$0.isEmpty }.joined(separator: " · "))
    }
}

/// GRM/Blitz 탭 — GRM 발표 순번·일정(위젯 'CSNL GRM' 탭과 같은 한 줄 지도) + 지난 Paper Blitz. 넓으면 2열, 좁으면 위아래
struct GRMBlitzTabView: View {
    @ObservedObject var model: NotionHubModel

    private var grmURL: URL? { model.cfg.tabs.first { $0.title == "CSNL GRM" }.flatMap { URL(string: $0.url) } }

    var body: some View {
        GeometryReader { geo in
            Group {
                if geo.size.width >= Hub.s(760) {
                    HStack(alignment: .top, spacing: HubSpace.column) {
                        grm.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        BlitzCompact(model: model).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    .layoutChoice("grmblitz", "2열")
                } else {
                    VStack(alignment: .leading, spacing: HubSpace.card) {
                        grm.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        BlitzCompact(model: model).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    .layoutChoice("grmblitz", "1열")
                }
            }
            .padding(HubSpace.outer)
        }
        .environment(\.cardStyle, .large)
    }

    private var grm: some View {
        GRMOrderView(model: model, notionURL: grmURL, mapDetail: false)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
    }
}

/// 실험/장비 탭 — 오늘의 실험(전부) + 장비 예약(늘 펼침, 이 맥 펼침 저장값은 건드리지 않음)
struct LabTabView: View {
    @ObservedObject var model: NotionHubModel

    var body: some View {
        HStack(alignment: .top, spacing: HubSpace.column) {
            ScrollView(.vertical) {
                ExperimentsCard(model: model).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            ScrollView(.vertical) {
                EquipmentCard(model: model, forceOpen: true).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(HubSpace.outer)
        .environment(\.cardStyle, .large)
    }
}
