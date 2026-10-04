//
//  PlaybackImageRequestLifecycleDiagnostics.swift
//  immichSlides
//
//  Playback image request lifecycle diagnostics, used only for DEBUG / UI test performance attribution.
//

#if DEBUG
import CryptoKit
import Foundation
import SDWebImage

enum PlaybackImageRequestLifecycleSource: String, Codable, CaseIterable, Equatable {
    case assetManagerLoadPhoto
    case rendererSingleFullsize
    case rendererSingleBackground
    case rendererSmartFillSlot
    case unknown
}

enum PlaybackImageRequestLifecycleCacheResult: String, Codable, Equatable {
    case memory
    case disk
    case miss
    case unknown

    init(sdImageCacheType: SDImageCacheType) {
        switch sdImageCacheType {
        case .memory:
            self = .memory
        case .disk:
            self = .disk
        case .none:
            self = .miss
        case .all:
            // `.all` only says several cache layers were checked; it does not prove the decoded image is in memory.
            self = .unknown
        @unknown default:
            self = .unknown
        }
    }
}

enum PlaybackImageRequestLifecycleMode: String, Codable, Equatable {
    case single
    case smartfill
    case unknown
}

enum PlaybackImageRequestLifecycleRole: String, Codable, Equatable {
    case current
    case incoming
    case outgoing
    case previous
    case next
    case unknown
}

enum PlaybackImageRequestLifecycleMemoryHitSemantics: String, Codable, Equatable {
    case verifiedByMemoryCacheQuery
    case unverified
}

/// Read-only snapshot: only counts whether ready URLs are persisted to disk.

struct PlaybackImageCachePersistenceSnapshot: Codable, Equatable {
    let schemaVersion = "playback-image-cache-persistence-snapshot-v1"
    let checkSequence: Int
    let activeTaskCount: Int
    let readyFullsizeCount: Int
    let diskReadyFullsizeCount: Int
    let readyPreviewCount: Int
    let diskReadyPreviewCount: Int
    let missingReadyFullsizeCount: Int
    let missingReadyPreviewCount: Int
    let isPersisted: Bool

    // Keep the fixed schema in encoded evidence while decoding continues to ignore its input value.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case checkSequence
        case activeTaskCount
        case readyFullsizeCount
        case diskReadyFullsizeCount
        case readyPreviewCount
        case diskReadyPreviewCount
        case missingReadyFullsizeCount
        case missingReadyPreviewCount
        case isPersisted
    }

    init(
        checkSequence: Int,
        activeTaskCount: Int,
        readyFullsizeCount: Int,
        diskReadyFullsizeCount: Int,
        readyPreviewCount: Int,
        diskReadyPreviewCount: Int
    ) {
        self.checkSequence = checkSequence
        self.activeTaskCount = activeTaskCount
        self.readyFullsizeCount = readyFullsizeCount
        self.diskReadyFullsizeCount = diskReadyFullsizeCount
        self.readyPreviewCount = readyPreviewCount
        self.diskReadyPreviewCount = diskReadyPreviewCount
        missingReadyFullsizeCount = max(0, readyFullsizeCount - diskReadyFullsizeCount)
        missingReadyPreviewCount = max(0, readyPreviewCount - diskReadyPreviewCount)
        isPersisted =
            activeTaskCount == 0 && readyFullsizeCount + readyPreviewCount > 0 && missingReadyFullsizeCount == 0
            && missingReadyPreviewCount == 0
    }
}

