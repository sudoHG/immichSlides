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
        let app = try launchStrictE2EApp(recordSceneSequence: true)
        defer { app.terminateForFailureEvidence() }
        try completeFirstBootToModeSelection(app: app, input: input, evidencePrefix: evidencePrefix)
        enterFilterSummary(app: app)
        openPersonFilter(app: app)
        selectPerson(app: app, personID: personID, isSoloOnly: isSoloOnly)
        try returnFromPersonFilterToSummary(app: app)
        startFilteredPlayback(app: app)
        // Pause freezes fades too; establish a complete scene before taking membership evidence.
        guard pauseStableAlbumPlaybackIfNeeded(app: app) else { return }
        _ = try captureStableAlbumPlaybackPNG(app: app, name: screenshotName)
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
        XCTAssertTrue(
            saveButton.waitForFailureEvidence(timeout: TestWait.seconds(.infrastructure(8))),
            "First-boot page must show the Save Settings button.")
        XCTAssertTrue(
            waitForSaveEnabled(app: app, saveButton: saveButton, timeout: TestWait.seconds(.infrastructure(45))),
            "Save must become enabled after a real connection test succeeds.")
        attachStrictE2EScreenshot(app: app, name: "\(evidencePrefix)-connection-passed-\(currentDeviceTag())")
        tapElement(saveButton)
        XCTAssertTrue(
            app.buttons["mode.random.button"].waitForPublicElement(
                "mode.random.button", timeout: TestWait.seconds(.product(15))),
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
        guard exif.waitForFailureEvidence(timeout: TestWait.seconds(.product(6))),
            let value = exif.value as? String, ["0", "1"].contains(value)
        else {
            throw StrictE2EPhotoIdentity.AssertionError.message(
                "The real EXIF switch must be read before capturing display policy evidence")
        }
        if value == "1" { exif.tapForFailureEvidence() }
        guard waitUntil(timeout: TestWait.seconds(.product(4)), condition: { (exif.value as? String) == "0" }) else {
            throw StrictE2EPhotoIdentity.AssertionError.message(
                "EXIF must be turned off through real settings before display policy screenshots")
        }
    }

    @MainActor
    func fillFirstBootForm(app: XCUIApplication, input: StrictE2EInput) throws {
        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(
            serverField.waitForPublicElement(
                "firstboot.serverURL.field", timeout: TestWait.seconds(.infrastructure(20))),
            "A fresh install must open the normal first-boot page.")
        replaceText(
            in: serverField, app: app, with: input.serverURL, evidenceName: "firstboot-url-replace",
            shouldRequireExactValue: true)
        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(
            apiKeyField.waitForPublicElement("firstboot.apiKey.field", timeout: TestWait.seconds(.infrastructure(8))),
            "First-boot page must show the API Key field.")
        replaceText(
            in: apiKeyField, app: app, with: input.publicKey, evidenceName: "firstboot-apikey-replace",
            shouldRequireExactValue: false)
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(3))) { self.hasSecureFieldEnteredValue(apiKeyField) },
            "API Key must actually be entered into the secure field.")
        commitFocusedInputIfNeeded(app: app)
    }

    @MainActor
    func enterFilterSummary(app: XCUIApplication) {
        guard let summaryDeadline = chooseOnboardingModeAndContinue(app: app, identifier: "mode.filtered.button")
        else { return }
        let reached = summaryDeadline.confirms { nodes in
            nodes.contains { $0.identifier == "filterSummary.album.button" }
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
        let deadline = Date().addingTimeInterval(TestWait.seconds(.product(15)))
        var didTap = false
        while Date() < deadline {
            if isSystemSavePasswordPromptVisible(app: app, deadline: deadline) {
                guard dismissSystemSavePasswordPromptIfPresent(app: app, deadline: deadline)
                else { break }
                _ = captureNamedPNG(app: app, name: "server-switch-entry-password-prompt-dismissed")
                didTap = false
            }
            let back = app.buttons["albumFilter.back.button"]
            if back.exists && back.isHittable { return }
            let entry = app.buttons["filterSummary.album.button"]
            if !didTap && entry.exists && entry.isHittable {
                entry.tapForFailureEvidence()
                didTap = true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.2))))
        }
        _ = captureNamedPNG(app: app, name: "server-switch-album-entry-failure")
        XCTFail("After handling the named system prompt, a usable album list must open")
    }

    @MainActor
    func openAlbumFilter(app: XCUIApplication) {
        openFilterPage(app: app, kind: "album")
    }

    @MainActor
    func openPersonFilter(app: XCUIApplication) {
        openFilterPage(app: app, kind: "person")
    }

    @MainActor
    private func openFilterPage(app: XCUIApplication, kind: String) {
        let guardWait = TestWait.hangGuard()
        let transaction = guardWait.transaction()
        let entryIdentifier = "filterSummary.\(kind).button"
        var targetFrame: CGRect?
        let prepared = transaction.until {
            let snapshots = app.evidenceSnapshotsByIdentifier()
            guard let target = snapshots[entryIdentifier], target.isEnabled, !target.frame.isEmpty else { return false }
            targetFrame = target.frame
            return true
        }
        guard prepared, let targetFrame,
            transaction.perform(
                "tap",
                {
                    FirstFailureContext.mark("select", element: entryIdentifier)
                    let startedAt = ProcessInfo.processInfo.systemUptime
                    print(
                        "Filter navigation action issued: entry=\(entryIdentifier); unixSeconds=\(Date().timeIntervalSince1970)"
                    )
                    app.coordinate(withNormalizedOffset: .zero).withOffset(
                        CGVector(dx: targetFrame.midX, dy: targetFrame.midY)
                    ).tapForFailureEvidence()
                    print(
                        "Filter navigation action returned: entry=\(entryIdentifier); unixSeconds=\(Date().timeIntervalSince1970); actionSeconds=\(ProcessInfo.processInfo.systemUptime - startedAt)"
                    )
                })
        else {
            XCTFail(kind == "album" ? "Album filter page must open" : "Person filter page must open")
            return
        }
        let opened = transaction.until {
            let snapshots = app.evidenceSnapshotsByIdentifier()
            return snapshots["\(kind)Filter.back.button"] != nil || snapshots["\(kind)Filter.selectAll.button"] != nil
        }
        XCTAssertTrue(opened, kind == "album" ? "Album filter page must open" : "Person filter page must open")
    }

    @MainActor
    func openAlbumFilterFromEditor(app: XCUIApplication) {
        let entry = app.buttons["filter.editor.album.entry"]
        XCTAssertTrue(
            entry.waitForFailureEvidence(timeout: TestWait.seconds(.product(10))),
            "Filter editor must offer the album entry")
        tapElement(entry)
        _ = app.buttons["albumFilter.back.button"].waitForFailureEvidence(timeout: TestWait.seconds(.product(12)))
    }

    @MainActor
    func openPersonFilterFromEditor(app: XCUIApplication) {
        let entry = app.buttons["filter.editor.person.entry"]
        XCTAssertTrue(
            entry.waitForFailureEvidence(timeout: TestWait.seconds(.product(10))),
            "Filter editor must offer the person entry")
        tapElement(entry)
        _ = app.buttons["personFilter.back.button"].waitForFailureEvidence(timeout: TestWait.seconds(.product(12)))
    }

    @MainActor
    func selectAlbum(app: XCUIApplication, albumID: String) {
        let button = app.buttons["albumFilter.album.\(albumID).button"]
        XCTAssertTrue(
            button.waitForFailureEvidence(timeout: TestWait.seconds(.infrastructure(20))),
            "Album \(albumID) must appear")
        tapElement(button)
    }

    @MainActor
    func setAlbumSelection(app: XCUIApplication, albumID: String, isSelectionRequested: Bool) {
        let card = albumCard(app: app, albumID: albumID)
        XCTAssertTrue(
            card.waitForFailureEvidence(timeout: TestWait.seconds(.infrastructure(20))), "Album \(albumID) must appear")
        let deadline = Date().addingTimeInterval(TestWait.seconds(.product(12)))
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(12))) {
                if self.isSystemSavePasswordPromptVisible(app: app, deadline: deadline) {
                    _ = self.dismissSystemSavePasswordPromptIfPresent(
                        app: app, deadline: deadline)
                    return false
                }
                return card.exists && card.isHittable
            },
            "Album must be visible and hittable; state injection is no substitute"
        )
        if isAlbumCardSelected(card) != isSelectionRequested {
            guard dismissSystemSavePasswordPromptIfPresent(app: app, deadline: deadline), card.isHittable,
                Date() < deadline
            else {
                XCTFail("Before the tap, the album must still be visible and not covered by a system prompt")
                return
            }
            card.tapForFailureEvidence()
        }
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(6))) {
                self.isAlbumCardSelected(card) == isSelectionRequested
            },
            "Album \(albumID) must actually reach the requested selection state"
        )
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
    func isSystemSavePasswordPromptVisible(app: XCUIApplication, deadline: Date) -> Bool {
        IOSFirstBootNavigation(app: app).isPasswordPromptVisible(until: deadline)
    }

    @discardableResult
    @MainActor
    func dismissSystemSavePasswordPromptIfPresent(app: XCUIApplication, deadline: Date) -> Bool {
        IOSFirstBootNavigation(app: app).dismissPasswordPrompt(until: deadline)
    }

    @MainActor
    func personNameElement(app: XCUIApplication, personID: String) -> XCUIElement {
        // Public fixture names end in Synthetic; the cover, count and switch of the same card inherit
        // the same identifier.
        let names = app.staticTexts.matching(identifier: "personFilter.person.\(personID).button")
            // ui-label-lookup: Verify the public fixture person name after locating its card by identifier.
            .matching(NSPredicate(format: "label ENDSWITH %@", " Synthetic"))
        XCTAssertTrue(
            names.firstMatch.waitForFailureEvidence(timeout: TestWait.seconds(.infrastructure(20))),
            "The target public fixture person name must appear")
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
        let preparationDeadline = Date().addingTimeInterval(TestWait.seconds(.infrastructure(20)))
        let identifier = "personFilter.person.\(personID).button"
        let card = personNameElement(app: app, personID: personID)
        let toggle = personSoloOnlySwitch(app: app, personID: personID)
        let switchControl = toggle.switches.element(boundBy: 0)
        let navigation = IOSFirstBootNavigation(app: app)
        var isAlreadySelected = false
        var promptDeclines = 0
        var hasAppModal = false
        var isCardHittable = false
        var isPromptAmbiguous = false
        let isReady = Wait.until(timeout: max(.zero, preparationDeadline.timeIntervalSinceNow)) {
            guard Date() < preparationDeadline,
                let observation = try? navigation.observe(destinationIdentifier: identifier),
                Date() < preparationDeadline
            else { return false }
            hasAppModal = observation.hasModalObstacle && !observation.hasPasswordPrompt
            isPromptAmbiguous = observation.hasPromptClue && observation.decline == nil
            isCardHittable = false
            if observation.hasPasswordPrompt {
                _ = navigation.dismissPasswordPrompt(until: preparationDeadline) { promptDeclines += 1 }
                return false
            }
            guard !observation.hasModalObstacle else { return false }
            let switches = observation.nodes.filter {
                $0.identifier == identifier && $0.elementType == .switch
            }
            isAlreadySelected = switches.count == 1
            if isAlreadySelected { return Date() < preparationDeadline }
            guard switches.isEmpty, Date() < preparationDeadline else { return false }
            isCardHittable = card.wait(
                for: \.isHittable, toEqual: true,
                timeout: min(TestWait.seconds(.product(0.1)), max(.zero, preparationDeadline.timeIntervalSinceNow)))
            return isCardHittable && Date() < preparationDeadline
        }
        guard isReady else {
            XCTFail(
                "Person selection preparation must provide an actionable card; appModal=\(hasAppModal), cardHittable=\(isCardHittable), promptAmbiguous=\(isPromptAmbiguous)"
            )
            return
        }
        if !isAlreadySelected { card.tapForFailureEvidence() }
        let deadline = Date().addingTimeInterval(TestWait.seconds(.product(6)))
        var isOn = false
        let didSelect = Wait.until(timeout: max(.zero, deadline.timeIntervalSinceNow)) {
            guard Date() < deadline,
                let observation = try? navigation.observe(destinationIdentifier: identifier), Date() < deadline
            else { return false }
            if observation.hasPasswordPrompt {
                _ = navigation.dismissPasswordPrompt(until: deadline) { promptDeclines += 1 }
                return false
            }
            guard !observation.hasModalObstacle else { return false }
            let switches = observation.nodes.filter { $0.identifier == identifier && $0.elementType == .switch }
            guard switches.count == 1, let value = switches[0].value as? String, value == "0" || value == "1" else {
                return false
            }
            isOn = value == "1"
            if isSoloOnly == isOn { return Date() < deadline }
            guard switches[0].children.filter({ $0.elementType == .switch }).count == 1 else { return false }
            return switchControl.wait(
                for: \.isHittable, toEqual: true,
                timeout: min(TestWait.seconds(.product(0.1)), max(.zero, deadline.timeIntervalSinceNow)))
                && Date() < deadline
        }
        print(
            "Person selection: switchObserved=\(didSelect), cardTapCount=\(isAlreadySelected ? 0 : 1), promptDeclines=\(promptDeclines)"
        )
        guard didSelect else {
            XCTFail("Solo-only switch must appear after selecting the person")
            return
        }
        if isSoloOnly != isOn {
            // The identified parent includes the label; its child is the native switch control.
            switchControl.tapForFailureEvidence()
        }
        assertPersonNavigation(
            waitUntil(timeout: TestWait.seconds(.product(6))) { (toggle.value as? String) == (isSoloOnly ? "1" : "0") },
            "Target person's solo-only mode must reach the requested value", app: app, personID: personID)
    }

    @MainActor
    func returnFromAlbumFilter(app: XCUIApplication) {
        let back = app.buttons["albumFilter.back.button"]
        let deadline = Date().addingTimeInterval(TestWait.seconds(.product(8)))
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(8))) {
                guard IOSFirstBootNavigation(app: app).dismissPasswordPrompt(until: deadline) else { return false }
                return back.isHittable && Date() < deadline
            }, "Album filter must be able to go back"
        )
        tapElement(back)
    }

    @MainActor
    func returnFromPersonFilter(app: XCUIApplication) {
        let back = app.buttons["personFilter.back.button"]
        XCTAssertTrue(
            back.waitForFailureEvidence(timeout: TestWait.seconds(.product(8))),
            "Person filter must be able to go back")
        back.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tapForFailureEvidence()
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
        let returned = waitUntil(
            timeout: TestWait.seconds(.product(8)), condition: { self.isFilterSummaryVisible(app) })
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
