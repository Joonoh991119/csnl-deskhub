import AppKit
import SwiftUI

/// 색 테마. Resources/themes.json (scripts/build_themes.py 가 공식 팔레트에서 만든 것) + 사용자 폴더의 themes.json 을 합친다.
/// 토큰 이름은 Hub/Palette 와 같다. 값은 "#rrggbb" 또는 "#rrggbbaa".
struct ThemeVariant: Codable {
    var card, backdrop, surface, heroBG, text, text2, text3, ink, ok, signal, onAccent, cardBorder, divider, fillNeutral: String
}

struct ThemeDef: Codable {
    var name: String
    var source: String?
    var alwaysDark: Bool?
    var light: ThemeVariant
    var dark: ThemeVariant
}

enum Theme {
    /// 지금 쓰는 테마 id (config.theme). 바꾸면 AppDelegate 가 위젯을 다시 만든다.
    nonisolated(unsafe) static var currentID = "csnl"
    nonisolated(unsafe) static var all: [String: ThemeDef] = load()
    /// 0.42.0 C7 — 새 팔레트 7종은 기존 뒤에 (메뉴 순서)
    static let order = ["csnl", "catppuccin", "rosepine", "nord", "solarized", "gruvbox", "tokyonight",
                        "primer", "carbon", "radix", "tokyonight-daynight", "catppuccin-frappe", "catppuccin-macchiato", "everforest"]
    /// 시험 훅 DESKHUB_THEME=<id> (0.42.0 C7) — 시작할 때만, config 에 쓰지 않는다. 없는 id 면 무시
    static var hookID: String? {
        guard let v = ProcessInfo.processInfo.environment["DESKHUB_THEME"], !v.isEmpty, all[v] != nil else { return nil }
        return v
    }

    /// 색 프리셋 (0.37.0 C3, HubDisplay.colorPreset 의 사본 — 칠하는 순간 어느 스레드에서나 읽도록). AppDelegate.applyTheme 가 맞춘다
    nonisolated(unsafe) static var preset = "default"
    /// 'High Contrast' 프리셋이면 contrast, 아니면 config 의 테마. 메뉴 'Theme' 목록(ids)에는 contrast 가 없다
    static var current: ThemeDef { preset == "contrast" ? contrast : (all[currentID] ?? all["csnl"] ?? builtin) }
    static var ids: [String] { order.filter { all[$0] != nil } + all.keys.filter { !order.contains($0) }.sorted() }

    static func variant(_ appearance: NSAppearance) -> ThemeVariant {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? current.dark : current.light
    }

    /// 외형(라이트/다크)에 따라 바뀌는 NSColor — 테마는 칠하는 순간의 Theme.current 를 읽는다
    static func ns(_ key: KeyPath<ThemeVariant, String>) -> NSColor {
        NSColor(name: nil) { app in color(hex: variant(app)[keyPath: key]) }
    }
    static func color(_ key: KeyPath<ThemeVariant, String>) -> Color { Color(nsColor: ns(key)) }

    static func color(hex: String) -> NSColor {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return .magenta }
        let rgba = h.count == 8 ? v : (v << 8 | 0xFF)
        return NSColor(srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255, green: CGFloat((rgba >> 16) & 0xFF) / 255,
                       blue: CGFloat((rgba >> 8) & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
    }

    static let userFile = Config.directory.appendingPathComponent("themes.json")

    static func load() -> [String: ThemeDef] {
        var out: [String: ThemeDef] = ["csnl": builtin]
        let dec = JSONDecoder()
        for url in [Bundle.main.url(forResource: "themes", withExtension: "json"), userFile].compactMap({ $0 }) {
            guard let d = try? Data(contentsOf: url), let m = try? dec.decode([String: ThemeDef].self, from: d) else { continue }
            out.merge(m) { _, new in new }
        }
        return out
    }

    /// High Contrast 프리셋 (0.37.0 C3 — 계획 값). all·order 에 넣지 않는다(메뉴 'Theme' 그대로). 0.42.0 C7 부터 build_themes.py 가 이 블록의 hex 를 읽어 같은 대비 검사(text ≥7 · text3 ≥3 · 나머지 ≥4.5)
    static let contrast = ThemeDef(
        name: "High Contrast", source: "DeskHub 0.37.0 색 프리셋", alwaysDark: nil,
        light: ThemeVariant(card: "#ffffff", backdrop: "#d9dce2", surface: "#f4f5f7", heroBG: "#dde6f2", text: "#000000", text2: "#2e333b",
                            text3: "#4f5560", ink: "#12304f", ok: "#0f5a44", signal: "#9e1f1b", onAccent: "#ffffff",
                            cardBorder: "#00000040", divider: "#00000033", fillNeutral: "#0000001a"),
        dark: ThemeVariant(card: "#0b0d11", backdrop: "#000000", surface: "#1a1d24", heroBG: "#172235", text: "#ffffff", text2: "#d0d4da",
                           text3: "#aab0b9", ink: "#b8d4f2", ok: "#8fd3b2", signal: "#ff8f86", onAccent: "#000000",
                           cardBorder: "#ffffff40", divider: "#ffffff33", fillNeutral: "#ffffff1f"))

    /// 번들 파일이 없어도 쓰는 기본 테마 (디자인 스펙 2026-10-12 의 세 색)
    static let builtin = ThemeDef(
        name: "CSNL", source: "DeskHub 디자인 스펙 2026-10-12", alwaysDark: nil,
        light: ThemeVariant(card: "#ffffff", backdrop: "#e6e8ed", surface: "#f2f4f7", heroBG: "#e3eaf3", text: "#1c1e22", text2: "#5a6069",
                            text3: "#808690", ink: "#1f3b5c", ok: "#1c6b54", signal: "#a8302d", onAccent: "#ffffff",
                            cardBorder: "#1c1e2214", divider: "#1c1e2214", fillNeutral: "#1c1e2212"),
        dark: ThemeVariant(card: "#1c1f26", backdrop: "#0f1217", surface: "#262932", heroBG: "#222c3a", text: "#e6e7ea", text2: "#a6aab2",
                           text3: "#7f848d", ink: "#9ebde0", ok: "#73b899", signal: "#ee8a82", onAccent: "#15171c",
                           cardBorder: "#e6e7ea1f", divider: "#e6e7ea1a", fillNeutral: "#e6e7ea12"))
}
