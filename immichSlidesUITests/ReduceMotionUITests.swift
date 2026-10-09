import XCTest

private enum SwitchGeometry {
    static let trailingTapFraction: CGFloat = 0.93
}

// P2-03 Reduce Motion: toggle "Reduce Motion" through the real system settings and record both display modes in
// separate video segments; only a person watching the recording decides whether there is motion.
final class ReduceMotionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    #if os(iOS)
    @MainActor
    func testSystemReduceMotionIOS() throws {
        XCUIDevice.shared.orientation = .portrait
        let input = try requireStrictE2EInput()
        let evidence = Evidence()
        let restore = try recordOriginalAndDisable(IOSReduceMotionSetting(), evidence: evidence)
        let app = try launchStrictE2EApp()
        defer { app.terminate() }
        let driver = IOSDriver(app: app)
        driver.launchToPlayback(input: input)
        try runMotionSegments(driver, system: IOSReduceMotionSetting(), evidence: evidence, restore: restore)
    }

    @MainActor
    func testReduceMotionSystemSettingRoundTripsIOS() throws {
        try runSettingRoundTrip(IOSReduceMotionSetting())
    }
    #endif

    #if os(tvOS)
    @MainActor
    func testSystemReduceMotionTVOS() throws {
        let input = try requireStrictE2EInput()
        let evidence = Evidence()
        let restore = try recordOriginalAndDisable(TVReduceMotionSetting(), evidence: evidence)
        let app = try launchStrictE2EApp()
        defer { app.terminate() }
        let driver = TVDriver(app: app)
        driver.launchToPlayback(input: input)
        try runMotionSegments(driver, system: TVReduceMotionSetting(), evidence: evidence, restore: restore)
    }

    @MainActor
    func testReduceMotionSystemSettingRoundTripsTVOS() throws {
        try runSettingRoundTrip(TVReduceMotionSetting())
    }
    #endif

    // If the original value is on, turn it off and capture the off state first so the positive control means
    // something; register the restore as soon as the original value is read.
    @MainActor
    private func recordOriginalAndDisable<System: ReduceMotionSystemSetting>(
        _ system: System,
        evidence: Evidence
    ) throws -> ReduceMotionRestore {
        let isOriginallyOn = try system.read()
        let restore = registerRestore(System.self, isOriginallyOn: isOriginallyOn)
        try evidence.record(
            "motion-system-original", png: system.screenshot(), capturedAt: Date(), orientation: .notApplicable)
        if isOriginallyOn {
            try system.set(false)
            try evidence.record(
                "motion-system-disabled", png: system.screenshot(), capturedAt: Date(), orientation: .notApplicable)
        }
        return restore
    }

    // The order matches the p2-reduce-motion contract. With the setting on, the first SmartFill segment should
    // still show the scene from before it was turned on (no timing in the background), and the first single-photo
    // segment is the scene rebuilt in place after switching back to single photo. Both are checked on the recording.
    @MainActor
    private func runMotionSegments(
        _ driver: some PlaybackDriver,
        system: some ReduceMotionSystemSetting,
        evidence: Evidence,
        restore: ReduceMotionRestore
    ) throws {
        driver.applyPlaybackSettings([.interval30Seconds, .displayMode(isSinglePhoto: true)])
        driver.next()
        try recordSegment(
            "motion-off-single", in: driver.app, evidence: evidence, hold: MotionTiming.positiveControlHold)
        driver.applyPlaybackSettings([.displayMode(isSinglePhoto: false)])
        try driver.advanceToMultiPhotoScene()
        try recordSegment(
            "motion-off-smartfill", in: driver.app, evidence: evidence, hold: MotionTiming.positiveControlHold)

        try system.set(true)
        try evidence.record(
            "motion-system-enabled", png: system.screenshot(), capturedAt: Date(), orientation: .notApplicable)
        try bringToForeground(driver.app)
        try recordSegment(
            "motion-on-smartfill", in: driver.app, evidence: evidence, hold: MotionTiming.reducedMotionHold)
        driver.next()
        try recordSegment(
            "motion-on-smartfill-next", in: driver.app, evidence: evidence, hold: MotionTiming.reducedMotionHold)
        driver.applyPlaybackSettings([.displayMode(isSinglePhoto: true)])
        try recordSegment("motion-on-single", in: driver.app, evidence: evidence, hold: MotionTiming.reducedMotionHold)
        driver.next()
        try recordSegment(
            "motion-on-single-next", in: driver.app, evidence: evidence, hold: MotionTiming.reducedMotionHold)

        try system.set(restore.isOriginallyOn)
        try evidence.record(
            "motion-system-restored", png: system.screenshot(), capturedAt: Date(), orientation: .notApplicable)
        restore.isSettled = true
    }

    // Pixel-difference thresholds cannot replace human review of the recording.
    @MainActor
    private func recordSegment(_ name: String, in app: XCUIApplication, evidence: Evidence, hold: TimeInterval) throws {
        let frame = StableFrame.wait(in: app, orientation: .notApplicable, accept: StableFrame.showsFixturePhoto)
        guard frame.isStable else {
            try evidence.reject(name, png: frame.png)
            throw Failure("\(name) timed out waiting for a stable frame: \(frame.detail)")
        }
        try evidence.markStep(name)
        RunLoop.current.run(until: Date().addingTimeInterval(hold))
    }

    @MainActor
    private func bringToForeground(_ app: XCUIApplication) throws {
        app.activate()
        guard app.wait(for: .runningForeground, timeout: MotionTiming.foregroundTimeout) else {
            throw Failure("The app did not return to the foreground after leaving system settings.")
        }
    }

    // Only flips the system switch and reads the persisted value back by reopening settings each time; the app is
    // not touched. It changes system settings, so it runs only in the StrictE2E plan with an evidence directory.
    @MainActor
    private func runSettingRoundTrip<System: ReduceMotionSystemSetting>(_ system: System) throws {
        guard StrictE2EVisualEvidence.directory() != nil else {
            throw XCTSkip(
                "Temporarily toggles system Reduce Motion; runs only in the StrictE2E plan with an evidence directory.")
        }
        let isOriginallyOn = try system.read()
        let restore = registerRestore(System.self, isOriginallyOn: isOriginallyOn)
        try StrictE2EVisualEvidence.writeRequiredPNG(system.screenshot(), name: "selfcheck-reduce-motion-original")
        try system.set(!isOriginallyOn)
        let isFlippedOn = try system.read()
        try StrictE2EVisualEvidence.writeRequiredPNG(system.screenshot(), name: "selfcheck-reduce-motion-flipped")
        try system.set(isOriginallyOn)
        let isRestoredOn = try system.read()
        try StrictE2EVisualEvidence.writeRequiredPNG(system.screenshot(), name: "selfcheck-reduce-motion-restored")
        try StrictE2EVisualEvidence.writeRequiredJSON(
            ["original": isOriginallyOn, "flipped_readback": isFlippedOn, "restored_readback": isRestoredOn],
            name: "selfcheck-reduce-motion.json"
        )
        guard isFlippedOn == !isOriginallyOn, isRestoredOn == isOriginallyOn else {
            throw Failure(
                "Reopened readback mismatch: original \(isOriginallyOn), flipped \(isFlippedOn), restored \(isRestoredOn)."
            )
        }
        restore.isSettled = true
    }

    // The main flow sets isSettled after reading back the original value. On failure paths the teardown restores
    // it as a fallback; if that fails too, the manual steps go into the failure message.
    @MainActor
    private func registerRestore<System: ReduceMotionSystemSetting>(
        _: System.Type,
        isOriginallyOn: Bool
    ) -> ReduceMotionRestore {
        let restore = ReduceMotionRestore(isOriginallyOn: isOriginallyOn)
        addTeardownBlock { @MainActor in
            guard !restore.isSettled else { return }
            do {
                try System().set(restore.isOriginallyOn)
            } catch {
                throw Failure(
                    "System Reduce Motion not restored to \(restore.isOriginallyOn ? "on" : "off"): \(error.localizedDescription)"
                        + ". Environment not cleaned up. Restore by hand: Simulator Settings › Accessibility › Motion › Reduce Motion, set it back to the original value, read it back, then rerun."
                )
            }
        }
        return restore
    }
}

