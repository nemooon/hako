import AppKit
import SwiftUI

/// コンテナ 1 つ分のログウィンドウの中身
private struct LogView: View {
    @Bindable var model: LogViewModel
    let openInTerminal: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            LogTextView(model: model)
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 240)
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            TextField("ログを絞り込む", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .frame(maxWidth: 280)
                .accessibilityLabel("ログを絞り込む")
            Spacer()
            Toggle(isOn: $model.follows) {
                Label("最新を表示", systemImage: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .help("新しい行が届いたら末尾までスクロールする")
            Button("消去", systemImage: "trash") { model.clear() }
                .help("表示中のログを消去する(コンテナのログは消えません)")
            Button("ターミナルで開く", systemImage: "terminal", action: openInTerminal)
                .help("docker logs -f をターミナルで実行する")
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            switch model.state {
            case .streaming:
                Image(systemName: "circle.fill").foregroundStyle(.green).font(.system(size: 7))
                Text("追従中")
            case .ended:
                Text("ログの終わりです(コンテナが停止しています)")
            case .failed(let status):
                Text(status < 0 ? "docker を実行できませんでした" : "ログを取得できませんでした(終了コード \(status))")
                    .foregroundStyle(.red)
            }
            Spacer()
            Text(model.query.isEmpty ? "\(model.lines.count) 行" : "絞り込み中 · 全 \(model.lines.count) 行")
                .monospacedDigit()
            if model.state != .streaming {
                Button("再読み込み", systemImage: "arrow.clockwise") { model.start() }
                    .controlSize(.small)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

/// 複数行の選択・コピーができ、大量の追記にも耐えるよう NSTextView で表示する
private struct LogTextView: NSViewRepresentable {
    let model: LogViewModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.font = Coordinator.font
        textView.setAccessibilityLabel("\(model.containerName) のログ")
        scrollView.hasHorizontalScroller = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.attach(textView: textView, scrollView: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // ここで読んだ値の変化だけが再描画の合図になる
        _ = (model.lines.count, model.generation, model.query, model.follows)
        context.coordinator.sync()
    }

    @MainActor
    final class Coordinator: NSObject {
        static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        private let model: LogViewModel
        private weak var textView: NSTextView?
        private weak var scrollView: NSScrollView?
        private var shownGeneration = -1
        private var shownQuery = ""
        private var shownCount = 0
        private var updating = false

        init(model: LogViewModel) { self.model = model }

        func attach(textView: NSTextView, scrollView: NSScrollView) {
            self.textView = textView
            self.scrollView = scrollView
            NotificationCenter.default.addObserver(
                self, selector: #selector(didScroll),
                name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        }

        /// 追記だけなら差分を足し、それ以外(消去・切り捨て・絞り込みの変更)は全体を描き直す
        func sync() {
            guard let textView, let storage = textView.textStorage else { return }
            updating = true
            defer { updating = false }
            let lines = model.lines
            let rebuild = shownGeneration != model.generation || shownQuery != model.query || shownCount > lines.count
            if rebuild {
                storage.setAttributedString(attributed(lines[...]))
            } else if shownCount < lines.count {
                storage.append(attributed(lines[shownCount...]))
            }
            shownGeneration = model.generation
            shownQuery = model.query
            shownCount = lines.count
            if model.follows { textView.scrollToEndOfDocument(nil) }
        }

        private func attributed(_ lines: ArraySlice<String>) -> NSAttributedString {
            let visible = lines.filter(model.matches)
            guard !visible.isEmpty else { return NSAttributedString() }
            let text = NSMutableAttributedString(
                string: visible.joined(separator: "\n") + "\n",
                attributes: [.font: Self.font, .foregroundColor: NSColor.textColor])
            // 絞り込み中は一致した箇所に色を付ける
            if !model.query.isEmpty {
                let string = text.string as NSString
                var range = NSRange(location: 0, length: string.length)
                while true {
                    let found = string.range(of: model.query, options: .caseInsensitive, range: range)
                    guard found.location != NSNotFound else { break }
                    text.addAttribute(.backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.5), range: found)
                    range = NSRange(location: NSMaxRange(found), length: string.length - NSMaxRange(found))
                }
            }
            return text
        }

        /// 自分でスクロールして末尾から離れたら追従をやめ、末尾まで戻したら再開する
        @objc private func didScroll() {
            guard !updating, let scrollView, let document = scrollView.documentView else { return }
            let visible = scrollView.contentView.documentVisibleRect
            let atBottom = visible.maxY >= document.bounds.maxY - 4
            if model.follows != atBottom { model.follows = atBottom }
        }
    }
}

/// ログウィンドウ。閉じたら docker logs も止める
@MainActor
final class LogWindowController: NSWindowController, NSWindowDelegate {
    private static let frameName = "HakoLogWindow"
    let model: LogViewModel
    private let onClose: () -> Void

    init(model: LogViewModel, cascadeFrom: NSWindow?, openInTerminal: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "\(model.containerName) のログ"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let hosting = NSHostingController(rootView: LogView(model: model, openInTerminal: openInTerminal))
        // 中身の最小サイズにウィンドウを縮めない(大きさはウィンドウ側で決める)
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 820, height: 520))
        window.contentMinSize = NSSize(width: 480, height: 240)
        // 大きさは前回閉じたウィンドウに合わせる。複数開くときは少しずつずらす
        window.center()
        window.setFrameUsingName(Self.frameName)
        if let cascadeFrom {
            let topLeft = NSPoint(x: cascadeFrom.frame.minX, y: cascadeFrom.frame.maxY)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: topLeft))
        }
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func open() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func focusSearch() { model.requestSearchFocus() }

    func windowWillClose(_ notification: Notification) {
        window?.saveFrame(usingName: Self.frameName)
        model.stop()
        onClose()
    }
}
