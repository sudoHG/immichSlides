import ImageIO
import UIKit
import XCTest

private enum SliderGeometry {
    // Drag beyond the track to reach the maximum after accessibility adjustment stops short.
    static let maximumThumbFraction: CGFloat = 0.93
    static let dragBeyondMaximumFraction: CGFloat = 1.05
}

private enum WaitTiming {
    static let briefElementTimeoutSeconds: TimeInterval = 1
    static let connectionTimeoutSeconds: TimeInterval = 15
    static let controlAppearanceTimeoutSeconds: TimeInterval = 8
    static let elementAppearanceTimeoutSeconds: TimeInterval = 5
    static let identityPollSeconds: TimeInterval = 0.3
    static let playbackStartupTimeoutSeconds: TimeInterval = 30
    static let readbackTimeoutSeconds: TimeInterval = 2
    static let sceneReadyTimeoutSeconds: TimeInterval = 45
    static let screenTransitionTimeoutSeconds: TimeInterval = 12
    static let settingsChangeTimeoutSeconds: TimeInterval = 6
    static let shortInteractionTimeoutSeconds: TimeInterval = 3
    static let stateChangeTimeoutSeconds: TimeInterval = 4
}

// Shared by the strict end-to-end UI tests: writing required PNGs / steps to disk, stable-frame waits, and real settings
// actions on both platforms.
// scripts/strict_e2e_p2_contract.py is the single source of truth for the p2-steps.json format.

enum Timing {
    // Interval between two screenshots (seconds). Stable only when two consecutive frames show the same public
    // pattern, which rules out mid-transition frames.
    static let identityPoll: TimeInterval = 0.3
    static let stableIdentityTimeout: TimeInterval = 8
    static let exifSettleTimeout: TimeInterval = 5
    // Multi-photo scenes must hold for 1 second in a row, to avoid capturing a half-switched frame.
    static let multiPhotoWait: TimeInterval = 4
    static let multiPhotoHold: TimeInterval = 1
    static let clearCompletionTimeout: TimeInterval = 15
    static let focusSettle: TimeInterval = 0.16
    static let poll: TimeInterval = 0.1
    // Orientation steady state: capture only when two frames 0.5 seconds apart show no layout jump. Wait at most
    // 10 seconds per attempt; on timeout keep the scene as it is.
    static let stableFramePair: TimeInterval = 0.5
    static let stableFrameTimeout: TimeInterval = 10
}

// Values match the orientation field in p2-steps.json; notApplicable skips the orientation check.
enum StepOrientation: String {
    case portrait
    case landscape
    case notApplicable = "not_applicable"

    func matches(_ size: CGSize) -> Bool {
        switch self {
        case .portrait: return size.height > size.width
        case .landscape: return size.width > size.height
        case .notApplicable: return true
        }
    }
}

struct Failure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

enum Wait {
    @MainActor
    static func until(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.poll))
        }
        return condition()
    }

    // The condition must hold continuously for hold seconds within timeout; the timer restarts if it fails midway.
    @MainActor
    static func held(timeout: TimeInterval, hold: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout + hold)
        var heldSince: Date?
        while Date() < deadline {
            if condition() {
                let start = heldSince ?? Date()
                heldSince = start
                if Date().timeIntervalSince(start) >= hold { return true }
            } else {
                heldSince = nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.poll))
        }
        return false
    }
}

@MainActor
final class Evidence {
    private var steps: [[String: Any]] = []

    // Write the required PNG and record a step only when accept passes. On timeout keep only a -rejected
    // diagnostic frame; the required file stays missing so the contract fails.
    @discardableResult
    func capture(
        _ name: String,
        from app: XCUIApplication,
        orientation: StepOrientation = .notApplicable,
        timeout: TimeInterval = Timing.stableIdentityTimeout,
        accept: (StrictE2EPhotoIdentity.Result) -> Bool = { _ in true }
    ) throws -> StrictE2EPhotoIdentity.Result {
        let deadline = Date().addingTimeInterval(timeout)
        var capturedAt = Date()
        var png = app.screenshot().pngRepresentation
        var identity = StrictE2EPhotoIdentity.classify(png: png)
        // No retakes past the deadline, so a last round cannot push later watermarks out of the contract window.
        while !accept(identity) {
            let retryAt = Date().addingTimeInterval(Timing.identityPoll)
            guard retryAt < deadline else { break }
            RunLoop.current.run(until: retryAt)
            capturedAt = Date()
            png = app.screenshot().pngRepresentation
            identity = StrictE2EPhotoIdentity.classify(png: png)
        }
        guard accept(identity) else {
            try reject(name, png: png)
            throw Failure("\(name) unmet at timeout: status=\(identity.status.rawValue) mark=\(identity.mark ?? "nil")")
        }
        try record(name, png: png, capturedAt: capturedAt, orientation: orientation)
        return identity
    }

    // A frame the caller already accepted: write the required PNG and record a step.
    func record(_ name: String, png: Data, capturedAt: Date, orientation: StepOrientation) throws {
        try save(png, as: name)
        try appendStep(name, at: capturedAt, orientation: orientation, png: "\(name).png")
    }

    // A rejected frame leaves only a -rejected diagnostic; the required PNG stays missing so the contract fails.
    func reject(_ name: String, png: Data) throws {
        try save(png, as: "\(name)-rejected")
    }

    // Time marker without a PNG (rotation start, start of a recording segment). The contract uses it to convert
    // recording offsets.
    func markStep(_ name: String) throws {
        try appendStep(name, at: Date(), orientation: .notApplicable, png: nil)
    }

