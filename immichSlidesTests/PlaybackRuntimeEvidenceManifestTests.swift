//
//  PlaybackRuntimeEvidenceManifestTests.swift
//  immichSlidesTests
//

import Foundation
import Testing
@testable import immichSlides

@Suite
struct PlaybackRuntimeEvidenceManifestTests {
    nonisolated static let externalRuntimeJSONLPath: String? = {
        let environment = ProcessInfo.processInfo.environment
        return environment["IMMICHSLIDES_RUNTIME_JSONL_FOR_VALIDATION"]
            ?? environment["TEST_RUNNER_IMMICHSLIDES_RUNTIME_JSONL_FOR_VALIDATION"]
    }()
    nonisolated static let externalValidatorReportPath: String? = {
        let environment = ProcessInfo.processInfo.environment
        return environment["IMMICHSLIDES_RUNTIME_VALIDATOR_REPORT_PATH"]
            ?? environment["TEST_RUNNER_IMMICHSLIDES_RUNTIME_VALIDATOR_REPORT_PATH"]
    }()
    nonisolated static let isExternalRuntimeJSONLEnabled = externalRuntimeJSONLPath?.isEmpty == false
    static let requiredStartupPhaseKeys = [
        "playbackEntryRequested",
        "assetPoolRequestStarted",
        "assetPoolReady",
        "firstScenePlanningStarted",
        "firstScenePlanned",
        "firstScenePublished",
        "firstSlotReady",
        "allVisibleSlotsReady"
    ]
    static let requiredPhotoLoadPhaseKeys = [
        "cacheChecked",
        "downloadRequestStarted",
        "downloadCompleted",
        "decodeCompleted",
        "firstImageDisplayed"
    ]

    @Test
    func `complete scene JSONL passes required fields, geometry, screenshot binding, and latency checks`() throws {
        let screenshotPath = "/evidence/screenshots/seq-7-sceneabc123.png"
        let line = try jsonLine(validRecord(sequence: 7, sceneIdHash: "sceneabc123", screenshotPath: screenshotPath))

        let report = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            [line],
            screenshotExists: { $0 == screenshotPath }
        )

