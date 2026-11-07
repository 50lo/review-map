import Foundation
import XCTest
@testable import ReviewMapCore

final class CallerContextTests: XCTestCase {
    private var temporary: [String] = []

    override func tearDown() {
        for path in temporary { try? FileManager.default.removeItem(atPath: path) }
        temporary = []
    }

    private func report(base: [String: String], head changes: [String: String],
                        swiftIndex: [Side: SideIndex]? = nil) throws -> ChangeReport {
        let root = NSTemporaryDirectory() + "rm-caller-context-\(UUID().uuidString)"
        temporary.append(root)
        let options = AnalyzeOptions(repo: root, base: "base", head: "head")
        let languages: [Language] = [SwiftLanguage(), KotlinLanguage()]
        let parser = ParseCache()
        var config = Config()
        func side(_ side: Side, _ files: [String: String]) throws -> SideData {
            let dir = root + "/" + side.rawValue
            for (path, text) in files {
                let file = dir + "/" + path
                try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try text.write(toFile: file, atomically: true, encoding: .utf8)
            }
            return try SideData.load(side: side, dir: dir, blobs: files, languages: languages,
                                     config: &config, parser: parser, options: options)
        }
        let head = base.merging(changes) { _, new in new }
        var builder = try ChangeReportBuilder(base: side(.base, base), head: side(.head, head), languages: languages, options: options)
        if let swiftIndex { builder.addIndex(swiftIndex, language: SwiftLanguage()) }
        builder.matchReviewItems()
        builder.resolveReferences()
        return builder.finish(repo: RepoInfo(root: root, base: "base", head: "head", baseSha: "base", headSha: "head", usesMergeBase: false))
    }

    private func callers(_ report: ChangeReport, file: String, name: String) throws -> [Region] {
        let item = try XCTUnwrap(report.reviewItems.first { $0.location.file == file && $0.qualifiedName == name })
        return report.regions.filter { $0.reviewItem == item.id && $0.relation == "caller" }
    }

    func testSwiftIndexPreservesKotlinCallersInSameAndOtherComponents() throws {
        let base = [
            "ios/Greeting.swift": "func greeting(_ name: String) -> String { name }\n",
            "ios/Screen.swift": "func renderGreeting() -> String { greeting(\"Taylor\") }\n",
            "android/Greeting.kt": "package com.example.mobile\nfun greeting(name: String): String = name\n",
            "android/Screen.kt": "package com.example.mobile\nfun renderGreeting(): String = greeting(\"Taylor\")\n",
            "widget/Screen.kt": "package com.example.mobile\nfun renderWidget(): String = greeting(\"Taylor\")\n",
        ]
        let head = [
            "ios/Greeting.swift": "func greeting(_ name: String, _ prefix: String = \"Hello\") -> String { prefix + name }\n",
            "android/Greeting.kt": "package com.example.mobile\nfun greeting(name: String, prefix: String = \"Hello\"): String = prefix + name\n",
        ]
        let swift = SideIndex(refs: [
            "ios/Greeting.swift": [],
            "ios/Screen.swift": [IndexedRef(line: 1, targetFile: "ios/Greeting.swift", targetLine: 1, name: "greeting(_:)")],
        ])
        let named = try report(base: base, head: head)
        let indexed = try report(base: base, head: head, swiftIndex: [.base: swift, .head: swift])
        XCTAssertEqual(indexed.analyzer.resolution, "index")
        let kotlinCallers = try callers(indexed, file: "android/Greeting.kt", name: "greeting()")
        XCTAssertEqual(Set(kotlinCallers.map(\.file)), ["android/Screen.kt", "widget/Screen.kt"])
        XCTAssertEqual(kotlinCallers, try callers(named, file: "android/Greeting.kt", name: "greeting()"))
        XCTAssertEqual(try callers(indexed, file: "ios/Greeting.swift", name: "greeting(_:_:)").map(\.file), ["ios/Screen.swift"])
    }

