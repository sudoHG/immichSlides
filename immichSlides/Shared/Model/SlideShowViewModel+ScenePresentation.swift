import Foundation
import Combine
import CryptoKit
import CoreGraphics
import OSLog

extension SlideShowViewModel {
    func scenePresentationTimestamp() -> TimeInterval {
        #if DEBUG
        if let scenePresentationTimestampProviderForTesting { return scenePresentationTimestampProviderForTesting() }
        #endif
        return ProcessInfo.processInfo.systemUptime
    }

    var currentSceneDownloadCompletion: ScenePresentationEffectExecutor.DownloadCompletion? {
        guard let identity = playbackSession.currentPresentationIdentity else { return nil }
        return scenePresentationEffectExecutor.downloadCompletion(for: identity)
    }

    /// Proposal delivery happens first; rejecting demand must not undo preparation or its image preloads.
    func preparedScenePlanningDidComplete(_ request: ScenePresentationPlanningRequest?) {
        guard let request, playbackSession.pendingTransition == nil else { return }
        let effects = playbackSession.reduceScenePresentation(
            .effectResult(.planningCompleted(request)), at: scenePresentationTimestamp())
        // The original completion published only through navigation, not an extra executor publication.
        executeScenePresentationEffects(effects, shouldPublishChanges: false)
    }

    #if DEBUG
    /// Tests only fire the wake-up the owner already scheduled; no separate autoplay clock is created.
    @discardableResult
    func fireScheduledScenePresentationWakeUpForTesting() -> TimeInterval? {
        scenePresentationWakeUpScheduler.fireScheduledWakeUpForTesting()
    }
    #endif

    func rendererFailed(_ identity: SceneRendererIdentity) {
        guard scenePresentationEffectExecutor.rendererFailed(identity),
            let presentationIdentity = playbackSession.presentationIdentity(
                generation: identity.generation,
                sceneID: identity.sceneID
            )
        else {
            return
        }
        executeScenePresentationEffects(
            playbackSession.reduceScenePresentation(
                .targetFailed(presentationIdentity),
                at: scenePresentationTimestamp()
            )
        )
    }

    /// The view asks for this label on every drawn frame (on iOS also on each state change), so in DEBUG it also records
    /// frames that show less than half a photo once the first scene has appeared, and the crossfade frames it draws.
    /// Tests compare these records around an action to catch what falls between their samples; only whether the counts
    /// change is meaningful, not their exact values.
    func scenePresentationContractProbeLabel(
        for snapshot: PlaybackSessionEngine.SceneRenderSnapshot
    ) -> String {
        let progressValues = snapshot.layers.map { layer -> Double in
            guard let target = playbackSession.presentationTarget(for: layer.identity) else { return 0 }
            let activeTime = Self.renderedMotionActiveTime(of: layer, lifecycle: target.lifecycle)
            return SceneAnimationProfile(lifecycle: target.lifecycle).rawProgress(for: activeTime)
        }
        return runtimeEvidenceRecorder.scenePresentationContractProbeLabel(
            for: snapshot,
            progressValues: progressValues,
            historyCount: playbackSession.presentationHistoryCount
        )
    }

    func motionEligibility(
        scene: PlaybackScene,
        renderRole: MotionRenderRole,
        platform: MotionPlatform,
        isReduceMotionEnabled: Bool
    ) -> MotionEligibilityResult {
        MotionEligibilityPolicy.acceptedSceneRuntime.evaluate(
            MotionEligibilityInput(
                platform: platform,
                sceneCapability: motionSceneCapability(for: scene),
                displayMode: playbackDisplayMode == .smartFill ? .smartFill : .singlePhoto,
                focalAdapter: .smartFill,
                isReduceMotionEnabled: isReduceMotionEnabled,
                renderRole: renderRole,
                slotReadiness: motionSlotReadiness(for: scene)
            )
        )
    }

    func motionPlatformForCurrentSurface() -> MotionPlatform {
        guard let profile = smartFillSurface?.profile else { return .iOS }
        return MotionPlatform(smartFillSurfaceProfile: profile)
    }

    func motionSceneCapability(for scene: PlaybackScene) -> MotionSceneCapability {
        guard let readback = scene.smartFillReadback else {
            return scene.photoSlots.count == 1 ? .legacySinglePhoto : .other
        }
        switch readback.sceneType {
        case .double, .triple:
            return .smartFillAccepted
        case .single:
            return .smartFillSingle
        case .fallback:
            return .smartFillFallback
        }
    }

    private func motionSlotReadiness(for scene: PlaybackScene) -> MotionSlotReadiness {
        guard !scene.photoSlots.isEmpty else { return .failed }
        var hasPendingSlot = false
        for slot in scene.photoSlots {
            let readiness = PlaybackSmartFillSlotReadiness.resolve(
                assetId: slot.asset.id,
                fullsizeState: downloadManager.assetStates[slot.asset.id] ?? .notStarted,
                fullsizeURL: downloadManager.findURL(assetId: slot.asset.id, size: .fullsize)
            )
            switch readiness {
            case .ready:
                continue
            case .pending:
                hasPendingSlot = true
            case .failed:
                return .failed
            }
        }
        return hasPendingSlot ? .pending : .ready
    }
}
