import AppKit
import SwiftUI

// MARK: - 메뉴 막대 한 줄 (디자인 계획 D11 — §2 D '조각', §3 P2-12)
// 창을 안 열어도 메뉴 막대에서: ■ 경고 수 + 가장 급한 것 + 다음 일정.
// 폭 단계: L "■1 BK21 제출 9h · 다음 14:00 SAC" / M "■1 BK21 9h" / S "■1" / off (아이콘만).
// 노치가 있는 맥에서 메뉴 막대가 좁으면 M·S 로 — 설정은 UserDefaults DeskHub.menuLine (메뉴에서 바꿈).
// `DeskHub --line <dir>` 로 세 단계 문자열을 <dir>/line.txt 에.

enum MenuLineStep: String, CaseIterable { case L, M, S, off
    var title: String { switch self { case .L: return "길게"; case .M: return "보통"; case .S: return "짧게"; case .off: return "아이콘만" } }
}

enum MenuBarLine {
    static var step: MenuLineStep {
        get { MenuLineStep(rawValue: UserDefaults.standard.string(forKey: "DeskHub.menuLine") ?? "") ?? .M }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "DeskHub.menuLine") }
    }

    /// 짧은 제목 — 괄호·부제 떼고 앞 두 단어
    static func short(_ t: String) -> String {
        let s = t.replacingOccurrences(of: "\\s*\\(.*?\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "◆ ", with: "")
        // 경보 문구 틀의 ' · ' 구분자는 낱말로 세지 않는다 ('NAS · 연결 안 됨' → 'NAS 연결', 0.34.0)
        let words = s.split(separator: " ").filter { $0 != "·" }.prefix(2).joined(separator: " ")
        return words.count > 14 ? String(words.prefix(14)) + "…" : words
    }

    @MainActor
    static func text(_ m: NotionHubModel, step: MenuLineStep, now: Date) -> String {
        guard step != .off else { return "" }
        let set = AlertEngine.evaluate(m, cal: m.todayCalendar, now: now, me: HubPrefs.me)
        let w = set.alerts.filter { $0.level == .warning }
        let head: String = w.first.map { a in
            let rel = a.due.map { compact($0, now: now) } ?? ""
            return "■\(w.count) " + short(a.title) + (rel.isEmpty ? "" : " " + rel)
        } ?? ""
        let next = (m.todayCalendar?.upcoming(days: 2) ?? []).first { $0.start > now }
        let nextText = next.map { "다음 " + Hub.time($0.start) + " " + short(Hub.canonicalNames($0.title)) } ?? ""
        switch step {
        case .S: return w.isEmpty ? "" : "■\(w.count)"
        case .M: return head.isEmpty ? nextText : head
        case .L: return [head, nextText].filter { !$0.isEmpty }.joined(separator: " · ")
        case .off: return ""
        }
    }

    /// 9h · 35m · D-2 처럼 가장 짧게
    static func compact(_ d: Date, now: Date) -> String {
        let mins = Int(d.timeIntervalSince(now) / 60)
        if mins < 0 { return "지남" }
        if mins < 60 { return "\(mins)m" }
        if mins < 48 * 60 { return "\(mins / 60)h" }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now), to: Calendar.current.startOfDay(for: d)).day ?? 0
        return "D-\(days)"
    }

    /// 상태 막대 단추에 그린다 — 아이콘 + 글자(있으면). ■ 가 있으면 숫자만 signal 색
    @MainActor
    static func apply(_ item: NSStatusItem, model: NotionHubModel?, now: Date) {
        guard let b = item.button else { return }
        let t = model.map { text($0, step: step, now: now) } ?? ""
        b.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "DeskHub")
        b.image?.isTemplate = true
        if t.isEmpty {
            item.length = NSStatusItem.squareLength
            b.attributedTitle = NSAttributedString(string: "")
            b.imagePosition = .imageOnly
        } else {
            item.length = NSStatusItem.variableLength
            let a = NSMutableAttributedString(string: " " + t, attributes: [.font: NSFont.menuBarFont(ofSize: 0)])
            if let r = t.range(of: "■\\d+", options: .regularExpression) {
                let ns = NSRange(r, in: t)
                a.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: ns.location + 1, length: ns.length))
            }
            b.attributedTitle = a
            b.imagePosition = .imageLeading
        }
        b.toolTip = model.map { m in MenuLineStep.allCases.filter { $0 != .off }.map { text(m, step: $0, now: now) }.first { !$0.isEmpty } ?? "경보 없음" }
    }
}
