import Foundation
import XCTest
@testable import ReviewMapCore

/// Index mode on Fixtures/indexed, a package that builds anywhere (Foundation only). It has the cases
/// name matching gets wrong: a common member name (`load()` on Store and Cache) and a type name
/// declared in two modules (`Config` in Storage and Settings), used module-qualified.
final class IndexTests: XCTestCase {
    static var repo: String?
    static var cache: String?
    static var indexed: ChangeModel?
    static var named: ChangeModel?

    override class func tearDown() {
        for dir in [repo, cache].compactMap({ $0 }) { try? FileManager.default.removeItem(atPath: dir) }
        super.tearDown()
    }

    func requireIndexStore() throws {
        do { _ = try IndexBuilder.libraryPath() } catch { throw XCTSkip("No libIndexStore in this toolchain: \(error)") }
    }

    func fixtureRepo() throws -> String {
        if let r = Self.repo { return r }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/indexed", withExtension: nil)).path
        let repo = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-indexed-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        func git(_ args: String...) throws {
            try Shell.run(["git", "-C", repo, "-c", "user.email=fixture@example.com", "-c", "user.name=fixture"] + args)
        }
        func copyTree(_ side: String) throws {
            for item in try fm.contentsOfDirectory(atPath: repo) where item != ".git" {
                try fm.removeItem(atPath: repo + "/" + item)
            }
            for item in try fm.contentsOfDirectory(atPath: fixture + "/" + side) {
                try fm.copyItem(atPath: fixture + "/" + side + "/" + item, toPath: repo + "/" + item)
            }
        }
        try git("init", "-q", "-b", "main")
        try copyTree("base")
        try git("add", "-A")
        try git("commit", "-qm", "base")
        try git("branch", "base")
        try copyTree("head")
        try git("add", "-A")
        try git("commit", "-qm", "head")
        Self.repo = repo
        Self.cache = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-index-cache-\(UUID().uuidString)")
        return repo
    }

    func analyze(index: IndexOptions) throws -> ChangeModel {
        try Analyzer.run(AnalyzeOptions(repo: try fixtureRepo(), base: "base", head: "main", index: index))
    }

    func indexedModel() throws -> ChangeModel {
        try requireIndexStore()
        if let m = Self.indexed { return m }
        _ = try fixtureRepo()
        let m = try analyze(index: IndexOptions(enabled: true, builder: "swift", cacheDir: Self.cache!))
        Self.indexed = m
        return m
    }

    func namedModel() throws -> ChangeModel {
        if let m = Self.named { return m }
        let m = try analyze(index: IndexOptions())
        Self.named = m
        return m
    }

    func entity(_ m: ChangeModel, _ name: String) throws -> Entity {
        try XCTUnwrap(m.entities.first { $0.qualifiedName == name }, "no entity \(name)")
    }

    func testResolutionIsRecorded() throws {
        XCTAssertEqual(try indexedModel().analyzer.resolution, "index")
        XCTAssertEqual(try namedModel().analyzer.resolution, "name-based")
        XCTAssertFalse(try indexedModel().warnings.contains { $0.kind.hasPrefix("index-") })
    }

    func testCommonMemberNameIsNotCountedAsUse() throws {
        // Feed.cached() calls Cache.load(); name matching counts it as a use of Store.load().
        XCTAssertEqual(Set(try entity(try namedModel(), "Store.load()").usedBy.map(\.symbol)), ["Feed.items()", "Feed.cached()"])
        XCTAssertEqual(try entity(try indexedModel(), "Store.load()").usedBy.map(\.symbol), ["Feed.items()"])
    }

    func testCallerContextIsExact() throws {
        let m = try indexedModel()
        let load = try entity(m, "Store.load()")
        let callers = m.regions.filter { $0.entity == load.id && $0.relation == "caller" }
        XCTAssertEqual(callers.map { $0.reasons[0] }, ["Feed.items()"])
    }

    func testModuleQualifiedReferenceMakesAnEdgeChange() throws {
        // Feed.limit() uses Storage.Config, new at head. Name matching doesn't see it.
        let edge = { (m: ChangeModel) in m.edges.first { $0.from == "spm:Feed" && $0.to == "spm:Storage" } }
        XCTAssertEqual(edge(try namedModel())?.status, .unchanged)
        let e = try XCTUnwrap(edge(try indexedModel()))
        XCTAssertEqual(e.status, .changed)
        XCTAssertEqual(e.symbolsAdded, ["Config"])
        // The other Config (Settings) is used on both sides, so that edge stays unchanged.
        XCTAssertEqual(try indexedModel().edges.first { $0.from == "spm:Feed" && $0.to == "spm:Settings" }?.status, .unchanged)
    }

    func testDependsOnAndDefinitionsPointAtTheRightModule() throws {
        let m = try indexedModel()
        let limit = try entity(m, "Feed.limit()")
        XCTAssertTrue(limit.dependsOn.contains { $0.component == "spm:Storage" && $0.symbol == "Config.limit" })
        XCTAssertFalse(limit.dependsOn.contains { $0.component == "spm:Settings" })
        let defs = m.regions.filter { $0.entity == limit.id && $0.relation == "definition" }
        XCTAssertTrue(defs.contains { $0.reasons[0] == "Config" && $0.file == "Sources/Storage/Config.swift" })
        XCTAssertFalse(defs.contains { $0.file.hasPrefix("Sources/Settings") })
    }

    func testCachedStoreIsReusedWithoutBuilding() throws {
        _ = try indexedModel()
        // An unknown builder would fail if a build were attempted.
        let again = try analyze(index: IndexOptions(enabled: true, builder: "none", cacheDir: Self.cache!))
        XCTAssertEqual(again.analyzer.resolution, "index")
        XCTAssertEqual(again.edges, try indexedModel().edges)
        XCTAssertEqual(again.entities, try indexedModel().entities)
    }

    func testFailedBuildFallsBackToNamesAndKeepsTheCache() throws {
        _ = try indexedModel()
        let failed = try analyze(index: IndexOptions(enabled: true, builder: "none", cacheDir: Self.cache!, rebuild: true))
        XCTAssertEqual(failed.analyzer.resolution, "name-based")
        XCTAssertTrue(failed.warnings.contains { $0.kind == "index-unavailable" })
        XCTAssertEqual(failed.entities, try namedModel().entities)
        // The stores from the earlier build are still there.
        XCTAssertEqual(try analyze(index: IndexOptions(enabled: true, builder: "none", cacheDir: Self.cache!)).analyzer.resolution, "index")
    }

    func testIndexFollowsReviewmapYml() throws {
        try requireIndexStore()
        let repo = try fixtureRepo()
        let config = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-index-\(UUID().uuidString).yml")
        defer { try? FileManager.default.removeItem(atPath: config) }
        try "index:\n  enabled: true\n  builder: swift\n".write(toFile: config, atomically: true, encoding: .utf8)
        let on = try Analyzer.run(AnalyzeOptions(repo: repo, base: "base", head: "main", configPath: config,
                                                 index: IndexOptions(cacheDir: Self.cache!)))
        XCTAssertEqual(on.analyzer.resolution, "index")
        let off = try Analyzer.run(AnalyzeOptions(repo: repo, base: "base", head: "main", configPath: config,
                                                  index: IndexOptions(enabled: false, cacheDir: Self.cache!)))
        XCTAssertEqual(off.analyzer.resolution, "name-based", "--no-index wins over reviewmap.yml")
    }
}
