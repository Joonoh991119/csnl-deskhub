import SwiftUI
import AppKit
import EventKit

// MARK: - 모델

struct CalEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let colorHex: String          // Hashable 을 위해 색은 hex 로
    let location: String?
    let calendarName: String
    var color: Color { Color(nsColor: NSColor(hex: colorHex) ?? NSColor(hex: "#1F3B5C")!) }
}

enum CalendarStatus: Equatable { case loading, ready, noSource, denied }

@MainActor
final class CalendarModel: ObservableObject {
    @Published var day: Date
    @Published var events: [CalEvent] = []
    @Published var allDay: [CalEvent] = []
    @Published var status: CalendarStatus = .loading
    @Published var now = HubClock.now
    @Published var sourceLabel = ""
    @Published var lastUpdated: Date?
    @Published var lastError: String?
    /// 시간표 수업 행 (0.44.0 B1, #58) — NotionHubModel.loadCourses 가 싣는다. NowNextLine 이 오늘 내 수업을 지금·다음에 넣는다(호출처는 그대로)
    @Published var timetable: TimetableFeed?
    /// 첫 조회가 끝났는가 (0.37.0 C6, D-2) — start() 의 첫 loadICS·probeEventKit·refresh 뒤 true(성공·실패 무관), 다시 false 가 되지 않는다.
    /// 그 전의 빈 일정은 '없음' 이 아니라 '불러오는 중…' (보드·관제탑·허브·팝오버·앰비언트·캘린더 창). status·icsSettled 는 그대로
    @Published private(set) var isSettled = false
    /// 시험 훅 DESKHUB_CAL_DELAY=<초> 로 첫 조회를 미루는 중 — 그동안 refreshIfStale(팝오버·스냅샷)이 먼저 조회하지 않게
    private var testDelaying = false
    /// 자정이 지나면 자동으로 오늘로 넘어갈지 (다른 날짜를 보고 있으면 false)
    private var followToday = true

    let cfg: CalendarConfig
    private let store = EKEventStore()
    private var eventKitOK = false
    private var icsCalendars: [ICSCalendar] = []
    /// 소스 URL → 마지막으로 받아 둔 캘린더. 한 소스가 일시 실패(잠자기 직후 Wi-Fi 전 -1009·5xx·포털 HTML)해도 그 소스는 이전 것을 유지한다 (검증 1)
    private var icsBySource: [String: ICSCalendar] = [:]
    private var refreshTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    /// TTL 기준 시각 — 마지막 ICS 네트워크 조회를 시작한 때(목록 읽기 뒤, 실패면 그 시각 − ttl/2). refresh() 는 EventKit 변경·자정에도 돌아 lastUpdated 로는 ICS 나이를 모른다
    private var icsFetchedAt: Date?
    private var reloading = false
    /// loadICS 는 한 번에 하나 (R-L3, 0.36.0) — 시작·주기 루프·refreshIfStale 세 경로가 같은 가드를 지난다. 겹친 호출은 건너뛰고 센다
    private var icsLoading = false
    private var icsSkipped = 0
    /// 마지막으로 refreshIfStale 이 받은 ttl (기본 = PopoverRefresh.ttl). 실패 뒤 백오프는 이것의 절반 (리뷰 R3, 0.35.0)
    private var lastStaleTTL: TimeInterval = PopoverRefresh.ttl
    /// 마지막으로 SSOT 목록을 제대로 읽었을 때의 소스(설정 icsURLs 포함). 목록을 못 읽는 동안은 이것으로 조회하고 받아 둔 캘린더를 버리지 않는다 (리뷰 R1, 0.35.0)
    private var lastGoodSources: [String] = []
    // 관측 (windows.txt 'ics:' 줄) — URL·토큰은 담지 않는다
    private var lastListOK = true
    private var lastSourceCount = 0
    private var icsLoadCount = 0
    private var lastICSAttempt: Date?
    /// 첫 ICS 조회가 끝났는지 — 그 전의 refresh() 는 소스 없음으로 판정하지 않는다(목록을 아직 안 읽었을 뿐)
    private var icsSettled = false

    var isToday: Bool { Calendar.current.isDate(day, inSameDayAs: HubClock.now) }
    private var eventKitHasEvents = false
    /// refresh() 마다 NAS 파일을 다시 읽지 않는다. 목록을 못 읽는 동안에도 이전에 읽은 소스·받아 둔 캘린더가 있으면 .noSource 로 떨어지지 않게 (R1)
    var hasNativeSource: Bool {
        (eventKitOK && eventKitHasEvents) || !icsCalendars.isEmpty || !lastGoodSources.isEmpty || !cfg.icsURLs.isEmpty
    }
    /// SSOT 파일 경로. 테스트 훅 (0.35.0): DESKHUB_ICS_SSOT=<경로> 면 설정 대신 그 파일 — 설정 스키마는 그대로 (DESKHUB_REMINDERS 와 같은 방식)
    private var icsSSOTPath: String {
        if let p = ProcessInfo.processInfo.environment["DESKHUB_ICS_SSOT"], !p.isEmpty { return (p as NSString).expandingTildeInPath }
        return cfg.icsSSOTFile
    }
    /// 설정의 icsURLs + SSOT 파일의 키 값(중복 제거)과, 목록을 제대로 읽었는지(listOK). NAS 가 늦게 붙어도 다음 조회 때 다시 읽는다.
    /// listOK=false — SSOT 경로가 설정됐는데 파일을 못 읽었거나 내용이 공백뿐(NAS 가 반쯤 붙은 상태). 이때 urls 는 설정 icsURLs 뿐이고, loadICS 가 이전 목록을 유지한다.
    /// 파일을 읽었는데 키가 없으면 listOK=true(설정에서 정말 뺀 것 → 그 소스는 버린다).
    /// 주의: 빈 파일은 '못 읽음' 으로 본다. ICS 키를 전부 지울 때 파일을 비우면 이전 소스가 계속 남으므로, 다른 줄(주석 등)을 남겨야 정리된다.
    func readICSSources() -> (urls: [String], listOK: Bool) {
        var out = cfg.icsURLs
        let path = icsSSOTPath
        guard !path.isEmpty else { return (out, true) }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (out, false) }
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            for k in cfg.icsSSOTKeys where t.hasPrefix(k + "=") {
                let v = String(t.dropFirst(k.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                if !v.isEmpty && !out.contains(v) { out.append(v) }
            }
        }
        return (out, true)
    }