        #expect(report.issues.isEmpty)
        #expect(report.recordsValidated == 1)
        #expect(report.fallbackDistribution["none"] == 1)
        #expect(report.latencySummary?.count == 1)
        #expect(report.latencySummary?.p50Milliseconds == 42)
        #expect(report.latencySummary?.p95Milliseconds == 42)
        #expect(report.latencySummary?.maxMilliseconds == 42)
    }

    @Test
    func `required field missing, null, or unknown value hard fails`() throws {
        var missing = validRecord()
        missing.removeValue(forKey: "sceneIdHash")

        var nullValue = validRecord()
        nullValue["surfaceKey"] = NSNull()

        var unknownValue = validRecord()
        unknownValue["photoCanvasId"] = "unknown"

        var retiredSchemaVersion = validRecord()
        retiredSchemaVersion["schemaVersion"] = "pr46-startup-fallback-v1"

        let report = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            [
                try jsonLine(missing),
                try jsonLine(nullValue),
                try jsonLine(unknownValue),
                try jsonLine(retiredSchemaVersion)
            ],
            screenshotExists: { _ in true }
        )

        #expect(hasIssue(report.issues, code: .missingRequiredField, field: "sceneIdHash"))
        #expect(hasIssue(report.issues, code: .nullRequiredField, field: "surfaceKey"))
        #expect(hasIssue(report.issues, code: .unknownRequiredField, field: "photoCanvasId"))
        #expect(hasIssue(report.issues, code: .unsupportedSchemaVersion, field: "schemaVersion"))
    }

    @Test
    func `non fallback geometry not filling the canvas hard fails`() throws {
        var empty = validRecord()
        let positiveEmptyCanvasRatio: Double = 0.00000001
        empty["emptyCanvasRatio"] = positiveEmptyCanvasRatio

        var gap = validRecord(
            sequence: 8, sceneIdHash: "scenegap888", screenshotPath: "/evidence/screenshots/seq-8-scenegap888.png")
        gap["gapPixelCount"] = 1

        var overlap = validRecord(
            sequence: 9, sceneIdHash: "sceneover999", screenshotPath: "/evidence/screenshots/seq-9-sceneover999.png")
        overlap["overlapPixelCount"] = 1

        let report = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            [
                try jsonLine(empty),
                try jsonLine(gap),
                try jsonLine(overlap)
            ],
            screenshotExists: { _ in true }
        )

        #expect(hasIssue(report.issues, code: .nonFallbackCanvasNotFull, field: "emptyCanvasRatio"))
        #expect(hasIssue(report.issues, code: .nonFallbackCanvasNotFull, field: "gapPixelCount"))
        #expect(hasIssue(report.issues, code: .nonFallbackCanvasNotFull, field: "overlapPixelCount"))
    }

    @Test
    func `forbidden fallback category hard fails final evidence`() throws {
        let forbiddenCategories = [
            "controlbar-triggered",
            "exif-triggered",
            "pending-resource-triggered",
            "recovery-fallback",
            "unknown"
        ]
        let lines = try forbiddenCategories.enumerated().map { index, category in
            var record = validRecord(
                sequence: index,
                sceneIdHash: "scene\(index)bad",
                screenshotPath: "/evidence/screenshots/seq-\(index)-scene\(index)bad.png"
            )
            record["sceneType"] = "fallback"
            record["isFallback"] = true
            record["fallbackReason"] = "all-layouts-rejected"
            record["fallbackCategory"] = category
            return try jsonLine(record)
        }

        let report = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            lines,
            screenshotExists: { _ in true }
        )

        for category in forbiddenCategories {
            #expect(hasIssue(report.issues, code: .forbiddenFallbackCategory, field: category))
        }
    }

    @Test
    func `legal layout reject fallbacks count as distribution evidence, not total failure`() throws {
        let lines = try (1...8).map { sequence in
            var record = validRecord(
                sequence: sequence,
                sceneIdHash: "layoutreject\(sequence)",
                screenshotPath: "/evidence/screenshots/seq-\(sequence)-layoutreject\(sequence).png"
            )
            record["sceneType"] = "fallback"
            record["isFallback"] = true
            record["fallbackReason"] = "all-layouts-rejected"
            record["fallbackCategory"] = "layout-reject"
            record["fallbackRootCauseBucket"] = "layout-policy-no-match"
            return try jsonLine(record)
        }

        let report = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            lines,
            screenshotExists: { _ in true }
        )

        #expect(report.issues.isEmpty)
        #expect(report.recordsValidated == 8)
        #expect(report.fallbackDistribution["layout-reject"] == 8)
    }

    @Test
    func `decision layer fallback root cause cannot be reported as none`() throws {
        var record = decisionLayerRecord()
        record["sceneType"] = "fallback"
        record["isFallback"] = true
        record["fallbackReason"] = "all-layouts-rejected"
        record["fallbackCategory"] = "layout-reject"
        record["acceptedSceneSearchTier"] = "fallback"
        record["currentAssetDisposition"] = "fallback-current"
        record["currentAssetVisibleQualityClass"] = "fail"
        record["slotCount"] = 1
        record["slotRoles"] = ["primary"]
        record["slotRefs"] = ["asset-hash-a"]
        record["ledgerSceneAssets"] = ["asset-hash-a"]
        record["hardFallbackCount"] = 1
        record["multiSlotSuccessCount"] = 0
        record["nonMultiSlotOutcomeCount"] = 2
        record["userPerceivedFailureCount"] = 2
        record["visualUnverifiedCount"] = 1
        record["fallbackRootCauseBucket"] = "none"

        let report = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            [try jsonLine(record)],
            screenshotExists: { _ in true }
        )

        #expect(hasIssue(report.issues, code: .forbiddenFallbackRootCauseBucket, field: "fallbackRootCauseBucket"))
    }

    @Test
    func `forbidden manifest token or non fallback recovery hard fails`() throws {
        var canvasFill = validRecord()
        canvasFill["layoutPreset"] = "canvas-fill"

        var blurredPrimary = validRecord(
            sequence: 8, sceneIdHash: "sceneblur88", screenshotPath: "/evidence/screenshots/seq-8-sceneblur88.png")
        blurredPrimary["layoutVariant"] = "blurred-primary"

        var recovery = validRecord(
            sequence: 9, sceneIdHash: "scenerec999", screenshotPath: "/evidence/screenshots/seq-9-scenerec999.png")
        recovery["fallbackCategory"] = "recovery-fallback"

        let report = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            [
                try jsonLine(canvasFill),
                try jsonLine(blurredPrimary),
                try jsonLine(recovery)
            ],
            screenshotExists: { _ in true }
        )

        #expect(hasIssue(report.issues, code: .forbiddenManifestToken, field: "canvas-fill"))
        #expect(hasIssue(report.issues, code: .forbiddenManifestToken, field: "blurred-primary"))
        #expect(hasIssue(report.issues, code: .nonFallbackRecovery, field: "fallbackCategory"))
    }

    @Test
    func `decision layer schema enforces perceived failure buckets for single, current asset, and unknown outcomes`()
        throws
    {
        let valid = decisionLayerRecord()

        var singleCountedAsMulti = decisionLayerRecord(
            sequence: 8,
            sceneIdHash: "smartFillScene008",
            screenshotPath: "/evidence/screenshots/seq-8-smartFillScene008.png"
        )
        singleCountedAsMulti["slotCount"] = 1
        singleCountedAsMulti["acceptedSceneSearchTier"] = "single-risk"
        singleCountedAsMulti["smartFillSingleFillCount"] = 1
        singleCountedAsMulti["multiSlotSuccessCount"] = 1
        singleCountedAsMulti["userPerceivedFailureCount"] = 0
        singleCountedAsMulti["nonMultiSlotOutcomeCount"] = 0

        var riskyCurrentAssetCountedAsMulti = decisionLayerRecord(
            sequence: 9,
            sceneIdHash: "smartFillScene009",
            screenshotPath: "/evidence/screenshots/seq-9-smartFillScene009.png"
        )
        riskyCurrentAssetCountedAsMulti["currentAssetVisibleQualityClass"] = "risky"
        riskyCurrentAssetCountedAsMulti["multiSlotSuccessCount"] = 1
        riskyCurrentAssetCountedAsMulti["userPerceivedFailureCount"] = 0

        var absentCurrentAsset = decisionLayerRecord(
            sequence: 10,
            sceneIdHash: "smartFillScene010",
            screenshotPath: "/evidence/screenshots/seq-10-smartFillScene010.png"
        )
        absentCurrentAsset["currentAssetDisposition"] = "absent-hard-fail"
        absentCurrentAsset["currentAssetAbsentReason"] = "validator-blocked"
        absentCurrentAsset["currentAssetAbsentSceneCount"] = 1
        absentCurrentAsset["currentAssetRef"] = "assetRef-absent"
        absentCurrentAsset["ledgerSceneAssets"] = ["asset-hash-b"]
        absentCurrentAsset["slotRefs"] = ["asset-hash-b"]
        absentCurrentAsset["userPerceivedFailureCount"] = 0

        var duplicateWithoutReason = decisionLayerRecord(
            sequence: 11,
            sceneIdHash: "smartFillScene011",
            screenshotPath: "/evidence/screenshots/seq-11-smartFillScene011.png"
        )
        duplicateWithoutReason["duplicateVisibleSlotCount"] = 1
        duplicateWithoutReason["duplicateVisibleSlotRefs"] = ["asset-hash-a"]
        duplicateWithoutReason["duplicateReuseReason"] = "none"

        var visualUnverifiedCountedAsMulti = decisionLayerRecord(
            sequence: 12,
            sceneIdHash: "smartFillScene012",
            screenshotPath: "/evidence/screenshots/seq-12-smartFillScene012.png"
        )
        visualUnverifiedCountedAsMulti["visualReviewStatus"] = "VISUAL_UNVERIFIED"
        visualUnverifiedCountedAsMulti["visualUnverifiedCount"] = 1
        visualUnverifiedCountedAsMulti["multiSlotSuccessCount"] = 1
        visualUnverifiedCountedAsMulti["userPerceivedFailureCount"] = 0

        var unknownBucketCountedAsMulti = decisionLayerRecord(
            sequence: 13,
            sceneIdHash: "smartFillScene013",
            screenshotPath: "/evidence/screenshots/seq-13-smartFillScene013.png"
        )
        unknownBucketCountedAsMulti["unknownOutcomeBucketCount"] = 1
        unknownBucketCountedAsMulti["multiSlotSuccessCount"] = 1

        let validReport = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            [try jsonLine(valid)],
            screenshotExists: { _ in true }
        )
        let invalidReport = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            [
                try jsonLine(singleCountedAsMulti),
                try jsonLine(riskyCurrentAssetCountedAsMulti),
                try jsonLine(absentCurrentAsset),
                try jsonLine(duplicateWithoutReason),
                try jsonLine(visualUnverifiedCountedAsMulti),
                try jsonLine(unknownBucketCountedAsMulti)
            ],
            screenshotExists: { _ in true }
        )

        #expect(validReport.issues.isEmpty)
        #expect(hasIssue(invalidReport.issues, code: .invalidRequiredField, field: "multiSlotSuccessCount"))
        #expect(hasIssue(invalidReport.issues, code: .invalidRequiredField, field: "currentAssetVisibleQualityClass"))
        #expect(hasIssue(invalidReport.issues, code: .invalidRequiredField, field: "currentAssetDisposition"))
        #expect(hasIssue(invalidReport.issues, code: .invalidRequiredField, field: "duplicateReuseReason"))
        #expect(hasIssue(invalidReport.issues, code: .invalidRequiredField, field: "visualReviewStatus"))
        #expect(hasIssue(invalidReport.issues, code: .invalidRequiredField, field: "unknownOutcomeBucketCount"))
    }

    @Test
    func `reviewed single fill counts as perceived success without joining multi slot success`() throws {
        var reviewedSingleFill = decisionLayerRecord(
            sequence: 14,
            sceneIdHash: "smartFillScene014",
            screenshotPath: "/evidence/screenshots/seq-14-smartFillScene014.png"
        )
        reviewedSingleFill["sceneType"] = "single"
        reviewedSingleFill["isFallback"] = false
        reviewedSingleFill["slotCount"] = 1
        reviewedSingleFill["surfaceKey"] = "iPhone-portrait-compact-regular-safeA"
        reviewedSingleFill["acceptedSceneSearchTier"] = "single-fill"
        reviewedSingleFill["currentAssetDisposition"] = "single-slot"
        reviewedSingleFill["currentAssetSlotAreaRatio"] = 1.0
        reviewedSingleFill["currentAssetCropRetention"] = 0.884
        reviewedSingleFill["currentAssetProtectedRegionCoverage"] = 1.0
        reviewedSingleFill["currentAssetFaceProtectionPassed"] = true
        reviewedSingleFill["currentAssetSubjectProtectionPassed"] = true
        reviewedSingleFill["currentAssetVisibleQualityClass"] = "acceptable"
        reviewedSingleFill["slotRoles"] = ["primary"]
        reviewedSingleFill["slotRefs"] = ["asset-hash-a"]
        reviewedSingleFill["ledgerSceneAssets"] = ["asset-hash-a"]
        reviewedSingleFill["multiSlotSuccessCount"] = 0
        reviewedSingleFill["smartFillSingleFillCount"] = 1
        reviewedSingleFill["singleRiskCount"] = 0
        reviewedSingleFill["hardFallbackCount"] = 0
        reviewedSingleFill["nonMultiSlotOutcomeCount"] = 0
        reviewedSingleFill["userPerceivedFailureCount"] = 0
        reviewedSingleFill["visualUnverifiedCount"] = 0
        reviewedSingleFill["visualReviewStatus"] = "REVIEWED_PASS"

        var lowRetentionSingleFill = reviewedSingleFill
        lowRetentionSingleFill["sequence"] = 15
        lowRetentionSingleFill["sceneIdHash"] = "smartFillScene015"
        lowRetentionSingleFill["screenshotPath"] = "/evidence/screenshots/seq-15-smartFillScene015.png"
        lowRetentionSingleFill["currentAssetCropRetention"] = 0.599

        var iPadSixtyPercentSingleFill = reviewedSingleFill
        iPadSixtyPercentSingleFill["sequence"] = 17
        iPadSixtyPercentSingleFill["sceneIdHash"] = "smartFillScene017"
        iPadSixtyPercentSingleFill["screenshotPath"] = "/evidence/screenshots/seq-17-smartFillScene017.png"
        iPadSixtyPercentSingleFill["surfaceKey"] = "iPad-landscape-regular-regular-safeA"
        iPadSixtyPercentSingleFill["currentAssetCropRetention"] = 0.600

        var largeSurfaceLowRetentionSingleFill = iPadSixtyPercentSingleFill
        largeSurfaceLowRetentionSingleFill["sequence"] = 19
        largeSurfaceLowRetentionSingleFill["sceneIdHash"] = "smartFillScene019"
        largeSurfaceLowRetentionSingleFill["screenshotPath"] = "/evidence/screenshots/seq-19-smartFillScene019.png"
        largeSurfaceLowRetentionSingleFill["currentAssetCropRetention"] = 0.599

        var iPhoneSixtyPercentSingleFill = reviewedSingleFill
        iPhoneSixtyPercentSingleFill["sequence"] = 18
        iPhoneSixtyPercentSingleFill["sceneIdHash"] = "smartFillScene018"
        iPhoneSixtyPercentSingleFill["screenshotPath"] = "/evidence/screenshots/seq-18-smartFillScene018.png"
        iPhoneSixtyPercentSingleFill["currentAssetCropRetention"] = 0.600

        var unprotectedSingleFill = reviewedSingleFill
        unprotectedSingleFill["sequence"] = 16
        unprotectedSingleFill["sceneIdHash"] = "smartFillScene016"
        unprotectedSingleFill["screenshotPath"] = "/evidence/screenshots/seq-16-smartFillScene016.png"
        unprotectedSingleFill["currentAssetProtectedRegionCoverage"] = 0.0
        unprotectedSingleFill["currentAssetFaceProtectionPassed"] = false

        let validReport = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            [
                try jsonLine(reviewedSingleFill),
                try jsonLine(iPhoneSixtyPercentSingleFill),
                try jsonLine(iPadSixtyPercentSingleFill)
            ],
            screenshotExists: { _ in true }
        )
        let invalidReport = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            [
                try jsonLine(lowRetentionSingleFill),
                try jsonLine(largeSurfaceLowRetentionSingleFill),
                try jsonLine(unprotectedSingleFill)
            ],
            screenshotExists: { _ in true }
        )

        #expect(validReport.issues.isEmpty)
        #expect(hasIssue(invalidReport.issues, code: .invalidRequiredField, field: "currentAssetCropRetention"))
        #expect(hasIssue(invalidReport.issues, code: .invalidRequiredField, field: "currentAssetFaceProtectionPassed"))
    }

    @Test
    func
        `single fill validator prefers the manifest emitted crop retention threshold and stays compatible with old evidence`()
        throws
    {
        var oldManifestSingleFill = decisionLayerRecord(
            sequence: 20,
            sceneIdHash: "smartFillScene020",
            screenshotPath: "/evidence/screenshots/seq-20-smartFillScene020.png"
        )
        oldManifestSingleFill["sceneType"] = "single"
        oldManifestSingleFill["isFallback"] = false
        oldManifestSingleFill["slotCount"] = 1
        oldManifestSingleFill["acceptedSceneSearchTier"] = "single-fill"
        oldManifestSingleFill["currentAssetDisposition"] = "single-slot"
        oldManifestSingleFill["currentAssetSlotAreaRatio"] = 1.0
        oldManifestSingleFill["currentAssetCropRetention"] = 0.600
        oldManifestSingleFill["currentAssetProtectedRegionCoverage"] = 1.0
        oldManifestSingleFill["currentAssetFaceProtectionPassed"] = true
        oldManifestSingleFill["currentAssetSubjectProtectionPassed"] = true
        oldManifestSingleFill["currentAssetVisibleQualityClass"] = "acceptable"
        oldManifestSingleFill["slotRoles"] = ["primary"]
        oldManifestSingleFill["slotRefs"] = ["asset-hash-a"]
        oldManifestSingleFill["ledgerSceneAssets"] = ["asset-hash-a"]
        oldManifestSingleFill["multiSlotSuccessCount"] = 0
        oldManifestSingleFill["smartFillSingleFillCount"] = 1
        oldManifestSingleFill["singleRiskCount"] = 0
        oldManifestSingleFill["hardFallbackCount"] = 0
        oldManifestSingleFill["nonMultiSlotOutcomeCount"] = 0
        oldManifestSingleFill["userPerceivedFailureCount"] = 0
        oldManifestSingleFill["visualUnverifiedCount"] = 0
        oldManifestSingleFill["visualReviewStatus"] = "REVIEWED_PASS"

        var emittedThresholdFailure = oldManifestSingleFill
        emittedThresholdFailure["sequence"] = 21
        emittedThresholdFailure["sceneIdHash"] = "smartFillScene021"
        emittedThresholdFailure["screenshotPath"] = "/evidence/screenshots/seq-21-smartFillScene021.png"
        emittedThresholdFailure["currentAssetCropRetention"] = 0.659
        emittedThresholdFailure["cropRetentionThresholdUsed"] = 0.660

        let oldManifestReport = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            [try jsonLine(oldManifestSingleFill)],
            screenshotExists: { _ in true }
        )
        let emittedThresholdReport = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            [try jsonLine(emittedThresholdFailure)],
            screenshotExists: { _ in true }
        )

        #expect(oldManifestReport.issues.isEmpty)
        #expect(
            hasIssue(emittedThresholdReport.issues, code: .invalidRequiredField, field: "currentAssetCropRetention"))
    }

    @Test
    func `scenario manifest lock binds sequence to its current asset ref`() throws {
        let first = decisionLayerRecord(
            sequence: 1,
            sceneIdHash: "smartFillScene001",
            screenshotPath: "/evidence/screenshots/seq-1-smartFillScene001.png"
        )
        var second = decisionLayerRecord(
            sequence: 2,
            sceneIdHash: "smartFillScene002",
            screenshotPath: "/evidence/screenshots/seq-2-smartFillScene002.png"
        )
        second["slotRefs"] = ["asset-hash-c", "asset-hash-d"]
        second["ledgerSceneAssets"] = ["asset-hash-c", "asset-hash-d"]
        second["currentAssetRef"] = "asset-hash-c"

        let validReport = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            [
                try jsonLine(first),
                try jsonLine(second)
            ],
            lockedCurrentAssetRefsBySequence: [
                1: "asset-hash-a",
                2: "asset-hash-c"
            ],
            screenshotExists: { _ in true }
        )
        let mismatchReport = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            [try jsonLine(second)],
            lockedCurrentAssetRefsBySequence: [
                2: "asset-hash-z"
            ],
            screenshotExists: { _ in true }
        )

        #expect(validReport.issues.isEmpty)
        #expect(hasIssue(mismatchReport.issues, code: .sampleManifestMismatch, field: "currentAssetRef"))
    }

    @Test
    func `protection overlap rejection records carry concrete protection box and screen region detail`() throws {
        let details = [
            "source:face",
            "region:systemSafeArea",
            "priority:hard",
            "crop:x0.000y0.227w1.000h0.773",
            "mapped:x0.450y0.890w0.120h0.080",
            "hardRejected:true"
        ].joined(separator: "|")
        var valid = decisionLayerRecord(
            sequence: 20,
            sceneIdHash: "smartFillScene020",
            screenshotPath: "/evidence/screenshots/seq-20-smartFillScene020.png"
        )
        valid["candidateRejectReasonTopList"] = ["protection-overlap": 1]
        valid["rejectedLayoutDiagnostics"] = ["reason:protection-overlap|role:primary"]
        valid["protectionOverlapDetails"] = details

        var missing = valid
        missing["sequence"] = 21
        missing["sceneIdHash"] = "smartFillScene021"
        missing["screenshotPath"] = "/evidence/screenshots/seq-21-smartFillScene021.png"
        missing.removeValue(forKey: "protectionOverlapDetails")

        var none = valid
        none["sequence"] = 22
        none["sceneIdHash"] = "smartFillScene022"
        none["screenshotPath"] = "/evidence/screenshots/seq-22-smartFillScene022.png"
        none["protectionOverlapDetails"] = "none"

        let validReport = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            [try jsonLine(valid)],
            screenshotExists: { _ in true }
        )
        let invalidReport = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            [
                try jsonLine(missing),
                try jsonLine(none)
            ],
            screenshotExists: { _ in true }
        )

        #expect(validReport.issues.isEmpty)
        #expect(hasIssue(invalidReport.issues, code: .missingRequiredField, field: "protectionOverlapDetails"))
        #expect(hasIssue(invalidReport.issues, code: .invalidRequiredField, field: "protectionOverlapDetails"))
    }

    @Test
    func `system safe area soft warning detail stays valid manifest evidence`() throws {
        let details = [
            "source:face",
            "region:systemSafeArea",
            "priority:hard",
            "crop:x0.000y0.000w1.000h1.000",
            "mapped:x0.920y0.420w0.060h0.120",
            "hardRejected:false",
            "systemSafeAreaSoftWarning:true"
        ].joined(separator: "|")
        var valid = decisionLayerRecord(
            sequence: 23,
            sceneIdHash: "smartFillScene023",
            screenshotPath: "/evidence/screenshots/seq-23-smartFillScene023.png"
        )
        valid["candidateRejectReasonTopList"] = ["protection-overlap": 1]
        valid["rejectedLayoutDiagnostics"] = ["reason:protection-overlap|role:primary"]
        valid["protectionOverlapDetails"] = details

        let report = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            [try jsonLine(valid)],
            screenshotExists: { _ in true }
        )

        #expect(report.issues.isEmpty)
    }

    @Test
    func `screenshot must exist and its path must bind sequence and scene id hash`() throws {
        let missingPath = "/evidence/screenshots/seq-7-sceneabc123.png"
        let mismatchedPath = "/evidence/screenshots/seq-8-sceneabc123.png"
        let missingReport = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            [try jsonLine(validRecord(screenshotPath: missingPath))],
            screenshotExists: { _ in false }
        )
        let mismatchReport = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            [try jsonLine(validRecord(screenshotPath: mismatchedPath))],
            screenshotExists: { _ in true }
        )

        #expect(hasIssue(missingReport.issues, code: .screenshotMissing, field: "screenshotPath"))
        #expect(hasIssue(mismatchReport.issues, code: .screenshotBindingMismatch, field: "screenshotPath"))
    }

    @Test
    func `latency summary is derived from per scene JSONL records`() throws {
        let lines = try [
            validRecord(
                sequence: 0, sceneIdHash: "scene000aaa", screenshotPath: "/evidence/screenshots/seq-0-scene000aaa.png",
                actionToSceneMs: 20),
            validRecord(
                sequence: 1, sceneIdHash: "scene111bbb", screenshotPath: "/evidence/screenshots/seq-1-scene111bbb.png",
                actionToSceneMs: 40),
            validRecord(
                sequence: 2, sceneIdHash: "scene222ccc", screenshotPath: "/evidence/screenshots/seq-2-scene222ccc.png",
                actionToSceneMs: 100)
        ].map(jsonLine)

        let report = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            lines,
            screenshotExists: { _ in true }
        )

        #expect(report.issues.isEmpty)
        #expect(report.latencySummary?.count == 3)
        #expect(report.latencySummary?.p50Milliseconds == 40)
        #expect(report.latencySummary?.p95Milliseconds == 100)
        #expect(report.latencySummary?.maxMilliseconds == 100)
    }
}
