import SwiftUI
import AppKit

// 2026-10-13 JOP 요청 묶음: 논문 추천을 크게(+ 반응·댓글), 다음 GRM 줄 축소 + 연구원별 진행 프로젝트 버튼,
// 회의록은 최근 하나만(펼치기), 최신 원고(OpenAlex: JSL·SJK), Paper Blitz 는 아래 작은 칸으로.

// MARK: - Notion 댓글 (반응·댓글 저장소)

/// 논문 추천 페이지의 Notion 댓글. 본문 "[이니셜] 내용" — 내용이 반응 이모지 하나면 반응, '같이 읽자' 면 제안(0.39.0 C5), 아니면 댓글.
/// 통합(claude bot)이 쓰므로 누가 남겼는지는 이니셜로 적는다. Notion API 는 댓글 삭제가 없어 반응·제안은 더하기만 되고 취소는 취소 댓글로 남긴다.
struct PaperComment: Identifiable, Hashable {
    let id: String; let who: String; let text: String; let created: Date?
    /// 세 반응 — 의미 불변(관제탑·팝오버 '반응 없음'·전광판 논문 반응이 이것만 센다)
    var isReaction: Bool { HubPrefs.reactionEmojis.contains(text) }
    /// '같이 읽자' 제안 (0.39.0 C5, TALK) — 반응으로 세지 않고, 댓글로도 세지 않는다
    var isProposal: Bool { text == HubPrefs.talkText }
    /// "[BHL] ✖👍" · "[BHL] ✖같이 읽자" — Notion API 에 댓글 삭제가 없어 취소는 취소 댓글로 남긴다 (BHL R1 10-15, 0.39.0 C5)
    var isCancel: Bool {
        guard text.hasPrefix(HubPrefs.cancelMark) else { return false }
        let rest = cancelled
        return HubPrefs.reactionEmojis.contains(rest) || rest == HubPrefs.talkText
    }
    var cancelled: String { String(text.dropFirst(HubPrefs.cancelMark.count)) }
    /// 사람이 쓴 댓글 — 반응·제안·취소가 아닌 것 (댓글 수·댓글 칸 목록)
    var isNote: Bool { !isReaction && !isProposal && !isCancel }

    /// "[XX] 내용" → 이니셜(대문자)·내용. 이니셜이 없으면 who 빈 값 — comments(page:)·드라이런 파일·text-check 가 함께 쓴다
    static func parse(raw: String, id: String, created: Date?) -> PaperComment? {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        var who = "", text = raw
        if let r = raw.range(of: "^\\[([A-Za-z]{2,4})\\]\\s*", options: .regularExpression) {
            who = raw[r].trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).uppercased(); text = String(raw[r.upperBound...])
        }
        return PaperComment(id: id, who: who, text: text, created: created)
    }

    /// 사람·토큰(이모지·'같이 읽자')별로 가장 나중 것만 반영: 반응·제안 뒤 취소면 둘 다 뺀다. 취소 댓글은 화면에 안 보인다.
    static func settle(_ cs: [PaperComment]) -> [PaperComment] {
        let ordered = cs.sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
        var live: [String: PaperComment] = [:]   // "who|토큰" → 살아 있는 반응·제안
        var out: [PaperComment] = []
        for c in ordered {
            if c.isReaction || c.isProposal { live[c.who + "|" + c.text] = c }
            else if c.isCancel { live[c.who + "|" + c.cancelled] = nil }
            else { out.append(c) }
        }
        return out + live.values.sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
    }

    /// settle 뒤 값에서 '같이 읽자' 제안자 — 이니셜 있는 것만, 중복 없이 가나다 (이니셜 없는 제안은 누구인지 몰라 세지 않음)
    static func proposers(_ settled: [PaperComment]) -> [String] {
        var xs = Array(Set(settled.filter { $0.isProposal && !$0.who.isEmpty }.map(\.who))); xs.sort(); return xs
    }
    /// 제안자 2명 이상 = 모임 후보(계산만, 알림 없음)
    static let meetupMin = 2
    /// text-check comment·[논문 소통] 공용 한 줄 — '반응 n · 같이 BHL,JOP · 댓글 n[ · 모임 후보]'
    static func talkLine(_ settled: [PaperComment]) -> String {
        let ps = proposers(settled)
        return "반응 \(settled.filter(\.isReaction).count) · 같이 " + (ps.isEmpty ? "—" : ps.joined(separator: ","))
            + " · 댓글 \(settled.filter(\.isNote).count)" + (ps.count >= meetupMin ? " · 모임 후보" : "")
    }
}

extension NotionAPI {
    func comments(page: String) async throws -> [PaperComment] {
        var req = URLRequest(url: URL(string: "https://api.notion.com/v1/comments?block_id=\(page)&page_size=100")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 300 {
            throw NSError(domain: "Notion", code: code, userInfo: [NSLocalizedDescriptionKey: (obj["message"] as? String) ?? "HTTP \(code)"])
        }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed: [PaperComment] = ((obj["results"] as? [[String: Any]]) ?? []).compactMap { c in
            PaperComment.parse(raw: NotionAPI.richText(c["rich_text"]), id: c["id"] as? String ?? UUID().uuidString,
                               created: (c["created_time"] as? String).flatMap { iso.date(from: $0) })
        }
        return PaperComment.settle(parsed)
    }

    func addComment(page: String, text: String) async throws {
        var req = URLRequest(url: URL(string: "https://api.notion.com/v1/comments")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["parent": ["page_id": page], "rich_text": [["text": ["content": text]]]])
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 300 {
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let hint = code == 403 ? " — Notion 통합 설정에서 'Insert comments' 권한을 켜 주세요" : ""
            throw NSError(domain: "Notion", code: code, userInfo: [NSLocalizedDescriptionKey: ((obj["message"] as? String) ?? "HTTP \(code)") + hint])
        }
    }
}

/// 이 맥에서 반응·댓글을 남기는 사람(이니셜). 맥마다 다르므로 UserDefaults 에 둔다. 처음엔 .env 의 MY_INIT.
enum HubPrefs {
    // 읽겠음 · 읽었음 · 관련없음/관심없음 — 세 개만 (BHL 빠른 컨펌 2026-10-13)
    static let reactionEmojis = ["👍", "✅", "🙅"]
    static let reactionLabels = ["👍": "읽겠음", "✅": "읽었음", "🙅": "관심없음"]
    static let cancelMark = "✖"
    /// 논문 소통 '같이 읽자' (0.39.0 C5) — 댓글 '[이니셜] 같이 읽자', 취소 '[이니셜] ✖같이 읽자'
    static let talkText = "같이 읽자"
    /// 이 맥에서 사람이 직접 확인한 이니셜인가. .env 의 MY_INIT 도, 이전 버전이 UserDefaults 에 남긴 값도(BHL 맥의 SYJ — #21 10-15 17:26)
    /// 한 번은 확인받는다 → 확인 플래그를 따로 둔다. 스냅샷용 DESKHUB_ME 만 예외.
    static var meChosen: Bool {
        get {
            // 시험 훅 (0.39.0 C0): DESKHUB_ME_CHOSEN=0 → 이니셜 미확인 상태를 스냅샷에서 재현 (DESKHUB_ME 보다 먼저, UserDefaults 쓰지 않음)
            if ProcessInfo.processInfo.environment["DESKHUB_ME_CHOSEN"] == "0" { return false }
            if let v = ProcessInfo.processInfo.environment["DESKHUB_ME"], !v.isEmpty { return true }
            return UserDefaults.standard.bool(forKey: "DeskHub.meConfirmed")
        }
        set { UserDefaults.standard.set(newValue, forKey: "DeskHub.meConfirmed") }
    }
    static var me: String {
        get {
            if let v = ProcessInfo.processInfo.environment["DESKHUB_ME"], !v.isEmpty { return v }   // 스냅샷 비교용 (D2)
            if let v = UserDefaults.standard.string(forKey: "DeskHub.me"), !v.isEmpty { return v }
            let env = (try? String(contentsOfFile: ("~/.claude/csnl-report/.env" as NSString).expandingTildeInPath, encoding: .utf8)) ?? ""
            for line in env.components(separatedBy: .newlines) where line.hasPrefix("MY_INIT=") {
                return String(line.dropFirst(8)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            }
            return ""
        }
        set { UserDefaults.standard.set(newValue, forKey: "DeskHub.me") }
    }
    /// 논문 추천 보기: 이니셜(그 사람 추천만) · "전체". 비면 me (#16 JYK)
    static var paperFilter: String {
        get { UserDefaults.standard.string(forKey: "DeskHub.paperFilter") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "DeskHub.paperFilter") }
    }
    /// 티어 순서 S → A → B → C (모르는 값은 맨 뒤)
    static func tierRank(_ t: String) -> Int { ["S": 0, "A": 1, "B": 2, "C": 3][t.uppercased()] ?? 9 }

    /// 첫 실행 안내(⌃⌥D) 를 봤는가 — 주버전(0.33)마다 한 번. DESKHUB_HINT=1 강제 표시, =0 강제 숨김 (스냅샷용, HubClock 패턴)
    static var hintMajor: String { Hub.buildLabel.split(separator: " ").first.map { $0.split(separator: ".").prefix(2).joined(separator: ".") } ?? "0" }
    static func hintSeen(major: String = hintMajor) -> Bool {
        if let v = ProcessInfo.processInfo.environment["DESKHUB_HINT"], !v.isEmpty { return v != "1" }
        return UserDefaults.standard.bool(forKey: "DeskHub.hintSeen." + major)
    }
    static func markHintSeen(major: String = hintMajor) { UserDefaults.standard.set(true, forKey: "DeskHub.hintSeen." + major) }
}

/// 첫 실행 안내 한 줄 — ⌃⌥D 숨김↔맨 앞, Dock 보이기는 메뉴 (R2-05 SMJ). ✕ 로 이 주버전 동안 숨김
struct HintBar: View {
    var compact = false
    @State private var seen = HubPrefs.hintSeen()
    var body: some View {
        // 관제탑·팝오버에 각각 인스턴스가 있어 한쪽 ✕ 가 다른 쪽에 바로 안 퍼졌음 → 나타날 때마다 UserDefaults 를 다시 읽는다 (리뷰 10-15 low)
        if !seen {
            HStack(spacing: 8) {
                Image(systemName: "keyboard").font(.hub(compact ? 10.5 : 11.5)).foregroundStyle(Hub.text2)
                // 팝오버(compact)는 폭이 좁아 긴 문장이 잘림(N7 스냅샷) → 짧은 문장
                Text(compact ? "\(DeskHubNotice.hotkeyLabel) 숨김 ↔ 맨 앞 · Dock 은 아이콘 우클릭" : "\(DeskHubNotice.hotkeyLabel) 숨김 ↔ 맨 앞 · Dock 보이기는 메뉴 막대 아이콘 오른쪽 클릭")
                    .font(.hub(compact ? 11 : 12)).foregroundStyle(Hub.text2).lineLimit(1)
                Spacer(minLength: 4)
                Button { HubPrefs.markHintSeen(); seen = true } label: {
                    Image(systemName: "xmark").font(.hub(10, weight: .bold)).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Hub.text3).help("이 안내 닫기 (다음 주버전까지)")
            }
            .padding(.horizontal, compact ? 8 : 10).padding(.vertical, compact ? 5 : 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Hub.surface))
            .onAppear { seen = HubPrefs.hintSeen() }
        }
    }
}

