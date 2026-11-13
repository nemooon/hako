import Foundation

/// アップデートウィンドウで更新できるもの
enum UpdatePackage {
    case hako, colima
}

/// 更新が失敗した理由。message はそのまま画面に出す
enum UpdateError: Error, Equatable {
    case notInstalledByHomebrew
    case upgradeFailed(String)
    case versionNotYetAvailable(String)
    case quarantineRemovalFailed(detail: String, command: String)

    var message: String {
        switch self {
        case .notInstalledByHomebrew:
            return "Homebrew でインストールされていません"
        case .upgradeFailed(let output):
            return "アップデートに失敗しました\n\n\(output)"
        case .versionNotYetAvailable(let version):
            return "Homebrew にまだ \(version) が反映されていません。しばらくしてから再試行してください"
        case .quarantineRemovalFailed(let detail, let command):
            return "アップデートは完了しましたが隔離属性を削除できませんでした\n\n\(detail)\n\nターミナルで次のコマンドを実行してください:\n\(command)"
        }
    }
}

/// Homebrew で Hako / Colima を更新する手順。コマンドの実行は差し替えられる(テスト用)
struct HomebrewUpdater {
    typealias Runner = (_ path: String, _ arguments: [String]) async -> Shell.Result

    let brew: String
    let run: Runner

    static let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    static let xattr = "/usr/bin/xattr"

    static func locateBrew(fileExists: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
        candidates.first(where: fileExists)
    }

    /// brew が見つからなければ nil
    static func live() -> HomebrewUpdater? {
        locateBrew().map { brew in
            HomebrewUpdater(brew: brew, run: { path, arguments in await Shell.runProgram(path, arguments) })
        }
    }

    /// 画面に出す「実行するコマンド」
    static func commands(for package: UpdatePackage, appPath: String) -> [String] {
        switch package {
        case .hako:
            return ["brew update", Shell.display(["brew"] + upgradeArguments(.hako)), quarantineCommand(appPath)]
        case .colima:
            return ["brew update", Shell.display(["brew"] + upgradeArguments(.colima))]
        }
    }

    private static func quarantineCommand(_ appPath: String) -> String {
        Shell.display(["xattr", "-dr", "com.apple.quarantine", appPath])
    }

    private static func listArguments(_ package: UpdatePackage) -> [String] {
        switch package {
        case .hako: return ["list", "--cask", "--versions", "hako"]
        case .colima: return ["list", "--formula", "--versions", "colima"]
        }
    }

    private static func upgradeArguments(_ package: UpdatePackage) -> [String] {
        switch package {
        case .hako: return ["upgrade", "--cask", "--no-quit", "--no-ask", "nemooon/tap/hako"]
        case .colima: return ["upgrade", "--no-ask", "colima"]
        }
    }

    /// Homebrew が入れているバージョン。Homebrew 管理でなければ nil
    /// 複数並ぶときの順番は数値順とは限らないので最大のものを選び、revision("_1")は落とす
    func installedVersion(_ package: UpdatePackage) async -> String? {
        let result = await run(brew, Self.listArguments(package))
        guard result.status == 0, let line = result.stdout.split(separator: "\n").first else { return nil }
        return line.split(separator: " ").dropFirst()
            .map { String($0.split(separator: "_").first ?? $0) }
            .max { UpdateChecker.isNewer($1, than: $0) }
    }

    /// 更新して、期待するバージョンが入ったことを確かめる。Hako は続けて隔離属性を外す
    func upgrade(_ package: UpdatePackage, to expected: String, appPath: String?) async throws {
        guard await installedVersion(package) != nil else { throw UpdateError.notInstalledByHomebrew }

        // brew upgrade の自動更新は 24 時間に 1 回なので、先に一覧を取り直す(しないと再試行が効かない)
        for arguments in [["update"], Self.upgradeArguments(package)] {
            let result = await run(brew, arguments)
            guard result.status == 0 else {
                throw UpdateError.upgradeFailed(Self.output(of: result))
            }
        }
        guard let installed = await installedVersion(package),
              !UpdateChecker.isNewer(expected, than: installed)
        else {
            throw UpdateError.versionNotYetAvailable(expected)
        }

        guard package == .hako, let appPath else { return }
        try await removeQuarantine(appPath: appPath)
    }

    /// Developer ID 署名が無いので、隔離属性が残っていると Gatekeeper が起動を止める
    func removeQuarantine(appPath: String) async throws {
        let xattr = await run(Self.xattr, ["-dr", "com.apple.quarantine", appPath])
        guard xattr.status == 0 else {
            throw UpdateError.quarantineRemovalFailed(
                detail: Self.output(of: xattr),
                command: Self.quarantineCommand(appPath)
            )
        }
    }

    private static func output(of result: Shell.Result) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : stderr
    }
}
