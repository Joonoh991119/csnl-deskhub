import Foundation
import AppKit

// MARK: - 위젯 종류와 스타일

enum WidgetKind: String, CaseIterable, Codable {
    case calendar, notionhub, notion, web, nas, plaud, claude

    var defaultTitle: String {
        switch self {
        case .calendar: return "오늘 일정"
        case .notionhub: return "CSNL"
        case .notion: return "Notion"
        case .web: return "Web"
        case .nas: return "NAS"
        case .plaud: return "Plaud"
        case .claude: return "Claude에게 질문"
        }
    }
    var symbol: String {
        switch self {
        case .calendar: return "calendar"
        case .notionhub: return "n.square"
        case .notion: return "doc.text"
        case .web: return "globe"
        case .nas: return "externaldrive.connected.to.line.below"
        case .plaud: return "waveform.circle"
        case .claude: return "sparkles"
        }
    }
    var tint: NSColor {
        switch self {
        case .calendar: return NSColor(red: 0.12, green: 0.23, blue: 0.36, alpha: 1)      // Cell 계열 네이비
        case .notionhub: return NSColor(red: 0.12, green: 0.23, blue: 0.36, alpha: 1)
        case .notion: return NSColor(red: 0.12, green: 0.23, blue: 0.36, alpha: 1)
        case .web: return NSColor(red: 0.110, green: 0.420, blue: 0.329, alpha: 1)
        case .nas: return NSColor(red: 0.122, green: 0.231, blue: 0.361, alpha: 1)
        case .plaud: return NSColor(red: 0.659, green: 0.188, blue: 0.176, alpha: 1)
        case .claude: return NSColor(red: 0.122, green: 0.231, blue: 0.361, alpha: 1)
        }
    }
}

/// 헤더에 쓰는 표시 정보
struct WidgetStyle {
    var title: String
    var symbol: String
    var tint: NSColor
    init(kind: WidgetKind, title: String? = nil) {
        self.title = title ?? kind.defaultTitle
        self.symbol = kind.symbol
        self.tint = kind.tint
    }
}

// MARK: - 레이아웃 (슬롯 = 위젯 인스턴스 하나)

/// 사용 가능한 영역에 대한 비율 (0~1)
struct FracRect: Codable, Equatable {
    var x: Double, y: Double, w: Double, h: Double
}

struct Slot: Codable, Identifiable, Equatable {
    var id: String
    var type: String                 // WidgetKind rawValue
    var title: String? = nil
    var url: String? = nil           // notion / web 슬롯의 시작 URL
    var frame: FracRect
    var visible: Bool = true

    var kind: WidgetKind? { WidgetKind(rawValue: type) }
}

struct Insets: Codable, Equatable {
    var top: Double = 0, left: Double = 0, bottom: Double = 0, right: Double = 0
}

struct LayoutConfig: Codable {
    /// widget: 카드만 띄운다(바닥판 없음, 그림자) · desktop: 예전처럼 화면 전체를 덮는 바닥판 + 카드
    var mode: String = "widget"
    /// 띄울 모니터: secondary(보조 모니터, 없으면 주 모니터) | main | 모니터 이름 일부 (예 "DELL")
    var screen: String = "secondary"
    /// 보조 모니터가 없을 때: hide(숨긴 채 시작, 단축키로 꺼냄) | show(주 모니터에 띄움)
    var whenNoSecondary: String = "hide"
    /// 모두 숨기기/보이기 전역 단축키. 단축키로 꺼낸 카드는 다른 창 위에 뜨고, 다시 누르면 숨는다
    var hotkey: String = "ctrl+opt+d"
    var insets = Insets(top: 12, left: 12, bottom: 12, right: 12)
    /// Stage Manager 가 켜져 있으면 왼쪽 스트립 폭만큼 비워 둔다
    var avoidStageManagerStrip: Bool = true
    var stageManagerStripWidth: Double = 176
    var gutter: Double = 14
    var cornerRadius: Double = 14
    /// 화면 전체를 덮는 불투명 바닥판 (배경화면이 안 보이게)
    var backdrop: Bool = false
    /// 카드 배경을 유리 대신 불투명하게
    var opaqueCards: Bool = true
    var slots: [Slot] = []
}

