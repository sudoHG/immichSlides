import Foundation
import XCTest

extension SmartFillRuntimeEvidenceSupport {
    static func jsonLine(from record: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func captureTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    static func isReadyForScreenshotEvidence(manifestFields fields: [String: String]) -> Bool {
        guard value("fallback", in: fields, default: "none") != "image-not-ready" else {
            return false
        }
        let readiness = listValue("slotReadiness", in: fields, fallbackKey: "firstSceneSlotReadiness")
        guard !readiness.isEmpty else { return false }
        return readiness.allSatisfy { $0 == "ready" }
    }

    static func screenshotEvidenceReadinessReason(manifestFields fields: [String: String]) -> String {
        if value("fallback", in: fields, default: "none") == "image-not-ready" {
            return "fallback=image-not-ready"
        }
        let readiness = listValue("slotReadiness", in: fields, fallbackKey: "firstSceneSlotReadiness")
        if readiness.isEmpty {
            return "slotReadiness=missing"
        }
        return "slotReadiness=\(readiness.joined(separator: ","))"
    }

    static func harnessTimestampMilliseconds() -> Double {
        ProcessInfo.processInfo.systemUptime * 1000
    }

    static func writeJSONLines(_ records: [[String: Any]], to url: URL) throws {
        let payload =
            try records
            .map(jsonLine)
            .joined(separator: "\n")
        try payload.write(to: url, atomically: true, encoding: .utf8)
    }

    static func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
    }

    static func scenarioManifestObservationLockText(
        records: [[String: Any]],
        scenario: String,
        deviceTag: String
    ) -> String? {
        guard !records.isEmpty else { return nil }
        let orderedRecords = records.sorted {
            intValue("sequence", in: $0) < intValue("sequence", in: $1)
        }
        let currentAssetRefs = orderedRecords.compactMap { stringValue("currentAssetRef", in: $0) }
        guard currentAssetRefs.count == orderedRecords.count else { return nil }
        let sceneIdHashes = orderedRecords.compactMap { stringValue("sceneIdHash", in: $0) }
        let sequences = orderedRecords.map { intValue("sequence", in: $0) }
        let surface = surfaceLockKey(
            surfaceKey: stringValue("surfaceKey", in: orderedRecords.first ?? [:]),
            deviceTag: deviceTag
        )
        let runId = stringValue("runId", in: orderedRecords.first ?? [:]) ?? "missing"
        let prHead = stringValue("prHead", in: orderedRecords.first ?? [:]) ?? "missing"
        let baseHead = stringValue("baseHead", in: orderedRecords.first ?? [:]) ?? "missing"

        return [
            "manifestVersion=scenario-manifest-v2",
            "lockStatus=RUNTIME_OBSERVED_CURRENT_ASSET_REFS_LOCK",
            "schemaVersion=\(schemaVersion)",
            "scenario=\(scenario)",
            "deviceTag=\(deviceTag)",
            "surface=\(surface)",
            "runId=\(runId)",
            "baseHead=\(baseHead)",
            "prHeadAtObservation=\(prHead)",
            "expectedCount=\(orderedRecords.count)",
            "orderedScenarioIds=\(surface):\(sequences.map { String(format: "%03d", $0) }.joined(separator: ","))",
            "orderedCurrentAssetRefs=\(currentAssetRefs.joined(separator: ","))",
            "orderedSceneIdHashes=\(sceneIdHashes.joined(separator: ","))",
            "lockNote=Observed lock only; later comparison must validate runtime currentAssetRef against this list and must not treat seed-only manifests as same-photo evidence."
        ].joined(separator: "\n") + "\n"
    }

