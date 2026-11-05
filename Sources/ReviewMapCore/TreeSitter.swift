import Foundation
import TreeSitter

// A thin layer over tree-sitter's C library, for the languages parsed with it. A language supplies its
// grammar and its queries; this file knows nothing about any one language.

/// A parsed file: the tree and the source bytes its nodes point into.
final class SyntaxTree {
    let source: [UInt8]
    private let tree: OpaquePointer

    /// Parses `source` with a grammar such as `tree_sitter_typescript()`. A parser is made per call, since
    /// one parser can't be shared across threads.
    init(source: String, language: OpaquePointer) {
        self.source = Array(source.utf8)
        let parser = ts_parser_new()
        defer { ts_parser_delete(parser) }
        ts_parser_set_language(parser, language)
        let length = UInt32(self.source.count)
        // Without a timeout or a cancellation flag, parsing always returns a tree.
        tree = source.withCString { ts_parser_parse_string(parser, nil, $0, length) }!
    }

    deinit { ts_tree_delete(tree) }

    var root: SyntaxNode { SyntaxNode(raw: ts_tree_root_node(tree), tree: self) }

    func text(_ start: Int, _ end: Int) -> String {
        String(decoding: source[start..<end], as: UTF8.self)
    }
}

/// A node of a `SyntaxTree`. Lines are 1-based, like the rest of the model.
struct SyntaxNode {
    let raw: TSNode
    let tree: SyntaxTree

    var type: String { String(cString: ts_node_type(raw)) }
    var isNamed: Bool { ts_node_is_named(raw) }
    /// Comments, which may appear anywhere.
    var isExtra: Bool { ts_node_is_extra(raw) }
    var startByte: Int { Int(ts_node_start_byte(raw)) }
    var endByte: Int { Int(ts_node_end_byte(raw)) }
    var startLine: Int { Int(ts_node_start_point(raw).row) + 1 }
    var endLine: Int { Int(ts_node_end_point(raw).row) + 1 }
    var text: String { tree.text(startByte, endByte) }

    var childCount: Int { Int(ts_node_child_count(raw)) }

    var children: [SyntaxNode] {
        (0..<childCount).map { SyntaxNode(raw: ts_node_child(raw, UInt32($0)), tree: tree) }
    }

    /// Named children, without comments.
    var namedChildren: [SyntaxNode] {
        children.filter { $0.isNamed && !$0.isExtra }
    }

    func child(_ field: String) -> SyntaxNode? {
        let n = field.withCString { ts_node_child_by_field_name(raw, $0, UInt32(strlen($0))) }
        return ts_node_is_null(n) ? nil : SyntaxNode(raw: n, tree: tree)
    }

    var parent: SyntaxNode? {
        let n = ts_node_parent(raw)
        return ts_node_is_null(n) ? nil : SyntaxNode(raw: n, tree: tree)
    }

    func isSame(_ other: SyntaxNode) -> Bool { ts_node_eq(raw, other.raw) }

    /// The tokens under the node, without comments and empty tokens (such as automatic semicolons).
    var tokens: [SyntaxNode] {
        var out: [SyntaxNode] = []
        func walk(_ n: SyntaxNode) {
            if n.isExtra { return }
            if n.childCount == 0 {
                if n.endByte > n.startByte { out.append(n) }
                return
            }
            for c in n.children { walk(c) }
        }
        walk(self)
        return out
    }

    /// Every node under this one, itself included, depth first.
    func forEach(_ visit: (SyntaxNode) -> Bool) {
        guard visit(self) else { return }
        for c in children { c.forEach(visit) }
    }
}

extension Array where Element == SyntaxNode {
    /// Token texts joined by single spaces: what's compared to tell real changes from cosmetic ones.
    var canon: String { map(\.text).joined(separator: " ") }

    /// Token texts with a single space wherever the source had anything between them.
    var display: String {
        var out = ""
        for (i, t) in enumerated() {
            if i > 0 && self[i - 1].endByte < t.startByte { out += " " }
            out += t.text
        }
        return out
    }
}

/// A compiled tree-sitter query. Captures are returned per match, by name, after the `#eq?`, `#not-eq?`,
/// `#match?`, `#not-match?`, and `#any-of?` predicates are applied (the C library leaves those to its caller).
final class SyntaxQuery: @unchecked Sendable {
    private let query: OpaquePointer
    private let captureNames: [String]
    private var predicates: [[Predicate]] = []

    private enum Arg {
        case capture(Int)
        case string(String)
    }

    private struct Predicate {
        var op: String
        var args: [Arg]
        var regex: NSRegularExpression?
    }