enum PlaybackImageRequestLifecycleEvent: Equatable {
    case requestStarted(
        requestId: String,
        source: PlaybackImageRequestLifecycleSource,
        assetId: String,
        size: ThumbnailSize,
        mode: PlaybackImageRequestLifecycleMode,
        role: PlaybackImageRequestLifecycleRole,
        cacheKeyHash: String,
        contextHash: String,
        navigationToken: UUID,
        sceneId: String,
        timestamp: TimeInterval
    )
    case cacheKeyResolved(
        requestId: String,
        sdDiskCacheFileNameHash: String,
        timestamp: TimeInterval
    )
    case rendererCacheKeyResolved(
        requestId: String,
        sdDiskCacheFileNameHash: String,
        cacheResult: PlaybackImageRequestLifecycleCacheResult,
        timestamp: TimeInterval
    )
    case prePlaybackFilterSummaryTransitionWriter(
        assetIdentityHash: String,
        requestIdentityHash: String,
        logicalIdentityHash: String,
        urlPathIdentityHash: String,
        fullURLIdentityHash: String,
        sdDiskCacheFileNameHash: String,
        cacheResult: PlaybackImageRequestLifecycleCacheResult,
        timestamp: TimeInterval
    )
    case cacheChecked(
        requestId: String,
        result: PlaybackImageRequestLifecycleCacheResult,
        timestamp: TimeInterval
    )
    case inFlightReused(
        requestId: String,
        reusedRequestId: String,
        timestamp: TimeInterval
    )
    case loadEntered(
        requestId: String,
        timestamp: TimeInterval
    )
    case loadFinished(
        requestId: String,
        cacheResult: PlaybackImageRequestLifecycleCacheResult,
        imagePixelWidth: Int?,
        imagePixelHeight: Int?,
        timestamp: TimeInterval
    )
    case canceled(
        requestId: String,
        timestamp: TimeInterval
    )
    case consumed(
        requestId: String,
        timestamp: TimeInterval
    )
}

struct PlaybackImageRequestLifecycleCounter: Codable, Equatable {
    var requestCount: Int = 0
    var uniqueRequestKeyCount: Int = 0
    var duplicateRequestCount: Int = 0
    var inFlightReusedCount: Int = 0
    var memoryHitCount: Int = 0
    var diskHitCount: Int = 0
    var missCount: Int = 0
    var unknownCacheCount: Int = 0
    var loadEnteredCount: Int = 0
    var finishedCount: Int = 0
    var canceledCount: Int = 0
    var lateResultCount: Int = 0
    var consumedCount: Int = 0
    var wastedDecodeCandidateCount: Int = 0

    mutating func addCacheCounts(from other: PlaybackImageRequestLifecycleCounter) {
        memoryHitCount += other.memoryHitCount
        diskHitCount += other.diskHitCount
        missCount += other.missCount
        unknownCacheCount += other.unknownCacheCount
    }
}

struct PlaybackImageRequestLifecycleLatencyStats: Codable, Equatable {
    var count: Int = 0
    var p50Milliseconds: Double = 0
    var p95Milliseconds: Double = 0
    var maxMilliseconds: Double = 0
}

enum PlaybackImageRequestLifecycleLatencyGateStatus: String, Codable, Equatable {
    case pass = "PASS"
    case fail = "FAIL"
    case insufficientSamples = "INSUFFICIENT_SAMPLES"
}

struct PlaybackImageRequestLifecycleLatencyGateEvaluation: Codable, Equatable {
    var status: PlaybackImageRequestLifecycleLatencyGateStatus
    var baseCount: Int
    var candidateCount: Int
    var baseP95Milliseconds: Double
    var candidateP95Milliseconds: Double
    var deltaPercent: Double?

    var triggersHardStop: Bool {
        status == .fail
    }
}

struct PlaybackImageRequestLifecycleLatencyGate {
    static let minimumComparableSampleCount = 20
    static let p95RegressionHardStopThresholdPercent = 10.0

    static func evaluate(
        base: PlaybackImageRequestLifecycleLatencyStats,
        candidate: PlaybackImageRequestLifecycleLatencyStats
    ) -> PlaybackImageRequestLifecycleLatencyGateEvaluation {
        let deltaPercent = roundedDeltaPercent(
            baseP95Milliseconds: base.p95Milliseconds,
            candidateP95Milliseconds: candidate.p95Milliseconds
        )
        let status: PlaybackImageRequestLifecycleLatencyGateStatus
        if base.count < minimumComparableSampleCount || candidate.count < minimumComparableSampleCount {
            status = .insufficientSamples
        } else if let deltaPercent,
            deltaPercent > p95RegressionHardStopThresholdPercent
        {
            status = .fail
        } else {
            status = .pass
        }

        return PlaybackImageRequestLifecycleLatencyGateEvaluation(
            status: status,
            baseCount: base.count,
            candidateCount: candidate.count,
            baseP95Milliseconds: base.p95Milliseconds,
            candidateP95Milliseconds: candidate.p95Milliseconds,
            deltaPercent: deltaPercent
        )
    }

    private static func roundedDeltaPercent(
        baseP95Milliseconds: Double,
        candidateP95Milliseconds: Double
    ) -> Double? {
        guard baseP95Milliseconds > 0 else { return nil }
        let delta = ((candidateP95Milliseconds - baseP95Milliseconds) / baseP95Milliseconds) * 100
        return (delta * 10).rounded() / 10
    }
}

