import Foundation
import Combine
import CryptoKit
import CoreGraphics
import OSLog

extension SlideShowViewModel {
    func makeSmartFillScenePlan(
        startingAt startIndex: Int,
        excludingDisplayedAssets: Bool = true,
        displayedAssetIdsForExclusion: Set<String>? = nil,
        callSite: SmartFillMainActorPlannerCallSite
    ) -> SmartFillScenePlan? {
        guard isSmartFillPlanningEnabled,
            let smartFillSurface,
            !assets.isEmpty,
            startIndex >= 0,
            startIndex < assets.count
        else {
            return nil
        }

        let candidateAssets = smartFillCandidateAssets(
            startingAt: startIndex,
            excludingDisplayedAssets: excludingDisplayedAssets,
            displayedAssetIdsForExclusion: displayedAssetIdsForExclusion
        )
        guard !candidateAssets.isEmpty else { return nil }

        recordSmartFillMainActorPlannerCall(callSite)
        let candidateSummaries = candidateAssets.map { smartFillCandidateSummary(for: $0) }
        let policy = PlaybackSmartFillLayoutPolicy.policy(for: smartFillSurface)
        recordSmartFillStartupRuntimePhase("firstScenePlanningStarted")
        let plannerResult = PlaybackSmartFillPlanner.plan(
            PlaybackSmartFillPlannerInput(
                surface: smartFillSurface,
                candidates: candidateSummaries,
                protectionSnapshot: smartFillProtectionSnapshot,
                policy: policy,
                playbackSessionSeed: "generation-\(playbackSourceGeneration)",
                sceneOrdinal: startIndex
            )
        )
        guard !plannerResult.slots.isEmpty else { return nil }

        var assetsByReference: [String: Asset] = [:]
        for (summary, asset) in zip(candidateSummaries, candidateAssets)
        where assetsByReference[summary.reference] == nil {
            assetsByReference[summary.reference] = asset
        }
        let photoSlots = plannerResult.slots.compactMap { slot -> PhotoSlot? in
            guard let asset = assetsByReference[slot.candidateReference] else { return nil }
            let candidate = candidateSummaries.first { $0.reference == slot.candidateReference }
            return PhotoSlot(
                id: "slot-\(slot.role.rawValue)-\(slot.candidateReference)",
                asset: asset,
                planning: PlaybackPlanningSnapshot.smartFill(
                    slot: slot,
                    plannerResult: plannerResult,
                    focalSummary: PlaybackCandidateProgression.smartFillFocalSummary(
                        faceRects: candidate?.faceRects ?? [],
                        subjectRects: candidate?.subjectRects ?? []
                    )
                )
            )
        }
        guard !photoSlots.isEmpty else { return nil }

        let readback = PlaybackSmartFillSceneReadback.fromPlannerResult(plannerResult)
        let prototypeScene = PlaybackScene(
            id: "scene-smartfill-\(photoSlots.first?.asset.id ?? "empty")",
            photoSlots: photoSlots,
            smartFillReadback: readback
        )
        recordSmartFillStartupFirstPlanMetrics(
            assetPoolSize: assets.count,
            eligibleCandidateCount: candidateSummaries.count,
            plannerResult: plannerResult
        )
        recordSmartFillStartupRuntimePhase("firstScenePlanned")
        return SmartFillScenePlan(
            scene: prototypeScene,
            nextCandidateCursorOffset: smartFillNextCandidateCursorOffset(
                candidateSummaries: candidateSummaries,
                plannerResult: plannerResult,
                fallbackCount: photoSlots.count
            ),
            displayedAssetIds: Set(prototypeScene.assetIds)
        )
    }

    private func recordSmartFillMainActorPlannerCall(_ callSite: SmartFillMainActorPlannerCallSite) {
        #if DEBUG
        smartFillMainActorPlannerCallCountsForTesting[callSite, default: 0] += 1
        #endif
    }

