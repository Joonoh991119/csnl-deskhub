import SwiftUI
import AppKit
import Combine

// MARK: - Notion API (토큰은 .env 에서 읽음)

struct NotionAPI {
    let token: String

    init?(cfg: NotionHubConfig) {
        let path = (cfg.tokenEnvFile as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var found: String?
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix(cfg.tokenEnvKey + "=") else { continue }
            var v = String(t.dropFirst(cfg.tokenEnvKey.count + 1)).trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") && v.hasSuffix("\"") || v.hasPrefix("'") && v.hasSuffix("'") { v = String(v.dropFirst().dropLast()) }
            found = v
        }
        guard let f = found, !f.isEmpty else { return nil }
        token = f
    }

    /// page_size 가 100 이상이면 '전부' 요청으로 보고 has_more 를 따라 최대 maxPages(기본 3)페이지까지 (조사 P2 — 추천·일정이 100에서 잘리던 문제).
    /// maxPages 는 시험 훅 DESKHUB_SLAB_SIM=all(SLab 전 페이지, 0.40.0 C1)만 10 으로 넘긴다. 질의·쪽 수는 NotionQueryStats 에 센다(windows.txt 'notion:')
    func query(db: String, body: [String: Any], maxPages: Int = 3) async throws -> [[String: Any]] {
        let wantsAll = (body["page_size"] as? Int ?? 100) >= 100
        var out: [[String: Any]] = []
        var b = body
        NotionQueryStats.add(query: 1, pages: 0)
        for _ in 0..<(wantsAll ? max(1, maxPages) : 1) {
            let (rows, next) = try await queryPage(db: db, body: b)
            NotionQueryStats.add(query: 0, pages: 1)
            out += rows
            guard wantsAll, let n = next else { break }
            b["start_cursor"] = n
        }
        return out
    }

    private func queryPage(db: String, body: [String: Any]) async throws -> ([[String: Any]], String?) {
        let url = URL(string: "https://api.notion.com/v1/databases/\(db)/query")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NSError(domain: "Notion", code: 1) }
        if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 300 {
            throw NSError(domain: "Notion", code: code, userInfo: [NSLocalizedDescriptionKey: (obj["message"] as? String) ?? "HTTP \(code)"])
        }
        let next = (obj["has_more"] as? Bool ?? false) ? obj["next_cursor"] as? String : nil
        return (obj["results"] as? [[String: Any]] ?? [], next)
    }

    /// 페이지 속성 갱신 (체크리스트 완료 등)
    func patch(page: String, properties: [String: Any]) async throws {
        let url = URL(string: "https://api.notion.com/v1/pages/\(page)")!
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["properties": properties])
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 300 {
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            throw NSError(domain: "Notion", code: code, userInfo: [NSLocalizedDescriptionKey: (obj["message"] as? String) ?? "HTTP \(code)"])
        }
    }

    // 속성 읽기 도우미
    static func prop(_ page: [String: Any], _ key: String) -> [String: Any]? {
        (page["properties"] as? [String: Any])?[key] as? [String: Any]
    }
    static func richText(_ arr: Any?) -> String {
        (arr as? [[String: Any]])?.compactMap { $0["plain_text"] as? String }.joined() ?? ""
    }
    static func title(_ page: [String: Any]) -> String {
        guard let props = page["properties"] as? [String: Any] else { return "" }
        for (_, v) in props { if let d = v as? [String: Any], d["type"] as? String == "title" { return richText(d["title"]) } }
        return ""
    }
    static func text(_ page: [String: Any], _ key: String) -> String {
        guard let p = prop(page, key) else { return "" }
        switch p["type"] as? String {
        case "rich_text": return richText(p["rich_text"])
        case "title": return richText(p["title"])
        case "email": return p["email"] as? String ?? ""
        case "url": return p["url"] as? String ?? ""
        case "select": return (p["select"] as? [String: Any])?["name"] as? String ?? ""
        case "status": return (p["status"] as? [String: Any])?["name"] as? String ?? ""
        case "formula":
            let f = p["formula"] as? [String: Any]
            return f?["string"] as? String ?? (f?["number"]).map { "\($0)" } ?? ""
        default: return ""
        }
    }
    static func bool(_ page: [String: Any], _ key: String) -> Bool { prop(page, key)?["checkbox"] as? Bool ?? false }
    static func number(_ page: [String: Any], _ key: String) -> Double? { prop(page, key)?["number"] as? Double }
    static func relationIDs(_ page: [String: Any], _ key: String) -> [String] {
        (prop(page, key)?["relation"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
    }
    static func date(_ page: [String: Any], _ key: String) -> (date: Date, hasTime: Bool)? {
        guard let d = prop(page, key)?["date"] as? [String: Any], let s = d["start"] as? String else { return nil }
        return parseDate(s)
    }
    static func parseDate(_ s: String) -> (date: Date, hasTime: Bool)? {
        if s.count == 10 {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
            return f.date(from: s).map { ($0, false) }
        }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return (d, true) }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s).map { ($0, true) }
    }
    static func dateRange(_ page: [String: Any], _ key: String) -> (start: Date, end: Date?, hasTime: Bool)? {
        guard let d = prop(page, key)?["date"] as? [String: Any], let s = d["start"] as? String, let st = parseDate(s) else { return nil }
        let end = (d["end"] as? String).flatMap(parseDate)?.date
        return (st.date, end, st.hasTime)
    }
    static func pageURL(_ page: [String: Any]) -> URL? { (page["url"] as? String).flatMap(URL.init) }
    static func appURL(id: String) -> URL { URL(string: "notion://www.notion.so/\(id.replacingOccurrences(of: "-", with: ""))")! }
}

/// 갱신 단위 Notion 질의·쪽 수 (0.40.0 C1, F0-3 관측) — refresh 시작 때 0, 갱신 본체(projectPeople 까지)가 끝나면 last 에 굳힌다.
/// 뒤따르는 Blitz·Prolific·댓글은 세지 않는다(그 갱신 본체 밖). windows.txt 'notion: 마지막 갱신 질의 n · 쪽 m'
enum NotionQueryStats {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queries = 0, pages = 0
    nonisolated(unsafe) private static var last: (queries: Int, pages: Int)?
    static func reset() { lock.lock(); queries = 0; pages = 0; lock.unlock() }
    static func add(query q: Int, pages p: Int) { lock.lock(); queries += q; pages += p; lock.unlock() }
    /// 갱신 본체 끝 — 지금 값을 '마지막 갱신' 으로
    static func settle() { lock.lock(); last = (queries, pages); lock.unlock() }
    /// Courses 질의 수 (앱 시작 뒤 합계, 0.42.0 C4) — 6시간 캐시라 갱신을 여러 번 해도 늘지 않아야 한다
    nonisolated(unsafe) private static var courses = 0
    static func addCourses() { lock.lock(); courses += 1; lock.unlock() }
    static var line: String {
        lock.lock(); defer { lock.unlock() }
        guard let l = last else { return "notion: 마지막 갱신 — · Courses 질의 \(courses)(시작 뒤)" }
        return "notion: 마지막 갱신 질의 \(l.queries) · 쪽 \(l.pages) · Courses 질의 \(courses)(시작 뒤)"
    }
}

// MARK: - 모델

struct Member: Identifiable, Hashable {
    let id: String; let name: String; let initials: String; let email: String
    let active: Bool; let order: Int
}
struct GRMSlot: Identifiable, Hashable {
    let id: String; let date: Date; let presenters: String; let type: String
    let notified: Bool; let abstractDone: Bool; let docURL: URL?; let noteIDs: [String]
}
struct Presentation: Identifiable, Hashable {
    let id: String; let title: String; let date: Date?; let status: String; let type: String; let slidePath: String
}
struct EventRow: Identifiable, Hashable {
    let id: String; let title: String; let date: Date; let hasTime: Bool; let type: String
    let status: String
}
/// Paper Blitz 발표 논문 한 편 (Notion 아카이브 또는 NAS pptx 에서)
struct BlitzPaper: Identifiable, Hashable {
    let id: String; let title: String; let presenter: String; let citation: String; let year: Int?
    let coreQuestion: String; var doi: URL?; let notionID: String?; let order: Int
}
struct LinkRow: Identifiable, Hashable { let id: String; let name: String; let url: URL?; let date: Date? }
struct ConferenceRow: Identifiable, Hashable {
    let id: String; let title: String; let conference: String; let start: Date; let end: Date?
    let location: String; let format: String; let authors: String; let international: Bool
    // NAS conferences_upcoming.json (JYK 제공, #7) 에서 온 행만 채운다
    var deadline: Date? = nil; var deadlineLabel: String = ""; var heldLabel: String = ""; var link: URL? = nil
}
struct PaperRec: Identifiable, Hashable {
    let id: String; let title: String; let authors: String; let tier: String; let researcher: String; let doi: URL?
    var recommendation: String = ""; var presentPlanned: Bool = false; var sentAt: Date? = nil
}
/// 오늘의 실험 한 줄 (SLab 예약 · Prolific study — 장비 예약은 0.40.0 C5 부터 장비 카드)
struct ExperimentRow: Identifiable, Hashable {
    let id: String; let source: String; let title: String; let detail: String; let status: String; let url: URL?; let notionID: String?
    /// 실험자 이니셜 — SLab 은 '실험자' relation(Project People 제목 → 멤버 이니셜, 멤버가 아니면 '외부'), Prolific 은 프로젝트 이름(ownerInitials).
    /// 비면 "실험자 미확인". 피험자 이름·ID 는 어디서도 읽지 않는다 (0.40.0 C1, F0-1). SLab title = 프로젝트 · n회차 — 실험명은 쓰지 않는다 (검증 1)
    var owner: String = ""
}
struct MeetingNote: Identifiable, Hashable {
    let id: String; let title: String; let date: Date?; let summary: String; let decisions: String
    let recording: URL?; let status: String; let type: String
    /// 그 주 GRM Magazine PDF(NAS). 파일이 있을 때만
    var magazine: URL? = nil
    /// 발표자 이니셜(Speakers) · NAS 녹취 JSON 경로(Source File) · 거기서 뽑은 핵심 결과 2~3줄
    var speakers: String = ""
    var sourceFile: String = ""
    var highlights: [String] = []
}

/// 드라이런 훅 DESKHUB_NOTION_WRITE=dry:<경로> (0.39.0 C5) — 반응·댓글·'같이 읽자' 쓰기를 Notion POST 대신 이 파일에 {page,text,at} JSON 한 줄로.
/// 읽기(loadPaperComments·addPaperComment)는 이 줄을 페이지별로 PaperComment.parse 해 Notion 값과 합친 뒤 다시 settle — 재시작해도 남는다. 시험 전용(scratch 경로만)
enum NotionDryRun {
    static var path: String? {
        guard let v = ProcessInfo.processInfo.environment["DESKHUB_NOTION_WRITE"], v.hasPrefix("dry:") else { return nil }
        let p = String(v.dropFirst(4))
        return p.isEmpty ? nil : (p as NSString).expandingTildeInPath
    }
    private static var iso: ISO8601DateFormatter { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }
    static func append(page: String, text: String, path: String) throws {
        let url = URL(fileURLWithPath: path)
        let line = try JSONSerialization.data(withJSONObject: ["page": page, "text": text, "at": iso.string(from: Date())], options: [.sortedKeys])
        var d = (try? Data(contentsOf: url)) ?? Data()
        if let last = d.last, last != 0x0A { d.append(0x0A) }
        d.append(line); d.append(0x0A)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try d.write(to: url, options: .atomic)
    }
    /// 페이지 → 그 페이지의 드라이런 댓글(settle 전). id = 'dry:<줄 번호>' — 파일은 덧붙이기만 하므로 안정
    static func comments(path: String) -> [String: [PaperComment]] {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        let f = iso
        var out: [String: [PaperComment]] = [:]
        for (i, line) in s.split(separator: "\n").enumerated() {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let page = o["page"] as? String, let text = o["text"] as? String,
                  let c = PaperComment.parse(raw: text, id: "dry:\(i)", created: (o["at"] as? String).flatMap { f.date(from: $0) }) else { continue }
            out[page, default: []].append(c)
        }
        return out
    }
    /// base(settle 뒤 값, 이전에 합친 드라이런 줄 포함 가능) + 드라이런 줄 → 같은 id 는 드라이런 쪽으로 한 번만, 다시 settle
    static func merge(_ base: [PaperComment], _ dry: [PaperComment]) -> [PaperComment] {
        let ids = Set(dry.map(\.id))
        return PaperComment.settle(base.filter { !ids.contains($0.id) } + dry)
    }
}

