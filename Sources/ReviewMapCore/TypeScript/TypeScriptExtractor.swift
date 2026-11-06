import Foundation
import TreeSitter
import TreeSitterTSX
import TreeSitterTypeScript

// TypeScript parsing with tree-sitter: declarations come from a walk over the tree, references and
// risk marks from queries. `.tsx` files use the TSX grammar.

enum TypeScriptExtractor {
    static func parse(path: String, source: String) -> ParsedFile {
        let grammar = Grammar.of(path)
        let tree = SyntaxTree(source: source, language: grammar.language)
        let root = tree.root
        var walker = DeclWalker()
        walker.statements(root, ctx: Context())
        let refs = References(root: root, query: grammar.references)
        return ParsedFile(path: path, language: "typescript", decls: walker.decls, imports: refs.imports,
                          typeRefs: refs.typeRefs, memberRefs: refs.memberRefs, marks: marks(root, grammar))
    }

    /// The two grammars, each with its queries compiled once.
    struct Grammar: @unchecked Sendable {
        let language: OpaquePointer
        let references: SyntaxQuery
        let risk: SyntaxQuery
        /// The entry of `riskTable` behind each pattern of `risk`.
        let riskEntries: [RiskEntry]

        static let typescript = Grammar(tree_sitter_typescript())
        static let tsx = Grammar(tree_sitter_tsx())

        static func of(_ path: String) -> Grammar { path.hasSuffix(".tsx") ? tsx : typescript }

        private init(_ language: OpaquePointer) {
            self.language = language
            // The queries are fixed, so a failure here is a bug in them.
            // swiftlint:disable force_try
            references = try! SyntaxQuery(referenceQuery, language: language)
            // A pattern that names a node the grammar lacks (TSX has no `<T>x` assertions) is left out.
            let entries = riskTable.filter { (try? SyntaxQuery($0.pattern, language: language)) != nil }
            risk = try! SyntaxQuery(entries.map(\.pattern).joined(separator: "\n"), language: language)
            // swiftlint:enable force_try
            riskEntries = entries
        }
    }

    // MARK: Risk marks

    /// One risk signal: a pattern whose `@m` capture is marked. `%` in the label stands for the captured text.
    struct RiskEntry {
        var kind: LineMark.Kind
        var label: String
        var pattern: String
    }

