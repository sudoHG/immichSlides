import Foundation
import Combine
import CryptoKit
import CoreGraphics
import OSLog

extension SlideShowViewModel {
    func syncPlaybackReadbackFromEngine() {
        // If autoplay is off at startup, send that to the reducer first, so layers created or made Ready later inherit
        // the paused clock.

        if !isAutoPlay {
            executeScenePresentationEffects(
                playbackSessionEngine.reduceScenePresentation(
                    .suspend(.userPaused),
                    at: scenePresentationTimestamp()
                )
            )
        }
        if playbackSessionEngine.pendingTransition != nil {
            beginPendingScenePresentationIfNeeded()
        } else if playbackSessionEngine.scenePresentationState.underlyingPhase == .empty,
            let started = playbackSessionEngine.startScenePresentation(
                configuredInterval: autoPlayInterval,
                at: scenePresentationTimestamp()
            ),
            let scene = playbackSessionEngine.scene(for: started.identity)
        {
            scenePresentationEffectExecutor.beginBarrier(identity: started.identity, scene: scene)
            executeScenePresentationEffects(started.effects)
        }
        currentIndex = playbackSessionEngine.currentIndex
        targetIndex = playbackSessionEngine.pendingTransition?.targetIndex ?? playbackSessionEngine.currentIndex
        targetTransitionToken = playbackSessionEngine.targetTransitionToken
        #if DEBUG
        downloadManager.markPlaybackImageRequestLifecycleLateResultsForDiagnostics(
            currentNavigationToken: targetTransitionToken
        )
        #endif
        publishScenePresentationChange()
    }

