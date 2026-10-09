import Foundation
import CryptoKit
import CoreGraphics

/// Candidate traversal, reservations and prepared planning for single photo and SmartFill playback.
@MainActor
final class PlaybackCandidateProgression {
    static let identifierDigestPrefixBytes = 8
    private var replanFingerprint: String?
    private var preparedRefreshTask: Task<Void, Never>?
    private var preparedRefreshGeneration: UUID?
    private var lookaheadTasks: [UUID: Task<Void, Never>] = [:]
    private var lookaheadProposal: PreparedCompletion?
    private var candidateCursorIndex = 0
    private var pendingCandidateCursorIndexAfterCommit: Int?
    private var displayedAssetIds: Set<String> = []
    private var pendingDisplayedAssetIdsAfterCommit: Set<String>?
    private var pendingCursorResumeAfterLoadMoreAssetCount: Int?
    private var planningSurface: PlaybackSmartFillSurface?
    private var planningProtectionSnapshot: PlaybackProtectionSnapshot = .empty

    struct PendingAcceptance {
        fileprivate let cursorIndex: Int?
        fileprivate let displayedAssetIds: Set<String>?
    }

    struct LoadMoreHold {
        let displayedAssetCount: Int
        let shouldStartLoadMore: Bool
    }

    enum LoadMoreResume {
        case unchanged
        case cleared
        case resumed
    }

    var currentCursorIndex: Int { candidateCursorIndex }
    var surface: PlaybackSmartFillSurface? { planningSurface }
    var protectionSnapshot: PlaybackProtectionSnapshot { planningProtectionSnapshot }

    func updatePlanningContext(
        surface: PlaybackSmartFillSurface,
        protectionSnapshot: PlaybackProtectionSnapshot
    ) -> Bool {
        let fingerprint = [
            surface.internalSurfaceFingerprint,
            protectionSnapshot.smartFillReplanFingerprint
        ].joined(separator: "||")
        guard replanFingerprint != fingerprint else { return false }
        replanFingerprint = fingerprint
        cancelPreparedRefresh()
        planningSurface = surface
        planningProtectionSnapshot = protectionSnapshot
        return true
    }

    deinit {
        preparedRefreshTask?.cancel()
        lookaheadTasks.values.forEach { $0.cancel() }
    }

    func exclusionsForPlanning(includesPendingReservation: Bool) -> Set<String> {
        includesPendingReservation ? pendingDisplayedAssetIdsAfterCommit ?? displayedAssetIds : displayedAssetIds
    }

    func cancelPendingSelection() {
        pendingCandidateCursorIndexAfterCommit = nil
        pendingDisplayedAssetIdsAfterCommit = nil
    }

    func recordInitialSelection(_ assetIds: Set<String>) {
        displayedAssetIds = assetIds
        pendingDisplayedAssetIdsAfterCommit = nil
    }

    func resetCursor(in assets: [Asset], nextCandidateCursorOffset: Int = 1) {
        candidateCursorIndex =
            assets.isEmpty
            ? 0
            : cursorIndex(
                in: assets, afterAdvancingFrom: 0, by: max(0, nextCandidateCursorOffset),
                excludingDisplayedAssetIds: displayedAssetIds
            )
        cancelPendingSelection()
        pendingCursorResumeAfterLoadMoreAssetCount = nil
    }

    func normalizedCursorIndex(in assets: [Asset]) -> Int {
        guard !assets.isEmpty else {
            preconditionFailure("normalizedCandidateCursorIndex requires non-empty assets")
        }
        if candidateCursorIndex >= 0 && candidateCursorIndex < assets.count {
            let normalizedIndex = nextCursorIndex(
                in: assets, startingAt: candidateCursorIndex, excludingDisplayedAssetIds: displayedAssetIds)
            candidateCursorIndex = normalizedIndex
            return normalizedIndex
        }
        candidateCursorIndex = 0
        let normalizedIndex = nextCursorIndex(in: assets, startingAt: 0, excludingDisplayedAssetIds: displayedAssetIds)
        candidateCursorIndex = normalizedIndex
        return normalizedIndex
    }

