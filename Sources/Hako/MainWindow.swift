import AppKit
import Observation
import SwiftUI

/// 取得・操作は AppDelegate が所有し、両方の UI に同じ結果を渡す。
@MainActor @Observable
final class MainWindowModel {
    var snapshot: ColimaSnapshot?
    var busyMessage: String?
    var statsByID: [String: ContainerStats] = [:]
    var diskUsage: [DiskUsage] = []
    var colimaVersion: String?
}

enum MainWindowAction {
    enum ContainerOperation { case start, restart, stop, remove, logs, shell }
    enum ProjectOperation { case start, restart, stop, remove, editor }
    case refresh, cleanup, startColima, restartColima, stopColima
    case container(String, ContainerOperation)
    case project(String, ProjectOperation)
}

enum ContainerScope: Hashable {
    case all, standalone, project(String)

    var title: String {
        switch self {
        case .all: return "すべてのコンテナ"
        case .standalone: return "単体のコンテナ"
        case .project(let name): return name
        }
    }

    func containers(in snapshot: ColimaSnapshot?, matching search: String) -> [Container] {
        (snapshot?.containers ?? []).filter { container in
            let included: Bool
            switch self {
            case .all: included = true
            case .standalone: included = container.composeProject == nil
            case .project(let name): included = container.composeProject == name
            }
            return included && (search.isEmpty ||
                [container.name, container.image, container.composeService ?? "", container.composeProject ?? ""]
                    .contains { $0.localizedStandardContains(search) })
        }.sorted(by: Container.runningFirst)
    }
}

/// 選択と検索は、再表示時にも維持するウィンドウ固有の状態。
@MainActor @Observable
private final class MainWindowState {
    var scope: ContainerScope? = .all
    var selection: String?
    var search = ""
    var isInspectorPresented = false
    var isSidebarPresented = true
    var sortOrder = [KeyPathComparator(\ContainerTableRow.name)]
}

private struct MainWindowSidebar: View {
    let model: MainWindowModel
    let perform: (MainWindowAction) -> Void
    @Bindable var state: MainWindowState