    private func save(_ png: Data, as fileName: String) throws {
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = fileName
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: fileName) { $0.add(attachment) }
        try StrictE2EVisualEvidence.writeRequiredPNG(png, name: fileName)
    }

    private func appendStep(_ name: String, at wallTime: Date, orientation: StepOrientation, png: String?) throws {
        var step: [String: Any] = [
            "index": steps.count + 1,
            "name": name,
            "wall_time": wallTime.timeIntervalSince1970,
            "orientation": orientation.rawValue
        ]
        if let png { step["png"] = png }
        steps.append(step)
        try StrictE2EVisualEvidence.writeRequiredJSON(
            ["schema": "strict-e2e-steps-v1", "steps": steps], name: "p2-steps.json")
    }

}

struct StableFrame {
    // Upper limit of the mean per-pixel difference (0-1) between 64x64 grayscale thumbnails. On the public pattern
    // a slow 0.5-second zoom / pan is about <=0.02, while a 5% relayout or a crossfade is about >=0.032. A relayout
    // of a screen with little content may fall below it.
    static let layoutJumpLimit = 0.03
    private static let thumbnailSide = 64

    let png: Data
    let capturedAt: Date
    let isStable: Bool
    let detail: String

    // Stable only when window orientation, prepare (run before the screenshot, e.g. waking the control bar), pixel
    // orientation and accept all hold, and two frames 0.5 seconds apart differ by no more than the limit. On
    // timeout, returns the last frame for the record.
    @MainActor
    static func wait(
        in app: XCUIApplication,
        orientation: StepOrientation,
        timeout: TimeInterval = Timing.stableFrameTimeout,
        prepare: () -> Bool = { true },
        accept: (Data) -> Bool
    ) -> StableFrame {
        let deadline = Date().addingTimeInterval(timeout)
        var previous: Data?
        while true {
            let window = app.frame.size
            let isPrepared = orientation.matches(window) && prepare()
            let capturedAt = Date()
            let png = uprightScreenPNG()
            let pixels = pixelSize(png) ?? .zero
            var candidate: Data?
            let detail: String
            if !orientation.matches(window) {
                detail = "window \(window) not yet \(orientation.rawValue)"
            } else if !isPrepared {
                detail = "controls or scene not ready"
            } else if !orientation.matches(pixels) {
                detail = "screenshot pixels \(pixels) not yet \(orientation.rawValue)"
            } else if !accept(png) {
                detail = "screen not ready"
            } else if let previous {
                candidate = png
                if let difference = difference(previous, png) {
                    let formatted = String(format: "%.4f", difference)
                    if difference <= layoutJumpLimit {
                        return StableFrame(
                            png: png, capturedAt: capturedAt, isStable: true, detail: "frame diff \(formatted)")
                    }
                    detail = "frame diff \(formatted) exceeds \(layoutJumpLimit)"
                } else {
                    detail = "thumbnail decoding failed; cannot compare the two frames"
                }
            } else {
                candidate = png
                detail = "waiting for the second frame"
            }
            previous = candidate
            let nextAt = capturedAt.addingTimeInterval(Timing.stableFramePair)
            guard nextAt <= deadline else {
                return StableFrame(png: png, capturedAt: capturedAt, isStable: false, detail: detail)
            }
            RunLoop.current.run(until: nextAt)
        }
    }

    // In landscape, an app-element screenshot is cropped at the wrong offset and a full-screen screenshot is the
    // native portrait framebuffer; redraw it using the system's imageOrientation to match what the user sees.
    static func uprightScreenPNG() -> Data {
        let screenshot = XCUIScreen.main.screenshot()
        let image = screenshot.image
        guard image.imageOrientation != .up else { return screenshot.pngRepresentation }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).pngData { _ in image.draw(at: .zero) }
    }

    // MATCH or TRANSITION both mean the public pattern is visible; mixed colors in multi-photo scenes usually
    // classify as TRANSITION.
    static func showsFixturePhoto(_ png: Data) -> Bool {
        [.match, .transition].contains(StrictE2EPhotoIdentity.classify(png: png).status)
    }

    static func pixelSize(_ png: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    static func difference(_ first: Data, _ second: Data) -> Double? {
        guard let lhs = thumbnail(first), let rhs = thumbnail(second) else { return nil }
        let total = zip(lhs, rhs).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(lhs.count * 255)
    }

    private static func thumbnail(_ png: Data) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        var pixels = [UInt8](repeating: 0, count: thumbnailSide * thumbnailSide)
        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                let context = CGContext(
                    data: base,
                    width: thumbnailSide,
                    height: thumbnailSide,
                    bitsPerComponent: 8,
                    bytesPerRow: thumbnailSide,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                )
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: thumbnailSide, height: thumbnailSide))
            return true
        }
        return didDraw ? pixels : nil
    }
}

enum PlaybackSetting {
    case interval30Seconds
    // Positive control for Reduce Motion: moves faster than 30 seconds and is easier to see, yet still leaves
    // enough time to observe the same scene after returning.
    case interval15Seconds
    case displayMode(isSinglePhoto: Bool)
    case showExif(Bool)
}

