import XCTest
@testable import Hako

/// テストから取得結果を 1 件ずつ流し込める偽の Colima
@MainActor
private final class FakeColima {
    private var queued: [ColimaSnapshot] = []
    private var pending: CheckedContinuation<ColimaSnapshot, Never>?
    private(set) var fetchCount = 0
    var notifications: [(String, String)] = []
    var commands: [[String]] = []

    func nextSnapshot() async -> ColimaSnapshot {
        fetchCount += 1
        if !queued.isEmpty { return queued.removeFirst() }
        return await withCheckedContinuation { pending = $0 }
    }

    func feed(_ snapshot: ColimaSnapshot) {
        if let pending {
            self.pending = nil
            pending.resume(returning: snapshot)
        } else {
            queued.append(snapshot)
        }
    }

    var isWaiting: Bool { pending != nil }

    func backend() -> StatusStore.Backend {
        StatusStore.Backend(
            fetchSnapshot: { await self.nextSnapshot() },
            fetchStats: { [:] },
            fetchDiskUsage: { [] },
            colimaVersion: { nil },
            latestRelease: { _, _ in nil },
            run: { arguments in
                await MainActor.run { self.commands.append(arguments) }
                return Shell.Result(status: 0, stdout: "", stderr: "")
            },
            notify: { title, body in self.notifications.append((title, body)) }
        )
    }
}

@MainActor
final class StatusStoreTests: XCTestCase {
    private func web(running: Bool, status: String = "Up 1 minute") -> Container {
        Container(id: "web", name: "shop-web", image: "nginx", state: running ? "running" : "exited", status: status,
                  ports: [PortMapping(host: "8080", container: "80")], composeProject: "shop", composeService: "web")
    }

    private func snapshot(_ containers: [Container]) -> ColimaSnapshot {
        ColimaSnapshot(profile: "default", running: true, vmInfo: nil, containers: containers, composeProjects: [])
    }

    /// 非同期の処理が進んで条件を満たすまで待つ
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #file, line: UInt = #line) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), "条件を満たさないまま時間切れ", file: file, line: line)
    }

    func testRefreshAppliesSnapshot() async {
        let fake = FakeColima()
        let store = StatusStore(backend: fake.backend())
        store.refresh()
        fake.feed(snapshot([web(running: true)]))
        await waitUntil { store.snapshot != nil }
        XCTAssertEqual(store.snapshot?.containers.map(\.id), ["web"])
    }

    /// 操作前に始まった取得の結果で、操作後の状態を上書きしない
    func testSnapshotStartedBeforeOperationIsDiscarded() async {
        let fake = FakeColima()
        let store = StatusStore(backend: fake.backend())
        store.refresh()
        await waitUntil { fake.isWaiting }

        await store.run(message: "停止中…", arguments: ["docker", "stop", "shop-web"])
        XCTAssertEqual(fake.commands, [["docker", "stop", "shop-web"]])

        fake.feed(snapshot([web(running: true)]))   // 操作前に始まった取得(古い)
        await waitUntil { fake.fetchCount == 2 && fake.isWaiting }
        XCTAssertNil(store.snapshot)

        fake.feed(snapshot([web(running: false)]))  // 操作後の取得
        await waitUntil { store.snapshot != nil }
        XCTAssertEqual(store.snapshot?.containers.first?.isRunning, false)
    }

    func testUnexpectedStopAndUnhealthyAreNotified() async {
        let fake = FakeColima()
        let store = StatusStore(backend: fake.backend())
        fake.feed(snapshot([web(running: true)]))
        store.refresh()
        await waitUntil { store.snapshot != nil }

        fake.feed(snapshot([web(running: true, status: "Up 2 minutes (unhealthy)")]))
        store.refresh()
        await waitUntil { fake.notifications.count == 1 }

        fake.feed(snapshot([web(running: false)]))
        store.refresh()
        await waitUntil { fake.notifications.count == 2 }
        XCTAssertEqual(fake.notifications.map(\.0), ["コンテナが unhealthy です", "コンテナが停止しました"])
        XCTAssertEqual(fake.notifications.first?.1, "shop の web")
    }

    /// 自分の操作による変化は通知しないが、変化が無かった場合もその抑止を次へ持ち越さない
    func testOwnOperationSuppressesOnlyTheNextSnapshot() async {
        let fake = FakeColima()
        let store = StatusStore(backend: fake.backend())
        fake.feed(snapshot([web(running: true)]))
        store.refresh()
        await waitUntil { store.snapshot != nil }

        fake.feed(snapshot([web(running: true)]))  // 操作しても状態が変わらなかった
        await store.run(message: "削除中…", arguments: ["docker", "volume", "prune", "-f"])
        await waitUntil { fake.fetchCount == 2 }

        fake.feed(snapshot([web(running: false)])) // その後に勝手に落ちた
        // 操作後の取得が終わるまで refresh は無視されるので、3 回目の取得が始まるまで呼び続ける
        await waitUntil { store.refresh(); return fake.fetchCount >= 3 }
        await waitUntil { fake.notifications.count == 1 }
        XCTAssertEqual(fake.notifications.first?.0, "コンテナが停止しました")
    }

    func testRunIsIgnoredWhileBusy() async {
        let fake = FakeColima()
        let store = StatusStore(backend: fake.backend())
        async let first = store.run(message: "1", arguments: ["one"])
        async let second = store.run(message: "2", arguments: ["two"])
        let results = await [first, second]
        XCTAssertEqual(results.compactMap { $0 }.count, 1)
        XCTAssertEqual(fake.commands.count, 1)
    }

    func testColimaStartAndStopDoNotNotify() {
        let stopped = ColimaSnapshot(profile: "default", running: false, vmInfo: nil, containers: [], composeProjects: [])
        XCTAssertTrue(StatusStore.notifications(from: snapshot([web(running: true)]), to: stopped).isEmpty)
    }

    func testStoppedPublishedServiceWarning() {
        let initJob = Container(id: "init", name: "shop-init", image: "busybox", state: "exited", status: "Exited",
                                ports: [], composeProject: "shop", composeService: "init")
        XCTAssertFalse(snapshot([web(running: true), initJob]).hasStoppedPublishedService)
        let db = Container(id: "db", name: "shop-db", image: "postgres", state: "running", status: "Up",
                           ports: [], composeProject: "shop", composeService: "db")
        XCTAssertTrue(snapshot([web(running: false), db]).hasStoppedPublishedService)
        XCTAssertFalse(snapshot([web(running: false)]).hasStoppedPublishedService) // 全停止は警告しない
    }
}

@MainActor
final class EditorPreferencesTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "HakoTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testFallsBackToFirstInstalledEditor() {
        let editors = EditorPreferences(defaults: defaults(), isInstalled: { $0 == "com.microsoft.VSCode" })
        XCTAssertEqual(editors.installed.map(\.name), ["Visual Studio Code"])
        XCTAssertEqual(editors.selected.name, "Visual Studio Code")
    }

    func testSelectionSurvivesAndFallsBackWhenUninstalled() {
        var installed: Set<String> = ["dev.zed.Zed", "com.panic.Nova"]
        let editors = EditorPreferences(defaults: defaults(), isInstalled: { installed.contains($0) })
        editors.select(bundleID: "com.panic.Nova")
        XCTAssertEqual(editors.selected.name, "Nova")

        installed.remove("com.panic.Nova")
        XCTAssertTrue(editors.reload())
        XCTAssertEqual(editors.selected.name, "Zed")
        XCTAssertFalse(editors.reload()) // 変化が無ければ false
    }
}
