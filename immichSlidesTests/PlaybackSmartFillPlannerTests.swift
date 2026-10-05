//
//  PlaybackSmartFillPlannerTests.swift
//  immichSlidesTests
//
//  Pure-model tests for the Smart Fill planner; no real server access and no real image downloads.
//

import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite(.serialized)
struct PlaybackSmartFillPlannerTests {

    @Test
    func `each device's SmartFill policy matches the spec's search order and layout allowlist`() {
        let phonePortrait = PlaybackSmartFillLayoutPolicy.policy(for: phonePortraitSurface)
        #expect(phonePortrait.layoutPolicyId == "iphone-portrait-pr49-v1")
        #expect(phonePortrait.sceneSearchOrder == [.single, .double, .fallback])
        #expect(phonePortrait.candidateWindowPresets == [24, 48, 72])
        #expect(phonePortrait.canUseVerticalDouble)
        #expect(!phonePortrait.canUseHorizontalDouble)
        #expect(!phonePortrait.canUseTriple)
        #expect(phonePortrait.canUseCurrentCandidateAsAuxiliaryLookahead)
        #expect(phonePortrait.cropRetentionThreshold == 0.60)
        #expect(
            phonePortrait.layoutAllowlist == [
                .verticalEqual,
                .topPrimaryBottomSecondary,
                .bottomPrimaryTopSecondary
            ])
        #expect(phonePortrait.ratioPresets(for: .topPrimaryBottomSecondary).map(\.id).contains("28/72"))
        #expect(phonePortrait.ratioPresets(for: .bottomPrimaryTopSecondary).map(\.id).contains("72/28"))

