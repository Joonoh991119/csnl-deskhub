import Foundation

// MARK: - 분야 최근 이슈 = bioRxiv neuroscience (0.39.0 C2, FEED — 실제 자료)
// api.biorxiv.org(인증 없음)를 하루 단위·최신 날부터 받는다. 구간은 HubClock.today 부터 7일, 한 번에 ≤10호출·호출 사이 1초, v1 만, DOI 병합.
// 캐시는 이 맥에만(Config.directory/feed-biorxiv.json, NAS 아님). 받기 실패면 캐시를 그대로 보이고 '마지막 갱신' 을 알린다(적색 없음).
// 훅: DESKHUB_FEED_FIXTURE=<json>(API 쪽 객체 하나 또는 배열 — 호출 0) · DESKHUB_FEED_SIM=offline · DESKHUB_FEED_CACHE=<경로>

/// bioRxiv 프리프린트 하나 — 앱이 읽는 필드만. id = doi
struct FeedItem: Codable, Identifiable, Hashable {
    let doi: String
    let title: String
    let authors: String
    /// yyyy-MM-dd (bioRxiv 게시일)
    let date: String
    let version: String
    let category: String
    /// 앞 2000자 — 600자면 주제 일치 근거가 잘린다(planner 시험)
    let abstract: String
    var id: String { doi }

    static let abstractLimit = 2000

    /// 첫 저자 성 + 2명 이상이면 ' et al.' — 'Wadsworth, W. G.' → 'Wadsworth'. 끝에 '; ' 가 남는 행도 있다
    var firstAuthor: String {
        let names = authors.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let first = names.first else { return "" }
        let surname = first.split(separator: ",", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? first
        return names.count >= 2 ? surname + " et al." : surname
    }
    var day: Date? { FeedItem.dayFormatter.date(from: date) }
    /// 'M.d'
    var shortDay: String { day.map(Hub.shortDay) ?? date }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "yyyy-MM-dd"; return f
    }()

    /// API collection 의 한 항목 → FeedItem. 제목은 공백만 합치고, 초록은 2000자까지
    static func from(_ d: [String: Any]) -> FeedItem? {
        func s(_ k: String) -> String {
            if let v = d[k] as? String { return v }
            if let v = d[k] as? NSNumber { return v.stringValue }
            return ""
        }
        let doi = s("doi").trimmingCharacters(in: .whitespaces)
        let title = s("title").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !doi.isEmpty, !title.isEmpty else { return nil }
        let abs = s("abstract").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return FeedItem(doi: doi, title: title, authors: s("authors"), date: s("date"), version: s("version"), category: s("category"),
                        abstract: String(abs.prefix(abstractLimit)))
    }
}

enum BioRxivFeed {
    static let category = "neuroscience"
    static let windowDays = 7
    static let pageSize = 30
    static let maxCalls = 10
    static let collectionURL = URL(string: "https://www.biorxiv.org/collection/neuroscience")!

    /// 한 쪽 — 그 날(interval 'a:a'), cursor, 그 쪽 항목 수, 그 날 전체 수, 항목(모든 판 — v1 거름은 merge 에서)
    struct Page { let day: String?; let cursor: Int; let count: Int; let total: Int; let items: [FeedItem] }

    static func url(day: String, cursor: Int) -> URL {
        URL(string: "https://api.biorxiv.org/details/biorxiv/\(day)/\(day)/\(cursor)?category=\(category)")!
    }

