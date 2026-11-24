# Colima プロファイル切り替え Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Colima のプロファイル一覧をメニューとメインウィンドウに出し、選ぶと docker context ごと操作対象を切り替えられるようにする。

**Architecture:** `colima ls --json` の結果から `ColimaProfile` の一覧を作り、`ColimaSnapshot` に持たせる。
切り替えは `CommandCenter.switchProfile(_:)` に集約する。実行中なら `docker context use`、停止中なら `colima start --profile` を実行する。
メニュー（Colima サブメニュー）、ツールバーのポップアップ、停止中画面の選択メニューの3か所から、この1つの操作を呼ぶ。

**Tech Stack:** Swift 5.9 / SwiftPM、AppKit（NSMenu・NSToolbar）、SwiftUI（メインウィンドウ本体）、XCTest

**Spec:** `docs/superpowers/specs/2026-11-24-colima-profiles-design.md`

## Global Constraints
- macOS 14.4 以上（Package.swift のまま）。依存は追加しない
- プロファイルが1つ（default のみ）のときは、メニュー・ツールバー・停止中画面のどこにもプロファイル UI を出さない。見た目は今と同じ
- context 名: default → `colima`、それ以外 → `colima-<name>`
- UI の文言は日本語。見出しは「プロファイル」、状態は「実行中」「停止中」
- やらないこと: プロファイルの作成・削除、複数プロファイルの同時一覧
- 既存テストの `ColimaSnapshot(profile:running:vmInfo:containers:composeProjects:)` 呼び出しを壊さない（新しいプロパティには既定値をつける）

## Review Focus
1. **docker context が Colima 以外（`desktop-linux` など）**: どのプロファイルにもチェックがつかない。どれを選んでも切り替えが実行される → Task 1・2 のテスト
2. **今のプロファイルをもう一度選ぶ**: 何も実行しない → Task 2 のテスト
3. **`colima ls --json` が失敗する／空**: 一覧が空になり、プロファイル UI は出ない。落ちない → Task 1・3 のテスト
4. **処理中（busy）に選ぶ**: 何も実行しない → Task 2 のテスト
5. **`status` が Running 以外（Stopped・Broken など）**: 停止中として扱い、選ぶと `colima start` を実行する → Task 1・2 のテスト

---

### Task 0: 作業ブランチ
- [ ] `main` から `colima-profiles` ブランチを切る（`log-viewer` の未コミットの変更は持ち込まない。worktree 推奨）
- [ ] spec と、この plan をコミットする

### Task 1: プロファイル一覧の取得

**Files:**
- Modify: `Sources/Hako/ColimaService.swift`（`ColimaSnapshot`、`fetchSnapshot`、`currentProfile`、`colimaStatus`、`anonymize`）
- Test: `Tests/HakoTests/ColimaProfileTests.swift`（新規）

**Interfaces:**
- Produces:
  - `struct ColimaProfile: Equatable { let name: String; let running: Bool; var dockerContext: String }`
  - `ColimaSnapshot` に `var profiles: [ColimaProfile] = []` と `var isColimaContext: Bool = true` を追加する
  - `static func ColimaService.parseProfiles(_ json: String) -> [ColimaProfile]`
  - `static func ColimaService.profile(forContext context: String) -> String?`（Colima 以外の context なら nil）

- [ ] **Step 1: 失敗するテストを書く**

```swift
func testParseProfiles() {
    let json = """
    {"name":"default","status":"Running","arch":"aarch64","cpus":2}
    {"name":"work","status":"Stopped"}
    {"name":"old","status":"Broken"}
    """
    XCTAssertEqual(ColimaService.parseProfiles(json), [
        ColimaProfile(name: "default", running: true),
        ColimaProfile(name: "work", running: false),
        ColimaProfile(name: "old", running: false),
    ])
    XCTAssertEqual(ColimaService.parseProfiles(""), [])
}

func testDockerContextName() {
    XCTAssertEqual(ColimaProfile(name: "default", running: true).dockerContext, "colima")
    XCTAssertEqual(ColimaProfile(name: "work", running: true).dockerContext, "colima-work")
}

func testProfileForContext() {
    XCTAssertEqual(ColimaService.profile(forContext: "colima"), "default")
    XCTAssertEqual(ColimaService.profile(forContext: "colima-work"), "work")
    XCTAssertNil(ColimaService.profile(forContext: "desktop-linux"))
    XCTAssertNil(ColimaService.profile(forContext: ""))
}
```

- [ ] **Step 2: 実行して失敗を確認する**
  Run: `swift test --filter ColimaProfileTests`
  Expected: コンパイルエラー（`ColimaProfile` が未定義）

