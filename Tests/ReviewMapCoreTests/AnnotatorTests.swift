import Foundation
import XCTest
@testable import ReviewMapCore

/// Runs the LLM annotator on the basic fixture with scripts/fake-llm.sh standing in for the CLI.
final class AnnotatorTests: XCTestCase {
    static var repo: String?
    static var plain: ChangeModel?
    var tmp = ""

    static let fake = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../scripts/fake-llm.sh").standardizedFileURL.path

    /// The fixture as a two-commit repo that lives for the whole class, because the annotator reads sources with git show.
    func plainModel() throws -> ChangeModel {
        if let m = Self.plain { return m }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/basic", withExtension: nil)).path
        let repo = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-annotate-\(UUID().uuidString)")
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
        try "Price changes must keep old carts decodable.\n".write(toFile: repo + "/REVIEW.md", atomically: true, encoding: .utf8)
        try git("add", "-A")
        try git("commit", "-qm", "head")
        let m = try Analyzer.run(AnalyzeOptions(repo: repo, base: "base", head: "main"))
        Self.repo = repo
        Self.plain = m
        return m
    }

    override class func tearDown() {
        if let repo { try? FileManager.default.removeItem(atPath: repo) }
        super.tearDown()
    }

    override func setUp() {
        tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-cache-\(UUID().uuidString)")
        unsetenv("FAKE_LLM_MODE")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmp)
        unsetenv("FAKE_LLM_MODE")
    }

    func annotate(_ m: ChangeModel, tool: String = "claude", command: String? = AnnotatorTests.fake) throws -> ChangeModel {
        try Annotator.run(m, options: AnnotateOptions(tool: tool, command: command, cacheDir: tmp, jobs: 2))
    }

    func testAnnotatesEveryRegionEntityAndComponent() throws {
        let plain = try plainModel()
        let m = try annotate(plain)
        let run = try XCTUnwrap(m.llm)
        XCTAssertEqual(run.failed, 0)
        XCTAssertEqual(run.cached, 0)
        XCTAssertTrue(run.reviewNotes, "REVIEW.md at head goes into the prompt")
        XCTAssertGreaterThan(run.batches, 1)

        let lowComponents = Set(m.components.filter(\.isTest).map(\.id))
        let annotatable = Set(m.entities.filter { $0.change != .cosmetic && !lowComponents.contains($0.component) && $0.tags.isEmpty }.map(\.id))
        for e in m.entities {
            XCTAssertEqual(e.llm != nil, annotatable.contains(e.id), e.id)
        }
        for r in m.regions where annotatable.contains(r.entity) {
            let llm = try XCTUnwrap(r.llm, r.id)
            if r.kind == "context" {
                XCTAssertNotNil(llm.keep, r.id)
                XCTAssertNil(llm.risk)
                if llm.keep == true { XCTAssertGreaterThanOrEqual(llm.rank ?? 0, 1) } else { XCTAssertNil(llm.rank) }
            } else {
                XCTAssertTrue((0...1).contains(llm.risk ?? -1), r.id)
                XCTAssertFalse((llm.note ?? "").isEmpty)
            }
        }
        for c in m.components where c.kind != .external && !c.isTest && c.changedEntities > 0 {
            XCTAssertNotNil(c.llm, c.id)
        }
        // Deterministic facts are untouched.
        XCTAssertEqual(m.regions.map(\.risk), plain.regions.map(\.risk))
        XCTAssertEqual(m.entities.map(\.id), plain.entities.map(\.id))
    }

    /// Fixtures/basic/annotated.json: the fixture annotated by the fake CLI, which the viewer tests read.
    func testAnnotatedSnapshot() throws {
        var m = try annotate(try plainModel())
        m.repo.root = "<repo>"
        m.repo.baseSha = "<base>"
        m.repo.headSha = "<head>"
        let actual = try ChangeModelIO.encode(m)
        let snapshot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/basic/annotated.json")
        if ProcessInfo.processInfo.environment["UPDATE_SNAPSHOTS"] == "1" {
            try actual.write(to: snapshot)
            return
        }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/basic", withExtension: nil)).path
        let expected = try Data(contentsOf: URL(fileURLWithPath: fixture + "/annotated.json"))
        if actual != expected {
            let out = (NSTemporaryDirectory() as NSString).appendingPathComponent("annotated-actual.json")
            try actual.write(to: URL(fileURLWithPath: out))
            XCTFail("Annotated snapshot differs. Actual written to \(out). Run with UPDATE_SNAPSHOTS=1 to accept.")
        }
    }

    func testKeptContextIsRankedFromOne() throws {
        let m = try annotate(try plainModel())
        for (_, ctx) in Dictionary(grouping: m.regions.filter { $0.kind == "context" && $0.llm?.keep == true }, by: \.entity) {
            XCTAssertEqual(ctx.compactMap(\.llm?.rank).sorted(), Array(1...ctx.count))
        }
    }

    func testSecondRunComesFromCache() throws {
        let plain = try plainModel()
        let first = try annotate(plain)
        // A command that doesn't exist proves the second run never calls the CLI.
        let second = try annotate(plain, command: "/nonexistent/fake-llm")
        XCTAssertEqual(second.llm?.cached, second.llm?.batches)
        XCTAssertEqual(second.regions, first.regions)
        XCTAssertEqual(second.entities, first.entities)
        XCTAssertEqual(second.components, first.components)
    }

    func testInvalidReplyKeepsDeterministicScores() throws {
        setenv("FAKE_LLM_MODE", "invalid", 1)
        let m = try annotate(try plainModel())
        XCTAssertEqual(m.llm?.failed, m.llm?.batches)
        XCTAssertTrue(m.regions.allSatisfy { $0.llm == nil })
        XCTAssertTrue(m.entities.allSatisfy { $0.llm == nil })
        XCTAssertTrue(m.warnings.contains { $0.kind == "llm-rejected" && $0.message.contains("outside 0...1") })
    }

    func testFailingCLIKeepsDeterministicScores() throws {
        setenv("FAKE_LLM_MODE", "fail", 1)
        let m = try annotate(try plainModel())
        XCTAssertEqual(m.llm?.failed, m.llm?.batches)
        XCTAssertTrue(m.regions.allSatisfy { $0.llm == nil })
    }

    func testProseAroundJSONIsAccepted() throws {
        setenv("FAKE_LLM_MODE", "prose", 1)
        XCTAssertEqual(try annotate(try plainModel()).llm?.failed, 0)
    }

    func testCodex() throws {
        let m = try annotate(try plainModel(), tool: "codex")
        XCTAssertEqual(m.llm?.tool, "codex")
        XCTAssertEqual(m.llm?.failed, 0)
        XCTAssertTrue(m.regions.contains { $0.llm?.risk != nil })
    }

    func testMissingCLISkipsTheAnnotator() throws {
        let m = try annotate(try plainModel(), command: "/nonexistent/claude")
        XCTAssertNil(m.llm)
        XCTAssertTrue(m.warnings.contains { $0.kind == "llm-unavailable" })
    }

    func testCacheInsideTheRepoIsRefused() throws {
        let m = try plainModel()
        let opts = AnnotateOptions(command: Self.fake, cacheDir: Self.repo! + "/.reviewmap/cache")
        XCTAssertThrowsError(try Annotator.run(m, options: opts))
    }

    func testValidation() throws {
        let m = try plainModel()
        let builder = PromptBuilder(model: m, sources: SourceReader(git: GitRepo(root: Self.repo!), baseSha: m.repo.baseSha, headSha: m.repo.headSha), reviewNotes: nil)
        let e = try XCTUnwrap(m.entities.first { $0.qualifiedName == "Cart.add(_:)" })
        let regions = builder.reviewRegions(e.id)
        let context = builder.contextRegions(e.id)
        XCTAssertFalse(regions.isEmpty)
        let good = EntityReply(id: e.id, summary: "Adds an item without checking the quantity.",
                               regions: regions.map { .init(id: $0.id, risk: 0.5, note: "Drops the quantity guard.", removal: nil) },
                               context: context.map { .init(id: $0.id, keep: false, rank: nil) })
        XCTAssertEqual(Annotator.validate(good, against: e, builder: builder), [])

        var missing = good
        missing.regions.removeLast()
        XCTAssertTrue(Annotator.validate(missing, against: e, builder: builder).contains { $0.contains("missing") })

        var unknown = good
        unknown.regions.append(.init(id: e.id + "/r99", risk: 0.1, note: "x", removal: nil))
        XCTAssertTrue(Annotator.validate(unknown, against: e, builder: builder).contains { $0.contains("unknown region") })

        var twoLines = good
        twoLines.summary = "One.\nTwo."
        XCTAssertTrue(Annotator.validate(twoLines, against: e, builder: builder).contains { $0.contains("more than one line") })

        var badKind = good
        badKind.regions[0].removal = RemovalCandidate(kind: "dead", note: "Unused.")
        XCTAssertFalse(Annotator.validate(badKind, against: e, builder: builder).isEmpty)

        if !context.isEmpty {
            var unranked = good
            unranked.context![0].keep = true
            XCTAssertTrue(Annotator.validate(unranked, against: e, builder: builder).contains { $0.contains("needs a rank") })
        }
    }

    func testParseReply() throws {
        let fenced = "Sure.\n```json\n{\"entities\": []}\n```\n"
        guard case .success(let r) = Annotator.parseReply(fenced) else { return XCTFail("fenced reply not parsed") }
        XCTAssertEqual(r.entities.count, 0)
        guard case .failure = Annotator.parseReply("no json here") else { return XCTFail("prose accepted") }
        guard case .failure(let e) = Annotator.parseReply("{\"entities\": [{\"id\": \"a\"}]}") else { return XCTFail("incomplete accepted") }
        XCTAssertTrue(e.message.contains("missing"))
    }

    func testPromptCarriesTheFacts() throws {
        let m = try plainModel()
        let builder = PromptBuilder(model: m, sources: SourceReader(git: GitRepo(root: Self.repo!), baseSha: m.repo.baseSha, headSha: m.repo.headSha), reviewNotes: "Keep carts decodable.")
        let e = try XCTUnwrap(m.entities.first { $0.qualifiedName == "Cart.add(_:)" })
        let comp = try XCTUnwrap(m.components.first { $0.id == e.component })
        let block = builder.entityBlock(e)
        XCTAssertTrue(block.contains("Head code"))
        XCTAssertTrue(block.contains("Base code"))
        XCTAssertTrue(block.contains("guard"), "the removed guard is in the base code")
        let batch = Batch(component: comp, entities: [e], blocks: [block], wantsSummary: true, part: 1, parts: 1, entityKeys: [:], componentKey: "")
        let prompt = builder.prompt(batch)
        XCTAssertTrue(prompt.contains("Keep carts decodable."))
        XCTAssertTrue(prompt.contains("<reply-template>"))
        // The template alone parses once its placeholders are filled.
        let template = builder.template(batch).replacingOccurrences(of: "\"risk\": null", with: "\"risk\": 0.5")
            .replacingOccurrences(of: "\"keep\": null", with: "\"keep\": false")
        guard case .success(let r) = Annotator.parseReply(template) else { return XCTFail("template is not valid JSON") }
        XCTAssertEqual(r.entities.map(\.id), [e.id])
    }
}
