import CoreGraphics
import Foundation

struct MotionUnitRect: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    nonisolated var validCenter: CGPoint? {
        guard width > 0, height > 0 else { return nil }
        return CGPoint(x: x + width * 0.5, y: y + height * 0.5)
    }
}

enum MotionPhaseAction: Equatable, Sendable {
    case identity
    case showStartWithoutAnimation
    case animateForwardAndHold
}

enum MotionRenderRole: Equatable, Sendable {
    case settled
    case outgoing
    case incoming
    case prerender

    nonisolated func phaseAction(progress: Double) -> MotionPhaseAction {
        switch self {
        case .prerender:
            return .identity
        case .incoming, .settled, .outgoing:
            return progress > 0 ? .animateForwardAndHold : .showStartWithoutAnimation
        }
    }

    nonisolated func progress(
        for clock: MotionPresentationClock,
        at currentTime: TimeInterval
    ) -> Double {
        switch self {
        case .prerender:
            return 0
        case .incoming, .settled, .outgoing:
            return clock.progress(at: currentTime)
        }
    }
}

enum MotionFocalSourceKind: Equatable, Sendable {
    case face
    case subject
    case person
    case soloOnly
    case cropCenterFallback
    case slotCenterFallback
}

enum MotionFocalProvenance: Equatable, Sendable {
    case runtimeFaceSummary
    case runtimeSubjectSummary
    case cropRectFallback
    case slotCenterFallback
    case futurePersonAdapter
    case futureSoloOnlyAdapter
}

struct MotionFocalSource: Equatable, Sendable {
    let kind: MotionFocalSourceKind
    let centerInSource: CGPoint?
    let rectInSource: MotionUnitRect?
    let provenance: MotionFocalProvenance

    nonisolated static func face(
        centerInSource: CGPoint?,
        rectInSource: MotionUnitRect?,
        provenance: MotionFocalProvenance = .runtimeFaceSummary
    ) -> MotionFocalSource {
        MotionFocalSource(
            kind: .face,
            centerInSource: centerInSource,
            rectInSource: rectInSource,
            provenance: provenance
        )
    }

    nonisolated static func subject(
        centerInSource: CGPoint?,
        rectInSource: MotionUnitRect?,
        provenance: MotionFocalProvenance = .runtimeSubjectSummary
    ) -> MotionFocalSource {
        MotionFocalSource(
            kind: .subject,
            centerInSource: centerInSource,
            rectInSource: rectInSource,
            provenance: provenance
        )
    }

    nonisolated static func person(centerInSource: CGPoint?) -> MotionFocalSource {
        MotionFocalSource(
            kind: .person,
            centerInSource: centerInSource,
            rectInSource: nil,
            provenance: .futurePersonAdapter
        )
    }

    nonisolated static func soloOnly(centerInSource: CGPoint?) -> MotionFocalSource {
        MotionFocalSource(
            kind: .soloOnly,
            centerInSource: centerInSource,
            rectInSource: nil,
            provenance: .futureSoloOnlyAdapter
        )
    }

    nonisolated static let cropCenterFallback = MotionFocalSource(
        kind: .cropCenterFallback,
        centerInSource: nil,
        rectInSource: nil,
        provenance: .cropRectFallback
    )
    nonisolated static let slotCenterFallback = MotionFocalSource(
        kind: .slotCenterFallback,
        centerInSource: nil,
        rectInSource: nil,
        provenance: .slotCenterFallback
    )
}

extension PlaybackPlanningFocalSummary {
    nonisolated var motionFocalSource: MotionFocalSource {
        switch source {
        case .face:
            return .face(
                centerInSource: centerInSource,
                rectInSource: rectInSource.motionUnitRect,
                provenance: .runtimeFaceSummary
            )
        case .subject:
            return .subject(
                centerInSource: centerInSource,
                rectInSource: rectInSource.motionUnitRect,
                provenance: .runtimeSubjectSummary
            )
        }
    }
}

extension PlaybackPlanningRect {
    nonisolated var motionUnitRect: MotionUnitRect {
        MotionUnitRect(x: x, y: y, width: width, height: height)
    }
}

struct MotionSlotRenderGeometry: Equatable, Sendable {
    let slotSize: CGSize
    let imageFrameInSlot: CGRect

    nonisolated var isRenderable: Bool {
        slotSize.width > 0 && slotSize.height > 0 && imageFrameInSlot.width > 0 && imageFrameInSlot.height > 0
    }
}

enum MotionTransformApplicationSpace: Equatable, Sendable {
    case slotSizedClippedContainer
}

