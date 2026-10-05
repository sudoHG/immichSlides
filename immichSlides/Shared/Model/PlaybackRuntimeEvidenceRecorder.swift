import Foundation

/// Observes values supplied by the facade; never owns playback, downloads or presentation policy.
@MainActor
final class PlaybackRuntimeEvidenceRecorder {
    struct SmartFillStartupRuntimeMetrics {
        let assetPoolSizeAtFirstPlan: Int
        let eligibleCandidateCountAtFirstPlan: Int
        let plannerAttemptCountAtFirstPlan: Int
        let candidateWindowUsedAtFirstPlan: Int
        let fallbackReasonTopList: String
        let rejectedLayoutReasonTopList: String
        let candidateRejectReasonTopList: String
        let lookaheadExhausted: Bool
        let fallbackRootCauseBucket: String
    }

    struct StartupSnapshot {
        let phaseTimestamps: [String: TimeInterval]
        let metrics: SmartFillStartupRuntimeMetrics?
    }

    var startupSnapshot: StartupSnapshot {
        StartupSnapshot(
            phaseTimestamps: smartFillStartupRuntimePhaseTimestamps, metrics: smartFillStartupRuntimeMetrics)
    }

    private var pendingSceneActionTimestamps: [UUID: TimeInterval] = [:]
    private let smartFillStartupRuntimePhaseOrder = [
        "playbackEntryRequested",
        "assetPoolRequestStarted",
        "assetPoolReady",
        "firstScenePlanningStarted",
        "firstScenePlanned",
        "firstScenePublished",
        "firstSlotReady",
        "allVisibleSlotsReady"
    ]
    private let smartFillPhotoLoadRuntimePhaseOrder = [
        "cacheChecked",
        "downloadRequestStarted",
        "downloadCompleted",
        "decodeCompleted",
        "firstImageDisplayed"
    ]
    private var smartFillStartupRuntimePhaseTimestamps: [String: TimeInterval] = [:]
    private var smartFillStartupRuntimeMetrics: SmartFillStartupRuntimeMetrics?
    private var scenePresentationDecodedCount = 0
    private var scenePresentationReadyCount = 0
    private var scenePresentationHiddenDecodeExcludedFromHistory = false
    private var scenePresentationVisibleTickCommittedHistory = false
    #if DEBUG
    private struct ScenePresentationProbeCrossfade {
        let outgoingID: String
        let incomingID: String
        let firstOutgoingProgress: Double
        var lastOutgoingProgress: Double
        var lowestOutgoingProgress: Double
        var highestOutgoingProgress: Double
        /// Largest share of the screen both photos showed at once, the outgoing one drawn below the incoming one; a
        /// switch without a blend never gets above zero.
        var peakBlendOpacity: Double
        var lastOutgoingOpacity: Double
        var didOutgoingProgressRewind: Bool
    }
    /// Never reset, so tests can compare them before and after an action.
    private var scenePresentationLowCoverageFrameCount = 0
    private var scenePresentationCrossfadeFrameCount = 0
    private var scenePresentationLastCrossfade: ScenePresentationProbeCrossfade?
    /// Same threshold as `SceneTransitionDiagnostic.minimumPhotoCoverage`: below half a photo the screen reads as empty.
    private static let scenePresentationProbeMinimumPhotoCoverage = 0.5
    /// Same tolerance as `SceneTransitionDiagnostic` uses for motion progress.
    private static let scenePresentationProbeProgressTolerance = 0.000_1
    #endif
    #if DEBUG
    private var qaPlaybackSequenceRecorder: PlaybackSequenceDebugRecorder?

    var displayedAssetRecordCount: Int {
        qaPlaybackSequenceRecorder?.displayedAssetRecordCount ?? 0
    }

    func recordPlaybackSequence(
        _ input: PlaybackSequenceDebugRecordInput,
        writesFile: Bool
    ) -> PlaybackSequenceDebugRecordResult? {
        ensureQAPlaybackSequenceRecorder(writesFile: writesFile)
        return qaPlaybackSequenceRecorder?.record(input)
    }

    func recordPlaybackSequenceEvent(
        _ event: PlaybackSequenceDebugEventInput,
        writesFile: Bool
    ) -> PlaybackSequenceDebugEventResult? {
        ensureQAPlaybackSequenceRecorder(writesFile: writesFile)
        return qaPlaybackSequenceRecorder?.recordEvent(event)
    }

    private func ensureQAPlaybackSequenceRecorder(writesFile: Bool) {
        if qaPlaybackSequenceRecorder == nil {
            qaPlaybackSequenceRecorder = PlaybackSequenceDebugRecorder(isEnabled: true, writesFile: writesFile)
        }
    }
    #endif

    func resetActionTimings() {
        pendingSceneActionTimestamps = [:]
    }

    func discardActionTimestamp(for transactionID: UUID) {
        pendingSceneActionTimestamps[transactionID] = nil
    }

