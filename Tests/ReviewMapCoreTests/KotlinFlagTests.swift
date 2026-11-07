import Foundation
import XCTest
import TreeSitterKotlin
@testable import ReviewMapCore

final class KotlinFlagTests: XCTestCase {
    func testContractFlags() throws {
        let report = try Fixture.report("kotlin-flags")
        func flags(_ name: String) throws -> Set<String> {
            Set(try XCTUnwrap(report.reviewItems.first { $0.qualifiedName == name }, name).contractFlags)
        }
        let expected: [String: Set<String>] = [
            "added()": ["kotlin:api-added"], "removed()": ["kotlin:api-removed"],
            "signature()": ["kotlin:api-signature-changed"], "nullable()": ["kotlin:nullability-changed"],
            "narrowed()": ["kotlin:visibility-narrowed"],
            "becomeSuspend()": ["kotlin:suspend-added"], "becomeSync()": ["kotlin:suspend-removed"],
            "Flexible": ["kotlin:open-removed", "kotlin:final-added"],
            "Extensible": ["kotlin:open-added", "kotlin:final-removed"],
            "AbstractOwner": ["kotlin:abstract-removed"], "BecomesAbstract": ["kotlin:abstract-added"],
            "Point": ["kotlin:data-class-shape-changed"], "Wire": ["kotlin:serialized-shape-changed"],
            "Reordered": ["kotlin:data-class-shape-changed"], "BecomesData": ["kotlin:data-class-shape-changed"], "StopsBeingData": ["kotlin:data-class-shape-changed"],
            "Row": ["kotlin:persisted-shape-changed"], "JsonValue.value": ["kotlin:serialized-shape-changed"],
            "State": ["kotlin:sealed-subclass-added", "kotlin:sealed-subclass-removed"],
            "Color": ["kotlin:enum-entry-added", "kotlin:enum-entry-removed"],
            "Visibility.becomesProtected()": ["kotlin:visibility-narrowed"], "Visibility.becomesInternal()": ["kotlin:visibility-narrowed"],
            "src/main/AndroidManifest.xml": ["kotlin:android-manifest-changed", "kotlin:permission-added", "kotlin:permission-removed", "kotlin:exported-components-changed", "kotlin:intent-filters-changed"],
        ]
        for (name, required) in expected {
            let actual = try flags(name)
            XCTAssertTrue(required.isSubset(of: actual), "\(name): \(actual)")
        }
        XCTAssertFalse(try flags("Hidden.secret()").contains("kotlin:api-signature-changed"))
        XCTAssertFalse(try flags("defaultText()").contains("kotlin:nullability-changed"), "question marks in default strings are not type nullability")
        XCTAssertTrue(try flags("Left.State").contains("kotlin:sealed-subclass-removed"))
        XCTAssertFalse(try flags("Left.State").contains("kotlin:sealed-subclass-added"), "the added classes inherit Right.State")
        XCTAssertTrue(try flags("Right.State").contains("kotlin:sealed-subclass-added"))
        XCTAssertFalse(try flags("Right.State").contains("kotlin:sealed-subclass-removed"), "the removed class inherited Left.State")
        XCTAssertTrue(try flags("AddedViaAlias").contains("kotlin:sealed-subclass-added"))
        let settings = try XCTUnwrap(report.reviewItems.first { $0.kind == .target })
        XCTAssertEqual(Set(settings.contractFlags), ["kotlin:min-sdk-changed", "kotlin:target-sdk-changed", "kotlin:compile-sdk-changed", "kotlin:jvm-target-changed", "kotlin:kotlin-version-changed"])
    }

    func testRiskQueries() {
        let source = """
        lateinit var name: String
        fun risk(value: Any?) {
            value!!
            val text = value as String
            val safe = value as? String
            TODO()
            error("failure")
            check(true)
            require(true)
            runBlocking { work() }
            GlobalScope.launch { work() }
            withContext(Dispatchers.Main) { work() }
            val ignored = "TODO() error() !! lateinit GlobalScope"
        }
        """
        let tree = SyntaxTree(source: source, language: tree_sitter_kotlin()!)
        let marks = KotlinRisk.marks(tree.root)
        XCTAssertEqual(KotlinExtractor.parse(path: "Risk.kt", source: source).marks, marks)
        let expected: [(Int, LineMark.Kind, String)] = [
            (1, .crash, "lateinit"), (3, .crash, "non-null assertion"), (4, .crash, "unchecked cast"),
            (6, .crash, "TODO"), (7, .crash, "error"), (8, .check, "check"), (9, .check, "require"),
            (10, .concurrency, "runBlocking"), (11, .concurrency, "GlobalScope"),
            (12, .isolation, "withContext"), (12, .isolation, "Dispatchers.Main"),
        ]
        for (line, kind, label) in expected {
            XCTAssertTrue(marks[line]?.contains(LineMark(kind: kind, label: label)) == true, "line \(line): \(marks[line] ?? [])")
        }
        XCTAssertNil(marks[5], "a safe cast is not a crash mark")
        XCTAssertNil(marks[13], "strings do not create risk marks")
    }

    func testManifestFormattingAndNamespaceAliasesDoNotChangeContracts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rm-kotlin-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = """
        <manifest xmlns:android="http://schemas.android.com/apk/res/android"><application><activity android:name=".Main" android:exported="true"><intent-filter><action android:name="A"/><category android:name="B"/></intent-filter></activity></application></manifest>
        """
        let head = """
        <manifest xmlns:a="http://schemas.android.com/apk/res/android">
          <application><activity a:exported="true" a:name=".Main">
            <intent-filter><category a:name="B"/><action a:name="A"/></intent-filter>
          </activity></application>
        </manifest>
        """
        let b = root.appendingPathComponent("base.xml"), h = root.appendingPathComponent("head.xml")
        try base.write(to: b, atomically: true, encoding: .utf8)
        try head.write(to: h, atomically: true, encoding: .utf8)
        XCTAssertEqual(KotlinManifest.flags(basePath: b.path, headPath: h.path), [])
        XCTAssertNil(KotlinManifest.contractFile("NotAndroidManifest.xml"))
    }

    func testSettingsAndRisk() {
        for (key, flag) in [("gradle minSdk", "min-sdk-changed"), ("gradle targetSdk", "target-sdk-changed"), ("gradle compileSdk", "compile-sdk-changed"), ("gradle jvmTarget", "jvm-target-changed"), ("gradle kotlin", "kotlin-version-changed")] {
            XCTAssertEqual(KotlinFlags.settingFlag(key), flag)
        }
        XCTAssertEqual(KotlinFlags.risk("serialized-shape-changed", isInterface: false), RiskWeight.high)
        XCTAssertEqual(KotlinFlags.risk("nullability-changed", isInterface: true), RiskWeight.high)
        XCTAssertEqual(KotlinFlags.risk("compile-sdk-changed", isInterface: false), RiskWeight.medium)
    }
}
