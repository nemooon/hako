import XCTest
@testable import Hako

final class ContainerTests: XCTestCase {
    private func container(status: String) -> Container {
        Container(id: "abc", name: "web", image: "nginx", state: "running", status: status,
                  ports: [], composeProject: nil, composeService: nil)
    }

    /// 経過時間だけが変わった status は同じコンテナとみなす(無駄な再描画を防ぐ)
    func testElapsedTimeOnlyChangeIsEqual() {
        XCTAssertEqual(container(status: "Up 4 minutes (healthy)"), container(status: "Up 5 minutes (healthy)"))
    }

    /// unhealthy への変化・回復は差分として検出する(通知と表示の更新に必要)
    func testUnhealthyTransitionIsNotEqual() {
        XCTAssertNotEqual(container(status: "Up 4 minutes (healthy)"), container(status: "Up 5 minutes (unhealthy)"))
        XCTAssertNotEqual(container(status: "Up 5 minutes (unhealthy)"), container(status: "Up 6 minutes (healthy)"))
    }
}
