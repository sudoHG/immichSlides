import Foundation
import XCTest

#if os(iOS)
extension PlaybackSmartFillVisualUITests {
    func writeManifestEvidence(
        _ manifests: [SmartFillManifest],
        runtimeRecords: [[String: Any]],
        harnessSummary: [String: Any]?,
        scenario: String
    ) {
        guard let directory = evidenceDirectory() else { return }
        let summary = manifests.enumerated().map { index, manifest in
            [
                "index=\(index + 1)",
                "sceneType=\(manifest.sceneType)",
                "surfaceKey=\(manifest.surfaceKey)",
                "policy=\(manifest.policy)",
                "layoutVariant=\(manifest.layoutVariant)",
                "ratioPreset=\(manifest.ratioPreset)",
                "slotFrames=\(manifest.slotFrames)",
                "cropRetention=\(manifest.cropRetention)",
                "protectionContained=\(manifest.protectionContained)",
                "candidateWindowUsed=\(manifest.candidateWindowUsed)",
                "evaluationCount=\(manifest.evaluationCount)",
                "rotationStartLayoutVariant=\(manifest.rotationStartLayoutVariant)",
                "rotationStartRatioPreset=\(manifest.rotationStartRatioPreset)",
                "acceptedLayoutVariant=\(manifest.acceptedLayoutVariant)",
                "acceptedRatioPreset=\(manifest.acceptedRatioPreset)",
                "rotationKeyHashPrefix=\(manifest.rotationKeyHashPrefix)",
                "rejects=\(manifest.rejects)",
                "rejectedLayoutReasonTopList=\(manifest.rejectedLayoutReasonTopList)",
                "fallback=\(manifest.fallback)",
                "slotRefs=\(manifest.slotRefs)"
            ].joined(separator: ";")
        }.joined(separator: "\n")
        let fileURL = directory.appendingPathComponent(
            sanitizedEvidenceFileName("smartfill-\(scenario)-\(deviceTag())-manifest") + ".txt"
        )
        requireEvidenceWrite {
            try summary.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        guard !runtimeRecords.isEmpty else { return }
        let jsonlURL = directory.appendingPathComponent(
            sanitizedEvidenceFileName("smartfill-\(scenario)-\(deviceTag())-runtime") + ".jsonl"
        )
        requireEvidenceWrite {
            try SmartFillRuntimeEvidenceSupport.writeJSONLines(runtimeRecords, to: jsonlURL)
        }
        let summaryURL = directory.appendingPathComponent(
            sanitizedEvidenceFileName("smartfill-\(scenario)-\(deviceTag())-runtime-summary") + ".txt"
        )
        requireEvidenceWrite {
            try SmartFillRuntimeEvidenceSupport.summaryLines(for: runtimeRecords)
                .write(to: summaryURL, atomically: true, encoding: .utf8)
        }
        if let observedLockText = SmartFillRuntimeEvidenceSupport.scenarioManifestObservationLockText(
            records: runtimeRecords,
            scenario: scenario,
            deviceTag: deviceTag()
        ) {
            let lockURL = directory.appendingPathComponent(
                sanitizedEvidenceFileName("smartfill-\(scenario)-\(deviceTag())-scenario-manifest-observed") + ".lock"
            )
            requireEvidenceWrite {
                try observedLockText.write(to: lockURL, atomically: true, encoding: .utf8)
            }
        }
        if let harnessSummary {
            let harnessURL = directory.appendingPathComponent(
                sanitizedEvidenceFileName("smartfill-\(scenario)-\(deviceTag())-harness-summary") + ".json"
            )
            requireEvidenceWrite {
                try SmartFillRuntimeEvidenceSupport.writeJSONObject(harnessSummary, to: harnessURL)
            }
        }
    }

    func makeHarnessSummary(
        runtimeRecords: [[String: Any]],
        firstManifestObservedMs: Double?,
        firstNonLoadingScreenshotCapturedMs: Double?
    ) -> [String: Any]? {
        guard let startupRunId = runtimeRecords.first?["startupRunId"] as? String,
            let firstManifestObservedMs,
            let firstNonLoadingScreenshotCapturedMs
        else {
            return nil
        }
        return SmartFillRuntimeEvidenceSupport.makeHarnessSummary(
            startupRunId: startupRunId,
            firstManifestObservedMs: firstManifestObservedMs,
            firstNonLoadingScreenshotCapturedMs: firstNonLoadingScreenshotCapturedMs
        )
    }

    func evidenceDirectory() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let rootPath =
            environment["IMMICHSLIDES_SMARTFILL_EVIDENCE_ROOT"]
            ?? environment["TEST_RUNNER_IMMICHSLIDES_SMARTFILL_EVIDENCE_ROOT"]
        do {
            return try PrivateEvidenceDirectory.resolve(
                rootPath: rootPath,
                components: ["ui-runtime", deviceTag()]
            )
        } catch {
            XCTFail(error.localizedDescription)
            return nil
        }
    }

