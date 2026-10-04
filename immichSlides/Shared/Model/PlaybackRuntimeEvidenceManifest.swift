//
//  PlaybackRuntimeEvidenceManifest.swift
//  immichSlides
//
//  Validates runtime evidence JSONL. The default screenshot predicate checks files on disk, and
//  PlaybackScene.smartFillRuntimeQADebugSummary reads AssetsDownloadManager download state.
//

import Foundation

#if DEBUG
struct PlaybackRuntimeEvidenceManifestValidationIssue: Equatable {
    enum Code: String, Equatable {
        case invalidJSON
        case missingRequiredField
        case nullRequiredField
        case unknownRequiredField
        case invalidRequiredField
        case nonFallbackCanvasNotFull
        case forbiddenManifestToken
        case nonFallbackRecovery
        case forbiddenFallbackCategory
        case screenshotMissing
        case screenshotBindingMismatch
        case invalidLatency
        case invalidStartupTiming
        case forbiddenFallbackRootCauseBucket
        case forbiddenSensitiveValue
        case sampleManifestMismatch
        case unsupportedSchemaVersion
    }

    let code: Code
    let field: String
    let message: String
}

struct PlaybackRuntimeEvidenceLatencySummary: Equatable {
    let count: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let maxMilliseconds: Double
}

struct PlaybackRuntimeEvidenceStartupTimingSummary: Equatable {
    let count: Int
    let firstSceneRuntimeP50Milliseconds: Double
    let firstSceneRuntimeP95Milliseconds: Double
    let firstSceneRuntimeMaxMilliseconds: Double
    let firstSlotReadyRuntimeP50Milliseconds: Double
    let firstSlotReadyRuntimeP95Milliseconds: Double
    let firstSlotReadyRuntimeMaxMilliseconds: Double
    let allVisibleSlotsReadyRuntimeP50Milliseconds: Double
    let allVisibleSlotsReadyRuntimeP95Milliseconds: Double
    let allVisibleSlotsReadyRuntimeMaxMilliseconds: Double
}

struct PlaybackRuntimeEvidenceManifestValidationReport: Equatable {
    let issues: [PlaybackRuntimeEvidenceManifestValidationIssue]
    let recordsValidated: Int
    let fallbackDistribution: [String: Int]
    let latencySummary: PlaybackRuntimeEvidenceLatencySummary?
    let fallbackRootCauseDistribution: [String: Int]
    let startupTimingSummary: PlaybackRuntimeEvidenceStartupTimingSummary?
}

