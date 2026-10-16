import SwiftUI
import AppKit

// MARK: - Members 탭 = 연구원 현황판 (0.37.0 C7, D-4·D-5)
// 'Members' 탭은 웹뷰 대신 이 표(탭 이름·설정 기본값·config.json 그대로 — 탭 대체 아님, 랩장 15:58).
// 실제 열: 이니셜 · 진행 프로젝트(NAS Memory 폴더, 칩 줄과 같은 member_links) · 다음 GRM(GRM Schedule) · Milestone(NAS MM 폴더 최신 파일 날짜)
// 실제 열(0.39.0 C4, SB-LIVE): 논문 반응 — 최근 28일 Notion 논문 추천 댓글의 세 반응(취소 반영), 이니셜은 자기 신고. 머리 '실제 M.d–M.d' 칩.
// 예시 열: Claude 사용량 · GitHub push — Resources/scoreboard-sample.json 의 표본 숫자. 열 머리마다 '예시' 칩 + 표 위 띠 + 무채색 막대.
// 교수님께 실제/예시를 구분해 보이기 위한 것(랩장 10-16 17:22). 순위가 아니다 — 행은 GRM 순번 순(정렬·1등 강조·색 구분 없음), 본인 행만 진한 막대. 적색 없음

/// 예시 열 표본 — 훅 DESKHUB_SCOREBOARD_SAMPLE → 사용자 폴더(~/Library/Application Support/DeskHub/scoreboard-sample.json) → 번들. 실패면 예시 열 숨김.
/// 값 null 은 '—'(디코딩 실패 아님). 실제 열 id(ScoreboardLive.liveIDs — react)와 같은 열은 버린다: 옛 표본이 남아도 예시와 실제가 한 열에 섞이지 않게 (0.39.0 C4)
struct ScoreboardSample: Codable {
    struct Column: Codable, Identifiable { let id: String; let title: String; let unit: String }
    let note: String
    let columns: [Column]
    let values: [String: [String: Int?]]

    static func load() -> ScoreboardSample? {
        let user = Config.directory.appendingPathComponent("scoreboard-sample.json")
        var urls: [URL] = []
        if let p = ProcessInfo.processInfo.environment["DESKHUB_SCOREBOARD_SAMPLE"], !p.isEmpty { urls.append(URL(fileURLWithPath: (p as NSString).expandingTildeInPath)) }
        urls.append(user)
        if let b = Bundle.main.url(forResource: "scoreboard-sample", withExtension: "json") { urls.append(b) }
        for url in urls {
            guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(ScoreboardSample.self, from: d) else { continue }
            let cols = s.columns.filter { !ScoreboardLive.liveIDs.contains($0.id) }
            if !cols.isEmpty { return ScoreboardSample(note: s.note, columns: cols, values: s.values) }
        }
        return nil
    }
    /// 열의 최댓값 — 막대 길이 기준
    func maxValue(_ col: String) -> Int { max(1, values.values.compactMap { $0[col] ?? nil }.max() ?? 1) }
}

/// 전광판 실제 열 '논문 반응' 집계 — 순수 함수 (0.39.0 C4, SB-LIVE). 입력은 settle 뒤 댓글(model.paperComments)
enum ScoreboardLive {
    /// 실제 열 id — 표본(scoreboard-sample.json)에 같은 id 가 있으면 버린다
    static let liveIDs: Set<String> = ["react"]
    static let days = 28
    static let help = "최근 28일 세 반응(읽겠음·읽었음·관심없음) 합 · 취소 반영 · 이니셜은 자기 신고(봇이 대신 씀) · 읽은 양·기여도 아님"

    struct Period { let from: Date; let to: Date; let label: String }
    /// from = today −27일, to = today(그날 끝까지), label 'M.d–M.d' — DESKHUB_NOW=2026-10-15 → '9.18–10.15'
    static func period(today: Date) -> Period {
        let to = Calendar.current.startOfDay(for: today)
        let from = Calendar.current.date(byAdding: .day, value: -(days - 1), to: to) ?? to
        return Period(from: from, to: to, label: Hub.shortDay(from) + "–" + Hub.shortDay(to))
    }

    struct Tally: Equatable {
        /// 로스터 이니셜 → 반응 수
        var reactions: [String: Int] = [:]
        /// 반응을 하나라도 남긴 사람 수(목록 밖 포함)
        var people = 0
        /// 사람이 쓴 댓글 수(기간 안, isNote — 반응·제안·취소 제외)
        var notes = 0
        /// 로스터 밖 이니셜 → 반응 수 (합계에만)
        var outside: [String: Int] = [:]
        var total: Int { reactions.values.reduce(0, +) + outside.values.reduce(0, +) }
    }

