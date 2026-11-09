import Foundation
import XCTest
@testable import ReviewMapCore

/// Which commits a change compares (CORE-001), and that analyzing it leaves the reviewed repo as it was (CORE-002).
final class RepoBoundaryTests: XCTestCase {
    var repo = ""

    /// `main` gets `Main.swift` after `feature` branched off, so `main` has moved on since the branch point.
    override func setUpWithError() throws {
        repo = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-boundary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try write("Lib/Shared.swift", "struct Shared {}\n")
        try git("init", "-q", "-b", "main")
        try git("add", "-A")
        try git("commit", "-qm", "shared")
        try git("checkout", "-qb", "feature")
        try write("Lib/Feature.swift", "struct Feature {}\n")
        try git("add", "-A")
        try git("commit", "-qm", "feature")
        try git("checkout", "-q", "main")
        try write("Lib/Main.swift", "struct OnlyOnMain {}\n")
        try git("add", "-A")
        try git("commit", "-qm", "main moves on")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: repo)
    }

    func git(_ args: String...) throws {
        try Shell.run(["git", "-C", repo, "-c", "user.email=fixture@example.com", "-c", "user.name=fixture"] + args)
    }

    func sha(_ ref: String) throws -> String {
        try Shell.string(["git", "-C", repo, "rev-parse", ref])
    }

    func write(_ path: String, _ text: String) throws {
        let full = repo + "/" + path
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: full, atomically: true, encoding: .utf8)
    }

    func names(_ m: ChangeReport) -> [String: ChangeKind] {
        Dictionary(uniqueKeysWithValues: m.reviewItems.map { ($0.qualifiedName, $0.change) })
    }

    func testBaseIsTheMergeBase() throws {
        let m = try Analyzer.run(AnalyzeOptions(repo: repo, base: "main", head: "feature"))
        XCTAssertTrue(m.repo.usesMergeBase)
        XCTAssertEqual(m.repo.baseSha, try sha("main~1"), "the branch point, not the tip of main")
        XCTAssertEqual(m.repo.headSha, try sha("feature"))
        XCTAssertEqual(names(m)["Feature"], .added)
        XCTAssertNil(names(m)["OnlyOnMain"], "main's later commit is not shown as the branch removing it")
    }

    func testNoMergeBaseComparesAgainstBaseDirectly() throws {
        let m = try Analyzer.run(AnalyzeOptions(repo: repo, base: "main", head: "feature", useMergeBase: false))
        XCTAssertFalse(m.repo.usesMergeBase)
        XCTAssertEqual(m.repo.baseSha, try sha("main"))
        XCTAssertEqual(names(m)["Feature"], .added)
        XCTAssertEqual(names(m)["OnlyOnMain"], .removed)
    }

    /// Every file under the repo, `.git` included, with its size and modification date.
    func snapshot() throws -> [String: String] {
        let fm = FileManager.default
        var out: [String: String] = [:]
        let e = try XCTUnwrap(fm.enumerator(atPath: repo))
        while let path = e.nextObject() as? String {
            let a = try fm.attributesOfItem(atPath: repo + "/" + path)
            out[path] = "\(a[.size] ?? "") \((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }
        return out
    }

    func testAnalysisLeavesTheRepoUntouched() throws {
        try git("checkout", "-q", "feature")
        try write("Lib/Uncommitted.swift", "struct Uncommitted {}\n")
        let before = try snapshot()
        let m = try Analyzer.run(AnalyzeOptions(repo: repo, base: "main", head: "feature"))
        XCTAssertEqual(names(m)["Feature"], .added)
        XCTAssertNil(names(m)["Uncommitted"], "only committed trees are analyzed")
        XCTAssertEqual(try snapshot(), before)
    }
}
