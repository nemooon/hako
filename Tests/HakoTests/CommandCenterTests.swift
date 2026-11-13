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
}
