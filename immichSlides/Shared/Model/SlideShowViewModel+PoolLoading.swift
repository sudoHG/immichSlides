import Foundation
import Combine
import CryptoKit
import CoreGraphics
import OSLog

extension SlideShowViewModel {
    var currentPlaybackMode: DefaultPlaybackMode {
        switch source {
        case .random:
            return .random
        case .filtered:
            return .filtered
        }
    }

    // Compare normalized filter snapshots; a different order is not a change. true means the filter pool must be
    // rebuilt.

    func shouldReloadFilteredSource(for latestSelection: FilterSelection) -> Bool {
        guard case .filtered(let currentSelection) = source else {
            return false
        }

        return normalizedSelection(currentSelection) != normalizedSelection(latestSelection)
    }

    // Whether a soloOnly person filter is present; the refill threshold must trigger earlier.

    var isSoloOnlyPlaybackSource: Bool {
        guard case .filtered(let selection) = source else {
            return false
        }

        return selection.personFilters.contains { filter in
            filter.matchMode == .soloOnly
        }
    }

    // The debug probe only checks the photo on screen, and only in soloOnly; random playback does not show Vision n=x.

    #if DEBUG
    var shouldRunDebugVisionFaceAudit: Bool {
        isSoloOnlyPlaybackSource
    }
    #endif

    // Pool refill rules gathered into a static method that unit tests can call.

    static func shouldTriggerLoadMore(
        assetCount: Int,
        newIndex: Int,
        isSoloOnlyPlayback: Bool,
        soloOnlyRemainingTriggerCount: Int = 8
    ) -> Bool {
        guard assetCount > 0 else { return false }
        guard newIndex >= 0, newIndex < assetCount else { return false }

        if isSoloOnlyPlayback {
            let remainingAfterNewIndex = assetCount - newIndex - 1
            return remainingAfterNewIndex <= soloOnlyRemainingTriggerCount
        }

        // Normal mode still refills in the last 20%.
        let defaultTriggerIndex = assetCount - (assetCount / refillRemainingFractionDivisor)
        return newIndex >= defaultTriggerIndex
    }

    func preparePlaybackSourceForPresentation(to newSource: PlaybackSource) {
        resetPlaybackSourceState(to: newSource)
    }

    // Switch source while running and reload the first screen right away.
    func switchPlaybackSource(to newSource: PlaybackSource) async {
        resetPlaybackSourceState(to: newSource)
        await prepareInitialAssets()
    }

    private func resetPlaybackSourceState(to newSource: PlaybackSource) {
        logger.notice(
            "playback source reset from=\(self.logName(for: self.source), privacy: .public) to=\(self.logName(for: newSource), privacy: .public) oldAssetCount=\(self.assets.count, privacy: .public) oldCurrentIndex=\(self.currentIndex, privacy: .public)"
        )
        resetSmartFillStartupRuntimeEvidence()
        source = newSource
        playbackSourceGeneration += 1
        // Reset the index and first preload on a source change, so leftovers from the old mode are not reused.
        applyPlaybackAssets([], invalidationReason: .sourceChanged)
        isLoading = true
        isLoadingMore = false
        clearEmptyPlaybackMessage()
        clearAutoPlayRecoveryMessage()
        #if DEBUG
        clearVisionFaceAuditState()
        #endif
        didFirstPreload = false
        firstPreloadTask?.cancel()
        firstPreloadTask = nil
    }

    // Normalize filter snapshots before comparing, so array order does not trigger a false change.

    private func normalizedSelection(_ selection: FilterSelection) -> FilterSelection {
        let normalizedAlbumIDs = selection.albumIds
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()

        let normalizedPersonFilters = selection.personFilters
            .filter { !$0.personId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                if lhs.personId == rhs.personId {
                    return lhs.matchMode.rawValue < rhs.matchMode.rawValue
                }
                return lhs.personId < rhs.personId
            }

        let normalizedTagIDs = selection.tagIds
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()

        return FilterSelection(
            albumIds: normalizedAlbumIDs,
            personFilters: normalizedPersonFilters,
            tagIds: normalizedTagIDs,
            rating: selection.rating,
            isFavorite: selection.isFavorite
        )
    }

