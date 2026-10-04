//
//  PlaybackSessionEngine.swift
//  immichSlides
//
//  Created by Codex on 2026/5/26.
//

import Foundation

enum PlaybackSessionInvalidationReason: String, Equatable {
    case sourceChanged
    case filterChanged
    case serverChanged
    case poolReloaded
}

enum PlaybackSceneTransactionSource: String, Equatable {
    case manualNext
    case manualPrevious
    case autoplay
}

struct PlaybackSceneTransaction: Equatable {
    let id: UUID
    let source: PlaybackSceneTransactionSource
    let sceneId: String
    let targetIndex: Int
    let publishedAssetIds: [String]
    let consumedAssetIds: [String]
    let advancesForwardCursor: Bool
    let preparedHit: Bool
}

struct PlaybackScenePublishedRecord: Equatable {
    let transactionId: UUID
    let source: PlaybackSceneTransactionSource
    let sceneId: String
    let targetIndex: Int
    let assetIds: [String]
    let consumedAssetIds: [String]
    let advancesForwardCursor: Bool
    let preparedHit: Bool
}

struct PlaybackSceneDisplayedRecord: Equatable {
    let transactionId: UUID
    let source: PlaybackSceneTransactionSource
    let sceneId: String
    let targetIndex: Int
    let assetIds: [String]
    let preparedHit: Bool
}

struct PlaybackPreparedSceneFingerprint: Equatable, Sendable {
    private static let dimensionBucketWidthPoints: Double = 8
    private static let aspectRatioBucketScale: Double = 100
    let deviceProfile: String
    let orientation: String
    let pointWidthBucket: Int
    let pointHeightBucket: Int
    let aspectRatioBucket: Int
    let safeAreaClass: String
    let controlBarClass: String
    let exifOverlayClass: String
    let assetPoolIdentity: String
    let playbackSourceIdentity: String

    init(
        deviceProfile: String,
        orientation: String,
        pointWidth: Double,
        pointHeight: Double,
        safeAreaClass: String,
        controlBarClass: String,
        exifOverlayClass: String,
        assetPoolIdentity: String,
        playbackSourceIdentity: String
    ) {
        self.deviceProfile = deviceProfile
        self.orientation = orientation
        self.pointWidthBucket = Self.dimensionBucket(pointWidth)
        self.pointHeightBucket = Self.dimensionBucket(pointHeight)
        self.aspectRatioBucket = Self.aspectRatioBucket(width: pointWidth, height: pointHeight)
        self.safeAreaClass = safeAreaClass
        self.controlBarClass = controlBarClass
        self.exifOverlayClass = exifOverlayClass
        self.assetPoolIdentity = assetPoolIdentity
        self.playbackSourceIdentity = playbackSourceIdentity
    }

    private static func dimensionBucket(_ value: Double) -> Int {
        Int((max(0, value) / dimensionBucketWidthPoints).rounded())
    }

    private static func aspectRatioBucket(width: Double, height: Double) -> Int {
        guard height > 0 else { return 0 }
        return Int(((max(0, width) / height) * aspectRatioBucketScale).rounded())
    }
}

struct PlaybackPreparedSceneCursorEffect: Equatable {
    let sourceCursor: Int
    let nextCandidateCursorOffset: Int
    let displayedAssetIds: Set<String>
}

enum PlaybackPreparedScenePosition: String, Equatable {
    case previous
    case current
    case next
}

struct PlaybackPreparedScene: Equatable {
    let generation: UUID
    let position: PlaybackPreparedScenePosition
    let scene: PlaybackScene
    let targetIndex: Int
    let sourceCursor: Int
    let fingerprint: PlaybackPreparedSceneFingerprint
    let cursorEffect: PlaybackPreparedSceneCursorEffect?

    static func == (lhs: PlaybackPreparedScene, rhs: PlaybackPreparedScene) -> Bool {
        lhs.generation == rhs.generation
            && lhs.position == rhs.position
            && lhs.scene.id == rhs.scene.id
            && lhs.targetIndex == rhs.targetIndex
            && lhs.sourceCursor == rhs.sourceCursor
            && lhs.fingerprint == rhs.fingerprint
            && lhs.cursorEffect == rhs.cursorEffect
    }

