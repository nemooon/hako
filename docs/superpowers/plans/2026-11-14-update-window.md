# アップデートウィンドウ Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hako と Colima を、専用の「アップデート」ウィンドウから欄ごとのボタンで Homebrew 経由で更新できるようにする。

**Architecture:** Homebrew と xattr を呼ぶ手順は `HomebrewUpdater`(実行関数を差し替え可能な値型)に閉じ込める。ウィンドウの状態は `@Observable` な `UpdateModel` が持ち、SwiftUI の `UpdateView` を `UpdateWindowController`(整理画面と同じ作り)に載せる。入口(アプリ名メニュー・メニューバーの 2 項目)は `CommandCenter.openUpdates` に集める。

**Tech Stack:** Swift 5.9 / AppKit + SwiftUI / Observation / XCTest(`swift test`)

**Spec:** `docs/superpowers/specs/2026-11-14-update-window-design.md`

## Global Constraints

- 対応 OS は macOS 14.4 以降(`Package.swift` の `.macOS("14.4")`)。macOS 26 以降の API は `#available` で分岐する
- 外部コマンドはシェルを介さず引数配列で実行する(`Shell.runProgram` / `Shell.exec`)
- Hako の更新コマンド: `brew upgrade --cask --no-quit --no-ask nemooon/tap/hako`、続けて `xattr -dr com.apple.quarantine <実行中の Hako.app のパス>`
- Colima の更新コマンド: `brew upgrade --no-ask colima`(xattr は実行しない)
- brew の場所は `/opt/homebrew/bin/brew`、`/usr/local/bin/brew` の順に探す
- 画面の文言は日本語。spec の状態表の文言をそのまま使う
- Colima の VM を確認なしに再起動しない

## Review Focus

- `brew list --versions` が複数バージョンを返す(`colima 0.10.2 0.10.3`)→ 最後(最新)のバージョンとして扱う(Task 2 のテストで固定)
- `swift run` など .app として動いていない → Hako 欄だけ対象外、Colima 欄は更新できる(Task 3 のテストで固定)
- GitHub API に届かない(オフライン・レート制限)→ 欄を「新しいバージョンを確認できませんでした」の対象外表示にし、固まらない(Task 3 のテストで固定)
- 片方の更新中にもう片方のボタンを押す → 何も起きない(Task 3 のテストで固定)
- 更新中にウィンドウを閉じようとする → 閉じない(Task 4 の `windowShouldClose`、手動確認)

---

### Task 1: リリース情報(バージョン+本文)を取得できるようにする

**Files:**
- Modify: `Sources/Hako/UpdateChecker.swift`
- Test: `Tests/HakoTests/UpdateCheckerTests.swift`(新規)

**Interfaces:**
- Produces:
  - `struct UpdateChecker.Release: Equatable { let version: String; let notes: String }`
  - `static func UpdateChecker.parseRelease(_ data: Data) -> Release?` — `tag_name` の先頭 `v` を除き、`body` が無ければ `""`
  - `static func UpdateChecker.latestRelease(repo: String) async -> Release?` — 通信・解析失敗は nil
  - 既存の `newerRelease(repo:current:)` は `latestRelease` を使う形に書き換え、振る舞いは変えない

- [ ] **Step 1: 失敗するテストを書く**

```swift
func testParseReleaseStripsVPrefixAndKeepsBody() {
    let data = Data(#"{"tag_name":"v0.11.0","body":"- 修正"}"#.utf8)
    XCTAssertEqual(UpdateChecker.parseRelease(data), .init(version: "0.11.0", notes: "- 修正"))
}
func testParseReleaseWithoutBodyOrTag() {
    XCTAssertEqual(UpdateChecker.parseRelease(Data(#"{"tag_name":"0.6"}"#.utf8)), .init(version: "0.6", notes: ""))
    XCTAssertNil(UpdateChecker.parseRelease(Data(#"{"message":"rate limited"}"#.utf8)))
}
```

- [ ] **Step 2: `swift test --filter UpdateCheckerTests` で FAIL(`parseRelease` が無い)を確認**
- [ ] **Step 3: `Release` / `parseRelease` / `latestRelease` を実装し、`newerRelease` をそれで書き換える**
- [ ] **Step 4: `swift test` で全件 PASS を確認**
- [ ] **Step 5: コミット**(`git commit -m "リリースノート本文を取得できるようにする"`)

### Task 2: Homebrew で更新する手順(HomebrewUpdater)

**Files:**
- Create: `Sources/Hako/HomebrewUpdater.swift`
- Test: `Tests/HakoTests/HomebrewUpdaterTests.swift`

