import XCTest
@testable import Hako

/// 呼ばれたコマンドを記録し、決められた結果を返す偽の実行関数
final class FakeCommandRunner {
    private(set) var calls: [[String]] = []
    /// [path] + arguments を受け取り、結果を返す
    var respond: ([String]) -> Shell.Result = { _ in .init(status: 0, stdout: "", stderr: "") }

    var runner: HomebrewUpdater.Runner {
        { path, arguments in
            let command = [path] + arguments
            self.calls.append(command)
            return self.respond(command)
        }
    }

    static func ok(_ stdout: String = "") -> Shell.Result { .init(status: 0, stdout: stdout, stderr: "") }
    static func fail(_ stderr: String) -> Shell.Result { .init(status: 1, stdout: "", stderr: stderr) }
}

final class HomebrewUpdaterTests: XCTestCase {
    private let brew = "/opt/homebrew/bin/brew"
    private let app = "/Applications/Hako.app"

    /// list の 1 回目は before、upgrade 後は after を返す偽の brew
    private func fakeBrew(package: String, before: String?, after: String?,
                          upgrade: Shell.Result = FakeCommandRunner.ok(),
                          xattr: Shell.Result = FakeCommandRunner.ok()) -> FakeCommandRunner {
        let fake = FakeCommandRunner()
        var upgraded = false
        fake.respond = { command in
            if command.first == "/usr/bin/xattr" { return xattr }
            if command.last == "update" { return FakeCommandRunner.ok() }
            if command.contains("upgrade") { upgraded = true; return upgrade }
            if command.contains("list") {
                let version = upgraded ? after : before
                return version.map { FakeCommandRunner.ok("\(package) \($0)\n") } ?? FakeCommandRunner.fail("Error: not installed")
            }
            return FakeCommandRunner.fail("unexpected")
        }
        return fake
    }

    func testHakoUpgradeRunsBrewThenXattrInOrder() async throws {
        let fake = fakeBrew(package: "hako", before: "0.6", after: "0.7")
        try await HomebrewUpdater(brew: brew, run: fake.runner).upgrade(.hako, to: "0.7", appPath: app)
        XCTAssertEqual(fake.calls, [
            [brew, "list", "--cask", "--versions", "hako"],
            [brew, "update"],
            [brew, "upgrade", "--cask", "--no-quit", "--no-ask", "nemooon/tap/hako"],
            [brew, "list", "--cask", "--versions", "hako"],
            ["/usr/bin/xattr", "-dr", "com.apple.quarantine", app],
        ])
    }

    func testColimaUpgradeDoesNotRunXattr() async throws {
        let fake = fakeBrew(package: "colima", before: "0.10.3", after: "0.11.0")
        try await HomebrewUpdater(brew: brew, run: fake.runner).upgrade(.colima, to: "0.11.0", appPath: app)
        XCTAssertTrue(fake.calls.contains([brew, "upgrade", "--no-ask", "colima"]))
        XCTAssertTrue(fake.calls.contains([brew, "list", "--formula", "--versions", "colima"]))
        XCTAssertFalse(fake.calls.contains { $0.first == "/usr/bin/xattr" })
    }

    func testNotInstalledByHomebrewStopsBeforeUpgrade() async {
        let fake = fakeBrew(package: "hako", before: nil, after: nil)
        do {
            try await HomebrewUpdater(brew: brew, run: fake.runner).upgrade(.hako, to: "0.7", appPath: app)
            XCTFail("エラーになるべき")
        } catch {
            XCTAssertEqual(error as? UpdateError, .notInstalledByHomebrew)
        }
        XCTAssertFalse(fake.calls.contains { $0.contains("upgrade") })
    }

    func testUpgradeFailureCarriesOutput() async {
        let fake = fakeBrew(package: "hako", before: "0.6", after: "0.6", upgrade: FakeCommandRunner.fail("Error: boom"))
        do {
            try await HomebrewUpdater(brew: brew, run: fake.runner).upgrade(.hako, to: "0.7", appPath: app)
            XCTFail("エラーになるべき")
        } catch let error as UpdateError {
            XCTAssertTrue(error.message.contains("アップデートに失敗しました"))
            XCTAssertTrue(error.message.contains("Error: boom"))
        } catch {
            XCTFail("UpdateError になるべき: \(error)")
        }
    }

