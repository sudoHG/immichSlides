//
//  ScenePresentationEffect.swift
//  immichSlides
//
//  The shared scene reducer only emits commands; the ViewModel only runs them and reports results back.
//

import Foundation

/// Pure-value command: holds no task, network or presentation state, so there is never a second owner.

enum ScenePresentationEffect: Equatable, Sendable {
    case plan(ScenePresentationEffectRequest)
    case download(ScenePresentationEffectRequest)
    case retry(ScenePresentationEffectRequest, attemptNumber: Int)
    case loadMore(generation: UUID)
    case scheduleWakeUp(generation: UUID, deadline: TimeInterval)
    case cancelWakeUp(generation: UUID)
    case cancel(ScenePresentationEffectRequest)
    case requestManualDirection(PlaybackSessionEngine.ScenePresentationRequestSource)
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

/// Execution result; the test runner uses it to build the matching reducer event.
enum ScenePresentationEffectResult: Equatable, Sendable {
    case ready(PlaybackSessionEngine.ScenePresentationIdentity)
    case failed(PlaybackSessionEngine.ScenePresentationIdentity)
    case sourceExhausted(generation: UUID)
    case cancelled(PlaybackSessionEngine.ScenePresentationIdentity)
}
