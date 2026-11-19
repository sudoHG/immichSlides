import Foundation

enum SharedSceneEvidenceManifest {

    static func canonicalJSONData<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func parseKeyValueFields(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in raw.components(separatedBy: .newlines) {
            for component in line.split(separator: ";", omittingEmptySubsequences: true) {
                guard let separator = component.firstIndex(of: "=") else { continue }
                let key = String(component[..<separator])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(component[component.index(after: separator)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                result[key] = value
            }
        }
        return result
    }
}
