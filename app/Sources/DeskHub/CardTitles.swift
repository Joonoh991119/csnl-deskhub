import Foundation

/// 허브 카드 제목 한 표 (0.42.0 C3, R9-a — 랩장 JOP 10-19 '제목이 너무 말이 길다 … 딱딱 제목만 표시해줘').
/// 제목은 영어 한두 단어(UI 용어는 영어 — R3), 뺀 설명(수식어·필터·갱신 시각·이니셜)은 도움말(마우스를 올리면)로.
/// 갱신 시각·개수는 카드 끝 캡션(CardMetas.caption)이 이미 맡는다. 새 카드(classes·joint·members)도 이 표를 쓴다.
/// text.txt '[카드 제목]' 이 이 표 순서 그대로 — 다음 이름 변경도 여기 한 곳만.
enum HubCardTitle {
    struct Row { let id: String; let title: String; let hint: String }
    static let rows: [Row] = [
        Row(id: "grm", title: "Next GRM", hint: "다음 GRM 날짜·발표자·자료"),
        Row(id: "nownext", title: "Now · Next", hint: "CSNL·SLab 캘린더 — 지금 일정과 다음 일정"),
        Row(id: "members", title: "Members", hint: "멤버 상태·진행 프로젝트"),
        Row(id: "papers", title: "Papers", hint: "논문 추천 — 티어 S→A→B 순"),
        Row(id: "preprints", title: "Preprints", hint: "최신 원고 (OpenAlex)"),
        Row(id: "apps", title: "Apps", hint: "연구실에서 만든 앱 — 개수는 카드 끝 캡션"),
        Row(id: "joint", title: "Joint projects", hint: "공동연구가 생기면 이 칸에 — 지금은 연구실 플러그인 개발"),
        Row(id: "reminders", title: "Reminders", hint: "컨펌한 리마인더만"),
        Row(id: "tools", title: "Mail drafts", hint: "초안만 만들고 보내지 않습니다"),
        Row(id: "experiments", title: "Experiments", hint: "오늘 SLab + Prolific 진행·준비 중"),
        Row(id: "equipment", title: "Equipment", hint: "장비 예약 (예약 기준) — 갱신 시각은 카드 끝 캡션"),
        Row(id: "events", title: "Upcoming", hint: "다가오는 일정 — Notion Schedule + CSNL·SLab 캘린더, GRM 제외"),
        Row(id: "classes", title: "Classes", hint: "오늘·이번 주 수업 (Courses)"),
        Row(id: "grants", title: "Grants", hint: "연구비 보고·지원 일정"),
        Row(id: "followups", title: "Follow-ups", hint: "미팅 후속 — 보기: 내 것 · 연구실 읽기 · 개수만"),
        Row(id: "minutes", title: "Minutes", hint: "Plaud 요약 회의록"),
        Row(id: "blitz", title: "Paper Blitz", hint: "지난 Paper Blitz — 날짜는 꼬리표"),
        Row(id: "conferences", title: "Conferences", hint: "다가오는 학회"),
    ]
    private static let byID: [String: Row] = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    static func title(_ id: String) -> String { byID[id]?.title ?? id }
    static func hint(_ id: String) -> String? { byID[id]?.hint }
    /// text.txt '[카드 제목]' — 'id · 제목 · 도움말' 표 순서
    static func dumpLines() -> [String] { rows.map { "\($0.id) · \($0.title) · \($0.hint)" } }
}
