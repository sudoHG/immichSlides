//
//  PlaybackScene.swift
//  immichSlides
//
//  Created by Codex on 2026/5/25.
//

import CoreGraphics
import Foundation

struct PlaybackPlanningPixelSize: Equatable, Sendable {
    let width: Int
    let height: Int

    nonisolated init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

enum PlaybackSmartFillSourceGeometry {
    static func displayPixelSize(for asset: Asset) -> PlaybackPlanningPixelSize? {
        let magnitude =
            pixelSize(width: asset.width, height: asset.height)
            ?? pixelSize(
                width: asset.exifInfo?.exifImageWidth,
                height: asset.exifInfo?.exifImageHeight
            )

        guard let magnitude else { return nil }
        guard let thumbhashIsLandscape = ThumbHashGeometry.isLandscape(asset.thumbhash) else {
            return pixelSize(width: asset.width, height: asset.height) ?? magnitude
        }

        let longEdge = max(magnitude.width, magnitude.height)
        let shortEdge = min(magnitude.width, magnitude.height)
        if thumbhashIsLandscape {
            return PlaybackPlanningPixelSize(width: longEdge, height: shortEdge)
        }
        return PlaybackPlanningPixelSize(width: shortEdge, height: longEdge)
    }

    private static func pixelSize(width: Int?, height: Int?) -> PlaybackPlanningPixelSize? {
        guard let width, let height, width > 0, height > 0 else {
            return nil
        }
        return PlaybackPlanningPixelSize(width: width, height: height)
    }
}

struct PlaybackPlanningRect: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    nonisolated static let fullUnitRect = PlaybackPlanningRect(x: 0, y: 0, width: 1, height: 1)

    nonisolated init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    nonisolated static func == (lhs: PlaybackPlanningRect, rhs: PlaybackPlanningRect) -> Bool {
        lhs.x == rhs.x && lhs.y == rhs.y && lhs.width == rhs.width && lhs.height == rhs.height
    }
}

enum PlaybackPlanningQualityDecision: String, Equatable, Sendable {
    case legacyNotEvaluated
    case smartFillAccepted
    case smartFillFallback
}

enum PlaybackPlanningFaceProtectionSummary: String, Equatable, Sendable {
    case notApplied
    case accepted
    case rejected
}

enum PlaybackPlanningFallbackReason: String, Equatable, Sendable {
    case plannerNotImplemented
    case legacyScaledToFit
    case missingMetadata
    case smartFillFallback
    case smartFillMissingCandidates
    case smartFillImageNotReady
    case smartFillAllLayoutsRejected
}

struct PlaybackPlanningSourceImageSummary: Equatable, Sendable {
    let assetPixelSize: PlaybackPlanningPixelSize?
    let exifPixelSize: PlaybackPlanningPixelSize?
    let orientation: String

    nonisolated init(
        assetPixelSize: PlaybackPlanningPixelSize?,
        exifPixelSize: PlaybackPlanningPixelSize?,
        orientation: String
    ) {
        self.assetPixelSize = assetPixelSize
        self.exifPixelSize = exifPixelSize
        self.orientation = orientation
    }
}

enum PlaybackPlanningFocalSource: Equatable, Sendable {
    case face
    case subject
}

struct PlaybackPlanningFocalSummary: Equatable, Sendable {
    let source: PlaybackPlanningFocalSource
    let rectInSource: PlaybackPlanningRect

    nonisolated init(
        source: PlaybackPlanningFocalSource,
        rectInSource: PlaybackPlanningRect
    ) {
        self.source = source
        self.rectInSource = rectInSource
    }

    nonisolated var centerInSource: CGPoint? {
        guard rectInSource.width > 0, rectInSource.height > 0 else { return nil }
        return CGPoint(
            x: rectInSource.x + rectInSource.width * 0.5,
            y: rectInSource.y + rectInSource.height * 0.5
        )
    }
}

struct PlaybackPlanningSnapshot: Equatable, Sendable {
    let version: String
    let sourceImage: PlaybackPlanningSourceImageSummary
    let displayFrame: PlaybackPlanningRect
    let cropRect: PlaybackPlanningRect
    let qualityDecision: PlaybackPlanningQualityDecision
    let faceProtection: PlaybackPlanningFaceProtectionSummary
    let focalSummary: PlaybackPlanningFocalSummary?
    let fallbackReasons: [PlaybackPlanningFallbackReason]
    let qaDebugSummary: String

