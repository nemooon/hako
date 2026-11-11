import AppKit
import SwiftUI

@MainActor
final class CleanupModel: ObservableObject {
    @Published var scan: CleanupScan?
    @Published var selected = Set<String>()
    @Published var busy = false
    @Published var error: String?
    @Published var results: [CleanupResult] = []
    var onComplete: (() -> Void)?

    var chosen: [CleanupResource] { scan?.resources.filter { selected.contains($0.id) } ?? [] }
    var initialSelectionIDs: Set<String> { Set(scan?.resources.filter(\.initiallySelected).map(\.id) ?? []) }
    var size: String { Self.size(chosen.reduce(0) { $0 + $1.bytes }) }
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }

    func refresh() {
        guard !busy else { return }
        busy = true
        error = nil
        scan = nil
        selected = []
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try CleanupService.scan() }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let scan):
                    self.scan = scan
                    self.selected = self.initialSelectionIDs
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
    }

    func delete(in window: NSWindow) {
        guard !busy, let scan, !chosen.isEmpty else { return }
        let targets = chosen
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "選択した \(targets.count) 件を削除しますか？"
        alert.informativeText = "対象容量の合計: \(size)（共有分を含む目安）\n\nイメージは再取得・再ビルドが必要になります。手元にしかないイメージは復元できない場合があります。キャッシュの削除後は次回のビルドが遅くなります。"
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "キャンセル")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.busy = true
            self.selected = []
            DispatchQueue.global(qos: .userInitiated).async {
                let results = CleanupService.delete(targets, scan: scan)
                DispatchQueue.main.async {
                    self.results = results
                    self.busy = false
                    self.onComplete?()
                    self.refresh()
                }
            }
        }
    }
}

private struct CleanupView: View {
    @ObservedObject var model: CleanupModel
    let deleteSelected: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if let scan = model.scan {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("コンテナから参照されていないイメージと、削除可能なビルドキャッシュを表示しています。")
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("削除候補 \(scan.resources.count) 件").font(.headline)
                                Text("Docker: \(scan.context)\(scan.builder.map { " · ビルダー: \($0)" } ?? "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { model.refresh() } label: {
                                Label("再取得", systemImage: "arrow.clockwise")
                            }
                            .cleanupGlassButton()
                            .disabled(model.busy)
                        }
                        .padding(.top, 10)
                        if let warning = scan.warning {
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    if scan.resources.isEmpty {
                        ContentUnavailableView("削除候補はありません", systemImage: "externaldrive.badge.checkmark",
                                               description: Text("未使用のイメージや削除可能なビルドキャッシュがここに表示されます。"))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        GeometryReader { geometry in
                            // 列間隔と表の左右余白を確保し、残りを名前と詳細に配分する。
                            let flexibleWidth = max(0, geometry.size.width - 160 - 214)
                            Table(scan.resources) {
                                TableColumn("選択") { item in
                                    Toggle("\(item.name) を選択", isOn: Binding(
                                        get: { model.selected.contains(item.id) },
                                        set: { if $0 { model.selected.insert(item.id) } else { model.selected.remove(item.id) } }
                                    )).labelsHidden().toggleStyle(.checkbox).disabled(model.busy)
                                }.width(28)
                                TableColumn("名前") { item in
                                    Text(item.name).lineLimit(1).help("\(item.name)\n\(item.id)")
                                }.width(flexibleWidth * 0.58)
                                TableColumn("種類") { item in
                                    Text(item.kind.rawValue)
                                }.width(104)
                                TableColumn("容量") { item in
                                    Text(CleanupModel.size(item.bytes)).monospacedDigit()
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                }.width(82)
                                TableColumn("詳細") { item in
                                    Text(item.reason).foregroundStyle(.secondary).lineLimit(1).help(item.reason)
                                }.width(flexibleWidth * 0.42)
                            }
                            .tableStyle(.inset)
                            .scrollContentBackground(.hidden)
                            .alternatingRowBackgrounds(.disabled)
                        }
                    }
                } else if let error = model.error {
                    ContentUnavailableView {
                        Label("リソースを取得できませんでした", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error).textSelection(.enabled)
                    } actions: {
                        Button("再試行") { model.refresh() }.disabled(model.busy)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView("削除候補を取得しています…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if !model.results.isEmpty {
                    Divider()
                    DisclosureGroup("処理結果") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(model.results.enumerated()), id: \.offset) { _, result in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Label("\(result.success ? "処理完了" : "失敗") · \(result.name)",
                                              systemImage: result.success ? "checkmark.circle" : "exclamationmark.triangle")
                                            .foregroundStyle(result.success ? Color.primary : Color.red)
                                        Text(result.detail).font(.caption.monospaced()).textSelection(.enabled)
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: 125)
                    }.padding(16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                HStack(spacing: 12) {
                    Button("すべて選択") {
                        model.selected = Set(model.scan?.resources.map(\.id) ?? [])
                    }
                    .cleanupGlassButton()
                    Button("選択解除") { model.selected = [] }
                        .cleanupGlassButton()
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.busy ? "処理中…" : "\(model.chosen.count) 件選択 · 対象容量 \(model.size)")
                        .foregroundStyle(.secondary)
                    Button(role: .destructive, action: deleteSelected) {
                        Label("選択した項目を削除…", systemImage: "trash")
                    }
                    .cleanupGlassButton()
                    .disabled(model.chosen.isEmpty)
                }
                .cleanupGlassContainer()
                .font(.body)
                .disabled(model.busy || model.scan == nil)
                Text("タグなしイメージと削除可能なキャッシュを初期選択します。容量は共有分を含む目安です。Macの空き容量への反映にはColima側の容量回収が必要な場合があります。")
                    .font(.caption)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.bottom, 12)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 780, minHeight: 480)
    }
}

private extension View {
    @ViewBuilder
    func cleanupGlassContainer() -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) { self }
        } else {
            self
        }
    }

    @ViewBuilder
    func cleanupGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

@MainActor
final class CleanupWindowController: NSWindowController, NSWindowDelegate {
    let model = CleanupModel()

    init(onComplete: @escaping () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "未使用リソースを整理"
        window.toolbarStyle = .unifiedCompact
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        super.init(window: window)
        model.onComplete = onComplete
        let hostingController = NSHostingController(rootView: CleanupView(model: model, deleteSelected: { [weak self] in
            guard let self, let window = self.window else { return }
            self.model.delete(in: window)
        }))
        hostingController.sizingOptions = []
        let backgroundController = NSViewController()
        let material = NSVisualEffectView()
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        backgroundController.view = material
        backgroundController.addChild(hostingController)
        let content = hostingController.view
        content.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            content.topAnchor.constraint(equalTo: material.topAnchor),
            content.bottomAnchor.constraint(equalTo: material.bottomAnchor)
        ])
        window.contentViewController = backgroundController
        // システム標準のコンパクトなタイトル領域を使い、操作は表の近くに置く。
        let titlebar = NSToolbar(identifier: "HakoCleanupTitlebar")
        titlebar.allowsUserCustomization = false
        window.toolbar = titlebar
        window.setContentSize(NSSize(width: 960, height: 640))
        window.minSize = NSSize(width: 780, height: 540)
        window.setFrameAutosaveName("HakoCleanupWindow")
        window.center()
        window.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func open() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.refresh()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && sender.attachedSheet == nil }
}
