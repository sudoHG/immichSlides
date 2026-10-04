import Foundation
import SDWebImage
import OSLog
#if canImport(UIKit)
import UIKit
#endif

struct SoloVisionBatchResult {
    let approvedAssets: [Asset]
    let finishedCount: Int
    let failedCount: Int
    let incompleteCount: Int
}

// Re-checks candidates that passed the Immich metadata pre-filter with Vision; keeps only those with exactly
// one face.

actor SoloVisionPoolFilter {

    private struct SoloVisionDecision {
        let shouldKeep: Bool
        let outcome: Outcome

        enum Outcome {
            case finished
            case failed
            case incomplete
        }
    }

    // Shared singleton so Vision results and the preview URL cache are reused.

    static let shared = SoloVisionPoolFilter()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "immichSlides",
        category: "SoloVision"
    )

    // Cache the full Decision rather than a Bool so an empty pool can tell failure reasons apart.

    private var decisionByAssetId: [String: SoloVisionDecision] = [:]

    // Cache preview URLs so the same asset's URL is not built again and again.
    private var previewURLByAssetId: [String: URL] = [:]

    // Fixed cache capacity with LRU eviction so large libraries do not grow it without bound.

    private let cacheCapacity = 600

    // Access order: most recently used at the end; over capacity, evict from the start.

    private var cacheAccessOrder: [String] = []

    // Vision audit downloads run 2 at a time so they do not take bandwidth from the current playback photo.

    private let maxParallelAudits: Int = 2

    private lazy var auditDownloadManager: SDWebImageManager = {
        let config =
            (SDWebImageDownloaderConfig.default.copy() as? SDWebImageDownloaderConfig) ?? SDWebImageDownloaderConfig()
        config.maxConcurrentDownloads = maxParallelAudits
        config.executionOrder = .fifoExecutionOrder
        let downloader = SDWebImageDownloader(config: config)
        return SDWebImageManager(cache: SDImageCache.shared, loader: downloader)
    }()

    // Audit only up to acceptedLimit; do not run every candidate just for the first open.

    func approvedAssets(
        from candidates: [Asset],
        apiService: ImmichAPIService,
        acceptedLimit: Int
    ) async -> [Asset] {
        let result = await approvalResult(
            from: candidates,
            apiService: apiService,
            acceptedLimit: acceptedLimit
        )
        return result.approvedAssets
    }

    func approvalResult(
        from candidates: [Asset],
        apiService: ImmichAPIService,
        acceptedLimit: Int
    ) async -> SoloVisionBatchResult {
        guard acceptedLimit > 0 else {
            logger.warning("solo vision batch skipped invalid limit=\(acceptedLimit, privacy: .public)")
            return SoloVisionBatchResult(
                approvedAssets: [],
                finishedCount: 0,
                failedCount: 0,
                incompleteCount: 0
            )
        }
        guard !candidates.isEmpty else {
            logger.info("solo vision batch skipped empty candidates limit=\(acceptedLimit, privacy: .public)")
            return SoloVisionBatchResult(
                approvedAssets: [],
                finishedCount: 0,
                failedCount: 0,
                incompleteCount: 0
            )
        }
        logger.info(
            "solo vision batch begin candidates=\(candidates.count, privacy: .public) acceptedLimit=\(acceptedLimit, privacy: .public) maxParallel=\(self.maxParallelAudits, privacy: .public)"
        )

        let result = await withTaskGroup(
            of: (Asset, SoloVisionDecision).self,
            returning: SoloVisionBatchResult.self
        ) { group in
            var approvedAssets: [Asset] = []
            var seenAssetIds: Set<String> = []
            var nextCandidateIndex = 0
            var activeAuditCount = 0
            var finishedCount = 0
            var failedCount = 0
            var incompleteCount = 0

            while activeAuditCount < maxParallelAudits,
                nextCandidateIndex < candidates.count
            {
                let asset = candidates[nextCandidateIndex]
                nextCandidateIndex += 1

                // The random API may return duplicates, so dedupe locally by asset id first.

                guard seenAssetIds.insert(asset.id).inserted else {
                    continue
                }

                activeAuditCount += 1
                group.addTask {
                    let decision = await self.decision(asset, apiService: apiService)
                    return (asset, decision)
                }
            }

            while activeAuditCount > 0 {
                guard let (asset, decision) = await group.next() else {
                    break
                }

                activeAuditCount -= 1

                switch decision.outcome {
                case .finished:
                    finishedCount += 1
                case .failed:
                    failedCount += 1
                case .incomplete:
                    incompleteCount += 1
                }

                if decision.shouldKeep {
                    approvedAssets.append(asset)
                }

                if approvedAssets.count >= acceptedLimit {
                    group.cancelAll()
                    break
                }

                while activeAuditCount < maxParallelAudits,
                    nextCandidateIndex < candidates.count
                {
                    let nextAsset = candidates[nextCandidateIndex]
                    nextCandidateIndex += 1

                    guard seenAssetIds.insert(nextAsset.id).inserted else {
                        continue
                    }

                    activeAuditCount += 1
                    group.addTask {
                        let decision = await self.decision(nextAsset, apiService: apiService)
                        return (nextAsset, decision)
                    }

                    if activeAuditCount >= maxParallelAudits {
                        break
                    }
                }
            }

            return SoloVisionBatchResult(
                approvedAssets: Array(approvedAssets.prefix(acceptedLimit)),
                finishedCount: finishedCount,
                failedCount: failedCount,
                incompleteCount: incompleteCount
            )
        }
        logger.info(
            "solo vision batch end candidates=\(candidates.count, privacy: .public) acceptedLimit=\(acceptedLimit, privacy: .public) approvedCount=\(result.approvedAssets.count, privacy: .public) finishedCount=\(result.finishedCount, privacy: .public) failedCount=\(result.failedCount, privacy: .public) incompleteCount=\(result.incompleteCount, privacy: .public)"
        )
        return result
    }

    // Clear the Vision cache after a server switch; old assetIds/URLs must not be reused.

    func resetForServerConfigurationChange() {
        decisionByAssetId.removeAll()
        previewURLByAssetId.removeAll()
        cacheAccessOrder.removeAll()
        logger.info("solo vision cache reset after server configuration change")
    }

    private func decision(
        _ asset: Asset,
        apiService: ImmichAPIService
    ) async -> SoloVisionDecision {
        if let cachedDecision = cachedDecision(for: asset.id) {
            logger.debug(
                "solo vision cached decision assetId=\(asset.id, privacy: .private) keep=\(cachedDecision.shouldKeep ? "true" : "false", privacy: .private)"
            )
            return cachedDecision
        }

        guard let previewURL = await previewURL(for: asset.id, apiService: apiService) else {
            let decision = SoloVisionDecision(shouldKeep: false, outcome: .incomplete)
            storeDecision(decision, for: asset.id)
            logger.warning(
                "solo vision drop preview url unavailable assetId=\(asset.id, privacy: .private)"
            )
            return decision
        }

        let apiKey = await apiService.getApiKey()
        guard let modifier = ImmichRequestModifier.create(apiKey: apiKey) else {
            let decision = SoloVisionDecision(shouldKeep: false, outcome: .incomplete)
            storeDecision(decision, for: asset.id)
            logger.warning(
                "solo vision drop request modifier unavailable assetId=\(asset.id, privacy: .private)"
            )
            return decision
        }

        guard let image = await loadPreviewImage(assetId: asset.id, url: previewURL, modifier: modifier) else {
            let decision = SoloVisionDecision(shouldKeep: false, outcome: .incomplete)
            storeDecision(decision, for: asset.id)
            logger.warning(
                "solo vision drop preview image unavailable assetId=\(asset.id, privacy: .private)"
            )
            return decision
        }

        let state = await VisionFaceAuditService.audit(
            assetId: asset.id,
            imageSource: .preview,
            image: image
        )

        await SDImageCache.shared.removeImage(
            forKey: previewURL.absoluteString,
            fromDisk: false
        )

        let decision: SoloVisionDecision
        switch state {
        case .finished(let result):
            let shouldKeep = (result.faceCount == 1)
            decision = SoloVisionDecision(shouldKeep: shouldKeep, outcome: .finished)
            logger.info(
                "solo vision decision assetId=\(asset.id, privacy: .private) faceCount=\(result.faceCount, privacy: .private) keep=\(shouldKeep ? "true" : "false", privacy: .private) elapsedMs=\(result.elapsedMilliseconds, privacy: .public) pixelWidth=\(result.imagePixelWidth, privacy: .public) pixelHeight=\(result.imagePixelHeight, privacy: .public)"
            )
        case .failed(let message):
            decision = SoloVisionDecision(shouldKeep: false, outcome: .failed)
            logger.warning(
                "solo vision decision failed assetId=\(asset.id, privacy: .private) keep=false error=\(message, privacy: .private)"
            )
        case .idle, .waitingForImage, .running:
            decision = SoloVisionDecision(shouldKeep: false, outcome: .incomplete)
            logger.warning(
                "solo vision decision incomplete assetId=\(asset.id, privacy: .private) keep=false"
            )
        }

        storeDecision(decision, for: asset.id)
        return decision
    }

    private func previewURL(
        for assetId: String,
        apiService: ImmichAPIService
    ) async -> URL? {
        if let cachedURL = previewURLByAssetId[assetId] {
            touchCacheEntry(assetId: assetId)
            return cachedURL
        }

        do {
            let url = try await apiService.getThumbnailURL(id: assetId, size: .preview)
            storePreviewURL(url, for: assetId)
            return url
        } catch {
            let message = error.localizedDescription
            logger.error(
                "solo vision preview url failed assetId=\(assetId, privacy: .private) error=\(message, privacy: .private)"
            )
            return nil
        }
    }

    private func loadPreviewImage(
        assetId: String,
        url: URL,
        modifier: SDWebImageDownloaderRequestModifier
    ) async -> UIImage? {
        if let cachedImage = SDImageCache.shared.imageFromCache(forKey: url.absoluteString) {
            logger.debug(
                "solo vision preview cache hit assetId=\(assetId, privacy: .private)"
            )
            return cachedImage
        }

        logger.info(
            "solo vision preview download begin assetId=\(assetId, privacy: .private)"
        )

        let callbackLogger = logger
        let downloadBridge = SDWebImageAsyncBridge<UIImage?>(fallbackValue: nil)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                downloadBridge.setContinuation(continuation)

                let context: [SDWebImageContextOption: Any] = [
                    .downloadRequestModifier: modifier
                ]

                let operation = auditDownloadManager.loadImage(
                    with: url,
                    options: [.lowPriority],
                    context: context,
                    progress: nil
                ) { image, _, error, _, finished, _ in
                    // Resume only on completion or error; ignore progressive callbacks.
                    guard finished || error != nil else { return }
                    if let error {
                        let message = error.localizedDescription
                        callbackLogger.warning(
                            "solo vision preview download callback error assetId=\(assetId, privacy: .private) error=\(message, privacy: .private)"
                        )
                    }
                    downloadBridge.resume(returning: image)
                }

                // If no operation was even created, the async call must not hang forever.
                if let operation {
                    downloadBridge.setOperation(operation)
                } else {
                    callbackLogger.warning(
                        "solo vision preview download operation missing assetId=\(assetId, privacy: .private)"
                    )
                    downloadBridge.resume(returning: nil)
                }
            }
        } onCancel: {
            downloadBridge.cancelAndResume()
        }
    }

    private func cachedDecision(for assetId: String) -> SoloVisionDecision? {
        guard let decision = decisionByAssetId[assetId] else {
            return nil
        }
        touchCacheEntry(assetId: assetId)
        return decision
    }

    private func storeDecision(_ decision: SoloVisionDecision, for assetId: String) {
        decisionByAssetId[assetId] = decision
        touchCacheEntry(assetId: assetId)
        trimCacheIfNeeded()
    }

    private func storePreviewURL(_ url: URL, for assetId: String) {
        previewURLByAssetId[assetId] = url
        touchCacheEntry(assetId: assetId)
        trimCacheIfNeeded()
    }

    private func touchCacheEntry(assetId: String) {
        if let existingIndex = cacheAccessOrder.firstIndex(of: assetId) {
            cacheAccessOrder.remove(at: existingIndex)
        }
        cacheAccessOrder.append(assetId)
    }

    private func trimCacheIfNeeded() {
        while cacheAccessOrder.count > cacheCapacity {
            let evictedAssetId = cacheAccessOrder.removeFirst()
            decisionByAssetId[evictedAssetId] = nil
            previewURLByAssetId[evictedAssetId] = nil
        }
    }
}
