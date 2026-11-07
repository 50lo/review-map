import Foundation
import TreeSitterKotlin

/// Declaration structure comes from the tree; reference candidates come from identifier queries.
enum KotlinExtractor {
    static let language = tree_sitter_kotlin()!
    // swiftlint:disable:next force_try
    static let references = try! SyntaxQuery("(simple_identifier) @id\n(type_identifier) @id", language: language)

    static func parse(path: String, source: String) -> ParsedFile {
        let tree = SyntaxTree(source: source, language: language)
        var walker = KotlinDeclarations()
        walker.walk(tree.root)
        let root = tree.root
        let package = root.namedChildren.first { $0.type == "package_header" }?.namedChildren.first(where: { $0.type == "identifier" }).map(qualifiedIdentifier) ?? ""
        var imports: [NameRef] = []
        var stars: [String] = []
        var bindings: [String: (name: String, package: String)] = [:]
        for n in root.namedChildren where n.type == "import_list" || n.type == "import_header" {
            let entries = n.type == "import_list" ? n.namedChildren : [n]
            for entry in entries where entry.type == "import_header" {
                guard let identifier = entry.namedChildren.first(where: { $0.type == "identifier" }) else { continue }
                let path = qualifiedIdentifier(identifier)
                if entry.namedChildren.contains(where: { $0.type == "wildcard_import" }) {
                    let name = path
                    stars.append(name)
                    imports.append(NameRef(name: name, line: entry.startLine))
                } else {
                    let parts = path.split(separator: ".").map(String.init)
                    guard let name = parts.last else { continue }
                    let package = parts.dropLast().joined(separator: ".")
                    let alias = entry.namedChildren.first(where: { $0.type == "import_alias" })?.namedChildren.first?.text ?? name
                    bindings[clean(alias)] = (clean(name), package)
                    imports.append(NameRef(name: path, line: entry.startLine))
                }
            }
        }
        var refs: [NameRef] = []
        var members: [NameRef] = []
        for match in references.matches(in: root) {
            guard let n = match.first("id"), !isDeclarationName(n) else { continue }
            var ancestor = n.parent
            var excluded = false
            while let a = ancestor {
                if ["package_header", "import_header", "import_list"].contains(a.type) { excluded = true; break }
                ancestor = a.parent
            }
            if excluded { continue }
            let name = clean(n.text)
            if let parent = n.parent, parent.type == "navigation_suffix" {
                members.append(NameRef(name: name, line: n.startLine))
                continue
            }
            if let binding = bindings[name] {
                refs.append(NameRef(name: binding.name, line: n.startLine, module: binding.package))
            } else {
                refs.append(NameRef(name: name, line: n.startLine))
            }
        }
        return ParsedFile(path: path, language: "kotlin", decls: walker.decls, imports: imports,
                          typeRefs: refs, memberRefs: members, packageName: package, wildcardImports: stars)
    }

    private static func qualifiedIdentifier(_ n: SyntaxNode) -> String {
        n.namedChildren.filter { $0.type == "simple_identifier" }.map { clean($0.text) }.joined(separator: ".")
    }

    static func clean(_ name: String) -> String { name.trimmingCharacters(in: CharacterSet(charactersIn: "`")) }

    private static func isDeclarationName(_ n: SyntaxNode) -> Bool {
        guard let p = n.parent else { return false }
        switch p.type {
        case "class_declaration", "object_declaration", "companion_object", "type_alias":
            return p.namedChildren.first(where: { ["simple_identifier", "type_identifier"].contains($0.type) })?.isSame(n) == true
        case "function_declaration", "variable_declaration", "class_parameter", "parameter", "parameter_with_optional_type", "enum_entry", "type_parameter":
            return p.namedChildren.first(where: { $0.type == "simple_identifier" })?.isSame(n) == true
        default: return false
        }
    }
}

private struct KotlinDeclarations {
    var decls: [Declaration] = []
    private var parent: Int?
    private var scope: String? { parent.map { decls[$0].qualifiedName } }
    private var parentKind: ReviewItemKind? { parent.map { decls[$0].kind } }
    private func qualify(_ name: String, scope: String? = nil) -> String { (scope ?? self.scope).map { $0 + "." + name } ?? name }
    private func first(_ node: SyntaxNode, _ types: String...) -> SyntaxNode? { node.namedChildren.first { types.contains($0.type) } }
    private func declarationName(_ node: SyntaxNode) -> String? { first(node, "simple_identifier", "type_identifier").map { KotlinExtractor.clean($0.text) } }

