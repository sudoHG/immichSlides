import Foundation
import OSLog

/// Runs reducer commands; navigation, session acceptance and publication stay with the facade.
@MainActor
final class ScenePresentationEffectExecutor {
    typealias Identity = PlaybackSessionEngine.ScenePresentationIdentity

    /// Awaiting this operation says nothing about decoded renderers or visible history.
    struct DownloadCompletion: Sendable {
        let identity: Identity
        private let downloadTask: Task<Void, Never>

        fileprivate init(identity: Identity, downloadTask: Task<Void, Never>) {
            self.identity = identity
            self.downloadTask = downloadTask
        }

        func waitForDownloads() async {
            await downloadTask.value
        }
    }

    struct ImageLoading {
        let loadInitialScene: @MainActor (PlaybackScene) async -> Void
        let loadTransitionScene: @MainActor (PlaybackScene, Bool, UUID) async -> Void
        let preloadCandidateWindow: @MainActor () async -> Void
        let preloadPlaybackWindow: @MainActor () async -> Void
    }

    enum FacadeCommand {
        case plan(ScenePresentationPlanningRequest)
        case scheduleWakeUp(UUID, TimeInterval)
        case cancelWakeUp(UUID)
        case cancelPlanning(Identity)
        case requestManualDirection(PlaybackSessionEngine.ScenePresentationRequestSource)
    }

    private struct EffectOperation: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    private static let surfaceActivationDelayNanoseconds: UInt64 = 250_000_000
    private var effectTasks: [UUID: EffectOperation] = [:]
    private var sceneDownloadCompletion: DownloadCompletion?
    private var barrier = ScenePresentationPrerenderBarrier()
    private var preparedSlotPreloadTasks: [UUID: Task<Void, Never>] = [:]
    private var surfaceActivationTask: EffectOperation?
    private var firstPreloadTask: EffectOperation?
    private var initialBackgroundPreloadTasks: [UUID: Task<Void, Never>] = [:]

    #if DEBUG
    private(set) var barrierAttemptCountForTesting = 0

    var activeBarrierForTesting: ScenePresentationLayerIdentity? { barrier.activeScene }
    #endif

    deinit {
        effectTasks.values.forEach { $0.task.cancel() }
        preparedSlotPreloadTasks.values.forEach { $0.cancel() }
        surfaceActivationTask?.task.cancel()
        firstPreloadTask?.task.cancel()
        initialBackgroundPreloadTasks.values.forEach { $0.cancel() }
    }

    /// Forwarded commands execute inline, including any nested reducer dispatch and publication.
    func execute(
        _ effect: ScenePresentationEffect,
        scene: PlaybackScene?,
        isInitialScene: @escaping @MainActor (Identity) -> Bool,
        images: ImageLoading,
        loadMore: @escaping @MainActor () async -> Void,
        forward: (FacadeCommand) -> Void
    ) {
        switch effect {
        case let .plan(request):
            forward(.plan(request))
        case let .scheduleWakeUp(generation, deadline):
            forward(.scheduleWakeUp(generation, deadline))
        case let .cancelWakeUp(generation):
            forward(.cancelWakeUp(generation))
        case let .requestManualDirection(source):
            forward(.requestManualDirection(source))

        case let .restartPreparation(request):
            if !isBarrierActive(for: request.identity), let scene {
                restartBarrier(identity: request.identity, scene: scene)
            }

        case let .download(request):
            guard let scene else { return }
            let task = startEffect(generation: request.identity.generation) {
                // Sample after the task starts, as before; acceptance may have changed since dispatch.
                if isInitialScene(request.identity) {
                    await images.loadInitialScene(scene)
                } else {
                    await images.loadTransitionScene(
                        scene, request.source == .manualPrevious, request.identity.generation)
                    guard !Task.isCancelled else { return }
                    await images.preloadCandidateWindow()
                    guard !Task.isCancelled else { return }
                    await images.preloadPlaybackWindow()
                }
            }
            sceneDownloadCompletion = DownloadCompletion(identity: request.identity, downloadTask: task)

        case let .retry(request, _):
            guard let scene else { return }
            restartBarrier(identity: request.identity, scene: scene)
            let task = startEffect(generation: request.identity.generation) {
                await images.loadTransitionScene(
                    scene, request.source == .manualPrevious, request.identity.generation)
            }
            sceneDownloadCompletion = DownloadCompletion(identity: request.identity, downloadTask: task)

        case let .loadMore(generation):
            _ = startEffect(generation: generation, operation: loadMore)

        case let .cancel(request):
            effectTasks[request.identity.generation]?.task.cancel()
            effectTasks[request.identity.generation] = nil
            forward(.cancelPlanning(request.identity))
            if sceneDownloadCompletion?.identity == request.identity {
                sceneDownloadCompletion = nil
            }
            releaseBarrier(for: request.identity)
        }
    }

    /// Read in the dispatching main-actor step; a later renderer callback may replace the operation.
    func downloadCompletion(for identity: Identity) -> DownloadCompletion? {
        guard sceneDownloadCompletion?.identity == identity else { return nil }
        return sceneDownloadCompletion
    }

