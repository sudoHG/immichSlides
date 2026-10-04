import Foundation
import Testing
@testable import immichSlides

extension PlaybackRuntimeEvidenceManifestTests {
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

        let report = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            [line], screenshotExists: { _ in true }
        )
        #expect(report.issues.isEmpty)
        var missingDurations = record
        missingDurations.removeValue(forKey: "photoLoadPhaseDurationsMs")
        let missingReport = PlaybackRuntimeEvidenceManifestValidator.validateJSONLines(
            [try jsonLine(missingDurations)], screenshotExists: { _ in true }
        )
        #expect(hasIssue(missingReport.issues, code: .missingRequiredField, field: "photoLoadPhaseDurationsMs"))
    }

    @Test(.enabled(if: isExternalRuntimeJSONLEnabled))
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
        let acceptedSchemas = Set(["startup-fallback-v1", "decision-layer-v1"])
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
        let traceRefs = scene.diagnosticSlotReferences(separator: "|")
        #expect(summary.contains("slotRefs=\(traceRefs.replacingOccurrences(of: "|", with: ","))"))
        #expect(traceRefs.split(separator: "|").count == 2)
        #expect(!traceRefs.contains(readyAsset.id))
        #expect(!traceRefs.contains(pendingAsset.id))
        #expect(summary.contains("controlBarVisible=true"))
        #expect(summary.contains("exifOverlayVisible=false"))
        #expect(summary.contains("publishReason=manual-next"))
        #expect(summary.contains("preparedHit=true"))
        #expect(!summary.contains(readyAsset.id))
        #expect(!summary.contains(pendingAsset.id))
    }
}
