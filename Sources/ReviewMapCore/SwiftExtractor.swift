import Foundation
import SwiftParser
import SwiftSyntax

/// A declaration found in one Swift file at one side of the change.
struct Decl {
    var kind: EntityKind
    /// Simple name ("add", "init", "CartService"); for extensions the extended type.
    var name: String
    /// Human-readable qualified name: "CartService.add(item:)", "extension CartService: Sendable".
    var qualifiedName: String
    /// Qualified name of the enclosing type scope ("CartService"), nil at top level.
    var scope: String?
    var parentIndex: Int?
    var isTopLevel: Bool { parentIndex == nil }
    /// Name plus argument labels, used to match overloads: "add(item:)".
    var labelsKey: String
    var signatureDisplay: String
    /// Trivia-free header tokens without attributes and modifiers.
    var signatureCanon: String
    /// Trivia-free attributes + modifiers.
    var modifiersCanon: String
    /// Trivia-free body tokens (empty for containers: their members are compared one by one).
    var bodyCanon: String
    /// Raw text of the declaration (header only for containers), used to detect cosmetic-only changes.
    var rawText: String
    var access: String?
    var attributes: [String]
    var modifiers: [String]
    var inherited: [String]
    var isAsync = false
    var isThrows = false
    var throwsType: String?
    var isStored = false
    var isStatic = false
    var typeAnnotation: String?
    /// Declared inside a protocol (a requirement).
    var inProtocol = false
    /// Kind of the enclosing container, if any.
    var parentKind: EntityKind?
    var startLine: Int
    var endLine: Int

    var isContainer: Bool {
        switch kind {
        case .struct, .class, .enum, .actor, .protocol, .extension: return true
        default: return false
        }
    }
}

struct NameRef: Hashable {
    var name: String
    var line: Int
}

struct ParsedFile {
    var path: String
    var decls: [Decl]
    var imports: [NameRef]
    /// Free identifiers and type names (candidates for cross-component references).
    var typeRefs: [NameRef]
    /// Names used after a dot (`x.foo`), for member-level usage.
    var memberRefs: [NameRef]

    /// Innermost declaration containing `line`.
    func enclosingDecl(line: Int) -> Decl? {
        var best: Decl?
        for d in decls where d.startLine <= line && line <= d.endLine {
            if let b = best {
                if d.endLine - d.startLine <= b.endLine - b.startLine { best = d }
            } else {
                best = d
            }
        }
        return best
    }
}

enum SwiftExtractor {
    static func parse(path: String, source: String) -> ParsedFile {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let declVisitor = DeclVisitor(converter: converter)
        declVisitor.walk(tree)
        let refVisitor = RefVisitor(converter: converter)
        refVisitor.walk(tree)
        return ParsedFile(path: path, decls: declVisitor.decls, imports: refVisitor.imports,
                          typeRefs: refVisitor.typeRefs, memberRefs: refVisitor.memberRefs)
    }
}

// MARK: - Token helpers

private func canon<S: SyntaxProtocol>(_ node: S?) -> String {
    guard let node else { return "" }
    return node.tokens(viewMode: .sourceAccurate).map(\.text).joined(separator: " ")
}

/// Tokens in [from, to) of `node`, joined trivia-free.
private func canonTokens(_ node: some SyntaxProtocol, from: AbsolutePosition, to: AbsolutePosition) -> String {
    tokens(node, from: from, to: to).map(\.text).joined(separator: " ")
}

private func tokens(_ node: some SyntaxProtocol, from: AbsolutePosition, to: AbsolutePosition) -> [TokenSyntax] {
    node.tokens(viewMode: .sourceAccurate).filter {
        $0.positionAfterSkippingLeadingTrivia >= from && $0.positionAfterSkippingLeadingTrivia < to
    }
}

/// Display form: token texts with a single space wherever the source had any trivia.
private func display(_ toks: [TokenSyntax]) -> String {
    var out = ""
    for (i, t) in toks.enumerated() {
        if i > 0 && (!toks[i - 1].trailingTrivia.isEmpty || !t.leadingTrivia.isEmpty) {
            out += " "
        }
        out += t.text
    }
    return out
}

