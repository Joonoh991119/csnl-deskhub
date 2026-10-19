import SwiftUI
import AppKit

// 만든 앱 — Resources/apps.json (사용자 폴더 apps.json 이 있으면 그쪽). 버전은 실행 때 Info.plist 에서 읽는다 (랩장 10-16: "생성된 앱들 배경화면에").
// 원본 목록은 .claude/skills/workspace-report 의 보고서와 같다. 앱이 늘면 apps.json 에 한 줄.
struct MadeApp: Codable, Identifiable {
    let name: String; let path: String; let source: String; let desc: String
    var id: String { name }
    var expanded: String { (path as NSString).expandingTildeInPath }
    var exists: Bool { FileManager.default.fileExists(atPath: expanded) }
    var version: String {
        guard let d = NSDictionary(contentsOfFile: expanded + "/Contents/Info.plist"), let v = d["CFBundleShortVersionString"] as? String else { return "" }
        return v
    }
}

enum MadeApps {
    private struct File: Codable { let apps: [MadeApp]; let report: String? }
    static func load() -> (apps: [MadeApp], report: String?) {
        let user = Config.directory.appendingPathComponent("apps.json")
        for url in [user, Bundle.main.url(forResource: "apps", withExtension: "json")].compactMap({ $0 }) {
            if let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: d) { return (f.apps, f.report) }
        }
        return ([], nil)
    }
    /// 레일 한 줄 요약: "3개 · DeskHub 0.33.0 · LabClean · CSNL DM Archive"
    static var summary: String {
        let a = load().apps
        return "\(a.count)개" + (a.isEmpty ? "" : " · " + a.map { $0.name + ($0.version.isEmpty ? "" : " " + $0.version) }.joined(separator: " · "))
    }
}

/// 만든 앱 카드 — 이름·버전(없으면 '설치됨'/'없음')·한 줄 설명·소스. 클릭하면 앱을 연다. 머리 오른쪽은 워크스페이스 구조 보고서(HTML).
struct AppsCard: View {
    private let data = MadeApps.load()
    /// 랩 허브만 — 머리 한 줄('만든 앱 · n개')만, 목록은 '▸ 더 보기' (0.37.0 C2 — 일정과 무관해 기본 접힘)
    var nearOnly = false
    @Environment(\.cardStyle) private var cs
    @ObservedObject private var expansion = HubExpansion.shared
    var body: some View {
        let cut = nearOnly ? HubNear.apps(data.apps) : nil
        let apps = cut.map { $0.shown(open: expansion.isOpen("apps")) } ?? data.apps
        VStack(alignment: .leading, spacing: cs.gap) {
            SectionTitle(card: "apps", hint: "연구실에서 만든 앱 \(data.apps.count)개", trailing: data.report.map { FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath) ? "구조 보고서" : nil } ?? nil,
                         fresh: nearOnly ? Freshness.content(CardMetas.appsFileDate, cycle: 30, today: HubClock.today, help: "apps.json 수정일") : nil) {
                if let r = data.report { NSWorkspace.shared.open(URL(fileURLWithPath: (r as NSString).expandingTildeInPath)) }
            }
            VStack(spacing: 0) {
                if data.apps.isEmpty {
                    Text("apps.json 없음").font(.hub(cs.body)).foregroundStyle(Hub.text2).padding(cs.empty).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(apps.enumerated()), id: \.element.id) { i, a in
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: a.expanded)) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(a.name).font(.hub(cs.body, weight: .semibold)).lineLimit(1)
                            Text(a.exists ? (a.version.isEmpty ? "설치됨" : a.version) : "없음")
                                .font(.hub(cs.tag, weight: .bold, design: .rounded)).foregroundStyle(a.exists ? Hub.ink : Hub.text3)
                            Text(a.desc).font(.hub(cs.aux)).foregroundStyle(Hub.text2).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(a.source).font(.hub(cs.tag)).foregroundStyle(Hub.text3).lineLimit(1)
                        }
                        .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help(a.path + " · 클릭하면 열기")
                    if i < apps.count - 1 { RowDivider() }
                }
                // 접힘에선 머리 바로 아래 바만 — 위 구분선 없이
                if let cut { CardFooter(caption: CardMetas.appsCaption(), toggleKey: "apps", more: cut.more, divider: !apps.isEmpty) }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
        }
    }
}