    /// isReaction · 기간 안(to 는 그날 끝까지) · who 있음만 이니셜별로. 이니셜은 대문자 + aliases(옛 이니셜 → 지금 이니셜)로 묶고,
    /// 로스터 밖은 outside. 사람이 쓴 댓글(isNote — 반응·'같이 읽자' 제안·취소 제외, C5 와 같은 규칙)만 notes 합계로 (0.39.0 검증 1)
    static func tally(_ byPaper: [String: [PaperComment]], roster: [String], aliases: [String: String], from: Date, to: Date) -> Tally {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: to)) ?? to
        let start = Calendar.current.startOfDay(for: from)
        let canon: (String) -> String = { w in let u = w.uppercased(); return (aliases[u] ?? aliases[w] ?? u).uppercased() }
        let rosterSet = Set(roster.filter { !$0.isEmpty }.map(canon))
        var t = Tally()
        var who = Set<String>()
        for cs in byPaper.values {
            for c in cs {
                guard let at = c.created, at >= start, at < end else { continue }
                if c.isReaction {
                    let w = c.who.trimmingCharacters(in: .whitespaces)
                    guard !w.isEmpty else { continue }
                    let k = canon(w)
                    if rosterSet.contains(k) { t.reactions[k, default: 0] += 1 } else { t.outside[k, default: 0] += 1 }
                    who.insert(k)
                } else if c.isNote {
                    t.notes += 1
                }
            }
        }
        t.people = who.count
        return t
    }

    /// 모델 값으로 — 댓글을 아직 못 읽었으면 nil('—')
    @MainActor static func tally(_ model: NotionHubModel) -> Tally? {
        guard model.paperCommentsReadAt != nil else { return nil }
        let p = period(today: HubClock.today)
        return tally(model.paperComments, roster: MembersProjectsStrip.shown(model).map(\.initials), aliases: model.cfg.initialsAliases, from: p.from, to: p.to)
    }
    /// 행 값 — 로스터 이니셜의 반응 수(없으면 0), 못 읽었거나 이니셜이 비면 nil
    static func value(_ t: Tally?, initials: String, aliases: [String: String]) -> Int? {
        guard let t, !initials.isEmpty else { return nil }
        let u = initials.uppercased()
        return t.reactions[(aliases[u] ?? u).uppercased()] ?? 0
    }
}

/// 멤버 한 명의 최신 Milestone meeting 파일
struct MilestoneFile: Equatable {
    let path: String
    let date: Date
    /// true = 파일 이름(MM<yymmdd>_<이니셜>)의 날짜, false = 수정 시각(복사로 바뀔 수 있어 '수정일' 로 표시)
    let fromName: Bool
    var label: String { Hub.shortDay(date) + (fromName ? " 이름" : " 수정일") }
}

/// NAS MM/<이니셜>/ 의 최신 발표 파일 — 순수 함수(파일 목록만 읽는다, 이름을 바꾸지 않는다)
enum MilestoneFiles {
    static let exts: Set<String> = ["pptx", "ppt", "key", "pdf"]

    /// 폴더 후보 = 이니셜 + 그 이니셜로 가는 옛 이니셜(initialsAliases: SK → SJK)
    static func folders(for ini: String, aliases: [String: String]) -> [String] {
        [ini] + aliases.filter { $0.value.uppercased() == ini.uppercased() }.map(\.key).sorted()
    }

    /// 'MM261016_JOP…' → 2026-10-16 (이니셜이 후보 중 하나일 때만)
    static func nameDate(_ file: String, initials: [String]) -> Date? {
        guard let m = file.range(of: "^MM(\\d{6})_([A-Za-z]+)", options: .regularExpression) else { return nil }
        let s = String(file[m])
        let digits = String(s.dropFirst(2).prefix(6))
        let who = String(s.dropFirst(9)).uppercased()
        guard initials.contains(where: { $0.uppercased() == who }),
              let yy = Int(digits.prefix(2)), let mm = Int(digits.dropFirst(2).prefix(2)), let dd = Int(digits.suffix(2)) else { return nil }
        var c = DateComponents(); c.year = 2000 + yy; c.month = mm; c.day = dd
        guard let d = Calendar.current.date(from: c), Calendar.current.component(.month, from: d) == mm else { return nil }
        return d
    }

