import Foundation
import XCTest
@testable import ReviewMapCore

/// Go index mode on Fixtures/go-indexed, a module without third-party dependencies. Name matching gets a
/// method name that two packages declare wrong: `Load()` on store.Store and cache.Cache, where the app only
/// calls Store's. Skipped without the Go toolchain, or when scip-go can't be installed.
final class GoIndexTests: XCTestCase {
    static var repo: String?
    static var cache: String?
    static var indexed: ChangeModel?
    static var available: Bool?

    override class func tearDown() {
        for dir in [repo, cache].compactMap({ $0 }) { try? FileManager.default.removeItem(atPath: dir) }
        super.tearDown()
    }

    func requireIndexer() throws {
        if Self.available == nil { Self.available = Shell.exists("go") }
        if Self.available != true { throw XCTSkip("The Go toolchain is not available.") }
    }

    func fixtureRepo() throws -> String {
        if let r = Self.repo { return r }
        let repo = try Fixture.repo("go-indexed")
        Self.repo = repo
        Self.cache = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-go-index-cache-\(UUID().uuidString)")
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
        if m.warnings.contains(where: { $0.kind == "index-unavailable" && $0.message.contains("install scip-go") }) {
            throw XCTSkip("scip-go could not be installed.")
        }
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
        XCTAssertEqual(try entity(m, "Store.Load()").usedBy.map(\.symbol), ["start()"])
        XCTAssertEqual(try entity(m, "Cache.Load()").usedBy, [], "the app never calls Cache.Load()")

        let named = try analyze(index: IndexOptions())
        XCTAssertEqual(named.analyzer.resolution, "name-based")
        XCTAssertEqual(try entity(named, "Cache.Load()").usedBy.map(\.symbol), ["start()"], "name matching over-counts")
    }

    func testEdgesMatchNameMatching() throws {
        let m = try indexedModel()
        let edge = try XCTUnwrap(m.edges.first { $0.from == "go:example.com/demo/app" && $0.to == "go:example.com/demo/cache" })
        XCTAssertEqual(edge.status, .unchanged)
        XCTAssertTrue(edge.refs.map(\.symbol).contains("Cache"))
    }

    func testCacheAndFallback() throws {
        _ = try indexedModel()
        var lines: [String] = []
        let again = try analyze(index: IndexOptions(enabled: true, cacheDir: Self.cache!)) { lines.append($0) }
        XCTAssertEqual(again.analyzer.resolution, "index")
        XCTAssertTrue(lines.contains { $0.contains("Go index for head") && $0.hasSuffix("cached.") }, "\(lines)")

        setenv("REVIEWMAP_SCIP_GO", "false", 1)
        defer { unsetenv("REVIEWMAP_SCIP_GO") }
        let failed = try analyze(index: IndexOptions(enabled: true, cacheDir: Self.cache!, rebuild: true))
        XCTAssertEqual(failed.analyzer.resolution, "name-based")
        XCTAssertTrue(failed.warnings.contains { $0.kind == "index-unavailable" && $0.message.contains("scip-go failed") }, "\(failed.warnings)")
    }

    func testWithoutGo() throws {
        // A PATH without the go tool, as on a machine without Go.
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let bin = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-no-go-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        for tool in ["git", "which", "env", "tar"] {
            if let found = try? Shell.string(["which", tool]).trimmingCharacters(in: .whitespacesAndNewlines), !found.isEmpty {
                try? FileManager.default.createSymbolicLink(atPath: bin + "/" + tool, withDestinationPath: found)
            }
        }
        setenv("PATH", bin, 1)
        defer {
            setenv("PATH", path, 1)
            try? FileManager.default.removeItem(atPath: bin)
        }
        let cache = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-go-nogo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: cache) }
        let m = try analyze(index: IndexOptions(enabled: true, cacheDir: cache))
        XCTAssertEqual(m.analyzer.resolution, "name-based")
        XCTAssertTrue(m.warnings.contains { $0.kind == "index-unavailable" && $0.message.contains("Go toolchain") }, "\(m.warnings)")
    }
}
