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

enum PlaybackHistoryLedgerPendingCommit {
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
    private static let autoplayRenderWindowRadius: Int = 1
    private static let manualRenderWindowRadius: Int = 2
    static let identifierDigestPrefixBytes: Int = 8
    static let refillRemainingFractionDivisor: Int = 5
    private static let surfaceActivationDelayNanoseconds: UInt64 = 250_000_000
    private static let diagnosticHistoryLookbackCount: Int = 8

    struct SmartFillScenePlan {
        let scene: PlaybackScene
        let nextCandidateCursorOffset: Int
        let displayedAssetIds: Set<String>
    }

    @Published private(set) var assets: [Asset] = []
    // The current display position is only read back from the engine; views cannot change playback facts directly.
    @Published var currentIndex: Int = 0
    // The target position is an adapter readout of the pending transition.
    @Published var targetIndex: Int = 0
    // The slide-change trigger uses the transition identity, so a reused numeric index does not hide a new scene.
    @Published var targetTransitionToken: UUID = UUID()

    @Published private(set) var isLoading: Bool = true

    @Published private(set) var isLoadingMore: Bool = false

    @Published private(set) var emptyPlaybackMessage: String? = nil

    // didSet does not run during init; any init-time assignment must also initialize the loader with that capacity.
    @Published var maxAssetCount: Int = SlideShowViewModel.maximumPlaybackPoolAssetCount {
        didSet { poolLoader.updateMaximumAssetCount(maxAssetCount) }
    }

    @Published var isAutoPlay: Bool = true

    @Published var autoPlayInterval: Double = PlaybackIntervalPolicy.minimumInterval

    var source: PlaybackSource { poolLoader.currentSource }
    let playbackSettingsStore: PlaybackSettingsStore
    private var playbackSettingsChangeObserver: NSObjectProtocol?

    // The facade and loader share this file so no external caller can apply raw projection updates.
    private let poolLoader: PlaybackPoolLoader

    struct PlaybackLoadIdentity {
        fileprivate let value: PlaybackPoolLoader.InitialLoadIdentity
    }

    var appliedInitialLoadIdentity: PlaybackLoadIdentity? {
        poolLoader.appliedInitialLoadIdentity.map { PlaybackLoadIdentity(value: $0) }
    }

