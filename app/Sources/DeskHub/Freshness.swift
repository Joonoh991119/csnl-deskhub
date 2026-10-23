import SwiftUI

// MARK: - 카드별 신선도 (조사 P1-②, 2026-10-14)
// '갱신 HH:mm' 은 조회 시각일 뿐 내용 날짜가 아니라서 오래된 내용이 최신처럼 보였다.
// 카드 제목 옆에 '내용 날짜'와 상태를 작게 붙인다. 색은 무채색, 상태는 아이콘 모양으로.

struct Freshness: Equatable {
    enum State { case fresh, pending, stale }
    let state: State
    let text: String
    var help: String = ""
}

// MARK: - 멈춘 생산자 규칙 (0.40.0 C3, A2 — 정의서 A2-stopped·A2-late). papersFreshness 10일 규칙을 원천마다 기대 주기로 일반화
enum ProducerRule {
    /// 논문 추천 '정지' (공정 보드 생산 칸) — papersFreshness·Pipeline 의 10일
    static let papersStaleDays = 10
    /// 만성(30일 넘게 멈춘 추천)은 경보가 아니라 참조 레일 몫 — AlertEngine
    static let chronicDays = 30
    enum Kind: String { case ok = "정상", late = "지연", stopped = "멈춤" }
    struct Judge: Equatable { let age: Int; let ratio: Double; let kind: Kind }
    /// 경과일 = 오늘 − 내용 날짜(음수는 0), ×비 = 경과일 ÷ 기대 주기. ×1 이하 정상, ×2 이하 지연, 그 위 멈춤. 내용·주기가 없으면 nil
    static func judge(content: Date?, today: Date, cycleDays: Int) -> Judge? {
        guard let c = content, cycleDays > 0 else { return nil }
        let cal = Calendar.current
        let age = max(0, cal.dateComponents([.day], from: cal.startOfDay(for: c), to: cal.startOfDay(for: today)).day ?? 0)
        let ratio = Double(age) / Double(cycleDays)
        return Judge(age: age, ratio: ratio, kind: ratio > 2 ? .stopped : (ratio > 1 ? .late : .ok))
    }
    /// '56일 · ×8.0 · 멈춤' — 덤프·text-check 'A2-stopped'
    static func label(_ j: Judge) -> String { "\(j.age)일 · ×" + String(format: "%.1f", j.ratio) + " · " + j.kind.rawValue }
}

extension Freshness {
    /// 내용 날짜 꼬리표 '내용 M.d · n일'(n=0 이면 '내용 M.d') — ×1 이하 fresh(Hub.text3·checkmark), 넘으면 stale(Hub.text2·exclamationmark). 적색 없음 (A2-content)
    static func content(_ d: Date?, cycle: Int, today: Date, help: String = "") -> Freshness? {
        guard let d, let j = ProducerRule.judge(content: d, today: today, cycleDays: cycle) else { return nil }
        let text = "내용 " + Hub.shortDay(d) + (j.age == 0 ? "" : " · \(j.age)일")
        let why = "기대 주기 \(cycle)일 · " + ProducerRule.label(j)
        return Freshness(state: j.ratio <= 1 ? .fresh : .stale, text: text, help: help.isEmpty ? why : help + " — " + why)
    }
    /// 라이브 원천(캘린더·Notion 조회) — '갱신 HH:mm'
    static func live(_ d: Date?, help: String) -> Freshness? {
        guard let d else { return nil }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return Freshness(state: .fresh, text: "갱신 " + f.string(from: d), help: help)
    }
}

struct FreshnessTag: View {
    let f: Freshness
    /// 좁은 제목 줄에서는 아이콘만 (글은 도움말) — 제목이 잘리지 않게 (0.44.0 검증 1)
    var iconOnly = false
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: f.state == .fresh ? "checkmark.circle" : f.state == .pending ? "arrow.triangle.2.circlepath" : "exclamationmark.circle")
            if !iconOnly { Text(f.text) }
        }
        .font(.hub(10.5, weight: .medium))
        .lineLimit(1)   // 좁은 열에서 한 글자씩 줄바꿈 방지 (0.37.0 리뷰 2)
        .foregroundStyle(f.state == .stale ? Hub.text2 : Hub.text3)
        .help(iconOnly ? f.text + " — " + f.help : f.help)
    }
}

