import AppKit
import SwiftUI
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated static let bundleID = "kr.ac.snu.csnl.deskhub"
    var config = Config.load()
    var backdrop: BackdropWindow?
    var windows: [String: WidgetWindow] = [:]          // slot id → 창
    var controllers: [String: WebController] = [:]
    var calendars: [String: CalendarModel] = [:]
    var hubs: [String: NotionHubModel] = [:]
    var hubTabControllers: [String: [WebController]] = [:]
    var explorer: ExplorerModel?
    var statusItem: NSStatusItem!
    /// 메뉴 막대 한 줄 갱신 (D11) — 1분마다
    private var menuLineTimer: Timer?
    /// 메뉴 막대 팝오버 '조각' (D12) — 왼쪽 클릭 팝오버, 오른쪽 클릭 메뉴
    private var popover: NSPopover?
    /// 팝오버 위치 지킴 (R-33, 0.36.0) — 앵커·팝오버 창 알림(didResize·didMove, 닫힐 때 해제)·관측값(windows.txt 'popover:')
    private var popoverAnchor: NSStatusBarButton?
    private var popoverObservers: [NSObjectProtocol] = []
    private var popoverAdjusts = 0
    private var popoverClampPending = false
    private var popoverFit: CGFloat = 0
    private var popoverCap: CGFloat?
    private var saveWork: DispatchWorkItem?
    private var relayouting = false
    /// 확대/원래 크기로 setFrame 하는 동안 — 그 프레임 변화는 비율로 저장하지 않는다 (0.43.0 C7)
    private var zoomChanging = false
    private var hotKey: HotKey?
    /// 사용자가 숨겼는지 (모니터를 다시 꽂아도 저절로 다시 뜨지 않게)
    private var hiddenByUser = false

    /// deskhub:// 링크 (D17) — 읽기·화면 동작만. 상태를 바꾸는 동작(끝남 등)은 웹 링크로 누구나 부를 수 있어서 넣지 않는다
    ///   deskhub://view/<tower|process|board|hub|today|grm|me|ambient> · deskhub://show · hide · toggle
    ///   deskhub://refresh (주간 정리 적용 직후 부름) · deskhub://open/grm.slides (다음 GRM 슬라이드 폴더)
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls where u.scheme == "deskhub" {
            let host = u.host ?? ""
            let path = u.pathComponents.filter { $0 != "/" }
            switch host {
            case "view": if let v = path.first.flatMap(HubViewMode.init(rawValue:)) { ViewModeStore.shared.mode = v; showAll() }
            case "show": showAll()
            case "hide": hideAll()
            case "toggle": toggleAll()
            case "refresh": hubs.values.forEach { h in Task { await h.refresh() } }; refreshMenuLine()
            case "open":
                if path.first == "grm.slides", let m = hubs.values.first, let g = m.nextGRM { m.openSlides(for: g) }
            default: NSSound.beep()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 첫 그림까지 시간 (M5, 0.40.0 C2) — 여기서 시작, 데이터 다 옴 뒤 기본 뷰가 그려지면 HubViewSwitch 가 끝을 잰다
        RenderClock.begin()
        if AppDelegate.showInDock { NSApp.setActivationPolicy(.regular) }
        // 검증용: DESKHUB_APPEARANCE=dark|light 로 외형 고정, flip 은 다크로 띄웠다가 20초 뒤 라이트로 바꿔
        // 자동 외형 전환 때 카드 색이 따라오는지 스냅샷으로 확인한다. 평소(LaunchAgent)에는 시스템 설정을 따른다.
        // 글자·색 프리셋 (0.37.0 C3) — 색이 바뀌면 테마·외형 다시 적용 + 바닥판·카드 바탕 다시 칠하기. config.json 은 쓰지 않는다
        HubDisplay.shared.onPresetChange = { [weak self] in self?.applyTheme(); self?.repaintFills() }
        applyTheme()
        if ProcessInfo.processInfo.environment["DESKHUB_APPEARANCE"] == "flip" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { NSApp.appearance = NSAppearance(named: .aqua) }
        }
        installMainMenu()
        buildAll()
        installStatusItem()
        registerHotKey()
        NotificationCenter.default.addObserver(self, selector: #selector(hideAll), name: DeskHubNotice.hideAll, object: nil)
        // 창 단추·제목 막대 더블클릭 (0.43.0 C7, #51)
        NotificationCenter.default.addObserver(self, selector: #selector(titleDoubleClicked(_:)), name: DeskHubNotice.titleDoubleClick, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowZoomRequested(_:)), name: DeskHubNotice.windowZoom, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settleAll), name: DeskHubNotice.windowLower, object: nil)
        for (cmd, sel) in [("show", #selector(showAll)), ("hide", #selector(hideAll)), ("toggle", #selector(toggleAll))] {
            DistributedNotificationCenter.default().addObserver(self, selector: sel, name: Notification.Name(AppDelegate.bundleID + "." + cmd), object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wokeUp),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(snapshotRequested(_:)),
                                                            name: Notification.Name(AppDelegate.bundleID + ".snapshot"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(dumpAlertsRequested(_:)),
                                                            name: Notification.Name(AppDelegate.bundleID + ".dumpalerts"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(keyRequested(_:)),
                                                            name: Notification.Name(AppDelegate.bundleID + ".key"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(dumpPipelineRequested(_:)),
                                                            name: Notification.Name(AppDelegate.bundleID + ".dumppipeline"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(dumpPhaseRequested(_:)),
                                                            name: Notification.Name(AppDelegate.bundleID + ".dumpphase"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(lineRequested(_:)),
                                                            name: Notification.Name(AppDelegate.bundleID + ".line"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(usageRequested(_:)),
                                                            name: Notification.Name(AppDelegate.bundleID + ".usage"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(viewRequested(_:)),
                                                            name: Notification.Name(AppDelegate.bundleID + ".view"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(dumpTextRequested(_:)),
                                                            name: Notification.Name(AppDelegate.bundleID + ".dumptext"), object: nil)
    }

    // 메뉴막대 없이도 ⌘C/⌘V/⌘A 등이 웹뷰·텍스트필드에서 동작하도록 숨은 Edit 메뉴를 둔다.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "DeskHub 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "편집")
        edit.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "오려두기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    // MARK: 구성

    /// 테마·외형 적용. 색 프리셋(HubDisplay — '고대비' 는 내장 테마, '어두움' 은 지금 테마의 다크)이 config 의 테마·외형보다 앞서고,
    /// DESKHUB_APPEARANCE(검증용) 가 있으면 그것이 맨 앞
    private func applyTheme() {
        NotionLink.mode = config.notionHub.openLinksIn
        NotionLink.minAppVersion = config.notionHub.minNotionAppVersion
        Theme.all = Theme.load()
        Theme.currentID = Theme.hookID ?? (Theme.all[config.theme] != nil ? config.theme : "csnl")
        Theme.preset = HubDisplay.shared.colorPreset
        var mode = config.appearance
        if Theme.current.alwaysDark == true { mode = "dark" }
        if Theme.preset == "dark" { mode = "dark" }
        if let env = ProcessInfo.processInfo.environment["DESKHUB_APPEARANCE"], env == "dark" || env == "light" { mode = env }
        NSApp.appearance = mode == "dark" ? NSAppearance(named: .darkAqua) : mode == "light" ? NSAppearance(named: .aqua) : nil
    }

    /// 바닥판·카드 바탕·테두리(AppearanceFillView)를 다시 칠한다 — 외형이 그대로인 색 변경(고대비)은 AppKit 이 알려 주지 않으므로
    private func repaintFills() {
        func walk(_ v: NSView) { if let f = v as? AppearanceFillView { f.needsDisplay = true }; v.subviews.forEach(walk) }
        for w in windows.values { if let v = w.contentView { walk(v) } }
        if let v = backdrop?.contentView { walk(v) }
    }

    private func registerHotKey() {
        hotKey = HotKey(config.layout.hotkey) { [weak self] in self?.toggleAll() }
        DeskHubNotice.hotkeyLabel = hotKey?.label ?? "단축키 없음"
    }

    /// 보조 모니터 설정인데 보조 모니터가 없으면(hide) 숨긴 채 시작한다
    private var startHidden: Bool { !config.onIntendedScreen && config.layout.whenNoSecondary == "hide" }

    private func buildAll() {
        if config.layout.mode == "desktop" || config.layout.backdrop, let screen = config.targetScreen() {
            let b = BackdropWindow(frame: screen.visibleFrame)
            if !startHidden && !hiddenByUser { b.orderFront(nil) }
            backdrop = b
        }
        for slot in config.layout.slots { makeWidget(slot) }
    }

    private func tearDownAll() {
        for w in windows.values { w.orderOut(nil); w.close() }
        windows.removeAll(); controllers.removeAll(); calendars.removeAll(); hubs.removeAll(); hubTabControllers.removeAll(); explorer = nil
        backdrop?.orderOut(nil); backdrop?.close(); backdrop = nil
    }

    private func makeWidget(_ slot: Slot) {
        guard windows[slot.id] == nil, let kind = slot.kind else { return }
        let ua = config.web.userAgent
        let frame = config.windowFrame(for: slot)
        let win = WidgetWindow(slotID: slot.id, kind: kind, frame: frame,
                               cornerRadius: CGFloat(config.layout.cornerRadius), opaque: config.layout.opaqueCards,
                               shadow: config.layout.mode == "widget")
        win.onFrameChange = { [weak self] f in self?.frameChanged(slot.id, f) }
        let title = slot.title ?? kind.defaultTitle

        switch kind {
        case .calendar:
            let model = CalendarModel(cfg: config.calendar)
            calendars[slot.id] = model
            let webC = WebController(kind: .calendar, homeURL: URL(string: config.calendar.webURL)!, userAgent: ua,
                                     zoom: config.calendar.webZoom,
                                     userScript: CalendarWebWidget.tidyScript(focusStart: config.calendar.focusStart),
                                     lazy: true)
            webC.reloadHomeAtMidnight()
            controllers[slot.id] = webC
            let host = CalendarHost(model: model, web: webC, modeBox: CalendarModeBox(config.calendar.mode),
                                    focusStart: config.calendar.focusStart) { [weak self] newMode in
                self?.config.calendar.mode = newMode
                self?.config.save()
            }
            win.setContent(host)
        case .notionhub:
            let model = NotionHubModel(cfg: config.notionHub, prolific: config.prolific, nasRoot: config.nas.root)
            // 허브의 "지금 · 다음 일정" 줄 — 캘린더 카드와 따로 오늘만 본다 (BHL 의견 '오늘 일정' 중복 ①안 준비)
            model.todayCalendar = CalendarModel(cfg: config.calendar)
            hubs[slot.id] = model
            let tabs = config.notionHub.tabs.map { t in
                WebController(kind: .notion, homeURL: URL(string: t.url) ?? URL(string: "https://www.notion.so/")!,
                              userAgent: ua, userScript: NotionWidget.tidyScript, lazy: true)
            }
            hubTabControllers[slot.id] = tabs
            // 허브는 머리·'글자' 판·고른 탭을 지키려고 본문만 .id 로 다시 만든다 (NotionHubWidget)
            win.setContent(NotionHubWidget(model: model, title: title, tabs: config.notionHub.tabs, tabControllers: tabs), refresh: false)
        case .notion:
            let url = URL(string: slot.url ?? "https://www.notion.so/") ?? URL(string: "https://www.notion.so/")!
            let c = WebController(kind: .notion, homeURL: url, userAgent: ua, userScript: NotionWidget.tidyScript)
            controllers[slot.id] = c
            win.setContent(NotionWidget(controller: c, title: title, accountHint: config.notion.accountHint))
        case .web:
            let url = URL(string: slot.url ?? "about:blank") ?? URL(string: "about:blank")!
            let c = WebController(kind: .web, homeURL: url, userAgent: ua)
            controllers[slot.id] = c
            win.setContent(GenericWebWidget(controller: c, title: title))
        case .plaud:
            let c = WebController(kind: .plaud, homeURL: URL(string: config.plaud.url)!, userAgent: ua)
            controllers[slot.id] = c
            win.setContent(PlaudWidget(controller: c, bundleID: config.plaud.bundleID))
        case .claude:
            let c = WebController(kind: .claude, homeURL: URL(string: config.claude.url)!, userAgent: ua)
            controllers[slot.id] = c
            // 쓰던 질문(@State)이 글자·색 변경 때 지워지지 않게 본문을 다시 만들지 않는다 — 위젯이 HubDisplay 를 관찰해 다시 그림 (0.37.0 검증 1 리뷰)
            win.setContent(ClaudeWidget(controller: c, autoSend: config.claude.autoSend), refresh: false)
        case .nas:
            let m = ExplorerModel(root: config.nas.root, smb: config.nas.smb,
                                  fileStation: config.nas.fileStationURL, favorites: config.nas.favorites)
            explorer = m
            win.setContent(NASWidget(model: m))
        }
        windows[slot.id] = win
        if slot.visible && !startHidden && !hiddenByUser { win.orderFront(nil) }
    }

    private func frameChanged(_ slotID: String, _ frame: NSRect) {
        // 확대 중(zoomRestore)·확대/원래 크기 전환 중에는 저장하지 않는다 — 확대는 비율 레이아웃에 남기지 않음 (0.43.0 C7)
        guard !relayouting, !zoomChanging, windows[slotID]?.zoomRestore == nil,
              let i = config.layout.slots.firstIndex(where: { $0.id == slotID }) else { return }
        config.layout.slots[i].frame = config.fraction(for: frame)
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.config.save() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    /// 비율로부터 모든 창 프레임을 다시 계산 (화면 바뀜·기본 배치 복원)
    private func relayout() {
        // 확대는 먼저 푼다(저장 없이) — 화면이 바뀌면 늘 비율대로 (0.43.0 C7)
        for w in windows.values { w.zoomRestore = nil }
        relayouting = true
        if let screen = config.targetScreen() { backdrop?.setFrame(screen.visibleFrame, display: true) }
        for slot in config.layout.slots {
            windows[slot.id]?.setFrame(config.windowFrame(for: slot), display: true)
        }
        relayouting = false
    }

    /// 모니터를 꽂거나 뺐을 때: 비율대로 다시 배치하고, 보조 모니터가 생기면 보이고 없어지면 숨긴다(사용자가 숨긴 상태는 유지)
    @objc private func screenChanged() {
        relayout()
        guard !hiddenByUser, !windows.values.contains(where: { $0.peeking }) else { return }
        if startHidden { for w in windows.values { w.orderOut(nil) }; backdrop?.orderOut(nil) }
        else { placeAll(peek: false) }
    }

    @objc private func wokeUp() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.explorer?.refresh()
            self?.calendars.values.forEach { $0.refresh() }
            self?.hubs.values.forEach { h in Task { await h.refresh() } }
        }
    }

    /// `DeskHub --dump-alerts <dir>` — 경보 엔진 결과를 텍스트로 (D3)
    @objc private func dumpAlertsRequested(_ note: Notification) {
        let dir = URL(fileURLWithPath: (note.object as? String) ?? NSTemporaryDirectory(), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = hubs.values.map { m in
            let props = m.reminderProposals
            // '제안' 섹션 (0.35.0, R2 검증용) — reminderProposals 그대로: id · 제목 · 날짜
            let proposals = (["", "제안 (\(props.count))"] + props.map { "- \($0.id) · \($0.title) · \($0.date)" }).joined(separator: "\n")
            // '레일 관련도' 줄 (0.35.0, SMJ #27 검증용) — 관제탑 기본 펼침이 쓰는 점수 그대로
            let relevance = "\n\n" + TowerRelevance.dumpLine(model: m, now: HubClock.now, me: HubPrefs.me)
            let set = AlertEngine.evaluate(m, cal: m.todayCalendar, now: HubClock.now, me: HubPrefs.me)
            // '팝오버 할 것' 절 (0.43.0 C1, #46) — 팝오버와 같은 PopoverTodo.split: 4줄 + 어제 이전 마감 접힌 한 줄
            let todo = "\n\n" + PopoverTodo.dumpLines(set, now: HubClock.now).joined(separator: "\n")
            return AlertEngine.dump(set, now: HubClock.now,
                                    isMember: { ini in m.member(initials: ini).map { !$0.initials.isEmpty } ?? false }) + "\n" + proposals + relevance + todo
        }.joined(separator: "\n\n")
        try? text.write(to: dir.appendingPathComponent("alerts.txt"), atomically: true, encoding: .utf8)
    }

    /// `DeskHub --key <키>` — KeyLayer 와 같은 처리 (D6 검증용)
    @objc private func keyRequested(_ note: Notification) {
        guard let k = note.object as? String else { return }
        if let n = Int(k), n >= 1, n <= HubViewMode.allCases.count { ViewModeStore.shared.mode = HubViewMode.allCases[n - 1] }
        else if k == "?" { KeyBus.shared.showHelp.toggle() }
        else if k == "r" { hubs.values.forEach { h in Task { await h.refresh() } } }
        // 팝오버 열기·닫기 토글 (R-33 검증용, 0.36.0) — 클릭 없이 실제 NSPopover 를 띄운다
        else if k == "popover" {
            if let p = popover, p.isShown { p.performClose(nil) } else if let b = statusItem.button { openPopover(anchor: b) }
        }
        // 허브 카드 '더 보기' 토글 (0.37.0 C2) — 클릭과 같은 경로(HubExpansion.toggle, 이 맥 저장)
        else if k.hasPrefix("expand:") { HubExpansion.shared.toggle(String(k.dropFirst("expand:".count))) }
        // 8주 띠 (0.40.0 C4) — 상태 한 줄 클릭과 같은 경로 · esc 는 띠가 열려 있으면 닫기(아니면 뷰로)
        else if k == "band" { StatusBand.shared.toggle() }
        else if k == "esc", StatusBand.shared.open { StatusBand.shared.close() }
        // '내 것' 배지 확인 (0.40.0 C4) — '새 n' 칩·'내 GRM 바뀜 · 확인' 과 같은 경로
        else if k.hasPrefix("seen:") { SeenCards.shared.acknowledge(String(k.dropFirst("seen:".count))) }
        // 글자·색 (0.37.0 C3) — 판의 막대·단추와 같은 경로(UserDefaults 저장). settings = '글자' 판 열기·닫기
        else if k.hasPrefix("scale:") { if let v = Double(k.dropFirst("scale:".count)) { HubDisplay.shared.setScale(v) } }
        else if k.hasPrefix("preset:") { HubDisplay.shared.setPreset(String(k.dropFirst("preset:".count))) }
        // 글꼴 (0.42.0 C7) — 판 'Font' 단추와 같은 경로(UserDefaults DeskHub.fontFamily)
        else if k.hasPrefix("font:") { HubDisplay.shared.setFont(String(k.dropFirst("font:".count))) }
        else if k == "settings" { withAnimation(.easeOut(duration: 0.12)) { HubDisplay.shared.panelOpen.toggle() } }
        // 학회 관심 (0.37.0 C5) — 이름 일부가 맞는 첫 학회에 '관심' 클릭과 같은 경로 · interest-undo = 마지막 대기 취소
        else if k == "interest-undo" { if let m = hubs.values.first, let p = m.interestCommits.pending.last { m.interestCommits.undo(p.id) } }
        else if k.hasPrefix("interest:") {
            let q = String(k.dropFirst("interest:".count)).lowercased()
            if let m = hubs.values.first, let c = m.conferences.first(where: { InterestFile.displayName($0).lowercased().contains(q) }) { m.toggleInterest(c) }
            else { NSSound.beep() }
        }
        // 분야 최근 이슈 보기 (0.39.0 C3) — '관심만'·'전체' 단추와 같은 경로(FeedPrefs, 이 맥 UserDefaults)
        else if k.hasPrefix("feed:") { FeedPrefs.shared.set(String(k.dropFirst("feed:".count))) }
        // 태그 Filter (0.43.0 C4, #49) — 칩 클릭과 같은 경로(FeedPrefs.setTags, 이 맥 UserDefaults DeskHub.feedTags). 빈 값 = 지움.
        // feedfilter(칩 줄 열기·닫기)는 아래 KeyBus 로
        // 창 (0.43.0 C7, #51) — window:zoom|lower|close|dblclick[:<슬롯>](슬롯 없으면 허브) · hotkey(⌃⌥D 와 같은 toggleAll) · peek(대시보드 앞으로)
        else if k.hasPrefix("window:") {
            let p = k.dropFirst("window:".count).split(separator: ":", maxSplits: 1).map(String.init)
            let slot = p.count > 1 && !p[1].isEmpty ? p[1] : hubSlotID
            switch p.first ?? "" {
            case "zoom": toggleZoom(slot)
            case "lower": settleAll()
            case "close": hideAll()
            case "dblclick": handleDoubleClick(slot)
            default: NSSound.beep()
            }
        }
        else if k == "hotkey" { toggleAll() }
        else if k == "peek" { bringFront() }
        else if k.hasPrefix("feedtags:") { FeedPrefs.shared.setTags(k.dropFirst("feedtags:".count).split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }) }
        // 논문 소통 '같이 읽자' (0.39.0 C5) — 제목 일부가 맞는 첫 논문([논문 추천] 덤프 순서)에 단추와 같은 경로 · talk-undo = 마지막 대기 취소.
        // talk: 는 시험용 키라 드라이런 훅(DESKHUB_NOTION_WRITE=dry:)이 없으면 아무것도 쓰지 않고 삐 — Notion 댓글은 API 로 지울 수 없다 (검증 1).
        // talk-undo 는 대기 중인 쓰기를 취소만 하므로(쓰기 없음) 막지 않는다. 사람이 누르는 단추 경로는 그대로
        else if k == "talk-undo" { if let m = hubs.values.first, let p = m.talkCommits.pending.last { m.talkCommits.undo(p.id) } }
        // 미팅 후속 (0.41.0 C2) — fu-done:<id 앞>·fu-dismiss:<id 앞>(6초)·fu-confirm:<id 앞>(즉시)·fu-undo·fu-add:<종류>|<글>.
        // 시험용 키라 DESKHUB_FOLLOWUPS 훅이 없으면 삐만 — NAS 원본에 쓰지 않게(talk: 와 같은 이유). 사람이 누르는 단추 경로는 그대로
        // 상태 한 줄 미팅 후속 칩 '그날 확인' (0.41.0 C4) — 이 맥 UserDefaults 만 쓰므로 훅 없이도 (칩 클릭과 같은 경로)
        else if k == "fu-ack" { hubs.values.first?.ackFollowupReminder() }
        else if k.hasPrefix("fu-") {
            guard FollowupsFile.hookDir != nil, let m = hubs.values.first else { NSSound.beep(); return }
            m.followupKey(k)
        }
        else if k.hasPrefix("talk:") {
            guard NotionDryRun.path != nil else { NSSound.beep(); return }
            let q = String(k.dropFirst("talk:".count)).lowercased()
            if !q.isEmpty, let m = hubs.values.first, let p = m.papers.first(where: { $0.title.lowercased().contains(q) }) { m.toggleTalk(p) }
            else { NSSound.beep() }
        }
        else { KeyBus.shared.send(k) }
    }

    /// `DeskHub --dump-pipeline <dir>` — 공정 판정 결과를 텍스트로 (D7)
    @objc private func dumpPipelineRequested(_ note: Notification) {
        let dir = URL(fileURLWithPath: (note.object as? String) ?? NSTemporaryDirectory(), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let defs = PipelineDefs.load()
        // [실험 키] — '실험' 한 줄의 펼침 표(0.40.0 C7, A4 — ExperimentKeyTable 과 같은 ExperimentStats.keyTable)
        let text = hubs.values.map { m in PipelineEngine.dump(PipelineEngine.evaluate(m, defs: defs, now: HubClock.now, me: HubPrefs.me), now: HubClock.now)
            + "\n\n[실험 키]\n" + m.experimentKeyDumpLines().joined(separator: "\n") }
            .joined(separator: "\n\n")
        try? text.write(to: dir.appendingPathComponent("pipeline.txt"), atomically: true, encoding: .utf8)
    }

    /// `DeskHub --dump-phase <dir>` — 안내판 주인공 국면 표 (D9)
    @objc private func dumpPhaseRequested(_ note: Notification) {
        let dir = URL(fileURLWithPath: (note.object as? String) ?? NSTemporaryDirectory(), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 국면 표(far 모드 주인공) 뒤에 안내판 블록(0.35.0: 마감·오늘·오른쪽·GRM 띠·끝 — BoardView.data 그대로)
        let text = hubs.values.map { m in
            Phase.dump(model: m, cal: m.todayCalendar, now: HubClock.now) + "\n\n" + BoardView.dump(model: m, now: HubClock.now, me: HubPrefs.me)
        }.joined(separator: "\n\n")
        try? text.write(to: dir.appendingPathComponent("phase.txt"), atomically: true, encoding: .utf8)
    }

    /// `DeskHub --dump-text <dir>` — 화면에 그리는 글자를 절별로 text.txt 에 (0.36.0, R-31…). 필드 구분은 ' · ', 빈 칸은 '—'
    @objc private func dumpTextRequested(_ note: Notification) {
        let dir = URL(fileURLWithPath: (note.object as? String) ?? NSTemporaryDirectory(), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dash: (String) -> String = { $0.isEmpty ? "—" : $0 }
        let text = hubs.keys.sorted().compactMap { hubs[$0] }.map { m in
            // [허브 글자] — 랩 허브 카드 글자 역할·여백 (0.37.0, CardStyle.large·HubSpace 에서 읽음)
            var out = ["[허브 글자] " + CardStyle.large.dumpLine, ""]
            // [허브 카드] — 카드마다 가까운 것만 보인 수·숨긴 수·펼침·기준값 (0.37.0 C2, HubNear — 뷰와 같은 함수)
            out += ["[허브 카드] \(HubNear.keys.count)"] + HubNear.dumpLines(m) + [""]
            // [카드 제목] — 허브 카드 제목 표 'id · 제목 · 도움말' (0.42.0 C3, R9-a — SectionTitle(card:) 와 같은 HubCardTitle)
            out += ["[카드 제목] \(HubCardTitle.rows.count)"] + HubCardTitle.dumpLines() + [""]
            // [카드 출처] — 허브 데이터 카드 14: id · 꼬리표 · 캡션('출처 · 기준 · n · 정의 id', CardMetas.caption — 카드 끝 CardFooter 와 같은 함수) (0.40.0 C2, A1)
            out += ["[카드 출처] \(CardMetas.hub.count)" + (m.metricsNote.map { " · 집계 " + $0 } ?? "")] + CardMetas.dumpLines(m) + [""]
            // [꼬리표] — 허브 데이터 카드 14 + 관제탑 레일 데이터 항목 10 의 내용 날짜 꼬리표(M3) · [자료 상태] — 원천 정렬 표(경과일 내림차순, 5칸) · [위생] (0.40.0 C3, A2)
            out += ["[꼬리표]"] + DataSources.tagDumpLines(m) + [""]
            out += ["[자료 상태]"] + DataSources.dumpLines(m) + [""]
            out += ["[위생]"] + DataSources.hygieneDumpLines(m) + [""]
            // [상태 한 줄]·[8주 띠]·[배지] (0.40.0 C4, A3) — 뷰와 같은 StatusLine·SeenCards 함수
            out += ["[상태 한 줄]"] + StatusLine.dumpLines(m) + [""]
            out += ["[8주 띠]"] + StatusLine.bandDumpLines(m) + [""]
            out += ["[배지]"] + SeenCards.shared.dumpLines(m) + [""]
            // [장비] — 장비 6줄 '장비 · 지금 · 다음'(내 것) + 닫기 누락 (0.40.0 C5, A5 — EquipmentCard 와 같은 EquipmentBoard 함수)
            out += ["[장비]"] + m.equipmentDumpLines() + [""]
            // [멤버 상태]·[Members 카드] (0.42.0 C5, R2·R9-c — MemberStatus.resolve 를 모델이 한 번 계산한 값 · MembersCard 와 같은 함수)
            out += ["[멤버 상태]"] + m.memberStatusDumpLines() + [""]
            out += ["[Members 카드]", MembersCard.dumpLine(m), ""]
            // [Joint projects] — 읽기·생성·행·오류 / 행 'id · 버전 · 담당 · 완료 … · 대기 …'(대기 있는 행 먼저) (0.42.0 C6, R9-d — JointProjectsCard 와 같은 함수)
            out += ["[Joint projects]"] + m.jointDumpLines() + [""]
            // [Timetable] — 학기·출처·과목·행·사람·못 읽은 행·휴일 / 오늘 덩어리 / 주간 (0.42.0 C4, R1 — ClassesCard·TimetableView 와 같은 Timetable 함수)
            out += ["[Timetable]"] + m.timetableDumpLines() + [""]
            // [미팅 후속] — 읽기·생성·항목 / 나·보기·남은·다음 미팅·리마인드 / (보기 내용·읽기만) 항목 줄 / 사람별 (0.41.0 C2, R1 — MeetingFollowups.swift 같은 함수)
            out += ["[미팅 후속]"] + m.followupDumpLines() + [""]
            // [GRM 자료 지도] — 머리(날짜 대응·열별 채움·?) · 보이는 행 · 순번 (0.40.0 C6, A6 — GRMMapView 와 같은 GRMMap 함수)
            out += ["[GRM 자료 지도]"] + GRMMap.dumpLines(m) + [""]
            // [논문 추천] — PaperRecBoard 가 그리는 제목·저자 그대로 (R-31)
            out += ["[논문 추천] \(m.papers.count)"]
            // 반응 줄 (0.42.0 C1, #23) — 쉴 때 글(PaperReact.line, 화면과 같은 함수)
            out += m.papers.map { p in
                let cs = m.paperComments[p.id] ?? []
                let rest = PaperReact.text(PaperReact.line(reactions: cs.filter(\.isReaction).map { ($0.text, $0.who) }, me: HubPrefs.me,
                                                           notes: cs.filter(\.isNote).count, hover: false))
                return [dash(p.researcher), dash(p.tier), dash(p.title), dash(p.authors), "반응 줄: " + rest].joined(separator: " · ")
            }
            // [Paper Blitz] — 인용 줄(R-30): 발표자 · 제목 앞 40자 · 표시 줄 · 정리|원문
            out += ["", "[Paper Blitz] \(m.blitz.count)"]
            out += m.blitz.map { p in
                let c = Hub.citationLine(p)
                return [dash(p.presenter), dash(String(p.title.prefix(40))), dash(c.text), c.normalized ? "정리" : "원문"].joined(separator: " · ")
            }
            // [학회 관심] — 학회 · 학회키 · 관심 [이니셜] · 나 on|off (0.37.0 C5 — 6초 대기 중이면 바뀔 상태)
            let ci = m.interestDumpLines()
            out += ["", "[학회 관심] \(m.conferences.count)"] + ci
            // [실험] — 오늘의 실험 카드 행 그대로: 출처 · 제목 · detail · 실험자 · 상태 (0.37.0 C4 — Prolific 은 진행·준비 중만.
            // 0.40.0 C1: detail 까지 — M8(피험자 이름·ID 출현 0) 시험이 카드 둘째 줄도 덮게)
            out += ["", "[실험] \(m.experiments.count)"]
            out += m.experiments.map { x in [dash(x.source), dash(x.title), dash(x.detail), dash(x.owner), dash(x.status)].joined(separator: " · ") }
            // Prolific 안내 줄(미연결·조회 실패 — 지난 행이 남으면 '아래는 HH:mm 결과') (0.38.0 C5)
            if let n = m.prolificNote { out.append("알림 · " + n) }
            // [연구 탭] — 가상 탭 901 (0.39.0 C1): 칸 · 분야 최근 이슈 · 논문 추천(보기 대상 · 편 수 · 신선도)
            out += ["", "[연구 탭]"] + ResearchTabView.dumpLines(m)
            // [분야 이슈] — bioRxiv neuroscience 7일 (0.39.0 C2): 출처·받기 횟수·호출 수·받은 날·관심 일치·보기·행 [주제] (IssueFeedCard 와 같은 함수, C3)
            out += ["", "[분야 이슈]"] + IssueFeedCard.dumpLines(m)
            // [논문 소통] — '같이 읽자' 제안·모임 후보·6초 대기 (0.39.0 C5, PaperComment.proposers — 뷰와 같은 함수)
            out += ["", "[논문 소통]"] + PaperTalk.dumpLines(m)
            // [Members 전광판] — Members 탭 현황판: 열(실제/예시) · 띠 · 합계 · 행(이니셜 · 진행 프로젝트 · 다음 GRM · Milestone · 논문 반응 · 예시 열) · 각주 (0.37.0 C7, 0.39.0 C4)
            out += ["", "[Members 전광판]"] + MembersBoardRow.dumpLines(m)
            // [전광판 집계] — 논문 반응 28일(ScoreboardLive.tally 와 같은 함수): 기간 · 댓글 읽음 · 반응·댓글 합 / 이니셜 행 / 목록 밖 (0.39.0 C4)
            out += ["", "[전광판 집계]"] + MembersBoardRow.tallyDumpLines(m)
            // [진행 프로젝트] — 칩 줄 멤버마다 팝오버 목록(PopoverView.myProjects)과 칩 목록(MemberGroup 이 받는 entry)을 비교 (R-32)
            let shown = MembersProjectsStrip.shown(m)
            out += ["", "[진행 프로젝트] \(shown.count)"]
            out += shown.map { mem in
                let pop = PopoverView.myProjects(m, mem).map { MemberGroup.display($0.name) }
                let chip = (m.memberLinkEntry(for: mem)?.projects ?? []).map { MemberGroup.display($0.name) }
                return [dash(mem.initials), "팝오버 [" + pop.joined(separator: ", ") + "]", "칩 [" + chip.joined(separator: ", ") + "]", pop == chip ? "같음" : "다름"].joined(separator: " · ")
            }
            return out.joined(separator: "\n")
        }.joined(separator: "\n\n")
        try? (text + "\n").write(to: dir.appendingPathComponent("text.txt"), atomically: true, encoding: .utf8)
    }

    /// `DeskHub --line <dir>` — 메뉴 막대 한 줄 세 단계 (D11)
    @objc private func lineRequested(_ note: Notification) {
        let dir = URL(fileURLWithPath: (note.object as? String) ?? NSTemporaryDirectory(), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = hubs.values.map { m in
            MenuLineStep.allCases.filter { $0 != .off }.map { "\($0.rawValue): " + MenuBarLine.text(m, step: $0, now: HubClock.now) }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        try? text.write(to: dir.appendingPathComponent("line.txt"), atomically: true, encoding: .utf8)
        refreshMenuLine()
    }

    /// `DeskHub --usage <dir>` — 사용 기록 요약 (D13)
    @objc private func usageRequested(_ note: Notification) {
        let dir = URL(fileURLWithPath: (note.object as? String) ?? NSTemporaryDirectory(), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? UsageLog.summary().write(to: dir.appendingPathComponent("usage.txt"), atomically: true, encoding: .utf8)
    }

    /// `DeskHub --view <hub|today|grm|me|ambient>` — 첫 탭의 뷰를 바꾼다
    @objc private func viewRequested(_ note: Notification) {
        if let m = (note.object as? String).flatMap(HubViewMode.init(rawValue:)) { ViewModeStore.shared.mode = m }
    }

    /// `DeskHub --snapshot <dir>` 로 요청하면 각 위젯 창을 PNG 로 저장한다.
    @objc private func snapshotRequested(_ note: Notification) {
        let dir = URL(fileURLWithPath: (note.object as? String) ?? NSTemporaryDirectory(), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var info: [String] = []
        for (id, w) in windows {
            w.snapshot(to: dir.appendingPathComponent("\(id).png"))
            info.append("\(id): visible=\(w.isVisible) level=\(w.level.rawValue) frame=\(w.frame) key=\(w.isKeyWindow) active=\(NSApp.isActive)")
        }
        // 창 상태 (0.43.0 C7) — 'window: <슬롯> zoomed=yes|no peeking=yes|no controls=yes|no dblclick=<zoom|lower|none> usable=<rect>'
        for id in windows.keys.sorted() {
            guard let w = windows[id] else { continue }
            let yn: (Bool) -> String = { $0 ? "yes" : "no" }
            info.append("window: \(id) zoomed=\(yn(w.zoomRestore != nil)) peeking=\(yn(w.peeking)) controls=\(yn(w.peeking && w.isVisible))"
                        + " dblclick=\(WindowChrome.current.rawValue) usable=\(config.usableRect(on: w.screen))")
        }
        if let b = backdrop { info.append("backdrop: visible=\(b.isVisible) level=\(b.level.rawValue) frame=\(b.frame)") }
        // 팝오버 '조각' 도 그림으로 (D12) — 화면에 띄우지 않고 그린다
        if let m = hubs.values.first {
            // 팝오버를 여는 것과 같은 경로 — TTL 지난 소스 다시 조회를 건다(비동기, 이 그림은 캐시 값). QA 가 다음 스냅샷에서 갱신 시각을 본다 (UX 0.34.0)
            PopoverRefresh.willOpen(m)
            let r = ImageRenderer(content: PopoverView(model: m, forSnapshot: true).background(Hub.card).environment(\.colorScheme, NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("popover.png"))
            }
        }
        // 캘린더 창 모델도 같은 TTL 로 다시 조회 — 'ics:' 줄과 캘린더 상태줄이 허브 쪽과 같은 때를 가리키게 (QA 0.35.0, R1·R3)
        for id in calendars.keys.sorted() { calendars[id]?.refreshIfStale(ttl: PopoverRefresh.ttl) }
        // ICS 관측 줄 (0.35.0) — 개수·상태·호스트만, URL 없음. 허브의 오늘 캘린더가 먼저, 그다음 캘린더 창
        for id in hubs.keys.sorted() { if let c = hubs[id]?.todayCalendar { info.append(c.debugLine + " (\(id) 오늘)") } }
        for id in calendars.keys.sorted() { if let c = calendars[id] { info.append(c.debugLine + " (\(id) 창)") } }
        info.append(popoverDebugLine)
        info.append(HubLayoutProbe.line)
        // 글꼴 (0.42.0 C7) — 'font: <id> (등록됨|대체|기본)'
        info.append(HubDisplay.fontLine)
        // 갱신 단위 Notion 질의·쪽 수 (0.40.0 C1, F0-3 — 죽은 조회 3건을 빼고 12)
        info.append(NotionQueryStats.line)
        // 첫 그림까지 시간 (M5, 0.40.0 C2) — 'render: 첫 실측 n ms · 뷰 <mode>'
        info.append(RenderClock.line)
        // 접힘 빈 면 채우기 (0.38.0 C3) — 'hub-fill: 1 preprints +1 papers +2 · 2 … (결정 HH:mm:ss · 1.0배)' / '꺼짐' / '대기(이유)'
        info.append(HubFill.shared.line)
        // ViewThatFits 가 고른 갈래 (0.38.0 C2) — 'choices: board-deadline 한 줄 · conf-row Cosyne 2027 한 줄 · …'
        info.append(LayoutChoice.line)
        // 글자·색 (0.37.0 C3) — 'display: 글자 1.3배 · 색 고대비 · 외형 light|dark'
        let d = HubDisplay.shared
        info.append("display: 글자 \(d.scaleLabel) · 색 \(d.presetLabel) · 외형 " + (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"))
        try? info.joined(separator: "\n").write(to: dir.appendingPathComponent("windows.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: 메뉴막대 아이콘

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "DeskHub")
            b.image?.isTemplate = true
        }
        // 왼쪽 클릭 = 팝오버, 오른쪽 클릭(또는 ⌥ 클릭) = 메뉴 (D12)
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(statusClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // 메뉴 막대 한 줄: 처음엔 데이터가 오기 전이라 20초 뒤 한 번, 그 뒤 1분마다
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.refreshMenuLine() }
        menuLineTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMenuLine() }
        }
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.option) == true || hubs.isEmpty {
            let menu = NSMenu(); menu.delegate = self
            rebuildMenu(menu)
            statusItem.menu = menu
            sender.performClick(nil)
            statusItem.menu = nil
            return
        }
        if let p = popover, p.isShown { p.performClose(nil); return }
        openPopover(anchor: sender)
    }

    /// 앵커가 있는 화면의 (화면, 가용 영역, 메뉴 막대 바닥). 메뉴 막대 높이는 시스템 상태 막대 두께 값(22) 이 아니라 상태 항목 창 바닥으로 —
    /// 노치 맥은 실제 39pt. 자동 숨김이어도 클릭하는 순간엔 막대가 보인다 (R-33)
    private func popoverGeometry(_ anchor: NSStatusBarButton) -> (screen: NSRect, visible: NSRect, bar: CGFloat?) {
        let scr = anchor.window?.screen ?? NSScreen.main
        return (scr?.frame ?? .zero, scr?.visibleFrame ?? .zero, anchor.window?.frame.minY)
    }

    /// 팝오버 열기 (R-33, 0.36.0) — 그 화면 메뉴 막대 바로 아래(여백 4)에서 시작하고, 가용 높이보다 길면 스크롤로 높이를 묶는다.
    /// 예전 offsetBy(dy: -6) 는 NSStatusBarButton 이 뒤집힌 좌표라 오히려 위로 6pt 올렸다 → 제거. 닫기 28×28·Esc·.transient·활성화는 그대로.
    /// 검증 1: anchor.bounds 그대로면 AppKit 자연 위치가 이미 막대 바로 아래(본문 윗선 여유 5pt, 이 맥 실측)다. positioningRect 를 알림마다
    /// 옮기던 보정은 과도기 frame 에 누적돼 61~82pt 떠 있었다 → 없앤다. 첫 frame 이 320×320 으로 잘리던 것은 sizingOptions·contentSize 로 막는다
    private func openPopover(anchor: NSStatusBarButton) {
        guard let m = hubs.values.first else { return }
        let g = popoverGeometry(anchor)
        let top = min(g.bar ?? g.visible.maxY, g.visible.maxY) - PopoverPlacement.margin
        let avail = top - (g.visible.minY + PopoverPlacement.margin) - 16
        let open: () -> Void = { [weak self] in self?.popover?.performClose(nil); self?.bringFront() }
        let close: () -> Void = { [weak self] in self?.popover?.performClose(nil) }
        let hc = NSHostingController(rootView: PopoverView(model: m, onOpenDashboard: open, onClose: close))
        // 띄우기 전 자연 높이를 재서 화면에 안 들어가면 스크롤 높이로 (데이터가 오기 전 높이일 수 있다 — 넘치면 아래 재클램프가 위를 지킨다)
        popoverFit = hc.view.fittingSize.height
        popoverCap = popoverFit > avail ? max(200, avail) : nil
        if let cap = popoverCap { hc.rootView = PopoverView(model: m, scrollHeight: cap, onOpenDashboard: open, onClose: close) }
        // 첫 frame 부터 내용 크기로 — 없으면 NSPopover 기본 320×320 으로 떴다가 몇 초 뒤 커져 머리·닫기가 잘려 보였다 (검증 1)
        hc.sizingOptions = [.preferredContentSize]
        let p = NSPopover()
        p.behavior = .transient
        p.delegate = self
        p.contentViewController = hc
        p.contentSize = NSSize(width: Hub.s(380), height: popoverCap ?? max(popoverFit, 120))
        // 메뉴 막대 앱은 활성이 아니면 바깥 클릭으로 팝오버가 안 닫힌다 → 띄울 때 활성화 (R2, JYK: '잘 안 꺼짐')
        NSApp.activate(ignoringOtherApps: true)
        // 열 때 TTL(120초) 지난 소스만 다시 조회 — 캐시 값으로 먼저 그리고 끝나면 제자리에서 바뀜 (UX menubar-glance-67)
        PopoverRefresh.willOpen(m)
        p.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        popover = p
        popoverAnchor = anchor
        popoverAdjusts = 0
        popoverClampPending = false
        clearPopoverObservers()
        if let win = hc.view.window {
            for n in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                popoverObservers.append(NotificationCenter.default.addObserver(forName: n, object: win, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.schedulePopoverClamp() }
                })
            }
        }
        // AppKit 이 크기·위치를 다 정한 다음 런루프에 한 번 — 과도기 frame(커지는 중 위로 뻗은 창)은 보지 않는다
        schedulePopoverClamp()
    }

    /// 알림을 다음 런루프 한 번으로 모은다. 내용이 커질 때 AppKit 은 didResize(위로 뻗은 과도기) → didMove(자연 위치) 순으로 옮기므로 끝난 뒤에 본다
    private func schedulePopoverClamp() {
        guard !popoverClampPending else { return }
        popoverClampPending = true
        DispatchQueue.main.async { [weak self] in
            self?.popoverClampPending = false
            self?.keepPopoverBelowBar()
        }
    }

    /// 팝오버 본문(창 그림자 여백 13pt 를 뺀 내용 사각형)의 화면 좌표
    private func popoverBody(_ p: NSPopover) -> (win: NSWindow, body: NSRect)? {
        guard let v = p.contentViewController?.view, let win = v.window else { return nil }
        return (win, win.convertToScreen(v.convert(v.bounds, to: nil)))
    }

    /// 팝오버 본문 윗선이 그 화면 메뉴 막대 아래(여백 4)에 있게 — 넘칠 때만 창 원점을 아래로(세로는 내리기만), 가로는 가용 영역 안.
    /// 매번 현재 본문에서 다시 계산하므로 누적되지 않는다(같은 상태면 같은 결과). 자연 위치가 이미 안쪽이면 아무것도 하지 않는다.
    /// 한 번 열 때 실제 이동은 최대 30번(AppKit 과 되먹임 방지)
    private func keepPopoverBelowBar() {
        guard let p = popover, p.isShown, let anchor = popoverAnchor, let (win, body) = popoverBody(p) else { return }
        let g = popoverGeometry(anchor)
        let c = PopoverPlacement.clamp(body, screen: g.screen, visible: g.visible, barBottom: g.bar)
        let dy = min(0, c.maxY - body.maxY)
        let dx = c.minX - body.minX
        guard abs(dx) > 0.5 || dy < -0.5, popoverAdjusts < 30 else { return }
        popoverAdjusts += 1
        win.setFrameOrigin(NSPoint(x: win.frame.minX + dx, y: win.frame.minY + dy))
    }

    private func clearPopoverObservers() {
        popoverObservers.forEach { NotificationCenter.default.removeObserver($0) }
        popoverObservers = []
    }

    /// windows.txt 'popover:' 줄 — shown·frame(창, 그림자 여백 포함)·body(보이는 본문)·screen·visible·bar·gap(막대 바닥 − 본문 윗선)·fit(자연 높이)·cap(스크롤 높이)·moves(보정 횟수)
    private var popoverDebugLine: String {
        let r: (NSRect) -> String = { PopoverPlacement.format($0) }
        guard let p = popover, p.isShown, let anchor = popoverAnchor, let (win, body) = popoverBody(p) else {
            return "popover: shown=false fit=\(Int(popoverFit)) cap=" + (popoverCap.map { String(Int($0)) } ?? "-")
        }
        let g = popoverGeometry(anchor)
        let line = min(g.bar ?? g.visible.maxY, g.visible.maxY)
        return "popover: shown=true frame=\(r(win.frame)) body=\(r(body)) screen=\(r(g.screen)) visible=\(r(g.visible)) bar=" + (g.bar.map { String(format: "%.0f", $0) } ?? "-")
            + String(format: " gap=%.1f", line - body.maxY) + " fit=\(Int(popoverFit)) cap=" + (popoverCap.map { String(Int($0)) } ?? "-") + " moves=\(popoverAdjusts)"
    }

    func refreshMenuLine() {
        MenuBarLine.apply(statusItem, model: hubs.values.first, now: HubClock.now)
    }

    @objc private func toggleUsage() { UsageLog.enabled.toggle() }

    @objc private func updateFromNAS() {
        guard let nu = AppUpdate.available() else { return }
        let a = NSAlert()
        a.messageText = "DeskHub \(nu.version) 로 바꿀까요?"
        a.informativeText = "NAS 의 배포본을 받아 설치하고 다시 띄웁니다 (몇 초)." + (nu.round.isEmpty ? "" : " 리뷰 라운드 \(nu.round) 버전입니다.")
        a.addButton(withTitle: "바꾸기"); a.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        AppUpdate.install(zip: nu.zip)
        NSApp.terminate(nil)
    }

    @objc private func setMenuLine(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let s = MenuLineStep(rawValue: raw) { MenuBarLine.step = s; refreshMenuLine() }
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "DeskHub — 바탕화면 위젯", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        // 메뉴 막대 한 줄 폭 (D11)
        let lineItem = NSMenuItem(title: "메뉴 막대 한 줄", action: nil, keyEquivalent: "")
        let lineMenu = NSMenu()
        for st in MenuLineStep.allCases {
            let it = NSMenuItem(title: st.title, action: #selector(setMenuLine(_:)), keyEquivalent: "")
            it.representedObject = st.rawValue; it.target = self
            it.state = MenuBarLine.step == st ? .on : .off
            lineMenu.addItem(it)
        }
        lineItem.submenu = lineMenu
        menu.addItem(lineItem)
        // 리뷰 라운드 새 버전 (리뷰 방식 개선 B2) — NAS latest.json 이 설치본보다 새로우면
        if let nu = AppUpdate.available() {
            let it = NSMenuItem(title: "새 버전 \(nu.version) 받기" + (nu.round.isEmpty ? "" : " (리뷰 라운드 \(nu.round))"), action: #selector(updateFromNAS), keyEquivalent: "")
            it.target = self
            menu.addItem(it)
        }
        let front = NSMenuItem(title: "대시보드 앞으로 (\(DeskHubNotice.hotkeyLabel))", action: #selector(bringFront), keyEquivalent: "")
        front.target = self
        menu.addItem(front)
        // 허브 창 확대 (0.43.0 C7, #51) — 바탕화면 층에서도 (창 단추는 꺼낸 상태에서만)
        let zoom = NSMenuItem(title: "허브 창 확대 / 원래 크기", action: #selector(zoomHubFromMenu), keyEquivalent: "")
        zoom.target = self; zoom.state = windows[hubSlotID]?.zoomRestore != nil ? .on : .off
        menu.addItem(zoom)
        let dock = NSMenuItem(title: "Dock·⌘Tab 에 보이기", action: #selector(toggleDock), keyEquivalent: "")
        dock.target = self; dock.state = AppDelegate.showInDock ? .on : .off
        menu.addItem(dock)
        // 사용 기록 (D13, 기본 꺼짐 — 결정 19)
        let usage = NSMenuItem(title: "사용 기록 (이 맥에만, 기본 꺼짐)", action: #selector(toggleUsage), keyEquivalent: "")
        usage.target = self; usage.state = UsageLog.enabled ? .on : .off
        menu.addItem(usage)
        menu.addItem(.separator())
        for slot in config.layout.slots {
            let item = NSMenuItem(title: slot.title ?? slot.kind?.defaultTitle ?? slot.id, action: #selector(toggleSlot(_:)), keyEquivalent: "")
            item.representedObject = slot.id
            item.state = (windows[slot.id]?.isVisible ?? false) ? .on : .off
            if let k = slot.kind { item.image = NSImage(systemSymbolName: k.symbol, accessibilityDescription: nil) }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let anyVisible = windows.values.contains { $0.isVisible }
        let hk = hotKey.map { " (\($0.label))" } ?? ""
        menu.addItem(withTitle: (anyVisible ? "모두 숨기기" : "다시 모두 보이기") + hk,
                     action: anyVisible ? #selector(hideAll) : #selector(showAll), keyEquivalent: "")
        if windows.values.contains(where: { $0.peeking && $0.isVisible }) {
            menu.addItem(withTitle: "바탕화면 층으로 내리기", action: #selector(settleAll), keyEquivalent: "")
        }
        func submenu(_ title: String, _ items: [(String, String, Bool)], _ action: Selector) {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu()
            for (label, value, on) in items {
                let it = NSMenuItem(title: label, action: action, keyEquivalent: "")
                it.representedObject = value; it.state = on ? .on : .off; it.target = self
                m.addItem(it)
            }
            parent.submenu = m
            menu.addItem(parent)
        }
        submenu("Theme", Theme.ids.compactMap { id in Theme.all[id].map { ($0.name, id, id == Theme.currentID) } }, #selector(chooseTheme(_:)))
        submenu("Appearance", [("System", "system", config.appearance == "system"), ("Light", "light", config.appearance == "light"),
                        ("Dark", "dark", config.appearance == "dark")], #selector(chooseAppearance(_:)))
        var screens: [(String, String, Bool)] = [("보조 모니터" + (Config.hasSecondary ? "" : " (지금 없음 — 숨긴 채 대기)"), "secondary", config.layout.screen == "secondary"),
                                                 ("주 모니터", "main", config.layout.screen == "main")]
        for s in NSScreen.screens.dropFirst() { screens.append(("  " + s.localizedName, s.localizedName, config.layout.screen == s.localizedName)) }
        submenu("표시할 모니터", screens, #selector(chooseScreen(_:)))
        let ver = NotionLink.appVersion
        let autoTo = ver.map { NotionLink.compare($0, NotionLink.minAppVersion) >= 0 ? "앱" : "웹 (앱 \($0) 이 오래됨)" } ?? "웹 (앱 없음)"
        let cur = config.notionHub.openLinksIn
        submenu("Notion 링크 열기", [("자동 — 지금은 \(autoTo)", "auto", cur == "auto"), ("Notion 앱", "app", cur == "app"), ("웹 브라우저", "web", cur == "web")],
                #selector(chooseNotionLinks(_:)))
        submenu("배치 방식", [("위젯 (카드만)", "widget", config.layout.mode == "widget"), ("바탕화면 전체 덮기", "desktop", config.layout.mode == "desktop")],
                #selector(chooseMode(_:)))
        menu.addItem(withTitle: "기본 배치로 되돌리기", action: #selector(resetLayout), keyEquivalent: "")
        menu.addItem(withTitle: "웹 위젯 모두 새로고침", action: #selector(reloadAll), keyEquivalent: "r")
        let calMode = NSMenuItem(title: config.calendar.mode == "web" ? "캘린더: 네이티브로 전환" : "캘린더: 웹(Google) 으로 전환",
                                 action: #selector(toggleCalendarMode), keyEquivalent: "")
        menu.addItem(calMode)
        menu.addItem(.separator())
        menu.addItem(withTitle: "설정 파일 열기…", action: #selector(openConfig), keyEquivalent: "")
        menu.addItem(withTitle: "설정 다시 읽기 (위젯 재생성)", action: #selector(reloadConfig), keyEquivalent: "")
        menu.addItem(withTitle: "웹 로그인 데이터 지우기…", action: #selector(clearWebData), keyEquivalent: "")
        let login = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.state = LaunchAgent.isInstalled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: "DeskHub 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != nil && item.target == nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
    }

    @objc private func toggleSlot(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let w = windows[id],
              let i = config.layout.slots.firstIndex(where: { $0.id == id }) else { return }
        if w.isVisible { w.orderOut(nil) } else { w.orderFront(nil) }
        config.layout.slots[i].visible = w.isVisible
        // 오늘 일정 카드를 켜고 끄면 허브 폭을 맞춘다 (켜면 1/3 | 2/3, 끄면 허브 전체 폭) — v13 BHL ②안
        if id == "calendar", let h = config.layout.slots.firstIndex(where: { $0.id == "csnl-hub" }) {
            let third = 1.0 / 3.0
            config.layout.slots[h].frame = w.isVisible ? FracRect(x: third, y: 0, w: 1 - third, h: 1) : FracRect(x: 0, y: 0, w: 1, h: 1)
            relayout()
        }
        config.save()
    }
    /// 보이는 슬롯만 띄운다. peek = 다른 창 위로 (단축키로 꺼낼 때)
    private func placeAll(peek: Bool) {
        for slot in config.layout.slots where slot.visible {
            guard let w = windows[slot.id] else { continue }
            w.peeking = peek
            w.orderFront(nil)
            if peek { w.orderFrontRegardless() }
        }
        if !peek { backdrop?.orderFront(nil) }
    }
    /// 메뉴 "다시 모두 보이기" — 바탕화면 층(제자리)에
    @objc func showAll() {
        hiddenByUser = false
        // 카드별로 꺼 둔 것(예: 오늘 일정 카드, v13 기본 숨김)은 그대로 둔다 — 메뉴의 카드 항목으로 켠다
        placeAll(peek: false)
    }
    @objc private func hideAll() {
        // 확대한 창은 원래 크기로 돌린 뒤 숨긴다 — 다시 꺼내면 늘 원래 비율 (0.43.0 C7)
        for id in windows.keys where windows[id]?.zoomRestore != nil { toggleZoom(id) }
        hiddenByUser = true
        for w in windows.values { w.orderOut(nil); w.peeking = false }
        backdrop?.orderOut(nil)
    }
    /// 대시보드를 다른 창 위로 (팝오버 버튼·메뉴 — 단축키와 같은 '꺼내기', R2: SMJ '항상 다른 창 아래에 깔림')
    @objc func bringFront() { hiddenByUser = false; placeAll(peek: true) }

    /// Dock·⌘Tab 에 보이기 (R2, SMJ UX 로그: '일반 앱처럼 전환') — 기본은 메뉴 막대 앱
    static var showInDock: Bool {
        get { UserDefaults.standard.bool(forKey: "DeskHub.showInDock") }
        set { UserDefaults.standard.set(newValue, forKey: "DeskHub.showInDock") }
    }
    @objc private func toggleDock() {
        AppDelegate.showInDock.toggle()
        NSApp.setActivationPolicy(AppDelegate.showInDock ? .regular : .accessory)
    }

    /// 단축키: 보이면 숨기고, 숨어 있으면 다른 창 위로 꺼낸다
    @objc private func toggleAll() {
        if windows.values.contains(where: { $0.isVisible }) { hideAll() }
        else { hiddenByUser = false; placeAll(peek: true) }
    }
    // MARK: 창 확대·더블클릭 (0.43.0 C7, #51) — styleMask 는 그대로(borderless), 확대 = 쓸 수 있는 화면 영역 채우기

    /// 허브 슬롯 id — 메뉴·--key window:* 기본 대상
    private var hubSlotID: String { config.layout.slots.first { $0.kind == .notionhub }?.id ?? "csnl-hub" }
    /// 확대 ↔ 원래 크기. 확대 = 그 창 화면의 usableRect(읽기만), 원래 = zoomRestore. 어느 쪽도 config 에 저장하지 않는다
    func toggleZoom(_ slotID: String) {
        guard let w = windows[slotID] else { NSSound.beep(); return }
        zoomChanging = true
        if let r = w.zoomRestore {
            w.zoomRestore = nil
            w.setFrame(r, display: true)
        } else {
            w.zoomRestore = w.frame
            w.setFrame(config.usableRect(on: w.screen), display: true)
        }
        zoomChanging = false
    }
    @objc private func windowZoomRequested(_ note: Notification) { toggleZoom((note.object as? String) ?? hubSlotID) }
    @objc private func zoomHubFromMenu() { toggleZoom(hubSlotID) }
    @objc private func titleDoubleClicked(_ note: Notification) {
        guard let w = note.object as? WidgetWindow else { return }
        handleDoubleClick(w.slotID)
    }
    /// 제목 막대 더블클릭과 --key window:dblclick 이 같은 처리 — 시스템 설정(WindowChrome.current)에 따라 확대 · 내리기(꺼냈으면 바탕화면 층, 이미 바탕화면이면 그대로 — 숨기지 않음) · 없음
    private func handleDoubleClick(_ slotID: String) {
        switch WindowChrome.current {
        case .zoom: toggleZoom(slotID)
        case .lower: if windows.values.contains(where: { $0.peeking }) { settleAll() }
        case .none: break
        }
    }

    /// 꺼낸(위에 뜬) 카드를 바탕화면 층으로 내린다
    @objc private func settleAll() {
        for w in windows.values where w.peeking { w.peeking = false; w.orderFront(nil) }
    }
    @objc private func chooseTheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        config.theme = id; config.save(); reloadConfig()
    }
    @objc private func chooseAppearance(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? String else { return }
        config.appearance = v; config.save(); reloadConfig()
    }
    @objc private func chooseScreen(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? String else { return }
        config.layout.screen = v; config.save(); hiddenByUser = false; reloadConfig()
    }
    @objc private func chooseNotionLinks(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? String else { return }
        config.notionHub.openLinksIn = v; NotionLink.mode = v; config.save()
    }
    @objc private func chooseMode(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? String else { return }
        config.layout.mode = v; config.layout.backdrop = v == "desktop"; config.save(); reloadConfig()
    }
    @objc private func resetLayout() {
        let defaults = Config.defaultSlots()
        for (i, s) in config.layout.slots.enumerated() {
            if let d = defaults.first(where: { $0.id == s.id }) { config.layout.slots[i].frame = d.frame }
        }
        relayout()
        config.save()
    }
    @objc private func reloadAll() {
        controllers.values.forEach { $0.reload() }; explorer?.refresh(); calendars.values.forEach { $0.refresh() }
        hubs.values.forEach { h in Task { await h.refresh() } }
    }
    @objc private func toggleCalendarMode() {
        config.calendar.mode = config.calendar.mode == "web" ? "auto" : "web"
        config.save()
        reloadConfig()
    }
    @objc private func openConfig() { config.save(); NSWorkspace.shared.open(Config.fileURL) }
    @objc private func reloadConfig() {
        tearDownAll()
        config = Config.load()
        applyTheme()
        if hotKey == nil || hotKey?.label != HotKey.parse(config.layout.hotkey)?.2 { hotKey = nil; registerHotKey() }
        buildAll()
    }
    @objc private func clearWebData() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "웹 로그인 데이터를 지울까요?"
        a.informativeText = "Notion · Google 등 웹 위젯의 쿠키와 로그인 상태가 모두 삭제되고 다시 로그인해야 합니다."
        a.addButton(withTitle: "지우기"); a.addButton(withTitle: "취소")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
            self?.controllers.values.forEach { $0.home() }
        }
    }
    @objc private func toggleLaunchAtLogin() {
        if LaunchAgent.isInstalled { LaunchAgent.uninstall() } else { LaunchAgent.install() }
    }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        clearPopoverObservers()
    }
}

/// 팝오버 창 클램프 (R-33, 0.36.0) — 순수 함수. 윗선 = min(메뉴 막대 바닥 ?? visible.maxY, visible.maxY) − margin, 아랫선 = visible.minY + margin,
/// 가로는 visible 안(여백 margin). 위로 넘치면 내리고, 그래도 아랫선을 넘으면 높이를 줄인다. 시스템 상태 막대 두께 값은 쓰지 않는다(노치 맥 22 ≠ 실제 39).
/// --text-check 의 clamp 줄이 노치 맥·세로·위쪽 보조·자동 숨김·bar 모름·화면보다 큼을 확인한다
enum PopoverPlacement {
    static let margin: CGFloat = 4
    static func clamp(_ f: NSRect, screen: NSRect, visible: NSRect, barBottom: CGFloat?, margin: CGFloat = PopoverPlacement.margin) -> NSRect {
        let vis = visible.isEmpty ? screen : visible
        let top = min(barBottom ?? vis.maxY, vis.maxY) - margin
        let bottom = vis.minY + margin
        var r = f
        if r.maxY > top { r.origin.y = top - r.height }
        if r.minY < bottom {
            r.origin.y = bottom
            if r.maxY > top { r.size.height = max(0, top - bottom) }
        }
        if r.maxX > vis.maxX - margin { r.origin.x = vis.maxX - margin - r.width }
        if r.minX < vis.minX + margin { r.origin.x = vis.minX + margin }
        return r
    }
    /// "x,y,w,h" (정수면 정수로) — fixture·windows.txt 공통
    static func format(_ r: NSRect) -> String {
        [r.minX, r.minY, r.width, r.height].map { $0 == $0.rounded() ? String(Int($0)) : String(format: "%.1f", $0) }.joined(separator: ",")
    }
    /// "x,y,w,h" → NSRect
    static func parse(_ s: String) -> NSRect? {
        let v = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return v.count == 4 ? NSRect(x: v[0], y: v[1], width: v[2], height: v[3]) : nil
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu(menu) }
}

/// 캘린더 슬롯: 설정/소스 상태에 따라 네이티브 뷰와 웹뷰를 고른다.
/// 캘린더 위젯 모드(auto|web|native) — @State 대신 참조로 둔다. 글자·색을 바꾸면 창 본문을 .id 로 다시 만드는데(DisplayRefresh)
/// @State 는 창을 만들 때 넘긴 값으로 돌아가 '웹으로' 고른 것이 풀렸다 (0.37.0 검증 1 리뷰). 상자는 창과 함께 한 번 만든다
final class CalendarModeBox: ObservableObject {
    @Published var mode: String
    init(_ mode: String) { self.mode = mode }
}

struct CalendarHost: View {
    @ObservedObject var model: CalendarModel
    @ObservedObject var web: WebController
    @ObservedObject var modeBox: CalendarModeBox
    let focusStart: Int
    let onModeChange: (String) -> Void

    private var useWeb: Bool {
        if modeBox.mode == "web" { return true }
        if modeBox.mode == "native" { return false }
        return model.status == .noSource || model.status == .denied
    }

    var body: some View {
        Group {
            if useWeb {
                CalendarWebWidget(controller: web, focusStart: focusStart) {
                    modeBox.mode = "native"; onModeChange("native")
                }
                .onAppear { web.ensureLoaded() }
            } else {
                CalendarNativeWidget(model: model) { modeBox.mode = "web"; onModeChange("web") }
            }
        }
    }
}

enum LaunchAgent {
    static let label = AppDelegate.bundleID
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }
    static func install() {
        let appPath = Bundle.main.bundleURL.path
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-g", "-a", appPath],
            "RunAtLoad": true, "KeepAlive": false, "ProcessType": "Interactive",
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: plistURL)
            run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
        }
    }
    static func uninstall() {
        run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }
    private static func run(_ path: String, _ args: [String]) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        try? p.run(); p.waitUntilExit()
    }
}
