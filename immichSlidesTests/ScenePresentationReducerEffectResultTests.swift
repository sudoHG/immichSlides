import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite
struct ScenePresentationReducerEffectResultTests {
    @Test
    func `replacing a pending target cancels the old effect and drops its stale result`() throws {
        var engine = PlaybackSessionEngine()
        let first = makeTarget(sceneID: "first")
        let second = makeTarget(sceneID: "second")

        let initialEffects = engine.reduceScenePresentation(
            .start(target: first, readiness: .pending),
            at: 0
        )
        let firstRequest = ScenePresentationEffectRequest(identity: first.identity, source: .automatic)
        #expect(initialEffects.contains(.restartPreparation(firstRequest)))
        #expect(initialEffects.contains(.download(firstRequest)))

        let replacementEffects = engine.reduceScenePresentation(
            .request(target: second, source: .manualNext, readiness: .pending),
            at: 1
        )
        #expect(replacementEffects.contains(.cancel(firstRequest)))

        let runner = FakeEffectRunner()
        let staleResult = try #require(runner.completedResult(for: .download(firstRequest)))
        engine.reduceScenePresentation(.effectResult(staleResult), at: 2)
        let state = engine.scenePresentationState

        #expect(state.pendingTarget?.identity == second.identity)
        #expect(state.targetReadiness[first.identity] == .pending)
        #expect(state.attemptSummary.cancelledAttemptCount == 1)
    }

    @Test
    func `automatic failure keeps the fixed grace deadline and the sole owner issues retry and load-more`() throws {
        var engine = PlaybackSessionEngine()
        let current = makeTarget(sceneID: "current")
        let pending = makeTarget(sceneID: "pending")

        engine.reduceScenePresentation(.start(target: current, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(.stableDeadlineReached(target: pending, readiness: .pending), at: 6)
        let beforeFailure = engine.scenePresentationState
        let originalGraceDeadline = try #require(beforeFailure.graceDeadline)

        let retryEffects = engine.reduceScenePresentation(.targetFailed(pending.identity), at: 6.2)
        let expectedRetry = ScenePresentationEffect.retry(
            .init(identity: pending.identity, source: .automatic),
            attemptNumber: 2
        )
        #expect(retryEffects.contains(expectedRetry))
        let afterFailure = engine.scenePresentationState
        #expect(afterFailure.phase == .grace)
        #expect(afterFailure.graceDeadline == originalGraceDeadline)

        let loadMoreEffects = engine.reduceScenePresentation(
            .loadMoreNeeded(generation: pending.identity.generation),
            at: 6.3
        )
        #expect(loadMoreEffects == [.loadMore(generation: pending.identity.generation)])
    }

    @Test
    func `a later automatic target failure does not inherit a finished manual request direction`() throws {
        var engine = PlaybackSessionEngine()
        let current = makeTarget(sceneID: "current")
        let manualTarget = makeTarget(sceneID: "manual")
        let automaticTarget = makeTarget(sceneID: "automatic")

        engine.reduceScenePresentation(.start(target: current, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        engine.reduceScenePresentation(
            .request(target: manualTarget, source: .manualNext, readiness: .pending),
            at: 2
        )
        engine.reduceScenePresentation(
            .request(target: automaticTarget, source: .automatic, readiness: .pending),
            at: 3
        )

        for attempt in 0..<4 {
            let effects = engine.reduceScenePresentation(
                .targetFailed(automaticTarget.identity),
                at: TimeInterval(4 + attempt)
            )
            let request = ScenePresentationEffectRequest(
                identity: automaticTarget.identity,
                source: .automatic
            )
            if attempt < 3 {
                #expect(effects.contains(.retry(request, attemptNumber: attempt + 2)))
            } else {
                #expect(effects.contains(.plan(.init(tag: 1, target: request, purpose: .replaceExhaustedTarget))))
                #expect(!effects.contains(.requestManualDirection(.manualNext)))
            }
        }
    }

    enum PlanningInterruption: CaseIterable {
        case active, pause, background, navigation, cancellation, reset, restoration
        case pausedExhaustionBeforeGraceExpiry, pausedExhaustionAfterGraceExpiry
        case pausedExhaustedTarget
    }

    @Test(arguments: PlanningInterruption.allCases)
    func `planning completion only retries the demand that still applies`(interruption: PlanningInterruption) throws {
        var engine = PlaybackSessionEngine()
        let current = makeTarget(sceneID: "planning-current")
        engine.reduceScenePresentation(.start(target: current, readiness: .ready), at: 0)
        engine.reduceScenePresentation(.transitionCompleted, at: 1)
        let effects = engine.reduceScenePresentation(
            .wakeUp(generation: current.identity.generation, deadline: 6), at: 6)
        var planningRequest = try #require(
            effects.compactMap { effect -> ScenePresentationPlanningRequest? in
                guard case let .plan(request) = effect else { return nil }
                return request
            }.first)
        var completionTime: TimeInterval = 7

        switch interruption {
        case .pause:
            engine.reduceScenePresentation(.suspend(.userPaused), at: 6.1)
        case .background:
            engine.reduceScenePresentation(.suspend(.background), at: 6.1)
        case .navigation, .restoration:
            engine.reduceScenePresentation(
                .request(target: makeTarget(sceneID: "manual"), source: .manualNext, readiness: .pending), at: 6.1)
            if interruption == .restoration {
                engine.reduceScenePresentation(.cancelUnseenManualPendingPresentation, at: 6.2)
            } else {
                engine.reduceScenePresentation(.suspend(.userPaused), at: 6.2)
                let resumeEffects = engine.reduceScenePresentation(.resume(.userPaused), at: 6.3)
                #expect(!resumeEffects.contains(.plan(planningRequest)))
            }
        case .cancellation, .pausedExhaustedTarget:
            let automatic = makeTarget(sceneID: "cancelled-automatic")
            engine.reduceScenePresentation(.stableDeadlineReached(target: automatic, readiness: .pending), at: 6.1)
            engine.reduceScenePresentation(.graceExpired, at: 10)
            engine.reduceScenePresentation(.transitionCompleted, at: 11)
            for attempt in 0..<4 {
                let failureEffects = engine.reduceScenePresentation(
                    .targetFailed(automatic.identity), at: 11.1 + Double(attempt) / 10)
                if attempt == 3 {
                    planningRequest = try #require(
                        failureEffects.compactMap { effect -> ScenePresentationPlanningRequest? in
                            guard case let .plan(request) = effect else { return nil }
                            return request
                        }.first)
                }
            }
            if interruption == .pausedExhaustedTarget {
                engine.reduceScenePresentation(.suspend(.userPaused), at: 11.5)
                #expect(
                    engine.reduceScenePresentation(.effectResult(.planningCompleted(planningRequest)), at: 11.6)
                        .isEmpty)
                let resumeEffects = engine.reduceScenePresentation(.resume(.userPaused), at: 3600)
                #expect(resumeEffects.contains(.plan(planningRequest)))
                completionTime = 3600.1
                break
            }
            let manual = makeTarget(sceneID: "manual-after-cancellation")
            let cancellationEffects = engine.reduceScenePresentation(
                .request(target: manual, source: .manualNext, readiness: .pending), at: 12)
            #expect(cancellationEffects.contains(.cancel(.init(identity: automatic.identity, source: .automatic))))
            for attempt in 0..<4 {
                engine.reduceScenePresentation(.targetFailed(manual.identity), at: 12.1 + Double(attempt) / 10)
            }
            engine.reduceScenePresentation(.suspend(.userPaused), at: 12.5)
            let resumeEffects = engine.reduceScenePresentation(.resume(.userPaused), at: 12.6)
            #expect(!resumeEffects.contains(.plan(planningRequest)))
            completionTime = 13
        case .pausedExhaustionBeforeGraceExpiry, .pausedExhaustionAfterGraceExpiry:
            let automatic = makeTarget(sceneID: "paused-automatic")
            engine.reduceScenePresentation(.stableDeadlineReached(target: automatic, readiness: .pending), at: 6.1)
            engine.reduceScenePresentation(.suspend(.userPaused), at: 6.2)
            for attempt in 0..<4 {
                engine.reduceScenePresentation(.targetFailed(automatic.identity), at: 6.3 + Double(attempt) / 10)
            }
            let resumeEffects = engine.reduceScenePresentation(.resume(.userPaused), at: 6.8)
            let graceDeadline = try #require(
                resumeEffects.compactMap { effect -> TimeInterval? in
                    guard case let .scheduleWakeUp(generation, deadline) = effect,
                        generation == automatic.identity.generation
                    else { return nil }
                    return deadline
                }.first)
            #expect(
                resumeEffects == [
                    .scheduleWakeUp(generation: automatic.identity.generation, deadline: graceDeadline),
                    .plan(planningRequest)
                ])
            if interruption == .pausedExhaustionAfterGraceExpiry {
                engine.reduceScenePresentation(
                    .wakeUp(generation: automatic.identity.generation, deadline: graceDeadline), at: graceDeadline)
                completionTime = graceDeadline + 0.1
            }
        case .reset:
            engine = PlaybackSessionEngine()
            // Production reset creates a new navigation generation, even when the same photo is reused.
            let restarted = makeTarget(sceneID: "planning-current")
            engine.reduceScenePresentation(.start(target: restarted, readiness: .ready), at: 0)
            engine.reduceScenePresentation(.transitionCompleted, at: 1)
            engine.reduceScenePresentation(.wakeUp(generation: restarted.identity.generation, deadline: 6), at: 6)
        case .active:
            break
        }