- [ ] **Step 3: 実装する**
  - `ColimaProfile` は `status` を小文字にして `"running"` と比べる。`dockerContext` は計算プロパティにする
  - `currentProfile()` を `profile(forContext:)` に置き換える。`fetchSnapshot` では `profile = profile(forContext:) ?? "default"`、`isColimaContext = profile(forContext:) != nil` とする
  - `colima ls --json` の呼び出しは1回にまとめる。`colimaStatus` は取得済みの出力を受け取って vmInfo を作り、同じ出力から `parseProfiles` で一覧を作る
  - 停止中の分岐（`running: false` で返す箇所）にも `profiles` と `isColimaContext` を入れる
  - `anonymize` は `profiles` と `isColimaContext` をそのまま引き継ぐ

- [ ] **Step 4: テストを実行して通ることを確認する**
  Run: `swift test`
  Expected: 全件 PASS

- [ ] **Step 5: コミット**
  `ColimaService.swift` と `ColimaProfileTests.swift` をコミットする。メッセージ例: 「Colima のプロファイル一覧を取得する」

### Task 2: 切り替え操作

**Files:**
- Modify: `Sources/Hako/CommandCenter.swift`、`Sources/Hako/MainWindow.swift:5-11`（`MainWindowAction`）
- Test: `Tests/HakoTests/CommandCenterTests.swift`

**Interfaces:**
- Consumes: `ColimaSnapshot.profiles`、`isColimaContext`、`ColimaProfile.dockerContext`（Task 1）
- Produces:
  - `func CommandCenter.switchProfile(_ name: String)`
  - `MainWindowAction.switchProfile(String)`（`perform` から `switchProfile` を呼ぶ）

- [ ] **Step 1: 失敗するテストを書く**
  既存の `testRestartColimaReportsWhenBusy` と同じ形で、`run` に渡された引数を記録する Backend を使う。先に `store.refresh()` で次のスナップショットを読み込ませる。

```swift
// 共通スナップショット: profile "default"、profiles [default 実行中, work 実行中, lab 停止中]
func testSwitchToRunningProfileChangesDockerContext()   // switchProfile("work")
    // → commands.last == ["docker", "context", "use", "colima-work"]
func testSwitchToStoppedProfileStartsIt()               // switchProfile("lab")
    // → commands.last == ["colima", "start", "--profile", "lab"]
func testSwitchToCurrentProfileDoesNothing()            // switchProfile("default")
    // → commands が空
func testSwitchFromNonColimaContextRunsEvenForSameName() // isColimaContext = false で switchProfile("default")
    // → ["docker", "context", "use", "colima"]
func testSwitchWhileBusyDoesNothing()                   // busy 中に switchProfile("work") → 何も追加されない
func testSwitchToUnknownProfileDoesNothing()            // switchProfile("nope") → 何も追加されない
```

- [ ] **Step 2: 実行して失敗を確認する**
  Run: `swift test --filter CommandCenterTests`
  Expected: コンパイルエラー（`switchProfile` が未定義）

- [ ] **Step 3: 実装する**
  `switchProfile` は、busy のとき・一覧にないとき・`isColimaContext && name == store.colimaProfile` のときは何もしない。
  - 対象が実行中: `execute("プロファイル \(name) に切り替え中…", ["docker", "context", "use", profile.dockerContext])`
  - 対象が停止中: `execute("プロファイル \(name) を起動中…", ["colima", "start", "--profile", name])`

- [ ] **Step 4: テストを実行して通ることを確認する**
  Run: `swift test`
  Expected: 全件 PASS

- [ ] **Step 5: コミット**
  メッセージ例: 「Colima のプロファイルを切り替える操作を追加する」

### Task 3: メニューのプロファイル一覧

**Files:**
- Modify: `Sources/Hako/StatusMenuController.swift`（`colimaStatusEntry`、`@objc` ハンドラ群）
- Test: `Tests/HakoTests/StatusMenuProfileTests.swift`（新規）

**Interfaces:**
- Consumes: `CommandCenter.switchProfile(_:)`（Task 2）
- Produces: `static func StatusMenuController.profileEntries(for snapshot: ColimaSnapshot) -> [MenuEntry]`

- [ ] **Step 1: 失敗するテストを書く**