struct PlaybackImageRequestLifecycleLatencySummary: Codable, Equatable {
    var requestToConsumedByRole: [String: PlaybackImageRequestLifecycleLatencyStats] = [:]
    var requestToConsumedBySource: [String: PlaybackImageRequestLifecycleLatencyStats] = [:]
    var loadEnteredToFinishedByRole: [String: PlaybackImageRequestLifecycleLatencyStats] = [:]
    var loadEnteredToFinishedBySource: [String: PlaybackImageRequestLifecycleLatencyStats] = [:]
}

struct PlaybackImageRequestLifecycleSummary: Codable, Equatable {
    var schemaVersion = "playback-image-request-lifecycle-summary-v1"
    var total = PlaybackImageRequestLifecycleCounter()
    var countersBySource: [String: PlaybackImageRequestLifecycleCounter] = [:]
    var latency = PlaybackImageRequestLifecycleLatencySummary()
    var evidenceFlushCount: Int = 0
    var unknownSourceRatio: Double = 0
    var memoryHitSemantics: PlaybackImageRequestLifecycleMemoryHitSemantics = .verifiedByMemoryCacheQuery

    func counter(for source: PlaybackImageRequestLifecycleSource) -> PlaybackImageRequestLifecycleCounter {
        countersBySource[source.rawValue] ?? PlaybackImageRequestLifecycleCounter()
    }
}

struct PlaybackImageRequestLifecycleDiagnostics {
    nonisolated static let environmentFlag = "IMMICHSLIDES_PLAYBACK_CPU_DIAGNOSTICS"

    private struct RequestKey: Hashable {
        let source: PlaybackImageRequestLifecycleSource
        let assetId: String
        let size: ThumbnailSize
        let cacheKeyHash: String
        let contextHash: String
    }

    private struct RequestRecord: Equatable {
        let requestId: String
        let source: PlaybackImageRequestLifecycleSource
        let assetId: String
        let size: ThumbnailSize
        let mode: PlaybackImageRequestLifecycleMode
        let role: PlaybackImageRequestLifecycleRole
        let cacheKeyHash: String
        let contextHash: String
        let navigationToken: UUID
        let sceneId: String
        let startedAt: TimeInterval
        var cacheResult: PlaybackImageRequestLifecycleCacheResult = .unknown
        var didCheckCache = false
        var didReuseInFlight = false
        var didEnterLoad = false
        var didFinish = false
        var didCancel = false
        var didConsume = false
        var isLateResult = false
        var loadEnteredAt: TimeInterval?
        var loadFinishedAt: TimeInterval?
        var consumedAt: TimeInterval?
        var imagePixelWidth: Int?
        var imagePixelHeight: Int?

        var key: RequestKey {
            RequestKey(
                source: source,
                assetId: assetId,
                size: size,
                cacheKeyHash: cacheKeyHash,
                contextHash: contextHash
            )
        }
    }

    let isEnabled: Bool
    private let evidenceDirectory: URL?
    private var records: [String: RequestRecord] = [:]
    private var requestOrder: [String] = []
    private var orphanCacheCounter = PlaybackImageRequestLifecycleCounter()
    private var eventFileHandle: FileHandle?
    private var evidenceFlushCount = 0

    init(
        isEnabled: Bool = PlaybackImageRequestLifecycleDiagnostics.isEnabledInEnvironment(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.isEnabled = isEnabled
        if isEnabled,
            let evidenceDirectoryPath = environment["UI_TEST_EVIDENCE_DIR"],
            !evidenceDirectoryPath.isEmpty
        {
            self.evidenceDirectory = URL(fileURLWithPath: evidenceDirectoryPath, isDirectory: true)
        } else {
            self.evidenceDirectory = nil
        }
    }

    nonisolated static func isEnabledInEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[environmentFlag] == "1"
    }

    nonisolated static func redactedHash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Reduces the logical resource identity of a filter summary image to its URL without query/fragment;
    /// returns only an irreversible short hash.
    nonisolated static func filterSummaryLogicalIdentityHash(url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        let normalizedScheme = components?.scheme?.lowercased()
        let normalizedHost = components?.host?.lowercased()
        components?.scheme = normalizedScheme
        components?.host = normalizedHost
        return redactedHash(components?.string ?? url.absoluteString)
    }

