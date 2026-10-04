import Foundation
import SDWebImage
import Combine
import OSLog

// SDWebImage callback bridge: the continuation resumes only once; cancelling the Task also cancels the operation.

nonisolated final class SDWebImageAsyncBridge<Output>: @unchecked Sendable {
    private let lock = NSLock()
    private let fallbackValue: Output
    private var continuation: CheckedContinuation<Output, Never>?
    private var operation: SDWebImageOperation?
    private var didResume = false
    private var shouldCancelOperation = false

    init(fallbackValue: Output) {
        self.fallbackValue = fallbackValue
    }

    func setContinuation(_ continuation: CheckedContinuation<Output, Never>) {
        let shouldResumeImmediately: Bool

        lock.lock()
        if didResume {
            shouldResumeImmediately = true
        } else {
            self.continuation = continuation
            shouldResumeImmediately = false
        }
        lock.unlock()

        if shouldResumeImmediately {
            continuation.resume(returning: fallbackValue)
        }
    }

    func setOperation(_ operation: SDWebImageOperation) {
        let shouldCancelImmediately: Bool

        lock.lock()
        if didResume || shouldCancelOperation {
            shouldCancelImmediately = true
        } else {
            self.operation = operation
            shouldCancelImmediately = false
        }
        lock.unlock()

        if shouldCancelImmediately {
            operation.cancel()
        }
    }

    func resume(returning value: Output, cancelOperation: Bool = false) {
        let continuationToResume: CheckedContinuation<Output, Never>?
        let operationToCancel: SDWebImageOperation?

        lock.lock()
        if didResume {
            if cancelOperation {
                shouldCancelOperation = true
                operationToCancel = operation
                operation = nil
            } else {
                operationToCancel = nil
            }
            continuationToResume = nil
            lock.unlock()
        } else {
            didResume = true
            shouldCancelOperation = cancelOperation
            continuationToResume = continuation
            continuation = nil
            operationToCancel = cancelOperation ? operation : nil
            operation = nil
            lock.unlock()
        }

        if cancelOperation {
            operationToCancel?.cancel()
        }
        continuationToResume?.resume(returning: value)
    }

    func cancelAndResume() {
        resume(returning: fallbackValue, cancelOperation: true)
    }
}

@MainActor
class AssetsDownloadManager: ObservableObject {
    struct CacheSummary {
        let diskBytes: UInt
        let trackedAssetURLCount: Int
        let trackedStateCount: Int
        let runningTaskCount: Int
    }

    struct PhotoLoadRuntimeRecord: Equatable {
        let phaseTimestamps: [String: TimeInterval]
        let cacheStatus: String
        let loadStatus: String
    }

