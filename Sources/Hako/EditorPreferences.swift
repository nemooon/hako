import AppKit

/// 「〜で開く」に使うエディタの候補と、選択中のエディタ
@MainActor
final class EditorPreferences {
    struct Editor: Equatable {
        let name: String
        let bundleID: String
    }

    static let candidates: [Editor] = [
        Editor(name: "Zed", bundleID: "dev.zed.Zed"),
        Editor(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode"),
        Editor(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92"),
        Editor(name: "Windsurf", bundleID: "com.exafunction.windsurf"),
        Editor(name: "IntelliJ IDEA", bundleID: "com.jetbrains.intellij"),
        Editor(name: "IntelliJ IDEA CE", bundleID: "com.jetbrains.intellij.ce"),
        Editor(name: "Sublime Text", bundleID: "com.sublimetext.4"),
        Editor(name: "Nova", bundleID: "com.panic.Nova"),
        Editor(name: "TextMate", bundleID: "com.macromates.TextMate"),
    ]

    private static let defaultsKey = "editorBundleID"
    private let defaults: UserDefaults
    private let isInstalled: (String) -> Bool

    /// インストール済みのエディタ。LaunchServices への問い合わせはメニュー再構築ごとに
    /// 繰り返すと重いので、reload() したときだけ調べ直す
    private(set) var installed: [Editor] = []

    init(defaults: UserDefaults = .standard,
         isInstalled: @escaping (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }) {
        self.defaults = defaults
        self.isInstalled = isInstalled
        installed = Self.candidates.filter { isInstalled($0.bundleID) }
    }

    /// インストール状況を調べ直す。変化があれば true
    @discardableResult
    func reload() -> Bool {
        let detected = Self.candidates.filter { isInstalled($0.bundleID) }
        guard detected != installed else { return false }
        installed = detected
        return true
    }

    /// 選択中のエディタ。未選択(またはアンインストール済み)なら
    /// 候補リストの先頭にあるインストール済みエディタへフォールバック
    var selected: Editor {
        if let saved = defaults.string(forKey: Self.defaultsKey),
           let editor = installed.first(where: { $0.bundleID == saved }) {
            return editor
        }
        return installed.first ?? Self.candidates[0]
    }

    func select(bundleID: String) {
        defaults.set(bundleID, forKey: Self.defaultsKey)
    }
}
