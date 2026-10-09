import Foundation

// Access-lifecycle contract shared by all three platforms. Launch arguments must not stand in for the real settings entry
// or for real persistence; the PIN must never appear in evidence.

enum AccessLifecycleContract {
    static let sha256HexCharacterCount: Int = 64
    static let timingToleranceSeconds: TimeInterval = TestWait.seconds(.product(0.001))
    static let luminanceTolerance: Double = 0.001
    static let minimumBaselineLuminance: Double = 0.1
    static let maximumPressReturnDelaySeconds: TimeInterval = TestWait.seconds(.product(2))
    static let sustainedDimmingLuminanceRatio: Double = 0.95
    static let requiredConsecutiveDimmingSampleCount: Int = 3

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
    static let newStableMarkPollInterval: TimeInterval = TestWait.seconds(.product(0.1))
    static let newStableMarkConfirmWindow: TimeInterval = TestWait.seconds(.product(0.8))
    static let ipadNewStableMarkConfirmWindow: TimeInterval = TestWait.seconds(.product(1.0))
    static let ipadStableImageDeadlineAfterTransition: TimeInterval = TestWait.seconds(.product(4.0))
    static let newStableMarkMinimumLuma: Double = 0.20
    // Wake evidence must finish before the next automatic photo change; 2.5s covers one screenshot, a tap and
    // another screenshot.
    static let wakeEvidenceBudgetSeconds: TimeInterval = TestWait.seconds(.product(2.5))

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
            if !isSettingValueEqual(beforeValue, afterValue) {
                throw AssertionError.message("Settings were not persisted")
            }
        }
        let defaults: [String: Any] = [
            "autoPlayEnabled": true,
            "intervalSeconds": 5,
            "showExif": true,
            "displayMode": "smartFill"
        ]
        let hasUnchangedDefaults = defaults.keys.allSatisfy { key in
            guard let beforeValue = before[key], let defaultValue = defaults[key] else {
                return false
            }
            return isSettingValueEqual(beforeValue, defaultValue)
        }
        if hasUnchangedDefaults {
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

    static func assertAutoPlayEnabledAtBackground(_ isEnabled: Bool) throws {
        if !isEnabled {
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

    static func hasMeasuredProgress(_ raw: String) -> Bool {
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
        didEnterWrongPin: Bool,
        isProtectedAfterCancel: Bool,
        didEnterCorrectPin: Bool,
        isGatedAfterRestart: Bool
    ) throws {
        if didEnterWrongPin {
            throw AssertionError.message("Getting in with a wrong PIN must not count as a pass")
        }
        if !isProtectedAfterCancel {
            throw AssertionError.message("Protection disappearing after cancel must not count as a pass")
        }
        if !didEnterCorrectPin {
            throw AssertionError.message("The correct PIN must open settings")
        }
        if !isGatedAfterRestart {
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

    static func assertReturnedToSlideshow(identifiers: [String], shouldRequireSettingsButton: Bool) throws {
        if shouldRequireSettingsButton {
            throw AssertionError.message("Returning to playback must not require the control bar to be visible")
        }
        if isSlideshowLayer(identifiers: identifiers) == false {
            throw AssertionError.message("Returning to playback must confirm the playback layer")
        }
    }

    // When the PIN gate blocks the settings page, requiring the playback settings button first must fail.
    static func assertSettingsOpen(identifiers: [String], shouldRequirePlaybackItem: Bool) throws {
        let isPinPresent = identifiers.contains { $0.hasPrefix("pinEntry.") }
        let isSettingsPresent = identifiers.contains { $0.hasPrefix("settings.") }
        if isPinPresent == false && isSettingsPresent == false {
            throw AssertionError.message("After opening settings, the PIN gate or the settings page must be confirmed")
        }
        if isPinPresent && shouldRequirePlaybackItem {
            throw AssertionError.message("Playback settings must not be required while the PIN gate is still up")
        }
    }

    // Only one direction key press is allowed after returning from settings, and only after the playback page
    // transition completes and the hidden receiver holds focus stably.
    static func assertSettingsReturnWake(
        identifiers: [String],
        isTransitionComplete: Bool,
        isHiddenWakeReceiverFocused: Bool,
        isHiddenWakeReceiverFocusStable: Bool,
        consecutiveFocusedObservations: Int,
        directionalPressCount: Int,
        beforeScreenshot: String,
        afterScreenshot: String
    ) throws {
        try assertReturnedToSlideshow(identifiers: identifiers, shouldRequireSettingsButton: false)
        if isTransitionComplete == false {
            throw AssertionError.message("After settings return, no direction key until the transition completes")
        }
        if isHiddenWakeReceiverFocused == false
            || isHiddenWakeReceiverFocusStable == false
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
        didRebuildProcess: Bool,
        didHomeLeaveAppRunning: Bool
    ) throws {
        if activation != allowedSystemPauseActivation {
            throw AssertionError.message("System pause analog must activate the existing process, not Open or rebuild")
        }
        if didRebuildProcess {
            throw AssertionError.message("System pause analog must not rebuild the process")
        }
        if didHomeLeaveAppRunning == false {
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
    static func pinStorageVerdict(storageKind: String, isXCTestConfigPresent: Bool) throws -> String {
        if storageKind == "keychain" && isXCTestConfigPresent {
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

    static func assertPresentMark(_ mark: String) throws {
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

    static func assertNoRetryMasking(_ didUseRetriesToPass: Bool) throws {
        if didUseRetriesToPass {
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
        if pngSHA256Before.count != sha256HexCharacterCount || pngSHA256After.count != sha256HexCharacterCount
            || pngSHA256Before == pngSHA256After
        {
            throw AssertionError.message("A display strategy that did not take effect must not count as a pass")
        }
    }

    static func assertIPadLicenseReturn(device: String, isStackPreserved: Bool) throws {
        if device != "ipad" {
            return
        }
        if !isStackPreserved {
            throw AssertionError.message("Losing the iPad open-source licenses back stack must not count as a pass")
        }
    }
}