    // If the generation does not match, drop the old task; it must not write into the new playback source.

    private func makePlaybackLoadIdentity(generation: Int, source: PlaybackSource) -> PlaybackLoadIdentity {
        let sessionIdentity = playbackSessionEngine.currentSessionIdentity
        return PlaybackLoadIdentity(
            generation: generation,
            sourceName: logName(for: source),
            playbackSessionId: sessionIdentity.playbackSessionId,
            sceneId: sessionIdentity.sceneId
        )
    }

    func isCurrentPlaybackLoad(_ identity: PlaybackLoadIdentity) -> Bool {
        let sessionIdentity = playbackSessionEngine.currentSessionIdentity
        return identity.generation == playbackSourceGeneration
            && identity.sourceName == logName(for: source)
            && identity.playbackSessionId == sessionIdentity.playbackSessionId
            && identity.sceneId == sessionIdentity.sceneId
            && !Task.isCancelled
    }

    private func makePlaybackPoolLoadIdentity(generation: Int, source: PlaybackSource) -> PlaybackPoolLoadIdentity {
        let sessionIdentity = playbackSessionEngine.currentSessionIdentity
        return PlaybackPoolLoadIdentity(
            generation: generation,
            sourceName: logName(for: source),
            playbackSessionId: sessionIdentity.playbackSessionId
        )
    }

    private func isCurrentPlaybackPoolLoad(_ identity: PlaybackPoolLoadIdentity) -> Bool {
        let sessionIdentity = playbackSessionEngine.currentSessionIdentity
        return identity.generation == playbackSourceGeneration
            && identity.sourceName == logName(for: source)
            && identity.playbackSessionId == sessionIdentity.playbackSessionId
            && !Task.isCancelled
    }

    func isCurrentPlaybackLoad(generation: Int) -> Bool {
        isCurrentPlaybackLoad(makePlaybackLoadIdentity(generation: generation, source: source))
    }

    private func loadMoreErrorKind(_ error: any Error) -> String {
        if error is CancellationError {
            return "cancelled"
        }
        return "failure"
    }

