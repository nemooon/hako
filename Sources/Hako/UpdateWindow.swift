import AppKit
import SwiftUI

/// アップデートウィンドウの中身。Hako と Colima の欄を上下に並べ、欄ごとに更新する
private struct UpdateView: View {
    let model: UpdateModel
    let restartHako: () -> Void
    let restartColima: () -> Void
    let colimaRunning: () -> Bool
    let close: () -> Void

    // 外側はスクロールさせず、ウィンドウの高さを中身に合わせる(変更内容の欄だけ高さを抑えてスクロール)
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
                UpdateSection(title: "Hako", item: model.hako, package: .hako, model: model,
                              releasesPage: UpdateChecker.hakoReleasesPageURL,
                              installedMessage: { "\($0) のインストールが完了しました。再起動すると切り替わります" },
                              restartTitle: "再起動", restart: model.hako.phase == .installed ? restartHako : nil,
                              close: close)
                Divider().padding(.vertical, 16)
                let running = colimaRunning()
                UpdateSection(title: "Colima", item: model.colima, package: .colima, model: model,
                              releasesPage: UpdateChecker.colimaReleasesPageURL,
                              installedMessage: { version in
                                  running
                                      ? "\(version) のインストールが完了しました。Colima を再起動すると切り替わります(再起動中はコンテナが止まります)"
                                      : "\(version) のインストールが完了しました。次に Colima を起動したときから使われます"
                              },
                              restartTitle: "Colima を再起動",
                              restart: model.colima.phase == .installed && running ? restartColima : nil,
                              close: close)
        }
        .padding(20)
        .frame(width: 560, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 1 製品分の欄。状態に応じて文言・変更内容・コマンド・ボタンを切り替える
private struct UpdateSection: View {
    let title: String
    let item: UpdateItem
    let package: UpdatePackage
    let model: UpdateModel
    let releasesPage: URL
    let installedMessage: (String) -> String
    let restartTitle: String
    let restart: (() -> Void)?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title3.weight(.semibold))
                Text(versionText).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                actions
            }
            status
            if item.phase == .available || item.phase == .updating {
                details
            }
            if let error = item.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var versionText: String {
        switch (item.current, item.latest) {
        case let (current?, latest?) where item.phase == .available || item.phase == .updating:
            return "\(current) → \(latest)"
        case let (current?, _):
            return current
        default:
            return ""
        }
    }

    @ViewBuilder private var actions: some View {
        switch item.phase {
        case .available:
            Button("アップデート") { Task { await model.update(package) } }
                .buttonStyle(.borderedProminent)
                .disabled(model.isUpdating)
        case .updating:
            ProgressView().controlSize(.small)
        case .installed:
            if let restart {
                // もう一方の欄が更新中なら、閉じたり終了したりしない
                Button("あとで", action: close).disabled(model.isUpdating)
                Button(restartTitle, action: restart).buttonStyle(.borderedProminent).disabled(model.isUpdating)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var status: some View {
        switch item.phase {
        case .checking:
            Label("新しいバージョンを確認しています…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .upToDate:
            Label("\(item.current ?? "") は最新です", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .available:
            EmptyView()
        case .updating:
            Text("アップデート中…").foregroundStyle(.secondary)
        case .installed:
            Label(installedMessage(item.latest ?? ""), systemImage: "checkmark.circle.fill")
        case .unavailable(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Label(reason, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                if let latest = item.newerLatest {
                    Link("リリースページで \(latest) を見る", destination: releasesPage).font(.caption)
                }
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !item.notes.isEmpty {
                Text("変更内容").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(Self.notesText(item.notes))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 160)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
            Text("実行するコマンド").font(.caption).foregroundStyle(.secondary)
            Text(model.commands(for: package).joined(separator: "\n"))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// GitHub のリリースノート(Markdown)。強調やリンクだけ解釈し、改行はそのまま残す
    static func notesText(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}

@MainActor
final class UpdateWindowController: NSWindowController, NSWindowDelegate {
    private let model: UpdateModel

    /// relaunchHako: 再起動しない場合(プレビュー中)にウィンドウを閉じるのも呼び出し側の役目
    /// restartColima: 再起動を始められなければ false(別の操作の処理中など)
    init(model: UpdateModel, relaunchHako: @escaping () -> Void,
         restartColima: @escaping () -> Bool, colimaRunning: @escaping () -> Bool) {
        self.model = model
        // 大きさは中身で決まるので、利用者によるリサイズはさせない
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 240),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "アップデート"
        window.toolbarStyle = .unifiedCompact
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let hosting = NSHostingController(rootView: UpdateView(
            model: model,
            restartHako: { [weak model] in
                // 隔離属性を外せなかったら再起動しない(新しい Hako が起動できずに消えるため)
                Task { @MainActor in
                    if await model?.prepareHakoRelaunch() == true {
                        relaunchHako()
                    } else {
                        NSSound.beep()
                    }
                }
            },
            restartColima: { [weak self] in
                // 始められなかったときはウィンドウを閉じずに知らせる(再起動したと思い込ませない)
                if restartColima() {
                    self?.window?.performClose(nil)
                } else {
                    NSSound.beep()
                }
            },
            colimaRunning: colimaRunning,
            // close() は windowShouldClose を通らないので performClose で閉じる
            close: { [weak self] in self?.window?.performClose(nil) }
        ))
        // 状態が変わって中身の高さが変わったら、ウィンドウも追従させる
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
        // 初回は中央に置き、保存済みの位置があればそれで上書きする。
        // 大きさは保存値ではなく、今の中身に合わせ直す(上端は保つ)
        window.center()
        window.setFrameUsingName("HakoUpdateWindow")
        let top = window.frame.maxY
        window.setContentSize(hosting.view.fittingSize)
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
        window.setFrameAutosaveName("HakoUpdateWindow")
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 表示して、そのたびに最新リリースを確認し直す(更新中に前面へ出すだけのときは refresh: false)
    func open(refresh: Bool = true) {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        if refresh { Task { await model.refresh() } }
    }

    /// 更新中は終了させない(brew が途中で止まって中途半端な状態になるため)
    var allowsTermination: Bool { !model.isUpdating }

    /// 更新の途中で閉じて中途半端な状態にしない
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.isUpdating }
}

/// 自分の終了を待ってから同じ .app を開き直す
/// (新しいプロセスをすぐ立ち上げると、メニューバーのアイコンが一瞬 2 つ並ぶため)
@MainActor
enum AppRelauncher {
    static func relaunch(appPath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; open "$2""#,
            "sh", String(ProcessInfo.processInfo.processIdentifier), appPath,
        ]
        do {
            try process.run()
        } catch {
            NSSound.beep()
            return
        }
        NSApp.terminate(nil)
    }
}
