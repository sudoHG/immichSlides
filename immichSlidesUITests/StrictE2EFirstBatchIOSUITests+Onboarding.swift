import XCTest

#if os(iOS)
protocol StrictE2EOnboardingIOS: XCTestCase {}

extension StrictE2EFirstBatchIOSUITests {
    func requireBoundFailureScenario() -> String {
        let scenario = ProcessInfo.processInfo.environment["STRICT_E2E_INPUT_SCENARIO"] ?? ""
        let allowed = ["auth-401", "html-200", "unreachable", "timeout"]
        XCTAssertFalse(scenario.isEmpty, "A failing connection test must be bound to STRICT_E2E_INPUT_SCENARIO.")
        XCTAssertTrue(
            allowed.contains(scenario),
            "A failing connection test cannot bind \(scenario); only 401 / HTML 200 / unreachable / timeout."
        )
        return scenario
    }

    @MainActor
    func assertActionableFailure(in alert: XCUIElement, scenario: String) {
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let texts = ([alert.label] + alert.staticTexts.allElementsBoundByIndex.map(\.label))
            .joined(separator: " | ")
        switch scenario {
        case "auth-401":
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            XCTAssertTrue(
                texts.contains("API Key 无效") || texts.contains("服务器拒绝了这个 API Key"),
                "401 must show an actionable Key error, actual: \(texts)"
            )
        case "html-200":
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            XCTAssertTrue(
                texts.contains("不是 JSON") || texts.contains("填错了 Immich"),
                "HTML 200 must say the address/entry point is wrong, actual: \(texts)"
            )
        case "unreachable":
            // With a reserved port that nothing listens on plus waitsForConnectivity, the user sees a timeout
            // failure, not a permission wait.
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            XCTAssertTrue(
                texts.contains("网络请求失败")
                    && (texts.contains("请求超时") || texts.contains("超时") || texts.contains("无法连接")
                        || texts.contains("本地网络") || texts.contains("无线数据")),
                "Unreachable must show an actionable connection error, actual: \(texts)"
            )
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            XCTAssertFalse(
                texts.contains("API Key 无效") || texts.contains("不是 JSON"),
                "Unreachable must not pose as 401 or HTML 200."
            )
        case "timeout":
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            XCTAssertTrue(
                texts.contains("网络请求失败")
                    && (texts.contains("请求超时") || texts.contains("超时")
                        || texts.localizedCaseInsensitiveContains("timed out")),
                "Timeout must show an actionable timeout error, actual: \(texts)"
            )
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            XCTAssertFalse(
                texts.contains("API Key 无效") || texts.contains("不是 JSON"),
                "Timeout must not pose as 401 or HTML 200."
            )
        default:
            XCTFail("Unbound failure scenario: \(scenario)")
        }
    }

}

extension StrictE2EOnboardingIOS {
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
            "The first-boot page must show the Save Settings button."
        )
        XCTAssertTrue(
            waitForSaveEnabled(app: app, saveButton: saveButton, timeout: TestWait.seconds(.infrastructure(45))),
            "Save must become enabled after a real connection test succeeds."
        )
        attachStrictE2EScreenshot(app: app, name: "\(evidencePrefix)-connection-passed-\(currentDeviceTag())")
        tapElement(saveButton)
        XCTAssertTrue(
            app.buttons["mode.random.button"].waitForPublicElement(
                "mode.random.button", timeout: TestWait.seconds(.product(15))),
            "After a successful save, the app must reach mode selection."
        )
        XCTAssertTrue(app.buttons["mode.filtered.button"].exists, "The mode page must also offer the filter entry.")
        attachStrictE2EScreenshot(app: app, name: "\(evidencePrefix)-mode-selection-\(currentDeviceTag())")
    }

    @MainActor
    func fillFirstBootForm(app: XCUIApplication, input: StrictE2EInput) throws {
        let serverField = app.textFields["firstboot.serverURL.field"]
        if !serverField.waitForPublicElement(
            "firstboot.serverURL.field", timeout: TestWait.seconds(.infrastructure(20)))
        {
            attachStrictE2EScreenshot(app: app, name: "firstboot-missing-\(currentDeviceTag())")
            if app.buttons["slideshow.control.settings.button"].exists {
                XCTFail("Playback page after uninstall means a dirty install container; cannot continue manual entry.")
            } else {
                XCTFail("A fresh install must reach the normal first-boot page.")
            }
            return
        }
        replaceText(in: serverField, with: input.serverURL)
        XCTAssertEqual(
            serverField.value as? String,
            input.serverURL,
            "The public test URL must be entered verbatim, not guessed from a default value."
        )

        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(
            apiKeyField.waitForPublicElement("firstboot.apiKey.field", timeout: TestWait.seconds(.infrastructure(8))),
            "The first-boot page must show the API Key field.")
        replaceText(in: apiKeyField, with: input.publicKey)
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(3))) { self.hasSecureFieldEnteredValue(apiKeyField) },
            "API Key must reach the secure field; tapping blank space to hide the keyboard clears uncommitted input."
        )
        commitFocusedInputIfNeeded(app: app)
        attachStrictE2EScreenshot(app: app, name: "firstboot-form-filled-\(currentDeviceTag())")
    }

    @MainActor
    func tapTestConnection(app: XCUIApplication) {
        let testConnectionButton = firstBootControl(
            in: app,
            identifier: "firstboot.testConnection.button"
        )
        XCTAssertTrue(
            testConnectionButton.waitForFailureEvidence(timeout: TestWait.seconds(.infrastructure(8))),
            "The first-boot page must show the Test Connection button."
        )
        tapElement(testConnectionButton)
    }

}

