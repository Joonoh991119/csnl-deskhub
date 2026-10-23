import SwiftUI
import AppKit
import Combine

// MARK: - 논문 커뮤니티 창 (1.0.0 B2, R5 — 계획 docs/plan-1.0.0-2026-10-23.md §B2, 설계 §5 ③)
// 여는 길은 하나: NSApp.sendAction(Selector(("openDeskHubCommunity:")), to: nil, from: <논문 page id String>) — Main 카드·--key community:<q> 가 같은 액션.
// 창 = 일반 NSWindow(제목 막대·닫기·최소화·크기 조절), 같은 논문은 창 하나. 내용 = 제목·저자·연도·DOI / Abstract(OpenAlex·캐시) / 왜 추천했나 /
// 읽겠음 👍·읽었음 ✅ / 댓글. 반응·댓글은 NotionHubModel.addPaperComment 한 경로(드라이런 훅 그대로). 열 때 그 페이지 댓글만 새로 읽는다.
// 시험 길(창이 열려 있을 때만 구독): KeyBus community-react:<읽겠음|읽었음> · community-send:<글>(드라이런 훅 있을 때만) · community-close,
// 분산 알림 .snapshot → community.png · .dumptext → community.txt

extension NSApplication {
    /// sender = 논문 page id (String/NSString). 모델에 그 논문이 없으면 삐
    @objc func openDeskHubCommunity(_ sender: Any?) {
        guard let id = sender as? String, !id.isEmpty,
              let model = (NSApp.delegate as? AppDelegate)?.hubs.values.first,
              let paper = model.papers.first(where: { $0.id == id }) else { NSSound.beep(); return }
        CommunityWindowController.open(model: model, paper: paper)
    }
}

// MARK: abstract (OpenAlex · 캐시 · 고정)

enum CommunityDOI {
    /// "https://doi.org/10.1/X" · "doi:10.1/x" · "10.1/x" → "10.1/x" (소문자). DOI 꼴이 아니면 빈 값
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for p in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/", "doi:"] where s.hasPrefix(p) {
            s = String(s.dropFirst(p.count)); break
        }
        return s.hasPrefix("10.") ? s : ""
    }
}

extension OpenAlex {
    /// DOI 하나의 abstract(단어 위치 색인을 복원) · 출판 연도. 네트워크 실패면 nil, abstract 가 없으면 빈 글
    static func abstract(doi: String) async -> (abstract: String, year: Int?)? {
        let path = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
        guard let url = URL(string: "https://api.openalex.org/works/doi:\(path)?select=abstract_inverted_index,publication_year&mailto=csnl@snu.ac.kr") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return ("", nil) }
        guard code < 300, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let year = obj["publication_year"] as? Int
        return (restore(obj["abstract_inverted_index"] as? [String: [Int]] ?? [:]), year)
    }
    /// {"word": [0, 5], …} → 위치 순서대로 이은 글
    static func restore(_ index: [String: [Int]]) -> String {
        var slots: [Int: String] = [:]
        for (w, ps) in index { for p in ps { slots[p] = w } }
        return slots.keys.sorted().compactMap { slots[$0] }.joined(separator: " ")
    }
}

/// abstract 얻는 곳 한 곳 — 고정(DESKHUB_ABSTRACT_FIXTURE) → 메모리·파일 캐시(abstract-cache.json) → OpenAlex.
/// 캐시에는 OpenAlex 가 abstract 를 준 것만 쓴다(없음은 다음에 다시 물음)
@MainActor
enum CommunityAbstract {
    struct Result { let text: String; let year: Int?; let source: String }   // source = OpenAlex|고정|캐시|없음|DOI 없음
    private static var memory: [String: [String: Any]] = [:]
    private static var loaded = false
    private static var file: URL { Config.directory.appendingPathComponent("abstract-cache.json") }

    private static func fixture() -> [String: Any]? {
        guard let p = ProcessInfo.processInfo.environment["DESKHUB_ABSTRACT_FIXTURE"], !p.isEmpty,
              let d = try? Data(contentsOf: URL(fileURLWithPath: (p as NSString).expandingTildeInPath)),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        var out: [String: Any] = [:]
        for (k, v) in o { let n = CommunityDOI.normalize(k); out[n.isEmpty ? k.lowercased() : n] = v }
        return out
    }

