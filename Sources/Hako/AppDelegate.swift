import AppKit

/// 各部品を組み立てて、タイマーやウィンドウの開閉をつなぐだけにする。
/// 状態は StatusStore、メニューバーは StatusMenuController、操作は CommandCenter が持つ
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let store = StatusStore()
    private let editors = EditorPreferences()
    private lazy var commands = CommandCenter(store: store, editors: editors)
    private var statusMenu: StatusMenuController?
    private var mainWindow: MainWindowController?
    private var cleanupWindow: CleanupWindowController?
    private var updateWindow: UpdateWindowController?
    private var refreshTimer: Timer?
    private var windowRefreshTimer: Timer?
    private var updateCheckTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        commands.openCleanup = { [weak self] in self?.openCleanup() }
        commands.openUpdates = { [weak self] in self?.openUpdates() }
        let statusMenu = StatusMenuController(store: store, commands: commands, editors: editors)
        statusMenu.openMainWindow = { [weak self] in self?.openMainWindow() }
        self.statusMenu = statusMenu

        configureApplicationMenu()
        store.refresh()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.refresh() }
        }

        Task { await store.checkForUpdates() }
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.store.checkForUpdates() }
            }
        }

        // スリープ復帰時は即リフレッシュ(次のポーリングを待たない)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow()
        return false
    }

    @objc private func didWake() {
        store.refresh()
    }

    // MARK: - Main window

    private func configureApplicationMenu() {
        let main = NSMenu()
        let appMenu = NSMenu(title: "Hako")
        appMenu.addItem(withTitle: "Hako について", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let checkForUpdates = appMenu.addItem(withTitle: "アップデートを確認…", action: #selector(openUpdatesAction), keyEquivalent: "")
        checkForUpdates.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hako を隠す", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hako を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        let edit = NSMenu(title: "編集")
        for (title, action, key) in [
            ("取り消す", Selector(("undo:")), "z"),
            ("カット", #selector(NSText.cut(_:)), "x"),
            ("コピー", #selector(NSText.copy(_:)), "c"),
            ("ペースト", #selector(NSText.paste(_:)), "v"),
            ("すべて選択", #selector(NSText.selectAll(_:)), "a"),
        ] { edit.addItem(withTitle: title, action: action, keyEquivalent: key) }
        let redo = NSMenuItem(title: "やり直す", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.insertItem(redo, at: 1)
        edit.insertItem(.separator(), at: 2)
        edit.addItem(.separator())
        let find = edit.addItem(withTitle: "コンテナを検索…", action: #selector(focusContainerSearch), keyEquivalent: "f")
        find.target = self
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        let view = NSMenu(title: "表示")
        let all = view.addItem(withTitle: "すべてのコンテナ", action: #selector(showAllContainers), keyEquivalent: "1")
        all.target = self
        let standalone = view.addItem(withTitle: "単体のコンテナ", action: #selector(showStandaloneContainers), keyEquivalent: "2")
        standalone.target = self
        view.addItem(.separator())
        let refresh = view.addItem(withTitle: "状態を更新", action: #selector(refreshWindowContents), keyEquivalent: "r")
        refresh.target = self
        let sidebar = view.addItem(withTitle: "サイドバーを表示／非表示", action: #selector(toggleWindowSidebar), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .option]
        sidebar.target = self
        let inspector = view.addItem(withTitle: "インスペクタを表示／非表示", action: #selector(toggleWindowInspector), keyEquivalent: "i")
        inspector.keyEquivalentModifierMask = [.command, .option]
        inspector.target = self
        let viewItem = NSMenuItem()
        viewItem.submenu = view
        main.addItem(viewItem)

        let project = NSMenu(title: "操作")
        for (title, action, key) in [
            ("起動", #selector(startWindowSelection), String(UnicodeScalar(NSUpArrowFunctionKey)!)),
            ("停止", #selector(stopWindowSelection), String(UnicodeScalar(NSDownArrowFunctionKey)!)),
            ("再起動", #selector(restartWindowSelection), "r")
        ] {
            let item = project.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.control, .command]
            item.target = self
        }
        let projectItem = NSMenuItem()
        projectItem.submenu = project
        main.addItem(projectItem)

        let windows = NSMenu(title: "ウインドウ")
        let open = windows.addItem(withTitle: "Hako を開く", action: #selector(openMainWindow), keyEquivalent: "0")
        open.target = self
        windows.addItem(withTitle: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windows.addItem(withTitle: "しまう", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "拡大／縮小", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let windowItem = NSMenuItem()
        windowItem.submenu = windows
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windows
    }

    @objc private func refreshWindowContents() { commands.perform(.refresh) }
    @objc private func toggleWindowInspector() { mainWindow?.toggleInspector() }
    @objc private func toggleWindowSidebar() { mainWindow?.toggleSidebar() }
    @objc private func showAllContainers() { mainWindow?.selectScope(.all) }
    @objc private func showStandaloneContainers() { mainWindow?.selectScope(.standalone) }
    @objc private func startWindowSelection() { mainWindow?.performLifecycleOperation(.start) }
    @objc private func stopWindowSelection() { mainWindow?.performLifecycleOperation(.stop) }
    @objc private func restartWindowSelection() { mainWindow?.performLifecycleOperation(.restart) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(startWindowSelection):
            menuItem.title = "\(mainWindow?.operationTargetLabel ?? "選択項目")を起動"
            return mainWindow?.window?.isKeyWindow == true && mainWindow?.canPerformLifecycleOperation(.start) == true
        case #selector(stopWindowSelection):
            menuItem.title = "\(mainWindow?.operationTargetLabel ?? "選択項目")を停止"
            return mainWindow?.window?.isKeyWindow == true && mainWindow?.canPerformLifecycleOperation(.stop) == true
        case #selector(restartWindowSelection):
            menuItem.title = "\(mainWindow?.operationTargetLabel ?? "選択項目")を再起動"
            return mainWindow?.window?.isKeyWindow == true && mainWindow?.canPerformLifecycleOperation(.restart) == true
        case #selector(toggleWindowSidebar), #selector(showAllContainers), #selector(showStandaloneContainers), #selector(toggleWindowInspector):
            return mainWindow?.window?.isKeyWindow == true && mainWindow?.canNavigate == true
        default:
            return true
        }
    }

    @objc private func focusContainerSearch() {
        openMainWindow()
        mainWindow?.focusSearch()
    }

    @objc private func openMainWindow() {
        if mainWindow == nil {
            mainWindow = MainWindowController(model: store, perform: { [weak self] action in
                self?.commands.perform(action)
            }, onClose: { [weak self] in
                self?.windowRefreshTimer?.invalidate()
                self?.windowRefreshTimer = nil
                // 閉じても終了せず、元のメニューバー常駐へ戻る。
                NSApp.setActivationPolicy(.accessory)
            })
        }
        NSApp.setActivationPolicy(.regular)
        mainWindow?.open()
        editors.reload()
        commands.perform(.refresh)
        guard windowRefreshTimer == nil else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.mainWindow?.window?.isVisible == true,
                      self.mainWindow?.window?.isMiniaturized == false else { return }
                self.store.refresh()
                self.store.refreshStats()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        windowRefreshTimer = timer
    }

    @objc private func openUpdatesAction() { openUpdates() }

    private func openUpdates() {
        if updateWindow == nil {
            updateWindow = UpdateWindowController(
                model: UpdateModel(backend: .live(), store: store),
                restartColima: { [weak self] in self?.commands.restartColima() },
                colimaRunning: { [weak self] in self?.store.snapshot?.running == true }
            )
        }
        updateWindow?.open()
    }

    private func openCleanup() {
        if cleanupWindow == nil {
            cleanupWindow = CleanupWindowController { [weak self] in
                self?.store.reloadDiskUsage()
                self?.store.refresh()
            }
        }
        cleanupWindow?.open()
    }
}
