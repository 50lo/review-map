import Foundation
import TreeSitter
import TreeSitterGo

// Go parsing with tree-sitter: declarations come from a walk over the tree, references and risk marks
// from queries. Methods are declared outside their type, so they are scoped to their receiver's type, and
// belong to it as children when the type is declared in the same file.

enum GoExtractor {
    static func parse(path: String, source: String) -> ParsedFile {
        let tree = SyntaxTree(source: source, language: Grammar.shared.language)
        let root = tree.root
        var walker = DeclWalker()
        walker.file(root)
        let refs = References(root: root, query: Grammar.shared.references, isTest: path.hasSuffix("_test.go"))
        var file = ParsedFile(path: path, language: "go", decls: walker.decls, imports: refs.imports,
                              typeRefs: refs.typeRefs, memberRefs: refs.memberRefs, marks: marks(root))
        file.isGenerated = GoLanguage.isGenerated(source: source)
        return file
    }

    struct Grammar: @unchecked Sendable {
        let language: OpaquePointer
        let references: SyntaxQuery
        let risk: SyntaxQuery

        static let shared = Grammar()

        private init() {
            language = tree_sitter_go()
            // The queries are fixed, so a failure here is a bug in them.
            // swiftlint:disable force_try
            references = try! SyntaxQuery(referenceQuery, language: language)
            risk = try! SyntaxQuery(riskTable.map(\.pattern).joined(separator: "\n"), language: language)
            // swiftlint:enable force_try
        }
    }

    // MARK: Risk marks

    /// One risk signal: a pattern whose `@m` capture is marked. `%` in the label stands for the captured text.
    struct RiskEntry {
        var kind: LineMark.Kind
        var label: String
        var pattern: String
        /// A check the query can't express, on the `@m` node.
        var keep: ((SyntaxNode) -> Bool)? = nil
    }

    private static let earlyReturn = #"[(if_statement consequence: (block (statement_list (return_statement) @m))) (if_statement alternative: (block (statement_list (return_statement) @m)))]"#

