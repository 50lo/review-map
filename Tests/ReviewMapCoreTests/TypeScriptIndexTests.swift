import Foundation
import XCTest
@testable import ReviewMapCore

/// TypeScript index mode on Fixtures/typescript-indexed, an npm workspace without third-party
/// dependencies. Name matching gets its common member name wrong: `load()` on Store and Cache, where
/// the app only calls Store's. Skipped without Node.js, or when scip-typescript can't be fetched.
final class TypeScriptIndexTests: XCTestCase {
    static var repo: String?
    static var cache: String?
    static var indexed: ChangeModel?
    static var available: Bool?

    override class func tearDown() {
        for dir in [repo, cache].compactMap({ $0 }) { try? FileManager.default.removeItem(atPath: dir) }
        super.tearDown()
    }

    func requireIndexer() throws {
        if Self.available == nil {
            let tool = ProcessInfo.processInfo.environment["REVIEWMAP_SCIP_TYPESCRIPT"].map { $0.split(separator: " ").map(String.init) }
                ?? ["npx", "--yes", TypeScriptIndex.scipTypeScript]
            Self.available = Shell.exists("node") && (try? Shell.run(tool + ["--version"])) != nil
        }
        if Self.available != true { throw XCTSkip("Node.js or scip-typescript is not available.") }
    }

    func fixtureRepo() throws -> String {
        if let r = Self.repo { return r }
        let repo = try Fixture.repo("typescript-indexed")
        Self.repo = repo
        Self.cache = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-ts-index-cache-\(UUID().uuidString)")
        return repo
    }

    func analyze(index: IndexOptions, log: @escaping (String) -> Void = { _ in }) throws -> ChangeModel {
        try Analyzer.run(AnalyzeOptions(repo: try fixtureRepo(), base: "base", head: "main", index: index), log: log)
    }

    func indexedModel() throws -> ChangeModel {
        try requireIndexer()
        if let m = Self.indexed { return m }
        _ = try fixtureRepo()
        let m = try analyze(index: IndexOptions(enabled: true, cacheDir: Self.cache!))
        Self.indexed = m
        return m
    }

    func entity(_ m: ChangeModel, _ name: String) throws -> Entity {
        try XCTUnwrap(m.entities.first { $0.qualifiedName == name }, "no entity \(name)")
    }

    func testExactMemberUsage() throws {
        let m = try indexedModel()
        XCTAssertEqual(m.analyzer.resolution, "index")
        XCTAssertFalse(m.warnings.contains { $0.kind.hasPrefix("index-") }, "\(m.warnings)")
        XCTAssertEqual(try entity(m, "Store.load()").usedBy.map(\.symbol), ["start()"])
        XCTAssertEqual(try entity(m, "Cache.load()").usedBy, [], "the app never calls Cache.load()")

        let named = try analyze(index: IndexOptions())
        XCTAssertEqual(named.analyzer.resolution, "name-based")
        XCTAssertEqual(try entity(named, "Cache.load()").usedBy.map(\.symbol), ["start()"], "name matching over-counts")
    }

    func testEdgesMatchNameMatching() throws {
        let m = try indexedModel()
        let edge = try XCTUnwrap(m.edges.first { $0.from == "npm:@demo/app" && $0.to == "npm:@demo/lib" })
        XCTAssertEqual(edge.status, .unchanged)
        XCTAssertTrue(Set(edge.refs.map(\.symbol)).isSuperset(of: ["Cache", "Store"]))
    }

    func testCacheAndFallback() throws {
        _ = try indexedModel()
        var lines: [String] = []
        let again = try analyze(index: IndexOptions(enabled: true, cacheDir: Self.cache!)) { lines.append($0) }
        XCTAssertEqual(again.analyzer.resolution, "index")
        XCTAssertTrue(lines.contains { $0.contains("TypeScript index for head") && $0.hasSuffix("cached.") }, "\(lines)")

        setenv("REVIEWMAP_SCIP_TYPESCRIPT", "false", 1)
        defer { unsetenv("REVIEWMAP_SCIP_TYPESCRIPT") }
        let failed = try analyze(index: IndexOptions(enabled: true, cacheDir: Self.cache!, rebuild: true))
        XCTAssertEqual(failed.analyzer.resolution, "name-based")
        XCTAssertTrue(failed.warnings.contains { $0.kind == "index-unavailable" && $0.message.contains("scip-typescript failed") })
    }
}