enum PlaybackRuntimeEvidenceManifestValidator {
    private static let epsilon = 1e-9
    private static let defaultCropRetentionThreshold: Double = 0.60
    private static let startupFirstImageDisplayProbeJitterToleranceMilliseconds = 10.0
    private static let requiredFields: [String] = [
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
        "screenshotPath"
    ]
    private static let baseSchemaVersion = "runtime-evidence-v1"
    private static let startupFallbackSchemaVersion = "startup-fallback-v1"
    private static let decisionLayerSchemaVersion = "decision-layer-v1"
    private static let startupFallbackRequiredFields: [String] = [
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
        "fallbackRootCauseBucket"
    ]
    private static let decisionLayerRequiredFields: [String] = [
        "currentAssetDisposition",
        "currentAssetRef",
        "currentAssetAbsentReason",
        "currentAssetSlotAreaRatio",
        "currentAssetCropRetention",
        "currentAssetProtectedRegionCoverage",
        "currentAssetFaceProtectionPassed",
        "currentAssetSubjectProtectionPassed",
        "currentAssetVisibleQualityClass",
        "slotRoles",
        "slotRefs",
        "candidateWindowRequested",
        "candidateWindowUsed",
        "candidateWindowExpansionTrace",
        "candidateRejectReasonTopList",
        "acceptedSceneSearchTier",
        "plannerAttemptCountAtFirstPlan",
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
    private static let forbiddenTokens = [
        "canvas-fill",
        "blurred-primary",
        "canvasfillmode",
        "smartfillcanvasbackgroundview",
        "layoutqualityrecoverytier"
    ]
    private static let forbiddenFallbackCategories = [
        "controlbar-triggered",
        "exif-triggered",
        "pending-resource-triggered",
        "recovery-fallback",
        "unknown"
    ]

    static func validateJSONLines(
        _ lines: [String],
        lockedCurrentAssetRefsBySequence: [Int: String] = [:],
        screenshotExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> PlaybackRuntimeEvidenceManifestValidationReport {
        var issues: [PlaybackRuntimeEvidenceManifestValidationIssue] = []
        var records: [[String: Any]] = []
        var fallbackDistribution: [String: Int] = [:]
        var fallbackRootCauseDistribution: [String: Int] = [:]
        var latencies: [Double] = []
        var startupTimingInputs: [(firstScene: Double, firstSlot: Double, allVisible: Double)] = []

        for (index, line) in lines.enumerated() {
            guard let object = parseObject(from: line) else {
                issues.append(
                    issue(.invalidJSON, field: "line:\(index)", message: "runtime evidence line is not a JSON object"))
                continue
            }

            let schemaVersion = stringValue(object["schemaVersion"])
            let isStartupFallbackSchema = schemaVersion == startupFallbackSchemaVersion
            let isDecisionLayerSchema = schemaVersion == decisionLayerSchemaVersion
            records.append(object)
            issues.append(contentsOf: validateRequiredFields(in: object, schemaVersion: schemaVersion))
            issues.append(contentsOf: validateForbiddenTokens(in: object))
            issues.append(contentsOf: validateSensitiveValues(in: object))
            issues.append(contentsOf: validateFallbackCategory(in: object))
            issues.append(contentsOf: validateFallbackRootCause(in: object))
            issues.append(contentsOf: validateProtectionOverlapDetails(in: object))
            issues.append(
                contentsOf: validateStartupTiming(
                    in: object,
                    shouldValidateStartupTiming: isStartupFallbackSchema || isDecisionLayerSchema
                ))
            issues.append(contentsOf: validateDecisionLayer(in: object, isDecisionLayerSchema: isDecisionLayerSchema))
            issues.append(
                contentsOf: validateSampleManifestLock(
                    in: object,
                    lockedCurrentAssetRefsBySequence: lockedCurrentAssetRefsBySequence,
                    isDecisionLayerSchema: isDecisionLayerSchema
                ))
            issues.append(contentsOf: validateGeometry(in: object))
            issues.append(contentsOf: validateScreenshotBinding(in: object, screenshotExists: screenshotExists))

            if let latency = doubleValue(object["actionToSceneMs"]), latency >= 0, latency.isFinite {
                latencies.append(latency)
            } else if object.keys.contains("actionToSceneMs") {
                issues.append(
                    issue(
                        .invalidLatency, field: "actionToSceneMs",
                        message: "actionToSceneMs must be a finite non-negative number"))
            }

            let category = stringValue(object["fallbackCategory"]) ?? "unknown"
            fallbackDistribution[category, default: 0] += 1
            if let rootCause = stringValue(object["fallbackRootCauseBucket"]) {
                fallbackRootCauseDistribution[rootCause, default: 0] += 1
            }
            if isStartupFallbackSchema || isDecisionLayerSchema,
                let firstScene = doubleValue(object["firstSceneRuntimeMs"]),
                let firstSlot = doubleValue(object["firstSlotReadyRuntimeMs"]),
                let allVisible = doubleValue(object["allVisibleSlotsReadyRuntimeMs"]),
                firstScene >= 0,
                firstSlot >= 0,
                allVisible >= 0,
                firstScene.isFinite,
                firstSlot.isFinite,
                allVisible.isFinite
            {
                startupTimingInputs.append((firstScene, firstSlot, allVisible))
            }
        }

        return PlaybackRuntimeEvidenceManifestValidationReport(
            issues: issues,
            recordsValidated: records.count,
            fallbackDistribution: fallbackDistribution,
            latencySummary: makeLatencySummary(from: latencies),
            fallbackRootCauseDistribution: fallbackRootCauseDistribution,
            startupTimingSummary: makeStartupTimingSummary(from: startupTimingInputs)
        )
    }

    private static func parseObject(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private static func validateRequiredFields(
        in object: [String: Any],
        schemaVersion: String?
    ) -> [PlaybackRuntimeEvidenceManifestValidationIssue] {
        var issues: [PlaybackRuntimeEvidenceManifestValidationIssue] = []
        let requiredFieldsForSchema: [String]
        if schemaVersion == decisionLayerSchemaVersion {
            requiredFieldsForSchema = requiredFields + startupFallbackRequiredFields + decisionLayerRequiredFields
        } else if schemaVersion == startupFallbackSchemaVersion {
            requiredFieldsForSchema = requiredFields + startupFallbackRequiredFields
        } else {
            requiredFieldsForSchema = requiredFields
        }

        if let schemaVersion,
            ![baseSchemaVersion, startupFallbackSchemaVersion, decisionLayerSchemaVersion].contains(schemaVersion)
        {
            issues.append(
                issue(
                    .unsupportedSchemaVersion, field: "schemaVersion",
                    message: "schema version \(schemaVersion) is not supported, so its strict checks cannot run"))
        }

        for field in requiredFieldsForSchema {
            guard let value = object[field] else {
                issues.append(issue(.missingRequiredField, field: field, message: "required field is missing"))
                continue
            }
            if value is NSNull {
                issues.append(issue(.nullRequiredField, field: field, message: "required field is null"))
                continue
            }
            if schemaVersion == startupFallbackSchemaVersion,
                field == "fallbackRootCauseBucket"
            {
                continue
            }
            if schemaVersion == decisionLayerSchemaVersion,
                decisionLayerUnknownAllowedFields.contains(field)
            {
                continue
            }
            if let string = value as? String,
                string.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare("unknown")
                    == .orderedSame
            {
                issues.append(issue(.unknownRequiredField, field: field, message: "required field is unknown"))
            }
        }

        return issues
    }

    private static func validateForbiddenTokens(in object: [String: Any])
        -> [PlaybackRuntimeEvidenceManifestValidationIssue]
    {
        let strings = allStringValues(in: object).map { $0.lowercased() }
        let foundTokens = forbiddenTokens.filter { token in
            strings.contains { $0.contains(token) }
        }

        return foundTokens.map { token in
            issue(.forbiddenManifestToken, field: token, message: "manifest contains forbidden token \(token)")
        }
    }

    private static func validateSensitiveValues(in object: [String: Any])
        -> [PlaybackRuntimeEvidenceManifestValidationIssue]
    {
        forbiddenSensitiveFindings(in: object).map { field in
            issue(
                .forbiddenSensitiveValue, field: field,
                message: "manifest contains a sensitive value or raw identifier in \(field)")
        }
    }

    private static func validateFallbackCategory(in object: [String: Any])
        -> [PlaybackRuntimeEvidenceManifestValidationIssue]
    {
        var issues: [PlaybackRuntimeEvidenceManifestValidationIssue] = []
        let fallbackCategory = stringValue(object["fallbackCategory"])?.lowercased() ?? "unknown"

        if forbiddenFallbackCategories.contains(fallbackCategory) {
            issues.append(
                issue(
                    .forbiddenFallbackCategory, field: fallbackCategory,
                    message: "forbidden fallback category count must be zero"))
        }

        if boolValue(object["isFallback"]) == false,
            fallbackCategory.contains("recovery")
        {
            issues.append(
                issue(
                    .nonFallbackRecovery, field: "fallbackCategory",
                    message: "non-fallback scene must not use recovery fallback category"))
        }

        return issues
    }

    private static func validateFallbackRootCause(in object: [String: Any])
        -> [PlaybackRuntimeEvidenceManifestValidationIssue]
    {
        var issues: [PlaybackRuntimeEvidenceManifestValidationIssue] = []
        let forbiddenBooleanFields = [
            "resourceReadinessAffectedFallback",
            "controlBarAffectedFallback",
            "legacyRendererUsedForSmartFillFallback"
        ]

        for field in forbiddenBooleanFields where boolValue(object[field]) == true {
            issues.append(issue(.forbiddenFallbackRootCauseBucket, field: field, message: "\(field) must be false"))
        }

        let bucket = stringValue(object["fallbackRootCauseBucket"])?.lowercased()
        if boolValue(object["isFallback"]) == true,
            (bucket == nil || bucket == "none")
        {
            issues.append(
                issue(
                    .forbiddenFallbackRootCauseBucket, field: "fallbackRootCauseBucket",
                    message: "fallback records must carry a concrete root-cause bucket"))
        }
        let forbiddenBuckets = [
            "resource-readiness-misclassified",
            "controlbar-misclassified",
            "legacy-renderer-misclassified"
        ]
        if let bucket,
            forbiddenBuckets.contains(bucket)
        {
            issues.append(
                issue(.forbiddenFallbackRootCauseBucket, field: bucket, message: "\(bucket) count must be zero"))
        }

        return issues
    }

    private static func validateProtectionOverlapDetails(in object: [String: Any])
        -> [PlaybackRuntimeEvidenceManifestValidationIssue]
    {
        let hasProtectionOverlapSignal =
            manifestValueContains(
                object["candidateRejectReasonTopList"],
                token: "protection-overlap"
            )
            || manifestValueContains(
                object["rejectedLayoutDiagnostics"],
                token: "protection-overlap"
            )
        guard hasProtectionOverlapSignal else { return [] }
        guard let detailValue = object["protectionOverlapDetails"] else {
            return [
                issue(
                    .missingRequiredField,
                    field: "protectionOverlapDetails",
                    message: "protection-overlap records must carry protection overlap diagnostics"
                )
            ]
        }

        let hasConcreteDetail = manifestStringTokens(in: detailValue).contains { rawValue in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                value.localizedCaseInsensitiveCompare("none") != .orderedSame,
                value.localizedCaseInsensitiveCompare("missing") != .orderedSame
            else {
                return false
            }
            return value.contains("source:") && value.contains("region:") && value.contains("hardRejected:")
        }
        guard !hasConcreteDetail else { return [] }
        return [
            issue(
                .invalidRequiredField,
                field: "protectionOverlapDetails",
                message:
                    "protection-overlap records must identify protected source, screen region, and hard reject status"
            )
        ]
    }

    private static let decisionLayerUnknownAllowedFields = Set([
        "startupBlockingPhase"
    ])

    private static func validateDecisionLayer(
        in object: [String: Any],
        isDecisionLayerSchema: Bool
    ) -> [PlaybackRuntimeEvidenceManifestValidationIssue] {
        guard isDecisionLayerSchema else { return [] }

        var issues: [PlaybackRuntimeEvidenceManifestValidationIssue] = []
        let isFallback = boolValue(object["isFallback"]) ?? false
        let slotCount = intValue(object["slotCount"]) ?? 0
        let multiSlotSuccessCount = intValue(object["multiSlotSuccessCount"]) ?? 0
        let smartFillSingleFillCount = intValue(object["smartFillSingleFillCount"]) ?? 0
        let singleRiskCount = intValue(object["singleRiskCount"]) ?? 0
        let hardFallbackCount = intValue(object["hardFallbackCount"]) ?? 0
        let nonMultiSlotOutcomeCount = intValue(object["nonMultiSlotOutcomeCount"]) ?? 0
        let userPerceivedFailureCount = intValue(object["userPerceivedFailureCount"]) ?? 0
        let currentAssetAbsentSceneCount = intValue(object["currentAssetAbsentSceneCount"]) ?? 0
        let visualUnverifiedCount = intValue(object["visualUnverifiedCount"]) ?? 0
        let unknownOutcomeBucketCount = intValue(object["unknownOutcomeBucketCount"]) ?? 0
        let duplicateVisibleSlotCount = intValue(object["duplicateVisibleSlotCount"]) ?? 0
        let recentVisibleLimit = intValue(object["recentVisibleLimit"]) ?? 0
        let recentVisibleCandidateCount = intValue(object["recentVisibleCandidateCount"]) ?? 0
        let acceptedTier = stringValue(object["acceptedSceneSearchTier"]) ?? "unknown"
        let currentDisposition = stringValue(object["currentAssetDisposition"]) ?? "unknown"
        let currentAssetRef = stringValue(object["currentAssetRef"]) ?? "unknown"
        let absentReason = stringValue(object["currentAssetAbsentReason"]) ?? "unknown"
        let currentQuality = stringValue(object["currentAssetVisibleQualityClass"]) ?? "unknown"
        let currentCropRetention = doubleValue(object["currentAssetCropRetention"])
        let thresholdResult = cropRetentionThreshold(in: object)
        let currentCropRetentionThreshold = thresholdResult.value
        issues.append(contentsOf: thresholdResult.issues)
        let currentProtectedRegionCoverage = doubleValue(object["currentAssetProtectedRegionCoverage"])
        let currentFaceProtectionPassed = boolValue(object["currentAssetFaceProtectionPassed"]) ?? false
        let currentSubjectProtectionPassed = boolValue(object["currentAssetSubjectProtectionPassed"]) ?? false
        let duplicateReuseReason = stringValue(object["duplicateReuseReason"]) ?? "unknown"
        let visualReviewStatus = stringValue(object["visualReviewStatus"]) ?? "unknown"
        let ledgerSceneAssets = stringArrayValue(object["ledgerSceneAssets"])
        let slotRefs = stringArrayValue(object["slotRefs"])
        let slotRoles = stringArrayValue(object["slotRoles"])
        let duplicateRefs = stringArrayValue(object["duplicateVisibleSlotRefs"])

        if multiSlotSuccessCount > 0,
            (isFallback || slotCount < 2 || acceptedTier == "single-risk" || acceptedTier == "single-fill")
        {
            issues.append(
                issue(
                    .invalidRequiredField, field: "multiSlotSuccessCount",
                    message:
                        "multiSlotSuccessCount requires non-fallback slotCount >= 2 and cannot include single-fill or single-risk"
                ))
        }

        if multiSlotSuccessCount > 0,
            currentQuality != "acceptable"
        {
            issues.append(
                issue(
                    .invalidRequiredField, field: "currentAssetVisibleQualityClass",
                    message: "current asset quality must be acceptable for multi-slot success"))
        }

        if currentQuality == "fail",
            userPerceivedFailureCount <= 0
        {
            issues.append(
                issue(
                    .invalidRequiredField, field: "currentAssetVisibleQualityClass",
                    message: "failed current asset quality must be counted as user perceived failure"))
        }

        if currentQuality == "risky",
            visualReviewStatus != "NEEDS_PRODUCT_DECISION" && visualReviewStatus != "VISUAL_REVIEW_REQUIRED"
        {
            issues.append(
                issue(
                    .invalidRequiredField, field: "currentAssetVisibleQualityClass",
                    message: "risky current asset quality requires product or visual review"))
        }

        if acceptedTier == "single-risk",
            singleRiskCount <= 0
        {
            issues.append(
                issue(
                    .invalidRequiredField, field: "singleRiskCount",
                    message: "single-risk accepted tier must be counted as singleRiskCount"))
        }

        if acceptedTier == "single-fill" {
            if isFallback || slotCount != 1 || currentDisposition != "single-slot" {
                issues.append(
                    issue(
                        .invalidRequiredField, field: "acceptedSceneSearchTier",
                        message: "single-fill requires one non-fallback single slot with current asset present"))
            }
            if smartFillSingleFillCount <= 0 || singleRiskCount > 0 {
                issues.append(
                    issue(
                        .invalidRequiredField, field: "smartFillSingleFillCount",
                        message: "single-fill must count as smartFillSingleFillCount and not singleRiskCount"))
            }
            if currentQuality != "acceptable" {
                issues.append(
                    issue(
                        .invalidRequiredField, field: "currentAssetVisibleQualityClass",
                        message: "single-fill current asset quality must be acceptable"))
            }
            if currentCropRetention.map({ $0 + epsilon < currentCropRetentionThreshold }) ?? true {
                issues.append(
                    issue(
                        .invalidRequiredField, field: "currentAssetCropRetention",
                        message: "single-fill must keep surface crop retention threshold"))
            }
            if currentProtectedRegionCoverage.map({ $0 < 1.0 }) ?? true || !currentFaceProtectionPassed
                || !currentSubjectProtectionPassed
            {
                issues.append(
                    issue(
                        .invalidRequiredField, field: "currentAssetFaceProtectionPassed",
                        message: "single-fill must preserve face and subject protection"))
            }
        }

        if acceptedTier == "single-risk" {
            if userPerceivedFailureCount <= 0 || nonMultiSlotOutcomeCount <= 0 {
                issues.append(
                    issue(
                        .invalidRequiredField, field: "userPerceivedFailureCount",
                        message: "single-risk outcome must count as user perceived failure"))
            }
        }

        if currentDisposition == "absent-hard-fail" {
            if currentAssetAbsentSceneCount <= 0 || userPerceivedFailureCount <= 0 {
                issues.append(
                    issue(
                        .invalidRequiredField, field: "currentAssetDisposition",
                        message: "absent current asset must count as absent scene and user perceived failure"))
            }
            if absentReason == "none" {
                issues.append(
                    issue(
                        .invalidRequiredField, field: "currentAssetAbsentReason",
                        message: "absent current asset requires a non-none reason"))
            }
            if currentAssetRef != "assetRef-absent" {
                issues.append(
                    issue(
                        .invalidRequiredField, field: "currentAssetRef",
                        message: "absent current asset must use assetRef-absent"))
            }
        } else if absentReason != "none" {
            issues.append(
                issue(
                    .invalidRequiredField, field: "currentAssetAbsentReason",
                    message: "present current asset must use absent reason none"))
        }

        if currentDisposition != "absent-hard-fail" {
            if currentAssetRef == "unknown" || currentAssetRef == "assetRef-missing"
                || currentAssetRef == "assetRef-absent"
            {
                issues.append(
                    issue(
                        .invalidRequiredField, field: "currentAssetRef",
                        message: "present current asset requires a concrete redacted currentAssetRef"))
            }
            if !slotRefs.isEmpty,
                !slotRefs.contains(currentAssetRef)
            {
                issues.append(
                    issue(
                        .invalidRequiredField, field: "currentAssetRef",
                        message: "currentAssetRef must be present in slotRefs"))
            }
            if let expectedSlotIndex = currentAssetSlotIndex(for: currentDisposition),
                expectedSlotIndex < slotRefs.count,
                slotRefs[expectedSlotIndex] != currentAssetRef
            {
                issues.append(
                    issue(
                        .invalidRequiredField, field: "currentAssetRef",
                        message: "currentAssetRef must match currentAssetDisposition slot index"))
            }
        }

        if currentDisposition != "absent-hard-fail",
            !ledgerSceneAssets.isEmpty,
            !slotRefs.isEmpty,
            ledgerSceneAssets != slotRefs
        {
            issues.append(
                issue(.invalidRequiredField, field: "slotRefs", message: "slotRefs must match ledgerSceneAssets order"))
        }

        if currentDisposition != "absent-hard-fail",
            slotRoles.count != slotRefs.count
        {
            issues.append(
                issue(.invalidRequiredField, field: "slotRoles", message: "slotRoles count must match slotRefs count"))
        }

        validateDuplicateSlots(
            duplicateVisibleSlotCount: duplicateVisibleSlotCount,
            duplicateReuseReason: duplicateReuseReason,
            duplicateRefs: duplicateRefs,
            recentVisibleLimit: recentVisibleLimit,
            recentVisibleCandidateCount: recentVisibleCandidateCount,
            issues: &issues
        )
        validateOutcomeCounts(
            hardFallbackCount: hardFallbackCount,
            singleRiskCount: singleRiskCount,
            currentAssetAbsentSceneCount: currentAssetAbsentSceneCount,
            visualUnverifiedCount: visualUnverifiedCount,
            nonMultiSlotOutcomeCount: nonMultiSlotOutcomeCount,
            userPerceivedFailureCount: userPerceivedFailureCount,
            visualReviewStatus: visualReviewStatus,
            multiSlotSuccessCount: multiSlotSuccessCount,
            unknownOutcomeBucketCount: unknownOutcomeBucketCount,
            issues: &issues
        )
        return issues
    }

    private static func validateSampleManifestLock(
        in object: [String: Any],
        lockedCurrentAssetRefsBySequence: [Int: String],
        isDecisionLayerSchema: Bool
    ) -> [PlaybackRuntimeEvidenceManifestValidationIssue] {
        guard isDecisionLayerSchema,
            !lockedCurrentAssetRefsBySequence.isEmpty,
            let sequence = intValue(object["sequence"]),
            let expectedCurrentAssetRef = lockedCurrentAssetRefsBySequence[sequence],
            let actualCurrentAssetRef = stringValue(object["currentAssetRef"])
        else {
            return []
        }

        guard actualCurrentAssetRef == expectedCurrentAssetRef else {
            return [
                issue(
                    .sampleManifestMismatch,
                    field: "currentAssetRef",
                    message:
                        "sequence \(sequence) expected \(expectedCurrentAssetRef) but found \(actualCurrentAssetRef)"
                )
            ]
        }
        return []
    }

    private static func currentAssetSlotIndex(for disposition: String) -> Int? {
        switch disposition {
        case "primary-slot", "single-slot", "fallback-current":
            return 0
        case "secondary-slot":
            return 1
        case "tertiary-slot":
            return 2
        default:
            return nil
        }
    }

    private static func cropRetentionThreshold(
        in object: [String: Any]
    ) -> (value: Double, issues: [PlaybackRuntimeEvidenceManifestValidationIssue]) {
        if object.keys.contains("cropRetentionThresholdUsed") {
            guard let value = doubleValue(object["cropRetentionThresholdUsed"]),
                value.isFinite,
                value >= 0,
                value <= 1
            else {
                return (
                    defaultCropRetentionThreshold,
                    [
                        issue(
                            .invalidRequiredField,
                            field: "cropRetentionThresholdUsed",
                            message: "cropRetentionThresholdUsed must be a finite normalized value"
                        )
                    ]
                )
            }
            return (value, [])
        }

        // Earlier evidence omits this field, so the default preserves compatibility.
        return (defaultCropRetentionThreshold, [])
    }

    private static func validateStartupTiming(
        in object: [String: Any],
        shouldValidateStartupTiming: Bool
    ) -> [PlaybackRuntimeEvidenceManifestValidationIssue] {
        guard shouldValidateStartupTiming else { return [] }

        var issues: [PlaybackRuntimeEvidenceManifestValidationIssue] = []
        if stringValue(object["startupClockSource"]) != "app-runtime" {
            issues.append(
                issue(
                    .invalidStartupTiming, field: "startupClockSource",
                    message: "runtime JSONL startupClockSource must be app-runtime"))
        }

        let timingFields = [
            "firstSceneRuntimeMs",
            "firstSlotReadyRuntimeMs",
            "allVisibleSlotsReadyRuntimeMs"
        ]
        for field in timingFields {
            guard let value = doubleValue(object[field]),
                value >= 0,
                value.isFinite
            else {
                issues.append(
                    issue(.invalidStartupTiming, field: field, message: "\(field) must be a finite non-negative number")
                )
                continue
            }
        }

        if doubleValue(object["firstImageDisplayedRuntimeMs"]).map({ $0 >= 0 && $0.isFinite }) != true {
            issues.append(
                issue(
                    .invalidStartupTiming, field: "firstImageDisplayedRuntimeMs",
                    message: "firstImageDisplayedRuntimeMs must be a finite non-negative number"))
        }

        if stringValue(object["firstImageLoadStatus"]) != "displayed" {
            issues.append(
                issue(
                    .invalidStartupTiming, field: "firstImageLoadStatus",
                    message: "firstImageLoadStatus must be displayed for final startup evidence"))
        }

        if let firstScene = doubleValue(object["firstSceneRuntimeMs"]),
            let firstSlot = doubleValue(object["firstSlotReadyRuntimeMs"]),
            let allVisible = doubleValue(object["allVisibleSlotsReadyRuntimeMs"])
        {
            if firstSlot < firstScene {
                issues.append(
                    issue(
                        .invalidStartupTiming, field: "firstSlotReadyRuntimeMs",
                        message: "first slot ready must not precede first scene publish"))
            }
            if allVisible < firstSlot {
                issues.append(
                    issue(
                        .invalidStartupTiming, field: "allVisibleSlotsReadyRuntimeMs",
                        message: "all visible slots ready must not precede first slot ready"))
            }
            if let firstImageDisplayed = doubleValue(object["firstImageDisplayedRuntimeMs"]),
                firstImageDisplayed + startupFirstImageDisplayProbeJitterToleranceMilliseconds < firstSlot
            {
                issues.append(
                    issue(
                        .invalidStartupTiming, field: "firstImageDisplayedRuntimeMs",
                        message: "first image display must not materially precede first slot ready"))
            }
        }

        if let missingPhases = object["startupMissingPhases"] as? [Any],
            !missingPhases.isEmpty
        {
            issues.append(
                issue(
                    .invalidStartupTiming, field: "startupMissingPhases",
                    message: "Final required startup phases must not be missing"))
        }

        return issues
    }

    private static func validateGeometry(in object: [String: Any]) -> [PlaybackRuntimeEvidenceManifestValidationIssue] {
        guard boolValue(object["isFallback"]) == false else { return [] }

        var issues: [PlaybackRuntimeEvidenceManifestValidationIssue] = []
        if let coverage = doubleValue(object["canvasCoverage"]),
            coverage < 1 - epsilon
        {
            issues.append(
                issue(
                    .nonFallbackCanvasNotFull, field: "canvasCoverage",
                    message: "non-fallback canvas coverage is below full-canvas threshold"))
        }
        if let empty = doubleValue(object["emptyCanvasRatio"]),
            empty > epsilon
        {
            issues.append(
                issue(
                    .nonFallbackCanvasNotFull, field: "emptyCanvasRatio",
                    message: "non-fallback empty canvas ratio must be zero within epsilon"))
        }
        if let maxEmptyAxis = doubleValue(object["maxContinuousEmptyAxisRatio"]),
            maxEmptyAxis > epsilon
        {
            issues.append(
                issue(
                    .nonFallbackCanvasNotFull, field: "maxContinuousEmptyAxisRatio",
                    message: "non-fallback continuous empty axis ratio must be zero within epsilon"))
        }
        if let gapPixels = intValue(object["gapPixelCount"]),
            gapPixels > 0
        {
            issues.append(
                issue(
                    .nonFallbackCanvasNotFull, field: "gapPixelCount",
                    message: "non-fallback gap pixel count must be zero"))
        }
        if let overlapPixels = intValue(object["overlapPixelCount"]),
            overlapPixels > 0
        {
            issues.append(
                issue(
                    .nonFallbackCanvasNotFull, field: "overlapPixelCount",
                    message: "non-fallback overlap pixel count must be zero"))
        }

        return issues
    }

    private static func validateScreenshotBinding(
        in object: [String: Any],
        screenshotExists: (String) -> Bool
    ) -> [PlaybackRuntimeEvidenceManifestValidationIssue] {
        guard let path = stringValue(object["screenshotPath"]) else {
            return []
        }

        var issues: [PlaybackRuntimeEvidenceManifestValidationIssue] = []
        if !screenshotExists(path) {
            issues.append(issue(.screenshotMissing, field: "screenshotPath", message: "screenshot path does not exist"))
        }

        guard let sequence = intValue(object["sequence"]),
            let sceneIdHash = stringValue(object["sceneIdHash"])
        else {
            return issues
        }

        let token = "seq-\(sequence)-\(sceneIdHash)"
        if !path.contains(token) {
            issues.append(
                issue(
                    .screenshotBindingMismatch, field: "screenshotPath",
                    message: "screenshot path must contain \(token)"))
        }
        return issues
    }

    private static func makeLatencySummary(from latencies: [Double]) -> PlaybackRuntimeEvidenceLatencySummary? {
        guard !latencies.isEmpty else { return nil }
        let sorted = latencies.sorted()
        return PlaybackRuntimeEvidenceLatencySummary(
            count: sorted.count,
            p50Milliseconds: percentile(0.50, sorted: sorted),
            p95Milliseconds: percentile(0.95, sorted: sorted),
            maxMilliseconds: sorted.last ?? 0
        )
    }

    private static func makeStartupTimingSummary(
        from inputs: [(firstScene: Double, firstSlot: Double, allVisible: Double)]
    ) -> PlaybackRuntimeEvidenceStartupTimingSummary? {
        guard !inputs.isEmpty else { return nil }

        let firstSceneValues = inputs.map(\.firstScene).sorted()
        let firstSlotValues = inputs.map(\.firstSlot).sorted()
        let allVisibleValues = inputs.map(\.allVisible).sorted()

        return PlaybackRuntimeEvidenceStartupTimingSummary(
            count: inputs.count,
            firstSceneRuntimeP50Milliseconds: percentile(0.50, sorted: firstSceneValues),
            firstSceneRuntimeP95Milliseconds: percentile(0.95, sorted: firstSceneValues),
            firstSceneRuntimeMaxMilliseconds: firstSceneValues.last ?? 0,
            firstSlotReadyRuntimeP50Milliseconds: percentile(0.50, sorted: firstSlotValues),
            firstSlotReadyRuntimeP95Milliseconds: percentile(0.95, sorted: firstSlotValues),
            firstSlotReadyRuntimeMaxMilliseconds: firstSlotValues.last ?? 0,
            allVisibleSlotsReadyRuntimeP50Milliseconds: percentile(0.50, sorted: allVisibleValues),
            allVisibleSlotsReadyRuntimeP95Milliseconds: percentile(0.95, sorted: allVisibleValues),
            allVisibleSlotsReadyRuntimeMaxMilliseconds: allVisibleValues.last ?? 0
        )
    }

    private static func percentile(_ percentile: Double, sorted values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let rank = Int(ceil(percentile * Double(values.count))) - 1
        let index = min(max(rank, 0), values.count - 1)
        return values[index]
    }

    private static func allStringValues(in value: Any) -> [String] {
        if let string = value as? String {
            return [string]
        }
        if let array = value as? [Any] {
            return array.flatMap { allStringValues(in: $0) }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.flatMap { allStringValues(in: $0) }
        }
        return []
    }

    private static func manifestValueContains(_ value: Any?, token: String) -> Bool {
        manifestStringTokens(in: value).contains { string in
            string.localizedCaseInsensitiveContains(token)
        }
    }

    private static func manifestStringTokens(in value: Any?) -> [String] {
        guard let value else { return [] }
        if let string = value as? String {
            return [string]
        }
        if let array = value as? [Any] {
            return array.flatMap { manifestStringTokens(in: $0) }
        }
        if let dictionary = value as? [String: Any] {
            return Array(dictionary.keys) + dictionary.values.flatMap { manifestStringTokens(in: $0) }
        }
        return []
    }

    private static func forbiddenSensitiveFindings(in value: Any, field: String? = nil) -> [String] {
        var findings: [String] = []

        if let dictionary = value as? [String: Any] {
            for (key, nestedValue) in dictionary {
                findings.append(contentsOf: forbiddenSensitiveFindings(in: nestedValue, field: key))
            }
            return findings
        }

        if let array = value as? [Any] {
            for nestedValue in array {
                findings.append(contentsOf: forbiddenSensitiveFindings(in: nestedValue, field: field))
            }
            return findings
        }

        let fieldName = field ?? "value"
        let normalizedField =
            fieldName
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        let forbiddenFieldNames = [
            "apikey",
            "token",
            "authorization",
            "assetid",
            "personid",
            "serverurl"
        ]
        if forbiddenFieldNames.contains(normalizedField) {
            findings.append(fieldName)
        }

        if let string = value as? String {
            let lowercased = string.lowercased()
            let containsSensitiveToken =
                lowercased.contains("http://") || lowercased.contains("https://") || lowercased.contains("bearer ")
                || lowercased.contains("api_key") || lowercased.contains("api key") || lowercased.contains("token=")
            if containsSensitiveToken {
                findings.append(fieldName)
            }
        }

        return Array(Set(findings)).sorted()
    }

    private static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double {
            return double
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private static func stringArrayValue(_ value: Any?) -> [String] {
        value as? [String] ?? []
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            switch string.lowercased() {
            case "true":
                return true
            case "false":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private static func issue(
        _ code: PlaybackRuntimeEvidenceManifestValidationIssue.Code,
        field: String,
        message: String
    ) -> PlaybackRuntimeEvidenceManifestValidationIssue {
        PlaybackRuntimeEvidenceManifestValidationIssue(code: code, field: field, message: message)
    }
    private static func validateDuplicateSlots(
        duplicateVisibleSlotCount: Int,
        duplicateReuseReason: String,
        duplicateRefs: [String],
        recentVisibleLimit: Int,
        recentVisibleCandidateCount: Int,
        issues: inout [PlaybackRuntimeEvidenceManifestValidationIssue]
    ) {
        if duplicateVisibleSlotCount > 0,
            duplicateReuseReason == "none"
        {
            issues.append(
                issue(
                    .invalidRequiredField, field: "duplicateReuseReason",
                    message: "duplicate visible slots require a reuse reason"))
        }

        if duplicateVisibleSlotCount > 0,
            duplicateRefs.isEmpty
        {
            issues.append(
                issue(
                    .invalidRequiredField, field: "duplicateVisibleSlotRefs",
                    message: "duplicate visible slots require duplicate refs"))
        }

        if recentVisibleLimit > 0,
            recentVisibleCandidateCount > recentVisibleLimit
        {
            issues.append(
                issue(
                    .invalidRequiredField, field: "recentVisibleCandidateCount",
                    message: "recent visible candidate count exceeds limit"))
        }
    }

    private static func validateOutcomeCounts(
        hardFallbackCount: Int,
        singleRiskCount: Int,
        currentAssetAbsentSceneCount: Int,
        visualUnverifiedCount: Int,
        nonMultiSlotOutcomeCount: Int,
        userPerceivedFailureCount: Int,
        visualReviewStatus: String,
        multiSlotSuccessCount: Int,
        unknownOutcomeBucketCount: Int,
        issues: inout [PlaybackRuntimeEvidenceManifestValidationIssue]
    ) {
        let expectedNonMulti =
            hardFallbackCount + singleRiskCount + currentAssetAbsentSceneCount + visualUnverifiedCount
        if nonMultiSlotOutcomeCount != expectedNonMulti {
            issues.append(
                issue(
                    .invalidRequiredField, field: "nonMultiSlotOutcomeCount",
                    message:
                        "nonMultiSlotOutcomeCount must equal hardFallback + single-risk + absent + visual-unverified"))
        }

        let expectedUserFailure =
            hardFallbackCount + singleRiskCount + visualUnverifiedCount + currentAssetAbsentSceneCount
        if userPerceivedFailureCount != expectedUserFailure {
            issues.append(
                issue(
                    .invalidRequiredField, field: "userPerceivedFailureCount",
                    message:
                        "userPerceivedFailureCount must equal hardFallback + single-risk + visual-unverified + absent"))
        }

        if visualReviewStatus == "VISUAL_UNVERIFIED",
            (multiSlotSuccessCount > 0 || userPerceivedFailureCount <= 0 || visualUnverifiedCount <= 0)
        {
            issues.append(
                issue(
                    .invalidRequiredField, field: "visualReviewStatus",
                    message:
                        "visual-unverified samples cannot count as multi-slot success and must count as user perceived failure"
                ))
        }

        if unknownOutcomeBucketCount > 0 {
            issues.append(
                issue(
                    .invalidRequiredField, field: "unknownOutcomeBucketCount",
                    message: "unknown outcome bucket final count must be zero"))
        }
    }

}

#endif
