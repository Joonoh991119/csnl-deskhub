import SwiftUI
import AppKit

// MARK: - 미팅 후속 체크리스트 (0.41.0, R1 — 랩장 JOP 10-17 '미팅에서 어떤 코멘트가 있었는지, 다음 마일스톤이 뭔지 … 체크리스트에서 체크')
// 데이터 계약 (계획 0.41.0 §2):
//   <grantsFile 폴더>/followups/proposals.json — scripts/meeting_followups.py 만 쓴다. 앱은 읽기만.
//   <같은 폴더>/state-<이니셜>.json — 그 이니셜의 앱만 쓴다(상태 행 + 직접 적은 MM 항목 'fu-self-'). 교수님 맥·스크립트는 쓰지 않는다.
// 상태 말: proposed(상태 행 없음) → confirmed(확정) · done(끝남) · dismissed(아님). 남은 = proposed + confirmed (결정 D-b).
// 보기: 확인한 이니셜 = who → 내용(쓰기) · 교수님(supervisors) → 읽기 · 그 밖 → 수만. 관제탑·전광판·상태 한 줄은 수만.
// 쓰기 규칙은 리마인더(RemindersFile.upsert)와 같다 — 관대 읽기, 저장 직전 재읽기, id 병합, .bak, atomic, 깨진 파일엔 쓰지 않음.
// 더해서 폴더가 없으면 만들지 않는다(NAS 미마운트 때 로컬에 _ssot 가 생기지 않게). 적색은 쓰지 않는다(잠김·저장 실패도 Hub.text2).

struct FollowupItem: Codable, Identifiable, Hashable {
    var id: String
    var who: String
    var meeting: String
    var meetingDate: String
    var kind: String
    var text: String
    var rule: String?
    var source: [String: String]
    var line: Int?
    /// 출처 바뀜 (0.42.0 C2, R6) — 스크립트가 다시 읽은 출처·사라진 MM 파일에 이 글이 없을 때 단다(선택 키, 0.41.0 파일은 nil)
    var orphanSince: String? = nil
    var orphanReason: String? = nil
    /// 같은 글의 옛 id (담당·출처가 바뀌어 id 가 바뀜) — 상태를 이어받는다
    var aka: [String]? = nil
    enum CodingKeys: String, CodingKey { case id, who, meeting, meetingDate = "meeting_date", kind, text, rule, source, line,
                                         orphanSince = "orphan_since", orphanReason = "orphan_reason", aka }
    var isOrphan: Bool { !(orphanSince ?? "").isEmpty }

    var day: Date? { RemindersFile.dayFormatter.date(from: String(meetingDate.prefix(10))) }
    var isSelf: Bool { id.hasPrefix("fu-self-") }
    /// 출처 칩 'GRM 10.7' · 'MM 10.2'
    var chip: String { meeting + " " + (day.map(Hub.shortDay) ?? "—") }
    var link: HubLink? {
        if let n = source["notion"], !n.isEmpty { return .notion(n) }
        if let p = source["nas"], !p.isEmpty { return .nas(p) }
        return nil
    }
    var linkKind: String { source["notion"] != nil ? "notion" : (source["nas"] != nil ? "nas" : "—") }

    /// Plaud 원본 (0.44.0 C2, #59 결정 D-11) — source 'plaud'(스크립트가 단 NAS 녹취 JSON)가 있으면 그 파일,
    /// 없고 GRM 이면 <GRM 루트>/<yyyy>/<yyyyMMdd>/transcript 폴더(있을 때). 같은 날 GRM 이 둘이면 폴더까지만 맞다
    @MainActor func plaudTarget(grmRoot: String) -> PlaudTarget? {
        PlaudTarget.resolve(plaud: source["plaud"], meeting: meeting, meetingDate: meetingDate, grmRoot: grmRoot,
                            fileExists: { PlaudTarget.exists($0, dir: false) }, dirExists: { PlaudTarget.exists($0, dir: true) })
    }
}

/// 미팅 후속 행의 'Plaud ↗' — Finder 에서 녹취 파일(또는 그날 transcript 폴더)을 선택해 보인다
struct PlaudTarget: Equatable {
    let path: String
    let isFile: Bool
    var kind: String { isFile ? "file" : "folder" }
    func reveal() { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }

    /// 순수 판정 — text-check 'fu-plaud' 와 같은 함수
    /// 날짜 폴더는 meeting_date 글('yyyy-MM-dd…')에서 바로 — 시간대 변환 없이 NAS 폴더 이름과 같게
    static func resolve(plaud: String?, meeting: String, meetingDate: String, grmRoot: String,
                        fileExists: (String) -> Bool, dirExists: (String) -> Bool) -> PlaudTarget? {
        if let p = plaud, !p.isEmpty, fileExists(p) { return PlaudTarget(path: p, isFile: true) }
        let ymd = String(meetingDate.prefix(10))
        guard meeting == "GRM", !grmRoot.isEmpty, ymd.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let dir = "\(grmRoot)/\(ymd.prefix(4))/\(ymd.replacingOccurrences(of: "-", with: ""))/transcript"
        return dirExists(dir) ? PlaudTarget(path: dir, isFile: false) : nil
    }

    /// NAS 확인을 화면 그릴 때마다 하지 않게 5분 기억 (메인 스레드)
    @MainActor private static var cache: [String: (ok: Bool, at: Date)] = [:]
    @MainActor static func exists(_ path: String, dir: Bool) -> Bool {
        let k = (dir ? "d:" : "f:") + path
        if let c = cache[k], Date().timeIntervalSince(c.at) < 300 { return c.ok }
        var isDir: ObjCBool = false
        let ok = FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue == dir
        cache[k] = (ok, Date())
        return ok
    }
}

struct FollowupState: Codable, Hashable {
    var id: String
    var status: String
    var by: String?
    var at: String?
    var who: String?
    var meeting: String?
    var meetingDate: String?
    var kind: String?
    var text: String?
    enum CodingKeys: String, CodingKey { case id, status, by, at, who, meeting, meetingDate = "meeting_date", kind, text }

    /// 직접 적은 항목(fu-self-, 글 있음) → 목록 항목. owner = 상태 파일의 이니셜
    func selfItem(owner: String) -> FollowupItem? {
        guard id.hasPrefix("fu-self-"), let t = text, !t.isEmpty else { return nil }
        let w = (who ?? "").isEmpty ? owner : who!
        let k = FollowupLogic.kinds.contains(kind ?? "") ? kind! : "기타"
        return FollowupItem(id: id, who: w, meeting: meeting ?? "MM", meetingDate: meetingDate ?? String((at ?? "").prefix(10)),
                            kind: k, text: t, rule: "self", source: [:], line: nil)
    }
}

enum FollowupRead: Equatable {
    case ok
    case unknown(String)
    var text: String { if case .unknown(let w) = self { return "?(\(w))" }; return "ok" }
}

enum FollowupsFile {
    enum Proposals { case ok(items: [FollowupItem], generated: Date?), missing(String), corrupt(String) }
    enum StateFile { case ok([FollowupState]), corrupt }
    struct Snapshot { var proposals: Proposals; var states: [String: StateFile] }

    /// 시험 훅 DESKHUB_FOLLOWUPS=<폴더> 면 NAS 대신 그 폴더 (remindersPath·DESKHUB_CONF_INTEREST 와 같은 방식, Config 그대로)
    static var hookDir: String? {
        guard let p = ProcessInfo.processInfo.environment["DESKHUB_FOLLOWUPS"], !p.isEmpty else { return nil }
        return (p as NSString).expandingTildeInPath
    }
    static func dir(_ cfg: NotionHubConfig) -> String {
        hookDir ?? ((cfg.grantsFile as NSString).deletingLastPathComponent as NSString).appendingPathComponent("followups")
    }
    static func statePath(_ dir: String, _ initials: String) -> String {
        (dir as NSString).appendingPathComponent("state-\(initials.uppercased()).json")
    }
    static func isDir(_ p: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
    }
    private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
    static func parseDate(_ s: String) -> Date? { iso.date(from: s) }

