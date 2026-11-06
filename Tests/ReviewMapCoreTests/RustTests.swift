import Foundation
import XCTest
@testable import ReviewMapCore

final class RustTests: XCTestCase {
    func testDeclarationsAndPrivacy() throws {
        let file = RustExtractor.parse(path: "src/lib.rs", source: """
        pub mod api {
            #[derive(Clone, serde::Serialize)]
            pub struct Item { pub value: i32, hidden: bool }
            pub enum Choice { A, B(i32) }
            pub union Bits { pub n: u32, pub f: f32 }
            pub trait Store { type Value; const SIZE: usize; fn get(&self) -> i32; fn defaulted(&self) {} }
            impl Store for Item { type Value = i32; const SIZE: usize = 1; fn get(&self) -> i32 { 1 } }
            pub async unsafe fn load() {}
            pub const fn size() -> usize { 1 }
            pub(crate) static COUNT: usize = 0;
            pub(super) type Id = u64;
            macro_rules! one { () => { 1 }; }
        }
        mod hidden { pub struct Secret; }
        """)
        func decl(_ name: String) throws -> Declaration { try XCTUnwrap(file.decls.first { $0.qualifiedName == name }) }
        XCTAssertEqual(try decl("api.Item").attributes, ["derive(Clone, serde::Serialize)"])
        XCTAssertEqual(try decl("api.Choice.A").kind, .case)
        XCTAssertTrue(try decl("api.Bits").traits.contains("union"))
        XCTAssertTrue(try decl("api.Store.get()").inProtocol)
        XCTAssertTrue(try decl("api.Store.defaulted()").traits.contains("default-implementation"))
        XCTAssertEqual(try decl("api.load()").modifiers, ["async", "unsafe"])
        XCTAssertEqual(try decl("api.size()").modifiers, ["const"])
        XCTAssertEqual(try decl("api.COUNT").access, "internal")
        XCTAssertEqual(try decl("api.Id").access, "fileprivate")
        XCTAssertTrue(try decl("api.one()").traits.contains("macro"))
        let language = RustLanguage()
        for (name, expected) in [("api.Item", true), ("api.Item.value", true), ("api.Item.hidden", false), ("hidden.Secret", false)] {
            let d = try decl(name)
            XCTAssertEqual(language.isPublicAPI(d, enclosing: file.enclosingDeclarations(of: d)), expected, name)
        }
    }

    func testModuleTreeAliasesGlobsAndPaths() throws {
        let sources = [
            "src/lib.rs": "pub mod model; #[path = \"other.rs\"] mod special; mod inline { use crate::model::{Thing as Alias}; fn f() { Alias::new(); } }",
            "src/model/mod.rs": "pub struct Thing; mod child;",
            "src/model/child.rs": "use super::Thing; use crate::special::*; use std::collections::HashMap; fn f() { Thing::new(); Extra::new(); HashMap::new(); }",
            "src/other.rs": "pub struct Extra;"
        ]
        var files = sources.mapValues { RustExtractor.parse(path: "unused.rs", source: $0) }
        for path in files.keys { files[path]?.path = path }
        RustModules.resolve(&files)
        XCTAssertTrue(files["src/lib.rs"]!.typeRefs.contains { $0.name == "new" && $0.source == "/src/model/mod" })
        XCTAssertTrue(files["src/model/child.rs"]!.typeRefs.contains { $0.name == "Thing" && $0.source == "/src/model/mod" })
        XCTAssertTrue(files["src/model/child.rs"]!.typeRefs.contains { $0.name == "Extra" && $0.source == "/src/other" })
        XCTAssertTrue(files["src/model/child.rs"]!.imports.contains { $0.name == "std" })
    }

    func testScopedImportsAndExternalPaths() throws {
        var files = ["src/lib.rs": RustExtractor.parse(path: "src/lib.rs", source: """
        mod model { pub struct Thing; }
        mod inline {
            use std::collections::HashMap;
            fn a() { use crate::model::Thing as Alias; Alias::new(); }
            fn b() { Alias::new(); HashMap::new(); }
        }
        use model::Thing;
        impl First for Thing { fn f() {} }
        impl Second for Thing { fn f() {} }
        """)]
        RustModules.resolve(&files)
        let file = files["src/lib.rs"]!
        XCTAssertTrue(file.typeRefs.contains { $0.name == "new" && $0.line == 4 && $0.source == "/src/lib" })
        XCTAssertFalse(file.typeRefs.contains { $0.line == 5 && $0.source != nil })
        XCTAssertTrue(file.typeRefs.contains { $0.line == 5 && $0.module == "std" })
        XCTAssertFalse(file.imports.contains { $0.name == "model" })
        XCTAssertEqual(Set(file.decls.filter { $0.name == "f" }.map(\.qualifiedName)).count, 2)
    }

    func testTuplePayloadsAreCompared() {
        let base = RustExtractor.parse(path: "src/lib.rs", source: "pub struct Value(pub i32); pub enum Choice { Some(i32) }")
        let head = RustExtractor.parse(path: "src/lib.rs", source: "pub struct Value(pub i64); pub enum Choice { Some(i64) }")
        for name in ["Value", "Some"] {
            XCTAssertNotEqual(base.decls.first { $0.name == name }?.signatureCanon, head.decls.first { $0.name == name }?.signatureCanon)
        }
    }

    func testGeneratedIncludesDoNotHideHandwrittenCode() {
        let file = RustExtractor.parse(path: "src/lib.rs", source: #"include!(concat!(env!("OUT_DIR"), "/generated.rs")); pub fn handwritten() {}"#)
        XCTAssertFalse(file.isGenerated)
        XCTAssertEqual(file.decls.map(\.name), ["handwritten"])
        XCTAssertTrue(RustLanguage().generatedPatterns.map(Glob.init).contains { $0.matches("target/debug/build/example/out/generated.rs") })
    }

    func testFixtureClassifiesChanges() throws {
        let report = try Fixture.report("rust")
        XCTAssertTrue(report.reviewItems.contains { $0.qualifiedName == "Store.get()" && $0.changes.contains(.signature) })
        XCTAssertTrue(report.reviewItems.contains { $0.qualifiedName == "Item.value" && $0.changes.contains(.signature) })
        XCTAssertTrue(report.reviewItems.contains { $0.qualifiedName == "read()" && $0.changes.contains(.body) && $0.changes.contains(.modifiers) })
    }
}
