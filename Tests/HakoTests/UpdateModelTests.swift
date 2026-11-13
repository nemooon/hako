import XCTest
@testable import Hako

@MainActor
final class UpdateModelTests: XCTestCase {
    private let brew = "/opt/homebrew/bin/brew"
    private let app = "/Applications/Hako.app"

    /// list の結果をパッケージごとに返し、upgrade 後は新しいバージョンを返す偽の brew
    private func fakeBrew(hako: String? = "0.6", colima: String? = "0.10.3",
                          upgradedTo: [String: String] = ["hako": "0.7", "colima": "0.11.0"],
                          upgrade: Shell.Result = FakeCommandRunner.ok(),
                          xattr: Shell.Result = FakeCommandRunner.ok()) -> FakeCommandRunner {
        let fake = FakeCommandRunner()
        var upgraded = Set<String>()
        fake.respond = { command in
            let package = command.last == "nemooon/tap/hako" || command.last == "hako" ? "hako" : "colima"
            if command.first == HomebrewUpdater.xattr { return xattr }
            if command.contains("upgrade") {
                if upgrade.status == 0 { upgraded.insert(package) }
                return upgrade
            }
            let version = upgraded.contains(package) ? upgradedTo[package] : (package == "hako" ? hako : colima)
            return version.map { FakeCommandRunner.ok("\(package) \($0)\n") } ?? FakeCommandRunner.fail("Error")
        }
        return fake
    }

    private func backend(_ fake: FakeCommandRunner?, hakoVersion: String? = "0.6", appPath: String? = "/Applications/Hako.app",
                         colimaVersion: String? = "0.10.3",
                         releases: [String: UpdateChecker.Release] = [
                             "nemooon/hako": .init(version: "0.7", notes: "- Hako の修正"),
                             "abiosoft/colima": .init(version: "0.11.0", notes: "- Colima の修正"),
                         ]) -> UpdateModel.Backend {
        UpdateModel.Backend(
            latestRelease: { releases[$0] },
            hakoVersion: hakoVersion,
            hakoAppPath: appPath,
            colimaVersion: { colimaVersion },
            updater: fake.map { HomebrewUpdater(brew: brew, run: $0.runner) }
        )
    }

    func testRefreshShowsAvailableAndUpToDate() async {
        let store = StatusStore()
        let model = UpdateModel(backend: backend(fakeBrew(), colimaVersion: "0.11.0"), store: store)
        await model.refresh()
        XCTAssertEqual(model.hako.phase, .available)
        XCTAssertEqual(model.hako.current, "0.6")
        XCTAssertEqual(model.hako.latest, "0.7")
        XCTAssertEqual(model.hako.notes, "- Hako の修正")
        XCTAssertEqual(model.colima.phase, .upToDate)
        XCTAssertEqual(store.availableUpdate, "0.7")
        XCTAssertNil(store.availableColimaUpdate)
        XCTAssertEqual(store.colimaVersion, "0.11.0")
    }

    func testNotBundledMakesOnlyHakoUnavailable() async {
        let model = UpdateModel(backend: backend(fakeBrew(), hakoVersion: nil, appPath: nil), store: StatusStore())
        await model.refresh()
        XCTAssertEqual(model.hako.phase, .unavailable(".app として動いていないため、アップデートできません"))
        XCTAssertEqual(model.colima.phase, .available)
    }

    func testMissingBrewMakesBothUnavailable() async {
        let model = UpdateModel(backend: backend(nil), store: StatusStore())
        await model.refresh()
        XCTAssertEqual(model.hako.phase, .unavailable("Homebrew が見つかりません"))
        XCTAssertEqual(model.colima.phase, .unavailable("Homebrew が見つかりません"))
        XCTAssertEqual(model.hako.latest, "0.7") // リリースページへのリンク用に残す
    }

    func testNotInstalledByHomebrewIsUnavailable() async {
        let model = UpdateModel(backend: backend(fakeBrew(colima: nil)), store: StatusStore())
        await model.refresh()
        XCTAssertEqual(model.colima.phase, .unavailable("Homebrew でインストールされていません"))
        XCTAssertEqual(model.hako.phase, .available)
    }

    func testOfflineCheckDoesNotHang() async {
        let store = StatusStore()
        let model = UpdateModel(backend: backend(fakeBrew(), releases: [:]), store: store)
        await model.refresh()
        XCTAssertEqual(model.hako.phase, .unavailable("新しいバージョンを確認できませんでした"))
        XCTAssertEqual(model.colima.phase, .unavailable("新しいバージョンを確認できませんでした"))
    }

    /// インストール済みで再起動待ち(「あとで」を選んだ後に開き直した)なら、更新ありではなく完了として出す
    func testInstalledButNotRestartedShowsInstalled() async {
        let store = StatusStore()
        let model = UpdateModel(backend: backend(fakeBrew(hako: "0.7")), store: store)
        await model.refresh()
        XCTAssertEqual(model.hako.phase, .installed)
        XCTAssertNil(store.availableUpdate)
    }