// MARK: - 진행 중인 프로젝트 (Projects & Chores DB)

struct ProjectRow: Identifiable, Hashable { let id: String; let name: String; let status: String; let memberIDs: [String]; var initials: [String] = [] }

// MARK: - 최신 원고 (OpenAlex)

struct PreprintRow: Identifiable, Hashable {
    let id: String; let title: String; let venue: String; let date: Date?; let url: URL?; let initials: [String]; let type: String
}

enum OpenAlex {
    /// 저자 id(이니셜 → OpenAlex id)별 최근 원고. 프리프린트·논문만, 기간 안, 최신순, DOI 로 중복 제거
    static func latest(authors: [String: String], days: Int, perAuthor: Int = 2) async -> [PreprintRow] {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        var byKey: [String: PreprintRow] = [:]
        for (ini, aid) in authors.sorted(by: { $0.key < $1.key }) {
            let u = "https://api.openalex.org/works?filter=author.id:\(aid),from_publication_date:\(f.string(from: since)),type:preprint|article&sort=publication_date:desc&per_page=\(perAuthor)&mailto=csnl@snu.ac.kr"
            guard let url = URL(string: u), let (data, _) = try? await URLSession.shared.data(from: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = obj["results"] as? [[String: Any]] else { continue }
            for w in results {
                let doi = (w["doi"] as? String) ?? (w["id"] as? String) ?? UUID().uuidString
                let src = ((w["primary_location"] as? [String: Any])?["source"] as? [String: Any])?["display_name"] as? String ?? ""
                let venue = src.replacingOccurrences(of: " (Cold Spring Harbor Laboratory)", with: "")
                if var row = byKey[doi] { if !row.initials.contains(ini) { row = PreprintRow(id: row.id, title: row.title, venue: row.venue, date: row.date, url: row.url, initials: row.initials + [ini], type: row.type) }; byKey[doi] = row; continue }
                byKey[doi] = PreprintRow(id: doi, title: (w["title"] as? String) ?? "", venue: venue,
                                         date: (w["publication_date"] as? String).flatMap { f.date(from: $0) },
                                         url: URL(string: doi), initials: [ini], type: (w["type"] as? String) ?? "")
            }
        }
        return byKey.values.filter { !$0.title.isEmpty }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}

// MARK: - 줄바꿈 배치 (멤버·프로젝트 칩)

struct FlowLayout: Layout {
    var spacing: CGFloat = 6, lineSpacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > w { y += line + lineSpacing; x = 0; line = 0 }
            x += sz.width + spacing; line = max(line, sz.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; line = max(line, sz.height)
        }
    }
}

// MARK: - 뷰 조각

/// 다음 GRM — 두 줄 (0.37.0): ① '다음 GRM · M.d · D-n' ② 발표자(큰 값) + 노트·초록·슬라이드.
/// 폭이 모자라면 단추가 발표자 아래 줄로 내려간다 — 발표자 이름은 잘리지 않는다
struct CompactGRMBar: View {
    @ObservedObject var model: NotionHubModel
    /// 랩 허브만 — 카드 끝 캡션 한 줄 (0.40.0 C2, A1)
    var caption = false
    @Environment(\.cardStyle) private var cs
    var body: some View {
        if let g = model.nextGRM {
            let soon = (Calendar.current.dateComponents([.day], from: model.today, to: g.date).day ?? 9) <= 3
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    // 제목 — SectionTitle 과 같은 글자(cs.title bold Hub.text, 0.44.0 B2 #71). 출처는 도움말로(#65)
                    Text(HubCardTitle.title("grm")).font(.hub(cs.title, weight: .bold)).foregroundStyle(Hub.text).tracking(0.2).lineLimit(1).fixedSize()
                        .help((HubCardTitle.hint("grm") ?? "") + (caption ? "\n" + CardMetas.caption("grm", model) : ""))
                    Text(Hub.day(g.date)).font(.hub(cs.aux, weight: .semibold, design: .rounded)).foregroundStyle(Hub.text2).monospacedDigit()
                    Text(Hub.dday(g.date)).font(.hub(cs.tag, weight: .bold)).foregroundStyle(Hub.onAccent)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(soon ? Hub.signal : Hub.ink))
                    // 꼬리표 = 지난 GRM 날짜 (허브만, 0.40.0 C3)
                    if caption, let f = model.cardTag("grm") { FreshnessTag(f: f).layoutPriority(-1) }   // 좁으면 꼬리표가 먼저 줄어든다
                    if caption { SeenBadge(card: "grm-mine") }   // 내가 발표자인 GRM 이 바뀌면 '새 n' (0.40.0 C4)
                    Spacer(minLength: 0)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { presenter(g).fixedSize(); actions(g); Spacer(minLength: 0) }
                    VStack(alignment: .leading, spacing: 4) {
                        presenter(g).lineLimit(1).minimumScaleFactor(0.7)
                        HStack(spacing: 6) { actions(g); Spacer(minLength: 0) }
                    }
                }
            }
            .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV + 2)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.heroBG))
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.loading ? "Notion 에서 불러오는 중…" : "예정된 GRM 이 없습니다").font(.hub(cs.body)).foregroundStyle(Hub.text2)
                    .help(caption ? CardMetas.caption("grm", model) : "")
            }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
        }
    }

    private func presenter(_ g: GRMSlot) -> some View {
        Text(g.presenters.isEmpty ? "발표자 미정" : g.presenters).font(.hub(cs.big, weight: .bold))
    }

    @ViewBuilder private func actions(_ g: GRMSlot) -> some View {
        HStack(spacing: 6) {
            if let n = model.note(for: g) { SmallAction(symbol: "doc.text", label: "발표 노트", prominent: true) { model.openInApp(id: n.id) } }
            if let d = g.docURL { SmallAction(symbol: "doc.richtext", label: "초록") { NSWorkspace.shared.open(d) } }
            SmallAction(symbol: "folder", label: "슬라이드") { model.openSlides(for: g) }
        }
        .fixedSize()
    }
}

struct SmallAction: View {
    let symbol: String; let label: String; var prominent = false; let action: () -> Void
    @Environment(\.cardStyle) private var cs
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) { Image(systemName: symbol); Text(label).lineLimit(1) }
                .font(.hub(cs.tag + 0.5, weight: .semibold))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(prominent ? Hub.ink : Hub.fillNeutral))
                .foregroundStyle(prominent ? Hub.onAccent : Hub.text)
        }
        .buttonStyle(.plain)
    }
}

/// 연구원 + 진행 중인 프로젝트 버튼 (이름 → Members 페이지, 프로젝트 → Projects 페이지)
/// 연구원 줄 데이터 — NAS Grant/_ssot/member_links.json (scripts/build_member_links.py 가 만든다)
/// 프로젝트 = Memory/<이니셜> 폴더명, 포스터 = BK21 SSOT 발표 실적 링크, GitHub = 있을 때만
struct MemberLinks {
    struct Project: Hashable { let name: String; let path: String }
    struct Poster: Hashable { let title: String; let venue: String; let date: String; let url: URL }
    struct Entry { let name: String; let projects: [Project]; let poster: Poster?; let github: URL? }
    var members: [String: Entry] = [:]
    var hidden: [(ini: String, name: String)] = []
    var away: [String: (name: String, label: String)] = [:]

    static func load(_ path: String) -> MemberLinks {
        var out = MemberLinks()
        guard let d = FileManager.default.contents(atPath: path),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return out }
        for (k, v) in (j["members"] as? [String: [String: Any]]) ?? [:] {
            let projs = ((v["projects"] as? [[String: Any]]) ?? []).compactMap { p -> Project? in
                guard let n = p["name"] as? String, let path = p["path"] as? String else { return nil }
                return Project(name: n, path: path)
            }
            var poster: Poster? = nil
            if let p = v["poster"] as? [String: Any], let u = (p["url"] as? String).flatMap(URL.init(string:)) {
                poster = Poster(title: p["title"] as? String ?? "", venue: p["venue"] as? String ?? "", date: p["date"] as? String ?? "", url: u)
            }
            out.members[k] = Entry(name: v["name"] as? String ?? "", projects: projs, poster: poster,
                                   github: (v["github"] as? String).flatMap(URL.init(string:)))
        }
        out.hidden = ((j["hidden"] as? [[String: Any]]) ?? []).map { ($0["init"] as? String ?? "", $0["name"] as? String ?? "") }
        for (k, v) in (j["away"] as? [String: [String: Any]]) ?? [:] { out.away[k] = (v["name"] as? String ?? "", v["label"] as? String ?? "") }
        return out
    }
}

/// 윗줄 오른쪽 — 연구원 이름 + 프로젝트(Memory 폴더) · 포스터 · GitHub. 링크가 있는 버튼만 그린다
/// (GRM 발표자 강조는 하지 않는다 — 다음 GRM 칸에 이미 있음, 랩장 의견 2026-10-13)
struct MembersProjectsStrip: View {
    @ObservedObject var model: NotionHubModel
    /// 랩 허브만 — 칩 아래 캡션 한 줄 (0.40.0 C2, A1)
    var caption = false

