import Foundation
import Combine
import CryptoKit
import CoreGraphics
import OSLog

extension SlideShowViewModel {
    func applyPlaybackAssets(
        _ newAssets: [Asset],
        invalidationReason: PlaybackSessionInvalidationReason
    ) {
        smartFillSurfaceActivationTask?.cancel()
        smartFillSurfaceActivationTask = nil
        cancelSmartFillPreparedRingRefreshTask()
        resetScenePresentationRuntime()
        assets = newAssets
        smartFillDisplayedAssetIds = []
        pendingSmartFillDisplayedAssetIdsAfterCommit = nil
        pendingSceneActionTimestamps = [:]
        let initialSmartFillPlan = makeSmartFillScenePlan(
            startingAt: 0,
            callSite: .initialPlanning
        )
        smartFillDisplayedAssetIds = initialSmartFillPlan?.displayedAssetIds ?? []
        resetCandidateCursor(nextCandidateCursorOffset: initialSmartFillPlan?.nextCandidateCursorOffset ?? 1)
        playbackSessionEngine.reset(
            with: newAssets,
            initialScene: initialSmartFillPlan?.scene,
            reason: invalidationReason
        )
        playbackHistoryLedger.reset(with: nil)
        pendingPlaybackHistoryLedgerCommits = [:]
        if initialSmartFillPlan != nil {
            recordSmartFillStartupRuntimePhase("firstScenePublished")
        }
        syncPlaybackReadbackFromEngine()
        refreshPreparedSmartFillSceneRingIfPossible()
    }