    /// Redacts the path part on its own, to tell a logical resource switch from a query/signature change;
    /// the raw path is never persisted.
    nonisolated static func filterSummaryURLPathIdentityHash(url: URL) -> String {
        let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
        return redactedHash(encodedPath.flatMap { $0.isEmpty ? nil : $0 } ?? url.path)
    }

    /// Keeps only an irreversible short hash of the full URL, for auditing signature or query churn.
    nonisolated static func filterSummaryFullURLIdentityHash(url: URL) -> String {
        redactedHash(url.absoluteString)
    }

    /// Extracts the resource segment from the actual filter summary request URL and redacts it right away;
    /// the raw asset ID is never persisted.
    nonisolated static func filterSummaryAssetIdentityHash(url: URL) -> String {
        let components = url.pathComponents.filter { $0 != "/" }
        if let assetsIndex = components.firstIndex(of: "assets"),
            components.indices.contains(components.index(after: assetsIndex))
        {
            return redactedHash(components[components.index(after: assetsIndex)])
        }
        return filterSummaryLogicalIdentityHash(url: url)
    }

    /// Combines the request key resolved by the actual manager/context with the resource identity and redacts
    /// it again; only used for DEBUG evidence.
    nonisolated static func filterSummaryRequestIdentityHash(
        url: URL,
        manager: SDWebImageManager = .shared,
        context: [SDWebImageContextOption: Any]? = nil
    ) -> String {
        let cacheKey = manager.cacheKey(for: url, context: context) ?? url.absoluteString
        let assetIdentityHash = filterSummaryAssetIdentityHash(url: url)
        return redactedHash("\(assetIdentityHash)|\(redactedHash(cacheKey))")
    }

    /// Records an irreversible file name hash of the SDK's actual disk key, only in DEBUG lifecycle evidence,
    /// so no URL or credential is exposed.
    nonisolated static func effectiveSDDiskCacheFileNameHash(
        url: URL,
        manager: SDWebImageManager = .shared,
        context: [SDWebImageContextOption: Any]? = nil
    ) -> String {
        let cacheKey = manager.cacheKey(for: url, context: context) ?? url.absoluteString
        guard let imageCache = manager.imageCache as? SDImageCache,
            let cachePath = imageCache.cachePath(forKey: cacheKey)
        else {
            // When the path is unavailable, still keep only a redacted value; never write the runtime cache key or URL
            // into evidence.
            return redactedHash(cacheKey)
        }
        return URL(fileURLWithPath: cachePath)
            .deletingPathExtension()
            .lastPathComponent
    }

    /// Diagnostics must use the same effective context as WebImage loadImage.

    nonisolated static func rendererEffectiveWebImageContext(
        _ context: [SDWebImageContextOption: Any]
    ) -> [SDWebImageContextOption: Any] {
        var effectiveContext = context
        if effectiveContext[.imageScaleFactor] == nil {
            effectiveContext[.imageScaleFactor] = 1
        }
        if effectiveContext[.animatedImageClass] == nil {
            effectiveContext[.animatedImageClass] = SDAnimatedImage.self
        }
        return effectiveContext
    }

    mutating func record(_ event: PlaybackImageRequestLifecycleEvent) {
        guard isEnabled else { return }

        switch event {
        case let .requestStarted(
            requestId,
            source,
            assetId,
            size,
            mode,
            role,
            cacheKeyHash,
            contextHash,
            navigationToken,
            sceneId,
            timestamp
        ):
            records[requestId] = RequestRecord(
                requestId: requestId,
                source: source,
                assetId: assetId,
                size: size,
                mode: mode,
                role: role,
                cacheKeyHash: cacheKeyHash,
                contextHash: contextHash,
                navigationToken: navigationToken,
                sceneId: sceneId,
                startedAt: timestamp
            )
            requestOrder.append(requestId)

        case let .cacheChecked(requestId, result, _):
            if var record = records[requestId] {
                record.cacheResult = result
                record.didCheckCache = true
                records[requestId] = record
            } else {
                incrementOrphanCacheCounter(for: result)
            }

        case .cacheKeyResolved, .rendererCacheKeyResolved, .prePlaybackFilterSummaryTransitionWriter:
            break

        case let .inFlightReused(requestId, _, _):
            records[requestId]?.didReuseInFlight = true

        case let .loadEntered(requestId, timestamp):
            records[requestId]?.didEnterLoad = true
            records[requestId]?.loadEnteredAt = timestamp

        case let .loadFinished(requestId, cacheResult, imagePixelWidth, imagePixelHeight, timestamp):
            records[requestId]?.cacheResult = cacheResult
            records[requestId]?.didFinish = true
            records[requestId]?.loadFinishedAt = timestamp
            records[requestId]?.imagePixelWidth = imagePixelWidth
            records[requestId]?.imagePixelHeight = imagePixelHeight

        case let .canceled(requestId, _):
            records[requestId]?.didCancel = true

        case let .consumed(requestId, timestamp):
            records[requestId]?.didConsume = true
            records[requestId]?.consumedAt = timestamp
        }

        appendEventToEvidenceIfNeeded(event)
    }

