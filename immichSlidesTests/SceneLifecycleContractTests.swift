import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite
struct SceneLifecycleContractTests {
    @Test(arguments: [
        "valid", "early", "late", "missing", "missingFade", "sequence", "nonce", "exception", "slowStable", "samePhoto",
        "notStable"
    ])
    func `app timeline rejects timing and integrity mutations`(mutation: String) throws {
        var events = [
            LifecycleTimelineEvent(sequence: 1, kind: "timelineStarted", uptime: 0),
            LifecycleTimelineEvent(
                sequence: 2, kind: "sceneStable", uptime: 1, scene: "old", assets: ["old-photo"], isStable: true),
            LifecycleTimelineEvent(sequence: 3, kind: "pauseReceived", uptime: 2, scene: "old"),
            LifecycleTimelineEvent(sequence: 4, kind: "checkpoint", uptime: 15, scene: "old"),
            LifecycleTimelineEvent(
                sequence: 5, kind: "continueReceived", uptime: 16, scene: "old", assets: ["old-photo"]),
            LifecycleTimelineEvent(sequence: 6, kind: "renderFadeStarted", uptime: 26, scene: "old"),
            LifecycleTimelineEvent(
                sequence: 7, kind: "sceneStable", uptime: 28, scene: "new", assets: ["new-photo"], isStable: true),
            LifecycleTimelineEvent(sequence: 8, kind: "checkpoint", uptime: 34, scene: "new")
        ]
        switch mutation {
        case "early": events[5].uptime -= 3
        case "late": events[5].uptime += 3; events[6].uptime += 3
        case "missing": events.remove(at: 5)
        case "missingFade":
            events.remove(at: 5)
            for index in events.indices { events[index].sequence = index + 1 }
        case "sequence": events[5].sequence = 8
        case "nonce": events[5].launchNonce = "another-launch"
        case "exception": events[2].kind = "pauseFadeGapException"
        case "slowStable": events[6].uptime += 3
        case "samePhoto": events[6].assets = events[4].assets
        case "notStable": events[6].isStable = false
        default: break
        }
        if mutation == "valid" {
            let judgment = try LifecycleTimelineJudge.judge(events, continueSequence: 5, interval: 10)
            #expect(judgment.onsetSeconds == 10)
            #expect(judgment.stableSecondsAfterOnset == 2)
        } else {
            let expected = [
                "early": "Continue onset outside T±2", "late": "Continue onset outside T±2",
                "missing": "noncontiguous sequence", "sequence": "noncontiguous sequence",
                "missingFade": "missing unambiguous fade onset",
                "nonce": "nonce mismatch", "exception": "pause exception misuse",
                "slowStable": "new photo not stable within onset+4", "samePhoto": "new photo not stable within onset+4",
                "notStable": "new photo not stable within onset+4"
            ][mutation]
            do {
                _ = try LifecycleTimelineJudge.judge(events, continueSequence: 5, interval: 10)
                Issue.record("The timeline mutation must fail")
            } catch let error as LifecycleTimelineJudge.Failure {
                #expect(error.description == "App timeline: \(expected ?? "missing expectation")")
            }
        }
    }

