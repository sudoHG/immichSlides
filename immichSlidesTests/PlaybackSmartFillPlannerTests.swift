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
    func `prepared plan result uses the request's full protection snapshot off the MainActor`() throws {
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

    private func plan(
        surface: PlaybackSmartFillSurface,
        candidates: [PlaybackSmartFillCandidateSummary],
        protectionSnapshot: PlaybackProtectionSnapshot = .empty,
        seed: String = "test-session",
        sceneOrdinal: Int = 0
    ) -> PlaybackSmartFillPlannerResult {
        PlaybackSmartFillPlanner.plan(
            PlaybackSmartFillPlannerInput(
                surface: surface,
                candidates: candidates,
                protectionSnapshot: protectionSnapshot,
                policy: .policy(for: surface),
                playbackSessionSeed: seed,
                sceneOrdinal: sceneOrdinal
            )
        )
    }

    private var phonePortraitSurface: PlaybackSmartFillSurface {
        PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(width: 1179, height: 2556),
            profile: .iPhone,
            orientation: .portrait
        )
    }

    private var phoneLandscapeSurface: PlaybackSmartFillSurface {
        PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(width: 2556, height: 1179),
            profile: .iPhone,
            orientation: .landscape
        )
    }

    private var iPadLandscapeSurface: PlaybackSmartFillSurface {
        PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(width: 2732, height: 2048),
            profile: .iPad,
            orientation: .landscape
        )
    }

    private var iPadPortraitSurface: PlaybackSmartFillSurface {
        PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(width: 2048, height: 2732),
            profile: .iPad,
            orientation: .portrait
        )
    }

    private var appleTVSurface: PlaybackSmartFillSurface {
        PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(width: 3840, height: 2160),
            profile: .appleTV,
            orientation: .landscape
        )
    }

    private var smartFillSurfaces: [PlaybackSmartFillSurface] {
        [
            phonePortraitSurface,
            phoneLandscapeSurface,
            iPadPortraitSurface,
            iPadLandscapeSurface,
            appleTVSurface
        ]
    }

    private func candidate(
        reference: String,
        width: Int,
        height: Int,
        faceRects: [PlaybackPlanningRect] = []
    ) -> PlaybackSmartFillCandidateSummary {
        let pixelSize = PlaybackPlanningPixelSize(width: width, height: height)
        return PlaybackSmartFillCandidateSummary(
            reference: reference,
            sourceImage: PlaybackPlanningSourceImageSummary(
                assetPixelSize: pixelSize,
                exifPixelSize: pixelSize,
                orientation: "available"
            ),
            faceRects: faceRects,
            subjectRects: faceRects
        )
    }

    private var benchmarkAspects: [Double] {
        [
            0.42, 0.56, 0.66, 0.75, 0.80, 1.00, 1.25, 1.33, 1.50, 1.78, 2.00, 2.40, 3.00
        ]
    }

    private var benchmarkFixedFaceRect: PlaybackPlanningRect {
        PlaybackPlanningRect(x: 0.35, y: 0.12, width: 0.30, height: 0.32)
    }

    private func benchmarkCandidates(
        surface: PlaybackSmartFillSurface,
        sceneIndex: Int,
        candidateCount: Int = 72
    ) -> [PlaybackSmartFillCandidateSummary] {
        let currentAspect = benchmarkAspects[sceneIndex % benchmarkAspects.count]
        let current = candidate(
            reference: "bench-\(surface.surfaceKey)-\(sceneIndex)-current",
            width: benchmarkPixelSize(for: currentAspect).width,
            height: benchmarkPixelSize(for: currentAspect).height
        )
        let lookahead = (0..<candidateCount).map { candidateIndex in
            let aspect = benchmarkAspects[(sceneIndex + candidateIndex + 1) % benchmarkAspects.count]
            let pixelSize = benchmarkPixelSize(for: aspect)
            return candidate(
                reference: "bench-\(surface.surfaceKey)-\(sceneIndex)-\(candidateIndex)",
                width: pixelSize.width,
                height: pixelSize.height,
                faceRects: (sceneIndex + candidateIndex).isMultiple(of: 2) ? [benchmarkFixedFaceRect] : []
            )
        }
        return [current] + lookahead
    }

    private func benchmarkPixelSize(for aspect: Double) -> PlaybackPlanningPixelSize {
        PlaybackPlanningPixelSize(width: Int((aspect * 1_200).rounded()), height: 1_200)
    }

    private func assertSendable<T: Sendable>(_ type: T.Type) {}

    private func assertDoesNotExposeForbiddenBackgroundBoundary(_ value: Any) {
        assertDoesNotExposeForbiddenBackgroundBoundary(value, depth: 0)
    }

    private func assertDoesNotExposeForbiddenBackgroundBoundary(_ value: Any, depth: Int) {
        guard depth < 6 else { return }
        let forbiddenTypeFragments = [
            "AssetsDownloadManager",
            "PlaybackSessionEngine",
            "ObservableObject",
            "RequestModifier",
            "URLRequest",
            "View",
            "SwiftUI"
        ]
        let reflectedValueType = String(reflecting: type(of: value))
        for forbidden in forbiddenTypeFragments {
            #expect(
                !reflectedValueType.contains(forbidden),
                "\(reflectedValueType) must not cross the background planning boundary")
        }
        for child in Mirror(reflecting: value).children {
            let reflectedType = String(reflecting: type(of: child.value))
            for forbidden in forbiddenTypeFragments {
                #expect(
                    !reflectedType.contains(forbidden),
                    "\(reflectedType) must not cross the background planning boundary")
            }
            assertDoesNotExposeForbiddenBackgroundBoundary(child.value, depth: depth + 1)
        }
    }
}
