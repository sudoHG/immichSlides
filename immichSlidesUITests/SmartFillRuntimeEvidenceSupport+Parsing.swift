import Foundation
import XCTest

extension SmartFillRuntimeEvidenceSupport {
    static func clockSourcesLine(for records: [[String: Any]]) -> String {
        Dictionary(grouping: records) { record in
            (record["startupClockSource"] as? String) ?? "missing"
        }
        .mapValues(\.count)
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: ";")
    }

    static func runtimePhaseKeyCompletenessLine(for records: [[String: Any]]) -> String {
        let missingCounts = records.compactMap { record in
            record["startupMissingPhases"] as? [String]
        }
        let missingTotal = missingCounts.reduce(0) { $0 + $1.count }
        return missingTotal == 0 ? "complete" : "missingPhaseCount=\(missingTotal)"
    }

    static func runId(
        scenario: String,
        deviceTag: String,
        environment: [String: String]
    ) -> String {
        environment["IMMICHSLIDES_RUNTIME_RUN_ID"] ?? environment["TEST_RUNNER_IMMICHSLIDES_RUNTIME_RUN_ID"]
            ?? "\(scenario)-\(deviceTag)-local"
    }

    static func gitBindingValue(
        _ key: String,
        environment: [String: String]
    ) -> String {
        environment[key] ?? environment["TEST_RUNNER_\(key)"]
            ?? "local-\(key.lowercased().replacingOccurrences(of: "_", with: "-"))-not-provided"
    }

    static func defaultAcceptedSceneSearchTier(isFallback: Bool, slotCount: Int) -> String {
        if isFallback {
            return "fallback"
        }
        return slotCount >= 2 ? "double" : "single-fill"
    }

    static func defaultRecentVisibleLimit(deviceTag: String) -> Int {
        deviceTag.localizedCaseInsensitiveContains("iphone") ? 12 : 16
    }

    static func value(
        _ key: String,
        in fields: [String: String],
        default defaultValue: String
    ) -> String {
        fields[key]?.isEmpty == false ? fields[key]! : defaultValue
    }

    static func listValue(
        _ key: String,
        in fields: [String: String],
        fallbackKey: String? = nil
    ) -> [String] {
        let rawValue: String
        if let fallbackKey {
            rawValue = value(key, in: fields, default: value(fallbackKey, in: fields, default: "missing"))
        } else {
            rawValue = value(key, in: fields, default: "missing")
        }
        return
            rawValue
            .split(separator: ",")
            .map(String.init)
    }

    static func redactedAssetListValue(_ key: String, in fields: [String: String]) -> [String] {
        listValue(key, in: fields).map { rawValue in
            "assetRef-\(stableHash(rawValue).prefix(12))"
        }
    }

    static func duplicateRefs(in values: [String]) -> [String] {
        var seen = Set<String>()
        var duplicates = Set<String>()
        for value in values {
            if seen.contains(value) {
                duplicates.insert(value)
            } else {
                seen.insert(value)
            }
        }
        return duplicates.sorted()
    }

    static func currentAssetRefValue(disposition: String, slotRefs: [String]) -> String {
        if disposition == "absent-hard-fail" {
            return "assetRef-absent"
        }

        let index: Int
        switch disposition {
        case "primary-slot", "single-slot", "fallback-current":
            index = 0
        case "secondary-slot":
            index = 1
        case "tertiary-slot":
            index = 2
        default:
            return "assetRef-missing"
        }

        guard slotRefs.indices.contains(index) else {
            return "assetRef-missing"
        }
        return slotRefs[index]
    }

    static func redactedReasonListValue(_ key: String, in fields: [String: String]) -> [String] {
        listValue(key, in: fields).map { rawValue in
            hasSensitiveToken(rawValue) ? "redacted-\(stableHash(rawValue).prefix(12))" : rawValue
        }
    }

    static func redactedRootCauseBucket(_ rawValue: String) -> String {
        hasSensitiveToken(rawValue) ? "unknown" : rawValue
    }

    static func redactedDiagnosticValue(_ rawValue: String) -> String {
        hasSensitiveToken(rawValue) ? "redacted-\(stableHash(rawValue).prefix(12))" : rawValue
    }

    static func normalizedFallbackRootCauseBucket(
        fields: [String: String],
        isFallback: Bool,
        fallbackReason: String,
        fallbackCategory: String
    ) -> String {
        let rawValue = redactedRootCauseBucket(
            value("fallbackRootCauseBucket", in: fields, default: isFallback ? "unknown" : "none"))
        guard isFallback, rawValue == "none" || rawValue == "unknown" || rawValue == "missing" else {
            return rawValue
        }

        let reasonTokens =
            [
                fallbackReason,
                fallbackCategory
            ] + redactedReasonListValue("rejectedLayoutReasonTopList", in: fields)
            + redactedReasonListValue("candidateRejectReasonTopList", in: fields)
            + redactedReasonListValue("fallbackReasonTopList", in: fields)

        if reasonTokens.contains("candidate-window-exhausted") {
            return "candidate-window-exhausted"
        }
        if reasonTokens.contains("protection-overlap") || reasonTokens.contains("face-crop-destroyed") {
            return "protection-reject"
        }
        if reasonTokens.contains("crop-retention-too-low") {
            return "crop-retention-reject"
        }
        if reasonTokens.contains("slot-aspect-ratio-out-of-range") {
            return "slot-aspect-ratio-reject"
        }
        if fallbackReason == "missing-candidates" {
            return "metadata-insufficient"
        }
        if fallbackReason == "all-layouts-rejected" || fallbackCategory == "layout-reject" {
            return "layout-policy-no-match"
        }
        if fallbackReason == "image-not-ready" {
            return "resource-readiness-misclassified"
        }
        return "fallback-unclassified"
    }

    static func finalFirstImageLoadStatus(fields: [String: String], screenshotPath: String) -> String {
        let rawStatus = redactedRootCauseBucket(value("firstImageLoadStatus", in: fields, default: "missing"))
        guard !screenshotPath.isEmpty else { return rawStatus }
        switch rawStatus {
        case "decoded", "downloaded":
            return "displayed"
        default:
            return rawStatus
        }
    }

    static func hasSensitiveToken(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.contains("http://") || lowercased.contains("https://") || lowercased.contains("api_key")
            || lowercased.contains("api key") || lowercased.contains("token") || lowercased.contains("bearer")
            || lowercased.contains("authorization") || lowercased.contains("assetid") || lowercased.contains("personid")
            || lowercased.contains("serverurl") || lowercased.contains("raw-asset") || lowercased.contains("raw-person")
    }

    static func phaseMapValue(_ key: String, in fields: [String: String]) -> [String: Double] {
        value(key, in: fields, default: "")
            .split(separator: ",")
            .reduce(into: [String: Double]()) { result, part in
                let entry = String(part)
                guard let separatorIndex = entry.firstIndex(of: ":") else { return }
                let phase = String(entry[..<separatorIndex])
                let rawValue = String(entry[entry.index(after: separatorIndex)...])
                guard let milliseconds = Double(rawValue),
                    milliseconds >= 0,
                    milliseconds.isFinite
                else {
                    return
                }
                result[phase] = milliseconds
            }
    }

    static func startupRuntimeValue(
        explicitField: String,
        fallbackPhase: String,
        in fields: [String: String],
        runtimePhaseTimestamps: [String: Double]
    ) -> Double {
        doubleValue(explicitField, in: fields, default: runtimePhaseTimestamps[fallbackPhase] ?? 0)
    }

    static func startupBlockingPhase(in runtimePhaseDurations: [String: Double]) -> String {
        runtimePhaseDurations
            .filter { requiredRuntimePhaseKeys.contains($0.key) }
            .max { lhs, rhs in lhs.value < rhs.value }?
            .key ?? "missing"
    }

    static func readinessCount(_ readiness: String, in values: [String]) -> Int {
        values.filter { $0.localizedCaseInsensitiveCompare(readiness) == .orderedSame }.count
    }

    static func doubleValue(
        _ key: String,
        in fields: [String: String],
        default defaultValue: Double
    ) -> Double {
        guard let raw = fields[key],
            let value = Double(raw)
        else {
            return defaultValue
        }
        return value
    }

    static func intValue(
        _ key: String,
        in fields: [String: String],
        default defaultValue: Int
    ) -> Int {
        guard let raw = fields[key],
            let value = Int(raw)
        else {
            return defaultValue
        }
        return value
    }

    static func intValue(_ key: String, in record: [String: Any]) -> Int {
        if let int = record[key] as? Int {
            return int
        }
        if let number = record[key] as? NSNumber {
            return number.intValue
        }
        if let string = record[key] as? String,
            let int = Int(string)
        {
            return int
        }
        return 0
    }

    static func stringValue(_ key: String, in record: [String: Any]) -> String? {
        record[key] as? String
    }

    static func surfaceLockKey(surfaceKey: String?, deviceTag: String) -> String {
        guard let surfaceKey,
            !surfaceKey.isEmpty
        else {
            return deviceTag == "appletv" ? "AppleTV-landscape" : "\(deviceTag)-unknown"
        }
        let parts = surfaceKey.split(separator: "-").map(String.init)
        guard parts.count >= 2 else {
            return surfaceKey
        }
        if parts[0] == "appleTV" {
            return "AppleTV-\(parts[1])"
        }
        return "\(parts[0])-\(parts[1])"
    }

    static func boolValue(
        _ key: String,
        in fields: [String: String],
        default defaultValue: Bool
    ) -> Bool {
        guard let raw = fields[key]?.lowercased() else {
            return defaultValue
        }
        switch raw {
        case "true":
            return true
        case "false":
            return false
        default:
            return defaultValue
        }
    }

    static func percentile(_ percentile: Double, values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let index = min(max(Int(ceil(percentile * Double(values.count))) - 1, 0), values.count - 1)
        return values[index]
    }

    static func stableHash(_ value: String) -> String {
        var hash: UInt64 = EvidenceCalibration.fnvOffsetBasis
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* EvidenceCalibration.fnvPrime
        }
        return String(format: "%016llx", hash)
    }

    static func parseAssetIDReplayList(_ text: String) -> [String] {
        var ids: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if let equalIndex = line.firstIndex(of: "=") {
                let key = String(line[..<equalIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                if [
                    "replayAssetIds",
                    "replayAssetIDs",
                    "orderedAssetIds",
                    "orderedAssetIDs",
                    "expectedCurrentAssetRefs",
                    "orderedCurrentAssetRefs",
                    "assetIds",
                    "assetIDs"
                ].contains(key) {
                    ids.append(contentsOf: splitAssetIDReplayList(String(line[line.index(after: equalIndex)...])))
                }
            } else {
                ids.append(contentsOf: splitAssetIDReplayList(line))
            }
        }
        if ids.isEmpty {
            ids = splitAssetIDReplayList(text)
        }
        return ids
    }

    static func splitAssetIDReplayList(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ", \n\t\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
