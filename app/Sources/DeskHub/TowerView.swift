import SwiftUI
import AppKit

// MARK: - 관제탑 뷰 (디자인 계획 D4 — docs/design-plan-2026-10-14.md §2 A)
// 원리: 화면에 올리기 전에 경보(W/C/A)와 참조를 가른다.
//   왼쪽 위 = 경보 열(AlertEngine) — 보는 시간은 경보 수에 비례, 0 이면 한 줄 '경보 없음'
//   머리 = 오늘 시간 띠(지금 위치 + 다음 두 일정)
//   오른쪽 = 참조 레일 — 10종을 한 줄 요약으로, 누르면 그 자리에서 펼침(하나만), ↗ 는 원본
// 점멸 없음. signal 색은 W 표시에만.

struct TowerView: View {
    @ObservedObject var model: NotionHubModel
    @ObservedObject private var commits: DelayedCommit
    /// 펼친 섹션 — 열마다 관련 있는 것(TowerRelevance)을 하루 한 번 자동으로, 그 뒤는 사용자가 (SMJ #27, 0.35.0). 데이터 전 첫 프레임은 모두 접힘
    @State private var expanded: Set<String> = []
    /// 자동 펼침을 결정한 날 — 하루 한 번만 (갱신마다 레이아웃이 바뀌지 않게)
    @State private var decidedDay: Date? = nil
    /// 사용자가 레일을 직접 펴거나 접은 날 — 그날은 자동 결정을 하지 않는다. 날짜로 두어 첫 결정 전에 만져도 다음 날엔 풀린다 (검증 1 리뷰)
    @State private var touchedDay: Date? = nil
    /// 확인함(ack) — C·A 만, 맥 단위 로컬, 7일 뒤 풀림 (W 는 ack 불가 — 처리해야 사라짐)
    @State private var acks: [String: Double] = AlertAck.load()
    @State private var showAcked = false
    /// 로스터 띠에서 고른 '대상' — 10분 동안 그 사람 기준으로 C·A 정렬·'내 것' 판정 (공용 맥 개인화)
    @State private var target: String? = nil
    @State private var targetUntil: Date? = nil
    /// 펼친 섹션이 남은 높이를 채우게 — 레일 열 높이 (GeometryReader 실측, 첫 프레임은 0)
    @State private var railHeight: CGFloat = 0
    /// 키보드로 고른 경보 (j/k)
    @State private var sel: Int? = nil
    @ObservedObject private var bus = KeyBus.shared

    init(model: NotionHubModel) {
        self.model = model
        _commits = ObservedObject(wrappedValue: model.reminderCommits)
    }

    private var who: String {
        if let t = target, let u = targetUntil, model.now < u { return t }
        return HubPrefs.me
    }
    private var allAlerts: AlertSet { AlertEngine.evaluate(model, cal: model.todayCalendar, now: model.now, me: who) }