    /// windows.txt 관측 줄 (0.35.0) — 개수·상태·호스트만, URL·토큰은 넣지 않는다
    var debugLine: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm:ss"
        var parts = ["ics: 소스 \(lastSourceCount)", isSettled ? "첫 조회 끝" : "첫 조회 전", lastListOK ? "목록 읽음" : "목록 못 읽음(이전 유지)",
                     "캘린더 \(icsCalendars.count)", "조회 \(icsLoadCount)회",
                     "마지막 시도 " + (lastICSAttempt.map(f.string(from:)) ?? "—"),
                     "TTL 기준 " + (icsFetchedAt.map(f.string(from:)) ?? "—"),
                     "겹침 건너뜀 \(icsSkipped)"]
        let err = (lastError ?? "없음").replacingOccurrences(of: "://", with: ":")   // 혹시라도 URL 모양이 새지 않게
        parts.append("오류 " + err)
        return parts.joined(separator: " · ")
    }

    /// macOS 캘린더에 앞뒤 2주 동안 일정이 하나라도 있는지 (기본 빈 캘린더만 있으면 웹으로 넘기기 위해)
    private func probeEventKit() {
        guard eventKitOK else { eventKitHasEvents = false; return }
        let cals = store.calendars(for: .event).filter(allowed).filter { $0.type != .subscription && $0.type != .birthday }
        guard !cals.isEmpty else { eventKitHasEvents = false; return }
        let from = Calendar.current.date(byAdding: .day, value: -14, to: Date())!
        let to = Calendar.current.date(byAdding: .day, value: 14, to: Date())!
        let pred = store.predicateForEvents(withStart: from, end: to, calendars: cals)
        eventKitHasEvents = !store.events(matching: pred).isEmpty
    }

    init(cfg: CalendarConfig) {
        self.cfg = cfg
        self.day = Calendar.current.startOfDay(for: HubClock.now)
        Task { await start() }
    }

    private func start() async {
        if cfg.useEventKit {
            let st = EKEventStore.authorizationStatus(for: .event)
            if st == .fullAccess { eventKitOK = true }
            else if st == .notDetermined {
                eventKitOK = (try? await store.requestFullAccessToEvents()) ?? false
            } else if st == .denied || st == .restricted {
                eventKitOK = false
            }
        }
        // 시험 훅 (0.37.0 C6) — 첫 ICS 조회 앞에서 기다린다(기본 꺼짐). '불러오는 중…' 화면을 스냅샷으로 확인
        if let d = ProcessInfo.processInfo.environment["DESKHUB_CAL_DELAY"].flatMap(Double.init), d > 0 {
            testDelaying = true
            try? await Task.sleep(nanoseconds: UInt64(d * 1_000_000_000))
            testDelaying = false
        }
        await loadICS()
        probeEventKit()
        refresh()
        isSettled = true
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let m = max(1, self?.cfg.refreshMinutes ?? 5)
                try? await Task.sleep(nanoseconds: UInt64(m) * 60_000_000_000)
                guard let self else { return }
                await self.loadICS()
                self.probeEventKit()
                self.refresh()
            }
        }
        clockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self else { return }
                self.now = HubClock.now
                if self.followToday && !Calendar.current.isDate(self.day, inSameDayAs: HubClock.now) {
                    self.day = Calendar.current.startOfDay(for: HubClock.now)
                    self.refresh()
                }
            }
        }
    }

    /// 팝오버를 열 때 (UX menubar-glance-67, 0.34.0): 마지막 ICS 조회가 ttl 보다 오래면 ICS·EventKit 을 다시 읽는다. 진행 중이면 그대로
    func refreshIfStale(ttl: TimeInterval) {
        lastStaleTTL = ttl
        guard !reloading, !icsLoading, !testDelaying else { return }
        if let t = icsFetchedAt, Date().timeIntervalSince(t) < ttl { return }
        reloading = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadICS()
            self.probeEventKit()
            self.refresh()
            self.reloading = false
        }
    }

    private func loadICS() async {
        // 한 번에 하나 (R-L3) — 겹친 조회가 서로의 icsFetchedAt 을 덮지 않게. 다음 주기나 팝오버 열기가 다시 부른다
        guard !icsLoading else { icsSkipped += 1; return }
        icsLoading = true
        defer { icsLoading = false }
        let (listed, listOK) = readICSSources()
        // 측정 시점 = 실제 네트워크 조회 시작 (NAS 목록 읽기 뒤 — NAS 가 반쯤 붙으면 목록 읽기만 수 초, R-L3)
        let fetchStarted = Date()
        icsFetchedAt = fetchStarted
        icsLoadCount += 1
        lastICSAttempt = fetchStarted
        // 목록을 읽었으면 그 목록이 기준. 못 읽었으면(NAS 반쯤 붙음·파일 없음) 마지막으로 읽은 목록 ∪ 설정 icsURLs 로 조회하고 버리지 않는다 (R1)
        let sources: [String]
        if listOK {
            sources = listed
            lastGoodSources = listed
        } else {
            sources = lastGoodSources + cfg.icsURLs.filter { !lastGoodSources.contains($0) }
        }
        lastListOK = listOK
        lastSourceCount = sources.count
        var errs: [String] = []
        for (i, s) in sources.enumerated() {
            guard let u = URL(string: s) else { continue }
            do {
                let (data, resp) = try await URLSession.shared.data(from: u)
                // 200 이 아니거나 ICS 가 아닌 본문(공용 Wi-Fi 로그인 페이지 등)은 실패로 — 빈 캘린더로 덮어쓰지 않게
                if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw URLError(.badServerResponse) }
                guard let text = String(data: data, encoding: .utf8), text.contains("BEGIN:VCALENDAR") else { throw URLError(.cannotParseResponse) }
                var c = ICSParser.parse(text)
                if c.colorHex == nil { c.colorHex = ICSCalendar.palette[i % ICSCalendar.palette.count] }
                icsBySource[s] = c
            } catch { errs.append(u.host ?? u.lastPathComponent) }
        }
        // 성공한 소스만 바뀌고 실패한 소스는 이전 것 그대로. 설정에서 빠진 소스만 버린다 — 목록을 제대로 읽었을 때만 (못 읽은 [] 로 전부 지우지 않게, R1)
        if listOK { icsBySource = icsBySource.filter { sources.contains($0.key) } }
        icsCalendars = sources.compactMap { icsBySource[$0] }
        var problems: [String] = []
        if !listOK { problems.append("ICS 소스 목록(NAS tokens.env)을 읽지 못함 — 이전 캘린더 유지") }
        if !errs.isEmpty { problems.append("ICS 불러오기 실패: " + errs.joined(separator: ", ")) }
        lastError = problems.isEmpty ? nil : problems.joined(separator: " · ")
        icsSettled = true
        // 실패(소스 조회 실패·목록 못 읽음)면 TTL 시계를 절반만 되돌린다 — 깨운 직후 한 번 실패가 ttl 전체를 묶지도,
        // 계속 실패하는 동안 팝오버를 열 때마다 다시 조회하지도 않게: 실패한 조회를 '시작한' 때부터 ttl/2 가 지나야 다시 시도 (R3).
        // 끝난 때부터 재면 네트워크 조회 시간(수 초~십여 초)만큼 간격이 늘어난다 (검증 1). 기준은 목록 읽기 뒤 실제 조회 시작(R-L3).
        // 진행 중이면 icsLoading·reloading 가드가 막는다. 주기 루프(refreshMinutes)는 이와 무관하게 돈다
        if !problems.isEmpty { icsFetchedAt = fetchStarted.addingTimeInterval(-lastStaleTTL / 2) }
    }

    func refresh() {
        let dayStart = Calendar.current.startOfDay(for: day)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!
        let r = collect(DateInterval(start: dayStart, end: dayEnd)); var out = r.events; let labels = r.labels
        out.sort { $0.start == $1.start ? $0.end > $1.end : $0.start < $1.start }
        allDay = out.filter { $0.isAllDay }
        events = out.filter { !$0.isAllDay }
        sourceLabel = labels.joined(separator: " · ")
        lastUpdated = Date()
        if !hasNativeSource {
            // 첫 ICS 조회(목록 읽기)가 끝나기 전에는 판정을 미룬다 — 소스를 아직 모를 뿐 (EventKit 거부는 바로)
            let denied = cfg.useEventKit && EKEventStore.authorizationStatus(for: .event) == .denied
            if denied { status = .denied } else if icsSettled { status = .noSource }
        } else {
            status = .ready
        }
    }

    /// 오늘부터 days 일 동안의 일정 (허브 '다가오는 일정'이 Notion Schedule 과 합쳐 쓴다, #13)
    func upcoming(days: Int) -> [CalEvent] {
        let start = Calendar.current.startOfDay(for: HubClock.now)
        let end = Calendar.current.date(byAdding: .day, value: days, to: start)!
        return collect(DateInterval(start: start, end: end)).events.sorted { $0.start < $1.start }
    }

    /// 허용된 캘린더(EventKit + ICS)에서 window 안의 일정. 같은 일정이 두 소스에 있으면 하나만
    private func collect(_ window: DateInterval) -> (events: [CalEvent], labels: [String]) {
        let dayStart = window.start, dayEnd = window.end
        var out: [CalEvent] = []
        var labels: [String] = []

        if eventKitOK && eventKitHasEvents {
            let cals = store.calendars(for: .event).filter(allowed)
            if !cals.isEmpty {
                let pred = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: cals)
                for e in store.events(matching: pred) {
                    // 캘린더 색은 Google 의 것이 아니라 이름 순서로 네이비/녹색/회색
                    let idx = cfg.includeCalendars.firstIndex { e.calendar.title.localizedCaseInsensitiveContains($0) } ?? 2
                    let hex = ICSCalendar.palette[min(idx, ICSCalendar.palette.count - 1)]
                    out.append(CalEvent(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "(제목 없음)",
                                        start: e.startDate, end: e.endDate, isAllDay: e.isAllDay, colorHex: hex,
                                        location: e.location, calendarName: e.calendar.title))
                }
                labels.append("macOS: " + cals.map(\.title).prefix(3).joined(separator: ", ") + (cals.count > 3 ? " 외 \(cals.count - 3)" : ""))
            }
        }
        for c in icsCalendars where allowedName(c.name) {
            for ev in c.occurrences(in: DateInterval(start: dayStart, end: dayEnd)) {
                out.append(CalEvent(id: ev.id, title: ev.title, start: ev.start, end: ev.end, isAllDay: ev.isAllDay,
                                    colorHex: c.colorHex ?? "#4A86F7", location: ev.location, calendarName: c.name))
            }
            labels.append(c.name)
        }

        var seen = Set<String>()
        out = out.filter { seen.insert("\($0.title)|\($0.start.timeIntervalSince1970)").inserted && !Hub.isHiddenEvent($0.title) }
        return (out, labels)
    }

    private func allowed(_ cal: EKCalendar) -> Bool { allowedName(cal.title) }
    private func allowedName(_ name: String) -> Bool {
        let n = name.lowercased()
        if !cfg.includeCalendars.isEmpty && !cfg.includeCalendars.contains(where: { n.contains($0.lowercased()) }) { return false }
        if cfg.excludeCalendars.contains(where: { n.contains($0.lowercased()) }) { return false }
        return true
    }

    func goToday() { followToday = true; day = Calendar.current.startOfDay(for: HubClock.now); refresh() }
    func shift(_ d: Int) {
        followToday = false
        day = Calendar.current.date(byAdding: .day, value: d, to: day)!
        if Calendar.current.isDate(day, inSameDayAs: HubClock.now) { followToday = true }
        refresh()
    }
}

