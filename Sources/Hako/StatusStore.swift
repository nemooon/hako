import Foundation
import Observation

/// Colima / Docker の状態を一手に持つ。メニューバーとメインウィンドウはここを読むだけで、
/// 取得や操作の実行もここを通す(状態のコピーを各 UI に持たせない)。
@MainActor @Observable
final class StatusStore {
    /// 外部コマンドへの依存。テストでは差し替える
    struct Backend {
        var fetchSnapshot: @Sendable () async -> ColimaSnapshot
        var fetchStats: @Sendable () async -> [String: ContainerStats]
        var fetchDiskUsage: @Sendable () async -> [DiskUsage]
        var colimaVersion: @Sendable () async -> String?
        var latestRelease: @Sendable (_ repo: String, _ current: String) async -> String?
        var run: @Sendable (_ arguments: [String]) async -> Shell.Result
        var notify: @MainActor (_ title: String, _ body: String) -> Void
        /// 新しいバージョンと比べる Hako 自身のバージョン(swift run の素の実行ファイルでは nil)
        var hakoVersion: String? = UpdateChecker.currentVersion

        /// HAKO_UPDATE_PREVIEW 付きで起動したときは、更新確認だけ見本の版を返す
        static var live: Backend {
            guard UpdatePreview.current != nil else { return real }
            var backend = real
            backend.hakoVersion = UpdatePreview.hakoVersion
            backend.latestRelease = { repo, current in
                guard let latest = UpdatePreview.release(for: repo)?.version else { return nil }
                return UpdateChecker.isNewer(latest, than: current) ? latest : nil
            }
            return backend
        }

        private static let real = Backend(
            fetchSnapshot: { await background { ColimaService.fetchSnapshot() } },
            fetchStats: { await background { ColimaService.fetchStats() } },
            fetchDiskUsage: { await background { ColimaService.fetchDiskUsage() } },
            colimaVersion: { await background(qos: .utility) { ColimaService.colimaVersion() } },
            latestRelease: { repo, current in await UpdateChecker.newerRelease(repo: repo, current: current) },
            run: { arguments in await Shell.exec(arguments) },
            notify: { title, body in StatusStore.postNotification(title: title, body: body) }
        )
    }

    // 直近の取得結果(メニューを開いた瞬間はこれで描画し、裏で更新する)
    private(set) var snapshot: ColimaSnapshot?
    private(set) var busyMessage: String?
    // コンテナごとの CPU/メモリ使用量(取得が遅いのでメニューやウィンドウを開いている間だけ更新)
    private(set) var statsByID: [String: ContainerStats] = [:]
    // ディスク使用量(取得が遅いのでメニューやウィンドウを開いたときだけ更新)
    private(set) var diskUsage: [DiskUsage] = []
    // colima CLI のバージョンと、Hako / colima の新しいバージョン(例: "0.2")
    private(set) var colimaVersion: String?
    private(set) var availableUpdate: String?
    private(set) var availableColimaUpdate: String?

    @ObservationIgnored private let backend: Backend
    // 実行中の取得。同じ種類の取得は重ねない
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var diskUsageTask: Task<Void, Never>?
    // 操作のたびに進める。操作前に始まった取得の結果で、操作後の状態を上書きしないために使う
    @ObservationIgnored private var generation = 0
    // 自分で実行した操作(stop など)による変化まで通知しないためのフラグ
    @ObservationIgnored private var suppressNextNotifications = false

    init(backend: Backend = .live) {
        self.backend = backend
    }

    /// 操作対象の colima プロファイル(docker の現在の context に対応)
    var colimaProfile: String { snapshot?.profile ?? "default" }

    var isBusy: Bool { busyMessage != nil }

    // MARK: - 取得

    func refresh() {
        guard busyMessage == nil, snapshotTask == nil else { return }
        let started = generation
        snapshotTask = Task {
            let snapshot = await backend.fetchSnapshot()
            snapshotTask = nil
            // 操作前に開始した取得結果は捨て、操作後の状態で取り直す
            guard started == generation else {
                refresh()
                return
            }
            apply(snapshot)
        }
    }

    func refreshStats() {
        guard busyMessage == nil, snapshot?.running == true, statsTask == nil else { return }
        let started = generation
        statsTask = Task {
            let stats = await backend.fetchStats()
            statsTask = nil
            guard started == generation, snapshot?.running == true else { return }
            assign(\.statsByID, stats)
        }
    }

