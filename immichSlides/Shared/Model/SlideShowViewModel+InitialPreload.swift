import Foundation
import Combine
import CryptoKit
import CoreGraphics
import OSLog

extension SlideShowViewModel {
    func firstPreload() async {
        guard !didFirstPreload else {
            logger.info("first preload skipped already completed")
            return
        }
        await scenePresentationEffectExecutor.runFirstPreload(sourceName: logName(for: source), logger: logger) {
            await self.prepareInitialAssets()
        }
    }

    func prepareInitialAssets() async {
        let loadGeneration = playbackSourceGeneration
        recordSmartFillStartupRuntimePhase("playbackEntryRequested")
        logger.info(
            "initial prepare begin source=\(self.logName(for: self.source), privacy: .public)"
        )

        let didApplyAssets = await loadAssets()
        guard didApplyAssets,
            let initialLoadIdentity = appliedInitialLoadIdentity,
            isCurrentPlaybackLoad(initialLoadIdentity)
        else {
            logger.notice(
                "initial prepare ignored stale asset result generation=\(loadGeneration, privacy: .public) currentGeneration=\(self.playbackSourceGeneration, privacy: .public)"
            )
            return
        }
        if smartFillSurface != nil,
            isSmartFillPlanningEnabled,
            !assets.isEmpty
        {
            if playbackSession.currentScene?.smartFillReadback == nil {
                _ = rebuildInitialSmartFillSceneIfPossible(invalidationReason: .poolReloaded)
            }
        }
        #if DEBUG
        clearVisionFaceAuditState()
        #endif

        if let firstScene = scene(at: 0),
            let firstAssetId = firstScene.primaryAssetId
        {
            logger.info(
                "initial first asset load begin sceneId=\(firstScene.id, privacy: .private) assetId=\(firstAssetId, privacy: .private) assetCount=\(self.assets.count, privacy: .public)"
            )
            if let completion = currentSceneDownloadCompletion {
                await completion.waitForDownloads()
            }
            guard isCurrentPlaybackLoad(initialLoadIdentity),
                scene(at: 0)?.primaryAssetId == firstAssetId
            else {
                logger.notice(
                    "initial first asset load ignored stale completion sceneId=\(firstScene.id, privacy: .private) assetId=\(firstAssetId, privacy: .private) generation=\(loadGeneration, privacy: .public) currentGeneration=\(self.playbackSourceGeneration, privacy: .public)"
                )
                return
            }
            markFirstPreloadCompleted()
            logger.info(
                "initial first asset load end sceneId=\(firstScene.id, privacy: .private) assetId=\(firstAssetId, privacy: .private) assetCount=\(self.assets.count, privacy: .public)"
            )

            startInitialBackgroundPreload(
                initialLoadIdentity: initialLoadIdentity,
                loadGeneration: loadGeneration
            )

        } else {
            logger.warning(
                "initial prepare ended empty source=\(self.logName(for: self.source), privacy: .public) currentIndex=\(self.currentIndex, privacy: .public) targetIndex=\(self.targetIndex, privacy: .public) fallbackReason=\(PlaybackSceneFallbackReason.emptyPool.rawValue, privacy: .public)"
            )
        }
    }
    private func startInitialBackgroundPreload(
        initialLoadIdentity: PlaybackLoadIdentity,
        loadGeneration: Int
    ) {
        let preloadAssets = assets
        let preloadCount = self.preloadCount
        scenePresentationEffectExecutor.startInitialBackgroundPreload {
            guard self.isCurrentPlaybackLoad(initialLoadIdentity) else {
                self.logger.notice(
                    "initial background preload skipped stale generation=\(loadGeneration, privacy: .public) currentGeneration=\(self.playbackSourceGeneration, privacy: .public)"
                )
                return
            }
            self.logger.info(
                "initial background preload begin assetCount=\(preloadAssets.count, privacy: .public) preloadCount=\(preloadCount, privacy: .public)"
            )
            #if DEBUG
            if let backgroundPreloadHookForTesting = self.backgroundPreloadHookForTesting {
                await backgroundPreloadHookForTesting(preloadAssets, 0, preloadCount)
            } else {
                #if DEBUG
                self.recordPreloadWindowLifecycleContextsForDiagnostics(
                    assets: preloadAssets,
                    currentIndex: 0,
                    preloadCount: preloadCount,
                    size: .fullsize
                )
                #endif
                await self.downloadManager.preloadPhotos(
                    assets: preloadAssets,
                    currentIndex: 0,
                    preloadCount: preloadCount,
                    size: .fullsize
                )
                guard self.isCurrentPlaybackLoad(initialLoadIdentity) else {
                    self.logger.notice(
                        "initial background preview preload skipped stale generation=\(loadGeneration, privacy: .public) currentGeneration=\(self.playbackSourceGeneration, privacy: .public)"
                    )
                    return
                }
                #if DEBUG
                self.recordPreloadWindowLifecycleContextsForDiagnostics(
                    assets: preloadAssets,
                    currentIndex: 0,
                    preloadCount: preloadCount,
                    size: .preview
                )
                #endif
                await self.downloadManager.preloadPhotos(
                    assets: preloadAssets,
                    currentIndex: 0,
                    preloadCount: preloadCount,
                    size: .preview
                )
            }
            #else
            await self.downloadManager.preloadPhotos(
                assets: preloadAssets,
                currentIndex: 0,
                preloadCount: preloadCount,
                size: .fullsize
            )
            guard self.isCurrentPlaybackLoad(initialLoadIdentity) else {
                self.logger.notice(
                    "initial background preview preload skipped stale generation=\(loadGeneration, privacy: .public) currentGeneration=\(self.playbackSourceGeneration, privacy: .public)"
                )
                return
            }
            await self.downloadManager.preloadPhotos(
                assets: preloadAssets,
                currentIndex: 0,
                preloadCount: preloadCount,
                size: .preview
            )
            #endif
            self.logger.info(
                "initial background preload end assetCount=\(preloadAssets.count, privacy: .public)"
            )
        }
    }

}