extension NSColor {
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
    convenience init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
        let r, g, b: CGFloat
        if h.count == 8 { r = CGFloat((v >> 24) & 0xFF) / 255; g = CGFloat((v >> 16) & 0xFF) / 255; b = CGFloat((v >> 8) & 0xFF) / 255 }
        else { r = CGFloat((v >> 16) & 0xFF) / 255; g = CGFloat((v >> 8) & 0xFF) / 255; b = CGFloat(v & 0xFF) / 255 }
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

// MARK: - ICS 파서 (VEVENT + RRULE 기본 지원)

struct ICSEvent {
    var uid: String
    var title: String
    var location: String?
    var start: Date
    var end: Date
    var isAllDay: Bool
    var tz: TimeZone
    var rrule: [String: String]?
    var exdates: [Date] = []
    var recurrenceID: Date?
    var cancelled = false
}

struct ICSOccurrence { let id: String; let title: String; let start: Date; let end: Date; let isAllDay: Bool; let location: String? }

struct ICSCalendar {
    var name: String
    var colorHex: String?
    var events: [ICSEvent]
    /// 세 색만: 첫 캘린더(CSNL) 네이비, 둘째(SLab) 녹색, 그 외 회색
    static let palette = ["#1F3B5C", "#1C6B54", "#80868F"]

