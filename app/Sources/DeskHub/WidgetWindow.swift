import AppKit
import SwiftUI

/// 대시보드 색: 바닥판과 카드 — 테마(Theme.current)와 라이트/다크를 따른다
enum Palette {
    static var backdrop: NSColor { Theme.ns(\.backdrop) }
    static var card: NSColor { Theme.ns(\.card) }
    static var cardBorder: NSColor { Theme.ns(\.cardBorder) }
}

/// 동적 NSColor 로 칠하는 layer 뷰. `.cgColor` 를 한 번 넣어 두면 그 시점 외형으로 굳어
/// 자동(라이트↔다크) 전환 뒤 글자와 배경이 어긋난다 → AppKit 이 외형이 바뀔 때마다 부르는 updateLayer 에서 다시 칠한다.
final class AppearanceFillView: NSView {
    var fill: NSColor? { didSet { needsDisplay = true } }
    var stroke: NSColor? { didSet { needsDisplay = true } }
    var strokeWidth: CGFloat = 0 { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        guard let l = layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            l.backgroundColor = fill?.cgColor
            l.borderColor = stroke?.cgColor
        }
        l.borderWidth = strokeWidth
        l.cornerRadius = cornerRadius
        l.cornerCurve = .continuous
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    /// 맨 위에 얹는 테두리가 카드 안 클릭을 가로채지 않도록 (예전 NSView 테두리는 모든 클릭을 삼켰다)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 바탕화면 레벨 공통 패널
class DesktopPanel: NSPanel {
    static let backdropLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    static let cardLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
    let fixedLevel: NSWindow.Level

    init(frame: NSRect, level: NSWindow.Level, styleMask: NSWindow.StyleMask) {
        fixedLevel = level
        super.init(contentRect: frame, styleMask: styleMask, backing: .buffered, defer: false)
        isFloatingPanel = false          // (level 을 normal 로 되돌리므로 level 보다 먼저)
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true   // 비활성 패널에서도 호버 레일(RowRail)이 뜨게 (D1)
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        isOpaque = false
        backgroundColor = .clear
        animationBehavior = .none
        titleVisibility = .hidden
        isExcludedFromWindowsMenu = true
        self.level = level
    }

    /// 단축키로 꺼냈을 때: 다른 창 위(.floating)에 띄운다. 숨기거나 메뉴로 "제자리" 하면 바탕화면 층으로 돌아간다
    var peeking = false { didSet { level = peeking ? .floating : fixedLevel } }

    override func orderFront(_ sender: Any?) {
        let want = peeking ? NSWindow.Level.floating : fixedLevel
        if level != want { level = want }
        super.orderFront(sender)
    }
    override var canBecomeMain: Bool { false }

    /// 창 내용을 PNG 로 저장 (디버그/검증용)
    func snapshot(to url: URL) {
        let wid = CGWindowID(windowNumber)
        guard let img = CGWindowListCreateImage(.null, .optionIncludingWindow, wid, [.boundsIgnoreFraming, .bestResolution]) else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }
}

/// 화면 전체를 덮는 불투명 바닥판 — 배경화면이 보이지 않게 한다.
final class BackdropWindow: DesktopPanel {
    init(frame: NSRect) {
        super.init(frame: frame, level: DesktopPanel.backdropLevel, styleMask: [.borderless, .nonactivatingPanel])
        ignoresMouseEvents = false
        hasShadow = false
        let v = AppearanceFillView(frame: NSRect(origin: .zero, size: frame.size))
        v.fill = Palette.backdrop
        v.autoresizingMask = [.width, .height]
        contentView = v
    }
    override var canBecomeKey: Bool { false }
}

/// 위젯 카드 창. 바탕화면 아이콘 위, 일반 앱 창 아래.
final class WidgetWindow: DesktopPanel {
    let slotID: String
    let kind: WidgetKind
    var onFrameChange: ((NSRect) -> Void)?
    private var container: NSView!
    private var hosting: NSView?

