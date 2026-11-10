import XCTest

private enum SwitchGeometry {
    static let trailingTapFraction: CGFloat = 0.93
}

// P2-03 Reduce Motion: change the real system setting and record both display modes in
// separate video segments; only a person watching the recording decides whether there is motion.
final class ReduceMotionUITests: XCTestCase {
    override func invokeTest() {
        FirstFailureContext.reset()
        super.invokeTest()
    }

    override func record(_ issue: XCTIssue) {
        FirstFailureEvidence.record(self, issue: issue)
        super.record(issue)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    #if os(iOS)
    @MainActor
    func testSystemReduceMotionIOS() throws {
        FirstFailureOrientation.set(.portrait)
        let input = try requireStrictE2EInput()
        let evidence = Evidence()
        let system = try HostReduceMotionSetting()
        let original = try system.originalValue()
        try evidence.markStep("motion-system-original")
        let app = try launchStrictE2EApp(recordReduceMotion: true)
        defer { app.terminateForFailureEvidence() }
        let driver = IOSDriver(app: app)
        driver.launchToPlayback(input: input)
        try runMotionSegments(driver, system: system, evidence: evidence, original: original)
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
        let system = try HostReduceMotionSetting()
        let original = try system.originalValue()
        try evidence.markStep("motion-system-original")
        let app = try launchStrictE2EApp(recordReduceMotion: true)
        defer { app.terminateForFailureEvidence() }
        let driver = TVDriver(app: app)
        driver.launchToPlayback(input: input)
        try runMotionSegments(driver, system: system, evidence: evidence, original: original)
    }

    @MainActor
    func testReduceMotionSystemSettingRoundTripsTVOS() throws {
        try runSettingRoundTrip(TVReduceMotionSetting())
    }
    #endif

    // The order matches the p2-reduce-motion contract. With the setting on, the first SmartFill segment should
    // still show the scene from before it was turned on (no timing in the background), and the first single-photo
    // segment is the scene rebuilt in place after switching back to single photo. Both are checked on the recording.
    @MainActor
    private func runMotionSegments(
        _ driver: some PlaybackDriver,
        system: HostReduceMotionSetting,
        evidence: Evidence,
        original: Bool
    ) throws {
        let offNotifications = try system.confirm(
            in: driver.app, isOn: false, phase: "disabled", minimumNotifications: 0)
        driver.applyPlaybackSettings([.interval30Seconds, .displayMode(isSinglePhoto: true)])
        driver.next()
        try recordSegment(
            "motion-off-single", in: driver.app, evidence: evidence, hold: MotionTiming.positiveControlHold)
        driver.applyPlaybackSettings([.displayMode(isSinglePhoto: false)])
        try driver.advanceToMultiPhotoScene()
        try recordSegment(
            "motion-off-smartfill", in: driver.app, evidence: evidence, hold: MotionTiming.positiveControlHold)

        try system.change("enabled", whileBackgrounding: driver.app)
        try evidence.markStep("motion-system-enabled")
        try bringToForeground(driver.app)
        let onNotifications = try system.confirm(
            in: driver.app, isOn: true, phase: "enabled", minimumNotifications: offNotifications + 1)
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

        try system.change("restored", whileBackgrounding: driver.app)
        try bringToForeground(driver.app)
        _ = try system.confirm(
            in: driver.app, isOn: original, phase: "restored",
            minimumNotifications: onNotifications + (original ? 0 : 1))
        try evidence.markStep("motion-system-restored")
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
        app.activateForFailureEvidence()
        guard app.wait(for: .runningForeground, timeout: MotionTiming.foregroundTimeout) else {
            throw Failure("The app did not return to the foreground after changing system Reduce Motion.")
        }
    }

    // Exercise only Settings, reopening it to verify persistence and restoration without launching the App.
    // The StrictE2E evidence directory keeps this system-changing check out of ordinary test runs.
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

// XCTest cannot execute host commands. These files share the strict runner's fresh evidence directory;
// the host owns original-value capture and finally restoration even if XCTest exits before teardown.
@MainActor
private struct HostReduceMotionSetting {
    private let original: Bool
    private let requestTimeoutSeconds: TimeInterval

    private enum HostFailureReason: String {
        case write, notify, readback, timeout
        case requestInvalid = "request-invalid"
    }

    init() throws {
        guard let ready = Self.response(sequence: 0),
            ready["succeeded"] as? Bool == true, ready["failure_reason"] is NSNull,
            let original = ready["original"] as? Bool,
            let timeout = ready["request_timeout_seconds"] as? Double, timeout.isFinite, timeout > 0
        else { throw Failure("System Reduce Motion command: original value is unavailable.") }
        self.original = original
        requestTimeoutSeconds = timeout
    }

    private static func read(_ name: String) -> [String: Any]? {
        guard let directory = StrictE2EVisualEvidence.directory() else { return nil }
        return read(name, in: directory)
    }

    private nonisolated static func read(_ name: String, in directory: URL) -> [String: Any]? {
        guard let bytes = try? Data(contentsOf: directory.appendingPathComponent(name)), bytes.count <= 65536
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }

    func originalValue() throws -> Bool {
        original
    }

    func change(_ phase: String, whileBackgrounding app: XCUIApplication) throws {
        FirstFailureContext.mark("settings-readback", element: "system.reduce-motion")
        let background = TestWait.hangGuard()
        let step = background.transaction()
        guard
            step.perform("press", { XCUIDevice.shared.press(.home) }),
            step.until({
                let state = app.state
                return state == .runningBackground || state == .runningBackgroundSuspended
            })
        else { throw Failure("System Reduce Motion command: App did not enter the background.") }
        let sequence = phase == "enabled" ? 1 : 2
        try StrictE2EVisualEvidence.writeRequiredJSON(
            ["sequence": sequence, "phase": phase, "app_state": "background"], name: "motion-command-request.json")
        guard let reply = Self.response(sequence: sequence, timeoutSeconds: requestTimeoutSeconds) else {
            throw Failure("System Reduce Motion command: timeout.")
        }
        guard reply["succeeded"] as? Bool == true, reply["failure_reason"] is NSNull else {
            let reason =
                (reply["failure_reason"] as? String).flatMap(HostFailureReason.init(rawValue:)) ?? .requestInvalid
            throw Failure("System Reduce Motion command: \(reason.rawValue).")
        }
    }

    private static func response(sequence: Int, timeoutSeconds: TimeInterval? = nil) -> [String: Any]? {
        guard let directory = StrictE2EVisualEvidence.directory() else { return nil }
        let timeout = timeoutSeconds ?? TestWait.hangGuard().remainingSeconds
        // This waits only for host file IO; UI navigation retains its separate default HangGuard.
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                Self.read("motion-command-response.json", in: directory)?["sequence"] as? Int == sequence
            }, object: nil)
        FirstFailureContext.beginWait(seconds: timeout)
        defer { FirstFailureContext.endWait() }
        guard XCTWaiter.wait(for: [ready], timeout: timeout) == .completed,
            let response = read("motion-command-response.json"), response["sequence"] as? Int == sequence
        else { return nil }
        return response
    }

