import Foundation

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

/// Coordinates accepted transitions and retained visible history without owning planning or presentation policy.
@MainActor
final class PlaybackSessionOwner {
    private var engine = PlaybackSessionEngine()
    private var historyLedger = PlaybackHistoryLedger()
    private var pendingHistoryCommits: [UUID: HistoryCommit] = [:]

    private enum HistoryCommit {
        case moveCursor(Int)
        case appendTail
    }

    enum PreviousNavigation {
        case unchanged
        case transition(PlaybackSessionTransition)
        case cancelled(effects: [ScenePresentationEffect], transactionID: UUID?)
    }

    struct AcceptedPresentation {
        let identity: PlaybackSessionEngine.ScenePresentationIdentity
        let effects: [ScenePresentationEffect]
        let appendsNewTailScene: Bool
    }

    enum VisibilityUpdate {
        case effects([ScenePresentationEffect])
        case committingScene(PlaybackScene?)
    }

    struct VisibleCommit {
        let identity: PlaybackSessionEngine.ScenePresentationIdentity
        let source: PlaybackSceneTransactionSource?
        let previousIndex: Int
        let previousAssetID: String?
    }

    var scenes: [PlaybackScene] { engine.scenes }
    var currentScene: PlaybackScene? { engine.currentScene }
    var currentIndex: Int { engine.currentIndex }
    var targetIndex: Int { engine.pendingTransition?.targetIndex ?? engine.currentIndex }
    var targetTransitionToken: UUID { engine.targetTransitionToken }
    var pendingTransition: PlaybackSessionTransition? { engine.pendingTransition }
    var preparedNext: PlaybackPreparedScene? { engine.preparedSceneRing?.next }
    var currentSessionIdentity: (playbackSessionId: UUID, sceneId: String?) { engine.currentSessionIdentity }
    var presentationHistoryCount: Int { engine.scenePresentationState.history.count }
    var isPresentationEmpty: Bool { engine.scenePresentationState.underlyingPhase == .empty }
    var isSuspendedForBackground: Bool { engine.scenePresentationState.suspensionReasons.contains(.background) }
    var isAtRetainedHistoryTail: Bool { historyLedger.isAtTail }
    var canRequestPreviousScene: Bool {
        canCancelUnseenPendingPresentation || historyLedger.previousTarget != nil
    }
    var currentPresentationIdentity: PlaybackSessionEngine.ScenePresentationIdentity? {
        let state = engine.scenePresentationState
        return (state.pendingTarget ?? state.currentTarget)?.identity
    }

    private var canCancelUnseenPendingPresentation: Bool {
        guard let visibleCurrentTarget = historyLedger.currentTarget,
            engine.canCancelUnseenManualPendingScenePresentation,
            let pendingTarget = engine.scenePresentationState.pendingTarget,
            !engine.scenePresentationState.history.contains(pendingTarget.identity)
        else { return false }
        return engine.currentScene?.id != visibleCurrentTarget.entry.scene.id
    }

    func scene(at index: Int) -> PlaybackScene? {
        if engine.pendingTransition?.targetIndex == index { return engine.pendingTransition?.scene }
        guard engine.scenes.indices.contains(index) else { return nil }
        return engine.scenes[index]
    }

    func scene(for identity: PlaybackSessionEngine.ScenePresentationIdentity) -> PlaybackScene? {
        engine.scene(for: identity)
    }

    func sceneRenderSnapshot(at time: TimeInterval) -> PlaybackSessionEngine.SceneRenderSnapshot {
        engine.sceneRenderSnapshot(at: time)
    }

    func presentationTarget(
        for identity: PlaybackSessionEngine.ScenePresentationIdentity
    ) -> PlaybackSessionEngine.ScenePresentationTarget? {
        engine.presentationTarget(for: identity)
    }

    func presentationIdentity(generation: UUID, sceneID: String) -> PlaybackSessionEngine.ScenePresentationIdentity? {
        engine.presentationIdentity(generation: generation, sceneID: sceneID)
    }

    func isInitialPresentation(_ identity: PlaybackSessionEngine.ScenePresentationIdentity) -> Bool {
        engine.transition(for: identity) == nil
    }

    /// Sample the clock only for cancellation, at the same point as the navigation command it replaces.
    func requestPrevious(at time: @autoclosure () -> TimeInterval) -> PreviousNavigation {
        if canCancelUnseenPendingPresentation, engine.canCancelUnseenManualPendingScenePresentation {
            let cancelledTransition = engine.scenePresentationState.pendingTarget
                .flatMap { engine.transition(for: $0.identity) }
            let effects = engine.cancelUnseenManualPendingScenePresentation(at: time())
            if let cancelledTransition { pendingHistoryCommits[cancelledTransition.transaction.id] = nil }
            return .cancelled(effects: effects, transactionID: cancelledTransition?.transaction.id)
        }
        guard let previous = historyLedger.previousTarget else { return .unchanged }
        let transition = engine.requestTransition(to: previous.entry.scene, source: .manualPrevious)
        pendingHistoryCommits[transition.transaction.id] = .moveCursor(previous.index)
        return .transition(transition)
    }

