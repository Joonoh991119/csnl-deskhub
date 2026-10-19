import SwiftUI
import AppKit

// MARK: - Joint projects (0.42.0 C6, R9-d — 랩장 JOP 10-19 '공동 프로젝트 섹션을 열어. 당장은 공동연구가 없으니 연구실 플러그인 개발에 대해서
// 버전과 리뷰가 트래킹되면 좋겠음 (좌측 하단에 … 담당자명, review 완료자명, review 대기명이 이니셜로 간단히)')
// 데이터 계약: scripts/plugin_status.py 가 <grantsFile 폴더>/plugins/plugin_status.json 에 쓰고(세션 사이클 하루 1회), 앱은 읽기만.
// 시험 훅 DESKHUB_PLUGINS=<파일>. 못 읽으면 이 카드만 한 줄로 접힌다(다른 카드에 번지지 않음). 적색 없음 — 완료 Hub.ok, 대기 Hub.text2.

struct PluginStatusRow: Codable, Hashable, Identifiable {
    var id: String
    var version: String
    var owner: String
    var done: [String]
    var waiting: [String]
    var note: String?
    enum CodingKeys: String, CodingKey { case id, version, owner, done, waiting, note }
    init(id: String, version: String, owner: String, done: [String], waiting: [String], note: String? = nil) {
        self.id = id; self.version = version; self.owner = owner; self.done = done; self.waiting = waiting; self.note = note
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        version = (try? c.decode(String.self, forKey: .version)) ?? "?"
        owner = (try? c.decode(String.self, forKey: .owner)) ?? ""
        done = (try? c.decode([String].self, forKey: .done)) ?? []
        waiting = (try? c.decode([String].self, forKey: .waiting)) ?? []
        note = try? c.decode(String.self, forKey: .note)
    }
}

enum JointProjects {
    struct File { var rows: [PluginStatusRow]; var generated: Date?; var errors: [String] }
    enum Load { case ok(File), missing(String), corrupt(String) }

    static func path(_ cfg: NotionHubConfig) -> String {
        if let v = ProcessInfo.processInfo.environment["DESKHUB_PLUGINS"], !v.isEmpty { return (v as NSString).expandingTildeInPath }
        return (((cfg.grantsFile as NSString).deletingLastPathComponent as NSString).appendingPathComponent("plugins") as NSString)
            .appendingPathComponent("plugin_status.json")
    }
    /// 관대 읽기 — 행 하나가 깨져도 나머지는 살린다
    static func load(_ path: String) -> Load {
        guard let d = FileManager.default.contents(atPath: path) else { return .missing("파일 없음") }
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], (o["schema"] as? Int) == 1,
              let raw = o["rows"] as? [[String: Any]] else { return .corrupt("형식 오류") }
        let rows = raw.compactMap { r -> PluginStatusRow? in
            guard let data = try? JSONSerialization.data(withJSONObject: r) else { return nil }
            return try? JSONDecoder().decode(PluginStatusRow.self, from: data)
        }
        let gen = (o["generated"] as? String).flatMap { s -> Date? in
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.date(from: s)
        }
        return .ok(File(rows: rows, generated: gen, errors: (o["errors"] as? [String]) ?? []))
    }
    /// 대기가 있는 행 먼저, 그다음 id 순
    static func sorted(_ rows: [PluginStatusRow]) -> [PluginStatusRow] {
        rows.sorted { a, b in
            if a.waiting.isEmpty != b.waiting.isEmpty { return !a.waiting.isEmpty }
            return a.id < b.id
        }
    }
    /// 'csnl-deskhub · 0.42.0 · JOP · 완료 BHL · 대기 JYK,SMJ' — 빈 칸은 칸째 생략 (text.txt·fixture·도움말 공용)
    static func line(_ r: PluginStatusRow) -> String {
        var p = [r.id, r.version.isEmpty ? "?" : r.version]
        if !r.owner.isEmpty { p.append(r.owner) }
        if !r.done.isEmpty { p.append("완료 " + r.done.joined(separator: ",")) }
        if !r.waiting.isEmpty { p.append("대기 " + r.waiting.joined(separator: ",")) }
        return p.joined(separator: " · ")
    }
    /// text-check kind jp-row — 'id=;v=;owner=;done=A,B;waiting=C'
    static func check(_ input: String) -> String {
        var k: [String: String] = [:]
        for part in input.components(separatedBy: ";") {
            let p = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if p.count == 2 { k[p[0].trimmingCharacters(in: .whitespaces)] = p[1] }
        }
        func list(_ s: String?) -> [String] { (s ?? "").components(separatedBy: ",").filter { !$0.isEmpty } }
        return line(PluginStatusRow(id: k["id"] ?? "", version: k["v"] ?? "", owner: k["owner"] ?? "", done: list(k["done"]), waiting: list(k["waiting"])))
    }
}

