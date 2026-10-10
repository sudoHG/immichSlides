import Foundation
import XCTest

#if os(tvOS)
extension PlaybackSmartFillTVOSVisualUITests {
    struct SmartFillEvidence {
        let manifests: [SmartFillManifest]

        var fallbackDistribution: [String: Int] {
            SmartFillFallbackEvidencePolicy.distribution(from: manifests.map(\.fallbackCategory))
        }

        var forbiddenFallbackDistribution: [String: Int] {
            SmartFillFallbackEvidencePolicy.forbiddenDistribution(from: fallbackDistribution)
        }
    }

    struct SmartFillManifest: Equatable {
        let raw: String
        let rawFields: [String: String]
        let sceneType: String
        let policy: String
        let slotCount: Int
        let fallback: String
        let fallbackCategory: String
        let slotRefs: String
        let rejects: String
        let surfaceKey: String
        let surfaceProfile: String
        let surfaceOrientation: String
        let slotFrames: String
        let layoutVariant: String
        let ratioPreset: String
        let cropRetention: String
        let protectionContained: String
        let candidateWindowUsed: Int
        let evaluationCount: Int
        let rotationStartLayoutVariant: String
        let rotationStartRatioPreset: String
        let acceptedLayoutVariant: String
        let acceptedRatioPreset: String
        let rotationKeyHashPrefix: String
        let rejectedLayoutReasonTopList: String
    }

    struct MotionFrameEvidenceRow {
        let sampleIndex: Int
        let elapsedSeconds: Double
        let probeIdentifier: String
        let fields: [String: String]
        let manifestSlotRefs: String
        let manifestSceneType: String
    }

    struct ProductSceneSequenceRow {
        let sampleIndex: Int
        let elapsedSeconds: Double
        let manifestSlotRefs: String
        let manifestSceneType: String
        let productTransitionFields: [String: String]
    }

    struct MotionRuntimeEvidenceSample {
        let motionRows: [MotionFrameEvidenceRow]
        let productRows: [ProductSceneSequenceRow]
    }

    func launchConfiguredAppAtModeSelection(
        selectionJSON: String? = nil,
        shouldForceAutoplayOff: Bool = true,
        shouldEnableSmartFillMotionTrace: Bool = false
    ) throws -> XCUIApplication {
        let config = try requireTestServerConfig()
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        if shouldForceAutoplayOff {
            app.launchEnvironment["UI_TEST_FORCE_AUTOPLAY_OFF"] = "1"
        }
        if shouldEnableSmartFillMotionTrace {
            let environment = ProcessInfo.processInfo.environment
            app.launchEnvironment["UI_TEST_COLLECT_SMARTFILL_MOTION_TRACE"] = "1"
            app.launchEnvironment["UI_TEST_SMARTFILL_MOTION_TRACE_DURATION_SECONDS"] =
                environment["TEST_RUNNER_SMARTFILL_MOTION_TRACE_DURATION_SECONDS"] ?? environment[
                    "TEST_RUNNER_SMARTFILL_MOTION_SAMPLE_SECONDS"] ?? environment[
                    "TEST_RUNNER_SMARTFILL_MOTION_INTERACTION_SAMPLE_SECONDS"] ?? "36"
            app.launchEnvironment["UI_TEST_SMARTFILL_MOTION_TRACE_SAMPLE_INTERVAL_SECONDS"] =
                environment["TEST_RUNNER_SMARTFILL_MOTION_TRACE_SAMPLE_INTERVAL_SECONDS"] ?? "0.025"
            app.launchEnvironment["UI_TEST_SMARTFILL_MOTION_TRACE_START_TIMEOUT_SECONDS"] =
                environment["TEST_RUNNER_SMARTFILL_MOTION_TRACE_START_TIMEOUT_SECONDS"] ?? "60"
        }
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        app.launchEnvironment["UI_TEST_SERVER_URL"] = config.url
        app.launchEnvironment["UI_TEST_API_KEY"] = config.apiKey
        SmartFillRuntimeEvidenceSupport.copyAssetIDReplayEnvironment(to: app)
        if let selectionJSON {
            app.launchEnvironment["UI_TEST_SEED_FILTER_SELECTION"] = "1"
            app.launchEnvironment["UI_TEST_FILTER_SELECTION_JSON"] = selectionJSON
        }
        app.launch()

        XCTAssertTrue(
            app.buttons["mode.continue.button"].waitForExistence(timeout: TestWait.seconds(.infrastructure(15))),
            "After injecting the test server, Apple TV should go straight to mode selection"
        )
        return app
    }

