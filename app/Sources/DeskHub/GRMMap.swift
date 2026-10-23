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
    /// Paper Blitz 덱 — PB_yymmdd*.pdf·pptx (예전 공정 보드는 pptx 만 봐서 PB_260401.pdf 를 놓쳤다).
    /// 밑줄 없는 PB261021.pptx 도 덱으로 센다(0.44.0 #61 — 예전엔 놓치고 슬라이드로 셌다). 이름 경고는 pbNameIssue. aggregate_daily.is_pb 와 같은 규칙
    static func isPB(_ name: String) -> Bool {
        let low = name.lowercased()
        guard !name.hasPrefix("~$"), low.hasSuffix(".pdf") || low.hasSuffix(".pptx") else { return false }
        return name.range(of: #"^[Pp][Bb]_?[0-9]{6}"#, options: .regularExpression) != nil
    }
    /// 덱 이름 규칙(PB_yymmdd) 어긋남 — 밑줄이 없으면 경고 글, 맞거나 덱이 아니면 nil (공정 'blitz' 칸·신선도 꼬리표·text-check A6-pb)
    static func pbNameIssue(_ name: String) -> String? {
        guard isPB(name), !name.uppercased().hasPrefix("PB_") else { return nil }
        return "이름 규칙 어긋남 (PB_yymmdd)"
    }
    /// 한 폴더에서 덱 하나 — 밑줄 쪽 먼저, 같으면 pdf 먼저, 그다음 이름순
    static func pickPB(_ names: [String]) -> String? {
        names.filter(isPB).min { a, b in
            func key(_ n: String) -> (Int, Int, String) { (pbNameIssue(n) == nil ? 0 : 1, n.lowercased().hasSuffix(".pdf") ? 0 : 1, n) }
            return key(a) < key(b)
        }
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
    /// text-check — 파일 이름 → '슬라이드' | 'PB' | 'PB(이름 규칙 어긋남)' | '녹취' | '—'
    static func classify(_ name: String) -> String {
        isPB(name) ? (pbNameIssue(name) == nil ? "PB" : "PB(이름 규칙 어긋남)") : (isSlide(name) ? "슬라이드" : (isTranscript(name) ? "녹취" : "—"))
    }

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

    // MARK: 허브 한 줄 (0.41.0 C6, R2 — 'CSNL GRM' 탭은 이번 주·지난주 한 줄, 상세 지도는 GRM 주간 뷰에만)

    /// 한 주의 회차 — past = 지난 회차(점 5개 있음), 아니면 예정
    struct WeekCell: Equatable { let date: Date; let who: String; let marks: [Mark]?; let past: Bool }
    /// 이번 주·지난주(한국시간 월~일, MetricDefs.week) — 그 주의 지난 회차(rows, 날짜 < 오늘) 중 가장 늦은 것,
    /// 없으면 그 주 오늘 이후 예정(schedule) 중 가장 이른 것('예정 M.d'), 둘 다 없으면 nil('—'). 순수 함수 — text-check 'grmweek'
    static func weekSummary(rows: [(date: Date, who: String, marks: [Mark])], schedule: [Date], today: Date) -> (this: WeekCell?, last: WeekCell?) {
        let cal = MetricDefs.kst
        let t0 = cal.startOfDay(for: today)
        func cell(_ weekStart: Date) -> WeekCell? {
            let end = cal.date(byAdding: .day, value: 7, to: weekStart)!
            func inWeek(_ d: Date) -> Bool { d >= weekStart && d < end }
            if let r = rows.filter({ inWeek($0.date) && cal.startOfDay(for: $0.date) < t0 }).max(by: { $0.date < $1.date }) {
                return WeekCell(date: r.date, who: r.who, marks: r.marks, past: true)
            }
            if let d = schedule.filter({ inWeek($0) && cal.startOfDay(for: $0) >= t0 }).min() {
                return WeekCell(date: d, who: "", marks: nil, past: false)
            }
            return nil
        }
        let thisStart = MetricDefs.week(of: today).start
        return (cell(thisStart), cell(cal.date(byAdding: .day, value: -7, to: thisStart)!))
    }
    static func weekText(_ c: WeekCell?) -> String {
        guard let c else { return "—" }
        let d = MetricDefs.ymd(c.date).split(separator: "-").dropFirst().map { String(Int($0) ?? 0) }.joined(separator: ".")
        if !c.past { return "예정 " + d }
        return [d, c.who.isEmpty ? "미정" : c.who, (c.marks ?? []).map(\.rawValue).joined()].joined(separator: " ")
    }
    /// '이번 주 10.14 SMJ ●●●●○ · 지난주 10.7 JOP ●●●●○' — 뷰 도움말·덤프 '허브 한 줄:' 이 같은 글
    static func weekLine(this: WeekCell?, last: WeekCell?) -> String { "이번 주 " + weekText(this) + " · 지난주 " + weekText(last) }
    /// 모델에서 — rows(m) 와 올해 GRM Schedule 전체
    @MainActor static func weekSummary(_ m: NotionHubModel) -> (this: WeekCell?, last: WeekCell?) {
        weekSummary(rows: rows(m).map { ($0.slot.date, $0.who, $0.marks) }, schedule: m.grmAll.map(\.date), today: m.today)
    }
    /// text-check 'grmweek' — 'today=;rows=yyyy-MM-dd 이니셜 ●○●–?|…;sched=yyyy-MM-dd|…' → weekLine
    static func weekCheck(_ input: String) -> String {
        var k: [String: String] = [:]
        for part in input.components(separatedBy: ";") {
            let p = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if p.count == 2 { k[p[0].trimmingCharacters(in: .whitespaces)] = p[1] }
        }
        guard let today = MetricDefs.parseDay(k["today"] ?? "") else { return "(입력 형식)" }
        let rows: [(date: Date, who: String, marks: [Mark])] = (k["rows"] ?? "").components(separatedBy: "|").compactMap { r in
            let f = r.split(separator: " ").map(String.init)
            guard f.count == 3, let d = MetricDefs.parseDay(f[0]) else { return nil }
            return (d, f[1], f[2].map { Mark(rawValue: String($0)) ?? .unknown })
        }
        let sched = (k["sched"] ?? "").components(separatedBy: "|").compactMap { MetricDefs.parseDay($0) } + rows.map(\.date)
        let s = weekSummary(rows: rows, schedule: sched, today: today)
        return weekLine(this: s.this, last: s.last)
    }

    /// text.txt [GRM 자료 지도] — 머리 줄 · 허브 한 줄 · 보임 · 행 'M.d · 이니셜 · ●○●–●[ · 빈칸 n]' · 순번 줄
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
        let wk = weekSummary(m)
        var out = [head, "허브 한 줄: " + weekLine(this: wk.this, last: wk.last),
                   "보임 \(shown.count)/\(rs.count) · 펼침 " + (open ? "on" : "off") + (m.grmScan.map { " · NAS 목록 " + Hub.time($0.scannedAt) } ?? "")]
        out += shown.map { r in "\(Hub.shortDay(r.slot.date)) · \(r.who) · " + r.marks.map(\.rawValue).joined() + (r.mine ? " · 빈칸 \(r.blanks)" : "") }
        out.append("순번:")
        out += GRMRotation.rows(m).map { r in "\(r.order) · \(r.initials) · 지난 \(r.last) · 다음 \(r.next)" + (r.isNext ? " (다음 발표)" : "") }
        // 일정 표와 같은 행 (0.43.2 C1, #54) — 'M.d 이니셜 · … · 중복 n'
        let sched = GRMSchedule.rows(m.grm, today: m.today, now: m.now)
        out.append("일정: " + GRMSchedule.line(sched.rows, who: { g in
            let i = m.initialsList(g.presenters)
            return i.isEmpty ? "미정" : i
        }, marks: false) + " · 중복 \(sched.dup)")
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

/// GRM 일정 규칙 한 곳 (0.43.2 C1, #54 R4) — 정오 규칙(지난 회차)·같은 회차 판정·일정 표 행.
/// 경보·꼬리표·파이프라인·관련도는 last 만 쓰고(원본 그대로), 데이터 중복 합치기는 일정 표·덤프(rows)에만.
enum GRMSchedule {
    /// 지난 GRM — 날짜 < 오늘, 또는 오늘이고 now ≥ 12:00. 같은 조건 중 날짜 최댓값(같으면 뒤에 나온 것) — 정렬된 grm 에서는 grm.last { … } 와 같다
    static func last(_ slots: [GRMSlot], today: Date, now: Date) -> GRMSlot? {
        let cal = Calendar.current
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: today)!
        var best: GRMSlot?
        for g in slots where g.date < today || (cal.isDate(g.date, inSameDayAs: today) && now >= noon) {
            if best == nil || g.date >= best!.date { best = g }
        }
        return best
    }
    /// 같은 회차 — 그날 + 발표자(앞뒤 공백 제거·연속 공백 하나로) + Type
    static func key(_ g: GRMSlot) -> String {
        let day = Calendar.current.startOfDay(for: g.date).timeIntervalSince1970
        let who = g.presenters.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return "\(Int(day))|\(who)|\(g.type)"
    }
    /// 일정 표 — 지난 한 번 + 오늘 이후(지난 회차와 같은 id 는 빼고). 같은 key 는 처음 자리 하나로(공지·초록 OR), 합친 수 = dup
    static func rows(_ slots: [GRMSlot], today: Date, now: Date) -> (rows: [GRMSlot], dup: Int) {
        let past = last(slots, today: today, now: now)
        let all = (past.map { [$0] } ?? []) + slots.filter { $0.date >= today && $0.id != past?.id }
        var out: [GRMSlot] = [], at: [String: Int] = [:], dup = 0
        for g in all {
            let k = key(g)
            if let i = at[k] {
                let f = out[i]
                out[i] = GRMSlot(id: f.id, date: f.date, presenters: f.presenters, type: f.type,
                                 notified: f.notified || g.notified, abstractDone: f.abstractDone || g.abstractDone,
                                 docURL: f.docURL ?? g.docURL, noteIDs: f.noteIDs + g.noteIDs.filter { !f.noteIDs.contains($0) })
                dup += 1
            } else {
                at[k] = out.count; out.append(g)
            }
        }
        return (out, dup)
    }
    /// 'M.d 발표자[ 공지][ 초록] · …' — who 는 발표자 표기(덤프는 이니셜), 행이 없으면 '—'
    static func line(_ rows: [GRMSlot], who: (GRMSlot) -> String, marks: Bool) -> String {
        guard !rows.isEmpty else { return "—" }
        return rows.map { g in
            var s = Hub.shortDay(g.date) + " " + who(g)
            if marks { if g.notified { s += " 공지" }; if g.abstractDone { s += " 초록" } }
            return s
        }.joined(separator: " · ")
    }
    /// text-check 'grm-sched' — 'now=yyyy-MM-ddTHH:mm;slots=yyyy-MM-dd/발표자/Type[/공지][/초록]|…'(id 는 's<순번>')
    /// → 'M.d 발표자[ 공지] · … | 중복 n'(행 없으면 '— | 중복 0'). fixtures/grmweek-check.tsv
    static func check(_ input: String) -> String {
        var k: [String: String] = [:]
        for part in input.components(separatedBy: ";") {
            let p = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if p.count == 2 { k[p[0].trimmingCharacters(in: .whitespaces)] = p[1] }
        }
        guard let now = MetricDefs.parseInstant(k["now"] ?? "") else { return "(입력 형식)" }
        let today = Calendar.current.startOfDay(for: now)
        let slots: [GRMSlot] = (k["slots"] ?? "").components(separatedBy: "|").enumerated().compactMap { i, s in
            let f = s.components(separatedBy: "/")
            guard f.count >= 3, let d = MetricDefs.parseDay(f[0]) else { return nil }
            let extra = f.dropFirst(3).map { $0.trimmingCharacters(in: .whitespaces) }
            return GRMSlot(id: "s\(i + 1)", date: d, presenters: f[1], type: f[2],
                           notified: extra.contains("공지"), abstractDone: extra.contains("초록"), docURL: nil, noteIDs: [])
        }
        let r = rows(slots, today: today, now: now)
        let who: (GRMSlot) -> String = { g in
            let n = g.presenters.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            return n.isEmpty ? "미정" : n
        }
        return line(r.rows, who: who, marks: true) + " | 중복 \(r.dup)"
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

    private func markView(_ m: GRMMap.Mark) -> some View { GRMMarkDot(mark: m, dot: dot) }
}

/// 점 하나 — 지도 칸과 허브 한 줄이 같은 모양 (● Hub.ink · ○ Hub.text3 테두리 · – 선 · ? 글자). 적색 없음
struct GRMMarkDot: View {
    let mark: GRMMap.Mark
    let dot: CGFloat
    var body: some View {
        switch mark {
        case .yes: Circle().fill(Hub.ink).frame(width: dot, height: dot)
        case .no: Circle().stroke(Hub.text3, lineWidth: 1).frame(width: dot, height: dot)
        case .na: Rectangle().fill(Hub.divider).frame(width: dot, height: 2)
        case .unknown: Text("?").font(.hub(11, weight: .bold)).foregroundStyle(Hub.text2)
        }
    }
}

/// 'CSNL GRM' 탭의 자료 지도 한 줄 (0.41.0 C6, R2) — '지난 회차 자료 · 이번 주 10.14 SMJ ●●●●○ · 지난주 10.7 JOP ●●●●○ · GRM 주간에서 자세히 ↗'.
/// 점 순서는 초록·슬라이드·녹취·회의록·PB(도움말·접근성 라벨에 열 이름). '↗' 한 번 = 첫 탭 + GRM 주간 뷰(전체 지도)
struct GRMMapSummaryLine: View {
    @ObservedObject var model: NotionHubModel
    private var dot: CGFloat { Hub.s(9) }

    var body: some View {
        let wk = GRMMap.weekSummary(model)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { title; cell("이번 주", wk.this); cell("지난주", wk.last); Spacer(minLength: 4); link }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) { title; Spacer(minLength: 4); link }
                HStack(spacing: 10) { cell("이번 주", wk.this); cell("지난주", wk.last); Spacer(minLength: 0) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
        .help(GRMMap.weekLine(this: wk.this, last: wk.last) + " — 점: " + GRMMap.columns.joined(separator: " · "))
    }

    private var title: some View {
        Text("지난 회차 자료").font(.hub(12, weight: .bold)).foregroundStyle(Hub.text2).lineLimit(1).fixedSize()
    }
    private var link: some View {
        Button {
            KeyBus.shared.send("tab:0")
            ViewModeStore.shared.mode = .grm
            UsageLog.panel("grm-map")
        } label: {
            HStack(spacing: 3) { Text("GRM 주간에서 자세히"); Image(systemName: "arrow.up.forward") }
                .font(.hub(11.5, weight: .medium)).foregroundStyle(Hub.text2).lineLimit(1).fixedSize()
        }
        .buttonStyle(.plain).help("GRM 주간 뷰 — 올해 지난 회차 전체 지도")
    }
    @ViewBuilder private func cell(_ label: String, _ c: GRMMap.WeekCell?) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.hub(11.5)).foregroundStyle(Hub.text3).lineLimit(1).fixedSize()
            if let c {
                Text((c.past ? "" : "예정 ") + Hub.shortDay(c.date)).font(.hub(12, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(c.past ? Hub.text : Hub.text2).lineLimit(1).fixedSize()
                if c.past {
                    Text(c.who.isEmpty ? "미정" : c.who).font(.hub(12)).foregroundStyle(Hub.text).lineLimit(1).fixedSize()
                    HStack(spacing: 3) {
                        ForEach(Array((c.marks ?? []).enumerated()), id: \.offset) { i, mk in
                            GRMMarkDot(mark: mk, dot: dot)
                                .accessibilityLabel("\(Hub.shortDay(c.date)) \(GRMMap.columns[i]) " + Self.label(mk))
                                .help("\(GRMMap.columns[i]) " + Self.label(mk))
                        }
                    }
                }
            } else {
                Text("—").font(.hub(12)).foregroundStyle(Hub.text3)
            }
        }
        .link(c.map { _ in HubLink.notion(model.cfg.grmScheduleDB) })
    }
    static func label(_ m: GRMMap.Mark) -> String {
        switch m { case .yes: return "있음"; case .no: return "없음"; case .na: return "해당 없음"; case .unknown: return "판정 불가" }
    }
}
