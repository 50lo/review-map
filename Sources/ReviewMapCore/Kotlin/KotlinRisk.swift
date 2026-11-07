import Foundation
import TreeSitterKotlin

enum KotlinRisk {
    struct Entry {
        let kind: LineMark.Kind
        let label: String
        let pattern: String
    }
    static let entries: [Entry] = [
        Entry(kind: .crash, label: "non-null assertion", pattern: #"(postfix_expression "!!" @m)"#),
        Entry(kind: .crash, label: "lateinit", pattern: #"(member_modifier "lateinit" @m)"#),
        Entry(kind: .crash, label: "unchecked cast", pattern: #"(as_expression "as" @m)"#),
        Entry(kind: .crash, label: "%", pattern: #"(call_expression (simple_identifier) @m (#any-of? @m "TODO" "error"))"#),
        Entry(kind: .crash, label: "%", pattern: #"(call_expression (navigation_expression (navigation_suffix (simple_identifier) @m)) (#any-of? @m "TODO" "error"))"#),
        Entry(kind: .check, label: "%", pattern: #"(call_expression (simple_identifier) @m (#any-of? @m "check" "require"))"#),
        Entry(kind: .check, label: "%", pattern: #"(call_expression (navigation_expression (navigation_suffix (simple_identifier) @m)) (#any-of? @m "check" "require"))"#),
        Entry(kind: .concurrency, label: "runBlocking", pattern: #"(call_expression (simple_identifier) @m (#eq? @m "runBlocking"))"#),
        Entry(kind: .concurrency, label: "runBlocking", pattern: #"(call_expression (navigation_expression (navigation_suffix (simple_identifier) @m)) (#eq? @m "runBlocking"))"#),
        Entry(kind: .concurrency, label: "GlobalScope", pattern: #"(navigation_expression (simple_identifier) @m (#eq? @m "GlobalScope"))"#),
        Entry(kind: .isolation, label: "Dispatchers.Main", pattern: #"(navigation_expression (simple_identifier) @owner (navigation_suffix (simple_identifier) @m) (#eq? @owner "Dispatchers") (#eq? @m "Main"))"#),
        Entry(kind: .isolation, label: "withContext", pattern: #"(call_expression (simple_identifier) @m (#eq? @m "withContext"))"#),
        Entry(kind: .isolation, label: "withContext", pattern: #"(call_expression (navigation_expression (navigation_suffix (simple_identifier) @m)) (#eq? @m "withContext"))"#),
        Entry(kind: .flow, label: "if", pattern: #"(if_expression) @m"#),
        Entry(kind: .flow, label: "when", pattern: #"(when_expression) @m"#),
        Entry(kind: .flow, label: "for", pattern: #"(for_statement) @m"#),
        Entry(kind: .flow, label: "while", pattern: #"(while_statement) @m"#),
    ]
    private static let query = try! SyntaxQuery(entries.map(\.pattern).joined(separator: "\n"), language: tree_sitter_kotlin()!)
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
