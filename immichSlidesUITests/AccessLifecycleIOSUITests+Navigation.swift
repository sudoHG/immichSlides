import CryptoKit
import XCTest

#if os(iOS)
extension AccessLifecycleIOSUITests {
    struct SceneCapture {
        let mark: String
        let png: Data
        let references: [String]
        let observation: [String: String]
    }

    @MainActor
    func sceneCaptureObservation(app: XCUIApplication) -> [String: String] {
        let snapshots = app.evidenceSnapshotsByIdentifier()
        return [
            "render": snapshots["slideshow.scenePresentation.frameSynchronized.summary"]?.label ?? "",
            "manifest": snapshots["slideshow.smartfill.currentManifest.flag"]?.label ?? "",
            "asset": snapshots["slideshow.currentAssetId.flag"]?.label ?? ""
        ]
    }

    func stableSceneReferences(
        in observation: [String: String], requiresSmartFillManifest: Bool, expectedPaused: Bool?
    ) -> [String]? {
        let render = SharedSceneEvidenceManifest.parseKeyValueFields(observation["render"] ?? "")
        guard render["phase"] == "stablePhoto", render["layerRoles"] == "stable",
            let opacity = Double(render["layerOpacities"] ?? ""), opacity == 1,
            render["partialSlotVisible"] == "false",
            render["loadingVisible"] == "false",
            let progress = Double(render["motionRawProgress"] ?? ""), (0...1).contains(progress),
            let paused = render["playbackPaused"], ["true", "false"].contains(paused),
            expectedPaused.map({ paused == String($0) }) ?? true
        else { return nil }
        if requiresSmartFillManifest {
            guard
                SharedSceneEvidenceManifest.manifestObservation(from: observation["manifest"] ?? "")?
                    .isCompleteVisibleScene == true
            else { return nil }
            let fields = SharedSceneEvidenceManifest.parseKeyValueFields(observation["manifest"] ?? "")
            let references = (fields["ledgerSceneAssets"] ?? "").split(separator: ",").map(String.init)
            let readiness = (fields["slotReadiness"] ?? "").split(separator: ",").map(String.init)
            guard let slotCount = Int(fields["slotCount"] ?? ""), references.count == slotCount,
                references.allSatisfy({ !$0.isEmpty && $0 != "none" }),
                readiness.count == slotCount, readiness.allSatisfy({ $0 == "ready" })
            else { return nil }
            return references
        }
        guard let asset = observation["asset"], !asset.isEmpty, asset != "no-asset" else { return nil }
        return [asset]
    }

    @MainActor
    func captureStableScene(
        app: XCUIApplication, name: String, deadline: Date,
        requiresSmartFillManifest: Bool = true, expectedPaused: Bool? = nil, shouldPersist: Bool = true
    ) throws -> SceneCapture? {
        var pending: (png: Data, references: [String], observation: [String: String])?
        var lastObservation: [String: String] = [:]
        var lastScreenshot: (png: Data, observation: [String: String])?
        while Date() < deadline {
            // One fallible snapshot per poll; consecutive polls bracket the screenshot with the drawn-frame probe.
            let observation = sceneCaptureObservation(app: app)
            lastObservation = observation
            let references = stableSceneReferences(
                in: observation, requiresSmartFillManifest: requiresSmartFillManifest, expectedPaused: expectedPaused)
            if let candidate = pending, let references, references == candidate.references {
                let before = SharedSceneEvidenceManifest.parseKeyValueFields(candidate.observation["manifest"] ?? "")
                let after = SharedSceneEvidenceManifest.parseKeyValueFields(observation["manifest"] ?? "")
                let beforeRender = SharedSceneEvidenceManifest.parseKeyValueFields(
                    candidate.observation["render"] ?? "")
                let afterRender = SharedSceneEvidenceManifest.parseKeyValueFields(observation["render"] ?? "")
                if beforeRender["layerIDs"] == afterRender["layerIDs"],
                    before["actionTimestamp"] == after["actionTimestamp"],
                    before["scenePublishTimestamp"] == after["scenePublishTimestamp"]
                {
                    let identity = StrictE2EPhotoIdentity.captureIdentity(png: candidate.png)
                    if identity.status == .match, let mark = identity.mark, !mark.isEmpty, Date() < deadline {
                        if shouldPersist {
                            try persistRequiredPNG(candidate.png, name: name)
                            try StrictE2EVisualEvidence.writeRequiredJSON(
                                ["before": candidate.observation, "after": observation], name: "\(name).scene.json")
                        }
                        return SceneCapture(
                            mark: mark, png: candidate.png, references: references, observation: observation)
                    }
                }
            }
            pending = nil
            if let references {
                let png = app.screenshotForFailureEvidence().pngRepresentation
                pending = (png, references, observation)
                lastScreenshot = (png, observation)
            } else {
                RunLoop.current.run(
                    until: min(deadline, Date().addingTimeInterval(TestWait.seconds(.product(0.4)))))
            }
        }
        // Failed windows retain diagnostics only; these files never provide verdict identity.
        let diagnosticPNG = lastScreenshot?.png ?? app.screenshotForFailureEvidence().pngRepresentation
        try? persistRequiredPNG(diagnosticPNG, name: "\(name).diagnostic")
        try? StrictE2EVisualEvidence.writeRequiredJSON(
            [
                "diagnosticOnly": true, "before": lastScreenshot?.observation ?? lastObservation,
                "after": lastObservation
            ], name: "\(name).diagnostic.scene.json")
        return nil
    }