        let beforeCompletion = engine.sceneRenderSnapshot(at: completionTime)
        let completionEffects = engine.reduceScenePresentation(
            .effectResult(.planningCompleted(planningRequest)), at: completionTime)
        let canComplete =
            interruption == .active || interruption == .background || interruption == .restoration
            || interruption == .pausedExhaustionBeforeGraceExpiry || interruption == .pausedExhaustedTarget
        #expect(completionEffects == (canComplete ? [.plan(planningRequest)] : []))
        #expect(engine.sceneRenderSnapshot(at: completionTime) == beforeCompletion)
        if interruption == .pause {
            let resumeEffects = engine.reduceScenePresentation(.resume(.userPaused), at: 3600)
            #expect(resumeEffects == [.plan(planningRequest)])
        }
    }

    private func makeTarget(sceneID: String) -> PlaybackSessionEngine.ScenePresentationTarget {
        PlaybackSessionEngine.ScenePresentationTarget(
            identity: .init(generation: UUID(), sceneID: sceneID, assetID: "asset-\(sceneID)"),
            configuredInterval: 5
        )
    }
}

/// Test-only fake runner; the production ViewModel still only executes reducer effects.
private struct FakeEffectRunner {
    func completedResult(for effect: ScenePresentationEffect) -> ScenePresentationEffectResult? {
        switch effect {
        case let .download(request):
            return .ready(request.identity)
        case .plan, .restartPreparation, .retry, .loadMore, .scheduleWakeUp, .cancelWakeUp, .cancel,
            .requestManualDirection:
            return nil
        }
    }
}
