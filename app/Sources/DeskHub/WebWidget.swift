import SwiftUI
import WebKit
import AppKit

/// 위젯 하나가 들고 있는 WKWebView 와 상태.
final class WebController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let processPool = WKProcessPool()

    let kind: WidgetKind
    let homeURL: URL
    let webView: WKWebView
    @Published var title: String = ""
    @Published var currentURL: URL?
    @Published var isLoading = false
    @Published var failure: String?
    /// 로드 완료 후 한 번 실행할 JS (Claude 자동 전송 등)
    var pendingScript: String?
    private var popups: [NSWindow] = []
    private var midnightTask: Task<Void, Never>?

    private var loadedOnce = false

    init(kind: WidgetKind, homeURL: URL, userAgent: String, zoom: Double = 1.0, userScript: String? = nil, lazy: Bool = false) {
        self.kind = kind
        self.homeURL = homeURL
        let cfg = WKWebViewConfiguration()
        if let js = userScript {
            cfg.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        cfg.processPool = WebController.processPool
        cfg.websiteDataStore = .default()
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.customUserAgent = userAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")
        if zoom != 1.0 { webView.pageZoom = zoom }
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if !lazy { ensureLoaded() }
    }

    /// 처음 한 번만 홈을 로드 (lazy 컨트롤러용)
    func ensureLoaded() {
        guard !loadedOnce else { return }
        loadedOnce = true
        webView.load(URLRequest(url: homeURL))
    }

    func load(_ url: URL) { webView.load(URLRequest(url: url)) }
    func home() { load(homeURL) }

    /// 매일 자정에 홈으로 되돌린다 (캘린더 '오늘' 유지용)
    func reloadHomeAtMidnight() {
        midnightTask?.cancel()
        midnightTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let now = Date()
                guard let next = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 10), matchingPolicy: .nextTime) else { return }
                let ns = UInt64(max(60, next.timeIntervalSince(now)) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                if Task.isCancelled { return }
                self?.home()
            }
        }
    }
    func reload() {
        if webView.url == nil { home() } else { webView.reload() }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if !["http", "https", "about", "blob", "data", "javascript"].contains(scheme) {
            // notion:// claude:// plaud:// mailto: 등은 시스템에 넘긴다
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType, let url = navigationResponse.response.url {
            // 다운로드(파일 내보내기 등)는 기본 브라우저로
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        failure = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        currentURL = webView.url
        title = webView.title ?? ""
        if let js = pendingScript {
            pendingScript = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.webView.evaluateJavaScript(js) { _, _ in }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        if (error as NSError).code != NSURLErrorCancelled { failure = error.localizedDescription }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        if (error as NSError).code != NSURLErrorCancelled { failure = error.localizedDescription }
    }

    // MARK: WKUIDelegate — 팝업(구글 로그인 등)

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680), configuration: configuration)
        popup.customUserAgent = webView.customUserAgent
        popup.uiDelegate = self
        popup.navigationDelegate = self
        let win = NSWindow(contentRect: popup.frame,
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "\(kind.defaultTitle) — 로그인"
        win.contentView = popup
        win.level = .floating
        win.isReleasedWhenClosed = false
        win.center()
        popups.append(win)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let idx = popups.firstIndex(where: { $0.contentView === webView }) {
            popups[idx].orderOut(nil)
            popups.remove(at: idx)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = kind.defaultTitle; a.informativeText = message
        a.runModal(); completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = kind.defaultTitle; a.informativeText = message
        a.addButton(withTitle: "확인"); a.addButton(withTitle: "취소")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.canChooseDirectories = parameters.allowsDirectories
        p.canChooseFiles = true
        NSApp.activate(ignoringOtherApps: true)
        p.begin { resp in completionHandler(resp == .OK ? p.urls : nil) }
    }
}

struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// 로딩 바 + 실패 안내가 붙은 웹 영역
struct WebArea: View {
    @ObservedObject var controller: WebController
    var body: some View {
        ZStack(alignment: .top) {
            WebViewRepresentable(webView: controller.webView)
            if controller.isLoading {
                ProgressView().progressViewStyle(.linear).frame(height: 2).padding(.horizontal, 0)
            }
            if let f = controller.failure {
                VStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark").font(.hub(28)).foregroundStyle(.secondary)
                    Text("페이지를 불러오지 못했습니다").font(.headline)
                    Text(f).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("다시 시도") { controller.reload() }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
            }
        }
    }
}

// MARK: - Notion / Plaud 위젯

struct NotionWidget: View {
    @ObservedObject var controller: WebController
    let title: String
    let accountHint: String

    /// 위젯용 Notion 손질: 사이드바 숨김(토글 가능), "데스크톱 앱에서 여시겠습니까?" 팝업 자동 닫기
    static let tidyScript = """
    (function(){
      if (window.__deskhub) return; window.__deskhub = true;
      var st = document.createElement('style'); st.id = 'deskhub-sidebar';
      st.textContent = '.notion-sidebar-container{display:none !important} .notion-frame{width:100% !important}';
      document.head.appendChild(st);
      window.__deskhubToggleSidebar = function(){ st.disabled = !st.disabled; };
      var tries = 0;
      var t = setInterval(function(){
        tries++;
        var hit = null;
        document.querySelectorAll('div').forEach(function(d){
          if (hit) return;
          var tx = d.textContent || '';
          if (d.children.length < 12 && (tx.indexOf('데스크톱 앱에서 여시겠습니까') >= 0 || tx.indexOf('Open in desktop app') >= 0 || tx.indexOf('Open in the desktop app') >= 0)) hit = d;
        });
        if (hit) {
          var box = hit; for (var i = 0; i < 6 && box.parentElement && box.getBoundingClientRect().width < 600; i++) box = box.parentElement;
          var btn = box.querySelector('[aria-label="닫기"], [aria-label="Close"], [aria-label="close"]');
          if (!btn) { box.querySelectorAll('div[role="button"], button').forEach(function(b){ if (!btn && b.querySelector('svg.closeThick, svg.close')) btn = b; }); }
          if (btn) { btn.click(); clearInterval(t); }
        }
        if (tries > 60) clearInterval(t);
      }, 500);
    })();
    """

    var body: some View {
        WidgetChrome(style: WidgetStyle(kind: .notion, title: title),
                     subtitle: controller.title.isEmpty ? accountHint : controller.title) {
            IconButton(symbol: "house", help: "\(title) 페이지로") { controller.home() }
            IconButton(symbol: "sidebar.left", help: "Notion 사이드바 보이기/숨기기") {
                controller.webView.evaluateJavaScript("window.__deskhubToggleSidebar && window.__deskhubToggleSidebar()") { _, _ in }
            }
            IconButton(symbol: "chevron.left", help: "뒤로") { controller.webView.goBack() }
            IconButton(symbol: "arrow.clockwise", help: "새로고침") { controller.reload() }
            IconButton(symbol: "arrow.up.forward.app", help: "Notion 에서 이 페이지 열기", label: "열기") {
                let u = controller.currentURL ?? controller.webView.url ?? controller.homeURL
                NotionLink.open(url: u)
            }
        } content: {
            WebArea(controller: controller)
        }
    }

    /// notion.so / notion.com / app.notion.com 어느 형태든 페이지 ID(32 hex)를 뽑아 notion:// 로 만든다.
    static func appURL(for url: URL) -> URL {
        let path = url.path
        if let r = path.range(of: "[0-9a-fA-F]{32}", options: [.regularExpression, .backwards]) {
            let id = String(path[r])
            return URL(string: "notion://www.notion.so/\(id)")!
        }
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.scheme = "notion"
        return comps?.url ?? URL(string: "notion://www.notion.so/")!
    }
}

// MARK: - Google Calendar 위젯

struct CalendarWebWidget: View {
    @ObservedObject var controller: WebController
    let focusStart: Int
    var onSwitchNative: (() -> Void)? = nil

    private func view(_ name: String) -> URL {
        var base = controller.homeURL.absoluteString
        if let r = base.range(of: "/r/") { base = String(base[..<r.lowerBound]) + "/r/" }
        else if !base.hasSuffix("/") { base += "/" }
        return URL(string: base + name) ?? controller.homeURL
    }

    var body: some View {
        WidgetChrome(kind: .calendar, subtitle: Date().formatted(.dateTime.year().month().day().weekday(.wide)) + " · 웹") {
            IconButton(symbol: "sun.max", help: "오늘 (일 보기)", label: "오늘") { controller.home() }
            IconButton(symbol: "list.bullet", help: "일정 목록 보기", label: "일정") { controller.load(view("agenda")) }
            IconButton(symbol: "calendar", help: "주 보기", label: "주") { controller.load(view("week")) }
            IconButton(symbol: "arrow.clockwise", help: "새로고침") { controller.reload() }
            IconButton(symbol: "safari", help: "브라우저에서 열기") {
                NSWorkspace.shared.open(controller.currentURL ?? controller.homeURL)
            }
        } content: {
            WebArea(controller: controller)
        }
    }

    /// 구글 캘린더 웹을 위젯용으로 다듬는 스크립트: 오른쪽 사이드패널 숨김, 시간 격자를 focusStart 로 스크롤
    static func tidyScript(focusStart: Int) -> String {
        """
        (function(){
          var css = '[role="complementary"]{display:none !important}';
          var st = document.createElement('style'); st.textContent = css; document.head.appendChild(st);
          function scrollGrid(){
            var main = document.querySelector('[role="main"]') || document.body;
            var best = null;
            main.querySelectorAll('*').forEach(function(el){
              var cs = getComputedStyle(el);
              if ((cs.overflowY === 'auto' || cs.overflowY === 'scroll') && el.scrollHeight > el.clientHeight + 200) {
                if (!best || el.scrollHeight > best.scrollHeight) best = el;
              }
            });
            if (best) { best.scrollTop = best.scrollHeight * (\(focusStart) / 24) - 8; }
          }
          setTimeout(scrollGrid, 1200); setTimeout(scrollGrid, 3000);
        })();
        """
    }
}

// MARK: - 일반 웹 위젯 (설정에서 URL 만 적으면 됨)

struct GenericWebWidget: View {
    @ObservedObject var controller: WebController
    let title: String
    var body: some View {
        WidgetChrome(style: WidgetStyle(kind: .web, title: title), subtitle: controller.title) {
            IconButton(symbol: "house", help: "처음 페이지로") { controller.home() }
            IconButton(symbol: "chevron.left", help: "뒤로") { controller.webView.goBack() }
            IconButton(symbol: "arrow.clockwise", help: "새로고침") { controller.reload() }
            IconButton(symbol: "safari", help: "브라우저에서 열기") {
                NSWorkspace.shared.open(controller.currentURL ?? controller.homeURL)
            }
        } content: {
            WebArea(controller: controller)
        }
    }
}

struct PlaudWidget: View {
    @ObservedObject var controller: WebController
    let bundleID: String
    var body: some View {
        WidgetChrome(kind: .plaud, subtitle: controller.title.isEmpty ? "web.plaud.ai" : controller.title) {
            IconButton(symbol: "house", help: "Plaud Web 홈") { controller.home() }
            IconButton(symbol: "arrow.clockwise", help: "새로고침") { controller.reload() }
            IconButton(symbol: "record.circle", help: "Plaud 데스크톱 앱 열기", label: "앱 열기") {
                if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
                } else {
                    NSWorkspace.shared.open(URL(string: "plaud://")!)
                }
            }
        } content: {
            WebArea(controller: controller)
        }
    }
}

