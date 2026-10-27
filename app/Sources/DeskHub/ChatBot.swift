import SwiftUI
import AppKit
import Combine

// MARK: - 챗봇 창 (1.0.0 B3, R6 — 계획 docs/plan-1.0.0-2026-10-23.md §B3, 설계 §5 ③·§6-2)
// 여는 길: NSApp.sendAction(Selector(("openDeskHubChat:")), to: nil, from: nil | 질문 String) — Main 둥근 단추·메뉴 '챗봇 열기'·--key chat[:<질문>].
// 1단계 로컬 즉답(ChatIntent.match): 다음 GRM 발표자 · 장비 예약 방법. 2단계 찾기: NAS 위키 md 조각 + 앱이 읽어 둔 Notion 값 → 낱말 겹침×idf 상위 5.
// 모델: OpenRouter 는 키가 있을 때만 — 키는 요청할 때만 파일에서 읽고 보관·로그·덤프에 쓰지 않는다. 키가 없으면(1.0.1) 이 맥의 Ollama(OpenAI 호환,
// 127.0.0.1:11434, 기본 qwen3:8b)가 떠 있을 때만 로컬로 묻는다 — 밖으로 나가지 않음. 둘 다 없으면 '모델 연결 전' + 찾은 조각 제목.
// 대화는 메모리에만. 시험 길(창이 열려 있을 때만): KeyBus chat-close, 분산 알림 .snapshot → chat.png · .dumptext → chat.txt,
// 훅 DESKHUB_CHAT_DRY=<dir>(보내지 않고 chat-request.json) · DESKHUB_OPENROUTER_ENV · DESKHUB_OPENROUTER_URL · DESKHUB_LOCAL_URL · DESKHUB_WIKI_DIR

extension NSApplication {
    /// sender = nil(창만) 또는 질문 String(열고 바로 묻기). 허브 모델이 없으면 삐
    @objc func openDeskHubChat(_ sender: Any?) {
        guard let model = (NSApp.delegate as? AppDelegate)?.hubs.values.first else { NSSound.beep(); return }
        let q = (sender as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        ChatWindowController.open(model: model, question: (q?.isEmpty ?? true) ? nil : q)
    }
}

// MARK: 의도 (순수)

enum ChatIntent: String {
    case nextGRM, equipment, search

    /// 'GRM·그램·발표' 와 '다음·누구·차례·발표자' → nextGRM, '장비·예약' 과 '방법·어떻게·하는' → equipment, 그 밖 search
    static func match(_ q: String) -> ChatIntent {
        let s = q.lowercased()
        let has: ([String]) -> Bool = { ws in ws.contains { s.contains($0) } }
        if has(["grm", "그램", "발표"]) && has(["다음", "누구", "차례", "발표자"]) { return .nextGRM }
        if has(["장비", "예약"]) && has(["방법", "어떻게", "하는"]) { return .equipment }
        return .search
    }
}

// MARK: 조각·순위 (순수)

struct ChatSnippet: Hashable {
    /// 위키 = '<위키 안 상대 경로>#n', Notion 값 = 'notion:<종류>[#n]'
    let id: String
    let title: String
    let text: String
}

enum ChatSearch {
    static let maxChars = 600
    static let topK = 5

    /// 영문 소문자·숫자 토큰(2자 이상) + 한글 두 글자 조각
    static func tokens(_ s: String) -> [String] {
        var out: [String] = [], latin = "", hangul: [Character] = []
        func flushLatin() { if latin.count >= 2 { out.append(latin) }; latin = "" }
        func flushHangul() {
            if hangul.count >= 2 { for i in 0..<(hangul.count - 1) { out.append(String(hangul[i...i + 1])) } }
            hangul = []
        }
        for ch in s.lowercased() {
            let v = ch.unicodeScalars.count == 1 ? ch.unicodeScalars.first!.value : 0
            if (0x61...0x7A).contains(v) || (0x30...0x39).contains(v) { flushHangul(); latin.append(ch) }
            else if (0xAC00...0xD7A3).contains(v) { flushLatin(); hangul.append(ch) }
            else { flushLatin(); flushHangul() }
        }
        flushLatin(); flushHangul()
        return out
    }

