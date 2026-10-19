import SwiftUI
import AppKit

// MARK: - GRM 회차 자료 지도 (0.40.0 C6, A6 — 수렴 문서 §3-2 A6, 정의서 A6-*)
// '그 회차 자료는 어디 있고 내 회차 빈칸은?' — 지난 회차(올해) × 5열(초록 · 슬라이드 · 녹취 · 회의록 · PB) 점 행렬.
// 'CSNL GRM' 탭과 grm 뷰(GRMWeekView 가 GRMOrderView 를 씀) 두 곳에 같이 나온다. 적색 없음.
// 판정은 순수 함수(isSlide·isPB·isTranscript) — 공정 보드 grmStage 와 text-check 'A6-slide' 가 같은 함수.

/// NAS 회차 폴더 목록 결과 (메인 스레드 밖에서 만든다)
struct GRMFolderScan: Sendable {
    struct Info: Sendable { var exists = false; var unknown = false; var slides = false; var pb = false; var transcript = false }
    /// 올해 등 GRM/<yyyy>/<yyyymmdd> 폴더 날짜
    var folders: Set<Date> = []
    var info: [Date: Info] = [:]
    /// NAS GRM/PaperBlitz.json sessions 날짜
    var pbJSON: Set<Date> = []
    var firstTranscript: Date?
    /// 해 폴더(또는 NAS 루트)를 읽지 못한 해 — 그 해 회차는 슬라이드·녹취·PB 를 '?'(판정 불가)로. ○(없음)로 보이면 발표자가 안 올린 것처럼 읽힌다 (리뷰, 검증 1)
    var unreadableYears: Set<Int> = []
    var scannedAt = Date()
}

enum GRMMap {
    enum Mark: String { case yes = "●", no = "○", na = "–", unknown = "?" }
    static let columns = ["초록", "슬라이드", "녹취", "회의록", "PB"]

