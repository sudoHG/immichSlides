import Foundation
import Combine
import CryptoKit
import CoreGraphics
import OSLog

extension SlideShowViewModel {
    func consumePreparedSmartFillNext(
        source: PlaybackSceneTransactionSource
    ) -> PlaybackSessionTransition? {
        let expectedSourceCursor = currentPreparedSmartFillSourceCursor()
        guard
            let transition = playbackSession.consumePreparedNext(
                fingerprint: makePreparedSmartFillSceneFingerprint(),
                expectedSourceCursor: expectedSourceCursor,
                source: source
            ), let cursorEffect = transition.preparedCursorEffect
        else { return nil }

        let displayedAssetIdsAfterCommit = smartFillDisplayedAssetIdsForPlanning.union(cursorEffect.displayedAssetIds)
        candidateProgression.reserveSelection(
            in: assets, startingAt: cursorEffect.sourceCursor, advancingBy: cursorEffect.nextCandidateCursorOffset,
            displayedAssetIdsAfterCommit: displayedAssetIdsAfterCommit
        )
        return transition
    }

    func currentPreparedSmartFillSourceCursor() -> Int? {
        candidateProgression.preparedSourceCursor(in: assets)
    }

    private var preparedPlanningInput: PlaybackCandidateProgression.PreparationInput {
        PlaybackCandidateProgression.PreparationInput(
            assets: assets,
            sourceGeneration: playbackSourceGeneration,
            sourceName: logName(for: source),
            isEnabled: isSmartFillPlanningEnabled,
            candidateWindowCount: smartFillCandidateWindowCount
        )
    }

    func cancelSmartFillPreparedRingRefreshTask() {
        candidateProgression.cancelPreparedRefresh()
    }

    func refreshPreparedSmartFillSceneRingIfPossible() {
        cancelSmartFillPreparedRingRefreshTask()
        guard isSmartFillPlanningEnabled, !assets.isEmpty else { return }
        let sourceCursor = normalizedCandidateCursorIndex()
        guard !shouldHoldSmartFillAdvanceForSoloOnlyLoadMore(startingAt: sourceCursor, reason: "prepareRing"),
            let request = capturePreparedSmartFillPlanRequest(startingAt: sourceCursor)
        else { return }
        candidateProgression.refreshPreparedPlan(request: request) { completion in
            _ = self.applyPreparedSmartFillPlanResultIfFresh(completion.result, request: completion.request)
        }
    }

    func applyPreparedSmartFillPlanResultIfFresh(
        _ result: SmartFillPreparedPlanResult,
        request: SmartFillPreparedPlanRequest
    ) -> SmartFillPreparedPlanApplicationOutcome {
        let completion = PlaybackCandidateProgression.PreparedCompletion(request: request, result: result)
        switch candidateProgression.prepareDelivery(completion, in: preparedPlanningInput) {
        case .stale:
            return .stale
        case .invalid:
            return .invalid
        case .proposal(let proposal):
            playbackSession.installPreparedNext(
                fingerprint: proposal.fingerprint,
                sourceCursor: proposal.cursorEffect.sourceCursor,
                scene: proposal.scene,
                cursorEffect: proposal.cursorEffect
            )
            preloadSmartFillMotionPreparedSlotsIfNeeded(scene: proposal.scene)
            candidateProgression.prepareLookahead(after: completion, in: preparedPlanningInput) {
                [weak self] lookahead in
                guard let self,
                    let scene = self.candidateProgression.storeLookaheadIfFresh(
                        lookahead, in: self.preparedPlanningInput)
                else { return }
                if self.applySmartFillMotionLookaheadPreparedPlanIfReady() { return }
                self.preloadSmartFillMotionPreparedSlotsIfNeeded(scene: scene)
            }
            preparedScenePlanningDidComplete(pendingAutomaticScenePlanningRequest)
            return .applied
        }
    }

    @discardableResult
    func applySmartFillMotionLookaheadPreparedPlanIfReady() -> Bool {
        guard let proposal = candidateProgression.takeLookaheadIfReady(in: preparedPlanningInput) else { return false }
        return applyPreparedSmartFillPlanResultIfFresh(proposal.result, request: proposal.request) == .applied
    }

    private func preloadSmartFillMotionPreparedSlotsIfNeeded(scene: PlaybackScene) {
        let eligibility = MotionEligibilityPolicy.acceptedSceneRuntime.evaluate(
            MotionEligibilityInput(
                platform: motionPlatformForCurrentSurface(),
                sceneCapability: motionSceneCapability(for: scene),
                displayMode: playbackDisplayMode == .smartFill ? .smartFill : .singlePhoto,
                focalAdapter: .smartFill,
                isReduceMotionEnabled: sceneRenderSnapshot.isReduceMotionEnabled,
                renderRole: .incoming,
                slotReadiness: .ready
            )
        )
        guard eligibility.runtimeIntegration == .acceptedSceneRuntime,
            eligibility.isTransformEnabled || eligibility.isScheduleEnabled
        else {
            return
        }

        var seenAssetIds: Set<String> = []
        let assetIds = scene.photoSlots.compactMap { slot -> String? in
            guard seenAssetIds.insert(slot.asset.id).inserted else { return nil }
            return slot.asset.id
        }
        guard !assetIds.isEmpty else { return }

        #if DEBUG
        if let smartFillMotionPreparedSlotPreloadHookForTesting {
            smartFillMotionPreparedSlotPreloadHookForTesting(assetIds)
            return
        }
        #endif

        scenePresentationEffectExecutor.preloadPreparedSlots(assetIDs: assetIds) { [weak self] assetID in
            await self?.downloadManager.loadPhoto(assetId: assetID, size: .fullsize, priority: .high)
        }
    }

    func capturePreparedSmartFillPlanRequest(startingAt startIndex: Int) -> SmartFillPreparedPlanRequest? {
        candidateProgression.capturePreparedRequest(in: preparedPlanningInput, startingAt: startIndex)
    }

    func makePreparedSmartFillSceneFingerprint() -> PlaybackPreparedSceneFingerprint? {
        candidateProgression.preparedFingerprint(in: preparedPlanningInput)
    }

    func smartFillCandidateAssets(
        startingAt startIndex: Int,
        excludingDisplayedAssets: Bool = true,
        displayedAssetIdsForExclusion: Set<String>? = nil
    ) -> [Asset] {
        candidateProgression.candidateAssets(
            in: assets, startingAt: startIndex, windowCount: smartFillCandidateWindowCount,
            excludingDisplayedAssets: excludingDisplayedAssets,
            displayedAssetIdsForExclusion: displayedAssetIdsForExclusion
        )
    }

}