@MainActor
final class NotionHubModel: ObservableObject {
    @Published var members: [Member] = []
    /// 지난 1주 이후 GRM — 다음 GRM·경보·안내판·공정 보드가 쓰는 목록 (0.40.0 C6 부터 grmAll 에서 거른다 — 동작 그대로)
    @Published var grm: [GRMSlot] = []
    /// 올해 1월 1일부터의 GRM 전체 (0.40.0 C6, A6 — 자료 지도·순번 '지난 GRM')
    @Published var grmAll: [GRMSlot] = []
    /// NAS 회차 폴더 목록 (GRMMap.scan, 백그라운드) · Paper Blitz Archive 의 모든 날짜
    @Published var grmScan: GRMFolderScan?
    /// 회의록 날짜 전부(Type 'Other' 포함, 제목 있는 행) — GRM 자료 지도 '회의록' 열 (A6-minutes, 검증 1). minutes 는 카드용으로 Other 를 뺀다
    @Published var minuteDaysAll: Set<Date> = []
    var grmScanRunning = false
    @Published var blitzDates: Set<Date> = []
    @Published var notes: [Presentation] = []
    @Published var events: [EventRow] = []
    @Published var cwll: [LinkRow] = []
    @Published var minutes: [MeetingNote] = []
    @Published var conferences: [ConferenceRow] = []
    @Published var papers: [PaperRec] = []
    @Published var experiments: [ExperimentRow] = []
    @Published var experimentsNote: String?
    /// Prolific 전체 study (모든 상태, 메모리만 — 0.40.0 C7, A4 온라인 수집). 금액은 쓰지 않는다
    @Published var prolificStudies: [ProlificStudy] = []
    /// Prolific 연결 상태 — 미연결·조회 실패는 '오늘의 실험' 카드 안에 표시 (#17, 실험 없음과 구분). nil = 연결됨 또는 꺼짐
    @Published var prolificNote: String?
    /// 마지막 Prolific 조회 성공 시각(실제 시각) — 실패해도 지난 행이 남아 있으면 '아래는 HH:mm 결과' (0.38.0 C5, M-PROLIFIC)
    private(set) var prolificOKAt: Date?
    @Published var blitz: [BlitzPaper] = []
    @Published var blitzDate: Date?
    @Published var blitzSource: String?      // "Notion" 또는 pptx 경로
    @Published var blitzNote: String?        // 비어 있는 이유
    @Published var blitzLoading = false
    /// NAS 에 Notion 보다 새 PB 덱이 있어 그걸 보이는 중 (Notion 반영은 주간 파이프라인 — 조사 원인 A·B, 2026-10-14)
    @Published var blitzPending = false
    /// NAS 에 녹취는 왔는데 Notion 회의록이 아직 없는 가장 최근 GRM 날짜
    @Published var minutesPending: Date?
    /// 리마인더 (NAS Grant/_ssot/reminders.json — 컨펌한 것만 리마인드, Reminders.swift)
    @Published var reminders: [ReminderItem] = []
    /// reminders.json 이 깨져 있으면 이유 — 이때는 등록·끝남 버튼을 잠근다 (덮어써서 잃지 않게)
    @Published var remindersLocked: String?
    /// reminders.json 을 이번 실행에서 한 번이라도 제대로 읽었나(.ok) — '내 것' 배지(rem-mine)는 이것이 참일 때만 기준선을 만든다.
    /// NAS 미마운트(.missing)에서 빈 기준선이 저장되면 마운트 뒤 내 리마인더 전부가 '새 n' 이 됐다 (리뷰, 검증 1)
    var remindersLoadedOK = false
    /// 리마인더 끝남·아님의 6초 미룸 — 모델에 두어 뷰를 바꿔도 잃지 않는다 (D1 리뷰)
    let reminderCommits = DelayedCommit(seconds: 6)
    /// 마지막 저장 실패 — 리마인더 칸에 [다시 시도] 한 줄
    @Published var reminderSaveFailed: ReminderItem?
    /// 미팅 후속 (0.41.0 C2, MeetingFollowups.swift) — NAS <grantsFile 폴더>/followups 의 proposals.json(스크립트가 씀) + state-<이니셜>.json(본인 앱이 씀).
    /// followups = 제안 + 직접 적은 항목 · followupStates = 이니셜 → 상태 행 · 읽기 '?' 면 단추 잠김 · 적색 없음
    @Published var followups: [FollowupItem] = []
    @Published var followupStates: [String: [FollowupState]] = [:]
    @Published var followupRead: FollowupRead = .unknown("읽기 전")
    @Published var followupsGenerated: Date?
    /// proposals 손상 · 내 상태 파일 손상이면 이유 — 쓰지 않는다
    @Published var followupLocked: String?
    /// 마지막 저장 실패(항목 id)
    @Published var followupSaveFailed: String?
    /// 상태 파일이 깨진 이니셜 — 그 사람만 '?'
    @Published var followupCorrupt: Set<String> = []
    var followupStateFiles = 0
    /// proposals.json 을 이번 실행에서 제대로 읽었나 — 'fu-mine' 배지 기준선은 이것이 참일 때만 (remindersLoadedOK 와 같은 이유)
    var followupsLoadedOK = false
    /// 끝남·아님의 6초 미룸 — 모델에 두어 뷰를 바꿔도 잃지 않는다
    let followupCommits = DelayedCommit(seconds: 6)
    /// 시간표 (0.42.0 C4, Timetable.swift) — Notion Courses 지금 학기 행(정규화) · 못 읽은 행 수 · 읽기 실패 이유(적색 아님) · 6시간 캐시
    @Published var courses: [CourseRow] = []
    @Published var coursesUnparsed = 0
    @Published var coursesNote: String?
    @Published var coursesSource = "Notion"
    var coursesFetchedAt: Date?
    var coursesSemester: String?
    /// 멤버 상태 (0.42.0 C5, MemberStatus.swift) — 이니셜 → 상태. 갱신 끝·1분 시계마다 updateMemberStatus 가 한 번 계산(화면 넷은 이것만 읽음)
    @Published var memberStatus: [String: MemberStatusValue] = [:]
    /// Joint projects (0.42.0 C6, JointProjects.swift) — plugin_status.json 행(스크립트가 씀, 앱은 읽기만) · 생성 시각 · 스크립트 오류 · 읽기 실패 이유
    @Published var jointRows: [PluginStatusRow] = []
    @Published var jointGenerated: Date?
    @Published var jointErrors: [String] = []
    @Published var jointNote: String? = "읽기 전"
    @Published var loading = false
    @Published var lastUpdated: Date?
    /// 한 번의 갱신이 다 끝난 때(실제 시각, 변화 알림용) — Notion·그랜트·리마인더·학회 합치기에 더해 그 갱신이 띄운 논문 댓글·Paper Blitz·Prolific·최신 원고까지.
    /// 늦는 것이 있으면 갱신 끝 20초 뒤 그대로. 관제탑 기본 펼침이 이것을 기다린다 — lastUpdated 는 그랜트·댓글보다 먼저 서므로 부분 데이터로 하루 결정이 굳었다 (검증 1 리뷰)
    @Published var settledAt: Date?
    /// settledAt 의 날짜(HubClock 기준 — DESKHUB_NOW 고정 시각과 같은 달력)
    private(set) var settledDay: Date?
    private var settleWaits: Set<String> = []
    private var settleGen = 0
    @Published var error: String?
    @Published var tokenMissing = false
    /// 1분마다 갱신 — 지난 일정 흐리게·D-day 가 자정을 넘어도 맞도록 (Notion 갱신 주기와 별개)
    @Published var now = HubClock.now
    /// 논문 추천 페이지별 Notion 댓글(반응 이모지 + 댓글)
    @Published var paperComments: [String: [PaperComment]] = [:]
    /// 진행 중인 프로젝트 (Projects & Chores, 상태 In Progress·Review, Lab Chore 제외)
    @Published var projects: [ProjectRow] = []
    /// 최신 원고 (OpenAlex — notionHub.manuscriptAuthors)
    @Published var preprints: [PreprintRow] = []
    @Published var preprintsLoading = false
    /// 분야 최근 이슈 (0.39.0 C2, ResearchFeed.swift) — bioRxiv neuroscience v1, 날짜 내림차순(캐시 14일 전체 — 화면·덤프는 7일 구간)
    @Published var feed: [FeedItem] = []
    @Published var feedLoading = false
    /// 마지막 받기 성공·시도 (실제 시각)
    @Published var feedOKAt: Date?
    @Published var feedTriedAt: Date?
    /// 받기 실패 안내 — 목록은 그대로(캐시). 적색 아님
    @Published var feedNote: String?
    /// 마지막 실패 이유 (툴팁·덤프)
    @Published var feedError: String?
    /// 지금 목록의 출처 — network · fixture · cache · none
    @Published var feedOrigin = "none"
    /// 마지막 받기의 호출 수 · 이 세션의 네트워크 받기 횟수
    @Published var feedLastCalls = 0
    @Published var feedRuns = 0
    /// 모든 쪽을 읽은 날('yyyy-MM-dd') — 오늘·어제는 늘 다시 받는다
    @Published var feedFetchedDays: [String] = []
    private var feedCacheRead = false
    /// 마지막 네트워크 받기가 빠진 날(오늘·어제 밖)을 하나도 채우지 못했나 — 그러면 12시간 쉰다(10분마다 상한까지 헛도는 것 막기, 0.39.0 검증 1)
    private var feedStalled = false
    /// 그랜트 (SSOT grants_schedule.json)
    @Published var grants: [GrantRow] = []
    @Published var memberLinks = MemberLinks()
    /// 학회 관심 (0.37.0 C5, ConferenceInterest.swift) — 학회키 → 관심 on 인 이니셜(정렬). NAS Grant/_ssot/conference_interest.json
    @Published var conferenceInterest: [String: [String]] = [:]
    /// 관심 파일이 깨져 있으면 이유 — '관심' 단추를 잠근다(덮어써서 잃지 않게)
    @Published var interestLocked: String?
    /// 마지막 저장 실패 — 학회 카드에 '관심 저장 실패 · 다시 시도'
    @Published var interestSaveFailed: InterestFailure?
    /// 이니셜을 확인하지 않은 맥에서 '관심' 을 누르면 카드 안에 이니셜 확인 줄
    @Published var interestAskMe = false
    /// 6초 대기 중인 관심 토글의 목표 상태 (학회키 → on)
    @Published var interestTargets: [String: Bool] = [:]
    /// 관심 표시·해제의 6초 미룸 — 모델에 두어 뷰를 바꿔도 잃지 않는다
    let interestCommits = DelayedCommit(seconds: 6)
    /// 논문 소통 '같이 읽자' 의 6초 미룸 (0.39.0 C5) — Notion 댓글은 지울 수 없어 그 안에 되돌리기. 되돌리기 줄은 연구 탭 오른쪽 칸 아래에만
    let talkCommits = DelayedCommit(seconds: 6)
    /// Members 현황판 Milestone 열 (0.37.0 C7, MembersBoard.swift) — 이니셜 → NAS MM 최신 파일. nil = MM 폴더 없음(NAS 끊김) → 열 숨김
    @Published var milestones: [String: MilestoneFile]? = nil
    /// MM 이름 날짜(4규칙)의 그 해 고유 날짜 수 — (연도, 이니셜 → n). 덤프 [Members 전광판] 'MM 고유 날짜' 줄만 (0.40.0 C1, F0-4)
    var milestoneDays: (year: Int, days: [String: Int])? = nil
    /// 일일 집계 (0.40.0 C2, A1 — scripts/aggregate_daily.py 가 이 맥 Application Support/DeskHub/metrics/latest.json 에 씀, 훅 DESKHUB_METRICS).
    /// 없거나 schema ≠ 1 이면 nil + metricsNote('집계 없음' 등). 적색 없음
    @Published var metrics: MetricsSnapshot?
    @Published var metricsNote: String?
    /// conferences_upcoming.json 의 generated 날짜 — 학회 카드 꼬리표·자료 상태 (0.40.0 C3, A2)
    @Published var conferencesGenerated: Date?
    /// 장비 예약 (0.40.0 C5, A5·F0-2 — Equipment.swift) — Resource 의 Canceled 아닌 예약 중 앱 창((끝 ?? 시작) ≥ 오늘−14 또는 Running)
    @Published var equipment: [EquipmentRow] = []
    /// 장비 6개 순서 — 받은 예약의 장비 이름을 행 수 내림차순(같으면 이름)
    @Published var equipmentMachines: [String] = []
    /// Resource 조회 성공 여부 · 받은 행 수 — 실패면 위생 '닫기 누락' 은 집계 값
    @Published var equipmentLoaded = false
    @Published var equipmentReceived = 0
    /// 받은 예약 전체(앱 창 적용 전)의 오늘 이하 시작일 최댓값 — 장비 꼬리표·자료 상태 Resource 행. 창(오늘−14)으로 거르면 2주 예약이 없을 때 꼬리표가 사라졌다 (리뷰, 검증 1)
    @Published var equipmentLatestStart: Date?
    /// 허브의 오늘 캘린더. @Published 가 아니라 보드·관제탑 본체·팝오버는 이 모델만 관찰한다 →
    /// 첫 조회 끝(isSettled)을 이 모델의 변화로 한 번 알린다 (0.37.0 C6 — '불러오는 중…' 이 다섯 곳에서 같이 풀리게)
    var todayCalendar: CalendarModel? = nil {
        didSet {
            calSettledSink = todayCalendar?.$isSettled.removeDuplicates().dropFirst().sink { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            }
        }
    }
    private var calSettledSink: AnyCancellable?

    /// 지난 Paper Blitz 덱 — NAS GRM/<yyyy>/<yyyymmdd>/PB_yymmdd.pdf (없으면 .pptx)
    var blitzDeckPath: String? {
        guard let d = blitzDate else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy"; let y = f.string(from: d); f.dateFormat = "yyyyMMdd"; let ymd = f.string(from: d); f.dateFormat = "yyMMdd"; let s = f.string(from: d)
        let dir = "\(cfg.nasGRMRoot)/\(y)/\(ymd)"
        return ["pdf", "pptx"].map { "\(dir)/PB_\(s).\($0)" }.first { FileManager.default.fileExists(atPath: $0) }
    }
    private var preprintsFetchedAt: Date?
    /// 최신 원고를 마지막으로 받은 시각 — 카드 캡션 '기준' (0.40.0 C2)
    var preprintsAt: Date? { preprintsFetchedAt }

    let cfg: NotionHubConfig
    let prolific: ProlificConfig
    let nasRoot: String
    private let api: NotionAPI?
    private var loop: Task<Void, Never>?
    private var clock: Task<Void, Never>?

