import Foundation
import Combine
import CryptoKit
import CoreGraphics
import OSLog

extension SlideShowViewModel {
    func syncPlaybackReadbackFromSession() {
        // If autoplay is off at startup, send that to the reducer first, so layers created or made Ready later inherit
        // the paused clock.

        if !isAutoPlay {
            executeScenePresentationEffects(
                playbackSession.reduceScenePresentation(
                    .suspend(.userPaused),
                    at: scenePresentationTimestamp()
                )
            )
        }
        if playbackSession.pendingTransition != nil {
            beginPendingScenePresentationIfNeeded()
        } else if playbackSession.isPresentationEmpty,
            let started = playbackSession.startScenePresentation(
                configuredInterval: autoPlayInterval,
                at: scenePresentationTimestamp()
            ),
            let scene = playbackSession.scene(for: started.identity)
        {
            scenePresentationEffectExecutor.beginBarrier(identity: started.identity, scene: scene)
            executeScenePresentationEffects(started.effects)
        }
        publishPlaybackPosition()
        #if DEBUG
        downloadManager.markPlaybackImageRequestLifecycleLateResultsForDiagnostics(
            currentNavigationToken: targetTransitionToken
        )
        #endif
        publishScenePresentationChange()
    }

    private func beginPendingScenePresentationIfNeeded() {
        guard let transition = playbackSession.pendingTransition else { return }
        let pendingCandidateAcceptance = candidateProgression.capturePendingAcceptance()
        guard
            let started = playbackSession.beginScenePresentation(
                for: transition,
                configuredInterval: autoPlayInterval,
                at: scenePresentationTimestamp()
            )
        else {
            runtimeEvidenceRecorder.discardActionTimestamp(for: transition.transaction.id)
            return
        }
        recordScenePublishTiming(for: transition)
        candidateProgression.accept(
            pendingCandidateAcceptance, appendsNewTailScene: started.appendsNewTailScene, assetCount: assets.count)
        if !applySmartFillMotionLookaheadPreparedPlanIfReady() {
            refreshPreparedSmartFillSceneRingIfPossible()
        }
        scenePresentationEffectExecutor.beginBarrier(identity: started.identity, scene: transition.scene)
        executeScenePresentationEffects(started.effects)
    }

    func scenePresentationTimestamp() -> TimeInterval {
        #if DEBUG
        if let scenePresentationTimestampProviderForTesting { return scenePresentationTimestampProviderForTesting() }
        #endif
        return ProcessInfo.processInfo.systemUptime
    }

    func toggleAutoPlayFromUserInteraction() {
        updateAutoPlayEnabled(!isAutoPlay, persistPreference: true)
    }

    func applyPlaybackSettings(_ settings: PlaybackSettings) {
        updateAutoPlayEnabled(settings.autoPlayEnabled, persistPreference: false)
        autoPlayInterval = PlaybackIntervalPolicy.migratedLegacyInterval(settings.intervalSeconds)
        let previousDisplayMode = playbackDisplayMode
        playbackDisplayMode = settings.displayMode
        if previousDisplayMode != playbackDisplayMode {
            rebuildCurrentSceneForDisplayModeChange()
        }
    }

    private func updateAutoPlayEnabled(_ enabled: Bool, persistPreference: Bool) {
        guard isAutoPlay != enabled else {
            if persistPreference {
                var settings = playbackSettingsStore.load() ?? PlaybackSettings()
                settings.autoPlayEnabled = enabled
                playbackSettingsStore.save(settings)
            }
            return
        }
        isAutoPlay = enabled
        let event: PlaybackSessionEngine.ScenePresentationEvent =
            enabled
            ? .resume(.userPaused)
            : .suspend(.userPaused)
        executeScenePresentationEffects(
            playbackSession.reduceScenePresentation(
                event,
                at: scenePresentationTimestamp()
            )
        )
        publishScenePresentationChange()
        guard persistPreference else { return }
        var settings = playbackSettingsStore.load() ?? PlaybackSettings()
        settings.autoPlayEnabled = enabled
        playbackSettingsStore.save(settings)
    }

    func executeScenePresentationEffects(_ effects: [ScenePresentationEffect], shouldPublishChanges: Bool = true) {
        let images = ScenePresentationEffectExecutor.ImageLoading(
            loadInitialScene: { scene in
                await self.loadInitialSceneAssetsForPlayback(scene)
            },
            loadTransitionScene: { scene, isPrevious, navigationToken in
                await self.loadSceneAssetsForTransition(
                    scene, isPreviousTransition: isPrevious, navigationToken: navigationToken)
            },
            preloadCandidateWindow: {
                _ = await self.preloadSmartFillCandidateWindowIfNeeded(
                    startingAt: self.candidateProgression.currentCursorIndex)
            },
            preloadPlaybackWindow: {
                await self.preloadPlaybackWindowAfterTransitionIfReady()
            }
        )
        for effect in effects {
            scenePresentationEffectExecutor.execute(
                effect,
                scene: sceneForPresentationEffect(effect),
                isInitialScene: { identity in
                    self.playbackSession.isInitialPresentation(identity)
                },
                images: images,
                loadMore: { await self.loadMoreAssets() },
                forward: executeScenePresentationFacadeCommand
            )
        }
        if shouldPublishChanges {
            publishScenePresentationChange()
        }
    }

    private func sceneForPresentationEffect(_ effect: ScenePresentationEffect) -> PlaybackScene? {
        switch effect {
        case let .restartPreparation(request), let .download(request), let .retry(request, _):
            return playbackSession.scene(for: request.identity)
        default:
            return nil
        }
    }