    @discardableResult
    func loadAssets() async -> Bool {
        clearAutoPlayRecoveryMessage()
        clearEmptyPlaybackMessage()
        lastAppliedInitialLoadIdentity = nil
        let loadGeneration = playbackSourceGeneration
        let loadSource = source
        let loadIdentity = makePlaybackLoadIdentity(generation: loadGeneration, source: loadSource)
        recordSmartFillStartupRuntimePhase("assetPoolRequestStarted")

        switch loadSource {
        case .random:

            isLoading = true
            logger.info("load assets begin source=random targetCount=100")
            do {

                let loadedAssets: [Asset]
                #if DEBUG
                if let loadAssetsHookForTesting {
                    loadedAssets = try await loadAssetsHookForTesting(loadSource)
                } else {
                    loadedAssets = try await ImmichAPIService.shared.getRandomAsset(
                        size: Self.standardPlaybackFetchAssetCount)
                }
                #else
                loadedAssets = try await ImmichAPIService.shared.getRandomAsset(
                    size: Self.standardPlaybackFetchAssetCount)

                #endif
                guard isCurrentPlaybackLoad(loadIdentity) else {
                    logger.notice(
                        "load assets ignored stale result source=random generation=\(loadGeneration, privacy: .public) currentGeneration=\(self.playbackSourceGeneration, privacy: .public)"
                    )
                    return false
                }
                recordSmartFillStartupRuntimePhase("assetPoolReady")

                applyPlaybackAssets(loadedAssets, invalidationReason: .poolReloaded)
                lastAppliedInitialLoadIdentity = makePlaybackLoadIdentity(
                    generation: loadGeneration,
                    source: loadSource
                )
                updateEmptyPlaybackMessage(
                    for: loadedAssets,
                    source: loadSource,
                    emptyReason: loadedAssets.isEmpty ? .noMatchingAssets : nil
                )
                isLoading = false
                logger.info(
                    "load assets end source=random resultCount=\(loadedAssets.count, privacy: .public)"
                )
            } catch {
                let message = error.localizedDescription
                guard isCurrentPlaybackLoad(loadIdentity) else {
                    logger.notice(
                        "load assets ignored stale failure source=random generation=\(loadGeneration, privacy: .public) currentGeneration=\(self.playbackSourceGeneration, privacy: .public) error=\(message, privacy: .private)"
                    )
                    return false
                }
                logger.error(
                    "load assets failed source=random error=\(message, privacy: .private)"
                )
                emptyPlaybackMessage = String(
                    localized: "Failed to load photos. Check your network or server settings.")
                isLoading = false
            }
        case .filtered(let selection):
            isLoading = true
            let targetCount = resolveTargetCount(for: selection, phase: .initial)
            logger.info(
                "load assets begin source=filtered targetCount=\(targetCount, privacy: .public) selection=\(self.logSummary(for: selection), privacy: .public)"
            )
            do {
                let loadedAssets: [Asset]
                let emptyReason: PlaybackPoolEmptyReason?
                #if DEBUG
                if let loadAssetsHookForTesting {
                    loadedAssets = try await loadAssetsHookForTesting(loadSource)
                    emptyReason = loadedAssets.isEmpty ? .noMatchingAssets : nil
                } else {
                    let resolution = try await resolver.resolveDetailed(
                        selection: selection,
                        targetCount: targetCount
                    )
                    loadedAssets = resolution.assets
                    emptyReason = resolution.emptyReason
                }
                #else
                let resolution = try await resolver.resolveDetailed(
                    selection: selection,
                    targetCount: targetCount
                )
                loadedAssets = resolution.assets
                emptyReason = resolution.emptyReason

                #endif
                guard isCurrentPlaybackLoad(loadIdentity) else {
                    logger.notice(
                        "load assets ignored stale result source=filtered generation=\(loadGeneration, privacy: .public) currentGeneration=\(self.playbackSourceGeneration, privacy: .public)"
                    )
                    return false
                }
                recordSmartFillStartupRuntimePhase("assetPoolReady")
                applyPlaybackAssets(loadedAssets, invalidationReason: .poolReloaded)
                lastAppliedInitialLoadIdentity = makePlaybackLoadIdentity(
                    generation: loadGeneration,
                    source: loadSource
                )
                updateEmptyPlaybackMessage(
                    for: loadedAssets,
                    source: loadSource,
                    emptyReason: emptyReason
                )
                isLoading = false
                logger.info(
                    "load assets end source=filtered targetCount=\(targetCount, privacy: .public) resultCount=\(loadedAssets.count, privacy: .public)"
                )
            } catch {
                let message = error.localizedDescription
                guard isCurrentPlaybackLoad(loadIdentity) else {
                    logger.notice(
                        "load assets ignored stale failure source=filtered generation=\(loadGeneration, privacy: .public) currentGeneration=\(self.playbackSourceGeneration, privacy: .public) error=\(message, privacy: .private)"
                    )
                    return false
                }
                applyPlaybackAssets([], invalidationReason: .poolReloaded)
                emptyPlaybackMessage = String(
                    localized: "Failed to load photos. Check your network or server settings.")
                logger.error(
                    "load assets failed source=filtered targetCount=\(targetCount, privacy: .public) error=\(message, privacy: .private)"
                )
                isLoading = false
            }

        }
        syncPlaybackReadbackFromEngine()
        return true
    }

