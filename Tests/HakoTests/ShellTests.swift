import XCTest
@testable import Hako

final class ShellTests: XCTestCase {
    /// stdout を閉じる前に stderr へパイプのバッファ(約 64KB)を超えて書いても詰まらないこと
    func testLargeStderrBeforeStdoutDoesNotDeadlock() {
        let finished = expectation(description: "コマンドが終了する")
        var result: Shell.Result?
        DispatchQueue.global().async {
            result = Shell.run("head -c 300000 /dev/zero | tr '\\0' x >&2; echo done")
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(result?.status, 0)
        XCTAssertEqual(result?.stdout, "done\n")
        XCTAssertEqual(result?.stderr.count, 300_000)
    }
}
