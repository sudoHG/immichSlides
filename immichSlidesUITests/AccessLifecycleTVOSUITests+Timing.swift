import XCTest
import ImageIO

#if os(tvOS)
// These metrics are derived offline from one decoded PNG, independently of public-photo identity.
private enum TVOSContinuePhotoCapture {
    static let requiredMark = "A1"
    static let expectedWidthPixels = 3840
    static let expectedHeightPixels = 2160
    static let photoRightFraction = 0.72
    static let photoBottomFraction = 0.78
    static let highlightPercentile = 0.95
    static let whiteChannelMinimum = 254
    static let plateauHighlightLuma = 255
    static let minimumDimHighlightDrop = 3
    static let proofHighlightRatio = 0.95
    static let minimumMeanDrop = 0.030
    static let minimumWhiteCoreFraction = 0.06
    static let maximumAnchorToProofRequestSeconds = TestWait.seconds(.product(1))

    static func policy(isSinglePhoto: Bool) -> AccessLifecycleContract.TVOSFadeRescuePolicy {
        .init(
            requiredMark: requiredMark, isSinglePhotoModeVerified: isSinglePhoto,
            plateauHighlightLuma: plateauHighlightLuma, minimumDimHighlightDrop: minimumDimHighlightDrop,
            proofHighlightRatio: proofHighlightRatio, minimumMeanDrop: minimumMeanDrop,
            minimumWhiteCoreFraction: minimumWhiteCoreFraction,
            maximumAnchorToProofRequestSeconds: maximumAnchorToProofRequestSeconds,
            maximumAnchorToProofReturnSeconds: AccessLifecycleContract.TVOSPhotoMotionBounds.maximumSpanSeconds)
    }

    static func pixels(png: Data) -> AccessLifecycleContract.TVOSPhotoPixels? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            image.width == expectedWidthPixels, image.height == expectedHeightPixels,
            let full = bitmap(image: image, width: image.width, height: image.height, isFlipped: false),
            let mean = identityMean(image: image)
        else { return nil }
        let width = Int(Double(image.width) * photoRightFraction)
        let height = Int(Double(image.height) * photoBottomFraction)
        let stride = width + 1
        var integral = [Int32](repeating: 0, count: stride * (height + 1))
        var histogram = [Int](repeating: 0, count: 256)
        for row in 0..<height {
            var whiteCount: Int32 = 0
            for column in 0..<width {
                let offset = (row * image.width + column) * 4
                let red = full[offset]
                let green = full[offset + 1]
                let blue = full[offset + 2]
                let luma = Int((0.299 * Double(red) + 0.587 * Double(green) + 0.114 * Double(blue)).rounded())
                histogram[luma] += 1
                if Int(min(red, green, blue)) >= whiteChannelMinimum { whiteCount += 1 }
                integral[(row + 1) * stride + column + 1] = integral[row * stride + column + 1] + whiteCount
            }
        }
        let pixelCount = width * height
        let target = Int(ceil(Double(pixelCount) * highlightPercentile))
        var accumulated = 0
        let highlight = histogram.indices.first { index in
            accumulated += histogram[index]
            return accumulated >= target
        }
        let erosion = AccessLifecycleContract.TVOSPhotoMotionBounds.whiteCoreErosionFractionPerAxis
        let radiusX = Int(ceil(Double(image.width) * erosion))
        let radiusY = Int(ceil(Double(image.height) * erosion))
        let kernelPixelCount = Int32((2 * radiusX + 1) * (2 * radiusY + 1))
        var corePixelCount = 0
        for row in radiusY..<(height - radiusY) {
            for column in radiusX..<(width - radiusX) {
                let top = (row - radiusY) * stride
                let bottom = (row + radiusY + 1) * stride
                let left = column - radiusX
                let right = column + radiusX + 1
                let covered =
                    integral[bottom + right] - integral[top + right]
                    - integral[bottom + left] + integral[top + left]
                if covered == kernelPixelCount { corePixelCount += 1 }
            }
        }
        return .init(
            highlightLuma: highlight, whiteCoreFraction: Double(corePixelCount) / Double(pixelCount),
            decodedMeanLuma: mean)
    }

    private static func bitmap(image: CGImage, width: Int, height: Int, isFlipped: Bool) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .low
            if isFlipped {
                context.translateBy(x: 0, y: CGFloat(height))
                context.scaleBy(x: 1, y: -1)
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }

    // Match the existing reader's sampling exactly, using the same CGImage as the photo metrics.
    private static func identityMean(image: CGImage) -> Double? {
        let width = 96
        let height = max(8, Int((Double(width) * Double(image.height) / Double(image.width)).rounded(.down)))
        guard let bytes = bitmap(image: image, width: width, height: height, isFlipped: true) else { return nil }
        var sum = 0.0
        for row in 0..<height where row <= Int(Double(height) * 0.86) {
            for column in 0..<width {
                if column > Int(Double(width) * 0.72) && row < Int(Double(height) * 0.22) { continue }
                let offset = (row * width + column) * 4
                sum +=
                    (0.299 * Double(bytes[offset]) + 0.587 * Double(bytes[offset + 1])
                        + 0.114 * Double(bytes[offset + 2])) / 255
            }
        }
        return sum / Double(max(1, Int(Double(width * height) * 0.86 * 0.85)))
    }
}

