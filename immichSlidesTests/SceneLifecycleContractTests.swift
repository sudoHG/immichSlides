import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite
struct SceneLifecycleContractTests {
    @Test(arguments: [
        "valid", "early", "late", "missing", "missingFade", "sequence", "nonce", "exception", "slowStable", "samePhoto",
        "notStable", "caseNonce"
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
        case "caseNonce": events[5].caseNonce = "another-case"
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
                "nonce": "nonce mismatch", "caseNonce": "nonce mismatch", "exception": "pause exception misuse",
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

    @Test(arguments: [
        "gap", "raise", "sceneMismatch", "basisMismatch", "notImmediate", "held", "heldMismatch", "heldMissing",
        "heldAutomatic", "heldAfterRaise"
    ])
    func `pause exceptions finish only the explicitly named photo and cannot excuse later changes`(mutation: String)
        throws
    {
        let isHeld = mutation.hasPrefix("held")
        let kind =
            isHeld
            ? "pauseHeldCrossfadeException" : mutation == "raise" ? "pauseManualHoldException" : "pauseFadeGapException"
        let basis = isHeld ? "heldManualTargetReady" : mutation == "raise" ? "manualHoldRaise" : "automaticInvisibleGap"
        var events = [
            LifecycleTimelineEvent(sequence: 1, kind: "timelineStarted", uptime: 0),
            LifecycleTimelineEvent(
                sequence: 2, kind: "pauseReceived", uptime: 1, scene: "old", heldTargetScene: isHeld ? "next" : nil),
            LifecycleTimelineEvent(
                sequence: 3, kind: kind, uptime: 1, scene: "next", exceptionBasis: basis,
                transitionScene: isHeld ? "next" : nil, transitionSource: isHeld ? "manualNext" : nil),
            LifecycleTimelineEvent(
                sequence: 4, kind: isHeld ? "renderFadeStarted" : "frozenFrameChanged", uptime: 1.1,
                scene: isHeld ? "old" : "next", isPaused: true, transitionScene: "next", transitionSource: "manualNext"),
            LifecycleTimelineEvent(
                sequence: 5, kind: "sceneCommitted", uptime: 1.2, scene: "next", isPaused: true,
                transitionScene: "next", transitionSource: "manualNext"),
            LifecycleTimelineEvent(
                sequence: 6, kind: "sceneStable", uptime: 1.3, scene: "next", isStable: true, isPaused: true,
                transitionScene: "next", transitionSource: "manualNext")
        ]
        switch mutation {
        case "sceneMismatch": events[3].scene = "other"
        case "basisMismatch": events[2].exceptionBasis = "wrong-basis"
        case "notImmediate": events.insert(LifecycleTimelineEvent(sequence: 0, kind: "checkpoint", uptime: 1), at: 2)
        case "heldMismatch": events[1].heldTargetScene = "other"
        case "heldMissing": events[1].heldTargetScene = nil
        case "heldAutomatic": events[2].transitionSource = "autoplay"
        case "heldAfterRaise":
            events.insert(
                contentsOf: [
                    LifecycleTimelineEvent(
                        sequence: 0, kind: "pauseManualHoldException", uptime: 1, scene: "raised",
                        exceptionBasis: "manualHoldRaise"),
                    LifecycleTimelineEvent(
                        sequence: 0, kind: "sceneStable", uptime: 1, scene: "raised", isStable: true, isPaused: true)
                ], at: 2)
            events[5].scene = "raised"
        default: break
        }
        if isHeld, let index = events.firstIndex(where: { $0.kind == "pauseHeldCrossfadeException" }) {
            events.insert(LifecycleTimelineEvent(sequence: 0, kind: "checkpoint", uptime: 1), at: index)
        }
        for index in events.indices { events[index].sequence = index + 1 }
        let isValid = ["gap", "raise", "held", "heldAfterRaise"].contains(mutation)
        if isValid {
            try LifecycleTimelineJudge.validate(events)
            events.append(
                LifecycleTimelineEvent(sequence: events.count + 1, kind: "frozenFrameChanged", uptime: 2, scene: "next")
            )
        }
        let expected = isValid || mutation == "sceneMismatch" ? "frame advanced during pause" : "pause exception misuse"
        do {
            try LifecycleTimelineJudge.validate(events)
            Issue.record("The pause exception mutation must fail")
        } catch let error as LifecycleTimelineJudge.Failure {
            #expect(error.description == "App timeline: \(expected)")
        }
    }

    @Test(arguments: ["stable", "crossesFade", "missingSeal"])
    func `content requires the entire capture interval to remain in one evidenced state`(mutation: String) throws {
        var events = [
            LifecycleTimelineEvent(sequence: 1, kind: "timelineStarted", uptime: 0),
            LifecycleTimelineEvent(sequence: 2, kind: "sceneStable", uptime: 1, scene: "old", isStable: true),
            LifecycleTimelineEvent(sequence: 3, kind: "renderFadeStarted", uptime: 10, scene: "old"),
            LifecycleTimelineEvent(sequence: 4, kind: "sceneStable", uptime: 12, scene: "new", isStable: true),
            LifecycleTimelineEvent(sequence: 5, kind: "checkpoint", uptime: 14, scene: "new", isStable: true)
        ]
        if mutation == "missingSeal" { events = Array(events.prefix(2)) }
        let state = try LifecycleTimelineJudge.contentState(
            events, request: mutation == "crossesFade" ? 9 : 1, returned: mutation == "crossesFade" ? 13 : 9)
        if mutation != "stable" {
            #expect(state == nil)
        } else {
            // A wide interval is still conclusive when its entire span has the same stable photo.
            #expect(state?.scene == "old")
        }
    }

    @Test(arguments: [
        "valid", "skippedPhoto", "automaticFade", "automaticCommit", "missingCommit",
        "unpausedStable", "secondNavigation", "secondCommit", "oldTarget", "wrongCommitScene", "wrongStableScene",
        "notStable"
    ])
    func `one paused Next permits one manual transition and then freezes again`(mutation: String) throws {
        var events = [
            LifecycleTimelineEvent(sequence: 1, kind: "timelineStarted", uptime: 0),
            LifecycleTimelineEvent(sequence: 2, kind: "pauseReceived", uptime: 1, scene: "old"),
            LifecycleTimelineEvent(sequence: 3, kind: "manualNavigationReceived", uptime: 2, scene: "old"),
            LifecycleTimelineEvent(
                sequence: 4, kind: "renderFadeStarted", uptime: 2.1, scene: "old", isPaused: true,
                transitionScene: "next", transitionSource: "manualNext"),
            LifecycleTimelineEvent(
                sequence: 5, kind: "sceneCommitted", uptime: 2.2, scene: "next", isPaused: true,
                transitionScene: "next", transitionSource: "manualNext"),
            LifecycleTimelineEvent(
                sequence: 6, kind: "sceneStable", uptime: 2.3, scene: "next", isStable: true, isPaused: true,
                transitionScene: "next", transitionSource: "manualNext")
        ]
        switch mutation {
        case "skippedPhoto":
            events.insert(
                LifecycleTimelineEvent(
                    sequence: 0, kind: "sceneCommitted", uptime: 2.25, scene: "skipped", isPaused: true,
                    transitionScene: "skipped", transitionSource: "manualNext"), at: 5)
        case "automaticFade": events[3].transitionSource = "autoplay"
        case "automaticCommit": events[4].transitionSource = "autoplay"
        case "secondNavigation":
            events.insert(
                LifecycleTimelineEvent(sequence: 0, kind: "manualNavigationReceived", uptime: 2.1, scene: "old"), at: 4)
        case "secondCommit": events.insert(events[4], at: 5)
        case "oldTarget": events[3].transitionScene = "old"
        case "wrongCommitScene": events[4].scene = "other"
        case "wrongStableScene": events[5].scene = "other"
        case "notStable": events[5].isStable = false
        case "missingCommit": events.remove(at: 4)
        case "unpausedStable": events[5].isPaused = false
        default: break
        }
        for index in events.indices { events[index].sequence = index + 1 }
        if mutation == "valid" {
            try LifecycleTimelineJudge.validate(events)
        } else {
            let expected =
                mutation.hasPrefix("automatic")
                ? "automatic change during paused manual navigation" : "paused manual transition exceeded one target"
            do {
                try LifecycleTimelineJudge.validate(events)
                Issue.record("The paused navigation mutation must fail")
            } catch let error as LifecycleTimelineJudge.Failure {
                #expect(error.description == "App timeline: \(expected)")
            }
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