    private static func isHidden(_ model: NotionHubModel, _ m: Member) -> Bool { model.memberLinks.hidden.contains { $0.ini == m.initials || $0.name == m.name } }
    static func awayLabel(_ model: NotionHubModel, _ m: Member) -> String? {
        model.memberLinks.away.first { $0.key == m.initials || $0.value.name == m.name }?.value.label
    }
    /// 칩 줄에 보이는 멤버 — 숨김 제외, 활성 또는 away (text.txt [진행 프로젝트] 도 이 목록)
    static func shown(_ model: NotionHubModel) -> [Member] {
        model.members.filter { !isHidden(model, $0) && ($0.active || awayLabel(model, $0) != nil) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FlowLayout(spacing: 5, lineSpacing: 4) {
                ForEach(Self.shown(model)) { m in
                    // 칩 항목 = model.memberLinkEntry(for:) — 팝오버 '진행 프로젝트'와 같은 매칭 (R-32)
                    let e = model.memberLinkEntry(for: m)
                    MemberGroup(model: model, member: m, entry: e, away: Self.awayLabel(model, m))
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Hub.surface))
                }
                // 칩 줄 끝 한 칸 — Members 편집 시각(집계) 꼬리표 (허브만, 0.40.0 C3)
                if caption, let f = model.cardTag("members") { FreshnessTag(f: f).padding(.vertical, 4) }
            }
            // 칩 아래 출처 줄은 뺐다 (0.44.0 B2, #65) — 덤프 [카드 출처] 그대로
        }
    }
}

extension Hub {
    static var card: Color { Theme.color(\.card) }
}

extension NotionHubModel {
    /// 이니셜 확인 줄·'나:' 고르기의 단추 — Members 이니셜 + 교수님(FollowupLogic.supervisors). 교수님 맥이 SL 을 골라 미팅 후속 '읽기' 보기에 들어가게
    var meChoices: [String] { FollowupLogic.chooserInitials(members: members.map(\.initials), aliases: cfg.initialsAliases) }
    func meChoiceHelp(_ ini: String) -> String {
        members.first { $0.initials == ini }?.name ?? "지도교수님 — 미팅 후속은 연구실 전체를 읽기만 (쓰기 없음)"
    }
}

/// 이 맥의 이니셜 확인 줄 — 랩 허브만이 아니라 관제탑·팝오버에도 (BHL #21 10-15 17:43: 관제탑만 쓰는 사람은 확인을 볼 일이 없음).
/// 한 번 고르면(UserDefaults DeskHub.meConfirmed) 어느 뷰에서도 다시 안 뜬다. 스냅샷(DESKHUB_ME)에는 안 뜬다.
struct MeConfirmBar: View {
    @ObservedObject var model: NotionHubModel
    var compact = false
    @State private var done = HubPrefs.meChosen

    var body: some View {
        if !done {
            let me = HubPrefs.me
            VStack(alignment: .leading, spacing: 5) {
                Text(me.isEmpty ? "반응·댓글에 붙일 이니셜을 골라 주세요 (이 맥에만 저장)"
                     : "이 맥에 저장된 이니셜은 \(me) 입니다. 본인이 맞으면 \(me) 를, 아니면 본인 이니셜을 눌러 주세요 (이 맥에만 저장)")
                    .font(.hub(compact ? 11 : 12)).foregroundStyle(Hub.text2).fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    // Members 이니셜 + 교수님(SL — Members DB 에 없음, 0.41.0 검증 1)
                    ForEach(model.meChoices, id: \.self) { ini in
                        Button { HubPrefs.me = ini; HubPrefs.meChosen = true; done = true; model.objectWillChange.send() } label: {
                            Text(ini).font(.hub(11, weight: .bold, design: .rounded))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ini == me ? Hub.ink : Hub.fillNeutral))
                                .foregroundStyle(ini == me ? Hub.onAccent : Hub.text)
                        }
                        .buttonStyle(.plain).help(model.meChoiceHelp(ini))
                    }
                }
            }
            .padding(compact ? 8 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Hub.ink.opacity(0.45)))
        }
    }
}

/// 논문 추천 — 큰 칸. 행마다 추천 이유, 반응(이모지 + 이니셜), 댓글
/// 논문 반응 줄 판정 (0.42.0 C1, #23) — 화면(PaperRecBoard.row)·text.txt '반응 줄:'·fixture(kind react) 공용 순수 함수.
/// 쉴 때: 내 반응 칩(그 이모지) · 남이 남긴 이모지의 수(합계, '👍2 ✅1') · 댓글 n. 호버: 반응 3개(수 · 내 것 *) + 댓글 단추
enum PaperReact {
    enum Chip: Equatable {
        case mine(String)              // 쉴 때 내 반응(누르면 취소)
        case counts(String)            // 쉴 때 남의 반응 수 '👍2 ✅1'
        case notes(Int)                // 쉴 때 '댓글 n'
        case react(String, Int, Bool)  // 호버 반응 단추 (이모지, 수, 내 것)
        case comment(Int)              // 호버 댓글 단추
    }
    static func line(reactions: [(String, String)], me: String, notes: Int, hover: Bool) -> [Chip] {
        let meU = me.trimmingCharacters(in: .whitespaces).uppercased()
        func who(_ e: String) -> [String] { reactions.filter { $0.0 == e }.map { $0.1.uppercased() } }
        if hover {
            return HubPrefs.reactionEmojis.map { e in let w = who(e); return Chip.react(e, w.count, !meU.isEmpty && w.contains(meU)) } + [.comment(notes)]
        }
        var out: [Chip] = HubPrefs.reactionEmojis.filter { !meU.isEmpty && who($0).contains(meU) }.map { .mine($0) }
        let others = HubPrefs.reactionEmojis.compactMap { e -> String? in
            let w = who(e); return w.contains { $0 != meU } ? "\(e)\(w.count)" : nil
        }
        if !others.isEmpty { out.append(.counts(others.joined(separator: " "))) }
        if notes > 0 { out.append(.notes(notes)) }
        return out
    }
    /// 글로 — 쉴 때 '내 👍 · 👍2 ✅1 · 댓글 2' (없으면 '—'), 호버 '[👍2*] [✅1] [🙅0] · 댓글 2'
    static func text(_ chips: [Chip]) -> String {
        if chips.isEmpty { return "—" }
        var parts: [String] = [], btn: [String] = []
        for c in chips {
            switch c {
            case .mine(let e): parts.append("내 " + e)
            case .counts(let t): parts.append(t)
            case .notes(let n): parts.append("댓글 \(n)")
            case .react(let e, let n, let mine): btn.append("[\(e)\(n)\(mine ? "*" : "")]")
            case .comment(let n): parts.append(btn.joined(separator: " ")); btn = []; parts.append(n > 0 ? "댓글 \(n)" : "댓글")
            }
        }
        if !btn.isEmpty { parts.append(btn.joined(separator: " ")) }
        return parts.joined(separator: " · ")
    }
    /// fixture 입력 'me=JOP;r=👍:JOP,BHL|✅:SMJ;notes=2;hover=0|1'
    static func check(_ input: String) -> String {
        var k: [String: String] = [:]
        for part in input.components(separatedBy: ";") {
            let p = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if p.count == 2 { k[p[0].trimmingCharacters(in: .whitespaces)] = p[1] }
        }
        var pairs: [(String, String)] = []
        for g in (k["r"] ?? "").components(separatedBy: "|") where !g.isEmpty {
            let q = g.split(separator: ":", maxSplits: 1).map(String.init)
            guard q.count == 2 else { continue }
            for w in q[1].components(separatedBy: ",") where !w.isEmpty { pairs.append((q[0], w)) }
        }
        return text(line(reactions: pairs, me: k["me"] ?? "", notes: Int(k["notes"] ?? "") ?? 0, hover: k["hover"] == "1"))
    }
}

struct PaperRecBoard: View {
    @ObservedObject var model: NotionHubModel
    /// 허브 열 빈 면 측정 키 (R-J1, HubLayoutProbe) — 허브 열1 만 준다. 이 카드의 스크롤 칸이 열에서 늘어나는 유일한 부분이라 그 빈 높이 = 열 빈 면
    var probeKey: String? = nil
    /// 랩 허브만 — 7일 안에 보낸 추천(없으면 티어 순 2)만 내용 높이로, 나머지는 '▸ 더 보기' 를 누르면 지금처럼 스크롤 칸 (0.37.0 C2)
    var nearOnly = false
    /// 연구 탭만 — 반응 줄 끝 '같이 읽자' 단추·제안자·모임 후보 (0.39.0 C5). 허브·관제탑·공정 보드·나 뷰는 false 그대로(열 높이 불변)
    var talk = false
    /// 큰 자리 4곳(허브 열1·관제탑·안내판·나 뷰) — 생산자가 멈췄으면(papersStopped) 한 줄로 접는다 (0.40.0 C8, R4). 연구 탭은 false
    var fold = false
    @ObservedObject private var expansion = HubExpansion.shared
    @ObservedObject private var fill = HubFill.shared
    @State private var openComments: String? = nil
    /// 마우스가 올라간 행 (0.42.0 C1, #23) — 그 행만 반응 단추 3개
    @State private var hoverRow: String? = nil
    @State private var draft: [String: String] = [:]
    @State private var askWho = false
    @State private var me = HubPrefs.me
    @State private var filter = HubPrefs.paperFilter
    @Environment(\.cardStyle) private var cs

    /// 지금 보는 사람: 고른 값 → 없으면 이 맥의 이니셜 → 없으면 전체
    private var who: String { Self.who(filter: filter, me: me) }
    static func who(filter: String, me: String) -> String { filter.isEmpty ? (me.isEmpty ? "전체" : me) : filter }
    private var researchers: [String] { Array(Set(model.papers.map(\.researcher).filter { !$0.isEmpty })).sorted() }
    /// 그 사람에게 온 추천만, 티어 순(S→A→B) → 최근 보낸 순 (#16)
    private var visible: [PaperRec] { Self.visible(model, who: who) }
    static func visible(_ model: NotionHubModel, who: String) -> [PaperRec] {
        model.papers.filter { who == "전체" || $0.researcher == who }
            .sorted { a, b in
                let ra = HubPrefs.tierRank(a.tier), rb = HubPrefs.tierRank(b.tier)
                if ra != rb { return ra < rb }
                return (a.sentAt ?? .distantPast) > (b.sentAt ?? .distantPast)
            }
    }