private enum MotionTiming {
    // Off-state positive control hold, in seconds: watch 8 s at a 30 s interval so slow zoom and pan are visible.
    static let positiveControlHold: TimeInterval = TestWait.seconds(.product(8))
    // On-state hold per segment, in seconds: the same scene and the new scene after next each need at least
    // 3 s of stability, plus a 0.5 s margin.
    static let reducedMotionHold: TimeInterval = TestWait.seconds(.product(3.5))
    static let foregroundTimeout: TimeInterval = TestWait.seconds(.infrastructure(10))
    static let settingsNavigationSteps = 6
    static let settingsPageTimeout: TimeInterval = TestWait.seconds(.infrastructure(4))
    static let settingsReadbackTimeout: TimeInterval = TestWait.seconds(.product(3))
}

@MainActor
private final class ReduceMotionRestore {
    let isOriginallyOn: Bool
    var isSettled = false

    init(isOriginallyOn: Bool) {
        self.isOriginallyOn = isOriginallyOn
    }
}

// Every operation reopens system settings from its main page; read / set end on the switch's page for screenshots.
@MainActor
private protocol ReduceMotionSystemSetting {
    init()
    func read() throws -> Bool
    // Switch to the target value and read it back on the same page. Persistence is proven separately by the
    // self-check's reopening read(); the real test skips the reopen to save time.
    func set(_ isOn: Bool) throws
    func screenshot() -> Data
}

