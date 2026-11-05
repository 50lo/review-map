import Foundation

// SCIP (https://github.com/sourcegraph/scip): the index format that scip-typescript, scip-go, and
// rust-analyzer write. A SCIP index lists, per document, every occurrence of a symbol with its range and
// roles; the definitions give each symbol a place, so every other occurrence becomes an `IndexedRef`.
// Only the fields used here are decoded, with a small protobuf reader, so no protobuf dependency.

enum SCIP {
    struct Occurrence: Equatable {
        /// 1-based, like the rest of the model (SCIP lines are 0-based).
        var line: Int
        var symbol: String
        var roles: Int32

        var isDefinition: Bool { roles & 0x1 != 0 }
    }

    struct Document: Equatable {
        /// Relative to the index's project root.
        var path: String
        var occurrences: [Occurrence]
    }

    struct Index: Equatable {
        /// A file URI, such as "file:///tmp/head/web".
        var projectRoot: String?
        var documents: [Document]
    }

    // MARK: Reading

    /// Exact references for one side, from SCIP indexes of its exported tree at `sourceRoot`. Paths become
    /// repo-relative through each index's project root; files outside `known` are left out.
    static func sideIndex(_ indexes: [Index], sourceRoot: String, known: Set<String>) -> SideIndex {
        var definitions: [String: (file: String, line: Int)] = [:]
        var documents: [(file: String, doc: Document)] = []
        for index in indexes {
            let prefix = index.projectRoot.flatMap { relativeRoot($0, sourceRoot: sourceRoot) } ?? ""
            for doc in index.documents {
                let file = join(prefix, doc.path)
                guard known.contains(file) else { continue }
                documents.append((file, doc))
                for o in doc.occurrences where o.isDefinition && !o.symbol.isEmpty {
                    let key = symbolKey(o.symbol, file: file)
                    if definitions[key] == nil { definitions[key] = (file, o.line) }
                }
            }
        }
        var refs: [String: [IndexedRef]] = [:]
        for (file, doc) in documents {
            var out = Set<IndexedRef>()
            for o in doc.occurrences where !o.isDefinition && !o.symbol.isEmpty {
                guard let def = definitions[symbolKey(o.symbol, file: file)] else { continue }
                out.insert(IndexedRef(line: o.line, targetFile: def.file, targetLine: def.line, name: name(ofSymbol: o.symbol)))
            }
            refs[file, default: []] += out.sorted { ($0.line, $0.targetFile, $0.targetLine) < ($1.line, $1.targetFile, $1.targetLine) }
        }
        return SideIndex(refs: refs)
    }

    /// Local symbols ("local 4") are only unique within their document.
    private static func symbolKey(_ symbol: String, file: String) -> String {
        symbol.hasPrefix("local ") ? file + "\u{1}" + symbol : symbol
    }

    /// The project root as a directory relative to `sourceRoot` ("" for the root itself), or nil when it is
    /// outside.
    static func relativeRoot(_ uri: String, sourceRoot: String) -> String? {
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        let real = { (p: String) in URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path }
        let p = real(url.path), root = real(sourceRoot)
        if p == root { return "" }
        return p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : nil
    }

    /// The name of a symbol's last descriptor, with "()" for a method:
    /// "scip-typescript npm app 1.0.0 src/`store.ts`/Store#load()." -> "load()".
    static func name(ofSymbol symbol: String) -> String {
        if symbol.hasPrefix("local ") { return String(symbol.dropFirst("local ".count)) }
        // Scheme, manager, package name, and version, separated by single spaces (a double space is an escaped space).
        let chars = Array(symbol)
        var i = 0
        var fields = 0
        while i < chars.count && fields < 4 {
            if chars[i] == " " {
                if i + 1 < chars.count && chars[i + 1] == " " { i += 2; continue }
                fields += 1
            }
            i += 1
        }
        var last = ""
        while i < chars.count {
            let c = chars[i]
            if c == "(" || c == "[" {
                // A parameter or type parameter: (name) or [name].
                let close: Character = c == "(" ? ")" : "]"
                while i < chars.count && chars[i] != close { i += 1 }
                i += 1
                continue
            }
            var name = ""
            if c == "`" {
                i += 1
                while i < chars.count {
                    if chars[i] == "`" {
                        if i + 1 < chars.count && chars[i + 1] == "`" { name.append("`"); i += 2; continue }
                        i += 1
                        break
                    }
                    name.append(chars[i])
                    i += 1
                }
            } else {
                while i < chars.count && (chars[i].isLetter || chars[i].isNumber || "_+-$".contains(chars[i])) {
                    name.append(chars[i])
                    i += 1
                }
            }
            guard i < chars.count else { last = name; break }
            if chars[i] == "(" {
                // A method: name(disambiguator).
                while i < chars.count && chars[i] != ")" { i += 1 }
                i += 2
                last = name + "()"
            } else {
                // Namespace "/", type "#", term ".", meta ":", or macro "!".
                i += 1
                last = name
            }
        }
        return last
    }