    static func decode<T: Decodable>(_ r: [String: Any], as: T.Type) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: r) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// 폴더 · proposals.json · state-*.json 을 한 번에 (메인 스레드 밖). 항목 단위로 관대 — 한 항목이 깨져도 나머지는 살린다
    static func load(_ dir: String) -> Snapshot {
        guard isDir(dir) else { return Snapshot(proposals: .missing("폴더 없음"), states: [:]) }
        let fm = FileManager.default
        var states: [String: StateFile] = [:]
        for n in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where n.hasPrefix("state-") && n.hasSuffix(".json") {
            let ini = String(n.dropFirst(6).dropLast(5)).uppercased()
            guard (2...4).contains(ini.count), ini.allSatisfy({ $0.isASCII && $0.isLetter }) else { continue }
            states[ini] = loadState((dir as NSString).appendingPathComponent(n))
        }
        let p = (dir as NSString).appendingPathComponent("proposals.json")
        guard let d = fm.contents(atPath: p) else { return Snapshot(proposals: .missing("파일 없음"), states: states) }
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], (o["schema"] as? Int) == 1,
              let raw = o["items"] as? [[String: Any]] else {
            return Snapshot(proposals: .corrupt("proposals 손상"), states: states)
        }
        let items = raw.compactMap { decode($0, as: FollowupItem.self) }.filter { !$0.id.isEmpty && !$0.isSelf }
        return Snapshot(proposals: .ok(items: items, generated: (o["generated"] as? String).flatMap(parseDate)), states: states)
    }
    static func loadState(_ path: String) -> StateFile {
        guard let d = FileManager.default.contents(atPath: path),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let raw = o["items"] as? [[String: Any]] else { return .corrupt }
        return .ok(raw.compactMap { decode($0, as: FollowupState.self) })
    }

    /// 끝남·확정·아님이 고치는 키
    static let statusFields: Set<String> = ["status", "by", "at"]

    /// 상태 파일 쓰기를 하나씩 — commitFollowup 은 항목마다 detached 로 쓰므로, NAS(왕복 수십~수백 ms)에서 두 행을 연달아 누르면
    /// 둘째 쓰기가 첫째가 끝나기 전 파일을 읽고 첫째 행이 빠진 내용으로 덮었다 (0.41.0 검증 1 리뷰). 읽기·병합·쓰기를 이 큐에서 통째로
    private static let writeQueue = DispatchQueue(label: "kr.ac.snu.csnl.deskhub.followups.write")

    /// 상태 행 하나만 바꿔 쓴다 — RemindersFile.upsert 와 같은 순서(저장 직전 재읽기 → id 병합 → .bak → atomic, 깨진 파일엔 안 씀).
    /// 폴더가 없으면 false 를 돌려주고 만들지 않는다. 새 행(직접 적기)은 모든 키를 붙인다. 같은 맥의 쓰기는 writeQueue 로 직렬
    @discardableResult
    static func upsertState(_ s: FollowupState, dir: String, initials: String, fields: Set<String> = statusFields) -> Bool {
        writeQueue.sync { upsertStateNow(s, dir: dir, initials: initials, fields: fields) }
    }
    /// 비동기판 — 큐 차례를 기다리는 동안 Swift 동시성 풀의 스레드를 막지 않는다 (0.41.0 검증 2 리뷰: Task.detached 안 writeQueue.sync)
    static func upsertStateAsync(_ s: FollowupState, dir: String, initials: String, fields: Set<String> = statusFields) async -> Bool {
        await withCheckedContinuation { c in writeQueue.async { c.resume(returning: upsertStateNow(s, dir: dir, initials: initials, fields: fields)) } }
    }
    private static func upsertStateNow(_ s: FollowupState, dir: String, initials: String, fields: Set<String>) -> Bool {
        guard isDir(dir), !initials.isEmpty else { return false }
        let path = statePath(dir, initials)
        let fm = FileManager.default
        var root: [String: Any] = ["items": []]
        if let d = fm.contents(atPath: path) {
            guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], o["items"] is [[String: Any]] else { return false }
            root = o
            try? d.write(to: URL(fileURLWithPath: path + ".bak"), options: .atomic)
        }
        var items = root["items"] as? [[String: Any]] ?? []
        guard let enc = try? JSONEncoder().encode(s), let mine = try? JSONSerialization.jsonObject(with: enc) as? [String: Any] else { return false }
        if let i = items.firstIndex(where: { ($0["id"] as? String) == s.id }) {
            items[i].merge(mine.filter { fields.contains($0.key) }) { _, n in n }
        } else {
            items.append(mine)
        }
        root["items"] = items
        let f = ISO8601DateFormatter(); f.timeZone = .current; f.formatOptions = [.withInternetDateTime]
        root["updated"] = f.string(from: Date())
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return false }
        return (try? out.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }
}

/// 판정 순수 함수 — 허브 카드·상태 한 줄 칩·관제탑·전광판·덤프·text-check 가 같은 함수를 쓴다
enum FollowupLogic {
    static let kinds = ["코멘트", "다음 마일스톤", "고칠 것", "새 모델 제안", "분석 계획", "기타"]
    /// 교수님 화면 판정 (결정 D-d) — Config 를 바꾸지 않으려고 코드 상수
    static let supervisors = ["SL"]
    /// 이니셜 확인 줄·'나:' 고르기의 선택지 — Members 이니셜 + 교수님(supervisors, 정본이 겹치면 하나). 교수님은 Members DB 에 없어서
    /// 이것이 없으면 교수님 맥에서 SL 을 고를 수 없고 '읽기' 보기에 못 들어간다 (0.41.0 검증 1 리뷰). 멤버를 아직 못 읽었으면 빈 목록(교수님 단추만 홀로 뜨지 않게)
    static func chooserInitials(members: [String], aliases: [String: String] = [:], supervisors: [String] = supervisors) -> [String] {
        var out: [String] = [], seen: Set<String> = []
        for m in members where !m.isEmpty && seen.insert(canon(m, aliases: aliases)).inserted { out.append(m) }
        guard !out.isEmpty else { return [] }
        for s in supervisors where seen.insert(canon(s, aliases: aliases)).inserted { out.append(s) }
        return out
    }
    /// 상태 한 줄 칩을 그날 확인한 날 (yyyy-MM-dd, 이 맥만)
    static let ackKey = "DeskHub.fuAck"

    enum View: String { case full = "내용", read = "읽기", counts = "수만" }
    struct Count: Equatable { var open = 0, confirmed = 0, proposed = 0 }

