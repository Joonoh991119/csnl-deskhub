import SwiftUI
import AppKit

// MARK: - 공정 보드 뷰 (디자인 계획 D8 — docs/design-plan-2026-10-14.md §2 B, 안돈)
// 공정이 행, 단계가 칸. 막힌 칸만 적색(행당 1칸, 화면 3칸까지 — 나머지 막힘은 굵은 무채색), 판정 불가는 '?' 회색.
// 칸 클릭 = 그 단계의 원본, 막힌 칸에 행동 버튼 하나(공지 초안 등 — 실행 전 확인, 메일은 보내지 않음).
// '내 손' = 이 맥 사용자(또는 로스터 대상)의 칸만. 바닥에 지금·다음 띠 고정.

struct ProcessBoardView: View {
    @ObservedObject var model: NotionHubModel
    @State private var mineOnly = false
    @State private var confirm: ConfirmAction? = nil
    @State private var running = false
    @State private var lastReply: String? = nil

    struct ConfirmAction: Identifiable { let id = UUID(); let label: String; let action: String }

    private var me: String { HubPrefs.me }

    /// 판정 + 날짜 미정 그랜트 묶기 + '내 손' 거르기
    private var rows: [PipelineRow] {
        var all = PipelineEngine.evaluate(model, defs: PipelineDefs.load(), now: model.now, me: me)
        let undated = all.filter { $0.pipeline == "grant" && $0.due == nil }
        if undated.count > 1 {
            all.removeAll { $0.pipeline == "grant" && $0.due == nil }
            let stage = PipelineDef.Stage(id: "submit", label: "일정")
            all.append(PipelineRow(id: "grant-undated", pipeline: "grant", title: "그랜트 일정 미정 · \(undated.count)건",
                                   cells: [(stage, StageState(kind: .unknown, note: undated.map { $0.title.replacingOccurrences(of: "그랜트 ", with: "") }.joined(separator: " · "),
                                                              link: .nas((model.cfg.grantsFile as NSString).deletingLastPathComponent)))]))
        }
        guard mineOnly, let m = model.member(initials: me) else { return all }
        return all.filter { r in r.title.contains(m.name) || r.title.contains(m.initials) || r.cells.contains { $0.state.owner == m.initials } || r.pipeline == "papers" }
    }

