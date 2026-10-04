import Foundation

extension AccessLifecycleContract {
    // Narrow entry for settings save / pause-continue / background return: time and the public frame are the final
    // criteria, not the progress probe or control value changes.
    static let requestedIntervalSeconds = 12
    static let pauseHoldBeyondIntervalSeconds: TimeInterval = 2
    static let continueCaptureSlackSeconds: TimeInterval = 2
    static let tvOSSelectableIntervals: [Int] = [5, 8, 10, 15, 30]
    // A brightness drop on the same photo is only an uncertain signal and cannot alone count as a transition.
    static let uncertainSameMarkLumaDrop: Double = 0.12
    // Evidence of an identifiable new photo may extend past T+2 without widening the transition window.
    static let newImageCaptureBeyondWindowSeconds: TimeInterval = 4

    struct ContinueWatchSample {
        let requestElapsed: TimeInterval
        let returnElapsed: TimeInterval
        let classifiedElapsed: TimeInterval
        let status: String
        let mark: String
        let meanLuma: Double
        let isControlBarVisible: Bool
    }

    struct IPadPauseTimingEvidence {
        let earliestTransitionElapsed: TimeInterval
        let latestTransitionElapsed: TimeInterval
        let transitionStartRequestElapsed: TimeInterval
        let stableImageRequestElapsed: TimeInterval
        let stableImageReturnElapsed: TimeInterval
        let stableImageDelaySeconds: TimeInterval
    }

    enum FirstTransitionStartVerdict: Equatable {
        case detected(requestElapsed: TimeInterval, mark: String, status: String)
        case pendingVideoReview(reason: String)
        case tooEarly(requestElapsed: TimeInterval, mark: String)
        case tooLate(requestElapsed: TimeInterval, mark: String)
        case missing
    }

    static func resolveTimingInterval(requested: Int, available: [Int]) throws -> (
        actual: Int, shouldRequireIntervalReview: Bool
    ) {
        if available.contains(requested) {
            return (requested, false)
        }
        guard let actual = available.min(by: { abs($0 - requested) < abs($1 - requested) }) else {
            throw AssertionError.message("Interval options are missing")
        }
        return (actual, true)
    }

    static func assertFourSettingsDiffer(initial: [String: Any], changed: [String: Any]) throws {
        for field in ["autoPlayEnabled", "intervalSeconds", "showExif", "displayMode"] {
            guard let initialValue = initial[field], let changedValue = changed[field] else {
                throw AssertionError.message("Missing settings evidence")
            }
            if isSettingValueEqual(initialValue, changedValue) {
                throw AssertionError.message("Must change \(field) to the opposite or another value via real settings")
            }
        }
    }

    static func assertProgressProbeNotUsed(launchEnvironment: [String: String]) throws {
        if launchEnvironment[scenePresentationProbeKey] != nil {
            throw AssertionError.message("Must not use the internal progress probe as the final criterion")
        }
        try assertNoForcedDisplayMode(launchEnvironment)
        let forced = launchEnvironment.keys.filter { $0.hasPrefix("UI_TEST_") }.sorted()
        if forced.isEmpty == false {
            throw AssertionError.message("launchEnvironment must not force-override the settings under test")
        }
    }

    static func assertPauseUsesVisibleIdentity(
        pauseMark: String,
        afterNextMark: String,
        didUseProgressProbe: Bool,
        didUseControlValueOnly: Bool
    ) throws {
        if didUseProgressProbe {
            throw AssertionError.message("Must not use the internal progress value instead of time and the screen")
        }
        if didUseControlValueOnly {
            throw AssertionError.message("Photo changes while paused must not be judged by control value changes alone")
        }
        try assertPresentMark(pauseMark)
        try assertPresentMark(afterNextMark)
        if afterNextMark == pauseMark {
            throw AssertionError.message("The next photo after pause must show a different public pattern")
        }
    }