    mutating func walk(_ node: SyntaxNode) {
        for n in node.namedChildren {
            switch n.type {
            case "class_declaration", "object_declaration", "companion_object": container(n)
            case "function_declaration": function(n)
            case "property_declaration": property(n)
            case "type_alias":
                if let name = declarationName(n) { add(n, kind: .typealias, name: name, header: n.tokens) }
            case "enum_entry":
                if let name = declarationName(n) { add(n, kind: .case, name: name, header: n.tokens) }
            case "secondary_constructor":
                let body = first(n, "function_body", "statements")
                add(n, kind: .`init`, name: "constructor", header: n.tokens.filter { $0.startByte < (body?.startByte ?? n.endByte) }, body: body,
                    labels: "constructor" + labels(n), function: true)
            case "statements", "source_file", "class_body", "enum_class_body": walk(n)
            default: break
            }
        }
    }

    private mutating func container(_ n: SyntaxNode) {
        let name = declarationName(n) ?? (n.type == "companion_object" ? "Companion" : "")
        guard !name.isEmpty else { return }
        let body = first(n, "class_body", "enum_class_body")
        let tokens = n.tokens
        let kind: ReviewItemKind = n.children.contains { $0.type == "interface" } ? .protocol :
            (n.children.contains { $0.type == "enum" } ? .enum : .class)
        var inherited: [String] = []
        for c in n.namedChildren where c.type == "delegation_specifier" {
            var identifiers: [SyntaxNode] = []
            c.forEach { node in
                if node.type == "user_type" {
                    identifiers = node.namedChildren.filter { $0.type == "type_identifier" }; return false
                }
                return identifiers.isEmpty
            }
            if let id = identifiers.last { inherited.append(KotlinExtractor.clean(id.text)) }
        }
        let index = add(n, kind: kind, name: name, header: tokens.filter { $0.startByte < (body?.startByte ?? n.endByte) },
                        inherited: inherited, headerEnd: body)
        let old = parent; parent = index
        if let constructor = first(n, "primary_constructor") {
            for p in constructor.namedChildren where p.type == "class_parameter" && p.children.contains(where: { $0.type == "binding_pattern_kind" }) {
                guard let name = declarationName(p) else { continue }
                let equals = p.tokens.first { $0.type == "=" }
                let value = equals.flatMap { e in p.namedChildren.first { $0.startByte > e.startByte } }
                let i = add(p, kind: .var, name: name, header: p.tokens.filter { $0.startByte < (equals?.startByte ?? p.endByte) }, body: value, stored: true)
                decls[i].traits.insert("constructor-property")
                decls[i].typeAnnotation = typeAfterColon(p)
                decls[i].traits.formUnion(nullableTraits(p, slot: "property"))
            }
        }
        if let body { walk(body) }
        parent = old
    }

    private func labels(_ n: SyntaxNode) -> String {
        guard let parameters = first(n, "function_value_parameters") else { return "()" }
        return "(" + parameters.namedChildren.filter { $0.type == "parameter" }.compactMap(declarationName).map { $0 + ":" }.joined() + ")"
    }

    private mutating func function(_ n: SyntaxNode) {
        guard let name = declarationName(n) else { return }
        let body = first(n, "function_body")
        let receiver = n.child("receiver")
        let receiverScope = receiver.map { node -> String in
            var id = ""
            node.forEach { c in
                if c.type == "user_type" { id = c.namedChildren.filter { $0.type == "type_identifier" }.map(\.text).joined(separator: "."); return false }
                return id.isEmpty
            }
            return id.isEmpty ? node.tokens.canon : id
        }
        let i = add(n, kind: .func, name: name, header: n.tokens.filter { $0.startByte < (body?.startByte ?? n.endByte) }, body: body,
                    labels: name + labels(n), function: true, receiver: receiverScope)
        if receiver != nil { decls[i].traits.insert("extension") }
        if parentKind == .protocol && body == nil { decls[i].inProtocol = true }
        decls[i].typeAnnotation = typeAfterColon(n)
        decls[i].traits.formUnion(nullableTraits(n, slot: "result"))
        if let params = first(n, "function_value_parameters") {
            for (offset, parameter) in params.namedChildren.filter({ $0.type == "parameter" }).enumerated() {
                decls[i].traits.formUnion(nullableTraits(parameter, slot: "parameter-\(offset)"))
            }
        }
    }

