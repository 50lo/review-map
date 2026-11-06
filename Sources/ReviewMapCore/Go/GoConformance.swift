import Foundation

/// Go's implicit interfaces: a type implements an interface when its method set has every method of the
/// interface. Methods match by name and parameter count; full type checking is index mode's job. Both value and
/// pointer receivers count, and embedded interfaces add their methods.
struct GoConformance {
    let b: ModelBuilder

    init(_ builder: ModelBuilder) { b = builder }

    /// A type or method: "<directory>|<type>". A package is a directory, and methods are declared in their type's package.
    private typealias TypeKey = String

    private struct SideFacts {
        /// Types other than interfaces.
        var types: [TypeKey: Located] = [:]
        /// Interfaces by key.
        var interfaces: [TypeKey: Located] = [:]
        /// Methods of each type, by name.
        var methods: [TypeKey: [String: [Located]]] = [:]
    }

    private func facts(_ s: Side) -> SideFacts {
        var out = SideFacts()
        let data = b.side(s)
        for (path, file) in data.files where file.language == "go" {
            guard let component = data.layout.fileComponent[path] else { continue }
            let dir = (path as NSString).deletingLastPathComponent
            for (i, d) in file.decls.enumerated() {
                let located = Located(decl: d, file: path, index: i, component: component)
                if d.scope == nil, [.struct, .typealias].contains(d.kind) {
                    out.types["\(dir)|\(d.name)"] = located
                } else if d.scope == nil, d.kind == .protocol {
                    out.interfaces["\(dir)|\(d.name)"] = located
                } else if d.kind == .func, !d.inProtocol, let scope = d.scope {
                    out.methods["\(dir)|\(scope)", default: [:]][d.name, default: []].append(located)
                }
            }
        }
        return out
    }

    /// An interface's methods by name, with their parameter count, embedded interfaces included. Nil when an
    /// embedded interface isn't in the repo (`io.Reader`), since the method set is then unknown.
    private func methodSet(_ interface: Located, _ f: SideFacts, side s: Side, seen: Set<TypeKey> = []) -> [String: Int]? {
        let dir = (interface.file as NSString).deletingLastPathComponent
        let key = "\(dir)|\(interface.decl.name)"
        guard !seen.contains(key), let file = b.side(s).files[interface.file] else { return nil }
        var out: [String: Int] = [:]
        for d in file.decls where d.parentIndex == interface.index && d.kind == .func {
            out[d.name] = Self.arity(d)
        }
        for name in interface.decl.inherited {
            let embedded = f.interfaces["\(dir)|\(name)"] ?? {
                let all = f.interfaces.filter { $0.key.hasSuffix("|\(name)") }
                return all.count == 1 ? all.first!.value : nil
            }()
            guard let embedded, let more = methodSet(embedded, f, side: s, seen: seen.union([key])) else { return nil }
            out.merge(more) { a, _ in a }
        }
        return out
    }

    static func arity(_ d: Decl) -> Int { d.labelsKey.filter { $0 == ":" }.count }

    private func implements(_ type: TypeKey, _ set: [String: Int], _ f: SideFacts) -> Bool {
        let methods = f.methods[type] ?? [:]
        return set.allSatisfy { name, arity in methods[name]?.contains { Self.arity($0.decl) == arity } ?? false }
    }

    func conformers(of interface: Pair, requirement: Pair?, for use: ConformanceUse) -> [Conformer] {
        // The types that implemented the interface at base (or at head, for a new interface)...
        let s: Side = interface.base != nil ? .base : .head
        guard let located = s == .base ? interface.base : interface.head else { return [] }
        let sideFacts = facts(s)
        guard let set = methodSet(located, sideFacts, side: s), !set.isEmpty else { return [] }
        let implementers = sideFacts.types.keys.filter { implements($0, set, sideFacts) }.sorted()
        // ...as they are at head, with their methods named like the requirement.
        let head = s == .head ? sideFacts : facts(.head)
        let member = requirement?.head?.decl ?? requirement?.base?.decl
        var out: [Conformer] = []
        for key in implementers {
            guard let type = head.types[key] else { continue }
            var implementations: [Located] = []
            if let member {
                implementations = (head.methods[key]?[member.name] ?? []).filter { m in
                    use == .context || requirement?.head.map { Self.arity(m.decl) == Self.arity($0.decl) } ?? true
                }
            }
            out.append(Conformer(declaration: type, implementations: implementations))
        }
        return out
    }
}
