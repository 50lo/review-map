import Foundation

/// Explicit trait implementations, with witnesses confined to their own impl block.
struct RustConformance {
    let b: ChangeReportBuilder

    func conformers(of interface: Pair, requirement: Pair?, for use: ConformanceUse) -> [Conformer] {
        guard let trait = interface.head ?? interface.base else { return [] }
        let member = requirement?.head?.decl ?? requirement?.base?.decl
        if use == .check, member?.traits.contains("default-implementation") == true { return [] }
        var result: [Conformer] = []
        for (path, file) in b.head.files.sorted(by: { $0.key < $1.key }) where file.language == "rust" {
            guard let component = b.head.layout.fileComponent[path] else { continue }
            for (index, decl) in file.decls.enumerated() where decl.kind == .extension && !decl.inherited.isEmpty {
                guard !isBlanket(decl), matches(decl, file: file, trait: trait) else { continue }
                let implementations = file.decls.enumerated().compactMap { i, item -> Located? in
                    guard let member, item.parentIndex == index, item.name == member.name, item.kind == member.kind else { return nil }
                    return Located(decl: item, file: path, index: i, component: component)
                }
                result.append(Conformer(declaration: Located(decl: decl, file: path, index: index, component: component), implementations: implementations))
            }
        }
        return result
    }

    private func isBlanket(_ decl: Declaration) -> Bool {
        guard decl.traits.contains("generic-impl") else { return false }
        // A generic concrete type (Container<T>) is still an explicit implementer. A bare
        // type parameter (T, &T, &mut T) represents the unbounded family we cannot enumerate.
        let type = decl.name.replacingOccurrences(of: #"^(?:&\s*(?:'\w+\s*)?(?:mut\s*)?)+"#, with: "", options: .regularExpression)
        guard type.range(of: #"^\w+$"#, options: .regularExpression) != nil else { return false }
        return decl.signatureCanon.range(of: #"(?:<|,)\s*"# + NSRegularExpression.escapedPattern(for: type) + #"\s*(?=[:,>])"#, options: .regularExpression) != nil
    }

    private func matches(_ implementation: Declaration, file: ParsedFile, trait: Located) -> Bool {
        guard let inherited = implementation.inherited.first else { return false }
        let name = inherited.components(separatedBy: "<").first!.trimmingCharacters(in: .whitespaces)
        let parts = name.components(separatedBy: "::")
        let scope = implementation.scope?.components(separatedBy: ".") ?? []
        if file.path == trait.file {
            var target = parts
            if target.first == "crate" { target.removeFirst() }
            else if target.first == "self" { target = scope + target.dropFirst() }
            else if target.first == "super" { target = Array(scope.dropLast()) + target.dropFirst() }
            else if parts.count == 1 { target = scope + parts }
            if target.joined(separator: ".") == trait.decl.qualifiedName { return true }
        }
        // Resolved imports carry the source file and original name, including renamed imports.
        let source = "/" + (trait.file as NSString).deletingPathExtension
        let references = file.typeRefs.filter { $0.line >= implementation.startLine && $0.line <= implementation.headerEndLine && $0.name == trait.decl.name && $0.source == source }
        if references.isEmpty {
            let imported = file.typeRefs.contains { ref in
                guard ref.line >= implementation.startLine, ref.line <= implementation.headerEndLine, ref.name == trait.decl.name, let module = ref.module,
                      let component = b.head.layout.fileComponent[file.path],
                      b.head.layout.moduleComponent[b.head.layout.aliases(for: component)[module] ?? module] == trait.component else { return false }
                return true
            }
            guard imported else { return false }
            // Only one trait of this name in the imported crate is unambiguous in name mode.
            return b.head.files.filter { b.head.layout.fileComponent[$0.key] == trait.component }
                .values.flatMap(\.decls).filter { $0.kind == .protocol && $0.name == trait.decl.name }.count == 1
        }
        // A file can contain multiple inline modules declaring the same trait name; source
        // alone cannot distinguish them. Qualified same-file names were handled above.
        return (b.head.files[trait.file]?.decls.filter { $0.kind == .protocol && $0.name == trait.decl.name }.count ?? 0) == 1
    }
}
