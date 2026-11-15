import Foundation
import IndexStoreDB

// Reads a compiler index store into exact references: for every reference in a file, the declaration it
// points at. The Rust core builds the store (Bazel, in an app-owned workspace) and tells the helper which
// directories the store's paths may start with.

struct IndexRequest: Codable {
    var storePath: String
    var databasePath: String
    /// libIndexStore of the toolchain that built the store.
    var libraryPath: String
    /// Directories index paths may start with, each with the repo-relative directory it stands for.
    var roots: [Root]
    /// rules_swift maps the execution root to "." in unit working directories and source paths. When set,
    /// "." is expanded to this directory while the store is imported.
    var prefixMapRoot: String?
    /// Repo-relative Swift files of the side.
    var files: [String]
}

/// A build root and the repo-relative directory it stands for ("" for the repo root).
struct Root: Hashable, Codable {
    var path: String
    var prefix: String
}

struct IndexedRef: Hashable {
    var line: Int
    var targetFile: String
    var targetLine: Int
    var name: String
}

enum IndexReader {
    /// Calls `emit` with each file that has index data and its references. Files without data are left out.
    static func read(_ request: IndexRequest, emit: (String, [IndexedRef]) -> Void) throws {
        let library = try IndexStoreLibrary(dylibPath: request.libraryPath)
        // Querying a relative filename is invalid even when a unit recorded one, so expand the prefix
        // while importing, before IndexStoreDB canonicalizes paths.
        let mappings = request.prefixMapRoot.map { [PathMapping(original: ".", replacement: $0)] } ?? []
        let db = try IndexStoreDB(storePath: request.storePath, databasePath: request.databasePath, library: library,
                                  waitUntilDoneInitializing: true, listenToUnitEvents: true, prefixMappings: mappings)
        let roots = expandRoots(request.roots)
        let known = Set(request.files)
        var definitions: [String: (file: String, line: Int)?] = [:]
        func definition(of usr: String) -> (file: String, line: Int)? {
            if let hit = definitions[usr] { return hit }
            let occ = db.occurrences(ofUSR: usr, roles: [.definition]).first ?? db.occurrences(ofUSR: usr, roles: [.declaration]).first
            let found = occ.flatMap { o in relativePath(o.location.path, roots: roots, known: known).map { ($0, o.location.line) } }
            definitions[usr] = found
            return found
        }
        for file in request.files {
            var occurrences: [SymbolOccurrence] = []
            for path in storedPaths(file, roots: roots) {
                occurrences = db.symbolOccurrences(inFilePath: path)
                if !occurrences.isEmpty { break }
            }
            if occurrences.isEmpty { continue }
            var out = Set<IndexedRef>()
            for o in occurrences where o.roles.contains(.reference) && !o.roles.contains(.implicit) {
                guard let def = definition(of: o.symbol.usr) else { continue }
                out.insert(IndexedRef(line: o.location.line, targetFile: def.file, targetLine: def.line, name: o.symbol.name))
            }
            emit(file, out.sorted { ($0.line, $0.targetFile, $0.targetLine, $0.name) < ($1.line, $1.targetFile, $1.targetLine, $1.name) })
        }
    }

    /// The build roots, also with symlinks resolved and with and without /private (macOS), longest first.
    static func expandRoots(_ given: [Root]) -> [Root] {
        var roots = Set<Root>()
        for root in given {
            let real = URL(fileURLWithPath: root.path).resolvingSymlinksInPath().path
            for r in [root.path, real] {
                roots.insert(Root(path: r, prefix: root.prefix))
                roots.insert(Root(path: r.hasPrefix("/private/") ? String(r.dropFirst("/private".count)) : "/private" + r, prefix: root.prefix))
            }
        }
        return roots.sorted { ($0.path.count, $0.path) > ($1.path.count, $1.path) }
    }

    /// A path from the index as a repo-relative path. Absolute paths start with a build root; Bazel may also
    /// record paths relative to its execution root ("Sources/App.swift" or "./Sources/App.swift").
    static func relativePath(_ path: String, roots: [Root], known: Set<String>) -> String? {
        for r in roots where path.hasPrefix(r.path + "/") { return join(r.prefix, String(path.dropFirst(r.path.count + 1))) }
        if path.hasPrefix("/") { return nil }
        let rel = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
        for prefix in Set(roots.map(\.prefix)).sorted(by: { $0.count > $1.count }) where known.contains(join(prefix, rel)) {
            return join(prefix, rel)
        }
        return nil
    }

    /// Absolute query paths for a repo-relative file. IndexStoreDB cannot query relative paths.
    static func storedPaths(_ file: String, roots: [Root]) -> [String] {
        var out: [String] = []
        for r in roots {
            if r.prefix.isEmpty {
                out.append(r.path + "/" + file)
            } else if file.hasPrefix(r.prefix + "/") {
                out.append(r.path + "/" + String(file.dropFirst(r.prefix.count + 1)))
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty || a == "." { return b }
        if b.isEmpty { return a }
        return a + "/" + b
    }
}