    mutating func markLateResults(currentNavigationToken: UUID) {
        guard isEnabled else { return }
        for requestId in requestOrder {
            guard var record = records[requestId],
                record.didFinish,
                record.navigationToken != currentNavigationToken
            else { continue }
            record.isLateResult = true
            records[requestId] = record
        }
    }

    mutating func flushPlaybackImageRequestLifecycleEvidence() {
        guard isEnabled else { return }
        evidenceFlushCount += 1
        closeEventFileHandle()
        writeSummaryToEvidenceIfNeeded()
    }

    func makeSummary() -> PlaybackImageRequestLifecycleSummary {
        guard isEnabled else { return PlaybackImageRequestLifecycleSummary() }

        let orderedRecords = requestOrder.compactMap { records[$0] }
        var summary = PlaybackImageRequestLifecycleSummary()
        summary.evidenceFlushCount = evidenceFlushCount
        summary.total = makeCounter(for: orderedRecords, shouldIncludeRecordCacheResults: true)
        summary.total.addCacheCounts(from: orphanCacheCounter)

        for source in PlaybackImageRequestLifecycleSource.allCases {
            summary.countersBySource[source.rawValue] = makeCounter(
                for: orderedRecords.filter { $0.source == source },
                shouldIncludeRecordCacheResults: true
            )
        }
        summary.latency = makeLatencySummary(for: orderedRecords)

        if summary.total.requestCount > 0 {
            summary.unknownSourceRatio =
                Double(summary.counter(for: .unknown).requestCount) / Double(summary.total.requestCount)
        }
        return summary
    }

    private mutating func incrementOrphanCacheCounter(for result: PlaybackImageRequestLifecycleCacheResult) {
        switch result {
        case .memory:
            orphanCacheCounter.memoryHitCount += 1
        case .disk:
            orphanCacheCounter.diskHitCount += 1
        case .miss:
            orphanCacheCounter.missCount += 1
        case .unknown:
            orphanCacheCounter.unknownCacheCount += 1
        }
    }

    private func makeCounter(
        for records: [RequestRecord],
        shouldIncludeRecordCacheResults: Bool
    ) -> PlaybackImageRequestLifecycleCounter {
        let keyCounts = Dictionary(grouping: records, by: \.key).mapValues(\.count)
        var counter = PlaybackImageRequestLifecycleCounter()
        counter.requestCount = records.count
        counter.uniqueRequestKeyCount = keyCounts.count
        counter.duplicateRequestCount = keyCounts.values.reduce(0) { total, count in
            total + max(0, count - 1)
        }
        counter.inFlightReusedCount = records.filter(\.didReuseInFlight).count
        if shouldIncludeRecordCacheResults {
            let cacheResolvedRecords = records.filter { record in
                record.didCheckCache || record.didFinish
            }
            counter.memoryHitCount = cacheResolvedRecords.filter { $0.cacheResult == .memory }.count
            counter.diskHitCount = cacheResolvedRecords.filter { $0.cacheResult == .disk }.count
            counter.missCount = cacheResolvedRecords.filter { $0.cacheResult == .miss }.count
            counter.unknownCacheCount = cacheResolvedRecords.filter { $0.cacheResult == .unknown }.count
        }
        counter.loadEnteredCount = records.filter(\.didEnterLoad).count
        counter.finishedCount = records.filter(\.didFinish).count
        counter.canceledCount = records.filter(\.didCancel).count
        counter.lateResultCount = records.filter(\.isLateResult).count
        counter.consumedCount = records.filter(\.didConsume).count
        counter.wastedDecodeCandidateCount =
            records.filter { record in
                record.didFinish && !record.didConsume
            }.count
        return counter
    }