    init(cfg: NotionHubConfig, prolific: ProlificConfig = ProlificConfig(), nasRoot: String) {
        self.cfg = cfg
        self.prolific = prolific
        self.nasRoot = nasRoot
        self.api = NotionAPI(cfg: cfg)
        Hub.showWeekday = cfg.display.showWeekday
        tokenMissing = api == nil
        loop = Task { @MainActor [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(2, self?.cfg.refreshMinutes ?? 10)) * 60_000_000_000)
                guard let self else { return }     // 설정 다시 읽기로 모델이 바뀌면 끝낸다
                await self.refresh()
            }
        }
        clock = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self else { return }
                self.now = HubClock.now
                self.updateMemberStatus()   // 1분마다 조용히 (알림 없음, 0.42.0 C5)
            }
        }
    }

    var today: Date { HubClock.today }
    var nextGRM: GRMSlot? { grm.first { $0.date >= today } }
    var upcomingGRM: [GRMSlot] { Array(grm.filter { $0.date >= today }.prefix(cfg.upcomingGRMCount)) }
    /// 지난 GRM — 오늘이 GRM 날이면 정오가 지나면 오늘 것을 '지난'으로 본다 (조사 원인 D: 당일엔 지난주를 정상으로 판정했음)
    var lastGRM: GRMSlot? {
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: today)!
        return grm.last { $0.date < today || (Calendar.current.isDate($0.date, inSameDayAs: today) && now >= noon) }
    }
    /// 올해 GRM 전체(grmAll)에서 같은 정오 규칙의 마지막 GRM — 내용 날짜 꼬리표·자료 상태 'GRM Schedule' 행용.
    /// lastGRM 은 지난 1주(grm)만 봐서 늘 '정상'이고, 방학처럼 1주 넘게 GRM 이 없으면 nil 이 되어 꼬리표가 사라졌다 (리뷰, 검증 1)
    var lastGRMContent: Date? {
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: today)!
        return grmAll.filter { $0.date < today || (Calendar.current.isDate($0.date, inSameDayAs: today) && now >= noon) }.map(\.date).max()
    }
    /// 다가오는 일정: 오늘~eventsDays, GRM·할 일 Type 제외
    var visibleEvents: [EventRow] {
        let end = Calendar.current.date(byAdding: .day, value: cfg.eventsDays, to: today)!
        return events.filter { $0.date >= today && $0.date < end && !cfg.display.hideEventTypes.contains($0.type) && !Hub.isHiddenEvent($0.title) }
    }
    var remindersPath: String {
        // 테스트 훅 (UX 0.34.0): DESKHUB_REMINDERS=<픽스처 경로> 면 NAS 대신 그 파일 — QA 가 NAS 원본에 쓰지 않고 확인 (DESKHUB_NOW 와 같은 방식)
        if let p = ProcessInfo.processInfo.environment["DESKHUB_REMINDERS"], !p.isEmpty { return (p as NSString).expandingTildeInPath }
        return ((cfg.grantsFile as NSString).deletingLastPathComponent as NSString).appendingPathComponent("reminders.json")
    }
    /// 컨펌한 리마인더: 끝나지 않은 것, 2주 전 것까지, 날짜순
    var confirmedReminders: [ReminderItem] {
        let start = Calendar.current.date(byAdding: .day, value: -14, to: today)!
        return reminders.filter { $0.status == "confirmed" && ($0.day.map { $0 >= start } ?? true) }
            .sorted { ($0.day ?? .distantFuture) < ($1.day ?? .distantFuture) }
    }
    /// 제안: 파일의 proposed + Schedule & Events 중 제목이 제출·방문 등인 다가오는 일정(파일에 없는 것)
    var reminderProposals: [ReminderItem] {
        let known = Set(reminders.map(\.id))
        let fromFile = reminders.filter { $0.status == "proposed" }
        let fromEvents = events.filter { $0.date >= today && !known.contains($0.id) }.compactMap { e -> ReminderItem? in
            let k = e.type == "Deadline" ? "제출" : RemindersFile.kind(forTitle: e.title)
            guard let k else { return nil }
            return ReminderItem(id: e.id, title: e.title, date: RemindersFile.dayFormatter.string(from: e.date), kind: k,
                                source: "notion:" + e.id, status: "proposed", by: nil, at: nil)
        }
        // 그랜트 마감·학회 초록 마감도 30일 안이면 제안 (#13 JYK — 리마인더 칸에 들어갈 것). 등록은 사람이
        let soon = Calendar.current.date(byAdding: .day, value: 30, to: today)!
        let fromGrants = grants.compactMap { g -> ReminderItem? in
            guard let d = g.due, d >= today, d <= soon else { return nil }
            let ds = RemindersFile.dayFormatter.string(from: d)
            // id 에 마감일을 넣는다 (리뷰 R2, 0.35.0) — 'grant:'+제목만이면 해마다 같은 id 가 되어, 올해 등록이 upsert 로 작년 행의 status 만 바꾸고
            // 날짜는 작년으로 남는다. 옛 형식('grant:'+제목) 행은 그대로 두고(마이그레이션 없음) 아래 날짜 창 안에서 같은 사건으로 인정한다
            let id = "grant:" + g.title + "@" + ds
            guard !reminders.contains(where: { Self.sameGrantProposal($0, grantTitle: g.title, due: d, newID: id) }) else { return nil }
            return ReminderItem(id: id, title: g.title + (g.kind == "지원" ? " 접수" : " 제출"), date: ds, kind: g.kind == "지원" ? "제출" : "보고",
                                source: "grants_schedule.json", status: "proposed", by: nil, at: nil)
        }
        let fromConfs = conferences.compactMap { c -> ReminderItem? in
            guard let d = c.deadline, d >= today, d <= soon else { return nil }
            let id = "conf:" + c.id
            guard !known.contains(id) else { return nil }
            return ReminderItem(id: id, title: "\(c.conference) 초록 마감", date: RemindersFile.dayFormatter.string(from: d), kind: "제출",
                                source: "conferences_upcoming.json", status: "proposed", by: nil, at: nil)
        }
        return (fromFile + fromEvents + fromGrants + fromConfs).sorted { ($0.day ?? .distantFuture) < ($1.day ?? .distantFuture) }
    }
    /// 그랜트 제안을 건너뛸 리마인더인가 (리뷰 R2, 0.35.0). 상태 무관(done·dismissed 포함) — 이미 다룬 사건을 다시 제안하지 않게.
    /// 새 id 와 정확히 같으면 날짜와 상관없이 같은 사건(id 에 마감일이 들어 있다). 그 밖에는 리마인더 날짜가 마감 ±60일 안이고
    /// (옛 형식 id 'grant:'+제목 || AlertEngine.sameEvent) 일 때만 — 작년 같은 이름의 마감(done)이 올해 제안을 막지 않게. 날짜 없는 행은 새 id 일치만
    static func sameGrantProposal(_ r: ReminderItem, grantTitle: String, due: Date, newID: String) -> Bool {
        if r.id == newID { return true }
        guard let rd = r.day else { return false }
        let cal = Calendar.current
        let gap = cal.dateComponents([.day], from: cal.startOfDay(for: rd), to: cal.startOfDay(for: due)).day ?? Int.max
        guard abs(gap) <= 60 else { return false }
        return r.id == "grant:" + grantTitle || AlertEngine.sameEvent(reminderID: r.id, reminderTitle: r.title, grantTitle: grantTitle)
    }
    /// "Meeting: SK" → "김성제" (Type 접두사 제거, 이니셜은 이름으로)
    func displayTitle(forEvent e: EventRow) -> String {
        var t = Hub.canonicalNames(e.title)
        if !e.type.isEmpty, let r = t.range(of: "^\\s*" + NSRegularExpression.escapedPattern(for: e.type) + "\\s*:\\s*", options: [.regularExpression, .caseInsensitive]) { t.removeSubrange(r) }
        let parts = t.components(separatedBy: CharacterSet(charactersIn: ",/·")).map { $0.trimmingCharacters(in: .whitespaces) }
        let mapped = parts.map { part -> String in
            let key = part.components(separatedBy: CharacterSet(charactersIn: " (")).first ?? part
            if let m = member(initials: key) { return part.replacingOccurrences(of: key, with: m.name) }
            return part
        }
        return mapped.joined(separator: ", ")
    }
    /// 해당 날짜의 GRM 발표자 이름들
    func grmPresenters(on date: Date) -> String { grm.first { Calendar.current.isDate($0.date, inSameDayAs: date) }?.presenters ?? "" }
    func member(initials: String) -> Member? {
        let key = (cfg.initialsAliases[initials] ?? initials).uppercased()
        return members.first { $0.initials.uppercased() == key }
    }
    /// 내 Members 행 — me 가 비면 nil, 이름·이니셜이 빈 행(교수·빈 행)은 제외. 빈 값이면 String.contains("") 가 늘 true 라 전부 '내 것' 이 된다 (검증 1 리뷰)
    func myMember(_ me: String) -> Member? {
        guard !me.isEmpty, let m = member(initials: me), !m.name.isEmpty, !m.initials.isEmpty else { return nil }
        return m
    }
    /// 내 것 판정 — 경보(AlertEngine)·안내판(BoardView) 공용 한 규칙: 제목에 이름(한글·영문) 또는 이니셜
    func isMine(_ text: String, me: String) -> Bool {
        guard let m = myMember(me) else { return false }
        // 이니셜은 토큰 단위로 — 부분 문자열이면 me=SL 이 'JSL'·'SLab' 에 걸린다 (리뷰 10-15 medium). 이름은 전체 문자열 포함.
        if text.contains(m.name) { return true }
        let tokens = text.uppercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
        return tokens.contains(m.initials.uppercased())
    }
    /// 이름("Joonoh Park", "박준오", "JOP")을 Members DB 이니셜로. 못 찾으면 받은 그대로 (다른 호출자 — 안내판 whoInitials 가 '외부' 로 바꾼다).
    /// 0.40.0 C1 (F0-1): 부분 일치는 initialsList 와 같은 '한 명일 때만' — 둘 이상 걸리면(이보현 BHL·이보연 BYL) 고르지 않는다.
    /// 이메일은 접두가 아니라 local part 가 같을 때만
    func initials(forName raw: String) -> String {
        let n = raw.trimmingCharacters(in: .whitespaces); if n.isEmpty { return "" }
        if let m = member(initials: n), !m.initials.isEmpty { return m.initials }
        let pool = members.filter { !$0.name.isEmpty && !$0.initials.isEmpty }
        let key = Self.normName(n)
        let exact = pool.filter { Self.normName($0.name) == key || Self.emailLocal($0.email) == key }
        if exact.count == 1 { return exact[0].initials }
        let partial = pool.filter { let nm = Self.normName($0.name); return nm.contains(key) || key.contains(nm) }
        return partial.count == 1 ? partial[0].initials : n
    }
    nonisolated static func normName(_ s: String) -> String { s.lowercased().replacingOccurrences(of: " ", with: "") }
    nonisolated static func emailLocal(_ e: String) -> String {
        let l = e.lowercased().trimmingCharacters(in: .whitespaces)
        return l.split(separator: "@").first.map(String.init) ?? ""
    }
    /// 실험자·예약자 칸 공용 규칙 (0.40.0 C1, F0-1) — 빈 값·'Project' 는 '', 이니셜·별칭·이름 전체·이메일 local part 가 **정확히** 맞으면 그 멤버 이니셜,
    /// 그 밖은 '외부'. 부분 일치는 쓰지 않는다(원문 이름이 화면·덤프·경보에 새지 않게). Prolific 프로젝트 폴백·Resource User 가 쓴다
    func ownerInitials(raw: String) -> String { Self.ownerInitials(raw: raw, members: members, aliases: cfg.initialsAliases) }
    nonisolated static func ownerInitials(raw: String, members: [Member], aliases: [String: String]) -> String {
        let n = raw.trimmingCharacters(in: .whitespaces)
        if n.isEmpty || n == "Project" { return "" }
        let pool = members.filter { !$0.initials.isEmpty }
        let ini = (aliases[n] ?? aliases[n.uppercased()] ?? n).uppercased()
        if let m = pool.first(where: { $0.initials.uppercased() == ini }) { return m.initials }
        let key = normName(n)
        let exact = pool.filter { (!$0.name.isEmpty && normName($0.name) == key) || (!$0.email.isEmpty && emailLocal($0.email) == key) }
        return exact.count == 1 ? exact[0].initials : "외부"
    }
    /// SLab 한 행 → 오늘의 실험 줄 (0.40.0 C1, F0-1 — 순수 함수, text-check 'slab' 과 같은 함수).
    /// owner = '실험자' relation id → people(Project People id(하이픈 없음) → 제목 이니셜)의 첫 값 → canonical(멤버면 정본 이니셜, 별칭 포함).
    /// relation 이 있고 풀렸는데 멤버가 아니면 '외부', relation 이 비었거나 풀리지 않으면 ''(카드 '실험자 미확인').
    /// title = [프로젝트 text(앞 40자, 비면 '프로젝트 미기재'), 'n회차'] 를 ' · ' 로 — 집계(aggregate_daily slab.keys)와 같은 '프로젝트' 칸.
    /// 제목 칸(실험명)은 쓰지 않는다: 실험명에 피험자 이름·ID 가 들어 있다(qa040 M8 — 244·15건) (검증 1).
    /// detail = 시간. '상태' 가 '취소' 면 nil. 피험자 이름·ID 칸과 실험명은 읽지 않는다(키 문자열도 코드에 없다)
    nonisolated static func slabRow(_ p: [String: Any], people: [String: String], canonical: (String) -> String?) -> ExperimentRow? {
        let status = NotionAPI.text(p, "상태")
        guard status != "취소" else { return nil }
        let resolved = NotionAPI.relationIDs(p, "실험자").compactMap { people[$0.replacingOccurrences(of: "-", with: "")] }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let owner = resolved.first.map { canonical($0) ?? "외부" } ?? ""
        let round = NotionAPI.number(p, "회차").map { "\(Int($0))회차" } ?? ""
        let project = String(NotionAPI.text(p, "프로젝트").trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let title = [project.isEmpty ? "프로젝트 미기재" : project, round].filter { !$0.isEmpty }.joined(separator: " · ")
        let detail = NotionAPI.text(p, "시간").trimmingCharacters(in: .whitespaces)
        let id = p["id"] as? String
        return ExperimentRow(id: id ?? UUID().uuidString, source: "SLab", title: title, detail: detail,
                             status: status, url: nil, notionID: id, owner: owner)
    }
    /// 쉼표 목록("박준오, 이보현")을 이니셜 목록("JOP, BHL")으로 — 경보·공정 보드·안내판 리본 공용 (UX 0.34.0).
    /// 멤버가 아닌 이름(외부 발표자·Guest)은 그대로. 이니셜·전체 이름이 같으면 바로, 아니면 부분 일치가 **한 명일 때만** —
    /// 둘 이상 걸리면(이보현 BHL·이보연 BYL 처럼) 고르지 않고 원래 이름을 둔다. Members 로드 전에는 이름 그대로
    func initialsList(_ names: String) -> String {
        let pool = members.filter { !$0.name.isEmpty && !$0.initials.isEmpty }
        func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: " ", with: "") }
        return names.components(separatedBy: ",").map { raw -> String in
            let n = raw.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return "" }
            if let m = member(initials: n), !m.initials.isEmpty { return m.initials }
            let key = norm(n)
            let exact = pool.filter { norm($0.name) == key }
            if exact.count == 1 { return exact[0].initials }
            let partial = pool.filter { let nm = norm($0.name); return nm.contains(key) || key.contains(nm) }
            return partial.count == 1 ? partial[0].initials : n
        }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
    nonisolated static func magazineURL(dir: String, date: Date) -> URL? {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"
        let path = "\(dir)/GRM_magazine_\(f.string(from: date)).pdf"
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
    func note(for slot: GRMSlot) -> Presentation? {
        notes.first { n in n.date.map { Calendar.current.isDate($0, inSameDayAs: slot.date) } ?? false }
    }
    func member(named name: String) -> Member? { members.first { name.contains($0.name) } }
    /// 해당 GRM 주의 CWLL 문서
    func cwllDoc(for slot: GRMSlot) -> URL? {
        cwll.first { r in r.date.map { Calendar.current.isDate($0, inSameDayAs: slot.date) } ?? false }?.url
    }

    /// 마지막으로 조회를 시작한 때 — 실패해 lastUpdated 가 안 바뀌어도 팝오버 열기마다 다시 조회하지 않게 (refreshIfStale)
    private var refreshStartedAt: Date?
    /// 팝오버를 열 때 (UX menubar-glance-67, 0.34.0): 마지막 조회(성공·시도 중 늦은 것)가 ttl 보다 오래면 다시. 진행 중이면 그대로
    /// 가벼운 경로(light) — DB 쿼리·NAS 파일만. 논문 댓글(논문마다 GET)은 자체 TTL(commentsTTL), Paper Blitz 는 주기 갱신에만 (검증 1)
    func refreshIfStale(ttl: TimeInterval) {
        guard !loading else { return }
        if let last = [lastUpdated, refreshStartedAt].compactMap({ $0 }).max(), Date().timeIntervalSince(last) < ttl { return }
        Task { @MainActor [weak self] in await self?.refresh(light: true) }
    }

    /// 논문 댓글 마지막 조회 시각 — 가벼운 갱신은 이보다 commentsTTL 이 지났을 때만 댓글을 다시 읽는다
    private var paperCommentsAt: Date?
    static let commentsTTL: TimeInterval = 600
    /// 논문 댓글을 실제로 읽은 시각(조회 끝) — 전광판 '논문 반응' 열이 읽기 전이나 첫 조회가 모두 실패했을 때 0 대신 '—' 를 보이게 (0.39.0 C4)
    @Published private(set) var paperCommentsReadAt: Date?

    /// light = 팝오버 열기 재조회: Notion DB 쿼리 약 14개 + NAS 파일. 댓글은 10분 TTL, Blitz(Notion·NAS·pptx)는 건너뜀
    func refresh(light: Bool = false) async {
        // 겹친 호출(주기 루프·'r' 키·메뉴 갱신·팝오버 열기)은 한 번만 — 진행 중이면 그 조회가 곧 끝나므로 건너뛴다
        guard !loading else { return }
        // 분야 최근 이슈 (0.39.0 C2) — Notion 토큰과 무관하게 api 가드 앞에서 띄운다. '다 옴' 대기 목록에는 넣지 않는다
        // (최소 9초 걸리는 호출이 settledAt·관제탑 기본 펼침·허브 채움을 늦추지 않게). 자체 TTL(성공 12시간·실패 1시간)
        if !feedLoading { Task { @MainActor [weak self] in await self?.loadFeed() } }
        guard let api else { tokenMissing = true; return }
        loading = true
        refreshStartedAt = Date()
        defer { loading = false }
        NotionQueryStats.reset()
        // 시험 훅 (0.40.0 C1, M8) — DESKHUB_SLAB_SIM=all 이면 SLab 날짜 조건을 빼고 전 페이지(최대 10쪽)를 받는다. 372행이 카드·공정 보드에 쏟아지므로 시험 전용
        let slabAll = ProcessInfo.processInfo.environment["DESKHUB_SLAB_SIM"] == "all"
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let weekAgoDate = Calendar.current.date(byAdding: .day, value: -7, to: today)!
        let yearStart = f.string(from: Calendar.current.date(from: DateComponents(year: Calendar.current.component(.year, from: today), month: 1, day: 1))!)
        let todayS = f.string(from: today)
        let horizon = f.string(from: Calendar.current.date(byAdding: .day, value: max(cfg.eventsDays, cfg.checklistDays), to: today)!)
        let twoWeeksAgo = f.string(from: Calendar.current.date(byAdding: .day, value: -14, to: today)!)
        let twoWeeksAhead = f.string(from: Calendar.current.date(byAdding: .day, value: 14, to: today)!)
        do {
            async let membersRaw = api.query(db: cfg.membersDB, body: ["page_size": 50, "sorts": [["property": "Rotation order", "direction": "ascending"]]])
            // 올해 1월 1일부터 (0.40.0 C6, A6 — 49행 1쪽). grm 은 이 중 지난 1주 이후만
            async let grmRaw = api.query(db: cfg.grmScheduleDB, body: [
                "page_size": 100,
                "filter": ["property": "날짜", "date": ["on_or_after": yearStart]],
                "sorts": [["property": "날짜", "direction": "ascending"]]])
            async let notesRaw = api.query(db: cfg.presentationsDB, body: [
                "page_size": max(cfg.recentNotesCount, cfg.upcomingGRMCount) + 4,
                "sorts": [["property": "날짜", "direction": "descending"]]])
            async let eventsRaw = api.query(db: cfg.eventsDB, body: [
                "page_size": 100,
                "filter": ["and": [["property": "날짜", "date": ["on_or_after": twoWeeksAgo]], ["property": "날짜", "date": ["on_or_before": horizon]]]],
                "sorts": [["property": "날짜", "direction": "ascending"]]])
            async let cwllRaw = api.query(db: cfg.cwllDB, body: ["page_size": 8, "sorts": [["property": "Date", "direction": "descending"]]])
            // 전부(15행) — 카드는 앞 recentMinutesCount 만, 자료 지도 '회의록' 열은 같은 날짜 전부를 본다 (0.40.0 C6)
            async let minRaw = api.query(db: cfg.meetingNotesDB, body: [
                "page_size": 100,
                "filter": ["property": "Title", "title": ["is_not_empty": true]],
                "sorts": [["property": "Date", "direction": "descending"]]])
            // 선택 섹션: DB 가 없거나 공유되지 않았으면 비워 둔다 (전체 갱신을 막지 않음)
            async let confRaw = cfg.conferencesDB.isEmpty ? [] : ((try? await api.query(db: cfg.conferencesDB, body: [
                "page_size": 20,
                "filter": ["property": "Date", "date": ["on_or_after": twoWeeksAgo]],
                "sorts": [["property": "Date", "direction": "ascending"]]])) ?? [])
            async let paperRaw = paperQuery(api)
            async let projRaw = cfg.projectsDB.isEmpty ? [] : ((try? await api.query(db: cfg.projectsDB, body: [
                "page_size": 100,
                "filter": ["or": [["property": "상태", "status": ["equals": "In Progress"]], ["property": "상태", "status": ["equals": "Review"]]]]])) ?? [])
            async let slabRaw = cfg.slabDB.isEmpty ? [] : ((try? await api.query(db: cfg.slabDB, body: slabAll
                ? ["page_size": 100, "sorts": [["property": "실험날짜", "direction": "descending"]]]
                : ["page_size": 20,
                   "filter": ["property": "실험날짜", "date": ["equals": todayS]],
                   "sorts": [["property": "시간", "direction": "ascending"]]], maxPages: slabAll ? 10 : 3)) ?? [])
            // 장비 예약 (0.40.0 C5, A5) — Canceled 아님 · 시작 ≤ 오늘+14, 최근 순 100행(33행, 1쪽). 앱이 다시 거른다(EquipmentBoard.window).
            // nil = 조회 실패·DB 없음 — '닫기 누락' 실측을 0 으로 오인하지 않게
            async let resourceRaw: [[String: Any]]? = cfg.resourceDB.isEmpty ? nil : (try? await api.query(db: cfg.resourceDB, body: [
                "page_size": 100,
                "filter": ["and": [["property": "Status", "status": ["does_not_equal": "Canceled"]], ["property": "date", "date": ["on_or_before": twoWeeksAhead]]]],
                "sorts": [["property": "date", "direction": "descending"]]]))
            let (m, g, n, e) = try await (membersRaw, grmRaw, notesRaw, eventsRaw)
            let (cw, mn) = try await (cwllRaw, minRaw)
            let (cf, pr) = await (confRaw, paperRaw)
            let (sl, rm) = await (slabRaw, resourceRaw)
            let pj = await projRaw
            // 담당자 relation 은 별도 사람 DB(제목 = 이니셜)를 가리킨다 → id → 이니셜. SLab '실험자' relation 도 같은 DB (0.40.0 C1, F0-1)
            var peopleInit: [String: String] = [:]
            if !cfg.projectPeopleDB.isEmpty, let ppl = try? await api.query(db: cfg.projectPeopleDB, body: ["page_size": 100]) {
                for p in ppl { if let id = p["id"] as? String { peopleInit[id.replacingOccurrences(of: "-", with: "")] = NotionAPI.title(p).trimmingCharacters(in: .whitespaces).uppercased() } }
            }
            // 갱신 본체의 질의는 여기까지 (members·grm·notes·events·cwll·minutes·conferences·paperRec(+폴백)·projects·slab·resource·projectPeople)
            NotionQueryStats.settle()
            // 멤버를 먼저 — SLab 실험자·자원 예약자 이니셜이 이번 갱신의 Members 로 풀리게 (첫 갱신에서 빈 목록으로 모두 '외부' 가 되지 않게)
            members = m.map { p in
                Member(id: p["id"] as? String ?? UUID().uuidString, name: NotionAPI.title(p),
                       initials: NotionAPI.text(p, "Initials"), email: NotionAPI.text(p, "Email"),
                       active: NotionAPI.bool(p, "Active"), order: Int(NotionAPI.number(p, "Rotation order") ?? 99))
            }.sorted { $0.order < $1.order }
            projects = pj.compactMap { p in
                let name = NotionAPI.title(p).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, NotionAPI.text(p, "분류") != "Lab Chore" else { return nil }
                let ids = NotionAPI.relationIDs(p, "담당자")
                return ProjectRow(id: p["id"] as? String ?? UUID().uuidString, name: name, status: NotionAPI.text(p, "상태"), memberIDs: ids,
                                  initials: ids.compactMap { peopleInit[$0.replacingOccurrences(of: "-", with: "")] })
            }
            conferences = cf.compactMap { p in
                guard let d = NotionAPI.dateRange(p, "Date") else { return nil }
                let endDay = Calendar.current.startOfDay(for: d.end ?? d.start)
                guard endDay >= today else { return nil }
                return ConferenceRow(id: p["id"] as? String ?? UUID().uuidString, title: NotionAPI.title(p).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression),
                                     conference: NotionAPI.text(p, "Conference"), start: Calendar.current.startOfDay(for: d.start), end: d.end.map { Calendar.current.startOfDay(for: $0) },
                                     location: NotionAPI.text(p, "Location"), format: NotionAPI.text(p, "Format"),
                                     authors: NotionAPI.text(p, "Authors"), international: NotionAPI.bool(p, "International"))
            }
            papers = pr.map { p in
                // 제목 끝 hash·저자 'Unknown' 은 표시에서만 걷어 낸다 — Notion 원값은 그대로 (R-31, 0.36.0)
                PaperRec(id: p["id"] as? String ?? UUID().uuidString, title: Hub.cleanPaperTitle(NotionAPI.title(p)),
                         authors: Hub.cleanAuthors(NotionAPI.text(p, "저자")), tier: NotionAPI.text(p, "Tier"), researcher: NotionAPI.text(p, "Researcher"),
                         doi: URL(string: NotionAPI.text(p, "DOI")),
                         recommendation: Hub.noEmoji(NotionAPI.text(p, "Recommendation")).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression),
                         presentPlanned: NotionAPI.bool(p, "발표 예정"), sentAt: NotionAPI.date(p, "Sent At")?.date)
            }.filter { !$0.title.isEmpty }
            if !light || paperCommentsAt.map({ Date().timeIntervalSince($0) >= Self.commentsTTL }) ?? true {
                settleWaits.insert("comments")
                Task { @MainActor [weak self] in await self?.loadPaperComments(); self?.settleDone("comments") }
            }
            cwll = cw.map { p in LinkRow(id: p["id"] as? String ?? UUID().uuidString, name: NotionAPI.title(p), url: URL(string: NotionAPI.text(p, "URL")), date: NotionAPI.date(p, "Date")?.date) }
            minutes = mn.map { p in
                MeetingNote(id: p["id"] as? String ?? UUID().uuidString, title: NotionAPI.title(p), date: NotionAPI.date(p, "Date")?.date,
                            summary: NotionAPI.text(p, "Summary"), decisions: NotionAPI.text(p, "Key Decisions"),
                            recording: URL(string: NotionAPI.text(p, "Recording URL")), status: NotionAPI.text(p, "Status"), type: NotionAPI.text(p, "Type"),
                            magazine: NotionAPI.date(p, "Date").flatMap { Self.magazineURL(dir: cfg.magazineDir, date: $0.date) },
                            speakers: NotionAPI.text(p, "Speakers"), sourceFile: NotionAPI.text(p, "Source File"))
            }.filter { $0.type != "Other" }
            minuteDaysAll = GRMMap.minuteDays(mn.map { p in (NotionAPI.text(p, "Type"), NotionAPI.title(p), NotionAPI.date(p, "Date")?.date) })
            loadHighlights()
            loadMinutesPending()

            // 오늘의 실험 — SLab 실험자는 '실험자' relation 으로만 (0.40.0 C1, F0-1: 피험자 이름·ID 를 읽지 않는다)
            let pool = members, aliases = cfg.initialsAliases
            let canonical: (String) -> String? = { raw in
                let ini = (aliases[raw] ?? raw).uppercased()
                return pool.first { !$0.initials.isEmpty && $0.initials.uppercased() == ini }?.initials
            }
            let ex: [ExperimentRow] = sl.compactMap { Self.slabRow($0, people: peopleInit, canonical: canonical) }
            // 장비 예약은 오늘의 실험에 넣지 않고 장비 카드로 (0.40.0 C5 — 예전 '자원' Running 줄과 (끝 ?? 시작) ≥ 오늘 guard(F0-2)를 대체)
            if let rm {
                let all = rm.compactMap { EquipmentBoard.parse($0, owner: { self.ownerInitials(raw: $0) }) }
                equipmentMachines = EquipmentBoard.machines(all)
                equipment = EquipmentBoard.window(all, today: today)
                equipmentReceived = all.count
                equipmentLatestStart = all.map { Calendar.current.startOfDay(for: $0.start) }.filter { $0 <= today }.max()
                equipmentLoaded = true
            } else {
                equipmentLoaded = false
            }
            // Prolific 행은 loadProlific 이 30분에 한 번만 다시 채운다 — 여기서 통째로 바꾸면 팝오버를 열 때마다
            // Prolific 진행·준비 중 연구가 최대 30분 사라졌다 (0.37.0 리뷰 2). 지난 Prolific 행(정렬된 채, id 'prolific-' 접두라 겹치지 않음)을 뒤에 그대로 붙인다
            experiments = ex + experiments.filter { $0.source == "Prolific" }
            grmAll = g.compactMap { p in
                guard let d = NotionAPI.date(p, "날짜") else { return nil }
                let doc = NotionAPI.text(p, "Contents")
                return GRMSlot(id: p["id"] as? String ?? UUID().uuidString, date: Calendar.current.startOfDay(for: d.date),
                               presenters: NotionAPI.text(p, "발표자 이름"), type: NotionAPI.text(p, "Type"),
                               notified: NotionAPI.bool(p, "공지 발송"), abstractDone: NotionAPI.bool(p, "Abstract 완료"),
                               docURL: doc.isEmpty ? nil : URL(string: doc), noteIDs: NotionAPI.relationIDs(p, "Meeting Notes"))
            }
            let since = Calendar.current.startOfDay(for: weekAgoDate)
            grm = grmAll.filter { $0.date >= since }
            notes = n.map { p in
                Presentation(id: p["id"] as? String ?? UUID().uuidString, title: NotionAPI.title(p),
                             date: NotionAPI.date(p, "날짜")?.date, status: NotionAPI.text(p, "상태"),
                             type: NotionAPI.text(p, "유형"), slidePath: NotionAPI.text(p, "슬라이드 경로"))
            }
            events = e.compactMap { p in
                guard let d = NotionAPI.date(p, "날짜") else { return nil }
                return EventRow(id: p["id"] as? String ?? UUID().uuidString, title: NotionAPI.title(p).trimmingCharacters(in: .whitespaces),
                                date: d.date, hasTime: d.hasTime, type: NotionAPI.text(p, "Type"),
                                status: NotionAPI.text(p, "상태"))
            }
            error = nil
            lastUpdated = Date()
        } catch {
            self.error = error.localizedDescription
        }
        // Paper Blitz 는 NAS·Crossref 를 타므로 따로 돈다 (Notion 섹션을 막지 않게)
        if !light, !blitzLoading { settleWaits.insert("blitz"); Task { @MainActor [weak self] in await self?.loadBlitz(); self?.settleDone("blitz") } }
        settleWaits.formUnion(["prolific", "preprints"])
        Task { @MainActor [weak self] in await self?.loadProlific(); self?.settleDone("prolific") }
        Task { @MainActor [weak self] in await self?.loadPreprints(); self?.settleDone("preprints") }
        let gf = cfg.grantsFile
        grants = await Task.detached(priority: .utility) { GrantsFile.load(gf) }.value
        let rp = remindersPath
        switch await Task.detached(priority: .utility, operation: { RemindersFile.load(rp) }).value {
        case .ok(let items): reminders = items; remindersLocked = nil; remindersLoadedOK = true
        case .missing: reminders = []; remindersLocked = nil; remindersLoadedOK = false
        case .corrupt(let why): remindersLocked = why       // 이전 목록은 그대로 보이고 버튼만 잠근다
        }
        // 미팅 후속 (0.41.0 C2) — 리마인더 읽기 바로 뒤, 같은 NAS 폴더
        await loadFollowups()
        let mf = ((gf as NSString).deletingLastPathComponent as NSString).appendingPathComponent("member_links.json")
        memberLinks = await Task.detached(priority: .utility) { MemberLinks.load(mf) }.value
        // 다가오는 학회: Notion Conferences + NAS conferences_upcoming.json (#7). 접수 중인 마감이 가까운 순 → 개최일 순
        let cfPath = ((gf as NSString).deletingLastPathComponent as NSString).appendingPathComponent("conferences_upcoming.json")
        let fileConfs = await Task.detached(priority: .utility) { ConferencesFile.load(cfPath) }.value
        conferencesGenerated = await Task.detached(priority: .utility) { ConferencesFile.generated(cfPath) }.value
        let t0 = today
        let notionNames = Set(conferences.filter { $0.link == nil }.map { $0.conference.lowercased() })
        conferences = (conferences.filter { $0.link == nil } + fileConfs.filter { !notionNames.contains($0.conference.lowercased()) })
            .filter { ($0.end ?? $0.start) >= t0 }
            .sorted { a, b in
                let da = a.deadline.flatMap { $0 >= t0 ? $0 : nil }, db = b.deadline.flatMap { $0 >= t0 ? $0 : nil }
                switch (da, db) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.start < b.start
                }
            }
        // 학회 관심 (0.37.0 C5) — 학회 합치기 뒤에 다시 읽는다(다른 맥의 체크도 다음 갱신에)
        await loadInterest()
        // Members 현황판 Milestone 열 (0.37.0 C7) — NAS MM 폴더 읽기만
        await loadMilestones()
        // 일일 집계 (0.40.0 C2) — 이 맥의 latest.json 읽기만
        await loadMetrics()
        // 시간표 (0.42.0 C4) — 학기 안일 때만, 6시간 캐시
        await loadCourses(api)
        // 멤버 상태 (0.42.0 C5) — 캘린더·Notion·SLab·수업·away 가 다 온 뒤 한 번
        updateMemberStatus()
        // Joint projects (0.42.0 C6) — NAS plugins/plugin_status.json 읽기만
        await loadJointProjects()
        // GRM 회차 자료 지도 (0.40.0 C6) — NAS 목록은 기다리지 않는다('다 옴'·첫 그림을 늦추지 않게)
        loadGRMMap()
        // 여기까지가 갱신 본체. 따로 띄운 로더가 남았으면 그것들이 끝날 때, 아니면 지금 '다 옴'
        if settleWaits.isEmpty { markSettled() }
        else {
            settleGen += 1
            let gen = settleGen
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, self.settleGen == gen, !self.settleWaits.isEmpty else { return }
                self.settleWaits.removeAll()
                self.markSettled()
            }
        }
    }

    /// 따로 띄운 로더 하나가 끝남 — 갱신 본체가 끝났고(loading=false) 남은 것이 없으면 '다 옴'
    private func settleDone(_ name: String) {
        guard settleWaits.remove(name) != nil else { return }
        if settleWaits.isEmpty, !loading { markSettled() }
    }

    private func markSettled() {
        settledDay = HubClock.today
        settledAt = Date()
        // '내 것' 배지 — 데이터가 다 온 뒤에만 (부분 데이터로 기준선을 만들지 않게, 0.40.0 C4)
        SeenCards.shared.update(self)
    }

    /// 논문 추천: "Sent At" 최신순 (속성이 없는 DB 면 생성 시각 순)
    private func paperQuery(_ api: NotionAPI) async -> [[String: Any]] {
        guard !cfg.paperRecDB.isEmpty else { return [] }
        // 사람별 필터·티어 정렬은 카드에서 (#16) — 그래서 최근 100편을 다 받는다
        if let r = try? await api.query(db: cfg.paperRecDB, body: ["page_size": 100, "sorts": [["property": "Sent At", "direction": "descending"]]]) { return r }
        return (try? await api.query(db: cfg.paperRecDB, body: ["page_size": 100, "sorts": [["timestamp": "created_time", "direction": "descending"]]])) ?? []
    }

    /// 멤버 칩 줄과 팝오버 '진행 프로젝트'가 같이 쓰는 member_links.json 항목 (R-32, 0.36.0) — 이니셜 → initialsAliases → 이름 순으로 찾는다
    func memberLinkEntry(for m: Member) -> MemberLinks.Entry? {
        let L = memberLinks
        for k in [m.initials, cfg.initialsAliases[m.initials] ?? ""] where !k.isEmpty { if let e = L.members[k] { return e } }
        return L.members.first { $0.value.name == m.name }?.value
    }
    /// 칩과 같은 소스·같은 순서(폴더 수정 시각 최신순)의 진행 프로젝트 — NAS Memory/<이니셜> 폴더 (R-32)
    func chipProjects(for m: Member) -> [MemberLinks.Project] { memberLinkEntry(for: m)?.projects ?? [] }

    /// 멤버가 담당자인 진행 프로젝트 (Notion Projects — '나' 뷰·관제탑 멤버 레일. 팝오버는 chipProjects, 결정 D1·D2)
    func projects(for m: Member) -> [ProjectRow] {
        let key = m.id.replacingOccurrences(of: "-", with: "")
        let ini = (cfg.initialsAliases[m.initials] ?? m.initials).uppercased()
        return projects.filter { p in
            p.memberIDs.contains { $0.replacingOccurrences(of: "-", with: "") == key }
                || (!ini.isEmpty && p.initials.contains { (cfg.initialsAliases[$0] ?? $0).uppercased() == ini })
        }
    }

    /// 논문 추천 각 페이지의 댓글(반응 포함). 실패한 페이지(429·일시 오류)는 이전 값을 유지한다 — 통째로 바꾸면 반응 배지·'반응 n/10' 이 0 으로 꺼진다 (검증 1)
    /// 드라이런 훅(DESKHUB_NOTION_WRITE=dry:<경로>)이면 그 파일 줄을 페이지별로 합쳐 다시 settle — 재시작해도 남는다 (0.39.0 C5)
    func loadPaperComments() async {
        let dry = NotionDryRun.path
        guard let api else {
            // 훅이면 api 가드를 건너뛴다 — Notion 없이 드라이런 줄만
            if let dry {
                let d = NotionDryRun.comments(path: dry)
                var next = paperComments
                for id in papers.map(\.id) { if let cs = d[id] { next[id] = NotionDryRun.merge(next[id] ?? [], cs) } }
                paperComments = next
                paperCommentsReadAt = Date()
            }
            return
        }
        paperCommentsAt = Date()
        let ids = papers.map(\.id)
        var out: [String: [PaperComment]] = [:]
        await withTaskGroup(of: (String, [PaperComment]?).self) { g in
            for id in ids { g.addTask { (id, try? await api.comments(page: id)) } }
            for await (id, cs) in g { if let cs { out[id] = cs } }
        }
        // 지금 목록의 논문만 남기고, 이번에 못 읽은 페이지는 이전 값 그대로 (그 사이 addPaperComment 로 바뀐 값도 보존)
        let prev = paperComments
        var next: [String: [PaperComment]] = [:]
        for id in ids { if let cs = out[id] ?? prev[id] { next[id] = cs } }
        if let dry {
            let d = NotionDryRun.comments(path: dry)
            for id in ids { if let cs = d[id] { next[id] = NotionDryRun.merge(next[id] ?? [], cs) } }
        }
        paperComments = next
        if !out.isEmpty || ids.isEmpty { paperCommentsReadAt = Date() }
    }

    /// 반응·댓글 남기기 — Notion 댓글로 "[이니셜] 내용". 드라이런 훅이면 POST 대신 파일에 한 줄(모든 반응·댓글·'같이 읽자' 쓰기가 여기로)
    func addPaperComment(page: String, text: String) async {
        if let dry = NotionDryRun.path {
            do { try NotionDryRun.append(page: page, text: text, path: dry) }
            catch { self.error = "반응·댓글 저장 실패(드라이런): \(error.localizedDescription)"; return }
            paperComments[page] = NotionDryRun.merge(paperComments[page] ?? [], NotionDryRun.comments(path: dry)[page] ?? [])
            return
        }
        guard let api else { return }
        do {
            try await api.addComment(page: page, text: text)
            if let cs = try? await api.comments(page: page) { paperComments[page] = cs }
        } catch { self.error = "반응·댓글 저장 실패: \(error.localizedDescription)" }
    }

    /// '같이 읽자' 대기 id — 단추·덤프·--key talk-undo 가 같은 값
    static func talkID(_ p: PaperRec) -> String { "talk-" + p.id }

    /// '같이 읽자' 단추·--key talk:<제목 일부> (0.39.0 C5) — 이니셜 미확인이면 아무것도 안 함(단추 쪽이 이니셜 고르기를 연다).
    /// 대기 중이면 되돌리기, 아니면 내 제안이 살아 있는지 보고 '[me] 같이 읽자' / '[me] ✖같이 읽자' 를 6초 뒤 남긴다
    func toggleTalk(_ p: PaperRec) {
        let me = HubPrefs.me.uppercased()
        guard !me.isEmpty, HubPrefs.meChosen else { return }
        let id = Self.talkID(p)
        if talkCommits.isPending(id) { talkCommits.undo(id); return }
        let mine = PaperComment.proposers(paperComments[p.id] ?? []).contains(me)
        let text = "[\(me)] " + (mine ? HubPrefs.cancelMark : "") + HubPrefs.talkText
        UsageLog.action("talk")
        talkCommits.schedule(id: id, label: String(p.title.prefix(28)) + " · " + (mine ? "같이 읽자 취소" : "같이 읽자")) { [weak self] in
            Task { @MainActor [weak self] in await self?.addPaperComment(page: p.id, text: text) }
        }
    }

    /// 최신 원고 — OpenAlex 는 하루에 한 번
    func loadPreprints() async {
        guard !cfg.manuscriptAuthors.isEmpty else { return }
        if let t = preprintsFetchedAt, Date().timeIntervalSince(t) < 12 * 3600, !preprints.isEmpty { return }
        preprintsLoading = true
        let rows = await OpenAlex.latest(authors: cfg.manuscriptAuthors, days: cfg.manuscriptLookbackDays)
        preprintsLoading = false
        if !rows.isEmpty { preprints = rows; preprintsFetchedAt = Date() }
    }

    /// 분야 최근 이슈 받기 (0.39.0 C2) — 캐시를 먼저 보이고, 성공 뒤 12시간(받을 날이 오늘·어제뿐이거나 지난 받기가 빠진 날을 못 채웠을 때)·
    /// 실패 뒤 1시간 안에는 다시 받지 않는다. 호출 상한(10)에 걸려 빠진 날이 남으면 다음 갱신(10분)에서 오늘·어제와 빠진 날만 이어 받는다 (검증 1).
    /// 실패해도 목록은 그대로 두고 feedNote. 픽스처 훅은 한 세션에 한 번, 호출 0
    func loadFeed() async {
        guard !feedLoading else { return }
        let env = ProcessInfo.processInfo.environment
        let cacheURL = FeedCache.url
        let today = HubClock.today
        if !feedCacheRead {
            feedCacheRead = true
            if let u = cacheURL, let c = FeedCache.load(u) {
                feed = BioRxivFeed.sorted(c.items.filter { $0.version == "1" })
                feedFetchedDays = c.fetchedDays; feedOKAt = c.okAt; feedTriedAt = c.triedAt
                if !c.items.isEmpty || c.okAt != nil { feedOrigin = "cache" }
                if let t = c.triedAt, t > (c.okAt ?? .distantPast) { feedNote = Self.feedFailNote(c.okAt) }
            }
        }
        if let fx = env["DESKHUB_FEED_FIXTURE"], !fx.isEmpty {
            guard feedOrigin != "fixture" else { return }
            guard let r = BioRxivFeed.fixture(path: fx) else { feedError = "픽스처를 읽지 못함 — \(fx)"; feedNote = Self.feedFailNote(feedOKAt); return }
            applyFeed(r, cacheURL: cacheURL, today: today, origin: "fixture")
            return
        }
        let days = BioRxivFeed.daysToFetch(today: today, fetched: Set(feedFetchedDays))
        let missing = days.filter { BioRxivFeed.isSettled($0, today: today) }
        let now = Date()
        if let ok = feedOKAt, now.timeIntervalSince(ok) < 12 * 3600, missing.isEmpty || feedStalled { return }
        if let t = feedTriedAt, t > (feedOKAt ?? .distantPast), now.timeIntervalSince(t) < 3600 { return }
        feedLoading = true
        let r: BioRxivFeed.Result
        if env["DESKHUB_FEED_SIM"] == "offline" {
            r = BioRxivFeed.Result(error: "시험(DESKHUB_FEED_SIM=offline)")
        } else {
            r = await BioRxivFeed.fetch(days: days)
            feedRuns += 1
        }
        feedLoading = false
        feedStalled = r.error == nil && !missing.isEmpty && Set(r.completedDays).isDisjoint(with: missing)
        applyFeed(r, cacheURL: cacheURL, today: today, origin: "network")
    }

    /// 받은 결과를 합친다 — v1 만·DOI 병합·14일 지난 것 지움, 다 받은 날 기록(오늘·어제 제외 = 확정된 날만), 캐시(있으면) atomic 쓰기
    private func applyFeed(_ r: BioRxivFeed.Result, cacheURL: URL?, today: Date, origin: String) {
        let now = Date()
        feedLastCalls = r.calls
        feedTriedAt = now
        let cut = FeedCache.cutoff(today: today)
        if !r.items.isEmpty { feed = BioRxivFeed.merge(feed, r.items).filter { $0.date >= cut } }
        // 오늘·어제는 끝까지 받아도 확정하지 않는다 — 다음 갱신에서 다시 받고 DOI 병합으로 중복 없음 (리뷰 2)
        feedFetchedDays = BioRxivFeed.settled(Array(Set(feedFetchedDays).union(r.completedDays)), today: today).filter { $0 >= cut }.sorted(by: >)
        if let e = r.error {
            feedError = e
            feedNote = Self.feedFailNote(feedOKAt)
            if !r.items.isEmpty { feedOrigin = origin }
        } else {
            feedOKAt = now; feedNote = nil; feedError = nil; feedOrigin = origin
        }
        if let u = cacheURL {
            FeedCache.save(FeedCacheFile(okAt: feedOKAt, triedAt: feedTriedAt, fetchedDays: feedFetchedDays, items: feed), to: u, today: today)
        }
    }

    /// 'bioRxiv 받기 실패 — 아래는 마지막 갱신 M.d HH:mm 결과' (받은 적 없으면 '연결되면 자동으로 다시 받습니다')
    static func feedFailNote(_ ok: Date?) -> String {
        guard let ok else { return "bioRxiv 받기 실패 — 연결되면 자동으로 다시 받습니다" }
        let f = DateFormatter(); f.dateFormat = "M.d HH:mm"
        return "bioRxiv 받기 실패 — 아래는 마지막 갱신 \(f.string(from: ok)) 결과"
    }

    /// 저자 relation id → 이니셜
    func initials(forMemberIDs ids: [String]) -> [String] {
        ids.compactMap { id in members.first { $0.id.replacingOccurrences(of: "-", with: "") == id.replacingOccurrences(of: "-", with: "") }?.initials }
    }

    // MARK: Prolific (진행·준비 중 study)
    private var prolificFetchedAt: Date?
    func loadProlific() async {
        // 테스트 훅 (0.36.0, R-L2 검증) — DESKHUB_PROLIFIC_SIM=notoken|error 면 네트워크 없이 그 경우의 note 를 세운다. 기본은 꺼짐
        let sim = ProcessInfo.processInfo.environment["DESKHUB_PROLIFIC_SIM"] ?? ""
        if sim == "notoken" || sim == "error" {
            experiments.removeAll { $0.source == "Prolific" }
            prolificNote = sim == "notoken" ? "Prolific 미연결 — 이 맥에 토큰 없음 (\(prolific.tokenEnvKey))" : "Prolific 조회 실패: 시험(DESKHUB_PROLIFIC_SIM)"
            return
        }
        let studies: ProlificResult
        if sim.hasPrefix("fixture:") {
            // 테스트 훅 (0.37.0 C4) — DESKHUB_PROLIFIC_SIM=fixture:<json> 면 네트워크 없이 그 파일을 API 와 같은 파싱·같은 필터로
            let path = (String(sim.dropFirst("fixture:".count)) as NSString).expandingTildeInPath
            studies = await Task.detached(priority: .utility) { ProlificClient.fixture(path: path) }.value
        } else {
            guard prolific.enabled else { return }
            // 전체 study 목록(263개, 30초)이라 30분에 한 번만
            if let t = prolificFetchedAt, Date().timeIntervalSince(t) < 30 * 60 { return }
            prolificFetchedAt = Date()
            studies = await ProlificClient(credentialsFile: prolific.credentialsFile, envFile: cfg.tokenEnvFile, envKey: prolific.tokenEnvKey, workspaceID: prolific.workspaceID).studies()
        }
        switch studies {
        case .noToken:
            // 멤버 맥에 토큰을 어떻게 줄지는 랩장 결정 대기 (#17, 2026-10-14) — 그때까지 '미연결'로만 보인다
            prolificNote = "Prolific 미연결 — 이 맥에 토큰 없음 (\(prolific.tokenEnvKey))"
            experiments.removeAll { $0.source == "Prolific" }
        case .error(let e):
            // 지난 Prolific 행이 남아 있으면(행 보존, 0.37.0 리뷰 2) 그 행이 언제 결과인지 앞에 — 이유는 뒤(한 줄에서 잘려도 앞이 보이게) (0.38.0 C5)
            if let t = prolificOKAt, experiments.contains(where: { $0.source == "Prolific" }) {
                let f = DateFormatter(); f.dateFormat = "HH:mm"
                prolificNote = "Prolific 조회 실패 · 아래는 \(f.string(from: t)) 결과 — \(e)"
            } else {
                prolificNote = "Prolific 조회 실패: \(e)"
            }
        case .ok(let list):
            prolificNote = nil
            prolificOKAt = Date()
            prolificStudies = list
            experiments.removeAll { $0.source == "Prolific" }
            // 진행(ACTIVE)·준비(UNPUBLISHED) 중만 — 랩장 10-16 18:12 'Prolific은 현재 draft나 active인 것들로', 옛 PAUSED 실험(BYL 19/20) 제외.
            // config 의 prolific.showStatuses 는 읽지 않는다(Config.swift·config.json 그대로, 계획 0.37.0 §4-2). 전체 조회 폴백(studies/?limit=50)도 여기서 걸러진다
            var rows: [ExperimentRow] = []
            for st in list where ProlificFilter.keep(st.status) {
                // 코드 기본값(로스터와 맞춘 이름 → 이니셜)이 이긴다. 사용자 설정은 새 이름만 더할 수 있다
                // (예전 설정 파일에 남은 "Boyun Lee": "BHL" 같은 낡은 값이 덮어쓰지 못하게 — 이보연 BYL ≠ 이보현 BHL, 메타 리뷰 W1 2026-10-13)
                // 표에 없는 프로젝트 이름은 정확 일치만(ownerInitials, 0.40.0 C1) — 못 찾으면 '외부'(원문 이름을 owner 로 두지 않는다)
                let owner = (ProlificConfig().projectInitials.merging(prolific.projectInitials) { def, _ in def })[st.project] ?? ownerInitials(raw: st.project)
                rows.append(ExperimentRow(id: "prolific-" + st.id, source: "Prolific", title: st.name,
                                          detail: "\(st.submissions)/\(st.places) 제출" + (st.rewardPence > 0 ? String(format: " · £%.2f", Double(st.rewardPence) / 100) : ""),
                                          status: ProlificFilter.label(st.status), url: URL(string: "https://app.prolific.com/researcher/workspaces/studies/\(st.id)"), notionID: nil,
                                          owner: owner == "Project" ? "" : owner))
            }
            // 진행 중 → 준비 중 → 실험자 이니셜, 실험자 빈 행은 뒤로 (SLab·자원 행 뒤) — 빈 문자열이 맨 앞에 오지 않게 (0.37.0 검증 1)
            experiments += rows.sorted { a, b in
                let ra = ProlificFilter.rank(label: a.status), rb = ProlificFilter.rank(label: b.status)
                if ra != rb { return ra < rb }
                if a.owner.isEmpty != b.owner.isEmpty { return !a.owner.isEmpty }
                return a.owner < b.owner
            }
        }
    }

    // MARK: 지난 Paper Blitz
    /// config 가 비어 있으면 report 플러그인의 DB registry(~/.claude/csnl-report/notion_dbs.json) 의 "Paper Blitz Archive" 를 쓴다
    var paperBlitzDB: String {
        if !cfg.paperBlitzDB.isEmpty { return cfg.paperBlitzDB }
        let reg = (cfg.tokenEnvFile as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: reg).deletingLastPathComponent().appendingPathComponent("notion_dbs.json")
        if let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let id = o["Paper Blitz Archive"] as? String { return id }
        return ""
    }

    func loadBlitz() async {
        blitzLoading = true
        defer { blitzLoading = false }
        let blitzDB = paperBlitzDB
        if !blitzDB.isEmpty, let api {
            // 전부(53행) — 최신 회차는 아래에서 고르고, 모든 날짜는 자료 지도 PB 열에 (0.40.0 C6, 예전 40행)
            let rows = (try? await api.query(db: blitzDB, body: ["page_size": 100, "sorts": [["property": "Date", "direction": "descending"]]])) ?? []
            if !rows.isEmpty { blitzDates = Set(rows.compactMap { NotionAPI.date($0, "Date").map { Calendar.current.startOfDay(for: $0.date) } }) }
            let all: [(Date, BlitzPaper)] = rows.enumerated().compactMap { i, p in
                guard let d = NotionAPI.date(p, "Date") else { return nil }
                let title = NotionAPI.title(p)
                guard !title.isEmpty else { return nil }
                let yr = NotionAPI.number(p, "Year").map { Int($0) }
                return (Calendar.current.startOfDay(for: d.date),
                        BlitzPaper(id: p["id"] as? String ?? UUID().uuidString, title: title, presenter: NotionAPI.text(p, "Presenter"),
                                   citation: { let a = NotionAPI.text(p, "Authors"); let y = yr.map(String.init) ?? ""; let j = NotionAPI.text(p, "Journal")
                                               return [a, a.contains(y) ? "" : y, a.contains(j) ? "" : j].filter { !$0.isEmpty }.joined(separator: ", ") }(),
                                   year: yr, coreQuestion: NotionAPI.text(p, "Core question"), doi: URL(string: NotionAPI.text(p, "DOI")),
                                   notionID: p["id"] as? String, order: i))
            }
            if let latest = all.map(\.0).max() {
                // NAS 에 더 새 덱이 있으면 그쪽을 보인다 (Notion 은 수 22:00 에야 반영되므로 GRM 당일엔 지난주가 보였음)
                let root = cfg.nasGRMRoot
                let nas = cfg.paperBlitzFromNAS ? await Task.detached(priority: .utility) { PaperBlitzDeck.latestFile(root: root) }.value : nil
                if nas.map({ $0.date <= latest }) ?? true {
                    blitzDate = latest; blitz = all.filter { $0.0 == latest }.map(\.1); blitzSource = "Notion"; blitzNote = nil; blitzPending = false
                    return
                }
            }
        }
        guard cfg.paperBlitzFromNAS else { blitzNote = "Paper Blitz Archive DB 가 없고 NAS 읽기도 꺼져 있음"; return }
        let root = cfg.nasGRMRoot
        guard FileManager.default.fileExists(atPath: root) else { blitzNote = "NAS 가 연결되어 있지 않음 (\(root))"; blitz = []; return }
        let found = await Task.detached(priority: .utility) { PaperBlitzDeck.latest(root: root) }.value
        guard let found else { blitzNote = "최근 PB_yymmdd.pptx 를 찾지 못함"; blitz = []; return }
        blitzDate = found.date; blitzSource = found.path; blitz = found.papers; blitzNote = found.papers.isEmpty ? "pptx 에서 논문 제목 슬라이드를 찾지 못함" : nil
        blitzPending = !blitzDB.isEmpty
        // DOI 는 Crossref 로 병렬 조회 (캐시)
        let pending = found.papers.filter { $0.doi == nil }
        let resolved: [(String, URL)] = await withTaskGroup(of: (String, URL?).self) { group in
            var out: [(String, URL)] = []
            var it = pending.makeIterator()
            for _ in 0..<3 { if let p = it.next() { group.addTask { (p.id, await DOIResolver.shared.doi(forTitle: p.title)) } } }
            while let (id, u) = await group.next() {
                if let u { out.append((id, u)) }
                if let p = it.next() { group.addTask { (p.id, await DOIResolver.shared.doi(forTitle: p.title)) } }
            }
            return out
        }
        for (id, u) in resolved { if let i = blitz.firstIndex(where: { $0.id == id }) { blitz[i].doi = u } }
    }

    /// 리마인더 등록·끝남·아님 → NAS reminders.json (Notion 은 건드리지 않음)
    func setReminder(_ r: ReminderItem, status: String) {
        guard remindersLocked == nil else { error = "리마인더 파일이 손상돼 저장하지 않음: \(remindersPath)"; return }
        if status == "done" { UsageLog.action("done") }
        let f = ISO8601DateFormatter(); f.timeZone = .current
        // 누른 사람: 이 맥에서 고른 이니셜, 없으면 맥 사용자 이름 (공용 맥은 'CSNL' 로 남던 문제)
        var it = r; it.status = status; it.by = HubPrefs.me.isEmpty ? NSFullUserName() : HubPrefs.me; it.at = f.string(from: Date())
        withAnimation(.easeOut(duration: 0.6)) {
            if let i = reminders.firstIndex(where: { $0.id == r.id }) { reminders[i] = it } else { reminders.append(it) }
        }
        reminderSaveFailed = nil
        let path = remindersPath, item = it
        Task.detached(priority: .utility) {
            let ok = RemindersFile.upsert(item, to: path)
            if !ok { await MainActor.run { [weak self] in self?.error = "리마인더 저장 실패: \(path)"; self?.reminderSaveFailed = item; self?.reminderFailedFields = RemindersFile.statusFields } }
        }
    }

    /// 지난 리마인더 미루기 → NAS reminders.json 의 date·by·at 만 (status 는 그대로). Notion 은 건드리지 않는다 —
    /// Notion 출처 리마인더도 파일의 날짜만 바뀌므로 Notion 일정 날짜와 어긋날 수 있다(툴팁 '리마인더만')
    func snoozeReminder(_ r: ReminderItem, to day: Date) {
        guard remindersLocked == nil else { error = "리마인더 파일이 손상돼 저장하지 않음: \(remindersPath)"; return }
        UsageLog.action("snooze")
        let f = ISO8601DateFormatter(); f.timeZone = .current
        var it = r; it.date = RemindersFile.dayFormatter.string(from: day)
        it.by = HubPrefs.me.isEmpty ? NSFullUserName() : HubPrefs.me; it.at = f.string(from: Date())
        withAnimation(.easeOut(duration: 0.6)) {
            if let i = reminders.firstIndex(where: { $0.id == r.id }) { reminders[i] = it } else { reminders.append(it) }
        }
        reminderSaveFailed = nil
        let path = remindersPath, item = it
        Task.detached(priority: .utility) {
            let ok = RemindersFile.upsert(item, to: path, fields: RemindersFile.snoozeFields)
            if !ok { await MainActor.run { [weak self] in self?.error = "리마인더 저장 실패: \(path)"; self?.reminderSaveFailed = item; self?.reminderFailedFields = RemindersFile.snoozeFields } }
        }
    }
    /// 마지막 저장 실패가 어느 키를 쓰려 했는지 — '다시 시도' 가 같은 키로 (미루기 실패를 status 쓰기로 다시 하면 날짜가 빠진다)
    private var reminderFailedFields: Set<String> = RemindersFile.statusFields
    func retryReminderSave(_ f: ReminderItem) {
        if reminderFailedFields.contains("date"), let d = f.day { snoozeReminder(f, to: d) } else { setReminder(f, status: f.status) }
    }

    /// 회의록 핵심 결과를 NAS 녹취 JSON 에서 (메인 스레드 밖에서) 읽어 붙인다. 경로별로 기억해 10분 갱신마다 다시 읽지 않는다
    private var highlightCache: [String: [String]] = [:]
    func loadHighlights() {
        let jobs = minutes.compactMap { m -> (String, String)? in MinutesHighlights.path(fromSourceFile: m.sourceFile).map { (m.id, $0) } }
        let cached = highlightCache
        Task { @MainActor [weak self] in
            let found: [String: [String]] = await Task.detached(priority: .utility) {
                var out: [String: [String]] = [:]
                for (_, path) in jobs where cached[path] == nil { out[path] = MinutesHighlights.extract(path: path) }
                return out
            }.value
            guard let self else { return }
            self.highlightCache.merge(found) { _, n in n }
            for (id, path) in jobs { if let i = self.minutes.firstIndex(where: { $0.id == id }) { self.minutes[i].highlights = self.highlightCache[path] ?? [] } }
        }
    }
    /// NAS GRM/<yyyy>/<yyyymmdd>/transcript/GRM_transcript_*.json 중 Notion 회의록보다 새 날짜가 있으면 표시 (10분 넘게 안 바뀐 파일만 — 쓰는 중 제외)
    func loadMinutesPending() {
        let root = cfg.nasGRMRoot
        let latestNote = minutes.compactMap(\.date).max().map { Calendar.current.startOfDay(for: $0) } ?? .distantPast
        Task { @MainActor [weak self] in
            let found: Date? = await Task.detached(priority: .utility) {
                let fm = FileManager.default
                let f = DateFormatter(); f.dateFormat = "yyyyMMdd"
                let years = ((try? fm.contentsOfDirectory(atPath: root)) ?? []).filter { $0.count == 4 && Int($0) != nil }.sorted(by: >)
                for y in years.prefix(1) {
                    for d in ((try? fm.contentsOfDirectory(atPath: "\(root)/\(y)")) ?? []).filter({ $0.count == 8 }).sorted(by: >).prefix(3) {
                        guard let date = f.date(from: d), date > latestNote else { continue }
                        let dir = "\(root)/\(y)/\(d)/transcript"
                        let files = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("GRM_transcript_") && $0.hasSuffix(".json") }
                        let stable = files.contains { n in
                            let a = try? fm.attributesOfItem(atPath: "\(dir)/\(n)")
                            let m = [a?[.modificationDate] as? Date, a?[.creationDate] as? Date].compactMap { $0 }.max() ?? Date()
                            return Date().timeIntervalSince(m) > 600
                        }
                        if stable { return date }
                    }
                }
                return nil
            }.value
            self?.minutesPending = found
        }
    }

    /// 회의록 머리 줄: "발표자 이름 | 발표 제목" (제목은 날짜·종류·이니셜 접두와 " — 부제" 를 뗀다)
    func minutesHeader(_ m: MeetingNote) -> (who: String, title: String) {
        var t = m.title.replacingOccurrences(of: "^\\d{4}-\\d{2}-\\d{2}\\s*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^(GRM|Paper Blitz|Focus|Other|Meeting)\\s*[—–-]\\s*", with: "", options: .regularExpression)
        var who = ""
        if let r = t.range(of: "^[A-Z]{2,4}(\\s*[,/&]\\s*[A-Z]{2,4})*\\s*:\\s*", options: .regularExpression) {
            who = String(t[r]).replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces); t.removeSubrange(r)
        }
        if who.isEmpty { who = m.speakers }
        if let r = t.range(of: " — ") { t = String(t[..<r.lowerBound]) }
        // 이니셜 목록("JOP, SK")은 이름으로, 이름 목록("이상훈 교수님, 임재섭 박사님")은 쉼표로만 나눈다. 셋 이상이면 "첫 사람 외 n명"
        let initialsOnly = who.range(of: "^[A-Z]{2,4}([\\s,/&]+[A-Z]{2,4})*$", options: .regularExpression) != nil
        let tokens = who.split(whereSeparator: { initialsOnly ? ",/& ".contains($0) : ",/".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let names = tokens.map { s in member(initials: s)?.name ?? s }
        let label = names.count > 2 ? "\(names[0]) 외 \(names.count - 1)명" : names.joined(separator: "·")
        return (label, t.trimmingCharacters(in: .whitespaces))
    }

    // MARK: 동작
    func openInApp(id: String) { NotionLink.open(id: id) }
    func openSlides(for slot: GRMSlot) {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"
        let yr = Calendar.current.component(.year, from: slot.date)
        let dir = "\(cfg.nasGRMRoot)/\(yr)/\(f.string(from: slot.date))"
        if FileManager.default.fileExists(atPath: dir) { NSWorkspace.shared.open(URL(fileURLWithPath: dir)) }
        else if FileManager.default.fileExists(atPath: cfg.nasGRMRoot) { NSWorkspace.shared.open(URL(fileURLWithPath: cfg.nasGRMRoot)) }
        else { error = "NAS 가 연결되어 있지 않습니다 (\(cfg.nasGRMRoot))" }
    }
}