    func requestRedo(source: PlaybackSceneTransactionSource) -> PlaybackSessionTransition? {
        guard let redo = historyLedger.redoTarget else { return nil }
        let transition = engine.requestTransition(to: redo.entry.scene, source: source)
        pendingHistoryCommits[transition.transaction.id] = .moveCursor(redo.index)
        return transition
    }

    func requestNext(scene: PlaybackScene, source: PlaybackSceneTransactionSource) -> PlaybackSessionTransition {
        let transition = engine.requestNext(scene: scene, source: source)
        pendingHistoryCommits[transition.transaction.id] = .appendTail
        return transition
    }

    func requestNext(candidate: Asset, source: PlaybackSceneTransactionSource) -> PlaybackSessionTransition {
        let transition = engine.requestNext(candidate: candidate, source: source)
        pendingHistoryCommits[transition.transaction.id] = .appendTail
        return transition
    }

    func consumePreparedNext(
        fingerprint: PlaybackPreparedSceneFingerprint?,
        expectedSourceCursor: Int?,
        source: PlaybackSceneTransactionSource
    ) -> PlaybackSessionTransition? {
        guard let fingerprint,
            engine.invalidatePreparedSceneRing(ifNeededFor: fingerprint) == false,
            let preparedCursorEffect = engine.preparedSceneRing?.next?.cursorEffect,
            preparedCursorEffect.sourceCursor == expectedSourceCursor,
            let transition = engine.consumePreparedNext(source: source),
            transition.preparedCursorEffect != nil
        else {
            if let preparedCursorEffect = engine.preparedSceneRing?.next?.cursorEffect,
                preparedCursorEffect.sourceCursor != expectedSourceCursor
            {
                engine.clearPreparedSceneRing()
            }
            return nil
        }
        pendingHistoryCommits[transition.transaction.id] = .appendTail
        return transition
    }

    func beginScenePresentation(
        for transition: PlaybackSessionTransition,
        configuredInterval: TimeInterval,
        at time: TimeInterval
    ) -> AcceptedPresentation? {
        let requestSource: PlaybackSessionEngine.ScenePresentationRequestSource
        switch transition.transaction.source {
        case .manualNext: requestSource = .manualNext
        case .manualPrevious: requestSource = .manualPrevious
        case .autoplay: requestSource = .automatic
        }
        let isAutomaticStableDeadline =
            requestSource == .automatic && engine.scenePresentationState.underlyingPhase == .stablePhoto
        let appendsNewTailScene = transition.targetIndex >= engine.scenes.count
        guard
            let started = engine.beginScenePresentation(
                for: transition, configuredInterval: configuredInterval,
                requestSource: requestSource, isAutomaticStableDeadline: isAutomaticStableDeadline, at: time
            )
        else {
            pendingHistoryCommits[transition.transaction.id] = nil
            return nil
        }
        return AcceptedPresentation(
            identity: started.identity, effects: started.effects, appendsNewTailScene: appendsNewTailScene)
    }

    func startScenePresentation(
        configuredInterval: TimeInterval, at time: TimeInterval
    ) -> (identity: PlaybackSessionEngine.ScenePresentationIdentity, effects: [ScenePresentationEffect])? {
        engine.startScenePresentation(configuredInterval: configuredInterval, at: time)
    }

    func reduceScenePresentation(
        _ event: PlaybackSessionEngine.ScenePresentationEvent, at time: TimeInterval
    ) -> [ScenePresentationEffect] {
        engine.reduceScenePresentation(event, at: time)
    }

    /// Synchronous updates preserve effect publication and evidence observation before the retained-ledger commit.
    func incomingBecameVisible(
        _ layerIdentity: ScenePresentationLayerIdentity,
        at time: @autoclosure () -> TimeInterval,
        update: (VisibilityUpdate) -> Void
    ) -> VisibleCommit? {
        guard
            let identity = engine.presentationIdentity(
                generation: layerIdentity.generation, sceneID: layerIdentity.sceneID)
        else { return nil }
        let historyCountBefore = engine.scenePresentationState.history.count
        let transition = engine.transition(for: identity)
        let previousIndex = historyLedger.cursor ?? -1
        let previousAssetID = historyLedger.currentTarget?.entry.scene.primaryAssetId
        update(.effects(engine.reduceScenePresentation(.incomingBecameVisible(identity), at: time())))
        guard engine.scenePresentationState.history.count > historyCountBefore else { return nil }
        update(.committingScene(engine.scene(for: identity)))
        if let transition {
            applyHistoryCommit(
                pendingHistoryCommits[transition.transaction.id], committedScene: engine.scene(for: identity))
        } else if historyLedger.entries.isEmpty, let scene = engine.scene(for: identity) {
            historyLedger.append(scene)
        }
        return VisibleCommit(
            identity: identity, source: transition?.transaction.source,
            previousIndex: previousIndex, previousAssetID: previousAssetID)
    }

