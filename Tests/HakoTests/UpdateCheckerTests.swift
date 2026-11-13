import XCTest
@testable import Hako

final class UpdateCheckerTests: XCTestCase {
    func testParseReleaseStripsVPrefixAndKeepsBody() {
        let data = Data(#"{"tag_name":"v0.11.0","body":"- 修正"}"#.utf8)
        XCTAssertEqual(UpdateChecker.parseRelease(data), .init(version: "0.11.0", notes: "- 修正"))
    }

    func testParseReleaseWithoutBodyOrTag() {
        XCTAssertEqual(UpdateChecker.parseRelease(Data(#"{"tag_name":"0.6"}"#.utf8)), .init(version: "0.6", notes: ""))
        XCTAssertNil(UpdateChecker.parseRelease(Data(#"{"message":"rate limited"}"#.utf8)))
    }

    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("0.7", than: "0.6"))
        XCTAssertTrue(UpdateChecker.isNewer("0.6.1", than: "0.6"))
        XCTAssertFalse(UpdateChecker.isNewer("0.6", than: "0.6.0"))
    }
}
