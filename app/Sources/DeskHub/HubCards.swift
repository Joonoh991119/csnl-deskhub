import SwiftUI
import AppKit

// 대시보드·여러 뷰에서 함께 쓰는 카드 (v24 멀티 뷰 — Dashboard 의 private var 에서 떼어 냄)

/// 회의록 (Plaud 녹음 요약). 기본은 가장 최근 하나, 펼치면 recentMinutesCount 개
struct MinutesCard: View {
    @ObservedObject var model: NotionHubModel
    @State var minutesExpanded = false
    /// 랩 허브만 — 펼침을 이 맥 저장소(HubExpansion 'minutes')로, 바는 '▸ 더 보기' (0.37.0 C2)
    var nearOnly = false
    @Environment(\.cardStyle) private var cs
    @ObservedObject private var expansion = HubExpansion.shared
    var body: some View {
        VStack(alignment: .leading, spacing: cs.gap) {
            SectionTitle(card: "minutes", trailing: "Meeting Notes", fresh: model.minutesFreshness) { model.openInApp(id: model.cfg.meetingNotesDB) }
            VStack(spacing: 0) {
                if let d = model.minutesPending {
                    HStack(spacing: 8) {
                        Text(Hub.day(d)).font(.hub(cs.aux, weight: .semibold, design: .rounded)).foregroundStyle(Hub.text2).monospacedDigit()
                            .frame(width: cs.col(Hub.dateColumn), alignment: .leading)
                        Image(systemName: "waveform").foregroundStyle(Hub.text3)
                        Text("녹취 도착 · 회의록 정리 전 (주간 정리 때 Notion 에 들어감)").font(.hub(cs.aux)).foregroundStyle(Hub.text2)
                        Spacer()
                    }
                    .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
                    RowDivider()
                }
                let cut = HubNear.minutes(model)
                let shownMinutes = nearOnly ? cut.shown(open: expansion.isOpen("minutes")) : Array(model.minutes.prefix(minutesExpanded ? model.cfg.recentMinutesCount : 1))
                ForEach(Array(shownMinutes.enumerated()), id: \.element.id) { i, m in
                    let h = model.minutesHeader(m)
                    Button { model.openInApp(id: m.id) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(m.date.map(Hub.day) ?? "—").font(.hub(cs.aux, weight: .semibold, design: .rounded)).foregroundStyle(Hub.text2).monospacedDigit()
                                    .frame(width: cs.col(Hub.dateColumn), alignment: .leading)
                                // 굵은 글씨: 발표자 | 발표 제목
                                (Text(h.who.isEmpty ? "" : h.who + "  |  ").foregroundStyle(Hub.ink) + Text(h.title))
                                    .font(.hub(cs.body, weight: .semibold)).lineSpacing(3).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                if !m.type.isEmpty && m.type != "GRM" { TypePill(text: m.type) }
                                if let r = m.recording {
                                    Button { NSWorkspace.shared.open(r) } label: { Image(systemName: "waveform.circle").font(.hub(13)) }
                                        .buttonStyle(.plain).foregroundStyle(Hub.text2).help("Plaud 녹음 열기")
                                }
                                if let mg = m.magazine {
                                    Button { NSWorkspace.shared.open(mg) } label: { Image(systemName: "book.closed").font(.hub(13)) }
                                        .buttonStyle(.plain).foregroundStyle(Hub.ink).help("이 주 GRM Magazine (PDF)")
                                }
                            }
                            // 얇은 글씨: 발표 핵심(주요 결과) 2~3줄 — Plaud 노트의 소제목에서. 없으면 결정 사항, 그것도 없으면 안내 한 줄
                            let bullets = !m.highlights.isEmpty ? m.highlights
                                : m.decisions.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                            if bullets.isEmpty {
                                Text("핵심 결과 정리 전 · 마우스를 올리면 요약").font(.hub(cs.aux)).foregroundStyle(Hub.text3).padding(.leading, cs.col(Hub.dateColumn) + 8)
                            } else {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(bullets.prefix(3).enumerated()), id: \.offset) { _, b in
                                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                                            Text("•").foregroundStyle(Hub.text3)
                                            Text(b).lineSpacing(2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                        }
                                        .font(.hub(cs.aux)).foregroundStyle(Hub.text2)
                                    }
                                }
                                .padding(.leading, cs.col(Hub.dateColumn) + 8)
                            }
                        }
                        .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV + 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help([m.decisions, m.summary.replacingOccurrences(of: "\\[[A-Z_0-9]+\\]\\s*", with: "", options: .regularExpression)].filter { !$0.isEmpty }.joined(separator: "\n\n"))
                    if i < shownMinutes.count - 1 { RowDivider() }
                }
                let more = min(model.minutes.count, model.cfg.recentMinutesCount) - 1
                if nearOnly { CardFooter(caption: CardMetas.caption("minutes", model), toggleKey: "minutes", more: cut.more) }
                else if more > 0 {
                    RowDivider()
                    Button { withAnimation(.easeOut(duration: 0.15)) { minutesExpanded.toggle() } } label: {
                        HStack(spacing: 4) {
                            Image(systemName: minutesExpanded ? "chevron.up" : "chevron.down")
                            Text(minutesExpanded ? "접기" : "펼치기 · 지난 회의록 \(more)개 더")
                        }
                        .font(.hub(cs.aux, weight: .medium)).foregroundStyle(Hub.text2)
                        .frame(maxWidth: .infinity).padding(.vertical, cs.rowV).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if model.minutes.isEmpty { Text(model.loading ? "불러오는 중…" : "없음").font(.hub(cs.body)).foregroundStyle(Hub.text2).padding(cs.empty).frame(maxWidth: .infinity, alignment: .leading) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// 오늘의 실험 — SLab 예약 · Prolific 진행(ACTIVE)·준비(UNPUBLISHED) 중 study (0.37.0 C4). 장비 예약은 EquipmentCard (0.40.0 C5)
struct ExperimentsCard: View {
    @ObservedObject var model: NotionHubModel
    /// 랩 허브만 — SLab·자원 + Prolific 진행 중 4행, 나머지는 '▸ 더 보기' (0.37.0 C2)
    var nearOnly = false
    @Environment(\.cardStyle) private var cs
    @ObservedObject private var expansion = HubExpansion.shared
    var body: some View {
        VStack(alignment: .leading, spacing: cs.gap) {
            // 꼬리표 = SLab 마지막 실험날짜(집계) — 허브만, 관제탑은 레일 줄에 (0.40.0 C3, A2)
            SectionTitle(card: "experiments", trailing: "SLab", fresh: nearOnly ? model.cardTag("experiments") : nil) { model.openInApp(id: model.cfg.slabDB) }
            VStack(spacing: 0) {
                // 빈 상태는 한 단어 (0.44.0 #71) — 설명 줄·'(SLab 예약 기준)' 삭제
                if model.experiments.isEmpty {
                    Text(model.loading ? "불러오는 중…" : "없음")
                        .font(.hub(cs.body, weight: .medium)).foregroundStyle(Hub.text2)
                        .padding(cs.empty)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Prolific 조회 실패(오류)만 행으로 (#17). '미연결'(토큰 없음)은 오류가 아니라 카드 끝 캡션 한 줄 (0.44.0 #56 BYL)
                let unlinked = model.prolificNote?.hasPrefix("Prolific 미연결") ?? false
                if let n = model.prolificNote, !unlinked {
                    if !model.experiments.isEmpty { RowDivider() }
                    HStack(spacing: 8) {
                        Text("Prolific").font(.hub(cs.tag, weight: .bold)).foregroundStyle(Hub.text2).frame(width: cs.col(48), alignment: .leading)
                        Text(n).font(.hub(cs.aux)).foregroundStyle(Hub.text2).lineLimit(1)
                        Spacer()
                        // 토큰 없음 = 상태(무채색), 조회 실패 = 오류(적색) — 적색은 마감·오류에만 (R-L2, 0.36.0).
                        // 지난 행이 남아 보이는 실패는 무채색 굵게 — 안내 줄의 'HH:mm 결과' 가 알리고, 마감 적색 3개인 날 4번째 적색이 되지 않게 (0.38.0 C5, 계획 §4-6)
                        if model.experiments.contains(where: { $0.source == "Prolific" }) {
                            Text("조회 실패").font(.hub(cs.tag, weight: .bold)).foregroundStyle(Hub.text)
                        } else {
                            Text("조회 실패").font(.hub(cs.tag, weight: .bold)).foregroundStyle(Hub.signal)
                        }
                    }
                    .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
                    .help("Prolific 토큰 공유 방식은 결정 대기 (GitHub #17)")
                }
                let cut = nearOnly ? HubNear.experiments(model) : nil
                let rows = cut.map { $0.shown(open: expansion.isOpen("experiments")) } ?? Array(model.experiments.prefix(6))
                // 접힘에 보일 행이 없고 준비 중만 있으면 한 줄로 알림 — 카드가 빈 것처럼 보이지 않게 (검증 1)
                if let cut, rows.isEmpty, cut.more > 0 {
                    if model.prolificNote != nil && !unlinked { RowDivider() }
                    // n = 실제 준비 중 수 — union(limit 6) 에 잘린 cut.more 가 아니라 (0.37.0 리뷰 2)
                    let prep = model.experiments.filter { $0.status == "준비 중" }.count
                    Text("오늘 예약·진행 중 없음 · 준비 중 \(prep)개는 더 보기")
                        .font(.hub(cs.body, weight: .medium)).foregroundStyle(Hub.text2).lineLimit(2)
                        .padding(cs.empty).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, x in
                    Button {
                        if let n = x.notionID { model.openInApp(id: n) } else if let u = x.url { NSWorkspace.shared.open(u) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(x.source).font(.hub(cs.tag, weight: .bold)).foregroundStyle(Hub.ink)
                                .frame(width: cs.col(48), alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(x.title).font(.hub(cs.body, weight: .semibold)).lineLimit(1)
                                if !x.detail.isEmpty { Text(x.detail).font(.hub(cs.aux)).foregroundStyle(Hub.text2).lineLimit(1) }
                            }
                            Spacer()
                            // 빈 실험자 칸 = 자료 빠짐(마감·오류 아님) → 무채색. 적색은 마감·오류에만 (검증 1)
                            if x.owner.isEmpty { Text("실험자 미확인").font(.hub(cs.tag, weight: .semibold)).foregroundStyle(Hub.text2).lineLimit(1).fixedSize() }
                            else { Text(x.owner).font(.hub(cs.tag, weight: .bold, design: .rounded)).foregroundStyle(Hub.ink) }
                            if !x.status.isEmpty { Text(x.status).font(.hub(cs.tag, weight: .bold)).foregroundStyle(x.status == "확정" || x.status == ProlificFilter.activeLabel ? Hub.ok : Hub.text2) }
                        }
                        .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if i < rows.count - 1 { RowDivider() }
                }
                if unlinked, let n = model.prolificNote {
                    Text("Prolific 미연결").font(.hub(cs.tag)).foregroundStyle(Hub.text3).lineLimit(1)
                        .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(n + " — 토큰 공유 방식은 결정 대기 (GitHub #17)")
                }
                if let cut { CardFooter(caption: CardMetas.caption("experiments", model), toggleKey: "experiments", more: cut.more) }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
        }
    }
}

/// 다가오는 학회 (Notion Conferences + NAS conferences_upcoming.json)
/// 0.37.0 C5: 행 오른쪽 '관심' 단추(내 이니셜을 NAS conference_interest.json 에, 6초 안에 되돌리기) · 제목 아래 관심 이니셜 칩
struct ConferencesCard: View {
    @ObservedObject var model: NotionHubModel
    var maxRows = 3
    /// 관제탑 레일: 마감 D-day 를 적색 대신 ink — 경보 열이 적색을 맡는다 (검증 1, 화면당 적색 ≤3)
    var quiet = false
    /// 랩 허브만 — 초록 마감 D≤14·개최 D≤30 최대 3, 나머지는 '▸ 더 보기' (0.37.0 C2)
    var nearOnly = false
    /// 일정 탭(1.0.0 A2) — 이름·장소·제목·초록 마감 글을 '…' 로 자르지 않고 줄바꿈 (검증 1: 1.5배 '토론토 (Metro…')
    var wrap = false
    @Environment(\.cardStyle) private var cs
    @ObservedObject private var expansion = HubExpansion.shared
    /// 열 바닥이 비면 다음 학회를 더 (HubFill, 0.38.0 C3)
    @ObservedObject private var fill = HubFill.shared
    /// 관심 표시·해제의 6초 미룸 — 모델에 두어 뷰를 바꿔도 잃지 않는다 (리마인더와 같은 방식)
    @ObservedObject private var commits: DelayedCommit
    /// 학회 상태(관심·제출 예정·제출함) — 칩 꼬리·단추 글 (0.44.0 #62)
    @ObservedObject private var statusStore = ConferenceStatusStore.shared

    init(model: NotionHubModel, maxRows: Int = 3, quiet: Bool = false, nearOnly: Bool = false, wrap: Bool = false) {
        self.model = model; self.maxRows = maxRows; self.quiet = quiet; self.nearOnly = nearOnly; self.wrap = wrap
        _commits = ObservedObject(wrappedValue: model.interestCommits)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: cs.gap) {
            let tag = nearOnly ? model.cardTag("conferences") : nil   // 학회 파일 생성일 (0.40.0 C3)
            if model.cfg.conferencesDB.isEmpty { SectionTitle(card: "conferences", fresh: tag) }
            else { SectionTitle(card: "conferences", trailing: "Notion", fresh: tag) { model.openInApp(id: model.cfg.conferencesDB) } }
            if model.interestAskMe && !HubPrefs.meChosen { MeConfirmBar(model: model, compact: true) }
            // 잠김 = 단추가 꺼진 상태 알림 → 무채색. 적색은 손댈 일이 있는 '저장 실패' 와 마감에 남긴다 — 깨진 파일 상태에서 허브 적색 5곳 (검증 1)
            if let why = model.interestLocked {
                Label(why, systemImage: "lock.fill").font(.hub(cs.aux - 0.5)).foregroundStyle(Hub.text2)
                    .help("NAS conference_interest.json 을 읽지 못해 관심 단추를 잠갔습니다 (파일은 건드리지 않음, .bak 확인)")
            }
            if let f = model.interestSaveFailed {
                HStack(spacing: 6) {
                    // 저장 실패도 '잠김' 줄과 같은 무채색 안내 + '다시 시도' — 허브 적색은 마감에만 (0.37.0 리뷰 2, qa C5)
                    Label("관심 저장 실패", systemImage: "exclamationmark.triangle").font(.hub(cs.aux - 0.5)).foregroundStyle(Hub.text).lineLimit(1)
                    Text("·").font(.hub(cs.aux - 0.5)).foregroundStyle(Hub.text3)
                    Button("다시 시도") { model.commitInterest(f) }.buttonStyle(.plain).font(.hub(cs.aux - 0.5, weight: .semibold)).foregroundStyle(Hub.ink)
                    Spacer(minLength: 4)
                    Text(f.name).font(.hub(cs.tag)).foregroundStyle(Hub.text3).lineLimit(1)
                }
                .help(model.conferenceInterestPath)
            }
            let cut = nearOnly ? HubNear.conferences(model, limit: min(model.cfg.conferencesCount, maxRows)) : nil
            let open = expansion.isOpen("conferences"), e = fill.extra["conferences"] ?? 0
            let rows = cut.map { $0.shown(open: open, extra: e) }
                ?? Array(model.conferences.prefix(min(model.cfg.conferencesCount, maxRows)))   // 바닥 줄이 가운데 칸을 누르지 않게 3행 (마감 가까운 순)
            VStack(spacing: 0) {
                if rows.isEmpty {
                    Text(model.loading && model.conferences.isEmpty ? "불러오는 중…" : "없음").font(.hub(cs.body, weight: .medium)).foregroundStyle(Hub.text2)
                        .padding(cs.empty)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, c in
                    row(c)
                    if i < rows.count - 1 { RowDivider() }
                }
                if let cut { CardFooter(caption: CardMetas.caption("conferences", model), toggleKey: "conferences", more: cut.toggleCount(open: open, extra: e)) }
                // 되돌리기 바는 카드 끝 제 줄에 — 겹치면 '▸ 더 보기' 글자와 포개진다 (검증 1). 6초 동안만 한 줄 늘어남
                if !commits.pending.isEmpty { UndoToast(commits: commits).padding(6) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 이니셜 확인 줄(MeConfirmBar)이 열3 을 늘리는 동안 채움 결정·넘침 고침을 멈춘다 (0.39.0 C0, 0.38.0 리뷰 medium) —
        // transient() 분기가 아니라 hold 방식이라 줄이 떠 있는 동안 1.1초 폴링이 없다. 이니셜을 고르면 조건이 false → 풀림
        .onChange(of: model.interestAskMe && !HubPrefs.meChosen, initial: true) { _, on in
            if nearOnly { HubFill.shared.setHold("conf-me", col: "3", on) }
        }
        .onDisappear { if nearOnly { HubFill.shared.setHold("conf-me", col: "3", false) } }
    }

    private func confName(_ c: ConferenceRow) -> some View {
        Text(c.conference.isEmpty ? "학회" : c.conference).font(.hub(cs.body, weight: .semibold)).foregroundStyle(Hub.text)
            .lineLimit(wrap ? nil : 1).fixedSize(horizontal: false, vertical: wrap).layoutPriority(2)
    }
    /// 형식·'국제' 는 줄바꿈 없이 고정 폭, 장소는 이상 폭 cs.col(56) — ViewThatFits 가 이름+꼬리표+장소 몇 글자로 한 줄 여부를 정하고, 장소는 남는 폭에서 잘린다.
    /// 꼬리표는 모두 한 모양 ConfTag — 남색 TypePill·굵은 '국제' 가 섞여 행마다 강약이 달라 보이던 것 (0.44.0 #66)
    @ViewBuilder private func confTagPills(_ c: ConferenceRow) -> some View {
        if !c.format.isEmpty { ConfTag(text: c.format) }
        if c.international { ConfTag(text: "국제") }
    }
    @ViewBuilder private func confTags(_ c: ConferenceRow) -> some View {
        confTagPills(c)
        if !c.location.isEmpty {
            Text(c.location).font(.hub(cs.aux)).foregroundStyle(Hub.text2).lineLimit(1)
                .frame(minWidth: 0, idealWidth: cs.col(56), maxWidth: .infinity, alignment: .leading).layoutPriority(-1)   // 이상 폭 0 이면 한 줄로 판정돼 장소가 '…' 만 남던 것 (리뷰 2)
        }
    }

    private func row(_ c: ConferenceRow) -> some View {
        let me = HubPrefs.me.uppercased()
        let st = model.confStatuses(c)
        let names = st.keys.sorted()
        let myState = me.isEmpty ? nil : st[me]
        let mine = myState != nil
        // 접수 중인 마감이 있으면 마감까지, 아니면 개최까지 — 색·라벨은 ConfRowStyle 한 규칙 (덤프와 같은 함수)
        let due = ConfRowStyle.due(c, today: model.today)
        let dateW = cs.col(76)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // 왼쪽(날짜·이름·장소·제목·마감) = 원본 링크
                Button { if let l = c.link { NSWorkspace.shared.open(l) } else { model.openInApp(id: c.id) } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Hub.range(c.start, c.end)).font(.hub(cs.aux)).monospacedDigit()
                            .lineLimit(1).frame(width: dateW, alignment: .leading).foregroundStyle(Hub.text2)
                        VStack(alignment: .leading, spacing: 1) {
                            // 이름이 먼저 폭을 받는다 — 이름+꼬리표가 한 줄에 다 들어가면 한 줄(장소는 남는 폭에서 잘림),
                            // 아니면 꼬리표('형식'·'국제'·장소)를 둘째 줄로 내려 이름이 잘리지 않게 (검증 1: 'Cosyne...'·1.3배 'C...'·1.6배 'A I · M L')
                            // 고른 갈래는 windows.txt 'choices: conf-row <학회> 한 줄|두 줄' (허브만, 0.38.0 C5)
                            let choice: String? = nearOnly ? "conf-row " + InterestFile.displayName(c) : nil
                            if wrap {
                                // 일정 탭: 늘 두 줄 — 꼬리표·장소는 둘째 줄에서 줄바꿈 (자르지 않음)
                                confName(c)
                                if !c.format.isEmpty || c.international || !c.location.isEmpty {
                                    // 장소가 꼬리표 옆에 한 줄로 안 들어가면 아랫줄로 — 좁은 열에서 한 글자씩 꺾이던 것 (1.0.0 검증 2)
                                    ViewThatFits(in: .horizontal) {
                                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                                            confTagPills(c)
                                            if !c.location.isEmpty { Text(c.location).font(.hub(cs.aux)).foregroundStyle(Hub.text2).lineLimit(1).fixedSize() }
                                        }
                                        // 꼬리표 옆에서 줄바꿈 — 장소 칸이 cs.col(120) 이상일 때만 (1.0배 화면은 그대로, 좁으면 아래 갈래)
                                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                                            confTagPills(c)
                                            if !c.location.isEmpty {
                                                Text(c.location).font(.hub(cs.aux)).foregroundStyle(Hub.text2).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                                                    .frame(minWidth: cs.col(120), idealWidth: cs.col(120), maxWidth: .infinity, alignment: .leading)
                                            }
                                        }
                                        VStack(alignment: .leading, spacing: 1) {
                                            if !c.format.isEmpty || c.international { HStack(alignment: .firstTextBaseline, spacing: 6) { confTagPills(c) } }
                                            if !c.location.isEmpty {
                                                Text(c.location).font(.hub(cs.aux)).foregroundStyle(Hub.text2).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                        }
                                    }
                                }
                            } else {
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 6) { confName(c); confTags(c) }
                                        .layoutChoice(choice, "한 줄")
                                    VStack(alignment: .leading, spacing: 1) {
                                        confName(c)
                                        if !c.format.isEmpty || c.international || !c.location.isEmpty { HStack(spacing: 6) { confTags(c) } }
                                    }
                                    .layoutChoice(choice, "두 줄")
                                }
                            }
                            if !c.title.isEmpty {
                                Text(c.title).font(.hub(cs.aux)).foregroundStyle(Hub.text2)
                                    .lineLimit(wrap ? nil : 1).fixedSize(horizontal: false, vertical: wrap)
                            }
                            if !c.deadlineLabel.isEmpty {
                                Text("초록 마감 " + (c.deadline.map { Hub.day($0) + " · " } ?? "") + c.deadlineLabel)
                                    .font(.hub(cs.aux)).foregroundStyle(Hub.text2)
                                    .lineLimit(wrap ? nil : 1).fixedSize(horizontal: false, vertical: wrap)
                            }
                        }
                        // 이름 칸이 남는 폭을 먼저 받는다 — 장소(maxWidth .infinity) 때문에 이 칸과 아래 Spacer 가 같은 유연도가 되어 폭을 반씩 나눴고,
                        // ViewThatFits 가 절반 폭으로 판정해 꼬리표를 둘째 줄로 자주 내렸다(1.0배 Cosyne, 추정 원인) (0.38.0 C5, M-VENUE)
                        .layoutPriority(1)
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 좁은 열(허브 가운데)에서도 D-day 칸은 고정 폭, 제목이 먼저 잘림
                VStack(alignment: .trailing, spacing: 1) {
                    // 적색은 접수 중인 초록 마감이 D≤3 일 때만 (0.35.0) — 개최일 D-day 는 마감이 아니다. 라벨은 늘 '마감' 또는 '개최' (0.44.0 #66)
                    Text(due.text).font(.hub(cs.tag, weight: .bold)).foregroundStyle(ConfRowStyle.color(due, quiet: quiet)).monospacedDigit().lineLimit(1)
                    Text(due.label).font(.hub(cs.tag - 1)).foregroundStyle(Hub.text3).lineLimit(1)
                }
                .frame(width: cs.col(44), alignment: .trailing)
            }
            // 상태 줄 — 날짜 칸만큼 들여 상태 단추(클릭 1회 = 한 단계: 관심 → 제출 예정 → 제출함 → 해제, 6초 안에 되돌리기, 결정 D-5)
            // + 표시한 사람 칩(관심 'JYK' · 예정 'JYK 예정' · 제출 'JYK 제출', 내 것은 남색 테두리). 단추 글 = 지금 내 상태, 도움말 = 다음 단계 (0.44.0 #62)
            HStack(alignment: .center, spacing: 6) {
                Button { model.toggleInterest(c) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: mine ? "hand.raised.fill" : "hand.raised")
                        Text(myState?.label ?? "관심")
                    }
                    .font(.hub(cs.tag, weight: .semibold)).foregroundStyle(mine ? Hub.ink : Hub.text2)
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(mine ? Hub.ink.opacity(0.12) : Color.clear))
                    .overlay(Capsule().stroke(mine ? Color.clear : Hub.divider))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.interestLocked != nil)
                .help(model.interestLocked != nil ? "관심 파일을 읽지 못해 잠김"
                      : "누르면 " + (ConfStatus.next(myState).map { "'\($0.label)'" } ?? "해제") + " — 클릭 1회 = 한 단계 (관심 → 제출 예정 → 제출함 → 해제, NAS, 6초 안에 되돌리기)")
                if !names.isEmpty {
                    FlowLayout(spacing: 4, lineSpacing: 3) {
                        ForEach(names, id: \.self) { n in ConfStatusChip(who: n, state: st[n] ?? .interest, mine: n == me) }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, dateW + 8)
        }
        .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
    }
}

// MARK: - 학회 행 강조 한 규칙 (0.44.0 C2, #66 BHL — 행마다 강약이 달라 보임)
// 이름 cs.body semibold Hub.text · 날짜 cs.aux text2 · 꼬리표(형식·국제)는 모두 ConfTag · D-n cs.tag bold 고정폭,
// 색은 '접수 중 마감 D≤3' 만 Hub.signal(관제탑 quiet 는 Hub.ink), 나머지 text2 · D-n 아래 라벨은 늘 '마감' 또는 '개최'
enum ConfRowStyle {
    struct Due: Equatable { let text: String; let label: String; let urgent: Bool }
    /// 접수 중인 초록 마감이 있으면 마감까지, 아니면 개최까지
    static func due(_ c: ConferenceRow, today: Date) -> Due {
        let open = c.deadline.flatMap { $0 >= today ? $0 : nil }
        let target = open ?? c.start
        let cd = Calendar.current.dateComponents([.day], from: today, to: target).day ?? 99
        return Due(text: Hub.dday(target), label: open != nil ? "마감" : "개최", urgent: open != nil && cd <= 3)
    }
    static func color(_ d: Due, quiet: Bool) -> Color { d.urgent ? (quiet ? Hub.ink : Hub.signal) : Hub.text2 }
    /// 덤프 '[학회 관심]' 색 이름
    static func colorName(_ d: Due, quiet: Bool) -> String { d.urgent ? (quiet ? "ink" : "signal") : "text2" }
}

/// 학회 꼬리표 한 모양 — 형식·국제 (cs.tag medium Hub.text2, Hub.fillNeutral 캡슐)
struct ConfTag: View {
    let text: String
    @Environment(\.cardStyle) private var cs
    var body: some View {
        Text(text).font(.hub(cs.tag, weight: .medium)).foregroundStyle(Hub.text2).lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Hub.fillNeutral))
    }
}

/// 학회 상태 칩 — 관심 'JYK' · 예정 'JYK 예정' · 제출 'JYK 제출' ('제출' 은 submitted 인 사람만). 모양은 InitialChip 과 같다
struct ConfStatusChip: View {
    let who: String
    let state: ConfStatus
    var mine = false
    @Environment(\.cardStyle) private var cs
    var body: some View {
        Text(who + state.chipSuffix).font(.hub(cs.tag - 0.5, weight: .bold, design: .rounded)).lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Hub.fillNeutral))
            .overlay(Capsule().stroke(mine ? Hub.ink : Color.clear, lineWidth: 1.5))
            .foregroundStyle(mine ? Hub.ink : Hub.text2)
            .help("\(who)\(mine ? " · 나" : "") — \(state.label)")
    }
}
