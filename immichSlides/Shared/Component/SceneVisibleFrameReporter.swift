//
//  SceneVisibleFrameReporter.swift
//  immichSlides
//
//  Visibility boundary of a complete scene-root: "the next display tick after the transaction completes".
//

import Foundation
#if os(iOS) || os(tvOS)
import QuartzCore
import SwiftUI
#endif

struct SceneVisibleFrameCandidate: Equatable, Sendable {
    let layerIdentity: ScenePresentationLayerIdentity
    let role: PlaybackSessionEngine.ScenePresentationLayerRole
    let opacity: Double
    let isBarrierComplete: Bool
    let isSceneRoot: Bool

    init(
        layerIdentity: ScenePresentationLayerIdentity,
        role: PlaybackSessionEngine.ScenePresentationLayerRole,
        opacity: Double,
        isBarrierComplete: Bool,
        isSceneRoot: Bool
    ) {
        self.layerIdentity = layerIdentity
        self.role = role
        self.opacity = opacity
        self.isBarrierComplete = isBarrierComplete
        self.isSceneRoot = isSceneRoot
    }

    var isEligibleForVisibility: Bool {
        isSceneRoot && (role == .incoming || role == .stable) && opacity > 0 && isBarrierComplete
    }
}

/// Reporter with no UI dependency; the platform host counts as visible only on the next tick after the
/// transaction completes.
struct SceneVisibleFrameReporter: Equatable, Sendable {
    private var pendingCandidate: SceneVisibleFrameCandidate?
    private var reportedLayers: Set<ScenePresentationLayerIdentity>

    init() {
        pendingCandidate = nil
        reportedLayers = []
    }

    /// Arms a single one-shot tick, only after the animation transaction of a complete scene-root completes.
    @discardableResult
    mutating func transactionCompleted(
        candidate: SceneVisibleFrameCandidate
    ) -> Bool {
        guard candidate.isEligibleForVisibility,
            !reportedLayers.contains(candidate.layerIdentity)
        else {
            pendingCandidate = nil
            return false
        }
        pendingCandidate = candidate
        return true
    }

    /// The next tick must re-check generation/role/opacity/barrier; rising opacity during a fade-in does not count
    /// as supersession.

    mutating func consumeDisplayTick(
        currentCandidate: SceneVisibleFrameCandidate?
    ) -> ScenePresentationLayerIdentity? {
        defer { pendingCandidate = nil }
        guard let pendingCandidate,
            let currentCandidate,
            pendingCandidate.layerIdentity == currentCandidate.layerIdentity,
            pendingCandidate.role == currentCandidate.role,
            currentCandidate.isEligibleForVisibility,
            !reportedLayers.contains(currentCandidate.layerIdentity)
        else {
            return nil
        }
        reportedLayers.insert(currentCandidate.layerIdentity)
        return currentCandidate.layerIdentity
    }

    mutating func cancel(scene: ScenePresentationLayerIdentity) {
        if pendingCandidate?.layerIdentity == scene {
            pendingCandidate = nil
        }
    }
}

#if os(iOS) || os(tvOS)
/// Attached only to a complete scene-root; hands the CA transaction and the real display tick to the UI-free
/// reporter.

struct SceneVisibleFrameReporterModifier: ViewModifier {
    let candidate: SceneVisibleFrameCandidate
    let onIncomingBecameVisible: (ScenePresentationLayerIdentity) -> Void

    @State private var reporter = SceneVisibleFrameReporter()
    @State private var currentCandidate: SceneVisibleFrameCandidate?

    private var taskIdentity: String {
        [
            candidate.layerIdentity.generation.uuidString,
            candidate.layerIdentity.sceneID,
            candidate.layerIdentity.layerID,
            candidate.role.rawValue,
            candidate.isEligibleForVisibility ? "eligible" : "ineligible"
        ].joined(separator: "|")
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: candidate, initial: true) { _, updatedCandidate in
                currentCandidate = updatedCandidate
            }
            .task(id: taskIdentity) {
                currentCandidate = candidate
                guard candidate.isEligibleForVisibility else {
                    reporter.cancel(scene: candidate.layerIdentity)
                    return
                }

                await SceneTransactionCompletionAwaiter.wait()
                guard !Task.isCancelled,
                    let armedCandidate = currentCandidate,
                    reporter.transactionCompleted(candidate: armedCandidate)
                else {
                    return
                }

                let displayTickAwaiter = SceneDisplayTickAwaiter()
                await displayTickAwaiter.waitForNextTick()
                guard !Task.isCancelled,
                    let visibleLayer = reporter.consumeDisplayTick(
                        currentCandidate: currentCandidate
                    )
                else {
                    return
                }
                onIncomingBecameVisible(visibleLayer)
            }
    }
}

@MainActor
private enum SceneTransactionCompletionAwaiter {
    static func wait() async {
        await withCheckedContinuation { continuation in
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                continuation.resume()
            }
            CATransaction.commit()
        }
    }
}

@MainActor
private final class SceneDisplayTickAwaiter: NSObject {
    private var continuation: CheckedContinuation<Void, Never>?
    private var displayLink: CADisplayLink?

    func waitForNextTick() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let displayLink = CADisplayLink(target: self, selector: #selector(displayTick))
            self.displayLink = displayLink
            displayLink.add(to: .main, forMode: .common)
        }
    }

    @objc private func displayTick() {
        displayLink?.invalidate()
        displayLink = nil
        continuation?.resume()
        continuation = nil
    }
}
#endif
