import Foundation

// Shared UI and unit tests only need the complete-scene verdict and stable JSON; runtime process evidence
// does not belong here.
struct SharedSceneManifestObservation: Equatable {
    let isCompleteVisibleScene: Bool
}

enum SharedSceneEvidenceManifest {
    private static let minimumCanvasCoverage: Double = 0.999_999
    private static let maximumEmptyCanvasRatio: Double = 0.000_001

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

    static func manifestObservation(from raw: String) -> SharedSceneManifestObservation? {
        let fields = parseKeyValueFields(raw)
        guard fields["sceneType"] != nil else { return nil }

        let readiness = (fields["slotReadiness"] ?? "missing").lowercased()
        let hasPending = readiness.contains("pending") || readiness.contains("等待")
        let hasFailed = readiness.contains("failed") || readiness.contains("失败")
        let slotCount = Int(fields["slotCount"] ?? "") ?? 0
        let hasNoGap = Int(fields["gapPixelCount"] ?? "") == 0
        let hasNoOverlap = Int(fields["overlapPixelCount"] ?? "") == 0
        let coverage = Double(fields["canvasCoverage"] ?? "") ?? 0
        let emptyCanvasRatio = Double(fields["emptyCanvasRatio"] ?? "") ?? 1

        return SharedSceneManifestObservation(
            isCompleteVisibleScene: slotCount > 0 && !hasPending && !hasFailed && hasNoGap && hasNoOverlap
                && coverage >= minimumCanvasCoverage && emptyCanvasRatio <= maximumEmptyCanvasRatio
        )
    }
}