    static func canon(_ ini: String, aliases: [String: String]) -> String {
        let t = ini.trimmingCharacters(in: .whitespaces)
        return (aliases[t] ?? aliases[t.uppercased()] ?? t).uppercased()
    }
    /// 상태 행이 없거나 모르는 status 면 proposed
    static func effective(_ s: FollowupState?) -> String {
        guard let st = s?.status, ["confirmed", "done", "dismissed"].contains(st) else { return "proposed" }
        return st
    }
    static func isOpen(_ status: String) -> Bool { status == "proposed" || status == "confirmed" }
    /// 그 항목의 실효 상태 — 담당자(who) 상태 파일의 같은 id 행, 없으면 aka(옛 id) 행 중 가장 늦은 at (0.42.0 C2)
    static func status(of it: FollowupItem, states: [String: [FollowupState]], aliases: [String: String]) -> String {
        let w = canon(it.who, aliases: aliases)
        let rows = states[w] ?? []
        if let r = rows.last(where: { $0.id == it.id }) { return effective(r) }
        let aka = Set(it.aka ?? [])
        guard !aka.isEmpty else { return "proposed" }
        var best: FollowupState? = nil
        for r in rows where aka.contains(r.id) && (best == nil || (r.at ?? "") >= (best?.at ?? "")) { best = r }
        return effective(best)
    }
    /// '남은' 에 드는가 (0.42.0 C2) — 남은 상태이고, 출처 바뀜 항목이면 확정한 것만(옛 결과의 제안은 할 일이 아님)
    static func isLive(_ it: FollowupItem, _ status: String) -> Bool { isOpen(status) && (!it.isOrphan || status == "confirmed") }
    /// 항목 하나의 보기 — 확인한 이니셜 = who → 내용, 교수님 → 읽기, 그 밖(미확인 포함) → 수만. BHL ≠ BYL (이니셜 그대로 비교)
    static func visibility(me: String, chosen: Bool, who: String, aliases: [String: String], supervisors: [String] = supervisors) -> View {
        let m = canon(me, aliases: aliases)
        guard chosen, !m.isEmpty else { return .counts }
        if !who.isEmpty, m == canon(who, aliases: aliases) { return .full }
        if supervisors.map({ canon($0, aliases: aliases) }).contains(m) { return .read }
        return .counts
    }
    /// 카드 보기 — 교수님이면 읽기(연구실), 확인했으면 내용(나), 아니면 수만
    static func view(me: String, chosen: Bool, aliases: [String: String]) -> View {
        let m = canon(me, aliases: aliases)
        guard chosen, !m.isEmpty else { return .counts }
        return supervisors.map { canon($0, aliases: aliases) }.contains(m) ? .read : .full
    }
    /// 사람별 수 — 키 '' = 담당 미정
    static func counts(items: [FollowupItem], states: [String: [FollowupState]], aliases: [String: String]) -> [String: Count] {
        var out: [String: Count] = [:]
        for it in items {
            let st = status(of: it, states: states, aliases: aliases)
            guard isLive(it, st) else { continue }
            let w = it.who.isEmpty ? "" : canon(it.who, aliases: aliases)
            var c = out[w] ?? Count()
            c.open += 1
            if st == "confirmed" { c.confirmed += 1 } else { c.proposed += 1 }
            out[w] = c
        }
        return out
    }
    /// 남은 항목 중 가장 이른 회의 날짜
    static func oldest(items: [FollowupItem], states: [String: [FollowupState]], aliases: [String: String]) -> Date? {
        items.filter { isLive($0, status(of: $0, states: states, aliases: aliases)) }.compactMap(\.day).min()
    }
    /// '사람별' 줄 — 많은 순(같으면 이니셜), 0 생략, 상태 파일이 깨진 사람은 '?', 담당 미정은 끝. 없으면 '—'
    static func perPersonLine(_ c: [String: Count], unknown: Set<String> = []) -> String {
        let known = c.filter { !$0.key.isEmpty && !unknown.contains($0.key) && $0.value.open > 0 }
            .sorted { $0.value.open != $1.value.open ? $0.value.open > $1.value.open : $0.key < $1.key }
            .map { "\($0.key) \($0.value.open)" }
        let q = unknown.sorted().map { "\($0) ?" }
        let none = (c[""]?.open ?? 0) > 0 ? ["미정 \(c[""]!.open)"] : []
        let parts = known + q + none
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    static let kst: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Seoul")!; return c }()
    static func dayKey(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = kst.timeZone; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
    /// 내 다음 MM — 제목 낱말에 MM·Milestone·마일스톤 이 있고 내 이니셜(별칭 포함) 낱말이 있는 오늘 이후 첫 일정. 'MMR' 같은 부분 일치는 아님
    static func nextMM(events: [(Date, String)], me: String, aliases: [String: String], today: Date) -> Date? {
        let m = canon(me, aliases: aliases)
        guard !m.isEmpty else { return nil }
        let mine = Set([m] + aliases.filter { canon($0.value, aliases: aliases) == m }.map { $0.key.uppercased() })
        let start = kst.startOfDay(for: today)
        return events.filter { $0.0 >= start }.filter { e in
            let toks = e.1.uppercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
            let isMM = toks.contains("MM") || toks.contains("MILESTONE") || e.1.contains("마일스톤")
            return isMM && toks.contains { mine.contains($0) }
        }.map(\.0).min()
    }
    /// 상태 한 줄 칩 글 — 한국시간 달력으로 다음 MM·GRM 이 오늘(D-0)·내일(D-1)이면 '내일 MM' · '오늘 GRM' · '내일 MM·GRM'.
    /// 남은 0 이거나 그날 이미 확인(ack = 오늘)이면 nil. 둘이 다른 날이면 가까운 쪽
    static func remind(today: Date, mm: Date?, grm: Date?, open: Int, ack: String?) -> String? {
        guard open > 0, ack != dayKey(today) else { return nil }
        let t0 = kst.startOfDay(for: today)
        func gap(_ d: Date?) -> Int? {
            guard let d, let n = kst.dateComponents([.day], from: t0, to: kst.startOfDay(for: d)).day, n == 0 || n == 1 else { return nil }
            return n
        }
        func word(_ n: Int) -> String { n == 0 ? "오늘" : "내일" }
        switch (gap(mm), gap(grm)) {
        case let (a?, b?) where a == b: return word(a) + " MM·GRM"
        case let (a?, b?): return a < b ? word(a) + " MM" : word(b) + " GRM"
        case let (a?, nil): return word(a) + " MM"
        case let (nil, b?): return word(b) + " GRM"
        default: return nil
        }
    }
    /// 'M.d D-n' · '—'
    static func dayLabel(_ d: Date?) -> String { d.map { Hub.shortDay($0) + " " + Hub.dday($0) } ?? "—" }
}

// MARK: - 모델

extension NotionHubModel {
    var followupsDir: String { FollowupsFile.dir(cfg) }
    /// 확인한 이니셜(별칭 정본) — 미확인이면 HubPrefs.me 그대로
    var followupMe: String { FollowupLogic.canon(HubPrefs.me, aliases: cfg.initialsAliases) }
    var followupView: FollowupLogic.View { FollowupLogic.view(me: HubPrefs.me, chosen: HubPrefs.meChosen, aliases: cfg.initialsAliases) }
    func followupStatus(_ it: FollowupItem) -> String { FollowupLogic.status(of: it, states: followupStates, aliases: cfg.initialsAliases) }
    func followupVisibility(_ who: String) -> FollowupLogic.View {
        FollowupLogic.visibility(me: HubPrefs.me, chosen: HubPrefs.meChosen, who: who, aliases: cfg.initialsAliases)
    }
    /// proposals.json 의 항목 수 (직접 적은 것 제외)
    var followupProposalCount: Int { followups.filter { !$0.isSelf }.count }
    var followupCounts: [String: FollowupLogic.Count] { FollowupLogic.counts(items: followups, states: followupStates, aliases: cfg.initialsAliases) }
    /// 사람별 남은 수를 모를 이니셜 — 읽기 실패면 nil(전부 '?'), 아니면 상태 파일이 깨진 사람
    var followupUnknown: Set<String>? { followupRead == .ok ? followupCorrupt : nil }
    /// 남은 항목 — 확정 먼저(오래된 회의 순) → 제안(새 회의 순). who = nil 이면 모두
    func followupOpen(who: String?) -> [FollowupItem] {
        let a = cfg.initialsAliases
        let rows = followups.filter { it in
            (who.map { FollowupLogic.canon(it.who, aliases: a) == FollowupLogic.canon($0, aliases: a) && !it.who.isEmpty } ?? true)
                && FollowupLogic.isLive(it, followupStatus(it))
        }
        let conf = rows.filter { followupStatus($0) == "confirmed" }.sorted { ($0.meetingDate, $0.id) < ($1.meetingDate, $1.id) }
        let prop = rows.filter { followupStatus($0) == "proposed" }.sorted { $0.meetingDate != $1.meetingDate ? $0.meetingDate > $1.meetingDate : $0.id < $1.id }
        return conf + prop
    }
    /// 출처 바뀜 제안 (0.42.0 검증 1 리뷰) — 남은 수·oldest 에는 안 들지만(isLive false), 본인 보기에서 '확정'·'아님' 을 고를 수 있게
    /// 남은 항목 아래에 따로 보인다. 새 회의 순. 확정·아님이 없으면 30일 뒤 스크립트가 정리
    func followupOrphanProposals(who: String) -> [FollowupItem] {
        let a = cfg.initialsAliases
        return followups.filter { it in
            it.isOrphan && !it.who.isEmpty && FollowupLogic.canon(it.who, aliases: a) == FollowupLogic.canon(who, aliases: a)
                && followupStatus(it) == "proposed"
        }
        .sorted { $0.meetingDate != $1.meetingDate ? $0.meetingDate > $1.meetingDate : $0.id < $1.id }
    }
    /// 내 남은 항목 (보기 내용일 때만 의미)
    var myFollowups: [FollowupItem] { followupView == .full ? followupOpen(who: followupMe) : [] }
    /// 내 남은 수 — 모르면 nil('?')
    var myFollowupOpen: Int? {
        guard followupRead == .ok, !followupCorrupt.contains(followupMe) else { return nil }
        return followupCounts[followupMe]?.open ?? 0
    }
    /// 다음 MM(일정·캘린더 제목) · 다음 GRM(내가 발표자) — 리마인드 기준 (결정 D-c).
    /// 상태 한 줄이 그릴 때마다 부르므로 (이니셜·오늘·갱신 시각·캘린더 갱신) 이 같으면 지난 값 (캘린더 조회를 매 그림마다 하지 않게)
    func followupNextMeetings() -> (mm: Date?, grm: Date?) {
        let key = [HubPrefs.me, "\(today.timeIntervalSince1970)", "\(lastUpdated?.timeIntervalSince1970 ?? 0)", "\(events.count)", "\(grm.count)",
                   "\(todayCalendar?.isSettled ?? false)", "\(todayCalendar?.lastUpdated?.timeIntervalSince1970 ?? 0)", "\(ObjectIdentifier(self).hashValue)"].joined(separator: "|")
        if let c = FollowupNextCache.value, FollowupNextCache.key == key { return c }
        let v = computeNextMeetings()
        FollowupNextCache.key = key; FollowupNextCache.value = v
        return v
    }
    private func computeNextMeetings() -> (mm: Date?, grm: Date?) {
        var evs: [(Date, String)] = visibleEvents.map { ($0.date, $0.title) }
        if let cal = todayCalendar, cal.isSettled { evs += cal.upcoming(days: 21).map { ($0.start, $0.title) } }
        let mm = FollowupLogic.nextMM(events: evs, me: HubPrefs.me, aliases: cfg.initialsAliases, today: today)
        let grm = myMember(HubPrefs.me).flatMap { nextGRM(for: $0) }?.date
        return (mm, grm)
    }
    /// 상태 한 줄 칩 '그날 확인' (UserDefaults DeskHub.fuAck = yyyy-MM-dd, 이 맥) — 칩 클릭·--key fu-ack. 다음 날·다음 미팅이 바뀌면 다시 뜬다
    func ackFollowupReminder() {
        UserDefaults.standard.set(FollowupLogic.dayKey(today), forKey: FollowupLogic.ackKey)
        UsageLog.action("ack")
        objectWillChange.send()
    }
    /// 칩 글 — 보기 내용·남은 > 0·그날 미확인일 때만
    func followupReminder() -> String? {
        guard followupView == .full, let n = myFollowupOpen, n > 0 else { return nil }
        let nm = followupNextMeetings()
        return FollowupLogic.remind(today: today, mm: nm.mm, grm: nm.grm, open: n, ack: UserDefaults.standard.string(forKey: FollowupLogic.ackKey))
    }

    /// refresh 의 리마인더 읽기 바로 뒤 — 폴더·proposals·상태 파일 (메인 스레드 밖에서 읽기)
    func loadFollowups() async {
        let dir = followupsDir
        let snap = await Task.detached(priority: .utility) { FollowupsFile.load(dir) }.value
        var states: [String: [FollowupState]] = [:]
        var bad: Set<String> = []
        for (ini, s) in snap.states {
            switch s {
            case .ok(let rows): states[ini] = rows
            case .corrupt: bad.insert(ini); if let old = followupStates[ini] { states[ini] = old }   // 이전 값은 보이고 쓰기만 잠근다
            }
        }
        // 내 쓰기가 아직 진행 중이면 내 행은 메모리 값(낙관적)을 둔다 — 쓰기 전 파일로 되돌아가 '남은' 으로 깜빡이지 않게. 내 파일은 이 맥만 쓴다
        if FollowupWrites.inFlight > 0, !bad.contains(followupMe), let cur = followupStates[followupMe] { states[followupMe] = cur }
        let selfItems = states.keys.sorted().flatMap { ini in (states[ini] ?? []).compactMap { $0.selfItem(owner: ini) } }
        switch snap.proposals {
        case .ok(let items, let gen):
            followups = items + selfItems
            followupsGenerated = gen
            followupRead = .ok
            followupsLoadedOK = true
        case .missing(let why):
            followups = []
            followupsGenerated = nil
            followupRead = .unknown(why)
            followupsLoadedOK = false
        case .corrupt(let why):
            followupRead = .unknown(why)                   // 이전 목록은 그대로 두고 단추만 잠근다
        }
        followupStates = states
        followupCorrupt = bad
        followupStateFiles = snap.states.count
        if case .corrupt(let why) = snap.proposals { followupLocked = why }
        else if bad.contains(followupMe) { followupLocked = "state-\(followupMe).json 손상" }
        else { followupLocked = nil }
    }

    /// 쓰기 전 확인 — nil 이면 써도 됨. 확인한 이니셜 · 보기 내용(본인 항목) · 읽기 ok · 내 상태 파일 안 깨짐 · 폴더 있음
    func followupWriteBlock(who: String) -> String? {
        guard HubPrefs.meChosen, !followupMe.isEmpty else { return "이니셜 미확인" }
        guard followupVisibility(who) == .full else { return "본인 항목만" }
        guard followupRead == .ok else { return "읽기 " + followupRead.text }
        guard !followupCorrupt.contains(followupMe) else { return "내 상태 파일 손상" }
        guard FollowupsFile.isDir(followupsDir) else { return "폴더 없음" }
        return nil
    }

    /// 확정은 바로, 끝남·아님은 6초 미뤄(scheduleFollowup) 부른다 → state-<나>.json
    /// 순서는 commitInterest 와 같다: 메모리 먼저 → 쓰기(detached) → 실패면 원래 값 + 저장 실패 줄 → 다시 읽기
    func setFollowup(_ it: FollowupItem, status: String) {
        guard followupWriteBlock(who: it.who) == nil else { return }
        UsageLog.action(status == "done" ? "fu-done" : (status == "confirmed" ? "fu-confirm" : "fu-dismiss"))
        let me = followupMe
        let iso = ISO8601DateFormatter(); iso.timeZone = .current; iso.formatOptions = [.withInternetDateTime]
        let row = FollowupState(id: it.id, status: status, by: me, at: iso.string(from: Date()))
        let before = followupStates[me]
        var rows = before ?? []
        if let i = rows.firstIndex(where: { $0.id == it.id }) { rows[i].status = status; rows[i].by = me; rows[i].at = row.at } else { rows.append(row) }
        withAnimation(.easeOut(duration: 0.6)) { followupStates[me] = rows }
        followupSaveFailed = nil
        commitFollowup(row, initials: me, fields: FollowupsFile.statusFields, before: before)
    }
    /// 끝남·아님 — 6초 안에 되돌리기 (단추·시험 키 같은 경로)
    func scheduleFollowup(_ it: FollowupItem, status: String) {
        guard followupWriteBlock(who: it.who) == nil else { NSSound.beep(); return }
        let label = (status == "done" ? "끝남" : "아님") + " · " + String(it.text.prefix(24))
        followupCommits.schedule(id: it.id, label: label) { [weak self] in self?.setFollowup(it, status: status) }
    }
    /// MM 후속 직접 적기 — id 'fu-self-<8>', meeting MM, 오늘, 확정. 바로 쓴다
    func addFollowup(kind: String, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !t.isEmpty else { return }
        let me = followupMe
        guard followupWriteBlock(who: me) == nil else { NSSound.beep(); return }
        UsageLog.action("fu-add")
        let iso = ISO8601DateFormatter(); iso.timeZone = .current; iso.formatOptions = [.withInternetDateTime]
        let id = "fu-self-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        let row = FollowupState(id: id, status: "confirmed", by: me, at: iso.string(from: Date()), who: me, meeting: "MM",
                                meetingDate: FollowupLogic.dayKey(today), kind: FollowupLogic.kinds.contains(kind) ? kind : "코멘트",
                                text: String(t.prefix(120)))
        let before = followupStates[me]
        withAnimation(.easeOut(duration: 0.3)) {
            followupStates[me] = (before ?? []) + [row]
            if let item = row.selfItem(owner: me) { followups.append(item) }
        }
        followupSaveFailed = nil
        commitFollowup(row, initials: me, fields: Set(["id", "status", "by", "at", "who", "meeting", "meeting_date", "kind", "text"]), before: before)
    }
    private func commitFollowup(_ row: FollowupState, initials: String, fields: Set<String>, before: [FollowupState]?) {
        let dir = followupsDir
        let prior = before?.first { $0.id == row.id }
        FollowupWrites.inFlight += 1
        Task { @MainActor [weak self] in
            let ok = await FollowupsFile.upsertStateAsync(row, dir: dir, initials: initials, fields: fields)
            FollowupWrites.inFlight -= 1
            guard let self else { return }
            if !ok {
                // 이 행만 되돌린다 — 그 사이 누른 다른 행(낙관적 값·쓰기 중)은 그대로 (검증 1 리뷰: 통째로 before 로 되돌리면 다른 행이 빠짐)
                var rows = self.followupStates[initials] ?? []
                if let p = prior {
                    if let i = rows.firstIndex(where: { $0.id == row.id }) { rows[i] = p } else { rows.append(p) }
                } else {
                    rows.removeAll { $0.id == row.id }
                }
                self.followupStates[initials] = rows.isEmpty && before == nil ? nil : rows
                if row.id.hasPrefix("fu-self-") { self.followups.removeAll { $0.id == row.id } }
                self.followupSaveFailed = row.id
            }
            // 다시 읽기는 마지막 쓰기가 끝난 뒤 한 번 — 중간 파일로 아직 쓰는 중인 행을 덮지 않게
            if FollowupWrites.inFlight == 0 { await self.loadFollowups() }
        }
    }

    /// --key fu-… (시험 전용 — AppDelegate 가 DESKHUB_FOLLOWUPS 훅이 있을 때만 부른다). 단추와 같은 경로
    func followupKey(_ k: String) {
        if k == "fu-undo" { if let p = followupCommits.pending.last { followupCommits.undo(p.id) }; return }
        if k.hasPrefix("fu-add:") {
            let parts = String(k.dropFirst("fu-add:".count)).split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { NSSound.beep(); return }
            addFollowup(kind: parts[0], text: parts[1]); return
        }
        for (prefix, status) in [("fu-done:", "done"), ("fu-dismiss:", "dismissed"), ("fu-confirm:", "confirmed")] where k.hasPrefix(prefix) {
            let q = String(k.dropFirst(prefix.count))
            guard !q.isEmpty, let it = followups.first(where: { $0.id.hasPrefix(q) || $0.id.hasPrefix("fu-" + q) }) else { NSSound.beep(); return }
            if status == "confirmed" { setFollowup(it, status: status) } else { scheduleFollowup(it, status: status) }
            return
        }
        NSSound.beep()
    }

    /// text.txt [미팅 후속] — 항목 글은 보기 '내용'(본인)·'읽기'(교수님)일 때만
    func followupDumpLines() -> [String] {
        let f = DateFormatter(); f.dateFormat = "M.d HH:mm"
        var out = ["읽기 \(followupRead.text) · 생성 \(followupsGenerated.map { f.string(from: $0) } ?? "—") · 항목 \(followupProposalCount) · 상태 파일 \(followupStateFiles)"]
        let view = followupView
        let scope: [FollowupItem] = view == .full ? followupOpen(who: followupMe) : (view == .read ? followupOpen(who: nil) : [])
        let all = followupOpen(who: nil)
        let counted = view == .counts ? all : scope
        // 담당 미정은 아무도 닫을 수 없으니(쓰기는 본인 항목만) 연구실 남은 수에 넣지 않고 '미정 n' 으로 따로 (0.41.0 검증 1 리뷰)
        let assigned = view == .full ? counted : counted.filter { !$0.who.isEmpty }
        let remain: String = {
            if followupRead != .ok { return "?" }
            if view == .full, followupCorrupt.contains(followupMe) { return "?" }
            let c = assigned.filter { followupStatus($0) == "confirmed" }.count
            let none = counted.count - assigned.count
            return "\(assigned.count) (확정 \(c) · 제안 \(assigned.count - c))" + (none > 0 ? " · 미정 \(none)" : "")
        }()
        let old = assigned.compactMap(\.day).min().map { d in "\(Hub.shortDay(d))(\(Calendar.current.dateComponents([.day], from: d, to: today).day ?? 0)일)" } ?? "—"
        let nm = followupNextMeetings()
        out.append(["나 " + (followupMe.isEmpty ? "—" : followupMe), "보기 " + view.rawValue, (view == .counts ? "연구실 남은 " : "남은 ") + remain,
                    "가장 오래된 " + old, "다음 MM " + FollowupLogic.dayLabel(nm.mm), "GRM " + FollowupLogic.dayLabel(nm.grm),
                    "리마인드 " + (followupReminder() ?? "—")].joined(separator: " · "))
        for it in scope {
            var f = ["- " + it.id, followupStatus(it) == "confirmed" ? "확정" : "제안", it.kind, it.chip, it.text, "→" + it.linkKind]
            if view == .read { f.append(it.who.isEmpty ? "미정" : it.who) }
            out.append(f.joined(separator: " · "))
        }
        out.append("사람별: " + (followupUnknown == nil ? "?" : FollowupLogic.perPersonLine(followupCounts, unknown: followupUnknown ?? [])))
        // Plaud 원본 연결 (0.44.0 C2, #59) — 보인 항목 기준(수만 보기는 연구실 전체 수)
        let plaud = (view == .counts ? all : scope).map { $0.plaudTarget(grmRoot: cfg.nasGRMRoot)?.kind }
        out.append("Plaud 연결: 파일 \(plaud.filter { $0 == "file" }.count) · 폴더 \(plaud.filter { $0 == "folder" }.count) · 없음 \(plaud.filter { $0 == nil }.count)")
        // 출처 바뀜 (0.42.0 C2, R6) — 전체 orphan 수 · 그중 '남은'(확정) 수
        let orphans = followups.filter(\.isOrphan)
        out.append("출처 바뀜 \(orphans.count) (남음 \(orphans.filter { FollowupLogic.isLive($0, followupStatus($0)) }.count) · 내 화면 제안 \(followupView == .full ? followupOrphanProposals(who: followupMe).count : 0))")
        if let why = followupLocked { out.append("잠김 · " + why) }
        if let id = followupSaveFailed { out.append("저장 실패 · " + id) }
        if !followupCommits.pending.isEmpty { out.append("대기 \(followupCommits.pending.count)") }
        return out
    }
}

/// 진행 중인 상태 파일 쓰기 수 (모델 하나 · 메인 스레드) — 0 이 될 때만 다시 읽는다
@MainActor enum FollowupWrites {
    static var inFlight = 0
}

/// followupNextMeetings 의 마지막 값 (모델 하나 · 메인 스레드)
@MainActor enum FollowupNextCache {
    static var key = ""
    static var value: (mm: Date?, grm: Date?)?
}

// MARK: - text-check (main.swift TextCheck 가 부른다)

enum FollowupCheck {
    static let kinds: Set<String> = ["fu-status", "fu-visible", "fu-count", "fu-remind", "fu-mm", "fu-choices", "fu-orphan", "fu-aka", "fu-plaud"]
    private static func kv(_ input: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in input.components(separatedBy: ";") {
            let p = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if p.count == 2 { out[p[0].trimmingCharacters(in: .whitespaces)] = p[1] }
        }
        return out
    }
    private static func day(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = FollowupLogic.kst.timeZone; f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
    static func eval(_ kind: String, _ input: String, aliases: [String: String]) -> String {
        let k = kv(input)
        switch kind {
        // 'state=done' → done · 'state=' → proposed(상태 행 없음) · 모르는 값 → proposed
        case "fu-status":
            let s = k["state"] ?? ""
            return FollowupLogic.effective(s.isEmpty ? nil : FollowupState(id: "t", status: s))
        // 'me=;chosen=1|0;who=' → 내용 · 읽기 · 수만
        case "fu-visible":
            return FollowupLogic.visibility(me: k["me"] ?? "", chosen: k["chosen"] != "0", who: k["who"] ?? "", aliases: aliases).rawValue
        // 'JOP,BHL' (Members 이니셜) → 이니셜 확인 줄 선택지 'JOP · BHL · SL' — 교수님은 끝에 한 번만, 멤버가 없으면 —
        case "fu-choices":
            let ms = input.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let c = FollowupLogic.chooserInitials(members: ms, aliases: aliases)
            return c.isEmpty ? "—" : c.joined(separator: " · ")
        // 'BHL:proposed,BHL:done,JOP:confirmed' → 'BHL 1 · JOP 1' ('미정:proposed' = 담당 미정)
        case "fu-count":
            var items: [FollowupItem] = [], states: [String: [FollowupState]] = [:]
            for (i, part) in input.components(separatedBy: ",").enumerated() {
                let p = part.split(separator: ":").map { String($0).trimmingCharacters(in: .whitespaces) }
                guard p.count == 2 else { continue }
                let who = p[0] == "미정" ? "" : p[0]
                items.append(FollowupItem(id: "t\(i)", who: who, meeting: "GRM", meetingDate: "2026-10-07", kind: "기타", text: "t", source: [:]))
                if p[1] != "proposed", !who.isEmpty { states[FollowupLogic.canon(who, aliases: aliases), default: []].append(FollowupState(id: "t\(i)", status: p[1])) }
            }
            return FollowupLogic.perPersonLine(FollowupLogic.counts(items: items, states: states, aliases: aliases))
        // 출처 바뀜 (0.42.0 C2) — 'orphan=yyyy-MM-dd|빈 값;status=proposed|confirmed|done|dismissed' → 남음 · 숨김 · 끝남 · 버림 (FollowupLogic.isLive)
        case "fu-orphan":
            let st = k["status"] ?? ""
            var it = FollowupItem(id: "t", who: "JOP", meeting: "GRM", meetingDate: "2026-10-07", kind: "기타", text: "t", source: [:])
            it.orphanSince = (k["orphan"] ?? "").isEmpty ? nil : k["orphan"]
            let states = st.isEmpty || st == "proposed" ? [:] : ["JOP": [FollowupState(id: "t", status: st)]]
            let eff = FollowupLogic.status(of: it, states: states, aliases: aliases)
            if FollowupLogic.isLive(it, eff) { return "남음" }
            return eff == "done" ? "끝남" : (eff == "dismissed" ? "버림" : "숨김")
        // aka 상태 이어받기 (0.42.0 C2) — 'aka=옛id,…;rows=id:status@at|…' (항목 id 'fu-new', 담당 JOP) → 실효 상태
        // Plaud 원본 (0.44.0 C2, #59) — 'meeting=GRM|MM;date=yyyy-MM-dd;plaud=<경로>;file=0|1;folder=0|1' → file · folder · —
        case "fu-plaud":
            let t = PlaudTarget.resolve(plaud: k["plaud"], meeting: k["meeting"] ?? "", meetingDate: k["date"] ?? "", grmRoot: "/nas/GRM",
                                        fileExists: { _ in k["file"] == "1" }, dirExists: { _ in k["folder"] == "1" })
            return t?.kind ?? "—"
        case "fu-aka":
            var it = FollowupItem(id: "fu-new", who: "JOP", meeting: "GRM", meetingDate: "2026-10-07", kind: "기타", text: "t", source: [:])
            let aka = (k["aka"] ?? "").components(separatedBy: ",").filter { !$0.isEmpty }
            it.aka = aka.isEmpty ? nil : aka
            let rows: [FollowupState] = (k["rows"] ?? "").components(separatedBy: "|").compactMap { r in
                let a = r.split(separator: "@", maxSplits: 1).map(String.init)
                let q = (a.first ?? "").split(separator: ":", maxSplits: 1).map(String.init)
                guard q.count == 2 else { return nil }
                return FollowupState(id: q[0], status: q[1], at: a.count > 1 ? a[1] : nil)
            }
            return FollowupLogic.status(of: it, states: ["JOP": rows], aliases: aliases)
        // 'today=;mm=;grm=;open=;ack=' → 칩 글 또는 '—'
        case "fu-remind":
            guard let t = day(k["today"]) else { return "(입력 형식)" }
            return FollowupLogic.remind(today: t, mm: day(k["mm"]), grm: day(k["grm"]), open: Int(k["open"] ?? "") ?? 0, ack: k["ack"]) ?? "—"
        // 'me=;today=;events=yyyy-MM-dd 제목|…' → 'yyyy-MM-dd' 또는 '—'
        case "fu-mm":
            guard let t = day(k["today"]) else { return "(입력 형식)" }
            let evs: [(Date, String)] = (k["events"] ?? "").components(separatedBy: "|").compactMap { e in
                let p = e.split(separator: " ", maxSplits: 1).map(String.init)
                guard p.count == 2, let d = day(p[0]) else { return nil }
                return (d, p[1])
            }
            return FollowupLogic.nextMM(events: evs, me: k["me"] ?? "", aliases: aliases, today: t).map(FollowupLogic.dayKey) ?? "—"
        default: return "(모르는 종류 \(kind))"
        }
    }
}

// MARK: - 허브 카드 (0.41.0 C3, R1-d) — 랩 허브 열3 맨 위(회의록 위, 결정 D-a) · 나 뷰(펼친 판)

extension HubNear {
    /// 미팅 후속 — 보기 내용: 확정 ≤3 + 제안 ≤2 · 펼침 남은 전부. 보기 읽기(교수님): 사람마다 1행 · 펼침 전부(groupRows 와 같은 기준). 수만: 행 없음.
    /// 펼침에 상한을 두지 않는다 — 확정 8·제안 8 로 자르면 '더 보기 · n개' 가 실제 숨은 수보다 작고 9번째부터는 나 뷰에서도 닿지 못했다 (0.41.0 검증 1 리뷰).
    /// 허브 열3·나 뷰는 스크롤 칸이라 길어져도 된다. 접힘이 기본이고 '더 보기' 수 = 남은 − 보인 것
    static func followups(_ model: NotionHubModel) -> NearCut<FollowupItem> {
        switch model.followupView {
        case .full:
            let rows = model.followupOpen(who: model.followupMe)
            let conf = rows.filter { model.followupStatus($0) == "confirmed" }, prop = rows.filter { model.followupStatus($0) == "proposed" }
            let near = Array(conf.prefix(3)) + Array(prop.prefix(2))
            return NearCut(near: near, full: conf + prop, note: nil)
        case .read:
            let groups = model.followupGroups()
            return NearCut(near: groups.compactMap(\.items.first), full: groups.flatMap(\.items), note: nil)
        case .counts:
            return NearCut(near: [], full: [], note: nil)
        }
    }
}

extension NotionHubModel {
    /// 교수님 보기 — 사람별 묶음(많은 순, 같으면 이니셜, 미정은 끝)
    func followupGroups() -> [(who: String, items: [FollowupItem])] {
        let all = followupOpen(who: nil)
        let a = cfg.initialsAliases
        var by: [String: [FollowupItem]] = [:]
        for it in all { by[it.who.isEmpty ? "" : FollowupLogic.canon(it.who, aliases: a), default: []].append(it) }
        return by.sorted { x, y in
            if x.key.isEmpty != y.key.isEmpty { return !x.key.isEmpty }
            return x.value.count != y.value.count ? x.value.count > y.value.count : x.key < y.key
        }.map { ($0.key, $0.value) }
    }
    /// 'fu-mine' 배지 행 — 내 제안(상태 무관) id → hash(meeting_date|kind|text). proposals 를 제대로 읽었을 때만(빈 기준선 방지).
    /// 내 상태 변경·직접 적기는 해시에 들어가지 않으므로 '새' 로 세지 않는다
    func followupSeenRows(me: String) -> [String: String]? {
        guard followupsLoadedOK, !me.isEmpty else { return nil }
        let m = FollowupLogic.canon(me, aliases: cfg.initialsAliases)
        var out: [String: String] = [:]
        for it in followups where !it.isSelf && FollowupLogic.canon(it.who, aliases: cfg.initialsAliases) == m && !it.who.isEmpty {
            out[it.id] = SeenCards.hash([it.meetingDate, it.kind, it.text])
        }
        return out
    }
    /// 요약 칸 — (라벨, 값). 못 읽었으면 nil
    func followupSummaryParts() -> [(String, String)]? {
        let view = followupView
        if followupRead != .ok { return nil }
        if view == .full, followupCorrupt.contains(followupMe) { return nil }
        let all = view == .full ? followupOpen(who: followupMe) : followupOpen(who: nil)
        // 담당 미정은 아무도 닫을 수 없으니(쓰기는 본인 항목만) 연구실 남은 수에서 빼고 '미정 n' 으로 따로 (0.41.0 검증 1 리뷰)
        let rows = view == .full ? all : all.filter { !$0.who.isEmpty }
        let unassigned = all.count - rows.count
        let prop = rows.filter { followupStatus($0) == "proposed" }.count
        var out: [(String, String)] = [(view == .full ? "남은" : "연구실 남은", "\(rows.count)")]
        if unassigned > 0 { out.append(("미정", "\(unassigned)")) }
        if view == .counts { return out }
        out.append(("제안", "\(prop)"))
        if let d = rows.compactMap(\.day).min() {
            out.append(("가장 오래된", "\(Hub.shortDay(d))(\(Calendar.current.dateComponents([.day], from: d, to: today).day ?? 0)일)"))
        }
        if view == .full {
            let nm = followupNextMeetings()
            out.append(("MM", nm.mm.map { Hub.shortDay($0) + " " + Hub.dday($0) } ?? "미정"))
            out.append(("GRM", nm.grm.map { Hub.shortDay($0) + " " + Hub.dday($0) } ?? "—"))
        }
        return out
    }
}

struct FollowupsCard: View {
    @ObservedObject var model: NotionHubModel
    /// 끝남·아님 6초 미룸 — 모델에 있어 뷰가 바뀌어도 잃지 않는다
    @ObservedObject private var commits: DelayedCommit
    /// 랩 허브만 — 확정 ≤3 + 제안 ≤2, 나머지는 '▸ 더 보기'(펼치면 남은 전부). 나 뷰는 false(펼친 판, 남은 전부)
    let nearOnly: Bool
    @Environment(\.cardStyle) private var cs
    @ObservedObject private var expansion = HubExpansion.shared
    /// 열1 바닥이 비면 다음 후속을 더 (HubFill, 0.44.0 검증 1) — '내 것' 보기만
    @ObservedObject private var fill = HubFill.shared
    @State private var adding = false
    @State private var draft = ""
    @State private var draftKind = "코멘트"
    @State private var askMe = false
    @FocusState private var focused: Bool

