import Foundation
import Testing
@testable import immichSlides

extension PlaybackSmartFillPlannerTests {
    @Test
    func `double selects a partner within the 24-candidate window without loosening thresholds`() {
        let badSecondaries = (1...12).map { index in
            candidate(
                reference: "bad-\(index)",
                width: 200,
                height: 6000
            )
        }
        let result = plan(
            surface: iPadLandscapeSurface,
            candidates: [
                candidate(reference: "primary", width: 1800, height: 2000)
            ] + badSecondaries + [
                candidate(reference: "readable-13", width: 1800, height: 2000)
            ]
        )

        #expect(result.sceneType == .double)
        #expect(result.candidateWindowUsed == 24)
        #expect(result.slots.map(\.candidateReference) == ["primary", "readable-13"])
        #expect(result.rejectReasonsTried.contains(.effectivePixelsTooLow))
        #expect(result.slots.allSatisfy { $0.cropRetention >= 0.60 })
    }

    @Test
    func `iPhone portrait does not skip an unrenderable current photo to reach a later legal single fill`() {
        let badPrimaryRun = (0..<8).map { index in
            candidate(
                reference: "wide-\(index)",
                width: 6000,
                height: 1800
            )
        }
        let result = plan(
            surface: phonePortraitSurface,
            candidates: badPrimaryRun + [
                candidate(reference: "portrait-fit", width: 1200, height: 2400)
            ]
        )

        #expect(result.sceneType == .fallback)
        #expect(result.fallbackReason == .allLayoutsRejected)
        #expect(result.slots.map(\.candidateReference) == ["wide-0"])
        #expect(result.currentAssetDisposition == .fallbackCurrent)
        #expect(result.currentAssetAbsentReason == .none)
        #expect(result.currentAssetVisibleQualityClass == .fail)
        #expect(result.rejectReasonsTried.contains(.cropRetentionTooLow))
    }

    @Test
    func `iPhone portrait keeps current as primary using a narrow preset once double now fits`() {
        let result = plan(
            surface: phonePortraitSurface,
            candidates: [
                candidate(reference: "current-landscape", width: 5400, height: 3000),
                candidate(reference: "later-primary", width: 1800, height: 2000)
            ]
        )

        #expect(result.sceneType == .double)
        #expect(result.fallbackReason == nil)
        #expect(result.slots.map(\.candidateReference) == ["current-landscape", "later-primary"])
        #expect(result.currentAssetDisposition == .primarySlot)
        #expect(result.currentAssetAbsentReason == .none)
        #expect(result.currentAssetVisibleQualityClass == .acceptable)
        #expect(result.ledgerSceneAssets == ["current-landscape", "later-primary"])
        #expect(result.slotRefs == ["current-landscape", "later-primary"])
        #expect(result.slotRoles == [.primary, .secondary])
        #expect(result.slots.allSatisfy { $0.cropRetention >= 0.70 })
        #expect(result.acceptedRatioPreset.hasPrefix("constructive-"))
        #expect(result.rejectReasonsTried.contains(.cropRetentionTooLow))
    }

    @Test
    func `iPhone portrait uses a narrow primary preset within the same renderer to keep a wide current photo visible`()
    {
        let result = plan(
            surface: phonePortraitSurface,
            candidates: [
                candidate(reference: "current-wide", width: 1920, height: 1080),
                candidate(reference: "secondary-portrait", width: 1200, height: 1800)
            ]
        )

        #expect(result.sceneType == .double)
        #expect(result.fallbackReason == nil)
        #expect(result.currentAssetDisposition == .primarySlot)
        #expect(result.slots.map(\.candidateReference) == ["current-wide", "secondary-portrait"])
        #expect(result.acceptedRatioPreset.hasPrefix("constructive-"))
        #expect(result.slots.allSatisfy { $0.cropRetention >= 0.70 })
        #expect(result.currentAssetVisibleQualityClass == .acceptable)
    }