extension StrictE2EFirstBatchIOSUITests {
    @MainActor
    func attachOrientationEvidence(app: XCUIApplication, name: String) {
        attachStrictE2EScreenshot(app: app, name: "\(name)-\(currentDeviceTag())")
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        FirstFailureOrientation.set(.landscapeLeft)
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.infrastructure(4))) { XCUIDevice.shared.orientation.isLandscape },
            "iPad must rotate to landscape to record split-view evidence."
        )
        attachStrictE2EScreenshot(app: app, name: "\(name)-ipad-landscape")
        FirstFailureOrientation.set(.portrait)
        _ = waitUntil(timeout: TestWait.seconds(.infrastructure(4))) { XCUIDevice.shared.orientation.isPortrait }
    }

    @MainActor
    func chooseOnboardingModeAndContinue(
        app: XCUIApplication,
        identifier: String,
        departureTimeout: TimeInterval = TestWait.seconds(.product(30))
    ) -> Date? {
        IOSFirstBootNavigation(app: app).selectModeAndContinue(
            identifier,
            destinationIdentifier: identifier == "mode.filtered.button"
                ? "filterSummary.startPlayback.button" : "slideshow.control.settings.button",
            selectionTimeout: TestWait.seconds(.product(8)) + TestWait.seconds(.product(2))
                + TestWait.seconds(.product(2)) + TestWait.seconds(.product(2)),
            departureTimeout: departureTimeout)
    }
}

extension StrictE2EOnboardingIOS {
    @MainActor
    func dismissSavePasswordPromptIfShown(app: XCUIApplication, deadline: Date) {
        _ = IOSFirstBootNavigation(app: app).dismissPasswordPrompt(until: deadline)
    }
}

extension StrictE2EFirstBatchIOSUITests {
    @MainActor
    func waitForFilterSummary(app: XCUIApplication, deadline: Date) {
        let reached = waitUntil(timeout: max(.zero, deadline.timeIntervalSinceNow)) {
            app.buttons["filterSummary.album.button"].exists
                || app.descendants(matching: .any)["filterSummary.album.button"].exists
                || app.staticTexts["filterSummary.page.title"].exists
        }
        if reached { return }
        attachStrictE2EScreenshot(app: app, name: "journey-b-filter-missing-\(currentDeviceTag())")
        if app.buttons["slideshow.control.settings.button"].exists {
            XCTFail("Chose filter but reached the playback page, so the mode card tap did not register.")
        } else if app.buttons["mode.random.button"].exists {
            XCTFail("Still on the mode page after Continue; filter mode did not start.")
        } else {
            XCTFail("Filter mode must reach the filter summary page.")
        }
    }

