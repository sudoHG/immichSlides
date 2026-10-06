//
//  ScenePresentationContractUITests.swift
//  immichSlidesUITests
//
//  Shared scene presentation runtime contract: both iOS display modes and tvOS SmartFill.
//

import XCTest

private enum WaitTiming {
    static let minimumSamplingWindowSeconds: TimeInterval = 4.2
    static let samplingTimeoutSeconds: TimeInterval = 15
    static let controlAppearanceTimeoutSeconds: TimeInterval = 8
    static let focusPollSeconds: TimeInterval = 0.08
    static let focusSettleSeconds: TimeInterval = 0.16
    static let inputSettleSeconds: TimeInterval = 0.05
    static let remotePressSettleSeconds: TimeInterval = 0.12
    static let sceneReadyTimeoutSeconds: TimeInterval = 45
    static let screenTransitionTimeoutSeconds: TimeInterval = 12
}

#if os(iOS) || os(tvOS)
final class ScenePresentationContractUITests: XCTestCase {
    private struct ContractOutcomes: Codable {
        let didRenderReadyScene: Bool
        let didPerformNext: Bool
        let didContinueOutgoingMotion: Bool
        let transitionDiagnostic: SceneTransitionDiagnostic.Verdict
        let didExcludeHiddenDecodeFromHistory: Bool
        let didCommitHistoryOnVisibleTick: Bool
        let partialSlotFlashCount: Int
        let loadingFlashCount: Int
        let lowCoverageFramesAfterNext: Int
        let crossfadeFramesAfterNext: Int

        private enum CodingKeys: String, CodingKey {
            case didRenderReadyScene = "readySceneRendered"
            case didPerformNext = "nextPerformed"
            case didContinueOutgoingMotion = "outgoingMotionContinued"
            case transitionDiagnostic
            case didExcludeHiddenDecodeFromHistory = "hiddenDecodeExcludedFromHistory"
            case didCommitHistoryOnVisibleTick = "visibleTickCommittedHistory"
            case partialSlotFlashCount
            case loadingFlashCount
            case lowCoverageFramesAfterNext
            case crossfadeFramesAfterNext
        }
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
        let isPartialSlotVisible: Bool
        let isLoadingVisible: Bool
        let isPlaybackPaused: Bool
        let lowCoverageFrameCount: Int
        let crossfadeFrameCount: Int
        let lastCrossfade: String

        private enum CodingKeys: String, CodingKey {
            case elapsedSeconds
            case phase
            case layerRoles
            case layerIDs
            case layerOpacities
            case motionRawProgress
            case decodedCount
            case presentationReadyCount
            case historyCount
            case isPartialSlotVisible = "partialSlotVisible"
            case isLoadingVisible = "loadingVisible"
            case isPlaybackPaused = "playbackPaused"
            case lowCoverageFrameCount
            case crossfadeFrameCount
            case lastCrossfade
        }
    }

    private struct ContractMedia: Codable {
        let videoPath: String?
        let tracePath: String
        let screenshotPaths: [String]
    }

    private struct ContractRecord: Codable {
        let schemaVersion: String
        let evidenceLevel: String
        let productSHA: String?
        let platform: String
        let deviceName: String?
        let runtimeIdentifier: String?
        let displayMode: String
        let testName: String
        let startedAt: String
        let finishedAt: String
        let outcomes: ContractOutcomes
        let samples: [ContractSample]
        let media: ContractMedia
    }