    func retarget(
        position: PlaybackPreparedScenePosition,
        targetIndex: Int
    ) -> PlaybackPreparedScene {
        PlaybackPreparedScene(
            generation: generation,
            position: position,
            scene: scene,
            targetIndex: targetIndex,
            sourceCursor: sourceCursor,
            fingerprint: fingerprint,
            cursorEffect: cursorEffect
        )
    }

    func replacingScene(_ scene: PlaybackScene) -> PlaybackPreparedScene {
        PlaybackPreparedScene(
            generation: generation,
            position: position,
            scene: scene,
            targetIndex: targetIndex,
            sourceCursor: sourceCursor,
            fingerprint: fingerprint,
            cursorEffect: cursorEffect
        )
    }
}

struct PlaybackPreparedSceneRing: Equatable {
    let generation: UUID
    let fingerprint: PlaybackPreparedSceneFingerprint
    let sourceCursor: Int
    let previous: PlaybackPreparedScene?
    let current: PlaybackPreparedScene?
    let next: PlaybackPreparedScene?
}

struct PlaybackSessionTransition {
    let playbackSessionId: UUID
    let navigationToken: UUID
    let scene: PlaybackScene
    let targetIndex: Int
    let transaction: PlaybackSceneTransaction
    let preparedCursorEffect: PlaybackPreparedSceneCursorEffect?
}

struct PlaybackSessionEngine {
    private(set) var playbackSessionId: UUID
    private(set) var navigationToken: UUID
    private(set) var pendingTransition: PlaybackSessionTransition?
    private(set) var invalidationReason: PlaybackSessionInvalidationReason?
    private(set) var scenes: [PlaybackScene]
    private(set) var currentIndex: Int
    private(set) var publishedSceneRecords: [PlaybackScenePublishedRecord]
    private(set) var displayedSceneRecords: [PlaybackSceneDisplayedRecord]
    private(set) var preparedSceneRing: PlaybackPreparedSceneRing?
    private(set) var scenePresentationState: ScenePresentationState

    private let retainedRenderSceneLimit: Int
    private var scenePresentationScenes: [ScenePresentationIdentity: PlaybackScene]
    private var scenePresentationTargets: [ScenePresentationIdentity: ScenePresentationTarget]
    private var scenePresentationTransitions: [ScenePresentationIdentity: PlaybackSessionTransition]
    private var committedPresentationHistory: Set<ScenePresentationIdentity>
    private var nextSceneSequence: Int
    private var futureProtectionSnapshot: PlaybackProtectionSnapshot

    init(retainedRenderSceneLimit: Int = 20) {
        self.retainedRenderSceneLimit = max(1, retainedRenderSceneLimit)
        self.playbackSessionId = UUID()
        self.navigationToken = UUID()
        self.pendingTransition = nil
        self.invalidationReason = nil
        self.scenes = []
        self.currentIndex = 0
        self.publishedSceneRecords = []
        self.displayedSceneRecords = []
        self.preparedSceneRing = nil
        self.scenePresentationState = ScenePresentationState()
        self.scenePresentationScenes = [:]
        self.scenePresentationTargets = [:]
        self.scenePresentationTransitions = [:]
        self.committedPresentationHistory = []
        self.nextSceneSequence = 0
        self.futureProtectionSnapshot = .empty
    }

    var currentScene: PlaybackScene? {
        guard currentIndex >= 0, currentIndex < scenes.count else { return nil }
        return scenes[currentIndex]
    }

    var currentSessionIdentity: (playbackSessionId: UUID, sceneId: String?) {
        (playbackSessionId, currentScene?.id)
    }

    var targetTransitionToken: UUID {
        pendingTransition?.navigationToken ?? navigationToken
    }

    var canCancelUnseenManualPendingScenePresentation: Bool {
        scenePresentationState.hasUnseenManualPendingPresentation
    }

    func sceneRenderSnapshot(at time: TimeInterval) -> SceneRenderSnapshot {
        scenePresentationState.renderSnapshot(at: time)
    }

    func scene(for identity: ScenePresentationIdentity) -> PlaybackScene? {
        scenePresentationScenes[identity]
    }

    func transition(for identity: ScenePresentationIdentity) -> PlaybackSessionTransition? {
        scenePresentationTransitions[identity]
    }

    func presentationTarget(for identity: ScenePresentationIdentity) -> ScenePresentationTarget? {
        scenePresentationTargets[identity]
    }

