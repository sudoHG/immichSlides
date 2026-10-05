import Foundation
import XCTest

#if os(iOS)
extension PlaybackSmartFillVisualUITests {
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
        XCTAssertEqual(record["schemaVersion"] as? String, "decision-layer-v1")
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
extension PlaybackSmartFillVisualUITests {

}
#endif
