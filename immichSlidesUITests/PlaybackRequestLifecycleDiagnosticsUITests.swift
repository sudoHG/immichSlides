import XCTest

#if os(iOS)
final class PlaybackRequestLifecycleDiagnosticsUITests: XCTestCase {
    private let previousFlowTransitionSettleDelay: TimeInterval = TestWait.seconds(.product(0.65))

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testSmartFillWarmNext60RequestLifecycleDiagnostics() throws {
        try runDiagnosticsFlow(mode: .smartFill, action: .next, actionCount: 60)
    }

    @MainActor
    func testSingleWarmNext60RequestLifecycleDiagnostics() throws {
        try runDiagnosticsFlow(mode: .singlePhoto, action: .next, actionCount: 60)
    }

    @MainActor
    func testSmartFillWarmPrevious30RequestLifecycleDiagnostics() throws {
        try runDiagnosticsFlow(mode: .smartFill, action: .previous, actionCount: 30, warmupNextCount: 35)
    }

    @MainActor
    func testSingleWarmPrevious30RequestLifecycleDiagnostics() throws {
        try runDiagnosticsFlow(mode: .singlePhoto, action: .previous, actionCount: 30, warmupNextCount: 35)
    }

    @MainActor
    func testSinglePhotoKenBurnsRuntimeSnapshots() throws {
        try runSinglePhotoKenBurnsRuntimeSnapshots()
    }
}

private extension PlaybackRequestLifecycleDiagnosticsUITests {
    enum PlaybackMode: String {
        case smartFill = "smartfill"
        case singlePhoto = "single"
    }

    enum PlaybackAction: String {
        case next
        case previous
    }

    struct FlowBehaviorSummary {
        let phase: String
        let mode: PlaybackMode
        let action: PlaybackAction
        let requestedTapCount: Int
        let actualTapCount: Int
        let changedCount: Int
        let uniqueAssetCount: Int
        let initialAssetId: String
        let finalAssetId: String

        var jsonObject: [String: Any] {
            [
                "schemaVersion": "playback-request-lifecycle-ui-flow-v1",
                "phase": phase,
                "mode": mode.rawValue,
                "action": action.rawValue,
                "requestedTapCount": requestedTapCount,
                "actualTapCount": actualTapCount,
                "changedCount": changedCount,
                "uniqueAssetCount": uniqueAssetCount,
                "initialAssetId": initialAssetId,
                "finalAssetId": finalAssetId,
                "xctestMetrics": "CPU and memory are recorded in the xcresult for this UI test run"
            ]
        }
    }