    init(model: NotionHubModel, nearOnly: Bool = false) {
        self.model = model; self.nearOnly = nearOnly
        _commits = ObservedObject(wrappedValue: model.followupCommits)
    }

    private var view: FollowupLogic.View { model.followupView }

    var body: some View {
        VStack(alignment: .leading, spacing: cs.gap) {
            SectionTitle(card: "followups", hint: "미팅 후속 · 보기: " + (view == .full ? "내 것" : (view == .read ? "연구실 읽기" : "개수만")), trailing: "Meeting Notes",
                         fresh: nearOnly ? model.cardTag("followups") : nil, badge: nearOnly && view == .full ? "fu-mine" : nil) {
                model.openInApp(id: model.cfg.meetingNotesDB)
            }
            VStack(spacing: 0) {
                summary.padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
                if let why = model.followupLocked {
                    Label(why + " · 체크 잠김 (.bak 확인)", systemImage: "lock.fill").font(.hub(cs.aux - 0.5)).foregroundStyle(Hub.text2)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, cs.rowH).padding(.bottom, cs.rowV)
                        .help("NAS 미팅 후속 파일을 읽지 못해 단추를 잠갔습니다 (파일은 건드리지 않음)")
                }
                if model.followupSaveFailed != nil {
                    HStack(spacing: 6) {
                        Label("저장 실패", systemImage: "exclamationmark.triangle").font(.hub(cs.aux - 0.5)).foregroundStyle(Hub.text)
                        Text("· 다시 눌러 주세요").font(.hub(cs.aux - 0.5)).foregroundStyle(Hub.text2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, cs.rowH).padding(.bottom, cs.rowV)
                }
                switch view {
                case .full: mineRows
                case .read: groupRows
                case .counts: countsRows
                }
                if nearOnly {
                    let cut = HubNear.followups(model)
                    CardFooter(caption: CardMetas.caption("followups", model), toggleKey: "followups", more: cut.toggleCount(open: expansion.isOpen("followups"), extra: view == .full ? (fill.extra["followups"] ?? 0) : 0))
                }
                // 되돌리기 줄은 카드 끝 제 줄에 (리마인더와 같은 자리) — 6초 동안만 한 줄 늘어남
                if !commits.pending.isEmpty { UndoToast(commits: commits).padding(6) }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
        }
        // 입력 칸·이니셜 확인 줄이 열3 을 늘리는 동안 채움 결정을 멈춘다 (논문 댓글 칸·학회 확인 줄과 같은 hold)
        .onChange(of: adding || askMe, initial: true) { _, on in if nearOnly { HubFill.shared.setHold("fu-input", col: "3", on) } }
        // 이니셜을 고르면 보기가 '내용' 으로 바뀌고 확인 줄은 사라진다 — askMe 가 남아 열3 hold 를 계속 잡지 않게. 입력 칸도 보기가 바뀌면 닫는다
        .onChange(of: view) { _, v in
            if v != .counts { askMe = false }
            if v != .full { adding = false; draft = "" }
        }
        .onDisappear { if nearOnly { HubFill.shared.setHold("fu-input", col: "3", false) } }
    }

    // MARK: 요약 줄 — 라벨 Hub.text2, 숫자 Hub.text 굵게. 좁으면 두 줄. 못 읽으면 '남은 ? · NAS 를 읽지 못해 체크 잠김'(적색 아님)

    @ViewBuilder private var summary: some View {
        if let parts = model.followupSummaryParts() {
            let first = Array(parts.prefix(3)), rest = Array(parts.dropFirst(3))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) { partsText(parts); Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 0) { partsText(first); Spacer(minLength: 0) }
                    if !rest.isEmpty { HStack(spacing: 0) { partsText(rest); Spacer(minLength: 0) } }
                }
            }
        } else {
            // NAS 는 붙어 있는데 추출 폴더·파일만 아직 없으면(첫 추출 전) 그렇게 말한다 — 'NAS 를 읽지 못해' 는 연결 문제일 때만
            let notYet = model.followupRead == .unknown("폴더 없음") || model.followupRead == .unknown("파일 없음")
            let mounted = FollowupsFile.isDir((model.followupsDir as NSString).deletingLastPathComponent)
            HStack(spacing: 0) {
                (Text("남은 ").foregroundStyle(Hub.text2) + Text("?").fontWeight(.bold).foregroundStyle(Hub.text)
                 + Text(notYet && mounted ? " · 추출 파일이 아직 없음 · 체크 잠김" : " · NAS 를 읽지 못해 체크 잠김").foregroundStyle(Hub.text2))
                    .font(.hub(cs.aux)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .help("연구실 공용 저장소(NAS) 연결을 확인하세요 — " + model.followupRead.text)
        }
    }
    private func partsText(_ p: [(String, String)]) -> some View {
        p.enumerated().reduce(Text("")) { acc, x in
            acc + (x.offset > 0 ? Text(" · ").foregroundStyle(Hub.text3) : Text(""))
                + Text(x.element.0 + " ").foregroundStyle(Hub.text2) + Text(x.element.1).fontWeight(.bold).foregroundStyle(Hub.text)
        }
        .font(.hub(cs.aux)).lineLimit(1).monospacedDigit()
    }

    // MARK: 보기 내용 — 확정 먼저(오래된 회의 순) → 제안(새 회의 순)

    @ViewBuilder private var mineRows: some View {
        let cut = HubNear.followups(model)
        let rows = nearOnly ? cut.shown(open: expansion.isOpen("followups"), extra: fill.extra["followups"] ?? 0) : cut.full
        if rows.isEmpty, model.followupRead == .ok {
            Text(model.loading ? "불러오는 중…" : "없음")
                .font(.hub(cs.aux)).foregroundStyle(Hub.text2).padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        ForEach(Array(rows.enumerated()), id: \.element.id) { i, it in
            RowDivider()
            row(it)
        }
        // 출처 바뀜 제안 — 남은 수에는 안 들지만 '확정'(할 일로 남기기)·'아님' 을 고를 수 있게 남은 항목 아래 (0.42.0 검증 1 리뷰)
        let orphans = model.followupOrphanProposals(who: model.followupMe)
        if !orphans.isEmpty {
            RowDivider()
            Text("출처 바뀜 \(orphans.count) — 남길 것만 확정")
                .font(.hub(cs.tag, weight: .medium)).foregroundStyle(Hub.text3)
                .padding(.horizontal, cs.rowH).padding(.top, cs.rowV)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("회의록·MM 파일이 바뀌어 다시 뽑은 결과에 없는 제안 — 남은 개수에 들지 않으며, 확정·아님이 없으면 30일 뒤 정리")
            if !nearOnly || expansion.isOpen("followups") { ForEach(orphans) { it in row(it) } }
        }
        if model.followupRead == .ok { RowDivider(); addRow }
    }

    private func row(_ it: FollowupItem) -> some View {
        let pending = commits.isPending(it.id)
        let proposal = model.followupStatus(it) == "proposed"
        return HStack(alignment: .top, spacing: 8) {
            Button { pending ? commits.undo(it.id) : model.scheduleFollowup(it, status: "done") } label: {
                Image(systemName: pending ? "checkmark.circle.fill" : "circle").font(.hub(14)).foregroundStyle(pending ? Hub.ok : Hub.text2)
            }
            .buttonStyle(.plain).help(pending ? "되돌리기" : "끝남으로 표시 — 6초 안에 되돌릴 수 있음")
            VStack(alignment: .leading, spacing: 4) {
                Text(it.text).font(.hub(cs.body, weight: proposal ? .regular : .medium)).lineSpacing(2).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true).strikethrough(pending)
                    .foregroundStyle(pending ? Hub.text3 : (proposal ? Hub.text2 : Hub.text)).help(it.text)
                HStack(spacing: 8) {
                    TypePill(text: it.kind)
                    sourceChip(it)
                    if proposal { Text("제안").font(.hub(cs.tag)).foregroundStyle(Hub.text3) }
                    Spacer(minLength: 4)
                    if proposal && !pending {
                        Button("확정") { model.setFollowup(it, status: "confirmed") }
                            .buttonStyle(.plain).font(.hub(cs.aux - 0.5, weight: .semibold)).foregroundStyle(Hub.ink)
                            .help("할 일로 남기기 — 바로 저장")
                        Button("아님") { model.scheduleFollowup(it, status: "dismissed") }
                            .buttonStyle(.plain).font(.hub(cs.aux - 0.5)).foregroundStyle(Hub.text2)
                            .help("후속 아님 — 버리기 (6초 안에 되돌리기)")
                    }
                }
            }
        }
        .opacity(pending ? 0.55 : 1)
        .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
    }

    @ViewBuilder private func sourceChip(_ it: FollowupItem) -> some View {
        Button { it.link?.open() } label: {
            HStack(spacing: 3) {
                Text(it.chip).lineLimit(1).fixedSize()
                if it.link != nil { Image(systemName: "arrow.up.forward") }
            }
            .font(.hub(cs.tag, weight: .medium)).foregroundStyle(Hub.text2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Hub.fillNeutral))
        }
        .buttonStyle(.plain).disabled(it.link == nil).help(it.link?.help ?? "직접 적은 항목")
        // Plaud 원본 ↗ — Finder 에서 녹취 파일(없으면 그날 transcript 폴더)을 선택 (0.44.0 C2, #59 JYK)
        if let t = it.plaudTarget(grmRoot: model.cfg.nasGRMRoot) {
            Button { t.reveal() } label: {
                HStack(spacing: 3) { Text("Plaud").lineLimit(1).fixedSize(); Image(systemName: "arrow.up.forward") }
                    .font(.hub(cs.tag, weight: .medium)).foregroundStyle(Hub.text2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Hub.fillNeutral))
            }
            .buttonStyle(.plain).help((t.isFile ? "Plaud 녹취 — " : "Plaud 녹취 폴더 — ") + t.path)
        }
        // 출처 바뀜 (0.42.0 C2, R6) — 적색 아님(Hub.text2)
        if it.isOrphan {
            Text("출처 바뀜").font(.hub(cs.tag)).foregroundStyle(Hub.text2).lineLimit(1).fixedSize()
                .help("회의록·MM 파일이 바뀌어 다시 뽑은 결과에 이 글이 없습니다 — 확정·끝남이 없으면 30일 뒤 정리")
        }
    }

