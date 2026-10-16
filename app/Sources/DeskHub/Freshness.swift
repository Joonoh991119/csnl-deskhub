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

struct FreshnessTag: View {
    let f: Freshness
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: f.state == .fresh ? "checkmark.circle" : f.state == .pending ? "arrow.triangle.2.circlepath" : "exclamationmark.circle")
            Text(f.text)
        }
        .font(.hub(10.5, weight: .medium))
        .lineLimit(1)   // 좁은 열에서 한 글자씩 줄바꿈 방지 (0.37.0 리뷰 2)
        .foregroundStyle(f.state == .stale ? Hub.text2 : Hub.text3)
        .help(f.help)
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
    /// 논문 추천: 가장 최근 보낸 날짜가 10일 넘으면 stale
    var papersFreshness: Freshness? {
        guard let d = papers.compactMap(\.sentAt).max() else { return nil }
        let days = Calendar.current.dateComponents([.day], from: d, to: today).day ?? 0
        return Freshness(state: days > 10 ? .stale : .fresh, text: days > 10 ? Hub.day(d) + " 이후 새 추천 없음" : Hub.day(d) + " 추천",
                         help: days > 10 ? "추천 생산자(P23)가 멈춰 있음 — GitHub #19" : "")
    }
}
