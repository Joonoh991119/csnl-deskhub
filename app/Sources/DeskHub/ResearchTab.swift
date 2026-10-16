import SwiftUI
import AppKit

// MARK: - 연구 탭 (0.39.0 C1, RT-TAB — 랩장 10-16 22:24 '최근 system neuroscience issue, 논문 추천과 소통 등이 이뤄질 섹션 미리 만들어놔')
// config 밖 가상 탭(NotionHubWidget.researchTab = 901) — Config.swift·사용자 config.json 은 그대로. 랩 허브 배치도 그대로.
// 왼쪽 '분야 최근 이슈', 오른쪽 논문 추천 카드 전체(PaperRecBoard — 허브·관제탑과 같은 보기·이니셜 UserDefaults 를 함께 씀).
// 폭 ≥ Hub.s(760) 이면 두 칸(같은 폭), 좁으면(세로 모니터) 위 45%·아래 55%. 고른 갈래는 windows.txt choices 'research 두 칸|위아래'

struct ResearchTabView: View {
    @ObservedObject var model: NotionHubModel

    var body: some View {
        Inner(model: model)
            .padding(HubSpace.outer)
            .environment(\.cardStyle, .large)
            .onAppear { UsageLog.action("tab-research") }   // 기록이 켜진 맥에서만, 이 맥 파일에만
    }

    private struct Inner: View {
        @ObservedObject var model: NotionHubModel
        @Environment(\.cardStyle) private var cs

        var body: some View {
            GeometryReader { g in
                if g.size.width >= Hub.s(760) {
                    HStack(alignment: .top, spacing: HubSpace.column) {
                        feedPane.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        papersPane.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    .layoutChoice("research", "두 칸")
                } else {
                    let h = max(0, g.size.height - HubSpace.card)
                    VStack(alignment: .leading, spacing: HubSpace.card) {
                        feedPane.frame(maxWidth: .infinity).frame(height: h * 0.45, alignment: .top)
                        papersPane.frame(maxWidth: .infinity).frame(height: h * 0.55, alignment: .top)
                    }
                    .layoutChoice("research", "위아래")
                }
            }
        }

        /// 분야 최근 이슈 — 자체 스크롤
        private var feedPane: some View {
            ScrollView(.vertical, showsIndicators: false) {
                IssueFeedCard(model: model)
            }
        }

        /// 논문 추천 전체(허브 nearOnly·probe 없음 — HubFill 과 무관) + 신선도 안내 + 오류 상태 줄(허브 footer 규칙: 아이콘만 적색).
        /// '같이 읽자' 단추(talk 켬)는 연구 탭에서만, 되돌리기 줄도 이 칸 아래에만 (0.39.0 C5)
        private var papersPane: some View {
            VStack(alignment: .leading, spacing: 6) {
                if model.papersFreshness?.state == .stale {
                    Text("새 추천은 입력 방식 결정 뒤 — 왼쪽 분야 최근 이슈에서 관심 주제 논문을 보세요")
                        .font(.hub(cs.aux)).foregroundStyle(Hub.text3).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                PaperRecBoard(model: model, talk: true).frame(maxHeight: .infinity)
                UndoToast(commits: model.talkCommits)
                if let e = model.error {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Hub.signal)
                        Text(e).lineLimit(1)
                    }
                    .font(.hub(11)).foregroundStyle(Hub.text2)
                }
            }
        }
    }

    /// text.txt [연구 탭] — 칸 · 분야 최근 이슈 · 논문 추천(보기 대상 · 편 수 · 신선도). 뷰와 같은 함수(PaperRecBoard.who·visible)
    @MainActor
    static func dumpLines(_ m: NotionHubModel) -> [String] {
        let who = PaperRecBoard.who(filter: HubPrefs.paperFilter, me: HubPrefs.me)
        let n = PaperRecBoard.visible(m, who: who).count
        return [
            "칸: 분야 최근 이슈 · 논문 추천",
            "분야 최근 이슈 · 행 \(IssueFeedCard.rows(m).count)",
            "논문 추천 · \(who) · \(n)편 · 신선도 \(m.papersFreshness?.text ?? "—")",
        ]
    }
}