    /// 구간 안에 걸치는 모든 발생 (반복 전개 + 예외 반영)
    func occurrences(in window: DateInterval) -> [ICSOccurrence] {
        var out: [ICSOccurrence] = []
        // RECURRENCE-ID 로 덮어쓴 발생들
        var overridden: [String: Set<Double>] = [:]
        for e in events where e.recurrenceID != nil {
            overridden[e.uid, default: []].insert(e.recurrenceID!.timeIntervalSince1970.rounded())
        }
        for e in events where !e.cancelled {
            let dur = e.end.timeIntervalSince(e.start)
            if let rule = e.rrule, e.recurrenceID == nil {
                for s in RRule.occurrences(start: e.start, tz: e.tz, rule: rule, window: window, maxCount: 3000) {
                    let key = s.timeIntervalSince1970.rounded()
                    if overridden[e.uid]?.contains(key) == true { continue }
                    if e.exdates.contains(where: { abs($0.timeIntervalSince(s)) < 60 }) { continue }
                    let en = s.addingTimeInterval(dur)
                    if s < window.end && en > window.start {
                        out.append(ICSOccurrence(id: "\(e.uid)@\(key)", title: e.title, start: s, end: en, isAllDay: e.isAllDay, location: e.location))
                    }
                }
            } else if e.start < window.end && e.end > window.start {
                out.append(ICSOccurrence(id: e.uid + (e.recurrenceID.map { "@\($0.timeIntervalSince1970)" } ?? ""),
                                         title: e.title, start: e.start, end: e.end, isAllDay: e.isAllDay, location: e.location))
            }
        }
        return out
    }
}

enum ICSParser {
    static func parse(_ text: String) -> ICSCalendar {
        // 접힌 줄 펴기
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.hasPrefix(" ") || line.hasPrefix("\t") { if !lines.isEmpty { lines[lines.count - 1] += String(line.dropFirst()) } }
            else { lines.append(line) }
        }
        var cal = ICSCalendar(name: "ICS", colorHex: nil, events: [])
        var cur: [String: (params: [String: String], value: String)]? = nil
        var exdates: [Date] = []
        for line in lines {
            if line == "BEGIN:VEVENT" { cur = [:]; exdates = []; continue }
            if line == "END:VEVENT" {
                if let p = cur, let ev = makeEvent(p, exdates: exdates) { cal.events.append(ev) }
                cur = nil; continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let head = String(line[..<colon]); let value = String(line[line.index(after: colon)...])
            let parts = head.split(separator: ";").map(String.init)
            // ":값" 처럼 이름이 빈 줄(구글 ICS 의 긴 설명 줄이 접힐 때 생김)은 건너뛴다 — 예전엔 parts[0] 에서 앱이 죽었다
            guard let first = parts.first, !first.isEmpty else { continue }
            let name = first.uppercased()
            var params: [String: String] = [:]
            for p in parts.dropFirst() {
                let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { params[kv[0].uppercased()] = kv[1] }
            }
            if cur == nil {
                if name == "X-WR-CALNAME" { cal.name = unescape(value) }
                if name == "X-APPLE-CALENDAR-COLOR" { cal.colorHex = value }
                continue
            }
            if name == "EXDATE" {
                for v in value.split(separator: ",") { if let d = parseDate(String(v), params: params) { exdates.append(d.date) } }
            } else {
                cur?[name] = (params, value)
            }
        }
        return cal
    }