    func consumePreparedSmartFillNext(
        source: PlaybackSceneTransactionSource
    ) -> PlaybackSessionTransition? {
        let expectedSourceCursor = currentPreparedSmartFillSourceCursor()
        guard let fingerprint = makePreparedSmartFillSceneFingerprint(),
            playbackSessionEngine.invalidatePreparedSceneRing(ifNeededFor: fingerprint) == false,
            let preparedCursorEffect = playbackSessionEngine.preparedSceneRing?.next?.cursorEffect,
            preparedCursorEffect.sourceCursor == expectedSourceCursor,
            let transition = playbackSessionEngine.consumePreparedNext(source: source),
            let cursorEffect = transition.preparedCursorEffect
        else {
            if let preparedCursorEffect = playbackSessionEngine.preparedSceneRing?.next?.cursorEffect,
                preparedCursorEffect.sourceCursor != expectedSourceCursor
            {
                playbackSessionEngine.clearPreparedSceneRing()
            }
            return nil
        }

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
            let previousScene =
                playbackSessionEngine.currentIndex > 0
                ? playbackSessionEngine.scenes[playbackSessionEngine.currentIndex - 1]
                : nil
            playbackSessionEngine.prepareSceneRing(
                fingerprint: proposal.fingerprint,
                sourceCursor: proposal.cursorEffect.sourceCursor,
                previous: previousScene,
                current: playbackSessionEngine.currentScene,
                next: proposal.scene,
                nextCursorEffect: proposal.cursorEffect
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

    private func smartFillNextCandidateCursorOffset(
        candidateSummaries: [PlaybackSmartFillCandidateSummary],
        plannerResult: PlaybackSmartFillPlannerResult,
        fallbackCount: Int
    ) -> Int {
        let selectedOffsets = plannerResult.slots.compactMap { slot in
            candidateSummaries.firstIndex { $0.reference == slot.candidateReference }
        }
        guard !selectedOffsets.isEmpty else {
            return max(1, fallbackCount)
        }

        // Only advance to the next unshown candidate, so photos in between are not skipped when lookahead picks a far
        // slot.
        let selectedOffsetSet = Set(selectedOffsets)
        guard selectedOffsetSet.contains(0) else {
            return 0
        }
        for offset in 1..<candidateSummaries.count where !selectedOffsetSet.contains(offset) {
            return offset
        }
        return min(candidateSummaries.count, max(fallbackCount, selectedOffsetSet.count))
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

    private func smartFillCandidateSummary(for asset: Asset) -> PlaybackSmartFillCandidateSummary {
        #if DEBUG
        smartFillCandidateSummaryBuildCountForTestingStorage += 1
        #endif
        let faceRects = FaceBoxGeometry.validate(
            faces: FaceBoxGeometry.collectFaces(from: asset.people),
            asset: asset
        ).compactMap { result -> PlaybackPlanningRect? in
            guard case let .usable(normalizedRect, _) = result else { return nil }
            return PlaybackPlanningRect(
                x: Double(normalizedRect.origin.x),
                y: Double(normalizedRect.origin.y),
                width: Double(normalizedRect.width),
                height: Double(normalizedRect.height)
            )
        }

        return PlaybackSmartFillCandidateSummary(
            reference: smartFillCandidateReference(for: asset.id),
            sourceImage: PlaybackPlanningSourceImageSummary(
                assetPixelSize: PlaybackSmartFillSourceGeometry.displayPixelSize(for: asset),
                exifPixelSize: smartFillPixelSize(
                    width: asset.exifInfo?.exifImageWidth,
                    height: asset.exifInfo?.exifImageHeight
                ),
                orientation: asset.exifInfo?.orientation == nil ? "unknown" : "available"
            ),
            faceRects: faceRects,
            subjectRects: faceRects
        )
    }

    private func smartFillCandidateReference(for rawId: String) -> String {
        let digest = SHA256.hash(data: Data(rawId.utf8))
        let hashText = digest.prefix(PlaybackCandidateProgression.identifierDigestPrefixBytes)
            .map { String(format: "%02x", $0) }.joined()
        return "asset_\(hashText)"
    }

    private func smartFillPixelSize(width: Int?, height: Int?) -> PlaybackPlanningPixelSize? {
        guard let width, let height else { return nil }
        return PlaybackPlanningPixelSize(width: width, height: height)
    }
}
