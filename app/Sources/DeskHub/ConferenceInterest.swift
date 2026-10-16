import Foundation

// MARK: - 다가오는 학회 '관심' (0.37.0 C5, 랩장 10-16 18:12 '다가오는 학회에 관심있는 학생들이 체크를 하고, 그 사람들의 리스트가 노출되면')
// 저장: NAS Grant/_ssot/conference_interest.json — Notion 속성이 아니다(Notion 레코드·스키마는 사람이 고친다).
//   {"items":[{"id":"<학회키>|<이니셜>","conf":"<학회키>","name":"<학회>","who":"JOP","on":true,"at":"<ISO8601>"}],"updated":"…"}
// 학회키 = 학회 이름(소문자 글자·숫자만) + "@" + 개최 시작일 yyyy-MM-dd — 같은 학회가 Notion page id 와 NAS 'file-…' id 로 갈리므로 행 id 를 쓰지 않는다.
// 해제는 지우지 않고 on:false. 읽기·쓰기 규칙은 리마인더(RemindersFile)와 같다 — 관대 읽기, 저장 직전 재읽기, id 병합, .bak, atomic, 깨진 파일엔 안 씀

struct InterestItem: Codable, Hashable {
    var id: String
    var conf: String
    var name: String
    var who: String
    var on: Bool
    var at: String
}