```swift
func testProfileEntriesHiddenForSingleProfile() {
    // profiles = [default] → profileEntries が空
    // profiles = []        → profileEntries が空
}

func testProfileEntriesListProfilesWithCheckAndStatus() {
    // profile "default"、profiles [default 実行中, work 停止中]
    let entries = StatusMenuController.profileEntries(for: snapshot)
    XCTAssertTrue(entries[0].isSeparator)
    XCTAssertEqual(entries[1].title, "プロファイル")
    XCTAssertEqual(entries[2...].map(\.title), ["default", "work"])
    XCTAssertEqual(entries[2...].map(\.subtitle), ["実行中", "停止中"])
    XCTAssertEqual(entries[2...].map(\.isChecked), [true, false])
    XCTAssertEqual(entries[3].representedObject as? String, "work")
}

func testProfileEntriesUncheckedForNonColimaContext() {
    // isColimaContext = false → isChecked がすべて false
}
```

- [ ] **Step 2: 実行して失敗を確認する**
  Run: `swift test --filter StatusMenuProfileTests`
  Expected: コンパイルエラー

- [ ] **Step 3: 実装する**
  - `profileEntries` の並べ方は、既存の「設定 > プロジェクトを開くエディタ」（`settingsEntry`）と同じ形（`.info` の見出し＋ `isChecked` 付きの `.action`）にする
  - `colimaStatusEntry` の children の末尾に `profileEntries(for: snapshot)` を足す
  - `@objc private func selectProfile(_ sender: NSMenuItem)` は、`representedObject as? String` を `commands.switchProfile` に渡す

- [ ] **Step 4: テストを実行して通ることを確認する**
  Run: `swift test`
  Expected: 全件 PASS

- [ ] **Step 5: コミット**
  メッセージ例: 「メニューに Colima のプロファイル一覧を出す」

### Task 4: メインウィンドウのプロファイル選択

**Files:**
- Modify: `Sources/Hako/MainWindowToolbar.swift`、`Sources/Hako/MainWindow.swift:145-160`（停止中の `ContentUnavailableView`）
- Test: `Tests/HakoTests/MainWindowTests.swift`

**Interfaces:**
- Consumes: `MainWindowAction.switchProfile(String)`（Task 2）
- Produces: `MainWindowToolbarController` に `let profileItem: NSMenuToolbarItem` を追加する（テストから中身を確認できるよう internal にする）

- [ ] **Step 1: 失敗するテストを書く**

```swift
@MainActor
func testToolbarProfileMenuReflectsProfiles() {
    var actions: [MainWindowAction] = []
    let controller = MainWindowToolbarController(perform: { actions.append($0) },
                                                 toggleSidebar: {}, toggleInspector: {}, searchChanged: { _ in })
    // profile "default"、profiles [default 実行中, work 停止中] で update
    XCTAssertEqual(controller.profileItem.title, "default")
    XCTAssertEqual(controller.profileItem.menu.items.map(\.title), ["default", "work"])
    XCTAssertEqual(controller.profileItem.menu.items.map(\.state), [.on, .off])
    // "work" の項目の action を発火 → actions に .switchProfile("work") が入る
}
```

- [ ] **Step 2: 実行して失敗を確認する**
  Run: `swift test --filter MainWindowTests`
  Expected: コンパイルエラー

- [ ] **Step 3: 実装する**
  - **ツールバー**: `ID.profile` を `toolbarAllowedItemIdentifiers` に足す。`update` のときに、プロファイルが2つ以上なら `.sidebarTrackingSeparator` の直後に挿入し、1つ以下なら取り除く（`updateCommandsVisibility` と同じやり方）。メニュー項目の subtitle には状態を出す。busy 中は `isEnabled = false`
  - **停止中画面**: プロファイルが2つ以上なら、「Colima を起動」ボタンの下に SwiftUI の `Menu("プロファイル: \(model.colimaProfile)")` を置く。中身はプロファイル名（今のものにチェック）で、選ぶと `perform(.switchProfile(name))`。busy 中は disabled（ツールバーは停止中に隠れるため、ここで代わりに選べるようにする）

- [ ] **Step 4: テストを実行して通ることを確認する**
  Run: `swift test`
  Expected: 全件 PASS

- [ ] **Step 5: 実機で確認する**
  `colima start --profile hako-test --cpu 1 --memory 1` で2つ目のプロファイルを作り、次を確認する。終わったら `colima delete -p hako-test` で消す
  - メニューに一覧が出て、`hako-test` を選ぶと `docker context show` が `colima-hako-test` になる
  - ツールバーのポップアップから default に戻せる
  - default を止めた状態で、停止中画面のメニューから切り替えられる

- [ ] **Step 6: コミット**
  メッセージ例: 「メインウィンドウでプロファイルを切り替えられるようにする」
