import Foundation
import XCTest
@testable import ReviewMapCore

final class LanguageTests: XCTestCase {
    private var temporary: [String] = []

    override func tearDown() {
        for path in temporary { try? FileManager.default.removeItem(atPath: path) }
        temporary = []
    }

    func testPublicAPIRulesStayWithEachLanguage() throws {
        let swift = SwiftLanguage()
        let swiftFile = swift.parse(path: "API.swift", source: """
            public struct PublicType {}
            open class OpenType {}
            package struct PackageType {}
            internal struct InternalType {}
            private struct PrivateType {}
            struct InternalOwner { public func exposed() {} }
            """)
        for decl in swiftFile.decls {
            XCTAssertEqual(swift.isPublicAPI(decl, enclosing: swiftFile.enclosingDeclarations(of: decl)),
                           ["PublicType", "OpenType", "PackageType", "exposed"].contains(decl.name), decl.qualifiedName)
        }

        let ts = TypeScriptLanguage()
        let tsFile = ts.parse(path: "api.ts", source: """
            export class Exported {
              public visible() {}
              private hidden() {}
              protected inherited() {}
              implicit() {}
            }
            class Internal { public visible() {} }
            export default class Default { public visible() {} }
            export function named() {}
            function local() {}
            """)
        let publicNames = Set(["Exported", "Exported.visible()", "Exported.implicit()", "named()"])
        for decl in tsFile.decls {
            XCTAssertEqual(ts.isPublicAPI(decl, enclosing: tsFile.enclosingDeclarations(of: decl)),
                           publicNames.contains(decl.qualifiedName), decl.qualifiedName)
        }
    }

    func testLanguageIsolationKeepsInnermostDeclarationRules() {
        let swift = SwiftLanguage()
        let source = """
            @MainActor struct Screen {
              func tap() { action() } // main
              nonisolated func background() { action() } // nonisolated
              @WorkActor func work() { action() } // custom
            }
            actor Worker { func run() { action() } } // actor
            struct Page: View { var body: some View { action() } } // view
            func outside() { action() } // none
            """
        let file = swift.parse(path: "App.swift", source: source)
        for (marker, expected) in [("main", "@MainActor"), ("nonisolated", "nonisolated"), ("custom", "@WorkActor"),
                                   ("actor", "actor Worker"), ("view", "@MainActor"), ("none", nil)] {
            let line = source.components(separatedBy: "\n").firstIndex { $0.hasSuffix("// " + marker) }! + 1
            XCTAssertEqual(swift.isolation(in: file, line: line, source: { XCTFail("Swift isolation needs no source read"); return "" }), expected, marker)
        }
        let ts = TypeScriptLanguage()
        let tsFile = ts.parse(path: "app.ts", source: "function run() { action(); }")
        XCTAssertNil(ts.isolation(in: tsFile, line: 1, source: { XCTFail("Default isolation needs no source read"); return "" }))
        let decoratedSource = """
            @MainActor class Screen {
              tap() { action(); } // main
              @WorkActor work() { action(); } // custom
            }
            class Page implements View { render() { action(); } } // none
            """
        let decorated = ts.parse(path: "screen.ts", source: decoratedSource)
        for (marker, expected) in [("main", "@MainActor"), ("custom", "@WorkActor"), ("none", nil)] {
            let line = decoratedSource.components(separatedBy: "\n").firstIndex { $0.hasSuffix("// " + marker) }! + 1
            XCTAssertEqual(ts.isolation(in: decorated, line: line, source: { XCTFail("Decorator isolation needs no source read"); return "" }), expected, marker)
        }
    }