/// text.txt [논문 소통] — '같이 읽자' (0.39.0 C5). 머리 '같이 읽자 n편 · 모임 후보 n편 · 대기 n', 행은 제안·대기가 있는 논문만
/// '제목 40 · 반응 n · 댓글 n · 같이 읽자 [BHL, JOP] · 모임 후보|— · 대기|—' (PaperComment.proposers·isNote — 뷰와 같은 함수)
enum PaperTalk {
    @MainActor static func dumpLines(_ m: NotionHubModel) -> [String] {
        let pending = Set(m.talkCommits.pending.map(\.id))
        var rows: [String] = []
        var proposed = 0, meetups = 0
        for p in m.papers {
            let cs = m.paperComments[p.id] ?? []
            let ps = PaperComment.proposers(cs)
            let wait = pending.contains(NotionHubModel.talkID(p))
            if !ps.isEmpty { proposed += 1 }
            if ps.count >= PaperComment.meetupMin { meetups += 1 }
            guard !ps.isEmpty || wait else { continue }
            rows.append([String(p.title.prefix(40)), "반응 \(cs.filter(\.isReaction).count)", "댓글 \(cs.filter(\.isNote).count)",
                         "같이 읽자 [" + (ps.isEmpty ? "—" : ps.joined(separator: ", ")) + "]",
                         ps.count >= PaperComment.meetupMin ? "모임 후보" : "—", wait ? "대기" : "—"].joined(separator: " · "))
        }
        let dry = NotionDryRun.path.map { " · 드라이런 " + ($0 as NSString).lastPathComponent } ?? ""
        return ["같이 읽자 \(proposed)편 · 모임 후보 \(meetups)편 · 대기 \(pending.count)" + dry] + rows
    }
}

/// 분야 최근 이슈 보기 — 관심만(기본) | 전체 (0.39.0 C3). 두 단추·--key feed:topic|all 이 같은 경로. 이 맥 UserDefaults DeskHub.feedFilter
final class FeedPrefs: ObservableObject {
    static let shared = FeedPrefs()
    static let defaultsKey = "DeskHub.feedFilter"
    @Published private(set) var filter: String
    private init() { filter = UserDefaults.standard.string(forKey: Self.defaultsKey) == "all" ? "all" : "topic" }
    var topicOnly: Bool { filter != "all" }
    func set(_ v: String) {
        guard v == "topic" || v == "all" else { NSSound.beep(); return }
        filter = v
        UserDefaults.standard.set(v, forKey: Self.defaultsKey)
    }
}

/// 분야 최근 이슈 — bioRxiv neuroscience 7일 (0.39.0 C2). 날짜 내림차순 40행 + '▸ 더 보기'. 행을 누르면 doi.org 원문, 툴팁은 초록 앞 300자.
/// 관심만(기본)·전체 두 단추, 행 끝 주제 칩(무채색, 최대 2 + '+n', 툴팁 '일치: 구') (0.39.0 C3).
/// 빈 상태는 받는 중·아직 받은 적 없음·7일 안 0건·관심 일치 없음 네 가지 — 지어낸 항목은 없다. 적색 없음
struct IssueFeedCard: View {
    @ObservedObject var model: NotionHubModel
    @ObservedObject private var expansion = HubExpansion.shared
    @ObservedObject private var prefs = FeedPrefs.shared
    @Environment(\.cardStyle) private var cs
    static let rowLimit = 40
    static let chipLimit = 2

