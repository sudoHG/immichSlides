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
        if let task = firstPreloadTask {
            logger.info("first preload waits existing task")
            await task.value
            return
        }
        logger.info("first preload task created source=\(self.logName(for: self.source), privacy: .public)")
        let task = Task {
            defer { self.firstPreloadTask = nil }
            await self.prepareInitialAssets()
        }
        firstPreloadTask = task
        await task.value
    }

    func prepareInitialAssets() async {
        let loadGeneration = playbackSourceGeneration
        recordSmartFillStartupRuntimePhase("playbackEntryRequested")
        logger.info(
            "initial prepare begin source=\(self.logName(for: self.source), privacy: .public)"
        )

        let didApplyAssets = await loadAssets()
        guard didApplyAssets,
            let initialLoadIdentity = lastAppliedInitialLoadIdentity,
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
            if playbackSessionEngine.currentScene?.smartFillReadback == nil {
                _ = rebuildInitialSmartFillSceneIfPossible(invalidationReason: .poolReloaded)
            }
        }
        clearVisionFaceAuditState()

        if let firstScene = scene(at: 0),
            let firstAssetId = firstScene.primaryAssetId
        {
            logger.info(
                "initial first asset load begin sceneId=\(firstScene.id, privacy: .private) assetId=\(firstAssetId, privacy: .private) assetCount=\(self.assets.count, privacy: .public)"
            )
            let presentationState = playbackSessionEngine.scenePresentationState
            if let generation = (presentationState.pendingTarget ?? presentationState.currentTarget)?.identity
                .generation,
                let effectTask = scenePresentationEffectTasks[generation]
            {
                await effectTask.value
            }
            guard isCurrentPlaybackLoad(initialLoadIdentity),
                scene(at: 0)?.primaryAssetId == firstAssetId
            else {
                logger.notice(
                    "initial first asset load ignored stale completion sceneId=\(firstScene.id, privacy: .private) assetId=\(firstAssetId, privacy: .private) generation=\(loadGeneration, privacy: .public) currentGeneration=\(self.playbackSourceGeneration, privacy: .public)"
                )
                return
            }
            didFirstPreload = true
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
        Task { @MainActor in  // Preload runs in a Task so we do not stall waiting for it before returning.
            guard self.isCurrentPlaybackLoad(initialLoadIdentity) else {
                self.logger.notice(
                    "initial background preload skipped stale generation=\(loadGeneration, privacy: .public) currentGeneration=\(self.playbackSourceGeneration, privacy: .public)"
                )
                return
            }
            self.logger.info(
                "initial background preload begin assetCount=\(preloadAssets.count, privacy: .public) preloadCount=\(preloadCount, privacy: .public)"
            )
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
            self.logger.info(
                "initial background preload end assetCount=\(preloadAssets.count, privacy: .public)"
            )
        }
    }

}
