//
//  ScenePresentationEffect.swift
//  immichSlides
//
//  The shared scene reducer only emits commands; the ViewModel only runs them and reports results back.
//

import Foundation

/// Pure-value command: holds no task, network or presentation state, so there is never a second owner.

enum ScenePresentationEffect: Equatable, Sendable {
    case plan(ScenePresentationPlanningRequest)
    case restartPreparation(ScenePresentationEffectRequest)
    case download(ScenePresentationEffectRequest)
    case retry(ScenePresentationEffectRequest, attemptNumber: Int)
    case loadMore(generation: UUID)
    case scheduleWakeUp(generation: UUID, deadline: TimeInterval)
    case cancelWakeUp(generation: UUID)
    case cancel(ScenePresentationEffectRequest)
    case requestManualDirection(PlaybackSessionEngine.ScenePresentationRequestSource)
}

/// Why the reducer requests a new automatic target; barrier preparation is a separate effect.
enum ScenePresentationPlanningPurpose: Equatable, Sendable {
    case nextAutomaticTarget
    case replaceExhaustedTarget
}

/// Demand identity is the reducer tag plus its target and purpose; it is independent of the prepared proposal's fingerprint.
struct ScenePresentationPlanningRequest: Equatable, Sendable {
    let tag: UInt64
    let target: ScenePresentationEffectRequest
    let purpose: ScenePresentationPlanningPurpose
}

/// An effect carries the generation and scene identity, so the reducer can drop its result.
struct ScenePresentationEffectRequest: Equatable, Sendable {
    let identity: PlaybackSessionEngine.ScenePresentationIdentity
    let source: PlaybackSessionEngine.ScenePresentationRequestSource

    init(
        identity: PlaybackSessionEngine.ScenePresentationIdentity,
        source: PlaybackSessionEngine.ScenePresentationRequestSource
    ) {
        self.identity = identity
        self.source = source
    }
}

/// Execution result; the facade sends planning completions, and the test runner builds the other matching reducer events.
enum ScenePresentationEffectResult: Equatable, Sendable {
    case planningCompleted(ScenePresentationPlanningRequest)
    case ready(PlaybackSessionEngine.ScenePresentationIdentity)
    case failed(PlaybackSessionEngine.ScenePresentationIdentity)
    case sourceExhausted(generation: UUID)
    case cancelled(PlaybackSessionEngine.ScenePresentationIdentity)
}