    let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "immichSlides",
        category: "Playback"
    )
    #if DEBUG
    private let qaPlaybackSequenceLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "immichSlides",
        category: "QAPlaybackSequence"
    )
    #endif
    var playbackSessionEngine = PlaybackSessionEngine()
    var playbackHistoryLedger = PlaybackHistoryLedger()
    var pendingPlaybackHistoryLedgerCommits: [UUID: PlaybackHistoryLedgerPendingCommit] = [:]
    var candidateCursorIndex: Int = 0
    var pendingCandidateCursorIndexAfterCommit: Int?
    var smartFillDisplayedAssetIds: Set<String> = []
    var pendingSmartFillDisplayedAssetIdsAfterCommit: Set<String>?
    var pendingSmartFillCursorResumeAfterLoadMoreAssetCount: Int?
    var playbackDisplayMode: PlaybackDisplayMode = .smartFill
    let runtimeEvidenceRecorder = PlaybackRuntimeEvidenceRecorder()
    var smartFillSurface: PlaybackSmartFillSurface?
    var smartFillProtectionSnapshot: PlaybackProtectionSnapshot = .empty
    var smartFillReplanFingerprint: String?
    var smartFillSurfaceActivationTask: Task<Void, Never>?
    var smartFillPreparedRingRefreshTask: Task<Void, Never>?
    var smartFillPreparedRingRefreshGeneration: UUID?
    struct ScenePresentationWakeUpKey: Equatable {
        let generation: UUID
        let deadline: TimeInterval
    }
    var scenePresentationPrerenderBarrier = ScenePresentationPrerenderBarrier()
    var scenePresentationWakeUpTask: Task<Void, Never>?
    var scenePresentationWakeUpKey: ScenePresentationWakeUpKey?
    var scenePresentationEffectTasks: [UUID: Task<Void, Never>] = [:]
    var pendingAutomaticScenePlanGeneration: UUID?
    @Published var scenePresentationRevision = UUID()
    var smartFillMotionPreparedSlotPreloadTasks: [UUID: Task<Void, Never>] = [:]
    struct SmartFillMotionLookaheadPreparedPlan {
        let request: SmartFillPreparedPlanRequest
        let result: SmartFillPreparedPlanResult
    }
    var smartFillMotionLookaheadPreparedPlan: SmartFillMotionLookaheadPreparedPlan?
    #if DEBUG
    var smartFillCandidateSummaryBuildCountForTestingStorage: Int = 0
    var smartFillMainActorPlannerCallCountsForTesting: [SmartFillMainActorPlannerCallSite: Int] = [:]
    #endif
    #if DEBUG
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
    var scenePresentationBarrierAttemptCountForTesting = 0

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
        playbackDisplayMode == .smartFill && !PlatformCompat.shouldForceSinglePhotoPlaybackForTesting
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
        let isSinglePhoto =
            playbackDisplayMode == .singlePhoto || PlatformCompat.shouldForceSinglePhotoPlaybackForTesting
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
    #if DEBUG
    var visibleImageAssetIdProbeLabel: String {
        visibleImageAssetId ?? "no-asset"
    }
    #endif
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
    #if DEBUG
    var overlayAssetIdProbeLabel: String {
        guard let overlayState = visibleOverlayState else { return "no-overlay" }
        return overlayState.ownerPrimaryAssetId ?? "no-asset"
    }
    #endif

    var safeCurrentAsset: Asset? {
        safeCurrentScene?.primaryAsset
    }

    var preloadCount: Int {
        isAutoPlay ? 3 : 5  // Manual navigation may move faster, so preload more.
    }

    let downloadManager: AssetsDownloadManager = AssetsDownloadManager.shared
    // In soloOnly, refill the pool when <= 8 remain instead of waiting for the last 20%; Vision re-checks are slower.

    let soloOnlyLoadMoreRemainingTriggerCount: Int = 8
    let smartFillCandidateWindowCount: Int = 36

    @Published private(set) var autoPlayRecoveryMessage: String? = nil
    #if DEBUG
    var smartFillMotionPreparedSlotPreloadHookForTesting: (([String]) -> Void)? = nil
    #endif
    // Handle for the first preload task, to prevent duplicate loads.
    var firstPreloadTask: Task<Void, Never>? = nil

    var playbackSourceGeneration: Int { poolLoader.sourceGeneration }

    @Published var didFirstPreload: Bool = false
    #if DEBUG
    // Tests can replace the first pool load to simulate a cold-start race where an old task returns late.

    var loadAssetsHookForTesting: ((PlaybackSource) async throws -> [Asset])? {
        get { poolLoader.loadAssetsHookForTesting }
        set { poolLoader.loadAssetsHookForTesting = newValue }
    }
    // Tests can replace the pool refill to simulate an old loadMore returning late.

    var loadMoreAssetsHookForTesting: ((PlaybackSource) async throws -> [Asset])? {
        get { poolLoader.loadMoreAssetsHookForTesting }
        set { poolLoader.loadMoreAssetsHookForTesting = newValue }
    }
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
    #endif
    // Defaults to the random source and a new resolver, so the old random entry point still works.
    init(
        source: PlaybackSource = .random,
        resolver: PlaybackPoolResolver? = nil,
        settingsStore: PlaybackSettingsStore? = nil,
        observeSettingsChanges: Bool? = nil
    ) {
        self.poolLoader = PlaybackPoolLoader(
            source: source, resolver: resolver ?? PlaybackPoolResolver(),
            maximumAssetCount: Self.maximumPlaybackPoolAssetCount
        )
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

    func smartFillReplanFingerprint(
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

    #if DEBUG
    func replacePlaybackAssetsForTesting(_ newAssets: [Asset]) {
        applyPlaybackAssets(newAssets, invalidationReason: .poolReloaded)
    }

    // Raw fixture writes preserve the existing session, cursor and publication count.
    func overwritePlaybackPoolWithoutResetForTesting(_ newAssets: [Asset]) {
        poolLoader.replaceAssets(newAssets, update: applyPlaybackPoolUpdate)
    }

    func setPlaybackLoadingForTesting(_ value: Bool) {
        poolLoader.setLoadingForTesting(value, update: applyPlaybackPoolUpdate)
    }

    func setPlaybackLoadingMoreForTesting(_ value: Bool) {
        poolLoader.setLoadingMoreForTesting(value, update: applyPlaybackPoolUpdate)
    }
    #endif

    func applyPlaybackHistoryLedgerCommit(
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

    func applyCandidateCursorIndexAfterCommit(_ index: Int) {
        guard !assets.isEmpty else {
            candidateCursorIndex = 0
            return
        }
        candidateCursorIndex = min(max(0, index), assets.count - 1)
    }

    func adjustCandidateCursorAfterRemovingPrefix(_ removeCount: Int) {
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

    func adjustSmartFillCursorAfterAppendingLoadMore(
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

    func clearPendingSmartFillCursorResumeAfterLoadMore(reason: String) {
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

    var candidateProgressIndexForLoadMore: Int {
        guard !assets.isEmpty else { return 0 }
        let lastCommittedCandidateIndex = candidateCursorIndex == 0 ? assets.count - 1 : candidateCursorIndex - 1
        return min(max(0, lastCommittedCandidateIndex), assets.count - 1)
    }

    static func emptyPlaybackMessage(
        for reason: PlaybackPoolEmptyReason?,
        source: PlaybackSource
    ) -> String {
        PlaybackPoolLoader.emptyMessage(for: reason, source: source)
    }

    // Each loader mutation publishes synchronously; append and trim remain separate emissions.
    private func applyPlaybackPoolUpdate(_ update: PlaybackPoolLoader.Update) {
        switch update {
        case .assets(let newAssets):
            assets = newAssets
        case .loading(let value):
            isLoading = value
        case .loadingMore(let value):
            isLoadingMore = value
        case .emptyMessage(let message):
            emptyPlaybackMessage = message
        case .replacePool(let newAssets, let reason):
            applyPlaybackAssets(newAssets, invalidationReason: reason)
        case .replaceInitialPool(let newAssets, let identity):
            applyPlaybackAssets(newAssets, invalidationReason: .poolReloaded)
            poolLoader.recordAppliedInitialLoad(identity, context: playbackPoolSessionContext)
        case .startupPhase(let phase):
            recordSmartFillStartupRuntimePhase(phase)
        case .resumeFilteredCursor(let oldCount, let appendedCount):
            adjustSmartFillCursorAfterAppendingLoadMore(oldCount: oldCount, appendedCount: appendedCount)
        case .clearPendingCursorResume(let reason):
            clearPendingSmartFillCursorResumeAfterLoadMore(reason: reason)
        case .evictCachedAssets(let assetIDs):
            downloadManager.clearCacheFromDisk(assetIds: assetIDs)
        case .adjustCursorAfterTrim(let removeCount):
            adjustCandidateCursorAfterRemovingPrefix(removeCount)
        case .syncReadback:
            syncPlaybackReadbackFromEngine()
        case .refillFinished(let source, let addedCount, let dedupedCount):
            logger.info(
                "load more end source=\(source, privacy: .public) addedCount=\(addedCount, privacy: .public) dedupedCount=\(dedupedCount, privacy: .public) finalCount=\(self.assets.count, privacy: .public) currentIndex=\(self.currentIndex, privacy: .public) currentAssetId=\(self.assetIdLogValue(at: self.currentIndex), privacy: .private)"
            )
        #if DEBUG
        case .sequenceEvent(let event):
            logQAPlaybackSequenceEventIfNeeded(event)
        #endif
        }
    }

    // Read the assetId for logs safely, so debug logging cannot crash on an out-of-range index.

    func assetId(at index: Int) -> String? {
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

    func assetIdLogValue(at index: Int) -> String {
        assetId(at: index) ?? "nil"
    }

    func sceneIdLogValue(at index: Int) -> String {
        scene(at: index)?.id ?? "nil"
    }

    // To find repeated playback, filter by the display asset's assetId; do not look only at currentIndex.

    func logDisplayedAsset(
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
    var isQAPlaybackSequenceEvidenceEnabled: Bool {
        qaPlaybackSequenceEvidenceEnabledForTesting
            || PlatformCompat.shouldRecordPlaybackSequenceForTesting
    }

    private func logQAPlaybackSequenceIfNeeded(
        displayedScene: PlaybackScene,
        displayedAssetId: String
    ) {
        guard isQAPlaybackSequenceEvidenceEnabled else { return }

        let result = runtimeEvidenceRecorder.recordPlaybackSequence(
            PlaybackSequenceDebugRecordInput(
                sceneId: displayedScene.id,
                displayedAssetId: displayedAssetId,
                primaryAssetId: displayedScene.primaryAssetId,
                slotAssetIds: displayedScene.assetIds,
                assetCount: assets.count,
                soloOnly: isSoloOnlyPlaybackSource,
                displayMode: playbackDisplayMode.rawValue,
                sourceSummary: logName(for: source)
            ),
            writesFile: PlatformCompat.shouldRecordPlaybackSequenceForTesting
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

    func logQAPlaybackSequenceEventIfNeeded(_ event: PlaybackSequenceDebugEventInput) {
        guard isQAPlaybackSequenceEvidenceEnabled else { return }

        let result = runtimeEvidenceRecorder.recordPlaybackSequenceEvent(
            event, writesFile: PlatformCompat.shouldRecordPlaybackSequenceForTesting
        )
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

    #endif

    // On re-entering the page, refresh the autoplay toggle and interval from local settings.
    func refreshAutoPlaySettingsFromStore() {
        applyPlaybackSettings(playbackSettingsStore.load() ?? PlaybackSettings())
    }

    func rebuildCurrentSceneForDisplayModeChange() {
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
        runtimeEvidenceRecorder.resetActionTimings()
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

    func recordPreloadWindowLifecycleContextsForDiagnostics(
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

    func loadSceneAssetsForTransition(
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

    func loadInitialSceneAssetsForPlayback(_ scene: PlaybackScene) async {
        let needsPreview = sceneNeedsPreviewForPlayback(scene)
        for asset in scene.photoSlots.map(\.asset) {
            #if DEBUG
            if let initialPhotoLoadHookForTesting {
                await initialPhotoLoadHookForTesting(asset.id)
                continue
            }
            #endif
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

    @discardableResult
    func preloadSmartFillCandidateWindowIfNeeded(
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

    func preloadPlaybackWindowAfterTransitionIfReady() async {
        guard !assets.isEmpty,
            let currentScene = safeCurrentScene,
            isSceneReadyForPlayback(currentScene)
        else {
            return
        }

        let assetsAtTransition = assets
        let currentIndexAtTransition = currentIndex
        let preloadCountAtTransition = preloadCount
        #if DEBUG
        if let transitionWindowPreloadHookForTesting {
            await transitionWindowPreloadHookForTesting(
                assetsAtTransition,
                currentIndexAtTransition,
                preloadCountAtTransition
            )
            return
        }
        #endif
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
    func rebuildInitialSmartFillSceneIfPossible(
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

    // Run the Vision MVP only on the current asset; do not scan the whole pool.

    #if DEBUG
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
    #endif

    // Clear local face-count state when debugging is turned off, the source changes, or the page is left.
    #if DEBUG
    func clearVisionFaceAuditState() {
        visionFaceAuditTask?.cancel()
        visionFaceAuditTask = nil
        visionFaceAuditState = .idle
    }
    #endif
    /// `.plan` only prepares and publishes the new target; Ready is decided by the renderer barrier.
    func planAutomaticSceneEffect() {
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

    func forceNextPhotoRecoveryMessageForTesting(retryCount: Int = 1) {
        updateAutoPlayRecoveryMessage(
            nextPhotoRetryingWhileCurrentKeepsPlayingMessage(retryCount: retryCount)
        )
    }
    #endif

    // Clear the message after a successful recovery, so old error text does not linger.
    func clearAutoPlayRecoveryMessage() {
        autoPlayRecoveryMessage = nil
    }

    // Vision MVP tries preview before fullsize because preview is lighter.

    #if DEBUG
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
    #endif

    // Logs record only counts and mode, not the full filter, and take no part in business decisions.

    func logName(for source: PlaybackSource) -> String {
        PlaybackPoolLoader.logName(for: source)
    }

    func logSummary(for selection: FilterSelection) -> String {
        PlaybackPoolLoader.logSummary(for: selection)
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

extension SlideShowViewModel {
    // Compare normalized filter snapshots; a different order is not a change. true means the filter pool must be
    // rebuilt.

    func shouldReloadFilteredSource(for latestSelection: FilterSelection) -> Bool {
        poolLoader.shouldReloadFilteredSource(for: latestSelection)
    }

    // Whether a soloOnly person filter is present; the refill threshold must trigger earlier.

    var isSoloOnlyPlaybackSource: Bool {
        poolLoader.isSoloOnlySource
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
        poolLoader.resetSource(to: newSource, update: applyPlaybackPoolUpdate)
        clearAutoPlayRecoveryMessage()
        #if DEBUG
        clearVisionFaceAuditState()
        #endif
        didFirstPreload = false
        firstPreloadTask?.cancel()
        firstPreloadTask = nil
    }

    private var playbackPoolSessionContext: PlaybackPoolLoader.SessionContext {
        let identity = playbackSessionEngine.currentSessionIdentity
        return PlaybackPoolLoader.SessionContext(
            playbackSessionId: identity.playbackSessionId, sceneId: identity.sceneId)
    }

    func isCurrentPlaybackLoad(_ identity: PlaybackLoadIdentity) -> Bool {
        poolLoader.isCurrentInitialLoad(identity.value, context: playbackPoolSessionContext)
    }

    @discardableResult
    func loadAssets() async -> Bool {
        clearAutoPlayRecoveryMessage()
        poolLoader.clearEmptyMessage(update: applyPlaybackPoolUpdate)
        let request = poolLoader.beginInitialLoad(
            context: playbackPoolSessionContext, update: applyPlaybackPoolUpdate)
        let result = await poolLoader.acquireInitial(request)
        // Read the live engine identity after acquisition; same-generation engine replacement must reject old work.
        guard
            poolLoader.applyInitial(
                result, context: playbackPoolSessionContext, update: applyPlaybackPoolUpdate)
        else {
            return false
        }
        syncPlaybackReadbackFromEngine()
        return true
    }

    func loadMoreAssets() async {
        let request = poolLoader.beginRefill(
            context: playbackPoolSessionContext, update: applyPlaybackPoolUpdate)
        defer { poolLoader.finishLoadingMore(request, update: applyPlaybackPoolUpdate) }
        #if DEBUG
        let result = await poolLoader.acquireRefill(
            request,
            sequenceEventSink: { [weak self] event in self?.logQAPlaybackSequenceEventIfNeeded(event) },
            isSequenceEvidenceEnabled: isQAPlaybackSequenceEvidenceEnabled
        )
        #else
        let result = await poolLoader.acquireRefill(request)
        #endif
        var trimReadback: PoolTrimReadback?
        poolLoader.applyRefill(
            result, context: playbackPoolSessionContext, update: applyPlaybackPoolUpdate,
            observeTrim: { observation in
                switch observation {
                case .willTrim(let source, let removeCount):
                    trimReadback = logPoolWillTrim(source: source, removeCount: removeCount)
                case .didTrim(let source, let removeCount):
                    if let trimReadback {
                        logPoolDidTrim(source: source, removeCount: removeCount, before: trimReadback)
                    }
                }
            })
    }

    private struct PoolTrimReadback {
        let currentIndex: Int
        let targetIndex: Int
        let currentAssetId: String
        let targetAssetId: String
    }

    // Trim log: an unchanged currentAssetId only means the index moved back; a true repeat is when a
    // display asset shows up again.
    private func logPoolWillTrim(source: String, removeCount: Int) -> PoolTrimReadback {
        let before = PoolTrimReadback(
            currentIndex: currentIndex, targetIndex: targetIndex,
            currentAssetId: assetIdLogValue(at: currentIndex),
            targetAssetId: assetIdLogValue(at: targetIndex)
        )
        let firstRemovedAssetId = removeCount > 0 ? (assets.first?.id ?? "nil") : "nil"
        let lastRemovedAssetId =
            removeCount > 0 && removeCount <= assets.count ? assets[removeCount - 1].id : "nil"
        logger.info(
            "load more trim source=\(source, privacy: .public) removeCount=\(removeCount, privacy: .public) beforeTrimCount=\(self.assets.count, privacy: .public) maxAssetCount=\(self.maxAssetCount, privacy: .public) currentIndexBeforeTrim=\(before.currentIndex, privacy: .public) currentAssetIdBeforeTrim=\(before.currentAssetId, privacy: .private) targetIndexBeforeTrim=\(before.targetIndex, privacy: .public) targetAssetIdBeforeTrim=\(before.targetAssetId, privacy: .private) firstRemovedAssetId=\(firstRemovedAssetId, privacy: .private) lastRemovedAssetId=\(lastRemovedAssetId, privacy: .private)"
        )
        return before
    }

    private func logPoolDidTrim(source: String, removeCount: Int, before: PoolTrimReadback) {
        logger.notice(
            "load more trim adjusted source=\(source, privacy: .public) removeCount=\(removeCount, privacy: .public) currentIndexBeforeTrim=\(before.currentIndex, privacy: .public) currentIndexAfterTrim=\(self.currentIndex, privacy: .public) currentAssetIdBeforeTrim=\(before.currentAssetId, privacy: .private) currentAssetIdAfterTrim=\(self.assetIdLogValue(at: self.currentIndex), privacy: .private) targetIndexBeforeTrim=\(before.targetIndex, privacy: .public) targetIndexAfterTrim=\(self.targetIndex, privacy: .public) targetAssetIdBeforeTrim=\(before.targetAssetId, privacy: .private) targetAssetIdAfterTrim=\(self.assetIdLogValue(at: self.targetIndex), privacy: .private)"
        )
    }

    private func applyPlaybackAssets(
        _ newAssets: [Asset],
        invalidationReason: PlaybackSessionInvalidationReason
    ) {
        smartFillSurfaceActivationTask?.cancel()
        smartFillSurfaceActivationTask = nil
        cancelSmartFillPreparedRingRefreshTask()
        resetScenePresentationRuntime()
        poolLoader.replaceAssets(newAssets, update: applyPlaybackPoolUpdate)
        smartFillDisplayedAssetIds = []
        pendingSmartFillDisplayedAssetIdsAfterCommit = nil
        runtimeEvidenceRecorder.resetActionTimings()
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
        runtimeEvidenceRecorder.resetScenePresentation()
        publishScenePresentationChange()
    }

}

/// Owns the ordered source pool. Acquisition never commits; the facade supplies current session values on apply.
@MainActor
fileprivate final class PlaybackPoolLoader {
    struct SessionContext {
        let playbackSessionId: UUID
        let sceneId: String?
    }

    struct InitialLoadIdentity {
        fileprivate let generation: Int
        fileprivate let sourceName: String
        fileprivate let context: SessionContext
    }

    struct InitialRequest {
        fileprivate let identity: InitialLoadIdentity
        fileprivate let source: PlaybackSource
        fileprivate let targetCount: Int
    }

    struct InitialResult {
        fileprivate let request: InitialRequest
        fileprivate let outcome: Result<PlaybackPoolResolveResult, any Error>
    }

    struct RefillRequest {
        fileprivate let requestID: UUID
        fileprivate let generation: Int
        fileprivate let source: PlaybackSource
        fileprivate let playbackSessionId: UUID
        fileprivate let oldCount: Int
        fileprivate let targetCount: Int
        fileprivate let excludedAssetIds: Set<String>
    }

    struct RefillResult {
        fileprivate let request: RefillRequest
        fileprivate let outcome: Result<[Asset], any Error>
        #if DEBUG
        fileprivate var strictSoloDebugEvents: [PlaybackSequenceDebugEventInput] = []
        #endif
    }

    enum Update {
        case assets([Asset])
        case loading(Bool)
        case loadingMore(Bool)
        case emptyMessage(String?)
        case replacePool([Asset], PlaybackSessionInvalidationReason)
        case replaceInitialPool([Asset], InitialLoadIdentity)
        case startupPhase(String)
        case resumeFilteredCursor(oldCount: Int, appendedCount: Int)
        case clearPendingCursorResume(reason: String)
        case evictCachedAssets([String])
        case adjustCursorAfterTrim(Int)
        case syncReadback
        case refillFinished(source: String, addedCount: Int, dedupedCount: Int)
        #if DEBUG
        case sequenceEvent(PlaybackSequenceDebugEventInput)
        #endif
    }

    enum TrimObservation {
        case willTrim(source: String, removeCount: Int)
        case didTrim(source: String, removeCount: Int)
    }

    private static let standardFetchAssetCount = 100
    private static let initialSoloOnlyAssetCount = 12
    private static let soloOnlyRefillAssetCount = 24
    private var source: PlaybackSource
    private var generation = 0
    private var assets: [Asset] = []
    private var maximumAssetCount: Int
    private var loadMoreLoadingRequestID: UUID?
    private var lastAppliedInitialLoadIdentity: InitialLoadIdentity?
    private let resolver: PlaybackPoolResolver
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "immichSlides", category: "Playback")

    #if DEBUG
    var loadAssetsHookForTesting: ((PlaybackSource) async throws -> [Asset])?
    var loadMoreAssetsHookForTesting: ((PlaybackSource) async throws -> [Asset])?
    #endif

    init(source: PlaybackSource, resolver: PlaybackPoolResolver, maximumAssetCount: Int) {
        self.source = source
        self.resolver = resolver
        self.maximumAssetCount = maximumAssetCount
    }

    var currentSource: PlaybackSource { source }
    var sourceGeneration: Int { generation }
    var appliedInitialLoadIdentity: InitialLoadIdentity? { lastAppliedInitialLoadIdentity }

    func updateMaximumAssetCount(_ count: Int) {
        maximumAssetCount = count
    }

    var isSoloOnlySource: Bool {
        guard case .filtered(let selection) = source else { return false }
        return selection.personFilters.contains { $0.matchMode == .soloOnly }
    }

    func shouldReloadFilteredSource(for latestSelection: FilterSelection) -> Bool {
        guard case .filtered(let currentSelection) = source else { return false }
        return normalizedSelection(currentSelection) != normalizedSelection(latestSelection)
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

    func recordAppliedInitialLoad(_ identity: InitialLoadIdentity, context: SessionContext) {
        lastAppliedInitialLoadIdentity = InitialLoadIdentity(
            generation: identity.generation, sourceName: identity.sourceName, context: context)
    }

    // Clear the old empty state when loading starts or the source changes, so the last round's error does not linger.
    func clearEmptyMessage(update: (Update) -> Void) {
        update(.emptyMessage(nil))
    }

    func resetSource(to newSource: PlaybackSource, update: (Update) -> Void) {
        source = newSource
        generation += 1
        // Reset the index and first preload on a source change, so leftovers from the old mode are not reused.
        update(.replacePool([], .sourceChanged))
        setLoading(true, update: update)
        loadMoreLoadingRequestID = nil
        setLoadingMore(false, update: update)
        clearEmptyMessage(update: update)
    }

    func replaceAssets(_ newAssets: [Asset], update: (Update) -> Void) {
        assets = newAssets
        update(.assets(assets))
    }

    #if DEBUG
    func setLoadingForTesting(_ value: Bool, update: (Update) -> Void) {
        setLoading(value, update: update)
    }

    func setLoadingMoreForTesting(_ value: Bool, update: (Update) -> Void) {
        setLoadingMore(value, update: update)
    }
    #endif

    func isCurrentInitialLoad(_ identity: InitialLoadIdentity, context: SessionContext) -> Bool {
        identity.generation == generation
            && identity.sourceName == Self.logName(for: source)
            && identity.context.playbackSessionId == context.playbackSessionId
            && identity.context.sceneId == context.sceneId
            && !Task.isCancelled
    }

    func beginInitialLoad(context: SessionContext, update: (Update) -> Void) -> InitialRequest {
        lastAppliedInitialLoadIdentity = nil
        let loadSource = source
        let identity = makeInitialLoadIdentity(
            generation: generation, source: loadSource, context: context)
        update(.startupPhase("assetPoolRequestStarted"))
        switch loadSource {
        case .random:
            setLoading(true, update: update)
            logger.info("load assets begin source=random targetCount=100")
            return InitialRequest(
                identity: identity, source: loadSource, targetCount: Self.standardFetchAssetCount)
        case .filtered(let selection):
            setLoading(true, update: update)
            let targetCount = resolveTargetCount(for: selection, isInitial: true)
            logger.info(
                "load assets begin source=filtered targetCount=\(targetCount, privacy: .public) selection=\(Self.logSummary(for: selection), privacy: .public)"
            )
            return InitialRequest(identity: identity, source: loadSource, targetCount: targetCount)
        }
    }

    func acquireInitial(_ request: InitialRequest) async -> InitialResult {
        do {
            let resolution: PlaybackPoolResolveResult
            switch request.source {
            case .random:
                let loadedAssets: [Asset]
                #if DEBUG
                if let loadAssetsHookForTesting {
                    loadedAssets = try await loadAssetsHookForTesting(request.source)
                } else {
                    loadedAssets = try await ImmichAPIService.shared.getRandomAsset(
                        size: Self.standardFetchAssetCount)
                }
                #else
                loadedAssets = try await ImmichAPIService.shared.getRandomAsset(
                    size: Self.standardFetchAssetCount)
                #endif
                resolution = PlaybackPoolResolveResult(
                    assets: loadedAssets, emptyReason: loadedAssets.isEmpty ? .noMatchingAssets : nil)
            case .filtered(let selection):
                #if DEBUG
                if let loadAssetsHookForTesting {
                    let loadedAssets = try await loadAssetsHookForTesting(request.source)
                    resolution = PlaybackPoolResolveResult(
                        assets: loadedAssets, emptyReason: loadedAssets.isEmpty ? .noMatchingAssets : nil)
                } else {
                    resolution = try await resolver.resolveDetailed(
                        selection: selection, targetCount: request.targetCount)
                }
                #else
                resolution = try await resolver.resolveDetailed(
                    selection: selection, targetCount: request.targetCount)
                #endif
            }
            return InitialResult(request: request, outcome: .success(resolution))
        } catch {
            return InitialResult(request: request, outcome: .failure(error))
        }
    }

    func applyInitial(_ result: InitialResult, context: SessionContext, update: (Update) -> Void)
        -> Bool
    {
        let request = result.request
        let loadGeneration = request.identity.generation
        let sourceKind = kindName(for: request.source)
        switch result.outcome {
        case .success(let resolution):
            guard isCurrentInitialLoad(request.identity, context: context) else {
                logger.notice(
                    "load assets ignored stale result source=\(sourceKind, privacy: .public) generation=\(loadGeneration, privacy: .public) currentGeneration=\(self.generation, privacy: .public)"
                )
                return false
            }
            switch request.source {
            case .random:
                update(.startupPhase("assetPoolReady"))
                update(.replaceInitialPool(resolution.assets, request.identity))
                update(
                    .emptyMessage(
                        resolution.assets.isEmpty
                            ? Self.emptyMessage(for: resolution.emptyReason, source: request.source) : nil))
                setLoading(false, update: update)
                logger.info(
                    "load assets end source=random resultCount=\(resolution.assets.count, privacy: .public)")
            case .filtered:
                update(.startupPhase("assetPoolReady"))
                update(.replaceInitialPool(resolution.assets, request.identity))
                update(
                    .emptyMessage(
                        resolution.assets.isEmpty
                            ? Self.emptyMessage(for: resolution.emptyReason, source: request.source) : nil))
                setLoading(false, update: update)
                logger.info(
                    "load assets end source=filtered targetCount=\(request.targetCount, privacy: .public) resultCount=\(resolution.assets.count, privacy: .public)"
                )
            }
        case .failure(let error):
            let message = error.localizedDescription
            guard isCurrentInitialLoad(request.identity, context: context) else {
                logger.notice(
                    "load assets ignored stale failure source=\(sourceKind, privacy: .public) generation=\(loadGeneration, privacy: .public) currentGeneration=\(self.generation, privacy: .public) error=\(message, privacy: .private)"
                )
                return false
            }
            switch request.source {
            case .random:
                logger.error("load assets failed source=random error=\(message, privacy: .private)")
                update(
                    .emptyMessage(
                        String(localized: "Failed to load photos. Check your network or server settings.")))
                setLoading(false, update: update)
            case .filtered:
                update(.replacePool([], .poolReloaded))
                update(
                    .emptyMessage(
                        String(localized: "Failed to load photos. Check your network or server settings.")))
                logger.error(
                    "load assets failed source=filtered targetCount=\(request.targetCount, privacy: .public) error=\(message, privacy: .private)"
                )
                setLoading(false, update: update)
            }
        }
        return true
    }

    // The refill remembers the generation it started with; old results must not be appended after a source change.
    func beginRefill(context: SessionContext, update: (Update) -> Void) -> RefillRequest {
        let loadGeneration = generation
        let loadSource = source
        let requestID = UUID()
        loadMoreLoadingRequestID = requestID
        setLoadingMore(true, update: update)
        let oldCount = assets.count
        switch loadSource {
        case .random:
            logger.info("load more begin source=random oldCount=\(oldCount, privacy: .public)")
            #if DEBUG
            update(
                .sequenceEvent(
                    .loadMoreBegin(
                        sourceSummary: Self.logName(for: loadSource), oldCount: oldCount, targetCount: nil,
                        excludedCount: oldCount)))
            #endif
            return RefillRequest(
                requestID: requestID, generation: loadGeneration, source: loadSource,
                playbackSessionId: context.playbackSessionId, oldCount: oldCount,
                targetCount: Self.standardFetchAssetCount, excludedAssetIds: [])
        case .filtered(let selection):
            let targetCount = resolveTargetCount(for: selection, isInitial: false)
            let excludedAssetIds = Set(assets.map(\.id))
            logger.info(
                "load more begin source=filtered oldCount=\(oldCount, privacy: .public) targetCount=\(targetCount, privacy: .public) selection=\(Self.logSummary(for: selection), privacy: .public)"
            )
            #if DEBUG
            update(
                .sequenceEvent(
                    .loadMoreBegin(
                        sourceSummary: Self.logSummary(for: selection), oldCount: oldCount,
                        targetCount: targetCount, excludedCount: excludedAssetIds.count)))
            #endif
            return RefillRequest(
                requestID: requestID, generation: loadGeneration, source: loadSource,
                playbackSessionId: context.playbackSessionId, oldCount: oldCount, targetCount: targetCount,
                excludedAssetIds: excludedAssetIds)
        }
    }

    func acquireRefill(_ request: RefillRequest) async -> RefillResult {
        switch request.source {
        case .random:
            return await acquireRandomRefill(request)
        case .filtered(let selection):
            return await acquireFilteredRefill(request, selection: selection)
        }
    }

    #if DEBUG
    // The resolver streams these observations during acquisition; final batch events still wait for validation.
    func acquireRefill(
        _ request: RefillRequest,
        sequenceEventSink: @escaping (PlaybackSequenceDebugEventInput) -> Void,
        isSequenceEvidenceEnabled: Bool
    ) async -> RefillResult {
        switch request.source {
        case .random:
            return await acquireRandomRefill(request)
        case .filtered(let selection):
            if loadMoreAssetsHookForTesting != nil {
                return await acquireFilteredRefill(request, selection: selection)
            }
            let previousDebugEventSink = resolver.playbackSequenceDebugEventSink
            if isSequenceEvidenceEnabled {
                resolver.playbackSequenceDebugEventSink = sequenceEventSink
            }
            defer { resolver.playbackSequenceDebugEventSink = previousDebugEventSink }
            return await acquireFilteredRefill(request, selection: selection)
        }
    }
    #endif

    private func acquireRandomRefill(_ request: RefillRequest) async -> RefillResult {
        do {
            let loadedAssets: [Asset]
            #if DEBUG
            if let loadMoreAssetsHookForTesting {
                loadedAssets = try await loadMoreAssetsHookForTesting(request.source)
            } else {
                loadedAssets = try await ImmichAPIService.shared.getRandomAsset(
                    size: Self.standardFetchAssetCount)
            }
            #else
            loadedAssets = try await ImmichAPIService.shared.getRandomAsset(
                size: Self.standardFetchAssetCount)
            #endif
            return RefillResult(request: request, outcome: .success(loadedAssets))
        } catch {
            return RefillResult(request: request, outcome: .failure(error))
        }
    }

    private func acquireFilteredRefill(_ request: RefillRequest, selection: FilterSelection) async
        -> RefillResult
    {
        do {
            let loadedAssets: [Asset]
            #if DEBUG
            let strictSoloDebugEvents: [PlaybackSequenceDebugEventInput]
            if let loadMoreAssetsHookForTesting {
                loadedAssets = try await loadMoreAssetsHookForTesting(request.source)
                strictSoloDebugEvents = []
            } else {
                loadedAssets = try await resolver.resolve(
                    selection: selection, targetCount: request.targetCount,
                    excludingAssetIds: request.excludedAssetIds)
                strictSoloDebugEvents = resolver.strictSoloDebugEventsForTesting
            }
            var result = RefillResult(request: request, outcome: .success(loadedAssets))
            result.strictSoloDebugEvents = strictSoloDebugEvents
            return result
            #else
            loadedAssets = try await resolver.resolve(
                selection: selection, targetCount: request.targetCount,
                excludingAssetIds: request.excludedAssetIds)
            return RefillResult(request: request, outcome: .success(loadedAssets))
            #endif
        } catch {
            return RefillResult(request: request, outcome: .failure(error))
        }
    }

    func applyRefill(
        _ result: RefillResult, context: SessionContext,
        update: (Update) -> Void,
        observeTrim: (TrimObservation) -> Void
    ) {
        switch result.request.source {
        case .random:
            applyRandomRefill(
                result, context: context, update: update, observeTrim: observeTrim)
        case .filtered(let selection):
            applyFilteredRefill(
                result, selection: selection, context: context,
                update: update, observeTrim: observeTrim)
        }
    }

    private func applyRandomRefill(
        _ result: RefillResult, context: SessionContext,
        update: (Update) -> Void,
        observeTrim: (TrimObservation) -> Void
    ) {
        let request = result.request
        switch result.outcome {
        case .success(let loadedAssets):
            guard isCurrentRefill(request, context: context) else {
                logger.notice(
                    "load more ignored stale result source=random generation=\(request.generation, privacy: .public) currentGeneration=\(self.generation, privacy: .public)"
                )
                return
            }
            let unseenAssets = assetsUnseenInCurrentPool(loadedAssets)
            assets.append(contentsOf: unseenAssets)
            update(.assets(assets))
            if !assets.isEmpty { update(.emptyMessage(nil)) }
            if assets.count >= maximumAssetCount {
                let removeCount = assets.count - maximumAssetCount
                observeTrim(.willTrim(source: "random", removeCount: removeCount))
                let idsToRemove = assets.prefix(removeCount).map(\.id)
                update(.evictCachedAssets(idsToRemove))
                assets.removeFirst(removeCount)
                update(.assets(assets))
                update(.adjustCursorAfterTrim(removeCount))
                // After trimming the queue head, move the index back so currentIndex is not in the removed range.
                update(.syncReadback)
                observeTrim(.didTrim(source: "random", removeCount: removeCount))
            }
            finishLoadingMore(request, update: update)
            #if DEBUG
            update(
                .sequenceEvent(
                    .loadMoreResult(
                        sourceSummary: Self.logName(for: request.source), oldCount: request.oldCount,
                        targetCount: nil, returnedCount: loadedAssets.count, unseenCount: unseenAssets.count,
                        dedupedCount: loadedAssets.count - unseenAssets.count, finalCount: assets.count)))
            #endif
            update(
                .refillFinished(
                    source: "random", addedCount: unseenAssets.count,
                    dedupedCount: loadedAssets.count - unseenAssets.count))
        case .failure(let error):
            let message = error.localizedDescription
            guard isCurrentRefill(request, context: context) else {
                logger.notice(
                    "load more ignored stale failure source=random generation=\(request.generation, privacy: .public) currentGeneration=\(self.generation, privacy: .public) error=\(message, privacy: .private)"
                )
                return
            }
            #if DEBUG
            update(
                .sequenceEvent(
                    .loadMoreFailure(
                        sourceSummary: Self.logName(for: request.source), oldCount: request.oldCount,
                        targetCount: nil, errorKind: loadMoreErrorKind(error))))
            #endif
            logger.error(
                "load more failed source=random oldCount=\(request.oldCount, privacy: .public) error=\(message, privacy: .private)"
            )
            finishLoadingMore(request, update: update)
        }
    }

    private func applyFilteredRefill(
        _ result: RefillResult, selection: FilterSelection, context: SessionContext,
        update: (Update) -> Void,
        observeTrim: (TrimObservation) -> Void
    ) {
        let request = result.request
        switch result.outcome {
        case .success(let loadedAssets):
            guard isCurrentRefill(request, context: context) else {
                logger.notice(
                    "load more ignored stale result source=filtered generation=\(request.generation, privacy: .public) currentGeneration=\(self.generation, privacy: .public)"
                )
                return
            }
            #if DEBUG
            for event in result.strictSoloDebugEvents { update(.sequenceEvent(event)) }
            #endif
            let unseenAssets = assetsUnseenInCurrentPool(loadedAssets)
            if unseenAssets.isEmpty {
                logger.notice(
                    "load more saturated source=filtered returnedCount=\(loadedAssets.count, privacy: .public) oldCount=\(request.oldCount, privacy: .public) targetCount=\(request.targetCount, privacy: .public) selection=\(Self.logSummary(for: selection), privacy: .public)"
                )
                #if DEBUG
                update(
                    .sequenceEvent(
                        .loadMoreSaturated(
                            sourceSummary: Self.logSummary(for: selection), oldCount: request.oldCount,
                            targetCount: request.targetCount, returnedCount: loadedAssets.count,
                            unseenCount: unseenAssets.count)))
                #endif
            }
            assets.append(contentsOf: unseenAssets)
            update(.assets(assets))
            update(.resumeFilteredCursor(oldCount: request.oldCount, appendedCount: unseenAssets.count))
            if !assets.isEmpty { update(.emptyMessage(nil)) }
            if assets.count >= maximumAssetCount {
                let removeCount = assets.count - maximumAssetCount
                observeTrim(.willTrim(source: "filtered", removeCount: removeCount))
                let idsToRemove = assets.prefix(removeCount).map(\.id)
                update(.evictCachedAssets(idsToRemove))
                assets.removeFirst(removeCount)
                update(.assets(assets))
                update(.adjustCursorAfterTrim(removeCount))
                // After trimming the queue head, move the index back so currentIndex is not in the removed range.
                update(.syncReadback)
                observeTrim(.didTrim(source: "filtered", removeCount: removeCount))
            }
            finishLoadingMore(request, update: update)
            #if DEBUG
            update(
                .sequenceEvent(
                    .loadMoreResult(
                        sourceSummary: Self.logSummary(for: selection), oldCount: request.oldCount,
                        targetCount: request.targetCount, returnedCount: loadedAssets.count,
                        unseenCount: unseenAssets.count,
                        dedupedCount: loadedAssets.count - unseenAssets.count, finalCount: assets.count)))
            #endif
            update(
                .refillFinished(
                    source: "filtered", addedCount: unseenAssets.count,
                    dedupedCount: loadedAssets.count - unseenAssets.count))
        case .failure(let error):
            let message = error.localizedDescription
            guard isCurrentRefill(request, context: context) else {
                logger.notice(
                    "load more ignored stale failure source=filtered generation=\(request.generation, privacy: .public) currentGeneration=\(self.generation, privacy: .public) error=\(message, privacy: .private)"
                )
                return
            }
            #if DEBUG
            update(
                .sequenceEvent(
                    .loadMoreFailure(
                        sourceSummary: Self.logSummary(for: selection), oldCount: request.oldCount,
                        targetCount: request.targetCount, errorKind: loadMoreErrorKind(error))))
            #endif
            logger.error(
                "load more failed source=filtered oldCount=\(request.oldCount, privacy: .public) targetCount=\(request.targetCount, privacy: .public) error=\(message, privacy: .private)"
            )
            update(.clearPendingCursorResume(reason: loadMoreErrorKind(error)))
            finishLoadingMore(request, update: update)
        }
    }

    func finishLoadingMore(_ request: RefillRequest, update: (Update) -> Void) {
        // Cleanup ownership is independent of result freshness, including task cancellation.
        guard loadMoreLoadingRequestID == request.requestID else { return }
        setLoadingMore(false, update: update)
    }

    // The refill follows the session, not the current sceneId.
    private func isCurrentRefill(_ request: RefillRequest, context: SessionContext) -> Bool {
        request.generation == generation
            && Self.logName(for: request.source) == Self.logName(for: source)
            && request.playbackSessionId == context.playbackSessionId
            && !Task.isCancelled
    }

    // If the generation does not match, drop the old task; it must not write into the new playback source.
    private func makeInitialLoadIdentity(
        generation: Int, source: PlaybackSource, context: SessionContext
    ) -> InitialLoadIdentity {
        InitialLoadIdentity(
            generation: generation, sourceName: Self.logName(for: source), context: context)
    }

    private func assetsUnseenInCurrentPool(_ incomingAssets: [Asset]) -> [Asset] {
        var seenAssetIds = Set(assets.map(\.id))
        return incomingAssets.filter { seenAssetIds.insert($0.id).inserted }
    }

    private func setLoading(_ value: Bool, update: (Update) -> Void) {
        update(.loading(value))
    }

    private func setLoadingMore(_ value: Bool, update: (Update) -> Void) {
        update(.loadingMore(value))
    }

    private func loadMoreErrorKind(_ error: any Error) -> String {
        if error is CancellationError {
            return "cancelled"
        }
        return "failure"
    }

    private func kindName(for source: PlaybackSource) -> String {
        switch source {
        case .random: return "random"
        case .filtered: return "filtered"
        }
    }

    // soloOnly starts with a small pool and refills in the background; fetching 100 up front slows startup and fills
    // the cache.
    private func resolveTargetCount(for selection: FilterSelection, isInitial: Bool) -> Int {
        guard selection.personFilters.contains(where: { $0.matchMode == .soloOnly }) else {
            return Self.standardFetchAssetCount
        }
        return isInitial ? Self.initialSoloOnlyAssetCount : Self.soloOnlyRefillAssetCount
    }

    static func logName(for source: PlaybackSource) -> String {
        switch source {
        case .random: return "random"
        case .filtered(let selection): return "filtered(\(logSummary(for: selection)))"
        }
    }

    static func logSummary(for selection: FilterSelection) -> String {
        let soloCount = selection.personFilters.filter { $0.matchMode == .soloOnly }.count
        let normalCount = selection.personFilters.filter { $0.matchMode == .normal }.count
        return
            "albums=\(selection.albumIds.count),people=\(selection.personFilters.count),solo=\(soloCount),normal=\(normalCount),tags=\(selection.tagIds.count),rating=\(selection.rating == nil ? "nil" : "set"),favorite=\(selection.isFavorite == nil ? "nil" : "set")"
    }

    static func emptyMessage(for reason: PlaybackPoolEmptyReason?, source: PlaybackSource) -> String {
        switch reason ?? .noMatchingAssets {
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
                        "Immich did not return any playable photos. Check your server library or network connection."
                )
            case .filtered:
                return String(
                    localized: "No playable photos match the current filters. Try another album or person.")
            }
        }
    }
}

extension MotionPlatform {
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