    func presentationIdentity(
        generation: UUID,
        sceneID: String
    ) -> ScenePresentationIdentity? {
        scenePresentationScenes.keys.first(where: {
            $0.generation == generation && $0.sceneID == sceneID
        })
    }

    @discardableResult
    mutating func reduceScenePresentation(
        _ event: ScenePresentationEvent,
        at time: TimeInterval
    ) -> [ScenePresentationEffect] {
        let previousHistory = Set(scenePresentationState.history)
        let effects = scenePresentationState.reduce(event, at: time)
        synchronizePresentationTargetsWithReducerState()
        let newlyVisible = scenePresentationState.history.filter { !previousHistory.contains($0) }
        for identity in newlyVisible {
            commitDisplayedPresentation(identity)
        }
        return effects
    }

    /// An unseen manual pending presentation only cancels that target; the reducer restores the old scene, which
    /// must not go back to Loading.

    @discardableResult
    mutating func cancelUnseenManualPendingScenePresentation(
        at time: TimeInterval
    ) -> [ScenePresentationEffect] {
        guard scenePresentationState.hasUnseenManualPendingPresentation else { return [] }
        let restoredVisibleTarget = scenePresentationState.manualPendingRestoreCurrentTarget
        let effects = reduceScenePresentation(.cancelUnseenManualPendingPresentation, at: time)
        guard let restoredVisibleTarget,
            let restoredScene = scenePresentationScenes[restoredVisibleTarget.identity],
            let restoredIndex = scenes.firstIndex(where: { $0.id == restoredScene.id })
        else {
            return effects
        }
        currentIndex = restoredIndex
        return effects
    }

    @discardableResult
    mutating func startScenePresentation(
        configuredInterval: TimeInterval,
        at time: TimeInterval
    ) -> (identity: ScenePresentationIdentity, effects: [ScenePresentationEffect])? {
        guard let currentScene else { return nil }
        let inheritedSuspensionReasons = scenePresentationState.suspensionReasons
        scenePresentationState = ScenePresentationState(
            nextConfiguredInterval: configuredInterval,
            isReduceMotionEnabled: scenePresentationState.isReduceMotionEnabled
        )
        for reason in inheritedSuspensionReasons {
            scenePresentationState.reduce(.suspend(reason), at: time)
        }
        scenePresentationScenes = [:]
        scenePresentationTargets = [:]
        scenePresentationTransitions = [:]
        committedPresentationHistory = []
        let identity = ScenePresentationIdentity(
            generation: navigationToken,
            sceneID: currentScene.id,
            assetID: currentScene.primaryAssetId
        )
        scenePresentationScenes[identity] = currentScene
        let target = ScenePresentationTarget(
            identity: identity,
            configuredInterval: configuredInterval
        )
        scenePresentationTargets[identity] = target
        let effects = reduceScenePresentation(.start(target: target, readiness: .pending), at: time)
        return (identity, effects)
    }

    @discardableResult
    mutating func beginScenePresentation(
        for transition: PlaybackSessionTransition,
        configuredInterval: TimeInterval,
        requestSource: ScenePresentationRequestSource,
        isAutomaticStableDeadline: Bool,
        at time: TimeInterval
    ) -> (identity: ScenePresentationIdentity, effects: [ScenePresentationEffect])? {
        guard commit(transition) else { return nil }
        let identity = ScenePresentationIdentity(
            generation: transition.navigationToken,
            sceneID: transition.scene.id,
            assetID: transition.scene.primaryAssetId
        )
        scenePresentationScenes[identity] = transition.scene
        scenePresentationTransitions[identity] = transition
        let target = ScenePresentationTarget(
            identity: identity,
            configuredInterval: configuredInterval,
            incomingFadeDuration: requestSource.isManual
                ? ScenePresentationPacingPolicy.manualReady.incomingFadeDuration
                : SceneLifecycleContract.incomingFadeDuration
        )
        scenePresentationTargets[identity] = target
        let event: ScenePresentationEvent =
            isAutomaticStableDeadline
            ? .stableDeadlineReached(target: target, readiness: .pending)
            : .request(target: target, source: requestSource, readiness: .pending)
        let effects = reduceScenePresentation(event, at: time)
        prunePresentationSceneMappings(at: time)
        return (identity, effects)
    }

