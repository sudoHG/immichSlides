#if DEBUG
import Foundation
import SDWebImage
import Combine
import OSLog

extension AssetsDownloadManager {
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
    func checkImageCacheResultForDiagnostics(url: URL) async -> PlaybackImageRequestLifecycleCacheResult {
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
}
#endif
