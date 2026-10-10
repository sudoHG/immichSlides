import XCTest

#if os(iOS)
extension StrictE2EFirstBatchIOSUITests {
    // launchStrictE2EApp clears launchEnvironment and rejects leftover UI_TEST_* keys. This pause-window
    // run needs exactly these five: server URL/key so first-boot is skipped, reset plus mode-selection to
    // reach a clean mode page, and the scene-presentation probe the outgoing-translucent check reads.
    @MainActor
    func launchOutgoingPauseWindowApp() throws -> XCUIApplication {
        let input = try requireStrictE2EInput()
        let app = XCUIApplication()
        app.launchEnvironment = [
            "UI_TEST_SERVER_URL": input.serverURL,
            "UI_TEST_API_KEY": input.publicKey,
            "UI_TEST_RESET_STATE": "1",
            "UI_TEST_FORCE_MODE_SELECTION": "1",
            "UI_TEST_SCENE_PRESENTATION_CONTRACT_PROBE": "1"
        ]
        let audit = try JSONSerialization.data(
            withJSONObject: ["launch_environment_keys": app.launchEnvironment.keys.sorted()],
            options: [.prettyPrinted, .sortedKeys]
        )
        let attachment = XCTAttachment(data: audit, uniformTypeIdentifier: "public.json")
        attachment.name = "pause-window-launch-environment-keys"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.launch()
        return app
    }

