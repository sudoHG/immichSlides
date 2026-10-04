import Foundation
import Testing
@testable import immichSlides

extension PlaybackSmartFillPlannerTests {
    @Test
    func `iPad and Apple TV fall back to a legal multi-slot layout only when single fill does not qualify`() {
        let entries: [(surface: PlaybackSmartFillSurface, primary: PlaybackSmartFillCandidateSummary)] = [
            (
                iPadLandscapeSurface,
                candidate(reference: "ipad-primary", width: 1800, height: 2000)
            ),
            (
                appleTVSurface,
                candidate(reference: "tv-primary", width: 2000, height: 2000)
            )
        ]

        for entry in entries {
            let result = plan(
                surface: entry.surface,
                candidates: [
                    entry.primary,
                    candidate(reference: "secondary-a", width: 1800, height: 2000),
                    candidate(reference: "secondary-b", width: 2000, height: 2000)
                ]
            )

            #expect(result.sceneType == .double)
            #expect(result.slots.count >= 2)
            #expect(result.slots.map(\.candidateReference).contains(entry.primary.reference))
            #expect(result.acceptedSceneSearchTier == .double)
            #expect(result.slots.allSatisfy { $0.cropRetention >= 0.70 })
            #expect(result.currentAssetVisibleQualityClass == .acceptable)
        }
    }

    @Test
    func `iPad and Apple TV prefer a qualified single fill over multi-slot layouts`() {
        let entries: [(surface: PlaybackSmartFillSurface, primary: PlaybackSmartFillCandidateSummary)] = [
            (
                iPadLandscapeSurface,
                candidate(reference: "ipad-landscape-primary", width: 2400, height: 2000)
            ),
            (
                appleTVSurface,
                candidate(reference: "tv-landscape-primary", width: 3708, height: 2400)
            )
        ]

        for entry in entries {
            let result = plan(
                surface: entry.surface,
                candidates: [
                    entry.primary,
                    candidate(reference: "secondary-a", width: 1800, height: 2000),
                    candidate(reference: "secondary-b", width: 2000, height: 2000)
                ]
            )

            #expect(result.sceneType == .single)
            #expect(result.slots.map(\.candidateReference) == [entry.primary.reference])
            #expect(result.acceptedSceneSearchTier == .singleFill)
            #expect((result.currentAssetCropRetention ?? 0) >= 0.70)
            #expect(result.currentAssetVisibleQualityClass == .acceptable)
        }
    }

    @Test
    func `on Apple TV, a near-landscape single fill biases cropping to keep headroom and trim more from the bottom`() {
        let upperFace = PlaybackPlanningRect(x: 0.46, y: 0.16, width: 0.10, height: 0.07)
        let result = plan(
            surface: appleTVSurface,
            candidates: [
                candidate(
                    reference: "tv-near-landscape-upper-face",
                    width: 3708,
                    height: 2400,
                    faceRects: [upperFace]
                )
            ]
        )

        let slot = result.slots.first
        #expect(result.sceneType == .single)
        #expect(result.acceptedSceneSearchTier == .singleFill)
        #expect(slot?.protectionContained == true)
        #expect((slot?.cropRetention ?? 0) >= 0.70)
        #expect((slot?.cropRectInSource.y ?? 1) <= 0.001)
        #expect((slot?.cropRectInSource.height ?? 0) < 1)
        #expect(result.currentAssetVisibleQualityClass == .acceptable)
    }

    @Test
    func `single fill falls back to double only below 70% crop retention, and keeps the primary photo`() {
        let result = plan(
            surface: phonePortraitSurface,
            candidates: [
                candidate(reference: "current", width: 1800, height: 2000),
                candidate(reference: "secondary", width: 1800, height: 2000)
            ]
        )

        #expect(result.sceneType == .double)
        #expect(result.slots.map(\.candidateReference).first == "current")
        #expect(result.rejectReasonsTried.contains(.cropRetentionTooLow))
        #expect(result.slots.allSatisfy { $0.cropRetention >= 0.70 })
        #expect(result.slots.allSatisfy { $0.protectionContained })
    }

