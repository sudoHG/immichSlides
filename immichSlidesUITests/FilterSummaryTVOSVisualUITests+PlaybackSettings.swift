import XCTest

#if os(tvOS)
extension FilterSummaryTVOSVisualUITests {
    @MainActor
    func testTVOSSettingsPlaybackDefaultFocusedScreenshot() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        let playbackItem = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            playbackItem.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "After opening settings, the home page should show the 'Playback Settings' entry")

        waitForSettingsHomeItemFocus(
            button: playbackItem,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "After opening settings, default focus should land on 'Playback Settings'"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-root-default-focus")
    }

    @MainActor
    func testTVOSSettingsAutoPlayUsesDedicatedSubpage() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        let playbackItem = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            playbackItem.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Settings home should show the 'Playback Settings' entry")
        waitForSettingsHomeItemFocus(
            button: playbackItem,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "Settings home default focus should land on 'Playback Settings'"
        )
        XCUIRemote.shared.press(.select)

        let autoPlayLink = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.autoPlay.link",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening Playback Settings, the 'Autoplay' row should be visible"
        )

        waitForButtonToGainFocus(
            autoPlayLink,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage:
                "After opening 'Playback Settings', default focus should land on the first actionable item, 'Autoplay'"
        )

        XCUIRemote.shared.press(.select)

        let autoPlayOnButton = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.autoPlay.on.button",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening 'Autoplay', the 'Autoplay on' option should be shown"
        )
        let autoPlayOffButton = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.autoPlay.off.button",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening 'Autoplay', the 'Autoplay off' option should be shown"
        )

        waitForButtonToGainFocus(
            autoPlayOnButton,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "After opening 'Autoplay', default focus should land on the first item, 'Autoplay on'"
        )
        waitForFocusVisualSettle()

        let isOnOptionSelected = accessibilityValueString(for: autoPlayOnButton).contains("已选中")
        if isOnOptionSelected {
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle()
        }
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitUntil(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds) {

                self.accessibilityValueString(for: autoPlayOnButton).contains(isOnOptionSelected ? "未选中" : "已选中")
                    && self.accessibilityValueString(for: autoPlayOffButton).contains(
                        isOnOptionSelected ? "已选中" : "未选中")
            },
            """
            After picking the other option on the 'Autoplay' subpage, the selection on this page should switch.
            Current state snapshot:
            autoPlayOn.value=\(accessibilityValueString(for: autoPlayOnButton))
            autoPlayOff.value=\(accessibilityValueString(for: autoPlayOffButton))
            """
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-playback-autoPlay-page")
    }

    @MainActor
    func testTVOSSettingsPlaybackIntervalUsesDedicatedSubpage() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        let playbackItem = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            playbackItem.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Settings home should show the 'Playback Settings' entry")
        waitForSettingsHomeItemFocus(
            button: playbackItem,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "Settings home default focus should land on 'Playback Settings'"
        )
        XCUIRemote.shared.press(.select)

        let autoPlayLink = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.autoPlay.link",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Playback settings page should show the 'Autoplay' row"
        )
        let intervalLink = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.interval.link",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Playback settings page should show the 'Autoplay Interval' entry"
        )
        let modeLink = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.mode.link",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Playback settings page should show the 'Default Playback Mode' entry"
        )
        let displayLink = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.display.link",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Playback settings page should show the 'Display Items' entry"
        )

        waitForButtonToGainFocus(
            autoPlayLink,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "After opening 'Playback Settings', default focus should land on the 'Autoplay' entry"
        )

        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds) {
                app.buttons["settings.playback.interval.5.button"].exists
            },
            """
            After moving down once from 'Autoplay', Select should open the 'Autoplay Interval' subpage.
            Current state snapshot:
            autoPlayLink.value=\(accessibilityValueString(for: autoPlayLink))
            intervalLink.value=\(accessibilityValueString(for: intervalLink))
            modeLink.value=\(accessibilityValueString(for: modeLink))
            displayLink.value=\(accessibilityValueString(for: displayLink))
            autoPlayPage.exists=\(app.buttons["settings.playback.autoPlay.on.button"].exists)
            intervalPage.exists=\(app.buttons["settings.playback.interval.5.button"].exists)
            """
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-playback-interval-page")
    }

    @MainActor
    func testTVOSSettingsFilterConfigButtonCanOpenEditor() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        let playbackItem = app.buttons["settings.item.playback"]
        XCTAssertTrue(
            playbackItem.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Settings home should show the 'Playback Settings' entry")
        waitForSettingsHomeItemFocus(
            button: playbackItem,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "Settings home default focus should land on 'Playback Settings'"
        )
        XCUIRemote.shared.press(.select)

        let autoPlayLink = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.autoPlay.link",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "Playback settings page should show the 'Autoplay' entry"
        )
        let filterConfigButton = waitForSettingsControl(
            app: app,
            identifier: "settings.playback.filterConfig.button",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage:
                "When the default playback mode is 'Filtered playback', the 'Edit Filters' entry should be shown"
        )

        waitForButtonToGainFocus(
            autoPlayLink,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "After opening 'Playback Settings', default focus should land on the 'Autoplay' entry"
        )

        for _ in 0..<8 where !filterConfigButton.hasFocus {
            XCUIRemote.shared.press(.down)
            waitForFocusVisualSettle()
        }
        XCTAssertTrue(filterConfigButton.hasFocus, "Edit Filters must get focus first")
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            waitUntil(timeout: FilterSummaryTVOSVisualUITestsWaitTiming.navigationDeadlineSeconds) {
                app.buttons["filter.editor.done.button"].exists && app.buttons["filter.editor.album.entry"].exists
                    && app.buttons["filter.editor.person.entry"].exists
            },
            """
            Selecting 'Edit Filters' should actually open the filter editor, not stay on the playback settings page.
            Current state snapshot:
            filterConfig.exists=\(filterConfigButton.exists)
            filterConfig.value=\(accessibilityValueString(for: filterConfigButton))
            done.exists=\(app.buttons["filter.editor.done.button"].exists)
            album.exists=\(app.buttons["filter.editor.album.entry"].exists)
            people.exists=\(app.buttons["filter.editor.person.entry"].exists)
            """
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-filter-editor")
    }

    @MainActor
    func testTVOSSettingsSidebarDefaultsToPlaybackAndCanMoveToAccessProtection() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        let playbackItem = app.buttons["settings.item.playback"]
        let accessProtectionItem = app.buttons["settings.item.accessProtection"]

        XCTAssertTrue(
            playbackItem.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "After opening settings, the home page should show the 'Playback Settings' entry")
        XCTAssertTrue(
            accessProtectionItem.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "After opening settings, the home page should show the 'Access Protection' entry")

        waitForSettingsHomeItemFocus(
            button: playbackItem,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "After opening settings, default focus should land on 'Playback Settings'"
        )

        XCUIRemote.shared.press(.down)
        waitForSettingsHomeItemFocus(
            button: accessProtectionItem,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "After moving down once on the home page, focus should reach 'Access Protection'"
        )

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitForSettingsControlExists(
                app: app,
                identifier: "settings.pin.enable.button",
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds
            ),
            "After opening 'Access Protection', the PIN enable controls should be shown"
        )

        waitForFocusVisualSettle()
        attachScreenshot(app: app, name: "tvos-settings-access-protection-page")
    }

    @MainActor
    func testTVOSSettingsSidebarDirectionalRoutingMatchesPressedDirection() throws {
        let app = try launchIntoSlideShow()
        openSettingsFromSlideShow(app: app)

        let playbackItem = app.buttons["settings.item.playback"]
        let accessProtectionItem = app.buttons["settings.item.accessProtection"]

        XCTAssertTrue(
            playbackItem.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Settings home page should show the 'Playback Settings' entry")
        XCTAssertTrue(
            accessProtectionItem.waitForExistence(
                timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds),
            "Settings home page should show the 'Access Protection' entry")

        waitForSettingsHomeItemFocus(
            button: playbackItem,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "After opening settings, default focus should land reliably on 'Playback Settings'"
        )

        XCUIRemote.shared.press(.down)
        waitForSettingsHomeItemFocus(
            button: accessProtectionItem,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "Pressing Down on 'Playback Settings' should move focus to 'Access Protection'"
        )
        XCUIRemote.shared.press(.select)
        let enablePinInput = waitForSettingsControl(
            app: app,
            identifier: "settings.pin.input.enable",
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceTimeoutSeconds,
            failureMessage: "After opening 'Access Protection', the PIN settings should be shown"
        )

        waitForButtonToGainFocus(
            enablePinInput,
            timeout: FilterSummaryTVOSVisualUITestsWaitTiming.controlAppearanceDeadlineSeconds,
            failureMessage: "After opening 'Access Protection', default focus should go to the first PIN input entry"
        )
    }
}
extension FilterSummaryTVOSVisualUITests {

}
#endif