    func testColimaUpdateSucceedsAndUpdatesCurrent() async {
        let store = StatusStore()
        let model = UpdateModel(backend: backend(fakeBrew()), store: store)
        await model.refresh()
        await model.update(.colima)
        XCTAssertEqual(model.colima.phase, .installed)
        XCTAssertEqual(model.colima.current, "0.11.0")
        XCTAssertNil(model.colima.error)
        XCTAssertNil(store.availableColimaUpdate)
        XCTAssertEqual(store.colimaVersion, "0.11.0")
    }

    func testHakoUpdateSucceeds() async {
        let model = UpdateModel(backend: backend(fakeBrew()), store: StatusStore())
        await model.refresh()
        await model.update(.hako)
        XCTAssertEqual(model.hako.phase, .installed)
    }

    /// 隔離属性の削除だけ失敗しても、更新は済んでいるので完了として扱い、再起動もできるようにする
    func testQuarantineFailureStillCountsAsInstalled() async {
        let store = StatusStore()
        let model = UpdateModel(backend: backend(fakeBrew(xattr: FakeCommandRunner.fail("Operation not permitted"))), store: store)
        await model.refresh()
        await model.update(.hako)
        XCTAssertEqual(model.hako.phase, .installed)
        XCTAssertTrue(model.hako.error?.contains("隔離属性を削除できませんでした") == true)
        XCTAssertNil(store.availableUpdate)
    }

    /// 先に始まった確認が更新中に終わっても、「更新中」を上書きしない(ウィンドウを続けて開いた場合)。
    /// 上書きされると閉じるボタンや他方の更新ボタンが効いてしまう
    func testStaleRefreshDoesNotOverwriteUpdating() async {
        var gates: [CheckedContinuation<Void, Never>] = []
        var upgradeGate: CheckedContinuation<Void, Never>?
        let fake = fakeBrew()
        var backend = backend(fake)
        backend.updater = HomebrewUpdater(brew: brew) { path, arguments in
            if arguments.first == "upgrade" { await withCheckedContinuation { upgradeGate = $0 } }
            return await fake.runner(path, arguments)
        }
        let releases = ["nemooon/hako": UpdateChecker.Release(version: "0.7", notes: ""),
                        "abiosoft/colima": UpdateChecker.Release(version: "0.11.0", notes: "")]
        backend.latestRelease = { repo in
            await withCheckedContinuation { gates.append($0) }
            return releases[repo]
        }
        let model = UpdateModel(backend: backend, store: StatusStore())
        func waitUntil(_ condition: () -> Bool) async {
            for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 5_000_000) }
        }

        let first = Task { await model.refresh() }
        await waitUntil { gates.count == 2 }
        let second = Task { await model.refresh() }
        await waitUntil { gates.count == 4 }
        gates[3].resume(); gates[2].resume() // 後から始めた確認が先に終わる
        await second.value
        XCTAssertEqual(model.hako.phase, .available)

        let updating = Task { await model.update(.hako) }
        await waitUntil { upgradeGate != nil }
        gates[0].resume(); gates[1].resume() // 先に始めた確認が更新中に終わる
        await first.value
        XCTAssertEqual(model.hako.phase, .updating)
        XCTAssertTrue(model.isUpdating)

        upgradeGate?.resume()
        await updating.value
        XCTAssertEqual(model.hako.phase, .installed)
    }

    func testFailureReturnsToAvailableWithMessage() async {
        let model = UpdateModel(backend: backend(fakeBrew(upgrade: FakeCommandRunner.fail("Error: boom"))), store: StatusStore())
        await model.refresh()
        await model.update(.hako)
        XCTAssertEqual(model.hako.phase, .available)
        XCTAssertTrue(model.hako.error?.contains("アップデートに失敗しました") == true)
        XCTAssertFalse(model.isUpdating)
    }

    func testSecondUpdateIsIgnoredWhileUpdating() async {
        let fake = fakeBrew()
        var release: CheckedContinuation<Void, Never>?
        var upgrades: [String] = []
        let gated: HomebrewUpdater.Runner = { path, arguments in
            if arguments.first == "upgrade" {
                upgrades.append(arguments.last!)
                await withCheckedContinuation { release = $0 } // テストが離すまで更新中のままにする
            }
            return await fake.runner(path, arguments)
        }
        var backend = backend(fake)
        backend.updater = HomebrewUpdater(brew: brew, run: gated)
        let model = UpdateModel(backend: backend, store: StatusStore())
        await model.refresh()

        let first = Task { await model.update(.hako) }
        for _ in 0..<200 where release == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(model.isUpdating)
        XCTAssertEqual(model.hako.phase, .updating)

        await model.update(.colima)
        XCTAssertEqual(upgrades, ["nemooon/tap/hako"])
        XCTAssertEqual(model.colima.phase, .available)

        release?.resume()
        await first.value
        XCTAssertFalse(model.isUpdating)
    }
}

final class UpdateItemTests: XCTestCase {
    /// リリースページへのリンクは、今より新しい版があるときだけ出す
    func testNewerLatestOnlyWhenActuallyNewer() {
        XCTAssertEqual(UpdateItem(current: "0.6", latest: "0.7").newerLatest, "0.7")
        XCTAssertNil(UpdateItem(current: "0.6", latest: "0.6").newerLatest)
        XCTAssertNil(UpdateItem(current: "0.7", latest: "0.6").newerLatest)
        XCTAssertNil(UpdateItem(current: nil, latest: "0.7").newerLatest)
    }
}
