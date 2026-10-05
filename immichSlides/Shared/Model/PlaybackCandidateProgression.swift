import Foundation

/// Synchronous candidate traversal and reservations for both single photo and SmartFill playback.
@MainActor
final class PlaybackCandidateProgression {
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

    var cursorIndexForReadback: Int { candidateCursorIndex }
    var pendingResumeAssetCountForReadback: Int? { pendingCursorResumeAfterLoadMoreAssetCount }
    var surface: PlaybackSmartFillSurface? { planningSurface }
    var protectionSnapshot: PlaybackProtectionSnapshot { planningProtectionSnapshot }

    func updatePlanningContext(
        surface: PlaybackSmartFillSurface,
        protectionSnapshot: PlaybackProtectionSnapshot
    ) {
        planningSurface = surface
        planningProtectionSnapshot = protectionSnapshot
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
        advancesCursor: Bool = true
    ) {
        pendingCandidateCursorIndexAfterCommit =
            advancesCursor
            ? cursorIndex(
                in: assets, afterAdvancingFrom: sourceCursor, by: offset,
                excludingDisplayedAssetIds: displayedAssetIdsAfterCommit)
            : nil
        pendingDisplayedAssetIdsAfterCommit = advancesCursor ? displayedAssetIdsAfterCommit : nil
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

    func cursorIndex(
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
    func markPoolConsumedForTesting(assets: [Asset], candidateCursorIndex: Int) {
        displayedAssetIds = Set(assets.map(\.id))
        self.candidateCursorIndex = min(max(0, candidateCursorIndex), max(0, assets.count - 1))
        cancelPendingSelection()
        pendingCursorResumeAfterLoadMoreAssetCount = nil
    }
    #endif
}