    @Test
    func `iPad landscape keeps trying a third slot when the current photo's second slot is hard-blocked`() throws {
        let topHardObstruction = PlaybackProtectionSnapshot(regions: [
            try #require(
                PlaybackProtectionRegion.systemTopObstruction(
                    rect: PlaybackProtectionRect(x: 0, y: 0, width: 1, height: 0.48),
                    activeConditionSummary: "unit-test-top-hard-obstruction"
                ))
        ])
        let currentTopSubject = PlaybackPlanningRect(x: 0.44, y: 0.20, width: 0.12, height: 0.08)
        let result = plan(
            surface: iPadLandscapeSurface,
            candidates: [
                candidate(
                    reference: "current-secondary-blocked",
                    width: 1800,
                    height: 2000,
                    faceRects: [currentTopSubject]
                ),
                candidate(reference: "promoted-primary", width: 1600, height: 2400),
                candidate(reference: "extra-auxiliary", width: 2000, height: 1800)
            ],
            protectionSnapshot: topHardObstruction
        )

        #expect(result.sceneType == .triple)
        #expect(result.slots.map(\.candidateReference).contains("current-secondary-blocked"))
        #expect(result.currentAssetDisposition == .tertiarySlot)
        #expect(result.currentAssetVisibleQualityClass == .acceptable)
        #expect(result.protectionSummary.status == .accepted)
        #expect(result.slots.allSatisfy { $0.cropRetention >= 0.70 })
        #expect(result.rejectReasonsTried.contains(.protectionOverlap))
    }

    @Test
    func `triple's normal search never exhausts the reserved budget for evaluating current as auxiliary`() throws {
        let policy = PlaybackSmartFillLayoutPolicy.policy(for: iPadLandscapeSurface)
        let topHardObstruction = PlaybackProtectionSnapshot(regions: [
            try #require(
                PlaybackProtectionRegion.systemTopObstruction(
                    rect: PlaybackProtectionRect(x: 0, y: 0, width: 1, height: 0.48),
                    activeConditionSummary: "unit-test-top-hard-obstruction"
                ))
        ])
        let blockers = (1...70).map { index in
            candidate(
                reference: "budget-blocker-\(index)",
                width: 90,
                height: 100
            )
        }

        let result = plan(
            surface: iPadLandscapeSurface,
            candidates: [
                candidate(
                    reference: "current-secondary-blocked-budget",
                    width: 1800,
                    height: 2000,
                    faceRects: [PlaybackPlanningRect(x: 0.44, y: 0.20, width: 0.12, height: 0.08)]
                ),
                candidate(
                    reference: "promoted-primary-budget", width: 1600, height: 2400
                ),
                candidate(reference: "extra-auxiliary-budget", width: 2000, height: 1800)
            ] + blockers,
            protectionSnapshot: topHardObstruction
        )

        #expect(policy.currentAuxiliaryEvaluationReserve == 2_000)
        #expect(result.sceneType == .triple)
        #expect(result.currentAssetDisposition == .tertiarySlot)
        #expect(result.slots.map(\.candidateReference).contains("current-secondary-blocked-budget"))
        #expect(result.evaluationCount <= policy.evaluationBudget)
        #expect(result.rejectReasonsTried.contains(.candidateWindowExhausted))
        #expect(result.currentAssetVisibleQualityClass == .acceptable)
    }

    @Test
    func `the current asset is never skipped for a later multi-slot layout it cannot legally join`() {
        let result = plan(
            surface: phonePortraitSurface,
            candidates: [
                candidate(reference: "current-too-wide", width: 9000, height: 1200),
                candidate(reference: "later-a", width: 1800, height: 2000),
                candidate(reference: "later-b", width: 1800, height: 2000)
            ]
        )

        #expect(result.sceneType != .double || result.slots.map(\.candidateReference).contains("current-too-wide"))
        #expect(result.currentAssetDisposition != .absentHardFail)
        #expect(
            result.currentAssetAbsentReason != .none
                || result.slots.map(\.candidateReference).contains("current-too-wide"))
    }

    @Test
    func `iPad landscape uses triple only after single and double are rejected`() {
        let result = plan(
            surface: iPadLandscapeSurface,
            candidates: [
                candidate(reference: "primary", width: 1800, height: 2000),
                candidate(reference: "wide-secondary", width: 2600, height: 2000),
                candidate(reference: "wide-tertiary", width: 2600, height: 2000)
            ]
        )

        #expect(result.sceneType == .triple)
        #expect(result.slots.map(\.candidateReference) == ["primary", "wide-secondary", "wide-tertiary"])
        #expect(result.rejectReasonsTried.contains(.cropRetentionTooLow))
        #expect(result.layoutVariant.isTriple)
        #expect(result.slots.allSatisfy { $0.cropRetention >= 0.60 })
    }

    @Test
    func
        `stable rotation is deterministic for the same input and sensitive to scene ordinal, not render count or randomness`()
    {
        let candidates = [
            candidate(reference: "primary", width: 1800, height: 2000),
            candidate(reference: "secondary-a", width: 1800, height: 2000),
            candidate(reference: "secondary-b", width: 1800, height: 2000)
        ]
        let first = plan(surface: phonePortraitSurface, candidates: candidates, seed: "session-a", sceneOrdinal: 7)
        let repeated = plan(surface: phonePortraitSurface, candidates: candidates, seed: "session-a", sceneOrdinal: 7)
        let nextOrdinal = plan(
            surface: phonePortraitSurface, candidates: candidates, seed: "session-a", sceneOrdinal: 8)

        #expect(first.rotationKeyHashPrefix == repeated.rotationKeyHashPrefix)
        #expect(first.rotationStartLayoutVariant == repeated.rotationStartLayoutVariant)
        #expect(first.rotationStartRatioPreset == repeated.rotationStartRatioPreset)
        #expect(first.acceptedLayoutVariant == repeated.acceptedLayoutVariant)
        #expect(first.acceptedRatioPreset == repeated.acceptedRatioPreset)
        #expect(first.rotationKeyHashPrefix != nextOrdinal.rotationKeyHashPrefix)
    }

    @Test
    func `readback summary contains the spec's fields and redacts the raw asset id`() {
        let result = plan(
            surface: phonePortraitSurface,
            candidates: [
                candidate(reference: "asset_abcd1234", width: 1800, height: 2000),
                candidate(reference: "asset_efgh5678", width: 1800, height: 2000)
            ]
        )
        let summary = result.qaDebugSummary

        for field in [
            "surfaceKey=",
            "layoutVariant=",
            "ratioPreset=",
            "slotFrames=",
            "slotCropRects=",
            "surfaceFingerprint=",
            "photoCanvasId=",
            "photoCanvasPointSize=",
            "photoCanvasPixelSize=",
            "canvasCoverage=",
            "emptyCanvasRatio=",
            "maxContinuousEmptyAxisRatio=",
            "gapPixelCount=",
            "overlapPixelCount=",
            "cropRetention=",
            "protectionContained=",
            "candidateWindowUsed=",
            "evaluationCount=",
            "rotationStartLayoutVariant=",
            "rotationStartRatioPreset=",
            "acceptedLayoutVariant=",
            "acceptedRatioPreset=",
            "rotationKeyHashPrefix=",
            "rejectedLayoutReasonTopList="
        ] {
            #expect(summary.contains(field))
        }
        #expect(!summary.contains("asset-raw-secret-primary"))
        #expect(!summary.localizedCaseInsensitiveContains("http" + "://"))
        #expect(!summary.localizedCaseInsensitiveContains("https" + "://"))
        #expect(!summary.localizedCaseInsensitiveContains("tok" + "en"))
    }

    @Test
    func `surfaceKey normalizes 1px jitter`() {
        let surface = PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(width: 1179, height: 2556),
            profile: .iPhone,
            orientation: .portrait,
            safeAreaClass: "safeA"
        )
        let jittered = PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(width: 1180, height: 2555),
            profile: .iPhone,
            orientation: .portrait,
            safeAreaClass: "safeA"
        )

        #expect(surface.surfaceKey == "iPhone-portrait-compact-regular-safeA")
        #expect(surface == jittered)
    }

    @Test
    func `internal surface identity distinguishes meaningful iPad size changes without changing the readback key`() {
        let fullSize = PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(width: 2732, height: 2048),
            profile: .iPad,
            orientation: .landscape,
            safeAreaClass: "safeA"
        )
        let sameOrientationDifferentSize = PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(width: 2048, height: 1536),
            profile: .iPad,
            orientation: .landscape,
            safeAreaClass: "safeA"
        )
        let onePixelJitter = PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(width: 2733, height: 2047),
            profile: .iPad,
            orientation: .landscape,
            safeAreaClass: "safeA"
        )
        let differentSafeAreaClass = PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(width: 2732, height: 2048),
            profile: .iPad,
            orientation: .landscape,
            safeAreaClass: "safeB"
        )

        #expect(fullSize.surfaceKey == sameOrientationDifferentSize.surfaceKey)
        #expect(fullSize.internalSurfaceFingerprint != sameOrientationDifferentSize.internalSurfaceFingerprint)
        #expect(fullSize.internalSurfaceFingerprint == onePixelJitter.internalSurfaceFingerprint)
        #expect(fullSize != sameOrientationDifferentSize)
        #expect(fullSize == onePixelJitter)
        #expect(fullSize != differentSafeAreaClass)
    }

    @Test
    func `control bar covering the upper body only records a QA warning without triggering fallback`() throws {
        let bottomFace = PlaybackPlanningRect(x: 0.42, y: 0.78, width: 0.16, height: 0.10)
        let protection = PlaybackProtectionSnapshot(regions: [
            try #require(
                PlaybackProtectionRegion.controlBar(
                    rect: PlaybackProtectionRect(x: 0, y: 0.82, width: 1, height: 0.18),
                    activeConditionSummary: "visible"
                ))
        ])

        let result = plan(
            surface: phoneLandscapeSurface,
            candidates: [
                candidate(
                    reference: "bottom-face",
                    width: 4336,
                    height: 2000,
                    faceRects: [bottomFace]
                )
            ],
            protectionSnapshot: protection
        )

        #expect(result.sceneType == .single)
        #expect(result.acceptedSceneSearchTier == .singleFill)
        #expect(result.currentAssetVisibleQualityClass == .acceptable)
        #expect(result.fallbackReason == nil)
        #expect(result.fallbackCategory == .none)
        #expect(!result.rejectReasonsTried.contains(.protectionOverlap))
        #expect(result.protectionSummary.status == .accepted)
        #expect(result.protectionSummary.controlBarSubjectOverlapWarningCount > 0)
        #expect(!result.protectionSummary.controlBarHardRejected)
    }

    @Test
    func `EXIF overlay covering the upper body only records a QA warning without triggering fallback`() throws {
        let rightFace = PlaybackPlanningRect(x: 0.75, y: 0.22, width: 0.12, height: 0.10)
        let protection = PlaybackProtectionSnapshot(regions: [
            try #require(
                PlaybackProtectionRegion.exifPanel(
                    isShowingExif: true,
                    hasExifContent: true,
                    frame: PlaybackProtectionRect(x: 0.70, y: 0.20, width: 0.25, height: 0.28)
                ))
        ])

        let result = plan(
            surface: phoneLandscapeSurface,
            candidates: [
                candidate(
                    reference: "exif-face",
                    width: 4336,
                    height: 2000,
                    faceRects: [rightFace]
                )
            ],
            protectionSnapshot: protection
        )

        #expect(result.sceneType == .single)
        #expect(result.acceptedSceneSearchTier == .singleFill)
        #expect(result.currentAssetVisibleQualityClass == .acceptable)
        #expect(result.fallbackReason == nil)
        #expect(result.fallbackCategory == .none)
        #expect(!result.rejectReasonsTried.contains(.protectionOverlap))
        #expect(result.protectionSummary.status == .accepted)
        #expect(result.protectionSummary.exifOverlayOverlapWarningCount > 0)
        #expect(!result.protectionSummary.exifOverlayHardRejected)
    }

    @Test
    func `fallback category splits into legal, layout and pending, and writes reason codes`() {
        let missingCandidates = plan(surface: phonePortraitSurface, candidates: [])
        #expect(missingCandidates.sceneType == .fallback)
        #expect(missingCandidates.fallbackCategory == .legalFallback)
        #expect(missingCandidates.reasonCodes.contains("fallbackCategory:legal-fallback"))
        #expect(missingCandidates.qaDebugSummary.contains("fallbackCategory=legal-fallback"))

        let lowResolution = plan(
            surface: phoneLandscapeSurface,
            candidates: [
                candidate(reference: "lowres", width: 800, height: 400)
            ]
        )
        #expect(lowResolution.sceneType == .fallback)
        #expect(lowResolution.fallbackCategory == .layoutReject)
        #expect(lowResolution.reasonCodes.contains("fallbackCategory:layout-reject"))

        let pending = PlaybackSmartFillFallbackCategory.classify(
            fallbackReason: .imageNotReady,
            rejectReasons: [.imageNotReady],
            protectionSummary: .accepted
        )
        #expect(pending == .pendingResourceTriggered)
    }

    @Test
    func `a layout is hard rejected when cropped effective pixels fall below 0.85x of the display area`() {
        let result = plan(
            surface: phoneLandscapeSurface,
            candidates: [
                candidate(reference: "lowres", width: 800, height: 400)
            ]
        )

        #expect(result.sceneType == .fallback)
        #expect(result.fallbackReason == .allLayoutsRejected)
        #expect(result.fallbackCategory == .layoutReject)
        #expect(result.rejectReasonsTried.contains(.effectivePixelsTooLow))
    }

    @Test
    func
        `constructive double search only tries the closest-ratio top-K partners and never reaches a late valid partner`()
    {
        let nearButLowResolutionPartners = (1...12).map { index in
            candidate(
                reference: "near-lowres-\(index)",
                width: 90,
                height: 100
            )
        }
        let lateValidPartner = candidate(
            reference: "late-valid",
            width: 1800,
            height: 2000
        )

        let result = plan(
            surface: iPadLandscapeSurface,
            candidates: [
                candidate(reference: "current-tall", width: 1800, height: 4286)
            ] + nearButLowResolutionPartners + [lateValidPartner]
        )

        #expect(result.sceneType == .fallback)
        #expect(!result.slots.map(\.candidateReference).contains("late-valid"))
        #expect(result.rejectReasonsTried.contains(.effectivePixelsTooLow))
    }

    @Test
    func `the planner's evaluation budget caps adversarial fallback work within a single plan call`() {
        let candidates = benchmarkCandidates(
            surface: iPadLandscapeSurface,
            sceneIndex: 23
        )

        let result = plan(
            surface: iPadLandscapeSurface,
            candidates: candidates,
            seed: "planner-perf-baseline-v1",
            sceneOrdinal: 23
        )

        #expect(result.sceneType == .fallback)
        #expect(result.evaluationCount <= 4000)
        #expect(result.rejectReasonsTried.contains(.candidateWindowExhausted))
    }

    @Test
    func `planner's pure computation stays bounded for a 21-candidate workload`() {
        let candidates =
            [
                candidate(reference: "primary", width: 1800, height: 2000)
            ]
            + (1...20).map {
                candidate(reference: "candidate-\($0)", width: 1800, height: 2000)
            }
        let start = ContinuousClock.now
        var maxEvaluationCount = 0

        for ordinal in 0..<250 {
            let result = plan(
                surface: iPadLandscapeSurface,
                candidates: candidates,
                seed: "perf",
                sceneOrdinal: ordinal
            )
            maxEvaluationCount = max(maxEvaluationCount, result.evaluationCount)
        }

        #expect(maxEvaluationCount <= 4000)
        // Wall-clock budgets depend on the machine, so only Evidence runs judge them.
        if isEvidenceRun {
            #expect(start.duration(to: .now) < .milliseconds(900))
        }
    }
}