    // MARK: Decoding

    struct DecodeError: Error, CustomStringConvertible {
        var description: String
    }

    static func decode(_ data: Data) throws -> Index {
        let bytes = [UInt8](data)
        var r = ProtoReader(bytes: bytes, range: 0..<bytes.count)
        var index = Index(projectRoot: nil, documents: [])
        while let (field, wire) = try r.next() {
            switch (field, wire) {
            case (1, 2):
                var m = try r.message()
                while let (f, w) = try m.next() {
                    if f == 3 && w == 2 { index.projectRoot = try m.string() } else { try m.skip(w) }
                }
            case (2, 2):
                index.documents.append(try document(r.message()))
            default:
                try r.skip(wire)
            }
        }
        return index
    }

    private static func document(_ reader: ProtoReader) throws -> Document {
        var r = reader
        var doc = Document(path: "", occurrences: [])
        while let (field, wire) = try r.next() {
            switch (field, wire) {
            case (1, 2): doc.path = try r.string()
            case (2, 2): if let o = try occurrence(r.message()) { doc.occurrences.append(o) }
            default: try r.skip(wire)
            }
        }
        return doc
    }

    private static func occurrence(_ reader: ProtoReader) throws -> Occurrence? {
        var r = reader
        var range: [Int32] = []
        var symbol = ""
        var roles: Int32 = 0
        while let (field, wire) = try r.next() {
            switch (field, wire) {
            case (1, 2):
                var packed = try r.message()
                while !packed.atEnd { range.append(Int32(truncatingIfNeeded: try packed.varint())) }
            case (1, 0): range.append(Int32(truncatingIfNeeded: try r.varint()))
            case (2, 2): symbol = try r.string()
            case (3, 0): roles = Int32(truncatingIfNeeded: try r.varint())
            default: try r.skip(wire)
            }
        }
        guard let start = range.first else { return nil }
        return Occurrence(line: Int(start) + 1, symbol: symbol, roles: roles)
    }
}

/// Reads protobuf fields from a range of bytes.
struct ProtoReader {
    let bytes: [UInt8]
    var pos: Int
    let end: Int

    init(bytes: [UInt8], range: Range<Int>) {
        self.bytes = bytes
        pos = range.lowerBound
        end = range.upperBound
    }

    var atEnd: Bool { pos >= end }

    /// The next field number and wire type, or nil at the end.
    mutating func next() throws -> (Int, Int)? {
        guard !atEnd else { return nil }
        let key = try varint()
        return (Int(key >> 3), Int(key & 7))
    }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard pos < end, shift < 64 else { throw SCIP.DecodeError(description: "Truncated varint at byte \(pos).") }
            let b = bytes[pos]
            pos += 1
            result |= UInt64(b & 0x7f) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
        }
    }

    /// A length-delimited field's bytes, as a reader of their own.
    mutating func message() throws -> ProtoReader {
        let length = Int(try varint())
        guard length >= 0, pos + length <= end else { throw SCIP.DecodeError(description: "Field runs past the end at byte \(pos).") }
        defer { pos += length }
        return ProtoReader(bytes: bytes, range: pos..<(pos + length))
    }

    mutating func string() throws -> String {
        let m = try message()
        return String(decoding: bytes[m.pos..<m.end], as: UTF8.self)
    }

    mutating func skip(_ wire: Int) throws {
        switch wire {
        case 0: _ = try varint()
        case 1: pos += 8
        case 2: _ = try message()
        case 5: pos += 4
        default: throw SCIP.DecodeError(description: "Unsupported wire type \(wire) at byte \(pos).")
        }
        if pos > end { throw SCIP.DecodeError(description: "Field runs past the end.") }
    }
}