    private static func makeEvent(_ p: [String: (params: [String: String], value: String)], exdates: [Date]) -> ICSEvent? {
        guard let ds = p["DTSTART"], let start = parseDate(ds.value, params: ds.params) else { return nil }
        let end: (date: Date, allDay: Bool, tz: TimeZone)
        if let de = p["DTEND"], let d = parseDate(de.value, params: de.params) { end = d }
        else if let du = p["DURATION"], let secs = parseDuration(du.value) { end = (start.date.addingTimeInterval(secs), start.allDay, start.tz) }
        else { end = (start.allDay ? Calendar.current.date(byAdding: .day, value: 1, to: start.date)! : start.date.addingTimeInterval(3600), start.allDay, start.tz) }
        var rrule: [String: String]? = nil
        if let r = p["RRULE"]?.value {
            var d: [String: String] = [:]
            for kv in r.split(separator: ";") { let a = kv.split(separator: "=", maxSplits: 1).map(String.init); if a.count == 2 { d[a[0].uppercased()] = a[1] } }
            rrule = d
        }
        let rid = p["RECURRENCE-ID"].flatMap { parseDate($0.value, params: $0.params)?.date }
        return ICSEvent(uid: p["UID"]?.value ?? UUID().uuidString,
                        title: unescape(p["SUMMARY"]?.value ?? "(제목 없음)"),
                        location: p["LOCATION"].map { unescape($0.value) }.flatMap { $0.isEmpty ? nil : $0 },
                        start: start.date, end: max(end.date, start.date), isAllDay: start.allDay, tz: start.tz,
                        rrule: rrule, exdates: exdates, recurrenceID: rid,
                        cancelled: (p["STATUS"]?.value.uppercased() == "CANCELLED"))
    }

    static func unescape(_ s: String) -> String {
        var r = s
        r = r.replacingOccurrences(of: "\\n", with: "\n")
        r = r.replacingOccurrences(of: "\\,", with: ",")
        r = r.replacingOccurrences(of: "\\;", with: ";")
        r = r.replacingOccurrences(of: "\\\\", with: "\\")
        return r
    }

    static func parseDate(_ v: String, params: [String: String]) -> (date: Date, allDay: Bool, tz: TimeZone)? {
        let tz = params["TZID"].flatMap { TimeZone(identifier: $0) } ?? .current
        var cal = Calendar(identifier: .gregorian)
        if params["VALUE"] == "DATE" || v.count == 8 {
            guard v.count >= 8, let y = Int(v.prefix(4)), let m = Int(v.dropFirst(4).prefix(2)), let d = Int(v.dropFirst(6).prefix(2)) else { return nil }
            cal.timeZone = .current
            guard let date = cal.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
            return (date, true, .current)
        }
        guard v.count >= 15 else { return nil }
        let utc = v.hasSuffix("Z")
        cal.timeZone = utc ? TimeZone(identifier: "UTC")! : tz
        guard let y = Int(v.prefix(4)), let m = Int(v.dropFirst(4).prefix(2)), let d = Int(v.dropFirst(6).prefix(2)),
              let hh = Int(v.dropFirst(9).prefix(2)), let mm = Int(v.dropFirst(11).prefix(2)), let ss = Int(v.dropFirst(13).prefix(2)) else { return nil }
        guard let date = cal.date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm, second: ss)) else { return nil }
        return (date, false, utc ? .current : tz)
    }

    static func parseDuration(_ v: String) -> TimeInterval? {
        // P1D, PT1H30M, P1W
        var s = v; var sign: Double = 1
        if s.hasPrefix("-") { sign = -1; s.removeFirst() }
        guard s.hasPrefix("P") else { return nil }
        s.removeFirst()
        var total: Double = 0; var num = ""; var inTime = false
        for ch in s {
            if ch == "T" { inTime = true; continue }
            if ch.isNumber { num.append(ch); continue }
            let n = Double(num) ?? 0; num = ""
            switch ch {
            case "W": total += n * 604800
            case "D": total += n * 86400
            case "H": total += n * 3600
            case "M": total += inTime ? n * 60 : n * 2592000
            case "S": total += n
            default: break
            }
        }
        return sign * total
    }
}

