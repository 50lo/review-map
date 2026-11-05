import Foundation
import XCTest
@testable import ReviewMapCore

/// Builds a two-commit git repo from Fixtures/<name>/{base,head}, runs the analyzer, and
/// compares the change model with Fixtures/<name>/expected.json.
/// Set UPDATE_SNAPSHOTS=1 to rewrite the snapshot.
final class FixtureTests: XCTestCase {
    func model(_ name: String) throws -> ChangeModel {
        try Fixture.model(name)
    }

    func entity(_ m: ChangeModel, _ qualifiedName: String, file: StaticString = #filePath, line: UInt = #line) throws -> Entity {
        try XCTUnwrap(m.entities.first { $0.qualifiedName == qualifiedName }, "no entity \(qualifiedName)", file: file, line: line)
    }

    func testSnapshot() throws {
        try Fixture.checkSnapshot("basic")
    }

    func testProtocolRequirements() throws {
        let m = try model("basic")
        XCTAssertEqual(try entity(m, "CartRepository.clear()").contractFlags, ["swift:protocol-requirement-added"])
        XCTAssertEqual(try entity(m, "CartRepository.items()").contractFlags, ["swift:async-added", "swift:protocol-requirement-changed"])
        let proto = try entity(m, "CartRepository")
        XCTAssertTrue(proto.contractFlags.contains("swift:protocol-requirement-added"))
        XCTAssertTrue(proto.isInterface)
    }

    func testDependencyEdges() throws {
        let m = try model("basic")
        let added = m.edges.first { $0.from == "spm:Features/Checkout" && $0.to == "spm:Networking" }
        XCTAssertEqual(added?.status, .added)
        XCTAssertEqual(added?.symbolsAdded.contains("PaymentClient"), true)
        let removed = m.edges.first { $0.from == "spm:Features/Checkout" && $0.to == "spm:Persistence" }
        XCTAssertEqual(removed?.status, .removed)
        XCTAssertEqual(m.edges.first { $0.from == "spm:Features" && $0.to == "spm:Networking" }?.status, .added,
                       "manifest dependency edge")
        XCTAssertEqual(m.edges.first { $0.to == "ext:swift-collections" }?.status, .unchanged)
    }

    func testConcurrency() throws {
        let m = try model("basic")
        XCTAssertTrue(try entity(m, "CheckoutViewModel").contractFlags.contains("swift:mainactor-added"))
        XCTAssertEqual(try entity(m, "CheckoutViewModel.refresh()").contractFlags, ["swift:nonisolated-removed"])
        XCTAssertEqual(try entity(m, "PriceCache").contractFlags, ["swift:kind-changed:class->actor"])
    }

    func testCodableShape() throws {
        let m = try model("basic")
        XCTAssertEqual(try entity(m, "Item.price").contractFlags, ["swift:codable-shape"])
        XCTAssertEqual(try entity(m, "Item.currency").change, .added)
        XCTAssertTrue(try entity(m, "Item").contractFlags.contains("swift:codable-shape"))
        XCTAssertTrue(try entity(m, "Item.CodingKeys.currency").contractFlags.contains("swift:codable-shape"))
    }

    func testBodyAccessCosmeticAndOverloads() throws {
        let m = try model("basic")
        XCTAssertEqual(try entity(m, "Cart.add(_:)").change, .body, "removed guard is a body change")
        XCTAssertEqual(try entity(m, "Cart.format(_:)").contractFlags, ["swift:access-changed:internal->public"])
        XCTAssertEqual(try entity(m, "CatalogView.title()").change, .cosmetic)
        let prices = m.entities.filter { $0.qualifiedName == "Cart.price(for:)" }
        XCTAssertEqual(prices.count, 1, "only the changed overload is reported")
        XCTAssertEqual(prices.first?.signature.head, "func price(for item: Item) -> Decimal")
    }

