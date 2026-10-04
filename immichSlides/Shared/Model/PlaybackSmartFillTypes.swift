//
//  PlaybackSmartFillTypes.swift
//  immichSlides
//
//  Input, output and readback structures for the Smart Fill planner.
//

import CryptoKit
import Foundation

struct PlaybackSmartFillSurface: Equatable, Sendable {
    let pixelSize: PlaybackPlanningPixelSize
    let profile: PlaybackSmartFillSurfaceProfile
    let orientation: PlaybackSmartFillOrientation
    let safeAreaClass: String

    nonisolated init(
        pixelSize: PlaybackPlanningPixelSize,
        profile: PlaybackSmartFillSurfaceProfile,
        orientation: PlaybackSmartFillOrientation,
        safeAreaClass: String? = nil
    ) {
        self.pixelSize = pixelSize
        self.profile = profile
        self.orientation = orientation
        self.safeAreaClass = safeAreaClass ?? Self.defaultSafeAreaClass(for: profile)
    }

    nonisolated var aspectRatio: Double {
        guard pixelSize.height > 0 else { return 1 }
        return Double(pixelSize.width) / Double(pixelSize.height)
    }

    nonisolated var normalizedSizeClass: String {
        switch (profile, orientation) {
        case (.iPhone, .portrait):
            return "compact-regular"
        case (.iPhone, .landscape):
            return "regular-compact"
        case (.iPad, _):
            return "regular-regular"
        case (.appleTV, _):
            return "tv-regular"
        }
    }

    nonisolated var surfaceKey: String {
        "\(profile.rawValue)-\(orientation.rawValue)-\(normalizedSizeClass)-\(safeAreaClass)"
    }

    nonisolated var internalSurfaceFingerprint: String {
        [
            surfaceKey,
            "size:\(Self.bucketedDimension(pixelSize.width))x\(Self.bucketedDimension(pixelSize.height))",
            "aspect:\(Self.bucketedAspect(aspectRatio))"
        ].joined(separator: "|")
    }

    nonisolated static func == (lhs: PlaybackSmartFillSurface, rhs: PlaybackSmartFillSurface) -> Bool {
        lhs.internalSurfaceFingerprint == rhs.internalSurfaceFingerprint
    }

    private nonisolated static func defaultSafeAreaClass(for profile: PlaybackSmartFillSurfaceProfile) -> String {
        switch profile {
        case .iPhone:
            return "safeA"
        case .iPad:
            return "safeA"
        case .appleTV:
            return "safeTV"
        }
    }

    private nonisolated static func bucketedDimension(_ value: Int) -> Int {
        max(1, Int((Double(max(1, value)) / 32.0).rounded()))
    }

    private nonisolated static func bucketedAspect(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 20 }
        return max(1, Int((value * 20.0).rounded()))
    }
}

enum PlaybackSmartFillSurfaceProfile: String, Equatable, Sendable {
    case iPhone = "iPhone"
    case iPad = "iPad"
    case appleTV = "appleTV"
}

enum PlaybackSmartFillOrientation: String, Equatable, Sendable {
    case portrait
    case landscape
}

struct PlaybackSmartFillCandidateSummary: Equatable, Sendable {
    let reference: String
    let sourceImage: PlaybackPlanningSourceImageSummary
    let faceRects: [PlaybackPlanningRect]
    let subjectRects: [PlaybackPlanningRect]

    nonisolated var pixelSize: PlaybackPlanningPixelSize? {
        sourceImage.assetPixelSize ?? sourceImage.exifPixelSize
    }

    nonisolated var aspectRatio: Double? {
        guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0 else {
            return nil
        }
        return Double(pixelSize.width) / Double(pixelSize.height)
    }
}

struct SmartFillPlanningRawFaceSnapshot: Equatable, Sendable {
    let boundingBoxX1: Double?
    let boundingBoxX2: Double?
    let boundingBoxY1: Double?
    let boundingBoxY2: Double?
    let imageWidth: Int?
    let imageHeight: Int?
    let sourceType: String?
}

struct SmartFillPlanningRawAssetSnapshot: Equatable, Sendable {
    let assetId: String
    let width: Int?
    let height: Int?
    let exifImageWidth: Int?
    let exifImageHeight: Int?
    let orientation: String?
    let thumbhash: String?
    let rawFaces: [SmartFillPlanningRawFaceSnapshot]
    let reference: String?
    let sourceImageSummary: PlaybackPlanningSourceImageSummary?
    let faceRects: [PlaybackPlanningRect]?
    let subjectRects: [PlaybackPlanningRect]?