    static let riskTable: [RiskEntry] = [
        RiskEntry(kind: .crash, label: "panic", pattern: #"(call_expression function: (identifier) @m (#eq? @m "panic"))"#),
        RiskEntry(kind: .crash, label: "log.%", pattern: #"(call_expression function: (selector_expression operand: (identifier) @o field: (field_identifier) @m) (#eq? @o "log") (#match? @m "^(Fatal|Panic)"))"#),
        RiskEntry(kind: .crash, label: "os.Exit", pattern: #"(call_expression function: (selector_expression operand: (identifier) @o field: (field_identifier) @m) (#eq? @o "os") (#eq? @m "Exit"))"#),
        RiskEntry(kind: .crash, label: "type assertion", pattern: #"(type_assertion_expression) @m"#, keep: { !GoExtractor.checksOK($0) }),
        RiskEntry(kind: .crash, label: "unsafe", pattern: #"(qualified_type package: (package_identifier) @m (#eq? @m "unsafe"))"#),
        RiskEntry(kind: .crash, label: "unsafe", pattern: #"(selector_expression operand: (identifier) @m (#eq? @m "unsafe"))"#),
        RiskEntry(kind: .crash, label: "ignored error", pattern: #"(assignment_statement left: (expression_list (identifier) @m .) right: (expression_list . (call_expression) .) (#eq? @m "_"))"#),
        RiskEntry(kind: .crash, label: "ignored error", pattern: #"(short_var_declaration left: (expression_list (identifier) @m .) right: (expression_list . (call_expression) .) (#eq? @m "_"))"#),
        RiskEntry(kind: .check, label: "early return", pattern: earlyReturn),
        RiskEntry(kind: .flow, label: "early return", pattern: earlyReturn),
        RiskEntry(kind: .flow, label: "recover", pattern: #"(call_expression function: (identifier) @m (#eq? @m "recover"))"#),
        RiskEntry(kind: .flow, label: "if", pattern: #"(if_statement) @m"#),
        RiskEntry(kind: .flow, label: "switch", pattern: #"[(expression_switch_statement) (type_switch_statement)] @m"#),
        RiskEntry(kind: .flow, label: "select", pattern: #"(select_statement) @m"#),
        RiskEntry(kind: .flow, label: "for", pattern: #"(for_statement) @m"#),
        RiskEntry(kind: .flow, label: "defer", pattern: #"(defer_statement) @m"#),
        RiskEntry(kind: .flow, label: "break", pattern: #"(break_statement) @m"#),
        RiskEntry(kind: .flow, label: "continue", pattern: #"(continue_statement) @m"#),
        RiskEntry(kind: .flow, label: "goto", pattern: #"(goto_statement) @m"#),
        RiskEntry(kind: .concurrency, label: "go", pattern: #"(go_statement) @m"#),
        RiskEntry(kind: .concurrency, label: "select", pattern: #"(select_statement) @m"#),
        RiskEntry(kind: .concurrency, label: "sync.%", pattern: #"(qualified_type package: (package_identifier) @o name: (type_identifier) @m (#eq? @o "sync") (#any-of? @m "Mutex" "RWMutex" "WaitGroup" "Once" "Cond"))"#),
        RiskEntry(kind: .concurrency, label: "atomic", pattern: #"(selector_expression operand: (identifier) @m (#eq? @m "atomic"))"#),
    ]

    /// A type assertion whose second result (`v, ok := x.(T)`) or type switch checks it.
    static func checksOK(_ n: SyntaxNode) -> Bool {
        guard let list = n.parent, list.type == "expression_list", let statement = list.parent,
              ["short_var_declaration", "assignment_statement", "var_spec"].contains(statement.type) else { return false }
        let left = statement.child("left")?.namedChildren.count ?? statement.children("name").count
        return left == 2
    }

    private static func marks(_ root: SyntaxNode) -> [Int: [LineMark]] {
        var marks: [Int: [LineMark]] = [:]
        for match in Grammar.shared.risk.matches(in: root) {
            guard let node = match.first("m") else { continue }
            let entry = riskTable[match.pattern]
            if let keep = entry.keep, !keep(node) { continue }
            let m = LineMark(kind: entry.kind, label: entry.label.replacingOccurrences(of: "%", with: node.text))
            if !(marks[node.startLine]?.contains(m) ?? false) { marks[node.startLine, default: []].append(m) }
        }
        return marks
    }

    // MARK: References

    static let referenceQuery = """
        (qualified_type package: (package_identifier) @ns name: (type_identifier) @member)
        (selector_expression operand: (identifier) @ns field: (field_identifier) @member)
        (selector_expression field: (field_identifier) @member)
        (identifier) @id
        (type_identifier) @id
        """

    /// The package name an import path binds when the import has no name: its last element, without a major
    /// version (`.../v2`, `gopkg.in/yaml.v3`). A package may declare another name; those need an alias to match.
    static func packageName(_ path: String) -> String {
        var parts = path.split(separator: "/").map(String.init)
        if parts.count > 1, let last = parts.last, last.range(of: #"^v[0-9]+$"#, options: .regularExpression) != nil { parts.removeLast() }
        var name = parts.last ?? path
        if let r = name.range(of: #"\.v[0-9]+$"#, options: .regularExpression) { name.removeSubrange(r) }
        if name.hasPrefix("go-") { name = String(name.dropFirst(3)) }
        if name.hasSuffix("-go") || name.hasSuffix(".go") { name = String(name.dropLast(3)) }
        return name.replacingOccurrences(of: "-", with: "_")
    }

    /// What a file imports, and the names it uses from them. `pkg.Name` comes from the package `pkg` names.
    /// Unqualified names are the file's own package's, which only reach another component from a test file
    /// (tests are a component of their own) or through a dot import.
    private struct References {
        var imports: [NameRef] = []
        var typeRefs: [NameRef] = []
        var memberRefs: [NameRef] = []

        init(root: SyntaxNode, query: SyntaxQuery, isTest: Bool) {
            var bindings: [String: String] = [:]
            var dotImports: [String] = []
            var body: [SyntaxNode] = []
            for decl in root.namedChildren {
                guard decl.type == "import_declaration" else {
                    if decl.type != "package_clause" { body.append(decl) }
                    continue
                }
                var specs: [SyntaxNode] = []
                for c in decl.namedChildren {
                    if c.type == "import_spec" { specs.append(c) }
                    if c.type == "import_spec_list" { specs += c.namedChildren.filter { $0.type == "import_spec" } }
                }
                for spec in specs {
                    guard let pathNode = spec.child("path") else { continue }
                    let path = String(pathNode.text.dropFirst().dropLast())
                    imports.append(NameRef(name: path, line: spec.startLine))
                    switch spec.child("name")?.type {
                    case "blank_identifier": break
                    case "dot": dotImports.append(path)
                    case "package_identifier": bindings[spec.child("name")!.text] = path
                    default: bindings[GoExtractor.packageName(path)] = path
                    }
                }
            }
            let dotModule = dotImports.count == 1 ? dotImports[0] : nil
            for decl in body {
                for match in query.matches(in: decl) {
                    if let member = match.first("member") {
                        if let ns = match.first("ns") {
                            if let path = bindings[ns.text] {
                                typeRefs.append(NameRef(name: member.text, line: member.startLine, module: path))
                            }
                        } else if member.parent?.child("operand").map({ bindings[$0.text] == nil }) ?? true {
                            memberRefs.append(NameRef(name: member.text, line: member.startLine))
                        }
                    } else if let id = match.first("id") {
                        // Kept for definition and caller context in the file's own package. The empty module keeps
                        // them out of cross-component resolution, except in tests and through dot imports.
                        let module: String?
                        if isTest {
                            module = nil
                        } else if !dotImports.isEmpty, id.text.first?.isUppercase == true {
                            module = dotModule
                        } else {
                            module = ""
                        }
                        typeRefs.append(NameRef(name: id.text, line: id.startLine, module: module))
                    }
                }
            }
        }
    }
}

// MARK: - Declarations

private struct DeclWalker {
    var decls: [Declaration] = []
    /// Index of each type declared in the file, for its methods.
    private var types: [String: Int] = [:]

    mutating func file(_ root: SyntaxNode) {
        // Types first, so that a method declared above its type still finds it.
        let top = root.namedChildren
        for n in top where n.type == "type_declaration" { typeDeclaration(n) }
        for n in top {
            switch n.type {
            case "function_declaration": function(n)
            case "method_declaration": method(n)
            case "const_declaration", "var_declaration": values(n)
            default: break
            }
        }
    }

    // MARK: Types

    private mutating func typeDeclaration(_ n: SyntaxNode) {
        let specs = n.namedChildren.filter { $0.type == "type_spec" || $0.type == "type_alias" }
        for spec in specs {
            // A single spec spans the whole declaration (`type` included); in a group, each spans its own text.
            let outer = specs.count == 1 ? n : spec
            guard let nameNode = spec.child("name") else { continue }
            let name = nameNode.text
            let type = spec.child("type")
            let headerStart = specs.count == 1 ? n.startByte : spec.startByte
            switch (spec.type, type?.type) {
            case ("type_spec", "struct_type"?):
                let fields = type!.namedChildren.first { $0.type == "field_declaration_list" }
                let index = container(outer: outer, kind: .struct, name: name, headerStart: headerStart, body: fields, inherited: [])
                for f in fields?.namedChildren ?? [] where f.type == "field_declaration" { field(f, parent: index, scope: name) }
            case ("type_spec", "interface_type"?):
                let body = type!.children.first { $0.type == "{" }
                let elements = type!.namedChildren
                let typeElements = elements.filter { $0.type == "type_elem" }
                // Embedded interfaces and type constraints are part of the method set, so they are compared with the header.
                let index = container(outer: outer, kind: .protocol, name: name, headerStart: headerStart, body: body,
                                      inherited: typeElements.flatMap { $0.namedChildren.map(Self.typeName) },
                                      elements: typeElements.flatMap(\.tokens))
                for m in elements where m.type == "method_elem" { interfaceMethod(m, parent: index, scope: name) }
            default:
                let tokens = n.tokens.filter { $0.startByte >= headerStart && $0.endByte <= outer.endByte }
                types[name] = add(outer, kind: .typealias, name: name, labelsKey: name, qualified: name, header: tokens, body: nil)
            }
        }
    }

    private mutating func container(outer: SyntaxNode, kind: EntityKind, name: String, headerStart: Int,
                                    body: SyntaxNode?, inherited: [String], elements: [SyntaxNode] = []) -> Int {
        let end = body?.startByte ?? outer.endByte
        let header = outer.tokens.filter { $0.startByte >= headerStart && $0.startByte < end } + elements
        let index = add(outer, kind: kind, name: name, labelsKey: name, qualified: name, header: header, body: nil,
                        inherited: inherited, rawEnd: end, headerEnd: body)
        types[name] = index
        return index
    }

    private mutating func field(_ f: SyntaxNode, parent: Int, scope: String) {
        guard let type = f.child("type") else { return }
        let names = f.children("name")
        let tag = f.child("tag").map { String($0.text.dropFirst().dropLast()) }
        let tagEnd = f.child("tag")?.startByte ?? Int.max
        // An embedded field is named by its type.
        let declared = names.isEmpty ? [(Self.typeName(type), f)] : names.map { ($0.text, $0) }
        for (name, _) in declared {
            let header = (names.isEmpty ? f.tokens : [names.first { $0.text == name }!] + type.tokens).filter { $0.startByte < tagEnd }
            var traits = Set<String>()
            if let tag { traits.insert("tag:" + tag) }
            if names.isEmpty { traits.insert("embedded") }
            // The tag is compared with the modifiers: changing it changes the field's contract, not its type.
            add(f, kind: .var, name: name, labelsKey: name, qualified: scope + "." + name, header: header, body: nil,
                scope: scope, parent: parent, parentKind: .struct, stored: true, type: type, traits: traits, tag: tag)
        }
    }

    private mutating func interfaceMethod(_ m: SyntaxNode, parent: Int, scope: String) {
        guard let name = m.child("name")?.text else { return }
        add(m, kind: .func, name: name, labelsKey: name + Self.labels(m.child("parameters")), qualified: "\(scope).\(name)()",
            header: m.tokens, body: nil, scope: scope, parent: parent, parentKind: .protocol)
    }

    // MARK: Functions

    private mutating func function(_ n: SyntaxNode) {
        guard let name = n.child("name")?.text else { return }
        let body = n.child("body")
        add(n, kind: .func, name: name, labelsKey: name + Self.labels(n.child("parameters")), qualified: name + "()",
            header: n.tokens.filter { $0.startByte < (body?.startByte ?? Int.max) }, body: body)
    }

    private mutating func method(_ n: SyntaxNode) {
        guard let name = n.child("name")?.text,
              let receiver = n.child("receiver")?.namedChildren.first(where: { $0.type == "parameter_declaration" }),
              let receiverType = receiver.child("type") else { return }
        let type = Self.typeName(receiverType)
        let body = n.child("body")
        let parent = types[type]
        var traits = Set<String>()
        if receiverType.type == "pointer_type" { traits.insert("pointer-receiver") }
        add(n, kind: .func, name: name, labelsKey: name + Self.labels(n.child("parameters")), qualified: "\(type).\(name)()",
            header: n.tokens.filter { $0.startByte < (body?.startByte ?? Int.max) }, body: body,
            scope: type, parent: parent, parentKind: parent.map { decls[$0].kind }, traits: traits)
    }

    // MARK: Constants and variables

    private mutating func values(_ n: SyntaxNode) {
        let keyword = n.children.first { !$0.isNamed }
        var specs: [SyntaxNode] = []
        for c in n.namedChildren {
            if c.type == "const_spec" || c.type == "var_spec" { specs.append(c) }
            if c.type == "var_spec_list" { specs += c.namedChildren.filter { $0.type == "var_spec" } }
        }
        let isConst = n.type == "const_declaration"
        for spec in specs {
            let names = spec.children("name").filter { $0.type == "identifier" }
            let value = spec.child("value")
            for (i, nameNode) in names.enumerated() {
                let name = nameNode.text
                if name == "_" { continue }
                let outer = specs.count == 1 && names.count == 1 ? n : spec
                var header = [nameNode] + (spec.child("type")?.tokens ?? [])
                if let keyword { header.insert(keyword, at: 0) }
                // With several names, each one's value is its own element of the list.
                let values = value?.namedChildren ?? []
                let own = names.count > 1 && values.count == names.count ? values[i] : value
                add(outer, kind: .var, name: name, labelsKey: name, qualified: name, header: header, body: own,
                    modifiers: isConst ? ["const"] : [], stored: true, type: spec.child("type"))
            }
        }
    }

    // MARK: Helpers

    /// "(a:b:_:)" from the parameter names, with `_` for unnamed ones: one label per parameter, so its arity.
    static func labels(_ params: SyntaxNode?) -> String {
        guard let params else { return "()" }
        var out: [String] = []
        for p in params.namedChildren where p.type == "parameter_declaration" || p.type == "variadic_parameter_declaration" {
            let names = p.children("name")
            out += names.isEmpty ? ["_"] : names.map(\.text)
        }
        return "(" + out.map { $0 + ":" }.joined() + ")"
    }

    /// "Cart" for `Cart`, `*Cart`, `Cart[T]`, `shop.Cart`, and `*shop.Cart[T]`.
    static func typeName(_ t: SyntaxNode) -> String {
        switch t.type {
        case "pointer_type", "parenthesized_type":
            return t.namedChildren.last.map(typeName) ?? t.text
        case "generic_type":
            return t.child("type").map(typeName) ?? t.text
        case "qualified_type":
            return t.child("name")?.text ?? t.text
        default:
            return t.text
        }
    }

    @discardableResult
    private mutating func add(_ n: SyntaxNode, kind: EntityKind, name: String, labelsKey: String, qualified: String,
                              header: [SyntaxNode], body: SyntaxNode?, scope: String? = nil, parent: Int? = nil,
                              parentKind: EntityKind? = nil, modifiers: [String] = [], inherited: [String] = [],
                              rawEnd: Int? = nil, headerEnd: SyntaxNode? = nil, stored: Bool = false,
                              type: SyntaxNode? = nil, traits: Set<String> = [], tag: String? = nil) -> Int {
        var d = Declaration(
            kind: kind, name: name, qualifiedName: qualified, scope: scope, parentIndex: parent, labelsKey: labelsKey,
            signatureDisplay: header.display, signatureCanon: header.canon,
            modifiersCanon: (modifiers + (tag.map { [$0] } ?? [])).joined(separator: " "), bodyCanon: body.map { $0.tokens.canon } ?? "",
            rawText: n.tree.text(n.startByte, max(n.startByte, rawEnd ?? n.endByte)),
            access: name.first?.isUppercase == true ? "public" : "internal",
            attributes: [], modifiers: modifiers, inherited: inherited,
            inProtocol: parentKind == .protocol, parentKind: parentKind, startLine: n.startLine, endLine: n.endLine)
        d.isStored = stored
        d.typeAnnotation = type?.text
        d.headerEndLine = max(n.startLine, (headerEnd ?? body)?.startLine ?? n.endLine)
        d.traits = traits
        decls.append(d)
        return decls.count - 1
    }
}