    /// 질문 낱말과 겹침 × idf(제목 겹침은 두 배), 같으면 조각 id 순 → 상위 topK (점수 0 은 뺌)
    static func rank(_ q: String, _ snippets: [ChatSnippet], k: Int = topK) -> [ChatSnippet] {
        let qt = Array(Set(tokens(q)))
        guard !qt.isEmpty, !snippets.isEmpty else { return [] }
        let bodies = snippets.map { Set(tokens($0.title + " " + $0.text)) }
        let titles = snippets.map { Set(tokens($0.title)) }
        let n = Double(snippets.count)
        var idf: [String: Double] = [:]
        for t in qt {
            let df = Double(bodies.filter { $0.contains(t) }.count)
            idf[t] = df == 0 ? 0 : log(1 + n / df)
        }
        var scored: [(Double, ChatSnippet)] = []
        for (i, s) in snippets.enumerated() {
            var sc = 0.0
            for t in qt where bodies[i].contains(t) { sc += (idf[t] ?? 0) * (titles[i].contains(t) ? 2 : 1) }
            if sc > 0 { scored.append((sc, s)) }
        }
        scored.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1.id < $1.1.id }
        return scored.prefix(k).map(\.1)
    }

    /// md 한 파일 → 조각. 제목 = 문서 제목(앞머리 title: 또는 첫 #) › 절 제목, 문단(빈 줄 구분)을 maxChars 이하로 나눔. 주석·앞머리·코드 울타리는 건너뜀
    static func chunks(rel: String, text: String) -> [ChatSnippet] {
        var out: [ChatSnippet] = [], doc = "", heading = "", para: [String] = [], n = 0
        func flush() {
            let body = para.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            para = []
            guard !body.isEmpty else { return }
            let title = [doc, heading].filter { !$0.isEmpty }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: " › ")
            var rest = Substring(body)
            while !rest.isEmpty {
                n += 1
                out.append(ChatSnippet(id: "\(rel)#\(n)", title: title.isEmpty ? rel : title, text: String(rest.prefix(maxChars))))
                rest = rest.dropFirst(maxChars)
            }
        }
        var lines = text.components(separatedBy: .newlines)
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---", let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for l in lines[1..<end] where l.hasPrefix("title:") { doc = l.dropFirst(6).trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
            lines = Array(lines[(end + 1)...])
        }
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("<!--") || t.hasPrefix("```") || t == "---" { continue }
            if t.hasPrefix("#") {
                flush()
                let h = String(t.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                if doc.isEmpty { doc = h } else { heading = h }
                continue
            }
            if t.isEmpty { flush(); continue }
            para.append(t)
        }
        flush()
        return out
    }

    /// 위키 폴더의 *.md 전부 (상대 경로 순). 폴더가 없으면 빈 목록 — NAS 가 없을 때 '위키 조각 0'
    static func loadWiki(dir: String) -> [ChatSnippet] {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: dir) else { return [] }
        var rels: [String] = []
        while let r = en.nextObject() as? String { if r.hasSuffix(".md") { rels.append(r) } }
        var out: [ChatSnippet] = []
        for rel in rels.sorted() {
            let p = (dir as NSString).appendingPathComponent(rel)
            if let sz = (try? fm.attributesOfItem(atPath: p))?[.size] as? Int, sz > 1_000_000 { continue }
            guard let s = try? String(contentsOfFile: p, encoding: .utf8) else { continue }
            out += chunks(rel: rel, text: s)
            if out.count > 4000 { break }
        }
        return out
    }
}

// MARK: 모델 연결 (키는 값 보관 없이)