    var body: some View {
        let all = Self.rows(model)
        let matched = all.filter { !FeedTopics.matches($0).isEmpty }
        let shown = prefs.topicOnly ? matched : all
        let open = expansion.isOpen("feed")
        let rows = open ? shown : Array(shown.prefix(Self.rowLimit))
        VStack(alignment: .leading, spacing: cs.gap) {
            SectionTitle(text: "분야 최근 이슈 · bioRxiv", trailing: "bioRxiv", fresh: model.feedFreshness) { HubLink.url(BioRxivFeed.collectionURL).open() }
            viewBar(matched: matched.count, all: all.count, got: Self.fetchedDays(model))
            if let n = model.feedNote {
                Text(n).font(.hub(cs.aux)).foregroundStyle(Hub.text2).fixedSize(horizontal: false, vertical: true)
                    .help(model.feedError ?? "")
            }
            VStack(spacing: 0) {
                if rows.isEmpty {
                    if prefs.topicOnly && !all.isEmpty {
                        // 관심 일치 0 — 누르면 전체 보기 (클릭 1회·제자리)
                        Button { prefs.set("all") } label: {
                            Text("최근 7일 관심 주제 일치 없음 — 전체 보기").font(.hub(cs.body)).foregroundStyle(Hub.text2)
                                .padding(cs.empty).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(Self.emptyText(model)).font(.hub(cs.body)).foregroundStyle(Hub.text2)
                            .padding(cs.empty).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, x in
                    row(x)
                    if i < rows.count - 1 { RowDivider() }
                }
                MoreToggle(key: "feed", more: max(0, shown.count - Self.rowLimit))
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// '관심만 n' | '전체 m' 두 단추(선택 = ink 0.12 바탕, 탭 단추와 같은 규칙) + 주제 초안 표시
    /// + 받은 적 있는데 확정할 수 있는 5일(오늘·어제 제외)을 다 못 받았으면 '받은 날 m/7'(무채색, 확정된 날만) — '최근 7일' 문구가 덜 받은 값을 7일처럼 보이지 않게 (0.39.0 검증 1)
    private func viewBar(matched: Int, all: Int, got: Int) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                viewButton("topic", "관심만 \(matched)", help: "연구실 관심 주제(초안)에 걸린 프리프린트만 — 칩에 일치한 구")
                viewButton("all", "전체 \(all)", help: "최근 7일 bioRxiv neuroscience 새 프리프린트(v1) 전부")
            }
            .padding(2)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Hub.divider))
            if FeedTopics.file?.isDraft ?? false {
                Text("주제 초안").font(.hub(cs.tag)).foregroundStyle(Hub.text3)
                    .help("연구실 확인 전 — 랩 논문 제목에서 뽑은 초안")
            }
            if got < BioRxivFeed.windowDays - BioRxivFeed.openDays && (model.feedOKAt != nil || !model.feed.isEmpty) {
                Text("받은 날 \(got)/\(BioRxivFeed.windowDays)").font(.hub(cs.tag)).foregroundStyle(Hub.text3).monospacedDigit().lineLimit(1).fixedSize()
                    .help("최근 7일 중 끝까지 받아 확정된 날 — 오늘·어제는 아직 올라오는 날이라 갱신마다 다시 받고 세지 않습니다(최대 5/7). 남은 날은 다음 갱신에서 이어 받습니다")
            }
            Spacer(minLength: 0)
        }
    }