    func refreshDiskUsage() {
        guard busyMessage == nil, snapshot?.running == true, diskUsageTask == nil else { return }
        let started = generation
        diskUsageTask = Task {
            let usage = await backend.fetchDiskUsage()
            diskUsageTask = nil
            guard started == generation, snapshot?.running == true else { return }
            assign(\.diskUsage, usage)
        }
    }

    /// 内訳が変わったはずの操作の後に、古いディスク使用量を「取得中」に戻して取り直す
    func reloadDiskUsage() {
        assign(\.diskUsage, [])
        refreshDiskUsage()
    }

    /// Hako と colima の新しいバージョンが公開されていれば記録する
    func checkForUpdates() async {
        if let current = backend.hakoVersion {
            assign(\.availableUpdate, await backend.latestRelease("nemooon/hako", current))
        }
        // colima はまずローカルのバージョンを取ってから最新と比較する
        let colima = await backend.colimaVersion()
        assign(\.colimaVersion, colima)
        if let colima {
            assign(\.availableColimaUpdate, await backend.latestRelease("abiosoft/colima", colima))
        }
    }

    /// アップデートウィンドウで確認・更新した結果をメニューバー側にも反映する
    func recordHakoUpdate(_ available: String?) {
        assign(\.availableUpdate, available)
    }

    func recordColimaUpdate(version: String?, available: String?) {
        assign(\.colimaVersion, version)
        assign(\.availableColimaUpdate, available)
    }

    private func apply(_ snapshot: ColimaSnapshot) {
        // 操作後の最初の取得で必ず消費する(変化が無かった場合に残ると、後の本物の変化を握りつぶす)
        let suppress = suppressNextNotifications
        suppressNextNotifications = false
        guard self.snapshot != snapshot else { return }
        if let old = self.snapshot, !suppress {
            for (title, body) in Self.notifications(from: old, to: snapshot) {
                backend.notify(title, body)
            }
        }
        self.snapshot = snapshot
        if !snapshot.running {
            assign(\.statsByID, [:])
            assign(\.diskUsage, [])
        }
    }

    /// @Observable は同じ値の代入でも変更として通知するため、変わったときだけ書き込む
    /// (stats の更新だけでメニューやウィンドウ全体が描き直されるのを防ぐ)
    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<StatusStore, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    // MARK: - 操作

    /// コマンドを実行し、終わったら状態を取り直す。別の操作中なら何もせず nil を返す
    @discardableResult
    func run(message: String, arguments: [String]) async -> Shell.Result? {
        guard busyMessage == nil else { return nil }
        generation += 1
        busyMessage = message
        let result = await backend.run(arguments)
        busyMessage = nil
        suppressNextNotifications = true // 自分の操作による変化は通知しない
        refresh()
        return result
    }

    // MARK: - 通知

    /// ポート公開しているコンテナが勝手に落ちたり unhealthy になったときの通知(タイトル, 本文)
    static func notifications(from old: ColimaSnapshot, to new: ColimaSnapshot) -> [(String, String)] {
        // colima 自体の起動/停止では全コンテナが一斉に変わるので対象外
        guard old.running, new.running else { return [] }

        let oldByID = Dictionary(old.containers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return new.containers.compactMap { container in
            guard !container.ports.isEmpty, let prev = oldByID[container.id] else { return nil }
            let label = container.composeService.flatMap { service in
                container.composeProject.map { "\($0) の \(service)" }
            } ?? container.name
            if prev.isRunning && !container.isRunning {
                return ("コンテナが停止しました", label)
            }
            if container.isRunning, container.isUnhealthy, !prev.isUnhealthy {
                return ("コンテナが unhealthy です", label)
            }
            return nil
        }
    }

    /// macOS 通知を出す(osascript 経由なのでバンドル化していなくても動く)
    static func postNotification(title: String, body: String) {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let script = "display notification \"\(escape(body))\" with title \"\(escape(title))\""
        Task { await Shell.runProgram("/usr/bin/osascript", ["-e", script]) }
    }
}

extension ColimaSnapshot {
    /// いずれかの compose プロジェクトが、稼働中なのにポート公開すべきコンテナが落ちている状態か
    /// (ポートなしの exited は cli や init 用サービスとみなして問題扱いしない)
    var hasStoppedPublishedService: Bool {
        guard running else { return false }
        let groups = Dictionary(grouping: containers.filter { $0.composeProject != nil }, by: { $0.composeProject! })
        return groups.values.contains { group in
            group.contains(where: \.isRunning) && group.contains { !$0.isRunning && !$0.ports.isEmpty }
        }
    }
}