private func display<S: SyntaxProtocol>(_ node: S?) -> String {
    guard let node else { return "" }
    return display(Array(node.tokens(viewMode: .sourceAccurate)))
}

private let accessLevels: Set<String> = ["open", "public", "package", "internal", "fileprivate", "private"]

// MARK: - Declarations

private final class DeclVisitor: SyntaxVisitor {
    let converter: SourceLocationConverter
    var decls: [Decl] = []

    private struct Scope {
        var qualified: String?
        var index: Int?
        var kind: EntityKind?
    }
    private var stack: [Scope] = [Scope(qualified: nil, index: nil, kind: nil)]

    init(converter: SourceLocationConverter) {
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    private func lines(_ node: some SyntaxProtocol) -> (Int, Int) {
        let s = converter.location(for: node.positionAfterSkippingLeadingTrivia).line
        let e = converter.location(for: node.endPositionBeforeTrailingTrivia).line
        return (s, e)
    }

    private func attrsAndModifiers(_ attributes: AttributeListSyntax, _ modifiers: DeclModifierListSyntax)
        -> (attrs: [String], mods: [String], access: String?, canon: String, isStatic: Bool)
    {
        var attrs: [String] = []
        for a in attributes {
            if case .attribute(let attr) = a {
                attrs.append(attr.attributeName.trimmedDescription)
            }
        }
        var mods: [String] = []
        var access: String?
        var isStatic = false
        for m in modifiers {
            let n = m.name.text
            mods.append(m.trimmedDescription)
            if accessLevels.contains(n) && m.detail == nil { access = n }
            if accessLevels.contains(n) && m.detail != nil && access == nil {
                // private(set) etc. only narrows the setter; keep as modifier, not access level.
            }
            if n == "static" || n == "class" { isStatic = true }
        }
        let canonText = (canon(attributes) + " " + canon(modifiers)).trimmingCharacters(in: .whitespaces)
        return (attrs, mods, access, canonText, isStatic)
    }

    private var current: Scope { stack[stack.count - 1] }

    private func qualify(_ name: String) -> String {
        if let q = current.qualified { return q + "." + name }
        return name
    }

    @discardableResult
    private func add(_ d: Decl) -> Int {
        decls.append(d)
        return decls.count - 1
    }

    private func inheritedNames(_ clause: InheritanceClauseSyntax?) -> [String] {
        guard let clause else { return [] }
        return clause.inheritedTypes.map { $0.type.trimmedDescription }
    }

    // MARK: containers

    private func visitContainer(
        _ node: some DeclSyntaxProtocol, kind: EntityKind, name: String, keyword: TokenSyntax,
        attributes: AttributeListSyntax, modifiers: DeclModifierListSyntax,
        inheritance: InheritanceClauseSyntax?, memberBlock: MemberBlockSyntax,
        qualifiedOverride: String? = nil, scopeName: String? = nil
    ) -> SyntaxVisitorContinueKind {
        let am = attrsAndModifiers(attributes, modifiers)
        let headerToks = tokens(node, from: keyword.positionAfterSkippingLeadingTrivia, to: memberBlock.positionAfterSkippingLeadingTrivia)
        let (s, e) = lines(node)
        let rawStart = node.positionAfterSkippingLeadingTrivia
        let rawEnd = memberBlock.positionAfterSkippingLeadingTrivia
        let raw = String(node.syntaxTextBytes.prefix(rawEnd.utf8Offset - node.position.utf8Offset)
            .dropFirst(rawStart.utf8Offset - node.position.utf8Offset).map { Character(UnicodeScalar($0)) })
        let qualified = qualifiedOverride ?? qualify(name)
        let d = Decl(
            kind: kind, name: name, qualifiedName: qualified, scope: current.qualified,
            parentIndex: current.index, labelsKey: name,
            signatureDisplay: display(headerToks),
            // Conformances are compared separately (per type, across extensions), so they're not part of the header.
            signatureCanon: headerToks.filter { tok in
                guard let inh = inheritance else { return true }
                return tok.positionAfterSkippingLeadingTrivia < inh.positionAfterSkippingLeadingTrivia
                    || tok.positionAfterSkippingLeadingTrivia >= inh.endPositionBeforeTrailingTrivia
            }.map(\.text).joined(separator: " "),
            modifiersCanon: am.canon, bodyCanon: "", rawText: raw,
            access: am.access, attributes: am.attrs, modifiers: am.mods, inherited: inheritedNames(inheritance),
            isStatic: false, inProtocol: current.kind == .protocol, parentKind: current.kind,
            startLine: s, endLine: e)
        let idx = add(d)
        stack.append(Scope(qualified: scopeName ?? qualified, index: idx, kind: kind))
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        visitContainer(node, kind: .struct, name: node.name.text, keyword: node.structKeyword,
                       attributes: node.attributes, modifiers: node.modifiers,
                       inheritance: node.inheritanceClause, memberBlock: node.memberBlock)
    }
    override func visitPost(_ node: StructDeclSyntax) { stack.removeLast() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        visitContainer(node, kind: .class, name: node.name.text, keyword: node.classKeyword,
                       attributes: node.attributes, modifiers: node.modifiers,
                       inheritance: node.inheritanceClause, memberBlock: node.memberBlock)
    }
    override func visitPost(_ node: ClassDeclSyntax) { stack.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        visitContainer(node, kind: .enum, name: node.name.text, keyword: node.enumKeyword,
                       attributes: node.attributes, modifiers: node.modifiers,
                       inheritance: node.inheritanceClause, memberBlock: node.memberBlock)
    }
    override func visitPost(_ node: EnumDeclSyntax) { stack.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        visitContainer(node, kind: .actor, name: node.name.text, keyword: node.actorKeyword,
                       attributes: node.attributes, modifiers: node.modifiers,
                       inheritance: node.inheritanceClause, memberBlock: node.memberBlock)
    }
    override func visitPost(_ node: ActorDeclSyntax) { stack.removeLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        visitContainer(node, kind: .protocol, name: node.name.text, keyword: node.protocolKeyword,
                       attributes: node.attributes, modifiers: node.modifiers,
                       inheritance: node.inheritanceClause, memberBlock: node.memberBlock)
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { stack.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let extended = node.extendedType.trimmedDescription
        let fullExtended = current.qualified.map { $0 + "." + extended } ?? extended
        let conformances = inheritedNames(node.inheritanceClause)
        var q = "extension " + fullExtended
        if !conformances.isEmpty { q += ": " + conformances.joined(separator: ", ") }
        if let w = node.genericWhereClause { q += " " + w.trimmedDescription }
        return visitContainer(node, kind: .extension, name: fullExtended, keyword: node.extensionKeyword,
                              attributes: node.attributes, modifiers: node.modifiers,
                              inheritance: node.inheritanceClause, memberBlock: node.memberBlock,
                              qualifiedOverride: q, scopeName: fullExtended)
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { stack.removeLast() }

    // MARK: leaves

    private func leaf(
        _ node: some SyntaxProtocol, kind: EntityKind, name: String, labelsKey: String,
        attributes: AttributeListSyntax, modifiers: DeclModifierListSyntax,
        headerFrom: AbsolutePosition, headerTo: AbsolutePosition, body: (any SyntaxProtocol)?,
        effects: FunctionEffectSpecifiersSyntax? = nil, extraHeader: String = ""
    ) -> Decl {
        let am = attrsAndModifiers(attributes, modifiers)
        let headerToks = tokens(node, from: headerFrom, to: headerTo)
        let (s, e) = lines(node)
        var d = Decl(
            kind: kind, name: name, qualifiedName: qualify(labelsKey), scope: current.qualified,
            parentIndex: current.index, labelsKey: labelsKey,
            signatureDisplay: display(headerToks) + extraHeader,
            signatureCanon: headerToks.map(\.text).joined(separator: " ") + extraHeader,
            modifiersCanon: am.canon, bodyCanon: body.map { canon($0) } ?? "",
            rawText: node.trimmedDescription,
            access: am.access, attributes: am.attrs, modifiers: am.mods, inherited: [],
            isStatic: am.isStatic, inProtocol: current.kind == .protocol, parentKind: current.kind,
            startLine: s, endLine: e)
        if let effects {
            d.isAsync = effects.asyncSpecifier != nil
            d.isThrows = effects.throwsClause != nil
            d.throwsType = effects.throwsClause?.type?.trimmedDescription
        }
        return d
    }

    private func labels(_ params: FunctionParameterListSyntax) -> String {
        params.map { ($0.firstName.text) + ":" }.joined()
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let key = "\(name)(\(labels(node.signature.parameterClause.parameters)))"
        let to = node.body?.positionAfterSkippingLeadingTrivia ?? node.endPosition
        add(leaf(node, kind: .func, name: name, labelsKey: key, attributes: node.attributes, modifiers: node.modifiers,
                 headerFrom: node.funcKeyword.positionAfterSkippingLeadingTrivia, headerTo: to, body: node.body,
                 effects: node.signature.effectSpecifiers))
        return .skipChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = "init" + (node.optionalMark?.text ?? "")
        let key = "init(\(labels(node.signature.parameterClause.parameters)))"
        let to = node.body?.positionAfterSkippingLeadingTrivia ?? node.endPosition
        add(leaf(node, kind: .`init`, name: name, labelsKey: key, attributes: node.attributes, modifiers: node.modifiers,
                 headerFrom: node.initKeyword.positionAfterSkippingLeadingTrivia, headerTo: to, body: node.body,
                 effects: node.signature.effectSpecifiers))
        return .skipChildren
    }

    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let to = node.body?.positionAfterSkippingLeadingTrivia ?? node.endPosition
        add(leaf(node, kind: .func, name: "deinit", labelsKey: "deinit", attributes: node.attributes,
                 modifiers: node.modifiers, headerFrom: node.deinitKeyword.positionAfterSkippingLeadingTrivia,
                 headerTo: to, body: node.body))
        return .skipChildren
    }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        let key = "subscript(\(labels(node.parameterClause.parameters)))"
        let inProto = current.kind == .protocol
        let to = (inProto ? nil : node.accessorBlock?.positionAfterSkippingLeadingTrivia) ?? node.endPosition
        add(leaf(node, kind: .func, name: "subscript", labelsKey: key, attributes: node.attributes,
                 modifiers: node.modifiers, headerFrom: node.subscriptKeyword.positionAfterSkippingLeadingTrivia,
                 headerTo: to, body: inProto ? nil : node.accessorBlock))
        return .skipChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let inProto = current.kind == .protocol
        for binding in node.bindings {
            guard let ident = binding.pattern.as(IdentifierPatternSyntax.self) else {
                // Tuple patterns etc.: record by their text.
                continue
            }
            let name = ident.identifier.text
            let headerToks = [node.bindingSpecifier] + Array(binding.pattern.tokens(viewMode: .sourceAccurate))
                + (binding.typeAnnotation.map { Array($0.tokens(viewMode: .sourceAccurate)) } ?? [])
            var effectsText = ""
            var isAsync = false
            var isThrows = false
            var throwsType: String?
            var stored = true
            var accessorBodies = ""
            if let block = binding.accessorBlock {
                switch block.accessors {
                case .getter(let items):
                    stored = false
                    accessorBodies = canon(items)
                case .accessors(let list):
                    let kinds = list.map(\.accessorSpecifier.text)
                    stored = kinds.allSatisfy { $0 == "willSet" || $0 == "didSet" }
                    for acc in list where acc.accessorSpecifier.text == "get" {
                        if let eff = acc.effectSpecifiers {
                            isAsync = eff.asyncSpecifier != nil
                            isThrows = eff.throwsClause != nil
                            throwsType = eff.throwsClause?.type?.trimmedDescription
                            effectsText = " " + canon(eff)
                        }
                    }
                    accessorBodies = canon(list)
                }
            }
            if inProto, let block = binding.accessorBlock {
                // In a protocol the accessor list ({ get set }) is part of the contract.
                effectsText = " " + canon(block)
                accessorBodies = ""
                stored = false
            }
            let am = attrsAndModifiers(node.attributes, node.modifiers)
            let (s, e) = lines(node)
            var d = Decl(
                kind: .var, name: name, qualifiedName: qualify(name), scope: current.qualified,
                parentIndex: current.index, labelsKey: name,
                signatureDisplay: display(headerToks) + (inProto ? effectsText : (effectsText.isEmpty ? "" : " {" + effectsText + " }")),
                signatureCanon: headerToks.map(\.text).joined(separator: " ") + effectsText,
                modifiersCanon: am.canon,
                bodyCanon: (canon(binding.initializer) + " " + accessorBodies).trimmingCharacters(in: .whitespaces),
                rawText: node.trimmedDescription,
                access: am.access, attributes: am.attrs, modifiers: am.mods, inherited: [],
                isStatic: am.isStatic, inProtocol: inProto, parentKind: current.kind,
                startLine: s, endLine: e)
            d.isStored = stored && !inProto
            d.isAsync = isAsync
            d.isThrows = isThrows
            d.throwsType = throwsType
            d.typeAnnotation = binding.typeAnnotation?.type.trimmedDescription
            add(d)
        }
        return .skipChildren
    }

    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        for el in node.elements {
            let name = el.name.text
            let toks: [TokenSyntax] = [node.caseKeyword] + el.tokens(viewMode: .sourceAccurate).filter { $0.tokenKind != .comma }
            var labelsKey = name
            if let params = el.parameterClause {
                labelsKey += "(" + params.parameters.map { ($0.firstName?.text ?? "_") + ":" }.joined() + ")"
            }
            let am = attrsAndModifiers(node.attributes, node.modifiers)
            let (s, e) = lines(el)
            add(Decl(
                kind: .case, name: name, qualifiedName: qualify(name), scope: current.qualified,
                parentIndex: current.index, labelsKey: name,
                signatureDisplay: display(toks), signatureCanon: toks.map(\.text).joined(separator: " "),
                modifiersCanon: am.canon, bodyCanon: "", rawText: el.trimmedDescription,
                access: nil, attributes: am.attrs, modifiers: am.mods, inherited: [],
                parentKind: current.kind, startLine: s, endLine: e))
            _ = labelsKey
        }
        return .skipChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        add(leaf(node, kind: .typealias, name: node.name.text, labelsKey: node.name.text,
                 attributes: node.attributes, modifiers: node.modifiers,
                 headerFrom: node.typealiasKeyword.positionAfterSkippingLeadingTrivia,
                 headerTo: node.endPositionBeforeTrailingTrivia, body: nil))
        return .skipChildren
    }