    func preparedSourceCursor(in assets: [Asset]) -> Int? {
        guard !assets.isEmpty else { return nil }
        let startIndex = candidateCursorIndex >= 0 && candidateCursorIndex < assets.count ? candidateCursorIndex : 0
        return nextCursorIndex(in: assets, startingAt: startIndex, excludingDisplayedAssetIds: displayedAssetIds)
    }

    func reserveSelection(
        in assets: [Asset],
        startingAt sourceCursor: Int,
        advancingBy offset: Int,
        displayedAssetIdsAfterCommit: Set<String>,
        reservesOnAcceptance: Bool = true
    ) {
        pendingCandidateCursorIndexAfterCommit =
            reservesOnAcceptance
            ? cursorIndex(
                in: assets, afterAdvancingFrom: sourceCursor, by: offset,
                excludingDisplayedAssetIds: displayedAssetIdsAfterCommit)
            : nil
        pendingDisplayedAssetIdsAfterCommit = reservesOnAcceptance ? displayedAssetIdsAfterCommit : nil
    }

    func capturePendingAcceptance() -> PendingAcceptance {
        PendingAcceptance(
            cursorIndex: pendingCandidateCursorIndexAfterCommit,
            displayedAssetIds: pendingDisplayedAssetIdsAfterCommit)
    }

    func accept(_ pending: PendingAcceptance, appendsNewTailScene: Bool, assetCount: Int) {
        if let assetIds = pending.displayedAssetIds {
            displayedAssetIds = assetIds
        }
        if appendsNewTailScene, let index = pending.cursorIndex {
            candidateCursorIndex = assetCount == 0 ? 0 : min(max(0, index), assetCount - 1)
        }
        cancelPendingSelection()
    }

    func replaceCurrentSelection(
        in assets: [Asset], startingAt anchorIndex: Int, advancingBy offset: Int,
        displayedAssetIdsAfterRebuild: Set<String>
    ) {
        displayedAssetIds = displayedAssetIdsAfterRebuild
        candidateCursorIndex = cursorIndex(
            in: assets, afterAdvancingFrom: anchorIndex, by: offset, excludingDisplayedAssetIds: displayedAssetIds)
    }

    func adjustAfterRemovingPrefix(_ removeCount: Int, remainingAssets: [Asset]) {
        guard removeCount > 0 else { return }
        candidateCursorIndex = max(0, candidateCursorIndex - removeCount)
        if let pendingIndex = pendingCandidateCursorIndexAfterCommit {
            pendingCandidateCursorIndexAfterCommit = max(0, pendingIndex - removeCount)
        }
        if !remainingAssets.isEmpty {
            let currentAssetIds = Set(remainingAssets.map(\.id))
            displayedAssetIds.formIntersection(currentAssetIds)
            if let pendingAssetIds = pendingDisplayedAssetIdsAfterCommit {
                pendingDisplayedAssetIdsAfterCommit = pendingAssetIds.intersection(currentAssetIds)
            }
            candidateCursorIndex = min(candidateCursorIndex, remainingAssets.count - 1)
            if let pendingIndex = pendingCandidateCursorIndexAfterCommit {
                pendingCandidateCursorIndexAfterCommit = min(pendingIndex, remainingAssets.count - 1)
            }
        } else {
            displayedAssetIds = []
            pendingDisplayedAssetIdsAfterCommit = nil
        }
    }

