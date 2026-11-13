import AppKit
import XCTest
@testable import Hako

@MainActor
final class UpdateWindowTests: XCTestCase {
    /// 更新中はアプリの終了も止める(brew が途中で止まって中途半端な状態になるため)
    func testTerminationIsBlockedWhileUpdating() async {
        _ = NSApplication.shared
        let fake = FakeCommandRunner()
        var release: CheckedContinuation<Void, Never>?
        let gated: HomebrewUpdater.Runner = { path, arguments in
            if arguments.first == "upgrade" { await withCheckedContinuation { release = $0 } }
            if arguments.first == "list" { return FakeCommandRunner.ok("hako \(release == nil ? "0.6" : "0.7")\n") }
            return await fake.runner(path, arguments)
        }
        let backend = UpdateModel.Backend(
            latestRelease: { _ in .init(version: "0.7", notes: "") }, hakoVersion: "0.6",
            hakoAppPath: "/Applications/Hako.app", colimaVersion: { "0.11.0" },
            updater: HomebrewUpdater(brew: "/opt/homebrew/bin/brew", run: gated))
        let model = UpdateModel(backend: backend, store: StatusStore())
        let controller = UpdateWindowController(model: model, restartColima: {}, colimaRunning: { false })
        await model.refresh()
        XCTAssertTrue(controller.allowsTermination)

        let updating = Task { await model.update(.hako) }
        for _ in 0..<200 where release == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(controller.allowsTermination)
        XCTAssertFalse(controller.windowShouldClose(controller.window!))

        release?.resume()
        await updating.value
        XCTAssertTrue(controller.allowsTermination)
    }

    /// 中身が少ないときは、ウィンドウの高さも中身に合わせて小さくする(下半分が空白にならない)
    func testWindowHeightFitsContent() async {
        _ = NSApplication.shared
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame HakoUpdateWindow")
        let backend = UpdateModel.Backend(
            latestRelease: { _ in .init(version: "0.6", notes: "") }, hakoVersion: "0.6",
            hakoAppPath: "/Applications/Hako.app", colimaVersion: { "0.6" }, updater: nil)
        let model = UpdateModel(backend: backend, store: StatusStore())
        let controller = UpdateWindowController(model: model, restartColima: {}, colimaRunning: { false })
        await model.refresh()
        let window = controller.window!
        window.contentView?.layoutSubtreeIfNeeded()
        for _ in 0..<50 { try? await Task.sleep(nanoseconds: 10_000_000); window.contentView?.layoutSubtreeIfNeeded() }
        XCTAssertEqual(model.hako.phase, .upToDate)
        XCTAssertLessThan(window.contentLayoutRect.height, 320)
    }
}
