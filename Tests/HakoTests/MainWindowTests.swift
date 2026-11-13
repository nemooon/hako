import AppKit
import XCTest
@testable import Hako

final class MainWindowTests: XCTestCase {
    @MainActor
    func testWindowStartsAtDefaultSizeWithoutSavedFrame() {
        withSavedWindowFrame(nil) {
            let controller = MainWindowController(model: MainWindowModel(), perform: { _ in }, onClose: {})
            XCTAssertEqual(controller.window!.frame.size, NSSize(width: 1100, height: 700))
        }
    }

    @MainActor
    func testWindowRepairsUndersizedSavedFrame() {
        withSavedWindowFrame("200 500 570 84 0 0 1920 1250 ") {
            let controller = MainWindowController(model: MainWindowModel(), perform: { _ in }, onClose: {})
            let window = controller.window!
            XCTAssertGreaterThanOrEqual(window.frame.width, window.minSize.width)
            XCTAssertGreaterThanOrEqual(window.frame.height, window.minSize.height)
        }
    }

    @MainActor
    func testWindowPreservesValidSavedSize() {
        withSavedWindowFrame("200 300 1000 650 0 0 1920 1250 ") {
            let controller = MainWindowController(model: MainWindowModel(), perform: { _ in }, onClose: {})
            XCTAssertEqual(controller.window!.frame.size, NSSize(width: 1000, height: 650))
        }
    }

    @MainActor
    private func withSavedWindowFrame(_ value: String?, body: () -> Void) {
        _ = NSApplication.shared
        let key = "NSWindow Frame HakoMainWindow"
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.set(value, forKey: key)
        body()
    }

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
        let snapshot = ColimaSnapshot(profile: "default", running: true, vmInfo: nil, containers: [initJob, web, standalone],
                                      composeProjects: [ComposeProject(name: "shop", status: "running(1)", configFiles: [])])
        XCTAssertEqual(ContainerScope.all.containers(in: snapshot, matching: "").map(\.id), ["db", "web", "init"])
        XCTAssertEqual(ContainerScope.standalone.containers(in: snapshot, matching: "").map(\.id), ["db"])
        XCTAssertEqual(ContainerScope.project("shop").containers(in: snapshot, matching: "").map(\.id), ["web", "init"])
        XCTAssertTrue(ContainerScope.project("missing").containers(in: snapshot, matching: "").isEmpty)
    }

    func testSearchMatchesServiceProjectAndImageWithoutEscapingScope() {
        let snapshot = ColimaSnapshot(profile: "default", running: true, vmInfo: nil,
                                      containers: [container("a", name: "shop-web", project: "shop", service: "API"),
                                                   container("b", name: "database")], composeProjects: [])
        XCTAssertEqual(ContainerScope.all.containers(in: snapshot, matching: "api").map(\.id), ["a"])
        XCTAssertEqual(ContainerScope.all.containers(in: snapshot, matching: "SHOP").map(\.id), ["a"])
        XCTAssertEqual(ContainerScope.standalone.containers(in: snapshot, matching: "postgres").map(\.id), ["b"])
        XCTAssertTrue(ContainerScope.standalone.containers(in: snapshot, matching: "shop").isEmpty)
        XCTAssertTrue(ContainerScope.all.containers(in: nil, matching: "").isEmpty)
    }
}
