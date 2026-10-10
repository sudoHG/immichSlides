import XCTest

#if os(iOS)
extension StrictE2EFilterIOSUITests {
    @MainActor
    func snapshotPersonReturnSurface(
        _ app: XCUIApplication,
        backCountBeforeTap: Int? = nil
    ) -> [String: Any] {
        let identifiers = [
            "personFilter.back.button",
            "filterSummary.album.button",
            "filterSummary.startPlayback.button",
            "mode.random.button",
            "global.back.button"
        ]
        let backButtons = app.buttons.matching(identifier: "personFilter.back.button")
        var snapshot: [String: Any] = [
            "personFilter.back.button.count": backButtons.count
        ]
        if let backCountBeforeTap {
            snapshot["personFilter.back.button.count.before-tap"] = backCountBeforeTap
        }
        for identifier in identifiers {
            let button = app.buttons[identifier]
            snapshot[identifier] = [
                "exists": button.exists,
                "hittable": button.exists && button.isHittable,
                "enabled": button.exists && button.isEnabled
            ]
        }
        return snapshot
    }

    @MainActor
    func isFilterSummaryVisible(_ app: XCUIApplication) -> Bool {
        app.buttons["filterSummary.startPlayback.button"].exists
    }

    @MainActor
    func startFilteredPlayback(app: XCUIApplication) {
        let start = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(
            start.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
            "Filter summary must show Start Playback")
        XCTAssertTrue(start.isEnabled, "Start Playback must be enabled once something is selected")
        tapElement(start)
        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: TestWait.seconds(.infrastructure(30))),
            "Starting filtered playback must reach the playback page")
        dismissPlaybackEntryHintIfNeeded(app: app)
    }

    @MainActor
    func captureNamedPNG(app: XCUIApplication, name: String) -> Data {
        let png = app.screenshot().pngRepresentation
        XCTAssertFalse(png.isEmpty, "Screenshot must not be empty: \(name)")
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        StrictE2EVisualEvidence.writePNG(png, name: name)
        return png
    }

    @MainActor
    func capturePlaybackPNG(app: XCUIApplication, name: String) -> Data {
        RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.8))))
        revealPlaybackControls(app: app)
        let png = app.screenshot().pngRepresentation
        XCTAssertFalse(png.isEmpty, "Playback screenshot must not be empty: \(name)")
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        StrictE2EVisualEvidence.writePNG(png, name: name)
        return png
    }

    @MainActor
    func tapNext(app: XCUIApplication) {
        revealPlaybackControls(app: app)
        let next = app.buttons["slideshow.control.next.button"]
        XCTAssertTrue(
            next.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))), "Playback page must have Next")
        tapElement(next)
    }

    // For B, the album list returns to the editor in settings: it has Done and no Start Playback.
    @MainActor
    func assertSettingsFilterEditorAfterServerSwitchAlbumSelection(app: XCUIApplication) {
        XCTAssertTrue(
            app.staticTexts["filterEditor.page.title"].waitForExistence(timeout: TestWait.seconds(.product(8)))
                || app.descendants(matching: .any)["filterEditor.page.title"].waitForExistence(
                    timeout: TestWait.seconds(.product(2))),
            "After selecting the B album, the app must stay on the settings editor"
        )
        let albumEntry = app.buttons["filter.editor.album.entry"]
        XCTAssertTrue(
            albumEntry.waitForExistence(timeout: TestWait.seconds(.product(8))), "Editor must offer the album entry")
        XCTAssertTrue(app.staticTexts["filter.editor.summary.title"].exists, "Editor must show the filter summary")
        XCTAssertFalse(
            app.buttons["filterSummary.startPlayback.button"].exists,
            "The settings editor has no Start Playback; do not assert it like the first-boot summary"
        )
        let done = app.buttons["filter.editor.done.button"]
        let doneElement = app.descendants(matching: .any)["filter.editor.done.button"]
        XCTAssertTrue(done.exists || doneElement.exists, "Editor must have Done")
        XCTAssertTrue(
            editorAlbumCardShowsSelection(albumEntry, selectedAlbums: "1", pendingPhotos: "3")
                || editorSummaryShowsSelection(app, selectedAlbums: "1", pendingPhotos: "3"),
            "Editor album card must show 1 selected album and 3 photos to play"
        )
    }

    @MainActor
    func editorSummaryShowsSelection(
        _ app: XCUIApplication,
        selectedAlbums: String,
        pendingPhotos: String
    ) -> Bool {
        // On iPad the summary tile may merge the count and the selected-albums text into one label.
        isSummaryCountVisible(app, value: selectedAlbums, label: "已选相册")
            && isSummaryCountVisible(app, value: pendingPhotos, label: "待播照片")
    }

    @MainActor
    func isSummaryCountVisible(_ app: XCUIApplication, value: String, label: String) -> Bool {
        // ui-label-lookup: Verify the displayed summary count and caption.
        if app.staticTexts[value].exists && app.staticTexts[label].exists { return true }
        let combined = "\(value) \(label)"
        // ui-label-lookup: Verify the displayed combined summary count and caption.
        if app.staticTexts[combined].exists { return true }
        return app.staticTexts.matching(
            // ui-label-lookup: Verify the displayed combined summary count and caption.
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", value, label)
        ).firstMatch.exists
    }

    @MainActor
    func editorAlbumCardShowsSelection(
        _ entry: XCUIElement,
        selectedAlbums: String,
        pendingPhotos: String
    ) -> Bool {
        let texts = entry.staticTexts.allElementsBoundByIndex.map(\.label)
        if let selectedIndex = texts.firstIndex(of: "已选相册"),
            selectedIndex > 0,
            texts[selectedIndex - 1] == selectedAlbums,
            let pendingIndex = texts.firstIndex(of: "待播照片"),
            pendingIndex > 0,
            texts[pendingIndex - 1] == pendingPhotos
        {
            return true
        }
        let label = entry.label
        return label.contains("已选相册")
            && label.contains("待播照片")
            && label.range(of: "\\b\(selectedAlbums)\\b", options: .regularExpression) != nil
            && label.range(of: "\\b\(pendingPhotos)\\b", options: .regularExpression) != nil
    }

    @MainActor
    func finishFilterEditor(app: XCUIApplication) {
        let done = app.buttons["filter.editor.done.button"]
        if done.waitForExistence(timeout: TestWait.seconds(.infrastructure(4))) {
            tapElement(done)
            return
        }
        let doneElement = app.descendants(matching: .any)["filter.editor.done.button"]
        if doneElement.exists {
            tapElement(doneElement)
            return
        }
        XCTFail("The filter editor must show its Done button.")
    }

    @MainActor
    func returnToSlideshowFromSettings(app: XCUIApplication) {
        // In the iPad split view the first navigation button is often ToggleSidebar; it is not Back.
        for _ in 0..<8 {
            let settings = app.buttons["slideshow.control.settings.button"]
            if !isFilterEditorVisible(app) && settings.exists && settings.isHittable { return }
            let globalBack = app.buttons["global.back.button"]
            if globalBack.exists && globalBack.isHittable {
                tapElement(globalBack)
                continue
            }
            if let backButton = settingsNavigationBackButton(app: app) {
                backButton.tap()
                continue
            }
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.3))))
        }
        revealPlaybackControls(app: app)
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(8))) {
                !self.isFilterEditorVisible(app)
                    && app.buttons["slideshow.control.settings.button"].exists
                    && app.buttons["slideshow.control.settings.button"].isHittable
            },
            "Must return to the playback page"
        )
    }

    @MainActor
    func isFilterEditorVisible(_ app: XCUIApplication) -> Bool {
        app.staticTexts["filterEditor.page.title"].exists
            || app.buttons["filter.editor.done.button"].exists
            || app.descendants(matching: .any)["filter.editor.done.button"].exists
    }

    @MainActor
    func settingsNavigationBackButton(app: XCUIApplication) -> XCUIElement? {
        let bars = app.navigationBars.buttons.allElementsBoundByIndex
        let back = bars.last { $0.exists && $0.isHittable && $0.identifier == "BackButton" }
        if let back { return back }
        return bars.first { $0.exists && $0.isHittable && $0.identifier != "ToggleSidebar" }
    }

    @MainActor
    func changeServerFromPlayback(app: XCUIApplication, serverURL: String, publicKey: String) {
        revealPlaybackControls(app: app)
        tapElement(app.buttons["slideshow.control.settings.button"])
        if UIDevice.current.userInterfaceIdiom == .pad {
            let sidebar = app.buttons["ToggleSidebar"]
            // ui-label-lookup: System navigation supplies the sidebar button label.
            if sidebar.exists && ["显示边栏", "Show Sidebar"].contains(sidebar.label) {
                tapElement(sidebar)
            }
        }
        let serverEntry = app.descendants(matching: .any)["settings.item.server"].firstMatch
        XCTAssertTrue(
            serverEntry.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
            "Settings must offer the server entry")
        tapElement(serverEntry)
        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(
            serverField.waitForExistence(timeout: TestWait.seconds(.product(8))),
            "Server settings page should show the URL")
        replaceText(
            in: serverField, app: app, with: serverURL, evidenceName: "server-url-replace",
            shouldRequireExactValue: true)
        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        if apiKeyField.waitForExistence(timeout: TestWait.seconds(.infrastructure(4))) {
            let current = apiKeyField.value as? String ?? ""
            if current.isEmpty || current.contains("请输入") {
                replaceText(
                    in: apiKeyField,
                    app: app,
                    with: publicKey,
                    evidenceName: "server-apikey-replace",
                    shouldRequireExactValue: false
                )
            }
        }
        commitFocusedInputIfNeeded(app: app)
        tapTestConnection(app: app)
        let saveButton = firstBootControl(
            in: app,
            identifier: "firstboot.saveConfig.button"
        )
        XCTAssertTrue(
            waitForSaveEnabled(app: app, saveButton: saveButton, timeout: TestWait.seconds(.infrastructure(45))),
            "Save must work after the connection test on the new server succeeds")
        tapElement(saveButton)
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(20))) {
                app.staticTexts["settings.server.status.message"].exists
                    && ["配置已保存", "Settings saved"].contains(app.staticTexts["settings.server.status.message"].label)
            },
            "Saving the new server must show a success confirmation"
        )
    }

    @MainActor
    func openFilterEditorFromSettings(app: XCUIApplication) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            let sidebar = app.buttons["ToggleSidebar"]
            // ui-label-lookup: System navigation supplies the sidebar button label.
            if sidebar.exists && ["显示边栏", "Show Sidebar"].contains(sidebar.label) {
                tapElement(sidebar)
            }
        }
        let playbackEntry = app.descendants(matching: .any)["settings.item.playback"].firstMatch
        if !playbackEntry.waitForExistence(timeout: TestWait.seconds(.product(2))) {
            let back = app.buttons["global.back.button"]
            if back.exists && back.isHittable {
                tapElement(back)
            } else {
                let navigationBack = app.navigationBars.buttons.firstMatch
                if navigationBack.exists && navigationBack.isHittable {
                    tapElement(navigationBack)
                }
            }
        }
        XCTAssertTrue(
            playbackEntry.waitForExistence(timeout: TestWait.seconds(.product(8))),
            "After the server switch, settings must still offer the playback entry")
        tapElement(playbackEntry)
        let filterConfig = app.buttons["settings.playback.filterConfig.button"]
        if !filterConfig.waitForExistence(timeout: TestWait.seconds(.product(2))) {
            let modePicker = app.segmentedControls["settings.playback.mode.picker"]
            XCTAssertTrue(
                modePicker.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
                "Playback settings must offer the default playback mode")
            let filteredMode = modePicker.buttons.element(boundBy: 1)
            XCTAssertTrue(
                filteredMode.waitForExistence(timeout: TestWait.seconds(.infrastructure(4))),
                "Playback settings must offer the filtered playback option")
            tapElement(filteredMode)
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            let configure = app.buttons["去配置"]
            XCTAssertTrue(
                configure.waitForExistence(timeout: TestWait.seconds(.product(8))),
                "After the server switch clears filters, reconfiguring must be allowed")
            tapElement(configure)
        } else {
            if !filterConfig.isHittable {
                app.swipeUp()
            }
            tapElement(filterConfig)
        }
        XCTAssertTrue(
            app.buttons["filter.editor.album.entry"].waitForExistence(timeout: TestWait.seconds(.product(12)))
                || app.staticTexts["filterEditor.page.title"].waitForExistence(timeout: TestWait.seconds(.product(4))),
            "Filter editor must open after the server switch"
        )
    }

    @MainActor
    func isolateAlbumSelection(app: XCUIApplication, keeping albumID: String) {
        let clear = app.buttons["albumFilter.clear.button"]
        if clear.waitForExistence(timeout: TestWait.seconds(.infrastructure(4))) {
            tapElement(clear)
        }
        let known = [
            "album-a-target", "album-a-non-target", "album-a-empty",
            "album-b-target", "album-b-non-target", "album-b-empty"
        ]
        for otherID in known where otherID != albumID {
            let other = app.buttons["albumFilter.album.\(otherID).button"]
            guard other.exists else { continue }
            let value = String(describing: other.value ?? "")
            if value.contains("已选中") || other.isSelected {
                tapElement(other)
            }
        }
    }

    @MainActor
    func openSettingsHomeFromPlayback(app: XCUIApplication) {
        revealPlaybackControls(app: app)
        tapElement(app.buttons["slideshow.control.settings.button"])
        if UIDevice.current.userInterfaceIdiom == .pad {
            let sidebar = app.buttons["ToggleSidebar"]
            // ui-label-lookup: System navigation supplies the sidebar button label.
            if sidebar.exists && ["显示边栏", "Show Sidebar"].contains(sidebar.label) {
                tapElement(sidebar)
            }
        }
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.item.server"].firstMatch.waitForExistence(
                timeout: TestWait.seconds(.product(8)))
                || app.descendants(matching: .any)["settings.item.playback"].firstMatch.waitForExistence(
                    timeout: TestWait.seconds(.product(2))),
            "Playback page must open settings"
        )
    }

    @MainActor
    func openPlaybackSettingsFromSlideshow(app: XCUIApplication) {
        openSettingsHomeFromPlayback(app: app)
        let playbackEntry = app.descendants(matching: .any)["settings.item.playback"].firstMatch
        XCTAssertTrue(
            playbackEntry.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
            "Settings must offer the playback entry")
        tapElement(playbackEntry)
        XCTAssertTrue(
            app.segmentedControls["settings.playback.displayMode.picker"].waitForExistence(
                timeout: TestWait.seconds(.product(8))),
            "Playback settings must offer the display policy"
        )
    }

    @MainActor
    func selectSinglePhotoDisplayMode(app: XCUIApplication) {
        let picker = app.segmentedControls["settings.playback.displayMode.picker"]
        XCTAssertTrue(
            picker.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
            "Playback settings must offer the display policy segmented control")
        let singlePhoto = picker.buttons["settings.playback.displayMode.singlePhoto.option"]
        XCTAssertTrue(
            singlePhoto.waitForExistence(timeout: TestWait.seconds(.infrastructure(3))),
            "Display policy must offer single-photo mode")
        tapElement(singlePhoto)
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(6))) { singlePhoto.isSelected },
            "After choosing it on the real settings page, single-photo mode must read back as selected"
        )
    }

    @MainActor
    func selectSmartFillDisplayMode(app: XCUIApplication) {
        let picker = app.segmentedControls["settings.playback.displayMode.picker"]
        XCTAssertTrue(
            picker.waitForExistence(timeout: TestWait.seconds(.infrastructure(8))),
            "Playback settings must offer the display policy segmented control")
        let smartFill = picker.buttons["settings.playback.displayMode.smartFill.option"]
        XCTAssertTrue(
            smartFill.waitForExistence(timeout: TestWait.seconds(.infrastructure(3))),
            "Display policy must offer Smart Fill")
        tapElement(smartFill)
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(6))) { smartFill.isSelected },
            "After choosing it on the real settings page, Smart Fill must read back as selected"
        )
    }

    @MainActor
    func waitForStablePublicPhoto(app: XCUIApplication, timeout: TimeInterval) -> StrictE2EPhotoIdentity.Result? {
        var last: StrictE2EPhotoIdentity.Result?
        _ = waitUntil(timeout: timeout) {
            let png = app.screenshot().pngRepresentation
            last = StrictE2EPhotoIdentity.classify(png: png)
            return last?.status == .match
        }
        return last
    }

    // Server-switch multi-photo uses the same crops as Python _distinct_region_marks but checks only color
    // classification and distinct marks; the Python contract additionally requires A/B letters in middle and stacked crops.
    @MainActor
    func waitForDistinctRegionMarks(app: XCUIApplication, timeout: TimeInterval) -> [String] {
        var last: [String] = []
        _ = waitUntil(timeout: timeout) {
            let png = app.screenshot().pngRepresentation
            last = self.distinctRegionMarks(StrictE2EPhotoIdentity.classifyRegions(png: png))
            return last.count >= 2
        }
        return last
    }

    func distinctRegionMarks(_ regions: [String: StrictE2EPhotoIdentity.Result]) -> [String] {
        func mark(_ name: String) -> String? {
            guard let identity = regions[name],
                identity.status == .match,
                let value = identity.mark
            else {
                return nil
            }
            return value
        }
        var marks: [String] = []
        func add(_ value: String?) {
            guard let value, marks.contains(value) == false else { return }
            marks.append(value)
        }
        for pair in [("left", "right"), ("mid_left", "mid_right"), ("center", "bottom_half")] {
            let first = mark(pair.0)
            let second = mark(pair.1)
            if let first, let second, first != second {
                add(first)
                add(second)
            }
        }
        let topHalf = mark("top_half")
        let bottomHalf = mark("bottom_half")
        let center = mark("center")
        let top = mark("top")
        // In the letterboxed single photo B1, top is a black bar; with two stacked photos in portrait
        // Smart Fill, center lands on the lower photo.
        let realStackedHalves = top != nil && top == topHalf
        if let topHalf, let bottomHalf, topHalf != bottomHalf {
            if center != bottomHalf || realStackedHalves {
                add(topHalf)
                add(bottomHalf)
            }
        }
        return marks
    }
}
#endif
