import Foundation
import Combine
import CryptoKit
import CoreGraphics
import OSLog

extension SlideShowViewModel {
    func playbackManifestTimestamp() -> TimeInterval {
        #if DEBUG
        if let playbackManifestTimestampProviderForTesting { return playbackManifestTimestampProviderForTesting() }
        #endif
        return Date().timeIntervalSince1970
    }

    func resetSmartFillStartupRuntimeEvidence() {
        smartFillStartupRuntimePhaseTimestamps = [:]
        smartFillStartupRuntimeMetrics = nil
    }

    func recordSmartFillStartupRuntimePhase(_ phase: String) {
        guard smartFillStartupRuntimePhaseOrder.contains(phase),
            smartFillStartupRuntimePhaseTimestamps[phase] == nil
        else {
            return
        }
        smartFillStartupRuntimePhaseTimestamps[phase] = playbackManifestTimestamp()
    }

    func recordSmartFillStartupFirstPlanMetrics(
        assetPoolSize: Int,
        eligibleCandidateCount: Int,
        plannerResult: PlaybackSmartFillPlannerResult
    ) {
        guard smartFillStartupRuntimeMetrics == nil else { return }

        let rejectedLayoutReasonTopList = plannerResult.rejectedLayoutReasonTopList
            .map(\.rawValue)
            .joined(separator: ",")
        let safeRejectedLayoutReasonTopList = rejectedLayoutReasonTopList.isEmpty ? "none" : rejectedLayoutReasonTopList
        let candidateRejectReasonTopList = plannerResult.rejectReasonsTried
            .map(\.rawValue)
            .joined(separator: ",")
        let safeCandidateRejectReasonTopList =
            candidateRejectReasonTopList.isEmpty ? "none" : candidateRejectReasonTopList
        let fallbackReasonTopList = plannerResult.fallbackReason?.rawValue ?? "none"
        let lookaheadExhausted = plannerResult.rejectReasonsTried.contains(.candidateWindowExhausted)

        smartFillStartupRuntimeMetrics = SmartFillStartupRuntimeMetrics(
            assetPoolSizeAtFirstPlan: assetPoolSize,
            eligibleCandidateCountAtFirstPlan: eligibleCandidateCount,
            plannerAttemptCountAtFirstPlan: plannerResult.evaluationCount,
            candidateWindowUsedAtFirstPlan: plannerResult.candidateWindowUsed,
            fallbackReasonTopList: fallbackReasonTopList,
            rejectedLayoutReasonTopList: safeRejectedLayoutReasonTopList,
            candidateRejectReasonTopList: safeCandidateRejectReasonTopList,
            lookaheadExhausted: lookaheadExhausted,
            fallbackRootCauseBucket: smartFillFallbackRootCauseBucket(
                fallbackReason: plannerResult.fallbackReason,
                fallbackCategory: plannerResult.fallbackCategory,
                rejectReasons: plannerResult.rejectReasonsTried
            )
        )
    }

    private func smartFillFallbackRootCauseBucket(
        fallbackReason: PlaybackSmartFillFallbackReason?,
        fallbackCategory: PlaybackSmartFillFallbackCategory,
        rejectReasons: [PlaybackSmartFillPlannerRejectReason]
    ) -> String {
        guard let fallbackReason,
            fallbackReason != PlaybackSmartFillFallbackReason.none,
            fallbackCategory != .none
        else {
            return "none"
        }
        if rejectReasons.contains(.candidateWindowExhausted) {
            return "candidate-window-exhausted"
        }
        if rejectReasons.contains(.cropRetentionTooLow) {
            return "crop-retention-reject"
        }
        if rejectReasons.contains(.protectionOverlap) || rejectReasons.contains(.faceCropDestroyed) {
            return "protection-reject"
        }
        if rejectReasons.contains(.layoutCanvasNotFilled) {
            return "full-canvas-invariant-reject"
        }
        switch fallbackReason {
        case .missingCandidates:
            return "metadata-insufficient"
        case .allLayoutsRejected:
            return "layout-policy-no-match"
        case .imageNotReady:
            return "resource-readiness-misclassified"
        case .none:
            return "none"
        }
    }

