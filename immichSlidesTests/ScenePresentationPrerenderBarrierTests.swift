import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite
struct ScenePresentationPrerenderBarrierTests {
    @Test
    func `animation profile preserves raw progress for renderers past the waypoint`() {
        let profile = SceneAnimationProfile(
            lifecycle: SceneLifecycleContract(configuredInterval: 5)
        )

        #expect(abs(profile.rawProgress(for: 4.95) - 0.99) < 0.000_1)
        #expect(abs(profile.rawProgress(for: 5) - 1) < 0.000_1)
        #expect(profile.rawProgress(for: 5.05) > 1)
    }

    @Test
    func `presentation ready fires only after every slot decodes and a second generation is rejected`() {
        let generation = UUID()
        let scene = ScenePresentationLayerIdentity(
            generation: generation,
            sceneID: "scene-a",
            layerID: "scene-root"
        )
        let attemptID = UUID()
        let renderers: Set<SceneRendererIdentity> = [
            .init(
                generation: generation, attemptID: attemptID, sceneID: "scene-a", slotID: "slot-1", assetID: "asset-1"),
            .init(
                generation: generation, attemptID: attemptID, sceneID: "scene-a", slotID: "slot-2", assetID: "asset-2"),
            .init(
                generation: generation, attemptID: attemptID, sceneID: "scene-a", slotID: "slot-3", assetID: "asset-3")
        ]
        var barrier = ScenePresentationPrerenderBarrier()

        let didBegin = barrier.begin(scene: scene, expectedRenderers: renderers)
        #expect(didBegin)
        let didBeginSecondGeneration = barrier.begin(
            scene: .init(generation: UUID(), sceneID: "scene-b", layerID: "scene-root"),
            expectedRenderers: renderers
        )
        #expect(!didBeginSecondGeneration)

        let ordered = renderers.sorted { $0.assetID > $1.assetID }
        let firstDecoded = barrier.rendererDecoded(ordered[0])
        let secondDecoded = barrier.rendererDecoded(ordered[1])
        #expect(firstDecoded == nil)
        #expect(secondDecoded == nil)
        #expect(!barrier.isPresentationReady)
        let finalDecoded = barrier.rendererDecoded(ordered[2])
        #expect(finalDecoded == .presentationReady(scene))
        #expect(barrier.isPresentationReady)
        let duplicateDecoded = barrier.rendererDecoded(ordered[2])
        #expect(duplicateDecoded == nil)
    }

    @Test
    func `restarting the barrier for the same scene rejects callbacks from the stale attempt`() {
        let generation = UUID()
        let scene = ScenePresentationLayerIdentity(
            generation: generation,
            sceneID: "scene-a",
            layerID: "scene-root"
        )
        let firstAttemptID = UUID()
        let secondAttemptID = UUID()
        let staleRenderer = SceneRendererIdentity(
            generation: generation,
            attemptID: firstAttemptID,
            sceneID: "scene-a",
            slotID: "slot-1",
            assetID: "asset-1"
        )
        let activeRenderer = SceneRendererIdentity(
            generation: generation,
            attemptID: secondAttemptID,
            sceneID: "scene-a",
            slotID: "slot-1",
            assetID: "asset-1"
        )
        var barrier = ScenePresentationPrerenderBarrier()

        let didBeginFirstAttempt = barrier.begin(scene: scene, expectedRenderers: [staleRenderer])
        let didReleaseFirstAttempt = barrier.release(scene: scene)
        let didBeginSecondAttempt = barrier.begin(scene: scene, expectedRenderers: [activeRenderer])

        #expect(didBeginFirstAttempt)
        #expect(didReleaseFirstAttempt)
        #expect(didBeginSecondAttempt)

        let staleDecodedEvent = barrier.rendererDecoded(staleRenderer)
        let didAcceptStaleFailure = barrier.rendererFailed(staleRenderer)
        let activeDecodedEvent = barrier.rendererDecoded(activeRenderer)

        #expect(staleDecodedEvent == nil)
        #expect(!didAcceptStaleFailure)
        #expect(activeDecodedEvent == .presentationReady(scene))
        #expect(barrier.isPresentationReady)
    }

    @Test
    func `renderer readiness is not history; only the next display tick after a root transaction reports visibility`() {
        let scene = ScenePresentationLayerIdentity(
            generation: UUID(),
            sceneID: "scene-a",
            layerID: "scene-root"
        )
        let eligible = SceneVisibleFrameCandidate(
            layerIdentity: scene,
            role: .incoming,
            opacity: 0.01,
            isBarrierComplete: true,
            isSceneRoot: true
        )
        var reporter = SceneVisibleFrameReporter()

        let didArm = reporter.transactionCompleted(candidate: eligible)
        #expect(didArm)
        let visibleLayer = reporter.consumeDisplayTick(currentCandidate: eligible)
        #expect(visibleLayer == scene)
        let didRearm = reporter.transactionCompleted(candidate: eligible)
        #expect(!didRearm)
        let duplicateTick = reporter.consumeDisplayTick(currentCandidate: eligible)
        #expect(duplicateTick == nil)

        var staleReporter = SceneVisibleFrameReporter()
        let didArmStale = staleReporter.transactionCompleted(candidate: eligible)
        #expect(didArmStale)
        let staleRole = SceneVisibleFrameCandidate(
            layerIdentity: scene,
            role: .outgoing,
            opacity: 0.01,
            isBarrierComplete: true,
            isSceneRoot: true
        )
        let staleTick = staleReporter.consumeDisplayTick(currentCandidate: staleRole)
        #expect(staleTick == nil)

        let perSlot = SceneVisibleFrameCandidate(
            layerIdentity: scene,
            role: .incoming,
            opacity: 1,
            isBarrierComplete: true,
            isSceneRoot: false
        )
        let didArmPerSlot = staleReporter.transactionCompleted(candidate: perSlot)
        #expect(!didArmPerSlot)
    }

    @Test
    func `a stable initial scene after a paused start still reports on a real display tick exactly once`() {
        let scene = ScenePresentationLayerIdentity(
            generation: UUID(),
            sceneID: "initial-stable",
            layerID: "scene-root"
        )
        let stable = SceneVisibleFrameCandidate(
            layerIdentity: scene,
            role: .stable,
            opacity: 1,
            isBarrierComplete: true,
            isSceneRoot: true
        )
        var reporter = SceneVisibleFrameReporter()

        let didArmStable = reporter.transactionCompleted(candidate: stable)
        #expect(didArmStable)
        let didReportStable = reporter.consumeDisplayTick(currentCandidate: stable)
        #expect(didReportStable == scene)
        let didRearmStable = reporter.transactionCompleted(candidate: stable)
        #expect(!didRearmStable)
    }
}