    func runDiagnosticsFlow(
        mode: PlaybackMode,
        action: PlaybackAction,
        actionCount: Int,
        warmupNextCount: Int = 0
    ) throws {
        let flowDirectory = try evidenceDirectory(mode: mode, action: action, actionCount: actionCount)
        try FileManager.default.createDirectory(at: flowDirectory, withIntermediateDirectories: true)
        try writeText(
            "xcodebuild test -scheme immichSlides-iOS -only-testing:immichSlidesUITests/PlaybackRequestLifecycleDiagnosticsUITests/\(testName(mode: mode, action: action, actionCount: actionCount))\n",
            to: flowDirectory.appending(path: "command.txt")
        )

        let app = try launchConfiguredApp(mode: mode, evidenceDirectory: flowDirectory)
        defer { app.terminate() }
        let initialAssetId =
            waitForCurrentAssetID(app: app, timeout: TestWait.seconds(.infrastructure(30))) ?? "missing"
        try writeScreenshot(app: app, to: flowDirectory.appending(path: "playback-initial.png"))
        try writeText(
            historyLedgerSummaryLabel(app: app), to: flowDirectory.appending(path: "playback-history-initial.json"))

        if warmupNextCount > 0 {
            let warmupResult = performPlaybackActions(
                app: app,
                action: .next,
                count: warmupNextCount,
                postChangeSettleDelay: previousFlowTransitionSettleDelay
            )
            let warmupSummary = FlowBehaviorSummary(
                phase: "warmup",
                mode: mode,
                action: .next,
                requestedTapCount: warmupNextCount,
                actualTapCount: warmupResult.actualTapCount,
                changedCount: warmupResult.changedCount,
                uniqueAssetCount: warmupResult.uniqueAssetCount,
                initialAssetId: initialAssetId,
                finalAssetId: warmupResult.finalAssetId
            )
            try writeJSON(warmupSummary.jsonObject, to: flowDirectory.appending(path: "playback-warmup-summary.json"))
            try writeText(
                historyLedgerSummaryLabel(app: app),
                to: flowDirectory.appending(path: "playback-history-after-warmup.json"))
            assertCompletePlaybackAction(summary: warmupSummary)
        }

        var behaviorSummary = FlowBehaviorSummary(
            phase: "measured",
            mode: mode,
            action: action,
            requestedTapCount: actionCount,
            actualTapCount: 0,
            changedCount: 0,
            uniqueAssetCount: 0,
            initialAssetId: initialAssetId,
            finalAssetId: initialAssetId
        )
        let measureOptions = XCTMeasureOptions()
        measureOptions.iterationCount = 1
        measureOptions.invocationOptions = [.manuallyStart, .manuallyStop]
        var measureInvocationCount = 0
        var rebuildSummary: FlowBehaviorSummary?
        measure(metrics: [XCTCPUMetric(application: app), XCTMemoryMetric(application: app)], options: measureOptions) {
            measureInvocationCount += 1
            if action == .previous && measureInvocationCount > 1 {
                let rebuildInitialAssetId = currentAssetID(app: app) ?? "missing"
                let rebuildResult = performPlaybackActions(
                    app: app,
                    action: .next,
                    count: actionCount,
                    postChangeSettleDelay: previousFlowTransitionSettleDelay
                )
                rebuildSummary = FlowBehaviorSummary(
                    phase: "measure-rebuild",
                    mode: mode,
                    action: .next,
                    requestedTapCount: actionCount,
                    actualTapCount: rebuildResult.actualTapCount,
                    changedCount: rebuildResult.changedCount,
                    uniqueAssetCount: rebuildResult.uniqueAssetCount,
                    initialAssetId: rebuildInitialAssetId,
                    finalAssetId: rebuildResult.finalAssetId
                )
            }

            let measuredInitialAssetId = currentAssetID(app: app) ?? "missing"
            startMeasuring()
            let result = performPlaybackActions(
                app: app,
                action: action,
                count: actionCount,
                postChangeSettleDelay: action == .previous ? previousFlowTransitionSettleDelay : 0
            )
            stopMeasuring()
            behaviorSummary = FlowBehaviorSummary(
                phase: "measured",
                mode: mode,
                action: action,
                requestedTapCount: actionCount,
                actualTapCount: result.actualTapCount,
                changedCount: result.changedCount,
                uniqueAssetCount: result.uniqueAssetCount,
                initialAssetId: measuredInitialAssetId,
                finalAssetId: result.finalAssetId
            )
        }

        if let rebuildSummary {
            try writeJSON(
                rebuildSummary.jsonObject, to: flowDirectory.appending(path: "playback-measure-rebuild-summary.json"))
            assertCompletePlaybackAction(summary: rebuildSummary)
        }
        try writeJSON(behaviorSummary.jsonObject, to: flowDirectory.appending(path: "playback-summary.json"))
        try writeText(
            requestLifecycleSummaryLabel(app: app),
            to: flowDirectory.appending(path: "playback-request-lifecycle-summary-from-probe.json"))
        try flushRequestLifecycleEvidence(app: app, flowDirectory: flowDirectory)
        try writeText(
            historyLedgerSummaryLabel(app: app),
            to: flowDirectory.appending(path: "playback-history-after-measured.json"))
        assertCompletePlaybackAction(summary: behaviorSummary)
        try writeText("0\n", to: flowDirectory.appending(path: "exit_code.txt"))
    }

    func launchConfiguredApp(mode: PlaybackMode, evidenceDirectory: URL) throws -> XCUIApplication {
        let config = try requireTestServerConfig()
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        app.launchEnvironment["UI_TEST_FORCE_AUTOPLAY_OFF"] = "1"
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        app.launchEnvironment["IMMICHSLIDES_PLAYBACK_CPU_DIAGNOSTICS"] = "1"
        app.launchEnvironment["UI_TEST_EVIDENCE_DIR"] = evidenceDirectory.path
        app.launchEnvironment["UI_TEST_SERVER_URL"] = config.url
        app.launchEnvironment["UI_TEST_API_KEY"] = config.apiKey
        let runnerEnvironment = ProcessInfo.processInfo.environment
        let baselineMode =
            runnerEnvironment["TEST_RUNNER_UI_TEST_PLAYBACK_REQUEST_LIFECYCLE_BASELINE"]
            ?? runnerEnvironment["UI_TEST_PLAYBACK_REQUEST_LIFECYCLE_BASELINE"]
        if baselineMode == "legacy-priority-upgrade" {
            app.launchEnvironment["IMMICHSLIDES_PLAYBACK_REQUEST_LIFECYCLE_LEGACY_PRIORITY_UPGRADE"] = "1"
        }
        if mode == .singlePhoto {
            app.launchEnvironment["IMMICHSLIDES_DISABLE_SMART_FILL"] = "1"
        }
        app.launch()

        XCTAssertTrue(
            app.buttons["mode.continue.button"].waitForExistence(timeout: TestWait.seconds(.infrastructure(15))),
            "After injecting the real server, the app should open the mode selection page"
        )
        startRandomPlaybackFromModeSelection(app: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["slideshow.requestLifecycle.summary.flag"].waitForExistence(
                timeout: TestWait.seconds(.infrastructure(15))),
            "With playback request lifecycle diagnostics on, the playback page should expose the summary probe"
        )
        return app
    }

