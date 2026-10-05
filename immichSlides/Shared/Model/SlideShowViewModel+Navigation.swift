import Foundation
import Combine
import CryptoKit
import CoreGraphics
import OSLog

extension SlideShowViewModel {
    func requestPreviousScene() {
        guard !playbackSessionEngine.scenes.isEmpty else { return }
        let actionTimestamp = playbackManifestTimestamp()
        candidateProgression.cancelPendingSelection()
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
                runtimeEvidenceRecorder.discardActionTimestamp(for: cancelledTransition.transaction.id)
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
            candidateProgression.reserveSelection(
                in: assets, startingAt: candidateIndex, advancingBy: smartFillPlan.nextCandidateCursorOffset,
                displayedAssetIdsAfterCommit: displayedAssetIdsAfterCommit
            )
        } else {
            let transition = playbackSessionEngine.requestNext(
                candidate: assets[candidateIndex], source: transactionSource)
            pendingPlaybackHistoryLedgerCommits[transition.transaction.id] = .appendTail
            recordActionTimestamp(actionTimestamp, for: transition)
            let displayedAssetIdsAfterCommit = displayedAssetIdsForPlanning.union([assets[candidateIndex].id])
            candidateProgression.reserveSelection(
                in: assets, startingAt: candidateIndex, advancingBy: 1,
                displayedAssetIdsAfterCommit: displayedAssetIdsAfterCommit,
                reservesOnAcceptance: shouldAdvanceCandidateCursorOnCommit
            )
        }
        syncPlaybackReadbackFromEngine()
    }

    private var isAtRetainedHistoryTail: Bool {
        playbackHistoryLedger.isAtTail
    }

    private var shouldIncludePendingCandidateReservation: Bool {
        smartFillSurface != nil && isSmartFillPlanningEnabled
    }

    var smartFillDisplayedAssetIdsForPlanning: Set<String> {
        candidateProgression.exclusionsForPlanning(
            includesPendingReservation: shouldIncludePendingCandidateReservation)
    }

    func resetCandidateCursor(nextCandidateCursorOffset: Int = 1) {
        candidateProgression.resetCursor(in: assets, nextCandidateCursorOffset: nextCandidateCursorOffset)
    }

    func normalizedCandidateCursorIndex() -> Int {
        candidateProgression.normalizedCursorIndex(in: assets)
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

        // An exhausted solo-only pool holds this beat until the refill appends new candidates.
        guard
            let hold = candidateProgression.holdForLoadMoreIfConsumed(
                assets: assets, includesPendingReservation: shouldIncludePendingCandidateReservation,
                isLoadingMore: isLoadingMore
            )
        else { return false }
        logger.notice(
            "smartfill advance held for soloOnly loadMore reason=\(reason, privacy: .public) assetCount=\(self.assets.count, privacy: .public) candidateCursorIndex=\(self.candidateProgression.currentCursorIndex, privacy: .public) startIndex=\(startIndex, privacy: .public) displayedAssetCount=\(hold.displayedAssetCount, privacy: .public) isLoadingMore=\(self.isLoadingMore ? "true" : "false", privacy: .public)"
        )
        if hold.shouldStartLoadMore {
            Task { @MainActor [weak self] in
                guard let self, self.isSoloOnlyPlaybackSource, !self.isLoadingMore else { return }
                await self.loadMoreAssets()
            }
        }
        return true
    }

    var isSmartFillPlanningEnabled: Bool {
        playbackDisplayMode == .smartFill && !PlatformCompat.shouldForceSinglePhotoPlaybackForTesting
    }
}