    func recordActionTimestamp(_ timestamp: TimeInterval, for transactionID: UUID) {
        pendingSceneActionTimestamps = [transactionID: timestamp]
    }

    func takeActionTimestamp(for transactionID: UUID) -> TimeInterval? {
        pendingSceneActionTimestamps.removeValue(forKey: transactionID)
    }

    func resetScenePresentation() {
        scenePresentationDecodedCount = 0
        scenePresentationReadyCount = 0
        scenePresentationHiddenDecodeExcludedFromHistory = false
        scenePresentationVisibleTickCommittedHistory = false
        // Frame accumulation and sequence history intentionally outlive presentation resets.
    }

    func recordRendererDecoded() {
        scenePresentationDecodedCount += 1
    }

    func recordPresentationReadiness(isReady: Bool, historyUnchanged: Bool) {
        if isReady {
            scenePresentationReadyCount += 1
        }
        scenePresentationHiddenDecodeExcludedFromHistory = historyUnchanged
    }

    func recordVisibleTickCommittedHistory() {
        scenePresentationVisibleTickCommittedHistory = true
    }

    func resetSmartFillStartupRuntimeEvidence() {
        smartFillStartupRuntimePhaseTimestamps = [:]
        smartFillStartupRuntimeMetrics = nil
    }

    func shouldRecordStartupPhase(_ phase: String) -> Bool {
        smartFillStartupRuntimePhaseOrder.contains(phase) && smartFillStartupRuntimePhaseTimestamps[phase] == nil
    }