    nonisolated init(
        version: String,
        sourceImage: PlaybackPlanningSourceImageSummary,
        displayFrame: PlaybackPlanningRect,
        cropRect: PlaybackPlanningRect,
        qualityDecision: PlaybackPlanningQualityDecision,
        faceProtection: PlaybackPlanningFaceProtectionSummary,
        focalSummary: PlaybackPlanningFocalSummary? = nil,
        fallbackReasons: [PlaybackPlanningFallbackReason],
        qaDebugSummary: String
    ) {
        self.version = version
        self.sourceImage = sourceImage
        self.displayFrame = displayFrame
        self.cropRect = cropRect
        self.qualityDecision = qualityDecision
        self.faceProtection = faceProtection
        self.focalSummary = focalSummary
        self.fallbackReasons = fallbackReasons
        self.qaDebugSummary = qaDebugSummary
    }

    static func legacyScaledToFit(for asset: Asset) -> PlaybackPlanningSnapshot {
        let sourceImage = PlaybackPlanningSourceImageSummary(
            assetPixelSize: pixelSize(width: asset.width, height: asset.height),
            exifPixelSize: pixelSize(
                width: asset.exifInfo?.exifImageWidth,
                height: asset.exifInfo?.exifImageHeight
            ),
            orientation: asset.exifInfo?.orientation == nil ? "unknown" : "available"
        )
        let hasAnyMetadata =
            sourceImage.assetPixelSize != nil
            || sourceImage.exifPixelSize != nil
            || sourceImage.orientation == "available"
        var fallbackReasons: [PlaybackPlanningFallbackReason] = [
            .plannerNotImplemented,
            .legacyScaledToFit
        ]
        if !hasAnyMetadata {
            fallbackReasons.append(.missingMetadata)
        }

        return PlaybackPlanningSnapshot(
            version: "legacy-scaledToFit-v1",
            sourceImage: sourceImage,
            displayFrame: .fullUnitRect,
            cropRect: .fullUnitRect,
            qualityDecision: .legacyNotEvaluated,
            faceProtection: .notApplied,
            focalSummary: nil,
            fallbackReasons: fallbackReasons,
            qaDebugSummary: qaDebugSummary(
                metadataSummary: hasAnyMetadata ? "asset-dimensions" : "missing",
                fallbackReasons: fallbackReasons
            )
        )
    }

    static func smartFill(
        slot: PlaybackSmartFillSlot,
        plannerResult: PlaybackSmartFillPlannerResult,
        focalSummary: PlaybackPlanningFocalSummary? = nil
    ) -> PlaybackPlanningSnapshot {
        let fallbackReasons = smartFillFallbackReasons(from: plannerResult)
        return PlaybackPlanningSnapshot(
            version: "smart-fill-planner-v2",
            sourceImage: slot.sourceImageSummary,
            displayFrame: slot.frameInScene,
            cropRect: slot.cropRectInSource,
            qualityDecision: plannerResult.qualityDecision,
            faceProtection: faceProtectionSummary(from: plannerResult.faceProtectionSummary),
            focalSummary: focalSummary,
            fallbackReasons: fallbackReasons,
            qaDebugSummary: smartFillQADebugSummary(
                slot: slot,
                plannerResult: plannerResult,
                fallbackReasons: fallbackReasons
            )
        )
    }

    private static func pixelSize(width: Int?, height: Int?) -> PlaybackPlanningPixelSize? {
        guard let width, let height else { return nil }
        return PlaybackPlanningPixelSize(width: width, height: height)
    }

    private static func qaDebugSummary(
        metadataSummary: String,
        fallbackReasons: [PlaybackPlanningFallbackReason]
    ) -> String {
        let fallbackSummary =
            fallbackReasons
            .map(\.summaryLabel)
            .joined(separator: ",")
        return [
            "version=legacy-scaledToFit-v1",
            "display=full",
            "crop=full",
            "quality=legacy-not-evaluated",
            "face=not-applied",
            "metadata=\(metadataSummary)",
            "fallback=\(fallbackSummary)"
        ].joined(separator: ";")
    }