struct CalendarConfig: Codable {
    /// native: 네이티브(EventKit/ICS)만 | auto: 소스 없으면 웹으로 | web: Google 웹
    var mode: String = "native"
    /// 일정 계정 안내 (오버레이 문구용)
    var accountHint: String = "lab-calendar@example.com"
    var useEventKit: Bool = true
    /// 구글 캘린더 "iCal 형식의 비공개 주소" 등 ICS URL (file:// 도 가능)
    var icsURLs: [String] = []
    /// 랩 SSOT(NAS) 의 iCal 비공개 주소 — 각자 맥 설정에 주소를 넣지 않아도 연결되게 (값은 이 파일에만, 설정·코드에 복사하지 않음)
    var icsSSOTFile: String = "/Volumes/CSNL_new/Grant/_ssot/credentials/tokens.env"
    var icsSSOTKeys: [String] = ["GCAL_ICS_CSNL", "GCAL_ICS_SLAB"]
    /// 이 이름이 포함된 캘린더만 표시 (대소문자 무시). 비어 있으면 전부
    var includeCalendars: [String] = ["CSNL Calendar", "SLab Calendar"]
    var excludeCalendars: [String] = []
    var dayStart: Int = 7
    var dayEnd: Int = 23
    var focusStart: Int = 10
    var focusEnd: Int = 20
    var offHoursScale: Double = 0.38
    var refreshMinutes: Int = 5
    var webURL: String = "https://calendar.google.com/calendar/u/0/r/day"
    var webZoom: Double = 1.15
}

struct WebConfig: Codable {
    var userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
}

struct NotionConfig: Codable {
    var accountHint: String = "lab-calendar@example.com"
}

/// 대시보드에서 생략할 수 있는 정보
struct HubDisplayConfig: Codable {
    /// 발표자 이메일 (끄면 툴팁에만)
    var showEmail: Bool = false
    /// 날짜 옆 요일 (GRM 은 항상 수요일이라 기본 숨김)
    var showWeekday: Bool = false
    /// Members 칩에 이니셜 표시
    var showMemberInitials: Bool = false
    /// 다가오는 일정에서 숨길 Type (GRM 은 발표 순번에 이미 있음)
    var hideEventTypes: [String] = ["GRM"]
    /// GRM 자료 링크 중 숨길 이름(부분 일치)
    var hideResources: [String] = ["CWLL"]
}

struct HubTab: Codable, Identifiable, Equatable {
    var title: String
    var url: String
    var id: String { url }
}