    override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
        add(leaf(node, kind: .typealias, name: node.name.text, labelsKey: node.name.text,
                 attributes: node.attributes, modifiers: node.modifiers,
                 headerFrom: node.associatedtypeKeyword.positionAfterSkippingLeadingTrivia,
                 headerTo: node.endPositionBeforeTrailingTrivia, body: nil))
        return .skipChildren
    }

    // Don't descend into things that can't contain member declarations we track.
    override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: MacroDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
}

// MARK: - References

private final class RefVisitor: SyntaxVisitor {
    let converter: SourceLocationConverter
    var imports: [NameRef] = []
    var typeRefs: [NameRef] = []
    var memberRefs: [NameRef] = []

    init(converter: SourceLocationConverter) {
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    private func line(_ node: some SyntaxProtocol) -> Int {
        converter.location(for: node.positionAfterSkippingLeadingTrivia).line
    }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        if let first = node.path.first {
            imports.append(NameRef(name: first.name.text, line: line(node)))
        }
        return .skipChildren
    }

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        typeRefs.append(NameRef(name: node.name.text, line: line(node)))
        return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.baseName.text
        if let member = node.parent?.as(MemberAccessExprSyntax.self), member.declName.id == node.id {
            memberRefs.append(NameRef(name: name, line: line(node)))
        } else {
            typeRefs.append(NameRef(name: name, line: line(node)))
        }
        return .visitChildren
    }

    override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
        memberRefs.append(NameRef(name: node.name.text, line: line(node)))
        return .visitChildren
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        typeRefs.append(NameRef(name: node.macroName.text, line: line(node)))
        return .visitChildren
    }

    override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
        typeRefs.append(NameRef(name: node.macroName.text, line: line(node)))
        return .visitChildren
    }
}