    /// 한 멤버의 최신 파일. 최신 = 날짜(이름 날짜 또는 수정 시각) → 같으면 pptx·key 먼저 → 수정 시각. 폴더·'~$'·'.' 로 시작하는 것 제외
    static func latest(root: String, initials ini: String, aliases: [String: String]) -> MilestoneFile? {
        let fm = FileManager.default
        let cands = folders(for: ini, aliases: aliases)
        var best: (file: MilestoneFile, pref: Int, mtime: Date)?
        for folder in cands {
            let dir = (root as NSString).appendingPathComponent(folder)
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where !n.hasPrefix("~$") && !n.hasPrefix(".") && exts.contains((n as NSString).pathExtension.lowercased()) {
                let p = (dir as NSString).appendingPathComponent(n)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue else { continue }
                let mtime = ((try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date) ?? .distantPast
                let nd = nameDate(n, initials: cands)
                let day = Calendar.current.startOfDay(for: nd ?? mtime)
                let pref = ["pptx", "key"].contains((n as NSString).pathExtension.lowercased()) ? 0 : 1
                let f = MilestoneFile(path: p, date: day, fromName: nd != nil)
                if let b = best {
                    if day != b.file.date { if day < b.file.date { continue } }
                    else if pref != b.pref { if pref > b.pref { continue } }
                    else if mtime <= b.mtime { continue }
                }
                best = (f, pref, mtime)
            }
        }
        return best?.file
    }

    /// 멤버 전원 — root(MM 폴더)가 없으면(NAS 끊김) nil → Milestone 열 숨김
    static func scan(root: String, initials: [String], aliases: [String: String]) -> [String: MilestoneFile]? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { return nil }
        var out: [String: MilestoneFile] = [:]
        for ini in initials where !ini.isEmpty { if let f = latest(root: root, initials: ini, aliases: aliases) { out[ini] = f } }
        return out
    }
}

extension NotionHubModel {
    /// NAS MM 폴더 — 테스트 훅 DESKHUB_MM_ROOT=<경로> 면 그곳
    var milestoneRoot: String {
        if let p = ProcessInfo.processInfo.environment["DESKHUB_MM_ROOT"], !p.isEmpty { return (p as NSString).expandingTildeInPath }
        return (nasRoot as NSString).appendingPathComponent("MM")
    }
    /// refresh 에서 (메인 스레드 밖) — 읽기만
    func loadMilestones() async {
        let root = milestoneRoot, ini = members.map(\.initials).filter { !$0.isEmpty }, aliases = cfg.initialsAliases
        milestones = await Task.detached(priority: .utility) { MilestoneFiles.scan(root: root, initials: ini, aliases: aliases) }.value
    }
    /// 그 멤버가 발표자인 첫 예정 GRM
    func nextGRM(for m: Member) -> GRMSlot? {
        grm.filter { $0.date >= today }.sorted { $0.date < $1.date }.first { g in
            (!m.name.isEmpty && g.presenters.contains(m.name)) || initialsList(g.presenters).components(separatedBy: ", ").contains(m.initials)
        }
    }
}

/// 현황판 한 행 (뷰·text.txt 공용)
struct MembersBoardRow {
    let member: Member
    let projects: String
    let projectsHelp: String
    let nextGRM: String          // '10.22 D-7' 또는 —
    let milestone: MilestoneFile?
    /// 실제 열 '논문 반응' — 댓글을 아직 못 읽었으면 nil('—')
    let live: Int?
    let samples: [Int?]

    @MainActor static func rows(_ model: NotionHubModel, sample: ScoreboardSample?, tally: ScoreboardLive.Tally?) -> [MembersBoardRow] {
        MembersProjectsStrip.shown(model).map { m in
            let projs = (model.memberLinkEntry(for: m)?.projects ?? []).map { MemberGroup.display($0.name) }
            let shown = projs.prefix(2).joined(separator: ", ") + (projs.count > 2 ? " +\(projs.count - 2)" : "")
            let g = model.nextGRM(for: m)
            let vals: [Int?] = sample.map { s in s.columns.map { s.values[m.initials]?[$0.id] ?? nil } } ?? []
            return MembersBoardRow(member: m, projects: shown, projectsHelp: projs.joined(separator: "\n"),
                                   nextGRM: g.map { Hub.shortDay($0.date) + " " + Hub.dday($0.date) } ?? "",
                                   milestone: model.milestones?[m.initials],
                                   live: ScoreboardLive.value(tally, initials: m.initials, aliases: model.cfg.initialsAliases), samples: vals)
        }
    }

