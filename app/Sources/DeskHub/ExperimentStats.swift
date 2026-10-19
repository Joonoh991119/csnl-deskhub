import SwiftUI
import AppKit

// MARK: - 실험 수집 한 줄 + 키 표 (0.40.0 C7, A4 — 수렴 문서 §3-2 A4, 정의서 A4-*)
// '데이터가 들어오나? 현장은 쉬는 중인가, 기록이 어긋났나?' — 공정 보드 '실험' 행을 한 줄 요약으로 바꾸고, 누르면 키 표(프로젝트×실험자).
// 온라인 = Prolific(게시일·제출·정원, 금액 안 씀), 현장 = 집계(SLab·SLab 캘린더 마지막 날짜). 정체 경보·적색 없음(D7).

enum ExperimentStats {
    struct Online: Equatable { let year: Int; let month: Int; let studies: Int; let submissions: Int; let underQuota: Int }
    enum Tone { case text, text2, text3 }

    /// 그 달(한국시간)에 게시한 study 수 · 그 study 제출 합(study 누적) · 진행 중(ACTIVE) 정원 미달 수(모든 study) (A4-online)
    static func online(_ studies: [ProlificStudy], year: Int, month: Int) -> Online {
        let cal = MetricDefs.kst
        let inMonth = studies.filter { s in
            guard let d = s.publishedAt else { return false }
            let c = cal.dateComponents([.year, .month], from: d)
            return c.year == year && c.month == month
        }
        let under = studies.filter { $0.status == "ACTIVE" && $0.placesTaken < $0.places }.count
        return Online(year: year, month: month, studies: inMonth.count, submissions: inMonth.reduce(0) { $0 + $1.submissions }, underQuota: under)
    }
    /// 게시월별 제출 합 = 게시일 있는 study 제출 합 (A4-sum 고정 시험)
    static func monthlySum(_ studies: [ProlificStudy]) -> (byMonth: Int, total: Int) {
        let cal = MetricDefs.kst
        var by: [String: Int] = [:]
        for s in studies { if let d = s.publishedAt { let c = cal.dateComponents([.year, .month], from: d); by["\(c.year ?? 0)-\(c.month ?? 0)", default: 0] += s.submissions } }
        return (by.values.reduce(0, +), studies.filter { $0.publishedAt != nil }.reduce(0) { $0 + $1.submissions })
    }
    static func onlineMetricText(_ o: Online) -> String { "study \(o.studies) · 제출 \(o.submissions) · 정원 미달 진행 중 \(o.underQuota)" }
    static func onlineLineText(_ o: Online) -> String { "온라인 \(o.month)월 게시 study \(o.studies) · 그 제출 \(o.submissions) · 정원 미달 진행 중 \(o.underQuota)" }

    /// 현장 (A4-field, D-f) — 둘 다 14일(주간×2) 넘게 멈춤 → '현장 쉼 n일 (Notion·캘린더 둘 다 멈춤)'(text3, n = 오늘 − 늦은 쪽),
    /// 한쪽만 → '출처 어긋남 n'(text2, n = 두 날짜 차이 일), 둘 다 최근 → '현장 마지막 M.d', 집계 없음 → '현장 — (집계 없음)'
    static let stallDays = 14
    static func field(slab: Date?, ics: Date?, today: Date) -> (text: String, tone: Tone) {
        let cal = Calendar.current
        func age(_ d: Date) -> Int { cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: today)).day ?? 0 }
        switch (slab, ics) {
        case (nil, nil): return ("현장 — (집계 없음)", .text3)
        case let (s?, i?):
            let sa = age(s), ia = age(i)
            if sa > stallDays && ia > stallDays { return ("현장 쉼 \(min(sa, ia))일 (Notion·캘린더 둘 다 멈춤)", .text3) }
            if (sa > stallDays) != (ia > stallDays) { return ("출처 어긋남 \(abs(sa - ia))", .text2) }
            return ("현장 마지막 " + Hub.shortDay(max(s, i)), .text3)
        case let (s?, nil): return age(s) > stallDays ? ("현장 쉼 \(age(s))일 (Notion 만, 캘린더 집계 없음)", .text3) : ("현장 마지막 " + Hub.shortDay(s), .text3)
        case let (nil, i?): return age(i) > stallDays ? ("현장 쉼 \(age(i))일 (캘린더 만, Notion 집계 없음)", .text3) : ("현장 마지막 " + Hub.shortDay(i), .text3)
        }
    }

    /// 키 표 (A4-keys) — 10회 이상 키는 그대로(마지막 날짜 내림차순), 미만은 '기타 n개 · n회' 한 줄
    struct KeyLine: Identifiable { let id: String; let label: String; let sessions: Int; let last: Date?; let help: String }
    static let keyMin = 10
    static func keyTable(_ keys: [MetricsSnapshot.SlabKey]) -> (lines: [KeyLine], otherKeys: Int, otherSessions: Int, otherHelp: String) {
        func label(_ k: MetricsSnapshot.SlabKey) -> String { (k.project.isEmpty ? "(프로젝트 없음)" : k.project) + " × " + (k.experimenter.isEmpty ? "실험자 미연결" : k.experimenter) }
        let big = keys.filter { $0.sessions >= keyMin }.sorted { ($0.lastDate ?? .distantPast) != ($1.lastDate ?? .distantPast) ? ($0.lastDate ?? .distantPast) > ($1.lastDate ?? .distantPast) : $0.sessions > $1.sessions }
        let small = keys.filter { $0.sessions < keyMin }
        return (big.map { KeyLine(id: label($0), label: label($0), sessions: $0.sessions, last: $0.lastDate, help: label($0)) },
                small.count, small.reduce(0) { $0 + $1.sessions }, small.map { label($0) + " \($0.sessions)회" }.joined(separator: "\n"))
    }
}

