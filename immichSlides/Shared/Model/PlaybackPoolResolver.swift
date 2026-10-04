//
//  PlaybackPoolResolver.swift
//  immichSlides
//
//  Created by sudoHG on 2026/3/6.
//

import Foundation
import OSLog

// Why the pool is empty, so the UI does not treat every assets.isEmpty as the same failure.

enum PlaybackPoolEmptyReason: String, Equatable {
    case invalidTargetCount
    case noActiveRules
    case noMatchingAssets
    case strictSoloVisionUnavailable
}

struct PlaybackPoolResolveResult {
    let assets: [Asset]
    let emptyReason: PlaybackPoolEmptyReason?
}

struct PlaybackAssetIDReplayConfiguration: Equatable {
    let orderedAssetIDs: [String]
    let source: String
}

// Resolve statistics, not shown to users; used to work out the empty-pool reason.

struct PlaybackPoolResolveDiagnostics: Equatable {
    var soloFetchedCandidateCount: Int = 0
    var soloLocalQualifiedCandidateCount: Int = 0
    var soloVisionApprovedCount: Int = 0
    var soloVisionFinishedCount: Int = 0
    var soloVisionFailedCount: Int = 0
    var soloVisionIncompleteCount: Int = 0

    mutating func merge(_ result: SoloVisionBatchResult) {
        soloVisionApprovedCount += result.approvedAssets.count
        soloVisionFinishedCount += result.finishedCount
        soloVisionFailedCount += result.failedCount
        soloVisionIncompleteCount += result.incompleteCount
    }

    mutating func merge(_ other: PlaybackPoolResolveDiagnostics) {
        soloFetchedCandidateCount += other.soloFetchedCandidateCount
        soloLocalQualifiedCandidateCount += other.soloLocalQualifiedCandidateCount
        soloVisionApprovedCount += other.soloVisionApprovedCount
        soloVisionFinishedCount += other.soloVisionFinishedCount
        soloVisionFailedCount += other.soloVisionFailedCount
        soloVisionIncompleteCount += other.soloVisionIncompleteCount
    }

    func emptyReason(activeRuleCount: Int, finalAssetCount: Int) -> PlaybackPoolEmptyReason? {
        guard finalAssetCount == 0 else { return nil }
        guard activeRuleCount > 0 else { return .noActiveRules }

        // If metadata has candidates but Vision did not finish, record the empty-pool reason as Vision unavailable.

        if soloLocalQualifiedCandidateCount > 0,
            soloVisionApprovedCount == 0,
            soloVisionFinishedCount == 0,
            soloVisionFailedCount + soloVisionIncompleteCount > 0
        {
            return .strictSoloVisionUnavailable
        }

        return .noMatchingAssets
    }
}

final class PlaybackPoolResolver {
    #if DEBUG
    typealias RandomAssetProviderForTesting = (
        _ size: Int,
        _ albumIds: [String]?,
        _ personIds: [String]?
    ) async throws -> [Asset]
    typealias PersonAssetsCountProviderForTesting = (_ personId: String) async throws -> Int
    typealias SoloApprovalProviderForTesting = (
        _ candidates: [Asset],
        _ acceptedLimit: Int
    ) async -> SoloVisionBatchResult
    #endif

    private let apiService: ImmichAPIService