    private mutating func property(_ n: SyntaxNode) {
        guard let variable = first(n, "variable_declaration"), let name = declarationName(variable) else { return }
        let equals = n.children.first { $0.type == "=" || $0.type == "property_delegate" }
        let accessor = first(n, "getter", "setter")
        let cutoff = min(equals?.startByte ?? n.endByte, accessor?.startByte ?? n.endByte)
        let i = add(n, kind: .var, name: name, header: n.tokens.filter { $0.startByte < cutoff }, stored: accessor == nil)
        decls[i].bodyCanon = n.tokens.filter { $0.startByte >= cutoff && $0.type != ";" }.canon
        decls[i].headerEndLine = n.tokens.last(where: { $0.startByte < cutoff })?.endLine ?? n.startLine
        decls[i].typeAnnotation = typeAfterColon(variable)
        decls[i].traits.formUnion(nullableTraits(variable, slot: "property"))
        decls[i].inProtocol = parentKind == .protocol && equals == nil && accessor == nil
    }

    private func typeAfterColon(_ n: SyntaxNode) -> String? {
        guard let colon = n.children.first(where: { $0.type == ":" }), let type = n.namedChildren.first(where: { $0.startByte > colon.startByte }) else { return nil }
        return type.tokens.display
    }

    private func nullableTraits(_ n: SyntaxNode, slot: String) -> Set<String> {
        guard let colon = n.children.first(where: { $0.type == ":" }), let type = n.namedChildren.first(where: { $0.startByte > colon.startByte }), type.tokens.contains(where: { $0.text == "?" }) else { return [] }
        let shape = type.tokens.map { ["type_identifier", "simple_identifier"].contains($0.type) ? "T" : $0.text }.joined(separator: " ")
        return ["nullable:\(slot):\(shape)"]
    }

    @discardableResult
    private mutating func add(_ n: SyntaxNode, kind: ReviewItemKind, name: String, header: [SyntaxNode], body: SyntaxNode? = nil,
                              inherited: [String] = [], headerEnd: SyntaxNode? = nil, labels: String? = nil,
                              function: Bool = false, stored: Bool = false, receiver: String? = nil) -> Int {
        let mods = first(n, "modifiers")
        let attributes = mods?.namedChildren.filter { $0.type == "annotation" }.compactMap { annotation -> String? in
            var names: [String] = []
            annotation.forEach { c in
                if c.type == "user_type" { names = c.namedChildren.filter { $0.type == "type_identifier" }.map(\.text); return false }
                return names.isEmpty
            }
            return names.last
        } ?? []
        var modifiers = mods?.namedChildren.filter { $0.type != "annotation" && $0.type != "context_receiver" }.flatMap { $0.tokens.map(\.text) } ?? []
        if n.type == "object_declaration" || n.type == "companion_object" { modifiers.append("object") }
        if n.type == "companion_object" { modifiers.append("companion") }
        if n.children.contains(where: { $0.type == "enum" }) { modifiers.append("enum") }
        if let binding = first(n, "binding_pattern_kind") { modifiers.append(binding.text) }
        if n.type == "property_declaration", let binding = n.children.first(where: { $0.type == "val" || $0.type == "var" }) { modifiers.append(binding.text) }
        let access = modifiers.first { ["public", "private", "internal", "protected"].contains($0) } ?? "public"
        let header = header.filter { token in token.type != ";" && !(mods.map { token.startByte >= $0.startByte && token.endByte <= $0.endByte } ?? false) }
        let container = [.class, .protocol, .enum].contains(kind)
        let rawEnd = container ? (headerEnd?.startByte ?? n.endByte) : n.endByte
        var d = Declaration(kind: kind, name: name, qualifiedName: qualify(name + (function ? "()" : ""), scope: receiver),
                            scope: receiver ?? scope, parentIndex: parent, labelsKey: labels ?? name,
                            signatureDisplay: header.display, signatureCanon: header.canon,
                            modifiersCanon: mods?.tokens.canon ?? "", bodyCanon: body?.tokens.filter { $0.type != ";" }.canon ?? "",
                            rawText: n.tree.text(n.startByte, rawEnd), access: access, attributes: attributes, modifiers: modifiers,
                            inherited: inherited, isAsync: modifiers.contains("suspend"), isStored: stored,
                            isStatic: modifiers.contains("const") || parent.map { decls[$0].modifiers.contains("object") } == true,
                            inProtocol: false, parentKind: parentKind, startLine: n.startLine, endLine: n.endLine)
        d.traits.formUnion(mods?.namedChildren.filter { $0.type == "annotation" }.map { "annotation:" + $0.tokens.canon } ?? [])
        d.headerEndLine = (headerEnd ?? body)?.startLine ?? header.last?.endLine ?? n.startLine
        decls.append(d)
        return decls.count - 1
    }
}