    static func load(doi raw: URL?) async -> Result {
        guard let raw else { return Result(text: "", year: nil, source: "DOI 없음") }
        let doi = CommunityDOI.normalize(raw.absoluteString)
        guard !doi.isEmpty else { return Result(text: "", year: nil, source: "DOI 없음") }
        if let fx = fixture() {
            // 값은 글 하나 또는 {"abstract": 글, "year": n}
            if let s = fx[doi] as? String { return Result(text: s, year: nil, source: "고정") }
            if let o = fx[doi] as? [String: Any] { return Result(text: o["abstract"] as? String ?? "", year: o["year"] as? Int, source: "고정") }
        }
        if !loaded {
            loaded = true
            if let d = try? Data(contentsOf: file), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: [String: Any]] { memory = o }
        }
        if let hit = memory[doi], let t = hit["abstract"] as? String, !t.isEmpty {
            return Result(text: t, year: hit["year"] as? Int, source: "캐시")
        }
        guard let got = await OpenAlex.abstract(doi: doi) else { return Result(text: "", year: nil, source: "없음") }
        guard !got.abstract.isEmpty else { return Result(text: "", year: got.year, source: "없음") }
        var entry: [String: Any] = ["abstract": got.abstract]
        if let y = got.year { entry["year"] = y }
        memory[doi] = entry
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: memory, options: [.sortedKeys]) { try? d.write(to: file, options: .atomic) }
        return Result(text: got.abstract, year: got.year, source: "OpenAlex")
    }
}

// MARK: 창 상태

@MainActor
final class CommunityState: ObservableObject {
    let paperID: String
    @Published var abstract: CommunityAbstract.Result?
    /// 이 창이 그 페이지 댓글을 마지막으로 읽은 시각(실제 시계 — 다시 열면 바뀌어야 하므로 DESKHUB_NOW 를 쓰지 않음)
    @Published var readAt: Date?
    @Published var readError: String?
    @Published var draft = ""
    @Published var askWho = false
    /// 단추 높이 최솟값 (TapHeightKey)
    var minButton: CGFloat = .infinity
    init(paperID: String) { self.paperID = paperID }
}

// MARK: 창

@MainActor
final class CommunityWindowController: NSObject, NSWindowDelegate {
    /// page id → 열린 창 (같은 논문은 하나)
    private static var open: [String: CommunityWindowController] = [:]
    /// 시험 키·스냅샷이 가리키는 창 — 마지막으로 열었거나 앞으로 온 것
    private static var currentID: String?

    let model: NotionHubModel
    let state: CommunityState
    var paper: PaperRec
    let window: NSWindow
    private var keySub: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    /// 닫는 중(표에서 빠지기 전) — 이때 다시 열면 새 창
    private var closing = false

    static func open(model: NotionHubModel, paper: PaperRec) {
        let byClick = NSApp.currentEvent.map { [.leftMouseUp, .leftMouseDown].contains($0.type) } ?? false
        if let c = open[paper.id], !c.closing {
            currentID = paper.id
            c.present(activate: byClick)
            Task { await c.refresh() }
            return
        }
        let c = CommunityWindowController(model: model, paper: paper)
        open[paper.id] = c
        currentID = paper.id
        c.start()
        c.present(activate: byClick)
    }

