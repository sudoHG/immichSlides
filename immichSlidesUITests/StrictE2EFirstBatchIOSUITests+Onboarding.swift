import XCTest

#if os(iOS)
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
            saveButton.waitForExistence(timeout: 8),
            "The first-boot page must show the Save Settings button."
        )
        XCTAssertTrue(
            waitForSaveEnabled(app: app, saveButton: saveButton, timeout: 45),
            "Save must become enabled after a real connection test succeeds."
        )
        attachStrictE2EScreenshot(app: app, name: "\(evidencePrefix)-connection-passed-\(currentDeviceTag())")
        tapElement(saveButton)
        XCTAssertTrue(
            app.buttons["mode.random.button"].waitForExistence(timeout: 15),
            "After a successful save, the app must reach mode selection."
        )
        XCTAssertTrue(app.buttons["mode.filtered.button"].exists, "The mode page must also offer the filter entry.")
        attachStrictE2EScreenshot(app: app, name: "\(evidencePrefix)-mode-selection-\(currentDeviceTag())")
    }

    @MainActor
    func fillFirstBootForm(app: XCUIApplication, input: StrictE2EInput) throws {
        let serverField = app.textFields["firstboot.serverURL.field"]
        if !serverField.waitForExistence(timeout: 20) {
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
        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 8), "The first-boot page must show the API Key field.")
        replaceText(in: apiKeyField, with: input.publicKey)
        XCTAssertTrue(
            waitUntil(timeout: 3) { self.hasSecureFieldEnteredValue(apiKeyField) },
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
            testConnectionButton.waitForExistence(timeout: 8),
            "The first-boot page must show the Test Connection button."
        )
        tapElement(testConnectionButton)
    }

    @MainActor
    func attachOrientationEvidence(app: XCUIApplication, name: String) {
        attachStrictE2EScreenshot(app: app, name: "\(name)-\(currentDeviceTag())")
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(
            waitUntil(timeout: 4) { XCUIDevice.shared.orientation.isLandscape },
            "iPad must rotate to landscape to record split-view evidence."
        )
        attachStrictE2EScreenshot(app: app, name: "\(name)-ipad-landscape")
        XCUIDevice.shared.orientation = .portrait
        _ = waitUntil(timeout: 4) { XCUIDevice.shared.orientation.isPortrait }
    }

    @MainActor
    func chooseOnboardingModeAndContinue(
        app: XCUIApplication,
        identifier: String
    ) {
        let modeButton = firstBootControl(in: app, identifier: identifier)
        XCTAssertTrue(modeButton.waitForExistence(timeout: 8), "The mode page must offer \(identifier).")
        let continueButton = firstBootControl(
            in: app,
            identifier: "mode.continue.button"
        )
        // First boot preselects random, so Continue is enabled from the start; isEnabled does not mean the
        // filter mode is selected.
        _ = waitUntil(timeout: 2) { continueButton.exists && continueButton.isEnabled }
        if !isOnboardingModeSelected(modeButton) {
            modeButton.tap()
        }
        if !waitUntil(timeout: 2, condition: { self.isOnboardingModeSelected(modeButton) }) {
            modeButton.tap()
            _ = waitUntil(timeout: 2, condition: { self.isOnboardingModeSelected(modeButton) })
        }
        // A late system "Save Password?" prompt, shown in the simulator's language, can swallow the
        // Continue tap. Dismiss it with Not Now only, so the test credential is never saved, and tap
        // Continue again while the mode page is still showing.
        for _ in 0..<3 {
            dismissSavePasswordPromptIfShown(app: app)
            guard continueButton.exists else { return }
            if continueButton.isHittable {
                continueButton.tap()
            }
            let settled = waitUntil(timeout: 4) {
                !continueButton.exists || self.isSavePasswordPromptShown(app: app)
            }
            if settled && !continueButton.exists {
                return
            }
        }
    }

    @MainActor
    func isSavePasswordPromptShown(app: XCUIApplication) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        return [app, springboard].contains { host in
            // ui-label-lookup: Detect the simulator-owned Save Password prompt.
            ["以后", "Not Now"].contains { host.buttons[$0].exists }
        }
    }

    @MainActor
    func dismissSavePasswordPromptIfShown(app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for host in [app, springboard] {
            // ui-label-lookup: Dismiss the simulator-owned Save Password prompt with Not Now.
            for label in ["以后", "Not Now"] where host.buttons[label].exists {
                // ui-label-lookup: Dismiss the system Save Password sheet without saving credentials.
                host.buttons[label].tap()
                _ = waitUntil(timeout: 2) { !self.isSavePasswordPromptShown(app: app) }
                return
            }
        }
    }

    @MainActor
    func isOnboardingModeSelected(_ modeButton: XCUIElement) -> Bool {
        modeButton.isSelected || modeButton.images["checkmark.circle.fill"].exists
    }

    @MainActor
    func waitForFilterSummary(app: XCUIApplication) {
        let reached = waitUntil(timeout: 20) {
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
            backButton.waitForExistence(timeout: 8),
            "The first-boot filter summary must offer a way back to mode selection."
        )
        XCTAssertFalse(
            app.buttons["filterSummary.backToMode.button"].exists,
            "The iOS filter summary should no longer use a bottom back button, to avoid duplicating the second entry."
        )
        _ = app.staticTexts["filterSummary.page.title"].waitForExistence(timeout: 4)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        let offsets = [
            CGVector(dx: 0.20, dy: 0.20),
            CGVector(dx: 0.10, dy: 0.55),
            CGVector(dx: 0.35, dy: 0.80)
        ]
        for (attempt, offset) in offsets.enumerated() {
            if backButton.isHittable {
                backButton.tap()
            } else {
                backButton.coordinate(withNormalizedOffset: offset).tap()
            }
            if app.buttons["mode.random.button"].waitForExistence(timeout: 5) {
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
        if banner.waitForExistence(timeout: 2) {
            tapElement(banner)
            _ = waitUntil(timeout: 2) { !banner.exists }
        }
    }

    @MainActor
    func waitForPlaybackControls(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) {
            let settings = app.buttons["slideshow.control.settings.button"]
            if settings.exists && settings.isHittable {
                return true
            }
            app.tap()
            return false
        }
    }

    // String? ?? NSNull() has no common type and cannot go into the array; upcast to Any? first to get JSON null.
    func jsonSafeMarks(_ marks: [String?]) -> [Any] {
        marks.map { $0 as Any? ?? NSNull() }
    }

    @MainActor
    func captureHistoryIdentity(app: XCUIApplication, step: String) -> StrictE2EPhotoIdentity.Result {
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        revealPlaybackControlsWithoutWaitHelper(app: app)
        let png = captureNamedPNG(app: app, name: step)
        let identity = StrictE2EPhotoIdentity.classify(png: png)
        XCTAssertEqual(
            identity.status,
            .match,
            "Visual ID failed \(step): \(identity.status.rawValue) \(identity.notes.joined(separator: " "))"
        )
        return identity
    }

    @MainActor
    func captureNamedPNG(app: XCUIApplication, name: String) -> Data {
        let png = app.screenshot().pngRepresentation
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
        let playPause = app.buttons["slideshow.control.playPause.button"]
        let previous = app.buttons["slideshow.control.previous.button"]
        // The probes only give an EXIF/asset cross-check; they cannot replace the in-repository visual identity
        // contract.
        let visibleImageProbe = app.descendants(matching: .any)["slideshow.currentAssetId.flag"]
        let smartFillProbe = app.descendants(matching: .any)["slideshow.smartfill.currentManifest.flag"]
        let payload: [String: Any] = [
            "event": event,
            "device": currentDeviceTag(),
            "firstboot_visible": app.textFields["firstboot.serverURL.field"].exists,
            "mode_visible": app.buttons["mode.random.button"].exists,
            "filter_summary_visible": app.buttons["filterSummary.album.button"].exists,
            "settings_visible": app.buttons["slideshow.control.settings.button"].exists,
            "previous_enabled": previous.exists ? previous.isEnabled : false,
            "play_pause": playPause.exists ? playPauseState(playPause) : "",
            "visible_image_asset_id": visibleImageProbe.exists ? visibleImageProbe.label : "",
            "smartfill_manifest": smartFillProbe.exists ? smartFillProbe.label : ""
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
        let playPause = app.buttons["slideshow.control.playPause.button"]
        let settings = app.buttons["slideshow.control.settings.button"]
        let previous = app.buttons["slideshow.control.previous.button"]
        let next = app.buttons["slideshow.control.next.button"]
        let hasPlayPauseControl = playPause.exists
        let hasSettingsControl = settings.exists
        let hasPreviousControl = previous.exists
        let hasNextControl = next.exists
        let visibleImageProbe = app.descendants(matching: .any)["slideshow.currentAssetId.flag"]
        let visibleImageAssetId = visibleImageProbe.exists ? visibleImageProbe.label : ""
        let originalConditionNote: String
        if visibleImageAssetId == "asset-a-2" {
            originalConditionNote = ""
        } else if visibleImageAssetId.isEmpty {
            originalConditionNote = "Original condition not covered: probe gave no asset id; identify by screenshot"
        } else {
            originalConditionNote = "Original condition not covered: probe is not A2 (\(visibleImageAssetId))"
        }

        let payload: [String: Any] = [
            "stage": stage,
            "system_uptime": uptime,
            "device": currentDeviceTag(),
            "play_pause_exists": hasPlayPauseControl,
            "play_pause_hittable": hasPlayPauseControl && playPause.isHittable,
            "play_pause": hasPlayPauseControl ? playPauseState(playPause) : "",
            "settings_exists": hasSettingsControl,
            "settings_hittable": hasSettingsControl && settings.isHittable,
            "previous_exists": hasPreviousControl,
            "previous_hittable": hasPreviousControl && previous.isHittable,
            "next_exists": hasNextControl,
            "next_hittable": hasNextControl && next.isHittable,
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

    func playPauseState(_ button: XCUIElement) -> String {
        ((button.value as? String) ?? "").lowercased()
    }

    func currentDeviceTag() -> String {
        let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let orientation = XCUIDevice.shared.orientation.isLandscape ? "landscape" : "portrait"
        return "\(idiom)-\(orientation)"
    }

    func replaceText(in field: XCUIElement, with value: String) {
        field.tap()
        let existingValue = field.value as? String ?? ""
        let looksLikePlaceholder =
            existingValue.contains("请输入") || existingValue.localizedCaseInsensitiveContains("enter")
        if !existingValue.isEmpty && !looksLikePlaceholder {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existingValue.count))
        }
        field.typeText(value)
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
                keyboardButton.tap()
                return
            }
            let accessory = app.buttons["server.keyboard.done.button"]
            if accessory.exists && accessory.isHittable && accessory.identifier != "firstboot.saveConfig.button" {
                accessory.tap()
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
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
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
                button.tap()
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
                button.tap()
                return
            }
        }
        // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
        if alert.buttons.count > 0 {
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            alert.buttons.element(boundBy: 0).tap()
        }
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

    func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}
#endif