    func testEnumModelObservable() throws {
        let m = try model("basic")
        XCTAssertEqual(try entity(m, "PaymentMethod.applePay").contractFlags, ["swift:enum-case-added"])
        XCTAssertTrue(try entity(m, "PaymentMethod").contractFlags.contains("swift:enum-case-added"))
        XCTAssertEqual(try entity(m, "Order.placedAt").contractFlags, ["swift:swiftdata-model-changed"])
        XCTAssertTrue(try entity(m, "Order").contractFlags.contains("swift:swiftdata-model-changed"))
        XCTAssertEqual(try entity(m, "CheckoutViewModel.total").contractFlags, ["swift:observable-state-changed"])
        XCTAssertEqual(try entity(m, "CheckoutViewModel.client").contractFlags, [], "not @Published")
        XCTAssertEqual(try entity(m, "PaymentClient.charge(_:method:)").contractFlags,
                       ["swift:access-changed:internal->public", "swift:typed-throws-changed"])
    }

    func testNonCodeContractsAndPackages() throws {
        let m = try model("basic")
        XCTAssertEqual(try entity(m, "App/Info.plist").contractFlags, ["swift:info-plist-changed", "swift:url-schemes-changed"])
        XCTAssertEqual(try entity(m, "App/Shop.entitlements").change, .added)
        XCTAssertEqual(m.externalDeps, [ExternalDepChange(name: "swift-collections", change: "bumped", from: "1.1.0", to: "1.2.0")])
    }

    func testBuildSettingsAndConformanceMoves() throws {
        let m = try model("basic")
        let settings = try entity(m, "Features build settings")
        XCTAssertEqual(settings.kind, .target)
        XCTAssertEqual(settings.contractFlags, ["swift:default-isolation-changed"])
        XCTAssertEqual(settings.signature.head, "swiftSettings: .defaultIsolation(MainActor.self)")
        XCTAssertFalse(m.entities.contains { $0.qualifiedName == "Banner" }, "conformance moved to an extension is not a change")
        let ext = try entity(m, "extension Banner: Hashable")
        XCTAssertEqual(ext.change, .added)
        XCTAssertEqual(ext.contractFlags, [])
    }

    func testComponentsAndWarnings() throws {
        let m = try model("basic")
        let ids = Set(m.components.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["cfg:Core", "spm:Features", "spm:Features/Checkout", "spm:Features/Catalog", "spm:Networking"]))
        XCTAssertFalse(ids.contains("spm:Core"), "config rule took over the Core module")
        XCTAssertEqual(m.components.first { $0.id == "cfg:Core" }?.layer, "domain")
        XCTAssertEqual(m.components.first { $0.id == "spm:Features/Checkout" }?.parent, "spm:Features")
        XCTAssertTrue(m.warnings.contains { $0.kind == "ambiguous-name" && $0.message.hasPrefix("Logger ") })
        XCTAssertFalse(m.entities.contains { $0.location.file == "Package.swift" && $0.kind != .target })
    }

    func regions(_ m: ChangeModel, _ qualifiedName: String, kind: String? = nil) throws -> [Region] {
        let e = try entity(m, qualifiedName)
        return m.regions.filter { $0.entity == e.id && (kind == nil || $0.kind == kind) }
    }

    func testReviewRegions() throws {
        let m = try model("basic")
        XCTAssertEqual(Set(m.regions.map(\.id)).count, m.regions.count, "region ids are unique")
        let removed = try regions(m, "Cart.add(_:)", kind: "removed")
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed.first?.side, .base)
        XCTAssertEqual(removed.first?.anchor, 7, "the guard sat after the declaration line")
        XCTAssertTrue(removed.first?.reasons.contains { $0.contains("guard removed") } ?? false)
        XCTAssertGreaterThanOrEqual(removed.first?.risk ?? 0, 0.6)

        let first = try regions(m, "Cart.first()", kind: "review")
        XCTAssertEqual(first.map { [$0.startLine, $0.endLine] }, [[15, 17]])
        XCTAssertTrue(first[0].reasons.contains("new force unwrap"))

        let refresh = try regions(m, "CheckoutViewModel.refresh()", kind: "review")
        XCTAssertEqual(refresh.first?.reasons.first, "swift:nonisolated-removed")
        XCTAssertGreaterThanOrEqual(refresh.first?.risk ?? 0, 0.6)

        let send = try regions(m, "Transport.send(_:)", kind: "review")
        XCTAssertEqual(send.map { [$0.startLine, $0.endLine] }, [[18, 19]])
        XCTAssertTrue(send[0].reasons.contains { $0.hasPrefix("control flow: ") })

        let item = try regions(m, "Item", kind: "review")
        XCTAssertEqual(item.map(\.startLine), [3], "flags from members sit on the declaration line")
        XCTAssertTrue(item[0].reasons.contains("swift:codable-shape"))

        XCTAssertTrue(try regions(m, "CatalogView.title()").isEmpty, "cosmetic changes have no regions")
        let testIds = Set(m.entities.filter { $0.tags.contains("test") }.map(\.id))
        let test = m.regions.filter { testIds.contains($0.entity) }
        XCTAssertTrue(test.allSatisfy { $0.kind != "context" && $0.risk < 0.2 }, "test code ranks low and gets no context")
    }

    func testContextRegions() throws {
        let m = try model("basic")
        let ids = Set(m.regions.map(\.id))
        for r in m.regions where r.kind == "context" {
            XCTAssertFalse(r.supports?.isEmpty ?? true, "\(r.id) supports a review region")
            XCTAssertTrue(r.supports!.allSatisfy(ids.contains))
        }
        let total = try regions(m, "Cart.total()", kind: "context")
        XCTAssertTrue(total.contains { $0.relation == "definition" && $0.reasons == ["rounded(_:)"] })
        XCTAssertTrue(total.contains { $0.relation == "caller" && $0.reasons == ["CheckoutViewModel.refresh()"] && $0.component == "spm:Features/Checkout" })
        let add = try regions(m, "Cart.add(_:)", kind: "context")
        let state = try XCTUnwrap(add.first { $0.relation == "state" })
        XCTAssertEqual(state.lines, [2, 3])
        XCTAssertTrue(try regions(m, "CartRepository.items()", kind: "context").contains { $0.relation == "conformer" && $0.reasons == ["CartStore.items()"] })
        XCTAssertTrue(try regions(m, "Transport.send(_:)", kind: "context").contains { $0.relation == "override" && $0.reasons == ["LoggingTransport.send(_:)"] })
    }
}