**Interfaces:**
- Produces:
  - `enum UpdatePackage { case hako, colima }`
  - `enum UpdateError: Error, Equatable { case notInstalledByHomebrew; case upgradeFailed(String); case versionNotYetAvailable(String); case quarantineRemovalFailed(detail: String, command: String) }` と `var message: String`(spec の文言。`versionNotYetAvailable("0.7")` → 「Homebrew にまだ 0.7 が反映されていません。しばらくしてから再試行してください」、`quarantineRemovalFailed` → 「アップデートは完了しましたが隔離属性を削除できませんでした」+ detail + 手で打つコマンド)
  - `struct HomebrewUpdater { typealias Runner = (_ path: String, _ arguments: [String]) async -> Shell.Result; let brew: String; let run: Runner }`
  - `static func HomebrewUpdater.locateBrew(fileExists: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String?`
  - `static func HomebrewUpdater.live() -> HomebrewUpdater?`(brew が無ければ nil、`run` は `Shell.runProgram`)
  - `func installedVersion(_ package: UpdatePackage) async -> String?` — hako: `list --cask --versions hako`、colima: `list --formula --versions colima`。出力 1 行目の最後の語
  - `func upgrade(_ package: UpdatePackage, to expected: String, appPath: String?) async throws` — spec「更新の手順とエラー」の順。hako の xattr は `/usr/bin/xattr -dr com.apple.quarantine <appPath>`

- [ ] **Step 1: 失敗するテストを書く**(偽の Runner が呼ばれた `[path] + arguments` を記録し、引数で返す結果を決める)

```swift
func testHakoUpgradeRunsBrewThenXattrInOrder()      // list(0.6) → upgrade → list(0.7) → xattr。記録したコマンド列が spec の 4 つと完全一致
func testColimaUpgradeDoesNotRunXattr()            // ["/opt/homebrew/bin/brew","upgrade","--no-ask","colima"] を含み、xattr を含まない
func testNotInstalledByHomebrewStopsBeforeUpgrade() // list が status 1 → .notInstalledByHomebrew、upgrade を呼ばない
func testUpgradeFailureCarriesOutput()             // upgrade が status 1, stderr "Error: boom" → .upgradeFailed に "Error: boom" を含む
func testTapLagIsReportedAndXattrIsSkipped()       // 2 回目の list も 0.6 → .versionNotYetAvailable("0.7")、xattr を呼ばない
func testQuarantineFailureShowsManualCommand()     // xattr が status 1 → message に "xattr -dr com.apple.quarantine /Applications/Hako.app" を含む
func testInstalledVersionTakesLatestOfSeveral()    // "colima 0.10.2 0.10.3\n" → "0.10.3"
func testLocateBrewPrefersAppleSilicon()           // 両方ある → /opt/homebrew/bin/brew、片方のみ → /usr/local/bin/brew、無し → nil
```

- [ ] **Step 2: `swift test --filter HomebrewUpdaterTests` で FAIL を確認**
- [ ] **Step 3: 上の Interfaces どおり実装する**
- [ ] **Step 4: `swift test` で全件 PASS を確認**
- [ ] **Step 5: コミット**(`git commit -m "Homebrew で Hako と Colima を更新する手順を追加"`)

### Task 3: ウィンドウの状態(UpdateModel)

**Files:**
- Create: `Sources/Hako/UpdateModel.swift`
- Modify: `Sources/Hako/StatusStore.swift`(更新確認の結果を反映するメソッド)
- Test: `Tests/HakoTests/UpdateModelTests.swift`

**Interfaces:**
- Consumes: Task 1 の `UpdateChecker.Release` / `latestRelease`、Task 2 の `HomebrewUpdater` / `UpdatePackage` / `UpdateError`
- Produces:
  - `struct UpdateItem: Equatable { enum Phase: Equatable { case checking, upToDate, available, updating, installed, unavailable(String) }; var phase: Phase; var current: String?; var latest: String?; var notes: String; var error: String? }`
  - `@MainActor @Observable final class UpdateModel`
    - `struct Backend { var latestRelease: (String) async -> UpdateChecker.Release?; var hakoVersion: String?; var hakoAppPath: String?; var colimaVersion: () async -> String?; var updater: HomebrewUpdater? }` と `static func live() -> Backend`(`hakoAppPath` は `Bundle.main.bundleURL` が `.app` のときだけそのパス)
    - `init(backend: Backend, store: StatusStore)`
    - `private(set) var hako: UpdateItem` / `private(set) var colima: UpdateItem`
    - `var isUpdating: Bool`(どちらかが `.updating`)
    - `func refresh() async` — 両方を `.checking` にしてから確認。結果を `store.recordUpdateCheck(hako:colima:colimaVersion:)` に渡す
    - `func update(_ package: UpdatePackage) async` — `isUpdating` 中や `.available` 以外では何もしない。成功で `.installed`、`UpdateError` で `.available` に戻して `error = message`。Colima 成功後は `colima.current` を新バージョンにする
  - `StatusStore.recordUpdateCheck(hako: String?, colima: String?, colimaVersion: String?)` — `availableUpdate` / `availableColimaUpdate` / `colimaVersion` に `assign` で反映
