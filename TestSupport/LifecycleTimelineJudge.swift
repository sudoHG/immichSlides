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
}

enum LifecycleTimelineJudge {
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

    static func validate(_ events: [LifecycleTimelineEvent]) throws {
        guard let first = events.first, first.kind == "timelineStarted", !first.launchNonce.isEmpty,
            !first.caseNonce.isEmpty
        else { throw Failure("missing timelineStarted") }
        var previousUptime = -Double.infinity
        var paused = false
        var exception: String?
        var exceptionScene: String?
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
            case "continueReceived", "manualNavigationReceived":
                paused = false
                exception = nil
                exceptionScene = nil
            case "pauseFadeGapException", "pauseManualHoldException":
                let basis = event.kind == "pauseFadeGapException" ? "automaticInvisibleGap" : "manualHoldRaise"
                guard paused, exception == nil, !event.scene.isEmpty,
                    index > 0, events[index - 1].kind == "pauseReceived", event.exceptionBasis == basis
                else {
                    throw Failure("pause exception misuse")
                }
                exception = event.kind
                exceptionScene = event.scene
            case "renderFadeStarted", "sceneCommitted", "sceneStable", "frozenFrameChanged":
                if paused {
                    guard exception != nil, event.scene == exceptionScene else {
                        throw Failure("frame advanced during pause")
                    }
                    // Both exceptions finish one short fade of the explicitly named photo, then freeze.
                    if event.kind == "sceneStable" { exception = nil }
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
            "continueReceived", "pauseFadeGapException", "pauseManualHoldException", "backgroundReceived"
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
}
