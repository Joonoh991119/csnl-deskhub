import SwiftUI

// MARK: - 공정 모델 (디자인 계획 D7 — docs/design-plan-2026-10-14.md §2 B 공정 보드)
// 랩의 일은 데이터 종류가 아니라 반복 공정이다: GRM · 그랜트 보고 · 논문 추천 · 실험 · 학회.
// 공정·단계의 목록과 이름은 Resources/pipelines.json (사용자 폴더 pipelines.json 이 있으면 그쪽) — 여기서 빼면 칸이 사라진다.
// 단계 판정은 이 파일의 순수 함수. 판정할 근거가 없으면 '?'(unknown) — 적색을 쓰지 않는다(안돈 신뢰 조건).
// `DeskHub --dump-pipeline <dir>` 로 텍스트 확인.
// 칸 클릭 = 원본 (UX smartwatch-20, 0.34.0): 링크가 없거나 없는 NAS 경로를 가리키는 칸은 행 대체 링크로 채운다(fill) — 눌러도 반응 없는 칸을 없앤다.
//   열리는 기존 링크는 바꾸지 않는다. 덤프는 칸마다 →종류(notion·nas·url·…, 없는 NAS 는 nas✗, 링크 없음 →—).

struct PipelineDef: Codable {
    struct Stage: Codable { let id: String; let label: String }
    let id: String
    let title: String
    let stages: [Stage]
}

enum PipelineDefs {
    private struct File: Codable { let pipelines: [PipelineDef] }
    static func load() -> [PipelineDef] {
        let user = Config.directory.appendingPathComponent("pipelines.json")
        for url in [user, Bundle.main.url(forResource: "pipelines", withExtension: "json")].compactMap({ $0 }) {
            if let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d) { return f.pipelines }
        }
        return []
    }
}

struct StageState {
    enum Kind: Equatable { case done, todo, blocked, unknown, progress(Double), future }
    let kind: Kind
    var note: String = ""
    /// 막힌 칸의 담당 이니셜 (결정 21: 공용 맥에서 보일지)
    var owner: String = ""
    /// 막힌 칸에 붙는 행동 하나 (AppsScript 이름 등 — 뷰가 그린다)
    var action: String? = nil
    var link: HubLink? = nil

    var mark: String {
        switch kind {
        case .done: return "✓"
        case .todo: return "—"
        case .blocked: return "■"
        case .unknown: return "?"
        case .progress(let f): return "\(Int((f * 100).rounded()))%"
        case .future: return "·"
        }
    }
}

struct PipelineRow: Identifiable {
    let id: String
    let pipeline: String
    let title: String
    var cells: [(stage: PipelineDef.Stage, state: StageState)]
    /// 지난 일(24h 넘음) — 회색
    var past: Bool = false
    var due: Date? = nil
    var blockedCount: Int { cells.filter { $0.state.kind == .blocked }.count }
}