    private func makeLatencySummary(
        for records: [RequestRecord]
    ) -> PlaybackImageRequestLifecycleLatencySummary {
        var summary = PlaybackImageRequestLifecycleLatencySummary()
        summary.requestToConsumedByRole = makeLatencyStatsByRole(
            records: records,
            duration: { record in
                guard let consumedAt = record.consumedAt else { return nil }
                return consumedAt - record.startedAt
            }
        )
        summary.requestToConsumedBySource = makeLatencyStatsBySource(
            records: records,
            duration: { record in
                guard let consumedAt = record.consumedAt else { return nil }
                return consumedAt - record.startedAt
            }
        )
        summary.loadEnteredToFinishedByRole = makeLatencyStatsByRole(
            records: records,
            duration: { record in
                guard let loadEnteredAt = record.loadEnteredAt,
                    let loadFinishedAt = record.loadFinishedAt
                else { return nil }
                return loadFinishedAt - loadEnteredAt
            }
        )
        summary.loadEnteredToFinishedBySource = makeLatencyStatsBySource(
            records: records,
            duration: { record in
                guard let loadEnteredAt = record.loadEnteredAt,
                    let loadFinishedAt = record.loadFinishedAt
                else { return nil }
                return loadFinishedAt - loadEnteredAt
            }
        )
        return summary
    }

    private func makeLatencyStatsByRole(
        records: [RequestRecord],
        duration: (RequestRecord) -> TimeInterval?
    ) -> [String: PlaybackImageRequestLifecycleLatencyStats] {
        Dictionary(grouping: records, by: { $0.role.rawValue }).compactMapValues { groupedRecords in
            makeLatencyStats(from: groupedRecords.compactMap(duration))
        }
    }

    private func makeLatencyStatsBySource(
        records: [RequestRecord],
        duration: (RequestRecord) -> TimeInterval?
    ) -> [String: PlaybackImageRequestLifecycleLatencyStats] {
        Dictionary(grouping: records, by: { $0.source.rawValue }).compactMapValues { groupedRecords in
            makeLatencyStats(from: groupedRecords.compactMap(duration))
        }
    }

    private func makeLatencyStats(
        from durations: [TimeInterval]
    ) -> PlaybackImageRequestLifecycleLatencyStats? {
        let milliseconds =
            durations
            .filter { $0 >= 0 }
            .map { ($0 * 1000).rounded() }
            .sorted()
        guard !milliseconds.isEmpty else { return nil }
        return PlaybackImageRequestLifecycleLatencyStats(
            count: milliseconds.count,
            p50Milliseconds: percentile(milliseconds, 0.50),
            p95Milliseconds: percentile(milliseconds, 0.95),
            maxMilliseconds: milliseconds[milliseconds.count - 1]
        )
    }

