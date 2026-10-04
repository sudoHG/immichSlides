import Foundation
import XCTest

private enum SmartFillRuntimeEvidenceSupport {
    static func writeScreenshotPNG(_ data: Data, to fileURL: URL) -> URL? {
        do {
            try data.write(to: fileURL, options: .atomic)
            guard try Data(contentsOf: fileURL) == data else { return nil }
            return fileURL
        } catch {
            return nil
        }
    }

    struct AssetIDReplayValidationRow {
        let sequence: Int
        let rule: String
        let expected: String
        let observedSlotRef: String?
        let observedCurrentAssetRef: String?
        let observedReplayIndex: Int?
        let status: String
    }

    struct AssetIDReplayMonotonicProgress {
        let expected: String
        let status: String
        let shouldIncludeManifest: Bool
        let shouldStopSampling: Bool
        let nextPreviousReplayAssetIndex: Int?
        let failureMessage: String?
    }

    static let schemaVersion = "pr49-decision-layer-v1"
    static let requiredRuntimePhaseKeys = [
        "playbackEntryRequested",
        "assetPoolRequestStarted",
        "assetPoolReady",
        "firstScenePlanningStarted",
        "firstScenePlanned",
        "firstScenePublished",
        "firstSlotReady",
        "allVisibleSlotsReady"
    ]
    static let harnessOnlyJSONFields = [
        "harnessPhaseTimestampsMs",
        "harnessPhaseDurationsMs",
        "harnessLaunchToFirstManifestObservedMs",
        "harnessLaunchToFirstNonLoadingScreenshotMs",
        "crossClockSummaryPolicy",
        "firstNonLoadingScreenshotCaptured"
    ]
    static let requiredJSONFields = [
        "schemaVersion",
        "runId",
        "prHead",
        "baseHead",
        "sequence",
        "sceneIdHash",
        "sceneType",
        "isFallback",
        "fallbackReason",
        "fallbackCategory",
        "layoutVariant",
        "layoutPreset",
        "surfaceKey",
        "surfaceFingerprint",
        "photoCanvasId",
        "photoCanvasPointSize",
        "photoCanvasPixelSize",
        "canvasCoverage",
        "emptyCanvasRatio",
        "maxContinuousEmptyAxisRatio",
        "gapPixelCount",
        "overlapPixelCount",
        "slotCount",
        "slotFrames",
        "slotCropRects",
        "protectionOverlapDetails",
        "slotReadiness",
        "ledgerSceneAssets",
        "controlBarVisible",
        "controlBarHardRejected",
        "controlBarSubjectOverlapWarning",
        "exifOverlayVisible",
        "exifOverlayHardRejected",
        "publishReason",
        "preparedHit",
        "actionToSceneMs",
        "captureTimestamp",
        "screenshotPath",
        "startupRunId",
        "startupSequence",
        "startupClockSource",
        "runtimePhaseTimestampsMs",
        "runtimePhaseDurationsMs",
        "firstSceneRuntimeMs",
        "firstSlotReadyRuntimeMs",
        "allVisibleSlotsReadyRuntimeMs",
        "startupMissingPhases",
        "startupBlockingPhase",
        "assetPoolSizeAtFirstPlan",
        "eligibleCandidateCountAtFirstPlan",
        "plannerAttemptCountAtFirstPlan",
        "candidateWindowUsedAtFirstPlan",
        "firstSceneSlotReadiness",
        "firstSceneReadySlotCount",
        "firstScenePendingSlotCount",
        "firstSceneFailedSlotCount",
        "photoLoadPhaseTimestampsMs",
        "photoLoadPhaseDurationsMs",
        "firstPhotoCacheStatus",
        "firstImageDisplayedRuntimeMs",
        "firstImageLoadStatus",
        "fallbackReasonTopList",
        "rejectedLayoutReasonTopList",
        "rejectedLayoutDiagnostics",
        "candidateRejectReasonTopList",
        "lookaheadExhausted",
        "resourceReadinessAffectedFallback",
        "controlBarAffectedFallback",
        "legacyRendererUsedForSmartFillFallback",
        "fallbackRootCauseBucket",
        "currentAssetDisposition",
        "currentAssetRef",
        "currentAssetAbsentReason",
        "currentAssetSlotAreaRatio",
        "currentAssetCropRetention",
        "currentAssetProtectedRegionCoverage",
        "currentAssetFaceProtectionPassed",
        "currentAssetSubjectProtectionPassed",
        "currentAssetVisibleQualityClass",
        "cropRetentionThresholdUsed",
        "slotRoles",
        "slotRefs",
        "candidateWindowRequested",
        "candidateWindowUsed",
        "candidateWindowExpansionTrace",
        "acceptedSceneSearchTier",
        "recentVisibleLimit",
        "recentVisibleCandidateCount",
        "duplicateVisibleSlotCount",
        "duplicateVisibleSlotRefs",
        "duplicateReuseReason",
        "multiSlotSuccessCount",
        "smartFillSingleFillCount",
        "singleRiskCount",
        "hardFallbackCount",
        "nonMultiSlotOutcomeCount",
        "userPerceivedFailureCount",
        "currentAssetAbsentSceneCount",
        "visualUnverifiedCount",
        "unknownOutcomeBucketCount",
        "visualReviewStatus"
    ]
    static let requiredHarnessSummaryFields = [
        "startupRunId",
        "startupClockSource",
        "harnessPhaseTimestampsMs",
        "harnessPhaseDurationsMs",
        "harnessLaunchToFirstManifestObservedMs",
        "harnessLaunchToFirstNonLoadingScreenshotMs",
        "crossClockSummaryPolicy"
    ]
    static let requiredSummaryFields = [
        "sceneType",
        "fallback",
        "fallbackCategory",
        "layoutVariant",
        "ratioPreset",
        "surfaceKey",
        "surfaceFingerprint",
        "photoCanvasId",
        "photoCanvasPointSize",
        "photoCanvasPixelSize",
        "canvasCoverage",
        "emptyCanvasRatio",
        "maxContinuousEmptyAxisRatio",
        "gapPixelCount",
        "overlapPixelCount",
        "slotCount",
        "slotRoles",
        "slotRefs",
        "currentAssetDisposition",
        "currentAssetAbsentReason",
        "currentAssetSlotAreaRatio",
        "currentAssetCropRetention",
        "currentAssetProtectedRegionCoverage",
        "currentAssetFaceProtectionPassed",
        "currentAssetSubjectProtectionPassed",
        "currentAssetVisibleQualityClass",
        "acceptedSceneSearchTier",
        "candidateWindowRequested",
        "candidateWindowExpansionTrace",
        "slotFrames",
        "slotCropRects",
        "slotReadiness",
        "ledgerSceneAssets",
        "controlBarVisible",
        "controlBarHardRejected",
        "controlBarSubjectOverlapWarningCount",
        "exifOverlayVisible",
        "exifOverlayHardRejected",
        "publishReason",
        "preparedHit",
        "rejectedLayoutDiagnostics",
        "protectionOverlapDetails"
    ]

    static func sceneIdHash(rawManifest: String, scenario: String, sequence: Int) -> String {
        let input = "\(scenario)|\(sequence)|\(rawManifest)"
        return stableHash(input).prefix(16).description
    }

    static func makeRecord(
        manifestFields fields: [String: String],
        rawManifest: String,
        scenario: String,
        deviceTag: String,
        sequence: Int,
        sceneIdHash: String,
        screenshotPath: String,
        captureTimestamp: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: Any] {
        let fallbackReason = value("fallback", in: fields, default: "none")
        let fallbackCategory = value("fallbackCategory", in: fields, default: "none")
        let isFallback =
            value("sceneType", in: fields, default: "") == "fallback" || fallbackReason != "none"
            || fallbackCategory != "none"
        let runtimePhaseTimestamps = phaseMapValue("runtimePhaseTimestampsMs", in: fields)
        let runtimePhaseDurations = phaseMapValue("runtimePhaseDurationsMs", in: fields)
        let photoLoadPhaseTimestamps = phaseMapValue("photoLoadPhaseTimestampsMs", in: fields)
        let photoLoadPhaseDurations = phaseMapValue("photoLoadPhaseDurationsMs", in: fields)
        let startupMissingPhases = requiredRuntimePhaseKeys.filter { phase in
            runtimePhaseTimestamps[phase] == nil || runtimePhaseDurations[phase] == nil
        }
        let firstSceneSlotReadiness = listValue(
            "firstSceneSlotReadiness",
            in: fields,
            fallbackKey: "slotReadiness"
        )
        let fallbackRootCauseBucket = normalizedFallbackRootCauseBucket(
            fields: fields,
            isFallback: isFallback,
            fallbackReason: fallbackReason,
            fallbackCategory: fallbackCategory
        )
        let slotCount = intValue("slotCount", in: fields, default: 0)
        let candidateWindowUsed = intValue("candidateWindowUsed", in: fields, default: 0)
        let acceptedSceneSearchTier = value(
            "acceptedSceneSearchTier",
            in: fields,
            default: defaultAcceptedSceneSearchTier(isFallback: isFallback, slotCount: slotCount)
        )
        let currentAssetDisposition = value(
            "currentAssetDisposition",
            in: fields,
            default: isFallback ? "fallback-current" : (slotCount == 1 ? "single-slot" : "primary-slot")
        )
        let currentAssetVisibleQualityClass = value(
            "currentAssetVisibleQualityClass",
            in: fields,
            default: isFallback ? "fail" : "acceptable"
        )
        // The collector never accepts an env var as sign-off for human visual review;
        // per-image verdicts stay in a separate review record.
        let visualReviewStatus = "VISUAL_REVIEW_REQUIRED"
        let visualUnverifiedCount = 1
        let hardFallbackCount = isFallback ? 1 : 0
        let smartFillSingleFillCount = !isFallback && slotCount == 1 && acceptedSceneSearchTier == "single-fill" ? 1 : 0
        let singleRiskCount = acceptedSceneSearchTier == "single-risk" ? 1 : 0
        let currentAssetAbsentSceneCount = currentAssetDisposition == "absent-hard-fail" ? 1 : 0
        let nonMultiSlotOutcomeCount =
            hardFallbackCount + singleRiskCount + currentAssetAbsentSceneCount + visualUnverifiedCount
        let userPerceivedFailureCount = nonMultiSlotOutcomeCount
        let multiSlotSuccessCount =
            !isFallback && slotCount >= 2 && currentAssetVisibleQualityClass == "acceptable"
                && currentAssetAbsentSceneCount == 0 && visualUnverifiedCount == 0 ? 1 : 0
        let slotRefs = redactedAssetListValue("slotRefs", in: fields)
        let currentAssetRef = currentAssetRefValue(
            disposition: currentAssetDisposition,
            slotRefs: slotRefs
        )
        let duplicateSlotRefs = duplicateRefs(in: slotRefs)
        let firstImageLoadStatus = finalFirstImageLoadStatus(fields: fields, screenshotPath: screenshotPath)

        return [
            "schemaVersion": schemaVersion,
            "runId": runId(scenario: scenario, deviceTag: deviceTag, environment: environment),
            "prHead": gitBindingValue("IMMICHSLIDES_PR_HEAD", environment: environment),
            "baseHead": gitBindingValue("IMMICHSLIDES_BASE_HEAD", environment: environment),
            "sequence": sequence,
            "sceneIdHash": sceneIdHash,
            "sceneType": value("sceneType", in: fields, default: "missing"),
            "isFallback": isFallback,
            "fallbackReason": fallbackReason,
            "fallbackCategory": fallbackCategory,
            "layoutVariant": value("layoutVariant", in: fields, default: "missing"),
            "layoutPreset": value("ratioPreset", in: fields, default: "missing"),
            "surfaceKey": value("surfaceKey", in: fields, default: "missing"),
            "surfaceFingerprint": value("surfaceFingerprint", in: fields, default: "missing"),
            "photoCanvasId": value("photoCanvasId", in: fields, default: "missing"),
            "photoCanvasPointSize": value("photoCanvasPointSize", in: fields, default: "missing"),
            "photoCanvasPixelSize": value("photoCanvasPixelSize", in: fields, default: "missing"),
            "canvasCoverage": doubleValue("canvasCoverage", in: fields, default: 0),
            "emptyCanvasRatio": doubleValue("emptyCanvasRatio", in: fields, default: 1),
            "maxContinuousEmptyAxisRatio": doubleValue("maxContinuousEmptyAxisRatio", in: fields, default: 1),
            "gapPixelCount": intValue("gapPixelCount", in: fields, default: 0),
            "overlapPixelCount": intValue("overlapPixelCount", in: fields, default: 0),
            "slotCount": slotCount,
            "slotFrames": listValue("slotFrames", in: fields),
            "slotCropRects": listValue("slotCropRects", in: fields),
            "protectionOverlapDetails": redactedDiagnosticValue(
                value("protectionOverlapDetails", in: fields, default: "none")),
            "slotReadiness": listValue("slotReadiness", in: fields),
            "ledgerSceneAssets": redactedAssetListValue("ledgerSceneAssets", in: fields),
            "controlBarVisible": boolValue("controlBarVisible", in: fields, default: false),
            "controlBarHardRejected": boolValue("controlBarHardRejected", in: fields, default: false),
            "controlBarSubjectOverlapWarning": intValue("controlBarSubjectOverlapWarningCount", in: fields, default: 0)
                > 0,
            "exifOverlayVisible": boolValue("exifOverlayVisible", in: fields, default: false),
            "exifOverlayHardRejected": boolValue("exifOverlayHardRejected", in: fields, default: false),
            "publishReason": value("publishReason", in: fields, default: "missing"),
            "preparedHit": boolValue("preparedHit", in: fields, default: false),
            "actionToSceneMs": doubleValue("actionToSceneLatencyMs", in: fields, default: 0),
            "captureTimestamp": captureTimestamp,
            "screenshotPath": screenshotPath,
            "startupRunId": runId(scenario: scenario, deviceTag: deviceTag, environment: environment),
            "startupSequence": sequence,
            "startupClockSource": "app-runtime",
            "runtimePhaseTimestampsMs": runtimePhaseTimestamps,
            "runtimePhaseDurationsMs": runtimePhaseDurations,
            "firstSceneRuntimeMs": startupRuntimeValue(
                explicitField: "firstSceneRuntimeMs",
                fallbackPhase: "firstScenePublished",
                in: fields,
                runtimePhaseTimestamps: runtimePhaseTimestamps
            ),
            "firstSlotReadyRuntimeMs": startupRuntimeValue(
                explicitField: "firstSlotReadyRuntimeMs",
                fallbackPhase: "firstSlotReady",
                in: fields,
                runtimePhaseTimestamps: runtimePhaseTimestamps
            ),
            "allVisibleSlotsReadyRuntimeMs": startupRuntimeValue(
                explicitField: "allVisibleSlotsReadyRuntimeMs",
                fallbackPhase: "allVisibleSlotsReady",
                in: fields,
                runtimePhaseTimestamps: runtimePhaseTimestamps
            ),
            "startupMissingPhases": startupMissingPhases,
            "startupBlockingPhase": startupBlockingPhase(in: runtimePhaseDurations),
            "assetPoolSizeAtFirstPlan": intValue("assetPoolSizeAtFirstPlan", in: fields, default: 0),
            "eligibleCandidateCountAtFirstPlan": intValue("eligibleCandidateCountAtFirstPlan", in: fields, default: 0),
            "plannerAttemptCountAtFirstPlan": intValue("plannerAttemptCountAtFirstPlan", in: fields, default: 0),
            "candidateWindowUsedAtFirstPlan": intValue(
                "candidateWindowUsedAtFirstPlan",
                in: fields,
                default: candidateWindowUsed
            ),
            "firstSceneSlotReadiness": firstSceneSlotReadiness,
            "firstSceneReadySlotCount": readinessCount("ready", in: firstSceneSlotReadiness),
            "firstScenePendingSlotCount": readinessCount("pending", in: firstSceneSlotReadiness),
            "firstSceneFailedSlotCount": readinessCount("failed", in: firstSceneSlotReadiness),
            "photoLoadPhaseTimestampsMs": photoLoadPhaseTimestamps,
            "photoLoadPhaseDurationsMs": photoLoadPhaseDurations,
            "firstPhotoCacheStatus": redactedRootCauseBucket(
                value("firstPhotoCacheStatus", in: fields, default: "missing")
            ),
            "firstImageDisplayedRuntimeMs": doubleValue("firstImageDisplayedRuntimeMs", in: fields, default: 0),
            "firstImageLoadStatus": firstImageLoadStatus,
            "fallbackReasonTopList": redactedReasonListValue("fallbackReasonTopList", in: fields),
            "rejectedLayoutReasonTopList": redactedReasonListValue("rejectedLayoutReasonTopList", in: fields),
            "rejectedLayoutDiagnostics": redactedReasonListValue("rejectedLayoutDiagnostics", in: fields),
            "candidateRejectReasonTopList": redactedReasonListValue("candidateRejectReasonTopList", in: fields),
            "lookaheadExhausted": boolValue("lookaheadExhausted", in: fields, default: false),
            "resourceReadinessAffectedFallback": boolValue(
                "resourceReadinessAffectedFallback", in: fields, default: false),
            "controlBarAffectedFallback": boolValue("controlBarAffectedFallback", in: fields, default: false),
            "legacyRendererUsedForSmartFillFallback": boolValue(
                "legacyRendererUsedForSmartFillFallback", in: fields, default: false),
            "fallbackRootCauseBucket": fallbackRootCauseBucket,
            "currentAssetDisposition": currentAssetDisposition,
            "currentAssetRef": currentAssetRef,
            "currentAssetAbsentReason": value(
                "currentAssetAbsentReason",
                in: fields,
                default: currentAssetDisposition == "absent-hard-fail" ? "no-legal-layout" : "none"
            ),
            "currentAssetSlotAreaRatio": doubleValue("currentAssetSlotAreaRatio", in: fields, default: 0),
            "currentAssetCropRetention": doubleValue("currentAssetCropRetention", in: fields, default: 0),
            "currentAssetProtectedRegionCoverage": doubleValue(
                "currentAssetProtectedRegionCoverage", in: fields, default: 0),
            "currentAssetFaceProtectionPassed": boolValue(
                "currentAssetFaceProtectionPassed", in: fields, default: currentAssetVisibleQualityClass == "acceptable"
            ),
            "currentAssetSubjectProtectionPassed": boolValue(
                "currentAssetSubjectProtectionPassed", in: fields,
                default: currentAssetVisibleQualityClass == "acceptable"),
            "currentAssetVisibleQualityClass": currentAssetVisibleQualityClass,
            "cropRetentionThresholdUsed": doubleValue("cropRetentionThresholdUsed", in: fields, default: 0.60),
            "slotRoles": listValue("slotRoles", in: fields),
            "slotRefs": slotRefs,
            "candidateWindowRequested": intValue("candidateWindowRequested", in: fields, default: candidateWindowUsed),
            "candidateWindowUsed": candidateWindowUsed,
            "candidateWindowExpansionTrace": listValue("candidateWindowExpansionTrace", in: fields),
            "acceptedSceneSearchTier": acceptedSceneSearchTier,
            "recentVisibleLimit": intValue(
                "recentVisibleLimit", in: fields, default: defaultRecentVisibleLimit(deviceTag: deviceTag)),
            "recentVisibleCandidateCount": intValue(
                "recentVisibleCandidateCount", in: fields, default: max(0, slotCount)),
            "duplicateVisibleSlotCount": duplicateSlotRefs.count,
            "duplicateVisibleSlotRefs": duplicateSlotRefs,
            "duplicateReuseReason": duplicateSlotRefs.isEmpty
                ? "none" : value("duplicateReuseReason", in: fields, default: "validator-blocked"),
            "multiSlotSuccessCount": multiSlotSuccessCount,
            "smartFillSingleFillCount": smartFillSingleFillCount,
            "singleRiskCount": singleRiskCount,
            "hardFallbackCount": hardFallbackCount,
            "nonMultiSlotOutcomeCount": nonMultiSlotOutcomeCount,
            "userPerceivedFailureCount": userPerceivedFailureCount,
            "currentAssetAbsentSceneCount": currentAssetAbsentSceneCount,
            "visualUnverifiedCount": visualUnverifiedCount,
            "unknownOutcomeBucketCount": 0,
            "visualReviewStatus": visualReviewStatus
        ]
    }

    static func makeHarnessSummary(
        startupRunId: String,
        appLaunchStartMs: Double,
        testServerConfigInjectedMs: Double,
        firstManifestObservedMs: Double,
        firstNonLoadingScreenshotCapturedMs: Double
    ) -> [String: Any] {
        let timestamps = [
            "appLaunchStart": appLaunchStartMs,
            "testServerConfigInjected": testServerConfigInjectedMs,
            "firstManifestObserved": firstManifestObservedMs,
            "firstNonLoadingScreenshotCaptured": firstNonLoadingScreenshotCapturedMs
        ]
        return [
            "startupRunId": startupRunId,
            "startupClockSource": "xctest-harness",
            "harnessPhaseTimestampsMs": timestamps,
            "harnessPhaseDurationsMs": [
                "testServerConfigInjected": max(0, testServerConfigInjectedMs - appLaunchStartMs),
                "firstManifestObserved": max(0, firstManifestObservedMs - appLaunchStartMs),
                "firstNonLoadingScreenshotCaptured": max(0, firstNonLoadingScreenshotCapturedMs - appLaunchStartMs)
            ],
            "harnessLaunchToFirstManifestObservedMs": max(0, firstManifestObservedMs - appLaunchStartMs),
            "harnessLaunchToFirstNonLoadingScreenshotMs": max(
                0, firstNonLoadingScreenshotCapturedMs - appLaunchStartMs),
            "crossClockSummaryPolicy": "summary-only-cross-clock-observed"
        ]
    }

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
            "manifestVersion=pr49-scenario-manifest-v2",
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