    /// External queries must read the same frozen lifecycle, not a stale copy kept from creation time.

    private mutating func synchronizePresentationTargetsWithReducerState() {
        if let currentTarget = scenePresentationState.currentTarget {
            scenePresentationTargets[currentTarget.identity] = currentTarget
        }
        if let pendingTarget = scenePresentationState.pendingTarget {
            scenePresentationTargets[pendingTarget.identity] = pendingTarget
        }
    }

    @discardableResult
    mutating func updateCurrentScene(
        _ transform: (PlaybackScene) -> PlaybackScene
    ) -> Bool {
        guard currentIndex >= 0, currentIndex < scenes.count else { return false }
        let currentScene = scenes[currentIndex]
        let updatedScene = transform(currentScene)
        guard updatedScene.id == currentScene.id,
            updatedScene.playbackSessionId == currentScene.playbackSessionId,
            updatedScene.sequence == currentScene.sequence
        else {
            return false
        }

        scenes[currentIndex] = updatedScene
        for identity in scenePresentationScenes.keys where identity.sceneID == updatedScene.id {
            scenePresentationScenes[identity] = updatedScene
        }
        if let ring = preparedSceneRing,
            ring.current?.scene.id == currentScene.id
        {
            preparedSceneRing = PlaybackPreparedSceneRing(
                generation: ring.generation,
                fingerprint: ring.fingerprint,
                sourceCursor: ring.sourceCursor,
                previous: ring.previous,
                current: ring.current?.replacingScene(updatedScene),
                next: ring.next
            )
        }
        return true
    }

    mutating func reset(
        with assets: [Asset],
        initialScene: PlaybackScene? = nil,
        reason: PlaybackSessionInvalidationReason
    ) {
        playbackSessionId = UUID()
        navigationToken = UUID()
        pendingTransition = nil
        invalidationReason = reason
        nextSceneSequence = 0
        publishedSceneRecords = []
        displayedSceneRecords = []
        preparedSceneRing = nil
        scenePresentationState = ScenePresentationState()
        scenePresentationScenes = [:]
        scenePresentationTargets = [:]
        scenePresentationTransitions = [:]
        committedPresentationHistory = []
        if let initialScene {
            scenes = [stampScene(initialScene)]
        } else {
            scenes = assets.first.map { [makeScene(for: $0)] } ?? []
        }
        currentIndex = 0
    }

    mutating func invalidate(reason: PlaybackSessionInvalidationReason) {
        navigationToken = UUID()
        pendingTransition = nil
        preparedSceneRing = nil
        scenePresentationState = ScenePresentationState(
            nextConfiguredInterval: scenePresentationState.nextConfiguredInterval,
            isReduceMotionEnabled: scenePresentationState.isReduceMotionEnabled
        )
        scenePresentationScenes = [:]
        scenePresentationTargets = [:]
        scenePresentationTransitions = [:]
        committedPresentationHistory = []
        invalidationReason = reason
    }

    mutating func updateFutureProtectionSnapshot(_ snapshot: PlaybackProtectionSnapshot) {
        guard snapshot != futureProtectionSnapshot else { return }

        futureProtectionSnapshot = snapshot
        preparedSceneRing = nil
        if pendingTransition != nil {
            navigationToken = UUID()
            pendingTransition = nil
        }
    }

    mutating func prepareSceneRing(
        fingerprint: PlaybackPreparedSceneFingerprint,
        sourceCursor: Int,
        previous: PlaybackScene?,
        current: PlaybackScene?,
        next: PlaybackScene?,
        previousCursorEffect: PlaybackPreparedSceneCursorEffect? = nil,
        currentCursorEffect: PlaybackPreparedSceneCursorEffect? = nil,
        nextCursorEffect: PlaybackPreparedSceneCursorEffect? = nil
    ) {
        let generation = UUID()
        let previousPrepared = previous.flatMap { scene in
            makePreparedScene(
                scene,
                position: .previous,
                targetIndex: currentIndex - 1,
                sourceCursor: sourceCursor,
                fingerprint: fingerprint,
                generation: generation,
                cursorEffect: previousCursorEffect
            )
        }
        let currentPreparedScene = current ?? currentScene
        let currentPrepared = currentPreparedScene.flatMap { scene in
            makePreparedScene(
                scene,
                position: .current,
                targetIndex: currentIndex,
                sourceCursor: sourceCursor,
                fingerprint: fingerprint,
                generation: generation,
                cursorEffect: currentCursorEffect
            )
        }
        let nextTargetIndex = currentIndex + 1 < scenes.count ? currentIndex + 1 : scenes.count
        let nextPrepared = next.flatMap { scene in
            makePreparedScene(
                scene,
                position: .next,
                targetIndex: nextTargetIndex,
                sourceCursor: sourceCursor,
                fingerprint: fingerprint,
                generation: generation,
                cursorEffect: nextCursorEffect
            )
        }

        preparedSceneRing = PlaybackPreparedSceneRing(
            generation: generation,
            fingerprint: fingerprint,
            sourceCursor: sourceCursor,
            previous: previousPrepared,
            current: currentPrepared,
            next: nextPrepared
        )
    }

