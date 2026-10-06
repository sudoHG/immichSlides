import Foundation
import Combine
import CryptoKit
import CoreGraphics
import OSLog

extension SlideShowViewModel {
    private static let refillRemainingFractionDivisor: Int = 5

    // Pool refill rules gathered into a static method that unit tests can call.

    static func shouldTriggerLoadMore(
        assetCount: Int,
        newIndex: Int,
        isSoloOnlyPlayback: Bool,
        soloOnlyRemainingTriggerCount: Int = 8
    ) -> Bool {
        guard assetCount > 0 else { return false }
        guard newIndex >= 0, newIndex < assetCount else { return false }

        if isSoloOnlyPlayback {
            let remainingAfterNewIndex = assetCount - newIndex - 1
            return remainingAfterNewIndex <= soloOnlyRemainingTriggerCount
        }

        // Normal mode still refills in the last 20%.
        let defaultTriggerIndex = assetCount - (assetCount / refillRemainingFractionDivisor)
        return newIndex >= defaultTriggerIndex
    }

    func sceneUsesSmartFillSlotReadiness(_ scene: PlaybackScene) -> Bool {
        guard let readback = scene.smartFillReadback else { return false }
        return readback.sceneType != .fallback
    }

    func sceneNeedsPreviewForPlayback(_ scene: PlaybackScene) -> Bool {
        !sceneUsesSmartFillSlotReadiness(scene)
    }

    func isSceneReadyForPlayback(_ scene: PlaybackScene) -> Bool {
        let needsPreview = sceneNeedsPreviewForPlayback(scene)
        return scene.photoSlots.allSatisfy { slot in
            downloadManager.isReady(assetId: slot.asset.id, size: .fullsize)
                && (!needsPreview || downloadManager.isReady(assetId: slot.asset.id, size: .preview))
        }
    }
}