    private struct ProbeState {
        let sample: ContractSample
        let didExcludeHiddenDecodeFromHistory: Bool
        let didCommitHistoryOnVisibleTick: Bool
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testProbeStateRejectsMissingOrMalformedVisibilityEvidence() throws {
        let prefix = "schemaVersion=scene-presentation-contract-probe-v1;phase=stablePhoto"
        let playback = ";playbackPaused=true;lowCoverageFrameCount=0;crossfadeFrameCount=0;lastCrossfade=none"
        let complete = prefix + ";partialSlotVisible=false;loadingVisible=false" + playback
        let sample = try XCTUnwrap(probeState(from: complete, elapsedSeconds: 0))
        XCTAssertFalse(sample.sample.isPartialSlotVisible)
        XCTAssertFalse(sample.sample.isLoadingVisible)
        XCTAssertTrue(sample.sample.isPlaybackPaused)
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
        XCTAssertTrue(visible.sample.isPartialSlotVisible)
        XCTAssertTrue(visible.sample.isLoadingVisible)
        XCTAssertFalse(visible.sample.isPlaybackPaused)
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

    @MainActor
    func testIOSImageFailureRecovery() throws {
        try runImageFailureRecovery()
    }
    #endif

    #if os(tvOS)
    @MainActor
    func testTVOSSmartFillSharedScenePresentationContract() throws {
        try runContract(displayMode: "smartFill")
    }

    #endif

    #if os(iOS)
    @MainActor
    private func runImageFailureRecovery() throws {
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }
        XCUIDevice.shared.orientation = .portrait
        let driver = IOSDriver(app: app)
        driver.launchToPlayback(input: input)
        let evidence = Evidence()
        defer { _ = try? imageResponse(input: input, mode: "normal") }
        driver.pause()
        activatePlaybackControl(app: app, identifier: "slideshow.control.playPause.button")
        driver.applyPlaybackSettings([.displayMode(isSinglePhoto: true), .showExif(false)])
        _ = try imageResponse(input: input, mode: "http", assetID: "asset-a-1")
        // A cold launch removes memory-cache hits while preserving the real saved playback settings.
        try driver.clearDiskCache(onCachePage: {})
        app.terminate()
        _ = try imageResponse(input: input, mode: "http", assetID: "asset-a-1")
        try relaunchStrictE2EApp(app)
        let recovered = try captureRecoveryIdentity("singlePhoto-recovered", app: app, evidence: evidence) {
            $0 != "A1"
        }
        let response = try imageResponse(input: input)
        XCTAssertGreaterThan(
            response["failures"] as? Int ?? 0, 0, "The fixture must actually deliver a failing image response")
        driver.pause()
        activateNext(prepareNextButton(app: app))
        let next = try captureRecoveryIdentity("singlePhoto-next", app: app, evidence: evidence) { $0 != recovered }
        activatePlaybackControl(app: app, identifier: "slideshow.control.previous.button")
        let previous = try captureRecoveryIdentity("singlePhoto-previous", app: app, evidence: evidence) {
            $0 == recovered
        }
        activateNext(prepareNextButton(app: app))
        let redo = try captureRecoveryIdentity("singlePhoto-redo", app: app, evidence: evidence) { $0 == next }
        driver.pause()
        activatePlaybackControl(app: app, identifier: "slideshow.control.playPause.button")
        let continued = try captureRecoveryIdentity("singlePhoto-continued", app: app, evidence: evidence) {
            $0 != redo
        }
        try StrictE2EVisualEvidence.writeRequiredJSON(
            [
                "schema": "image-failure-recovery-v1",
                "flows": [
                    [
                        "display_mode": "singlePhoto", "failure_mode": "http", "failed_asset_id": "asset-a-1",
                        "failed_response_count": response["failures"] ?? 0, "recovered": recovered, "next": next,
                        "previous": previous, "redo": redo, "continued": continued
                    ]
                ]
            ], name: "image-failure-recovery.json")
    }

    @MainActor
    private func captureRecoveryIdentity(
        _ name: String, app: XCUIApplication, evidence: Evidence, accept: (String) -> Bool
    ) throws -> String {
        let deadline = Date().addingTimeInterval(45)
        var previous: String?
        while Date() < deadline {
            let capturedAt = Date()
            let png = app.screenshot().pngRepresentation
            let identity = StrictE2EPhotoIdentity.captureIdentity(png: png)
            if identity.status == .match, let mark = identity.mark, accept(mark) {
                if mark == previous {
                    try evidence.record(name, png: png, capturedAt: capturedAt, orientation: .notApplicable)
                    return mark
                }
                previous = mark
            } else {
                previous = nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        try evidence.reject(name, png: app.screenshot().pngRepresentation)
        throw Failure("\(name) did not render the required public photo identity before the deadline")
    }

    @MainActor
    private func activatePlaybackControl(app: XCUIApplication, identifier: String) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 8))
        tap(button)
    }

