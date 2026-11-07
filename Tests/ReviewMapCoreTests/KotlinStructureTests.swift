import Foundation
import XCTest
@testable import ReviewMapCore

final class KotlinStructureTests: XCTestCase {
    func testInnermostDispatcherOverridesDeclarationIsolation() throws {
        let source = """
            @MainThread
            fun show() {
                mainBefore()
                withContext(Dispatchers.IO) {
                    io()
                    launch(Dispatchers.Main.immediate) {
                        mainNested()
                        async(Dispatchers.Default) {
                            defaultNested()
                        }
                        mainAgain()
                    }
                    ioAgain()
                }
                mainAfter()
            }
            """
        let file = KotlinLanguage().parse(path: "Ui.kt", source: source)
        let lines = source.components(separatedBy: "\n")
        func isolation(_ name: String) throws -> String? {
            let line = try XCTUnwrap(lines.firstIndex { $0.contains(name + "()") }) + 1
            return KotlinLanguage().isolation(in: file, line: line)
        }
        for name in ["mainBefore", "mainNested", "mainAgain", "mainAfter"] { XCTAssertEqual(try isolation(name), "main thread", name) }
        for name in ["io", "defaultNested", "ioAgain"] { XCTAssertNil(try isolation(name), name) }
        XCTAssertEqual(file.isolationRegions.count, 3)
    }

    func testAnnotationsUIClassesAndNamedBlockArguments() throws {
        let source = """
            @UiThread
            fun annotated() {
                annotatedCall()
            }
            class Screen : Activity() {
                fun show() {
                    uiCall()
                    withContext(Dispatchers.IO, block = {
                        backgroundCall()
                    })
                }
            }
            class Worker {
                fun work() {
                    ordinaryCall()
                }
            }
            """
        let file = KotlinLanguage().parse(path: "Ui.kt", source: source)
        let lines = source.components(separatedBy: "\n")
        for (name, expected) in [("annotatedCall", "main thread"), ("uiCall", "main thread"), ("backgroundCall", nil), ("ordinaryCall", nil)] {
            let line = try XCTUnwrap(lines.firstIndex { $0.contains(name + "()") }) + 1
            XCTAssertEqual(KotlinLanguage().isolation(in: file, line: line), expected)
        }
    }

    func testDefaultsAndAbstractClassRequirements() throws {
        let file = KotlinLanguage().parse(path: "Api.kt", source: """
            interface Api {
                fun required()
                fun defaultFunction() = 1
                val requiredProperty: Int
                val defaultProperty: Int get() = 1
            }
            abstract class Base {
                abstract fun required()
            }
            """)
        for name in ["required", "requiredProperty"] {
            XCTAssertTrue(try XCTUnwrap(file.decls.first { $0.scope == "Api" && $0.name == name }).inProtocol)
        }
        for name in ["defaultFunction", "defaultProperty"] {
            XCTAssertFalse(try XCTUnwrap(file.decls.first { $0.scope == "Api" && $0.name == name }).inProtocol)
        }
        XCTAssertTrue(try XCTUnwrap(file.decls.first { $0.scope == "Base" && $0.name == "required" }).modifiers.contains("abstract"))
        let report = try Fixture.report("kotlin-structure")
        let findings = report.findings.filter { $0.kind == "conformers" }
        XCTAssertTrue(findings.contains { $0.evidence.joined().contains("Broken") && $0.evidence.joined().contains("clear") })
        XCTAssertTrue(findings.contains { $0.evidence.joined().contains("BrokenAbstract") && $0.evidence.joined().contains("reset") })
        XCTAssertFalse(findings.contains { $0.evidence.joined().contains("DefaultUser") })
    }