    func shouldInvalidatePreparedSceneRing(
        for fingerprint: PlaybackPreparedSceneFingerprint
    ) -> Bool {
        guard let preparedSceneRing else { return true }
        return preparedSceneRing.fingerprint != fingerprint
    }

    @discardableResult
    mutating func invalidatePreparedSceneRing(
        ifNeededFor fingerprint: PlaybackPreparedSceneFingerprint
    ) -> Bool {
        guard preparedSceneRing != nil,
            shouldInvalidatePreparedSceneRing(for: fingerprint)
        else {
            return false
        }

        preparedSceneRing = nil
        pendingTransition = nil
        navigationToken = UUID()
        return true
    }

    mutating func clearPreparedSceneRing() {
        preparedSceneRing = nil
    }

    mutating func consumePreparedNext(
        source: PlaybackSceneTransactionSource = .manualNext
    ) -> PlaybackSessionTransition? {
        guard let ring = preparedSceneRing,
            let preparedNext = ring.next
        else {
            return nil
        }
        let expectedTargetIndex = currentIndex + 1 < scenes.count ? currentIndex + 1 : scenes.count
        guard preparedNext.targetIndex == expectedTargetIndex else {
            preparedSceneRing = nil
            return nil
        }

        let transition = makePendingTransition(
            scene: preparedNext.scene,
            targetIndex: preparedNext.targetIndex,
            source: source,
            preparedHit: true,
            preparedCursorEffect: preparedNext.cursorEffect
        )
        preparedSceneRing = PlaybackPreparedSceneRing(
            generation: ring.generation,
            fingerprint: ring.fingerprint,
            sourceCursor: preparedNext.sourceCursor,
            previous: ring.current?.retarget(position: .previous, targetIndex: currentIndex),
            current: preparedNext.retarget(position: .current, targetIndex: preparedNext.targetIndex),
            next: nil
        )
        return transition
    }

    mutating func consumePreparedPrevious(
        source: PlaybackSceneTransactionSource = .manualPrevious
    ) -> PlaybackSessionTransition? {
        guard let ring = preparedSceneRing,
            let preparedPrevious = ring.previous
        else {
            return nil
        }

        let transition = makePendingTransition(
            scene: preparedPrevious.scene,
            targetIndex: preparedPrevious.targetIndex,
            source: source,
            preparedHit: true,
            preparedCursorEffect: preparedPrevious.cursorEffect
        )
        preparedSceneRing = PlaybackPreparedSceneRing(
            generation: ring.generation,
            fingerprint: ring.fingerprint,
            sourceCursor: preparedPrevious.sourceCursor,
            previous: nil,
            current: preparedPrevious.retarget(position: .current, targetIndex: preparedPrevious.targetIndex),
            next: ring.current?.retarget(position: .next, targetIndex: currentIndex)
        )
        return transition
    }

    mutating func requestPrevious() -> PlaybackSessionTransition? {
        guard currentIndex > 0 else { return nil }
        let targetIndex = currentIndex - 1
        return makePendingTransition(
            scene: scenes[targetIndex],
            targetIndex: targetIndex,
            source: .manualPrevious
        )
    }