    struct Match {
        var pattern: Int
        var captures: [(name: String, node: SyntaxNode)]

        func first(_ name: String) -> SyntaxNode? { captures.first { $0.name == name }?.node }
    }

    struct QueryError: Error, CustomStringConvertible {
        var description: String
    }

    init(_ source: String, language: OpaquePointer) throws {
        var offset: UInt32 = 0
        var error = TSQueryErrorNone
        let utf8 = Array(source.utf8)
        guard let q = utf8.withUnsafeBufferPointer({ buf in
            buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                ts_query_new(language, $0, UInt32(buf.count), &offset, &error)
            }
        }) else {
            let line = utf8.prefix(Int(offset)).filter { $0 == UInt8(ascii: "\n") }.count + 1
            throw QueryError(description: "Query error \(error.rawValue) on line \(line).")
        }
        query = q
        captureNames = (0..<ts_query_capture_count(q)).map { id in
            var length: UInt32 = 0
            let p = ts_query_capture_name_for_id(q, id, &length)!
            return String(decoding: UnsafeRawBufferPointer(start: p, count: Int(length)), as: UTF8.self)
        }
        for pattern in 0..<ts_query_pattern_count(q) {
            predicates.append(try Self.predicates(q, pattern: pattern))
        }
    }

    deinit { ts_query_delete(query) }

    private static func predicates(_ q: OpaquePointer, pattern: UInt32) throws -> [Predicate] {
        var count: UInt32 = 0
        guard let steps = ts_query_predicates_for_pattern(q, pattern, &count) else { return [] }
        var out: [Predicate] = []
        var current: [TSQueryPredicateStep] = []
        func string(_ id: UInt32) -> String {
            var length: UInt32 = 0
            let p = ts_query_string_value_for_id(q, id, &length)!
            return String(decoding: UnsafeRawBufferPointer(start: p, count: Int(length)), as: UTF8.self)
        }
        for i in 0..<Int(count) {
            let step = steps[i]
            guard step.type == TSQueryPredicateStepTypeDone else {
                current.append(step)
                continue
            }
            guard let first = current.first, first.type == TSQueryPredicateStepTypeString else {
                throw QueryError(description: "A predicate must start with its name.")
            }
            let op = string(first.value_id)
            let args: [Arg] = current.dropFirst().map {
                $0.type == TSQueryPredicateStepTypeCapture ? .capture(Int($0.value_id)) : .string(string($0.value_id))
            }
            var regex: NSRegularExpression?
            if op == "match?" || op == "not-match?", case .string(let pattern)? = args.last {
                regex = try NSRegularExpression(pattern: pattern)
            }
            guard ["eq?", "not-eq?", "match?", "not-match?", "any-of?"].contains(op) else {
                throw QueryError(description: "Unsupported predicate #\(op).")
            }
            out.append(Predicate(op: op, args: args, regex: regex))
            current = []
        }
        return out
    }

    /// The matches under `node` whose predicates hold.
    func matches(in node: SyntaxNode) -> [Match] {
        let cursor = ts_query_cursor_new()
        defer { ts_query_cursor_delete(cursor) }
        ts_query_cursor_exec(cursor, query, node.raw)
        var out: [Match] = []
        var m = TSQueryMatch()
        while ts_query_cursor_next_match(cursor, &m) {
            var captures: [(name: String, node: SyntaxNode)] = []
            var byId: [Int: SyntaxNode] = [:]
            for i in 0..<Int(m.capture_count) {
                let c = m.captures[i]
                let n = SyntaxNode(raw: c.node, tree: node.tree)
                captures.append((captureNames[Int(c.index)], n))
                byId[Int(c.index)] = n
            }
            if holds(predicates[Int(m.pattern_index)], byId) {
                out.append(Match(pattern: Int(m.pattern_index), captures: captures))
            }
        }
        return out
    }

    private func holds(_ preds: [Predicate], _ byId: [Int: SyntaxNode]) -> Bool {
        func value(_ a: Arg) -> String? {
            switch a {
            case .capture(let id): return byId[id]?.text
            case .string(let s): return s
            }
        }
        for p in preds {
            guard let subject = p.args.first.flatMap(value) else { continue }
            let rest = p.args.dropFirst().compactMap(value)
            let ok: Bool
            switch p.op {
            case "eq?": ok = rest.first == subject
            case "not-eq?": ok = rest.first != subject
            case "any-of?": ok = rest.contains(subject)
            default:
                let found = p.regex?.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil
                ok = p.op == "match?" ? found : !found
            }
            if !ok { return false }
        }
        return true
    }
}