    static func assertNarrowSettingsPersist(
        initial: [String: Any],
        changed: [String: Any],
        afterRestart: [String: Any]
    ) throws {
        try assertFourSettingsDiffer(initial: initial, changed: changed)
        try assertSettingsPersisted(before: changed, afterRestart: afterRestart)
    }

    static func assertNarrowPathDidNotUnlockPin(didEnterPin: Bool) throws {
        if didEnterPin {
            throw AssertionError.message("The narrow entry must not enter the passcode by itself when reading settings")
        }
    }

    static func assertPausedHoldWithoutAdvance(
        startMark: String,
        endMark: String,
        holdSeconds: TimeInterval,
        intervalSeconds: TimeInterval
    ) throws {
        try assertPresentMark(startMark)
        try assertPresentMark(endMark)
        if endMark != startMark {
            throw AssertionError.message("An automatic photo change during the pause hold must not count as a pass")
        }
        if holdSeconds + timingToleranceSeconds < intervalSeconds + pauseHoldBeyondIntervalSeconds {
            throw AssertionError.message("The pause hold must last at least T+2 seconds")
        }
    }

    static func assertHoldSampleUnchanged(expectedMark: String, polled: String) throws {
        try assertPresentMark(expectedMark)
        try assertPresentMark(polled)
        if polled != expectedMark {
            throw AssertionError.message("An automatic photo change during the pause hold must not count as a pass")
        }
    }

    // The value read back from the real UI must equal the target seconds; reading 16 must not become a pass.
    static func assertIOSIntervalReachedRequested(observed: Int, target: Int = requestedIntervalSeconds) throws {
        if observed != target {
            throw AssertionError.message("The iOS slider must be settable to \(target) seconds.")
        }
    }

    // interval.link is also found in the settings home tree, so it cannot stand in for entering playback settings.
    static func assertTVOSPlaybackSettingsEntered(isAutoPlayLinkFocused: Bool, isHomePlaybackFocused: Bool) throws {
        if isHomePlaybackFocused || isAutoPlayLinkFocused == false {
            throw AssertionError.message(
                "After opening settings, enter playback settings before locating the interval row")
        }
    }

    // Do not read value when the control is not in the tree; an empty value must not count as paused.
    static func playPauseControlValue(isPresent: Bool, rawValue: String?) -> String {
        guard isPresent else { return "" }
        return (rawValue ?? "").lowercased()
    }

    static func assertMissingPlayPauseIsNotPaused(isPresent: Bool, isInferredPaused: Bool) throws {
        if isPresent == false && isInferredPaused {
            throw AssertionError.message("Missing controls must not be treated as paused")
        }
    }

    static func assertPlayPauseNotRetappedBecauseMissing(
        didAlreadyTap: Bool,
        didRetapBecauseMissing: Bool
    ) throws {
        if didAlreadyTap && didRetapBecauseMissing {
            throw AssertionError.message("Do not tap again and toggle playback")
        }
    }

    // A leftover settings button that still exists cannot stand in for a hittable play/pause button.
    static func isPlaybackControlBarRevealed(isPlayPauseHittable: Bool) -> Bool {
        isPlayPauseHittable
    }

    // The playback page has arrived once the photo, control bar or onboarding hint is there; being temporarily
    // unhittable is not a failure.
    static func hasPlaybackPageArrived(
        isSettingsPresent: Bool,
        isNextPresent: Bool,
        isPlayPausePresent: Bool,
        isHintPresent: Bool
    ) -> Bool {
        isSettingsPresent || isNextPresent || isPlayPausePresent || isHintPresent
    }

    static func assertPlaybackPageArrivalIgnoresTemporaryUnhittable(
        isPresentOnPlaybackPage: Bool,
        isTreatedAsArrived: Bool
    ) throws {
        if isPresentOnPlaybackPage && isTreatedAsArrived == false {
            throw AssertionError.message(
                "Do not fail because the button is temporarily unhittable after the playback screen has arrived")
        }
        if isPresentOnPlaybackPage == false && isTreatedAsArrived {
            throw AssertionError.message("Do not mark playback as arrived before the playback page is reached")
        }
    }

