import Foundation

/// GitHub Releases の最新バージョンを確認する
enum UpdateChecker {
    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/nemooon/hako/releases/latest")!
    static let releasesPageURL = URL(string: "https://github.com/nemooon/hako/releases/latest")!

    /// 現在のバージョン(swift run の素の実行ファイルでは nil)
    static var currentVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// 現在より新しいバージョンがあればそのバージョン文字列を completion に渡す(なければ nil)。
    /// completion はバックグラウンドスレッドから呼ばれる
    static func check(completion: @escaping (String?) -> Void) {
        guard let current = currentVersion else {
            completion(nil) // バージョン不明(swift run)のときは確認しない
            return
        }
        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard
                let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tag = json["tag_name"] as? String
            else {
                completion(nil) // オフラインや API エラーは黙って諦める(次回また確認する)
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            completion(isNewer(latest, than: current) ? latest : nil)
        }.resume()
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