    /// '＋ MM 후속 적기' — 제자리 입력 칸 + 종류 + 남기기(Enter). 지도교수님과의 개인 미팅(MM)은 기록이 거의 없어 이것이 주 경로 (결정 D-g)
    @ViewBuilder private var addRow: some View {
        if adding {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Menu {
                        ForEach(FollowupLogic.kinds, id: \.self) { k in Button(k) { draftKind = k } }
                    } label: { Text(draftKind).font(.hub(cs.aux)).lineLimit(1).fixedSize() }
                    .menuStyle(.borderlessButton).fixedSize()
                    TextField("MM 에서 나온 후속 한 줄", text: $draft)
                        .textFieldStyle(.roundedBorder).font(.hub(cs.aux)).focused($focused)
                        .onSubmit(submit)
                }
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Button("닫기") { adding = false; draft = "" }.buttonStyle(.plain).font(.hub(cs.aux - 0.5)).foregroundStyle(Hub.text2)
                    Button("남기기", action: submit).buttonStyle(.plain).font(.hub(cs.aux - 0.5, weight: .semibold)).foregroundStyle(Hub.ink)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
            .onAppear { focused = true }
        } else {
            Button { adding = true } label: {
                HStack(spacing: 4) { Image(systemName: "plus"); Text("MM 후속 적기") }
                    .font(.hub(cs.aux, weight: .medium)).foregroundStyle(Hub.text2)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
            .disabled(model.followupWriteBlock(who: model.followupMe) != nil)
            .help("지도교수님과의 개인 미팅(MM)에서 나온 할 일을 직접 남깁니다 — 본인 화면에만")
        }
    }
    private func submit() {
        let t = draft.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        model.addFollowup(kind: draftKind, text: t)
        draft = ""; adding = false
    }