// MARK: - 색/서식

/// 색은 세 가지뿐: 네이비(ink, Cell) · 녹색(ok, Nature) · 적색(signal, Science). 나머지는 무채색.
enum Hub {
    /// 데이터에 섞여 온 이모지(❓🔑💡 등)를 글자 라벨로 — 이모지는 테마 색을 안 따르고 적색 검사(lint_signal)에 잡힌다 (N2, 적색 ≤3)
    static func noEmoji(_ t: String) -> String {
        var out = t.replacingOccurrences(of: "❓ 핵심 질문:", with: "질문 ·").replacingOccurrences(of: "🔑 주요 발견:", with: "발견 ·")
            .replacingOccurrences(of: "❓", with: "Q").replacingOccurrences(of: "🔑", with: "·")
        out = String(out.unicodeScalars.filter { !($0.properties.isEmojiPresentation && $0.value > 0x2000) })
        return out.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }
    /// "0.26.0 (7b56fa5)" — build.sh 가 Info.plist 에 새긴 값
    static var buildLabel: String {
        let i = Bundle.main.infoDictionary ?? [:]
        let v = i["CFBundleShortVersionString"] as? String ?? "?", b = i["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))" + ((i["DeskHubBuilt"] as? String).map { " · " + $0 } ?? "")
    }
    static func dyn(_ light: NSColor, _ dark: NSColor) -> Color { Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }) }
    // 토큰은 테마(Theme.swift, themes.json)에서 — 대비는 scripts/build_themes.py 가 검사 (text ≥ 7, text2·강조색 ≥ 4.5, text3 ≥ 3)
    static var ink: Color { Theme.color(\.ink) }
    static var ok: Color { Theme.color(\.ok) }
    static var signal: Color { Theme.color(\.signal) }
    static var surface: Color { Theme.color(\.surface) }
    static var heroBG: Color { Theme.color(\.heroBG) }
    /// ink/signal 채움 위의 글자
    static var onAccent: Color { Theme.color(\.onAccent) }
    /// 글자 3단계
    static var text: Color { Theme.color(\.text) }
    static var text2: Color { Theme.color(\.text2) }
    static var text3: Color { Theme.color(\.text3) }
    static var divider: Color { Theme.color(\.divider) }
    static var fillNeutral: Color { Theme.color(\.fillNeutral) }

    /// 날짜 옆 요일 표시 여부 (config notionHub.display.showWeekday)
    static var showWeekday = false
    static func day(_ d: Date) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = showWeekday ? "M.d (E)" : "M.d"; return f.string(from: d) }
    /// 기간: 같은 달이면 "11.15–19", 다르면 "11.30–12.2"
    static func range(_ a: Date, _ b: Date?) -> String {
        guard let b, !Calendar.current.isDate(a, inSameDayAs: b) else { return day(a) }
        let f = DateFormatter(); f.dateFormat = "M.d"
        let g = DateFormatter(); g.dateFormat = Calendar.current.isDate(a, equalTo: b, toGranularity: .month) ? "d" : "M.d"
        return f.string(from: a) + "–" + g.string(from: b)
    }
    static var dateColumn: CGFloat { showWeekday ? 66 : 44 }
    /// 논문 추천 제목 (R-31, 0.36.0): HTML 태그를 지우고, 끝에 붙은 ' <6자 소문자 hex>' 조각을 뗀다 — 숫자가 하나 이상 섞인 것만
    /// ('… decade'·'… facade' 같은 영단어 끝을 지키려고). 대문자 hex 와 숫자 없는 hash 는 남는다 (결정 D6). --text-check 의 title 줄
    static func cleanPaperTitle(_ raw: String) -> String {
        raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+(?=[0-9a-f]{0,5}[0-9])[0-9a-f]{6}$", with: "", options: .regularExpression)
    }
    /// 논문 추천 저자 (R-31, 0.36.0): 앞쪽의 빈 토큰과 'Unknown' 토큰(대소문자 무시, 낱말 단위)만 반복해서 걷어 낸다. 전부 Unknown 이면 "".
    /// 쉼표로 쪼개 다시 잇지 않는다 — 'Kira, S.' 같은 성·이니셜 쌍이 깨지므로. 'Unknownson' 은 그대로. --text-check 의 authors 줄
    static func cleanAuthors(_ raw: String) -> String {
        let t = raw.replacingOccurrences(of: "^(?:\\s*(?:unknown)?\\s*[,;&])+\\s*", with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t.range(of: "^unknown[\\s,;&]*$", options: [.regularExpression, .caseInsensitive]) != nil ? "" : t
    }
    // MARK: Paper Blitz 인용 줄 (R-30, 0.36.0) — '성, 연도, 저널' 셋 다 확신할 때만 정리하고, 아니면 원문 한 줄
    /// 정리 결과 또는 nil(확신 없음). 게이트 셋: ① 성(성 먼저 한 낱말 / 이름 먼저 2–4 낱말의 끝) ② 연도 ③ 저널(APA 꼴 연도 뒤 문장, Nature 꼴은 알려진 저널만).
    /// 추정 폴백(쉼표 조각 중 가장 긴 것)은 두지 않는다 — 틀린 정리보다 원문이 낫다. --text-check 의 cite 줄
    static func citationParts(_ raw: String, year: Int?, title: String = "") -> String? {
        let t = collapseSpaces(raw)
        guard !t.isEmpty, let sur = citationSurname(t) else { return nil }
        let yr: String
        if let y = year { yr = String(y) }
        else if let m = t.range(of: "\\b(19|20)\\d{2}[a-z]?\\b", options: .regularExpression) { yr = String(t[m]) }
        else { return nil }
        guard let j = citationJournal(t, year: yr, title: title) else { return nil }
        return "\(sur), \(yr), \(abbreviateJournal(j))"
    }
    /// 화면에 그리는 인용 한 줄 — 정리되면 (정리, true), 아니면 (원문 공백 정리, false). 빈 원문은 "" (줄 숨김)
    static func citationLine(_ p: BlitzPaper) -> (text: String, normalized: Bool) { citationLine(p.citation, year: p.year, title: p.title) }
    static func citationLine(_ raw: String, year: Int?, title: String = "") -> (text: String, normalized: Bool) {
        if let s = citationParts(raw, year: year, title: title) { return (s, true) }
        return (collapseSpaces(raw), false)
    }
    static func collapseSpaces(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func rx(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }
    /// 문장 나눔 — 소문자 세 글자 뒤의 . ? ! 에서만 ('J.'·'Nat.' 같은 약어에서는 끊지 않는다)
    private static func sentences(_ s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "(?<=[a-z]{3}[.?!])\\s+") else { return [s] }
        let ns = s as NSString
        var out: [String] = [], from = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: from, length: m.range.location - from))); from = m.range.location + m.range.length
        }
        out.append(ns.substring(from: from))
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private static let surnameParticles: Set<String> = ["van", "von", "de", "der", "den", "la", "le", "di", "da", "du", "del", "dos"]
    /// 게이트 ① 첫 저자 성. F = 첫 , ; ( 앞 조각(끝 'et al.' 제거)
    ///   (a) 성 먼저 — F 가 대문자로 시작하는 한 낱말(앞 소문자 접두 van·de … 허용)이고 다음 조각이 이니셜·&·and·연도·et al. 이면 F
    ///   (b) 이름 먼저 — F 가 2–4 낱말(이름 꼴 + 이니셜 + 끝 2자 이상, 끝 낱말에 소문자 포함)이고 다음 조각이 이니셜로 시작하지 않으면 끝 낱말
    ///       (Vancouver 'Sheehan TC'·'Heng JA' 의 대문자 이니셜 묶음을 성으로 받지 않는다 — 검증 1 리뷰)
    ///   그 밖(숫자 섞임·끝이 한 글자·5 낱말 이상)은 nil
    static func citationSurname(_ t: String) -> String? {
        let delims = CharacterSet(charactersIn: ",;(")
        let cut = t.rangeOfCharacter(from: delims)
        var f = (cut.map { String(t[..<$0.lowerBound]) } ?? t).trimmingCharacters(in: .whitespaces)
        let rest = cut.map { String(t[$0.upperBound...]) } ?? ""
        var etal = false
        if let r = f.range(of: "\\s+et al\\.?$", options: [.regularExpression, .caseInsensitive]) { f = String(f[..<r.lowerBound]); etal = true }
        let next = (rest.rangeOfCharacter(from: delims).map { String(rest[..<$0.lowerBound]) } ?? rest).trimmingCharacters(in: .whitespaces)
        let initial = "^\\p{Lu}(?:\\.|\\s|$)"
        let words = f.split(separator: " ").map(String.init)
        guard !words.isEmpty, f.rangeOfCharacter(from: .decimalDigits) == nil else { return nil }
        var i = 0
        while i < words.count - 1, surnameParticles.contains(words[i]) { i += 1 }
        if words.count - i == 1, rx(words[i], "^\\p{Lu}[\\p{L}\\p{M}'’\\-]*$") {
            let nextOK = etal || rx(next, initial) || next.hasPrefix("&") || rx(next, "^(?i:and|et al)\\b") || rx(next, "^(19|20)\\d{2}")
            return nextOK ? f : nil
        }
        if (2...4).contains(words.count), rx(words[0], "^\\p{Lu}\\p{Ll}+$"),
           words.dropFirst().dropLast().allSatisfy({ rx($0, "^\\p{Lu}\\.?$") }),
           let last = words.last, rx(last, "^\\p{Lu}[\\p{L}\\p{M}'’\\-]+$"), rx(last, "\\p{Ll}"), !rx(next, initial) {
            return last
        }
        return nil
    }
    /// 게이트 ③ 저널. (i) APA 꼴: 연도 뒤를 문장으로 나눠 1문장이면 그것, 2문장 이상이면 둘째(첫째는 논문 제목) → 첫 쉼표 앞, 권·호 뗌.
    ///   검증 1 리뷰: 쉼표 든 약어표 저널('Attention, Perception, & Psychophysics')로 시작하면 그 이름 전체. 그 밖에 둘째 쉼표 조각이 권·호(숫자)가
    ///   아니면 저널 이름 안의 쉼표로 보고 nil('…: Learning, memory, and cognition'). 약어표에 없는 후보가 3문장 이상에서 왔거나 '. ' 를 품으면
    ///   (약어 저널 'Proc. Natl. …'·약어/물음표로 끝나는 제목이 문장 나눔을 흐린 경우) nil — 원문 한 줄
    /// (ii) Nature 꼴(연도가 끝 괄호): 연도를 품은 마지막 문장에서 권·호를 떼고, 끝 낱말들이 알려진 저널(약어표 키 ∪ 값)이고
    /// 그 앞이 저자 목록의 끝(이니셜·쉼표)일 때만. 받는 조건: 1–8 낱말·글자로 시작·숫자 없음·'in ' 아님·제목과 같지 않음
    static func citationJournal(_ t: String, year yr: String, title: String) -> String? {
        guard let y = t.range(of: "\\b" + NSRegularExpression.escapedPattern(for: yr) + "[a-z]?\\b", options: .regularExpression) else { return nil }
        let rest = String(t[y.upperBound...]).replacingOccurrences(of: "^[)\\].,;:\\s]+", with: "", options: .regularExpression)
        if !rest.isEmpty {
            let s = sentences(rest)
            // 책 장(In: … / In X (Ed.)) 은 저널이 아니다 — 앞 두 문장 중 하나라도 'In' 으로 시작하면 정리하지 않는다
            if s.prefix(2).contains(where: { rx($0, "^(?i:in)[:\\s]") }) { return nil }
            if !s.isEmpty {
                // 리뷰 2: 알려진 저널 먼저 — s[k...] 를 이어 (쉼표 든 저널 또는) 첫 쉼표 앞, 권·호 뗀 것이 약어표에 있으면 그것
                // (k=0 제목 없음, k=1 제목 있음). 약어 저널 'Cereb. Cortex'·'Curr. Biol.' 이 문장 나눔에 끊겨 'Cortex' 가 되는 것을 막는다
                for k in 0..<min(2, s.count) {
                    let joined = s[k...].joined(separator: " ")
                    let head = commaJournal(joined) ?? stripVolume(joined.components(separatedBy: ",")[0])
                    if knownJournals.contains(journalKey(head)) { return acceptJournal(head, title: title) }
                }
                let k0 = s.count == 1 ? 0 : 1
                let frag = stripVolume(s[k0...].joined(separator: " ").components(separatedBy: ",")[0])
                    .replacingOccurrences(of: "\\.+$", with: "", options: .regularExpression)
                if rx(frag, "\\b\\p{Lu}\\p{Ll}+\\.") { return nil }   // 약어표에 없는 약어 꼴 저널('Exp. Brain Res.') — 원문 한 줄
                let sent = s[k0]
                let c: String
                if let k = commaJournal(sent) { c = k }
                else {
                    let pieces = sent.components(separatedBy: ",")
                    // 둘째 쉼표 조각이 권·호가 아니면 저널 이름 안의 쉼표 — 단 알려진 저널 뒤('Neuron, in press')는 예외 (리뷰 2)
                    if pieces.count > 1, !knownJournals.contains(journalKey(stripVolume(pieces[0]))),
                       !rx(pieces[1].trimmingCharacters(in: .whitespaces), "^\\d") { return nil }
                    c = stripVolume(pieces[0])
                }
                // 제목 조각이 저널 자리에 온 경우('Is it MT? Neuron') — . ? ! 뒤 공백을 품으면 원문 (리뷰 2)
                if !knownJournals.contains(journalKey(c)), s.count > 2 || rx(c, "[.?!]\\s") { return nil }
                return acceptJournal(c, title: title)
            }
        }
        guard rx(t, "\\((19|20)\\d{2}[a-z]?\\)\\.?$"), let last = sentences(t).last(where: { $0.contains(yr) }) else { return nil }
        let words = last.replacingOccurrences(of: "\\s+\\d.*$", with: "", options: .regularExpression).split(separator: " ").map(String.init)
        for k in stride(from: min(8, words.count), through: 1, by: -1) {
            let suffix = words.suffix(k).joined(separator: " ")
            guard knownJournals.contains(journalKey(suffix)) else { continue }
            let before = words.count > k ? words[words.count - k - 1] : ""
            return before.isEmpty || rx(before, "^\\p{Lu}\\.,?$|[,;&]$") ? acceptJournal(suffix, title: title) : nil
        }
        return nil
    }
    private static func stripVolume(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+\\d.*$", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
    /// 쉼표 든 약어표 저널 이름으로 시작하면 원문에서 그 길이만큼 (뒤가 끝·쉼표·마침표·공백일 때만)
    private static let commaJournalKeys: [String] = journalAbbrev.keys.filter { $0.contains(",") }.sorted { $0.count > $1.count }
    private static func commaJournal(_ sent: String) -> String? {
        let low = sent.lowercased()
        for k in commaJournalKeys where low.hasPrefix(k) {
            let after = String(low.dropFirst(k.count))
            if after.isEmpty || rx(after, "^[,.;\\s]") { return String(sent.prefix(k.count)) }
        }
        return nil
    }
    private static func acceptJournal(_ raw: String, title: String) -> String? {
        let c = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\.+$", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard (1...8).contains(c.split(separator: " ").count), rx(c, "^\\p{L}"), c.rangeOfCharacter(from: .decimalDigits) == nil,
              !c.lowercased().hasPrefix("in "),
              !rx(c, "^(?i:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)$") else { return nil }   // 'J Neurosci. 2011 Nov 23;…' 의 월 약어 (검증 1 리뷰)
        let tl = title.lowercased().trimmingCharacters(in: .whitespaces), cl = c.lowercased()
        if !tl.isEmpty && (cl == tl || (cl.count >= 20 && tl.hasPrefix(cl))) { return nil }   // 저널 자리에 논문 제목이 온 경우
        return c
    }
    /// 저널 비교 키 — 소문자·마침표 없음·공백 하나 ('Nat. Neurosci.' = 'Nat Neurosci')
    static func journalKey(_ j: String) -> String {
        collapseSpaces(j.lowercased().replacingOccurrences(of: ".", with: ""))
    }
    /// 알려진 저널 = 약어표의 키 ∪ 값 (Nature 꼴 인용은 이 안에 있을 때만 정리)
    static let knownJournals: Set<String> = Set(journalAbbrev.keys.map(journalKey) + journalAbbrev.values.map(journalKey))
    /// 자주 나오는 저널은 NLM 약어로 ("Nature Human Behaviour" → "Nat Hum Behav"). 목록에 없으면 그대로.
    static let journalAbbrev: [String: String] = [
        "nature human behaviour": "Nat Hum Behav", "nature human behavior": "Nat Hum Behav", "nature communications": "Nat Commun",
        "nature neuroscience": "Nat Neurosci", "nature reviews neuroscience": "Nat Rev Neurosci", "nature methods": "Nat Methods",
        "communications biology": "Commun Biol", "scientific reports": "Sci Rep", "science advances": "Sci Adv",
        "proceedings of the national academy of sciences": "PNAS", "proceedings of the national academy of sciences of the united states of america": "PNAS",
        "plos biology": "PLOS Biol", "plos computational biology": "PLOS Comput Biol", "plos one": "PLOS ONE",
        "journal of neuroscience": "J Neurosci", "the journal of neuroscience": "J Neurosci", "journal of vision": "J Vis",
        "journal of neurophysiology": "J Neurophysiol", "journal of cognitive neuroscience": "J Cogn Neurosci",
        "current biology": "Curr Biol", "cerebral cortex": "Cereb Cortex", "vision research": "Vision Res",
        "psychological review": "Psychol Rev", "psychological science": "Psychol Sci", "psychonomic bulletin & review": "Psychon Bull Rev",
        "trends in cognitive sciences": "Trends Cogn Sci", "trends in neurosciences": "Trends Neurosci",
        "frontiers in psychology": "Front Psychol", "frontiers in human neuroscience": "Front Hum Neurosci", "frontiers in neuroscience": "Front Neurosci",
        "journal of experimental psychology: general": "J Exp Psychol Gen", "attention, perception, & psychophysics": "Atten Percept Psychophys",
        "neural computation": "Neural Comput", "annual review of neuroscience": "Annu Rev Neurosci", "annual review of vision science": "Annu Rev Vis Sci",
        "biological psychiatry": "Biol Psychiatry", "cognitive psychology": "Cogn Psychol",
        // 0.36.0 (R-30) — 10-14 덱과 자주 나오는 단어 저널
        "elife": "eLife", "facial plastic surgery & aesthetic medicine": "Facial Plast Surg Aesthet Med", "cognition": "Cognition",
        "neuron": "Neuron", "nature": "Nature", "science": "Science", "neuroimage": "NeuroImage", "cell reports": "Cell Rep",
    ]
    /// 약어표 키 → 약어. 이미 약어 꼴이면('Nat. Neurosci.') 표의 약어 표기로 맞춘다. 표에 없으면 그대로
    static func abbreviateJournal(_ j: String) -> String {
        let key = j.lowercased().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if let a = journalAbbrev[key] { return a }
        let k = journalKey(j)
        return journalAbbrev.values.first { journalKey($0) == k } ?? j
    }
    static func longDay(_ d: Date) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "M월 d일 EEEE"; return f.string(from: d) }
    static func time(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "H:mm"; return f.string(from: d) }
    static func dday(_ d: Date) -> String {
        let n = Calendar.current.dateComponents([.day], from: HubClock.today, to: d).day ?? 0
        return n == 0 ? "오늘" : (n > 0 ? "D-\(n)" : "D+\(-n)")
    }
}

