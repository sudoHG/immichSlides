import Foundation
import XCTest

#if os(iOS)
extension PlaybackSmartFillVisualUITests {
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

    enum SmartFillSurfaceExpectation {
        case portrait
        case landscape
    }

    enum SmartFillIOSFailure: Error {
        case missingManifest
        case missingCurrentAssetProbe
        case motionTraceFinishedBeforeInteraction
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

    enum ExifPresenceTransitionEdge: Equatable {
        case appear
        case disappear
    }

    struct ExifPresenceEdgeCoverage {
        private(set) var didAppear = false
        private(set) var didDisappear = false

        var isComplete: Bool {
            didAppear && didDisappear
        }

        var missingEdgeDescription: String {
            var messages: [String] = []
            if !didAppear {
                messages.append(
                    "Missing smooth EXIF overlay appearance: multi-photo without EXIF → single photo with EXIF")
            }
            if !didDisappear {
                messages.append(
                    "Missing smooth EXIF overlay disappearance: single photo with EXIF → multi-photo without EXIF")
            }
            return messages.joined(separator: "; ")
        }

        mutating func observeTransition(from isPreviousVisible: Bool, to isCurrentVisible: Bool)
            -> ExifPresenceTransitionEdge?
        {
            switch (isPreviousVisible, isCurrentVisible) {
            case (false, true):
                didAppear = true
                return .appear
            case (true, false):
                didDisappear = true
                return .disappear
            default:
                return nil
            }
        }
    }

    func launchConfiguredAppAtModeSelection(
        selectionJSON: String? = nil,
        shouldDisableSmartFill: Bool = false,
        shouldForceAutoplayOff: Bool = true,
        shouldEnableSmartFillMotionTrace: Bool = false,
        shouldResetState: Bool = true
    ) throws -> XCUIApplication {
        let config = try requireTestServerConfig()
        let app = XCUIApplication()
        if shouldResetState {
            app.launchEnvironment["UI_TEST_RESET_STATE"] = "1"
        }
        app.launchEnvironment["XCTestConfigurationFilePath"] =
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] ?? "SmartFillMotionEvidenceUITest"
        app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        if shouldForceAutoplayOff {
            app.launchEnvironment["UI_TEST_FORCE_AUTOPLAY_OFF"] = "1"
        }
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        app.launchEnvironment["UI_TEST_SERVER_URL"] = config.url
        app.launchEnvironment["UI_TEST_API_KEY"] = config.apiKey
        SmartFillRuntimeEvidenceSupport.copyAssetIDReplayEnvironment(to: app)
        if shouldEnableSmartFillMotionTrace {
            let environment = ProcessInfo.processInfo.environment
            app.launchEnvironment["UI_TEST_COLLECT_SMARTFILL_MOTION_TRACE"] = "1"
            app.launchEnvironment["UI_TEST_SMARTFILL_MOTION_TRACE_DURATION_SECONDS"] =
                environment["TEST_RUNNER_SMARTFILL_MOTION_SAMPLE_SECONDS"] ?? environment[
                    "SMARTFILL_MOTION_SAMPLE_SECONDS"] ?? "36"
            app.launchEnvironment["UI_TEST_SMARTFILL_MOTION_TRACE_SAMPLE_INTERVAL_SECONDS"] =
                environment["TEST_RUNNER_SMARTFILL_MOTION_SAMPLE_INTERVAL_SECONDS"] ?? environment[
                    "SMARTFILL_MOTION_SAMPLE_INTERVAL_SECONDS"] ?? "0.005"
            app.launchEnvironment["UI_TEST_SMARTFILL_MOTION_TRACE_START_TIMEOUT_SECONDS"] =
                environment["TEST_RUNNER_SMARTFILL_MOTION_TRACE_START_TIMEOUT_SECONDS"] ?? environment[
                    "SMARTFILL_MOTION_TRACE_START_TIMEOUT_SECONDS"] ?? "60"
        }
        if shouldDisableSmartFill {
            app.launchEnvironment["IMMICHSLIDES_DISABLE_SMART_FILL"] = "1"
        }
        if let selectionJSON {
            app.launchEnvironment["UI_TEST_SEED_FILTER_SELECTION"] = "1"
            app.launchEnvironment["UI_TEST_FILTER_SELECTION_JSON"] = selectionJSON
        }
        let requestedOrientation = XCUIDevice.shared.orientation
        app.launch()
        if requestedOrientation.isLandscape {
            XCUIDevice.shared.orientation = requestedOrientation
            _ = waitUntil(timeout: TestWait.seconds(.infrastructure(8))) { app.frame.width > app.frame.height }
        }

