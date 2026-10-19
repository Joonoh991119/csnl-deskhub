import SwiftUI

// MARK: - Apps Script 웹앱 (JYK 제공 2026-10-13) — GRM 안내·청소 당번 메일 "초안"만 만든다. 보내지 않는다
// 주소: https://script.google.com/macros/s/<배포ID>/exec, POST {"token","action"}
// 배포 ID·토큰은 NAS SSOT tokens.env(calendar.icsSSOTFile)에서 실행할 때마다 읽는다 — 코드·설정·커밋에 쓰지 않는다.

enum AppsScript {
    enum Project: String, CaseIterable { case grm = "GRM", cwll = "CWLL", cleaning = "CLEANING" }

    struct Reply { let ok: Bool; let text: String }

    /// tokens.env 에서 KEY=값 하나 (따옴표 제거). 없으면 nil
    static func value(_ key: String, in path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(key + "=") {
                let v = String(t.dropFirst(key.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    static func isConfigured(_ p: Project, env path: String) -> Bool {
        value("APPS_SCRIPT_TOKEN", in: path) != nil && value("APPS_SCRIPT_DEPLOYMENT_ID_" + p.rawValue, in: path) != nil
    }

    /// POST 호출. 공지 초안은 PDF 변환 때문에 오래 걸려 제한 시간 150초 (JYK 안내: 2분 이상). 302 는 URLSession 이 따라간다
    static func call(_ p: Project, action: String, env path: String) async -> Reply {
        guard let token = value("APPS_SCRIPT_TOKEN", in: path),
              let dep = value("APPS_SCRIPT_DEPLOYMENT_ID_" + p.rawValue, in: path),
              let url = URL(string: "https://script.google.com/macros/s/\(dep)/exec") else {
            return Reply(ok: false, text: "NAS tokens.env 에 APPS_SCRIPT_TOKEN · APPS_SCRIPT_DEPLOYMENT_ID_\(p.rawValue) 가 없음")
        }
        var req = URLRequest(url: url, timeoutInterval: 150)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token, "action": action])
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return Reply(ok: false, text: "응답을 읽지 못함 (JSON 아님)")
            }
            if (j["ok"] as? Bool) == true {
                return Reply(ok: true, text: summary(j["result"]) ?? "완료")
            }
            let err = j["error"] as? String ?? "알 수 없는 오류"
            let hint = ["unauthorized": "토큰이 맞지 않음", "unknown_action": "열려 있지 않은 동작",
                        "busy": "다른 호출이 실행 중 — 잠시 뒤 다시", "server_token_not_set": "스크립트 쪽 토큰 미설정"][err]
            return Reply(ok: false, text: hint.map { "\(err) · \($0)" } ?? err)
        } catch {
            return Reply(ok: false, text: error.localizedDescription)
        }
    }

    private static func summary(_ r: Any?) -> String? {
        switch r {
        case let s as String: return s
        case let a as [Any]: return a.isEmpty ? "없음" : a.map { "\($0)" }.joined(separator: ", ")
        case let d as [String: Any]:
            return d.keys.sorted().prefix(4).map { "\($0): \(d[$0].map { "\($0)" } ?? "")" }.joined(separator: " · ")
        case .some(let x): return "\(x)"
        default: return nil
        }
    }
}

/// 가운데 열 — 메일 초안 만들기 버튼. 누르면 확인을 한 번 받고 실행, 결과 한 줄
struct AppsScriptSection: View {
    @ObservedObject var model: NotionHubModel
    @State private var running: String? = nil
    @State private var last: (label: String, reply: AppsScript.Reply, at: Date)? = nil
    @State private var confirm: Item? = nil
    @Environment(\.cardStyle) private var cs

    struct Item: Identifiable {
        let id: String; let label: String; let detail: String; let project: AppsScript.Project; let action: String
    }
    private let items: [Item] = [
        Item(id: "grm2w", label: "GRM 2주 전 안내", detail: "2주 뒤 발표자 안내 메일 초안 (날짜·발표자별 중복 방지)", project: .grm, action: "createTwoWeeksAheadNotice"),
        Item(id: "grmpdf", label: "GRM 공지 + PDF", detail: "이번 주 GRM 공지 초안 (PDF 변환에 1~2분, '공지 발송' 칸으로 중복 방지)", project: .grm, action: "createAnnouncementDraftWithPDF"),
        Item(id: "clean", label: "청소 당번 초안", detail: "이번 주 청소 당번 메일 초안을 다시 만듦 (누를 때마다 새 초안)", project: .cleaning, action: "regenerateCleaningDraftFromNotion"),
        Item(id: "holiday", label: "휴가 주 보기", detail: "청소 순번에서 빠지는 휴가 주 목록 (읽기만)", project: .cleaning, action: "listHolidayWeeks"),
    ]

    // 캘린더와 같은 SSOT 파일 (calendar.icsSSOTFile)
    private var env: String { Config.load().calendar.icsSSOTFile }

    var body: some View {
        VStack(alignment: .leading, spacing: cs.gap) {
            SectionTitle(card: "tools")
            VStack(alignment: .leading, spacing: 8) {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(items) { it in
                        let ready = AppsScript.isConfigured(it.project, env: env)
                        Button { confirm = it } label: {
                            HStack(spacing: 4) {
                                if running == it.id { ProgressView().controlSize(.mini) }
                                Text(it.label).font(.hub(cs.aux, weight: .medium)).lineLimit(1).fixedSize()
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Hub.card))
                            .foregroundStyle(ready ? Hub.text : Hub.text3).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(!ready || running != nil)
                        .help(ready ? it.detail : "NAS tokens.env 에 APPS_SCRIPT_* 가 없음 (NAS 마운트 확인)")
                    }
                }
                if let l = last {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: l.reply.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(l.reply.ok ? Hub.ink : Hub.signal)
                        Text("\(l.label) · \(Hub.time(l.at)) — \(l.reply.text)").font(.hub(cs.aux - 0.5)).foregroundStyle(Hub.text2).lineLimit(2)
                    }
                }
            }
            .padding(cs.rowH)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Hub.surface))
        }
        .alert(item: $confirm) { it in
            Alert(title: Text(it.label), message: Text(it.detail + "\n메일은 보내지 않고 초안만 만듭니다."),
                  primaryButton: .default(Text("실행")) { run(it) }, secondaryButton: .cancel(Text("취소")))
        }
    }

    private func run(_ it: Item) {
        running = it.id
        let path = env
        Task { @MainActor in
            let r = await AppsScript.call(it.project, action: it.action, env: path)
            last = (it.label, r, Date()); running = nil
        }
    }
}