    func testPartialSwiftIndexCombinesExactAndUncoveredCallers() throws {
        let base = [
            "App/Greeting.swift": "func greeting(_ name: String) -> String { name }\n",
            "App/Exact.swift": "func exactCaller() -> String { greeting(\"Taylor\") }\n",
            "App/Uncovered.swift": "func uncoveredCaller() -> String { greeting(\"Taylor\") }\n",
            // The spelling matches, but this calls another declaration. Covered empty refs must suppress fallback.
            "App/Decoy.swift": "struct Other { func greeting(_ name: String) -> String { name } }\nfunc decoy() -> String { Other().greeting(\"Taylor\") }\n",
            "Widget/Uncovered.swift": "func widgetCaller() -> String { greeting(\"Taylor\") }\n",
        ]
        for targetCovered in [true, false] {
            var refs: [String: [IndexedRef]] = [
                "App/Exact.swift": [IndexedRef(line: 1, targetFile: "App/Greeting.swift", targetLine: 1, name: "greeting(_:)")],
                "App/Decoy.swift": [],
            ]
            if targetCovered { refs["App/Greeting.swift"] = [] }
            let index = SideIndex(refs: refs)
            let result = try report(base: base,
                                    head: ["App/Greeting.swift": "func greeting(_ name: String, _ prefix: String = \"Hello\") -> String { prefix + name }\n"],
                                    swiftIndex: [.base: index, .head: index])
            let found = try callers(result, file: "App/Greeting.swift", name: "greeting(_:_:)")
            XCTAssertEqual(Set(found.map(\.file)), ["App/Exact.swift", "App/Uncovered.swift", "Widget/Uncovered.swift"],
                           "Caller file coverage controls fallback even when target coverage is \(targetCovered)")
            XCTAssertEqual(found.count, 3)
        }
    }

    func testFallbackUsesHeadCoverage() throws {
        let base = [
            "Lib/Greeting.swift": "public func greeting(_ name: String) -> String { name }\n",
            "App/New.swift": "func newCaller() -> String { \"Taylor\" }\n",
        ]
        let baseIndex = SideIndex(refs: [
            "Lib/Greeting.swift": [],
            "App/New.swift": [],
        ])
        let headIndex = SideIndex(refs: ["Lib/Greeting.swift": []])
        let result = try report(base: base, head: [
            "Lib/Greeting.swift": "public func greeting(_ name: String, _ prefix: String = \"Hello\") -> String { prefix + name }\n",
            "App/New.swift": "func newCaller() -> String { greeting(\"Taylor\") }\n",
        ], swiftIndex: [.base: baseIndex, .head: headIndex])
        XCTAssertEqual(try callers(result, file: "Lib/Greeting.swift", name: "greeting(_:_:)").map(\.file), ["App/New.swift"])
    }

    func testFallbackDoesNotInterpretBaseOnlyCallsAsHeadContext() throws {
        let base = [
            "Other/Indexed.swift": "struct Indexed {}\n",
            "Lib/Greeting.swift": "public func swiftGreeting(_ name: String) -> String { name }\n",
            "App/Screen.swift": "func removedSwift() -> String { swiftGreeting(\"Taylor\") }\nfunc retainedSwift() -> String { swiftGreeting(\"Taylor\") }\n",
            "android/Greeting.kt": "package com.example.mobile\nfun greeting(name: String): String = name\n",
            "widget/Screen.kt": "package com.example.mobile\nfun removedKotlin(): String = greeting(\"Taylor\")\nfun retainedKotlin(): String = greeting(\"Taylor\")\n",
        ]
        let head = [
            "Lib/Greeting.swift": "public func swiftGreeting(_ name: String, _ prefix: String = \"Hello\") -> String { prefix + name }\n",
            "App/Screen.swift": "func unrelatedSwift() -> String { \"Taylor\" }\nfunc retainedSwift() -> String { swiftGreeting(\"Taylor\") }\n",
            "android/Greeting.kt": "package com.example.mobile\nfun greeting(name: String, prefix: String = \"Hello\"): String = prefix + name\n",
            "widget/Screen.kt": "package com.example.mobile\nfun unrelatedKotlin(): String = \"Taylor\"\nfun retainedKotlin(): String = greeting(\"Taylor\")\n",
        ]
        // Swift callers are uncovered by a partial Swift index; Kotlin has no index at all.
        let headIndex = SideIndex(refs: ["Other/Indexed.swift": []])
        var baseIndex = headIndex
        baseIndex.refs["App/Screen.swift"] = [1, 2].map {
            IndexedRef(line: $0, targetFile: "Lib/Greeting.swift", targetLine: 1, name: "swiftGreeting(_:)")
        }
        for indexed in [false, true] {
            let result = try report(base: base, head: head, swiftIndex: indexed ? [.base: baseIndex, .head: headIndex] : nil)
            for (file, name, removed, retained) in [
                ("Lib/Greeting.swift", "swiftGreeting(_:_:)", "removedSwift()", "retainedSwift()"),
                ("android/Greeting.kt", "greeting()", "removedKotlin()", "retainedKotlin()"),
            ] {
                let item = try XCTUnwrap(result.reviewItems.first { $0.location.file == file && $0.qualifiedName == name })
                XCTAssertTrue(item.usedBy.contains { $0.symbol == removed && $0.side == .base },
                              "Keep the base usage as historical evidence; indexed: \(indexed)")
                XCTAssertEqual(try callers(result, file: file, name: name).map(\.reasons), [[retained]],
                               "Only genuine head callers belong in head context; indexed: \(indexed)")
            }
        }
    }
}