    // MARK: 보기 읽기(교수님) — 사람별 머리 줄 + 접힘 1행/사람, 펼치면 전체. 단추·입력 없음

    @ViewBuilder private var groupRows: some View {
        let open = !nearOnly || expansion.isOpen("followups")
        let groups = model.followupGroups()
        if groups.isEmpty, model.followupRead == .ok {
            Text("없음").font(.hub(cs.aux)).foregroundStyle(Hub.text2).padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        ForEach(groups, id: \.who) { g in
            RowDivider()
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(g.who.isEmpty ? "미정" : g.who).font(.hub(cs.tag + 0.5, weight: .bold, design: .rounded)).foregroundStyle(Hub.ink)
                    Text("남은 \(g.items.count)" + (g.items.compactMap(\.day).min().map { " · 가장 오래된 " + Hub.shortDay($0) } ?? ""))
                        .font(.hub(cs.aux - 0.5)).foregroundStyle(Hub.text2).monospacedDigit()
                    Spacer(minLength: 0)
                }
                ForEach(open ? g.items : Array(g.items.prefix(1))) { it in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        TypePill(text: it.kind)
                        Text(it.text).font(.hub(cs.aux)).foregroundStyle(Hub.text).lineLimit(1).help(it.text)
                        Spacer(minLength: 4)
                        sourceChip(it)
                    }
                }
            }
            .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
        }
    }

    // MARK: 보기 수만 — 이니셜 확인 줄 + 연구실 남은 수

    @ViewBuilder private var countsRows: some View {
        RowDivider()
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("이니셜을 확인하면 내 미팅 후속이 보입니다").font(.hub(cs.aux)).foregroundStyle(Hub.text2).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(askMe ? "닫기" : "확인") { askMe.toggle() }.buttonStyle(.plain).font(.hub(cs.aux - 0.5, weight: .semibold)).foregroundStyle(Hub.ink)
            }
            if askMe { MeConfirmBar(model: model, compact: true) }
        }
        .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
    }
}

