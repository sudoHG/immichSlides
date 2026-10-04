import XCTest

// Negative controls for the narrow-entry timing/identity criteria: these failures must block false passes and must
// not be produced by changing production code.

final class SettingsResumeContractTests: XCTestCase {
    let initial: [String: Any] = [
        "autoPlayEnabled": true,
        "intervalSeconds": 5,
        "showExif": true,
        "displayMode": "smartFill"
    ]
    let changed: [String: Any] = [
        "autoPlayEnabled": false,
        "intervalSeconds": 12,
        "showExif": false,
        "displayMode": "singlePhoto"
    ]

    func testUnchangedDefaultsAreNotPersistSuccess() {
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertSettingsPersisted(
                before: initial,
                afterRestart: initial
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("Settings were not persisted"))
        }
    }

    func testFourSettingsMustAllDifferFromInitial() {
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertFourSettingsDiffer(
                initial: initial,
                changed: initial
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertFourSettingsDiffer(
                initial: initial,
                changed: [
                    "autoPlayEnabled": false,
                    "intervalSeconds": 5,
                    "showExif": false,
                    "displayMode": "singlePhoto"
                ]
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("intervalSeconds"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertFourSettingsDiffer(initial: initial, changed: changed)
        )
    }

    func testProgressProbeAndForcedSettingsFailClosed() {
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertProgressProbeNotUsed(
                launchEnvironment: [AccessLifecycleContract.scenePresentationProbeKey: "1"]
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("progress probe"))
        }
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertProgressProbeNotUsed(
                launchEnvironment: [AccessLifecycleContract.forbiddenDisplayModeKey: "singlePhoto"]
            )
        )
        XCTAssertNoThrow(try AccessLifecycleContract.assertProgressProbeNotUsed(launchEnvironment: [:]))
    }

    func testOldProgressProbeOrControlValuePauseIsNotPass() {
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertPauseUsesVisibleIdentity(
                pauseMark: "A1",
                afterNextMark: "A2",
                didUseProgressProbe: true,
                didUseControlValueOnly: false
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("progress"))
        }
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertPauseUsesVisibleIdentity(
                pauseMark: "A1",
                afterNextMark: "A2",
                didUseProgressProbe: false,
                didUseControlValueOnly: true
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("control value"))
        }
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertPauseUsesVisibleIdentity(
                pauseMark: "A1",
                afterNextMark: "A1",
                didUseProgressProbe: false,
                didUseControlValueOnly: false
            )
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertPauseUsesVisibleIdentity(
                pauseMark: "A1",
                afterNextMark: "A2",
                didUseProgressProbe: false,
                didUseControlValueOnly: false
            )
        )
    }

    func testPauseHoldShorterThanTPlusTwoOrAdvancingFails() {
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertPausedHoldWithoutAdvance(
                startMark: "A2",
                endMark: "A2",
                holdSeconds: 13,
                intervalSeconds: 12
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertPausedHoldWithoutAdvance(
                startMark: "A2",
                endMark: "A3",
                holdSeconds: 14,
                intervalSeconds: 12
            )
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertPausedHoldWithoutAdvance(
                startMark: "A2",
                endMark: "A2",
                holdSeconds: 14,
                intervalSeconds: 12
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertPausedHoldWithoutAdvance(
                startMark: "A2",
                endMark: "BLACK",
                holdSeconds: 14,
                intervalSeconds: 12
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertHoldSampleUnchanged(expectedMark: "A2", polled: "TRANSITION")
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertHoldSampleUnchanged(expectedMark: "A2", polled: "BLANK")
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertHoldSampleUnchanged(expectedMark: "A2", polled: "A2")
        )
    }

    func testContinueEarlyWindowAndAutoAdvanceWindow() {
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertContinueEarlyStillSameScene(
                continueMark: "A2",
                earlyMark: "A3",
                elapsedSeconds: 4,
                intervalSeconds: 12
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertContinueEarlyStillSameScene(
                continueMark: "A2",
                earlyMark: "A2",
                elapsedSeconds: 9,
                intervalSeconds: 12
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("test timing failure"))
        }
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertContinueEarlyStillSameScene(
                continueMark: "A2",
                earlyMark: "A2",
                elapsedSeconds: 7,
                intervalSeconds: 12
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("test timing failure"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertContinueEarlyStillSameScene(
                continueMark: "A2",
                earlyMark: "A2",
                elapsedSeconds: 5,
                intervalSeconds: 12
            )
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertContinueEarlyStillSameScene(
                continueMark: "A2",
                earlyMark: "A2",
                elapsedSeconds: 6,
                intervalSeconds: 12
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertContinueEarlyStillSameScene(
                continueMark: "A1",
                earlyMark: "A1",
                elapsedSeconds: 6.44,
                intervalSeconds: 10
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("test timing failure"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertContinueEarlyStillSameScene(
                continueMark: "A1",
                earlyMark: "A1",
                elapsedSeconds: 0.8,
                intervalSeconds: 10
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertContinueAutoAdvanceInWindow(
                continueMark: "A2",
                laterMark: "A3",
                elapsedSeconds: 8,
                intervalSeconds: 12
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertContinueAutoAdvanceInWindow(
                continueMark: "A2",
                laterMark: "A2",
                elapsedSeconds: 12,
                intervalSeconds: 12
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertContinueAutoAdvanceInWindow(
                continueMark: "A2",
                laterMark: "A3",
                elapsedSeconds: 16,
                intervalSeconds: 12
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("test timing failure"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertContinueAutoAdvanceInWindow(
                continueMark: "A2",
                laterMark: "A3",
                elapsedSeconds: 12,
                intervalSeconds: 12
            )
        )
    }

    func testBackgroundWaitAndIdentityNegatives() {
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertBackgroundWaitExceedsInterval(
                waitSeconds: 12,
                intervalSeconds: 12
            )
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertBackgroundWaitExceedsInterval(
                waitSeconds: 14,
                intervalSeconds: 12
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertBackgroundDidNotJump(before: "A4", after: "A5")
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertBackgroundDidNotJump(before: "A4", after: "A4")
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertSystemPauseActivation(
                activation: "open_new_process",
                didRebuildProcess: false,
                didHomeLeaveAppRunning: true
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertSystemPauseActivation(
                activation: AccessLifecycleContract.allowedSystemPauseActivation,
                didRebuildProcess: true,
                didHomeLeaveAppRunning: false
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertSystemPauseIdentityTiming(
                screenshotOrder: ["before-background", "hidden-control-wake-1", "after-background"]
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertSameProcess(beforeIdentifier: 12, afterIdentifier: 99)
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertSameProcess(beforeIdentifier: 12, afterIdentifier: 12)
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertBackgroundIdentityIsFirstSegment(
                secondsBeforeIdentity: 12,
                intervalSeconds: 12
            )
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertBackgroundIdentityIsFirstSegment(
                secondsBeforeIdentity: 1.2,
                intervalSeconds: 10
            )
        )
    }

    func testHandwrittenSettingsAndPinUnlockAreNotPersistSuccess() {
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertNarrowSettingsPersist(
                initial: initial,
                changed: initial,
                afterRestart: initial
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertNarrowSettingsPersist(
                initial: initial,
                changed: changed,
                afterRestart: initial
            )
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertNarrowSettingsPersist(
                initial: initial,
                changed: changed,
                afterRestart: changed
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertNarrowPathDidNotUnlockPin(didEnterPin: true)
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertNarrowPathDidNotUnlockPin(didEnterPin: false)
        )
    }

    func testContinuousFirstAdvanceMustNotOnlySampleNearT() throws {
        let stayedThenAdvanced: [(elapsed: TimeInterval, mark: String)] = [
            (5.0, "A2"),
            (9.5, "A2"),
            (12.0, "A3")
        ]
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertSamplesStayOnSceneBeforeAdvanceWindow(
                continueMark: "A2",
                samples: stayedThenAdvanced,
                intervalSeconds: 12
            )
        )
        let firstStay = AccessLifecycleContract.firstUsableAdvance(
            continueMark: "A2",
            samples: stayedThenAdvanced
        )
        XCTAssertEqual(firstStay?.elapsed, 12)
        XCTAssertEqual(firstStay?.mark, "A3")
        try AccessLifecycleContract.assertContinueAutoAdvanceInWindow(
            continueMark: "A2",
            laterMark: firstStay!.mark,
            elapsedSeconds: firstStay!.elapsed,
            intervalSeconds: 12
        )

        let jumpedEarly: [(elapsed: TimeInterval, mark: String)] = [
            (7.0, "A3"),
            (12.0, "A3")
        ]
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertSamplesStayOnSceneBeforeAdvanceWindow(
                continueMark: "A2",
                samples: jumpedEarly,
                intervalSeconds: 12
            )
        )
        let firstEarly = AccessLifecycleContract.firstUsableAdvance(
            continueMark: "A2",
            samples: jumpedEarly
        )
        XCTAssertEqual(firstEarly?.elapsed, 7)
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertContinueAutoAdvanceInWindow(
                continueMark: "A2",
                laterMark: firstEarly!.mark,
                elapsedSeconds: firstEarly!.elapsed,
                intervalSeconds: 12
            )
        )
    }

    func testIOSSliderReadbackSixteenIsNotTwelve() {
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertIOSIntervalReachedRequested(observed: 16)
        ) { error in
            XCTAssertTrue(String(describing: error).contains("12"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertIOSIntervalReachedRequested(observed: 12)
        )
    }

    func testTVOSIntervalSearchRequiresPlaybackSettingsPage() {
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertTVOSPlaybackSettingsEntered(
                isAutoPlayLinkFocused: false,
                isHomePlaybackFocused: true
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("playback settings"))
        }
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertTVOSPlaybackSettingsEntered(
                isAutoPlayLinkFocused: false,
                isHomePlaybackFocused: false
            )
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertTVOSPlaybackSettingsEntered(
                isAutoPlayLinkFocused: true,
                isHomePlaybackFocused: false
            )
        )
    }

    func testMissingPlayPauseControlIsNotPausedAndMustNotRetap() {
        XCTAssertEqual(
            AccessLifecycleContract.playPauseControlValue(isPresent: false, rawValue: "play"),
            ""
        )
        XCTAssertEqual(
            AccessLifecycleContract.playPauseControlValue(isPresent: true, rawValue: "Play"),
            "play"
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertMissingPlayPauseIsNotPaused(
                isPresent: false,
                isInferredPaused: true
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("Missing controls"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertMissingPlayPauseIsNotPaused(
                isPresent: false,
                isInferredPaused: false
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertPlayPauseNotRetappedBecauseMissing(
                didAlreadyTap: true,
                didRetapBecauseMissing: true
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("tap again"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertPlayPauseNotRetappedBecauseMissing(
                didAlreadyTap: true,
                didRetapBecauseMissing: false
            )
        )
    }

    func testSettingsExistsIsNotPlaybackControlsRevealed() {
        XCTAssertFalse(
            AccessLifecycleContract.isPlaybackControlBarRevealed(isPlayPauseHittable: false)
        )
        XCTAssertTrue(
            AccessLifecycleContract.isPlaybackControlBarRevealed(isPlayPauseHittable: true)
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertPlaybackControlsRevealedByTarget(
                isPlayPauseHittable: false,
                isSettingsPresent: true,
                isTreatedAsRevealed: true
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("play/pause"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertPlaybackControlsRevealedByTarget(
                isPlayPauseHittable: true,
                isSettingsPresent: true,
                isTreatedAsRevealed: true
            )
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertPlaybackControlsRevealedByTarget(
                isPlayPauseHittable: false,
                isSettingsPresent: true,
                isTreatedAsRevealed: false
            )
        )
    }

    func testPlaybackPageArrivalMustNotRequireHittable() {
        XCTAssertTrue(
            AccessLifecycleContract.hasPlaybackPageArrived(
                isSettingsPresent: true,
                isNextPresent: false,
                isPlayPausePresent: false,
                isHintPresent: false
            )
        )
        XCTAssertTrue(
            AccessLifecycleContract.hasPlaybackPageArrived(
                isSettingsPresent: false,
                isNextPresent: false,
                isPlayPausePresent: false,
                isHintPresent: true
            )
        )
        XCTAssertFalse(
            AccessLifecycleContract.hasPlaybackPageArrived(
                isSettingsPresent: false,
                isNextPresent: false,
                isPlayPausePresent: false,
                isHintPresent: false
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertPlaybackPageArrivalIgnoresTemporaryUnhittable(
                isPresentOnPlaybackPage: true,
                isTreatedAsArrived: false
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("temporarily unhittable"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertPlaybackPageArrivalIgnoresTemporaryUnhittable(
                isPresentOnPlaybackPage: true,
                isTreatedAsArrived: true
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertPlaybackPageArrivalIgnoresTemporaryUnhittable(
                isPresentOnPlaybackPage: false,
                isTreatedAsArrived: true
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("before the playback page is reached"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertPlaybackPageArrivalIgnoresTemporaryUnhittable(
                isPresentOnPlaybackPage: false,
                isTreatedAsArrived: false
            )
        )
    }

    func testEnterPlaybackWaitMustNotTapOrUsePrivateQuiescence() {
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertEnterPlaybackWaitDoesNotTapOrBypassQuiescence(
                didTapCanvas: true,
                didTapHint: false,
                didUsePrivateQuiescenceBypass: false
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("tap the canvas or hint"))
        }
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertEnterPlaybackWaitDoesNotTapOrBypassQuiescence(
                didTapCanvas: false,
                didTapHint: true,
                didUsePrivateQuiescenceBypass: false
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("tap the canvas or hint"))
        }
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertEnterPlaybackWaitDoesNotTapOrBypassQuiescence(
                didTapCanvas: false,
                didTapHint: false,
                didUsePrivateQuiescenceBypass: true
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("private wait"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertEnterPlaybackWaitDoesNotTapOrBypassQuiescence(
                didTapCanvas: false,
                didTapHint: false,
                didUsePrivateQuiescenceBypass: false
            )
        )
    }

    func testConfirmPlayPauseMustWakeCanvasEvenIfHittable() {
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertConfirmPlayPauseWakesCanvasBeforeWait(
                didWakeCanvas: false,
                didTapPlayPauseToWake: false
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("Tap the canvas"))
        }
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertConfirmPlayPauseWakesCanvasBeforeWait(
                didWakeCanvas: true,
                didTapPlayPauseToWake: true
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("tap again"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertConfirmPlayPauseWakesCanvasBeforeWait(
                didWakeCanvas: true,
                didTapPlayPauseToWake: false
            )
        )
    }

    func testContinueClockMustNotStartAfterConfirmWait() {
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertContinueClockStartsAtPress(
                confirmWaitSecondsBeforeClock: 4
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("continueAt"))
        }
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertContinueClockStartsAtPress(
                confirmWaitSecondsBeforeClock: 3
            )
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertContinueClockStartsAtPress(
                confirmWaitSecondsBeforeClock: 0
            )
        )
    }

    func testTVOSPlaybackPageWithNoFocusIsNotHome() {
        XCTAssertEqual(
            AccessLifecycleContract.tvosSettingsPageIdentity(
                isPlaybackSettingsContentVisible: true,
                isHomeEntryVisible: true,
                isHomeUniqueVisible: true
            ),
            "home"
        )
        XCTAssertEqual(
            AccessLifecycleContract.tvosSettingsPageIdentity(
                isPlaybackSettingsContentVisible: true,
                isHomeEntryVisible: false
            ),
            "playback"
        )
        XCTAssertEqual(
            AccessLifecycleContract.tvosSettingsPageIdentity(
                isPlaybackSettingsContentVisible: false,
                isHomeEntryVisible: true
            ),
            "home"
        )
        XCTAssertEqual(
            AccessLifecycleContract.tvosSettingsPageIdentity(
                isPlaybackSettingsContentVisible: false,
                isHomeEntryVisible: false
            ),
            "unknown"
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertTVOSPageIdentityNotInferredFromMissingFocus(
                isPlaybackSettingsContentVisible: true,
                isClassifiedAsHome: true
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("settings home"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertTVOSPageIdentityNotInferredFromMissingFocus(
                isPlaybackSettingsContentVisible: true,
                isClassifiedAsHome: false
            )
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertTVOSPlaybackSettingsEntered(
                isAutoPlayLinkFocused: true,
                isHomePlaybackFocused: false
            )
        )
    }

    func testTVOSTwelveSecondsIsNotSilentlySubstituted() throws {
        let exact = try AccessLifecycleContract.resolveTimingInterval(
            requested: 12,
            available: [5, 8, 10, 12, 15, 30]
        )
        XCTAssertEqual(exact.actual, 12)
        XCTAssertFalse(exact.shouldRequireIntervalReview)
        let tv = try AccessLifecycleContract.resolveTimingInterval(
            requested: 12,
            available: AccessLifecycleContract.tvOSSelectableIntervals
        )
        XCTAssertEqual(tv.actual, 10)
        XCTAssertTrue(tv.shouldRequireIntervalReview)
        XCTAssertFalse(AccessLifecycleContract.tvOSSelectableIntervals.contains(12))
    }
}
