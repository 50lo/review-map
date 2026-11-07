import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum KotlinManifest {
    static func contractFile(_ path: String) -> (key: String, flag: String)? {
        (path as NSString).lastPathComponent == "AndroidManifest.xml" ? (path, "android-manifest-changed") : nil
    }

    static func flags(basePath: String, headPath: String) -> [String] {
        guard let base = read(basePath), let head = read(headPath) else { return [] }
        var flags: [String] = []
        if !head.permissions.subtracting(base.permissions).isEmpty { flags.append("permission-added") }
        if !base.permissions.subtracting(head.permissions).isEmpty { flags.append("permission-removed") }
        if base.exported != head.exported { flags.append("exported-components-changed") }
        if base.intents != head.intents { flags.append("intent-filters-changed") }
        return flags
    }

    private static func read(_ path: String) -> Manifest? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let parser = XMLParser(data: data), manifest = Manifest()
        parser.delegate = manifest
        return parser.parse() ? manifest : nil
    }

    private final class Manifest: NSObject, XMLParserDelegate {
        var permissions: Set<String> = []
        var exported: [String: String] = [:]
        var intents: Set<String> = []
        private var androidPrefix = "android:"
        private var components: [String] = []
        private var intent: [String]?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            for (key, value) in attributes where key.hasPrefix("xmlns:") && value == "http://schemas.android.com/apk/res/android" {
                androidPrefix = String(key.dropFirst("xmlns:".count)) + ":"
            }
            func android(_ key: String) -> String? { attributes[androidPrefix + key] }
            if elementName == "uses-permission" || elementName == "uses-permission-sdk-23", let name = android("name") { permissions.insert(name) }
            if ["activity", "activity-alias", "service", "receiver", "provider"].contains(elementName) {
                let key = elementName + ":" + (android("name") ?? "")
                components.append(key)
                exported[key] = android("exported") ?? "implicit"
            }
            if elementName == "intent-filter" { intent = [components.last ?? "application"] }
            if intent != nil {
                let values = attributes.map { key, value in
                    (key.hasPrefix(androidPrefix) ? "android:" + key.dropFirst(androidPrefix.count) : key) + "=" + value
                }.sorted().joined(separator: "|")
                intent!.append(elementName + ":" + values)
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "intent-filter", let values = intent {
                intents.insert(values[0] + "|" + values.dropFirst().sorted().joined(separator: "|"))
                intent = nil
            }
            if ["activity", "activity-alias", "service", "receiver", "provider"].contains(elementName) { _ = components.popLast() }
        }
    }
}