        XCTAssertTrue(
            app.buttons["mode.continue.button"].waitForExistence(timeout: TestWait.seconds(.infrastructure(12))),
            "After injecting the test server, the app should go straight to mode selection"
        )
        return app
    }

    func launchSmartFillMotionEvidenceAppAtModeSelection(
        scenario: String,
        shouldForceAutoplayOff: Bool,
        shouldEnableSmartFillMotionTrace: Bool
    ) throws -> XCUIApplication {
        let configuredInterval = smartFillMotionConfiguredIntervalSeconds()
        if abs(configuredInterval - 5.0) > 0.000_1 {
            XCTAssertTrue(
                isSmartFillMotionIntervalPreseeded(),
                "\(scenario) non-5-second motion evidence must preseed PlaybackSettings.intervalSeconds (\(configuredInterval) s) in the app's saved settings and set SMARTFILL_MOTION_INTERVAL_PRESEEDED=1; the flag is trusted, not verified, so confirm the value in Settings before using the cadence evidence"
            )
            return try launchConfiguredAppAtModeSelection(
                shouldForceAutoplayOff: shouldForceAutoplayOff,
                shouldEnableSmartFillMotionTrace: shouldEnableSmartFillMotionTrace,
                shouldResetState: false
            )
        }

        return try launchConfiguredAppAtModeSelection(
            shouldForceAutoplayOff: shouldForceAutoplayOff,
            shouldEnableSmartFillMotionTrace: shouldEnableSmartFillMotionTrace
        )
    }