    private func beginPendingScenePresentationIfNeeded() {
        guard let transition = playbackSessionEngine.pendingTransition else { return }
        let requestSource: PlaybackSessionEngine.ScenePresentationRequestSource
        switch transition.transaction.source {
        case .manualNext:
            requestSource = .manualNext
        case .manualPrevious:
            requestSource = .manualPrevious
        case .autoplay:
            requestSource = .automatic
        }
        let isAutomaticStableDeadline =
            requestSource == .automatic && playbackSessionEngine.scenePresentationState.underlyingPhase == .stablePhoto
        let appendsNewTailScene = transition.targetIndex >= playbackSessionEngine.scenes.count
        let pendingCandidateAcceptance = candidateProgression.capturePendingAcceptance()
        guard
            let started = playbackSessionEngine.beginScenePresentation(
                for: transition,
                configuredInterval: autoPlayInterval,
                requestSource: requestSource,
                isAutomaticStableDeadline: isAutomaticStableDeadline,
                at: scenePresentationTimestamp()
            )
        else {
            pendingPlaybackHistoryLedgerCommits[transition.transaction.id] = nil
            runtimeEvidenceRecorder.discardActionTimestamp(for: transition.transaction.id)
            return
        }
        recordScenePublishTiming(for: transition)
        candidateProgression.accept(
            pendingCandidateAcceptance, appendsNewTailScene: appendsNewTailScene, assetCount: assets.count)
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

    func publishScenePresentationChange() {
        scenePresentationRevision = UUID()
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
            playbackSessionEngine.reduceScenePresentation(
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
            loadInitialScene: { [weak self] scene in
                await self?.loadInitialSceneAssetsForPlayback(scene)
            },
            loadTransitionScene: { [weak self] scene, isPrevious, navigationToken in
                await self?.loadSceneAssetsForTransition(
                    scene, isPreviousTransition: isPrevious, navigationToken: navigationToken)
            },
            preloadCandidateWindow: { [weak self] in
                guard let self else { return }
                _ = await self.preloadSmartFillCandidateWindowIfNeeded(
                    startingAt: self.candidateProgression.currentCursorIndex)
            },
            preloadPlaybackWindow: { [weak self] in
                await self?.preloadPlaybackWindowAfterTransitionIfReady()
            }
        )
        for effect in effects {
            if let completion = scenePresentationEffectExecutor.execute(
                effect,
                scene: sceneForPresentationEffect(effect),
                isInitialScene: { [weak self] identity in
                    self?.playbackSessionEngine.transition(for: identity) == nil
                },
                images: images,
                loadMore: { [weak self] in await self?.loadMoreAssets() },
                forward: executeScenePresentationFacadeCommand
            ) {
                sceneDownloadCompletion = completion
            }
        }
        if shouldPublishChanges {
            publishScenePresentationChange()
        }
    }

    private func sceneForPresentationEffect(_ effect: ScenePresentationEffect) -> PlaybackScene? {
        switch effect {
        case let .restartPreparation(request), let .download(request), let .retry(request, _):
            return playbackSessionEngine.scene(for: request.identity)
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
            if sceneDownloadCompletion?.identity == identity {
                sceneDownloadCompletion = nil
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
        let presentationState = playbackSessionEngine.scenePresentationState
        let identity = (presentationState.pendingTarget ?? presentationState.currentTarget)?.identity
        guard let sceneDownloadCompletion, sceneDownloadCompletion.identity == identity else { return nil }
        return sceneDownloadCompletion
    }

    /// Proposal delivery happens first; rejecting demand must not undo preparation or its image preloads.
    func preparedScenePlanningDidComplete(_ request: ScenePresentationPlanningRequest?) {
        guard let request, playbackSessionEngine.pendingTransition == nil else { return }
        let effects = playbackSessionEngine.reduceScenePresentation(
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
        let historyCountBefore = playbackSessionEngine.scenePresentationState.history.count
        runtimeEvidenceRecorder.recordRendererDecoded()
        guard case let .presentationReady(layerIdentity)? = scenePresentationEffectExecutor.rendererDecoded(identity)
        else {
            runtimeEvidenceRecorder.recordPresentationReadiness(
                isReady: false,
                historyUnchanged: playbackSessionEngine.scenePresentationState.history.count == historyCountBefore
            )
            publishScenePresentationChange()
            return
        }
        runtimeEvidenceRecorder.recordPresentationReadiness(
            isReady: true,
            historyUnchanged: playbackSessionEngine.scenePresentationState.history.count == historyCountBefore
        )
        guard
            let presentationIdentity = playbackSessionEngine.presentationIdentity(
                generation: layerIdentity.generation,
                sceneID: layerIdentity.sceneID
            )
        else {
            publishScenePresentationChange()
            return
        }
        executeScenePresentationEffects(
            playbackSessionEngine.reduceScenePresentation(
                .targetReady(presentationIdentity),
                at: scenePresentationTimestamp()
            )
        )
    }

    func rendererFailed(_ identity: SceneRendererIdentity) {
        guard scenePresentationEffectExecutor.rendererFailed(identity),
            let presentationIdentity = playbackSessionEngine.presentationIdentity(
                generation: identity.generation,
                sceneID: identity.sceneID
            )
        else {
            return
        }
        executeScenePresentationEffects(
            playbackSessionEngine.reduceScenePresentation(
                .targetFailed(presentationIdentity),
                at: scenePresentationTimestamp()
            )
        )
    }

    func incomingBecameVisible(_ layerIdentity: ScenePresentationLayerIdentity) {
        guard
            let identity = playbackSessionEngine.presentationIdentity(
                generation: layerIdentity.generation,
                sceneID: layerIdentity.sceneID
            )
        else {
            return
        }
        let historyCountBefore = playbackSessionEngine.scenePresentationState.history.count
        let transition = playbackSessionEngine.transition(for: identity)
        let previousLedgerIndex = playbackHistoryLedger.cursor ?? -1
        let previousLedgerAssetId = playbackHistoryLedger.cursor.flatMap { cursor in
            playbackHistoryLedger.entries.indices.contains(cursor)
                ? playbackHistoryLedger.entries[cursor].scene.primaryAssetId
                : nil
        }
        executeScenePresentationEffects(
            playbackSessionEngine.reduceScenePresentation(
                .incomingBecameVisible(identity),
                at: scenePresentationTimestamp()
            )
        )
        guard playbackSessionEngine.scenePresentationState.history.count > historyCountBefore else { return }
        runtimeEvidenceRecorder.recordVisibleTickCommittedHistory()
        for slot in playbackSessionEngine.scene(for: identity)?.photoSlots ?? [] {
            recordSmartFillFirstImageDisplayed(assetId: slot.asset.id)
        }
        if let transition {
            applyPlaybackHistoryLedgerCommit(
                pendingPlaybackHistoryLedgerCommits[transition.transaction.id],
                committedScene: playbackSessionEngine.scene(for: identity)
            )
        } else if playbackHistoryLedger.entries.isEmpty,
            let scene = playbackSessionEngine.scene(for: identity)
        {
            playbackHistoryLedger.append(scene)
        }
        let displayReason: String
        switch transition?.transaction.source {
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
            previousIndex: previousLedgerIndex,
            previousAssetId: previousLedgerAssetId,
            requestedIndex: currentIndex,
            displayedIndex: currentIndex
        )
        requestLoadMoreAfterVisibleSceneIfNeeded(generation: identity.generation)
        scenePresentationEffectExecutor.releaseBarrier(for: identity)
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
            playbackSessionEngine.reduceScenePresentation(
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
            guard let target = playbackSessionEngine.presentationTarget(for: layer.identity) else { return 0 }
            let activeTime = Self.renderedMotionActiveTime(of: layer, lifecycle: target.lifecycle)
            return SceneAnimationProfile(lifecycle: target.lifecycle).rawProgress(for: activeTime)
        }
        return runtimeEvidenceRecorder.scenePresentationContractProbeLabel(
            for: snapshot,
            progressValues: progressValues,
            historyCount: playbackSessionEngine.scenePresentationState.history.count
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
