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

    /// docker 以外のランタイム(containerd など)のプロファイルは docker context が無く切り替えられないので出さない
    func testParseProfilesSkipsNonDockerRuntime() {
        let json = """
        {"name":"default","status":"Running","runtime":"docker"}
        {"name":"k8s","status":"Running","runtime":"containerd"}
        {"name":"old","status":"Stopped"}
        """
        XCTAssertEqual(ColimaService.parseProfiles(json).map(\.name), ["default", "old"])
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

    /// デモモードでは、案件名などが入りうるプロファイル名も置き換える(default はそのまま)
    func testAnonymizeReplacesProfileNames() {
        let snapshot = ColimaSnapshot(profile: "acme-corp", running: true, vmInfo: "プロファイル acme-corp ・ CPU 2",
                                      containers: [], composeProjects: [],
                                      profiles: [ColimaProfile(name: "default", running: true),
                                                 ColimaProfile(name: "acme-corp", running: true),
                                                 ColimaProfile(name: "beta-inc", running: false)])
        let demo = ColimaService.anonymize(snapshot)
        XCTAssertEqual(demo.profiles.map(\.name), ["default", "profile-1", "profile-2"])
        XCTAssertEqual(demo.profiles.map(\.running), [true, true, false])
        XCTAssertEqual(demo.profile, "profile-1")
        XCTAssertEqual(demo.vmInfo, "プロファイル profile-1 ・ CPU 2")
    }

    /// 短いプロファイル名でも、CPU やメモリの数字まで書き換えない
    func testAnonymizeKeepsVMNumbersForShortProfileName() {
        let snapshot = ColimaSnapshot(profile: "2", running: true, vmInfo: "プロファイル 2 ・ CPU 2 ・ メモリ 2GB",
                                      containers: [], composeProjects: [],
                                      profiles: [ColimaProfile(name: "default", running: true),
                                                 ColimaProfile(name: "2", running: true)])
        XCTAssertEqual(ColimaService.anonymize(snapshot).vmInfo, "プロファイル profile-1 ・ CPU 2 ・ メモリ 2GB")
    }
}