    static let band = "일부 열은 예시 — 표본 자료, 실제 집계 아님"
    static let bandAux = "논문 반응은 Notion 논문 추천 댓글에서 센 실제 값"
    static let purpose = "순위가 아닙니다 — 행은 GRM 순번 순, 비교는 본인의 지난 기간과. 숫자는 읽은 양·기여도가 아니며 평가·장학·인사에 쓰지 않습니다."
    static let source = "진행 프로젝트 = NAS Memory 폴더 · 다음 GRM = GRM Schedule · Milestone = NAS MM 폴더의 최신 파일 날짜(이름에 날짜가 없으면 '수정일') · 논문 반응 = 최근 28일 논문 추천 댓글의 세 반응(취소 반영)"

    /// 합계 줄 — '연구실 · 9.18–10.15 · 논문 반응 n건(n명) · 댓글 n건 · Milestone 28일 안 n명 · 다음 GRM 예정 n명'. 못 읽었으면 반응·댓글 자리 '—'
    @MainActor static func summary(_ model: NotionHubModel, rows: [MembersBoardRow], tally: ScoreboardLive.Tally?) -> String {
        let p = ScoreboardLive.period(today: HubClock.today)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: p.to) ?? p.to
        let react = tally.map { "\($0.total)건(\($0.people)명)" } ?? "—"
        let notes = tally.map { "\($0.notes)건" } ?? "—"
        let mm = model.milestones == nil ? "—" : "\(rows.filter { r in r.milestone.map { $0.date >= p.from && $0.date < end } ?? false }.count)명"
        let grm = rows.filter { !$0.nextGRM.isEmpty }.count
        return ["연구실", p.label, "논문 반응 " + react, "댓글 " + notes, "Milestone 28일 안 " + mm, "다음 GRM 예정 \(grm)명"].joined(separator: " · ")
    }

    /// text.txt [Members 전광판] — 열(실제/예시 접미) · 띠 · 합계 · 행 · 각주. 열·값은 열 단위로 나눠 쌓는다
    @MainActor static func dumpLines(_ model: NotionHubModel) -> [String] {
        let sample = ScoreboardSample.load()
        let tally = ScoreboardLive.tally(model)
        let period = ScoreboardLive.period(today: HubClock.today)
        let rs = rows(model, sample: sample, tally: tally)
        var cols = ["이니셜", "진행 프로젝트", "다음 GRM"]
        if model.milestones != nil { cols.append("Milestone") }
        cols.append("논문 반응(실제 \(period.label))")
        cols += (sample?.columns ?? []).map { $0.title + "(예시)" }
        var out = ["열: " + cols.joined(separator: " · ")]
        if sample != nil { out.append("띠: " + band + " · " + bandAux) }
        out.append("합계: " + summary(model, rows: rs, tally: tally))
        let dash: (String) -> String = { $0.isEmpty ? "—" : $0 }
        for r in rs {
            var f = [dash(r.member.initials), dash(r.projects), dash(r.nextGRM)]
            if model.milestones != nil { f.append(r.milestone?.label ?? "—") }
            f.append(r.live.map(String.init) ?? "—")
            f += r.samples.map { $0.map(String.init) ?? "—" }
            out.append(f.joined(separator: " · "))
        }
        out.append("각주: " + purpose)
        return out
    }

    /// text.txt [전광판 집계] — 기간 · 댓글 읽음 · 반응 n건(n명) · 댓글 n건 / 이니셜 행(로스터 순) / 목록 밖
    @MainActor static func tallyDumpLines(_ model: NotionHubModel) -> [String] {
        let p = ScoreboardLive.period(today: HubClock.today)
        let t = ScoreboardLive.tally(model)
        var out = ["기간 \(p.label) · 댓글 읽음 " + (t == nil ? "no" : "yes") + " · 반응 " + (t.map { "\($0.total)건(\($0.people)명)" } ?? "—")
                   + " · 댓글 " + (t.map { "\($0.notes)건" } ?? "—")]
        for m in MembersProjectsStrip.shown(model) where !m.initials.isEmpty {
            out.append(m.initials + " · 반응 " + (ScoreboardLive.value(t, initials: m.initials, aliases: model.cfg.initialsAliases).map(String.init) ?? "—"))
        }
        var keys = Array((t?.outside ?? [:]).keys); keys.sort()   // 이니셜 가나다(값 순 아님)
        let outside = keys.map { "\($0) \(t?.outside[$0] ?? 0)" }
        out.append("목록 밖: " + (outside.isEmpty ? "—" : outside.joined(separator: ", ")))
        return out
    }
}