    func testTapLagIsReportedAndXattrIsSkipped() async {
        let fake = fakeBrew(package: "hako", before: "0.6", after: "0.6")
        do {
            try await HomebrewUpdater(brew: brew, run: fake.runner).upgrade(.hako, to: "0.7", appPath: app)
            XCTFail("エラーになるべき")
        } catch {
            XCTAssertEqual(error as? UpdateError, .versionNotYetAvailable("0.7"))
            XCTAssertEqual((error as? UpdateError)?.message,
                           "Homebrew にまだ 0.7 が反映されていません。しばらくしてから再試行してください")
        }
        XCTAssertFalse(fake.calls.contains { $0.first == "/usr/bin/xattr" })
    }

    func testQuarantineFailureShowsManualCommand() async {
        let fake = fakeBrew(package: "hako", before: "0.6", after: "0.7", xattr: FakeCommandRunner.fail("Operation not permitted"))
        do {
            try await HomebrewUpdater(brew: brew, run: fake.runner).upgrade(.hako, to: "0.7", appPath: app)
            XCTFail("エラーになるべき")
        } catch let error as UpdateError {
            XCTAssertTrue(error.message.contains("アップデートは完了しましたが隔離属性を削除できませんでした"))
            XCTAssertTrue(error.message.contains("Operation not permitted"))
            XCTAssertTrue(error.message.contains("xattr -dr com.apple.quarantine /Applications/Hako.app"))
        } catch {
            XCTFail("UpdateError になるべき: \(error)")
        }
    }

    func testInstalledVersionTakesLatestOfSeveral() async {
        let fake = FakeCommandRunner()
        fake.respond = { _ in FakeCommandRunner.ok("colima 0.10.2 0.10.3\n") }
        let version = await HomebrewUpdater(brew: brew, run: fake.runner).installedVersion(.colima)
        XCTAssertEqual(version, "0.10.3")
    }

    /// brew list の並びは数値順とは限らない(バイト順)ので、最大のバージョンを選ぶ
    func testInstalledVersionPicksNumericallyLatest() async {
        let fake = FakeCommandRunner()
        fake.respond = { _ in FakeCommandRunner.ok("colima 0.10.3 0.9.1\n") }
        let version = await HomebrewUpdater(brew: brew, run: fake.runner).installedVersion(.colima)
        XCTAssertEqual(version, "0.10.3")
    }

    /// homebrew-core の revision 付き(0.11.0_1)は 0.11.0 として扱う
    func testRevisionSuffixCountsAsExpectedVersion() async throws {
        let fake = fakeBrew(package: "colima", before: "0.10.3", after: "0.11.0_1")
        try await HomebrewUpdater(brew: brew, run: fake.runner).upgrade(.colima, to: "0.11.0", appPath: app)
    }

    /// upgrade の前に一覧を取り直す(自動更新は 24 時間に 1 回のため、再試行が効かなくなる)
    func testRefreshesHomebrewBeforeUpgrade() async throws {
        let fake = fakeBrew(package: "colima", before: "0.10.3", after: "0.11.0")
        try await HomebrewUpdater(brew: brew, run: fake.runner).upgrade(.colima, to: "0.11.0", appPath: app)
        let update = fake.calls.firstIndex(of: [brew, "update"])
        let upgrade = fake.calls.firstIndex(of: [brew, "upgrade", "--no-ask", "colima"])
        XCTAssertNotNil(update)
        XCTAssertLessThan(update ?? .max, upgrade ?? .min)
        XCTAssertEqual(HomebrewUpdater.commands(for: .colima, appPath: app), ["brew update", "brew upgrade --no-ask colima"])
    }

    func testLocateBrewPrefersAppleSilicon() {
        XCTAssertEqual(HomebrewUpdater.locateBrew(fileExists: { _ in true }), "/opt/homebrew/bin/brew")
        XCTAssertEqual(HomebrewUpdater.locateBrew(fileExists: { $0 == "/usr/local/bin/brew" }), "/usr/local/bin/brew")
        XCTAssertNil(HomebrewUpdater.locateBrew(fileExists: { _ in false }))
    }
}