    private static func clockSourcesLine(for records: [[String: Any]]) -> String {
        Dictionary(grouping: records) { record in
            (record["startupClockSource"] as? String) ?? "missing"
        }
        .mapValues(\.count)
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: ";")
    }

    private static func runtimePhaseKeyCompletenessLine(for records: [[String: Any]]) -> String {
        let missingCounts = records.compactMap { record in
            record["startupMissingPhases"] as? [String]
        }
        let missingTotal = missingCounts.reduce(0) { $0 + $1.count }
        return missingTotal == 0 ? "complete" : "missingPhaseCount=\(missingTotal)"
    }

    private static func runId(
        scenario: String,
        deviceTag: String,
        environment: [String: String]
    ) -> String {
        environment["IMMICHSLIDES_RUNTIME_RUN_ID"] ?? environment["TEST_RUNNER_IMMICHSLIDES_RUNTIME_RUN_ID"]
            ?? "\(scenario)-\(deviceTag)-local"
    }

    private static func gitBindingValue(
        _ key: String,
        environment: [String: String]
    ) -> String {
        environment[key] ?? environment["TEST_RUNNER_\(key)"]
            ?? "local-\(key.lowercased().replacingOccurrences(of: "_", with: "-"))-not-provided"
    }

    private static func defaultAcceptedSceneSearchTier(isFallback: Bool, slotCount: Int) -> String {
        if isFallback {
            return "fallback"
        }
        return slotCount >= 2 ? "double" : "single-fill"
    }

    private static func defaultRecentVisibleLimit(deviceTag: String) -> Int {
        deviceTag.localizedCaseInsensitiveContains("iphone") ? 12 : 16
    }

    private static func value(
        _ key: String,
        in fields: [String: String],
        default defaultValue: String
    ) -> String {
        fields[key]?.isEmpty == false ? fields[key]! : defaultValue
    }

    private static func listValue(
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

    private static func redactedAssetListValue(_ key: String, in fields: [String: String]) -> [String] {
        listValue(key, in: fields).map { rawValue in
            "assetRef-\(stableHash(rawValue).prefix(12))"
        }
    }

    private static func duplicateRefs(in values: [String]) -> [String] {
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

    private static func currentAssetRefValue(disposition: String, slotRefs: [String]) -> String {
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

    private static func redactedReasonListValue(_ key: String, in fields: [String: String]) -> [String] {
        listValue(key, in: fields).map { rawValue in
            containsSensitiveToken(rawValue) ? "redacted-\(stableHash(rawValue).prefix(12))" : rawValue
        }
    }

    private static func redactedRootCauseBucket(_ rawValue: String) -> String {
        containsSensitiveToken(rawValue) ? "unknown" : rawValue
    }

    private static func redactedDiagnosticValue(_ rawValue: String) -> String {
        containsSensitiveToken(rawValue) ? "redacted-\(stableHash(rawValue).prefix(12))" : rawValue
    }

    private static func normalizedFallbackRootCauseBucket(
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

    private static func finalFirstImageLoadStatus(fields: [String: String], screenshotPath: String) -> String {
        let rawStatus = redactedRootCauseBucket(value("firstImageLoadStatus", in: fields, default: "missing"))
        guard !screenshotPath.isEmpty else { return rawStatus }
        switch rawStatus {
        case "decoded", "downloaded":
            return "displayed"
        default:
            return rawStatus
        }
    }

    private static func containsSensitiveToken(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.contains("http://") || lowercased.contains("https://") || lowercased.contains("api_key")
            || lowercased.contains("api key") || lowercased.contains("token") || lowercased.contains("bearer")
            || lowercased.contains("authorization") || lowercased.contains("assetid") || lowercased.contains("personid")
            || lowercased.contains("serverurl") || lowercased.contains("raw-asset") || lowercased.contains("raw-person")
    }

    private static func phaseMapValue(_ key: String, in fields: [String: String]) -> [String: Double] {
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

    private static func startupRuntimeValue(
        explicitField: String,
        fallbackPhase: String,
        in fields: [String: String],
        runtimePhaseTimestamps: [String: Double]
    ) -> Double {
        doubleValue(explicitField, in: fields, default: runtimePhaseTimestamps[fallbackPhase] ?? 0)
    }

    private static func startupBlockingPhase(in runtimePhaseDurations: [String: Double]) -> String {
        runtimePhaseDurations
            .filter { requiredRuntimePhaseKeys.contains($0.key) }
            .max { lhs, rhs in lhs.value < rhs.value }?
            .key ?? "missing"
    }

    private static func readinessCount(_ readiness: String, in values: [String]) -> Int {
        values.filter { $0.localizedCaseInsensitiveCompare(readiness) == .orderedSame }.count
    }

    private static func doubleValue(
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

    private static func intValue(
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

    private static func intValue(_ key: String, in record: [String: Any]) -> Int {
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

    private static func stringValue(_ key: String, in record: [String: Any]) -> String? {
        record[key] as? String
    }

    private static func surfaceLockKey(surfaceKey: String?, deviceTag: String) -> String {
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

    private static func boolValue(
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

    private static func percentile(_ percentile: Double, values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let index = min(max(Int(ceil(percentile * Double(values.count))) - 1, 0), values.count - 1)
        return values[index]
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static func parseAssetIDReplayList(_ text: String) -> [String] {
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

    private static func splitAssetIDReplayList(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ", \n\t\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private enum SmartFillFallbackEvidencePolicy {
    static let forbiddenCategories: Set<String> = [
        "controlbar-triggered",
        "exif-triggered",
        "pending-resource-triggered",
        "recovery-fallback",
        "unknown"
    ]

    static func distribution(from categories: [String]) -> [String: Int] {
        Dictionary(grouping: categories) { category in
            category.isEmpty ? "missing" : category
        }
        .mapValues(\.count)
    }

    static func forbiddenDistribution(from distribution: [String: Int]) -> [String: Int] {
        distribution.filter { forbiddenCategories.contains($0.key) }
    }

    static func format(_ distribution: [String: Int]) -> String {
        distribution
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ";")
    }
}

private func requireEvidenceWrite(_ write: () throws -> Void) {
    do {
        try write()
    } catch {
        XCTFail("Failed to write SmartFill evidence: \(error.localizedDescription)")
    }
}

#if os(iOS)
final class PlaybackSmartFillVisualUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testScreenshotWriterRejectsUnwritableDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blockedFile = directory.appendingPathComponent("blocked.png")
        try FileManager.default.createDirectory(at: blockedFile, withIntermediateDirectories: true)

        XCTAssertNil(SmartFillRuntimeEvidenceSupport.writeScreenshotPNG(Data([1, 2, 3]), to: blockedFile))
        XCTAssertTrue(FileManager.default.fileExists(atPath: blockedFile.path, isDirectory: nil))
    }

    func testScreenshotWriterReturnsReadableFileOnSuccess() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let bytes = Data([1, 2, 3])

        XCTAssertEqual(SmartFillRuntimeEvidenceSupport.writeScreenshotPNG(bytes, to: fileURL), fileURL)
        XCTAssertEqual(try Data(contentsOf: fileURL), bytes)
    }

    @MainActor
    func testSmartFillRandomPlaybackTwentyScenes() throws {
        let app = try launchConfiguredAppAtModeSelection()
        startRandomPlaybackFromModeSelection(app: app)

        let evidence = try collectTwentySceneEvidence(app: app, scenario: "random")
        assertPolicies(in: evidence, contain: "portrait", scenario: "random playback, portrait")
        assertSurfaces(in: evidence, orientation: .portrait, scenario: "random playback, portrait")
        assertFallbackDistributionMeetsSpec(in: evidence, scenario: "random playback, portrait")
    }

    @MainActor
    func testSmartFillMotionRealAutoplayFullProductEvidence() throws {
        let scenario = smartFillMotionScenarioName(
            defaultScenario: "iphone-5sec-interval-any-iphone-real-autoplay-full-product"
        )
        let app = try launchSmartFillMotionEvidenceAppAtModeSelection(
            scenario: scenario,
            forceAutoplayOff: false,
            enableSmartFillMotionTrace: true
        )
        startRandomPlaybackFromModeSelection(app: app)

        XCTAssertTrue(
            waitUntil(timeout: 12) {
                !app.buttons["slideshow.control.settings.button"].exists
            },
            "\(scenario) control bar must auto-hide before sampling so clean stable-visible segments are not polluted by the overlay"
        )

        let traceStartTimeout = smartFillMotionTraceStartTimeoutSeconds()
        let initialManifest = try waitForCurrentManifest(
            app: app,
            timeout: max(45, traceStartTimeout + 5)
        )
        var acceptedSlotRefs = Set<String>()
        if initialManifest.sceneType == "double" || initialManifest.sceneType == "triple" {
            acceptedSlotRefs.insert(initialManifest.slotRefs)
        }
        let sampleDuration = smartFillMotionSampleDurationSeconds()
        let traceText = try appSmartFillMotionTraceText(
            app: app,
            timeout: sampleDuration + traceStartTimeout + 30,
        )
        let rows = motionFrameRows(
            fromTraceText: traceText,
            fallbackManifest: initialManifest
        )
        let productRows = productSceneSequenceRows(
            fromTraceText: traceText,
            fallbackManifest: initialManifest
        )
        for row in rows {
            let slotRefs =
                row.fields["manifestSlotRefs"]?.replacingOccurrences(of: "|", with: ",") ?? row.manifestSlotRefs
            let sceneType = row.fields["manifestSceneType"] ?? row.manifestSceneType
            if sceneType == "double" || sceneType == "triple" {
                acceptedSlotRefs.insert(slotRefs)
            }
        }
        if let latest = currentManifest(app: app),
            latest.sceneType == "double" || latest.sceneType == "triple"
        {
            acceptedSlotRefs.insert(latest.slotRefs)
        }

        writeProductSceneSequenceEvidence(productRows, motionRows: rows, scenario: scenario)
        writeMotionFrameEvidence(rows, scenario: scenario)
        let productSceneTypes = Set(productRows.map(\.manifestSceneType))
        let motionCoveredSceneTypes = Set(["double", "triple", "single"])
        let visibleUncoveredMotionSceneTypes =
            productSceneTypes
            .subtracting(motionCoveredSceneTypes)
            .sorted()
        let cleanAvailableMotionSceneTypes = Set(
            rows.compactMap { row -> String? in
                guard row.fields["progressFrameStatus"] == "available",
                    row.fields["controlBarVisible"] == "false",
                    row.fields["appOverlayPollution"] == "none"
                else {
                    return nil
                }
                return row.manifestSceneType
            })
        let coveredSceneTypesMissingCleanMotionRows =
            productSceneTypes
            .intersection(motionCoveredSceneTypes)
            .subtracting(cleanAvailableMotionSceneTypes)
            .sorted()
        let productTransitionRows = productRows.filter { row in
            row.productTransitionFields["productTransitionActive"] == "true"
        }
        let productTransitionRowsWithoutBacking = productTransitionRows.filter { row in
            row.productTransitionFields["productBlackBackingActive"] != "true"
        }
        let availableRows = rows.filter { row in
            row.fields["progressFrameStatus"] == "available"
        }
        XCTAssertFalse(
            productRows.isEmpty, "\(scenario) must capture the full continuous product playback sceneType sequence")
        XCTAssertFalse(
            productTransitionRows.isEmpty, "\(scenario) product sequence must cover at least one real transition")
        XCTAssertTrue(
            productTransitionRowsWithoutBacking.isEmpty,
            "\(scenario) every product SmartFill transition must enable the black backing")
        XCTAssertTrue(
            visibleUncoveredMotionSceneTypes.isEmpty,
            "\(scenario) VISUAL_GAP: the full product sequence shows visible sceneTypes without runtime motion: \(visibleUncoveredMotionSceneTypes)"
        )
        XCTAssertTrue(
            coveredSceneTypesMissingCleanMotionRows.isEmpty,
            "\(scenario) VISUAL_GAP: visible sceneTypes the manifest declares covered lack a clean available motion row: \(coveredSceneTypesMissingCleanMotionRows)"
        )
        XCTAssertTrue(
            productSceneTypes.contains("double") || productSceneTypes.contains("triple"),
            "\(scenario) product sequence must still include an accepted SmartFill scene"
        )
        XCTAssertGreaterThanOrEqual(
            acceptedSlotRefs.count, 2, "\(scenario) real autoplay must show at least two accepted SmartFill scenes")
        XCTAssertFalse(rows.isEmpty, "\(scenario) must capture motion frame probes")
        XCTAssertFalse(
            availableRows.isEmpty, "\(scenario) motion frame probes must include an available progress frame")
        _ = captureRuntimeScreenshot(
            app: app,
            name: "smartfill-\(scenario)-\(deviceTag())-final",
            attachToXCTest: true
        )
    }

    @MainActor
    func testSmartFillMotionInteractionLivenessEvidence() throws {
        let scenario = smartFillMotionScenarioName(
            defaultScenario: "iphone-5sec-interval-any-iphone-interaction-liveness"
        )
        let app = try launchSmartFillMotionEvidenceAppAtModeSelection(
            scenario: scenario,
            forceAutoplayOff: false,
            enableSmartFillMotionTrace: true
        )
        startRandomPlaybackFromModeSelection(app: app)

        XCTAssertTrue(
            waitUntil(timeout: 12) {
                !app.buttons["slideshow.control.settings.button"].exists
            },
            "\(scenario) control bar must auto-hide before interaction sampling so the initial overlay is not taken for interaction noise"
        )
        let initialManifest = try waitForCurrentManifest(
            app: app,
            timeout: max(45, smartFillMotionTraceStartTimeoutSeconds() + 5)
        )
        let traceReferenceTime = try waitForSmartFillMotionTraceCollecting(
            app: app,
            timeout: smartFillMotionTraceStartTimeoutSeconds() + 10
        )
        var actions: [[String: Any]] = []
        func recordAction(_ action: String) {
            let elapsedSeconds = max(0, ProcessInfo.processInfo.systemUptime - traceReferenceTime)
            actions.append([
                "action": action,
                "elapsedSeconds": elapsedSeconds,
                "timestamp": SmartFillRuntimeEvidenceSupport.captureTimestamp()
            ])
        }

        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        recordAction("tap-image-show-control-bar")
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: 4),
            "\(scenario) tapping the photo must show the control bar"
        )

        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: 4),
            "\(scenario) pause/resume button must be found while the control bar is visible"
        )
        tapElement(playPauseButton)
        recordAction("pause")

        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        XCTAssertTrue(
            playPauseButton.waitForExistence(timeout: 4),
            "\(scenario) resume button must still be found after pause"
        )
        tapElement(playPauseButton)
        recordAction("resume")

        XCTAssertTrue(
            waitUntil(timeout: 10) {
                !settingsButton.exists
            },
            "\(scenario) control bar must auto-hide after pause/resume"
        )
        recordAction("control-bar-auto-hidden")
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))

        let traceText = try appSmartFillMotionTraceText(
            app: app,
            timeout: smartFillMotionSampleDurationSeconds() + smartFillMotionTraceStartTimeoutSeconds() + 30,
        )
        let rows = motionFrameRows(
            fromTraceText: traceText,
            fallbackManifest: initialManifest
        )
        let productRows = productSceneSequenceRows(
            fromTraceText: traceText,
            fallbackManifest: initialManifest
        )
        let availableRows = rows.filter { row in
            row.fields["progressFrameStatus"] == "available"
        }
        let controlBarVisibleRows = rows.filter { row in
            row.fields["controlBarVisible"] == "true" && row.fields["progressFrameStatus"] == "available"
        }
        let controlBarHiddenRowsAfterAction = rows.filter { row in
            guard let elapsed = Double(row.fields["elapsedSeconds"] ?? ""),
                let hiddenAction = actions.first(where: { $0["action"] as? String == "control-bar-auto-hidden" }),
                let hiddenElapsed = hiddenAction["elapsedSeconds"] as? Double
            else {
                return false
            }
            return elapsed >= hiddenElapsed && row.fields["controlBarVisible"] == "false"
                && row.fields["progressFrameStatus"] == "available"
        }

        writeProductSceneSequenceEvidence(productRows, motionRows: rows, scenario: scenario)
        writeMotionFrameEvidence(rows, scenario: scenario)
        writeInteractionActionEvidence(actions, scenario: scenario)

        XCTAssertFalse(rows.isEmpty, "\(scenario) must capture motion frame probes")
        XCTAssertFalse(
            availableRows.isEmpty, "\(scenario) motion frame probes must include an available progress frame")
        XCTAssertFalse(
            controlBarVisibleRows.isEmpty,
            "\(scenario) available motion rows must continue while the control bar is visible")
        XCTAssertFalse(
            controlBarHiddenRowsAfterAction.isEmpty,
            "\(scenario) available motion rows must continue after the control bar auto-hides")
        XCTAssertTrue(
            actions.map { $0["action"] as? String }.contains("pause")
                && actions.map { $0["action"] as? String }.contains("resume"),
            "\(scenario) must record the pause/resume interaction"
        )
        _ = captureRuntimeScreenshot(
            app: app,
            name: "smartfill-\(scenario)-\(deviceTag())-final",
            attachToXCTest: true
        )
    }

    @MainActor
    func testPlaybackTransitionAnimationEvidenceSmartFillQuickSwitch() throws {
        try runPlaybackTransitionAnimationEvidence(
            disableSmartFill: false,
            scenario: "iphone-smartfill"
        )
    }

    @MainActor
    func testPlaybackTransitionAnimationEvidenceSinglePhotoQuickSwitch() throws {
        try runPlaybackTransitionAnimationEvidence(
            disableSmartFill: true,
            scenario: "iphone-single-photo"
        )
    }

    @MainActor
    func testPlaybackTransitionExifPresenceEvidenceSmartFillEdges() throws {
        let app = try launchConfiguredAppAtModeSelection()
        startRandomPlaybackFromModeSelection(app: app)

        let scenario = "iphone-smartfill-exif-presence"
        var previousManifest = try waitForCurrentManifest(app: app, timeout: 45)
        var previousVisible = exifOverlayVisible(in: previousManifest)
        saveEvidenceScreenshot(
            app: app,
            scenario: scenario,
            step: "00-start-visible-\(previousVisible)"
        )

        var coverage = ExifPresenceEdgeCoverage()
        let maximumAttempts = 60
        let midTransitionDelay: TimeInterval = 0.14
        let settledDelay: TimeInterval = 0.55

        for attempt in 1...maximumAttempts where !coverage.isComplete {
            let previousRefs = previousManifest.slotRefs
            tapNext(app: app)

            var currentManifest = previousManifest
            _ = waitUntil(timeout: 10) {
                guard let nextManifest = self.currentManifest(app: app) else { return false }
                currentManifest = nextManifest
                return nextManifest.slotRefs != previousRefs
            }

            let currentVisible = exifOverlayVisible(in: currentManifest)
            let transitionLabel = "\(previousVisible)-to-\(currentVisible)"
            switch coverage.observeTransition(from: previousVisible, to: currentVisible) {
            case .appear:
                RunLoop.current.run(until: Date().addingTimeInterval(midTransitionDelay))
                saveEvidenceScreenshot(app: app, scenario: scenario, step: "\(attempt)-appear-mid-\(transitionLabel)")
                RunLoop.current.run(until: Date().addingTimeInterval(settledDelay))
                saveEvidenceScreenshot(
                    app: app, scenario: scenario, step: "\(attempt)-appear-settled-\(transitionLabel)")
            case .disappear:
                RunLoop.current.run(until: Date().addingTimeInterval(midTransitionDelay))
                saveEvidenceScreenshot(
                    app: app, scenario: scenario, step: "\(attempt)-disappear-mid-\(transitionLabel)")
                RunLoop.current.run(until: Date().addingTimeInterval(settledDelay))
                saveEvidenceScreenshot(
                    app: app, scenario: scenario, step: "\(attempt)-disappear-settled-\(transitionLabel)")
            case nil:
                break
            }

            previousManifest = currentManifest
            previousVisible = currentVisible
        }

        guard coverage.isComplete else {
            XCTFail(
                """
                SmartFill EXIF overlay presence runtime evidence is incomplete: \(coverage.missingEdgeDescription).
                Sampled \(maximumAttempts) random switches on the real server without observing the target edge; the server needs photos both with and without an EXIF overlay.
                """
            )
            return
        }
        XCTAssertTrue(
            app.buttons["slideshow.control.next.button"].waitForExistence(timeout: 4),
            "Control bar should still work after the EXIF overlay appear/disappear check"
        )
    }

    func testExifPresenceEdgeCoverageRequiresAppearAndDisappear() throws {
        var coverage = ExifPresenceEdgeCoverage()

        XCTAssertEqual(
            coverage.observeTransition(from: false, to: true),
            .appear
        )
        XCTAssertFalse(coverage.isComplete)
        XCTAssertEqual(
            coverage.missingEdgeDescription,
            "Missing smooth EXIF overlay disappearance: single photo with EXIF → multi-photo without EXIF"
        )

        XCTAssertEqual(
            coverage.observeTransition(from: true, to: false),
            .disappear
        )
        XCTAssertTrue(coverage.isComplete)
        XCTAssertEqual(coverage.missingEdgeDescription, "")
    }

    func testExifPresenceEdgeCoverageIgnoresNoChangeTransitions() throws {
        var coverage = ExifPresenceEdgeCoverage()

        XCTAssertNil(coverage.observeTransition(from: false, to: false))
        XCTAssertNil(coverage.observeTransition(from: true, to: true))
        XCTAssertFalse(coverage.isComplete)
        XCTAssertEqual(
            coverage.missingEdgeDescription,
            "Missing smooth EXIF overlay appearance: multi-photo without EXIF → single photo with EXIF; Missing smooth EXIF overlay disappearance: single photo with EXIF → multi-photo without EXIF"
        )
    }

    @MainActor
    func testSmartFillRandomLandscapePlaybackTwentyScenes() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = try launchConfiguredAppAtModeSelection()
        startRandomPlaybackFromModeSelection(app: app)

        let evidence = try collectTwentySceneEvidence(app: app, scenario: "random-landscape")
        assertPolicies(in: evidence, contain: "landscape", scenario: "random playback, landscape")
        assertSurfaces(in: evidence, orientation: .landscape, scenario: "random playback, landscape")
        assertFallbackDistributionMeetsSpec(in: evidence, scenario: "random playback, landscape")
    }

    @MainActor
    func testSmartFillPeopleFilterPlaybackTwentyScenes() async throws {
        let personID = try await findEligiblePersonID(minimumAssetCount: 20)
        let selectionJSON = makePersonFilterSelectionJSON(personID: personID)
        let app = try launchConfiguredAppAtModeSelection(selectionJSON: selectionJSON)
        startFilteredPlaybackFromModeSelection(app: app)

        let evidence = try collectTwentySceneEvidence(app: app, scenario: "people-filter")
        assertPolicies(in: evidence, contain: "portrait", scenario: "people filter, portrait")
        assertSurfaces(in: evidence, orientation: .portrait, scenario: "people filter, portrait")
        assertFallbackDistributionMeetsSpec(in: evidence, scenario: "people filter, portrait")
    }

    @MainActor
    func testSmartFillPeopleFilterLandscapePlaybackTwentyScenes() async throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let personID = try await findEligiblePersonID(minimumAssetCount: 20)
        let selectionJSON = makePersonFilterSelectionJSON(personID: personID)
        let app = try launchConfiguredAppAtModeSelection(selectionJSON: selectionJSON)
        startFilteredPlaybackFromModeSelection(app: app)

        let evidence = try collectTwentySceneEvidence(app: app, scenario: "people-filter-landscape")
        assertPolicies(in: evidence, contain: "landscape", scenario: "people filter, landscape")
        assertSurfaces(in: evidence, orientation: .landscape, scenario: "people filter, landscape")
        assertFallbackDistributionMeetsSpec(in: evidence, scenario: "people filter, landscape")
    }

    @MainActor
    func testSmartFillFixedAlbumPlaybackTwentyScenes() throws {
        let albumID = try requireFixedAlbumID()
        let selectionJSON = makeAlbumFilterSelectionJSON(albumID: albumID)
        let app = try launchConfiguredAppAtModeSelection(selectionJSON: selectionJSON)
        startFilteredPlaybackFromModeSelection(app: app)

        let evidence = try collectTwentySceneEvidence(app: app, scenario: "fixed-album")
        assertPolicies(in: evidence, contain: "portrait", scenario: "fixed album, portrait")
        assertSurfaces(in: evidence, orientation: .portrait, scenario: "fixed album, portrait")
        assertFallbackDistributionMeetsSpec(in: evidence, scenario: "fixed album, portrait")
    }

    @MainActor
    func testSmartFillFixedAlbumLandscapePlaybackTwentyScenes() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let albumID = try requireFixedAlbumID()
        let selectionJSON = makeAlbumFilterSelectionJSON(albumID: albumID)
        let app = try launchConfiguredAppAtModeSelection(selectionJSON: selectionJSON)
        startFilteredPlaybackFromModeSelection(app: app)

        let evidence = try collectTwentySceneEvidence(app: app, scenario: "fixed-album-landscape")
        assertPolicies(in: evidence, contain: "landscape", scenario: "fixed album, landscape")
        assertSurfaces(in: evidence, orientation: .landscape, scenario: "fixed album, landscape")
        assertFallbackDistributionMeetsSpec(in: evidence, scenario: "fixed album, landscape")
    }

    @MainActor
    func testRandomPlaybackSwitchWorkloadTwentyScenesWithSmartFillDisabled() throws {
        let app = try launchConfiguredAppAtModeSelection(disableSmartFill: true)
        startRandomPlaybackFromModeSelection(app: app)

        try exerciseTwentySceneSwitches(app: app, scenario: "cpu-baseline")
    }

    @MainActor
    func testRandomPlaybackSwitchWorkloadTwentyScenesWithSmartFillEnabled() throws {
        let app = try launchConfiguredAppAtModeSelection(disableSmartFill: false)
        startRandomPlaybackFromModeSelection(app: app)

        try exerciseTwentySceneSwitches(app: app, scenario: "cpu-smartfill")
    }

    func testSmartFillRuntimeEvidenceRecordBuilderIncludesRequiredJSONFields() throws {
        let raw = makeStartupRuntimeManifestForTesting()
        let manifest = try XCTUnwrap(parseManifest(raw))
        let sceneIdHash = SmartFillRuntimeEvidenceSupport.sceneIdHash(
            rawManifest: manifest.raw,
            scenario: "unit",
            sequence: 1
        )
        let screenshotPath = "/evidence/seq-1-\(sceneIdHash)-unit.png"
        let record = SmartFillRuntimeEvidenceSupport.makeRecord(
            manifestFields: manifest.rawFields,
            rawManifest: manifest.raw,
            scenario: "unit",
            deviceTag: "iphone",
            sequence: 1,
            sceneIdHash: sceneIdHash,
            screenshotPath: screenshotPath,
            captureTimestamp: "2026-06-08T00:00:00Z"
        )

        for field in SmartFillRuntimeEvidenceSupport.requiredJSONFields {
            XCTAssertNotNil(record[field], "runtime JSONL should include \(field)")
        }
        XCTAssertEqual(record["schemaVersion"] as? String, "pr49-decision-layer-v1")
        XCTAssertEqual(record["sceneIdHash"] as? String, sceneIdHash)
        XCTAssertEqual(record["screenshotPath"] as? String, screenshotPath)
        XCTAssertEqual(record["slotReadiness"] as? [String], ["ready", "pending"])
        XCTAssertEqual(record["preparedHit"] as? Bool, true)
        XCTAssertEqual(record["rejectedLayoutDiagnostics"] as? [String], ["none"])
        XCTAssertEqual(record["protectionOverlapDetails"] as? String, "none")
        XCTAssertEqual(record["firstPhotoCacheStatus"] as? String, "miss")
        XCTAssertEqual(record["firstImageLoadStatus"] as? String, "displayed")
        XCTAssertEqual(record["firstImageDisplayedRuntimeMs"] as? Double, 104)
        XCTAssertEqual(record["visualReviewStatus"] as? String, "VISUAL_REVIEW_REQUIRED")
        XCTAssertEqual(record["multiSlotSuccessCount"] as? Int, 0)
        XCTAssertEqual(record["visualUnverifiedCount"] as? Int, 1)
    }

    func testSmartFillRuntimeEvidenceRecordBuilderCarriesProtectionOverlapDetails() throws {
        let details = [
            "source:upperBodyProxy",
            "region:systemSafeArea",
            "priority:hard",
            "crop:x0.000y0.227w1.000h0.773",
            "mapped:x0.478y0.673w0.110h0.327",
            "hardRejected:false"
        ].joined(separator: "|")
        let raw = makeStartupRuntimeManifestForTesting(overrides: [
            "candidateRejectReasonTopList": "protection-overlap",
            "rejectedLayoutDiagnostics": "reason:protection-overlap|role:primary",
            "protectionOverlapDetails": details
        ])
        let manifest = try XCTUnwrap(parseManifest(raw))
        let sceneIdHash = SmartFillRuntimeEvidenceSupport.sceneIdHash(
            rawManifest: manifest.raw,
            scenario: "unit-protection",
            sequence: 2
        )
        let record = SmartFillRuntimeEvidenceSupport.makeRecord(
            manifestFields: manifest.rawFields,
            rawManifest: manifest.raw,
            scenario: "unit-protection",
            deviceTag: "appletv",
            sequence: 2,
            sceneIdHash: sceneIdHash,
            screenshotPath: "/evidence/seq-2-\(sceneIdHash)-unit-protection.png",
            captureTimestamp: "2026-06-15T00:00:00Z"
        )

        XCTAssertEqual(record["candidateRejectReasonTopList"] as? [String], ["protection-overlap"])
        XCTAssertEqual(record["protectionOverlapDetails"] as? String, details)
    }

    func testSmartFillRuntimeEvidenceRequiresAllVisibleSlotsReadyBeforeScreenshot() throws {
        let pendingManifest = try XCTUnwrap(parseManifest(makeStartupRuntimeManifestForTesting()))
        XCTAssertFalse(
            SmartFillRuntimeEvidenceSupport.isReadyForScreenshotEvidence(manifestFields: pendingManifest.rawFields),
            "Screenshot evidence must not be captured while any visible slot is still pending"
        )

        let readyManifest = try XCTUnwrap(
            parseManifest(
                makeStartupRuntimeManifestForTesting(overrides: [
                    "slotReadiness": "ready,ready",
                    "firstSceneSlotReadiness": "ready,ready",
                    "firstSceneReadySlotCount": "2",
                    "firstScenePendingSlotCount": "0",
                    "runtimePhaseTimestampsMs":
                        "playbackEntryRequested:0,assetPoolRequestStarted:8,assetPoolReady:24,firstScenePlanningStarted:31,firstScenePlanned:45,firstScenePublished:60,firstSlotReady:82,allVisibleSlotsReady:96",
                    "runtimePhaseDurationsMs":
                        "playbackEntryRequested:0,assetPoolRequestStarted:8,assetPoolReady:16,firstScenePlanningStarted:7,firstScenePlanned:14,firstScenePublished:15,firstSlotReady:22,allVisibleSlotsReady:14"
                ])))
        XCTAssertTrue(
            SmartFillRuntimeEvidenceSupport.isReadyForScreenshotEvidence(manifestFields: readyManifest.rawFields),
            "Screenshot evidence may only be written after all visible slots are ready"
        )
    }

    func testSmartFillRuntimeEvidenceRecordBuilderDerivesFallbackRootCauseWhenManifestReportsNone() throws {
        let raw = makeStartupRuntimeManifestForTesting(overrides: [
            "sceneType": "fallback",
            "layoutVariant": "single",
            "ratioPreset": "fallback",
            "fallback": "all-layouts-rejected",
            "fallbackCategory": "layout-reject",
            "acceptedSceneSearchTier": "fallback",
            "currentAssetDisposition": "fallback-current",
            "currentAssetVisibleQualityClass": "fail",
            "fallbackReasonTopList": "all-layouts-rejected",
            "rejectedLayoutReasonTopList": "crop-retention-too-low,candidate-window-exhausted",
            "candidateRejectReasonTopList": "crop-retention-too-low",
            "fallbackRootCauseBucket": "none",
            "slotReadiness": "ready",
            "firstSceneSlotReadiness": "ready"
        ])
        let manifest = try XCTUnwrap(parseManifest(raw))
        let sceneIdHash = SmartFillRuntimeEvidenceSupport.sceneIdHash(
            rawManifest: manifest.raw,
            scenario: "fallback-root-cause",
            sequence: 1
        )
        let record = SmartFillRuntimeEvidenceSupport.makeRecord(
            manifestFields: manifest.rawFields,
            rawManifest: manifest.raw,
            scenario: "fallback-root-cause",
            deviceTag: "iphone",
            sequence: 1,
            sceneIdHash: sceneIdHash,
            screenshotPath: "/evidence/seq-1-\(sceneIdHash)-fallback-root-cause.png",
            captureTimestamp: "2026-06-14T00:00:00Z"
        )

        XCTAssertEqual(record["fallbackRootCauseBucket"] as? String, "candidate-window-exhausted")
    }

    func testSmartFillRuntimeEvidenceRecordBuilderPromotesDecodedStatusAfterScreenshotEvidence() throws {
        let raw = makeStartupRuntimeManifestForTesting(
            overrides: [
                "firstImageDisplayedRuntimeMs": "0",
                "firstImageLoadStatus": "decoded",
                "photoLoadPhaseDurationsMs": "cacheChecked:0,decodeCompleted:30",
                "photoLoadPhaseTimestampsMs": "cacheChecked:70,decodeCompleted:100"
            ]
        )
        let manifest = try XCTUnwrap(parseManifest(raw))
        let sceneIdHash = SmartFillRuntimeEvidenceSupport.sceneIdHash(
            rawManifest: manifest.raw,
            scenario: "decoded-after-screenshot",
            sequence: 1
        )
        let record = SmartFillRuntimeEvidenceSupport.makeRecord(
            manifestFields: manifest.rawFields,
            rawManifest: manifest.raw,
            scenario: "decoded-after-screenshot",
            deviceTag: "iphone",
            sequence: 1,
            sceneIdHash: sceneIdHash,
            screenshotPath: "/evidence/seq-1-\(sceneIdHash)-decoded-after-screenshot.png",
            captureTimestamp: "2026-06-08T00:00:00Z"
        )

        XCTAssertEqual(record["firstImageLoadStatus"] as? String, "displayed")
        XCTAssertEqual(record["visualReviewStatus"] as? String, "VISUAL_REVIEW_REQUIRED")
        XCTAssertEqual(record["multiSlotSuccessCount"] as? Int, 0)
    }

    func testSmartFillRuntimeEvidenceRecordBuilderRejectsUnboundReviewClaim() throws {
        let raw = makeStartupRuntimeManifestForTesting(
            overrides: [
                "sceneType": "single",
                "layoutVariant": "single",
                "ratioPreset": "full",
                "slotCount": "1",
                "slotFrames": "x0.000y0.000w1.000h1.000",
                "slotCropRects": "x0.000y0.065w1.000h0.869",
                "slotRoles": "primary",
                "slotRefs": "asset-hash-a",
                "ledgerSceneAssets": "asset-hash-a",
                "acceptedSceneSearchTier": "single-fill",
                "currentAssetDisposition": "single-slot",
                "currentAssetSlotAreaRatio": "1.000",
                "currentAssetCropRetention": "0.869",
                "currentAssetProtectedRegionCoverage": "1.000",
                "currentAssetFaceProtectionPassed": "true",
                "currentAssetSubjectProtectionPassed": "true",
                "currentAssetVisibleQualityClass": "acceptable",
                "fallback": "none",
                "fallbackCategory": "none"
            ]
        )
        let manifest = try XCTUnwrap(parseManifest(raw))
        let sceneIdHash = SmartFillRuntimeEvidenceSupport.sceneIdHash(
            rawManifest: manifest.raw,
            scenario: "single-fill",
            sequence: 1
        )
        let record = SmartFillRuntimeEvidenceSupport.makeRecord(
            manifestFields: manifest.rawFields,
            rawManifest: manifest.raw,
            scenario: "single-fill",
            deviceTag: "appletv",
            sequence: 1,
            sceneIdHash: sceneIdHash,
            screenshotPath: "/evidence/seq-1-\(sceneIdHash)-single-fill.png",
            captureTimestamp: "2026-06-13T00:00:00Z",
            environment: [
                "IMMICHSLIDES_VISUAL_REVIEW_STATUS": "REVIEWED_PASS"
            ]
        )

        XCTAssertEqual(record["acceptedSceneSearchTier"] as? String, "single-fill")
        XCTAssertEqual(record["smartFillSingleFillCount"] as? Int, 1)
        XCTAssertEqual(record["singleRiskCount"] as? Int, 0)
        XCTAssertEqual(record["multiSlotSuccessCount"] as? Int, 0)
        XCTAssertEqual(record["visualReviewStatus"] as? String, "VISUAL_REVIEW_REQUIRED")
        XCTAssertEqual(record["visualUnverifiedCount"] as? Int, 1)
        XCTAssertEqual(record["nonMultiSlotOutcomeCount"] as? Int, 1)
        XCTAssertEqual(record["userPerceivedFailureCount"] as? Int, 1)
    }

    func testMultiSlotReviewCannotBeApprovedThroughEitherEnvironmentKey() throws {
        let raw = makeStartupRuntimeManifestForTesting(overrides: [
            "sceneType": "multi", "slotCount": "2", "fallback": "none", "fallbackCategory": "none"
        ])
        let manifest = try XCTUnwrap(parseManifest(raw))
        for key in ["IMMICHSLIDES_VISUAL_REVIEW_STATUS", "TEST_RUNNER_IMMICHSLIDES_VISUAL_REVIEW_STATUS"] {
            let record = SmartFillRuntimeEvidenceSupport.makeRecord(
                manifestFields: manifest.rawFields, rawManifest: manifest.raw,
                scenario: "unbound-review", deviceTag: "iphone", sequence: 1,
                sceneIdHash: "unbound-review", screenshotPath: "/evidence/unbound-review.png",
                captureTimestamp: "2026-09-22T00:00:00Z", environment: [key: "REVIEWED_PASS"]
            )
            XCTAssertEqual(record["visualReviewStatus"] as? String, "VISUAL_REVIEW_REQUIRED")
            XCTAssertEqual(record["visualUnverifiedCount"] as? Int, 1)
            XCTAssertEqual(record["multiSlotSuccessCount"] as? Int, 0)
        }
    }

    func testAssetIDReplayCurrentAssetIDComesFromManifestSlotRefs() throws {
        let secondaryRaw = makeStartupRuntimeManifestForTesting(
            overrides: [
                "slotRefs": "asset-primary,asset-secondary",
                "currentAssetDisposition": "secondary-slot"
            ]
        )
        let singleRaw = makeStartupRuntimeManifestForTesting(
            overrides: [
                "slotRefs": "asset-single",
                "currentAssetDisposition": "single-slot"
            ]
        )

        let secondaryManifest = try XCTUnwrap(parseManifest(secondaryRaw))
        let singleManifest = try XCTUnwrap(parseManifest(singleRaw))

        XCTAssertEqual(rawCurrentAssetID(in: secondaryManifest), "asset-secondary")
        XCTAssertEqual(rawCurrentAssetID(in: singleManifest), "asset-single")
    }

    func testAssetIDReplayExpectedRefsUseRuntimeLedgerHash() throws {
        let refs = SmartFillRuntimeEvidenceSupport.assetIDReplayExpectedCurrentRefs(
            environment: [
                "TEST_RUNNER_IMMICHSLIDES_SMARTFILL_REPLAY_ASSET_IDS": "40760bc4-b139-45f7-9d44-dbcfeedae8ec"
            ]
        )

        XCTAssertEqual(refs, ["asset-8e77787aa141150e"])
    }

    func testAssetIDReplayStrictExpectedCurrentRefsParseObservedLock() throws {
        let refs = SmartFillRuntimeEvidenceSupport.strictExpectedCurrentAssetRefs(
            environment: [
                "TEST_RUNNER_IMMICHSLIDES_SMARTFILL_EXPECTED_CURRENT_ASSET_REFS":
                    "orderedCurrentAssetRefs=asset-first,asset-third"
            ]
        )

        XCTAssertEqual(refs, ["asset-first", "asset-third"])
    }

    func testAssetIDReplayRuntimeCurrentAssetRefMatchesRecordBuilderRedaction() throws {
        let ref = SmartFillRuntimeEvidenceSupport.runtimeCurrentAssetRef(forSlotRef: "asset-8e77787aa141150e")

        XCTAssertEqual(ref, "assetRef-706a83fd609f")
    }

    func testAssetIDReplayMonotonicValidationStopsAtFirstWrapWithoutFailure() throws {
        let accepted = SmartFillRuntimeEvidenceSupport.evaluateAssetIDReplayMonotonicProgress(
            sequence: 1,
            observedReplayIndex: 0,
            previousReplayAssetIndex: nil
        )
        let wrapped = SmartFillRuntimeEvidenceSupport.evaluateAssetIDReplayMonotonicProgress(
            sequence: 47,
            observedReplayIndex: 0,
            previousReplayAssetIndex: 78
        )

        XCTAssertEqual(accepted.status, "match")
        XCTAssertTrue(accepted.shouldIncludeManifest)
        XCTAssertFalse(accepted.shouldStopSampling)
        XCTAssertEqual(accepted.nextPreviousReplayAssetIndex, 0)
        XCTAssertNil(accepted.failureMessage)
        XCTAssertEqual(wrapped.status, "truncated-at-replay-boundary")
        XCTAssertFalse(wrapped.shouldIncludeManifest)
        XCTAssertTrue(wrapped.shouldStopSampling)
        XCTAssertEqual(wrapped.nextPreviousReplayAssetIndex, 78)
        XCTAssertNil(wrapped.failureMessage)
    }

    func testSmartFillRuntimeEvidenceScenarioManifestObservationBindsCurrentAssetRefs() throws {
        let raw = makeStartupRuntimeManifestForTesting()
        let manifest = try XCTUnwrap(parseManifest(raw))
        let firstSceneHash = SmartFillRuntimeEvidenceSupport.sceneIdHash(
            rawManifest: manifest.raw,
            scenario: "lock-observation",
            sequence: 1
        )
        let first = SmartFillRuntimeEvidenceSupport.makeRecord(
            manifestFields: manifest.rawFields,
            rawManifest: manifest.raw,
            scenario: "lock-observation",
            deviceTag: "iphone",
            sequence: 1,
            sceneIdHash: firstSceneHash,
            screenshotPath: "/evidence/seq-1-\(firstSceneHash)-lock-observation.png",
            captureTimestamp: "2026-06-13T00:00:00Z"
        )
        var second = first
        second["sequence"] = 2
        second["sceneIdHash"] = "scene-lock-002"
        second["currentAssetRef"] = "assetRef-second"

        let lock = try XCTUnwrap(
            SmartFillRuntimeEvidenceSupport.scenarioManifestObservationLockText(
                records: [first, second],
                scenario: "lock-observation",
                deviceTag: "iphone"
            ))

        XCTAssertTrue(lock.contains("lockStatus=RUNTIME_OBSERVED_CURRENT_ASSET_REFS_LOCK"))
        XCTAssertTrue(
            lock.contains("orderedCurrentAssetRefs=\(first["currentAssetRef"] as? String ?? ""),assetRef-second"))
        XCTAssertFalse(lock.contains("TO_BE_RUNTIME_CAPTURED"))
    }

    func testSmartFillRuntimeEvidenceBuilderSeparatesRuntimeJSONLFromHarnessSummary() throws {
        let raw = makeStartupRuntimeManifestForTesting()
        let manifest = try XCTUnwrap(parseManifest(raw))
        let sceneIdHash = SmartFillRuntimeEvidenceSupport.sceneIdHash(
            rawManifest: manifest.raw,
            scenario: "clock-domain",
            sequence: 1
        )
        let record = SmartFillRuntimeEvidenceSupport.makeRecord(
            manifestFields: manifest.rawFields,
            rawManifest: manifest.raw,
            scenario: "clock-domain",
            deviceTag: "iphone",
            sequence: 1,
            sceneIdHash: sceneIdHash,
            screenshotPath: "/evidence/seq-1-\(sceneIdHash)-clock-domain.png",
            captureTimestamp: "2026-06-08T00:00:00Z"
        )

        for field in SmartFillRuntimeEvidenceSupport.harnessOnlyJSONFields {
            XCTAssertNil(record[field], "runtime JSONL must not include harness-only field \(field)")
        }
        XCTAssertEqual(record["startupClockSource"] as? String, "app-runtime")

        let harnessSummary = SmartFillRuntimeEvidenceSupport.makeHarnessSummary(
            startupRunId: try XCTUnwrap(record["startupRunId"] as? String),
            appLaunchStartMs: 0,
            testServerConfigInjectedMs: 14,
            firstManifestObservedMs: 238,
            firstNonLoadingScreenshotCapturedMs: 412
        )

        for field in SmartFillRuntimeEvidenceSupport.requiredHarnessSummaryFields {
            XCTAssertNotNil(harnessSummary[field], "harness summary should include \(field)")
        }
        XCTAssertEqual(harnessSummary["startupClockSource"] as? String, "xctest-harness")
        XCTAssertNil(
            harnessSummary["runtimePhaseTimestampsMs"], "harness summary must not include runtime phase timestamps")
        XCTAssertNil(
            harnessSummary["firstSlotReadyRuntimeMs"], "harness summary must not include App runtime readiness")
    }

    func testSmartFillRuntimeEvidenceRecordBuilderRequiresCompleteStartupPhaseKeys() throws {
        let raw = makeStartupRuntimeManifestForTesting()
        let manifest = try XCTUnwrap(parseManifest(raw))
        let record = SmartFillRuntimeEvidenceSupport.makeRecord(
            manifestFields: manifest.rawFields,
            rawManifest: manifest.raw,
            scenario: "phase-complete",
            deviceTag: "iphone",
            sequence: 1,
            sceneIdHash: SmartFillRuntimeEvidenceSupport.sceneIdHash(
                rawManifest: manifest.raw,
                scenario: "phase-complete",
                sequence: 1
            ),
            screenshotPath: "/evidence/seq-1-phase-complete.png",
            captureTimestamp: "2026-06-08T00:00:00Z"
        )

        let timestamps = try XCTUnwrap(record["runtimePhaseTimestampsMs"] as? [String: Double])
        let durations = try XCTUnwrap(record["runtimePhaseDurationsMs"] as? [String: Double])
        for phase in SmartFillRuntimeEvidenceSupport.requiredRuntimePhaseKeys {
            XCTAssertNotNil(timestamps[phase], "runtimePhaseTimestampsMs must include \(phase)")
            XCTAssertNotNil(durations[phase], "runtimePhaseDurationsMs must include \(phase)")
        }
        let photoLoadTimestamps = try XCTUnwrap(record["photoLoadPhaseTimestampsMs"] as? [String: Double])
        let photoLoadDurations = try XCTUnwrap(record["photoLoadPhaseDurationsMs"] as? [String: Double])
        for phase in [
            "cacheChecked", "downloadRequestStarted", "downloadCompleted", "decodeCompleted", "firstImageDisplayed"
        ] {
            XCTAssertNotNil(photoLoadTimestamps[phase], "photoLoadPhaseTimestampsMs must include \(phase)")
            XCTAssertNotNil(photoLoadDurations[phase], "photoLoadPhaseDurationsMs must include \(phase)")
        }
        XCTAssertEqual(record["startupMissingPhases"] as? [String], [])

        let incompleteRaw = makeStartupRuntimeManifestForTesting(
            overrides: [
                "runtimePhaseTimestampsMs": "playbackEntryRequested:0,assetPoolRequestStarted:8,assetPoolReady:24"
            ]
        )
        let incompleteManifest = try XCTUnwrap(parseManifest(incompleteRaw))
        let incompleteRecord = SmartFillRuntimeEvidenceSupport.makeRecord(
            manifestFields: incompleteManifest.rawFields,
            rawManifest: incompleteManifest.raw,
            scenario: "phase-incomplete",
            deviceTag: "iphone",
            sequence: 1,
            sceneIdHash: SmartFillRuntimeEvidenceSupport.sceneIdHash(
                rawManifest: incompleteManifest.raw,
                scenario: "phase-incomplete",
                sequence: 1
            ),
            screenshotPath: "/evidence/seq-1-phase-incomplete.png",
            captureTimestamp: "2026-06-08T00:00:00Z"
        )
        XCTAssertTrue(
            ((incompleteRecord["startupMissingPhases"] as? [String]) ?? []).contains("firstScenePublished"),
            "builder must expose missing required startup phases instead of only checking that the map field exists"
        )
    }

    func testSmartFillRuntimeEvidenceRecordBuilderRedactsLedgerCandidatesAndReasonLists() throws {
        let raw = makeStartupRuntimeManifestForTesting(
            overrides: [
                "ledgerSceneAssets":
                    "assetId:raw-asset-123,https://immich.example/api/assets/raw-asset-456?api_key=secret",
                "fallbackReasonTopList": "personId:raw-person-123,bearer token",
                "rejectedLayoutReasonTopList": "assetId:raw-asset-000,crop-retention-reject",
                "rejectedLayoutDiagnostics":
                    "reason:crop-retention-too-low|assetId:raw-asset-000|serverURL:https://immich.example",
                "candidateRejectReasonTopList": "serverURL:https://immich.example,candidate:raw-asset-789"
            ]
        )
        let manifest = try XCTUnwrap(parseManifest(raw))
        let sceneIdHash = SmartFillRuntimeEvidenceSupport.sceneIdHash(
            rawManifest: manifest.raw,
            scenario: "redaction",
            sequence: 1
        )
        let record = SmartFillRuntimeEvidenceSupport.makeRecord(
            manifestFields: manifest.rawFields,
            rawManifest: manifest.raw,
            scenario: "redaction",
            deviceTag: "iphone",
            sequence: 1,
            sceneIdHash: sceneIdHash,
            screenshotPath: "/evidence/seq-1-\(sceneIdHash)-redaction.png",
            captureTimestamp: "2026-06-08T00:00:00Z"
        )
        let jsonLine = try SmartFillRuntimeEvidenceSupport.jsonLine(from: record).lowercased()

        for forbidden in [
            "raw-asset", "raw-person", "https://", "api_key", "bearer", "serverurl", "personid", "assetid"
        ] {
            XCTAssertFalse(jsonLine.contains(forbidden), "runtime JSONL leaked forbidden raw token \(forbidden)")
        }
        XCTAssertTrue(
            ((record["ledgerSceneAssets"] as? [String]) ?? []).allSatisfy { $0.hasPrefix("assetRef-") },
            "ledgerSceneAssets must be emitted as surrogate ids only"
        )
    }
}

