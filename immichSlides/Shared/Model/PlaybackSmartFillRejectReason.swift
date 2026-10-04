//
//  PlaybackSmartFillRejectReason.swift
//  immichSlides
//
//  Smart Fill planning reject reasons. Only pure model reason codes live here, so tests and the QA manifest can
//  read them back.
//

import Foundation

enum PlaybackSmartFillPlannerRejectReason: String, Equatable, Hashable, Sendable {
    case missingCandidates = "missing-candidates"
    case imageNotReady = "image-not-ready"
    case missingImageSize = "missing-image-size"
    case horizontalDoubleDisallowedOnSurface = "horizontal-double-disallowed-on-surface"
    case verticalDoubleDisallowedOnSurface = "vertical-double-disallowed-on-surface"
    case tripleDisallowedOnSurface = "triple-disallowed-on-surface"
    case insufficientCandidatesForDouble = "insufficient-candidates-for-double"
    case insufficientCandidatesForTriple = "insufficient-candidates-for-triple"
    case triplePhotoWallRejected = "triple-photo-wall-rejected"
    case auxiliaryUnreadable = "auxiliary-unreadable"
    case faceCropDestroyed = "face-crop-destroyed"
    case protectionOverlap = "protection-overlap"
    case effectivePixelsTooLow = "effective-pixels-too-low"
    case cropRetentionTooLow = "crop-retention-too-low"
    case slotAspectRatioOutOfRange = "slot-aspect-ratio-out-of-range"
    case layoutCanvasNotFilled = "layout-canvas-not-filled"
    case candidateWindowExhausted = "candidate-window-exhausted"
    case primaryCandidateRejected = "primary-candidate-rejected"
    case allLayoutsRejected = "all-layouts-rejected"
}

enum PlaybackSmartFillFallbackReason: String, Equatable, Sendable {
    case none = "none"
    case missingCandidates = "missing-candidates"
    case allLayoutsRejected = "all-layouts-rejected"
    case imageNotReady = "image-not-ready"
}

enum PlaybackSmartFillFallbackCategory: String, Equatable, Sendable {
    case none
    case legalFallback = "legal-fallback"
    case layoutReject = "layout-reject"
    case controlBarTriggered = "controlbar-triggered"
    case exifTriggered = "exif-triggered"
    case pendingResourceTriggered = "pending-resource-triggered"
    case recoveryFallback = "recovery-fallback"
    case unknown

    nonisolated static func classify(
        fallbackReason: PlaybackSmartFillFallbackReason?,
        rejectReasons: [PlaybackSmartFillPlannerRejectReason],
        protectionSummary: PlaybackSmartFillProtectionSummary
    ) -> PlaybackSmartFillFallbackCategory {
        guard let fallbackReason, fallbackReason != .none else { return .none }
        if protectionSummary.controlBarHardRejected {
            return .controlBarTriggered
        }
        if protectionSummary.exifOverlayHardRejected {
            return .exifTriggered
        }
        if fallbackReason == .imageNotReady || rejectReasons.contains(.imageNotReady) {
            return .pendingResourceTriggered
        }

        switch fallbackReason {
        case .none:
            return .none
        case .missingCandidates:
            return .legalFallback
        case .imageNotReady:
            return .pendingResourceTriggered
        case .allLayoutsRejected:
            return classifyRejectedLayouts(rejectReasons)
        }
    }

    private nonisolated static func classifyRejectedLayouts(
        _ rejectReasons: [PlaybackSmartFillPlannerRejectReason]
    ) -> PlaybackSmartFillFallbackCategory {
        let layoutRejectReasons: Set<PlaybackSmartFillPlannerRejectReason> = [
            .layoutCanvasNotFilled,
            .cropRetentionTooLow,
            .slotAspectRatioOutOfRange,
            .faceCropDestroyed,
            .protectionOverlap,
            .effectivePixelsTooLow,
            .auxiliaryUnreadable,
            .triplePhotoWallRejected,
            .primaryCandidateRejected
        ]
        if rejectReasons.contains(where: { layoutRejectReasons.contains($0) }) {
            return .layoutReject
        }
        if rejectReasons.contains(.missingImageSize) {
            return .legalFallback
        }
        if rejectReasons.contains(.candidateWindowExhausted) || rejectReasons.contains(.insufficientCandidatesForDouble)
            || rejectReasons.contains(.insufficientCandidatesForTriple)
        {
            return .legalFallback
        }
        return .unknown
    }
}
