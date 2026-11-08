import Foundation
import XCTest
@testable import ReviewMapCore

/// Kotlin index mode on Fixtures/kotlin-bazel-indexed: a rules_kotlin workspace with `//store` and `//cache`
/// libraries and an `//app` binary. Name matching gets a method name that both libraries declare wrong: `load()` on
/// Store and Cache, where the app only calls Store's. Skipped without Bazel and a JDK, or when scip-java can't be
/// downloaded. The first run fetches rules_kotlin, so it needs the network once.
final class KotlinBazelIndexTests: XCTestCase {
    static var repo: String?
    static var cache: String?
    static var indexed: ChangeReport?
    static var available: Bool?

    override class func tearDown() {
        for dir in [repo, cache].compactMap({ $0 }) { try? FileManager.default.removeItem(atPath: dir) }
        super.tearDown()
    }

    func requireTools() throws {
        if Self.available == nil { Self.available = KotlinIndex.hasJava() && KotlinBazel.bazelCommand() != nil }
        if Self.available != true { throw XCTSkip("Bazel and a JDK are not available.") }
    }

    func fixtureRepo() throws -> String {
        if let r = Self.repo { return r }
        let repo = try Fixture.repo("kotlin-bazel-indexed")
        Self.repo = repo
        Self.cache = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-kotlin-bazel-cache-\(UUID().uuidString)")
        return repo
    }

    func analyze(index: IndexOptions, log: @escaping (String) -> Void = { _ in }) throws -> ChangeReport {
        try Analyzer.run(AnalyzeOptions(repo: try fixtureRepo(), base: "base", head: "main", index: index), log: log)
    }

    /// Output bases of Kotlin's Bazel runs that are still on disk.
    func outputBases() -> Set<String> {
        let tmp = NSTemporaryDirectory()
        return Set(((try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? []).filter { $0.hasPrefix("rm-kt-") })
    }

    func indexedReport() throws -> ChangeReport {
        try requireTools()
        if let m = Self.indexed { return m }
        _ = try fixtureRepo()
        let before = outputBases()
        let m = try analyze(index: IndexOptions(enabled: true, cacheDir: Self.cache!))
        if m.warnings.contains(where: { $0.kind == "index-unavailable" && $0.message.contains("download scip-java") }) {
            throw XCTSkip("scip-java could not be downloaded.")
        }
        XCTAssertEqual(outputBases().subtracting(before), [], "Kotlin's Bazel output bases are removed")
        Self.indexed = m
        return m
    }

    func reviewItem(_ m: ChangeReport, _ name: String) throws -> ReviewItem {
        try XCTUnwrap(m.reviewItems.first { $0.qualifiedName == name }, "no review item \(name)")
    }

    func testExactMemberUsageAcrossPackages() throws {
        let m = try indexedReport()
        XCTAssertEqual(m.analyzer.resolution, "index", "\(m.warnings)")
        XCTAssertFalse(m.warnings.contains { $0.kind.hasPrefix("index-") }, "\(m.warnings)")
        XCTAssertEqual(try reviewItem(m, "Store.load()").usedBy.map(\.symbol), ["start()"])
        XCTAssertEqual(try reviewItem(m, "Cache.load()").usedBy, [], "the app never calls Cache.load()")

        let named = try analyze(index: IndexOptions())
        XCTAssertNotEqual(try reviewItem(named, "Cache.load()").usedBy.map(\.symbol), [],
                          "name matching can't tell the two load() methods apart")
    }

    func testCachedRunStartsNoBazel() throws {
        _ = try indexedReport()
        var lines: [String] = []
        let again = try analyze(index: IndexOptions(enabled: true, cacheDir: Self.cache!)) { lines.append($0) }
        XCTAssertEqual(again.analyzer.resolution, "index")
        XCTAssertTrue(lines.contains { $0.contains("Kotlin index for head") && $0.hasSuffix("cached.") }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("with Bazel for the Kotlin index") }, "a cached run starts no build: \(lines)")
    }

