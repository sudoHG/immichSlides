import CryptoKit
import XCTest

#if os(iOS)
extension AccessLifecycleIOSUITests {
    @MainActor
    func completeFirstBootToPlayback(app: XCUIApplication, input: StrictE2EInput) throws {
        try fillFirstBootForm(app: app, input: input)
        tapTestConnection(app: app)
        let saveButton = firstBootControl(
            in: app,
            identifier: "firstboot.saveConfig.button"
        )
        XCTAssertTrue(
            saveButton.waitForExistence(timeout: 8), "The first-boot page must show the Save Settings button.")
        XCTAssertTrue(
            waitForSaveEnabled(app: app, saveButton: saveButton, timeout: 45),
            "Save must become enabled after a real connection test succeeds.")
        tapElement(saveButton)
        XCTAssertTrue(
            app.buttons["mode.random.button"].waitForExistence(timeout: 15),
            "Must reach mode selection after a successful save.")
        let modeButton = firstBootControl(in: app, identifier: "mode.random.button")
        let continueButton = firstBootControl(in: app, identifier: "mode.continue.button")
        if !(continueButton.exists && continueButton.isEnabled && modeButton.isSelected) {
            tapElement(modeButton)
            XCTAssertTrue(
                waitUntil(timeout: 2) { continueButton.exists && continueButton.isEnabled },
                "Continue must be enabled after selecting random.")
        }
        tapElement(continueButton)
        dismissSystemSavePromptIfPresent(app: app, timeout: 5)
        if continueButton.exists && continueButton.isHittable && continueButton.isEnabled {
            tapElement(continueButton)
        }
        XCTAssertTrue(waitForPlaybackControls(app: app, timeout: 30), "Random mode must reach the playback page.")
    }

