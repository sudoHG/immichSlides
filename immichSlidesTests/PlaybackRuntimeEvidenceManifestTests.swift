//
//  PlaybackRuntimeEvidenceManifestTests.swift
//  immichSlidesTests
//

import Foundation
import Testing
@testable import immichSlides

@Suite
struct PlaybackRuntimeEvidenceManifestTests {
    private nonisolated static let externalRuntimeJSONLPath: String? = {
        let environment = ProcessInfo.processInfo.environment
        return environment["IMMICHSLIDES_RUNTIME_JSONL_FOR_VALIDATION"]
            ?? environment["TEST_RUNNER_IMMICHSLIDES_RUNTIME_JSONL_FOR_VALIDATION"]
    }()
    private nonisolated static let externalValidatorReportPath: String? = {
        let environment = ProcessInfo.processInfo.environment
        return environment["IMMICHSLIDES_RUNTIME_VALIDATOR_REPORT_PATH"]
            ?? environment["TEST_RUNNER_IMMICHSLIDES_RUNTIME_VALIDATOR_REPORT_PATH"]
    }()
    private nonisolated static let externalRuntimeJSONLEnabled = externalRuntimeJSONLPath?.isEmpty == false
    private static let requiredStartupPhaseKeys = [
        "playbackEntryRequested",
        "assetPoolRequestStarted",
        "assetPoolReady",
        "firstScenePlanningStarted",
        "firstScenePlanned",
        "firstScenePublished",
        "firstSlotReady",
        "allVisibleSlotsReady"
    ]
    private static let requiredPhotoLoadPhaseKeys = [
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

        let report = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            [
                try jsonLine(missing),
                try jsonLine(nullValue),
                try jsonLine(unknownValue)
            ],
            screenshotExists: { _ in true }
        )

