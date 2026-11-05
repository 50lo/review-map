import Foundation
import XCTest
@testable import ReviewMapCore

/// The structural review's deterministic checks, each on a small two-commit repo. Top-level folders
/// are components of their own.
final class ChecksTests: XCTestCase {
    var repos: [String] = []

    override func tearDown() {
        for r in repos { try? FileManager.default.removeItem(atPath: r) }
        repos = []
    }

    /// A repo with `base` committed on branch `base` and `head` on `main`. A nil file content deletes the file.
    /// `index` stands in for the indexers.
    func analyze(base: [String: String], head: [String: String?],
                 index: ((Language, String, String) -> [Side: SideIndex]?)? = nil) throws -> ChangeModel {
        let repo = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-checks-\(UUID().uuidString)")
        repos.append(repo)
        let fm = FileManager.default
        try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        func git(_ args: String...) throws {
            try Shell.run(["git", "-C", repo, "-c", "user.email=fixture@example.com", "-c", "user.name=fixture"] + args)
        }
        func write(_ files: [String: String?]) throws {
            for (path, text) in files {
                let full = repo + "/" + path
                if let text {
                    try fm.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    try text.write(toFile: full, atomically: true, encoding: .utf8)
                } else {
                    try fm.removeItem(atPath: full)
                }
            }
        }
        try git("init", "-q", "-b", "main")
        try write(base)
        try git("add", "-A")
        try git("commit", "-qm", "base")
        try git("branch", "base")
        try write(head)
        try git("add", "-A")
        try git("commit", "-qm", "head")
        return try Analyzer.run(AnalyzeOptions(repo: repo, base: "base", head: "main"), index: index)
    }

    func findings(_ m: ChangeModel, _ kind: String) -> [Finding] {
        m.findings.filter { $0.kind == kind }
    }

    func testNewCycle() throws {
        let m = try analyze(
            base: ["App/App.swift": "struct AppRoot { let store = Store() }\n",
                   "Store/Store.swift": "struct Store { func load() {} }\n"],
            head: ["Store/Store.swift": "struct Store { func load() {}\n    func root() -> AppRoot? { nil } }\n"])
        let f = try XCTUnwrap(findings(m, "cycle").first)
        XCTAssertEqual(f.severity, "high")
        XCTAssertTrue(f.message.contains("App → Store → App") || f.message.contains("Store → App → Store"), f.message)
        XCTAssertTrue(f.anchors.contains(.edge("folder:Store", "folder:App")))
        XCTAssertTrue(f.evidence.contains { $0.contains("(new)") })
    }

    func testExistingCycleIsNotReported() throws {
        let m = try analyze(
            base: ["App/App.swift": "struct AppRoot { let store = Store() }\n",
                   "Store/Store.swift": "struct Store { func root() -> AppRoot? { nil } }\n"],
            head: ["Store/Store.swift": "struct Store { func root() -> AppRoot? { nil }\n    func other() {} }\n"])
        XCTAssertEqual(findings(m, "cycle"), [])
    }

    func testLayering() throws {
        let config = """
        layers:
          - name: ui
            components: ["UI"]
          - name: core
            components: ["Core"]
        """
        let m = try analyze(
            base: ["reviewmap.yml": config,
                   "UI/Screen.swift": "struct Screen { let model = Model() }\n",
                   "Core/Model.swift": "struct Model { var name = \"\" }\n"],
            head: ["Core/Model.swift": "struct Model { var name = \"\"\n    var screen: Screen? }\n"])
        XCTAssertEqual(m.components.first { $0.id == "folder:Core" }?.layer, "core")
        let f = try XCTUnwrap(findings(m, "layering").first)
        XCTAssertEqual(f.anchors.first, .edge("folder:Core", "folder:UI"))
        XCTAssertEqual(f.severity, "high")
        XCTAssertEqual(findings(m, "layering").count, 1, "UI → Core follows the layering")
    }

    func testUnusedPublicAPIAndTests() throws {
        let m = try analyze(
            base: ["Lib/Lib.swift": "public struct Lib {\n    public init() {}\n}\n",
                   "Tests/LibTests.swift": "func testLib() { _ = Lib() }\n"],
            head: ["Lib/Lib.swift": "public struct Lib {\n    public init() {}\n    public func used() {}\n    public func onlyTested() {}\n    public func nobody() {}\n}\n",
                   "App/App.swift": "func run() { Lib().used() }\n",
                   "Tests/LibTests.swift": "func testLib() { Lib().onlyTested() }\n"])
        let unused = findings(m, "unused-api")
        XCTAssertEqual(Set(unused.compactMap { $0.anchors.first?.entity }), ["folder:Lib::Lib.onlyTested()", "folder:Lib::Lib.nobody()"])
        XCTAssertTrue(unused.first { $0.anchors.first?.entity == "folder:Lib::Lib.onlyTested()" }!.evidence[0].hasPrefix("Only tests use it"))
        // Tests reach Lib, so its changed entities that no test names are listed.
        let untested = try XCTUnwrap(findings(m, "untested").first { $0.anchors.first == .component("folder:Lib") })
        XCTAssertTrue(untested.anchors.contains(.entity("folder:Lib::Lib.used()")))
        XCTAssertFalse(untested.anchors.contains(.entity("folder:Lib::Lib.onlyTested()")))
        // No test reaches App.
        XCTAssertFalse(findings(m, "untested").contains { $0.anchors.first == .component("folder:App") })
    }

