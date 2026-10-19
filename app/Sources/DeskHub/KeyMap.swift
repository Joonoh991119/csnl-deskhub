import SwiftUI

// MARK: - 키보드 층 (디자인 계획 D6 — docs/design-plan-2026-10-14.md §3 P1-6)
// 카드 창은 클릭했을 때만 키 창이 된다(WidgetWindow.canBecomeKey) — 그 뒤로 아래 키가 먹는다.
// 전역 키는 KeyLayer 가 바로 처리하고, 뷰마다 다른 키(j/k/Enter/d/a/Space/\/Esc)는 KeyBus 로 흘려 보낸다.

struct KeyEvent: Equatable {
    let key: String
    let seq: Int
}

@MainActor
final class KeyBus: ObservableObject {
    static let shared = KeyBus()
    @Published private(set) var event: KeyEvent?
    @Published var showHelp = false
    private var seq = 0
    func send(_ key: String) { seq += 1; event = KeyEvent(key: key, seq: seq) }
}

/// 키 표 — ? 로 띄우는 시트와 같은 내용
enum KeyMap {
    static let global: [(String, String)] = [
        ("1 – 8", "뷰 바꾸기 (관제탑 · 공정 보드 · 안내판 · 랩 허브 · 오늘 집중 · GRM 주간 · 나 · 앰비언트)"),
        ("r", "지금 새로고침"),
        ("?", "이 키 표 열기·닫기"),
    ]
    static let tower: [(String, String)] = [
        ("j / k", "경보 아래·위로 고르기"),
        ("Enter", "고른 경보의 원본 열기"),
        ("Space", "고른 경보와 관련된 섹션 펼치기"),
        ("d", "고른 리마인더 끝남 (6초 안에 되돌리기)"),
        ("a", "고른 경보 확인함 (□·· 만, 7일)"),
        ("\\", "펼친 섹션 접기"),
        ("Esc", "고르기 해제 · 접기 · 키 표 닫기"),
    ]
}

/// 뷰 최상단에 한 번 — 포커스를 잡고 키를 받는다
struct KeyLayer: ViewModifier {
    @ObservedObject var model: NotionHubModel
    @ObservedObject private var bus = KeyBus.shared
    @ObservedObject private var store = ViewModeStore.shared
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear { focused = true }
            .onKeyPress(phases: .down) { press in handle(press) }
            .overlay(alignment: .center) { if bus.showHelp { KeyHelpSheet().transition(.opacity) } }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let r = handleKey(press)
        if r == .handled { UsageLog.action("key") }
        return r
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // 텍스트 입력 중(댓글 칸 등)에는 가로채지 않는다 — 수정키가 붙은 입력도 그대로 보낸다
        if press.modifiers.contains(.command) || press.modifiers.contains(.control) { return .ignored }
        if let w = NSApp.keyWindow, w.firstResponder is NSTextView { return .ignored }
        switch press.key {
        case .escape:
            // 8주 띠(0.40.0 C4) → '글자' 판(0.37.0 C3) → 키 표 순으로 닫는다
            if StatusBand.shared.open { StatusBand.shared.close() }
            else if HubDisplay.shared.panelOpen { withAnimation(.easeOut(duration: 0.12)) { HubDisplay.shared.panelOpen = false } }
            else if bus.showHelp { withAnimation(.easeOut(duration: 0.12)) { bus.showHelp = false } } else { bus.send("esc") }
            return .handled
        case .return: bus.send("enter"); return .handled
        case .space: bus.send("space"); return .handled
        default: break
        }
        let c = press.characters
        if let n = Int(c), n >= 1, n <= HubViewMode.allCases.count {
            store.mode = HubViewMode.allCases[n - 1]; return .handled
        }
        switch c {
        case "?": withAnimation(.easeOut(duration: 0.12)) { bus.showHelp.toggle() }; return .handled
        case "r": Task { await model.refresh() }; return .handled
        case "j", "k", "d", "a", "\\": bus.send(c); return .handled
        default: return .ignored
        }
    }
}

extension View {
    func keyLayer(_ model: NotionHubModel) -> some View { modifier(KeyLayer(model: model)) }
}

/// ? 시트 — 가운데 작은 판
struct KeyHelpSheet: View {
    @ObservedObject private var store = ViewModeStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("키보드").font(.hub(15, weight: .bold))
                Spacer()
                Text("카드를 한 번 클릭한 뒤 · Esc 닫기").font(.hub(11)).foregroundStyle(Hub.text3)
            }
            section("어디서나", KeyMap.global)
            if store.mode == .tower { section("관제탑", KeyMap.tower) }
        }
        .padding(18)
        .frame(width: 460)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Hub.surface).shadow(color: .black.opacity(0.25), radius: 18, y: 6))
    }

    private func section(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.hub(11.5, weight: .bold)).foregroundStyle(Hub.text2)
            ForEach(rows, id: \.0) { k, v in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(k).font(.hub(12, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Hub.divider))
                        .frame(width: 70, alignment: .leading)
                    Text(v).font(.hub(12.5)).foregroundStyle(Hub.text)
                }
            }
        }
    }
}
