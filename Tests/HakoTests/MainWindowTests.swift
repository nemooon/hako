import AppKit
import XCTest
@testable import Hako

final class MainWindowTests: XCTestCase {
    @MainActor
    func testWindowStartsAtDefaultSizeWithoutSavedFrame() {
        withSavedWindowFrame(nil) {
            let controller = MainWindowController(model: StatusStore(), perform: { _ in }, onClose: {})
            XCTAssertEqual(controller.window!.frame.size, NSSize(width: 1100, height: 700))
        }
    }

    @MainActor
    func testWindowRepairsUndersizedSavedFrame() {
        withSavedWindowFrame("200 500 570 84 0 0 1920 1250 ") {
            let controller = MainWindowController(model: StatusStore(), perform: { _ in }, onClose: {})
            let window = controller.window!
            XCTAssertGreaterThanOrEqual(window.frame.width, window.minSize.width)
            XCTAssertGreaterThanOrEqual(window.frame.height, window.minSize.height)
        }
    }

    @MainActor
    func testWindowPreservesValidSavedSize() {
        withSavedWindowFrame("200 300 1000 650 0 0 1920 1250 ") {
            let controller = MainWindowController(model: StatusStore(), perform: { _ in }, onClose: {})
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

    // MARK: - プロファイル選択

    @MainActor
    private func profileSnapshot(_ profiles: [ColimaProfile], running: Bool = true) -> ColimaSnapshot {
        ColimaSnapshot(profile: "default", running: running, vmInfo: nil, containers: [], composeProjects: [],
                       profiles: profiles)
    }

    @MainActor
    func testToolbarProfileMenuReflectsProfiles() {
        _ = NSApplication.shared
        var actions: [MainWindowAction] = []
        let controller = MainWindowToolbarController(perform: { actions.append($0) },
                                                     toggleSidebar: {}, toggleInspector: {}, searchChanged: { _ in })
        let window = NSWindow()
        window.toolbar = controller.toolbar // ツールバーは window に付けたときに既定の項目が並ぶ
        controller.update(snapshot: profileSnapshot([ColimaProfile(name: "default", running: true),
                                                     ColimaProfile(name: "work", running: false)]),
                          scope: .all, busy: false, search: "")
        XCTAssertEqual(controller.profileItem.title, "default")
        // NSMenuToolbarItem はプルダウン式で、メニューの先頭項目を表示しない。先頭は空の見出しにしておく
        let items = controller.profileItem.menu.items
        XCTAssertEqual(items.first?.title, "")
        XCTAssertEqual(items.dropFirst().map(\.title), ["default", "work"])
        XCTAssertEqual(items.dropFirst().map(\.state), [.on, .off])
        XCTAssertTrue(controller.profileItem.isEnabled)
        XCTAssertTrue(controller.toolbar.items.contains { $0.itemIdentifier == controller.profileItem.itemIdentifier })

        let work = controller.profileItem.menu.items[2]
        _ = (work.target as? NSObject)?.perform(work.action, with: work)
        guard case .switchProfile("work") = actions.last else {
            return XCTFail("work への切り替えが送られていない: \(actions)")
        }
    }

    /// default だけのときはツールバーにプロファイル選択を出さない
    @MainActor
    func testToolbarHidesProfileMenuForSingleProfile() {
        _ = NSApplication.shared
        let controller = MainWindowToolbarController(perform: { _ in },
                                                     toggleSidebar: {}, toggleInspector: {}, searchChanged: { _ in })
        let window = NSWindow()
        window.toolbar = controller.toolbar // ツールバーは window に付けたときに既定の項目が並ぶ
        controller.update(snapshot: profileSnapshot([ColimaProfile(name: "default", running: true),
                                                     ColimaProfile(name: "work", running: true)]),
                          scope: .all, busy: false, search: "")
        controller.update(snapshot: profileSnapshot([ColimaProfile(name: "default", running: true)]),
                          scope: .all, busy: false, search: "")
        XCTAssertFalse(controller.toolbar.items.contains { $0.itemIdentifier == controller.profileItem.itemIdentifier })
    }

    @MainActor
    func testToolbarProfileMenuDisabledWhileBusy() {
        _ = NSApplication.shared
        let controller = MainWindowToolbarController(perform: { _ in },
                                                     toggleSidebar: {}, toggleInspector: {}, searchChanged: { _ in })
        let window = NSWindow()
        window.toolbar = controller.toolbar // ツールバーは window に付けたときに既定の項目が並ぶ
        controller.update(snapshot: profileSnapshot([ColimaProfile(name: "default", running: true),
                                                     ColimaProfile(name: "work", running: true)]),
                          scope: .all, busy: true, search: "")
        XCTAssertFalse(controller.profileItem.isEnabled)
    }
}
