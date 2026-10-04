import Foundation

// Access-lifecycle contract shared by all three platforms. Launch arguments must not stand in for the real settings entry
// or for real persistence; the PIN must never appear in evidence.

enum AccessLifecycleContract {
    enum AssertionError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case .message(let text):
                return text
            }
        }
    }

    static let allowedIdentitySource = "public_fixture_photo_mark"
    static let allowedSettingsSource = "real_settings_ui"
    static let forbiddenSettingsSources: Set<String> = ["launch_argument", "userdefaults_injection"]
    static let forbiddenDisplayModeKey = "UI_TEST_FORCE_PLAYBACK_DISPLAY_MODE"
    static let measuredProgressZeroEpsilon: Double = 0.001
    static let scenePresentationProbeKey = "UI_TEST_SCENE_PRESENTATION_CONTRACT_PROBE"
    static let knownRequests: Set<String> = [
        "settings.open",
        "settings.pin.enable",
        "settings.pin.confirm",
        "settings.pin.cancel",
        "settings.pin.unlock",
        "settings.save.autoplay",
        "settings.save.interval",
        "settings.save.exif",
        "settings.save.display_mode",
        "settings.about.licenses",
        "playback.pause",
        "playback.next",
        "playback.play",
        "playback.background",
        "playback.foreground",
        "playback.wake_controls"
    ]
    static let playbackLayerPrefix = "slideshow."
    static let nonPlaybackLayerPrefixes = ["settings.", "pinEntry.", "firstboot.", "mode."]
    static let hiddenControlBarPlaybackIdentifier = "slideshow.hiddenWakeReceiver"
    // Focus counts as stable only after 5 consecutive hasFocus polls, spaced by the UI test focusPoll of 0.08s
    // (about 0.4s in total). Losing focus midway resets the count. In an earlier device run, the Up press landed
    // while focus was still being established.
    static let minStableHiddenWakeFocusObservations = 5
    static let allowedSystemPauseActivation = "activate_existing_process"
    static let newStableMarkPollInterval: TimeInterval = 0.1
    static let newStableMarkConfirmWindow: TimeInterval = 0.8
    static let ipadNewStableMarkConfirmWindow: TimeInterval = 1.0
    static let ipadStableImageDeadlineAfterTransition: TimeInterval = 4.0
    static let newStableMarkMinimumLuma: Double = 0.20
    // Wake evidence must finish before the next automatic photo change; 2.5s covers one screenshot, a tap and
    // another screenshot.
    static let wakeEvidenceBudgetSeconds: TimeInterval = 2.5

    static func clampedWait(requested: TimeInterval, remaining: TimeInterval) -> TimeInterval {
        if remaining <= 0 || requested <= 0 {
            return 0
        }
        return min(requested, remaining)
    }

    static func pollWait(remaining: TimeInterval) -> TimeInterval {
        clampedWait(requested: newStableMarkPollInterval, remaining: remaining)
    }

    static func confirmWait(remaining: TimeInterval) -> TimeInterval {
        // The 0.8s confirmation must be clamped to the remaining time and must never run past the deadline.
        clampedWait(requested: newStableMarkConfirmWindow, remaining: remaining)
    }

    static func hideWaitForWake(
        hideSeconds: TimeInterval,
        remainingToAutoplay: TimeInterval,
        evidenceBudget: TimeInterval
    ) -> TimeInterval {
        let maxWait = remainingToAutoplay - evidenceBudget
        if hideSeconds <= 0 || maxWait <= 0 {
            return 0
        }
        return min(hideSeconds, maxWait)
    }

    static func shouldWaitForAutoplayBeforeWake(
        remainingToAutoplay: TimeInterval,
        evidenceBudget: TimeInterval
    ) -> Bool {
        remainingToAutoplay <= evidenceBudget
    }

    static func isConfirmedNewStableMark(
        status: String,
        mark: String,
        candidateMark: String,
        initialMark: String,
        meanLuma: Double
    ) -> Bool {
        status == "MATCH"
            && mark.isEmpty == false
            && mark == candidateMark
            && mark != initialMark
            && meanLuma >= newStableMarkMinimumLuma
    }

    static func assertNotSkip(_ status: String) throws {
        if status.lowercased() == "skip" {
            throw AssertionError.message("skip must not count as a pass")
        }
    }

    static func assertIdentitySource(_ source: String) throws {
        if source != allowedIdentitySource {
            throw AssertionError.message("Identity comes only from public fixture photos, never from logs or index")
        }
    }

    static func assertSettingsSource(_ source: String) throws {
        if forbiddenSettingsSources.contains(source) || source != allowedSettingsSource {
            throw AssertionError.message("Launch arguments or UserDefaults must not pass for real persistence")
        }
    }

    static func assertSettingsPersisted(before: [String: Any], afterRestart: [String: Any]) throws {
        for field in ["autoPlayEnabled", "intervalSeconds", "showExif", "displayMode"] {
            guard let beforeValue = before[field], let afterValue = afterRestart[field] else {
                throw AssertionError.message("Missing settings evidence")
            }
            if !areSettingValuesEqual(beforeValue, afterValue) {
                throw AssertionError.message("Settings were not persisted")
            }
        }
        let defaults: [String: Any] = [
            "autoPlayEnabled": true,
            "intervalSeconds": 5,
            "showExif": true,
            "displayMode": "smartFill"
        ]
        let unchangedDefaults = defaults.keys.allSatisfy { key in
            guard let beforeValue = before[key], let defaultValue = defaults[key] else {
                return false
            }
            return areSettingValuesEqual(beforeValue, defaultValue)
        }
        if unchangedDefaults {
            throw AssertionError.message("Settings were not persisted")
        }
    }

    static func assertNoForcedDisplayMode(_ launchEnvironment: [String: String]) throws {
        if launchEnvironment[forbiddenDisplayModeKey] != nil {
            throw AssertionError.message("A forced display mode must not replace the real settings path")
        }
    }

    static func assertDisplayBeforePoolBurn(screenshotOrder: [String]) throws {
        guard let displayAt = screenshotOrder.firstIndex(of: "display-before") else {
            throw AssertionError.message("The comparison must happen before autoplay burns through the pool")
        }
        let burnNames = [
            "pause",
            "after-next",
            "after-play",
            "before-background",
            "after-background",
            "before-wake",
            "after-wake"
        ]
        if burnNames.contains(where: { name in
            guard let index = screenshotOrder.firstIndex(of: name) else { return false }
            return index < displayAt
        }) {
            throw AssertionError.message("The comparison must happen before autoplay burns through the pool")
        }
    }

    static func assertKnownRequests(_ requests: [String]) throws {
        guard !requests.isEmpty else {
            throw AssertionError.message("Missing request evidence")
        }
        for request in requests where !knownRequests.contains(request) {
            throw AssertionError.message("Unknown request, this batch fails: \(request)")
        }
    }

    static func assertPauseNextPlay(
        pause: String,
        afterNext: String,
        afterPlay: String,
        progressAfterPlay: Double,
        progressAfterNext: Double? = nil,
        progressRawAfterNext: String = "",
        progressRawAfterPlay: String = ""
    ) throws {
        try assertPresentMark(pause)
        try assertPresentMark(afterNext)
        try assertPresentMark(afterPlay)
        if afterNext == pause {
            throw AssertionError.message("next after pause must switch to a new scene")
        }
        if afterPlay == pause || afterPlay != afterNext {
            throw AssertionError.message("Returning to the old scene must not count as a pass")
        }
        if let progressAfterNext {
            try assertProgressMeasured(
                progressAfterNext: progressAfterNext,
                progressAfterPlay: progressAfterPlay,
                rawAfterNext: progressRawAfterNext,
                rawAfterPlay: progressRawAfterPlay
            )
        } else if progressAfterPlay != 0 {
            throw AssertionError.message("Play must resume the new scene from progress 0")
        }
    }

    static func assertAutoPlayEnabledAtBackground(_ enabled: Bool) throws {
        if !enabled {
            throw AssertionError.message("Autoplay must be on when entering the background")
        }
    }

    static func assertBackgroundWaitExceedsInterval(waitSeconds: Double, intervalSeconds: Double) throws {
        if waitSeconds <= intervalSeconds {
            throw AssertionError.message("The background wait must exceed one read interval")
        }
    }

    static func assertProgressMeasured(
        progressAfterNext: Double,
        progressAfterPlay: Double,
        rawAfterNext: String,
        rawAfterPlay: String
    ) throws {
        if abs(progressAfterNext) > measuredProgressZeroEpsilon {
            throw AssertionError.message("next after pause must keep progress at 0")
        }
        if !hasMeasuredProgress(rawAfterNext) || !hasMeasuredProgress(rawAfterPlay) {
            throw AssertionError.message("Progress must be measured")
        }
        if progressAfterPlay.isNaN {
            throw AssertionError.message("Progress must be measured")
        }
    }

    private static func hasMeasuredProgress(_ raw: String) -> Bool {
        if raw.isEmpty || raw.contains("progress=missing") || raw.contains("motionRawProgress=none") {
            return false
        }
        return raw.contains("progress=") || raw.contains("motionRawProgress=")
    }

    static func assertBackgroundDidNotJump(before: String, after: String) throws {
        try assertPresentMark(before)
        try assertPresentMark(after)
        if after != before {
            throw AssertionError.message("Jumping to another photo on return from background must not count as a pass")
        }
    }

    static func assertWakeDidNotSwitch(before: String, after: String) throws {
        try assertPresentMark(before)
        try assertPresentMark(after)
        if after != before {
            throw AssertionError.message("Switching photos while waking must not count as a pass")
        }
    }

    static func assertPinFlow(
        wrongPinEntered: Bool,
        cancelStillProtected: Bool,
        correctPinEntered: Bool,
        restartGated: Bool
    ) throws {
        if wrongPinEntered {
            throw AssertionError.message("Getting in with a wrong PIN must not count as a pass")
        }
        if !cancelStillProtected {
            throw AssertionError.message("Protection disappearing after cancel must not count as a pass")
        }
        if !correctPinEntered {
            throw AssertionError.message("The correct PIN must open settings")
        }
        if !restartGated {
            throw AssertionError.message("The gate must still apply after restart")
        }
    }

    static func isSlideshowLayer(identifiers: [String]) -> Bool {
        if identifiers.contains(where: { identifier in
            nonPlaybackLayerPrefixes.contains { identifier.hasPrefix($0) }
        }) {
            return false
        }
        return identifiers.contains { $0.hasPrefix(playbackLayerPrefix) }
    }

    static func assertReturnedToSlideshow(identifiers: [String], requireSettingsButton: Bool) throws {
        if requireSettingsButton {
            throw AssertionError.message("Returning to playback must not require the control bar to be visible")
        }
        if isSlideshowLayer(identifiers: identifiers) == false {
            throw AssertionError.message("Returning to playback must confirm the playback layer")
        }
    }

    // When the PIN gate blocks the settings page, requiring the playback settings button first must fail.
    static func assertSettingsOpen(identifiers: [String], requirePlaybackItem: Bool) throws {
        let pinPresent = identifiers.contains { $0.hasPrefix("pinEntry.") }
        let settingsPresent = identifiers.contains { $0.hasPrefix("settings.") }
        if pinPresent == false && settingsPresent == false {
            throw AssertionError.message("After opening settings, the PIN gate or the settings page must be confirmed")
        }
        if pinPresent && requirePlaybackItem {
            throw AssertionError.message("Playback settings must not be required while the PIN gate is still up")
        }
    }

    // Only one direction key press is allowed after returning from settings, and only after the playback page
    // transition completes and the hidden receiver holds focus stably.
    static func assertSettingsReturnWake(
        identifiers: [String],
        transitionComplete: Bool,
        hiddenWakeReceiverFocused: Bool,
        hiddenWakeReceiverFocusStable: Bool,
        consecutiveFocusedObservations: Int,
        directionalPressCount: Int,
        beforeScreenshot: String,
        afterScreenshot: String
    ) throws {
        try assertReturnedToSlideshow(identifiers: identifiers, requireSettingsButton: false)
        if transitionComplete == false {
            throw AssertionError.message("After settings return, no direction key until the transition completes")
        }
        if hiddenWakeReceiverFocused == false
            || hiddenWakeReceiverFocusStable == false
            || consecutiveFocusedObservations < minStableHiddenWakeFocusObservations
        {
            throw AssertionError.message("After settings return, must confirm the hidden receiver holds focus stably")
        }
        if directionalPressCount != 1 {
            throw AssertionError.message("Must not press twice to mask the first wake")
        }
        if beforeScreenshot.isEmpty || afterScreenshot.isEmpty {
            throw AssertionError.message("Wake after settings return is missing before/after screenshots")
        }
    }

    static func assertSystemPauseActivation(
        activation: String,
        processRebuilt: Bool,
        homeLeftAppRunning: Bool
    ) throws {
        if activation != allowedSystemPauseActivation {
            throw AssertionError.message("System pause analog must activate the existing process, not Open or rebuild")
        }
        if processRebuilt {
            throw AssertionError.message("System pause analog must not rebuild the process")
        }
        if homeLeftAppRunning == false {
            throw AssertionError.message("The process exited after Home; activate would Open/rebuild it")
        }
    }

    static func assertSystemPauseIdentityTiming(screenshotOrder: [String]) throws {
        guard
            let before = screenshotOrder.firstIndex(of: "before-background"),
            let after = screenshotOrder.firstIndex(of: "after-background"),
            after > before
        else {
            throw AssertionError.message("Missing identity timing for the return from background")
        }
        let window = screenshotOrder[(before + 1)..<after]
        if window.contains(where: { $0.contains("wake") }) {
            throw AssertionError.message("On background return, do not wake the control bar before capturing identity")
        }
    }

    // Serializes keys and nested values so a PIN hidden in any value is found by `assertPinAbsent`.
    static func serializedText(of payload: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return String(describing: payload) }
        return text
    }

    static func assertPinAbsent(in text: String, pinValues: [String]) throws {
        if pinValues.contains(where: { !$0.isEmpty && text.contains($0) }) {
            throw AssertionError.message("PIN appears in a file name, command, log or attachment")
        }
    }

    // Under XCTest the PIN goes through UserDefaults, which must not count as the real Keychain;
    // a Keychain failure stays PARTIAL.
    static func d01Verdict(storageKind: String, xctestConfigPresent: Bool) throws -> String {
        if storageKind == "keychain" && xctestConfigPresent {
            throw AssertionError.message("Test UserDefaults must not pass for the real Keychain")
        }
        if storageKind == "keychain_failure" {
            return "PARTIAL"
        }
        if storageKind != "uitest_userdefaults" {
            throw AssertionError.message("Unknown PIN storage type, this batch fails")
        }
        return "PARTIAL"
    }

    private static func assertPresentMark(_ mark: String) throws {
        if mark.isEmpty {
            throw AssertionError.message("A missing image must not count as a pass")
        }
        if mark == "BLACK" {
            throw AssertionError.message("All black must not count as a pass")
        }
        if mark == "BLANK" {
            throw AssertionError.message("Blank must not count as a pass")
        }
        if mark == "UNRECOGNIZABLE" || mark == "TRANSITION" {
            throw AssertionError.message("Unrecognizable input must not count as a pass")
        }
    }

    static func assertNoRetryMasking(_ retriesUsedToPass: Bool) throws {
        if retriesUsedToPass {
            throw AssertionError.message("Masking with retries must not count as a pass")
        }
    }

    static func assertDisplayPolicyTookEffect(
        source: String,
        modeBefore: String,
        modeAfter: String,
        pngSHA256Before: String,
        pngSHA256After: String,
        markBefore: String,
        markAfter: String
    ) throws {
        try assertSettingsSource(source)
        try assertPresentMark(markBefore)
        try assertPresentMark(markAfter)
        if modeBefore.isEmpty || modeAfter.isEmpty || modeBefore == modeAfter {
            throw AssertionError.message("A display strategy that did not take effect must not count as a pass")
        }
        if pngSHA256Before.count != 64 || pngSHA256After.count != 64 || pngSHA256Before == pngSHA256After {
            throw AssertionError.message("A display strategy that did not take effect must not count as a pass")
        }
    }

    static func assertIPadLicenseReturn(device: String, stackPreserved: Bool) throws {
        if device != "ipad" {
            return
        }
        if !stackPreserved {
            throw AssertionError.message("Losing the iPad open-source licenses back stack must not count as a pass")
        }
    }

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
        let controlBarVisible: Bool
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
        actual: Int, desktopCloseoutRequired: Bool
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
            if areSettingValuesEqual(initialValue, changedValue) {
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
        usedProgressProbe: Bool,
        usedControlValueOnly: Bool
    ) throws {
        if usedProgressProbe {
            throw AssertionError.message("Must not use the internal progress value instead of time and the screen")
        }
        if usedControlValueOnly {
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
        if holdSeconds + 0.001 < intervalSeconds + pauseHoldBeyondIntervalSeconds {
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
    static func assertTVOSPlaybackSettingsEntered(autoPlayLinkFocused: Bool, homePlaybackFocused: Bool) throws {
        if homePlaybackFocused || autoPlayLinkFocused == false {
            throw AssertionError.message(
                "After opening settings, enter playback settings before locating the interval row")
        }
    }

    // Do not read value when the control is not in the tree; an empty value must not count as paused.
    static func playPauseControlValue(exists: Bool, rawValue: String?) -> String {
        guard exists else { return "" }
        return (rawValue ?? "").lowercased()
    }

    static func assertMissingPlayPauseIsNotPaused(exists: Bool, inferredPaused: Bool) throws {
        if exists == false && inferredPaused {
            throw AssertionError.message("Missing controls must not be treated as paused")
        }
    }

    static func assertPlayPauseNotRetappedBecauseMissing(
        alreadyTapped: Bool,
        retappedBecauseMissing: Bool
    ) throws {
        if alreadyTapped && retappedBecauseMissing {
            throw AssertionError.message("Do not tap again and toggle playback")
        }
    }

    // A leftover settings button that still exists cannot stand in for a hittable play/pause button.
    static func playbackControlsAreRevealed(playPauseHittable: Bool) -> Bool {
        playPauseHittable
    }

    // The playback page has arrived once the photo, control bar or onboarding hint is there; being temporarily
    // unhittable is not a failure.
    static func playbackPageHasArrived(
        settingsExists: Bool,
        nextExists: Bool,
        playPauseExists: Bool,
        hintExists: Bool
    ) -> Bool {
        settingsExists || nextExists || playPauseExists || hintExists
    }

    static func assertPlaybackPageArrivalIgnoresTemporaryUnhittable(
        existsOnPlaybackPage: Bool,
        treatedAsArrived: Bool
    ) throws {
        if existsOnPlaybackPage && treatedAsArrived == false {
            throw AssertionError.message(
                "Do not fail because the button is temporarily unhittable after the playback screen has arrived")
        }
        if existsOnPlaybackPage == false && treatedAsArrived {
            throw AssertionError.message("Do not mark playback as arrived before the playback page is reached")
        }
    }

    // Waiting to enter playback relies only on exists; tapping the hint or the canvas goes through XCTest animation
    // idling, and a private selector must not be used to skip it.
    static func assertEnterPlaybackWaitDoesNotTapOrBypassQuiescence(
        tappedCanvas: Bool,
        tappedHint: Bool,
        usedPrivateQuiescenceBypass: Bool
    ) throws {
        if usedPrivateQuiescenceBypass {
            throw AssertionError.message("Do not use a private wait bypass to skip XCTest quiescence")
        }
        if tappedCanvas || tappedHint {
            throw AssertionError.message("Do not tap the canvas or hint while waiting for playback to load")
        }
    }

    static func assertPlaybackControlsRevealedByTarget(
        playPauseHittable: Bool,
        settingsExists: Bool,
        treatedAsRevealed: Bool
    ) throws {
        if treatedAsRevealed && playPauseHittable == false {
            throw AssertionError.message(
                "A leftover settings button must not stand in for operable play/pause controls")
        }
        if settingsExists && playPauseHittable == false && treatedAsRevealed {
            throw AssertionError.message(
                "A leftover settings button must not stand in for operable play/pause controls")
        }
    }

    // The first waitForExistence round takes about 1 second, during which the 8-second auto-hide can remove the
    // button; even when it is hittable, the canvas tap must not be skipped.
    static func assertConfirmPlayPauseWakesCanvasBeforeWait(
        wokeCanvas: Bool,
        tappedPlayPauseToWake: Bool
    ) throws {
        if wokeCanvas == false {
            throw AssertionError.message("Tap the canvas to wake it before confirming play/pause")
        }
        if tappedPlayPauseToWake {
            throw AssertionError.message("Do not tap again and toggle playback")
        }
    }

    // The stopwatch must start when Continue is pressed; the button check may come after it, but the stopwatch
    // must not be moved to after the check completes.
    static func assertContinueClockStartsAtPress(
        confirmWaitSecondsBeforeClock: TimeInterval
    ) throws {
        if confirmWaitSecondsBeforeClock > 0.001 {
            throw AssertionError.message("The confirmation wait must not happen before continueAt")
        }
    }

    // If playback settings content is present, we are on that page; a momentary loss of focus does not mean the
    // settings home.
    static func assertTVOSHomeUniqueBeatsPlaybackRowLabel(
        homeUniqueVisible: Bool,
        classifiedAsPlayback: Bool
    ) throws {
        if homeUniqueVisible && classifiedAsPlayback {
            throw AssertionError.message("The settings home's playback settings label does not mean that page is open")
        }
    }

    static func assertTVOSFocusSearchMustNotUseOnlyDownWhenTargetAbove(
        targetWasAboveFocus: Bool,
        usedOnlyDown: Bool
    ) throws {
        if targetWasAboveFocus && usedOnlyDown {
            throw AssertionError.message("Must not press only Down when the target is above")
        }
    }

    static func tvosSettingsPageIdentity(
        playbackSettingsContentVisible: Bool,
        homeEntryVisible: Bool,
        homeUniqueVisible: Bool = false
    ) -> String {
        if homeUniqueVisible { return "home" }
        if playbackSettingsContentVisible { return "playback" }
        if homeEntryVisible { return "home" }
        return "unknown"
    }

    static func assertTVOSPageIdentityNotInferredFromMissingFocus(
        playbackSettingsContentVisible: Bool,
        classifiedAsHome: Bool
    ) throws {
        if playbackSettingsContentVisible && classifiedAsHome {
            throw AssertionError.message(
                "Do not classify the settings home solely because focus is momentarily missing")
        }
    }

    static func assertContinueEarlyStillSameScene(
        continueMark: String,
        earlyMark: String,
        elapsedSeconds: TimeInterval,
        intervalSeconds: TimeInterval
    ) throws {
        try assertPresentMark(continueMark)
        try assertPresentMark(earlyMark)
        if elapsedSeconds > intervalSeconds / 2 {
            throw AssertionError.message(
                "The first-half evidence window after Continue crossed its bounds; classify this as a test timing failure"
            )
        }
        if earlyMark != continueMark {
            throw AssertionError.message("The same public pattern must stay for the first half of T after Continue")
        }
    }

    static func assertContinueAutoAdvanceInWindow(
        continueMark: String,
        laterMark: String,
        elapsedSeconds: TimeInterval,
        intervalSeconds: TimeInterval
    ) throws {
        try assertPresentMark(continueMark)
        try assertPresentMark(laterMark)
        let earliest = intervalSeconds - continueCaptureSlackSeconds
        let latest = intervalSeconds + continueCaptureSlackSeconds
        if elapsedSeconds > latest {
            throw AssertionError.message(
                "No automatic photo change was captured within T±2; if waiting for idleness crossed the window, classify this as a test timing failure"
            )
        }
        if elapsedSeconds < earliest {
            throw AssertionError.message(
                "Automatic photo change occurred before T-2; first check test timing and image recognition instead of immediately calling it a product bug"
            )
        }
        if laterMark == continueMark {
            throw AssertionError.message("After about a full T, it must switch to the next scene")
        }
    }

    static func isUsableSceneMark(_ mark: String) -> Bool {
        mark.isEmpty == false
            && mark != "BLACK"
            && mark != "BLANK"
            && mark != "UNRECOGNIZABLE"
            && mark != "TRANSITION"
    }

    static func firstUsableAdvance(
        continueMark: String,
        samples: [(elapsed: TimeInterval, mark: String)]
    ) -> (elapsed: TimeInterval, mark: String)? {
        samples.first { sample in
            isUsableSceneMark(sample.mark) && sample.mark != continueMark
        }
    }

    static func assertSamplesStayOnSceneBeforeAdvanceWindow(
        continueMark: String,
        samples: [(elapsed: TimeInterval, mark: String)],
        intervalSeconds: TimeInterval
    ) throws {
        try assertPresentMark(continueMark)
        let earliest = intervalSeconds - continueCaptureSlackSeconds
        for sample in samples where sample.elapsed + 0.001 < earliest {
            try assertPresentMark(sample.mark)
            if sample.mark != continueMark {
                throw AssertionError.message(
                    "Automatic photo change occurred before T-2; first check test timing and image recognition instead of immediately calling it a product bug"
                )
            }
        }
    }

    static func assertSameProcess(beforeIdentifier: Int32, afterIdentifier: Int32) throws {
        if beforeIdentifier <= 0 || afterIdentifier <= 0 {
            throw AssertionError.message("Background return is missing the original process identity")
        }
        if beforeIdentifier != afterIdentifier {
            throw AssertionError.message("System pause analog must not rebuild the process")
        }
    }

    static func assertBackgroundIdentityIsFirstSegment(
        secondsBeforeIdentity: TimeInterval,
        intervalSeconds: TimeInterval
    ) throws {
        if secondsBeforeIdentity + 0.001 >= intervalSeconds {
            throw AssertionError.message("On background return, do not wait a playback cycle before capturing identity")
        }
    }

    static func continueWatchRecordingDeadline(intervalSeconds: TimeInterval) -> TimeInterval {
        intervalSeconds + continueCaptureSlackSeconds + intervalSeconds
    }

    static func continueWatchDenseCaptureDeadline(intervalSeconds: TimeInterval) -> TimeInterval {
        min(
            intervalSeconds + continueCaptureSlackSeconds + newImageCaptureBeyondWindowSeconds,
            continueWatchRecordingDeadline(intervalSeconds: intervalSeconds)
        )
    }

    static func isAutoTransitionStart(status: String, mark: String, continueMark: String) -> Bool {
        if status == "TRANSITION" || mark == "TRANSITION" {
            return true
        }
        return isUsableSceneMark(mark) && mark != continueMark
    }

    static func isForbiddenAdvanceProxy(
        status: String,
        mark: String,
        continueMark: String,
        controlBarVisible: Bool
    ) -> Bool {
        if status == "BLACK" || mark == "BLACK" { return true }
        if status == "BLANK" || mark == "BLANK" { return true }
        if status == "UNRECOGNIZABLE" || mark == "UNRECOGNIZABLE" { return true }
        if isUsableSceneMark(mark) && mark == continueMark { return true }
        if controlBarVisible == false && mark == continueMark { return true }
        return isAutoTransitionStart(status: status, mark: mark, continueMark: continueMark) == false
    }

    static func assertBlackZoomBarOrClassificationIsNotAdvance(
        status: String,
        mark: String,
        continueMark: String,
        controlBarVisible: Bool
    ) throws {
        if isForbiddenAdvanceProxy(
            status: status,
            mark: mark,
            continueMark: continueMark,
            controlBarVisible: controlBarVisible
        ) {
            throw AssertionError.message("Black screen, zoom, control bar gone or unrecognized is not a transition")
        }
    }

    static func assertClickTimesRecordedSeparately(
        pressIssuedElapsed: TimeInterval,
        pressReturnedElapsed: TimeInterval,
        continueOriginElapsed: TimeInterval,
        usedReturnedAsOrigin: Bool
    ) throws {
        if usedReturnedAsOrigin {
            throw AssertionError.message("Do not use click return time to hide the action's elapsed time")
        }
        if pressReturnedElapsed + 0.001 < pressIssuedElapsed {
            throw AssertionError.message("The click return time must not be earlier than the press")
        }
        if abs(continueOriginElapsed - pressIssuedElapsed) > 0.001 {
            throw AssertionError.message("Do not use click return time to hide the action's elapsed time")
        }
    }

    static func assertWindowUsesRequestElapsed(
        requestElapsed: TimeInterval,
        returnElapsed: TimeInterval,
        classifiedElapsed: TimeInterval,
        elapsedUsedForWindow: TimeInterval
    ) throws {
        if abs(elapsedUsedForWindow - requestElapsed) > 0.001 {
            throw AssertionError.message("Evidence crossing the window must not pass automatically")
        }
        if elapsedUsedForWindow == returnElapsed && returnElapsed > requestElapsed + 0.001 {
            throw AssertionError.message("Evidence crossing the window must not pass automatically")
        }
        if elapsedUsedForWindow == classifiedElapsed && classifiedElapsed > requestElapsed + 0.001 {
            throw AssertionError.message("Evidence crossing the window must not pass automatically")
        }
    }

    static func firstIdentifiableNewImage(
        continueMark: String,
        samples: [ContinueWatchSample]
    ) -> ContinueWatchSample? {
        samples.first { sample in
            sample.status == "MATCH" && isUsableSceneMark(sample.mark) && sample.mark != continueMark
        }
    }

    static func firstStableNewImage(
        continueMark: String,
        samples: [ContinueWatchSample],
        minimumStableSeconds: TimeInterval = newStableMarkConfirmWindow
    ) -> ContinueWatchSample? {
        guard minimumStableSeconds.isFinite, minimumStableSeconds > 0 else { return nil }
        var candidate: ContinueWatchSample?
        var previous: ContinueWatchSample?
        for sample in samples {
            guard sample.requestElapsed.isFinite, sample.returnElapsed.isFinite,
                sample.returnElapsed >= sample.requestElapsed,
                sample.meanLuma.isFinite
            else { return nil }
            if let previous {
                if sample.requestElapsed < previous.returnElapsed { return nil }
                if sample.requestElapsed - previous.returnElapsed > newStableMarkPollInterval + 0.001 {
                    candidate = nil
                }
            }
            previous = sample
            guard isUsableSceneMark(sample.mark),
                isConfirmedNewStableMark(
                    status: sample.status, mark: sample.mark, candidateMark: sample.mark,
                    initialMark: continueMark, meanLuma: sample.meanLuma
                )
            else {
                candidate = nil
                continue
            }
            if candidate?.mark != sample.mark { candidate = sample }
            if let candidate,
                sample.requestElapsed - candidate.returnElapsed >= minimumStableSeconds
            {
                return sample
            }
        }
        return nil
    }

    static func assertIPadPauseTimingEvidence(
        continueMark: String,
        baselineLuma: Double,
        samples: [ContinueWatchSample],
        intervalSeconds: TimeInterval,
        pressReturnedElapsed: TimeInterval = 0
    ) throws -> IPadPauseTimingEvidence {
        guard intervalSeconds.isFinite, intervalSeconds > 0,
            baselineLuma.isFinite, baselineLuma > 0.1,
            pressReturnedElapsed.isFinite, (0...2).contains(pressReturnedElapsed)
        else {
            throw AssertionError.message("iPad pause-continue lacks valid timing or original photo brightness evidence")
        }
        guard samples.count >= 2 else {
            throw AssertionError.message("iPad pause-continue is missing verifiable old-photo and transition samples")
        }

        for index in samples.indices {
            let sample = samples[index]
            guard sample.requestElapsed.isFinite, sample.returnElapsed.isFinite,
                sample.classifiedElapsed.isFinite, sample.meanLuma.isFinite,
                sample.returnElapsed >= sample.requestElapsed,
                sample.returnElapsed - sample.requestElapsed <= 1.001
            else {
                throw AssertionError.message("iPad pause-continue samples contain invalid timing or brightness")
            }
            if index > 0 {
                let previous = samples[index - 1]
                let gap = sample.requestElapsed - previous.returnElapsed
                guard gap >= 0, gap <= newStableMarkPollInterval + 0.001 else {
                    throw AssertionError.message("iPad pause-continue samples are out of order or have a gap")
                }
            }
        }

        let dimmingThreshold = baselineLuma * 0.95
        var startIndex: Int?
        for index in 1..<samples.count {
            let sample = samples[index]
            let isTransitionMarker = sample.status == "TRANSITION" || sample.mark == "TRANSITION"
            let isDifferentImage =
                sample.status == "MATCH"
                && isUsableSceneMark(sample.mark)
                && sample.mark != continueMark
            let isSustainedDimming =
                sample.status == "MATCH"
                && sample.mark == continueMark
                && sample.meanLuma < dimmingThreshold
                && hasSustainedIPadDimming(
                    from: index,
                    continueMark: continueMark,
                    threshold: dimmingThreshold,
                    samples: samples
                )
            if isTransitionMarker || isDifferentImage || isSustainedDimming {
                startIndex = index
                break
            }
        }
        guard let startIndex, startIndex > 0 else {
            throw AssertionError.message("iPad pause-continue: no transition start via sustained dimming or new photo")
        }
        let start = samples[startIndex]
        let previous = samples[startIndex - 1]
        guard samples[..<startIndex].allSatisfy({ $0.status == "MATCH" && $0.mark == continueMark }),
            previous.status == "MATCH", previous.mark == continueMark,
            previous.controlBarVisible == start.controlBarVisible,
            previous.meanLuma.isFinite, previous.meanLuma >= newStableMarkMinimumLuma,
            previous.requestElapsed.isFinite, previous.returnElapsed.isFinite,
            start.requestElapsed.isFinite, start.returnElapsed.isFinite,
            previous.returnElapsed >= previous.requestElapsed,
            start.returnElapsed >= start.requestElapsed,
            start.requestElapsed >= previous.returnElapsed
        else {
            throw AssertionError.message(
                "A continuous, reliable screenshot of the previous photo must precede the iPad transition start; previous[index=\(startIndex - 1), requestElapsed=\(previous.requestElapsed), returnElapsed=\(previous.returnElapsed), status=\(previous.status), mark=\(previous.mark), meanLuma=\(previous.meanLuma)]; start[index=\(startIndex), requestElapsed=\(start.requestElapsed), returnElapsed=\(start.returnElapsed), status=\(start.status), mark=\(start.mark), meanLuma=\(start.meanLuma)]"
            )
        }
        let earliestTransitionElapsed = previous.requestElapsed - pressReturnedElapsed
        let latestTransitionElapsed = start.returnElapsed
        let earliestAllowed = intervalSeconds - continueCaptureSlackSeconds
        let latestAllowed = intervalSeconds + continueCaptureSlackSeconds
        if earliestTransitionElapsed + 0.001 < earliestAllowed
            || latestTransitionElapsed > latestAllowed + 0.001
        {
            throw AssertionError.message("iPad transition: conservative screenshot range must lie fully within T±2 s")
        }
        guard
            let stable = firstStableNewImage(
                continueMark: continueMark,
                samples: samples,
                minimumStableSeconds: ipadNewStableMarkConfirmWindow
            ), stable.requestElapsed + 0.001 >= start.requestElapsed
        else {
            throw AssertionError.message("iPad must keep identifying a different new photo for at least 1 second")
        }
        let stableImageDelaySeconds = stable.returnElapsed - start.requestElapsed
        if !stableImageDelaySeconds.isFinite || stableImageDelaySeconds < 0
            || stableImageDelaySeconds > ipadStableImageDeadlineAfterTransition + 0.001
        {
            throw AssertionError.message("iPad new photo must be stably identifiable within 4 s of transition start")
        }
        return IPadPauseTimingEvidence(
            earliestTransitionElapsed: earliestTransitionElapsed,
            latestTransitionElapsed: latestTransitionElapsed,
            transitionStartRequestElapsed: start.requestElapsed,
            stableImageRequestElapsed: stable.requestElapsed,
            stableImageReturnElapsed: stable.returnElapsed,
            stableImageDelaySeconds: stableImageDelaySeconds
        )
    }

    private static func hasSustainedIPadDimming(
        from startIndex: Int,
        continueMark: String,
        threshold: Double,
        samples: [ContinueWatchSample]
    ) -> Bool {
        guard startIndex + 2 < samples.count else { return false }
        var previous = samples[startIndex]
        for index in (startIndex + 1)...(startIndex + 2) {
            let sample = samples[index]
            let gap = sample.requestElapsed - previous.returnElapsed
            guard sample.status == "MATCH", sample.mark == continueMark,
                sample.meanLuma.isFinite, sample.meanLuma < threshold,
                sample.meanLuma < previous.meanLuma - 0.001,
                sample.controlBarVisible == previous.controlBarVisible,
                gap >= 0, gap <= newStableMarkPollInterval + 0.001
            else {
                return false
            }
            previous = sample
        }
        return true
    }

    static func assertIdentifiableNewImagePresent(
        continueMark: String,
        confirmedMark: String?,
        confirmedStatus: String?
    ) throws {
        try assertPresentMark(continueMark)
        guard let confirmedMark, let confirmedStatus else {
            throw AssertionError.message("Black screen without a new photo must not pass automatically")
        }
        if confirmedStatus != "MATCH" || isUsableSceneMark(confirmedMark) == false || confirmedMark == continueMark {
            throw AssertionError.message("Black screen without a new photo must not pass automatically")
        }
        try assertPresentMark(confirmedMark)
    }

    static func assertRecordingDidNotStopAtIdentityTimeout(
        lastSampleRequestElapsed: TimeInterval,
        confirmedNewImage: Bool,
        intervalSeconds: TimeInterval
    ) throws {
        let identityTimeout = intervalSeconds + continueCaptureSlackSeconds
        if confirmedNewImage {
            return
        }
        if lastSampleRequestElapsed <= identityTimeout + 0.001 {
            throw AssertionError.message("Record until a new photo is identifiable, not until the T+2 identity timeout")
        }
    }

    static func assessFirstTransitionStart(
        continueMark: String,
        baselineLuma: Double?,
        samples: [ContinueWatchSample],
        intervalSeconds: TimeInterval
    ) -> FirstTransitionStartVerdict {
        let earliest = intervalSeconds - continueCaptureSlackSeconds
        let latest = intervalSeconds + continueCaptureSlackSeconds
        let ordered = samples.sorted { $0.requestElapsed < $1.requestElapsed }

        func hasUncertainSignal(_ sample: ContinueWatchSample) -> Bool {
            if sample.requestElapsed + 0.001 < earliest || sample.requestElapsed > latest {
                return false
            }
            if sample.status == "UNRECOGNIZABLE" || sample.mark == "UNRECOGNIZABLE" {
                return true
            }
            if sample.status == "BLACK" || sample.mark == "BLACK" {
                return true
            }
            if let baselineLuma,
                isUsableSceneMark(sample.mark),
                sample.mark == continueMark,
                baselineLuma - sample.meanLuma >= uncertainSameMarkLumaDrop
            {
                return true
            }
            return false
        }

        guard
            let firstStart = ordered.first(where: { sample in
                isAutoTransitionStart(status: sample.status, mark: sample.mark, continueMark: continueMark)
            })
        else {
            if ordered.contains(where: hasUncertainSignal) {
                return .pendingVideoReview(reason: "Unusable changes in window; auto start cannot be reliably judged")
            }
            return .missing
        }
        if firstStart.requestElapsed + 0.001 < earliest {
            return .tooEarly(requestElapsed: firstStart.requestElapsed, mark: firstStart.mark)
        }
        if firstStart.requestElapsed > latest {
            let earlierUncertain = ordered.contains { sample in
                sample.requestElapsed + 0.001 < firstStart.requestElapsed && hasUncertainSignal(sample)
            }
            if earlierUncertain {
                return .pendingVideoReview(reason: "No usable start in window; post-window new photo does not count")
            }
            return .tooLate(requestElapsed: firstStart.requestElapsed, mark: firstStart.mark)
        }
        return .detected(
            requestElapsed: firstStart.requestElapsed,
            mark: firstStart.mark,
            status: firstStart.status
        )
    }

    static func assertFirstTransitionStartInWindow(
        continueMark: String,
        startMark: String,
        startStatus: String,
        elapsedSeconds: TimeInterval,
        intervalSeconds: TimeInterval
    ) throws {
        try assertPresentMark(continueMark)
        try assertBlackZoomBarOrClassificationIsNotAdvance(
            status: startStatus,
            mark: startMark,
            continueMark: continueMark,
            controlBarVisible: true
        )
        if isAutoTransitionStart(status: startStatus, mark: startMark, continueMark: continueMark) == false {
            throw AssertionError.message("Black screen, zoom, control bar gone or unrecognized is not a transition")
        }
        let earliest = intervalSeconds - continueCaptureSlackSeconds
        let latest = intervalSeconds + continueCaptureSlackSeconds
        if elapsedSeconds > latest {
            throw AssertionError.message(
                "No automatic photo change was captured within T±2; if waiting for idleness crossed the window, classify this as a test timing failure"
            )
        }
        if elapsedSeconds < earliest {
            throw AssertionError.message(
                "Automatic photo change occurred before T-2; first check test timing and image recognition instead of immediately calling it a product bug"
            )
        }
    }

    static func assertFirstTransitionStartOfficialPass(
        verdict: FirstTransitionStartVerdict,
        officialSigned: Bool
    ) throws {
        switch verdict {
        case .detected:
            if officialSigned == false {
                throw AssertionError.message("An in-window start was detected but not signed off")
            }
        case .pendingVideoReview:
            if officialSigned {
                throw AssertionError.message(
                    "Uncertain samples must remain pending video review; do not default to PASS")
            }
        case .tooEarly, .tooLate, .missing:
            if officialSigned {
                throw AssertionError.message("Too early/late transition or missing start cannot pass automatically")
            }
        }
    }

    static func officialStartSigned(
        for verdict: FirstTransitionStartVerdict,
        continueMark: String,
        intervalSeconds: TimeInterval
    ) throws -> Bool {
        switch verdict {
        case .detected(let elapsed, let mark, let status):
            try assertFirstTransitionStartInWindow(
                continueMark: continueMark,
                startMark: mark,
                startStatus: status,
                elapsedSeconds: elapsed,
                intervalSeconds: intervalSeconds
            )
            try assertFirstTransitionStartOfficialPass(verdict: verdict, officialSigned: true)
            return true
        case .pendingVideoReview:
            try assertFirstTransitionStartOfficialPass(verdict: verdict, officialSigned: false)
            return false
        case .tooEarly:
            throw AssertionError.message(
                "Automatic photo change occurred before T-2; first check test timing and image recognition instead of immediately calling it a product bug"
            )
        case .tooLate, .missing:
            throw AssertionError.message(
                "No automatic photo change was captured within T±2; if waiting for idleness crossed the window, classify this as a test timing failure"
            )
        }
    }

    private static func areSettingValuesEqual(_ left: Any, _ right: Any) -> Bool {
        String(describing: left) == String(describing: right)
    }
}
