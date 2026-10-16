import SwiftUI
import AppKit

/// 위젯 공통 틀: 헤더(아이콘·제목·버튼) + 내용 + 크기조절 손잡이
struct WidgetChrome<Content: View, Actions: View>: View {
    let style: WidgetStyle
    var subtitle: String? = nil
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

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