    func motionEvidenceDirectory() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["TEST_RUNNER_SMARTFILL_MOTION_EVIDENCE_DIR"]
            ?? environment["SMARTFILL_MOTION_EVIDENCE_DIR"],
            !path.isEmpty
        {
            do {
                return try PrivateEvidenceDirectory.resolve(
                    rootPath: path,
                    components: []
                )
            } catch {
                XCTFail(error.localizedDescription)
                return nil
            }
        }
        guard let root = evidenceDirectory() else { return nil }
        do {
            return try PrivateEvidenceDirectory.resolve(
                rootPath: root.path,
                components: ["motion-runtime"]
            )
        } catch {
            XCTFail(error.localizedDescription)
            return nil
        }
    }

    func smartFillMotionSampleDurationSeconds() -> TimeInterval {
        let environment = ProcessInfo.processInfo.environment
        let rawValue =
            environment["TEST_RUNNER_SMARTFILL_MOTION_SAMPLE_SECONDS"] ?? environment["SMARTFILL_MOTION_SAMPLE_SECONDS"]
        guard let rawValue,
            let value = TimeInterval(rawValue),
            value > 0
        else {
            return EvidenceCalibration.defaultMotionSampleSeconds
        }
        return value
    }

    func smartFillMotionConfiguredIntervalSeconds() -> Double {
        let environment = ProcessInfo.processInfo.environment
        let rawValue =
            environment["TEST_RUNNER_SMARTFILL_MOTION_INTERVAL_SECONDS"]
            ?? environment["SMARTFILL_MOTION_INTERVAL_SECONDS"]
        guard let rawValue,
            let value = Double(rawValue),
            value > 0
        else {
            return EvidenceCalibration.defaultMotionIntervalSeconds
        }
        return value
    }

    func isSmartFillMotionIntervalPreseeded() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["TEST_RUNNER_SMARTFILL_MOTION_INTERVAL_PRESEEDED"] == "1"
            || environment["SMARTFILL_MOTION_INTERVAL_PRESEEDED"] == "1"
    }

    func smartFillMotionScenarioName(defaultScenario: String) -> String {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["TEST_RUNNER_SMARTFILL_MOTION_SCENARIO"], !override.isEmpty {
            return override
        }
        let interval = smartFillMotionConfiguredIntervalSeconds()
        guard abs(interval - 5.0) > 0.000_1 else {
            return defaultScenario
        }
        let intervalText =
            abs(interval.rounded() - interval) < 0.000_1
            ? "\(Int(interval.rounded()))sec"
            : String(format: "%.3fsec", interval).replacingOccurrences(of: ".", with: "p")
        return defaultScenario.replacingOccurrences(of: "5sec", with: intervalText)
    }

    func smartFillMotionTraceStartTimeoutSeconds() -> TimeInterval {
        let environment = ProcessInfo.processInfo.environment
        let rawValue =
            environment["TEST_RUNNER_SMARTFILL_MOTION_TRACE_START_TIMEOUT_SECONDS"]
            ?? environment["SMARTFILL_MOTION_TRACE_START_TIMEOUT_SECONDS"]
        guard let rawValue,
            let value = TimeInterval(rawValue),
            value > 0
        else {
            return EvidenceCalibration.defaultMotionTraceTimeoutSeconds
        }
        return value
    }

    func writeMotionFrameEvidence(_ rows: [MotionFrameEvidenceRow], scenario: String) {
        rows.forEach { SmartFillRuntimeEvidenceSupport.assertRedactedSeedSummary($0.fields) }
        guard let directory = motionEvidenceDirectory() else { return }
        let baseName = sanitizedEvidenceFileName("smartfill-\(scenario)-\(deviceTag())-motion-frames")
        let dictionaries = rows.map(motionFrameDictionary)
        requireEvidenceWrite {
            try SmartFillRuntimeEvidenceSupport.writeJSONLines(
                dictionaries,
                to: directory.appendingPathComponent(baseName + ".jsonl")
            )
        }
        requireEvidenceWrite {
            try motionFrameCSV(rows)
                .write(to: directory.appendingPathComponent(baseName + ".csv"), atomically: true, encoding: .utf8)
        }
    }

    func writeProductSceneSequenceEvidence(
        _ rows: [ProductSceneSequenceRow],
        motionRows: [MotionFrameEvidenceRow],
        scenario: String
    ) {
        guard let directory = motionEvidenceDirectory() else { return }
        let dictionaries = rows.map(productSceneSequenceDictionary)
        let transitionDictionaries = dictionaries.filter { dictionary in
            dictionary["productTransitionActive"] as? String == "true"
        }
        let countsBySceneType = Dictionary(grouping: rows, by: \.manifestSceneType)
            .mapValues(\.count)
        let motionCoveredSceneTypes = ["double", "triple", "single"]
        let nonAcceptedObservedSceneTypes = Set(rows.map(\.manifestSceneType))
            .subtracting(Set(["double", "triple"]))
            .sorted()
        let visibleUncoveredMotionSceneTypes = Set(rows.map(\.manifestSceneType))
            .subtracting(Set(motionCoveredSceneTypes))
            .sorted()
        let cleanAvailableMotionSceneTypes = Set(
            motionRows.compactMap { row -> String? in
                guard row.fields["progressFrameStatus"] == "available",
                    row.fields["controlBarVisible"] == "false",
                    row.fields["appOverlayPollution"] == "none"
                else {
                    return nil
                }
                return row.manifestSceneType
            }
        ).sorted()
        let knownOutOfScopeVisualGap = !visibleUncoveredMotionSceneTypes.isEmpty
        let visualGapStatus = knownOutOfScopeVisualGap ? "VISUAL_GAP" : "NONE_OBSERVED"
        let manifest: [String: Any] = [
            "schemaVersion": "product-scope-evidence-v1",
            "scenario": scenario,
            "deviceTag": deviceTag(),
            "deviceRequirement": "any-iPhone-or-iPad",
            "configuredIntervalSeconds": smartFillMotionConfiguredIntervalSeconds(),
            "requestedSampleDurationSeconds": smartFillMotionSampleDurationSeconds(),
            "productScope": [
                "source": "full-product-continuous",
                "cleanAcceptedOnlyClaimAllowed": false,
                "motionCoveredSceneTypes": motionCoveredSceneTypes,
                "motionScopeExpandedToSingle": true,
                "motionScopeExpandedToFallback": false,
                "motionScopeExpandedToLegacy": false,
                "known_out_of_scope_visual_gap": knownOutOfScopeVisualGap,
                "nonAcceptedObservedSceneTypes": nonAcceptedObservedSceneTypes,
                "nonAcceptedCoverageStatus": nonAcceptedObservedSceneTypes.isEmpty
                    ? "not_observed_in_this_run" : "observed",
                "visibleUncoveredMotionSceneTypes": visibleUncoveredMotionSceneTypes,
                "cleanAvailableMotionSceneTypes": cleanAvailableMotionSceneTypes,
                "visualGapStatus": visualGapStatus
            ],
            "countsBySceneType": countsBySceneType,
            "rowCount": rows.count,
            "transitionActiveRowCount": transitionDictionaries.count,
            "sceneSequenceJSON": "scene-sequence.json",
            "sceneSequenceCSV": "scene-sequence.csv",
            "productTransitionProbesJSON": "product-transition-probes.json",
            "productTransitionProbesCSV": "product-transition-probes.csv"
        ]
        let sceneSequence: [String: Any] = [
            "schemaVersion": "product-scene-sequence-v1",
            "scenario": scenario,
            "deviceTag": deviceTag(),
            "deviceRequirement": "any-iPhone-or-iPad",
            "configuredIntervalSeconds": smartFillMotionConfiguredIntervalSeconds(),
            "requestedSampleDurationSeconds": smartFillMotionSampleDurationSeconds(),
            "source": "full-product-continuous",
            "countsBySceneType": countsBySceneType,
            "rowCount": rows.count,
            "transitionActiveRowCount": transitionDictionaries.count,
            "productScope": [
                "source": "full-product-continuous",
                "cleanAcceptedOnlyClaimAllowed": false,
                "motionCoveredSceneTypes": motionCoveredSceneTypes,
                "motionScopeExpandedToSingle": true,
                "motionScopeExpandedToFallback": false,
                "motionScopeExpandedToLegacy": false,
                "known_out_of_scope_visual_gap": knownOutOfScopeVisualGap,
                "nonAcceptedObservedSceneTypes": nonAcceptedObservedSceneTypes,
                "nonAcceptedCoverageStatus": nonAcceptedObservedSceneTypes.isEmpty
                    ? "not_observed_in_this_run" : "observed",
                "visibleUncoveredMotionSceneTypes": visibleUncoveredMotionSceneTypes,
                "cleanAvailableMotionSceneTypes": cleanAvailableMotionSceneTypes,
                "visualGapStatus": visualGapStatus
            ],
            "rows": dictionaries
        ]
        let productTransitionProbes: [String: Any] = [
            "schemaVersion": "product-transition-probes-v1",
            "scenario": scenario,
            "deviceTag": deviceTag(),
            "transitionActiveRowCount": transitionDictionaries.count,
            "rows": transitionDictionaries
        ]
        requireEvidenceWrite {
            try SmartFillRuntimeEvidenceSupport.writeJSONObject(
                manifest,
                to: directory.appendingPathComponent("manifest.json")
            )
        }
        requireEvidenceWrite {
            try SmartFillRuntimeEvidenceSupport.writeJSONObject(
                sceneSequence,
                to: directory.appendingPathComponent("scene-sequence.json")
            )
        }
        requireEvidenceWrite {
            try productSceneSequenceCSV(rows)
                .write(to: directory.appendingPathComponent("scene-sequence.csv"), atomically: true, encoding: .utf8)
        }
        requireEvidenceWrite {
            try SmartFillRuntimeEvidenceSupport.writeJSONObject(
                productTransitionProbes,
                to: directory.appendingPathComponent("product-transition-probes.json")
            )
        }
        requireEvidenceWrite {
            let transitionRows = rows.filter { $0.productTransitionFields["productTransitionActive"] == "true" }
            try productSceneSequenceCSV(transitionRows)
                .write(
                    to: directory.appendingPathComponent("product-transition-probes.csv"), atomically: true,
                    encoding: .utf8
                )
        }
    }
}
#endif
