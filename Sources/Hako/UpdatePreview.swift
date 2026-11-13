import Foundation

/// 開発用: HAKO_UPDATE_PREVIEW を付けて起動すると、本物の brew / colima に触れずに
/// 仮想のアップデートをアップデートウィンドウとメニューバーに表示する。
///   HAKO_UPDATE_PREVIEW=1     成功
///   HAKO_UPDATE_PREVIEW=fail  「アップデートに失敗しました」
///   HAKO_UPDATE_PREVIEW=lag   「Homebrew にまだ反映されていません」
enum UpdatePreview {
    enum Outcome: Equatable {
        case success, failure, lag
    }

    static let variable = "HAKO_UPDATE_PREVIEW"

    /// 環境変数が無いか、0 / false / no / off なら nil(プレビューしない)。認識できない値は成功として扱う
    static func outcome(from environment: [String: String]) -> Outcome? {
        guard let value = environment[variable] else { return nil }
        switch value.lowercased() {
        case "0", "false", "no", "off": return nil
        case "fail": return .failure
        case "lag": return .lag
        default: return .success
        }
    }

    static let current = outcome(from: ProcessInfo.processInfo.environment)

    static let hakoVersion = "0.6"
    static let hakoAppPath = "/Applications/Hako.app"
    static let fallbackColimaVersion = "0.10.3"

    static let hakoRelease = UpdateChecker.Release(version: "0.7", notes: """
        **プレビュー用の変更内容です。**

        - アップデートウィンドウの表示を確認するための見本
        - 本物の Homebrew は実行されません
        """)

    static let colimaRelease = UpdateChecker.Release(version: "0.99.0", notes: """
        **プレビュー用の変更内容です。**

        - `brew upgrade colima` は実行されず、Colima の VM にも触れません
        """)

    static func release(for repo: String) -> UpdateChecker.Release? {
        switch repo {
        case UpdateModel.hakoRepo: return hakoRelease
        case UpdateModel.colimaRepo: return colimaRelease
        default: return nil
        }
    }

    /// 本物の代わりに動く brew。upgrade は delay ナノ秒かかり、outcome どおりに終わる
    static func updater(_ outcome: Outcome, colimaVersion: String = fallbackColimaVersion,
                        delay: UInt64 = 2_000_000_000) -> HomebrewUpdater {
        let state = PreviewBrewState()
        return HomebrewUpdater(brew: "/opt/homebrew/bin/brew") { path, arguments in
            let ok = Shell.Result(status: 0, stdout: "", stderr: "")
            guard path != HomebrewUpdater.xattr else { return ok }
            let isHako = arguments.contains("hako") || arguments.contains("nemooon/tap/hako")
            switch arguments.first {
            case "list":
                let (name, before, after) = isHako
                    ? ("hako", hakoVersion, hakoRelease.version)
                    : ("colima", colimaVersion, colimaRelease.version)
                let upgraded = await state.isUpgraded(name)
                return Shell.Result(status: 0, stdout: "\(name) \(upgraded ? after : before)\n", stderr: "")
            case "upgrade":
                try? await Task.sleep(nanoseconds: delay)
                switch outcome {
                case .success:
                    await state.markUpgraded(isHako ? "hako" : "colima")
                    return ok
                case .failure:
                    return Shell.Result(status: 1, stdout: "", stderr: "Error: プレビュー用の失敗です")
                case .lag:
                    return ok
                }
            default:
                return ok
            }
        }
    }

    static func backend(_ outcome: Outcome, colimaVersion: @escaping @MainActor () async -> String?,
                        delay: UInt64 = 2_000_000_000) -> UpdateModel.Backend {
        UpdateModel.Backend(
            latestRelease: { release(for: $0) },
            hakoVersion: hakoVersion,
            hakoAppPath: hakoAppPath,
            colimaVersion: { await colimaVersion() ?? fallbackColimaVersion },
            updater: updater(outcome, delay: delay)
        )
    }
}

/// 偽の brew が「更新済み」を覚えておく場所
private actor PreviewBrewState {
    private var upgraded = Set<String>()
    func isUpgraded(_ name: String) -> Bool { upgraded.contains(name) }
    func markUpgraded(_ name: String) { upgraded.insert(name) }
}
