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

/// 연구 탭 태그 색 (0.43.0 C4, #49) — 테마 토큰(ink·surface·text2)에서 만든다. 16진 색 상수 없음.
/// 색상(hue) 고정 7개 45·95·140·180·215·255·295° — 적색 계열(330°–40°)은 쓰지 않는다. 채도는 테마 ink 의 채도를
/// 밝은 표면이면 0.75–0.95, 어두운 표면이면 0.45–0.60 으로 자른다(계획의 0.40–0.80 은 Nord 라이트에서 두 색 거리 26 — 거리 검사 ≥40 을 못 넘어 바꿈).
/// 명도: 밝은 표면이면 1.0 에서 내려가며, 어두운 표면이면 max(ink 명도, 0.92) 에서 올라가며(1.0 이면 채도를 낮춤)
/// '표면 위 그 색 14% 바탕' 대비 4.5 이상이고 적색 판정(lint_signal: r>140·r−g>70·r−b>70)이 아닌 첫 값. 끝내 못 맞추면 text2.
/// 검사: text-check `tagcolor`(fixtures/research-check.tsv) — 테마 15개 × 라이트·다크, 대비·적색·서로 다른 두 색 sRGB 거리 ≥40
enum TagPalette {
    static let hues: [Double] = [45, 95, 140, 180, 215, 255, 295]
    static let tint = 0.14
    struct RGB: Equatable { var r, g, b: Double }

    static func rgb(hex: String) -> RGB {
        let c = Theme.color(hex: hex)
        return RGB(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
    }
    /// HSV → sRGB (Python colorsys.hsv_to_rgb 와 같은 식)
    static func hsv(_ h: Double, _ s: Double, _ v: Double) -> RGB {
        if s == 0 { return RGB(r: v, g: v, b: v) }
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return RGB(r: v, g: t, b: p)
        case 1: return RGB(r: q, g: v, b: p)
        case 2: return RGB(r: p, g: v, b: t)
        case 3: return RGB(r: p, g: q, b: v)
        case 4: return RGB(r: t, g: p, b: v)
        default: return RGB(r: v, g: p, b: q)
        }
    }
    static func toHSV(_ c: RGB) -> (h: Double, s: Double, v: Double) {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b)
        let v = mx
        guard mx > 0, mx != mn else { return (0, 0, v) }
        let s = (mx - mn) / mx
        let rc = (mx - c.r) / (mx - mn), gc = (mx - c.g) / (mx - mn), bc = (mx - c.b) / (mx - mn)
        var h = c.r == mx ? bc - gc : (c.g == mx ? 2 + rc - bc : 4 + gc - rc)
        h = (h / 6).truncatingRemainder(dividingBy: 1); if h < 0 { h += 1 }
        return (h, s, v)
    }
    static func luminance(_ c: RGB) -> Double {
        func lin(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
    static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB { RGB(r: a.r * (1 - t) + b.r * t, g: a.g * (1 - t) + b.g * t, b: a.b * (1 - t) + b.b * t) }
    /// lint_signal.py 의 적색 판정과 같은 식(0–255)
    static func isRed(_ c: RGB) -> Bool { let r = c.r * 255, g = c.g * 255, b = c.b * 255; return r > 140 && r - g > 70 && r - b > 70 }
    static func distance(_ a: RGB, _ b: RGB) -> Double { (pow((a.r - b.r) * 255, 2) + pow((a.g - b.g) * 255, 2) + pow((a.b - b.b) * 255, 2)).squareRoot() }
    /// 바탕 = 표면 위 그 색 14%
    static func background(_ c: RGB, surface: RGB) -> RGB { mix(surface, c, tint) }

    /// slot 의 색과 맞춤 여부(false = text2 대체)
    static func compute(_ slot: Int, _ v: ThemeVariant) -> (rgb: RGB, ok: Bool) {
        let surf = rgb(hex: v.surface), ink = toHSV(rgb(hex: v.ink))
        let dark = luminance(surf) < 0.18
        let (lo, hi) = dark ? (0.45, 0.60) : (0.75, 0.95)
        var s = min(max(ink.s, lo), hi)
        var bri = dark ? max(ink.v, 0.92) : 1.0
        let hue = hues[((slot % hues.count) + hues.count) % hues.count] / 360
        for _ in 0..<300 {
            let c = hsv(hue, s, bri)
            if contrast(c, background(c, surface: surf)) >= 4.5 && !isRed(c) { return (c, true) }
            if dark {
                if bri < 1 { bri = min(1, bri + 0.01) } else if s > 0.15 { s -= 0.02 } else { break }
            } else {
                if bri > 0.05 { bri -= 0.01 } else { break }
            }
        }
        return (rgb(hex: v.text2), false)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: RGB] = [:]
    /// 칠하는 순간의 테마 변형으로 — (surface·ink·text2·slot) 로 기억
    static func color(_ slot: Int, variant v: ThemeVariant) -> NSColor {
        let key = "\(v.surface)|\(v.ink)|\(v.text2)|\(slot)"
        lock.lock()
        let hit = cache[key]
        lock.unlock()
        let c = hit ?? compute(slot, v).rgb
        if hit == nil { lock.lock(); cache[key] = c; lock.unlock() }
        return NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1)
    }
    static func ns(_ slot: Int) -> NSColor { NSColor(name: nil) { app in color(slot, variant: Theme.variant(app)) } }

    /// text-check `tagcolor` — 한 테마의 라이트·다크 모두 7색이 대비 ≥4.5 · 적색 아님 · 서로 다른 두 색 거리 ≥40 이면 'ok 7', 아니면 실패 목록
    static func check(_ def: ThemeDef) -> String {
        var fails: [String] = []
        for (mode, v) in [("light", def.light), ("dark", def.dark)] {
            let cs = (0..<hues.count).map { compute($0, v) }
            for (i, c) in cs.enumerated() where !c.ok { fails.append("\(mode) \(i) 대비") }
            for i in 0..<cs.count { for j in (i + 1)..<cs.count where distance(cs[i].rgb, cs[j].rgb) < 40 {
                fails.append("\(mode) \(i)-\(j) 거리 \(Int(distance(cs[i].rgb, cs[j].rgb)))")
            } }
        }
        return fails.isEmpty ? "ok \(hues.count)" : fails.joined(separator: ", ")
    }
}