    static let riskTable: [RiskEntry] = [
        RiskEntry(kind: .crash, label: "non-null assertion", pattern: #"(non_null_expression "!" @m)"#),
        RiskEntry(kind: .crash, label: "type assertion", pattern: #"((as_expression) @m (#not-match? @m "as\\s+const$"))"#),
        RiskEntry(kind: .crash, label: "type assertion", pattern: #"(type_assertion) @m"#),
        RiskEntry(kind: .crash, label: "any", pattern: #"((predefined_type) @m (#eq? @m "any"))"#),
        RiskEntry(kind: .crash, label: "type check suppressed", pattern: #"((comment) @m (#match? @m "@ts-(ignore|expect-error|nocheck)"))"#),
        RiskEntry(kind: .check, label: "throw", pattern: #"(throw_statement) @m"#),
        RiskEntry(kind: .flow, label: "throw", pattern: #"(throw_statement) @m"#),
        RiskEntry(kind: .check, label: "early return", pattern: #"[(if_statement consequence: (return_statement) @m) (if_statement consequence: (statement_block (return_statement) @m)) (else_clause (return_statement) @m) (else_clause (statement_block (return_statement) @m))]"#),
        RiskEntry(kind: .flow, label: "early return", pattern: #"[(if_statement consequence: (return_statement) @m) (if_statement consequence: (statement_block (return_statement) @m)) (else_clause (return_statement) @m) (else_clause (statement_block (return_statement) @m))]"#),
        RiskEntry(kind: .check, label: "%", pattern: #"(call_expression function: (identifier) @m (#any-of? @m "assert" "invariant"))"#),
        RiskEntry(kind: .check, label: "assert", pattern: #"(call_expression function: (member_expression object: (identifier) @o property: (property_identifier) @m) (#any-of? @o "assert" "console") (#match? @m "^(assert|ok|equal|strictEqual|deepEqual|deepStrictEqual)$"))"#),
        RiskEntry(kind: .flow, label: "if", pattern: #"(if_statement) @m"#),
        RiskEntry(kind: .flow, label: "switch", pattern: #"(switch_statement) @m"#),
        RiskEntry(kind: .flow, label: "?:", pattern: #"(ternary_expression) @m"#),
        RiskEntry(kind: .flow, label: "for", pattern: #"[(for_statement) (for_in_statement)] @m"#),
        RiskEntry(kind: .flow, label: "while", pattern: #"[(while_statement) (do_statement)] @m"#),
        RiskEntry(kind: .flow, label: "catch", pattern: #"(catch_clause) @m"#),
        RiskEntry(kind: .flow, label: "catch", pattern: #"(call_expression function: (member_expression property: (property_identifier) @m (#eq? @m "catch")))"#),
        RiskEntry(kind: .flow, label: "break", pattern: #"(break_statement) @m"#),
        RiskEntry(kind: .flow, label: "continue", pattern: #"(continue_statement) @m"#),
        RiskEntry(kind: .concurrency, label: "new Promise", pattern: #"(new_expression constructor: (identifier) @m (#eq? @m "Promise"))"#),
        RiskEntry(kind: .concurrency, label: "Promise.%", pattern: #"(call_expression function: (member_expression object: (identifier) @o property: (property_identifier) @m) (#eq? @o "Promise") (#any-of? @m "all" "allSettled" "race" "any"))"#),
        RiskEntry(kind: .concurrency, label: "%", pattern: #"(call_expression function: (identifier) @m (#any-of? @m "setTimeout" "setInterval" "setImmediate" "queueMicrotask" "requestAnimationFrame"))"#),
        RiskEntry(kind: .concurrency, label: "new %", pattern: #"(new_expression constructor: (identifier) @m (#any-of? @m "Worker" "SharedWorker" "SharedArrayBuffer" "MessageChannel"))"#),
        RiskEntry(kind: .concurrency, label: "Atomics", pattern: #"(member_expression object: (identifier) @m (#eq? @m "Atomics"))"#),
    ]

    private static func marks(_ root: SyntaxNode, _ grammar: Grammar) -> [Int: [LineMark]] {
        var marks: [Int: [LineMark]] = [:]
        for match in grammar.risk.matches(in: root) {
            guard let node = match.first("m") else { continue }
            let entry = grammar.riskEntries[match.pattern]
            let m = LineMark(kind: entry.kind, label: entry.label.replacingOccurrences(of: "%", with: node.text))
            if !(marks[node.startLine]?.contains(m) ?? false) { marks[node.startLine, default: []].append(m) }
        }
        return marks
    }

    // MARK: References

    static let referenceQuery = """
        (identifier) @id
        (type_identifier) @id
        (shorthand_property_identifier) @id
        (nested_type_identifier module: (identifier) @ns name: (type_identifier) @member)
        (member_expression object: (identifier) @ns property: (property_identifier) @member)
        (member_expression property: (property_identifier) @member)
        (call_expression function: (import) arguments: (arguments (string (string_fragment) @module)))
        (call_expression function: (identifier) @require arguments: (arguments (string (string_fragment) @module)) (#eq? @require "require"))
        """

    /// What a file imports, and the uses of imported names. A name declared in another file has to be imported
    /// before it can be used, so only imported names are reference candidates, each with the file it comes from.
    private struct References {
        var imports: [NameRef] = []
        var typeRefs: [NameRef] = []
        var memberRefs: [NameRef] = []

        private struct Binding {
            /// The exported name, or nil for a namespace import (`import * as api`).
            var name: String?
            /// The file of a relative import, or the package of a bare one.
            var source: String?
            var module: String?
        }

        init(root: SyntaxNode, query: SyntaxQuery) {
            var bindings: [String: Binding] = [:]
            var body: [SyntaxNode] = []
            for stmt in root.namedChildren {
                switch stmt.type {
                case "import_statement":
                    let spec = Self.specifier(stmt.child("source"))
                        ?? stmt.namedChildren.first { $0.type == "import_require_clause" }.flatMap { Self.specifier($0.child("source")) }
                    guard let spec else { continue }
                    let (source, module) = addImport(spec, line: stmt.startLine)
                    for clause in stmt.namedChildren where clause.type == "import_clause" || clause.type == "import_require_clause" {
                        for part in clause.namedChildren {
                            switch part.type {
                            case "identifier":
                                bindings[part.text] = Binding(name: clause.type == "import_clause" ? part.text : nil, source: source, module: module)
                            case "namespace_import":
                                if let id = part.namedChildren.first { bindings[id.text] = Binding(name: nil, source: source, module: module) }
                            case "named_imports":
                                for s in part.namedChildren where s.type == "import_specifier" {
                                    guard let name = s.child("name") else { continue }
                                    bindings[(s.child("alias") ?? name).text] = Binding(name: name.text, source: source, module: module)
                                }
                            default: break
                            }
                        }
                    }
                case "export_statement" where stmt.child("source") != nil:
                    // A re-export (`export { Cart } from "./cart"`) uses the names it passes on.
                    guard let spec = Self.specifier(stmt.child("source")) else { continue }
                    let (source, module) = addImport(spec, line: stmt.startLine)
                    for clause in stmt.namedChildren where clause.type == "export_clause" {
                        for s in clause.namedChildren where s.type == "export_specifier" {
                            if let name = s.child("name") { typeRefs.append(NameRef(name: name.text, line: s.startLine, source: source, module: module)) }
                        }
                    }
                default:
                    body.append(stmt)
                }
            }
            for stmt in body {
                for match in query.matches(in: stmt) {
                    if let id = match.first("id"), let b = bindings[id.text], let name = b.name {
                        typeRefs.append(NameRef(name: name, line: id.startLine, source: b.source, module: b.module))
                    } else if let module = match.first("module") {
                        addImport(module.text, line: module.startLine)
                    } else if let member = match.first("member") {
                        if let ns = match.first("ns") {
                            if let b = bindings[ns.text], b.name == nil {
                                typeRefs.append(NameRef(name: member.text, line: member.startLine, source: b.source, module: b.module))
                            }
                        } else {
                            memberRefs.append(NameRef(name: member.text, line: member.startLine))
                        }
                    }
                }
            }
        }

        private static func specifier(_ string: SyntaxNode?) -> String? {
            guard let string else { return nil }
            return string.namedChildren.first { $0.type == "string_fragment" }?.text
        }

        /// Records an import of a package. Returns the path a relative import names (without its extension), or
        /// the package a bare one names.
        @discardableResult
        private mutating func addImport(_ spec: String, line: Int) -> (source: String?, module: String?) {
            if spec.hasPrefix(".") || spec.hasPrefix("/") {
                return (TypeScriptLanguage.importPath(spec), nil)
            }
            let package = TypeScriptLanguage.packageName(spec)
            if let package { imports.append(NameRef(name: package, line: line)) }
            return (nil, package)
        }
    }
}

// MARK: - Declarations

/// Keywords and decorators that a wrapper (`export`, `declare`) or a preceding line (a member's decorators)
/// adds to a declaration.
private struct Context {
    var outer: SyntaxNode?
    var modifiers: [String] = []
    var decorators: [SyntaxNode] = []
}

private let modifierKeywords: Set<String> = ["export", "default", "declare", "abstract", "static", "readonly", "async",
                                             "override", "accessor", "const", "get", "set", "*"]
private let functionValues: Set<String> = ["arrow_function", "function_expression", "generator_function", "function"]

private struct DeclWalker {
    var decls: [Declaration] = []

    private struct Scope {
        var qualified: String?
        var index: Int?
        var kind: EntityKind?
    }
    private var stack: [Scope] = [Scope(qualified: nil, index: nil, kind: nil)]
    private var current: Scope { stack[stack.count - 1] }

    private func qualify(_ name: String) -> String {
        current.qualified.map { $0 + "." + name } ?? name
    }

    mutating func statements(_ block: SyntaxNode, ctx: Context) {
        for stmt in block.namedChildren { statement(stmt, ctx: ctx) }
    }

    private mutating func statement(_ n: SyntaxNode, ctx: Context) {
        var ctx = ctx
        switch n.type {
        case "export_statement":
            ctx.outer = ctx.outer ?? n
            ctx.modifiers.append("export")
            if n.children.contains(where: { $0.type == "default" && !$0.isNamed }) { ctx.modifiers.append("default") }
            ctx.decorators += n.namedChildren.filter { $0.type == "decorator" }
            if let d = n.child("declaration") {
                statement(d, ctx: ctx)
            } else if let v = n.child("value"), functionValues.contains(v.type) || v.type == "class" {
                statement(v, ctx: ctx)
            }
        case "ambient_declaration":
            ctx.outer = ctx.outer ?? n
            ctx.modifiers.append("declare")
            for c in n.namedChildren {
                if c.type == "statement_block" { statements(c, ctx: Context()) } else { statement(c, ctx: ctx) }
            }
        case "class_declaration", "abstract_class_declaration", "class":
            container(n, kind: .class, keyword: "class", ctx: ctx)
        case "interface_declaration":
            container(n, kind: .protocol, keyword: "interface", ctx: ctx)
        case "enum_declaration":
            container(n, kind: .enum, keyword: "enum", ctx: ctx)
        case "type_alias_declaration":
            let header = keywordStart(n, "type") ?? n.startByte
            add(n, ctx: ctx, kind: .typealias, name: n.child("name")?.text ?? "", labelsKey: n.child("name")?.text ?? "",
                header: n.tokens.filter { $0.startByte >= header }, body: nil)
        case "function_declaration", "generator_function_declaration", "function_signature", "function_expression", "generator_function":
            let name = n.child("name")?.text ?? "default"
            let body = n.child("body")
            let start = keywordStart(n, "function") ?? n.startByte
            add(n, ctx: ctx, kind: .func, name: name, labelsKey: name + labels(n), qualified: qualify(name + "()"),
                header: n.tokens.filter { $0.startByte >= start && $0.startByte < (body?.startByte ?? Int.max) }, body: body)
        case "lexical_declaration", "variable_declaration":
            variables(n, ctx: ctx)
        case "module", "internal_module":
            guard let name = n.child("name"), let body = n.child("body") else { return }
            let label = name.type == "string" ? (name.namedChildren.first?.text ?? name.text) : name.text
            stack.append(Scope(qualified: qualify(label), index: current.index, kind: current.kind))
            statements(body, ctx: Context())
            stack.removeLast()
        case "expression_statement":
            for c in n.namedChildren where c.type == "internal_module" { statement(c, ctx: ctx) }
        default:
            break
        }
    }

    /// Start of the first anonymous `keyword` token among a node's children.
    private func keywordStart(_ n: SyntaxNode, _ keyword: String) -> Int? {
        n.children.first { !$0.isNamed && $0.type == keyword }?.startByte
    }

    /// "(a:b:)" from the parameter names, to pair overloads.
    private func labels(_ n: SyntaxNode) -> String {
        guard let params = n.child("parameters") else { return "()" }
        let names = params.namedChildren.map { p in (p.child("pattern") ?? p).text }
        return "(" + names.map { $0 + ":" }.joined() + ")"
    }

    private func baseName(_ t: SyntaxNode) -> String {
        let n = t.type == "generic_type" ? (t.child("name") ?? t) : t
        return String(n.text.split(separator: ".").last ?? Substring(n.text))
    }

    private mutating func container(_ n: SyntaxNode, kind: EntityKind, keyword: String, ctx: Context) {
        guard let body = n.child("body") else { return }
        let name = n.child("name")?.text ?? "default"
        var inherited: [String] = []
        for c in n.namedChildren {
            switch c.type {
            case "class_heritage":
                for clause in c.namedChildren {
                    // `extends` comes first, so the superclass is the first inherited name.
                    inherited += clause.namedChildren.filter { $0.type != "type_arguments" }.map(baseName)
                }
            case "extends_type_clause":
                inherited += c.namedChildren.map(baseName)
            default: break
            }
        }
        let start = keywordStart(n, keyword) ?? n.startByte
        // Supertypes stay in the compared header, type arguments included (`Base<string>` -> `Base<number>`).
        let header = n.tokens.filter { $0.startByte >= start && $0.startByte < body.startByte }
        let index = add(n, ctx: ctx, kind: kind, name: name, labelsKey: name, header: header, body: nil,
                        inherited: inherited, headerEnd: body)
        stack.append(Scope(qualified: qualify(name), index: index, kind: kind))
        switch kind {
        case .enum:
            for m in body.namedChildren {
                let nameNode = m.type == "enum_assignment" ? m.child("name") : m
                guard let label = nameNode?.text else { continue }
                add(m, ctx: Context(), kind: .case, name: label, labelsKey: label, header: m.tokens, body: nil)
            }
        default:
            var decorators: [SyntaxNode] = []
            for m in body.namedChildren {
                if m.type == "decorator" {
                    decorators.append(m)
                    continue
                }
                member(m, ctx: Context(decorators: decorators))
                decorators = []
            }
        }
        stack.removeLast()
    }

    private mutating func member(_ n: SyntaxNode, ctx: Context) {
        guard let nameNode = n.child("name") ?? (n.type == "index_signature" ? n : nil) else {
            switch n.type {
            case "call_signature":
                add(n, ctx: ctx, kind: .func, name: "call", labelsKey: "call" + labels(n), qualified: qualify("call()"), header: n.tokens, body: nil)
            case "construct_signature":
                add(n, ctx: ctx, kind: .`init`, name: "new", labelsKey: "new" + labels(n), qualified: qualify("new()"), header: n.tokens, body: nil)
            default: break
            }
            return
        }
        let name = n.type == "index_signature" ? "[index]" : nameNode.text
        let fromName = n.tokens.filter { $0.startByte >= nameNode.startByte }
        switch n.type {
        case "method_definition", "method_signature", "abstract_method_signature":
            let body = n.child("body")
            let header = fromName.filter { $0.startByte < (body?.startByte ?? Int.max) }
            if let accessor = n.children.first(where: { !$0.isNamed && ($0.type == "get" || $0.type == "set") }) {
                let key = "\(accessor.type) \(name)"
                let header = n.tokens.filter { $0.startByte >= accessor.startByte && $0.startByte < (body?.startByte ?? Int.max) }
                add(n, ctx: ctx, kind: .var, name: name, labelsKey: key, qualified: qualify(key), header: header, body: body)
            } else if name == "constructor" {
                add(n, ctx: ctx, kind: .`init`, name: name, labelsKey: name + labels(n), qualified: qualify("constructor()"), header: header, body: body)
            } else {
                add(n, ctx: ctx, kind: .func, name: name, labelsKey: name + labels(n), qualified: qualify(name + "()"), header: header, body: body)
            }
        case "public_field_definition", "property_signature", "index_signature":
            let value = n.child("value")
            if let value, functionValues.contains(value.type) {
                let body = value.child("body")
                add(n, ctx: ctx, kind: .func, name: name, labelsKey: name + labels(value), qualified: qualify(name + "()"),
                    header: fromName.filter { $0.startByte < (body?.startByte ?? Int.max) }, body: body, function: value)
            } else {
                let header = fromName.filter { $0.startByte < (value?.startByte ?? Int.max) }
                add(n, ctx: ctx, kind: .var, name: name, labelsKey: name,
                    header: header.last?.type == "=" ? Array(header.dropLast()) : header, body: value,
                    stored: n.type == "public_field_definition", type: n.child("type"))
            }
        default:
            break
        }
    }

    private mutating func variables(_ n: SyntaxNode, ctx: Context) {
        guard let keyword = n.children.first(where: { !$0.isNamed }) else { return }
        let declarators = n.namedChildren.filter { $0.type == "variable_declarator" }
        for (i, v) in declarators.enumerated() {
            guard let nameNode = v.child("name"), nameNode.type == "identifier" else { continue }
            let name = nameNode.text
            // A single declarator spans the whole statement; with several, each spans its own text.
            var c = ctx
            if declarators.count > 1 {
                c.outer = i == 0 ? (ctx.outer ?? n) : v
                if i > 0 { c.decorators = [] }
            } else {
                c.outer = ctx.outer ?? n
            }
            let span = declarators.count > 1 ? v : n
            let value = v.child("value")
            if let value, functionValues.contains(value.type) {
                let body = value.child("body")
                add(span, ctx: c, kind: .func, name: name, labelsKey: name + labels(value), qualified: qualify(name + "()"),
                    header: [keyword] + v.tokens.filter { $0.startByte < (body?.startByte ?? Int.max) }, body: body, function: value)
            } else {
                var header = v.tokens.filter { $0.startByte < (value?.startByte ?? Int.max) }
                if header.last?.type == "=" { header.removeLast() }
                add(span, ctx: c, kind: .var, name: name, labelsKey: name, header: [keyword] + header, body: value,
                    stored: true, type: v.child("type"))
            }
        }
    }

    /// Adds a declaration. `n` is the declaration's own node; the context's outer node (an `export` or
    /// `declare`, or the first decorator) widens its lines.
    @discardableResult
    private mutating func add(_ n: SyntaxNode, ctx: Context, kind: EntityKind, name: String, labelsKey: String,
                              qualified: String? = nil, header: [SyntaxNode], body: SyntaxNode?,
                              inherited: [String] = [], headerEnd: SyntaxNode? = nil,
                              function: SyntaxNode? = nil, stored: Bool = false, type: SyntaxNode? = nil) -> Int {
        var modifiers = ctx.modifiers
        var access: String?
        var decorators = ctx.decorators
        for c in n.children {
            if c.type == "decorator" { decorators.append(c); continue }
            if c.type == "accessibility_modifier" { access = c.text; continue }
            if c.type == "override_modifier" { modifiers.append("override"); continue }
            if !c.isNamed, modifierKeywords.contains(c.type), !header.contains(where: { $0.isSame(c) }) {
                modifiers.append(c.type)
            }
        }
        var traits = Set<String>()
        if n.children.contains(where: { !$0.isNamed && $0.type == "?" }) { traits.insert("optional") }
        if let body, Self.containsJSX(body) { traits.insert("jsx") }
        if let function, function.children.contains(where: { !$0.isNamed && $0.type == "async" }) { modifiers.append("async") }
        if n.child("name")?.type == "private_property_identifier" { access = "#private" }
        let canonModifiers = (decorators.map { $0.tokens.canon } + (access.map { [$0] } ?? []) + modifiers).joined(separator: " ")
        let first = decorators.first ?? ctx.outer ?? n
        let start = min(first.startLine, ctx.outer?.startLine ?? n.startLine)
        let startByte = min(first.startByte, ctx.outer?.startByte ?? n.startByte)
        let containerKinds: Set<EntityKind> = [.class, .protocol, .enum]
        let rawEnd = containerKinds.contains(kind) ? (headerEnd?.startByte ?? n.endByte) : n.endByte
        // Semicolons are optional, so adding or dropping one is cosmetic.
        let header = header.last?.type == ";" ? Array(header.dropLast()) : header
        func canon(_ tokens: [SyntaxNode]) -> String { tokens.filter { $0.type != ";" }.canon }
        var d = Declaration(
            kind: kind, name: name, qualifiedName: qualified ?? qualify(name), scope: current.qualified,
            parentIndex: current.index, labelsKey: labelsKey,
            signatureDisplay: header.display, signatureCanon: canon(header),
            modifiersCanon: canonModifiers, bodyCanon: body.map { canon($0.tokens) } ?? "",
            rawText: n.tree.text(startByte, max(startByte, rawEnd)),
            access: access, attributes: decorators.map(decoratorName), modifiers: modifiers, inherited: inherited,
            isStatic: modifiers.contains("static"), inProtocol: current.kind == .protocol, parentKind: current.kind,
            startLine: start, endLine: n.endLine)
        d.isAsync = modifiers.contains("async")
        d.isStored = stored
        d.typeAnnotation = type.map { String($0.text.drop { $0 == ":" || $0 == " " }) }
        d.headerEndLine = max(start, (headerEnd ?? body)?.startLine ?? n.endLine)
        d.traits = traits
        decls.append(d)
        return decls.count - 1
    }

    private static func containsJSX(_ node: SyntaxNode) -> Bool {
        var found = false
        node.forEach { n in
            if n.type.hasPrefix("jsx_") { found = true }
            return !found
        }
        return found
    }

    /// "Component" for `@Component({...})`, "Input" for `@Input()`.
    private func decoratorName(_ d: SyntaxNode) -> String {
        guard let expr = d.namedChildren.first else { return d.text }
        let callee = expr.type == "call_expression" ? (expr.child("function") ?? expr) : expr
        return String(callee.text.split(separator: ".").last ?? Substring(callee.text))
    }
}