    nonisolated init(
        assetId: String,
        width: Int? = nil,
        height: Int? = nil,
        exifImageWidth: Int? = nil,
        exifImageHeight: Int? = nil,
        orientation: String? = nil,
        thumbhash: String? = nil,
        rawFaces: [SmartFillPlanningRawFaceSnapshot] = [],
        reference: String? = nil,
        sourceImageSummary: PlaybackPlanningSourceImageSummary? = nil,
        faceRects: [PlaybackPlanningRect]? = nil,
        subjectRects: [PlaybackPlanningRect]? = nil
    ) {
        self.assetId = assetId
        self.width = width
        self.height = height
        self.exifImageWidth = exifImageWidth
        self.exifImageHeight = exifImageHeight
        self.orientation = orientation
        self.thumbhash = thumbhash
        self.rawFaces = rawFaces
        self.reference = reference
        self.sourceImageSummary = sourceImageSummary
        self.faceRects = faceRects
        self.subjectRects = subjectRects
    }

    nonisolated init(
        assetId: String,
        reference: String?,
        assetPixelSize: PlaybackPlanningPixelSize?,
        exifPixelSize: PlaybackPlanningPixelSize?,
        orientation: String,
        faceRects: [PlaybackPlanningRect],
        subjectRects: [PlaybackPlanningRect]
    ) {
        self.init(
            assetId: assetId,
            width: assetPixelSize?.width,
            height: assetPixelSize?.height,
            exifImageWidth: exifPixelSize?.width,
            exifImageHeight: exifPixelSize?.height,
            orientation: orientation,
            reference: reference,
            sourceImageSummary: PlaybackPlanningSourceImageSummary(
                assetPixelSize: assetPixelSize,
                exifPixelSize: exifPixelSize,
                orientation: orientation
            ),
            faceRects: faceRects,
            subjectRects: subjectRects
        )
    }

    nonisolated var candidateSummary: PlaybackSmartFillCandidateSummary? {
        guard let reference, let sourceImageSummary, let faceRects, let subjectRects else {
            return nil
        }
        return PlaybackSmartFillCandidateSummary(
            reference: reference,
            sourceImage: sourceImageSummary,
            faceRects: faceRects,
            subjectRects: subjectRects
        )
    }
}

struct SmartFillPreparedPlanRequest: Equatable, Sendable {
    let requestId: UUID
    let surface: PlaybackSmartFillSurface
    let layoutPolicyId: String
    let protectionSnapshot: PlaybackProtectionSnapshot
    let protectionFingerprint: String
    let candidateCursor: Int
    let displayedAssetIds: Set<String>
    let assetPoolIdentity: String
    let playbackSourceGeneration: Int
    let playbackSessionSeed: String
    let sceneOrdinal: Int
    let preparedFingerprint: PlaybackPreparedSceneFingerprint?
    let rawAssetSnapshots: [SmartFillPlanningRawAssetSnapshot]
}

struct SmartFillPreparedPlanResult: Equatable, Sendable {
    let requestId: UUID
    let selectedAssetIds: [String]
    let selectedReferences: [String]
    let slots: [PlaybackSmartFillSlot]
    let plannerResult: PlaybackSmartFillPlannerResult
    let readback: PlaybackSmartFillSceneReadback
    let nextCandidateCursorOffset: Int
    let displayedAssetIds: Set<String>
    let sourceCursor: Int
    let assetPoolIdentity: String
    let playbackSourceGeneration: Int
}

enum SmartFillPreparedPlanApplicationOutcome: Equatable, Sendable {
    case applied
    case stale
    case invalid
}

enum SmartFillPreparedPlanBuilder {
    nonisolated static func makeResult(for request: SmartFillPreparedPlanRequest) -> SmartFillPreparedPlanResult? {
        guard !Task.isCancelled else { return nil }
        let candidates = request.rawAssetSnapshots.map { candidateSummary(from: $0) }
        guard !candidates.isEmpty else { return nil }
        guard !Task.isCancelled else { return nil }
        let policy = PlaybackSmartFillLayoutPolicy.policy(for: request.surface)
        let plannerResult = PlaybackSmartFillPlanner.plan(
            PlaybackSmartFillPlannerInput(
                surface: request.surface,
                candidates: candidates,
                protectionSnapshot: request.protectionSnapshot,
                policy: policy,
                playbackSessionSeed: request.playbackSessionSeed,
                sceneOrdinal: request.sceneOrdinal
            )
        )
        guard !Task.isCancelled else { return nil }
        guard !plannerResult.slots.isEmpty else { return nil }

        let readback = PlaybackSmartFillSceneReadback(
            version: "smart-fill-scene-v2",
            sceneType: plannerResult.sceneType,
            layoutPolicyId: plannerResult.layoutPolicyId,
            surfaceKey: plannerResult.surfaceKey,
            layoutVariant: plannerResult.layoutVariant,
            ratioPreset: plannerResult.ratioPreset,
            slotRoles: plannerResult.slots.map(\.role),
            fallbackReason: plannerResult.fallbackReason,
            fallbackCategory: plannerResult.fallbackCategory,
            candidateWindowUsed: plannerResult.candidateWindowUsed,
            evaluationCount: plannerResult.evaluationCount,
            rotationStartLayoutVariant: plannerResult.rotationStartLayoutVariant,
            rotationStartRatioPreset: plannerResult.rotationStartRatioPreset,
            acceptedLayoutVariant: plannerResult.acceptedLayoutVariant,
            acceptedRatioPreset: plannerResult.acceptedRatioPreset,
            rotationKeyHashPrefix: plannerResult.rotationKeyHashPrefix,
            rejectedLayoutReasonTopList: plannerResult.rejectedLayoutReasonTopList,
            reasonCodes: plannerResult.reasonCodes,
            qaDebugSummary: plannerResult.qaDebugSummary
        )
        let selectedRefs = plannerResult.slots.map(\.candidateReference)
        let selectedAssetIds = selectedRefs.compactMap { selectedRef in
            zip(candidates, request.rawAssetSnapshots).first { candidate, _ in
                candidate.reference == selectedRef
            }?.1.assetId
        }
        return SmartFillPreparedPlanResult(
            requestId: request.requestId,
            selectedAssetIds: selectedAssetIds,
            selectedReferences: selectedRefs,
            slots: plannerResult.slots,
            plannerResult: plannerResult,
            readback: readback,
            nextCandidateCursorOffset: nextCandidateCursorOffset(
                candidateSummaries: candidates,
                plannerResult: plannerResult,
                fallbackCount: max(1, selectedAssetIds.count)
            ),
            displayedAssetIds: Set(selectedAssetIds),
            sourceCursor: request.candidateCursor,
            assetPoolIdentity: request.assetPoolIdentity,
            playbackSourceGeneration: request.playbackSourceGeneration
        )
    }

