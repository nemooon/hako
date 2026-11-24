import XCTest
@testable import Hako

@MainActor
final class CommandCenterTests: XCTestCase {
    /// 別の操作の処理中は Colima を再起動できないことを呼び出し側に伝える(黙って何もしないのを防ぐ)
    func testRestartColimaReportsWhenBusy() async {
        var release: CheckedContinuation<Void, Never>?
        var commands: [[String]] = []
        let backend = StatusStore.Backend(
            fetchSnapshot: { ColimaSnapshot(profile: "default", running: true, vmInfo: nil, containers: [], composeProjects: []) },
            fetchStats: { [:] },
            fetchDiskUsage: { [] },
            colimaVersion: { nil },
            latestRelease: { _, _ in nil },
            run: { arguments in
                await MainActor.run { commands.append(arguments) }
                if arguments.first == "docker" { await withCheckedContinuation { c in Task { @MainActor in release = c } } }
                return Shell.Result(status: 0, stdout: "", stderr: "")
            },
            notify: { _, _ in }
        )
        let store = StatusStore(backend: backend)
        let center = CommandCenter(store: store, editors: EditorPreferences(isInstalled: { _ in false }))

        let busy = Task { await store.run(message: "処理中", arguments: ["docker", "volume", "prune", "-f"]) }
        for _ in 0..<1000 where !store.isBusy { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(store.isBusy, "処理中にならないまま時間切れ")
        XCTAssertFalse(center.restartColima())

        for _ in 0..<1000 where release == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
        release?.resume()
        _ = await busy.value
        XCTAssertTrue(center.restartColima())
    }

    // MARK: - プロファイル切り替え

    private let threeProfiles = [
        ColimaProfile(name: "default", running: true),
        ColimaProfile(name: "work", running: true),
        ColimaProfile(name: "lab", running: false),
    ]

    /// 指定のスナップショットを読み込んだ store と、実行されたコマンドの記録を用意する
    private func makeCenter(isColimaContext: Bool = true) async -> (CommandCenter, StatusStore, () async -> [[String]]) {
        let recorder = CommandRecorder()
        let snapshot = ColimaSnapshot(profile: "default", running: true, vmInfo: nil, containers: [], composeProjects: [],
                                      profiles: threeProfiles, isColimaContext: isColimaContext)
        let backend = StatusStore.Backend(
            fetchSnapshot: { snapshot },
            fetchStats: { [:] },
            fetchDiskUsage: { [] },
            colimaVersion: { nil },
            latestRelease: { _, _ in nil },
            run: { arguments in
                await recorder.append(arguments)
                return Shell.Result(status: 0, stdout: "", stderr: "")
            },
            notify: { _, _ in }
        )
        let store = StatusStore(backend: backend)
        store.refresh()
        for _ in 0..<200 where store.snapshot == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
        let center = CommandCenter(store: store, editors: EditorPreferences(isInstalled: { _ in false }))
        return (center, store, { await recorder.commands })
    }

    /// 切り替えで起きた非同期の実行が終わるまで待つ
    private func settle(_ store: StatusStore) async {
        for _ in 0..<20 { try? await Task.sleep(nanoseconds: 5_000_000) }
        for _ in 0..<200 where store.isBusy { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testSwitchToRunningProfileChangesDockerContext() async {
        let (center, store, commands) = await makeCenter()
        center.switchProfile("work")
        await settle(store)
        let recorded = await commands()
        XCTAssertEqual(recorded.last, ["docker", "context", "use", "colima-work"])
    }

    func testSwitchToStoppedProfileStartsIt() async {
        let (center, store, commands) = await makeCenter()
        center.switchProfile("lab")
        await settle(store)
        let recorded = await commands()
        XCTAssertEqual(recorded.last, ["colima", "start", "--profile", "lab"])
    }

    func testSwitchToCurrentProfileDoesNothing() async {
        let (center, store, commands) = await makeCenter()
        center.switchProfile("default")
        await settle(store)
        let recorded = await commands()
        XCTAssertEqual(recorded, [])
    }

    /// Docker Desktop などを向いているときは、同じ名前でも切り替える(今は default を向いていないため)
    func testSwitchFromNonColimaContextRunsEvenForSameName() async {
        let (center, store, commands) = await makeCenter(isColimaContext: false)
        center.switchProfile("default")
        await settle(store)
        let recorded = await commands()
        XCTAssertEqual(recorded.last, ["docker", "context", "use", "colima"])
    }

    func testSwitchWhileBusyDoesNothing() async {
        let gate = Gate()
        let snapshot = ColimaSnapshot(profile: "default", running: true, vmInfo: nil, containers: [], composeProjects: [],
                                      profiles: threeProfiles)
        let recorder = CommandRecorder()
        let backend = StatusStore.Backend(
            fetchSnapshot: { snapshot },
            fetchStats: { [:] },
            fetchDiskUsage: { [] },
            colimaVersion: { nil },
            latestRelease: { _, _ in nil },
            run: { arguments in
                await recorder.append(arguments)
                if arguments.first == "sleep" { await gate.wait() }
                return Shell.Result(status: 0, stdout: "", stderr: "")
            },
            notify: { _, _ in }
        )
        let store = StatusStore(backend: backend)
        store.refresh()
        for _ in 0..<200 where store.snapshot == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
        let center = CommandCenter(store: store, editors: EditorPreferences(isInstalled: { _ in false }))

        let busy = Task { await store.run(message: "処理中", arguments: ["sleep"]) }
        for _ in 0..<200 where !store.isBusy { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(store.isBusy, "処理中にならないまま時間切れ")
        center.switchProfile("work")
        for _ in 0..<20 { try? await Task.sleep(nanoseconds: 5_000_000) }
        await gate.open()
        _ = await busy.value
        let recorded = await recorder.commands
        XCTAssertEqual(recorded, [["sleep"]])
    }

    func testSwitchToUnknownProfileDoesNothing() async {
        let (center, store, commands) = await makeCenter()
        center.switchProfile("nope")
        await settle(store)
        let recorded = await commands()
        XCTAssertEqual(recorded, [])
    }
}

/// 実行されたコマンドを記録する(Backend の run は別スレッドから呼ばれる)
private actor CommandRecorder {
    private(set) var commands: [[String]] = []
    func append(_ arguments: [String]) { commands.append(arguments) }
}

/// テストから開けるまで待たせる門
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
