import XCTest
@testable import Hako

final class CleanupServiceTests: XCTestCase {
    private func ok(_ text: String) -> Shell.Result { .init(status: 0, stdout: text, stderr: "") }

    func testScanProtectsStoppedContainerImagesAndSelectsReclaimableCaches() throws {
        let scan = try CleanupService.scan(run: { args in
            switch args {
            case ["context", "show"]: return self.ok("colima")
            case let a where a.contains("ps"): return self.ok("stopped-container")
            case let a where a.contains("inspect") && a.contains("stopped-container"):
                return self.ok(#"[{"Image":"sha256:used"}]"#)
            case let a where a.contains("ls"): return self.ok("sha256:used\nsha256:local\nsha256:dangling")
            case let a where a.contains("image") && a.contains("inspect"):
                return self.ok(#"[{"Id":"sha256:used","Size":500,"RepoTags":["db:latest"]},{"Id":"sha256:local","Size":300,"RepoTags":["myapp:dev"]},{"Id":"sha256:dangling","Size":100,"RepoTags":[]}]"#)
            case let a where a.contains("du"):
                return self.ok("""
                {"ID":"old","Size":"5000","Reclaimable":true,"LastUsedAt":"2020-01-01T00:00:00Z"}
                {"ID":"unknown","Size":"20","Reclaimable":true}
                {"ID":"recent","Size":"30","Reclaimable":true,"LastUsedAt":"2099-01-01T00:00:00Z"}
                {"ID":"inuse","Size":"10","Reclaimable":false}
                """)
            default: XCTFail("Unexpected command: \(args)"); return self.ok("")
            }
        })
        XCTAssertEqual(Set(scan.resources.map(\.id)), ["sha256:local", "sha256:dangling", "old", "unknown", "recent"])
        XCTAssertEqual(Set(scan.resources.filter(\.initiallySelected).map(\.id)), ["sha256:dangling", "old", "unknown", "recent"])
        XCTAssertEqual(scan.builder, "colima")
        XCTAssertEqual(scan.resources.map(\.bytes), [5000, 300, 100, 30, 20])
        XCTAssertEqual(scan.resources.first?.id, "old")
    }

    func testHumanReadableCacheSizes() {
        XCTAssertEqual(CleanupService.parseCacheSize("4.128kB"), 4128)
        XCTAssertEqual(CleanupService.parseCacheSize("8.192kB*"), 8192)
        XCTAssertEqual(CleanupService.parseCacheSize("1.25 GB"), 1250000000)
        XCTAssertEqual(CleanupService.parseCacheSize("1.5MiB"), 1572864)
        XCTAssertEqual(CleanupService.parseCacheSize("829889526"), 829889526)
        XCTAssertEqual(CleanupService.parseCacheSize(1024), 1024)
        XCTAssertEqual(CleanupService.parseCacheSize("0B"), 0)
        XCTAssertNil(CleanupService.parseCacheSize("-1"))
        XCTAssertNil(CleanupService.parseCacheSize("huge"))
        XCTAssertNil(CleanupService.parseCacheSize("999999PB"))
    }

    func testFormattedBuildxRecordsAndRelativeAges() throws {
        let scan = try CleanupService.scan(run: { args in
            if args == ["context", "show"] { return self.ok("colima") }
            if args.contains("du") {
                return self.ok("""
                {"ID":"recent","Size":"4.128kB","LastUsedAt":"16 hours ago","Reclaimable":true}
                {"ID":"old","Size":"1.25GB","LastUsedAt":"2 weeks ago","Reclaimable":true,"Shared":true}
                """)
            }
            return self.ok("")
        })
        XCTAssertNil(scan.warning)
        XCTAssertEqual(scan.resources.count, 2)
        XCTAssertEqual(scan.resources.first { $0.id == "recent" }?.bytes, 4128)
        XCTAssertEqual(scan.resources.first { $0.id == "recent" }?.initiallySelected, true)
        XCTAssertEqual(scan.resources.first { $0.id == "old" }?.initiallySelected, true)
        XCTAssertTrue(scan.resources.first { $0.id == "recent" }?.reason.contains("16 hours ago") == true)

    }

    func testInspectionFailurePreventsUnsafeScan() {
        XCTAssertThrowsError(try CleanupService.scan(run: { args in
            if args == ["context", "show"] { return self.ok("colima") }
            if args.contains("ps") { return self.ok("container") }
            return self.ok("[]")
        }))
    }

    func testDeletionPinsContextBuilderAndLimitsCacheToSelectedID() {
        let image = CleanupResource(id: "sha256:abc", kind: .image, name: "local", bytes: 1, reason: "", initiallySelected: false)
        let cache = CleanupResource(id: "cache123", kind: .cache, name: "build", bytes: 2, reason: "", initiallySelected: true)
        let scan = CleanupScan(context: "colima", builder: "builder", resources: [image, cache], warning: nil)
        var commands: [[String]] = []
        let results = CleanupService.delete([image, cache], scan: scan, run: { args in
            commands.append(args)
            if args.contains("du") { return self.ok("") }
            return args.contains("image") ? .init(status: 1, stdout: "", stderr: "image is in use") : self.ok("Total: 2B")
        })
        XCTAssertEqual(commands, [
            ["--context", "colima", "image", "rm", "sha256:abc"],
            ["--context", "colima", "buildx", "prune", "--builder", "builder", "--all", "--force", "--filter", "id~=^(cache123)$"],
            ["--context", "colima", "buildx", "du", "--builder", "builder", "--format=json"]
        ])
        XCTAssertFalse(results[0].success)
        XCTAssertTrue(results[1].success)
        XCTAssertTrue(results[1].detail.contains("1 / 1 件の削除を確認"))
        XCTAssertTrue(results[1].detail.contains("Total: 2B"))
    }

    func testRelatedCachesAreDeletedTogetherAndRetainedRecordsAreReported() {
        let parent = CleanupResource(id: "parent", kind: .cache, name: "parent", bytes: 100, reason: "", initiallySelected: true)
        let child = CleanupResource(id: "child", kind: .cache, name: "child", bytes: 10, reason: "", initiallySelected: true)
        let other = CleanupResource(id: "unselected", kind: .cache, name: "other", bytes: 1, reason: "", initiallySelected: true)
        let scan = CleanupScan(context: "colima", builder: "builder", resources: [parent, child, other], warning: nil)
        var pruneCalls = 0
        let results = CleanupService.delete([parent, child], scan: scan, run: { args in
            if args.contains("prune") {
                pruneCalls += 1
                XCTAssertEqual(args.last, "id~=^(child|parent)$")
                return self.ok("Total: 10B")
            }
            return self.ok(#"{"ID":"parent"}"#)
        })
        XCTAssertEqual(pruneCalls, 1)
        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].success)
        XCTAssertTrue(results[0].detail.contains("1 / 2 件の削除を確認"))
        XCTAssertTrue(results[0].detail.contains("parent (parent)"))
    }

    func testCacheVerificationFailureIsNotReportedAsSuccess() {
        let cache = CleanupResource(id: "cache", kind: .cache, name: "cache", bytes: 1, reason: "", initiallySelected: true)
        let scan = CleanupScan(context: "colima", builder: "builder", resources: [cache], warning: nil)
        let results = CleanupService.delete([cache], scan: scan, run: { args in
            args.contains("du") ? self.ok("invalid JSON") : self.ok("Total: 0B")
        })
        XCTAssertFalse(results[0].success)
        XCTAssertTrue(results[0].detail.contains("削除結果を確認できませんでした"))
    }

    func testCacheFailureStillAllowsImagesAndShowsWarning() throws {
        let scan = try CleanupService.scan(run: { args in
            if args == ["context", "show"] { return self.ok("colima") }
            if args.contains("buildx") { return .init(status: 1, stdout: "", stderr: "unsupported") }
            return self.ok("")
        })
        XCTAssertNotNil(scan.warning)
        XCTAssertNil(scan.builder)
        XCTAssertTrue(scan.resources.isEmpty)
    }
}