    func runSinglePhotoKenBurnsRuntimeSnapshots() throws {
        let flowDirectory = try requireEvidenceRoot()
            .appending(path: "single-photo-ken-burns")
        try FileManager.default.createDirectory(at: flowDirectory, withIntermediateDirectories: true)
        try writeText(
            "xcodebuild test -scheme immichSlides-iOS -only-testing:immichSlidesUITests/PlaybackRequestLifecycleDiagnosticsUITests/testSinglePhotoKenBurnsRuntimeSnapshots\n",
            to: flowDirectory.appending(path: "command.txt")
        )

        let app = try launchConfiguredApp(mode: .singlePhoto, evidenceDirectory: flowDirectory)
        defer { app.terminate() }

        let settledAssetId =
            waitForCurrentAssetID(app: app, timeout: TestWait.seconds(.infrastructure(30))) ?? "missing"
        try writeText("\(settledAssetId)\n", to: flowDirectory.appending(path: "settled-asset-id.txt"))
        try writeScreenshot(app: app, to: flowDirectory.appending(path: "single-kenburns-t00.png"))
        RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(6))))
        try writeScreenshot(app: app, to: flowDirectory.appending(path: "single-kenburns-t06.png"))
        RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(6))))
        try writeScreenshot(app: app, to: flowDirectory.appending(path: "single-kenburns-t12.png"))
        try writeText("0\n", to: flowDirectory.appending(path: "exit_code.txt"))
    }

    func startRandomPlaybackFromModeSelection(app: XCUIApplication) {
        let randomButton = app.buttons["mode.random.button"]
        XCTAssertTrue(
            randomButton.waitForExistence(timeout: TestWait.seconds(.infrastructure(10))),
            "Mode selection page should show random playback")
        tapElement(randomButton)

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: TestWait.seconds(.product(10))),
            "Mode selection page should show Continue")
        XCTAssertTrue(continueButton.isEnabled, "After selecting random playback, Continue should be tappable")
        tapElement(continueButton)

        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: TestWait.seconds(.product(30))),
            "After entering playback, the control bar should be shown"
        )
    }

    func performPlaybackActions(
        app: XCUIApplication,
        action: PlaybackAction,
        count: Int,
        postChangeSettleDelay: TimeInterval = 0
    ) -> (actualTapCount: Int, changedCount: Int, uniqueAssetCount: Int, finalAssetId: String) {
        let buttonIdentifier =
            action == .next
            ? "slideshow.control.next.button"
            : "slideshow.control.previous.button"
        let button = app.buttons[buttonIdentifier]
        var observedAssetIds: [String] = []
        var actualTapCount = 0
        var changedCount = 0
        var previousAssetId = currentAssetID(app: app)
        if let previousAssetId {
            observedAssetIds.append(previousAssetId)
        }

        for _ in 0..<count {
            guard button.waitForExistence(timeout: TestWait.seconds(.product(5))), button.isEnabled else {
                break
            }
            tapElement(button)
            actualTapCount += 1
            let nextAssetId =
                waitForCurrentAssetIDChange(app: app, from: previousAssetId, timeout: TestWait.seconds(.product(10)))
                ?? currentAssetID(app: app)
            if let nextAssetId {
                if nextAssetId != previousAssetId {
                    changedCount += 1
                }
                observedAssetIds.append(nextAssetId)
                previousAssetId = nextAssetId
            }
            if postChangeSettleDelay > 0 {
                RunLoop.current.run(until: Date().addingTimeInterval(postChangeSettleDelay))
            }
        }

        return (
            actualTapCount,
            changedCount,
            Set(observedAssetIds).count,
            previousAssetId ?? "missing"
        )
    }

    func requestLifecycleSummaryLabel(app: XCUIApplication) -> String {
        let probe = app.descendants(matching: .any)["slideshow.requestLifecycle.summary.flag"]
        guard probe.waitForExistence(timeout: TestWait.seconds(.infrastructure(5))) else { return "{}" }
        return probe.label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func flushRequestLifecycleEvidence(app: XCUIApplication, flowDirectory: URL) throws {
        let flushButton = app.buttons["slideshow.requestLifecycle.flush.button"]
        XCTAssertTrue(
            flushButton.waitForExistence(timeout: TestWait.seconds(.infrastructure(5))),
            "Playback request lifecycle diagnostics should expose an explicit flush control")
        tapElement(flushButton)
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.infrastructure(5))) {
                self.requestLifecycleEvidenceFlushCount(app: app) == 1
            },
            "After an explicit flush, the read-only summary probe should observe evidenceFlushCount == 1"
        )
        let summaryURL = flowDirectory.appending(path: "playback-request-lifecycle-summary.json")
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.infrastructure(5))) {
                FileManager.default.fileExists(atPath: summaryURL.path)
            },
            "After an explicit flush, the in-app summary artifact should be written once"
        )
    }

    func requestLifecycleEvidenceFlushCount(app: XCUIApplication) -> Int? {
        let label = requestLifecycleSummaryLabel(app: app)
        guard let data = label.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json["evidenceFlushCount"] as? Int
    }

    func historyLedgerSummaryLabel(app: XCUIApplication) -> String {
        let probe = app.descendants(matching: .any)["slideshow.historyLedger.summary.flag"]
        guard probe.waitForExistence(timeout: TestWait.seconds(.infrastructure(5))) else { return "{}" }
        return probe.label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func assertCompletePlaybackAction(summary: FlowBehaviorSummary) {
        XCTAssertEqual(
            summary.actualTapCount,
            summary.requestedTapCount,
            "\(summary.phase) \(summary.action.rawValue) should actually run all \(summary.requestedTapCount) times, otherwise the diagnostic sample is unusable"
        )
        XCTAssertEqual(
            summary.changedCount,
            summary.requestedTapCount,
            "\(summary.phase) \(summary.action.rawValue) should produce \(summary.requestedTapCount) visible photo changes, otherwise it is not a valid diagnostic sample"
        )
    }

    func waitForCurrentAssetID(app: XCUIApplication, timeout: TimeInterval) -> String? {
        waitUntil(timeout: timeout) { self.currentAssetID(app: app) != nil }
            ? currentAssetID(app: app)
            : nil
    }

    func waitForCurrentAssetIDChange(
        app: XCUIApplication,
        from oldValue: String?,
        timeout: TimeInterval
    ) -> String? {
        guard let oldValue else {
            return waitForCurrentAssetID(app: app, timeout: timeout)
        }
        return waitUntil(timeout: timeout) {
            guard let value = self.currentAssetID(app: app) else { return false }
            return value != oldValue
        } ? currentAssetID(app: app) : nil
    }

    func currentAssetID(app: XCUIApplication) -> String? {
        let probe = app.descendants(matching: .any)["slideshow.currentAssetId.flag"]
        guard probe.exists else { return nil }
        let label = probe.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty || label == "no-asset" ? nil : label
    }

    func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
            return
        }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.2))))
        }
        return condition()
    }

    func evidenceDirectory(
        mode: PlaybackMode,
        action: PlaybackAction,
        actionCount: Int
    ) throws -> URL {
        let flowName = action == .next ? "next\(actionCount)" : "previous\(actionCount)"
        return try requireEvidenceRoot()
            .appending(path: mode.rawValue)
            .appending(path: flowName)
    }

    func requireEvidenceRoot() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let rootPath = environment["TEST_RUNNER_UI_TEST_EVIDENCE_ROOT"] ?? environment["UI_TEST_EVIDENCE_ROOT"]
        guard
            let directory = try PrivateEvidenceDirectory.resolve(
                rootPath: rootPath,
                components: ["playback-image-request-lifecycle"]
            )
        else {
            throw XCTSkip(
                "Raw playback request lifecycle evidence requires UI_TEST_EVIDENCE_ROOT to be set explicitly to a directory outside Git"
            )
        }
        return directory
    }

    func testName(mode: PlaybackMode, action: PlaybackAction, actionCount: Int) -> String {
        switch (mode, action, actionCount) {
        case (.smartFill, .next, 60):
            return "testSmartFillWarmNext60RequestLifecycleDiagnostics"
        case (.singlePhoto, .next, 60):
            return "testSingleWarmNext60RequestLifecycleDiagnostics"
        case (.smartFill, .previous, 30):
            return "testSmartFillWarmPrevious30RequestLifecycleDiagnostics"
        case (.singlePhoto, .previous, 30):
            return "testSingleWarmPrevious30RequestLifecycleDiagnostics"
        default:
            return "unknown"
        }
    }

    func writeScreenshot(app: XCUIApplication, to url: URL) throws {
        let screenshot = app.screenshot()
        try screenshot.pngRepresentation.write(to: url, options: .atomic)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = url.lastPathComponent
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    func writeText(_ text: String, to url: URL) throws {
        try text.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
#endif
