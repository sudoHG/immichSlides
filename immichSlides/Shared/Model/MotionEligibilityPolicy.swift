import Foundation

enum MotionPlatform: String, Equatable, Sendable {
    case iOS
    case iPadOS
    case tvOS
}

enum MotionSceneCapability: String, Equatable, Sendable {
    case smartFillAccepted
    case smartFillSingle
    case smartFillFallback
    case legacySinglePhoto
    case other
}

enum MotionDisplayMode: String, Equatable, Sendable {
    case smartFill
    case singlePhoto
}

enum MotionFocalAdapter: String, Equatable, Sendable {
    case smartFill
    case person
    case soloOnly
    case cropCenter
    case slotCenter
}

enum MotionSlotReadiness: String, Equatable, Sendable {
    case ready
    case pending
    case failed
}

enum MotionPlatformScope: String, Equatable, Sendable {
    case iOSAndIPadOS
    case tvOSAcceptedSceneRuntime
    case tvOSDisabled
}

enum MotionRuntimeIntegration: String, Equatable, Sendable {
    case architectureOnly
    case acceptedSceneRuntime
}

enum MotionIdentityReason: String, Equatable, Sendable {
    case platformDisabled
    case displayModeDisabled
    case fallbackDisabled
    case legacyUnchanged
    case otherSceneDisabled
    case futureVisualBehaviorDeferred
    case reduceMotion
    case slotNotReady
    case prerender
}

struct MotionEligibilityInput: Equatable, Sendable {
    let platform: MotionPlatform
    let sceneCapability: MotionSceneCapability
    let displayMode: MotionDisplayMode
    let focalAdapter: MotionFocalAdapter
    let isReduceMotionEnabled: Bool
    let renderRole: MotionRenderRole
    let slotReadiness: MotionSlotReadiness
}

struct MotionEligibilityResult: Equatable, Sendable {
    let isTransformEnabled: Bool
    let isScheduleEnabled: Bool
    let identityReason: MotionIdentityReason?
    let platformScope: MotionPlatformScope
    let runtimeIntegration: MotionRuntimeIntegration
}

struct MotionEligibilityPolicy: Equatable, Sendable {
    nonisolated static let architectureOnly = MotionEligibilityPolicy(
        runtimeIntegration: .architectureOnly
    )
    nonisolated static let acceptedSceneRuntime = MotionEligibilityPolicy(
        runtimeIntegration: .acceptedSceneRuntime
    )

    let runtimeIntegration: MotionRuntimeIntegration

    nonisolated func evaluate(_ input: MotionEligibilityInput) -> MotionEligibilityResult {
        let platformScope = platformScope(for: input.platform)
        guard isRuntimeSupportedPlatform(input.platform) else {
            return disabled(input, platformScope: platformScope, reason: .platformDisabled)
        }
        switch input.sceneCapability {
        case .smartFillAccepted, .smartFillSingle:
            break
        case .smartFillFallback:
            return disabled(input, platformScope: platformScope, reason: .fallbackDisabled)
        case .legacySinglePhoto:
            return disabled(input, platformScope: platformScope, reason: .legacyUnchanged)
        case .other:
            return disabled(input, platformScope: platformScope, reason: .otherSceneDisabled)
        }

        guard input.displayMode == .smartFill else {
            return disabled(input, platformScope: platformScope, reason: .displayModeDisabled)
        }

        switch input.focalAdapter {
        case .person, .soloOnly:
            return disabled(input, platformScope: platformScope, reason: .futureVisualBehaviorDeferred)
        case .smartFill, .cropCenter, .slotCenter:
            break
        }

        guard !input.isReduceMotionEnabled else {
            return disabled(input, platformScope: platformScope, reason: .reduceMotion)
        }
        guard input.slotReadiness == .ready else {
            return disabled(input, platformScope: platformScope, reason: .slotNotReady)
        }
        guard !Self.isPrerender(input.renderRole) else {
            return disabled(input, platformScope: platformScope, reason: .prerender)
        }

        return MotionEligibilityResult(
            isTransformEnabled: true,
            isScheduleEnabled: Self.isSettled(input.renderRole),
            identityReason: nil,
            platformScope: platformScope,
            runtimeIntegration: runtimeIntegration
        )
    }

    private nonisolated func disabled(
        _ input: MotionEligibilityInput,
        platformScope: MotionPlatformScope,
        reason: MotionIdentityReason
    ) -> MotionEligibilityResult {
        MotionEligibilityResult(
            isTransformEnabled: false,
            isScheduleEnabled: false,
            identityReason: reason,
            platformScope: platformScope,
            runtimeIntegration: runtimeIntegration
        )
    }

    private nonisolated func platformScope(for platform: MotionPlatform) -> MotionPlatformScope {
        switch platform {
        case .iOS, .iPadOS:
            return .iOSAndIPadOS
        case .tvOS:
            switch runtimeIntegration {
            case .architectureOnly:
                return .tvOSDisabled
            case .acceptedSceneRuntime:
                return .tvOSAcceptedSceneRuntime
            }
        }
    }

    private nonisolated func isRuntimeSupportedPlatform(_ platform: MotionPlatform) -> Bool {
        switch platform {
        case .iOS, .iPadOS:
            return true
        case .tvOS:
            return runtimeIntegration == .acceptedSceneRuntime
        }
    }

    private nonisolated static func isPrerender(_ renderRole: MotionRenderRole) -> Bool {
        switch renderRole {
        case .prerender:
            return true
        case .settled, .outgoing, .incoming:
            return false
        }
    }

    private nonisolated static func isSettled(_ renderRole: MotionRenderRole) -> Bool {
        switch renderRole {
        case .settled:
            return true
        case .outgoing, .incoming, .prerender:
            return false
        }
    }
}