    private init(model: NotionHubModel, paper: PaperRec) {
        self.model = model; self.paper = paper
        self.state = CommunityState(paperID: paper.id)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Hub.s(560), height: Hub.s(680)),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = paper.title.isEmpty ? "논문 커뮤니티" : paper.title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 360, height: 420)
        let host = NSHostingView(rootView: DisplayRefresh(CommunityView(model: model, state: state, fallback: paper,
                                                                       close: { [weak self] in self?.window.performClose(nil) })))
        // SwiftUI 이상 높이(본문 전체)로 창을 늘리지 않는다 — 검증 1: 840×5203pt 로 커져 댓글 칸·보내기가 화면 밖.
        // 크기는 아래 고정값(화면 visibleFrame 상한)이고, 본문은 CommunityView 안 ScrollView 가, 입력 줄은 아래에 고정
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(Self.fittedSize())
        window.center()
    }

    /// Hub.s(560)×Hub.s(680) 를 화면 visibleFrame(제목 막대·여백 빼고) 안으로
    static func fittedSize() -> NSSize {
        let vis = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        return NSSize(width: min(Hub.s(560), max(360, vis.width - 40)), height: min(Hub.s(680), max(420, vis.height - 60)))
    }

    private func present(activate: Bool) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        if activate { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
        else { window.orderFrontRegardless() }
    }

    /// 열 때 한 번 — abstract 읽기 · 그 페이지 댓글 새로 읽기 · 시험 키·분산 알림 구독
    private func start() {
        // KeyBus 의 지난 값은 다시 받지 않는다(dropFirst — 이전 community-send 가 새 창에서 또 보내지지 않게)
        keySub = KeyBus.shared.$event.dropFirst().compactMap { $0 }.sink { [weak self] e in
            MainActor.assumeIsolated { self?.key(e.key) }
        }
        let dc = DistributedNotificationCenter.default()
        observers.append(dc.addObserver(forName: Notification.Name(AppDelegate.bundleID + ".snapshot"), object: nil, queue: .main) { [weak self] n in
            let dir = n.object as? String
            MainActor.assumeIsolated { self?.snapshot(dir: dir) }
        })
        observers.append(dc.addObserver(forName: Notification.Name(AppDelegate.bundleID + ".dumptext"), object: nil, queue: .main) { [weak self] n in
            let dir = n.object as? String
            MainActor.assumeIsolated { self?.dump(dir: dir) }
        })
        let doi = paper.doi
        Task { [weak self] in
            let r = await CommunityAbstract.load(doi: doi)
            self?.state.abstract = r
        }
        Task { await refresh() }
    }

    /// 그 페이지 댓글만 새로 읽기 — Notion(+ 드라이런 줄), 토큰이 없으면 드라이런 줄만. 이후는 모델 10분 주기 값이 그대로 보인다
    func refresh() async {
        let id = paper.id, dry = NotionDryRun.path
        if let api = NotionAPI(cfg: model.cfg) {
            do {
                var cs = try await api.comments(page: id)
                if let dry { cs = NotionDryRun.merge(cs, NotionDryRun.comments(path: dry)[id] ?? []) }
                model.paperComments[id] = cs
                state.readAt = Date(); state.readError = nil
            } catch {
                state.readError = "댓글을 읽지 못했습니다 — \(error.localizedDescription)"
            }
        } else if let dry {
            model.paperComments[id] = NotionDryRun.merge(model.paperComments[id] ?? [], NotionDryRun.comments(path: dry)[id] ?? [])
            state.readAt = Date(); state.readError = nil
        } else {
            state.readError = "Notion 연결 전 — 댓글을 읽을 수 없습니다"
        }
    }

    // MARK: 시험 키 (현재 창만)
    private func key(_ k: String) {
        guard Self.currentID == paper.id else { return }
        if k == "community-close" { window.performClose(nil); return }
        if k.hasPrefix("community-react:") {
            // 댓글은 지울 수 없다 → 키로는 드라이런 훅이 있을 때만
            guard NotionDryRun.path != nil else { NSSound.beep(); return }
            let label = String(k.dropFirst("community-react:".count))
            guard let e = CommunityView.reactions.first(where: { $0.label == label })?.emoji else { NSSound.beep(); return }
            CommunityView.react(model: model, state: state, page: paper.id, emoji: e)
        } else if k.hasPrefix("community-send:") {
            guard NotionDryRun.path != nil else { NSSound.beep(); return }
            let t = String(k.dropFirst("community-send:".count))
            CommunityView.send(model: model, state: state, page: paper.id, text: t)
        }
    }

    // MARK: 덤프·스냅샷
    private func snapshot(dir: String?) {
        guard Self.currentID == paper.id, window.isVisible else { return }
        let d = URL(fileURLWithPath: dir ?? NSTemporaryDirectory(), isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let url = d.appendingPathComponent("community.png")
        if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
           let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
            try? png.write(to: url); return
        }
        // 창 그림을 못 얻으면 내용만
        if let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    private func dump(dir: String?) {
        // 열린 창마다 한 줄 — 현재 창이 먼저. 파일은 현재 창이 쓴다(여러 창이 같은 파일을 겹쳐 쓰지 않게)
        guard Self.currentID == paper.id else { return }
        let d = URL(fileURLWithPath: dir ?? NSTemporaryDirectory(), isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let others = Self.open.values.filter { $0 !== self }.sorted { $0.paper.id < $1.paper.id }
        let lines = ([self] + others).map { $0.dumpLine() }
        try? (lines.joined(separator: "\n") + "\n").write(to: d.appendingPathComponent("community.txt"), atomically: true, encoding: .utf8)
    }

    func dumpLine() -> String {
        let p = model.papers.first(where: { $0.id == paper.id }) ?? paper
        let mask = window.styleMask
        let win = (mask.contains(.titled) ? "titled" : "untitled") + " " + (mask.contains(.closable) ? "closable" : "noclose")
        let abs: String = {
            guard let a = state.abstract else { return "불러오는 중 0자" }
            return "\(a.source) \(a.text.count)자"
        }()
        let why = p.recommendation.trimmingCharacters(in: .whitespacesAndNewlines)
        let cs = model.paperComments[p.id] ?? []
        let me = HubPrefs.me
        let mine = CommunityView.reactions.filter { r in cs.contains { $0.isReaction && $0.text == r.emoji && !me.isEmpty && $0.who == me.uppercased() } }.map(\.emoji)
        let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"
        let read = CommunityView.lastRead(state: state, model: model).map { tf.string(from: $0) } ?? "—"
        let btn = state.minButton.isFinite ? "\(Int(state.minButton.rounded(.down)))" : "—"
        return "[커뮤니티] \(String(p.id.prefix(8))) · \(String(p.title.prefix(40))) · 창 \(win) · abstract \(abs)"
            + " · 이유 " + (why.isEmpty ? "없음" : "\(why.count)자")
            + " · 반응 👍\(cs.filter { $0.isReaction && $0.text == "👍" }.count) ✅\(cs.filter { $0.isReaction && $0.text == "✅" }.count)"
            + " · 나 \(me.isEmpty ? "—" : me) " + (mine.isEmpty ? "—" : mine.joined())
            + " · 댓글 \(cs.filter(\.isNote).count) · 읽음 \(read) · 단추 최소 높이 \(btn)"
    }

    // MARK: NSWindowDelegate
    func windowDidBecomeKey(_ notification: Notification) { Self.currentID = paper.id }
    func windowWillClose(_ notification: Notification) {
        closing = true
        keySub?.cancel(); keySub = nil
        let dc = DistributedNotificationCenter.default()
        for o in observers { dc.removeObserver(o) }
        observers = []
        let id = paper.id
        if Self.currentID == id { Self.currentID = Self.open.keys.filter { $0 != id }.sorted().first }
        // 닫는 중에 창(이 객체가 가진)이 풀리지 않게 표에서 빼는 것은 다음 바퀴에
        DispatchQueue.main.async { [self] in
            window.delegate = nil
            if Self.open[id] === self { Self.open[id] = nil }
        }
    }
}

// MARK: 창 내용

struct CommunityView: View {
    @ObservedObject var model: NotionHubModel
    @ObservedObject var state: CommunityState
    let fallback: PaperRec
    let close: () -> Void
    @ObservedObject private var display = HubDisplay.shared
    private let cs = CardStyle.large

    static let reactions: [(emoji: String, label: String)] = [("👍", "읽겠음"), ("✅", "읽었음")]

    /// 같은 이모지를 이미 남겼으면 취소 댓글('✖👍') — PaperRecBoard.react 와 같은 규칙(결정 D-9)
    static func react(model: NotionHubModel, state: CommunityState, page: String, emoji: String) {
        let me = HubPrefs.me
        guard !me.isEmpty, HubPrefs.meChosen else { state.askWho = true; NSSound.beep(); return }
        let already = (model.paperComments[page] ?? []).contains { $0.isReaction && $0.text == emoji && $0.who == me.uppercased() }
        Task { await model.addPaperComment(page: page, text: "[\(me)] " + (already ? HubPrefs.cancelMark + emoji : emoji)) }
    }
    static func send(model: NotionHubModel, state: CommunityState, page: String, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let me = HubPrefs.me
        guard !me.isEmpty, HubPrefs.meChosen else { state.askWho = true; NSSound.beep(); return }
        Task { await model.addPaperComment(page: page, text: "[\(me)] \(t)") }
    }
    /// 이 창이 읽은 시각과 모델 10분 주기 읽기 중 나중 것
    @MainActor static func lastRead(state: CommunityState, model: NotionHubModel) -> Date? {
        [state.readAt, model.paperCommentsReadAt].compactMap { $0 }.max()
    }

    var body: some View {
        let p = model.papers.first(where: { $0.id == fallback.id }) ?? fallback
        let comments = model.paperComments[p.id] ?? []
        VStack(alignment: .leading, spacing: 12) {
            header(p)
            if !HubPrefs.meChosen || state.askWho { MeConfirmBar(model: model) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Abstract") { abstractBody }
                    section("왜 추천했나") {
                        let why = p.recommendation.trimmingCharacters(in: .whitespacesAndNewlines)
                        Text(why.isEmpty ? "요약 없음" : why).font(.hub(cs.body)).foregroundStyle(why.isEmpty ? Hub.text3 : Hub.text)
                            .lineSpacing(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    section("반응") { reactionRow(p, comments) }
                    section("댓글 · \(comments.filter(\.isNote).count)") { notesList(comments.filter(\.isNote)) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 6)
            }
            inputRow(p)
            footer
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Hub.card)
        .foregroundStyle(Hub.text)
        .environment(\.cardStyle, cs)
        .onPreferenceChange(TapHeightKey.self) { h in MainActor.assumeIsolated { state.minButton = h } }
    }

    private func header(_ p: PaperRec) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if !p.tier.isEmpty {
                        Text(p.tier).font(.hub(cs.tag, weight: .bold, design: .rounded))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Hub.ink.opacity(p.tier == "S" ? 0.22 : 0.12)))
                            .foregroundStyle(Hub.ink)
                    }
                    if !p.researcher.isEmpty { Text("추천: \(p.researcher)").font(.hub(cs.aux)).foregroundStyle(Hub.text2) }
                }
                Text(p.title).font(.hub(cs.big + 2, weight: .bold)).lineSpacing(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                let year = state.abstract?.year.map(String.init) ?? ""
                let byline = [p.authors, year].filter { !$0.isEmpty }.joined(separator: " · ")
                if !byline.isEmpty {
                    Text(byline).font(.hub(cs.aux)).foregroundStyle(Hub.text2).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                if let d = p.doi {
                    Button { NSWorkspace.shared.open(d) } label: {
                        Text("DOI ↗").font(.hub(cs.aux, weight: .semibold)).padding(.horizontal, 10)
                            .frame(minHeight: TapTarget.min)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Hub.fillNeutral))
                    }
                    .buttonStyle(PressFillStyle()).help(d.absoluteString).tapProbe()
                }
            }
            Spacer(minLength: 8)
            Button(action: close) {
                HStack(spacing: 4) { Text("닫기"); Image(systemName: "xmark") }
                    .font(.hub(cs.aux, weight: .semibold)).padding(.horizontal, 12)
                    .frame(minWidth: TapTarget.min, minHeight: TapTarget.min)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Hub.fillNeutral))
            }
            .buttonStyle(PressFillStyle()).keyboardShortcut(.cancelAction).help("창 닫기 (Esc)").tapProbe()
        }
    }

    @ViewBuilder private var abstractBody: some View {
        if let a = state.abstract {
            if a.text.isEmpty {
                Text(a.source == "DOI 없음" ? "abstract 없음 — DOI 가 없습니다" : "abstract 없음").font(.hub(cs.body)).foregroundStyle(Hub.text3)
            } else {
                Text(a.text).font(.hub(cs.body)).lineSpacing(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        } else {
            Text("불러오는 중…").font(.hub(cs.body)).foregroundStyle(Hub.text3)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.hub(cs.aux, weight: .bold)).foregroundStyle(Hub.text2)
            content()
        }
    }

    private func reactionRow(_ p: PaperRec, _ comments: [PaperComment]) -> some View {
        let me = HubPrefs.me.uppercased()
        return HStack(spacing: 10) {
            ForEach(Self.reactions, id: \.emoji) { r in
                let who = comments.filter { $0.isReaction && $0.text == r.emoji }.map(\.who)
                let mine = !me.isEmpty && who.contains(me)
                Button { Self.react(model: model, state: state, page: p.id, emoji: r.emoji) } label: {
                    HStack(spacing: 6) {
                        Text(r.emoji)
                        Text(r.label).font(.hub(cs.aux, weight: .semibold))
                        Text("\(who.count)").font(.hub(cs.aux, weight: .bold, design: .rounded)).monospacedDigit()
                        if !who.isEmpty {
                            Text(who.map { $0.isEmpty ? "?" : $0 }.joined(separator: " · ")).font(.hub(cs.tag)).foregroundStyle(Hub.text2).lineLimit(1)
                        }
                    }
                    .font(.hub(cs.body))
                    .padding(.horizontal, 12).frame(minHeight: TapTarget.min)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(mine ? Hub.ink.opacity(0.16) : Hub.fillNeutral))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(mine ? Hub.ink.opacity(0.5) : Color.clear))
                }
                .buttonStyle(PressFillStyle(cornerRadius: 10)).tapProbe()
                .help(mine ? "\(r.emoji) \(r.label) — 다시 누르면 취소(취소 댓글로 남습니다)" : "\(r.emoji) \(r.label) 남기기 — Notion 댓글로 남습니다")
            }
            Spacer(minLength: 0)
        }
    }

    private func notesList(_ notes: [PaperComment]) -> some View {
        let f = DateFormatter(); f.dateFormat = "M.d HH:mm"
        return VStack(alignment: .leading, spacing: 8) {
            if notes.isEmpty {
                Text("아직 댓글이 없습니다").font(.hub(cs.aux)).foregroundStyle(Hub.text3)
            }
            ForEach(notes) { c in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(c.who.isEmpty ? "?" : c.who).font(.hub(cs.tag, weight: .bold, design: .rounded)).foregroundStyle(Hub.ink)
                        .frame(width: cs.col(40), alignment: .leading)
                    Text(c.text).font(.hub(cs.aux)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Spacer(minLength: 4)
                    if let d = c.created { Text(f.string(from: d)).font(.hub(cs.tag)).foregroundStyle(Hub.text3).monospacedDigit() }
                }
            }
        }
    }

    private func inputRow(_ p: PaperRec) -> some View {
        let me = HubPrefs.me
        let empty = state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 8) {
            TextField(me.isEmpty ? "먼저 위에서 이니셜을 고르세요" : "\(me) 로 댓글 남기기 (Enter)", text: $state.draft)
                .textFieldStyle(.roundedBorder).font(.hub(cs.aux))
                .onSubmit { submit(p) }
            Button { submit(p) } label: {
                Text("보내기").font(.hub(cs.aux, weight: .semibold)).padding(.horizontal, 14)
                    .frame(minWidth: TapTarget.min, minHeight: TapTarget.min)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(empty ? Hub.fillNeutral : Hub.ink))
                    .foregroundStyle(empty ? Hub.text3 : Hub.onAccent)
            }
            .buttonStyle(PressFillStyle()).disabled(empty).tapProbe()
            .help("Notion 댓글로 남습니다 — 지울 수 없음")
        }
    }

    private func submit(_ p: PaperRec) {
        let t = state.draft
        guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !HubPrefs.me.isEmpty, HubPrefs.meChosen else { state.askWho = true; NSSound.beep(); return }
        state.draft = ""
        Self.send(model: model, state: state, page: p.id, text: t)
    }

    private var footer: some View {
        let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"
        let read = Self.lastRead(state: state, model: model)
        return HStack(spacing: 8) {
            Text(read.map { "댓글 읽음 \(tf.string(from: $0)) · 10분마다·열 때 새로 고침" } ?? "댓글 읽는 중…")
                .font(.hub(cs.tag)).foregroundStyle(Hub.text3)
            if let e = state.readError { Text(e).font(.hub(cs.tag)).foregroundStyle(Hub.text2).lineLimit(1) }
            Spacer(minLength: 0)
        }
    }
}