private extension PlaybackSmartFillVisualUITests {
    struct SmartFillEvidence {
        let manifests: [SmartFillManifest]

        var fallbackDistribution: [String: Int] {
            SmartFillFallbackEvidencePolicy.distribution(from: manifests.map(\.fallbackCategory))
        }

        var forbiddenFallbackDistribution: [String: Int] {
            SmartFillFallbackEvidencePolicy.forbiddenDistribution(from: fallbackDistribution)
        }
    }

    struct SmartFillManifest: Equatable {
        let raw: String
        let rawFields: [String: String]
        let sceneType: String
        let policy: String
        let slotCount: Int
        let fallback: String
        let fallbackCategory: String
        let slotRefs: String
        let rejects: String
        let surfaceKey: String
        let surfaceProfile: String
        let surfaceOrientation: String
        let slotFrames: String
        let layoutVariant: String
        let ratioPreset: String
        let cropRetention: String
        let protectionContained: String
        let candidateWindowUsed: Int
        let evaluationCount: Int
        let rotationStartLayoutVariant: String
        let rotationStartRatioPreset: String
        let acceptedLayoutVariant: String
        let acceptedRatioPreset: String
        let rotationKeyHashPrefix: String
        let rejectedLayoutReasonTopList: String
    }

    enum SmartFillSurfaceExpectation {
        case portrait
        case landscape
    }

