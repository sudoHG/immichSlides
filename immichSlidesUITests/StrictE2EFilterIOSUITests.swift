import XCTest

#if os(iOS)
final class StrictE2EFilterIOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    // Seam: continuous playback after selecting the target album in the filter summary.
    // Identity is judged only from public fixture screenshots.
    @MainActor
    func testFilterAlbumTargetMembers() throws {
        let input = try requireStrictE2EInput()
        let manifest = try loadEvidenceManifest()
        let albumID = try stringValue(manifest, keyPath: ["target_album", "id"])
        let app = try launchStrictE2EApp()
        defer { app.terminate() }

        try completeFirstBootToModeSelection(app: app, input: input, evidencePrefix: "filter-album")
        enterFilterSummary(app: app)
        openAlbumFilter(app: app)
        selectAlbum(app: app, albumID: albumID)
        returnFromAlbumFilter(app: app)
        startFilteredPlayback(app: app)
        pausePlaybackIfNeeded(app: app)

        _ = capturePlaybackPNG(app: app, name: "album-play-1")
        tapNext(app: app)
        _ = capturePlaybackPNG(app: app, name: "album-play-2")
        tapNext(app: app)
        _ = capturePlaybackPNG(app: app, name: "album-play-3")
    }

    // Swapping the target album through the real settings editor keeps filtered mode;
    // only clearing the selection and leaving the editor returns to random.
    @MainActor
    func testFilterEditSwitchKeepsFilteredModeAndClearReturnsRandom() throws {
        let input = try requireStrictE2EInput()
        let manifest = try loadEvidenceManifest()
        let targetAlbumID = try stringValue(manifest, keyPath: ["target_album", "id"])
        let nonTargetAlbumID = try stringValue(manifest, keyPath: ["non_target_album", "id"])
        let app = try launchStrictE2EApp()
        defer { app.terminate() }

        try completeFirstBootToModeSelection(app: app, input: input, evidencePrefix: "filter-edit-switch")
        enterFilterSummary(app: app)
        openAlbumFilterHandlingSystemPrompt(app: app)
        setAlbumSelection(app: app, albumID: targetAlbumID, isSelectionRequested: true)
        returnFromAlbumFilter(app: app)
        startFilteredPlayback(app: app)
        pausePlaybackIfNeeded(app: app)

        openSettingsHomeFromPlayback(app: app)
        openFilterEditorFromSettings(app: app)
        openAlbumFilterFromEditor(app: app)
        setAlbumSelection(app: app, albumID: targetAlbumID, isSelectionRequested: false)
        setAlbumSelection(app: app, albumID: nonTargetAlbumID, isSelectionRequested: true)
        let selectedCard = albumCard(app: app, albumID: nonTargetAlbumID)
        XCTAssertEqual(
            selectedCard.identifier,
            "albumFilter.album.\(nonTargetAlbumID).button",
            "The replaced album identity must come from the real list accessibility identifier"
        )
        let observedAlbumID = selectedCard.identifier
            .replacingOccurrences(of: "albumFilter.album.", with: "")
            .replacingOccurrences(of: ".button", with: "")
        returnFromAlbumFilter(app: app)
        finishFilterEditor(app: app)

        let modePicker = app.segmentedControls["settings.playback.mode.picker"]
        XCTAssertTrue(
            modePicker.waitForExistence(timeout: TestWait.seconds(.product(8))),
            "Leaving the editor must return to the real playback settings page"
        )
        let filteredMode = modePicker.buttons.element(boundBy: 1)
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(6))) { filteredMode.isSelected },
            "Filtered mode must stay selected after switching to the non-target album")
        _ = captureNamedPNG(app: app, name: "album-edit-switch-mode-filtered")
        returnToSlideshowFromSettings(app: app)
        _ = capturePlaybackPNG(app: app, name: "album-switch-b-play-1")
        tapNext(app: app)
        _ = capturePlaybackPNG(app: app, name: "album-switch-b-play-2")

        openSettingsHomeFromPlayback(app: app)
        openFilterEditorFromSettings(app: app)
        openAlbumFilterFromEditor(app: app)
        let clear = app.buttons["albumFilter.clear.button"]
        XCTAssertTrue(
            clear.waitForExistence(timeout: TestWait.seconds(.product(8))) && clear.isHittable,
            "The real album editor must offer Clear Selection")
        tapElement(clear)
        let clearedTarget = albumCard(app: app, albumID: targetAlbumID)
        let clearedNonTarget = albumCard(app: app, albumID: nonTargetAlbumID)
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(6))) {
                !self.isAlbumCardSelected(clearedTarget) && !self.isAlbumCardSelected(clearedNonTarget)
            },
            "After tapping Clear, target and non-target albums must both really become unselected; tapping cards one by one must not stand in for the clear result"
        )
        returnFromAlbumFilter(app: app)
        finishFilterEditor(app: app)

        XCTAssertTrue(
            modePicker.waitForExistence(timeout: TestWait.seconds(.product(8))),
            "Clearing and leaving the editor must return to the real playback settings page")
        let randomMode = modePicker.buttons.element(boundBy: 0)
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(6))) { randomMode.isSelected },
            "Leaving the editor with an empty filter must set the default mode back to random")
        _ = captureNamedPNG(app: app, name: "album-edit-switch-mode-random-after-clear")
        try StrictE2EVisualEvidence.writeRequiredJSON(
            [
                "identity_source": "accessibility_ui",
                "selected_album_id_after_replace": observedAlbumID,
                "mode_after_replace": "filtered",
                "mode_after_clear_and_exit": "random"
            ],
            name: "album-edit-modes.json"
        )
    }

    // Seam: with an empty selection, Start Playback in the filter summary must be disabled.
    @MainActor
    func testFilterEmptySelectionCannotStart() throws {
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }

        try completeFirstBootToModeSelection(app: app, input: input, evidencePrefix: "filter-empty")
        enterFilterSummary(app: app)
        let start = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(
            start.waitForExistence(timeout: TestWait.seconds(.product(8))),
            "Filter summary must show Start Playback")
        XCTAssertFalse(start.isEnabled, "An empty selection must not start")
        attachStrictE2EScreenshot(app: app, name: "filter-empty-\(currentDeviceTag())")
        try StrictE2EVisualEvidence.writeRequiredJSON(
            [
                "album_ids": [],
                "person_filters": [],
                "start_enabled": start.isEnabled,
                "start_button_id": "filterSummary.startPlayback.button"
            ],
            name: "empty-selection.json"
        )
    }

    // Seam: filter from the real mode page; 0/0 cannot start; the target album shows at least two public
    // identities; then switch to the controlled empty album through the settings entry.
    @MainActor
    func testTargetAlbumPlaysAndEmptyAlbumShowsEmptyResult() throws {
        let input = try requireStrictE2EInput()
        let manifest = try loadEvidenceManifest()
        let albumID = try stringValue(manifest, keyPath: ["target_album", "id"])
        let emptyAlbumID = try stringValue(manifest, keyPath: ["empty_album", "id"])
        let emptyCopy = "当前筛选条件没有找到可播放照片，请换一组相册或人物再试。"
        let app = try launchStrictE2EApp()
        defer { app.terminate() }

        try completeFirstBootToModeSelection(app: app, input: input, evidencePrefix: "album-empty")
        enterFilterSummary(app: app)
        let start = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(
            start.waitForExistence(timeout: TestWait.seconds(.product(8))),
            "Filter summary must show Start Playback")
        XCTAssertFalse(start.isEnabled, "Start must be disabled with 0 albums / 0 people")
        attachStrictE2EScreenshot(app: app, name: "album-empty-selection-\(currentDeviceTag())")
        try StrictE2EVisualEvidence.writeRequiredJSON(
            [
                "album_ids": [],
                "person_filters": [],
                "start_enabled": start.isEnabled,
                "start_button_id": "filterSummary.startPlayback.button",
                "identity_source": "public_fixture_photo_mark"
            ],
            name: "empty-selection.json"
        )

        openAlbumFilter(app: app)
        selectAlbum(app: app, albumID: albumID)
        returnFromAlbumFilter(app: app)
        startFilteredPlayback(app: app)
        pausePlaybackIfNeeded(app: app)
        _ = capturePlaybackPNG(app: app, name: "album-play-1")
        tapNext(app: app)
        _ = capturePlaybackPNG(app: app, name: "album-play-2")

        openSettingsHomeFromPlayback(app: app)
        openFilterEditorFromSettings(app: app)
        openAlbumFilterFromEditor(app: app)
        isolateAlbumSelection(app: app, keeping: emptyAlbumID)
        selectAlbum(app: app, albumID: emptyAlbumID)
        returnFromAlbumFilter(app: app)
        let editorStart = app.buttons["filterSummary.startPlayback.button"]
        let didObserveStart = editorStart.exists
        // The Settings filter editor does not present Start Playback; record that explicitly, never as a disabled button.
        let startEnabledAfterEmpty: Any = didObserveStart ? editorStart.isEnabled : "not_applicable_settings_editor"
        attachStrictE2EScreenshot(app: app, name: "album-empty-selected-\(currentDeviceTag())")
        finishFilterEditor(app: app)
        returnToSlideshowFromSettings(app: app)
        _ = captureNamedPNG(app: app, name: "album-empty-after-return-slideshow")
        let emptyLabel = app.staticTexts["slideshow.emptyState.message"]
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(20))) { emptyLabel.exists && emptyLabel.label == emptyCopy },
            "An empty album must show the frozen, existing production empty-result copy and must not keep the old non-empty pool"
        )
        try StrictE2EVisualEvidence.writeRequiredJSON(
            [
                "album_id": emptyAlbumID,
                "start_enabled": startEnabledAfterEmpty,
                "start_button_observed": didObserveStart,
                "empty_copy": emptyLabel.label,
                "identity_source": "public_fixture_photo_mark",
                "entry": "settings.playback.filterConfig.button"
            ],
            name: "empty-album.json"
        )
        _ = captureNamedPNG(app: app, name: "empty-album-result")
    }

    // Seam: real playback for a person with normal matching, after an independent first boot. The selection
    // is not cleared, so the filter never becomes empty and falls back to random.
    @MainActor
    func testFilterPersonNormalMatch() throws {
        let personID = try stringValue(
            try loadEvidenceManifest(), keyPath: ["person_cases", "normal_match", "person_id"])
        try playPersonRuleFromFirstBoot(
            personID: personID,
            isSoloOnly: false,
            screenshotName: "person-normal-1",
            evidencePrefix: "filter-person-normal"
        )
    }

    // Selecting a person changes the card content; the person page must stay visible, and Back must lead
    // only to the filter summary.
    @MainActor
    func testPersonSelectionStaysOnPersonPageAndReturnsToSummary() throws {
        let input = try requireStrictE2EInput()
        let manifest = try loadEvidenceManifest()
        let personID = try stringValue(manifest, keyPath: ["person_cases", "solo_only_qualified", "person_id"])
        let app = try launchStrictE2EApp()
        defer { app.terminate() }

        try completeFirstBootToModeSelection(app: app, input: input, evidencePrefix: "filter-person-navigation")
        enterFilterSummary(app: app)
        openPersonFilter(app: app)

        let back = app.buttons["personFilter.back.button"]
        let card = personNameElement(app: app, personID: personID)
        attachStrictE2EScreenshot(app: app, name: "person-navigation-before-selection-\(currentDeviceTag())")
        assertPersonNavigation(
            back.waitForExistence(timeout: TestWait.seconds(.product(8))) && back.isHittable,
            "Before selection, the person page Back button must be visible and hittable", app: app, personID: personID)
        assertPersonNavigation(
            card.waitForExistence(timeout: TestWait.seconds(.infrastructure(20))) && card.isHittable,
            "Before selection, the target person card must be visible and hittable", app: app, personID: personID)

        selectPerson(app: app, personID: personID, isSoloOnly: false)

        let soloOnlySwitch = personSoloOnlySwitch(app: app, personID: personID)
        attachStrictE2EScreenshot(app: app, name: "person-navigation-after-selection-\(currentDeviceTag())")
        assertPersonNavigation(
            back.exists && back.isHittable,
            "After selection, the app must still be on the person page with Back available", app: app,
            personID: personID)
        assertPersonNavigation(
            card.exists && card.isHittable,
            "After selection, the target person card must still be visible and hittable", app: app, personID: personID)
        assertPersonNavigation(
            soloOnlySwitch.exists && soloOnlySwitch.isHittable,
            "After selection, the solo-only switch on the person page must be visible and hittable", app: app,
            personID: personID)
        assertPersonNavigation(
            (soloOnlySwitch.value as? String) == "0",
            "Only select the person and keep the default normal match; do not switch match rules in the navigation test",
            app: app, personID: personID)

        try returnFromPersonFilterToSummary(app: app)
        let summaryStart = app.buttons["filterSummary.startPlayback.button"]
        assertPersonNavigation(
            summaryStart.exists && summaryStart.isHittable,
            "After Back, the filter summary must be visible and usable", app: app, personID: personID)
        assertPersonNavigation(
            waitUntil(timeout: TestWait.seconds(.product(5))) { !back.exists || !back.isHittable },
            "After returning to the summary, the person page Back button must be gone or not visible; do not rely only on the summary control's exists",
            app: app, personID: personID
        )
    }

    @MainActor
    func testPersonSoloOnlyTogglePersistsAcrossReturn() throws {
        let input = try requireStrictE2EInput()
        let personID = try stringValue(
            try loadEvidenceManifest(), keyPath: ["person_cases", "solo_only_qualified", "person_id"])
        let app = try launchStrictE2EApp()
        defer { app.terminate() }

        try completeFirstBootToModeSelection(app: app, input: input, evidencePrefix: "filter-person-solo-toggle")
        enterFilterSummary(app: app)
        openPersonFilter(app: app)
        selectPerson(app: app, personID: personID, isSoloOnly: true)
        attachStrictE2EScreenshot(app: app, name: "person-solo-enabled-\(currentDeviceTag())")
        try returnFromPersonFilterToSummary(app: app)
        openPersonFilter(app: app)
        let toggle = personSoloOnlySwitch(app: app, personID: personID)
        assertPersonNavigation(
            toggle.waitForExistence(timeout: TestWait.seconds(.product(6))) && (toggle.value as? String) == "1",
            "After going back and reopening, the target person's solo-only mode must still be on", app: app,
            personID: personID)
        selectPerson(app: app, personID: personID, isSoloOnly: false)
        attachStrictE2EScreenshot(app: app, name: "person-solo-disabled-\(currentDeviceTag())")
        try returnFromPersonFilterToSummary(app: app)
        openPersonFilter(app: app)
        let reopenedToggle = personSoloOnlySwitch(app: app, personID: personID)
        assertPersonNavigation(
            reopenedToggle.waitForExistence(timeout: TestWait.seconds(.product(6)))
                && (reopenedToggle.value as? String) == "0",
            "After going back and reopening, the target person's solo-only mode must still be off", app: app,
            personID: personID)
    }

    // Captures the scene only when a public-fixture person navigation assertion fails;
    // waits and pass conditions are unchanged.
    @MainActor
    func assertPersonNavigation(
        _ condition: Bool, _ message: String, app: XCUIApplication, personID: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        if !condition {
            attachStrictE2EScreenshot(app: app, name: "person-navigation-failure-\(currentDeviceTag())")
            let backQuery = app.buttons.matching(identifier: "personFilter.back.button")
            let cardQuery = app.descendants(matching: .any)
                .matching(identifier: "personFilter.person.\(personID).button")
            let attachment = XCTAttachment(
                string:
                    "\(message)\nBACK:\n\(backQuery.debugDescription)\nCARD:\n\(cardQuery.debugDescription)\nAPP:\n\(app.debugDescription)"
            )
            attachment.name = "person-navigation-failure-hierarchy"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(condition, message, file: file, line: line)
    }

    // Seam: the conflict is still person-a-solo + normal (soloOnly=false); "wins" is not the outcome.
    @MainActor
    func testFilterPersonConflictNormal() throws {
        let personID = try stringValue(
            try loadEvidenceManifest(),
            keyPath: ["person_cases", "solo_only_qualified", "person_id"]
        )
        try playPersonRuleFromFirstBoot(
            personID: personID,
            isSoloOnly: false,
            screenshotName: "person-conflict-normal-1",
            evidencePrefix: "filter-person-conflict"
        )
    }

    // Seam: real playback for a person without faces, after an independent first boot;
    // soloOnly stays in filter-vision.
    @MainActor
    func testFilterPersonNoFaces() throws {
        let personID = try stringValue(try loadEvidenceManifest(), keyPath: ["person_cases", "no_faces", "person_id"])
        try playPersonRuleFromFirstBoot(
            personID: personID,
            isSoloOnly: false,
            screenshotName: "person-nofaces-1",
            evidencePrefix: "filter-person-nofaces"
        )
    }

    // Seam: the real UI switches SmartFill to single photo; identity before and after the change is
    // judged from public fixture screenshots.
    @MainActor
    func testSmartFillDisplayPolicyChangesMultiToSingle() throws {
        let input = try requireStrictE2EInput()
        let manifest = try loadEvidenceManifest()
        let albumID = try stringValue(manifest, keyPath: ["target_album", "id"])
        let targetMarks = try stringArrayValue(manifest, keyPath: ["target_album", "labels"])
        let app = try launchStrictE2EApp()
        defer { app.terminate() }

        try completeFirstBootToModeSelection(app: app, input: input, evidencePrefix: "display-policy")
        enterFilterSummary(app: app)
        openAlbumFilterHandlingSystemPrompt(app: app)
        selectAlbum(app: app, albumID: albumID)
        returnFromAlbumFilter(app: app)
        startFilteredPlayback(app: app)
        pausePlaybackIfNeeded(app: app)

        openPlaybackSettingsFromSlideshow(app: app)
        selectSinglePhotoDisplayMode(app: app)
        selectSmartFillDisplayMode(app: app)
        try disableExifForDisplayEvidence(app: app)
        _ = captureNamedPNG(app: app, name: "display-settings-smartFill")
        returnToSlideshowFromSettings(app: app)
        pausePlaybackIfNeeded(app: app)
        let processBefore = try strictE2EProcessID(app)

        var candidateSteps: [String] = []
        var selectedBefore: Data?
        for index in 1...4 {
            try waitForDisplayControlsToHide(app: app)
            RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(1.0))))
            let png = app.screenshot().pngRepresentation
            let step = String(format: "display-before-candidate-%02d", index)
            XCTAssertFalse(png.isEmpty, "Before-change candidate screenshot must not be empty: \(step)")
            candidateSteps.append(step)
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = step
            attachment.lifetime = .keepAlways
            add(attachment)
            try StrictE2EVisualEvidence.writeRequiredPNG(png, name: step)

            let candidate = try displayCandidatePNG(png)
            let marks = distinctRegionMarks(StrictE2EPhotoIdentity.classifyRegions(png: candidate))
            if marks.count >= 2 {
                XCTAssertTrue(
                    Set(marks).isSubset(of: Set(targetMarks)),
                    "Every photo in the before-change multi-photo frame must belong to the manifest target album: \(marks)"
                )
                selectedBefore = png
                break
            }
            if index < 4 {
                tapNext(app: app)
            }
        }
        guard let selectedBefore, let selectedStep = candidateSteps.last else {
            throw StrictE2EPhotoIdentity.AssertionError.message(
                "No two distinct target-album photos were seen in one full four-frame candidate rotation; all candidate originals were kept."
            )
        }
        try StrictE2EVisualEvidence.writeRequiredPNG(selectedBefore, name: "display-before")

        openPlaybackSettingsFromSlideshow(app: app)
        selectSinglePhotoDisplayMode(app: app)
        _ = captureNamedPNG(app: app, name: "display-settings-singlePhoto")
        returnToSlideshowFromSettings(app: app)
        pausePlaybackIfNeeded(app: app)

        try waitForDisplayControlsToHide(app: app)
        var afterPNG: Data?
        let afterIsStableSingle = waitUntil(timeout: TestWait.seconds(.product(20))) {
            let png = app.screenshot().pngRepresentation
            guard let candidate = try? self.displayCandidatePNG(png) else { return false }
            let identity = StrictE2EPhotoIdentity.classify(png: candidate)
            guard identity.status == .match,
                let mark = identity.mark,
                targetMarks.contains(mark)
            else { return false }
            let regions = StrictE2EPhotoIdentity.classifyRegions(png: candidate)
            let stableNames = ["center", "left", "right", "mid_left", "mid_right", "upper"]
            guard
                stableNames.allSatisfy({ name in
                    guard let region = regions[name] else { return false }
                    return region.status == .match && region.mark == mark
                }), self.distinctRegionMarks(regions).count < 2
            else { return false }
            afterPNG = png
            return true
        }
        XCTAssertTrue(
            afterIsStableSingle,
            "After the change it must be a stable single photo from the target album, not a transition or multi-photo")
        guard let afterPNG else {
            throw StrictE2EPhotoIdentity.AssertionError.message(
                "No stable single-photo original was observed after the change.")
        }
        try StrictE2EVisualEvidence.writeRequiredPNG(afterPNG, name: "display-after")
        let processAfter = try strictE2EProcessID(app)
        XCTAssertEqual(
            processAfter, processBefore, "The same live app process must run before and after the display policy change"
        )
        try StrictE2EVisualEvidence.writeRequiredJSON(
            [
                "identity_source": "public_fixture_photo_mark",
                "setting_source": "accessibility_ui",
                "mode_before": "smartFill",
                "mode_after": "singlePhoto",
                "process_id_before": processBefore,
                "process_id_after": processAfter,
                "before_candidate_steps": candidateSteps,
                "selected_before_step": selectedStep
            ],
            name: "display-policy.json"
        )
    }

    @MainActor
    func waitForDisplayControlsToHide(app: XCUIApplication) throws {
        guard
            waitUntil(
                timeout: TestWait.seconds(.product(12)),
                condition: {
                    !app.buttons["slideshow.control.playPause.button"].exists
                })
        else {
            throw StrictE2EPhotoIdentity.AssertionError.message(
                "Display policy screenshots must wait for the toolbar to hide on its own, without cropping unknown content"
            )
        }
        // A 0.3 s exit animation still runs after the AX node disappears; wait for it before capturing.
        RunLoop.current.run(until: Date().addingTimeInterval(TestWait.seconds(.product(0.5))))
    }

    // Seam: save filters on server A, then switch to B; old album/person IDs must not reach B's UI
    // or playback.
    @MainActor
    func testFilterServerSwitchIsolation() throws {
        let input = try requireStrictE2EInput()
        let peerURL = try requireStrictE2EPeerServerURL()
        XCTAssertNotEqual(input.serverURL, peerURL, "A and B must be two different server URLs")
        let manifestA = try loadEvidenceManifest(named: "member-manifest-a.json")
        let manifestB = try loadEvidenceManifest(named: "member-manifest-b.json")
        let albumA = try stringValue(manifestA, keyPath: ["target_album", "id"])
        let albumB = try stringValue(manifestB, keyPath: ["target_album", "id"])
        let app = try launchStrictE2EApp()
        defer { app.terminate() }

        try completeFirstBootToModeSelection(app: app, input: input, evidencePrefix: "filter-switch-a")
        enterFilterSummary(app: app)
        openAlbumFilterHandlingSystemPrompt(app: app)
        setAlbumSelection(app: app, albumID: albumA, isSelectionRequested: true)
        returnFromAlbumFilter(app: app)
        startFilteredPlayback(app: app)
        pausePlaybackIfNeeded(app: app)

        changeServerFromPlayback(app: app, serverURL: peerURL, publicKey: input.publicKey)
        openFilterEditorFromSettings(app: app)
        let observed = collectVisibleFilterIDs(app: app)
        XCTAssertFalse(observed.contains(albumA), "After the server switch, the UI must not still list A's album ID")
        for item in observed {
            XCTAssertFalse(
                item.hasPrefix("album-a-") || item.hasPrefix("person-a-") || item.hasPrefix("asset-a-"),
                "Old ID left in the UI after the server switch: \(item)")
        }

        openAlbumFilterFromEditor(app: app)
        setAlbumSelection(app: app, albumID: albumB, isSelectionRequested: true)
        returnFromAlbumFilter(app: app)
        finishFilterEditor(app: app)
        returnToSlideshowFromSettings(app: app)
        pausePlaybackIfNeeded(app: app)
        _ = capturePlaybackPNG(app: app, name: "switch-b-play-1")
        tapNext(app: app)
        _ = capturePlaybackPNG(app: app, name: "switch-b-play-2")
        try StrictE2EVisualEvidence.writeRequiredJSON(["ids": observed], name: "observed-ids.json")

        let targetMarksB = try stringArrayValue(manifestB, keyPath: ["target_album", "labels"])
        let processBefore = try strictE2EProcessID(app)
        openPlaybackSettingsFromSlideshow(app: app)
        selectSinglePhotoDisplayMode(app: app)
        try disableExifForDisplayEvidence(app: app)
        returnToSlideshowFromSettings(app: app)
        pausePlaybackIfNeeded(app: app)
        try waitForDisplayControlsToHide(app: app)

        var singleAfterSwitchPNG: Data?
        let isStableBSingle = waitUntil(timeout: TestWait.seconds(.product(20))) {
            let png = app.screenshot().pngRepresentation
            guard let candidate = try? self.displayCandidatePNG(png) else { return false }
            let identity = StrictE2EPhotoIdentity.classify(png: candidate)
            guard identity.status == .match,
                let mark = identity.mark,
                targetMarksB.contains(mark),
                self.distinctRegionMarks(StrictE2EPhotoIdentity.classifyRegions(png: candidate)).count < 2
            else {
                return false
            }
            singleAfterSwitchPNG = png
            return true
        }
        XCTAssertTrue(
            isStableBSingle,
            "After the server switch, single-photo mode must show a stable single photo from B's target album")
        guard let singleAfterSwitchPNG else {
            throw StrictE2EPhotoIdentity.AssertionError.message(
                "No single-photo original from B's target album was observed after the server switch.")
        }
        let attachment = XCTAttachment(data: singleAfterSwitchPNG, uniformTypeIdentifier: "public.png")
        attachment.name = "switch-b-single-after"
        attachment.lifetime = .keepAlways
        add(attachment)
        try StrictE2EVisualEvidence.writeRequiredPNG(singleAfterSwitchPNG, name: "switch-b-single-after")
        let processAfter = try strictE2EProcessID(app)
        XCTAssertEqual(
            processAfter, processBefore,
            "The same process must run before and after applying single-photo mode after the server switch")
        try StrictE2EVisualEvidence.writeRequiredJSON(
            [
                "identity_source": "public_fixture_photo_mark",
                "setting_source": "accessibility_ui",
                "mode_after": "singlePhoto",
                "process_id_before": processBefore,
                "process_id_after": processAfter
            ],
            name: "display-policy-after-switch.json"
        )
    }

    // Seam: switch to B after playing on A; old IDs must not reach B; the same live process switches
    // Smart Fill to single photo.
    @MainActor
    func testServerSwitchDropsOldFiltersAndDisplayPolicyAppliesImmediately() throws {
        let input = try requireStrictE2EInput()
        let peerURL = try requireStrictE2EPeerServerURL()
        XCTAssertNotEqual(input.serverURL, peerURL, "A and B must be two different server URLs")
        let manifestA = try loadEvidenceManifest(named: "member-manifest-a.json")
        let manifestB = try loadEvidenceManifest(named: "member-manifest-b.json")
        let albumA = try stringValue(manifestA, keyPath: ["target_album", "id"])
        let albumB = try stringValue(manifestB, keyPath: ["target_album", "id"])
        let app = try launchStrictE2EApp()
        defer { app.terminate() }

        try completeFirstBootToModeSelection(app: app, input: input, evidencePrefix: "server-switch-a")
        enterFilterSummary(app: app)
        openAlbumFilterHandlingSystemPrompt(app: app)
        selectAlbumHandlingSystemPrompt(app: app, albumID: albumA)
        returnFromAlbumFilter(app: app)
        _ = captureNamedPNG(app: app, name: "server-switch-album-summary-\(albumA)")
        let startA = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(
            startA.waitForExistence(timeout: TestWait.seconds(.product(8))) && startA.isEnabled,
            "Start Playback must be enabled after selecting the target album")
        startFilteredPlayback(app: app)
        pausePlaybackIfNeeded(app: app)
        _ = capturePlaybackPNG(app: app, name: "server-switch-a-play-1")

        changeServerFromPlayback(app: app, serverURL: peerURL, publicKey: input.publicKey)
        _ = captureNamedPNG(app: app, name: "server-switch-b-save-success")
        openFilterEditorFromSettings(app: app)
        _ = captureNamedPNG(app: app, name: "server-switch-b-selection-cleared")
        let collected = collectVisibleFilterEvidence(app: app)
        XCTAssertFalse(
            collected.ids.contains(albumA), "After the server switch, the UI must not still list A's album ID")
        for item in collected.ids {
            XCTAssertFalse(
                item.hasPrefix("album-a-") || item.hasPrefix("person-a-") || item.hasPrefix("asset-a-"),
                "Old ID left in the UI after the server switch: \(item)")
        }
        XCTAssertFalse(
            collected.ids.isEmpty,
            "After the server switch, B's filter IDs must be collected from the UI, not assembled from the manifest")
        XCTAssertFalse(
            collected.raw.isEmpty,
            "After the server switch, UI identifiers must be recorded, not assembled from the expected manifest")
        try StrictE2EVisualEvidence.writeRequiredJSON(
            [
                "identity_source": "ui_accessibility_identifier",
                "ids": collected.ids,
                "raw_identifiers": collected.raw
            ],
            name: "observed-ids.json"
        )
        openAlbumFilterFromEditor(app: app)
        selectAlbumHandlingSystemPrompt(app: app, albumID: albumB)
        returnFromAlbumFilter(app: app)
        _ = captureNamedPNG(app: app, name: "server-switch-album-summary-\(albumB)")
        assertSettingsFilterEditorAfterServerSwitchAlbumSelection(app: app)
        finishFilterEditor(app: app)
        returnToSlideshowFromSettings(app: app)
        pausePlaybackIfNeeded(app: app)
        _ = capturePlaybackPNG(app: app, name: "switch-b-play-1")
        let beforeMarks = waitForDistinctRegionMarks(app: app, timeout: TestWait.seconds(.product(8)))
        if beforeMarks.count < 2 {
            tapNext(app: app)
        }
        let multiMarks = waitForDistinctRegionMarks(app: app, timeout: TestWait.seconds(.product(12)))
        XCTAssertGreaterThanOrEqual(
            multiMarks.count, 2,
            "Before the change it must really be multi-photo; a full-frame single-photo MATCH does not count")
        _ = capturePlaybackPNG(app: app, name: "display-before")
        tapNext(app: app)
        _ = capturePlaybackPNG(app: app, name: "switch-b-play-2")

        openPlaybackSettingsFromSlideshow(app: app)
        selectSinglePhotoDisplayMode(app: app)
        _ = captureNamedPNG(app: app, name: "display-settings")
        try StrictE2EVisualEvidence.writeRequiredJSON(
            ["identity_source": "public_fixture_photo_mark"],
            name: "display-policy.json"
        )
        returnToSlideshowFromSettings(app: app)
        pausePlaybackIfNeeded(app: app)
        let after = waitForStablePublicPhoto(app: app, timeout: TestWait.seconds(.product(20)))
        XCTAssertEqual(
            after?.status, .match,
            "After the change, wait for the current transition to end; the stable single photo must not be TRANSITION")
        _ = capturePlaybackPNG(app: app, name: "display-after")
    }

    // Seam: soloOnly Vision runs separately on a real device; the simulator may only report UNVERIFIED,
    // never pose as PASS.
    @MainActor
    func testFilterVisionSoloOnlyOnDevice() throws {
        if isRunningOnSimulator {
            try requireEvidenceDirectory()
            try StrictE2EVisualEvidence.writeRequiredJSON(
                [
                    "environment": "simulator",
                    "vision_available": false
                ],
                name: "vision-environment.json"
            )
            return
        }

        let input = try requireStrictE2EInput()
        let manifest = try loadEvidenceManifest()
        let soloID = try stringValue(manifest, keyPath: ["person_cases", "solo_only_qualified", "person_id"])
        let app = try launchStrictE2EApp()
        defer { app.terminate() }
        try completeFirstBootToModeSelection(app: app, input: input, evidencePrefix: "filter-vision")
        enterFilterSummary(app: app)
        openPersonFilter(app: app)
        selectPerson(app: app, personID: soloID, isSoloOnly: true)
        returnFromPersonFilter(app: app)
        startFilteredPlayback(app: app)
        pausePlaybackIfNeeded(app: app)
        _ = capturePlaybackPNG(app: app, name: "vision-solo-1")
        // The face count must be measured by Vision on a real device; never hard-code 1 to pass by luck.
        XCTFail(
            "Real-device Vision measurement (qualified_marks and face_counts) is not implemented, so this path cannot produce evidence; vision-environment.json was not written."
        )
    }

    var isRunningOnSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    func requireEvidenceDirectory() throws {
        XCTAssertNotNil(StrictE2EVisualEvidence.directory(), "The filter suite requires STRICT_E2E_EVIDENCE_DIR")
    }

    func displayCandidatePNG(_ png: Data) throws -> Data {
        guard let directory = StrictE2EVisualEvidence.directory() else {
            throw StrictE2EFilterContract.AssertionError.message("Missing STRICT_E2E_EVIDENCE_DIR")
        }
        return try StrictE2EFilterContract.displayCandidatePNG(png, evidenceDirectory: directory)
    }

    func loadEvidenceManifest(named name: String = "member-manifest.json") throws -> [String: Any] {
        guard let directory = StrictE2EVisualEvidence.directory() else {
            throw StrictE2EFilterContract.AssertionError.message("Missing STRICT_E2E_EVIDENCE_DIR")
        }
        if name == "member-manifest.json" {
            return try StrictE2EFilterContract.loadMemberManifest(from: directory)
        }
        let url = directory.appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StrictE2EFilterContract.AssertionError.message("\(name) is unreadable")
        }
        return payload
    }
}
#endif