    mutating func requestNext(
        candidate: Asset,
        source: PlaybackSceneTransactionSource = .manualNext
    ) -> PlaybackSessionTransition {
        if currentIndex + 1 < scenes.count {
            let targetIndex = currentIndex + 1
            return makePendingTransition(
                scene: scenes[targetIndex],
                targetIndex: targetIndex,
                source: source
            )
        }

        return makePendingTransition(
            scene: makeScene(for: candidate),
            targetIndex: scenes.count,
            source: source
        )
    }

    mutating func requestNext(
        scene: PlaybackScene,
        source: PlaybackSceneTransactionSource = .manualNext
    ) -> PlaybackSessionTransition {
        if currentIndex + 1 < scenes.count {
            let targetIndex = currentIndex + 1
            return makePendingTransition(
                scene: scenes[targetIndex],
                targetIndex: targetIndex,
                source: source
            )
        }

        return makePendingTransition(
            scene: stampScene(scene),
            targetIndex: scenes.count,
            source: source
        )
    }

    mutating func requestTransition(
        to scene: PlaybackScene,
        source: PlaybackSceneTransactionSource,
        advancesForwardCursor: Bool = false
    ) -> PlaybackSessionTransition {
        let targetScene =
            scene.playbackSessionId == playbackSessionId
            ? scene
            : stampScene(scene)
        return makePendingTransition(
            scene: targetScene,
            targetIndex: currentIndex,
            source: source,
            advancesForwardCursor: advancesForwardCursor
        )
    }

    @discardableResult
    mutating func commit(_ transition: PlaybackSessionTransition?) -> Bool {
        guard let transition else { return false }
        return commit(transition)
    }

    @discardableResult
    mutating func commit(_ transition: PlaybackSessionTransition) -> Bool {
        guard transition.playbackSessionId == playbackSessionId,
            transition.navigationToken == navigationToken,
            pendingTransition?.scene.id == transition.scene.id,
            pendingTransition?.targetIndex == transition.targetIndex
        else {
            return false
        }

        if transition.targetIndex < scenes.count {
            if scenes[transition.targetIndex].id == transition.scene.id {
                currentIndex = transition.targetIndex
            } else if transition.targetIndex == currentIndex {
                scenes[transition.targetIndex] = transition.scene
                preparedSceneRing = nil
            } else {
                pendingTransition = nil
                return false
            }
        } else if transition.targetIndex == scenes.count {
            scenes.append(transition.scene)
            currentIndex = scenes.count - 1
            trimRetainedRenderSceneWindow()
        } else {
            pendingTransition = nil
            return false
        }

        pendingTransition = nil
        return true
    }

    private mutating func makePendingTransition(
        scene: PlaybackScene,
        targetIndex: Int,
        source: PlaybackSceneTransactionSource,
        preparedHit: Bool = false,
        preparedCursorEffect: PlaybackPreparedSceneCursorEffect? = nil,
        advancesForwardCursor: Bool? = nil
    ) -> PlaybackSessionTransition {
        navigationToken = UUID()
        let transaction = makeTransaction(
            scene: scene,
            targetIndex: targetIndex,
            source: source,
            preparedHit: preparedHit,
            advancesForwardCursor: advancesForwardCursor
        )
        let transition = PlaybackSessionTransition(
            playbackSessionId: playbackSessionId,
            navigationToken: navigationToken,
            scene: scene,
            targetIndex: targetIndex,
            transaction: transaction,
            preparedCursorEffect: preparedCursorEffect
        )
        pendingTransition = transition
        publishedSceneRecords.append(
            PlaybackScenePublishedRecord(
                transactionId: transaction.id,
                source: transaction.source,
                sceneId: transaction.sceneId,
                targetIndex: transaction.targetIndex,
                assetIds: transaction.publishedAssetIds,
                consumedAssetIds: transaction.consumedAssetIds,
                advancesForwardCursor: transaction.advancesForwardCursor,
                preparedHit: transaction.preparedHit
            ))
        return transition
    }

    private mutating func commitDisplayedPresentation(_ identity: ScenePresentationIdentity) {
        guard let transition = scenePresentationTransitions[identity],
            transition.targetIndex >= 0,
            transition.targetIndex < scenes.count,
            scenes[transition.targetIndex].id == transition.scene.id,
            committedPresentationHistory.insert(identity).inserted
        else {
            return
        }
        currentIndex = transition.targetIndex
        displayedSceneRecords.append(
            PlaybackSceneDisplayedRecord(
                transactionId: transition.transaction.id,
                source: transition.transaction.source,
                sceneId: transition.scene.id,
                targetIndex: transition.targetIndex,
                assetIds: transition.scene.assetIds,
                preparedHit: transition.transaction.preparedHit
            ))
    }