    static let shared = AssetsDownloadManager()
    private static let maximumPreloadConcurrentDownloads: Int = 2
    private static let preloadLookBehindAssetCount: Int = 2

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "immichSlides",
        category: "AssetDownload"
    )

    @Published var assetStates: [String: AssetStates] = [:]

    @Published var assetPreviewStates: [String: AssetStates] = [:]

    @Published var assetThumbnailStates: [String: AssetStates] = [:]

    @Published var assetURLs: [String: URL] = [:]

    @Published var assetPreviewURLs: [String: URL] = [:]

    @Published var assetThumbnailURLs: [String: URL] = [:]
    // Settings observes activeTaskCount; the remaining metrics are overlay-only and take no part in business logic.
    @Published private(set) var activeTaskCount: Int = 0
    @Published private(set) var lastDownloadDuration: TimeInterval? = nil
    @Published private(set) var lastDownloadBytes: UInt = 0
    @Published private(set) var lastDownloadWasCacheHit: Bool = false

    // Separates the current/next photo (high) from preloading (low).
    enum DownloadPriority: Int {
        case low = 0
        case high = 1
    }

    private var runningTasks: [TaskKey: Task<Void, Never>] = [:]
    // The token tells whether a task is still the latest, so an old task cannot clean up a newer one.

    private var runningTaskTokens: [TaskKey: UUID] = [:]
    private var runningTaskPriorities: [TaskKey: DownloadPriority] = [:]
    // Task.cancel cannot stop the SDWebImage network request, so the operation is stored separately.

    private var runningOperations: [TaskKey: SDWebImageOperation] = [:]
    private var photoLoadRuntimeRecords: [TaskKey: PhotoLoadRuntimeRecordStorage] = [:]
    #if DEBUG
    private struct PlaybackImageRequestLifecycleDiagnosticContext {
        let mode: PlaybackImageRequestLifecycleMode
        let role: PlaybackImageRequestLifecycleRole
        let navigationToken: UUID
        let sceneId: String
    }

    private var playbackImageRequestLifecycleDiagnostics = PlaybackImageRequestLifecycleDiagnostics()
    private var runningLifecycleRequestIds: [TaskKey: String] = [:]
    private var latestLifecycleRequestIds: [TaskKey: String] = [:]
    private var playbackImageRequestLifecycleContexts: [TaskKey: PlaybackImageRequestLifecycleDiagnosticContext] = [:]
    private let usesLegacyPriorityUpgradeForRequestLifecycleDiagnostics: Bool
    #endif
    // Preload-only downloader: copied config, 2 concurrent, LIFO, so it does not take bandwidth from the current photo.
    private lazy var lowPriorityManager: SDWebImageManager = {
        let config =
            (SDWebImageDownloaderConfig.default.copy() as? SDWebImageDownloaderConfig) ?? SDWebImageDownloaderConfig()
        config.maxConcurrentDownloads = Self.maximumPreloadConcurrentDownloads
        config.executionOrder = .lifoExecutionOrder
        let downloader = SDWebImageDownloader(config: config)
        return SDWebImageManager(cache: SDImageCache.shared, loader: downloader)
    }()

    private struct TaskKey: Hashable {
        let assetId: String
        let size: ThumbnailSize
    }

    private struct PhotoLoadRuntimeRecordStorage {
        var phaseTimestamps: [String: TimeInterval] = [:]
        var cacheStatus: String = "unknown"
        var loadStatus: String = "pending"
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        #if DEBUG
        usesLegacyPriorityUpgradeForRequestLifecycleDiagnostics =
            environment["IMMICHSLIDES_PLAYBACK_REQUEST_LIFECYCLE_LEGACY_PRIORITY_UPGRADE"] == "1"
        #endif
        PlaybackImageCachePolicy.apply(to: SDImageCache.shared)
    }

    func findURL(assetId: String, size: ThumbnailSize) -> URL? {
        if let url = url(assetId: assetId, size: size) {
            return url
        }
        return nil
    }

    func isReady(assetId: String, size: ThumbnailSize) -> Bool {
        if let state = state(assetId: assetId, size: size) {
            switch state {
            case .readyToPlay:
                return true
            default:
                return false
            }
        }
        return false
    }

    func photoLoadRuntimeRecord(assetId: String, size: ThumbnailSize) -> PhotoLoadRuntimeRecord? {
        let key = TaskKey(assetId: assetId, size: size)
        guard let record = photoLoadRuntimeRecords[key] else { return nil }
        return PhotoLoadRuntimeRecord(
            phaseTimestamps: record.phaseTimestamps,
            cacheStatus: record.cacheStatus,
            loadStatus: record.loadStatus
        )
    }

    func recordFirstImageDisplayed(assetId: String, size: ThumbnailSize) {
        recordPhotoLoadRuntimePhase(
            assetId: assetId,
            size: size,
            phase: "firstImageDisplayed",
            timestamp: Date().timeIntervalSince1970,
            cacheStatus: nil,
            loadStatus: "displayed"
        )
    }

    #if DEBUG
    func resetPlaybackImageRequestLifecycleDiagnostics(
        isEnabled: Bool = PlaybackImageRequestLifecycleDiagnostics.isEnabledInEnvironment()
    ) {
        playbackImageRequestLifecycleDiagnostics = PlaybackImageRequestLifecycleDiagnostics(isEnabled: isEnabled)
        runningLifecycleRequestIds.removeAll()
        latestLifecycleRequestIds.removeAll()
        playbackImageRequestLifecycleContexts.removeAll()
    }

    func playbackImageRequestLifecycleSummary() -> PlaybackImageRequestLifecycleSummary {
        playbackImageRequestLifecycleDiagnostics.makeSummary()
    }

    func flushPlaybackImageRequestLifecycleEvidenceForDiagnostics() {
        playbackImageRequestLifecycleDiagnostics.flushPlaybackImageRequestLifecycleEvidence()
    }

    /// The diagnostic snapshot only checks whether ready URLs are on disk; it never starts or cancels downloads.

    func playbackImageCachePersistenceSnapshotForDiagnostics(
        checkSequence: Int
    ) async -> PlaybackImageCachePersistenceSnapshot {
        let readyFullsizeURLs = readyURLsForCachePersistence(
            urls: assetURLs,
            states: assetStates
        )
        let readyPreviewURLs = readyURLsForCachePersistence(
            urls: assetPreviewURLs,
            states: assetPreviewStates
        )
        let diskReadyFullsizeCount = await diskCachedURLCountForDiagnostics(readyFullsizeURLs)
        let diskReadyPreviewCount = await diskCachedURLCountForDiagnostics(readyPreviewURLs)
        return PlaybackImageCachePersistenceSnapshot(
            checkSequence: checkSequence,
            activeTaskCount: activeTaskCount,
            readyFullsizeCount: readyFullsizeURLs.count,
            diskReadyFullsizeCount: diskReadyFullsizeCount,
            readyPreviewCount: readyPreviewURLs.count,
            diskReadyPreviewCount: diskReadyPreviewCount
        )
    }

    private func readyURLsForCachePersistence(
        urls: [String: URL],
        states: [String: AssetStates]
    ) -> [URL] {
        urls.compactMap { assetId, url in
            guard case .readyToPlay? = states[assetId] else { return nil }
            return url
        }
    }

    private func diskCachedURLCountForDiagnostics(_ urls: [URL]) async -> Int {
        var count = 0
        for url in urls {
            if await containsImageInCacheForDiagnostics(url: url, cacheType: .disk) {
                count += 1
            }
        }
        return count
    }

    func recordPlaybackImageRequestLifecycleDiagnostic(_ event: PlaybackImageRequestLifecycleEvent) {
        playbackImageRequestLifecycleDiagnostics.record(event)
    }

    func markPlaybackImageRequestLifecycleLateResultsForDiagnostics(currentNavigationToken: UUID) {
        playbackImageRequestLifecycleDiagnostics.markLateResults(currentNavigationToken: currentNavigationToken)
    }

    func recordPlaybackImageRequestLifecycleContextForDiagnostics(
        assetId: String,
        size: ThumbnailSize,
        mode: PlaybackImageRequestLifecycleMode,
        role: PlaybackImageRequestLifecycleRole,
        navigationToken: UUID,
        sceneId: String
    ) {
        let key = TaskKey(assetId: assetId, size: size)
        playbackImageRequestLifecycleContexts[key] = PlaybackImageRequestLifecycleDiagnosticContext(
            mode: mode,
            role: role,
            navigationToken: navigationToken,
            sceneId: sceneId
        )
    }

    @discardableResult
    func recordRendererImageRequestForDiagnostics(
        source: PlaybackImageRequestLifecycleSource,
        assetId: String,
        size: ThumbnailSize,
        mode: PlaybackImageRequestLifecycleMode,
        role: PlaybackImageRequestLifecycleRole,
        navigationToken: UUID,
        sceneId: String,
        url: URL,
        context: [SDWebImageContextOption: Any] = [:],
        manager: SDWebImageManager = .shared,
        contextHash: String
    ) -> String? {
        guard playbackImageRequestLifecycleDiagnostics.isEnabled else { return nil }
        let requestId = UUID().uuidString
        let effectiveContext = PlaybackImageRequestLifecycleDiagnostics.rendererEffectiveWebImageContext(context)
        recordPlaybackImageRequestLifecycleDiagnostic(
            .requestStarted(
                requestId: requestId,
                source: source,
                assetId: assetId,
                size: size,
                mode: mode,
                role: role,
                cacheKeyHash: PlaybackImageRequestLifecycleDiagnostics.redactedHash(url.absoluteString),
                contextHash: PlaybackImageRequestLifecycleDiagnostics.redactedHash(contextHash),
                navigationToken: navigationToken,
                sceneId: sceneId,
                timestamp: Date().timeIntervalSince1970
            ))
        recordPlaybackImageRequestLifecycleDiagnostic(
            .cacheKeyResolved(
                requestId: requestId,
                sdDiskCacheFileNameHash: PlaybackImageRequestLifecycleDiagnostics.effectiveSDDiskCacheFileNameHash(
                    url: url,
                    manager: manager,
                    context: effectiveContext
                ),
                timestamp: Date().timeIntervalSince1970
            ))
        latestLifecycleRequestIds[TaskKey(assetId: assetId, size: size)] = requestId
        return requestId
    }

    func recordRendererImageFinishedForDiagnostics(
        requestId: String?,
        cacheType: SDImageCacheType,
        imagePixelWidth: Int?,
        imagePixelHeight: Int?
    ) {
        guard let requestId else { return }
        recordPlaybackImageRequestLifecycleDiagnostic(
            .loadFinished(
                requestId: requestId,
                cacheResult: PlaybackImageRequestLifecycleCacheResult(sdImageCacheType: cacheType),
                imagePixelWidth: imagePixelWidth,
                imagePixelHeight: imagePixelHeight,
                timestamp: Date().timeIntervalSince1970
            ))
    }

    /// Records the cache key only after WebImage succeeds; takes no part in loading or caching decisions.
    func recordRendererResolvedCacheKeyForDiagnostics(
        requestId: String?,
        url: URL,
        context: [SDWebImageContextOption: Any] = [:],
        manager: SDWebImageManager = .shared,
        cacheType: SDImageCacheType
    ) {
        guard let requestId else { return }
        let effectiveContext = PlaybackImageRequestLifecycleDiagnostics.rendererEffectiveWebImageContext(context)
        recordPlaybackImageRequestLifecycleDiagnostic(
            .rendererCacheKeyResolved(
                requestId: requestId,
                sdDiskCacheFileNameHash: PlaybackImageRequestLifecycleDiagnostics.effectiveSDDiskCacheFileNameHash(
                    url: url,
                    manager: manager,
                    context: effectiveContext
                ),
                cacheResult: PlaybackImageRequestLifecycleCacheResult(sdImageCacheType: cacheType),
                timestamp: Date().timeIntervalSince1970
            ))
    }

    /// A memory hit can happen before onAppear; this only fills in the diagnostic identity and does not load.
    func recordRendererImageSuccessForDiagnostics(
        requestId: String?,
        source: PlaybackImageRequestLifecycleSource,
        assetId: String,
        size: ThumbnailSize,
        mode: PlaybackImageRequestLifecycleMode,
        role: PlaybackImageRequestLifecycleRole,
        navigationToken: UUID,
        sceneId: String,
        url: URL,
        context: [SDWebImageContextOption: Any] = [:],
        cacheType: SDImageCacheType,
        imagePixelWidth: Int?,
        imagePixelHeight: Int?
    ) {
        let resolvedRequestId =
            requestId
            ?? recordRendererImageRequestForDiagnostics(
                source: source,
                assetId: assetId,
                size: size,
                mode: mode,
                role: role,
                navigationToken: navigationToken,
                sceneId: sceneId,
                url: url,
                context: context,
                contextHash: "SlideItemView|\(source.rawValue)|downloadRequestModifier"
            )
        recordRendererResolvedCacheKeyForDiagnostics(
            requestId: resolvedRequestId,
            url: url,
            context: context,
            cacheType: cacheType
        )
        recordRendererImageFinishedForDiagnostics(
            requestId: resolvedRequestId,
            cacheType: cacheType,
            imagePixelWidth: imagePixelWidth,
            imagePixelHeight: imagePixelHeight
        )
    }

    func recordRendererImageConsumedForDiagnostics(requestId: String?) {
        guard let requestId else { return }
        recordPlaybackImageRequestLifecycleDiagnostic(
            .consumed(
                requestId: requestId,
                timestamp: Date().timeIntervalSince1970
            ))
    }

    /// Only records the successful filter summary stage mapping; takes no part in requests, disk writes or caching.
    func recordPrePlaybackFilterSummaryTransitionWriterForDiagnostics(
        url: URL,
        context: [SDWebImageContextOption: Any] = [:],
        manager: SDWebImageManager = .shared,
        cacheType: SDImageCacheType
    ) {
        guard playbackImageRequestLifecycleDiagnostics.isEnabled else { return }
        let effectiveContext = PlaybackImageRequestLifecycleDiagnostics.rendererEffectiveWebImageContext(context)
        recordPlaybackImageRequestLifecycleDiagnostic(
            .prePlaybackFilterSummaryTransitionWriter(
                assetIdentityHash: PlaybackImageRequestLifecycleDiagnostics.filterSummaryAssetIdentityHash(url: url),
                requestIdentityHash: PlaybackImageRequestLifecycleDiagnostics.filterSummaryRequestIdentityHash(
                    url: url,
                    manager: manager,
                    context: effectiveContext
                ),
                logicalIdentityHash: PlaybackImageRequestLifecycleDiagnostics.filterSummaryLogicalIdentityHash(
                    url: url),
                urlPathIdentityHash: PlaybackImageRequestLifecycleDiagnostics.filterSummaryURLPathIdentityHash(
                    url: url),
                fullURLIdentityHash: PlaybackImageRequestLifecycleDiagnostics.filterSummaryFullURLIdentityHash(
                    url: url),
                sdDiskCacheFileNameHash: PlaybackImageRequestLifecycleDiagnostics.effectiveSDDiskCacheFileNameHash(
                    url: url,
                    manager: manager,
                    context: effectiveContext
                ),
                cacheResult: PlaybackImageRequestLifecycleCacheResult(sdImageCacheType: cacheType),
                timestamp: Date().timeIntervalSince1970
            ))
    }

    private static let seededPhotoLoadDelayNanoseconds: UInt64 = 5_000_000_000

    @discardableResult
    func seedRunningPhotoLoadForTesting(
        assetId: String,
        size: ThumbnailSize,
        priority: DownloadPriority
    ) -> Task<Void, Never> {
        let key = TaskKey(assetId: assetId, size: size)
        let token = UUID()
        let seededPhotoLoadTask = Task {
            _ = try? await Task.sleep(nanoseconds: Self.seededPhotoLoadDelayNanoseconds)
        }
        runningTasks[key] = seededPhotoLoadTask
        runningTaskTokens[key] = token
        runningTaskPriorities[key] = priority
        let seededRequestId = "seeded-\(assetId)-\(size.rawValue)"
        runningLifecycleRequestIds[key] = seededRequestId
        recordPlaybackImageRequestLifecycleDiagnostic(
            .requestStarted(
                requestId: seededRequestId,
                source: .assetManagerLoadPhoto,
                assetId: assetId,
                size: size,
                mode: .unknown,
                role: priority == .low ? .next : .current,
                cacheKeyHash: PlaybackImageRequestLifecycleDiagnostics.redactedHash(
                    "\(assetId)|\(size.rawValue)|seeded"),
                contextHash: PlaybackImageRequestLifecycleDiagnostics.redactedHash("seeded|\(priority.logName)"),
                navigationToken: UUID(),
                sceneId: "seeded",
                timestamp: Date().timeIntervalSince1970
            ))
        activeTaskCount = runningTasks.count
        return seededPhotoLoadTask
    }

    func runningPhotoLoadPriorityForTesting(assetId: String, size: ThumbnailSize) -> DownloadPriority? {
        runningTaskPriorities[TaskKey(assetId: assetId, size: size)]
    }

    func latestLifecycleRequestIdForTesting(assetId: String, size: ThumbnailSize) -> String? {
        latestLifecycleRequestIds[TaskKey(assetId: assetId, size: size)]
    }

    func clearSeededRunningPhotoLoadForTesting(assetId: String, size: ThumbnailSize) {
        let key = TaskKey(assetId: assetId, size: size)
        runningTasks[key]?.cancel()
        runningOperations[key]?.cancel()
        runningTasks[key] = nil
        runningOperations[key] = nil
        runningTaskTokens[key] = nil
        runningTaskPriorities[key] = nil
        runningLifecycleRequestIds[key] = nil
        latestLifecycleRequestIds[key] = nil
        playbackImageRequestLifecycleContexts[key] = nil
        activeTaskCount = runningTasks.count
    }
    #endif

    #if DEBUG
    func recordPhotoLoadRuntimePhaseForTesting(
        assetId: String,
        size: ThumbnailSize,
        phase: String,
        timestamp: TimeInterval,
        cacheStatus: String
    ) {
        recordPhotoLoadRuntimePhase(
            assetId: assetId,
            size: size,
            phase: phase,
            timestamp: timestamp,
            cacheStatus: cacheStatus,
            loadStatus: phase == "decodeCompleted" ? "decoded" : nil
        )
    }

    #endif

    func loadPhoto(assetId: String, size: ThumbnailSize, priority: DownloadPriority) async {
        let key = TaskKey(assetId: assetId, size: size)
        if isReady(assetId: assetId, size: size) {
            return
        }
        #if DEBUG
        let lifecycleRequestId: String? = playbackImageRequestLifecycleDiagnostics.isEnabled ? UUID().uuidString : nil
        let lifecycleContext = playbackImageRequestLifecycleContexts[key]
        if let lifecycleRequestId {
            recordPlaybackImageRequestLifecycleDiagnostic(
                .requestStarted(
                    requestId: lifecycleRequestId,
                    source: .assetManagerLoadPhoto,
                    assetId: assetId,
                    size: size,
                    mode: lifecycleContext?.mode ?? .unknown,
                    role: lifecycleContext?.role ?? (priority == .low ? .next : .unknown),
                    cacheKeyHash: PlaybackImageRequestLifecycleDiagnostics.redactedHash("\(assetId)|\(size.rawValue)"),
                    contextHash: PlaybackImageRequestLifecycleDiagnostics.redactedHash(
                        "assetManager|\(priority.logName)"),
                    navigationToken: lifecycleContext?.navigationToken ?? UUID(),
                    sceneId: lifecycleContext?.sceneId ?? "unknown",
                    timestamp: Date().timeIntervalSince1970
                ))
            latestLifecycleRequestIds[key] = lifecycleRequestId
        }
        #endif

        if let existingPhotoLoadTask = runningTasks[key],
            let existingPriority = runningTaskPriorities[key]
        {
            #if DEBUG
            let shouldRestartForLegacyPriorityUpgrade =
                usesLegacyPriorityUpgradeForRequestLifecycleDiagnostics
                && existingPriority.rawValue < priority.rawValue
            #else
            let shouldRestartForLegacyPriorityUpgrade = false
            #endif
            if shouldRestartForLegacyPriorityUpgrade {
                #if DEBUG
                // Only the DEBUG legacy baseline interrupts low priority; the default path does not, to avoid bringing
                // back a request storm.

                existingPhotoLoadTask.cancel()
                runningOperations[key]?.cancel()
                if let runningRequestId = runningLifecycleRequestIds[key] {
                    recordPlaybackImageRequestLifecycleDiagnostic(
                        .canceled(
                            requestId: runningRequestId,
                            timestamp: Date().timeIntervalSince1970
                        ))
                }
                runningTasks[key] = nil
                runningOperations[key] = nil
                runningTaskTokens[key] = nil
                runningTaskPriorities[key] = nil
                runningLifecycleRequestIds[key] = nil
                playbackImageRequestLifecycleContexts[key] = nil
                activeTaskCount = runningTasks.count
                #endif
            } else {
                // If the same key is already in flight, join and wait without interrupting low; a visible photo may
                // still finish at low priority.

                if existingPriority.rawValue < priority.rawValue {
                    runningTaskPriorities[key] = priority
                }
                logger.debug(
                    "reuse running download assetId=\(assetId, privacy: .private) size=\(size.rawValue, privacy: .public) existingPriority=\(existingPriority.logName, privacy: .public) requestedPriority=\(priority.logName, privacy: .public)"
                )
                #if DEBUG
                if let lifecycleRequestId,
                    let reusedRequestId = runningLifecycleRequestIds[key]
                {
                    recordPlaybackImageRequestLifecycleDiagnostic(
                        .inFlightReused(
                            requestId: lifecycleRequestId,
                            reusedRequestId: reusedRequestId,
                            timestamp: Date().timeIntervalSince1970
                        ))
                }
                #endif

                await existingPhotoLoadTask.value
                return
            }
        }

        let token = UUID()
        runningTaskTokens[key] = token
        runningTaskPriorities[key] = priority
        #if DEBUG
        if let lifecycleRequestId {
            runningLifecycleRequestIds[key] = lifecycleRequestId
        }
        #endif

        let photoLoadTask = Task { @MainActor in

            defer {

                if runningTaskTokens[key] == token {
                    runningTasks[key] = nil
                    runningOperations[key] = nil
                    runningTaskTokens[key] = nil
                    runningTaskPriorities[key] = nil
                    #if DEBUG
                    runningLifecycleRequestIds[key] = nil
                    latestLifecycleRequestIds[key] = nil
                    playbackImageRequestLifecycleContexts[key] = nil
                    #endif
                    activeTaskCount = runningTasks.count
                }
            }
            if isReady(assetId: assetId, size: size) {
                return
            }
            if findURL(assetId: assetId, size: size) == nil {
                guard !Task.isCancelled else { return }
                await loadURL(assetId: assetId, size: size)
                guard !Task.isCancelled else { return }
            }
            if let url = findURL(assetId: assetId, size: size) {
                guard !Task.isCancelled else { return }
                #if DEBUG
                await downloadPhoto(
                    assetId: assetId,
                    url: url,
                    size: size,
                    priority: priority,
                    taskToken: token,
                    lifecycleRequestId: lifecycleRequestId
                )
                #else
                await downloadPhoto(
                    assetId: assetId,
                    url: url,
                    size: size,
                    priority: priority,
                    taskToken: token
                )
                #endif
            } else {
                return
            }
        }
        runningTasks[key] = photoLoadTask

        activeTaskCount = runningTasks.count
        await photoLoadTask.value
    }

    func preloadPhotos(assets: [Asset], currentIndex: Int, preloadCount: Int, size: ThumbnailSize) async {

        guard !assets.isEmpty else {
            logger.info(
                "preload skipped empty pool size=\(size.rawValue, privacy: .public) currentIndex=\(currentIndex, privacy: .public) preloadCount=\(preloadCount, privacy: .public)"
            )
            return
        }
        guard currentIndex >= 0, currentIndex < assets.count else {
            logger.warning(
                "preload skipped invalid index size=\(size.rawValue, privacy: .public) assetCount=\(assets.count, privacy: .public) currentIndex=\(currentIndex, privacy: .public) preloadCount=\(preloadCount, privacy: .public)"
            )
            return
        }
        // Guard against a negative preloadCount to avoid an invalid range.

        guard preloadCount >= 0 else {
            logger.warning(
                "preload skipped negative preloadCount size=\(size.rawValue, privacy: .public) assetCount=\(assets.count, privacy: .public) currentIndex=\(currentIndex, privacy: .public) preloadCount=\(preloadCount, privacy: .public)"
            )
            return
        }

        let startIndex = max(0, currentIndex - Self.preloadLookBehindAssetCount)
        let endIndex = min(currentIndex + preloadCount, assets.count - 1)
        // Clamp the slice bounds to avoid an out-of-range array index.

        guard startIndex <= endIndex else {
            logger.warning(
                "preload skipped invalid range size=\(size.rawValue, privacy: .public) assetCount=\(assets.count, privacy: .public) currentIndex=\(currentIndex, privacy: .public) startIndex=\(startIndex, privacy: .public) endIndex=\(endIndex, privacy: .public)"
            )
            return
        }
        let rangeCount = endIndex - startIndex + 1
        logger.info(
            "preload begin size=\(size.rawValue, privacy: .public) assetCount=\(assets.count, privacy: .public) currentIndex=\(currentIndex, privacy: .public) startIndex=\(startIndex, privacy: .public) endIndex=\(endIndex, privacy: .public) rangeCount=\(rangeCount, privacy: .public)"
        )

        await withTaskGroup(of: Void.self) { group in
            for index in startIndex...endIndex {
                let assetId = assets[index].id

                group.addTask {

                    await self.loadPhoto(assetId: assetId, size: size, priority: .low)
                }
            }
        }
        logger.info(
            "preload end size=\(size.rawValue, privacy: .public) currentIndex=\(currentIndex, privacy: .public) rangeCount=\(rangeCount, privacy: .public)"
        )
    }

    func clearCacheFromDisk(assetIds: [String]) {
        for id in assetIds {

            cancelAllTasks(for: id)

            if let url = assetURLs[id] {

                SDImageCache.shared.removeImage(forKey: url.absoluteString, fromDisk: true)

                assetURLs[id] = nil
            }
            if let url = assetPreviewURLs[id] {
                SDImageCache.shared.removeImage(forKey: url.absoluteString, fromDisk: true)
                assetPreviewURLs[id] = nil
            }
            if let url = assetThumbnailURLs[id] {
                SDImageCache.shared.removeImage(forKey: url.absoluteString, fromDisk: true)
                assetThumbnailURLs[id] = nil
            }

            assetStates[id] = nil
            assetPreviewStates[id] = nil
            assetThumbnailStates[id] = nil
        }
    }

    /// Each new running task count, delivered once it is stored: `$activeTaskCount` fires before the value changes.
    /// One shared instance, so an `onReceive` keeps its subscription across view updates.
    private(set) lazy var activeTaskCountChanges: AnyPublisher<Int, Never> =
        $activeTaskCount
        .removeDuplicates()
        .dropFirst()
        .receive(on: DispatchQueue.main)
        .eraseToAnyPublisher()

    func cacheSummary() -> CacheSummary {
        let diskBytes = SDImageCache.shared.totalDiskSize()
        let trackedAssetURLCount = assetURLs.count + assetPreviewURLs.count + assetThumbnailURLs.count
        let trackedStateCount = assetStates.count + assetPreviewStates.count + assetThumbnailStates.count
        return CacheSummary(
            diskBytes: diskBytes,
            trackedAssetURLCount: trackedAssetURLCount,
            trackedStateCount: trackedStateCount,
            runningTaskCount: activeTaskCount
        )
    }

    func clearDiskCacheForSettings() async {
        // Cancel all downloads first so old tasks cannot write state back after the clear.
        cancelAllRunningTasks()
        await withCheckedContinuation { continuation in
            SDImageCache.shared.clearDisk {
                continuation.resume()
            }
        }
        clearAllTrackedStatesAndURLs()
    }

    // After a server switch, cancel in-flight tasks and clear URLs/states so nothing leaks into the new server.

    func resetForServerConfigurationChange() {
        cancelAllRunningTasks()
        clearAllTrackedStatesAndURLs()
        SDImageCache.shared.clearMemory()
    }

    func cancelExpiredTasks(keepAssetIds: Set<String>) {
        var cancelledCount = 0

        for task in runningTasks {

            if !keepAssetIds.contains(task.key.assetId) {
                task.value.cancel()

                runningOperations[task.key]?.cancel()
                runningOperations[task.key] = nil
                #if DEBUG
                if let requestId = runningLifecycleRequestIds[task.key] {
                    recordPlaybackImageRequestLifecycleDiagnostic(
                        .canceled(
                            requestId: requestId,
                            timestamp: Date().timeIntervalSince1970
                        ))
                }
                latestLifecycleRequestIds[task.key] = nil
                #endif
                cancelledCount += 1
            }
        }
        if cancelledCount > 0 {
            logger.info(
                "cancel expired download tasks cancelledCount=\(cancelledCount, privacy: .public) keepCount=\(keepAssetIds.count, privacy: .public)"
            )
        }
    }

    private func loadURL(assetId: String, size: ThumbnailSize) async {

        if url(assetId: assetId, size: size) != nil {
            return
        }
        logger.debug(
            "thumbnail url load begin assetId=\(assetId, privacy: .private) size=\(size.rawValue, privacy: .public)"
        )

        setState(.loadingURL, assetId: assetId, size: size)
        do {
            let url = try await ImmichAPIService.shared.getThumbnailURL(
                id: assetId,
                size: size
            )

            setURL(url, assetId: assetId, size: size)

            setState(.urlReady, assetId: assetId, size: size)
            logger.debug(
                "thumbnail url load success assetId=\(assetId, privacy: .private) size=\(size.rawValue, privacy: .public)"
            )
        } catch {
            let message = error.localizedDescription
            logger.error(
                "thumbnail url load failed assetId=\(assetId, privacy: .private) size=\(size.rawValue, privacy: .public) error=\(message, privacy: .private)"
            )
            setState(.failed, assetId: assetId, size: size)
        }
    }

    private func downloadPhoto(
        assetId: String,
        url: URL,
        size: ThumbnailSize,
        priority: DownloadPriority,
        taskToken: UUID,
        lifecycleRequestId: String? = nil
    ) async {

        #if DEBUG
        let lifecycleCacheResult: PlaybackImageRequestLifecycleCacheResult?
        if lifecycleRequestId != nil {
            lifecycleCacheResult = await checkImageCacheResultForDiagnostics(url: url)
        } else {
            lifecycleCacheResult = nil
        }
        if let lifecycleRequestId, let lifecycleCacheResult {
            recordPlaybackImageRequestLifecycleDiagnostic(
                .cacheChecked(
                    requestId: lifecycleRequestId,
                    result: lifecycleCacheResult,
                    timestamp: Date().timeIntervalSince1970
                ))
        }
        let isCached: Bool
        if let lifecycleCacheResult {
            isCached = lifecycleCacheResult == .memory || lifecycleCacheResult == .disk
        } else {
            isCached = await checkImageInCache(url: url)
        }
        #else
        let isCached = await checkImageInCache(url: url)
        #endif
        recordPhotoLoadRuntimePhase(
            assetId: assetId,
            size: size,
            phase: "cacheChecked",
            timestamp: Date().timeIntervalSince1970,
            cacheStatus: isCached ? "hit" : "miss",
            loadStatus: nil
        )
        if isCached {
            logger.debug(
                "download cache hit assetId=\(assetId, privacy: .private) size=\(size.rawValue, privacy: .public)"
            )

            lastDownloadWasCacheHit = true
            lastDownloadDuration = 0
            lastDownloadBytes = 0

            setState(.readyToPlay, assetId: assetId, size: size)
            recordPhotoLoadRuntimePhase(
                assetId: assetId,
                size: size,
                phase: "decodeCompleted",
                timestamp: Date().timeIntervalSince1970,
                cacheStatus: "hit",
                loadStatus: "decoded"
            )
            return
        } else {
            guard !Task.isCancelled else { return }

            setState(.downloading, assetId: assetId, size: size)

            guard let modifier = ImmichRequestModifier.create() else {
                logger.error(
                    "download failed request modifier missing assetId=\(assetId, privacy: .private) size=\(size.rawValue, privacy: .public)"
                )

                setState(.failedToDownload, assetId: assetId, size: size)
                return
            }

            let startTime = Date()
            logger.info(
                "download start assetId=\(assetId, privacy: .private) size=\(size.rawValue, privacy: .public) priority=\(priority.logName, privacy: .public) activeTasks=\(self.activeTaskCount, privacy: .public)"
            )
            #if DEBUG
            if let lifecycleRequestId {
                recordPlaybackImageRequestLifecycleDiagnostic(
                    .loadEntered(
                        requestId: lifecycleRequestId,
                        timestamp: startTime.timeIntervalSince1970
                    ))
            }
            #endif
            recordPhotoLoadRuntimePhase(
                assetId: assetId,
                size: size,
                phase: "downloadRequestStarted",
                timestamp: startTime.timeIntervalSince1970,
                cacheStatus: "miss",
                loadStatus: "downloading"
            )
            let downloadBridge = SDWebImageAsyncBridge<UInt>(fallbackValue: 0)
            let downloadedBytes = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    downloadBridge.setContinuation(continuation)

                    let options: SDWebImageOptions = (priority == .high) ? [.highPriority] : [.lowPriority]

                    let context: [SDWebImageContextOption: Any] = [
                        .downloadRequestModifier: modifier,
                        .callbackQueue: SDCallbackQueue.main
                    ]

                    let manager = (priority == .high) ? SDWebImageManager.shared : self.lowPriorityManager
                    #if DEBUG
                    if let lifecycleRequestId {
                        self.recordPlaybackImageRequestLifecycleDiagnostic(
                            .cacheKeyResolved(
                                requestId: lifecycleRequestId,
                                sdDiskCacheFileNameHash:
                                    PlaybackImageRequestLifecycleDiagnostics.effectiveSDDiskCacheFileNameHash(
                                        url: url,
                                        manager: manager,
                                        context: context
                                    ),
                                timestamp: Date().timeIntervalSince1970
                            ))
                    }
                    #endif

                    let operation = manager.loadImage(
                        with: url,
                        options: options,
                        context: context,
                        progress: nil
                    ) { [weak self] image, data, error, cacheType, finished, imageURL in
                        guard let self = self else { return }

                        if finished || error != nil {

                            if self.runningTaskTokens[TaskKey(assetId: assetId, size: size)] == taskToken {
                                self.runningOperations[TaskKey(assetId: assetId, size: size)] = nil
                            }
                            let byteCount = UInt(data?.count ?? 0)
                            let callbackTimestamp = Date().timeIntervalSince1970
                            #if DEBUG
                            if let lifecycleRequestId {
                                self.recordPlaybackImageRequestLifecycleDiagnostic(
                                    .loadFinished(
                                        requestId: lifecycleRequestId,
                                        cacheResult: PlaybackImageRequestLifecycleCacheResult(
                                            sdImageCacheType: cacheType),
                                        imagePixelWidth: image?.cgImage?.width,
                                        imagePixelHeight: image?.cgImage?.height,
                                        timestamp: callbackTimestamp
                                    ))
                            }
                            #endif
                            self.recordPhotoLoadRuntimePhase(
                                assetId: assetId,
                                size: size,
                                phase: "downloadCompleted",
                                timestamp: callbackTimestamp,
                                cacheStatus: "miss",
                                loadStatus: image == nil ? "failed" : "downloaded"
                            )
                            if image != nil {
                                self.recordPhotoLoadRuntimePhase(
                                    assetId: assetId,
                                    size: size,
                                    phase: "decodeCompleted",
                                    timestamp: callbackTimestamp,
                                    cacheStatus: "miss",
                                    loadStatus: "decoded"
                                )
                            }
                            downloadBridge.resume(returning: byteCount)
                        }
                    }

                    if let operation = operation {
                        downloadBridge.setOperation(operation)

                        if self.runningTaskTokens[TaskKey(assetId: assetId, size: size)] == taskToken {
                            self.runningOperations[TaskKey(assetId: assetId, size: size)] = operation
                        }
                    } else {

                        downloadBridge.resume(returning: 0)
                    }
                }
            } onCancel: {
                downloadBridge.cancelAndResume()
            }
            guard !Task.isCancelled else { return }
            let duration = Date().timeIntervalSince(startTime)
            let durationMilliseconds = Int((duration * 1000.0).rounded())
            lastDownloadWasCacheHit = false
            lastDownloadDuration = duration
            lastDownloadBytes = downloadedBytes

            #if DEBUG
            let downloadSuccess = await checkImageCacheResultForDiagnostics(url: url) != .miss
            #else
            let downloadSuccess = await checkImageInCache(url: url)
            #endif
            if downloadSuccess {
                logger.info(
                    "download success assetId=\(assetId, privacy: .private) size=\(size.rawValue, privacy: .public) priority=\(priority.logName, privacy: .public) durationMs=\(durationMilliseconds, privacy: .public) bytes=\(self.lastDownloadBytes, privacy: .public)"
                )

                setState(.readyToPlay, assetId: assetId, size: size)
            } else {
                logger.error(
                    "download failed cache missing after finish assetId=\(assetId, privacy: .private) size=\(size.rawValue, privacy: .public) priority=\(priority.logName, privacy: .public) durationMs=\(durationMilliseconds, privacy: .public)"
                )

                setState(.failedToDownload, assetId: assetId, size: size)
                recordPhotoLoadRuntimePhase(
                    assetId: assetId,
                    size: size,
                    phase: "downloadCompleted",
                    timestamp: Date().timeIntervalSince1970,
                    cacheStatus: "miss",
                    loadStatus: "failed"
                )
            }
        }
    }

    #if DEBUG
    private func checkImageCacheResultForDiagnostics(url: URL) async -> PlaybackImageRequestLifecycleCacheResult {
        if await containsImageInCacheForDiagnostics(url: url, cacheType: .memory) {
            return .memory
        }
        if await containsImageInCacheForDiagnostics(url: url, cacheType: .disk) {
            return .disk
        }
        return .miss
    }

    private func containsImageInCacheForDiagnostics(url: URL, cacheType: SDImageCacheType) async -> Bool {
        await withCheckedContinuation { continuation in
            SDImageCache.shared.containsImage(
                forKey: url.absoluteString,
                cacheType: cacheType
            ) { result in
                continuation.resume(returning: result != .none)
            }
        }
    }
    #endif

    private func checkImageInCache(url: URL) async -> Bool {

        return await withCheckedContinuation { continuation in

            SDImageCache.shared.containsImage(
                forKey: url.absoluteString,
                cacheType: .all
            ) { cacheType in

                let isCached = cacheType != .none

                continuation.resume(returning: isCached)
            }
        }
    }
    private func cancelAllTasks(for assetId: String) {
        for size in [ThumbnailSize.fullsize, .preview, .thumbnail] {
            let key = TaskKey(assetId: assetId, size: size)
            runningTasks[key]?.cancel()
            runningOperations[key]?.cancel()
            runningTasks[key] = nil
            runningOperations[key] = nil
            runningTaskTokens[key] = nil
            runningTaskPriorities[key] = nil
        }
        activeTaskCount = runningTasks.count
    }

    private func cancelAllRunningTasks() {
        for (_, task) in runningTasks {
            task.cancel()
        }
        for (_, operation) in runningOperations {
            operation.cancel()
        }
        runningTasks.removeAll()
        runningOperations.removeAll()
        runningTaskTokens.removeAll()
        runningTaskPriorities.removeAll()
        activeTaskCount = 0
    }

    private func clearAllTrackedStatesAndURLs() {
        assetURLs.removeAll()
        assetPreviewURLs.removeAll()
        assetThumbnailURLs.removeAll()
        assetStates.removeAll()
        assetPreviewStates.removeAll()
        assetThumbnailStates.removeAll()
        photoLoadRuntimeRecords.removeAll()
    }
}

