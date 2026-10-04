//
//  SlideShowViewModel.swift
//  immichSlides
//
//  Created by sudoHG on 2026/1/25.
//

import Foundation
import Combine
import CryptoKit
import CoreGraphics
import OSLog

enum PlaybackHistoryLedgerLimits {
    static let retainedEntryLimit = 1_000
}

struct PlaybackHistoryLedgerEntry {
    let scene: PlaybackScene
}

struct PlaybackHistoryLedger {
    private(set) var entries: [PlaybackHistoryLedgerEntry] = []
    private(set) var cursor: Int?
    let retainedEntryLimit: Int

    init(retainedEntryLimit: Int = PlaybackHistoryLedgerLimits.retainedEntryLimit) {
        self.retainedEntryLimit = max(1, retainedEntryLimit)
    }

    var isAtTail: Bool {
        guard let cursor else { return true }
        return cursor >= entries.count - 1
    }

    var currentTarget: (index: Int, entry: PlaybackHistoryLedgerEntry)? {
        guard let cursor, entries.indices.contains(cursor) else { return nil }
        return (cursor, entries[cursor])
    }

    var previousTarget: (index: Int, entry: PlaybackHistoryLedgerEntry)? {
        guard let cursor, cursor > 0 else { return nil }
        let index = cursor - 1
        return (index, entries[index])
    }

    var redoTarget: (index: Int, entry: PlaybackHistoryLedgerEntry)? {
        guard let cursor, cursor + 1 < entries.count else { return nil }
        let index = cursor + 1
        return (index, entries[index])
    }

    mutating func reset(with scene: PlaybackScene?) {
        if let scene {
            entries = [PlaybackHistoryLedgerEntry(scene: scene)]
            cursor = 0
        } else {
            entries = []
            cursor = nil
        }
    }

    mutating func append(_ scene: PlaybackScene) {
        entries.append(PlaybackHistoryLedgerEntry(scene: scene))
        cursor = entries.count - 1
        trimIfNeeded()
    }

    mutating func moveCursor(to index: Int) {
        guard entries.indices.contains(index) else { return }
        cursor = index
    }

    mutating func replaceCurrent(with scene: PlaybackScene) {
        guard let cursor, entries.indices.contains(cursor) else { return }
        entries[cursor] = PlaybackHistoryLedgerEntry(scene: scene)
    }

    private mutating func trimIfNeeded() {
        guard entries.count > retainedEntryLimit else { return }
        let removeCount = entries.count - retainedEntryLimit
        entries.removeFirst(removeCount)
        if let cursor {
            self.cursor = max(0, cursor - removeCount)
        }
    }
}

private enum PlaybackHistoryLedgerPendingCommit {
    case moveCursor(Int)
    case appendTail
}

enum SmartFillMainActorPlannerCallSite: String, CaseIterable, Sendable {
    case initialPlanning
    case manualNext
    case autoplayNext
    case requestScene
    case displayModeProtectionRebuild
    case initialSmartFillRebuild
}

@MainActor
class SlideShowViewModel: ObservableObject {
    private static let maximumPlaybackPoolAssetCount: Int = 200
    private static let standardPlaybackFetchAssetCount: Int = 100
    private static let initialSoloOnlyPoolAssetCount: Int = 12
    private static let soloOnlyRefillAssetCount: Int = 24
    private static let autoplayRenderWindowRadius: Int = 1
    private static let manualRenderWindowRadius: Int = 2
    private static let identifierDigestPrefixBytes: Int = 8
    private static let refillRemainingFractionDivisor: Int = 5
    private static let surfaceActivationDelayNanoseconds: UInt64 = 250_000_000
    private static let diagnosticHistoryLookbackCount: Int = 8

    private enum ResolvePhase {
        case initial
        case loadMore
    }

    private struct SmartFillScenePlan {
        let scene: PlaybackScene
        let nextCandidateCursorOffset: Int
        let displayedAssetIds: Set<String>
    }

    private struct SmartFillStartupRuntimeMetrics {
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

    @Published var assets: [Asset] = []
    // The current display position is only read back from the engine; views cannot change playback facts directly.
    @Published private(set) var currentIndex: Int = 0
    // The target position is an adapter readout of the pending transition.
    @Published private(set) var targetIndex: Int = 0
    // The slide-change trigger uses the transition identity, so a reused numeric index does not hide a new scene.
    @Published private(set) var targetTransitionToken: UUID = UUID()

    @Published var isLoading: Bool = true

    @Published var isLoadingMore: Bool = false

    @Published private(set) var emptyPlaybackMessage: String? = nil

    @Published var maxAssetCount: Int = SlideShowViewModel.maximumPlaybackPoolAssetCount

    @Published var isAutoPlay: Bool = true

    @Published var autoPlayInterval: Double = PlaybackIntervalPolicy.minimumInterval

    private var source: PlaybackSource
    private let playbackSettingsStore: PlaybackSettingsStore
    private var playbackSettingsChangeObserver: NSObjectProtocol?