    private static func int(_ v: Any?) -> Int? {
        if let n = v as? Int { return n }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// 네트워크·픽스처가 함께 쓰는 파싱. messages[0] 의 total·count·cursor 는 숫자 또는 문자열('55'). 'no posts found' 는 total 0
    static func parse(page obj: [String: Any]) -> Page? {
        let coll: [[String: Any]]
        if let c = obj["collection"] as? [[String: Any]] { coll = c } else if obj["messages"] != nil { coll = [] } else { return nil }
        let msg = (obj["messages"] as? [[String: Any]])?.first ?? [:]
        let items = coll.compactMap(FeedItem.from)
        let interval = (msg["interval"] as? String) ?? ""
        let parts = interval.split(separator: ":").map(String.init)
        let day = parts.count == 2 && parts[0] == parts[1] ? parts[0] : nil
        let cursor = int(msg["cursor"]) ?? 0
        let count = int(msg["count"]) ?? items.count
        let total = int(msg["total"]) ?? (cursor + count)
        return Page(day: day, cursor: cursor, count: count, total: total, items: items)
    }

    /// 구간의 날들 — 최신 날부터 7일 ('yyyy-MM-dd')
    static func window(today: Date) -> [String] {
        (0..<windowDays).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: today) }.map { FeedItem.dayFormatter.string(from: $0) }
    }
    /// 늘 다시 받는 최근 날 수 — 오늘·어제(이 맥 달력 = 한국시간 날짜 경계). bioRxiv 게시가 늦게 붙어 아직 늘어나는 날이라
    /// 끝까지 받아도 '다 받은 날'로 확정하지 않는다 (0.39.0 리뷰 2)
    static let openDays = 2
    /// 날 하나가 확정(다 받은 날로 저장)될 수 있나 — 어제(today − 1) 보다 앞선 날만. 'yyyy-MM-dd' 문자열 비교
    static func isSettled(_ day: String, today: Date) -> Bool {
        let y = Calendar.current.date(byAdding: .day, value: -(openDays - 1), to: today) ?? today
        return day < FeedItem.dayFormatter.string(from: y)
    }
    /// 다 받은 날 중 확정된 것만 — 저장(applyFeed·캐시)과 '받은 날 m/7' 이 같은 함수. 예전 캐시에 남은 오늘·어제도 여기서 빠진다
    static func settled(_ days: [String], today: Date) -> [String] {
        days.filter { isSettled($0, today: today) }
    }
    /// 받을 날 — 확정되지 않은 날 전부(오늘·어제는 늘 + 다 받은 적 없는 날). 최신 날부터
    static func daysToFetch(today: Date, fetched: Set<String>) -> [String] {
        window(today: today).filter { !isSettled($0, today: today) || !fetched.contains($0) }
    }

    struct Result { var items: [FeedItem] = []; var completedDays: [String] = []; var calls = 0; var error: String? }

    /// 날마다 cursor 를 30씩 total 까지. 호출 사이 1초, 합계 ≤maxCalls. 그 날의 모든 쪽을 읽었을 때만 completedDays.
    /// 실패(네트워크·HTTP 2xx 아님·JSON 아님)면 거기서 멈추고 그때까지 받은 것과 error 를 돌려준다
    static func fetch(days: [String], maxCalls: Int = maxCalls) async -> Result {
        var r = Result()
        let ver = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
        outer: for day in days {
            var cursor = 0
            while true {
                guard r.calls < maxCalls else { break outer }
                if r.calls > 0 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
                var req = URLRequest(url: url(day: day, cursor: cursor), timeoutInterval: 20)
                req.setValue("DeskHub/\(ver) (csnl@snu.ac.kr)", forHTTPHeaderField: "User-Agent")
                r.calls += 1
                do {
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    if let code = (resp as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) { r.error = "HTTP \(code)"; break outer }
                    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let p = parse(page: obj) else { r.error = "JSON 아님"; break outer }
                    r.items += p.items
                    cursor += pageSize
                    if p.items.isEmpty || cursor >= p.total { r.completedDays.append(day); break }
                } catch {
                    r.error = error.localizedDescription; break outer
                }
            }
        }
        return r
    }

    /// 픽스처 — API 쪽 객체 하나 또는 그 배열. 그 날의 쪽들이 0…total 을 덮으면 그 날을 다 받은 날로
    static func fixture(path: String) -> Result? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)),
              let obj = try? JSONSerialization.jsonObject(with: d) else { return nil }
        let raw: [[String: Any]] = (obj as? [[String: Any]]) ?? ((obj as? [String: Any]).map { [$0] } ?? [])
        let pages = raw.compactMap(parse(page:))
        var r = Result()
        var covered: [String: (end: Int, total: Int)] = [:]
        for p in pages {
            r.items += p.items
            if let day = p.day {
                let c = covered[day] ?? (0, p.total)
                covered[day] = (max(c.end, p.cursor + max(p.count, p.items.count)), p.total)
            }
        }
        r.completedDays = covered.filter { $0.value.end >= $0.value.total }.keys.sorted(by: >)
        return r
    }

    /// v1 만, DOI 로 병합(새 것이 이김)
    static func merge(_ old: [FeedItem], _ new: [FeedItem]) -> [FeedItem] {
        var byDOI: [String: FeedItem] = [:]
        for x in old where x.version == "1" { byDOI[x.doi] = x }
        for x in new where x.version == "1" { byDOI[x.doi] = x }
        return sorted(Array(byDOI.values))
    }
    /// 날짜 내림차순 → 같은 날은 DOI 내림차순(새 번호 먼저)
    static func sorted(_ xs: [FeedItem]) -> [FeedItem] {
        xs.sorted { a, b in a.date != b.date ? a.date > b.date : a.doi > b.doi }
    }
    /// 구간(7일) 안 항목
    static func inWindow(_ xs: [FeedItem], today: Date) -> [FeedItem] {
        let w = Set(window(today: today))
        return xs.filter { w.contains($0.date) }
    }
}

