//
//  PlaybackSceneTests.swift
//  immichSlidesTests
//
//  Stays on the PlaybackScene model so a view-layer pass cannot hide scene identity, slot, or fallback failures.
//

import Foundation
import CoreGraphics
import Testing
@testable import immichSlides

@MainActor
@Suite
struct PlaybackSceneTests {
    private let geometryComparisonTolerance: CGFloat = 0.000_001

    @Test
    func `single photo scene generates a stable scene id and slot id`() {
        let asset = makeAsset(id: "asset-a")

        let firstScene = PlaybackScene(primaryAsset: asset)
        let secondScene = PlaybackScene(primaryAsset: asset)

        #expect(firstScene.id == secondScene.id)
        #expect(firstScene.photoSlots.first?.id == secondScene.photoSlots.first?.id)
        #expect(firstScene.id == "scene-asset-a")
        #expect(firstScene.sequence == 0)
        #expect(firstScene.photoSlots.first?.id == "slot-primary-asset-a")
        #expect(firstScene.fallbackReason == .none)
        #expect(firstScene.protectionSnapshot == .empty)
        #expect(secondScene.protectionSnapshot == .empty)
    }

    @Test
    func `single photo scene exposes primaryAsset and assetIds`() {
        let asset = makeAsset(id: "asset-primary")

        let scene = PlaybackScene(primaryAsset: asset)

        #expect(scene.primaryAsset?.id == "asset-primary")
        #expect(scene.primaryAssetId == "asset-primary")
        #expect(scene.assetIds == ["asset-primary"])
    }

    @Test
    func `single photo scene creates a stable legacy planning snapshot`() throws {
        let asset = makeAsset(
            id: "asset-sensitive-a",
            width: 4032,
            height: 3024,
            exifInfo: ExifInfo(
                exifImageWidth: 4000,
                exifImageHeight: 3000,
                orientation: "Rotate 90 CW"
            )
        )

        let firstScene = PlaybackScene(primaryAsset: asset)
        let secondScene = PlaybackScene(primaryAsset: asset)
        let planning = try #require(firstScene.photoSlots.first?.planning)

        #expect(planning == secondScene.photoSlots.first?.planning)
        #expect(planning.version == "legacy-scaledToFit-v1")
        #expect(planning.sourceImage.assetPixelSize == PlaybackPlanningPixelSize(width: 4032, height: 3024))
        #expect(planning.sourceImage.exifPixelSize == PlaybackPlanningPixelSize(width: 4000, height: 3000))
        #expect(planning.sourceImage.orientation == "available")
        #expect(planning.displayFrame == .fullUnitRect)
        #expect(planning.cropRect == .fullUnitRect)
        #expect(planning.qualityDecision == .legacyNotEvaluated)
        #expect(planning.faceProtection == .notApplied)
        #expect(planning.fallbackReasons == [.legacyScaledToFit])
        #expect(!planning.qaDebugSummary.contains(asset.id))
        #expect(!planning.qaDebugSummary.localizedCaseInsensitiveContains("smart"))
        #expect(!planning.qaDebugSummary.localizedCaseInsensitiveContains("face protected"))
    }

    @Test
    func `protection snapshot stays independent from the planning snapshot and initializer defaults are compatible`()
        throws
    {
        let asset = makeAsset(id: "asset-independent", width: 1600, height: 900)
        let protection = PlaybackProtectionSnapshot(regions: [
            try #require(
                PlaybackProtectionRegion.controlBar(
                    rect: PlaybackProtectionRect(x: 0, y: 0.9, width: 1, height: 0.1),
                    activeConditionSummary: "visible"
                ))
        ])

        let legacyScene = PlaybackScene(primaryAsset: asset)
        let protectedScene = PlaybackScene(
            id: "scene-protected",
            photoSlots: [
                PhotoSlot(id: "slot-protected", asset: asset)
            ],
            protectionSnapshot: protection
        )

