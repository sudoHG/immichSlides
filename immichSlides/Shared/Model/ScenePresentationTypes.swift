//
//  ScenePresentationTypes.swift
//  immichSlides
//

import Foundation

extension PlaybackSessionEngine {
    enum ScenePresentationPhase: String, Equatable, Sendable {
        case empty
        case stablePhoto
        case grace
        case transition
        case loading
        case incomingFromLoading
        case paused
        case sourceError
    }

    enum ScenePresentationLayerRole: String, Equatable, Sendable {
        case stable
        case outgoing
        case incoming

        /// For a first scene with only an incoming layer, a first-frame opacity of 0 must not count as background;
        /// transitions with an outgoing layer keep the original meaning.

        static func isCurrentForRenderer(
            role: Self,
            opacity: Double,
            hasOutgoingLayer: Bool
        ) -> Bool {
            role != .outgoing && (opacity > 0 || !hasOutgoingLayer)
        }
    }

    enum ScenePresentationRequestSource: String, Equatable, Sendable {
        case automatic
        case manualNext
        case manualPrevious

        var isManual: Bool {
            self != .automatic
        }
    }

    enum ScenePresentationTargetReadiness: String, Equatable, Sendable {
        case pending
        case ready
        case failed
    }

    enum ScenePresentationSuspensionReason: String, Hashable, Sendable {
        case userPaused
        case background
    }

    /// Composite identity so async callbacks stay bound to one generation, scene, slot and asset for their lifetime.
    struct ScenePresentationIdentity: Hashable, Sendable {
        // Preserve the historical seed; it is not the standard FNV-1a offset basis.
        private static let diagnosticHashSeed: UInt64 = 1_469_598_103_934_665_603
        private static let diagnosticHashMultiplier: UInt64 = 1_099_511_628_211
        let generation: UUID
        let sceneID: String
        let slotID: String?
        let assetID: String?

        init(
            generation: UUID,
            sceneID: String,
            slotID: String? = nil,
            assetID: String? = nil
        ) {
            self.generation = generation
            self.sceneID = sceneID
            self.slotID = slotID
            self.assetID = assetID
        }

        /// Diagnostics output only a stable hash, never the raw scene or resource ids.
        var privateIdentifier: String {
            let source = "\(generation.uuidString)|\(sceneID)|\(slotID ?? "-")|\(assetID ?? "-")"
            var hash: UInt64 = Self.diagnosticHashSeed
            for byte in source.utf8 {
                hash ^= UInt64(byte)
                hash &*= Self.diagnosticHashMultiplier
            }
            return String(hash, radix: 16)
        }
    }

    struct ScenePresentationTarget: Equatable, Sendable {
        let identity: ScenePresentationIdentity
        let lifecycle: SceneLifecycleContract

        init(
            identity: ScenePresentationIdentity,
            configuredInterval: TimeInterval,
            incomingFadeDuration: TimeInterval = SceneLifecycleContract.incomingFadeDuration
        ) {
            self.identity = identity
            self.lifecycle = SceneLifecycleContract(
                configuredInterval: configuredInterval,
                incomingFadeDuration: incomingFadeDuration
            )
        }

        /// Rebuild the window only once this incoming is known to no longer contribute motion; at creation, do not
        /// guess whether playback resumes later.

        func replacingVisibleIncomingFadeDuration(_ duration: TimeInterval) -> Self {
            Self(
                identity: identity,
                configuredInterval: lifecycle.configuredInterval,
                incomingFadeDuration: duration
            )
        }
    }

    /// Render facts for one layer in a snapshot; the identity lasts from the hidden prerender until the fade-out ends.
    struct SceneRenderLayer: Identifiable, Equatable, Sendable {
        let identity: ScenePresentationIdentity
        let role: ScenePresentationLayerRole
        let opacity: Double
        let motionActiveTime: TimeInterval
        let isMotionEnabled: Bool
        let fadeStartTime: TimeInterval?
        let fadeDuration: TimeInterval
        let isPresentationReady: Bool

        var id: ScenePresentationIdentity { identity }
    }

    struct SceneRenderSnapshot: Equatable, Sendable {
        let phase: ScenePresentationPhase
        let underlyingPhase: ScenePresentationPhase
        let layers: [SceneRenderLayer]
        let currentTarget: ScenePresentationTarget?
        let frozenInterval: TimeInterval?
        let activeTime: TimeInterval
        let suspensionReasons: Set<ScenePresentationSuspensionReason>
        let isReduceMotionEnabled: Bool
        let isPendingTargetReady: Bool
    }

    enum TargetAttemptOutcome: String, Equatable, Sendable {
        case pending
        case ready
        case failed
        case cancelled
        case exhausted
    }

    /// Attempt ledger, independent of SmartFill metrics.
    struct TargetAttemptRecord: Equatable, Sendable {
        let generation: UUID
        let privateIdentifier: String
        let source: ScenePresentationRequestSource
        let attemptNumber: Int
        let startedAt: TimeInterval
        var outcome: TargetAttemptOutcome

        init(
            identity: ScenePresentationIdentity,
            source: ScenePresentationRequestSource,
            attemptNumber: Int,
            startedAt: TimeInterval,
            outcome: TargetAttemptOutcome
        ) {
            generation = identity.generation
            privateIdentifier = identity.privateIdentifier
            self.source = source
            self.attemptNumber = attemptNumber
            self.startedAt = startedAt
            self.outcome = outcome
        }
    }

    struct TargetAttemptSummary: Equatable, Sendable {
        let totalAttemptCount: Int
        let readyAttemptCount: Int
        let failedAttemptCount: Int
        let pendingAttemptCount: Int
        let cancelledAttemptCount: Int

        init(records: [TargetAttemptRecord]) {
            totalAttemptCount = records.count
            readyAttemptCount = records.filter { $0.outcome == .ready }.count
            failedAttemptCount = records.filter { $0.outcome == .failed || $0.outcome == .exhausted }.count
            pendingAttemptCount = records.filter { $0.outcome == .pending }.count
            cancelledAttemptCount = records.filter { $0.outcome == .cancelled }.count
        }
    }

    enum ScenePresentationEvent: Equatable, Sendable {
        case start(target: ScenePresentationTarget, readiness: ScenePresentationTargetReadiness)
        case request(
            target: ScenePresentationTarget, source: ScenePresentationRequestSource,
            readiness: ScenePresentationTargetReadiness)
        case stableDeadlineReached(target: ScenePresentationTarget, readiness: ScenePresentationTargetReadiness)
        case targetReady(ScenePresentationIdentity)
        case targetFailed(ScenePresentationIdentity)
        case graceExpired
        case transitionCompleted
        case wakeUp(generation: UUID, deadline: TimeInterval)
        case incomingBecameVisible(ScenePresentationIdentity)
        case suspend(ScenePresentationSuspensionReason)
        case resume(ScenePresentationSuspensionReason)
        case reduceMotionChanged(Bool)
        case intervalTemplateChanged(TimeInterval)
        case loadMoreNeeded(generation: UUID)
        case sourceExhausted
        case cancelUnseenManualPendingPresentation
        case effectResult(ScenePresentationEffectResult)
    }
}