    enum SmartFillIOSFailure: Error {
        case missingManifest
        case missingCurrentAssetProbe
        case motionTraceFinishedBeforeInteraction
    }

    struct MotionFrameEvidenceRow {
        let sampleIndex: Int
        let elapsedSeconds: Double
        let probeIdentifier: String
        let fields: [String: String]
        let manifestSlotRefs: String
        let manifestSceneType: String
    }

    struct ProductSceneSequenceRow {
        let sampleIndex: Int
        let elapsedSeconds: Double
        let manifestSlotRefs: String
        let manifestSceneType: String
        let productTransitionFields: [String: String]
    }

    enum ExifPresenceTransitionEdge: Equatable {
        case appear
        case disappear
    }

    struct ExifPresenceEdgeCoverage {
        private(set) var sawAppear = false
        private(set) var sawDisappear = false

        var isComplete: Bool {
            sawAppear && sawDisappear
        }

        var missingEdgeDescription: String {
            var messages: [String] = []
            if !sawAppear {
                messages.append(
                    "Missing smooth EXIF overlay appearance: multi-photo without EXIF → single photo with EXIF")
            }
            if !sawDisappear {
                messages.append(
                    "Missing smooth EXIF overlay disappearance: single photo with EXIF → multi-photo without EXIF")
            }
            return messages.joined(separator: "; ")
        }

        mutating func observeTransition(from previousVisible: Bool, to currentVisible: Bool)
            -> ExifPresenceTransitionEdge?
        {
            switch (previousVisible, currentVisible) {
            case (false, true):
                sawAppear = true
                return .appear
            case (true, false):
                sawDisappear = true
                return .disappear
            default:
                return nil
            }
        }
    }

    func launchConfiguredAppAtModeSelection(
        selectionJSON: String? = nil,
        disableSmartFill: Bool = false,
        forceAutoplayOff: Bool = true,
        enableSmartFillMotionTrace: Bool = false,
        resetState: Bool = true
    ) throws -> XCUIApplication {
        let config = try requireTestServerConfig()
        let app = XCUIApplication()
        if resetState {
            app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        }
        app.launchEnvironment["XCTestConfigurationFilePath"] =
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] ?? "SmartFillMotionEvidenceUITest"
        app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        if forceAutoplayOff {
            app.launchEnvironment["UI_TEST_FORCE_AUTOPLAY_OFF"] = "1"
        }
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        app.launchEnvironment["UI_TEST_SERVER_URL"] = config.url
        app.launchEnvironment["UI_TEST_API_KEY"] = config.apiKey
        SmartFillRuntimeEvidenceSupport.copyAssetIDReplayEnvironment(to: app)
        if enableSmartFillMotionTrace {
            let environment = ProcessInfo.processInfo.environment
            app.launchEnvironment["UI_TEST_COLLECT_SMARTFILL_MOTION_TRACE"] = "1"
            app.launchEnvironment["UI_TEST_SMARTFILL_MOTION_TRACE_DURATION_SECONDS"] =
                environment["TEST_RUNNER_SMARTFILL_MOTION_SAMPLE_SECONDS"] ?? environment[
                    "SMARTFILL_MOTION_SAMPLE_SECONDS"] ?? "36"
            app.launchEnvironment["UI_TEST_SMARTFILL_MOTION_TRACE_SAMPLE_INTERVAL_SECONDS"] =
                environment["TEST_RUNNER_SMARTFILL_MOTION_SAMPLE_INTERVAL_SECONDS"] ?? environment[
                    "SMARTFILL_MOTION_SAMPLE_INTERVAL_SECONDS"] ?? "0.005"
            app.launchEnvironment["UI_TEST_SMARTFILL_MOTION_TRACE_START_TIMEOUT_SECONDS"] =
                environment["TEST_RUNNER_SMARTFILL_MOTION_TRACE_START_TIMEOUT_SECONDS"] ?? environment[
                    "SMARTFILL_MOTION_TRACE_START_TIMEOUT_SECONDS"] ?? "60"
        }
        if disableSmartFill {
            app.launchEnvironment["IMMICHSLIDES_DISABLE_SMART_FILL"] = "1"
        }
        if let selectionJSON {
            app.launchEnvironment["UI_TEST_SEED_FILTER_SELECTION"] = "1"
            app.launchEnvironment["UI_TEST_FILTER_SELECTION_JSON"] = selectionJSON
        }
        let requestedOrientation = XCUIDevice.shared.orientation
        app.launch()
        if requestedOrientation.isLandscape {
            XCUIDevice.shared.orientation = requestedOrientation
            _ = waitUntil(timeout: 8) { app.frame.width > app.frame.height }
        }

