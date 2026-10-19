import SwiftUI
import AppKit

// MARK: - 리마인더 (랩장 지시 2026-10-14)
// Schedule & Events 는 일정이지 마감이 아니다. 리마인더가 필요한 것(○○ 제출, 누군가의 방문 등)은
// 제안 → 사람이 컨펌한 것만 등록한다.
// 저장: NAS Grant/_ssot/reminders.json  {"items": [{id, title, date(yyyy-MM-dd), kind, source, status, by, at}]}
//   status: proposed(제안 — Claude·사람이 파일에 넣은 것) · confirmed(등록) · done(끝남) · dismissed(아님)
// 제안은 두 곳에서: 파일의 proposed 항목 + Schedule & Events 중 제목에 제출·방문 같은 말이 있는 다가오는 일정(파일에 아직 없는 것)

struct ReminderItem: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var date: String
    var kind: String
    var source: String
    var status: String
    var by: String?
    var at: String?

    var day: Date? { RemindersFile.dayFormatter.date(from: String(date.prefix(10))) }
}

enum RemindersFile {
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    enum LoadResult { case missing, corrupt(String), ok([ReminderItem]) }

    /// 항목 단위로 관대하게 읽는다 — 한 항목이 깨져도 나머지는 살린다. 파일 자체가 JSON 이 아니면 corrupt (조사 P1-⑧)
    static func load(_ path: String) -> LoadResult {
        guard let d = FileManager.default.contents(atPath: path) else { return .missing }
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let raw = o["items"] as? [[String: Any]] else {
            return .corrupt("reminders.json 을 읽지 못함 — 손상됐거나 형식이 다름")
        }
        let items = raw.compactMap { r -> ReminderItem? in
            guard let data = try? JSONSerialization.data(withJSONObject: r) else { return nil }
            return try? JSONDecoder().decode(ReminderItem.self, from: data)
        }
        return .ok(items)
    }

    /// 끝남·등록·아님이 고치는 키 (upsert 기본값)
    static let statusFields: Set<String> = ["status", "by", "at"]
    /// 미루기가 고치는 키 — status 는 그대로 둔다 (UX mobile-productivity-11)
    static let snoozeFields: Set<String> = ["date", "by", "at"]

    /// 항목 하나만 바꿔 쓴다: 저장 직전에 파일을 다시 읽고 그 id 의 fields(기본 status·by·at)만 고치거나 새로 붙인다.
    /// 다른 맥이 그사이 바꾼 항목·모르는 키는 그대로 둔다. 쓰기 전에 .bak 하나를 남긴다. 파일이 깨져 있으면 쓰지 않는다
    @discardableResult
    static func upsert(_ item: ReminderItem, to path: String, fields: Set<String> = RemindersFile.statusFields) -> Bool {
        let fm = FileManager.default
        var root: [String: Any] = ["items": []]
        if let d = fm.contents(atPath: path) {
            guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], o["items"] is [[String: Any]] else { return false }
            root = o
            try? d.write(to: URL(fileURLWithPath: path + ".bak"), options: .atomic)
        }
        var items = root["items"] as? [[String: Any]] ?? []
        guard let enc = try? JSONEncoder().encode(item), let mine = try? JSONSerialization.jsonObject(with: enc) as? [String: Any] else { return false }
        if let i = items.firstIndex(where: { ($0["id"] as? String) == item.id }) {
            items[i].merge(mine.filter { fields.contains($0.key) }) { _, n in n }
        } else {
            items.append(mine)
        }
        root["items"] = items
        let f = ISO8601DateFormatter(); f.timeZone = .current; f.formatOptions = [.withInternetDateTime]
        root["updated"] = f.string(from: Date())
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return false }
        return (try? out.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }

    /// 제목으로 리마인더 후보인지 본다. 아니면 nil
    static func kind(forTitle t: String) -> String? {
        let s = t.lowercased()
        let table: [(String, [String])] = [
            ("제출", ["제출", "마감", "접수", "신청", "submit", "submission", "deadline", "due"]),
            ("방문", ["방문", "내방", "visit", "손님", "오심", "오시는"]),
            ("심사", ["심사", "디펜스", "defense", "면접", "interview", "인터뷰"]),
            ("보고", ["보고서", "평가", "report"]),
        ]
        for (k, words) in table where words.contains(where: { s.contains($0) }) { return k }
        return nil
    }
}

