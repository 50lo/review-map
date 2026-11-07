import Foundation
import XCTest
@testable import ReviewMapCore

/// Kotlin index mode on Fixtures/kotlin-gradle-indexed: two Gradle modules without third-party dependencies.
/// Name matching gets a method name that two classes in `core` declare wrong: `load()` on Store and Cache, where
/// the app module only calls Store's. Skipped without a JDK and Gradle, or when scip-java can't be downloaded.
final class KotlinIndexTests: XCTestCase {
    static var repo: String?
    static var cache: String?
    static var indexed: ChangeReport?
    static var available: Bool?

    override class func tearDown() {
        for dir in [repo, cache].compactMap({ $0 }) { try? FileManager.default.removeItem(atPath: dir) }
        super.tearDown()
    }

    func requireIndexer() throws {
        if Self.available == nil { Self.available = KotlinIndex.hasJava() && Shell.exists("gradle") }
        if Self.available != true { throw XCTSkip("A JDK and Gradle are not available.") }
    }

    func fixtureRepo() throws -> String {
        if let r = Self.repo { return r }
        let repo = try Fixture.repo("kotlin-gradle-indexed")
        Self.repo = repo
        Self.cache = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-kotlin-index-cache-\(UUID().uuidString)")
        return repo
    }

    func analyze(index: IndexOptions, log: @escaping (String) -> Void = { _ in }) throws -> ChangeReport {
        try Analyzer.run(AnalyzeOptions(repo: try fixtureRepo(), base: "base", head: "main", index: index), log: log)
    }

    func indexedReport() throws -> ChangeReport {
        try requireIndexer()
        if let m = Self.indexed { return m }
        _ = try fixtureRepo()
        let m = try analyze(index: IndexOptions(enabled: true, cacheDir: Self.cache!))
        if m.warnings.contains(where: { $0.kind == "index-unavailable" && $0.message.contains("download scip-java") }) {
            throw XCTSkip("scip-java could not be downloaded.")
        }
        Self.indexed = m
        return m
    }

    func reviewItem(_ m: ChangeReport, _ name: String) throws -> ReviewItem {
        try XCTUnwrap(m.reviewItems.first { $0.qualifiedName == name }, "no review item \(name)")
    }

    func testExactMemberUsageAcrossModules() throws {
        let m = try indexedReport()
        XCTAssertEqual(m.analyzer.resolution, "index")
        XCTAssertFalse(m.warnings.contains { $0.kind.hasPrefix("index-") }, "\(m.warnings)")
        XCTAssertEqual(try reviewItem(m, "Store.load()").usedBy.map(\.symbol), ["start()"])
        XCTAssertEqual(try reviewItem(m, "Cache.load()").usedBy, [], "the app never calls Cache.load()")

        let named = try analyze(index: IndexOptions())
        XCTAssertEqual(named.analyzer.resolution, "name-based")
        XCTAssertNotEqual(try reviewItem(named, "Cache.load()").usedBy.map(\.symbol), [],
                          "name matching can't tell the two load() methods apart")
    }

