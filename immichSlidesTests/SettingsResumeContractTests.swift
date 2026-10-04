import XCTest

// Negative controls for the narrow-entry timing/identity criteria: these failures must block false passes and must
// not be produced by changing production code.

final class SettingsResumeContractTests: XCTestCase {
    private let initial: [String: Any] = [
        "autoPlayEnabled": true,
        "intervalSeconds": 5,
        "showExif": true,
        "displayMode": "smartFill"
    ]
    private let changed: [String: Any] = [
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
                usedProgressProbe: true,
                usedControlValueOnly: false
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("progress"))
        }
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertPauseUsesVisibleIdentity(
                pauseMark: "A1",
                afterNextMark: "A2",
                usedProgressProbe: false,
                usedControlValueOnly: true
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("control value"))
        }
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertPauseUsesVisibleIdentity(
                pauseMark: "A1",
                afterNextMark: "A1",
                usedProgressProbe: false,
                usedControlValueOnly: false
            )
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertPauseUsesVisibleIdentity(
                pauseMark: "A1",
                afterNextMark: "A2",
                usedProgressProbe: false,
                usedControlValueOnly: false
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
                processRebuilt: false,
                homeLeftAppRunning: true
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertSystemPauseActivation(
                activation: AccessLifecycleContract.allowedSystemPauseActivation,
                processRebuilt: true,
                homeLeftAppRunning: false
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
                autoPlayLinkFocused: false,
                homePlaybackFocused: true
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("playback settings"))
        }
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertTVOSPlaybackSettingsEntered(
                autoPlayLinkFocused: false,
                homePlaybackFocused: false
            )
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertTVOSPlaybackSettingsEntered(
                autoPlayLinkFocused: true,
                homePlaybackFocused: false
            )
        )
    }

    func testMissingPlayPauseControlIsNotPausedAndMustNotRetap() {
        XCTAssertEqual(
            AccessLifecycleContract.playPauseControlValue(exists: false, rawValue: "play"),
            ""
        )
        XCTAssertEqual(
            AccessLifecycleContract.playPauseControlValue(exists: true, rawValue: "Play"),
            "play"
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertMissingPlayPauseIsNotPaused(
                exists: false,
                inferredPaused: true
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("Missing controls"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertMissingPlayPauseIsNotPaused(
                exists: false,
                inferredPaused: false
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertPlayPauseNotRetappedBecauseMissing(
                alreadyTapped: true,
                retappedBecauseMissing: true
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("tap again"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertPlayPauseNotRetappedBecauseMissing(
                alreadyTapped: true,
                retappedBecauseMissing: false
            )
        )
    }

    func testSettingsExistsIsNotPlaybackControlsRevealed() {
        XCTAssertFalse(
            AccessLifecycleContract.playbackControlsAreRevealed(playPauseHittable: false)
        )
        XCTAssertTrue(
            AccessLifecycleContract.playbackControlsAreRevealed(playPauseHittable: true)
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertPlaybackControlsRevealedByTarget(
                playPauseHittable: false,
                settingsExists: true,
                treatedAsRevealed: true
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("play/pause"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertPlaybackControlsRevealedByTarget(
                playPauseHittable: true,
                settingsExists: true,
                treatedAsRevealed: true
            )
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertPlaybackControlsRevealedByTarget(
                playPauseHittable: false,
                settingsExists: true,
                treatedAsRevealed: false
            )
        )
    }

    func testPlaybackPageArrivalMustNotRequireHittable() {
        XCTAssertTrue(
            AccessLifecycleContract.playbackPageHasArrived(
                settingsExists: true,
                nextExists: false,
                playPauseExists: false,
                hintExists: false
            )
        )
        XCTAssertTrue(
            AccessLifecycleContract.playbackPageHasArrived(
                settingsExists: false,
                nextExists: false,
                playPauseExists: false,
                hintExists: true
            )
        )
        XCTAssertFalse(
            AccessLifecycleContract.playbackPageHasArrived(
                settingsExists: false,
                nextExists: false,
                playPauseExists: false,
                hintExists: false
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertPlaybackPageArrivalIgnoresTemporaryUnhittable(
                existsOnPlaybackPage: true,
                treatedAsArrived: false
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("temporarily unhittable"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertPlaybackPageArrivalIgnoresTemporaryUnhittable(
                existsOnPlaybackPage: true,
                treatedAsArrived: true
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertPlaybackPageArrivalIgnoresTemporaryUnhittable(
                existsOnPlaybackPage: false,
                treatedAsArrived: true
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("before the playback page is reached"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertPlaybackPageArrivalIgnoresTemporaryUnhittable(
                existsOnPlaybackPage: false,
                treatedAsArrived: false
            )
        )
    }

    func testEnterPlaybackWaitMustNotTapOrUsePrivateQuiescence() {
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertEnterPlaybackWaitDoesNotTapOrBypassQuiescence(
                tappedCanvas: true,
                tappedHint: false,
                usedPrivateQuiescenceBypass: false
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("tap the canvas or hint"))
        }
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertEnterPlaybackWaitDoesNotTapOrBypassQuiescence(
                tappedCanvas: false,
                tappedHint: true,
                usedPrivateQuiescenceBypass: false
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("tap the canvas or hint"))
        }
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertEnterPlaybackWaitDoesNotTapOrBypassQuiescence(
                tappedCanvas: false,
                tappedHint: false,
                usedPrivateQuiescenceBypass: true
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("private wait"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertEnterPlaybackWaitDoesNotTapOrBypassQuiescence(
                tappedCanvas: false,
                tappedHint: false,
                usedPrivateQuiescenceBypass: false
            )
        )
    }

    func testConfirmPlayPauseMustWakeCanvasEvenIfHittable() {
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertConfirmPlayPauseWakesCanvasBeforeWait(
                wokeCanvas: false,
                tappedPlayPauseToWake: false
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("Tap the canvas"))
        }
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertConfirmPlayPauseWakesCanvasBeforeWait(
                wokeCanvas: true,
                tappedPlayPauseToWake: true
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("tap again"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertConfirmPlayPauseWakesCanvasBeforeWait(
                wokeCanvas: true,
                tappedPlayPauseToWake: false
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
                playbackSettingsContentVisible: true,
                homeEntryVisible: true,
                homeUniqueVisible: true
            ),
            "home"
        )
        XCTAssertEqual(
            AccessLifecycleContract.tvosSettingsPageIdentity(
                playbackSettingsContentVisible: true,
                homeEntryVisible: false
            ),
            "playback"
        )
        XCTAssertEqual(
            AccessLifecycleContract.tvosSettingsPageIdentity(
                playbackSettingsContentVisible: false,
                homeEntryVisible: true
            ),
            "home"
        )
        XCTAssertEqual(
            AccessLifecycleContract.tvosSettingsPageIdentity(
                playbackSettingsContentVisible: false,
                homeEntryVisible: false
            ),
            "unknown"
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertTVOSPageIdentityNotInferredFromMissingFocus(
                playbackSettingsContentVisible: true,
                classifiedAsHome: true
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("settings home"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertTVOSPageIdentityNotInferredFromMissingFocus(
                playbackSettingsContentVisible: true,
                classifiedAsHome: false
            )
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertTVOSPlaybackSettingsEntered(
                autoPlayLinkFocused: true,
                homePlaybackFocused: false
            )
        )
    }

    func testTVOSTwelveSecondsIsNotSilentlySubstituted() throws {
        let exact = try AccessLifecycleContract.resolveTimingInterval(
            requested: 12,
            available: [5, 8, 10, 12, 15, 30]
        )
        XCTAssertEqual(exact.actual, 12)
        XCTAssertFalse(exact.desktopCloseoutRequired)
        let tv = try AccessLifecycleContract.resolveTimingInterval(
            requested: 12,
            available: AccessLifecycleContract.tvOSSelectableIntervals
        )
        XCTAssertEqual(tv.actual, 10)
        XCTAssertTrue(tv.desktopCloseoutRequired)
        XCTAssertFalse(AccessLifecycleContract.tvOSSelectableIntervals.contains(12))
    }

    func testFirstTransitionStartRejectsEarlyLateBlackAndCrossWindow() {
        let early = [
            watchSample(request: 5.0, mark: "A2"),
            watchSample(request: 8.0, mark: "A3")
        ]
        XCTAssertEqual(
            AccessLifecycleContract.assessFirstTransitionStart(
                continueMark: "A2",
                baselineLuma: 0.5,
                samples: early,
                intervalSeconds: 12
            ),
            .tooEarly(requestElapsed: 8.0, mark: "A3")
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.officialStartSigned(
                for: .tooEarly(requestElapsed: 8.0, mark: "A3"),
                continueMark: "A2",
                intervalSeconds: 12
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("before T-2"))
        }

        let late = [
            watchSample(request: 5.0, mark: "A2"),
            watchSample(request: 11.0, mark: "A2"),
            watchSample(request: 16.0, mark: "A3")
        ]
        XCTAssertEqual(
            AccessLifecycleContract.assessFirstTransitionStart(
                continueMark: "A2",
                baselineLuma: 0.5,
                samples: late,
                intervalSeconds: 12
            ),
            .tooLate(requestElapsed: 16.0, mark: "A3")
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.officialStartSigned(
                for: .tooLate(requestElapsed: 16.0, mark: "A3"),
                continueMark: "A2",
                intervalSeconds: 12
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("test timing failure"))
        }

        XCTAssertThrowsError(
            try AccessLifecycleContract.assertIdentifiableNewImagePresent(
                continueMark: "A2",
                confirmedMark: nil,
                confirmedStatus: nil
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("Black screen without a new photo"))
        }
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertIdentifiableNewImagePresent(
                continueMark: "A2",
                confirmedMark: "BLACK",
                confirmedStatus: "BLACK"
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("Black screen without a new photo"))
        }
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertWindowUsesRequestElapsed(
                requestElapsed: 13.0,
                returnElapsed: 14.5,
                classifiedElapsed: 14.8,
                elapsedUsedForWindow: 14.5
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("Evidence crossing the window"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertWindowUsesRequestElapsed(
                requestElapsed: 13.0,
                returnElapsed: 14.5,
                classifiedElapsed: 14.8,
                elapsedUsedForWindow: 13.0
            )
        )
    }

    func testUncertainStartCannotDefaultOfficialPass() throws {
        let uncertainThenLate = [
            watchSample(request: 5.0, mark: "A5", luma: 0.55),
            watchSample(request: 12.9, mark: "A5", luma: 0.40),
            watchSample(request: 14.4, mark: "A1", luma: 0.42)
        ]
        let verdict = AccessLifecycleContract.assessFirstTransitionStart(
            continueMark: "A5",
            baselineLuma: 0.55,
            samples: uncertainThenLate,
            intervalSeconds: 12
        )
        guard case .pendingVideoReview = verdict else {
            return XCTFail(
                "After a luma drop in the window, a new image outside the window must await video review, not be judged tooLate or auto-passed"
            )
        }
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertFirstTransitionStartOfficialPass(
                verdict: verdict,
                officialSigned: true
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("pending video review"))
        }
        XCTAssertFalse(
            try AccessLifecycleContract.officialStartSigned(
                for: verdict,
                continueMark: "A5",
                intervalSeconds: 12
            )
        )
    }

    func testNewImageConfirmationIsSeparateFromStartAndMayFollowWindow() throws {
        let mixThenZoomedNew = [
            watchSample(request: 5.0, mark: "A5", status: "MATCH"),
            watchSample(request: 12.9, mark: "TRANSITION", status: "TRANSITION", luma: 0.28),
            watchSample(request: 14.7, mark: "A1", status: "MATCH", luma: 0.41)
        ]
        let start = AccessLifecycleContract.assessFirstTransitionStart(
            continueMark: "A5",
            baselineLuma: 0.5,
            samples: mixThenZoomedNew,
            intervalSeconds: 12
        )
        XCTAssertEqual(
            start,
            .detected(requestElapsed: 12.9, mark: "TRANSITION", status: "TRANSITION")
        )
        XCTAssertTrue(
            try AccessLifecycleContract.officialStartSigned(
                for: start,
                continueMark: "A5",
                intervalSeconds: 12
            )
        )
        let confirmed = AccessLifecycleContract.firstIdentifiableNewImage(
            continueMark: "A5",
            samples: mixThenZoomedNew
        )
        XCTAssertEqual(confirmed?.requestElapsed, 14.7)
        XCTAssertEqual(confirmed?.mark, "A1")
        try AccessLifecycleContract.assertIdentifiableNewImagePresent(
            continueMark: "A5",
            confirmedMark: confirmed?.mark,
            confirmedStatus: confirmed?.status
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertContinueEarlyStillSameScene(
                continueMark: "A5",
                earlyMark: "A5",
                elapsedSeconds: 5.0,
                intervalSeconds: 12
            )
        )
    }

    func testStableConfirmationRejectsDarkMisclassificationAndWaitsForBrightSequence() {
        var samples = [watchSample(request: 13.8, mark: "A2", luma: 0.065, returnLag: 0.1)]
        XCTAssertNil(AccessLifecycleContract.firstStableNewImage(continueMark: "A5", samples: samples))
        samples.append(watchSample(request: 14.1, mark: "A1", luma: 0.4, returnLag: 0.1))
        samples.append(watchSample(request: 14.3, mark: "A1", luma: 0.4, returnLag: 0.1))
        XCTAssertNil(AccessLifecycleContract.firstStableNewImage(continueMark: "A5", samples: samples))
        for time in [14.5, 14.7, 14.9, 15.1] {
            samples.append(watchSample(request: time, mark: "A1", luma: 0.4, returnLag: 0.1))
        }
        XCTAssertEqual(AccessLifecycleContract.firstStableNewImage(continueMark: "A5", samples: samples)?.mark, "A1")
    }

    func testStableConfirmationRestartsOnUnknownDifferentAndDarkFrames() {
        for interruption in [
            watchSample(request: 14.5, mark: "A2", returnLag: 0.1),
            watchSample(request: 14.5, mark: "UNRECOGNIZABLE", status: "UNRECOGNIZABLE", returnLag: 0.1),
            watchSample(request: 14.5, mark: "A1", luma: 0.05, returnLag: 0.1)
        ] {
            let samples =
                [14.1, 14.3].map { watchSample(request: $0, mark: "A1", returnLag: 0.1) }
                + [interruption]
                + [14.7, 14.9, 15.1].map { watchSample(request: $0, mark: "A1", returnLag: 0.1) }
            XCTAssertNil(AccessLifecycleContract.firstStableNewImage(continueMark: "A5", samples: samples))
            let uninterrupted = [14.1, 14.3, 14.5, 14.7, 14.9, 15.1].map {
                watchSample(request: $0, mark: "A1", returnLag: 0.1)
            }
            XCTAssertNotNil(AccessLifecycleContract.firstStableNewImage(continueMark: "A5", samples: uninterrupted))
        }
    }

    func testStableConfirmationRejectsSamplingGapsAndInvalidTimes() {
        for samples in [
            [watchSample(request: 14, mark: "A1"), watchSample(request: 17, mark: "A1")],
            [watchSample(request: 14, mark: "A1", returnLag: 0.1), watchSample(request: 14.9, mark: "A1")],
            [watchSample(request: 14, mark: "A1"), watchSample(request: 14.1, mark: "A1")],
            [watchSample(request: .nan, mark: "A1")]
        ] {
            XCTAssertNil(AccessLifecycleContract.firstStableNewImage(continueMark: "A5", samples: samples))
        }
    }

    func testIPadPauseRequiresConservativeTransitionWindowAndOneSecondStableImage() throws {
        let samples =
            [
                watchSample(request: 10.1, mark: "A5", returnLag: 0.05, classifyLag: 0.1),
                watchSample(request: 10.2, mark: "TRANSITION", status: "TRANSITION", returnLag: 0.05, classifyLag: 0.1)
            ]
            + (0...8).map { index in
                watchSample(request: 10.3 + Double(index) * 0.15, mark: "A1", returnLag: 0.1, classifyLag: 0.1)
            }

        let evidence = try AccessLifecycleContract.assertIPadPauseTimingEvidence(
            continueMark: "A5",
            baselineLuma: 0.5,
            samples: samples,
            intervalSeconds: 12
        )

        XCTAssertEqual(evidence.earliestTransitionElapsed, 10.1, accuracy: 0.001)
        XCTAssertEqual(evidence.latestTransitionElapsed, 10.25, accuracy: 0.001)
        XCTAssertEqual(evidence.stableImageRequestElapsed, 11.5, accuracy: 0.001)
        XCTAssertEqual(evidence.stableImageReturnElapsed, 11.6, accuracy: 0.001)
        XCTAssertEqual(evidence.stableImageDelaySeconds, 1.4, accuracy: 0.001)
        XCTAssertLessThanOrEqual(evidence.stableImageDelaySeconds, 4.0)
    }

    func testIPadPauseReplaysSustainedFadeAndIgnoresSmallLumaNoise() throws {
        let oldFrames = [
            watchSample(request: 8.249, mark: "A5", luma: 0.5343, returnLag: 0.18),
            watchSample(request: 8.445, mark: "A5", luma: 0.5319, returnLag: 0.18),
            watchSample(request: 8.636, mark: "A5", luma: 0.5306, returnLag: 0.18),
            watchSample(request: 8.830, mark: "A5", luma: 0.5307, returnLag: 0.18),
            watchSample(request: 9.036, mark: "A5", luma: 0.5307, returnLag: 0.18),
            watchSample(request: 9.228, mark: "A5", luma: 0.5307, returnLag: 0.18),
            watchSample(request: 9.419, mark: "A5", luma: 0.5307, returnLag: 0.18),
            watchSample(request: 9.608, mark: "A5", luma: 0.5308, returnLag: 0.18),
            watchSample(request: 9.798, mark: "A5", luma: 0.5309, returnLag: 0.18),
            watchSample(request: 9.987, mark: "A5", luma: 0.5310, returnLag: 0.18),
            watchSample(request: 10.175, mark: "A5", luma: 0.5310, returnLag: 0.18),
            watchSample(request: 10.364, mark: "A5", luma: 0.5310, returnLag: 0.18)
        ]
        let fadeFrames = [
            watchSample(request: 10.551, mark: "A5", luma: 0.49, returnLag: 0.18),
            watchSample(request: 10.739, mark: "A5", luma: 0.35, returnLag: 0.18),
            watchSample(request: 10.930, mark: "A5", luma: 0.16, returnLag: 0.18),
            watchSample(request: 11.118, mark: "UNRECOGNIZABLE", status: "UNRECOGNIZABLE", luma: 0.02, returnLag: 0.18)
        ]
        let stableFrames = (0...10).map { index in
            watchSample(request: 11.333 + Double(index) * 0.2, mark: "A1", luma: 0.47, returnLag: 0.18)
        }
        let samples = oldFrames + fadeFrames + stableFrames
        let evidence = try AccessLifecycleContract.assertIPadPauseTimingEvidence(
            continueMark: "A5",
            baselineLuma: 0.535,
            samples: samples,
            intervalSeconds: 12
        )

        XCTAssertEqual(evidence.transitionStartRequestElapsed, 10.551, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(evidence.earliestTransitionElapsed, 10)
        XCTAssertLessThanOrEqual(evidence.latestTransitionElapsed, 14)
        XCTAssertLessThanOrEqual(evidence.stableImageDelaySeconds, 4)
    }

    func testIPadPauseRejectsRecoveredDimFrameDimOnlyAndControlBarOnlyChange() {
        let recoveredDim = [
            watchSample(request: 10.1, mark: "A5", luma: 0.53, returnLag: 0.05),
            watchSample(request: 10.2, mark: "A5", luma: 0.49, returnLag: 0.05),
            watchSample(request: 10.3, mark: "A5", luma: 0.53, returnLag: 0.05),
            watchSample(request: 10.4, mark: "A5", luma: 0.53, returnLag: 0.05)
        ]
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertIPadPauseTimingEvidence(
                continueMark: "A5", baselineLuma: 0.53, samples: recoveredDim, intervalSeconds: 12
            )
        )

        let dimOnly = [
            watchSample(request: 10.1, mark: "A5", luma: 0.53, returnLag: 0.05),
            watchSample(request: 10.2, mark: "A5", luma: 0.49, returnLag: 0.05),
            watchSample(request: 10.3, mark: "A5", luma: 0.35, returnLag: 0.05),
            watchSample(request: 10.4, mark: "A5", luma: 0.16, returnLag: 0.05),
            watchSample(request: 10.5, mark: "BLACK", status: "BLACK", luma: 0.01, returnLag: 0.05)
        ]
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertIPadPauseTimingEvidence(
                continueMark: "A5", baselineLuma: 0.53, samples: dimOnly, intervalSeconds: 12
            )
        )

        let controlsPrefix: [AccessLifecycleContract.ContinueWatchSample] = (0...40).map { index in
            let luma: Double
            switch index {
            case ..<22: luma = 0.53
            case 22: luma = 0.49
            case 23: luma = 0.35
            case 40: luma = 0.47
            default: luma = 0.16
            }
            return watchSample(
                request: 10.1 + Double(index) * 0.1,
                mark: index == 40 ? "A1" : "A5",
                luma: luma,
                controlBar: index < 22,
                returnLag: 0.05
            )
        }
        let latePhotoFrames: [AccessLifecycleContract.ContinueWatchSample] = (1...12).map { index in
            watchSample(request: 14.1 + Double(index) * 0.1, mark: "A1", luma: 0.47, controlBar: false, returnLag: 0.05)
        }
        let controlsOnly = controlsPrefix + latePhotoFrames
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertIPadPauseTimingEvidence(
                continueMark: "A5", baselineLuma: 0.53, samples: controlsOnly, intervalSeconds: 12
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("reliable screenshot of the previous photo"))
        }
    }

    func testIPadPauseRejectsEarlyOrLateConservativeTransitionBounds() {
        let stableFrames = (0...8).map { index in
            watchSample(request: 10.1 + Double(index) * 0.15, mark: "A1", returnLag: 0.05, classifyLag: 0.1)
        }
        let early =
            [
                watchSample(request: 9.9, mark: "A5", returnLag: 0.05, classifyLag: 0.1),
                watchSample(request: 10.0, mark: "TRANSITION", status: "TRANSITION", returnLag: 0.05, classifyLag: 0.1)
            ] + stableFrames
        let late =
            [
                watchSample(request: 13.8, mark: "A5", returnLag: 0.05, classifyLag: 0.1),
                watchSample(request: 13.95, mark: "TRANSITION", status: "TRANSITION", returnLag: 0.1, classifyLag: 0.1)
            ]
            + (0...8).map { index in
                watchSample(request: 14.1 + Double(index) * 0.15, mark: "A1", returnLag: 0.05, classifyLag: 0.1)
            }

        for samples in [early, late] {
            XCTAssertThrowsError(
                try AccessLifecycleContract.assertIPadPauseTimingEvidence(
                    continueMark: "A5", baselineLuma: 0.5, samples: samples, intervalSeconds: 12
                )
            )
        }
    }

    func testIPadPauseIncludesPressLatencyInConservativeLowerBound() {
        let samples =
            [
                watchSample(request: 10.1, mark: "A5", returnLag: 0.05),
                watchSample(request: 10.2, mark: "TRANSITION", status: "TRANSITION", returnLag: 0.05)
            ]
            + (0...8).map { index in
                watchSample(request: 10.3 + Double(index) * 0.15, mark: "A1", returnLag: 0.05)
            }

        XCTAssertThrowsError(
            try AccessLifecycleContract.assertIPadPauseTimingEvidence(
                continueMark: "A5",
                baselineLuma: 0.5,
                samples: samples,
                intervalSeconds: 12,
                pressReturnedElapsed: 0.2
            )
        )
    }

    func testIPadPauseRejectsUncertainOrMissingTransitionAndInsufficientStableFrames() {
        let unknownBeforeStart =
            [
                watchSample(request: 10.1, mark: "A5", returnLag: 0.05, classifyLag: 0.1),
                watchSample(
                    request: 10.2, mark: "UNRECOGNIZABLE", status: "UNRECOGNIZABLE", returnLag: 0.05, classifyLag: 0.1),
                watchSample(request: 10.3, mark: "TRANSITION", status: "TRANSITION", returnLag: 0.05, classifyLag: 0.1)
            ]
            + (0...8).map { index in
                watchSample(request: 10.4 + Double(index) * 0.15, mark: "A1", returnLag: 0.05, classifyLag: 0.1)
            }
        let insufficientStableFrames =
            [
                watchSample(request: 10.1, mark: "A5", returnLag: 0.05, classifyLag: 0.1),
                watchSample(request: 10.2, mark: "TRANSITION", status: "TRANSITION", returnLag: 0.05, classifyLag: 0.1)
            ]
            + (0...5).map { index in
                watchSample(request: 10.3 + Double(index) * 0.15, mark: "A1", returnLag: 0.05, classifyLag: 0.1)
            }
        let missingStart = [watchSample(request: 10.1, mark: "A5", returnLag: 0.05, classifyLag: 0.1)]

        for samples in [unknownBeforeStart, insufficientStableFrames, missingStart] {
            XCTAssertThrowsError(
                try AccessLifecycleContract.assertIPadPauseTimingEvidence(
                    continueMark: "A5", baselineLuma: 0.5, samples: samples, intervalSeconds: 12
                )
            )
        }
    }

    func testIPadPauseRejectsStableImageMoreThanFourSecondsAfterTransitionStart() {
        let samples =
            [
                watchSample(request: 10.1, mark: "A5", returnLag: 0.05, classifyLag: 0.1),
                watchSample(request: 10.2, mark: "TRANSITION", status: "TRANSITION", returnLag: 0.05, classifyLag: 0.1)
            ]
            + (0...40).map { index in
                watchSample(
                    request: 10.3 + Double(index) * 0.1, mark: "TRANSITION", status: "TRANSITION", returnLag: 0.05,
                    classifyLag: 0.1)
            }
            + (0...12).map { index in
                watchSample(request: 14.4 + Double(index) * 0.09, mark: "A1", returnLag: 0.05, classifyLag: 0.1)
            }

        XCTAssertThrowsError(
            try AccessLifecycleContract.assertIPadPauseTimingEvidence(
                continueMark: "A5", baselineLuma: 0.5, samples: samples, intervalSeconds: 12
            )
        )
    }

    func testRecordingMustContinuePastIdentityTimeoutWithoutNewImage() {
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertRecordingDidNotStopAtIdentityTimeout(
                lastSampleRequestElapsed: 14.0,
                confirmedNewImage: false,
                intervalSeconds: 12
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("T+2"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertRecordingDidNotStopAtIdentityTimeout(
                lastSampleRequestElapsed: 14.7,
                confirmedNewImage: true,
                intervalSeconds: 12
            )
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertRecordingDidNotStopAtIdentityTimeout(
                lastSampleRequestElapsed: 18.0,
                confirmedNewImage: false,
                intervalSeconds: 12
            )
        )
        XCTAssertEqual(
            AccessLifecycleContract.continueWatchRecordingDeadline(intervalSeconds: 12),
            26
        )
        XCTAssertEqual(
            AccessLifecycleContract.continueWatchDenseCaptureDeadline(intervalSeconds: 12),
            18
        )
        XCTAssertEqual(AccessLifecycleContract.continueCaptureSlackSeconds, 2)
    }

    func testClickReturnTimeCannotReplacePressOrigin() {
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertClickTimesRecordedSeparately(
                pressIssuedElapsed: 0,
                pressReturnedElapsed: 0.29,
                continueOriginElapsed: 0.29,
                usedReturnedAsOrigin: true
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("click return"))
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertClickTimesRecordedSeparately(
                pressIssuedElapsed: 0,
                pressReturnedElapsed: 0.29,
                continueOriginElapsed: 0,
                usedReturnedAsOrigin: false
            )
        )
    }

    func testZoomControlBarAndClassificationFailureAreNotStart() {
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertBlackZoomBarOrClassificationIsNotAdvance(
                status: "MATCH",
                mark: "A5",
                continueMark: "A5",
                controlBarVisible: true
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertBlackZoomBarOrClassificationIsNotAdvance(
                status: "MATCH",
                mark: "A5",
                continueMark: "A5",
                controlBarVisible: false
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertBlackZoomBarOrClassificationIsNotAdvance(
                status: "BLACK",
                mark: "BLACK",
                continueMark: "A5",
                controlBarVisible: true
            )
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.assertBlackZoomBarOrClassificationIsNotAdvance(
                status: "UNRECOGNIZABLE",
                mark: "UNRECOGNIZABLE",
                continueMark: "A5",
                controlBarVisible: true
            )
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertBlackZoomBarOrClassificationIsNotAdvance(
                status: "TRANSITION",
                mark: "TRANSITION",
                continueMark: "A5",
                controlBarVisible: true
            )
        )
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertBlackZoomBarOrClassificationIsNotAdvance(
                status: "MATCH",
                mark: "A1",
                continueMark: "A5",
                controlBarVisible: true
            )
        )
        let zoomOnly = [
            watchSample(request: 5.0, mark: "A5"),
            watchSample(request: 12.0, mark: "A5"),
            watchSample(request: 13.0, mark: "A5")
        ]
        XCTAssertEqual(
            AccessLifecycleContract.assessFirstTransitionStart(
                continueMark: "A5",
                baselineLuma: 0.5,
                samples: zoomOnly,
                intervalSeconds: 12
            ),
            .missing
        )
        XCTAssertThrowsError(
            try AccessLifecycleContract.officialStartSigned(
                for: .missing,
                continueMark: "A5",
                intervalSeconds: 12
            )
        )
    }

    private func watchSample(
        request: TimeInterval,
        mark: String,
        status: String = "MATCH",
        luma: Double = 0.5,
        controlBar: Bool = true,
        returnLag: TimeInterval = 0.3,
        classifyLag: TimeInterval = 0.8
    ) -> AccessLifecycleContract.ContinueWatchSample {
        AccessLifecycleContract.ContinueWatchSample(
            requestElapsed: request,
            returnElapsed: request + returnLag,
            classifiedElapsed: request + classifyLag,
            status: status,
            mark: mark,
            meanLuma: luma,
            controlBarVisible: controlBar
        )
    }
}