// The two platforms differ only in how they tap; photo identification, waiting and evidence checks are shared.
@MainActor
protocol PlaybackDriver {
    var app: XCUIApplication { get }
    func launchToPlayback(input: StrictE2EInput)
    func applyPlaybackSettings(_ settings: [PlaybackSetting])
    func pause()
    func next()
    func returnToPlayback()
    // On the cache page, capture the screen before clearing, then handle the confirm alert; ends on the cache page.
    func clearDiskCache(onCachePage: () throws -> Void) throws
}

extension PlaybackDriver {
    // Returns only after two consecutive frames show the same MATCH; previous skips the old screen left over
    // from before the switch.
    func stableMark(excluding previous: String? = nil, timeout: TimeInterval = Timing.stableIdentityTimeout) -> String?
    {
        let deadline = Date().addingTimeInterval(timeout)
        var last: String?
        var unchanged: String?
        while Date() < deadline {
            let identity = StrictE2EPhotoIdentity.classify(png: app.screenshot().pngRepresentation)
            let mark = identity.status == .match ? identity.mark : nil
            if let mark, mark == last {
                if mark != previous { return mark }
                unchanged = mark
            }
            last = mark
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.identityPoll))
        }
        return unchanged
    }

    func advance(toAnyOf marks: Set<String>, maxNextPresses: Int = 6) throws -> String {
        var current = stableMark()
        for _ in 0..<maxNextPresses {
            if let current, marks.contains(current) { return current }
            next()
            current = stableMark(excluding: current)
        }
        if let current, marks.contains(current) { return current }
        throw Failure(
            "\(maxNextPresses) next presses never reached \(marks.sorted()); last was \(current ?? "unidentified").")
    }

    // Identify multi-photo screens by the public pattern; a missing probe must not veto a visible two-photo screen.
    func advanceToMultiPhotoScene(in orientation: StepOrientation = .notApplicable, maxNextPresses: Int = 6) throws {
        var observations: [[String: Any]] = []
        for press in 0...maxNextPresses {
            if press > 0 { next() }
            if Wait.held(
                timeout: Timing.multiPhotoWait, hold: Timing.multiPhotoHold,
                {
                    isShowingMultiPhotoScene(in: orientation)
                })
            {
                return
            }
            let current = snapshotNodes { $0.identifier == "slideshow.smartfill.currentManifest.flag" }
            let layers = snapshotNodes { $0.identifier == "slideshow.smartfill.manifest.flag" }
            observations.append([
                "next_presses": press,
                "current_probe_count": current.count,
                "current_scene_types": current.compactMap { manifestField("sceneType", in: $0.label) },
                "layer_probe_count": layers.count,
                "layer_scene_types": layers.compactMap { manifestField("sceneType", in: $0.label) }
            ])
        }
        try StrictE2EVisualEvidence.writeRequiredJSON(
            ["schema": "strict-e2e-multi-scene-search-v1", "observations": observations],
            name: "multi-scene-search-diagnostic.json"
        )
        try Evidence().reject("multi-scene-search", png: app.screenshot().pngRepresentation)
        throw Failure(
            "Public fixture: no 2/3-photo scene within \(maxNextPresses) next presses; too few multi-photo frames.")
    }

    private func manifestField(_ key: String, in label: String) -> String? {
        label.split(separator: ";").first { $0.hasPrefix("\(key)=") }.map { String($0.dropFirst(key.count + 1)) }
    }

    // Collect only visible EXIF Fixture text. Take one snapshot of the whole tree so elements cannot vanish while
    // labels are read one by one.
    func visibleOverlayText() -> String {
        snapshotNodes { $0.elementType == .staticText && $0.label.contains("Fixture") }
            .map(\.label)
            .joined(separator: " | ")
    }

    func waitForClearCompletion() {
        XCTAssertTrue(
            Wait.until(timeout: Timing.clearCompletionTimeout) {
                let identifiers = Set(snapshotNodes { $0.identifier.hasPrefix("settings.cache.") }.map(\.identifier))
                return identifiers.contains("settings.cache.status.message")
                    && !identifiers.contains("settings.cache.clearing.status")
            },
            "After confirming the clear, the completion message must appear and the clearing status must go away."
        )
    }

    // Confirm both orientation and two-photo identity from actual screen pixels.
    func isShowingMultiPhotoScene(in orientation: StepOrientation = .notApplicable) -> Bool {
        guard orientation.matches(app.frame.size) else { return false }
        let png = StableFrame.uprightScreenPNG()
        guard let pixels = StableFrame.pixelSize(png), orientation.matches(pixels) else { return false }
        let identity = StrictE2EPhotoIdentity.captureIdentity(png: png)
        return identity.status == .match && (identity.mark?.split(separator: "+").count ?? 0) >= 2
    }

    private func snapshotNodes(where include: (XCUIElementSnapshot) -> Bool) -> [XCUIElementSnapshot] {
        guard let root = try? app.snapshot() else { return [] }
        var matched: [XCUIElementSnapshot] = []
        var pending: [XCUIElementSnapshot] = [root]
        while let node = pending.popLast() {
            if include(node) { matched.append(node) }
            pending.append(contentsOf: node.children)
        }
        return matched
    }
}

#if os(iOS)
@MainActor
struct IOSDriver: PlaybackDriver {
    // The interval slider maps 5-30 seconds linearly: (15 - 5) / (30 - 5).
    private static let interval15SliderPosition = 0.4
    // The slider steps by 1 second and a drag often lands one step off: try the target first, then nudge to both
    // sides from near to far.
    private static let sliderNudgeOffsets = [0, -0.04, 0.04, -0.08, 0.08]

    let app: XCUIApplication

