import AppKit

/// ウィンドウ上部は AppKit が所有し、寸法とガラスの描画をシステムに任せる。
@MainActor
final class MainWindowToolbarController: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
    private enum ID {
        static let cleanup = NSToolbarItem.Identifier("hako.cleanup")
        static let sidebar = NSToolbarItem.Identifier("hako.sidebar")
        static let inspectorActions = NSToolbarItem.Identifier("hako.inspectorActions")
        static let commands = NSToolbarItem.Identifier("hako.commands")
        static let inspector = NSToolbarItem.Identifier("hako.inspector")
        static let projectActions = NSToolbarItem.Identifier("hako.projectActions")
        static let search = NSToolbarItem.Identifier("hako.search")
    }

    private let perform: (MainWindowAction) -> Void
    private let toggleSidebar: () -> Void
    private let toggleInspector: () -> Void
    private let searchChanged: (String) -> Void
    private var project: ComposeProject?
    private var busy = false
    private var running = false
    private var canStart = false
    private var canStop = false
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private let searchItem = NSSearchToolbarItem(itemIdentifier: ID.search)

    lazy var toolbar: NSToolbar = {
        let toolbar = NSToolbar(identifier: "HakoMainWindowToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }()

    init(perform: @escaping (MainWindowAction) -> Void,
         toggleSidebar: @escaping () -> Void, toggleInspector: @escaping () -> Void, searchChanged: @escaping (String) -> Void) {
        self.perform = perform
        self.toggleSidebar = toggleSidebar
        self.toggleInspector = toggleInspector
        self.searchChanged = searchChanged
        super.init()
        let field = NSSearchField()
        field.placeholderString = "コンテナを検索"
        field.setAccessibilityLabel("コンテナを検索")
        field.delegate = self
        field.sendsSearchStringImmediately = true
        searchItem.searchField = field
        searchItem.label = "検索"
        searchItem.preferredWidthForSearchField = 220
        field.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ID.sidebar, .sidebarTrackingSeparator,
         .flexibleSpace, ID.inspectorActions, ID.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [ID.commands, ID.projectActions]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == ID.search { return searchItem }
        if let item = items[id] { return item }
        let item: NSToolbarItem
        switch id {
        case ID.sidebar:
            item = button(id, title: "サイドバー", symbol: "sidebar.left", action: #selector(toggleSidebarAction))
            item.toolTip = "サイドバーを表示／非表示（⌥⌘S）"
        case ID.inspectorActions:
            let group = NSToolbarItemGroup(itemIdentifier: id)
            group.label = "リソース整理・インスペクタ"
            let cleanupItem = button(ID.cleanup, title: "未使用リソースを整理…", symbol: "externaldrive", action: #selector(cleanup))
            let inspectorItem = button(ID.inspector, title: "インスペクタ", symbol: "info.circle", action: #selector(toggleInspectorAction))
            inspectorItem.toolTip = "インスペクタを表示／非表示（⌥⌘I）"
            group.subitems = [cleanupItem, inspectorItem]
            items[ID.cleanup] = cleanupItem
            items[ID.inspector] = inspectorItem
            item = group
        case ID.commands:
            let group = NSToolbarItemGroup(itemIdentifier: id)
            group.label = "起動・停止・再起動"
            group.subitems = [
                button(.init("hako.start"), title: "起動", symbol: "play.fill", action: #selector(start)),
                button(.init("hako.stop"), title: "停止", symbol: "stop.fill", action: #selector(stop)),
                button(.init("hako.restart"), title: "再起動", symbol: "arrow.2.circlepath", action: #selector(restart))
            ]
            item = group
        case ID.projectActions:
            let group = NSToolbarItemGroup(itemIdentifier: id)
            group.label = "プロジェクトの操作"
            group.subitems = [
                button(.init("hako.openEditor"), title: "エディタで開く", symbol: "square.and.pencil", action: #selector(openEditor)),
                button(.init("hako.removeProject"), title: "プロジェクトを破棄…", symbol: "trash", action: #selector(removeProject))
            ]
            item = group
        default: return nil
        }
        item.autovalidates = false
        items[id] = item
        applyState()
        return item
    }

    private func button(_ id: NSToolbarItem.Identifier, title: String, symbol: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = title
        item.toolTip = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.target = self
        item.action = action
        item.autovalidates = false
        return item
    }

    func update(snapshot: ColimaSnapshot?, scope: ContainerScope, busy: Bool, search: String) {
        self.busy = busy
        running = snapshot?.running == true
        if case .project(let name) = scope {
            project = snapshot?.composeProjects.first { $0.name == name }
        } else { project = nil }
        let containers = scope.containers(in: snapshot, matching: "")
        let count = containers.filter(\.isRunning).count
        canStart = project != nil ? running && (containers.isEmpty || count < containers.count) : !running
        canStop = project != nil ? count > 0 : running
        if searchItem.searchField.stringValue != search { searchItem.searchField.stringValue = search }
        updateCommandsVisibility()
        applyState()
    }

    private func updateCommandsVisibility() {
        for id in [ID.commands, ID.projectActions] {
            let index = toolbar.items.firstIndex { $0.itemIdentifier == id }
            if project != nil, index == nil,
               let inspectorIndex = toolbar.items.firstIndex(where: { $0.itemIdentifier == ID.inspectorActions }) {
                toolbar.insertItem(withItemIdentifier: id, at: inspectorIndex)
                toolbar.insertItem(withItemIdentifier: .space, at: inspectorIndex + 1)
            } else if project == nil, let index {
                if toolbar.items.indices.contains(index + 1),
                   toolbar.items[index + 1].itemIdentifier == .space {
                    toolbar.removeItem(at: index + 1)
                }
                toolbar.removeItem(at: index)
            }
        }
    }

    private func applyState() {
        items[ID.cleanup]?.isEnabled = running && !busy
        items[ID.sidebar]?.isEnabled = running
        items[ID.inspector]?.isEnabled = running
        searchItem.searchField.isEnabled = running
        if let group = items[ID.commands] as? NSToolbarItemGroup {
            let target = project?.name ?? "Colima"
            for (index, item) in group.subitems.enumerated() {
                let verb = ["起動", "停止", "再起動"][index]
                item.label = "\(target) を\(verb)"
                item.toolTip = "\(item.label)\n\(["⌃⌘↑", "⌃⌘↓", "⌃⌘R"][index]): コンテナ選択時はそのコンテナを\(verb)"
                item.isEnabled = running && !busy && (index == 0 ? canStart : canStop)
            }
        }
        if let group = items[ID.projectActions] as? NSToolbarItemGroup {
            group.subitems[0].isEnabled = project != nil && !busy && project?.configFiles.isEmpty == false
            group.subitems[1].isEnabled = project != nil && !busy
        }
    }

    func focusSearch() {
        guard running else { return }
        searchItem.beginSearchInteraction()
    }

    func canPerformProjectOperation(_ operation: MainWindowAction.ProjectOperation) -> Bool {
        guard project != nil, running, !busy else { return false }
        switch operation {
        case .start: return canStart
        case .stop, .restart: return canStop
        default: return false
        }
    }

    func performProjectOperation(_ operation: MainWindowAction.ProjectOperation) {
        guard canPerformProjectOperation(operation) else { return }
        switch operation {
        case .start: start()
        case .stop: stop()
        case .restart: restart()
        default: break
        }
    }

    func controlTextDidChange(_ obj: Notification) { searchChanged(searchItem.searchField.stringValue) }

    @objc private func cleanup() { guard running && !busy else { return }; perform(.cleanup) }
    @objc private func toggleSidebarAction() { guard running else { return }; toggleSidebar() }
    @objc private func toggleInspectorAction() { guard running else { return }; toggleInspector() }
    @objc private func start() { guard running && canStart && !busy else { return }; perform(project.map { .project($0.name, .start) } ?? .startColima) }
    @objc private func stop() { guard canStop && !busy else { return }; perform(project.map { .project($0.name, .stop) } ?? .stopColima) }
    @objc private func restart() { guard canStop && !busy else { return }; perform(project.map { .project($0.name, .restart) } ?? .restartColima) }
    @objc private func openEditor() { if let project, !busy { perform(.project(project.name, .editor)) } }
    @objc private func removeProject() { if let project, !busy { perform(.project(project.name, .remove)) } }
}
