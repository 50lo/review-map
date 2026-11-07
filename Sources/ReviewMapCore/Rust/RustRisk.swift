import Foundation
import TreeSitterRust

/// Syntax signals; these report possible hazards without claiming type information.
enum RustRisk {
    struct Entry {
        let kind: LineMark.Kind
        let label: String
        let pattern: String
    }
    static let entries: [Entry] = [
        Entry(kind: .crash, label: "unsafe", pattern: #"(unsafe_block) @m"#),
        Entry(kind: .crash, label: "unsafe", pattern: #"(function_modifiers "unsafe" @m)"#),
        Entry(kind: .crash, label: "%", pattern: #"(call_expression function: (field_expression field: (field_identifier) @m) (#any-of? @m "unwrap" "expect"))"#),
        Entry(kind: .crash, label: "%!", pattern: #"(macro_invocation macro: (identifier) @m (#any-of? @m "panic" "todo" "unimplemented" "unreachable"))"#),
        Entry(kind: .crash, label: "%!", pattern: #"(macro_invocation macro: (scoped_identifier name: (identifier) @m) (#any-of? @m "panic" "todo" "unimplemented" "unreachable"))"#),
        Entry(kind: .crash, label: "indexing", pattern: #"(index_expression) @m"#),
        Entry(kind: .check, label: "numeric cast", pattern: #"((type_cast_expression type: (primitive_type) @t) @m (#match? @t "^(i|u|f)[0-9]+$|^[iu]size$"))"#),
        Entry(kind: .concurrency, label: "block_on", pattern: #"(call_expression function: (identifier) @m (#eq? @m "block_on"))"#),
        Entry(kind: .concurrency, label: "block_on", pattern: #"(call_expression function: (scoped_identifier name: (identifier) @m) (#eq? @m "block_on"))"#),
        Entry(kind: .concurrency, label: "block_on", pattern: #"(call_expression function: (field_expression field: (field_identifier) @m) (#eq? @m "block_on"))"#),
        Entry(kind: .concurrency, label: "thread::spawn", pattern: #"(call_expression function: (scoped_identifier) @m (#match? @m "^(std::)?thread::spawn$"))"#),
        Entry(kind: .concurrency, label: "lock().unwrap()", pattern: #"(call_expression function: (field_expression value: (call_expression function: (field_expression field: (field_identifier) @lock)) field: (field_identifier) @m) (#eq? @lock "lock") (#eq? @m "unwrap"))"#),
        Entry(kind: .concurrency, label: "lock().unwrap()", pattern: #"(call_expression function: (field_expression value: (call_expression function: (scoped_identifier name: (identifier) @lock)) field: (field_identifier) @m) (#eq? @lock "lock") (#eq? @m "unwrap"))"#),
    ]
    private static let query = try! SyntaxQuery(entries.map(\.pattern).joined(separator: "\n"), language: tree_sitter_rust())
    static func marks(_ root: SyntaxNode) -> [Int: [LineMark]] {
        var marks: [Int: [LineMark]] = [:]
        for match in query.matches(in: root) {
            guard let node = match.first("m") else { continue }
            let entry = entries[match.pattern]
            let mark = LineMark(kind: entry.kind, label: entry.label.replacingOccurrences(of: "%", with: node.text))
            if !(marks[node.startLine]?.contains(mark) ?? false) { marks[node.startLine, default: []].append(mark) }
        }
        return marks
    }
}
