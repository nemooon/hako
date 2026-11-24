import XCTest
@testable import Hako

final class LogStreamTests: XCTestCase {
    /// 行の途中で区切られた出力もまとめ直し、stderr も同じ流れで受け取り、終了コードを返す
    func testDeliversLinesFromStdoutAndStderrThenExits() {
        let stream = LogStream(arguments: [
            "/bin/sh", "-c", "printf 'one\\ntw'; sleep 0.1; printf 'o\\r\\n'; echo err >&2; printf 'last'; exit 3",
        ])
        let received = Received()
        let exited = expectation(description: "終了する")
        XCTAssertTrue(stream.start(
            onLines: { batch in received.add(batch) },
            onExit: { code in received.finish(code); exited.fulfill() }
        ))
        wait(for: [exited], timeout: 5)
        XCTAssertEqual(received.lines, ["one", "two", "err", "last"])
        XCTAssertEqual(received.status, 3)
    }

    /// stop() で終わらないコマンドも止まる
    func testStopTerminatesEndlessCommand() {
        let stream = LogStream(arguments: ["/bin/sh", "-c", "while true; do echo tick; sleep 0.05; done"])
        let exited = expectation(description: "終了する")
        XCTAssertTrue(stream.start(onLines: { _ in }, onExit: { _ in exited.fulfill() }))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { stream.stop() }
        wait(for: [exited], timeout: 5)
    }

    /// 止めた直後に参照を手放しても、出力の終わりまで処理して onExit が呼ばれる
    /// (以前は解放後に EOF のハンドラを外せず、空読みが続いていた)
    func testReleasingAfterStopStillFinishes() {
        let exited = expectation(description: "終了する")
        var stream: LogStream? = LogStream(arguments: ["/bin/sh", "-c", "while true; do echo tick; sleep 0.05; done"])
        XCTAssertTrue(stream!.start(onLines: { _ in }, onExit: { _ in exited.fulfill() }))
        stream?.stop()
        stream = nil
        wait(for: [exited], timeout: 5)
    }

    /// 起動できないコマンドは false を返す
    func testStartFailsForMissingExecutable() {
        let stream = LogStream(executable: "/nonexistent/command", arguments: [])
        XCTAssertFalse(stream.start(onLines: { _ in }, onExit: { _ in }))
    }
}

/// バックグラウンドから届く行と終了コードを溜める
private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    private var _status: Int32?
    var lines: [String] { lock.withLock { _lines } }
    var status: Int32? { lock.withLock { _status } }
    func add(_ batch: [String]) { lock.withLock { _lines += batch } }
    func finish(_ code: Int32) { lock.withLock { _status = code } }
}

@MainActor
final class LogViewModelTests: XCTestCase {
    private func model(_ script: String, maxLines: Int = 100) -> LogViewModel {
        LogViewModel(containerName: "web", maxLines: maxLines) {
            LogStream(arguments: ["/bin/sh", "-c", script])
        }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testCollectsLinesWithoutEscapeSequencesAndEnds() async {
        let model = model(#"printf '\033[32mready\033[0m\nplain\n'"#)
        model.start()
        await waitUntil { model.state == .ended }
        XCTAssertEqual(model.lines, ["ready", "plain"])
        XCTAssertEqual(model.state, .ended)
    }

    func testNonZeroExitIsFailure() async {
        let model = model("echo 'No such container' >&2; exit 1")
        model.start()
        await waitUntil { model.state != .streaming }
        XCTAssertEqual(model.state, .failed(1))
        XCTAssertEqual(model.lines, ["No such container"])
    }

    /// 上限を超えたら古い行から捨て、追記以外の変化として generation を進める
    func testTrimsOldLinesBeyondLimit() async {
        let model = model("seq 1 30", maxLines: 10)
        model.start()
        await waitUntil { model.state == .ended }
        XCTAssertLessThanOrEqual(model.lines.count, 12)
        XCTAssertEqual(model.lines.last, "30")
        XCTAssertGreaterThan(model.generation, 1)
    }

    /// 追従を止めて過去の行を読んでいる間は、表示位置が飛ばないよう上限の 5 倍まで捨てない
    func testKeepsLinesWhileNotFollowing() async {
        let model = model("sleep 0.2; seq 1 30", maxLines: 10)
        model.start()
        model.follows = false
        await waitUntil { model.state == .ended }
        XCTAssertEqual(model.lines.count, 30)
    }

    func testQueryMatchesCaseInsensitively() {
        let model = model("true")
        XCTAssertTrue(model.matches("ERROR: boom"))
        model.query = "error"
        XCTAssertTrue(model.matches("ERROR: boom"))
        XCTAssertFalse(model.matches("info: ok"))
    }

    /// 再接続すると前の行は消して読み直す(--tail で同じ行が重複するため)
    func testRestartClearsPreviousLines() async {
        let model = model("echo once")
        model.start()
        await waitUntil { model.state == .ended }
        let generation = model.generation
        model.start()
        await waitUntil { model.state == .ended }
        XCTAssertEqual(model.lines, ["once"])
        XCTAssertGreaterThan(model.generation, generation)
    }

    func testClearRemovesLines() async {
        let model = model("echo a; echo b")
        model.start()
        await waitUntil { model.state == .ended }
        model.clear()
        XCTAssertEqual(model.lines, [])
    }
}