    func startRandomPlaybackFromModeSelection(app: XCUIApplication) {
        let randomButton = app.buttons["mode.random.button"]
        XCTAssertTrue(
            randomButton.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
            "Apple TV mode selection should show the random playback option")
        if randomButton.hasFocus == false {
            XCUIRemote.shared.press(.left)
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.16))))
        }
        XCUIRemote.shared.press(.select)

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: TestWait.seconds(.product(8))),
            "Continue button should appear after choosing random playback")
        if continueButton.hasFocus == false {
            XCUIRemote.shared.press(.down)
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.16))))
        }
        XCTAssertTrue(continueButton.hasFocus, "In the Apple TV random playback flow, focus should move to Continue")
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: TestWait.seconds(.product(30))),
            "After starting Apple TV random playback, the playback control bar should appear"
        )
        _ = waitUntil(timeout: TestWait.seconds(.infrastructure(30))) {
            guard let manifest = self.currentManifest(app: app) else { return false }
            return manifest.fallback != "image-not-ready"
        }
    }

    func startFilteredPlaybackFromModeSelection(app: XCUIApplication) {
        let filteredButton = app.buttons["mode.filtered.button"]
        XCTAssertTrue(
            filteredButton.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
            "Apple TV mode selection should show the filtered playback option")
        for _ in 0..<4 {
            if filteredButton.hasFocus { break }
            XCUIRemote.shared.press(.right)
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.16))))
        }
        XCTAssertTrue(
            filteredButton.hasFocus, "Apple TV mode selection focus should move to the filtered playback option")
        XCUIRemote.shared.press(.select)

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: TestWait.seconds(.product(8))),
            "Continue button should appear after choosing filtered playback")
        for _ in 0..<4 {
            if continueButton.hasFocus { break }
            XCUIRemote.shared.press(.down)
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.16))))
        }
        XCTAssertTrue(continueButton.hasFocus, "In the Apple TV filtered playback flow, focus should move to Continue")
        XCUIRemote.shared.press(.select)

        let startButton = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(
            startButton.waitForExistence(timeout: TestWait.seconds(.product(20))),
            "Apple TV filter summary should show the Start playback button")
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(20))) { startButton.isEnabled },
            "After seeding the people filter, Apple TV Start playback should be enabled")
        for _ in 0..<10 {
            if startButton.hasFocus { break }
            XCUIRemote.shared.press(.down)
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.16))))
        }
        if startButton.hasFocus == false {
            for _ in 0..<10 {
                if startButton.hasFocus { break }
                XCUIRemote.shared.press(.right)
                RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.16))))
            }
        }
        XCTAssertTrue(startButton.hasFocus, "Apple TV filter summary focus should move to Start playback")
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: TestWait.seconds(.product(45))),
            "After starting Apple TV people-filter playback, the playback control bar should appear"
        )
        _ = waitUntil(timeout: TestWait.seconds(.infrastructure(30))) {
            guard let manifest = self.currentManifest(app: app) else { return false }
            return manifest.fallback != "image-not-ready"
        }
    }

    func collectMotionRuntimeEvidence(
        app: XCUIApplication,
        scenario: String,
        duration: TimeInterval,
        interval: TimeInterval,
        performAction: ((Double) -> Void)? = nil
    ) -> MotionRuntimeEvidenceSample {
        var motionRows: [MotionFrameEvidenceRow] = []
        var productRows: [ProductSceneSequenceRow] = []
        let startedAt = ProcessInfo.processInfo.systemUptime
        var sampleIndex = 0

        while ProcessInfo.processInfo.systemUptime - startedAt < duration {
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            performAction?(elapsed)
            if let manifest = currentManifest(app: app) {
                motionRows.append(
                    contentsOf: currentMotionFrameRows(
                        app: app,
                        sampleIndex: sampleIndex,
                        elapsedSeconds: elapsed,
                        manifest: manifest
                    ))
                productRows.append(
                    ProductSceneSequenceRow(
                        sampleIndex: sampleIndex,
                        elapsedSeconds: elapsed,
                        manifestSlotRefs: manifest.slotRefs,
                        manifestSceneType: manifest.sceneType,
                        productTransitionFields: currentProductTransitionFields(app: app) ?? [:]
                    ))
            }
            sampleIndex += 1
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
        }

        let attachment = XCTAttachment(
            string: "scenario=\(scenario);motionRows=\(motionRows.count);productRows=\(productRows.count)")
        attachment.name = "smartfill-\(scenario)-appletv-motion-runtime-summary"
        attachment.lifetime = .keepAlways
        add(attachment)
        return MotionRuntimeEvidenceSample(motionRows: motionRows, productRows: productRows)
    }

    func currentMotionFrameRows(
        app: XCUIApplication,
        sampleIndex: Int,
        elapsedSeconds: Double,
        manifest: SmartFillManifest
    ) -> [MotionFrameEvidenceRow] {
        let summaryProbe = app.otherElements["slideshow.smartfill.motionFrame.summary"]
        if summaryProbe.exists {
            return summaryProbe.label
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { rawLine -> MotionFrameEvidenceRow? in
                    let fields = parseSemicolonFields(String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines))
                    guard fields["eventType"] == "motionFrame" else { return nil }
                    let identifier = [
                        "slideshow.smartfill.motionFrame.summary",
                        fields["renderRole"] ?? "unknown",
                        fields["slotId"] ?? "unknown"
                    ].joined(separator: ".")
                    return MotionFrameEvidenceRow(
                        sampleIndex: sampleIndex,
                        elapsedSeconds: elapsedSeconds,
                        probeIdentifier: identifier,
                        fields: fields,
                        manifestSlotRefs: manifest.slotRefs,
                        manifestSceneType: fields["manifestSceneType"] ?? manifest.sceneType
                    )
                }
        }

        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "slideshow.smartfill.motionFrame.")
        let elements = app.descendants(matching: .any)
            .matching(predicate)
            .allElementsBoundByIndex
        return elements.compactMap { element in
            guard element.exists else { return nil }
            let fields = parseSemicolonFields(element.label.trimmingCharacters(in: .whitespacesAndNewlines))
            guard fields["eventType"] == "motionFrame" else { return nil }
            return MotionFrameEvidenceRow(
                sampleIndex: sampleIndex,
                elapsedSeconds: elapsedSeconds,
                probeIdentifier: element.identifier,
                fields: fields,
                manifestSlotRefs: manifest.slotRefs,
                manifestSceneType: fields["manifestSceneType"] ?? manifest.sceneType
            )
        }
    }

    func currentProductTransitionFields(app: XCUIApplication) -> [String: String]? {
        let probe = app.otherElements["slideshow.smartfill.productTransition.summary"]
        guard probe.exists else { return nil }
        let fields = parseSemicolonFields(probe.label.trimmingCharacters(in: .whitespacesAndNewlines))
        guard fields["eventType"] == "productTransition" else { return nil }
        return fields
    }

    func appSmartFillMotionTraceText(
        app: XCUIApplication,
        timeout: TimeInterval
    ) throws -> String {
        let statusProbe = app.otherElements["slideshow.smartfill.motionFrame.trace.status"]
        let quietWait = TestWait.seconds(.product(min(timeout, smartFillMotionTraceDurationSeconds() + 5)))
        RunLoop.current.run(until: Date().addingTimeInterval(quietWait))
        let isCompleteAfterQuietWait = statusProbe.exists && statusProbe.label.contains("status=complete")
        let remainingTimeout = TestWait.seconds(.product(max(0, timeout - quietWait)))
        let completed =
            isCompleteAfterQuietWait
            || waitUntil(timeout: remainingTimeout) {
                statusProbe.exists && statusProbe.label.contains("status=complete")
            }
        XCTAssertTrue(
            completed, "in-app motion trace must complete, status=\(statusProbe.exists ? statusProbe.label : "missing")"
        )
        guard completed else { return "" }

        let statusFields = parseSemicolonFields(statusProbe.label)
        if let tracePath = statusFields["tracePath"],
            !tracePath.isEmpty,
            tracePath != "missing",
            tracePath != "write-failed",
            let traceText = try? String(contentsOfFile: tracePath, encoding: .utf8)
        {
            return traceText
        }

        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "slideshow.smartfill.motionFrame.trace.chunk.")
        let chunks = app.descendants(matching: .any)
            .matching(predicate)
            .allElementsBoundByIndex
            .sorted { lhs, rhs in
                traceChunkIndex(lhs.identifier) < traceChunkIndex(rhs.identifier)
            }
        return chunks.map(\.label).joined(separator: "\n")
    }

    func waitForSmartFillMotionTraceCollecting(
        app: XCUIApplication,
        timeout: TimeInterval
    ) throws -> TimeInterval {
        let statusProbe = app.otherElements["slideshow.smartfill.motionFrame.trace.status"]
        let completed = waitUntil(timeout: timeout) {
            guard statusProbe.exists else { return false }
            let statusFields = parseSemicolonFields(statusProbe.label)
            guard statusProbe.label.contains("status=collecting") || statusProbe.label.contains("status=complete")
            else {
                return false
            }
            return Double(statusFields["collectionStartedUptimeSeconds"] ?? "0") ?? 0 > 0
        }
        XCTAssertTrue(
            completed,
            "in-app motion trace must start collecting, status=\(statusProbe.exists ? statusProbe.label : "missing")")
        if statusProbe.exists, statusProbe.label.contains("status=complete") {
            XCTFail(
                "motion trace finished before the interaction; increase the motion trace capture budget or start the interaction sooner"
            )
            throw SmartFillTVOSFailure.motionTraceFinishedBeforeInteraction
        }
        let statusFields = statusProbe.exists ? parseSemicolonFields(statusProbe.label) : [:]
        let startedAt = Double(statusFields["collectionStartedUptimeSeconds"] ?? "0") ?? 0
        XCTAssertGreaterThan(
            startedAt, 0,
            "motion trace status must expose collectionStartedUptimeSeconds as the time anchor for interaction evidence"
        )
        return startedAt
    }

    func traceChunkIndex(_ identifier: String) -> Int {
        Int(identifier.split(separator: ".").last ?? "") ?? 0
    }

    func motionFrameRows(
        fromTraceText traceText: String,
        fallbackManifest: SmartFillManifest
    ) -> [MotionFrameEvidenceRow] {
        traceText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { rawLine -> MotionFrameEvidenceRow? in
                let fields = parseSemicolonFields(String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines))
                guard fields["eventType"] == "motionFrame" else { return nil }
                guard let rawSampleIndex = fields["sampleIndex"],
                    let sampleIndex = Int(rawSampleIndex),
                    let rawElapsed = fields["elapsedSeconds"],
                    let elapsedSeconds = Double(rawElapsed)
                else {
                    return nil
                }
                let identifier = [
                    "slideshow.smartfill.motionFrame.trace",
                    fields["renderRole"] ?? "unknown",
                    fields["slotId"] ?? "unknown"
                ].joined(separator: ".")
                return MotionFrameEvidenceRow(
                    sampleIndex: sampleIndex,
                    elapsedSeconds: elapsedSeconds,
                    probeIdentifier: identifier,
                    fields: fields,
                    manifestSlotRefs: (fields["manifestSlotRefs"] ?? fallbackManifest.slotRefs)
                        .replacingOccurrences(of: "|", with: ","),
                    manifestSceneType: fields["manifestSceneType"] ?? fallbackManifest.sceneType
                )
            }
    }

    func productSceneSequenceRows(
        fromTraceText traceText: String,
        fallbackManifest: SmartFillManifest
    ) -> [ProductSceneSequenceRow] {
        traceText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { rawLine -> ProductSceneSequenceRow? in
                let fields = parseSemicolonFields(String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines))
                guard fields["eventType"] == "productSceneSequence" else { return nil }
                guard let rawSampleIndex = fields["sampleIndex"],
                    let sampleIndex = Int(rawSampleIndex),
                    let rawElapsed = fields["elapsedSeconds"],
                    let elapsedSeconds = Double(rawElapsed)
                else {
                    return nil
                }
                return ProductSceneSequenceRow(
                    sampleIndex: sampleIndex,
                    elapsedSeconds: elapsedSeconds,
                    manifestSlotRefs: (fields["slotRefs"] ?? fallbackManifest.slotRefs)
                        .replacingOccurrences(of: "|", with: ","),
                    manifestSceneType: fields["sceneType"] ?? fallbackManifest.sceneType,
                    productTransitionFields: fields
                )
            }
    }

    func recordInteractionAction(_ action: String, elapsed: Double, actions: inout [[String: Any]]) {
        guard !actions.containsAction(action) else { return }
        actions.append([
            "action": action,
            "elapsedSeconds": elapsed,
            "timestamp": SmartFillRuntimeEvidenceSupport.captureTimestamp()
        ])
    }

    func parseSemicolonFields(_ raw: String) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: raw.split(separator: ";").compactMap { part -> (String, String)? in
                guard let equalIndex = part.firstIndex(of: "=") else { return nil }
                return (
                    String(part[..<equalIndex]),
                    String(part[part.index(after: equalIndex)...])
                )
            })
    }

    func smartFillMotionScenarioName(defaultScenario: String) -> String {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["TEST_RUNNER_SMARTFILL_MOTION_SCENARIO"], !override.isEmpty {
            return override
        }
        if let override = environment["SMARTFILL_MOTION_SCENARIO"], !override.isEmpty {
            return override
        }
        return defaultScenario
    }

    func smartFillMotionSampleDurationSeconds() -> TimeInterval {
        let environment = ProcessInfo.processInfo.environment
        let rawValue =
            environment["TEST_RUNNER_SMARTFILL_MOTION_SAMPLE_SECONDS"] ?? environment["SMARTFILL_MOTION_SAMPLE_SECONDS"]
        guard let rawValue,
            let value = TimeInterval(rawValue),
            value > 0
        else {
            return EvidenceCalibration.defaultMotionTraceTimeoutSeconds
        }
        return value
    }

    func smartFillMotionTraceDurationSeconds() -> TimeInterval {
        let environment = ProcessInfo.processInfo.environment
        let rawValue =
            environment["TEST_RUNNER_SMARTFILL_MOTION_TRACE_DURATION_SECONDS"] ?? environment[
                "TEST_RUNNER_SMARTFILL_MOTION_SAMPLE_SECONDS"] ?? environment[
                "TEST_RUNNER_SMARTFILL_MOTION_INTERACTION_SAMPLE_SECONDS"] ?? environment[
                "SMARTFILL_MOTION_TRACE_DURATION_SECONDS"] ?? environment["SMARTFILL_MOTION_SAMPLE_SECONDS"]
        guard let rawValue,
            let value = TimeInterval(rawValue),
            value > 0
        else {
            return EvidenceCalibration.defaultMotionSampleSeconds
        }
        return value
    }

    func smartFillMotionInteractionSampleDurationSeconds() -> TimeInterval {
        let environment = ProcessInfo.processInfo.environment
        let rawValue =
            environment["TEST_RUNNER_SMARTFILL_MOTION_INTERACTION_SAMPLE_SECONDS"]
            ?? environment["SMARTFILL_MOTION_INTERACTION_SAMPLE_SECONDS"]
        guard let rawValue,
            let value = TimeInterval(rawValue),
            value > 0
        else {
            return 22
        }
        return value
    }

    func smartFillMotionSampleIntervalSeconds() -> TimeInterval {
        let environment = ProcessInfo.processInfo.environment
        let rawValue =
            environment["TEST_RUNNER_SMARTFILL_MOTION_SAMPLE_INTERVAL_SECONDS"]
            ?? environment["SMARTFILL_MOTION_SAMPLE_INTERVAL_SECONDS"]
        guard let rawValue,
            let value = TimeInterval(rawValue),
            value > 0
        else {
            return 0.10
        }
        return min(max(value, 0.05), 0.25)
    }

    func collectSceneEvidence(app: XCUIApplication, scenario: String) throws -> SmartFillEvidence {
        var manifests: [SmartFillManifest] = []
        var runtimeRecords: [[String: Any]] = []
        var attachedSceneTypes = Set<String>()
        var attachedScreenshotCount = 0
        let harnessStartMs = SmartFillRuntimeEvidenceSupport.harnessTimestampMilliseconds()
        var firstManifestObservedMs: Double?
        var firstNonLoadingScreenshotCapturedMs: Double?
        let targetSceneCount = smartFillTargetSceneCount()
        let samplingScreenshotIndices = screenshotSampleIndices(for: targetSceneCount)

        for index in 0..<targetSceneCount {
            var manifest = try waitForCurrentManifest(
                app: app, timeout: TestWait.seconds(index == 0 ? .infrastructure(45) : .product(25)))
            if index == 0,
                shouldWaitForCompleteStartupRuntimePhases()
            {
                manifest = try waitForCompleteStartupRuntimeManifest(
                    app: app,
                    initialManifest: manifest,
                    timeout: TestWait.seconds(.product(30))
                )
            }
            manifest = try waitForScreenshotReadyManifest(
                app: app,
                initialManifest: manifest,
                timeout: TestWait.seconds(.product(30)),
                scenario: scenario,
                index: index
            )
            if firstManifestObservedMs == nil {
                firstManifestObservedMs =
                    SmartFillRuntimeEvidenceSupport.harnessTimestampMilliseconds() - harnessStartMs
            }
            assertManifestIsRedacted(manifest.raw)
            assertManifestMeetsSpecGates(manifest, scenario: scenario, index: index)
            manifests.append(manifest)

            let sequence = index + 1
            let sceneIdHash = SmartFillRuntimeEvidenceSupport.sceneIdHash(
                rawManifest: manifest.raw,
                scenario: scenario,
                sequence: sequence
            )
            let shouldAttach =
                index == 0 || index == targetSceneCount - 1 || attachedSceneTypes.insert(manifest.sceneType).inserted
                || samplingScreenshotIndices.contains(index)
            if let screenshot = captureRuntimeScreenshot(
                app: app,
                name: "smartfill-\(scenario)-appletv-seq-\(sequence)-\(sceneIdHash)-\(manifest.sceneType)",
                shouldAttachToXCTest: shouldAttach
            ) {
                if firstNonLoadingScreenshotCapturedMs == nil {
                    firstNonLoadingScreenshotCapturedMs =
                        SmartFillRuntimeEvidenceSupport.harnessTimestampMilliseconds() - harnessStartMs
                }
                runtimeRecords.append(
                    SmartFillRuntimeEvidenceSupport.makeRecord(
                        manifestFields: manifest.rawFields,
                        rawManifest: manifest.raw,
                        scenario: scenario,
                        deviceTag: "appletv",
                        sequence: sequence,
                        sceneIdHash: sceneIdHash,
                        screenshotPath: screenshot.path,
                        captureTimestamp: screenshot.captureTimestamp
                    )
                )
            }
            if shouldAttach {
                attachedScreenshotCount += 1
            }

            guard index < targetSceneCount - 1 else { continue }
            let previousRefs = manifest.slotRefs
            pressNext(app: app)
            _ = waitUntil(timeout: TestWait.seconds(.product(25))) {
                guard let nextManifest = self.currentManifest(app: app) else { return false }
                return nextManifest.slotRefs != previousRefs
            }
        }

        attachManifestSummary(manifests, scenario: scenario)
        let harnessSummary = makeHarnessSummary(
            runtimeRecords: runtimeRecords,
            firstManifestObservedMs: firstManifestObservedMs,
            firstNonLoadingScreenshotCapturedMs: firstNonLoadingScreenshotCapturedMs
        )
        writeManifestEvidence(
            manifests,
            runtimeRecords: runtimeRecords,
            harnessSummary: harnessSummary,
            scenario: scenario
        )
        XCTAssertEqual(
            manifests.count, targetSceneCount, "\(scenario) should capture the target number of Smart Fill manifests")
        if targetSceneCount >= 60 {
            XCTAssertGreaterThanOrEqual(
                attachedScreenshotCount, 10, "\(scenario) a 60-scene sample should keep at least 10 screenshots")
        }
        if targetSceneCount > 1 {
            XCTAssertGreaterThan(
                Set(manifests.map(\.slotRefs)).count,
                1,
                "\(scenario) consecutive samples should show at least one change in redacted slot references"
            )
        }
        return SmartFillEvidence(manifests: manifests)
    }
}
#endif