    @Test
    func `iPhone allows 60% crop retention to avoid falling back on consecutive landscape photos`() {
        let result = plan(
            surface: phonePortraitSurface,
            candidates: [
                candidate(reference: "current-landscape", width: 2400, height: 1600),
                candidate(reference: "secondary-landscape", width: 2400, height: 1600)
            ]
        )

        #expect(result.sceneType == .double)
        #expect(result.acceptedLayoutVariant == .verticalEqual)
        #expect(result.acceptedRatioPreset == "50/50")
        #expect(result.slots.map(\.candidateReference) == ["current-landscape", "secondary-landscape"])
        #expect(result.slots.allSatisfy { $0.cropRetention >= 0.60 })
        #expect(result.slots.contains { $0.cropRetention < 0.70 })
        #expect(result.currentAssetVisibleQualityClass == .acceptable)
    }

    @Test
    func
        `when a protected subject sits near the edge, planner only shifts the same crop fill without demoting or falling back the current photo`()
    {
        let leftProtectedFace = PlaybackPlanningRect(x: 0.05, y: 0.30, width: 0.05, height: 0.08)
        let result = plan(
            surface: phonePortraitSurface,
            candidates: [
                candidate(
                    reference: "current-left-face",
                    width: 2400,
                    height: 2000,
                    faceRects: [leftProtectedFace]
                ),
                candidate(reference: "secondary-fit", width: 1800, height: 2000)
            ]
        )

        let currentSlot = result.slots.first { $0.candidateReference == "current-left-face" }
        #expect(result.sceneType == .double)
        #expect(result.slots.first?.candidateReference == "current-left-face")
        #expect(currentSlot?.role == .primary)
        #expect(currentSlot?.protectionContained == true)
        #expect((currentSlot?.cropRectInSource.x ?? 1) < 0.05)
        #expect((currentSlot?.cropRetention ?? 0) >= 0.70)
        #expect(result.currentAssetVisibleQualityClass == .acceptable)
    }

    @Test
    func `adding a same-renderer ratio preset on iPhone landscape still keeps the current photo as primary`() {
        let result = plan(
            surface: phoneLandscapeSurface,
            candidates: [
                candidate(reference: "current-portrait", width: 1500, height: 2000),
                candidate(reference: "secondary-landscape", width: 2400, height: 2000)
            ]
        )

        #expect(result.sceneType == .double)
        #expect(result.slots.first?.candidateReference == "current-portrait")
        #expect(result.currentAssetDisposition == .primarySlot)
        #expect(result.acceptedRatioPreset.hasPrefix("constructive-"))
        #expect(result.currentAssetVisibleQualityClass == .acceptable)
        #expect(result.slots.allSatisfy { $0.cropRetention >= 0.70 })
    }

