import Foundation

extension PlaybackScene {
    @MainActor
    func smartFillRuntimeQADebugSummary(
        downloadManager: AssetsDownloadManager,
        controlBarVisible: Bool,
        exifOverlayVisible: Bool,
        publishReason: String,
        preparedHit: Bool
    ) -> String? {
        guard let readback = smartFillReadback else { return nil }

        let slotReadiness =
            photoSlots
            .map { slot in
                Self.runtimeReadinessLabel(
                    assetId: slot.asset.id,
                    downloadManager: downloadManager
                )
            }
            .joined(separator: ",")
        let ledgerSceneAssets = diagnosticSlotReferences(separator: ",")
        let retainedSummaryParts = readback.qaDebugSummary
            .split(separator: ";")
            .map(String.init)
            .filter { part in
                !Self.runtimeQADebugSummaryPrefixes.contains { part.hasPrefix($0) }
            }
        let runtimeSummaryParts = [
            "slotReadiness=\(slotReadiness)",
            "ledgerSceneAssets=\(ledgerSceneAssets)",
            "slotRefs=\(ledgerSceneAssets)",
            "controlBarVisible=\(controlBarVisible)",
            "exifOverlayVisible=\(exifOverlayVisible)",
            "publishReason=\(publishReason)",
            "preparedHit=\(preparedHit)"
        ]

        return (retainedSummaryParts + runtimeSummaryParts).joined(separator: ";")
    }

    func diagnosticSlotReferences(separator: String) -> String {
        photoSlots.map { "asset-\(Self.runtimeAssetLedgerHash($0.asset.id))" }
            .joined(separator: separator)
    }

    private static let runtimeQADebugSummaryPrefixes = [
        "slotReadiness=",
        "ledgerSceneAssets=",
        "slotRefs=",
        "controlBarVisible=",
        "exifOverlayVisible=",
        "publishReason=",
        "preparedHit="
    ]

    @MainActor
    private static func runtimeReadinessLabel(
        assetId: String,
        downloadManager: AssetsDownloadManager
    ) -> String {
        let readiness = PlaybackSmartFillSlotReadiness.resolve(
            assetId: assetId,
            fullsizeState: downloadManager.assetStates[assetId] ?? .notStarted,
            fullsizeURL: downloadManager.findURL(assetId: assetId, size: .fullsize)
        )

        switch readiness {
        case .ready:
            return "ready"
        case .pending:
            return "pending"
        case .failed:
            return "failed"
        }
    }

    private static func runtimeAssetLedgerHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
