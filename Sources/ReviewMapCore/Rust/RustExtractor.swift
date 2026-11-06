import Foundation
import TreeSitterRust

/// Syntax-only Rust facts. Module paths are resolved after all files have been parsed, so cached
/// parses remain independent of their location and of the other side's module tree.
enum RustExtractor {
    static func parse(path: String, source: String) -> ParsedFile {
        let tree = SyntaxTree(source: source, language: tree_sitter_rust())
        var walker = Walker()
        walker.walk(tree.root, parent: nil, scope: nil)
        let refs = References(root: tree.root)
        let file = ParsedFile(path: path, language: "rust", decls: walker.decls, imports: refs.imports,
                              typeRefs: refs.refs, memberRefs: refs.members, marks: RustRisk.marks(tree.root))
        return file
    }

    private struct Walker {
        var decls: [Declaration] = []
        mutating func walk(_ node: SyntaxNode, parent: Int?, scope: String?) {
            var attrs: [String] = []
            for n in node.namedChildren {
                if n.type == "attribute_item" { attrs.append(String(n.text.dropFirst(2).dropLast())); continue }
                let kind: ReviewItemKind
                switch n.type {
                case "struct_item", "union_item": kind = .struct
                case "enum_item": kind = .enum
                case "trait_item": kind = .protocol
                case "impl_item", "mod_item": kind = .extension
                case "function_item", "function_signature_item", "macro_definition": kind = .func
                case "const_item", "static_item", "field_declaration": kind = .var
                case "type_item", "associated_type": kind = .typealias
                case "enum_variant": kind = .case
                default: attrs = []; continue
                }
                guard let name = (n.child("name") ?? n.child("type"))?.text else { attrs = []; continue }
                let body = n.child("body") ?? n.child("value")
                let container = ["struct_item", "union_item", "enum_item", "trait_item", "impl_item", "mod_item", "enum_variant"].contains(n.type)
                let visibility = n.namedChildren.first { $0.type == "visibility_modifier" }
                let mods = n.namedChildren.first { $0.type == "function_modifiers" }?.tokens.map(\.text) ?? []
                let parentKind = parent.map { decls[$0].kind }
                let access = visibility.map { $0.text == "pub" ? "public" : ($0.text.contains("crate") ? "internal" : "fileprivate") }
                    ?? (parentKind == .protocol || kind == .case ? "public" : "private")
                let tuple = body?.type == "ordered_field_declaration_list"
                let header = n.tokens.filter { $0.startByte < (tuple ? n.endByte : (body?.startByte ?? n.endByte)) }
                let signature = header.filter { token in
                    !(visibility.map { token.startByte >= $0.startByte && token.endByte <= $0.endByte } ?? false) && !mods.contains(token.text)
                }
                let memberScope = [scope, name].compactMap { $0 }.joined(separator: ".")
                let qualified = n.type == "impl_item" ? [scope, "impl " + (n.child("trait").map { $0.text + " for " } ?? "") + name].compactMap { $0 }.joined(separator: ".") : memberScope
                var d = Declaration(kind: kind, name: name, qualifiedName: qualified + (kind == .func ? "()" : ""),
                    scope: scope, parentIndex: parent, labelsKey: name,
                    signatureDisplay: header.display, signatureCanon: signature.canon,
                    modifiersCanon: ([access] + mods + attrs).joined(separator: " "), bodyCanon: container ? "" : (body?.tokens.canon ?? ""),
                    rawText: n.tree.text(n.startByte, container && !tuple ? (body?.startByte ?? n.endByte) : n.endByte),
                    access: access, attributes: attrs, modifiers: mods, inherited: n.child("trait").map { [$0.text] } ?? [],
                    inProtocol: parentKind == .protocol, parentKind: parentKind, startLine: n.startLine, endLine: n.endLine)
                d.headerEndLine = body?.startLine ?? n.endLine
                d.isAsync = mods.contains("async")
                d.isStored = n.type == "field_declaration"
                d.isStatic = n.type == "static_item"
                d.typeAnnotation = n.child("type")?.text
                if n.type == "mod_item" { d.traits.insert("rust-module"); if body == nil { d.traits.insert("rust-file-module") } }
                if n.type == "union_item" { d.traits.insert("union") }
                if n.type == "macro_definition" { d.traits.insert("macro") }
                if n.type == "impl_item", n.child("type_parameters") != nil { d.traits.insert("generic-impl") }
                if parentKind == .protocol, body != nil { d.traits.insert("default-implementation") }
                if attrs.contains("cfg(test)") || attrs.contains("test") || (parent.map { decls[$0].traits.contains("test") } ?? false) { d.traits.insert("test") }
                let index = decls.count
                decls.append(d)
                attrs = []
                if container, let body { walk(body, parent: index, scope: n.type == "impl_item" ? qualified : memberScope) }
            }
        }
    }