// MARK: - 관제탑 레일·Members 전광판 — 사람별 남은 수만 (0.41.0 C5, R1-d). 항목 글은 없다

extension NotionHubModel {
    /// 사람별 표 행 — [(이니셜|'미정', 남은 수 또는 nil('?'), 확정, 제안, 가장 오래된)] '사람별' 줄과 같은 순서(많은 순, 같으면 이니셜, ? 다음, 미정 끝)
    func followupPeopleRows() -> [(who: String, count: FollowupLogic.Count?, oldest: Date?)] {
        guard followupRead == .ok else { return [] }
        let a = cfg.initialsAliases
        let c = followupCounts
        let open = followupOpen(who: nil)
        func oldest(_ w: String) -> Date? { open.filter { (it: FollowupItem) in (it.who.isEmpty ? "" : FollowupLogic.canon(it.who, aliases: a)) == w }.compactMap(\.day).min() }
        let known = c.filter { !$0.key.isEmpty && !followupCorrupt.contains($0.key) && $0.value.open > 0 }
            .sorted { $0.value.open != $1.value.open ? $0.value.open > $1.value.open : $0.key < $1.key }
            .map { (who: $0.key, count: Optional($0.value), oldest: oldest($0.key)) }
        let q = followupCorrupt.sorted().map { (who: $0, count: FollowupLogic.Count?.none, oldest: Date?.none) }
        let none = (c[""]?.open ?? 0) > 0 ? [(who: "미정", count: c[""], oldest: oldest(""))] : []
        return known + q + none
    }
    /// 관제탑 접힌 줄 — '남은 N · JOP 3 · BHL 1 … · 미정 n'(0 생략) · 못 읽으면 'NAS 를 읽지 못함 ?'.
    /// N 에는 담당 미정을 넣지 않는다 — 아무도 닫을 수 없어 쌓이기만 하므로 끝에 '미정 n' 으로 따로 (0.41.0 검증 1 리뷰)
    func followupRailSummary() -> String {
        guard followupRead == .ok, let unknown = followupUnknown else { return "NAS 를 읽지 못함 ?" }
        let total = followupCounts.filter { !$0.key.isEmpty && !unknown.contains($0.key) }.values.reduce(0) { $0 + $1.open }
        let per = FollowupLogic.perPersonLine(followupCounts, unknown: unknown)
        return "남은 \(total)" + (unknown.isEmpty ? "" : "+?") + (per == "—" ? "" : " · " + per)
    }
    /// Members 전광판 칸 — 'n' · '?'(못 읽음·그 사람 상태 파일 손상) · '—'(0)
    func followupCountCell(_ initials: String) -> String {
        guard followupRead == .ok else { return "?" }
        let k = FollowupLogic.canon(initials, aliases: cfg.initialsAliases)
        if followupCorrupt.contains(k) { return "?" }
        let n = followupCounts[k]?.open ?? 0
        return n > 0 ? "\(n)" : "—"
    }
}