enum PipelineEngine {
    @MainActor
    static func evaluate(_ m: NotionHubModel, defs: [PipelineDef], now: Date, me: String) -> [PipelineRow] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        func days(_ d: Date) -> Int { cal.dateComponents([.day], from: today, to: cal.startOfDay(for: d)).day ?? 99 }
        var rows: [PipelineRow] = []
        for def in defs {
            switch def.id {
            case "grm":
                // 지난 GRM 1회 + 다음 2회
                let slots = (m.lastGRM.map { [$0] } ?? []) + m.grm.filter { $0.date >= today && $0.id != m.lastGRM?.id }.prefix(2)
                for g in slots {
                    // 대체 링크: NAS 단계는 그날 폴더(아직 없으면 Notion — 없는 경로는 비프음), Notion 단계는 그 GRM 페이지. 폴더 확인은 행마다 한 번
                    let dir = grmDir(g, m)
                    let nasFallback: HubLink = FileManager.default.fileExists(atPath: dir) ? .nas(dir) : .notion(g.id)
                    let cells = def.stages.map { s in
                        (s, fill(grmStage(s.id, g, m, now: now, days: days(g.date)), grmNASStages.contains(s.id) ? nasFallback : .notion(g.id)))
                    }
                    rows.append(PipelineRow(id: "grm-" + g.id, pipeline: def.id, title: "GRM \(Hub.day(g.date)) " + (g.presenters.isEmpty ? "미정" : m.initialsList(g.presenters)),
                                            cells: cells, past: days(g.date) < -1, due: g.date))
                }
            case "grant":
                let grantsDir = (m.cfg.grantsFile as NSString).deletingLastPathComponent
                for g in m.grants {
                    // 대체 링크: 그랜트 폴더(제출 칸과 같은 경로 식)가 있으면 그 폴더, 없으면 grants_schedule.json 폴더
                    let gdir = m.cfg.nasGRMRoot.replacingOccurrences(of: "/GRM", with: "") + "/" + g.folder
                    let rowLink: HubLink = .nas(!g.folder.isEmpty && FileManager.default.fileExists(atPath: gdir) ? gdir : grantsDir)
                    let cells = def.stages.map { s -> (PipelineDef.Stage, StageState) in
                        switch s.id {
                        case "submit":
                            if let d = g.due { return (s, StageState(kind: days(d) <= 1 ? .blocked : .future, note: Hub.relative(d, now: now, hasTime: false), link: rowLink)) }
                            return (s, StageState(kind: .unknown, note: g.needsCheck(today: today) ? "일정 확인 필요" : "미정", link: rowLink))
                        default:
                            // 수집·컨펌·승인은 report SSOT 확인 행이 있을 때만 판정 (결정 22) — 지금은 '?'
                            return (s, StageState(kind: .unknown, link: rowLink))
                        }
                    }
                    rows.append(PipelineRow(id: "grant-" + g.id, pipeline: def.id, title: "그랜트 " + g.title, cells: cells, due: g.due))
                }
            case "papers":
                let latest = m.papers.compactMap(\.sentAt).max()
                let mine = m.papers.filter { me.isEmpty || $0.researcher == me }
                let reacted = mine.filter { p in (m.paperComments[p.id] ?? []).contains { $0.isReaction && (me.isEmpty || $0.who == me) } }.count
                // 댓글 = 사람이 쓴 댓글만 — '같이 읽자' 제안·취소는 세지 않는다 (0.39.0 C5)
                let notes = m.papers.reduce(0) { $0 + (m.paperComments[$1.id] ?? []).filter(\.isNote).count }
                let cells = def.stages.map { s -> (PipelineDef.Stage, StageState) in
                    switch s.id {
                    case "produce":
                        guard let d = latest else { return (s, StageState(kind: .unknown)) }
                        return days(d) >= -10 ? (s, StageState(kind: .done, note: Hub.day(d)))
                            : (s, StageState(kind: .blocked, note: "P23 \(Hub.day(d)) 정지", link: .url(URL(string: "https://github.com/Joonoh991119/csnl-admin/issues/19")!)))
                    case "deliver": return (s, StageState(kind: m.papers.isEmpty ? .todo : .done, note: "\(m.papers.count)편", link: .notion(m.cfg.paperRecDB)))
                    case "react": return (s, StageState(kind: mine.isEmpty ? .unknown : .progress(Double(reacted) / Double(mine.count)), note: "\(me.isEmpty ? "" : me + " ")\(reacted)/\(mine.count)"))
                    case "comment": return (s, StageState(kind: notes > 0 ? .done : .todo, note: "\(notes)"))
                    default: return (s, StageState(kind: .unknown))
                    }
                }.map { ($0.0, fill($0.1, .notion(m.cfg.paperRecDB))) }   // 묶음 행 — 칸 대체 링크는 추천 DB (예외로 명시: 덤프 →notion(DB))
                rows.append(PipelineRow(id: "papers", pipeline: def.id, title: "논문 추천", cells: cells))
            case "experiment":
                for x in m.experiments {
                    // 대체 링크: study URL(Prolific), 없으면 예약 Notion 페이지
                    let rowLink: HubLink? = x.url.map(HubLink.url) ?? x.notionID.map(HubLink.notion)
                    let cells = def.stages.map { s -> (PipelineDef.Stage, StageState) in
                        switch s.id {
                        case "reserve": return (s, StageState(kind: .done))
                        case "recruit":
                            if let f = fraction(x.detail) { return (s, StageState(kind: f >= 1 ? .done : .progress(f), note: x.detail.components(separatedBy: " · ").first ?? "")) }
                            return (s, StageState(kind: .unknown, note: x.detail))
                        case "collect":
                            if x.status.lowercased() == "paused" { return (s, StageState(kind: .blocked, note: "Paused", owner: x.owner, link: x.url.map(HubLink.url))) }
                            return (s, StageState(kind: x.status.isEmpty ? .unknown : .progress(0.5), note: x.status))
                        default: return (s, StageState(kind: .todo))
                        }
                    }.map { ($0.0, fill($0.1, rowLink)) }
                    rows.append(PipelineRow(id: "exp-" + x.id, pipeline: def.id, title: "실험 \(x.owner.isEmpty ? "" : x.owner + " ")\(x.source) · \(x.title)", cells: cells))
                }
            case "conference":
                let confFile = ((m.cfg.grantsFile as NSString).deletingLastPathComponent as NSString).appendingPathComponent("conferences_upcoming.json")
                for c in m.conferences.prefix(3) {
                    // 대체 링크: 학회 링크, 없으면 Notion 페이지 (NAS 파일에서 온 행 'file-…' 은 Notion 페이지가 없으므로 그 파일)
                    let rowLink: HubLink = c.link.map(HubLink.url) ?? (c.id.hasPrefix("file-") ? .nas(confFile) : .notion(c.id))
                    let cells = def.stages.map { s -> (PipelineDef.Stage, StageState) in
                        switch s.id {
                        case "abstract":
                            guard let d = c.deadline else { return (s, StageState(kind: .unknown)) }
                            if days(d) < 0 { return (s, StageState(kind: .unknown, note: "마감 지남")) }
                            return (s, StageState(kind: days(d) <= 3 ? .blocked : .future, note: Hub.relative(d, now: now, hasTime: false), link: c.link.map(HubLink.url)))
                        case "present": return (s, StageState(kind: .future, note: Hub.range(c.start, c.end)))
                        default: return (s, StageState(kind: .unknown))
                        }
                    }.map { ($0.0, fill($0.1, rowLink)) }
                    rows.append(PipelineRow(id: "conf-" + c.id, pipeline: def.id, title: "학회 " + c.conference, cells: cells, due: c.deadline))
                }
            default: break
            }
        }
        // 막힘 있는 공정 위 → 마감 가까운 순 (지난 것은 아래)
        return rows.sorted { a, b in
            if a.past != b.past { return !a.past }
            if (a.blockedCount > 0) != (b.blockedCount > 0) { return a.blockedCount > 0 }
            return (a.due ?? .distantFuture) < (b.due ?? .distantFuture)
        }
    }

    /// "19/20 제출" → 0.95
    static func fraction(_ s: String) -> Double? {
        guard let r = s.range(of: "(\\d+)\\s*/\\s*(\\d+)", options: .regularExpression) else { return nil }
        let parts = s[r].split(separator: "/").map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        guard parts.count == 2, parts[1] > 0 else { return nil }
        return parts[0] / parts[1]
    }

    /// 칸 클릭 = 원본: 링크가 열리면 그대로, 없거나 없는 NAS 경로면 대체 링크로 (대체도 없으면 그대로)
    static func fill(_ s: StageState, _ fallback: HubLink?) -> StageState {
        if let l = s.link, l.opens { return s }
        guard let fallback else { return s }
        var t = s; t.link = fallback; return t
    }
    /// NAS 파일로 판정하는 GRM 단계 — 대체 링크가 그날 폴더(없으면 Notion)
    static let grmNASStages: Set<String> = ["slides", "transcript", "magazine", "blitz"]
    /// GRM 그날 NAS 폴더 — <nasGRMRoot>/<yyyy>/<yyyyMMdd>
    @MainActor
    static func grmDir(_ g: GRMSlot, _ m: NotionHubModel) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"
        return "\(m.cfg.nasGRMRoot)/\(Calendar.current.component(.year, from: g.date))/\(f.string(from: g.date))"
    }

    /// GRM 한 회의 단계 판정. NAS 파일 존재로 슬라이드·녹취·매거진·Blitz 를 본다
    @MainActor
    static func grmStage(_ id: String, _ g: GRMSlot, _ m: NotionHubModel, now: Date, days n: Int) -> StageState {
        let dir = grmDir(g, m)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: g.date)!
        let talked = now >= noon
        switch id {
        case "notice":
            if g.notified { return StageState(kind: .done) }
            return n >= 0 && n <= 5 ? StageState(kind: .blocked, note: n == 0 ? "오늘" : "D-\(n)", owner: "", action: "공지 초안", link: .notion(g.id))
                : StageState(kind: talked ? .unknown : .todo, link: .notion(g.id))
        case "abstract":
            if g.abstractDone { return StageState(kind: .done, link: g.docURL.map(HubLink.url)) }
            return n >= 0 && n <= 3 ? StageState(kind: .blocked, note: n == 0 ? "오늘" : "D-\(n)", link: .notion(g.id)) : StageState(kind: talked ? .unknown : .todo)
        case "slides":
            let deck = files.first { name in !name.hasPrefix("PB_") && !name.hasPrefix("~$") && [".pptx", ".pdf", ".key"].contains { name.lowercased().hasSuffix($0) } }
            if let d = deck { return StageState(kind: .done, note: (d as NSString).deletingPathExtension, link: .nas(dir + "/" + d)) }
            if n == 0 && !talked { return StageState(kind: .blocked, note: "아직 없음", link: .nas(dir)) }
            return StageState(kind: talked ? .unknown : .todo, link: .nas(dir))
        case "talk":
            return talked ? StageState(kind: .done) : StageState(kind: .future, note: n == 0 ? "오늘" : "D-\(n)")
        case "transcript":
            let tdir = dir + "/transcript"
            let t = ((try? FileManager.default.contentsOfDirectory(atPath: tdir)) ?? []).first { $0.hasPrefix("GRM_transcript_") }
            if let t { return StageState(kind: .done, link: .nas(tdir + "/" + t)) }
            return StageState(kind: talked ? .todo : .future)
        case "minutes":
            if let note = m.minutes.first(where: { $0.date.map { Calendar.current.isDate($0, inSameDayAs: g.date) } ?? false }) {
                return StageState(kind: .done, link: .notion(note.id))
            }
            if let p = m.minutesPending, Calendar.current.isDate(p, inSameDayAs: g.date) { return StageState(kind: .todo, note: "정리 전") }
            return StageState(kind: talked ? .todo : .future)
        case "magazine":
            if let u = NotionHubModel.magazineURL(dir: m.cfg.magazineDir, date: g.date) { return StageState(kind: .done, link: .nas(u.path)) }
            return StageState(kind: talked ? .unknown : .future)
        case "blitz":
            if let pb = files.first(where: { $0.hasPrefix("PB_") && $0.lowercased().hasSuffix(".pptx") }) {
                let count = m.blitzDate.map { Calendar.current.isDate($0, inSameDayAs: g.date) } == true ? "\(m.blitz.count)편" : ""
                return StageState(kind: .done, note: count, link: .nas(dir + "/" + pb))
            }
            return StageState(kind: talked ? .unknown : .future)
        default:
            return StageState(kind: .unknown)
        }
    }

    @MainActor
    static func dump(_ rows: [PipelineRow], now: Date) -> String {
        var out = ["공정 \(Hub.day(now)) \(Hub.time(now)) — \(rows.count)행 · 막힘 \(rows.filter { $0.blockedCount > 0 }.count)"]
        for r in rows {
            // 칸마다 링크 종류 — 논문 추천(묶음 행)의 Notion 링크는 DB 라 →notion(DB), 링크 없음 →—
            let cells = r.cells.map { c -> String in
                let to: String
                if let l = c.state.link {
                    if r.pipeline == "papers", case .notion = l { to = "notion(DB)" } else { to = l.kindLabel }
                } else { to = "—" }
                return "[\(c.stage.label) \(c.state.mark)\(c.state.note.isEmpty ? "" : " " + c.state.note) →\(to)]"
            }.joined(separator: "─")
            out.append((r.past ? "(지난) " : "") + r.title + "  " + cells)
        }
        return out.joined(separator: "\n")
    }
}