private enum ToggleValue {
    // The switch's accessibility value varies by platform and language. Accept only explicit on / off spellings
    // and treat anything else as unreadable.
    static func parse(_ value: Any?) -> Bool? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        switch text {
        case "1", "开", "打开", "on": return true
        case "0", "关", "关闭", "off": return false
        default: return nil
        }
    }

    // Writes the system settings screen and element tree as failure evidence, so call it only where the final
    // error is thrown; use parse while polling.
    @MainActor
    static func failure(_ message: String, in settings: XCUIApplication) -> Failure {
        let png = settings.screenshot().pngRepresentation
        let tree = settings.debugDescription
        XCTContext.runActivity(named: "System settings failure evidence") { activity in
            let screen = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            screen.name = "system-settings-failure"
            screen.lifetime = .keepAlways
            activity.add(screen)
            let text = XCTAttachment(string: tree)
            text.name = "system-settings-failure-tree"
            text.lifetime = .keepAlways
            activity.add(text)
        }
        StrictE2EVisualEvidence.writePNG(png, name: "system-settings-failure")
        StrictE2EVisualEvidence.writeJSON(["message": message, "tree": tree], name: "system-settings-failure.json")
        return Failure("System settings: \(message)")
    }
}

#if os(iOS)
@MainActor
private struct IOSReduceMotionSetting: ReduceMotionSystemSetting {
    // ui-label-lookup: The Accessibility row belongs to the system Settings app.
    private static let accessibilityEntry = NSPredicate(
        format: "identifier == %@ OR label IN %@",
        "com.apple.settings.accessibility",
        ["无障碍", "辅助功能", "Accessibility"]
    )
    // ui-label-lookup: The Motion row belongs to the system Settings app.
    private static let motionEntry = NSPredicate(format: "label IN %@", ["动态效果", "Motion"])
    // ui-label-lookup: The Reduce Motion toggle belongs to the system Settings app.
    private static let toggleMatch = NSPredicate(format: "label IN %@", ["减弱动态效果", "Reduce Motion"])

    private let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")

    func read() throws -> Bool {
        try value(of: openToggle())
    }

    func set(_ isOn: Bool) throws {
        let toggle = try openToggle()
        // The switch's tappable area varies by OS version: tap the switch position at the right of the row first,
        // then fall back to the element center.
        let taps: [() -> Void] = [
            {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: SwitchGeometry.trailingTapFraction, dy: 0.5)).tap()
            },
            { toggle.tap() }
        ]
        for tap in taps where ToggleValue.parse(toggle.value) != isOn {
            tap()
            _ = Wait.until(timeout: MotionTiming.settingsReadbackTimeout) { ToggleValue.parse(toggle.value) == isOn }
        }
        guard try value(of: toggle) == isOn else {
            throw ToggleValue.failure(
                "Reduce Motion read back after the tap is not \(isOn ? "on" : "off")", in: settings)
        }
    }

    func screenshot() -> Data {
        settings.screenshot().pngRepresentation
    }

    // Settings may reopen on the last subpage, so step forward through whichever entry is visible. Wait for the
    // next level only after tapping an entry.
    private func openToggle() throws -> XCUIElement {
        settings.terminate()
        settings.launch()
        let toggle = settings.switches.matching(Self.toggleMatch).firstMatch
        let motion = entry(Self.motionEntry)
        let accessibility = entry(Self.accessibilityEntry)
        for _ in 0..<MotionTiming.settingsNavigationSteps {
            if toggle.exists { return toggle }
            if motion.exists {
                motion.tap()
                _ = toggle.waitForExistence(timeout: MotionTiming.settingsPageTimeout)
            } else if accessibility.exists {
                accessibility.tap()
                _ = motion.waitForExistence(timeout: MotionTiming.settingsPageTimeout)
            } else {
                settings.swipeUp()
            }
        }
        guard toggle.exists else {
            throw ToggleValue.failure("Cannot find the 'Reduce Motion' switch", in: settings)
        }
        return toggle
    }

    private func entry(_ match: NSPredicate) -> XCUIElement {
        let types = [XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.cell.rawValue]
        let typed = NSPredicate(format: "elementType IN %@", types)
        return settings.descendants(matching: .any)
            .matching(NSCompoundPredicate(andPredicateWithSubpredicates: [typed, match]))
            .firstMatch
    }

    private func value(of toggle: XCUIElement) throws -> Bool {
        guard let isOn = ToggleValue.parse(toggle.value) else {
            throw ToggleValue.failure("Cannot read the switch value: \(String(describing: toggle.value))", in: settings)
        }
        return isOn
    }
}
#endif