    init(slotID: String, kind: WidgetKind, frame: NSRect, cornerRadius: CGFloat, opaque: Bool, shadow: Bool) {
        self.slotID = slotID
        self.kind = kind
        super.init(frame: frame, level: DesktopPanel.cardLevel, styleMask: [.borderless, .nonactivatingPanel, .resizable])
        hasShadow = shadow || !opaque
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = false
        minSize = NSSize(width: 300, height: 220)

        container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = cornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.autoresizingMask = [.width, .height]

        let bg: NSView
        if opaque {
            let f = AppearanceFillView(frame: container.bounds)
            f.fill = Palette.card
            bg = f
        } else {
            bg = GlassBackground.make(frame: container.bounds, cornerRadius: cornerRadius)
        }
        bg.autoresizingMask = [.width, .height]
        container.addSubview(bg)

        let border = AppearanceFillView(frame: container.bounds)
        border.cornerRadius = cornerRadius
        border.strokeWidth = 1
        border.stroke = Palette.cardBorder
        border.autoresizingMask = [.width, .height]
        container.addSubview(border)

        contentView = container

        NotificationCenter.default.addObserver(self, selector: #selector(frameChanged), name: NSWindow.didMoveNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(frameChanged), name: NSWindow.didEndLiveResizeNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(frameChanged), name: NSWindow.didResizeNotification, object: self)
    }

    /// refresh = 글자 배율·색 프리셋이 바뀌면 본문을 다시 만든다(DisplayRefresh, 0.37.0 C3). 허브 창은 스스로 .id 를 걸어 false,
    /// Claude 창은 쓰던 질문을 지키려고 false(위젯이 HubDisplay 관찰). 캘린더 모드는 CalendarModeBox 라 다시 만들어도 유지
    func setContent<V: View>(_ view: V, refresh: Bool = true) {
        hosting?.removeFromSuperview()
        let h = NSHostingView(rootView: refresh ? AnyView(DisplayRefresh(view)) : AnyView(view))
        h.frame = container.bounds
        h.autoresizingMask = [.width, .height]
        container.addSubview(h, positioned: .below, relativeTo: container.subviews.last)
        hosting = h
    }

    /// 사용자가 실제로 클릭했을 때만 키 창이 된다 (앱 실행/활성화만으로 키 입력을 가로채지 않도록).
    override var canBecomeKey: Bool {
        guard let e = NSApp.currentEvent else { return false }
        switch e.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .keyDown, .scrollWheel:
            return true
        default:
            return false
        }
    }

    @objc private func frameChanged() { onFrameChange?(frame) }

    func clampToScreen() {
        guard let screen = self.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        var f = frame
        f.size.width = min(f.width, vf.width)
        f.size.height = min(f.height, vf.height)
        if f.maxX > vf.maxX { f.origin.x = vf.maxX - f.width }
        if f.maxY > vf.maxY { f.origin.y = vf.maxY - f.height }
        if f.minX < vf.minX { f.origin.x = vf.minX }
        if f.minY < vf.minY { f.origin.y = vf.minY }
        if f != frame { setFrame(f, display: true) }
    }
}

enum GlassBackground {
    /// macOS 26 의 NSGlassEffectView 가 있으면 쓰고, 아니면 NSVisualEffectView.
    static func make(frame: NSRect, cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26.0, *),
           let cls = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let v = cls.init(frame: frame)
            if v.responds(to: NSSelectorFromString("setCornerRadius:")) {
                v.setValue(cornerRadius, forKey: "cornerRadius")
            }
            if v.responds(to: NSSelectorFromString("setTintColor:")) {
                v.setValue(NSColor(name: nil) { app in
                    app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? NSColor(white: 0.10, alpha: 0.35)
                        : NSColor(white: 1.0, alpha: 0.45)
                }, forKey: "tintColor")
            }
            return v
        }
        let v = NSVisualEffectView(frame: frame)
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = cornerRadius
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        return v
    }
}

// MARK: - 드래그 영역 / 크기조절 손잡이

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override var mouseDownCanMoveWindow: Bool { false }
    }
}

struct ResizeGrip: NSViewRepresentable {
    func makeNSView(context: Context) -> GripView { GripView() }
    func updateNSView(_ nsView: GripView, context: Context) {}
    final class GripView: NSView {
        private var startFrame: NSRect = .zero
        private var startMouse: NSPoint = .zero
        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.secondaryLabelColor.withAlphaComponent(0.55).setStroke()
            for i in 0..<3 {
                let off = CGFloat(4 + i * 4)
                let p = NSBezierPath()
                p.move(to: NSPoint(x: bounds.maxX - off, y: bounds.minY + 2))
                p.line(to: NSPoint(x: bounds.maxX - 2, y: bounds.minY + off))
                p.lineWidth = 1.2
                p.stroke()
            }
        }
        override func mouseDown(with event: NSEvent) {
            guard let w = window else { return }
            startFrame = w.frame; startMouse = NSEvent.mouseLocation
        }
        override func mouseDragged(with event: NSEvent) {
            guard let w = window else { return }
            let now = NSEvent.mouseLocation
            let dx = now.x - startMouse.x, dy = now.y - startMouse.y
            var f = startFrame
            f.size.width = max(w.minSize.width, startFrame.width + dx)
            let newH = max(w.minSize.height, startFrame.height - dy)
            f.origin.y = startFrame.maxY - newH
            f.size.height = newH
            w.setFrame(f, display: true)
        }
    }
}
