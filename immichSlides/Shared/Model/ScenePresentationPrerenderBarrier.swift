//
//  ScenePresentationPrerenderBarrier.swift
//  immichSlides
//
//  Decoded boundary for hidden prerendering; a finished decode does not mean it was written to history.
//

import Foundation

/// Generation identity of a complete layer; kept separate from the Slot renderer identity.
struct ScenePresentationLayerIdentity: Hashable, Sendable {
    let generation: UUID
    let sceneID: String
    let layerID: String

    init(generation: UUID, sceneID: String, layerID: String) {
        self.generation = generation
        self.sceneID = sceneID
        self.layerID = layerID
    }
}

/// Stable identity that every renderer callback must carry in full.
struct SceneRendererIdentity: Hashable, Sendable {
    let generation: UUID
    /// Rebuilding the barrier must use a new attemptID so an old callback cannot enter a new attempt.
    let attemptID: UUID?
    let sceneID: String
    let slotID: String?
    let assetID: String

    init(
        generation: UUID,
        attemptID: UUID? = nil,
        sceneID: String,
        slotID: String?,
        assetID: String
    ) {
        self.generation = generation
        self.attemptID = attemptID
        self.sceneID = sceneID
        self.slotID = slotID
        self.assetID = assetID
    }
}

enum ScenePresentationReadinessEvent: Equatable, Sendable {
    case presentationReady(ScenePresentationLayerIdentity)
}

/// Only aggregates decoded results; does not commit history or change the reducer's visible state.
struct ScenePresentationPrerenderBarrier: Equatable, Sendable {
    private(set) var activeScene: ScenePresentationLayerIdentity?
    private(set) var activeRendererAttemptID: UUID?
    private(set) var expectedRenderers: Set<SceneRendererIdentity>
    private(set) var decodedRenderers: Set<SceneRendererIdentity>
    private(set) var failedRenderers: Set<SceneRendererIdentity>
    private var hasEmittedPresentationReady = false

    init() {
        activeScene = nil
        activeRendererAttemptID = nil
        expectedRenderers = []
        decodedRenderers = []
        failedRenderers = []
    }

    var isPresentationReady: Bool {
        activeScene != nil && !expectedRenderers.isEmpty && failedRenderers.isEmpty
            && decodedRenderers == expectedRenderers
    }

    /// Only one generation at a time may build hidden renderers; a repeated begin is idempotent.
    @discardableResult
    mutating func begin(
        scene: ScenePresentationLayerIdentity,
        expectedRenderers: Set<SceneRendererIdentity>
    ) -> Bool {
        guard !expectedRenderers.isEmpty,
            let rendererAttemptID = expectedRenderers.first?.attemptID,
            expectedRenderers.allSatisfy({
                $0.generation == scene.generation && $0.attemptID == rendererAttemptID && $0.sceneID == scene.sceneID
            })
        else {
            return false
        }

        if let activeScene {
            return activeScene == scene && self.expectedRenderers == expectedRenderers
        }

        activeScene = scene
        activeRendererAttemptID = rendererAttemptID
        self.expectedRenderers = expectedRenderers
        decodedRenderers = []
        failedRenderers = []
        hasEmittedPresentationReady = false
        return true
    }

    /// A successful hidden decode only counts toward the barrier; it does not mean the user has seen it.
    mutating func rendererDecoded(
        _ identity: SceneRendererIdentity
    ) -> ScenePresentationReadinessEvent? {
        guard expectedRenderers.contains(identity), failedRenderers.isEmpty else {
            return nil
        }
        decodedRenderers.insert(identity)
        guard isPresentationReady,
            !hasEmittedPresentationReady,
            let activeScene
        else {
            return nil
        }
        hasEmittedPresentationReady = true
        return .presentationReady(activeScene)
    }

    /// If any Slot fails, the whole unseen scene is invalid; it cannot be partially promoted.
    @discardableResult
    mutating func rendererFailed(_ identity: SceneRendererIdentity) -> Bool {
        guard expectedRenderers.contains(identity) else { return false }
        failedRenderers.insert(identity)
        return true
    }

    /// Released once the generation is replaced or cancelled; later old callbacks are all ignored.
    @discardableResult
    mutating func release(scene: ScenePresentationLayerIdentity) -> Bool {
        guard activeScene == scene else { return false }
        activeScene = nil
        activeRendererAttemptID = nil
        expectedRenderers = []
        decodedRenderers = []
        failedRenderers = []
        hasEmittedPresentationReady = false
        return true
    }
}