/// 관제탑 '미팅 후속' 레일 펼침 — 사람마다 한 줄 '이니셜 · 남은 n(확정 a · 제안 b) · 가장 오래된 M.d'. 항목 글 없음
struct FollowupCountsView: View {
    @ObservedObject var model: NotionHubModel
    @Environment(\.cardStyle) private var cs
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let rows = model.followupPeopleRows()
            if model.followupRead != .ok {
                Text("NAS 를 읽지 못함 ? — 연구실 공용 저장소 연결을 확인하세요").font(.hub(cs.aux)).foregroundStyle(Hub.text2)
                    .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
            } else if rows.isEmpty {
                Text("없음").font(.hub(cs.aux)).foregroundStyle(Hub.text2).padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
            }
            ForEach(Array(rows.enumerated()), id: \.element.who) { i, r in
                HStack(spacing: 8) {
                    Text(r.who).font(.hub(cs.tag + 0.5, weight: .bold, design: .rounded)).foregroundStyle(Hub.ink).frame(width: cs.col(44), alignment: .leading)
                    if let c = r.count {
                        (Text("남은 ").foregroundStyle(Hub.text2) + Text("\(c.open)").fontWeight(.bold).foregroundStyle(Hub.text)
                         + Text(" (확정 \(c.confirmed) · 제안 \(c.proposed))").foregroundStyle(Hub.text2))
                            .font(.hub(cs.aux)).monospacedDigit().lineLimit(1)
                        Spacer(minLength: 4)
                        Text(r.oldest.map { "가장 오래된 " + Hub.shortDay($0) } ?? "").font(.hub(cs.tag)).foregroundStyle(Hub.text3).lineLimit(1)
                    } else {
                        Text("? — 상태 파일을 읽지 못함").font(.hub(cs.aux)).foregroundStyle(Hub.text2)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
                if i < rows.count - 1 { RowDivider() }
            }
            RowDivider()
            Text("개수만 보입니다 — 항목 내용은 본인·교수님 화면에만. 평가가 아닙니다").font(.hub(cs.tag)).foregroundStyle(Hub.text3)
                .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
    }
}
