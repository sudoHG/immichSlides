import Foundation

extension SlideShowViewModel {
    func playbackManifestTimestamp() -> TimeInterval {
        #if DEBUG
        if let playbackManifestTimestampProviderForTesting { return playbackManifestTimestampProviderForTesting() }
        #endif
        return Date().timeIntervalSince1970
    }

    func resetSmartFillStartupRuntimeEvidence() {
        runtimeEvidenceRecorder.resetSmartFillStartupRuntimeEvidence()
    }

    func recordSmartFillStartupRuntimePhase(_ phase: String) {
        guard runtimeEvidenceRecorder.shouldRecordStartupPhase(phase) else { return }
        runtimeEvidenceRecorder.recordSmartFillStartupRuntimePhase(phase, at: playbackManifestTimestamp())
    }

    func recordSmartFillStartupFirstPlanMetrics(
        assetPoolSize: Int,
        eligibleCandidateCount: Int,
        plannerResult: PlaybackSmartFillPlannerResult
    ) {
        runtimeEvidenceRecorder.recordSmartFillStartupFirstPlanMetrics(
            assetPoolSize: assetPoolSize,
            eligibleCandidateCount: eligibleCandidateCount,
            plannerResult: plannerResult
        )
    }

    #if DEBUG
    func currentSmartFillRuntimeQADebugSummary(
        controlBarVisible: Bool,
        exifOverlayVisible: Bool
    ) -> String? {
        guard let scene = safeCurrentScene else { return nil }
        let displayedLedgerEntry = playbackSessionEngine.displayedSceneRecords
            .reversed()
            .first { $0.sceneId == scene.id }
        guard
            let runtimeSummary = scene.smartFillRuntimeQADebugSummary(
                downloadManager: downloadManager,
                controlBarVisible: controlBarVisible,
                exifOverlayVisible: exifOverlayVisible,
                publishReason: displayedLedgerEntry?.source.rawValue ?? "initial",
                preparedHit: displayedLedgerEntry?.preparedHit ?? false
            )
        else { return nil }
        let slotReadiness = smartFillRuntimeSummaryField("slotReadiness", in: runtimeSummary)
        let startupSummaryParts = smartFillStartupRuntimeSummaryParts(
            scene: scene,
            slotReadiness: slotReadiness
        )
        guard !startupSummaryParts.isEmpty else {
            return runtimeSummary
        }
        return ([runtimeSummary] + startupSummaryParts).joined(separator: ";")
    }
    #endif
    #if DEBUG
    private func smartFillRuntimeSummaryField(_ key: String, in summary: String) -> String? {
        for part in summary.split(separator: ";") {
            guard let equalIndex = part.firstIndex(of: "="),
                part[..<equalIndex] == key
            else {
                continue
            }
            return String(part[part.index(after: equalIndex)...])
        }
        return nil
    }
    #endif

    func recordSmartFillFirstImageDisplayed(assetId: String) {
        downloadManager.recordFirstImageDisplayed(assetId: assetId, size: .fullsize)
    }

    #if DEBUG
    func recordSmartFillFirstImageDisplayedForTesting(assetId: String) {
        recordSmartFillFirstImageDisplayed(assetId: assetId)
    }
    #endif

    #if DEBUG
    private func smartFillStartupRuntimeSummaryParts(scene: PlaybackScene, slotReadiness: String?) -> [String] {
        if let slotReadiness {
            for phase in runtimeEvidenceRecorder.startupReadinessPhasesToRecord(slotReadiness) {
                recordSmartFillStartupRuntimePhase(phase)
            }
        }
        guard !runtimeEvidenceRecorder.startupSnapshot.phaseTimestamps.isEmpty else { return [] }
        let photoLoadRecords = scene.photoSlots.compactMap { slot in
            downloadManager.photoLoadRuntimeRecord(assetId: slot.asset.id, size: .fullsize)
        }
        return runtimeEvidenceRecorder.smartFillStartupRuntimeSummaryParts(
            slotReadiness: slotReadiness,
            assetPoolSize: assets.count,
            photoLoadRecords: photoLoadRecords
        )
    }
    #endif

    func recordActionTimestamp(
        _ timestamp: TimeInterval,
        for transition: PlaybackSessionTransition
    ) {
        runtimeEvidenceRecorder.recordActionTimestamp(timestamp, for: transition.transaction.id)
    }

    func recordScenePublishTiming(for transition: PlaybackSessionTransition) {
        guard let actionTimestamp = runtimeEvidenceRecorder.takeActionTimestamp(for: transition.transaction.id) else {
            return
        }
        let scenePublishTimestamp = playbackManifestTimestamp()
        playbackSessionEngine.updateCurrentScene { scene in
            guard scene.id == transition.scene.id,
                let readback = scene.smartFillReadback
            else {
                return scene
            }
            return scene.replacingSmartFillReadback(
                readback.recordingPublishTiming(
                    actionTimestamp: actionTimestamp,
                    scenePublishTimestamp: scenePublishTimestamp
                )
            )
        }
    }
}