    // MARK: 판정 (A6-slide · A6-pb · A6-transcript)
    /// 슬라이드 — pptx·key·pdf(.key 패키지 폴더 포함). PB_·~$·Thumbs.db·'.' 시작은 뺀다
    static func isSlide(_ name: String) -> Bool {
        let low = name.lowercased()
        guard !name.hasPrefix("."), !name.hasPrefix("~$"), low != "thumbs.db", !isPB(name) else { return false }
        return low.hasSuffix(".pptx") || low.hasSuffix(".key") || low.hasSuffix(".pdf")
    }
    /// Paper Blitz 덱 — PB_*.pdf·pptx (예전 공정 보드는 pptx 만 봐서 PB_260401.pdf 를 놓쳤다)
    static func isPB(_ name: String) -> Bool {
        let low = name.lowercased()
        return name.uppercased().hasPrefix("PB_") && !name.hasPrefix("~$") && (low.hasSuffix(".pdf") || low.hasSuffix(".pptx"))
    }
    static func isTranscript(_ name: String) -> Bool { name.hasPrefix("GRM_transcript_") && name.hasSuffix(".json") }
    /// 회의록 날짜 (A6-minutes) — 제목이 있는 Meeting Notes 행 **전부**(Type 'Other' 포함)의 날짜. 회의록 카드는 Other 를 빼지만
    /// 지도는 정의서·집계(aggregate_daily minutes_dates)와 같게 센다 — 예전엔 Other 만 있는 GRM 날 2건이 빠져 화면 7 · 집계 9 였다 (검증 1)
    static func minuteDays(_ notes: [(type: String, title: String, date: Date?)]) -> Set<Date> {
        Set(notes.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }.compactMap(\.date).map { Calendar.current.startOfDay(for: $0) })
    }
    /// 회의록 칸 — GRM 행의 Meeting Notes relation 이 있거나 같은 날짜 회의록
    static func hasMinutes(relation: Bool, day: Date, minuteDays: Set<Date>) -> Bool {
        relation || minuteDays.contains(Calendar.current.startOfDay(for: day))
    }
    /// text-check — 파일 이름 → '슬라이드' | 'PB' | '녹취' | '—'
    static func classify(_ name: String) -> String { isPB(name) ? "PB" : (isSlide(name) ? "슬라이드" : (isTranscript(name) ? "녹취" : "—")) }

    static func folderName(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd"; return f.string(from: d)
    }

    /// NAS 목록 — 회차 날짜(들)의 해 폴더를 읽고, 그 해 모든 회차 폴더의 슬라이드·PB·녹취 유무. 폴더 목록을 못 읽으면 unknown('?')
    static func scan(root: String, dates: [Date]) -> GRMFolderScan {
        let fm = FileManager.default
        let cal = Calendar.current
        var out = GRMFolderScan()
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd"
        let years = Set(dates.map { cal.component(.year, from: $0) })
        var all = Set(dates.map { cal.startOfDay(for: $0) })
        // NAS 루트를 못 읽으면(마운트 안 됨) 모든 해가 판정 불가. 루트는 읽히는데 해 폴더가 없으면 그 해는 빈 목록(○), 해 폴더가 있는데 못 읽으면 판정 불가
        let rootReadable = (try? fm.contentsOfDirectory(atPath: root)) != nil
        for y in years {
            let yearDir = "\(root)/\(y)"
            var isDir: ObjCBool = false
            let names: [String]
            if !rootReadable { out.unreadableYears.insert(y); continue }
            if !fm.fileExists(atPath: yearDir, isDirectory: &isDir) { names = [] }
            else if let ls = try? fm.contentsOfDirectory(atPath: yearDir) { names = ls }
            else { out.unreadableYears.insert(y); continue }
            for n in names where n.count == 8 && Int(n) != nil {
                if let d = f.date(from: n) { out.folders.insert(cal.startOfDay(for: d)); all.insert(cal.startOfDay(for: d)) }
            }
        }
        for d in all {
            var i = GRMFolderScan.Info()
            if out.unreadableYears.contains(cal.component(.year, from: d)) { i.unknown = true; out.info[d] = i; continue }
            let dir = "\(root)/\(cal.component(.year, from: d))/\(f.string(from: d))"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue {
                i.exists = true
                if let files = try? fm.contentsOfDirectory(atPath: dir) {
                    i.slides = files.contains(where: isSlide)
                    i.pb = files.contains(where: isPB)
                    i.transcript = ((try? fm.contentsOfDirectory(atPath: dir + "/transcript")) ?? []).contains(where: isTranscript)
                } else { i.unknown = true }
            }
            out.info[d] = i
        }
        out.firstTranscript = out.info.filter { $0.value.transcript }.keys.min()
        // PaperBlitz.json — sessions[].date (yyyy-MM-dd 또는 yyyymmdd)
        if let data = fm.contents(atPath: "\(root)/PaperBlitz.json"), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for s in (o["sessions"] as? [[String: Any]]) ?? [] {
                if let ds = s["date"] as? String, let d = MetricsSnapshot.day(ds) ?? f.date(from: ds) { out.pbJSON.insert(cal.startOfDay(for: d)) }
            }
        }
        return out
    }

    /// 지도 한 행
    struct Row: Identifiable {
        let slot: GRMSlot
        let who: String
        let marks: [Mark]   // 초록·슬라이드·녹취·회의록·PB
        let mine: Bool
        var id: String { slot.id }
        /// 발표자 칸(초록·슬라이드)의 빈칸 수 (A6-blank — 녹취·회의록 결측은 세지 않음)
        var blanks: Int { marks.prefix(2).filter { $0 == .no }.count }
    }

    /// 지난 회차(올해, 날짜 < 오늘) 내림차순
    @MainActor static func rows(_ m: NotionHubModel) -> [Row] {
        let cal = Calendar.current
        let today = m.today
        let year = cal.component(.year, from: today)
        let scan = m.grmScan
        let me = HubPrefs.me
        let minuteDays = m.minuteDaysAll
        return m.grmAll.filter { $0.date < today && cal.component(.year, from: $0.date) == year }.sorted { $0.date > $1.date }.map { g in
            let d = cal.startOfDay(for: g.date)
            let info = scan?.info[d]
            let folderUnknown = scan == nil || (info?.unknown ?? false) || (scan?.unreadableYears.contains(cal.component(.year, from: d)) ?? false)
            let abstract: Mark = g.docURL != nil ? .yes : .no
            let slides: Mark = folderUnknown ? .unknown : ((info?.slides ?? false) ? .yes : .no)
            let transcript: Mark = {
                if let first = scan?.firstTranscript, d < first { return .na }
                if folderUnknown { return .unknown }
                return (info?.transcript ?? false) ? .yes : .no
            }()
            let minutes: Mark = hasMinutes(relation: !g.noteIDs.isEmpty, day: d, minuteDays: minuteDays) ? .yes : .no
            let pbKnown = m.blitzDates.contains(d) || (scan?.pbJSON.contains(d) ?? false)
            let pb: Mark = (info?.pb ?? false) || pbKnown ? .yes : (folderUnknown ? .unknown : .no)
            let who = m.initialsList(g.presenters)
            return Row(slot: g, who: who.isEmpty ? "미정" : who, marks: [abstract, slides, transcript, minutes, pb], mine: m.isMine(g.presenters, me: me))
        }
    }
    /// 기본 = 내 회차 ∪ 최근 6, 펼치면 전체 (HubExpansion 'grm-map')
    static func shown(_ rows: [Row], open: Bool) -> [Row] {
        if open { return rows }
        let latest = Set(rows.prefix(6).map(\.id))
        return rows.filter { $0.mine || latest.contains($0.id) }
    }
    /// 올해 해 폴더를 읽지 못함(NAS 마운트 안 됨 등) — 날짜 대응은 '—', 칸은 '?'
    @MainActor static func yearUnreadable(_ m: NotionHubModel) -> Bool {
        m.grmScan?.unreadableYears.contains(Calendar.current.component(.year, from: m.today)) ?? false
    }
    /// 날짜 대응 (A6-match) — NAS 회차 폴더(오늘 전) ↔ 지난 Schedule 날짜. NAS 목록 전·해 폴더를 못 읽었으면 nil
    @MainActor static func match(_ m: NotionHubModel) -> (matched: Int, total: Int, nasOnly: Int, scheduleOnly: Int)? {
        guard let scan = m.grmScan, !yearUnreadable(m) else { return nil }
        let cal = Calendar.current
        let today = m.today
        let year = cal.component(.year, from: today)
        let sched = Set(m.grmAll.filter { $0.date < today && cal.component(.year, from: $0.date) == year }.map { cal.startOfDay(for: $0.date) })
        let nas = Set(scan.folders.filter { $0 < today && cal.component(.year, from: $0) == year })
        return (sched.intersection(nas).count, sched.count, nas.subtracting(sched).count, sched.subtracting(nas).count)
    }
    /// 열별 채움 'n/전체' · '?' 수
    static func fills(_ rows: [Row]) -> (filled: [Int], unknown: Int) {
        ((0..<columns.count).map { c in rows.filter { $0.marks[c] == .yes }.count }, rows.reduce(0) { $0 + $1.marks.filter { $0 == .unknown }.count })
    }

    /// text.txt [GRM 자료 지도] — 머리 줄 · 보임 · 행 'M.d · 이니셜 · ●○●–●[ · 빈칸 n]' · 순번 줄
    @MainActor static func dumpLines(_ m: NotionHubModel) -> [String] {
        let rs = rows(m)
        let fl = fills(rs)
        let mt = match(m)
        var head = "회차 \(rs.count)"
        if let mt { head += " · 날짜 대응 \(mt.matched)/\(mt.total) · NAS 만 \(mt.nasOnly) · Schedule 만 \(mt.scheduleOnly)" }
        else { head += yearUnreadable(m) ? " · 날짜 대응 —(NAS 읽지 못함)" : " · 날짜 대응 —(NAS 목록 전)" }
        head += " · " + zip(columns, fl.filled).map { "\($0.0) \($0.1)/\(rs.count)" }.joined(separator: " · ") + " · ? \(fl.unknown)"
        let open = HubExpansion.shared.isOpen("grm-map")
        let shown = shown(rs, open: open)
        var out = [head, "보임 \(shown.count)/\(rs.count) · 펼침 " + (open ? "on" : "off") + (m.grmScan.map { " · NAS 목록 " + Hub.time($0.scannedAt) } ?? "")]
        out += shown.map { r in "\(Hub.shortDay(r.slot.date)) · \(r.who) · " + r.marks.map(\.rawValue).joined() + (r.mine ? " · 빈칸 \(r.blanks)" : "") }
        out.append("순번:")
        out += GRMRotation.rows(m).map { r in "\(r.order) · \(r.initials) · 지난 \(r.last) · 다음 \(r.next)" + (r.isNext ? " (다음 발표)" : "") }
        return out
    }
}

