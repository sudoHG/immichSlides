import XCTest

#if os(tvOS)
extension FilterSummaryTVOSVisualUITests {
    @MainActor
    func testTVOSSettingsSidebarAccessProtectionScreenshotLight() throws {

        let app = try launchIntoSlideShow(colorScheme: "light")
        openSettingsFromSlideShow(app: app)

        let accessProtectionItem = app.buttons["settings.item.accessProtection"]
        XCTAssertTrue(
            accessProtectionItem.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "After opening settings, the home page should show the 'Access Protection' entry")

        XCUIRemote.shared.press(.down)
        waitForSettingsHomeItemFocus(
            button: accessProtectionItem,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "In light mode, moving down on the home page should also reliably focus 'Access Protection'"
        )

        XCUIRemote.shared.press(.select)
        let enablePinInput = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.input.enable",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "In light mode, opening 'Access Protection' should show the PIN input entry"
        )
        waitForButtonToGainFocus(
            enablePinInput,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage:
                "In light mode, on the access protection page default focus should be on the 'Set PIN' input entry"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-access-protection-page-light")
    }

    @MainActor
    func testTVOSSettingsAccessProtectionAccessibilityTextScreenshot() throws {

        let app = try launchIntoSlideShow(dynamicTypeSize: "accessibility3")
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.accessProtection",
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.accessProtectionSteps,
            failureMessage:
                "With large text, settings home should reliably reach the 'Access Protection' entry with direction keys"
        )

