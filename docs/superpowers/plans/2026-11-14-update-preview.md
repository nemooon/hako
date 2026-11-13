# アップデートのプレビューモード Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `HAKO_UPDATE_PREVIEW` を付けて起動したときだけ、本物の brew / colima に触れずに仮想のアップデートを表示・操作できるようにする。

**Architecture:** 新しい `UpdatePreview` が環境変数の解釈・見本のリリース・偽の `HomebrewUpdater` をまとめて持つ。`UpdateModel.Backend.live()` と `StatusStore.Backend.live` はプレビュー時だけそれに差し替え、完了後の再起動はプレビュー時に何もしない閉じるだけの処理を AppDelegate から渡す。

**Tech Stack:** Swift 5.9 / AppKit + SwiftUI / XCTest(`swift test`)

**Spec:** `docs/superpowers/specs/2026-11-14-update-preview-design.md`

## Global Constraints

- 環境変数名は `HAKO_UPDATE_PREVIEW`。値 `fail` → 失敗、`lag` → 反映待ち、それ以外(`1` や認識できない値)→ 成功。未設定ならプレビューしない
- 仮想の版: Hako 0.6 → 0.7、Colima 今の版 → 0.99.0
- 偽の更新は約 2 秒かかる
- プレビュー中は本物の brew・xattr・colima の操作・Hako の再起動を一切実行しない
- 環境変数なしのときの動作は変えない

## Review Focus

- 環境変数なし → 既存どおり本物の Backend が使われる(Task 1 の `testOutcomeIsNilWithoutVariable` と Task 2 の手動確認)
- プレビュー中の「Colima を再起動」→ 本物の Colima を再起動しない(Task 2 の手動確認)
- プレビュー中の Hako「再起動」→ アプリが終了しない(Task 2 の手動確認)
- プレビュー中にメニューバーの「新しいバージョン」項目が出る(Task 2 の手動確認)
- `HAKO_UPDATE_PREVIEW=` のように空の値 → 成功として扱う(Task 1 のテスト)

---

### Task 1: UpdatePreview(環境変数・見本リリース・偽の brew)

**Files:**
- Create: `Sources/Hako/UpdatePreview.swift`
- Test: `Tests/HakoTests/UpdatePreviewTests.swift`

**Interfaces:**
- Consumes: `UpdateChecker.Release`、`HomebrewUpdater(brew:run:)`、`UpdateModel.Backend`
- Produces:
  - `enum UpdatePreview` 内に `enum Outcome: Equatable { case success, failure, lag }`
  - `static func outcome(from environment: [String: String]) -> Outcome?`
  - `static let current: Outcome?`(`ProcessInfo.processInfo.environment` から)
  - `static let hakoRelease: UpdateChecker.Release`(version "0.7")、`static let colimaRelease`(version "0.99.0")
  - `static func updater(_ outcome: Outcome, delay: UInt64 = 2_000_000_000) -> HomebrewUpdater` — brew パスは `/opt/homebrew/bin/brew`(表示用)。`list` は今の版(upgrade 成功後は新しい版)、`update` と xattr は成功、`upgrade` は delay ナノ秒待ってから outcome に応じて成功 / status 1 で stderr "Error: プレビュー用の失敗です" / 成功するが版は上がらない
  - `static func backend(_ outcome: Outcome, colimaVersion: @escaping () async -> String?, delay: UInt64 = 2_000_000_000) -> UpdateModel.Backend` — hakoVersion "0.6"、hakoAppPath "/Applications/Hako.app"、latestRelease は repo ごとに上の見本、colima の今の版が取れなければ "0.10.3"

- [ ] **Step 1: 失敗するテストを書く**

```swift
func testOutcomeIsNilWithoutVariable()        // outcome(from: [:]) == nil
func testOutcomeValues()                      // "1"/""/"foo" → .success、"fail" → .failure、"lag" → .lag
func testPreviewShowsBothUpdates() async      // UpdateModel(backend: backend(.success, colimaVersion: { "0.10.3" }, delay: 0)) を refresh → hako/colima とも .available、hako.latest == "0.7"、colima.latest == "0.99.0"
func testPreviewSuccessInstalls() async       // update(.hako) → .installed
func testPreviewFailureShowsError() async     // .failure で update(.colima) → .available、error に "プレビュー用の失敗です"
func testPreviewLagShowsNotYetAvailable() async // .lag で update(.hako) → error == UpdateError.versionNotYetAvailable("0.7").message
```

- [ ] **Step 2: `swift test --filter UpdatePreviewTests` で FAIL(`UpdatePreview` が無い)を確認**
- [ ] **Step 3: Interfaces どおり実装する**
- [ ] **Step 4: `swift test` で全件 PASS を確認**
- [ ] **Step 5: コミット**(`git commit -m "アップデートのプレビュー用の見本と偽の brew を追加"`)

### Task 2: プレビューへの切り替えと再起動の無効化

**Files:**
- Modify: `Sources/Hako/UpdateModel.swift`(`Backend.live()` の先頭で `UpdatePreview.current` があればプレビューの Backend を返す)
- Modify: `Sources/Hako/StatusStore.swift`(`Backend` に `var hakoVersion: String?` を追加し、`checkForUpdates` は `UpdateChecker.currentVersion` の代わりにこれを使う。`live` はプレビュー時 hakoVersion "0.6"、`latestRelease` は見本の版が current より新しければ返す)
- Modify: `Sources/Hako/UpdateWindow.swift`(`UpdateWindowController.init` に `relaunchHako: @escaping () -> Void` を追加し、内部で直接 `AppRelauncher` を呼ばない)
- Modify: `Sources/Hako/AppDelegate.swift`(プレビュー時は relaunchHako・restartColima とも何もせず、colimaRunning は常に true。通常時は今までどおり)
- Modify: `Tests/HakoTests/StatusStoreTests.swift`、`Tests/HakoTests/UpdateWindowTests.swift`(新しい引数に合わせる)

- [ ] **Step 1: 失敗するテストを書く**

```swift
// StatusStoreTests
func testCheckForUpdatesUsesBackendHakoVersion() async // hakoVersion "0.6"、latestRelease が "0.7" → availableUpdate == "0.7"
```

- [ ] **Step 2: `swift test --filter StatusStoreTests` で FAIL(`hakoVersion` が無い)を確認**
- [ ] **Step 3: 上の Files どおり実装する**
- [ ] **Step 4: `swift test` で全件 PASS、`swift build` で警告なしを確認**
- [ ] **Step 5: 実アプリで確認する**
  - `HAKO_UPDATE_PREVIEW=1 .build/debug/Hako`:メニューバーに「Hako の新しいバージョン 0.7 があります」「Colima の新しいバージョン 0.99.0 があります」。押すとウィンドウが開き、両欄が「更新あり」。Hako の「アップデート」→ 約 2 秒「アップデート中…」→「完了」と「あとで / 再起動」。「再起動」でアプリが終了せずウィンドウだけ閉じる
  - `HAKO_UPDATE_PREVIEW=fail`:「アップデートに失敗しました」が赤字で出る
  - 環境変数なし:今までどおり(Hako 欄が「.app として動いていない」)
- [ ] **Step 6: コミット**(`git commit -m "HAKO_UPDATE_PREVIEW でアップデートをプレビューできるようにする"`)