    func startRandomPlaybackFromModeSelection(app: XCUIApplication) {
        tapElement(app.buttons["mode.random.button"])
        tapElement(app.buttons["mode.continue.button"])
        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: TestWait.seconds(.product(30))),
            "After starting random playback, the playback control bar should appear"
        )
    }

    func runPlaybackTransitionAnimationEvidence(shouldDisableSmartFill: Bool, scenario: String) throws {
        let app = try launchConfiguredAppAtModeSelection(shouldDisableSmartFill: shouldDisableSmartFill)
        startRandomPlaybackFromModeSelection(app: app)
        saveEvidenceScreenshot(app: app, scenario: scenario, step: "00-before")

        for index in 1...3 {
            tapNext(app: app)
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.25))))
            saveEvidenceScreenshot(app: app, scenario: scenario, step: "\(index)-mid")
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.65))))
            saveEvidenceScreenshot(app: app, scenario: scenario, step: "\(index)-settled")
        }

        XCTAssertTrue(
            app.buttons["slideshow.control.next.button"].waitForExistence(
                timeout: TestWait.seconds(.product(4))),
            "\(scenario) control bar should still work after quick switching"
        )
    }

    func isExifOverlayVisible(in manifest: SmartFillManifest) -> Bool {
        manifest.rawFields["exifOverlayVisible"] == "true"
    }

    func startFilteredPlaybackFromModeSelection(app: XCUIApplication) {
        tapElement(app.buttons["mode.filtered.button"])
        tapElement(app.buttons["mode.continue.button"])

        let startButton = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(
            startButton.waitForExistence(timeout: TestWait.seconds(.product(20))),
            "Filter summary should show the Start playback button")
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(20))) { startButton.isEnabled },
            "After seeding the people filter, Start playback should be tappable")
        tapElement(startButton)

        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: TestWait.seconds(.product(45))),
            "After starting people-filter playback, the playback control bar should appear"
        )
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
        let replayCurrentAssetRefs = SmartFillRuntimeEvidenceSupport.assetIDReplayExpectedCurrentRefs()
        let strictExpectedCurrentAssetRefs = SmartFillRuntimeEvidenceSupport.strictExpectedCurrentAssetRefs()
        let replayCurrentAssetRefIndex = firstIndexMap(for: replayCurrentAssetRefs ?? [])
        var previousReplayAssetIndex: Int?
        var replayValidationRows: [SmartFillRuntimeEvidenceSupport.AssetIDReplayValidationRow] = []
        var didStopAtReplayBoundary = false

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

            let sequence = index + 1
            if replayCurrentAssetRefs != nil {
                let observedSlotRef = rawCurrentAssetID(in: manifest)
                let observedCurrentAssetRef = observedSlotRef.map {
                    SmartFillRuntimeEvidenceSupport.runtimeCurrentAssetRef(forSlotRef: $0)
                }
                let observedReplayIndex = observedSlotRef.flatMap { replayCurrentAssetRefIndex[$0] }
                if let strictExpectedCurrentAssetRefs {
                    let expectedAssetRef = try XCTUnwrap(
                        strictExpectedCurrentAssetRefs.indices.contains(index)
                            ? strictExpectedCurrentAssetRefs[index] : nil,
                        "expected currentAssetRef lock has fewer than \(targetSceneCount) entries; entry \(sequence) is missing"
                    )
                    let status = observedCurrentAssetRef == expectedAssetRef ? "match" : "mismatch"
                    replayValidationRows.append(
                        SmartFillRuntimeEvidenceSupport.AssetIDReplayValidationRow(
                            sequence: sequence,
                            rule: "strict-current-ref",
                            expected: expectedAssetRef,
                            observedSlotRef: observedSlotRef,
                            observedCurrentAssetRef: observedCurrentAssetRef,
                            observedReplayIndex: observedReplayIndex.map { $0 + 1 },
                            status: status
                        )
                    )
                    XCTAssertEqual(
                        observedCurrentAssetRef,
                        expectedAssetRef,
                        "\(scenario) scene \(sequence) must play per the expected currentAssetRef lock"
                    )
                } else {
                    let progress = SmartFillRuntimeEvidenceSupport.evaluateAssetIDReplayMonotonicProgress(
                        sequence: sequence,
                        observedReplayIndex: observedReplayIndex,
                        previousReplayAssetIndex: previousReplayAssetIndex
                    )
                    replayValidationRows.append(
                        SmartFillRuntimeEvidenceSupport.AssetIDReplayValidationRow(
                            sequence: sequence,
                            rule: "replay-pool-monotonic",
                            expected: progress.expected,
                            observedSlotRef: observedSlotRef,
                            observedCurrentAssetRef: observedCurrentAssetRef,
                            observedReplayIndex: observedReplayIndex.map { $0 + 1 },
                            status: progress.status
                        )
                    )
                    if let failureMessage = progress.failureMessage {
                        XCTFail("\(scenario) \(failureMessage)")
                        break
                    }
                    if progress.shouldStopSampling {
                        didStopAtReplayBoundary = true
                        break
                    }
                    guard progress.shouldIncludeManifest else { break }
                    previousReplayAssetIndex = progress.nextPreviousReplayAssetIndex
                }
            }
            manifests.append(manifest)
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
                name: "smartfill-\(scenario)-\(deviceTag())-seq-\(sequence)-\(sceneIdHash)-\(manifest.sceneType)",
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
                        deviceTag: deviceTag(),
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
            tapNext(app: app)
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
        writeAssetIDReplayEvidence(replayValidationRows, scenario: scenario)
        if didStopAtReplayBoundary {
            XCTAssertLessThan(
                manifests.count, targetSceneCount, "\(scenario) should stop cleanly before the replay wraps around")
        } else {
            XCTAssertEqual(
                manifests.count, targetSceneCount,
                "\(scenario) should capture the target number of Smart Fill manifests")
        }
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

    func writeAssetIDReplayEvidence(
        _ rows: [SmartFillRuntimeEvidenceSupport.AssetIDReplayValidationRow],
        scenario: String
    ) {
        guard !rows.isEmpty, let directory = evidenceDirectory() else { return }
        let fileURL = directory.appendingPathComponent(
            sanitizedEvidenceFileName("smartfill-\(scenario)-\(deviceTag())-asset-id-replay-validation") + ".tsv"
        )
        try? SmartFillRuntimeEvidenceSupport.assetIDReplayValidationText(rows: rows)
            .write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func exerciseTwentySceneSwitches(app: XCUIApplication, scenario: String) throws {
        _ = try waitForCurrentAssetReference(app: app, timeout: TestWait.seconds(.infrastructure(45)))
        var switchedCount = 1

        for _ in 0..<19 {
            let previousReference = try waitForCurrentAssetReference(app: app, timeout: TestWait.seconds(.product(20)))
            tapNext(app: app)
            XCTAssertTrue(
                waitUntil(timeout: TestWait.seconds(.product(25))) {
                    guard let nextReference = self.currentAssetReference(app: app) else { return false }
                    return nextReference != previousReference
                },
                "\(scenario) tapping Next should switch to a new playback asset"
            )
            switchedCount += 1
        }

        let attachment = XCTAttachment(string: "scenario=\(scenario);sceneCount=\(switchedCount)")
        attachment.name = "smartfill-\(scenario)-performance-probe-\(deviceTag())"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(switchedCount, 20, "\(scenario) should complete 20 playback switches")
    }

    func tapNext(app: XCUIApplication) {
        let nextButton = app.buttons["slideshow.control.next.button"]
        if nextButton.waitForExistence(timeout: TestWait.seconds(.product(3))) {
            tapElement(nextButton)
            return
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(
            nextButton.waitForExistence(timeout: TestWait.seconds(.product(5))),
            "Next button should be found after waking the control bar")
        tapElement(nextButton)
    }

    func waitForCurrentManifest(app: XCUIApplication, timeout: TimeInterval) throws -> SmartFillManifest {
        guard waitUntil(timeout: timeout, condition: { self.currentManifest(app: app) != nil }) else {
            attachScreenshot(app: app, name: "smartfill-manifest-missing-\(deviceTag())")
            throw SmartFillIOSFailure.missingManifest
        }
        guard let manifest = currentManifest(app: app) else {
            throw SmartFillIOSFailure.missingManifest
        }
        return manifest
    }

    func appSmartFillMotionTraceText(
        app: XCUIApplication,
        timeout: TimeInterval
    ) throws -> String {
        let statusProbe = app.otherElements["slideshow.smartfill.motionFrame.trace.status"]
        let quietWait = TestWait.seconds(.product(min(timeout, smartFillMotionSampleDurationSeconds() + 5)))
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
            throw SmartFillIOSFailure.motionTraceFinishedBeforeInteraction
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

    func waitForCompleteStartupRuntimeManifest(
        app: XCUIApplication,
        initialManifest: SmartFillManifest,
        timeout: TimeInterval
    ) throws -> SmartFillManifest {
        var latestManifest = initialManifest
        _ = waitUntil(timeout: timeout) {
            guard let nextManifest = self.currentManifest(app: app) else { return false }
            latestManifest = nextManifest
            return self.hasCompleteStartupRuntimePhases(nextManifest)
        }
        XCTAssertTrue(
            hasCompleteStartupRuntimePhases(latestManifest),
            "Minimal runtime JSONL requires the first-frame manifest to include all startup runtime phases"
        )
        return latestManifest
    }

    func waitForScreenshotReadyManifest(
        app: XCUIApplication,
        initialManifest: SmartFillManifest,
        timeout: TimeInterval,
        scenario: String,
        index: Int
    ) throws -> SmartFillManifest {
        var latestManifest = initialManifest
        _ = waitUntil(timeout: timeout) {
            guard let nextManifest = self.currentManifest(app: app) else { return false }
            latestManifest = nextManifest
            return SmartFillRuntimeEvidenceSupport.isReadyForScreenshotEvidence(
                manifestFields: nextManifest.rawFields
            )
        }
        XCTAssertTrue(
            SmartFillRuntimeEvidenceSupport.isReadyForScreenshotEvidence(manifestFields: latestManifest.rawFields),
            "\(scenario) frame \(index + 1) must wait for images to be ready before the screenshot, current state: \(SmartFillRuntimeEvidenceSupport.screenshotEvidenceReadinessReason(manifestFields: latestManifest.rawFields))"
        )
        return latestManifest
    }

    func hasCompleteStartupRuntimePhases(_ manifest: SmartFillManifest) -> Bool {
        guard let timestamps = manifest.rawFields["runtimePhaseTimestampsMs"],
            let durations = manifest.rawFields["runtimePhaseDurationsMs"]
        else {
            return false
        }
        return SmartFillRuntimeEvidenceSupport.requiredRuntimePhaseKeys.allSatisfy { phase in
            timestamps.contains("\(phase):") && durations.contains("\(phase):")
        }
    }

    func currentManifest(app: XCUIApplication) -> SmartFillManifest? {
        let probe = app.descendants(matching: .any)["slideshow.smartfill.currentManifest.flag"]
        guard probe.exists else { return nil }
        return parseManifest(probe.label.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func waitForCurrentAssetReference(app: XCUIApplication, timeout: TimeInterval) throws -> String {
        guard waitUntil(timeout: timeout, condition: { self.currentAssetReference(app: app) != nil }) else {
            throw SmartFillIOSFailure.missingCurrentAssetProbe
        }
        guard let reference = currentAssetReference(app: app) else {
            throw SmartFillIOSFailure.missingCurrentAssetProbe
        }
        return reference
    }

    func currentAssetReference(app: XCUIApplication) -> String? {
        let probe = app.descendants(matching: .any)["slideshow.currentAssetId.flag"]
        guard probe.exists else { return nil }
        let raw = probe.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty || raw == "no-asset" ? nil : raw
    }

    func rawCurrentAssetID(in manifest: SmartFillManifest) -> String? {
        let slotRefs =
            manifest.rawFields["slotRefs"]?
            .split(separator: ",")
            .map(String.init) ?? []
        let disposition = manifest.rawFields["currentAssetDisposition"] ?? "missing"
        let index: Int
        switch disposition {
        case "primary-slot", "single-slot", "fallback-current":
            index = 0
        case "secondary-slot":
            index = 1
        case "tertiary-slot":
            index = 2
        default:
            return nil
        }
        guard slotRefs.indices.contains(index) else { return nil }
        return slotRefs[index]
    }

    func firstIndexMap(for values: [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        for (index, value) in values.enumerated() where result[value] == nil {
            result[value] = index
        }
        return result
    }
}
#endif