/// CSNL 허브: Notion API 로 읽는 DB/페이지 ID 와 표시 개수
struct NotionHubConfig: Codable {
    var tokenEnvFile: String = "~/.claude/csnl-report/.env"
    var tokenEnvKey: String = "NOTION_TOKEN"
    /// Notion 링크를 여는 곳: auto(앱이 있고 minNotionAppVersion 이상이면 앱, 아니면 웹) | app | web. 메뉴 ▦ → Notion 링크 열기
    var openLinksIn: String = "auto"
    /// 이보다 오래된 Notion 앱은 "Please upgrade your client" 만 띄우므로 웹으로 연다
    var minNotionAppVersion: String = "7.30"
    var refreshMinutes: Int = 10
    var membersDB: String = "54e8d7dd-1d7c-43ea-98d6-559f8b922838"
    var grmScheduleDB: String = "2ffeb59a-6828-4feb-81ea-5d922fe03462"
    var presentationsDB: String = "23cd1c0d-86e7-46e0-8493-cbc011cf45d7"
    var eventsDB: String = "2fe2a38e-4f5f-8032-a462-f8fbcca31a14"
    var resourcesDB: String = "7b80d2f7-f5be-4af3-88fe-1cc2210600a6"
    var cwllDB: String = "32c2a38e-4f5f-8077-b40d-f7a6b60cbddd"
    var meetingNotesDB: String = "669d4d56-1c6a-4b37-997f-c45b2888d6b3"
    var grmPageID: String = "3022a38e-4f5f-801f-b89b-dd7226873640"
    var csnlPageID: String = "2df2a38e-4f5f-8025-b75e-d1048b20faa9"
    /// 다가오는 학회 (Conferences DB, Date 가 오늘 이후인 항목만). 비우면 섹션을 빈 상태로 둔다
    var conferencesDB: String = "3f72a38e-4f5f-81f6-9c2c-cb7fe21d2b7e"
    var conferencesCount: Int = 5
    /// 논문 추천 DB = P23(CSNL-vnilab/csnl-paper-rec-v2, 월 09:00) 이 배달하는 현행 "이번 주 논문 추천" DB. 2026-06-01 이후 P23 정지로 새 행 없음(조사 F·G). 비우면 자리만 둔다. 반응·댓글은 이 DB 페이지의 Notion 댓글로 남는다
    var paperRecDB: String = "3722a38e-4f5f-8076-ba73-f82afa50de3d"
    var paperRecCount: Int = 8
    /// 연구원별 진행 프로젝트 버튼 (Projects & Chores DB: 상태 In Progress·Review, 담당자 relation)
    var projectsDB: String = "76e7c392-127e-47f3-8b7e-212610db9376"
    /// 그 DB 의 담당자 relation 이 가리키는 사람 DB (페이지 제목 = 이니셜)
    var projectPeopleDB: String = "94854705-c91d-4a35-a91e-803c5934745e"
    /// 최신 원고: 이니셜 → OpenAlex 저자 id. 최근 manuscriptLookbackDays 일의 프리프린트·논문
    var manuscriptAuthors: [String: String] = ["JSL": "A5029193200", "SJK": "A5064953124"]
    var manuscriptLookbackDays: Int = 365
    /// 그랜트 칸(보고 제출·도전할 과제) — 랩 SSOT(NAS) 의 JSON. 랩장·JYK 가 편집
    var grantsFile: String = "/Volumes/CSNL_new/Grant/_ssot/grants_schedule.json"
    var upcomingGRMCount: Int = 12
    var recentNotesCount: Int = 5
    var recentMinutesCount: Int = 5
    /// 다가오는 일정 범위 (일). Meeting 등 GRM 이 아닌 이벤트만
    var eventsDays: Int = 14
    /// (예전 체크리스트, 지금은 안 씀 — Schedule & Events 는 마감이 아님, 리마인더는 reminders.json 에서 컨펌한 것만)
    var checklistTypes: [String] = ["Deadline", "Milestone", "Assignment", "Exam", "Paper", "Experiment"]
    /// 일정 불러오는 범위(일) — 리마인더 제안도 이 안에서 찾는다
    var checklistDays: Int = 30
    /// 지난 Paper Blitz: Notion 아카이브 DB (JYK 파이프라인이 채움). 비어 있으면 NAS 의 PB_yymmdd.pptx 를 직접 읽는다
    var paperBlitzDB: String = ""
    var paperBlitzFromNAS: Bool = true
    /// 슬라이드·녹취의 이니셜 → Members DB 이니셜
    var initialsAliases: [String: String] = ["SK": "SJK", "RJH": "JHR"]
    var display = HubDisplayConfig()
    /// 오늘의 실험: SLab 실험 예약 DB · 자원 예약 DB (Running) · Prolific
    var slabDB: String = "3482a38e-4f5f-8002-98e7-d7a07294ccd0"
    var resourceDB: String = "2e72a38e-4f5f-81bf-9e9d-d8e53b6ef745"
    /// 논문 진행: Publications DB 에서 `manuscriptStageProp`(select) 이 `manuscriptStages` 중 하나인 행
    var publicationsDB: String = "3f72a38e-4f5f-8189-a0e6-f30bae89cb5f"
    var manuscriptStageProp: String = "Stage"
    var manuscriptDeadlineProp: String = "Deadline"
    var manuscriptJournalProp: String = "Journal"
    var manuscriptStages: [String] = ["초고", "투고", "심사중", "리비전", "게재확정"]
    /// 다가오는 일정 칸 최대 행 수 (오늘의 실험에 자리를 내준다)
    var eventsMaxRows: Int = 4
    var nasGRMRoot: String = "/Volumes/CSNL_new/GRM"
    /// 주간 GRM Magazine PDF 폴더(JYK 매거진 스킬이 수요일마다 GRM_magazine_<yyyymmdd>.pdf 로 저장). 회의록 행의 책 버튼이 연다
    var magazineDir: String = "/Volumes/CSNL_new/GRM/GRM_magazine"
    /// 카드 안에서 바로 열어 편집할 수 있는 Notion 페이지 탭 (사이드바 숨김)
    var tabs: [HubTab] = [
        HubTab(title: "Members", url: "https://www.notion.so/54e8d7dd1d7c43ea98d6559f8b922838"),
        HubTab(title: "CSNL GRM", url: "https://www.notion.so/3022a38e4f5f801fb89bdd7226873640"),
        HubTab(title: "CSNL", url: "https://www.notion.so/2df2a38e4f5f8025b75ed1048b20faa9"),
    ]
}