    private struct References {
        var imports: [NameRef] = []
        var refs: [NameRef] = []
        var members: [NameRef] = []
        struct Binding { var path: [String]; var name: String }
        init(root: SyntaxNode) { walk(root, scope: [], inherited: [:]) }
        mutating func walk(_ root: SyntaxNode, scope: [String], inherited: [String: Binding], inheritedGlobs: [[String]] = []) {
            var bindings = inherited
            var globs = inheritedGlobs
            func leaves(_ n: SyntaxNode, prefix: [String]) -> [(String, Binding)] {
                switch n.type {
                case "scoped_use_list":
                    let path = prefix + (n.child("path")?.text.components(separatedBy: "::") ?? [])
                    return n.child("list").map { leaves($0, prefix: path) } ?? []
                case "use_list": return n.namedChildren.flatMap { leaves($0, prefix: prefix) }
                case "use_as_clause":
                    let parts = prefix + (n.child("path")?.text.components(separatedBy: "::") ?? [])
                    return [(n.child("alias")!.text, Binding(path: parts, name: parts.last ?? ""))]
                default:
                    var parts = prefix + n.text.components(separatedBy: "::")
                    if parts.last == "self" { parts.removeLast() }
                    return [(parts.last ?? "", Binding(path: parts, name: parts.last ?? ""))]
                }
            }
            for n in root.namedChildren where n.type == "use_declaration" {
                guard let argument = n.child("argument") else { continue }
                for (alias, binding) in leaves(argument, prefix: []) {
                    if alias == "*" { globs.append(Array(binding.path.dropLast())) } else { bindings[alias] = binding }
                    let ref = reference(binding.path, name: binding.name, line: n.startLine, scope: scope)
                    if let module = ref.module, !module.isEmpty { imports.append(NameRef(name: module, line: n.startLine)) }
                    refs.append(ref)
                }
            }
            for n in root.namedChildren where n.type != "use_declaration" && n.type != "attribute_item" {
                if n.type == "mod_item", let body = n.child("body"), let name = n.child("name") {
                    walk(body, scope: scope + [name.text], inherited: [:]); continue
                }
                n.forEach { node in
                    if node.type == "block" || node.type == "declaration_list" {
                        walk(node, scope: scope, inherited: bindings, inheritedGlobs: globs); return false
                    }
                    if node.type == "scoped_identifier" || node.type == "scoped_type_identifier" {
                        var parts = node.text.components(separatedBy: "::")
                        if let binding = bindings[parts[0]] {
                            refs.append(reference(binding.path, name: binding.name, line: node.startLine, scope: scope))
                            parts = binding.path + parts.dropFirst()
                        } else if globs.count == 1, parts[0].first?.isUppercase == true {
                            refs.append(reference(globs[0] + [parts[0]], name: parts[0], line: node.startLine, scope: scope))
                            parts = globs[0] + parts
                        }
                        refs.append(reference(parts, name: parts.last ?? "", line: node.startLine, scope: scope)); return false
                    }
                    if node.type == "field_expression", let field = node.child("field") {
                        members.append(NameRef(name: field.text, line: field.startLine))
                    }
                    if node.type == "identifier" || node.type == "type_identifier" {
                        if let binding = bindings[node.text] { refs.append(reference(binding.path, name: binding.name, line: node.startLine, scope: scope)) }
                        else if globs.count == 1 { refs.append(reference(globs[0] + [node.text], name: node.text, line: node.startLine, scope: scope)) }
                        else { refs.append(NameRef(name: node.text, line: node.startLine, module: "")) }
                    }
                    return true
                }
            }
        }
        func reference(_ path: [String], name: String, line: Int, scope: [String]) -> NameRef {
            if ["crate", "self", "super"].contains(path.first ?? "") {
                return NameRef(name: name, line: line, source: "rust:" + scope.joined(separator: "::") + "|" + path.dropLast().joined(separator: "::"), module: "")
            }
            return NameRef(name: name, line: line, source: path.count > 1 ? "rust:" + scope.joined(separator: "::") + "|" + path.dropLast().joined(separator: "::") : nil, module: path.count > 1 ? path.first : "")
        }
    }
}