        XCTAssertTrue(
            app.buttons["mode.continue.button"].waitForExistence(timeout: 12),
            "After injecting the test server, the app should go straight to mode selection"
        )
        return app
    }

    func launchSmartFillMotionEvidenceAppAtModeSelection(
        scenario: String,
        forceAutoplayOff: Bool,
        enableSmartFillMotionTrace: Bool
    ) throws -> XCUIApplication {
        let configuredInterval = smartFillMotionConfiguredIntervalSeconds()
        if abs(configuredInterval - 5.0) > 0.000_1 {
            XCTAssertTrue(
                smartFillMotionIntervalIsPreseeded(),
                "\(scenario) non-5-second motion evidence must preseed PlaybackSettings.intervalSeconds (\(configuredInterval) s) in the app's saved settings and set SMARTFILL_MOTION_INTERVAL_PRESEEDED=1; the flag is trusted, not verified, so confirm the value in Settings before using the cadence evidence"
            )
            return try launchConfiguredAppAtModeSelection(
                forceAutoplayOff: forceAutoplayOff,
                enableSmartFillMotionTrace: enableSmartFillMotionTrace,
                resetState: false
            )
        }

        return try launchConfiguredAppAtModeSelection(
            forceAutoplayOff: forceAutoplayOff,
            enableSmartFillMotionTrace: enableSmartFillMotionTrace
        )
    }

    func startRandomPlaybackFromModeSelection(app: XCUIApplication) {
        tapElement(app.buttons["mode.random.button"])
        tapElement(app.buttons["mode.continue.button"])
        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(timeout: 30),
            "After starting random playback, the playback control bar should appear"
        )
    }

    func runPlaybackTransitionAnimationEvidence(disableSmartFill: Bool, scenario: String) throws {
        let app = try launchConfiguredAppAtModeSelection(disableSmartFill: disableSmartFill)
        startRandomPlaybackFromModeSelection(app: app)
        saveEvidenceScreenshot(app: app, scenario: scenario, step: "00-before")

        for index in 1...3 {
            tapNext(app: app)
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            saveEvidenceScreenshot(app: app, scenario: scenario, step: "\(index)-mid")
            RunLoop.current.run(until: Date().addingTimeInterval(0.65))
            saveEvidenceScreenshot(app: app, scenario: scenario, step: "\(index)-settled")
        }

        XCTAssertTrue(
            app.buttons["slideshow.control.next.button"].waitForExistence(timeout: 4),
            "\(scenario) control bar should still work after quick switching"
        )
    }

    func exifOverlayVisible(in manifest: SmartFillManifest) -> Bool {
        manifest.rawFields["exifOverlayVisible"] == "true"
    }

    func startFilteredPlaybackFromModeSelection(app: XCUIApplication) {
        tapElement(app.buttons["mode.filtered.button"])
        tapElement(app.buttons["mode.continue.button"])

        let startButton = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 20), "Filter summary should show the Start playback button")
        XCTAssertTrue(
            waitUntil(timeout: 20) { startButton.isEnabled },
            "After seeding the people filter, Start playback should be tappable")
        tapElement(startButton)

        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(timeout: 45),
            "After starting people-filter playback, the playback control bar should appear"
        )
    }

    func collectTwentySceneEvidence(app: XCUIApplication, scenario: String) throws -> SmartFillEvidence {
        var manifests: [SmartFillManifest] = []
        var runtimeRecords: [[String: Any]] = []
        var attachedSceneTypes = Set<String>()
        var attachedScreenshotCount = 0
        let harnessStartMs = SmartFillRuntimeEvidenceSupport.harnessTimestampMilliseconds()
        var firstManifestObservedMs: Double?
        var firstNonLoadingScreenshotCapturedMs: Double?
        let targetSceneCount = smartFillTargetSceneCount()
        let samplingScreenshotIndices = screenshotSampleIndices(for: targetSceneCount)
        let replayCurrentAssetRefs = SmartFillRuntimeEvidenceSupport.assetIDReplayExpectedCurrentRefs()
        let strictExpectedCurrentAssetRefs = SmartFillRuntimeEvidenceSupport.strictExpectedCurrentAssetRefs()
        let replayCurrentAssetRefIndex = firstIndexMap(for: replayCurrentAssetRefs ?? [])
        var previousReplayAssetIndex: Int?
        var replayValidationRows: [SmartFillRuntimeEvidenceSupport.AssetIDReplayValidationRow] = []
        var stoppedAtReplayBoundary = false

        for index in 0..<targetSceneCount {
            var manifest = try waitForCurrentManifest(app: app, timeout: index == 0 ? 45 : 25)
            if index == 0,
                shouldWaitForCompleteStartupRuntimePhases()
            {
                manifest = try waitForCompleteStartupRuntimeManifest(
                    app: app,
                    initialManifest: manifest,
                    timeout: 30
                )
            }
            manifest = try waitForScreenshotReadyManifest(
                app: app,
                initialManifest: manifest,
                timeout: 30,
                scenario: scenario,
                index: index
            )
            if firstManifestObservedMs == nil {
                firstManifestObservedMs =
                    SmartFillRuntimeEvidenceSupport.harnessTimestampMilliseconds() - harnessStartMs
            }
            assertManifestIsRedacted(manifest.raw)
            assertManifestMeetsSpecGates(manifest, scenario: scenario, index: index)

            let sequence = index + 1
            if replayCurrentAssetRefs != nil {
                let observedSlotRef = rawCurrentAssetID(in: manifest)
                let observedCurrentAssetRef = observedSlotRef.map {
                    SmartFillRuntimeEvidenceSupport.runtimeCurrentAssetRef(forSlotRef: $0)
                }
                let observedReplayIndex = observedSlotRef.flatMap { replayCurrentAssetRefIndex[$0] }
                if let strictExpectedCurrentAssetRefs {
                    let expectedAssetRef = try XCTUnwrap(
                        strictExpectedCurrentAssetRefs.indices.contains(index)
                            ? strictExpectedCurrentAssetRefs[index] : nil,
                        "expected currentAssetRef lock has fewer than \(targetSceneCount) entries; entry \(sequence) is missing"
                    )
                    let status = observedCurrentAssetRef == expectedAssetRef ? "match" : "mismatch"
                    replayValidationRows.append(
                        SmartFillRuntimeEvidenceSupport.AssetIDReplayValidationRow(
                            sequence: sequence,
                            rule: "strict-current-ref",
                            expected: expectedAssetRef,
                            observedSlotRef: observedSlotRef,
                            observedCurrentAssetRef: observedCurrentAssetRef,
                            observedReplayIndex: observedReplayIndex.map { $0 + 1 },
                            status: status
                        )
                    )
                    XCTAssertEqual(
                        observedCurrentAssetRef,
                        expectedAssetRef,
                        "\(scenario) scene \(sequence) must play per the expected currentAssetRef lock"
                    )
                } else {
                    let progress = SmartFillRuntimeEvidenceSupport.evaluateAssetIDReplayMonotonicProgress(
                        sequence: sequence,
                        observedReplayIndex: observedReplayIndex,
                        previousReplayAssetIndex: previousReplayAssetIndex
                    )
                    replayValidationRows.append(
                        SmartFillRuntimeEvidenceSupport.AssetIDReplayValidationRow(
                            sequence: sequence,
                            rule: "replay-pool-monotonic",
                            expected: progress.expected,
                            observedSlotRef: observedSlotRef,
                            observedCurrentAssetRef: observedCurrentAssetRef,
                            observedReplayIndex: observedReplayIndex.map { $0 + 1 },
                            status: progress.status
                        )
                    )
                    if let failureMessage = progress.failureMessage {
                        XCTFail("\(scenario) \(failureMessage)")
                        break
                    }
                    if progress.shouldStopSampling {
                        stoppedAtReplayBoundary = true
                        break
                    }
                    guard progress.shouldIncludeManifest else { break }
                    previousReplayAssetIndex = progress.nextPreviousReplayAssetIndex
                }
            }
            manifests.append(manifest)
            let sceneIdHash = SmartFillRuntimeEvidenceSupport.sceneIdHash(
                rawManifest: manifest.raw,
                scenario: scenario,
                sequence: sequence
            )
            let shouldAttach =
                index == 0 || index == targetSceneCount - 1 || attachedSceneTypes.insert(manifest.sceneType).inserted
                || samplingScreenshotIndices.contains(index)
            if let screenshot = captureRuntimeScreenshot(
                app: app,
                name: "smartfill-\(scenario)-\(deviceTag())-seq-\(sequence)-\(sceneIdHash)-\(manifest.sceneType)",
                attachToXCTest: shouldAttach
            ) {
                if firstNonLoadingScreenshotCapturedMs == nil {
                    firstNonLoadingScreenshotCapturedMs =
                        SmartFillRuntimeEvidenceSupport.harnessTimestampMilliseconds() - harnessStartMs
                }
                runtimeRecords.append(
                    SmartFillRuntimeEvidenceSupport.makeRecord(
                        manifestFields: manifest.rawFields,
                        rawManifest: manifest.raw,
                        scenario: scenario,
                        deviceTag: deviceTag(),
                        sequence: sequence,
                        sceneIdHash: sceneIdHash,
                        screenshotPath: screenshot.path,
                        captureTimestamp: screenshot.captureTimestamp
                    )
                )
            }
            if shouldAttach {
                attachedScreenshotCount += 1
            }

            guard index < targetSceneCount - 1 else { continue }
            let previousRefs = manifest.slotRefs
            tapNext(app: app)
            _ = waitUntil(timeout: 25) {
                guard let nextManifest = self.currentManifest(app: app) else { return false }
                return nextManifest.slotRefs != previousRefs
            }
        }

        attachManifestSummary(manifests, scenario: scenario)
        let harnessSummary = makeHarnessSummary(
            runtimeRecords: runtimeRecords,
            firstManifestObservedMs: firstManifestObservedMs,
            firstNonLoadingScreenshotCapturedMs: firstNonLoadingScreenshotCapturedMs
        )
        writeManifestEvidence(
            manifests,
            runtimeRecords: runtimeRecords,
            harnessSummary: harnessSummary,
            scenario: scenario
        )
        writeAssetIDReplayEvidence(replayValidationRows, scenario: scenario)
        if stoppedAtReplayBoundary {
            XCTAssertLessThan(
                manifests.count, targetSceneCount, "\(scenario) should stop cleanly before the replay wraps around")
        } else {
            XCTAssertEqual(
                manifests.count, targetSceneCount,
                "\(scenario) should capture the target number of Smart Fill manifests")
        }
        if targetSceneCount >= 60 {
            XCTAssertGreaterThanOrEqual(
                attachedScreenshotCount, 10, "\(scenario) a 60-scene sample should keep at least 10 screenshots")
        }
        if targetSceneCount > 1 {
            XCTAssertGreaterThan(
                Set(manifests.map(\.slotRefs)).count,
                1,
                "\(scenario) consecutive samples should show at least one change in redacted slot references"
            )
        }
        return SmartFillEvidence(manifests: manifests)
    }

    func writeAssetIDReplayEvidence(
        _ rows: [SmartFillRuntimeEvidenceSupport.AssetIDReplayValidationRow],
        scenario: String
    ) {
        guard !rows.isEmpty, let directory = evidenceDirectory() else { return }
        let fileURL = directory.appendingPathComponent(
            sanitizedEvidenceFileName("smartfill-\(scenario)-\(deviceTag())-asset-id-replay-validation") + ".tsv"
        )
        try? SmartFillRuntimeEvidenceSupport.assetIDReplayValidationText(rows: rows)
            .write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func exerciseTwentySceneSwitches(app: XCUIApplication, scenario: String) throws {
        _ = try waitForCurrentAssetReference(app: app, timeout: 45)
        var switchedCount = 1

        for _ in 0..<19 {
            let previousReference = try waitForCurrentAssetReference(app: app, timeout: 20)
            tapNext(app: app)
            XCTAssertTrue(
                waitUntil(timeout: 25) {
                    guard let nextReference = self.currentAssetReference(app: app) else { return false }
                    return nextReference != previousReference
                },
                "\(scenario) tapping Next should switch to a new playback asset"
            )
            switchedCount += 1
        }

        let attachment = XCTAttachment(string: "scenario=\(scenario);sceneCount=\(switchedCount)")
        attachment.name = "smartfill-\(scenario)-performance-probe-\(deviceTag())"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(switchedCount, 20, "\(scenario) should complete 20 playback switches")
    }

    func tapNext(app: XCUIApplication) {
        let nextButton = app.buttons["slideshow.control.next.button"]
        if nextButton.waitForExistence(timeout: 3) {
            tapElement(nextButton)
            return
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(
            nextButton.waitForExistence(timeout: 5), "Next button should be found after waking the control bar")
        tapElement(nextButton)
    }

    func waitForCurrentManifest(app: XCUIApplication, timeout: TimeInterval) throws -> SmartFillManifest {
        guard waitUntil(timeout: timeout, condition: { self.currentManifest(app: app) != nil }) else {
            attachScreenshot(app: app, name: "smartfill-manifest-missing-\(deviceTag())")
            throw SmartFillIOSFailure.missingManifest
        }
        guard let manifest = currentManifest(app: app) else {
            throw SmartFillIOSFailure.missingManifest
        }
        return manifest
    }

    func appSmartFillMotionTraceText(
        app: XCUIApplication,
        timeout: TimeInterval
    ) throws -> String {
        let statusProbe = app.otherElements["slideshow.smartfill.motionFrame.trace.status"]
        let quietWait = min(timeout, smartFillMotionSampleDurationSeconds() + 5)
        RunLoop.current.run(until: Date().addingTimeInterval(quietWait))
        let isCompleteAfterQuietWait = statusProbe.exists && statusProbe.label.contains("status=complete")
        let remainingTimeout = max(0, timeout - quietWait)
        let completed =
            isCompleteAfterQuietWait
            || waitUntil(timeout: remainingTimeout) {
                statusProbe.exists && statusProbe.label.contains("status=complete")
            }
        XCTAssertTrue(
            completed, "in-app motion trace must complete, status=\(statusProbe.exists ? statusProbe.label : "missing")"
        )
        guard completed else { return "" }

        let statusFields = parseSemicolonFields(statusProbe.label)
        if let tracePath = statusFields["tracePath"],
            !tracePath.isEmpty,
            tracePath != "missing",
            tracePath != "write-failed",
            let traceText = try? String(contentsOfFile: tracePath, encoding: .utf8)
        {
            return traceText
        }

        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "slideshow.smartfill.motionFrame.trace.chunk.")
        let chunks = app.descendants(matching: .any)
            .matching(predicate)
            .allElementsBoundByIndex
            .sorted { lhs, rhs in
                traceChunkIndex(lhs.identifier) < traceChunkIndex(rhs.identifier)
            }
        return chunks.map(\.label).joined(separator: "\n")
    }

    func waitForSmartFillMotionTraceCollecting(
        app: XCUIApplication,
        timeout: TimeInterval
    ) throws -> TimeInterval {
        let statusProbe = app.otherElements["slideshow.smartfill.motionFrame.trace.status"]
        let completed = waitUntil(timeout: timeout) {
            guard statusProbe.exists else { return false }
            let statusFields = parseSemicolonFields(statusProbe.label)
            guard statusProbe.label.contains("status=collecting") || statusProbe.label.contains("status=complete")
            else {
                return false
            }
            return Double(statusFields["collectionStartedUptimeSeconds"] ?? "0") ?? 0 > 0
        }
        XCTAssertTrue(
            completed,
            "in-app motion trace must start collecting, status=\(statusProbe.exists ? statusProbe.label : "missing")")
        if statusProbe.exists, statusProbe.label.contains("status=complete") {
            XCTFail(
                "motion trace finished before the interaction; increase the motion trace capture budget or start the interaction sooner"
            )
            throw SmartFillIOSFailure.motionTraceFinishedBeforeInteraction
        }
        let statusFields = statusProbe.exists ? parseSemicolonFields(statusProbe.label) : [:]
        let startedAt = Double(statusFields["collectionStartedUptimeSeconds"] ?? "0") ?? 0
        XCTAssertGreaterThan(
            startedAt, 0,
            "motion trace status must expose collectionStartedUptimeSeconds as the time anchor for interaction evidence"
        )
        return startedAt
    }

    func traceChunkIndex(_ identifier: String) -> Int {
        Int(identifier.split(separator: ".").last ?? "") ?? 0
    }

    func motionFrameRows(
        fromTraceText traceText: String,
        fallbackManifest: SmartFillManifest
    ) -> [MotionFrameEvidenceRow] {
        traceText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { rawLine -> MotionFrameEvidenceRow? in
                let fields = parseSemicolonFields(String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines))
                guard fields["eventType"] == "motionFrame" else { return nil }
                guard let rawSampleIndex = fields["sampleIndex"],
                    let sampleIndex = Int(rawSampleIndex),
                    let rawElapsed = fields["elapsedSeconds"],
                    let elapsedSeconds = Double(rawElapsed)
                else {
                    return nil
                }
                let identifier = [
                    "slideshow.smartfill.motionFrame.trace",
                    fields["renderRole"] ?? "unknown",
                    fields["slotId"] ?? "unknown"
                ].joined(separator: ".")
                return MotionFrameEvidenceRow(
                    sampleIndex: sampleIndex,
                    elapsedSeconds: elapsedSeconds,
                    probeIdentifier: identifier,
                    fields: fields,
                    manifestSlotRefs: (fields["manifestSlotRefs"] ?? fallbackManifest.slotRefs)
                        .replacingOccurrences(of: "|", with: ","),
                    manifestSceneType: fields["manifestSceneType"] ?? fallbackManifest.sceneType
                )
            }
    }

    func productSceneSequenceRows(
        fromTraceText traceText: String,
        fallbackManifest: SmartFillManifest
    ) -> [ProductSceneSequenceRow] {
        traceText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { rawLine -> ProductSceneSequenceRow? in
                let fields = parseSemicolonFields(String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines))
                guard fields["eventType"] == "productSceneSequence" else { return nil }
                guard let rawSampleIndex = fields["sampleIndex"],
                    let sampleIndex = Int(rawSampleIndex),
                    let rawElapsed = fields["elapsedSeconds"],
                    let elapsedSeconds = Double(rawElapsed)
                else {
                    return nil
                }
                return ProductSceneSequenceRow(
                    sampleIndex: sampleIndex,
                    elapsedSeconds: elapsedSeconds,
                    manifestSlotRefs: (fields["slotRefs"] ?? fallbackManifest.slotRefs)
                        .replacingOccurrences(of: "|", with: ","),
                    manifestSceneType: fields["sceneType"] ?? fallbackManifest.sceneType,
                    productTransitionFields: fields
                )
            }
    }

    func parseSemicolonFields(_ raw: String) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: raw.split(separator: ";").compactMap { part -> (String, String)? in
                guard let equalIndex = part.firstIndex(of: "=") else { return nil }
                return (
                    String(part[..<equalIndex]),
                    String(part[part.index(after: equalIndex)...])
                )
            })
    }

    func waitForCompleteStartupRuntimeManifest(
        app: XCUIApplication,
        initialManifest: SmartFillManifest,
        timeout: TimeInterval
    ) throws -> SmartFillManifest {
        var latestManifest = initialManifest
        _ = waitUntil(timeout: timeout) {
            guard let nextManifest = self.currentManifest(app: app) else { return false }
            latestManifest = nextManifest
            return self.hasCompleteStartupRuntimePhases(nextManifest)
        }
        XCTAssertTrue(
            hasCompleteStartupRuntimePhases(latestManifest),
            "Minimal runtime JSONL requires the first-frame manifest to include all startup runtime phases"
        )
        return latestManifest
    }

    func waitForScreenshotReadyManifest(
        app: XCUIApplication,
        initialManifest: SmartFillManifest,
        timeout: TimeInterval,
        scenario: String,
        index: Int
    ) throws -> SmartFillManifest {
        var latestManifest = initialManifest
        _ = waitUntil(timeout: timeout) {
            guard let nextManifest = self.currentManifest(app: app) else { return false }
            latestManifest = nextManifest
            return SmartFillRuntimeEvidenceSupport.isReadyForScreenshotEvidence(
                manifestFields: nextManifest.rawFields
            )
        }
        XCTAssertTrue(
            SmartFillRuntimeEvidenceSupport.isReadyForScreenshotEvidence(manifestFields: latestManifest.rawFields),
            "\(scenario) frame \(index + 1) must wait for images to be ready before the screenshot, current state: \(SmartFillRuntimeEvidenceSupport.screenshotEvidenceReadinessReason(manifestFields: latestManifest.rawFields))"
        )
        return latestManifest
    }

    func hasCompleteStartupRuntimePhases(_ manifest: SmartFillManifest) -> Bool {
        guard let timestamps = manifest.rawFields["runtimePhaseTimestampsMs"],
            let durations = manifest.rawFields["runtimePhaseDurationsMs"]
        else {
            return false
        }
        return SmartFillRuntimeEvidenceSupport.requiredRuntimePhaseKeys.allSatisfy { phase in
            timestamps.contains("\(phase):") && durations.contains("\(phase):")
        }
    }

    func currentManifest(app: XCUIApplication) -> SmartFillManifest? {
        let probe = app.descendants(matching: .any)["slideshow.smartfill.currentManifest.flag"]
        guard probe.exists else { return nil }
        return parseManifest(probe.label.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func waitForCurrentAssetReference(app: XCUIApplication, timeout: TimeInterval) throws -> String {
        guard waitUntil(timeout: timeout, condition: { self.currentAssetReference(app: app) != nil }) else {
            throw SmartFillIOSFailure.missingCurrentAssetProbe
        }
        guard let reference = currentAssetReference(app: app) else {
            throw SmartFillIOSFailure.missingCurrentAssetProbe
        }
        return reference
    }

    func currentAssetReference(app: XCUIApplication) -> String? {
        let probe = app.descendants(matching: .any)["slideshow.currentAssetId.flag"]
        guard probe.exists else { return nil }
        let raw = probe.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty || raw == "no-asset" ? nil : raw
    }

    func rawCurrentAssetID(in manifest: SmartFillManifest) -> String? {
        let slotRefs =
            manifest.rawFields["slotRefs"]?
            .split(separator: ",")
            .map(String.init) ?? []
        let disposition = manifest.rawFields["currentAssetDisposition"] ?? "missing"
        let index: Int
        switch disposition {
        case "primary-slot", "single-slot", "fallback-current":
            index = 0
        case "secondary-slot":
            index = 1
        case "tertiary-slot":
            index = 2
        default:
            return nil
        }
        guard slotRefs.indices.contains(index) else { return nil }
        return slotRefs[index]
    }

    func firstIndexMap(for values: [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        for (index, value) in values.enumerated() where result[value] == nil {
            result[value] = index
        }
        return result
    }

    func parseManifest(_ raw: String) -> SmartFillManifest? {
        guard raw.contains("version=smart-fill-planner-v2") else { return nil }
        let fields = Dictionary(
            uniqueKeysWithValues: raw.split(separator: ";").compactMap { part -> (String, String)? in
                guard let equalIndex = part.firstIndex(of: "=") else { return nil }
                let key = String(part[..<equalIndex])
                let value = String(part[part.index(after: equalIndex)...])
                return (key, value)
            }
        )
        guard SmartFillRuntimeEvidenceSupport.requiredSummaryFields.allSatisfy({ fields[$0] != nil }),
            let sceneType = fields["sceneType"],
            let policy = fields["policy"],
            let rawSlotCount = fields["slotCount"],
            let slotCount = Int(rawSlotCount),
            let fallback = fields["fallback"],
            let fallbackCategory = fields["fallbackCategory"],
            let slotRefs = fields["slotRefs"],
            let rejects = fields["rejects"],
            let surfaceKey = fields["surfaceKey"],
            let surface = parseSurfaceKey(surfaceKey),
            let slotFrames = fields["slotFrames"],
            let layoutVariant = fields["layoutVariant"],
            let ratioPreset = fields["ratioPreset"],
            let cropRetention = fields["cropRetention"],
            let protectionContained = fields["protectionContained"],
            let rawCandidateWindowUsed = fields["candidateWindowUsed"],
            let candidateWindowUsed = Int(rawCandidateWindowUsed),
            let rawEvaluationCount = fields["evaluationCount"],
            let evaluationCount = Int(rawEvaluationCount),
            let rotationStartLayoutVariant = fields["rotationStartLayoutVariant"],
            let rotationStartRatioPreset = fields["rotationStartRatioPreset"],
            let acceptedLayoutVariant = fields["acceptedLayoutVariant"],
            let acceptedRatioPreset = fields["acceptedRatioPreset"],
            let rotationKeyHashPrefix = fields["rotationKeyHashPrefix"],
            let rejectedLayoutReasonTopList = fields["rejectedLayoutReasonTopList"]
        else {
            return nil
        }
        return SmartFillManifest(
            raw: raw,
            rawFields: fields,
            sceneType: sceneType,
            policy: policy,
            slotCount: slotCount,
            fallback: fallback,
            fallbackCategory: fallbackCategory,
            slotRefs: slotRefs,
            rejects: rejects,
            surfaceKey: surfaceKey,
            surfaceProfile: surface.profile,
            surfaceOrientation: surface.orientation,
            slotFrames: slotFrames,
            layoutVariant: layoutVariant,
            ratioPreset: ratioPreset,
            cropRetention: cropRetention,
            protectionContained: protectionContained,
            candidateWindowUsed: candidateWindowUsed,
            evaluationCount: evaluationCount,
            rotationStartLayoutVariant: rotationStartLayoutVariant,
            rotationStartRatioPreset: rotationStartRatioPreset,
            acceptedLayoutVariant: acceptedLayoutVariant,
            acceptedRatioPreset: acceptedRatioPreset,
            rotationKeyHashPrefix: rotationKeyHashPrefix,
            rejectedLayoutReasonTopList: rejectedLayoutReasonTopList
        )
    }

    func makeRuntimeManifestForTesting() -> String {
        [
            "version=smart-fill-planner-v2",
            "sceneType=double",
            "surfaceKey=iPhone-landscape-regular-compact-safeA",
            "surfaceFingerprint=iPhone-landscape-393x852-safeA",
            "policy=iphone-landscape-v2",
            "layoutVariant=horizontal-equal",
            "ratioPreset=50/50",
            "photoCanvasId=canvas-iphone-landscape",
            "photoCanvasPointSize=852.000x393.000",
            "photoCanvasPixelSize=2556x1179",
            "canvasCoverage=1.000",
            "emptyCanvasRatio=0.000",
            "maxContinuousEmptyAxisRatio=0.000",
            "gapPixelCount=0",
            "overlapPixelCount=0",
            "slotCount=2",
            "slotRoles=primary,secondary",
            "slotRefs=asset-1111,asset-2222",
            "currentAssetDisposition=primary-slot",
            "currentAssetAbsentReason=none",
            "currentAssetSlotAreaRatio=0.500",
            "currentAssetCropRetention=0.900",
            "currentAssetProtectedRegionCoverage=1.000",
            "currentAssetFaceProtectionPassed=true",
            "currentAssetSubjectProtectionPassed=true",
            "currentAssetVisibleQualityClass=acceptable",
            "cropRetentionThresholdUsed=0.600",
            "acceptedSceneSearchTier=double",
            "candidateWindowRequested=24",
            "candidateWindowExpansionTrace=24:accepted",
            "slotFrames=x0.000y0.000w0.500h1.000,x0.500y0.000w0.500h1.000",
            "slotCropRects=x0.000y0.000w1.000h1.000,x0.000y0.000w1.000h1.000",
            "cropRetention=0.900,0.850",
            "protectionContained=true,true",
            "controlBarHardRejected=false",
            "controlBarSubjectOverlapWarningCount=0",
            "exifOverlayHardRejected=false",
            "fallbackCategory=none",
            "candidateWindowUsed=24",
            "evaluationCount=4",
            "rotationStartLayoutVariant=horizontal-equal",
            "rotationStartRatioPreset=50/50",
            "acceptedLayoutVariant=horizontal-equal",
            "acceptedRatioPreset=50/50",
            "rotationKeyHashPrefix=abc12345",
            "fallback=none",
            "rejects=none",
            "rejectedLayoutReasonTopList=none",
            "rejectedLayoutDiagnostics=none",
            "slotReadiness=ready,pending",
            "ledgerSceneAssets=asset-1111,asset-2222",
            "controlBarVisible=true",
            "exifOverlayVisible=false",
            "publishReason=manualNext",
            "preparedHit=true",
            "actionToSceneLatencyMs=25.000"
        ].joined(separator: ";")
    }

    func makeStartupRuntimeManifestForTesting(overrides: [String: String] = [:]) -> String {
        var baseFields = makeRuntimeManifestForTesting()
            .split(separator: ";")
            .reduce(into: [String: String]()) { result, part in
                let entry = String(part)
                guard let equalIndex = entry.firstIndex(of: "=") else { return }
                let key = String(entry[..<equalIndex])
                let value = String(entry[entry.index(after: equalIndex)...])
                result[key] = value
            }
        var fields = [
            "runtimePhaseTimestampsMs":
                "playbackEntryRequested:0,assetPoolRequestStarted:8,assetPoolReady:24,firstScenePlanningStarted:31,firstScenePlanned:45,firstScenePublished:60,firstSlotReady:82,allVisibleSlotsReady:96",
            "runtimePhaseDurationsMs":
                "playbackEntryRequested:0,assetPoolRequestStarted:8,assetPoolReady:16,firstScenePlanningStarted:7,firstScenePlanned:14,firstScenePublished:15,firstSlotReady:22,allVisibleSlotsReady:14",
            "assetPoolSizeAtFirstPlan": "36",
            "eligibleCandidateCountAtFirstPlan": "24",
            "plannerAttemptCountAtFirstPlan": "4",
            "candidateWindowUsedAtFirstPlan": "12",
            "firstSceneSlotReadiness": "ready,pending",
            "photoLoadPhaseTimestampsMs":
                "cacheChecked:70,downloadRequestStarted:72,downloadCompleted:96,decodeCompleted:100,firstImageDisplayed:104",
            "photoLoadPhaseDurationsMs":
                "cacheChecked:0,downloadRequestStarted:2,downloadCompleted:24,decodeCompleted:4,firstImageDisplayed:4",
            "firstPhotoCacheStatus": "miss",
            "firstImageDisplayedRuntimeMs": "104",
            "firstImageLoadStatus": "displayed",
            "fallbackReasonTopList": "none",
            "rejectedLayoutDiagnostics": "none",
            "candidateRejectReasonTopList": "none",
            "protectionOverlapDetails": "none",
            "lookaheadExhausted": "false",
            "resourceReadinessAffectedFallback": "false",
            "controlBarAffectedFallback": "false",
            "legacyRendererUsedForSmartFillFallback": "false",
            "fallbackRootCauseBucket": "none"
        ]
        for (key, value) in overrides {
            fields[key] = value
        }
        for (key, value) in fields {
            baseFields[key] = value
        }
        return
            baseFields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ";")
    }

    func parseSurfaceKey(_ raw: String) -> (profile: String, orientation: String)? {
        let parts = raw.split(separator: "-")
        guard parts.count >= 2 else {
            return nil
        }
        return (String(parts[0]), String(parts[1]))
    }

    func assertManifestIsRedacted(_ manifest: String) {
        let lowercased = manifest.lowercased()
        XCTAssertFalse(lowercased.contains("http://"))
        XCTAssertFalse(lowercased.contains("https://"))
        XCTAssertFalse(lowercased.contains("api_key"))
        XCTAssertFalse(lowercased.contains("api key"))
        XCTAssertFalse(lowercased.contains("token"))
        XCTAssertFalse(lowercased.contains("base64"))
    }

    func assertManifestMeetsSpecGates(_ manifest: SmartFillManifest, scenario: String, index: Int) {
        XCTAssertFalse(manifest.layoutVariant.isEmpty, "\(scenario) frame \(index + 1) should record layoutVariant")
        XCTAssertFalse(manifest.ratioPreset.isEmpty, "\(scenario) frame \(index + 1) should record ratioPreset")
        XCTAssertFalse(
            manifest.rotationKeyHashPrefix.isEmpty, "\(scenario) frame \(index + 1) should record rotationKeyHashPrefix"
        )
        XCTAssertGreaterThan(
            manifest.candidateWindowUsed, 0, "\(scenario) frame \(index + 1) should record candidateWindowUsed")
        XCTAssertGreaterThanOrEqual(
            manifest.evaluationCount, 0, "\(scenario) frame \(index + 1) should record evaluationCount")

        if manifest.surfaceProfile == "iPhone" {
            XCTAssertNotEqual(
                manifest.sceneType, "triple", "\(scenario) frame \(index + 1): iPhone does not allow triple")
        }

        guard manifest.sceneType != "fallback" else { return }
        let retentions = manifest.cropRetention
            .split(separator: ",")
            .compactMap { Double($0) }
        XCTAssertEqual(
            retentions.count,
            manifest.slotCount,
            "\(scenario) frame \(index + 1) should record cropRetention for every slot"
        )
        let cropRetentionThreshold = cropRetentionThreshold(for: manifest)
        let thresholdLabel = String(format: "%.0f%%", cropRetentionThreshold * 100)
        XCTAssertTrue(
            retentions.allSatisfy { $0 >= cropRetentionThreshold },
            "\(scenario) frame \(index + 1): cropRetention of every accepted slot should be >= \(thresholdLabel)"
        )
        let protectionValues = manifest.protectionContained.split(separator: ",").map(String.init)
        XCTAssertEqual(
            protectionValues.count,
            manifest.slotCount,
            "\(scenario) frame \(index + 1) should record protectionContained for every slot"
        )
        XCTAssertTrue(
            protectionValues.allSatisfy { $0 == "true" },
            "\(scenario) frame \(index + 1): every accepted slot should fully contain its protected region"
        )
    }

    func cropRetentionThreshold(for manifest: SmartFillManifest) -> Double {
        Double(manifest.rawFields["cropRetentionThresholdUsed"] ?? "") ?? 0.60
    }

    func attachManifestSummary(_ manifests: [SmartFillManifest], scenario: String) {
        let fallbackDistribution = SmartFillFallbackEvidencePolicy.format(
            SmartFillFallbackEvidencePolicy.distribution(from: manifests.map(\.fallbackCategory))
        )
        let summary =
            ([
                "fallbackDistribution=\(fallbackDistribution)"
            ]
            + manifests.enumerated().map { index, manifest in
                [
                    "index=\(index + 1)",
                    "sceneType=\(manifest.sceneType)",
                    "policy=\(manifest.policy)",
                    "layoutVariant=\(manifest.layoutVariant)",
                    "ratioPreset=\(manifest.ratioPreset)",
                    "slotCount=\(manifest.slotCount)",
                    "fallback=\(manifest.fallback)",
                    "fallbackCategory=\(manifest.fallbackCategory)",
                    "rejects=\(manifest.rejects)",
                    "rejectedLayoutReasonTopList=\(manifest.rejectedLayoutReasonTopList)",
                    "surfaceKey=\(manifest.surfaceKey)",
                    "surfaceProfile=\(manifest.surfaceProfile)",
                    "surfaceOrientation=\(manifest.surfaceOrientation)",
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
                    "slotRefs=\(manifest.slotRefs)"
                ].joined(separator: ";")
            }).joined(separator: "\n")
        let attachment = XCTAttachment(string: summary)
        attachment.name = "smartfill-\(scenario)-manifest-\(deviceTag())"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func assertPolicies(in evidence: SmartFillEvidence, contain expectedFragment: String, scenario: String) {
        XCTAssertTrue(
            evidence.manifests.allSatisfy { $0.policy.contains(expectedFragment) },
            "\(scenario) should read back the \(expectedFragment) policy"
        )
    }

    func assertFallbackDistributionMeetsSpec(in evidence: SmartFillEvidence, scenario: String) {
        let forbiddenDistribution = evidence.forbiddenFallbackDistribution
        XCTAssertTrue(
            forbiddenDistribution.isEmpty,
            "\(scenario) forbidden fallback categories must be 0, forbidden distribution: \(SmartFillFallbackEvidencePolicy.format(forbiddenDistribution)), full distribution: \(SmartFillFallbackEvidencePolicy.format(evidence.fallbackDistribution))"
        )
    }

    func assertSurfaces(
        in evidence: SmartFillEvidence,
        orientation expectedOrientation: SmartFillSurfaceExpectation,
        scenario: String
    ) {
        let isExpectedOrientation: (SmartFillManifest) -> Bool = { manifest in
            switch expectedOrientation {
            case .portrait:
                return manifest.surfaceOrientation == "portrait"
            case .landscape:
                return manifest.surfaceOrientation == "landscape"
            }
        }
        XCTAssertTrue(
            evidence.manifests.allSatisfy(isExpectedOrientation),
            "\(scenario) should read back Smart Fill surface geometry matching the target orientation"
        )
    }

    func attachScreenshot(app: XCUIApplication, name: String) {
        _ = captureRuntimeScreenshot(app: app, name: name, attachToXCTest: true)
    }

    func captureRuntimeScreenshot(
        app: XCUIApplication,
        name: String,
        attachToXCTest: Bool
    ) -> (path: String, captureTimestamp: String)? {
        // In a landscape Simulator an app-element screenshot can keep the old window bounds,
        // so runtime evidence takes a full-screen screenshot.
        let screenshot = XCUIScreen.main.screenshot()
        if attachToXCTest {
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        guard let directory = evidenceDirectory() else { return nil }
        let captureTimestamp = SmartFillRuntimeEvidenceSupport.captureTimestamp()
        let fileURL = directory.appendingPathComponent(sanitizedEvidenceFileName(name) + ".png")
        guard
            let writtenURL = SmartFillRuntimeEvidenceSupport.writeScreenshotPNG(
                screenshot.pngRepresentation,
                to: fileURL
            )
        else {
            XCTFail("SmartFill runtime PNG write or read-back failed: \(fileURL.lastPathComponent)")
            return nil
        }
        return (writtenURL.path, captureTimestamp)
    }

    func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
            return
        }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    func saveEvidenceScreenshot(app: XCUIApplication, scenario: String, step: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(scenario)-\(step)"
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let evidenceDirectory = playbackTransitionEvidenceDirectory() else { return }
        do {
            let fileURL = evidenceDirectory.appendingPathComponent("\(scenario)-\(step).png")
            try screenshot.pngRepresentation.write(to: fileURL, options: .atomic)
        } catch {
            XCTFail("Cannot write runtime screenshot evidence")
        }
    }

    func playbackTransitionEvidenceDirectory() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let path = env["TEST_RUNNER_UI_TEST_EVIDENCE_DIR"] ?? env["UI_TEST_EVIDENCE_DIR"]
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

    func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    func deviceTag() -> String {
        switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            return "iphone"
        case .pad:
            return "ipad"
        default:
            return UIDevice.current.model.replacingOccurrences(of: " ", with: "_").lowercased()
        }
    }

    func smartFillTargetSceneCount() -> Int {
        let environment = ProcessInfo.processInfo.environment
        let rawValue =
            environment["IMMICHSLIDES_SMARTFILL_SCENE_COUNT"]
            ?? environment["TEST_RUNNER_IMMICHSLIDES_SMARTFILL_SCENE_COUNT"]
        guard let rawValue,
            let count = Int(rawValue),
            count > 0
        else {
            return 20
        }
        return count
    }

    func shouldWaitForCompleteStartupRuntimePhases() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["IMMICHSLIDES_REQUIRE_STARTUP_PHASES"] == "1"
            || environment["TEST_RUNNER_IMMICHSLIDES_REQUIRE_STARTUP_PHASES"] == "1"
    }

    func screenshotSampleIndices(for sceneCount: Int) -> Set<Int> {
        guard sceneCount >= 10 else {
            return Set(0..<sceneCount)
        }
        return Set(
            (0..<10).map { sampleIndex in
                Int((Double(sampleIndex) * Double(sceneCount - 1) / 9.0).rounded())
            })
    }

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
            appLaunchStartMs: 0,
            testServerConfigInjectedMs: 0,
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
            return 36
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
            return 5.0
        }
        return value
    }

    func smartFillMotionIntervalIsPreseeded() -> Bool {
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
            return 60
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
            "deviceRequirement": "any-iPhone",
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
            "deviceRequirement": "any-iPhone",
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

    func writeInteractionActionEvidence(_ actions: [[String: Any]], scenario: String) {
        guard let directory = motionEvidenceDirectory() else { return }
        let payload: [String: Any] = [
            "schemaVersion": "interaction-actions-v1",
            "scenario": scenario,
            "deviceTag": deviceTag(),
            "actions": actions
        ]
        requireEvidenceWrite {
            try SmartFillRuntimeEvidenceSupport.writeJSONObject(
                payload,
                to: directory.appendingPathComponent("user-actions.json")
            )
        }
        requireEvidenceWrite {
            try interactionActionCSV(actions)
                .write(to: directory.appendingPathComponent("user-actions.csv"), atomically: true, encoding: .utf8)
        }
    }

    func interactionActionCSV(_ actions: [[String: Any]]) -> String {
        let columns = [
            "action",
            "elapsedSeconds",
            "timestamp"
        ]
        let body = actions.map { action in
            columns.map { column in
                if column == "elapsedSeconds", let value = action[column] as? Double {
                    return String(format: "%.6f", value)
                }
                return csvEscaped("\(action[column] ?? "")")
            }.joined(separator: ",")
        }.joined(separator: "\n")
        return ([columns.joined(separator: ",")] + [body]).joined(separator: "\n")
    }

    func productSceneSequenceDictionary(_ row: ProductSceneSequenceRow) -> [String: Any] {
        let endpoints = productTransitionEndpointSceneTypes(row.productTransitionFields)
        var object: [String: Any] = [
            "sampleIndex": row.sampleIndex,
            "elapsedSeconds": row.elapsedSeconds,
            "manifestSlotRefs": row.manifestSlotRefs,
            "manifestSceneType": row.manifestSceneType,
            "productTransitionActive": row.productTransitionFields["productTransitionActive"] ?? "missing",
            "acceptedMotionTransitionActive": row.productTransitionFields["acceptedMotionTransitionActive"]
                ?? "missing",
            "productBlackBackingActive": row.productTransitionFields["productBlackBackingActive"]
                ?? row.productTransitionFields["blackBackingActive"] ?? "missing",
            "transitionFromSceneType": endpoints.from,
            "transitionToSceneType": endpoints.to,
            "transitionLayerRoles": row.productTransitionFields["transitionLayerRoles"] ?? "missing",
            "transitionLayerSceneTypes": row.productTransitionFields["transitionLayerSceneTypes"] ?? "missing",
            "transitionLayerScopes": row.productTransitionFields["transitionLayerScopes"] ?? "missing"
        ]
        for (key, value) in row.productTransitionFields {
            object[key] = value
        }
        return object
    }

    func productSceneSequenceCSV(_ rows: [ProductSceneSequenceRow]) -> String {
        let columns = [
            "sampleIndex",
            "elapsedSeconds",
            "manifestSlotRefs",
            "manifestSceneType",
            "productTransitionActive",
            "acceptedMotionTransitionActive",
            "productBlackBackingActive",
            "transitionFromSceneType",
            "transitionToSceneType",
            "transitionLayerRoles",
            "transitionLayerSceneTypes",
            "transitionLayerScopes"
        ]
        let body = rows.map { row in
            let dictionary = productSceneSequenceDictionary(row)
            return columns.map { column in
                switch column {
                case "sampleIndex":
                    return "\(row.sampleIndex)"
                case "elapsedSeconds":
                    return String(format: "%.6f", row.elapsedSeconds)
                default:
                    return csvEscaped("\(dictionary[column] ?? "")")
                }
            }.joined(separator: ",")
        }.joined(separator: "\n")
        return ([columns.joined(separator: ",")] + [body]).joined(separator: "\n")
    }

    func productTransitionEndpointSceneTypes(_ fields: [String: String]) -> (from: String, to: String) {
        let roles =
            fields["transitionLayerRoles"]?
            .split(separator: "|")
            .map(String.init) ?? []
        let sceneTypes =
            fields["transitionLayerSceneTypes"]?
            .split(separator: "|")
            .map(String.init) ?? []
        var from = "none"
        var to = "none"
        for (index, role) in roles.enumerated() where sceneTypes.indices.contains(index) {
            if role == "outgoing" {
                from = sceneTypes[index]
            }
            if role == "incoming" {
                to = sceneTypes[index]
            }
        }
        return (from, to)
    }

    func motionFrameDictionary(_ row: MotionFrameEvidenceRow) -> [String: Any] {
        var object: [String: Any] = [
            "sampleIndex": row.sampleIndex,
            "elapsedSeconds": row.elapsedSeconds,
            "probeIdentifier": row.probeIdentifier,
            "manifestSlotRefs": row.manifestSlotRefs,
            "manifestSceneType": row.manifestSceneType
        ]
        for (key, value) in row.fields {
            object[key] = value
        }
        return object
    }

    func motionFrameCSV(_ rows: [MotionFrameEvidenceRow]) -> String {
        let columns = [
            "sampleIndex",
            "elapsedSeconds",
            "probeIdentifier",
            "sceneId",
            "slotId",
            "assetId",
            "renderRole",
            "controlBarVisible",
            "appOverlayPollution",
            "acceptedMotionScope",
            "singleFilledScope",
            "progressFrameStatus",
            "clockGeneration",
            "progress",
            "progressSource",
            "presentationProgressSource",
            "visualFrameSource",
            "presentationModelDivergenceStatus",
            "isDiscontinuous",
            "extensionReason",
            "timelineStartTime",
            "stableVisibleStartTime",
            "handoffStartDeadlineTime",
            "removalDeadlineTime",
            "stableVisibleDuration",
            "transitionCompletionDelay",
            "preparedNextTargetIndex",
            "preparedNextSourceCursor",
            "currentPreparedSourceCursor",
            "lookaheadCachedSourceCursor",
            "lookaheadCachedSelectedCount",
            "scale",
            "translationX",
            "translationY",
            "renderedFrameMinX",
            "renderedFrameMinY",
            "renderedFrameWidth",
            "renderedFrameHeight",
            "presentationFrameMinX",
            "presentationFrameMinY",
            "presentationFrameWidth",
            "presentationFrameHeight",
            "modelFrameMinX",
            "modelFrameMinY",
            "modelFrameWidth",
            "modelFrameHeight",
            "anchorX",
            "anchorY",
            "focalSourceKind",
            "focalProvenance",
            "zoomDirection",
            "stableSeedHash",
            "seedInputSummary",
            "requestedTranslationX",
            "requestedTranslationY",
            "clampedTranslationX",
            "clampedTranslationY",
            "endTranslationX",
            "endTranslationY",
            "phaseAction",
            "isIdentity",
            "manifestSlotRefs",
            "manifestSceneType"
        ]
        let body = rows.map { row in
            columns.map { column in
                switch column {
                case "sampleIndex":
                    return "\(row.sampleIndex)"
                case "elapsedSeconds":
                    return String(format: "%.6f", row.elapsedSeconds)
                case "probeIdentifier":
                    return csvEscaped(row.probeIdentifier)
                case "manifestSlotRefs":
                    return csvEscaped(row.manifestSlotRefs)
                case "manifestSceneType":
                    return csvEscaped(row.manifestSceneType)
                default:
                    return csvEscaped(row.fields[column] ?? "")
                }
            }.joined(separator: ",")
        }.joined(separator: "\n")
        return ([columns.joined(separator: ",")] + [body]).joined(separator: "\n")
    }

    func csvEscaped(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    func sanitizedEvidenceFileName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return raw.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
    }

    func makePersonFilterSelectionJSON(personID: String) -> String {
        let object: [String: Any] = [
            "albumIds": [],
            "personFilters": [
                [
                    "personId": personID,
                    "matchMode": "normal"
                ]
            ],
            "tagIds": []
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [])
        return String(data: data, encoding: .utf8)!
    }

    func makeAlbumFilterSelectionJSON(albumID: String) -> String {
        let object: [String: Any] = [
            "albumIds": [albumID],
            "personFilters": [],
            "tagIds": []
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [])
        return String(data: data, encoding: .utf8)!
    }

    func requireFixedAlbumID() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let rawValue =
            environment["IMMICHSLIDES_SMARTFILL_FIXED_ALBUM_ID"]
            ?? environment["TEST_RUNNER_IMMICHSLIDES_SMARTFILL_FIXED_ALBUM_ID"]
        guard let albumID = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !albumID.isEmpty
        else {
            throw XCTSkip("Fixed-album Smart Fill UI acceptance requires IMMICHSLIDES_SMARTFILL_FIXED_ALBUM_ID")
        }
        return albumID
    }

    func findEligiblePersonID(minimumAssetCount: Int) async throws -> String {
        let config = try requireTestServerConfig()
        let baseURL = config.url.hasSuffix("/") ? String(config.url.dropLast()) : config.url
        let peopleObject = try await requestJSON(
            urlString: "\(baseURL)/people?size=100",
            apiKey: config.apiKey
        )
        let people: [[String: Any]]
        if let object = peopleObject as? [String: Any],
            let peopleArray = object["people"] as? [[String: Any]]
        {
            people = peopleArray
        } else if let peopleArray = peopleObject as? [[String: Any]] {
            people = peopleArray
        } else {
            throw XCTSkip(
                "Test server people list response has an unexpected format; cannot run the people-filter Smart Fill UI acceptance."
            )
        }

        for person in people {
            guard let personID = person["id"] as? String else { continue }
            let encodedPersonID = personID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? personID
            let statsObject = try await requestJSON(
                urlString: "\(baseURL)/people/\(encodedPersonID)/statistics",
                apiKey: config.apiKey
            )
            let count = (statsObject as? [String: Any])?["assets"] as? Int ?? 0
            if count >= minimumAssetCount {
                return personID
            }
        }

        throw XCTSkip(
            "Test server has no person with at least \(minimumAssetCount) assets; people-filter 20-frame acceptance is marked BLOCKED_ENV."
        )
    }

    func requestJSON(urlString: String, apiKey: String) async throws -> Any {
        guard let url = URL(string: urlString) else {
            throw XCTSkip("Cannot build the test server URL.")
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("immichSlides-smartfill-ui-test", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else {
            throw XCTSkip(
                "Read-only probe of the test server failed; people-filter Smart Fill UI acceptance is marked BLOCKED_ENV."
            )
        }
        return try JSONSerialization.jsonObject(with: data)
    }
}
#endif

#if os(tvOS)
final class PlaybackSmartFillTVOSVisualUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSmartFillRandomPlaybackTwentyScenesOnAppleTV() throws {
        let app = try launchConfiguredAppAtModeSelection()
        startRandomPlaybackFromModeSelection(app: app)

        let evidence = try collectTwentySceneEvidence(app: app, scenario: "random-tvos")
        assertPolicies(in: evidence, contain: "appletv-landscape", scenario: "Apple TV random playback")
        assertSurfacesAreLandscape(in: evidence, scenario: "Apple TV random playback")
        assertFallbackDistributionMeetsSpec(in: evidence, scenario: "Apple TV random playback")
    }

    @MainActor
    func testPlaybackTransitionAnimationEvidenceControlBarQuickSwitchOnAppleTV() throws {
        let app = try launchConfiguredAppAtModeSelection()
        startRandomPlaybackFromModeSelection(app: app)
        attachScreenshot(app: app, name: "appletv-transition-00-before")

        for index in 1...3 {
            pressNext(app: app)
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
            attachScreenshot(app: app, name: "appletv-transition-\(index)-mid")
            RunLoop.current.run(until: Date().addingTimeInterval(0.65))
            attachScreenshot(app: app, name: "appletv-transition-\(index)-settled")
        }

        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: 6),
            "Apple TV control bar settings button should still exist after quick switching"
        )
    }

    @MainActor
    func testSmartFillMotionAppleTVRealAutoplayRuntimeEvidence() throws {
        let scenario = smartFillMotionScenarioName(
            defaultScenario: "apple-tv-smartfill-motion-real-autoplay"
        )
        let app = try launchConfiguredAppAtModeSelection(
            forceAutoplayOff: false,
            enableSmartFillMotionTrace: true
        )
        startRandomPlaybackFromModeSelection(app: app)

        XCTAssertTrue(
            waitUntil(timeout: 12) {
                !app.buttons["slideshow.control.settings.button"].exists
            },
            "\(scenario) control bar must auto-hide before sampling so clean motion rows are not polluted by the control bar"
        )
        _ = try waitForCurrentManifest(app: app, timeout: 45)

        let sampleDuration = smartFillMotionSampleDurationSeconds()
        let evidence = collectMotionRuntimeEvidence(
            app: app,
            scenario: scenario,
            duration: sampleDuration,
            interval: smartFillMotionSampleIntervalSeconds()
        )
        let traceText = try appSmartFillMotionTraceText(app: app, timeout: sampleDuration + 30)
        let fallbackManifest = try waitForCurrentManifest(app: app, timeout: 5)
        let traceMotionRows = motionFrameRows(fromTraceText: traceText, fallbackManifest: fallbackManifest)
        let traceProductRows = productSceneSequenceRows(fromTraceText: traceText, fallbackManifest: fallbackManifest)
        let motionRows = traceMotionRows.isEmpty ? evidence.motionRows : traceMotionRows
        let productRows = traceProductRows.isEmpty ? evidence.productRows : traceProductRows

        writeProductSceneSequenceEvidence(
            productRows,
            motionRows: motionRows,
            scenario: scenario,
            sampleDuration: sampleDuration
        )
        writeMotionFrameEvidence(motionRows, scenario: scenario)

        let productSceneTypes = Set(productRows.map(\.manifestSceneType))
        let cleanAvailableSceneTypes = Set(
            motionRows.compactMap { row -> String? in
                guard row.fields["progressFrameStatus"] == "available",
                    row.fields["controlBarVisible"] == "false",
                    row.fields["appOverlayPollution"] == "none"
                else {
                    return nil
                }
                return row.manifestSceneType
            })
        let transitionRows = productRows.filter { row in
            row.productTransitionFields["productTransitionActive"] == "true"
        }
        let transitionRowsWithoutBacking = transitionRows.filter { row in
            row.productTransitionFields["productBlackBackingActive"] != "true"
        }

        XCTAssertFalse(motionRows.isEmpty, "\(scenario) must capture Apple TV motion frame rows")
        XCTAssertFalse(productRows.isEmpty, "\(scenario) must capture the Apple TV product scene sequence")
        XCTAssertTrue(
            productSceneTypes.contains("double") || productSceneTypes.contains("triple"),
            "\(scenario) must cover a SmartFill accepted double/triple scene"
        )
        XCTAssertTrue(
            productSceneTypes.contains("single"), "\(scenario) must cover a SmartFill planner single-filled scene")
        XCTAssertTrue(
            cleanAvailableSceneTypes.contains("double") || cleanAvailableSceneTypes.contains("triple"),
            "\(scenario) clean rows must include accepted double/triple motion"
        )
        XCTAssertTrue(
            cleanAvailableSceneTypes.contains("single"), "\(scenario) clean rows must include SmartFill single motion")
        XCTAssertFalse(transitionRows.isEmpty, "\(scenario) must cover a real autoplay transition")
        XCTAssertTrue(
            transitionRowsWithoutBacking.isEmpty,
            "\(scenario) accepted/single SmartFill transitions must enable the black backing"
        )
        _ = captureRuntimeScreenshot(app: app, name: "smartfill-\(scenario)-appletv-final", attachToXCTest: true)
    }

    @MainActor
    func testSmartFillMotionAppleTVRemoteInteractionLivenessEvidence() throws {
        let scenario = smartFillMotionScenarioName(
            defaultScenario: "apple-tv-smartfill-motion-remote-interaction-liveness"
        )
        let app = try launchConfiguredAppAtModeSelection(
            forceAutoplayOff: false,
            enableSmartFillMotionTrace: true
        )
        startRandomPlaybackFromModeSelection(app: app)

        XCTAssertTrue(
            waitUntil(timeout: 12) {
                !app.buttons["slideshow.control.settings.button"].exists
            },
            "\(scenario) control bar must auto-hide before the interaction"
        )
        let initialManifest = try waitForCurrentManifest(app: app, timeout: 45)
        let traceStartedAt = try waitForSmartFillMotionTraceCollecting(app: app, timeout: 45)

        var actions: [[String: Any]] = []
        let sampleDuration = smartFillMotionInteractionSampleDurationSeconds()
        let evidence = collectMotionRuntimeEvidence(
            app: app,
            scenario: scenario,
            duration: sampleDuration,
            interval: smartFillMotionSampleIntervalSeconds()
        ) { elapsed in
            if actions.isEmpty, elapsed >= 1.0 {
                XCUIRemote.shared.press(.up)
                self.recordInteractionAction(
                    "tap-image-show-control-bar",
                    elapsed: ProcessInfo.processInfo.systemUptime - traceStartedAt,
                    actions: &actions
                )
            }
            if actions.containsAction("tap-image-show-control-bar"),
                !actions.containsAction("select-control-bar-next"),
                elapsed >= 2.0
            {
                self.pressNext(app: app)
                self.recordInteractionAction(
                    "select-control-bar-next",
                    elapsed: ProcessInfo.processInfo.systemUptime - traceStartedAt,
                    actions: &actions
                )
            }
            if actions.containsAction("select-control-bar-next"),
                !actions.containsAction("pause"),
                elapsed >= 8.0
            {
                XCUIRemote.shared.press(.playPause)
                self.recordInteractionAction(
                    "pause",
                    elapsed: ProcessInfo.processInfo.systemUptime - traceStartedAt,
                    actions: &actions
                )
            }
            if actions.containsAction("pause"),
                !actions.containsAction("resume"),
                elapsed >= 10.0
            {
                XCUIRemote.shared.press(.playPause)
                self.recordInteractionAction(
                    "resume",
                    elapsed: ProcessInfo.processInfo.systemUptime - traceStartedAt,
                    actions: &actions
                )
            }
            if actions.containsAction("resume"),
                !actions.containsAction("control-bar-auto-hidden"),
                !app.buttons["slideshow.control.settings.button"].exists
            {
                self.recordInteractionAction(
                    "control-bar-auto-hidden",
                    elapsed: ProcessInfo.processInfo.systemUptime - traceStartedAt,
                    actions: &actions
                )
            }
        }
        XCUIRemote.shared.press(.menu)
        recordInteractionAction(
            "menu-return",
            elapsed: ProcessInfo.processInfo.systemUptime - traceStartedAt,
            actions: &actions
        )

        let traceText = try appSmartFillMotionTraceText(app: app, timeout: sampleDuration + 30)
        let traceMotionRows = motionFrameRows(fromTraceText: traceText, fallbackManifest: initialManifest)
        let traceProductRows = productSceneSequenceRows(fromTraceText: traceText, fallbackManifest: initialManifest)
        let motionRows = traceMotionRows.isEmpty ? evidence.motionRows : traceMotionRows
        let productRows = traceProductRows.isEmpty ? evidence.productRows : traceProductRows

        writeProductSceneSequenceEvidence(
            productRows,
            motionRows: motionRows,
            scenario: scenario,
            sampleDuration: sampleDuration
        )
        writeMotionFrameEvidence(motionRows, scenario: scenario)
        writeInteractionActionEvidence(actions, scenario: scenario)

        XCTAssertTrue(
            actions.containsAction("tap-image-show-control-bar"),
            "\(scenario) must cover waking the control bar with the remote")
        XCTAssertTrue(
            actions.containsAction("select-control-bar-next"), "\(scenario) must cover Select on a control bar button")
        XCTAssertTrue(actions.containsAction("pause"), "\(scenario) must cover Play/Pause pause")
        XCTAssertTrue(actions.containsAction("resume"), "\(scenario) must cover Play/Pause resume")
        XCTAssertTrue(
            actions.containsAction("control-bar-auto-hidden"),
            "\(scenario) must cover motion continuing after auto-hide")
        XCTAssertTrue(actions.containsAction("menu-return"), "\(scenario) must cover Back/Menu or an equivalent return")
        XCTAssertFalse(motionRows.isEmpty, "\(scenario) must capture motion rows during the interaction")
        XCTAssertFalse(
            motionRows.filter { $0.fields["progressFrameStatus"] == "available" }.isEmpty,
            "\(scenario) available motion rows must continue during the interaction"
        )
        _ = captureRuntimeScreenshot(app: app, name: "smartfill-\(scenario)-appletv-final", attachToXCTest: true)
    }

    @MainActor
    func testSmartFillPeopleFilterPlaybackTwentyScenesOnAppleTV() async throws {
        let personID = try await findEligiblePersonID(minimumAssetCount: 20)
        let selectionJSON = makePersonFilterSelectionJSON(personID: personID)
        let app = try launchConfiguredAppAtModeSelection(selectionJSON: selectionJSON)
        startFilteredPlaybackFromModeSelection(app: app)

        let evidence = try collectTwentySceneEvidence(app: app, scenario: "people-filter-tvos")
        assertPolicies(in: evidence, contain: "appletv-landscape", scenario: "Apple TV people filter playback")
        assertSurfacesAreLandscape(in: evidence, scenario: "Apple TV people filter playback")
        assertFallbackDistributionMeetsSpec(in: evidence, scenario: "Apple TV people filter playback")
    }

    @MainActor
    func testSmartFillFixedAlbumPlaybackTwentyScenesOnAppleTV() throws {
        let albumID = try requireFixedAlbumID()
        let selectionJSON = makeAlbumFilterSelectionJSON(albumID: albumID)
        let app = try launchConfiguredAppAtModeSelection(selectionJSON: selectionJSON)
        startFilteredPlaybackFromModeSelection(app: app)

        let evidence = try collectTwentySceneEvidence(app: app, scenario: "fixed-album-tvos")
        assertPolicies(in: evidence, contain: "appletv-landscape", scenario: "Apple TV fixed album playback")
        assertSurfacesAreLandscape(in: evidence, scenario: "Apple TV fixed album playback")
        assertFallbackDistributionMeetsSpec(in: evidence, scenario: "Apple TV fixed album playback")
    }
}