#if os(tvOS)
@MainActor
private struct TVReduceMotionSetting: ReduceMotionSystemSetting {
    // ui-label-lookup: These navigation labels belong to the system Settings app.
    private static let accessibilityLabels = ["辅助功能", "无障碍", "Accessibility"]
    // ui-label-lookup: This navigation label belongs to the system Settings app.
    private static let motionLabels = ["动态效果", "Motion"]
    // ui-label-lookup: This toggle label belongs to the system Settings app.
    private static let toggleLabels = ["减弱动态效果", "Reduce Motion"]
    // The settings list is a single column; fail if focus is still not reached after this many arrow presses.
    private static let maxFocusPresses = 16

    private let settings = XCUIApplication(bundleIdentifier: "com.apple.TVSettings")

    func read() throws -> Bool {
        try value(of: openToggle())
    }

    func set(_ isOn: Bool) throws {
        let toggle = try openToggle()
        if try value(of: toggle) != isOn {
            try focus(toggle)
            press(.select)
            _ = Wait.until(timeout: MotionTiming.settingsReadbackTimeout) { parsedValue(of: toggle) == isOn }
        }
        guard try value(of: toggle) == isOn else {
            throw ToggleValue.failure(
                "Reduce Motion read back after Select is not \(isOn ? "on" : "off")", in: settings)
        }
    }

    func screenshot() -> Data {
        settings.screenshot().pngRepresentation
    }

    // Off-screen rows may not exist yet, so move down one row when no entry is found. Wait for the target only
    // after entering the next level.
    private func openToggle() throws -> XCUIElement {
        settings.terminate()
        settings.launch()
        let toggle = row(Self.toggleLabels)
        let motion = row(Self.motionLabels)
        let accessibility = row(Self.accessibilityLabels)
        for _ in 0..<MotionTiming.settingsNavigationSteps {
            if toggle.exists { return toggle }
            if motion.exists {
                try focus(motion)
                press(.select)
                _ = toggle.waitForExistence(timeout: MotionTiming.settingsPageTimeout)
            } else if accessibility.exists {
                try focus(accessibility)
                press(.select)
                _ = motion.waitForExistence(timeout: MotionTiming.settingsPageTimeout)
            } else {
                press(.down)
            }
        }
        guard toggle.exists else {
            throw ToggleValue.failure("Cannot find the 'Reduce Motion' row", in: settings)
        }
        return toggle
    }

    private func row(_ labels: [String]) -> XCUIElement {
        let types = [XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.cell.rawValue]
        return settings.descendants(matching: .any)
            // ui-label-lookup: These rows belong to the system Settings app.
            .matching(NSPredicate(format: "elementType IN %@ AND label IN %@", types, labels))
            .firstMatch
    }

    private func focus(_ element: XCUIElement) throws {
        for direction in [XCUIRemote.Button.down, .up] {
            for _ in 0..<Self.maxFocusPresses where !element.hasFocus {
                press(direction)
            }
        }
        guard element.hasFocus else {
            throw ToggleValue.failure("Cannot move focus to '\(element.label)'", in: settings)
        }
    }

    private func value(of toggle: XCUIElement) throws -> Bool {
        guard let isOn = parsedValue(of: toggle) else {
            let texts = toggle.staticTexts.allElementsBoundByIndex.map(\.label)
            throw ToggleValue.failure(
                "Cannot read the switch value: value=\(String(describing: toggle.value)) texts=\(texts)", in: settings)
        }
        return isOn
    }

    // The value may sit on the row itself or in the row's on / off text. Polling uses only this and records no
    // failure evidence.
    private func parsedValue(of toggle: XCUIElement) -> Bool? {
        if let isOn = ToggleValue.parse(toggle.value) { return isOn }
        return toggle.staticTexts.allElementsBoundByIndex.lazy.compactMap { ToggleValue.parse($0.label) }.first
    }

    private func press(_ button: XCUIRemote.Button) {
        XCUIRemote.shared.press(button)
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusSettle))
    }
}
#endif
