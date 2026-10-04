import XCTest

#if os(iOS)
extension StrictE2EFilterIOSUITests {
    func stringValue(_ payload: [String: Any], keyPath: [String]) throws -> String {
        var current: Any = payload
        for key in keyPath {
            guard let object = current as? [String: Any], let next = object[key] else {
                throw StrictE2EFilterContract.AssertionError.message(
                    "manifest is missing \(keyPath.joined(separator: "."))")
            }
            current = next
        }
        guard let value = current as? String, !value.isEmpty else {
            throw StrictE2EFilterContract.AssertionError.message(
                "manifest is missing \(keyPath.joined(separator: "."))")
        }
        return value
    }

    func stringArrayValue(_ payload: [String: Any], keyPath: [String]) throws -> [String] {
        var current: Any = payload
        for key in keyPath {
            guard let object = current as? [String: Any], let next = object[key] else {
                throw StrictE2EFilterContract.AssertionError.message(
                    "manifest is missing \(keyPath.joined(separator: "."))")
            }
            current = next
        }
        guard let values = current as? [String], !values.isEmpty else {
            throw StrictE2EFilterContract.AssertionError.message(
                "manifest is missing \(keyPath.joined(separator: "."))")
        }
        return values
    }

    func strictE2EProcessID(_ app: XCUIApplication) throws -> Int {
        let object = app as NSObject
        if object.responds(to: Selector(("processID"))),
            let number = object.value(forKey: "processID") as? NSNumber,
            number.intValue > 0
        {
            return number.intValue
        }
        let text = app.debugDescription as NSString
        let regex = try NSRegularExpression(pattern: #"pid[: ]+(\d+)"#, options: [.caseInsensitive])
        if let match = regex.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)),
            let processID = Int(text.substring(with: match.range(at: 1))), processID > 0
        {
            return processID
        }
        throw StrictE2EFilterContract.AssertionError.message("Cannot read the actual app process ID")
    }

    @MainActor
    func playPersonRuleFromFirstBoot(
        personID: String,
        isSoloOnly: Bool,
        screenshotName: String,
        evidencePrefix: String
    ) throws {
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }
        try completeFirstBootToModeSelection(app: app, input: input, evidencePrefix: evidencePrefix)
        enterFilterSummary(app: app)
        openPersonFilter(app: app)
        selectPerson(app: app, personID: personID, isSoloOnly: isSoloOnly)
        try returnFromPersonFilterToSummary(app: app)
        startFilteredPlayback(app: app)
        pausePlaybackIfNeeded(app: app)
        _ = capturePlaybackPNG(app: app, name: screenshotName)
        try writePersonResultsJSON()
    }

    func writePersonResultsJSON() throws {
        let soloOnlyEvidence: [String: Any] =
            isRunningOnSimulator
            ? ["environment": "simulator", "verdict": "UNVERIFIED"]
            : ["environment": "device", "verdict": "UNVERIFIED"]
        try StrictE2EVisualEvidence.writeRequiredJSON(
            [
                "cases": [
                    "solo_only": soloOnlyEvidence
                ]
            ],
            name: "person-results.json"
        )
    }

    @MainActor
    func completeFirstBootToModeSelection(
        app: XCUIApplication,
        input: StrictE2EInput,
        evidencePrefix: String
    ) throws {
        try fillFirstBootForm(app: app, input: input)
        tapTestConnection(app: app)
        let saveButton = firstBootControl(
            in: app,
            identifier: "firstboot.saveConfig.button"
        )
        XCTAssertTrue(saveButton.waitForExistence(timeout: 8), "First-boot page must show the Save Settings button.")
        XCTAssertTrue(
            waitForSaveEnabled(app: app, saveButton: saveButton, timeout: 45),
            "Save must become enabled after a real connection test succeeds.")
        attachStrictE2EScreenshot(app: app, name: "\(evidencePrefix)-connection-passed-\(currentDeviceTag())")
        tapElement(saveButton)
        XCTAssertTrue(
            app.buttons["mode.random.button"].waitForExistence(timeout: 15),
            "A successful save must lead to mode selection.")
        XCTAssertTrue(app.buttons["mode.filtered.button"].exists, "Mode page must also offer the filter option.")
        attachStrictE2EScreenshot(app: app, name: "\(evidencePrefix)-mode-selection-\(currentDeviceTag())")
    }

    @MainActor
    func disableExifForDisplayEvidence(app: XCUIApplication) throws {
        let identifier = "settings.playback.showExif.toggle"
        let exif =
            app.switches[identifier].exists
            ? app.switches[identifier]
            : app.descendants(matching: .any)[identifier].firstMatch
        guard exif.waitForExistence(timeout: 6),
            let value = exif.value as? String, ["0", "1"].contains(value)
        else {
            throw StrictE2EPhotoIdentity.AssertionError.message(
                "The real EXIF switch must be read before capturing display policy evidence")
        }
        if value == "1" { exif.tap() }
        guard waitUntil(timeout: 4, condition: { (exif.value as? String) == "0" }) else {
            throw StrictE2EPhotoIdentity.AssertionError.message(
                "EXIF must be turned off through real settings before display policy screenshots")
        }
    }

    @MainActor
    func fillFirstBootForm(app: XCUIApplication, input: StrictE2EInput) throws {
        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(
            serverField.waitForExistence(timeout: 20), "A fresh install must open the normal first-boot page.")
        replaceText(
            in: serverField, app: app, with: input.serverURL, evidenceName: "firstboot-url-replace",
            shouldRequireExactValue: true)
        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 8), "First-boot page must show the API Key field.")
        replaceText(
            in: apiKeyField, app: app, with: input.publicKey, evidenceName: "firstboot-apikey-replace",
            shouldRequireExactValue: false)
        XCTAssertTrue(
            waitUntil(timeout: 3) { self.hasSecureFieldEnteredValue(apiKeyField) },
            "API Key must actually be entered into the secure field.")
        commitFocusedInputIfNeeded(app: app)
    }

    @MainActor
    func enterFilterSummary(app: XCUIApplication) {
        chooseOnboardingModeAndContinue(app: app, identifier: "mode.filtered.button")
        let reached = waitUntil(timeout: 20) {
            app.buttons["filterSummary.album.button"].exists
                || app.descendants(matching: .any)["filterSummary.album.button"].exists
        }
        if reached {
            attachStrictE2EScreenshot(app: app, name: "filter-summary-\(currentDeviceTag())")
            return
        }
        attachStrictE2EScreenshot(app: app, name: "filter-summary-missing-\(currentDeviceTag())")
        if app.buttons["slideshow.control.settings.button"].exists {
            XCTFail("Filter was chosen but playback opened, so the mode card tap did not register.")
        } else if app.buttons["mode.random.button"].exists {
            XCTFail("Still on the mode page after Continue; filtered mode did not start.")
        } else {
            XCTFail("Filtered mode must reach the filter summary page.")
        }
    }

    @MainActor
    func openAlbumFilterHandlingSystemPrompt(app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(15)
        var didTap = false
        while Date() < deadline {
            if isSystemSavePasswordPromptVisible(app: app) {
                _ = captureNamedPNG(app: app, name: "server-switch-entry-password-prompt")
                guard dismissSystemSavePasswordPromptIfPresent(app: app, timeout: 4) else { break }
                didTap = false
            }
            let back = app.buttons["albumFilter.back.button"]
            if back.exists && back.isHittable { return }
            let entry = app.buttons["filterSummary.album.button"]
            if !didTap && entry.exists && entry.isHittable {
                entry.tap()
                didTap = true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        _ = captureNamedPNG(app: app, name: "server-switch-album-entry-failure")
        XCTFail("After handling the named system prompt, a usable album list must open")
    }

    @MainActor
    func openAlbumFilter(app: XCUIApplication) {
        tapElement(app.buttons["filterSummary.album.button"])
        XCTAssertTrue(
            app.buttons["albumFilter.back.button"].waitForExistence(timeout: 12)
                || app.buttons["albumFilter.selectAll.button"].waitForExistence(timeout: 2),
            "Album filter page must open"
        )
    }

    @MainActor
    func openPersonFilter(app: XCUIApplication) {
        tapElement(app.buttons["filterSummary.person.button"])
        XCTAssertTrue(
            app.buttons["personFilter.back.button"].waitForExistence(timeout: 12)
                || app.buttons["personFilter.selectAll.button"].waitForExistence(timeout: 2),
            "Person filter page must open"
        )
    }

    @MainActor
    func openAlbumFilterFromEditor(app: XCUIApplication) {
        let entry = app.buttons["filter.editor.album.entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "Filter editor must offer the album entry")
        tapElement(entry)
        _ = app.buttons["albumFilter.back.button"].waitForExistence(timeout: 12)
    }

    @MainActor
    func openPersonFilterFromEditor(app: XCUIApplication) {
        let entry = app.buttons["filter.editor.person.entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "Filter editor must offer the person entry")
        tapElement(entry)
        _ = app.buttons["personFilter.back.button"].waitForExistence(timeout: 12)
    }

    @MainActor
    func selectAlbum(app: XCUIApplication, albumID: String) {
        let button = app.buttons["albumFilter.album.\(albumID).button"]
        XCTAssertTrue(button.waitForExistence(timeout: 20), "Album \(albumID) must appear")
        tapElement(button)
    }

    @MainActor
    func setAlbumSelection(app: XCUIApplication, albumID: String, isSelectionRequested: Bool) {
        let card = albumCard(app: app, albumID: albumID)
        XCTAssertTrue(card.waitForExistence(timeout: 20), "Album \(albumID) must appear")
        XCTAssertTrue(
            waitUntil(timeout: 12) {
                if self.isSystemSavePasswordPromptVisible(app: app) {
                    _ = self.dismissSystemSavePasswordPromptIfPresent(app: app, timeout: 2)
                    return false
                }
                return card.exists && card.isHittable
            },
            "Album must be visible and hittable; state injection is no substitute"
        )
        if isAlbumCardSelected(card) != isSelectionRequested {
            guard !isSystemSavePasswordPromptVisible(app: app), card.isHittable else {
                XCTFail("Before the tap, the album must still be visible and not covered by a system prompt")
                return
            }
            card.tap()
        }
        XCTAssertTrue(
            waitUntil(timeout: 6) { self.isAlbumCardSelected(card) == isSelectionRequested },
            "Album \(albumID) must actually reach the requested selection state"
        )
    }

    // During server switching, the system "Save Password?" prompt can cover the albums. Tap only "Not Now",
    // wait until the album is hittable before tapping, and never tap through the prompt by coordinates.
    @MainActor
    func selectAlbumHandlingSystemPrompt(app: XCUIApplication, albumID: String) {
        if isSystemSavePasswordPromptVisible(app: app) {
            XCTAssertTrue(
                dismissSystemSavePasswordPromptIfPresent(app: app, timeout: 6),
                "The system Save Password prompt must be closed with 'Not Now'; test credentials must not be saved"
            )
        }
        _ = captureNamedPNG(app: app, name: "server-switch-album-before-select-\(albumID)")
        tapAlbumWhenHittable(app: app, albumID: albumID)
        if !isAlbumCardSelected(albumCard(app: app, albumID: albumID))
            && isSystemSavePasswordPromptVisible(app: app)
        {
            _ = captureNamedPNG(app: app, name: "server-switch-save-password-late-\(albumID)")
            XCTAssertTrue(
                dismissSystemSavePasswordPromptIfPresent(app: app, timeout: 6),
                "A late Save Password prompt allows only this one retry, backed by evidence"
            )
            tapAlbumWhenHittable(app: app, albumID: albumID)
        }
        XCTAssertTrue(
            waitUntil(timeout: 4) { self.isAlbumCardSelected(self.albumCard(app: app, albumID: albumID)) },
            "Target album must be selected; no blind taps while the prompt covers it"
        )
        _ = captureNamedPNG(app: app, name: "server-switch-album-after-select-\(albumID)")
    }

    @MainActor
    func tapAlbumWhenHittable(app: XCUIApplication, albumID: String) {
        if isSystemSavePasswordPromptVisible(app: app) {
            XCTAssertTrue(
                dismissSystemSavePasswordPromptIfPresent(app: app, timeout: 6),
                "Do not tap the album while the prompt covers it"
            )
        }
        let identifier = "albumFilter.album.\(albumID).button"
        XCTAssertTrue(
            waitUntil(timeout: 12) {
                if self.isSystemSavePasswordPromptVisible(app: app) {
                    _ = self.dismissSystemSavePasswordPromptIfPresent(app: app, timeout: 2)
                    return false
                }
                let button = app.buttons[identifier]
                return button.exists && button.isHittable
            },
            "After closing the Save Password prompt, a fresh query must find the target album hittable"
        )
        let button = app.buttons[identifier]
        XCTAssertFalse(isSystemSavePasswordPromptVisible(app: app), "Do not tap the album while the prompt covers it")
        XCTAssertTrue(button.isHittable, "Target album must be hittable; no coordinate fallback")
        if isAlbumCardSelected(button) { return }
        button.tap()
    }

    @MainActor
    func albumCard(app: XCUIApplication, albumID: String) -> XCUIElement {
        app.buttons["albumFilter.album.\(albumID).button"]
    }

    @MainActor
    func isAlbumCardSelected(_ button: XCUIElement) -> Bool {
        if button.isSelected { return true }
        let value = String(describing: button.value ?? "")
        if value.contains("已选中") { return true }
        return button.images["checkmark.circle.fill"].exists
    }

    @MainActor
    func namedSavePasswordPrompt(in app: XCUIApplication) -> XCUIElement? {
        // ui-label-lookup: The Save Password sheet belongs to iOS.
        let titles = ["保存密码？", "保存密码?", "Save Password?"]
        for title in titles {
            // ui-label-lookup: The Save Password prompt belongs to iOS.
            let sheet = app.sheets[title]
            if sheet.exists { return sheet }
            // ui-label-lookup: The Save Password prompt belongs to iOS.
            let alert = app.alerts[title]
            if alert.exists { return alert }
        }
        // The system prompt container may have no title identifier, so match the title together with
        // the single decline and save buttons.
        // ui-label-lookup: The Save Password sheet belongs to iOS.
        let title = app.staticTexts.matching(NSPredicate(format: "label IN %@", titles)).firstMatch
        // ui-label-lookup: The Save Password action is owned by iOS.
        let later = app.buttons.matching(NSPredicate(format: "label IN %@", ["以后", "Not Now"]))
        // ui-label-lookup: The Save Password action is owned by iOS.
        let save = app.buttons.matching(NSPredicate(format: "label IN %@", ["保存", "Save Password", "Save"]))
        if title.exists && later.count == 1 && save.count == 1 { return app }
        return nil
    }

    @MainActor
    func isSystemSavePasswordPromptVisible(app: XCUIApplication) -> Bool {
        namedSavePasswordPrompt(in: app) != nil
            || namedSavePasswordPrompt(in: XCUIApplication(bundleIdentifier: "com.apple.springboard")) != nil
    }

    @discardableResult
    @MainActor
    func dismissSystemSavePasswordPromptIfPresent(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for host in [app, springboard] {
                guard let prompt = namedSavePasswordPrompt(in: host) else { continue }
                // ui-label-lookup: Dismiss the iOS Save Password sheet without saving credentials.
                let later = prompt.buttons["以后"].exists ? prompt.buttons["以后"] : prompt.buttons["Not Now"]
                guard later.exists else { continue }
                later.tap()
                _ = waitUntil(timeout: 2) { !self.isSystemSavePasswordPromptVisible(app: app) }
                return !isSystemSavePasswordPromptVisible(app: app)
            }
            if !isSystemSavePasswordPromptVisible(app: app) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return !isSystemSavePasswordPromptVisible(app: app)
    }

    @MainActor
    func personNameElement(app: XCUIApplication, personID: String) -> XCUIElement {
        // Public fixture names end in Synthetic; the cover, count and switch of the same card inherit
        // the same identifier.
        let names = app.staticTexts.matching(identifier: "personFilter.person.\(personID).button")
            // ui-label-lookup: Verify the public fixture person name after locating its card by identifier.
            .matching(NSPredicate(format: "label ENDSWITH %@", " Synthetic"))
        XCTAssertTrue(
            names.firstMatch.waitForExistence(timeout: 20), "The target public fixture person name must appear")
        XCTAssertEqual(
            names.count, 1, "Target person name must be unique; do not pick an arbitrary node with the same identifier")
        return names.element(boundBy: 0)
    }

    @MainActor
    func personSoloOnlySwitch(app: XCUIApplication, personID: String) -> XCUIElement {
        app.switches["personFilter.person.\(personID).button"]
    }

    @MainActor
    func selectPerson(app: XCUIApplication, personID: String, isSoloOnly: Bool) {
        let card = personNameElement(app: app, personID: personID)
        let toggle = personSoloOnlySwitch(app: app, personID: personID)
        if !toggle.exists {
            tapElement(card)
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 6), "Solo-only switch must appear after selecting the person")
        let isOn = (toggle.value as? String) == "1"
        if isSoloOnly != isOn {
            // Tap the actual knob on the right of the switch; tapping the middle of the combined SwiftUI label
            // may not toggle the value.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        assertPersonNavigation(
            waitUntil(timeout: 6) { (toggle.value as? String) == (isSoloOnly ? "1" : "0") },
            "Target person's solo-only mode must reach the requested value", app: app, personID: personID)
    }

    @MainActor
    func returnFromAlbumFilter(app: XCUIApplication) {
        let back = app.buttons["albumFilter.back.button"]
        XCTAssertTrue(back.waitForExistence(timeout: 8), "Album filter must be able to go back")
        tapElement(back)
    }

    @MainActor
    func returnFromPersonFilter(app: XCUIApplication) {
        let back = app.buttons["personFilter.back.button"]
        XCTAssertTrue(back.waitForExistence(timeout: 8), "Person filter must be able to go back")
        back.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor
    func returnFromPersonFilterToSummary(app: XCUIApplication) throws {
        let backCountBeforeTap = app.buttons.matching(identifier: "personFilter.back.button").count
        NSLog("personFilter.back.button.count.before-tap \(backCountBeforeTap)")
        returnFromPersonFilter(app: app)
        let immediate = snapshotPersonReturnSurface(app, backCountBeforeTap: backCountBeforeTap)
        NSLog("person-return-immediate \(immediate)")
        attachStrictE2EScreenshot(app: app, name: "person-return-immediate-\(currentDeviceTag())")
        try StrictE2EVisualEvidence.writeRequiredJSON(immediate, name: "person-return-immediate.json")
        let returned = waitUntil(timeout: 8, condition: { self.isFilterSummaryVisible(app) })
        if returned == false {
            let later = snapshotPersonReturnSurface(app, backCountBeforeTap: backCountBeforeTap)
            NSLog("person-return-after-wait \(later)")
            attachStrictE2EScreenshot(app: app, name: "person-return-after-wait-\(currentDeviceTag())")
            try StrictE2EVisualEvidence.writeRequiredJSON(later, name: "person-return-after-wait.json")
            XCTFail(
                "Back from the person filter must land on the filter summary, not stay on the person page or fall back to mode selection. immediate=\(immediate) later=\(later)"
            )
        }
    }
}
#endif
