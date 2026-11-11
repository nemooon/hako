import AppKit

// AppKit のエントリポイントはメインスレッドで実行される。
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // 起動時はメニューバーに常駐し、メインウィンドウ表示中は Dock にも表示する。
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
