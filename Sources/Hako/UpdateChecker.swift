import Foundation

/// GitHub Releases の最新バージョンを確認する
enum UpdateChecker {
    static let hakoReleasesPageURL = URL(string: "https://github.com/nemooon/hako/releases/latest")!
    static let colimaReleasesPageURL = URL(string: "https://github.com/abiosoft/colima/releases/latest")!

    /// Hako 自身のバージョン(swift run の素の実行ファイルでは nil)
    static var currentVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// GitHub リリースのバージョン("v" を除いたもの)と本文(Markdown)
    struct Release: Equatable {
        let version: String
        let notes: String
    }

    /// releases/latest API の応答を読む。tag_name が無ければ nil
    static func parseRelease(_ data: Data) -> Release? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = json["tag_name"] as? String
        else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: (json["body"] as? String) ?? "")
    }

    /// repo("owner/name")の最新リリース。オフラインや API エラーは nil(次回また確認する)
    static func latestRelease(repo: String) async -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return parseRelease(data)
    }

    /// repo の最新リリースが current より新しければ、そのバージョン文字列を返す(なければ nil)
    static func newerRelease(repo: String, current: String) async -> String? {
        guard let latest = await latestRelease(repo: repo)?.version else { return nil }
        return isNewer(latest, than: current) ? latest : nil
    }

    /// "0.2" > "0.1.1" のような数値バージョン比較
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let l = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let r = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(l.count, r.count) {
            let a = index < l.count ? l[index] : 0
            let b = index < r.count ? r[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}
