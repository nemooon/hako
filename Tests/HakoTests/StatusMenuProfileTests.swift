import XCTest
@testable import Hako

@MainActor
final class StatusMenuProfileTests: XCTestCase {
    private func snapshot(_ profiles: [ColimaProfile], isColimaContext: Bool = true) -> ColimaSnapshot {
        ColimaSnapshot(profile: "default", running: true, vmInfo: nil, containers: [], composeProjects: [],
                       profiles: profiles, isColimaContext: isColimaContext)
    }

    /// default しかない(または一覧が取れない)ときは、今と同じ見た目にする
    func testProfileEntriesHiddenForSingleProfile() {
        XCTAssertTrue(StatusMenuController.profileEntries(for: snapshot([ColimaProfile(name: "default", running: true)])).isEmpty)
        XCTAssertTrue(StatusMenuController.profileEntries(for: snapshot([])).isEmpty)
    }

    func testProfileEntriesListProfilesWithCheckAndStatus() {
        let entries = StatusMenuController.profileEntries(for: snapshot([
            ColimaProfile(name: "default", running: true),
            ColimaProfile(name: "work", running: false),
        ]))
        XCTAssertEqual(entries.count, 4)
        XCTAssertTrue(entries[0].isSeparator)
        XCTAssertEqual(entries[1].title, "プロファイル")
        XCTAssertEqual(entries[2...].map(\.title), ["default", "work"])
        XCTAssertEqual(entries[2...].map(\.subtitle), ["実行中", "停止中"])
        XCTAssertEqual(entries[2...].map(\.isChecked), [true, false])
        XCTAssertEqual(entries[3].representedObject as? String, "work")
        XCTAssertNotNil(entries[3].action)
    }

    /// Docker Desktop などを向いているときは、どのプロファイルも選ばれていない
    func testProfileEntriesUncheckedForNonColimaContext() {
        let entries = StatusMenuController.profileEntries(for: snapshot([
            ColimaProfile(name: "default", running: true),
            ColimaProfile(name: "work", running: false),
        ], isColimaContext: false))
        XCTAssertEqual(entries[2...].map(\.isChecked), [false, false])
    }
}
