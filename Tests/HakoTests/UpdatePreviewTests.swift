import XCTest
@testable import Hako

@MainActor
final class UpdatePreviewTests: XCTestCase {
    private func model(_ outcome: UpdatePreview.Outcome) -> UpdateModel {
        UpdateModel(backend: UpdatePreview.backend(outcome, colimaVersion: { "0.10.3" }, delay: 0), store: StatusStore())
    }

    func testOutcomeIsNilWithoutVariable() {
        XCTAssertNil(UpdatePreview.outcome(from: [:]))
        XCTAssertNil(UpdatePreview.outcome(from: ["HAKO_DEMO": "1"]))
    }

    func testOutcomeValues() {
        XCTAssertEqual(UpdatePreview.outcome(from: ["HAKO_UPDATE_PREVIEW": "1"]), .success)
        XCTAssertEqual(UpdatePreview.outcome(from: ["HAKO_UPDATE_PREVIEW": ""]), .success)
        XCTAssertEqual(UpdatePreview.outcome(from: ["HAKO_UPDATE_PREVIEW": "foo"]), .success)
        XCTAssertEqual(UpdatePreview.outcome(from: ["HAKO_UPDATE_PREVIEW": "fail"]), .failure)
        XCTAssertEqual(UpdatePreview.outcome(from: ["HAKO_UPDATE_PREVIEW": "lag"]), .lag)
    }

    func testPreviewShowsBothUpdates() async {
        let model = model(.success)
        await model.refresh()
        XCTAssertEqual(model.hako.phase, .available)
        XCTAssertEqual(model.colima.phase, .available)
        XCTAssertEqual(model.hako.current, "0.6")
        XCTAssertEqual(model.hako.latest, "0.7")
        XCTAssertEqual(model.colima.latest, "0.99.0")
        XCTAssertFalse(model.hako.notes.isEmpty)
    }

    func testPreviewSuccessInstalls() async {
        let model = model(.success)
        await model.refresh()
        await model.update(.hako)
        XCTAssertEqual(model.hako.phase, .installed)
    }

    func testPreviewFailureShowsError() async {
        let model = model(.failure)
        await model.refresh()
        await model.update(.colima)
        XCTAssertEqual(model.colima.phase, .available)
        XCTAssertTrue(model.colima.error?.contains("プレビュー用の失敗です") == true)
    }

    func testPreviewLagShowsNotYetAvailable() async {
        let model = model(.lag)
        await model.refresh()
        await model.update(.hako)
        XCTAssertEqual(model.hako.error, UpdateError.versionNotYetAvailable("0.7").message)
    }
}