    private func imageResponse(input: StrictE2EInput, mode: String? = nil, assetID: String? = nil) throws -> [String:
        Any]
    {
        let url = try XCTUnwrap(URL(string: input.serverURL + "/test/image-response"))
        var request = URLRequest(url: url)
        request.setValue(input.publicKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 15
        if let mode {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["mode": mode]
            if let assetID { body["asset_id"] = assetID }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?
        var status: Int?
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            payload = data
            status = (response as? HTTPURLResponse)?.statusCode
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + 15) == .success else {
            task.cancel()
            throw Failure("Fixture image response control timed out")
        }
        XCTAssertEqual(status, 200, "Fixture control must acknowledge its response mode")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(payload)) as? [String: Any])
    }
    #endif

    @MainActor
    private func runContract(displayMode: String) throws {
        #if os(tvOS)
        let runDirectory: URL? = try optionalRunDirectory()
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
        XCTAssertTrue(
            probe.waitForExistence(timeout: WaitTiming.sceneReadyTimeoutSeconds),
            "The product host must expose the read-only contract probe")
        XCTAssertTrue(
            waitUntil(timeout: WaitTiming.sceneReadyTimeoutSeconds) {
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
        let minimumSamplingEnd = Date().addingTimeInterval(WaitTiming.minimumSamplingWindowSeconds)
        let samplingDeadline = Date().addingTimeInterval(WaitTiming.samplingTimeoutSeconds)
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
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.focusPollSeconds))
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
            isPlaybackPaused: stateBeforeNext.isPlaybackPaused
        )
        let initialHistoryCount = historyCountBeforeNext
        let finalHistoryCount = samples.last?.historyCount ?? initialHistoryCount
        let outcomes = ContractOutcomes(
            didRenderReadyScene: true,
            didPerformNext: crossfadeFramesAfterNext > 0,
            didContinueOutgoingMotion: transitionDiagnostic == .outgoingAdvanced,
            transitionDiagnostic: transitionDiagnostic,
            didExcludeHiddenDecodeFromHistory: probeStates.contains(where: \.didExcludeHiddenDecodeFromHistory),
            didCommitHistoryOnVisibleTick: probeStates.contains(where: \.didCommitHistoryOnVisibleTick)
                && finalHistoryCount > initialHistoryCount,
            partialSlotFlashCount: samples.filter(\.isPartialSlotVisible).count,
            loadingFlashCount: samples.filter(\.isLoadingVisible).count,
            lowCoverageFramesAfterNext: lastSample.lowCoverageFrameCount - stateBeforeNext.lowCoverageFrameCount,
            crossfadeFramesAfterNext: crossfadeFramesAfterNext
        )

        let diagnostic = XCTAttachment(data: try JSONEncoder().encode(samples), uniformTypeIdentifier: "public.json")
        diagnostic.name = "Desktop-transition-samples"
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
        XCTAssertTrue(
            stateBeforeNext.isPlaybackPaused, "Autoplay is forced off, so playback must be paused before Next")
        XCTAssertTrue(outcomes.didPerformNext, "Next must crossfade from the old photo to the new one")
        XCTAssertEqual(
            outcomes.transitionDiagnostic, stateBeforeNext.isPlaybackPaused ? .outgoingHeldStill : .outgoingAdvanced,
            "The old photo must stay on screen until the new one crossfades in, moving only while playback runs")
        XCTAssertEqual(
            outcomes.lowCoverageFramesAfterNext, 0, "No frame drawn after Next may show less than half a photo")
        XCTAssertTrue(outcomes.didExcludeHiddenDecodeFromHistory, "A hidden renderer decode must not commit history")
        XCTAssertTrue(
            outcomes.didCommitHistoryOnVisibleTick,
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
            "t=\(sample.elapsedSeconds);phase=\(sample.phase);roles=\(sample.layerRoles.joined(separator: "|"));ids=\(sample.layerIDs.joined(separator: "|"));opacity=\(sample.layerOpacities);progress=\(sample.motionRawProgress);decoded=\(sample.decodedCount);ready=\(sample.presentationReadyCount);history=\(sample.historyCount);partial=\(sample.isPartialSlotVisible);loading=\(sample.isLoadingVisible);paused=\(sample.isPlaybackPaused);lowCoverageFrames=\(sample.lowCoverageFrameCount);crossfadeFrames=\(sample.crossfadeFrameCount);lastCrossfade=\(sample.lastCrossfade)"
        }.joined(separator: "\n")
        if let runDirectory {
            let record = ContractRecord(
                schemaVersion: "scene-presentation-contract-evidence-v3",
                evidenceLevel: "diagnostic_only",
                productSHA: ProcessInfo.processInfo.environment["TEST_RUNNER_PRODUCT_SHA"],
                platform: contractPlatform,
                deviceName: ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"],
                runtimeIdentifier: ProcessInfo.processInfo.environment["SIMULATOR_RUNTIME_VERSION"],
                displayMode: displayMode,
                testName: name,
                startedAt: ISO8601DateFormatter().string(from: startedAt),
                finishedAt: ISO8601DateFormatter().string(from: Date()),
                outcomes: outcomes,
                samples: samples,
                media: ContractMedia(
                    videoPath: ProcessInfo.processInfo.environment["TEST_RUNNER_SCENE_PRESENTATION_VIDEO_PATH"],
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
            let isPartialSlotVisible = Bool(partialSlotRaw),
            let isLoadingVisible = Bool(loadingRaw),
            let isPlaybackPaused = Bool(pausedRaw),
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
                isPartialSlotVisible: isPartialSlotVisible,
                isLoadingVisible: isLoadingVisible,
                isPlaybackPaused: isPlaybackPaused,
                lowCoverageFrameCount: lowCoverageFrameCount,
                crossfadeFrameCount: crossfadeFrameCount,
                lastCrossfade: lastCrossfade
            ),
            didExcludeHiddenDecodeFromHistory: fields["hiddenDecodeExcludedFromHistory"] == "true",
            didCommitHistoryOnVisibleTick: fields["visibleTickCommittedHistory"] == "true"
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
        guard let directory = try optionalRunDirectory() else {
            throw XCTSkip(
                "Runs only when TEST_RUNNER_SCENE_PRESENTATION_CONTRACT_RUN_DIR points to a persistent evidence directory"
            )
        }
        return directory
    }

    private func optionalRunDirectory() throws -> URL? {
        try PrivateEvidenceDirectory.resolve(
            rootPath: ProcessInfo.processInfo.environment["TEST_RUNNER_SCENE_PRESENTATION_CONTRACT_RUN_DIR"],
            components: []
        )
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
        XCTAssertTrue(continueButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds))
        XCTAssertTrue(continueButton.isEnabled)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(startButton.waitForExistence(timeout: WaitTiming.screenTransitionTimeoutSeconds))
        // Starting before the page swaps in a real album and person would play the seeded placeholder album.
        for marker in ["filterSummary.album.ready", "filterSummary.people.ready"] {
            let readiness = app.staticTexts[marker]
            XCTAssertTrue(
                waitUntil(timeout: 30) { readiness.exists && readiness.label == "ready" },
                "The filter summary must select a real album and person before playback starts: \(marker)"
            )
        }
        XCTAssertTrue(waitUntil(timeout: WaitTiming.screenTransitionTimeoutSeconds) { startButton.isEnabled })
        for _ in 0..<8 where !startButton.hasFocus {
            XCUIRemote.shared.press(.down)
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.remotePressSettleSeconds))
        }
        XCTAssertTrue(startButton.hasFocus, "The tvOS Start Playback button must be able to take focus")
        XCUIRemote.shared.press(.select)
        #else
        tap(filteredButton)
        XCTAssertTrue(continueButton.waitForExistence(timeout: WaitTiming.controlAppearanceTimeoutSeconds))
        XCTAssertTrue(continueButton.isEnabled)
        tap(continueButton)
        XCTAssertTrue(startButton.waitForExistence(timeout: WaitTiming.screenTransitionTimeoutSeconds))
        XCTAssertTrue(waitUntil(timeout: WaitTiming.screenTransitionTimeoutSeconds) { startButton.isEnabled })
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
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.focusSettleSeconds))
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
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.inputSettleSeconds))
        }
        return condition()
    }
}
#endif
