import Foundation
import Combine
import CryptoKit
import CoreGraphics
import OSLog

extension SlideShowViewModel {
    func requestPreviousScene() {
        guard !playbackSessionEngine.scenes.isEmpty else { return }
        let actionTimestamp = playbackManifestTimestamp()
        pendingCandidateCursorIndexAfterCommit = nil
        pendingSmartFillDisplayedAssetIdsAfterCommit = nil
        if canCancelUnseenPendingScenePresentation,
            playbackSessionEngine.canCancelUnseenManualPendingScenePresentation
        {
            // When pre-committed but not yet seen, Previous cancels the pending target and restores the seen scene;
            // re-requesting the current ledger would flash Loading.

            let cancelledTransition = playbackSessionEngine.scenePresentationState.pendingTarget
                .flatMap { playbackSessionEngine.transition(for: $0.identity) }
            let effects = playbackSessionEngine.cancelUnseenManualPendingScenePresentation(
                at: scenePresentationTimestamp()
            )
            if let cancelledTransition {
                pendingPlaybackHistoryLedgerCommits[cancelledTransition.transaction.id] = nil
                pendingSceneActionTimestamps[cancelledTransition.transaction.id] = nil
            }
            executeScenePresentationEffects(effects)
            syncPlaybackReadbackFromEngine()
            return
        }
        guard let previousTarget = playbackHistoryLedger.previousTarget else {
            syncPlaybackReadbackFromEngine()
            return
        }
        let transition = playbackSessionEngine.requestTransition(
            to: previousTarget.entry.scene,
            source: .manualPrevious
        )
        pendingPlaybackHistoryLedgerCommits[transition.transaction.id] = .moveCursor(previousTarget.index)
        recordActionTimestamp(actionTimestamp, for: transition)
        syncPlaybackReadbackFromEngine()
    }

    var canCancelUnseenPendingScenePresentation: Bool {
        guard let visibleCurrentTarget = playbackHistoryLedger.currentTarget,
            playbackSessionEngine.canCancelUnseenManualPendingScenePresentation,
            let pendingTarget = playbackSessionEngine.scenePresentationState.pendingTarget,
            !playbackSessionEngine.scenePresentationState.history.contains(pendingTarget.identity)
        else {
            return false
        }
        return playbackSessionEngine.currentScene?.id != visibleCurrentTarget.entry.scene.id
    }

    /// The platform page is the only scenePhase entry point; the reducer keeps background time out of the playback
    /// clock.
    func suspendScenePresentationForBackground() {
        executeScenePresentationEffects(
            playbackSessionEngine.reduceScenePresentation(
                .suspend(.background),
                at: scenePresentationTimestamp()
            )
        )
    }

    /// Returning to the foreground only removes the background reason; if the user is still paused, stay frozen and do
    /// not catch up on the deadline.
    func resumeScenePresentationFromBackground() {
        guard playbackSessionEngine.scenePresentationState.suspensionReasons.contains(.background) else {
            return
        }
        executeScenePresentationEffects(
            playbackSessionEngine.reduceScenePresentation(
                .resume(.background),
                at: scenePresentationTimestamp()
            )
        )
    }

    func requestNextScene() {
        requestNextScene(isManual: true)
    }