/// 'Members' 탭 본문
struct MembersBoardView: View {
    @ObservedObject var model: NotionHubModel
    let notionURL: URL?
    private let sample = ScoreboardSample.load()

    var body: some View {
        ScrollView(.vertical) {
            Inner(model: model, notionURL: notionURL, sample: sample)
                .padding(16)
        }
        .environment(\.cardStyle, .large)
    }

    private struct Inner: View {
        @ObservedObject var model: NotionHubModel
        let notionURL: URL?
        let sample: ScoreboardSample?
        @Environment(\.cardStyle) private var cs

        // 열 폭 — 글자 배율을 따라 (CardStyle.col)
        private var wIni: CGFloat { cs.col(54) }
        private var wGRM: CGFloat { cs.col(92) }
        private var wMM: CGFloat { cs.col(96) }
        private var wSample: CGFloat { cs.col(112) }
        private var wLive: CGFloat { cs.col(150) }

        var body: some View {
            let tally = ScoreboardLive.tally(model)
            let rows = MembersBoardRow.rows(model, sample: sample, tally: tally)
            // 논문 반응 막대 기준 — 그 열 행 값의 최댓값
            let liveMax = Swift.max(1, rows.compactMap(\.live).max() ?? 1)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("연구원 현황판").font(.hub(cs.title + 2, weight: .bold))
                    Text("Members · 함께 보는 활동 흐름 — 평가·순위용 아님").font(.hub(cs.aux)).foregroundStyle(Hub.text3).lineLimit(1)
                    Spacer()
                    if let u = notionURL {
                        Button { NotionLink.open(url: u) } label: { Label("Notion 에서 열기", systemImage: "arrow.up.forward.app").font(.hub(cs.aux)) }
                            .buttonStyle(.plain).foregroundStyle(Hub.text2)
                    }
                }
                // 연구실 합계 줄 — 표보다 먼저(중요한 것 먼저). 무채색
                Text(MembersBoardRow.summary(model, rows: rows, tally: tally)).font(.hub(cs.aux)).foregroundStyle(Hub.text2)
                    .monospacedDigit().fixedSize(horizontal: false, vertical: true)
                    .help(ScoreboardLive.help)
                if sample != nil {
                    // 표 위 띠 — 예시 열이 표본임을 먼저 말한다
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle").font(.hub(cs.aux))
                        Text(MembersBoardRow.band).font(.hub(cs.aux, weight: .semibold))
                        Text(MembersBoardRow.bandAux).font(.hub(cs.tag)).foregroundStyle(Hub.text3).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Hub.text2)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Hub.surface))
                }
                VStack(spacing: 0) {
                    header
                    RowDivider()
                    if rows.isEmpty {
                        Text(model.loading ? "불러오는 중…" : "Members 를 읽지 못함").font(.hub(cs.body)).foregroundStyle(Hub.text2)
                            .padding(cs.empty).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.member.id) { i, r in
                        row(r, liveMax: liveMax)
                        if i < rows.count - 1 { RowDivider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
                Text(MembersBoardRow.source)
                    .font(.hub(cs.tag)).foregroundStyle(Hub.text3).fixedSize(horizontal: false, vertical: true)
                // 목적·한계 한 줄 — 정렬·1등 강조·색 구분은 넣지 않는다
                Text(MembersBoardRow.purpose)
                    .font(.hub(cs.tag)).foregroundStyle(Hub.text2).fixedSize(horizontal: false, vertical: true)
            }
        }

        private var header: some View {
            HStack(spacing: 8) {
                Text("이니셜").frame(width: wIni, alignment: .leading)
                Text("진행 프로젝트").frame(maxWidth: .infinity, alignment: .leading)
                Text("다음 GRM").frame(width: wGRM, alignment: .leading)
                if model.milestones != nil { Text("Milestone").frame(width: wMM, alignment: .leading) }
                HStack(spacing: 4) {
                    Text("논문 반응").lineLimit(1).minimumScaleFactor(0.8)
                    RealChip(label: "실제 " + ScoreboardLive.period(today: HubClock.today).label)
                }
                .frame(width: wLive, alignment: .leading)
                .help(ScoreboardLive.help)
                ForEach(sample?.columns ?? []) { c in
                    HStack(spacing: 4) {
                        Text(c.title).lineLimit(1).minimumScaleFactor(0.8)
                        ExampleChip()
                    }
                    .frame(width: wSample, alignment: .leading)
                    .help("예시 — 표본 자료, 실제 집계 아님 (\(c.unit))")
                }
            }
            .font(.hub(cs.tag, weight: .bold)).foregroundStyle(Hub.text3)
            .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV + 2)
        }

        private func row(_ r: MembersBoardRow, liveMax: Int) -> some View {
            HStack(spacing: 8) {
                Button { model.openInApp(id: r.member.id) } label: {
                    Text(r.member.initials.isEmpty ? "—" : r.member.initials).font(.hub(cs.body, weight: .bold, design: .rounded)).foregroundStyle(Hub.ink)
                        .frame(width: wIni, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Members 페이지 열기")
                Text(r.projects.isEmpty ? "—" : r.projects).font(.hub(cs.aux)).foregroundStyle(r.projects.isEmpty ? Hub.text3 : Hub.text).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading).help(r.projectsHelp)
                Text(r.nextGRM.isEmpty ? "—" : r.nextGRM).font(.hub(cs.aux, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(r.nextGRM.isEmpty ? Hub.text3 : Hub.text2).lineLimit(1)
                    .frame(width: wGRM, alignment: .leading)
                if model.milestones != nil { milestoneCell(r.milestone).frame(width: wMM, alignment: .leading) }
                sampleCell(r.live, max: liveMax, mine: isMe(r.member.initials)).frame(width: wLive, alignment: .leading)
                    .help(ScoreboardLive.help)
                ForEach(Array(r.samples.enumerated()), id: \.offset) { i, v in
                    sampleCell(v, max: sample.map { $0.maxValue($0.columns[i].id) } ?? 1).frame(width: wSample, alignment: .leading)
                }
            }
            .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV + 2)
        }

        @ViewBuilder private func milestoneCell(_ f: MilestoneFile?) -> some View {
            if let f {
                Button { HubLink.nas(f.path).open() } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(Hub.shortDay(f.date)).font(.hub(cs.aux, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Hub.ink)
                        if !f.fromName { Text("수정일").font(.hub(cs.tag - 2)).foregroundStyle(Hub.text3) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help((f.path as NSString).lastPathComponent + (f.fromName ? " — 이름의 날짜" : " — 이름에 날짜가 없어 수정 시각") + " · 클릭하면 열기")
            } else {
                Text("—").font(.hub(cs.aux)).foregroundStyle(Hub.text3)
            }
        }

        /// 본인 행(HubPrefs.me, 옛 이니셜이면 지금 이니셜로) — 막대만 진하게
        private func isMe(_ ini: String) -> Bool {
            let me = HubPrefs.me.uppercased()
            guard !me.isEmpty, !ini.isEmpty else { return false }
            return (model.cfg.initialsAliases[me] ?? me).uppercased() == ini.uppercased()
        }

        /// 예시·실제 칸 — 무채색 막대 + 숫자 (적색·강조색 없음). mine = 본인 행 실제 열만 Hub.ink 막대
        private func sampleCell(_ v: Int?, max: Int, mine: Bool = false) -> some View {
            HStack(spacing: 6) {
                let w = cs.col(56)
                ZStack(alignment: .leading) {
                    Capsule().fill(Hub.fillNeutral).frame(width: w, height: 7)
                    if let v { Capsule().fill(mine ? Hub.ink : Hub.text3).frame(width: Swift.max(3, w * CGFloat(v) / CGFloat(Swift.max(1, max))), height: 7) }
                }
                Text(v.map(String.init) ?? "—").font(.hub(cs.tag, design: .rounded)).monospacedDigit().foregroundStyle(Hub.text2)
            }
        }
    }
}

/// 열 머리의 '실제 M.d–M.d' 칩 — ExampleChip 과 같은 모양(테두리 divider, 글자 text2) (0.39.0 C4)
struct RealChip: View {
    let label: String
    @Environment(\.cardStyle) private var cs
    var body: some View {
        Text(label).font(.hub(cs.tag - 2, weight: .bold)).foregroundStyle(Hub.text2).lineLimit(1).fixedSize()
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(Capsule().stroke(Hub.divider, lineWidth: 1))
    }
}

/// 열 머리의 '예시' 칩 — 테두리만, 무채색
struct ExampleChip: View {
    @Environment(\.cardStyle) private var cs
    var body: some View {
        Text("예시").font(.hub(cs.tag - 2, weight: .bold)).foregroundStyle(Hub.text2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(Capsule().stroke(Hub.divider, lineWidth: 1))
    }
}