extension NotionHubModel {
    /// 회의록: NAS 녹취가 더 새면 pending, 가장 최근 회의록이 지난 GRM 보다 오래면 stale
    var minutesFreshness: Freshness? {
        if let d = minutesPending { return Freshness(state: .pending, text: Hub.day(d) + " 녹취 도착", help: "NAS 에 녹취가 왔고 Notion 회의록은 주간 정리 때 들어갑니다") }
        guard let latest = minutes.compactMap(\.date).max() else { return nil }
        let behind = lastGRM.map { Calendar.current.startOfDay(for: latest) < $0.date } ?? false
        return Freshness(state: behind ? .stale : .fresh, text: "내용 " + Hub.day(latest),
                         help: behind ? "지난 GRM(\(lastGRM.map { Hub.day($0.date) } ?? "")) 회의록이 아직 없음" : "가장 최근 회의록 날짜")
    }
    /// Paper Blitz: NAS 에서 바로 읽으면 pending, 지난 GRM 보다 오래면 stale
    var blitzFreshness: Freshness? {
        guard let d = blitzDate else { return nil }
        // 덱 이름이 PB_yymmdd 가 아니면(PB261021.pptx) 주간 정리가 Notion 에 넣지 않는다 — 이름을 고치라는 꼬리표 (0.44.0 #61, 적색 아님)
        let deck = blitzSource.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? blitzDeckPath
        if let deck, GRMMap.pbNameIssue((deck as NSString).lastPathComponent) != nil {
            return Freshness(state: .pending, text: "NAS 덱 · 이름 확인", help: (deck as NSString).lastPathComponent + " — 규칙 PB_yymmdd")
        }
        if blitzPending { return Freshness(state: .pending, text: "NAS 덱", help: "Notion Archive 반영 전 — NAS 의 PB 덱을 바로 읽음") }
        let behind = lastGRM.map { d < $0.date } ?? false
        return Freshness(state: behind ? .stale : .fresh, text: behind ? "지난 GRM 덱 없음?" : "최신",
                         help: behind ? "지난 GRM(\(lastGRM.map { Hub.day($0.date) } ?? "")) 의 PB 덱을 찾지 못함 — 휴강이거나 아직 안 올라옴" : "")
    }
    /// 분야 최근 이슈 (0.39.0 C2): 받는 중 pending · 성공 24시간 안 fresh '마지막 갱신 HH:mm' · 실패 또는 24시간 넘음 stale '마지막 갱신 M.d HH:mm'. 무채색
    var feedFreshness: Freshness? {
        if feedLoading { return Freshness(state: .pending, text: "받는 중", help: "bioRxiv 에서 받는 중 (이 맥)") }
        guard let ok = feedOKAt else { return nil }
        let f = DateFormatter()
        if feedNote == nil, Date().timeIntervalSince(ok) < 24 * 3600 {
            f.dateFormat = "HH:mm"
            return Freshness(state: .fresh, text: "마지막 갱신 " + f.string(from: ok), help: "bioRxiv 에서 받은 시각 (이 맥, 하루 두 번)")
        }
        f.dateFormat = "M.d HH:mm"
        return Freshness(state: .stale, text: "마지막 갱신 " + f.string(from: ok),
                         help: feedNote != nil ? "받기 실패 — 마지막으로 받은 목록을 보이는 중" : "24시간 넘게 새로 받지 못함")
    }
    /// 논문 추천 생산자 멈춤 (0.40.0 C8, R4-fold) — 가장 최근 Sent At 이 기대 주기 7일의 ×2(14일)를 넘으면. 자료가 없으면(nil) 접지 않는다.
    /// 새 Sent At 이 들어오면 저절로 false → 네 자리(허브 열1·관제탑·안내판·나 뷰)가 원래 보드로 돌아간다
    var papersStopped: Bool {
        ProducerRule.judge(content: papers.compactMap(\.sentAt).max(), today: today, cycleDays: 7)?.kind == .stopped
    }
    /// 멈춘 날 'M.d' — 접힘 줄·덤프 '접힘(멈춤 6.1)'
    var papersStoppedSince: String { papers.compactMap(\.sentAt).max().map(Hub.shortDay) ?? "—" }
    /// 논문 추천: 가장 최근 보낸 날짜가 10일 넘으면 stale
    var papersFreshness: Freshness? {
        guard let d = papers.compactMap(\.sentAt).max() else { return nil }
        let days = Calendar.current.dateComponents([.day], from: d, to: today).day ?? 0
        return Freshness(state: days > 10 ? .stale : .fresh, text: days > 10 ? Hub.day(d) + " 이후 새 추천 없음" : Hub.day(d) + " 추천",
                         help: days > 10 ? "추천 생산자(P23)가 멈춰 있음 — GitHub #19" : "")
    }
}