enum RRule {
    private static let weekdays = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]

    /// RRULE 전개: FREQ=DAILY/WEEKLY/MONTHLY/YEARLY, INTERVAL, COUNT, UNTIL, BYDAY, BYMONTHDAY, BYMONTH
    static func occurrences(start: Date, tz: TimeZone, rule: [String: String], window: DateInterval, maxCount: Int) -> [Date] {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let freq = rule["FREQ"]?.uppercased() ?? "DAILY"
        let interval = max(1, Int(rule["INTERVAL"] ?? "1") ?? 1)
        let count = Int(rule["COUNT"] ?? "")
        let until: Date? = rule["UNTIL"].flatMap { ICSParser.parseDate($0, params: [:])?.date }
        let byMonth = rule["BYMONTH"]?.split(separator: ",").compactMap { Int($0) } ?? []
        let byMonthDay = rule["BYMONTHDAY"]?.split(separator: ",").compactMap { Int($0) } ?? []
        let byDay: [(ord: Int?, wd: Int)] = (rule["BYDAY"]?.split(separator: ",").compactMap { tok -> (Int?, Int)? in
            let t = String(tok); let code = String(t.suffix(2)); guard let wd = weekdays[code] else { return nil }
            let ordStr = String(t.dropLast(2)); return (ordStr.isEmpty ? nil : Int(ordStr), wd)
        }) ?? []
        let timeComps = cal.dateComponents([.hour, .minute, .second], from: start)
        func withTime(_ day: Date) -> Date? {
            var c = cal.dateComponents([.year, .month, .day], from: day)
            c.hour = timeComps.hour; c.minute = timeComps.minute; c.second = timeComps.second
            return cal.date(from: c)
        }

        var result: [Date] = []
        var produced = 0
        var candidates: [Date] = []
        let hardStop = window.end
        var iterations = 0

        func emit(_ d: Date) -> Bool {   // false = 중단
            if d < start { return true }
            if let u = until, d > u { return false }
            produced += 1
            if let c = count, produced > c { return false }
            if d >= hardStop { return false }
            result.append(d)
            return true
        }

        switch freq {
        case "DAILY":
            var d = start
            while iterations < maxCount {
                iterations += 1
                if !byDay.isEmpty { let wd = cal.component(.weekday, from: d); if !byDay.contains(where: { $0.wd == wd }) { d = cal.date(byAdding: .day, value: interval, to: d)!; if d >= hardStop { break }; continue } }
                if !emit(d) { break }
                d = cal.date(byAdding: .day, value: interval, to: d)!
            }
        case "WEEKLY":
            let days = byDay.isEmpty ? [cal.component(.weekday, from: start)] : byDay.map { $0.wd }
            var weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: start))!
            outer: while iterations < maxCount {
                iterations += 1
                for off in 0..<7 {
                    let day = cal.date(byAdding: .day, value: off, to: weekStart)!
                    if days.contains(cal.component(.weekday, from: day)), let d = withTime(day) {
                        if !emit(d) { break outer }
                    }
                }
                weekStart = cal.date(byAdding: .weekOfYear, value: interval, to: weekStart)!
                if weekStart >= hardStop { break }
            }
        case "MONTHLY":
            var monthStart = cal.date(from: cal.dateComponents([.year, .month], from: start))!
            outer: while iterations < maxCount {
                iterations += 1
                var days: [Date] = []
                let range = cal.range(of: .day, in: .month, for: monthStart)!
                if !byMonthDay.isEmpty {
                    for md in byMonthDay { let dd = md > 0 ? md : range.count + md + 1; if range.contains(dd), let d = cal.date(byAdding: .day, value: dd - 1, to: monthStart) { days.append(d) } }
                } else if !byDay.isEmpty {
                    for (ord, wd) in byDay {
                        var matches: [Date] = []
                        for off in 0..<range.count { let d = cal.date(byAdding: .day, value: off, to: monthStart)!; if cal.component(.weekday, from: d) == wd { matches.append(d) } }
                        if let o = ord { let idx = o > 0 ? o - 1 : matches.count + o; if matches.indices.contains(idx) { days.append(matches[idx]) } }
                        else { days.append(contentsOf: matches) }
                    }
                } else {
                    let md = cal.component(.day, from: start)
                    if range.contains(md) { days.append(cal.date(byAdding: .day, value: md - 1, to: monthStart)!) }
                }
                for day in days.sorted() { if let d = withTime(day) { if !emit(d) { break outer } } }
                monthStart = cal.date(byAdding: .month, value: interval, to: monthStart)!
                if monthStart >= hardStop { break }
            }
        case "YEARLY":
            var y = start
            while iterations < maxCount {
                iterations += 1
                var ok = true
                if !byMonth.isEmpty { ok = byMonth.contains(cal.component(.month, from: y)) }
                if ok, !emit(y) { break }
                y = cal.date(byAdding: .year, value: interval, to: y)!
                if y >= hardStop { break }
            }
        default:
            candidates = [start]
            _ = candidates.map { _ = emit($0) }
        }
        return result
    }
}

// MARK: - 뷰

struct CalendarNativeWidget: View {
    @ObservedObject var model: CalendarModel
    var onSwitchWeb: (() -> Void)? = nil