    private static func smartFillFallbackReasons(
        from plannerResult: PlaybackSmartFillPlannerResult
    ) -> [PlaybackPlanningFallbackReason] {
        guard let fallbackReason = plannerResult.fallbackReason else { return [] }
        switch fallbackReason {
        case .none:
            return []
        case .missingCandidates:
            return [.smartFillFallback, .smartFillMissingCandidates]
        case .imageNotReady:
            return [.smartFillFallback, .smartFillImageNotReady]
        case .allLayoutsRejected:
            return [.smartFillFallback, .smartFillAllLayoutsRejected]
        }
    }

    private static func faceProtectionSummary(
        from status: PlaybackSmartFillFaceProtectionStatus
    ) -> PlaybackPlanningFaceProtectionSummary {
        switch status {
        case .notApplied:
            return .notApplied
        case .accepted:
            return .accepted
        case .rejected:
            return .rejected
        }
    }

    private static func smartFillQADebugSummary(
        slot: PlaybackSmartFillSlot,
        plannerResult: PlaybackSmartFillPlannerResult,
        fallbackReasons: [PlaybackPlanningFallbackReason]
    ) -> String {
        let fallbackSummary =
            fallbackReasons
            .map(\.summaryLabel)
            .joined(separator: ",")
        return [
            "version=smart-fill-planner-v2",
            "sceneType=\(plannerResult.sceneType.rawValue)",
            "surfaceKey=\(plannerResult.surfaceKey)",
            "policy=\(plannerResult.layoutPolicyId)",
            "layoutVariant=\(plannerResult.layoutVariant.rawValue)",
            "ratioPreset=\(plannerResult.ratioPreset)",
            "fallbackCategory=\(plannerResult.fallbackCategory.rawValue)",
            "role=\(slot.role.rawValue)",
            "slotRef=\(slot.candidateReference)",
            "display=\(slot.frameInScene.summaryLabel)",
            "crop=\(slot.cropRectInSource.summaryLabel)",
            "cropRetention=\(format(slot.cropRetention))",
            "protectionContained=\(slot.protectionContained ? "true" : "false")",
            "slotAspectRatio=\(format(slot.slotAspectRatio))",
            "candidateWindowUsed=\(plannerResult.candidateWindowUsed)",
            "evaluationCount=\(plannerResult.evaluationCount)",
            "rotationStartLayoutVariant=\(plannerResult.rotationStartLayoutVariant.rawValue)",
            "rotationStartRatioPreset=\(plannerResult.rotationStartRatioPreset)",
            "acceptedLayoutVariant=\(plannerResult.acceptedLayoutVariant.rawValue)",
            "acceptedRatioPreset=\(plannerResult.acceptedRatioPreset)",
            "rotationKeyHashPrefix=\(plannerResult.rotationKeyHashPrefix)",
            "quality=\(plannerResult.qualityDecision.rawValue)",
            "face=\(plannerResult.faceProtectionSummary.rawValue)",
            "rejectedLayoutReasonTopList=\(plannerResult.rejectedLayoutReasonTopList.map(\.rawValue).joined(separator: ",").nilIfEmpty ?? "none")",
            "rejects=\(plannerResult.rejectReasonsTried.map(\.rawValue).joined(separator: ",").nilIfEmpty ?? "none")",
            "fallback=\(fallbackSummary.isEmpty ? "none" : fallbackSummary)"
        ].joined(separator: ";")
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension PlaybackPlanningFallbackReason {
    var summaryLabel: String {
        switch self {
        case .plannerNotImplemented:
            "planner-not-implemented"
        case .legacyScaledToFit:
            "legacy-scaled-to-fit"
        case .missingMetadata:
            "missing-metadata"
        case .smartFillFallback:
            "smart-fill-fallback"
        case .smartFillMissingCandidates:
            "smart-fill-missing-candidates"
        case .smartFillImageNotReady:
            "smart-fill-image-not-ready"
        case .smartFillAllLayoutsRejected:
            "smart-fill-all-layouts-rejected"
        }
    }
}

private extension PlaybackPlanningRect {
    var summaryLabel: String {
        "x\(formatted(x))y\(formatted(y))w\(formatted(width))h\(formatted(height))"
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

struct PhotoSlot: Identifiable {
    let id: String
    let asset: Asset
    let planning: PlaybackPlanningSnapshot

    init(
        id: String,
        asset: Asset,
        planning: PlaybackPlanningSnapshot? = nil
    ) {
        self.id = id
        self.asset = asset
        self.planning = planning ?? .legacyScaledToFit(for: asset)
    }
}

enum PlaybackSceneFallbackReason: String, Equatable {
    case none
    case emptyPool
}

struct PlaybackScene: Identifiable {
    let id: String
    let playbackSessionId: UUID
    let sequence: Int
    let photoSlots: [PhotoSlot]
    let fallbackReason: PlaybackSceneFallbackReason
    let protectionSnapshot: PlaybackProtectionSnapshot
    let smartFillReadback: PlaybackSmartFillSceneReadback?

    init(
        id: String,
        playbackSessionId: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        sequence: Int = 0,
        photoSlots: [PhotoSlot],
        fallbackReason: PlaybackSceneFallbackReason = .none,
        protectionSnapshot: PlaybackProtectionSnapshot = .empty,
        smartFillReadback: PlaybackSmartFillSceneReadback? = nil
    ) {
        self.id = id
        self.playbackSessionId = playbackSessionId
        self.sequence = sequence
        self.photoSlots = photoSlots
        self.fallbackReason = fallbackReason
        self.protectionSnapshot = protectionSnapshot
        self.smartFillReadback = smartFillReadback
    }

    init(
        primaryAsset asset: Asset,
        fallbackReason: PlaybackSceneFallbackReason = .none,
        protectionSnapshot: PlaybackProtectionSnapshot = .empty
    ) {
        self.init(
            id: Self.sceneId(for: asset),
            playbackSessionId: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            sequence: 0,
            photoSlots: [
                PhotoSlot(
                    id: Self.primarySlotId(for: asset),
                    asset: asset
                )
            ],
            fallbackReason: fallbackReason,
            protectionSnapshot: protectionSnapshot
        )
    }

    var primaryAsset: Asset? {
        photoSlots.first?.asset
    }

    var assetIds: [String] {
        photoSlots.map(\.asset.id)
    }

    var primaryAssetId: String? {
        primaryAsset?.id
    }

    static func scenes(from assets: [Asset]) -> [PlaybackScene] {
        assets.map { asset in
            PlaybackScene(primaryAsset: asset)
        }
    }

    static func assetIds(in scenes: [PlaybackScene]) -> [String] {
        scenes.flatMap(\.assetIds)
    }

    func replacingPlaybackIdentity(
        id: String,
        playbackSessionId: UUID,
        sequence: Int,
        protectionSnapshot: PlaybackProtectionSnapshot
    ) -> PlaybackScene {
        PlaybackScene(
            id: id,
            playbackSessionId: playbackSessionId,
            sequence: sequence,
            photoSlots: photoSlots,
            fallbackReason: fallbackReason,
            protectionSnapshot: protectionSnapshot,
            smartFillReadback: smartFillReadback
        )
    }

    func replacingSmartFillReadback(_ readback: PlaybackSmartFillSceneReadback?) -> PlaybackScene {
        PlaybackScene(
            id: id,
            playbackSessionId: playbackSessionId,
            sequence: sequence,
            photoSlots: photoSlots,
            fallbackReason: fallbackReason,
            protectionSnapshot: protectionSnapshot,
            smartFillReadback: readback
        )
    }

    func replacingDisplayContent(with scene: PlaybackScene) -> PlaybackScene {
        PlaybackScene(
            id: id,
            playbackSessionId: playbackSessionId,
            sequence: sequence,
            photoSlots: scene.photoSlots,
            fallbackReason: scene.fallbackReason,
            protectionSnapshot: protectionSnapshot,
            smartFillReadback: scene.smartFillReadback
        )
    }

    private static func sceneId(for asset: Asset) -> String {
        "scene-\(asset.id)"
    }

    private static func primarySlotId(for asset: Asset) -> String {
        "slot-primary-\(asset.id)"
    }
}