        let phoneLandscape = PlaybackSmartFillLayoutPolicy.policy(for: phoneLandscapeSurface)
        #expect(phoneLandscape.layoutPolicyId == "iphone-landscape-pr49-v1")
        #expect(phoneLandscape.sceneSearchOrder == [.single, .double, .fallback])
        #expect(phoneLandscape.candidateWindowPresets == [24, 48, 72])
        #expect(!phoneLandscape.canUseVerticalDouble)
        #expect(phoneLandscape.canUseHorizontalDouble)
        #expect(!phoneLandscape.canUseTriple)
        #expect(phoneLandscape.canUseCurrentCandidateAsAuxiliaryLookahead)
        #expect(phoneLandscape.cropRetentionThreshold == 0.60)
        #expect(
            phoneLandscape.layoutAllowlist == [
                .horizontalEqual,
                .leftPrimaryRightSecondary,
                .rightPrimaryLeftSecondary
            ])
        #expect(
            phoneLandscape.ratioPresets(for: .leftPrimaryRightSecondary).map(\.id) == [
                "28/72",
                "45/55",
                "55/45",
                "40/60",
                "60/40",
                "65/35",
                "72/28"
            ])
        #expect(
            phoneLandscape.ratioPresets(for: .rightPrimaryLeftSecondary).map(\.id) == [
                "28/72",
                "45/55",
                "55/45",
                "40/60",
                "60/40",
                "65/35",
                "72/28"
            ])

        let iPadPortrait = PlaybackSmartFillLayoutPolicy.policy(for: iPadPortraitSurface)
        #expect(iPadPortrait.layoutPolicyId == "ipad-portrait-pr49-v1")
        #expect(iPadPortrait.sceneSearchOrder == [.single, .double, .triple, .fallback])
        #expect(iPadPortrait.candidateWindowPresets == [24, 48, 72])
        #expect(iPadPortrait.canUseVerticalDouble)
        #expect(!iPadPortrait.canUseHorizontalDouble)
        #expect(iPadPortrait.canUseTriple)
        #expect(iPadPortrait.canUseCurrentCandidateAsAuxiliaryLookahead)
        #expect(iPadPortrait.cropRetentionThreshold == 0.60)
        #expect(!iPadPortrait.layoutAllowlist.contains(.leftPrimaryRightSecondary))
        #expect(iPadPortrait.layoutAllowlist.contains(.topPrimaryBottomPair))

        let iPadLandscape = PlaybackSmartFillLayoutPolicy.policy(for: iPadLandscapeSurface)
        #expect(iPadLandscape.sceneSearchOrder == [.single, .double, .triple, .fallback])
        #expect(
            iPadLandscape.layoutAllowlist == [
                .horizontalEqual,
                .leftPrimaryRightSecondary,
                .rightPrimaryLeftSecondary,
                .leftPrimaryRightStack,
                .rightPrimaryLeftStack,
                .topPrimaryBottomPair,
                .bottomPrimaryTopPair,
                .balancedGrid
            ])
        #expect(iPadLandscape.cropRetentionThreshold == 0.60)
        #expect(iPadLandscape.ratioPresets(for: .leftPrimaryRightSecondary).map(\.id).contains("80/20"))
        #expect(iPadLandscape.ratioPresets(for: .rightPrimaryLeftSecondary).map(\.id).contains("80/20"))

        let appleTV = PlaybackSmartFillLayoutPolicy.policy(for: appleTVSurface)
        #expect(appleTV.layoutPolicyId == "appletv-landscape-pr49-v1")
        #expect(appleTV.sceneSearchOrder == [.single, .double, .triple, .fallback])
        #expect(appleTV.candidateWindowPresets == [24, 48, 72])
        #expect(appleTV.canUseHorizontalDouble)
        #expect(appleTV.canUseTriple)
        #expect(appleTV.canUseCurrentCandidateAsAuxiliaryLookahead)
        #expect(appleTV.layoutAllowlist.contains(.balancedGrid))
        #expect(appleTV.ratioPresets(for: .leftPrimaryRightSecondary).map(\.id).contains("80/20"))
        #expect(appleTV.ratioPresets(for: .rightPrimaryLeftSecondary).map(\.id).contains("80/20"))
        #expect(appleTV.cropRetentionThreshold == 0.60)
        #expect(appleTV.slotAspectRatioRange.minimum == 9.0 / 16.0)
        #expect(appleTV.slotAspectRatioRange.maximum == 16.0 / 9.0)
    }

    @Test
    func `background planning request, result and snapshot types are pure Sendable values`() throws {
        assertSendable(PlaybackProtectionSnapshot.self)
        assertSendable(SmartFillPlanningRawAssetSnapshot.self)
        assertSendable(SmartFillPreparedPlanRequest.self)
        assertSendable(SmartFillPreparedPlanResult.self)

        let rawSnapshot = SmartFillPlanningRawAssetSnapshot(
            assetId: "asset-0",
            reference: "asset_ref_0",
            assetPixelSize: PlaybackPlanningPixelSize(width: 3840, height: 2160),
            exifPixelSize: PlaybackPlanningPixelSize(width: 3840, height: 2160),
            orientation: "available",
            faceRects: [PlaybackPlanningRect(x: 0.2, y: 0.1, width: 0.2, height: 0.3)],
            subjectRects: [PlaybackPlanningRect(x: 0.2, y: 0.1, width: 0.2, height: 0.3)]
        )
        let sourceImageSummary = try #require(rawSnapshot.sourceImageSummary)
        let protectionSnapshot = PlaybackProtectionSnapshot(regions: [
            try #require(
                PlaybackProtectionRegion.controlBar(
                    rect: PlaybackProtectionRect(x: 0, y: 0.82, width: 1, height: 0.18),
                    activeConditionSummary: "visible=true"
                )),
            try #require(
                PlaybackProtectionRegion.exifPanel(
                    isShowingExif: true,
                    hasExifContent: true,
                    frame: PlaybackProtectionRect(x: 0.70, y: 0.20, width: 0.25, height: 0.28)
                ))
        ])
        let request = SmartFillPreparedPlanRequest(
            requestId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            surface: appleTVSurface,
            layoutPolicyId: "appletv-landscape-pr49-v1",
            protectionSnapshot: protectionSnapshot,
            protectionFingerprint: protectionSnapshot.smartFillReplanFingerprint,
            candidateCursor: 3,
            displayedAssetIds: ["asset-seen"],
            assetPoolIdentity: "count-2-abcd",
            playbackSourceGeneration: 7,
            playbackSessionSeed: "generation-7",
            sceneOrdinal: 42,
            preparedFingerprint: nil,
            rawAssetSnapshots: [rawSnapshot]
        )
        let result = SmartFillPreparedPlanResult(
            requestId: request.requestId,
            selectedAssetIds: ["asset-0"],
            selectedReferences: ["asset_ref_0"],
            slots: [
                PlaybackSmartFillSlot(
                    role: .primary,
                    candidateReference: "asset_ref_0",
                    frameInScene: .fullUnitRect,
                    cropRectInSource: .fullUnitRect,
                    sourceImageSummary: sourceImageSummary,
                    rejectRisks: []
                )
            ],
            plannerResult: PlaybackSmartFillPlannerResult(
                sceneType: .single,
                layoutPolicyId: "appletv-landscape-pr49-v1",
                slots: [
                    PlaybackSmartFillSlot(
                        role: .primary,
                        candidateReference: "asset_ref_0",
                        frameInScene: .fullUnitRect,
                        cropRectInSource: .fullUnitRect,
                        sourceImageSummary: sourceImageSummary,
                        rejectRisks: []
                    )
                ],
                fallbackReason: nil,
                rejectReasonsTried: [],
                qualityDecision: .smartFillAccepted,
                faceProtectionSummary: .notApplied,
                protectionSummary: .accepted,
                readabilitySummary: PlaybackSmartFillReadabilitySummary(
                    minimumSecondaryArea: 0,
                    smallestSecondaryArea: nil,
                    accepted: true
                ),
                reasonCodes: [],
                qaDebugSummary: "unit-test",
                currentAssetDisposition: .singleSlot,
                currentAssetAbsentReason: .none,
                currentAssetFaceProtectionPassed: true,
                currentAssetSubjectProtectionPassed: true,
                currentAssetVisibleQualityClass: .acceptable
            ),
            readback: PlaybackSmartFillSceneReadback(
                version: "smart-fill-scene-v2",
                sceneType: .single,
                layoutPolicyId: "appletv-landscape-pr49-v1",
                slotRoles: [.primary],
                fallbackReason: nil,
                reasonCodes: [],
                qaDebugSummary: "unit-test"
            ),
            nextCandidateCursorOffset: 1,
            displayedAssetIds: ["asset-0"],
            sourceCursor: request.candidateCursor,
            assetPoolIdentity: request.assetPoolIdentity,
            playbackSourceGeneration: request.playbackSourceGeneration
        )

        #expect(request.protectionSnapshot.regions.count == 2)
        #expect(request.protectionSnapshot.regions.map(\.source) == [.controlBar, .exifPanel])
        #expect(request.protectionFingerprint == request.protectionSnapshot.smartFillReplanFingerprint)
        for value in [rawSnapshot as Any, request as Any, result as Any] {
            assertDoesNotExposeForbiddenBackgroundBoundary(value)
        }
    }

    @Test
    func `prepared plan result uses the request's full protection snapshot off the MainActor`() async throws {
        let protection = PlaybackProtectionSnapshot(regions: [
            try #require(
                PlaybackProtectionRegion.controlBar(
                    rect: PlaybackProtectionRect(x: 0, y: 0.82, width: 1, height: 0.18),
                    activeConditionSummary: "visible"
                ))
        ])
        let rawSnapshot = SmartFillPlanningRawAssetSnapshot(
            assetId: "asset-raw-bottom-face",
            width: 4336,
            height: 2000,
            exifImageWidth: 4336,
            exifImageHeight: 2000,
            orientation: "available",
            rawFaces: [
                SmartFillPlanningRawFaceSnapshot(
                    boundingBoxX1: 1821,
                    boundingBoxX2: 2515,
                    boundingBoxY1: 1560,
                    boundingBoxY2: 1760,
                    imageWidth: 4336,
                    imageHeight: 2000,
                    sourceType: "machine-learning"
                )
            ]
        )
        let request = SmartFillPreparedPlanRequest(
            requestId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            surface: phoneLandscapeSurface,
            layoutPolicyId: "iphone-landscape-pr49-v1",
            protectionSnapshot: protection,
            protectionFingerprint: protection.smartFillReplanFingerprint,
            candidateCursor: 0,
            displayedAssetIds: [],
            assetPoolIdentity: "count-1-bottom-face",
            playbackSourceGeneration: 11,
            playbackSessionSeed: "generation-11",
            sceneOrdinal: 0,
            preparedFingerprint: nil,
            rawAssetSnapshots: [rawSnapshot]
        )

        let result = try #require(SmartFillPreparedPlanBuilder.makeResult(for: request))

        #expect(result.requestId == request.requestId)
        #expect(result.selectedAssetIds == ["asset-raw-bottom-face"])
        #expect(result.readback.fallbackReason == nil)
        #expect(result.plannerResult.protectionSummary.checkedRegionCount == 1)
        #expect(result.plannerResult.protectionSummary.overlapDetails.contains { $0.regionSource == .controlBar })
        #expect(result.readback.qaDebugSummary.contains("protectionStatus=accepted"))
        let cancelledResult = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return SmartFillPreparedPlanBuilder.makeResult(for: request)
        }.value
        #expect(cancelledResult == nil)
    }

    @Test
    func `every allowlisted layout catalog frame fully covers the photo canvas`() {
        for surface in smartFillSurfaces {
            let policy = PlaybackSmartFillLayoutPolicy.policy(for: surface)
            let photoCanvas = PlaybackSmartFillPhotoCanvasDescriptor(surface: surface)

            for variant in policy.layoutAllowlist {
                for preset in policy.ratioPresets(for: variant) {
                    let frames = PlaybackSmartFillLayoutCatalog.frames(for: variant, preset: preset)
                    let invariant = PlaybackSmartFillLayoutGeometryInvariant.evaluate(
                        frames: frames,
                        photoCanvas: photoCanvas
                    )

                    #expect(invariant.isFullCanvas)
                    #expect(invariant.gapPixelCount == 0)
                    #expect(invariant.overlapUnitArea <= 0.000000001)
                    #expect(invariant.overlapPixelCount == 0)
                    #expect(invariant.outOfBoundsUnitArea <= 0.000000001)
                }
            }
        }
    }

    @Test
    func `layout invariant rejects frames that leave black-bar canvas gaps`() {
        let frames = [
            PlaybackPlanningRect(x: 0.05, y: 0.05, width: 0.42, height: 0.90),
            PlaybackPlanningRect(x: 0.53, y: 0.05, width: 0.42, height: 0.90)
        ]
        let invariant = PlaybackSmartFillLayoutGeometryInvariant.evaluate(
            frames: frames,
            photoCanvas: PlaybackSmartFillPhotoCanvasDescriptor(surface: appleTVSurface)
        )

        #expect(!invariant.isFullCanvas)
        #expect(invariant.gapPixelCount > 0)
        #expect(invariant.emptyCanvasRatio > 0.01)
    }

    @Test
    func `layout invariant rejects a subpixel unit gap above the spec's 1e-9 epsilon`() {
        let frames = [
            PlaybackPlanningRect(x: 0, y: 0, width: 0.5 - 0.0000001, height: 1),
            PlaybackPlanningRect(x: 0.5, y: 0, width: 0.5, height: 1)
        ]
        let invariant = PlaybackSmartFillLayoutGeometryInvariant.evaluate(
            frames: frames,
            photoCanvas: PlaybackSmartFillPhotoCanvasDescriptor(
                pixelSize: PlaybackPlanningPixelSize(width: 100, height: 100)
            )
        )

        #expect(!invariant.isFullCanvas)
        #expect(invariant.gapPixelCount == 0)
        #expect(invariant.emptyCanvasRatio > 0)
        #expect(invariant.maxContinuousEmptyAxisRatio > 0)
    }

    @Test
    func `layout invariant rejects a subpixel unit overlap above the spec's 1e-9 epsilon`() {
        let frames = [
            PlaybackPlanningRect(x: 0, y: 0, width: 0.5 + 0.0000001, height: 1),
            PlaybackPlanningRect(x: 0.5, y: 0, width: 0.5, height: 1)
        ]
        let invariant = PlaybackSmartFillLayoutGeometryInvariant.evaluate(
            frames: frames,
            photoCanvas: PlaybackSmartFillPhotoCanvasDescriptor(
                pixelSize: PlaybackPlanningPixelSize(width: 100, height: 100)
            )
        )

        #expect(!invariant.isFullCanvas)
        #expect(invariant.gapPixelCount == 0)
        #expect(invariant.overlapUnitArea > 0.000000001)
        #expect(invariant.overlapPixelCount == 0)
    }

    @Test
    func `layout invariant rejects a subpixel unit out-of-bounds above the spec's 1e-9 epsilon`() {
        let frames = [
            PlaybackPlanningRect(x: -0.0000001, y: 0, width: 0.5000001, height: 1),
            PlaybackPlanningRect(x: 0.5, y: 0, width: 0.5, height: 1)
        ]
        let invariant = PlaybackSmartFillLayoutGeometryInvariant.evaluate(
            frames: frames,
            photoCanvas: PlaybackSmartFillPhotoCanvasDescriptor(
                pixelSize: PlaybackPlanningPixelSize(width: 100, height: 100)
            )
        )

        #expect(!invariant.isFullCanvas)
        #expect(invariant.gapPixelCount == 0)
        #expect(invariant.outOfBoundsUnitArea > 0.000000001)
        #expect(invariant.outOfBoundsPixelCount == 0)
    }

    @Test
    func `pixelized invariant absorbs non-divisible rounding remainder using shared edges`() {
        let frames = PlaybackSmartFillLayoutCatalog.frames(
            for: .balancedGrid,
            preset: PlaybackSmartFillRatioPreset(id: "equal-thirds", primaryShare: 1.0 / 3.0)
        )
        let invariant = PlaybackSmartFillLayoutGeometryInvariant.evaluate(
            frames: frames,
            photoCanvas: PlaybackSmartFillPhotoCanvasDescriptor(
                pixelSize: PlaybackPlanningPixelSize(width: 1001, height: 563)
            )
        )

        #expect(invariant.isFullCanvas)
        #expect(invariant.gapPixelCount == 0)
        #expect(invariant.overlapUnitArea <= 0.000000001)
        #expect(invariant.overlapPixelCount == 0)
        #expect(invariant.outOfBoundsUnitArea <= 0.000000001)
        #expect(invariant.coverageRatio == 1)
    }

    @Test
    func `pixelized invariant reports gap and overlap pixels separately`() {
        let canvas = PlaybackSmartFillPhotoCanvasDescriptor(
            pixelSize: PlaybackPlanningPixelSize(width: 101, height: 67)
        )
        let gapInvariant = PlaybackSmartFillLayoutGeometryInvariant.evaluate(
            frames: [
                PlaybackPlanningRect(x: 0, y: 0, width: 0.49, height: 1),
                PlaybackPlanningRect(x: 0.51, y: 0, width: 0.49, height: 1)
            ],
            photoCanvas: canvas
        )
        let overlapInvariant = PlaybackSmartFillLayoutGeometryInvariant.evaluate(
            frames: [
                PlaybackPlanningRect(x: 0, y: 0, width: 0.52, height: 1),
                PlaybackPlanningRect(x: 0.48, y: 0, width: 0.52, height: 1)
            ],
            photoCanvas: canvas
        )

        #expect(!gapInvariant.isFullCanvas)
        #expect(gapInvariant.gapPixelCount > 0)
        #expect(gapInvariant.overlapPixelCount == 0)
        #expect(!overlapInvariant.isFullCanvas)
        #expect(overlapInvariant.gapPixelCount == 0)
        #expect(overlapInvariant.overlapPixelCount > 0)
    }

    @Test
    func `PhotoCanvasDescriptor carries a canvas identity shared across planning stages`() {
        let surface = PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(width: 2732, height: 2048),
            profile: .iPad,
            orientation: .landscape,
            safeAreaClass: "safeB"
        )
        let descriptor = PlaybackSmartFillPhotoCanvasDescriptor(
            surface: surface,
            pointSize: PlaybackSmartFillPointSize(width: 1366, height: 1024),
            renderScale: 2,
            hardSystemObstructionClass: "none",
            unitCanvas: .fullUnitRect,
            canvasId: "canvas-test-id"
        )

        #expect(descriptor.profile == .iPad)
        #expect(descriptor.orientation == .landscape)
        #expect(descriptor.surfaceFingerprint == surface.internalSurfaceFingerprint)
        #expect(descriptor.pointSize == PlaybackSmartFillPointSize(width: 1366, height: 1024))
        #expect(descriptor.pixelSize == surface.pixelSize)
        #expect(descriptor.safeAreaClass == "safeB")
        #expect(descriptor.hardSystemObstructionClass == "none")
        #expect(descriptor.renderScale == 2)
        #expect(descriptor.unitCanvas == .fullUnitRect)
        #expect(descriptor.canvasId == "canvas-test-id")
    }

    @Test
    func `compact, centered and recovery layouts are never accepted as non-fallback variants`() {
        let forbiddenCaseNames = Set([
            "verticalCompactBands",
            "horizontalCompactBands",
            "landscapeCenteredLeftPrimary",
            "landscapeCenteredRightPrimary",
            "recoveryNonFallback",
            "recoveryCanvasFill"
        ])
        let variantCaseNames = Set(PlaybackSmartFillLayoutVariant.allCases.map { String(describing: $0) })

        #expect(variantCaseNames.isDisjoint(with: forbiddenCaseNames))
        for surface in smartFillSurfaces {
            let policy = PlaybackSmartFillLayoutPolicy.policy(for: surface)
            let allowlistCaseNames = Set(policy.layoutAllowlist.map { String(describing: $0) })
            #expect(allowlistCaseNames.isDisjoint(with: forbiddenCaseNames))
        }

        let result = plan(
            surface: appleTVSurface,
            candidates: [
                candidate(reference: "primary", width: 1800, height: 2000),
                candidate(reference: "secondary", width: 2400, height: 2000),
                candidate(reference: "tertiary", width: 2400, height: 2000)
            ]
        )

        #expect(result.sceneType != .fallback)
        #expect(!forbiddenCaseNames.contains(String(describing: result.acceptedLayoutVariant)))
    }

    @Test
    func `planner-accepted SmartFill scenes pass the full photo canvas invariant`() {
        let scenarios: [(surface: PlaybackSmartFillSurface, candidates: [PlaybackSmartFillCandidateSummary])] = [
            (
                phonePortraitSurface,
                [
                    candidate(reference: "phone-primary", width: 1800, height: 2000),
                    candidate(reference: "phone-secondary", width: 1800, height: 2000)
                ]
            ),
            (
                iPadLandscapeSurface,
                [
                    candidate(reference: "ipad-primary", width: 1800, height: 2000),
                    candidate(reference: "ipad-secondary", width: 2400, height: 2000),
                    candidate(reference: "ipad-tertiary", width: 2400, height: 2000)
                ]
            )
        ]

        for scenario in scenarios {
            let result = plan(surface: scenario.surface, candidates: scenario.candidates)
            let invariant = PlaybackSmartFillLayoutGeometryInvariant.evaluate(
                frames: result.slots.map(\.frameInScene),
                photoCanvas: PlaybackSmartFillPhotoCanvasDescriptor(surface: scenario.surface)
            )

            #expect(result.sceneType != .fallback)
            #expect(invariant.isFullCanvas)
        }
    }

    @Test
    func `planner never falls back because fullsize or preview downloads are not ready`() {
        let primary = candidate(
            reference: "primary",
            width: 1800,
            height: 2000
        )
        let candidateFieldNames = Set(Mirror(reflecting: primary).children.compactMap(\.label))
        let result = plan(
            surface: phonePortraitSurface,
            candidates: [
                primary,
                candidate(reference: "secondary", width: 1800, height: 2000)
            ]
        )

        #expect(!candidateFieldNames.contains("isFullsizeReady"))
        #expect(!candidateFieldNames.contains("isPreviewReady"))
        #expect(result.sceneType == .double)
        #expect(result.fallbackReason == nil)
        #expect(!result.rejectReasonsTried.contains(.imageNotReady))
        #expect(result.slots.map(\.candidateReference) == ["primary", "secondary"])
        #expect(result.fallbackCategory == .none)
    }

    @Test
    func `an accepted scene's control bar never shrinks the photo canvas`() throws {
        let protection = PlaybackProtectionSnapshot(regions: [
            try #require(
                PlaybackProtectionRegion.controlBar(
                    rect: PlaybackProtectionRect(x: 0, y: 0.82, width: 1, height: 0.18),
                    activeConditionSummary: "visible"
                ))
        ])
        let result = plan(
            surface: phonePortraitSurface,
            candidates: [
                candidate(reference: "primary", width: 1800, height: 2000),
                candidate(reference: "secondary", width: 1800, height: 2000)
            ],
            protectionSnapshot: protection
        )
        let invariant = PlaybackSmartFillLayoutGeometryInvariant.evaluate(
            frames: result.slots.map(\.frameInScene),
            photoCanvas: PlaybackSmartFillPhotoCanvasDescriptor(surface: phonePortraitSurface)
        )

        #expect(result.sceneType == .double)
        #expect(invariant.isFullCanvas)
        #expect(invariant.gapPixelCount == 0)
    }
}
