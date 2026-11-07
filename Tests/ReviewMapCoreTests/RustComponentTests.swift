import Foundation
import XCTest
@testable import ReviewMapCore

final class RustComponentTests: XCTestCase {
    func testWorkspaceComponentsPinsAndEdges() throws {
        let report = try Fixture.report("rust-components")
        let components = Dictionary(uniqueKeysWithValues: report.components.map { ($0.id, $0) })
        XCTAssertEqual(components["cargo:my-store"]?.kind, .cargoCrate)
        XCTAssertEqual(components["cargo:my-store"]?.module, "my_store")
        XCTAssertNotNil(components["cargo:app:lib:app"])
        XCTAssertNotNil(components["cargo:app:bin:app"])
        XCTAssertNotNil(components["cargo:app:tests"])
        let fixtureRoot = try Fixture.path("rust-components") + "/head"
        var layout = ComponentLayout()
        RustComponents.add(root: fixtureRoot, files: ComponentBuilder.findFiles(root: fixtureRoot, where: { $0.hasSuffix(".rs") }), layout: &layout)
        XCTAssertEqual(layout.fileComponent["crates/app/src/cli.rs"], "cargo:app:bin:app")
        XCTAssertNil(layout.fileComponent["crates/ignored/src/lib.rs"])
        XCTAssertTrue(report.edges.contains { $0.from == "cargo:app:tests" && $0.to == "ext:serde" })
        XCTAssertNil(components["cargo:ignored"])
        XCTAssertFalse(report.components.filter { $0.kind == .cargoCrate }.flatMap(\.paths).contains("crates/ignored/src/lib.rs"))
        XCTAssertTrue(report.edges.contains { $0.from == "cargo:app:lib:app" && $0.to == "cargo:my-store" })
        XCTAssertTrue(report.edges.contains { $0.from == "cargo:app:bin:app" && $0.to == "cargo:app:lib:app" })
        XCTAssertTrue(report.edges.contains { $0.from == "cargo:my-store" && $0.to == "ext:serde" })
        XCTAssertTrue(report.externalDeps.contains { $0.name == "serde" && $0.from == "1.0.200" && $0.to == "1.0.201" })
        XCTAssertFalse(report.externalDeps.contains { $0.name == "unlisted" })
        let test = try XCTUnwrap(report.reviewItems.first { $0.qualifiedName == "tests.checks_value()" })
        XCTAssertEqual(test.component, "cargo:my-store")
        XCTAssertTrue(test.tags.contains("test"))
    }

    func testManifestTargetsSettingsAndInheritance() throws {
        let value = try TOMLValue("""
        [package]
        name = "demo"
        edition.workspace = true
        rust-version = "1.80"
        autobins = false
        [lib]
        name = "demo_core"
        path = "code/core.rs"
        [[bin]]
        name = "tool"
        path = "tools/main.rs"
        [dev-dependencies]
        renamed = { workspace = true }
        [features]
        extra = []
        """)
        let workspace = try TOMLValue("""
        [workspace.package]
        edition = "2024"
        [workspace.dependencies]
        renamed = { package = "real-package", version = "1" }
        [profile.release]
        lto = true
        """)
        let crate = RustComponents.Crate(manifest: "Cargo.toml", value: value, workspace: workspace, workspaceDir: "")
        let targets = RustComponents.targets(crate, files: ["code/core.rs", "tools/main.rs", "src/bin/ignored.rs"])
        XCTAssertEqual(targets.map(\.name), ["demo_core", "tool"])
        XCTAssertEqual(crate.dependencies["renamed"]?["package"]?.string, "real-package")
        XCTAssertTrue(crate.inheritsDependency("renamed"))
        XCTAssertEqual(RustComponents.settings(crate)["Cargo.toml edition"], "\"2024\"")
        XCTAssertEqual(RustComponents.settings(crate)["Cargo.toml profile"], "release=lto=true")
    }

    func testBinaryNamesDoNotShadowExternalDependencies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        [package]
        name = "benchmarks"
        version = "0.1.0"
        [[bin]]
        name = "atomicring"
        path = "atomicring.rs"
        [[bin]]
        name = "bus"
        path = "bus.rs"
        [dependencies]
        atomicring = "1.2.9"
        """.write(to: root.appendingPathComponent("Cargo.toml"), atomically: true, encoding: .utf8)
        for file in ["atomicring.rs", "bus.rs"] {
            try "fn main() {}".write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        var layout = ComponentLayout()
        RustComponents.add(root: root.path, files: ["atomicring.rs", "bus.rs"], layout: &layout)
        XCTAssertNil(layout.moduleComponent["atomicring"])
        XCTAssertNil(layout.moduleComponent["benchmarks"])
        XCTAssertEqual(layout.externalProducts["atomicring"], "atomicring")
        XCTAssertEqual(layout.fileComponent["bus.rs"], "cargo:benchmarks:bin:bus")
    }

    func testTargetOwnershipAndReferencesFollowTheSameModuleFiles() throws {
        let sources = [
            "src/main.rs": #"mod outer; mod inline { mod child; #[path="actual.rs"] mod renamed; use self::renamed::Custom; } use outer::nested::Item;"#,
            "src/outer.rs": #"mod nested; #[path="special.rs"] mod chosen; use self::chosen::Other;"#,
            "src/outer/nested.rs": "pub struct Item;",
            "src/special.rs": "pub struct Other;",
            "src/inline/child/mod.rs": "pub struct Child;",
            "src/inline/actual.rs": "pub struct Custom;"
        ]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, source) in sources {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try source.write(to: url, atomically: true, encoding: .utf8)
        }
        var parsed: [String: ParsedFile] = [:]
        let owned = RustComponents.sourceFiles(target: .init(name: "app", path: "src/main.rs", library: false),
                                               root: root.path, files: Set(sources.keys), parsed: &parsed)
        XCTAssertEqual(owned, Set(sources.keys))
        RustModules.resolve(&parsed)
        XCTAssertTrue(parsed["src/main.rs"]!.typeRefs.contains { $0.name == "Custom" && $0.source == "/src/inline/actual" })
        XCTAssertTrue(parsed["src/main.rs"]!.typeRefs.contains { $0.name == "Item" && $0.source == "/src/outer/nested" })
        XCTAssertTrue(parsed["src/outer.rs"]!.typeRefs.contains { $0.name == "Other" && $0.source == "/src/special" })
    }

    private func TOMLValue(_ source: String) throws -> RustComponents.Value {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try source.write(to: dir, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try XCTUnwrap(RustComponents.read(dir.path))
    }
}