    func assetsUnseenInCurrentPool(_ incomingAssets: [Asset]) -> [Asset] {
        var seenAssetIds = Set(assets.map(\.id))
        return incomingAssets.filter { asset in
            seenAssetIds.insert(asset.id).inserted
        }
    }

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
            beginScenePresentationBarrier(identity: started.identity, scene: scene)
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
        let candidateCursorIndexAfterCommit = pendingCandidateCursorIndexAfterCommit
        let displayedAssetIdsAfterCommit = pendingSmartFillDisplayedAssetIdsAfterCommit
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
            pendingSceneActionTimestamps[transition.transaction.id] = nil
            return
        }
        recordScenePublishTiming(for: transition)
        if let displayedAssetIdsAfterCommit {
            smartFillDisplayedAssetIds = displayedAssetIdsAfterCommit
        }
        if appendsNewTailScene, let candidateCursorIndexAfterCommit {
            applyCandidateCursorIndexAfterCommit(candidateCursorIndexAfterCommit)
        }
        pendingCandidateCursorIndexAfterCommit = nil
        pendingSmartFillDisplayedAssetIdsAfterCommit = nil
        if !applySmartFillMotionLookaheadPreparedPlanIfReady() {
            refreshPreparedSmartFillSceneRingIfPossible()
        }
        beginScenePresentationBarrier(identity: started.identity, scene: transition.scene)
        executeScenePresentationEffects(started.effects)
    }

    private func resetScenePresentationRuntime() {
        scenePresentationWakeUpTask?.cancel()
        scenePresentationWakeUpTask = nil
        scenePresentationWakeUpKey = nil
        scenePresentationEffectTasks.values.forEach { $0.cancel() }
        scenePresentationEffectTasks = [:]
        pendingAutomaticScenePlanGeneration = nil
        scenePresentationPrerenderBarrier = ScenePresentationPrerenderBarrier()
        smartFillMotionPreparedSlotPreloadTasks.values.forEach { $0.cancel() }
        smartFillMotionPreparedSlotPreloadTasks = [:]
        smartFillMotionLookaheadPreparedPlan = nil
        scenePresentationDecodedCount = 0
        scenePresentationReadyCount = 0
        scenePresentationHiddenDecodeExcludedFromHistory = false
        scenePresentationVisibleTickCommittedHistory = false
        publishScenePresentationChange()
    }

    func scenePresentationTimestamp() -> TimeInterval {
        scenePresentationTimestampProviderForTesting?() ?? ProcessInfo.processInfo.systemUptime
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

    func executeScenePresentationEffects(_ effects: [ScenePresentationEffect]) {
        for effect in effects {
            switch effect {
            case let .plan(request):
                let presentationState = playbackSessionEngine.scenePresentationState
                let isStableDeadlinePlan =
                    presentationState.underlyingPhase == .stablePhoto
                    && presentationState.currentTarget?.identity == request.identity
                let isExhaustedAutomaticTargetPlan =
                    presentationState.pendingTarget?.identity == request.identity
                    && presentationState.targetReadiness[request.identity] == .failed
                let isRestoredGracePendingPlan =
                    presentationState.underlyingPhase == .grace
                    && presentationState.pendingTarget?.identity == request.identity
                    && presentationState.targetReadiness[request.identity] == .pending
                if isRestoredGracePendingPlan {
                    // A manual hold has just begun this target's barrier; only a target a cancel brought back needs a new one.
                    let barrierIsActive =
                        scenePresentationPrerenderBarrier.activeScene
                        == ScenePresentationLayerIdentity(
                            generation: request.identity.generation,
                            sceneID: request.identity.sceneID,
                            layerID: "scene-root"
                        )
                    if !barrierIsActive, let scene = playbackSessionEngine.scene(for: request.identity) {
                        restartScenePresentationBarrier(identity: request.identity, scene: scene)
                    }
                    continue
                }
                guard isAutoPlay,
                    request.source == .automatic,
                    isStableDeadlinePlan || isExhaustedAutomaticTargetPlan
                else {
                    continue
                }
                pendingAutomaticScenePlanGeneration = request.identity.generation
                planAutomaticSceneEffect()
                let updatedState = playbackSessionEngine.scenePresentationState
                if updatedState.currentTarget?.identity != request.identity
                    && updatedState.pendingTarget?.identity != request.identity
                {
                    pendingAutomaticScenePlanGeneration = nil
                }

            case let .download(request):
                guard let scene = playbackSessionEngine.scene(for: request.identity) else { continue }
                scenePresentationEffectTasks[request.identity.generation]?.cancel()
                let task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.playbackSessionEngine.transition(for: request.identity) == nil {
                        await self.loadInitialSceneAssetsForPlayback(scene)
                    } else {
                        await self.loadSceneAssetsForTransition(
                            scene,
                            isPreviousTransition: request.source == .manualPrevious,
                            navigationToken: request.identity.generation
                        )
                        guard !Task.isCancelled else { return }
                        _ = await self.preloadSmartFillCandidateWindowIfNeeded(
                            startingAt: self.candidateCursorIndex
                        )
                        guard !Task.isCancelled else { return }
                        await self.preloadPlaybackWindowAfterTransitionIfReady()
                    }
                    guard !Task.isCancelled else { return }
                    self.scenePresentationEffectTasks[request.identity.generation] = nil
                }
                scenePresentationEffectTasks[request.identity.generation] = task

            case let .retry(request, _):
                guard let scene = playbackSessionEngine.scene(for: request.identity) else { continue }
                restartScenePresentationBarrier(identity: request.identity, scene: scene)
                scenePresentationEffectTasks[request.identity.generation]?.cancel()
                let task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.loadSceneAssetsForTransition(
                        scene,
                        isPreviousTransition: request.source == .manualPrevious,
                        navigationToken: request.identity.generation
                    )
                    guard !Task.isCancelled else { return }
                    self.scenePresentationEffectTasks[request.identity.generation] = nil
                }
                scenePresentationEffectTasks[request.identity.generation] = task

            case let .loadMore(generation):
                scenePresentationEffectTasks[generation]?.cancel()
                let task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.loadMoreAssets()
                    guard !Task.isCancelled else { return }
                    self.scenePresentationEffectTasks[generation] = nil
                }
                scenePresentationEffectTasks[generation] = task

            case let .scheduleWakeUp(generation, deadline):
                scheduleScenePresentationWakeUp(generation: generation, deadline: deadline)

            case let .cancelWakeUp(generation):
                guard scenePresentationWakeUpKey?.generation == generation else { continue }
                scenePresentationWakeUpTask?.cancel()
                scenePresentationWakeUpTask = nil
                scenePresentationWakeUpKey = nil

            case let .cancel(request):
                scenePresentationEffectTasks[request.identity.generation]?.cancel()
                scenePresentationEffectTasks[request.identity.generation] = nil
                if pendingAutomaticScenePlanGeneration == request.identity.generation {
                    pendingAutomaticScenePlanGeneration = nil
                }
                releaseScenePresentationBarrier(for: request.identity)

            case let .requestManualDirection(source):
                switch source {
                case .manualPrevious:
                    requestPreviousScene()
                case .manualNext, .automatic:
                    requestNextScene()
                }
            }
        }
        publishScenePresentationChange()
    }

    private func scheduleScenePresentationWakeUp(
        generation: UUID,
        deadline: TimeInterval
    ) {
        let key = ScenePresentationWakeUpKey(generation: generation, deadline: deadline)
        guard scenePresentationWakeUpKey != key else { return }
        scenePresentationWakeUpTask?.cancel()
        scenePresentationWakeUpKey = key
        guard scenePresentationTimestampProviderForTesting == nil else {
            scenePresentationWakeUpTask = nil
            return
        }
        let delay = max(0, deadline - scenePresentationTimestamp())
        scenePresentationWakeUpTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64((delay * 1_000_000_000).rounded(.up))
            )
            guard let self,
                !Task.isCancelled,
                self.scenePresentationWakeUpKey == key
            else {
                return
            }
            self.scenePresentationWakeUpTask = nil
            self.scenePresentationWakeUpKey = nil
            let effects = self.playbackSessionEngine.reduceScenePresentation(
                .wakeUp(generation: generation, deadline: deadline),
                at: self.scenePresentationTimestamp()
            )
            self.executeScenePresentationEffects(effects)
        }
    }

    #if DEBUG
    /// Tests only fire the wake-up the owner already scheduled; no separate autoplay clock is created.
    @discardableResult
    func fireScheduledScenePresentationWakeUpForTesting() -> TimeInterval? {
        guard let key = scenePresentationWakeUpKey else { return nil }
        scenePresentationWakeUpTask?.cancel()
        scenePresentationWakeUpTask = nil
        scenePresentationWakeUpKey = nil
        let effects = playbackSessionEngine.reduceScenePresentation(
            .wakeUp(generation: key.generation, deadline: key.deadline),
            at: key.deadline
        )
        executeScenePresentationEffects(effects)
        return key.deadline
    }
    #endif

    private func beginScenePresentationBarrier(
        identity: PlaybackSessionEngine.ScenePresentationIdentity,
        scene: PlaybackScene
    ) {
        let layerIdentity = ScenePresentationLayerIdentity(
            generation: identity.generation,
            sceneID: identity.sceneID,
            layerID: "scene-root"
        )
        if let activeScene = scenePresentationPrerenderBarrier.activeScene {
            guard activeScene != layerIdentity else { return }
            _ = scenePresentationPrerenderBarrier.release(scene: activeScene)
        }
        let rendererAttemptID = UUID()
        #if DEBUG
        scenePresentationBarrierAttemptCountForTesting += 1
        #endif
        let expectedRenderers = Set(
            scene.photoSlots.map { slot in
                SceneRendererIdentity(
                    generation: identity.generation,
                    attemptID: rendererAttemptID,
                    sceneID: identity.sceneID,
                    slotID: slot.id,
                    assetID: slot.asset.id
                )
            })
        _ = scenePresentationPrerenderBarrier.begin(
            scene: layerIdentity,
            expectedRenderers: expectedRenderers
        )
    }

    private func releaseScenePresentationBarrier(
        for identity: PlaybackSessionEngine.ScenePresentationIdentity
    ) {
        _ = scenePresentationPrerenderBarrier.release(
            scene: ScenePresentationLayerIdentity(
                generation: identity.generation,
                sceneID: identity.sceneID,
                layerID: "scene-root"
            )
        )
    }

    private func restartScenePresentationBarrier(
        identity: PlaybackSessionEngine.ScenePresentationIdentity,
        scene: PlaybackScene
    ) {
        releaseScenePresentationBarrier(for: identity)
        beginScenePresentationBarrier(identity: identity, scene: scene)
    }

    func rendererDecoded(_ identity: SceneRendererIdentity) {
        let historyCountBefore = playbackSessionEngine.scenePresentationState.history.count
        scenePresentationDecodedCount += 1
        guard case let .presentationReady(layerIdentity)? = scenePresentationPrerenderBarrier.rendererDecoded(identity)
        else {
            scenePresentationHiddenDecodeExcludedFromHistory =
                playbackSessionEngine.scenePresentationState.history.count == historyCountBefore
            publishScenePresentationChange()
            return
        }
        scenePresentationReadyCount += 1
        scenePresentationHiddenDecodeExcludedFromHistory =
            playbackSessionEngine.scenePresentationState.history.count == historyCountBefore
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
        guard scenePresentationPrerenderBarrier.rendererFailed(identity),
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
        scenePresentationVisibleTickCommittedHistory = true
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
        releaseScenePresentationBarrier(for: identity)
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
                candidateCursorIndex: candidateCursorIndex,
                candidateProgressIndexForLoadMore: loadMoreProgressIndex,
                soloOnly: isSoloOnlyPlaybackSource,
                isLoadingMore: isLoadingMore,
                shouldTrigger: shouldTriggerLoadMore,
                currentIndex: currentIndex,
                targetIndex: targetIndex,
                displayedAssetCount: qaPlaybackSequenceRecorder?.displayedAssetRecordCount ?? 0
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
        #if DEBUG
        let photoCoverage = 1 - snapshot.layers.reduce(1) { uncovered, layer in uncovered * (1 - layer.opacity) }
        if !playbackSessionEngine.scenePresentationState.history.isEmpty,
            photoCoverage < Self.scenePresentationProbeMinimumPhotoCoverage
        {
            scenePresentationLowCoverageFrameCount += 1
        }
        recordScenePresentationCrossfadeFrame(snapshot, progress: progressValues)
        let lowCoverageFrameCount = scenePresentationLowCoverageFrameCount
        let crossfadeFrameCount = scenePresentationCrossfadeFrameCount
        let lastCrossfade =
            scenePresentationLastCrossfade.map { crossfade in
                let progress = [
                    crossfade.firstOutgoingProgress, crossfade.lastOutgoingProgress,
                    crossfade.lowestOutgoingProgress, crossfade.highestOutgoingProgress
                ].map { String(format: "%.6f", $0) }
                let blend = String(format: "%.6f", crossfade.peakBlendOpacity)
                let motion = crossfade.didOutgoingProgressRewind ? "rewound" : "steady"
                return "\(crossfade.outgoingID)>\(crossfade.incomingID)@\(progress[0])>\(progress[1])"
                    + "@\(progress[2])>\(progress[3])@\(blend)@\(motion)"
            } ?? "none"
        #else
        let lowCoverageFrameCount = 0
        let crossfadeFrameCount = 0
        let lastCrossfade = "none"
        #endif
        let roles = snapshot.layers.map { $0.role.rawValue }.joined(separator: "|")
        let layerIDs = snapshot.layers.map(\.identity.privateIdentifier).joined(separator: "|")
        let opacities = snapshot.layers.map { String(format: "%.6f", $0.opacity) }.joined(separator: "|")
        let progress = progressValues.map { String(format: "%.6f", $0) }.joined(separator: "|")
        return [
            "schemaVersion=scene-presentation-contract-probe-v1",
            "phase=\(snapshot.underlyingPhase.rawValue)",
            "layerRoles=\(roles.isEmpty ? "none" : roles)",
            "layerIDs=\(layerIDs.isEmpty ? "none" : layerIDs)",
            "layerOpacities=\(opacities.isEmpty ? "none" : opacities)",
            "motionRawProgress=\(progress.isEmpty ? "none" : progress)",
            "decodedCount=\(scenePresentationDecodedCount)",
            "presentationReadyCount=\(scenePresentationReadyCount)",
            "historyCount=\(playbackSessionEngine.scenePresentationState.history.count)",
            "partialSlotVisible=\(snapshot.layers.contains { $0.opacity > 0 && !$0.isPresentationReady })",
            "loadingVisible=\(snapshot.underlyingPhase == .loading)",
            "playbackPaused=\(snapshot.suspensionReasons.contains(.userPaused))",
            "lowCoverageFrameCount=\(lowCoverageFrameCount)",
            "crossfadeFrameCount=\(crossfadeFrameCount)",
            "lastCrossfade=\(lastCrossfade)",
            "hiddenDecodeExcludedFromHistory=\(scenePresentationHiddenDecodeExcludedFromHistory)",
            "visibleTickCommittedHistory=\(scenePresentationVisibleTickCommittedHistory)"
        ].joined(separator: ";")
    }

    #if DEBUG
    /// Remembers a crossfade from one photo to another (one outgoing and one incoming layer): how the outgoing photo's
    /// motion moved while it was drawn, and whether both photos were ever visible together.
    private func recordScenePresentationCrossfadeFrame(
        _ snapshot: PlaybackSessionEngine.SceneRenderSnapshot,
        progress: [Double]
    ) {
        let outgoingIndices = snapshot.layers.indices.filter { snapshot.layers[$0].role == .outgoing }
        let incomingIndices = snapshot.layers.indices.filter { snapshot.layers[$0].role == .incoming }
        guard snapshot.underlyingPhase == .transition,
            outgoingIndices.count == 1, incomingIndices.count == 1,
            let outgoing = outgoingIndices.first, let incoming = incomingIndices.first
        else {
            return
        }
        scenePresentationCrossfadeFrameCount += 1
        let outgoingID = snapshot.layers[outgoing].identity.privateIdentifier
        let incomingID = snapshot.layers[incoming].identity.privateIdentifier
        let outgoingOpacity = snapshot.layers[outgoing].opacity
        let incomingOpacity = snapshot.layers[incoming].opacity
        let blend = min(incomingOpacity, outgoingOpacity * (1 - incomingOpacity))
        let outgoingProgress = progress[outgoing]
        guard var crossfade = scenePresentationLastCrossfade,
            crossfade.outgoingID == outgoingID, crossfade.incomingID == incomingID
        else {
            scenePresentationLastCrossfade = ScenePresentationProbeCrossfade(
                outgoingID: outgoingID,
                incomingID: incomingID,
                firstOutgoingProgress: outgoingProgress,
                lastOutgoingProgress: outgoingProgress,
                lowestOutgoingProgress: outgoingProgress,
                highestOutgoingProgress: outgoingProgress,
                peakBlendOpacity: blend,
                lastOutgoingOpacity: outgoingOpacity,
                didOutgoingProgressRewind: false
            )
            return
        }
        crossfade.lowestOutgoingProgress = min(crossfade.lowestOutgoingProgress, outgoingProgress)
        crossfade.highestOutgoingProgress = max(crossfade.highestOutgoingProgress, outgoingProgress)
        crossfade.peakBlendOpacity = max(crossfade.peakBlendOpacity, blend)
        // The outgoing photo only fades out, so only a dimmer frame is a later one; on iOS the root probe can report an
        // earlier moment than the frame-synchronized probe did, and once faded out the photo's motion is not seen.
        if outgoingOpacity < crossfade.lastOutgoingOpacity {
            if outgoingProgress < crossfade.lastOutgoingProgress - Self.scenePresentationProbeProgressTolerance {
                crossfade.didOutgoingProgressRewind = true
            }
            crossfade.lastOutgoingProgress = outgoingProgress
            crossfade.lastOutgoingOpacity = outgoingOpacity
        }
        scenePresentationLastCrossfade = crossfade
    }
    #endif

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