/// Builds a two-commit git repo from Fixtures/<name>/{base,head} and runs the analyzer on it, once per fixture.
enum Fixture {
    nonisolated(unsafe) static var cached: [String: ChangeModel] = [:]

    static func path(_ name: String) throws -> String {
        try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)).path
    }

    /// A temporary repo with the fixture's base on branch `base` and its head on `main`. The caller removes it.
    static func repo(_ name: String) throws -> String {
        let fixture = try path(name)
        let repo = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-fixture-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        func git(_ args: String...) throws {
            try Shell.run(["git", "-C", repo, "-c", "user.email=fixture@example.com", "-c", "user.name=fixture"] + args)
        }
        func copyTree(_ side: String) throws {
            for item in try fm.contentsOfDirectory(atPath: repo) where item != ".git" {
                try fm.removeItem(atPath: repo + "/" + item)
            }
            let src = fixture + "/" + side
            for item in try fm.contentsOfDirectory(atPath: src) {
                try fm.copyItem(atPath: src + "/" + item, toPath: repo + "/" + item)
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
        return repo
    }

    static func model(_ name: String) throws -> ChangeModel {
        if let m = cached[name] { return m }
        let repo = try repo(name)
        defer { try? FileManager.default.removeItem(atPath: repo) }
        var m = try Analyzer.run(AnalyzeOptions(repo: repo, base: "base", head: "main"))
        m.repo.root = "<repo>"
        m.repo.baseSha = "<base>"
        m.repo.headSha = "<head>"
        cached[name] = m
        return m
    }

    /// Compares the model with Fixtures/<name>/expected.json; UPDATE_SNAPSHOTS=1 rewrites it.
    static func checkSnapshot(_ name: String, sourceFile: String = #filePath) throws {
        let actual = try ChangeModelIO.encode(try model(name))
        // Write to the source tree, not the copied bundle.
        let sourceSnapshot = URL(fileURLWithPath: sourceFile).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)/expected.json")
        if ProcessInfo.processInfo.environment["UPDATE_SNAPSHOTS"] == "1" {
            try actual.write(to: sourceSnapshot)
            return
        }
        let expected = try Data(contentsOf: URL(fileURLWithPath: try path(name) + "/expected.json"))
        if actual != expected {
            let out = (NSTemporaryDirectory() as NSString).appendingPathComponent("\(name)-actual.json")
            try actual.write(to: URL(fileURLWithPath: out))
            XCTFail("Snapshot differs. Actual written to \(out). Run with UPDATE_SNAPSHOTS=1 to accept.")
        }
    }
}