// Pixel decoding stays off the capture cadence; only the bounded observation state shares this lock.
private final class TVOSControlBarProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "immichSlides.tests.controlBarProbe")
    private let lock = NSLock()
    private let reference: StrictE2EPhotoIdentity.ControlBarReference
    private var hasPendingProbe = false
    private var hasObservedVisible = false
    private var hasObservedAutoHide = false

    init(reference: StrictE2EPhotoIdentity.ControlBarReference) {
        self.reference = reference
    }

    var didObserveAutoHide: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasObservedAutoHide
    }

    func submit(png: Data) {
        lock.lock()
        guard hasPendingProbe == false, hasObservedAutoHide == false else {
            lock.unlock()
            return
        }
        hasPendingProbe = true
        lock.unlock()
        queue.async { [self] in
            let isVisible = reference.isVisible(png: png)
            lock.lock()
            defer { lock.unlock() }
            hasPendingProbe = false
            if isVisible == true { hasObservedVisible = true }
            if isVisible == false, hasObservedVisible { hasObservedAutoHide = true }
        }
    }
}

extension AccessLifecycleTVOSUITests {
    @MainActor
    func assertTVOSNarrowEntryHasNoPin(app: XCUIApplication) throws {
        XCTAssertFalse(
            app.buttons["pinEntry.close.button"].waitForFailureEvidence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.readbackTimeoutSeconds),
            "This narrow entry must not enable a password."
        )
    }

    @MainActor
    func enterPlaybackSettings(app: XCUIApplication) throws {
        openSettingsFromSlideShow(app: app)
        record("settings.open")
        try assertTVOSNarrowEntryHasNoPin(app: app)
        let playbackItem = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            playbackItem.waitForPublicElement(
                "settings.item.playback",
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Settings home must show playback settings.")
        if playbackItem.hasFocus == false {
            moveFocus(.up, to: playbackItem, maximumPresses: 4, message: "Must return to playback settings.")
        }
        FirstFailureRemote.press(.select)
    }

    // Page identity comes from playback settings content; a momentary lack of focus is not treated as home.
    // After entering, focus must still land on the autoplay row.
    @MainActor
    func ensureInsidePlaybackSettingsPage(app: XCUIApplication) throws {
        var isHomeUniqueVisible = isTVOSHomeUniqueVisible(app: app)
        var isPlaybackSettingsContentVisible = isTVOSPlaybackSettingsContentVisible(app: app)
        var isSettingsHomeVisible = app.buttons["settings.item.playback"].isHittable
        if isPlaybackSettingsContentVisible == false && isSettingsHomeVisible == false && isHomeUniqueVisible == false {
            waitForFocusVisualSettle()
            isHomeUniqueVisible = isTVOSHomeUniqueVisible(app: app)
            isPlaybackSettingsContentVisible = isTVOSPlaybackSettingsContentVisible(app: app)
            isSettingsHomeVisible = app.buttons["settings.item.playback"].isHittable
        }
        let identity = AccessLifecycleContract.tvosSettingsPageIdentity(
            isPlaybackSettingsContentVisible: isPlaybackSettingsContentVisible,
            isHomeEntryVisible: isSettingsHomeVisible,
            isHomeUniqueVisible: isHomeUniqueVisible
        )
        try AccessLifecycleContract.assertTVOSHomeUniqueBeatsPlaybackRowLabel(
            isHomeUniqueVisible: isHomeUniqueVisible,
            isClassifiedAsPlayback: identity == "playback"
        )
        try AccessLifecycleContract.assertTVOSPageIdentityNotInferredFromMissingFocus(
            isPlaybackSettingsContentVisible: isPlaybackSettingsContentVisible && isHomeUniqueVisible == false,
            isClassifiedAsHome: identity == "home"
        )
        let homePlayback = app.buttons["settings.item.playback"]
        if identity == "home" {
            XCTAssertTrue(
                homePlayback.waitForPublicElement(
                    "settings.item.playback",
                    timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
                "Settings home must show playback settings.")
            if homePlayback.hasFocus == false {
                moveFocus(.up, to: homePlayback, maximumPresses: 6, message: "Must go back to playback settings entry.")
            }
            XCTAssertTrue(homePlayback.hasFocus, "Settings home must focus playback settings before entering.")
            FirstFailureRemote.press(.select)
            waitForFocusVisualSettle()
        }
        let autoPlayLink = app.buttons["settings.playback.autoPlay.link"]
        XCTAssertTrue(
            autoPlayLink.waitForFailureEvidence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Playback settings must show the autoplay row.")
        if autoPlayLink.hasFocus == false {
            _ = tryMoveFocus(.up, to: autoPlayLink, maximumPresses: 8)
        }
        if autoPlayLink.hasFocus == false {
            _ = tryMoveFocus(.down, to: autoPlayLink, maximumPresses: 8)
        }
        try AccessLifecycleContract.assertTVOSPlaybackSettingsEntered(
            isAutoPlayLinkFocused: autoPlayLink.hasFocus,
            isHomePlaybackFocused: homePlayback.exists && homePlayback.hasFocus
        )
    }

    @MainActor
    func isTVOSHomeUniqueVisible(app: XCUIApplication) -> Bool {
        app.buttons["settings.item.accessProtection"].isHittable
            || app.descendants(matching: .any)["settings.item.playback"].isHittable
    }

    // The home page row also shows the "Playback Settings" text, so it does not mean the page was entered.
    @MainActor
    func isTVOSPlaybackSettingsContentVisible(app: XCUIApplication) -> Bool {
        app.buttons["settings.playback.autoPlay.link"].isHittable
            || app.descendants(matching: .any)["settings.playback.autoPlay.link"].isHittable
    }

    @MainActor
    func readTVOSFourSettings(app: XCUIApplication) throws -> [String: Any] {
        try enterPlaybackSettings(app: app)
        let autoPlayEnabled = try selectedBinaryOption(
            app: app,
            link: "settings.playback.autoPlay.link",
            onOption: "settings.playback.autoPlay.on.button",
            offOption: "settings.playback.autoPlay.off.button",
            stepsToLink: 0
        )
        let intervalSeconds = try selectedIntervalSeconds(app: app)
        let displayMode = try selectedDisplayMode(app: app)
        let showExif = try selectedBinaryOption(
            app: app,
            link: "settings.playback.showExif.link",
            onOption: "settings.playback.showExif.on.button",
            offOption: "settings.playback.showExif.off.button",
            stepsToLink: 0,
            openParentLink: "settings.playback.display.link"
        )
        return [
            "autoPlayEnabled": autoPlayEnabled,
            "intervalSeconds": intervalSeconds,
            "showExif": showExif,
            "displayMode": displayMode
        ]
    }

    @MainActor
    func changeTVOSFourSettingsFromInitial(
        app: XCUIApplication,
        initial: [String: Any]
    ) throws -> [String: Any] {
        let isInitiallyAutoPlayEnabled = initial["autoPlayEnabled"] as? Bool ?? true
        let initialInterval = initial["intervalSeconds"] as? Int ?? Int(TestWait.seconds(.product(5)))
        let isInitiallyExifEnabled = initial["showExif"] as? Bool ?? true
        let initialMode = initial["displayMode"] as? String ?? "smartFill"
        let intervalTarget =
            initialInterval == AccessLifecycleContract.tvOSRequestedIntervalSeconds
            ? 15 : AccessLifecycleContract.tvOSRequestedIntervalSeconds

        try ensureInsidePlaybackSettingsPage(app: app)
        selectPlaybackToggle(
            app: app,
            link: "settings.playback.interval.link",
            option: "settings.playback.interval.\(intervalTarget).button",
            stepsToLink: 2
        )
        record("settings.save.interval")
        // After the interval Menu, go back to the autoplay row first, then search down for display mode.
        try ensureInsidePlaybackSettingsPage(app: app)
        selectPlaybackToggle(
            app: app,
            link: "settings.playback.displayMode.link",
            option: initialMode == "smartFill"
                ? "settings.playback.displayMode.singlePhoto.button"
                : "settings.playback.displayMode.smartFill.button",
            stepsToLink: 4
        )
        record("settings.save.display_mode")
        // After the display mode Menu the target is above: move up to autoplay first; pressing only down is
        // not allowed. EXIF lives in the display items subpage, so the generic return to playback settings
        // does not apply here.
        try AccessLifecycleContract.assertTVOSFocusSearchMustNotUseOnlyDownWhenTargetAbove(
            didTargetAppearAboveFocus: true,
            didUseOnlyDown: false
        )
        try ensureInsidePlaybackSettingsPage(app: app)
        selectPlaybackToggle(
            app: app,
            link: "settings.playback.autoPlay.link",
            option: isInitiallyAutoPlayEnabled
                ? "settings.playback.autoPlay.off.button"
                : "settings.playback.autoPlay.on.button",
            stepsToLink: 0
        )
        record("settings.save.autoplay")

        moveFocusToSettingsControl(app: app, identifier: "settings.playback.display.link", maxSteps: 7)
        FirstFailureRemote.press(.select)
        selectPlaybackToggle(
            app: app,
            link: "settings.playback.showExif.link",
            option: isInitiallyExifEnabled
                ? "settings.playback.showExif.off.button"
                : "settings.playback.showExif.on.button",
            stepsToLink: 0
        )
        record("settings.save.exif")
        FirstFailureRemote.press(.menu)
        waitForFocusVisualSettle()
        returnToSlideShow(app: app)
        return try readTVOSFourSettings(app: app)
    }

    @MainActor
    func configureTVOSTimingPlaybackSettings(
        app: XCUIApplication
    ) throws -> (actual: Int, shouldRequireIntervalReview: Bool, isSinglePhotoModeVerified: Bool) {
        try enterPlaybackSettings(app: app)
        selectPlaybackToggle(
            app: app,
            link: "settings.playback.autoPlay.link",
            option: "settings.playback.autoPlay.on.button",
            stepsToLink: 0
        )
        record("settings.save.autoplay")
        // When the requested interval is unavailable, the substituted interval needs a desktop closeout run.
        let resolved = try AccessLifecycleContract.resolveTimingInterval(
            requested: AccessLifecycleContract.tvOSRequestedIntervalSeconds,
            available: AccessLifecycleContract.tvOSSelectableIntervals
        )
        selectPlaybackToggle(
            app: app,
            link: "settings.playback.interval.link",
            option: "settings.playback.interval.\(resolved.actual).button",
            stepsToLink: 2
        )
        record("settings.save.interval")
        let isSinglePhotoModeVerified = selectPlaybackToggle(
            app: app,
            link: "settings.playback.displayMode.link",
            option: "settings.playback.displayMode.singlePhoto.button",
            stepsToLink: 4
        )
        record("settings.save.display_mode")
        FirstFailureRemote.press(.menu)
        waitForFocusVisualSettle()
        returnToSlideShow(app: app)
        return (resolved.actual, resolved.shouldRequireIntervalReview, isSinglePhotoModeVerified)
    }

    @MainActor
    func selectedBinaryOption(
        app: XCUIApplication,
        link: String,
        onOption: String,
        offOption: String,
        stepsToLink: Int,
        openParentLink: String? = nil
    ) throws -> Bool {
        if let parent = openParentLink {
            moveFocusToSettingsControl(app: app, identifier: parent, maxSteps: 7)
            FirstFailureRemote.press(.select)
            waitForFocusVisualSettle()
        }
        moveFocusToSettingsControl(app: app, identifier: link, maxSteps: max(stepsToLink, 6))
        FirstFailureRemote.press(.select)
        let onButton = app.buttons[onOption]
        let offButton = app.buttons[offOption]
        XCTAssertTrue(
            onButton.waitForFailureEvidence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds)
                || offButton.waitForFailureEvidence(
                    timeout: AccessLifecycleTVOSUITestsWaitTiming.readbackTimeoutSeconds),
            "Must read the toggle options."
        )
        let isOn = onButton.exists && valueContainsSelected(onButton)
        FirstFailureRemote.press(.menu)
        waitForFocusVisualSettle()
        if openParentLink != nil {
            FirstFailureRemote.press(.menu)
            waitForFocusVisualSettle()
        }
        return isOn
    }

    @MainActor
    func selectedIntervalSeconds(app: XCUIApplication) throws -> Int {
        moveFocusToSettingsControl(app: app, identifier: "settings.playback.interval.link", maxSteps: 6)
        FirstFailureRemote.press(.select)
        var selected = 0
        for seconds in AccessLifecycleContract.tvOSSelectableIntervals {
            let button = app.buttons["settings.playback.interval.\(seconds).button"]
            if button.waitForFailureEvidence(timeout: AccessLifecycleTVOSUITestsWaitTiming.briefElementTimeoutSeconds)
                && valueContainsSelected(button)
            {
                selected = seconds
                break
            }
        }
        FirstFailureRemote.press(.menu)
        waitForFocusVisualSettle()
        if selected == 0 {
            throw AccessLifecycleContract.AssertionError.message("Missing settings evidence")
        }
        return selected
    }

    @MainActor
    func selectedDisplayMode(app: XCUIApplication) throws -> String {
        moveFocusToSettingsControl(app: app, identifier: "settings.playback.displayMode.link", maxSteps: 6)
        FirstFailureRemote.press(.select)
        let single = app.buttons["settings.playback.displayMode.singlePhoto.button"]
        XCTAssertTrue(
            single.waitForFailureEvidence(
                timeout: AccessLifecycleTVOSUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Must be able to read the display mode.")
        let mode = valueContainsSelected(single) ? "singlePhoto" : "smartFill"
        FirstFailureRemote.press(.menu)
        waitForFocusVisualSettle()
        return mode
    }

    @MainActor
    func exerciseTVOSPauseNextContinueVisibleTiming(
        app: XCUIApplication,
        playPauseButton: XCUIElement,
        nextButton: XCUIElement,
        intervalSeconds: Int,
        isSinglePhotoModeVerified: Bool
    ) throws -> [[String: Any]] {
        let interval = TimeInterval(intervalSeconds)
        let midpointSetupAt = Date()
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        moveFocus(.right, to: playPauseButton, maximumPresses: 3, message: "Focus must reach play/pause.")
        // Pool both control/focus allocations, conditional readback and half-cycle under one deadline.
        let value = String(describing: playPauseButton.value ?? "")
        let isPlaying = value.contains("暂停") || value.lowercased().contains("pause")
        let midpointDeadline = midpointSetupAt.addingTimeInterval(
            TestWait.seconds(
                .product(
                    (isPlaying ? 0 : AccessLifecycleTVOSUITestsWaitTiming.stateChangeTimeoutSeconds)
                        + interval / 2
                        + 2
                        * (AccessLifecycleTVOSUITestsWaitTiming.settingsChangeTimeoutSeconds
                            + AccessLifecycleTVOSUITestsWaitTiming.stateChangeTimeoutSeconds + 3 * Timing.focusSettle)))
        )
        if isPlaying == false {
            FirstFailureRemote.press(.select)
            XCTAssertTrue(
                waitUntil(timeout: AccessLifecycleTVOSUITestsWaitTiming.stateChangeTimeoutSeconds) {
                    let current = String(describing: playPauseButton.value ?? "")
                    return current.contains("暂停") || current.lowercased().contains("pause")
                },
                "Must be playing before the mid-interval timing."
            )
        }
        // Settings returns at an arbitrary scene age. A newly observed stable photo anchors the half-cycle.
        let anchor = try captureTVOSMidpointAnchor(app: app, deadline: midpointDeadline)
        let midpointAt = anchor.requestedAt.addingTimeInterval(TestWait.seconds(.product(interval / 2)))
        guard midpointAt < midpointDeadline else {
            throw AccessLifecycleContract.AssertionError.message(
                "tvOS midpoint setup exhausted the original step budget before the half-cycle pause."
            )
        }
        RunLoop.current.run(until: midpointAt)
        let focusDeadline = min(
            midpointDeadline,
            anchor.requestedAt.addingTimeInterval(interval - AccessLifecycleContract.continueCaptureSlackSeconds)
        )
        var snapshots = app.evidenceSnapshotsByIdentifier()
        if snapshots[AccessLifecycleContract.hiddenControlBarPlaybackIdentifier]?.hasFocus == true {
            FirstFailureRemote.press(.up)
        }
        // Auto-hide can hand off focus while the control bar still appears visible.
        while Date() < focusDeadline && snapshots["slideshow.control.playPause.button"]?.hasFocus != true {
            snapshots = app.evidenceSnapshotsByIdentifier()
            if snapshots["slideshow.control.playPause.button"]?.hasFocus == true { break }
            RunLoop.current.run(
                until: min(focusDeadline, Date().addingTimeInterval(Timing.focusPoll)))
        }
        XCTAssertTrue(
            Date() < focusDeadline && snapshots["slideshow.control.playPause.button"]?.hasFocus == true,
            "tvOS midpoint pause requires Play/Pause focus after at most one wake within the original step budget."
        )
        let playingValue = String(describing: snapshots["slideshow.control.playPause.button"]?.value ?? "")
        FirstFailureRemote.press(.select)
        let midpointPauseReturnedAt = Date()
        var didPause = false
        while Date() < focusDeadline {
            let observation = app.evidenceSnapshotsByIdentifier()
            if let playPause = observation["slideshow.control.playPause.button"] {
                let pausedValue = String(describing: playPause.value ?? "")
                if !pausedValue.isEmpty && pausedValue != playingValue {
                    didPause = true
                    break
                }
            }
            RunLoop.current.run(
                until: min(focusDeadline, Date().addingTimeInterval(Timing.focusPoll)))
        }
        XCTAssertTrue(
            didPause && Date() < focusDeadline
                && midpointPauseReturnedAt < midpointDeadline && midpointPauseReturnedAt < focusDeadline,
            "tvOS midpoint pause must return in the anchored stable window within the original step budget."
        )
        record("playback.pause")
        let beforePause = try captureTVOSImmediateMark(app: app, name: "before-pause")
        XCTAssertEqual(
            beforePause.mark, anchor.mark,
            "tvOS midpoint pause must preserve the anchored public photo before manual Next."
        )
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        moveFocus(.right, to: nextButton, maximumPresses: 3, message: "After pause, focus must reach next.")
        FirstFailureRemote.press(.select)
        record("playback.next")
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.sceneSettle))
        let afterNext = try captureTVOSImmediateMark(app: app, name: "after-next")
        try AccessLifecycleContract.assertPauseUsesVisibleIdentity(
            pauseMark: beforePause.mark,
            afterNextMark: afterNext.mark,
            didUseProgressProbe: false,
            didUseControlValueOnly: false
        )
        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        let controlBarReference = try captureTVOSControlBarReference(app: app)

        let holdStart = Date()
        let holdTarget = interval + AccessLifecycleContract.pauseHoldBeyondIntervalSeconds
        while Date().timeIntervalSince(holdStart) < holdTarget {
            RunLoop.current.run(
                until: Date().addingTimeInterval(AccessLifecycleTVOSUITestsWaitTiming.transitionPollSeconds))
            try AccessLifecycleContract.assertHoldSampleUnchanged(
                expectedMark: afterNext.mark,
                polled: classifyTVOSMark(app: app)
            )
        }
        let holdSeconds = Date().timeIntervalSince(holdStart)
        let holdMark = classifyTVOSMark(app: app)
        try AccessLifecycleContract.assertPausedHoldWithoutAdvance(
            startMark: afterNext.mark,
            endMark: holdMark,
            holdSeconds: holdSeconds,
            intervalSeconds: interval
        )

        ensureControlBarVisible(app: app, playPauseButton: playPauseButton)
        moveFocus(.left, to: playPauseButton, maximumPresses: 3, message: "Focus must return to play/pause after next.")
        let continueAt = Date()
        FirstFailureRemote.press(.select)
        let pressReturnedElapsed = Date().timeIntervalSince(continueAt)
        record("playback.play")
        try AccessLifecycleContract.assertClickTimesRecordedSeparately(
            pressIssuedElapsed: 0, pressReturnedElapsed: pressReturnedElapsed,
            continueOriginElapsed: 0, didUseReturnedAsOrigin: false
        )
        let continueWatch = try watchTVOSContinueToFirstAdvance(
            app: app,
            continueAt: continueAt,
            continueMark: afterNext.mark,
            interval: interval,
            controlBarReference: controlBarReference,
            isSinglePhotoModeVerified: isSinglePhotoModeVerified
        )
        return [
            [
                "name": "midpoint_anchor", "mark": anchor.mark,
                "request_elapsed": anchor.requestedAt.timeIntervalSince(midpointSetupAt),
                "pause_return_elapsed": midpointPauseReturnedAt.timeIntervalSince(anchor.requestedAt),
                "step_elapsed": midpointPauseReturnedAt.timeIntervalSince(midpointSetupAt),
                "step_budget": midpointDeadline.timeIntervalSince(midpointSetupAt)
            ],
            ["name": "before_pause", "mark": beforePause.mark],
            ["name": "after_next", "mark": afterNext.mark],
            ["name": "pause_hold_end", "elapsed": holdSeconds, "mark": holdMark],
            ["name": "continue_press", "issued_elapsed": 0, "returned_elapsed": pressReturnedElapsed],
            ["name": "continue_early", "elapsed": continueWatch.earlyElapsed, "mark": continueWatch.earlyMark],
            [
                "name": "first_transition_start", "status": "detected", "official_signed": true,
                "elapsed": continueWatch.start.requestElapsed, "request_elapsed": continueWatch.start.requestElapsed,
                "return_elapsed": continueWatch.start.returnElapsed, "mark": continueWatch.start.mark,
                "identity_status": continueWatch.start.mark == afterNext.mark ? "DIMMING" : continueWatch.start.status,
                "rescue_interval": continueWatch.rescue.map {
                    ["lower": $0.anchor.requestElapsed, "upper": $0.proof.returnElapsed]
                } as Any? ?? NSNull()
            ],
            [
                "name": "new_image_confirmation", "elapsed": continueWatch.advanced.requestElapsed,
                "request_elapsed": continueWatch.advanced.requestElapsed,
                "return_elapsed": continueWatch.advanced.returnElapsed,
                "mark": continueWatch.advanced.mark
            ],
            [
                "name": "after_auto_advance", "elapsed": continueWatch.advanced.requestElapsed,
                "mark": continueWatch.advanced.mark
            ],
            [
                "name": "continue_watch_samples",
                "samples": continueWatch.samples.map { sample in
                    [
                        "request_elapsed": sample.requestElapsed, "return_elapsed": sample.returnElapsed,
                        "classified_elapsed": sample.classifiedElapsed, "status": sample.status,
                        "mark": sample.mark, "mean_luma": sample.meanLuma,
                        "control_bar_visible": sample.isControlBarVisible
                    ] as [String: Any]
                }
            ]
        ]
    }

    @MainActor
    private func captureTVOSMidpointAnchor(app: XCUIApplication, deadline: Date) throws
        -> (mark: String, requestedAt: Date)
    {
        var initialMark: String?
        var candidate: (mark: String, requestedAt: Date)?
        while Date() < deadline {
            let requestedAt = Date()
            let png = app.screenshotForFailureEvidence().pngRepresentation
            let identity = StrictE2EPhotoIdentity.captureIdentity(png: png)
            let mark = contractTVOSMark(identity)
            guard Date() < deadline else { break }
            if isUsableTVOSMark(mark) {
                if initialMark == nil { initialMark = mark }
                if mark != initialMark && identity.meanLuma >= AccessLifecycleContract.newStableMarkMinimumLuma {
                    if let candidate, candidate.mark == mark,
                        requestedAt.timeIntervalSince(candidate.requestedAt)
                            >= AccessLifecycleContract.newStableMarkConfirmWindow
                    {
                        try persistTVOSCapturedPNG(png, name: "midpoint-anchor")
                        return candidate
                    }
                    if candidate?.mark != mark { candidate = (mark, requestedAt) }
                } else {
                    candidate = nil
                }
            } else {
                candidate = nil
            }
            RunLoop.current.run(
                until: min(
                    deadline, Date().addingTimeInterval(AccessLifecycleContract.newStableMarkPollInterval)))
        }
        throw AccessLifecycleContract.AssertionError.message(
            "tvOS midpoint setup requires a new stable public photo within the original step budget."
        )
    }

    struct TVOSContinueWatchResult {
        let earlyMark: String
        let earlyElapsed: TimeInterval
        let start: AccessLifecycleContract.ContinueWatchSample
        let advanced: AccessLifecycleContract.ContinueWatchSample
        let samples: [AccessLifecycleContract.ContinueWatchSample]
        let rescue: AccessLifecycleContract.TVOSFadeRescue?
    }

    // T±2 judges the shared transition onset; stable new-photo evidence may follow that window.
    @MainActor
    func watchTVOSContinueToFirstAdvance(
        app: XCUIApplication,
        continueAt: Date,
        continueMark: String,
        interval: TimeInterval,
        controlBarReference: StrictE2EPhotoIdentity.ControlBarReference,
        isSinglePhotoModeVerified: Bool
    ) throws -> TVOSContinueWatchResult {
        let captureUntil = AccessLifecycleContract.continueWatchDenseCaptureDeadline(intervalSeconds: interval)
        // 0.224 s measured press gap + 0.3 s animation must finish before T-0.25, the earliest fade
        // observed in one trace; this is a measured allowance, not a contractual lower bound.
        let wakeLeadTimeSeconds = TestWait.seconds(.product(0.8))
        let wakeDeadline = interval - wakeLeadTimeSeconds
        var capturedFrames: [(request: TimeInterval, captured: TimeInterval, returned: TimeInterval, png: Data)] = []
        var controlBarWake: (issued: TimeInterval, returned: TimeInterval)?
        var isControlBarWakeSkipped = false
        let controlBarProbe = TVOSControlBarProbe(reference: controlBarReference)
        var samples: [AccessLifecycleContract.ContinueWatchSample] = []
        var earlyMark = ""
        var earlyElapsed: TimeInterval = TestWait.seconds(.product(0))
        var baselineLuma: Double?
        var photoPixels: [AccessLifecycleContract.TVOSPhotoPixels?] = []
        var rescue: AccessLifecycleContract.TVOSFadeRescue?
        let timingObservation = AccessLifecycleContract.TVOSPauseTimingObservation()
        defer {
            do {
                try StrictE2EVisualEvidence.writeRequiredJSON(
                    [
                        "baseline_luma": baselineLuma.map { $0 as Any } ?? NSNull(),
                        "single_photo_mode_verified": isSinglePhotoModeVerified,
                        "judge": timingObservation.judgeStep.rawValue,
                        "rescue_ran": timingObservation.didRunRescue,
                        "rescue_stage": timingObservation.rescueStage.rawValue,
                        "rescue_indices": timingObservation.indices,
                        "rescue_interval": rescue.map {
                            ["lower": $0.anchor.requestElapsed, "upper": $0.proof.returnElapsed]
                        } as Any? ?? NSNull(),
                        "control_bar_wake": controlBarWake.map {
                            ["issued": $0.issued, "returned": $0.returned] as Any
                        } ?? NSNull(),
                        "control_bar_wake_skipped": isControlBarWakeSkipped,
                        "control_bar_wake_deadline": wakeDeadline,
                        "frames": capturedFrames.enumerated().map { index, frame in
                            let pixels = index < photoPixels.count ? photoPixels[index] : nil
                            return [
                                "request": frame.request, "captured": frame.captured, "returned": frame.returned,
                                "photo_q95": pixels?.highlightLuma as Any? ?? NSNull(),
                                "photo_white_core_fraction": pixels?.whiteCoreFraction as Any? ?? NSNull(),
                                "photo_decoded_mean_luma": pixels?.decodedMeanLuma as Any? ?? NSNull()
                            ] as [String: Any]
                        },
                        "samples": samples.map { sample in
                            [
                                "request": sample.requestElapsed, "returned": sample.returnElapsed,
                                "status": sample.status, "mark": sample.mark, "luma": sample.meanLuma,
                                "controls": sample.isControlBarVisible,
                                "photo_q95": sample.photoPixels?.highlightLuma as Any? ?? NSNull(),
                                "photo_white_core_fraction": sample.photoPixels?.whiteCoreFraction as Any? ?? NSNull(),
                                "photo_decoded_mean_luma": sample.photoPixels?.decodedMeanLuma as Any? ?? NSNull(),
                                "identity_notes": sample.identityNotes
                            ] as [String: Any]
                        }
                    ], name: "continue-watch-diagnostic.json")
            } catch {
                print("Continue watch diagnostic could not be written: \(error.localizedDescription)")
            }
        }
        do {
            while Date().timeIntervalSince(continueAt) <= captureUntil {
                let request = Date().timeIntervalSince(continueAt)
                let screenshot = XCUIScreen.main.screenshotForFailureEvidence()
                let captured = Date().timeIntervalSince(continueAt)
                let png = screenshot.pngRepresentation
                let returned = Date().timeIntervalSince(continueAt)
                capturedFrames.append((request, captured, returned, png))
                if controlBarWake == nil, isControlBarWakeSkipped == false {
                    // Never wait for PNG decoding between captures, including across T-2.
                    controlBarProbe.submit(png: png)
                    let didObserveAutoHide = controlBarProbe.didObserveAutoHide
                    let issued = Date().timeIntervalSince(continueAt)
                    if issued > wakeDeadline {
                        // Skipping returns to main's hidden-state comparison; its direction is unmeasured.
                        isControlBarWakeSkipped = true
                    } else if didObserveAutoHide {
                        // The App's 8 s auto-hide equals T-2 only while this flow requests T=10 s.
                        guard issued >= interval - AccessLifecycleContract.continueCaptureSlackSeconds else {
                            throw AccessLifecycleContract.AssertionError.message(
                                "tvOS Continue wake timing precondition failed: Up must not be requested before T-2."
                            )
                        }
                        FirstFailureRemote.press(.up)
                        controlBarWake = (issued, Date().timeIntervalSince(continueAt))
                        record("playback.wake_controls")
                    }
                }
            }
            for frame in capturedFrames {
                photoPixels.append(autoreleasepool { TVOSContinuePhotoCapture.pixels(png: frame.png) })
            }
            for (index, frame) in capturedFrames.enumerated() {
                let identity = StrictE2EPhotoIdentity.captureIdentity(png: frame.png)
                let mark = contractTVOSMark(identity)
                let sample = AccessLifecycleContract.ContinueWatchSample(
                    requestElapsed: frame.request, returnElapsed: frame.returned,
                    classifiedElapsed: Date().timeIntervalSince(continueAt), status: identity.status.rawValue,
                    mark: mark, meanLuma: identity.meanLuma,
                    isControlBarVisible: try XCTUnwrap(controlBarReference.isVisible(png: frame.png)),
                    photoPixels: photoPixels[index], identityNotes: identity.notes
                )
                samples.append(sample)
                if earlyMark.isEmpty {
                    if frame.request > interval / 2 {
                        throw AccessLifecycleContract.AssertionError.message(
                            "The first-half evidence window after Continue crossed its bounds; classify this as a test timing failure"
                        )
                    }
                    if isUsableTVOSMark(mark) && mark == continueMark {
                        earlyMark = mark
                        earlyElapsed = frame.request
                        baselineLuma = identity.meanLuma
                        try persistTVOSCapturedPNG(frame.png, name: "continue-early")
                        try AccessLifecycleContract.assertContinueEarlyStillSameScene(
                            continueMark: continueMark, earlyMark: earlyMark,
                            elapsedSeconds: earlyElapsed, intervalSeconds: interval
                        )
                    }
                }
                if AccessLifecycleContract.firstStableNewImage(continueMark: continueMark, samples: samples) != nil {
                    break
                }
            }
            guard let baselineLuma else {
                throw AccessLifecycleContract.AssertionError.message(
                    "The first-half evidence window after Continue crossed its bounds; missing original photo evidence"
                )
            }
            let evidence = try AccessLifecycleContract.assertTVOSPauseTimingEvidence(
                continueMark: continueMark, baselineLuma: baselineLuma, samples: samples, intervalSeconds: interval,
                rescuePolicy: TVOSContinuePhotoCapture.policy(isSinglePhoto: isSinglePhotoModeVerified),
                observation: timingObservation
            )
            rescue = evidence.rescue
            if let rescue {
                for (sample, name) in [
                    (rescue.anchor, "continue-rescue-anchor"), (rescue.dim, "continue-rescue-dim"),
                    (rescue.proof, "continue-rescue-proof")
                ] {
                    if let frame = capturedFrames.first(where: { $0.request == sample.requestElapsed }) {
                        try persistTVOSCapturedPNG(frame.png, name: name)
                    }
                }
            }
            for (sample, name) in [(evidence.start, "first-transition-start"), (evidence.stable, "after-auto-advance")]
            {
                if let frame = capturedFrames.first(where: { $0.request == sample.requestElapsed }) {
                    try persistTVOSCapturedPNG(frame.png, name: name)
                }
            }
            return TVOSContinueWatchResult(
                earlyMark: earlyMark, earlyElapsed: earlyElapsed,
                start: evidence.start, advanced: evidence.stable, samples: samples, rescue: rescue
            )
        } catch {
            if let lastFrame = capturedFrames.last {
                try? persistTVOSCapturedPNG(lastFrame.png, name: "after-auto-advance")
            }
            throw error
        }
    }

    @MainActor
    private func captureTVOSControlBarReference(app: XCUIApplication) throws
        -> StrictE2EPhotoIdentity.ControlBarReference
    {
        let settings = app.buttons["slideshow.control.settings.button"]
        let frame = try settings.snapshot().frame
        let bounds = app.frame
        let normalizedRect = CGRect(
            x: (frame.minX - bounds.minX) / bounds.width, y: (frame.minY - bounds.minY) / bounds.height,
            width: frame.width / bounds.width, height: frame.height / bounds.height
        )
        let png = app.screenshotForFailureEvidence().pngRepresentation
        guard settings.isHittable else {
            throw AccessLifecycleContract.AssertionError.message(
                "Playback page should show the settings button: control-bar calibration requires Settings to remain hittable after the screenshot"
            )
        }
        return try XCTUnwrap(StrictE2EPhotoIdentity.ControlBarReference(png: png, normalizedRect: normalizedRect))
    }

    @MainActor
    func captureTVOSNewStableMark(
        app: XCUIApplication,
        name: String,
        timeout: TimeInterval
    ) throws -> (mark: String, png: Data) {
        try AccessLifecycleContract.assertIdentitySource("public_fixture_photo_mark")
        let initialMark = classifyTVOSMark(app: app)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(
                until: Date().addingTimeInterval(
                    AccessLifecycleContract.pollWait(remaining: deadline.timeIntervalSinceNow)
                )
            )
            let candidate = classifyTVOSMark(app: app)
            if isUsableTVOSMark(candidate) && candidate != initialMark {
                let confirm = AccessLifecycleContract.confirmWait(remaining: deadline.timeIntervalSinceNow)
                if confirm > 0 {
                    RunLoop.current.run(until: Date().addingTimeInterval(confirm))
                }
                let stable = try captureTVOSImmediateMark(app: app, name: name)
                if stable.mark == candidate {
                    return stable
                }
            }
        }
        throw AccessLifecycleContract.AssertionError.message("No new stable frame before going to background")
    }

    @MainActor
    func captureTVOSImmediateMark(
        app: XCUIApplication,
        name: String
    ) throws -> (mark: String, png: Data) {
        try AccessLifecycleContract.assertIdentitySource("public_fixture_photo_mark")
        let png = app.screenshotForFailureEvidence().pngRepresentation
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try StrictE2EVisualEvidence.writeRequiredPNG(png, name: name)
        screenshotOrder.append(name)
        attachScreenshot(app: app, name: "tvos-\(name)")
        let mark = contractTVOSMark(StrictE2EPhotoIdentity.captureIdentity(png: png))
        if isUsableTVOSMark(mark) == false {
            throw AccessLifecycleContract.AssertionError.message("Screenshot \(name) cannot serve as identity: \(mark)")
        }
        return (mark, png)
    }

    @MainActor
    func classifyTVOSMark(app: XCUIApplication) -> String {
        contractTVOSMark(
            StrictE2EPhotoIdentity.captureIdentity(png: app.screenshotForFailureEvidence().pngRepresentation))
    }

    func contractTVOSMark(_ identity: StrictE2EPhotoIdentity.Result) -> String {
        if identity.status == .match, let mark = identity.mark {
            return mark
        }
        if identity.status == .black { return "BLACK" }
        if identity.status == .blank { return "BLANK" }
        if identity.status == .transition { return "TRANSITION" }
        return "UNRECOGNIZABLE"
    }

    func isUsableTVOSMark(_ mark: String) -> Bool {
        AccessLifecycleContract.isUsableSceneMark(mark)
    }

    // XCUIApplication has no public processIdentifier API; use processID or the pid in its description.
    func applicationProcessID(_ app: XCUIApplication) throws -> Int32 {
        let object = app as NSObject
        if object.responds(to: Selector(("processID"))) {
            if let number = object.value(forKey: "processID") as? NSNumber, number.int32Value > 0 {
                return number.int32Value
            }
        }
        let text = app.debugDescription
        let regex = try NSRegularExpression(pattern: #"pid[: ]+(\d+)"#, options: [.caseInsensitive])
        let nsText = text as NSString
        if let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
            match.numberOfRanges > 1,
            let pid = Int32(nsText.substring(with: match.range(at: 1))),
            pid > 0
        {
            return pid
        }
        throw AccessLifecycleContract.AssertionError.message("Background return lacks the original process identity")
    }

    func writeTVOSResumeJSON(name: String, extra: [String: Any]) throws {
        var payload: [String: Any] = [
            "status": "ran",
            "identity_source": AccessLifecycleContract.allowedIdentitySource,
            "settings_source": AccessLifecycleContract.allowedSettingsSource,
            "device": "tvos",
            "requests": requests,
            "pin_enabled": false,
            "screenshot_order": screenshotOrder
        ]
        for (key, value) in extra {
            payload[key] = value
        }
        try StrictE2EVisualEvidence.writeRequiredJSON(payload, name: name)
    }
}
#endif