    var body: some View {
        VStack(spacing: 0) {
            if model.snapshot?.running == true {
                List(selection: $state.scope) {
                    Section("ライブラリ") {
                        Label("すべてのコンテナ", systemImage: "shippingbox")
                            .tag(ContainerScope.all)
                        Label("単体のコンテナ", systemImage: "cube")
                            .tag(ContainerScope.standalone)
                    }
                    Section {
                        ForEach(model.snapshot?.composeProjects ?? [], id: \.name) { project in
                            ProjectSidebarRow(project: project,
                                              containers: model.snapshot?.containers.filter { $0.composeProject == project.name } ?? [],
                                              selected: state.scope == .project(project.name))
                                .tag(ContainerScope.project(project.name))
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Text("Compose プロジェクト")
                            Button {
                                perform(.refresh)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .disabled(model.busyMessage != nil)
                            .accessibilityLabel("状態を更新")
                            .help("状態を更新（⌘R）")
                            Spacer()
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            } else {
                Spacer()
            }
        }
    }
}

private struct MainWindowView: View {
    let model: MainWindowModel
    let perform: (MainWindowAction) -> Void
    @Bindable var state: MainWindowState

    private var currentScope: ContainerScope { state.scope ?? .all }
    private var containers: [Container] { currentScope.containers(in: model.snapshot, matching: state.search) }
    private var selectedProject: ComposeProject? {
        guard case .project(let name) = currentScope else { return nil }
        return model.snapshot?.composeProjects.first { $0.name == name }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.snapshot?.running == true {
                containerList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                MainWindowStatusBar(message: model.busyMessage, count: containers.count,
                                    runningCount: containers.filter(\.isRunning).count,
                                    imageSize: model.diskUsage.first(where: { $0.type == "Images" })?.size)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                containerList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: model.snapshot?.running) {
            if model.snapshot?.running != true {
                state.scope = .all
                state.selection = nil
                state.search = ""
                state.isInspectorPresented = false
            }
        }
        .onChange(of: currentScope) { state.selection = nil }
        .onChange(of: containers.map(\.id)) {
            if let selection = state.selection, !containers.contains(where: { $0.id == selection }) { state.selection = nil }
        }
        .onChange(of: model.snapshot?.composeProjects.map(\.name)) {
            if case .project(let name) = currentScope,
               model.snapshot?.composeProjects.contains(where: { $0.name == name }) != true {
                state.scope = .all
            }
        }
        .frame(minWidth: 320, minHeight: 320)
    }

    @ViewBuilder private var containerList: some View {
        if model.snapshot == nil {
            ProgressView("状態を確認中…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.snapshot?.running != true {
            ContentUnavailableView {
                Label("Colima は停止中です", systemImage: "power")
            } description: {
                Text(model.busyMessage ?? "Colima を起動すると、プロジェクトとコンテナを表示できます。")
            } actions: {
                if model.busyMessage != nil {
                    ProgressView().controlSize(.small)
                }
                Button("Colima を起動") { perform(.startColima) }
                    .disabled(model.busyMessage != nil)
            }
        } else {
            VStack(spacing: 0) {
                if containers.isEmpty {
                    ContentUnavailableView(state.search.isEmpty ? "コンテナがありません" : "一致するコンテナがありません",
                                           systemImage: "shippingbox",
                                           description: Text(state.search.isEmpty ? "Docker で作成したコンテナがここに表示されます。" : "別の名前やイメージ名で検索してください。"))
                } else {
                    ContainerTableView(containers: containers, statsByID: model.statsByID,
                                       showsServiceNames: selectedProject != nil, busy: model.busyMessage != nil,
                                       selection: $state.selection, sortOrder: $state.sortOrder,
                                       inspect: { state.isInspectorPresented = true }, perform: perform)
                }
            }
        }
    }
}

private struct MainWindowInspector: View {
    let model: MainWindowModel
    let perform: (MainWindowAction) -> Void
    @Bindable var state: MainWindowState

    var body: some View {
        Group {
            if let container = model.snapshot?.containers.first(where: { $0.id == state.selection }) {
                ContainerDetailView(container: container, stats: model.statsByID[container.id],
                                    busy: model.busyMessage != nil, perform: perform)
            } else {
                ContentUnavailableView("コンテナを選択", systemImage: "info.circle",
                                       description: Text("選択したコンテナの詳細を表示します。"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct ProjectSidebarRow: View {
    let project: ComposeProject
    let containers: [Container]
    let selected: Bool

    private var runningCount: Int { containers.filter(\.isRunning).count }
    private var unhealthy: Bool { containers.contains { $0.isRunning && $0.isUnhealthy } }
    private var status: String {
        if unhealthy { return "要確認" }
        if runningCount == 0 { return "停止中" }
        return runningCount == containers.count ? "実行中" : "一部停止"
    }
    private var color: Color {
        if selected { return .primary }
        if unhealthy { return .red }
        if runningCount > 0 && runningCount < containers.count { return .orange }
        return runningCount > 0 ? .green : .secondary
    }

    var body: some View {
        Label {
            Text(project.name).lineLimit(1)
        } icon: {
            Image(systemName: "circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(color)
                .frame(width: 16)
        }
        .badge(Text("\(runningCount)/\(containers.count)"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(project.name)、\(status)、\(containers.count) コンテナ中 \(runningCount) 実行中")
        .help("\(project.name): \(status)、\(containers.count) コンテナ中 \(runningCount) 実行中")
    }
}

private struct MainWindowStatusBar: View {
    let message: String?
    let count: Int
    let runningCount: Int
    let imageSize: String?

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if let message {
                    ProgressView().controlSize(.small)
                    Text(message)
                } else {
                    Text("\(count) コンテナ · \(runningCount) 実行中")
                }
                Spacer()
                if let imageSize { Text("イメージ \(imageSize)") }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .background(.bar)
    }
}

private struct ContainerTableRow: Identifiable {
    let container: Container
    let stats: ContainerStats?
    let showsServiceNames: Bool
    var id: String { container.id }
    var name: String { showsServiceNames ? (container.composeService ?? container.name) : container.name }
    var image: String { container.shortImage }
    var cpuPercent: Double { container.isRunning ? (stats?.cpuPercent ?? -1) : -1 }
    var memoryBytes: Double { container.isRunning ? (stats?.memoryBytes ?? -1) : -1 }
    var status: String {
        if container.isRunning { return container.isUnhealthy ? "要確認" : "実行中" }
        return container.state == "paused" ? "一時停止" : "停止中"
    }
}

private struct ContainerTableView: View {
    let containers: [Container]
    let statsByID: [String: ContainerStats]
    let showsServiceNames: Bool
    let busy: Bool
    @Binding var selection: String?
    @Binding var sortOrder: [KeyPathComparator<ContainerTableRow>]
    let inspect: () -> Void
    let perform: (MainWindowAction) -> Void

    private var rows: [ContainerTableRow] {
        let sorted = containers.map {
            ContainerTableRow(container: $0, stats: statsByID[$0.id], showsServiceNames: showsServiceNames)
        }.sorted(using: sortOrder)
        if let keyPath = sortOrder.first?.keyPath,
           keyPath == \ContainerTableRow.cpuPercent || keyPath == \ContainerTableRow.memoryBytes {
            return sorted.filter { $0.container.isRunning } + sorted.filter { !$0.container.isRunning }
        }
        return sorted
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("名前", value: \.name) { row in
                Text(row.name).lineLimit(1).help(row.container.name)
            }
            .width(min: 100, ideal: 140)
            TableColumn("状態", value: \.status) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.container.isRunning ? "circle.fill" : "circle")
                        .font(.system(size: 7)).accessibilityHidden(true)
                        .foregroundStyle(selection == row.id ? Color.primary :
                            (row.container.isUnhealthy ? .orange : (row.container.isRunning ? .green : .secondary)))
                    Text(row.status)
                }
                .help(row.container.friendlyStatus)
            }
            .width(90)
            TableColumn("CPU", value: \.cpuPercent) { row in
                Text(row.container.isRunning ? (row.stats?.cpu ?? "—") : "—").monospacedDigit()
            }
            .width(65)
            TableColumn("メモリ", value: \.memoryBytes) { row in
                Text(row.container.isRunning ? (row.stats?.mem ?? "—") : "—").monospacedDigit()
            }
            .width(85)
            TableColumn("イメージ", value: \.image) { row in
                Text(row.image).lineLimit(1).help(row.container.image)
            }
            .width(min: 90, ideal: 130)
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let container = containers.first(where: { $0.id == id }) {
                Button("情報を見る", systemImage: "info.circle") { selection = id; inspect() }
                Divider()
                ContainerActionsView(container: container, perform: perform).disabled(busy)
            }
        } primaryAction: { ids in
            if let id = ids.first { selection = id; inspect() }
        }
    }
}

private struct ContainerStatusView: View {
    let container: Container

    var body: some View {
        Label(container.friendlyStatus,
              systemImage: container.isUnhealthy ? "exclamationmark.triangle.fill" :
                (container.isRunning ? "checkmark.circle.fill" : "pause.circle"))
            .font(.caption)
            .foregroundStyle(container.isUnhealthy ? Color.orange :
                                (container.isRunning ? .green : .secondary))
    }
}

private struct ContainerActionsView: View {
    let container: Container
    let perform: (MainWindowAction) -> Void

    var body: some View {
        if container.isRunning {
            Button("停止", systemImage: "stop") { perform(.container(container.id, .stop)) }
            Button("再起動", systemImage: "arrow.clockwise") { perform(.container(container.id, .restart)) }
        } else {
            Button("起動", systemImage: "play") { perform(.container(container.id, .start)) }
        }
        Divider()
        Button("ターミナルで接続", systemImage: "terminal") { perform(.container(container.id, .shell)) }
            .disabled(!container.isRunning)
        Button("ログを見る", systemImage: "text.alignleft") { perform(.container(container.id, .logs)) }
        Divider()
        Button("コンテナを破棄…", systemImage: "trash", role: .destructive) {
            perform(.container(container.id, .remove))
        }
    }
}

private struct ContainerDetailView: View {
    let container: Container
    let stats: ContainerStats?
    let busy: Bool
    let perform: (MainWindowAction) -> Void

    var body: some View {
        Form {
            Section {
                Text(container.name).font(.headline).textSelection(.enabled)
                ContainerStatusView(container: container)
                HStack {
                    if container.isRunning {
                        Button("停止", systemImage: "stop") { perform(.container(container.id, .stop)) }
                        Button("再起動", systemImage: "arrow.clockwise") { perform(.container(container.id, .restart)) }
                    } else {
                        Button("起動", systemImage: "play") { perform(.container(container.id, .start)) }
                    }
                    Menu {
                        ContainerActionsView(container: container, perform: perform)
                    } label: { Label("その他の操作", systemImage: "ellipsis") }
                    .labelStyle(.iconOnly).fixedSize()
                }
                .controlSize(.small).disabled(busy)
            }
            Section("コンテナ情報") {
                LabeledContent("イメージ") { Text(container.image).textSelection(.enabled) }
                LabeledContent("ID") { Text(container.id).textSelection(.enabled) }
                if let project = container.composeProject { LabeledContent("プロジェクト", value: project) }
                if let service = container.composeService { LabeledContent("サービス", value: service) }
                if container.isRunning {
                    LabeledContent("CPU", value: stats?.cpu ?? "取得中…")
                    LabeledContent("メモリ", value: stats?.mem ?? "取得中…")
                }
            }
            if !container.ports.isEmpty {
                Section("公開ポート") {
                    ForEach(container.ports, id: \.display) { port in
                        HStack {
                            if let url = URL(string: "http://localhost:\(port.host)") {
                                Link("localhost:\(port.host)", destination: url).disabled(!container.isRunning)
                            }
                            Spacer()
                            Text("→ \(port.container)").foregroundStyle(.secondary)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("http://localhost:\(port.host)", forType: .string)
                            } label: { Label("URL をコピー", systemImage: "doc.on.doc") }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).help("URL をコピー")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// Table の内部最小幅を分割ペインの制約へ伝播させず、一覧の横スクロールに任せる。
@MainActor
private final class ResizableContentRegion: NSViewController {
    private let content: NSViewController

    init(content: NSViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
        view = NSView()
        view.clipsToBounds = true
        addChild(content)
        content.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content.view)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLayout() {
        super.viewDidLayout()
        content.view.frame = view.bounds
    }
}

/// 右側の分割はツールバーの下に収め、区切り線をヘッダーへ伸ばさない。
@MainActor
private final class WindowContentRegion: NSViewController {
    init(content: NSViewController) {
        super.init(nibName: nil, bundle: nil)
        view = NSView()
        addChild(content)
        let contentView = content.view
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 複数の HostingController 間でも、クリックしたリストをキーボード操作の対象にする。
@MainActor
private final class MainContentWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        var clickedTable: NSTableView?
        if event.type == .leftMouseDown, let contentView {
            var target = contentView.hitTest(contentView.convert(event.locationInWindow, from: nil))
            while let view = target {
                if let table = view as? NSTableView { clickedTable = table; break }
                target = view.superview
            }
        }
        super.sendEvent(event)
        if let clickedTable, clickedTable.window === self {
            makeFirstResponder(clickedTable)
        }
    }
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void
    private let viewState: MainWindowState
    private let model: MainWindowModel
    private let perform: (MainWindowAction) -> Void
    private let toolbarController: MainWindowToolbarController
    private let splitController: NSSplitViewController
    private let inspectorItem: NSSplitViewItem
    private let sidebarItem: NSSplitViewItem
    private var inspectorObservation: NSKeyValueObservation?

    init(model: MainWindowModel, perform: @escaping (MainWindowAction) -> Void, onClose: @escaping () -> Void) {
        self.onClose = onClose
        self.model = model
        self.perform = perform
        let state = MainWindowState()
        self.viewState = state
        self.toolbarController = MainWindowToolbarController(perform: perform,
            toggleSidebar: { state.isSidebarPresented.toggle() },
            toggleInspector: { state.isInspectorPresented.toggle() },
            searchChanged: { state.search = $0 })
        let window = MainContentWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = ""
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        window.isOpaque = false
        window.backgroundColor = .textBackgroundColor
        let split = NSSplitViewController()
        split.splitView.isVertical = true
        let sidebar = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: MainWindowSidebar(model: model, perform: perform, state: state)))
        sidebar.minimumThickness = 250
        sidebar.maximumThickness = 320
        sidebar.preferredThicknessFraction = 0.25
        sidebar.canCollapse = false
        sidebar.allowsFullHeightLayout = true
        sidebar.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        let detailHosting = NSHostingController(rootView: MainWindowView(model: model, perform: perform, state: state))
        detailHosting.sizingOptions = []
        let detail = NSSplitViewItem(viewController: ResizableContentRegion(content: detailHosting))
        detail.minimumThickness = 320
        let contentSplit = NSSplitViewController()
        contentSplit.splitView.isVertical = true
        contentSplit.addSplitViewItem(detail)
        let inspectorHosting = NSHostingController(rootView: MainWindowInspector(model: model, perform: perform, state: state))
        inspectorHosting.sizingOptions = []
        // 通常のペインとして配置し、インスペクタ用の自動ガラス背景を重ねない。
        let inspector = NSSplitViewItem(viewController: inspectorHosting)
        inspector.canCollapse = true
        inspector.minimumThickness = 240
        inspector.maximumThickness = 480
        inspectorHosting.view.setFrameSize(NSSize(width: 270, height: inspectorHosting.view.frame.height))
        // ウィンドウ全体ではなく隣接ペインを伸縮する。
        inspector.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        inspector.isCollapsed = true
        contentSplit.addSplitViewItem(inspector)
        split.addSplitViewItem(sidebar)
        let workspace = NSSplitViewItem(viewController: WindowContentRegion(content: contentSplit))
        workspace.minimumThickness = 320
        split.addSplitViewItem(workspace)
        self.splitController = split
        self.inspectorItem = inspector
        self.sidebarItem = sidebar
        window.contentViewController = split
        window.toolbar = toolbarController.toolbar
        window.minSize = NSSize(width: 880, height: 560)
        super.init(window: window)
        window.delegate = self
        inspectorObservation = inspector.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
            let collapsed = item.isCollapsed
            Task { @MainActor in
                guard let self, self.model.snapshot?.running == true else { return }
                self.viewState.isInspectorPresented = !collapsed
            }
        }
        observeToolbar()
        // HostingController / SplitView の取り付けで fittingSize に縮むため、
        // ペインとツールバーの初期状態を反映した後にサイズを決める。
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.center()
        window.setFrameUsingName("HakoMainWindow")
        window.setFrameAutosaveName("HakoMainWindow")
        enforceMinimumWindowSize()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func focusSearch() { toolbarController.focusSearch() }
    var canNavigate: Bool { model.snapshot?.running == true }

    func toggleSidebar() {
        guard canNavigate else { return }
        viewState.isSidebarPresented.toggle()
    }

    func selectScope(_ scope: ContainerScope) {
        guard canNavigate else { return }
        viewState.scope = scope
    }

    private var selectedContainerForCommands: Container? {
        (viewState.scope ?? .all).containers(in: model.snapshot, matching: viewState.search)
            .first { $0.id == viewState.selection }
    }

    var operationTargetLabel: String {
        if selectedContainerForCommands != nil { return "コンテナ" }
        if case .project = viewState.scope { return "プロジェクト" }
        return "選択項目"
    }

    func canPerformLifecycleOperation(_ operation: MainWindowAction.ProjectOperation) -> Bool {
        guard canNavigate, model.busyMessage == nil else { return false }
        if let container = selectedContainerForCommands {
            switch operation {
            case .start: return !container.isRunning
            case .stop, .restart: return container.isRunning
            default: return false
            }
        }
        return toolbarController.canPerformProjectOperation(operation)
    }

    func performLifecycleOperation(_ operation: MainWindowAction.ProjectOperation) {
        guard canPerformLifecycleOperation(operation) else { return }
        if let container = selectedContainerForCommands {
            let containerOperation: MainWindowAction.ContainerOperation
            switch operation {
            case .start: containerOperation = .start
            case .stop: containerOperation = .stop
            case .restart: containerOperation = .restart
            default: return
            }
            perform(.container(container.id, containerOperation))
        } else {
            toolbarController.performProjectOperation(operation)
        }
    }

    func toggleInspector() {
        guard model.snapshot?.running == true else { return }
        viewState.isInspectorPresented.toggle()
    }

    func open() {
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        enforceMinimumWindowSize()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func enforceMinimumWindowSize() {
        guard let window else { return }
        var frame = window.frame
        let size = NSSize(width: max(frame.width, window.minSize.width),
                          height: max(frame.height, window.minSize.height))
        guard size != frame.size else { return }
        // 保存された高さを補正するときも、ウィンドウの上端は維持する。
        frame.origin.y -= size.height - frame.height
        frame.size = size
        window.setFrame(frame, display: false)
    }

    private func observeToolbar() {
        withObservationTracking {
            let running = model.snapshot?.running == true
            let collapseSidebar = !running || !viewState.isSidebarPresented
            let collapseInspector = !running || !viewState.isInspectorPresented
            if sidebarItem.isCollapsed != collapseSidebar {
                if running, window?.isVisible == true, window?.toolbar?.isVisible == true,
                   !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    sidebarItem.animator().isCollapsed = collapseSidebar
                } else {
                    sidebarItem.isCollapsed = collapseSidebar
                }
            }
            if inspectorItem.isCollapsed != collapseInspector {
                if running, window?.isVisible == true, window?.toolbar?.isVisible == true,
                   !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    inspectorItem.animator().isCollapsed = collapseInspector
                } else {
                    inspectorItem.isCollapsed = collapseInspector
                }
            }
            window?.toolbar?.isVisible = running
            let scope = viewState.scope ?? .all
            window?.title = running ? scope.title : ""
            window?.subtitle = ""
            toolbarController.update(snapshot: model.snapshot, scope: scope,
                                     busy: model.busyMessage != nil, search: viewState.search)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeToolbar() }
        }
    }

    func windowWillClose(_ notification: Notification) { onClose() }
}
