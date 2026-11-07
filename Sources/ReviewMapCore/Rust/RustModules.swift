import Foundation

/// Resolve local Rust paths against the declared module tree, not guessed directory names.
/// This runs per side, after the content-only parse cache, and never reads the working checkout.
enum RustModules {
    /// Both reference resolution and Cargo target ownership follow the same module-file rules.
    static func file(for declaration: Declaration, in path: String, directory: String,
                     files: Set<String>) -> (path: String, directory: String)? {
        let inline = declaration.scope?.replacingOccurrences(of: ".", with: "/") ?? ""
        let parent = join(directory, inline)
        let custom = declaration.attributes.first { $0.hasPrefix("path") }
            .flatMap { $0.split(separator: "\"").dropFirst().first.map(String.init) }
        let candidates: [String]
        if let custom {
            candidates = [Paths.resolve(custom, from: join(join((path as NSString).deletingLastPathComponent, inline), "_")) ?? ""]
        } else {
            candidates = [join(parent, declaration.name + ".rs"), join(join(parent, declaration.name), "mod.rs")]
        }
        guard let child = candidates.first(where: files.contains) else { return nil }
        return (child, child.hasSuffix("/mod.rs") ? (child as NSString).deletingLastPathComponent : (child as NSString).deletingPathExtension)
    }

    static func resolve(_ files: inout [String: ParsedFile]) {
        let rust = files.filter { $0.value.language == "rust" }
        let paths = Set(rust.keys)
        var locations: [String: (root: String, module: [String])] = [:]
        var modules: [String: String] = [:]
        func key(_ root: String, _ module: [String]) -> String { root + "|" + module.joined(separator: "::") }
        func visit(_ path: String, root: String, module: [String], directory: String, seen: Set<String>) {
            guard let file = rust[path], !seen.contains(path) else { return }
            locations[path] = (root, module)
            modules[key(root, module)] = path
            for decl in file.decls where decl.traits.contains("rust-module") {
                let local = (decl.scope?.components(separatedBy: ".") ?? []) + [decl.name]
                let full = module + local
                if !decl.traits.contains("rust-file-module") { modules[key(root, full)] = path; continue }
                if let child = Self.file(for: decl, in: path, directory: directory, files: paths) {
                    visit(child.path, root: root, module: full, directory: child.directory, seen: seen.union([path]))
                }
            }
        }
        for path in rust.keys.sorted() where ["lib.rs", "main.rs"].contains((path as NSString).lastPathComponent) {
            visit(path, root: path, module: [], directory: (path as NSString).deletingLastPathComponent, seen: [])
        }
        for path in rust.keys.sorted() where locations[path] == nil {
            visit(path, root: path, module: [], directory: (path as NSString).deletingLastPathComponent, seen: [])
        }
        for path in rust.keys {
            guard let location = locations[path] else { continue }
            files[path]?.typeRefs = rust[path]!.typeRefs.map { ref in
                guard let source = ref.source, source.hasPrefix("rust:") else { return ref }
                var result = ref
                result.source = nil
                let halves = String(source.dropFirst(5)).components(separatedBy: "|")
                let inline = halves[0].components(separatedBy: "::").filter { !$0.isEmpty }
                var parts = halves[1].components(separatedBy: "::").filter { !$0.isEmpty }
                var module = location.module + inline
                let minimumDepth = ref.module == "" ? 0 : module.count + 1
                if parts.first == "crate" { module = []; parts.removeFirst() }
                else if parts.first == "self" { parts.removeFirst() }
                while parts.first == "super" { guard !module.isEmpty else { return result }; module.removeLast(); parts.removeFirst() }
                module += parts
                while module.count > minimumDepth && modules[key(location.root, module)] == nil { module.removeLast() }
                if module.count >= minimumDepth, let target = modules[key(location.root, module)] {
                    result.source = "/" + (target as NSString).deletingPathExtension
                    result.module = ""
                }
                return result
            }
            let localImports = Set(zip(rust[path]!.typeRefs, files[path]!.typeRefs).compactMap { before, after -> String? in
                guard let module = before.module, !module.isEmpty, after.source != nil, after.module == "" else { return nil }
                return "\(before.line)|\(module)"
            })
            files[path]?.imports.removeAll { localImports.contains("\($0.line)|\($0.name)") }
        }
    }
}
