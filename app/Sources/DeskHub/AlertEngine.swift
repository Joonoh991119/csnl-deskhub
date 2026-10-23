import SwiftUI

// MARK: - 경보 엔진 (디자인 계획 D3 — docs/design-plan-2026-10-14.md §2 A 관제탑)
// 화면에 올리기 전에 '경보'와 '참조'를 가른다. 경보는 세 등급:
//   W(경고, 오늘·내일 꼭 처리) · C(주의, 며칠 안) · A(알림, 알아만 두기)
// 순수 함수 — 같은 입력(모델·캘린더·지금·나)이면 같은 결과. `DeskHub --dump-alerts <dir>` 로 텍스트 확인.
// 같은 사건(BK21 리마인더 = 그랜트 마감)은 한 줄로 묶고 출처를 더한다. 등급별 상한 W3·C5·A3, 넘치면 overflow.
// 문구 한 틀 (UX game-hud-5, 0.34.0): 제목 = [짧은 상태/종류] · [대상] (AlertEngine.title), 누구 = owner(이니셜), 얼마나 =
//   마감이 있으면 시간 칸(MenuBarLine.compact)이 맡고 제목에 D-n 을 다시 쓰지 않는다. 마감이 없으면 n건·19/20·n일 지남.
//   소스 오류(src-*)는 대상을 앞에('NAS · 연결 안 됨'), 원인은 detail 에 반드시. detail 은 제목에 이미 있는 낱말을 되풀이하지 않는다.

struct HubAlert: Identifiable, Equatable {
    enum Level: Int, Comparable {
        case warning = 0, caution = 1, advisory = 2
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        var mark: String { switch self { case .warning: return "■"; case .caution: return "□"; case .advisory: return "·" } }
    }
    let id: String
    let level: Level
    let title: String
    var detail: String = ""
    var due: Date? = nil
    var hasTime: Bool = false
    /// 이 맥 사용자(me) 와 관련 있음 — C·A 는 내 것이 위로
    var mine: Bool = false
    /// 담당(누구) — 이니셜, 여럿이면 ", " 로. 비면 담당 없음 (관제탑 meta 줄 맨 앞, 덤프 @XXX)
    var owner: String = ""
    var link: HubLink? = nil
    var sources: [String] = []
    /// W 행(과 지난 리마인더 C)에만 붙는 행동 한 개의 이름 (버튼은 뷰가 그린다)
    var action: String? = nil
    /// 마감 날이 어제 이전(달력 날짜)인 리마인더 (0.43.0 C1, #46 결정 D-1 — '24시간' 이 아니라 날짜: 10-18 마감은 10-19 0시부터).
    /// 같은 날 시각이 지난 것은 overdue 아님(맨 위 유지). 같은 등급 안에서 맨 아래로, 상한 밖(AlertEngine.order) — 팝오버는 한 줄로 접는다
    var overdue: Bool = false
    /// 호버 레일 '미루기'(+7일) 를 보일지 — 지난 리마인더이고, 이 맥에서 확인한 신원(actor)이 있고, 그 사람 것이거나 그 사람이 등록한 것일 때만
    /// (남의 마감을 공용 맥에서 미루지 않게). 보기 렌즈(me — 관제탑 로스터에서 고른 10분 '대상')로는 판정하지 않는다
    var snoozable: Bool = false

    static func == (a: HubAlert, b: HubAlert) -> Bool {
        a.id == b.id && a.level == b.level && a.title == b.title && a.detail == b.detail && a.sources == b.sources && a.mine == b.mine
            && a.owner == b.owner && a.action == b.action && a.overdue == b.overdue && a.snoozable == b.snoozable
    }
    /// owner 토큰 가운데 이 이니셜이 있나 (토큰 단위 — 부분 문자열이면 BHL·BYL·SL·JSL 이 섞인다)
    func owned(by initials: String) -> Bool {
        let key = initials.uppercased()
        guard !key.isEmpty, !owner.isEmpty else { return false }
        return owner.uppercased().split { !($0.isLetter || $0.isNumber) }.contains { String($0) == key }
    }
}