- 対象外の理由(spec の文言):hakoAppPath が nil →「.app として動いていないため、アップデートできません」/ updater が nil →「Homebrew が見つかりません」/ `installedVersion` が nil →「Homebrew でインストールされていません」/ `latestRelease` が nil →「新しいバージョンを確認できませんでした」

- [ ] **Step 1: 失敗するテストを書く**(偽の Runner を持つ `HomebrewUpdater` と偽の `latestRelease` で組み立てる)

```swift
func testRefreshShowsAvailableAndUpToDate()        // hako 0.6→0.7 で .available(notes 付き)、colima 0.10.3 最新で .upToDate。store.availableUpdate == "0.7"、availableColimaUpdate == nil
func testNotBundledMakesOnlyHakoUnavailable()      // hakoAppPath nil → hako は .unavailable、colima は .available
func testMissingBrewMakesBothUnavailable()         // updater nil → 両方 .unavailable("Homebrew が見つかりません")
func testOfflineCheckDoesNotHang()                 // latestRelease が nil → .unavailable("新しいバージョンを確認できませんでした")
func testColimaUpdateSucceedsAndUpdatesCurrent()   // update(.colima) → .installed、current == "0.11.0"
func testFailureReturnsToAvailableWithMessage()    // upgrade 失敗 → .available、error に "アップデートに失敗しました" を含む
func testSecondUpdateIsIgnoredWhileUpdating()      // hako の update 中(Runner を待たせる)に update(.colima) → colima の upgrade は呼ばれない
```

- [ ] **Step 2: `swift test --filter UpdateModelTests` で FAIL を確認**
- [ ] **Step 3: 上の Interfaces どおり実装する**
- [ ] **Step 4: `swift test` で全件 PASS を確認**
- [ ] **Step 5: コミット**(`git commit -m "アップデートウィンドウの状態を管理する UpdateModel を追加"`)

### Task 4: ウィンドウ(UpdateView / UpdateWindowController)と再起動

**Files:**
- Create: `Sources/Hako/UpdateWindow.swift`

**Interfaces:**
- Consumes: Task 3 の `UpdateModel` / `UpdateItem`
- Produces:
  - `@MainActor final class UpdateWindowController: NSWindowController, NSWindowDelegate`
    - `init(model: UpdateModel, restartColima: @escaping () -> Void, colimaRunning: @escaping () -> Bool)`
    - `func open()` — 表示して `Task { await model.refresh() }`
    - `windowShouldClose` は `!model.isUpdating`
  - `enum AppRelauncher { static func relaunch(appPath: String) }` — `/bin/sh -c 'while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; open "$2"' sh <自分の PID> <appPath>` を待たずに起動してから `NSApp.terminate(nil)`
- 画面: spec「画面」「欄ごとの状態」の表どおり。タイトル「アップデート」。欄は Hako → Colima の順、`Divider` で区切る。変更内容は `AttributedString(markdown:options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))` で表示し、高さを抑えてスクロール。実行するコマンドは等幅・選択可能。完了(Colima)は `colimaRunning()` で文言とボタンを切り替える。対象外で `latest` があればリリースページへの `Link`(`UpdateChecker.hakoReleasesPageURL` / `colimaReleasesPageURL`)。ウィンドウの作りと見た目は `CleanupWindowController` に合わせ、frame autosave 名は `HakoUpdateWindow`(center → setFrameUsingName → setFrameAutosaveName の順)

- [ ] **Step 1: 実装する**
- [ ] **Step 2: `swift build` が警告なしで通ることを確認**
- [ ] **Step 3: コミット**(`git commit -m "アップデートウィンドウの画面と Hako の再起動を追加"`)

### Task 5: 入口をつなぐ

**Files:**
- Modify: `Sources/Hako/CommandCenter.swift`(`var openUpdates: () -> Void = {}` を追加)
- Modify: `Sources/Hako/AppDelegate.swift`(アプリ名メニューに「アップデートを確認…」を「Hako について」の直後に追加、`updateWindow` を保持して開く、`commands.openUpdates` を設定。「Colima を再起動」は `commands.restartColima()`、`colimaRunning` は `store.snapshot?.running == true`)
- Modify: `Sources/Hako/StatusMenuController.swift`(Hako / Colima の更新項目の action を `openUpdates` に変更し、subtitle をどちらも「クリックしてアップデート」にする)

- [ ] **Step 1: 実装する**
- [ ] **Step 2: `swift build` と `swift test` が通ることを確認**
- [ ] **Step 3: アプリを動かして確認する**
  - `swift run` で起動し、「Hako」メニュー →「アップデートを確認…」でウィンドウが開く
  - Hako 欄が「.app として動いていないため、アップデートできません」、Colima 欄が「最新」または「更新あり」になる
  - `scripts/bundle.sh` で作った `dist/Hako.app` から開くと、Hako 欄が「0.6 は最新です」になる(更新は実行しない)
- [ ] **Step 4: コミット**(`git commit -m "アップデートウィンドウを各メニューから開けるようにする"`)
