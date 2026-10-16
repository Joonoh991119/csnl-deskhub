import AppKit

/// Notion 링크를 어디서 열지 한 곳에서 정한다 (config notionHub.openLinksIn).
/// auto = Notion 앱이 있고 버전이 minNotionAppVersion 이상이면 앱(notion://), 아니면 웹 브라우저(https).
/// 오래된 Notion 앱은 "Please upgrade your client to keep using Notion." 만 띄우고 페이지를 열지 않는다 (BHL 리뷰 2026-10-13).
enum NotionLink {
    nonisolated(unsafe) static var mode = "auto"
    nonisolated(unsafe) static var minAppVersion = "7.30"

    static func open(id: String) {
        let clean = id.replacingOccurrences(of: "-", with: "")
        NSWorkspace.shared.open(URL(string: (useApp ? "notion://www.notion.so/" : "https://www.notion.so/") + clean)!)
    }

    /// notion.so / notion.com / app.notion.com 링크 → 페이지 ID 로 열기. ID 를 못 찾으면 그 링크 그대로(앱이면 scheme 만 바꿈).
    static func open(url: URL) {
        if let r = url.path.range(of: "[0-9a-fA-F]{32}", options: [.regularExpression, .backwards]) {
            open(id: String(url.path[r])); return
        }
        guard useApp, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { NSWorkspace.shared.open(url); return }
        c.scheme = "notion"
        NSWorkspace.shared.open(c.url ?? url)
    }

    static var useApp: Bool {
        switch mode {
        case "app": return true
        case "web": return false
        default: return appVersion.map { compare($0, minAppVersion) >= 0 } ?? false
        }
    }

    /// 설치된 Notion 앱 버전 (없으면 nil)
    static var appVersion: String? {
        guard let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "notion.id") else { return nil }
        return Bundle(url: u)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? -1 : 1 }
        }
        return 0
    }
}