    static func copyAssetIDReplayEnvironment(
        to app: XCUIApplication,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        for key in [
            "IMMICHSLIDES_SMARTFILL_REPLAY_ASSET_IDS",
            "IMMICHSLIDES_SMARTFILL_REPLAY_ASSET_IDS_PATH",
            "IMMICHSLIDES_SMARTFILL_EXPECTED_CURRENT_ASSET_REFS",
            "IMMICHSLIDES_SMARTFILL_EXPECTED_CURRENT_ASSET_REFS_PATH"
        ] {
            if let value = environment[key] ?? environment["TEST_RUNNER_\(key)"],
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                app.launchEnvironment[key] = value
            }
        }
    }

    static func assetIDReplayList(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String]? {
        let pathValue =
            (environment["IMMICHSLIDES_SMARTFILL_REPLAY_ASSET_IDS_PATH"]
            ?? environment["TEST_RUNNER_IMMICHSLIDES_SMARTFILL_REPLAY_ASSET_IDS_PATH"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let pathValue, !pathValue.isEmpty,
            let text = try? String(contentsOfFile: pathValue, encoding: .utf8)
        {
            let ids = parseAssetIDReplayList(text)
            return ids.isEmpty ? nil : ids
        }

        let inlineValue =
            environment["IMMICHSLIDES_SMARTFILL_REPLAY_ASSET_IDS"]
            ?? environment["TEST_RUNNER_IMMICHSLIDES_SMARTFILL_REPLAY_ASSET_IDS"]
        guard let inlineValue,
            !inlineValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        let ids = parseAssetIDReplayList(inlineValue)
        return ids.isEmpty ? nil : ids
    }

    static func assetIDReplayExpectedCurrentRefs(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String]? {
        assetIDReplayList(environment: environment)?
            .map { "asset-\(stableHash($0))" }
    }

    static func runtimeCurrentAssetRef(forSlotRef slotRef: String) -> String {
        "assetRef-\(stableHash(slotRef).prefix(12))"
    }

    static func assertRedactedSeedSummary(_ fields: [String: String]) {
        guard fields["progressFrameStatus"] == "available" else { return }
        let summary = fields["seedInputSummary"] ?? ""
        XCTAssertFalse(summary.isEmpty)
        for key in ["sceneId", "slotId", "assetId"] {
            let value = fields[key] ?? ""
            XCTAssertFalse(value.isEmpty)
            XCTAssertNotNil(value.range(of: "^[0-9a-f]{16}$", options: .regularExpression))
            XCTAssertTrue(
                summary.contains("\(key)=\(value)|"), "Seed diagnostics must correlate with the frame identity")
        }
    }

    static func strictExpectedCurrentAssetRefs(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String]? {
        let pathValue =
            (environment["IMMICHSLIDES_SMARTFILL_EXPECTED_CURRENT_ASSET_REFS_PATH"]
            ?? environment["TEST_RUNNER_IMMICHSLIDES_SMARTFILL_EXPECTED_CURRENT_ASSET_REFS_PATH"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let pathValue, !pathValue.isEmpty,
            let text = try? String(contentsOfFile: pathValue, encoding: .utf8)
        {
            let refs = parseAssetIDReplayList(text)
            return refs.isEmpty ? nil : refs
        }

        let inlineValue =
            environment["IMMICHSLIDES_SMARTFILL_EXPECTED_CURRENT_ASSET_REFS"]
            ?? environment["TEST_RUNNER_IMMICHSLIDES_SMARTFILL_EXPECTED_CURRENT_ASSET_REFS"]
        guard let inlineValue,
            !inlineValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        let refs = parseAssetIDReplayList(inlineValue)
        return refs.isEmpty ? nil : refs
    }

    static func assetIDReplayValidationText(rows: [AssetIDReplayValidationRow]) -> String {
        let header = "sequence\trule\texpected\tobservedSlotRef\tobservedCurrentAssetRef\tobservedReplayIndex\tstatus"
        let body = rows.map { row in
            let observedSlotRef = row.observedSlotRef ?? "missing"
            let observedCurrentAssetRef = row.observedCurrentAssetRef ?? "missing"
            let observedIndex = row.observedReplayIndex.map(String.init) ?? "missing"
            return
                "\(row.sequence)\t\(row.rule)\t\(row.expected)\t\(observedSlotRef)\t\(observedCurrentAssetRef)\t\(observedIndex)\t\(row.status)"
        }
        return ([header] + body).joined(separator: "\n") + "\n"
    }

    static func evaluateAssetIDReplayMonotonicProgress(
        sequence: Int,
        observedReplayIndex: Int?,
        previousReplayAssetIndex: Int?
    ) -> AssetIDReplayMonotonicProgress {
        let previousText = previousReplayAssetIndex.map { String($0 + 1) } ?? "start"
        let expected = "replayIndex>\(previousText)"
        guard let observedReplayIndex else {
            return AssetIDReplayMonotonicProgress(
                expected: expected,
                status: "mismatch-not-in-replay-lock",
                shouldIncludeManifest: false,
                shouldStopSampling: false,
                nextPreviousReplayAssetIndex: previousReplayAssetIndex,
                failureMessage: "currentAssetRef #\(sequence) must come from the asset-id replay lock"
            )
        }
        if let previousReplayAssetIndex,
            observedReplayIndex <= previousReplayAssetIndex
        {
            return AssetIDReplayMonotonicProgress(
                expected: expected,
                status: "truncated-at-replay-boundary",
                shouldIncludeManifest: false,
                shouldStopSampling: true,
                nextPreviousReplayAssetIndex: previousReplayAssetIndex,
                failureMessage: nil
            )
        }
        return AssetIDReplayMonotonicProgress(
            expected: expected,
            status: "match",
            shouldIncludeManifest: true,
            shouldStopSampling: false,
            nextPreviousReplayAssetIndex: observedReplayIndex,
            failureMessage: nil
        )
    }

    static func summaryLines(for records: [[String: Any]]) -> String {
        let fallbackDistribution = Dictionary(grouping: records) { record in
            (record["fallbackCategory"] as? String) ?? "missing"
        }
        .mapValues(\.count)
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: ";")
        let latencies = records.compactMap { $0["actionToSceneMs"] as? Double }.sorted()
        let latencyLine: String
        if latencies.isEmpty {
            latencyLine = "latency=missing"
        } else {
            latencyLine = [
                "latencyCount=\(latencies.count)",
                "p50=\(percentile(0.50, values: latencies))",
                "p95=\(percentile(0.95, values: latencies))",
                "max=\(latencies.last ?? 0)"
            ].joined(separator: ";")
        }
        return [
            "recordCount=\(records.count)",
            "fallbackDistribution=\(fallbackDistribution)",
            "startupClockSources=\(clockSourcesLine(for: records))",
            "runtimePhaseKeyCompleteness=\(runtimePhaseKeyCompletenessLine(for: records))",
            latencyLine
        ].joined(separator: "\n")
    }
}
