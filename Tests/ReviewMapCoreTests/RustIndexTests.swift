import Foundation
import XCTest
@testable import ReviewMapCore

final class RustIndexTests: XCTestCase {
    static var repo: String?
    static var cache: String?
    static var indexed: ChangeReport?

    override class func tearDown() {
        for path in [repo, cache].compactMap({ $0 }) { try? FileManager.default.removeItem(atPath: path) }
        super.tearDown()
    }

    func fixtureRepo() throws -> String {
        if let repo = Self.repo { return repo }
        let repo = try Fixture.repo("rust-indexed")
        Self.repo = repo
        Self.cache = NSTemporaryDirectory() + "rm-rust-index-\(UUID().uuidString)"
        return repo
    }

    func requireIndexer() throws {
        guard Shell.exists("cargo"), (try? Shell.run(["rust-analyzer", "--version"])) != nil else {
            if ProcessInfo.processInfo.environment["CI"] == "true" { XCTFail("CI must install rust-analyzer and Cargo") }
            throw XCTSkip("Cargo and rust-analyzer are required")
        }
    }

    func analyze(_ options: IndexOptions, log: @escaping (String) -> Void = { _ in }) throws -> ChangeReport {
        try Analyzer.run(AnalyzeOptions(repo: try fixtureRepo(), base: "base", head: "main", index: options), log: log)
    }

    func indexedReport() throws -> ChangeReport {
        try requireIndexer()
        if let report = Self.indexed { return report }
        _ = try fixtureRepo()
        let report = try analyze(IndexOptions(enabled: true, cacheDir: Self.cache!))
        Self.indexed = report
        return report
    }

    func testExactTraitCallAndCache() throws {
        let report = try indexedReport()
        XCTAssertEqual(report.analyzer.resolution, "index")
        let changed = report.reviewItems.filter { $0.qualifiedName.contains("render") }
        XCTAssertEqual(changed.count, 2)
        XCTAssertEqual(changed.filter { !$0.usedBy.isEmpty }.count, 1, "Only Alpha's implementation is called: \(changed)")
        let named = try analyze(IndexOptions())
        XCTAssertNotEqual(named.reviewItems.filter { $0.qualifiedName.contains("render") }.map(\.usedBy), changed.map(\.usedBy), "index mode must improve the ambiguous method call")
        var logs: [String] = []
        let cached = try analyze(IndexOptions(enabled: true, cacheDir: Self.cache!)) { logs.append($0) }
        XCTAssertEqual(cached.analyzer.resolution, "index")
        XCTAssertTrue(logs.contains { $0.contains("Rust index for head") && $0.hasSuffix("cached.") })
    }

    func testFailedIndexerFallsBackOnBothSides() throws {
        try requireIndexer()
        let old = ProcessInfo.processInfo.environment["REVIEWMAP_RUST_ANALYZER"]
        let cache = NSTemporaryDirectory() + "rm-rust-failed-\(UUID().uuidString)"
        let tool = cache + "-tool"
        try "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then exit 0; fi\nexit 1\n".write(toFile: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool)
        setenv("REVIEWMAP_RUST_ANALYZER", tool, 1)
        defer {
            if let old { setenv("REVIEWMAP_RUST_ANALYZER", old, 1) } else { unsetenv("REVIEWMAP_RUST_ANALYZER") }
            try? FileManager.default.removeItem(atPath: cache)
            try? FileManager.default.removeItem(atPath: tool)
        }
        let report = try analyze(IndexOptions(enabled: true, cacheDir: cache))
        XCTAssertEqual(report.analyzer.resolution, "name-based")
        XCTAssertTrue(report.warnings.contains { $0.kind == "index-unavailable" && $0.message.contains("scip failed") })
    }

