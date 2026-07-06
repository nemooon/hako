import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Dock アイコンを出さず、メニューバーのみに常駐する
app.setActivationPolicy(.accessory)
app.run()