    /// 이니셜 고르기 칸이 보이는가 — 본문 표시 조건. 채움 보류(holdOn)는 이 중 askWho 로 새로 열려 높이가 바뀐 경우만 쓴다 (0.39.0 C0, 검증 1·리뷰 2)
    private var whoPickerShown: Bool { askWho || pickerStanding }
    /// 이니셜 미확인(me 빈 값·!meChosen)이라 늘 떠 있는 고르기 칸 — 측정 높이에 이미 들어 있는 안정 레이아웃
    private var pickerStanding: Bool { me.isEmpty || !HubPrefs.meChosen }
    /// 지금 그려진 행 — 접힘이면 가까운 것 + 채움 행, 아니면 보기 대상 전부. 댓글 칸이 열린 행이 여기 없으면(필터 변경·재조회·7일 창 밖) 칸은 화면에 없다
    private var drawnIDs: Set<String> {
        if nearOnly && !expansion.isOpen("papers") {
            return Set(HubNear.papers(model, visible: visible).shown(open: false, extra: fill.extra["papers"] ?? 0).map(\.id))
        }
        return Set(visible.map(\.id))
    }
    /// 열1 을 잠깐 늘리는 것이 실제로 보이는가 — 사용자가 연 이니셜 고르기(askWho) 또는 그려진 행의 댓글 칸 (0.38.0 리뷰 medium: openComments != nil 이면 칸이 사라져도 보류가 남았음).
    /// 이니셜 미확인(me 빈 값·!meChosen)으로 늘 떠 있는 고르기 칸은 측정 높이에 포함된 안정 레이아웃이라 보류하지 않는다 — 보류하면 공용 맥에서 열1 채움이 영영 결정되지 않음 (0.39.0 검증 1).
    /// 그 칸이 이미 떠 있을 때 반응·댓글·'나:' 를 눌러 askWho 가 켜져도 높이 변화가 없으니 보류하지 않는다 (리뷰 2)
    private var holdOn: Bool { (askWho && !pickerStanding) || (openComments.map { drawnIDs.contains($0) } ?? false) }

    var body: some View {
        if fold && model.papersStopped { folded } else { board }
    }