    func testOrphanedCode() throws {
        let m = try analyze(
            base: ["Lib/Format.swift": "struct Format {\n    static func legacy(_ s: String) -> String { s }\n    static func current(_ s: String) -> String { s }\n}\n",
                   "App/App.swift": "func show() {\n    print(Format.legacy(\"a\"))\n    print(Format.current(\"b\"))\n}\n"],
            head: ["App/App.swift": "func show() {\n    print(Format.current(\"b\"))\n}\n"])
        let f = try XCTUnwrap(findings(m, "orphaned").first)
        XCTAssertTrue(f.message.contains("Format.legacy(_:)"), f.message)
        XCTAssertTrue(f.anchors.contains(.entity("folder:App::show()")), "the caller that dropped it")
        XCTAssertEqual(f.location?.file, "Lib/Format.swift")
        XCTAssertEqual(findings(m, "orphaned").count, 1)
    }

    /// A file the index has no data for (a target the build skipped) still counts its callers by name.
    func testPartialIndexKeepsNameReferencesOfUncoveredFiles() throws {
        let format = "struct Format {\n    static func legacy(_ s: String) -> String { s }\n}\n"
        let m = try analyze(
            base: ["Lib/Format.swift": format,
                   "App/App.swift": "func show() { print(Format.legacy(\"a\")) }\n",
                   "Other/Other.swift": "func other() { print(Format.legacy(\"b\")) }\n"],
            head: ["Other/Other.swift": "func other() { print(\"b\") }\n"],
            index: { lang, _, _ in
                guard lang.id == "swift" else { return nil }
                // App/App.swift is missing on both sides, as if its target weren't built.
                let ref = IndexedRef(line: 1, targetFile: "Lib/Format.swift", targetLine: 2, name: "legacy(_:)")
                return [.base: SideIndex(refs: ["Lib/Format.swift": [], "Other/Other.swift": [ref]]),
                        .head: SideIndex(refs: ["Lib/Format.swift": [], "Other/Other.swift": []])]
            })
        XCTAssertEqual(m.analyzer.resolution, "index")
        XCTAssertEqual(findings(m, "orphaned"), [], "App/App.swift still calls Format.legacy")
    }

    func testConformersOfAChangedProtocol() throws {
        let m = try analyze(
            base: ["Lib/Store.swift": "protocol Store {\n    func load() -> Int\n}\nstruct Memory: Store {\n    func load() -> Int { 1 }\n}\nstruct Disk: Store {\n    func load() -> Int { 2 }\n}\n"],
            head: ["Lib/Store.swift": "protocol Store {\n    func load() async -> Int\n    func clear()\n}\nstruct Memory: Store {\n    func load() async -> Int { 1 }\n    func clear() {}\n}\nstruct Disk: Store {\n    func load() -> Int { 2 }\n}\n"])
        let found = findings(m, "conformers")
        let clear = try XCTUnwrap(found.first { $0.message.contains("Store.clear()") })
        XCTAssertEqual(clear.severity, "high")
        XCTAssertTrue(clear.evidence[0].contains("Disk"))
        XCTAssertFalse(clear.evidence[0].contains("Memory"))
        let load = try XCTUnwrap(found.first { $0.message.contains("Store.load()") })
        XCTAssertTrue(load.evidence.contains { $0.contains("Disk.load") })
    }

    func testDefaultImplementationCoversConformers() throws {
        let m = try analyze(
            base: ["Lib/Store.swift": "protocol Store {}\nstruct Disk: Store {}\n"],
            head: ["Lib/Store.swift": "protocol Store {\n    func clear()\n}\nextension Store {\n    func clear() {}\n}\nstruct Disk: Store {}\n"])
        XCTAssertEqual(findings(m, "conformers"), [])
    }

    func testSimilarNames() throws {
        let m = try analyze(
            base: ["Lib/Format.swift": "func formatPrice(_ d: Double) -> String { \"\\(d)\" }\n"],
            head: ["App/App.swift": "func formatPrices(_ d: [Double]) -> [String] { d.map { \"\\($0)\" } }\n"])
        let e = try XCTUnwrap(m.entities.first { $0.qualifiedName == "formatPrices(_:)" })
        XCTAssertEqual(e.similar?.first?.symbol, "formatPrice(_:)")
        XCTAssertEqual(ModelBuilder.nameWords("loadCartItems_v2"), ["load", "cart", "items", "v2"])
    }

    func testIsolationOfCallers() throws {
        let m = try analyze(
            base: ["Lib/Lib.swift": "struct Counter { func tick() {} }\n",
                   "App/App.swift": "@MainActor final class Screen {\n    func tap() { Counter().tick() }\n}\nactor Worker {\n    func work() { Counter().tick() }\n}\n"],
            head: ["Lib/Lib.swift": "struct Counter { func tick() { print(1) } }\n"])
        let e = try XCTUnwrap(m.entities.first { $0.qualifiedName == "Counter.tick()" })
        XCTAssertEqual(Set(e.usedBy.compactMap(\.isolation)), ["@MainActor", "actor Worker"])
        XCTAssertTrue(e.usedBy.allSatisfy { $0.side == nil }, "uses at both sides count as head uses")
    }

    func testRemovedCallersAreMarkedBase() throws {
        let m = try analyze(
            base: ["Lib/Lib.swift": "struct Counter { func tick() {} }\n",
                   "App/App.swift": "func tap() { Counter().tick() }\n",
                   "Jobs/Jobs.swift": "func work() { Counter().tick() }\n"],
            head: ["Lib/Lib.swift": "struct Counter { func tick() { print(1) } }\n",
                   "Jobs/Jobs.swift": "func work() {}\n"])
        let e = try XCTUnwrap(m.entities.first { $0.qualifiedName == "Counter.tick()" })
        XCTAssertEqual(e.usedBy.first { $0.component == "folder:App" }?.side, nil)
        XCTAssertEqual(e.usedBy.first { $0.component == "folder:Jobs" }?.side, .base)
    }
}