private extension PlaybackSmartFillTVOSVisualUITests {
    struct SmartFillEvidence {
        let manifests: [SmartFillManifest]

        var fallbackDistribution: [String: Int] {
            SmartFillFallbackEvidencePolicy.distribution(from: manifests.map(\.fallbackCategory))
        }

        var forbiddenFallbackDistribution: [String: Int] {
            SmartFillFallbackEvidencePolicy.forbiddenDistribution(from: fallbackDistribution)
        }
    }

    struct SmartFillManifest: Equatable {
        let raw: String
        let rawFields: [String: String]
        let sceneType: String
        let policy: String
        let slotCount: Int
        let fallback: String
        let fallbackCategory: String
        let slotRefs: String
        let rejects: String
        let surfaceKey: String
        let surfaceProfile: String
        let surfaceOrientation: String
        let slotFrames: String
        let layoutVariant: String
        let ratioPreset: String
        let cropRetention: String
        let protectionContained: String
        let candidateWindowUsed: Int
        let evaluationCount: Int
        let rotationStartLayoutVariant: String
        let rotationStartRatioPreset: String
        let acceptedLayoutVariant: String
        let acceptedRatioPreset: String
        let rotationKeyHashPrefix: String
        let rejectedLayoutReasonTopList: String
    }

    struct MotionFrameEvidenceRow {
        let sampleIndex: Int
        let elapsedSeconds: Double
        let probeIdentifier: String
        let fields: [String: String]
        let manifestSlotRefs: String
        let manifestSceneType: String
    }

    struct ProductSceneSequenceRow {
        let sampleIndex: Int
        let elapsedSeconds: Double
        let manifestSlotRefs: String
        let manifestSceneType: String
        let productTransitionFields: [String: String]
    }

    struct MotionRuntimeEvidenceSample {
        let motionRows: [MotionFrameEvidenceRow]
        let productRows: [ProductSceneSequenceRow]
    }

    func launchConfiguredAppAtModeSelection(
        selectionJSON: String? = nil,
        forceAutoplayOff: Bool = true,
        enableSmartFillMotionTrace: Bool = false
    ) throws -> XCUIApplication {
        let config = try requireTestServerConfig()
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        if forceAutoplayOff {
            app.launchEnvironment["UI_TEST_FORCE_AUTOPLAY_OFF"] = "1"
        }
        if enableSmartFillMotionTrace {
            let environment = ProcessInfo.processInfo.environment
            app.launchEnvironment["UI_TEST_COLLECT_SMARTFILL_MOTION_TRACE"] = "1"
            app.launchEnvironment["UI_TEST_SMARTFILL_MOTION_TRACE_DURATION_SECONDS"] =
                environment["TEST_RUNNER_SMARTFILL_MOTION_TRACE_DURATION_SECONDS"] ?? environment[
                    "TEST_RUNNER_SMARTFILL_MOTION_SAMPLE_SECONDS"] ?? environment[
                    "TEST_RUNNER_SMARTFILL_MOTION_INTERACTION_SAMPLE_SECONDS"] ?? "36"
            app.launchEnvironment["UI_TEST_SMARTFILL_MOTION_TRACE_SAMPLE_INTERVAL_SECONDS"] =
                environment["TEST_RUNNER_SMARTFILL_MOTION_TRACE_SAMPLE_INTERVAL_SECONDS"] ?? "0.025"
            app.launchEnvironment["UI_TEST_SMARTFILL_MOTION_TRACE_START_TIMEOUT_SECONDS"] =
                environment["TEST_RUNNER_SMARTFILL_MOTION_TRACE_START_TIMEOUT_SECONDS"] ?? "60"
        }
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        app.launchEnvironment["UI_TEST_SERVER_URL"] = config.url
        app.launchEnvironment["UI_TEST_API_KEY"] = config.apiKey
        SmartFillRuntimeEvidenceSupport.copyAssetIDReplayEnvironment(to: app)
        if let selectionJSON {
            app.launchEnvironment["UI_TEST_SEED_FILTER_SELECTION"] = "1"
            app.launchEnvironment["UI_TEST_FILTER_SELECTION_JSON"] = selectionJSON
        }
        app.launch()

        XCTAssertTrue(
            app.buttons["mode.continue.button"].waitForExistence(timeout: 15),
            "After injecting the test server, Apple TV should go straight to mode selection"
        )
        return app
    }