        #expect(legacyScene.protectionSnapshot == .empty)
        #expect(protectedScene.protectionSnapshot == protection)
        #expect(protectedScene.photoSlots.first?.planning == legacyScene.photoSlots.first?.planning)
        #expect(protectedScene.photoSlots.first?.planning.version == "legacy-scaledToFit-v1")
        #expect(
            protectedScene.protectionSnapshot.qaDebugSummary != protectedScene.photoSlots.first?.planning.qaDebugSummary
        )
    }

    @Test
    func `planning records unknown when size metadata is missing and the summary leaks no sensitive pattern`() throws {
        let asset = makeAsset(id: "asset-sensitive-b")

        let scene = PlaybackScene(primaryAsset: asset)
        let planning = try #require(scene.photoSlots.first?.planning)

        #expect(planning.sourceImage.assetPixelSize == nil)
        #expect(planning.sourceImage.exifPixelSize == nil)
        #expect(planning.sourceImage.orientation == "unknown")
        #expect(planning.fallbackReasons.contains(.missingMetadata))
        #expect(planning.qaDebugSummary.contains("metadata=missing"))
        #expect(!planning.qaDebugSummary.contains(asset.id))
    }

    @Test
    func `the high bit of thumbhash byte 5 determines display orientation`() {
        #expect(ThumbHashGeometry.isLandscape("AAAAAIA=") == true)
        #expect(ThumbHashGeometry.isLandscape("AAAAAAA=") == false)
        #expect(ThumbHashGeometry.isLandscape("abc") == nil)
    }

    @Test
    func `SmartFill candidate display size orders the asset magnitude by thumbhash orientation`() throws {
        let arwPortrait = makeAsset(
            id: "asset-arw-portrait",
            width: 5120,
            height: 7168,
            thumbhash: "AAAAAAA=",
            exifInfo: ExifInfo(exifImageWidth: 7168, exifImageHeight: 5120, orientation: "8")
        )
        let heifPortrait = makeAsset(
            id: "asset-heif-portrait",
            width: 7008,
            height: 4672,
            thumbhash: "AAAAAAA=",
            exifInfo: ExifInfo(exifImageWidth: 7008, exifImageHeight: 4672, orientation: nil)
        )
        let landscape = makeAsset(
            id: "asset-landscape",
            width: 3000,
            height: 4000,
            thumbhash: "AAAAAIA=",
            exifInfo: nil
        )

        #expect(
            PlaybackSmartFillSourceGeometry.displayPixelSize(for: arwPortrait)
                == PlaybackPlanningPixelSize(width: 5120, height: 7168))
        #expect(
            PlaybackSmartFillSourceGeometry.displayPixelSize(for: heifPortrait)
                == PlaybackPlanningPixelSize(width: 4672, height: 7008))
        #expect(
            PlaybackSmartFillSourceGeometry.displayPixelSize(for: landscape)
                == PlaybackPlanningPixelSize(width: 4000, height: 3000))
    }

    @Test
    func `SmartFill candidate display size falls back to the asset size then EXIF when thumbhash is missing`() {
        let assetSize = makeAsset(id: "asset-size", width: 1200, height: 2400, thumbhash: nil)
        let exifOnly = makeAsset(
            id: "exif-only",
            width: nil,
            height: nil,
            thumbhash: nil,
            exifInfo: ExifInfo(exifImageWidth: 6000, exifImageHeight: 4000, orientation: "1")
        )

        #expect(
            PlaybackSmartFillSourceGeometry.displayPixelSize(for: assetSize)
                == PlaybackPlanningPixelSize(width: 1200, height: 2400))
        #expect(
            PlaybackSmartFillSourceGeometry.displayPixelSize(for: exifOnly)
                == PlaybackPlanningPixelSize(width: 6000, height: 4000))
    }

    @Test
    func `SmartFill slot planning summary exposes v2 reviewable fields without leaking the raw assetId`() {
        let slot = PlaybackSmartFillSlot(
            role: .primary,
            candidateReference: "ref-deadbeef1234",
            frameInScene: PlaybackPlanningRect(x: 0, y: 0, width: 1, height: 1),
            cropRectInSource: PlaybackPlanningRect(x: 0.1, y: 0, width: 0.8, height: 1),
            sourceImageSummary: PlaybackPlanningSourceImageSummary(
                assetPixelSize: PlaybackPlanningPixelSize(width: 4000, height: 3000),
                exifPixelSize: nil,
                orientation: "available"
            ),
            rejectRisks: [],
            cropRetention: 0.8,
            protectionContained: true,
            slotAspectRatio: 1.333
        )
        let plannerResult = PlaybackSmartFillPlannerResult(
            sceneType: .single,
            layoutPolicyId: "iphone-portrait-v2",
            surfaceKey: "iPhone-portrait-compact-regular-safeA",
            layoutVariant: .single,
            ratioPreset: "full",
            slots: [slot],
            fallbackReason: nil,
            fallbackCategory: .none,
            rejectReasonsTried: [.cropRetentionTooLow],
            rejectedLayoutReasonTopList: [.cropRetentionTooLow],
            qualityDecision: .smartFillAccepted,
            faceProtectionSummary: .accepted,
            protectionSummary: .accepted,
            readabilitySummary: PlaybackSmartFillReadabilitySummary(
                minimumSecondaryArea: 0.18,
                smallestSecondaryArea: nil,
                accepted: true
            ),
            candidateWindowUsed: 12,
            evaluationCount: 3,
            rotationStartLayoutVariant: .single,
            rotationStartRatioPreset: "full",
            acceptedLayoutVariant: .single,
            acceptedRatioPreset: "full",
            rotationKeyHashPrefix: "abc12345",
            reasonCodes: ["scene:single", "policy:iphone-portrait-v2"],
            qaDebugSummary: "planner-summary-not-copied-verbatim",
            currentAssetDisposition: .singleSlot,
            currentAssetAbsentReason: .none,
            currentAssetSlotAreaRatio: 1,
            currentAssetCropRetention: 0.8,
            currentAssetProtectedRegionCoverage: 1,
            currentAssetFaceProtectionPassed: true,
            currentAssetSubjectProtectionPassed: true,
            currentAssetVisibleQualityClass: .acceptable
        )

        let planning = PlaybackPlanningSnapshot.smartFill(slot: slot, plannerResult: plannerResult)

        #expect(planning.version == "smart-fill-planner-v2")
        #expect(planning.qaDebugSummary.contains("version=smart-fill-planner-v2"))
        #expect(planning.qaDebugSummary.contains("surfaceKey=iPhone-portrait-compact-regular-safeA"))
        #expect(planning.qaDebugSummary.contains("layoutVariant=single"))
        #expect(planning.qaDebugSummary.contains("ratioPreset=full"))
        #expect(planning.qaDebugSummary.contains("fallbackCategory=none"))
        #expect(planning.qaDebugSummary.contains("cropRetention=0.800"))
        #expect(planning.qaDebugSummary.contains("protectionContained=true"))
        #expect(planning.qaDebugSummary.contains("candidateWindowUsed=12"))
        #expect(planning.qaDebugSummary.contains("evaluationCount=3"))
        #expect(planning.qaDebugSummary.contains("rotationKeyHashPrefix=abc12345"))
        #expect(planning.qaDebugSummary.contains("slotRef=ref-deadbeef1234"))
        #expect(!planning.qaDebugSummary.contains("asset-sensitive"))
        #expect(!planning.qaDebugSummary.localizedCaseInsensitiveContains("http" + "://"))
        #expect(!planning.qaDebugSummary.localizedCaseInsensitiveContains("api " + "key"))
        #expect(!planning.qaDebugSummary.localizedCaseInsensitiveContains("tok" + "en"))
    }

    @Test
    func `SmartFill renderer placement maps the source crop into the slot`() {
        let placement = SmartFillSourceCropPlacement.resolve(
            slotSize: CGSize(width: 100, height: 100),
            sourceAspectRatio: 2.0,
            cropRect: PlaybackPlanningRect(x: 0.25, y: 0, width: 0.5, height: 1)
        )

        #expect(abs(placement.imageFrame.minX - -50) < geometryComparisonTolerance)
        #expect(abs(placement.imageFrame.minY - 0) < geometryComparisonTolerance)
        #expect(abs(placement.imageFrame.width - 200) < geometryComparisonTolerance)
        #expect(abs(placement.imageFrame.height - 100) < geometryComparisonTolerance)
    }

    @Test
    func `SmartFill EXIF overlay policy keeps only single and fallback`() {
        #expect(PlaybackSmartFillSceneType.single.shouldPreserveExistingExifOverlay)
        #expect(!PlaybackSmartFillSceneType.double.shouldPreserveExistingExifOverlay)
        #expect(!PlaybackSmartFillSceneType.triple.shouldPreserveExistingExifOverlay)
        #expect(PlaybackSmartFillSceneType.fallback.shouldPreserveExistingExifOverlay)
    }

    @Test
    func `an asset array converts to a same order array of single photo scenes`() {
        let scenes = PlaybackScene.scenes(from: [
            makeAsset(id: "asset-a"),
            makeAsset(id: "asset-b"),
            makeAsset(id: "asset-c")
        ])

        #expect(
            scenes.map(\.id) == [
                "scene-asset-a",
                "scene-asset-b",
                "scene-asset-c"
            ])
        #expect(
            PlaybackScene.assetIds(in: scenes) == [
                "asset-a",
                "asset-b",
                "asset-c"
            ])
    }

    @Test
    func `an empty scene array returns empty assetIds`() {
        #expect(PlaybackScene.assetIds(in: []) == [])
    }

    @Test
    func `SmartFill debug summary lists the scene and full asset ids for every slot`() {
        let primary = makeAsset(id: "11111111-1111-4111-8111-111111111111")
        let secondary = makeAsset(id: "22222222-2222-4222-8222-222222222222")
        let primaryPlanning = PlaybackPlanningSnapshot(
            version: "smart-fill-planner-v2",
            sourceImage: PlaybackPlanningSourceImageSummary(
                assetPixelSize: PlaybackPlanningPixelSize(width: 4000, height: 3000),
                exifPixelSize: nil,
                orientation: "available"
            ),
            displayFrame: PlaybackPlanningRect(x: 0, y: 0, width: 0.6, height: 1),
            cropRect: PlaybackPlanningRect(x: 0, y: 0.1, width: 1, height: 0.8),
            qualityDecision: .smartFillAccepted,
            faceProtection: .accepted,
            fallbackReasons: [],
            qaDebugSummary: "cropRetention=0.800;slotAspectRatio=1.067"
        )
        let secondaryPlanning = PlaybackPlanningSnapshot(
            version: "smart-fill-planner-v2",
            sourceImage: PlaybackPlanningSourceImageSummary(
                assetPixelSize: PlaybackPlanningPixelSize(width: 3000, height: 4000),
                exifPixelSize: nil,
                orientation: "available"
            ),
            displayFrame: PlaybackPlanningRect(x: 0.6, y: 0, width: 0.4, height: 1),
            cropRect: PlaybackPlanningRect(x: 0.2, y: 0, width: 0.6, height: 1),
            qualityDecision: .smartFillAccepted,
            faceProtection: .accepted,
            fallbackReasons: [],
            qaDebugSummary: "cropRetention=0.600;slotAspectRatio=0.711"
        )
        let readback = PlaybackSmartFillSceneReadback(
            version: "smart-fill-scene-v2",
            sceneType: .double,
            layoutPolicyId: "appletv-landscape-pr49-v1",
            surfaceKey: "appleTV-landscape-tv-regular-safeTV",
            layoutVariant: .leftPrimaryRightSecondary,
            ratioPreset: "60/40",
            slotRoles: [.primary, .secondary],
            fallbackReason: nil,
            fallbackCategory: .none,
            candidateWindowUsed: 2,
            evaluationCount: 2,
            rotationStartLayoutVariant: .single,
            rotationStartRatioPreset: "full",
            acceptedLayoutVariant: .leftPrimaryRightSecondary,
            acceptedRatioPreset: "60/40",
            rotationKeyHashPrefix: "abc12345",
            rejectedLayoutReasonTopList: [],
            reasonCodes: ["scene:double"],
            qaDebugSummary: "sceneType=double;quality=smartFillAccepted"
        )
        let scene = PlaybackScene(
            id: "scene-debug",
            photoSlots: [
                PhotoSlot(id: "slot-primary", asset: primary, planning: primaryPlanning),
                PhotoSlot(id: "slot-secondary", asset: secondary, planning: secondaryPlanning)
            ],
            smartFillReadback: readback
        )

        let summary = PlaybackDebugOverlaySceneSummary(scene: scene).lines.joined(separator: "\n")

        #expect(summary.contains("Scene double renderer smartFill"))
        #expect(summary.contains("fallback none/none"))
        #expect(summary.contains("slot primary 11111111-1111-4111-8111-111111111111"))
        #expect(summary.contains("slot secondary 22222222-2222-4222-8222-222222222222"))
        #expect(summary.contains("frame x0.000y0.000w0.600h1.000"))
        #expect(summary.contains("crop x0.000y0.100w1.000h0.800"))
        #expect(summary.contains("retention 0.800"))
        #expect(!summary.contains("1111...1111"))
    }

    @Test
    func `legacy debug summary marks the legacy renderer and the full primary asset id`() {
        let asset = makeAsset(id: "33333333-3333-4333-8333-333333333333")
        let scene = PlaybackScene(primaryAsset: asset)

        let summary = PlaybackDebugOverlaySceneSummary(scene: scene).lines.joined(separator: "\n")

        #expect(summary.contains("Scene legacy renderer legacy"))
        #expect(summary.contains("fallback legacy"))
        #expect(summary.contains("slot primary 33333333-3333-4333-8333-333333333333"))
    }

    private func makeAsset(
        id: String,
        width: Int? = nil,
        height: Int? = nil,
        thumbhash: String? = nil,
        exifInfo: ExifInfo? = nil
    ) -> Asset {
        Asset(
            id: id,
            type: "IMAGE",
            isFavorite: false,
            isTrashed: false,
            isArchived: false,
            exifInfo: exifInfo,
            people: nil,
            tags: nil,
            livePhotoVideoID: nil,
            width: width,
            height: height,
            thumbhash: thumbhash
        )
    }
}