    private func executeScenePresentationFacadeCommand(_ command: ScenePresentationEffectExecutor.FacadeCommand) {
        switch command {
        case let .plan(request):
            switch request.purpose {
            case .nextAutomaticTarget, .replaceExhaustedTarget:
                guard isAutoPlay else { return }
                pendingAutomaticScenePlanningRequest = request
                requestAutomaticSceneTarget()
            }
        case let .scheduleWakeUp(generation, deadline):
            scheduleScenePresentationWakeUp(generation: generation, deadline: deadline)
        case let .cancelWakeUp(generation):
            scenePresentationWakeUpScheduler.cancel(generation: generation)
        case let .cancelPlanning(identity):
            if pendingAutomaticScenePlanningRequest?.target.identity == identity {
                pendingAutomaticScenePlanningRequest = nil
            }
        case let .requestManualDirection(source):
            switch source {
            case .manualPrevious:
                requestPreviousScene()
            case .manualNext, .automatic:
                requestNextScene()
            }
        }
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

    private func scheduleScenePresentationWakeUp(
        generation: UUID,
        deadline: TimeInterval
    ) {
        #if DEBUG
        guard scenePresentationTimestampProviderForTesting == nil else {
            scenePresentationWakeUpScheduler.scheduleWithoutSleepingForTesting(
                generation: generation, deadline: deadline)
            return
        }
        #endif
        scenePresentationWakeUpScheduler.schedule(generation: generation, deadline: deadline)
    }

    #if DEBUG
    /// Tests only fire the wake-up the owner already scheduled; no separate autoplay clock is created.
    @discardableResult
    func fireScheduledScenePresentationWakeUpForTesting() -> TimeInterval? {
        scenePresentationWakeUpScheduler.fireScheduledWakeUpForTesting()
    }
    #endif

    func rendererDecoded(_ identity: SceneRendererIdentity) {
        let historyCountBefore = playbackSession.presentationHistoryCount
        runtimeEvidenceRecorder.recordRendererDecoded()
        guard case let .presentationReady(layerIdentity)? = scenePresentationEffectExecutor.rendererDecoded(identity)
        else {
            runtimeEvidenceRecorder.recordPresentationReadiness(
                isReady: false,
                historyUnchanged: playbackSession.presentationHistoryCount == historyCountBefore
            )
            publishScenePresentationChange()
            return
        }
        runtimeEvidenceRecorder.recordPresentationReadiness(
            isReady: true,
            historyUnchanged: playbackSession.presentationHistoryCount == historyCountBefore
        )
        guard
            let presentationIdentity = playbackSession.presentationIdentity(
                generation: layerIdentity.generation,
                sceneID: layerIdentity.sceneID
            )
        else {
            publishScenePresentationChange()
            return
        }
        executeScenePresentationEffects(
            playbackSession.reduceScenePresentation(
                .targetReady(presentationIdentity),
                at: scenePresentationTimestamp()
            )
        )
    }

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

    func incomingBecameVisible(_ layerIdentity: ScenePresentationLayerIdentity) {
        guard
            let commit = playbackSession.incomingBecameVisible(
                layerIdentity, at: scenePresentationTimestamp(),
                update: { update in
                    switch update {
                    case .effects(let effects):
                        executeScenePresentationEffects(effects)
                    case .committingScene(let scene):
                        runtimeEvidenceRecorder.recordVisibleTickCommittedHistory()
                        for slot in scene?.photoSlots ?? [] {
                            recordSmartFillFirstImageDisplayed(assetId: slot.asset.id)
                        }
                    }
                }
            )
        else { return }
        let displayReason: String
        switch commit.source {
        case .manualNext:
            displayReason = "manual"
        case .manualPrevious:
            displayReason = "manual"
        case .autoplay:
            displayReason = "auto"
        case .none:
            displayReason = "initial"
        }
        logDisplayedAsset(
            reason: displayReason,
            previousIndex: commit.previousIndex,
            previousAssetId: commit.previousAssetID,
            requestedIndex: currentIndex,
            displayedIndex: currentIndex
        )
        requestLoadMoreAfterVisibleSceneIfNeeded(generation: commit.identity.generation)
        scenePresentationEffectExecutor.releaseBarrier(for: commit.identity)
        publishScenePresentationChange()
    }

    private func requestLoadMoreAfterVisibleSceneIfNeeded(generation: UUID) {
        let loadMoreProgressIndex = candidateProgressIndexForLoadMore
        let shouldTriggerLoadMore = Self.shouldTriggerLoadMore(
            assetCount: assets.count,
            newIndex: loadMoreProgressIndex,
            isSoloOnlyPlayback: isSoloOnlyPlaybackSource,
            soloOnlyRemainingTriggerCount: soloOnlyLoadMoreRemainingTriggerCount
        )
        #if DEBUG
        logQAPlaybackSequenceEventIfNeeded(
            .loadMoreDecision(
                assetCount: assets.count,
                candidateCursorIndex: candidateProgression.currentCursorIndex,
                candidateProgressIndexForLoadMore: loadMoreProgressIndex,
                soloOnly: isSoloOnlyPlaybackSource,
                isLoadingMore: isLoadingMore,
                shouldTrigger: shouldTriggerLoadMore,
                currentIndex: currentIndex,
                targetIndex: targetIndex,
                displayedAssetCount: runtimeEvidenceRecorder.displayedAssetRecordCount
            ))
        #endif
        guard shouldTriggerLoadMore, !isLoadingMore else { return }
        executeScenePresentationEffects(
            playbackSession.reduceScenePresentation(
                .loadMoreNeeded(generation: generation),
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
