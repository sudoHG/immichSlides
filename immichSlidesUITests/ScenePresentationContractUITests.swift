//
//  ScenePresentationContractUITests.swift
//  immichSlidesUITests
//
//  Shared scene presentation runtime contract: both iOS display modes and tvOS SmartFill.
//

import XCTest

#if os(iOS) || os(tvOS)
final class ScenePresentationContractUITests: XCTestCase {
    private struct ContractOutcomes: Codable {
        let readySceneRendered: Bool
        let nextPerformed: Bool
        let outgoingMotionContinued: Bool
        let transitionDiagnostic: SceneTransitionDiagnostic.Verdict
        let hiddenDecodeExcludedFromHistory: Bool
        let visibleTickCommittedHistory: Bool
        let partialSlotFlashCount: Int
        let loadingFlashCount: Int
        let lowCoverageFramesAfterNext: Int
        let crossfadeFramesAfterNext: Int
    }

    private struct ContractSample: Codable {
        let elapsedSeconds: Double
        let phase: String
        let layerRoles: [String]
        let layerIDs: [String]
        let layerOpacities: [Double]
        let motionRawProgress: [Double]
        let decodedCount: Int
        let presentationReadyCount: Int
        let historyCount: Int
        let partialSlotVisible: Bool
        let loadingVisible: Bool
        let playbackPaused: Bool
        let lowCoverageFrameCount: Int
        let crossfadeFrameCount: Int
        let lastCrossfade: String
    }

    private struct ContractMedia: Codable {
        let videoPath: String
        let tracePath: String
        let screenshotPaths: [String]
    }

    private struct ContractRecord: Codable {
        let schemaVersion: String
        let evidenceLevel: String
        let productSHA: String
        let platform: String
        let deviceName: String
        let runtimeIdentifier: String
        let displayMode: String
        let intervalSeconds: Double
        let testName: String
        let startedAt: String
        let finishedAt: String
        let outcomes: ContractOutcomes
        let samples: [ContractSample]
        let media: ContractMedia
    }

    private struct ProbeState {
        let sample: ContractSample
        let hiddenDecodeExcludedFromHistory: Bool
        let visibleTickCommittedHistory: Bool
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testProbeStateRejectsMissingOrMalformedVisibilityEvidence() throws {
        let prefix = "schemaVersion=scene-presentation-contract-probe-v1;phase=stablePhoto"
        let playback = ";playbackPaused=true;lowCoverageFrameCount=0;crossfadeFrameCount=0;lastCrossfade=none"
        let complete = prefix + ";partialSlotVisible=false;loadingVisible=false" + playback
        let sample = try XCTUnwrap(probeState(from: complete, elapsedSeconds: 0))
        XCTAssertFalse(sample.sample.partialSlotVisible)
        XCTAssertFalse(sample.sample.loadingVisible)
        XCTAssertTrue(sample.sample.playbackPaused)
        XCTAssertEqual(sample.sample.lowCoverageFrameCount, 0)
        for invalid in [
            prefix,
            prefix + ";partialSlotVisible=false" + playback,
            prefix + ";loadingVisible=false" + playback,
            prefix + ";partialSlotVisible=unknown;loadingVisible=false" + playback,
            prefix + ";partialSlotVisible=false;loadingVisible=0" + playback,
            prefix + ";partialSlotVisible=false;loadingVisible=false",
            prefix + ";partialSlotVisible=false;loadingVisible=false;playbackPaused=1;lowCoverageFrameCount=0"
                + ";crossfadeFrameCount=0;lastCrossfade=none",
            prefix + ";partialSlotVisible=false;loadingVisible=false;playbackPaused=true;lowCoverageFrameCount=-1"
                + ";crossfadeFrameCount=0;lastCrossfade=none",
            prefix + ";partialSlotVisible=false;loadingVisible=false;playbackPaused=true"
                + ";crossfadeFrameCount=0;lastCrossfade=none",
            prefix + ";partialSlotVisible=false;loadingVisible=false;playbackPaused=true;lowCoverageFrameCount=0"
                + ";lastCrossfade=none",
            prefix + ";partialSlotVisible=false;loadingVisible=false;playbackPaused=true;lowCoverageFrameCount=0"
                + ";crossfadeFrameCount=0"
        ] {
            XCTAssertNil(probeState(from: invalid, elapsedSeconds: 0), "Missing/invalid fields must not count as clean")
        }
        let visible = try XCTUnwrap(
            probeState(
                from: prefix + ";partialSlotVisible=true;loadingVisible=true"
                    + ";playbackPaused=false;lowCoverageFrameCount=3;crossfadeFrameCount=2;lastCrossfade=a>b@0.1>0.2@0.1>0.2@0.5@steady",
                elapsedSeconds: 0
            ))
        XCTAssertTrue(visible.sample.partialSlotVisible)
        XCTAssertTrue(visible.sample.loadingVisible)
        XCTAssertFalse(visible.sample.playbackPaused)
        XCTAssertEqual(visible.sample.lowCoverageFrameCount, 3)
        XCTAssertEqual(visible.sample.crossfadeFrameCount, 2)
        XCTAssertEqual(visible.sample.lastCrossfade, "a>b@0.1>0.2@0.1>0.2@0.5@steady")
    }