    private nonisolated static func candidateSummary(
        from raw: SmartFillPlanningRawAssetSnapshot
    ) -> PlaybackSmartFillCandidateSummary {
        PlaybackSmartFillCandidateSummary(
            reference: raw.reference ?? reference(for: raw.assetId),
            sourceImage: raw.sourceImageSummary ?? sourceImageSummary(from: raw),
            faceRects: raw.faceRects ?? faceRects(from: raw),
            subjectRects: raw.subjectRects ?? faceRects(from: raw)
        )
    }

    private nonisolated static func reference(for rawId: String) -> String {
        let digest = SHA256.hash(data: Data(rawId.utf8))
        let hashText = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "asset_\(hashText)"
    }

    private nonisolated static func sourceImageSummary(
        from raw: SmartFillPlanningRawAssetSnapshot
    ) -> PlaybackPlanningSourceImageSummary {
        PlaybackPlanningSourceImageSummary(
            assetPixelSize: displayPixelSize(from: raw),
            exifPixelSize: pixelSize(width: raw.exifImageWidth, height: raw.exifImageHeight),
            orientation: raw.orientation == nil ? "unknown" : "available"
        )
    }

    private nonisolated static func displayPixelSize(
        from raw: SmartFillPlanningRawAssetSnapshot
    ) -> PlaybackPlanningPixelSize? {
        let magnitude =
            pixelSize(width: raw.width, height: raw.height)
            ?? pixelSize(width: raw.exifImageWidth, height: raw.exifImageHeight)
        guard let magnitude else { return nil }
        guard let thumbhashIsLandscape = thumbhashIsLandscape(raw.thumbhash) else {
            return pixelSize(width: raw.width, height: raw.height) ?? magnitude
        }

        let longEdge = max(magnitude.width, magnitude.height)
        let shortEdge = min(magnitude.width, magnitude.height)
        if thumbhashIsLandscape {
            return PlaybackPlanningPixelSize(width: longEdge, height: shortEdge)
        }
        return PlaybackPlanningPixelSize(width: shortEdge, height: longEdge)
    }

    private nonisolated static func pixelSize(width: Int?, height: Int?) -> PlaybackPlanningPixelSize? {
        guard let width, let height, width > 0, height > 0 else {
            return nil
        }
        return PlaybackPlanningPixelSize(width: width, height: height)
    }

    private nonisolated static func faceRects(
        from raw: SmartFillPlanningRawAssetSnapshot
    ) -> [PlaybackPlanningRect] {
        raw.rawFaces.compactMap { face in
            guard let imageWidth = face.imageWidth, let imageHeight = face.imageHeight,
                imageWidth > 0, imageHeight > 0,
                let x1 = face.boundingBoxX1, let x2 = face.boundingBoxX2,
                let y1 = face.boundingBoxY1, let y2 = face.boundingBoxY2,
                x1 < x2, y1 < y2,
                x1 >= 0, y1 >= 0,
                x2 <= Double(imageWidth), y2 <= Double(imageHeight)
            else {
                return nil
            }
            return PlaybackPlanningRect(
                x: x1 / Double(imageWidth),
                y: y1 / Double(imageHeight),
                width: (x2 - x1) / Double(imageWidth),
                height: (y2 - y1) / Double(imageHeight)
            )
        }
    }