    /// Needs no tools: without Bazel, analysis falls back to name matching at both sides.
    func testWithoutBazelFallsBack() throws {
        setenv("REVIEWMAP_BAZEL", "reviewmap-no-such-bazel", 1)
        defer { unsetenv("REVIEWMAP_BAZEL") }
        let cache = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-kotlin-nobazel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: cache) }
        let m = try analyze(index: IndexOptions(enabled: true, cacheDir: cache))
        XCTAssertEqual(m.analyzer.resolution, "name-based")
        XCTAssertTrue(m.warnings.contains { $0.kind == "index-unavailable" && $0.message.contains("needs bazel or bazelisk") }, "\(m.warnings)")
    }

    func testAspectNamesTheRulesKotlinRepo() throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-kotlin-module-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        XCTAssertEqual(KotlinBazel.rulesKotlinRepo(dir), "rules_kotlin", "no MODULE.bazel")
        try """
        bazel_dep(name = "rules_java", version = "9.9.0", repo_name = "java")
        bazel_dep(
            name = "rules_kotlin",
            version = "2.4.21",
            repo_name = "io_bazel_rules_kotlin",
        )
        """.write(toFile: dir + "/MODULE.bazel", atomically: true, encoding: .utf8)
        XCTAssertEqual(KotlinBazel.rulesKotlinRepo(dir), "io_bazel_rules_kotlin")
        XCTAssertTrue(KotlinBazel.aspect(rulesKotlin: "io_bazel_rules_kotlin").contains("load(\"@io_bazel_rules_kotlin//kotlin/internal:defs.bzl\", \"KtJvmInfo\")"))
    }

    /// Two binaries declare `demo/start()`, which carries no coordinates: each links to its own. `Store#load()`
    /// is declared once, so the references from both binaries still link to it.
    func testDuplicateSymbolsAreScopedToTheirTarget() throws {
        let start = "scip-java maven . . demo/start()."
        let load = "scip-java maven . . demo/Store#load()."
        func occurrence(_ line: Int, _ symbol: String, definition: Bool = false) -> SCIP.Occurrence {
            SCIP.Occurrence(line: line, symbol: symbol, roles: definition ? 1 : 0)
        }
        let targets = [
            KotlinBazel.Target(label: "@@//app:app", sources: ["app/Main.kt"], classpath: [], deps: ["@@//store:store"]),
            KotlinBazel.Target(label: "@@//tool:tool", sources: ["tool/Main.kt"], classpath: [], deps: ["@@//store:store"]),
            KotlinBazel.Target(label: "@@//store:store", sources: ["store/Store.kt"], classpath: [], deps: []),
            KotlinBazel.Target(label: "@@//cli:cli", sources: ["cli/Cli.kt"], classpath: [], deps: ["@@//tool:tool"]),
        ]
        var index = SCIP.Index(projectRoot: nil, documents: [
            SCIP.Document(path: "app/Main.kt", occurrences: [occurrence(1, start, definition: true), occurrence(5, start), occurrence(6, load)]),
            SCIP.Document(path: "tool/Main.kt", occurrences: [occurrence(1, start, definition: true), occurrence(5, start), occurrence(6, load)]),
            SCIP.Document(path: "store/Store.kt", occurrences: [occurrence(3, load, definition: true)]),
            SCIP.Document(path: "cli/Cli.kt", occurrences: [occurrence(2, start)]),
        ])
        KotlinBazel.scopeDuplicateSymbols(&index, targets: targets)
        let root = "/tmp/rm-scope-\(UUID().uuidString)"
        index.projectRoot = URL(fileURLWithPath: join(root, "ws")).absoluteString
        let files = ["app/Main.kt", "tool/Main.kt", "store/Store.kt", "cli/Cli.kt"].map { "ws/" + $0 }
        let side = SCIP.sideIndex([index], sourceRoot: root, known: Set(files))
        for target in ["app", "tool"] {
            let refs = try XCTUnwrap(side.refs["ws/\(target)/Main.kt"])
            XCTAssertEqual(refs.first { $0.line == 5 }?.targetFile, "ws/\(target)/Main.kt", "start() stays in \(target)")
            XCTAssertEqual(refs.first { $0.line == 5 }?.name, "start()")
            XCTAssertEqual(refs.first { $0.line == 6 }?.targetFile, "ws/store/Store.kt", "load() links across targets")
        }
        XCTAssertEqual(side.refs["ws/cli/Cli.kt"]?.first?.targetFile, "ws/tool/Main.kt", "the declaring target it depends on")
    }

    func testReadsManifests() throws {
        let bin = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-kotlin-bin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: bin) }
        try FileManager.default.createDirectory(atPath: bin + "/app", withIntermediateDirectories: true)
        try #"{"classpath":["bazel-out/bin/store/store.abi.jar"],"deps":["@@//store:store"],"label":"@@//app:app","sources":["app/Main.kt"]}"#
            .write(toFile: bin + "/app/app" + KotlinBazel.manifestSuffix, atomically: true, encoding: .utf8)
        try "{}".write(toFile: bin + "/app/app.jdeps", atomically: true, encoding: .utf8)
        XCTAssertEqual(try KotlinBazel.readManifests(bin: bin), [
            KotlinBazel.Target(label: "@@//app:app", sources: ["app/Main.kt"], classpath: ["bazel-out/bin/store/store.abi.jar"], deps: ["@@//store:store"]),
        ])
    }
}