    private func viewButton(_ key: String, _ label: String, help: String) -> some View {
        let on = prefs.filter == key
        return Button { prefs.set(key) } label: {
            Text(label).font(.hub(cs.aux, weight: on ? .semibold : .regular)).monospacedDigit().lineLimit(1).fixedSize()
                .foregroundStyle(on ? Hub.text : Hub.text2)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Hub.ink.opacity(0.12) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }

    private func row(_ x: FeedItem) -> some View {
        let topics = FeedTopics.matches(x)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(x.shortDay).font(.hub(cs.aux)).foregroundStyle(Hub.text2).monospacedDigit().lineLimit(1)
                .frame(width: cs.col(44), alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(x.title).font(.hub(cs.body, weight: .semibold)).lineSpacing(2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text([x.firstAuthor, "bioRxiv"].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.hub(cs.aux)).foregroundStyle(Hub.text2).lineLimit(1)
                    ForEach(topics.prefix(Self.chipLimit), id: \.id) { t in chip(t.title, help: "일치: " + t.phrase) }
                    if topics.count > Self.chipLimit {
                        let rest = topics.dropFirst(Self.chipLimit)
                        chip("+\(rest.count)", help: rest.map { "\($0.title) — 일치: \($0.phrase)" }.joined(separator: "\n"))
                    }
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { HubLink.doi(x.doi).open() }
        .help(String(x.abstract.prefix(300)) + (x.abstract.count > 300 ? "…" : "") + "\n\ndoi:" + x.doi)
    }

    /// 주제 칩 — 무채색(fillNeutral 바탕, text2)
    private func chip(_ text: String, help: String) -> some View {
        Text(text).font(.hub(cs.tag, weight: .medium)).foregroundStyle(Hub.text2).lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Hub.fillNeutral))
            .help(help)
    }

    /// 7일 구간 안, 날짜 내림차순 — 뷰·덤프가 같은 함수
    @MainActor static func rows(_ m: NotionHubModel) -> [FeedItem] { BioRxivFeed.inWindow(m.feed, today: HubClock.today) }
    /// 7일 구간 중 확정된 날 수(끝까지 받았고 오늘·어제가 아닌 날) — 뷰 머리·덤프 '받은 날 m/7' 이 같은 함수. 다 받으면 5/7 (리뷰 2)
    @MainActor static func fetchedDays(_ m: NotionHubModel) -> Int {
        let today = HubClock.today
        let window = Set(BioRxivFeed.window(today: today))
        return BioRxivFeed.settled(m.feedFetchedDays, today: today).filter { window.contains($0) }.count
    }

    @MainActor static func emptyText(_ m: NotionHubModel) -> String {
        if m.feedLoading && m.feed.isEmpty { return "bioRxiv 에서 받는 중…" }
        if m.feed.isEmpty && m.feedOKAt == nil { return "아직 받은 적 없음 — 연결되면 자동으로 받습니다" }
        return "최근 7일 프리프린트 없음"
    }

    /// text.txt [분야 이슈] — 머리(출처·받기 횟수·마지막 호출 수·받은 날 m/7·7일 안 v1 n·마지막 갱신·관심 일치 n·보기) · 알림
    /// · 행 'M.d · 제목 60 · 저자 · doi:… · [id,…]'(지금 보기 기준)
    @MainActor static func dumpLines(_ m: NotionHubModel) -> [String] {
        let all = rows(m)
        let matched = all.filter { !FeedTopics.matches($0).isEmpty }
        let topicOnly = FeedPrefs.shared.topicOnly
        let rows = topicOnly ? matched : all
        let got = fetchedDays(m)
        let f = DateFormatter(); f.dateFormat = "M.d HH:mm"
        let last: String = m.feedOKAt.map { f.string(from: $0) } ?? "—"
        let topicNote: String = FeedTopics.file.map { "\($0.topics.count)개" + ($0.isDraft ? "(초안)" : "") } ?? "없음"
        let head: [String] = ["bioRxiv neuroscience", "출처 \(m.feedOrigin)", "받기 \(m.feedRuns)회", "마지막 호출 \(m.feedLastCalls)",
                              "받은 날 \(got)/\(BioRxivFeed.windowDays)", "7일 안 v1 \(all.count)", "마지막 갱신 " + last,
                              "관심 일치 \(matched.count)", "보기 " + (topicOnly ? "관심만" : "전체"), "주제 " + topicNote]
        var out = [head.joined(separator: " · ")]
        if let n = m.feedNote { out.append("알림 · " + n + (m.feedError.map { " (\($0))" } ?? "")) }
        if rows.isEmpty { out.append("빈 상태 · " + (topicOnly && !all.isEmpty ? "최근 7일 관심 주제 일치 없음 — 전체 보기" : emptyText(m))) }
        for x in rows {
            let ids: String = FeedTopics.matches(x).map(\.id).joined(separator: ",")
            let fields: [String] = [x.shortDay, String(x.title.prefix(60)), x.firstAuthor.isEmpty ? "—" : x.firstAuthor, "doi:" + x.doi, "[" + ids + "]"]
            out.append(fields.joined(separator: " · "))
        }
        return out
    }
}