    func testConformanceHookCanUseBothSidesWithoutHeadDependency() throws {
        let language = HookLanguage()
        var builder = try builder(
            base: ["API/Store.swift": "protocol Store {\n  func load() -> Int\n}\n",
                   "Impl/Store.swift": "struct HiddenConformer {\n  func load() -> Int { 1 }\n  func clear() {}\n}\n",
                   "Unrelated/Other.swift": "struct HiddenConformer {\n  func load() -> Int { 2 }\n}\n"],
            head: ["API/Store.swift": "protocol Store {\n  func load() async -> Int\n  func clear(_ value: Int)\n}\n",
                   "Impl/Store.swift": "struct HiddenConformer {\n  func load() -> Int { 1 }\n  func clear() {}\n}\n",
                   "Unrelated/Other.swift": "struct HiddenConformer {\n  func load() async -> Int { 2 }\n  func clear(_ value: Int) {}\n}\n"], language: language)
        builder.matchEntities()
        builder.resolveReferences()
        let model = finish(builder)
        XCTAssertNil(builder.edgeRefs[.head]?["folder:Impl"]?["folder:API"])
        let findings = model.findings.filter { $0.kind == "conformers" }
        XCTAssertTrue(findings.contains { $0.message.contains("clear") && $0.severity == "high" && $0.evidence.contains { $0.hasPrefix("No clear") } }, "A wrong-arity method and an unrelated type's matching method cannot satisfy the hook's empty result")
        XCTAssertTrue(findings.contains { $0.message.contains("load") && $0.evidence.contains { $0.contains("HiddenConformer") } })
        XCTAssertTrue(model.regions.contains { $0.relation == "conformer" && $0.component == "folder:Impl" && $0.reasons == ["HiddenConformer.load()"] })
        XCTAssertTrue(language.sawBaseInterfaceAndConformer)
        XCTAssertEqual(Set(language.conformanceUses), [.check, .context], "Checks and region context both delegate discovery")
    }

    func testUsageDelegatesIsolationForBothSidesWithAndWithoutIndex() throws {
        for indexed in [false, true] {
            let language = HookLanguage()
            var builder = try builder(
                base: ["Lib/Counter.swift": "struct Counter {\n  func tick() {}\n}\n",
                       "Old/Caller.swift": "// base-block\nfunc old() { Counter().tick() }\n"],
                head: ["Lib/Counter.swift": "struct Counter {\n  func tick() { print(1) }\n}\n",
                       "New/Caller.swift": "// head-block\nfunc new() { Counter().tick() }\n"], language: language)
            if indexed {
                let ref = IndexedRef(line: 2, targetFile: "Lib/Counter.swift", targetLine: 2, name: "tick()")
                builder.addIndex([.base: SideIndex(refs: ["Lib/Counter.swift": [], "Old/Caller.swift": [ref]]),
                                  .head: SideIndex(refs: ["Lib/Counter.swift": [], "New/Caller.swift": [ref]])], language: language)
            }
            builder.matchEntities()
            builder.resolveReferences()
            let model = finish(builder)
            let tick = try XCTUnwrap(model.entities.first { $0.qualifiedName == "Counter.tick()" })
            XCTAssertTrue(tick.usedBy.contains { $0.file == "Old/Caller.swift" && $0.side == .base && $0.isolation == "base-block" }, "indexed: \(indexed)")
            XCTAssertTrue(tick.usedBy.contains { $0.file == "New/Caller.swift" && $0.side == nil && $0.isolation == "head-block" }, "indexed: \(indexed)")
        }
    }

    func testUnusedAPICheckDelegatesPublicClassification() throws {
        let language = HookLanguage()
        var builder = try builder(base: ["Lib/API.swift": "func old() {}\n"],
                                  head: ["Lib/API.swift": "func old() {}\nfunc api() {}\npublic func excluded() {}\n"], language: language)
        builder.matchEntities()
        builder.resolveReferences()
        let unused = finish(builder).findings.filter { $0.kind == "unused-api" }
        XCTAssertEqual(unused.compactMap { $0.anchors.first?.entity }, ["folder:Lib::api()"], "The language hook, rather than Swift access rules, defines public API")
    }