    /// 접힌 한 줄 (R4) — 제목·신선도 + '새 추천이 오면 자동으로 다시 펼칩니다 · 연구 탭 ↗'(Hub.text2). 새 Sent At 이 오면 저절로 원래 보드
    private var folded: some View {
        VStack(alignment: .leading, spacing: cs.gap) {
            SectionTitle(card: "papers", trailing: model.cfg.paperRecDB.isEmpty ? nil : "Notion", fresh: model.papersFreshness) { model.openInApp(id: model.cfg.paperRecDB) }
            Button { KeyBus.shared.send("tab:연구") } label: {
                HStack(spacing: 4) {
                    Text("새 추천이 오면 자동으로 다시 펼칩니다 · 연구 탭")
                    Image(systemName: "arrow.up.forward")
                }
                .font(.hub(cs.aux)).foregroundStyle(Hub.text2).lineLimit(1)
                .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("논문 추천 생산자(P23)가 \(model.papersStoppedSince) 이후 멈춤 — 전체 목록·반응은 연구 탭 (R4-fold)")
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var board: some View {
        VStack(alignment: .leading, spacing: cs.gap) {
            HStack(spacing: 8) {
                SectionTitle(card: "papers", trailing: model.cfg.paperRecDB.isEmpty ? nil : "Notion", fresh: model.papersFreshness) { model.openInApp(id: model.cfg.paperRecDB) }
                Menu {
                    if !me.isEmpty { Button("내 추천 (\(me))") { setFilter(me) } }
                    ForEach(researchers.filter { $0 != me }, id: \.self) { r in Button(model.member(initials: r).map { "\($0.name) (\(r))" } ?? r) { setFilter(r) } }
                    Divider()
                    Button("전체 · 티어 순") { setFilter("전체") }
                } label: {
                    Text("보기: " + (who == "전체" ? "전체" : (who == me ? "내 추천 \(me)" : who))).font(.hub(cs.aux, weight: .semibold))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("누구에게 온 추천을 볼지 (이 맥에만 저장). 티어 S→A→B 순")
                Button { askWho = true } label: {
                    Text(me.isEmpty ? "나: 없음" : "나: \(me)" + (HubPrefs.meChosen ? "" : " ?")).font(.hub(cs.tag)).foregroundStyle(HubPrefs.meChosen ? Hub.text3 : Hub.ink)
                }
                .buttonStyle(.plain).help("반응·댓글에 붙는 이니셜 (이 맥에만 저장) · 눌러서 바꾸기")
            }
            if whoPickerShown { whoPicker }
            let all = visible
            let cut = nearOnly ? HubNear.papers(model, visible: all) : nil
            if let cut, !expansion.isOpen("papers") {
                // 접힘: 스크롤 없이 내용 높이 — 열 끝까지 늘지 않는다. 열 바닥이 비면 다음 추천을 더 (HubFill, 0.38.0 C3)
                let e = fill.extra["papers"] ?? 0
                let rows = cut.shown(open: false, extra: e)
                VStack(spacing: 0) {
                    // 보인 행 높이 실측 → 채움이 추정(135×배율) 대신 이 평균으로 정한다 (검증 1 — 1.3배에서 넣었다 넘쳐 뺐음)
                    list(rows).background(GeometryReader { g in
                        Color.clear
                            .onAppear { let h = g.size.height; MainActor.assumeIsolated { HubFill.shared.rowsMeasured("papers", height: h, rows: rows.count) } }
                            .onChange(of: g.size.height) { _, h in MainActor.assumeIsolated { HubFill.shared.rowsMeasured("papers", height: h, rows: rows.count) } }
                    })
                    CardFooter(caption: CardMetas.caption("papers", model), toggleKey: "papers", more: cut.toggleCount(open: false, extra: e))
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
            } else {
                VStack(spacing: 0) {
                    ScrollView(.vertical, showsIndicators: false) {
                        list(all).hubProbe(probeKey, .content)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .hubProbe(probeKey, .visible)
                    if let cut { CardFooter(caption: CardMetas.caption("papers", model), toggleKey: "papers", more: cut.more) }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: nearOnly && !expansion.isOpen("papers") ? nil : .infinity, alignment: .top)
        // 댓글 칸·이니셜 고르기가 열1 을 잠깐 늘리는 동안 채움 넘침 고침을 멈춘다 — 그 사이 뺀 행이 그날 내내 안 돌아오던 것 (검증 1 리뷰).
        // 0.39.0 C0: 높이를 바꾸는 것만 센다 — 새로 연 고르기 칸·그려진 행의 댓글 칸. 이니셜 미확인으로 늘 떠 있는 고르기 칸(askWho 가 켜져도)과
        // 사라진 행의 댓글 칸은 보류하지 않음 (검증 1·리뷰 2). initial 로 처음부터
        .onChange(of: holdOn, initial: true) { _, on in if nearOnly { HubFill.shared.setHold("papers-ui", col: "1", on) } }
        .onDisappear { if nearOnly { HubFill.shared.setHold("papers-ui", col: "1", false) } }
    }

    private func list(_ rows: [PaperRec]) -> some View {
        VStack(spacing: 0) {
            if rows.isEmpty {
                Text(model.cfg.paperRecDB.isEmpty ? "논문 추천 DB 가 연결되지 않았습니다"
                     : (model.loading ? "불러오는 중…" : (model.papers.isEmpty ? "추천 논문 없음" : "\(who) 에게 온 추천 없음 — 위 '보기'에서 다른 사람·전체")))
                    .font(.hub(cs.body)).foregroundStyle(Hub.text2).padding(cs.empty).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, p in
                row(p)
                if i < rows.count - 1 { RowDivider() }
            }
        }
    }

    private var whoPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(me.isEmpty || HubPrefs.meChosen ? "반응·댓글에 붙일 이니셜을 골라 주세요 (이 맥에만 저장)"
                 : "이 맥에 저장된 이니셜은 \(me) 입니다(설정 파일 또는 이전 버전). 본인이 맞으면 \(me) 를, 아니면 본인 이니셜을 눌러 주세요 (이 맥에만 저장)")
                .font(.hub(cs.aux)).foregroundStyle(Hub.text2)
            FlowLayout(spacing: 5, lineSpacing: 5) {
                // MeConfirmBar 와 같은 선택지 — Members 이니셜 + 교수님 (0.41.0 검증 1)
                ForEach(model.meChoices, id: \.self) { ini in
                    Button { HubPrefs.me = ini; HubPrefs.meChosen = true; me = ini; askWho = false } label: {
                        Text(ini).font(.hub(cs.tag, weight: .bold, design: .rounded))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ini == me ? Hub.ink : Hub.fillNeutral))
                            .foregroundStyle(ini == me ? Hub.onAccent : Hub.text)
                    }
                    .buttonStyle(.plain).help(model.meChoiceHelp(ini))
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Hub.divider))
    }

    @ViewBuilder
    private func row(_ p: PaperRec) -> some View {
        let comments = model.paperComments[p.id] ?? []
        let reactions = comments.filter(\.isReaction), notes = comments.filter(\.isNote)
        VStack(alignment: .leading, spacing: 6) {
            Button { model.openInApp(id: p.id) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(p.tier.isEmpty ? "·" : p.tier).font(.hub(cs.tag, weight: .bold, design: .rounded))
                        .frame(width: cs.col(22), height: cs.col(20))
                        // 티어 S 도 남색 — 적색은 마감·오류에만 (N2, 적색 ≤3/화면). S 는 굵기·테두리로 구별
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Hub.ink.opacity(p.tier == "S" ? 0.22 : 0.12)))
                        .foregroundStyle(Hub.ink)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.title).font(.hub(cs.body, weight: .semibold)).lineSpacing(2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Text([p.authors, p.researcher.isEmpty ? "" : "추천: \(p.researcher)"].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.hub(cs.aux)).foregroundStyle(Hub.text2).lineLimit(1)
                        if !p.recommendation.isEmpty {
                            Text(p.recommendation).font(.hub(cs.aux)).foregroundStyle(Hub.text2).lineSpacing(2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                    if p.presentPlanned { Text("발표 예정").font(.hub(cs.tag, weight: .bold)).foregroundStyle(Hub.ok) }
                    if let d = p.doi {
                        Button { NSWorkspace.shared.open(d) } label: { Image(systemName: "link").font(.hub(11)) }
                            .buttonStyle(.plain).foregroundStyle(Hub.text2).help(d.absoluteString)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 반응 줄 (0.42.0 C1, #23) — 쉴 때는 내 반응 칩 하나 + 남의 수 + 댓글 n, 마우스를 올렸거나 댓글 칸이 열렸을 때만 반응 3개 + 댓글 단추.
            // 두 상태를 ZStack 에 겹쳐 두어(안 보이는 쪽 opacity 0) 줄 높이가 같다 — 호버로 목록이 출렁이지 않게. 연구 탭 '같이 읽자'는 늘 보인다
            let hover = hoverRow == p.id || openComments == p.id
            let pairs = reactions.map { ($0.text, $0.who) }
            HStack(alignment: .center, spacing: 6) {
                ZStack(alignment: .leading) {
                    restLine(p, PaperReact.line(reactions: pairs, me: me, notes: notes.count, hover: false))
                        .opacity(hover ? 0 : 1).allowsHitTesting(!hover)
                    hoverLine(p, reactions: reactions, notes: notes)
                        .opacity(hover ? 1 : 0).allowsHitTesting(hover)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if talk {
                    TalkControls(model: model, commits: model.talkCommits, paper: p, proposers: PaperComment.proposers(comments), me: me) { askWho = true }
                }
            }
            .padding(.leading, cs.col(30))
            if openComments == p.id {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(notes) { c in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(c.who.isEmpty ? "?" : c.who).font(.hub(cs.tag, weight: .bold, design: .rounded)).foregroundStyle(Hub.ink).frame(width: cs.col(30), alignment: .leading)
                            Text(c.text).font(.hub(cs.aux)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: 6) {
                        TextField(me.isEmpty ? "먼저 위에서 이니셜을 고르세요" : "\(me) 로 댓글 남기기", text: Binding(get: { draft[p.id] ?? "" }, set: { draft[p.id] = $0 }))
                            .textFieldStyle(.roundedBorder).font(.hub(cs.aux))
                            .onSubmit { send(p) }
                        Button("남기기") { send(p) }.disabled((draft[p.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty || me.isEmpty)
                    }
                    HStack { Spacer(); Button("이니셜 바꾸기 (\(me.isEmpty ? "없음" : me))") { askWho = true }.buttonStyle(.plain).font(.hub(cs.tag)).foregroundStyle(Hub.text3) }
                }
                .padding(.leading, cs.col(30))
            }
        }
        .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV + 2)
        .contentShape(Rectangle())
        .onHover { h in if h { hoverRow = p.id } else if hoverRow == p.id { hoverRow = nil } }
    }

    /// 쉴 때 반응 줄 — 내 반응 칩(누르면 취소) · 남의 수(작게) · 댓글 n. 아무것도 없으면 빈 줄(높이는 호버 줄이 잡는다)
    private func restLine(_ p: PaperRec, _ chips: [PaperReact.Chip]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, c in
                switch c {
                case .mine(let e):
                    Button { react(p, e, already: true) } label: {
                        Text(e).font(.hub(cs.aux))
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Hub.ink.opacity(0.16)))
                            .foregroundStyle(Hub.text)
                    }
                    .buttonStyle(.plain).help("내 반응 \(e) · 다시 누르면 취소")
                case .counts(let t):
                    Text(t).font(.hub(cs.tag)).foregroundStyle(Hub.text2).lineLimit(1).fixedSize().monospacedDigit()
                case .notes(let n):
                    Button { openComments = p.id } label: {
                        Text("댓글 \(n)").font(.hub(cs.tag)).foregroundStyle(Hub.text2).lineLimit(1).fixedSize()
                    }
                    .buttonStyle(.plain).help("댓글 보기·남기기")
                default: EmptyView()
                }
            }
            if chips.isEmpty { Text(" ").font(.hub(cs.tag)) }
        }
    }

    /// 호버 반응 줄 — 반응 3개(라벨) + 댓글 단추. 폭이 모자라면(1.6배) 라벨을 빼고 이모지 + 수만 — 한 줄 고정
    private func hoverLine(_ p: PaperRec, reactions: [PaperComment], notes: [PaperComment]) -> some View {
        ViewThatFits(in: .horizontal) {
            hoverChips(p, reactions: reactions, notes: notes, labels: true)
            hoverChips(p, reactions: reactions, notes: notes, labels: false)
        }
    }

    private func hoverChips(_ p: PaperRec, reactions: [PaperComment], notes: [PaperComment], labels: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(HubPrefs.reactionEmojis, id: \.self) { e in
                let who = reactions.filter { $0.text == e }.map(\.who)
                let mine = !me.isEmpty && who.contains(me)
                Button { react(p, e, already: mine) } label: {
                    HStack(spacing: 3) {
                        Text(e).font(.hub(cs.aux))
                        if labels { Text(HubPrefs.reactionLabels[e] ?? "").font(.hub(cs.tag, weight: .medium)) }
                        if !who.isEmpty { Text("\(who.count)").font(.hub(cs.tag, weight: .semibold, design: .rounded)).monospacedDigit() }
                    }
                    .lineLimit(1).fixedSize()   // '관심없음' 이 큰 글자에서 꺾이지 않게 (검증 1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(mine ? Hub.ink.opacity(0.16) : (who.isEmpty ? Color.clear : Hub.fillNeutral)))
                    .overlay(Capsule().stroke(who.isEmpty ? Hub.divider : Color.clear))
                    .foregroundStyle(Hub.text)
                    .opacity(who.isEmpty ? 0.6 : 1)
                }
                .buttonStyle(.plain)
                .help(who.isEmpty ? "\(e) \(HubPrefs.reactionLabels[e] ?? "") 남기기" : "\(e) " + who.joined(separator: " · ") + (mine ? " · 다시 누르면 취소" : ""))
            }
            Button { openComments = openComments == p.id ? nil : p.id } label: {
                HStack(spacing: 3) { Image(systemName: "bubble.left"); Text(notes.isEmpty ? "댓글" : "\(notes.count)").lineLimit(1).fixedSize() }
                    .font(.hub(cs.aux, weight: .medium)).foregroundStyle(Hub.text2)
                    .lineLimit(1).fixedSize()
                    .padding(.leading, 4)
            }
            .buttonStyle(.plain).help("댓글 보기·남기기")
        }
        .fixedSize()
    }

    /// 보기를 바꾸면 열린 댓글 칸을 닫는다 (0.39.0 C0 — 안 보이는 행의 칸이 열1 보류를 잡고 있지 않게)
    private func setFilter(_ v: String) {
        filter = v; HubPrefs.paperFilter = v
        openComments = nil
    }

    /// '같이 읽자' 단추 + 제안자 + 모임 후보 칩 (0.39.0 C5, 연구 탭만). 대기 중(6초)은 시계 표시 — 되돌리기는 연구 탭 오른쪽 칸 아래 줄
    private struct TalkControls: View {
        @ObservedObject var model: NotionHubModel
        @ObservedObject var commits: DelayedCommit
        let paper: PaperRec
        let proposers: [String]
        let me: String
        let needWho: () -> Void
        @Environment(\.cardStyle) private var cs
        var body: some View {
            let mine = !me.isEmpty && proposers.contains(me.uppercased())
            let pending = commits.isPending(NotionHubModel.talkID(paper))
            Button {
                guard !me.isEmpty, HubPrefs.meChosen else { needWho(); return }
                model.toggleTalk(paper)
            } label: {
                HStack(spacing: 3) {
                    if pending { Image(systemName: "clock").font(.hub(cs.tag - 1)) }
                    Text(HubPrefs.talkText).font(.hub(cs.tag, weight: .medium))
                }
                .lineLimit(1).fixedSize()
                .foregroundStyle(Hub.text2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .overlay(Capsule().stroke(mine ? Hub.ink : Hub.divider, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("6초 뒤 Notion 댓글로 남습니다(지울 수 없음) — 그 안에 되돌리기 · 이니셜은 자기 신고" + (mine ? " · 다시 누르면 취소" : ""))
            if !proposers.isEmpty {
                Text("· " + proposers.joined(separator: "·")).font(.hub(cs.tag)).foregroundStyle(Hub.text2).lineLimit(1).fixedSize()
            }
            if proposers.count >= PaperComment.meetupMin {
                Text("모임 후보").font(.hub(cs.tag, weight: .medium)).foregroundStyle(Hub.text2).lineLimit(1).fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Hub.fillNeutral))
                    .help("같이 읽자 \(proposers.count)명 — 계산만, 알림 없음")
            }
        }
    }

    private func react(_ p: PaperRec, _ e: String, already: Bool) {
        guard !me.isEmpty, HubPrefs.meChosen else { askWho = true; return }
        // 다시 누르면 취소 — Notion 댓글은 지울 수 없어 취소 댓글을 남기고 settle() 이 둘 다 뺀다
        Task { await model.addPaperComment(page: p.id, text: "[\(me)] " + (already ? HubPrefs.cancelMark + e : e)) }
    }
    private func send(_ p: PaperRec) {
        let t = (draft[p.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        guard !me.isEmpty, HubPrefs.meChosen else { askWho = true; return }
        draft[p.id] = ""
        Task { await model.addPaperComment(page: p.id, text: "[\(me)] \(t)") }
    }
}

/// 최신 원고 — OpenAlex(지정 저자의 최근 프리프린트·논문). Publications Stage 질의는 0.40.0 C1(F0-3)에서 뺌(늘 0행)
struct LatestManuscripts: View {
    @ObservedObject var model: NotionHubModel
    /// 랩 허브만 — 30일 안 2편, 나머지는 '▸ 더 보기' (0.37.0 C2). 열 바닥이 비면 다음 원고를 더 (HubFill, 0.38.0 C3)
    var nearOnly = false
    @Environment(\.cardStyle) private var cs
    @ObservedObject private var expansion = HubExpansion.shared
    @ObservedObject private var fill = HubFill.shared
    var body: some View {
        VStack(alignment: .leading, spacing: cs.gap) {
            SectionTitle(card: "preprints", hint: "저자: " + model.cfg.manuscriptAuthors.keys.sorted().joined(separator: "·") + " (OpenAlex)", trailing: "Publications",
                         fresh: nearOnly ? model.cardTag("preprints") : nil) { model.openInApp(id: model.cfg.publicationsDB) }
            VStack(spacing: 0) {
                let cut = nearOnly ? HubNear.preprints(model) : nil
                let open = expansion.isOpen("preprints"), e = fill.extra["preprints"] ?? 0
                let rows = cut.map { $0.shown(open: open, extra: e) } ?? Array(model.preprints.prefix(4))
                if rows.isEmpty {
                    Text(model.preprintsLoading ? "OpenAlex 에서 찾는 중…" : "없음").font(.hub(cs.body)).foregroundStyle(Hub.text2)
                        .padding(cs.empty).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                    Button { if let u = r.url { NSWorkspace.shared.open(u) } } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(r.type == "preprint" ? "Preprint" : "논문").font(.hub(cs.tag, weight: .bold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill((r.type == "preprint" ? Hub.ink : Hub.ok).opacity(0.12)))
                                .foregroundStyle(r.type == "preprint" ? Hub.ink : Hub.ok)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.title).font(.hub(cs.body, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                Text([r.venue, r.date.map(Hub.day) ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")).font(.hub(cs.aux)).foregroundStyle(Hub.text2).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Text(r.initials.joined(separator: "·")).font(.hub(cs.tag, weight: .bold, design: .rounded)).foregroundStyle(Hub.ink)
                        }
                        .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help(r.url?.absoluteString ?? r.title)
                    if i < rows.count - 1 { RowDivider() }
                }
                if let cut { CardFooter(caption: CardMetas.caption("preprints", model), toggleKey: "preprints", more: cut.toggleCount(open: open, extra: e)) }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// 허브 가운데 세 열의 빈 면 측정 (R-J1, 0.36.0) — 열마다 (내용 높이, 보이는 높이)를 GeometryReader 배경으로 적고,
/// --snapshot 이 windows.txt 에 'hub-cols: 1 빈 Npt · 2 빈 Npt|스크롤 +Npt · 3 빈 Npt|스크롤 +Npt' 로 쓴다(빈 = max(0, 보이는 − 내용)). 허브가 안 보이면 '—'
/// 0.38.0 C3: 값마다 적은 Dashboard(소유자 토큰, 환경 hubProbeOwner)를 함께 둔다 — 글자 배율을 바꾸면 창 본문이 다시 만들어지는데,
/// 옛 Dashboard 의 onDisappear 가 새 Dashboard 가 이미 적은 값까지 지워 1.3배 hub-cols 가 '—' 였다. 이제 clear(owner:) 는 제가 적은 값만 지운다.
/// 기록할 때마다 HubFill.measured 로 채움 결정을 깨운다
@MainActor
enum HubLayoutProbe {
    enum Part { case content, visible }
    private static var content: [String: (h: CGFloat, owner: UUID?)] = [:]
    private static var visible: [String: (h: CGFloat, owner: UUID?)] = [:]
    static func record(_ key: String, _ part: Part, _ h: CGFloat, owner: UUID? = nil) {
        switch part { case .content: content[key] = (h, owner); case .visible: visible[key] = (h, owner) }
        HubFill.shared.measured(col: key, part: part)
    }
    /// 그 Dashboard 가 적은 값만 지운다 (다른 소유자가 덮어쓴 값은 그대로)
    static func clear(owner: UUID) {
        content = content.filter { $0.value.owner != owner }
        visible = visible.filter { $0.value.owner != owner }
    }
    /// 열의 (내용, 보이는) 높이 — 둘 다 있을 때만 (HubFill)
    static func value(_ key: String) -> (content: CGFloat, visible: CGFloat)? {
        guard let c = content[key]?.h, let v = visible[key]?.h else { return nil }
        return (c, v)
    }
    static var line: String {
        "hub-cols: " + ["1", "2", "3"].map { k -> String in
            guard let c = content[k]?.h, let v = visible[k]?.h else { return "\(k) —" }
            // 스크롤이면 넘친 양도 적는다(다음 라운드에 카드 이동 여유 판단용, 검증 1)
            return c > v + 0.5 ? "\(k) 스크롤 +\(Int((c - v).rounded()))pt" : "\(k) 빈 \(Int((v - c).rounded()))pt"
        }.joined(separator: " · ")
    }
}

/// ViewThatFits 가 고른 갈래 기록 (0.38.0 C2) — --snapshot 이 windows.txt 에 'choices: <키> <값> · …'(없으면 'choices: —') 로 쓴다.
/// ViewThatFits 는 고른 쪽만 그리므로 그 갈래의 onAppear 가 기록한다. 다음 조정이 그림 눈대중이 아니라 이 줄로 (계획 0.38.0 §5 ⑤)
@MainActor
enum LayoutChoice {
    private static var values: [String: String] = [:]
    static func record(_ key: String, _ value: String) { values[key] = value }
    static var line: String {
        "choices: " + (values.isEmpty ? "—" : values.keys.sorted().map { "\($0) \(values[$0] ?? "")" }.joined(separator: " · "))
    }
}

extension View {
    /// 이 갈래가 그려지면 LayoutChoice 에 기록 — key 가 nil 이면 아무것도 안 한다
    func layoutChoice(_ key: String?, _ value: String) -> some View {
        background(Color.clear.onAppear { if let key { MainActor.assumeIsolated { LayoutChoice.record(key, value) } } })
    }

    /// 높이 측정 배경 (HubLayoutProbe) — key 가 nil 이면 아무것도 안 한다. 소유자는 환경 hubProbeOwner (Dashboard)
    func hubProbe(_ key: String?, _ part: HubLayoutProbe.Part) -> some View {
        modifier(HubProbeModifier(key: key, part: part))
    }
}

/// HubLayoutProbe 소유자 토큰 — Dashboard 가 환경으로 내려 준다 (0.38.0 C3)
private struct HubProbeOwnerKey: EnvironmentKey { static let defaultValue: UUID? = nil }
extension EnvironmentValues {
    var hubProbeOwner: UUID? {
        get { self[HubProbeOwnerKey.self] }
        set { self[HubProbeOwnerKey.self] = newValue }
    }
}

private struct HubProbeModifier: ViewModifier {
    let key: String?
    let part: HubLayoutProbe.Part
    @Environment(\.hubProbeOwner) private var owner
    func body(content: Content) -> some View {
        content.background(GeometryReader { g in
            Color.clear
                .onAppear { if let key { let h = g.size.height; MainActor.assumeIsolated { HubLayoutProbe.record(key, part, h, owner: owner) } } }
                .onChange(of: g.size.height) { _, h in if let key { MainActor.assumeIsolated { HubLayoutProbe.record(key, part, h, owner: owner) } } }
        })
    }
}

/// 지난 Paper Blitz — 아래 작은 칸: "이름 · 제목" 한 줄씩
/// 덱 파일(NAS GRM/<yyyy>/<yyyymmdd>/PB_yymmdd.pdf, 없으면 pptx)은 카드 머리 칩 — 여섯 사용처 모두 같은 규칙 (R-J1, 0.36.0)
/// fill=false 면 안쪽 스크롤 없이 내용 높이·배경도 내용에 붙는다(허브 열3). 다른 뷰는 기본 true(열 끝까지)
struct BlitzCompact: View {
    @ObservedObject var model: NotionHubModel
    var fill: Bool = true
    /// 랩 허브만 — 최신 회차 첫 3편(내 발표 먼저), 나머지는 '▸ 더 보기' (0.37.0 C2). 열 바닥이 비면 다음 편을 더 (HubFill, 0.38.0 C3)
    var nearOnly = false
    @Environment(\.cardStyle) private var cs
    /// 허브 카드 접기 (0.44.0 #70, 검증 1 리뷰) — SectionTitle 을 안 쓰므로 같은 화살표·제목 클릭을 여기서도
    @Environment(\.cardFold) private var fold
    @ObservedObject private var expansion = HubExpansion.shared
    @ObservedObject private var hubFill = HubFill.shared

    var body: some View {
        VStack(alignment: .leading, spacing: cs.gap) {
            header
            if fill {
                ScrollView(.vertical, showsIndicators: false) { list }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
            } else {
                VStack(spacing: 0) {
                    list
                    if nearOnly { CardFooter(caption: CardMetas.caption("blitz", model), toggleKey: "blitz", more: HubNear.blitz(model, me: HubPrefs.me).toggleCount(open: expansion.isOpen("blitz"), extra: hubFill.extra["blitz"] ?? 0)) }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .top)
    }

    /// 머리 — 제목 · (덱 칩) · (Archive ↗, Notion 출처일 때)
    /// 검증 1: 칩에 layoutPriority(-1) 를 주면 SectionTitle 안 Spacer 가 남는 폭을 다 가져가 칩이 아이콘만 남았다(어느 폭에서나 30pt).
    /// 제목은 SectionTitle 과 같은 글자(12 semibold text2 · 신선도 표)지만 Spacer 없이 제 폭으로 고정, 칩이 그 옆 남는 폭을 받고(좁으면 가운데 말줄임),
    /// Archive 는 오른쪽 끝. 허브 열3(약 422pt)에서 'PB_261014.pptx' 전체가 보인다(제목 206 + 칩 125 + Archive 58 + 간격 16, 오프라인 측정)
    /// 리뷰 low 2-a (0.37.0): 제목 묶음의 .fixedSize() 가 카드 최소 폭을 317pt 로 묶었다 → ViewThatFits 로 한 줄(제목·칩·Archive)이
    /// 들어가면 한 줄, 아니면 두 줄(제목 + Archive / 덱 칩). 큰 글자(허브)에서도 칩 파일명이 잘리지 않는다
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                headerTitle
                if let deck = model.blitzDeckPath { deckChip(deck) }
                Spacer(minLength: 0)
                archiveLink
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) { headerTitle; Spacer(minLength: 0); archiveLink }
                if let deck = model.blitzDeckPath { deckChip(deck) }
            }
        }
    }

    private var headerTitle: some View {
        HStack(spacing: 6) {
            if let fold {
                Image(systemName: "chevron.down").font(.hub(max(9, cs.aux - 3), weight: .bold)).foregroundStyle(Hub.text3).frame(width: 12)
                    .contentShape(Rectangle()).onTapGesture(perform: fold).help("접기 — 한 줄로 (이 맥에 기억)")
            }
            Text(HubCardTitle.title("blitz"))
                .font(.hub(cs.title, weight: .bold)).foregroundStyle(Hub.text).tracking(0.2).lineLimit(1)   // SectionTitle 과 같은 글자 (0.44.0 B2, #71)
                .help("지난 Paper Blitz" + (model.blitzDate.map { " · " + Hub.day($0) } ?? "") + (fold == nil ? "" : " — 제목을 누르면 접기 (이 맥에 기억)"))
                .modifier(FoldTap(fold: fold))
            if let f = model.blitzFreshness { FreshnessTag(f: f) }
        }
    }

    private func deckChip(_ deck: String) -> some View {
        Button { NSWorkspace.shared.open(URL(fileURLWithPath: deck)) } label: {
            HStack(spacing: 4) {
                Image(systemName: deck.hasSuffix(".pdf") ? "doc.richtext" : "rectangle.on.rectangle").font(.hub(cs.tag - 1))
                Text((deck as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
            }
            .font(.hub(cs.aux, weight: .medium)).foregroundStyle(Hub.ink)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Hub.fillNeutral))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(deck + " — NAS 덱 열기")
    }

    @ViewBuilder private var archiveLink: some View {
        if model.blitzSource == "Notion" {
            Button { model.openInApp(id: model.paperBlitzDB) } label: {
                HStack(spacing: 3) { Text("Archive"); Image(systemName: "arrow.up.forward") }.font(.hub(cs.aux, weight: .medium)).fixedSize()
            }
            .buttonStyle(.plain).foregroundStyle(Hub.text2)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: cs.rowV) {
            if model.blitz.isEmpty {
                Text(model.blitzLoading ? "불러오는 중…" : "없음").font(.hub(cs.aux)).foregroundStyle(Hub.text2)
            }
            let papers = nearOnly ? HubNear.blitz(model, me: HubPrefs.me).shown(open: expansion.isOpen("blitz"), extra: hubFill.extra["blitz"] ?? 0) : model.blitz
            ForEach(papers) { p in
                Button {
                    if let n = p.notionID, model.blitzSource == "Notion" { model.openInApp(id: n) } else if let d = p.doi { NSWorkspace.shared.open(d) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(model.member(initials: p.presenter)?.name ?? p.presenter).font(.hub(cs.aux, weight: .semibold)).frame(width: cs.col(46), alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.title).font(.hub(cs.body, weight: .medium)).lineLimit(1)
                            // '성, 연도, 저널' — 확신이 없으면 원문 한 줄(꼬리 잘림, 툴팁 원문) (R-30)
                            let cite = Hub.citationLine(p).text
                            if !cite.isEmpty { Text(cite).font(.hub(cs.aux)).foregroundStyle(Hub.text3).lineLimit(1).truncationMode(.tail) }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help([p.citation, p.coreQuestion].filter { !$0.isEmpty }.joined(separator: "\n"))
            }
        }
        .padding(.horizontal, cs.rowH).padding(.vertical, cs.empty)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - 그랜트 (보고 제출 · 도전할 과제) — SSOT(NAS) Grant/_ssot/grants_schedule.json

struct GrantRow: Identifiable, Hashable {
    let id: String; let kind: String; let title: String; let agency: String; let due: Date?; let dueNote: String; let folder: String
    /// 날짜를 마지막으로 확인한 날 · 과제 종료 연월(그 달 1일) — #15
    var checkedAt: Date? = nil; var ended: Date? = nil
    /// 일정 미정이고 마지막 확인이 staleDays 넘게 지났거나 기록이 없음
    func needsCheck(today: Date, staleDays: Int = 14) -> Bool {
        guard due == nil else { return false }
        guard let c = checkedAt else { return true }
        return (Calendar.current.dateComponents([.day], from: c, to: today).day ?? 0) > staleDays
    }
    /// 과제가 끝났으면 '결과보고' 단계
    func isEnded(today: Date) -> Bool { ended.map { Calendar.current.date(byAdding: .month, value: 1, to: $0)! <= today } ?? false }
}

enum GrantsFile {
    static func load(_ path: String) -> [GrantRow] {
        guard let d = FileManager.default.contents(atPath: path),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let items = o["items"] as? [[String: Any]] else { return [] }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let rows = items.enumerated().filter { !(($0.element["hidden"] as? Bool) ?? false) }.map { i, x in
            GrantRow(id: "g\(i)", kind: x["kind"] as? String ?? "", title: x["title"] as? String ?? "", agency: x["agency"] as? String ?? "",
                     due: (x["due"] as? String).flatMap { f.date(from: $0) }, dueNote: x["dueNote"] as? String ?? "", folder: x["folder"] as? String ?? "",
                     checkedAt: (x["checkedAt"] as? String).flatMap { f.date(from: $0) },
                     ended: (x["ended"] as? String).flatMap { f.date(from: $0 + "-01") })
        }
        let today = Calendar.current.startOfDay(for: HubClock.now)
        // 지난 마감은 빼고, 날짜 있는 것(가까운 순) → 날짜 미정(보고 먼저)
        return rows.filter { $0.due.map { $0 >= today } ?? true }
            .sorted { a, b in
                switch (a.due, b.due) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.kind == "보고" && b.kind != "보고"
                }
            }
    }
}

struct GrantsSection: View {
    @ObservedObject var model: NotionHubModel
    /// 관제탑 레일: 적색 대신 ink — 같은 마감이 경보 열에 이미 적색으로 있으므로 (검증 1, 화면당 적색 ≤3)
    var quiet = false
    /// 랩 허브만 — 마감 D≤7 만, 나머지(D>7·미정·'확인 필요')는 '▸ 더 보기' (0.37.0 C2). 열 바닥이 비면 다음 그랜트를 더 — 날짜 있는 것 먼저, 미정은 무채색 (HubFill, 0.38.0 C3)
    var nearOnly = false
    @Environment(\.cardStyle) private var cs
    @ObservedObject private var expansion = HubExpansion.shared
    @ObservedObject private var fill = HubFill.shared
    var body: some View {
        VStack(alignment: .leading, spacing: cs.gap) {
            SectionTitle(card: "grants", trailing: "NAS", fresh: nearOnly ? model.cardTag("grants") : nil) {
                NSWorkspace.shared.open(URL(fileURLWithPath: (model.cfg.grantsFile as NSString).deletingLastPathComponent))
            }
            VStack(spacing: 0) {
                if model.grants.isEmpty {
                    Text(FileManager.default.fileExists(atPath: model.cfg.grantsFile) ? "없음" : "NAS 의 Grant/_ssot/grants_schedule.json 을 읽지 못함")
                        .font(.hub(cs.body)).foregroundStyle(Hub.text2).padding(cs.empty).frame(maxWidth: .infinity, alignment: .leading)
                }
                let cut = nearOnly ? HubNear.grants(model) : nil
                let open = expansion.isOpen("grants"), e = fill.extra["grants"] ?? 0
                let rows = cut.map { $0.shown(open: open, extra: e) } ?? model.grants
                // 채움(HubFill)으로 보인 행 — 접힘 기준 밖이라 '확인 필요' 를 적색 없이 (검증 1: 미정 그랜트도 채움 후보로, 적색 예산은 그대로)
                let nearIDs = Set(cut?.near.map(\.id) ?? [])
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, g in
                    let filled = cut != nil && !open && !nearIDs.contains(g.id)
                    Button {
                        let p = model.cfg.nasGRMRoot.replacingOccurrences(of: "/GRM", with: "") + "/" + g.folder
                        if FileManager.default.fileExists(atPath: p) { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            // 적색은 마감 D≤3 만 (0.35.0 — lint 규칙과 같게). 관제탑 레일(quiet)은 ink — 경보 열이 적색을 맡는다
                            let soon = g.due.map { (Calendar.current.dateComponents([.day], from: model.today, to: $0).day ?? 99) <= 3 } ?? false
                            Text(g.due.map(Hub.dday) ?? "미정").font(.hub(cs.tag, weight: .bold, design: .rounded)).monospacedDigit()
                                .frame(width: cs.col(40), alignment: .leading).foregroundStyle(soon ? (quiet ? Hub.ink : Hub.signal) : Hub.text2)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    let kind = g.isEnded(today: model.today) ? "결과보고" : g.kind
                                    Text(kind).font(.hub(cs.tag - 0.5, weight: .bold))
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill((g.kind == "보고" ? Hub.ink : Hub.ok).opacity(0.12)))
                                        .foregroundStyle(g.kind == "보고" ? Hub.ink : Hub.ok)
                                    Text(g.title).font(.hub(cs.body, weight: .semibold)).lineLimit(1)
                                }
                                Text([g.due.map(Hub.day) ?? "", g.dueNote].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.hub(cs.aux)).foregroundStyle(Hub.text2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                // 일정 미정 항목은 마지막 확인일을 보이고, 14일 넘으면 적색 '확인 필요' (#15, 주간 파이프라인 grants 단계도 로그에 남김)
                                if g.due == nil {
                                    let stale = g.needsCheck(today: model.today)
                                    // 채움 행은 무채색(Hub.text2) — 같은 행을 '▸ 더 보기' 로 펼치면 지금처럼 적색
                                    Text(stale ? "확인 필요 · 마지막 확인 " + (g.checkedAt.map(Hub.day) ?? "기록 없음") : "마지막 확인 " + (g.checkedAt.map(Hub.day) ?? ""))
                                        .font(.hub(cs.tag, weight: stale && !filled ? .semibold : .regular))
                                        .foregroundStyle(stale ? (filled ? Hub.text2 : (quiet ? Hub.ink : Hub.signal)) : Hub.text3)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help([g.agency, g.folder].filter { !$0.isEmpty }.joined(separator: " · "))
                    if i < rows.count - 1 { RowDivider() }
                }
                if let cut { CardFooter(caption: CardMetas.caption("grants", model), toggleKey: "grants", more: cut.toggleCount(open: open, extra: e)) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - 다가오는 학회 (NAS Grant/_ssot/conferences_upcoming.json — scripts/import_conferences.py, JYK 제공 #7)
enum ConferencesFile {
    /// 파일의 generated 날짜(앞 10자 yyyy-MM-dd) — 학회 카드 꼬리표 (0.40.0 C3, A2-src-ssot_conferences)
    static func generated(_ path: String) -> Date? {
        guard let d = FileManager.default.contents(atPath: path), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return MetricsSnapshot.day(o["generated"] ?? o["updated"])
    }
    static func load(_ path: String) -> [ConferenceRow] {
        guard let d = FileManager.default.contents(atPath: path),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let rows = o["conferences"] as? [[String: Any]] else { return [] }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let link = (o["source"] as? String).flatMap(URL.init(string:))
        return rows.compactMap { r in
            guard let s = (r["start"] as? String).flatMap(f.date(from:)) else { return nil }
            let cat = r["category"] as? String ?? ""
            return ConferenceRow(id: "file-" + (r["id"] as? String ?? UUID().uuidString), title: "", conference: r["name"] as? String ?? "",
                                 start: s, end: (r["end"] as? String).flatMap(f.date(from:)), location: r["place"] as? String ?? "",
                                 format: cat == "국제" ? "" : cat, authors: "", international: cat == "국제",
                                 deadline: (r["deadline"] as? String).flatMap(f.date(from:)), deadlineLabel: r["deadlineLabel"] as? String ?? "",
                                 heldLabel: r["heldLabel"] as? String ?? "", link: link)
        }
    }
}

/// 지금 · 다음 판정 (0.44.0 B1, #58) — 오늘 캘린더(CSNL·SLab) 일정 + 오늘 내 수업(Timetable). 같은 수업(시간 겹침 + 이름 포함, 4자 이상)은 Timetable 하나.
/// NowNextLine(허브·팝오버·앰비언트)·text.txt [Timetable] '지금·다음 후보'·text-check nownext 가 같은 함수
enum NowNext {
    static let classSource = "Timetable"
    struct Slot: Hashable {
        let title: String, start: Date, end: Date, source: String
        var isClass: Bool { source == NowNext.classSource }
    }
    /// now = 진행 중 첫 슬롯, next = 지금 뒤 시작하는 첫 슬롯, rest = 오늘 남은 전부(시작·끝 순)
    struct Pick { var now: Slot?; var next: Slot?; var rest: [Slot] }

    /// 오늘(같은 날) 시각 있는 캘린더 일정 → 슬롯. 출처는 캘린더 이름에 slab 이 있으면 SLab, 아니면 CSNL (Upcoming 과 같음)
    static func eventSlots(_ events: [CalEvent], now: Date) -> [Slot] {
        events.filter { !$0.isAllDay && Calendar.current.isDate($0.start, inSameDayAs: now) }.map {
            Slot(title: Hub.canonicalNames($0.title), start: $0.start, end: $0.end,
                 source: $0.calendarName.localizedCaseInsensitiveContains("slab") ? "SLab" : "CSNL")
        }
    }
    /// 오늘 내 수업 → 슬롯 — Timetable.todayGroups(휴일·학기 밖이면 없음) 중 이 맥 이니셜(별칭 풂)이 든 덩어리, 오늘 날짜(KST) 시각으로
    static func classSlots(_ feed: TimetableFeed?, me: String, now: Date) -> [Slot] {
        guard let feed else { return [] }
        let key = Timetable.meKey(me, aliases: feed.aliases)
        guard !key.isEmpty else { return [] }
        let day = Timetable.kst.startOfDay(for: now)
        return Timetable.todayGroups(feed.rows, now: now).filter { $0.mine(key) }.map {
            Slot(title: $0.course, start: at($0.start, day: day), end: at($0.end, day: day), source: classSource)
        }
    }
    static func at(_ hm: String, day: Date) -> Date { day.addingTimeInterval(TimeInterval(Timetable.minutes(hm) * 60)) }
    /// 순수 — 같은 수업이면 캘린더 쪽을 버리고, 남은 것 중 지금·다음
    static func pick(events: [Slot], classes: [Slot], now: Date) -> Pick {
        let kept = events.filter { e in !classes.contains { c in c.start < e.end && e.start < c.end && Timetable.sameCourse(e.title, c.title) } }
        let rest = Array((kept + classes).enumerated().filter { $0.element.end > now }.sorted { a, b in
            (a.element.start, a.element.end, a.offset) < (b.element.start, b.element.end, b.offset)
        }.map(\.element))
        return Pick(now: rest.first { $0.start <= now }, next: rest.first { $0.start > now }, rest: rest)
    }
    /// 'HH:mm–HH:mm 제목 (출처)'
    static func text(_ s: Slot) -> String { "\(Timetable.hm(s.start))–\(Timetable.hm(s.end)) \(s.title) (\(s.source))" }
    /// text-check nownext — 'now=yyyy-MM-ddTHH:mm;cal=HH:mm-HH:mm/제목|…;cls=HH:mm-HH:mm/과목|…' → '지금 <…|—> · 다음 <…|—>' (fixtures/schedule-check.tsv)
    static func check(_ input: String) -> String {
        var k: [String: String] = [:]
        for part in input.components(separatedBy: ";") {
            let p = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if p.count == 2 { k[p[0].trimmingCharacters(in: .whitespaces)] = p[1] }
        }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = Timetable.kst.timeZone; f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        guard let now = f.date(from: k["now"] ?? "") else { return "(입력 형식)" }
        let day = Timetable.kst.startOfDay(for: now)
        func slots(_ s: String, source: String) -> [Slot]? {
            var out: [Slot] = []
            for item in s.components(separatedBy: "|") where !item.isEmpty {
                let p = item.split(separator: "/", maxSplits: 1).map(String.init)
                let t = p.first?.components(separatedBy: "-") ?? []
                guard p.count == 2, t.count == 2 else { return nil }
                out.append(Slot(title: p[1], start: at(t[0], day: day), end: at(t[1], day: day), source: source))
            }
            return out
        }
        guard let ev = slots(k["cal"] ?? "", source: "CSNL"), let cl = slots(k["cls"] ?? "", source: classSource) else { return "(입력 형식)" }
        let p = pick(events: ev, classes: cl, now: now)
        return "지금 \(p.now.map(text) ?? "—") · 다음 \(p.next.map(text) ?? "—")"
    }
}

/// 다음 GRM 칸 아래 — 오늘 캘린더(CSNL·SLab)의 지금 · 다음 일정 한 줄씩 (오늘 일정 카드 ①안) + 오늘 내 수업(Timetable, 0.44.0 B1 #58)
struct NowNextLine: View {
    @ObservedObject var cal: CalendarModel
    @Environment(\.cardStyle) private var cs
    var body: some View {
        let now = cal.now
        let p = NowNext.pick(events: NowNext.eventSlots(cal.events, now: now), classes: NowNext.classSlots(cal.timetable, me: HubPrefs.me, now: now), now: now)
        VStack(alignment: .leading, spacing: 3) {
            if p.now == nil && p.next == nil {
                // 첫 조회 전 → 불러오는 중… / 소스 없음·거부 → 캘린더 읽지 못함 / 그 밖 → 없음 (0.37.0 C6 — 소스 없음에서 '불러오는 중'이 영원히 남던 것, 0.44.0 #71 한 단어)
                Text(!cal.isSettled ? "불러오는 중…" : (cal.status == .noSource || cal.status == .denied ? "캘린더 읽지 못함" : "없음"))
                    .font(.hub(cs.aux)).foregroundStyle(cal.isSettled ? Hub.text3 : Hub.text2)
            }
            if let c = p.now { row("지금", c, strong: true) }
            if let n = p.next { row("다음", n, strong: false) }
        }
    }
    private func row(_ tag: String, _ e: NowNext.Slot, strong: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // '지금' 은 남색 — 적색은 마감·오류에만 (0.37.0 C6)
            Text(tag).font(.hub(cs.tag - 0.5, weight: .bold)).foregroundStyle(strong ? Hub.ink : Hub.text3).frame(width: cs.col(26), alignment: .leading)
            Text(Hub.time(e.start) + "–" + Hub.time(e.end)).font(.hub(cs.aux - 0.5, design: .rounded)).monospacedDigit().foregroundStyle(Hub.text2)
            Text(e.title).font(.hub(cs.body - 1, weight: strong ? .semibold : .regular)).lineLimit(1)
            // 시간표 수업이면 출처 꼬리표 — 캘린더 일정과 구분 (0.44.0 B1, #58)
            if e.isClass { Text(NowNext.classSource).font(.hub(cs.tag - 1)).foregroundStyle(Hub.text3).fixedSize() }
        }
        .help(e.isClass ? "Timetable 의 내 수업" : "\(e.source) 캘린더 일정")
    }
}

/// 허브 '오늘' 탭 — CSNL·SLab 캘린더 오늘 하루를 크게 (BHL ②안: 기본 화면에서는 캘린더 카드를 빼고 여기서만)
struct TodayView: View {
    @ObservedObject var cal: CalendarModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(Hub.longDay(cal.now)).font(.hub(22, weight: .bold))
                Spacer()
                Text(Hub.time(cal.now)).font(.hub(18, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Hub.text2)
            }
            if !cal.allDay.isEmpty {
                Text(cal.allDay.map(\.title).joined(separator: " · ")).font(.hub(13)).foregroundStyle(Hub.text2).lineLimit(1)
            }
            GeometryReader { geo in Timeline(model: cal, size: geo.size) }
        }
        .padding(16)
    }
}

/// 연구원 한 명 — 이름(+포스터 작은 아이콘) · 프로젝트 1개 · "+N"(누르면 펼침) (#10 BHL: 필 과밀·원시 식별자)
struct MemberGroup: View {
    @ObservedObject var model: NotionHubModel
    let member: Member
    let entry: MemberLinks.Entry?
    let away: String?
    @State private var expanded = false
    @Environment(\.cardStyle) private var cs

    /// 폴더 이름 → 표시 이름: 밑줄·하이픈은 띄어쓰기, 숫자만인 토큰·updated·final·v2 같은 꼬리 제거
    static func display(_ raw: String) -> String {
        let drop: Set<String> = ["updated", "final", "new", "old", "copy"]
        let toks = raw.replacingOccurrences(of: "-", with: "_").split(separator: "_").map(String.init)
            .filter { t in !(t.allSatisfy(\.isNumber)) && !drop.contains(t.lowercased()) && !(t.lowercased().hasPrefix("v") && t.dropFirst().allSatisfy(\.isNumber) && t.count > 1) }
        let s = toks.joined(separator: " ")
        return s.isEmpty ? raw : s
    }

    var body: some View {
        let projs = entry?.projects ?? []
        let shown = expanded ? projs : Array(projs.prefix(1))
        HStack(spacing: 0) {
            // 상태 아이콘 (0.42.0 C5, R2) — 이름 앞, 없으면 빈 칸 없음
            if let st = model.status(of: member.initials) {
                MemberStatusIcon(status: st, mine: !HubPrefs.me.isEmpty && member.initials.uppercased() == HubPrefs.me.uppercased()).padding(.leading, 7)
            }
            Button { model.openInApp(id: member.id) } label: {
                Text(member.name).font(.hub(cs.aux, weight: .semibold)).lineLimit(1)
                    .padding(.leading, 8).padding(.trailing, entry?.poster == nil ? 8 : 3).padding(.vertical, 3)
                    .foregroundStyle(Hub.text).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help([member.name, member.initials].filter { !$0.isEmpty }.joined(separator: " · ") + " — Notion 에서 열기")
            if let pos = entry?.poster {
                Button { NSWorkspace.shared.open(pos.url) } label: {
                    Image(systemName: "doc.richtext").font(.hub(10.5)).foregroundStyle(Hub.text3).padding(.trailing, 7).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("최근 포스터 — \(pos.venue) \(pos.date) · \(pos.title)")
            }
            if let away {
                Text(away).font(.hub(cs.tag, weight: .medium)).foregroundStyle(Hub.text3).padding(.trailing, 8)
            }
            ForEach(shown, id: \.self) { p in
                pill(Self.display(p.name), help: "\(p.name) — NAS Memory 폴더 열기") { NSWorkspace.shared.open(URL(fileURLWithPath: p.path)) }
            }
            if projs.count > 1 {
                pill(expanded ? "접기" : "+\(projs.count - 1)", help: expanded ? "접기" : projs.dropFirst().map { Self.display($0.name) }.joined(separator: ", ")) { expanded.toggle() }
            }
            if let g = entry?.github {
                Button { NSWorkspace.shared.open(g) } label: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right").font(.hub(10)).foregroundStyle(Hub.text3).padding(.trailing, 7)
                }
                .buttonStyle(.plain).help(g.absoluteString)
            }
        }
    }

    private func pill(_ text: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.hub(cs.tag + 0.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: cs.col(130), alignment: .leading).fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Hub.card))
                .foregroundStyle(Hub.text2).contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.trailing, 4).help(help)
    }
}
