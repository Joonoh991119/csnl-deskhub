import SwiftUI

// MARK: - 하루 국면 → 안내판 주인공 (디자인 계획 D9 — §2 C)
// 순수 함수: 같은 (지금·모델·캘린더) 이면 같은 주인공. `DeskHub --dump-phase <dir>` 로 표 확인.
// 우선순위: 밤(22–08) 다음 아침 첫 일정 > 48시간 안 마감 > GRM 전날 17시~당일 정오 > 평일 아침(08–10) 첫 일정 > 저녁(18시~) 내일 첫 일정 > 그 밖엔 다음 일정

struct PhaseHero {
    enum Kind: String { case night = "밤", deadline = "마감", grm = "GRM", morning = "아침", evening = "저녁", next = "다음" }
    let kind: Kind
    let title: String
    var subtitle: String = ""
    var date: Date? = nil
    var link: HubLink? = nil
}

enum Phase {
    @MainActor
    static func hero(now: Date, model m: NotionHubModel, cal: CalendarModel?) -> PhaseHero {
        let c = Calendar.current
        let hour = c.component(.hour, from: now)
        let today = c.startOfDay(for: now)
        let weekday = c.component(.weekday, from: now)   // 1 일요일 … 7 토요일
        let events = cal?.upcoming(days: 3).filter { !$0.isAllDay } ?? []

        if hour >= 22 || hour < 8 {
            // 밤: 시계는 이미 크게 있으므로 주인공은 '다음 아침 첫 일정' (없으면 조용히)
            let morning = hour >= 22 ? c.date(byAdding: .day, value: 1, to: today)! : today
            if let e = events.first(where: { c.isDate($0.start, inSameDayAs: morning) && $0.start > now }) {
                return PhaseHero(kind: .night, title: (hour >= 22 ? "내일 " : "오늘 ") + Hub.canonicalNames(e.title), subtitle: Hub.relative(e.start, now: now), date: e.start, link: .calendarDay(e.start))
            }
            return PhaseHero(kind: .night, title: "조용한 밤", subtitle: Hub.longDay(now))
        }
        // 48시간 안 마감 — 컨펌한 리마인더·날짜 있는 그랜트
        let soon = now.addingTimeInterval(48 * 3600)
        var deadlines: [(String, Date, HubLink?)] = m.confirmedReminders.compactMap { r in
            guard let d = r.day else { return nil }
            let due = deadlineTime(r.title, day: d)
            return due >= now && due <= soon ? (r.title, due, nil) : nil
        }
        for g in m.grants { if let d = g.due { let due = deadlineTime(g.title, day: d); if due >= now && due <= soon && !deadlines.contains(where: { c.isDate($0.1, inSameDayAs: due) }) { deadlines.append((g.title, due, nil)) } } }
        if let d = deadlines.min(by: { $0.1 < $1.1 }) {
            return PhaseHero(kind: .deadline, title: d.0, subtitle: Hub.relative(d.1, now: now) , date: d.1, link: d.2)
        }
        // GRM 전날 17시 ~ 당일 정오
        if let g = m.grm.first(where: { $0.date >= today }) {
            let eve = c.date(byAdding: .hour, value: -7, to: g.date)!   // 전날 17:00
            let noon = c.date(bySettingHour: 12, minute: 0, second: 0, of: g.date)!
            if now >= eve && now < noon {
                let pips = [g.notified ? "공지✓" : "공지—", g.abstractDone ? "초록✓" : "초록—"].joined(separator: " ")
                return PhaseHero(kind: .grm, title: "GRM · " + (g.presenters.isEmpty ? "발표자 미정" : g.presenters),
                                 subtitle: Hub.relative(c.date(bySettingHour: 10, minute: 0, second: 0, of: g.date)!, now: now) + " · " + pips, date: g.date, link: .notion(g.id))
            }
        }
        // 평일 아침 — 오늘 첫 일정 + 실험
        if (2...6).contains(weekday) && hour < 10 {
            let first = events.first { c.isDate($0.start, inSameDayAs: now) && $0.end > now }
            let ex = m.experiments.isEmpty ? "" : " · 실험 \(m.experiments.count)건"
            if let e = first { return PhaseHero(kind: .morning, title: Hub.canonicalNames(e.title), subtitle: Hub.relative(e.start, now: now) + ex, date: e.start, link: .calendarDay(e.start)) }
        }
        // 저녁 — 내일 첫 일정
        if hour >= 18 {
            let tomorrow = c.date(byAdding: .day, value: 1, to: today)!
            if let e = events.first(where: { c.isDate($0.start, inSameDayAs: tomorrow) }) {
                return PhaseHero(kind: .evening, title: "내일 " + Hub.canonicalNames(e.title), subtitle: Hub.relative(e.start, now: now), date: e.start, link: .calendarDay(e.start))
            }
        }
        if let e = events.first(where: { $0.end > now }) {
            let cur = e.start <= now
            return PhaseHero(kind: .next, title: Hub.canonicalNames(e.title),
                             subtitle: cur ? "진행 중 · 남은 \(Int(e.end.timeIntervalSince(now) / 60))분" : Hub.relative(e.start, now: now), date: e.start, link: .calendarDay(e.start))
        }
        return PhaseHero(kind: .next, title: "남은 일정 없음", subtitle: Hub.longDay(now))
    }

    /// 제목에 "(18:00)" 같은 시각이 있으면 그 시각, 없으면 그날 23:59
    static func deadlineTime(_ title: String, day: Date) -> Date {
        let c = Calendar.current
        if let r = title.range(of: "(\\d{1,2}):(\\d{2})", options: .regularExpression) {
            let p = title[r].split(separator: ":").compactMap { Int($0) }
            if p.count == 2, let d = c.date(bySettingHour: p[0], minute: p[1], second: 0, of: day) { return d }
        }
        return c.date(bySettingHour: 23, minute: 59, second: 0, of: day)!
    }

    /// --dump-phase: 지금 + 국면 표본 4개 시각 (오늘 09:00 · 다음 GRM 전날 17:30 · 가장 가까운 마감 47시간 전 · 오늘 23:00)
    @MainActor
    static func dump(model m: NotionHubModel, cal: CalendarModel?, now: Date) -> String {
        let c = Calendar.current
        let today = c.startOfDay(for: now)
        var samples: [(String, Date)] = [("지금", now), ("오늘 09:00", today.addingTimeInterval(9 * 3600)), ("오늘 23:00", today.addingTimeInterval(23 * 3600))]
        if let g = m.grm.first(where: { $0.date > today }) { samples.append(("GRM 전날 17:30", g.date.addingTimeInterval(-6.5 * 3600))) }
        if let r = m.confirmedReminders.first(where: { ($0.day ?? .distantPast) > now }), let d = r.day {
            samples.append(("마감 47h 전", deadlineTime(r.title, day: d).addingTimeInterval(-47 * 3600)))
        }
        return samples.map { label, t in
            let h = hero(now: t, model: m, cal: cal)
            return "\(label) (\(Hub.day(t)) \(Hub.time(t))) → [\(h.kind.rawValue)] \(h.title) · \(h.subtitle)"
        }.joined(separator: "\n")
    }
}