/// 가운데 열 맨 위 — 컨펌한 리마인더 + 제안(등록/아님)
struct RemindersSection: View {
    @ObservedObject var model: NotionHubModel
    /// 끝남·아님은 6초 미뤄 두고 되돌릴 수 있게 (D1)
    @ObservedObject private var commits: DelayedCommit
    @Environment(\.cardStyle) private var cs
    /// 랩 허브만 — 확정 D≤7(지난 것 포함)·제안 D≤7 2개, 나머지는 '▸ 더 보기' (0.37.0 C2)
    let nearOnly: Bool
    /// 마감 D≤3 을 적색 대신 Hub.ink 굵게 — 허브는 상태 한 줄 '확정 n' 한 칸이 적색을 맡는다 (0.40.0 C4, 결정 D-b)
    let quiet: Bool
    @ObservedObject private var expansion = HubExpansion.shared
    /// 열 바닥이 비면 다음 리마인더를 더 (HubFill, 0.38.0 C3)
    @ObservedObject private var fill = HubFill.shared
    init(model: NotionHubModel, nearOnly: Bool = false, quiet: Bool = false) {
        self.model = model; self.nearOnly = nearOnly; self.quiet = quiet
        _commits = ObservedObject(wrappedValue: model.reminderCommits)
    }