        XCUIRemote.shared.press(.select)
        let enablePinInput = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.input.enable",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "With large text, opening 'Access Protection' should show the 'Set PIN' input entry"
        )
        waitForButtonToGainFocus(
            enablePinInput,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage:
                "With large text, on the access protection page default focus should be on the 'Set PIN' input entry"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-access-protection-accessibility-text")
    }

    @MainActor
    func testTVOSPinSheetAccessibilityTextBottomRowRoutingScreenshot() throws {

        let app = try launchIntoSlideShow(dynamicTypeSize: "accessibility3")
        openSettingsFromSlideShow(app: app)

        _ = waitForSettingsHomeItem(
            app: app,
            identifier: "settings.item.accessProtection",
            downStepsFromPlayback: FilterSummaryTVOSVisualUITestsSettingsNavigation.accessProtectionSteps,
            failureMessage:
                "With large text, settings home should reliably reach the 'Access Protection' entry with direction keys"
        )
        XCUIRemote.shared.press(.select)

        let enablePinInput = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.input.enable",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "With large text, the access protection page should show the 'Set PIN' input entry"
        )
        waitForButtonToGainFocus(
            enablePinInput,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage:
                "With large text, entering the access protection page should focus the 'Set PIN' input entry first"
        )
        XCUIRemote.shared.press(.select)

        let digitOneButton = app.buttons["pinEntry.digit.1.button"]
        let closeButton = app.buttons["pinEntry.close.button"]
        let zeroButton = app.buttons["pinEntry.digit.0.button"]
        let deleteButton = app.buttons["pinEntry.delete.button"]

        XCTAssertTrue(
            closeButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "With large text, the opened PIN sheet should show the close button")
        XCTAssertTrue(
            digitOneButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "With large text, the opened PIN sheet should show the number pad")
        XCTAssertTrue(
            zeroButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "With large text, the PIN sheet should show digit 0")
        XCTAssertTrue(
            deleteButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "With large text, the PIN sheet should show the delete button")

        waitForButtonToGainFocus(
            digitOneButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "With large text, default focus in the opened PIN sheet should land on digit 1"
        )

        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        waitForButtonToGainFocus(
            closeButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "With large text, moving down three times from digit 1 should land focus on 'Close'"
        )

        XCUIRemote.shared.press(.right)
        waitForButtonToGainFocus(
            zeroButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "With large text, moving right from 'Close' should move focus to digit 0"
        )

        XCUIRemote.shared.press(.right)
        waitForButtonToGainFocus(
            deleteButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "With large text, moving right from digit 0 should move focus to 'Delete'"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-pin-sheet-accessibility-text-routing")
    }

    @MainActor
    func testTVOSPinSheetDefaultsToDigitOneAndBottomRowKeepsStableRouting() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        let accessProtectionItem = app.buttons["settings.item.accessProtection"]
        XCTAssertTrue(
            accessProtectionItem.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Settings home page should show the 'Access Protection' entry")

        XCUIRemote.shared.press(.down)
        waitForSettingsHomeItemFocus(
            button: accessProtectionItem,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "After moving down, focus should reach 'Access Protection'"
        )

        XCUIRemote.shared.press(.select)

        let enablePinInput = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.input.enable",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Access protection page should show the 'Set PIN' input entry"
        )
        waitForButtonToGainFocus(
            enablePinInput,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage:
                "On entering the access protection page, focus should land on the 'Set PIN' input entry first"
        )

        XCUIRemote.shared.press(.select)

        let digitOneButton = app.buttons["pinEntry.digit.1.button"]
        let digitTwoButton = app.buttons["pinEntry.digit.2.button"]
        let closeButton = app.buttons["pinEntry.close.button"]
        let zeroButton = app.buttons["pinEntry.digit.0.button"]
        let deleteButton = app.buttons["pinEntry.delete.button"]

        XCTAssertTrue(
            closeButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "The opened PIN sheet should show the close button")
        XCTAssertTrue(
            digitOneButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "The opened PIN sheet should show the number pad")
        XCTAssertTrue(
            digitTwoButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "The opened PIN sheet should show digit 2")
        XCTAssertTrue(
            zeroButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "The PIN sheet should show digit 0")
        XCTAssertTrue(
            deleteButton.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "The PIN sheet should show the delete button")

        // The PIN sheet's default focus must be on the digit pad, not drift to the close button.
        waitForButtonToGainFocus(
            digitOneButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "When the PIN sheet opens, default focus should land on digit 1"
        )

        XCUIRemote.shared.press(.right)
        waitForButtonToGainFocus(
            digitTwoButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "Moving right from digit 1, focus should reach digit 2"
        )

        XCUIRemote.shared.press(.left)
        waitForButtonToGainFocus(
            digitOneButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "Moving left from digit 2, focus should return to digit 1"
        )

        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        waitForButtonToGainFocus(
            closeButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "Moving down three times from digit 1, focus should land reliably on 'Close'"
        )

        XCUIRemote.shared.press(.right)
        waitForButtonToGainFocus(
            zeroButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "Moving right from 'Close', focus should reach digit 0"
        )

        XCUIRemote.shared.press(.right)
        waitForButtonToGainFocus(
            deleteButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "Moving right from digit 0, focus should reach 'Delete'"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-pin-sheet-bottom-row-routing")
    }

    @MainActor
    func testTVOSAccessProtectionShowsProminentSuccessFeedbackAfterEnable() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        let accessProtectionItem = app.buttons["settings.item.accessProtection"]
        XCTAssertTrue(
            accessProtectionItem.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Settings home page should show the 'Access Protection' entry")

        XCUIRemote.shared.press(.down)
        waitForSettingsHomeItemFocus(
            button: accessProtectionItem,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "After moving down, focus should reach 'Access Protection'"
        )
        XCUIRemote.shared.press(.select)

        let enablePinInput = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.input.enable",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Access protection page should show the 'Set PIN' input entry"
        )
        let enablePinConfirmInput = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.input.enableConfirm",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Access protection page should show the 'Confirm PIN' input entry"
        )
        let enableProtectionButton = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.enable.button",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "Access protection page should show the 'Enable Access Protection' button"
        )

        waitForButtonToGainFocus(
            enablePinInput,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "On the access protection page, default focus should land on the 'Set PIN' input entry"
        )
        XCUIRemote.shared.press(.select)
        enterSixDigitsInPinSheetUsingDigitOne(app: app, operationName: "Set PIN")

        XCUIRemote.shared.press(.down)
        waitForButtonToGainFocus(
            enablePinConfirmInput,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "After filling 'Set PIN', moving down should focus 'Confirm PIN'"
        )
        XCUIRemote.shared.press(.select)
        enterSixDigitsInPinSheetUsingDigitOne(app: app, operationName: "Confirm PIN")

        XCUIRemote.shared.press(.down)
        waitForButtonToGainFocus(
            enableProtectionButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage:
                "After entering and confirming the PIN, moving down should focus the 'Enable Access Protection' button"
        )
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app,
                identifier: "settings.pin.feedback.success.prominent",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds
            ),
            "After access protection is enabled, a prominent success banner should show at the top of the page. state=\(accessibilityValueString(for: app.otherElements["settings.pin.stateProbe"]))"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app,
                identifier: "settings.pin.disable.button",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds
            ),
            "After access protection is enabled, the page should switch to the 'Disable Access Protection' controls"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-access-protection-enable-success-feedback")
    }

    @MainActor
    func testTVOSAccessProtectionShowsProminentSuccessFeedbackAfterDisable() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        let accessProtectionItem = app.buttons["settings.item.accessProtection"]
        XCTAssertTrue(
            accessProtectionItem.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Settings home page should show the 'Access Protection' entry")

        XCUIRemote.shared.press(.down)
        waitForSettingsHomeItemFocus(
            button: accessProtectionItem,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "After moving down, focus should reach 'Access Protection'"
        )
        XCUIRemote.shared.press(.select)

        let enablePinInput = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.input.enable",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Access protection page should show the 'Set PIN' input entry"
        )
        let enablePinConfirmInput = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.input.enableConfirm",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Access protection page should show the 'Confirm PIN' input entry"
        )
        let enableProtectionButton = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.enable.button",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "Access protection page should show the 'Enable Access Protection' button"
        )

        waitForButtonToGainFocus(
            enablePinInput,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "On the access protection page, default focus should land on the 'Set PIN' input entry"
        )
        XCUIRemote.shared.press(.select)
        enterSixDigitsInPinSheetUsingDigitOne(app: app, operationName: "Set PIN")

        XCUIRemote.shared.press(.down)
        waitForButtonToGainFocus(
            enablePinConfirmInput,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "After filling 'Set PIN', moving down should focus 'Confirm PIN'"
        )
        XCUIRemote.shared.press(.select)
        enterSixDigitsInPinSheetUsingDigitOne(app: app, operationName: "Confirm PIN")

        XCUIRemote.shared.press(.down)
        waitForButtonToGainFocus(
            enableProtectionButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage:
                "After entering and confirming the PIN, moving down should focus the 'Enable Access Protection' button"
        )
        XCUIRemote.shared.press(.select)

        let disableCurrentPinInput = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.input.disableCurrent",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "After enabling access protection, the 'Enter current PIN' entry should be shown. state=\(accessibilityValueString(for: app.otherElements["settings.pin.stateProbe"]))"
        )
        let disableProtectionButton = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.disable.button",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "After enabling access protection, the 'Disable Access Protection' button should be shown"
        )

        waitForButtonToGainFocus(
            disableCurrentPinInput,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage:
                "After access protection is enabled, default focus should be on the 'Enter current PIN' entry"
        )
        XCUIRemote.shared.press(.select)
        enterSixDigitsInPinSheetUsingDigitOne(app: app, operationName: "Enter current PIN")

        XCUIRemote.shared.press(.down)
        waitForButtonToGainFocus(
            disableProtectionButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage:
                "After entering the current PIN, moving down should focus the 'Disable Access Protection' button"
        )
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app,
                identifier: "settings.pin.feedback.success.prominent",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds
            ),
            "After access protection is disabled, a prominent success banner should be shown. state=\(accessibilityValueString(for: app.otherElements["settings.pin.stateProbe"]))"
        )
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app,
                identifier: "settings.pin.enable.button",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds
            ),
            "After disabling access protection, the page should switch back to the 'Enable Access Protection' controls"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-access-protection-disable-success-feedback")
    }
}
extension FilterSummaryTVOSVisualUITests {

}
#endif