    func holdForLoadMoreIfConsumed(
        assets: [Asset], includesPendingReservation: Bool, isLoadingMore: Bool
    ) -> LoadMoreHold? {
        let currentAssetIds = Set(assets.map(\.id))
        let exclusions = exclusionsForPlanning(includesPendingReservation: includesPendingReservation)
            .intersection(currentAssetIds)
        guard !currentAssetIds.contains(where: { !exclusions.contains($0) }) else { return nil }
        let shouldStartLoadMore = !isLoadingMore && pendingCursorResumeAfterLoadMoreAssetCount == nil
        pendingCursorResumeAfterLoadMoreAssetCount = assets.count
        return LoadMoreHold(displayedAssetCount: exclusions.count, shouldStartLoadMore: shouldStartLoadMore)
    }

    func resumeAfterAppendingLoadMore(oldCount: Int, appendedCount: Int, assetCount: Int) -> LoadMoreResume {
        guard pendingCursorResumeAfterLoadMoreAssetCount != nil, oldCount > 0 else { return .unchanged }
        guard appendedCount > 0, oldCount < assetCount else {
            pendingCursorResumeAfterLoadMoreAssetCount = nil
            return .cleared
        }
        pendingCursorResumeAfterLoadMoreAssetCount = nil
        candidateCursorIndex = min(max(0, oldCount), assetCount - 1)
        pendingCandidateCursorIndexAfterCommit = nil
        return .resumed
    }

    func clearPendingLoadMoreResume() -> Bool {
        guard pendingCursorResumeAfterLoadMoreAssetCount != nil else { return false }
        pendingCursorResumeAfterLoadMoreAssetCount = nil
        return true
    }

    func progressIndexForLoadMore(assetCount: Int) -> Int {
        guard assetCount > 0 else { return 0 }
        let lastCommittedIndex = candidateCursorIndex == 0 ? assetCount - 1 : candidateCursorIndex - 1
        return min(max(0, lastCommittedIndex), assetCount - 1)
    }

    private func cursorIndex(
        in assets: [Asset], afterAdvancingFrom assetIndex: Int, by consumedCount: Int,
        excludingDisplayedAssetIds exclusions: Set<String>
    ) -> Int {
        guard !assets.isEmpty else { return 0 }
        let safeStartIndex = min(max(0, assetIndex), assets.count - 1)
        let unfilteredIndex = (safeStartIndex + max(0, consumedCount)) % assets.count
        return nextCursorIndex(in: assets, startingAt: unfilteredIndex, excludingDisplayedAssetIds: exclusions)
    }

    private func nextCursorIndex(
        in assets: [Asset], startingAt startIndex: Int, excludingDisplayedAssetIds exclusions: Set<String>
    ) -> Int {
        guard !assets.isEmpty else { return 0 }
        let safeStartIndex = min(max(0, startIndex), assets.count - 1)
        guard !exclusions.isEmpty else { return safeStartIndex }
        for offset in 0..<assets.count {
            let candidateIndex = (safeStartIndex + offset) % assets.count
            if !exclusions.contains(assets[candidateIndex].id) { return candidateIndex }
        }
        return safeStartIndex
    }

    func candidateAssets(
        in assets: [Asset], startingAt startIndex: Int, windowCount: Int,
        excludingDisplayedAssets: Bool = true, displayedAssetIdsForExclusion: Set<String>? = nil
    ) -> [Asset] {
        guard !assets.isEmpty, startIndex >= 0, startIndex < assets.count else { return [] }
        let uniqueAssetCount = Set(assets.map(\.id)).count
        let maxCandidateCount = min(windowCount, uniqueAssetCount)
        let exclusions = displayedAssetIdsForExclusion ?? displayedAssetIds
        let shouldSkipDisplayedAssets = excludingDisplayedAssets && exclusions.count < uniqueAssetCount
        var candidates: [Asset] = []
        var candidateIds: Set<String> = []
        for offset in 0..<assets.count {
            let candidate = assets[(startIndex + offset) % assets.count]
            guard candidateIds.insert(candidate.id).inserted else { continue }
            if shouldSkipDisplayedAssets, exclusions.contains(candidate.id) { continue }
            candidates.append(candidate)
            if candidates.count >= maxCandidateCount { break }
        }
        return candidates
    }