/// Prolific: 랩 prolific 플러그인과 같은 자격증명 파일 (~/.config/prolific/credentials.json 의 api_token)
struct ProlificConfig: Codable {
    var enabled: Bool = true
    /// 토큰 출처 1: 랩 prolific 플러그인의 credentials.json (api_token)
    var credentialsFile: String = "~/.config/prolific/credentials.json"
    /// 토큰 출처 2: notionHub.tokenEnvFile(.env) 의 이 키 — 없으면 1 을 본다
    var tokenEnvKey: String = "PROLIFIC_API_TOKEN"
    /// 이 상태의 study 만 보여준다
    var showStatuses: [String] = ["ACTIVE", "PAUSED", "AWAITING REVIEW", "SCHEDULED"]
    /// 워크스페이스 ID. 비우면 첫 워크스페이스. 프로젝트 이름이 실험자 이름("Joonoh Park")이라 프로젝트별로 study 를 읽어 실험자를 붙인다
    var workspaceID: String = ""
    /// 프로젝트 이름 → 이니셜. Members DB 이름과 맞지 않는 프로젝트만 적는다 (나머지는 Members 에서 찾음)
    var projectInitials: [String: String] = ["MinsuYeo": "MSY", "Minsu Yeo": "MSY", "Boyun Lee": "BYL", "Bohyun Lee": "BHL", "Jaeseob Lim": "JSL", "Joonoh Park": "JOP", "Jungye Kim": "JYK", "Sungje Kim": "SJK", "Saemi Jung": "SMJ", "Suyoung Jo": "SYJ", "Juhyoung Ryu": "JHR", "Min Jin Choe": "MJC", "Minjin Choe": "MJC", "Hyunju Hwang": "HJH"]
}

struct NASConfig: Codable {
    var root: String = "/Volumes/CSNL_new"
    var smb: String = "smb://joonoh@147.47.70.15/CSNL_new"
    var fileStationURL: String = "https://147.47.70.15:5001/?launchApp=SYNO.SDS.App.FileStation3.Instance"
    var favorites: [String] = ["Server/Conferences", "Grant", "Server"]
}

struct PlaudConfig: Codable {
    var url: String = "https://web.plaud.ai/"
    var bundleID: String = "ai.plaud.desktop.plaud"
}

