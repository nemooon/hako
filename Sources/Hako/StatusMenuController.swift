import AppKit
import Observation
import ServiceManagement

/// メニューバーのアイコンとメニュー。StatusStore の変化を監視して差分で描き直す
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let store: StatusStore
    private let commands: CommandCenter
    private let editors: EditorPreferences
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var openRefreshTimer: Timer?
    var openMainWindow: () -> Void = {}

    init(store: StatusStore, commands: CommandCenter, editors: EditorPreferences) {
        self.store = store
        self.commands = commands
        self.editors = editors
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        observeStore()
    }

    /// store を読んで描画し、読んだ値が変わったら描き直す
    private func observeStore() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStore() }
        }
    }

    /// store 以外(エディタ選択やログイン項目)の変化を反映する
    private func render() {
        updateIcon()
        sync(menu, with: buildEntries())
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        if editors.reload() { render() }
        store.refresh()
        store.refreshStats()
        store.refreshDiskUsage()
        // 開いている間は短い間隔でリアルタイム更新(差分適用なので開いたままでも安全)
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.store.refresh()
                self?.store.refreshStats()
            }
        }
        RunLoop.main.add(timer, forMode: .common) // メニュー追跡中も発火させる
        openRefreshTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        openRefreshTimer?.invalidate()
        openRefreshTimer = nil
    }

    // MARK: - アイコン

    private func updateIcon() {
        let symbolName: String
        let description: String
        var tint: NSColor?
        if store.isBusy {
            symbolName = "shippingbox.circle"
            description = "Colima: 処理中"
        } else if let snapshot = store.snapshot, snapshot.running {
            symbolName = "shippingbox.fill"
            if snapshot.hasStoppedPublishedService {
                description = "Colima: 実行中(停止中のサービスあり)"
                tint = .systemOrange
            } else {
                description = "Colima: 実行中"
            }
        } else {
            symbolName = "shippingbox"
            description = "Colima: 停止中"
        }

        let image: NSImage?
        if let tint {
            let config = NSImage.SymbolConfiguration(paletteColors: [tint])
            image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)?
                .withSymbolConfiguration(config)
        } else {
            image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
            image?.isTemplate = true
        }
        statusItem.button?.image = image
        statusItem.button?.toolTip = description
    }

    // MARK: - Menu model

    /// メニューのあるべき状態。NSMenu へは差分適用する
    struct MenuEntry {
        var isSeparator = false
        var title = ""
        var subtitle: String?
        var dot: NSColor?
        var icon: String?          // SF Symbol 名(dot より優先)
        var isDestructive = false  // 赤字+赤アイコン
        var isEnabled = false
        var action: Selector?
        var keyEquivalent = ""
        var representedObject: Any?
        var isAlternate = false    // ⌥ を押している間だけ直前の項目と入れ替わる
        var modifiers: NSEvent.ModifierFlags = []
        var isChecked = false      // チェックマーク付き(トグル項目用)
        var children: [MenuEntry]?

        static let separator = MenuEntry(isSeparator: true)

        static func info(_ title: String, subtitle: String? = nil, dot: NSColor? = nil) -> MenuEntry {
            MenuEntry(title: title, subtitle: subtitle, dot: dot)
        }

        static func action(
            _ title: String,
            _ action: Selector,
            icon: String? = nil,
            destructive: Bool = false,
            enabled: Bool = true,
            represented: Any? = nil,
            key: String = "",
            modifiers: NSEvent.ModifierFlags = []
        ) -> MenuEntry {
            MenuEntry(
                title: title,
                icon: icon,
                isDestructive: destructive,
                isEnabled: enabled,
                action: action,
                keyEquivalent: key,
                representedObject: represented,
                modifiers: modifiers
            )
        }
    }

    /// メニュー項目に載せるコンテナ操作
    private struct ContainerCommand {
        let name: String
        let operation: MainWindowAction.ContainerOperation
    }

    /// メニュー項目に載せる compose プロジェクト操作
    private struct ProjectCommand {
        let project: ComposeProject
        let operation: MainWindowAction.ProjectOperation
    }

    func buildEntries() -> [MenuEntry] {
        let open = MenuEntry.action("Hako を開く…", #selector(openMainWindowAction), icon: "macwindow", key: "0", modifiers: .command)
        let quit = MenuEntry.action("Hako を終了", #selector(quitApp), key: "q", modifiers: .command)

        if let busyMessage = store.busyMessage {
            return [open, .separator, .info(busyMessage), .separator, quit]
        }
        guard let snapshot = store.snapshot else {
            return [open, .separator, .info("状態を確認中…"), .separator, quit]
        }

        var entries = [open, .separator, colimaStatusEntry(snapshot)]
        if snapshot.running {
            entries.append(diskUsageEntry())
            entries.append(.separator)
            entries += containerEntries(snapshot)
        }
        entries.append(.separator)
        if let version = store.availableUpdate {
            var update = MenuEntry.action(
                "Hako の新しいバージョン \(version) があります",
                #selector(openUpdates),
                icon: "arrow.down.circle"
            )
            update.subtitle = "クリックしてアップデート"
            entries.append(update)
        }
        if let version = store.availableColimaUpdate {
            var update = MenuEntry.action(
                "Colima の新しいバージョン \(version) があります",
                #selector(openUpdates),
                icon: "arrow.down.circle"
            )
            update.subtitle = "クリックしてアップデート"
            entries.append(update)
        }
        entries.append(settingsEntry())
        entries.append(quit)
        return entries
    }

    /// 「ディスク使用量」サブメニュー(内訳の表示+お掃除アクション)
    private func diskUsageEntry() -> MenuEntry {
        var entry = MenuEntry.info("ディスク使用量")
        entry.isEnabled = true

        var children: [MenuEntry] = []
        if store.diskUsage.isEmpty {
            children.append(.info("取得中…"))
        } else {
            for usage in store.diskUsage {
                children.append(.info("\(usage.label): \(usage.size)", subtitle: "回収可能 \(usage.reclaimable)"))
            }
        }
        children.append(.separator)
        children.append(.action("未使用リソースを整理…", #selector(openCleanup), icon: "externaldrive"))
        children.append(.action("未使用の匿名ボリュームを削除", #selector(pruneVolumes), icon: "trash", destructive: true))
        entry.children = children
        return entry
    }

    /// 「設定」サブメニュー(ログイン時に起動+エディタ選択)
    private func settingsEntry() -> MenuEntry {
        var entry = MenuEntry.info("設定")
        entry.isEnabled = true

        var children: [MenuEntry] = [launchAtLoginEntry(), .separator]
        children.append(.info("プロジェクトを開くエディタ"))
        if editors.installed.isEmpty {
            children.append(.info("対応エディタが見つかりません"))
        } else {
            let selected = editors.selected
            for editor in editors.installed {
                var item = MenuEntry.action(editor.name, #selector(selectEditor(_:)), represented: editor.bundleID)
                item.isChecked = editor.bundleID == selected.bundleID
                children.append(item)
            }
        }
        entry.children = children
        return entry
    }

    /// 「ログイン時に起動」トグル。.app バンドルとして動いているときだけ有効
    /// (swift run の素の実行ファイルでは SMAppService が使えない)
    private func launchAtLoginEntry() -> MenuEntry {
        let isBundled = Bundle.main.bundleURL.pathExtension == "app"
        var entry = MenuEntry.action("ログイン時に起動", #selector(toggleLaunchAtLogin), enabled: isBundled)
        entry.isChecked = isBundled && SMAppService.mainApp.status == .enabled
        return entry
    }

    /// 「Colima: 実行中/停止中」+ 起動・再起動・停止のサブメニュー(状態に応じて disabled)
    /// 実行中は 2 行目に VM の割り当て(CPU/メモリ/ディスク)を出す
    private func colimaStatusEntry(_ snapshot: ColimaSnapshot) -> MenuEntry {
        let running = snapshot.running
        // 例: "v0.9.1 ・ CPU 2 ・ メモリ 12GB ・ ディスク 100GB"(停止中は "v0.9.1" のみ)
        var subtitleParts: [String] = []
        if let colimaVersion = store.colimaVersion {
            subtitleParts.append("v\(colimaVersion)")
        }
        if let vmInfo = snapshot.vmInfo {
            subtitleParts.append(vmInfo)
        }
        var entry = MenuEntry.info(
            running ? "Colima: 実行中" : "Colima: 停止中",
            subtitle: subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: " ・ ")
        )
        entry.isEnabled = true
        entry.children = [
            .action("起動", #selector(startColima), icon: "play.fill", enabled: !running),
            .action("再起動", #selector(restartColima), icon: "arrow.clockwise", enabled: running),
            .action("停止", #selector(stopColima), icon: "stop.fill", enabled: running),
        ]
        return entry
    }

    /// compose プロジェクト(稼働中・停止中とも)と単体コンテナを 1 つのリストで表示する
    private func containerEntries(_ snapshot: ColimaSnapshot) -> [MenuEntry] {
        // 起動中コンテナを compose プロジェクトごとにまとめ、単体コンテナは分けておく
        var composeGroups: [String: [Container]] = [:]
        var standalone: [Container] = []
        for container in snapshot.containers {
            if let project = container.composeProject {
                composeGroups[project, default: []].append(container)
            } else if container.isRunning || !container.ports.isEmpty {
                // 単体コンテナは起動中のもの+ポート設定のある停止中のもの
                // (ポートなしの exited は使い捨てとみなして出さない)
                standalone.append(container)
            }
        }

        // compose ls に出ないが起動中コンテナにはいる、というケースも拾う
        let knownNames = Set(snapshot.composeProjects.map(\.name))
        let orphanProjects = composeGroups.keys
            .filter { !knownNames.contains($0) }
            .map { ComposeProject(name: $0, status: "", configFiles: []) }
        let projects = (snapshot.composeProjects + orphanProjects).sorted { $0.name < $1.name }

        if projects.isEmpty && standalone.isEmpty {
            return [.info("コンテナはありません")]
        }

        let editorName = editors.selected.name
        var entries = projects.map { composeEntry(project: $0, group: composeGroups[$0.name] ?? [], editorName: editorName) }
        entries += standalone.sorted(by: Container.runningFirst).map(standaloneEntry(for:))
        return entries
    }

    private func standaloneEntry(for container: Container) -> MenuEntry {
        // 1 行目: コンテナ名 / 2 行目: 稼働状況 ・ イメージ ・ ポート
        // (長さの安定している時刻を先頭に置いて、行の頭を揃える)
        var entry = MenuEntry.info(
            container.name,
            subtitle: containerSubtitle(container),
            dot: container.isRunning ? .systemGreen : .systemGray
        )
        entry.isEnabled = true
        entry.children = containerActionChildren(container)
        return entry
    }

    private func containerSubtitle(_ container: Container) -> String {
        var parts = [container.friendlyStatus, container.shortImage]
        if !container.ports.isEmpty {
            parts.append(container.ports.map(\.display).joined(separator: ", "))
        }
        return parts.joined(separator: " ・ ")
    }

    /// コンテナ単体の操作メニュー(状態に応じて disabled)
    private func containerActionChildren(_ container: Container) -> [MenuEntry] {
        var children: [MenuEntry] = []

        // CPU / メモリ使用量(取得済みの場合のみ)
        if container.isRunning, let stats = store.statsByID[container.id] {
            var statsEntry = MenuEntry.info("CPU \(stats.cpu) ・ メモリ \(stats.mem)")
            statsEntry.icon = "gauge"
            children.append(statsEntry)
            children.append(.separator)
        }

        // 公開ポートをブラウザで開く(⌥ で URL コピーに切り替わる)
        for port in container.ports {
            children.append(.action(
                "localhost:\(port.host) を開く", #selector(openURL(_:)),
                icon: "globe",
                enabled: container.isRunning,
                represented: URL(string: "http://localhost:\(port.host)")
            ))
            var copy = MenuEntry.action(
                "localhost:\(port.host) をコピー", #selector(copyText(_:)),
                icon: "doc.on.doc",
                represented: "localhost:\(port.host)"
            )
            copy.isAlternate = true
            copy.modifiers = .option
            children.append(copy)
        }
        if !container.ports.isEmpty {
            children.append(.separator)
        }

        func command(_ operation: MainWindowAction.ContainerOperation) -> ContainerCommand {
            ContainerCommand(name: container.name, operation: operation)
        }
        let run = #selector(runContainerCommand(_:))
        children.append(.action("ターミナルで接続", run, icon: "terminal", enabled: container.isRunning, represented: command(.shell)))
        children.append(.action("ログを見る", run, icon: "text.alignleft", represented: command(.logs)))
        children.append(.action("名前をコピー", #selector(copyText(_:)), icon: "doc.on.doc", represented: container.name))
        children.append(.separator)
        children.append(.action("起動", run, icon: "play.fill", enabled: !container.isRunning, represented: command(.start)))
        children.append(.action("再起動", run, icon: "arrow.clockwise", enabled: container.isRunning, represented: command(.restart)))
        children.append(.action("停止", run, icon: "stop.fill", enabled: container.isRunning, represented: command(.stop)))
        children.append(.separator)
        children.append(.action("破棄", run, icon: "trash", destructive: true, represented: command(.remove)))
        return children
    }

    private func composeEntry(project: ComposeProject, group: [Container], editorName: String) -> MenuEntry {
        let runningCount = group.filter(\.isRunning).count

        // 1 行目: プロジェクト名 / 2 行目: compose ・ コンテナ数 ・ 公開ポート
        var subtitleParts = ["compose", "\(group.count) コンテナ"]
        var seenPorts = Set<String>()
        let allPorts = group.flatMap(\.hostPorts).filter { seenPorts.insert($0).inserted }
        if !allPorts.isEmpty {
            subtitleParts.append(allPorts.joined(separator: ", "))
        }

        // 全停止ならグレー。稼働中でも、ポートを公開するはずのコンテナが止まっていればオレンジ
        // (ポートなしの exited は cli や init 用サービスとみなして問題扱いしない)
        let dotColor: NSColor
        if runningCount == 0 {
            dotColor = .systemGray
        } else if group.contains(where: { !$0.isRunning && !$0.hostPorts.isEmpty }) {
            dotColor = .systemOrange
        } else {
            dotColor = .systemGreen
        }
        var entry = MenuEntry.info(project.name, subtitle: subtitleParts.joined(separator: " ・ "), dot: dotColor)
        entry.isEnabled = true

        // 1 行目: サービス名 / 2 行目: 稼働状況 ・ イメージ ・ ポート
        var children: [MenuEntry] = group.sorted(by: Container.runningFirst).map { container in
            var child = MenuEntry.info(
                container.composeService ?? container.name,
                subtitle: containerSubtitle(container),
                dot: container.isRunning ? .systemGreen : .systemGray
            )
            child.isEnabled = true
            child.children = containerActionChildren(container)
            return child
        }
        children.append(.separator)

        func command(_ operation: MainWindowAction.ProjectOperation) -> ProjectCommand {
            ProjectCommand(project: project, operation: operation)
        }
        let run = #selector(runProjectCommand(_:))
        children.append(.action("\(editorName) で開く", run, icon: "curlybraces",
                                enabled: project.directory != nil, represented: command(.editor)))
        children.append(.separator)
        children.append(.action("起動", run, icon: "play.fill",
                                enabled: runningCount < group.count || group.isEmpty, represented: command(.start)))
        children.append(.action("再起動", run, icon: "arrow.clockwise", enabled: runningCount > 0, represented: command(.restart)))
        children.append(.action("停止", run, icon: "stop.fill", enabled: runningCount > 0, represented: command(.stop)))
        children.append(.separator)
        children.append(.action("破棄", run, icon: "trash", destructive: true, represented: command(.remove)))

        entry.children = children
        return entry
    }

    // MARK: - Menu sync

    /// あるべき状態を NSMenu に差分適用する。既存アイテムを使い回すので、
    /// 開いているメニューを更新してもリサイズ(→下に余白)が起きない
    private func sync(_ menu: NSMenu, with entries: [MenuEntry]) {
        for (index, entry) in entries.enumerated() {
            if index < menu.items.count {
                let item = menu.items[index]
                if item.isSeparatorItem == entry.isSeparator {
                    apply(entry, to: item)
                } else {
                    menu.removeItem(at: index)
                    menu.insertItem(makeItem(entry), at: index)
                }
            } else {
                menu.addItem(makeItem(entry))
            }
        }
        while menu.items.count > entries.count {
            menu.removeItem(at: menu.items.count - 1)
        }
    }

    private func makeItem(_ entry: MenuEntry) -> NSMenuItem {
        if entry.isSeparator {
            return .separator()
        }
        let item = NSMenuItem()
        apply(entry, to: item)
        return item
    }

    private func apply(_ entry: MenuEntry, to item: NSMenuItem) {
        guard !entry.isSeparator else { return }
        if item.title != entry.title {
            item.title = entry.title
        }
        if item.subtitle != entry.subtitle {
            item.subtitle = entry.subtitle
        }
        if let icon = entry.icon {
            item.image = Self.actionIcon(icon, color: entry.isDestructive ? .systemRed : nil)
        } else {
            item.image = entry.dot.flatMap { Self.statusDot($0) }
        }
        if #available(macOS 27.0, *) {
            // macOS 27 は SF Symbols を標準で隠すため、状態を伝える ● は常に表示する。
            // 項目の使い回し時には通常の画像表示ルールへ戻す。
            item.preferredImageVisibility = entry.dot != nil && entry.icon == nil ? .visible : .automatic
        }
        if entry.isDestructive {
            item.attributedTitle = NSAttributedString(string: entry.title, attributes: [
                .foregroundColor: NSColor.systemRed,
                .font: NSFont.menuFont(ofSize: 0),
            ])
        } else {
            item.attributedTitle = nil // 使い回し時に赤字が残らないようクリア
        }
        item.isEnabled = entry.isEnabled
        item.action = entry.action
        item.target = entry.action != nil ? self : nil
        item.keyEquivalent = entry.keyEquivalent
        item.keyEquivalentModifierMask = entry.modifiers
        item.isAlternate = entry.isAlternate
        item.state = entry.isChecked ? .on : .off
        item.representedObject = entry.representedObject

        if let children = entry.children {
            let submenu: NSMenu
            if let existing = item.submenu {
                submenu = existing
            } else {
                submenu = NSMenu()
                submenu.autoenablesItems = false
                item.submenu = submenu
            }
            sync(submenu, with: children)
        } else {
            item.submenu = nil
        }
    }

    /// アクション項目用のアイコン。色を渡さなければテンプレート画像(ハイライトに追従)
    private static func actionIcon(_ symbolName: String, color: NSColor?) -> NSImage? {
        var config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        if let color {
            config = config.applying(.init(paletteColors: [color]))
        }
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    /// ステータス表示用の小さい ●
    private static func statusDot(_ color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
            .applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    // MARK: - Actions

    @objc private func openMainWindowAction() { openMainWindow() }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func startColima() { commands.startColima() }
    @objc private func restartColima() { commands.restartColima() }
    @objc private func stopColima() { commands.stopColima() }
    @objc private func openCleanup() { commands.openCleanup() }
    @objc private func openUpdates() { commands.openUpdates() }
    @objc private func pruneVolumes() { commands.pruneVolumes() }

    @objc private func runContainerCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? ContainerCommand else { return }
        commands.run(command.operation, container: command.name)
    }

    @objc private func runProjectCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? ProjectCommand else { return }
        commands.run(command.operation, project: command.project)
    }

    @objc private func selectEditor(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        editors.select(bundleID: bundleID)
        render()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            commands.showError(command: "ログイン項目の変更", detail: error.localizedDescription)
        }
        render()
    }

    @objc private func openURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyText(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