struct RowDivider: View { var body: some View { Rectangle().fill(Hub.divider).frame(height: 1) } }

struct SectionTitle: View {
    let text: String
    var trailing: String? = nil
    var fresh: Freshness? = nil
    /// '내 것' 배지 카드 id — 꼬리표 옆 '새 n' 칩 (0.40.0 C4, A3-badge)
    var badge: String? = nil
    var action: (() -> Void)? = nil
    /// 제목에서 뺀 설명 (0.42.0 C3, R9-a) — 제목에 마우스를 올리면
    var hint: String? = nil
    /// 카드 글자 역할 (0.37.0) — 제목 = cs.title, 꼬리 링크 = cs.aux
    @Environment(\.cardStyle) private var cs
    init(text: String, hint: String? = nil, trailing: String? = nil, fresh: Freshness? = nil, badge: String? = nil, action: (() -> Void)? = nil) {
        self.text = text; self.hint = hint; self.trailing = trailing; self.fresh = fresh; self.badge = badge; self.action = action
    }
    /// 허브 카드 제목 표(HubCardTitle)에서 — 제목 + 도움말(hint 를 주면 그것으로 바꿈)
    init(card id: String, hint: String? = nil, trailing: String? = nil, fresh: Freshness? = nil, badge: String? = nil, action: (() -> Void)? = nil) {
        self.init(text: HubCardTitle.title(id), hint: hint ?? HubCardTitle.hint(id), trailing: trailing, fresh: fresh, badge: badge, action: action)
    }
    var body: some View {
        HStack(spacing: 6) {
            // 좁은 열에서 한 글자씩 꺾이지 않게 한 줄 + 제목이 꼬리표보다 먼저 폭을 받는다 (0.37.0 리뷰 2)
            Text(text).font(.hub(cs.title, weight: .semibold)).foregroundStyle(Hub.text2).tracking(0.3).lineLimit(1).layoutPriority(1)
                .help(hint ?? "")
            if let f = fresh { FreshnessTag(f: f) }
            if let b = badge { SeenBadge(card: b) }
            Spacer()
            if let t = trailing, let a = action {
                // 꼬리 링크는 줄바꿈 없이 — 1.3배에서 'Pap/ers' 로 꺾이지 않게, 제목이 먼저 줄어든다 (검증 1)
                Button(action: a) { HStack(spacing: 3) { Text(t); Image(systemName: "arrow.up.forward") }.font(.hub(cs.aux, weight: .medium)).lineLimit(1).fixedSize() }
                    .buttonStyle(.plain).foregroundStyle(Hub.text2)
            }
        }
    }
}