    func requestNextScene(isManual: Bool) {
        guard !assets.isEmpty else { return }
        let actionTimestamp = playbackManifestTimestamp()
        let transactionSource: PlaybackSceneTransactionSource = isManual ? .manualNext : .autoplay
        if let redoTarget = playbackHistoryLedger.redoTarget {
            let transition = playbackSessionEngine.requestTransition(
                to: redoTarget.entry.scene,
                source: transactionSource
            )
            pendingPlaybackHistoryLedgerCommits[transition.transaction.id] = .moveCursor(redoTarget.index)
            recordActionTimestamp(actionTimestamp, for: transition)
            syncPlaybackReadbackFromEngine()
            return
        }
        let candidateIndex = normalizedCandidateCursorIndex()
        let shouldAdvanceCandidateCursorOnCommit = isAtRetainedHistoryTail
        guard
            !shouldHoldSmartFillAdvanceForSoloOnlyLoadMore(
                startingAt: candidateIndex,
                reason: "requestNext"
            )
        else {
            syncPlaybackReadbackFromEngine()
            return
        }
        let displayedAssetIdsForPlanning = smartFillDisplayedAssetIdsForPlanning
        if shouldAdvanceCandidateCursorOnCommit,
            let preparedTransition = consumePreparedSmartFillNext(source: transactionSource)
        {
            pendingPlaybackHistoryLedgerCommits[preparedTransition.transaction.id] = .appendTail
            recordActionTimestamp(actionTimestamp, for: preparedTransition)
        } else if shouldAdvanceCandidateCursorOnCommit,
            !isManual,
            isSmartFillPlanningEnabled
        {
            refreshPreparedSmartFillSceneRingIfPossible()
            return
        } else if shouldAdvanceCandidateCursorOnCommit,
            let smartFillPlan = makeSmartFillScenePlan(
                startingAt: candidateIndex,
                displayedAssetIdsForExclusion: displayedAssetIdsForPlanning,
                callSite: isManual ? .manualNext : .autoplayNext
            )
        {
            let displayedAssetIdsAfterCommit = displayedAssetIdsForPlanning.union(smartFillPlan.displayedAssetIds)
            let transition = playbackSessionEngine.requestNext(scene: smartFillPlan.scene, source: transactionSource)
            pendingPlaybackHistoryLedgerCommits[transition.transaction.id] = .appendTail
            recordActionTimestamp(actionTimestamp, for: transition)
            pendingCandidateCursorIndexAfterCommit = cursorIndex(
                afterAdvancingFrom: candidateIndex,
                by: smartFillPlan.nextCandidateCursorOffset,
                excludingDisplayedAssetIds: displayedAssetIdsAfterCommit
            )
            pendingSmartFillDisplayedAssetIdsAfterCommit = displayedAssetIdsAfterCommit
        } else {
            let transition = playbackSessionEngine.requestNext(
                candidate: assets[candidateIndex], source: transactionSource)
            pendingPlaybackHistoryLedgerCommits[transition.transaction.id] = .appendTail
            recordActionTimestamp(actionTimestamp, for: transition)
            let displayedAssetIdsAfterCommit = displayedAssetIdsForPlanning.union([assets[candidateIndex].id])
            pendingCandidateCursorIndexAfterCommit =
                shouldAdvanceCandidateCursorOnCommit
                ? cursorIndex(after: candidateIndex, excludingDisplayedAssetIds: displayedAssetIdsAfterCommit)
                : nil
            pendingSmartFillDisplayedAssetIdsAfterCommit =
                shouldAdvanceCandidateCursorOnCommit
                ? displayedAssetIdsAfterCommit
                : nil
        }
        syncPlaybackReadbackFromEngine()
    }

    private var isAtRetainedHistoryTail: Bool {
        playbackHistoryLedger.isAtTail
    }

    var smartFillDisplayedAssetIdsForPlanning: Set<String> {
        guard smartFillSurface != nil, isSmartFillPlanningEnabled else {
            return smartFillDisplayedAssetIds
        }
        return pendingSmartFillDisplayedAssetIdsAfterCommit ?? smartFillDisplayedAssetIds
    }

    func resetCandidateCursor(nextCandidateCursorOffset: Int = 1) {
        candidateCursorIndex =
            assets.isEmpty
            ? 0
            : cursorIndex(
                afterAdvancingFrom: 0,
                by: max(0, nextCandidateCursorOffset),
                excludingDisplayedAssetIds: smartFillDisplayedAssetIds
            )
        pendingCandidateCursorIndexAfterCommit = nil
        pendingSmartFillDisplayedAssetIdsAfterCommit = nil
        pendingSmartFillCursorResumeAfterLoadMoreAssetCount = nil
    }