    // On iPhone the root back button under the safe area / wizard header often exists but is not hittable;
    // tapping its center coordinate hits the scroll layer.
    @MainActor
    func returnToModeSelectionFromFilterSummary(app: XCUIApplication) {
        let backButton = app.buttons["global.back.button"]
        XCTAssertTrue(
            backButton.waitForFailureEvidence(timeout: TestWait.seconds(.product(8))),
            "The first-boot filter summary must offer a way back to mode selection."
        )
        XCTAssertFalse(
            app.buttons["filterSummary.backToMode.button"].exists,
            "The iOS filter summary should no longer use a bottom back button, to avoid duplicating the second entry."
        )
        _ = app.staticTexts["filterSummary.page.title"].waitForFailureEvidence(timeout: TestWait.seconds(.product(4)))
        RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.6))))

        let offsets = [
            CGVector(dx: 0.20, dy: 0.20),
            CGVector(dx: 0.10, dy: 0.55),
            CGVector(dx: 0.35, dy: 0.80)
        ]
        for (attempt, offset) in offsets.enumerated() {
            if backButton.isHittable {
                backButton.tapForFailureEvidence()
            } else {
                backButton.coordinate(withNormalizedOffset: offset).tapForFailureEvidence()
            }
            if app.buttons["mode.random.button"].waitForPublicElement(
                "mode.random.button", timeout: TestWait.seconds(.product(5)))
            {
                return
            }
            attachStrictE2EScreenshot(app: app, name: "journey-b-back-retry-\(attempt)-\(currentDeviceTag())")
        }
        attachStrictE2EScreenshot(app: app, name: "journey-b-back-failed-\(currentDeviceTag())")
        XCTFail("Going back from the filter summary must return to mode selection.")
    }

    @MainActor
    func dismissPlaybackEntryHintIfNeeded(app: XCUIApplication) {
        let banner = app.descendants(matching: .any)["slideshow.entryHint.banner"]
        if banner.waitForFailureEvidence(timeout: TestWait.seconds(.product(2))) {
            tapElement(banner)
            _ = waitUntil(timeout: TestWait.seconds(.product(2))) { !banner.exists }
        }
    }

    @MainActor
    func waitForPlaybackControls(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) {
            let settings = app.evidenceSnapshotsByIdentifier()["slideshow.control.settings.button"]
            if let settings, settings.isEnabled, !settings.frame.isEmpty {
                return true
            }
            app.tapForFailureEvidence()
            return false
        }
    }

    @MainActor
    func captureHistoryIdentity(app: XCUIApplication, step: String) -> [String: Any] {
        RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.8))))
        revealPlaybackControlsWithoutWaitHelper(app: app)
        return captureStrictSceneFrame(app: app, name: step, attachmentName: step)
    }

    @MainActor
    func captureNamedPNG(app: XCUIApplication, name: String, capturedPNG: Data? = nil) -> Data {
        let png = capturedPNG ?? app.screenshotForFailureEvidence().pngRepresentation
        if !png.isEmpty {
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            StrictE2EVisualEvidence.writePNG(png, name: name)
        }
        return png
    }

    @MainActor
    func recordControlTimeline(app: XCUIApplication, event: String) {
        let snapshots = app.evidenceSnapshotsByIdentifier()
        let playPause = snapshots["slideshow.control.playPause.button"]
        let previous = snapshots["slideshow.control.previous.button"]
        // The probes only give an EXIF/asset cross-check; they cannot replace the in-repository visual identity
        // contract.
        let visibleImageProbe = snapshots["slideshow.currentAssetId.flag"]
        let smartFillProbe = snapshots["slideshow.smartfill.currentManifest.flag"]
        let payload: [String: Any] = [
            "event": event,
            "device": currentDeviceTag(),
            "firstboot_visible": snapshots["firstboot.serverURL.field"] != nil,
            "mode_visible": snapshots["mode.random.button"] != nil,
            "filter_summary_visible": snapshots["filterSummary.album.button"] != nil,
            "settings_visible": snapshots["slideshow.control.settings.button"] != nil,
            "previous_enabled": previous.map { $0.isEnabled as Any } ?? "notVisible",
            "play_pause": playPause.map { playPauseState($0) } ?? "notVisible",
            "visible_image_asset_id": visibleImageProbe?.label ?? "notVisible",
            "smartfill_manifest": smartFillProbe?.label ?? "notVisible"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        else {
            return
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "strict-e2e-control-timeline-\(event)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func capturePauseStage(app: XCUIApplication, stage: String) -> [String: Any] {
        let uptime = ProcessInfo.processInfo.systemUptime
        let snapshots = app.evidenceSnapshotsByIdentifier()
        let playPause = snapshots["slideshow.control.playPause.button"]
        let settings = snapshots["slideshow.control.settings.button"]
        let previous = snapshots["slideshow.control.previous.button"]
        let next = snapshots["slideshow.control.next.button"]
        let visibleImageAssetId = snapshots["slideshow.currentAssetId.flag"]?.label ?? "notVisible"
        let originalConditionNote: String
        if visibleImageAssetId == "asset-a-2" {
            originalConditionNote = ""
        } else if visibleImageAssetId.isEmpty || visibleImageAssetId == "notVisible" {
            originalConditionNote = "Original condition not covered: probe gave no asset id; identify by screenshot"
        } else {
            originalConditionNote = "Original condition not covered: probe is not A2 (\(visibleImageAssetId))"
        }

        let payload: [String: Any] = [
            "stage": stage,
            "system_uptime": uptime,
            "device": currentDeviceTag(),
            "play_pause_exists": playPause != nil,
            "play_pause_enabled": playPause.map { $0.isEnabled as Any } ?? "notVisible",
            "play_pause": playPause.map { playPauseState($0) } ?? "notVisible",
            "settings_exists": settings != nil,
            "settings_enabled": settings.map { $0.isEnabled as Any } ?? "notVisible",
            "previous_exists": previous != nil,
            "previous_enabled": previous.map { $0.isEnabled as Any } ?? "notVisible",
            "next_exists": next != nil,
            "next_enabled": next.map { $0.isEnabled as Any } ?? "notVisible",
            "visible_image_asset_id": visibleImageAssetId,
            "original_a2_condition_note": originalConditionNote
        ]

        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "pause-stage-\(stage)-\(currentDeviceTag())"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        attachStrictE2EScreenshot(app: app, name: "pause-stage-\(stage)-\(currentDeviceTag())")
        return payload
    }

    func attachPauseStageTimeline(_ stages: [[String: Any]]) {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: ["stages": stages],
                options: [.prettyPrinted, .sortedKeys]
            )
        else {
            return
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "pause-stage-timeline"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}

extension StrictE2EOnboardingIOS {
    func playPauseState(_ button: XCUIElementAttributes) -> String {
        ((button.value as? String) ?? "").lowercased()
    }

    func currentDeviceTag() -> String {
        let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let orientation = XCUIDevice.shared.orientation.isLandscape ? "landscape" : "portrait"
        return "\(idiom)-\(orientation)"
    }

    func replaceText(in field: XCUIElement, with value: String) {
        field.tapForFailureEvidence()
        let existingValue = field.value as? String ?? ""
        let looksLikePlaceholder =
            existingValue.contains("请输入") || existingValue.localizedCaseInsensitiveContains("enter")
        if !existingValue.isEmpty && !looksLikePlaceholder {
            field.typeForFailureEvidence(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existingValue.count))
        }
        field.typeForFailureEvidence(value)
    }

    func hasSecureFieldEnteredValue(_ field: XCUIElement) -> Bool {
        let value = field.value as? String ?? ""
        return !value.isEmpty && !value.contains("请输入") && !value.localizedCaseInsensitiveContains("api key")
    }

    func commitFocusedInputIfNeeded(app: XCUIApplication) {
        // ui-label-lookup: Match the simulator-localized system keyboard action.
        for label in ["完成", "Done", "next", "Next"] {
            // ui-label-lookup: System keyboard keys follow the simulator language.
            let keyboardButton = app.keyboards.buttons[label]
            if keyboardButton.exists && keyboardButton.isHittable {
                keyboardButton.tapForFailureEvidence()
                return
            }
            let accessory = app.buttons["server.keyboard.done.button"]
            if accessory.exists && accessory.isHittable && accessory.identifier != "firstboot.saveConfig.button" {
                accessory.tapForFailureEvidence()
                return
            }
        }
    }

    func waitForSaveEnabled(
        app: XCUIApplication,
        saveButton: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            acceptLocalNetworkPermissionIfNeeded()
            if saveButton.exists && saveButton.isEnabled {
                return true
            }
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            let alert = app.alerts.firstMatch
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            if alert.exists {
                // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
                let details = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
                XCTFail("Connection test showed a failure alert: \(alert.label) | \(details)")
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.2))))
        }
        return saveButton.exists && saveButton.isEnabled
    }

    func acceptLocalNetworkPermissionIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // ui-label-lookup: Dismiss the simulator-owned local network permission prompt.
        for label in ["允许", "Allow"] {
            // ui-label-lookup: The permission action belongs to SpringBoard.
            let button = springboard.alerts.buttons[label]
            if button.exists {
                button.tapForFailureEvidence()
                return
            }
        }
    }

    func dismissFirstAlertIfNeeded(app: XCUIApplication) {
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        let alert = app.alerts.firstMatch
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        guard alert.exists else { return }
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        for label in ["好", "确定", "OK", "关闭"] {
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            let button = alert.buttons[label]
            if button.exists {
                button.tapForFailureEvidence()
                return
            }
        }
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        if alert.buttons.count > 0 {
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            alert.buttons.element(boundBy: 0).tapForFailureEvidence()
        }
    }

    func firstBootControl(
        in app: XCUIApplication,
        identifier: String
    ) -> XCUIElement {
        FirstFailureContext.mark("query-element", element: identifier)
        let button = app.buttons[identifier]
        if button.exists { return button }
        let identifiedElement = app.descendants(matching: .any)[identifier]
        return identifiedElement
    }

    func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tapForFailureEvidence()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tapForFailureEvidence()
        }
    }

    func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        FirstFailureContext.beginWait(seconds: timeout)
        defer { FirstFailureContext.endWait() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.1))))
        }
        return condition()
    }
}
#endif
