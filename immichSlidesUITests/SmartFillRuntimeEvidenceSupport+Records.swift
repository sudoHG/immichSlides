import Foundation
import XCTest

extension SmartFillRuntimeEvidenceSupport {
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
            "cropRetentionThresholdUsed": doubleValue(
                "cropRetentionThresholdUsed", in: fields, default: EvidenceCalibration.cropRetentionThreshold),
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
        firstManifestObservedMs: Double,
        firstNonLoadingScreenshotCapturedMs: Double
    ) -> [String: Any] {
        // Offsets from the start of scene collection in the harness, not from app launch.
        let timestamps = [
            "collectionStart": 0,
            "firstManifestObserved": firstManifestObservedMs,
            "firstNonLoadingScreenshotCaptured": firstNonLoadingScreenshotCapturedMs
        ]
        return [
            "startupRunId": startupRunId,
            "startupClockSource": "xctest-harness",
            "harnessPhaseTimestampsMs": timestamps,
            "harnessPhaseDurationsMs": [
                "firstManifestObserved": max(0, firstManifestObservedMs),
                "firstNonLoadingScreenshotCaptured": max(0, firstNonLoadingScreenshotCapturedMs)
            ],
            "harnessCollectionToFirstManifestObservedMs": max(0, firstManifestObservedMs),
            "harnessCollectionToFirstNonLoadingScreenshotMs": max(0, firstNonLoadingScreenshotCapturedMs),
            "crossClockSummaryPolicy": "summary-only-cross-clock-observed"
        ]
    }
}