    func launchToPlayback(input: StrictE2EInput) {
        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 20), "Fresh install must open the normal first-boot page.")
        replaceText(in: serverField, with: input.serverURL)
        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(
            apiKeyField.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "First-boot page must show the API Key field.")
        replaceText(in: apiKeyField, with: input.publicKey)
        XCTAssertTrue(
            Wait.until(timeout: WaitTiming.shortInteractionTimeoutSeconds) { secureFieldHasValue(apiKeyField) },
            "The API Key must be entered into the secure field.")
        commitFocusedInput()

        let testConnection = control("firstboot.testConnection.button")
        XCTAssertTrue(
            testConnection.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "First-boot page must show Test Connection.")
        tap(testConnection)
        let save = control("firstboot.saveConfig.button")
        XCTAssertTrue(
            save.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "First-boot page must show the Save Settings button.")
        XCTAssertTrue(waitForSaveEnabled(save), "Save must become enabled after a real connection test succeeds.")
        tap(save)

        XCTAssertTrue(
            app.buttons["mode.random.button"].waitForExistence(timeout: WaitTiming.connectionTimeoutSeconds),
            "A successful save must lead to mode selection.")
        let random = control("mode.random.button")
        let continueButton = control("mode.continue.button")
        if !(continueButton.exists && continueButton.isEnabled && random.isSelected) {
            tap(random)
            XCTAssertTrue(
                Wait.until(timeout: WaitTiming.readbackTimeoutSeconds) {
                    continueButton.exists && continueButton.isEnabled
                },
                "Continue must be enabled after selecting Random.")
        }
        tap(continueButton)
        dismissSavePasswordPrompt(timeout: WaitTiming.elementAppearanceTimeoutSeconds)
        if continueButton.exists && continueButton.isHittable && continueButton.isEnabled {
            tap(continueButton)
        }
        XCTAssertTrue(
            waitForPlaybackControls(timeout: WaitTiming.playbackStartupTimeoutSeconds),
            "Random mode must reach the playback page.")
    }

    func applyPlaybackSettings(_ settings: [PlaybackSetting]) {
        openSettings()
        openPlaybackSection()
        for setting in settings {
            switch setting {
            case .interval30Seconds:
                let slider = app.sliders["settings.playback.interval.slider"]
                XCTAssertTrue(
                    slider.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
                    "Playback settings must have the interval slider.")
                XCTAssertTrue(slider.isEnabled, "With auto-play on, the interval slider must be adjustable.")
                slider.adjust(toNormalizedSliderPosition: 1)
                let interval30 = app.staticTexts["settings.playback.interval.value"]
                if UIDevice.current.userInterfaceIdiom == .pad
                    && !Wait.until(
                        timeout: WaitTiming.briefElementTimeoutSeconds,
                        { interval30.exists && interval30.label == "30 秒" })
                {
                    let thumb = slider.coordinate(
                        withNormalizedOffset: CGVector(dx: SliderGeometry.maximumThumbFraction, dy: 0.5))
                    let beyondRightEnd = slider.coordinate(
                        withNormalizedOffset: CGVector(dx: SliderGeometry.dragBeyondMaximumFraction, dy: 0.5))
                    thumb.press(forDuration: 0.1, thenDragTo: beyondRightEnd)
                }
                let reached30 = Wait.until(timeout: WaitTiming.shortInteractionTimeoutSeconds) {
                    interval30.exists && interval30.label == "30 秒"
                }
                if !reached30 {
                    try? Evidence().reject("interval30-setting", png: app.screenshot().pngRepresentation)
                }
                XCTAssertTrue(reached30, "The interval must be set to 30 seconds with the real slider.")
            case .interval15Seconds:
                let slider = app.sliders["settings.playback.interval.slider"]
                XCTAssertTrue(
                    slider.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
                    "Playback settings must have the interval slider.")
                XCTAssertTrue(slider.isEnabled, "With auto-play on, the interval slider must be adjustable.")
                XCTAssertTrue(
                    adjustInterval(slider, toNormalized: Self.interval15SliderPosition, label: "15 秒"),
                    "The interval must be set to 15 seconds with the real slider."
                )
            case .displayMode(let isSinglePhoto):
                let picker = app.segmentedControls["settings.playback.displayMode.picker"]
                XCTAssertTrue(
                    picker.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
                    "Playback settings must have display mode segments.")
                let option = picker.buttons[
                    isSinglePhoto
                        ? "settings.playback.displayMode.singlePhoto.option"
                        : "settings.playback.displayMode.smartFill.option"]
                XCTAssertTrue(
                    option.waitForExistence(timeout: WaitTiming.shortInteractionTimeoutSeconds),
                    "Display mode must offer the target option.")
                tap(option)
                XCTAssertTrue(
                    Wait.until(timeout: WaitTiming.shortInteractionTimeoutSeconds) { option.isSelected },
                    "Display mode must switch to the target option.")
            case .showExif(let isOn):
                let toggle = app.switches["settings.playback.showExif.toggle"]
                XCTAssertTrue(
                    toggle.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
                    "Playback settings must provide the EXIF toggle.")
                if isToggleOn(toggle) != isOn { tap(toggle) }
                XCTAssertTrue(
                    Wait.until(timeout: WaitTiming.stateChangeTimeoutSeconds) { isToggleOn(toggle) == isOn },
                    "The EXIF toggle must reach the target state through the real settings.")
            }
        }
        returnToPlayback()
    }

    func pause() {
        revealControls()
        let playPause = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(
            playPause.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Playback page must provide play/pause.")
        if playPauseValue(playPause) != "play" { tap(playPause) }
        XCTAssertTrue(
            Wait.until(timeout: WaitTiming.stateChangeTimeoutSeconds) { playPauseValue(playPause) == "play" },
            "After pausing, the control value must be play.")
    }

    func next() {
        revealControls()
        let nextButton = app.buttons["slideshow.control.next.button"]
        XCTAssertTrue(
            nextButton.waitForExistence(timeout: WaitTiming.stateChangeTimeoutSeconds),
            "Playback page must provide Next.")
        tap(nextButton)
    }

    func returnToPlayback() {
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        for _ in 0..<12 {
            if settingsButton.exists && settingsButton.isHittable { return }
            if !isOnSettingsSurface() {
                revealControls()
                if settingsButton.waitForExistence(timeout: WaitTiming.readbackTimeoutSeconds) { return }
            }
            let globalBack = app.buttons["global.back.button"]
            if globalBack.exists && globalBack.isHittable {
                tap(globalBack)
                RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.identityPollSeconds))
                continue
            }
            let navigationButtons = app.navigationBars.buttons.allElementsBoundByIndex
            let backButton =
                navigationButtons.last { $0.exists && $0.isHittable && $0.identifier == "BackButton" }
                ?? navigationButtons.last { button in
                    button.exists && button.isHittable && button.identifier != "ToggleSidebar"
                        // ui-label-lookup: System navigation supplies the sidebar button label.
                        && !["显示边栏", "隐藏边栏", "Show Sidebar", "Hide Sidebar"].contains(button.label)
                }
            if let backButton {
                tap(backButton)
                RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.identityPollSeconds))
                continue
            }
            app.swipeDown()
        }
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Must be able to return from settings to playback.")
    }

    func clearDiskCache(onCachePage: () throws -> Void) throws {
        openSettings()
        openCacheSection()
        let clearButton = app.buttons["settings.cache.clearDisk.button"]
        XCTAssertTrue(
            clearButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Cache page must provide the Clear Disk Cache button.")
        if !clearButton.isHittable { app.swipeUp() }
        try onCachePage()
        tap(clearButton)
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let alert = app.alerts["确认清理磁盘缓存"]
        XCTAssertTrue(
            alert.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds),
            "Tapping Clear must show the confirmation alert.")
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let confirm = alert.buttons.matching(NSPredicate(format: "label == %@", "清理")).firstMatch
        XCTAssertTrue(
            confirm.waitForExistence(timeout: WaitTiming.shortInteractionTimeoutSeconds),
            "Confirmation alert must offer Clear.")
        confirm.tap()
        waitForClearCompletion()
    }

    private func openSettings() {
        revealControls()
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(
            settingsButton.waitForExistence(timeout: WaitTiming.connectionTimeoutSeconds),
            "Playback page must provide the settings entry.")
        tap(settingsButton)
        XCTAssertTrue(
            Wait.until(timeout: WaitTiming.controlAppearanceTimeoutSeconds) { isOnSettingsSurface() },
            "Tapping settings must open the settings page.")
    }

    // On iPad the split view shows playback settings on the right by default; iPhone goes through the list.
    private func openPlaybackSection() {
        let autoPlay = app.switches["settings.playback.autoPlay.toggle"]
        if autoPlay.waitForExistence(timeout: WaitTiming.readbackTimeoutSeconds) { return }
        showSidebarIfCollapsed()
        let playbackItem = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            playbackItem.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Settings list must have the playback settings entry.")
        playbackItem.tap()
        if !Wait.until(
            timeout: WaitTiming.readbackTimeoutSeconds,
            { autoPlay.exists || app.staticTexts["settings.playback.title"].exists })
        {
            app.cells.element(boundBy: 0).tap()
        }
        XCTAssertTrue(
            Wait.until(timeout: 10) { autoPlay.exists || app.staticTexts["settings.playback.title"].exists },
            "After opening playback settings, the auto-play toggle or the playback settings title must be visible."
        )
    }

    private func openCacheSection() {
        showSidebarIfCollapsed()
        let clearButton = app.buttons["settings.cache.clearDisk.button"]
        for attempt in 0..<6 {
            let candidates = [
                app.buttons["settings.item.cache"],
                app.descendants(matching: .any).matching(identifier: "settings.item.cache").firstMatch,
                app.staticTexts["settings.item.cache"]
            ]
            if let entry = candidates.first(where: {
                $0.waitForExistence(timeout: WaitTiming.briefElementTimeoutSeconds)
            }) {
                tap(entry)
                if clearButton.waitForExistence(timeout: WaitTiming.stateChangeTimeoutSeconds) { return }
            }
            if attempt % 2 == 0 { app.swipeUp() } else { app.swipeDown() }
        }
        XCTFail("Settings list must be able to open cache management.")
    }

    private func showSidebarIfCollapsed() {
        let sidebar = app.buttons["ToggleSidebar"]
        // ui-label-lookup: System navigation supplies the sidebar button label.
        if sidebar.exists && ["显示边栏", "Show Sidebar"].contains(sidebar.label) {
            tap(sidebar)
        }
    }

    private func isOnSettingsSurface() -> Bool {
        let identifiers = [
            "settings.item.playback", "settings.playback.title", "settings.accessProtection.title",
            "settings.server.title", "settings.cache.title", "settings.about.title",
            "settings.about.opensource.page"
        ]
        if identifiers.contains(where: { app.descendants(matching: .any)[$0].exists }) { return true }
        return app.buttons["settings.item.playback"].exists
            || app.switches["settings.playback.autoPlay.toggle"].exists
            || app.buttons["settings.cache.clearDisk.button"].exists
    }

    // For orientation steady-state evidence: wake the control bar if it is hidden, then require play / next /
    // settings to all be tappable.
    func revealUsableControls() -> Bool {
        revealControls()
        return [
            "slideshow.control.playPause.button", "slideshow.control.next.button", "slideshow.control.settings.button"
        ]
        .allSatisfy { app.buttons[$0].isHittable }
    }

    private func revealControls() {
        if app.buttons["slideshow.control.settings.button"].exists { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        _ = app.buttons["slideshow.control.settings.button"].waitForExistence(
            timeout: WaitTiming.shortInteractionTimeoutSeconds)
    }

    private func adjustInterval(_ slider: XCUIElement, toNormalized target: Double, label: String) -> Bool {
        for offset in Self.sliderNudgeOffsets {
            slider.adjust(toNormalizedSliderPosition: min(max(target + offset, 0), 1))
            let interval = app.staticTexts["settings.playback.interval.value"]
            if Wait.until(
                timeout: WaitTiming.briefElementTimeoutSeconds, { interval.exists && interval.label == label })
            {
                return true
            }
        }
        return false
    }

    private func waitForPlaybackControls(timeout: TimeInterval) -> Bool {
        Wait.until(timeout: timeout) {
            dismissSavePasswordPrompt(timeout: 0)
            let banner = app.descendants(matching: .any).matching(identifier: "slideshow.entryHint.banner").firstMatch
            if banner.exists { tap(banner) }
            if app.buttons["slideshow.control.settings.button"].isHittable { return true }
            revealControls()
            return app.buttons["slideshow.control.settings.button"].isHittable
        }
    }

    private func waitForSaveEnabled(_ save: XCUIElement) -> Bool {
        Wait.until(timeout: WaitTiming.sceneReadyTimeoutSeconds) {
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            // ui-label-lookup: The local-network permission alert belongs to iOS.
            for label in ["允许", "Allow"] where springboard.alerts.buttons[label].exists {
                // ui-label-lookup: The permission action belongs to SpringBoard.
                springboard.alerts.buttons[label].tap()
            }
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            let alert = app.alerts.firstMatch
            if alert.exists {
                XCTFail("Connection test showed a failure alert: \(alert.label)")
                return true
            }
            return save.exists && save.isEnabled
        }
    }

    private func dismissSavePasswordPrompt(timeout: TimeInterval) {
        _ = Wait.until(timeout: timeout) {
            // ui-label-lookup: Dismiss the iOS Save Password sheet without saving credentials.
            for label in ["以后", "Not Now"] where app.buttons[label].exists {
                // ui-label-lookup: The Save Password action belongs to iOS.
                app.buttons[label].tap()
                return true
            }
            return false
        }
    }

    private func replaceText(in field: XCUIElement, with value: String) {
        field.tap()
        let existing = field.value as? String ?? ""
        let isPlaceholder = existing.contains("请输入") || existing.localizedCaseInsensitiveContains("enter")
        if !existing.isEmpty && !isPlaceholder {
            field.typeKey("a", modifierFlags: .command)
            field.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        }
        field.typeText(value)
    }

    private func secureFieldHasValue(_ field: XCUIElement) -> Bool {
        let value = field.value as? String ?? ""
        return !value.isEmpty && !value.contains("请输入") && !value.localizedCaseInsensitiveContains("api key")
    }

    private func commitFocusedInput() {
        let done = app.buttons["server.keyboard.done.button"]
        if done.exists && done.isHittable {
            done.tap()
            return
        }
        // ui-label-lookup: System keyboard submit keys follow the simulator language.
        for label in ["完成", "Done", "next", "Next"] {
            // ui-label-lookup: System keyboard submit keys follow the simulator language.
            let button = app.keyboards.buttons[label]
            if button.exists && button.isHittable {
                button.tap()
                return
            }
        }
    }

    private func control(_ identifier: String) -> XCUIElement {
        let button = app.buttons[identifier]
        if button.exists { return button }
        let identified = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        if identified.exists { return identified }
        return identified
    }

    private func tap(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func isToggleOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? String) == "1"
    }

    private func playPauseValue(_ button: XCUIElement) -> String {
        ((button.value as? String) ?? "").lowercased()
    }
}
#endif

