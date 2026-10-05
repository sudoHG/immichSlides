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
                    focalSummary: smartFillFocalSummary(
                        faceRects: candidate?.faceRects ?? [],
                        subjectRects: candidate?.subjectRects ?? []
                    )
                )
            )
        }
        guard !photoSlots.isEmpty else { return nil }

        let initialReadback = PlaybackSmartFillSceneReadback(
            version: "smart-fill-scene-v2",
            sceneType: plannerResult.sceneType,
            layoutPolicyId: plannerResult.layoutPolicyId,
            surfaceKey: plannerResult.surfaceKey,
            layoutVariant: plannerResult.layoutVariant,
            ratioPreset: plannerResult.ratioPreset,
            slotRoles: plannerResult.slots.map(\.role),
            fallbackReason: plannerResult.fallbackReason,
            fallbackCategory: plannerResult.fallbackCategory,
            candidateWindowUsed: plannerResult.candidateWindowUsed,
            evaluationCount: plannerResult.evaluationCount,
            rotationStartLayoutVariant: plannerResult.rotationStartLayoutVariant,
            rotationStartRatioPreset: plannerResult.rotationStartRatioPreset,
            acceptedLayoutVariant: plannerResult.acceptedLayoutVariant,
            acceptedRatioPreset: plannerResult.acceptedRatioPreset,
            rotationKeyHashPrefix: plannerResult.rotationKeyHashPrefix,
            rejectedLayoutReasonTopList: plannerResult.rejectedLayoutReasonTopList,
            reasonCodes: plannerResult.reasonCodes
        )
        #if DEBUG
        let readback = initialReadback.recordingQADebugSummary(plannerResult.qaDebugSummary)
        #else
        let readback = initialReadback
        #endif
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
        pendingCandidateCursorIndexAfterCommit = cursorIndex(
            afterAdvancingFrom: cursorEffect.sourceCursor,
            by: cursorEffect.nextCandidateCursorOffset,
            excludingDisplayedAssetIds: displayedAssetIdsAfterCommit
        )
        pendingSmartFillDisplayedAssetIdsAfterCommit = displayedAssetIdsAfterCommit
        return transition
    }

    func currentPreparedSmartFillSourceCursor() -> Int? {
        guard !assets.isEmpty else { return nil }
        let startIndex =
            candidateCursorIndex >= 0 && candidateCursorIndex < assets.count
            ? candidateCursorIndex
            : 0
        return nextCandidateCursorIndex(
            startingAt: startIndex,
            excludingDisplayedAssetIds: smartFillDisplayedAssetIds
        )
    }

    func cancelSmartFillPreparedRingRefreshTask() {
        smartFillPreparedRingRefreshTask?.cancel()
        smartFillPreparedRingRefreshTask = nil
        smartFillPreparedRingRefreshGeneration = nil
    }

    private func clearSmartFillPreparedRingRefreshTaskIfCurrent(_ generation: UUID) {
        guard smartFillPreparedRingRefreshGeneration == generation else { return }
        smartFillPreparedRingRefreshTask = nil
        smartFillPreparedRingRefreshGeneration = nil
    }

    func refreshPreparedSmartFillSceneRingIfPossible() {
        cancelSmartFillPreparedRingRefreshTask()

        guard isSmartFillPlanningEnabled, !assets.isEmpty else {
            return
        }
        let sourceCursor = normalizedCandidateCursorIndex()
        guard
            !shouldHoldSmartFillAdvanceForSoloOnlyLoadMore(
                startingAt: sourceCursor,
                reason: "prepareRing"
            )
        else {
            return
        }
        guard let request = capturePreparedSmartFillPlanRequest(startingAt: sourceCursor) else {
            return
        }

        let generation = UUID()
        smartFillPreparedRingRefreshGeneration = generation
        let planningTask = Task.detached(priority: .utility) {
            SmartFillPreparedPlanBuilder.makeResult(for: request)
        }
        smartFillPreparedRingRefreshTask = Task { @MainActor in
            let result = await withTaskCancellationHandler {
                await planningTask.value
            } onCancel: {
                planningTask.cancel()
            }
            guard !Task.isCancelled, let result else {
                self.clearSmartFillPreparedRingRefreshTaskIfCurrent(generation)
                return
            }
            if self.smartFillPreparedRingRefreshGeneration == generation {
                _ = self.applyPreparedSmartFillPlanResultIfFresh(result, request: request)
            }
            self.clearSmartFillPreparedRingRefreshTaskIfCurrent(generation)
        }
    }

    func applyPreparedSmartFillPlanResultIfFresh(
        _ result: SmartFillPreparedPlanResult,
        request: SmartFillPreparedPlanRequest
    ) -> SmartFillPreparedPlanApplicationOutcome {
        guard isPreparedSmartFillPlanResultFresh(result, request: request) else {
            return .stale
        }
        guard let plan = smartFillScenePlan(from: result) else {
            return .invalid
        }
        guard let fingerprint = makePreparedSmartFillSceneFingerprint() else {
            return .stale
        }
        let previousScene =
            playbackSessionEngine.currentIndex > 0
            ? playbackSessionEngine.scenes[playbackSessionEngine.currentIndex - 1]
            : nil

        playbackSessionEngine.prepareSceneRing(
            fingerprint: fingerprint,
            sourceCursor: result.sourceCursor,
            previous: previousScene,
            current: playbackSessionEngine.currentScene,
            next: plan.scene,
            nextCursorEffect: PlaybackPreparedSceneCursorEffect(
                sourceCursor: result.sourceCursor,
                nextCandidateCursorOffset: plan.nextCandidateCursorOffset,
                displayedAssetIds: plan.displayedAssetIds
            )
        )
        preloadSmartFillMotionPreparedSlotsIfNeeded(scene: plan.scene)
        preloadSmartFillMotionLookaheadSlotsIfNeeded(result: result, request: request)
        let presentationState = playbackSessionEngine.scenePresentationState
        let pendingPlanGenerationIsActive =
            pendingAutomaticScenePlanGeneration.map { generation in
                presentationState.currentTarget?.identity.generation == generation
                    || presentationState.pendingTarget?.identity.generation == generation
            } ?? false
        let canResumeStableDeadlinePlan = presentationState.underlyingPhase == .stablePhoto
        let canResumeExhaustedTargetPlan =
            presentationState.pendingTarget.map {
                presentationState.targetReadiness[$0.identity] == .failed
            } ?? false
        if isAutoPlay,
            pendingPlanGenerationIsActive,
            canResumeStableDeadlinePlan || canResumeExhaustedTargetPlan,
            playbackSessionEngine.pendingTransition == nil
        {
            planAutomaticSceneEffect()
            let updatedState = playbackSessionEngine.scenePresentationState
            let pendingGenerationStillActive =
                pendingAutomaticScenePlanGeneration.map { generation in
                    updatedState.currentTarget?.identity.generation == generation
                        || updatedState.pendingTarget?.identity.generation == generation
                } ?? false
            if !pendingGenerationStillActive {
                pendingAutomaticScenePlanGeneration = nil
            }
        }
        return .applied
    }

    private func preloadSmartFillMotionLookaheadSlotsIfNeeded(
        result: SmartFillPreparedPlanResult,
        request: SmartFillPreparedPlanRequest
    ) {
        guard result.requestId == request.requestId,
            result.sourceCursor == request.candidateCursor,
            result.assetPoolIdentity == request.assetPoolIdentity,
            result.playbackSourceGeneration == request.playbackSourceGeneration
        else {
            return
        }
        let displayedAssetIdsAfterPreparedScene = request.displayedAssetIds.union(result.displayedAssetIds)
        let nextCursor = cursorIndex(
            afterAdvancingFrom: result.sourceCursor,
            by: result.nextCandidateCursorOffset,
            excludingDisplayedAssetIds: displayedAssetIdsAfterPreparedScene
        )
        guard
            let lookaheadRequest = capturePreparedSmartFillPlanRequest(
                startingAt: nextCursor,
                displayedAssetIdsForExclusion: displayedAssetIdsAfterPreparedScene,
                sceneOrdinal: nextCursor
            )
        else {
            return
        }
        let planningTask = Task.detached(priority: .utility) {
            SmartFillPreparedPlanBuilder.makeResult(for: lookaheadRequest)
        }
        Task { @MainActor [weak self] in
            let lookaheadResult = await withTaskCancellationHandler {
                await planningTask.value
            } onCancel: {
                planningTask.cancel()
            }
            guard let self,
                !Task.isCancelled,
                let lookaheadResult,
                self.isSmartFillMotionLookaheadPlanResultFresh(lookaheadResult, request: lookaheadRequest),
                let lookaheadPlan = self.smartFillScenePlan(from: lookaheadResult)
            else {
                return
            }
            self.smartFillMotionLookaheadPreparedPlan = SmartFillMotionLookaheadPreparedPlan(
                request: lookaheadRequest,
                result: lookaheadResult
            )
            if self.applySmartFillMotionLookaheadPreparedPlanIfReady() {
                return
            }
            self.preloadSmartFillMotionPreparedSlotsIfNeeded(scene: lookaheadPlan.scene)
        }
    }

    @discardableResult
    func applySmartFillMotionLookaheadPreparedPlanIfReady() -> Bool {
        guard let lookaheadPlan = smartFillMotionLookaheadPreparedPlan,
            lookaheadPlan.request.candidateCursor == currentPreparedSmartFillSourceCursor()
        else {
            return false
        }
        smartFillMotionLookaheadPreparedPlan = nil
        return applyPreparedSmartFillPlanResultIfFresh(
            lookaheadPlan.result,
            request: lookaheadPlan.request
        ) == .applied
    }

    private func isSmartFillMotionLookaheadPlanResultFresh(
        _ result: SmartFillPreparedPlanResult,
        request: SmartFillPreparedPlanRequest
    ) -> Bool {
        result.requestId == request.requestId && result.sourceCursor == request.candidateCursor
            && result.assetPoolIdentity == request.assetPoolIdentity
            && result.playbackSourceGeneration == request.playbackSourceGeneration
            && request.playbackSourceGeneration == playbackSourceGeneration
            && request.assetPoolIdentity == smartFillAssetPoolIdentity()
            && request.protectionFingerprint == request.protectionSnapshot.smartFillReplanFingerprint
            && request.protectionFingerprint == smartFillProtectionSnapshot.smartFillReplanFingerprint
            && request.preparedFingerprint == makePreparedSmartFillSceneFingerprint()
            && request.surface == smartFillSurface
            && request.layoutPolicyId == PlaybackSmartFillLayoutPolicy.policy(for: request.surface).layoutPolicyId
            && !assets.isEmpty && isSmartFillPlanningEnabled
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

        let taskId = UUID()
        smartFillMotionPreparedSlotPreloadTasks[taskId] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.smartFillMotionPreparedSlotPreloadTasks[taskId] = nil
            }
            await withTaskGroup(of: Void.self) { group in
                for assetId in assetIds {
                    group.addTask { @MainActor in
                        guard !Task.isCancelled else { return }
                        await self.downloadManager.loadPhoto(assetId: assetId, size: .fullsize, priority: .high)
                    }
                }
            }
        }
    }

    private func isPreparedSmartFillPlanResultFresh(
        _ result: SmartFillPreparedPlanResult,
        request: SmartFillPreparedPlanRequest
    ) -> Bool {
        guard result.requestId == request.requestId,
            result.sourceCursor == request.candidateCursor,
            result.assetPoolIdentity == request.assetPoolIdentity,
            result.playbackSourceGeneration == request.playbackSourceGeneration,
            request.playbackSourceGeneration == playbackSourceGeneration,
            request.assetPoolIdentity == smartFillAssetPoolIdentity(),
            request.protectionFingerprint == request.protectionSnapshot.smartFillReplanFingerprint,
            request.protectionFingerprint == smartFillProtectionSnapshot.smartFillReplanFingerprint,
            request.preparedFingerprint == makePreparedSmartFillSceneFingerprint(),
            request.surface == smartFillSurface,
            request.layoutPolicyId == PlaybackSmartFillLayoutPolicy.policy(for: request.surface).layoutPolicyId,
            !assets.isEmpty,
            request.candidateCursor == normalizedCandidateCursorIndex(),
            isSmartFillPlanningEnabled
        else {
            return false
        }
        return true
    }

    private func smartFillScenePlan(from result: SmartFillPreparedPlanResult) -> SmartFillScenePlan? {
        guard result.slots.count == result.selectedAssetIds.count else { return nil }

        var assetsById: [String: Asset] = [:]
        for asset in assets where assetsById[asset.id] == nil {
            assetsById[asset.id] = asset
        }
        let photoSlots = zip(result.slots, result.selectedAssetIds).compactMap { slot, assetId -> PhotoSlot? in
            guard let asset = assetsById[assetId] else { return nil }
            return PhotoSlot(
                id: "slot-\(slot.role.rawValue)-\(slot.candidateReference)",
                asset: asset,
                planning: PlaybackPlanningSnapshot.smartFill(
                    slot: slot,
                    plannerResult: result.plannerResult,
                    focalSummary: smartFillFocalSummary(for: asset)
                )
            )
        }
        guard photoSlots.count == result.slots.count, !photoSlots.isEmpty else {
            return nil
        }

        let scene = PlaybackScene(
            id: "scene-smartfill-\(photoSlots.first?.asset.id ?? "empty")",
            photoSlots: photoSlots,
            smartFillReadback: result.readback
        )
        return SmartFillScenePlan(
            scene: scene,
            nextCandidateCursorOffset: result.nextCandidateCursorOffset,
            displayedAssetIds: result.displayedAssetIds
        )
    }

    func capturePreparedSmartFillPlanRequest(
        startingAt startIndex: Int,
        displayedAssetIdsForExclusion: Set<String>? = nil,
        sceneOrdinal: Int? = nil
    ) -> SmartFillPreparedPlanRequest? {
        guard let smartFillSurface,
            let fingerprint = makePreparedSmartFillSceneFingerprint(),
            isSmartFillPlanningEnabled,
            !assets.isEmpty,
            startIndex >= 0,
            startIndex < assets.count
        else {
            return nil
        }

        let displayedAssetIds = displayedAssetIdsForExclusion ?? smartFillDisplayedAssetIds
        let rawSnapshots = smartFillCandidateAssets(
            startingAt: startIndex,
            displayedAssetIdsForExclusion: displayedAssetIds
        ).map { asset in
            smartFillRawAssetSnapshot(for: asset)
        }
        guard !rawSnapshots.isEmpty else { return nil }
        let policy = PlaybackSmartFillLayoutPolicy.policy(for: smartFillSurface)
        return SmartFillPreparedPlanRequest(
            requestId: UUID(),
            surface: smartFillSurface,
            layoutPolicyId: policy.layoutPolicyId,
            protectionSnapshot: smartFillProtectionSnapshot,
            protectionFingerprint: smartFillProtectionSnapshot.smartFillReplanFingerprint,
            candidateCursor: startIndex,
            displayedAssetIds: displayedAssetIds,
            assetPoolIdentity: fingerprint.assetPoolIdentity,
            playbackSourceGeneration: playbackSourceGeneration,
            playbackSessionSeed: "generation-\(playbackSourceGeneration)",
            sceneOrdinal: sceneOrdinal ?? startIndex,
            preparedFingerprint: fingerprint,
            rawAssetSnapshots: rawSnapshots
        )
    }

    private func smartFillRawAssetSnapshot(for asset: Asset) -> SmartFillPlanningRawAssetSnapshot {
        SmartFillPlanningRawAssetSnapshot(
            assetId: asset.id,
            width: asset.width,
            height: asset.height,
            exifImageWidth: asset.exifInfo?.exifImageWidth,
            exifImageHeight: asset.exifInfo?.exifImageHeight,
            orientation: asset.exifInfo?.orientation,
            thumbhash: asset.thumbhash,
            rawFaces: (asset.people ?? []).flatMap { person in
                (person.faces ?? []).map { face in
                    SmartFillPlanningRawFaceSnapshot(
                        boundingBoxX1: face.boundingBoxX1,
                        boundingBoxX2: face.boundingBoxX2,
                        boundingBoxY1: face.boundingBoxY1,
                        boundingBoxY2: face.boundingBoxY2,
                        imageWidth: face.imageWidth,
                        imageHeight: face.imageHeight,
                        sourceType: face.sourceType
                    )
                }
            }
        )
    }

    func makePreparedSmartFillSceneFingerprint() -> PlaybackPreparedSceneFingerprint? {
        guard let smartFillSurface else { return nil }
        return PlaybackPreparedSceneFingerprint(
            deviceProfile: smartFillSurface.profile.rawValue,
            orientation: smartFillSurface.orientation.rawValue,
            pointWidth: Double(smartFillSurface.pixelSize.width),
            pointHeight: Double(smartFillSurface.pixelSize.height),
            safeAreaClass: smartFillSurface.safeAreaClass,
            controlBarClass: "soft-overlay",
            exifOverlayClass: "metadata-overlay",
            assetPoolIdentity: smartFillAssetPoolIdentity(),
            playbackSourceIdentity: "\(logName(for: source))-\(playbackSourceGeneration)"
        )
    }

    private func smartFillAssetPoolIdentity() -> String {
        let raw = assets.map(\.id).joined(separator: "|")
        let digest = SHA256.hash(data: Data(raw.utf8))
        let hashText = digest.prefix(Self.identifierDigestPrefixBytes).map { String(format: "%02x", $0) }.joined()
        return "count-\(assets.count)-\(hashText)"
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
        guard !assets.isEmpty,
            startIndex >= 0,
            startIndex < assets.count
        else {
            return []
        }

        let uniqueAssetCount = Set(assets.map(\.id)).count
        let maxCandidateCount = min(smartFillCandidateWindowCount, uniqueAssetCount)
        let displayedAssetIds = displayedAssetIdsForExclusion ?? smartFillDisplayedAssetIds
        let shouldSkipDisplayedAssets = excludingDisplayedAssets && displayedAssetIds.count < uniqueAssetCount
        var candidateAssets: [Asset] = []
        var candidateAssetIds: Set<String> = []

        for offset in 0..<assets.count {
            let candidate = assets[(startIndex + offset) % assets.count]
            guard candidateAssetIds.insert(candidate.id).inserted else {
                continue
            }
            if shouldSkipDisplayedAssets,
                displayedAssetIds.contains(candidate.id)
            {
                continue
            }
            candidateAssets.append(candidate)
            if candidateAssets.count >= maxCandidateCount {
                break
            }
        }
        return candidateAssets
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

    private func smartFillFocalSummary(for asset: Asset) -> PlaybackPlanningFocalSummary? {
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
        return smartFillFocalSummary(faceRects: faceRects, subjectRects: faceRects)
    }

    private func smartFillFocalSummary(
        faceRects: [PlaybackPlanningRect],
        subjectRects: [PlaybackPlanningRect]
    ) -> PlaybackPlanningFocalSummary? {
        if let face = faceRects.first {
            return PlaybackPlanningFocalSummary(source: .face, rectInSource: face)
        }
        if let subject = subjectRects.first {
            return PlaybackPlanningFocalSummary(source: .subject, rectInSource: subject)
        }
        return nil
    }

    private func smartFillCandidateReference(for rawId: String) -> String {
        let digest = SHA256.hash(data: Data(rawId.utf8))
        let hashText = digest.prefix(Self.identifierDigestPrefixBytes).map { String(format: "%02x", $0) }.joined()
        return "asset_\(hashText)"
    }

    private func smartFillPixelSize(width: Int?, height: Int?) -> PlaybackPlanningPixelSize? {
        guard let width, let height else { return nil }
        return PlaybackPlanningPixelSize(width: width, height: height)
    }
}