enum ChatModelLink {
    static let defaultModel = "deepseek/deepseek-v4.1-flash"
    static let keyName = "OPENROUTER_API_KEY"
    static var modelID: String {
        let v = (UserDefaults.standard.string(forKey: "DeskHub.chatModel") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? defaultModel : v
    }
    static var endpoint: URL {
        if let v = ProcessInfo.processInfo.environment["DESKHUB_OPENROUTER_URL"], !v.isEmpty, let u = URL(string: v) { return u }
        return URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    }
    static var dryDir: String? {
        guard let v = ProcessInfo.processInfo.environment["DESKHUB_CHAT_DRY"], !v.isEmpty else { return nil }
        return (v as NSString).expandingTildeInPath
    }

    // MARK: 로컬 모델 (1.0.1) — 키가 없을 때의 두 번째 길. Ollama 의 OpenAI 호환 주소, 키 없음, 이 맥 밖으로 나가지 않는다
    static let localDefaultModel = "qwen3:8b"
    static var localModelID: String {
        let v = (UserDefaults.standard.string(forKey: "DeskHub.chatLocalModel") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? localDefaultModel : v
    }
    /// 로컬 chat/completions 주소 — 훅 DESKHUB_LOCAL_URL → UserDefaults DeskHub.chatLocalURL → 기본 127.0.0.1:11434
    static var localEndpoint: URL {
        for raw in [ProcessInfo.processInfo.environment["DESKHUB_LOCAL_URL"], UserDefaults.standard.string(forKey: "DeskHub.chatLocalURL")] {
            let v = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty, let u = URL(string: v) { return u }
        }
        return URL(string: "http://127.0.0.1:11434/v1/chat/completions")!
    }
    /// 로컬 서버가 떠 있는지 — '…/chat/completions' 와 같은 자리의 '…/models' 를 2초 안에 GET(그 꼴이 아니면 주소 그대로). 5xx·연결 실패만 죽은 것으로
    static func localAlive(url: URL) async -> Bool {
        let s = url.absoluteString, tail = "/chat/completions"
        let probe = s.hasSuffix(tail) ? (URL(string: String(s.dropLast(tail.count)) + "/models") ?? url) : url
        var req = URLRequest(url: probe)
        req.timeoutInterval = 2
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 500) < 500
    }
    /// 생각 블록(<think>…</think>) 제거 — 로컬 Qwen3 류가 답 앞에 끼워 넣는 것
    static func stripThink(_ s: String) -> String {
        var out = s
        while let a = out.range(of: "<think>"), let b = out.range(of: "</think>", range: a.upperBound..<out.endIndex) {
            out.removeSubrange(a.lowerBound..<b.upperBound)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// 키를 찾을 파일 순서 — 시험 훅이 있으면 그것만(다른 파일로 넘어가지 않음), 아니면 NAS tokens.env → 이 맥 .env
    @MainActor static func keyFiles(model: NotionHubModel) -> [String] {
        if let v = ProcessInfo.processInfo.environment["DESKHUB_OPENROUTER_ENV"], !v.isEmpty { return [(v as NSString).expandingTildeInPath] }
        var out: [String] = []
        if let ics = (NSApp.delegate as? AppDelegate)?.config.calendar.icsSSOTFile, !ics.isEmpty { out.append((ics as NSString).expandingTildeInPath) }
        out.append((model.cfg.tokenEnvFile as NSString).expandingTildeInPath)
        return out
    }
    /// 'OPENROUTER_API_KEY=' 한 줄(따옴표 제거, NotionAPI.init 과 같은 파싱). 부르는 쪽은 값을 쓰고 바로 버린다
    static func readKey(files: [String]) -> String? {
        for f in files {
            guard let text = try? String(contentsOfFile: f, encoding: .utf8) else { continue }
            var found: String?
            for line in text.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix(keyName + "=") else { continue }
                var v = String(t.dropFirst(keyName.count + 1)).trimmingCharacters(in: .whitespaces)
                if v.hasPrefix("\"") && v.hasSuffix("\"") || v.hasPrefix("'") && v.hasSuffix("'") { v = String(v.dropFirst().dropLast()) }
                found = v
            }
            if let f = found, !f.isEmpty { return f }
        }
        return nil
    }

    static let system = "너는 연구실 대시보드의 도우미다. 아래 연구실 자료 조각만 근거로 한국어 3문장 이내로 답하고, 근거로 쓴 조각 번호를 [n] 으로 붙여라. 자료에 답이 없으면 '자료에 없음' 이라고만 답하라."

    /// local = 로컬 모델용 — 시스템 문장 끝에 ' /no_think'(Qwen3 생각 끄기 표시, 다른 모델은 무시)
    static func messages(question: String, snippets: [ChatSnippet], local: Bool = false) -> [[String: String]] {
        let ctx = snippets.enumerated().map { i, s in "[\(i + 1)] \(s.title)\n\(s.text)" }.joined(separator: "\n\n")
        let user = "질문: \(question)\n\n연구실 자료 조각:\n" + (ctx.isEmpty ? "(없음)" : ctx)
        return [["role": "system", "content": local ? system + " /no_think" : system], ["role": "user", "content": user]]
    }

    /// 드라이런 파일 — model · snippet_ids · messages 만(Authorization·키 없음). '"model": "<id>"' 꼴로 쓴다
    static func dryJSON(model: String, messages: [[String: String]], ids: [String]) -> String {
        func enc(_ v: Any) -> String {
            (try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .withoutEscapingSlashes, .sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        }
        return "{\n  \"model\": \(enc(model)),\n  \"snippet_ids\": \(enc(ids)),\n  \"messages\": [\n"
            + messages.map { "    " + enc($0) }.joined(separator: ",\n") + "\n  ]\n}\n"
    }

    /// chat/completions — OpenRouter(key 있음, 20초) 또는 로컬(key nil, 60초 — 첫 답은 모델을 메모리에 올리느라 느리다). 성공이면 답 글, 실패면 nil
    static func complete(key: String?, model: String, messages: [[String: String]], url: URL) async -> String? {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = key == nil ? 60 : 20
        if let key { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("DeskHub", forHTTPHeaderField: "X-Title")
        var body: [String: Any] = ["model": model, "messages": messages, "max_tokens": 400, "temperature": 0.2]
        if key == nil { body["think"] = false }   // Ollama 생각 끄기(모르는 서버는 무시)
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = data
        guard let (d, resp) = try? await URLSession.shared.data(for: req),
              ((resp as? HTTPURLResponse)?.statusCode ?? 500) < 300,
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let choice = (o["choices"] as? [[String: Any]])?.first,
              let text = (choice["message"] as? [String: Any])?["content"] as? String else { return nil }
        let t = stripThink(text)
        return t.isEmpty ? nil : t
    }
}

// MARK: 대화 상태

struct ChatTurn: Identifiable {
    enum Kind: String { case direct = "바로", model = "모델", dry = "드라이런", offline = "연결 전", failed = "실패", waiting = "대기" }
    let id: Int
    let question: String
    let intent: ChatIntent
    var kind: Kind
    var answer: String
    var evidence: [ChatSnippet]
}

@MainActor
final class ChatSession: ObservableObject {
    let model: NotionHubModel
    @Published var turns: [ChatTurn] = []
    @Published var linked = false        // 모델에 물을 수 있는 상태(키 또는 로컬 서버)
    @Published var linkName = ""         // 'OpenRouter <id>' 또는 '로컬 <id>'
    @Published var wikiCount = 0
    @Published var draft = ""
    var minButton: CGFloat = .infinity
    private var wikiTask: Task<[ChatSnippet], Never>?
    private var seq = 0

    init(model: NotionHubModel) { self.model = model }

    var wikiDir: String {
        if let v = ProcessInfo.processInfo.environment["DESKHUB_WIKI_DIR"], !v.isEmpty { return (v as NSString).expandingTildeInPath }
        return (model.nasRoot as NSString).appendingPathComponent("AI_Meeting/llm_wiki_practice/wiki")
    }

    /// 창을 열 때 — 위키 읽기(백그라운드, NAS 가 느려도 화면이 멈추지 않게) · 연결 확인(키 있음(값은 버림) → 없으면 로컬 서버)
    func start() {
        let dir = wikiDir
        let t = Task.detached(priority: .utility) { ChatSearch.loadWiki(dir: dir) }
        wikiTask = t
        Task { [weak self] in
            let w = await t.value
            self?.wikiCount = w.count
        }
        checkLink()
    }

    /// 키가 있으면 OpenRouter, 없고 로컬 서버가 살아 있으면 로컬, 둘 다 아니면 연결 전
    func checkLink() {
        let files = ChatModelLink.keyFiles(model: model)
        let cloud = ChatModelLink.modelID, localID = ChatModelLink.localModelID, localURL = ChatModelLink.localEndpoint
        Task { [weak self] in
            let r: (Bool, String) = await Task.detached {
                if ChatModelLink.readKey(files: files) != nil { return (true, "OpenRouter \(cloud)") }
                if await ChatModelLink.localAlive(url: localURL) { return (true, "로컬 \(localID)") }
                return (false, "")
            }.value
            self?.linked = r.0; self?.linkName = r.1
        }
    }

    // MARK: Notion 값 조각 (D-10 — 사람은 이니셜, 이메일·토큰·실험 참여자 없음, 파일로 저장 안 함)
    private func anonymize(_ s: String) -> String {
        var out = s
        for m in model.members where !m.name.isEmpty && !m.initials.isEmpty { out = out.replacingOccurrences(of: m.name, with: m.initials) }
        return out.replacingOccurrences(of: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", with: "(메일)", options: .regularExpression)
    }

    func notionSnippets() -> [ChatSnippet] {
        let md = DateFormatter(); md.dateFormat = "M.d"
        let mdw = DateFormatter(); mdw.locale = Locale(identifier: "ko_KR"); mdw.dateFormat = "M.d(E)"
        let today = model.today, cal = Calendar.current
        var out: [ChatSnippet] = []
        let grm = upcomingGRM(6)
        if !grm.isEmpty {
            out.append(ChatSnippet(id: "notion:grm", title: "GRM 발표 일정 다음 \(grm.count)회",
                                   text: grm.map { "\(mdw.string(from: $0.date)) 발표 \(model.initialsList($0.presenters)) \($0.type)" }.joined(separator: " / ")))
        }
        let end = cal.date(byAdding: .day, value: 14, to: today) ?? today
        let ev = model.events.filter { $0.date >= today && $0.date < end }.sorted { $0.date < $1.date }
        if !ev.isEmpty {
            out.append(ChatSnippet(id: "notion:events", title: "14일 일정",
                                   text: anonymize(ev.prefix(30).map { "\(md.string(from: $0.date)) \($0.title)" + ($0.type.isEmpty ? "" : " (\($0.type))") }.joined(separator: " / "))))
        }
        for (i, c) in model.conferences.enumerated() {
            let name = c.conference.isEmpty ? c.title : c.conference
            var parts = ["개최 \(md.string(from: c.start))" + (c.location.isEmpty ? "" : " · \(c.location)")]
            if let d = c.deadline { parts.append("초록 마감 \(md.string(from: d))") }
            out.append(ChatSnippet(id: "notion:conf#\(i + 1)", title: "학회 \(anonymize(name))", text: parts.joined(separator: " · ")))
        }
        let eq = equipmentLines()
        if !eq.isEmpty { out.append(ChatSnippet(id: "notion:equip", title: "장비 예약 현황", text: eq.joined(separator: " / "))) }
        for (i, g) in model.grants.enumerated() {
            let due = g.due.map { "마감 \(md.string(from: $0))" } ?? "마감 미정"
            out.append(ChatSnippet(id: "notion:grant#\(i + 1)", title: "그랜트 \(g.title)",
                                   text: anonymize([g.kind, g.agency, due, g.dueNote].filter { !$0.isEmpty }.joined(separator: " · "))))
        }
        for (i, p) in model.papers.enumerated() {
            out.append(ChatSnippet(id: "notion:paper#\(i + 1)", title: "추천 논문 \(p.title)",
                                   text: "추천 대상 " + (p.researcher.isEmpty ? "—" : p.researcher) + (p.tier.isEmpty ? "" : " · 티어 \(p.tier)")))
        }
        return out
    }

    /// GRMSchedule.rows 의 지난 회차를 뺀 앞 n 행 (같은 회차 합침 그대로)
    func upcomingGRM(_ n: Int) -> [GRMSlot] {
        let today = model.today, now = model.now
        let past = GRMSchedule.last(model.grm, today: today, now: now)
        return Array(GRMSchedule.rows(model.grm, today: today, now: now).rows.filter { $0.date >= today && $0.id != past?.id }.prefix(n))
    }

    /// equipmentDumpLines 의 장비 줄만 (머리·요약·닫기 누락 줄 뺌)
    func equipmentLines() -> [String] {
        model.equipmentDumpLines().filter { !$0.hasPrefix("장비 ") && !$0.hasPrefix("요약 · ") && !$0.hasPrefix("닫기 누락") }
    }

    // MARK: 묻기
    func ask(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        seq += 1
        let id = seq
        let intent = ChatIntent.match(q)
        switch intent {
        case .nextGRM:
            turns.append(ChatTurn(id: id, question: q, intent: intent, kind: .direct, answer: grmAnswer(), evidence: notionSnippets().filter { $0.id == "notion:grm" }))
        case .equipment:
            turns.append(ChatTurn(id: id, question: q, intent: intent, kind: .direct, answer: equipmentAnswer(), evidence: notionSnippets().filter { $0.id == "notion:equip" }))
        case .search:
            turns.append(ChatTurn(id: id, question: q, intent: intent, kind: .waiting, answer: "자료를 찾는 중…", evidence: []))
            let notion = notionSnippets(), files = ChatModelLink.keyFiles(model: model)
            let modelID = ChatModelLink.modelID, url = ChatModelLink.endpoint, dry = ChatModelLink.dryDir
            let localID = ChatModelLink.localModelID, localURL = ChatModelLink.localEndpoint
            let wiki = wikiTask
            Task { [weak self] in
                let w = await wiki?.value ?? []
                let top = ChatSearch.rank(q, w + notion)
                // 키는 이 안에서만 — 꺼내 쓰고 버린다(상태·로그·덤프에 남지 않음). 길: 키 → OpenRouter, 없으면 로컬 서버가 살아 있을 때만 로컬
                let outcome: (ChatTurn.Kind, String, String) = await Task.detached {
                    let key = ChatModelLink.readKey(files: files)
                    let local = key == nil
                    if local, !(await ChatModelLink.localAlive(url: localURL)) { return (.offline, "", "") }
                    let id = local ? localID : modelID
                    let link = local ? "로컬 \(id)" : "OpenRouter \(id)"
                    let msgs = ChatModelLink.messages(question: q, snippets: top, local: local)
                    if let dry {
                        let json = ChatModelLink.dryJSON(model: id, messages: msgs, ids: top.map(\.id))
                        try? FileManager.default.createDirectory(atPath: dry, withIntermediateDirectories: true)
                        try? json.write(toFile: (dry as NSString).appendingPathComponent("chat-request.json"), atomically: true, encoding: .utf8)
                        return (.dry, "", link)
                    }
                    if let a = await ChatModelLink.complete(key: key, model: id, messages: msgs, url: local ? localURL : url) { return (.model, a, link) }
                    return (.failed, "", link)
                }.value
                self?.finish(id: id, kind: outcome.0, modelAnswer: outcome.1, link: outcome.2, top: top)
            }
        }
    }

    private func finish(id: Int, kind: ChatTurn.Kind, modelAnswer: String, link: String, top: [ChatSnippet]) {
        guard let i = turns.firstIndex(where: { $0.id == id }) else { return }
        let titles = top.isEmpty ? "찾은 자료 없음" : top.enumerated().map { "[\($0.offset + 1)] \($0.element.title)" }.joined(separator: "\n")
        switch kind {
        case .model: turns[i].answer = modelAnswer; linked = true; linkName = link
        case .dry: turns[i].answer = "(드라이런) 요청을 남김 — 자료 \(top.count)개 · \(link)"; linked = true; linkName = link
        case .offline: turns[i].answer = "모델 연결 전 — 연구실 자료에서 찾은 것:\n" + titles; linked = false; linkName = ""
        case .failed: turns[i].answer = "모델 응답 실패(\(link)) — 찾은 자료:\n" + titles; linked = true; linkName = link
        default: break
        }
        turns[i].kind = kind
        turns[i].evidence = top
    }

    func grmAnswer() -> String {
        guard !model.grm.isEmpty else { return "GRM 일정을 아직 읽지 못했습니다 — 잠시 뒤 다시 물어 주세요" }
        guard let g = upcomingGRM(1).first else { return "다음 GRM 일정이 아직 없습니다" }
        let mdw = DateFormatter(); mdw.locale = Locale(identifier: "ko_KR"); mdw.dateFormat = "M.d(E)"
        let cal = Calendar.current
        let n = cal.dateComponents([.day], from: cal.startOfDay(for: model.today), to: cal.startOfDay(for: g.date)).day ?? 0
        let who = model.initialsList(g.presenters)
        return "\(mdw.string(from: g.date)) D-\(max(n, 0)) · 발표 \(who.isEmpty ? "미정" : who)" + (g.type.isEmpty ? "" : " · \(g.type)")
    }

    func equipmentAnswer() -> String {
        let db = model.cfg.resourceDB.replacingOccurrences(of: "-", with: "")
        let lines = equipmentLines()
        return "Notion Resource Management 에서 예약합니다 — https://www.notion.so/\(db)"
            + (lines.isEmpty ? "" : "\n" + lines.map { "· " + $0 }.joined(separator: "\n"))
    }
}

// MARK: 창

@MainActor
final class ChatWindowController: NSObject, NSWindowDelegate {
    private static var shared: ChatWindowController?

    let session: ChatSession
    let window: NSWindow
    private var keySub: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var closing = false

    static func open(model: NotionHubModel, question: String?) {
        let byClick = NSApp.currentEvent.map { [.leftMouseUp, .leftMouseDown].contains($0.type) } ?? false
        let c: ChatWindowController
        if let s = shared, !s.closing { c = s } else {
            c = ChatWindowController(model: model)
            shared = c
            c.start()
        }
        if c.window.isMiniaturized { c.window.deminiaturize(nil) }
        if byClick { NSApp.activate(ignoringOtherApps: true); c.window.makeKeyAndOrderFront(nil) } else { c.window.orderFrontRegardless() }
        if let q = question { c.session.ask(q) }
    }

    private init(model: NotionHubModel) {
        session = ChatSession(model: model)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Hub.s(520), height: Hub.s(640)),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "챗봇"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 360, height: 420)
        window.contentView = NSHostingView(rootView: DisplayRefresh(ChatWindowView(session: session, close: { [weak self] in self?.window.performClose(nil) })))
        window.setContentSize(NSSize(width: Hub.s(520), height: Hub.s(640)))
        window.center()
    }

    private func start() {
        session.start()
        keySub = KeyBus.shared.$event.dropFirst().compactMap { $0 }.sink { [weak self] e in
            MainActor.assumeIsolated { if e.key == "chat-close" { self?.window.performClose(nil) } }
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
    }

    private func snapshot(dir: String?) {
        guard window.isVisible else { return }
        let d = URL(fileURLWithPath: dir ?? NSTemporaryDirectory(), isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let url = d.appendingPathComponent("chat.png")
        if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
           let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
            try? png.write(to: url); return
        }
        if let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    private func dump(dir: String?) {
        let d = URL(fileURLWithPath: dir ?? NSTemporaryDirectory(), isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let s = session
        let btn = s.minButton.isFinite ? "\(Int(s.minButton.rounded(.down)))" : "—"
        var lines = ["[챗봇] 모델 \(ChatModelLink.modelID) · 로컬 \(ChatModelLink.localModelID) · 연결 \(s.linked ? s.linkName : "없음") · 위키 조각 \(s.wikiCount) · Notion 조각 \(s.notionSnippets().count) · 단추 최소 높이 \(btn)"]
        for t in s.turns {
            let ev = t.evidence.isEmpty ? "—" : t.evidence.map(\.id).joined(separator: ",")
            let head = String(t.answer.replacingOccurrences(of: "\n", with: " ").prefix(80))
            lines.append("Q \(t.question) · 의도 \(t.intent.rawValue) · 답 \(t.kind.rawValue) · 근거 \(ev) · \(head)")
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: d.appendingPathComponent("chat.txt"), atomically: true, encoding: .utf8)
    }

    func windowWillClose(_ notification: Notification) {
        closing = true
        keySub?.cancel(); keySub = nil
        let dc = DistributedNotificationCenter.default()
        for o in observers { dc.removeObserver(o) }
        observers = []
        DispatchQueue.main.async { [self] in
            window.delegate = nil
            if Self.shared === self { Self.shared = nil }
        }
    }
}

// MARK: 창 내용

struct ChatWindowView: View {
    @ObservedObject var session: ChatSession
    let close: () -> Void
    @ObservedObject private var display = HubDisplay.shared
    @State private var settingsOpen = false
    @State private var modelDraft = UserDefaults.standard.string(forKey: "DeskHub.chatModel") ?? ""
    @State private var localDraft = UserDefaults.standard.string(forKey: "DeskHub.chatLocalModel") ?? ""
    @State private var openEvidence: Set<Int> = []
    private let cs = CardStyle.large
    static let examples = ["다음 GRM 발표자", "장비 예약 방법"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if session.turns.isEmpty {
                            Text("연구실 일정·자료에 대해 한 줄로 물어보세요. 아래 예시 두 개는 바로 답합니다.")
                                .font(.hub(cs.body)).foregroundStyle(Hub.text2).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(session.turns) { t in turnView(t).id(t.id) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 6)
                }
                .onChange(of: session.turns.count) { _, _ in
                    if let last = session.turns.last { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            HStack(spacing: 8) {
                ForEach(Self.examples, id: \.self) { e in
                    Button { session.ask(e) } label: {
                        Text(e).font(.hub(cs.aux, weight: .semibold)).lineLimit(1).padding(.horizontal, 12)
                            .frame(minHeight: TapTarget.min)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.fillNeutral))
                    }
                    .buttonStyle(PressFillStyle(cornerRadius: 10)).tapProbe()
                }
                Spacer(minLength: 0)
            }
            inputRow
            settings
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Hub.card)
        .foregroundStyle(Hub.text)
        .environment(\.cardStyle, cs)
        .onPreferenceChange(TapHeightKey.self) { h in MainActor.assumeIsolated { session.minButton = h } }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle().fill(session.linked ? Hub.ink : Hub.text3).frame(width: 9, height: 9)
            Text(session.linked ? "모델 연결됨 · \(session.linkName)" : "모델 연결 전 — 연구실 자료에서 찾은 것만")
                .font(.hub(cs.aux, weight: .semibold)).foregroundStyle(session.linked ? Hub.text : Hub.text2).lineLimit(2)
            Spacer(minLength: 8)
            Button(action: close) {
                HStack(spacing: 4) { Text("닫기"); Image(systemName: "xmark") }
                    .font(.hub(cs.aux, weight: .semibold)).padding(.horizontal, 12)
                    .frame(minWidth: TapTarget.min, minHeight: TapTarget.min)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Hub.fillNeutral))
            }
            .buttonStyle(PressFillStyle()).keyboardShortcut(.cancelAction).help("창 닫기 (Esc) — 대화는 저장하지 않습니다").tapProbe()
        }
    }

    private func tag(_ t: ChatTurn) -> String {
        switch t.kind {
        case .direct: return "바로 답"
        case .model: return "모델 · 자료 \(t.evidence.count)개"
        case .dry: return "드라이런 · 자료 \(t.evidence.count)개"
        case .offline, .failed: return "자료 \(t.evidence.count)개"
        case .waiting: return "찾는 중"
        }
    }

    private func turnView(_ t: ChatTurn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t.question).font(.hub(cs.body, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.ink.opacity(0.10)))
            Text(t.answer).font(.hub(cs.body)).lineSpacing(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .foregroundStyle(t.kind == .waiting ? Hub.text3 : Hub.text)
            HStack(spacing: 8) {
                Text(tag(t)).font(.hub(cs.tag, weight: .medium)).foregroundStyle(Hub.text2)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Hub.fillNeutral))
                if !t.evidence.isEmpty {
                    Button { if openEvidence.contains(t.id) { openEvidence.remove(t.id) } else { openEvidence.insert(t.id) } } label: {
                        Text(openEvidence.contains(t.id) ? "▾ 근거 접기" : "▸ 근거 \(t.evidence.count)개 보기")
                            .font(.hub(cs.tag, weight: .medium)).foregroundStyle(Hub.text2).padding(.horizontal, 6)
                            .frame(minHeight: TapTarget.min)
                    }
                    .buttonStyle(PressFillStyle(cornerRadius: 6))
                }
                Spacer(minLength: 0)
            }
            if openEvidence.contains(t.id) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(t.evidence.enumerated()), id: \.offset) { i, s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("[\(i + 1)] \(s.title)").font(.hub(cs.tag, weight: .semibold))
                            Text(s.id).font(.hub(cs.tag - 1, design: .monospaced)).foregroundStyle(Hub.text3)
                            Text(String(s.text.prefix(200))).font(.hub(cs.tag)).foregroundStyle(Hub.text2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Hub.divider))
            }
        }
    }

    private var inputRow: some View {
        let empty = session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 8) {
            TextField("질문 한 줄 (Enter)", text: $session.draft)
                .textFieldStyle(.roundedBorder).font(.hub(cs.aux))
                .onSubmit { submit() }
            Button { submit() } label: {
                Text("보내기").font(.hub(cs.aux, weight: .semibold)).padding(.horizontal, 14)
                    .frame(minWidth: TapTarget.min, minHeight: TapTarget.min)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(empty ? Hub.fillNeutral : Hub.ink))
                    .foregroundStyle(empty ? Hub.text3 : Hub.onAccent)
            }
            .buttonStyle(PressFillStyle()).disabled(empty).tapProbe()
        }
    }

    private func submit() {
        let q = session.draft
        guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.draft = ""
        session.ask(q)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { settingsOpen.toggle() } label: {
                Text(settingsOpen ? "▾ 설정" : "▸ 설정").font(.hub(cs.tag, weight: .medium)).foregroundStyle(Hub.text2)
                    .padding(.horizontal, 6).frame(minHeight: TapTarget.min)
            }
            .buttonStyle(PressFillStyle(cornerRadius: 6))
            if settingsOpen {
                settingRow("OpenRouter 모델", placeholder: ChatModelLink.defaultModel, text: $modelDraft)
                settingRow("로컬 모델", placeholder: ChatModelLink.localDefaultModel, text: $localDraft)
                Text("OpenRouter 키가 없으면 이 맥의 Ollama(127.0.0.1:11434)에 묻습니다 · 비우면 기본값 · 이 맥에만 저장 · 대화는 저장하지 않습니다")
                    .font(.hub(cs.tag - 1)).foregroundStyle(Hub.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func settingRow(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.hub(cs.tag, weight: .semibold)).foregroundStyle(Hub.text2)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder).font(.hub(cs.tag, design: .monospaced))
                .onSubmit { saveModel() }
            Button { saveModel() } label: {
                Text("저장").font(.hub(cs.tag, weight: .semibold)).padding(.horizontal, 10)
                    .frame(minHeight: TapTarget.min)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Hub.fillNeutral))
            }
            .buttonStyle(PressFillStyle())
        }
    }

    /// 두 칸 다 저장(빈 칸 = 기본값) 뒤 연결 상태를 다시 본다
    private func saveModel() {
        for (draft, key) in [(modelDraft, "DeskHub.chatModel"), (localDraft, "DeskHub.chatLocalModel")] {
            let v = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty { UserDefaults.standard.removeObject(forKey: key) } else { UserDefaults.standard.set(v, forKey: key) }
        }
        session.checkLink()
    }
}