    #if DEBUG
    func smartFillRuntimeSummaryField(_ key: String, in summary: String) -> String? {
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
    func smartFillStartupRuntimeSummaryParts(
        scene: PlaybackScene,
        slotReadiness: String?
    ) -> [String] {
        if let slotReadiness {
            recordSmartFillStartupReadinessPhases(slotReadiness)
        }
        guard !smartFillStartupRuntimePhaseTimestamps.isEmpty else { return [] }

        let timestamps = smartFillStartupRuntimeTimestampsMilliseconds()
        let durations = smartFillStartupRuntimeDurationsMilliseconds(from: timestamps)
        let photoLoadSummary = smartFillPhotoLoadRuntimeSummary(for: scene)
        let missingPhases = smartFillStartupRuntimePhaseOrder.filter { timestamps[$0] == nil }
        let metrics = smartFillStartupRuntimeMetrics
        let slotReadinessValues =
            slotReadiness?
            .split(separator: ",")
            .map(String.init) ?? []
        let readinessField = slotReadiness ?? "missing"

        return [
            "runtimePhaseTimestampsMs=\(smartFillFormattedPhaseMap(timestamps))",
            "runtimePhaseDurationsMs=\(smartFillFormattedPhaseMap(durations))",
            "startupMissingPhases=\(missingPhases.isEmpty ? "none" : missingPhases.joined(separator: ","))",
            "startupBlockingPhase=\(smartFillStartupBlockingPhase(in: durations))",
            "assetPoolSizeAtFirstPlan=\(metrics?.assetPoolSizeAtFirstPlan ?? assets.count)",
            "eligibleCandidateCountAtFirstPlan=\(metrics?.eligibleCandidateCountAtFirstPlan ?? 0)",
            "plannerAttemptCountAtFirstPlan=\(metrics?.plannerAttemptCountAtFirstPlan ?? 0)",
            "candidateWindowUsedAtFirstPlan=\(metrics?.candidateWindowUsedAtFirstPlan ?? 0)",
            "firstSceneSlotReadiness=\(readinessField)",
            "firstSceneReadySlotCount=\(smartFillReadinessCount("ready", in: slotReadinessValues))",
            "firstScenePendingSlotCount=\(smartFillReadinessCount("pending", in: slotReadinessValues))",
            "firstSceneFailedSlotCount=\(smartFillReadinessCount("failed", in: slotReadinessValues))",
            "photoLoadPhaseTimestampsMs=\(smartFillFormattedPhotoLoadPhaseMap(photoLoadSummary.timestamps))",
            "photoLoadPhaseDurationsMs=\(smartFillFormattedPhotoLoadPhaseMap(photoLoadSummary.durations))",
            "firstPhotoCacheStatus=\(photoLoadSummary.cacheStatus)",
            "firstImageDisplayedRuntimeMs=\(smartFillFormattedMilliseconds(photoLoadSummary.firstImageDisplayedRuntimeMs))",
            "firstImageLoadStatus=\(photoLoadSummary.loadStatus)",
            "fallbackReasonTopList=\(metrics?.fallbackReasonTopList ?? "none")",
            "candidateRejectReasonTopList=\(metrics?.candidateRejectReasonTopList ?? "none")",
            "lookaheadExhausted=\((metrics?.lookaheadExhausted ?? false) ? "true" : "false")",
            "resourceReadinessAffectedFallback=\(metrics?.fallbackRootCauseBucket == "resource-readiness-misclassified")",
            "controlBarAffectedFallback=false",
            "legacyRendererUsedForSmartFillFallback=false",
            "fallbackRootCauseBucket=\(metrics?.fallbackRootCauseBucket ?? "none")"
        ]
    }

    private func recordSmartFillStartupReadinessPhases(_ slotReadiness: String) {
        let values = slotReadiness.split(separator: ",").map(String.init)
        guard !values.isEmpty else { return }
        let hasReadySlot = values.contains("ready")
        if hasReadySlot {
            recordSmartFillStartupRuntimePhase("firstSlotReady")
        }
        if values.allSatisfy({ $0 == "ready" || $0 == "pending" || $0 == "failed" }),
            hasReadySlot || smartFillStartupRuntimePhaseTimestamps["firstSlotReady"] != nil
        {
            recordSmartFillStartupRuntimePhase("allVisibleSlotsReady")
        }
    }

    private func smartFillStartupRuntimeTimestampsMilliseconds() -> [String: Double] {
        guard
            let entryTimestamp = smartFillStartupRuntimePhaseTimestamps["playbackEntryRequested"]
                ?? smartFillStartupRuntimePhaseTimestamps.values.min()
        else {
            return [:]
        }
        return smartFillStartupRuntimePhaseTimestamps.reduce(into: [String: Double]()) { result, entry in
            result[entry.key] = max(0, (entry.value - entryTimestamp) * 1000)
        }
    }

    private func smartFillStartupRuntimeDurationsMilliseconds(from timestamps: [String: Double]) -> [String: Double] {
        var result: [String: Double] = [:]
        var previousTimestamp: Double?
        for phase in smartFillStartupRuntimePhaseOrder {
            guard let timestamp = timestamps[phase] else { continue }
            result[phase] = max(0, timestamp - (previousTimestamp ?? timestamp))
            previousTimestamp = timestamp
        }
        return result
    }

    private func smartFillStartupBlockingPhase(in durations: [String: Double]) -> String {
        smartFillStartupRuntimePhaseOrder
            .compactMap { phase -> (String, Double)? in
                guard let duration = durations[phase] else { return nil }
                return (phase, duration)
            }
            .max { lhs, rhs in lhs.1 < rhs.1 }?
            .0 ?? "none"
    }

    private func smartFillFormattedPhaseMap(_ values: [String: Double]) -> String {
        smartFillStartupRuntimePhaseOrder
            .compactMap { phase -> String? in
                guard let value = values[phase] else { return nil }
                return "\(phase):\(String(format: "%.3f", value))"
            }
            .joined(separator: ",")
    }

    private func smartFillReadinessCount(_ readiness: String, in values: [String]) -> Int {
        values.filter { $0 == readiness }.count
    }

    private func smartFillPhotoLoadRuntimeSummary(
        for scene: PlaybackScene
    ) -> (
        timestamps: [String: Double], durations: [String: Double], cacheStatus: String, loadStatus: String,
        firstImageDisplayedRuntimeMs: Double
    ) {
        let records = scene.photoSlots.compactMap { slot -> AssetsDownloadManager.PhotoLoadRuntimeRecord? in
            downloadManager.photoLoadRuntimeRecord(assetId: slot.asset.id, size: .fullsize)
        }
        let selectedRecord =
            records
            .filter { $0.phaseTimestamps["firstImageDisplayed"] != nil }
            .min { lhs, rhs in
                (lhs.phaseTimestamps["firstImageDisplayed"] ?? .greatestFiniteMagnitude)
                    < (rhs.phaseTimestamps["firstImageDisplayed"] ?? .greatestFiniteMagnitude)
            } ?? records.first

        guard let selectedRecord else {
            return ([:], [:], "missing", "missing", 0)
        }

        let timestamps = smartFillPhotoLoadTimestampsMilliseconds(from: selectedRecord.phaseTimestamps)
        return (
            timestamps,
            smartFillPhotoLoadDurationsMilliseconds(from: timestamps),
            selectedRecord.cacheStatus,
            selectedRecord.loadStatus,
            timestamps["firstImageDisplayed"] ?? 0
        )
    }

    private func smartFillPhotoLoadTimestampsMilliseconds(from rawTimestamps: [String: TimeInterval]) -> [String:
        Double]
    {
        guard
            let entryTimestamp = smartFillStartupRuntimePhaseTimestamps["playbackEntryRequested"]
                ?? smartFillStartupRuntimePhaseTimestamps.values.min()
        else {
            return [:]
        }
        return rawTimestamps.reduce(into: [String: Double]()) { result, entry in
            guard smartFillPhotoLoadRuntimePhaseOrder.contains(entry.key) else { return }
            result[entry.key] = max(0, (entry.value - entryTimestamp) * 1000)
        }
    }

    private func smartFillPhotoLoadDurationsMilliseconds(from timestamps: [String: Double]) -> [String: Double] {
        var result: [String: Double] = [:]
        var previousTimestamp: Double?
        for phase in smartFillPhotoLoadRuntimePhaseOrder {
            guard let timestamp = timestamps[phase] else { continue }
            result[phase] = max(0, timestamp - (previousTimestamp ?? timestamp))
            previousTimestamp = timestamp
        }
        return result
    }

    private func smartFillFormattedPhotoLoadPhaseMap(_ values: [String: Double]) -> String {
        smartFillPhotoLoadRuntimePhaseOrder
            .compactMap { phase -> String? in
                guard let value = values[phase] else { return nil }
                return "\(phase):\(smartFillFormattedMilliseconds(value))"
            }
            .joined(separator: ",")
    }

    private func smartFillFormattedMilliseconds(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    #endif
    func recordActionTimestamp(
        _ timestamp: TimeInterval,
        for transition: PlaybackSessionTransition
    ) {
        pendingSceneActionTimestamps = [transition.transaction.id: timestamp]
    }

    func recordScenePublishTiming(for transition: PlaybackSessionTransition) {
        guard let actionTimestamp = pendingSceneActionTimestamps.removeValue(forKey: transition.transaction.id) else {
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