    func testWithoutCargo() throws {
        _ = try fixtureRepo()
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let bin = NSTemporaryDirectory() + "rm-no-cargo-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        for tool in ["git", "which", "env", "tar"] {
            let found = try Shell.string(["which", tool])
            try FileManager.default.createSymbolicLink(atPath: bin + "/" + tool, withDestinationPath: found)
        }
        setenv("PATH", bin, 1)
        defer { setenv("PATH", path, 1); try? FileManager.default.removeItem(atPath: bin) }
        let cache = NSTemporaryDirectory() + "rm-rust-no-cargo-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: cache) }
        let report = try analyze(IndexOptions(enabled: true, cacheDir: cache))
        XCTAssertEqual(report.analyzer.resolution, "name-based")
        XCTAssertTrue(report.warnings.contains { $0.kind == "index-unavailable" && $0.message.contains("Cargo toolchain") })
    }

    func testPartialMacroDiagnostics() {
        XCTAssertTrue(RustIndex.hasPartialDiagnostics("WARN proc-macro loading for /tmp/macros.dylib failed: incompatible version"))
        XCTAssertTrue(RustIndex.hasPartialDiagnostics("INFO Failed to start proc-macro server"))
        XCTAssertFalse(RustIndex.hasPartialDiagnostics("INFO Proc-macro server started\nGenerating SCIP finished 1s"))
        XCTAssertTrue(RustIndex.hasPartialDiagnostics("ERROR Encountered duplicate SCIP symbols"))
        XCTAssertTrue(RustIndex.hasPartialDiagnostics("ERROR Encountered enclosing definition with no name def=Module(...)"))
        XCTAssertFalse(RustIndex.hasPartialDiagnostics("INFO error handling enabled for error messages"))
        XCTAssertFalse(RustIndex.hasPartialDiagnostics("DEBUG proc-macro loading for macros.dylib succeeded\nINFO no failed requests"))
    }

    func testWorkspaceDiscoveryFindsIndependentNestedProjects() throws {
        guard Shell.exists("cargo") else { throw XCTSkip("Cargo is required") }
        let root = NSTemporaryDirectory() + "rm-rust-projects-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        for (directory, name) in [("services/server", "server"), ("tools/worker", "worker"), ("services/server/fixtures/sample", "sample")] {
            try FileManager.default.createDirectory(atPath: root + "/" + directory + "/src", withIntermediateDirectories: true)
            try "[package]\nname = \"\(name)\"\nversion = \"0.1.0\"\nedition = \"2021\"\n".write(toFile: root + "/" + directory + "/Cargo.toml", atomically: true, encoding: .utf8)
            try "pub fn value() {}\n".write(toFile: root + "/" + directory + "/src/lib.rs", atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(try RustIndex.workspaceDirs(root), ["services/server", "tools/worker"])
    }

    func testWorkspaceDiscoveryRejectsWorkspaceOutsideExport() throws {
        guard Shell.exists("cargo") else { throw XCTSkip("Cargo is required") }
        let parent = NSTemporaryDirectory() + "rm-rust-outside-\(UUID().uuidString)"
        let root = parent + "/export"
        defer { try? FileManager.default.removeItem(atPath: parent) }
        try FileManager.default.createDirectory(atPath: root + "/crate/src", withIntermediateDirectories: true)
        try "[workspace]\nmembers = [\"export/crate\"]\nresolver = \"2\"\n".write(toFile: parent + "/Cargo.toml", atomically: true, encoding: .utf8)
        try "[package]\nname = \"outside\"\nversion = \"0.1.0\"\nedition = \"2021\"\n".write(toFile: root + "/crate/Cargo.toml", atomically: true, encoding: .utf8)
        try "pub fn value() {}\n".write(toFile: root + "/crate/src/lib.rs", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try RustIndex.workspaceDirs(root)) { error in
            XCTAssertTrue(String(describing: error).contains("outside the exported commit"))
        }
    }

    func testFailedBuildScriptRetainsPartialIndexAndWarningOnCacheHit() throws {
        try requireIndexer()
        let root = NSTemporaryDirectory() + "rm-rust-partial-\(UUID().uuidString)"
        let cache = root + "-cache"
        defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(atPath: cache) }
        try FileManager.default.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        try "[package]\nname = \"broken-build\"\nversion = \"0.1.0\"\nedition = \"2021\"\n".write(toFile: root + "/Cargo.toml", atomically: true, encoding: .utf8)
        try "fn main() { panic!(\"intentional build failure\"); }\n".write(toFile: root + "/build.rs", atomically: true, encoding: .utf8)
        try "pub fn value() -> u32 { 1 }\npub fn call() -> u32 { value() }\n".write(toFile: root + "/src/lib.rs", atomically: true, encoding: .utf8)
        let side = IndexSide(side: .head, sha: "partial", dir: root, files: ["src/lib.rs"])
        for _ in 0..<2 {
            let result = try RustIndex.load(options: IndexOptions(cacheDir: cache), repoRoot: root, sides: [side], log: { _ in })
            XCTAssertFalse(try XCTUnwrap(result[.head]?.refs["src/lib.rs"]).isEmpty)
            XCTAssertTrue(result[.head]?.warnings.contains { $0.kind == "index-partial" } == true)
        }
    }
}
