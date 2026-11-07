import Foundation

/// Kotlin's lexical dispatcher blocks override declaration-level Android main-thread conventions.
enum KotlinStructure {
    static let mainThread = "main thread"
    private static let uiTypes: Set<String> = ["View", "Activity", "Fragment"]

    static func regions(_ root: SyntaxNode) -> [IsolationRegion] {
        var result: [IsolationRegion] = []
        root.forEach { node in
            guard node.type == "call_expression", let callee = node.namedChildren.first,
                  let suffix = node.namedChildren.last(where: { $0.type == "call_suffix" }),
                  ["withContext", "launch", "async"].contains(callName(callee)) else { return true }
            let arguments = suffix.namedChildren.first { $0.type == "value_arguments" }
                ?? callee.namedChildren.last(where: { $0.type == "call_suffix" })?.namedChildren.first { $0.type == "value_arguments" }
            guard let arguments else { return true }
            var dispatchers: [String] = []
            for argument in arguments.namedChildren where argument.type == "value_argument" {
                // The context expression may combine a dispatcher with a Job. A block argument's own
                // dispatchers belong to nested calls and must not change this call's context.
                guard !argument.namedChildren.contains(where: { $0.type == "lambda_literal" }) else { continue }
                let tokens = argument.tokens
                for i in tokens.indices where i + 2 < tokens.count {
                    if tokens[i].type == "simple_identifier", tokens[i].text == "Dispatchers", tokens[i + 1].text == ".",
                       tokens[i + 2].type == "simple_identifier" { dispatchers.append(tokens[i + 2].text) }
                }
            }
            guard !dispatchers.isEmpty else { return true }
            var lambdas = suffix.namedChildren.filter { $0.type == "annotated_lambda" }.flatMap(\.namedChildren).filter { $0.type == "lambda_literal" }
            lambdas += arguments.namedChildren.filter { $0.type == "value_argument" }.flatMap(\.namedChildren).filter { $0.type == "lambda_literal" }
            for lambda in lambdas {
                result.append(IsolationRegion(startLine: lambda.startLine, endLine: lambda.endLine,
                                              startByte: lambda.startByte, endByte: lambda.endByte,
                                              isolation: dispatchers.allSatisfy { $0 == "Main" } ? mainThread : nil))
            }
            return true
        }
        return result
    }

    private static func callName(_ node: SyntaxNode) -> String {
        if node.type == "call_expression", let callee = node.namedChildren.first { return callName(callee) }
        return node.tokens.last?.text ?? ""
    }

    static func isolation(in file: ParsedFile, line: Int) -> String? {
        if let region = file.isolationRegions.filter({ $0.startLine <= line && line <= $0.endLine })
            .min(by: { $0.endByte - $0.startByte < $1.endByte - $1.startByte }) {
            return region.isolation // A non-main dispatcher deliberately clears inherited main-thread isolation.
        }
        guard let enclosing = file.enclosingDecl(line: line) else { return nil }
        for declaration in [enclosing] + file.enclosingDeclarations(of: enclosing) {
            if !Set(declaration.attributes).isDisjoint(with: ["MainThread", "UiThread"]) { return mainThread }
            if declaration.isContainer && !Set(declaration.inherited.map(ChangeReportBuilder.conformanceName)).isDisjoint(with: uiTypes) { return mainThread }
        }
        return nil
    }

    /// Uses Kotlin package/import identity before matching members of the actual implementing class.
    static func conformers(of interface: Pair, requirement: Pair?, in builder: ChangeReportBuilder, for use: ConformanceUse) -> [Conformer] {
        let side = interface.head == nil ? builder.base : builder.head
        guard let interfaceFile = side.files[interface.any.file] else { return [] }
        let wanted = qualified(interfaceFile.packageName, interface.any.decl.qualifiedName)
        var knownTypes = Set<String>()
        for file in builder.head.files.values where file.language == "kotlin" {
            knownTypes.formUnion(file.decls.filter(\.isContainer).map { qualified(file.packageName, $0.qualifiedName) })
        }
        var result: [Conformer] = []
        for path in builder.head.files.keys.sorted() {
            guard let file = builder.head.files[path], file.language == "kotlin", let component = builder.head.layout.fileComponent[path] else { continue }
            if use == .check, component != interface.any.component, builder.edgeRefs[.head]?[component]?[interface.any.component] == nil { continue }
            for (index, declaration) in file.decls.enumerated() where declaration.isContainer {
                let supertypes = declaration.traits.filter { $0.hasPrefix("supertype:") }.map { String($0.dropFirst("supertype:".count)) }
                guard supertypes.contains(where: { resolveType($0, in: file, scope: declaration.scope, knownTypes: knownTypes) == wanted }) else { continue }
                let located = Located(decl: declaration, file: path, index: index, component: component)
                var implementations: [Located] = []
                if let member = requirement?.head?.decl {
                    implementations = file.decls.enumerated().compactMap { memberIndex, candidate in
                        guard candidate.parentIndex == index, candidate.name == member.name,
                              ChangeReportBuilder.kindGroup(candidate.kind) == ChangeReportBuilder.kindGroup(member.kind) else { return nil }
                        return Located(decl: candidate, file: path, index: memberIndex, component: component)
                    }
                }
                result.append(Conformer(declaration: located, implementations: implementations))
            }
        }
        return result
    }

    static func qualified(_ package: String?, _ name: String) -> String {
        [package ?? "", name].filter { !$0.isEmpty }.joined(separator: ".")
    }

    /// Resolves only explicit source names, keeping unrelated packages and nested types distinct.
    static func resolveType(_ type: String, in file: ParsedFile, scope: String?, knownTypes: Set<String>) -> String? {
        // Import aliases are normalized in the extractor's supertype traits.
        if type.contains("."), knownTypes.contains(type) { return type }
        var scopes = (scope ?? "").split(separator: ".").map(String.init)
        while !scopes.isEmpty {
            let nested = qualified(file.packageName, (scopes + [type]).joined(separator: "."))
            if knownTypes.contains(nested) { return nested }
            scopes.removeLast()
        }
        // Explicit bindings were already expanded, including aliases. The raw import list cannot
        // distinguish `import p.State` from `import p.State as Other`, so do not rebind simple names here.
        let local = qualified(file.packageName, type)
        if knownTypes.contains(local) { return local }
        let stars = file.wildcardImports.map { qualified($0, type) }.filter { knownTypes.contains($0) }
        return stars.count == 1 ? stars[0] : nil
    }

    static func isViewCode(_ declaration: Declaration, inherits: Set<String>) -> Bool {
        declaration.attributes.contains("Composable") || !inherits.isDisjoint(with: uiTypes)
    }
}
