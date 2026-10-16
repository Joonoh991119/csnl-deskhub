import Foundation

// MARK: - NAS 배포본으로 업데이트 (리뷰 방식 개선 B1·B2, 2026-10-15)
// 리뷰어가 컴파일 없이 라운드 버전을 받게: build.sh publish 가 NAS Grant/_ssot/deskhub/ 에 zip + latest.json 을 둔다.

enum AppUpdate {
    struct Info { let version: String; let zip: String; let round: String }
    static var dir: String { ProcessInfo.processInfo.environment["DESKHUB_PUBLISH_DIR"] ?? "/Volumes/CSNL_new/Grant/_ssot/deskhub" }

    /// 설치본보다 새 배포본이 있으면
    static func available() -> Info? {
        guard let d = FileManager.default.contents(atPath: dir + "/latest.json"),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let v = o["version"] as? String, let z = o["zip"] as? String else { return nil }
        let cur = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard newer(v, than: cur) else { return nil }
        return Info(version: v, zip: dir + "/" + z, round: o["round"] as? String ?? "")
    }

    /// "0.30.10" > "0.30.3" — 숫자 단위 비교
    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// 앱이 끝난 뒤 바꿔 끼우고 다시 띄우는 셸을 따로 띄운다 (앱 안에서 자기 번들을 지우지 않게)
    static func install(zip: String) {
        let q = zip.replacingOccurrences(of: "'", with: "'\\''")
        let script = "sleep 2; T=$(mktemp -d); ditto -x -k '\(q)' \"$T\" && rm -rf /Applications/DeskHub.app && ditto \"$T/DeskHub.app\" /Applications/DeskHub.app && rm -rf \"$T\"; "
            + "mkdir -p ~/.claude/csnl-report/deskhub; nohup /Applications/DeskHub.app/Contents/MacOS/DeskHub > ~/.claude/csnl-report/deskhub/app.log 2>&1 &"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", script]
        try? p.run()
    }
}