struct ClaudeConfig: Codable {
    var url: String = "https://claude.ai/new"
    var autoSend: Bool = true
}

// MARK: - 전체 설정

struct Config: Codable {
    static let currentVersion = 13
    var version: Int = Config.currentVersion
    /// 색 테마 id (Theme.ids — csnl · catppuccin · rosepine · nord · solarized · gruvbox · tokyonight). 메뉴막대 ▦ → 테마
    var theme: String = "csnl"
    /// system(맥 설정을 따름) | light | dark
    var appearance: String = "system"
    var layout = LayoutConfig()
    var calendar = CalendarConfig()
    var web = WebConfig()
    var notion = NotionConfig()
    var notionHub = NotionHubConfig()
    var prolific = ProlificConfig()
    var nas = NASConfig()
    var plaud = PlaudConfig()
    var claude = ClaudeConfig()

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DeskHub", isDirectory: true)
    }()
    static let fileURL = directory.appendingPathComponent("config.json")

    static func defaults() -> Config {
        var c = Config()
        c.layout.slots = defaultSlots()
        return c
    }

    /// 기본 배치: 캘린더 1/3 | CSNL 허브(Notion) 2/3
    static func defaultSlots() -> [Slot] {
        let third = 1.0 / 3.0
        return [
            // v13: 오늘 일정 카드는 기본으로 숨기고 허브 '오늘' 탭에서 본다 (BHL ②안). 메뉴에서 다시 켤 수 있음
            Slot(id: "calendar", type: WidgetKind.calendar.rawValue, title: "오늘 일정",
                 frame: FracRect(x: 0, y: 0, w: third, h: 1), visible: false),
            Slot(id: "csnl-hub", type: WidgetKind.notionhub.rawValue, title: "CSNL",
                 frame: FracRect(x: 0, y: 0, w: 1, h: 1)),
        ]
    }

    static func load() -> Config {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: fileURL) else {
            let c = defaults(); c.save(); return c
        }
        // 구버전 설정은 백업하고, v9 이상이면 사용자 값을 새 기본값 위에 얹는다(새 키만 기본값). 그보다 오래되면 새 기본값으로
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (obj["version"] as? Int ?? 0) < currentVersion {
            let old = obj["version"] as? Int ?? 1
            try? data.write(to: directory.appendingPathComponent("config.v\(old).bak.json"))
            if old >= 9, let migrated = migrate(obj, from: old) { migrated.save(); return migrated }
            let c = defaults(); c.save(); return c
        }
        do {
            var c = try JSONDecoder().decode(Config.self, from: data)
            if c.layout.slots.isEmpty { c.layout.slots = defaultSlots() }
            return c
        } catch {
            NSLog("DeskHub: config decode failed (%@) — using defaults", "\(error)")
            return defaults()
        }
    }

    /// 사용자 설정(JSON) 을 새 기본값 위에 깊게 합친다
    static func migrate(_ old: [String: Any], from v: Int) -> Config? {
        let enc = JSONEncoder()
        guard let base = try? JSONSerialization.jsonObject(with: enc.encode(defaults())) as? [String: Any] else { return nil }
        func merge(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
            var r = a
            for (k, v) in b {
                if let av = a[k] as? [String: Any], let bv = v as? [String: Any] { r[k] = merge(av, bv) } else { r[k] = v }
            }
            return r
        }
        var m = merge(base, old)
        m["version"] = currentVersion
        if v < 10, var lay = m["layout"] as? [String: Any], let dl = base["layout"] as? [String: Any] {
            // v10: 바탕화면 전체를 덮던 방식 → 위젯 방식 (바닥판 끔, 여백·간격 넓힘)
            for k in ["backdrop", "insets", "gutter", "mode"] { lay[k] = dl[k] }
            m["layout"] = lay
        }
        if v < 12, var hub = m["notionHub"] as? [String: Any], let dh = base["notionHub"] as? [String: Any] {
            // v12: 논문 추천을 예전 DB 로 연결하고 크게(8편), 비어 있던 값만 새 기본값으로
            if (hub["paperRecDB"] as? String ?? "").isEmpty { hub["paperRecDB"] = dh["paperRecDB"] }
            if (hub["paperRecCount"] as? Int ?? 0) < 8 { hub["paperRecCount"] = dh["paperRecCount"] }
            m["notionHub"] = hub
        }
        guard let d = try? JSONSerialization.data(withJSONObject: m), var c = try? JSONDecoder().decode(Config.self, from: d) else { return nil }
        if c.layout.slots.isEmpty { c.layout.slots = defaultSlots() }
        if v < 13 {
            // v13: 기본 배치(캘린더 1/3 | 허브 2/3)를 그대로 쓰던 경우만 → 캘린더 카드 숨김 + 허브 전체 폭
            let ids = c.layout.slots.map(\.id)
            if ids == ["calendar", "csnl-hub"], abs(c.layout.slots[1].frame.x - 1.0/3.0) < 0.01 { c.layout.slots = defaultSlots() }
        }
        return c
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: Config.fileURL, options: .atomic)
        }
    }

    // MARK: 좌표 계산

    static var stageManagerEnabled: Bool {
        UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") ?? false
    }

    /// 주 모니터(메뉴막대가 있는 화면) 말고 다른 모니터가 붙어 있는지
    static var hasSecondary: Bool { NSScreen.screens.count > 1 }

    /// layout.screen 에 맞는 모니터. secondary 인데 보조 모니터가 없으면 주 모니터
    func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        switch layout.screen {
        case "main": return screens.first
        case "secondary", "": return screens.dropFirst().first ?? screens.first
        default:
            return screens.first { $0.localizedName.localizedCaseInsensitiveContains(layout.screen) } ?? screens.dropFirst().first ?? screens.first
        }
    }

    /// 지금 카드를 띄울 모니터가 "원래 자리"인지 (secondary 설정인데 보조 모니터가 없으면 false)
    var onIntendedScreen: Bool { layout.screen == "main" || Config.hasSecondary }

    /// 슬롯들이 차지할 수 있는 영역 (메뉴막대·Dock·인셋·Stage Manager 스트립 제외)
    func usableRect(on screen: NSScreen? = nil) -> NSRect {
        let vf = (screen ?? targetScreen())?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1800, height: 1100)
        var r = vf
        r.origin.x += layout.insets.left; r.size.width -= layout.insets.left + layout.insets.right
        r.origin.y += layout.insets.bottom; r.size.height -= layout.insets.top + layout.insets.bottom
        if layout.avoidStageManagerStrip && Config.stageManagerEnabled {
            r.origin.x += layout.stageManagerStripWidth
            r.size.width -= layout.stageManagerStripWidth
        }
        return r
    }

    /// 비율 → 실제 창 프레임 (슬롯 사이 간격 = gutter)
    func windowFrame(for slot: Slot, on screen: NSScreen? = nil) -> NSRect {
        let u = usableRect(on: screen)
        let g = layout.gutter / 2
        // 비율 y 는 위에서 아래로(0 = 위) 읽는다
        let x = u.minX + slot.frame.x * u.width
        let w = slot.frame.w * u.width
        let h = slot.frame.h * u.height
        let y = u.maxY - slot.frame.y * u.height - h
        return NSRect(x: x + g, y: y + g, width: max(w - 2 * g, 200), height: max(h - 2 * g, 160))
    }

    /// 실제 창 프레임 → 비율
    func fraction(for frame: NSRect, on screen: NSScreen? = nil) -> FracRect {
        let u = usableRect(on: screen)
        let g = layout.gutter / 2
        let f = frame.insetBy(dx: -g, dy: -g)
        return FracRect(x: (f.minX - u.minX) / u.width,
                        y: (u.maxY - f.maxY) / u.height,
                        w: f.width / u.width,
                        h: f.height / u.height)
    }
}
