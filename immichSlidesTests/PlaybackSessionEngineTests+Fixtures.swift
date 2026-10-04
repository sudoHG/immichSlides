import Foundation
import Testing
@testable import immichSlides

extension PlaybackSessionEngineTests {
    /// Settles right after the first scene is Ready; later steps only assert the auto play identity.
    func settleInitialScenePresentation(
        _ engine: inout PlaybackSessionEngine,
        configuredInterval: TimeInterval = 5,
        at time: TimeInterval = 0
    ) throws -> PlaybackSessionEngine.ScenePresentationIdentity {
        let startedResult = engine.startScenePresentation(configuredInterval: configuredInterval, at: time)
        let started = try #require(startedResult)
        engine.reduceScenePresentation(.targetReady(started.identity), at: time)
        engine.reduceScenePresentation(.transitionCompleted, at: time)
        return started.identity
    }

    func makeAsset(
        id: String,
        width: Int? = nil,
        height: Int? = nil,
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
            height: height
        )
    }

    func makeSmartFillScene(
        id: String,
        assets: [Asset],
        sceneType: PlaybackSmartFillSceneType = .double
    ) -> PlaybackScene {
        let policyId = "unit-smartfill-policy"
        let roles: [PlaybackSmartFillSlotRole] = [.primary, .secondary, .tertiary]
        let slots = zip(assets.indices, assets).map { index, asset in
            PhotoSlot(
                id: "slot-\(roles[index].rawValue)-\(asset.id)",
                asset: asset,
                planning: PlaybackPlanningSnapshot.smartFill(
                    slot: PlaybackSmartFillSlot(
                        role: roles[index],
                        candidateReference: "candidate-\(index)",
                        frameInScene: PlaybackPlanningRect(
                            x: index == 0 ? 0 : 0.5,
                            y: index == 2 ? 0.5 : 0,
                            width: index == 0 ? 0.5 : 0.5,
                            height: assets.count == 3 && index > 0 ? 0.5 : 1
                        ),
                        cropRectInSource: .fullUnitRect,
                        sourceImageSummary: PlaybackPlanningSourceImageSummary(
                            assetPixelSize: PlaybackPlanningPixelSize(width: 2400, height: 1600),
                            exifPixelSize: nil,
                            orientation: "available"
                        ),
                        rejectRisks: []
                    ),
                    plannerResult: PlaybackSmartFillPlannerResult(
                        sceneType: sceneType,
                        layoutPolicyId: policyId,
                        surfaceKey: "unit-surface",
                        layoutVariant: sceneType == .triple ? .leftPrimaryRightStack : .horizontalEqual,
                        ratioPreset: "unit",
                        slots: [],
                        fallbackReason: nil,
                        rejectReasonsTried: [],
                        qualityDecision: .smartFillAccepted,
                        faceProtectionSummary: .notApplied,
                        protectionSummary: .accepted,
                        readabilitySummary: PlaybackSmartFillReadabilitySummary(
                            minimumSecondaryArea: 0.2,
                            smallestSecondaryArea: 0.25,
                            accepted: true
                        ),
                        candidateWindowUsed: 12,
                        evaluationCount: assets.count,
                        rotationStartLayoutVariant: sceneType == .triple ? .leftPrimaryRightStack : .horizontalEqual,
                        rotationStartRatioPreset: "unit",
                        acceptedLayoutVariant: sceneType == .triple ? .leftPrimaryRightStack : .horizontalEqual,
                        acceptedRatioPreset: "unit",
                        rotationKeyHashPrefix: "unit0000",
                        reasonCodes: ["scene:\(sceneType.rawValue)", "policy:\(policyId)"],
                        qaDebugSummary:
                            "version=smart-fill-planner-v2;sceneType=\(sceneType.rawValue);surfaceKey=unit-surface;policy=\(policyId);slotCount=\(assets.count);fallback=none;rejects=none",
                        currentAssetDisposition: .primarySlot,
                        currentAssetAbsentReason: .none,
                        currentAssetFaceProtectionPassed: true,
                        currentAssetSubjectProtectionPassed: true,
                        currentAssetVisibleQualityClass: .acceptable
                    )
                )
            )
        }

        return PlaybackScene(
            id: id,
            photoSlots: slots,
            smartFillReadback: PlaybackSmartFillSceneReadback(
                version: "smart-fill-scene-v2",
                sceneType: sceneType,
                layoutPolicyId: policyId,
                surfaceKey: "unit-surface",
                layoutVariant: sceneType == .triple ? .leftPrimaryRightStack : .horizontalEqual,
                ratioPreset: "unit",
                slotRoles: Array(roles.prefix(assets.count)),
                fallbackReason: nil,
                candidateWindowUsed: 12,
                evaluationCount: assets.count,
                rotationStartLayoutVariant: sceneType == .triple ? .leftPrimaryRightStack : .horizontalEqual,
                rotationStartRatioPreset: "unit",
                acceptedLayoutVariant: sceneType == .triple ? .leftPrimaryRightStack : .horizontalEqual,
                acceptedRatioPreset: "unit",
                rotationKeyHashPrefix: "unit0000",
                reasonCodes: ["scene:\(sceneType.rawValue)", "policy:\(policyId)"],
                qaDebugSummary:
                    "version=smart-fill-planner-v2;sceneType=\(sceneType.rawValue);surfaceKey=unit-surface;policy=\(policyId);slotCount=\(assets.count);fallback=none"
            )
        )
    }

    func makePreparedFingerprint(
        deviceProfile: String = "iPad",
        orientation: String = "landscape",
        width: Double = 1024,
        height: Double = 768,
        safeAreaClass: String = "regular",
        controlBarClass: String = "hidden",
        exifOverlayClass: String = "visible",
        assetPoolIdentity: String = "pool-a",
        playbackSourceIdentity: String = "album-a"
    ) -> PlaybackPreparedSceneFingerprint {
        PlaybackPreparedSceneFingerprint(
            deviceProfile: deviceProfile,
            orientation: orientation,
            pointWidth: width,
            pointHeight: height,
            safeAreaClass: safeAreaClass,
            controlBarClass: controlBarClass,
            exifOverlayClass: exifOverlayClass,
            assetPoolIdentity: assetPoolIdentity,
            playbackSourceIdentity: playbackSourceIdentity
        )
    }

    func makeControlBarProtection() -> PlaybackProtectionSnapshot {
        PlaybackProtectionSnapshot(regions: [
            PlaybackProtectionRegion.controlBar(
                rect: PlaybackProtectionRect(x: 0, y: 0.9, width: 1, height: 0.1),
                activeConditionSummary: "visible"
            )!
        ])
    }

    func makeFutureOverlayProtection() -> PlaybackProtectionSnapshot {
        PlaybackProtectionSnapshot(regions: [
            PlaybackProtectionRegion.futureOverlay(
                rect: PlaybackProtectionRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                activeConditionSummary: "preview"
            )!
        ])
    }
}