struct AlertSet {
    var alerts: [HubAlert]
    /// 상한으로 잘린 개수 (등급별)
    var overflow: [HubAlert.Level: Int]
    var counts: [HubAlert.Level: Int] { Dictionary(grouping: alerts, by: \.level).mapValues(\.count) }
    var isClear: Bool { alerts.isEmpty }
    /// 지금 할 것 — 어제 이전 마감(overdue)이 아닌 경보 (0.44.0 #68). 관제탑 행·머리 수·j/k 는 이것
    var live: [HubAlert] { alerts.filter { !$0.overdue } }
    /// 지난 마감 — advisory 아닌 overdue. 관제탑·팝오버 모두 맨 아래 '지난 마감 n건 ▸' 한 줄로 접힌다 (0.44.0 #68, 0.43.0 C1 팝오버와 같은 말)
    var lapsed: [HubAlert] { alerts.filter { $0.overdue && $0.level != .advisory } }
    var liveCounts: [HubAlert.Level: Int] { Dictionary(grouping: live, by: \.level).mapValues(\.count) }
    /// 관제탑 머리·alerts.txt 첫 줄 한 말 (0.44.0 #67, 결정 D-4) — '급함 n · 할 일 n · 참고 n'(지난 마감은 세지 않음 — 접힌 줄이 따로 셈). 순수.
    /// 급함 = W(오늘·내일 마감 · 오늘 GRM · 자료 끊김) · 할 일 = C(며칠 안 마감 · 공지 · 내 차례) · 참고 = A(알아만 둘 것)
    var headline: String { Self.headline(liveCounts) }
    /// alerts.txt 둘째 줄 — 관제탑이 보이는 것 '관제탑: 급함 n · 할 일 n · 참고 n · 지난 마감 n건 (접힘)[: 제목, …]' (0.44.0 #68)
    var towerLine: String {
        "관제탑: \(headline) · " + PopoverTodo.lapsedLabel(lapsed.count) + " (접힘)" + (lapsed.isEmpty ? "" : ": " + lapsed.map(\.title).joined(separator: ", "))
    }
    static func headline(_ c: [HubAlert.Level: Int]) -> String {
        HubAlert.Level.ordered.map { "\($0.word) \(c[$0] ?? 0)" }.joined(separator: " · ")
    }
}

extension HubAlert.Level {
    /// 등급의 말 (0.44.0 #67) — 행 앞 ■ □ · 표식은 그대로, 머리·덤프는 말로
    var word: String { switch self { case .warning: return "급함"; case .caution: return "할 일"; case .advisory: return "참고" } }
    /// 머리 칸 도움말
    var wordHelp: String {
        switch self {
        case .warning: return "급함 — 오늘·내일 마감 · 오늘 GRM · 자료 끊김"
        case .caution: return "할 일 — 며칠 안 마감 · 공지 · 내 차례"
        case .advisory: return "참고 — 알아만 둘 것"
        }
    }
    static let ordered: [HubAlert.Level] = [.warning, .caution, .advisory]
}

enum AlertEngine {
    static let caps: [HubAlert.Level: Int] = [.warning: 3, .caution: 5, .advisory: 3]