    #if DEBUG
    var pendingResumeAssetCountForTesting: Int? { pendingCursorResumeAfterLoadMoreAssetCount }

    var lookaheadDiagnosticSnapshotForTesting: (sourceCursor: Int, selectedCount: Int)? {
        lookaheadProposal.map { ($0.request.candidateCursor, $0.result.selectedAssetIds.count) }
    }

    var hasInFlightPlanningForTesting: Bool { preparedRefreshTask != nil || !lookaheadTasks.isEmpty }

    func markPoolConsumedForTesting(assets: [Asset], candidateCursorIndex: Int) {
        displayedAssetIds = Set(assets.map(\.id))
        self.candidateCursorIndex = min(max(0, candidateCursorIndex), max(0, assets.count - 1))
        cancelPendingSelection()
        pendingCursorResumeAfterLoadMoreAssetCount = nil
    }
    #endif
}

extension PlaybackCandidateProgression {
    struct PreparationInput {
        let assets: [Asset]
        let sourceGeneration: Int
        let sourceName: String
        let isEnabled: Bool
        let candidateWindowCount: Int
    }

    struct PreparedCompletion {
        let request: SmartFillPreparedPlanRequest
        let result: SmartFillPreparedPlanResult
    }

    struct PreparedProposal {
        let scene: PlaybackScene
        let fingerprint: PlaybackPreparedSceneFingerprint
        let cursorEffect: PlaybackPreparedSceneCursorEffect
    }

    enum PreparedDelivery {
        case stale
        case invalid
        case proposal(PreparedProposal)
    }

    func cancelPreparedRefresh() {
        preparedRefreshTask?.cancel()
        preparedRefreshTask = nil
        preparedRefreshGeneration = nil
    }

    private func clearPreparedRefreshIfCurrent(_ generation: UUID) {
        guard preparedRefreshGeneration == generation else { return }
        preparedRefreshTask = nil
        preparedRefreshGeneration = nil
    }

    func refreshPreparedPlan(
        request: SmartFillPreparedPlanRequest,
        completion: @escaping @MainActor (PreparedCompletion) -> Void
    ) {
        cancelPreparedRefresh()
        let generation = UUID()
        preparedRefreshGeneration = generation
        let planningTask = Task.detached(priority: .utility) {
            SmartFillPreparedPlanBuilder.makeResult(for: request)
        }
        preparedRefreshTask = Task { @MainActor in
            let result = await withTaskCancellationHandler {
                await planningTask.value
            } onCancel: {
                planningTask.cancel()
            }
            guard !Task.isCancelled, let result else {
                self.clearPreparedRefreshIfCurrent(generation)
                return
            }
            if self.preparedRefreshGeneration == generation {
                completion(PreparedCompletion(request: request, result: result))
            }
            self.clearPreparedRefreshIfCurrent(generation)
        }
    }

    func prepareDelivery(
        _ completion: PreparedCompletion, in input: PreparationInput
    ) -> PreparedDelivery {
        let request = completion.request
        let result = completion.result
        guard isPreparedResultFresh(result, request: request, in: input) else { return .stale }
        guard let scene = scene(from: result, assets: input.assets) else { return .invalid }
        guard let fingerprint = preparedFingerprint(in: input) else { return .stale }
        return .proposal(
            PreparedProposal(
                scene: scene,
                fingerprint: fingerprint,
                cursorEffect: PlaybackPreparedSceneCursorEffect(
                    sourceCursor: result.sourceCursor,
                    nextCandidateCursorOffset: result.nextCandidateCursorOffset,
                    displayedAssetIds: result.displayedAssetIds
                )
            )
        )
    }