    private mutating func prunePresentationSceneMappings(at time: TimeInterval) {
        var retained = Set(scenePresentationState.history.suffix(retainedRenderSceneLimit))
        retained.formUnion(
            scenePresentationState.renderSnapshot(at: time).layers.map(\.identity)
        )
        if let currentTarget = scenePresentationState.currentTarget {
            retained.insert(currentTarget.identity)
        }
        if let pendingTarget = scenePresentationState.pendingTarget {
            retained.insert(pendingTarget.identity)
        }
        if let restorePendingTarget = scenePresentationState.manualPendingRestorePendingTarget {
            retained.insert(restorePendingTarget.identity)
        }
        if let restoreCurrentTarget = scenePresentationState.manualPendingRestoreCurrentTarget {
            retained.insert(restoreCurrentTarget.identity)
        }
        scenePresentationScenes = scenePresentationScenes.filter { retained.contains($0.key) }
        scenePresentationTargets = scenePresentationTargets.filter { retained.contains($0.key) }
        scenePresentationTransitions = scenePresentationTransitions.filter { retained.contains($0.key) }
        committedPresentationHistory = committedPresentationHistory.intersection(retained)
    }

    private func makeTransaction(
        scene: PlaybackScene,
        targetIndex: Int,
        source: PlaybackSceneTransactionSource,
        preparedHit: Bool,
        advancesForwardCursor: Bool?
    ) -> PlaybackSceneTransaction {
        let advancesForwardCursor = advancesForwardCursor ?? (source != .manualPrevious && targetIndex >= scenes.count)
        let assetIds = scene.assetIds
        return PlaybackSceneTransaction(
            id: UUID(),
            source: source,
            sceneId: scene.id,
            targetIndex: targetIndex,
            publishedAssetIds: assetIds,
            consumedAssetIds: advancesForwardCursor ? assetIds : [],
            advancesForwardCursor: advancesForwardCursor,
            preparedHit: preparedHit
        )
    }

    private mutating func makePreparedScene(
        _ scene: PlaybackScene,
        position: PlaybackPreparedScenePosition,
        targetIndex: Int,
        sourceCursor: Int,
        fingerprint: PlaybackPreparedSceneFingerprint,
        generation: UUID,
        cursorEffect: PlaybackPreparedSceneCursorEffect?
    ) -> PlaybackPreparedScene? {
        guard targetIndex >= 0 else { return nil }
        let sceneWithIdentity =
            targetIndex < scenes.count
            ? scene
            : stampScene(scene)
        return PlaybackPreparedScene(
            generation: generation,
            position: position,
            scene: sceneWithIdentity,
            targetIndex: targetIndex,
            sourceCursor: sourceCursor,
            fingerprint: fingerprint,
            cursorEffect: cursorEffect
        )
    }

    private mutating func makeScene(for asset: Asset) -> PlaybackScene {
        nextSceneSequence += 1
        return PlaybackScene(
            id: "scene-\(asset.id)-\(nextSceneSequence)",
            playbackSessionId: playbackSessionId,
            sequence: nextSceneSequence,
            photoSlots: [
                PhotoSlot(
                    id: "slot-primary-\(asset.id)-\(nextSceneSequence)",
                    asset: asset
                )
            ],
            protectionSnapshot: futureProtectionSnapshot
        )
    }

    private mutating func stampScene(_ scene: PlaybackScene) -> PlaybackScene {
        nextSceneSequence += 1
        let primaryId = scene.primaryAssetId ?? "empty"
        return scene.replacingPlaybackIdentity(
            id: "scene-\(primaryId)-\(nextSceneSequence)",
            playbackSessionId: playbackSessionId,
            sequence: nextSceneSequence,
            protectionSnapshot: futureProtectionSnapshot
        )
    }

    private mutating func trimRetainedRenderSceneWindow() {
        guard scenes.count > retainedRenderSceneLimit else { return }
        let removeCount = scenes.count - retainedRenderSceneLimit
        scenes.removeFirst(removeCount)
        currentIndex = max(0, currentIndex - removeCount)
    }
}
