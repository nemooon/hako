import XCTest
@testable import Hako

final class ColimaProfileTests: XCTestCase {
    /// `colima ls --json` の各行から名前と実行状態を読む(Running 以外は停止中扱い)
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

    /// Colima 以外の context(Docker Desktop など)はどのプロファイルにも対応しない
    func testProfileForContext() {
        XCTAssertEqual(ColimaService.profile(forContext: "colima"), "default")
        XCTAssertEqual(ColimaService.profile(forContext: "colima-work"), "work")
        XCTAssertNil(ColimaService.profile(forContext: "desktop-linux"))
        XCTAssertNil(ColimaService.profile(forContext: ""))
    }
}