struct MotionTransformPolicy: Equatable, Sendable {
    nonisolated static let v1Default = MotionTransformPolicy(
        minimumScale: 1.15,
        maximumScale: 1.25,
        panFractionOfSlot: 0.025
    )

    let minimumScale: Double
    let maximumScale: Double
    let panFractionOfSlot: CGFloat
}

enum MotionZoomDirection: String, Equatable, Sendable {
    case zoomIn
    case zoomOut
}

struct MotionTransformDiagnostics: Equatable, Sendable {
    let stableSeedHash: UInt64
    let zoomDirection: MotionZoomDirection
    let seedInputSummary: String
    let requestedTranslationInSlot: CGSize
    let clampedTranslationInSlot: CGSize
    let endTranslationInSlot: CGSize
}

struct MotionFrameIdentity: Equatable, Sendable {
    let sceneId: String
    let slotId: String
    let assetId: String
    let renderRole: MotionRenderRole
    let clockGeneration: Int
}

enum MotionProgressSource: Equatable, Sendable {
    case sceneActiveTime
    case presentationClock
}

struct MotionRenderProgressFrame: Equatable, Sendable {
    let identity: MotionFrameIdentity
    let source: MotionProgressSource

    private let rawProgress: Double

    nonisolated var progress: Double {
        rawProgress
    }

    private nonisolated init(
        identity: MotionFrameIdentity,
        progress: Double,
        source: MotionProgressSource
    ) {
        self.identity = identity
        self.rawProgress = progress
        self.source = source
    }

    nonisolated static func fromSceneActiveTime(
        identity: MotionFrameIdentity,
        rawProgress: Double
    ) -> MotionRenderProgressFrame {
        MotionRenderProgressFrame(
            identity: identity,
            progress: rawProgress,
            source: .sceneActiveTime
        )
    }

    nonisolated static func fromPresentationClock(
        identity: MotionFrameIdentity,
        clock: MotionPresentationClock,
        at currentTime: TimeInterval
    ) -> MotionRenderProgressFrame {
        return MotionRenderProgressFrame(
            identity: identity,
            progress: identity.renderRole.progress(for: clock, at: currentTime),
            source: .presentationClock
        )
    }
}

struct MotionTransformInput: Equatable, Sendable {
    let progressFrame: MotionRenderProgressFrame
    /// The coverage endpoint is planned once before resolve; it is not re-planned per frame at runtime.

    let maximumCoverageProgress: Double
    let renderGeometry: MotionSlotRenderGeometry
    let cropRectInSource: MotionUnitRect
    let focalSource: MotionFocalSource
    let isMotionEnabled: Bool
    let reduceMotionEnabled: Bool
}

struct MotionTransform: Equatable, Sendable {
    nonisolated static let identity = MotionTransform(
        scale: 1,
        translationInSlot: .zero,
        anchorUnitPointInSlot: CGPoint(x: 0.5, y: 0.5),
        applicationSpace: .slotSizedClippedContainer,
        phaseAction: .identity,
        focalSource: .slotCenterFallback
    )

    let scale: Double
    let translationInSlot: CGSize
    let anchorUnitPointInSlot: CGPoint
    let applicationSpace: MotionTransformApplicationSpace
    let phaseAction: MotionPhaseAction
    let focalSource: MotionFocalSourceKind

    nonisolated var isIdentity: Bool {
        abs(scale - 1) < 0.000_1 && abs(translationInSlot.width) < 0.000_1 && abs(translationInSlot.height) < 0.000_1
            && abs(anchorUnitPointInSlot.x - 0.5) < 0.000_1 && abs(anchorUnitPointInSlot.y - 0.5) < 0.000_1
            && Self.isSlotSizedClippedContainer(applicationSpace) && Self.isIdentityPhaseAction(phaseAction)
            && Self.isSlotCenter(focalSource)
    }

    private nonisolated static func isSlotSizedClippedContainer(_ applicationSpace: MotionTransformApplicationSpace)
        -> Bool
    {
        switch applicationSpace {
        case .slotSizedClippedContainer:
            return true
        }
    }

    private nonisolated static func isIdentityPhaseAction(_ phaseAction: MotionPhaseAction) -> Bool {
        switch phaseAction {
        case .identity:
            return true
        case .showStartWithoutAnimation, .animateForwardAndHold:
            return false
        }
    }

    private nonisolated static func isSlotCenter(_ focalSource: MotionFocalSourceKind) -> Bool {
        switch focalSource {
        case .slotCenterFallback:
            return true
        case .face, .subject, .person, .soloOnly, .cropCenterFallback:
            return false
        }
    }
}
