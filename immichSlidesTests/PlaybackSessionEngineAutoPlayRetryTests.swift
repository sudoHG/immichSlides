//
//  PlaybackSessionEngineAutoPlayRetryTests.swift
//  immichSlidesTests
//
//  Tests auto advance and retry in ScenePresentationState; does not go through SlideShowViewModel.
//

import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite(.sharedRuntimeIsolation)
struct PlaybackSessionEngineAutoPlayRetryTests {
    private let intervalSeconds: TimeInterval = 5

    @Test
    func `automatic request first failure is recorded and issues a second attempt`() {
        var engine = PlaybackSessionEngine()
        let target = makeTarget(sceneID: "automatic")

        engine.reduceScenePresentation(.start(target: target, readiness: .pending), at: 0)
        let effects = engine.reduceScenePresentation(.targetFailed(target.identity), at: 1)

        #expect(
            effects == [
                .retry(
                    .init(identity: target.identity, source: .automatic),
                    attemptNumber: 2
                )
            ])
        #expect(engine.scenePresentationState.attemptSummary.totalAttemptCount == 2)
        #expect(engine.scenePresentationState.attemptSummary.failedAttemptCount == 1)
        #expect(engine.scenePresentationState.attemptSummary.pendingAttemptCount == 1)
    }

    @Test
    func `automatic request exhausting the retry budget falls back to a plan effect`() {
        var engine = PlaybackSessionEngine()
        let target = makeTarget(sceneID: "automatic-exhausted")
        let request = ScenePresentationEffectRequest(
            identity: target.identity,
            source: .automatic
        )

        engine.reduceScenePresentation(.start(target: target, readiness: .pending), at: 0)
        var terminalEffects: [ScenePresentationEffect] = []
        for attempt in 1...(SceneLifecycleContract.retryLimit + 1) {
            terminalEffects = engine.reduceScenePresentation(
                .targetFailed(target.identity),
                at: TimeInterval(attempt)
            )
        }

        #expect(terminalEffects == [.plan(.init(tag: 1, target: request, purpose: .replaceExhaustedTarget))])
        #expect(engine.scenePresentationState.attemptSummary.totalAttemptCount == 4)
        #expect(engine.scenePresentationState.attemptSummary.failedAttemptCount == 4)
        #expect(engine.scenePresentationState.attemptSummary.pendingAttemptCount == 0)
    }

    @Test
    func `manual previous failure keeps its direction across retry`() {
        var engine = PlaybackSessionEngine()
        let target = makeTarget(sceneID: "manual-previous")
        let request = ScenePresentationEffectRequest(
            identity: target.identity,
            source: .manualPrevious
        )

        engine.reduceScenePresentation(
            .request(target: target, source: .manualPrevious, readiness: .pending),
            at: 0
        )
        let effects = engine.reduceScenePresentation(.targetFailed(target.identity), at: 1)

        #expect(effects == [.retry(request, attemptNumber: 2)])
        #expect(engine.scenePresentationState.attemptRecords.last?.source == .manualPrevious)
    }

    @Test
    func `manual next exhausting the retry budget requests a new target in the same direction`() {
        var engine = PlaybackSessionEngine()
        let target = makeTarget(sceneID: "manual-next-exhausted")

        engine.reduceScenePresentation(
            .request(target: target, source: .manualNext, readiness: .pending),
            at: 0
        )
        var terminalEffects: [ScenePresentationEffect] = []
        for attempt in 1...(SceneLifecycleContract.retryLimit + 1) {
            terminalEffects = engine.reduceScenePresentation(
                .targetFailed(target.identity),
                at: TimeInterval(attempt)
            )
        }

        #expect(terminalEffects == [.requestManualDirection(.manualNext)])
        #expect(
            !terminalEffects.contains(
                .plan(
                    .init(
                        tag: 1, target: .init(identity: target.identity, source: .manualNext),
                        purpose: .replaceExhaustedTarget))))
    }

    private func makeTarget(
        sceneID: String
    ) -> PlaybackSessionEngine.ScenePresentationTarget {
        PlaybackSessionEngine.ScenePresentationTarget(
            identity: .init(
                generation: UUID(),
                sceneID: sceneID,
                assetID: "asset-\(sceneID)"
            ),
            configuredInterval: intervalSeconds
        )
    }
}