    func testConformersRespectPackagesAliasesAndActualMembers() throws {
        let report = try Fixture.report("kotlin-structure")
        let requirement = try XCTUnwrap(report.reviewItems.first { $0.qualifiedName == "Api.clear()" && $0.location.file.contains("/a/") })
        let finding = try XCTUnwrap(report.findings.first { $0.kind == "conformers" && $0.anchors.contains { $0.reviewItem == requirement.id } })
        XCTAssertTrue(finding.message.contains("2 conformers"), finding.message)
        XCTAssertTrue(finding.evidence.joined().contains("Impl"))
        XCTAssertTrue(finding.evidence.joined().contains("Aliased"))
        XCTAssertFalse(finding.evidence.joined().contains("Other"), "the other package's Api is a different interface")
        XCTAssertFalse(finding.evidence.joined().contains("Outer.Impl"), "an enclosing interface shadows a package-level type")
        let nested = try XCTUnwrap(report.findings.first { $0.kind == "conformers" && $0.message.contains("Outer.Api.nestedClear") })
        XCTAssertTrue(nested.evidence.joined().contains("Outer.Impl"))
    }

    func testRemovingDefaultImplementationCreatesARequirement() throws {
        let report = try Fixture.report("kotlin-structure")
        for (member, conformer) in [("LosesDefault.refresh()", "NeedsDefault"), ("LosesImplementation.reset()", "NeedsImplementation")] {
            let item = try XCTUnwrap(report.reviewItems.first { $0.qualifiedName == member })
            XCTAssertTrue(item.changes.contains(.body))
            let finding = try XCTUnwrap(report.findings.first { $0.kind == "conformers" && $0.anchors.contains { $0.reviewItem == item.id } })
            XCTAssertTrue(finding.message.hasPrefix("New requirement"))
            XCTAssertTrue(finding.evidence.joined().contains(conformer))
        }
        let interfaceMember = try XCTUnwrap(report.reviewItems.first { $0.qualifiedName == "LosesDefault.refresh()" })
        XCTAssertTrue(interfaceMember.contractFlags.contains("kotlin:interface-member-changed"))
        XCTAssertFalse(interfaceMember.contractFlags.contains("kotlin:final-removed"), "interface default members are implicitly open")
    }

    func testUsageIsolationReachesStructuralPrompt() throws {
        let report = try Fixture.report("kotlin-structure")
        let load = try XCTUnwrap(report.reviewItems.first { $0.qualifiedName == "load()" })
        XCTAssertTrue(load.usedBy.contains { $0.side != .base && $0.symbol == "refresh()" && $0.isolation == "main thread" }, "\(load.usedBy)")
        let repo = try Fixture.repo("kotlin-structure")
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let head = try String(contentsOfFile: join(repo, "app/src/main/kotlin/Screen.kt"), encoding: .utf8)
        let lines = head.components(separatedBy: "\n")
        let ioLine = try XCTUnwrap(lines.firstIndex { $0.contains("withContext(Dispatchers.IO)") }) + 2
        XCTAssertTrue(load.usedBy.contains { $0.side != .base && $0.line == ioLine && $0.isolation == nil }, "\(load.usedBy)")
        let sources = SourceReader(git: GitRepo(root: repo), baseSha: "base", headSha: "main")
        let review = StructuralReview(report: report, sources: sources, reviewNotes: nil,
                                      description: ChangeDescription(text: "Update the API and screen.", source: "commits"))
        XCTAssertTrue(try XCTUnwrap(review.prompt()).contains("main thread"))
    }

    func testComposableControlFlowIsViewCode() throws {
        let report = try Fixture.report("kotlin-structure")
        let panel = try XCTUnwrap(report.reviewItems.first { $0.qualifiedName == "Panel()" })
        let ordinary = try XCTUnwrap(report.reviewItems.first { $0.qualifiedName == "ordinary()" })
        let panelReasons = report.regions.filter { $0.reviewItem == panel.id }.flatMap(\.reasons)
        let ordinaryReasons = report.regions.filter { $0.reviewItem == ordinary.id }.flatMap(\.reasons)
        XCTAssertTrue(panelReasons.contains { $0.hasPrefix("view control flow:") })
        XCTAssertFalse(panelReasons.contains { $0.hasPrefix("control flow:") })
        XCTAssertTrue(ordinaryReasons.contains { $0.hasPrefix("control flow:") })
    }
}