/// 이 맥의 피드 캐시 — {schema:1, source:"biorxiv", ok_at, tried_at, fetched_days, items}. atomic, 14일 지난 항목은 지운다.
/// 깨진 파일은 없는 것으로 보고 다음 성공 때 덮어쓴다
struct FeedCacheFile: Codable {
    var schema = 1
    var source = "biorxiv"
    var okAt: Date?
    var triedAt: Date?
    var fetchedDays: [String] = []
    var items: [FeedItem] = []
}

enum FeedCache {
    static let keepDays = 14
    /// 이 날짜('yyyy-MM-dd')보다 앞선 항목은 지운다 — today − 14일
    static func cutoff(today: Date) -> String {
        FeedItem.dayFormatter.string(from: Calendar.current.date(byAdding: .day, value: -keepDays, to: today) ?? today)
    }
    /// DESKHUB_FEED_CACHE 가 있으면 그것. 픽스처·SIM 훅만 있으면 nil(기본 경로를 읽지도 쓰지도 않음). 아니면 Config.directory/feed-biorxiv.json
    static var url: URL? {
        let env = ProcessInfo.processInfo.environment
        if let p = env["DESKHUB_FEED_CACHE"], !p.isEmpty { return URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        if !(env["DESKHUB_FEED_FIXTURE"] ?? "").isEmpty || !(env["DESKHUB_FEED_SIM"] ?? "").isEmpty { return nil }
        return Config.directory.appendingPathComponent("feed-biorxiv.json")
    }
    private static var decoder: JSONDecoder { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; d.dateDecodingStrategy = .iso8601; return d }
    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }
    static func load(_ url: URL) -> FeedCacheFile? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(FeedCacheFile.self, from: d)
    }
    /// 14일 지난 항목·받은 날과 확정 안 된 오늘·어제를 지우고 atomic 으로 쓴다
    static func save(_ f: FeedCacheFile, to url: URL, today: Date) {
        var f = f
        let cut = cutoff(today: today)
        f.items = f.items.filter { $0.date >= cut }
        f.fetchedDays = BioRxivFeed.settled(f.fetchedDays, today: today).filter { $0 >= cut }.sorted(by: >)
        guard let d = try? encoder.encode(f) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }
}

// MARK: - 관심 주제 (0.39.0 C3, TOPIC) — Resources/research-topics.json (사용자 폴더 사본이 있고 읽히면 그쪽)
// 판정은 순수 함수 TopicFilter.match 하나 — 뷰(칩·관심만)·덤프([분야 이슈])·text-check(topic)가 같은 함수를 쓴다.
// 구(phrases): 소문자·'-'/'–' 는 공백·공백 하나로 맞춘 뒤 단어 경계로, 끝 s 허용(place cells).
// 약어(caseSensitive): 원문 대소문자 그대로, 앞뒤가 글자·숫자·'-' 가 아니어야(LC-MS 제외), 끝 s 허용. exclude 구가 걸리면 그 주제를 뺀다.

struct ResearchTopic: Codable, Hashable {
    let id: String
    let title: String
    var phrases: [String] = []
    var caseSensitive: [String] = []
    var exclude: [String] = []
    /// 태그 색 자리 0–6 (0.43.0 C4, #49 — Hub.tag). 없으면 파일 순서(ResearchTopicFile.slot)
    var slot: Int? = nil

    private enum CodingKeys: String, CodingKey { case id, title, phrases, caseSensitive, exclude, slot }
    init(id: String, title: String, phrases: [String] = [], caseSensitive: [String] = [], exclude: [String] = []) {
        self.id = id; self.title = title; self.phrases = phrases; self.caseSensitive = caseSensitive; self.exclude = exclude
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        phrases = try c.decodeIfPresent([String].self, forKey: .phrases) ?? []
        caseSensitive = try c.decodeIfPresent([String].self, forKey: .caseSensitive) ?? []
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
        slot = try c.decodeIfPresent(Int.self, forKey: .slot)
    }
}

struct ResearchTopicFile: Codable {
    var note: String?
    /// "draft" 면 카드 머리에 '주제 초안' (결정 D-2 전)
    var status: String?
    var topics: [ResearchTopic]
    var isDraft: Bool { (status ?? "") == "draft" }
    /// 주제의 태그 색 자리 — 파일의 slot, 없으면 파일 순서 (0.43.0 C4)
    func slot(_ id: String) -> Int {
        guard let i = topics.firstIndex(where: { $0.id == id }) else { return 0 }
        return topics[i].slot ?? i
    }
    /// 칩 이름(title) — 모르는 id 면 id 그대로
    func label(_ id: String) -> String { topics.first { $0.id == id }?.title ?? id }
}