private extension AssetsDownloadManager {
    func recordPhotoLoadRuntimePhase(
        assetId: String,
        size: ThumbnailSize,
        phase: String,
        timestamp: TimeInterval,
        cacheStatus: String?,
        loadStatus: String?
    ) {
        let key = TaskKey(assetId: assetId, size: size)
        var record = photoLoadRuntimeRecords[key] ?? PhotoLoadRuntimeRecordStorage()
        if record.phaseTimestamps[phase] == nil {
            record.phaseTimestamps[phase] = timestamp
        }
        if let cacheStatus {
            record.cacheStatus = cacheStatus
        }
        if let loadStatus {
            record.loadStatus = loadStatus
        }
        photoLoadRuntimeRecords[key] = record
    }

    func url(assetId: String, size: ThumbnailSize) -> URL? {
        switch size {
        case .fullsize:
            return assetURLs[assetId]
        case .preview:
            return assetPreviewURLs[assetId]
        case .thumbnail:
            return assetThumbnailURLs[assetId]
        }
    }

    func setURL(_ url: URL?, assetId: String, size: ThumbnailSize) {
        switch size {
        case .fullsize:
            assetURLs[assetId] = url
        case .preview:
            assetPreviewURLs[assetId] = url
        case .thumbnail:
            assetThumbnailURLs[assetId] = url
        }
    }

    func state(assetId: String, size: ThumbnailSize) -> AssetStates? {
        switch size {
        case .fullsize:
            return assetStates[assetId]
        case .preview:
            return assetPreviewStates[assetId]
        case .thumbnail:
            return assetThumbnailStates[assetId]
        }
    }

    func setState(_ state: AssetStates?, assetId: String, size: ThumbnailSize) {
        switch size {
        case .fullsize:
            assetStates[assetId] = state
        case .preview:
            assetPreviewStates[assetId] = state
        case .thumbnail:
            assetThumbnailStates[assetId] = state
        }
    }
}

private extension AssetsDownloadManager.DownloadPriority {

    var logName: String {
        switch self {
        case .low:
            return "low"
        case .high:
            return "high"
        }
    }
}