    var body: some View {
        let rs = rows
        // 적색 예산: 정렬된 순서대로 행마다 첫 막힘 칸 하나, 화면 전체 3칸까지
        var budget = 3
        let redCells: Set<String> = Set(rs.compactMap { r -> String? in
            guard budget > 0, let c = r.cells.first(where: { $0.state.kind == .blocked }) else { return nil }
            budget -= 1; return r.id + "|" + c.stage.id
        })
        // R2-01: 바깥 ScrollView 없이 — 공정 표는 내용 높이(최대 절반), 아래 칸들이 남은 높이를 채운다. 세로(h/w>1.4)는 한 열로.
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let tall = h / max(w, 1) > 1.4
            let groups = zip(rs, rs.dropFirst()).filter { $0.pipeline != $1.pipeline }.count
            let tableH = min(h * 0.5, max(CGFloat(rs.count) * 34 + CGFloat(groups) * 9 + 12, 60))
            let orderRows = tall ? 8 : max(8, Int((h - tableH - 150) / 32))
            VStack(alignment: .leading, spacing: 10) {
                header(rs)
                // 지금·다음 띠는 머리 바로 아래 (R2, JYK: '맨 아래 일정은 잘 안 보임 → 맨 위로')
                if let cal = model.todayCalendar { NowNextBand(cal: cal).frame(height: 36) }
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rs.enumerated()), id: \.element.id) { i, r in
                            if i > 0 && rs[i - 1].pipeline != r.pipeline { Rectangle().fill(Hub.divider).frame(height: 1).padding(.vertical, 4) }
                            rowView(r, red: redCells, titleWidth: min(290, w * 0.35))
                        }
                        if rs.isEmpty { Text(mineOnly ? "내 손에 있는 칸 없음" : "공정 없음").foregroundStyle(Hub.text2).padding(12) }
                    }
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
                }
                .frame(maxHeight: tableH)
                if let r = lastReply { Text(r).font(.hub(11.5)).foregroundStyle(Hub.text2) }
                // 표 아래 남는 면: GRM 공정의 앞뒤 — 다음 순번 · 지난 GRM 산출물(회의록 펼침·Blitz). 가로는 좌우, 세로는 위아래
                if tall {
                    VStack(alignment: .leading, spacing: 12) {
                        upcomingOrder(rows: orderRows)
                        ScrollView(.vertical, showsIndicators: false) { MinutesCard(model: model, minutesExpanded: true) }.frame(maxHeight: .infinity)
                        BlitzCompact(model: model).frame(maxHeight: .infinity)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        upcomingOrder(rows: orderRows).frame(maxWidth: 420)
                        VStack(alignment: .leading, spacing: 12) {
                            ScrollView(.vertical, showsIndicators: false) { MinutesCard(model: model, minutesExpanded: true) }.frame(maxHeight: .infinity)
                            BlitzCompact(model: model).frame(maxHeight: .infinity)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                Text("DeskHub \(Hub.buildLabel)").font(.hub(10.5)).foregroundStyle(Hub.text3).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(12)
        .alert(item: $confirm) { c in
            Alert(title: Text(c.label), message: Text("메일은 보내지 않고 초안만 만듭니다 (Apps Script)."),
                  primaryButton: .default(Text("실행")) { run(c) }, secondaryButton: .cancel(Text("취소")))
        }
    }

    /// 다음 GRM 순번 — 보드에는 두 회만 있으므로 그 뒤를. 줄 수는 남은 높이로 (최소 8)
    private func upcomingOrder(rows: Int) -> some View {
        let next = Array(model.grm.filter { $0.date >= model.today }.dropFirst(2).prefix(rows))
        return VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "그다음 GRM 순번", trailing: "순번", action: { ViewModeStore.shared.mode = .grm })
            VStack(spacing: 0) {
                ForEach(Array(next.enumerated()), id: \.element.id) { i, g in
                    HStack(spacing: 10) {
                        Text(Hub.day(g.date)).font(.hub(12.5, weight: .semibold, design: .rounded)).monospacedDigit().frame(width: 44, alignment: .leading)
                        let rel = Hub.relative(g.date, now: model.now, hasTime: false)
                        Text(rel == Hub.shortDay(g.date) ? "" : rel).font(.hub(11)).foregroundStyle(Hub.text3).frame(width: 40, alignment: .leading)
                        Text(g.presenters.isEmpty ? "미정" : g.presenters).font(.hub(13, weight: .medium)).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .link(.notion(g.id))
                    if i < next.count - 1 { RowDivider() }
                }
                if next.isEmpty { Text("GRM Schedule 에 더 없음").font(.hub(12)).foregroundStyle(Hub.text3).padding(12) }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
        }
    }

    private func header(_ rs: [PipelineRow]) -> some View {
        let blocked = rs.filter { $0.blockedCount > 0 }.count
        return HStack(spacing: 12) {
            Text("공정 \(rs.count)").font(.hub(13, weight: .bold))
            // 적색 예산(화면 3곳)은 막힌 칸이 쓴다 — 머리 숫자는 굵은 무채색 (D14 린트)
            Text("막힘 \(blocked)").font(.hub(13, weight: .heavy)).foregroundStyle(blocked > 0 ? Hub.text : Hub.text3)
            Button { withAnimation(.easeOut(duration: 0.15)) { mineOnly.toggle() } } label: {
                Text(mineOnly ? "내 손만 · \(me)" : "내 손만 보기").font(.hub(12, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(mineOnly ? Hub.ink : Hub.surface))
                    .foregroundStyle(mineOnly ? Hub.onAccent : Hub.text2)
            }
            .buttonStyle(.plain).disabled(me.isEmpty).help(me.isEmpty ? "이 맥의 이니셜을 먼저 고르세요 (나 뷰)" : "\(me) 담당 칸만")
            Spacer()
            Text("칸 클릭 = 원본 · ■ 막힘 · ? 판정 근거 없음").font(.hub(11)).foregroundStyle(Hub.text3)
        }
    }

    private func rowView(_ r: PipelineRow, red: Set<String>, titleWidth: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Text(r.title).font(.hub(13, weight: r.blockedCount > 0 ? .semibold : .medium)).lineLimit(1)
                .frame(width: titleWidth, alignment: .leading).padding(.leading, 12)
                .help(r.title)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(r.cells.enumerated()), id: \.offset) { i, c in
                        if i > 0 { Rectangle().fill(Hub.divider).frame(width: 8, height: 1) }
                        cell(c.stage, c.state, isRed: red.contains(r.id + "|" + c.stage.id))
                    }
                }
                .padding(.vertical, 5)
            }
        }
        .opacity(r.past ? 0.45 : 1)
        .padding(.trailing, 8)
    }

    @ViewBuilder
    private func cell(_ s: PipelineDef.Stage, _ st: StageState, isRed: Bool) -> some View {
        let fg: Color = isRed ? Hub.signal : {
            switch st.kind {
            case .done: return Hub.text2
            case .blocked: return Hub.text
            case .unknown, .future: return Hub.text3
            case .todo, .progress: return Hub.text
            }
        }()
        HStack(spacing: 4) {
            Text(s.label).font(.hub(11.5, weight: .medium))
            switch st.kind {
            case .progress(let f):
                ZStack(alignment: .leading) {
                    Capsule().fill(Hub.divider).frame(width: 34, height: 5)
                    Capsule().fill(Hub.ink).frame(width: 34 * max(0.05, min(1, f)), height: 5)
                }
            default:
                Text(st.mark).font(.hub(11.5, weight: .bold))
            }
            if !st.note.isEmpty { Text(st.note).font(.hub(11)).lineLimit(1) }
            if !st.owner.isEmpty { Text(st.owner).font(.hub(10.5, weight: .bold, design: .rounded)).foregroundStyle(Hub.ink) }
            if st.kind == .blocked, let act = st.action, act == "공지 초안" {
                Button { confirm = ConfirmAction(label: "GRM 공지 초안 + PDF", action: "createAnnouncementDraftWithPDF") } label: {
                    Text(running ? "…" : act).font(.hub(10.5, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Hub.ink.opacity(0.14)))
                        .foregroundStyle(Hub.ink)
                }
                .buttonStyle(.plain).disabled(running)
            }
        }
        .foregroundStyle(fg)
        .fontWeight(st.kind == .blocked ? .bold : .regular)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isRed ? Hub.signal.opacity(0.12) : (st.kind == .blocked ? Hub.card : Color.clear)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(st.kind == .unknown ? Hub.divider : Color.clear, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .link(st.link)
        .help([s.label, st.note, st.link?.help ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
    }

    private func run(_ c: ConfirmAction) {
        running = true
        let env = Config.load().calendar.icsSSOTFile
        Task { @MainActor in
            let r = await AppsScript.call(.grm, action: c.action, env: env)
            lastReply = "\(c.label) · \(Hub.time(Date())) — \(r.text)"
            running = false
        }
    }
}