    func loadMoreAssets() async {
        // The refill remembers the generation it started with; old results must not be appended after a source change.
        // The refill follows the session, not the current sceneId.

        let loadGeneration = playbackSourceGeneration
        let loadSource = source
        let loadIdentity = makePlaybackPoolLoadIdentity(generation: loadGeneration, source: loadSource)

        switch loadSource {
        case .random:
            await loadMoreRandomAssets(
                loadGeneration: loadGeneration, loadSource: loadSource, loadIdentity: loadIdentity)
        case .filtered(let selection):
            await loadMoreFilteredAssets(
                loadGeneration: loadGeneration, loadSource: loadSource, loadIdentity: loadIdentity, selection: selection
            )
        }

    }

    func loadIndexChangePhoto(assetId: String, size: ThumbnailSize) async {
        #if DEBUG
        if let indexChangePhotoLoadHookForTesting {
            await indexChangePhotoLoadHookForTesting(assetId, size)
            return
        }
        #endif
        await downloadManager.loadPhoto(assetId: assetId, size: size, priority: .high)
    }

    func sceneUsesSmartFillSlotReadiness(_ scene: PlaybackScene) -> Bool {
        guard let readback = scene.smartFillReadback else { return false }
        return readback.sceneType != .fallback
    }

    func sceneNeedsPreviewForPlayback(_ scene: PlaybackScene) -> Bool {
        !sceneUsesSmartFillSlotReadiness(scene)
    }