    private let resolver: PlaybackPoolResolver

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "immichSlides",
        category: "Playback"
    )
    #if DEBUG
    private let qaPlaybackSequenceLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "immichSlides",
        category: "QAPlaybackSequence"
    )
    #endif
    private var playbackSessionEngine = PlaybackSessionEngine()
    private var playbackHistoryLedger = PlaybackHistoryLedger()
    private var pendingPlaybackHistoryLedgerCommits: [UUID: PlaybackHistoryLedgerPendingCommit] = [:]
    private var candidateCursorIndex: Int = 0
    private var pendingCandidateCursorIndexAfterCommit: Int?
    private var smartFillDisplayedAssetIds: Set<String> = []
    private var pendingSmartFillDisplayedAssetIdsAfterCommit: Set<String>?
    private var pendingSmartFillCursorResumeAfterLoadMoreAssetCount: Int?
    private var playbackDisplayMode: PlaybackDisplayMode = .smartFill
    private var pendingSceneActionTimestamps: [UUID: TimeInterval] = [:]
    private var smartFillSurface: PlaybackSmartFillSurface?
    private var smartFillProtectionSnapshot: PlaybackProtectionSnapshot = .empty
    private var smartFillReplanFingerprint: String?
    private var smartFillSurfaceActivationTask: Task<Void, Never>?
    private var smartFillPreparedRingRefreshTask: Task<Void, Never>?
    private var smartFillPreparedRingRefreshGeneration: UUID?
    private struct ScenePresentationWakeUpKey: Equatable {
        let generation: UUID
        let deadline: TimeInterval
    }
    private var scenePresentationPrerenderBarrier = ScenePresentationPrerenderBarrier()
    private var scenePresentationWakeUpTask: Task<Void, Never>?
    private var scenePresentationWakeUpKey: ScenePresentationWakeUpKey?
    private var scenePresentationEffectTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingAutomaticScenePlanGeneration: UUID?
    @Published private(set) var scenePresentationRevision = UUID()
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
    private var smartFillMotionPreparedSlotPreloadTasks: [UUID: Task<Void, Never>] = [:]
    private struct SmartFillMotionLookaheadPreparedPlan {
        let request: SmartFillPreparedPlanRequest
        let result: SmartFillPreparedPlanResult
    }
    private var smartFillMotionLookaheadPreparedPlan: SmartFillMotionLookaheadPreparedPlan?
    #if DEBUG
    private var smartFillCandidateSummaryBuildCountForTestingStorage: Int = 0
    private var smartFillMainActorPlannerCallCountsForTesting: [SmartFillMainActorPlannerCallSite: Int] = [:]
    #endif
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
    #if DEBUG
    private var qaPlaybackSequenceRecorder: PlaybackSequenceDebugRecorder?
    var qaPlaybackSequenceEvidenceEnabledForTesting: Bool = false
    var qaPlaybackSequenceOSLogEmitterForTesting: ((String) -> Void)? = nil
    #endif

    var renderCount: Int {  // Autoplay window: 1 on each side; manual: 2 on each side.
        isAutoPlay ? Self.autoplayRenderWindowRadius : Self.manualRenderWindowRadius
    }
    var playbackScenes: [PlaybackScene] {
        playbackSessionEngine.scenes
    }
    #if DEBUG
    var smartFillCandidateCursorIndexForTesting: Int {
        candidateCursorIndex
    }

    var pendingPlaybackHistoryLedgerCommitCountForTesting: Int {
        pendingPlaybackHistoryLedgerCommits.count
    }

    var activeScenePresentationBarrierForTesting: ScenePresentationLayerIdentity? {
        scenePresentationPrerenderBarrier.activeScene
    }

    /// Counts prerender barrier attempts, so tests can tell a kept barrier from a restarted one.
    private(set) var scenePresentationBarrierAttemptCountForTesting = 0

    var pendingSmartFillCursorResumeAfterLoadMoreAssetCountForTesting: Int? {
        pendingSmartFillCursorResumeAfterLoadMoreAssetCount
    }

    func markCurrentSmartFillPoolConsumedForTesting(candidateCursorIndex: Int = 0) {
        smartFillDisplayedAssetIds = Set(assets.map(\.id))
        self.candidateCursorIndex = min(max(0, candidateCursorIndex), max(0, assets.count - 1))
        pendingCandidateCursorIndexAfterCommit = nil
        pendingSmartFillDisplayedAssetIdsAfterCommit = nil
        pendingSmartFillCursorResumeAfterLoadMoreAssetCount = nil
    }
    #endif
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
    func scene(at index: Int) -> PlaybackScene? {
        if playbackSessionEngine.pendingTransition?.targetIndex == index {
            return playbackSessionEngine.pendingTransition?.scene
        }
        guard index >= 0, index < playbackSessionEngine.scenes.count else { return nil }
        return playbackSessionEngine.scenes[index]
    }
    var safeCurrentScene: PlaybackScene? {
        scene(at: currentIndex)
    }
    var canRequestPreviousScene: Bool {
        canCancelUnseenPendingScenePresentation || playbackHistoryLedger.previousTarget != nil
    }
    var sceneRenderSnapshot: PlaybackSessionEngine.SceneRenderSnapshot {
        playbackSessionEngine.sceneRenderSnapshot(at: scenePresentationTimestamp())
    }
    func scene(
        for layer: PlaybackSessionEngine.SceneRenderLayer
    ) -> PlaybackScene? {
        playbackSessionEngine.scene(for: layer.identity)
    }
    func scenePresentationLayerIdentity(
        for layer: PlaybackSessionEngine.SceneRenderLayer
    ) -> ScenePresentationLayerIdentity {
        ScenePresentationLayerIdentity(
            generation: layer.identity.generation,
            sceneID: layer.identity.sceneID,
            layerID: "scene-root"
        )
    }
    func isScenePresentationBarrierComplete(
        for layer: PlaybackSessionEngine.SceneRenderLayer
    ) -> Bool {
        scenePresentationPrerenderBarrier.activeScene == scenePresentationLayerIdentity(for: layer)
            && scenePresentationPrerenderBarrier.isPresentationReady
    }

    /// Pass only the active barrier's attempt to its renderer; other layers' callbacks cannot advance this barrier.
    func scenePresentationRendererAttemptID(
        for layer: PlaybackSessionEngine.SceneRenderLayer
    ) -> UUID? {
        guard scenePresentationPrerenderBarrier.activeScene == scenePresentationLayerIdentity(for: layer) else {
            return nil
        }
        return scenePresentationPrerenderBarrier.activeRendererAttemptID
    }
    var isSmartFillPresentationModeActive: Bool {
        playbackDisplayMode == .smartFill && !PlatformCompat.forceSinglePhotoPlaybackForDebug
    }
    func updateSmartFillMotionReduceMotionEnabled(_ isEnabled: Bool) {
        executeScenePresentationEffects(
            playbackSessionEngine.reduceScenePresentation(
                .reduceMotionChanged(isEnabled),
                at: scenePresentationTimestamp()
            )
        )
        publishScenePresentationChange()
    }
    /// Motion is planned to stay coverage-safe only within the scene's longest visible window. A photo held longer,
    /// while a manual target is still loading, rests at the end of that motion instead of extrapolating past it.
    nonisolated static func renderedMotionActiveTime(
        of layer: PlaybackSessionEngine.SceneRenderLayer,
        lifecycle: SceneLifecycleContract
    ) -> TimeInterval {
        min(layer.motionActiveTime, lifecycle.longestVisibleMotionDuration)
    }

    func motionRuntimeContext(
        for layer: PlaybackSessionEngine.SceneRenderLayer,
        platform: MotionPlatform,
        isReduceMotionEnabled: Bool
    ) -> MotionRuntimeContext? {
        guard let scene = playbackSessionEngine.scene(for: layer.identity),
            let target = playbackSessionEngine.presentationTarget(for: layer.identity)
        else {
            return nil
        }
        let renderRole = MotionRenderRole(scenePresentationLayerRole: layer.role)
        let eligibility = motionEligibility(
            scene: scene,
            renderRole: renderRole,
            platform: platform,
            isReduceMotionEnabled: isReduceMotionEnabled
        )
        let isSinglePhoto = playbackDisplayMode == .singlePhoto || PlatformCompat.forceSinglePhotoPlaybackForDebug
        let canRenderFrozenTransform =
            isReduceMotionEnabled && layer.isMotionEnabled
            && (isSinglePhoto
                || motionEligibility(
                    scene: scene,
                    renderRole: renderRole,
                    platform: platform,
                    isReduceMotionEnabled: false
                ).isTransformEnabled)
        return MotionRuntimeContext(
            sceneId: scene.id,
            renderRole: renderRole,
            lifecycle: target.lifecycle,
            motionActiveTime: Self.renderedMotionActiveTime(of: layer, lifecycle: target.lifecycle),
            isMotionEnabled: layer.isMotionEnabled
                && (isSinglePhoto || eligibility.isTransformEnabled || canRenderFrozenTransform),
            isReduceMotionEnabled: isReduceMotionEnabled
        )
    }
    #if DEBUG
    var smartFillMotionProbeDebugFieldsForTesting: [String: String] {
        var fields: [String: String] = [:]
        if let targetIndex = playbackSessionEngine.preparedSceneRing?.next?.targetIndex {
            fields["preparedNextTargetIndex"] = String(targetIndex)
        } else {
            fields["preparedNextTargetIndex"] = "none"
        }
        if let sourceCursor = playbackSessionEngine.preparedSceneRing?.next?.cursorEffect?.sourceCursor {
            fields["preparedNextSourceCursor"] = String(sourceCursor)
        } else {
            fields["preparedNextSourceCursor"] = "none"
        }
        if let currentSourceCursor = currentPreparedSmartFillSourceCursor() {
            fields["currentPreparedSourceCursor"] = String(currentSourceCursor)
        } else {
            fields["currentPreparedSourceCursor"] = "none"
        }
        if let lookaheadSourceCursor = smartFillMotionLookaheadPreparedPlan?.request.candidateCursor {
            fields["lookaheadCachedSourceCursor"] = String(lookaheadSourceCursor)
        } else {
            fields["lookaheadCachedSourceCursor"] = "none"
        }
        if let selectedCount = smartFillMotionLookaheadPreparedPlan?.result.selectedAssetIds.count {
            fields["lookaheadCachedSelectedCount"] = String(selectedCount)
        } else {
            fields["lookaheadCachedSelectedCount"] = "none"
        }
        return fields
    }

    #endif
    var visibleImageAssetId: String? {
        sceneRenderSnapshot.layers
            .last { layer in
                layer.opacity > 0 && (layer.role == .incoming || layer.role == .stable)
            }?
            .identity
            .assetID
    }
    var visibleImageAssetIdProbeLabel: String {
        visibleImageAssetId ?? "no-asset"
    }
    var visibleOverlayState: PlaybackVisibleOverlayState? {
        guard let visibleScene = playbackSessionEngine.currentScene else { return nil }
        return PlaybackVisibleOverlayState(
            ownerSceneId: visibleScene.id,
            ownerPrimaryAssetId: visibleScene.primaryAssetId
        )
    }
    #if DEBUG
    @Published private(set) var playbackImageCachePersistenceSnapshot = PlaybackImageCachePersistenceSnapshot(
        checkSequence: 0,
        activeTaskCount: 0,
        readyFullsizeCount: 0,
        diskReadyFullsizeCount: 0,
        readyPreviewCount: 0,
        diskReadyPreviewCount: 0
    )
    private var playbackImageCachePersistenceCheckSequence = 0

    var playbackImageRequestLifecycleSummaryJSON: String {
        let summary = downloadManager.playbackImageRequestLifecycleSummary()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(summary),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }

    func flushPlaybackImageRequestLifecycleEvidenceForDiagnostics() {
        downloadManager.flushPlaybackImageRequestLifecycleEvidenceForDiagnostics()
    }

    var playbackImageCachePersistenceSnapshotJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(playbackImageCachePersistenceSnapshot),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }

    func checkPlaybackImageCachePersistenceForDiagnostics() {
        playbackImageCachePersistenceCheckSequence += 1
        let checkSequence = playbackImageCachePersistenceCheckSequence
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.downloadManager.playbackImageCachePersistenceSnapshotForDiagnostics(
                checkSequence: checkSequence
            )
            guard checkSequence == self.playbackImageCachePersistenceCheckSequence else { return }
            self.playbackImageCachePersistenceSnapshot = snapshot
        }
    }

    var playbackHistoryLedgerDiagnosticsSummaryJSON: String {
        let suffixPrimaryAssetIds = playbackHistoryLedger.entries.suffix(Self.diagnosticHistoryLookbackCount).map {
            entry in
            entry.scene.primaryAssetId ?? "nil"
        }
        let currentPrimaryAssetId: String
        if let cursor = playbackHistoryLedger.cursor,
            playbackHistoryLedger.entries.indices.contains(cursor)
        {
            currentPrimaryAssetId = playbackHistoryLedger.entries[cursor].scene.primaryAssetId ?? "nil"
        } else {
            currentPrimaryAssetId = "nil"
        }
        let object: [String: Any] = [
            "schemaVersion": "playback-history-ledger-diagnostics-v1",
            "entryCount": playbackHistoryLedger.entries.count,
            "cursor": playbackHistoryLedger.cursor.map { $0 as Any } ?? NSNull(),
            "canPrevious": playbackHistoryLedger.previousTarget != nil,
            "canRedo": playbackHistoryLedger.redoTarget != nil,
            "currentPrimaryAssetId": currentPrimaryAssetId,
            "suffixPrimaryAssetIds": suffixPrimaryAssetIds
        ]
        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }
    #endif
    var visibleOverlayScene: PlaybackScene? {
        visibleOverlayScene(in: sceneRenderSnapshot)
    }
    func visibleOverlayScene(
        in snapshot: PlaybackSessionEngine.SceneRenderSnapshot
    ) -> PlaybackScene? {
        // Pick the EXIF owner by each rendered layer's actual contribution; visibleOverlayState still manages the
        // playback pool anchor.
        let backToFront =
            snapshot.layers.filter { $0.role == .outgoing } + snapshot.layers.filter { $0.role != .outgoing }
        var transmission = 1.0
        var greatestWeight = 0.0
        var owner: PlaybackSessionEngine.SceneRenderLayer?
        for layer in backToFront.reversed() {
            let weight = layer.opacity * transmission
            if weight > 0, weight >= greatestWeight {
                owner = layer
                greatestWeight = weight
            }
            transmission *= 1 - layer.opacity
        }
        guard let owner = owner ?? backToFront.last(where: { $0.role == .outgoing }) else {
            return nil
        }
        return scene(for: owner)
    }
    var visibleOverlayAsset: Asset? {
        visibleOverlayScene?.primaryAsset
    }
    var overlayAssetIdProbeLabel: String {
        guard let overlayState = visibleOverlayState else { return "no-overlay" }
        return overlayState.ownerPrimaryAssetId ?? "no-asset"
    }

    var safeCurrentAsset: Asset? {
        safeCurrentScene?.primaryAsset
    }

    var preloadCount: Int {
        isAutoPlay ? 3 : 5  // Manual navigation may move faster, so preload more.
    }

    let downloadManager: AssetsDownloadManager = AssetsDownloadManager.shared
    // In soloOnly, refill the pool when <= 8 remain instead of waiting for the last 20%; Vision re-checks are slower.

    private let soloOnlyLoadMoreRemainingTriggerCount: Int = 8
    private let smartFillCandidateWindowCount: Int = 36

    @Published private(set) var autoPlayRecoveryMessage: String? = nil
    var smartFillMotionPreparedSlotPreloadHookForTesting: (([String]) -> Void)? = nil
    // Handle for the first preload task, to prevent duplicate loads.
    private var firstPreloadTask: Task<Void, Never>? = nil

    private var playbackSourceGeneration: Int = 0
    private struct PlaybackLoadIdentity {
        let generation: Int
        let sourceName: String
        let playbackSessionId: UUID
        let sceneId: String?
    }
    private var lastAppliedInitialLoadIdentity: PlaybackLoadIdentity?
    private struct PlaybackPoolLoadIdentity {
        let generation: Int
        let sourceName: String
        let playbackSessionId: UUID
    }

    @Published private(set) var didFirstPreload: Bool = false
    // Tests can replace the first pool load to simulate a cold-start race where an old task returns late.

    var loadAssetsHookForTesting: ((PlaybackSource) async throws -> [Asset])? = nil
    // Tests can replace the pool refill to simulate an old loadMore returning late.

    var loadMoreAssetsHookForTesting: ((PlaybackSource) async throws -> [Asset])? = nil
    // Tests can stub out the first-screen download so unit tests do not hit the network.

    var initialPhotoLoadHookForTesting: ((String) async -> Void)? = nil
    // Tests can stub out the background preload so state-flow checks see no extra downloads.

    var backgroundPreloadHookForTesting: (([Asset], Int, Int) async -> Void)? = nil
    var indexChangePhotoLoadHookForTesting: ((String, ThumbnailSize) async -> Void)? = nil
    // Tests can use a fixed clock to verify the scene publish latency manifest.

    var playbackManifestTimestampProviderForTesting: (() -> TimeInterval)? = nil
    var scenePresentationTimestampProviderForTesting: (() -> TimeInterval)? = nil
    // Tests can stub out the post-transition window prefetch so unit tests do not hit the network; it also skips the
    // first-screen commit.

    var transitionWindowPreloadHookForTesting: (([Asset], Int, Int) async -> Void)? = nil
    // Vision debug state is only for the panel; it does not change playback logic.

    @Published private(set) var visionFaceAuditState: VisionFaceAuditState = .idle
    private var visionFaceAuditTask: Task<Void, Never>? = nil
    // Defaults to the random source and a new resolver, so the old random entry point still works.
    init(
        source: PlaybackSource = .random,
        resolver: PlaybackPoolResolver? = nil,
        settingsStore: PlaybackSettingsStore? = nil,
        observeSettingsChanges: Bool? = nil
    ) {
        self.source = source
        self.resolver = resolver ?? PlaybackPoolResolver()
        self.playbackSettingsStore = settingsStore ?? PlaybackSettingsStore()
        // Read playback settings once at creation so changes from the settings page reach playback.
        let settings = playbackSettingsStore.load() ?? PlaybackSettings()
        self.isAutoPlay = settings.autoPlayEnabled
        self.autoPlayInterval = PlaybackIntervalPolicy.migratedLegacyInterval(settings.intervalSeconds)
        self.playbackDisplayMode = settings.displayMode
        let isRunningXCTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let shouldObserveSettingsChanges =
            observeSettingsChanges
            ?? Self.shouldObserveSettingsChangesByDefault(
                isDebugBuild: Self.isDebugBuild,
                isRunningXCTest: isRunningXCTest
            )
        guard shouldObserveSettingsChanges else { return }
        playbackSettingsChangeObserver = NotificationCenter.default.addObserver(
            forName: .playbackSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                notification.userInfo?[PlaybackSettingsStore.changedStoreKeyUserInfoKey] as? String
                    == self.playbackSettingsStore.notificationScope,
                let settings = notification.userInfo?[PlaybackSettingsStore.changedSettingsUserInfoKey]
                    as? PlaybackSettings
            else {
                return
            }
            Task { @MainActor [weak self] in
                self?.applyPlaybackSettings(settings)
            }
        }
    }

    deinit {
        if let playbackSettingsChangeObserver {
            NotificationCenter.default.removeObserver(playbackSettingsChangeObserver)
        }
    }

    // Only isolate global notifications for Debug tests; Release must sync product settings even when launched by
    // XCTest.
    static func shouldObserveSettingsChangesByDefault(
        isDebugBuild: Bool,
        isRunningXCTest: Bool
    ) -> Bool {
        !isDebugBuild || !isRunningXCTest
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    func updateSmartFillSurface(
        _ surface: PlaybackSmartFillSurface,
        protectionSnapshot: PlaybackProtectionSnapshot
    ) {
        let replanFingerprint = smartFillReplanFingerprint(
            surface: surface,
            protectionSnapshot: protectionSnapshot
        )
        if smartFillReplanFingerprint == replanFingerprint {
            return
        }
        smartFillReplanFingerprint = replanFingerprint
        cancelSmartFillPreparedRingRefreshTask()
        smartFillSurface = surface
        smartFillProtectionSnapshot = protectionSnapshot
        playbackSessionEngine.updateFutureProtectionSnapshot(protectionSnapshot)
        syncPlaybackReadbackFromEngine()
        scheduleSmartFillInitialSceneActivationIfNeeded()
        refreshPreparedSmartFillSceneRingIfPossible()
    }

    private func smartFillReplanFingerprint(
        surface: PlaybackSmartFillSurface,
        protectionSnapshot: PlaybackProtectionSnapshot
    ) -> String {
        [
            surface.internalSurfaceFingerprint,
            protectionSnapshot.smartFillReplanFingerprint
        ].joined(separator: "||")
    }

    #if DEBUG
    func updateSmartFillSurfaceForTesting(_ surface: PlaybackSmartFillSurface) {
        updateSmartFillSurface(surface, protectionSnapshot: PlaybackProtectionSnapshot(regions: []))
    }

    var smartFillCandidateSummaryBuildCountForTesting: Int {
        smartFillCandidateSummaryBuildCountForTestingStorage
    }

    func resetSmartFillCandidateSummaryBuildCountForTesting() {
        smartFillCandidateSummaryBuildCountForTestingStorage = 0
    }

    func resetSmartFillMainActorPlannerCallCountsForTesting() {
        smartFillMainActorPlannerCallCountsForTesting = [:]
    }

    func smartFillMainActorPlannerCallCountForTesting(
        _ callSite: SmartFillMainActorPlannerCallSite
    ) -> Int {
        smartFillMainActorPlannerCallCountsForTesting[callSite, default: 0]
    }

    func capturePreparedSmartFillPlanRequestForTesting(startingAt startIndex: Int) -> SmartFillPreparedPlanRequest? {
        capturePreparedSmartFillPlanRequest(startingAt: startIndex)
    }

    @discardableResult
    func applyPreparedSmartFillPlanResultForTesting(
        _ result: SmartFillPreparedPlanResult,
        request: SmartFillPreparedPlanRequest
    ) -> SmartFillPreparedPlanApplicationOutcome {
        applyPreparedSmartFillPlanResultIfFresh(result, request: request)
    }

    struct SmartFillScenePlanComparisonForTesting: Equatable {
        let selectedAssetIds: [String]
        let slotRoles: [PlaybackSmartFillSlotRole]
        let layoutVariant: PlaybackSmartFillLayoutVariant
        let ratioPreset: String
        let fallbackCategory: PlaybackSmartFillFallbackCategory
        let nextCandidateCursorOffset: Int
    }

    func makeSmartFillScenePlanComparisonForTesting(startingAt startIndex: Int)
        -> SmartFillScenePlanComparisonForTesting?
    {
        guard let plan = makeSmartFillScenePlan(startingAt: startIndex, callSite: .requestScene),
            let readback = plan.scene.smartFillReadback
        else {
            return nil
        }
        return SmartFillScenePlanComparisonForTesting(
            selectedAssetIds: plan.scene.assetIds,
            slotRoles: readback.slotRoles,
            layoutVariant: readback.layoutVariant,
            ratioPreset: readback.ratioPreset,
            fallbackCategory: readback.fallbackCategory,
            nextCandidateCursorOffset: plan.nextCandidateCursorOffset
        )
    }

    var preparedSmartFillNextAssetIdsForTesting: [String]? {
        playbackSessionEngine.preparedSceneRing?.next?.scene.assetIds
    }

    var preparedSmartFillNextSourceCursorForTesting: Int? {
        playbackSessionEngine.preparedSceneRing?.next?.cursorEffect?.sourceCursor
    }

    var preparedSmartFillNextTargetIndexForTesting: Int? {
        playbackSessionEngine.preparedSceneRing?.next?.targetIndex
    }

    var currentPreparedSmartFillSourceCursorForTesting: Int? {
        currentPreparedSmartFillSourceCursor()
    }

    var playbackSceneCountForTesting: Int {
        playbackSessionEngine.scenes.count
    }

    func clearPreparedSmartFillRingForTesting() {
        cancelSmartFillPreparedRingRefreshTask()
        guard let fingerprint = makePreparedSmartFillSceneFingerprint(),
            !assets.isEmpty
        else {
            return
        }
        playbackSessionEngine.prepareSceneRing(
            fingerprint: fingerprint,
            sourceCursor: normalizedCandidateCursorIndex(),
            previous: nil,
            current: playbackSessionEngine.currentScene,
            next: nil,
            nextCursorEffect: nil
        )
    }
    #endif

    func replacePlaybackAssetsForTesting(_ newAssets: [Asset]) {
        applyPlaybackAssets(newAssets, invalidationReason: .poolReloaded)
    }

    private func applyPlaybackAssets(
        _ newAssets: [Asset],
        invalidationReason: PlaybackSessionInvalidationReason
    ) {
        smartFillSurfaceActivationTask?.cancel()
        smartFillSurfaceActivationTask = nil
        cancelSmartFillPreparedRingRefreshTask()
        resetScenePresentationRuntime()
        assets = newAssets
        smartFillDisplayedAssetIds = []
        pendingSmartFillDisplayedAssetIdsAfterCommit = nil
        pendingSceneActionTimestamps = [:]
        let initialSmartFillPlan = makeSmartFillScenePlan(
            startingAt: 0,
            callSite: .initialPlanning
        )
        smartFillDisplayedAssetIds = initialSmartFillPlan?.displayedAssetIds ?? []
        resetCandidateCursor(nextCandidateCursorOffset: initialSmartFillPlan?.nextCandidateCursorOffset ?? 1)
        playbackSessionEngine.reset(
            with: newAssets,
            initialScene: initialSmartFillPlan?.scene,
            reason: invalidationReason
        )
        playbackHistoryLedger.reset(with: nil)
        pendingPlaybackHistoryLedgerCommits = [:]
        if initialSmartFillPlan != nil {
            recordSmartFillStartupRuntimePhase("firstScenePublished")
        }
        syncPlaybackReadbackFromEngine()
        refreshPreparedSmartFillSceneRingIfPossible()
    }

    private func assetsUnseenInCurrentPool(_ incomingAssets: [Asset]) -> [Asset] {
        var seenAssetIds = Set(assets.map(\.id))
        return incomingAssets.filter { asset in
            seenAssetIds.insert(asset.id).inserted
        }
    }

    private func syncPlaybackReadbackFromEngine() {
        // If autoplay is off at startup, send that to the reducer first, so layers created or made Ready later inherit
        // the paused clock.

        if !isAutoPlay {
            executeScenePresentationEffects(
                playbackSessionEngine.reduceScenePresentation(
                    .suspend(.userPaused),
                    at: scenePresentationTimestamp()
                )
            )
        }
        if playbackSessionEngine.pendingTransition != nil {
            beginPendingScenePresentationIfNeeded()
        } else if playbackSessionEngine.scenePresentationState.underlyingPhase == .empty,
            let started = playbackSessionEngine.startScenePresentation(
                configuredInterval: autoPlayInterval,
                at: scenePresentationTimestamp()
            ),
            let scene = playbackSessionEngine.scene(for: started.identity)
        {
            beginScenePresentationBarrier(identity: started.identity, scene: scene)
            executeScenePresentationEffects(started.effects)
        }
        currentIndex = playbackSessionEngine.currentIndex
        targetIndex = playbackSessionEngine.pendingTransition?.targetIndex ?? playbackSessionEngine.currentIndex
        targetTransitionToken = playbackSessionEngine.targetTransitionToken
        #if DEBUG
        downloadManager.markPlaybackImageRequestLifecycleLateResultsForDiagnostics(
            currentNavigationToken: targetTransitionToken
        )
        #endif
        publishScenePresentationChange()
    }

    private func beginPendingScenePresentationIfNeeded() {
        guard let transition = playbackSessionEngine.pendingTransition else { return }
        let requestSource: PlaybackSessionEngine.ScenePresentationRequestSource
        switch transition.transaction.source {
        case .manualNext:
            requestSource = .manualNext
        case .manualPrevious:
            requestSource = .manualPrevious
        case .autoplay:
            requestSource = .automatic
        }
        let isAutomaticStableDeadline =
            requestSource == .automatic && playbackSessionEngine.scenePresentationState.underlyingPhase == .stablePhoto
        let appendsNewTailScene = transition.targetIndex >= playbackSessionEngine.scenes.count
        let candidateCursorIndexAfterCommit = pendingCandidateCursorIndexAfterCommit
        let displayedAssetIdsAfterCommit = pendingSmartFillDisplayedAssetIdsAfterCommit
        guard
            let started = playbackSessionEngine.beginScenePresentation(
                for: transition,
                configuredInterval: autoPlayInterval,
                requestSource: requestSource,
                isAutomaticStableDeadline: isAutomaticStableDeadline,
                at: scenePresentationTimestamp()
            )
        else {
            pendingPlaybackHistoryLedgerCommits[transition.transaction.id] = nil
            pendingSceneActionTimestamps[transition.transaction.id] = nil
            return
        }
        recordScenePublishTiming(for: transition)
        if let displayedAssetIdsAfterCommit {
            smartFillDisplayedAssetIds = displayedAssetIdsAfterCommit
        }
        if appendsNewTailScene, let candidateCursorIndexAfterCommit {
            applyCandidateCursorIndexAfterCommit(candidateCursorIndexAfterCommit)
        }
        pendingCandidateCursorIndexAfterCommit = nil
        pendingSmartFillDisplayedAssetIdsAfterCommit = nil
        if !applySmartFillMotionLookaheadPreparedPlanIfReady() {
            refreshPreparedSmartFillSceneRingIfPossible()
        }
        beginScenePresentationBarrier(identity: started.identity, scene: transition.scene)
        executeScenePresentationEffects(started.effects)
    }

    private func resetScenePresentationRuntime() {
        scenePresentationWakeUpTask?.cancel()
        scenePresentationWakeUpTask = nil
        scenePresentationWakeUpKey = nil
        scenePresentationEffectTasks.values.forEach { $0.cancel() }
        scenePresentationEffectTasks = [:]
        pendingAutomaticScenePlanGeneration = nil
        scenePresentationPrerenderBarrier = ScenePresentationPrerenderBarrier()
        smartFillMotionPreparedSlotPreloadTasks.values.forEach { $0.cancel() }
        smartFillMotionPreparedSlotPreloadTasks = [:]
        smartFillMotionLookaheadPreparedPlan = nil
        scenePresentationDecodedCount = 0
        scenePresentationReadyCount = 0
        scenePresentationHiddenDecodeExcludedFromHistory = false
        scenePresentationVisibleTickCommittedHistory = false
        publishScenePresentationChange()
    }

    private func scenePresentationTimestamp() -> TimeInterval {
        scenePresentationTimestampProviderForTesting?() ?? ProcessInfo.processInfo.systemUptime
    }

    private func publishScenePresentationChange() {
        scenePresentationRevision = UUID()
    }

    func toggleAutoPlayFromUserInteraction() {
        updateAutoPlayEnabled(!isAutoPlay, persistPreference: true)
    }

    private func applyPlaybackSettings(_ settings: PlaybackSettings) {
        updateAutoPlayEnabled(settings.autoPlayEnabled, persistPreference: false)
        autoPlayInterval = PlaybackIntervalPolicy.migratedLegacyInterval(settings.intervalSeconds)
        let previousDisplayMode = playbackDisplayMode
        playbackDisplayMode = settings.displayMode
        if previousDisplayMode != playbackDisplayMode {
            rebuildCurrentSceneForDisplayModeChange()
        }
    }

    private func updateAutoPlayEnabled(_ enabled: Bool, persistPreference: Bool) {
        guard isAutoPlay != enabled else {
            if persistPreference {
                var settings = playbackSettingsStore.load() ?? PlaybackSettings()
                settings.autoPlayEnabled = enabled
                playbackSettingsStore.save(settings)
            }
            return
        }
        isAutoPlay = enabled
        let event: PlaybackSessionEngine.ScenePresentationEvent =
            enabled
            ? .resume(.userPaused)
            : .suspend(.userPaused)
        executeScenePresentationEffects(
            playbackSessionEngine.reduceScenePresentation(
                event,
                at: scenePresentationTimestamp()
            )
        )
        publishScenePresentationChange()
        guard persistPreference else { return }
        var settings = playbackSettingsStore.load() ?? PlaybackSettings()
        settings.autoPlayEnabled = enabled
        playbackSettingsStore.save(settings)
    }

    func executeScenePresentationEffects(_ effects: [ScenePresentationEffect]) {
        for effect in effects {
            switch effect {
            case let .plan(request):
                let presentationState = playbackSessionEngine.scenePresentationState
                let isStableDeadlinePlan =
                    presentationState.underlyingPhase == .stablePhoto
                    && presentationState.currentTarget?.identity == request.identity
                let isExhaustedAutomaticTargetPlan =
                    presentationState.pendingTarget?.identity == request.identity
                    && presentationState.targetReadiness[request.identity] == .failed
                let isRestoredGracePendingPlan =
                    presentationState.underlyingPhase == .grace
                    && presentationState.pendingTarget?.identity == request.identity
                    && presentationState.targetReadiness[request.identity] == .pending
                if isRestoredGracePendingPlan {
                    // A manual hold has just begun this target's barrier; only a target a cancel brought back needs a new one.
                    let barrierIsActive =
                        scenePresentationPrerenderBarrier.activeScene
                        == ScenePresentationLayerIdentity(
                            generation: request.identity.generation,
                            sceneID: request.identity.sceneID,
                            layerID: "scene-root"
                        )
                    if !barrierIsActive, let scene = playbackSessionEngine.scene(for: request.identity) {
                        restartScenePresentationBarrier(identity: request.identity, scene: scene)
                    }
                    continue
                }
                guard isAutoPlay,
                    request.source == .automatic,
                    isStableDeadlinePlan || isExhaustedAutomaticTargetPlan
                else {
                    continue
                }
                pendingAutomaticScenePlanGeneration = request.identity.generation
                planAutomaticSceneEffect()
                let updatedState = playbackSessionEngine.scenePresentationState
                if updatedState.currentTarget?.identity != request.identity
                    && updatedState.pendingTarget?.identity != request.identity
                {
                    pendingAutomaticScenePlanGeneration = nil
                }

            case let .download(request):
                guard let scene = playbackSessionEngine.scene(for: request.identity) else { continue }
                scenePresentationEffectTasks[request.identity.generation]?.cancel()
                let task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.playbackSessionEngine.transition(for: request.identity) == nil {
                        await self.loadInitialSceneAssetsForPlayback(scene)
                    } else {
                        await self.loadSceneAssetsForTransition(
                            scene,
                            isPreviousTransition: request.source == .manualPrevious,
                            navigationToken: request.identity.generation
                        )
                        guard !Task.isCancelled else { return }
                        _ = await self.preloadSmartFillCandidateWindowIfNeeded(
                            startingAt: self.candidateCursorIndex
                        )
                        guard !Task.isCancelled else { return }
                        await self.preloadPlaybackWindowAfterTransitionIfReady()
                    }
                    guard !Task.isCancelled else { return }
                    self.scenePresentationEffectTasks[request.identity.generation] = nil
                }
                scenePresentationEffectTasks[request.identity.generation] = task

            case let .retry(request, _):
                guard let scene = playbackSessionEngine.scene(for: request.identity) else { continue }
                restartScenePresentationBarrier(identity: request.identity, scene: scene)
                scenePresentationEffectTasks[request.identity.generation]?.cancel()
                let task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.loadSceneAssetsForTransition(
                        scene,
                        isPreviousTransition: request.source == .manualPrevious,
                        navigationToken: request.identity.generation
                    )
                    guard !Task.isCancelled else { return }
                    self.scenePresentationEffectTasks[request.identity.generation] = nil
                }
                scenePresentationEffectTasks[request.identity.generation] = task

            case let .loadMore(generation):
                scenePresentationEffectTasks[generation]?.cancel()
                let task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.loadMoreAssets()
                    guard !Task.isCancelled else { return }
                    self.scenePresentationEffectTasks[generation] = nil
                }
                scenePresentationEffectTasks[generation] = task

            case let .scheduleWakeUp(generation, deadline):
                scheduleScenePresentationWakeUp(generation: generation, deadline: deadline)

            case let .cancelWakeUp(generation):
                guard scenePresentationWakeUpKey?.generation == generation else { continue }
                scenePresentationWakeUpTask?.cancel()
                scenePresentationWakeUpTask = nil
                scenePresentationWakeUpKey = nil

            case let .cancel(request):
                scenePresentationEffectTasks[request.identity.generation]?.cancel()
                scenePresentationEffectTasks[request.identity.generation] = nil
                if pendingAutomaticScenePlanGeneration == request.identity.generation {
                    pendingAutomaticScenePlanGeneration = nil
                }
                releaseScenePresentationBarrier(for: request.identity)

            case let .requestManualDirection(source):
                switch source {
                case .manualPrevious:
                    requestPreviousScene()
                case .manualNext, .automatic:
                    requestNextScene()
                }
            }
        }
        publishScenePresentationChange()
    }

    private func scheduleScenePresentationWakeUp(
        generation: UUID,
        deadline: TimeInterval
    ) {
        let key = ScenePresentationWakeUpKey(generation: generation, deadline: deadline)
        guard scenePresentationWakeUpKey != key else { return }
        scenePresentationWakeUpTask?.cancel()
        scenePresentationWakeUpKey = key
        guard scenePresentationTimestampProviderForTesting == nil else {
            scenePresentationWakeUpTask = nil
            return
        }
        let delay = max(0, deadline - scenePresentationTimestamp())
        scenePresentationWakeUpTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64((delay * 1_000_000_000).rounded(.up))
            )
            guard let self,
                !Task.isCancelled,
                self.scenePresentationWakeUpKey == key
            else {
                return
            }
            self.scenePresentationWakeUpTask = nil
            self.scenePresentationWakeUpKey = nil
            let effects = self.playbackSessionEngine.reduceScenePresentation(
                .wakeUp(generation: generation, deadline: deadline),
                at: self.scenePresentationTimestamp()
            )
            self.executeScenePresentationEffects(effects)
        }
    }

    #if DEBUG
    /// Tests only fire the wake-up the owner already scheduled; no separate autoplay clock is created.
    @discardableResult
    func fireScheduledScenePresentationWakeUpForTesting() -> TimeInterval? {
        guard let key = scenePresentationWakeUpKey else { return nil }
        scenePresentationWakeUpTask?.cancel()
        scenePresentationWakeUpTask = nil
        scenePresentationWakeUpKey = nil
        let effects = playbackSessionEngine.reduceScenePresentation(
            .wakeUp(generation: key.generation, deadline: key.deadline),
            at: key.deadline
        )
        executeScenePresentationEffects(effects)
        return key.deadline
    }
    #endif

    private func beginScenePresentationBarrier(
        identity: PlaybackSessionEngine.ScenePresentationIdentity,
        scene: PlaybackScene
    ) {
        let layerIdentity = ScenePresentationLayerIdentity(
            generation: identity.generation,
            sceneID: identity.sceneID,
            layerID: "scene-root"
        )
        if let activeScene = scenePresentationPrerenderBarrier.activeScene {
            guard activeScene != layerIdentity else { return }
            _ = scenePresentationPrerenderBarrier.release(scene: activeScene)
        }
        let rendererAttemptID = UUID()
        #if DEBUG
        scenePresentationBarrierAttemptCountForTesting += 1
        #endif
        let expectedRenderers = Set(
            scene.photoSlots.map { slot in
                SceneRendererIdentity(
                    generation: identity.generation,
                    attemptID: rendererAttemptID,
                    sceneID: identity.sceneID,
                    slotID: slot.id,
                    assetID: slot.asset.id
                )
            })
        _ = scenePresentationPrerenderBarrier.begin(
            scene: layerIdentity,
            expectedRenderers: expectedRenderers
        )
    }

    private func releaseScenePresentationBarrier(
        for identity: PlaybackSessionEngine.ScenePresentationIdentity
    ) {
        _ = scenePresentationPrerenderBarrier.release(
            scene: ScenePresentationLayerIdentity(
                generation: identity.generation,
                sceneID: identity.sceneID,
                layerID: "scene-root"
            )
        )
    }

    private func restartScenePresentationBarrier(
        identity: PlaybackSessionEngine.ScenePresentationIdentity,
        scene: PlaybackScene
    ) {
        releaseScenePresentationBarrier(for: identity)
        beginScenePresentationBarrier(identity: identity, scene: scene)
    }

    func rendererDecoded(_ identity: SceneRendererIdentity) {
        let historyCountBefore = playbackSessionEngine.scenePresentationState.history.count
        scenePresentationDecodedCount += 1
        guard case let .presentationReady(layerIdentity)? = scenePresentationPrerenderBarrier.rendererDecoded(identity)
        else {
            scenePresentationHiddenDecodeExcludedFromHistory =
                playbackSessionEngine.scenePresentationState.history.count == historyCountBefore
            publishScenePresentationChange()
            return
        }
        scenePresentationReadyCount += 1
        scenePresentationHiddenDecodeExcludedFromHistory =
            playbackSessionEngine.scenePresentationState.history.count == historyCountBefore
        guard
            let presentationIdentity = playbackSessionEngine.presentationIdentity(
                generation: layerIdentity.generation,
                sceneID: layerIdentity.sceneID
            )
        else {
            publishScenePresentationChange()
            return
        }
        executeScenePresentationEffects(
            playbackSessionEngine.reduceScenePresentation(
                .targetReady(presentationIdentity),
                at: scenePresentationTimestamp()
            )
        )
    }

    func rendererFailed(_ identity: SceneRendererIdentity) {
        guard scenePresentationPrerenderBarrier.rendererFailed(identity),
            let presentationIdentity = playbackSessionEngine.presentationIdentity(
                generation: identity.generation,
                sceneID: identity.sceneID
            )
        else {
            return
        }
        executeScenePresentationEffects(
            playbackSessionEngine.reduceScenePresentation(
                .targetFailed(presentationIdentity),
                at: scenePresentationTimestamp()
            )
        )
    }

    func incomingBecameVisible(_ layerIdentity: ScenePresentationLayerIdentity) {
        guard
            let identity = playbackSessionEngine.presentationIdentity(
                generation: layerIdentity.generation,
                sceneID: layerIdentity.sceneID
            )
        else {
            return
        }
        let historyCountBefore = playbackSessionEngine.scenePresentationState.history.count
        let transition = playbackSessionEngine.transition(for: identity)
        let previousLedgerIndex = playbackHistoryLedger.cursor ?? -1
        let previousLedgerAssetId = playbackHistoryLedger.cursor.flatMap { cursor in
            playbackHistoryLedger.entries.indices.contains(cursor)
                ? playbackHistoryLedger.entries[cursor].scene.primaryAssetId
                : nil
        }
        executeScenePresentationEffects(
            playbackSessionEngine.reduceScenePresentation(
                .incomingBecameVisible(identity),
                at: scenePresentationTimestamp()
            )
        )
        guard playbackSessionEngine.scenePresentationState.history.count > historyCountBefore else { return }
        scenePresentationVisibleTickCommittedHistory = true
        for slot in playbackSessionEngine.scene(for: identity)?.photoSlots ?? [] {
            recordSmartFillFirstImageDisplayed(assetId: slot.asset.id)
        }
        if let transition {
            applyPlaybackHistoryLedgerCommit(
                pendingPlaybackHistoryLedgerCommits[transition.transaction.id],
                committedScene: playbackSessionEngine.scene(for: identity)
            )
        } else if playbackHistoryLedger.entries.isEmpty,
            let scene = playbackSessionEngine.scene(for: identity)
        {
            playbackHistoryLedger.append(scene)
        }
        let displayReason: String
        switch transition?.transaction.source {
        case .manualNext:
            displayReason = "manual"
        case .manualPrevious:
            displayReason = "manual"
        case .autoplay:
            displayReason = "auto"
        case .none:
            displayReason = "initial"
        }
        logDisplayedAsset(
            reason: displayReason,
            previousIndex: previousLedgerIndex,
            previousAssetId: previousLedgerAssetId,
            requestedIndex: currentIndex,
            displayedIndex: currentIndex
        )
        requestLoadMoreAfterVisibleSceneIfNeeded(generation: identity.generation)
        releaseScenePresentationBarrier(for: identity)
        publishScenePresentationChange()
    }

    private func requestLoadMoreAfterVisibleSceneIfNeeded(generation: UUID) {
        let loadMoreProgressIndex = candidateProgressIndexForLoadMore
        let shouldTriggerLoadMore = Self.shouldTriggerLoadMore(
            assetCount: assets.count,
            newIndex: loadMoreProgressIndex,
            isSoloOnlyPlayback: isSoloOnlyPlaybackSource,
            soloOnlyRemainingTriggerCount: soloOnlyLoadMoreRemainingTriggerCount
        )
        #if DEBUG
        logQAPlaybackSequenceEventIfNeeded(
            .loadMoreDecision(
                assetCount: assets.count,
                candidateCursorIndex: candidateCursorIndex,
                candidateProgressIndexForLoadMore: loadMoreProgressIndex,
                soloOnly: isSoloOnlyPlaybackSource,
                isLoadingMore: isLoadingMore,
                shouldTrigger: shouldTriggerLoadMore,
                currentIndex: currentIndex,
                targetIndex: targetIndex,
                displayedAssetCount: qaPlaybackSequenceRecorder?.displayedAssetRecordCount ?? 0
            ))
        #endif
        guard shouldTriggerLoadMore, !isLoadingMore else { return }
        executeScenePresentationEffects(
            playbackSessionEngine.reduceScenePresentation(
                .loadMoreNeeded(generation: generation),
                at: scenePresentationTimestamp()
            )
        )
    }

    /// The view asks for this label on every drawn frame (on iOS also on each state change), so in DEBUG it also records
    /// frames that show less than half a photo once the first scene has appeared, and the crossfade frames it draws.
    /// Tests compare these records around an action to catch what falls between their samples; only whether the counts
    /// change is meaningful, not their exact values.
    func scenePresentationContractProbeLabel(
        for snapshot: PlaybackSessionEngine.SceneRenderSnapshot
    ) -> String {
        let progressValues = snapshot.layers.map { layer -> Double in
            guard let target = playbackSessionEngine.presentationTarget(for: layer.identity) else { return 0 }
            let activeTime = Self.renderedMotionActiveTime(of: layer, lifecycle: target.lifecycle)
            return SceneAnimationProfile(lifecycle: target.lifecycle).rawProgress(for: activeTime)
        }
        #if DEBUG
        let photoCoverage = 1 - snapshot.layers.reduce(1) { uncovered, layer in uncovered * (1 - layer.opacity) }
        if !playbackSessionEngine.scenePresentationState.history.isEmpty,
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
            "historyCount=\(playbackSessionEngine.scenePresentationState.history.count)",
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

    private func motionEligibility(
        scene: PlaybackScene,
        renderRole: MotionRenderRole,
        platform: MotionPlatform,
        isReduceMotionEnabled: Bool
    ) -> MotionEligibilityResult {
        MotionEligibilityPolicy.acceptedSceneRuntime.evaluate(
            MotionEligibilityInput(
                platform: platform,
                sceneCapability: motionSceneCapability(for: scene),
                displayMode: playbackDisplayMode == .smartFill ? .smartFill : .singlePhoto,
                focalAdapter: .smartFill,
                isReduceMotionEnabled: isReduceMotionEnabled,
                renderRole: renderRole,
                slotReadiness: motionSlotReadiness(for: scene)
            )
        )
    }

    private func motionPlatformForCurrentSurface() -> MotionPlatform {
        guard let profile = smartFillSurface?.profile else { return .iOS }
        return MotionPlatform(smartFillSurfaceProfile: profile)
    }

    private func motionSceneCapability(for scene: PlaybackScene) -> MotionSceneCapability {
        guard let readback = scene.smartFillReadback else {
            return scene.photoSlots.count == 1 ? .legacySinglePhoto : .other
        }
        switch readback.sceneType {
        case .double, .triple:
            return .smartFillAccepted
        case .single:
            return .smartFillSingle
        case .fallback:
            return .smartFillFallback
        }
    }

    private func motionSlotReadiness(for scene: PlaybackScene) -> MotionSlotReadiness {
        guard !scene.photoSlots.isEmpty else { return .failed }
        var hasPendingSlot = false
        for slot in scene.photoSlots {
            let readiness = PlaybackSmartFillSlotReadiness.resolve(
                assetId: slot.asset.id,
                fullsizeState: downloadManager.assetStates[slot.asset.id] ?? .notStarted,
                fullsizeURL: downloadManager.findURL(assetId: slot.asset.id, size: .fullsize)
            )
            switch readiness {
            case .ready:
                continue
            case .pending:
                hasPendingSlot = true
            case .failed:
                return .failed
            }
        }
        return hasPendingSlot ? .pending : .ready
    }

    func requestPreviousScene() {
        guard !playbackSessionEngine.scenes.isEmpty else { return }
        let actionTimestamp = playbackManifestTimestamp()
        pendingCandidateCursorIndexAfterCommit = nil
        pendingSmartFillDisplayedAssetIdsAfterCommit = nil
        if canCancelUnseenPendingScenePresentation,
            playbackSessionEngine.canCancelUnseenManualPendingScenePresentation
        {
            // When pre-committed but not yet seen, Previous cancels the pending target and restores the seen scene;
            // re-requesting the current ledger would flash Loading.

            let cancelledTransition = playbackSessionEngine.scenePresentationState.pendingTarget
                .flatMap { playbackSessionEngine.transition(for: $0.identity) }
            let effects = playbackSessionEngine.cancelUnseenManualPendingScenePresentation(
                at: scenePresentationTimestamp()
            )
            if let cancelledTransition {
                pendingPlaybackHistoryLedgerCommits[cancelledTransition.transaction.id] = nil
                pendingSceneActionTimestamps[cancelledTransition.transaction.id] = nil
            }
            executeScenePresentationEffects(effects)
            syncPlaybackReadbackFromEngine()
            return
        }
        guard let previousTarget = playbackHistoryLedger.previousTarget else {
            syncPlaybackReadbackFromEngine()
            return
        }
        let transition = playbackSessionEngine.requestTransition(
            to: previousTarget.entry.scene,
            source: .manualPrevious
        )
        pendingPlaybackHistoryLedgerCommits[transition.transaction.id] = .moveCursor(previousTarget.index)
        recordActionTimestamp(actionTimestamp, for: transition)
        syncPlaybackReadbackFromEngine()
    }

    private var canCancelUnseenPendingScenePresentation: Bool {
        guard let visibleCurrentTarget = playbackHistoryLedger.currentTarget,
            playbackSessionEngine.canCancelUnseenManualPendingScenePresentation,
            let pendingTarget = playbackSessionEngine.scenePresentationState.pendingTarget,
            !playbackSessionEngine.scenePresentationState.history.contains(pendingTarget.identity)
        else {
            return false
        }
        return playbackSessionEngine.currentScene?.id != visibleCurrentTarget.entry.scene.id
    }

    /// The platform page is the only scenePhase entry point; the reducer keeps background time out of the playback
    /// clock.
    func suspendScenePresentationForBackground() {
        executeScenePresentationEffects(
            playbackSessionEngine.reduceScenePresentation(
                .suspend(.background),
                at: scenePresentationTimestamp()
            )
        )
    }

    /// Returning to the foreground only removes the background reason; if the user is still paused, stay frozen and do
    /// not catch up on the deadline.
    func resumeScenePresentationFromBackground() {
        guard playbackSessionEngine.scenePresentationState.suspensionReasons.contains(.background) else {
            return
        }
        executeScenePresentationEffects(
            playbackSessionEngine.reduceScenePresentation(
                .resume(.background),
                at: scenePresentationTimestamp()
            )
        )
    }

    func requestNextScene() {
        requestNextScene(isManual: true)
    }

    private func requestNextScene(isManual: Bool) {
        guard !assets.isEmpty else { return }
        let actionTimestamp = playbackManifestTimestamp()
        let transactionSource: PlaybackSceneTransactionSource = isManual ? .manualNext : .autoplay
        if let redoTarget = playbackHistoryLedger.redoTarget {
            let transition = playbackSessionEngine.requestTransition(
                to: redoTarget.entry.scene,
                source: transactionSource
            )
            pendingPlaybackHistoryLedgerCommits[transition.transaction.id] = .moveCursor(redoTarget.index)
            recordActionTimestamp(actionTimestamp, for: transition)
            syncPlaybackReadbackFromEngine()
            return
        }
        let candidateIndex = normalizedCandidateCursorIndex()
        let shouldAdvanceCandidateCursorOnCommit = isAtRetainedHistoryTail
        guard
            !shouldHoldSmartFillAdvanceForSoloOnlyLoadMore(
                startingAt: candidateIndex,
                reason: "requestNext"
            )
        else {
            syncPlaybackReadbackFromEngine()
            return
        }
        let displayedAssetIdsForPlanning = smartFillDisplayedAssetIdsForPlanning
        if shouldAdvanceCandidateCursorOnCommit,
            let preparedTransition = consumePreparedSmartFillNext(source: transactionSource)
        {
            pendingPlaybackHistoryLedgerCommits[preparedTransition.transaction.id] = .appendTail
            recordActionTimestamp(actionTimestamp, for: preparedTransition)
        } else if shouldAdvanceCandidateCursorOnCommit,
            !isManual,
            isSmartFillPlanningEnabled
        {
            refreshPreparedSmartFillSceneRingIfPossible()
            return
        } else if shouldAdvanceCandidateCursorOnCommit,
            let smartFillPlan = makeSmartFillScenePlan(
                startingAt: candidateIndex,
                displayedAssetIdsForExclusion: displayedAssetIdsForPlanning,
                callSite: isManual ? .manualNext : .autoplayNext
            )
        {
            let displayedAssetIdsAfterCommit = displayedAssetIdsForPlanning.union(smartFillPlan.displayedAssetIds)
            let transition = playbackSessionEngine.requestNext(scene: smartFillPlan.scene, source: transactionSource)
            pendingPlaybackHistoryLedgerCommits[transition.transaction.id] = .appendTail
            recordActionTimestamp(actionTimestamp, for: transition)
            pendingCandidateCursorIndexAfterCommit = cursorIndex(
                afterAdvancingFrom: candidateIndex,
                by: smartFillPlan.nextCandidateCursorOffset,
                excludingDisplayedAssetIds: displayedAssetIdsAfterCommit
            )
            pendingSmartFillDisplayedAssetIdsAfterCommit = displayedAssetIdsAfterCommit
        } else {
            let transition = playbackSessionEngine.requestNext(
                candidate: assets[candidateIndex], source: transactionSource)
            pendingPlaybackHistoryLedgerCommits[transition.transaction.id] = .appendTail
            recordActionTimestamp(actionTimestamp, for: transition)
            let displayedAssetIdsAfterCommit = displayedAssetIdsForPlanning.union([assets[candidateIndex].id])
            pendingCandidateCursorIndexAfterCommit =
                shouldAdvanceCandidateCursorOnCommit
                ? cursorIndex(after: candidateIndex, excludingDisplayedAssetIds: displayedAssetIdsAfterCommit)
                : nil
            pendingSmartFillDisplayedAssetIdsAfterCommit =
                shouldAdvanceCandidateCursorOnCommit
                ? displayedAssetIdsAfterCommit
                : nil
        }
        syncPlaybackReadbackFromEngine()
    }

    private var isAtRetainedHistoryTail: Bool {
        playbackHistoryLedger.isAtTail
    }

    private var smartFillDisplayedAssetIdsForPlanning: Set<String> {
        guard smartFillSurface != nil, isSmartFillPlanningEnabled else {
            return smartFillDisplayedAssetIds
        }
        return pendingSmartFillDisplayedAssetIdsAfterCommit ?? smartFillDisplayedAssetIds
    }

    private func resetCandidateCursor(nextCandidateCursorOffset: Int = 1) {
        candidateCursorIndex =
            assets.isEmpty
            ? 0
            : cursorIndex(
                afterAdvancingFrom: 0,
                by: max(0, nextCandidateCursorOffset),
                excludingDisplayedAssetIds: smartFillDisplayedAssetIds
            )
        pendingCandidateCursorIndexAfterCommit = nil
        pendingSmartFillDisplayedAssetIdsAfterCommit = nil
        pendingSmartFillCursorResumeAfterLoadMoreAssetCount = nil
    }

    private func normalizedCandidateCursorIndex() -> Int {
        guard !assets.isEmpty else {
            preconditionFailure("normalizedCandidateCursorIndex requires non-empty assets")
        }
        if candidateCursorIndex >= 0 && candidateCursorIndex < assets.count {
            let normalizedIndex = nextCandidateCursorIndex(
                startingAt: candidateCursorIndex,
                excludingDisplayedAssetIds: smartFillDisplayedAssetIds
            )
            candidateCursorIndex = normalizedIndex
            return normalizedIndex
        }
        candidateCursorIndex = 0
        let normalizedIndex = nextCandidateCursorIndex(
            startingAt: 0,
            excludingDisplayedAssetIds: smartFillDisplayedAssetIds
        )
        candidateCursorIndex = normalizedIndex
        return normalizedIndex
    }

    private func cursorIndex(
        after assetIndex: Int,
        excludingDisplayedAssetIds displayedAssetIds: Set<String>
    ) -> Int {
        cursorIndex(
            afterAdvancingFrom: assetIndex,
            by: 1,
            excludingDisplayedAssetIds: displayedAssetIds
        )
    }

    private func cursorIndex(afterAdvancingFrom assetIndex: Int, by consumedCount: Int) -> Int {
        guard !assets.isEmpty else { return 0 }
        let safeStartIndex = min(max(0, assetIndex), assets.count - 1)
        return (safeStartIndex + max(0, consumedCount)) % assets.count
    }

    private func cursorIndex(
        afterAdvancingFrom assetIndex: Int,
        by consumedCount: Int,
        excludingDisplayedAssetIds displayedAssetIds: Set<String>
    ) -> Int {
        guard !assets.isEmpty else { return 0 }
        let unfilteredIndex = cursorIndex(afterAdvancingFrom: assetIndex, by: consumedCount)
        return nextCandidateCursorIndex(
            startingAt: unfilteredIndex,
            excludingDisplayedAssetIds: displayedAssetIds
        )
    }

    private func shouldHoldSmartFillAdvanceForSoloOnlyLoadMore(
        startingAt startIndex: Int,
        reason: String
    ) -> Bool {
        guard isSmartFillPlanningEnabled,
            isSoloOnlyPlaybackSource,
            isAtRetainedHistoryTail,
            !assets.isEmpty,
            startIndex >= 0,
            startIndex < assets.count
        else {
            return false
        }

        let currentAssetIds = Set(assets.map(\.id))
        let displayedAssetIds = smartFillDisplayedAssetIdsForPlanning.intersection(currentAssetIds)
        let hasUndisplayedCandidate = currentAssetIds.contains(where: { !displayedAssetIds.contains($0) })
        guard !hasUndisplayedCandidate else {
            return false
        }

        let shouldStartLoadMore = !isLoadingMore && pendingSmartFillCursorResumeAfterLoadMoreAssetCount == nil
        // When SmartFill has used up the soloOnly pool, skip this beat and continue from new assets after the refill
        // appends.

        pendingSmartFillCursorResumeAfterLoadMoreAssetCount = assets.count
        logger.notice(
            "smartfill advance held for soloOnly loadMore reason=\(reason, privacy: .public) assetCount=\(self.assets.count, privacy: .public) candidateCursorIndex=\(self.candidateCursorIndex, privacy: .public) startIndex=\(startIndex, privacy: .public) displayedAssetCount=\(displayedAssetIds.count, privacy: .public) isLoadingMore=\(self.isLoadingMore ? "true" : "false", privacy: .public)"
        )
        if shouldStartLoadMore {
            Task { @MainActor [weak self] in
                guard let self, self.isSoloOnlyPlaybackSource, !self.isLoadingMore else { return }
                await self.loadMoreAssets()
            }
        }
        return true
    }

    private func nextCandidateCursorIndex(
        startingAt startIndex: Int,
        excludingDisplayedAssetIds displayedAssetIds: Set<String>
    ) -> Int {
        guard !assets.isEmpty else { return 0 }
        let safeStartIndex = min(max(0, startIndex), assets.count - 1)
        guard !displayedAssetIds.isEmpty else { return safeStartIndex }

        for offset in 0..<assets.count {
            let candidateIndex = (safeStartIndex + offset) % assets.count
            if !displayedAssetIds.contains(assets[candidateIndex].id) {
                return candidateIndex
            }
        }
        return safeStartIndex
    }

    private var isSmartFillPlanningEnabled: Bool {
        playbackDisplayMode == .smartFill && !PlatformCompat.forceSinglePhotoPlaybackForDebug
    }

    private func makeSmartFillScenePlan(
        startingAt startIndex: Int,
        excludingDisplayedAssets: Bool = true,
        displayedAssetIdsForExclusion: Set<String>? = nil,
        callSite: SmartFillMainActorPlannerCallSite
    ) -> SmartFillScenePlan? {
        guard isSmartFillPlanningEnabled,
            let smartFillSurface,
            !assets.isEmpty,
            startIndex >= 0,
            startIndex < assets.count
        else {
            return nil
        }

        let candidateAssets = smartFillCandidateAssets(
            startingAt: startIndex,
            excludingDisplayedAssets: excludingDisplayedAssets,
            displayedAssetIdsForExclusion: displayedAssetIdsForExclusion
        )
        guard !candidateAssets.isEmpty else { return nil }

        recordSmartFillMainActorPlannerCall(callSite)
        let candidateSummaries = candidateAssets.map { smartFillCandidateSummary(for: $0) }
        let policy = PlaybackSmartFillLayoutPolicy.policy(for: smartFillSurface)
        recordSmartFillStartupRuntimePhase("firstScenePlanningStarted")
        let plannerResult = PlaybackSmartFillPlanner.plan(
            PlaybackSmartFillPlannerInput(
                surface: smartFillSurface,
                candidates: candidateSummaries,
                protectionSnapshot: smartFillProtectionSnapshot,
                policy: policy,
                playbackSessionSeed: "generation-\(playbackSourceGeneration)",
                sceneOrdinal: startIndex
            )
        )
        guard !plannerResult.slots.isEmpty else { return nil }

        var assetsByReference: [String: Asset] = [:]
        for (summary, asset) in zip(candidateSummaries, candidateAssets)
        where assetsByReference[summary.reference] == nil {
            assetsByReference[summary.reference] = asset
        }
        let photoSlots = plannerResult.slots.compactMap { slot -> PhotoSlot? in
            guard let asset = assetsByReference[slot.candidateReference] else { return nil }
            let candidate = candidateSummaries.first { $0.reference == slot.candidateReference }
            return PhotoSlot(
                id: "slot-\(slot.role.rawValue)-\(slot.candidateReference)",
                asset: asset,
                planning: PlaybackPlanningSnapshot.smartFill(
                    slot: slot,
                    plannerResult: plannerResult,
                    focalSummary: smartFillFocalSummary(
                        faceRects: candidate?.faceRects ?? [],
                        subjectRects: candidate?.subjectRects ?? []
                    )
                )
            )
        }
        guard !photoSlots.isEmpty else { return nil }

        let readback = PlaybackSmartFillSceneReadback(
            version: "smart-fill-scene-v2",
            sceneType: plannerResult.sceneType,
            layoutPolicyId: plannerResult.layoutPolicyId,
            surfaceKey: plannerResult.surfaceKey,
            layoutVariant: plannerResult.layoutVariant,
            ratioPreset: plannerResult.ratioPreset,
            slotRoles: plannerResult.slots.map(\.role),
            fallbackReason: plannerResult.fallbackReason,
            fallbackCategory: plannerResult.fallbackCategory,
            candidateWindowUsed: plannerResult.candidateWindowUsed,
            evaluationCount: plannerResult.evaluationCount,
            rotationStartLayoutVariant: plannerResult.rotationStartLayoutVariant,
            rotationStartRatioPreset: plannerResult.rotationStartRatioPreset,
            acceptedLayoutVariant: plannerResult.acceptedLayoutVariant,
            acceptedRatioPreset: plannerResult.acceptedRatioPreset,
            rotationKeyHashPrefix: plannerResult.rotationKeyHashPrefix,
            rejectedLayoutReasonTopList: plannerResult.rejectedLayoutReasonTopList,
            reasonCodes: plannerResult.reasonCodes,
            qaDebugSummary: plannerResult.qaDebugSummary
        )
        let prototypeScene = PlaybackScene(
            id: "scene-smartfill-\(photoSlots.first?.asset.id ?? "empty")",
            photoSlots: photoSlots,
            smartFillReadback: readback
        )
        recordSmartFillStartupFirstPlanMetrics(
            assetPoolSize: assets.count,
            eligibleCandidateCount: candidateSummaries.count,
            plannerResult: plannerResult
        )
        recordSmartFillStartupRuntimePhase("firstScenePlanned")
        return SmartFillScenePlan(
            scene: prototypeScene,
            nextCandidateCursorOffset: smartFillNextCandidateCursorOffset(
                candidateSummaries: candidateSummaries,
                plannerResult: plannerResult,
                fallbackCount: photoSlots.count
            ),
            displayedAssetIds: Set(prototypeScene.assetIds)
        )
    }

    private func recordSmartFillMainActorPlannerCall(_ callSite: SmartFillMainActorPlannerCallSite) {
        #if DEBUG
        smartFillMainActorPlannerCallCountsForTesting[callSite, default: 0] += 1
        #endif
    }

    private func consumePreparedSmartFillNext(
        source: PlaybackSceneTransactionSource
    ) -> PlaybackSessionTransition? {
        let expectedSourceCursor = currentPreparedSmartFillSourceCursor()
        guard let fingerprint = makePreparedSmartFillSceneFingerprint(),
            playbackSessionEngine.invalidatePreparedSceneRing(ifNeededFor: fingerprint) == false,
            let preparedCursorEffect = playbackSessionEngine.preparedSceneRing?.next?.cursorEffect,
            preparedCursorEffect.sourceCursor == expectedSourceCursor,
            let transition = playbackSessionEngine.consumePreparedNext(source: source),
            let cursorEffect = transition.preparedCursorEffect
        else {
            if let preparedCursorEffect = playbackSessionEngine.preparedSceneRing?.next?.cursorEffect,
                preparedCursorEffect.sourceCursor != expectedSourceCursor
            {
                playbackSessionEngine.clearPreparedSceneRing()
            }
            return nil
        }

        let displayedAssetIdsAfterCommit = smartFillDisplayedAssetIdsForPlanning.union(cursorEffect.displayedAssetIds)
        pendingCandidateCursorIndexAfterCommit = cursorIndex(
            afterAdvancingFrom: cursorEffect.sourceCursor,
            by: cursorEffect.nextCandidateCursorOffset,
            excludingDisplayedAssetIds: displayedAssetIdsAfterCommit
        )
        pendingSmartFillDisplayedAssetIdsAfterCommit = displayedAssetIdsAfterCommit
        return transition
    }

    private func currentPreparedSmartFillSourceCursor() -> Int? {
        guard !assets.isEmpty else { return nil }
        let startIndex =
            candidateCursorIndex >= 0 && candidateCursorIndex < assets.count
            ? candidateCursorIndex
            : 0
        return nextCandidateCursorIndex(
            startingAt: startIndex,
            excludingDisplayedAssetIds: smartFillDisplayedAssetIds
        )
    }

    private func cancelSmartFillPreparedRingRefreshTask() {
        smartFillPreparedRingRefreshTask?.cancel()
        smartFillPreparedRingRefreshTask = nil
        smartFillPreparedRingRefreshGeneration = nil
    }

    private func clearSmartFillPreparedRingRefreshTaskIfCurrent(_ generation: UUID) {
        guard smartFillPreparedRingRefreshGeneration == generation else { return }
        smartFillPreparedRingRefreshTask = nil
        smartFillPreparedRingRefreshGeneration = nil
    }

    private func refreshPreparedSmartFillSceneRingIfPossible() {
        cancelSmartFillPreparedRingRefreshTask()

        guard isSmartFillPlanningEnabled, !assets.isEmpty else {
            return
        }
        let sourceCursor = normalizedCandidateCursorIndex()
        guard
            !shouldHoldSmartFillAdvanceForSoloOnlyLoadMore(
                startingAt: sourceCursor,
                reason: "prepareRing"
            )
        else {
            return
        }
        guard let request = capturePreparedSmartFillPlanRequest(startingAt: sourceCursor) else {
            return
        }

        let generation = UUID()
        smartFillPreparedRingRefreshGeneration = generation
        let planningTask = Task.detached(priority: .utility) {
            SmartFillPreparedPlanBuilder.makeResult(for: request)
        }
        smartFillPreparedRingRefreshTask = Task { @MainActor in
            let result = await withTaskCancellationHandler {
                await planningTask.value
            } onCancel: {
                planningTask.cancel()
            }
            guard !Task.isCancelled, let result else {
                self.clearSmartFillPreparedRingRefreshTaskIfCurrent(generation)
                return
            }
            if self.smartFillPreparedRingRefreshGeneration == generation {
                _ = self.applyPreparedSmartFillPlanResultIfFresh(result, request: request)
            }
            self.clearSmartFillPreparedRingRefreshTaskIfCurrent(generation)
        }
    }

    private func applyPreparedSmartFillPlanResultIfFresh(
        _ result: SmartFillPreparedPlanResult,
        request: SmartFillPreparedPlanRequest
    ) -> SmartFillPreparedPlanApplicationOutcome {
        guard isPreparedSmartFillPlanResultFresh(result, request: request) else {
            return .stale
        }
        guard let plan = smartFillScenePlan(from: result) else {
            return .invalid
        }
        guard let fingerprint = makePreparedSmartFillSceneFingerprint() else {
            return .stale
        }
        let previousScene =
            playbackSessionEngine.currentIndex > 0
            ? playbackSessionEngine.scenes[playbackSessionEngine.currentIndex - 1]
            : nil

        playbackSessionEngine.prepareSceneRing(
            fingerprint: fingerprint,
            sourceCursor: result.sourceCursor,
            previous: previousScene,
            current: playbackSessionEngine.currentScene,
            next: plan.scene,
            nextCursorEffect: PlaybackPreparedSceneCursorEffect(
                sourceCursor: result.sourceCursor,
                nextCandidateCursorOffset: plan.nextCandidateCursorOffset,
                displayedAssetIds: plan.displayedAssetIds
            )
        )
        preloadSmartFillMotionPreparedSlotsIfNeeded(scene: plan.scene)
        preloadSmartFillMotionLookaheadSlotsIfNeeded(result: result, request: request)
        let presentationState = playbackSessionEngine.scenePresentationState
        let pendingPlanGenerationIsActive =
            pendingAutomaticScenePlanGeneration.map { generation in
                presentationState.currentTarget?.identity.generation == generation
                    || presentationState.pendingTarget?.identity.generation == generation
            } ?? false
        let canResumeStableDeadlinePlan = presentationState.underlyingPhase == .stablePhoto
        let canResumeExhaustedTargetPlan =
            presentationState.pendingTarget.map {
                presentationState.targetReadiness[$0.identity] == .failed
            } ?? false
        if isAutoPlay,
            pendingPlanGenerationIsActive,
            canResumeStableDeadlinePlan || canResumeExhaustedTargetPlan,
            playbackSessionEngine.pendingTransition == nil
        {
            planAutomaticSceneEffect()
            let updatedState = playbackSessionEngine.scenePresentationState
            let pendingGenerationStillActive =
                pendingAutomaticScenePlanGeneration.map { generation in
                    updatedState.currentTarget?.identity.generation == generation
                        || updatedState.pendingTarget?.identity.generation == generation
                } ?? false
            if !pendingGenerationStillActive {
                pendingAutomaticScenePlanGeneration = nil
            }
        }
        return .applied
    }

    private func preloadSmartFillMotionLookaheadSlotsIfNeeded(
        result: SmartFillPreparedPlanResult,
        request: SmartFillPreparedPlanRequest
    ) {
        guard result.requestId == request.requestId,
            result.sourceCursor == request.candidateCursor,
            result.assetPoolIdentity == request.assetPoolIdentity,
            result.playbackSourceGeneration == request.playbackSourceGeneration
        else {
            return
        }
        let displayedAssetIdsAfterPreparedScene = request.displayedAssetIds.union(result.displayedAssetIds)
        let nextCursor = cursorIndex(
            afterAdvancingFrom: result.sourceCursor,
            by: result.nextCandidateCursorOffset,
            excludingDisplayedAssetIds: displayedAssetIdsAfterPreparedScene
        )
        guard
            let lookaheadRequest = capturePreparedSmartFillPlanRequest(
                startingAt: nextCursor,
                displayedAssetIdsForExclusion: displayedAssetIdsAfterPreparedScene,
                sceneOrdinal: nextCursor
            )
        else {
            return
        }
        let planningTask = Task.detached(priority: .utility) {
            SmartFillPreparedPlanBuilder.makeResult(for: lookaheadRequest)
        }
        Task { @MainActor [weak self] in
            let lookaheadResult = await withTaskCancellationHandler {
                await planningTask.value
            } onCancel: {
                planningTask.cancel()
            }
            guard let self,
                !Task.isCancelled,
                let lookaheadResult,
                self.isSmartFillMotionLookaheadPlanResultFresh(lookaheadResult, request: lookaheadRequest),
                let lookaheadPlan = self.smartFillScenePlan(from: lookaheadResult)
            else {
                return
            }
            self.smartFillMotionLookaheadPreparedPlan = SmartFillMotionLookaheadPreparedPlan(
                request: lookaheadRequest,
                result: lookaheadResult
            )
            if self.applySmartFillMotionLookaheadPreparedPlanIfReady() {
                return
            }
            self.preloadSmartFillMotionPreparedSlotsIfNeeded(scene: lookaheadPlan.scene)
        }
    }

    @discardableResult
    private func applySmartFillMotionLookaheadPreparedPlanIfReady() -> Bool {
        guard let lookaheadPlan = smartFillMotionLookaheadPreparedPlan,
            lookaheadPlan.request.candidateCursor == currentPreparedSmartFillSourceCursor()
        else {
            return false
        }
        smartFillMotionLookaheadPreparedPlan = nil
        return applyPreparedSmartFillPlanResultIfFresh(
            lookaheadPlan.result,
            request: lookaheadPlan.request
        ) == .applied
    }

    private func isSmartFillMotionLookaheadPlanResultFresh(
        _ result: SmartFillPreparedPlanResult,
        request: SmartFillPreparedPlanRequest
    ) -> Bool {
        result.requestId == request.requestId && result.sourceCursor == request.candidateCursor
            && result.assetPoolIdentity == request.assetPoolIdentity
            && result.playbackSourceGeneration == request.playbackSourceGeneration
            && request.playbackSourceGeneration == playbackSourceGeneration
            && request.assetPoolIdentity == smartFillAssetPoolIdentity()
            && request.protectionFingerprint == request.protectionSnapshot.smartFillReplanFingerprint
            && request.protectionFingerprint == smartFillProtectionSnapshot.smartFillReplanFingerprint
            && request.preparedFingerprint == makePreparedSmartFillSceneFingerprint()
            && request.surface == smartFillSurface
            && request.layoutPolicyId == PlaybackSmartFillLayoutPolicy.policy(for: request.surface).layoutPolicyId
            && !assets.isEmpty && isSmartFillPlanningEnabled
    }

    private func preloadSmartFillMotionPreparedSlotsIfNeeded(scene: PlaybackScene) {
        let eligibility = MotionEligibilityPolicy.acceptedSceneRuntime.evaluate(
            MotionEligibilityInput(
                platform: motionPlatformForCurrentSurface(),
                sceneCapability: motionSceneCapability(for: scene),
                displayMode: playbackDisplayMode == .smartFill ? .smartFill : .singlePhoto,
                focalAdapter: .smartFill,
                isReduceMotionEnabled: sceneRenderSnapshot.isReduceMotionEnabled,
                renderRole: .incoming,
                slotReadiness: .ready
            )
        )
        guard eligibility.runtimeIntegration == .acceptedSceneRuntime,
            eligibility.isTransformEnabled || eligibility.isScheduleEnabled
        else {
            return
        }

        var seenAssetIds: Set<String> = []
        let assetIds = scene.photoSlots.compactMap { slot -> String? in
            guard seenAssetIds.insert(slot.asset.id).inserted else { return nil }
            return slot.asset.id
        }
        guard !assetIds.isEmpty else { return }

        if let smartFillMotionPreparedSlotPreloadHookForTesting {
            smartFillMotionPreparedSlotPreloadHookForTesting(assetIds)
            return
        }

        let taskId = UUID()
        smartFillMotionPreparedSlotPreloadTasks[taskId] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.smartFillMotionPreparedSlotPreloadTasks[taskId] = nil
            }
            await withTaskGroup(of: Void.self) { group in
                for assetId in assetIds {
                    group.addTask { @MainActor in
                        guard !Task.isCancelled else { return }
                        await self.downloadManager.loadPhoto(assetId: assetId, size: .fullsize, priority: .high)
                    }
                }
            }
        }
    }

    private func isPreparedSmartFillPlanResultFresh(
        _ result: SmartFillPreparedPlanResult,
        request: SmartFillPreparedPlanRequest
    ) -> Bool {
        guard result.requestId == request.requestId,
            result.sourceCursor == request.candidateCursor,
            result.assetPoolIdentity == request.assetPoolIdentity,
            result.playbackSourceGeneration == request.playbackSourceGeneration,
            request.playbackSourceGeneration == playbackSourceGeneration,
            request.assetPoolIdentity == smartFillAssetPoolIdentity(),
            request.protectionFingerprint == request.protectionSnapshot.smartFillReplanFingerprint,
            request.protectionFingerprint == smartFillProtectionSnapshot.smartFillReplanFingerprint,
            request.preparedFingerprint == makePreparedSmartFillSceneFingerprint(),
            request.surface == smartFillSurface,
            request.layoutPolicyId == PlaybackSmartFillLayoutPolicy.policy(for: request.surface).layoutPolicyId,
            !assets.isEmpty,
            request.candidateCursor == normalizedCandidateCursorIndex(),
            isSmartFillPlanningEnabled
        else {
            return false
        }
        return true
    }

    private func smartFillScenePlan(from result: SmartFillPreparedPlanResult) -> SmartFillScenePlan? {
        guard result.slots.count == result.selectedAssetIds.count else { return nil }

        var assetsById: [String: Asset] = [:]
        for asset in assets where assetsById[asset.id] == nil {
            assetsById[asset.id] = asset
        }
        let photoSlots = zip(result.slots, result.selectedAssetIds).compactMap { slot, assetId -> PhotoSlot? in
            guard let asset = assetsById[assetId] else { return nil }
            return PhotoSlot(
                id: "slot-\(slot.role.rawValue)-\(slot.candidateReference)",
                asset: asset,
                planning: PlaybackPlanningSnapshot.smartFill(
                    slot: slot,
                    plannerResult: result.plannerResult,
                    focalSummary: smartFillFocalSummary(for: asset)
                )
            )
        }
        guard photoSlots.count == result.slots.count, !photoSlots.isEmpty else {
            return nil
        }

        let scene = PlaybackScene(
            id: "scene-smartfill-\(photoSlots.first?.asset.id ?? "empty")",
            photoSlots: photoSlots,
            smartFillReadback: result.readback
        )
        return SmartFillScenePlan(
            scene: scene,
            nextCandidateCursorOffset: result.nextCandidateCursorOffset,
            displayedAssetIds: result.displayedAssetIds
        )
    }

    private func capturePreparedSmartFillPlanRequest(
        startingAt startIndex: Int,
        displayedAssetIdsForExclusion: Set<String>? = nil,
        sceneOrdinal: Int? = nil
    ) -> SmartFillPreparedPlanRequest? {
        guard let smartFillSurface,
            let fingerprint = makePreparedSmartFillSceneFingerprint(),
            isSmartFillPlanningEnabled,
            !assets.isEmpty,
            startIndex >= 0,
            startIndex < assets.count
        else {
            return nil
        }

        let displayedAssetIds = displayedAssetIdsForExclusion ?? smartFillDisplayedAssetIds
        let rawSnapshots = smartFillCandidateAssets(
            startingAt: startIndex,
            displayedAssetIdsForExclusion: displayedAssetIds
        ).map { asset in
            smartFillRawAssetSnapshot(for: asset)
        }
        guard !rawSnapshots.isEmpty else { return nil }
        let policy = PlaybackSmartFillLayoutPolicy.policy(for: smartFillSurface)
        return SmartFillPreparedPlanRequest(
            requestId: UUID(),
            surface: smartFillSurface,
            layoutPolicyId: policy.layoutPolicyId,
            protectionSnapshot: smartFillProtectionSnapshot,
            protectionFingerprint: smartFillProtectionSnapshot.smartFillReplanFingerprint,
            candidateCursor: startIndex,
            displayedAssetIds: displayedAssetIds,
            assetPoolIdentity: fingerprint.assetPoolIdentity,
            playbackSourceGeneration: playbackSourceGeneration,
            playbackSessionSeed: "generation-\(playbackSourceGeneration)",
            sceneOrdinal: sceneOrdinal ?? startIndex,
            preparedFingerprint: fingerprint,
            rawAssetSnapshots: rawSnapshots
        )
    }

    private func smartFillRawAssetSnapshot(for asset: Asset) -> SmartFillPlanningRawAssetSnapshot {
        SmartFillPlanningRawAssetSnapshot(
            assetId: asset.id,
            width: asset.width,
            height: asset.height,
            exifImageWidth: asset.exifInfo?.exifImageWidth,
            exifImageHeight: asset.exifInfo?.exifImageHeight,
            orientation: asset.exifInfo?.orientation,
            thumbhash: asset.thumbhash,
            rawFaces: (asset.people ?? []).flatMap { person in
                (person.faces ?? []).map { face in
                    SmartFillPlanningRawFaceSnapshot(
                        boundingBoxX1: face.boundingBoxX1,
                        boundingBoxX2: face.boundingBoxX2,
                        boundingBoxY1: face.boundingBoxY1,
                        boundingBoxY2: face.boundingBoxY2,
                        imageWidth: face.imageWidth,
                        imageHeight: face.imageHeight,
                        sourceType: face.sourceType
                    )
                }
            }
        )
    }

    private func makePreparedSmartFillSceneFingerprint() -> PlaybackPreparedSceneFingerprint? {
        guard let smartFillSurface else { return nil }
        return PlaybackPreparedSceneFingerprint(
            deviceProfile: smartFillSurface.profile.rawValue,
            orientation: smartFillSurface.orientation.rawValue,
            pointWidth: Double(smartFillSurface.pixelSize.width),
            pointHeight: Double(smartFillSurface.pixelSize.height),
            safeAreaClass: smartFillSurface.safeAreaClass,
            controlBarClass: "soft-overlay",
            exifOverlayClass: "metadata-overlay",
            assetPoolIdentity: smartFillAssetPoolIdentity(),
            playbackSourceIdentity: "\(logName(for: source))-\(playbackSourceGeneration)"
        )
    }

    private func smartFillAssetPoolIdentity() -> String {
        let raw = assets.map(\.id).joined(separator: "|")
        let digest = SHA256.hash(data: Data(raw.utf8))
        let hashText = digest.prefix(Self.identifierDigestPrefixBytes).map { String(format: "%02x", $0) }.joined()
        return "count-\(assets.count)-\(hashText)"
    }

    private func smartFillNextCandidateCursorOffset(
        candidateSummaries: [PlaybackSmartFillCandidateSummary],
        plannerResult: PlaybackSmartFillPlannerResult,
        fallbackCount: Int
    ) -> Int {
        let selectedOffsets = plannerResult.slots.compactMap { slot in
            candidateSummaries.firstIndex { $0.reference == slot.candidateReference }
        }
        guard !selectedOffsets.isEmpty else {
            return max(1, fallbackCount)
        }

        // Only advance to the next unshown candidate, so photos in between are not skipped when lookahead picks a far
        // slot.
        let selectedOffsetSet = Set(selectedOffsets)
        guard selectedOffsetSet.contains(0) else {
            return 0
        }
        for offset in 1..<candidateSummaries.count where !selectedOffsetSet.contains(offset) {
            return offset
        }
        return min(candidateSummaries.count, max(fallbackCount, selectedOffsetSet.count))
    }

    private func smartFillCandidateAssets(
        startingAt startIndex: Int,
        excludingDisplayedAssets: Bool = true,
        displayedAssetIdsForExclusion: Set<String>? = nil
    ) -> [Asset] {
        guard !assets.isEmpty,
            startIndex >= 0,
            startIndex < assets.count
        else {
            return []
        }

        let uniqueAssetCount = Set(assets.map(\.id)).count
        let maxCandidateCount = min(smartFillCandidateWindowCount, uniqueAssetCount)
        let displayedAssetIds = displayedAssetIdsForExclusion ?? smartFillDisplayedAssetIds
        let shouldSkipDisplayedAssets = excludingDisplayedAssets && displayedAssetIds.count < uniqueAssetCount
        var candidateAssets: [Asset] = []
        var candidateAssetIds: Set<String> = []

        for offset in 0..<assets.count {
            let candidate = assets[(startIndex + offset) % assets.count]
            guard candidateAssetIds.insert(candidate.id).inserted else {
                continue
            }
            if shouldSkipDisplayedAssets,
                displayedAssetIds.contains(candidate.id)
            {
                continue
            }
            candidateAssets.append(candidate)
            if candidateAssets.count >= maxCandidateCount {
                break
            }
        }
        return candidateAssets
    }

    private func smartFillCandidateSummary(for asset: Asset) -> PlaybackSmartFillCandidateSummary {
        #if DEBUG
        smartFillCandidateSummaryBuildCountForTestingStorage += 1
        #endif
        let faceRects = FaceBoxGeometry.validate(
            faces: FaceBoxGeometry.collectFaces(from: asset.people),
            asset: asset
        ).compactMap { result -> PlaybackPlanningRect? in
            guard case let .usable(normalizedRect, _) = result else { return nil }
            return PlaybackPlanningRect(
                x: Double(normalizedRect.origin.x),
                y: Double(normalizedRect.origin.y),
                width: Double(normalizedRect.width),
                height: Double(normalizedRect.height)
            )
        }

        return PlaybackSmartFillCandidateSummary(
            reference: smartFillCandidateReference(for: asset.id),
            sourceImage: PlaybackPlanningSourceImageSummary(
                assetPixelSize: PlaybackSmartFillSourceGeometry.displayPixelSize(for: asset),
                exifPixelSize: smartFillPixelSize(
                    width: asset.exifInfo?.exifImageWidth,
                    height: asset.exifInfo?.exifImageHeight
                ),
                orientation: asset.exifInfo?.orientation == nil ? "unknown" : "available"
            ),
            faceRects: faceRects,
            subjectRects: faceRects
        )
    }

    private func smartFillFocalSummary(for asset: Asset) -> PlaybackPlanningFocalSummary? {
        let faceRects = FaceBoxGeometry.validate(
            faces: FaceBoxGeometry.collectFaces(from: asset.people),
            asset: asset
        ).compactMap { result -> PlaybackPlanningRect? in
            guard case let .usable(normalizedRect, _) = result else { return nil }
            return PlaybackPlanningRect(
                x: Double(normalizedRect.origin.x),
                y: Double(normalizedRect.origin.y),
                width: Double(normalizedRect.width),
                height: Double(normalizedRect.height)
            )
        }
        return smartFillFocalSummary(faceRects: faceRects, subjectRects: faceRects)
    }

    private func smartFillFocalSummary(
        faceRects: [PlaybackPlanningRect],
        subjectRects: [PlaybackPlanningRect]
    ) -> PlaybackPlanningFocalSummary? {
        if let face = faceRects.first {
            return PlaybackPlanningFocalSummary(source: .face, rectInSource: face)
        }
        if let subject = subjectRects.first {
            return PlaybackPlanningFocalSummary(source: .subject, rectInSource: subject)
        }
        return nil
    }

    private func smartFillCandidateReference(for rawId: String) -> String {
        let digest = SHA256.hash(data: Data(rawId.utf8))
        let hashText = digest.prefix(Self.identifierDigestPrefixBytes).map { String(format: "%02x", $0) }.joined()
        return "asset_\(hashText)"
    }

    private func smartFillPixelSize(width: Int?, height: Int?) -> PlaybackPlanningPixelSize? {
        guard let width, let height else { return nil }
        return PlaybackPlanningPixelSize(width: width, height: height)
    }

    private func applyPlaybackHistoryLedgerCommit(
        _ pendingCommit: PlaybackHistoryLedgerPendingCommit?,
        committedScene: PlaybackScene?
    ) {
        guard let pendingCommit else { return }
        switch pendingCommit {
        case let .moveCursor(index):
            playbackHistoryLedger.moveCursor(to: index)
        case .appendTail:
            if let committedScene {
                playbackHistoryLedger.append(committedScene)
            }
        }
        pendingPlaybackHistoryLedgerCommits = [:]
    }

    private func playbackManifestTimestamp() -> TimeInterval {
        playbackManifestTimestampProviderForTesting?() ?? Date().timeIntervalSince1970
    }

    private func resetSmartFillStartupRuntimeEvidence() {
        smartFillStartupRuntimePhaseTimestamps = [:]
        smartFillStartupRuntimeMetrics = nil
    }

    private func recordSmartFillStartupRuntimePhase(_ phase: String) {
        guard smartFillStartupRuntimePhaseOrder.contains(phase),
            smartFillStartupRuntimePhaseTimestamps[phase] == nil
        else {
            return
        }
        smartFillStartupRuntimePhaseTimestamps[phase] = playbackManifestTimestamp()
    }

    private func recordSmartFillStartupFirstPlanMetrics(
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

    func recordSmartFillFirstImageDisplayed(assetId: String) {
        downloadManager.recordFirstImageDisplayed(assetId: assetId, size: .fullsize)
    }

    func recordSmartFillFirstImageDisplayedForTesting(assetId: String) {
        recordSmartFillFirstImageDisplayed(assetId: assetId)
    }

    private func smartFillStartupRuntimeSummaryParts(
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

    private func recordActionTimestamp(
        _ timestamp: TimeInterval,
        for transition: PlaybackSessionTransition
    ) {
        pendingSceneActionTimestamps = [transition.transaction.id: timestamp]
    }

    private func recordScenePublishTiming(for transition: PlaybackSessionTransition) {
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

    private func applyCandidateCursorIndexAfterCommit(_ index: Int) {
        guard !assets.isEmpty else {
            candidateCursorIndex = 0
            return
        }
        candidateCursorIndex = min(max(0, index), assets.count - 1)
    }

    private func adjustCandidateCursorAfterRemovingPrefix(_ removeCount: Int) {
        guard removeCount > 0 else { return }
        candidateCursorIndex = max(0, candidateCursorIndex - removeCount)
        if let pendingIndex = pendingCandidateCursorIndexAfterCommit {
            pendingCandidateCursorIndexAfterCommit = max(0, pendingIndex - removeCount)
        }
        if !assets.isEmpty {
            pruneSmartFillDisplayedAssetIdsToCurrentAssets()
            candidateCursorIndex = min(candidateCursorIndex, assets.count - 1)
            if let pendingIndex = pendingCandidateCursorIndexAfterCommit {
                pendingCandidateCursorIndexAfterCommit = min(pendingIndex, assets.count - 1)
            }
        } else {
            smartFillDisplayedAssetIds = []
            pendingSmartFillDisplayedAssetIdsAfterCommit = nil
        }
    }

    private func adjustSmartFillCursorAfterAppendingLoadMore(
        oldCount: Int,
        appendedCount: Int
    ) {
        guard isSmartFillPlanningEnabled,
            isSoloOnlyPlaybackSource,
            pendingSmartFillCursorResumeAfterLoadMoreAssetCount != nil,
            oldCount > 0
        else {
            return
        }

        guard appendedCount > 0,
            oldCount < assets.count
        else {
            clearPendingSmartFillCursorResumeAfterLoadMore(reason: "noUnseenAssets")
            return
        }

        pendingSmartFillCursorResumeAfterLoadMoreAssetCount = nil
        candidateCursorIndex = min(max(0, oldCount), assets.count - 1)
        pendingCandidateCursorIndexAfterCommit = nil
        if let fingerprint = makePreparedSmartFillSceneFingerprint() {
            playbackSessionEngine.invalidatePreparedSceneRing(ifNeededFor: fingerprint)
        }
        refreshPreparedSmartFillSceneRingIfPossible()
    }

    private func clearPendingSmartFillCursorResumeAfterLoadMore(reason: String) {
        guard pendingSmartFillCursorResumeAfterLoadMoreAssetCount != nil else { return }
        pendingSmartFillCursorResumeAfterLoadMoreAssetCount = nil
        logger.notice(
            "smartfill loadMore hold marker cleared reason=\(reason, privacy: .public) assetCount=\(self.assets.count, privacy: .public) candidateCursorIndex=\(self.candidateCursorIndex, privacy: .public)"
        )
    }

    private func pruneSmartFillDisplayedAssetIdsToCurrentAssets() {
        let currentAssetIds = Set(assets.map(\.id))
        smartFillDisplayedAssetIds.formIntersection(currentAssetIds)
        if let pendingAssetIds = pendingSmartFillDisplayedAssetIdsAfterCommit {
            pendingSmartFillDisplayedAssetIdsAfterCommit = pendingAssetIds.intersection(currentAssetIds)
        }
    }

    private var candidateProgressIndexForLoadMore: Int {
        guard !assets.isEmpty else { return 0 }
        let lastCommittedCandidateIndex = candidateCursorIndex == 0 ? assets.count - 1 : candidateCursorIndex - 1
        return min(max(0, lastCommittedCandidateIndex), assets.count - 1)
    }

    // soloOnly starts with a small pool and refills in the background; fetching 100 up front slows startup and fills
    // the cache.

    private func resolveTargetCount(
        for selection: FilterSelection,
        phase: ResolvePhase
    ) -> Int {
        let containsSoloOnly = selection.personFilters.contains { filter in
            filter.matchMode == .soloOnly
        }

        guard containsSoloOnly else {
            return Self.standardPlaybackFetchAssetCount
        }

        switch phase {
        case .initial:
            return Self.initialSoloOnlyPoolAssetCount
        case .loadMore:
            return Self.soloOnlyRefillAssetCount
        }
    }

    static func emptyPlaybackMessage(
        for reason: PlaybackPoolEmptyReason?,
        source: PlaybackSource
    ) -> String {
        let resolvedReason = reason ?? .noMatchingAssets

        switch resolvedReason {
        case .invalidTargetCount:
            return String(localized: "The playback pool request size is invalid. Please try again later.")
        case .noActiveRules:
            return String(localized: "No filters are selected yet. Choose an album or person first.")
        case .strictSoloVisionUnavailable:
            return String(
                localized:
                    "Strict solo detection is not available right now. This device cannot complete local face detection. Try on a real device, or use normal person filtering for now."
            )
        case .noMatchingAssets:
            switch source {
            case .random:
                return String(
                    localized:
                        "Immich did not return any playable photos. Check your server library or network connection.")
            case .filtered:
                return String(localized: "No playable photos match the current filters. Try another album or person.")
            }
        }
    }

    private func updateEmptyPlaybackMessage(
        for assets: [Asset],
        source: PlaybackSource,
        emptyReason: PlaybackPoolEmptyReason?
    ) {
        guard assets.isEmpty else {
            emptyPlaybackMessage = nil
            return
        }

        emptyPlaybackMessage = Self.emptyPlaybackMessage(
            for: emptyReason,
            source: source
        )
    }

    // Clear the old empty state when loading starts or the source changes, so the last round's error does not linger.

    private func clearEmptyPlaybackMessage() {
        emptyPlaybackMessage = nil
    }

    // Read the assetId for logs safely, so debug logging cannot crash on an out-of-range index.

    private func assetId(at index: Int) -> String? {
        scene(at: index)?.primaryAssetId
    }

    func assetIds(in range: ClosedRange<Int>) -> [String] {
        guard !playbackScenes.isEmpty else { return [] }
        let lowerBound = max(0, range.lowerBound)
        let upperBound = min(playbackScenes.count - 1, range.upperBound)
        guard lowerBound <= upperBound else { return [] }

        let scenes = (lowerBound...upperBound).compactMap { index in
            scene(at: index)
        }
        return PlaybackScene.assetIds(in: scenes)
    }

    private func assetIdLogValue(at index: Int) -> String {
        assetId(at: index) ?? "nil"
    }

    func sceneIdLogValue(at index: Int) -> String {
        scene(at: index)?.id ?? "nil"
    }

    // To find repeated playback, filter by the display asset's assetId; do not look only at currentIndex.

    private func logDisplayedAsset(
        reason: String,
        previousIndex: Int,
        previousAssetId: String?,
        requestedIndex: Int,
        displayedIndex: Int
    ) {
        guard let displayedScene = scene(at: displayedIndex),
            let displayedAssetId = displayedScene.primaryAssetId
        else {
            logger.warning(
                "display asset skipped reason=\(reason, privacy: .public) requestedIndex=\(requestedIndex, privacy: .public) displayedIndex=\(displayedIndex, privacy: .public) assetCount=\(self.assets.count, privacy: .public)"
            )
            return
        }

        let previousAssetIdText = previousAssetId ?? "nil"
        let requestedAssetIdText = assetIdLogValue(at: requestedIndex)
        let requestedSceneIdText = sceneIdLogValue(at: requestedIndex)
        logger.notice(
            "display asset reason=\(reason, privacy: .public) displayedIndex=\(displayedIndex, privacy: .public) displayedSceneId=\(displayedScene.id, privacy: .private) displayedAssetId=\(displayedAssetId, privacy: .private) previousIndex=\(previousIndex, privacy: .public) previousAssetId=\(previousAssetIdText, privacy: .private) requestedIndex=\(requestedIndex, privacy: .public) requestedSceneId=\(requestedSceneIdText, privacy: .private) requestedAssetId=\(requestedAssetIdText, privacy: .private) fallbackReason=\(displayedScene.fallbackReason.rawValue, privacy: .public) assetCount=\(self.assets.count, privacy: .public) soloOnly=\(self.isSoloOnlyPlaybackSource ? "true" : "false", privacy: .public)"
        )
        #if DEBUG
        logQAPlaybackSequenceIfNeeded(
            displayedScene: displayedScene,
            displayedAssetId: displayedAssetId
        )
        #endif
    }

    #if DEBUG
    private var isQAPlaybackSequenceEvidenceEnabled: Bool {
        qaPlaybackSequenceEvidenceEnabledForTesting
            || PlatformCompat.shouldRecordPlaybackSequenceForTesting
    }

    private func logQAPlaybackSequenceIfNeeded(
        displayedScene: PlaybackScene,
        displayedAssetId: String
    ) {
        guard isQAPlaybackSequenceEvidenceEnabled else { return }

        ensureQAPlaybackSequenceRecorder()

        let result = qaPlaybackSequenceRecorder?.record(
            PlaybackSequenceDebugRecordInput(
                sceneId: displayedScene.id,
                displayedAssetId: displayedAssetId,
                primaryAssetId: displayedScene.primaryAssetId,
                slotAssetIds: displayedScene.assetIds,
                assetCount: assets.count,
                soloOnly: isSoloOnlyPlaybackSource,
                displayMode: playbackDisplayMode.rawValue,
                sourceSummary: logName(for: source)
            )
        )
        guard let result else { return }

        // QA reads the simulator unified log; do not fall back to print, or smoke capture becomes unreliable.
        if let qaPlaybackSequenceOSLogEmitterForTesting {
            qaPlaybackSequenceOSLogEmitterForTesting(result.osLogLine)
        } else {
            qaPlaybackSequenceLogger.notice("\(result.osLogLine, privacy: .public)")
        }

        if result.didCreateEvidenceFile {
            qaPlaybackSequenceLogger.notice(
                "qa_playback_sequence_evidence_file relativePath=\(result.evidenceRelativePath, privacy: .public)"
            )
        }
    }

    private func logQAPlaybackSequenceEventIfNeeded(_ event: PlaybackSequenceDebugEventInput) {
        guard isQAPlaybackSequenceEvidenceEnabled else { return }

        ensureQAPlaybackSequenceRecorder()
        let result = qaPlaybackSequenceRecorder?.recordEvent(event)
        guard let result else { return }

        if let qaPlaybackSequenceOSLogEmitterForTesting {
            qaPlaybackSequenceOSLogEmitterForTesting(result.osLogLine)
        } else {
            qaPlaybackSequenceLogger.notice("\(result.osLogLine, privacy: .public)")
        }

        if result.didCreateEvidenceFile {
            qaPlaybackSequenceLogger.notice(
                "qa_playback_sequence_evidence_file relativePath=\(result.evidenceRelativePath, privacy: .public)"
            )
        }
    }

    private func ensureQAPlaybackSequenceRecorder() {
        if qaPlaybackSequenceRecorder == nil {
            qaPlaybackSequenceRecorder = PlaybackSequenceDebugRecorder(
                isEnabled: true,
                writesFile: PlatformCompat.shouldRecordPlaybackSequenceForTesting
            )
        }
    }
    #endif

    // On re-entering the page, refresh the autoplay toggle and interval from local settings.
    func refreshAutoPlaySettingsFromStore() {
        applyPlaybackSettings(playbackSettingsStore.load() ?? PlaybackSettings())
    }

    private func rebuildCurrentSceneForDisplayModeChange() {
        guard !assets.isEmpty,
            let currentScene = playbackSessionEngine.currentScene,
            let anchorAssetId = visibleOverlayState?.ownerPrimaryAssetId ?? currentScene.primaryAssetId,
            let anchorIndex = assets.firstIndex(where: { $0.id == anchorAssetId })
        else {
            return
        }

        let anchorAsset = assets[anchorIndex]
        let displayedBeforeCurrent = displayedAssetIdsBeforeCurrentScene()
        let replacementPlan = currentDisplayModeScenePlan(
            anchorAsset: anchorAsset,
            anchorIndex: anchorIndex,
            displayedBeforeCurrent: displayedBeforeCurrent,
            protectionSnapshot: currentScene.protectionSnapshot
        )
        let displayedAssetIdsAfterRebuild = displayedBeforeCurrent.union(replacementPlan.displayedAssetIds)

        guard
            playbackSessionEngine.updateCurrentScene({ currentScene in
                currentScene.replacingDisplayContent(with: replacementPlan.scene)
            })
        else {
            return
        }
        playbackHistoryLedger.replaceCurrent(with: playbackSessionEngine.currentScene ?? currentScene)

        cancelSmartFillPreparedRingRefreshTask()
        pendingCandidateCursorIndexAfterCommit = nil
        pendingSmartFillDisplayedAssetIdsAfterCommit = nil
        pendingSceneActionTimestamps = [:]
        smartFillDisplayedAssetIds = displayedAssetIdsAfterRebuild
        candidateCursorIndex = cursorIndex(
            afterAdvancingFrom: anchorIndex,
            by: replacementPlan.nextCandidateCursorOffset,
            excludingDisplayedAssetIds: smartFillDisplayedAssetIds
        )
        playbackSessionEngine.invalidate(reason: .poolReloaded)
        syncPlaybackReadbackFromEngine()
        refreshPreparedSmartFillSceneRingIfPossible()
    }

    private func currentDisplayModeScenePlan(
        anchorAsset: Asset,
        anchorIndex: Int,
        displayedBeforeCurrent: Set<String>,
        protectionSnapshot: PlaybackProtectionSnapshot
    ) -> SmartFillScenePlan {
        if playbackDisplayMode == .smartFill,
            let plan = makeSmartFillScenePlan(
                startingAt: anchorIndex,
                displayedAssetIdsForExclusion: displayedBeforeCurrent,
                callSite: .displayModeProtectionRebuild
            ),
            plan.scene.smartFillReadback?.fallbackCategory == PlaybackSmartFillFallbackCategory.none
        {
            return plan
        }

        return singlePhotoScenePlan(
            anchorAsset: anchorAsset,
            protectionSnapshot: protectionSnapshot
        )
    }

    private func singlePhotoScenePlan(
        anchorAsset: Asset,
        protectionSnapshot: PlaybackProtectionSnapshot
    ) -> SmartFillScenePlan {
        let scene = PlaybackScene(
            primaryAsset: anchorAsset,
            protectionSnapshot: protectionSnapshot
        )
        return SmartFillScenePlan(
            scene: scene,
            nextCandidateCursorOffset: 1,
            displayedAssetIds: [anchorAsset.id]
        )
    }

    private func displayedAssetIdsBeforeCurrentScene() -> Set<String> {
        let current = max(0, min(currentIndex, playbackSessionEngine.scenes.count))
        guard current > 0 else { return [] }
        return Set(playbackSessionEngine.scenes.prefix(current).flatMap(\.assetIds))
    }

    // After the settings page clears the cache and returns, force-reload the current photo; this does not rely on the
    // slide-change path.

    func forceReloadCurrentAssetAfterCacheClear() async {
        guard let currentId = safeCurrentScene?.primaryAssetId else { return }
        await downloadManager.loadPhoto(assetId: currentId, size: .fullsize, priority: .high)
        await downloadManager.loadPhoto(assetId: currentId, size: .preview, priority: .high)
    }

    var currentPlaybackMode: DefaultPlaybackMode {
        switch source {
        case .random:
            return .random
        case .filtered:
            return .filtered
        }
    }

    // Compare normalized filter snapshots; a different order is not a change. true means the filter pool must be
    // rebuilt.

    func shouldReloadFilteredSource(for latestSelection: FilterSelection) -> Bool {
        guard case .filtered(let currentSelection) = source else {
            return false
        }

        return normalizedSelection(currentSelection) != normalizedSelection(latestSelection)
    }

    // Whether a soloOnly person filter is present; the refill threshold must trigger earlier.

    private var isSoloOnlyPlaybackSource: Bool {
        guard case .filtered(let selection) = source else {
            return false
        }

        return selection.personFilters.contains { filter in
            filter.matchMode == .soloOnly
        }
    }

    // The debug probe only checks the photo on screen, and only in soloOnly; random playback does not show Vision n=x.

    var shouldRunDebugVisionFaceAudit: Bool {
        isSoloOnlyPlaybackSource
    }

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

    func preparePlaybackSourceForPresentation(to newSource: PlaybackSource) {
        resetPlaybackSourceState(to: newSource)
    }

    // Switch source while running and reload the first screen right away.
    func switchPlaybackSource(to newSource: PlaybackSource) async {
        resetPlaybackSourceState(to: newSource)
        await prepareInitialAssets()
    }

    private func resetPlaybackSourceState(to newSource: PlaybackSource) {
        logger.notice(
            "playback source reset from=\(self.logName(for: self.source), privacy: .public) to=\(self.logName(for: newSource), privacy: .public) oldAssetCount=\(self.assets.count, privacy: .public) oldCurrentIndex=\(self.currentIndex, privacy: .public)"
        )
        resetSmartFillStartupRuntimeEvidence()
        source = newSource
        playbackSourceGeneration += 1
        // Reset the index and first preload on a source change, so leftovers from the old mode are not reused.
        applyPlaybackAssets([], invalidationReason: .sourceChanged)
        isLoading = true
        isLoadingMore = false
        clearEmptyPlaybackMessage()
        clearAutoPlayRecoveryMessage()
        clearVisionFaceAuditState()
        didFirstPreload = false
        firstPreloadTask?.cancel()
        firstPreloadTask = nil
    }

    // Normalize filter snapshots before comparing, so array order does not trigger a false change.

    private func normalizedSelection(_ selection: FilterSelection) -> FilterSelection {
        let normalizedAlbumIDs = selection.albumIds
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()

        let normalizedPersonFilters = selection.personFilters
            .filter { !$0.personId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                if lhs.personId == rhs.personId {
                    return lhs.matchMode.rawValue < rhs.matchMode.rawValue
                }
                return lhs.personId < rhs.personId
            }

        let normalizedTagIDs = selection.tagIds
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()

        return FilterSelection(
            albumIds: normalizedAlbumIDs,
            personFilters: normalizedPersonFilters,
            tagIds: normalizedTagIDs,
            rating: selection.rating,
            isFavorite: selection.isFavorite
        )
    }

    // If the generation does not match, drop the old task; it must not write into the new playback source.

    private func makePlaybackLoadIdentity(generation: Int, source: PlaybackSource) -> PlaybackLoadIdentity {
        let sessionIdentity = playbackSessionEngine.currentSessionIdentity
        return PlaybackLoadIdentity(
            generation: generation,
            sourceName: logName(for: source),
            playbackSessionId: sessionIdentity.playbackSessionId,
            sceneId: sessionIdentity.sceneId
        )
    }

    private func isCurrentPlaybackLoad(_ identity: PlaybackLoadIdentity) -> Bool {
        let sessionIdentity = playbackSessionEngine.currentSessionIdentity
        return identity.generation == playbackSourceGeneration
            && identity.sourceName == logName(for: source)
            && identity.playbackSessionId == sessionIdentity.playbackSessionId
            && identity.sceneId == sessionIdentity.sceneId
            && !Task.isCancelled
    }

    private func makePlaybackPoolLoadIdentity(generation: Int, source: PlaybackSource) -> PlaybackPoolLoadIdentity {
        let sessionIdentity = playbackSessionEngine.currentSessionIdentity
        return PlaybackPoolLoadIdentity(
            generation: generation,
            sourceName: logName(for: source),
            playbackSessionId: sessionIdentity.playbackSessionId
        )
    }

    private func isCurrentPlaybackPoolLoad(_ identity: PlaybackPoolLoadIdentity) -> Bool {
        let sessionIdentity = playbackSessionEngine.currentSessionIdentity
        return identity.generation == playbackSourceGeneration
            && identity.sourceName == logName(for: source)
            && identity.playbackSessionId == sessionIdentity.playbackSessionId
            && !Task.isCancelled
    }

    private func isCurrentPlaybackLoad(generation: Int) -> Bool {
        isCurrentPlaybackLoad(makePlaybackLoadIdentity(generation: generation, source: source))
    }

    private func loadMoreErrorKind(_ error: any Error) -> String {
        if error is CancellationError {
            return "cancelled"
        }
        return "failure"
    }

    @discardableResult
    func loadAssets() async -> Bool {
        clearAutoPlayRecoveryMessage()
        clearEmptyPlaybackMessage()
        lastAppliedInitialLoadIdentity = nil
        let loadGeneration = playbackSourceGeneration
        let loadSource = source
        let loadIdentity = makePlaybackLoadIdentity(generation: loadGeneration, source: loadSource)
        recordSmartFillStartupRuntimePhase("assetPoolRequestStarted")

        switch loadSource {
        case .random:

            isLoading = true
            logger.info("load assets begin source=random targetCount=100")
            do {

                let loadedAssets: [Asset]
                if let loadAssetsHookForTesting {
                    loadedAssets = try await loadAssetsHookForTesting(loadSource)
                } else {
                    loadedAssets = try await ImmichAPIService.shared.getRandomAsset(
                        size: Self.standardPlaybackFetchAssetCount)
                }
                guard isCurrentPlaybackLoad(loadIdentity) else {
                    logger.notice(
                        "load assets ignored stale result source=random generation=\(loadGeneration, privacy: .public) currentGeneration=\(self.playbackSourceGeneration, privacy: .public)"
                    )
                    return false
                }
                recordSmartFillStartupRuntimePhase("assetPoolReady")

                applyPlaybackAssets(loadedAssets, invalidationReason: .poolReloaded)
                lastAppliedInitialLoadIdentity = makePlaybackLoadIdentity(
                    generation: loadGeneration,
                    source: loadSource
                )
                updateEmptyPlaybackMessage(
                    for: loadedAssets,
                    source: loadSource,
                    emptyReason: loadedAssets.isEmpty ? .noMatchingAssets : nil
                )
                isLoading = false
                logger.info(
                    "load assets end source=random resultCount=\(loadedAssets.count, privacy: .public)"
                )
            } catch {
                let message = error.localizedDescription
                guard isCurrentPlaybackLoad(loadIdentity) else {
                    logger.notice(
                        "load assets ignored stale failure source=random generation=\(loadGeneration, privacy: .public) currentGeneration=\(self.playbackSourceGeneration, privacy: .public) error=\(message, privacy: .private)"
                    )
                    return false
                }
                logger.error(
                    "load assets failed source=random error=\(message, privacy: .private)"
                )
                emptyPlaybackMessage = String(
                    localized: "Failed to load photos. Check your network or server settings.")
                isLoading = false
            }
        case .filtered(let selection):
            isLoading = true
            let targetCount = resolveTargetCount(for: selection, phase: .initial)
            logger.info(
                "load assets begin source=filtered targetCount=\(targetCount, privacy: .public) selection=\(self.logSummary(for: selection), privacy: .public)"
            )
            do {
                let loadedAssets: [Asset]
                let emptyReason: PlaybackPoolEmptyReason?
                if let loadAssetsHookForTesting {
                    loadedAssets = try await loadAssetsHookForTesting(loadSource)
                    emptyReason = loadedAssets.isEmpty ? .noMatchingAssets : nil
                } else {
                    let resolution = try await resolver.resolveDetailed(
                        selection: selection,
                        targetCount: targetCount
                    )
                    loadedAssets = resolution.assets
                    emptyReason = resolution.emptyReason
                }
                guard isCurrentPlaybackLoad(loadIdentity) else {
                    logger.notice(
                        "load assets ignored stale result source=filtered generation=\(loadGeneration, privacy: .public) currentGeneration=\(self.playbackSourceGeneration, privacy: .public)"
                    )
                    return false
                }
                recordSmartFillStartupRuntimePhase("assetPoolReady")
                applyPlaybackAssets(loadedAssets, invalidationReason: .poolReloaded)
                lastAppliedInitialLoadIdentity = makePlaybackLoadIdentity(
                    generation: loadGeneration,
                    source: loadSource
                )
                updateEmptyPlaybackMessage(
                    for: loadedAssets,
                    source: loadSource,
                    emptyReason: emptyReason
                )
                isLoading = false
                logger.info(
                    "load assets end source=filtered targetCount=\(targetCount, privacy: .public) resultCount=\(loadedAssets.count, privacy: .public)"
                )
            } catch {
                let message = error.localizedDescription
                guard isCurrentPlaybackLoad(loadIdentity) else {
                    logger.notice(
                        "load assets ignored stale failure source=filtered generation=\(loadGeneration, privacy: .public) currentGeneration=\(self.playbackSourceGeneration, privacy: .public) error=\(message, privacy: .private)"
                    )
                    return false
                }
                applyPlaybackAssets([], invalidationReason: .poolReloaded)
                emptyPlaybackMessage = String(
                    localized: "Failed to load photos. Check your network or server settings.")
                logger.error(
                    "load assets failed source=filtered targetCount=\(targetCount, privacy: .public) error=\(message, privacy: .private)"
                )
                isLoading = false
            }

        }
        syncPlaybackReadbackFromEngine()
        return true
    }

    func loadMoreAssets() async {
        // The refill remembers the generation it started with; old results must not be appended after a source change.
        // The refill follows the session, not the current sceneId.

        let loadGeneration = playbackSourceGeneration
        let loadSource = source
        let loadIdentity = makePlaybackPoolLoadIdentity(generation: loadGeneration, source: loadSource)

        switch loadSource {
        case .random:

            isLoadingMore = true
            defer { isLoadingMore = false }
            let oldCount = assets.count
            logger.info(
                "load more begin source=random oldCount=\(oldCount, privacy: .public)"
            )
            #if DEBUG
            logQAPlaybackSequenceEventIfNeeded(
                .loadMoreBegin(
                    sourceSummary: logName(for: loadSource),
                    oldCount: oldCount,
                    targetCount: nil,
                    excludedCount: oldCount
                ))
            #endif
            do {

                let loadedAssets: [Asset]
                if let loadMoreAssetsHookForTesting {
                    loadedAssets = try await loadMoreAssetsHookForTesting(loadSource)
                } else {
                    loadedAssets = try await ImmichAPIService.shared.getRandomAsset(
                        size: Self.standardPlaybackFetchAssetCount)
                }
                guard isCurrentPlaybackPoolLoad(loadIdentity) else {
                    logger.notice(
                        "load more ignored stale result source=random generation=\(loadGeneration, privacy: .public) currentGeneration=\(self.playbackSourceGeneration, privacy: .public)"
                    )
                    return
                }

                let unseenAssets = assetsUnseenInCurrentPool(loadedAssets)
                assets.append(contentsOf: unseenAssets)
                if !assets.isEmpty {
                    clearEmptyPlaybackMessage()
                }

                if assets.count >= maxAssetCount {

                    let removeCount = assets.count - maxAssetCount

                    let currentIndexBeforeTrim = currentIndex
                    let targetIndexBeforeTrim = targetIndex
                    let currentAssetIdBeforeTrim = assetIdLogValue(at: currentIndexBeforeTrim)
                    let targetAssetIdBeforeTrim = assetIdLogValue(at: targetIndexBeforeTrim)
                    let firstRemovedAssetId = removeCount > 0 ? (assets.first?.id ?? "nil") : "nil"
                    let lastRemovedAssetId =
                        removeCount > 0 && removeCount <= assets.count ? assets[removeCount - 1].id : "nil"
                    logger.info(
                        "load more trim source=random removeCount=\(removeCount, privacy: .public) beforeTrimCount=\(self.assets.count, privacy: .public) maxAssetCount=\(self.maxAssetCount, privacy: .public) currentIndexBeforeTrim=\(currentIndexBeforeTrim, privacy: .public) currentAssetIdBeforeTrim=\(currentAssetIdBeforeTrim, privacy: .private) targetIndexBeforeTrim=\(targetIndexBeforeTrim, privacy: .public) targetAssetIdBeforeTrim=\(targetAssetIdBeforeTrim, privacy: .private) firstRemovedAssetId=\(firstRemovedAssetId, privacy: .private) lastRemovedAssetId=\(lastRemovedAssetId, privacy: .private)"
                    )

                    let idsToRemove = assets.prefix(removeCount).map { $0.id }

                    downloadManager.clearCacheFromDisk(assetIds: idsToRemove)

                    assets.removeFirst(removeCount)
                    adjustCandidateCursorAfterRemovingPrefix(removeCount)
                    // After trimming the queue head, move the index back so currentIndex is not in the removed range.
                    syncPlaybackReadbackFromEngine()
                    logger.notice(
                        "load more trim adjusted source=random removeCount=\(removeCount, privacy: .public) currentIndexBeforeTrim=\(currentIndexBeforeTrim, privacy: .public) currentIndexAfterTrim=\(self.currentIndex, privacy: .public) currentAssetIdBeforeTrim=\(currentAssetIdBeforeTrim, privacy: .private) currentAssetIdAfterTrim=\(self.assetIdLogValue(at: self.currentIndex), privacy: .private) targetIndexBeforeTrim=\(targetIndexBeforeTrim, privacy: .public) targetIndexAfterTrim=\(self.targetIndex, privacy: .public) targetAssetIdBeforeTrim=\(targetAssetIdBeforeTrim, privacy: .private) targetAssetIdAfterTrim=\(self.assetIdLogValue(at: self.targetIndex), privacy: .private)"
                    )
                }
                isLoadingMore = false
                #if DEBUG
                logQAPlaybackSequenceEventIfNeeded(
                    .loadMoreResult(
                        sourceSummary: logName(for: loadSource),
                        oldCount: oldCount,
                        targetCount: nil,
                        returnedCount: loadedAssets.count,
                        unseenCount: unseenAssets.count,
                        dedupedCount: loadedAssets.count - unseenAssets.count,
                        finalCount: assets.count
                    ))
                #endif
                logger.info(
                    "load more end source=random addedCount=\(unseenAssets.count, privacy: .public) dedupedCount=\(loadedAssets.count - unseenAssets.count, privacy: .public) finalCount=\(self.assets.count, privacy: .public) currentIndex=\(self.currentIndex, privacy: .public) currentAssetId=\(self.assetIdLogValue(at: self.currentIndex), privacy: .private)"
                )

            } catch {
                let message = error.localizedDescription
                guard isCurrentPlaybackPoolLoad(loadIdentity) else {
                    logger.notice(
                        "load more ignored stale failure source=random generation=\(loadGeneration, privacy: .public) currentGeneration=\(self.playbackSourceGeneration, privacy: .public) error=\(message, privacy: .private)"
                    )
                    return
                }
                #if DEBUG
                logQAPlaybackSequenceEventIfNeeded(
                    .loadMoreFailure(
                        sourceSummary: logName(for: loadSource),
                        oldCount: oldCount,
                        targetCount: nil,
                        errorKind: loadMoreErrorKind(error)
                    ))
                #endif
                logger.error(
                    "load more failed source=random oldCount=\(oldCount, privacy: .public) error=\(message, privacy: .private)"
                )
                isLoadingMore = false
            }
        case .filtered(let selection):
            isLoadingMore = true
            defer { isLoadingMore = false }
            let oldCount = assets.count
            let targetCount = resolveTargetCount(for: selection, phase: .loadMore)
            let excludedAssetIds = Set(assets.map(\.id))
            logger.info(
                "load more begin source=filtered oldCount=\(oldCount, privacy: .public) targetCount=\(targetCount, privacy: .public) selection=\(self.logSummary(for: selection), privacy: .public)"
            )
            #if DEBUG
            logQAPlaybackSequenceEventIfNeeded(
                .loadMoreBegin(
                    sourceSummary: logSummary(for: selection),
                    oldCount: oldCount,
                    targetCount: targetCount,
                    excludedCount: excludedAssetIds.count
                ))
            #endif
            do {
                let loadedAssets: [Asset]
                #if DEBUG
                let strictSoloDebugEvents: [PlaybackSequenceDebugEventInput]
                #endif
                if let loadMoreAssetsHookForTesting {
                    loadedAssets = try await loadMoreAssetsHookForTesting(loadSource)
                    #if DEBUG
                    strictSoloDebugEvents = []
                    #endif
                } else {
                    #if DEBUG
                    let previousDebugEventSink = resolver.playbackSequenceDebugEventSink
                    if isQAPlaybackSequenceEvidenceEnabled {
                        resolver.playbackSequenceDebugEventSink = { [weak self] event in
                            self?.logQAPlaybackSequenceEventIfNeeded(event)
                        }
                    }
                    defer {
                        resolver.playbackSequenceDebugEventSink = previousDebugEventSink
                    }
                    #endif
                    loadedAssets = try await resolver.resolve(
                        selection: selection,
                        targetCount: targetCount,
                        excludingAssetIds: excludedAssetIds
                    )
                    #if DEBUG
                    strictSoloDebugEvents = resolver.strictSoloDebugEventsForTesting
                    #endif
                }
                guard isCurrentPlaybackPoolLoad(loadIdentity) else {
                    logger.notice(
                        "load more ignored stale result source=filtered generation=\(loadGeneration, privacy: .public) currentGeneration=\(self.playbackSourceGeneration, privacy: .public)"
                    )
                    return
                }
                #if DEBUG
                for event in strictSoloDebugEvents {
                    logQAPlaybackSequenceEventIfNeeded(event)
                }
                #endif
                let unseenAssets = assetsUnseenInCurrentPool(loadedAssets)
                if unseenAssets.isEmpty {
                    logger.notice(
                        "load more saturated source=filtered returnedCount=\(loadedAssets.count, privacy: .public) oldCount=\(oldCount, privacy: .public) targetCount=\(targetCount, privacy: .public) selection=\(self.logSummary(for: selection), privacy: .public)"
                    )
                    #if DEBUG
                    logQAPlaybackSequenceEventIfNeeded(
                        .loadMoreSaturated(
                            sourceSummary: logSummary(for: selection),
                            oldCount: oldCount,
                            targetCount: targetCount,
                            returnedCount: loadedAssets.count,
                            unseenCount: unseenAssets.count
                        ))
                    #endif
                }
                assets.append(contentsOf: unseenAssets)
                adjustSmartFillCursorAfterAppendingLoadMore(
                    oldCount: oldCount,
                    appendedCount: unseenAssets.count
                )
                if !assets.isEmpty {
                    clearEmptyPlaybackMessage()
                }
                if assets.count >= maxAssetCount {

                    let removeCount = assets.count - maxAssetCount
                    // Trim log: an unchanged currentAssetId only means the index moved back; a true repeat is when a
                    // display asset shows up again.

                    let currentIndexBeforeTrim = currentIndex
                    let targetIndexBeforeTrim = targetIndex
                    let currentAssetIdBeforeTrim = assetIdLogValue(at: currentIndexBeforeTrim)
                    let targetAssetIdBeforeTrim = assetIdLogValue(at: targetIndexBeforeTrim)
                    let firstRemovedAssetId = removeCount > 0 ? (assets.first?.id ?? "nil") : "nil"
                    let lastRemovedAssetId =
                        removeCount > 0 && removeCount <= assets.count ? assets[removeCount - 1].id : "nil"
                    logger.info(
                        "load more trim source=filtered removeCount=\(removeCount, privacy: .public) beforeTrimCount=\(self.assets.count, privacy: .public) maxAssetCount=\(self.maxAssetCount, privacy: .public) currentIndexBeforeTrim=\(currentIndexBeforeTrim, privacy: .public) currentAssetIdBeforeTrim=\(currentAssetIdBeforeTrim, privacy: .private) targetIndexBeforeTrim=\(targetIndexBeforeTrim, privacy: .public) targetAssetIdBeforeTrim=\(targetAssetIdBeforeTrim, privacy: .private) firstRemovedAssetId=\(firstRemovedAssetId, privacy: .private) lastRemovedAssetId=\(lastRemovedAssetId, privacy: .private)"
                    )

                    let idsToRemove = assets.prefix(removeCount).map { $0.id }

                    downloadManager.clearCacheFromDisk(assetIds: idsToRemove)

                    assets.removeFirst(removeCount)
                    adjustCandidateCursorAfterRemovingPrefix(removeCount)
                    // After trimming the queue head, move the index back so currentIndex is not in the removed range.
                    syncPlaybackReadbackFromEngine()
                    logger.notice(
                        "load more trim adjusted source=filtered removeCount=\(removeCount, privacy: .public) currentIndexBeforeTrim=\(currentIndexBeforeTrim, privacy: .public) currentIndexAfterTrim=\(self.currentIndex, privacy: .public) currentAssetIdBeforeTrim=\(currentAssetIdBeforeTrim, privacy: .private) currentAssetIdAfterTrim=\(self.assetIdLogValue(at: self.currentIndex), privacy: .private) targetIndexBeforeTrim=\(targetIndexBeforeTrim, privacy: .public) targetIndexAfterTrim=\(self.targetIndex, privacy: .public) targetAssetIdBeforeTrim=\(targetAssetIdBeforeTrim, privacy: .private) targetAssetIdAfterTrim=\(self.assetIdLogValue(at: self.targetIndex), privacy: .private)"
                    )
                }
                isLoadingMore = false
                #if DEBUG
                logQAPlaybackSequenceEventIfNeeded(
                    .loadMoreResult(
                        sourceSummary: logSummary(for: selection),
                        oldCount: oldCount,
                        targetCount: targetCount,
                        returnedCount: loadedAssets.count,
                        unseenCount: unseenAssets.count,
                        dedupedCount: loadedAssets.count - unseenAssets.count,
                        finalCount: assets.count
                    ))
                #endif
                logger.info(
                    "load more end source=filtered addedCount=\(unseenAssets.count, privacy: .public) dedupedCount=\(loadedAssets.count - unseenAssets.count, privacy: .public) finalCount=\(self.assets.count, privacy: .public) currentIndex=\(self.currentIndex, privacy: .public) currentAssetId=\(self.assetIdLogValue(at: self.currentIndex), privacy: .private)"
                )
            } catch {
                let message = error.localizedDescription
                guard isCurrentPlaybackPoolLoad(loadIdentity) else {
                    logger.notice(
                        "load more ignored stale failure source=filtered generation=\(loadGeneration, privacy: .public) currentGeneration=\(self.playbackSourceGeneration, privacy: .public) error=\(message, privacy: .private)"
                    )
                    return
                }
                #if DEBUG
                logQAPlaybackSequenceEventIfNeeded(
                    .loadMoreFailure(
                        sourceSummary: logSummary(for: selection),
                        oldCount: oldCount,
                        targetCount: targetCount,
                        errorKind: loadMoreErrorKind(error)
                    ))
                #endif
                logger.error(
                    "load more failed source=filtered oldCount=\(oldCount, privacy: .public) targetCount=\(targetCount, privacy: .public) error=\(message, privacy: .private)"
                )
                clearPendingSmartFillCursorResumeAfterLoadMore(reason: loadMoreErrorKind(error))
                isLoadingMore = false
            }

        }

    }

    private func loadIndexChangePhoto(assetId: String, size: ThumbnailSize) async {
        if let indexChangePhotoLoadHookForTesting {
            await indexChangePhotoLoadHookForTesting(assetId, size)
            return
        }
        await downloadManager.loadPhoto(assetId: assetId, size: size, priority: .high)
    }

    private func sceneUsesSmartFillSlotReadiness(_ scene: PlaybackScene) -> Bool {
        guard let readback = scene.smartFillReadback else { return false }
        return readback.sceneType != .fallback
    }

    private func sceneNeedsPreviewForPlayback(_ scene: PlaybackScene) -> Bool {
        !sceneUsesSmartFillSlotReadiness(scene)
    }

    private func isSceneReadyForPlayback(_ scene: PlaybackScene) -> Bool {
        let needsPreview = sceneNeedsPreviewForPlayback(scene)
        return scene.photoSlots.allSatisfy { slot in
            downloadManager.isReady(assetId: slot.asset.id, size: .fullsize)
                && (!needsPreview || downloadManager.isReady(assetId: slot.asset.id, size: .preview))
        }
    }

    #if DEBUG
    private func playbackImageRequestLifecycleModeForDiagnostics(scene: PlaybackScene)
        -> PlaybackImageRequestLifecycleMode
    {
        sceneUsesSmartFillSlotReadiness(scene) ? .smartfill : .single
    }

    private func recordPlaybackImageRequestLifecycleContextForDiagnostics(
        assetId: String,
        size: ThumbnailSize,
        scene: PlaybackScene,
        role: PlaybackImageRequestLifecycleRole,
        navigationToken: UUID
    ) {
        downloadManager.recordPlaybackImageRequestLifecycleContextForDiagnostics(
            assetId: assetId,
            size: size,
            mode: playbackImageRequestLifecycleModeForDiagnostics(scene: scene),
            role: role,
            navigationToken: navigationToken,
            sceneId: scene.id
        )
    }

    private func recordPreloadWindowLifecycleContextsForDiagnostics(
        assets: [Asset],
        currentIndex: Int,
        preloadCount: Int,
        size: ThumbnailSize
    ) {
        guard !assets.isEmpty,
            currentIndex >= 0,
            currentIndex < assets.count,
            preloadCount >= 0
        else {
            return
        }
        let startIndex = max(0, currentIndex - 2)
        let endIndex = min(currentIndex + preloadCount, assets.count - 1)
        guard startIndex <= endIndex else { return }
        let mode: PlaybackImageRequestLifecycleMode =
            smartFillSurface != nil && isSmartFillPlanningEnabled
            ? .smartfill
            : .single
        for index in startIndex...endIndex {
            downloadManager.recordPlaybackImageRequestLifecycleContextForDiagnostics(
                assetId: assets[index].id,
                size: size,
                mode: mode,
                role: .next,
                navigationToken: targetTransitionToken,
                sceneId: "preload-window"
            )
        }
    }
    #endif

    private func loadSceneAssetsForTransition(
        _ scene: PlaybackScene,
        isPreviousTransition: Bool = false,
        navigationToken: UUID? = nil
    ) async {
        let needsPreview = sceneNeedsPreviewForPlayback(scene)
        for asset in scene.photoSlots.map(\.asset) {
            #if DEBUG
            let roleForDiagnostics: PlaybackImageRequestLifecycleRole = isPreviousTransition ? .previous : .incoming
            recordPlaybackImageRequestLifecycleContextForDiagnostics(
                assetId: asset.id,
                size: .fullsize,
                scene: scene,
                role: roleForDiagnostics,
                navigationToken: navigationToken ?? targetTransitionToken
            )
            #endif
            await loadIndexChangePhoto(assetId: asset.id, size: .fullsize)
            if needsPreview {
                #if DEBUG
                recordPlaybackImageRequestLifecycleContextForDiagnostics(
                    assetId: asset.id,
                    size: .preview,
                    scene: scene,
                    role: roleForDiagnostics,
                    navigationToken: navigationToken ?? targetTransitionToken
                )
                #endif
                await loadIndexChangePhoto(assetId: asset.id, size: .preview)
            }
        }
    }

    private func loadInitialSceneAssetsForPlayback(_ scene: PlaybackScene) async {
        let needsPreview = sceneNeedsPreviewForPlayback(scene)
        for asset in scene.photoSlots.map(\.asset) {
            if let initialPhotoLoadHookForTesting {
                await initialPhotoLoadHookForTesting(asset.id)
            } else {
                #if DEBUG
                recordPlaybackImageRequestLifecycleContextForDiagnostics(
                    assetId: asset.id,
                    size: .fullsize,
                    scene: scene,
                    role: .current,
                    navigationToken: targetTransitionToken
                )
                #endif
                await downloadManager.loadPhoto(assetId: asset.id, size: .fullsize, priority: .high)
                if needsPreview {
                    #if DEBUG
                    recordPlaybackImageRequestLifecycleContextForDiagnostics(
                        assetId: asset.id,
                        size: .preview,
                        scene: scene,
                        role: .current,
                        navigationToken: targetTransitionToken
                    )
                    #endif
                    await downloadManager.loadPhoto(assetId: asset.id, size: .preview, priority: .high)
                }
            }
        }
    }

    @discardableResult
    private func preloadSmartFillCandidateWindowIfNeeded(
        startingAt startIndex: Int,
        excludingDisplayedAssets: Bool = true
    ) async -> Bool {
        guard smartFillSurface != nil,
            isSmartFillPlanningEnabled,
            !assets.isEmpty
        else {
            return false
        }

        let candidateAssets = smartFillCandidateAssets(
            startingAt: startIndex,
            excludingDisplayedAssets: excludingDisplayedAssets
        )
        guard candidateAssets.count > 1 else { return false }

        var didRequestLoad = false
        for asset in candidateAssets {
            if !downloadManager.isReady(assetId: asset.id, size: .fullsize) {
                #if DEBUG
                downloadManager.recordPlaybackImageRequestLifecycleContextForDiagnostics(
                    assetId: asset.id,
                    size: .fullsize,
                    mode: .smartfill,
                    role: .next,
                    navigationToken: targetTransitionToken,
                    sceneId: "smartfill-candidate-window"
                )
                #endif
                await loadIndexChangePhoto(assetId: asset.id, size: .fullsize)
                didRequestLoad = true
            }
        }
        return didRequestLoad
    }

    /// Only committed non-first-screen transitions run the window prefetch; the visible first-screen commit skips it so
    /// it does not compete for first-scene resources.

    private func preloadPlaybackWindowAfterTransitionIfReady() async {
        guard !assets.isEmpty,
            let currentScene = safeCurrentScene,
            isSceneReadyForPlayback(currentScene)
        else {
            return
        }

        let assetsAtTransition = assets
        let currentIndexAtTransition = currentIndex
        let preloadCountAtTransition = preloadCount
        if let transitionWindowPreloadHookForTesting {
            await transitionWindowPreloadHookForTesting(
                assetsAtTransition,
                currentIndexAtTransition,
                preloadCountAtTransition
            )
            return
        }
        #if DEBUG
        recordPreloadWindowLifecycleContextsForDiagnostics(
            assets: assetsAtTransition,
            currentIndex: currentIndexAtTransition,
            preloadCount: preloadCountAtTransition,
            size: .fullsize
        )
        #endif
        await downloadManager.preloadPhotos(
            assets: assetsAtTransition,
            currentIndex: currentIndexAtTransition,
            preloadCount: preloadCountAtTransition,
            size: .fullsize
        )
        #if DEBUG
        recordPreloadWindowLifecycleContextsForDiagnostics(
            assets: assetsAtTransition,
            currentIndex: currentIndexAtTransition,
            preloadCount: preloadCountAtTransition,
            size: .preview
        )
        #endif
        await downloadManager.preloadPhotos(
            assets: assetsAtTransition,
            currentIndex: currentIndexAtTransition,
            preloadCount: preloadCountAtTransition,
            size: .preview
        )
    }

    @discardableResult
    private func rebuildInitialSmartFillSceneIfPossible(
        invalidationReason: PlaybackSessionInvalidationReason
    ) -> Bool {
        guard
            let initialSmartFillPlan = makeSmartFillScenePlan(
                startingAt: 0,
                excludingDisplayedAssets: false,
                callSite: .initialSmartFillRebuild
            )
        else {
            return false
        }

        smartFillDisplayedAssetIds = initialSmartFillPlan.displayedAssetIds
        pendingSmartFillDisplayedAssetIdsAfterCommit = nil
        resetCandidateCursor(nextCandidateCursorOffset: initialSmartFillPlan.nextCandidateCursorOffset)
        playbackSessionEngine.reset(
            with: assets,
            initialScene: initialSmartFillPlan.scene,
            reason: invalidationReason
        )
        syncPlaybackReadbackFromEngine()
        refreshPreparedSmartFillSceneRingIfPossible()
        return true
    }

    private func scheduleSmartFillInitialSceneActivationIfNeeded() {
        guard smartFillSurface != nil,
            isSmartFillPlanningEnabled,
            !assets.isEmpty,
            currentIndex == 0
        else {
            return
        }
        let currentReadback = playbackSessionEngine.currentScene?.smartFillReadback
        guard currentReadback == nil || currentReadback?.fallbackReason == .imageNotReady else {
            return
        }

        smartFillSurfaceActivationTask?.cancel()
        smartFillSurfaceActivationTask = Task { @MainActor in
            // Surface changes often come with safe area / control bar animations; delay once to avoid repeated
            // recalculation in a short time.
            try? await Task.sleep(nanoseconds: Self.surfaceActivationDelayNanoseconds)
            guard !Task.isCancelled else { return }
            if self.rebuildInitialSmartFillSceneIfPossible(invalidationReason: .poolReloaded) {
                let presentationState = self.playbackSessionEngine.scenePresentationState
                if let generation = (presentationState.pendingTarget ?? presentationState.currentTarget)?.identity
                    .generation,
                    let effectTask = self.scenePresentationEffectTasks[generation]
                {
                    await effectTask.value
                }
            }
            self.smartFillSurfaceActivationTask = nil
        }
    }

    #if DEBUG
    func synchronizePlaybackReadbackForTesting(token: UUID, targetIndex: Int) async {
        _ = token
        _ = targetIndex
        syncPlaybackReadbackFromEngine()
    }
    #endif

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

        } else {
            logger.warning(
                "initial prepare ended empty source=\(self.logName(for: self.source), privacy: .public) currentIndex=\(self.currentIndex, privacy: .public) targetIndex=\(self.targetIndex, privacy: .public) fallbackReason=\(PlaybackSceneFallbackReason.emptyPool.rawValue, privacy: .public)"
            )
        }
    }

    // Run the Vision MVP only on the current asset; do not scan the whole pool.

    func refreshVisionFaceAuditForCurrentAsset() async {
        // Cancel any unfinished face-count task first, so a slow photo does not write onto a new one.
        visionFaceAuditTask?.cancel()
        visionFaceAuditTask = nil

        guard shouldRunDebugVisionFaceAudit else {
            // Do not run Vision outside soloOnly, even if the caller missed the playback-mode check.

            visionFaceAuditState = .idle
            return
        }

        guard let asset = safeCurrentAsset else {
            visionFaceAuditState = .idle
            return
        }

        let candidateURLs = visionFaceAuditCandidateURLs(for: asset.id)
        guard !candidateURLs.isEmpty else {
            visionFaceAuditState = .waitingForImage
            return
        }

        visionFaceAuditState = .running
        let assetId = asset.id

        let task = Task {
            let state = await VisionFaceAuditService.audit(
                assetId: assetId,
                candidateURLs: candidateURLs
            )

            guard !Task.isCancelled else { return }
            guard self.safeCurrentAsset?.id == assetId else { return }
            self.visionFaceAuditState = state
        }

        visionFaceAuditTask = task
        await task.value
    }

    // Clear local face-count state when debugging is turned off, the source changes, or the page is left.
    func clearVisionFaceAuditState() {
        visionFaceAuditTask?.cancel()
        visionFaceAuditTask = nil
        visionFaceAuditState = .idle
    }
    /// `.plan` only prepares and publishes the new target; Ready is decided by the renderer barrier.
    private func planAutomaticSceneEffect() {
        guard isAutoPlay, !assets.isEmpty else { return }
        requestNextScene(isManual: false)
    }

    func makeKeepIds(currentIndex: Int) -> Set<String> {
        guard !playbackScenes.isEmpty else { return [] }
        guard currentIndex >= 0, currentIndex < playbackScenes.count else {
            logger.warning(
                "make keep ids invalid currentIndex=\(currentIndex, privacy: .public) sceneCount=\(self.playbackScenes.count, privacy: .public)"
            )
            return []
        }

        let start = max(0, currentIndex - preloadCount)

        let end = min(playbackScenes.count - 1, currentIndex + preloadCount)

        guard start <= end else {
            logger.warning(
                "make keep ids invalid range currentIndex=\(currentIndex, privacy: .public) sceneCount=\(self.playbackScenes.count, privacy: .public) start=\(start, privacy: .public) end=\(end, privacy: .public)"
            )
            return []
        }
        var keepIds = Set(assetIds(in: start...end))
        keepIds.formUnion(PlaybackScene.assetIds(in: playbackScenes))
        if let pendingScene = playbackSessionEngine.pendingTransition?.scene {
            keepIds.formUnion(PlaybackScene.assetIds(in: [pendingScene]))
        }
        return keepIds
    }

    // Runtime messages get a stable localization template first, then format it, to avoid Chinese interpolated keys.

    private func formattedRetryMessage(_ localizationKey: String, retryCount: Int) -> String {
        let format = NSLocalizedString(localizationKey, comment: "")
        return String(
            format: format,
            locale: Locale.current,
            Int64(retryCount),
            Int64(SceneLifecycleContract.retryLimit)
        )
    }

    private func nextPhotoRetryingWhileCurrentKeepsPlayingMessage(retryCount: Int) -> String {
        formattedRetryMessage(
            "Next photo load failed, retrying (%lld/%lld); current photo keeps playing",
            retryCount: retryCount
        )
    }

    // Single entry point for recovery messages, so test branches do not write the property directly.
    private func updateAutoPlayRecoveryMessage(
        _ message: String,
        fallbackReason: PlaybackSceneFallbackReason = .none
    ) {
        autoPlayRecoveryMessage = message
        logger.notice(
            "autoplay recovery message updated currentIndex=\(self.currentIndex, privacy: .public) currentSceneId=\(self.sceneIdLogValue(at: self.currentIndex), privacy: .private) currentAssetId=\(self.assetIdLogValue(at: self.currentIndex), privacy: .private) targetIndex=\(self.targetIndex, privacy: .public) targetSceneId=\(self.sceneIdLogValue(at: self.targetIndex), privacy: .private) targetAssetId=\(self.assetIdLogValue(at: self.targetIndex), privacy: .private) fallbackReason=\(fallbackReason.rawValue, privacy: .public)"
        )
    }

    #if DEBUG
    // UI tests only: inject a recovery message without advancing the state machine or hitting the network.

    func forceNextPhotoRecoveryMessageForUITesting(retryCount: Int = 1) {
        updateAutoPlayRecoveryMessage(
            nextPhotoRetryingWhileCurrentKeepsPlayingMessage(retryCount: retryCount)
        )
    }
    #endif

    // Clear the message after a successful recovery, so old error text does not linger.
    private func clearAutoPlayRecoveryMessage() {
        autoPlayRecoveryMessage = nil
    }

    // Vision MVP tries preview before fullsize because preview is lighter.

    private func visionFaceAuditCandidateURLs(for assetId: String) -> [(ThumbnailSize, URL)] {
        var candidates: [(ThumbnailSize, URL)] = []

        if let previewURL = downloadManager.findURL(assetId: assetId, size: .preview) {
            candidates.append((.preview, previewURL))
        }
        if let fullsizeURL = downloadManager.findURL(assetId: assetId, size: .fullsize) {
            candidates.append((.fullsize, fullsizeURL))
        }

        return candidates
    }

    // Logs record only counts and mode, not the full filter, and take no part in business decisions.

    private func logName(for source: PlaybackSource) -> String {
        switch source {
        case .random:
            return "random"
        case .filtered(let selection):
            return "filtered(\(logSummary(for: selection)))"
        }
    }

    private func logSummary(for selection: FilterSelection) -> String {
        let soloCount = selection.personFilters.filter { $0.matchMode == .soloOnly }.count
        let normalCount = selection.personFilters.filter { $0.matchMode == .normal }.count
        return
            "albums=\(selection.albumIds.count),people=\(selection.personFilters.count),solo=\(soloCount),normal=\(normalCount),tags=\(selection.tagIds.count),rating=\(selection.rating == nil ? "nil" : "set"),favorite=\(selection.isFavorite == nil ? "nil" : "set")"
    }
}

private extension MotionRenderRole {
    init(scenePresentationLayerRole role: PlaybackSessionEngine.ScenePresentationLayerRole) {
        switch role {
        case .stable:
            self = .settled
        case .outgoing:
            self = .outgoing
        case .incoming:
            self = .incoming
        }
    }
}

private extension MotionPlatform {
    init(smartFillSurfaceProfile profile: PlaybackSmartFillSurfaceProfile) {
        switch profile {
        case .iPhone:
            self = .iOS
        case .iPad:
            self = .iPadOS
        case .appleTV:
            self = .tvOS
        }
    }
}