    func prepareLookahead(
        after preparedCompletion: PreparedCompletion,
        in input: PreparationInput,
        onCompletion receive: @escaping @MainActor (PreparedCompletion) -> Void
    ) {
        let result = preparedCompletion.result
        let request = preparedCompletion.request
        guard result.requestId == request.requestId,
            result.sourceCursor == request.candidateCursor,
            result.assetPoolIdentity == request.assetPoolIdentity,
            result.playbackSourceGeneration == request.playbackSourceGeneration
        else { return }
        let displayedAssetIdsAfterPreparedScene = request.displayedAssetIds.union(result.displayedAssetIds)
        let nextCursor = cursorIndex(
            in: input.assets,
            afterAdvancingFrom: result.sourceCursor,
            by: result.nextCandidateCursorOffset,
            excludingDisplayedAssetIds: displayedAssetIdsAfterPreparedScene
        )
        guard
            let lookaheadRequest = capturePreparedRequest(
                in: input,
                startingAt: nextCursor,
                displayedAssetIdsForExclusion: displayedAssetIdsAfterPreparedScene,
                sceneOrdinal: nextCursor
            )
        else { return }
        let planningTask = Task.detached(priority: .utility) {
            SmartFillPreparedPlanBuilder.makeResult(for: lookaheadRequest)
        }
        let taskId = UUID()
        lookaheadTasks[taskId] = Task { @MainActor [weak self] in
            let result = await withTaskCancellationHandler {
                await planningTask.value
            } onCancel: {
                planningTask.cancel()
            }
            guard let self else { return }
            defer { self.lookaheadTasks[taskId] = nil }
            guard !Task.isCancelled, let result else { return }
            receive(PreparedCompletion(request: lookaheadRequest, result: result))
        }
    }

    func storeLookaheadIfFresh(
        _ completion: PreparedCompletion, in input: PreparationInput
    ) -> PlaybackScene? {
        guard isLookaheadResultFresh(completion.result, request: completion.request, in: input),
            let scene = scene(from: completion.result, assets: input.assets)
        else { return nil }
        lookaheadProposal = completion
        return scene
    }

    func takeLookaheadIfReady(in input: PreparationInput) -> PreparedCompletion? {
        guard let proposal = lookaheadProposal,
            proposal.request.candidateCursor == preparedSourceCursor(in: input.assets)
        else { return nil }
        lookaheadProposal = nil
        return proposal
    }

    func clearLookaheadProposal() {
        lookaheadProposal = nil
    }

    private func isLookaheadResultFresh(
        _ result: SmartFillPreparedPlanResult,
        request: SmartFillPreparedPlanRequest,
        in input: PreparationInput
    ) -> Bool {
        result.requestId == request.requestId && result.sourceCursor == request.candidateCursor
            && result.assetPoolIdentity == request.assetPoolIdentity
            && result.playbackSourceGeneration == request.playbackSourceGeneration
            && request.playbackSourceGeneration == input.sourceGeneration
            && request.assetPoolIdentity == assetPoolIdentity(in: input)
            && request.protectionFingerprint == request.protectionSnapshot.smartFillReplanFingerprint
            && request.protectionFingerprint == planningProtectionSnapshot.smartFillReplanFingerprint
            && request.preparedFingerprint == preparedFingerprint(in: input)
            && request.surface == planningSurface
            && request.layoutPolicyId == PlaybackSmartFillLayoutPolicy.policy(for: request.surface).layoutPolicyId
            && !input.assets.isEmpty && input.isEnabled
    }

    private func isPreparedResultFresh(
        _ result: SmartFillPreparedPlanResult,
        request: SmartFillPreparedPlanRequest,
        in input: PreparationInput
    ) -> Bool {
        guard result.requestId == request.requestId,
            result.sourceCursor == request.candidateCursor,
            result.assetPoolIdentity == request.assetPoolIdentity,
            result.playbackSourceGeneration == request.playbackSourceGeneration,
            request.playbackSourceGeneration == input.sourceGeneration,
            request.assetPoolIdentity == assetPoolIdentity(in: input),
            request.protectionFingerprint == request.protectionSnapshot.smartFillReplanFingerprint,
            request.protectionFingerprint == planningProtectionSnapshot.smartFillReplanFingerprint,
            request.preparedFingerprint == preparedFingerprint(in: input),
            request.surface == planningSurface,
            request.layoutPolicyId == PlaybackSmartFillLayoutPolicy.policy(for: request.surface).layoutPolicyId,
            !input.assets.isEmpty,
            request.candidateCursor == normalizedCursorIndex(in: input.assets),
            input.isEnabled
        else {
            return false
        }
        return true
    }