extension NotionHubModel {
    /// refresh 끝 — 메인 스레드 밖에서 읽는다
    func loadJointProjects() async {
        let p = JointProjects.path(cfg)
        switch await Task.detached(priority: .utility, operation: { JointProjects.load(p) }).value {
        case .ok(let f): jointRows = f.rows; jointGenerated = f.generated; jointErrors = f.errors; jointNote = nil
        case .missing(let why), .corrupt(let why): jointNote = why
        }
    }
    var jointTag: Freshness? { Freshness.content(jointGenerated, cycle: 1, today: today, help: "plugin_status.json 생성 시각 (세션 사이클 하루 1회)") }
    /// text.txt [Joint projects]
    func jointDumpLines() -> [String] {
        let f = DateFormatter(); f.dateFormat = "M.d HH:mm"
        var out = ["읽기 " + (jointNote.map { "읽지 못함(\($0))" } ?? "ok") + " · 생성 " + (jointGenerated.map { f.string(from: $0) } ?? "—")
                   + " · 행 \(jointRows.count) · 오류 \(jointErrors.count)"]
        out += JointProjects.sorted(jointRows).map(JointProjects.line)
        return out
    }
}

/// 허브 열1 바닥(Apps 아래) 카드 — 한 줄 = 이름 · 버전 · 담당 · ✓ 완료 · 🕘 대기. ≤8행 + '더 보기'
struct JointProjectsCard: View {
    @ObservedObject var model: NotionHubModel
    @ObservedObject private var expansion = HubExpansion.shared
    @Environment(\.cardStyle) private var cs
    static let maxRows = 8
    static let key = "joint"

    var body: some View {
        let rows = JointProjects.sorted(model.jointRows)
        let open = expansion.isOpen(Self.key)
        VStack(alignment: .leading, spacing: cs.gap) {
            SectionTitle(card: "joint", fresh: model.jointNote == nil ? model.jointTag : nil)
            VStack(alignment: .leading, spacing: 0) {
                if model.jointNote != nil && rows.isEmpty {
                    Text("plugin_status.json 을 읽지 못함 · NAS").font(.hub(cs.aux)).foregroundStyle(Hub.text2).lineLimit(1)
                        .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(JointProjects.path(model.cfg))
                } else {
                    let shown = open ? rows : Array(rows.prefix(Self.maxRows))
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, r in
                        row(r)
                        if i < shown.count - 1 { RowDivider() }
                    }
                    CardFooter(caption: CardMetas.caption("joint", model), toggleKey: Self.key, more: max(rows.count - Self.maxRows, 0))
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
        }
    }

    private func row(_ r: PluginStatusRow) -> some View {
        let me = HubPrefs.me.uppercased()
        func ini(_ x: String) -> Color { !me.isEmpty && x.uppercased() == me ? Hub.ink : Hub.text2 }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(r.id).font(.hub(cs.aux, weight: .semibold)).foregroundStyle(Hub.text).lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)
            Text(r.version.isEmpty ? "?" : r.version).font(.hub(cs.tag, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(Hub.ink).lineLimit(1).fixedSize()
            if !r.owner.isEmpty {
                Text(r.owner).font(.hub(cs.tag, weight: .bold, design: .rounded)).foregroundStyle(ini(r.owner)).lineLimit(1).fixedSize()
                    .help("담당 " + r.owner)
            }
            Spacer(minLength: 4)
            if !r.done.isEmpty {
                HStack(spacing: 2) {
                    Image(systemName: "checkmark.circle").foregroundStyle(Hub.ok)
                    Text(r.done.joined(separator: ",")).foregroundStyle(Hub.ok)
                }
                .font(.hub(cs.tag, weight: .medium)).lineLimit(1).fixedSize()
                .help("리뷰 완료 " + r.done.joined(separator: ", "))
            }
            if !r.waiting.isEmpty {
                HStack(spacing: 2) {
                    Image(systemName: "clock").foregroundStyle(Hub.text2)
                    ForEach(Array(r.waiting.enumerated()), id: \.offset) { i, w in
                        Text(w + (i < r.waiting.count - 1 ? "," : "")).foregroundStyle(ini(w))
                    }
                }
                .font(.hub(cs.tag, weight: .medium)).lineLimit(1).fixedSize()
                .help("리뷰 대기 " + r.waiting.joined(separator: ", "))
            }
        }
        .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
        .help(JointProjects.line(r) + ((r.note ?? "").isEmpty ? "" : " — " + (r.note ?? "")))
    }
}