    func isSceneReadyForPlayback(_ scene: PlaybackScene) -> Bool {
        let needsPreview = sceneNeedsPreviewForPlayback(scene)
        return scene.photoSlots.allSatisfy { slot in
            downloadManager.isReady(assetId: slot.asset.id, size: .fullsize)
                && (!needsPreview || downloadManager.isReady(assetId: slot.asset.id, size: .preview))
        }
    }
    private func loadMoreRandomAssets(
        loadGeneration: Int,
        loadSource: PlaybackSource,
        loadIdentity: PlaybackPoolLoadIdentity
    ) async {

        isLoadingMore = true
        defer { isLoadingMore = false }
        let oldCount = assets.count
        logger.info(
            "load more begin source=random oldCount=\(oldCount, privacy: .public)"
        )
        #if DEBUG
        logQAPlaybackSequenceEventIfNeeded(
            .loadMoreBegin(
                sourceSummary: logName(for: loadSource),
                oldCount: oldCount,
                targetCount: nil,
                excludedCount: oldCount
            ))
        #endif
        do {

            let loadedAssets: [Asset]
            #if DEBUG
            if let loadMoreAssetsHookForTesting {
                loadedAssets = try await loadMoreAssetsHookForTesting(loadSource)
            } else {
                loadedAssets = try await ImmichAPIService.shared.getRandomAsset(
                    size: Self.standardPlaybackFetchAssetCount)
            }
            #else
            loadedAssets = try await ImmichAPIService.shared.getRandomAsset(
                size: Self.standardPlaybackFetchAssetCount)

            #endif
            guard isCurrentPlaybackPoolLoad(loadIdentity) else {
                logger.notice(
                    "load more ignored stale result source=random generation=\(loadGeneration, privacy: .public) currentGeneration=\(self.playbackSourceGeneration, privacy: .public)"
                )
                return
            }

            let unseenAssets = assetsUnseenInCurrentPool(loadedAssets)
            assets.append(contentsOf: unseenAssets)
            if !assets.isEmpty {
                clearEmptyPlaybackMessage()
            }

            if assets.count >= maxAssetCount {

                let removeCount = assets.count - maxAssetCount

                let currentIndexBeforeTrim = currentIndex
                let targetIndexBeforeTrim = targetIndex
                let currentAssetIdBeforeTrim = assetIdLogValue(at: currentIndexBeforeTrim)
                let targetAssetIdBeforeTrim = assetIdLogValue(at: targetIndexBeforeTrim)
                let firstRemovedAssetId = removeCount > 0 ? (assets.first?.id ?? "nil") : "nil"
                let lastRemovedAssetId =
                    removeCount > 0 && removeCount <= assets.count ? assets[removeCount - 1].id : "nil"
                logger.info(
                    "load more trim source=random removeCount=\(removeCount, privacy: .public) beforeTrimCount=\(self.assets.count, privacy: .public) maxAssetCount=\(self.maxAssetCount, privacy: .public) currentIndexBeforeTrim=\(currentIndexBeforeTrim, privacy: .public) currentAssetIdBeforeTrim=\(currentAssetIdBeforeTrim, privacy: .private) targetIndexBeforeTrim=\(targetIndexBeforeTrim, privacy: .public) targetAssetIdBeforeTrim=\(targetAssetIdBeforeTrim, privacy: .private) firstRemovedAssetId=\(firstRemovedAssetId, privacy: .private) lastRemovedAssetId=\(lastRemovedAssetId, privacy: .private)"
                )

                let idsToRemove = assets.prefix(removeCount).map { $0.id }

                downloadManager.clearCacheFromDisk(assetIds: idsToRemove)

                assets.removeFirst(removeCount)
                adjustCandidateCursorAfterRemovingPrefix(removeCount)
                // After trimming the queue head, move the index back so currentIndex is not in the removed range.
                syncPlaybackReadbackFromEngine()
                logger.notice(
                    "load more trim adjusted source=random removeCount=\(removeCount, privacy: .public) currentIndexBeforeTrim=\(currentIndexBeforeTrim, privacy: .public) currentIndexAfterTrim=\(self.currentIndex, privacy: .public) currentAssetIdBeforeTrim=\(currentAssetIdBeforeTrim, privacy: .private) currentAssetIdAfterTrim=\(self.assetIdLogValue(at: self.currentIndex), privacy: .private) targetIndexBeforeTrim=\(targetIndexBeforeTrim, privacy: .public) targetIndexAfterTrim=\(self.targetIndex, privacy: .public) targetAssetIdBeforeTrim=\(targetAssetIdBeforeTrim, privacy: .private) targetAssetIdAfterTrim=\(self.assetIdLogValue(at: self.targetIndex), privacy: .private)"
                )
            }
            isLoadingMore = false
            #if DEBUG
            logQAPlaybackSequenceEventIfNeeded(
                .loadMoreResult(
                    sourceSummary: logName(for: loadSource),
                    oldCount: oldCount,
                    targetCount: nil,
                    returnedCount: loadedAssets.count,
                    unseenCount: unseenAssets.count,
                    dedupedCount: loadedAssets.count - unseenAssets.count,
                    finalCount: assets.count
                ))
            #endif
            logger.info(
                "load more end source=random addedCount=\(unseenAssets.count, privacy: .public) dedupedCount=\(loadedAssets.count - unseenAssets.count, privacy: .public) finalCount=\(self.assets.count, privacy: .public) currentIndex=\(self.currentIndex, privacy: .public) currentAssetId=\(self.assetIdLogValue(at: self.currentIndex), privacy: .private)"
            )

        } catch {
            let message = error.localizedDescription
            guard isCurrentPlaybackPoolLoad(loadIdentity) else {
                logger.notice(
                    "load more ignored stale failure source=random generation=\(loadGeneration, privacy: .public) currentGeneration=\(self.playbackSourceGeneration, privacy: .public) error=\(message, privacy: .private)"
                )
                return
            }
            #if DEBUG
            logQAPlaybackSequenceEventIfNeeded(
                .loadMoreFailure(
                    sourceSummary: logName(for: loadSource),
                    oldCount: oldCount,
                    targetCount: nil,
                    errorKind: loadMoreErrorKind(error)
                ))
            #endif
            logger.error(
                "load more failed source=random oldCount=\(oldCount, privacy: .public) error=\(message, privacy: .private)"
            )
            isLoadingMore = false
        }
    }

