import Foundation
import Observation

/// アップデートウィンドウの 1 欄(Hako / Colima)の状態
struct UpdateItem: Equatable {
    enum Phase: Equatable {
        case checking
        case upToDate
        case available
        case updating
        case installed
        case unavailable(String) // 理由
    }

    var phase: Phase = .checking
    var current: String?
    var latest: String?
    var notes = ""
    var error: String?
}

/// アップデートウィンドウの状態。確認と更新を行い、結果をメニューバー側(StatusStore)にも反映する
@MainActor @Observable
final class UpdateModel {
    struct Backend {
        var latestRelease: (_ repo: String) async -> UpdateChecker.Release?
        var hakoVersion: String?
        var hakoAppPath: String?
        var colimaVersion: () async -> String?
        var updater: HomebrewUpdater?

        static func live() -> Backend {
            let bundle = Bundle.main.bundleURL
            return Backend(
                latestRelease: { await UpdateChecker.latestRelease(repo: $0) },
                hakoVersion: UpdateChecker.currentVersion,
                hakoAppPath: bundle.pathExtension == "app" ? bundle.path : nil,
                colimaVersion: { await background(qos: .utility) { ColimaService.colimaVersion() } },
                updater: HomebrewUpdater.live()
            )
        }
    }

    static let hakoRepo = "nemooon/hako"
    static let colimaRepo = "abiosoft/colima"

    private(set) var hako = UpdateItem()
    private(set) var colima = UpdateItem()

    @ObservationIgnored private let backend: Backend
    @ObservationIgnored private let store: StatusStore

    init(backend: Backend, store: StatusStore) {
        self.backend = backend
        self.store = store
    }

    var isUpdating: Bool { hako.phase == .updating || colima.phase == .updating }

    /// 画面に出す「実行するコマンド」
    func commands(for package: UpdatePackage) -> [String] {
        HomebrewUpdater.commands(for: package, appPath: backend.hakoAppPath ?? "/Applications/Hako.app")
    }

    // MARK: - 確認

    func refresh() async {
        guard !isUpdating else { return }
        hako = UpdateItem()
        colima = UpdateItem()
        async let pendingHakoRelease = backend.latestRelease(Self.hakoRepo)
        async let pendingColimaRelease = backend.latestRelease(Self.colimaRepo)
        async let colimaCurrent = backend.colimaVersion()

        let hakoRelease = await pendingHakoRelease
        hako = await check(.hako, current: backend.hakoVersion, release: hakoRelease,
                           notRunnable: backend.hakoAppPath == nil ? ".app として動いていないため、アップデートできません" : nil)
        if hakoRelease != nil {
            store.recordHakoUpdate(newer(hako))
        }

        let current = await colimaCurrent
        let colimaRelease = await pendingColimaRelease
        colima = await check(.colima, current: current, release: colimaRelease,
                             notRunnable: current == nil ? "Colima が見つかりません" : nil)
        if colimaRelease != nil {
            store.recordColimaUpdate(version: current, available: newer(colima))
        }
    }

    /// latest が current より新しければ latest(どちらか不明なら nil)
    private func newer(_ item: UpdateItem) -> String? {
        guard let latest = item.latest, let current = item.current else { return nil }
        return UpdateChecker.isNewer(latest, than: current) ? latest : nil
    }

    /// 確認結果から欄の状態を決める。対象外の理由は spec の順(確認失敗 → 実行環境 → 最新 → Homebrew)で判定する
    private func check(_ package: UpdatePackage, current: String?, release: UpdateChecker.Release?,
                       notRunnable: String?) async -> UpdateItem {
        var item = UpdateItem(current: current, latest: release?.version, notes: release?.notes ?? "")
        if release == nil {
            item.phase = .unavailable("新しいバージョンを確認できませんでした")
        } else if let notRunnable {
            item.phase = .unavailable(notRunnable)
        } else if newer(item) == nil {
            item.phase = .upToDate
        } else if let updater = backend.updater {
            item.phase = await updater.installedVersion(package) == nil
                ? .unavailable(UpdateError.notInstalledByHomebrew.message)
                : .available
        } else {
            item.phase = .unavailable("Homebrew が見つかりません")
        }
        return item
    }

    // MARK: - 更新

    func update(_ package: UpdatePackage) async {
        guard !isUpdating, let updater = backend.updater else { return }
        var item = package == .hako ? hako : colima
        guard item.phase == .available, let latest = item.latest else { return }

        item.phase = .updating
        item.error = nil
        set(package, item)
        do {
            try await updater.upgrade(package, to: latest, appPath: backend.hakoAppPath)
            item.phase = .installed
            if package == .colima {
                item.current = latest
                store.recordColimaUpdate(version: latest, available: nil)
            } else {
                store.recordHakoUpdate(nil)
            }
        } catch {
            item.phase = .available
            item.error = (error as? UpdateError)?.message ?? error.localizedDescription
        }
        set(package, item)
    }

    private func set(_ package: UpdatePackage, _ item: UpdateItem) {
        switch package {
        case .hako: hako = item
        case .colima: colima = item
        }
    }
}