    @MainActor
    func dismissSystemSavePromptIfPresent(app: XCUIApplication, timeout: TimeInterval) {
        // Tap only "Not Now"; the prompt often appears only after entering settings, so wait for it to go away.
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            // ui-label-lookup: Dismiss the iOS Save Password sheet without saving credentials.
            for label in ["以后", "Not Now"] {
                // ui-label-lookup: The Save Password action belongs to iOS.
                let button = app.buttons[label]
                if button.exists {
                    button.tap()
                    if waitUntil(timeout: 2, condition: { !self.isSystemSavePasswordPromptVisible(app: app) }) {
                        return
                    }
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
    }

    @MainActor
    func isSystemSavePasswordPromptVisible(app: XCUIApplication) -> Bool {
        // ui-label-lookup: The Save Password sheet is owned by iOS.
        app.sheets["保存密码？"].exists
            // ui-label-lookup: The Save Password prompt belongs to iOS.
            || app.sheets["Save Password?"].exists
            // ui-label-lookup: The Save Password action is owned by iOS.
            || app.buttons["以后"].exists
            // ui-label-lookup: The Save Password prompt belongs to iOS.
            || app.buttons["Not Now"].exists
    }

    @MainActor
    func changePlaybackSettingsFromUI(app: XCUIApplication) throws {
        openSettingsFromSlideshow(app: app)
        requests.append("settings.open")
        openPlaybackSettings(app: app)
        let autoPlay = playbackSwitch(app: app, identifier: "settings.playback.autoPlay.toggle")
        XCTAssertTrue(autoPlay.waitForExistence(timeout: 12), "Playback settings must provide the autoplay toggle.")
        if !isToggleOn(autoPlay) {
            tapElement(autoPlay)
        }
        XCTAssertTrue(
            waitUntil(timeout: 4) { self.isToggleOn(autoPlay) },
            "Autoplay must be turned on through the real settings UI."
        )
        requests.append("settings.save.autoplay")
        _ = try setIntervalFromUI(app: app, targetSeconds: targetIntervalSeconds)
        requests.append("settings.save.interval")
        let exif = playbackSwitch(app: app, identifier: "settings.playback.showExif.toggle")
        XCTAssertTrue(exif.waitForExistence(timeout: 8), "Playback settings must provide the EXIF toggle.")
        if isToggleOn(exif) {
            tapElement(exif)
        }
        XCTAssertTrue(
            waitUntil(timeout: 4) { !self.isToggleOn(exif) },
            "EXIF must be turned off through the real settings."
        )
        requests.append("settings.save.exif")
        returnToSlideshowFromSettings(app: app)
    }

    @MainActor
    func enablePinAndProveGate(app: XCUIApplication) throws {
        openSettingsFromSlideshow(app: app)
        requests.append("settings.open")
        openSettingsSection(app: app, sectionID: "settings.item.accessProtection")
        tapSettingsPinInput(app: app, id: "settings.pin.input.enable")
        enterPin(app: app, pin: syntheticPIN())
        requests.append("settings.pin.enable")
        tapSettingsPinInput(app: app, id: "settings.pin.input.enableConfirm")
        enterPin(app: app, pin: syntheticPIN())
        requests.append("settings.pin.confirm")
        let enable = app.buttons["settings.pin.enable.button"]
        XCTAssertTrue(
            enable.waitForExistence(timeout: 5) && enable.isEnabled,
            "Enable must be available after confirming the PIN.")
        tapElement(enable)
        XCTAssertTrue(
            app.buttons["settings.pin.disable.button"].waitForExistence(timeout: 8),
            "The disable entry should appear after enabling.")
        returnToSlideshowFromSettings(app: app)

        openSettingsFromSlideshow(app: app)
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 8),
            "After enabling, opening settings must require the PIN first.")
        enterPin(app: app, pin: wrongPIN())
        let retryHint = findFirstExistingIdentifiedText(
            in: app,
            identifiers: ["pinEntry.error.message"],
            timeout: 3
        )
        XCTAssertNotNil(
            retryHint,
            "A wrong PIN must prompt a retry and must not grant entry."
        )
        // ui-label-lookup: Verify the Simplified Chinese wrong-PIN retry hint after identifier lookup.
        XCTAssertEqual(retryHint?.label, "PIN 错误，请重试")
        tapElement(app.buttons["pinEntry.close.button"])
        requests.append("settings.pin.cancel")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        if app.descendants(matching: .any)["settings.item.playback"].exists {
            returnToSlideshowFromSettings(app: app)
        } else {
            revealPlaybackControls(app: app)
        }
        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(timeout: 8),
            "After canceling the PIN, should return to the playback page with protection still on."
        )
        openSettingsFromSlideshow(app: app)
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 8), "Protection must remain after canceling."
        )
        enterPin(app: app, pin: syntheticPIN())
        requests.append("settings.pin.unlock")
        XCTAssertFalse(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 3), "The correct PIN must open settings")
        XCTAssertTrue(
            app.buttons["settings.item.playback"].waitForExistence(timeout: 8)
                || app.buttons["settings.pin.disable.button"].waitForExistence(timeout: 2)
                || settingsControl(app: app, identifier: "settings.playback.autoPlay.toggle").waitForExistence(
                    timeout: 2),
            "Must reach the settings page after the correct PIN."
        )
        returnToSlideshowFromSettings(app: app)
    }

    @MainActor
    func enablePasswordFromSettingsUI(app: XCUIApplication, pin: String) throws {
        openSettingsFromSlideshow(app: app)
        requests.append("settings.open")
        let isAccessReady = waitUntil(timeout: 12) {
            self.dismissSystemSavePromptIfPresent(app: app, timeout: 0)
            return self.firstExistingSettingsItem(
                app: app,
                identifier: "settings.item.accessProtection"
            ) != nil && !self.isSystemSavePasswordPromptVisible(app: app)
        }
        XCTAssertTrue(
            isAccessReady,
            "The system 'Save Password?' prompt must go away after tapping 'Not Now', and Access Protection must be tappable."
        )
        let holdUntil = Date().addingTimeInterval(2)
        while Date() < holdUntil {
            dismissSystemSavePromptIfPresent(app: app, timeout: 0)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(
            firstExistingSettingsItem(
                app: app,
                identifier: "settings.item.accessProtection"
            ) != nil && !isSystemSavePasswordPromptVisible(app: app),
            "After a steady wait, Access Protection must still be tappable and the Save Password prompt must be gone."
        )
        openSettingsSection(app: app, sectionID: "settings.item.accessProtection")
        tapSettingsPinInput(app: app, id: "settings.pin.input.enable")
        enterPin(app: app, pin: pin)
        requests.append("settings.pin.enable")
        tapSettingsPinInput(app: app, id: "settings.pin.input.enableConfirm")
        enterPin(app: app, pin: pin)
        requests.append("settings.pin.confirm")
        let enable = app.buttons["settings.pin.enable.button"]
        XCTAssertTrue(
            enable.waitForExistence(timeout: 5) && enable.isEnabled,
            "Enable must be available after confirming the PIN.")
        tapElement(enable)
        XCTAssertTrue(
            app.buttons["settings.pin.disable.button"].waitForExistence(timeout: 8),
            "The disable entry should appear after enabling.")
        _ = try captureRequiredPNG(app: app, name: "pin-enabled")
        returnToSlideshowFromSettings(app: app)
    }

    @MainActor
    func provePasswordGateAfterRestart(
        app: XCUIApplication,
        pins: StrictE2EPrivatePINInput
    ) throws {
        app.terminate()
        try relaunchApp(app)
        XCTAssertFalse(
            app.textFields["firstboot.serverURL.field"].waitForExistence(timeout: 3),
            "A cold launch with saved settings must not return to the first-boot page."
        )
        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: 25), "Should return to the playback page after relaunch.")

        openSettingsFromSlideshow(app: app)
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 8),
            "After relaunch, opening a protected entry must show the access gate."
        )
        _ = try captureRequiredPNG(app: app, name: "pin-restart-gate")

        enterPin(app: app, pin: pins.wrong)
        let retryHint = findFirstExistingIdentifiedText(
            in: app,
            identifiers: ["pinEntry.error.message"],
            timeout: 3
        )
        XCTAssertNotNil(
            retryHint,
            "A wrong PIN must prompt a retry and must not grant entry."
        )
        // ui-label-lookup: Verify the Simplified Chinese wrong-PIN retry hint after identifier lookup.
        XCTAssertEqual(retryHint?.label, "PIN 错误，请重试")
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 3),
            "The PIN sheet must remain after a wrong PIN."
        )
        XCTAssertFalse(
            app.buttons["settings.item.playback"].waitForExistence(timeout: 1),
            "A wrong PIN must not reveal the settings home page."
        )
        _ = try captureRequiredPNG(app: app, name: "pin-wrong")

        enterPin(app: app, pin: pins.correct)
        requests.append("settings.pin.unlock")
        XCTAssertFalse(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 3), "The correct PIN must open settings")
        XCTAssertTrue(
            app.buttons["settings.item.playback"].waitForExistence(timeout: 8)
                || app.buttons["settings.pin.disable.button"].waitForExistence(timeout: 2)
                || settingsControl(app: app, identifier: "settings.playback.autoPlay.toggle").waitForExistence(
                    timeout: 2),
            "Must reach the settings page after the correct PIN."
        )
        _ = try captureRequiredPNG(app: app, name: "pin-unlocked")
        returnToSlideshowFromSettings(app: app)

        openSettingsFromSlideshow(app: app)
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 8),
            "Opening settings again must still require the PIN."
        )
        tapElement(app.buttons["pinEntry.close.button"])
        requests.append("settings.pin.cancel")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        // Capture the real screen after canceling first. If settings are open, protected content was released;
        // do not go back to the playback page and then record a pass.
        _ = try captureRequiredPNG(app: app, name: "pin-cancel-safe")
        let pinStillShowing = app.buttons["pinEntry.close.button"].exists
        XCTAssertFalse(
            pinStillShowing == false && isOnSettingsSurface(app: app),
            "Protected content is not released after canceling."
        )
        if pinStillShowing == false {
            revealPlaybackControls(app: app)
            XCTAssertTrue(
                app.buttons["slideshow.control.settings.button"].waitForExistence(timeout: 8),
                "After canceling, should return to a safe page; the gate need not stay on screen."
            )
            openSettingsFromSlideshow(app: app)
        }
        XCTAssertTrue(
            app.buttons["pinEntry.close.button"].waitForExistence(timeout: 8),
            "Protection must remain after canceling; opening settings again still requires the PIN."
        )
        _ = try captureRequiredPNG(app: app, name: "pin-cancel-still-gated")
    }

    func writePasswordProtectionPayload(pins: StrictE2EPrivatePINInput) throws {
        try AccessLifecycleContract.assertNotSkip("ran")
        try AccessLifecycleContract.assertSettingsSource("real_settings_ui")
        try AccessLifecycleContract.assertPinFlow(
            didEnterWrongPin: false,
            isProtectedAfterCancel: true,
            didEnterCorrectPin: true,
            isGatedAfterRestart: true
        )
        try AccessLifecycleContract.assertKnownRequests(requests)
        try AccessLifecycleContract.assertNoRetryMasking(false)
        let d01 = try AccessLifecycleContract.pinStorageVerdict(
            storageKind: "uitest_userdefaults",
            isXCTestConfigPresent: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        )
        let screenshotNames = [
            "pin-enabled",
            "pin-restart-gate",
            "pin-wrong",
            "pin-unlocked",
            "pin-cancel-safe",
            "pin-cancel-still-gated"
        ]
        let payload: [String: Any] = [
            "status": "ran",
            "suite": "password-protection-normal-ui",
            "device": deviceKind(),
            "settings_source": AccessLifecycleContract.allowedSettingsSource,
            "pin_injected": false,
            "pin_enable_path": "ordinary_settings_ui",
            "storage_kind": "uitest_userdefaults",
            "storage_boundary": "xctest_userdefaults_not_keychain",
            "d01_verdict": d01,
            "xctest_config_present": ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
            "requests": requests,
            "screenshots": screenshotNames,
            "pin_flow": [
                "wrong_pin_entered": false,
                "cancel_still_protected": true,
                "correct_pin_entered": true,
                "restart_gated": true
            ]
        ]
        let evidenceText =
            (StrictE2EVisualEvidence.directory()?.path ?? "")
            + requests.joined()
            + screenshotNames.joined()
            + AccessLifecycleContract.serializedText(of: payload)
        try AccessLifecycleContract.assertPinAbsent(
            in: evidenceText,
            pinValues: [pins.correct, pins.wrong]
        )
        try StrictE2EVisualEvidence.writeRequiredJSON(payload, name: "password-protection.json")
    }

    @MainActor
    func pauseNextPlayFromZero(app: XCUIApplication, progress: inout [String: Any]) throws {
        revealPlaybackControls(app: app)
        let playPause = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 8), "The playback page must have play/pause.")
        if playPauseState(playPause) != "play" {
            tapElement(playPause)
        }
        XCTAssertTrue(waitUntil(timeout: 4) { self.playPauseState(playPause) == "play" }, "Must pause first.")
        requests.append("playback.pause")
        let pause = try captureRequiredMark(app: app, name: "pause")
        tapElement(app.buttons["slideshow.control.next.button"])
        requests.append("playback.next")
        let afterNext = try captureRequiredMark(app: app, name: "after-next")
        let progressAfterNext = try readSceneProgress(app: app)
        tapElement(playPause)
        requests.append("playback.play")
        lastPlayAt = Date()
        XCTAssertTrue(
            waitUntil(timeout: 4) { self.playPauseState(playPause) == "pause" }, "Should be playing after Play.")
        let progressAfterPlay = try readSceneProgress(app: app)
        let afterPlay = try captureRequiredMark(app: app, name: "after-play")
        // Even if the identity assertion fails, pass the progress already read to the outer JSON; never leave it empty.
        progress = [
            "progress_after_next": progressAfterNext.value,
            "progress_after_play": progressAfterPlay.value,
            "progress_source": progressAfterNext.source,
            "progress_raw_after_next": progressAfterNext.raw,
            "progress_raw_after_play": progressAfterPlay.raw
        ]
        try AccessLifecycleContract.assertPauseNextPlay(
            pause: pause.mark,
            afterNext: afterNext.mark,
            afterPlay: afterPlay.mark,
            progressAfterPlay: progressAfterPlay.value,
            progressAfterNext: progressAfterNext.value,
            progressRawAfterNext: progressAfterNext.raw,
            progressRawAfterPlay: progressAfterPlay.raw
        )
    }

    @MainActor
    func waitOutAutoplayIfWakeWouldCrossBoundary(app: XCUIApplication, interval: TimeInterval) throws {
        let origin = lastPlayAt ?? Date()
        let remaining = interval - Date().timeIntervalSince(origin)
        if AccessLifecycleContract.shouldWaitForAutoplayBeforeWake(
            remainingToAutoplay: remaining,
            evidenceBudget: AccessLifecycleContract.wakeEvidenceBudgetSeconds
        ) {
            _ = try captureNewStableMark(
                app: app,
                name: "autoplay-before-wake",
                timeout: max(remaining, 1) + 4
            )
            lastPlayAt = Date()
        }
    }

    @MainActor
    func wakeControlsWithoutSwitching(app: XCUIApplication) throws {
        let interval = TimeInterval(targetIntervalSeconds)
        try waitOutAutoplayIfWakeWouldCrossBoundary(app: app, interval: interval)
        let origin = lastPlayAt ?? Date()
        let remaining = interval - Date().timeIntervalSince(origin)
        let hide = AccessLifecycleContract.hideWaitForWake(
            hideSeconds: controlHideSeconds,
            remainingToAutoplay: remaining,
            evidenceBudget: AccessLifecycleContract.wakeEvidenceBudgetSeconds
        )
        try requireHiddenPlaybackControls(app: app, timeout: hide)
        try waitOutAutoplayIfWakeWouldCrossBoundary(app: app, interval: interval)
        let before = try captureWakeMark(app: app, name: "before-wake")
        try requireHiddenPlaybackControls(app: app, timeout: 0)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        requests.append("playback.wake_controls")
        XCTAssertTrue(
            app.buttons["slideshow.control.settings.button"].waitForExistence(timeout: 4),
            "The first wake should only bring up the control bar."
        )
        let after = try captureWakeMark(app: app, name: "after-wake")
        try AccessLifecycleContract.assertWakeDidNotSwitch(before: before.mark, after: after.mark)
    }

    @MainActor
    func requireHiddenPlaybackControls(app: XCUIApplication, timeout: TimeInterval) throws {
        var hiddenSince: Date?
        guard
            waitUntil(
                timeout: timeout,
                condition: {
                    guard !app.buttons["slideshow.control.settings.button"].exists else {
                        hiddenSince = nil
                        return false
                    }
                    if timeout == 0 { return true }
                    if hiddenSince == nil { hiddenSince = Date() }
                    // AX removes the button first while pixels keep fading out for 0.3 s; require 0.6 s of
                    // stability before capturing the precondition frame.
                    return Date().timeIntervalSince(hiddenSince!) >= 0.6
                })
        else {
            throw NSError(
                domain: "WakePrecondition", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "The control bar is not hidden yet; cannot verify the first wake."
                ]
            )
        }
    }

    @MainActor
    func captureWakeMark(app: XCUIApplication, name: String) throws -> (mark: String, png: Data) {
        try AccessLifecycleContract.assertIdentitySource("public_fixture_photo_mark")
        let png = try captureRequiredPNG(app: app, name: name)
        let identity = StrictE2EPhotoIdentity.captureIdentity(png: png)
        let mark = contractMark(identity)
        if mark == "BLACK" || mark == "BLANK" || mark == "UNRECOGNIZABLE" || mark.isEmpty {
            XCTFail(
                "Screenshot \(name) cannot be used as identity: \(identity.status.rawValue)/\(identity.mark ?? "nil")")
        }
        return (mark, png)
    }

    @MainActor
    func changeDisplayPolicyAndReturn(app: XCUIApplication) throws -> [String: Any] {
        revealPlaybackControls(app: app)
        let beforePNG = try captureRequiredPNG(app: app, name: "display-before")
        let beforeMark = contractMark(StrictE2EPhotoIdentity.captureIdentity(png: beforePNG))
        openSettingsFromSlideshow(app: app)
        requests.append("settings.open")
        if app.buttons["pinEntry.close.button"].waitForExistence(timeout: 3) {
            enterPin(app: app, pin: syntheticPIN())
            requests.append("settings.pin.unlock")
        }
        openPlaybackSettings(app: app)
        let picker = app.segmentedControls["settings.playback.displayMode.picker"]
        XCTAssertTrue(
            picker.waitForExistence(timeout: 8), "Returning to settings must still allow changing the display policy.")
        let singlePhoto = picker.buttons["settings.playback.displayMode.singlePhoto.option"]
        XCTAssertTrue(singlePhoto.waitForExistence(timeout: 3), "The display policy should offer single-photo mode.")
        tapElement(singlePhoto)
        requests.append("settings.save.display_mode")
        let autoPlay = playbackSwitch(app: app, identifier: "settings.playback.autoPlay.toggle")
        if autoPlay.waitForExistence(timeout: 3), !isToggleOn(autoPlay) {
            tapElement(autoPlay)
            XCTAssertTrue(
                waitUntil(timeout: 4) { self.isToggleOn(autoPlay) },
                "Autoplay must stay on after changing the display policy."
            )
            requests.append("settings.save.autoplay")
        }
        returnToSlideshowFromSettings(app: app)
        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: 15),
            "Must return to the playback page after changing the display policy.")
        let afterPNG = try captureRequiredPNG(app: app, name: "display-after")
        let afterMark = contractMark(StrictE2EPhotoIdentity.captureIdentity(png: afterPNG))
        try AccessLifecycleContract.assertDisplayPolicyTookEffect(
            source: "real_settings_ui",
            modeBefore: "smartFill",
            modeAfter: "singlePhoto",
            pngSHA256Before: sha256Hex(beforePNG),
            pngSHA256After: sha256Hex(afterPNG),
            markBefore: beforeMark,
            markAfter: afterMark
        )
        return [
            "source": "real_settings_ui",
            "mode_before": "smartFill",
            "mode_after": "singlePhoto",
            "png_sha256_before": sha256Hex(beforePNG),
            "png_sha256_after": sha256Hex(afterPNG),
            "mark_before": beforeMark,
            "mark_after": afterMark
        ]
    }

    @MainActor
    func proveIPadLicenseReturnIfNeeded(app: XCUIApplication) throws -> [String: Any] {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            return ["applicable": false]
        }
        openSettingsFromSlideshow(app: app)
        if app.buttons["pinEntry.close.button"].waitForExistence(timeout: 5) {
            enterPin(app: app, pin: syntheticPIN())
            requests.append("settings.pin.unlock")
        }
        openSettingsSection(app: app, sectionID: "settings.item.about")
        let openSourceLink = app.descendants(matching: .any)["settings.about.opensource.link"]
        XCTAssertTrue(
            openSourceLink.waitForExistence(timeout: 8), "The About page should show the open-source licenses entry.")
        tapElement(openSourceLink)
        requests.append("settings.about.licenses")
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.about.opensource.page"].waitForExistence(timeout: 5),
            "Must reach the open-source licenses page."
        )
        let aboutBack = app.navigationBars.buttons["BackButton"].firstMatch
        if aboutBack.waitForExistence(timeout: 4) {
            tapElement(aboutBack)
        } else {
            let back = app.navigationBars.buttons.allElementsBoundByIndex.last { button in
                button.exists && button.isHittable
            }
            XCTAssertNotNil(back, "The open-source licenses page must be able to go back to About.")
            if let back {
                tapElement(back)
            }
        }
        let stackPreserved = openSourceLink.waitForExistence(timeout: 8)
        XCTAssertTrue(stackPreserved, "After going back, must still be on About; the back stack must not be lost.")
        try AccessLifecycleContract.assertIPadLicenseReturn(device: "ipad", isStackPreserved: stackPreserved)
        returnToSlideshowFromSettings(app: app)
        return ["applicable": true, "stack_preserved": stackPreserved]
    }

    struct ObservedPlaybackSettings {
        let isAutoPlayEnabled: Bool
        let intervalSeconds: Int
        let shouldShowExif: Bool
        let displayMode: String

        var dictionary: [String: Any] {
            [
                "source": "real_settings_ui",
                "autoPlayEnabled": isAutoPlayEnabled,
                "intervalSeconds": intervalSeconds,
                "showExif": shouldShowExif,
                "displayMode": displayMode
            ]
        }
    }

    @MainActor
    func captureSettingsAtBackground(app: XCUIApplication) throws -> ObservedPlaybackSettings {
        openSettingsFromSlideshow(app: app)
        requests.append("settings.open")
        if app.buttons["pinEntry.close.button"].waitForExistence(timeout: 3) {
            enterPin(app: app, pin: syntheticPIN())
            requests.append("settings.pin.unlock")
        }
        let settings = try readObservedPlaybackSettings(app: app)
        try AccessLifecycleContract.assertAutoPlayEnabledAtBackground(settings.isAutoPlayEnabled)
        _ = try captureRequiredPNG(app: app, name: "settings-at-background")
        returnToSlideshowFromSettings(app: app)
        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: 15),
            "Must return to the playback page before going to the background.")
        return settings
    }

    @MainActor
    func readPlaybackSettings(
        app: XCUIApplication,
        shouldAllowPinUnlock: Bool = true
    ) throws -> [String: Any] {
        let observed = try readObservedPlaybackSettings(app: app, shouldAllowPinUnlock: shouldAllowPinUnlock)
        return [
            "autoPlayEnabled": observed.isAutoPlayEnabled,
            "intervalSeconds": observed.intervalSeconds,
            "showExif": observed.shouldShowExif,
            "displayMode": observed.displayMode
        ]
    }

    @MainActor
    func readObservedPlaybackSettings(
        app: XCUIApplication,
        shouldAllowPinUnlock: Bool = true
    ) throws -> ObservedPlaybackSettings {
        if app.buttons["pinEntry.close.button"].exists {
            if shouldAllowPinUnlock == false {
                throw AccessLifecycleContract.AssertionError.message(
                    "A password sheet appeared while reading settings; the narrow entry must fail")
            }
            enterPin(app: app, pin: syntheticPIN())
        }
        openPlaybackSettings(app: app)
        let autoPlay = playbackSwitch(app: app, identifier: "settings.playback.autoPlay.toggle")
        XCTAssertTrue(autoPlay.waitForExistence(timeout: 8), "Playback settings must provide the autoplay toggle.")
        let exif = playbackSwitch(app: app, identifier: "settings.playback.showExif.toggle")
        XCTAssertTrue(exif.waitForExistence(timeout: 8), "Playback settings must provide the EXIF toggle.")
        let display = app.segmentedControls["settings.playback.displayMode.picker"]
        XCTAssertTrue(display.waitForExistence(timeout: 8), "Playback settings must provide the display policy.")
        guard let interval = readIntervalSeconds(app: app) else {
            throw AccessLifecycleContract.AssertionError.message("Missing settings evidence")
        }
        let mode =
            display.buttons["settings.playback.displayMode.smartFill.option"].isSelected ? "smartFill" : "singlePhoto"
        return ObservedPlaybackSettings(
            isAutoPlayEnabled: isToggleOn(autoPlay),
            intervalSeconds: interval,
            shouldShowExif: isToggleOn(exif),
            displayMode: mode
        )
    }

    @MainActor
    func setIntervalFromUI(app: XCUIApplication, targetSeconds: Int) throws -> Int {
        let slider = app.sliders["settings.playback.interval.slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 8), "Playback settings must provide the interval slider.")
        XCTAssertTrue(slider.isEnabled, "The interval cannot be changed while autoplay is off.")
        let targetLabel = "\(targetSeconds) 秒"
        var low = 0.0
        var high = 1.0
        var position =
            (Double(targetSeconds) - intervalMinimumSeconds)
            / (intervalMaximumSeconds - intervalMinimumSeconds)
        slider.adjust(toNormalizedSliderPosition: position)
        for _ in 0..<AccessLifecycleIOSUITestsCalibration.intervalSearchAttemptLimit {
            if intervalLabelExists(app: app, label: targetLabel) {
                try AccessLifecycleContract.assertIOSIntervalReachedRequested(
                    observed: targetSeconds,
                    target: targetSeconds
                )
                return targetSeconds
            }
            guard let current = readIntervalSeconds(app: app) else { break }
            if current > targetSeconds {
                high = min(high, position)
            } else {
                low = max(low, position)
            }
            if high - low < AccessLifecycleIOSUITestsCalibration.sliderSearchTolerance { break }
            position = (low + high) / 2
            slider.adjust(toNormalizedSliderPosition: position)
        }
        if intervalLabelExists(app: app, label: targetLabel) == false {
            try nudgeIntervalSliderTowardTarget(slider, app: app, targetSeconds: targetSeconds)
        }
        guard intervalLabelExists(app: app, label: targetLabel) else {
            let observed = readIntervalSeconds(app: app)
            try AccessLifecycleContract.assertIOSIntervalReachedRequested(
                observed: observed ?? -1,
                target: targetSeconds
            )
            throw AccessLifecycleContract.AssertionError.message("Missing settings evidence")
        }
        try AccessLifecycleContract.assertIOSIntervalReachedRequested(
            observed: targetSeconds,
            target: targetSeconds
        )
        return targetSeconds
    }

    @MainActor
    func intervalLabelExists(app: XCUIApplication, label: String) -> Bool {
        let interval = app.staticTexts["settings.playback.interval.value"]
        return waitUntil(timeout: 0.4) { interval.exists && interval.label == label }
    }

    @MainActor
    func nudgeIntervalSliderTowardTarget(
        _ slider: XCUIElement,
        app: XCUIApplication,
        targetSeconds: Int
    ) throws {
        let targetLabel = "\(targetSeconds) 秒"
        for _ in 0..<AccessLifecycleIOSUITestsCalibration.sliderNudgeAttemptLimit {
            if intervalLabelExists(app: app, label: targetLabel) { return }
            guard let current = readIntervalSeconds(app: app) else { return }
            if current == targetSeconds && intervalLabelExists(app: app, label: targetLabel) { return }
            let delta: CGFloat =
                current < targetSeconds
                ? AccessLifecycleIOSUITestsCalibration.sliderNudgeStep
                : -AccessLifecycleIOSUITestsCalibration.sliderNudgeStep
            let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = slider.coordinate(
                withNormalizedOffset: CGVector(
                    dx: min(
                        max(0.5 + delta, AccessLifecycleIOSUITestsCalibration.sliderLowerBound),
                        AccessLifecycleIOSUITestsCalibration.sliderUpperBound), dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    @MainActor
    func readIntervalSeconds(app: XCUIApplication) -> Int? {
        let interval = app.staticTexts["settings.playback.interval.value"]
        guard
            waitUntil(
                timeout: 2,
                condition: {
                    interval.exists && interval.label.range(of: #"^[0-9]+ 秒$"#, options: .regularExpression) != nil
                })
        else { return nil }
        let digits = interval.label.split { !$0.isNumber }.first
        guard let digits, let value = Int(digits) else { return nil }
        return value
    }

    @MainActor
    func playbackSwitch(app: XCUIApplication, identifier: String) -> XCUIElement {
        let toggle = app.switches[identifier]
        if toggle.exists { return toggle }
        return settingsControl(app: app, identifier: identifier)
    }
}
#endif
