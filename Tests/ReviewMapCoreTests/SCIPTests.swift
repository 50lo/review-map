import Foundation
import XCTest
@testable import ReviewMapCore

/// Writes the protobuf fields of a SCIP index, to test the reader without an indexer.
private struct ProtoWriter {
    var bytes: [UInt8] = []

    mutating func varint(_ v: UInt64) {
        var v = v
        while v >= 0x80 {
            bytes.append(UInt8(v & 0x7f) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    mutating func key(_ field: Int, _ wire: Int) { varint(UInt64(field << 3 | wire)) }

    mutating func int(_ field: Int, _ v: Int) {
        key(field, 0)
        varint(UInt64(bitPattern: Int64(v)))
    }

    mutating func bytes(_ field: Int, _ b: [UInt8]) {
        key(field, 2)
        varint(UInt64(b.count))
        bytes += b
    }

    mutating func string(_ field: Int, _ s: String) { bytes(field, Array(s.utf8)) }

    mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var m = ProtoWriter()
        build(&m)
        bytes(field, m.bytes)
    }
}

/// An occurrence: 0-based line, symbol, and roles (1 is a definition).
private typealias Occ = (line: Int, symbol: String, roles: Int)

private func scip(root: String?, documents: [(path: String, occurrences: [Occ])], packed: Bool = true) -> Data {
    var w = ProtoWriter()
    if let root {
        w.message(1) { m in
            m.message(2) { t in t.string(1, "test-indexer") }
            m.string(3, root)
        }
    }
    for doc in documents {
        w.message(2) { d in
            d.string(4, "TypeScript")
            d.string(1, doc.path)
            for o in doc.occurrences {
                d.message(2) { occ in
                    let range = [o.line, 4, 10]
                    if packed {
                        var p = ProtoWriter()
                        for v in range { p.varint(UInt64(v)) }
                        occ.bytes(1, p.bytes)
                    } else {
                        for v in range { occ.int(1, v) }
                    }
                    occ.string(2, o.symbol)
                    if o.roles != 0 { occ.int(3, o.roles) }
                    occ.int(5, 7) // syntax_kind, skipped
                }
            }
            d.message(3) { s in s.string(1, "ignored symbol information") }
        }
    }
    w.message(3) { s in s.string(1, "external symbol") }
    return Data(w.bytes)
}

final class SCIPTests: XCTestCase {
    let store = "scip-typescript npm app 1.0.0 src/`store.ts`/Store#"
    let load = "scip-typescript npm app 1.0.0 src/`store.ts`/Store#load()."

    func testDecode() throws {
        let data = scip(root: "file:///tmp/head", documents: [
            ("src/store.ts", [(0, store, 1), (2, load, 1)]),
            ("src/feed.ts", [(4, load, 0), (5, "local 0", 1)]),
        ])
        let index = try SCIP.decode(data)
        XCTAssertEqual(index.projectRoot, "file:///tmp/head")
        XCTAssertEqual(index.documents.map(\.path), ["src/store.ts", "src/feed.ts"])
        XCTAssertEqual(index.documents[1].occurrences, [
            SCIP.Occurrence(line: 5, symbol: load, roles: 0),
            SCIP.Occurrence(line: 6, symbol: "local 0", roles: 1),
        ])
        let unpacked = try SCIP.decode(scip(root: nil, documents: [("a.ts", [(9, store, 1)])], packed: false))
        XCTAssertEqual(unpacked.documents[0].occurrences.first?.line, 10)
    }

    func testTruncatedIndexThrows() {
        let data = scip(root: "file:///tmp/head", documents: [("src/store.ts", [(0, store, 1)])])
        XCTAssertThrowsError(try SCIP.decode(data.prefix(data.count - 3)))
    }

    func testSideIndex() throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("rm-scip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root + "/web", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        // The indexer ran in web/, so its paths are relative to web/.
        let index = try SCIP.decode(scip(root: URL(fileURLWithPath: root + "/web").absoluteString, documents: [
            ("src/store.ts", [(0, store, 1), (2, load, 1), (3, "local 1", 1)]),
            ("src/feed.ts", [(0, store, 0x2), (4, load, 0), (4, "local 1", 0), (6, "local 2", 1), (7, "local 2", 0),
                             (8, "scip-typescript npm lib 2.0.0 `index.d.ts`/fetch().", 0)]),
            ("dist/bundle.ts", [(1, load, 0)]),
        ]))
        let side = SCIP.sideIndex([index], sourceRoot: root, known: ["web/src/store.ts", "web/src/feed.ts"])
        XCTAssertEqual(Set(side.refs.keys), ["web/src/store.ts", "web/src/feed.ts"], "files outside the repo's sources are left out")
        XCTAssertEqual(side.refs["web/src/store.ts"], [], "a file with only definitions is still covered")
        XCTAssertEqual(side.refs["web/src/feed.ts"], [
            IndexedRef(line: 1, targetFile: "web/src/store.ts", targetLine: 1, name: "Store"),
            IndexedRef(line: 5, targetFile: "web/src/store.ts", targetLine: 3, name: "load()"),
            IndexedRef(line: 8, targetFile: "web/src/feed.ts", targetLine: 7, name: "2"),
        ], "an import counts as a reference; local symbols resolve only within their document; external symbols have no definition")
    }

    func testRelativeRoot() {
        XCTAssertEqual(SCIP.relativeRoot("file:///tmp/x/head", sourceRoot: "/tmp/x/head"), "")
        XCTAssertEqual(SCIP.relativeRoot("file:///tmp/x/head/web/", sourceRoot: "/tmp/x/head"), "web")
        XCTAssertNil(SCIP.relativeRoot("file:///elsewhere", sourceRoot: "/tmp/x/head"))
        XCTAssertNil(SCIP.relativeRoot("https://example.com/x", sourceRoot: "/tmp/x/head"))
    }

    func testSymbolNames() {
        XCTAssertEqual(SCIP.name(ofSymbol: load), "load()")
        XCTAssertEqual(SCIP.name(ofSymbol: store), "Store")
        XCTAssertEqual(SCIP.name(ofSymbol: "scip-typescript npm app 1.0.0 src/`store.ts`/Store#items."), "items")
        XCTAssertEqual(SCIP.name(ofSymbol: "rust-analyzer cargo feed 0.1.0 store/impl#[Store]load(+1)."), "load()")
        XCTAssertEqual(SCIP.name(ofSymbol: "scip-go gomod example.com/feed v1.2.0 `example.com/feed/store`/Store#Load()."), "Load()")
        XCTAssertEqual(SCIP.name(ofSymbol: "scip-typescript npm app 1.0.0 src/`a.ts`/`odd ``name`."), "odd `name")
        XCTAssertEqual(SCIP.name(ofSymbol: "scip-typescript npm my  app 1.0.0 src/`a.ts`/run()."), "run()", "a double space escapes a space")
        XCTAssertEqual(SCIP.name(ofSymbol: "scip-typescript npm app 1.0.0 src/`a.ts`/run().(item)"), "run()", "a parameter names its function")
        XCTAssertEqual(SCIP.name(ofSymbol: "local 12"), "12")
    }
}
