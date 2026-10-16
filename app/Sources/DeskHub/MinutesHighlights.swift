import Foundation

/// 회의록 "핵심 결과" 2~3줄 — Notion 회의록의 Source File(NAS 녹취 JSON)에 든 Plaud 노트에서 뽑는다. Notion 은 쓰지 않는다.
/// (BHL 리뷰 2026-10-13: 흐름 요약 대신 발표 핵심을 두세 줄)
///
/// Plaud 노트는 주마다 틀이 다르다(소제목이 곧 주장인 "## 파일럿 결과 — 노출 시간은 …" 꼴, "### 3. 핵심 결과: …" 아래 본문,
/// "- **본 연구의 핵심 독창성**:" 아래 번호 목록). 그래서
/// 1. 소제목에 " — " 가 있으면 뒤쪽 주장을 그대로 쓰고,
/// 2. 핵심·결과·결론 같은 말이 든 소제목/굵은 라벨이면 그 아래 본문 1~2줄을 쓴다.
/// 우선순위(핵심 결과 > 핵심·결론 > 결과·발견…)로 고르고 같은 순위는 문서 순서를 따른다.
enum MinutesHighlights {
    static let weights: [(String, Int)] = [("핵심 결과", 4), ("주요 결과", 4), ("핵심", 3), ("결론", 3), ("결과", 2), ("발견", 2),
                                           ("확인", 1), ("시사", 1), ("독창성", 2)]
    static let skip = ["할 일", "과제", "질문", "다음 안건", "AI 제안", "요약", "데이터 수집", "업로드", "화면 크기", "응답 절차", "향후"]

    static func extract(path: String, limit: Int = 3) -> [String] {
        guard let d = FileManager.default.contents(atPath: path),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let notes = o["plaud_notes"] as? [String: Any] else { return [] }
        var picks: [(score: Int, order: Int, text: String)] = []
        var order = 0
        for key in notes.keys.sorted() {
            guard let text = notes[key] as? String else { continue }
            var capture = 0, captureScore = 0
            for raw in text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                if line.hasPrefix("#") {
                    capture = 0
                    let h = clean(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))
                    if skip.contains(where: { h.hasPrefix($0) || h.contains("· " + $0) }) { continue }
                    if let r = h.range(of: " — ") {
                        let claim = String(h[r.upperBound...]), w = weight(h)
                        if w > 0 { order += 1; picks.append((w, order, claim)) }
                    } else if weight(h) > 0 {
                        capture = 2; captureScore = weight(h)
                    }
                    continue
                }
                // "- **라벨**:" 처럼 내용 없이 라벨만 있는 줄 → 그 아래를 본다
                let body = clean(line)
                if body.hasSuffix(":") || body.hasSuffix("：") {
                    let w = weight(body)
                    if w > 0 { capture = 2; captureScore = w } else if capture > 0 { capture = 0 }
                    continue
                }
                if capture > 0 && body.count >= 8 {
                    order += 1; picks.append((captureScore, order, body)); capture -= 1
                }
            }
        }
        return picks.sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            .prefix(limit).sorted { $0.order < $1.order }.map(\.text)
    }

    static func weight(_ s: String) -> Int { weights.filter { s.contains($0.0) }.map(\.1).max() ?? 0 }

    /// 글머리표·번호·굵게 표시를 지운다
    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "**", with: "")
        t = t.replacingOccurrences(of: "^([-*•]\\s+|\\d+[.)]\\s+)", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "^\\d+[.)]\\s*", with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// "file:///Volumes/…json" → 경로
    static func path(fromSourceFile s: String) -> String? {
        guard !s.isEmpty else { return nil }
        if let u = URL(string: s), u.isFileURL { return u.path }
        return s.hasPrefix("/") ? s : nil
    }
}