    private nonisolated static func thumbhashIsLandscape(_ thumbhash: String?) -> Bool? {
        guard let bytes = decodedThumbhashBytes(from: thumbhash), bytes.count > 4 else {
            return nil
        }
        return (bytes[4] & 0x80) != 0
    }

    private nonisolated static func decodedThumbhashBytes(from thumbhash: String?) -> [UInt8]? {
        guard let thumbhash else { return nil }
        var normalized =
            thumbhash
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard !normalized.isEmpty else { return nil }

        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: normalized) else {
            return nil
        }
        return Array(data)
    }

    private nonisolated static func nextCandidateCursorOffset(
        candidateSummaries: [PlaybackSmartFillCandidateSummary],
        plannerResult: PlaybackSmartFillPlannerResult,
        fallbackCount: Int
    ) -> Int {
        let selectedOffsets = plannerResult.slots.compactMap { slot in
            candidateSummaries.firstIndex { $0.reference == slot.candidateReference }
        }
        guard !selectedOffsets.isEmpty else {
            return max(1, fallbackCount)
        }

        let selectedOffsetSet = Set(selectedOffsets)
        guard selectedOffsetSet.contains(0) else {
            return 0
        }
        for offset in 1..<candidateSummaries.count where !selectedOffsetSet.contains(offset) {
            return offset
        }
        return min(candidateSummaries.count, max(fallbackCount, selectedOffsetSet.count))
    }
}

enum PlaybackSmartFillSlotReadiness: Equatable, Sendable {
    case ready(assetId: String, fullsizeURL: URL)
    case pending(assetId: String)
    case failed(assetId: String)

    nonisolated static func resolve(
        assetId: String,
        fullsizeState: AssetStates,
        fullsizeURL: URL?
    ) -> PlaybackSmartFillSlotReadiness {
        switch fullsizeState {
        case .readyToPlay:
            if let fullsizeURL {
                return .ready(assetId: assetId, fullsizeURL: fullsizeURL)
            }
            return .pending(assetId: assetId)
        case .failed, .failedToDownload:
            return .failed(assetId: assetId)
        case .notStarted, .loadingURL, .urlReady, .downloading, .downloaded:
            return .pending(assetId: assetId)
        }
    }
}

struct PlaybackSmartFillPlannerInput: Equatable, Sendable {
    let surface: PlaybackSmartFillSurface
    let candidates: [PlaybackSmartFillCandidateSummary]
    let protectionSnapshot: PlaybackProtectionSnapshot
    let policy: PlaybackSmartFillLayoutPolicy
    let playbackSessionSeed: String
    let sceneOrdinal: Int

    nonisolated init(
        surface: PlaybackSmartFillSurface,
        candidates: [PlaybackSmartFillCandidateSummary],
        protectionSnapshot: PlaybackProtectionSnapshot,
        policy: PlaybackSmartFillLayoutPolicy,
        playbackSessionSeed: String = "default",
        sceneOrdinal: Int = 0
    ) {
        self.surface = surface
        self.candidates = candidates
        self.protectionSnapshot = protectionSnapshot
        self.policy = policy
        self.playbackSessionSeed = playbackSessionSeed
        self.sceneOrdinal = sceneOrdinal
    }
}

enum PlaybackSmartFillSceneType: String, Equatable, Sendable {
    case single
    case double
    case triple
    case fallback

    nonisolated var preservesExistingExifOverlay: Bool {
        switch self {
        case .single, .fallback:
            true
        case .double, .triple:
            false
        }
    }
}

enum PlaybackSmartFillSlotRole: String, Equatable, Sendable {
    case primary
    case secondary
    case tertiary
}

enum PlaybackSmartFillAcceptedSceneSearchTier: String, Equatable, Sendable {
    case double
    case triple
    case singleFill = "single-fill"
    case singleRisk = "single-risk"
    case fallback

    nonisolated init(sceneType: PlaybackSmartFillSceneType) {
        switch sceneType {
        case .double:
            self = .double
        case .triple:
            self = .triple
        case .single:
            self = .singleFill
        case .fallback:
            self = .fallback
        }
    }
}

enum PlaybackSmartFillCurrentAssetDisposition: String, Equatable, Sendable {
    case primarySlot = "primary-slot"
    case secondarySlot = "secondary-slot"
    case tertiarySlot = "tertiary-slot"
    case singleSlot = "single-slot"
    case fallbackCurrent = "fallback-current"
    case absentHardFail = "absent-hard-fail"
}

enum PlaybackSmartFillCurrentAssetAbsentReason: String, Equatable, Sendable {
    case none
    case noLegalLayout = "no-legal-layout"
    case missingMetadata = "missing-metadata"
    case poolScarcity = "pool-scarcity"
    case validatorBlocked = "validator-blocked"
}

enum PlaybackSmartFillVisibleQualityClass: String, Equatable, Sendable {
    case acceptable
    case risky
    case fail
}