    private var dateTitle: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "M월 d일 EEEE"
        return f.string(from: model.day)
    }

    var body: some View {
        WidgetChrome(style: WidgetStyle(kind: .calendar, title: "오늘 일정"), subtitle: model.sourceLabel) {
            IconButton(symbol: "chevron.left", help: "전날") { model.shift(-1) }
            IconButton(symbol: "sun.max", help: "오늘로", label: "오늘") { model.goToday() }.disabled(model.isToday).opacity(model.isToday ? 0.45 : 1)
            IconButton(symbol: "chevron.right", help: "다음날") { model.shift(1) }
            IconButton(symbol: "arrow.clockwise", help: "새로고침") { model.refresh() }
            IconButton(symbol: "safari", help: "Google Calendar 를 브라우저에서 열기") {
                NSWorkspace.shared.open(URL(string: "https://calendar.google.com/calendar/u/0/r/day")!)
            }
        } content: {
            VStack(spacing: 0) {
                dayHeader
                if model.status == .noSource || model.status == .denied { noSourceBanner }
                if !model.allDay.isEmpty { allDayRow }
                GeometryReader { geo in
                    Timeline(model: model, size: geo.size)
                }
                .clipped()
                statusBar
            }

        }
    }

    private var dayHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(dateTitle).font(.hub(24, weight: .bold))
            if !model.isToday {
                Text(Hub.dday(model.day)).font(.hub(12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Hub.ink))
            }
            Spacer()
            Text(model.now, format: .dateTime.hour().minute()).font(.hub(22, weight: .medium, design: .rounded)).monospacedDigit()
                .foregroundStyle(Hub.text2)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    }

    private var allDayRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.allDay) { e in
                    HStack(spacing: 6) {
                        Circle().fill(e.color).frame(width: 8, height: 8)
                        Text(Hub.canonicalNames(e.title)).font(.hub(13, weight: .semibold)).lineLimit(1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(e.color.opacity(0.18)))
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text(!model.isSettled ? "불러오는 중…" : (model.status == .noSource || model.status == .denied ? "캘린더 읽지 못함" : "일정 \(model.events.count + model.allDay.count)개"))
            if let u = model.lastUpdated { Text("· 갱신 " + Hub.time(u)) }
            if let e = model.lastError { Text("· " + e).foregroundStyle(Hub.signal).lineLimit(1) }
            Spacer()
        }
        .font(.hub(11)).foregroundStyle(Hub.text2)
        .padding(.horizontal, 16).padding(.vertical, 6).padding(.trailing, 14)
    }

    /// 소스 없음: 한 줄 배너. 설정 절차는 툴팁과 설정 파일 주석에.
    private var noSourceBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark").foregroundStyle(Hub.signal)
            Text(model.status == .denied ? "캘린더 접근 거부됨" : "캘린더 연결 안 됨 · \(model.cfg.accountHint)").font(.hub(12.5, weight: .semibold))
            Spacer()
            if model.status == .denied {
                Button("개인정보 설정") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!) }
            } else {
                Button("인터넷 계정 설정") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!) }
            }
            if let sw = onSwitchWeb { Button("웹으로") { sw() } }
        }
        .buttonStyle(HeaderButtonStyle())
        .font(.hub(12))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Hub.signal.opacity(0.08)))
        .padding(.horizontal, 16).padding(.bottom, 8)
        .help(model.status == .denied ? "시스템 설정 > 개인정보 보호 및 보안 > 캘린더에서 DeskHub 허용"
              : "① 시스템 설정 > 인터넷 계정 > Google 에 \(model.cfg.accountHint) 추가 후 '캘린더' 켜기  ② 또는 Google Calendar 의 'iCal 비공개 주소'를 config.json calendar.icsURLs 에 넣기. 표시 대상: \(model.cfg.includeCalendars.joined(separator: " · "))")
    }
}

/// 시간축: 포커스 시간대는 넓게, 그 밖은 압축
struct TimeScale {
    let dayStart: Int, dayEnd: Int, focusStart: Int, focusEnd: Int, offScale: CGFloat
    let height: CGFloat
    let unit: CGFloat
    init(cfg: CalendarConfig, height: CGFloat) {
        dayStart = min(cfg.dayStart, cfg.focusStart); dayEnd = max(cfg.dayEnd, cfg.focusEnd)
        focusStart = cfg.focusStart; focusEnd = cfg.focusEnd; offScale = CGFloat(cfg.offHoursScale)
        self.height = height
        var w: CGFloat = 0
        for h in dayStart..<dayEnd { w += (h >= focusStart && h < focusEnd) ? 1 : CGFloat(cfg.offHoursScale) }
        unit = w > 0 ? height / w : 0
    }
    func weight(_ h: Int) -> CGFloat { (h >= focusStart && h < focusEnd) ? 1 : offScale }
    func y(forHour hour: Double) -> CGFloat {
        var y: CGFloat = 0
        var h = Double(dayStart)
        while h < hour && h < Double(dayEnd) {
            let next = min(floor(h) + 1, hour, Double(dayEnd))
            y += CGFloat(next - h) * weight(Int(floor(h))) * unit
            h = next
        }
        return y
    }
    func y(for date: Date, day: Date) -> CGFloat {
        let secs = date.timeIntervalSince(Calendar.current.startOfDay(for: day))
        let hour = min(max(secs / 3600, Double(dayStart)), Double(dayEnd))
        return y(forHour: hour)
    }
}

struct Timeline: View {
    @ObservedObject var model: CalendarModel
    let size: CGSize
    private let gutter: CGFloat = 58
    private let rightPad: CGFloat = 14

    private struct Placed: Identifiable { let id: String; let event: CalEvent; let col: Int; let cols: Int }

