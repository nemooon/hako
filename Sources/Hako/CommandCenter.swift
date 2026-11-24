import AppKit

/// メニューバーとメインウィンドウの両方から呼ぶ操作。確認ダイアログとエラー表示もここで共有する
@MainActor
final class CommandCenter {
    private let store: StatusStore
    private let editors: EditorPreferences
    /// 整理画面はウィンドウ管理側(AppDelegate)が持つ
    var openCleanup: () -> Void = {}
    /// アップデートウィンドウも同様
    var openUpdates: () -> Void = {}
    /// ログウィンドウも同様(引数はコンテナ名)
    var openLogs: (String) -> Void = { _ in }

    init(store: StatusStore, editors: EditorPreferences) {
        self.store = store
        self.editors = editors
    }

    /// メインウィンドウからの操作
    func perform(_ action: MainWindowAction) {
        if case .refresh = action {
            store.refresh()
            store.refreshStats()
            store.refreshDiskUsage()
            return
        }
        // ログは読むだけなので、再起動などの処理中でも開けるようにする(起動の様子を見たい場面が多い)
        if case .container(let id, .logs) = action {
            if let container = store.snapshot?.containers.first(where: { $0.id == id }) {
                openLogs(container.name)
            }
            return
        }
        guard !store.isBusy else { return }
        switch action {
        case .refresh: break
        case .cleanup: openCleanup()
        case .startColima: startColima()
        case .restartColima: restartColima()
        case .stopColima: stopColima()
        case .switchProfile(let name): switchProfile(name)
        case .container(let id, let operation):
            guard let container = store.snapshot?.containers.first(where: { $0.id == id }) else { return }
            run(operation, container: container.name)
        case .project(let name, let operation):
            guard let project = store.snapshot?.composeProjects.first(where: { $0.name == name }) else { return }
            run(operation, project: project)
        }
    }

    // MARK: - Colima

    func startColima() {
        execute("Colima を起動中…", ["colima", "start", "--profile", store.colimaProfile])
    }

    /// 別の操作の処理中なら何もせず false を返す(呼び出し側が黙って閉じないように)
    @discardableResult
    func restartColima() -> Bool {
        guard !store.isBusy else { return false }
        execute("Colima を再起動中…", ["colima", "restart", "--profile", store.colimaProfile])
        return true
    }

    func stopColima() {
        execute("Colima を停止中…", ["colima", "stop", "--profile", store.colimaProfile])
    }

    /// 操作対象のプロファイルを切り替える。docker context ごと切り替えるので、ターミナルの docker も同じ VM を向く。
    /// 実行中なら context を切り替えるだけ、停止中なら起動する(colima start が context も切り替える)
    func switchProfile(_ name: String) {
        guard !store.isBusy,
              let snapshot = store.snapshot,
              let profile = snapshot.profiles.first(where: { $0.name == name }),
              !(snapshot.isColimaContext && name == snapshot.profile)
        else { return }
        if profile.running {
            execute("プロファイル \(name) に切り替え中…", ["docker", "context", "use", profile.dockerContext])
        } else {
            execute("プロファイル \(name) を起動中…", ["colima", "start", "--profile", name])
        }
    }

    // MARK: - コンテナ / compose

    func run(_ operation: MainWindowAction.ContainerOperation, container name: String) {
        switch operation {
        case .start:
            execute("\(name) を起動中…", ["docker", "start", name])
        case .restart:
            execute("\(name) を再起動中…", ["docker", "restart", name])
        case .stop:
            execute("\(name) を停止中…", ["docker", "stop", name])
        case .remove:
            guard confirm(
                title: "\(name) を破棄しますか?",
                message: "docker rm -f を実行します。コンテナが削除され、一覧から消えます(ボリュームは残ります)。",
                button: "破棄"
            ) else { return }
            execute("\(name) を破棄中…", ["docker", "rm", "-f", name])
        case .logs:
            openLogs(name)
        case .shell:
            // bash があれば bash、なければ sh
            openInTerminal("docker exec -it \(Shell.quote(name)) /bin/sh -c '[ -x /bin/bash ] && exec /bin/bash || exec /bin/sh'")
        }
    }

    func run(_ operation: MainWindowAction.ProjectOperation, project: ComposeProject) {
        let name = project.name
        switch operation {
        case .start:
            execute("\(name) を起動中…", project.upArguments)
        case .restart:
            execute("\(name) を再起動中…", ["docker", "compose", "-p", name, "restart"])
        case .stop:
            execute("\(name) を停止中…", ["docker", "compose", "-p", name, "stop"])
        case .remove:
            // コンテナごと削除されて一覧からも消えるので、確認を挟む
            guard confirm(
                title: "\(name) を破棄しますか?",
                message: "docker compose down を実行します。コンテナとネットワークが削除され、このプロジェクトは一覧から消えます(ボリュームは残ります)。",
                button: "破棄"
            ) else { return }
            execute("\(name) を破棄中…", ["docker", "compose", "-p", name, "down"])
        case .editor:
            guard let directory = project.directory else { return }
            openInEditor(path: directory)
        }
    }

    func pruneVolumes() {
        guard confirm(
            title: "未使用の匿名ボリュームを削除しますか?",
            message: "docker volume prune を実行します。どのコンテナにも使われていない匿名ボリュームが削除されます。DBなどのデータも失われ、元に戻せません(名前付きボリュームは残ります)。",
            button: "削除"
        ) else { return }
        Task {
            await executeAndReport("未使用ボリュームを削除中…", ["docker", "volume", "prune", "-f"])
            store.reloadDiskUsage()
        }
    }

    // MARK: - 外部アプリ

    func openInEditor(path: String) {
        let editor = editors.selected
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleID) else {
            showError(command: "\(editor.name) で開く", detail: "\(editor.name) が見つかりませんでした。「設定 > プロジェクトを開くエディタ」で選び直してください。")
            return
        }
        Task {
            do {
                _ = try await NSWorkspace.shared.open(
                    [URL(fileURLWithPath: path, isDirectory: true)],
                    withApplicationAt: appURL,
                    configuration: NSWorkspace.OpenConfiguration()
                )
            } catch {
                showError(command: "\(editor.name) で開く", detail: error.localizedDescription)
            }
        }
    }

    /// ログウィンドウの「ターミナルで開く」から呼ぶ
    func openLogsInTerminal(container name: String) {
        openInTerminal("docker logs -f --tail 200 \(Shell.quote(name))")
    }

    /// Terminal.app で新しいウインドウを開いてコマンドを実行する
    func openInTerminal(_ command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        Task {
            let result = await Shell.runProgram("/usr/bin/osascript", ["-e", script])
            if result.status != 0 {
                showError(command: "osascript", detail: result.stderr)
            }
        }
    }

    // MARK: - ダイアログ

    /// 破棄系アクションの確認ダイアログ。OK なら true
    func confirm(title: String, message: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "キャンセル")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func showError(command: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "コマンドが失敗しました"
        alert.informativeText = "\(command)\n\n\(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - 実行

    private func execute(_ message: String, _ arguments: [String]) {
        Task { await executeAndReport(message, arguments) }
    }

    private func executeAndReport(_ message: String, _ arguments: [String]) async {
        guard let result = await store.run(message: message, arguments: arguments) else { return }
        if result.status != 0 {
            showError(command: Shell.display(arguments), detail: result.stderr)
        }
    }
}