extension NotionHubModel {
    /// 공정 보드 '실험' 한 줄의 두 덩어리 — (글, 톤). 온라인 = Prolific(이 맥 토큰), 현장 = 집계
    func experimentSummary() -> [(String, ExperimentStats.Tone)] {
        let c = MetricDefs.kst.dateComponents([.year, .month], from: HubClock.now)
        let onlineText: String
        if let n = prolificNote, prolificStudies.isEmpty { onlineText = "온라인 — (" + (n.hasPrefix("Prolific 미연결") ? "Prolific 미연결" : "Prolific 조회 실패") + ")" }
        else { onlineText = ExperimentStats.onlineLineText(ExperimentStats.online(prolificStudies, year: c.year ?? 0, month: c.month ?? 0)) }
        let f: (text: String, tone: ExperimentStats.Tone) = metrics == nil ? (text: "현장 — (집계 없음)", tone: .text3)
            : ExperimentStats.field(slab: metrics?.slabLast, ics: metrics?.icsLast, today: today)
        return [(onlineText, .text), (f.text, f.tone)]
    }
    /// pipeline.txt [실험 키] — 머리 + '- 키 · n회 · M.d' + 기타 + 실험자 미연결 (세션 합 = 집계 slab.sessions)
    func experimentKeyDumpLines() -> [String] {
        guard let snap = metrics else { return ["집계 없음 — " + (metricsNote ?? "")] }
        let t = ExperimentStats.keyTable(snap.slabKeys)
        let total = t.lines.reduce(0) { $0 + $1.sessions } + t.otherSessions
        var out = ["키 \(snap.slabKeys.count) · 10회 이상 \(t.lines.count) · 세션 합 \(total) · 펼침 " + (HubExpansion.shared.isOpen("exp-keys") ? "on" : "off")]
        out += t.lines.map { "- \($0.label) · \($0.sessions)회 · " + ($0.last.map(Hub.shortDay) ?? "—") + " · SLab 집계" }
        if t.otherKeys > 0 { out.append("- 기타 \(t.otherKeys)개 · \(t.otherSessions)회") }
        out.append("- 실험자 미연결 \(snap.slabNoExperimenter ?? 0)")
        return out
    }
}

/// 공정 보드 '실험' 펼침 — 4열 표(키=프로젝트×실험자 | 누적 세션 | 마지막 날짜 | 출처 꼬리표) + 기타 + '실험자 미연결 n' 점선 칩
struct ExperimentKeyTable: View {
    @ObservedObject var model: NotionHubModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let snap = model.metrics {
                let t = ExperimentStats.keyTable(snap.slabKeys)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    GridRow {
                        Text("키 = 프로젝트 × 실험자"); Text("누적 세션"); Text("마지막 날짜"); Text("출처")
                    }
                    .font(.hub(11, weight: .semibold)).foregroundStyle(Hub.text3)
                    ForEach(t.lines) { l in
                        GridRow {
                            Text(l.label).font(.hub(12.5, weight: .medium)).lineLimit(1).help(l.help)
                            Text("\(l.sessions)회").font(.hub(12.5)).monospacedDigit()
                            Text(l.last.map(Hub.shortDay) ?? "—").font(.hub(12.5)).monospacedDigit().foregroundStyle(Hub.text2)
                            Text("SLab 집계").font(.hub(11)).foregroundStyle(Hub.text3)
                        }
                    }
                    if t.otherKeys > 0 {
                        GridRow {
                            Text("기타 \(t.otherKeys)개 · \(t.otherSessions)회").font(.hub(12.5)).foregroundStyle(Hub.text2).help(t.otherHelp)
                            Text(""); Text(""); Text("")
                        }
                    }
                }
                HStack(spacing: 8) {
                    Text("실험자 미연결 \(snap.slabNoExperimenter ?? 0)").font(.hub(11.5, weight: .semibold)).foregroundStyle(Hub.text2)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Hub.text2, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                        .link(.notion(model.cfg.slabDB))
                        .help("SLab '실험자' relation 이 빈 예약 — Notion 에서 실험자를 연결하면 사라짐 (A2 위생)")
                    Spacer(minLength: 0)
                }
                SourceCaption(text: MetricDefs.caption(source: "SLab(집계, 이 맥 전용)", basis: DataSources.asOfText(snap.asOf),
                                                       n: "\(snap.slabSessions ?? 0)", id: "A4-keys"))
            } else {
                Text((model.metricsNote ?? "집계 없음") + " — 키 표는 이 맥의 집계(latest.json)에서").font(.hub(12)).foregroundStyle(Hub.text2)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}