    func normalizedCandidateCursorIndex() -> Int {
        guard !assets.isEmpty else {
            preconditionFailure("normalizedCandidateCursorIndex requires non-empty assets")
        }
        if candidateCursorIndex >= 0 && candidateCursorIndex < assets.count {
            let normalizedIndex = nextCandidateCursorIndex(
                startingAt: candidateCursorIndex,
                excludingDisplayedAssetIds: smartFillDisplayedAssetIds
            )
            candidateCursorIndex = normalizedIndex
            return normalizedIndex
        }
        candidateCursorIndex = 0
        let normalizedIndex = nextCandidateCursorIndex(
            startingAt: 0,
            excludingDisplayedAssetIds: smartFillDisplayedAssetIds
        )
        candidateCursorIndex = normalizedIndex
        return normalizedIndex
    }

    func cursorIndex(
        after assetIndex: Int,
        excludingDisplayedAssetIds displayedAssetIds: Set<String>
    ) -> Int {
        cursorIndex(
            afterAdvancingFrom: assetIndex,
            by: 1,
            excludingDisplayedAssetIds: displayedAssetIds
        )
    }

    func cursorIndex(afterAdvancingFrom assetIndex: Int, by consumedCount: Int) -> Int {
        guard !assets.isEmpty else { return 0 }
        let safeStartIndex = min(max(0, assetIndex), assets.count - 1)
        return (safeStartIndex + max(0, consumedCount)) % assets.count
    }

    func cursorIndex(
        afterAdvancingFrom assetIndex: Int,
        by consumedCount: Int,
        excludingDisplayedAssetIds displayedAssetIds: Set<String>
    ) -> Int {
        guard !assets.isEmpty else { return 0 }
        let unfilteredIndex = cursorIndex(afterAdvancingFrom: assetIndex, by: consumedCount)
        return nextCandidateCursorIndex(
            startingAt: unfilteredIndex,
            excludingDisplayedAssetIds: displayedAssetIds
        )
    }

    func shouldHoldSmartFillAdvanceForSoloOnlyLoadMore(
        startingAt startIndex: Int,
        reason: String
    ) -> Bool {
        guard isSmartFillPlanningEnabled,
            isSoloOnlyPlaybackSource,
            isAtRetainedHistoryTail,
            !assets.isEmpty,
            startIndex >= 0,
            startIndex < assets.count
        else {
            return false
        }

        let currentAssetIds = Set(assets.map(\.id))
        let displayedAssetIds = smartFillDisplayedAssetIdsForPlanning.intersection(currentAssetIds)
        let hasUndisplayedCandidate = currentAssetIds.contains(where: { !displayedAssetIds.contains($0) })
        guard !hasUndisplayedCandidate else {
            return false
        }

        let shouldStartLoadMore = !isLoadingMore && pendingSmartFillCursorResumeAfterLoadMoreAssetCount == nil
        // When SmartFill has used up the soloOnly pool, skip this beat and continue from new assets after the refill
        // appends.

        pendingSmartFillCursorResumeAfterLoadMoreAssetCount = assets.count
        logger.notice(
            "smartfill advance held for soloOnly loadMore reason=\(reason, privacy: .public) assetCount=\(self.assets.count, privacy: .public) candidateCursorIndex=\(self.candidateCursorIndex, privacy: .public) startIndex=\(startIndex, privacy: .public) displayedAssetCount=\(displayedAssetIds.count, privacy: .public) isLoadingMore=\(self.isLoadingMore ? "true" : "false", privacy: .public)"
        )
        if shouldStartLoadMore {
            Task { @MainActor [weak self] in
                guard let self, self.isSoloOnlyPlaybackSource, !self.isLoadingMore else { return }
                await self.loadMoreAssets()
            }
        }
        return true
    }

    func nextCandidateCursorIndex(
        startingAt startIndex: Int,
        excludingDisplayedAssetIds displayedAssetIds: Set<String>
    ) -> Int {
        guard !assets.isEmpty else { return 0 }
        let safeStartIndex = min(max(0, startIndex), assets.count - 1)
        guard !displayedAssetIds.isEmpty else { return safeStartIndex }

        for offset in 0..<assets.count {
            let candidateIndex = (safeStartIndex + offset) % assets.count
            if !displayedAssetIds.contains(assets[candidateIndex].id) {
                return candidateIndex
            }
        }
        return safeStartIndex
    }

    var isSmartFillPlanningEnabled: Bool {
        playbackDisplayMode == .smartFill && !PlatformCompat.shouldForceSinglePhotoPlaybackForTesting
    }
}