    func failStableSceneCapture(
        _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> Never {
        XCTFail(message, file: file, line: line)
        throw AccessLifecycleContract.AssertionError.message(message)
    }

    @MainActor
    func launchApp() throws -> XCUIApplication {
        let app = XCUIApplication()
        try prepareLaunch(app)
        app.launchForFailureEvidence()
        return app
    }

    @MainActor
    func relaunchApp(_ app: XCUIApplication) throws {
        app.terminateForFailureEvidence()
        try prepareLaunch(app)
        app.launchForFailureEvidence()
    }

    @MainActor
    func prepareLaunch(_ app: XCUIApplication) throws {
        app.launchEnvironment = [
            AccessLifecycleContract.scenePresentationProbeKey: "1"
        ]
        try AccessLifecycleContract.assertNoForcedDisplayMode(app.launchEnvironment)
    }

    @MainActor
    func readSceneProgress(app: XCUIApplication) throws -> (value: Double, raw: String, source: String) {
        revealPlaybackControls(app: app)
        let contractProbe = app.descendants(matching: .any)["slideshow.scenePresentation.contract.summary"]
        if contractProbe.waitForFailureEvidence(timeout: TestWait.seconds(.product(4))),
            let parsed = progressValue(in: contractProbe.label)
        {
            return (parsed.value, parsed.raw, "slideshow.scenePresentation.contract.summary")
        }
        let motionSummary = app.descendants(matching: .any)["slideshow.smartfill.motionFrame.summary"]
        if motionSummary.waitForFailureEvidence(timeout: TestWait.seconds(.product(2))),
            let parsed = progressValue(in: motionSummary.label)
        {
            return (parsed.value, parsed.raw, "slideshow.smartfill.motionFrame.summary")
        }
        let firstFrame = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "slideshow.smartfill.motionFrame."))
            .firstMatch
        if firstFrame.exists, let parsed = progressValue(in: firstFrame.label) {
            return (parsed.value, parsed.raw, firstFrame.identifier)
        }
        throw AccessLifecycleContract.AssertionError.message("Progress must be measured")
    }

    func progressValue(in raw: String) -> (value: Double, raw: String)? {
        if let fromMotion = parseProgressField(raw) {
            return (fromMotion, raw)
        }
        if let fromContract = parseMotionRawProgress(raw) {
            return (fromContract, raw)
        }
        let rows = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        for row in rows where !row.contains("renderRole=outgoing") {
            if let value = parseProgressField(row) ?? parseMotionRawProgress(row) {
                return (value, row)
            }
        }
        return nil
    }

    func parseMotionRawProgress(_ raw: String) -> Double? {
        guard let range = raw.range(of: "motionRawProgress=") else { return nil }
        let token = String(raw[range.upperBound...]).split(separator: ";").first.map(String.init) ?? ""
        let parts = token.split(separator: "|").compactMap { Double($0) }
        return parts.last
    }

    func parseProgressField(_ raw: String) -> Double? {
        guard let range = raw.range(of: "progress=") else { return nil }
        let token = String(raw[range.upperBound...]).split(separator: ";").first.map(String.init) ?? ""
        if token.isEmpty || token == "missing" { return nil }
        return Double(token)
    }

    @MainActor
    func captureRequiredMark(
        app: XCUIApplication, name: String, requiresSmartFillManifest: Bool = true, expectedPaused: Bool? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> SceneCapture {
        try AccessLifecycleContract.assertIdentitySource("public_fixture_photo_mark")
        let deadline = Date().addingTimeInterval(TestWait.seconds(.product(4)))
        guard
            let capture = try captureStableScene(
                app: app, name: name, deadline: deadline, requiresSmartFillManifest: requiresSmartFillManifest,
                expectedPaused: expectedPaused)
        else {
            try failStableSceneCapture(
                "Screenshot \(name) cannot be used as identity: no complete stable capture window", file: file,
                line: line)
        }
        return capture
    }

    @MainActor
    func captureNewStableMark(
        app: XCUIApplication,
        name: String,
        timeout: TimeInterval,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> (mark: String, png: Data) {
        if shouldRequireStableSceneCaptures {
            return try captureNewStableSceneMark(app: app, name: name, timeout: timeout, file: file, line: line)
        }
        try AccessLifecycleContract.assertIdentitySource("public_fixture_photo_mark")
        let initialPNG = app.screenshotForFailureEvidence().pngRepresentation
        let initialMark = contractMark(StrictE2EPhotoIdentity.captureIdentity(png: initialPNG))
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                break
            }
            RunLoop.current.run(
                until: Date().addingTimeInterval(AccessLifecycleContract.pollWait(remaining: remaining))
            )
            let png = app.screenshotForFailureEvidence().pngRepresentation
            let identity = StrictE2EPhotoIdentity.captureIdentity(png: png)
            let mark = contractMark(identity)
            if identity.status == .match, !mark.isEmpty, mark != initialMark {
                let remainingForConfirm = deadline.timeIntervalSinceNow
                if remainingForConfirm <= 0 {
                    break
                }
                RunLoop.current.run(
                    until: Date().addingTimeInterval(
                        AccessLifecycleContract.confirmWait(remaining: remainingForConfirm)
                    )
                )
                let stablePNG = app.screenshotForFailureEvidence().pngRepresentation
                let stableIdentity = StrictE2EPhotoIdentity.captureIdentity(png: stablePNG)
                let stableMark = contractMark(stableIdentity)
                if AccessLifecycleContract.isConfirmedNewStableMark(
                    status: stableIdentity.status.rawValue,
                    mark: stableMark,
                    candidateMark: mark,
                    initialMark: initialMark,
                    meanLuma: stableIdentity.meanLuma
                ) {
                    try persistRequiredPNG(stablePNG, name: name)
                    return (stableMark, stablePNG)
                }
            }
        }
        throw AccessLifecycleContract.AssertionError.message(
            "No new stable frame appeared before going to the background")
    }

    @MainActor
    private func captureNewStableSceneMark(
        app: XCUIApplication, name: String, timeout: TimeInterval, file: StaticString, line: UInt
    ) throws -> (mark: String, png: Data) {
        try AccessLifecycleContract.assertIdentitySource("public_fixture_photo_mark")
        let deadline = Date().addingTimeInterval(timeout)
        guard
            let initial = try captureStableScene(
                app: app, name: name, deadline: deadline, shouldPersist: false)
        else {
            try failStableSceneCapture(
                "No new stable frame appeared before going to the background", file: file, line: line)
        }
        let initialMark = initial.mark
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                break
            }
            RunLoop.current.run(
                until: Date().addingTimeInterval(AccessLifecycleContract.pollWait(remaining: remaining))
            )
            guard
                let candidate = try captureStableScene(
                    app: app, name: name, deadline: deadline, shouldPersist: false)
            else { break }
            let mark = candidate.mark
            if mark != initialMark, candidate.references != initial.references {
                let remainingForConfirm = deadline.timeIntervalSinceNow
                if remainingForConfirm <= 0 {
                    break
                }
                RunLoop.current.run(
                    until: Date().addingTimeInterval(
                        AccessLifecycleContract.confirmWait(remaining: remainingForConfirm)
                    )
                )
                guard
                    let confirmed = try captureStableScene(
                        app: app, name: name, deadline: deadline, shouldPersist: false)
                else { break }
                let stablePNG = confirmed.png
                let stableIdentity = StrictE2EPhotoIdentity.captureIdentity(png: stablePNG)
                let stableMark = confirmed.mark
                if AccessLifecycleContract.isConfirmedNewStableMark(
                    status: stableIdentity.status.rawValue,
                    mark: stableMark,
                    candidateMark: mark,
                    initialMark: initialMark,
                    meanLuma: stableIdentity.meanLuma
                ), confirmed.references == candidate.references {
                    try persistRequiredPNG(stablePNG, name: name)
                    try StrictE2EVisualEvidence.writeRequiredJSON(
                        ["before": candidate.observation, "after": confirmed.observation], name: "\(name).scene.json")
                    return (stableMark, stablePNG)
                }
            }
        }
        try failStableSceneCapture(
            "No new stable frame appeared before going to the background", file: file, line: line)
    }

    @MainActor
    func captureRequiredPNG(app: XCUIApplication, name: String) throws -> Data {
        let png = app.screenshotForFailureEvidence().pngRepresentation
        try persistRequiredPNG(png, name: name)
        return png
    }

    @MainActor
    func persistRequiredPNG(_ png: Data, name: String) throws {
        XCTAssertFalse(png.isEmpty, "Screenshot must not be empty: \(name)")
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try StrictE2EVisualEvidence.writeRequiredPNG(png, name: name)
    }

    func contractMark(_ identity: StrictE2EPhotoIdentity.Result) -> String {
        if identity.status == .match, let mark = identity.mark {
            return mark
        }
        if identity.status == .black { return "BLACK" }
        if identity.status == .blank { return "BLANK" }
        return "UNRECOGNIZABLE"
    }

    func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func syntheticPIN() -> String {
        [2, 4, 6, 8, 0, 1].map(String.init).joined()
    }

    func wrongPIN() -> String {
        [1, 3, 5, 7, 9, 0].map(String.init).joined()
    }

    func deviceKind() -> String {
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    }

    @MainActor
    func enterPin(app: XCUIApplication, pin: String) {
        for digit in pin {
            let key = app.buttons["pinEntry.digit.\(digit).button"]
            XCTAssertTrue(
                key.waitForFailureEvidence(timeout: TestWait.seconds(.product(3))), "PIN digit key does not exist.")
            tapElement(key)
        }
    }

    @MainActor
    func tapSettingsPinInput(app: XCUIApplication, id: String) {
        let pinInputButton = app.buttons[id]
        let deadline = Date().addingTimeInterval(TestWait.seconds(.product(8)))
        let ready = waitUntil(timeout: TestWait.seconds(.product(8))) {
            self.dismissSystemSavePromptIfPresent(app: app, deadline: deadline)
            return pinInputButton.exists && pinInputButton.isHittable
                && !self.isSystemSavePasswordPromptVisible(app: app, deadline: deadline)
        }
        XCTAssertTrue(ready, "PIN input entry not found.")
        tapElement(pinInputButton)
    }

    @MainActor
    func openSettingsFromSlideshow(
        app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        // Read the successor within the entry observation allowance before callers query settings items.
        let deadline = Date().addingTimeInterval(TestWait.seconds(.product(15)))
        IOSDriver(app: app).openSettings(until: deadline, shouldAllowPINEntry: true, file: file, line: line)
    }

    @MainActor
    func returnToSlideshowFromSettings(app: XCUIApplication) {
        for _ in 0..<12 {
            if app.buttons["slideshow.control.settings.button"].exists,
                app.buttons["slideshow.control.settings.button"].isHittable
            {
                return
            }
            if !isOnSettingsSurface(app: app) {
                revealPlaybackControls(app: app)
                if app.buttons["slideshow.control.settings.button"].waitForPublicElement(
                    "slideshow.control.settings.button",
                    timeout: TestWait.seconds(.product(2)))
                {
                    return
                }
            }
            if app.buttons["pinEntry.close.button"].exists {
                tapElement(app.buttons["pinEntry.close.button"])
                RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.2))))
                continue
            }
            let globalBack = app.buttons["global.back.button"]
            if globalBack.exists && globalBack.isHittable {
                tapElement(globalBack)
                RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.3))))
                continue
            }
            let backButton =
                app.navigationBars.buttons.allElementsBoundByIndex.last { button in
                    button.exists && button.isHittable && button.identifier == "BackButton"
                }
                ?? app.navigationBars.buttons.allElementsBoundByIndex.last { button in
                    button.exists && button.isHittable && button.identifier != "ToggleSidebar"
                        // ui-label-lookup: System navigation supplies the sidebar button label.
                        && !["显示边栏", "隐藏边栏", "Show Sidebar", "Hide Sidebar"].contains(button.label)
                }
            if let backButton {
                tapElement(backButton)
                RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.3))))
                continue
            }
            app.swipeDownForFailureEvidence()
        }
        if app.buttons["slideshow.control.next.button"].exists {
            revealPlaybackControls(app: app)
        }
        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForPublicElement(
                "slideshow.control.settings.button",
                timeout: TestWait.seconds(.product(8))),
            "Must be able to return from settings to the playback page."
        )
    }

    @MainActor
    func openPlaybackSettings(app: XCUIApplication) {
        let toggle = playbackSwitch(app: app, identifier: "settings.playback.autoPlay.toggle")
        // This probe decides whether to navigate again; keep its observation window fixed.
        if toggle.waitForFailureEvidence(timeout: TestWait.seconds(.product(2))) {
            return
        }
        let sidebar = app.buttons["ToggleSidebar"]
        // ui-label-lookup: System navigation supplies the sidebar button label.
        if sidebar.exists && ["显示边栏", "Show Sidebar"].contains(sidebar.label) {
            tapElement(sidebar)
        }
        _ = app.descendants(matching: .any)["settings.item.playback"].waitForFailureEvidence(
            timeout: TestWait.seconds(.product(3)))
        let playbackButton = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            playbackButton.waitForPublicElement("settings.item.playback", timeout: TestWait.seconds(.product(8))),
            "The settings list must provide the playback settings entry")
        // A full-screen Toolbar swallows coordinate taps; use the element's tap() to activate via accessibility.
        playbackButton.tapForFailureEvidence()
        if !waitUntil(
            timeout: TestWait.seconds(.product(2)),
            condition: { toggle.exists || app.staticTexts["settings.playback.title"].exists })
        {
            app.cells.element(boundBy: 0).tapForFailureEvidence()
        }
        let opened = waitUntil(timeout: TestWait.seconds(.product(10))) {
            toggle.exists || app.staticTexts["settings.playback.title"].exists
        }
        if !opened {
            let png = app.screenshotForFailureEvidence().pngRepresentation
            try? StrictE2EVisualEvidence.writeRequiredPNG(png, name: "settings-open-debug")
            if let directory = StrictE2EVisualEvidence.directory() {
                try? app.debugDescription.write(
                    to: directory.appendingPathComponent("settings-open-debug.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
        XCTAssertTrue(
            opened,
            "After opening playback settings, the autoplay toggle or the playback settings title must be visible.")
    }

    @MainActor
    func settingsControl(app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    // In the iPad split view, List(selection)+Label is not always a Button; same query set as FilterSummary.
    @MainActor
    func settingsItemCandidates(
        app: XCUIApplication,
        identifier: String
    ) -> [XCUIElement] {
        [
            app.buttons[identifier],
            app.staticTexts[identifier],
            app.otherElements[identifier],
            settingsControl(app: app, identifier: identifier)
        ]
    }

    @MainActor
    func firstExistingSettingsItem(
        app: XCUIApplication,
        identifier: String
    ) -> XCUIElement? {
        settingsItemCandidates(app: app, identifier: identifier)
            .first(where: \.exists)
    }

    @MainActor
    func isOnSettingsSurface(app: XCUIApplication) -> Bool {
        let identifiers = [
            "settings.item.playback", "settings.playback.title", "settings.accessProtection.title",
            "settings.server.title", "settings.cache.title", "settings.about.title",
            "settings.about.opensource.page"
        ]
        if identifiers.contains(where: { settingsControl(app: app, identifier: $0).exists }) {
            return true
        }
        return app.buttons["settings.item.playback"].exists
            || app.buttons["settings.pin.enable.button"].exists
            || app.buttons["settings.pin.disable.button"].exists
            || settingsControl(app: app, identifier: "settings.playback.autoPlay.toggle").exists
    }

    @MainActor
    func openSettingsSection(app: XCUIApplication, sectionID: String) {
        let sidebar = app.buttons["ToggleSidebar"]
        // ui-label-lookup: System navigation supplies the sidebar button label.
        if sidebar.exists && (sidebar.label == "显示边栏" || sidebar.label == "Show Sidebar") {
            sidebar.tapForFailureEvidence()
        }
        // While the Save Password prompt covers the screen the hit point is {-1,-1}; tap "Not Now" first,
        // then Access Protection.
        // Preserve the old 20 attempts: each already allowed a 2 s decline readback and a 0.3 s poll.
        let deadline = Date().addingTimeInterval(TestWait.seconds(.product(20 * (2 + 0.3))))
        for attempt in 0..<20 where Date() < deadline {
            let isPromptGone = IOSFirstBootNavigation(app: app).dismissPasswordPrompt(until: deadline)
            if let candidate = firstExistingSettingsItem(
                app: app,
                identifier: sectionID
            ), isPromptGone, Date() < deadline {
                tapElement(candidate)
                return
            }
            if !isPromptGone || settingsControl(app: app, identifier: sectionID).exists {
                RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(TestWait.seconds(.product(0.3)))))
                continue
            }
            if attempt % 2 == 0 {
                app.swipeUpForFailureEvidence()
            } else {
                app.swipeDownForFailureEvidence()
            }
        }
        XCTFail("Settings item not found: \(sectionID)")
    }

    // Judge by play/pause being really hittable; a leftover settings button that still exists is not the control bar.
    @MainActor
    func revealPlaybackControls(app: XCUIApplication) {
        let playPause = playPauseButton(app)
        let settingsExists = app.buttons["slideshow.control.settings.button"].exists
        if AccessLifecycleContract.isPlaybackControlBarRevealed(
            isPlayPauseHittable: playPause.exists && playPause.isHittable
        ) {
            return
        }
        XCTAssertNoThrow(
            try AccessLifecycleContract.assertPlaybackControlsRevealedByTarget(
                isPlayPauseHittable: playPause.exists && playPause.isHittable,
                isSettingsPresent: settingsExists,
                isTreatedAsRevealed: false
            )
        )
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tapForFailureEvidence()
        _ = waitUntil(timeout: TestWait.seconds(.product(3))) {
            let button = self.playPauseButton(app)
            return button.exists && button.isHittable
        }
    }

    // Arriving at playback checks only exists; do not tap the screen or the hint, so XCTest does not wait
    // about 60 s for Ken Burns to go idle.
    @MainActor
    func waitForPlaybackControls(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        return waitUntil(timeout: timeout) {
            self.dismissSystemSavePromptIfPresent(app: app, deadline: deadline)
            return AccessLifecycleContract.hasPlaybackPageArrived(
                isSettingsPresent: app.buttons["slideshow.control.settings.button"].exists,
                isNextPresent: app.buttons["slideshow.control.next.button"].exists,
                isPlayPausePresent: self.playPauseButton(app).exists,
                isHintPresent: app.descendants(matching: .any)["slideshow.entryHint.banner"].exists
            )
        }
    }

    @MainActor
    func fillFirstBootForm(app: XCUIApplication, input: StrictE2EInput) throws {
        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(
            serverField.waitForPublicElement(
                "firstboot.serverURL.field", timeout: TestWait.seconds(.infrastructure(20))),
            "A fresh install must reach the normal first-boot page.")
        replaceText(in: serverField, with: input.serverURL)
        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(
            apiKeyField.waitForPublicElement("firstboot.apiKey.field", timeout: TestWait.seconds(.infrastructure(8))),
            "The first-boot page must show the API Key field.")
        replaceText(in: apiKeyField, with: input.publicKey)
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(3))) { self.hasSecureFieldEnteredValue(apiKeyField) },
            "The API Key must be entered into the secure field.")
        commitFocusedInputIfNeeded(app: app)
    }

    @MainActor
    func tapTestConnection(app: XCUIApplication) {
        let testConnectionButton = firstBootControl(
            in: app,
            identifier: "firstboot.testConnection.button"
        )
        XCTAssertTrue(
            testConnectionButton.waitForPublicElement(
                "firstboot.testConnection.button", timeout: TestWait.seconds(.infrastructure(8))),
            "Test Connection must be shown")
        tapElement(testConnectionButton)
    }

    @MainActor
    func waitForSaveEnabled(
        app: XCUIApplication, saveButton: XCUIElement, timeout: TimeInterval,
        file: StaticString = #filePath, line: UInt = #line
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            acceptLocalNetworkPermissionIfNeeded()
            if saveButton.exists && saveButton.isEnabled { return true }
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            let alert = app.alerts.firstMatch
            if alert.exists {
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                let details = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
                XCTFail("Connection test showed a failure alert: \(alert.label) | \(details)", file: file, line: line)
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.2))))
        }
        return saveButton.exists && saveButton.isEnabled
    }

    func acceptLocalNetworkPermissionIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // ui-label-lookup: The local-network permission alert belongs to iOS.
        for label in ["允许", "Allow"] {
            // ui-label-lookup: The permission action belongs to SpringBoard.
            let button = springboard.alerts.buttons[label]
            if button.exists {
                button.tapForFailureEvidence()
                return
            }
        }
    }

    @MainActor
    func firstBootControl(in app: XCUIApplication, identifier: String) -> XCUIElement {
        let button = app.buttons[identifier]
        if button.exists { return button }
        return app.descendants(matching: .any)[identifier]
    }

    @MainActor
    func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tapForFailureEvidence()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tapForFailureEvidence()
        }
    }

    @MainActor
    func replaceText(in field: XCUIElement, with value: String) {
        field.tapForFailureEvidence()
        let existingValue = field.value as? String ?? ""
        let looksLikePlaceholder =
            existingValue.contains("请输入") || existingValue.localizedCaseInsensitiveContains("enter")
        if !existingValue.isEmpty && !looksLikePlaceholder {
            field.typeKey("a", modifierFlags: .command)
            field.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        }
        field.typeForFailureEvidence(value)
    }

    @MainActor
    func hasSecureFieldEnteredValue(_ field: XCUIElement) -> Bool {
        let value = field.value as? String ?? ""
        return !value.isEmpty && !value.contains("请输入") && !value.localizedCaseInsensitiveContains("api key")
    }

    @MainActor
    func commitFocusedInputIfNeeded(app: XCUIApplication) {
        let done = app.buttons["server.keyboard.done.button"]
        if done.exists && done.isHittable {
            done.tapForFailureEvidence()
            return
        }
        // ui-label-lookup: System keyboard submit keys follow the simulator language.
        for label in ["完成", "Done", "next", "Next"] {
            // ui-label-lookup: System keyboard submit keys follow the simulator language.
            let button = app.keyboards.buttons[label]
            if button.exists && button.isHittable {
                button.tapForFailureEvidence()
                return
            }
        }
    }

    @MainActor
    func findFirstExistingIdentifiedText(in app: XCUIApplication, identifiers: [String], timeout: TimeInterval)
        -> XCUIElement?
    {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for identifier in identifiers {
                let text = app.staticTexts[identifier]
                if text.exists { return text }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.1))))
        }
        return nil
    }

    @MainActor
    func isToggleOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? String) == "1"
    }
}
#endif