    func confirm(
        in app: XCUIApplication, isOn: Bool, phase: String, minimumNotifications: Int
    ) throws -> Int {
        FirstFailureContext.mark("settings-readback", element: "system.reduce-motion")
        let guardWait = TestWait.hangGuard()
        guard let changes = Self.read("motion-system-command.json")?["changes"] as? [[String: Any]],
            let completed = changes.last(where: { $0["phase"] as? String == phase })?["completed_wall_time"] as? Double
        else { throw Failure("App Reduce Motion: command timestamp is unavailable.") }
        var notificationCount: Int?
        let confirmed = guardWait.transaction().until {
            guard app.state == .runningForeground,
                let samples = Self.read("motion-app-evidence.json")?["samples"] as? [[String: Any]],
                let sample = samples.last, let count = sample["notification_count"] as? Int,
                let wallTime = sample["wall_time"] as? Double,
                wallTime >= completed, sample["app_state"] as? String == "active",
                sample["ui_kit"] as? Bool == isOn, sample["swift_ui"] as? Bool == isOn,
                count >= minimumNotifications
            else { return false }
            notificationCount = count
            return true
        }
        guard confirmed, let notificationCount else {
            throw Failure(
                "App Reduce Motion: UIKit and SwiftUI did not confirm the system change with its notification.")
        }
        return notificationCount
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
    static let settingsPageTimeout: TimeInterval = TestWait.seconds(.product(4))
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

// Read and set open real system Settings and finish on the switch page for screenshots.
@MainActor
private protocol ReduceMotionSystemSetting {
    init()
    func read() throws -> Bool
    // Open Settings before changing the switch, then confirm its value on that page. The separate round trip
    // reopens Settings again to verify persistence.
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
        let png = settings.screenshotForFailureEvidence().pngRepresentation
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
    private static let toggleLabels = ["减弱动态效果", "Reduce Motion"]
    private static let toggleMatch = NSPredicate(format: "label IN %@", toggleLabels)

    private let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")

    func read() throws -> Bool {
        try openToggle().isOn
    }

    func set(_ isOn: Bool) throws {
        // Settings must be in front before the change, preserving the P2 background/resume contract.
        let toggle = try openToggle()
        guard settings.state == .runningForeground else {
            throw ToggleValue.failure("Settings must be foreground before changing Reduce Motion.", in: settings)
        }
        guard toggle.isOn != isOn else { return }
        XCTContext.runActivity(named: "System Reduce Motion: one tap with Settings foreground") { _ in
            settings.coordinate(withNormalizedOffset: .zero)
                .withOffset(
                    CGVector(
                        dx: toggle.frame.minX + toggle.frame.width * SwitchGeometry.trailingTapFraction,
                        dy: toggle.frame.midY)
                )
                .tapForFailureEvidence()
        }
        FirstFailureContext.mark("settings-readback", element: "system.reduce-motion")
        var lastSwitchState: SwitchObservation?
        let didReadBack = XCTContext.runActivity(named: "System Reduce Motion: snapshot readback after one tap") { _ in
            // Match main's combined two readback waits without issuing its center retap.
            TestWait.until(.product(2 * MotionTiming.settingsReadbackTimeout)) {
                lastSwitchState = switchObservation()
                return lastSwitchState?.isOn == isOn
            }
        }
        guard didReadBack else {
            if let lastSwitchState, lastSwitchState.isOn != isOn {
                throw ToggleValue.failure(
                    "Reduce Motion read back after the tap is not \(isOn ? "on" : "off")", in: settings)
            }
            throw ToggleValue.failure("Reduce Motion snapshot readback timed out after one tap.", in: settings)
        }
    }

    func screenshot() -> Data {
        settings.screenshotForFailureEvidence().pngRepresentation
    }

    // Settings may reopen on the last subpage, so step forward through whichever entry is visible. Wait for the
    // next level only after tapping an entry.
    private func openToggle() throws -> SwitchObservation {
        settings.terminateForFailureEvidence()
        settings.launchForFailureEvidence()
        let toggle = settings.switches.matching(Self.toggleMatch).firstMatch
        let motion = entry(Self.motionEntry)
        let accessibility = entry(Self.accessibilityEntry)
        for _ in 0..<MotionTiming.settingsNavigationSteps {
            if toggle.exists { return try waitForSettledSwitch() }
            if motion.exists {
                motion.tapForFailureEvidence()
                return try waitForSettledSwitch()
            } else if accessibility.exists {
                accessibility.tapForFailureEvidence()
                _ = motion.waitForFailureEvidence(timeout: MotionTiming.settingsPageTimeout)
            } else {
                settings.swipeUpForFailureEvidence()
            }
        }
        guard toggle.exists else {
            throw ToggleValue.failure("Cannot find the Reduce Motion switch", in: settings)
        }
        return try waitForSettledSwitch()
    }

    private func entry(_ match: NSPredicate) -> XCUIElement {
        let types = [XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.cell.rawValue]
        let typed = NSPredicate(format: "elementType IN %@", types)
        return settings.descendants(matching: .any)
            .matching(NSCompoundPredicate(andPredicateWithSubpredicates: [typed, match]))
            .firstMatch
    }

    private struct SwitchObservation: Equatable {
        let frame: CGRect
        let isOn: Bool
    }

    private func waitForSettledSwitch() throws -> SwitchObservation {
        FirstFailureContext.mark("query-element", element: "system.reduce-motion")
        var previousSwitchState: SwitchObservation?
        var settledSwitchState: SwitchObservation?
        let isReady = TestWait.until(.product(MotionTiming.settingsPageTimeout)) {
            let currentSwitchState = switchObservation()
            defer { previousSwitchState = currentSwitchState }
            guard let currentSwitchState, currentSwitchState == previousSwitchState else { return false }
            settledSwitchState = currentSwitchState
            return true
        }
        guard isReady, let settledSwitchState else {
            throw ToggleValue.failure("Reduce Motion switch is not ready for system evidence.", in: settings)
        }
        return settledSwitchState
    }

    // Bind value, enabled state and geometry to the system switch in one fresh Settings snapshot.
    private func switchObservation() -> SwitchObservation? {
        guard let root = try? settings.snapshot() else { return nil }
        var switches: [XCUIElementSnapshot] = []
        func visit(_ node: XCUIElementSnapshot) {
            if node.elementType == .switch, Self.toggleLabels.contains(node.label) { switches.append(node) }
            node.children.forEach(visit)
        }
        visit(root)
        guard switches.count == 1, let toggle = switches.first, toggle.isEnabled,
            !toggle.frame.isEmpty, root.frame.contains(toggle.frame),
            let isOn = ToggleValue.parse(toggle.value.map { String(describing: $0) })
        else { return nil }
        return SwitchObservation(frame: toggle.frame, isOn: isOn)
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
        settings.screenshotForFailureEvidence().pngRepresentation
    }

    // Off-screen rows may not exist yet, so move down one row when no entry is found. Wait for the target only
    // after entering the next level.
    private func openToggle() throws -> XCUIElement {
        settings.terminateForFailureEvidence()
        settings.launchForFailureEvidence()
        let toggle = row(Self.toggleLabels)
        let motion = row(Self.motionLabels)
        let accessibility = row(Self.accessibilityLabels)
        for _ in 0..<MotionTiming.settingsNavigationSteps {
            if toggle.exists { return toggle }
            if motion.exists {
                try focus(motion)
                press(.select)
                _ = toggle.waitForFailureEvidence(timeout: MotionTiming.settingsPageTimeout)
            } else if accessibility.exists {
                try focus(accessibility)
                press(.select)
                _ = motion.waitForFailureEvidence(timeout: MotionTiming.settingsPageTimeout)
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
        FirstFailureRemote.press(button)
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusSettle))
    }
}
#endif