#if os(tvOS)
@MainActor
struct TVDriver: PlaybackDriver {
    let app: XCUIApplication

    func launchToPlayback(input: StrictE2EInput) {
        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(
            serverField.waitForExistence(timeout: WaitTiming.screenTransitionTimeoutSeconds),
            "A clean install must open the first-boot form.")
        replaceFocusedText(in: serverField, with: input.serverURL)
        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(
            apiKeyField.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "First-boot form must show the API Key field.")
        focus(
            apiKeyField, trying: [.down], maxPresses: 2,
            "After submitting the URL, focus must be able to move down to the API Key.")
        replaceFocusedText(in: apiKeyField, with: input.publicKey)

        let testConnection = firstBootControl("firstboot.testConnection.button")
        XCTAssertTrue(
            testConnection.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds),
            "First-boot form must show the Test Connection button.")
        press(.down)
        press(.right)
        press(.select)
        XCTAssertTrue(
            app.staticTexts["firstboot.connection.success"].waitForExistence(
                timeout: WaitTiming.sceneReadyTimeoutSeconds),
            "Once the real controlled server is reachable, it must show that the connection test passed.")
        let save = firstBootControl("firstboot.saveConfig.button")
        XCTAssertTrue(
            save.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds),
            "Once connected, the Save Settings button must show.")
        XCTAssertTrue(save.isEnabled, "After a successful connection, Save Settings must be enabled.")
        press(.select)

        let random = app.buttons["mode.random.button"]
        XCTAssertTrue(
            random.waitForExistence(timeout: WaitTiming.connectionTimeoutSeconds),
            "Saving the settings must open the mode selection page.")
        XCTAssertTrue(
            waitForFocus(random, timeout: WaitTiming.elementAppearanceTimeoutSeconds),
            "Mode selection default focus must be on Random playback.")
        press(.select)
        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds),
            "After choosing Random playback, the Continue button must show.")
        focus(
            continueButton, trying: [.down], maxPresses: 2,
            "After choosing Random playback, focus must be able to move down to Continue.")
        press(.select)
        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: WaitTiming.playbackStartupTimeoutSeconds),
            "The control bar must appear after starting random playback.")
    }

    func applyPlaybackSettings(_ settings: [PlaybackSetting]) {
        openSettings()
        focus(
            app.buttons["settings.item.playback"], trying: [.up], maxPresses: 4,
            "Settings home must be able to focus playback settings.")
        press(.select)
        XCTAssertTrue(
            app.buttons["settings.playback.autoPlay.link"].waitForExistence(
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Must open the playback settings subpage.")
        for setting in settings {
            switch setting {
            case .interval30Seconds:
                choose(link: "settings.playback.interval.link", option: "settings.playback.interval.30.button")
            case .interval15Seconds:
                choose(link: "settings.playback.interval.link", option: "settings.playback.interval.15.button")
            case .displayMode(let isSinglePhoto):
                choose(
                    link: "settings.playback.displayMode.link",
                    option: isSinglePhoto
                        ? "settings.playback.displayMode.singlePhoto.button"
                        : "settings.playback.displayMode.smartFill.button"
                )
            case .showExif(let isOn):
                focusSettingsControl("settings.playback.display.link")
                press(.select)
                choose(
                    link: "settings.playback.showExif.link",
                    option: isOn ? "settings.playback.showExif.on.button" : "settings.playback.showExif.off.button"
                )
                press(.menu)
                XCTAssertTrue(
                    app.buttons["settings.playback.display.link"].waitForExistence(
                        timeout: WaitTiming.settingsChangeTimeoutSeconds),
                    "After Menu, must return to playback settings.")
            }
        }
        returnToPlayback()
    }

    func pause() {
        revealControls()
        let playPause = app.buttons["slideshow.control.playPause.button"]
        focus(playPause, trying: [.right, .left], maxPresses: 3, "Focus must be able to reach play/pause.")
        if playPauseValue(playPause) != "play" { press(.select) }
        XCTAssertTrue(
            Wait.until(timeout: WaitTiming.stateChangeTimeoutSeconds) { playPauseValue(playPause) == "play" },
            "After pausing, the control value must be play.")
    }

    func next() {
        // Wait until the control bar is actually hidden and the receiver layer has focus, then act within a fresh
        // 8-second visible window.
        let receiver = app.descendants(matching: .any).matching(identifier: "slideshow.hiddenWakeReceiver").firstMatch
        XCTAssertTrue(
            Wait.until(timeout: WaitTiming.screenTransitionTimeoutSeconds) { receiver.exists && receiver.hasFocus },
            "Before Next, the control bar must be hidden and the hidden receiver layer must have focus."
        )
        press(.up)
        let nextButton = app.buttons["slideshow.control.next.button"]
        XCTAssertTrue(
            nextButton.waitForExistence(timeout: WaitTiming.stateChangeTimeoutSeconds),
            "After a direction key wakes the controls, Next must show.")
        focus(nextButton, trying: [.right, .left], maxPresses: 3, "Focus must be able to reach Next.")
        press(.select)
    }

    // Before each Menu press, confirm we are not back on the playback layer yet; one press too many sends the app
    // to the Home screen.
    func returnToPlayback() {
        for _ in 0..<8 {
            if Wait.until(timeout: 1.5, { isOnPlaybackLayer() }) { break }
            press(.menu)
        }
        XCTAssertTrue(
            Wait.held(timeout: WaitTiming.controlAppearanceTimeoutSeconds, hold: 1.2) { isOnPlaybackLayer() },
            "Must be able to return from settings to playback."
        )
    }

    func clearDiskCache(onCachePage: () throws -> Void) throws {
        openSettings()
        focusSettingsControl("settings.item.cache")
        press(.select)
        XCTAssertTrue(
            app.buttons["settings.cache.clearDisk.button"].waitForExistence(
                timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Cache page must provide the Clear Disk Cache button.")
        focusSettingsControl("settings.cache.clearDisk.button")
        try onCachePage()
        press(.select)
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let alert = app.alerts.firstMatch
        XCTAssertTrue(
            alert.waitForExistence(timeout: WaitTiming.elementAppearanceTimeoutSeconds),
            "Selecting Clear must show the confirmation alert.")
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let confirmButtons = alert.buttons.matching(NSPredicate(format: "label == %@", "清理"))
        XCTAssertTrue(
            confirmButtons.firstMatch.waitForExistence(timeout: WaitTiming.shortInteractionTimeoutSeconds),
            "Confirmation alert must offer Clear.")
        let hasFocusedConfirm = {
            confirmButtons.allElementsBoundByIndex.contains { $0.exists && $0.hasFocus }
        }
        try Evidence().capture("cache-confirm-alert", from: app)
        if !hasFocusedConfirm() {
            press(.right)
            try Evidence().capture("cache-confirm-right", from: app)
        }
        if !hasFocusedConfirm() {
            press(.left)
            try Evidence().capture("cache-confirm-left", from: app)
        }
        XCTAssertTrue(
            Wait.until(timeout: WaitTiming.shortInteractionTimeoutSeconds) { hasFocusedConfirm() },
            "Alert focus must be able to reach Clear.")
        XCUIRemote.shared.press(.select)
        waitForClearCompletion()
    }

    private func openSettings() {
        revealControls()
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        focus(
            settingsButton, trying: [.left], maxPresses: 6,
            "Before opening settings, focus must be on the settings button.")
        press(.select)
        XCTAssertTrue(
            app.buttons["settings.item.playback"].waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds),
            "Selecting settings must open the settings home.")
    }

    // After Menu, the settings page that owns the link must be visible again.
    private func choose(link: String, option: String) {
        focusSettingsControl(link)
        press(.select)
        let optionButton = app.buttons[option]
        focusSettingsControl(option)
        press(.select)
        XCTAssertTrue(
            Wait.until(timeout: WaitTiming.shortInteractionTimeoutSeconds) { isSelected(optionButton) },
            "After choosing \(option), it must be selected.")
        press(.menu)
        XCTAssertTrue(
            app.buttons[link].waitForExistence(timeout: WaitTiming.settingsChangeTimeoutSeconds),
            "Menu must return to the page with \(link).")
    }

    // The settings page is a single column: search down first, then up if nothing is found at the bottom.
    private func focusSettingsControl(_ identifier: String) {
        focus(app.buttons[identifier], trying: [.down, .up], maxPresses: 7, "Must be able to focus \(identifier).")
    }

    // While the control bar is hidden, the first direction key only wakes it. Wait for the hidden receiver layer
    // to get focus before pressing, and press again at most once.
    private func revealControls() {
        let playPause = app.buttons["slideshow.control.playPause.button"]
        let receiver = app.descendants(matching: .any).matching(identifier: "slideshow.hiddenWakeReceiver").firstMatch
        for _ in 0..<2 where !playPause.exists {
            _ = Wait.until(timeout: WaitTiming.controlAppearanceTimeoutSeconds) {
                playPause.exists || (receiver.exists && receiver.hasFocus)
            }
            if playPause.exists { break }
            press(.up)
            _ = playPause.waitForExistence(timeout: WaitTiming.stateChangeTimeoutSeconds)
        }
        XCTAssertTrue(playPause.exists, "A direction key must wake the playback control bar.")
    }

    private func isOnPlaybackLayer() -> Bool {
        let settingsLayer = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.")).firstMatch
        guard !settingsLayer.exists else { return false }
        return app.buttons["slideshow.control.playPause.button"].exists
            || app.descendants(matching: .any).matching(identifier: "slideshow.hiddenWakeReceiver").firstMatch.exists
    }

    private func replaceFocusedText(in field: XCUIElement, with value: String) {
        XCTAssertTrue(
            waitForFocus(field, timeout: WaitTiming.stateChangeTimeoutSeconds),
            "The field must be focused before input.")
        press(.select)
        app.typeText(value)
        // ui-label-lookup: tvOS owns the on-screen keyboard submit buttons.
        let submit = app.buttons.matching(NSPredicate(format: "label IN %@", ["下一项", "Next", "完成", "Done"])).firstMatch
        XCTAssertTrue(
            submit.waitForExistence(timeout: WaitTiming.stateChangeTimeoutSeconds),
            "The system keyboard must show Next or Done.")
        for _ in 0..<6 where !submit.hasFocus {
            press(.down)
        }
        XCTAssertTrue(submit.hasFocus, "The system keyboard submit button must be focused before submitting text.")
        press(.select)
        press(.menu)
        XCTAssertTrue(
            waitForFocus(field, timeout: WaitTiming.stateChangeTimeoutSeconds),
            "After submitting, focus must return to the original field.")
    }

    private func focus(
        _ element: XCUIElement, trying directions: [XCUIRemote.Button], maxPresses: Int, _ message: String
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds), message)
        for direction in directions {
            for _ in 0..<maxPresses {
                if element.exists && element.hasFocus { return }
                press(direction)
            }
        }
        XCTAssertTrue(waitForFocus(element, timeout: WaitTiming.shortInteractionTimeoutSeconds), message)
    }

    private func waitForFocus(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        Wait.until(timeout: timeout) { element.exists && element.hasFocus }
    }

    private func press(_ button: XCUIRemote.Button) {
        XCUIRemote.shared.press(button)
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusSettle))
    }

    private func firstBootControl(_ identifier: String) -> XCUIElement {
        let button = app.buttons[identifier]
        if button.exists { return button }
        let identified = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        if identified.exists { return identified }
        return identified
    }

    private func isSelected(_ element: XCUIElement) -> Bool {
        let value = String(describing: element.value ?? "")
        return value.contains("已选中") || value.contains("selected")
    }

    private func playPauseValue(_ button: XCUIElement) -> String {
        String(describing: button.value ?? "").lowercased()
    }
}
#endif