    private func startEffect(
        generation: UUID,
        operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        effectTasks[generation]?.task.cancel()
        let operationID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await operation()
            guard !Task.isCancelled, self.effectTasks[generation]?.id == operationID else { return }
            self.effectTasks[generation] = nil
        }
        effectTasks[generation] = EffectOperation(id: operationID, task: task)
        return task
    }

    func beginBarrier(identity: Identity, scene: PlaybackScene) {
        let layerIdentity = layerIdentity(for: identity)
        if let activeScene = barrier.activeScene {
            guard activeScene != layerIdentity else { return }
            _ = barrier.release(scene: activeScene)
        }
        let rendererAttemptID = UUID()
        #if DEBUG
        barrierAttemptCountForTesting += 1
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
        _ = barrier.begin(scene: layerIdentity, expectedRenderers: expectedRenderers)
    }

    func releaseBarrier(for identity: Identity) {
        _ = barrier.release(scene: layerIdentity(for: identity))
    }

    private func restartBarrier(identity: Identity, scene: PlaybackScene) {
        releaseBarrier(for: identity)
        beginBarrier(identity: identity, scene: scene)
    }

    private func isBarrierActive(for identity: Identity) -> Bool {
        barrier.activeScene == layerIdentity(for: identity)
    }

    private func layerIdentity(for identity: Identity) -> ScenePresentationLayerIdentity {
        ScenePresentationLayerIdentity(
            generation: identity.generation, sceneID: identity.sceneID, layerID: "scene-root")
    }

    func isBarrierComplete(for layer: ScenePresentationLayerIdentity) -> Bool {
        barrier.activeScene == layer && barrier.isPresentationReady
    }

    func rendererAttemptID(for layer: ScenePresentationLayerIdentity) -> UUID? {
        guard barrier.activeScene == layer else { return nil }
        return barrier.activeRendererAttemptID
    }

    func rendererDecoded(_ identity: SceneRendererIdentity) -> ScenePresentationReadinessEvent? {
        barrier.rendererDecoded(identity)
    }

    func rendererFailed(_ identity: SceneRendererIdentity) -> Bool {
        barrier.rendererFailed(identity)
    }

    func preloadPreparedSlots(
        assetIDs: [String],
        loadPhoto: @escaping @MainActor (String) async -> Void
    ) {
        let taskID = UUID()
        preparedSlotPreloadTasks[taskID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.preparedSlotPreloadTasks[taskID] = nil }
            await withTaskGroup(of: Void.self) { group in
                for assetID in assetIDs {
                    group.addTask { @MainActor in
                        guard !Task.isCancelled else { return }
                        await loadPhoto(assetID)
                    }
                }
            }
        }
    }

    func scheduleSurfaceActivation(
        activate: @escaping @MainActor () -> DownloadCompletion?
    ) {
        surfaceActivationTask?.task.cancel()
        let operationID = UUID()
        let task = Task { @MainActor [weak self] in
            // Surface and control-bar animations can report several sizes in a short interval.
            try? await Task.sleep(nanoseconds: Self.surfaceActivationDelayNanoseconds)
            guard !Task.isCancelled, let self else { return }
            if let completion = activate() {
                await completion.waitForDownloads()
            }
            if self.surfaceActivationTask?.id == operationID {
                self.surfaceActivationTask = nil
            }
        }
        surfaceActivationTask = EffectOperation(id: operationID, task: task)
    }

    func cancelSurfaceActivation() {
        surfaceActivationTask?.task.cancel()
        surfaceActivationTask = nil
    }

    func runFirstPreload(
        sourceName: String,
        logger: Logger,
        prepare: @escaping @MainActor () async -> Void
    ) async {
        if let firstPreloadTask {
            logger.info("first preload waits existing task")
            await firstPreloadTask.task.value
            return
        }
        logger.info("first preload task created source=\(sourceName, privacy: .public)")
        let operationID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.firstPreloadTask?.id == operationID {
                    self.firstPreloadTask = nil
                }
            }
            await prepare()
        }
        firstPreloadTask = EffectOperation(id: operationID, task: task)
        await task.value
    }

    func startInitialBackgroundPreload(operation: @escaping @MainActor () async -> Void) {
        let operationID = UUID()
        initialBackgroundPreloadTasks[operationID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.initialBackgroundPreloadTasks[operationID] = nil }
            await operation()
        }
    }

    func cancelStartup() {
        firstPreloadTask?.task.cancel()
        firstPreloadTask = nil
        initialBackgroundPreloadTasks.values.forEach { $0.cancel() }
        initialBackgroundPreloadTasks = [:]
    }

    /// Pool replacement also happens inside startup, so this must not cancel the startup caller.
    func resetPresentation() {
        effectTasks.values.forEach { $0.task.cancel() }
        effectTasks = [:]
        sceneDownloadCompletion = nil
        barrier = ScenePresentationPrerenderBarrier()
        preparedSlotPreloadTasks.values.forEach { $0.cancel() }
        preparedSlotPreloadTasks = [:]
    }
}
