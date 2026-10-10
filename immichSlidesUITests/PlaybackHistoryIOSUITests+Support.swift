import XCTest

#if os(iOS)
extension PlaybackHistoryIOSUITests {
    func attachManualLifecycleRuntimeEvidence(mode: ManualLifecycleMode) {
        guard !manualLifecycleRuntimeEvidenceRows.isEmpty,
            JSONSerialization.isValidJSONObject(manualLifecycleRuntimeEvidenceRows),
            let data = try? JSONSerialization.data(
                withJSONObject: manualLifecycleRuntimeEvidenceRows,
                options: [.prettyPrinted, .sortedKeys]
            )
        else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "manual-lifecycle-\(mode == .smartFill ? "smartfill" : "single-photo")-runtime-sequence"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func currentSceneIdentity(app: XCUIApplication, mode: ManualLifecycleMode) -> String? {
        if mode == .smartFill {
            return currentCompleteVisibleSmartFillScene(app: app)?.sceneIdentity
        }
        return currentAssetID(app: app)
    }

    func announceManualLifecycleCaptureWindowIfRequested(mode: ManualLifecycleMode, kind: String) {
        guard let path = ProcessInfo.processInfo.environment["TEST_RUNNER_MANUAL_LIFECYCLE_CAPTURE_READY_FILE"],
            !path.isEmpty
        else {
            emitManualLifecycleCaptureStatus(mode: mode, kind: kind, markerStatus: "not-configured")
            return
        }
        let payload: [String: Any] = [
            "mode": mode == .smartFill ? "smartFill" : "singlePhoto",
            "kind": kind,
            "readyAt": ISO8601DateFormatter().string(from: Date())
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            emitManualLifecycleCaptureStatus(mode: mode, kind: kind, markerStatus: "encode-failed")
            return
        }
        let markerStatus: String
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            markerStatus = "written"
        } catch {
            markerStatus = "write-failed"
        }
        emitManualLifecycleCaptureStatus(mode: mode, kind: kind, markerStatus: markerStatus)
        // External recording must wait for a visible stable scene; only the test capture path keeps this sync window.
        RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.infrastructure(1))))
    }

    func emitManualLifecycleCaptureStatus(mode: ManualLifecycleMode, kind: String, markerStatus: String) {
        let modeName = mode == .smartFill ? "smartFill" : "singlePhoto"
        let line = "MANUAL_LIFECYCLE_CAPTURE_READY mode=\(modeName) kind=\(kind) marker=\(markerStatus)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    func openPlaybackSettingsFromSlideshow(app: XCUIApplication) {
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.infrastructure(8))) {
                settingsButton.exists && settingsButton.isHittable
            })
        tapElement(settingsButton)

        let playbackEntry: XCUIElement
        if UIDevice.current.userInterfaceIdiom == .pad {
            if app.switches["settings.playback.autoPlay.toggle"].waitForExistence(
                timeout: TestWait.seconds(.infrastructure(2)))
            {
                return
            }
            let sidebar = app.buttons["ToggleSidebar"]
            if sidebar.exists && ["显示边栏", "Show Sidebar"].contains(sidebar.label) {
                tapElement(sidebar)
            }
            playbackEntry = app.descendants(matching: .any)["settings.item.playback"].firstMatch
        } else {
            playbackEntry = app.buttons["settings.item.playback"]
        }
        XCTAssertTrue(
            playbackEntry.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
            "The settings list must provide the Playback Settings entry")
        tapElement(playbackEntry)
    }

    func requireAutoPlayToggle(app: XCUIApplication) throws -> XCUIElement {
        let toggle = app.switches["settings.playback.autoPlay.toggle"]
        guard toggle.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))) else {
            throw NSError(
                domain: "PlaybackHistoryIOSUITests",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "missing settings.playback.autoPlay.toggle"]
            )
        }
        return toggle
    }

    func returnToSlideshowFromPlaybackSettings(app: XCUIApplication) {
        for _ in 0..<6 {
            let settingsButton = app.buttons["slideshow.control.settings.button"]
            if settingsButton.exists && settingsButton.isHittable { return }

            let globalBack = app.buttons["global.back.button"]
            if globalBack.exists && globalBack.isHittable {
                tapElement(globalBack)
                continue
            }
            let backButton =
                app.navigationBars.buttons.allElementsBoundByIndex
                .filter { $0.exists && $0.isHittable && $0.identifier == "BackButton" }
                .last
                ?? app.navigationBars.buttons.allElementsBoundByIndex
                .filter { $0.exists && $0.isHittable && $0.identifier != "ToggleSidebar" }
                .first
            if let backButton {
                backButton.tap()
            } else {
                app.tap()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.3))))
        }
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.infrastructure(6))) {
                let settingsButton = app.buttons["slideshow.control.settings.button"]
                return settingsButton.exists && settingsButton.isHittable
            },
            "Could not return from the playback settings page to the slideshow"
        )
    }

    func playPauseState(_ button: XCUIElement) -> String {
        ((button.value as? String) ?? "").lowercased()
    }

    func isToggleOn(_ toggle: XCUIElement) -> Bool {
        let value = ((toggle.value as? String) ?? "").lowercased()
        return value == "1" || value == "true"
    }

    func waitForPresentationProbe(app: XCUIApplication, timeout: TimeInterval) throws -> ScenePresentationProbe {
        guard waitUntil(timeout: timeout, condition: { self.presentationProbe(app: app) != nil }),
            let probe = presentationProbe(app: app)
        else {
            let hierarchy = app.debugDescription
            print("MANUAL_LIFECYCLE_PROBE_HIERARCHY_BEGIN\n\(hierarchy)\nMANUAL_LIFECYCLE_PROBE_HIERARCHY_END")
            let attachment = XCTAttachment(data: Data(hierarchy.utf8), uniformTypeIdentifier: "public.plain-text")
            attachment.name = "manual-lifecycle-missing-contract-probe-hierarchy"
            attachment.lifetime = .keepAlways
            add(attachment)
            throw NSError(
                domain: "PlaybackHistoryIOSUITests", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "missing presentation contract probe"])
        }
        return probe
    }

    func waitForStablePresentationProbe(app: XCUIApplication, timeout: TimeInterval) throws -> ScenePresentationProbe {
        guard
            waitUntil(
                timeout: timeout,
                condition: {
                    guard let probe = self.presentationProbe(app: app) else { return false }
                    return probe.phase == "stablePhoto" && !probe.rawProgress.isEmpty
                }), let probe = presentationProbe(app: app)
        else {
            throw NSError(
                domain: "PlaybackHistoryIOSUITests",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "scene presentation did not reach stablePhoto"]
            )
        }
        return probe
    }

    func waitForFrameSynchronizedPresentationProbe(
        app: XCUIApplication,
        timeout: TimeInterval
    ) throws -> ScenePresentationProbe {
        guard
            waitUntil(
                timeout: timeout,
                condition: {
                    guard let probe = self.frameSynchronizedPresentationProbe(app: app) else { return false }
                    return probe.phase == "stablePhoto" && !probe.rawProgress.isEmpty
                }), let probe = frameSynchronizedPresentationProbe(app: app)
        else {
            let frameProbe = app.descendants(matching: .any)["slideshow.scenePresentation.frameSynchronized.summary"]
            let contractProbe = app.descendants(matching: .any)["slideshow.scenePresentation.contract.summary"]
            let diagnostic = [
                "frameProbe.exists=\(frameProbe.exists)",
                "frameProbe.label=\(frameProbe.label)",
                "contractProbe.exists=\(contractProbe.exists)",
                "contractProbe.label=\(contractProbe.label)",
                "MANUAL_LIFECYCLE_FRAME_SYNCHRONIZED_HIERARCHY_BEGIN",
                app.debugDescription,
                "MANUAL_LIFECYCLE_FRAME_SYNCHRONIZED_HIERARCHY_END"
            ].joined(separator: "\n")
            print(diagnostic)
            let attachment = XCTAttachment(data: Data(diagnostic.utf8), uniformTypeIdentifier: "public.plain-text")
            attachment.name = "manual-lifecycle-frame-synchronized-probe-diagnostic"
            attachment.lifetime = .keepAlways
            add(attachment)
            throw NSError(
                domain: "PlaybackHistoryIOSUITests",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "missing frame-synchronized scene presentation probe"]
            )
        }
        return probe
    }

    // A pause can land mid-transition, and the reducer then freezes each layer's fade (ScenePresentationReducerTests),
    // so the freeze checks accept a paused transition as well as a stable scene. At least one photo layer must show.
    func waitForPausedFrameSynchronizedPresentationProbe(
        app: XCUIApplication,
        timeout: TimeInterval
    ) throws -> ScenePresentationProbe {
        guard
            waitUntil(
                timeout: timeout,
                condition: {
                    guard let probe = self.frameSynchronizedPresentationProbe(app: app) else { return false }
                    return ["stablePhoto", "transition"].contains(probe.phase) && !probe.rawProgress.isEmpty
                        && probe.opacities.contains { $0 > 0 }
                }), let probe = frameSynchronizedPresentationProbe(app: app)
        else {
            let label = app.descendants(matching: .any)["slideshow.scenePresentation.frameSynchronized.summary"]
            let observed = label.exists ? label.label : "missing"
            throw NSError(
                domain: "PlaybackHistoryIOSUITests",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "paused scene is not a visible photo scene: \(observed)"]
            )
        }
        return probe
    }

    func presentationProbe(app: XCUIApplication) -> ScenePresentationProbe? {
        scenePresentationProbe(identifier: "slideshow.scenePresentation.contract.summary", app: app)
    }

    func frameSynchronizedPresentationProbe(app: XCUIApplication) -> ScenePresentationProbe? {
        scenePresentationProbe(identifier: "slideshow.scenePresentation.frameSynchronized.summary", app: app)
    }

    func scenePresentationProbe(identifier: String, app: XCUIApplication) -> ScenePresentationProbe? {
        let element = app.descendants(matching: .any)[identifier]
        guard element.exists else { return nil }
        let fields = SharedSceneEvidenceManifest.parseKeyValueFields(element.label)
        func numbers(_ key: String) -> [Double] {
            (fields[key] ?? "").split(separator: "|").compactMap { Double($0) }
        }
        // phase=empty is real evidence of empty input; do not disguise it as a missing probe.

        guard let phase = fields["phase"] else { return nil }
        return ScenePresentationProbe(
            phase: phase,
            rawProgress: numbers("motionRawProgress"),
            opacities: numbers("layerOpacities")
        )
    }

    // These fields are the render's clock (`systemUptime` when SwiftUI evaluated the view) and times derived
    // from it, so any re-render of a paused scene moves them. The paused motion clock stays under test through
    // `progress`, `stableVisibleDuration` and `transitionCompletionDelay`.
    static let renderTimeAnchoredSlotProbeFields: Set<String> = [
        "presentationSampleTime", "timelineStartTime", "stableVisibleStartTime",
        "handoffStartDeadlineTime", "removalDeadlineTime"
    ]

    // Interface chrome and next-scene bookkeeping are not photo rendering: the pause contract freezes the photo only (#218).
    static let nonPhotoSlotProbeFields: Set<String> = [
        "controlBarVisible", "appOverlayPollution", "preparedNextTargetIndex", "preparedNextSourceCursor",
        "currentPreparedSourceCursor", "lookaheadCachedSourceCursor", "lookaheadCachedSelectedCount"
    ]

    func frozenStateOfSmartFillSlots(app: XCUIApplication) -> [String] {
        smartFillRenderedSlotProbeLabels(app: app).map { probe in
            probe.split(separator: ";", omittingEmptySubsequences: false)
                .filter { field in
                    let key = field.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
                    return !Self.renderTimeAnchoredSlotProbeFields.contains(key)
                        && !Self.nonPhotoSlotProbeFields.contains(key)
                }
                .joined(separator: ";")
        }
    }

    func smartFillRenderedSlotProbeLabels(app: XCUIApplication) -> [String] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "slideshow.smartfill.motionFrame."))
            .allElementsBoundByIndex
            .map { $0.identifier + "=" + $0.label }
            .sorted()
    }

    func assertSmartFillPauseOnlyFrameFreeze(
        app: XCUIApplication,
        evidenceEventPrefix: String
    ) throws {
        let initialProbe = try waitForPausedFrameSynchronizedPresentationProbe(
            app: app, timeout: TestWait.seconds(.product(3)))
        let initialSlots = frozenStateOfSmartFillSlots(app: app)
        XCTAssertFalse(
            initialSlots.isEmpty,
            "The pause diagnostic must read the rendered frame/transform probe of every SmartFill slot")
        let initialSample = capturePausedWindowSample(app: app)
        appendManualLifecycleRuntimeEvidence(
            app: app, mode: .smartFill, event: "\(evidenceEventPrefix)-start", probe: initialProbe)
        let initialPixelsAttachment = XCTAttachment(data: initialSample.png, uniformTypeIdentifier: "public.png")
        initialPixelsAttachment.name = "\(evidenceEventPrefix)-start"
        initialPixelsAttachment.lifetime = .keepAlways
        add(initialPixelsAttachment)

        for sample in 1...PlaybackHistoryIOSUITestsCalibration.pauseSampleCount {
            RunLoop.current.run(
                until: Date().addingTimeInterval(
                    TestWait.seconds(.product(PlaybackHistoryIOSUITestsCalibration.pauseSampleIntervalSeconds))))
            let probe = try waitForPausedFrameSynchronizedPresentationProbe(
                app: app, timeout: TestWait.seconds(.product(2)))
            let slots = frozenStateOfSmartFillSlots(app: app)
            let sampleWindow = capturePausedWindowSample(app: app)
            let pixels = sampleWindow.png
            let frame = XCTAttachment(data: pixels, uniformTypeIdentifier: "public.png")
            frame.name = "Desktop-settings-pause-before-assert-\(sample)"
            frame.lifetime = .keepAlways
            add(frame)
            XCTAssertEqual(probe.phase, initialProbe.phase, "The scene phase must not change while paused")
            XCTAssertEqual(probe.opacities, initialProbe.opacities, "Layer opacities must not change while paused")
            XCTAssertEqual(
                probe.rawProgress, initialProbe.rawProgress,
                "After pausing, the frame-synchronized motionRawProgress must stay frozen")
            XCTAssertEqual(
                slots, initialSlots,
                "After pausing, the rendered transform/frame of every SmartFill slot must stay frozen")
            let pixelComparison = comparePausedPhotoPixels(sampleWindow, against: initialSample)
            let comparisonAttachment = XCTAttachment(
                data: Data(pixelComparison.summary.utf8), uniformTypeIdentifier: "public.plain-text")
            comparisonAttachment.name = "\(evidenceEventPrefix)-photo-pixels-sample-\(sample)"
            comparisonAttachment.lifetime = .keepAlways
            add(comparisonAttachment)
            XCTAssertNil(
                pixelComparison.failureReason, "Paused screenshots must be comparable: \(pixelComparison.summary)")
            XCTAssertEqual(
                pixelComparison.differingPixelCount, 0,
                "After pausing, the photo pixels outside the control bar and entry hint must stay frozen: \(pixelComparison.summary)"
            )
            appendManualLifecycleRuntimeEvidence(
                app: app, mode: .smartFill, event: "\(evidenceEventPrefix)-sample-\(sample)", probe: probe)
            let pixelsAttachment = XCTAttachment(data: pixels, uniformTypeIdentifier: "public.png")
            pixelsAttachment.name = "\(evidenceEventPrefix)-sample-\(sample)"
            pixelsAttachment.lifetime = .keepAlways
            add(pixelsAttachment)
        }
    }

    func sceneIdentity(app: XCUIApplication, mode: ManualLifecycleMode) throws -> String {
        if mode == .smartFill {
            return try waitForCompleteVisibleSmartFillScene(app: app, timeout: TestWait.seconds(.product(8)))
                .sceneIdentity
        }
        return try waitForCurrentAssetID(app: app, timeout: TestWait.seconds(.product(8)))
    }

    func waitForSceneIdentityChange(app: XCUIApplication, mode: ManualLifecycleMode, from oldValue: String) throws
        -> String
    {
        guard
            waitUntil(
                timeout: TestWait.seconds(.product(20)),
                condition: {
                    (try? self.sceneIdentity(app: app, mode: mode)).map { $0 != oldValue } ?? false
                })
        else {
            throw NSError(
                domain: "PlaybackHistoryIOSUITests", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "scene identity did not change"])
        }
        return try sceneIdentity(app: app, mode: mode)
    }

    func startRandomPlaybackFromModeSelection(app: XCUIApplication) {
        let randomButton = app.buttons["mode.random.button"]
        XCTAssertTrue(
            randomButton.waitForExistence(timeout: TestWait.seconds(.infrastructure(5))),
            "The mode selection page should show the Random Playback entry")
        tapElement(randomButton)

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: TestWait.seconds(.infrastructure(5))),
            "The mode selection page should show the Continue button")
        XCTAssertTrue(
            continueButton.isEnabled, "After choosing Random Playback, the Continue button should be tappable")
        tapElement(continueButton)

        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: TestWait.seconds(.infrastructure(25))),
            "After entering random playback, the playback control bar should be shown"
        )
    }

    func startFilteredPlaybackFromModeSelection(app: XCUIApplication) {
        let filteredButton = app.buttons["mode.filtered.button"]
        XCTAssertTrue(
            filteredButton.waitForExistence(timeout: TestWait.seconds(.infrastructure(5))),
            "The filtered-playback harness should show the Filtered Playback entry")
        tapElement(filteredButton)

        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: TestWait.seconds(.infrastructure(5))),
            "Filtered playback should show the Continue button")
        XCTAssertTrue(
            continueButton.isEnabled, "The Continue button in the filtered-playback harness should be tappable")
        tapElement(continueButton)

        let startButton = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(
            startButton.waitForExistence(timeout: TestWait.seconds(.infrastructure(12))),
            "The filtered playback summary should show the Start Playback button")
        // Starting before the page swaps in the real album and person would play an empty pool.
        let selectionReady = app.staticTexts["filterSummary.visual.ready"]
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.infrastructure(30))) {
                selectionReady.exists && selectionReady.label == "ready"
            },
            "The filter summary must select a real album and person before playback starts"
        )
        XCTAssertTrue(waitUntil(timeout: TestWait.seconds(.infrastructure(12))) { startButton.isEnabled })
        tapElement(startButton)

        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(
                timeout: TestWait.seconds(.infrastructure(45))),
            "The filtered-playback harness should reach the real playback control bar"
        )
    }

    func waitForCurrentAssetID(app: XCUIApplication, timeout: TimeInterval) throws -> String {
        guard waitUntil(timeout: timeout, condition: { self.currentAssetID(app: app) != nil }) else {
            let hierarchy = app.debugDescription
            let candidate = app.descendants(matching: .any)["slideshow.currentAssetId.flag"]
            let diagnostic = [
                "currentAssetProbe.exists=\(candidate.exists)",
                "currentAssetProbe.identifier=\(candidate.identifier)",
                "currentAssetProbe.label=\(candidate.label)",
                "MANUAL_LIFECYCLE_CURRENT_ASSET_HIERARCHY_BEGIN",
                hierarchy,
                "MANUAL_LIFECYCLE_CURRENT_ASSET_HIERARCHY_END"
            ].joined(separator: "\n")
            print(diagnostic)
            let attachment = XCTAttachment(data: Data(diagnostic.utf8), uniformTypeIdentifier: "public.plain-text")
            attachment.name = "manual-lifecycle-current-asset-probe-hierarchy"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail(
                "The slideshow must reliably expose slideshow.currentAssetId.flag in UI tests, EXIF panel or not."
            )
            throw NSError(
                domain: "PlaybackHistoryIOSUITests",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "missing slideshow.currentAssetId.flag"
                ]
            )
        }

        guard let assetID = currentAssetID(app: app) else {
            XCTFail("The slideshow asset ID probe disappeared; cannot read the current photo.")
            throw NSError(
                domain: "PlaybackHistoryIOSUITests",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "missing slideshow.currentAssetId.flag after initial detection"
                ]
            )
        }
        return assetID
    }

    func waitForCurrentAssetIDChange(app: XCUIApplication, from oldValue: String, timeout: TimeInterval) throws
        -> String
    {
        guard
            waitUntil(
                timeout: timeout,
                condition: {
                    guard let value = self.currentAssetID(app: app) else { return false }
                    return value != oldValue
                })
        else {
            XCTFail("After tapping next, the current photo ID did not change within \(Int(timeout)) seconds")
            return oldValue
        }

        return try waitForCurrentAssetID(app: app, timeout: TestWait.seconds(.product(2)))
    }

    func currentAssetID(app: XCUIApplication) -> String? {
        let probe = app.descendants(matching: .any)["slideshow.currentAssetId.flag"]
        guard probe.exists else { return nil }
        let label = probe.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty || label == "no-asset" ? nil : label
    }

    func waitForCompleteVisibleSmartFillScene(
        app: XCUIApplication,
        timeout: TimeInterval
    ) throws -> CompleteVisibleSmartFillScene {
        guard
            waitUntil(
                timeout: timeout,
                condition: {
                    self.currentCompleteVisibleSmartFillScene(app: app) != nil
                }), let scene = currentCompleteVisibleSmartFillScene(app: app)
        else {
            attachSmartFillProbeLabels(app: app, name: "smartfill-history-missing-complete-visible-probe")
            XCTFail(
                "SmartFill must expose the complete manifest, stable visible render state and history cursor together")
            throw NSError(
                domain: "PlaybackHistoryIOSUITests",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "missing complete visible SmartFill scene"]
            )
        }
        return scene
    }

    func waitForCompleteVisibleSmartFillSceneChange(
        app: XCUIApplication,
        from previousIdentity: String,
        timeout: TimeInterval
    ) throws -> CompleteVisibleSmartFillScene {
        guard
            waitUntil(
                timeout: timeout,
                condition: {
                    guard let scene = self.currentCompleteVisibleSmartFillScene(app: app) else { return false }
                    return scene.sceneIdentity != previousIdentity
                })
        else {
            attachSmartFillProbeLabels(app: app, name: "smartfill-history-next-identity-unchanged-probe")
            XCTFail(
                "After tapping next, the fully visible SmartFill scene identity did not change in \(Int(timeout)) s")
            throw NSError(
                domain: "PlaybackHistoryIOSUITests",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "complete visible SmartFill scene did not change"]
            )
        }
        return try waitForCompleteVisibleSmartFillScene(app: app, timeout: TestWait.seconds(.product(2)))
    }

    func currentCompleteVisibleSmartFillScene(app: XCUIApplication) -> CompleteVisibleSmartFillScene? {
        let manifestProbe = app.descendants(matching: .any)["slideshow.smartfill.currentManifest.flag"]
        let contractProbe = app.descendants(matching: .any)["slideshow.scenePresentation.contract.summary"]
        let historyProbe = app.descendants(matching: .any)["slideshow.historyLedger.summary.flag"]
        guard manifestProbe.exists,
            contractProbe.exists,
            historyProbe.exists
        else {
            return nil
        }

        let manifestFields = SharedSceneEvidenceManifest.parseKeyValueFields(manifestProbe.label)
        let contractFields = SharedSceneEvidenceManifest.parseKeyValueFields(contractProbe.label)
        guard
            SharedSceneEvidenceManifest.manifestObservation(from: manifestProbe.label)?.isCompleteVisibleScene == true,
            contractFields["phase"] == "stablePhoto",
            contractFields["layerRoles"] == "stable",
            contractFields["loadingVisible"] == "false",
            let sceneIdentity = manifestFields["ledgerSceneAssets"],
            sceneIdentity != "none",
            !sceneIdentity.isEmpty,
            let historyData = historyProbe.label.data(using: .utf8),
            let history = try? JSONSerialization.jsonObject(with: historyData) as? [String: Any],
            let cursor = history["cursor"] as? Int
        else {
            return nil
        }
        return CompleteVisibleSmartFillScene(sceneIdentity: sceneIdentity, historyCursor: cursor)
    }

    func attachSmartFillProbeLabels(app: XCUIApplication, name: String) {
        let identifiers = [
            "slideshow.smartfill.currentManifest.flag",
            "slideshow.scenePresentation.contract.summary",
            "slideshow.historyLedger.summary.flag"
        ]
        let labels = identifiers.map { identifier in
            let probe = app.descendants(matching: .any)[identifier]
            return "[\(identifier)] exists=\(probe.exists)\n\(probe.label)"
        }.joined(separator: "\n\n")
        let attachment = XCTAttachment(data: Data(labels.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "\(name)-screenshot"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func attachScreenshot(app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
            return
        }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    // Callers resolve the TestWait budget once; polling cadence stays fixed.
    func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.2))))
        }
        return condition()
    }

    func currentDeviceTag() -> String {
        switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            return "iphone"
        case .pad:
            return "ipad"
        default:
            return UIDevice.current.model.replacingOccurrences(of: " ", with: "_").lowercased()
        }
    }
}
#endif