/// 순번 한 줄 (4열 — 순번 | 이름(이니셜) | 지난 GRM n일 전 | 다음 M.d). 횟수 열은 두지 않는다(D8)
struct GRMRotation {
    let member: Member
    let order: Int
    let initials: String
    let last: String
    let next: String
    let isNext: Bool

    @MainActor static func rows(_ m: NotionHubModel) -> [GRMRotation] {
        let fromSchedule = GRMOrderView.cycle(m.grm.filter { $0.date >= m.today }, members: m.members)
        let ms = fromSchedule.count >= 3 ? fromSchedule : m.members.filter { $0.active && $0.order < 99 }
        let nextPresenters = m.nextGRM?.presenters ?? ""
        let cal = Calendar.current
        func presents(_ g: GRMSlot, _ mem: Member) -> Bool {
            (!mem.name.isEmpty && g.presenters.contains(mem.name)) || m.initialsList(g.presenters).components(separatedBy: ", ").contains(mem.initials)
        }
        return ms.enumerated().map { i, mem in
            let last = m.grmAll.filter { $0.date < m.today && presents($0, mem) }.map(\.date).max()
            let next = m.grmAll.filter { $0.date >= m.today && presents($0, mem) }.map(\.date).min()
            let ago = last.map { "\(cal.dateComponents([.day], from: cal.startOfDay(for: $0), to: m.today).day ?? 0)일 전" } ?? "—"
            return GRMRotation(member: mem, order: i + 1, initials: mem.initials.isEmpty ? mem.name : mem.initials, last: ago,
                               next: next.map(Hub.shortDay) ?? "—",
                               isNext: !nextPresenters.isEmpty && (nextPresenters.contains(mem.name) || nextPresenters.contains(mem.initials)))
        }
    }
}

