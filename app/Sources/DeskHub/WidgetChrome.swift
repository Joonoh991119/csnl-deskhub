import SwiftUI
import AppKit

/// 위젯 공통 틀: 헤더(아이콘·제목·버튼) + 내용 + 크기조절 손잡이
struct WidgetChrome<Content: View, Actions: View>: View {
    let style: WidgetStyle
    var subtitle: String? = nil
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content
    /// 이 창의 상태(꺼냄·확대) — WidgetWindow.setContent 가 넣는다 (0.43.0 C7, #51). 없으면 창 단추 없음
    @Environment(\.windowChrome) private var chrome

    init(style: WidgetStyle, subtitle: String? = nil,
         @ViewBuilder actions: @escaping () -> Actions, @ViewBuilder content: @escaping () -> Content) {
        self.style = style; self.subtitle = subtitle; self.actions = actions; self.content = content
    }
    init(kind: WidgetKind, subtitle: String? = nil,
         @ViewBuilder actions: @escaping () -> Actions, @ViewBuilder content: @escaping () -> Content) {
        self.init(style: WidgetStyle(kind: kind), subtitle: subtitle, actions: actions, content: content)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                WindowDragArea()
                HStack(spacing: 10) {
                    // 창 단추(닫기·내리기·확대) — 꺼낸 상태에서만 (결정 D-7). 무채색(결정 D-6)
                    if let c = chrome { WindowControls(state: c) }
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.color(\.ink))
                            .frame(width: 26, height: 26)
                        Image(systemName: style.symbol)
                            .font(.hub(14, weight: .semibold))
                            .foregroundStyle(Theme.color(\.onAccent))
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(style.title)
                            .font(.hub(15, weight: .semibold))
                            .lineLimit(1)
                        if let s = subtitle, !s.isEmpty {
                            Text(s)
                                .font(.hub(11))
                                .foregroundStyle(Hub.text2)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        actions()
                        // 모든 카드 공통: 한 번에 치우기 (단축키와 같은 동작)
                        IconButton(symbol: "eye.slash", help: "모두 숨기기 (\(DeskHubNotice.hotkeyLabel))") {
                            NotificationCenter.default.post(name: DeskHubNotice.hideAll, object: nil)
                        }
                    }
                    .buttonStyle(HeaderButtonStyle())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(height: 46)
            Divider().opacity(0.5)
            ZStack(alignment: .bottomTrailing) {
                content()
                ResizeGrip()
                    .frame(width: 18, height: 18)
                    .padding(4)
            }
        }
        .foregroundStyle(Hub.text)
    }
}

/// 카드 안 버튼 → AppDelegate 로 보내는 알림
enum DeskHubNotice {
    static let hideAll = Notification.Name("kr.ac.snu.csnl.deskhub.hideAll")
    /// 제목 막대(머리) 두 번 클릭 — object = 그 창 (0.43.0 C7, #51)
    static let titleDoubleClick = Notification.Name("kr.ac.snu.csnl.deskhub.titleDoubleClick")
    /// 창 단추 — object = 슬롯 id. 확대/원래 크기 · 바탕화면 층으로 내리기
    static let windowZoom = Notification.Name("kr.ac.snu.csnl.deskhub.windowZoom")
    static let windowLower = Notification.Name("kr.ac.snu.csnl.deskhub.windowLower")
    nonisolated(unsafe) static var hotkeyLabel = "⌃⌥D"
}

struct HeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.hub(12, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? Hub.text.opacity(0.14) : Hub.fillNeutral)
            )
            .foregroundStyle(Hub.text)
            .contentShape(Rectangle())
    }
}

/// 헤더 아이콘 버튼 (툴팁 포함)
struct IconButton: View {
    let symbol: String
    let help: String
    var label: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                if let l = label { Text(l).lineLimit(1).fixedSize() }
            }
            .fixedSize()
        }
        .help(help)
    }
}

