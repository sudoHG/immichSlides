import Foundation
import Combine
import CryptoKit
import CoreGraphics
import OSLog

extension SlideShowViewModel {
    func requestPreviousScene() {
        guard !playbackSession.scenes.isEmpty else { return }
        let actionTimestamp = playbackManifestTimestamp()
        candidateProgression.cancelPendingSelection()
        switch playbackSession.requestPrevious(at: scenePresentationTimestamp()) {
        case .unchanged:
            break
        case .transition(let transition):
            recordActionTimestamp(actionTimestamp, for: transition)
        case .cancelled(let effects, let transactionID):
            if let transactionID { runtimeEvidenceRecorder.discardActionTimestamp(for: transactionID) }
            executeScenePresentationEffects(effects)
        }
        syncPlaybackReadbackFromSession()
    }

    /// The platform page is the only scenePhase entry point; the reducer keeps background time out of the playback
    /// clock.
    func suspendScenePresentationForBackground() {
        executeScenePresentationEffects(
            playbackSession.reduceScenePresentation(
                .suspend(.background),
                at: scenePresentationTimestamp()
            )
        )
    }

    /// Returning to the foreground only removes the background reason; if the user is still paused, stay frozen and do
    /// not catch up on the deadline.
    func resumeScenePresentationFromBackground() {
        guard playbackSession.isSuspendedForBackground else {
            return
        }
        executeScenePresentationEffects(
            playbackSession.reduceScenePresentation(
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
        if let transition = playbackSession.requestRedo(source: transactionSource) {
            recordActionTimestamp(actionTimestamp, for: transition)
            syncPlaybackReadbackFromSession()
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
            syncPlaybackReadbackFromSession()
            return
        }
        let displayedAssetIdsForPlanning = smartFillDisplayedAssetIdsForPlanning
        if shouldAdvanceCandidateCursorOnCommit,
            let preparedTransition = consumePreparedSmartFillNext(source: transactionSource)
        {
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
            let transition = playbackSession.requestNext(scene: smartFillPlan.scene, source: transactionSource)
            recordActionTimestamp(actionTimestamp, for: transition)
            candidateProgression.reserveSelection(
                in: assets, startingAt: candidateIndex, advancingBy: smartFillPlan.nextCandidateCursorOffset,
                displayedAssetIdsAfterCommit: displayedAssetIdsAfterCommit
            )
        } else {
            let transition = playbackSession.requestNext(
                candidate: assets[candidateIndex], source: transactionSource)
            recordActionTimestamp(actionTimestamp, for: transition)
            let displayedAssetIdsAfterCommit = displayedAssetIdsForPlanning.union([assets[candidateIndex].id])
            candidateProgression.reserveSelection(
                in: assets, startingAt: candidateIndex, advancingBy: 1,
                displayedAssetIdsAfterCommit: displayedAssetIdsAfterCommit,
                reservesOnAcceptance: shouldAdvanceCandidateCursorOnCommit
            )
        }
        syncPlaybackReadbackFromSession()
    }

    private var isAtRetainedHistoryTail: Bool {
        playbackSession.isAtRetainedHistoryTail
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