    private func percentile(_ sortedValues: [Double], _ percentile: Double) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let rawIndex = Int(ceil(percentile * Double(sortedValues.count))) - 1
        let clampedIndex = min(max(rawIndex, 0), sortedValues.count - 1)
        return sortedValues[clampedIndex]
    }

    private mutating func appendEventToEvidenceIfNeeded(_ event: PlaybackImageRequestLifecycleEvent) {
        guard let evidenceDirectory else { return }
        do {
            try FileManager.default.createDirectory(
                at: evidenceDirectory,
                withIntermediateDirectories: true
            )
            var object = eventJSONDictionary(event)
            object["schemaVersion"] = "playback-image-request-lifecycle-event-v1"
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let fileURL = evidenceDirectory.appending(path: "playback-request-lifecycle-events.jsonl")
            let line = data + Data("\n".utf8)
            if eventFileHandle == nil {
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }
                eventFileHandle = try FileHandle(forWritingTo: fileURL)
                try eventFileHandle?.seekToEnd()
            }
            try eventFileHandle?.write(contentsOf: line)
        } catch {
            // A failed diagnostic write must not affect playback; the gap is recorded as unverified.
            closeEventFileHandle()
        }
    }

    private mutating func closeEventFileHandle() {
        do {
            try eventFileHandle?.synchronize()
            try eventFileHandle?.close()
        } catch {
            // A failure to close the diagnostic file must not affect playback.
        }
        eventFileHandle = nil
    }

    private func writeSummaryToEvidenceIfNeeded() {
        guard let evidenceDirectory else { return }
        do {
            try FileManager.default.createDirectory(
                at: evidenceDirectory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(makeSummary())
            try data.write(
                to: evidenceDirectory.appending(path: "playback-request-lifecycle-summary.json"),
                options: .atomic
            )
        } catch {
            // A failed diagnostic write must not affect playback.
        }
    }

    private func eventJSONDictionary(_ event: PlaybackImageRequestLifecycleEvent) -> [String: Any] {
        switch event {
        case let .requestStarted(
            requestId,
            source,
            assetId,
            size,
            mode,
            role,
            cacheKeyHash,
            contextHash,
            navigationToken,
            sceneId,
            timestamp
        ):
            return [
                "event": "requestStarted",
                "requestId": requestId,
                "source": source.rawValue,
                "assetId": Self.redactedHash(assetId),
                "size": size.rawValue,
                "mode": mode.rawValue,
                "role": role.rawValue,
                "cacheKeyHash": cacheKeyHash,
                "contextHash": contextHash,
                "navigationToken": navigationToken.uuidString,
                "sceneId": Self.redactedHash(sceneId),
                "timestamp": timestamp
            ]
        case let .cacheKeyResolved(requestId, sdDiskCacheFileNameHash, timestamp):
            return [
                "event": "cacheKeyResolved",
                "requestId": requestId,
                "sdDiskCacheFileNameHash": sdDiskCacheFileNameHash,
                "timestamp": timestamp
            ]
        case let .rendererCacheKeyResolved(requestId, sdDiskCacheFileNameHash, cacheResult, timestamp):
            return [
                "event": "rendererCacheKeyResolved",
                "requestId": requestId,
                "sdDiskCacheFileNameHash": sdDiskCacheFileNameHash,
                "cacheResult": cacheResult.rawValue,
                "timestamp": timestamp
            ]
        case let .prePlaybackFilterSummaryTransitionWriter(
            assetIdentityHash,
            requestIdentityHash,
            logicalIdentityHash,
            urlPathIdentityHash,
            fullURLIdentityHash,
            sdDiskCacheFileNameHash,
            cacheResult,
            timestamp
        ):
            return [
                "event": "prePlaybackFilterSummaryTransitionWriter",
                "writerSource": "filterSummaryStageWebImageSuccess",
                "assetIdentityHash": assetIdentityHash,
                "requestIdentityHash": requestIdentityHash,
                "logicalIdentityHash": logicalIdentityHash,
                "urlPathIdentityHash": urlPathIdentityHash,
                "fullURLIdentityHash": fullURLIdentityHash,
                "effectiveDiskIdentityHash": sdDiskCacheFileNameHash,
                "sdDiskCacheFileNameHash": sdDiskCacheFileNameHash,
                "cacheResult": cacheResult.rawValue,
                "observedWriteAtEpochNanoseconds": Int64(timestamp * 1_000_000_000),
                "timestamp": timestamp
            ]
        case let .cacheChecked(requestId, result, timestamp):
            return [
                "event": "cacheChecked",
                "requestId": requestId,
                "result": result.rawValue,
                "timestamp": timestamp
            ]
        case let .inFlightReused(requestId, reusedRequestId, timestamp):
            return [
                "event": "inFlightReused",
                "requestId": requestId,
                "reusedRequestId": reusedRequestId,
                "timestamp": timestamp
            ]
        case let .loadEntered(requestId, timestamp):
            return [
                "event": "loadEntered",
                "requestId": requestId,
                "timestamp": timestamp
            ]
        case let .loadFinished(requestId, cacheResult, imagePixelWidth, imagePixelHeight, timestamp):
            var object: [String: Any] = [
                "event": "loadFinished",
                "requestId": requestId,
                "cacheResult": cacheResult.rawValue,
                "timestamp": timestamp
            ]
            if let imagePixelWidth {
                object["imagePixelWidth"] = imagePixelWidth
            }
            if let imagePixelHeight {
                object["imagePixelHeight"] = imagePixelHeight
            }
            return object
        case let .canceled(requestId, timestamp):
            return [
                "event": "canceled",
                "requestId": requestId,
                "timestamp": timestamp
            ]
        case let .consumed(requestId, timestamp):
            return [
                "event": "consumed",
                "requestId": requestId,
                "timestamp": timestamp
            ]
        }
    }
}
#endif