    /// 경보 문구 한 틀 — 조각을 ' · ' 로 잇는다. 빈 조각(앞뒤 공백 포함)은 빼므로 ' ·  · ' 가 생기지 않는다. detail 도 같은 함수로
    static func title(_ head: String, _ parts: String...) -> String {
        ([head] + parts).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 리마인더 하나와 그랜트 하나가 같은 사건인가 (검증 1). 날짜만 같다고 합치면, 미루기(+7일)로 그날에 옮겨 온 관계없는 리마인더가
    /// 그랜트 마감을 숨긴다. 같은 사건 = 그랜트 제안으로 등록한 id('grant:'+제목) · 제목에 그랜트 제목이 들어 있음 ·
    /// 뜻 있는 낱말 2개 이상 겹침(BK21 '자체평가 항목별 실적 제출 (18:00)' ↔ 그랜트 '자체평가 항목별 실적 2026'). 숫자·제출 같은 흔한 낱말은 안 셈
    static func sameEvent(reminderID: String, reminderTitle: String, grantTitle: String) -> Bool {
        let g = grantTitle.trimmingCharacters(in: .whitespaces)
        guard !g.isEmpty else { return false }
        // id: 옛 형식 'grant:'+제목, 0.35.0 형식 'grant:'+제목+'@'+마감일 (R2)
        if reminderID == "grant:" + g || reminderID.hasPrefix("grant:" + g + "@") || reminderTitle.contains(g) { return true }
        func words(_ t: String) -> Set<String> {
            Set(t.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
                .filter { $0.count >= 2 && Int($0) == nil && !genericWords.contains($0) })
        }
        return words(reminderTitle).intersection(words(g)).count >= 2
    }
    private static let genericWords: Set<String> = ["제출", "접수", "마감", "보고", "신청", "초록", "준비", "일정", "결과", "회의"]

    /// 그랜트 마감 시각 (0.42.0 C1, #39) — 제목에 'HH:mm' 이 있으면 그 시각(Phase.deadlineTime), 없으면 dueNote 의 첫 'HH:mm'
    /// (실제 grants_schedule.json 은 시각을 dueNote 에 적는다: '연구원 컨펌 마감 10/15(목) 18:00 → …', 검증 1 리뷰), 둘 다 없으면 그날 23:59.
    /// 경보·8주 띠·팝오버 '할 것'·메뉴 막대·안내판·Phase 가 같은 값을 쓴다. 자정으로 두면 18:00 마감이 당일 오전부터 '지남'.
    /// 제목의 'n:n' 숫자(예 '2:1 매칭')도 시각으로 읽힌다 — 리마인더와 같은 규칙(fixture 에 적음)
    static func grantDue(title: String, dueNote: String = "", day: Date) -> (due: Date, hasTime: Bool) {
        func clock(_ s: String) -> Bool { s.range(of: "\\d{1,2}:\\d{2}", options: .regularExpression) != nil }
        if clock(title) { return (Phase.deadlineTime(title, day: day), true) }
        if clock(dueNote) { return (Phase.deadlineTime(dueNote, day: day), true) }
        return (Phase.deadlineTime(title, day: day), false)
    }

    /// 미루기를 할 수 있는 사람 = 이 맥에서 확인한 이니셜(HubPrefs.meChosen). 확인 전·비었으면 "" → 미루기 없음 (반응 쓰기와 같은 조건)
    static var snoozeActor: String { HubPrefs.meChosen ? HubPrefs.me.trimmingCharacters(in: .whitespaces) : "" }

    /// me = 보기 렌즈(정렬·'내 것'). actor = 쓰기(미루기) 권한 — nil 이면 snoozeActor
    @MainActor
    static func evaluate(_ m: NotionHubModel, cal: CalendarModel?, now: Date, me: String, actor: String? = nil) -> AlertSet {
        let actor = actor ?? snoozeActor
        let actorMember = actor.isEmpty ? nil : m.myMember(actor)
        let cal0 = Calendar.current
        let today = cal0.startOfDay(for: now)
        func days(_ d: Date) -> Int { cal0.dateComponents([.day], from: today, to: cal0.startOfDay(for: d)).day ?? 99 }
        let meMember = m.myMember(me)
        func isMine(_ text: String) -> Bool { m.isMine(text, me: me) }
        var out: [HubAlert] = []

        // 소스 끊김 — 화면을 믿을 수 없으면 가장 먼저 (W)
        // 대상 먼저 · 상태 — 원인(이유·경로)은 detail 에 반드시 (비면 무엇이 왜 깨졌는지 알 수 없다)
        if let why = m.remindersLocked {
            out.append(HubAlert(id: "src-reminders", level: .warning, title: title("리마인더 파일", "손상"), detail: why.isEmpty ? "reminders.json 형식 오류" : why,
                                link: .nas(m.remindersPath), sources: ["NAS"]))
        }
        if let f = m.reminderSaveFailed {
            out.append(HubAlert(id: "src-save-\(f.id)", level: .warning, title: title("리마인더", "저장 실패"),
                                detail: title(f.title, (m.remindersPath as NSString).lastPathComponent + " 쓰기 실패"),
                                link: .nas(m.remindersPath), sources: ["NAS"], action: "다시 시도"))
        }
        // m.error 는 여러 실패가 함께 쓰는 칸 — 제목을 갈라 붙이고, 리마인더 저장 실패는 위 줄과 겹치므로 뺀다
        if let e = m.error, !e.isEmpty, !(m.reminderSaveFailed != nil && e.hasPrefix("리마인더")) {
            let nas = e.hasPrefix("NAS") || e.hasPrefix("리마인더")
            let target = e.hasPrefix("NAS") ? "NAS" : e.hasPrefix("리마인더") ? "리마인더" : e.hasPrefix("반응") ? "반응·댓글" : "Notion"
            let state = e.hasPrefix("NAS") ? "연결 안 됨" : (e.hasPrefix("리마인더") || e.hasPrefix("반응") ? "저장 실패" : "불러오기 실패")
            out.append(HubAlert(id: "src-notion", level: .warning, title: title(target, state), detail: e, sources: [nas ? "NAS" : "Notion"]))
        }

        // 리마인더 (컨펌한 것만) — D≤1 W, D≤3 C. 지난 것은 7일까지 C('끝남' 버튼으로 정리 유도) 뒤 사라짐 — 영구 W 는 알람 피로
        for r in m.confirmedReminders {
            guard let d = r.day else { continue }
            let n = days(d)
            let level: HubAlert.Level? = n < 0 ? (n >= -7 ? .caution : nil) : (n <= 1 ? .warning : (n <= 3 ? .caution : nil))
            guard let level else { continue }
            // 제목에 시각이 있으면 그 시각을 마감으로 (BK21 '(18:00)') — 자정으로 두면 당일 오전부터 '지남'이 됨
            let hasClock = r.title.range(of: "\\d{1,2}:\\d{2}", options: .regularExpression) != nil
            // detail: 제목에 kind 가 이미 있으면 빼고('… 제출 (18:00) — 제출' 중복), 지난 것은 정도('n일 지남')
            // 학회 마감 리마인더는 '제출' 대신 '마감'(카드 꼬리표와 같은 말, 0.44.0 #62 검증 1)
            let k = RemindersFile.displayKind(r)
            let kindText = k.isEmpty || r.title.contains(k) ? "" : k
            // 미루기: 지난 것 + actor(이 맥에서 확인한 신원) 있음 + (제목이 actor 것 || actor 가 등록). 보기 렌즈 me 로 판정하지 않는다 (검증 1)
            // by 가 없으면(nil) false — [actor, nil].contains(nil) 이 참이 되지 않게 by 를 먼저 푼다
            let byActor = !actor.isEmpty && (r.by.map { b in [actor.uppercased(), actorMember?.initials.uppercased()].contains(b.uppercased()) } ?? false)
            let actorOwns = !actor.isEmpty && (m.isMine(r.title, me: actor) || byActor)
            out.append(HubAlert(id: "rem-" + r.id, level: level, title: r.title, detail: title(kindText, n < 0 ? "\(-n)일 지남" : ""),
                                // 시각 없는 리마인더도 그날 23:59 (그랜트·안내판·Phase 와 같은 규칙) — 자정이면 그날 0시부터 '지남' (검증 1 리뷰)
                                due: Phase.deadlineTime(r.title, day: d), hasTime: hasClock, mine: isMine(r.title),
                                link: r.source.hasPrefix("notion:") ? .notion(String(r.source.dropFirst(7))) : .nas(m.remindersPath),
                                sources: ["리마인더"], action: (level == .warning || n < 0) ? "끝남" : nil,
                                overdue: n < 0, snoozable: n < 0 && actorOwns))
        }

        // 그랜트 — 확정 마감 D≤1 W(같은 날 '같은 사건' 리마인더가 있으면 그 줄에 출처만 더함 — 날짜만 같은 남의 줄엔 합치지 않음), 일정 미정·오래 확인 안 함 C
        for g in m.grants {
            if let d = g.due {
                let n = days(d)
                guard n <= 1 && n >= 0 else { continue }
                let ds = RemindersFile.dayFormatter.string(from: d)
                if let i = out.firstIndex(where: { $0.id.hasPrefix("rem-") && $0.due.map(RemindersFile.dayFormatter.string(from:)) == ds
                    && sameEvent(reminderID: String($0.id.dropFirst(4)), reminderTitle: $0.title, grantTitle: g.title) }) {
                    out[i].sources.append("그랜트")
                    // 리마인더 제목에 시각이 없고 그랜트(제목·dueNote)에 있으면 그 시각으로 — 두 경로가 다른 남은 시간을 보이지 않게
                    let gd = grantDue(title: g.title, dueNote: g.dueNote, day: d)
                    if gd.hasTime && !out[i].hasTime { out[i].due = gd.due; out[i].hasTime = true }
                } else {
                    let gd = grantDue(title: g.title, dueNote: g.dueNote, day: d)
                    out.append(HubAlert(id: "grant-" + g.id, level: .warning, title: title(g.kind, g.title), detail: g.dueNote, due: gd.due, hasTime: gd.hasTime, sources: ["그랜트"]))
                }
            }
        }
        // 일정 미정·오래 확인 안 한 그랜트는 한 줄로 묶는다 (같은 종류 = 한 사건)
        let checks = m.grants.filter { $0.due == nil && $0.needsCheck(today: today) }
        if !checks.isEmpty {
            out.append(HubAlert(id: "grantchk", level: .caution, title: title("일정 확인", "그랜트 \(checks.count)건"),
                                detail: checks.map(\.title).joined(separator: " · "), link: .nas(m.cfg.grantsFile), sources: ["그랜트"]))
        }

        // GRM — 오늘이면 W, 공지 미발송 D≤5 C, 내 차례 D≤7 C
        if let g = m.nextGRM {
            let n = days(g.date)
            let missing = [g.notified ? nil : "공지", g.abstractDone ? nil : "초록"].compactMap { $0 }
            // 발표자는 이니셜로 (화면은 이니셜 규칙). '내 것' 판정은 원래 이름 문자열로 — 이니셜 변환 뒤 문자열로 바꾸지 않는다
            let who = m.initialsList(g.presenters)
            // GRM 은 오전(10:00~11:30)에 하므로 정오가 지나면 '오늘 GRM' 경보는 내린다 (lastGRM 판정과 같은 기준)
            let noon = cal0.date(bySettingHour: 12, minute: 0, second: 0, of: today)!
            if n == 0 && now < noon {
                out.append(HubAlert(id: "grm-today", level: .warning, title: title("오늘 GRM", who.isEmpty ? "발표자 미정" : who),
                                    detail: missing.isEmpty ? "공지·초록 완료" : missing.joined(separator: "·") + " 미완",
                                    due: cal0.date(bySettingHour: 10, minute: 0, second: 0, of: g.date), hasTime: true,
                                    mine: isMine(g.presenters), owner: who, link: .notion(g.id), sources: ["GRM"], action: "슬라이드"))
            } else if !g.notified && n > 0 && n <= 5 {
                // 제목이 이미 '공지 아직' — detail 엔 남은 것만 (둘 다 끝났으면 빈 칸)
                out.append(HubAlert(id: "grm-notice", level: .caution, title: title("GRM 공지 아직", "\(Hub.day(g.date)) \(who)"),
                                    detail: g.abstractDone ? "" : "초록 미완", due: g.date, mine: isMine(g.presenters), owner: who,
                                    link: .notion(g.id), sources: ["GRM"]))
            }
        }
        if let mm = meMember, let mine = m.grm.first(where: { $0.date >= today && ($0.presenters.contains(mm.name) || $0.presenters.contains(mm.initials)) }),
           days(mine.date) <= 7, days(mine.date) > 0, !out.contains(where: { $0.id == "grm-notice" && $0.mine }) {
            out.append(HubAlert(id: "grm-mine", level: .caution, title: title("내 GRM 차례", Hub.day(mine.date)), due: mine.date, mine: true, link: .notion(mine.id), sources: ["GRM"]))
        }

        // 실험 — Prolific Paused, 미연결은 A. 정도는 detail('19/20 제출')
        for x in m.experiments where x.status.lowercased() == "paused" {
            out.append(HubAlert(id: "exp-" + x.id, level: .caution, title: title("\(x.source) 멈춤", x.title), detail: x.detail,
                                mine: !x.owner.isEmpty && x.owner.uppercased() == (meMember?.initials ?? me).uppercased(), owner: x.owner,
                                link: x.url.map(HubLink.url), sources: [x.source]))
        }
        // 미연결은 설정 상태(#17 결정 대기)라 경보 아님. 조회 실패는 받아 둔 목록이 하나도 없을 때만
        if let n = m.prolificNote, !n.hasPrefix("Prolific 미연결"), !m.experiments.contains(where: { $0.source == "Prolific" }) {
            out.append(HubAlert(id: "exp-prolific", level: .advisory, title: n, sources: ["Prolific"]))
        }

        // 학회 초록 마감 D≤7 — A (가까우면 C)
        for c in m.conferences {
            guard let d = c.deadline else { continue }
            let n = days(d)
            guard n >= 0 && n <= 7 else { continue }
            // 이미 리마인더로 등록된 같은 마감이면 건너뜀
            if out.contains(where: { $0.id.hasPrefix("rem-") && $0.title.contains(c.conference) }) { continue }
            out.append(HubAlert(id: "conf-" + c.id, level: n <= 3 ? .caution : .advisory, title: title("초록 마감", c.conference), detail: c.deadlineLabel, due: d,
                                link: c.link.map(HubLink.url), sources: ["학회"]))
        }

        // 신선도 — 멈춘 소스는 A
        // 만성(30일 넘게 멈춘 추천)은 참조 레일 몫, 회의록·Blitz 는 주간 정리 주기(7일)가 지난 뒤에만
        let papersChronic = m.papers.compactMap(\.sentAt).max().map { days($0) < -ProducerRule.chronicDays } ?? false
        let weeklyDue = m.lastGRM.map { days($0.date) <= -7 } ?? false
        for (key, f) in [("papers", m.papersFreshness), ("minutes", m.minutesFreshness), ("blitz", m.blitzFreshness)] {
            guard let f, f.state == .stale else { continue }
            if key == "papers" && papersChronic { continue }
            if key != "papers" && !weeklyDue { continue }
            out.append(HubAlert(id: "fresh-" + key, level: .advisory, title: f.text, detail: f.help, sources: [key]))
        }

        return order(out)
    }

    /// 정렬·상한 (0.43.0 C1, #46) — 순수 함수. evaluate · text-check `todo` 가 같이 부른다.
    /// 정렬: 등급 → 어제 이전 마감(overdue)은 맨 뒤 → (C·A 는) 내 것 → 마감 가까운 순.
    /// 상한 W3·C5·A3 는 overdue 가 아닌 것에만 — overdue 는 늘 남긴다(7일 창이라 개수에 끝이 있음, '끝남' 정리가 닿게). 그래서 각 등급 안에서 지난 것이 맨 아래
    static func order(_ input: [HubAlert]) -> AlertSet {
        let out = input.sorted { a, b in
            if a.level != b.level { return a.level < b.level }
            if a.overdue != b.overdue { return !a.overdue }
            if a.level != .warning && a.mine != b.mine { return a.mine }
            return (a.due ?? .distantFuture) < (b.due ?? .distantFuture)
        }
        var kept: [HubAlert] = [], overflow: [HubAlert.Level: Int] = [:]
        for a in out {
            if a.overdue { kept.append(a); continue }
            let n = kept.filter { $0.level == a.level && !$0.overdue }.count
            if n < (caps[a.level] ?? 3) { kept.append(a) } else { overflow[a.level, default: 0] += 1 }
        }
        return AlertSet(alerts: kept, overflow: overflow)
    }

    /// 텍스트 한 장 — --dump-alerts 용. isMember = 멤버 이니셜인가 — '@' 는 멤버에게만 붙인다('외부'·외부 발표자 이름은 멘션하지 않음, 0.40.0 C1 F0-1)
    @MainActor
    static func dump(_ set: AlertSet, now: Date, isMember: (String) -> Bool = { _ in true }) -> String {
        var lines = ["경보 \(Hub.day(now)) \(Hub.time(now)) — \(set.headline)", set.towerLine]
        if set.isClear { lines.append("✓ 경보 없음") }
        for a in set.alerts {
            let due = (a.due.map { " [" + Hub.relative($0, now: now, hasTime: a.hasTime) + "]" } ?? "") + (a.overdue ? " (지남)" : "")
            let owner = a.owner.isEmpty ? "" : " " + a.owner.components(separatedBy: ", ").map { isMember($0) ? "@" + $0 : $0 }.joined(separator: " ")
            lines.append("\(a.level.mark) \(a.title)\(due)" + (a.detail.isEmpty ? "" : " — \(a.detail)") + (a.mine ? " (내 것)" : "") + owner
                         + " {\(a.sources.joined(separator: "+"))}" + (a.action.map { " <\($0)>" } ?? "") + (a.snoozable ? " ⟲미루기" : ""))
        }
        for (l, n) in set.overflow.sorted(by: { $0.key < $1.key }) { lines.append("\(l.mark) +\(n) 더") }
        return lines.joined(separator: "\n")
    }
}