    @MainActor
    func pausePlaybackIfNeeded(app: XCUIApplication) {
        let playPause = app.buttons["slideshow.control.playPause.button"]
        guard playPause.waitForExistence(timeout: TestWait.seconds(.product(4))) else { return }
        if playPauseState(playPause) != "play" {
            tapElement(playPause)
        }
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(4))) { self.playPauseState(playPause) == "play" },
            "Pause before opening settings or identifying photos, so autoplay does not move away."
        )
    }

    // iPad sidebar handling is copied from PlaybackHistoryIOSUITests.openPlaybackSettingsFromSlideshow, into
    // this file only.
    @MainActor
    func openPlaybackSettingsFromSlideshow(app: XCUIApplication) {
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        XCTAssertTrue(settingsButton.exists && settingsButton.isHittable, "The settings button must be tappable.")
        tapElement(settingsButton)

        let playbackEntry: XCUIElement
        if UIDevice.current.userInterfaceIdiom == .pad {
            if app.switches["settings.playback.autoPlay.toggle"].waitForExistence(
                timeout: TestWait.seconds(.product(2)))
            {
                return
            }
            let sidebar = app.buttons["ToggleSidebar"]
            // ui-label-lookup: Check the simulator-owned navigation control's localized title before toggling it.
            if sidebar.exists && ["显示边栏", "Show Sidebar"].contains(sidebar.label) {
                tapElement(sidebar)
            }
            playbackEntry = app.descendants(matching: .any)["settings.item.playback"].firstMatch
        } else {
            playbackEntry = app.buttons["settings.item.playback"]
        }
        XCTAssertTrue(
            playbackEntry.waitForExistence(timeout: TestWait.seconds(.product(8))),
            "The settings list must offer the playback settings entry"
        )
        tapElement(playbackEntry)
    }

    @MainActor
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
            waitUntil(timeout: TestWait.seconds(.product(6))) {
                let settingsButton = app.buttons["slideshow.control.settings.button"]
                return settingsButton.exists && settingsButton.isHittable
            },
            "Could not return from playback settings to the playback page"
        )
    }

    @MainActor
    func selectSinglePhotoDisplayMode(app: XCUIApplication) {
        let picker = app.segmentedControls["settings.playback.displayMode.picker"]
        XCTAssertTrue(
            picker.waitForExistence(timeout: TestWait.seconds(.product(8))),
            "Playback settings must offer the display mode segmented control."
        )
        let singlePhoto = picker.buttons["settings.playback.displayMode.singlePhoto.option"]
        XCTAssertTrue(
            singlePhoto.waitForExistence(timeout: TestWait.seconds(.product(3))),
            "Display mode must offer single photo mode.")
        tapElement(singlePhoto)
        XCTAssertTrue(singlePhoto.exists, "The segmented control must remain after selecting single photo mode.")
        // ui-label-lookup: Preserve the Simplified Chinese display-mode copy assertion after identifier lookup.
        XCTAssertEqual(singlePhoto.label, "单图模式", "The display mode option must keep its Simplified Chinese copy.")
    }

    @MainActor
    func confirmExifOnAndFiveSecondInterval(app: XCUIApplication) {
        let exifToggle = app.switches["settings.playback.showExif.toggle"]
        XCTAssertTrue(
            exifToggle.waitForExistence(timeout: TestWait.seconds(.product(8))),
            "Playback settings must offer the EXIF toggle.")
        let toggleValue = ((exifToggle.value as? String) ?? "").lowercased()
        XCTAssertTrue(toggleValue == "1" || toggleValue == "true", "Show EXIF info must be on.")
        let intervalValue = app.staticTexts["settings.playback.interval.value"]
        // ui-label-lookup: Preserve the Simplified Chinese playback-interval copy assertion after identifier lookup.
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(3))) { intervalValue.exists && intervalValue.label == "5 秒" }
                || (intervalValue.exists && intervalValue.label.contains("5 秒")),
            "The playback interval must be 5 seconds."
        )
    }

    @MainActor
    func locateStableA2WithoutFixture3(app: XCUIApplication) throws {
        let next = app.buttons["slideshow.control.next.button"]
        let previous = app.buttons["slideshow.control.previous.button"]
        for step in 0...4 {
            revealPlaybackControlsWithoutWaitHelper(app: app)
            waitForSettledPhoto(app: app)
            let overlay = visibleExifOverlayText(app: app)
            let mark = classifyVisibleFixture(app: app)
            attachStrictE2EScreenshot(app: app, name: "find-a2-step-\(step)-\(mark)")
            let hasOddFixture =
                overlay.contains("Fixture 1") || overlay.contains("Fixture 3") || overlay.contains("Fixture 5")
            if hasOddFixture || mark == "A1" || mark == "A3" || mark == "A5" {
                tapElement(next)
                continue
            }
            let maybeA2 = mark == "A2" || (mark == "unknown" && !hasOddFixture)
            if maybeA2 {
                XCTAssertTrue(
                    next.waitForExistence(timeout: TestWait.seconds(.product(4))),
                    "After identifying A2, Next must be tappable to check its successor."
                )
                tapElement(next)
                waitForSettledPhoto(app: app)
                let successorOverlay = visibleExifOverlayText(app: app)
                let successor = classifyVisibleFixture(app: app)
                attachStrictE2EScreenshot(app: app, name: "a2-successor-\(successor)")
                let successorIsA3 = successor == "A3" || successorOverlay.contains("Fixture 3")
                if successor == "A4" || successor == "A5" || successorOverlay.contains("Fixture 5") {
                    if mark == "A2" {
                        attachVerdict([
                            "verdict": "PRECONDITION_FAIL",
                            "reason": "A2 successor is \(successor), not A3",
                            "visible_exif": successorOverlay,
                            "visible_mark": successor
                        ])
                        XCTFail("PRECONDITION_FAIL: order became A2→\(successor), not A2→A3.")
                        return
                    }
                    continue
                }
                if !successorIsA3 {
                    if mark == "A2" {
                        attachVerdict([
                            "verdict": "PRECONDITION_FAIL",
                            "reason": "A2 successor is not A3",
                            "visible_exif": successorOverlay,
                            "visible_mark": successor
                        ])
                        XCTFail("PRECONDITION_FAIL: A2 successor is not A3 (\(successor)).")
                        return
                    }
                    continue
                }
                revealPlaybackControlsWithoutWaitHelper(app: app)
                tapElement(previous)
                waitForSettledPhoto(app: app)
                let restoredOverlay = visibleExifOverlayText(app: app)
                let restored = classifyVisibleFixture(app: app)
                if restoredOverlay.contains("Fixture 3") || (restored != "A2" && restored != "unknown") {
                    attachVerdict([
                        "verdict": "PRECONDITION_FAIL",
                        "reason": "After returning from the successor, it is not an A2 without Fixture 3",
                        "visible_exif": restoredOverlay,
                        "visible_mark": restored
                    ])
                    XCTFail("PRECONDITION_FAIL: not the large-text A2 after returning.")
                    return
                }
                return
            }
            tapElement(next)
        }
        attachVerdict([
            "verdict": "PRECONDITION_FAIL",
            "reason": "Large-text A2 still not identified after four Next taps"
        ])
        XCTFail("PRECONDITION_FAIL: could not identify the large-text A2 using Next.")
    }

    @MainActor
    func revealPlaybackControlsWithoutWaitHelper(app: XCUIApplication, shouldRefreshAutoHideTimer: Bool = false) {
        let playPause = app.buttons["slideshow.control.playPause.button"]
        // A visible bar can be near expiry after an observation hold; refresh it before evidence reads.
        if !shouldRefreshAutoHideTimer && playPause.exists && playPause.isHittable { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        _ = waitUntil(timeout: TestWait.seconds(.product(4))) { playPause.exists }
    }

    @MainActor
    func waitForSettledPhoto(app: XCUIApplication) {
        _ = waitUntil(timeout: TestWait.seconds(.product(4))) {
            guard let state = self.probeState(from: self.contractProbeRaw(app: app)) else {
                return false
            }
            return state.phase == "stablePhoto"
        }
        RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.2))))
    }

    @MainActor
    func contractProbeRaw(app: XCUIApplication) -> String {
        probeRaw(app: app, identifier: "slideshow.scenePresentation.contract.summary")
    }

    @MainActor
    func frameSynchronizedProbeRaw(app: XCUIApplication) -> String {
        probeRaw(app: app, identifier: "slideshow.scenePresentation.frameSynchronized.summary")
    }

    @MainActor
    func probeRaw(app: XCUIApplication, identifier: String) -> String {
        let probe = app.descendants(matching: .any)[identifier]
        guard probe.exists else { return "" }
        return probe.label
    }

    struct PauseWindowProbeState {
        let phase: String
        let layerRoles: [String]
        let layerOpacities: [Double]
    }

    // Parsing copied from ScenePresentationContractUITests.probeState, keeping only the phase / roles /
    // opacities this test's HIT needs.
    func probeState(from label: String) -> PauseWindowProbeState? {
        let fields = probeFields(from: label)
        guard fields["schemaVersion"] == "scene-presentation-contract-probe-v1",
            let phase = fields["phase"]
        else {
            return nil
        }
        let roles = list(fields["layerRoles"])
        let opacities = list(fields["layerOpacities"]).compactMap(Double.init)
        return PauseWindowProbeState(phase: phase, layerRoles: roles, layerOpacities: opacities)
    }

    func probeFields(from label: String) -> [String: String] {
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

    func list(_ raw: String?) -> [String] {
        guard let raw, raw != "none", !raw.isEmpty else { return [] }
        return raw.split(separator: "|").map(String.init)
    }

    func isOutgoingOnlyPauseWindow(_ state: PauseWindowProbeState) -> Bool {
        guard state.phase == "transition" else { return false }
        guard state.layerRoles.count == state.layerOpacities.count else { return false }
        var isOutgoingFading = false
        var isIncomingHidden = false
        for (role, opacity) in zip(state.layerRoles, state.layerOpacities) {
            if role == "outgoing", opacity > 0, opacity < 1 {
                isOutgoingFading = true
            }
            if role == "incoming", opacity == 0 {
                isIncomingHidden = true
            }
        }
        return isOutgoingFading && isIncomingHidden
    }

    func layerOpacity(in state: PauseWindowProbeState, role: String) -> Double? {
        guard state.layerRoles.count == state.layerOpacities.count else { return nil }
        for (layerRole, opacity) in zip(state.layerRoles, state.layerOpacities) {
            if layerRole == role { return opacity }
        }
        return nil
    }

    // Positive condition after freezing: outgoing is still visible and incoming is still fully invisible.
    func isPostPauseProbePositive(_ raw: String) -> Bool {
        guard let state = probeState(from: raw),
            let outgoing = layerOpacity(in: state, role: "outgoing"), outgoing > 0,
            let incoming = layerOpacity(in: state, role: "incoming"), incoming == 0
        else {
            return false
        }
        return true
    }

    // Missing probe or outgoing at 0 means black/blank; 'no Fixture 3' alone must not count as a pass.
    func isPostPauseBlackOrBlank(_ raw: String) -> Bool {
        guard !raw.isEmpty, let state = probeState(from: raw) else {
            return true
        }
        guard let outgoing = layerOpacity(in: state, role: "outgoing") else {
            return true
        }
        return !(outgoing > 0)
    }

    @MainActor
    func visibleExifOverlayText(app: XCUIApplication) -> String {
        app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
    }

    @MainActor
    func classifyVisibleFixture(app: XCUIApplication) -> String {
        StrictE2EPhotoIdentity.classify(png: app.screenshot().pngRepresentation).mark ?? "unknown"
    }

    @MainActor
    func attachPauseWindowPNG(app: XCUIApplication, name: String) -> Bool {
        let png = app.screenshot().pngRepresentation
        guard !png.isEmpty else { return false }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return true
    }

    @MainActor
    func attachKeepAlwaysFrame(app: XCUIApplication, index: Int) -> Bool {
        attachPauseWindowPNG(app: app, name: String(format: "play-to-pause-frame-%03d", index))
    }

    func attachVerdict(_ payload: [String: Any]) {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            )
        else {
            return
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "verdict.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