// MARK: - 창 단추·제목 막대 더블클릭 (0.43.0 C7, #51)

/// 창 하나의 화면 상태 — WidgetWindow 가 peeking·확대가 바뀔 때 맞춘다. 머리(WidgetChrome)가 환경으로 받아 단추를 보이거나 숨긴다
@MainActor
final class WindowChromeState: ObservableObject {
    let slotID: String
    @Published var peeking = false
    @Published var zoomed = false
    init(slotID: String) { self.slotID = slotID }
}

private struct WindowChromeKey: EnvironmentKey { static let defaultValue: WindowChromeState? = nil }
extension EnvironmentValues {
    var windowChrome: WindowChromeState? {
        get { self[WindowChromeKey.self] }
        set { self[WindowChromeKey.self] = newValue }
    }
}

enum WindowChrome {
    enum DoubleClick: String { case zoom, lower, none }
    /// 시스템 설정 '제목 막대를 두 번 클릭하면' — AppleActionOnDoubleClick(Maximize·Fill·Zoom·값 없음 → 확대, Minimize → 내리기, None·Do Nothing·모르는 값 → 없음),
    /// 값이 없을 때만 옛 키 AppleMiniaturizeOnDoubleClick(true → 내리기). 순수 함수 — text-check `dblclick`
    static func doubleClickAction(action: String?, legacyMiniaturize: Bool) -> DoubleClick {
        let a = (action ?? "").trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return legacyMiniaturize ? .lower : .zoom }
        switch a.lowercased() {
        case "maximize", "fill", "zoom": return .zoom
        case "minimize": return .lower
        default: return .none
        }
    }
    /// 이 맥의 설정 — 시험 훅 DESKHUB_DBLCLICK=<값> 이 있으면 그 값(옛 키는 무시)
    static var current: DoubleClick {
        if let v = ProcessInfo.processInfo.environment["DESKHUB_DBLCLICK"] { return doubleClickAction(action: v, legacyMiniaturize: false) }
        let d = UserDefaults.standard
        return doubleClickAction(action: d.string(forKey: "AppleActionOnDoubleClick"), legacyMiniaturize: d.bool(forKey: "AppleMiniaturizeOnDoubleClick"))
    }
}

/// 머리 왼쪽 원 3개 — × 모두 숨기기 · − 바탕화면 층으로 내리기 · ⤢ 이 창 확대/원래 크기. 꺼낸 상태에서만 보인다.
/// 신호등 색이 아니라 무채색(fillNeutral 채움 + divider 테두리, 글리프 text2 · 마우스 올리면 text) — 적색은 마감·오류에만 (결정 D-6)
struct WindowControls: View {
    @ObservedObject var state: WindowChromeState
    @State private var hover = false
    var body: some View {
        if state.peeking {
            HStack(spacing: 8) {
                dot("xmark", help: "모두 숨기기 (\(DeskHubNotice.hotkeyLabel)로 다시)") {
                    NotificationCenter.default.post(name: DeskHubNotice.hideAll, object: nil)
                }
                dot("minus", help: "바탕화면 층으로 내리기") {
                    NotificationCenter.default.post(name: DeskHubNotice.windowLower, object: state.slotID)
                }
                dot(state.zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    help: state.zoomed ? "원래 크기 — 확대 중 옮기거나 크기를 바꾼 것은 저장되지 않습니다" : "이 창 확대 (제목 막대 두 번 클릭과 같음)") {
                    NotificationCenter.default.post(name: DeskHubNotice.windowZoom, object: state.slotID)
                }
            }
            .onHover { hover = $0 }
        }
    }
    private func dot(_ symbol: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Hub.fillNeutral)
                Circle().stroke(Hub.divider, lineWidth: 1)
                Image(systemName: symbol).font(.system(size: 8, weight: .semibold)).foregroundStyle(hover ? Hub.text : Hub.text2)
            }
            .frame(width: 12, height: 12)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
