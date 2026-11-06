import XCTest
@testable import ReviewMapCore

final class RustConformanceTests: XCTestCase {
    func testCrossCrateTraitDoesNotMatchUnrelatedNamesake() throws {
        let report = try Fixture.report("rust-conformance-crates")
        let finding = try XCTUnwrap(report.findings.first { $0.kind == "conformers" && $0.message.contains("Service.required()") })
        XCTAssertTrue(finding.message.contains("1 conformer"))
        XCTAssertTrue(finding.evidence.joined().contains("Local"))
        XCTAssertFalse(finding.evidence.joined().contains("Unrelated"))
    }

    func testExplicitImplsDefaultsSignaturesAndBlankets() throws {
        let report = try Fixture.report("rust-conformance")
        let findings = report.findings.filter { $0.kind == "conformers" }
        func finding(_ name: String) throws -> Finding {
            try XCTUnwrap(findings.first { $0.message.contains(name) }, "Missing \(name): \(findings)")
        }
        let missing = try finding("Required.added()")
        XCTAssertTrue(missing.message.contains("1 conformer"))
        XCTAssertTrue(missing.evidence.joined().contains("Missing"))
        XCTAssertFalse(missing.evidence.joined().contains("Complete"))
        XCTAssertFalse(findings.contains { $0.message.contains("defaulted") })
        let changed = try finding("Changed.changed()")
        XCTAssertEqual(changed.severity, "medium")
        XCTAssertTrue(changed.evidence.joined().contains("Missing.changed"))
        XCTAssertFalse(changed.evidence.joined().contains("Complete"))
        let blanket = try finding("Blanket.blanket()")
        XCTAssertTrue(blanket.message.contains("1 conformer"))
        XCTAssertTrue(blanket.evidence.joined().contains("Container<T>"))
        let scoped = try finding("a.Same.scoped()")
        XCTAssertTrue(scoped.message.contains("1 conformer"))
        XCTAssertTrue(scoped.evidence.joined().contains("No scoped in A"))
    }
}