/// 한 항목이 한 주제에 걸린 근거 — 주제당 첫 일치 구(또는 약어) 하나
struct TopicMatch: Hashable {
    let id: String
    let title: String
    let phrase: String
}

enum TopicFilter {
    static func load(url: URL) -> ResearchTopicFile? {
        guard let d = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(ResearchTopicFile.self, from: d), !f.topics.isEmpty else { return nil }
        return f
    }
    /// 사용자 폴더(Config.directory/research-topics.json) → 번들. 둘 다 없으면 nil(칩·관심만 없음)
    static func bundled() -> ResearchTopicFile? {
        let user = Config.directory.appendingPathComponent("research-topics.json")
        for url in [user, Bundle.main.url(forResource: "research-topics", withExtension: "json")].compactMap({ $0 }) {
            if let f = load(url: url) { return f }
        }
        return nil
    }

    /// 소문자 · '-'/'–' → 공백 · 공백 하나 — 구와 글 모두 이것으로 맞춘다('decision-making' = 'decision making')
    static func normalize(_ s: String) -> String {
        var out = ""; out.reserveCapacity(s.count)
        var space = true
        for ch in s.lowercased() {
            if ch == "-" || ch == "–" || ch.isWhitespace {
                if !space { out.append(" "); space = true }
            } else { out.append(ch); space = false }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    private static var regexCache: [String: NSRegularExpression] = [:]
    private static let regexLock = NSLock()
    private static func regex(_ pattern: String) -> NSRegularExpression? {
        regexLock.lock(); defer { regexLock.unlock() }
        if let r = regexCache[pattern] { return r }
        let r = try? NSRegularExpression(pattern: pattern)
        regexCache[pattern] = r
        return r
    }
    private static func find(_ pattern: String, in text: String) -> Bool {
        guard let r = regex(pattern) else { return false }
        return r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    /// 구 — 정규화한 글(norm)에서 단어 경계, 끝 s 허용
    static func phraseHit(_ phrase: String, in norm: String) -> Bool {
        let q = normalize(phrase)
        guard !q.isEmpty, norm.contains(q) else { return false }
        return find("(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: q) + "s?(?![\\p{L}\\p{N}])", in: norm)
    }
    /// 약어 — 원문 대소문자 그대로, 앞뒤가 글자·숫자·'-'·'–' 아님(LC-MS·rnn 제외), 끝 s 허용
    static func acronymHit(_ token: String, in raw: String) -> Bool {
        let q = token.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, raw.contains(q) else { return false }
        return find("(?<![\\p{L}\\p{N}\\-–])" + NSRegularExpression.escapedPattern(for: q) + "s?(?![\\p{L}\\p{N}\\-–])", in: raw)
    }

    /// 제목·초록이 걸린 주제 — topics 순서, 주제당 첫 일치 하나(구 먼저, 다음 약어). exclude 가 걸리면 그 주제는 뺀다
    static func match(title: String, abstract: String, topics: [ResearchTopic]) -> [TopicMatch] {
        let raw = title + " | " + abstract          // ' | ' — 제목 끝과 초록 첫 단어가 한 구로 이어지지 않게
        let norm = normalize(raw)
        var out: [TopicMatch] = []
        for t in topics {
            if t.exclude.contains(where: { phraseHit($0, in: norm) }) { continue }
            if let p = t.phrases.first(where: { phraseHit($0, in: norm) }) { out.append(TopicMatch(id: t.id, title: t.title, phrase: p)); continue }
            if let a = t.caseSensitive.first(where: { acronymHit($0, in: raw) }) { out.append(TopicMatch(id: t.id, title: t.title, phrase: a)) }
        }
        return out
    }
}

/// 앱 안 주제 판정 — 주제 파일은 실행당 한 번 읽고, 항목별 결과는 DOI 로 기억한다(뷰가 자주 다시 그려도 정규식을 다시 돌리지 않게)
@MainActor
enum FeedTopics {
    static let file: ResearchTopicFile? = TopicFilter.bundled()
    private static var memo: [String: [TopicMatch]] = [:]
    static func matches(_ x: FeedItem) -> [TopicMatch] {
        if let m = memo[x.doi] { return m }
        let m = TopicFilter.match(title: x.title, abstract: x.abstract, topics: file?.topics ?? [])
        memo[x.doi] = m
        return m
    }
}