    func testCacheAndFallback() throws {
        _ = try indexedReport()
        var lines: [String] = []
        let again = try analyze(index: IndexOptions(enabled: true, cacheDir: Self.cache!)) { lines.append($0) }
        XCTAssertEqual(again.analyzer.resolution, "index")
        XCTAssertTrue(lines.contains { $0.contains("Kotlin index for head") && $0.hasSuffix("cached.") }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("with Gradle and scip-java") }, "a cached run starts no build: \(lines)")
    }

    /// Needs no JDK or Gradle: a failing scip-java falls back to name matching at both sides.
    func testFailedIndexerFallsBack() throws {
        setenv("REVIEWMAP_SCIP_JAVA", "false", 1)
        defer { unsetenv("REVIEWMAP_SCIP_JAVA") }
        let cache = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-kotlin-fail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: cache) }
        let m = try analyze(index: IndexOptions(enabled: true, cacheDir: cache))
        XCTAssertEqual(m.analyzer.resolution, "name-based")
        XCTAssertTrue(m.warnings.contains { $0.kind == "index-unavailable" && $0.message.contains("scip-java failed") }, "\(m.warnings)")
    }

    func testWithoutJava() throws {
        // A PATH without java or gradle, as on a machine without a JDK.
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let bin = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-no-java-\(UUID().uuidString)")
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
        let cache = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-kotlin-nojava-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: cache) }
        let m = try analyze(index: IndexOptions(enabled: true, cacheDir: cache))
        XCTAssertEqual(m.analyzer.resolution, "name-based")
        XCTAssertTrue(m.warnings.contains { $0.kind == "index-unavailable" && $0.message.contains("needs a JDK") }, "\(m.warnings)")
    }

    func testGradleBuilds() throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-gradle-builds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        for file in ["settings.gradle.kts", "app/build.gradle.kts", "included/settings.gradle.kts",
                     "tools/plugin/build.gradle", "tools/plugin/sub/build.gradle", "docs/README.md"] {
            let path = join(root, file)
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: Data())
        }
        XCTAssertEqual(KotlinIndex.gradleBuilds(root), [""], "everything sits under the root build")
        try FileManager.default.removeItem(atPath: join(root, "settings.gradle.kts"))
        XCTAssertEqual(KotlinIndex.gradleBuilds(root), ["app", "included", "tools/plugin"])
    }

    func testCacheNamesDontCollide() {
        let names = ["", "root", "_root", "tools/android", "tools-android", "tools_android"].map(KotlinIndex.cacheName)
        XCTAssertEqual(Set(names).count, names.count, "\(names)")
    }

    /// Two leaf modules declaring the same top-level function get the same uncoordinated symbol from scip-java;
    /// each module's call must reach its own declaration, while a shared module's symbol still links across.
    func testUnqualifiedSymbolsAreScopedToTheirModule() throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-kotlin-scope-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        for file in ["build/settings.gradle.kts", "build/app/build.gradle.kts", "build/tool/build.gradle.kts", "build/core/build.gradle.kts"] {
            let path = join(root, file)
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: Data())
        }
        let start = "scip-java maven . . demo/start()."
        let load = "scip-java maven maven/demo/core unspecified demo/Store#load()."
        func occurrence(_ line: Int, _ symbol: String, definition: Bool = false) -> SCIP.Occurrence {
            SCIP.Occurrence(line: line, symbol: symbol, roles: definition ? 1 : 0)
        }
        var index = SCIP.Index(projectRoot: nil, documents: [
            SCIP.Document(path: "app/src/main/kotlin/Main.kt", occurrences: [occurrence(1, start, definition: true), occurrence(5, start), occurrence(6, load)]),
            SCIP.Document(path: "tool/src/main/kotlin/Main.kt", occurrences: [occurrence(1, start, definition: true), occurrence(5, start), occurrence(6, load)]),
            SCIP.Document(path: "core/src/main/kotlin/Store.kt", occurrences: [occurrence(3, load, definition: true)]),
        ])
        KotlinIndex.scopeUnqualifiedSymbols(&index, root: root, build: "build")
        index.projectRoot = URL(fileURLWithPath: join(root, "build")).absoluteString
        let files = ["app", "tool", "core"].map { "build/\($0)/src/main/kotlin/\($0 == "core" ? "Store" : "Main").kt" }
        let side = SCIP.sideIndex([index], sourceRoot: root, known: Set(files))
        for module in ["app", "tool"] {
            let refs = try XCTUnwrap(side.refs["build/\(module)/src/main/kotlin/Main.kt"])
            XCTAssertEqual(refs.first { $0.line == 5 }?.targetFile, "build/\(module)/src/main/kotlin/Main.kt", "start() stays in \(module)")
            XCTAssertEqual(refs.first { $0.line == 5 }?.name, "start()")
            XCTAssertEqual(refs.first { $0.line == 6 }?.targetFile, "build/core/src/main/kotlin/Store.kt", "load() links across modules")
        }
    }
}
