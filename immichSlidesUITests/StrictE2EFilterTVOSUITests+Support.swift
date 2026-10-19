import XCTest

#if os(tvOS)
extension StrictE2EFilterTVOSUITests {
    @MainActor
    func assertTVOSDefaultMode(app: XCUIApplication, expected: String) throws {
        let modeLink = app.buttons["settings.playback.mode.link"]
        XCTAssertTrue(
            modeLink.waitForFailureEvidence(timeout: TestWait.seconds(.product(8))),
            "The real playback settings screen must offer the default mode entry"
        )
        moveFocusTo(modeLink, directions: [.up, .down], message: "Focus must be able to reach the default mode entry")
        XCTAssertTrue(modeLink.hasFocus, "The default mode entry must actually receive remote focus")
        FirstFailureRemote.press(.select)
        let random = app.buttons["settings.playback.mode.random.button"]
        let filtered = app.buttons["settings.playback.mode.filtered.button"]
        XCTAssertTrue(
            random.waitForFailureEvidence(timeout: TestWait.seconds(.product(8))),
            "The default mode screen must offer Random Playback")
        XCTAssertTrue(
            filtered.waitForFailureEvidence(timeout: TestWait.seconds(.product(8))),
            "The default mode screen must offer Filtered Playback")
        let expectedButton = expected == "filtered" ? filtered : random
        let unexpectedButton = expected == "filtered" ? random : filtered
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(5))) {
                String(describing: expectedButton.value ?? "").contains("已选中")
            },
            "Default mode must show \(expected) as selected"
        )
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(5))) {
                String(describing: unexpectedButton.value ?? "").contains("未选中")
            },
            "The other default mode must show as not selected"
        )
        try writeScreenshotPNG(
            app: app,
            name: "album-edit-switch-mode-\(expected)",
            attachmentName: "album-edit-switch-mode-\(expected)"
        )
        FirstFailureRemote.press(.menu)
        XCTAssertTrue(
            modeLink.waitForFailureEvidence(timeout: TestWait.seconds(.product(8))),
            "Going back from the default mode screen must return to playback settings")
    }

    @MainActor
    func isolatePersonSelection(app: XCUIApplication, keeping personID: String) {
        let knownIDs = [
            "person-a-normal", "person-a-solo", "person-a-other", "person-a-no-faces",
            "person-b-normal", "person-b-solo", "person-b-other", "person-b-no-faces"
        ]
        for otherID in knownIDs where otherID != personID {
            let other = app.buttons["personFilter.person.\(otherID).button"]
            guard other.exists else { continue }
            moveFocusTo(
                other, directions: [.down, .right, .left, .up],
                message: "Focus must be able to move to the person to deselect.")
            let value = String(describing: other.value ?? "")
            if value.contains("已选中") || value.contains("单人") {
                FirstFailureRemote.press(.select)
                RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.4))))
            }
            let after = String(describing: other.value ?? "")
            XCTAssertFalse(
                after.contains("已选中") || after.contains("单人"),
                "Other people must be deselected before selecting the target person: \(otherID)"
            )
        }
    }

    @MainActor
    func focusAndConfigurePerson(app: XCUIApplication, personID: String, isSoloOnly: Bool) throws {
        let button = app.buttons["personFilter.person.\(personID).button"]
        XCTAssertTrue(
            button.waitForFailureEvidence(timeout: TestWait.seconds(.infrastructure(15))),
            "The people list must show \(personID).")
        isolatePersonSelection(app: app, keeping: personID)
        moveFocusTo(button, directions: [.down, .right, .left], message: "Focus must land on the target person.")
        attachScreenshot(app: app, name: "tvos-filter-person-\(personID)-focused")
        let fixturePrefix = personID.split(separator: "-").prefix(2).joined(separator: "-")
        let neighborIDs = ["normal", "solo", "other", "no-faces"]
            .map { "\(fixturePrefix)-\($0)" }
            .filter { $0 != personID }
        if let neighborID = neighborIDs.first {
            assertNoFocusCollision(
                focused: button,
                neighbor: app.buttons["personFilter.person.\(neighborID).button"]
            )
        }
        let value = String(describing: button.value ?? "")
        if isSoloOnly {
            if !value.contains("单人") {
                FirstFailureRemote.press(.playPause)
                RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.4))))
            }
        } else if !value.contains("已选中") {
            FirstFailureRemote.press(.select)
        }
    }

    @MainActor
    func capturePausedPlaybackPNGs(
        app: XCUIApplication, names: [String], stableFrameDeadline: Date? = nil
    ) throws {
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(
            playPauseButton.waitForPublicElement(
                "slideshow.control.playPause.button", timeout: TestWait.seconds(.product(30))),
            "Start Playback must open the playback screen.")
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        if settingsButton.waitForPublicElement(
            "slideshow.control.settings.button", timeout: TestWait.seconds(.product(6))),
            waitForFocus(on: settingsButton, timeout: TestWait.seconds(.product(3)))
        {
            moveFocus(
                .right, to: playPauseButton, maximumPresses: 3, message: "Focus must be able to move to Play/Pause.")
        }
        ensureControlBarVisible(app: app)
        moveFocusTo(
            playPauseButton, directions: [.left, .right],
            message: "Focus must be able to move to Play/Pause.")
        let playingValue = String(describing: playPauseButton.value ?? "")
        var readyMark: String?
        var readyFrame: StablePersonFrame?
        if playingValue.contains("暂停") || playingValue.lowercased().contains("pause") {
            moveFocusTo(
                playPauseButton, directions: [.left, .right],
                message: "Focus must be able to move to Play/Pause.")
            if let stableFrameDeadline {
                readyFrame = try requireFocusedStablePersonFrame(
                    app: app, deadline: stableFrameDeadline, name: names[0])
            }
            FirstFailureRemote.press(.select)
            readyMark = readyFrame?.mark
        }
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(4))) {
                let current = String(describing: playPauseButton.value ?? "")
                return current.contains("播放") || current.lowercased() == "play"
            }, "Playback must be paused before sampling candidates.")
        if let readyFrame {
            attachStrictSceneObservation(
                before: readyFrame.before, after: readyFrame.after, name: "\(names[0])-before-pause")
            let attachment = XCTAttachment(data: readyFrame.png, uniformTypeIdentifier: "public.png")
            attachment.name = "\(names[0])-before-pause"
            attachment.lifetime = .keepAlways
            add(attachment)
            try StrictE2EVisualEvidence.writeRequiredJSON(
                [
                    "proof_duration_seconds": readyFrame.durationSeconds,
                    "proof_attempts": readyFrame.attempts, "refocus_count": readyFrame.refocusCount,
                    "entry_hint_visible": readyFrame.isEntryHintVisible,
                    "select_focus": "slideshow.control.playPause.button"
                ],
                name: "\(names[0])-pause-readiness.json")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.playbackSceneSettleSeconds))

        let nextButton = app.buttons["slideshow.control.next.button"]
        for (index, name) in names.enumerated() {
            ensureControlBarVisible(app: app)
            let png = app.screenshotForFailureEvidence().pngRepresentation
            if index == 0, let readyMark {
                let identity = StrictE2EPhotoIdentity.captureIdentity(png: png)
                XCTAssertTrue(
                    identity.status == .match && identity.mark == readyMark,
                    "Visual ID failed \(name): paused frame must retain the stable readable scene")
            }
            try writeScreenshotPNG(app: app, name: name, attachmentName: name, capturedPNG: png)
            if index + 1 < names.count {
                ensureControlBarVisible(app: app)
                moveFocus(.right, to: nextButton, maximumPresses: 3, message: "Focus must be able to move to Next.")
                FirstFailureRemote.press(.select)
                RunLoop.current.run(until: Date().addingTimeInterval(Timing.playbackSceneSettleSeconds))
            }
        }
    }

    private struct StablePersonFrame {
        let mark: String
        let png: Data
        let before: [String: String]
        let after: [String: String]
        var durationSeconds: TimeInterval = .zero
        var attempts: Int = 0
        var refocusCount: Int = 0
        var isEntryHintVisible: Bool = false
    }

    @MainActor
    private func requireFocusedStablePersonFrame(
        app: XCUIApplication, deadline: Date, name: String
    ) throws -> StablePersonFrame {
        let startedAt = Date()
        FirstFailureContext.beginWait(seconds: max(0, deadline.timeIntervalSinceNow))
        defer { FirstFailureContext.endWait() }
        var attempts = 0
        var refocusCount = 0
        while Date() < deadline {
            var frame = try requireStablePersonFrame(app: app, deadline: deadline, name: name)
            attempts += frame.attempts
            let controls = app.evidenceSnapshotsByIdentifier()
            if controls["slideshow.control.playPause.button"]?.hasFocus == true, Date() < deadline {
                frame.durationSeconds = Date().timeIntervalSince(startedAt)
                frame.attempts = attempts
                frame.refocusCount = refocusCount
                frame.isEntryHintVisible = controls["slideshow.entryHint.banner"] != nil
                return frame
            }
            guard Date() < deadline else { break }
            ensureControlBarVisible(app: app, deadline: deadline)
            moveFocusTo(
                app.buttons["slideshow.control.playPause.button"], directions: [.left, .right],
                message: "Focus must be able to move to Play/Pause.", deadline: deadline)
            refocusCount += 1
            // Revealing controls consumed time; prove the frame again within the same deadline.
        }
        throw StrictE2EPhotoIdentity.AssertionError.message(
            "Visual ID failed \(name): no stable readable frame before Pause")
    }

    @MainActor
    private func requireStablePersonFrame(app: XCUIApplication, deadline: Date, name: String) throws
        -> StablePersonFrame
    {
        #if !DEBUG
        var previousMark: String?
        #endif
        var attempts = 0
        while Date() < deadline {
            attempts += 1
            let before = strictSceneFrameObservation(app: app)
            let png = app.screenshotForFailureEvidence().pngRepresentation
            let after = strictSceneFrameObservation(app: app)
            let identity = StrictE2EPhotoIdentity.captureIdentity(png: png)
            let beforeRefs = SharedSceneEvidenceManifest.parseKeyValueFields(before["manifest"] ?? "")[
                "ledgerSceneAssets"]
            let afterRefs = SharedSceneEvidenceManifest.parseKeyValueFields(after["manifest"] ?? "")[
                "ledgerSceneAssets"]
            #if DEBUG
            let isStable =
                StrictE2ESceneCapture.isStableWindow(before)
                && StrictE2ESceneCapture.isStableWindow(after) && beforeRefs != nil && beforeRefs == afterRefs
            #else
            // Consecutive readable identities cannot prove full opacity; Release has no scene probes.
            let isStable = previousMark == identity.mark
            #endif
            if isStable, identity.status == .match, let mark = identity.mark {
                guard Date() < deadline else { break }
                return StablePersonFrame(mark: mark, png: png, before: before, after: after, attempts: attempts)
            }
            #if !DEBUG
            previousMark = identity.status == .match ? identity.mark : nil
            #endif
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(Timing.focusPollingSeconds)))
        }
        throw StrictE2EPhotoIdentity.AssertionError.message(
            "Visual ID failed \(name): no stable readable frame before Pause")
    }

    @MainActor
    func changeServer(app: XCUIApplication, url: String, publicKey: String) throws {
        let playPauseButton = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(
            playPauseButton.waitForPublicElement(
                "slideshow.control.playPause.button", timeout: TestWait.seconds(.product(20))),
            "The playback screen must be open before switching servers.")
        ensureControlBarVisible(app: app)
        let settingsButton = app.buttons["slideshow.control.settings.button"]
        moveFocus(
            .left, to: settingsButton, maximumPresses: 4,
            message: "Focus on the playback control bar must be able to move to Settings.")
        FirstFailureRemote.press(.select)
        let serverItem = app.buttons["settings.item.server"]
        XCTAssertTrue(
            serverItem.waitForFailureEvidence(timeout: TestWait.seconds(.product(8))),
            "The settings screen must show the server entry.")
        moveFocusTo(serverItem, directions: [.down], message: "Focus must be able to move to server settings.")
        FirstFailureRemote.press(.select)

        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(
            serverField.waitForPublicElement("firstboot.serverURL.field", timeout: TestWait.seconds(.product(8))),
            "Server settings must show the URL field.")
        moveFocusTo(serverField, directions: [.up, .down], message: "Focus must land on the server URL.")
        replaceFocusedText(in: serverField, app: app, with: url)

        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(
            apiKeyField.waitForPublicElement("firstboot.apiKey.field", timeout: TestWait.seconds(.product(8))),
            "Server settings must show the API Key.")
        moveFocus(.down, to: apiKeyField, maximumPresses: 2, message: "Focus must be able to move down to the API Key.")
        replaceFocusedText(in: apiKeyField, app: app, with: publicKey)

        let testConnectionButton = firstBootControl(
            in: app,
            identifier: "firstboot.testConnection.button"
        )
        moveFocusTo(
            testConnectionButton, directions: [.down, .right], message: "Focus must be able to move to Test Connection."
        )
        FirstFailureRemote.press(.select)
        waitForTVOSServerConnectionSuccess(
            app: app,
            timeout: TestWait.seconds(.infrastructure(45)),
            message: "After switching to server B, the existing tvOS success copy must be shown."
        )

        let saveButton = firstBootControl(
            in: app,
            identifier: "firstboot.saveConfig.button"
        )
        XCTAssertTrue(
            saveButton.waitForFailureEvidence(timeout: TestWait.seconds(.infrastructure(5))) && saveButton.isEnabled,
            "After a successful connection, the configuration must be savable.")
        moveFocusTo(saveButton, directions: [.down, .right], message: "Focus must be able to move to Save Settings.")
        FirstFailureRemote.press(.select)
        let saveFeedback = app.descendants(matching: .any)["settings.server.feedback.save.success"]
        let saveFeedbackText = app.staticTexts["settings.server.feedback.save.success"]
        XCTAssertTrue(
            saveFeedback.waitForFailureEvidence(timeout: TestWait.seconds(.product(20)))
                || saveFeedbackText.waitForFailureEvidence(timeout: TestWait.seconds(.product(2))),
            "Saving server B must show save success."
        )
    }

    @MainActor
    func configureServerThroughFirstBoot(app: XCUIApplication, input: StrictE2EInput) throws {
        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(
            serverField.waitForPublicElement(
                "firstboot.serverURL.field", timeout: TestWait.seconds(.infrastructure(12))),
            "A clean install must open the first-launch form.")
        replaceFocusedText(in: serverField, app: app, with: input.serverURL)

        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(
            apiKeyField.waitForPublicElement("firstboot.apiKey.field", timeout: TestWait.seconds(.infrastructure(8))),
            "The first-launch form must show the API Key field.")
        moveFocus(
            .down, to: apiKeyField, maximumPresses: 2,
            message: "After submitting the URL, focus must be able to move down to the API Key.")
        replaceFocusedText(in: apiKeyField, app: app, with: input.publicKey)

        let testConnectionButton = firstBootControl(
            in: app,
            identifier: "firstboot.testConnection.button"
        )
        XCTAssertTrue(
            testConnectionButton.waitForFailureEvidence(timeout: TestWait.seconds(.infrastructure(5))),
            "The first-launch form must show the Test Connection button.")
        FirstFailureRemote.press(.down)
        FirstFailureRemote.press(.right)
        attachFocusAudit(app: app, name: "tvos-filter-firstboot-before-test-connection")
        FirstFailureRemote.press(.select)
        XCTAssertTrue(
            app.staticTexts["firstboot.connection.success"].waitForFailureEvidence(
                timeout: TestWait.seconds(.infrastructure(45))),
            "Once the real controlled server is reachable, connection test passed must be shown.")

        let saveButton = firstBootControl(
            in: app,
            identifier: "firstboot.saveConfig.button"
        )
        XCTAssertTrue(
            saveButton.waitForFailureEvidence(timeout: TestWait.seconds(.infrastructure(5))) && saveButton.isEnabled,
            "Save Settings must be enabled after a successful connection.")
        FirstFailureRemote.press(.select)
    }

    @MainActor
    func replaceFocusedText(in field: XCUIElement, app: XCUIApplication, with value: String) {
        XCTAssertTrue(
            waitForFocus(on: field, timeout: TestWait.seconds(.product(4))), "The field must be focused before typing.")
        FirstFailureRemote.press(.select)
        if let existing = field.value as? String, !existing.isEmpty {
            app.typeForFailureEvidence(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count + 8))
        }
        app.typeForFailureEvidence(value)

        let submit = app.buttons.matching(
            // ui-label-lookup: Match the simulator-localized system keyboard submit key.
            NSPredicate(format: "label IN %@", ["下一项", "Next", "完成", "Done"])
        ).firstMatch
        XCTAssertTrue(
            submit.waitForFailureEvidence(timeout: TestWait.seconds(.product(4))),
            "The system keyboard must show Next or Done.")
        for _ in 0..<6 where !submit.hasFocus {
            FirstFailureRemote.press(.down)
        }
        XCTAssertTrue(submit.hasFocus, "The system keyboard's submit button must be focused before submitting text.")
        FirstFailureRemote.press(.select)
        FirstFailureRemote.press(.menu)
        XCTAssertTrue(
            waitForFocus(on: field, timeout: TestWait.seconds(.product(4))),
            "After submitting text, focus must return to the original field.")
    }

    // Observe identifiable system focus before sending another direction key.
    @MainActor
    func moveFocus(
        _ direction: XCUIRemote.Button,
        to element: XCUIElement,
        maximumPresses: Int,
        message: String
    ) {
        for _ in 0..<maximumPresses {
            if (try? element.snapshot())?.hasFocus == true { return }
            _ = pressAndWaitForFocusMovement(direction, to: element)
        }
        XCTAssertTrue(waitForFocus(on: element, timeout: TestWait.seconds(.product(4))), message)
    }

    @MainActor
    func moveFocusTo(
        _ element: XCUIElement, directions: [XCUIRemote.Button], message: String, deadline: Date? = nil
    ) {
        if (try? element.snapshot())?.hasFocus == true { return }
        for direction in directions {
            for _ in 0..<4 {
                if let deadline, Date() >= deadline { break }
                if (try? element.snapshot())?.hasFocus == true { return }
                let timeout = min(Timing.focusObservationWindowSeconds, deadline?.timeIntervalSinceNow ?? .infinity)
                guard timeout > 0 else { break }
                if pressAndWaitForFocusMovement(direction, to: element, timeout: timeout) == false { break }
            }
        }
        let timeout = min(
            TestWait.seconds(.product(4)), max(TimeInterval.zero, deadline?.timeIntervalSinceNow ?? .infinity))
        XCTAssertTrue(waitForFocus(on: element, timeout: timeout), message)
    }

    @MainActor
    private func pressAndWaitForFocusMovement(
        _ direction: XCUIRemote.Button, to target: XCUIElement,
        timeout: TimeInterval = Timing.focusObservationWindowSeconds
    ) -> Bool? {
        let identifier = (try? target.snapshot())?.identifier
        return XCUIApplication().pressAndWaitForTVOSFocusMovement(
            direction, to: identifier, timeout: timeout)
    }

    @MainActor
    func waitForFocus(on element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? element.snapshot())?.hasFocus == true { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusPollingSeconds))
        }
        return (try? element.snapshot())?.hasFocus == true
    }

    @MainActor
    func ensureControlBarVisible(app: XCUIApplication, deadline: Date? = nil) {
        let timeout = min(
            TestWait.seconds(.product(5)), max(TimeInterval.zero, deadline?.timeIntervalSinceNow ?? .infinity))
        XCTAssertTrue(
            app.refreshTVOSSlideshowControlBar(timeout: timeout),
            "A direction key must bring up the playback control bar.")
    }

    @MainActor
    func waitForTVOSServerConnectionSuccess(
        app: XCUIApplication,
        timeout: TimeInterval,
        message: String
    ) {
        let successCopy = "服务器连接已验证"
        let hero = app.descendants(matching: .any)["settings.server.hero.summary"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if hero.exists {
                let text = hero.label + String(describing: hero.value ?? "")
                // ui-label-lookup: Preserve the Simplified Chinese connection-status copy check after identifier lookup.
                if text.contains(successCopy) { return }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusPollingSeconds))
        }
        let observedText = hero.label + String(describing: hero.value ?? "")
        // ui-label-lookup: Preserve the Simplified Chinese connection-status copy assertion after identifier lookup.
        XCTAssertTrue(hero.exists && observedText.contains(successCopy), message)
    }

    @MainActor
    func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusPollingSeconds))
        }
        return condition()
    }

    @MainActor
    func writeScreenshotPNG(app: XCUIApplication, name: String, attachmentName: String, capturedPNG: Data? = nil) throws
    {
        let png = capturedPNG ?? app.screenshotForFailureEvidence().pngRepresentation
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = attachmentName
        attachment.lifetime = .keepAlways
        add(attachment)
        try StrictE2EVisualEvidence.writeRequiredPNG(png, name: name)
    }

    func attachScreenshot(app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshotForFailureEvidence())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func attachFocusAudit(app: XCUIApplication, name: String) {
        let focused = app.descendants(matching: .any).allElementsBoundByIndex.filter(\.hasFocus)
        let lines = focused.map { element in
            "type=\(element.elementType.rawValue) id=\(element.identifier) label=\(element.label) frame=\(element.frame)"
        }
        let attachment = XCTAttachment(string: lines.isEmpty ? "no-focused-element" : lines.joined(separator: "\n"))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // Visible card center spacing is still 320+34. The focused accessibility frame includes the glow, so
    // intersecting frames do not mean the cards visibly overlap.
    func assertNoFocusCollision(focused: XCUIElement, neighbor: XCUIElement) {
        XCTAssertTrue(focused.exists, "The focused element must exist to check for collisions.")
        XCTAssertTrue(
            neighbor.exists,
            "With the neighboring element missing, focus-scale collision is unverified and cannot pass.")
        let dx = abs(focused.frame.midX - neighbor.frame.midX)
        let dy = abs(focused.frame.midY - neighbor.frame.midY)
        let cardSpan = min(neighbor.frame.width, neighbor.frame.height)
        XCTAssertTrue(
            dx > cardSpan * 0.85 || dy > cardSpan * 0.85,
            "The scaled-up focused element must not collide with its neighbor: \(focused.identifier) vs \(neighbor.identifier) focused=\(focused.frame) neighbor=\(neighbor.frame) dx=\(dx) dy=\(dy)"
        )
    }

    func collectFixtureIDs(app: XCUIApplication) -> (ids: [String], raw: [String]) {
        let query = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier CONTAINS 'album-' OR identifier CONTAINS 'person-' OR identifier CONTAINS 'asset-'")
        )
        var raw: [String] = []
        var ids: [String] = []
        let limit = min(query.count, 80)
        for index in 0..<limit {
            let identifier = query.element(boundBy: index).identifier
            raw.append(identifier)
            if let match = identifier.range(
                of: #"(album|person|asset)-[ab]-[A-Za-z0-9-]+"#,
                options: .regularExpression
            ) {
                ids.append(String(identifier[match]))
            }
        }
        return (Array(Set(ids)).sorted(), raw)
    }

    @MainActor
    func assertStillInApp(_ app: XCUIApplication) throws {
        if app.state != .runningForeground {
            attachScreenshot(app: app, name: "tvos-left-app")
            XCTFail("Leaving the app is a failure, state=\(app.state.rawValue)")
        }
    }

    // One Menu press from the album list returns to the filter screen; the album list identifier must still be visible.
    @MainActor
    func returnFromAlbumList(app: XCUIApplication) throws {
        try assertStillInApp(app)
        let albumList = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'albumFilter.album.'")
        ).firstMatch
        XCTAssertTrue(
            albumList.waitForFailureEvidence(timeout: TestWait.seconds(.product(8))),
            "Must still be on the album list to return to the filter screen")
        FirstFailureRemote.press(.menu)
        try assertStillInApp(app)
        XCTAssertTrue(
            app.buttons["filterSummary.album.button"].waitForFailureEvidence(timeout: TestWait.seconds(.product(10)))
                || app.buttons["filter.editor.album.entry"].waitForFailureEvidence(
                    timeout: TestWait.seconds(.product(2))),
            "Going back from the album list must return to the filter screen"
        )
    }

    // Go from the playback control bar to the settings home, then into playback settings, avoiding UI_TEST injection.
    @MainActor
    func openPlaybackSettingsFromSlideshow(app: XCUIApplication) throws {
        if app.refreshTVOSSlideshowControlBar(timeout: TestWait.seconds(.product(8))) {
            let settingsButton = app.buttons["slideshow.control.settings.button"]
            moveFocus(
                .left, to: settingsButton, maximumPresses: 4,
                message: "Focus on the playback control bar must be able to move to Settings.")
            FirstFailureRemote.press(.select)
        }
        let playbackItem = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            playbackItem.waitForPublicElement("settings.item.playback", timeout: TestWait.seconds(.product(8))),
            "The settings screen must show the playback entry.")
        moveFocusTo(playbackItem, directions: [.up, .down], message: "Focus must be able to move to playback settings.")
        FirstFailureRemote.press(.select)
    }

    // After switching servers, reach the filter editor entry in playback settings from the current real screen,
    // without guessing the route by pressing Menu in a loop.
    @MainActor
    func openFilterEditorFromCurrentSurface(app: XCUIApplication) throws {
        try assertStillInApp(app)
        if app.buttons["filter.editor.album.entry"].exists || app.buttons["filterSummary.album.button"].exists {
            return
        }
        if app.buttons["settings.playback.filterConfig.button"].exists {
            try openFilterConfigFromPlaybackSettings(app: app)
            return
        }
        if app.textFields["firstboot.serverURL.field"].exists
            || app.descendants(matching: .any)["settings.server.feedback.save.success"].exists
        {
            FirstFailureRemote.press(.menu)
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.8))))
            try assertStillInApp(app)
            XCTAssertTrue(
                app.buttons["settings.item.playback"].waitForPublicElement(
                    "settings.item.playback", timeout: TestWait.seconds(.product(8)))
                    || app.buttons["settings.item.server"].waitForFailureEvidence(
                        timeout: TestWait.seconds(.product(2))),
                "Going back from server settings must stay on the settings home screen"
            )
        }
        if app.buttons["slideshow.control.playPause.button"].exists,
            !app.buttons["settings.item.playback"].exists
        {
            try openPlaybackSettingsFromSlideshow(app: app)
            try assertStillInApp(app)
        }
        let playbackItem = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            playbackItem.waitForPublicElement("settings.item.playback", timeout: TestWait.seconds(.product(8))),
            "The filter editor must be entered through the settings playback entry")
        try assertStillInApp(app)
        if !app.buttons["settings.playback.filterConfig.button"].exists
            && !app.buttons["settings.playback.mode.link"].exists
        {
            moveFocusTo(
                playbackItem, directions: [.up, .down], message: "Focus must be able to move to playback settings.")
            FirstFailureRemote.press(.select)
            try assertStillInApp(app)
        }
        try openFilterConfigFromPlaybackSettings(app: app)
    }

    // The filter editor entry appears only when the default mode is filtered; if it is missing, go through the real
    // default mode screen first.
    @MainActor
    func openFilterEditorFromPlaybackSettings(app: XCUIApplication) throws {
        try openPlaybackSettingsFromSlideshow(app: app)
        try openFilterConfigFromPlaybackSettings(app: app)
    }

    @MainActor
    func openFilterConfigFromPlaybackSettings(app: XCUIApplication) throws {
        let filterConfig = app.buttons["settings.playback.filterConfig.button"]
        if filterConfig.waitForFailureEvidence(timeout: TestWait.seconds(.product(2))) {
            try selectFilterConfigOnPlaybackSettings(app: app, filterConfig: filterConfig)
            return
        }

        let modeLink = app.buttons["settings.playback.mode.link"]
        XCTAssertTrue(
            modeLink.waitForFailureEvidence(timeout: TestWait.seconds(.product(8))),
            "Playback settings must offer Default Playback Mode.")
        moveFocusTo(modeLink, directions: [.up, .down], message: "Focus must be able to move to Default Playback Mode.")
        FirstFailureRemote.press(.select)
        let filtered = app.buttons["settings.playback.mode.filtered.button"]
        XCTAssertTrue(
            filtered.waitForFailureEvidence(timeout: TestWait.seconds(.product(8))),
            "Filtered Playback must be selectable.")
        moveFocus(.down, to: filtered, maximumPresses: 4, message: "Focus must land on Filtered Playback.")
        FirstFailureRemote.press(.select)

        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        if let alert = namedFilterModeBlockedAlert(in: app) {
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            try confirmConfigureInFilterBlockedAlert(alert: alert, app: app)
            try waitForFilterEditorSurface(
                app: app, message: "Pressing the right Set Up Filters must go straight to the filter editor")
            return
        }

        if app.buttons["settings.playback.mode.filtered.button"].exists
            && !app.buttons["settings.playback.filterConfig.button"].exists
        {
            FirstFailureRemote.press(.menu)
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.8))))
        }
        let returnedConfig = app.buttons["settings.playback.filterConfig.button"]
        XCTAssertTrue(
            returnedConfig.waitForFailureEvidence(timeout: TestWait.seconds(.product(8))),
            "Once the default mode can switch, playback settings must return with the filter editor entry.")
        try selectFilterConfigOnPlaybackSettings(app: app, filterConfig: returnedConfig)
    }

    @MainActor
    func selectFilterConfigOnPlaybackSettings(app: XCUIApplication, filterConfig: XCUIElement) throws {
        XCTAssertTrue(
            app.buttons["settings.playback.filterConfig.button"].exists
                && (app.buttons["settings.playback.mode.link"].exists
                    || app.buttons["settings.playback.autoPlay.toggle"].exists
                    || app.switches["settings.playback.autoPlay.toggle"].exists),
            "filterConfig may only be used on the real playback settings screen"
        )
        moveFocusTo(filterConfig, directions: [.down, .up], message: "Focus must be able to move to Edit Filters.")
        XCTAssertTrue(filterConfig.hasFocus, "Edit Filters must have hasFocus before Select.")
        FirstFailureRemote.press(.select)
        try waitForFilterEditorSurface(app: app, message: "The filter editor must open")
    }

    @MainActor
    func namedFilterModeBlockedAlert(in app: XCUIApplication) -> XCUIElement? {
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let titles = ["无法切换到筛选播放", "Can't Switch to Filtered Playback"]
        let deadline = Date().addingTimeInterval(TestWait.seconds(.product(2)))
        while Date() < deadline {
            for title in titles {
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                let alert = app.alerts[title]
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                if alert.exists { return alert }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.1))))
        }
        return nil
    }

    // In the error alert's tree, the Set Up Filters button wraps a same-named child button. Read hasFocus for each
    // element via boundBy; do not treat a multi-match query as a single element.
    @MainActor
    func confirmConfigureInFilterBlockedAlert(alert: XCUIElement, app: XCUIApplication) throws {
        let configureQuery = alert.buttons.matching(
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            NSPredicate(format: "label == %@ OR label == %@", "去配置", "Set Up Filters")
        )
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(3))) { configureQuery.element(boundBy: 0).exists },
            "Set Up Filters must appear in the named alert"
        )
        let configureNodes = configureQuery.allElementsBoundByIndex
        XCTAssertFalse(configureNodes.isEmpty, "Set Up Filters must appear in the named alert")
        XCTAssertTrue(
            configureNodes.count == 1 || configureNodes.count == 2,
            "Set Up Filters must be one visual action as one node or a parent-child pair; found \(configureNodes.count) nodes"
        )
        if configureNodes.count == 2 {
            let outer = configureQuery.element(boundBy: 0)
            let inner = configureQuery.element(boundBy: 1)
            XCTAssertTrue(
                outer.frame.contains(inner.frame) || inner.frame.contains(outer.frame),
                "Two Set Up Filters nodes must be a parent-child wrapper, not two separate actions"
            )
        }
        if !configureActionHasFocus(configureQuery) {
            for direction in [.right, .left, .up, .down] as [XCUIRemote.Button] {
                var remaining = 4
                while remaining > 0 {
                    if configureActionHasFocus(configureQuery) { break }
                    FirstFailureRemote.press(direction)
                    RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusMovementSettleSeconds))
                    remaining -= 1
                }
                if configureActionHasFocus(configureQuery) { break }
            }
        }
        try writeScreenshotPNG(
            app: app,
            name: "filter-blocked-configure-focused",
            attachmentName: "filter-blocked-configure-focused"
        )
        XCTAssertTrue(
            configureActionHasFocus(configureQuery), "Before Select, focus must belong to the Set Up Filters action")
        FirstFailureRemote.press(.select)
    }

    @MainActor
    func configureActionHasFocus(_ query: XCUIElementQuery) -> Bool {
        let nodes = query.allElementsBoundByIndex
        for index in nodes.indices {
            let node = query.element(boundBy: index)
            if node.exists && node.hasFocus {
                return true
            }
        }
        return false
    }

    @MainActor
    func waitForFilterEditorSurface(app: XCUIApplication, message: String) throws {
        let didReach = waitUntil(timeout: TestWait.seconds(.product(12))) {
            let done = app.buttons["filter.editor.done.button"]
            let album = app.buttons["filter.editor.album.entry"]
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            return app.alerts.count == 0 && done.exists && done.isHittable && album.exists && album.isHittable
        }
        try writeScreenshotPNG(app: app, name: "desktop-editor-transition", attachmentName: "desktop-editor-transition")
        try StrictE2EVisualEvidence.writeRequiredJSON(
            ["ui": app.debugDescription], name: "desktop-editor-transition.json")
        XCTAssertTrue(didReach, message)
    }

    // Deselect other albums first and keep only the controlled empty album, so the union holds no old photos.
    @MainActor
    func isolateAndSelectEmptyAlbum(app: XCUIApplication, emptyAlbumID: String, neighborID: String) throws {
        try openAlbumFilter(app: app)
        let known = [
            "album-a-target", "album-a-non-target", "album-a-empty",
            "album-b-target", "album-b-non-target", "album-b-empty"
        ]
        for otherID in known where otherID != emptyAlbumID {
            let other = app.buttons["albumFilter.album.\(otherID).button"]
            guard other.exists else { continue }
            moveFocusTo(
                other, directions: [.down, .right, .left, .up],
                message: "Focus must be able to move to the album to deselect.")
            let value = String(describing: other.value ?? "")
            if value.contains("已选中") {
                FirstFailureRemote.press(.select)
                RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.4))))
            }
        }
        let target = app.buttons["albumFilter.album.\(emptyAlbumID).button"]
        XCTAssertTrue(
            target.waitForFailureEvidence(timeout: TestWait.seconds(.infrastructure(15))),
            "The album list must show the controlled empty album \(emptyAlbumID)."
        )
        moveFocusTo(target, directions: [.down, .right, .left], message: "Focus must land on the empty album.")
        let neighbor = app.buttons["albumFilter.album.\(neighborID).button"]
        if neighbor.exists {
            assertNoFocusCollision(focused: target, neighbor: neighbor)
        }
        let value = String(describing: target.value ?? "")
        if !value.contains("已选中") {
            FirstFailureRemote.press(.select)
        }
        FirstFailureRemote.press(.menu)
    }

    // Menu returns to playback or the empty-pool copy screen; the empty pool has no control bar, so do not wait
    // only for playPause.
    @MainActor
    func returnToSlideshowFromSettings(app: XCUIApplication) throws {
        for _ in 0..<10 {
            if app.buttons["slideshow.control.playPause.button"].exists
                || app.staticTexts["slideshow.emptyState.message"].exists
            {
                return
            }
            FirstFailureRemote.press(.menu)
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.6))))
        }
        XCTFail("Cannot return from settings to the playback screen.")
    }

    func firstBootControl(
        in app: XCUIApplication,
        identifier: String
    ) -> XCUIElement {
        let button = app.buttons[identifier]
        if button.exists { return button }
        let identifiedElement = app.descendants(matching: .any)[identifier]
        return identifiedElement
    }
}
#endif
