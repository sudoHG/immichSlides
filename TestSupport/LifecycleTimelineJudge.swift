import Foundation

/// Read-only wire projection; the App owns the independently compiled DEBUG producer.
struct LifecycleTimelineEvent: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var launchNonce = "synthetic-launch"
    var caseNonce = "synthetic-case"
    var sequence: Int
    var kind: String
    var uptime: TimeInterval
    var scene: String = ""
    var assets: [String] = []
    var frame: String = ""
    var isStable = false
    var isPaused = false
    var request: String = ""
    var exceptionBasis: String = ""
    var transitionScene: String?
    var transitionSource: String?
    var heldTargetScene: String?
}

enum LifecycleTimelineJudge {
    private static let frozenPixelMaximumChannelDifference = 1

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ reason: String) { description = "App timeline: " + reason }
    }

    struct Judgment: Codable {
        let continueSequence: Int
        let onsetSequence: Int
        let stableSequence: Int
        let onsetSeconds: TimeInterval
        let stableSecondsAfterOnset: TimeInterval
    }

    private struct PausedTransition {
        let origin: String
        var target: String?
        var hasCommit = false

        mutating func bind(_ scene: String) throws {
            guard !scene.isEmpty, scene != origin, target == nil || target == scene else {
                throw Failure("paused manual transition exceeded one target")
            }
            target = scene
        }

        mutating func accept(_ event: LifecycleTimelineEvent) throws {
            guard ["manualNext", "manualPrevious"].contains(event.transitionSource ?? "") else {
                throw Failure("automatic change during paused manual navigation")
            }
            guard event.isPaused else { throw Failure("paused manual transition exceeded one target") }
            try bind(event.transitionScene ?? "")
            switch event.kind {
            case "sceneCommitted":
                guard !hasCommit, event.scene == target else {
                    throw Failure("paused manual transition exceeded one target")
                }
                hasCommit = true
            case "sceneStable":
                guard hasCommit, event.isStable, event.scene == target else {
                    throw Failure("paused manual transition exceeded one target")
                }
            default: break
            }
        }
    }

    static func validate(_ events: [LifecycleTimelineEvent]) throws {
        guard let first = events.first, first.kind == "timelineStarted", !first.launchNonce.isEmpty,
            !first.caseNonce.isEmpty
        else { throw Failure("missing timelineStarted") }
        var previousUptime = -Double.infinity
        var paused = false
        var exception: String?
        var exceptionScene: String?
        var pauseScene = ""
        var heldTargetScene: String?
        var pausedTransition: PausedTransition?
        for (index, event) in events.enumerated() {
            guard event.schemaVersion == 1, event.sequence == index + 1 else {
                throw Failure("noncontiguous sequence")
            }
            guard event.launchNonce == first.launchNonce, event.caseNonce == first.caseNonce else {
                throw Failure("nonce mismatch")
            }
            guard event.uptime.isFinite, event.uptime >= previousUptime else {
                throw Failure("nonmonotonic uptime")
            }
            previousUptime = event.uptime
            switch event.kind {
            case "timelineStarted", "checkpoint", "clockHandshake", "foregroundReceived", "backgroundReceived": break
            case "pauseReceived":
                paused = true
                exception = nil
                exceptionScene = nil
                pauseScene = event.scene
                heldTargetScene = event.heldTargetScene.flatMap { $0.isEmpty ? nil : $0 }
                pausedTransition = nil
            case "continueReceived":
                paused = false
                exception = nil
                exceptionScene = nil
                heldTargetScene = nil
                pausedTransition = nil
            case "manualNavigationReceived":
                exception = nil
                exceptionScene = nil
                heldTargetScene = nil
                if paused {
                    guard pausedTransition == nil else {
                        throw Failure("paused manual transition exceeded one target")
                    }
                    pausedTransition = PausedTransition(origin: event.scene)
                }
            case "pauseFadeGapException", "pauseManualHoldException":
                let basis = event.kind == "pauseFadeGapException" ? "automaticInvisibleGap" : "manualHoldRaise"
                guard paused, exception == nil, !event.scene.isEmpty,
                    index > 0, events[index - 1].kind == "pauseReceived", event.exceptionBasis == basis
                else {
                    throw Failure("pause exception misuse")
                }
                exception = event.kind
                exceptionScene = event.scene
            case "pauseHeldCrossfadeException":
                guard paused, !event.scene.isEmpty, event.transitionScene == event.scene,
                    ["manualNext", "manualPrevious"].contains(event.transitionSource ?? ""),
                    event.exceptionBasis == "heldManualTargetReady",
                    heldTargetScene == event.scene || pausedTransition != nil
                else { throw Failure("pause exception misuse") }
                var transition = pausedTransition ?? PausedTransition(origin: pauseScene)
                try transition.bind(event.scene)
                pausedTransition = transition
                heldTargetScene = nil
                exception = nil
                exceptionScene = nil
            case "renderFadeStarted", "sceneCommitted", "sceneStable", "frozenFrameChanged":
                if paused {
                    if var transition = pausedTransition {
                        try transition.accept(event)
                        pausedTransition = event.kind == "sceneStable" ? nil : transition
                    } else {
                        guard exception != nil, event.scene == exceptionScene else {
                            throw Failure("frame advanced during pause")
                        }
                        // A raised or gap photo finishes its explicitly named fade, then freezes.
                        if event.kind == "sceneStable" { exception = nil }
                    }
                }
                if event.kind == "sceneStable", event.isPaused { paused = true }
            case "renderUnstable", "pauseFrameCommitted", "frameFrozen": break
            default: throw Failure("unknown event " + event.kind)
            }
        }
    }

    /// docs/TESTING.md: Continue onset T±2, followed by a recognisable new photo within four seconds.
    static func judge(
        _ events: [LifecycleTimelineEvent], continueSequence: Int, interval: TimeInterval
    ) throws -> Judgment {
        try validate(events)
        guard interval.isFinite, interval >= 5,
            let receipt = events.first(where: { $0.sequence == continueSequence }),
            receipt.kind == "continueReceived"
        else { throw Failure("missing Continue receipt") }
        let following = events.filter { $0.sequence > continueSequence }
        guard
            let onset = following.first(where: {
                ["renderFadeStarted", "manualNavigationReceived", "pauseReceived", "continueReceived"].contains($0.kind)
            }), onset.kind == "renderFadeStarted", onset.scene == receipt.scene
        else {
            throw Failure("missing unambiguous fade onset")
        }
        let elapsed = onset.uptime - receipt.uptime
        guard (interval - 2...interval + 2).contains(elapsed) else {
            throw Failure("Continue onset outside T±2")
        }
        guard let stable = following.first(where: { $0.sequence > onset.sequence && $0.kind == "sceneStable" }),
            stable.isStable, !stable.assets.isEmpty, stable.assets != receipt.assets,
            !stable.scene.isEmpty, stable.scene != receipt.scene,
            stable.uptime - onset.uptime <= 4
        else { throw Failure("new photo not stable within onset+4") }
        return Judgment(
            continueSequence: receipt.sequence, onsetSequence: onset.sequence, stableSequence: stable.sequence,
            onsetSeconds: elapsed, stableSecondsAfterOnset: stable.uptime - onset.uptime)
    }

    static func judgeMidpointPause(
        _ events: [LifecycleTimelineEvent], continueSequence: Int, pauseSequence: Int, interval: TimeInterval
    ) throws {
        try validate(events)
        guard let receipt = events.first(where: { $0.sequence == continueSequence && $0.kind == "continueReceived" }),
            let pause = events.first(where: { $0.sequence == pauseSequence && $0.kind == "pauseReceived" }),
            pause.sequence > receipt.sequence, pause.uptime - receipt.uptime < interval - 2
        else { throw Failure("midpoint Pause did not cover T-2") }
        guard
            !events.contains(where: {
                $0.sequence > continueSequence && $0.sequence < pauseSequence
                    && ["renderFadeStarted", "sceneCommitted", "manualNavigationReceived"].contains($0.kind)
            })
        else { throw Failure("automatic transition before midpoint Pause") }
    }

    /// Returns nil for an interval crossing an uncertain boundary. The caller must obtain another content proof.
    static func contentState(
        _ events: [LifecycleTimelineEvent], request: TimeInterval, returned: TimeInterval
    ) throws -> LifecycleTimelineEvent? {
        try validate(events)
        guard request.isFinite, returned.isFinite, request <= returned,
            let seal = events.last, seal.uptime >= returned,
            let state = events.last(where: {
                $0.uptime <= request && (($0.kind == "sceneStable" && $0.isStable) || $0.kind == "frameFrozen")
            })
        else { return nil }
        let invalidating = [
            "renderFadeStarted", "renderUnstable", "frozenFrameChanged", "manualNavigationReceived",
            "continueReceived", "pauseFadeGapException", "pauseManualHoldException", "pauseHeldCrossfadeException",
            "backgroundReceived"
        ]
        guard
            !events.contains(where: {
                $0.sequence > state.sequence && $0.uptime <= returned
                    && (invalidating.contains($0.kind)
                        || (["sceneStable", "sceneCommitted"].contains($0.kind) && $0.scene != state.scene))
            })
        else { return nil }
        return state
    }

    // Maintainer-approved; see docs/TESTING.md.
    static func frozenPixelsEqual(
        _ reference: [UInt8], _ candidate: [UInt8], events: [LifecycleTimelineEvent],
        scene: String, frame: String, request: TimeInterval, returned: TimeInterval
    ) throws -> Bool {
        try validate(events)
        guard !reference.isEmpty, reference.count == candidate.count else { return false }
        if reference == candidate { return true }
        guard request.isFinite, returned.isFinite, request <= returned, !scene.isEmpty, !frame.isEmpty,
            let seal = events.first(where: { $0.uptime >= returned }),
            seal.isPaused, seal.scene == scene, seal.frame == frame,
            let anchor = events.last(where: {
                $0.kind == "frameFrozen" && $0.uptime <= request && $0.isPaused
                    && $0.scene == scene && $0.frame == frame
            }),
            zip(reference, candidate).allSatisfy({
                abs(Int($0.0) - Int($0.1)) <= frozenPixelMaximumChannelDifference
            })
        else { return false }
        return events.filter { $0.sequence >= anchor.sequence && $0.sequence <= seal.sequence }.allSatisfy {
            ["frameFrozen", "checkpoint", "clockHandshake"].contains($0.kind)
                && $0.isPaused && $0.scene == scene && $0.frame == frame
        }
    }
}
