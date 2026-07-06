import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    // 直近の取得結果(メニューを開いた瞬間はこれで描画し、裏で更新する)
    private var snapshot: ColimaSnapshot?
    private var busyMessage: String?
    private var refreshTimer: Timer?
    private var openRefreshTimer: Timer?
    // 自分で実行した操作(stop など)の結果まで通知しないためのフラグ
    private var suppressNotificationsOnce = false
    // コンテナごとの CPU/メモリ使用量(取得が遅いのでメニューを開いている間だけ更新)
    private var statsByID: [String: ContainerStats] = [:]
    private var isFetchingStats = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        updateIcon()
        rebuildMenu()
        refresh()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        // スリープ復帰時は即リフレッシュ(次のポーリングを待たない)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func didWake() {
        refresh()
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        fetchStats()
        // 開いている間は短い間隔でリアルタイム更新(差分適用なので開いたままでも安全)
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
            self?.fetchStats()
        }
        RunLoop.main.add(timer, forMode: .common) // メニュー追跡中も発火させる
        openRefreshTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        openRefreshTimer?.invalidate()
        openRefreshTimer = nil
    }

    // MARK: - State

    private func refresh() {
        guard busyMessage == nil else { return } // colima 操作中はポーリングしない
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = ColimaService.fetchSnapshot()
            DispatchQueue.main.async {
                guard let self, self.snapshot != snapshot else { return }
                if let old = self.snapshot {
                    self.notifyStateChanges(from: old, to: snapshot)
                }
                self.snapshot = snapshot
                self.updateIcon()
                self.rebuildMenu()
            }
        }
    }

    private func fetchStats() {
        guard snapshot?.running == true, !isFetchingStats else { return }
        isFetchingStats = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let stats = ColimaService.fetchStats()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isFetchingStats = false
                guard self.statsByID != stats else { return }
                self.statsByID = stats
                self.rebuildMenu()
            }
        }
    }

    /// ポート公開しているコンテナが勝手に落ちたり unhealthy になったら通知する
    private func notifyStateChanges(from old: ColimaSnapshot, to new: ColimaSnapshot) {
        if suppressNotificationsOnce {
            suppressNotificationsOnce = false
            return
        }
        // colima 自体の起動/停止では全コンテナが一斉に変わるので対象外
        guard old.running, new.running else { return }

        let oldByID = Dictionary(uniqueKeysWithValues: old.containers.map { ($0.id, $0) })
        for container in new.containers {
            guard !container.ports.isEmpty, let prev = oldByID[container.id] else { continue }

            let label: String
            if let service = container.composeService, let project = container.composeProject {
                label = "\(project) の \(service)"
            } else {
                label = container.name
            }

            if prev.isRunning && !container.isRunning {
                notify(title: "コンテナが停止しました", body: label)
            } else if container.isRunning,
                      container.status.contains("unhealthy"),
                      !prev.status.contains("unhealthy") {
                notify(title: "コンテナが unhealthy です", body: label)
            }
        }
    }

    /// macOS 通知を出す(osascript 経由なのでバンドル化していなくても動く)
    private func notify(title: String, body: String) {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let script = "display notification \"\(escape(body))\" with title \"\(escape(title))\""
        DispatchQueue.global(qos: .utility).async {
            Shell.runProgram("/usr/bin/osascript", ["-e", script])
        }
    }

    private func updateIcon() {
        let symbolName: String
        let description: String
        var tint: NSColor?
        if busyMessage != nil {
            symbolName = "shippingbox.circle"
            description = "Colima: 処理中"
        } else if snapshot?.running == true {
            symbolName = "shippingbox.fill"
            if hasWarning() {
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

    /// いずれかの compose プロジェクトがオレンジ状態(稼働中なのにポート公開すべき
    /// コンテナが落ちている)かどうか
    private func hasWarning() -> Bool {
        guard let snapshot, snapshot.running else { return false }
        var groups: [String: [Container]] = [:]
        for container in snapshot.containers {
            if let project = container.composeProject {
                groups[project, default: []].append(container)
            }
        }
        return groups.values.contains { group in
            group.contains(where: \.isRunning)
                && group.contains { !$0.isRunning && !$0.ports.isEmpty }
        }
    }

    // MARK: - Menu model

    /// メニューのあるべき状態。NSMenu へは差分適用する
    private struct MenuEntry {
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
            key: String = ""
        ) -> MenuEntry {
            MenuEntry(
                title: title,
                icon: icon,
                isDestructive: destructive,
                isEnabled: enabled,
                action: action,
                keyEquivalent: key,
                representedObject: represented
            )
        }
    }

    private func rebuildMenu() {
        sync(menu, with: buildEntries())
    }

    private func buildEntries() -> [MenuEntry] {
        let quit = MenuEntry.action("Colima UI を終了", #selector(quitApp), key: "q")

        if let busyMessage {
            return [.info(busyMessage), .separator, quit]
        }
        guard let snapshot else {
            return [.info("状態を確認中…"), .separator, quit]
        }

        var entries = [colimaStatusEntry(snapshot)]
        if snapshot.running {
            entries.append(.separator)
            entries += containerEntries(snapshot)
        }
        entries.append(.separator)
        entries.append(launchAtLoginEntry())
        entries.append(quit)
        return entries
    }

    /// 「ログイン時に起動」トグル。.app バンドルとして動いているときだけ有効
    /// (swift run の素の実行ファイルでは SMAppService が使えない)
    private func launchAtLoginEntry() -> MenuEntry {
        let isBundled = Bundle.main.bundleURL.pathExtension == "app"
        var entry = MenuEntry.action(
            "ログイン時に起動",
            #selector(toggleLaunchAtLogin),
            enabled: isBundled
        )
        entry.isChecked = isBundled && SMAppService.mainApp.status == .enabled
        return entry
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
            showError(command: "ログイン項目の変更", detail: error.localizedDescription)
        }
        rebuildMenu()
    }

    /// 「Colima: 実行中/停止中」+ 起動・再起動・停止のサブメニュー(状態に応じて disabled)
    /// 実行中は 2 行目に VM の割り当て(CPU/メモリ/ディスク)を出す
    private func colimaStatusEntry(_ snapshot: ColimaSnapshot) -> MenuEntry {
        let running = snapshot.running
        var entry = MenuEntry.info(running ? "Colima: 実行中" : "Colima: 停止中", subtitle: snapshot.vmInfo)
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

        var entries = projects.map { composeEntry(project: $0, group: composeGroups[$0.name] ?? []) }

        // 起動中 → 名前順で並べる
        let sortedStandalone = standalone.sorted { ($0.isRunning ? 0 : 1, $0.name) < ($1.isRunning ? 0 : 1, $1.name) }
        entries += sortedStandalone.map(standaloneEntry(for:))
        return entries
    }

    private func standaloneEntry(for container: Container) -> MenuEntry {
        // 1 行目: コンテナ名 / 2 行目: 稼働状況 ・ イメージ ・ ポート
        // (長さの安定している時刻を先頭に置いて、行の頭を揃える)
        var parts = [container.friendlyStatus, container.shortImage]
        if !container.ports.isEmpty {
            parts.append(container.ports.map(\.display).joined(separator: ", "))
        }
        var entry = MenuEntry.info(
            container.name,
            subtitle: parts.joined(separator: " ・ "),
            dot: container.isRunning ? .systemGreen : .systemGray
        )
        entry.isEnabled = true
        entry.children = containerActionChildren(container)
        return entry
    }

    /// コンテナ単体の操作メニュー(状態に応じて disabled)
    private func containerActionChildren(_ container: Container) -> [MenuEntry] {
        var children: [MenuEntry] = []

        // CPU / メモリ使用量(取得済みの場合のみ)
        if container.isRunning, let stats = statsByID[container.id] {
            var statsEntry = MenuEntry.info("CPU \(stats.cpu) ・ メモリ \(stats.mem)")
            statsEntry.icon = "gauge"
            children.append(statsEntry)
            children.append(.separator)
        }

        // 公開ポートをブラウザで開く(⌥ で URL コピーに切り替わる)
        for port in container.ports {
            children.append(.action(
                "localhost:\(port.host) を開く", #selector(openPort(_:)),
                icon: "globe",
                enabled: container.isRunning,
                represented: port.host
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

        children.append(.action(
            "ターミナルで接続", #selector(openShell(_:)),
            icon: "terminal",
            enabled: container.isRunning,
            represented: container.name
        ))
        children.append(.action("ログを見る", #selector(showLogs(_:)), icon: "text.alignleft", represented: container.name))
        children.append(.action("名前をコピー", #selector(copyText(_:)), icon: "doc.on.doc", represented: container.name))
        children.append(.separator)

        children.append(.action("起動", #selector(startContainer(_:)), icon: "play.fill", enabled: !container.isRunning, represented: container.name))
        children.append(.action("再起動", #selector(restartContainer(_:)), icon: "arrow.clockwise", enabled: container.isRunning, represented: container.name))
        children.append(.action("停止", #selector(stopContainer(_:)), icon: "stop.fill", enabled: container.isRunning, represented: container.name))
        children.append(.separator)
        children.append(.action("破棄", #selector(removeContainer(_:)), icon: "trash", destructive: true, represented: container.name))
        return children
    }

    private func composeEntry(project: ComposeProject, group: [Container]) -> MenuEntry {
        let runningCount = group.filter(\.isRunning).count

        // 1 行目: プロジェクト名 / 2 行目: compose ・ コンテナ数 ・ 公開ポート
        var subtitleParts = ["compose", "\(group.count) コンテナ"]
        let allPorts = uniquePortMappings(of: group)
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
        var entry = MenuEntry.info(
            project.name,
            subtitle: subtitleParts.joined(separator: " ・ "),
            dot: dotColor
        )
        entry.isEnabled = true

        // 起動中 → 名前順で並べる
        var children: [MenuEntry] = []
        let sorted = group.sorted { ($0.isRunning ? 0 : 1, $0.name) < ($1.isRunning ? 0 : 1, $1.name) }
        for container in sorted {
            // 1 行目: サービス名 / 2 行目: 稼働状況 ・ イメージ ・ ポート
            // (長さの安定している時刻を先頭に置いて、行の頭を揃える)
            var sub = "\(container.friendlyStatus) ・ \(container.shortImage)"
            if !container.ports.isEmpty {
                sub += " ・ " + container.ports.map(\.display).joined(separator: ", ")
            }
            var child = MenuEntry.info(
                container.composeService ?? container.name,
                subtitle: sub,
                dot: container.isRunning ? .systemGreen : .systemGray
            )
            child.isEnabled = true
            child.children = containerActionChildren(container)
            children.append(child)
        }
        children.append(.separator)

        // compose ファイルの場所からプロジェクトディレクトリを割り出す
        let projectDir = project.configFiles.first
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        children.append(.action(
            "Zed で開く", #selector(openProjectInZed(_:)),
            icon: "curlybraces",
            enabled: projectDir != nil,
            represented: projectDir
        ))
        children.append(.separator)

        children.append(.action(
            "起動", #selector(upCompose(_:)),
            icon: "play.fill",
            enabled: runningCount < group.count || group.isEmpty,
            represented: project
        ))
        children.append(.action("再起動", #selector(restartCompose(_:)), icon: "arrow.clockwise", enabled: runningCount > 0, represented: project))
        children.append(.action("停止", #selector(stopCompose(_:)), icon: "stop.fill", enabled: runningCount > 0, represented: project))
        children.append(.separator)
        children.append(.action("破棄", #selector(downCompose(_:)), icon: "trash", destructive: true, represented: project))

        entry.children = children
        return entry
    }

    /// グループ内の全コンテナの公開ポートを順序を保って重複排除
    private func uniquePortMappings(of containers: [Container]) -> [String] {
        var seen = Set<String>()
        return containers.flatMap(\.hostPorts).filter { seen.insert($0).inserted }
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
            item.image = actionIcon(icon, color: entry.isDestructive ? .systemRed : nil)
        } else {
            item.image = entry.dot.flatMap { statusDot($0) }
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
    private func actionIcon(_ symbolName: String, color: NSColor?) -> NSImage? {
        var config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        if let color {
            config = config.applying(.init(paletteColors: [color]))
        }
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    /// ステータス表示用の小さい ●
    private func statusDot(_ color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
            .applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    // MARK: - Actions

    @objc private func startColima() {
        runBusy(message: "Colima を起動中…", command: "colima start")
    }

    @objc private func restartColima() {
        runBusy(message: "Colima を再起動中…", command: "colima restart")
    }

    @objc private func stopColima() {
        runBusy(message: "Colima を停止中…", command: "colima stop")
    }

    @objc private func stopCompose(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? ComposeProject else { return }
        runBusy(message: "\(project.name) を停止中…", command: "docker compose -p '\(project.name)' stop")
    }

    @objc private func restartCompose(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? ComposeProject else { return }
        runBusy(message: "\(project.name) を再起動中…", command: "docker compose -p '\(project.name)' restart")
    }

    @objc private func downCompose(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? ComposeProject else { return }

        // コンテナごと削除されて一覧からも消えるので、確認を挟む
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(project.name) を破棄しますか?"
        alert.informativeText = "docker compose down を実行します。コンテナとネットワークが削除され、このプロジェクトは一覧から消えます(ボリュームは残ります)。"
        alert.addButton(withTitle: "破棄")
        alert.addButton(withTitle: "キャンセル")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        runBusy(message: "\(project.name) を破棄中…", command: "docker compose -p '\(project.name)' down")
    }

    @objc private func upCompose(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? ComposeProject else { return }
        runBusy(message: "\(project.name) を起動中…", command: project.upCommand)
    }

    @objc private func startContainer(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        runBusy(message: "\(name) を起動中…", command: "docker start '\(name)'")
    }

    @objc private func restartContainer(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        runBusy(message: "\(name) を再起動中…", command: "docker restart '\(name)'")
    }

    @objc private func stopContainer(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        runBusy(message: "\(name) を停止中…", command: "docker stop '\(name)'")
    }

    @objc private func removeContainer(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(name) を破棄しますか?"
        alert.informativeText = "docker rm -f を実行します。コンテナが削除され、一覧から消えます(ボリュームは残ります)。"
        alert.addButton(withTitle: "破棄")
        alert.addButton(withTitle: "キャンセル")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        runBusy(message: "\(name) を破棄中…", command: "docker rm -f '\(name)'")
    }

    @objc private func openPort(_ sender: NSMenuItem) {
        guard let port = sender.representedObject as? String,
              let url = URL(string: "http://localhost:\(port)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyText(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openShell(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        // bash があれば bash、なければ sh
        openInTerminal("docker exec -it '\(name)' /bin/sh -c '[ -x /bin/bash ] && exec /bin/bash || exec /bin/sh'")
    }

    @objc private func showLogs(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        openInTerminal("docker logs -f --tail 200 '\(name)'")
    }

    @objc private func openProjectInZed(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        Shell.runAsync("open -a Zed '\(path)'") { [weak self] result in
            if result.status != 0 {
                self?.showError(command: "open -a Zed", detail: result.stderr)
            }
        }
    }

    /// Terminal.app で新しいウインドウを開いてコマンドを実行する
    private func openInTerminal(_ command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Shell.runProgram("/usr/bin/osascript", ["-e", script])
            if result.status != 0 {
                DispatchQueue.main.async {
                    self?.showError(command: "osascript", detail: result.stderr)
                }
            }
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func runBusy(message: String, command: String) {
        busyMessage = message
        updateIcon()
        rebuildMenu()

        Shell.runAsync(command) { [weak self] result in
            guard let self else { return }
            self.busyMessage = nil
            self.suppressNotificationsOnce = true // 自分の操作による変化は通知しない
            if result.status != 0 {
                self.showError(command: command, detail: result.stderr)
            }
            self.refresh()
        }
    }

    private func showError(command: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "コマンドが失敗しました"
        alert.informativeText = "\(command)\n\n\(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