enum PlaybackSmartFillLayoutVariant: String, Equatable, Hashable, Sendable {
    case single = "单图"
    case verticalEqual = "vertical-equal"
    case horizontalEqual = "horizontal-equal"
    case topPrimaryBottomSecondary = "top-primary-bottom-secondary"
    case bottomPrimaryTopSecondary = "bottom-primary-top-secondary"
    case leftPrimaryRightSecondary = "left-primary-right-secondary"
    case rightPrimaryLeftSecondary = "right-primary-left-secondary"
    case leftPrimaryRightStack = "left-primary-right-stack"
    case rightPrimaryLeftStack = "right-primary-left-stack"
    case topPrimaryBottomPair = "top-primary-bottom-pair"
    case bottomPrimaryTopPair = "bottom-primary-top-pair"
    case balancedGrid = "balanced-grid"

    nonisolated var isTriple: Bool {
        switch self {
        case .leftPrimaryRightStack, .rightPrimaryLeftStack, .topPrimaryBottomPair, .bottomPrimaryTopPair,
            .balancedGrid:
            return true
        default:
            return false
        }
    }

    nonisolated var sceneType: PlaybackSmartFillSceneType {
        switch self {
        case .single:
            return .single
        case .verticalEqual, .horizontalEqual, .topPrimaryBottomSecondary, .bottomPrimaryTopSecondary,
            .leftPrimaryRightSecondary, .rightPrimaryLeftSecondary:
            return .double
        case .leftPrimaryRightStack, .rightPrimaryLeftStack, .topPrimaryBottomPair, .bottomPrimaryTopPair,
            .balancedGrid:
            return .triple
        }
    }
}

struct PlaybackSmartFillRatioPreset: Equatable, Hashable, Sendable {
    let id: String
    let primaryShare: Double
}

struct PlaybackSmartFillUpperBodyProxyParams: Equatable, Sendable {
    let horizontalFaceScale: Double
    let topFaceMargin: Double
    let bottomFaceExtension: Double

    nonisolated static let defaultSpec = PlaybackSmartFillUpperBodyProxyParams(
        horizontalFaceScale: 2.4,
        topFaceMargin: 0.3,
        bottomFaceExtension: 3.0
    )
}

struct PlaybackSmartFillAspectRatioRange: Equatable, Sendable {
    let minimum: Double
    let maximum: Double

    nonisolated static let commonPhotoExtreme = PlaybackSmartFillAspectRatioRange(
        minimum: 9.0 / 16.0,
        maximum: 16.0 / 9.0
    )

    nonisolated func contains(_ value: Double) -> Bool {
        value >= minimum && value <= maximum
    }
}

enum PlaybackSmartFillProtectionStatus: String, Equatable, Sendable {
    case notApplied = "not-applied"
    case accepted
    case rejected
}

enum PlaybackSmartFillFaceProtectionStatus: String, Equatable, Sendable {
    case notApplied = "not-applied"
    case accepted
    case rejected
}

enum PlaybackSmartFillProtectedRectSource: String, Equatable, Sendable {
    case face
    case subject
    case upperBodyProxy
}

struct PlaybackSmartFillProtectionOverlapDetail: Equatable, Sendable {
    let protectedSource: PlaybackSmartFillProtectedRectSource
    let regionSource: PlaybackProtectionSource
    let regionPriority: PlaybackProtectionPriority
    let cropRect: PlaybackPlanningRect
    let mappedRect: PlaybackPlanningRect
    let hardRejected: Bool
    let systemSafeAreaSoftWarning: Bool
}

struct PlaybackSmartFillProtectionSummary: Equatable, Sendable {
    let status: PlaybackSmartFillProtectionStatus
    let checkedRegionCount: Int
    let overlappingRegionCount: Int
    let hardOverlapCount: Int
    let softOverlayOverlapWarningCount: Int
    let controlBarSubjectOverlapWarningCount: Int
    let exifOverlayOverlapWarningCount: Int
    let controlBarHardRejected: Bool
    let exifOverlayHardRejected: Bool
    let overlapDetails: [PlaybackSmartFillProtectionOverlapDetail]

    nonisolated static let accepted = PlaybackSmartFillProtectionSummary(
        status: .accepted,
        checkedRegionCount: 0,
        overlappingRegionCount: 0
    )

    nonisolated init(
        status: PlaybackSmartFillProtectionStatus,
        checkedRegionCount: Int,
        overlappingRegionCount: Int,
        hardOverlapCount: Int? = nil,
        softOverlayOverlapWarningCount: Int = 0,
        controlBarSubjectOverlapWarningCount: Int = 0,
        exifOverlayOverlapWarningCount: Int = 0,
        controlBarHardRejected: Bool = false,
        exifOverlayHardRejected: Bool = false,
        overlapDetails: [PlaybackSmartFillProtectionOverlapDetail] = []
    ) {
        self.status = status
        self.checkedRegionCount = checkedRegionCount
        self.overlappingRegionCount = overlappingRegionCount
        self.hardOverlapCount = hardOverlapCount ?? overlappingRegionCount
        self.softOverlayOverlapWarningCount = softOverlayOverlapWarningCount
        self.controlBarSubjectOverlapWarningCount = controlBarSubjectOverlapWarningCount
        self.exifOverlayOverlapWarningCount = exifOverlayOverlapWarningCount
        self.controlBarHardRejected = controlBarHardRejected
        self.exifOverlayHardRejected = exifOverlayHardRejected
        self.overlapDetails = overlapDetails
    }
}

