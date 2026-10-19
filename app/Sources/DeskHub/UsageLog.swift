import Foundation

// MARK: - 사용 기록 (디자인 계획 D13 — §3 P2-10, 뷰 A/B 의 판정 근거)
// **기본 꺼짐** — 랩장 결정 19 전까지 아무것도 쓰지 않는다. 켜기: 메뉴 '사용 기록' 또는 `defaults write kr.ac.snu.csnl.deskhub DeskHub.usageLog -bool true`
// 쓰는 곳: ~/Library/Application Support/DeskHub/UsageLog.jsonl (이 맥에만, NAS·네트워크로 보내지 않음). 이니셜만, 내용(제목)은 안 씀.
// 한 줄 = {"t": ISO, "view": "tower", "kind": …, "ms": 뷰를 띄운 뒤 첫 행동까지, "me": "JOP"(이 맥의 보기 렌즈), "dev": 1(개발·시험 실행)}
// kind (실제 호출과 같게, 0.40.0 C2): view · open · ack · done · snooze · key · interest · tab-research · talk
//   · fu-done · fu-dismiss · fu-confirm · fu-add (미팅 후속, 0.41.0 C2 — 항목 글은 쓰지 않음)
//   · panel(+ "panel": 패널 id — 허브 '더 보기' 키·관제탑 'tower:<id>'·band·grm-map·exp-keys) · search(횟수만, 검색어 없음) · render(첫 그림 ms, M5)
// dev = DESKHUB_ 환경변수가 있거나 실행 파일이 /Applications 밖 — 지표(M5·M6)에서 뺀다
// `DeskHub --usage <dir>` → 뷰별 표시 횟수·첫 행동까지 중앙값·행동 종류 요약.

@MainActor
enum UsageLog {
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "DeskHub.usageLog") }
        set { UserDefaults.standard.set(newValue, forKey: "DeskHub.usageLog") }
    }
    static var url: URL { Config.directory.appendingPathComponent("UsageLog.jsonl") }

    private static var viewShownAt = Date()
    private static var firstActionLogged = false

    /// 뷰가 바뀌었을 때
    static func viewShown(_ v: String) {
        viewShownAt = Date(); firstActionLogged = false
        write(["view": v, "kind": "view"])
    }

    /// 패널 열기 (0.40.0 C2) — id 만, 내용 없음
    static func panel(_ id: String) { write(["view": ViewModeStore.shared.mode.rawValue, "kind": "panel", "panel": id]) }
    /// NAS 검색 시작 — 횟수만 (검색어는 쓰지 않는다)
    static func search() { write(["view": ViewModeStore.shared.mode.rawValue, "kind": "search"]) }
    /// 첫 그림까지 ms (RenderClock, M5) — 앱 시작마다 한 번
    static func render(ms: Int, view: String) { write(["view": view, "kind": "render", "ms": ms]) }
    /// 개발·시험 실행 — DESKHUB_ 환경변수가 하나라도 있거나 /Applications 밖에서 실행
    static let isDev: Bool = ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("DESKHUB_") } || !Bundle.main.bundlePath.hasPrefix("/Applications/")

    /// 행동 — open(원본 열기) · ack(확인함) · done(끝남) · snooze(미루기 +7일) · key(키보드)
    static func action(_ kind: String) {
        var e: [String: Any] = ["view": ViewModeStore.shared.mode.rawValue, "kind": kind]
        if !firstActionLogged { e["ms"] = Int(Date().timeIntervalSince(viewShownAt) * 1000); firstActionLogged = true }
        write(e)
    }

    private static func write(_ e: [String: Any]) {
        guard enabled else { return }
        var e = e
        let f = ISO8601DateFormatter(); f.timeZone = .current
        e["t"] = f.string(from: Date()); e["me"] = HubPrefs.me
        if isDev { e["dev"] = 1 }
        guard let d = try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys]) else { return }
        let line = d + Data("\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: url) }
    }

    /// 주간 요약 텍스트
    static func summary(days: Int = 14) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return enabled ? "기록 없음 (켜져 있음, 아직 쓰인 줄 없음)" : "사용 기록 꺼짐 — 결정 19 전까지 쓰지 않음"
        }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let f = ISO8601DateFormatter()
        let rows: [[String: Any]] = text.split(separator: "\n").compactMap {
            guard let o = try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any],
                  let t = (o["t"] as? String).flatMap(f.date(from:)), t >= cutoff else { return nil }
            return o
        }
        var out = ["사용 기록 최근 \(days)일 — \(rows.count)줄" + (enabled ? "" : " (지금은 꺼짐)")]
        for (v, rs) in Dictionary(grouping: rows, by: { $0["view"] as? String ?? "?" }).sorted(by: { $0.key < $1.key }) {
            let shows = rs.filter { $0["kind"] as? String == "view" }.count
            let ms = rs.compactMap { $0["ms"] as? Int }.sorted()
            let med = ms.isEmpty ? "—" : String(format: "%.1f초", Double(ms[ms.count / 2]) / 1000)
            let kinds = Dictionary(grouping: rs.compactMap { $0["kind"] as? String }.filter { $0 != "view" }, by: { $0 }).mapValues(\.count)
            out.append("\(v): 표시 \(shows) · 첫 행동까지 중앙값 \(med) · " + kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " "))
        }
        return out.joined(separator: "\n")
    }
}