    func startRandomPlaybackFromModeSelection(app: XCUIApplication) {
        let randomButton = app.buttons["mode.random.button"]
        XCTAssertTrue(
            randomButton.waitForExistence(timeout: 8), "Apple TV mode selection should show the random playback option")
        if randomButton.hasFocus == false {
            XCUIRemote.shared.press(.left)
            RunLoop.current.run(until: Date().addingTimeInterval(0.16))
        }
        XCUIRemote.shared.press(.select)

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: 8), "Continue button should appear after choosing random playback")
        if continueButton.hasFocus == false {
            XCUIRemote.shared.press(.down)
            RunLoop.current.run(until: Date().addingTimeInterval(0.16))
        }
        XCTAssertTrue(continueButton.hasFocus, "In the Apple TV random playback flow, focus should move to Continue")
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(timeout: 30),
            "After starting Apple TV random playback, the playback control bar should appear"
        )
        _ = waitUntil(timeout: 30) {
            guard let manifest = self.currentManifest(app: app) else { return false }
            return manifest.fallback != "image-not-ready"
        }
    }

    func startFilteredPlaybackFromModeSelection(app: XCUIApplication) {
        let filteredButton = app.buttons["mode.filtered.button"]
        XCTAssertTrue(
            filteredButton.waitForExistence(timeout: 8),
            "Apple TV mode selection should show the filtered playback option")
        for _ in 0..<4 {
            if filteredButton.hasFocus { break }
            XCUIRemote.shared.press(.right)
            RunLoop.current.run(until: Date().addingTimeInterval(0.16))
        }
        XCTAssertTrue(
            filteredButton.hasFocus, "Apple TV mode selection focus should move to the filtered playback option")
        XCUIRemote.shared.press(.select)

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: 8),
            "Continue button should appear after choosing filtered playback")
        for _ in 0..<4 {
            if continueButton.hasFocus { break }
            XCUIRemote.shared.press(.down)
            RunLoop.current.run(until: Date().addingTimeInterval(0.16))
        }
        XCTAssertTrue(continueButton.hasFocus, "In the Apple TV filtered playback flow, focus should move to Continue")
        XCUIRemote.shared.press(.select)

        let startButton = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(
            startButton.waitForExistence(timeout: 20), "Apple TV filter summary should show the Start playback button")
        XCTAssertTrue(
            waitUntil(timeout: 20) { startButton.isEnabled },
            "After seeding the people filter, Apple TV Start playback should be enabled")
        for _ in 0..<10 {
            if startButton.hasFocus { break }
            XCUIRemote.shared.press(.down)
            RunLoop.current.run(until: Date().addingTimeInterval(0.16))
        }
        if startButton.hasFocus == false {
            for _ in 0..<10 {
                if startButton.hasFocus { break }
                XCUIRemote.shared.press(.right)
                RunLoop.current.run(until: Date().addingTimeInterval(0.16))
            }
        }
        XCTAssertTrue(startButton.hasFocus, "Apple TV filter summary focus should move to Start playback")
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(timeout: 45),
            "After starting Apple TV people-filter playback, the playback control bar should appear"
        )
        _ = waitUntil(timeout: 30) {
            guard let manifest = self.currentManifest(app: app) else { return false }
            return manifest.fallback != "image-not-ready"
        }
    }

    func collectMotionRuntimeEvidence(
        app: XCUIApplication,
        scenario: String,
        duration: TimeInterval,
        interval: TimeInterval,
        performAction: ((Double) -> Void)? = nil
    ) -> MotionRuntimeEvidenceSample {
        var motionRows: [MotionFrameEvidenceRow] = []
        var productRows: [ProductSceneSequenceRow] = []
        let startedAt = ProcessInfo.processInfo.systemUptime
        var sampleIndex = 0

        while ProcessInfo.processInfo.systemUptime - startedAt < duration {
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            performAction?(elapsed)
            if let manifest = currentManifest(app: app) {
                motionRows.append(
                    contentsOf: currentMotionFrameRows(
                        app: app,
                        sampleIndex: sampleIndex,
                        elapsedSeconds: elapsed,
                        manifest: manifest
                    ))
                productRows.append(
                    ProductSceneSequenceRow(
                        sampleIndex: sampleIndex,
                        elapsedSeconds: elapsed,
                        manifestSlotRefs: manifest.slotRefs,
                        manifestSceneType: manifest.sceneType,
                        productTransitionFields: currentProductTransitionFields(app: app) ?? [:]
                    ))
            }
            sampleIndex += 1
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
        }

        let attachment = XCTAttachment(
            string: "scenario=\(scenario);motionRows=\(motionRows.count);productRows=\(productRows.count)")
        attachment.name = "smartfill-\(scenario)-appletv-motion-runtime-summary"
        attachment.lifetime = .keepAlways
        add(attachment)
        return MotionRuntimeEvidenceSample(motionRows: motionRows, productRows: productRows)
    }

    func currentMotionFrameRows(
        app: XCUIApplication,
        sampleIndex: Int,
        elapsedSeconds: Double,
        manifest: SmartFillManifest
    ) -> [MotionFrameEvidenceRow] {
        let summaryProbe = app.otherElements["slideshow.smartfill.motionFrame.summary"]
        if summaryProbe.exists {
            return summaryProbe.label
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { rawLine -> MotionFrameEvidenceRow? in
                    let fields = parseSemicolonFields(String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines))
                    guard fields["eventType"] == "motionFrame" else { return nil }
                    let identifier = [
                        "slideshow.smartfill.motionFrame.summary",
                        fields["renderRole"] ?? "unknown",
                        fields["slotId"] ?? "unknown"
                    ].joined(separator: ".")
                    return MotionFrameEvidenceRow(
                        sampleIndex: sampleIndex,
                        elapsedSeconds: elapsedSeconds,
                        probeIdentifier: identifier,
                        fields: fields,
                        manifestSlotRefs: manifest.slotRefs,
                        manifestSceneType: fields["manifestSceneType"] ?? manifest.sceneType
                    )
                }
        }

        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "slideshow.smartfill.motionFrame.")
        let elements = app.descendants(matching: .any)
            .matching(predicate)
            .allElementsBoundByIndex
        return elements.compactMap { element in
            guard element.exists else { return nil }
            let fields = parseSemicolonFields(element.label.trimmingCharacters(in: .whitespacesAndNewlines))
            guard fields["eventType"] == "motionFrame" else { return nil }
            return MotionFrameEvidenceRow(
                sampleIndex: sampleIndex,
                elapsedSeconds: elapsedSeconds,
                probeIdentifier: element.identifier,
                fields: fields,
                manifestSlotRefs: manifest.slotRefs,
                manifestSceneType: fields["manifestSceneType"] ?? manifest.sceneType
            )
        }
    }

    func currentProductTransitionFields(app: XCUIApplication) -> [String: String]? {
        let probe = app.otherElements["slideshow.smartfill.productTransition.summary"]
        guard probe.exists else { return nil }
        let fields = parseSemicolonFields(probe.label.trimmingCharacters(in: .whitespacesAndNewlines))
        guard fields["eventType"] == "productTransition" else { return nil }
        return fields
    }

    func appSmartFillMotionTraceText(
        app: XCUIApplication,
        timeout: TimeInterval
    ) throws -> String {
        let statusProbe = app.otherElements["slideshow.smartfill.motionFrame.trace.status"]
        let quietWait = min(timeout, smartFillMotionTraceDurationSeconds() + 5)
        RunLoop.current.run(until: Date().addingTimeInterval(quietWait))
        let isCompleteAfterQuietWait = statusProbe.exists && statusProbe.label.contains("status=complete")
        let remainingTimeout = max(0, timeout - quietWait)
        let completed =
            isCompleteAfterQuietWait
            || waitUntil(timeout: remainingTimeout) {
                statusProbe.exists && statusProbe.label.contains("status=complete")
            }
        XCTAssertTrue(
            completed, "in-app motion trace must complete, status=\(statusProbe.exists ? statusProbe.label : "missing")"
        )
        guard completed else { return "" }

        let statusFields = parseSemicolonFields(statusProbe.label)
        if let tracePath = statusFields["tracePath"],
            !tracePath.isEmpty,
            tracePath != "missing",
            tracePath != "write-failed",
            let traceText = try? String(contentsOfFile: tracePath, encoding: .utf8)
        {
            return traceText
        }

        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "slideshow.smartfill.motionFrame.trace.chunk.")
        let chunks = app.descendants(matching: .any)
            .matching(predicate)
            .allElementsBoundByIndex
            .sorted { lhs, rhs in
                traceChunkIndex(lhs.identifier) < traceChunkIndex(rhs.identifier)
            }
        return chunks.map(\.label).joined(separator: "\n")
    }

    func waitForSmartFillMotionTraceCollecting(
        app: XCUIApplication,
        timeout: TimeInterval
    ) throws -> TimeInterval {
        let statusProbe = app.otherElements["slideshow.smartfill.motionFrame.trace.status"]
        let completed = waitUntil(timeout: timeout) {
            guard statusProbe.exists else { return false }
            let statusFields = parseSemicolonFields(statusProbe.label)
            guard statusProbe.label.contains("status=collecting") || statusProbe.label.contains("status=complete")
            else {
                return false
            }
            return Double(statusFields["collectionStartedUptimeSeconds"] ?? "0") ?? 0 > 0
        }
        XCTAssertTrue(
            completed,
            "in-app motion trace must start collecting, status=\(statusProbe.exists ? statusProbe.label : "missing")")
        if statusProbe.exists, statusProbe.label.contains("status=complete") {
            XCTFail(
                "motion trace finished before the interaction; increase the motion trace capture budget or start the interaction sooner"
            )
            throw SmartFillTVOSFailure.motionTraceFinishedBeforeInteraction
        }
        let statusFields = statusProbe.exists ? parseSemicolonFields(statusProbe.label) : [:]
        let startedAt = Double(statusFields["collectionStartedUptimeSeconds"] ?? "0") ?? 0
        XCTAssertGreaterThan(
            startedAt, 0,
            "motion trace status must expose collectionStartedUptimeSeconds as the time anchor for interaction evidence"
        )
        return startedAt
    }

    func traceChunkIndex(_ identifier: String) -> Int {
        Int(identifier.split(separator: ".").last ?? "") ?? 0
    }

    func motionFrameRows(
        fromTraceText traceText: String,
        fallbackManifest: SmartFillManifest
    ) -> [MotionFrameEvidenceRow] {
        traceText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { rawLine -> MotionFrameEvidenceRow? in
                let fields = parseSemicolonFields(String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines))
                guard fields["eventType"] == "motionFrame" else { return nil }
                guard let rawSampleIndex = fields["sampleIndex"],
                    let sampleIndex = Int(rawSampleIndex),
                    let rawElapsed = fields["elapsedSeconds"],
                    let elapsedSeconds = Double(rawElapsed)
                else {
                    return nil
                }
                let identifier = [
                    "slideshow.smartfill.motionFrame.trace",
                    fields["renderRole"] ?? "unknown",
                    fields["slotId"] ?? "unknown"
                ].joined(separator: ".")
                return MotionFrameEvidenceRow(
                    sampleIndex: sampleIndex,
                    elapsedSeconds: elapsedSeconds,
                    probeIdentifier: identifier,
                    fields: fields,
                    manifestSlotRefs: (fields["manifestSlotRefs"] ?? fallbackManifest.slotRefs)
                        .replacingOccurrences(of: "|", with: ","),
                    manifestSceneType: fields["manifestSceneType"] ?? fallbackManifest.sceneType
                )
            }
    }

    func productSceneSequenceRows(
        fromTraceText traceText: String,
        fallbackManifest: SmartFillManifest
    ) -> [ProductSceneSequenceRow] {
        traceText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { rawLine -> ProductSceneSequenceRow? in
                let fields = parseSemicolonFields(String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines))
                guard fields["eventType"] == "productSceneSequence" else { return nil }
                guard let rawSampleIndex = fields["sampleIndex"],
                    let sampleIndex = Int(rawSampleIndex),
                    let rawElapsed = fields["elapsedSeconds"],
                    let elapsedSeconds = Double(rawElapsed)
                else {
                    return nil
                }
                return ProductSceneSequenceRow(
                    sampleIndex: sampleIndex,
                    elapsedSeconds: elapsedSeconds,
                    manifestSlotRefs: (fields["slotRefs"] ?? fallbackManifest.slotRefs)
                        .replacingOccurrences(of: "|", with: ","),
                    manifestSceneType: fields["sceneType"] ?? fallbackManifest.sceneType,
                    productTransitionFields: fields
                )
            }
    }

    func recordInteractionAction(_ action: String, elapsed: Double, actions: inout [[String: Any]]) {
        guard !actions.containsAction(action) else { return }
        actions.append([
            "action": action,
            "elapsedSeconds": elapsed,
            "timestamp": SmartFillRuntimeEvidenceSupport.captureTimestamp()
        ])
    }

    func parseSemicolonFields(_ raw: String) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: raw.split(separator: ";").compactMap { part -> (String, String)? in
                guard let equalIndex = part.firstIndex(of: "=") else { return nil }
                return (
                    String(part[..<equalIndex]),
                    String(part[part.index(after: equalIndex)...])
                )
            })
    }

    func smartFillMotionScenarioName(defaultScenario: String) -> String {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["TEST_RUNNER_SMARTFILL_MOTION_SCENARIO"], !override.isEmpty {
            return override
        }
        if let override = environment["SMARTFILL_MOTION_SCENARIO"], !override.isEmpty {
            return override
        }
        return defaultScenario
    }

    func smartFillMotionSampleDurationSeconds() -> TimeInterval {
        let environment = ProcessInfo.processInfo.environment
        let rawValue =
            environment["TEST_RUNNER_SMARTFILL_MOTION_SAMPLE_SECONDS"] ?? environment["SMARTFILL_MOTION_SAMPLE_SECONDS"]
        guard let rawValue,
            let value = TimeInterval(rawValue),
            value > 0
        else {
            return 60
        }
        return value
    }

    func smartFillMotionTraceDurationSeconds() -> TimeInterval {
        let environment = ProcessInfo.processInfo.environment
        let rawValue =
            environment["TEST_RUNNER_SMARTFILL_MOTION_TRACE_DURATION_SECONDS"] ?? environment[
                "TEST_RUNNER_SMARTFILL_MOTION_SAMPLE_SECONDS"] ?? environment[
                "TEST_RUNNER_SMARTFILL_MOTION_INTERACTION_SAMPLE_SECONDS"] ?? environment[
                "SMARTFILL_MOTION_TRACE_DURATION_SECONDS"] ?? environment["SMARTFILL_MOTION_SAMPLE_SECONDS"]
        guard let rawValue,
            let value = TimeInterval(rawValue),
            value > 0
        else {
            return 36
        }
        return value
    }

    func smartFillMotionInteractionSampleDurationSeconds() -> TimeInterval {
        let environment = ProcessInfo.processInfo.environment
        let rawValue =
            environment["TEST_RUNNER_SMARTFILL_MOTION_INTERACTION_SAMPLE_SECONDS"]
            ?? environment["SMARTFILL_MOTION_INTERACTION_SAMPLE_SECONDS"]
        guard let rawValue,
            let value = TimeInterval(rawValue),
            value > 0
        else {
            return 22
        }
        return value
    }

    func smartFillMotionSampleIntervalSeconds() -> TimeInterval {
        let environment = ProcessInfo.processInfo.environment
        let rawValue =
            environment["TEST_RUNNER_SMARTFILL_MOTION_SAMPLE_INTERVAL_SECONDS"]
            ?? environment["SMARTFILL_MOTION_SAMPLE_INTERVAL_SECONDS"]
        guard let rawValue,
            let value = TimeInterval(rawValue),
            value > 0
        else {
            return 0.10
        }
        return min(max(value, 0.05), 0.25)
    }

    func collectTwentySceneEvidence(app: XCUIApplication, scenario: String) throws -> SmartFillEvidence {
        var manifests: [SmartFillManifest] = []
        var runtimeRecords: [[String: Any]] = []
        var attachedSceneTypes = Set<String>()
        var attachedScreenshotCount = 0
        let harnessStartMs = SmartFillRuntimeEvidenceSupport.harnessTimestampMilliseconds()
        var firstManifestObservedMs: Double?
        var firstNonLoadingScreenshotCapturedMs: Double?
        let targetSceneCount = smartFillTargetSceneCount()
        let samplingScreenshotIndices = screenshotSampleIndices(for: targetSceneCount)

        for index in 0..<targetSceneCount {
            var manifest = try waitForCurrentManifest(app: app, timeout: index == 0 ? 45 : 25)
            if index == 0,
                shouldWaitForCompleteStartupRuntimePhases()
            {
                manifest = try waitForCompleteStartupRuntimeManifest(
                    app: app,
                    initialManifest: manifest,
                    timeout: 30
                )
            }
            manifest = try waitForScreenshotReadyManifest(
                app: app,
                initialManifest: manifest,
                timeout: 30,
                scenario: scenario,
                index: index
            )
            if firstManifestObservedMs == nil {
                firstManifestObservedMs =
                    SmartFillRuntimeEvidenceSupport.harnessTimestampMilliseconds() - harnessStartMs
            }
            assertManifestIsRedacted(manifest.raw)
            assertManifestMeetsSpecGates(manifest, scenario: scenario, index: index)
            manifests.append(manifest)

            let sequence = index + 1
            let sceneIdHash = SmartFillRuntimeEvidenceSupport.sceneIdHash(
                rawManifest: manifest.raw,
                scenario: scenario,
                sequence: sequence
            )
            let shouldAttach =
                index == 0 || index == targetSceneCount - 1 || attachedSceneTypes.insert(manifest.sceneType).inserted
                || samplingScreenshotIndices.contains(index)
            if let screenshot = captureRuntimeScreenshot(
                app: app,
                name: "smartfill-\(scenario)-appletv-seq-\(sequence)-\(sceneIdHash)-\(manifest.sceneType)",
                attachToXCTest: shouldAttach
            ) {
                if firstNonLoadingScreenshotCapturedMs == nil {
                    firstNonLoadingScreenshotCapturedMs =
                        SmartFillRuntimeEvidenceSupport.harnessTimestampMilliseconds() - harnessStartMs
                }
                runtimeRecords.append(
                    SmartFillRuntimeEvidenceSupport.makeRecord(
                        manifestFields: manifest.rawFields,
                        rawManifest: manifest.raw,
                        scenario: scenario,
                        deviceTag: "appletv",
                        sequence: sequence,
                        sceneIdHash: sceneIdHash,
                        screenshotPath: screenshot.path,
                        captureTimestamp: screenshot.captureTimestamp
                    )
                )
            }
            if shouldAttach {
                attachedScreenshotCount += 1
            }

            guard index < targetSceneCount - 1 else { continue }
            let previousRefs = manifest.slotRefs
            pressNext(app: app)
            _ = waitUntil(timeout: 25) {
                guard let nextManifest = self.currentManifest(app: app) else { return false }
                return nextManifest.slotRefs != previousRefs
            }
        }

        attachManifestSummary(manifests, scenario: scenario)
        let harnessSummary = makeHarnessSummary(
            runtimeRecords: runtimeRecords,
            firstManifestObservedMs: firstManifestObservedMs,
            firstNonLoadingScreenshotCapturedMs: firstNonLoadingScreenshotCapturedMs
        )
        writeManifestEvidence(
            manifests,
            runtimeRecords: runtimeRecords,
            harnessSummary: harnessSummary,
            scenario: scenario
        )
        XCTAssertEqual(
            manifests.count, targetSceneCount, "\(scenario) should capture the target number of Smart Fill manifests")
        if targetSceneCount >= 60 {
            XCTAssertGreaterThanOrEqual(
                attachedScreenshotCount, 10, "\(scenario) a 60-scene sample should keep at least 10 screenshots")
        }
        if targetSceneCount > 1 {
            XCTAssertGreaterThan(
                Set(manifests.map(\.slotRefs)).count,
                1,
                "\(scenario) consecutive samples should show at least one change in redacted slot references"
            )
        }
        return SmartFillEvidence(manifests: manifests)
    }

    func pressNext(app: XCUIApplication) {
        let nextButton = app.buttons["slideshow.control.next.button"]
        if !nextButton.exists {
            XCUIRemote.shared.press(.up)
            RunLoop.current.run(until: Date().addingTimeInterval(0.16))
        }
        XCTAssertTrue(nextButton.waitForExistence(timeout: 6), "Apple TV playback page should show the Next button")

        for _ in 0..<6 {
            if nextButton.hasFocus { break }
            XCUIRemote.shared.press(.right)
            RunLoop.current.run(until: Date().addingTimeInterval(0.16))
        }
        if nextButton.hasFocus == false {
            for _ in 0..<6 {
                if nextButton.hasFocus { break }
                XCUIRemote.shared.press(.left)
                RunLoop.current.run(until: Date().addingTimeInterval(0.16))
            }
        }

        XCTAssertTrue(nextButton.hasFocus, "Apple TV playback page focus should move to the Next button")
        XCUIRemote.shared.press(.select)
    }

    func waitForCurrentManifest(app: XCUIApplication, timeout: TimeInterval) throws -> SmartFillManifest {
        guard waitUntil(timeout: timeout, condition: { self.currentManifest(app: app) != nil }) else {
            attachScreenshot(app: app, name: "smartfill-manifest-missing-appletv")
            throw SmartFillTVOSFailure.missingManifest
        }
        guard let manifest = currentManifest(app: app) else {
            throw SmartFillTVOSFailure.missingManifest
        }
        return manifest
    }

    func waitForCompleteStartupRuntimeManifest(
        app: XCUIApplication,
        initialManifest: SmartFillManifest,
        timeout: TimeInterval
    ) throws -> SmartFillManifest {
        var latestManifest = initialManifest
        _ = waitUntil(timeout: timeout) {
            guard let nextManifest = self.currentManifest(app: app) else { return false }
            latestManifest = nextManifest
            return self.hasCompleteStartupRuntimePhases(nextManifest)
        }
        XCTAssertTrue(
            hasCompleteStartupRuntimePhases(latestManifest),
            "Minimal runtime JSONL requires the first-frame manifest to include all startup runtime phases"
        )
        return latestManifest
    }

    func waitForScreenshotReadyManifest(
        app: XCUIApplication,
        initialManifest: SmartFillManifest,
        timeout: TimeInterval,
        scenario: String,
        index: Int
    ) throws -> SmartFillManifest {
        var latestManifest = initialManifest
        _ = waitUntil(timeout: timeout) {
            guard let nextManifest = self.currentManifest(app: app) else { return false }
            latestManifest = nextManifest
            return SmartFillRuntimeEvidenceSupport.isReadyForScreenshotEvidence(
                manifestFields: nextManifest.rawFields
            )
        }
        XCTAssertTrue(
            SmartFillRuntimeEvidenceSupport.isReadyForScreenshotEvidence(manifestFields: latestManifest.rawFields),
            "\(scenario) frame \(index + 1) must wait for images to be ready before the screenshot, current state: \(SmartFillRuntimeEvidenceSupport.screenshotEvidenceReadinessReason(manifestFields: latestManifest.rawFields))"
        )
        return latestManifest
    }

    func hasCompleteStartupRuntimePhases(_ manifest: SmartFillManifest) -> Bool {
        guard let timestamps = manifest.rawFields["runtimePhaseTimestampsMs"],
            let durations = manifest.rawFields["runtimePhaseDurationsMs"]
        else {
            return false
        }
        return SmartFillRuntimeEvidenceSupport.requiredRuntimePhaseKeys.allSatisfy { phase in
            timestamps.contains("\(phase):") && durations.contains("\(phase):")
        }
    }

    func currentManifest(app: XCUIApplication) -> SmartFillManifest? {
        let probe = app.descendants(matching: .any)["slideshow.smartfill.currentManifest.flag"]
        guard probe.exists else { return nil }
        return parseManifest(probe.label.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func parseManifest(_ raw: String) -> SmartFillManifest? {
        guard raw.contains("version=smart-fill-planner-v2") else { return nil }
        let fields = Dictionary(
            uniqueKeysWithValues: raw.split(separator: ";").compactMap { part -> (String, String)? in
                guard let equalIndex = part.firstIndex(of: "=") else { return nil }
                let key = String(part[..<equalIndex])
                let value = String(part[part.index(after: equalIndex)...])
                return (key, value)
            }
        )
        guard SmartFillRuntimeEvidenceSupport.requiredSummaryFields.allSatisfy({ fields[$0] != nil }),
            let sceneType = fields["sceneType"],
            let policy = fields["policy"],
            let rawSlotCount = fields["slotCount"],
            let slotCount = Int(rawSlotCount),
            let fallback = fields["fallback"],
            let fallbackCategory = fields["fallbackCategory"],
            let slotRefs = fields["slotRefs"],
            let rejects = fields["rejects"],
            let surfaceKey = fields["surfaceKey"],
            let surface = parseSurfaceKey(surfaceKey),
            let slotFrames = fields["slotFrames"],
            let layoutVariant = fields["layoutVariant"],
            let ratioPreset = fields["ratioPreset"],
            let cropRetention = fields["cropRetention"],
            let protectionContained = fields["protectionContained"],
            let rawCandidateWindowUsed = fields["candidateWindowUsed"],
            let candidateWindowUsed = Int(rawCandidateWindowUsed),
            let rawEvaluationCount = fields["evaluationCount"],
            let evaluationCount = Int(rawEvaluationCount),
            let rotationStartLayoutVariant = fields["rotationStartLayoutVariant"],
            let rotationStartRatioPreset = fields["rotationStartRatioPreset"],
            let acceptedLayoutVariant = fields["acceptedLayoutVariant"],
            let acceptedRatioPreset = fields["acceptedRatioPreset"],
            let rotationKeyHashPrefix = fields["rotationKeyHashPrefix"],
            let rejectedLayoutReasonTopList = fields["rejectedLayoutReasonTopList"]
        else {
            return nil
        }
        return SmartFillManifest(
            raw: raw,
            rawFields: fields,
            sceneType: sceneType,
            policy: policy,
            slotCount: slotCount,
            fallback: fallback,
            fallbackCategory: fallbackCategory,
            slotRefs: slotRefs,
            rejects: rejects,
            surfaceKey: surfaceKey,
            surfaceProfile: surface.profile,
            surfaceOrientation: surface.orientation,
            slotFrames: slotFrames,
            layoutVariant: layoutVariant,
            ratioPreset: ratioPreset,
            cropRetention: cropRetention,
            protectionContained: protectionContained,
            candidateWindowUsed: candidateWindowUsed,
            evaluationCount: evaluationCount,
            rotationStartLayoutVariant: rotationStartLayoutVariant,
            rotationStartRatioPreset: rotationStartRatioPreset,
            acceptedLayoutVariant: acceptedLayoutVariant,
            acceptedRatioPreset: acceptedRatioPreset,
            rotationKeyHashPrefix: rotationKeyHashPrefix,
            rejectedLayoutReasonTopList: rejectedLayoutReasonTopList
        )
    }

    func parseSurfaceKey(_ raw: String) -> (profile: String, orientation: String)? {
        let parts = raw.split(separator: "-")
        guard parts.count >= 2 else {
            return nil
        }
        return (String(parts[0]), String(parts[1]))
    }

    func assertManifestIsRedacted(_ manifest: String) {
        let lowercased = manifest.lowercased()
        XCTAssertFalse(lowercased.contains("http://"))
        XCTAssertFalse(lowercased.contains("https://"))
        XCTAssertFalse(lowercased.contains("api_key"))
        XCTAssertFalse(lowercased.contains("api key"))
        XCTAssertFalse(lowercased.contains("token"))
        XCTAssertFalse(lowercased.contains("base64"))
    }

    func assertManifestMeetsSpecGates(_ manifest: SmartFillManifest, scenario: String, index: Int) {
        XCTAssertFalse(manifest.layoutVariant.isEmpty, "\(scenario) frame \(index + 1) should record layoutVariant")
        XCTAssertFalse(manifest.ratioPreset.isEmpty, "\(scenario) frame \(index + 1) should record ratioPreset")
        XCTAssertFalse(
            manifest.rotationKeyHashPrefix.isEmpty, "\(scenario) frame \(index + 1) should record rotationKeyHashPrefix"
        )
        XCTAssertGreaterThan(
            manifest.candidateWindowUsed, 0, "\(scenario) frame \(index + 1) should record candidateWindowUsed")
        XCTAssertGreaterThanOrEqual(
            manifest.evaluationCount, 0, "\(scenario) frame \(index + 1) should record evaluationCount")

        guard manifest.sceneType != "fallback" else { return }
        let retentions = manifest.cropRetention
            .split(separator: ",")
            .compactMap { Double($0) }
        XCTAssertEqual(
            retentions.count,
            manifest.slotCount,
            "\(scenario) frame \(index + 1) should record cropRetention for every slot"
        )
        let cropRetentionThreshold = cropRetentionThreshold(for: manifest)
        let thresholdLabel = String(format: "%.0f%%", cropRetentionThreshold * 100)
        XCTAssertTrue(
            retentions.allSatisfy { $0 >= cropRetentionThreshold },
            "\(scenario) frame \(index + 1): cropRetention of every accepted slot should be >= \(thresholdLabel)"
        )
        let protectionValues = manifest.protectionContained.split(separator: ",").map(String.init)
        XCTAssertEqual(
            protectionValues.count,
            manifest.slotCount,
            "\(scenario) frame \(index + 1) should record protectionContained for every slot"
        )
        XCTAssertTrue(
            protectionValues.allSatisfy { $0 == "true" },
            "\(scenario) frame \(index + 1): every accepted slot should fully contain its protected region"
        )
    }

    func cropRetentionThreshold(for manifest: SmartFillManifest) -> Double {
        Double(manifest.rawFields["cropRetentionThresholdUsed"] ?? "") ?? 0.60
    }

    func attachManifestSummary(_ manifests: [SmartFillManifest], scenario: String) {
        let fallbackDistribution = SmartFillFallbackEvidencePolicy.format(
            SmartFillFallbackEvidencePolicy.distribution(from: manifests.map(\.fallbackCategory))
        )
        let summary =
            ([
                "fallbackDistribution=\(fallbackDistribution)"
            ]
            + manifests.enumerated().map { index, manifest in
                [
                    "index=\(index + 1)",
                    "sceneType=\(manifest.sceneType)",
                    "policy=\(manifest.policy)",
                    "layoutVariant=\(manifest.layoutVariant)",
                    "ratioPreset=\(manifest.ratioPreset)",
                    "slotCount=\(manifest.slotCount)",
                    "fallback=\(manifest.fallback)",
                    "fallbackCategory=\(manifest.fallbackCategory)",
                    "rejects=\(manifest.rejects)",
                    "rejectedLayoutReasonTopList=\(manifest.rejectedLayoutReasonTopList)",
                    "surfaceKey=\(manifest.surfaceKey)",
                    "surfaceProfile=\(manifest.surfaceProfile)",
                    "surfaceOrientation=\(manifest.surfaceOrientation)",
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
                    "slotRefs=\(manifest.slotRefs)"
                ].joined(separator: ";")
            }).joined(separator: "\n")
        let attachment = XCTAttachment(string: summary)
        attachment.name = "smartfill-\(scenario)-manifest-appletv"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func assertPolicies(in evidence: SmartFillEvidence, contain expectedFragment: String, scenario: String) {
        XCTAssertTrue(
            evidence.manifests.allSatisfy { $0.policy.contains(expectedFragment) },
            "\(scenario) should read back the \(expectedFragment) policy"
        )
    }

    func assertFallbackDistributionMeetsSpec(in evidence: SmartFillEvidence, scenario: String) {
        let forbiddenDistribution = evidence.forbiddenFallbackDistribution
        XCTAssertTrue(
            forbiddenDistribution.isEmpty,
            "\(scenario) forbidden fallback categories must be 0, forbidden distribution: \(SmartFillFallbackEvidencePolicy.format(forbiddenDistribution)), full distribution: \(SmartFillFallbackEvidencePolicy.format(evidence.fallbackDistribution))"
        )
    }

    func assertSurfacesAreLandscape(in evidence: SmartFillEvidence, scenario: String) {
        XCTAssertTrue(
            evidence.manifests.allSatisfy {
                $0.surfaceOrientation == "landscape" && $0.surfaceProfile == "appleTV"
            },
            "\(scenario) should read back Apple TV landscape Smart Fill surface geometry"
        )
    }

    func makePersonFilterSelectionJSON(personID: String) -> String {
        let object: [String: Any] = [
            "albumIds": [],
            "personFilters": [
                [
                    "personId": personID,
                    "matchMode": "normal"
                ]
            ],
            "tagIds": []
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [])
        return String(data: data, encoding: .utf8)!
    }

    func makeAlbumFilterSelectionJSON(albumID: String) -> String {
        let object: [String: Any] = [
            "albumIds": [albumID],
            "personFilters": [],
            "tagIds": []
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [])
        return String(data: data, encoding: .utf8)!
    }

    func requireFixedAlbumID() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let rawValue =
            environment["IMMICHSLIDES_SMARTFILL_FIXED_ALBUM_ID"]
            ?? environment["TEST_RUNNER_IMMICHSLIDES_SMARTFILL_FIXED_ALBUM_ID"]
        guard let albumID = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !albumID.isEmpty
        else {
            throw XCTSkip("Fixed-album Smart Fill UI acceptance requires IMMICHSLIDES_SMARTFILL_FIXED_ALBUM_ID")
        }
        return albumID
    }

    func findEligiblePersonID(minimumAssetCount: Int) async throws -> String {
        let config = try requireTestServerConfig()
        let baseURL = config.url.hasSuffix("/") ? String(config.url.dropLast()) : config.url
        let peopleObject = try await requestJSON(
            urlString: "\(baseURL)/people?size=100",
            apiKey: config.apiKey
        )
        let people: [[String: Any]]
        if let object = peopleObject as? [String: Any],
            let peopleArray = object["people"] as? [[String: Any]]
        {
            people = peopleArray
        } else if let peopleArray = peopleObject as? [[String: Any]] {
            people = peopleArray
        } else {
            throw XCTSkip(
                "Test server people list response has an unexpected format; cannot run the Apple TV people-filter Smart Fill UI acceptance."
            )
        }

        for person in people {
            guard let personID = person["id"] as? String else { continue }
            let encodedPersonID = personID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? personID
            let statsObject = try await requestJSON(
                urlString: "\(baseURL)/people/\(encodedPersonID)/statistics",
                apiKey: config.apiKey
            )
            let count = (statsObject as? [String: Any])?["assets"] as? Int ?? 0
            if count >= minimumAssetCount {
                return personID
            }
        }

        throw XCTSkip(
            "Test server has no person with at least \(minimumAssetCount) assets; Apple TV people-filter 20-frame acceptance is marked BLOCKED_ENV."
        )
    }

    func requestJSON(urlString: String, apiKey: String) async throws -> Any {
        guard let url = URL(string: urlString) else {
            throw XCTSkip("Cannot build the test server URL.")
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("immichSlides-smartfill-tvos-ui-test", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else {
            throw XCTSkip(
                "Read-only probe of the test server failed; Apple TV people-filter Smart Fill UI acceptance is marked BLOCKED_ENV."
            )
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    func attachScreenshot(app: XCUIApplication, name: String) {
        _ = captureRuntimeScreenshot(app: app, name: name, attachToXCTest: true)
    }

    func captureRuntimeScreenshot(
        app: XCUIApplication,
        name: String,
        attachToXCTest: Bool
    ) -> (path: String, captureTimestamp: String)? {
        let screenshot = app.screenshot()
        if attachToXCTest {
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        guard let directory = evidenceDirectory() else { return nil }
        let captureTimestamp = SmartFillRuntimeEvidenceSupport.captureTimestamp()
        let fileURL = directory.appendingPathComponent(sanitizedEvidenceFileName(name) + ".png")
        guard
            let writtenURL = SmartFillRuntimeEvidenceSupport.writeScreenshotPNG(
                screenshot.pngRepresentation,
                to: fileURL
            )
        else {
            XCTFail("SmartFill runtime PNG write or read-back failed: \(fileURL.lastPathComponent)")
            return nil
        }
        return (writtenURL.path, captureTimestamp)
    }

    func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    func smartFillTargetSceneCount() -> Int {
        let environment = ProcessInfo.processInfo.environment
        let rawValue =
            environment["IMMICHSLIDES_SMARTFILL_SCENE_COUNT"]
            ?? environment["TEST_RUNNER_IMMICHSLIDES_SMARTFILL_SCENE_COUNT"]
        guard let rawValue,
            let count = Int(rawValue),
            count > 0
        else {
            return 20
        }
        return count
    }

    func shouldWaitForCompleteStartupRuntimePhases() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["IMMICHSLIDES_REQUIRE_STARTUP_PHASES"] == "1"
            || environment["TEST_RUNNER_IMMICHSLIDES_REQUIRE_STARTUP_PHASES"] == "1"
    }

    func screenshotSampleIndices(for sceneCount: Int) -> Set<Int> {
        guard sceneCount >= 10 else {
            return Set(0..<sceneCount)
        }
        return Set(
            (0..<10).map { sampleIndex in
                Int((Double(sampleIndex) * Double(sceneCount - 1) / 9.0).rounded())
            })
    }

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
            sanitizedEvidenceFileName("smartfill-\(scenario)-appletv-manifest") + ".txt"
        )
        requireEvidenceWrite {
            try summary.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        guard !runtimeRecords.isEmpty else { return }
        let jsonlURL = directory.appendingPathComponent(
            sanitizedEvidenceFileName("smartfill-\(scenario)-appletv-runtime") + ".jsonl"
        )
        requireEvidenceWrite {
            try SmartFillRuntimeEvidenceSupport.writeJSONLines(runtimeRecords, to: jsonlURL)
        }
        let summaryURL = directory.appendingPathComponent(
            sanitizedEvidenceFileName("smartfill-\(scenario)-appletv-runtime-summary") + ".txt"
        )
        requireEvidenceWrite {
            try SmartFillRuntimeEvidenceSupport.summaryLines(for: runtimeRecords)
                .write(to: summaryURL, atomically: true, encoding: .utf8)
        }
        if let observedLockText = SmartFillRuntimeEvidenceSupport.scenarioManifestObservationLockText(
            records: runtimeRecords,
            scenario: scenario,
            deviceTag: "appletv"
        ) {
            let lockURL = directory.appendingPathComponent(
                sanitizedEvidenceFileName("smartfill-\(scenario)-appletv-scenario-manifest-observed") + ".lock"
            )
            requireEvidenceWrite {
                try observedLockText.write(to: lockURL, atomically: true, encoding: .utf8)
            }
        }
        if let harnessSummary {
            let harnessURL = directory.appendingPathComponent(
                sanitizedEvidenceFileName("smartfill-\(scenario)-appletv-harness-summary") + ".json"
            )
            requireEvidenceWrite {
                try SmartFillRuntimeEvidenceSupport.writeJSONObject(harnessSummary, to: harnessURL)
            }
        }
    }

    func writeMotionFrameEvidence(_ rows: [MotionFrameEvidenceRow], scenario: String) {
        rows.forEach { SmartFillRuntimeEvidenceSupport.assertRedactedSeedSummary($0.fields) }
        guard let directory = motionEvidenceDirectory() else { return }
        let baseName = sanitizedEvidenceFileName("smartfill-\(scenario)-appletv-motion-frames")
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
        scenario: String,
        sampleDuration: TimeInterval
    ) {
        for row in rows {
            let refs = row.manifestSlotRefs.split(separator: ",")
            XCTAssertFalse(refs.isEmpty)
            XCTAssertTrue(refs.allSatisfy { $0.range(of: "^asset-[0-9a-f]{16}$", options: .regularExpression) != nil })
            if let motionRow = motionRows.first(where: {
                $0.sampleIndex == row.sampleIndex
                    && $0.fields["sceneId"] == row.productTransitionFields["sceneId"]
            }) {
                XCTAssertEqual(row.manifestSlotRefs, motionRow.manifestSlotRefs)
            }
        }
        guard let directory = motionEvidenceDirectory() else { return }
        let dictionaries = rows.map(productSceneSequenceDictionary)
        let transitionDictionaries = dictionaries.filter { dictionary in
            dictionary["productTransitionActive"] as? String == "true"
        }
        let countsBySceneType = Dictionary(grouping: rows, by: \.manifestSceneType)
            .mapValues(\.count)
        let motionSupportedSceneTypes = ["double", "triple", "single"]
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
        let motionCoveredSceneTypes = cleanAvailableMotionSceneTypes
        let visibleUncoveredMotionSceneTypes = Set(rows.map(\.manifestSceneType))
            .subtracting(Set(motionCoveredSceneTypes))
            .sorted()
        let motionUnverifiedSupportedSceneTypes = Set(motionSupportedSceneTypes)
            .subtracting(Set(motionCoveredSceneTypes))
            .sorted()
        let motionCoverageVerdict = motionUnverifiedSupportedSceneTypes.isEmpty ? "PASS" : "PARTIAL"
        let manifest: [String: Any] = [
            "schemaVersion": "apple-tv-smartfill-motion-product-scope-evidence-v1",
            "scenario": scenario,
            "deviceTag": "appletv",
            "deviceRequirement": "Apple TV",
            "configuredIntervalSeconds": 5.0,
            "requestedSampleDurationSeconds": sampleDuration,
            "productScope": [
                "source": "full-product-continuous",
                "cleanAcceptedOnlyClaimAllowed": false,
                "motionSupportedSceneTypes": motionSupportedSceneTypes,
                "motionCoveredSceneTypes": motionCoveredSceneTypes,
                "motionUnverifiedSupportedSceneTypes": motionUnverifiedSupportedSceneTypes,
                "motionCoverageVerdict": motionCoverageVerdict,
                "motionScopeExpandedToSingle": true,
                "motionScopeExpandedToFallback": false,
                "motionScopeExpandedToLegacy": false,
                "known_out_of_scope_visual_gap": !visibleUncoveredMotionSceneTypes.isEmpty,
                "visibleUncoveredMotionSceneTypes": visibleUncoveredMotionSceneTypes,
                "cleanAvailableMotionSceneTypes": cleanAvailableMotionSceneTypes
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
            "schemaVersion": "apple-tv-smartfill-motion-scene-sequence-v1",
            "scenario": scenario,
            "deviceTag": "appletv",
            "deviceRequirement": "Apple TV",
            "configuredIntervalSeconds": 5.0,
            "requestedSampleDurationSeconds": sampleDuration,
            "countsBySceneType": countsBySceneType,
            "rowCount": rows.count,
            "transitionActiveRowCount": transitionDictionaries.count,
            "rows": dictionaries
        ]
        let productTransitionProbes: [String: Any] = [
            "schemaVersion": "apple-tv-smartfill-motion-transition-probes-v1",
            "scenario": scenario,
            "deviceTag": "appletv",
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

    func writeInteractionActionEvidence(_ actions: [[String: Any]], scenario: String) {
        guard let directory = motionEvidenceDirectory() else { return }
        let payload: [String: Any] = [
            "schemaVersion": "apple-tv-smartfill-motion-interaction-actions-v1",
            "scenario": scenario,
            "deviceTag": "appletv",
            "actions": actions
        ]
        requireEvidenceWrite {
            try SmartFillRuntimeEvidenceSupport.writeJSONObject(
                payload,
                to: directory.appendingPathComponent("user-actions.json")
            )
        }
        requireEvidenceWrite {
            try interactionActionCSV(actions)
                .write(to: directory.appendingPathComponent("user-actions.csv"), atomically: true, encoding: .utf8)
        }
    }

    func productSceneSequenceDictionary(_ row: ProductSceneSequenceRow) -> [String: Any] {
        let endpoints = productTransitionEndpointSceneTypes(row.productTransitionFields)
        var object: [String: Any] = [
            "sampleIndex": row.sampleIndex,
            "elapsedSeconds": row.elapsedSeconds,
            "manifestSlotRefs": row.manifestSlotRefs,
            "manifestSceneType": row.manifestSceneType,
            "productTransitionActive": row.productTransitionFields["productTransitionActive"] ?? "missing",
            "acceptedMotionTransitionActive": row.productTransitionFields["acceptedMotionTransitionActive"]
                ?? "missing",
            "productBlackBackingActive": row.productTransitionFields["productBlackBackingActive"]
                ?? row.productTransitionFields["blackBackingActive"] ?? "missing",
            "transitionFromSceneType": endpoints.from,
            "transitionToSceneType": endpoints.to,
            "transitionLayerRoles": row.productTransitionFields["transitionLayerRoles"] ?? "missing",
            "transitionLayerSceneTypes": row.productTransitionFields["transitionLayerSceneTypes"] ?? "missing",
            "transitionLayerScopes": row.productTransitionFields["transitionLayerScopes"] ?? "missing"
        ]
        for (key, value) in row.productTransitionFields {
            object[key] = value
        }
        return object
    }

    func productSceneSequenceCSV(_ rows: [ProductSceneSequenceRow]) -> String {
        let columns = [
            "sampleIndex",
            "elapsedSeconds",
            "manifestSlotRefs",
            "manifestSceneType",
            "productTransitionActive",
            "acceptedMotionTransitionActive",
            "productBlackBackingActive",
            "transitionFromSceneType",
            "transitionToSceneType",
            "transitionLayerRoles",
            "transitionLayerSceneTypes",
            "transitionLayerScopes"
        ]
        let body = rows.map { row in
            let dictionary = productSceneSequenceDictionary(row)
            return columns.map { column in
                switch column {
                case "sampleIndex":
                    return "\(row.sampleIndex)"
                case "elapsedSeconds":
                    return String(format: "%.6f", row.elapsedSeconds)
                default:
                    return csvEscaped("\(dictionary[column] ?? "")")
                }
            }.joined(separator: ",")
        }.joined(separator: "\n")
        return ([columns.joined(separator: ",")] + [body]).joined(separator: "\n")
    }

    func productTransitionEndpointSceneTypes(_ fields: [String: String]) -> (from: String, to: String) {
        let roles =
            fields["transitionLayerRoles"]?
            .split(separator: "|")
            .map(String.init) ?? []
        let sceneTypes =
            fields["transitionLayerSceneTypes"]?
            .split(separator: "|")
            .map(String.init) ?? []
        var from = "none"
        var to = "none"
        for (index, role) in roles.enumerated() where sceneTypes.indices.contains(index) {
            if role == "outgoing" {
                from = sceneTypes[index]
            }
            if role == "incoming" {
                to = sceneTypes[index]
            }
        }
        return (from, to)
    }

    func motionFrameDictionary(_ row: MotionFrameEvidenceRow) -> [String: Any] {
        var object: [String: Any] = [
            "sampleIndex": row.sampleIndex,
            "elapsedSeconds": row.elapsedSeconds,
            "probeIdentifier": row.probeIdentifier,
            "manifestSlotRefs": row.manifestSlotRefs,
            "manifestSceneType": row.manifestSceneType
        ]
        for (key, value) in row.fields {
            object[key] = value
        }
        return object
    }

    func motionFrameCSV(_ rows: [MotionFrameEvidenceRow]) -> String {
        let columns = [
            "sampleIndex", "elapsedSeconds", "probeIdentifier", "sceneId", "slotId", "assetId",
            "renderRole", "controlBarVisible", "appOverlayPollution", "acceptedMotionScope",
            "singleFilledScope", "progressFrameStatus", "clockGeneration", "progress",
            "progressSource", "presentationProgressSource", "visualFrameSource",
            "presentationModelDivergenceStatus", "isDiscontinuous", "extensionReason",
            "timelineStartTime", "stableVisibleStartTime", "handoffStartDeadlineTime",
            "removalDeadlineTime", "stableVisibleDuration", "transitionCompletionDelay",
            "scale", "translationX", "translationY", "renderedFrameMinX", "renderedFrameMinY",
            "renderedFrameWidth", "renderedFrameHeight", "presentationFrameMinX",
            "presentationFrameMinY", "presentationFrameWidth", "presentationFrameHeight",
            "modelFrameMinX", "modelFrameMinY", "modelFrameWidth", "modelFrameHeight",
            "anchorX", "anchorY", "focalSourceKind", "focalProvenance", "zoomDirection",
            "stableSeedHash", "seedInputSummary", "requestedTranslationX", "requestedTranslationY",
            "clampedTranslationX", "clampedTranslationY", "endTranslationX", "endTranslationY",
            "phaseAction", "isIdentity", "manifestSlotRefs", "manifestSceneType"
        ]
        let body = rows.map { row in
            columns.map { column in
                switch column {
                case "sampleIndex":
                    return "\(row.sampleIndex)"
                case "elapsedSeconds":
                    return String(format: "%.6f", row.elapsedSeconds)
                case "probeIdentifier":
                    return csvEscaped(row.probeIdentifier)
                case "manifestSlotRefs":
                    return csvEscaped(row.manifestSlotRefs)
                case "manifestSceneType":
                    return csvEscaped(row.manifestSceneType)
                default:
                    return csvEscaped(row.fields[column] ?? "")
                }
            }.joined(separator: ",")
        }.joined(separator: "\n")
        return ([columns.joined(separator: ",")] + [body]).joined(separator: "\n")
    }

    func interactionActionCSV(_ actions: [[String: Any]]) -> String {
        let columns = ["action", "elapsedSeconds", "timestamp"]
        let body = actions.map { action in
            columns.map { column in
                if column == "elapsedSeconds", let value = action[column] as? Double {
                    return String(format: "%.6f", value)
                }
                return csvEscaped("\(action[column] ?? "")")
            }.joined(separator: ",")
        }.joined(separator: "\n")
        return ([columns.joined(separator: ",")] + [body]).joined(separator: "\n")
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
            appLaunchStartMs: 0,
            testServerConfigInjectedMs: 0,
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
                components: ["ui-runtime", "appletv"]
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

    func csvEscaped(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    func sanitizedEvidenceFileName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return raw.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
    }

    enum SmartFillTVOSFailure: Error {
        case missingManifest
        case motionTraceFinishedBeforeInteraction
    }
}

private extension Array where Element == Dictionary<String, Any> {
    func containsAction(_ name: String) -> Bool {
        contains { $0["action"] as? String == name }
    }
}
#endif