extension NotionHubModel {
    /// NAS 회차 폴더 목록 — refresh 끝에서 기다리지 않고 띄운다(10분 주기). 느리면 '?' 로 보이고 다음 갱신에 채워진다
    func loadGRMMap() {
        guard !grmScanRunning else { return }
        grmScanRunning = true
        let root = cfg.nasGRMRoot, dates = grmAll.map(\.date)
        Task { @MainActor [weak self] in
            let r = await Task.detached(priority: .utility) { GRMMap.scan(root: root, dates: dates) }.value
            self?.grmScan = r
            self?.grmScanRunning = false
        }
    }
}

/// 지난 회차 자료 — 점 행렬 (SwiftUI Grid). 행 = 지난 회차 내림차순, 기본 내 회차 ∪ 최근 6, '▸ 전체 n회' 로 펼침(HubExpansion 'grm-map')
struct GRMMapView: View {
    @ObservedObject var model: NotionHubModel
    @ObservedObject private var expansion = HubExpansion.shared
    private var colW: CGFloat { Hub.s(28) }
    private var dot: CGFloat { Hub.s(10) }

    var body: some View {
        let rows = GRMMap.rows(model)
        let open = expansion.isOpen("grm-map")
        let shown = GRMMap.shown(rows, open: open)
        let fl = GRMMap.fills(rows)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("지난 회차 자료").font(.hub(12, weight: .bold)).foregroundStyle(Hub.text2)
                Text(matchText).font(.hub(11)).foregroundStyle(Hub.text3).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 0) {
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 2) {
                    GridRow {
                        Text("회차").font(.hub(11, weight: .semibold)).foregroundStyle(Hub.text3)
                        ForEach(Array(GRMMap.columns.enumerated()), id: \.offset) { i, c in
                            VStack(spacing: 0) {
                                Text(c).font(.hub(10.5, weight: .semibold)).lineLimit(1).fixedSize()
                                Text("\(fl.filled[i])/\(rows.count)").font(.hub(10.5)).monospacedDigit().lineLimit(1).fixedSize()
                            }
                            .foregroundStyle(Hub.text2).frame(minWidth: colW)
                        }
                        Text("").gridCellUnsizedAxes(.horizontal)
                    }
                    ForEach(shown) { r in mapRow(r) }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                if rows.count > shown.count || open {
                    RowDivider()
                    Button { expansion.toggle("grm-map") } label: {
                        Text(open ? "▾ 접기 · 내 회차와 최근 6" : "▸ 전체 \(rows.count)회").font(.hub(12, weight: .medium)).foregroundStyle(Hub.text2)
                            .frame(maxWidth: .infinity).padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                CardFooter(caption: MetricDefs.caption(source: "GRM Schedule·NAS 회차 폴더·Meeting Notes·PB", basis: CardMetas.basis(model.grmScan?.scannedAt),
                                                       n: "\(rows.count)", id: "A6-match"))
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
            Text("● 있음 · ○ 없음 · – 해당 없음(녹취 도입 전) · ? 판정 불가(NAS) · 빈칸 = 내 회차의 초록·슬라이드").font(.hub(10.5)).foregroundStyle(Hub.text3)
        }
    }

    private var matchText: String {
        guard let mt = GRMMap.match(model) else { return GRMMap.yearUnreadable(model) ? "날짜 대응 — (NAS 읽지 못함 · 칸은 ?)" : "날짜 대응 — (NAS 목록 전)" }
        return "날짜 대응 \(mt.matched)/\(mt.total) · NAS 만 \(mt.nasOnly) · Schedule 만 \(mt.scheduleOnly)"
    }

    private func mapRow(_ r: GRMMap.Row) -> some View {
        GridRow {
            HStack(spacing: 6) {
                Text(Hub.shortDay(r.slot.date)).font(.hub(12, weight: .semibold, design: .rounded)).monospacedDigit()
                    .frame(width: Hub.s(Hub.dateColumn), alignment: .leading)
                Text(r.who).font(.hub(12, weight: r.mine ? .bold : .regular)).foregroundStyle(r.mine ? Hub.ink : Hub.text).lineLimit(1)
            }
            .frame(minHeight: Hub.s(14))
            .link(.notion(r.slot.id))
            ForEach(Array(r.marks.enumerated()), id: \.offset) { i, mk in
                markView(mk).frame(width: colW)
                    .accessibilityLabel("\(Hub.shortDay(r.slot.date)) \(GRMMap.columns[i]) " + label(mk))
                    .help("\(Hub.shortDay(r.slot.date)) \(GRMMap.columns[i]) " + label(mk))
            }
            Text(r.mine && r.blanks > 0 ? "빈칸 \(r.blanks)" : "").font(.hub(11)).foregroundStyle(Hub.text2).lineLimit(1)
        }
    }

    private func label(_ m: GRMMap.Mark) -> String {
        switch m { case .yes: return "있음"; case .no: return "없음"; case .na: return "해당 없음"; case .unknown: return "판정 불가" }
    }

    @ViewBuilder private func markView(_ m: GRMMap.Mark) -> some View {
        switch m {
        case .yes: Circle().fill(Hub.ink).frame(width: dot, height: dot)
        case .no: Circle().stroke(Hub.text3, lineWidth: 1).frame(width: dot, height: dot)
        case .na: Rectangle().fill(Hub.divider).frame(width: dot, height: 2)
        case .unknown: Text("?").font(.hub(11, weight: .bold)).foregroundStyle(Hub.text2)
        }
    }
}