struct StatusPill: View {
    let label: String; let done: Bool
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dotted").font(.hub(11, weight: .semibold))
            Text(label).font(.hub(11, weight: .semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill((done ? Hub.ok : Hub.signal).opacity(0.12)))
        .foregroundStyle(done ? Hub.ok : Hub.signal)
    }
}

struct TypePill: View {
    let text: String
    @Environment(\.cardStyle) private var cs
    var body: some View {
        // 줄바꿈 없이 — 큰 글자 배율에서 'A I · M L' 처럼 글자마다 꺾이지 않게 (검증 1)
        Text(text.isEmpty ? "GRM" : text).font(.hub(cs.tag, weight: .bold)).lineLimit(1).fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Hub.ink.opacity(0.12)))
            .foregroundStyle(Hub.ink)
    }
}

struct ActionButton: View {
    let symbol: String; let label: String; var prominent = false; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) { Image(systemName: symbol); Text(label).lineLimit(1) }
                .font(.hub(12, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(prominent ? Hub.ink : Hub.fillNeutral))
                .foregroundStyle(prominent ? Hub.onAccent : Hub.text)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 위젯

struct NotionHubWidget: View {
    @ObservedObject var model: NotionHubModel
    let title: String
    let tabs: [HubTab]
    let tabControllers: [WebController]
    @State private var tab: Int = 0      // 0 = 고른 뷰(HubViewSwitch), 1... = 탭, todayTab = 오늘 시간표
    @ObservedObject private var views = ViewModeStore.shared
    /// --key tab:<제목>|tab:<번호> (0.37.0 C7, 스냅샷용) — KeyBus 로 받아 탭을 고른다
    @ObservedObject private var bus = KeyBus.shared
    /// 글자 배율·색 프리셋 (0.37.0 C3) — 바뀌면 탭 줄+본문만 .id 로 다시 만든다(머리·'글자' 판·고른 탭은 그대로)
    @ObservedObject private var display = HubDisplay.shared
    static let todayTab = 900
    /// '연구' 탭 (0.39.0 C1, RT-TAB) — config 밖 가상 탭: 분야 최근 이슈 + 논문 추천 전체 (ResearchTab.swift). 탭 줄에 늘 보인다
    static let researchTab = 901
    /// 'CSNL GRM' 탭은 웹뷰 대신 발표 순번 화면 (랩장 2026-10-14, #18 — 순번을 알기 위한 탭)
    /// 'Members' 탭은 웹뷰 대신 연구원 현황판 (0.37.0 C7 — 탭 이름·설정 그대로, 탭 대체 아님)
    static func isNative(_ t: HubTab) -> Bool { t.title == "CSNL GRM" || t.title == "Members" }
    static func tabSymbol(_ t: HubTab) -> String { t.title == "Members" ? "person.3" : (t.title == "CSNL GRM" ? "list.number" : "doc.text") }
    /// 탭 줄 표시 이름 (SMJ #28, 0.35.0) — 'CSNL' 만으로는 Notion 웹뷰인지 알 수 없어 'CSNL Notion' 으로 보인다.
    /// 표시만 바꾼다: 설정 기본값·사용자 config.json·isNative 판정·창 머리 제목은 그대로. 사용자가 제목을 바꿔 뒀으면 그 값을 쓴다
    static func tabLabel(_ t: HubTab) -> String { t.title == "CSNL" ? "CSNL Notion" : t.title }

    var body: some View {
        WidgetChrome(style: WidgetStyle(kind: .notionhub, title: title),
                     subtitle: model.lastUpdated.map { "Notion · 갱신 " + Hub.time($0) } ?? "Notion") {
            IconButton(symbol: "textformat.size", help: "Display — 글자 크기·색 (이 맥에만 저장)", label: "Display") {
                withAnimation(.easeOut(duration: 0.12)) { display.panelOpen.toggle() }
            }
            IconButton(symbol: "arrow.clockwise", help: "지금 새로고침") { Task { await model.refresh() } }
            IconButton(symbol: "arrow.up.forward.app", help: "Notion 앱에서 CSNL 열기") { model.openInApp(id: model.cfg.csnlPageID) }
        } content: {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    tabBar
                    Divider().opacity(0.5)
                    // 가상 탭(900·901)은 tabs[tab-1] 을 읽는 분기보다 앞에 있어야 한다 (0.39.0 C1)
                    if tab == 0 { HubViewSwitch(model: model) }
                    else if tab == Self.todayTab, let cal = model.todayCalendar { TodayView(cal: cal) }
                    else if tab == Self.researchTab { ResearchTabView(model: model) }
                    // 안전 가드 — 캘린더 없는 '오늘'(900) 등 config 밖 번호는 고른 뷰로 (tabs[899] 충돌 방지)
                    else if tab > tabs.count { HubViewSwitch(model: model) }
                    else if tabs[tab - 1].title == "Members" { MembersBoardView(model: model, notionURL: URL(string: tabs[tab - 1].url)) }
                    else if Self.isNative(tabs[tab - 1]) { GRMOrderView(model: model, notionURL: URL(string: tabs[tab - 1].url), mapDetail: false) }
                    else {
                        let c = tabControllers[tab - 1]
                        WebArea(controller: c).onAppear { c.ensureLoaded() }
                    }
                }
                .id(display.revision)
                if display.panelOpen {
                    DisplaySettingsPanel().padding(.top, 6).padding(.trailing, 10).transition(.opacity)
                }
            }
            .onReceive(bus.$event.dropFirst().compactMap { $0 }) { e in selectTab(e.key) }   // 구독 때 받는 지난 값은 건너뜀
            // 고른 탭 이름을 windows.txt choices 'tab <이름>' 으로 (0.39.0 C1 — 스냅샷이 어느 탭인지 글로 확인)
            .onChange(of: tab, initial: true) { _, t in LayoutChoice.record("tab", tabName(t)) }
        }
    }

    /// 탭 번호 → 탭 줄 표시 이름 (choices 기록용)
    private func tabName(_ t: Int) -> String {
        if t == 0 { return views.mode.title }
        if t == Self.todayTab { return "오늘" }
        if t == Self.researchTab { return "연구" }
        return t >= 1 && t <= tabs.count ? Self.tabLabel(tabs[t - 1]) : "\(t)"
    }

    /// 'tab:Members' · 'tab:0'(고른 뷰) · 'tab:2' · 'tab:연구'|'tab:901' — 제목(표시 이름 포함)이나 번호
    private func selectTab(_ key: String) {
        guard key.hasPrefix("tab:") else { return }
        let q = String(key.dropFirst(4))
        if q == "연구" || Int(q) == Self.researchTab { tab = Self.researchTab; return }
        if let n = Int(q) { if n == 0 || (1...tabs.count).contains(n) { tab = n }; return }
        if q == "오늘", model.todayCalendar != nil { tab = Self.todayTab; return }
        if let i = tabs.firstIndex(where: { $0.title == q || Self.tabLabel($0) == q }) { tab = i + 1 }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabButton(0, views.mode.title, views.mode.symbol)
            ViewModeMenu { tab = 0 }.padding(.trailing, 4)
            if model.todayCalendar != nil { tabButton(Self.todayTab, "오늘", "calendar.day.timeline.left") }
            tabButton(Self.researchTab, "연구", "books.vertical")
            ForEach(Array(tabs.enumerated()), id: \.offset) { i, t in tabButton(i + 1, Self.tabLabel(t), Self.tabSymbol(t)) }
            Spacer()
            // 웹 도구 막대는 config 웹 탭에서만 — 가상 탭(900·901)은 tabs 범위 밖이라 먼저 거른다 (0.39.0 C1, 901 이면 tabs[900] 충돌)
            if tab > 0 && tab <= tabs.count && !Self.isNative(tabs[tab - 1]) {
                let c = tabControllers[tab - 1]
                HStack(spacing: 4) {
                    IconButton(symbol: "house", help: "페이지 처음으로") { c.home() }
                    IconButton(symbol: "chevron.left", help: "뒤로") { c.webView.goBack() }
                    IconButton(symbol: "arrow.clockwise", help: "새로고침") { c.reload() }
                    IconButton(symbol: "sidebar.left", help: "Notion 사이드바 보이기/숨기기") {
                        c.webView.evaluateJavaScript("window.__deskhubToggleSidebar && window.__deskhubToggleSidebar()") { _, _ in }
                    }
                    IconButton(symbol: "arrow.up.forward.app", help: "이 페이지를 Notion 에서 열기") {
                        NotionLink.open(url: c.currentURL ?? c.homeURL)
                    }
                }
                .buttonStyle(HeaderButtonStyle())
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func tabButton(_ i: Int, _ label: String, _ symbol: String) -> some View {
        Button { tab = i } label: {
            HStack(spacing: 5) { Image(systemName: symbol); Text(label) }
                .font(.hub(12, weight: tab == i ? .bold : .medium))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tab == i ? Hub.ink.opacity(0.12) : Color.clear))
                .foregroundStyle(tab == i ? Hub.ink : Hub.text2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Paper Blitz pptx 읽기 (NAS)

/// NAS 의 GRM/<yyyy>/<yyyymmdd>/PB_yymmdd.pptx 에서 논문 제목 슬라이드를 읽는다.
/// 템플릿: 제목 / 저자(연도) 저널 / "Core question" / … / "Initial" / 이니셜
enum PaperBlitzDeck {
    struct Found { let date: Date; let path: String; let papers: [BlitzPaper] }

    /// 가장 최근 PB 덱 경로만 (파싱 없이) — Notion 과 날짜 비교용
    static func latestFile(root: String, within days: Int = 21) -> (date: Date, path: String)? {
        let fm = FileManager.default
        let years = ((try? fm.contentsOfDirectory(atPath: root)) ?? []).filter { $0.count == 4 && Int($0) != nil }.sorted(by: >)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; f.timeZone = .current
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        for y in years.prefix(2) {
            let dirs = ((try? fm.contentsOfDirectory(atPath: "\(root)/\(y)")) ?? []).filter { $0.count == 8 && Int($0) != nil }.sorted(by: >)
            for d in dirs {
                guard let date = f.date(from: d), date >= cutoff else { continue }
                let files = ((try? fm.contentsOfDirectory(atPath: "\(root)/\(y)/\(d)")) ?? [])
                    .filter { $0.uppercased().hasPrefix("PB_") && $0.lowercased().hasSuffix(".pptx") && !$0.hasPrefix("~$") }.sorted()
                if let file = files.first { return (Calendar.current.startOfDay(for: date), "\(root)/\(y)/\(d)/\(file)") }
            }
        }
        return nil
    }

    /// 파싱 결과 캐시 — 경로+수정 시각 (10분마다 15MB pptx 를 다시 풀지 않게)
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var parseCache: [String: [BlitzPaper]] = [:]
    static func parseCached(_ path: String) -> [BlitzPaper] {
        let m = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(path)|\(m)"
        cacheLock.lock(); let hit = parseCache[key]; cacheLock.unlock()
        if let hit { return hit }
        let papers = parse(pptx: path)
        cacheLock.lock(); parseCache[key] = papers; cacheLock.unlock()
        return papers
    }

    static func latest(root: String, within days: Int = 21) -> Found? {
        guard let (date, path) = latestFile(root: root, within: days) else { return nil }
        return Found(date: date, path: path, papers: parseCached(path))
    }

    static func parse(pptx path: String) -> [BlitzPaper] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", path, "ppt/slides/slide*.xml"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let xml = String(data: data, encoding: .utf8) else { return [] }
        let slides = xml.components(separatedBy: "<?xml").dropFirst()
        var papers: [BlitzPaper] = []
        let paraRE = try! NSRegularExpression(pattern: "<a:p>(.*?)</a:p>", options: [.dotMatchesLineSeparators])
        let runRE = try! NSRegularExpression(pattern: "<a:t>([^<]*)</a:t>")
        let yearRE = try! NSRegularExpression(pattern: "\\b(19|20)\\d{2}\\b")
        for (n, slide) in slides.enumerated() {
            let ns = slide as NSString
            var paras: [String] = []
            for m in paraRE.matches(in: slide, range: NSRange(location: 0, length: ns.length)) {
                let body = ns.substring(with: m.range(at: 1)) as NSString
                let t = runRE.matches(in: body as String, range: NSRange(location: 0, length: body.length)).map { body.substring(with: $0.range(at: 1)) }.joined()
                let clean = unescape(t).trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { paras.append(clean) }
            }
            guard let cq = paras.firstIndex(where: { $0.lowercased().hasPrefix("core question") }), cq >= 1 else { continue }
            var title = paras[0]
            if title.lowercased() == "paper title" { continue }
            var citationOverride: String?
            // 제목 칸에 인용문 전체를 넣은 경우: "Cheng, S., … (2026). 제목. 저널." → 제목만 뽑는다
            if let m = try! NSRegularExpression(pattern: "\\((19|20)\\d{2}[a-z]?\\)\\.\\s*([^.]+[.?!])").firstMatch(in: title, range: NSRange(location: 0, length: (title as NSString).length)) {
                citationOverride = title
                title = (title as NSString).substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            }
            var initials = ""
            if let ii = paras.firstIndex(where: { $0.lowercased() == "initial" || $0.lowercased() == "initials" }), ii + 1 < paras.count {
                initials = paras[ii + 1].trimmingCharacters(in: .punctuationCharacters).uppercased()
            }
            if initials == "ABC" { continue }
            let citation = citationOverride ?? (cq >= 2 ? paras[1..<cq].joined(separator: " ") : "")
            let question = cq + 1 < paras.count && !paras[cq + 1].lowercased().hasPrefix("reason") ? paras[cq + 1] : ""
            var year: Int?
            if let m = yearRE.firstMatch(in: citation, range: NSRange(location: 0, length: (citation as NSString).length)) { year = Int((citation as NSString).substring(with: m.range)) }
            papers.append(BlitzPaper(id: "pb-\(n)-\(title.hashValue)", title: title, presenter: initials, citation: citation, year: year,
                                     coreQuestion: question, doi: nil, notionID: nil, order: n))
        }
        return papers
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
    }
}

/// Crossref 로 제목 → DOI. 결과는 Application Support/DeskHub/doi-cache.json 에 저장
actor DOIResolver {
    static let shared = DOIResolver()
    private var cache: [String: String] = [:]
    private var failed: Set<String> = []
    private let file = Config.directory.appendingPathComponent("doi-cache.json")
    private var loaded = false

    func doi(forTitle title: String) async -> URL? {
        if !loaded { loaded = true; if let d = try? Data(contentsOf: file), let m = try? JSONDecoder().decode([String: String].self, from: d) { cache = m } }
        let key = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let hit = cache[key], !hit.isEmpty { return URL(string: hit) }
        if failed.contains(key) { return nil }          // 이번 실행에서 이미 실패 — 다음 실행에 재시도
        var comps = URLComponents(string: "https://api.crossref.org/works")!
        comps.queryItems = [URLQueryItem(name: "query.bibliographic", value: title), URLQueryItem(name: "rows", value: "5"), URLQueryItem(name: "select", value: "DOI,title,type")]
        var req = URLRequest(url: comps.url!); req.timeoutInterval = 25
        req.setValue("DeskHub/1.0 (CSNL lab dashboard; mailto:lab-calendar@example.com)", forHTTPHeaderField: "User-Agent")
        var result = ""
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let items = (obj["message"] as? [String: Any])?["items"] as? [[String: Any]] {
            // 제목 유사도 ≥ 0.75 인 후보만. 같은 논문의 출판본이 프리프린트와 함께 있으면 출판본을 고른다
            var best: (score: Double, doi: String, preprint: Bool)?
            for it in items {
                let t = ((it["title"] as? [String])?.first ?? "").lowercased()
                guard let d = it["DOI"] as? String else { continue }
                let sc = similarity(t, key)
                guard sc >= 0.75 else { continue }
                let isPreprint = (it["type"] as? String) == "posted-content" || d.hasPrefix("10.1101/") || d.hasPrefix("10.31234/")
                if let b = best {
                    if b.preprint && !isPreprint && sc >= b.score - 0.05 { best = (sc, d, false) }      // 거의 같은 제목의 출판본
                    else if sc > b.score + 0.05 { best = (sc, d, isPreprint) }
                } else { best = (sc, d, isPreprint) }
            }
            if let b = best { result = "https://doi.org/\(b.doi)" }
        }
        if result.isEmpty { failed.insert(key); return nil }
        cache[key] = result
        if let d = try? JSONEncoder().encode(cache) { try? d.write(to: file) }
        return URL(string: result)
    }

    /// 단어 집합 겹침 / 큰 쪽 집합 크기 (0~1)
    private func similarity(_ a: String, _ b: String) -> Double {
        func words(_ s: String) -> Set<String> { Set(s.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 }) }
        let wa = words(a), wb = words(b)
        guard !wa.isEmpty, !wb.isEmpty else { return 0 }
        return Double(wa.intersection(wb).count) / Double(max(wa.count, wb.count))
    }
}

// MARK: - Prolific

/// places = total_available_places, submissions = number_of_submissions(study 누적). publishedAt·placesTaken 은 0.40.0 C7(A4 온라인 수집) —
/// 금액(rewardPence)은 기존 카드 detail 에만 남고 새 계산에는 쓰지 않는다
struct ProlificStudy { let id: String; let name: String; let status: String; let places: Int; let submissions: Int; let rewardPence: Int; var project: String = ""
    var publishedAt: Date? = nil; var placesTaken: Int = 0 }
enum ProlificResult { case noToken, error(String), ok([ProlificStudy]) }

/// 허브·관제탑에 보일 Prolific study (0.37.0 C4, 랩장 10-16 18:12) — 진행(ACTIVE)·준비(UNPUBLISHED) 중만.
/// PAUSED·AWAITING REVIEW·SCHEDULED·PUBLISHING·COMPLETED 는 뺀다. --text-check 의 prolific 줄
enum ProlificFilter {
    static let allowed: Set<String> = ["ACTIVE", "UNPUBLISHED"]
    static func keep(_ status: String) -> Bool { allowed.contains(status.trimmingCharacters(in: .whitespaces).uppercased()) }
    /// 화면 상태 글자 — 진행 중(Hub.ok) · 준비 중(Hub.text2)
    static func label(_ status: String) -> String {
        switch status.trimmingCharacters(in: .whitespaces).uppercased() {
        case "ACTIVE": return "진행 중"
        case "UNPUBLISHED": return "준비 중"
        default: return status.capitalized
        }
    }
    static let activeLabel = "진행 중"
    /// 정렬 — 진행 중 0 · 준비 중 1 · 그 밖 2
    static func rank(label: String) -> Int { label == "진행 중" ? 0 : (label == "준비 중" ? 1 : 2) }
}

/// 읽기만 한다. 토큰은 랩 prolific 플러그인과 같은 credentials.json 의 api_token
struct ProlificClient {
    let credentialsFile: String
    var envFile: String = ""
    var envKey: String = ""
    var workspaceID: String = ""
    func token() -> String? {
        // 1) .env 의 PROLIFIC_API_TOKEN
        if !envFile.isEmpty, let text = try? String(contentsOfFile: (envFile as NSString).expandingTildeInPath, encoding: .utf8) {
            for line in text.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix(envKey + "=") {
                    let v = String(t.dropFirst(envKey.count + 1)).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if !v.isEmpty { return v }
                }
            }
        }
        // 2) credentials.json 의 api_token
        let path = (credentialsFile as NSString).expandingTildeInPath
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let t = o["api_token"] as? String, !t.isEmpty else { return nil }
        return t
    }
    private func get(_ path: String, _ t: String, timeout: TimeInterval = 30) async throws -> [[String: Any]] {
        var req = URLRequest(url: URL(string: "https://api.prolific.com/api/v1/" + path)!); req.timeoutInterval = timeout
        req.setValue("Token " + t, forHTTPHeaderField: "Authorization"); req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 300 { throw NSError(domain: "Prolific", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code) \(path)"]) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = obj["results"] as? [[String: Any]] else { throw NSError(domain: "Prolific", code: 1, userInfo: [NSLocalizedDescriptionKey: "응답 형식 \(path)"]) }
        return rows
    }
    /// 테스트 픽스처 (0.37.0 C4, DESKHUB_PROLIFIC_SIM=fixture:<json>) — API 와 같은 키의 study 목록.
    /// 형식: {"results":[{"id","internal_name"|"name","status","total_available_places","number_of_submissions","reward","project"}]} 또는 그 배열만.
    /// project(프로젝트 제목 = 실험자 이름, 'project_title' 도 받음)가 실험자 이니셜이 된다. 파싱·필터는 실제 조회와 같다
    static func fixture(path: String) -> ProlificResult {
        guard let d = FileManager.default.contents(atPath: path), let o = try? JSONSerialization.jsonObject(with: d) else {
            return .error("시험 픽스처를 읽지 못함 (DESKHUB_PROLIFIC_SIM)")
        }
        let rows = (o as? [[String: Any]]) ?? ((o as? [String: Any])?["results"] as? [[String: Any]]) ?? []
        return .ok(rows.map { study($0, project: ($0["project"] as? String) ?? ($0["project_title"] as? String) ?? "") })
    }
    static func study(_ r: [String: Any], project: String) -> ProlificStudy {
        ProlificStudy(id: r["id"] as? String ?? "", name: (r["internal_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (r["name"] as? String ?? ""),
                      status: (r["status"] as? String ?? "").uppercased(), places: r["total_available_places"] as? Int ?? 0,
                      submissions: r["number_of_submissions"] as? Int ?? 0, rewardPence: r["reward"] as? Int ?? 0, project: project,
                      publishedAt: publishedAt(r["published_at"]), placesTaken: r["places_taken"] as? Int ?? 0)
    }
    /// '2026-10-03T09:00:00.000000Z' — 소수 초(자릿수 제각각)를 떼고 ISO 로 (0.40.0 C7)
    static func publishedAt(_ v: Any?) -> Date? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        let t = s.replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: t) ?? MetricsSnapshot.day(t)
    }
    /// 워크스페이스 → 프로젝트(이름 = 실험자) → 프로젝트별 study. /studies/ 전체 조회(263개, 30초)보다 빠르고 실험자가 붙는다.
    /// 프로젝트 조회가 안 되면 전체 조회로 돌아간다(실험자 없음)
    func studies() async -> ProlificResult {
        guard let t = token() else { return .noToken }
        do {
            var ws = workspaceID
            if ws.isEmpty { ws = (try await get("workspaces/", t).first?["id"] as? String) ?? "" }
            let projects = ws.isEmpty ? [] : try await get("workspaces/\(ws)/projects/", t)
            if projects.isEmpty {
                return .ok(try await get("studies/?limit=50", t, timeout: 60).map { Self.study($0, project: "") })
            }
            let all: [ProlificStudy] = try await withThrowingTaskGroup(of: [ProlificStudy].self) { g in
                for pr in projects {
                    guard let id = pr["id"] as? String else { continue }
                    let title = (pr["title"] as? String ?? "").replacingOccurrences(of: "&amp;", with: "&")
                    g.addTask { try await get("projects/\(id)/studies/", t).map { Self.study($0, project: title) } }
                }
                var out: [ProlificStudy] = []
                for try await part in g { out += part }
                return out
            }
            return .ok(all)
        } catch { return .error(error.localizedDescription) }
    }
}

// MARK: - 대시보드

struct Dashboard: View {
    @ObservedObject var model: NotionHubModel
    @ObservedObject var expansion = HubExpansion.shared
    /// HubLayoutProbe 소유자 토큰 (0.38.0 C3) — 배율 변경으로 본문이 다시 만들어질 때 옛 Dashboard 가 새 값을 지우지 않게
    @State private var probeOwner = UUID()

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: HubSpace.card) {
                // 연구실 상태 한 줄 (0.40.0 C4, A3) — 허브 마감 적색은 이 줄 '확정 n' 한 칸으로 모은다(카드 D-day 는 quiet, 결정 D-b). 클릭 = 8주 띠
                StatusLineView(model: model, quiet: false)
                // 2026-10-13: 다음 GRM 은 한 줄로 작게, 연구원 + 진행 프로젝트 버튼, 논문 추천을 왼쪽 큰 칸(반응·댓글),
                // 회의록은 최근 하나(펼치기), 아래 줄: 최신 원고 · 다가오는 학회 · 지난 Paper Blitz
                // 다음 GRM 과 오늘 캘린더(지금·다음)는 다른 카드로 (#13 JYK — 한 카드에 섞이면 헷갈림)
                // 0.37.0 (랩장 10-16 18:12): 여백 12 → 8(HubSpace), 글자는 CardStyle.large(제목 16·본문 15·보조 14), 윗줄 두 칸 300 → 320
                // 0.42.0 C5 (R9-c, 결정 D-12): [Next GRM + Now·Next 세로 쌓기 320 | Members 카드 넓게] — 같은 카드 셋, 배치만
                HStack(alignment: .top, spacing: HubSpace.column) {
                    // 카드 끝 캡션 '출처 · 기준 · n · 정의 id' (0.40.0 C2, A1) — 윗줄 세 카드는 허브에서만
                    VStack(alignment: .leading, spacing: HubSpace.card) {
                        CompactGRMBar(model: model, caption: true)
                        if let cal = model.todayCalendar { NowNextCard(cal: cal, caption: true) }
                    }
                    // 글자 배율만큼 넓힘 — 고정 320 은 1.6배에서 내용이 넘쳐 왼쪽이 잘렸다('ext GRM', 0.42.0 C5 검증 1)
                    .frame(width: Hub.s(320))
                    MembersCard(model: model).frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
                // 가운데 3열 (R-J1, 0.36.0 — 열 바닥 빈 면에 묻혀 있던 카드를 올림, 결정 D5):
                //   열1 논문 추천 + 최신 원고 + 만든 앱(바닥) | 열2 할 일·메일 초안·실험·일정·그랜트 | 열3 회의록 + 지난 Paper Blitz(내용 높이) + 학회(5행)
                // 열2·열3 은 스크롤 열 — 윗줄 연구원 줄이 길어져도 바닥 줄(제작·GitHub)이 밀려나지 않게. 빈 면은 HubLayoutProbe 로 잰다(windows.txt hub-cols)
                // 리뷰 low 2-b (0.37.0): 일정은 설정값과 무관하게 10행을 강제하던 것을 8행으로 (가까운 것만은 C2)
                // 0.37.0 C2: 카드마다 가까운 것만(nearOnly, HubNear) + '▸ 더 보기' 제자리 펼침(HubExpansion, 이 맥 저장). 관제탑·다른 뷰는 그대로
                HStack(alignment: .top, spacing: HubSpace.column) {
                    column1
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: HubSpace.card) {
                            RemindersSection(model: model, nearOnly: true, quiet: true); AppsScriptSection(model: model); ExperimentsCard(model: model, nearOnly: true)
                            EquipmentCard(model: model)   // 장비 예약 6줄 · 닫기 누락 (0.40.0 C5, A5)
                            UpcomingEventsCard(model: model, cal: model.todayCalendar, maxRows: 8, nearOnly: true)
                            ClassesCard(model: model)   // 오늘·이번 주 수업 (0.42.0 C4, R1) — Upcoming 바로 아래
                            GrantsSection(model: model, quiet: true, nearOnly: true)   // 메일 초안 버튼은 할 일 바로 아래 (스크롤 없이 보이게)   // GRM 자료 칸은 뺌 (랩장 의견 2026-10-13)
                        }
                        .hubProbe("2", .content)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .hubProbe("2", .visible)
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: HubSpace.card) {
                            // 미팅 후속 (0.41.0 C3, R1-d) — 열3 맨 위, 회의록 맥락 바로 위 (결정 D-a). 가장 긴 열2 는 늘리지 않는다
                            FollowupsCard(model: model, nearOnly: true).fixedSize(horizontal: false, vertical: true)
                            MinutesCard(model: model, nearOnly: true).fixedSize(horizontal: false, vertical: true)
                            BlitzCompact(model: model, fill: false, nearOnly: true)
                            // 다가오는 학회 — 열2 그랜트 아래(R2-01 BHL)에서 열3 Blitz 아래 빈 면으로 (R-J1). 최신 원고는 열1 (검증 1)
                            ConferencesCard(model: model, maxRows: 5, quiet: true, nearOnly: true)
                        }
                        .hubProbe("3", .content)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .hubProbe("3", .visible)
                }
                .frame(maxHeight: .infinity)
                footer
            }
            .padding(HubSpace.outer)
            .environment(\.cardStyle, .large)
            .environment(\.hubProbeOwner, probeOwner)
            if model.tokenMissing { tokenMissingOverlay }
        }
        // 접힘 빈 면 채우기(HubFill, 0.38.0 C3) — 데이터 다 옴·캘린더 첫 조회·펼침이 바뀔 때 한 번 더 본다(측정이 바뀔 때는 probe 가 깨운다)
        .onAppear { HubFill.shared.attach(model) }
        .onChange(of: model.settledAt) { _, _ in HubFill.shared.poke() }
        .onChange(of: model.loading) { _, _ in HubFill.shared.poke() }
        .onChange(of: model.todayCalendar?.isSettled ?? false) { _, _ in HubFill.shared.poke() }
        // 펼침·접힘은 모든 열을 '바뀐 뒤 측정 대기'로 — 애니메이션 중간·옛 높이로 정하거나 빼지 않게 (0.39.0 C0)
        .onChange(of: expansion.open) { _, _ in HubFill.shared.expansionChanged() }
        .onDisappear { HubLayoutProbe.clear(owner: probeOwner) }
    }

    /// 열1 — 논문 추천 + 최신 원고 + 만든 앱. 추천을 펼치면 0.36.0 처럼 추천 스크롤 칸이 열을 채우고(빈 면 = 그 칸, probe "1"),
    /// 접히면 세 카드가 내용 높이로 쌓이고 열 전체가 스크롤(넘칠 때만) — 빈 면은 열 바닥 (probe "1" 을 열에서 잰다)
    @ViewBuilder private var column1: some View {
        // 생산자가 멈췄으면 펼침 저장값이 있어도 접힌 갈래 — 논문 추천은 한 줄, 열은 스크롤·바닥 빈 면 측정 (0.40.0 C8, R4). HubExpansion 값은 지우지 않는다
        if expansion.isOpen("papers") && !model.papersStopped {
            VStack(alignment: .leading, spacing: HubSpace.card) {
                PaperRecBoard(model: model, probeKey: "1", nearOnly: true, fold: true)
                LatestManuscripts(model: model, nearOnly: true).fixedSize(horizontal: false, vertical: true)
                AppsCard(nearOnly: true).fixedSize(horizontal: false, vertical: true)   // 만든 앱 (랩장 10-16) — 열2 끝에서 열1 바닥으로
                JointProjectsCard(model: model).fixedSize(horizontal: false, vertical: true)   // Joint projects (0.42.0 C6, R9-d) — 좌측 하단
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: HubSpace.card) {
                    PaperRecBoard(model: model, nearOnly: true, fold: true)
                    LatestManuscripts(model: model, nearOnly: true).fixedSize(horizontal: false, vertical: true)
                    AppsCard(nearOnly: true).fixedSize(horizontal: false, vertical: true)
                    JointProjectsCard(model: model).fixedSize(horizontal: false, vertical: true)
                }
                .hubProbe("1", .content)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .hubProbe("1", .visible)
        }
    }

    // 0.37.0: 쓰지 않던 옛 조각(hero·membersStrip·blitzList·manuscriptsView·quickLinks·paperRecs — v24 이후 body 에서 빠짐)을 지움.
    // 같은 자리는 CompactGRMBar·MembersProjectsStrip·BlitzCompact·LatestManuscripts·PaperRecBoard 가 맡는다

    private var footer: some View {
        HStack(spacing: 8) {
            if let e = model.error ?? model.experimentsNote { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Hub.signal); Text(e).lineLimit(1) }
            Spacer()
            Text("DeskHub \(Hub.buildLabel) · 제작 박준오 · © 2026 CSNL").foregroundStyle(Hub.text3)
                .help("버전 · 커밋 · 빌드 시각 — 리뷰 이슈 '환경' 칸에 이 줄을 붙여 주세요")
            Button("GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/Joonoh991119/csnl-admin")!) }
                .buttonStyle(.plain).foregroundStyle(Hub.text3).help("github.com/Joonoh991119/csnl-admin")
            Text("·").foregroundStyle(Hub.text3)
            Button("설정 파일") { NSWorkspace.shared.open(Config.fileURL) }.buttonStyle(.plain).foregroundStyle(Hub.text3)
        }
        .font(.hub(11)).foregroundStyle(Hub.text2)
    }

    private var tokenMissingOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "key.slash").font(.hub(36)).foregroundStyle(Hub.text2)
            Text("Notion 토큰을 찾지 못했습니다").font(.hub(14, weight: .semibold))
            Text("config.json 의 notionHub.tokenEnvFile (\(model.cfg.tokenEnvFile)) 에 \(model.cfg.tokenEnvKey)=… 가 있어야 합니다.")
                .font(.hub(12)).foregroundStyle(Hub.text2).multilineTextAlignment(.center)
            Button("설정 파일 열기") { NSWorkspace.shared.open(Config.fileURL) }
        }
        .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