    private func applyHistoryCommit(_ commit: HistoryCommit?, committedScene: PlaybackScene?) {
        guard let commit else { return }
        switch commit {
        case .moveCursor(let index): historyLedger.moveCursor(to: index)
        case .appendTail:
            if let committedScene { historyLedger.append(committedScene) }
        }
        pendingHistoryCommits = [:]
    }

    func resetPlayback(with assets: [Asset], initialScene: PlaybackScene?, reason: PlaybackSessionInvalidationReason) {
        engine.reset(with: assets, initialScene: initialScene, reason: reason)
        historyLedger.reset(with: nil)
        pendingHistoryCommits = [:]
    }

    /// Initial SmartFill activation resets the engine only; retained history keeps its existing lifecycle.
    func rebuildInitialScene(
        with assets: [Asset], initialScene: PlaybackScene, reason: PlaybackSessionInvalidationReason
    ) {
        engine.reset(with: assets, initialScene: initialScene, reason: reason)
    }

    func invalidate(reason: PlaybackSessionInvalidationReason) { engine.invalidate(reason: reason) }

    func updateFutureProtectionSnapshot(_ snapshot: PlaybackProtectionSnapshot) {
        engine.updateFutureProtectionSnapshot(snapshot)
    }

    @discardableResult
    func replaceCurrentDisplayContent(with scene: PlaybackScene) -> Bool {
        guard let currentScene = engine.currentScene,
            engine.updateCurrentScene({ $0.replacingDisplayContent(with: scene) })
        else { return false }
        historyLedger.replaceCurrent(with: engine.currentScene ?? currentScene)
        return true
    }

    func annotateCurrentScene(_ transform: (PlaybackScene) -> PlaybackScene) {
        engine.updateCurrentScene(transform)
    }

    @discardableResult
    func invalidatePreparedSceneRing(ifNeededFor fingerprint: PlaybackPreparedSceneFingerprint) -> Bool {
        engine.invalidatePreparedSceneRing(ifNeededFor: fingerprint)
    }

    func installPreparedNext(
        fingerprint: PlaybackPreparedSceneFingerprint,
        sourceCursor: Int,
        scene: PlaybackScene,
        cursorEffect: PlaybackPreparedSceneCursorEffect
    ) {
        let previous = engine.currentIndex > 0 ? engine.scenes[engine.currentIndex - 1] : nil
        engine.prepareSceneRing(
            fingerprint: fingerprint, sourceCursor: sourceCursor,
            previous: previous, current: engine.currentScene, next: scene, nextCursorEffect: cursorEffect)
    }

    #if DEBUG
    struct HistorySnapshot {
        let entryCount: Int
        let cursor: Int?
        let canPrevious: Bool
        let canRedo: Bool
        let currentPrimaryAssetID: String?
        let suffixPrimaryAssetIDs: [String]
    }

    func historySnapshot(lookbackCount: Int) -> HistorySnapshot {
        HistorySnapshot(
            entryCount: historyLedger.entries.count, cursor: historyLedger.cursor,
            canPrevious: historyLedger.previousTarget != nil, canRedo: historyLedger.redoTarget != nil,
            currentPrimaryAssetID: historyLedger.currentTarget?.entry.scene.primaryAssetId,
            suffixPrimaryAssetIDs: historyLedger.entries.suffix(lookbackCount).map { $0.scene.primaryAssetId ?? "nil" })
    }

    var pendingHistoryCommitCountForTesting: Int { pendingHistoryCommits.count }

    func displayedRecord(for sceneID: String) -> PlaybackSceneDisplayedRecord? {
        engine.displayedSceneRecords.reversed().first { $0.sceneId == sceneID }
    }

    func clearPreparedNextForTesting(fingerprint: PlaybackPreparedSceneFingerprint, sourceCursor: Int) {
        engine.prepareSceneRing(
            fingerprint: fingerprint, sourceCursor: sourceCursor,
            previous: nil, current: engine.currentScene, next: nil, nextCursorEffect: nil)
    }
    #endif
}