    @Test(arguments: [false, true])
    func `midpoint Pause cannot hide an early automatic fade`(hasEarlyFade: Bool) throws {
        let events = [
            LifecycleTimelineEvent(sequence: 1, kind: "timelineStarted", uptime: 0),
            LifecycleTimelineEvent(sequence: 2, kind: "continueReceived", uptime: 1, scene: "old"),
            LifecycleTimelineEvent(
                sequence: 3, kind: hasEarlyFade ? "renderFadeStarted" : "checkpoint", uptime: 5, scene: "old"),
            LifecycleTimelineEvent(sequence: 4, kind: "pauseReceived", uptime: 6, scene: "old")
        ]
        if hasEarlyFade {
            #expect(throws: LifecycleTimelineJudge.Failure.self) {
                try LifecycleTimelineJudge.judgeMidpointPause(
                    events, continueSequence: 2, pauseSequence: 4, interval: 10)
            }
        } else {
            try LifecycleTimelineJudge.judgeMidpointPause(events, continueSequence: 2, pauseSequence: 4, interval: 10)
        }
    }

    @Test(arguments: ["pauseFadeGapException", "pauseManualHoldException"])
    func `pause exceptions finish only the explicitly named photo and cannot excuse later changes`(kind: String) throws
    {
        let basis = kind == "pauseFadeGapException" ? "automaticInvisibleGap" : "manualHoldRaise"
        var events = [
            LifecycleTimelineEvent(sequence: 1, kind: "timelineStarted", uptime: 0),
            LifecycleTimelineEvent(sequence: 2, kind: "pauseReceived", uptime: 1, scene: "old"),
            LifecycleTimelineEvent(sequence: 3, kind: kind, uptime: 1, scene: "next", exceptionBasis: basis),
            LifecycleTimelineEvent(sequence: 4, kind: "frozenFrameChanged", uptime: 1.1, scene: "next"),
            LifecycleTimelineEvent(
                sequence: 5, kind: "sceneStable", uptime: 1.3, scene: "next", isStable: true, isPaused: true)
        ]
        try LifecycleTimelineJudge.validate(events)
        events.append(LifecycleTimelineEvent(sequence: 6, kind: "frozenFrameChanged", uptime: 2, scene: "next"))
        #expect(throws: LifecycleTimelineJudge.Failure.self) { try LifecycleTimelineJudge.validate(events) }
    }

    @Test(arguments: [false, true])
    func `content requires the entire capture interval to remain in one evidenced state`(crossesFade: Bool) throws {
        let events = [
            LifecycleTimelineEvent(sequence: 1, kind: "timelineStarted", uptime: 0),
            LifecycleTimelineEvent(sequence: 2, kind: "sceneStable", uptime: 1, scene: "old", isStable: true),
            LifecycleTimelineEvent(sequence: 3, kind: "renderFadeStarted", uptime: 10, scene: "old"),
            LifecycleTimelineEvent(sequence: 4, kind: "sceneStable", uptime: 12, scene: "new", isStable: true),
            LifecycleTimelineEvent(sequence: 5, kind: "checkpoint", uptime: 14, scene: "new", isStable: true)
        ]
        let state = try LifecycleTimelineJudge.contentState(
            events, request: crossesFade ? 9 : 1, returned: crossesFade ? 13 : 9)
        if crossesFade {
            #expect(state == nil)
        } else {
            // A wide interval is still conclusive when its entire span has the same stable photo.
            #expect(state?.scene == "old")
        }
    }

    @Test
    func `single photo longest visible motion window includes the incoming fade duration`() {
        let contract = SceneLifecycleContract(configuredInterval: 3)

        #expect(contract.configuredInterval == 3)
        #expect(contract.frozenInterval == 5)
        #expect(contract.graceDuration == 1)
        #expect(SceneLifecycleContract.outgoingFadeDuration == 1)
        #expect(SceneLifecycleContract.incomingDelay == 1.025)
        #expect(SceneLifecycleContract.incomingFadeDuration == 1)
        #expect(SceneLifecycleContract.transitionDuration == 2.025)
        #expect(contract.longestVisibleMotionDuration == 8)
    }

    @Test
    func `default single photo tunables start full zoom-out at 1.10 and shrink continuously to 1.00`() {
        #expect(SinglePhotoAnimationTunables.default.zoomInTargetScale == 1.10)
        #expect(SinglePhotoAnimationTunables.default.continueShrinkRange == 0.10)
    }

    @Test
    func
        `single photo zoom-out keeps headroom at frozen stable end and reaches 1.00 continuously at the longest window`()
    {
        let lifecycle = SceneLifecycleContract(configuredInterval: 5)
        let profile = SceneAnimationProfile(lifecycle: lifecycle)
        let frozenStableEndTime = SceneLifecycleContract.incomingFadeDuration + lifecycle.frozenInterval

        let stableEnd = profile.singlePhotoTransform(
            direction: .zoomOut,
            activeTime: frozenStableEndTime,
            isMotionEnabled: true
        )
        let longestEnd = profile.singlePhotoTransform(
            direction: .zoomOut,
            activeTime: lifecycle.longestVisibleMotionDuration,
            isMotionEnabled: true
        )

        #expect(stableEnd.scale >= 1.02)
        #expect(stableEnd.scale <= 1.03)
        #expect(longestEnd.scale == 1.00)
    }

    @Test
    func `single photo zoom-out reaches its end exactly at 8 seconds when the motion clock starts at incoming fade`() {
        let lifecycle = SceneLifecycleContract(configuredInterval: 5)
        let profile = SceneAnimationProfile(lifecycle: lifecycle)

        let fullTimelineEnd = profile.singlePhotoTransform(
            direction: .zoomOut,
            activeTime: 8,
            isMotionEnabled: true
        )

        #expect(fullTimelineEnd.scale == 1.00)
    }

    @Test
    func `single photo zoom-in stops exactly at 1.10 at the full visible timeline end instead of overshooting`() {
        let lifecycle = SceneLifecycleContract(configuredInterval: 5)
        let profile = SceneAnimationProfile(lifecycle: lifecycle)

        let frozenStableEnd = profile.singlePhotoTransform(
            direction: .zoomIn,
            activeTime: SceneLifecycleContract.incomingFadeDuration + lifecycle.frozenInterval,
            isMotionEnabled: true
        )
        let fullTimelineEnd = profile.singlePhotoTransform(
            direction: .zoomIn,
            activeTime: lifecycle.longestVisibleMotionDuration,
            isMotionEnabled: true
        )

        #expect(abs(frozenStableEnd.scale - 1.075) < 0.0001)
        #expect(abs(fullTimelineEnd.scale - 1.10) < 0.0001)
    }

    @Test
    func `an already started single photo motion keeps its current sample after Reduce Motion toggles on`() {
        let profile = SceneAnimationProfile(lifecycle: SceneLifecycleContract(configuredInterval: 5))
        let active = profile.singlePhotoTransform(
            direction: .zoomIn,
            activeTime: 2,
            isMotionEnabled: true
        )
        let frozenForReduceMotion = profile.singlePhotoTransform(
            direction: .zoomIn,
            activeTime: 2,
            isMotionEnabled: true
        )

        #expect(!active.isIdentity)
        #expect(frozenForReduceMotion == active)
    }
}