    #if os(iOS)
    @MainActor
    func testIPhoneSmartFillSharedScenePresentationContract() throws {
        try runContract(displayMode: "smartFill")
    }

    @MainActor
    func testIPhoneSinglePhotoSharedScenePresentationContract() throws {
        try runContract(displayMode: "singlePhoto")
    }
    #endif

    #if os(tvOS)
    @MainActor
    func testTVOSSmartFillSharedScenePresentationContract() throws {
        try runContract(displayMode: "smartFill")
    }
    #endif

    @MainActor
    private func runContract(displayMode: String) throws {
        #if os(tvOS)
        let runDirectory: URL? = optionalRunDirectory()
        #else
        let runDirectory: URL? = try requiredRunDirectory()
        #endif
        let config = try requireTestServerConfig()
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT"] = "1"
        app.launchEnvironment["UI_TEST_FORCE_MODE_SELECTION"] = "1"
        app.launchEnvironment["UI_TEST_SEED_FILTER_SELECTION"] = "1"
        app.launchEnvironment["UI_TEST_FORCE_AUTOPLAY_OFF"] = "1"
        app.launchEnvironment["UI_TEST_FORCE_PLAYBACK_DISPLAY_MODE"] = displayMode
        app.launchEnvironment["UI_TEST_SCENE_PRESENTATION_CONTRACT_PROBE"] = "1"
        #if os(tvOS)
        try requireServerAlbumAndPerson()
        app.launchEnvironment["UI_TEST_PREPARE_FILTER_SUMMARY_VISUAL_SELECTIONS"] = "1"
        #endif
        app.launchEnvironment["UI_TEST_SERVER_URL"] = config.url
        app.launchEnvironment["UI_TEST_API_KEY"] = config.apiKey
        if let runDirectory {
            app.launchEnvironment["UI_TEST_EVIDENCE_DIR"] = runDirectory.path
        }
        for key in [
            "IMMICHSLIDES_SMARTFILL_REPLAY_ASSET_IDS_PATH",
            "IMMICHSLIDES_SMARTFILL_REPLAY_ASSET_IDS"
        ] {
            if let value = ProcessInfo.processInfo.environment[key]
                ?? ProcessInfo.processInfo.environment["TEST_RUNNER_\(key)"]
            {
                app.launchEnvironment[key] = value
            }
        }
        app.launch()

        enterPlaybackFromFilteredMode(app: app)

        let probe = app.descendants(matching: .any)["slideshow.scenePresentation.contract.summary"]
        XCTAssertTrue(probe.waitForExistence(timeout: 45), "The product host must expose the read-only contract probe")
        XCTAssertTrue(
            waitUntil(timeout: 45) {
                guard let state = self.probeState(from: probe.label, elapsedSeconds: 0) else { return false }
                return state.sample.phase == "stablePhoto" && state.sample.layerOpacities.contains(where: { $0 > 0 })
            },
            "The first full scene must reach Ready/stablePhoto"
        )

        let initialScreenshot = XCTAttachment(screenshot: app.screenshot())
        initialScreenshot.name = "scene-presentation-\(displayMode)-ready"
        initialScreenshot.lifetime = .keepAlways
        add(initialScreenshot)

        // Focus Next and read the baseline before pressing it, so only the press separates the baseline from the
        // first sample: the incoming scene can fade in and commit history within half a second.
        let nextButton = prepareNextButton(app: app)
        let stateBeforeNext = try XCTUnwrap(
            probeState(from: probe.label, elapsedSeconds: 0),
            "The probe must report the ready scene before Next"
        ).sample
        let historyCountBeforeNext = stateBeforeNext.historyCount
        let startedAt = Date()
        var probeStates: [ProbeState] = []
        activateNext(nextButton)

        // Watch at least the original window, and past a slow decode until the new photo has stayed settled a while;
        // the old photo may legitimately stay on screen that long.
        let minimumSamplingEnd = Date().addingTimeInterval(4.2)
        let samplingDeadline = Date().addingTimeInterval(15)
        var settledSince: Date?
        while Date() < samplingDeadline {
            let state = try XCTUnwrap(
                probeState(
                    from: probe.label,
                    elapsedSeconds: Date().timeIntervalSince(startedAt)
                ), "Probe sample missing or malformed; it must not be dropped and reported as clean")
            probeStates.append(state)
            let hasCrossfaded = state.sample.crossfadeFrameCount > stateBeforeNext.crossfadeFrameCount
            if hasCrossfaded, state.sample.phase == "stablePhoto" {
                let since = settledSince ?? Date()
                settledSince = since
                if Date() >= minimumSamplingEnd, Date().timeIntervalSince(since) >= 1 { break }
            } else {
                settledSince = nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        }

        let samples = probeStates.map(\.sample)
        let lastSample = samples.last ?? stateBeforeNext
        let crossfadeFramesAfterNext = lastSample.crossfadeFrameCount - stateBeforeNext.crossfadeFrameCount
        let crossfade = SceneTransitionDiagnostic.crossfadeEvidence(
            lastCrossfade: lastSample.lastCrossfade, frameCount: crossfadeFramesAfterNext)
        let transitionDiagnostic = SceneTransitionDiagnostic.evaluate(
            before: diagnosticSample(stateBeforeNext),
            after: samples.map(diagnosticSample),
            crossfade: crossfade,
            isPlaybackPaused: stateBeforeNext.playbackPaused
        )
        let initialHistoryCount = historyCountBeforeNext
        let finalHistoryCount = samples.last?.historyCount ?? initialHistoryCount
        let outcomes = ContractOutcomes(
            readySceneRendered: true,
            nextPerformed: crossfadeFramesAfterNext > 0,
            outgoingMotionContinued: transitionDiagnostic == .outgoingAdvanced,
            transitionDiagnostic: transitionDiagnostic,
            hiddenDecodeExcludedFromHistory: probeStates.contains(where: \.hiddenDecodeExcludedFromHistory),
            visibleTickCommittedHistory: probeStates.contains(where: \.visibleTickCommittedHistory)
                && finalHistoryCount > initialHistoryCount,
            partialSlotFlashCount: samples.filter(\.partialSlotVisible).count,
            loadingFlashCount: samples.filter(\.loadingVisible).count,
            lowCoverageFramesAfterNext: lastSample.lowCoverageFrameCount - stateBeforeNext.lowCoverageFrameCount,
            crossfadeFramesAfterNext: crossfadeFramesAfterNext
        )

        let diagnostic = XCTAttachment(data: try JSONEncoder().encode(samples), uniformTypeIdentifier: "public.json")
        diagnostic.name = "Desktop-transition-samples"
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
        XCTAssertTrue(stateBeforeNext.playbackPaused, "Autoplay is forced off, so playback must be paused before Next")
        XCTAssertTrue(outcomes.nextPerformed, "Next must crossfade from the old photo to the new one")
        XCTAssertEqual(
            outcomes.transitionDiagnostic, stateBeforeNext.playbackPaused ? .outgoingHeldStill : .outgoingAdvanced,
            "The old photo must stay on screen until the new one crossfades in, moving only while playback runs")
        XCTAssertEqual(
            outcomes.lowCoverageFramesAfterNext, 0, "No frame drawn after Next may show less than half a photo")
        XCTAssertTrue(outcomes.hiddenDecodeExcludedFromHistory, "A hidden renderer decode must not commit history")
        XCTAssertTrue(
            outcomes.visibleTickCommittedHistory,
            "A display tick after the full scene-root reaches opacity>0 must commit history")
        XCTAssertEqual(
            outcomes.partialSlotFlashCount, 0,
            "Diagnostic fields must not report partial flashes; a zero count does not mean a frame-by-frame visual pass"
        )
        XCTAssertEqual(
            outcomes.loadingFlashCount, 0,
            "Diagnostic fields must not report Loading; a zero count does not mean a frame-by-frame visual pass")

        let finalScreenshot = XCTAttachment(screenshot: app.screenshot())
        finalScreenshot.name = "scene-presentation-\(displayMode)-after-next"
        finalScreenshot.lifetime = .keepAlways
        add(finalScreenshot)

        let trace = samples.map { sample in
            "t=\(sample.elapsedSeconds);phase=\(sample.phase);roles=\(sample.layerRoles.joined(separator: "|"));ids=\(sample.layerIDs.joined(separator: "|"));opacity=\(sample.layerOpacities);progress=\(sample.motionRawProgress);decoded=\(sample.decodedCount);ready=\(sample.presentationReadyCount);history=\(sample.historyCount);partial=\(sample.partialSlotVisible);loading=\(sample.loadingVisible);paused=\(sample.playbackPaused);lowCoverageFrames=\(sample.lowCoverageFrameCount);crossfadeFrames=\(sample.crossfadeFrameCount);lastCrossfade=\(sample.lastCrossfade)"
        }.joined(separator: "\n")
        if let runDirectory {
            let record = ContractRecord(
                schemaVersion: "scene-presentation-contract-evidence-v2",
                evidenceLevel: "diagnostic_only",
                productSHA: ProcessInfo.processInfo.environment["TEST_RUNNER_PRODUCT_SHA"]
                    ?? String(repeating: "0", count: 40),
                platform: contractPlatform,
                deviceName: ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "unknown",
                runtimeIdentifier: ProcessInfo.processInfo.environment["SIMULATOR_RUNTIME_VERSION"] ?? "unknown",
                displayMode: displayMode,
                intervalSeconds: 5,
                testName: name,
                startedAt: ISO8601DateFormatter().string(from: startedAt),
                finishedAt: ISO8601DateFormatter().string(from: Date()),
                outcomes: outcomes,
                samples: samples,
                media: ContractMedia(
                    videoPath: ProcessInfo.processInfo.environment["TEST_RUNNER_SCENE_PRESENTATION_VIDEO_PATH"] ?? "",
                    tracePath: runDirectory.appendingPathComponent("\(displayMode)-trace.txt").path,
                    screenshotPaths: [
                        "scene-presentation-\(displayMode)-ready",
                        "scene-presentation-\(displayMode)-after-next"
                    ]
                )
            )
            try writeContractRecord(
                record,
                to: runDirectory.appendingPathComponent("\(displayMode)-contract-evidence.json")
            )
            try trace.write(
                to: runDirectory.appendingPathComponent("\(displayMode)-trace.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private func probeState(from label: String, elapsedSeconds: Double) -> ProbeState? {
        let fields = probeFields(from: label)
        guard fields["schemaVersion"] == "scene-presentation-contract-probe-v1",
            let phase = fields["phase"],
            let partialSlotRaw = fields["partialSlotVisible"],
            let loadingRaw = fields["loadingVisible"],
            let pausedRaw = fields["playbackPaused"],
            let lowCoverageRaw = fields["lowCoverageFrameCount"],
            let crossfadeCountRaw = fields["crossfadeFrameCount"],
            let lastCrossfade = fields["lastCrossfade"],
            let partialSlotVisible = Bool(partialSlotRaw),
            let loadingVisible = Bool(loadingRaw),
            let playbackPaused = Bool(pausedRaw),
            let lowCoverageFrameCount = Int(lowCoverageRaw),
            lowCoverageFrameCount >= 0,
            let crossfadeFrameCount = Int(crossfadeCountRaw),
            crossfadeFrameCount >= 0
        else {
            return nil
        }
        let roles = list(fields["layerRoles"])
        let layerIDs = list(fields["layerIDs"])
        let opacities = list(fields["layerOpacities"]).compactMap(Double.init)
        let progress = list(fields["motionRawProgress"]).compactMap(Double.init)
        return ProbeState(
            sample: ContractSample(
                elapsedSeconds: max(0, elapsedSeconds),
                phase: phase,
                layerRoles: roles,
                layerIDs: layerIDs,
                layerOpacities: opacities,
                motionRawProgress: progress,
                decodedCount: Int(fields["decodedCount"] ?? "") ?? 0,
                presentationReadyCount: Int(fields["presentationReadyCount"] ?? "") ?? 0,
                historyCount: Int(fields["historyCount"] ?? "") ?? 0,
                partialSlotVisible: partialSlotVisible,
                loadingVisible: loadingVisible,
                playbackPaused: playbackPaused,
                lowCoverageFrameCount: lowCoverageFrameCount,
                crossfadeFrameCount: crossfadeFrameCount,
                lastCrossfade: lastCrossfade
            ),
            hiddenDecodeExcludedFromHistory: fields["hiddenDecodeExcludedFromHistory"] == "true",
            visibleTickCommittedHistory: fields["visibleTickCommittedHistory"] == "true"
        )
    }

    private func diagnosticSample(_ sample: ContractSample) -> SceneTransitionDiagnostic.Sample {
        .init(
            phase: sample.phase, roles: sample.layerRoles, ids: sample.layerIDs,
            opacities: sample.layerOpacities, progress: sample.motionRawProgress)
    }

    private var contractPlatform: String {
        #if os(tvOS)
        "tvOS"
        #else
        "iOS"
        #endif
    }

    private func probeFields(from label: String) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: label.split(separator: ";").compactMap { pair in
                guard let separator = pair.firstIndex(of: "=") else { return nil }
                return (
                    String(pair[..<separator]),
                    String(pair[pair.index(after: separator)...])
                )
            }
        )
    }

    private func writeContractRecord(_ record: ContractRecord, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    private func list(_ raw: String?) -> [String] {
        guard let raw, raw != "none", !raw.isEmpty else { return [] }
        return raw.split(separator: "|").map(String.init)
    }

    private func requiredRunDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["TEST_RUNNER_SCENE_PRESENTATION_CONTRACT_RUN_DIR"],
            !path.isEmpty
        else {
            throw XCTSkip(
                "Runs only when TEST_RUNNER_SCENE_PRESENTATION_CONTRACT_RUN_DIR points to a persistent evidence directory"
            )
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func optionalRunDirectory() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["TEST_RUNNER_SCENE_PRESENTATION_CONTRACT_RUN_DIR"],
            !path.isEmpty
        else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    @MainActor
    private func enterPlaybackFromFilteredMode(app: XCUIApplication) {
        let filteredButton = app.buttons["mode.filtered.button"]
        XCTAssertTrue(filteredButton.waitForExistence(timeout: 20))
        let continueButton = app.buttons["mode.continue.button"]
        let startButton = app.buttons["filterSummary.startPlayback.button"]

        #if os(tvOS)
        // tvOS must reach filtering through real remote focus, not a faked tap.
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(continueButton.waitForExistence(timeout: 8))
        XCTAssertTrue(continueButton.isEnabled)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(startButton.waitForExistence(timeout: 12))
        // Starting before the page swaps in a real album and person would play the seeded placeholder album.
        for marker in ["filterSummary.album.ready", "filterSummary.people.ready"] {
            let readiness = app.staticTexts[marker]
            XCTAssertTrue(
                waitUntil(timeout: 30) { readiness.exists && readiness.label == "ready" },
                "The filter summary must select a real album and person before playback starts: \(marker)"
            )
        }
        XCTAssertTrue(waitUntil(timeout: 12) { startButton.isEnabled })
        for _ in 0..<8 where !startButton.hasFocus {
            XCUIRemote.shared.press(.down)
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }
        XCTAssertTrue(startButton.hasFocus, "The tvOS Start Playback button must be able to take focus")
        XCUIRemote.shared.press(.select)
        #else
        tap(filteredButton)
        XCTAssertTrue(continueButton.waitForExistence(timeout: 8))
        XCTAssertTrue(continueButton.isEnabled)
        tap(continueButton)
        XCTAssertTrue(startButton.waitForExistence(timeout: 12))
        XCTAssertTrue(waitUntil(timeout: 12) { startButton.isEnabled })
        tap(startButton)
        #endif
    }

    @MainActor
    private func prepareNextButton(app: XCUIApplication) -> XCUIElement {
        let nextButton = app.buttons["slideshow.control.next.button"]
        XCTAssertTrue(nextButton.waitForExistence(timeout: 6))

        #if os(tvOS)
        for _ in 0..<4 where !nextButton.hasFocus {
            XCUIRemote.shared.press(.right)
            RunLoop.current.run(until: Date().addingTimeInterval(0.16))
        }
        XCTAssertTrue(nextButton.hasFocus, "The tvOS Next button must be able to take focus")
        #endif
        return nextButton
    }

    @MainActor
    private func activateNext(_ nextButton: XCUIElement) {
        #if os(tvOS)
        XCUIRemote.shared.press(.select)
        #else
        tap(nextButton)
        #endif
    }

    #if os(iOS)
    @MainActor
    private func tap(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }
    #endif

    private func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
}
#endif
