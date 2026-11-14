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

final class ComposeGroupStateTests: XCTestCase {
    private func container(_ id: String, running: Bool, ports: Bool) -> Container {
        Container(id: id, name: id, image: "img", state: running ? "running" : "exited",
                  status: running ? "Up" : "Exited (0)",
                  ports: ports ? [PortMapping(host: "8080", container: "80")] : [],
                  composeProject: "shop", composeService: id)
    }

    /// ポートを公開しない init 系(バケット作成など)が止まっていても、問題扱いしない
    func testStoppedInitContainerIsNotPartial() {
        let group = [container("web", running: true, ports: true), container("s3-init", running: false, ports: false)]
        XCTAssertEqual(Container.groupState(group), .running)
    }

    func testStoppedPublishedServiceIsPartial() {
        let group = [container("db", running: true, ports: false), container("web", running: false, ports: true)]
        XCTAssertEqual(Container.groupState(group), .partial)
    }

    func testNothingRunningIsStopped() {
        XCTAssertEqual(Container.groupState([container("web", running: false, ports: true)]), .stopped)
        XCTAssertEqual(Container.groupState([]), .stopped)
    }
}