    func recordSmartFillStartupRuntimePhase(_ phase: String, at timestamp: TimeInterval) {
        guard smartFillStartupRuntimePhaseOrder.contains(phase),
            smartFillStartupRuntimePhaseTimestamps[phase] == nil
        else {
            return
        }
        smartFillStartupRuntimePhaseTimestamps[phase] = timestamp
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
    func smartFillStartupRuntimeSummaryParts(
        slotReadiness: String?,
        assetPoolSize: Int,
        photoLoadRecords: [AssetsDownloadManager.PhotoLoadRuntimeRecord]
    ) -> [String] {
        guard !smartFillStartupRuntimePhaseTimestamps.isEmpty else { return [] }

        let timestamps = smartFillStartupRuntimeTimestampsMilliseconds()
        let durations = smartFillStartupRuntimeDurationsMilliseconds(from: timestamps)
        let photoLoadSummary = smartFillPhotoLoadRuntimeSummary(records: photoLoadRecords)
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
            "assetPoolSizeAtFirstPlan=\(metrics?.assetPoolSizeAtFirstPlan ?? assetPoolSize)",
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

    /// The facade samples each missing phase separately, preserving the query-time clock reads.
    func startupReadinessPhasesToRecord(_ slotReadiness: String) -> [String] {
        let values = slotReadiness.split(separator: ",").map(String.init)
        guard !values.isEmpty else { return [] }
        var phases: [String] = []
        let hasReadySlot = values.contains("ready")
        if hasReadySlot {
            phases.append("firstSlotReady")
        }
        if values.allSatisfy({ $0 == "ready" || $0 == "pending" || $0 == "failed" }),
            hasReadySlot || smartFillStartupRuntimePhaseTimestamps["firstSlotReady"] != nil
        {
            phases.append("allVisibleSlotsReady")
        }
        return phases.filter { shouldRecordStartupPhase($0) }
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
        records: [AssetsDownloadManager.PhotoLoadRuntimeRecord]
    ) -> (
        timestamps: [String: Double], durations: [String: Double], cacheStatus: String, loadStatus: String,
        firstImageDisplayedRuntimeMs: Double
    ) {
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
    func scenePresentationContractProbeLabel(
        for snapshot: PlaybackSessionEngine.SceneRenderSnapshot,
        progressValues: [Double],
        historyCount: Int
    ) -> String {
        #if DEBUG
        let photoCoverage = 1 - snapshot.layers.reduce(1) { uncovered, layer in uncovered * (1 - layer.opacity) }
        if historyCount > 0,
            photoCoverage < Self.scenePresentationProbeMinimumPhotoCoverage
        {
            scenePresentationLowCoverageFrameCount += 1
        }
        recordScenePresentationCrossfadeFrame(snapshot, progress: progressValues)
        let lowCoverageFrameCount = scenePresentationLowCoverageFrameCount
        let crossfadeFrameCount = scenePresentationCrossfadeFrameCount
        let lastCrossfade =
            scenePresentationLastCrossfade.map { crossfade in
                let progress = [
                    crossfade.firstOutgoingProgress, crossfade.lastOutgoingProgress,
                    crossfade.lowestOutgoingProgress, crossfade.highestOutgoingProgress
                ].map { String(format: "%.6f", $0) }
                let blend = String(format: "%.6f", crossfade.peakBlendOpacity)
                let motion = crossfade.didOutgoingProgressRewind ? "rewound" : "steady"
                return "\(crossfade.outgoingID)>\(crossfade.incomingID)@\(progress[0])>\(progress[1])"
                    + "@\(progress[2])>\(progress[3])@\(blend)@\(motion)"
            } ?? "none"
        #else
        let lowCoverageFrameCount = 0
        let crossfadeFrameCount = 0
        let lastCrossfade = "none"
        #endif
        let roles = snapshot.layers.map { $0.role.rawValue }.joined(separator: "|")
        let layerIDs = snapshot.layers.map(\.identity.privateIdentifier).joined(separator: "|")
        let opacities = snapshot.layers.map { String(format: "%.6f", $0.opacity) }.joined(separator: "|")
        let progress = progressValues.map { String(format: "%.6f", $0) }.joined(separator: "|")
        return [
            "schemaVersion=scene-presentation-contract-probe-v1",
            "phase=\(snapshot.underlyingPhase.rawValue)",
            "layerRoles=\(roles.isEmpty ? "none" : roles)",
            "layerIDs=\(layerIDs.isEmpty ? "none" : layerIDs)",
            "layerOpacities=\(opacities.isEmpty ? "none" : opacities)",
            "motionRawProgress=\(progress.isEmpty ? "none" : progress)",
            "decodedCount=\(scenePresentationDecodedCount)",
            "presentationReadyCount=\(scenePresentationReadyCount)",
            "historyCount=\(historyCount)",
            "partialSlotVisible=\(snapshot.layers.contains { $0.opacity > 0 && !$0.isPresentationReady })",
            "loadingVisible=\(snapshot.underlyingPhase == .loading)",
            "playbackPaused=\(snapshot.suspensionReasons.contains(.userPaused))",
            "lowCoverageFrameCount=\(lowCoverageFrameCount)",
            "crossfadeFrameCount=\(crossfadeFrameCount)",
            "lastCrossfade=\(lastCrossfade)",
            "hiddenDecodeExcludedFromHistory=\(scenePresentationHiddenDecodeExcludedFromHistory)",
            "visibleTickCommittedHistory=\(scenePresentationVisibleTickCommittedHistory)"
        ].joined(separator: ";")
    }

    #if DEBUG
    /// Remembers a crossfade from one photo to another (one outgoing and one incoming layer): how the outgoing photo's
    /// motion moved while it was drawn, and whether both photos were ever visible together.
    private func recordScenePresentationCrossfadeFrame(
        _ snapshot: PlaybackSessionEngine.SceneRenderSnapshot,
        progress: [Double]
    ) {
        let outgoingIndices = snapshot.layers.indices.filter { snapshot.layers[$0].role == .outgoing }
        let incomingIndices = snapshot.layers.indices.filter { snapshot.layers[$0].role == .incoming }
        guard snapshot.underlyingPhase == .transition,
            outgoingIndices.count == 1, incomingIndices.count == 1,
            let outgoing = outgoingIndices.first, let incoming = incomingIndices.first
        else {
            return
        }
        scenePresentationCrossfadeFrameCount += 1
        let outgoingID = snapshot.layers[outgoing].identity.privateIdentifier
        let incomingID = snapshot.layers[incoming].identity.privateIdentifier
        let outgoingOpacity = snapshot.layers[outgoing].opacity
        let incomingOpacity = snapshot.layers[incoming].opacity
        let blend = min(incomingOpacity, outgoingOpacity * (1 - incomingOpacity))
        let outgoingProgress = progress[outgoing]
        guard var crossfade = scenePresentationLastCrossfade,
            crossfade.outgoingID == outgoingID, crossfade.incomingID == incomingID
        else {
            scenePresentationLastCrossfade = ScenePresentationProbeCrossfade(
                outgoingID: outgoingID,
                incomingID: incomingID,
                firstOutgoingProgress: outgoingProgress,
                lastOutgoingProgress: outgoingProgress,
                lowestOutgoingProgress: outgoingProgress,
                highestOutgoingProgress: outgoingProgress,
                peakBlendOpacity: blend,
                lastOutgoingOpacity: outgoingOpacity,
                didOutgoingProgressRewind: false
            )
            return
        }
        crossfade.lowestOutgoingProgress = min(crossfade.lowestOutgoingProgress, outgoingProgress)
        crossfade.highestOutgoingProgress = max(crossfade.highestOutgoingProgress, outgoingProgress)
        crossfade.peakBlendOpacity = max(crossfade.peakBlendOpacity, blend)
        // The outgoing photo only fades out, so only a dimmer frame is a later one; on iOS the root probe can report an
        // earlier moment than the frame-synchronized probe did, and once faded out the photo's motion is not seen.
        if outgoingOpacity < crossfade.lastOutgoingOpacity {
            if outgoingProgress < crossfade.lastOutgoingProgress - Self.scenePresentationProbeProgressTolerance {
                crossfade.didOutgoingProgressRewind = true
            }
            crossfade.lastOutgoingProgress = outgoingProgress
            crossfade.lastOutgoingOpacity = outgoingOpacity
        }
        scenePresentationLastCrossfade = crossfade
    }
    #endif

}