        #expect(hasIssue(report.issues, code: .missingRequiredField, field: "sceneIdHash"))
        #expect(hasIssue(report.issues, code: .nullRequiredField, field: "surfaceKey"))
        #expect(hasIssue(report.issues, code: .unknownRequiredField, field: "photoCanvasId"))
    }

    @Test
    func `non fallback geometry not filling the canvas hard fails`() throws {
        var empty = validRecord()
        empty["emptyCanvasRatio"] = 0.00000001

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

    @Test
    func `startup schema requires runtime clock fields and rejects invalid durations`() throws {
        var missingRuntimeTimestamps = startupFallbackRecord()
        missingRuntimeTimestamps.removeValue(forKey: "runtimePhaseTimestampsMs")

        var missingPhotoLoadTimestamps = startupFallbackRecord(
            sequence: 11,
            sceneIdHash: "startupScene011",
            screenshotPath: "/evidence/screenshots/seq-11-startupScene011.png"
        )
        missingPhotoLoadTimestamps.removeValue(forKey: "photoLoadPhaseTimestampsMs")

        var negativeFirstScene = startupFallbackRecord(
            sequence: 8,
            sceneIdHash: "startupScene008",
            screenshotPath: "/evidence/screenshots/seq-8-startupScene008.png"
        )
        negativeFirstScene["firstSceneRuntimeMs"] = -1

        var negativeFirstImageDisplayed = startupFallbackRecord(
            sequence: 12,
            sceneIdHash: "startupScene012",
            screenshotPath: "/evidence/screenshots/seq-12-startupScene012.png"
        )
        negativeFirstImageDisplayed["firstImageDisplayedRuntimeMs"] = -1

        var notDisplayed = startupFallbackRecord(
            sequence: 13,
            sceneIdHash: "startupScene013",
            screenshotPath: "/evidence/screenshots/seq-13-startupScene013.png"
        )
        notDisplayed["firstImageLoadStatus"] = "decoded"

        var missingFinalPhase = startupFallbackRecord(
            sequence: 9,
            sceneIdHash: "startupScene009",
            screenshotPath: "/evidence/screenshots/seq-9-startupScene009.png"
        )
        missingFinalPhase["startupMissingPhases"] = ["allVisibleSlotsReady"]

        let report = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            [
                try jsonLine(missingRuntimeTimestamps),
                try jsonLine(missingPhotoLoadTimestamps),
                try jsonLine(negativeFirstScene),
                try jsonLine(negativeFirstImageDisplayed),
                try jsonLine(notDisplayed),
                try jsonLine(missingFinalPhase)
            ],
            screenshotExists: { _ in true }
        )

        #expect(hasIssue(report.issues, code: .missingRequiredField, field: "runtimePhaseTimestampsMs"))
        #expect(hasIssue(report.issues, code: .missingRequiredField, field: "photoLoadPhaseTimestampsMs"))
        #expect(hasIssue(report.issues, code: .invalidStartupTiming, field: "firstSceneRuntimeMs"))
        #expect(hasIssue(report.issues, code: .invalidStartupTiming, field: "firstImageDisplayedRuntimeMs"))
        #expect(hasIssue(report.issues, code: .invalidStartupTiming, field: "firstImageLoadStatus"))
        #expect(hasIssue(report.issues, code: .invalidStartupTiming, field: "startupMissingPhases"))
    }

    @Test
    func `startup schema rejects first image shown before the first slot is ready`() throws {
        var firstImageBeforeFirstSlot = startupFallbackRecord(
            sequence: 14,
            sceneIdHash: "startupScene014",
            screenshotPath: "/evidence/screenshots/seq-14-startupScene014.png",
            firstSceneRuntimeMs: 20,
            firstSlotReadyRuntimeMs: 120,
            allVisibleSlotsReadyRuntimeMs: 160
        )
        firstImageBeforeFirstSlot["firstImageDisplayedRuntimeMs"] = 100

        let report = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            [try jsonLine(firstImageBeforeFirstSlot)],
            screenshotExists: { _ in true }
        )

        #expect(report.issues.map(\.field) == ["firstImageDisplayedRuntimeMs"])
        #expect(hasIssue(report.issues, code: .invalidStartupTiming, field: "firstImageDisplayedRuntimeMs"))
    }

    @Test
    func `startup schema allows small jitter between first image display and slot ready timestamps`() throws {
        var firstImageProbeJitter = startupFallbackRecord(
            sequence: 15,
            sceneIdHash: "startupScene015",
            screenshotPath: "/evidence/screenshots/seq-15-startupScene015.png",
            firstSceneRuntimeMs: 20,
            firstSlotReadyRuntimeMs: 120,
            allVisibleSlotsReadyRuntimeMs: 160
        )
        firstImageProbeJitter["firstImageDisplayedRuntimeMs"] = 115

        let report = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            [try jsonLine(firstImageProbeJitter)],
            screenshotExists: { _ in true }
        )

        #expect(report.issues.isEmpty)
    }

    @Test
    func `misclassification flags hard fail while an unknown root cause is only counted`() throws {
        var resourceMisclassified = startupFallbackRecord()
        resourceMisclassified["resourceReadinessAffectedFallback"] = true

        var controlBarMisclassified = startupFallbackRecord(
            sequence: 8,
            sceneIdHash: "startupScene008",
            screenshotPath: "/evidence/screenshots/seq-8-startupScene008.png"
        )
        controlBarMisclassified["controlBarAffectedFallback"] = true

        var legacyMisclassified = startupFallbackRecord(
            sequence: 9,
            sceneIdHash: "startupScene009",
            screenshotPath: "/evidence/screenshots/seq-9-startupScene009.png"
        )
        legacyMisclassified["legacyRendererUsedForSmartFillFallback"] = true

        var unknownRootCause = startupFallbackRecord(
            sequence: 10,
            sceneIdHash: "startupScene010",
            screenshotPath: "/evidence/screenshots/seq-10-startupScene010.png"
        )
        unknownRootCause["fallbackRootCauseBucket"] = "unknown"

        let report = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            [
                try jsonLine(resourceMisclassified),
                try jsonLine(controlBarMisclassified),
                try jsonLine(legacyMisclassified),
                try jsonLine(unknownRootCause)
            ],
            screenshotExists: { _ in true }
        )

        #expect(
            hasIssue(report.issues, code: .forbiddenFallbackRootCauseBucket, field: "resourceReadinessAffectedFallback")
        )
        #expect(hasIssue(report.issues, code: .forbiddenFallbackRootCauseBucket, field: "controlBarAffectedFallback"))
        #expect(
            hasIssue(
                report.issues, code: .forbiddenFallbackRootCauseBucket, field: "legacyRendererUsedForSmartFillFallback")
        )
        #expect(!hasIssue(report.issues, code: .forbiddenFallbackRootCauseBucket, field: "unknown"))
        #expect(report.fallbackRootCauseDistribution["unknown"] == 1)
    }

    @Test
    func `startup manifest rejects URL, API key, token, and raw asset id values`() throws {
        var urlRecord = startupFallbackRecord()
        urlRecord["diagnosticURL"] = "https://example.invalid/debug"

        var apiKeyRecord = startupFallbackRecord(
            sequence: 8,
            sceneIdHash: "startupScene008",
            screenshotPath: "/evidence/screenshots/seq-8-startupScene008.png"
        )
        apiKeyRecord["api_key"] = "abcd1234abcd1234"

        var rawAssetRecord = startupFallbackRecord(
            sequence: 9,
            sceneIdHash: "startupScene009",
            screenshotPath: "/evidence/screenshots/seq-9-startupScene009.png"
        )
        rawAssetRecord["assetId"] = "raw-asset-123"

        let report = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            [
                try jsonLine(urlRecord),
                try jsonLine(apiKeyRecord),
                try jsonLine(rawAssetRecord)
            ],
            screenshotExists: { _ in true }
        )

        #expect(hasIssue(report.issues, code: .forbiddenSensitiveValue, field: "diagnosticURL"))
        #expect(hasIssue(report.issues, code: .forbiddenSensitiveValue, field: "api_key"))
        #expect(hasIssue(report.issues, code: .forbiddenSensitiveValue, field: "assetId"))
    }

    @Test
    func `startup timing summary is derived from runtime clock fields`() throws {
        let lines = try [
            startupFallbackRecord(
                sequence: 1, sceneIdHash: "startupScene001",
                screenshotPath: "/evidence/screenshots/seq-1-startupScene001.png", firstSceneRuntimeMs: 20,
                firstSlotReadyRuntimeMs: 100, allVisibleSlotsReadyRuntimeMs: 120),
            startupFallbackRecord(
                sequence: 2, sceneIdHash: "startupScene002",
                screenshotPath: "/evidence/screenshots/seq-2-startupScene002.png", firstSceneRuntimeMs: 40,
                firstSlotReadyRuntimeMs: 160, allVisibleSlotsReadyRuntimeMs: 180),
            startupFallbackRecord(
                sequence: 3, sceneIdHash: "startupScene003",
                screenshotPath: "/evidence/screenshots/seq-3-startupScene003.png", firstSceneRuntimeMs: 80,
                firstSlotReadyRuntimeMs: 200, allVisibleSlotsReadyRuntimeMs: 240)
        ].map(jsonLine)

        let report = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            lines,
            screenshotExists: { _ in true }
        )

        #expect(report.issues.isEmpty)
        #expect(report.startupTimingSummary?.count == 3)
        #expect(report.startupTimingSummary?.firstSceneRuntimeP50Milliseconds == 40)
        #expect(report.startupTimingSummary?.firstSlotReadyRuntimeP95Milliseconds == 200)
        #expect(report.startupTimingSummary?.allVisibleSlotsReadyRuntimeMaxMilliseconds == 240)
    }

    @Test
    func `decision layer startup timing summary reuses the same runtime clock fields`() throws {
        let lines = try [
            decisionLayerRecord(
                sequence: 1, sceneIdHash: "smartFillScene001",
                screenshotPath: "/evidence/screenshots/seq-1-smartFillScene001.png", firstSceneRuntimeMs: 20,
                firstSlotReadyRuntimeMs: 100, allVisibleSlotsReadyRuntimeMs: 120),
            decisionLayerRecord(
                sequence: 2, sceneIdHash: "smartFillScene002",
                screenshotPath: "/evidence/screenshots/seq-2-smartFillScene002.png", firstSceneRuntimeMs: 40,
                firstSlotReadyRuntimeMs: 160, allVisibleSlotsReadyRuntimeMs: 180),
            decisionLayerRecord(
                sequence: 3, sceneIdHash: "smartFillScene003",
                screenshotPath: "/evidence/screenshots/seq-3-smartFillScene003.png", firstSceneRuntimeMs: 80,
                firstSlotReadyRuntimeMs: 200, allVisibleSlotsReadyRuntimeMs: 240)
        ].map(jsonLine)

        let report = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            lines,
            screenshotExists: { _ in true }
        )

        #expect(report.issues.isEmpty)
        #expect(report.startupTimingSummary?.count == 3)
        #expect(report.startupTimingSummary?.firstSceneRuntimeP50Milliseconds == 40)
        #expect(report.startupTimingSummary?.firstSlotReadyRuntimeP95Milliseconds == 200)
        #expect(report.startupTimingSummary?.allVisibleSlotsReadyRuntimeMaxMilliseconds == 240)
    }

    @Test
    func `photo load phase summary requires first image load chain fields`() throws {
        let record = startupFallbackRecord()
        let line = try jsonLine(record)
        let parsed = try parseJSONObject(line)
        let timestamps = try #require(parsed["photoLoadPhaseTimestampsMs"] as? [String: Any])
        let durations = try #require(parsed["photoLoadPhaseDurationsMs"] as? [String: Any])

        for phase in Self.requiredPhotoLoadPhaseKeys {
            #expect(timestamps[phase] != nil, "photoLoadPhaseTimestampsMs is missing \(phase)")
            #expect(durations[phase] != nil, "photoLoadPhaseDurationsMs is missing \(phase)")
        }
        #expect(parsed["firstPhotoCacheStatus"] as? String == "miss")
        #expect(parsed["firstImageDisplayedRuntimeMs"] as? Double == 170)
        #expect(parsed["firstImageLoadStatus"] as? String == "displayed")
    }

    @Test(.enabled(if: externalRuntimeJSONLEnabled))
    func externalRuntimeJSONLPassesValidator() throws {
        let path = try #require(Self.externalRuntimeJSONLPath)
        let payload = try String(contentsOfFile: path, encoding: .utf8)
        let lines =
            payload
            .split { $0.isNewline }
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let records = try lines.map(parseJSONObject)
        let report = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(lines)
        let phaseCompleteness = runtimePhaseKeyCompleteness(for: records)

        try writeExternalValidatorReport(
            report,
            jsonlPath: path,
            recordCount: records.count,
            phaseCompleteness: phaseCompleteness,
            to: Self.externalValidatorReportPath
        )

        #expect(report.recordsValidated == lines.count)
        #expect(report.issues.isEmpty)
        #expect(report.startupTimingSummary?.count == lines.count)
        #expect(phaseCompleteness == "complete")
        let acceptedSchemas = Set(["pr46-startup-fallback-v1", "pr49-decision-layer-v1"])
        #expect(
            records.allSatisfy { record in
                guard let schemaVersion = record["schemaVersion"] as? String else { return false }
                return acceptedSchemas.contains(schemaVersion)
            })
        #expect(records.allSatisfy { ($0["startupClockSource"] as? String) == "app-runtime" })
        #expect(records.allSatisfy { ($0["startupMissingPhases"] as? [Any])?.isEmpty == true })
    }

    @MainActor
    @Test
    func `runtime probe summary adds readiness and redacted ledger fields`() throws {
        let readyAsset = makeAsset(id: "asset-runtime-ready")
        let pendingAsset = makeAsset(id: "asset-runtime-pending")
        let scene = PlaybackScene(
            id: "scene-runtime",
            photoSlots: [
                PhotoSlot(id: "slot-ready", asset: readyAsset),
                PhotoSlot(id: "slot-pending", asset: pendingAsset)
            ],
            smartFillReadback: makeReadback()
        )
        let downloadManager = AssetsDownloadManager()
        downloadManager.assetStates[readyAsset.id] = .readyToPlay
        downloadManager.assetURLs[readyAsset.id] = URL(string: "https://example.invalid/fullsize.jpg")!
        downloadManager.assetStates[pendingAsset.id] = .notStarted

        let summary = try #require(
            scene.smartFillRuntimeQADebugSummary(
                downloadManager: downloadManager,
                controlBarVisible: true,
                exifOverlayVisible: false,
                publishReason: "manual-next",
                preparedHit: true
            ))

        #expect(summary.contains("slotReadiness=ready,pending"))
        #expect(summary.contains("ledgerSceneAssets=asset-"))
        #expect(summary.contains("controlBarVisible=true"))
        #expect(summary.contains("exifOverlayVisible=false"))
        #expect(summary.contains("publishReason=manual-next"))
        #expect(summary.contains("preparedHit=true"))
        #expect(!summary.contains(readyAsset.id))
        #expect(!summary.contains(pendingAsset.id))
    }

    private func validRecord(
        sequence: Int = 7,
        sceneIdHash: String = "sceneabc123",
        screenshotPath: String = "/evidence/screenshots/seq-7-sceneabc123.png",
        actionToSceneMs: Double = 42
    ) -> [String: Any] {
        [
            "schemaVersion": "runtime-evidence-v1",
            "runId": "runtime-evidence-unit",
            "prHead": "head-sha",
            "baseHead": "base-sha",
            "sequence": sequence,
            "sceneIdHash": sceneIdHash,
            "sceneType": "double",
            "isFallback": false,
            "fallbackReason": "none",
            "fallbackCategory": "none",
            "layoutVariant": "horizontalEqual",
            "layoutPreset": "50-50",
            "surfaceKey": "iPhone-landscape-compact-regular-safeA",
            "surfaceFingerprint": "iPhone-landscape-1179x2556-safeA",
            "photoCanvasId": "canvas-iPhone-landscape-1179x2556-safeA",
            "photoCanvasPointSize": ["width": 852, "height": 393],
            "photoCanvasPixelSize": ["width": 2556, "height": 1179],
            "canvasCoverage": 1.0,
            "emptyCanvasRatio": 0.0,
            "maxContinuousEmptyAxisRatio": 0.0,
            "gapPixelCount": 0,
            "overlapPixelCount": 0,
            "slotCount": 2,
            "slotFrames": [
                ["x": 0, "y": 0, "width": 0.5, "height": 1],
                ["x": 0.5, "y": 0, "width": 0.5, "height": 1]
            ],
            "slotCropRects": [
                ["x": 0, "y": 0, "width": 1, "height": 1],
                ["x": 0, "y": 0, "width": 1, "height": 1]
            ],
            "slotReadiness": ["ready", "pending"],
            "ledgerSceneAssets": ["asset-hash-a", "asset-hash-b"],
            "protectionOverlapDetails": "none",
            "controlBarVisible": true,
            "controlBarHardRejected": false,
            "controlBarSubjectOverlapWarning": false,
            "exifOverlayVisible": true,
            "exifOverlayHardRejected": false,
            "publishReason": "manual-next",
            "preparedHit": true,
            "actionToSceneMs": actionToSceneMs,
            "captureTimestamp": "2026-06-08T00:00:00Z",
            "screenshotPath": screenshotPath
        ]
    }

    private func startupFallbackRecord(
        sequence: Int = 7,
        sceneIdHash: String = "startupScene007",
        screenshotPath: String = "/evidence/screenshots/seq-7-startupScene007.png",
        firstSceneRuntimeMs: Double = 25,
        firstSlotReadyRuntimeMs: Double = 120,
        allVisibleSlotsReadyRuntimeMs: Double = 160
    ) -> [String: Any] {
        let firstImageDisplayedRuntimeMs = max(170, firstSlotReadyRuntimeMs + 10)
        var record = validRecord(
            sequence: sequence,
            sceneIdHash: sceneIdHash,
            screenshotPath: screenshotPath,
            actionToSceneMs: firstSceneRuntimeMs
        )
        record["schemaVersion"] = "pr46-startup-fallback-v1"
        record["startupRunId"] = "startup-run-hash"
        record["startupSequence"] = sequence
        record["startupClockSource"] = "app-runtime"
        record["runtimePhaseTimestampsMs"] = [
            "playbackEntryRequested": 0,
            "assetPoolRequestStarted": 5,
            "assetPoolReady": 10,
            "firstScenePlanningStarted": 12,
            "firstScenePlanned": 18,
            "firstScenePublished": firstSceneRuntimeMs,
            "firstSlotReady": firstSlotReadyRuntimeMs,
            "allVisibleSlotsReady": allVisibleSlotsReadyRuntimeMs
        ]
        record["runtimePhaseDurationsMs"] = [
            "playbackEntryToAssetPoolReady": 10,
            "planning": 6,
            "publishToFirstSlotReady": firstSlotReadyRuntimeMs - firstSceneRuntimeMs,
            "firstSlotToAllVisibleSlotsReady": allVisibleSlotsReadyRuntimeMs - firstSlotReadyRuntimeMs
        ]
        record["firstSceneRuntimeMs"] = firstSceneRuntimeMs
        record["firstSlotReadyRuntimeMs"] = firstSlotReadyRuntimeMs
        record["allVisibleSlotsReadyRuntimeMs"] = allVisibleSlotsReadyRuntimeMs
        record["startupMissingPhases"] = [String]()
        record["startupBlockingPhase"] = "firstSlotReady"
        record["assetPoolSizeAtFirstPlan"] = 60
        record["eligibleCandidateCountAtFirstPlan"] = 24
        record["plannerAttemptCountAtFirstPlan"] = 4
        record["candidateWindowUsedAtFirstPlan"] = 12
        record["firstSceneSlotReadiness"] = ["ready", "pending"]
        record["firstSceneReadySlotCount"] = 1
        record["firstScenePendingSlotCount"] = 1
        record["firstSceneFailedSlotCount"] = 0
        record["photoLoadPhaseTimestampsMs"] = [
            "cacheChecked": 80,
            "downloadRequestStarted": 90,
            "downloadCompleted": 140,
            "decodeCompleted": 150,
            "firstImageDisplayed": firstImageDisplayedRuntimeMs
        ]
        record["photoLoadPhaseDurationsMs"] = [
            "cacheChecked": 0,
            "downloadRequestStarted": 10,
            "downloadCompleted": 50,
            "decodeCompleted": 10,
            "firstImageDisplayed": firstImageDisplayedRuntimeMs - 150
        ]
        record["firstPhotoCacheStatus"] = "miss"
        record["firstImageDisplayedRuntimeMs"] = firstImageDisplayedRuntimeMs
        record["firstImageLoadStatus"] = "displayed"
        record["fallbackReasonTopList"] = ["none": 1]
        record["rejectedLayoutReasonTopList"] = ["none": 1]
        record["rejectedLayoutDiagnostics"] = ["none"]
        record["candidateRejectReasonTopList"] = ["none": 1]
        record["lookaheadExhausted"] = false
        record["resourceReadinessAffectedFallback"] = false
        record["controlBarAffectedFallback"] = false
        record["legacyRendererUsedForSmartFillFallback"] = false
        record["fallbackRootCauseBucket"] = "none"
        return record
    }

    private func decisionLayerRecord(
        sequence: Int = 7,
        sceneIdHash: String = "smartFillScene007",
        screenshotPath: String = "/evidence/screenshots/seq-7-smartFillScene007.png",
        firstSceneRuntimeMs: Double = 42,
        firstSlotReadyRuntimeMs: Double = 100,
        allVisibleSlotsReadyRuntimeMs: Double = 120
    ) -> [String: Any] {
        var record = startupFallbackRecord(
            sequence: sequence,
            sceneIdHash: sceneIdHash,
            screenshotPath: screenshotPath,
            firstSceneRuntimeMs: firstSceneRuntimeMs,
            firstSlotReadyRuntimeMs: firstSlotReadyRuntimeMs,
            allVisibleSlotsReadyRuntimeMs: allVisibleSlotsReadyRuntimeMs
        )
        record["schemaVersion"] = "pr49-decision-layer-v1"
        record["currentAssetRef"] = "asset-hash-a"
        record["currentAssetDisposition"] = "primary-slot"
        record["currentAssetAbsentReason"] = "none"
        record["currentAssetSlotAreaRatio"] = 0.5
        record["currentAssetCropRetention"] = 0.8
        record["currentAssetProtectedRegionCoverage"] = 1.0
        record["currentAssetFaceProtectionPassed"] = true
        record["currentAssetSubjectProtectionPassed"] = true
        record["currentAssetVisibleQualityClass"] = "acceptable"
        record["slotRoles"] = ["primary", "secondary"]
        record["slotRefs"] = ["asset-hash-a", "asset-hash-b"]
        record["candidateWindowRequested"] = 24
        record["candidateWindowUsed"] = 24
        record["candidateWindowExpansionTrace"] = ["24:accepted"]
        record["candidateRejectReasonTopList"] = ["none": 1]
        record["acceptedSceneSearchTier"] = "double"
        record["plannerAttemptCountAtFirstPlan"] = 1
        record["recentVisibleLimit"] = 12
        record["recentVisibleCandidateCount"] = 2
        record["duplicateVisibleSlotCount"] = 0
        record["duplicateVisibleSlotRefs"] = [String]()
        record["duplicateReuseReason"] = "none"
        record["multiSlotSuccessCount"] = 1
        record["smartFillSingleFillCount"] = 0
        record["singleRiskCount"] = 0
        record["hardFallbackCount"] = 0
        record["nonMultiSlotOutcomeCount"] = 0
        record["userPerceivedFailureCount"] = 0
        record["currentAssetAbsentSceneCount"] = 0
        record["visualUnverifiedCount"] = 0
        record["unknownOutcomeBucketCount"] = 0
        record["visualReviewStatus"] = "REVIEWED_PASS"
        return record
    }

    private func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func parseJSONObject(_ line: String) throws -> [String: Any] {
        let data = Data(line.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private func runtimePhaseKeyCompleteness(for records: [[String: Any]]) -> String {
        let missingCount = records.reduce(0) { partialResult, record in
            let timestamps = record["runtimePhaseTimestampsMs"] as? [String: Any] ?? [:]
            let durations = record["runtimePhaseDurationsMs"] as? [String: Any] ?? [:]
            let missingPhases = Self.requiredStartupPhaseKeys.filter { phase in
                timestamps[phase] == nil || durations[phase] == nil
            }
            return partialResult + missingPhases.count
        }
        return missingCount == 0 ? "complete" : "missingPhaseCount=\(missingCount)"
    }

    private func writeExternalValidatorReport(
        _ report: PlaybackRuntimeEvidenceManifestValidationReport,
        jsonlPath: String,
        recordCount: Int,
        phaseCompleteness: String,
        to path: String?
    ) throws {
        guard let path,
            !path.isEmpty
        else {
            return
        }
        let summary = report.startupTimingSummary
        var lines = [
            "runtimeJSONLPath=\(jsonlPath)",
            "recordCount=\(recordCount)",
            "recordsValidated=\(report.recordsValidated)",
            "issueCount=\(report.issues.count)",
            "runtimePhaseKeyCompleteness=\(phaseCompleteness)",
            "fallbackDistribution=\(formatDistribution(report.fallbackDistribution))",
            "fallbackRootCauseDistribution=\(formatDistribution(report.fallbackRootCauseDistribution))",
            "startupTimingCount=\(summary?.count ?? 0)",
            "firstSceneRuntimeP50Ms=\(format(summary?.firstSceneRuntimeP50Milliseconds))",
            "firstSlotReadyRuntimeP95Ms=\(format(summary?.firstSlotReadyRuntimeP95Milliseconds))",
            "allVisibleSlotsReadyRuntimeMaxMs=\(format(summary?.allVisibleSlotsReadyRuntimeMaxMilliseconds))"
        ]
        if report.issues.isEmpty {
            lines.append("issues=none")
        } else {
            lines.append("issues=\(report.issues.map(formatIssue).joined(separator: "|"))")
        }

        let reportURL = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: reportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (lines.joined(separator: "\n") + "\n").write(to: reportURL, atomically: true, encoding: .utf8)
    }

    private func formatDistribution(_ distribution: [String: Int]) -> String {
        distribution
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ";")
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "missing" }
        return String(format: "%.3f", value)
    }

    private func formatIssue(_ issue: PlaybackRuntimeEvidenceManifestValidationIssue) -> String {
        "\(issue.code.rawValue):\(issue.field):\(issue.message)"
    }

    private func hasIssue(
        _ issues: [PlaybackRuntimeEvidenceManifestValidationIssue],
        code: PlaybackRuntimeEvidenceManifestValidationIssue.Code,
        field: String
    ) -> Bool {
        issues.contains { issue in
            issue.code == code && issue.field == field
        }
    }

    private func makeReadback() -> PlaybackSmartFillSceneReadback {
        PlaybackSmartFillSceneReadback(
            version: "smart-fill-scene-v2",
            sceneType: .double,
            layoutPolicyId: "iphone-landscape-v2",
            surfaceKey: "iPhone-landscape-regular-compact-safeA",
            layoutVariant: .horizontalEqual,
            ratioPreset: "50/50",
            slotRoles: [.primary, .secondary],
            fallbackReason: nil,
            fallbackCategory: .none,
            reasonCodes: ["scene:double"],
            qaDebugSummary: [
                "version=smart-fill-planner-v2",
                "sceneType=double",
                "surfaceKey=iPhone-landscape-regular-compact-safeA",
                "fallbackCategory=none"
            ].joined(separator: ";")
        )
    }

    private func makeAsset(id: String) -> Asset {
        Asset(
            id: id,
            type: "IMAGE",
            isFavorite: false,
            isTrashed: false,
            isArchived: false,
            exifInfo: nil,
            people: nil,
            tags: nil,
            livePhotoVideoID: nil,
            width: 1600,
            height: 900
        )
    }
}
