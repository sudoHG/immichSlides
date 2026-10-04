import Foundation
import Testing
@testable import immichSlides

extension PlaybackRuntimeEvidenceManifestTests {
    func validRecord(
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

    func startupFallbackRecord(
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
        record["schemaVersion"] = "startup-fallback-v1"
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
            "playbackEntryRequested": 0,
            "assetPoolRequestStarted": 5,
            "assetPoolReady": 5,
            "firstScenePlanningStarted": 2,
            "firstScenePlanned": 6,
            "firstScenePublished": max(0, firstSceneRuntimeMs - 18),
            "firstSlotReady": max(0, firstSlotReadyRuntimeMs - firstSceneRuntimeMs),
            "allVisibleSlotsReady": max(0, allVisibleSlotsReadyRuntimeMs - firstSlotReadyRuntimeMs)
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

    func decisionLayerRecord(
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
        record["schemaVersion"] = "decision-layer-v1"
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

    func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    func parseJSONObject(_ line: String) throws -> [String: Any] {
        let data = Data(line.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    func runtimePhaseKeyCompleteness(for records: [[String: Any]]) -> String {
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

    func writeExternalValidatorReport(
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

    func formatDistribution(_ distribution: [String: Int]) -> String {
        distribution
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ";")
    }

    func format(_ value: Double?) -> String {
        guard let value else { return "missing" }
        return String(format: "%.3f", value)
    }

    func formatIssue(_ issue: PlaybackRuntimeEvidenceManifestValidationIssue) -> String {
        "\(issue.code.rawValue):\(issue.field):\(issue.message)"
    }

    func hasIssue(
        _ issues: [PlaybackRuntimeEvidenceManifestValidationIssue],
        code: PlaybackRuntimeEvidenceManifestValidationIssue.Code,
        field: String
    ) -> Bool {
        issues.contains { issue in
            issue.code == code && issue.field == field
        }
    }

    func makeReadback() -> PlaybackSmartFillSceneReadback {
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

    func makeAsset(id: String) -> Asset {
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