    private func loadMoreFilteredAssets(
        loadGeneration: Int,
        loadSource: PlaybackSource,
        loadIdentity: PlaybackPoolLoadIdentity,
        selection: FilterSelection
    ) async {
        isLoadingMore = true
        defer { isLoadingMore = false }
        let oldCount = assets.count
        let targetCount = resolveTargetCount(for: selection, phase: .loadMore)
        let excludedAssetIds = Set(assets.map(\.id))
        logger.info(
            "load more begin source=filtered oldCount=\(oldCount, privacy: .public) targetCount=\(targetCount, privacy: .public) selection=\(self.logSummary(for: selection), privacy: .public)"
        )
        #if DEBUG
        logQAPlaybackSequenceEventIfNeeded(
            .loadMoreBegin(
                sourceSummary: logSummary(for: selection),
                oldCount: oldCount,
                targetCount: targetCount,
                excludedCount: excludedAssetIds.count
            ))
        #endif
        do {
            let loadedAssets: [Asset]
            #if DEBUG
            let strictSoloDebugEvents: [PlaybackSequenceDebugEventInput]
            #endif
            #if DEBUG
            if let loadMoreAssetsHookForTesting {
                loadedAssets = try await loadMoreAssetsHookForTesting(loadSource)
                #if DEBUG
                strictSoloDebugEvents = []
                #endif
            } else {
                #if DEBUG
                let previousDebugEventSink = resolver.playbackSequenceDebugEventSink
                if isQAPlaybackSequenceEvidenceEnabled {
                    resolver.playbackSequenceDebugEventSink = { [weak self] event in
                        self?.logQAPlaybackSequenceEventIfNeeded(event)
                    }
                }
                defer {
                    resolver.playbackSequenceDebugEventSink = previousDebugEventSink
                }
                #endif
                loadedAssets = try await resolver.resolve(
                    selection: selection,
                    targetCount: targetCount,
                    excludingAssetIds: excludedAssetIds
                )
                #if DEBUG
                strictSoloDebugEvents = resolver.strictSoloDebugEventsForTesting
                #endif
            }
            #else
            loadedAssets = try await resolver.resolve(
                selection: selection,
                targetCount: targetCount,
                excludingAssetIds: excludedAssetIds
            )
            #endif
            guard isCurrentPlaybackPoolLoad(loadIdentity) else {
                logger.notice(
                    "load more ignored stale result source=filtered generation=\(loadGeneration, privacy: .public) currentGeneration=\(self.playbackSourceGeneration, privacy: .public)"
                )
                return
            }
            #if DEBUG
            for event in strictSoloDebugEvents {
                logQAPlaybackSequenceEventIfNeeded(event)
            }
            #endif
            let unseenAssets = assetsUnseenInCurrentPool(loadedAssets)
            if unseenAssets.isEmpty {
                logger.notice(
                    "load more saturated source=filtered returnedCount=\(loadedAssets.count, privacy: .public) oldCount=\(oldCount, privacy: .public) targetCount=\(targetCount, privacy: .public) selection=\(self.logSummary(for: selection), privacy: .public)"
                )
                #if DEBUG
                logQAPlaybackSequenceEventIfNeeded(
                    .loadMoreSaturated(
                        sourceSummary: logSummary(for: selection),
                        oldCount: oldCount,
                        targetCount: targetCount,
                        returnedCount: loadedAssets.count,
                        unseenCount: unseenAssets.count
                    ))
                #endif
            }
            assets.append(contentsOf: unseenAssets)
            adjustSmartFillCursorAfterAppendingLoadMore(
                oldCount: oldCount,
                appendedCount: unseenAssets.count
            )
            if !assets.isEmpty {
                clearEmptyPlaybackMessage()
            }
            if assets.count >= maxAssetCount {

                let removeCount = assets.count - maxAssetCount
                // Trim log: an unchanged currentAssetId only means the index moved back; a true repeat is when a
                // display asset shows up again.

                let currentIndexBeforeTrim = currentIndex
                let targetIndexBeforeTrim = targetIndex
                let currentAssetIdBeforeTrim = assetIdLogValue(at: currentIndexBeforeTrim)
                let targetAssetIdBeforeTrim = assetIdLogValue(at: targetIndexBeforeTrim)
                let firstRemovedAssetId = removeCount > 0 ? (assets.first?.id ?? "nil") : "nil"
                let lastRemovedAssetId =
                    removeCount > 0 && removeCount <= assets.count ? assets[removeCount - 1].id : "nil"
                logger.info(
                    "load more trim source=filtered removeCount=\(removeCount, privacy: .public) beforeTrimCount=\(self.assets.count, privacy: .public) maxAssetCount=\(self.maxAssetCount, privacy: .public) currentIndexBeforeTrim=\(currentIndexBeforeTrim, privacy: .public) currentAssetIdBeforeTrim=\(currentAssetIdBeforeTrim, privacy: .private) targetIndexBeforeTrim=\(targetIndexBeforeTrim, privacy: .public) targetAssetIdBeforeTrim=\(targetAssetIdBeforeTrim, privacy: .private) firstRemovedAssetId=\(firstRemovedAssetId, privacy: .private) lastRemovedAssetId=\(lastRemovedAssetId, privacy: .private)"
                )

                let idsToRemove = assets.prefix(removeCount).map { $0.id }

                downloadManager.clearCacheFromDisk(assetIds: idsToRemove)

                assets.removeFirst(removeCount)
                adjustCandidateCursorAfterRemovingPrefix(removeCount)
                // After trimming the queue head, move the index back so currentIndex is not in the removed range.
                syncPlaybackReadbackFromEngine()
                logger.notice(
                    "load more trim adjusted source=filtered removeCount=\(removeCount, privacy: .public) currentIndexBeforeTrim=\(currentIndexBeforeTrim, privacy: .public) currentIndexAfterTrim=\(self.currentIndex, privacy: .public) currentAssetIdBeforeTrim=\(currentAssetIdBeforeTrim, privacy: .private) currentAssetIdAfterTrim=\(self.assetIdLogValue(at: self.currentIndex), privacy: .private) targetIndexBeforeTrim=\(targetIndexBeforeTrim, privacy: .public) targetIndexAfterTrim=\(self.targetIndex, privacy: .public) targetAssetIdBeforeTrim=\(targetAssetIdBeforeTrim, privacy: .private) targetAssetIdAfterTrim=\(self.assetIdLogValue(at: self.targetIndex), privacy: .private)"
                )
            }
            isLoadingMore = false
            #if DEBUG
            logQAPlaybackSequenceEventIfNeeded(
                .loadMoreResult(
                    sourceSummary: logSummary(for: selection),
                    oldCount: oldCount,
                    targetCount: targetCount,
                    returnedCount: loadedAssets.count,
                    unseenCount: unseenAssets.count,
                    dedupedCount: loadedAssets.count - unseenAssets.count,
                    finalCount: assets.count
                ))
            #endif
            logger.info(
                "load more end source=filtered addedCount=\(unseenAssets.count, privacy: .public) dedupedCount=\(loadedAssets.count - unseenAssets.count, privacy: .public) finalCount=\(self.assets.count, privacy: .public) currentIndex=\(self.currentIndex, privacy: .public) currentAssetId=\(self.assetIdLogValue(at: self.currentIndex), privacy: .private)"
            )
        } catch {
            let message = error.localizedDescription
            guard isCurrentPlaybackPoolLoad(loadIdentity) else {
                logger.notice(
                    "load more ignored stale failure source=filtered generation=\(loadGeneration, privacy: .public) currentGeneration=\(self.playbackSourceGeneration, privacy: .public) error=\(message, privacy: .private)"
                )
                return
            }
            #if DEBUG
            logQAPlaybackSequenceEventIfNeeded(
                .loadMoreFailure(
                    sourceSummary: logSummary(for: selection),
                    oldCount: oldCount,
                    targetCount: targetCount,
                    errorKind: loadMoreErrorKind(error)
                ))
            #endif
            logger.error(
                "load more failed source=filtered oldCount=\(oldCount, privacy: .public) targetCount=\(targetCount, privacy: .public) error=\(message, privacy: .private)"
            )
            clearPendingSmartFillCursorResumeAfterLoadMore(reason: loadMoreErrorKind(error))
            isLoadingMore = false
        }
    }

}