    private func finish(_ r: ReminderItem) {
        commits.schedule(id: r.id, label: "\(r.title) · 끝남") { model.setReminder(r, status: "done") }
    }
    private func openSource(_ r: ReminderItem) {
        if r.source.hasPrefix("notion:") { model.openInApp(id: String(r.source.dropFirst(7))) }
        else { NSWorkspace.shared.open(URL(fileURLWithPath: (model.remindersPath as NSString).deletingLastPathComponent)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: cs.gap) {
            SectionTitle(text: "리마인더 · 컨펌한 것만", trailing: "NAS", fresh: nearOnly ? model.cardTag("reminders") : nil, badge: nearOnly ? "rem-mine" : nil) {
                NSWorkspace.shared.open(URL(fileURLWithPath: (model.remindersPath as NSString).deletingLastPathComponent))
            }
            if let why = model.remindersLocked {
                Label(why + " · 등록·끝남 버튼 잠김 (.bak 확인)", systemImage: "lock.fill").font(.hub(cs.aux - 0.5)).foregroundStyle(Hub.signal)
            }
            if let f = model.reminderSaveFailed {
                HStack(spacing: 8) {
                    Label("저장 실패 · \(f.title)", systemImage: "exclamationmark.triangle").font(.hub(cs.aux - 0.5)).foregroundStyle(Hub.signal).lineLimit(1)
                    Button("다시 시도") { model.retryReminderSave(f) }.buttonStyle(.plain).font(.hub(cs.aux - 0.5, weight: .semibold)).foregroundStyle(Hub.ink)
                    Button("파일") { openSource(f) }.buttonStyle(.plain).font(.hub(cs.aux - 0.5)).foregroundStyle(Hub.text2)
                }
            }
            VStack(spacing: 0) {
                let cut = nearOnly ? HubNear.reminders(model) : nil
                let open = expansion.isOpen("reminders"), e = fill.extra["reminders"] ?? 0
                let lines = cut?.shown(open: open, extra: e)
                let rows = lines.map { $0.filter { !$0.proposal }.map(\.item) } ?? Array(model.confirmedReminders.prefix(6))
                if rows.isEmpty {
                    Text(model.loading ? "불러오는 중…" : "등록된 리마인더 없음")
                        .font(.hub(cs.body, weight: .medium)).foregroundStyle(Hub.text2)
                        .padding(cs.empty).frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                    let done = commits.isPending(r.id)
                    HStack(spacing: 8) {
                        Button { done ? commits.undo(r.id) : finish(r) } label: {
                            Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.hub(14)).foregroundStyle(done ? Hub.ok : Hub.text2)
                        }
                        .buttonStyle(.plain).help(done ? "되돌리기" : "끝남으로 표시 — 6초 안에 되돌릴 수 있음 (NAS reminders.json)")
                        let d = r.day
                        let soon = d.map { $0 <= Calendar.current.date(byAdding: .day, value: 3, to: model.today)! } ?? false
                        Text(d.map { Hub.relative($0, now: model.now, hasTime: false) } ?? "미정")
                            .font(.hub(cs.tag + 0.5, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1)
                            .frame(width: cs.col(44), alignment: .leading).foregroundStyle(soon && !done ? (quiet ? Hub.ink : Hub.signal) : Hub.text2)
                        Text(r.title).font(.hub(cs.body, weight: .medium)).lineLimit(1).strikethrough(done).foregroundStyle(done ? Hub.text3 : Hub.text)
                        Spacer()
                        if let d, (Calendar.current.dateComponents([.day], from: model.today, to: d).day ?? 0) < 14 { Text(Hub.day(d)).font(.hub(cs.aux - 0.5)).foregroundStyle(Hub.text2).monospacedDigit() }
                        TypePill(text: r.kind)
                    }
                    .padding(.horizontal, cs.rowH).padding(.vertical, cs.rowV)
                    .contentShape(Rectangle())
                    .onTapGesture { openSource(r) }
                    .rowRail([
                        RailButton(symbol: "arrow.up.forward", help: r.source.hasPrefix("notion:") ? "Notion 일정 열기" : "NAS 폴더 열기") { openSource(r) },
                        RailButton(symbol: done ? "arrow.uturn.backward" : "checkmark", help: done ? "되돌리기" : "끝남 (6초 안에 되돌리기)") { done ? commits.undo(r.id) : finish(r) },
                    ])
                    if i < rows.count - 1 { RowDivider() }
                }
                let props = lines.map { $0.filter(\.proposal).map(\.item) } ?? Array(model.reminderProposals.filter { !commits.isPending($0.id) }.prefix(4))
                if !props.isEmpty {
                    RowDivider()
                    Text("제안 · 리마인더로 등록할까요?").font(.hub(cs.tag, weight: .semibold)).foregroundStyle(Hub.text2)
                        .padding(.horizontal, cs.rowH).padding(.top, cs.rowV).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(props) { p in
                        HStack(spacing: 8) {
                            Text(p.day.map(Hub.day) ?? "미정").font(.hub(cs.aux - 0.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(Hub.text2).monospacedDigit().frame(width: cs.col(40), alignment: .leading)
                            Text(p.title).font(.hub(cs.aux + 0.5)).foregroundStyle(Hub.text2).lineLimit(1)
                            Spacer()
                            TypePill(text: p.kind)
                            Button("등록") { model.setReminder(p, status: "confirmed") }
                                .buttonStyle(.plain).font(.hub(cs.aux - 0.5, weight: .semibold)).foregroundStyle(Hub.ink)
                                .help("리마인더로 등록 — D-day 가 위 목록에 뜬다")
                            Button("아님") { commits.schedule(id: p.id, label: "\(p.title) · 리마인더 아님") { model.setReminder(p, status: "dismissed") } }
                                .buttonStyle(.plain).font(.hub(cs.aux - 0.5)).foregroundStyle(Hub.text2)
                                .help("리마인더 아님 — 다시 제안하지 않음")
                        }
                        .padding(.horizontal, cs.rowH).padding(.vertical, max(4, cs.rowV - 2))
                    }
                    .padding(.bottom, 4)
                }
                if let cut { CardFooter(caption: CardMetas.caption("reminders", model), toggleKey: "reminders", more: cut.toggleCount(open: open, extra: e)) }
                // 되돌리기 바는 카드 끝 제 줄에 — 겹치면 '▸ 더 보기'·마지막 행과 포개진다 (검증 1). 6초 동안만 한 줄 늘어남
                if !commits.pending.isEmpty { UndoToast(commits: commits).padding(6) }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
        }
    }
}
