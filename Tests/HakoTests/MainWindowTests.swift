import XCTest
@testable import Hako

final class MainWindowTests: XCTestCase {
    func testStatsProvideNumericSortValuesAcrossUnits() {
        let small = ContainerStats(cpu: "2.50%", mem: "900MiB")
        let large = ContainerStats(cpu: "12.00%", mem: "1.5GiB")
        XCTAssertEqual(small.cpuPercent, 2.5)
        XCTAssertEqual(large.cpuPercent, 12)
        XCTAssertEqual(small.memoryBytes, 943718400)
        XCTAssertEqual(large.memoryBytes, 1610612736)
        XCTAssertTrue(small.memoryBytes! < large.memoryBytes!)
        XCTAssertEqual(ContainerStats(cpu: "0.00%", mem: "1.25 GB").memoryBytes, 1250000000)
        XCTAssertNil(ContainerStats(cpu: "—", mem: "—").cpuPercent)
        XCTAssertNil(ContainerStats(cpu: "—", mem: "—").memoryBytes)
    }

    private func container(_ id: String, name: String, running: Bool = true,
                           project: String? = nil, service: String? = nil) -> Container {
        Container(id: id, name: name, image: "postgres:16", state: running ? "running" : "exited",
                  status: running ? "Up" : "Exited", ports: [], composeProject: project, composeService: service)
    }

    func testWindowIncludesStoppedInitContainersAndFiltersByScope() {
        let web = container("web", name: "shop-web", project: "shop", service: "web")
        let initJob = container("init", name: "shop-init", running: false, project: "shop", service: "init")
        let standalone = container("db", name: "database")
        let snapshot = ColimaSnapshot(running: true, vmInfo: nil, containers: [initJob, web, standalone],
                                      composeProjects: [ComposeProject(name: "shop", status: "running(1)", configFiles: [])])
        XCTAssertEqual(ContainerScope.all.containers(in: snapshot, matching: "").map(\.id), ["db", "web", "init"])
        XCTAssertEqual(ContainerScope.standalone.containers(in: snapshot, matching: "").map(\.id), ["db"])
        XCTAssertEqual(ContainerScope.project("shop").containers(in: snapshot, matching: "").map(\.id), ["web", "init"])
        XCTAssertTrue(ContainerScope.project("missing").containers(in: snapshot, matching: "").isEmpty)
    }

    func testSearchMatchesServiceProjectAndImageWithoutEscapingScope() {
        let snapshot = ColimaSnapshot(running: true, vmInfo: nil,
                                      containers: [container("a", name: "shop-web", project: "shop", service: "API"),
                                                   container("b", name: "database")], composeProjects: [])
        XCTAssertEqual(ContainerScope.all.containers(in: snapshot, matching: "api").map(\.id), ["a"])
        XCTAssertEqual(ContainerScope.all.containers(in: snapshot, matching: "SHOP").map(\.id), ["a"])
        XCTAssertEqual(ContainerScope.standalone.containers(in: snapshot, matching: "postgres").map(\.id), ["b"])
        XCTAssertTrue(ContainerScope.standalone.containers(in: snapshot, matching: "shop").isEmpty)
        XCTAssertTrue(ContainerScope.all.containers(in: nil, matching: "").isEmpty)
    }
}
