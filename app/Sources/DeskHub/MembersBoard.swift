import SwiftUI
import AppKit

// MARK: - Members 탭 = 연구원 현황판 (0.37.0 C7, D-4·D-5)
// 'Members' 탭은 웹뷰 대신 이 표(탭 이름·설정 기본값·config.json 그대로 — 탭 대체 아님, 랩장 15:58).
// 실제 열: 이니셜 · 진행 프로젝트(NAS Memory 폴더, 칩 줄과 같은 member_links) · 다음 GRM(GRM Schedule) · Milestone(NAS MM 폴더 최신 파일 날짜)
// 예시 열: Claude 사용량 · GitHub push · 논문 추천 반응 — Resources/scoreboard-sample.json 의 표본 숫자. 열 머리마다 '예시' 칩 + 표 위 띠 + 무채색 막대.
// 교수님께 실제/예시를 구분해 보이기 위한 것(랩장 10-16 17:22). 적색 없음

/// 예시 열 표본 — 사용자 폴더(~/Library/Application Support/DeskHub/scoreboard-sample.json)가 있으면 그쪽, 아니면 번들. 실패면 예시 열 숨김
struct ScoreboardSample: Codable {
    struct Column: Codable, Identifiable { let id: String; let title: String; let unit: String }
    let note: String
    let columns: [Column]
    let values: [String: [String: Int]]

    static func load() -> ScoreboardSample? {
        let user = Config.directory.appendingPathComponent("scoreboard-sample.json")
        for url in [user, Bundle.main.url(forResource: "scoreboard-sample", withExtension: "json")].compactMap({ $0 }) {
            if let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(ScoreboardSample.self, from: d), !s.columns.isEmpty { return s }
        }
        return nil
    }
    /// 열의 최댓값 — 막대 길이 기준
    func maxValue(_ col: String) -> Int { max(1, values.values.compactMap { $0[col] }.max() ?? 1) }
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
    let samples: [Int?]

    @MainActor static func rows(_ model: NotionHubModel, sample: ScoreboardSample?) -> [MembersBoardRow] {
        MembersProjectsStrip.shown(model).map { m in
            let projs = (model.memberLinkEntry(for: m)?.projects ?? []).map { MemberGroup.display($0.name) }
            let shown = projs.prefix(2).joined(separator: ", ") + (projs.count > 2 ? " +\(projs.count - 2)" : "")
            let g = model.nextGRM(for: m)
            let vals = sample.map { s in s.columns.map { s.values[m.initials]?[$0.id] } } ?? []
            return MembersBoardRow(member: m, projects: shown, projectsHelp: projs.joined(separator: "\n"),
                                   nextGRM: g.map { Hub.shortDay($0.date) + " " + Hub.dday($0.date) } ?? "",
                                   milestone: model.milestones?[m.initials], samples: vals)
        }
    }

    static let band = "예시 — 표본 자료, 실제 집계 아님"

    /// text.txt [Members 전광판]
    @MainActor static func dumpLines(_ model: NotionHubModel) -> [String] {
        let sample = ScoreboardSample.load()
        var cols = ["이니셜", "진행 프로젝트", "다음 GRM"]
        if model.milestones != nil { cols.append("Milestone") }
        cols += (sample?.columns ?? []).map { $0.title + "(예시)" }
        var out = ["열: " + cols.joined(separator: " · ")]
        if sample != nil { out.append("띠: " + band) }
        let dash: (String) -> String = { $0.isEmpty ? "—" : $0 }
        out += rows(model, sample: sample).map { r in
            var f = [dash(r.member.initials), dash(r.projects), dash(r.nextGRM)]
            if model.milestones != nil { f.append(r.milestone?.label ?? "—") }
            f += r.samples.map { $0.map(String.init) ?? "—" }
            return f.joined(separator: " · ")
        }
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

        var body: some View {
            let rows = MembersBoardRow.rows(model, sample: sample)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("연구원 현황판").font(.hub(cs.title + 2, weight: .bold))
                    Text("Members · 진행 프로젝트 · 다음 GRM · Milestone meeting").font(.hub(cs.aux)).foregroundStyle(Hub.text3).lineLimit(1)
                    Spacer()
                    if let u = notionURL {
                        Button { NotionLink.open(url: u) } label: { Label("Notion 에서 열기", systemImage: "arrow.up.forward.app").font(.hub(cs.aux)) }
                            .buttonStyle(.plain).foregroundStyle(Hub.text2)
                    }
                }
                if sample != nil {
                    // 표 위 띠 — 예시 열이 표본임을 먼저 말한다
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle").font(.hub(cs.aux))
                        Text(MembersBoardRow.band).font(.hub(cs.aux, weight: .semibold))
                        Text("오른쪽 '예시' 열은 화면 모양을 보이기 위한 숫자입니다").font(.hub(cs.tag)).foregroundStyle(Hub.text3).lineLimit(1)
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
                        row(r)
                        if i < rows.count - 1 { RowDivider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
                Text("진행 프로젝트 = NAS Memory 폴더 · 다음 GRM = GRM Schedule · Milestone = NAS MM 폴더의 최신 파일 날짜(이름에 날짜가 없으면 '수정일')")
                    .font(.hub(cs.tag)).foregroundStyle(Hub.text3).fixedSize(horizontal: false, vertical: true)
            }
        }

        private var header: some View {
            HStack(spacing: 8) {
                Text("이니셜").frame(width: wIni, alignment: .leading)
                Text("진행 프로젝트").frame(maxWidth: .infinity, alignment: .leading)
                Text("다음 GRM").frame(width: wGRM, alignment: .leading)
                if model.milestones != nil { Text("Milestone").frame(width: wMM, alignment: .leading) }
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

        private func row(_ r: MembersBoardRow) -> some View {
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

        /// 예시 칸 — 무채색 막대 + 숫자 (적색·강조색 없음)
        private func sampleCell(_ v: Int?, max: Int) -> some View {
            HStack(spacing: 6) {
                let w = cs.col(56)
                ZStack(alignment: .leading) {
                    Capsule().fill(Hub.fillNeutral).frame(width: w, height: 7)
                    if let v { Capsule().fill(Hub.text3).frame(width: Swift.max(3, w * CGFloat(v) / CGFloat(Swift.max(1, max))), height: 7) }
                }
                Text(v.map(String.init) ?? "—").font(.hub(cs.tag, design: .rounded)).monospacedDigit().foregroundStyle(Hub.text2)
            }
        }
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