    @Test
    func `iPhone portrait double solves a continuous, non-menu geometric vertical split`() throws {
        let surface = phonePortraitSurface
        let currentAspect = 1.40
        let idealPartnerAspect = (surface.aspectRatio * currentAspect) / (currentAspect - surface.aspectRatio)
        let expectedCurrentShare = surface.aspectRatio / currentAspect
        let result = plan(
            surface: surface,
            candidates: [
                candidate(reference: "current-wide", width: 2800, height: 2000),
                candidate(reference: "ideal-partner", width: 1376, height: 2000)
            ]
        )
        let currentSlot = try #require(result.slots.first { $0.candidateReference == "current-wide" })
        let partnerSlot = try #require(result.slots.first { $0.candidateReference == "ideal-partner" })

        #expect(abs(idealPartnerAspect - 0.688) < 0.002)
        #expect(result.sceneType == .double)
        #expect(
            result.acceptedLayoutVariant == .topPrimaryBottomSecondary
                || result.acceptedLayoutVariant == .bottomPrimaryTopSecondary)
        #expect(abs(currentSlot.frameInScene.height - expectedCurrentShare) < 0.010)
        #expect(abs(partnerSlot.frameInScene.height - (1 - expectedCurrentShare)) < 0.010)
        #expect(currentSlot.cropRetention > 0.985)
        #expect(partnerSlot.cropRetention > 0.985)
        #expect(result.slots.allSatisfy { $0.cropRetention >= 0.60 })
    }

    @Test
    func `iPhone landscape double solves a continuous, non-menu geometric horizontal split`() throws {
        let surface = phoneLandscapeSurface
        let currentAspect = 0.74
        let idealPartnerAspect = surface.aspectRatio - currentAspect
        let expectedCurrentShare = currentAspect / surface.aspectRatio
        let result = plan(
            surface: surface,
            candidates: [
                candidate(reference: "current-portrait", width: 1480, height: 2000),
                candidate(reference: "ideal-landscape", width: 2856, height: 2000)
            ]
        )
        let currentSlot = try #require(result.slots.first { $0.candidateReference == "current-portrait" })
        let partnerSlot = try #require(result.slots.first { $0.candidateReference == "ideal-landscape" })

        #expect(abs(idealPartnerAspect - 1.428) < 0.002)
        #expect(result.sceneType == .double)
        #expect(
            result.acceptedLayoutVariant == .leftPrimaryRightSecondary
                || result.acceptedLayoutVariant == .rightPrimaryLeftSecondary)
        #expect(abs(currentSlot.frameInScene.width - expectedCurrentShare) < 0.010)
        #expect(abs(partnerSlot.frameInScene.width - (1 - expectedCurrentShare)) < 0.010)
        #expect(currentSlot.cropRetention > 0.985)
        #expect(partnerSlot.cropRetention > 0.985)
        #expect(result.slots.allSatisfy { $0.cropRetention >= 0.60 })
    }

    @Test
    func `double picks the partner closest to the ideal ratio over an earlier passing candidate`() {
        let result = plan(
            surface: phonePortraitSurface,
            candidates: [
                candidate(reference: "current-wide", width: 2800, height: 2000),
                candidate(reference: "earlier-square", width: 2000, height: 2000),
                candidate(reference: "near-ideal", width: 1376, height: 2000)
            ]
        )

        #expect(result.sceneType == .double)
        #expect(result.slots.map(\.candidateReference) == ["current-wide", "near-ideal"])
        #expect(result.slots.allSatisfy { $0.cropRetention > 0.985 })
    }

    @Test
    func `multi-slot search never skips the current photo as primary`() {
        let faceAtLeftEdge = PlaybackPlanningRect(x: 0.02, y: 0.42, width: 0.08, height: 0.12)
        let result = plan(
            surface: phonePortraitSurface,
            candidates: [
                candidate(
                    reference: "current-face",
                    width: 6000,
                    height: 2200,
                    faceRects: [faceAtLeftEdge]
                ),
                candidate(reference: "readable-1", width: 1800, height: 2000),
                candidate(reference: "readable-2", width: 1800, height: 2000)
            ]
        )

        #expect(result.sceneType == .double)
        #expect(result.slots.map(\.candidateReference) == ["current-face", "readable-1"])
        #expect(result.currentAssetDisposition == .primarySlot)
        #expect(result.currentAssetVisibleQualityClass == .acceptable)
        #expect(result.slots.allSatisfy { $0.cropRetention >= 0.60 })
    }

    @Test
    func `fallback records the key numbers of the rejected layout to prevent blindly loosening thresholds`() {
        let result = plan(
            surface: phonePortraitSurface,
            candidates: [
                candidate(reference: "too-wide", width: 6000, height: 1800)
            ]
        )

        #expect(result.sceneType == .fallback)
        #expect(result.rejectReasonsTried.contains(.cropRetentionTooLow))
        #expect(result.qaDebugSummary.contains("rejectedLayoutDiagnostics="))
        #expect(result.qaDebugSummary.contains("reason:crop-retention-too-low"))
        #expect(result.qaDebugSummary.contains("role:primary"))
        #expect(result.qaDebugSummary.contains("slotIndex:0"))
        #expect(result.qaDebugSummary.contains("imageAspect:3.333"))
        #expect(result.qaDebugSummary.contains("slotAspect:0.461"))
        #expect(result.qaDebugSummary.contains("cropRetention:0.138"))
        #expect(result.qaDebugSummary.contains("threshold:0.600"))
        #expect(result.qaDebugSummary.contains("thresholdDelta:-0.462"))
        #expect(!result.qaDebugSummary.contains("asset-raw-too-wide"))
    }

    @Test
    func `on Apple TV, systemSafeArea overlapping a real face only warns without triggering fallback`() throws {
        let bottomFace = PlaybackPlanningRect(x: 0.45, y: 0.88, width: 0.12, height: 0.08)
        let bottomHardSafeArea = PlaybackProtectionSnapshot(regions: [
            try #require(
                PlaybackProtectionRegion.systemSafeArea(
                    rect: PlaybackProtectionRect(x: 0, y: 0.90, width: 1, height: 0.10),
                    activeConditionSummary: "edge=bottom"
                ))
        ])

        let result = plan(
            surface: appleTVSurface,
            candidates: [
                candidate(
                    reference: "hard-face",
                    width: 4032,
                    height: 3024,
                    faceRects: [bottomFace]
                )
            ],
            protectionSnapshot: bottomHardSafeArea
        )
        let summary = result.qaDebugSummary

        #expect(result.sceneType == .single)
        #expect(result.fallbackReason == nil)
        #expect(!result.rejectReasonsTried.contains(.protectionOverlap))
        #expect(result.protectionSummary.status == .accepted)
        #expect(result.protectionSummary.hardOverlapCount == 0)
        #expect(summary.contains("protectionOverlapDetails="))
        #expect(summary.contains("source:face"))
        #expect(summary.contains("region:systemSafeArea"))
        #expect(summary.contains("priority:hard"))
        #expect(summary.contains("hardRejected:false"))
        #expect(summary.contains("systemSafeAreaSoftWarning:true"))
    }

    @Test
    func `on iPad portrait, systemSafeArea overlapping a real face only warns without triggering fallback`() throws {
        let topFace = PlaybackPlanningRect(x: 0.44, y: 0.02, width: 0.12, height: 0.08)
        let topHardSafeArea = PlaybackProtectionSnapshot(regions: [
            try #require(
                PlaybackProtectionRegion.systemSafeArea(
                    rect: PlaybackProtectionRect(x: 0, y: 0, width: 1, height: 0.08),
                    activeConditionSummary: "edge=top"
                ))
        ])

        let result = plan(
            surface: iPadPortraitSurface,
            candidates: [
                candidate(
                    reference: "ipad-portrait-safe-area-face",
                    width: 3200,
                    height: 4000,
                    faceRects: [topFace]
                )
            ],
            protectionSnapshot: topHardSafeArea
        )
        let summary = result.qaDebugSummary

        #expect(result.sceneType == .single)
        #expect(result.fallbackReason == nil)
        #expect(!result.rejectReasonsTried.contains(.protectionOverlap))
        #expect(result.protectionSummary.status == .accepted)
        #expect(result.protectionSummary.hardOverlapCount == 0)
        #expect(summary.contains("source:face"))
        #expect(summary.contains("region:systemSafeArea"))
        #expect(summary.contains("hardRejected:false"))
        #expect(summary.contains("systemSafeAreaSoftWarning:true"))
    }

    @Test
    func `on iPad landscape, systemSafeArea overlapping a real face only warns without triggering fallback`() throws {
        let rightFace = PlaybackPlanningRect(x: 0.92, y: 0.42, width: 0.06, height: 0.12)
        let trailingHardSafeArea = PlaybackProtectionSnapshot(regions: [
            try #require(
                PlaybackProtectionRegion.systemSafeArea(
                    rect: PlaybackProtectionRect(x: 0.90, y: 0, width: 0.10, height: 1),
                    activeConditionSummary: "edge=trailing"
                ))
        ])

        let result = plan(
            surface: iPadLandscapeSurface,
            candidates: [
                candidate(
                    reference: "ipad-landscape-safe-area-face",
                    width: 2732,
                    height: 2048,
                    faceRects: [rightFace]
                )
            ],
            protectionSnapshot: trailingHardSafeArea
        )
        let summary = result.qaDebugSummary

        #expect(result.sceneType == .single)
        #expect(result.fallbackReason == nil)
        #expect(!result.rejectReasonsTried.contains(.protectionOverlap))
        #expect(result.protectionSummary.status == .accepted)
        #expect(result.protectionSummary.hardOverlapCount == 0)
        #expect(summary.contains("source:face"))
        #expect(summary.contains("region:systemSafeArea"))
        #expect(summary.contains("hardRejected:false"))
        #expect(summary.contains("systemSafeAreaSoftWarning:true"))
    }

    @Test
    func `on iPhone portrait, systemSafeArea overlapping a real face still triggers fallback`() throws {
        let topFace = PlaybackPlanningRect(x: 0.44, y: 0.02, width: 0.12, height: 0.08)
        let topHardSafeArea = PlaybackProtectionSnapshot(regions: [
            try #require(
                PlaybackProtectionRegion.systemSafeArea(
                    rect: PlaybackProtectionRect(x: 0, y: 0, width: 1, height: 0.08),
                    activeConditionSummary: "edge=top"
                ))
        ])

        let result = plan(
            surface: phonePortraitSurface,
            candidates: [
                candidate(
                    reference: "iphone-portrait-safe-area-face",
                    width: 1200,
                    height: 2400,
                    faceRects: [topFace]
                )
            ],
            protectionSnapshot: topHardSafeArea
        )
        let summary = result.qaDebugSummary

        #expect(result.sceneType == .fallback)
        #expect(result.rejectReasonsTried.contains(.protectionOverlap))
        #expect(summary.contains("protectionOverlapDetails="))
        #expect(summary.contains("source:face"))
        #expect(summary.contains("region:systemSafeArea"))
        #expect(summary.contains("priority:hard"))
        #expect(summary.contains("hardRejected:true"))
        #expect(!summary.contains("systemSafeAreaSoftWarning:true"))
    }

    @Test
    func `on iPhone landscape, systemSafeArea overlapping a real face still triggers fallback`() throws {
        let rightFace = PlaybackPlanningRect(x: 0.94, y: 0.42, width: 0.04, height: 0.12)
        let trailingHardSafeArea = PlaybackProtectionSnapshot(regions: [
            try #require(
                PlaybackProtectionRegion.systemSafeArea(
                    rect: PlaybackProtectionRect(x: 0.90, y: 0, width: 0.10, height: 1),
                    activeConditionSummary: "edge=trailing"
                ))
        ])

        let result = plan(
            surface: phoneLandscapeSurface,
            candidates: [
                candidate(
                    reference: "iphone-landscape-safe-area-face",
                    width: 2556,
                    height: 1179,
                    faceRects: [rightFace]
                )
            ],
            protectionSnapshot: trailingHardSafeArea
        )
        let summary = result.qaDebugSummary

        #expect(result.sceneType == .fallback)
        #expect(result.rejectReasonsTried.contains(.protectionOverlap))
        #expect(summary.contains("protectionOverlapDetails="))
        #expect(summary.contains("source:face"))
        #expect(summary.contains("region:systemSafeArea"))
        #expect(summary.contains("priority:hard"))
        #expect(summary.contains("hardRejected:true"))
        #expect(!summary.contains("systemSafeAreaSoftWarning:true"))
    }

    @Test
    func `an upper-body proxy overlapping a hard screen region only warns without rejecting the fill`() throws {
        let face = PlaybackPlanningRect(x: 0.478, y: 0.340, width: 0.110, height: 0.194)
        let bottomHardSafeArea = PlaybackProtectionSnapshot(regions: [
            try #require(
                PlaybackProtectionRegion.systemSafeArea(
                    rect: PlaybackProtectionRect(x: 0, y: 0.90, width: 1, height: 0.10),
                    activeConditionSummary: "edge=bottom"
                ))
        ])

        let result = plan(
            surface: appleTVSurface,
            candidates: [
                candidate(
                    reference: "b54-like",
                    width: 4032,
                    height: 3024,
                    faceRects: [face]
                )
            ],
            protectionSnapshot: bottomHardSafeArea
        )
        let summary = result.qaDebugSummary

        #expect(result.sceneType == .single)
        #expect(result.fallbackReason == nil)
        #expect(!result.rejectReasonsTried.contains(.protectionOverlap))
        #expect(result.protectionSummary.status == .accepted)
        #expect(summary.contains("protectionOverlapDetails="))
        #expect(summary.contains("source:upperBodyProxy"))
        #expect(summary.contains("region:systemSafeArea"))
        #expect(summary.contains("priority:hard"))
        #expect(summary.contains("hardRejected:false"))
    }

    @Test
    func `an accepted crop must contain the upper-body proxy derived from the face rectangle`() {
        let oversizedUpperBodyProxy = PlaybackPlanningRect(x: 0.25, y: 0.30, width: 0.34, height: 0.08)
        let result = plan(
            surface: phonePortraitSurface,
            candidates: [
                candidate(
                    reference: "upper-body-risk",
                    width: 1300,
                    height: 2000,
                    faceRects: [oversizedUpperBodyProxy]
                )
            ]
        )

        #expect(result.sceneType == .fallback)
        #expect(result.faceProtectionSummary == .rejected)
        #expect(result.rejectReasonsTried.contains(.faceCropDestroyed))
    }
}
