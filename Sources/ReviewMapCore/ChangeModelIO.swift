import Foundation

public enum ChangeModelIO {
    public static func encode(_ model: ChangeModel) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try enc.encode(model)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    public static func decode(_ data: Data) throws -> ChangeModel {
        try JSONDecoder().decode(ChangeModel.self, from: data)
    }

    /// A few human-readable lines for the terminal.
    public static func summary(_ m: ChangeModel) -> [String] {
        let changed = m.entities.filter { $0.change != .cosmetic }
        let interface = changed.filter(\.isInterface)
        let flagged = changed.filter { !$0.contractFlags.isEmpty }
        let edgeCounts = Dictionary(grouping: m.edges, by: \.status).mapValues(\.count)
        var lines = [
            "Components: \(m.components.count) (\(m.components.filter { $0.changedEntities > 0 }.count) changed)",
            "Edges: +\(edgeCounts[.added] ?? 0) -\(edgeCounts[.removed] ?? 0) ~\(edgeCounts[.changed] ?? 0) =\(edgeCounts[.unchanged] ?? 0)",
            "Entities changed: \(changed.count) (interface: \(interface.count), with contract flags: \(flagged.count), cosmetic: \(m.entities.count - changed.count))",
            "External packages changed: \(m.externalDeps.count)",
            "Warnings: \(m.warnings.count)",
        ]
        if !m.findings.isEmpty {
            let kinds = Dictionary(grouping: m.findings, by: \.kind).map { "\($0.key) \($0.value.count)" }.sorted()
            lines.append("Findings: \(m.findings.count) (\(kinds.joined(separator: ", ")))")
        }
        let top = m.components.filter { $0.changeScore > 0 }.sorted { $0.changeScore > $1.changeScore }.prefix(5)
        if !top.isEmpty {
            lines.append("Top components: " + top.map { "\($0.name) (\($0.changeScore))" }.joined(separator: ", "))
        }
        return lines
    }
}