struct PlaybackSmartFillReadabilitySummary: Equatable, Sendable {
    let minimumSecondaryArea: Double
    let smallestSecondaryArea: Double?
    let accepted: Bool
}

struct PlaybackSmartFillSlot: Equatable, Sendable {
    let role: PlaybackSmartFillSlotRole
    let candidateReference: String
    let frameInScene: PlaybackPlanningRect
    let cropRectInSource: PlaybackPlanningRect
    let sourceImageSummary: PlaybackPlanningSourceImageSummary
    let rejectRisks: [PlaybackSmartFillPlannerRejectReason]
    let cropRetention: Double
    let protectionContained: Bool
    let slotAspectRatio: Double

    nonisolated init(
        role: PlaybackSmartFillSlotRole,
        candidateReference: String,
        frameInScene: PlaybackPlanningRect,
        cropRectInSource: PlaybackPlanningRect,
        sourceImageSummary: PlaybackPlanningSourceImageSummary,
        rejectRisks: [PlaybackSmartFillPlannerRejectReason],
        cropRetention: Double = 1,
        protectionContained: Bool = true,
        slotAspectRatio: Double = 1
    ) {
        self.role = role
        self.candidateReference = candidateReference
        self.frameInScene = frameInScene
        self.cropRectInSource = cropRectInSource
        self.sourceImageSummary = sourceImageSummary
        self.rejectRisks = rejectRisks
        self.cropRetention = cropRetention
        self.protectionContained = protectionContained
        self.slotAspectRatio = slotAspectRatio
    }
}

struct PlaybackSmartFillPlannerResult: Equatable, Sendable {
    let sceneType: PlaybackSmartFillSceneType
    let layoutPolicyId: String
    let surfaceKey: String
    let layoutVariant: PlaybackSmartFillLayoutVariant
    let ratioPreset: String
    let slots: [PlaybackSmartFillSlot]
    let fallbackReason: PlaybackSmartFillFallbackReason?
    let fallbackCategory: PlaybackSmartFillFallbackCategory
    let rejectReasonsTried: [PlaybackSmartFillPlannerRejectReason]
    let rejectedLayoutReasonTopList: [PlaybackSmartFillPlannerRejectReason]
    let qualityDecision: PlaybackPlanningQualityDecision
    let faceProtectionSummary: PlaybackSmartFillFaceProtectionStatus
    let protectionSummary: PlaybackSmartFillProtectionSummary
    let readabilitySummary: PlaybackSmartFillReadabilitySummary
    let candidateWindowUsed: Int
    let evaluationCount: Int
    let rotationStartLayoutVariant: PlaybackSmartFillLayoutVariant
    let rotationStartRatioPreset: String
    let acceptedLayoutVariant: PlaybackSmartFillLayoutVariant
    let acceptedRatioPreset: String
    let rotationKeyHashPrefix: String
    let reasonCodes: [String]
    let qaDebugSummary: String
    let acceptedSceneSearchTier: PlaybackSmartFillAcceptedSceneSearchTier
    let currentAssetDisposition: PlaybackSmartFillCurrentAssetDisposition
    let currentAssetAbsentReason: PlaybackSmartFillCurrentAssetAbsentReason
    let currentAssetSlotAreaRatio: Double?
    let currentAssetCropRetention: Double?
    let currentAssetProtectedRegionCoverage: Double?
    let currentAssetFaceProtectionPassed: Bool
    let currentAssetSubjectProtectionPassed: Bool
    let currentAssetVisibleQualityClass: PlaybackSmartFillVisibleQualityClass
    let ledgerSceneAssets: [String]
    let slotRoles: [PlaybackSmartFillSlotRole]
    let slotRefs: [String]