enum InterestFile {
    enum LoadResult { case missing, corrupt(String), ok([InterestItem]) }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    /// 학회키 — 'Cosyne 2027' · 2027-03-04 → 'cosyne2027@2027-03-04'
    static func key(name: String, start: Date) -> String {
        let n = String(String.UnicodeScalarView(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
        return n + "@" + dayFormatter.string(from: start)
    }
    static func key(_ c: ConferenceRow) -> String { key(name: displayName(c), start: c.start) }
    static func displayName(_ c: ConferenceRow) -> String { c.conference.isEmpty ? (c.title.isEmpty ? "학회" : c.title) : c.conference }

    /// 항목 단위로 관대하게 — 한 항목이 깨져도 나머지는 살린다. 파일 자체가 형식이 다르면 corrupt
    static func load(_ path: String) -> LoadResult {
        guard let d = FileManager.default.contents(atPath: path) else { return .missing }
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let raw = o["items"] as? [[String: Any]] else {
            return .corrupt("관심 파일을 읽지 못함 — 체크 잠김")
        }
        return .ok(raw.compactMap { r in
            guard let data = try? JSONSerialization.data(withJSONObject: r) else { return nil }
            return try? JSONDecoder().decode(InterestItem.self, from: data)
        })
    }

    /// 학회키 → 관심 on 인 이니셜(정렬)
    static func byConference(_ items: [InterestItem]) -> [String: [String]] {
        var out: [String: Set<String>] = [:]
        for it in items where it.on && !it.who.isEmpty { out[it.conf, default: []].insert(it.who.uppercased()) }
        return out.mapValues { $0.sorted() }
    }

    /// 항목 하나만 바꿔 쓴다: 저장 직전에 다시 읽고 그 id 의 on·at·who·name 만 고치거나 새로 붙인다(다른 항목·모르는 키는 그대로).
    /// 쓰기 전 .bak 하나. 파일이 깨져 있으면 쓰지 않는다
    @discardableResult
    static func upsert(_ item: InterestItem, to path: String) -> Bool {
        let fm = FileManager.default
        var root: [String: Any] = ["items": []]
        if let d = fm.contents(atPath: path) {
            guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], o["items"] is [[String: Any]] else { return false }
            root = o
            try? d.write(to: URL(fileURLWithPath: path + ".bak"), options: .atomic)
        }
        var items = root["items"] as? [[String: Any]] ?? []
        guard let enc = try? JSONEncoder().encode(item), let mine = try? JSONSerialization.jsonObject(with: enc) as? [String: Any] else { return false }
        let fields: Set<String> = ["on", "at", "who", "name"]
        if let i = items.firstIndex(where: { ($0["id"] as? String) == item.id }) {
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

/// 마지막 저장 실패 — 학회 카드에 '관심 저장 실패 · 다시 시도' 한 줄
struct InterestFailure: Equatable { let key: String; let name: String; let on: Bool }

extension NotionHubModel {
    /// 테스트 훅 DESKHUB_CONF_INTEREST=<픽스처 경로> 면 NAS 대신 그 파일 (remindersPath 와 같은 방식, Config 그대로)
    var conferenceInterestPath: String {
        if let p = ProcessInfo.processInfo.environment["DESKHUB_CONF_INTEREST"], !p.isEmpty { return (p as NSString).expandingTildeInPath }
        return ((cfg.grantsFile as NSString).deletingLastPathComponent as NSString).appendingPathComponent("conference_interest.json")
    }

    /// 관심 파일 다시 읽기 — refresh 의 학회 합치기 뒤·쓰기 뒤 (다른 맥의 체크도 다음 갱신에 보임)
    func loadInterest() async {
        let p = conferenceInterestPath
        switch await Task.detached(priority: .utility, operation: { InterestFile.load(p) }).value {
        case .ok(let items): conferenceInterest = InterestFile.byConference(items); interestLocked = nil
        case .missing: conferenceInterest = [:]; interestLocked = nil
        case .corrupt(let why): interestLocked = why          // 이전 칩은 그대로 보이고 단추만 잠근다
        }
    }

    /// 화면에 보일 관심 이니셜 — 6초 대기 중이면 바뀔 상태로 (되돌리기 전까지)
    func interestNames(_ c: ConferenceRow) -> [String] {
        let key = InterestFile.key(c)
        var names = conferenceInterest[key] ?? []
        let me = HubPrefs.me.uppercased()
        if !me.isEmpty, interestCommits.isPending("ci-" + key), let target = interestTargets[key] {
            names.removeAll { $0 == me }
            if target { names = (names + [me]).sorted() }
        }
        return names
    }

    /// '관심' 단추·--key interest:<이름> — 내 상태를 뒤집는다. 이니셜을 확인하지 않았으면 확인 줄부터. 6초 안에 되돌릴 수 있다
    func toggleInterest(_ c: ConferenceRow) {
        let me = HubPrefs.me.uppercased()
        guard !me.isEmpty, HubPrefs.meChosen else { interestAskMe = true; return }
        guard interestLocked == nil else { return }
        let key = InterestFile.key(c), pid = "ci-" + key, name = InterestFile.displayName(c)
        // 대기 중에 다시 누르면 원래대로 — 되돌리기와 같다
        if interestCommits.isPending(pid) { interestCommits.undo(pid); return }
        let target = !(conferenceInterest[key] ?? []).contains(me)
        interestTargets[key] = target
        interestSaveFailed = nil
        UsageLog.action("interest")
        interestCommits.schedule(id: pid, label: "\(name) · " + (target ? "관심 표시" : "관심 해제")) { [weak self] in
            self?.commitInterest(InterestFailure(key: key, name: name, on: target))
        }
    }

    /// NAS 에 쓰기 (detached). 실패면 '관심 저장 실패 · 다시 시도'
    func commitInterest(_ f: InterestFailure) {
        let me = HubPrefs.me.uppercased()
        let iso = ISO8601DateFormatter(); iso.timeZone = .current; iso.formatOptions = [.withInternetDateTime]
        let item = InterestItem(id: f.key + "|" + me, conf: f.key, name: f.name, who: me, on: f.on, at: iso.string(from: Date()))
        let path = conferenceInterestPath
        interestSaveFailed = nil
        // 6초 대기가 끝나 예상 상태가 풀려도 칩이 깜빡이지 않게 모델을 먼저 목표 상태로 — 쓰기·다시 읽기 사이에
        // 다시 눌러도 목표가 갱신된 상태에서 계산된다(리마인더 setReminder 와 같은 순서). 실패면 원래대로 (검증 1 리뷰)
        let before = conferenceInterest[f.key]
        var names = (before ?? []).filter { $0 != me }
        if f.on { names = (names + [me]).sorted() }
        conferenceInterest[f.key] = names
        Task { @MainActor [weak self] in
            let ok = await Task.detached(priority: .utility) { InterestFile.upsert(item, to: path) }.value
            guard let self else { return }
            if !ok { self.interestSaveFailed = f; self.conferenceInterest[f.key] = before }
            await self.loadInterest()
        }
    }

    /// text.txt [학회 관심] — '<학회> · <학회키> · 관심 [JYK, SMJ] · 나 on|off'
    func interestDumpLines() -> [String] {
        let me = HubPrefs.me.uppercased()
        var out = conferences.map { c in
            let names = interestNames(c)
            return "\(InterestFile.displayName(c)) · \(InterestFile.key(c)) · 관심 [\(names.joined(separator: ", "))] · 나 " + (names.contains(me) ? "on" : "off")
        }
        if let why = interestLocked { out.append("잠김 · " + why) }
        if let f = interestSaveFailed { out.append("저장 실패 · \(f.name)") }
        return out
    }
}
