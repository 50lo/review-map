import XCTest
import TreeSitterRust
@testable import ReviewMapCore

final class RustFlagTests: XCTestCase {
    func testContractFlags() throws {
        let report = try Fixture.report("rust-flags")
        func flags(_ name: String) throws -> Set<String> {
            Set(try XCTUnwrap(report.reviewItems.first { $0.qualifiedName == name }, name).contractFlags)
        }
        let expected: [String: Set<String>] = [
            "added()": ["rust:api-added"], "removed()": ["rust:api-removed"],
            "signature()": ["rust:api-signature-changed"], "narrowed()": ["rust:visibility-narrowed"],
            "become_async()": ["rust:async-added"], "become_sync()": ["rust:async-removed"],
            "add_bounds()": ["rust:send-bound-added", "rust:sync-bound-added"],
            "remove_bounds()": ["rust:send-bound-removed", "rust:sync-bound-removed"],
            "Service": ["rust:trait-item-added", "rust:trait-item-removed", "rust:trait-item-changed"],
            "Color": ["rust:enum-variant-added", "rust:enum-variant-removed"],
            "Flexible": ["rust:non-exhaustive-removed"], "Strict": ["rust:non-exhaustive-added"],
            "Message": ["rust:serde-shape-changed"], "TupleWire": ["rust:serde-shape-changed"],
            "Wire": ["rust:serde-shape-changed"], "Named": ["rust:serde-shape-changed"],
        ]
        for (name, required) in expected {
            let actual = try flags(name)
            XCTAssertTrue(required.isSubset(of: actual), "\(name): \(actual)")
        }
        XCTAssertFalse(try flags("hidden.secret()").contains("rust:api-signature-changed"))
    }

    func testRiskQueries() {
        let source = """
        unsafe fn danger() {}
        fn example() {
            unsafe { danger(); }
            value.unwrap();
            value.expect("value");
            panic!("failure");
            todo!();
            unimplemented!();
            unreachable!();
            let x = values[1];
            let y = x as u8;
            block_on(work());
            runtime.block_on(work());
            executor::block_on(work());
            std::thread::spawn(work);
            lock.lock().unwrap();
            let pointer = x as *const u8;
            let text = "panic! unsafe unwrap";
        }
        """
        let tree = SyntaxTree(source: source, language: tree_sitter_rust())
        let marks = RustRisk.marks(tree.root)
        XCTAssertEqual(RustExtractor.parse(path: "src/lib.rs", source: source).marks, marks)
        let expected: [(Int, LineMark.Kind, String)] = [
            (1, .crash, "unsafe"), (3, .crash, "unsafe"), (4, .crash, "unwrap"), (5, .crash, "expect"),
            (6, .crash, "panic!"), (7, .crash, "todo!"), (8, .crash, "unimplemented!"), (9, .crash, "unreachable!"),
            (10, .crash, "indexing"), (11, .check, "numeric cast"), (12, .concurrency, "block_on"),
            (13, .concurrency, "block_on"), (14, .concurrency, "block_on"), (15, .concurrency, "thread::spawn"),
            (16, .concurrency, "lock().unwrap()"),
        ]
        for (line, kind, label) in expected { XCTAssertTrue(marks[line]?.contains(LineMark(kind: kind, label: label)) == true, "line \(line): \(marks[line] ?? [])") }
        XCTAssertNil(marks[17]); XCTAssertNil(marks[18])
    }

    func testSettingsAndRisk() {
        for (key, flag) in [("Cargo.toml features.default", "features-changed"), ("Cargo.toml edition", "edition-changed"), ("Cargo.toml rust-version", "rust-version-changed"), ("Cargo.toml profile.release", "profile-changed")] {
            XCTAssertEqual(RustFlags.settingFlag(key), flag)
            XCTAssertEqual(RustFlags.risk(flag, isInterface: false), RiskWeight.medium)
        }
        XCTAssertEqual(RustFlags.risk("serde-shape-changed", isInterface: false), RiskWeight.high)
        XCTAssertEqual(RustFlags.risk("visibility-narrowed", isInterface: false), RiskWeight.high)
    }
}