    private func scene(from result: SmartFillPreparedPlanResult, assets: [Asset]) -> PlaybackScene? {
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
        return scene
    }

    func capturePreparedRequest(
        in input: PreparationInput, startingAt startIndex: Int
    ) -> SmartFillPreparedPlanRequest? {
        capturePreparedRequest(
            in: input, startingAt: startIndex, displayedAssetIdsForExclusion: nil, sceneOrdinal: nil)
    }

    private func capturePreparedRequest(
        in input: PreparationInput,
        startingAt startIndex: Int,
        displayedAssetIdsForExclusion: Set<String>?,
        sceneOrdinal: Int?
    ) -> SmartFillPreparedPlanRequest? {
        guard let planningSurface,
            let fingerprint = preparedFingerprint(in: input),
            input.isEnabled,
            !input.assets.isEmpty,
            startIndex >= 0,
            startIndex < input.assets.count
        else {
            return nil
        }

        let displayedAssetIds =
            displayedAssetIdsForExclusion
            ?? exclusionsForPlanning(includesPendingReservation: false)
        let rawSnapshots = candidateAssets(
            in: input.assets,
            startingAt: startIndex,
            windowCount: input.candidateWindowCount,
            displayedAssetIdsForExclusion: displayedAssetIds
        ).map { asset in
            smartFillRawAssetSnapshot(for: asset)
        }
        guard !rawSnapshots.isEmpty else { return nil }
        let policy = PlaybackSmartFillLayoutPolicy.policy(for: planningSurface)
        return SmartFillPreparedPlanRequest(
            requestId: UUID(),
            surface: planningSurface,
            layoutPolicyId: policy.layoutPolicyId,
            protectionSnapshot: planningProtectionSnapshot,
            protectionFingerprint: planningProtectionSnapshot.smartFillReplanFingerprint,
            candidateCursor: startIndex,
            displayedAssetIds: displayedAssetIds,
            assetPoolIdentity: fingerprint.assetPoolIdentity,
            playbackSourceGeneration: input.sourceGeneration,
            playbackSessionSeed: "generation-\(input.sourceGeneration)",
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

    func preparedFingerprint(in input: PreparationInput) -> PlaybackPreparedSceneFingerprint? {
        guard let planningSurface else { return nil }
        return PlaybackPreparedSceneFingerprint(
            deviceProfile: planningSurface.profile.rawValue,
            orientation: planningSurface.orientation.rawValue,
            pointWidth: Double(planningSurface.pixelSize.width),
            pointHeight: Double(planningSurface.pixelSize.height),
            safeAreaClass: planningSurface.safeAreaClass,
            controlBarClass: "soft-overlay",
            exifOverlayClass: "metadata-overlay",
            assetPoolIdentity: assetPoolIdentity(in: input),
            playbackSourceIdentity: "\(input.sourceName)-\(input.sourceGeneration)"
        )
    }

    private func assetPoolIdentity(in input: PreparationInput) -> String {
        let raw = input.assets.map(\.id).joined(separator: "|")
        let digest = SHA256.hash(data: Data(raw.utf8))
        let hashText = digest.prefix(Self.identifierDigestPrefixBytes).map { String(format: "%02x", $0) }.joined()
        return "count-\(input.assets.count)-\(hashText)"
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
        return Self.smartFillFocalSummary(faceRects: faceRects, subjectRects: faceRects)
    }

    nonisolated static func smartFillFocalSummary(
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
}