    // Waiting to enter playback relies only on exists; tapping the hint or the canvas goes through XCTest animation
    // idling, and a private selector must not be used to skip it.
    static func assertEnterPlaybackWaitDoesNotTapOrBypassQuiescence(
        didTapCanvas: Bool,
        didTapHint: Bool,
        didUsePrivateQuiescenceBypass: Bool
    ) throws {
        if didUsePrivateQuiescenceBypass {
            throw AssertionError.message("Do not use a private wait bypass to skip XCTest quiescence")
        }
        if didTapCanvas || didTapHint {
            throw AssertionError.message("Do not tap the canvas or hint while waiting for playback to load")
        }
    }

    static func assertPlaybackControlsRevealedByTarget(
        isPlayPauseHittable: Bool,
        isSettingsPresent: Bool,
        isTreatedAsRevealed: Bool
    ) throws {
        if isTreatedAsRevealed && isPlayPauseHittable == false {
            throw AssertionError.message(
                "A leftover settings button must not stand in for operable play/pause controls")
        }
        if isSettingsPresent && isPlayPauseHittable == false && isTreatedAsRevealed {
            throw AssertionError.message(
                "A leftover settings button must not stand in for operable play/pause controls")
        }
    }

    // The first waitForExistence round takes about 1 second, during which the 8-second auto-hide can remove the
    // button; even when it is hittable, the canvas tap must not be skipped.
    static func assertConfirmPlayPauseWakesCanvasBeforeWait(
        didWakeCanvas: Bool,
        didTapPlayPauseToWake: Bool
    ) throws {
        if didWakeCanvas == false {
            throw AssertionError.message("Tap the canvas to wake it before confirming play/pause")
        }
        if didTapPlayPauseToWake {
            throw AssertionError.message("Do not tap again and toggle playback")
        }
    }

    // The stopwatch must start when Continue is pressed; the button check may come after it, but the stopwatch
    // must not be moved to after the check completes.
    static func assertContinueClockStartsAtPress(
        confirmWaitSecondsBeforeClock: TimeInterval
    ) throws {
        if confirmWaitSecondsBeforeClock > timingToleranceSeconds {
            throw AssertionError.message("The confirmation wait must not happen before continueAt")
        }
    }

    // If playback settings content is present, we are on that page; a momentary loss of focus does not mean the
    // settings home.
    static func assertTVOSHomeUniqueBeatsPlaybackRowLabel(
        isHomeUniqueVisible: Bool,
        isClassifiedAsPlayback: Bool
    ) throws {
        if isHomeUniqueVisible && isClassifiedAsPlayback {
            throw AssertionError.message("The settings home's playback settings label does not mean that page is open")
        }
    }

    static func assertTVOSFocusSearchMustNotUseOnlyDownWhenTargetAbove(
        didTargetAppearAboveFocus: Bool,
        didUseOnlyDown: Bool
    ) throws {
        if didTargetAppearAboveFocus && didUseOnlyDown {
            throw AssertionError.message("Must not press only Down when the target is above")
        }
    }

    static func tvosSettingsPageIdentity(
        isPlaybackSettingsContentVisible: Bool,
        isHomeEntryVisible: Bool,
        isHomeUniqueVisible: Bool = false
    ) -> String {
        if isHomeUniqueVisible { return "home" }
        if isPlaybackSettingsContentVisible { return "playback" }
        if isHomeEntryVisible { return "home" }
        return "unknown"
    }

    static func assertTVOSPageIdentityNotInferredFromMissingFocus(
        isPlaybackSettingsContentVisible: Bool,
        isClassifiedAsHome: Bool
    ) throws {
        if isPlaybackSettingsContentVisible && isClassifiedAsHome {
            throw AssertionError.message(
                "Do not classify the settings home solely because focus is momentarily missing")
        }
    }
}