    private func builder(base: [String: String], head: [String: String], language: Language) throws -> ModelBuilder {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-language-\(UUID().uuidString)")
        temporary.append(root)
        let options = AnalyzeOptions(repo: root, base: "base", head: "head")
        let parser = ParseCache()
        var config = Config()
        func side(_ side: Side, _ files: [String: String]) throws -> SideData {
            let dir = root + "/" + side.rawValue
            for (path, text) in files {
                let file = dir + "/" + path
                try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try text.write(toFile: file, atomically: true, encoding: .utf8)
            }
            return try SideData.load(side: side, dir: dir, blobs: files, languages: [language], config: &config, parser: parser, options: options)
        }
        return try ModelBuilder(base: side(.base, base), head: side(.head, head), languages: [language], options: options)
    }

    private func finish(_ builder: ModelBuilder) -> ChangeModel {
        builder.finish(repo: RepoInfo(root: builder.options.repo, base: "base", head: "head", baseSha: "base", headSha: "head", usesMergeBase: false))
    }
}

/// Uses the existing Swift parser and component layout, with deliberately different review semantics.
/// This proves core consumers call the protocol hooks rather than assuming a built-in language.
private final class HookLanguage: Language {
    private let swift = SwiftLanguage()
    var id: String { swift.id }
    var displayName: String { swift.displayName }
    var generatedPatterns: [String] { swift.generatedPatterns }
    var platformModules: Set<String> { swift.platformModules }
    var conformanceUses: [ConformanceUse] = []
    var sawBaseInterfaceAndConformer = false

    func isPublicAPI(_ decl: Decl, enclosing: [Decl]) -> Bool { decl.name == "api" }
    func conformers(of interface: Pair, requirement: Pair?, named name: String, in builder: ModelBuilder, for use: ConformanceUse) -> [Conformer] {
        conformanceUses.append(use)
        if interface.base != nil && builder.pairs.contains(where: { $0.base?.decl.name == "HiddenConformer" && $0.head != nil }) {
            sawBaseInterfaceAndConformer = true
        }
        return builder.pairs.compactMap(\.head).filter { $0.decl.name == "HiddenConformer" && $0.component == "folder:Impl" }.map { candidate in
            // Stand in for a language's method-set matching: clear() has the wrong arity for
            // clear(_ value: Int), while load() is a known implementation in this component.
            let implementations = builder.pairs.compactMap(\.head).filter {
                requirement?.head?.decl.name == "load" && $0.component == candidate.component
                    && $0.decl.scope == candidate.decl.qualifiedName && $0.decl.name == "load"
            }
            return Conformer(declaration: candidate, implementations: implementations)
        }
    }
    func isolation(in file: ParsedFile, line: Int, source: () -> String) -> String? {
        let text = source()
        return text.contains("base-block") ? "base-block" : text.contains("head-block") ? "head-block" : nil
    }
    func isSource(_ path: String) -> Bool { swift.isSource(path) }
    func parse(path: String, source: String) -> ParsedFile { swift.parse(path: path, source: source) }
    func addComponents(root: String, files: [String], options: AnalyzeOptions, layout: inout ComponentLayout) {
        swift.addComponents(root: root, files: files, options: options, layout: &layout)
    }
    func pinnedPackages(blobs: [String: String], dir: String) -> [String: String] { swift.pinnedPackages(blobs: blobs, dir: dir) }
    func package(ofModule module: String, pinned: Set<String>) -> String? { swift.package(ofModule: module, pinned: pinned) }
    func contractFlags(_ builder: ModelBuilder, pairs: [Int]) -> [Int: [String]] { swift.contractFlags(builder, pairs: pairs) }
    func contractFile(_ path: String) -> (key: String, flag: String)? { swift.contractFile(path) }
    func contractFileFlags(key: String, flag: String, basePath: String, headPath: String) -> [String] {
        swift.contractFileFlags(key: key, flag: flag, basePath: basePath, headPath: headPath)
    }
    func settingFlag(_ key: String) -> String { swift.settingFlag(key) }
    func flagRisk(_ flag: String, isInterface: Bool) -> Double { swift.flagRisk(flag, isInterface: isInterface) }
    func isViewCode(_ decl: Decl, inherits: Set<String>) -> Bool { swift.isViewCode(decl, inherits: inherits) }
    func index(options: IndexOptions, repoRoot: String, sides: [IndexSide], log: (String) -> Void) throws -> [Side: SideIndex]? { nil }
}