    var body: some View {
        let topInset: CGFloat = 12
        let scale = TimeScale(cfg: model.cfg, height: size.height - topInset - 6)
        let placed = place(model.events)
        ZStack(alignment: .topLeading) {
            // 포커스 밴드
            let fy = scale.y(forHour: Double(scale.focusStart)), fh = scale.y(forHour: Double(scale.focusEnd)) - fy
            Rectangle().fill(Hub.ink.opacity(0.07))
                .frame(width: size.width, height: fh).offset(y: fy)
            Rectangle().fill(Hub.ink.opacity(0.8))
                .frame(width: 3, height: fh).offset(x: 0, y: fy)
            // 시간 줄
            ForEach(scale.dayStart..<scale.dayEnd, id: \.self) { h in
                let inFocus = h >= scale.focusStart && h < scale.focusEnd
                let y = scale.y(forHour: Double(h))
                let rowH = scale.unit * scale.weight(h)
                Rectangle().fill(Color.primary.opacity(inFocus ? 0.12 : 0.06)).frame(width: size.width - gutter, height: 1).offset(x: gutter, y: y)
                if inFocus && rowH > 36 {
                    Rectangle().fill(Color.primary.opacity(0.05)).frame(width: size.width - gutter, height: 1).offset(x: gutter, y: y + rowH / 2)
                }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(h % 12 == 0 ? 12 : h % 12)")
                        .font(.hub(inFocus ? 17 : 11.5, weight: inFocus ? .bold : .regular, design: .rounded)).monospacedDigit()
                    Text(h < 12 ? "AM" : "PM").font(.hub(inFocus ? 9.5 : 8, weight: .semibold))
                }
                .foregroundStyle(inFocus ? Color.primary : Color.secondary)
                .frame(width: gutter - 10, alignment: .trailing)
                .offset(x: 0, y: y - (inFocus ? 9 : 6))
            }
            // 일정 블록
            ForEach(placed) { p in
                let e = p.event
                let y0 = scale.y(for: e.start, day: model.day)
                let y1 = max(scale.y(for: e.end, day: model.day), y0 + 24)
                let availW = size.width - gutter - rightPad
                let colW = (availW - CGFloat(p.cols - 1) * 4) / CGFloat(p.cols)
                EventBlock(event: e, height: y1 - y0, inFocus: isInFocus(e, scale: scale))
                    .frame(width: colW, height: y1 - y0)
                    .offset(x: gutter + CGFloat(p.col) * (colW + 4), y: y0)
            }
            // 현재 시각
            if model.isToday {
                let ny = scale.y(for: model.now, day: model.day)
                HStack(spacing: 0) {
                    Circle().fill(Hub.signal).frame(width: 8, height: 8)
                    Rectangle().fill(Hub.signal).frame(height: 2)
                }
                .frame(width: size.width).offset(y: ny - 4)
            }
            if model.events.isEmpty && model.allDay.isEmpty && model.status == .ready {
                Text("일정이 없습니다").font(.hub(15)).foregroundStyle(Hub.text2)
                    .frame(width: size.width, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height - topInset, alignment: .topLeading)
        .offset(y: topInset)
    }

    private func isInFocus(_ e: CalEvent, scale: TimeScale) -> Bool {
        let s = Calendar.current.startOfDay(for: model.day)
        let sh = e.start.timeIntervalSince(s) / 3600, eh = e.end.timeIntervalSince(s) / 3600
        return eh > Double(scale.focusStart) && sh < Double(scale.focusEnd)
    }

    /// 겹치는 일정을 열로 나눈다
    private func place(_ events: [CalEvent]) -> [Placed] {
        var out: [Placed] = []
        var cluster: [CalEvent] = []; var clusterEnd: Date = .distantPast
        func flush() {
            guard !cluster.isEmpty else { return }
            var colEnds: [Date] = []; var assign: [(CalEvent, Int)] = []
            for e in cluster {
                if let i = colEnds.firstIndex(where: { $0 <= e.start }) { colEnds[i] = e.end; assign.append((e, i)) }
                else { colEnds.append(e.end); assign.append((e, colEnds.count - 1)) }
            }
            for (e, c) in assign { out.append(Placed(id: e.id, event: e, col: c, cols: colEnds.count)) }
            cluster = []; clusterEnd = .distantPast
        }
        for e in events {
            if !cluster.isEmpty && e.start >= clusterEnd { flush() }
            cluster.append(e); clusterEnd = max(clusterEnd, e.end)
        }
        flush()
        return out
    }
}

struct EventBlock: View {
    let event: CalEvent
    let height: CGFloat
    let inFocus: Bool
    private static let tf: DateFormatter = { let f = DateFormatter(); f.dateFormat = "H:mm"; return f }()

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2).fill(event.color).frame(width: 5)
            VStack(alignment: .leading, spacing: 2) {
                if height < 40 {
                    HStack(spacing: 6) {
                        Text(EventBlock.tf.string(from: event.start)).font(.hub(12, weight: .semibold)).monospacedDigit().foregroundStyle(Hub.text2)
                        Text(Hub.canonicalNames(event.title)).font(.hub(13.5, weight: .semibold)).lineLimit(1)
                    }
                } else {
                    Text(Hub.canonicalNames(event.title)).font(.hub(inFocus ? 15.5 : 13, weight: .bold)).lineLimit(height > 70 ? 3 : 1)
                    Text("\(EventBlock.tf.string(from: event.start)) – \(EventBlock.tf.string(from: event.end))")
                        .font(.hub(12.5, weight: .medium)).monospacedDigit().foregroundStyle(Hub.text2)
                    if let l = event.location, height > 64 {
                        Label(l, systemImage: "mappin").font(.hub(12)).foregroundStyle(Hub.text2).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, height < 40 ? 3 : 7)
            Spacer(minLength: 0)
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(event.color.opacity(inFocus ? 0.22 : 0.14)))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(inFocus ? 1 : 0.8)
        .help(event.title + (event.location.map { "\n" + $0 } ?? ""))
    }
}