    var body: some View {
        let full = allAlerts
        let acked = full.alerts.filter { $0.level != .warning && acks[AlertAck.key($0)] != nil }
        let set = AlertSet(alerts: full.alerts.filter { a in !acked.contains(where: { $0.id == a.id }) }, overflow: full.overflow)
        GeometryReader { geo in
            let tall = geo.size.height / max(geo.size.width, 1) > 1.4
            // 가로: 경보 열은 440 이상, 넓은 화면(5K)에선 폭의 28% (R2-01 BHL — 오른쪽만 넓어지지 않게)
            let alertWidth = max(440, geo.size.width * 0.28)
            VStack(alignment: .leading, spacing: 10) {
                // 연구실 상태 한 줄 (0.40.0 C4, A3) — 관제탑은 무채색(quiet): 경보 열이 같은 마감을 적색으로 갖는다
                StatusLineView(model: model, quiet: true)
                header(set, tall: tall, alertWidth: alertWidth)
                // 이니셜 확인 줄이 보이면 안내 줄은 숨김 (둘 중 하나만, R2-05)
                if HubPrefs.meChosen { HintBar() } else { MeConfirmBar(model: model) }
                if tall {
                    // 세로 화면: 경보 전폭 — 높이는 내용만큼(경보 수·오늘 일정 수로 추정), 최대 42%. 남는 높이는 레일(1열)이 쓴다 (R2-01 JYK)
                    alertColumn(set, acked: acked).frame(maxHeight: min(geo.size.height * 0.42, alertEstimate(set, acked: acked)))
                    rail(columns: 1).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        alertColumn(set, acked: acked).frame(width: alertWidth)
                        rail(columns: 2).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
            }
        }
        .padding(12)
        // onChange 는 빠른 연속 입력을 하나로 합치므로 발행마다 받는 onReceive
        .onReceive(bus.$event.compactMap { $0 }) { e in handleKey(e.key, alerts: set.alerts) }
    }

    /// D6 키: j/k 고르기 · Enter 원본 · Space 관련 섹션 · d 끝남 · a 확인함 · \ 접기 · Esc 해제
    private func handleKey(_ k: String, alerts: [HubAlert]) {
        let n = alerts.count
        let cur = sel.flatMap { $0 < n ? alerts[$0] : nil }
        switch k {
        case "j": sel = n == 0 ? nil : min((sel ?? -1) + 1, n - 1)
        case "k": sel = n == 0 ? nil : max((sel ?? n) - 1, 0)
        case "enter": cur?.link?.open()
        case "space": if let a = cur { openRail(for: a) }   // openRail 이 touchedDay 를 세운다
        case "d":
            if let a = cur, a.id.hasPrefix("rem-"), let r = model.reminders.first(where: { $0.id == String(a.id.dropFirst(4)) }) {
                commits.schedule(id: r.id, label: "\(r.title) · 끝남") { model.setReminder(r, status: "done") }
            }
        case "a":
            if let a = cur, a.level != .warning { acks[AlertAck.key(a)] = Date().timeIntervalSince1970; AlertAck.save(acks); UsageLog.action("ack") }
        case "\\": markTouched(); withAnimation(.easeOut(duration: 0.15)) { expanded = [] }
        // 시험용 열기 (0.40.0 C3) — '--key rail:<id>' 는 레일 줄 클릭과 같은 경로(그날 자동 결정 멈춤 · panel 기록)
        case let r where r.hasPrefix("rail:"):
            let id = String(r.dropFirst("rail:".count))
            guard Self.railOrder.contains(id) else { return }
            markTouched()
            let opening = !expanded.contains(id)
            withAnimation(.easeOut(duration: 0.2)) { open(id) }
            if opening { UsageLog.panel("tower:" + id) }
        case "esc":
            if sel != nil { sel = nil } else { markTouched(); withAnimation(.easeOut(duration: 0.15)) { expanded = [] } }
        default: break
        }
    }

    /// 사용자가 레일을 만졌음 — 오늘(HubClock 날짜)은 자동 결정 안 함
    private func markTouched() { touchedDay = HubClock.today }

    /// 미팅 후속(0.41.0 C5)은 회의록 다음 — 13개면 half 7, 앞 열 papers…grants · 뒤 열 conferences…datastate 그대로
    static let railOrder = ["papers", "minutes", "followups", "events", "blitz", "experiments", "grants", "conferences", "preprints", "members", "apps", "tools", "datastate"]
    /// 데이터 항목(꼬리표 대상, 0.40.0 C3 M3) — 도구·자료 상태 제외
    static let railDataItems = ["papers", "minutes", "followups", "events", "blitz", "experiments", "grants", "conferences", "preprints", "members", "apps"]
    /// 같은 열의 다른 펼침은 접고 이것을 편다 (열 = 레일 순서 앞 절반·뒤 절반)
    private func open(_ key: String) {
        let half = (Self.railOrder.count + 1) / 2
        let col: (String) -> Int = { k in (Self.railOrder.firstIndex(of: k) ?? 0) < half ? 0 : 1 }
        expanded = expanded.filter { col($0) != col(key) }
        expanded.insert(key)
    }

    /// 경보 열의 내용 높이 추정 (세로 화면 캡) — 경보 행 ~46pt, 오늘 일정 머리 ~24pt + 행 ~26pt(최대 8) + 넘침 줄 20, 제목·여백 (R-J2)
    private func alertEstimate(_ set: AlertSet, acked: [HubAlert]) -> CGFloat {
        let agenda = (model.todayCalendar?.events ?? []).filter { $0.end > model.now && Calendar.current.isDate($0.start, inSameDayAs: model.now) }.count
        return CGFloat(set.alerts.count) * 46 + (set.isClear ? 44 : 0) + CGFloat(set.overflow.count) * 26 + (acked.isEmpty ? 0 : 30)
            + 24 + CGFloat(min(max(agenda, 1), 8)) * 26 + (agenda > 8 ? 20 : 0) + 96 + 24   // + 상태 한 줄 (0.40.0 C4)
    }

    // MARK: 머리 — 경보 카운터 + 오늘 시간 띠

    private func header(_ set: AlertSet, tall: Bool, alertWidth: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 8) {
                Text("경보").font(.hub(13, weight: .bold)).foregroundStyle(Hub.text2)
                counter("■", set.counts[.warning] ?? 0, strong: true)
                counter("□", set.counts[.caution] ?? 0, strong: false)
                counter("·", set.counts[.advisory] ?? 0, strong: false)
            }
            .frame(width: tall ? nil : alertWidth - 12, alignment: .leading)
            if let cal = model.todayCalendar { NowNextBand(cal: cal) } else { Spacer() }
            roster
        }
        .frame(height: 38)
    }

    /// 로스터 띠 — 이니셜을 누르면 10분 동안 그 사람 기준 (다시 누르면 해제)
    private var roster: some View {
        let active = (target != nil && (targetUntil.map { model.now < $0 } ?? false)) ? target : nil
        return HStack(spacing: 3) {
            if let t = active { Text("대상 \(t)").font(.hub(11, weight: .bold)).foregroundStyle(Hub.ink).padding(.trailing, 4) }
            ForEach(model.members.filter { $0.active && !$0.initials.isEmpty && $0.order < 99 }) { m in
                let on = active == m.initials
                Text(m.initials).font(.hub(10.5, weight: .bold, design: .rounded))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(on ? Hub.ink : Hub.surface))
                    .foregroundStyle(on ? Hub.onAccent : Hub.text2)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if on { target = nil; targetUntil = nil }
                        else { target = m.initials; targetUntil = Date().addingTimeInterval(600) }
                    }
                    .help("\(m.name) 기준으로 10분 보기 — 내 것 정렬·내 차례")
            }
        }
        .fixedSize()
    }

    private func counter(_ mark: String, _ n: Int, strong: Bool) -> some View {
        HStack(spacing: 2) {
            Text(mark).font(.hub(11, weight: .bold))
            Text("\(n)").font(.hub(13, weight: .bold, design: .rounded)).monospacedDigit()
        }
        .foregroundStyle(strong && n > 0 ? Hub.signal : (n > 0 ? Hub.text : Hub.text3))
    }

    private var clearLine: some View {
        let next = model.confirmedReminders.first { ($0.day ?? .distantPast) >= model.today }
        return HStack(spacing: 8) {
            Image(systemName: "checkmark.circle").foregroundStyle(Hub.ok)
            Text("경보 없음").font(.hub(14, weight: .semibold))
            if let n = next, let d = n.day { Text("· 다음 \(n.title) \(Hub.relative(d, now: model.now, hasTime: false))").font(.hub(13)).foregroundStyle(Hub.text2) }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
    }

    // MARK: 경보 열

    private func alertColumn(_ set: AlertSet, acked: [HubAlert]) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            if set.isClear { clearLine.padding(.bottom, 8) }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(set.alerts.enumerated()), id: \.element.id) { i, a in
                    alertRow(a)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(sel == i ? Hub.ink : Color.clear, lineWidth: 1.5))
                    if i < set.alerts.count - 1 { RowDivider() }
                }
                ForEach(set.overflow.sorted(by: { $0.key < $1.key }), id: \.key) { l, n in
                    RowDivider()
                    Text("\(l.mark) +\(n) 더").font(.hub(11.5)).foregroundStyle(Hub.text3).padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(set.isClear ? Color.clear : Hub.surface))
            UndoToast(commits: commits).padding(.top, 6)
            if !acked.isEmpty { ackedBlock(acked) }
            todayAgenda.padding(.top, 14)
        }
    }

    /// 확인함 묶음 — 접힌 한 줄, 누르면 펼침, ↺ 로 되돌리기
    private func ackedBlock(_ acked: [HubAlert]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: showAcked ? "chevron.down" : "chevron.right").font(.hub(9, weight: .bold))
                Text("확인함 \(acked.count)").font(.hub(11.5, weight: .medium))
                Spacer()
            }
            .foregroundStyle(Hub.text3).padding(.horizontal, 12).padding(.vertical, 6)
            .contentShape(Rectangle()).onTapGesture { withAnimation(.easeOut(duration: 0.15)) { showAcked.toggle() } }
            if showAcked {
                ForEach(acked) { a in
                    HStack(spacing: 6) {
                        Text(a.level.mark).font(.hub(11)).foregroundStyle(Hub.text3)
                        Text(a.title).font(.hub(12)).foregroundStyle(Hub.text3).lineLimit(1)
                        Spacer()
                        Button { acks[AlertAck.key(a)] = nil; AlertAck.save(acks) } label: { Image(systemName: "arrow.uturn.backward").font(.hub(11)) }
                            .buttonStyle(.plain).foregroundStyle(Hub.text2).help("확인 취소 — 다시 경보로")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 4)
                }
            }
        }
        .padding(.top, 4)
    }

    /// 경보 아래 — 오늘 남은 일정 (R-J2, 0.36.0: 제목 급 글자 — 레일보다 먼저 읽히게). 글자 단계는 AgendaType 하나만
    private var todayAgenda: some View {
        let now = model.now
        let rest = (model.todayCalendar?.events ?? []).filter { $0.end > now && Calendar.current.isDate($0.start, inSameDayAs: now) }
        return VStack(alignment: .leading, spacing: 6) {
            if rest.isEmpty {
                // 캘린더 첫 조회 전엔 '없음' 이 아니다 (0.37.0 C6)
                Text(model.todayCalendar?.isSettled == false ? "불러오는 중…" : "오늘 남은 일정 없음").font(AgendaType.aux).foregroundStyle(Hub.text2).padding(.horizontal, 12)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("오늘 남은 일정").font(AgendaType.head).foregroundStyle(Hub.text)
                    Text("\(rest.count)건").font(AgendaType.aux).foregroundStyle(Hub.text2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
            }
            ForEach(rest.prefix(8)) { e in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Hub.time(e.start)).font(AgendaType.time).frame(width: Hub.s(48), alignment: .leading).foregroundStyle(Hub.text2)
                    // 진행 중(시작 ≤ 지금 < 끝)
                    if e.start <= now && now < e.end { Text("●").font(AgendaType.aux).foregroundStyle(Hub.ink) }
                    Text(Hub.canonicalNames(e.title)).font(AgendaType.title).foregroundStyle(Hub.text).lineLimit(1).help(e.title)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 2)
                .link(.calendarDay(e.start))
            }
            if rest.count > 8 { Text("+\(rest.count - 8)건").font(AgendaType.aux).foregroundStyle(Hub.text2).padding(.horizontal, 12) }
        }
    }

    @ViewBuilder
    private func alertRow(_ a: HubAlert) -> some View {
        let pending = a.id.hasPrefix("rem-") && commits.isPending(String(a.id.dropFirst(4)))
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(a.level.mark).font(.hub(12, weight: .bold)).foregroundStyle(a.level == .warning ? Hub.signal : Hub.text2).frame(width: 12)
            // 좁은 칸엔 짧은 남은 시간(2h·35m·D-3), 전체 '오늘 18:00 · 2h' 는 툴팁으로 — '오늘 1…' 잘림 수정(10-15 실화면)
            Text(a.due.map { MenuBarLine.compact($0, now: model.now) } ?? "")
                .font(.hub(11.5, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1)
                .foregroundStyle(a.level == .warning ? Hub.signal : Hub.text2).frame(width: Hub.s(46), alignment: .leading)
                .help(a.due.map { Hub.relative($0, now: model.now, hasTime: a.hasTime) } ?? "")
            VStack(alignment: .leading, spacing: 2) {
                Text(a.title).font(.hub(a.level == .warning ? 13.5 : 13, weight: a.level == .warning ? .semibold : .medium))
                    .lineLimit(2).strikethrough(pending).foregroundStyle(pending ? Hub.text3 : Hub.text)
                // meta = [누구(이니셜), detail, +n 출처] — '내 것' 은 담당 칸이 비었을 때만 (담당이 나면 이니셜을 ink 로, 적색 예산 밖)
                let rest = [a.detail, a.sources.count > 1 ? "+\(a.sources.count - 1) 출처" : "", a.owner.isEmpty && a.mine ? "내 것" : ""]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
                if !a.owner.isEmpty || !rest.isEmpty {
                    let meOwner = a.owned(by: model.myMember(who)?.initials ?? who)
                    (Text(a.owner).fontWeight(.semibold).foregroundStyle(meOwner ? Hub.ink : Hub.text2)
                     + Text((a.owner.isEmpty || rest.isEmpty ? "" : " · ") + rest))
                        .font(.hub(11.5)).foregroundStyle(Hub.text3).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let act = a.action, a.level == .warning || act == "끝남" { actionButton(act, for: a, pending: pending) }
        }
        .padding(.horizontal, 12).padding(.vertical, a.level == .warning ? 10 : 7)
        .contentShape(Rectangle())
        .onTapGesture { openRail(for: a) }
        // 레일 ≤3: ↗ 원본 · ✓ 확인함(C·A) · 미루기(지난 내 리마인더만). 보이는 행동 버튼은 '끝남으로 표시' 하나 그대로
        .rowRail((a.link.map { l in [RailButton(symbol: "arrow.up.forward", help: l.help) { l.open() }] } ?? [])
                 + (a.level == .warning ? [] : [RailButton(symbol: "checkmark.circle", help: "확인함 — 경보에서 내림 (이 맥, 7일)") {
                        acks[AlertAck.key(a)] = Date().timeIntervalSince1970; AlertAck.save(acks); UsageLog.action("ack") }])
                 + (a.snoozable ? [RailButton(symbol: "calendar.badge.clock", help: snoozeHelp) { snooze(a) }] : []))
        .help(([a.title, a.owner, a.detail] + [a.sources.joined(separator: " + ")]).filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    private func actionButton(_ act: String, for a: HubAlert, pending: Bool) -> some View {
        Button {
            switch act {
            case "끝남":
                let id = String(a.id.dropFirst(4))
                if pending { commits.undo(id) }
                else if let r = model.reminders.first(where: { $0.id == id }) {
                    commits.schedule(id: id, label: "\(r.title) · 끝남") { model.setReminder(r, status: "done") }
                }
            case "슬라이드": if let g = model.nextGRM { model.openSlides(for: g) }
            case "다시 시도": if let f = model.reminderSaveFailed { model.retryReminderSave(f) }
            default: a.link?.open()
            }
        } label: {
            // '끝남' 만 쓰면 상태 배지로 읽힌다(JYK UX 10-15: "46분 후" 옆 "끝남" 이 끝난 건지 남은 건지 혼란) → 동작임을 드러내는 라벨
            let text = pending ? "되돌리기" : (act == "끝남" ? "끝남으로 표시" : act)
            HStack(spacing: 3) {
                if act == "끝남" { Image(systemName: pending ? "arrow.uturn.backward" : "checkmark").font(.hub(10, weight: .bold)) }
                Text(text).font(.hub(11.5, weight: .semibold))
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Hub.ink.opacity(0.12)))
            .foregroundStyle(Hub.ink)
        }
        .buttonStyle(.plain)
        .help(act == "끝남" ? (pending ? "끝남 표시 되돌리기" : "이 리마인더를 끝남으로 표시 — 6초 안에 되돌릴 수 있음 (NAS reminders.json)") : act)
    }

    /// 미루기 날짜 — 오늘 +7일(다음 주 같은 요일) 고정. '내일'은 D≤1 이라 바로 W(■)로 올라가 더 시끄러워진다
    private var snoozeTarget: Date { Calendar.current.date(byAdding: .day, value: 7, to: model.today) ?? model.today }
    private var snoozeHelp: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "M.d(E)"
        return "다음 주 \(f.string(from: snoozeTarget))로 미루기 — 리마인더만, Notion 일정은 그대로 · 6초 안에 되돌리기"
    }
    /// 미루기 — 6초 미뤄 두고(UndoToast 로 되돌리기) NAS reminders.json 의 날짜만. id 는 '끝남' 과 따로('snooze-') — 취소선과 섞이지 않게
    private func snooze(_ a: HubAlert) {
        let id = String(a.id.dropFirst(4)), to = snoozeTarget
        // 쓰기는 이 맥에서 확인한 신원으로만 — 로스터에서 남을 '대상'으로 골라 둔 동안에도 (검증 1)
        guard a.snoozable, !AlertEngine.snoozeActor.isEmpty, let r = model.reminders.first(where: { $0.id == id }) else { return }
        commits.schedule(id: "snooze-" + r.id, label: "\(r.title) · \(Hub.day(to))로 미룸") { model.snoozeReminder(r, to: to) }
    }

    /// 경보 제목을 누르면 관련 참조 섹션을 펼친다
    private func openRail(for a: HubAlert) {
        let key: String? = a.sources.contains("GRM") ? "minutes" : a.sources.contains("그랜트") ? "grants" : a.sources.contains("학회") ? "conferences"
            : a.sources.contains("papers") ? "papers" : a.sources.contains("Prolific") ? "experiments" : nil
        if let key { markTouched(); withAnimation(.easeOut(duration: 0.2)) { open(key) } } else { a.link?.open() }
    }

    // MARK: 참조 레일

    /// chips = 접힌 줄 요약 뒤 관심 이니셜 (학회 줄만, 0.38.0 C4)
    private struct RailItem: Identifiable { let id: String; let title: String; let summary: String; let fresh: Freshness?; let link: HubLink?; var est: CGFloat = 0; var chips: [String] = [] }
    /// 열 채우기 (N1, 결정 3): 기본은 관련 항목을 점수 순으로 열 높이가 맞는 동안 펼친다. DESKHUB_RAIL_FILL=0 이면 열마다 최고 점수 하나만.
    private static let fillLandscape: Bool = ProcessInfo.processInfo.environment["DESKHUB_RAIL_FILL"] != "0"

    private var railItems: [RailItem] {
        let me = HubPrefs.me
        let mine = model.papers.filter { me.isEmpty || $0.researcher == me }
        let unreacted = mine.filter { (model.paperComments[$0.id] ?? []).filter(\.isReaction).isEmpty }.count
        // 오늘 분은 경보 열 '오늘 남은 일정'에 있으므로 레일은 내일부터 (R2-02 BHL — 중복 제거)
        let events = model.todayCalendar?.upcoming(days: model.cfg.eventsDays).filter { $0.end > model.now && !Calendar.current.isDate($0.start, inSameDayAs: model.now) } ?? []
        let firstMin = model.minutes.first.map { m -> String in let h = model.minutesHeader(m); return (m.date.map(Hub.day) ?? "") + " " + h.who + " | " + h.title } ?? "없음"
        let checks = model.grants.filter { $0.needsCheck(today: model.today) }.count
        let conf = model.conferences.first.map { c in c.conference + (c.deadline.map { " 초록 " + Hub.relative($0, now: model.now, hasTime: false) } ?? "") } ?? "없음"
        let items: [RailItem] = [
            // 꼬리표는 모두 model.cardTag — 허브 카드 머리·[꼬리표] 덤프와 같은 함수 (0.40.0 C3, A2)
            // 생산자가 멈췄으면 '새 추천 없음 (6.1~)' — 펼쳐도 한 줄(fold), 자동 펼침 후보에서 빠짐(est 0) (0.40.0 C8, R4)
            RailItem(id: "papers", title: "논문 추천",
                     summary: model.papersStopped ? "새 추천 없음 (\(model.papersStoppedSince)~)" : "\(mine.count)편" + (me.isEmpty ? "" : " · \(me)") + " · 반응 없음 \(unreacted)",
                     fresh: model.cardTag("papers"), link: .notion(model.cfg.paperRecDB)),
            RailItem(id: "minutes", title: "회의록", summary: firstMin, fresh: model.cardTag("minutes"), link: .notion(model.cfg.meetingNotesDB)),
            // 미팅 후속 (0.41.0 C5) — 사람별 남은 수만(항목 글 없음). 관련도 0 · est 0 이라 자동으로 펴지 않는다
            RailItem(id: "followups", title: "미팅 후속", summary: model.followupRailSummary(), fresh: model.cardTag("followups"), link: nil),
            // 캘린더 첫 조회 전에는 '0건' 대신 불러오는 중 (0.37.0 C6 검증 1)
            RailItem(id: "events", title: "내일부터 \(model.cfg.eventsDays)일",
                     summary: model.todayCalendar?.isSettled == false ? "캘린더 불러오는 중…"
                        : "\(events.count)건" + (events.first.map { " · 다음 " + Hub.relative($0.start, now: model.now) + " " + Hub.canonicalNames($0.title) } ?? ""),
                     fresh: model.cardTag("events"), link: .notion(model.cfg.eventsDB)),
            RailItem(id: "blitz", title: "Paper Blitz", summary: (model.blitzDate.map(Hub.day) ?? "—") + " · \(model.blitz.count)편", fresh: model.cardTag("blitz"), link: model.blitzDeckPath.map(HubLink.nas)),
            RailItem(id: "experiments", title: "오늘의 실험", summary: "\(model.experiments.count)건" + (model.prolificNote != nil ? " · Prolific 미연결" : ""), fresh: model.cardTag("experiments"), link: .notion(model.cfg.slabDB)),
            RailItem(id: "grants", title: "그랜트", summary: "\(model.grants.count)건" + (checks > 0 ? " · 확인 필요 \(checks)" : ""), fresh: model.cardTag("grants"), link: .nas((model.cfg.grantsFile as NSString).deletingLastPathComponent)),
            // 접힌 줄 칩 = 요약에 쓴 첫 학회의 관심 이니셜 (0.38.0 C4 — 펼치면 카드 안 칩·'관심' 단추가 있으므로 줄에서는 뺀다)
            RailItem(id: "conferences", title: "학회", summary: "\(model.conferences.count)건 · " + conf, fresh: model.cardTag("conferences"), link: .notion(model.cfg.conferencesDB),
                     chips: model.conferences.first.map { model.interestNames($0) } ?? []),
            RailItem(id: "preprints", title: "최신 원고", summary: "\(model.preprints.count)편" + (model.preprints.first.map { " · " + $0.title } ?? ""), fresh: model.cardTag("preprints"), link: .notion(model.cfg.publicationsDB)),
            RailItem(id: "members", title: "멤버·프로젝트", summary: "\(model.members.filter(\.active).count)명 · 프로젝트 \(model.projects.count)", fresh: model.cardTag("members"), link: .notion(model.cfg.membersDB)),
            RailItem(id: "apps", title: "만든 앱", summary: MadeApps.summary, fresh: model.cardTag("apps"), link: nil),
            RailItem(id: "tools", title: "도구", summary: "메일 초안 4 · GRM 안내·공지·청소·휴가", fresh: nil, link: nil),
            // 자료 상태 (0.40.0 C3, A2) — 원천 정렬 표 + 위생 목록. 관련도 0 이라 자동으로 펴지 않는다
            RailItem(id: "datastate", title: "자료 상태", summary: DataSources.summary(model), fresh: nil, link: nil),
        ]
        // 펼쳤을 때 내용 높이 추정(pt) — 가로 2열 채우기 판단용 (행 높이 × 줄 수 + 제목)
        let est: [String: CGFloat] = [
            "papers": model.papersStopped ? 0 : CGFloat(min(mine.count, 3)) * 150 + 40, "minutes": 180,
            "events": CGFloat(min(events.count, 14)) * 36 + 60, "blitz": CGFloat(min(model.blitz.count, 12)) * 34 + 50,
            // 0건이면 0 → 자동 펼침 후보에서 빠짐('없음' 카드로 채우지 않음). 관제탑 레일의 그랜트·학회 D-day 는 무채색(quiet) — 적색은 경보 열만
            "experiments": model.experiments.isEmpty ? 0 : CGFloat(model.experiments.count) * 46 + 30,
            // 그랜트 행은 제목·날짜·메모(최대 2줄)·확인일까지 여러 줄 — 실측 가로 2열 ≈ 70pt/행 (검증 1: 44 로 잡아 세로에서 넘침)
            "grants": model.grants.isEmpty ? 0 : CGFloat(model.grants.count) * 72 + 50,
            // 학회 행마다 '관심' 단추·이니셜 칩 줄(약 18pt)이 붙는다 (0.37.0 C5, 검증 1: 단추를 칩 줄로)
            "conferences": CGFloat(min(model.conferences.count, model.cfg.conferencesCount, 8)) * (62 + 18) + 50,
            "preprints": model.preprints.isEmpty ? 0 : CGFloat(model.preprints.count) * 48 + 30,
            "members": 340, "apps": 170, "tools": 90, "followups": 0,
            // 표 행(좁은 레일은 원천·영향 카드 두 줄 ≈ 34) + 위생 줄 22 + 머리·캡션 90 (검증 1)
            "datastate": CGFloat(DataSources.catalog.count) * 34 + CGFloat(min(DataSources.hygiene(model).count, DataSources.hygieneLimit + 1)) * 22 + 90,
        ]
        return items.map { var r = $0; r.est = est[$0.id] ?? 0; return r }
    }

    /// 참조 레일 — 가로 2열(R2, JYK: '너무 세로로만 나열돼 일정 아래로는 왼/오 두 개로'), 세로 1열. 펼침은 그 열 안에서.
    /// 바깥 ScrollView 없이 열이 남은 높이를 받고, 펼친 카드(안쪽 ScrollView)가 그 높이를 채운다 (R2-01 빈 면)
    private func rail(columns: Int) -> some View {
        let items = railItems
        let half = (items.count + 1) / 2
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                // 세로 1열: 펼친 카드가 남은 높이를 채움. 가로 2열: 카드는 내용 높이(최대 열의 62%) — 늘리면 카드 안이 비고 접힌 줄이 바닥으로 밀림 (R2 검증 10-15)
                if columns == 1 {
                    railColumn(items, stretch: true)
                } else {
                    railColumn(Array(items.prefix(half)), stretch: false)
                    railColumn(Array(items.dropFirst(half)), stretch: false)
                }
            }
            // minHeight 0 + clipped: 펼친 카드가 넘쳐도 열이 창 밖으로 커지지 않는다 — 소스 줄('캘린더 ✓')은 늘 보인다 (검증 1 세로)
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            .clipped()
            .background(GeometryReader { g in
                // 열 높이 실측 — 펼친 '일정' 의 줄 수 계산 (onGeometryChange 는 macOS 15+)
                Color.clear.onAppear { railHeight = g.size.height; decideExpansion(columns: columns, height: g.size.height) }
                    .onChange(of: g.size.height) { _, n in railHeight = n; decideExpansion(columns: columns, height: n) }
                    // 데이터가 다 온 뒤(갱신 본체 + 그 갱신이 띄운 댓글·Blitz·Prolific·원고, 늦으면 20초) 결정 — lastUpdated 는 그랜트·학회 파일·댓글보다 먼저 선다 (검증 1 리뷰).
                    // 날짜가 바뀐 뒤 첫 갱신도 여기서
                    .onChange(of: model.settledAt) { _, _ in decideExpansion(columns: columns, height: railHeight) }
                    .onChange(of: model.loading) { _, l in if !l { decideExpansion(columns: columns, height: railHeight) } }
                // todayCalendar 는 @Published 가 아니라 TowerView 가 그 상태 변화를 못 받는다 — CalendarModel 을 관찰하는 프로브로 .ready 를 받음 (검증 1 리뷰)
                if let cal = model.todayCalendar {
                    CalendarReadyProbe(cal: cal) { decideExpansion(columns: columns, height: railHeight) }
                }
            })
            sourcesLine
        }
    }

    /// 안쪽에서 스크롤하는 카드 — 남은 높이를 채운다. 나머지는 내용 높이 + 열 끝 Spacer
    private static let flexRail: Set<String> = ["papers", "blitz", "events", "conferences", "minutes"]

    /// 결정용 접힌 줄 높이 — 줄 34 + 열 간격 6 (실측 40pt, 10-16 세로·가로 스냅샷)
    private static let lineH: CGFloat = 40

    /// 펼친 카드가 결정에서 차지하는 높이. 카드 안에서 스크롤해 줄어드는 카드(세로: flexRail·그랜트, 가로: papers·minutes·blitz·그랜트)는
    /// 쓸모 있는 최소 높이(세로 150, 가로 열의 30%·150 이상 — 가로 2열에서 셋째 카드가 끼어 모두 납작해지지 않게)만 센다 — 실제로는 남은 높이를 나눠 갖는다. 내용 높이로 고정되는 카드(실험·원고·멤버·앱·도구,
    /// 가로 events·conferences)는 그 높이 그대로 — 넘치면 아래 줄과 소스 줄을 밀어낸다 (검증 1: 세로 그랜트 넘침, BYL 실험이 큰 추정에 밀림)
    private func cost(_ it: RailItem, columns: Int, height: CGFloat) -> CGFloat {
        let shrinks: Set<String> = columns == 1 ? Self.flexRail.union(["grants"]) : ["papers", "minutes", "blitz", "grants"]
        if shrinks.contains(it.id) { return min(it.est, columns == 1 ? 150 : max(150, height * 0.3)) }
        if columns == 2, it.id == "events" || it.id == "conferences" { return min(it.est, max(240, height * 0.62)) }   // 가로 줄 수 캡(railContent)과 같게
        return it.est
    }

    /// 기본 펼침 = 관련도 (SMJ #27, 0.35.0) — 세로(1열)·가로(2열) 같은 규칙. 캘린더 .ready + 데이터 다 옴(settledAt) + 실측 높이 뒤 하루 한 번.
    /// 열(가로 = 레일 순서 앞·뒤 절반, 세로 = 전체)마다 점수>0 이고 내용이 있는(est>0) 것만 점수 순(같으면 레일 순서)으로, 접힌 줄 + 펼친 카드(cost)가
    /// 열 높이 안에 드는 것만 펼치고(세로는 최대 3개, DESKHUB_RAIL_FILL=0 은 1개) 나머지는 접는다. 열에 관련 항목이 없으면 그 열의 기본
    /// (앞 events · 뒤 conferences, 세로는 둘 다)을 같은 높이 규칙으로. 사용자가 펴거나 접은 날(touchedDay)은 정하지 않는다. 날짜가 바뀐 뒤 첫 갱신에서 다시
    private func decideExpansion(columns: Int, height: CGFloat) {
        // 날짜 키는 HubClock.today 하나 — settledDay·touchedDay·점수 안 today 가 같은 달력 (model.now 는 1분 늦게 넘어간다, R-L1)
        let today = HubClock.today
        if let d = decidedDay, d != today { decidedDay = nil }
        guard decidedDay == nil, touchedDay != today, height > 100, model.todayCalendar?.status == .ready,
              model.lastUpdated != nil, !model.loading, model.settledDay == today else { return }
        decidedDay = today
        let scores = TowerRelevance.score(model: model, now: HubClock.now, me: HubPrefs.me)
        // 캡처한 items 는 마지막 body 계산 때 것이라(일정 0건) 추정이 틀린다 → 호출 시점에 railItems 를 다시 계산 (리뷰 2)
        let items = railItems
        let half = (items.count + 1) / 2
        let cols: [[RailItem]] = columns == 1 ? [items] : [Array(items.prefix(half)), Array(items.dropFirst(half))]
        let rank: (String) -> Int = { Self.railOrder.firstIndex(of: $0) ?? 99 }
        let limit = !Self.fillLandscape ? 1 : (columns == 1 ? 3 : Int.max)
        var next: Set<String> = []
        for (ci, col) in cols.enumerated() {
            let ranked = col.filter { (scores[$0.id]?.score ?? 0) > 0 && $0.est > 0 }
                .sorted { a, b in
                    let sa = scores[a.id]?.score ?? 0, sb = scores[b.id]?.score ?? 0
                    return sa != sb ? sa > sb : rank(a.id) < rank(b.id)
                }
            let defaults: Set<String> = columns == 1 ? ["events", "conferences"] : [ci == 0 ? "events" : "conferences"]
            let candidates = ranked.isEmpty ? col.filter { defaults.contains($0.id) } : ranked
            var used = CGFloat(col.count) * Self.lineH, n = 0
            for it in candidates where n < limit {
                let c = cost(it, columns: columns, height: height)
                if used + c > height { continue }   // 안 들어가면 다음 후보 (작은 고정 카드가 큰 카드 뒤에서 밀리지 않게)
                next.insert(it.id); used += c; n += 1
            }
        }
        withAnimation(.easeOut(duration: 0.2)) { expanded = next }
    }

    private func railColumn(_ items: [RailItem], stretch: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { it in
                let on = expanded.contains(it.id)
                VStack(alignment: .leading, spacing: 0) {
                    railLine(it, chipLimit: stretch ? 2 : 3)
                    if on {
                        railContent(it.id, rows: items.count, stretch: stretch, est: it.est).padding(.horizontal, 6).padding(.bottom, 8)
                            .transition(.opacity)
                        // 펼친 카드 아래 캡션 '출처 · 기준 · n · 정의 id' — 허브 카드 끝과 같은 함수 (0.40.0 C2, A1)
                        if let cid = CardMetas.cardID(forRail: it.id) {
                            SourceCaption(text: CardMetas.caption(cid, model)).padding(.horizontal, 12).padding(.bottom, 8)
                        }
                    }
                }
                .frame(maxHeight: on && stretch && Self.flexRail.contains(it.id) ? .infinity : nil, alignment: .top)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Hub.card.opacity(0.5) : Hub.surface))
                // 펼친 카드가 남은 높이를 먼저 받는다 — 끝의 Spacer 와 반씩 나누면 줄어드는 카드(그랜트·논문)가 절반만 받았다 (검증 1)
                .layoutPriority(on ? 1 : 0)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// chipLimit — 세로 1열(stretch)은 2, 가로 2열은 3 (요약이 '…' 로만 남지 않게)
    private func railLine(_ it: RailItem, chipLimit: Int = 3) -> some View {
        HStack(spacing: 8) {
            Image(systemName: expanded.contains(it.id) ? "chevron.down" : "chevron.right").font(.hub(10, weight: .bold)).foregroundStyle(Hub.text3).frame(width: 12)
            Text(it.title).font(.hub(13, weight: .semibold)).frame(width: Hub.s(84), alignment: .leading)
            Text(it.summary).font(.hub(12.5)).foregroundStyle(Hub.text2).lineLimit(1)
            // 접혔을 때만 관심 칩 — 펼친 학회 카드에는 행마다 칩·'관심' 단추가 있다 (0.38.0 C4)
            if !it.chips.isEmpty && !expanded.contains(it.id) { InterestChips(names: it.chips, limit: chipLimit) }
            if let f = it.fresh { FreshnessTag(f: f) }
            Spacer(minLength: 4)
            if let l = it.link {
                Button { l.open() } label: { Image(systemName: "arrow.up.forward").font(.hub(11)) }
                    .buttonStyle(.plain).foregroundStyle(Hub.text2).help(l.help)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            markTouched()
            let opening = !expanded.contains(it.id)
            withAnimation(.easeOut(duration: 0.2)) { if expanded.contains(it.id) { expanded.remove(it.id) } else { open(it.id) } }
            if opening { UsageLog.panel("tower:" + it.id) }   // 열 때만 (0.40.0 C2, A1)
        }
    }

    @ViewBuilder
    private func railContent(_ id: String, rows: Int, stretch: Bool = true, est: CGFloat = .infinity) -> some View {
        // 가로(stretch=false)는 내용 높이, 단 열의 62% 까지 — 긴 목록은 카드 안에서 스크롤
        let cap: CGFloat = stretch ? .infinity : max(240, railHeight * 0.62)
        // 펼친 카드가 남은 높이를 먼저 받으므로(layoutPriority) 가로의 스크롤 카드는 내용 추정까지만 — 짧은 목록이 캡까지 늘어 속이 비지 않게
        let fit: CGFloat = stretch ? .infinity : min(cap, max(160, est))
        switch id {
        case "papers": PaperRecBoard(model: model, fold: true).frame(maxHeight: model.papersStopped ? nil : fit)
        case "minutes": ScrollView(.vertical, showsIndicators: false) { MinutesCard(model: model, minutesExpanded: true) }.frame(maxHeight: cap)
        case "events":
            // 줄 수 = (열 높이 − 접힌 줄 rows×40 − 제목·여백) / 행 36, 최소 6 (첫 프레임 실측 0 이어도 6)
            if stretch {
                ScrollView(.vertical, showsIndicators: false) {
                    UpcomingEventsCard(model: model, cal: model.todayCalendar, maxRows: max(6, Int((railHeight - CGFloat(rows) * 40 - 90) / 36)), excludeToday: true)
                }
                .frame(maxHeight: cap)
            } else {
                // 가로: ScrollView 는 내용이 적어도 캡까지 늘어나 카드 안이 빈다 → 줄 수만 캡에 맞춰 내용 높이로
                UpcomingEventsCard(model: model, cal: model.todayCalendar, maxRows: max(6, Int(cap / 36) - 2), excludeToday: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case "blitz": BlitzCompact(model: model).frame(maxHeight: fit)
        case "experiments": ExperimentsCard(model: model)
        case "grants":
            // 들어가면 내용 높이 그대로, 모자라면 카드 안에서 스크롤 — 열을 넘쳐 아래 줄·소스 줄을 밀어내지 않게 (검증 1 세로).
            // quiet: 레일의 D-day 는 무채색, 적색은 경보 열만 (검증 1: 그랜트 '오늘' 이 4번째 적색)
            ViewThatFits(in: .vertical) {
                GrantsSection(model: model, quiet: true).fixedSize(horizontal: false, vertical: true)
                ScrollView(.vertical, showsIndicators: false) { GrantsSection(model: model, quiet: true) }
            }
        case "conferences":
            if stretch { ScrollView(.vertical, showsIndicators: false) { ConferencesCard(model: model, maxRows: 12, quiet: true) }.frame(maxHeight: cap) }
            else { ConferencesCard(model: model, maxRows: max(3, Int(cap / 82)), quiet: true).fixedSize(horizontal: false, vertical: true) }   // 카드 안 frame(maxHeight: .infinity) 가 열을 채우지 않게
        case "preprints": LatestManuscripts(model: model)
        case "followups": FollowupCountsView(model: model)
        case "members": MembersProjectsStrip(model: model).padding(6)
        case "apps": AppsCard()
        case "tools": AppsScriptSection(model: model)
        // 자료 상태 — 표가 길어 카드 안에서 스크롤 (가로는 열의 62%, 세로는 남은 높이)
        case "datastate": ScrollView(.vertical, showsIndicators: false) { DataStateRail(model: model) }.frame(maxHeight: stretch ? max(240, railHeight * 0.7) : cap)
        default: EmptyView()
        }
    }

    private var sourcesLine: some View {
        HStack(spacing: 10) {
            Text("소스").font(.hub(11, weight: .bold)).foregroundStyle(Hub.text3)
            Text("Notion " + (model.lastUpdated.map(Hub.time) ?? "—")).font(.hub(11)).foregroundStyle(Hub.text3)
            Text("NAS " + (FileManager.default.fileExists(atPath: model.cfg.nasGRMRoot) ? "✓" : "✕")).font(.hub(11)).foregroundStyle(Hub.text3)
            Text("캘린더 " + ((model.todayCalendar?.status == .ready) ? "✓" : "…")).font(.hub(11)).foregroundStyle(Hub.text3)
            Spacer()
            Text("DeskHub \(Hub.buildLabel)").font(.hub(10.5)).foregroundStyle(Hub.text3)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

/// 관제탑 '오늘 남은 일정' 글자 단계 (R-J2, 0.36.0) — 레일 제목 13 semibold·요약 12.5 보다 크게, 경보 제목 13.5 semibold 와 비슷하게.
/// 경보는 적색 표식·표면 배경으로 계속 먼저 읽힌다. 안내판 급 18pt 는 결정 D3
/// static var (0.37.0 C3) — 글자 배율(HubDisplay)이 바뀌면 읽을 때마다 다시 계산
private enum AgendaType {
    static let headSize: CGFloat = 15, rowSize: CGFloat = 14, auxSize: CGFloat = 12
    static var head: Font { Font.hub(headSize, weight: .semibold) }
    static var time: Font { Font.hub(rowSize, weight: .semibold, design: .rounded).monospacedDigit() }
    static var title: Font { Font.hub(rowSize, weight: .medium) }
    static var aux: Font { Font.hub(auxSize) }
}

/// 관제탑 레일 관련도 (SMJ #27, 0.35.0) — 순수 함수: 같은 (모델·지금·나) 이면 같은 점수. 기본 펼침(decideExpansion)이 쓰고,
/// `--dump-alerts` 끝 '레일 관련도' 줄로 확인한다. 다른 뷰의 접기·펼치기(B5)에서 재사용할 수 있게 뷰 밖에 둔다.
///   마감 임박 +3 (D0–7): grants 마감 · conferences 초록 마감(개최일 아님) — 원고 Deadline 은 0.40.0 C1(F0-3)에서 뺌(Publications Stage·Deadline 0/13, 늘 빈 값)
///   내 것 +2 (NotionHubModel.isMine·이니셜 토큰, 부분 문자열 금지): experiments 담당 · preprints 저자 · papers 내 추천 중 내 반응 없음 ·
///     events 내일~eventsDays 제목 · conferences 제목·저자 · minutes 최근 발표자 · blitz 발표자
///   오늘 변화 +1: papers 오늘 보낸 추천 · minutes 오늘 GRM 지남·녹취 대기 · blitz 오늘 덱·NAS 새 덱
///   members·apps·tools 는 늘 0 (자동으로 펴지 않음). me 는 이 맥의 이니셜(HubPrefs.me) — 로스터 '대상' 렌즈는 쓰지 않는다
enum TowerRelevance {
    @MainActor
    static func score(model m: NotionHubModel, now: Date, me: String) -> [String: (score: Int, why: String)] {
        let c = Calendar.current
        let today = c.startOfDay(for: now)
        func days(_ d: Date) -> Int { c.dateComponents([.day], from: today, to: c.startOfDay(for: d)).day ?? 99 }
        func dText(_ n: Int) -> String { n == 0 ? "오늘" : "D-\(n)" }
        func mine(_ text: String) -> Bool { m.isMine(text, me: me) }
        let myIni = (m.myMember(me)?.initials ?? "").uppercased()
        var acc: [String: (Int, [String])] = Dictionary(uniqueKeysWithValues: TowerView.railOrder.map { ($0, (0, [String]())) })
        func add(_ id: String, _ pts: Int, _ why: String) { var v = acc[id] ?? (0, []); v.0 += pts; v.1.append(why); acc[id] = v }
        /// D0–7 중 가장 가까운 것
        func nearest<T>(_ xs: [T], _ date: (T) -> Date?) -> (T, Int)? {
            xs.compactMap { x in date(x).map { (x, days($0)) } }.filter { (0...7).contains($0.1) }.min { $0.1 < $1.1 }
        }

        // 마감 임박 +3
        if let (g, n) = nearest(m.grants, { $0.due }) { add("grants", 3, "마감 \(dText(n)) \(g.title)") }
        if let (cf, n) = nearest(m.conferences, { $0.deadline }) { add("conferences", 3, "마감 \(dText(n)) \(cf.conference)") }

        // 내 것 +2 — me 가 없거나 Members 에 없으면 아무것도 내 것이 아니다 (isMine 과 같은 조건)
        if !myIni.isEmpty {
            if m.experiments.contains(where: { mine($0.owner) }) { add("experiments", 2, "내 것") }
            if m.preprints.contains(where: { $0.initials.map { $0.uppercased() }.contains(myIni) }) {
                add("preprints", 2, "내 것")
            }
            let myPapers = m.papers.filter { $0.researcher.uppercased() == myIni || $0.researcher == me }
            let unreacted = myPapers.filter { p in !(m.paperComments[p.id] ?? []).contains { $0.isReaction && $0.who == me } }.count
            if unreacted > 0 { add("papers", 2, "내 추천 반응 없음 \(unreacted)") }
            let calMine = (m.todayCalendar?.upcoming(days: m.cfg.eventsDays) ?? [])
                .contains { $0.end > now && !c.isDate($0.start, inSameDayAs: now) && mine(Hub.canonicalNames($0.title)) }
            let notionMine = m.visibleEvents.contains { !c.isDate($0.date, inSameDayAs: now) && mine($0.title) }
            if calMine || notionMine { add("events", 2, "내 일정") }
            if m.conferences.contains(where: { mine($0.conference + " " + $0.title + " " + $0.authors) }) { add("conferences", 2, "내 것") }
            if let last = m.minutes.first {
                let who = m.minutesHeader(last).who
                if mine(who.isEmpty ? (m.lastGRM?.presenters ?? "") : who) { add("minutes", 2, "내 발표 회의록") }
            }
            if m.blitz.contains(where: { mine($0.presenter) }) { add("blitz", 2, "내 발표") }
        }

        // 오늘 변화 +1
        let sentToday = m.papers.filter { $0.sentAt.map { c.isDate($0, inSameDayAs: now) } ?? false }.count
        if sentToday > 0 { add("papers", 1, "오늘 추천 \(sentToday)") }
        if let g = m.lastGRM, c.isDate(g.date, inSameDayAs: now) { add("minutes", 1, "오늘 GRM") }
        else if m.minutesPending != nil { add("minutes", 1, "녹취 대기") }
        if let d = m.blitzDate, c.isDate(d, inSameDayAs: now) { add("blitz", 1, "오늘 덱") }
        else if m.blitzPending { add("blitz", 1, "NAS 새 덱") }

        // members·apps·tools·datastate·followups(0.41.0 C5 — 수만, 자동으로 펴지 않음) 는 0 으로 고정
        for k in ["members", "apps", "tools", "datastate", "followups"] { acc[k] = (0, []) }
        return acc.mapValues { (score: $0.0, why: $0.1.joined(separator: ", ")) }
    }

    /// '레일 관련도: conferences 3 (마감 D-3 Cosyne 2027) · experiments 2 (내 것) · … / 0: members, apps, tools …'
    @MainActor
    static func dumpLine(model m: NotionHubModel, now: Date, me: String) -> String {
        let s = score(model: m, now: now, me: me)
        let order = TowerView.railOrder
        let rank: (String) -> Int = { order.firstIndex(of: $0) ?? 99 }
        let pos = s.filter { $0.value.score > 0 }.sorted { a, b in a.value.score != b.value.score ? a.value.score > b.value.score : rank(a.key) < rank(b.key) }
        let zero = order.filter { (s[$0]?.score ?? 0) == 0 }
        return "레일 관련도 (나 \(me.isEmpty ? "—" : me)): " + (pos.isEmpty ? "없음" : pos.map { "\($0.key) \($0.value.score) (\($0.value.why))" }.joined(separator: " · "))
            + " / 0: " + (zero.isEmpty ? "없음" : zero.joined(separator: ", "))
    }
}

/// 캘린더가 .ready 가 되는 순간을 받는 빈 뷰 — NotionHubModel.todayCalendar 는 관찰되지 않으므로 CalendarModel 을 직접 관찰 (기본 펼침 결정 트리거)
private struct CalendarReadyProbe: View {
    @ObservedObject var cal: CalendarModel
    let onReady: () -> Void
    var body: some View {
        Color.clear
            .onChange(of: cal.status == .ready) { _, ready in if ready { onReady() } }
    }
}

/// 오늘 시간 띠 — 08~22시를 가로로, 일정은 막대, 지금은 세로선, 다음 두 일정만 이름 (계획 §2 A '띠')
struct NowNextBand: View {
    @ObservedObject var cal: CalendarModel
    var body: some View {
        let now = cal.now
        let day = Calendar.current.startOfDay(for: now)
        let start = day.addingTimeInterval(8 * 3600), end = day.addingTimeInterval(22 * 3600)
        let evs = cal.events.filter { $0.end > start && $0.start < end }
        let next = evs.filter { $0.start > now }.prefix(2)
        GeometryReader { geo in
            let w = geo.size.width
            let x: (Date) -> CGFloat = { d in CGFloat(max(0, min(1, d.timeIntervalSince(start) / end.timeIntervalSince(start)))) * w }
            ZStack(alignment: .topLeading) {
                Capsule().fill(Hub.surface).frame(height: 8).offset(y: 22)
                ForEach(evs) { e in
                    let cur = e.start <= now && now < e.end
                    Capsule().fill(cur ? Hub.ink : Hub.ink.opacity(0.35)).frame(width: max(4, x(e.end) - x(e.start)), height: 8).offset(x: x(e.start), y: 22)
                        .help(Hub.time(e.start) + "–" + Hub.time(e.end) + " " + Hub.canonicalNames(e.title))
                }
                if now > start && now < end {
                    // 지금 선은 무채색 — 적색 예산(화면 3곳)은 W 경보에만 (R2 lint, Light 외형 4곳 → 3곳)
                    Rectangle().fill(Hub.text).frame(width: 2, height: 16).offset(x: x(now) - 1, y: 18)
                }
                HStack(spacing: 14) {
                    if let c = evs.first(where: { $0.start <= now && now < $0.end }) {
                        Text("지금 " + Hub.canonicalNames(c.title) + " ~" + Hub.time(c.end)).font(.hub(11.5, weight: .semibold)).lineLimit(1)
                    }
                    ForEach(Array(next)) { e in
                        Text(Hub.relative(e.start, now: now) + " " + Hub.canonicalNames(e.title)).font(.hub(11.5)).foregroundStyle(Hub.text2).lineLimit(1)
                    }
                    if evs.isEmpty { Text(cal.isSettled ? "오늘 일정 없음" : "불러오는 중…").font(.hub(11.5)).foregroundStyle(cal.isSettled ? Hub.text3 : Hub.text2) }
                }
            }
        }
    }
}

/// 확인함 저장 — UserDefaults, 키 = 경보 id + 제목 (내용이 바뀌면 다시 경보), 7일 뒤 만료
enum AlertAck {
    static func key(_ a: HubAlert) -> String { a.id + "|" + a.title }
    static func load() -> [String: Double] {
        let d = (UserDefaults.standard.dictionary(forKey: "DeskHub.alertAck") as? [String: Double]) ?? [:]
        let cutoff = Date().timeIntervalSince1970 - 7 * 86400
        return d.filter { $0.value > cutoff }
    }
    static func save(_ d: [String: Double]) { UserDefaults.standard.set(d, forKey: "DeskHub.alertAck") }
}