    nonisolated init(
        sceneType: PlaybackSmartFillSceneType,
        layoutPolicyId: String,
        surfaceKey: String = "unknown-surface",
        layoutVariant: PlaybackSmartFillLayoutVariant = .single,
        ratioPreset: String = "full",
        slots: [PlaybackSmartFillSlot],
        fallbackReason: PlaybackSmartFillFallbackReason?,
        fallbackCategory: PlaybackSmartFillFallbackCategory = .none,
        rejectReasonsTried: [PlaybackSmartFillPlannerRejectReason],
        rejectedLayoutReasonTopList: [PlaybackSmartFillPlannerRejectReason] = [],
        qualityDecision: PlaybackPlanningQualityDecision,
        faceProtectionSummary: PlaybackSmartFillFaceProtectionStatus,
        protectionSummary: PlaybackSmartFillProtectionSummary,
        readabilitySummary: PlaybackSmartFillReadabilitySummary,
        candidateWindowUsed: Int = 1,
        evaluationCount: Int = 0,
        rotationStartLayoutVariant: PlaybackSmartFillLayoutVariant = .single,
        rotationStartRatioPreset: String = "full",
        acceptedLayoutVariant: PlaybackSmartFillLayoutVariant = .single,
        acceptedRatioPreset: String = "full",
        rotationKeyHashPrefix: String = "none",
        reasonCodes: [String],
        qaDebugSummary: String,
        acceptedSceneSearchTier: PlaybackSmartFillAcceptedSceneSearchTier? = nil,
        currentAssetDisposition: PlaybackSmartFillCurrentAssetDisposition,
        currentAssetAbsentReason: PlaybackSmartFillCurrentAssetAbsentReason,
        currentAssetSlotAreaRatio: Double? = nil,
        currentAssetCropRetention: Double? = nil,
        currentAssetProtectedRegionCoverage: Double? = nil,
        currentAssetFaceProtectionPassed: Bool,
        currentAssetSubjectProtectionPassed: Bool,
        currentAssetVisibleQualityClass: PlaybackSmartFillVisibleQualityClass,
        ledgerSceneAssets: [String]? = nil,
        slotRoles: [PlaybackSmartFillSlotRole]? = nil,
        slotRefs: [String]? = nil
    ) {
        self.sceneType = sceneType
        self.layoutPolicyId = layoutPolicyId
        self.surfaceKey = surfaceKey
        self.layoutVariant = layoutVariant
        self.ratioPreset = ratioPreset
        self.slots = slots
        self.fallbackReason = fallbackReason
        self.fallbackCategory = fallbackCategory
        self.rejectReasonsTried = rejectReasonsTried
        self.rejectedLayoutReasonTopList = rejectedLayoutReasonTopList
        self.qualityDecision = qualityDecision
        self.faceProtectionSummary = faceProtectionSummary
        self.protectionSummary = protectionSummary
        self.readabilitySummary = readabilitySummary
        self.candidateWindowUsed = candidateWindowUsed
        self.evaluationCount = evaluationCount
        self.rotationStartLayoutVariant = rotationStartLayoutVariant
        self.rotationStartRatioPreset = rotationStartRatioPreset
        self.acceptedLayoutVariant = acceptedLayoutVariant
        self.acceptedRatioPreset = acceptedRatioPreset
        self.rotationKeyHashPrefix = rotationKeyHashPrefix
        self.reasonCodes = reasonCodes
        self.qaDebugSummary = qaDebugSummary
        self.acceptedSceneSearchTier =
            acceptedSceneSearchTier ?? PlaybackSmartFillAcceptedSceneSearchTier(sceneType: sceneType)
        self.currentAssetDisposition = currentAssetDisposition
        self.currentAssetAbsentReason = currentAssetAbsentReason
        self.currentAssetSlotAreaRatio = currentAssetSlotAreaRatio
        self.currentAssetCropRetention = currentAssetCropRetention
        self.currentAssetProtectedRegionCoverage = currentAssetProtectedRegionCoverage
        self.currentAssetFaceProtectionPassed = currentAssetFaceProtectionPassed
        self.currentAssetSubjectProtectionPassed = currentAssetSubjectProtectionPassed
        self.currentAssetVisibleQualityClass = currentAssetVisibleQualityClass
        self.ledgerSceneAssets = ledgerSceneAssets ?? slots.map(\.candidateReference)
        self.slotRoles = slotRoles ?? slots.map(\.role)
        self.slotRefs = slotRefs ?? slots.map(\.candidateReference)
    }
}

struct PlaybackSmartFillSceneReadback: Equatable, Sendable {
    let version: String
    let sceneType: PlaybackSmartFillSceneType
    let layoutPolicyId: String
    let surfaceKey: String
    let layoutVariant: PlaybackSmartFillLayoutVariant
    let ratioPreset: String
    let slotRoles: [PlaybackSmartFillSlotRole]
    let fallbackReason: PlaybackSmartFillFallbackReason?
    let fallbackCategory: PlaybackSmartFillFallbackCategory
    let candidateWindowUsed: Int
    let evaluationCount: Int
    let rotationStartLayoutVariant: PlaybackSmartFillLayoutVariant
    let rotationStartRatioPreset: String
    let acceptedLayoutVariant: PlaybackSmartFillLayoutVariant
    let acceptedRatioPreset: String
    let rotationKeyHashPrefix: String
    let rejectedLayoutReasonTopList: [PlaybackSmartFillPlannerRejectReason]
    let reasonCodes: [String]
    let actionTimestamp: TimeInterval?
    let scenePublishTimestamp: TimeInterval?
    let actionToSceneLatencyMilliseconds: Double?
    let qaDebugSummary: String