    private let soloVisionFilter: SoloVisionPoolFilter

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "immichSlides",
        category: "PlaybackPool"
    )

    init(
        apiService: ImmichAPIService = .shared,
        soloVisionFilter: SoloVisionPoolFilter = .shared
    ) {
        self.apiService = apiService
        self.soloVisionFilter = soloVisionFilter

    }
    #if DEBUG
    var randomAssetProviderForTesting: RandomAssetProviderForTesting?
    var personAssetsCountProviderForTesting: PersonAssetsCountProviderForTesting?
    var soloApprovalProviderForTesting: SoloApprovalProviderForTesting?
    private(set) var strictSoloDebugEventsForTesting: [PlaybackSequenceDebugEventInput] = []
    var playbackSequenceDebugEventSink: (@MainActor (PlaybackSequenceDebugEventInput) -> Void)?
    #endif

    private var recentlyPlayedQueue: [String] = []
    private var recentlyPlayedIds: Set<String> = []

    func resolve(selection: FilterSelection, targetCount: Int) async throws -> [Asset] {
        try await resolve(
            selection: selection,
            targetCount: targetCount,
            excludingAssetIds: []
        )
    }

    func resolve(
        selection: FilterSelection,
        targetCount: Int,
        excludingAssetIds: Set<String>
    ) async throws -> [Asset] {
        let result = try await resolveDetailed(
            selection: selection,
            targetCount: targetCount,
            excludingAssetIds: excludingAssetIds
        )
        return result.assets
    }

    func resolveDetailed(
        selection: FilterSelection,
        targetCount: Int,
        excludingAssetIds: Set<String> = []
    ) async throws -> PlaybackPoolResolveResult {
        #if DEBUG
        strictSoloDebugEventsForTesting = []
        #endif
        guard targetCount > 0 else {
            logger.warning("resolve skipped invalid targetCount=\(targetCount, privacy: .public)")
            return PlaybackPoolResolveResult(
                assets: [],
                emptyReason: .invalidTargetCount
            )
        }

        #if DEBUG
        if let replayConfiguration = try Self.assetIDReplayConfiguration() {
            let requestedIDs = Array(replayConfiguration.orderedAssetIDs.prefix(targetCount))
            logger.notice(
                "resolve asset-id replay begin requestedCount=\(requestedIDs.count, privacy: .public) source=\(replayConfiguration.source, privacy: .private)"
            )
            let replayAssets = try await apiService.getAssets(ids: requestedIDs)
                .filter { !excludingAssetIds.contains($0.id) }
            updateCoolingPool(with: replayAssets, poolSize: max(replayAssets.count, 20))
            logger.notice(
                "resolve asset-id replay end requestedCount=\(requestedIDs.count, privacy: .public) finalCount=\(replayAssets.count, privacy: .public)"
            )
            return PlaybackPoolResolveResult(
                assets: replayAssets,
                emptyReason: replayAssets.isEmpty ? .noMatchingAssets : nil
            )
        }
        #endif

        // Clean and dedupe rules; if a person is both normal and soloOnly, soloOnly wins.

        let albumIds = Array(
            Set(
                selection.albumIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty })
        )

        let soloPersonIDs = Array(
            Set(
                selection.personFilters
                    .filter { $0.matchMode == .soloOnly }
                    .map { $0.personId.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty })
        )

        let soloSet = Set(soloPersonIDs)

        let normalPersonIDs = Array(
            Set(
                selection.personFilters
                    .filter { $0.matchMode == .normal }
                    .map { $0.personId.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
            .filter { !soloSet.contains($0) }
        )

        var assetsMap: [String: Asset] = [:]
        func addCandidateAsset(_ asset: Asset) {
            guard !excludingAssetIds.contains(asset.id) else { return }
            assetsMap[asset.id] = asset
        }

        var diagnostics = PlaybackPoolResolveDiagnostics()
        // With few rules, lower the budget floor instead of keeping the old minimum of 120.

        let activeRuleCount = albumIds.count + soloPersonIDs.count + normalPersonIDs.count
        logger.info(
            "resolve begin targetCount=\(targetCount, privacy: .public) activeRules=\(activeRuleCount, privacy: .public) albumRules=\(albumIds.count, privacy: .public) soloRules=\(soloPersonIDs.count, privacy: .public) normalRules=\(normalPersonIDs.count, privacy: .public) excludedCount=\(excludingAssetIds.count, privacy: .public)"
        )

        // Split the budget by sqrt(size) so large rules do not crowd out small ones.

        let albumSizeById = await fetchAlbumSizeMap(for: albumIds)
        let allPersonIds = Array(Set(soloPersonIDs + normalPersonIDs))
        let personSizeById = await fetchPersonSizeMap(for: allPersonIds)

        let cdPoolSize = getCdPoolSize(
            albumIds: albumIds,
            soloIds: soloPersonIDs,
            normalIds: normalPersonIDs,
            albumSizeById: albumSizeById,
            personSizeById: personSizeById
        )

        let minPerRule = 8
        let maxPerRule = 60
        let defaultEstimate = 50
        let totalBudget = Self.requestBudget(
            targetCount: targetCount,
            activeRuleCount: activeRuleCount,
            minPerRule: minPerRule
        )
        logger.info(
            "resolve budget targetCount=\(targetCount, privacy: .public) totalBudget=\(totalBudget, privacy: .public) minPerRule=\(minPerRule, privacy: .public) maxPerRule=\(maxPerRule, privacy: .public)"
        )

        var totalWeight: Double = 0
        for id in albumIds {
            let estimate = albumSizeById[id] ?? defaultEstimate
            totalWeight += sqrt(Double(max(estimate, 1)))
        }
        for id in soloPersonIDs {
            let estimate = personSizeById[id] ?? defaultEstimate
            totalWeight += sqrt(Double(max(estimate, 1)))
        }
        for id in normalPersonIDs {
            let estimate = personSizeById[id] ?? defaultEstimate
            totalWeight += sqrt(Double(max(estimate, 1)))
        }

        if totalWeight <= 0 { totalWeight = 1 }

        var albumFetchSizeById: [String: Int] = [:]
        var soloFetchSizeById: [String: Int] = [:]
        var normalFetchSizeById: [String: Int] = [:]

        for id in albumIds {
            let estimate = albumSizeById[id] ?? defaultEstimate
            let weight = sqrt(Double(max(estimate, 1)))
            let raw = Double(totalBudget) * weight / totalWeight
            let size = max(minPerRule, min(maxPerRule, Int(raw.rounded())))
            albumFetchSizeById[id] = size
        }
        for id in soloPersonIDs {
            let estimate = personSizeById[id] ?? defaultEstimate
            let weight = sqrt(Double(max(estimate, 1)))
            let raw = Double(totalBudget) * weight / totalWeight
            let size = max(minPerRule, min(maxPerRule, Int(raw.rounded())))
            soloFetchSizeById[id] = size
        }
        for id in normalPersonIDs {
            let estimate = personSizeById[id] ?? defaultEstimate
            let weight = sqrt(Double(max(estimate, 1)))
            let raw = Double(totalBudget) * weight / totalWeight
            let size = max(minPerRule, min(maxPerRule, Int(raw.rounded())))
            normalFetchSizeById[id] = size
        }

        if !albumIds.isEmpty {

            // A cancelled rule request must rethrow, so candidates are not fetched after the pool is empty.
            for id in albumIds {
                do {
                    let fetchSize = albumFetchSizeById[id] ?? minPerRule
                    let albumAssets = try await fetchRandomAsset(
                        size: fetchSize,
                        albumIds: [id],
                        personIds: nil
                    )

                    for asset in albumAssets {
                        addCandidateAsset(asset)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let message = error.localizedDescription
                    logger.error(
                        "album rule request failed albumId=\(id, privacy: .private) error=\(message, privacy: .private)"
                    )
                    continue
                }
            }
        }

        if !soloPersonIDs.isEmpty {
            let soloVisionDesiredCountPerRule = Self.soloVisionDesiredCountPerRule(
                targetCount: targetCount,
                soloRuleCount: soloPersonIDs.count,
                minPerRule: minPerRule
            )

            for id in soloPersonIDs {
                do {
                    let weightedFetchSize = soloFetchSizeById[id] ?? minPerRule
                    let desiredQualifiedCount = min(weightedFetchSize, soloVisionDesiredCountPerRule)
                    logger.info(
                        "solo rule begin personId=\(id, privacy: .private) weightedFetchSize=\(weightedFetchSize, privacy: .public) desiredQualifiedCount=\(desiredQualifiedCount, privacy: .public)"
                    )
                    let soloResult = try await resolveStrictSoloAssets(
                        personId: id,
                        desiredQualifiedCount: desiredQualifiedCount,
                        excludingAssetIds: excludingAssetIds.union(assetsMap.keys)
                    )
                    diagnostics.merge(soloResult.diagnostics)
                    let soloAssets = soloResult.assets
                    logger.info(
                        "solo rule end personId=\(id, privacy: .private) acceptedCount=\(soloAssets.count, privacy: .public) desiredQualifiedCount=\(desiredQualifiedCount, privacy: .public)"
                    )

                    for asset in soloAssets {
                        addCandidateAsset(asset)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let message = error.localizedDescription
                    logger.error(
                        "solo rule request failed personId=\(id, privacy: .private) error=\(message, privacy: .private)"
                    )
                    continue
                }
            }
        }

        if !normalPersonIDs.isEmpty {
            for id in normalPersonIDs {
                do {
                    let fetchSize = normalFetchSizeById[id] ?? minPerRule
                    let normalAssets = try await fetchRandomAsset(
                        size: fetchSize,
                        albumIds: nil,
                        personIds: [id]
                    )
                    for asset in normalAssets {
                        addCandidateAsset(asset)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let message = error.localizedDescription
                    logger.error(
                        "normal person rule request failed personId=\(id, privacy: .private) error=\(message, privacy: .private)"
                    )
                    continue
                }
            }
        }

        if assetsMap.count < targetCount {
            let refillRounds = 2
            for _ in 0..<refillRounds {
                if assetsMap.count >= targetCount { break }

                func refillSize(_ base: Int?) -> Int {
                    let b = base ?? minPerRule
                    return max(4, b / 2)
                }

                if !albumIds.isEmpty {
                    for id in albumIds {
                        do {
                            let moreAssets = try await fetchRandomAsset(
                                size: refillSize(albumFetchSizeById[id]),
                                albumIds: [id],
                                personIds: nil
                            )
                            for asset in moreAssets {
                                addCandidateAsset(asset)
                            }
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            continue
                        }
                    }
                }

                if !normalPersonIDs.isEmpty {
                    for id in normalPersonIDs {
                        do {
                            let moreAssets = try await fetchRandomAsset(
                                size: refillSize(normalFetchSizeById[id]),
                                albumIds: nil,
                                personIds: [id]
                            )
                            for asset in moreAssets {
                                addCandidateAsset(asset)
                            }
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            continue
                        }
                    }
                }
            }
        }

        let orderedCandidates = Self.stableCandidateOrder(Array(assetsMap.values))

        let preferredAssets = orderedCandidates.filter { !recentlyPlayedIds.contains($0.id) }
        let fallbackAssets = orderedCandidates.filter { recentlyPlayedIds.contains($0.id) }

        var finalAssets = Array(preferredAssets.prefix(targetCount))
        if finalAssets.count < targetCount {
            let need = targetCount - finalAssets.count
            finalAssets.append(contentsOf: fallbackAssets.prefix(need))
        }

        updateCoolingPool(with: finalAssets, poolSize: cdPoolSize)
        let emptyReason = diagnostics.emptyReason(
            activeRuleCount: activeRuleCount,
            finalAssetCount: finalAssets.count
        )
        logger.info(
            "resolve end targetCount=\(targetCount, privacy: .public) excludedCount=\(excludingAssetIds.count, privacy: .public) uniqueCandidateCount=\(assetsMap.count, privacy: .public) finalCount=\(finalAssets.count, privacy: .public) coolingPoolSize=\(cdPoolSize, privacy: .public) emptyReason=\(emptyReason?.rawValue ?? "none", privacy: .public)"
        )
        return PlaybackPoolResolveResult(
            assets: finalAssets,
            emptyReason: emptyReason
        )

    }

    private struct StrictSoloResolveResult {
        let assets: [Asset]
        let diagnostics: PlaybackPoolResolveDiagnostics
    }

    private func getCdPoolSize(
        albumIds: [String],
        soloIds: [String],
        normalIds: [String],
        albumSizeById: [String: Int],
        personSizeById: [String: Int]
    ) -> Int {
        var totalCount: Int = 0
        if !albumIds.isEmpty {
            for id in albumIds {
                totalCount += (albumSizeById[id] ?? 0)
            }
        }
        if !soloIds.isEmpty || !normalIds.isEmpty {
            let personIds = Array(Set(soloIds + normalIds))
            for id in personIds {
                totalCount += (personSizeById[id] ?? 0)
            }
        }

        let cdPoolSize = min(500, Int(ceil(Double(totalCount) * 0.05)))

        if cdPoolSize > 20 {
            return cdPoolSize
        } else {
            return 20
        }
    }

    private func fetchAlbumSizeMap(for albumIds: [String]) async -> [String: Int] {
        guard !albumIds.isEmpty else { return [:] }
        let albumIdSet = Set(albumIds)
        do {
            let allAlbums = try await apiService.getAllAlbums()
            var result: [String: Int] = [:]
            for album in allAlbums where albumIdSet.contains(album.id) {
                result[album.id] = album.assetCount
            }
            return result
        } catch {
            let message = error.localizedDescription
            logger.error(
                "album size map failed albumRuleCount=\(albumIds.count, privacy: .public) error=\(message, privacy: .private)"
            )
            return [:]
        }
    }

    private func fetchPersonSizeMap(for personIds: [String]) async -> [String: Int] {
        guard !personIds.isEmpty else { return [:] }
        var result: [String: Int] = [:]
        for id in personIds {
            do {
                let count = try await fetchPersonAssetsCount(id: id)
                result[id] = count
            } catch {
                let message = error.localizedDescription
                logger.error(
                    "person size failed personId=\(id, privacy: .private) error=\(message, privacy: .private)"
                )
                continue
            }
        }
        return result
    }

    private func fetchRandomAsset(
        size: Int,
        albumIds: [String]?,
        personIds: [String]?
    ) async throws -> [Asset] {
        #if DEBUG
        if let randomAssetProviderForTesting {
            return try await randomAssetProviderForTesting(size, albumIds, personIds)
        }
        #endif

        return try await apiService.getRandomAsset(
            size: size,
            albumIds: albumIds,
            personIds: personIds
        )
    }

    private func fetchPersonAssetsCount(id: String) async throws -> Int {
        #if DEBUG
        if let personAssetsCountProviderForTesting {
            return try await personAssetsCountProviderForTesting(id)
        }
        #endif

        return try await apiService.getPersonAssetsCount(id: id)
    }

    private func soloApprovalResult(
        from candidates: [Asset],
        acceptedLimit: Int
    ) async -> SoloVisionBatchResult {
        #if DEBUG
        if let soloApprovalProviderForTesting {
            return await soloApprovalProviderForTesting(candidates, acceptedLimit)
        }
        #endif

        return await soloVisionFilter.approvalResult(
            from: candidates,
            apiService: apiService,
            acceptedLimit: acceptedLimit
        )
    }

    static func requestBudget(
        targetCount: Int,
        activeRuleCount: Int,
        minPerRule: Int
    ) -> Int {
        let minimumBudget = max(activeRuleCount * minPerRule, 24)
        return max(targetCount * 2, minimumBudget)
    }

    static func soloVisionDesiredCountPerRule(
        targetCount: Int,
        soloRuleCount: Int,
        minPerRule: Int
    ) -> Int {
        guard soloRuleCount > 0 else { return minPerRule }
        let perRuleTarget = Int(
            ceil(Double(max(targetCount, 1)) / Double(soloRuleCount))
        )
        return max(minPerRule, perRuleTarget)
    }

    // Stable ordering keeps comparison runs reproducible.

    static func stableCandidateOrder(_ assets: [Asset]) -> [Asset] {
        assets.sorted { lhs, rhs in
            let lhsHash = stablePlaybackHash(lhs.id)
            let rhsHash = stablePlaybackHash(rhs.id)
            if lhsHash != rhsHash {
                return lhsHash < rhsHash
            }
            return lhs.id < rhs.id
        }
    }

    static func assetIDReplayConfiguration(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> PlaybackAssetIDReplayConfiguration? {
        let pathValue = environmentValue(
            "IMMICHSLIDES_SMARTFILL_REPLAY_ASSET_IDS_PATH",
            in: environment
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pathValue, !pathValue.isEmpty {
            let text = try String(contentsOfFile: pathValue, encoding: .utf8)
            let ids = parseAssetIDReplayList(text)
            guard !ids.isEmpty else {
                throw NSError(
                    domain: "PlaybackPoolResolver.assetIDReplay",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "asset-id replay lock is empty"]
                )
            }
            return PlaybackAssetIDReplayConfiguration(
                orderedAssetIDs: ids,
                source: pathValue
            )
        }

        let inlineValue = environmentValue(
            "IMMICHSLIDES_SMARTFILL_REPLAY_ASSET_IDS",
            in: environment
        )
        guard let inlineValue,
            !inlineValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        let ids = parseAssetIDReplayList(inlineValue)
        guard !ids.isEmpty else { return nil }
        return PlaybackAssetIDReplayConfiguration(
            orderedAssetIDs: ids,
            source: "inline"
        )
    }

    static func parseAssetIDReplayList(_ text: String) -> [String] {
        var ids: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if let value = replayValue(from: line) {
                ids.append(contentsOf: splitReplayAssetIDs(value))
            } else if !line.contains("=") {
                ids.append(contentsOf: splitReplayAssetIDs(line))
            }
        }
        if ids.isEmpty {
            ids = splitReplayAssetIDs(text)
        }
        return ids
    }

    private static func environmentValue(
        _ key: String,
        in environment: [String: String]
    ) -> String? {
        environment[key] ?? environment["TEST_RUNNER_\(key)"]
    }

    private static func replayValue(from line: String) -> String? {
        let keys = [
            "replayAssetIds",
            "replayAssetIDs",
            "orderedAssetIds",
            "orderedAssetIDs",
            "assetIds",
            "assetIDs"
        ]
        guard let equalIndex = line.firstIndex(of: "=") else { return nil }
        let key = String(line[..<equalIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard keys.contains(key) else { return nil }
        return String(line[line.index(after: equalIndex)...])
    }

    private static func splitReplayAssetIDs(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ", \n\t\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func stablePlaybackHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }

    private func resolveStrictSoloAssets(
        personId: String,
        desiredQualifiedCount: Int,
        excludingAssetIds: Set<String> = []
    ) async throws -> StrictSoloResolveResult {
        guard desiredQualifiedCount > 0 else {
            return StrictSoloResolveResult(
                assets: [],
                diagnostics: PlaybackPoolResolveDiagnostics()
            )
        }

        func fetchBatchSize(for remainingNeeded: Int) -> Int {
            min(12, max(8, remainingNeeded * 2))
        }

        var acceptedAssets: [Asset] = []
        var seenAssetIds = excludingAssetIds
        var diagnostics = PlaybackPoolResolveDiagnostics()
        #if DEBUG
        let resolveStartedAt = Self.debugUptime()
        var currentDebugStage = "resolve"
        #endif

        let maxRounds = max(3, min(6, desiredQualifiedCount / 4 + 1))

        #if DEBUG
        await emitPlaybackSequenceDebugEvent(
            .strictSoloResolveBegin(
                desiredCount: desiredQualifiedCount,
                excludedCount: excludingAssetIds.count
            ))
        #endif

        do {
            for roundIndex in 1...maxRounds {
                if acceptedAssets.count >= desiredQualifiedCount {
                    break
                }

                let remainingNeeded = desiredQualifiedCount - acceptedAssets.count
                let fetchSize = fetchBatchSize(for: remainingNeeded)
                logger.info(
                    "strict solo round begin personId=\(personId, privacy: .private) round=\(roundIndex, privacy: .public) maxRounds=\(maxRounds, privacy: .public) remainingNeeded=\(remainingNeeded, privacy: .public) fetchSize=\(fetchSize, privacy: .public) excludedCount=\(excludingAssetIds.count, privacy: .public)"
                )
                #if DEBUG
                currentDebugStage = "random"
                await emitPlaybackSequenceDebugEvent(
                    .strictSoloRandomBegin(
                        batchNumber: roundIndex,
                        fetchSize: fetchSize,
                        accumulatedResultCount: acceptedAssets.count
                    ))
                let randomStartedAt = Self.debugUptime()
                #endif
                let candidates = try await fetchRandomAsset(
                    size: fetchSize,
                    albumIds: nil,
                    personIds: [personId]
                )
                #if DEBUG
                await emitPlaybackSequenceDebugEvent(
                    .strictSoloRandomEnd(
                        batchNumber: roundIndex,
                        randomReturnedCount: candidates.count,
                        durationMs: Self.debugDurationMs(since: randomStartedAt)
                    ))
                #endif
                diagnostics.soloFetchedCandidateCount += candidates.count

                #if DEBUG
                currentDebugStage = "localFilter"
                let localFilterStartedAt = Self.debugUptime()
                #endif
                let locallyQualifiedCandidates = locallyQualifiedSoloAssets(
                    from: candidates,
                    personId: personId
                ).filter { asset in
                    seenAssetIds.insert(asset.id).inserted
                }
                #if DEBUG
                await emitPlaybackSequenceDebugEvent(
                    .strictSoloLocalFilterEnd(
                        batchNumber: roundIndex,
                        randomReturnedCount: candidates.count,
                        afterExclusionCount: locallyQualifiedCandidates.count,
                        durationMs: Self.debugDurationMs(since: localFilterStartedAt)
                    ))
                #endif
                diagnostics.soloLocalQualifiedCandidateCount += locallyQualifiedCandidates.count
                logger.info(
                    "strict solo round candidates personId=\(personId, privacy: .private) round=\(roundIndex, privacy: .public) fetchedCount=\(candidates.count, privacy: .public) localQualifiedCount=\(locallyQualifiedCandidates.count, privacy: .public) seenCount=\(seenAssetIds.count, privacy: .public) excludedCount=\(excludingAssetIds.count, privacy: .public)"
                )

                if locallyQualifiedCandidates.isEmpty {
                    #if DEBUG
                    recordStrictSoloDebugBatch(
                        batchNumber: roundIndex,
                        randomReturnedCount: candidates.count,
                        afterExclusionCount: locallyQualifiedCandidates.count,
                        visionApprovedCount: 0,
                        accumulatedResultCount: acceptedAssets.count
                    )
                    #endif
                    continue
                }

                let acceptedBeforeVision = acceptedAssets.count
                #if DEBUG
                currentDebugStage = "vision"
                await emitPlaybackSequenceDebugEvent(
                    .strictSoloVisionBegin(
                        batchNumber: roundIndex,
                        candidateCount: locallyQualifiedCandidates.count,
                        acceptedLimit: remainingNeeded,
                        accumulatedResultCount: acceptedAssets.count
                    ))
                let visionStartedAt = Self.debugUptime()
                #endif
                let visionResult = await soloApprovalResult(
                    from: locallyQualifiedCandidates,
                    acceptedLimit: remainingNeeded
                )
                diagnostics.merge(visionResult)

                acceptedAssets.append(contentsOf: visionResult.approvedAssets)
                let acceptedDelta = acceptedAssets.count - acceptedBeforeVision
                #if DEBUG
                await emitPlaybackSequenceDebugEvent(
                    .strictSoloVisionEnd(
                        batchNumber: roundIndex,
                        visionApprovedCount: visionResult.approvedAssets.count,
                        durationMs: Self.debugDurationMs(since: visionStartedAt),
                        accumulatedResultCount: acceptedAssets.count
                    ))
                recordStrictSoloDebugBatch(
                    batchNumber: roundIndex,
                    randomReturnedCount: candidates.count,
                    afterExclusionCount: locallyQualifiedCandidates.count,
                    visionApprovedCount: visionResult.approvedAssets.count,
                    accumulatedResultCount: acceptedAssets.count
                )
                #endif
                logger.info(
                    "strict solo round vision end personId=\(personId, privacy: .private) round=\(roundIndex, privacy: .public) visionAcceptedDelta=\(acceptedDelta, privacy: .public) totalAccepted=\(acceptedAssets.count, privacy: .public) desired=\(desiredQualifiedCount, privacy: .public)"
                )
            }

            #if DEBUG
            await emitPlaybackSequenceDebugEvent(
                .strictSoloResolveEnd(
                    desiredCount: desiredQualifiedCount,
                    returnedCount: acceptedAssets.count,
                    durationMs: Self.debugDurationMs(since: resolveStartedAt)
                ))
            #endif
        } catch {
            #if DEBUG
            await emitPlaybackSequenceDebugEvent(
                .strictSoloResolveFailure(
                    stageName: currentDebugStage,
                    errorKind: Self.debugErrorKind(error)
                ))
            #endif
            throw error
        }

        logger.info(
            "strict solo end personId=\(personId, privacy: .private) acceptedCount=\(acceptedAssets.count, privacy: .public) desired=\(desiredQualifiedCount, privacy: .public) maxRounds=\(maxRounds, privacy: .public) excludedCount=\(excludingAssetIds.count, privacy: .public)"
        )
        return StrictSoloResolveResult(
            assets: acceptedAssets,
            diagnostics: diagnostics
        )
    }

    private func locallyQualifiedSoloAssets(
        from candidates: [Asset],
        personId: String
    ) -> [Asset] {
        candidates.filter { asset in
            guard let people = asset.people else { return false }
            guard people.count == 1 else { return false }
            guard asset.unassignedFaces?.isEmpty ?? true else { return false }
            return personId == people[0].id
        }
    }

    // The cooling pool evicts by recent use; an existing ID moves to the end of the queue.

    private func updateCoolingPool(with assets: [Asset], poolSize: Int) {
        guard poolSize > 0 else { return }

        for asset in assets {
            let id = asset.id
            if recentlyPlayedIds.contains(id) {

                if let oldIndex = recentlyPlayedQueue.firstIndex(of: id) {
                    recentlyPlayedQueue.remove(at: oldIndex)
                }
            } else {
                recentlyPlayedIds.insert(id)
            }
            recentlyPlayedQueue.append(id)
        }

        while recentlyPlayedQueue.count > poolSize {
            let removedId = recentlyPlayedQueue.removeFirst()
            recentlyPlayedIds.remove(removedId)
        }
    }

    #if DEBUG
    private func emitPlaybackSequenceDebugEvent(_ event: PlaybackSequenceDebugEventInput) async {
        guard let playbackSequenceDebugEventSink else { return }
        await MainActor.run {
            playbackSequenceDebugEventSink(event)
        }
    }

    private func recordStrictSoloDebugBatch(
        batchNumber: Int,
        randomReturnedCount: Int,
        afterExclusionCount: Int,
        visionApprovedCount: Int,
        accumulatedResultCount: Int
    ) {
        strictSoloDebugEventsForTesting.append(
            .strictSoloBatch(
                batchNumber: batchNumber,
                randomReturnedCount: randomReturnedCount,
                afterExclusionCount: afterExclusionCount,
                visionApprovedCount: visionApprovedCount,
                accumulatedResultCount: accumulatedResultCount
            ))
    }

    private static func debugUptime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private static func debugDurationMs(since start: TimeInterval) -> Int {
        max(0, Int(((debugUptime() - start) * 1_000).rounded()))
    }

    private static func debugErrorKind(_ error: any Error) -> String {
        if error is CancellationError {
            return "cancelled"
        }
        return "failure"
    }
    #endif
}