// MARK: - Claude 위젯

struct ClaudeWidget: View {
    @ObservedObject var controller: WebController
    let autoSend: Bool
    /// 글자 배율·색 프리셋 — 창 본문을 다시 만들지 않고(쓰던 질문 유지) 여기서 관찰해 다시 그린다 (0.37.0 검증 1 리뷰)
    @ObservedObject private var display = HubDisplay.shared
    @State private var query = ""
    @FocusState private var focused: Bool

    private static let autoSendJS = """
    (function(){
      var tries = 0;
      var t = setInterval(function(){
        tries++;
        var ed = document.querySelector('div[contenteditable="true"]');
        var b = document.querySelector('button[aria-label*="Send"], button[aria-label*="send"], button[aria-label*="보내"], button[aria-label*="전송"]');
        if (ed && b && !b.disabled && ed.innerText.trim().length > 0) { b.click(); clearInterval(t); }
        if (tries > 40) clearInterval(t);
      }, 300);
    })();
    """

    var body: some View {
        WidgetChrome(kind: .claude, subtitle: controller.title.isEmpty ? "claude.ai" : controller.title) {
            IconButton(symbol: "plus.bubble", help: "새 대화") { controller.home() }
            IconButton(symbol: "arrow.clockwise", help: "새로고침") { controller.reload() }
            IconButton(symbol: "arrow.up.forward.app", help: "Claude 데스크톱 앱에서 열기", label: "앱") {
                openInApp()
            }
        } content: {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(Color(nsColor: WidgetKind.claude.tint))
                    TextField("Claude에게 질문… (Enter: 위젯에서, ⌘Enter: 앱에서)", text: $query)
                        .textFieldStyle(.plain)
                        .font(.hub(14))
                        .focused($focused)
                        .onSubmit { submit(inApp: NSEvent.modifierFlags.contains(.command)) }
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                    }
                    Button { submit(inApp: false) } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.hub(22))
                            .foregroundStyle(query.isEmpty ? Color.secondary : Color(nsColor: WidgetKind.claude.tint))
                    }
                    .buttonStyle(.plain)
                    .disabled(query.isEmpty)
                    .help("질문 보내기")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.05))
                Divider().opacity(0.6)
                WebArea(controller: controller)
            }
        }
    }

    private func submit(inApp: Bool) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if inApp { openInApp(); return }
        var comps = URLComponents(string: "https://claude.ai/new")!
        comps.queryItems = [URLQueryItem(name: "q", value: q)]
        if autoSend { controller.pendingScript = ClaudeWidget.autoSendJS }
        controller.load(comps.url!)
        query = ""
    }

    private func openInApp() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var comps = URLComponents(string: "claude://claude.ai/new")!
        if !q.isEmpty { comps.queryItems = [URLQueryItem(name: "q", value: q)] }
        if NSWorkspace.shared.urlForApplication(toOpen: comps.url!) != nil {
            NSWorkspace.shared.open(comps.url!)
        } else {
            var web = URLComponents(string: "https://claude.ai/new")!
            web.queryItems = comps.queryItems
            NSWorkspace.shared.open(web.url!)
        }
        query = ""
    }
}