    nonisolated init(
        version: String,
        sceneType: PlaybackSmartFillSceneType,
        layoutPolicyId: String,
        surfaceKey: String = "unknown-surface",
        layoutVariant: PlaybackSmartFillLayoutVariant = .single,
        ratioPreset: String = "full",
        slotRoles: [PlaybackSmartFillSlotRole],
        fallbackReason: PlaybackSmartFillFallbackReason?,
        fallbackCategory: PlaybackSmartFillFallbackCategory = .none,
        candidateWindowUsed: Int = 1,
        evaluationCount: Int = 0,
        rotationStartLayoutVariant: PlaybackSmartFillLayoutVariant = .single,
        rotationStartRatioPreset: String = "full",
        acceptedLayoutVariant: PlaybackSmartFillLayoutVariant = .single,
        acceptedRatioPreset: String = "full",
        rotationKeyHashPrefix: String = "none",
        rejectedLayoutReasonTopList: [PlaybackSmartFillPlannerRejectReason] = [],
        reasonCodes: [String],
        actionTimestamp: TimeInterval? = nil,
        scenePublishTimestamp: TimeInterval? = nil,
        actionToSceneLatencyMilliseconds: Double? = nil,
        qaDebugSummary: String
    ) {
        self.version = version
        self.sceneType = sceneType
        self.layoutPolicyId = layoutPolicyId
        self.surfaceKey = surfaceKey
        self.layoutVariant = layoutVariant
        self.ratioPreset = ratioPreset
        self.slotRoles = slotRoles
        self.fallbackReason = fallbackReason
        self.fallbackCategory = fallbackCategory
        self.candidateWindowUsed = candidateWindowUsed
        self.evaluationCount = evaluationCount
        self.rotationStartLayoutVariant = rotationStartLayoutVariant
        self.rotationStartRatioPreset = rotationStartRatioPreset
        self.acceptedLayoutVariant = acceptedLayoutVariant
        self.acceptedRatioPreset = acceptedRatioPreset
        self.rotationKeyHashPrefix = rotationKeyHashPrefix
        self.rejectedLayoutReasonTopList = rejectedLayoutReasonTopList
        self.reasonCodes = reasonCodes
        self.actionTimestamp = actionTimestamp
        self.scenePublishTimestamp = scenePublishTimestamp
        self.actionToSceneLatencyMilliseconds = actionToSceneLatencyMilliseconds
        self.qaDebugSummary = qaDebugSummary
    }

    nonisolated func recordingPublishTiming(
        actionTimestamp: TimeInterval,
        scenePublishTimestamp: TimeInterval
    ) -> PlaybackSmartFillSceneReadback {
        let latencyMilliseconds = max(0, (scenePublishTimestamp - actionTimestamp) * 1000)
        return PlaybackSmartFillSceneReadback(
            version: version,
            sceneType: sceneType,
            layoutPolicyId: layoutPolicyId,
            surfaceKey: surfaceKey,
            layoutVariant: layoutVariant,
            ratioPreset: ratioPreset,
            slotRoles: slotRoles,
            fallbackReason: fallbackReason,
            fallbackCategory: fallbackCategory,
            candidateWindowUsed: candidateWindowUsed,
            evaluationCount: evaluationCount,
            rotationStartLayoutVariant: rotationStartLayoutVariant,
            rotationStartRatioPreset: rotationStartRatioPreset,
            acceptedLayoutVariant: acceptedLayoutVariant,
            acceptedRatioPreset: acceptedRatioPreset,
            rotationKeyHashPrefix: rotationKeyHashPrefix,
            rejectedLayoutReasonTopList: rejectedLayoutReasonTopList,
            reasonCodes: reasonCodes,
            actionTimestamp: actionTimestamp,
            scenePublishTimestamp: scenePublishTimestamp,
            actionToSceneLatencyMilliseconds: latencyMilliseconds,
            qaDebugSummary: qaSummaryRecordingPublishTiming(
                actionTimestamp: actionTimestamp,
                scenePublishTimestamp: scenePublishTimestamp,
                latencyMilliseconds: latencyMilliseconds
            )
        )
    }

    private nonisolated func qaSummaryRecordingPublishTiming(
        actionTimestamp: TimeInterval,
        scenePublishTimestamp: TimeInterval,
        latencyMilliseconds: Double
    ) -> String {
        let timingPrefixes = [
            "actionTimestamp=",
            "scenePublishTimestamp=",
            "actionToSceneLatencyMs="
        ]
        let retainedParts =
            qaDebugSummary
            .split(separator: ";")
            .map(String.init)
            .filter { part in
                !timingPrefixes.contains { part.hasPrefix($0) }
            }
        return
            (retainedParts + [
                "actionTimestamp=\(Self.format(actionTimestamp))",
                "scenePublishTimestamp=\(Self.format(scenePublishTimestamp))",
                "actionToSceneLatencyMs=\(Self.format(latencyMilliseconds))"
            ]).joined(separator: ";")
    }

    private nonisolated static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
