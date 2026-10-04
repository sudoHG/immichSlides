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
        setAlbumSelection(app: app, albumID: targetAlbumID, selected: true)
        returnFromAlbumFilter(app: app)
        startFilteredPlayback(app: app)
        pausePlaybackIfNeeded(app: app)

        openSettingsHomeFromPlayback(app: app)
        openFilterEditorFromSettings(app: app)
        openAlbumFilterFromEditor(app: app)
        setAlbumSelection(app: app, albumID: targetAlbumID, selected: false)
        setAlbumSelection(app: app, albumID: nonTargetAlbumID, selected: true)
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
            modePicker.waitForExistence(timeout: 8), "Leaving the editor must return to the real playback settings page"
        )
        let filteredMode = modePicker.buttons.element(boundBy: 1)
        XCTAssertTrue(
            waitUntil(timeout: 6) { filteredMode.isSelected },
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
            clear.waitForExistence(timeout: 8) && clear.isHittable, "The real album editor must offer Clear Selection")
        tapElement(clear)
        let clearedTarget = albumCard(app: app, albumID: targetAlbumID)
        let clearedNonTarget = albumCard(app: app, albumID: nonTargetAlbumID)
        XCTAssertTrue(
            waitUntil(timeout: 6) {
                !self.albumCardLooksSelected(clearedTarget) && !self.albumCardLooksSelected(clearedNonTarget)
            },
            "After tapping Clear, target and non-target albums must both really become unselected; tapping cards one by one must not stand in for the clear result"
        )
        returnFromAlbumFilter(app: app)
        finishFilterEditor(app: app)

        XCTAssertTrue(
            modePicker.waitForExistence(timeout: 8),
            "Clearing and leaving the editor must return to the real playback settings page")
        let randomMode = modePicker.buttons.element(boundBy: 0)
        XCTAssertTrue(
            waitUntil(timeout: 6) { randomMode.isSelected },
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
        XCTAssertTrue(start.waitForExistence(timeout: 8), "Filter summary must show Start Playback")
        XCTAssertFalse(start.isEnabled, "An empty selection must not start")
        attachStrictE2EScreenshot(app: app, name: "filter-empty-\(currentDeviceTag())")
        StrictE2EVisualEvidence.writeJSON(
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
        XCTAssertTrue(start.waitForExistence(timeout: 8), "Filter summary must show Start Playback")
        XCTAssertFalse(start.isEnabled, "Start must be disabled with 0 albums / 0 people")
        attachStrictE2EScreenshot(app: app, name: "album-empty-selection-\(currentDeviceTag())")
        StrictE2EVisualEvidence.writeJSON(
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
        let startObserved = editorStart.exists
        let startEnabledAfterEmpty = startObserved && editorStart.isEnabled
        attachStrictE2EScreenshot(app: app, name: "album-empty-selected-\(currentDeviceTag())")
        finishFilterEditor(app: app)
        returnToSlideshowFromSettings(app: app)
        _ = captureNamedPNG(app: app, name: "album-empty-after-return-slideshow")
        let emptyLabel = app.staticTexts["slideshow.emptyState.message"]
        XCTAssertTrue(
            waitUntil(timeout: 20) { emptyLabel.exists && emptyLabel.label == emptyCopy },
            "An empty album must show the frozen, existing production empty-result copy and must not keep the old non-empty pool"
        )
        StrictE2EVisualEvidence.writeJSON(
            [
                "album_id": emptyAlbumID,
                "start_enabled": startEnabledAfterEmpty,
                "start_button_observed": startObserved,
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
            soloOnly: false,
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
            back.waitForExistence(timeout: 8) && back.isHittable,
            "Before selection, the person page Back button must be visible and hittable", app: app, personID: personID)
        assertPersonNavigation(
            card.waitForExistence(timeout: 20) && card.isHittable,
            "Before selection, the target person card must be visible and hittable", app: app, personID: personID)

        selectPerson(app: app, personID: personID, soloOnly: false)

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

        returnFromPersonFilterToSummary(app: app)
        let summaryStart = app.buttons["filterSummary.startPlayback.button"]
        assertPersonNavigation(
            summaryStart.exists && summaryStart.isHittable,
            "After Back, the filter summary must be visible and usable", app: app, personID: personID)
        assertPersonNavigation(
            waitUntil(timeout: 5) { !back.exists || !back.isHittable },
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
        selectPerson(app: app, personID: personID, soloOnly: true)
        attachStrictE2EScreenshot(app: app, name: "person-solo-enabled-\(currentDeviceTag())")
        returnFromPersonFilterToSummary(app: app)
        openPersonFilter(app: app)
        let toggle = personSoloOnlySwitch(app: app, personID: personID)
        assertPersonNavigation(
            toggle.waitForExistence(timeout: 6) && (toggle.value as? String) == "1",
            "After going back and reopening, the target person's solo-only mode must still be on", app: app,
            personID: personID)
        selectPerson(app: app, personID: personID, soloOnly: false)
        attachStrictE2EScreenshot(app: app, name: "person-solo-disabled-\(currentDeviceTag())")
        returnFromPersonFilterToSummary(app: app)
    }

    // Captures the scene only when a public-fixture person navigation assertion fails;
    // waits and pass conditions are unchanged.
    @MainActor
    private func assertPersonNavigation(
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
            soloOnly: false,
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
            soloOnly: false,
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
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
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
        let afterIsStableSingle = waitUntil(timeout: 20) {
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
    private func waitForDisplayControlsToHide(app: XCUIApplication) throws {
        guard
            waitUntil(
                timeout: 12,
                condition: {
                    !app.buttons["slideshow.control.playPause.button"].exists
                })
        else {
            throw StrictE2EPhotoIdentity.AssertionError.message(
                "Display policy screenshots must wait for the toolbar to hide on its own, without cropping unknown content"
            )
        }
        // A 0.3 s exit animation still runs after the AX node disappears; wait for it before capturing.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
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
        setAlbumSelection(app: app, albumID: albumA, selected: true)
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
        setAlbumSelection(app: app, albumID: albumB, selected: true)
        returnFromAlbumFilter(app: app)
        finishFilterEditor(app: app)
        returnToSlideshowFromSettings(app: app)
        pausePlaybackIfNeeded(app: app)
        _ = capturePlaybackPNG(app: app, name: "switch-b-play-1")
        tapNext(app: app)
        _ = capturePlaybackPNG(app: app, name: "switch-b-play-2")
        StrictE2EVisualEvidence.writeJSON(["ids": observed + [albumB]], name: "observed-ids.json")

        let targetMarksB = try stringArrayValue(manifestB, keyPath: ["target_album", "labels"])
        let processBefore = try strictE2EProcessID(app)
        openPlaybackSettingsFromSlideshow(app: app)
        selectSinglePhotoDisplayMode(app: app)
        try disableExifForDisplayEvidence(app: app)
        returnToSlideshowFromSettings(app: app)
        pausePlaybackIfNeeded(app: app)
        try waitForDisplayControlsToHide(app: app)

        var singleAfterSwitchPNG: Data?
        let isStableBSingle = waitUntil(timeout: 20) {
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
            startA.waitForExistence(timeout: 8) && startA.isEnabled,
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
        StrictE2EVisualEvidence.writeJSON(
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
        let beforeMarks = waitForDistinctRegionMarks(app: app, timeout: 8)
        if beforeMarks.count < 2 {
            tapNext(app: app)
        }
        let multiMarks = waitForDistinctRegionMarks(app: app, timeout: 12)
        XCTAssertGreaterThanOrEqual(
            multiMarks.count, 2,
            "Before the change it must really be multi-photo; a full-frame single-photo MATCH does not count")
        _ = capturePlaybackPNG(app: app, name: "display-before")
        tapNext(app: app)
        _ = capturePlaybackPNG(app: app, name: "switch-b-play-2")

        openPlaybackSettingsFromSlideshow(app: app)
        selectSinglePhotoDisplayMode(app: app)
        _ = captureNamedPNG(app: app, name: "display-settings")
        StrictE2EVisualEvidence.writeJSON(
            ["identity_source": "public_fixture_photo_mark"],
            name: "display-policy.json"
        )
        returnToSlideshowFromSettings(app: app)
        pausePlaybackIfNeeded(app: app)
        let after = waitForStablePublicPhoto(app: app, timeout: 20)
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
            StrictE2EVisualEvidence.writeJSON(
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
        selectPerson(app: app, personID: soloID, soloOnly: true)
        returnFromPersonFilter(app: app)
        startFilteredPlayback(app: app)
        pausePlaybackIfNeeded(app: app)
        _ = capturePlaybackPNG(app: app, name: "vision-solo-1")
        // The face count must be measured by Vision on a real device; never hard-code 1 to pass by luck.
        StrictE2EVisualEvidence.writeJSON(
            [
                "environment": "device",
                "vision_available": true
            ],
            name: "vision-environment.json"
        )
    }

    private var isRunningOnSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    private func requireEvidenceDirectory() throws {
        XCTAssertNotNil(StrictE2EVisualEvidence.directory(), "The filter suite requires STRICT_E2E_EVIDENCE_DIR")
    }

    private func displayCandidatePNG(_ png: Data) throws -> Data {
        guard let directory = StrictE2EVisualEvidence.directory() else {
            throw StrictE2EFilterContract.AssertionError.message("Missing STRICT_E2E_EVIDENCE_DIR")
        }
        return try StrictE2EFilterContract.displayCandidatePNG(png, evidenceDirectory: directory)
    }

    private func loadEvidenceManifest(named name: String = "member-manifest.json") throws -> [String: Any] {
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

    private func stringValue(_ payload: [String: Any], keyPath: [String]) throws -> String {
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

    private func stringArrayValue(_ payload: [String: Any], keyPath: [String]) throws -> [String] {
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

    private func strictE2EProcessID(_ app: XCUIApplication) throws -> Int {
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
    private func playPersonRuleFromFirstBoot(
        personID: String,
        soloOnly: Bool,
        screenshotName: String,
        evidencePrefix: String
    ) throws {
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }
        try completeFirstBootToModeSelection(app: app, input: input, evidencePrefix: evidencePrefix)
        enterFilterSummary(app: app)
        openPersonFilter(app: app)
        selectPerson(app: app, personID: personID, soloOnly: soloOnly)
        returnFromPersonFilterToSummary(app: app)
        startFilteredPlayback(app: app)
        pausePlaybackIfNeeded(app: app)
        _ = capturePlaybackPNG(app: app, name: screenshotName)
        writePersonResultsJSON()
    }

    private func writePersonResultsJSON() {
        let soloOnly: [String: Any] =
            isRunningOnSimulator
            ? ["environment": "simulator", "verdict": "UNVERIFIED"]
            : ["environment": "device", "verdict": "UNVERIFIED"]
        StrictE2EVisualEvidence.writeJSON(
            [
                "cases": [
                    "solo_only": soloOnly
                ]
            ],
            name: "person-results.json"
        )
    }

    @MainActor
    private func completeFirstBootToModeSelection(
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
    private func disableExifForDisplayEvidence(app: XCUIApplication) throws {
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
    private func fillFirstBootForm(app: XCUIApplication, input: StrictE2EInput) throws {
        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(
            serverField.waitForExistence(timeout: 20), "A fresh install must open the normal first-boot page.")
        replaceText(
            in: serverField, app: app, with: input.serverURL, evidenceName: "firstboot-url-replace",
            requireExactValue: true)
        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 8), "First-boot page must show the API Key field.")
        replaceText(
            in: apiKeyField, app: app, with: input.publicKey, evidenceName: "firstboot-apikey-replace",
            requireExactValue: false)
        XCTAssertTrue(
            waitUntil(timeout: 3) { self.secureFieldHasEnteredValue(apiKeyField) },
            "API Key must actually be entered into the secure field.")
        commitFocusedInputIfNeeded(app: app)
    }

    @MainActor
    private func enterFilterSummary(app: XCUIApplication) {
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
    private func openAlbumFilterHandlingSystemPrompt(app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(15)
        var tapped = false
        while Date() < deadline {
            if systemSavePasswordPromptVisible(app: app) {
                _ = captureNamedPNG(app: app, name: "server-switch-entry-password-prompt")
                guard dismissSystemSavePasswordPromptIfPresent(app: app, timeout: 4) else { break }
                tapped = false
            }
            let back = app.buttons["albumFilter.back.button"]
            if back.exists && back.isHittable { return }
            let entry = app.buttons["filterSummary.album.button"]
            if !tapped && entry.exists && entry.isHittable {
                entry.tap()
                tapped = true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        _ = captureNamedPNG(app: app, name: "server-switch-album-entry-failure")
        XCTFail("After handling the named system prompt, a usable album list must open")
    }

    @MainActor
    private func openAlbumFilter(app: XCUIApplication) {
        tapElement(app.buttons["filterSummary.album.button"])
        XCTAssertTrue(
            app.buttons["albumFilter.back.button"].waitForExistence(timeout: 12)
                || app.buttons["albumFilter.selectAll.button"].waitForExistence(timeout: 2),
            "Album filter page must open"
        )
    }

    @MainActor
    private func openPersonFilter(app: XCUIApplication) {
        tapElement(app.buttons["filterSummary.person.button"])
        XCTAssertTrue(
            app.buttons["personFilter.back.button"].waitForExistence(timeout: 12)
                || app.buttons["personFilter.selectAll.button"].waitForExistence(timeout: 2),
            "Person filter page must open"
        )
    }

    @MainActor
    private func openAlbumFilterFromEditor(app: XCUIApplication) {
        let entry = app.buttons["filter.editor.album.entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "Filter editor must offer the album entry")
        tapElement(entry)
        _ = app.buttons["albumFilter.back.button"].waitForExistence(timeout: 12)
    }

    @MainActor
    private func openPersonFilterFromEditor(app: XCUIApplication) {
        let entry = app.buttons["filter.editor.person.entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "Filter editor must offer the person entry")
        tapElement(entry)
        _ = app.buttons["personFilter.back.button"].waitForExistence(timeout: 12)
    }

    @MainActor
    private func selectAlbum(app: XCUIApplication, albumID: String) {
        let button = app.buttons["albumFilter.album.\(albumID).button"]
        XCTAssertTrue(button.waitForExistence(timeout: 20), "Album \(albumID) must appear")
        tapElement(button)
    }

    @MainActor
    private func setAlbumSelection(app: XCUIApplication, albumID: String, selected: Bool) {
        let card = albumCard(app: app, albumID: albumID)
        XCTAssertTrue(card.waitForExistence(timeout: 20), "Album \(albumID) must appear")
        XCTAssertTrue(
            waitUntil(timeout: 12) {
                if self.systemSavePasswordPromptVisible(app: app) {
                    _ = self.dismissSystemSavePasswordPromptIfPresent(app: app, timeout: 2)
                    return false
                }
                return card.exists && card.isHittable
            },
            "Album must be visible and hittable; state injection is no substitute"
        )
        if albumCardLooksSelected(card) != selected {
            guard !systemSavePasswordPromptVisible(app: app), card.isHittable else {
                XCTFail("Before the tap, the album must still be visible and not covered by a system prompt")
                return
            }
            card.tap()
        }
        XCTAssertTrue(
            waitUntil(timeout: 6) { self.albumCardLooksSelected(card) == selected },
            "Album \(albumID) must actually reach the requested selection state"
        )
    }

    // During server switching, the system "Save Password?" prompt can cover the albums. Tap only "Not Now",
    // wait until the album is hittable before tapping, and never tap through the prompt by coordinates.
    @MainActor
    private func selectAlbumHandlingSystemPrompt(app: XCUIApplication, albumID: String) {
        if systemSavePasswordPromptVisible(app: app) {
            XCTAssertTrue(
                dismissSystemSavePasswordPromptIfPresent(app: app, timeout: 6),
                "The system Save Password prompt must be closed with 'Not Now'; test credentials must not be saved"
            )
        }
        _ = captureNamedPNG(app: app, name: "server-switch-album-before-select-\(albumID)")
        tapAlbumWhenHittable(app: app, albumID: albumID)
        if !albumCardLooksSelected(albumCard(app: app, albumID: albumID))
            && systemSavePasswordPromptVisible(app: app)
        {
            _ = captureNamedPNG(app: app, name: "server-switch-save-password-late-\(albumID)")
            XCTAssertTrue(
                dismissSystemSavePasswordPromptIfPresent(app: app, timeout: 6),
                "A late Save Password prompt allows only this one retry, backed by evidence"
            )
            tapAlbumWhenHittable(app: app, albumID: albumID)
        }
        XCTAssertTrue(
            waitUntil(timeout: 4) { self.albumCardLooksSelected(self.albumCard(app: app, albumID: albumID)) },
            "Target album must be selected; no blind taps while the prompt covers it"
        )
        _ = captureNamedPNG(app: app, name: "server-switch-album-after-select-\(albumID)")
    }

    @MainActor
    private func tapAlbumWhenHittable(app: XCUIApplication, albumID: String) {
        if systemSavePasswordPromptVisible(app: app) {
            XCTAssertTrue(
                dismissSystemSavePasswordPromptIfPresent(app: app, timeout: 6),
                "Do not tap the album while the prompt covers it"
            )
        }
        let identifier = "albumFilter.album.\(albumID).button"
        XCTAssertTrue(
            waitUntil(timeout: 12) {
                if self.systemSavePasswordPromptVisible(app: app) {
                    _ = self.dismissSystemSavePasswordPromptIfPresent(app: app, timeout: 2)
                    return false
                }
                let button = app.buttons[identifier]
                return button.exists && button.isHittable
            },
            "After closing the Save Password prompt, a fresh query must find the target album hittable"
        )
        let button = app.buttons[identifier]
        XCTAssertFalse(systemSavePasswordPromptVisible(app: app), "Do not tap the album while the prompt covers it")
        XCTAssertTrue(button.isHittable, "Target album must be hittable; no coordinate fallback")
        if albumCardLooksSelected(button) { return }
        button.tap()
    }

    @MainActor
    private func albumCard(app: XCUIApplication, albumID: String) -> XCUIElement {
        app.buttons["albumFilter.album.\(albumID).button"]
    }

    @MainActor
    private func albumCardLooksSelected(_ button: XCUIElement) -> Bool {
        if button.isSelected { return true }
        let value = String(describing: button.value ?? "")
        if value.contains("已选中") { return true }
        return button.images["checkmark.circle.fill"].exists
    }

    @MainActor
    private func namedSavePasswordPrompt(in app: XCUIApplication) -> XCUIElement? {
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
    private func systemSavePasswordPromptVisible(app: XCUIApplication) -> Bool {
        namedSavePasswordPrompt(in: app) != nil
            || namedSavePasswordPrompt(in: XCUIApplication(bundleIdentifier: "com.apple.springboard")) != nil
    }

    @discardableResult
    @MainActor
    private func dismissSystemSavePasswordPromptIfPresent(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for host in [app, springboard] {
                guard let prompt = namedSavePasswordPrompt(in: host) else { continue }
                // ui-label-lookup: Dismiss the iOS Save Password sheet without saving credentials.
                let later = prompt.buttons["以后"].exists ? prompt.buttons["以后"] : prompt.buttons["Not Now"]
                guard later.exists else { continue }
                later.tap()
                _ = waitUntil(timeout: 2) { !self.systemSavePasswordPromptVisible(app: app) }
                return !systemSavePasswordPromptVisible(app: app)
            }
            if !systemSavePasswordPromptVisible(app: app) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return !systemSavePasswordPromptVisible(app: app)
    }

    @MainActor
    private func personNameElement(app: XCUIApplication, personID: String) -> XCUIElement {
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
    private func personSoloOnlySwitch(app: XCUIApplication, personID: String) -> XCUIElement {
        app.switches["personFilter.person.\(personID).button"]
    }

    @MainActor
    private func selectPerson(app: XCUIApplication, personID: String, soloOnly: Bool) {
        let card = personNameElement(app: app, personID: personID)
        let toggle = personSoloOnlySwitch(app: app, personID: personID)
        if !toggle.exists {
            tapElement(card)
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 6), "Solo-only switch must appear after selecting the person")
        let isOn = (toggle.value as? String) == "1"
        if soloOnly != isOn {
            // Tap the actual knob on the right of the switch; tapping the middle of the combined SwiftUI label
            // may not toggle the value.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        assertPersonNavigation(
            waitUntil(timeout: 6) { (toggle.value as? String) == (soloOnly ? "1" : "0") },
            "Target person's solo-only mode must reach the requested value", app: app, personID: personID)
    }

    @MainActor
    private func returnFromAlbumFilter(app: XCUIApplication) {
        let back = app.buttons["albumFilter.back.button"]
        XCTAssertTrue(back.waitForExistence(timeout: 8), "Album filter must be able to go back")
        tapElement(back)
    }

    @MainActor
    private func returnFromPersonFilter(app: XCUIApplication) {
        let back = app.buttons["personFilter.back.button"]
        XCTAssertTrue(back.waitForExistence(timeout: 8), "Person filter must be able to go back")
        back.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor
    private func returnFromPersonFilterToSummary(app: XCUIApplication) {
        let backCountBeforeTap = app.buttons.matching(identifier: "personFilter.back.button").count
        NSLog("personFilter.back.button.count.before-tap \(backCountBeforeTap)")
        returnFromPersonFilter(app: app)
        let immediate = snapshotPersonReturnSurface(app, backCountBeforeTap: backCountBeforeTap)
        NSLog("person-return-immediate \(immediate)")
        attachStrictE2EScreenshot(app: app, name: "person-return-immediate-\(currentDeviceTag())")
        StrictE2EVisualEvidence.writeJSON(immediate, name: "person-return-immediate.json")
        let returned = waitUntil(timeout: 8, condition: { self.isFilterSummaryVisible(app) })
        if returned == false {
            let later = snapshotPersonReturnSurface(app, backCountBeforeTap: backCountBeforeTap)
            NSLog("person-return-after-wait \(later)")
            attachStrictE2EScreenshot(app: app, name: "person-return-after-wait-\(currentDeviceTag())")
            StrictE2EVisualEvidence.writeJSON(later, name: "person-return-after-wait.json")
            XCTFail(
                "Back from the person filter must land on the filter summary, not stay on the person page or fall back to mode selection. immediate=\(immediate) later=\(later)"
            )
        }
    }

    @MainActor
    private func snapshotPersonReturnSurface(
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
    private func isFilterSummaryVisible(_ app: XCUIApplication) -> Bool {
        app.buttons["filterSummary.startPlayback.button"].exists
    }

    @MainActor
    private func startFilteredPlayback(app: XCUIApplication) {
        let start = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(start.waitForExistence(timeout: 8), "Filter summary must show Start Playback")
        XCTAssertTrue(start.isEnabled, "Start Playback must be enabled once something is selected")
        tapElement(start)
        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: 30), "Starting filtered playback must reach the playback page")
        dismissPlaybackEntryHintIfNeeded(app: app)
    }

    @MainActor
    private func captureNamedPNG(app: XCUIApplication, name: String) -> Data {
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
    private func capturePlaybackPNG(app: XCUIApplication, name: String) -> Data {
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
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
    private func tapNext(app: XCUIApplication) {
        revealPlaybackControls(app: app)
        let next = app.buttons["slideshow.control.next.button"]
        XCTAssertTrue(next.waitForExistence(timeout: 8), "Playback page must have Next")
        tapElement(next)
    }

    // For B, the album list returns to the editor in settings: it has Done and no Start Playback.
    @MainActor
    private func assertSettingsFilterEditorAfterServerSwitchAlbumSelection(app: XCUIApplication) {
        XCTAssertTrue(
            app.staticTexts["filterEditor.page.title"].waitForExistence(timeout: 8)
                || app.descendants(matching: .any)["filterEditor.page.title"].waitForExistence(timeout: 2),
            "After selecting the B album, the app must stay on the settings editor"
        )
        let albumEntry = app.buttons["filter.editor.album.entry"]
        XCTAssertTrue(albumEntry.waitForExistence(timeout: 8), "Editor must offer the album entry")
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
    private func editorSummaryShowsSelection(
        _ app: XCUIApplication,
        selectedAlbums: String,
        pendingPhotos: String
    ) -> Bool {
        // On iPad the summary tile may merge the count and the selected-albums text into one label.
        summaryCountVisible(app, value: selectedAlbums, label: "已选相册")
            && summaryCountVisible(app, value: pendingPhotos, label: "待播照片")
    }

    @MainActor
    private func summaryCountVisible(_ app: XCUIApplication, value: String, label: String) -> Bool {
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
    private func editorAlbumCardShowsSelection(
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
    private func finishFilterEditor(app: XCUIApplication) {
        let done = app.buttons["filter.editor.done.button"]
        if done.waitForExistence(timeout: 4) {
            tapElement(done)
            return
        }
        let doneElement = app.descendants(matching: .any)["filter.editor.done.button"]
        if doneElement.exists {
            tapElement(doneElement)
        }
    }

    @MainActor
    private func returnToSlideshowFromSettings(app: XCUIApplication) {
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
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        revealPlaybackControls(app: app)
        XCTAssertTrue(
            waitUntil(timeout: 8) {
                !self.isFilterEditorVisible(app)
                    && app.buttons["slideshow.control.settings.button"].exists
                    && app.buttons["slideshow.control.settings.button"].isHittable
            },
            "Must return to the playback page"
        )
    }

    @MainActor
    private func isFilterEditorVisible(_ app: XCUIApplication) -> Bool {
        app.staticTexts["filterEditor.page.title"].exists
            || app.buttons["filter.editor.done.button"].exists
            || app.descendants(matching: .any)["filter.editor.done.button"].exists
    }

    @MainActor
    private func settingsNavigationBackButton(app: XCUIApplication) -> XCUIElement? {
        let bars = app.navigationBars.buttons.allElementsBoundByIndex
        let back = bars.last { $0.exists && $0.isHittable && $0.identifier == "BackButton" }
        if let back { return back }
        return bars.first { $0.exists && $0.isHittable && $0.identifier != "ToggleSidebar" }
    }

    @MainActor
    private func changeServerFromPlayback(app: XCUIApplication, serverURL: String, publicKey: String) {
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
        XCTAssertTrue(serverEntry.waitForExistence(timeout: 8), "Settings must offer the server entry")
        tapElement(serverEntry)
        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 8), "Server settings page should show the URL")
        replaceText(
            in: serverField, app: app, with: serverURL, evidenceName: "server-url-replace", requireExactValue: true)
        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        if apiKeyField.waitForExistence(timeout: 4) {
            let current = apiKeyField.value as? String ?? ""
            if current.isEmpty || current.contains("请输入") {
                replaceText(
                    in: apiKeyField,
                    app: app,
                    with: publicKey,
                    evidenceName: "server-apikey-replace",
                    requireExactValue: false
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
            waitForSaveEnabled(app: app, saveButton: saveButton, timeout: 45),
            "Save must work after the connection test on the new server succeeds")
        tapElement(saveButton)
        XCTAssertTrue(
            waitUntil(timeout: 20) {
                app.staticTexts["settings.server.status.message"].exists
                    && ["配置已保存", "Settings saved"].contains(app.staticTexts["settings.server.status.message"].label)
            },
            "Saving the new server must show a success confirmation"
        )
    }

    @MainActor
    private func openFilterEditorFromSettings(app: XCUIApplication) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            let sidebar = app.buttons["ToggleSidebar"]
            // ui-label-lookup: System navigation supplies the sidebar button label.
            if sidebar.exists && ["显示边栏", "Show Sidebar"].contains(sidebar.label) {
                tapElement(sidebar)
            }
        }
        let playbackEntry = app.descendants(matching: .any)["settings.item.playback"].firstMatch
        if !playbackEntry.waitForExistence(timeout: 2) {
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
            playbackEntry.waitForExistence(timeout: 8),
            "After the server switch, settings must still offer the playback entry")
        tapElement(playbackEntry)
        let filterConfig = app.buttons["settings.playback.filterConfig.button"]
        if !filterConfig.waitForExistence(timeout: 2) {
            let modePicker = app.segmentedControls["settings.playback.mode.picker"]
            XCTAssertTrue(
                modePicker.waitForExistence(timeout: 8), "Playback settings must offer the default playback mode")
            let filteredMode = modePicker.buttons.element(boundBy: 1)
            XCTAssertTrue(
                filteredMode.waitForExistence(timeout: 4), "Playback settings must offer the filtered playback option")
            tapElement(filteredMode)
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            let configure = app.buttons["去配置"]
            XCTAssertTrue(
                configure.waitForExistence(timeout: 8),
                "After the server switch clears filters, reconfiguring must be allowed")
            tapElement(configure)
        } else {
            if !filterConfig.isHittable {
                app.swipeUp()
            }
            tapElement(filterConfig)
        }
        XCTAssertTrue(
            app.buttons["filter.editor.album.entry"].waitForExistence(timeout: 12)
                || app.staticTexts["filterEditor.page.title"].waitForExistence(timeout: 4),
            "Filter editor must open after the server switch"
        )
    }

    @MainActor
    private func isolateAlbumSelection(app: XCUIApplication, keeping albumID: String) {
        let clear = app.buttons["albumFilter.clear.button"]
        if clear.waitForExistence(timeout: 4) {
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
    private func openSettingsHomeFromPlayback(app: XCUIApplication) {
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
            app.descendants(matching: .any)["settings.item.server"].firstMatch.waitForExistence(timeout: 8)
                || app.descendants(matching: .any)["settings.item.playback"].firstMatch.waitForExistence(timeout: 2),
            "Playback page must open settings"
        )
    }

    @MainActor
    private func openPlaybackSettingsFromSlideshow(app: XCUIApplication) {
        openSettingsHomeFromPlayback(app: app)
        let playbackEntry = app.descendants(matching: .any)["settings.item.playback"].firstMatch
        XCTAssertTrue(playbackEntry.waitForExistence(timeout: 8), "Settings must offer the playback entry")
        tapElement(playbackEntry)
        XCTAssertTrue(
            app.segmentedControls["settings.playback.displayMode.picker"].waitForExistence(timeout: 8),
            "Playback settings must offer the display policy"
        )
    }

    @MainActor
    private func selectSinglePhotoDisplayMode(app: XCUIApplication) {
        let picker = app.segmentedControls["settings.playback.displayMode.picker"]
        XCTAssertTrue(
            picker.waitForExistence(timeout: 8), "Playback settings must offer the display policy segmented control")
        let singlePhoto = picker.buttons["settings.playback.displayMode.singlePhoto.option"]
        XCTAssertTrue(singlePhoto.waitForExistence(timeout: 3), "Display policy must offer single-photo mode")
        tapElement(singlePhoto)
        XCTAssertTrue(
            waitUntil(timeout: 6) { singlePhoto.isSelected },
            "After choosing it on the real settings page, single-photo mode must read back as selected"
        )
    }

    @MainActor
    private func selectSmartFillDisplayMode(app: XCUIApplication) {
        let picker = app.segmentedControls["settings.playback.displayMode.picker"]
        XCTAssertTrue(
            picker.waitForExistence(timeout: 8), "Playback settings must offer the display policy segmented control")
        let smartFill = picker.buttons["settings.playback.displayMode.smartFill.option"]
        XCTAssertTrue(smartFill.waitForExistence(timeout: 3), "Display policy must offer Smart Fill")
        tapElement(smartFill)
        XCTAssertTrue(
            waitUntil(timeout: 6) { smartFill.isSelected },
            "After choosing it on the real settings page, Smart Fill must read back as selected"
        )
    }

    @MainActor
    private func waitForStablePublicPhoto(app: XCUIApplication, timeout: TimeInterval) -> StrictE2EPhotoIdentity.Result?
    {
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
    private func waitForDistinctRegionMarks(app: XCUIApplication, timeout: TimeInterval) -> [String] {
        var last: [String] = []
        _ = waitUntil(timeout: timeout) {
            let png = app.screenshot().pngRepresentation
            last = self.distinctRegionMarks(StrictE2EPhotoIdentity.classifyRegions(png: png))
            return last.count >= 2
        }
        return last
    }

    private func distinctRegionMarks(_ regions: [String: StrictE2EPhotoIdentity.Result]) -> [String] {
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

    @MainActor
    private func collectVisibleFilterIDs(app: XCUIApplication) -> [String] {
        collectVisibleFilterEvidence(app: app).ids
    }

    // Observations come only from UI identifiers; never splice in albumB from the manifest.
    @MainActor
    private func collectVisibleFilterEvidence(app: XCUIApplication) -> (ids: [String], raw: [String]) {
        var ids: [String] = []
        var raw: [String] = []
        openAlbumFilterFromEditor(app: app)
        _ = waitUntil(timeout: 12) {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "albumFilter.album.")).count > 0
        }
        let albumIDs = identifiers(in: app, prefix: "albumFilter.album.", suffix: ".button")
        let albumRaw = rawIdentifiers(in: app, prefix: "albumFilter.album.")
        ids.append(contentsOf: albumIDs)
        raw.append(contentsOf: albumRaw)
        returnFromAlbumFilter(app: app)
        openPersonFilterFromEditor(app: app)
        _ = waitUntil(timeout: 12) {
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "personFilter.person.")
            ).count > 0
        }
        let personIDs = identifiers(in: app, prefix: "personFilter.person.", suffix: ".button")
        let personRaw = rawIdentifiers(in: app, prefix: "personFilter.person.")
        ids.append(contentsOf: personIDs)
        raw.append(contentsOf: personRaw)
        returnFromPersonFilter(app: app)
        return (ids, raw)
    }

    @MainActor
    private func rawIdentifiers(in app: XCUIApplication, prefix: String) -> [String] {
        let query = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
        return query.allElementsBoundByIndex.compactMap { element in
            let identifier = element.identifier
            return identifier.hasPrefix(prefix) ? identifier : nil
        }
    }

    @MainActor
    private func identifiers(in app: XCUIApplication, prefix: String, suffix: String) -> [String] {
        let query = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
        return query.allElementsBoundByIndex.compactMap { element in
            let identifier = element.identifier
            guard identifier.hasPrefix(prefix), identifier.hasSuffix(suffix) else { return nil }
            return String(identifier.dropFirst(prefix.count).dropLast(suffix.count))
        }
    }

    @MainActor
    private func chooseOnboardingModeAndContinue(
        app: XCUIApplication,
        identifier: String
    ) {
        let modeButton = firstBootControl(in: app, identifier: identifier)
        XCTAssertTrue(modeButton.waitForExistence(timeout: 8), "Mode page must offer \(identifier).")
        let continueButton = firstBootControl(in: app, identifier: "mode.continue.button")
        // The system Save Password prompt may cover the card late; after handling the named prompt,
        // still prove the target mode is selected.
        _ = waitUntil(timeout: 2) { continueButton.exists && continueButton.isEnabled }
        for _ in 0..<2 {
            if systemSavePasswordPromptVisible(app: app) {
                _ = captureNamedPNG(app: app, name: "mode-selection-password-prompt")
                guard dismissSystemSavePasswordPromptIfPresent(app: app, timeout: 4) else {
                    XCTFail("The named Save Password prompt must be gone before choosing a mode")
                    return
                }
            }
            if isOnboardingModeSelected(modeButton) { break }
            if waitUntil(timeout: 4, condition: { modeButton.exists && modeButton.isHittable }) {
                modeButton.tap()
            } else {
                let matches = app.buttons.matching(identifier: identifier)
                let frame = modeButton.frame
                let snapshot: [String: Any] = [
                    "identifier": identifier, "button_count": matches.count,
                    "exists": modeButton.exists, "enabled": modeButton.isEnabled,
                    "hittable": modeButton.isHittable, "frame": String(describing: frame),
                    "app_frame": String(describing: app.frame),
                    "password_prompt_visible": systemSavePasswordPromptVisible(app: app)
                ]
                if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) {
                    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                    attachment.name = "mode-card-hit-diagnostic"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                _ = captureNamedPNG(app: app, name: "mode-card-not-hittable")
                guard matches.count == 1, modeButton.exists, modeButton.isEnabled,
                    !systemSavePasswordPromptVisible(app: app),
                    frame.width > 0, frame.height > 0, app.frame.contains(frame)
                else {
                    XCTFail("Target mode card must be unique, enabled, fully visible and unobstructed")
                    return
                }
                // When XCTest's hittable flag is wrong, tap only the center of the single visible button;
                // the selection and page checks below still decide the result.
                modeButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            _ = waitUntil(timeout: 4) {
                self.systemSavePasswordPromptVisible(app: app) || self.isOnboardingModeSelected(modeButton)
            }
        }
        if systemSavePasswordPromptVisible(app: app) {
            _ = captureNamedPNG(app: app, name: "mode-selection-password-prompt")
            guard dismissSystemSavePasswordPromptIfPresent(app: app, timeout: 4) else {
                XCTFail("The named Save Password prompt must be dismissed before Continue on the mode page")
                return
            }
        }
        XCTAssertTrue(
            isOnboardingModeSelected(modeButton),
            "Target mode card must be selected before Continue; do not rely on Continue with the default random mode"
        )
        continueButton.tap()
        // The password prompt may appear only after tapping Continue; resend the blocked Continue once,
        // and only if the prompt was actually dismissed.
        let departureDeadline = Date().addingTimeInterval(8)
        var resumedAfterPrompt = false
        while Date() < departureDeadline {
            if systemSavePasswordPromptVisible(app: app) {
                _ = captureNamedPNG(app: app, name: "mode-departure-password-prompt")
                guard !resumedAfterPrompt,
                    dismissSystemSavePasswordPromptIfPresent(app: app, timeout: 4)
                else {
                    XCTFail("A Save Password prompt shown while leaving the mode page must be dismissed")
                    return
                }
                resumedAfterPrompt = true
                if modeButton.exists && continueButton.exists {
                    guard isOnboardingModeSelected(modeButton) else {
                        XCTFail("Target mode must stay selected after the prompt goes away")
                        return
                    }
                    continueButton.tap()
                }
            }
            if !modeButton.exists { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    @MainActor
    private func isOnboardingModeSelected(_ modeButton: XCUIElement) -> Bool {
        modeButton.isSelected || modeButton.images["checkmark.circle.fill"].exists
    }

    @MainActor
    private func pausePlaybackIfNeeded(app: XCUIApplication) {
        revealPlaybackControls(app: app)
        let playPause = app.buttons["slideshow.control.playPause.button"]
        guard playPause.waitForExistence(timeout: 4) else { return }
        if playPauseState(playPause) != "play" {
            tapElement(playPause)
        }
        _ = waitUntil(timeout: 4) { self.playPauseState(playPause) == "play" }
    }

    @MainActor
    private func revealPlaybackControls(app: XCUIApplication) {
        _ = waitUntil(timeout: 4) {
            let settings = app.buttons["slideshow.control.settings.button"]
            if settings.exists && settings.isHittable { return true }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
            return false
        }
    }

    @MainActor
    private func waitForPlaybackControls(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) {
            let settings = app.buttons["slideshow.control.settings.button"]
            if settings.exists && settings.isHittable { return true }
            app.tap()
            return false
        }
    }

    @MainActor
    private func dismissPlaybackEntryHintIfNeeded(app: XCUIApplication) {
        let banner = app.descendants(matching: .any)["slideshow.entryHint.banner"]
        if banner.waitForExistence(timeout: 2) {
            tapElement(banner)
            _ = waitUntil(timeout: 2) { !banner.exists }
        }
    }

    @MainActor
    private func tapTestConnection(app: XCUIApplication) {
        let testConnectionButton = firstBootControl(
            in: app,
            identifier: "firstboot.testConnection.button"
        )
        XCTAssertTrue(testConnectionButton.waitForExistence(timeout: 8), "Test Connection must be shown")
        tapElement(testConnectionButton)
    }

    private func playPauseState(_ button: XCUIElement) -> String {
        ((button.value as? String) ?? "").lowercased()
    }

    private func currentDeviceTag() -> String {
        let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let orientation = XCUIDevice.shared.orientation.isLandscape ? "landscape" : "portrait"
        return "\(idiom)-\(orientation)"
    }

    @MainActor
    private func replaceText(
        in field: XCUIElement,
        app: XCUIApplication,
        with value: String,
        evidenceName: String,
        requireExactValue: Bool
    ) {
        field.tap()
        clearTextFieldOrFail(field, app: app, evidenceName: evidenceName)
        field.typeText(value)
        guard requireExactValue else { return }
        let actual = field.value as? String ?? ""
        if actual != value {
            _ = captureNamedPNG(app: app, name: "\(evidenceName)-mismatch")
            XCTFail("After typing, the URL must exactly equal the target; actual \(actual)")
        }
    }

    @MainActor
    private func clearTextFieldOrFail(_ field: XCUIElement, app: XCUIApplication, evidenceName: String) {
        if textFieldLooksEmpty(field) { return }
        // Command-A does not always select the whole URL field, so fall back to end-of-field deletes.
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        if !textFieldLooksEmpty(field) {
            field.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: .command)
            let remaining = field.value as? String ?? ""
            if !remaining.isEmpty {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: remaining.count))
            }
        }
        if !textFieldLooksEmpty(field) {
            _ = captureNamedPNG(app: app, name: "\(evidenceName)-clear-failed")
            XCTFail("Failed to clear the URL field; read back \(field.value as? String ?? "")")
        }
    }

    private func textFieldLooksEmpty(_ field: XCUIElement) -> Bool {
        let value = field.value as? String ?? ""
        return value.isEmpty
            || value.contains("请输入")
            || value.localizedCaseInsensitiveContains("enter")
    }

    private func secureFieldHasEnteredValue(_ field: XCUIElement) -> Bool {
        let value = field.value as? String ?? ""
        return !value.isEmpty && !value.contains("请输入") && !value.localizedCaseInsensitiveContains("api key")
    }

    private func commitFocusedInputIfNeeded(app: XCUIApplication) {
        let done = app.buttons["server.keyboard.done.button"]
        if done.exists && done.isHittable {
            done.tap()
            return
        }
        // ui-label-lookup: System keyboard submit keys follow the simulator language.
        for label in ["完成", "Done", "next", "Next"] {
            // ui-label-lookup: System keyboard submit keys follow the simulator language.
            let button = app.keyboards.buttons[label]
            if button.exists && button.isHittable {
                button.tap()
                return
            }
        }
    }

    private func waitForSaveEnabled(app: XCUIApplication, saveButton: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            acceptLocalNetworkPermissionIfNeeded()
            if saveButton.exists && saveButton.isEnabled { return true }
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

    private func acceptLocalNetworkPermissionIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // ui-label-lookup: The local-network permission alert belongs to iOS.
        for label in ["允许", "Allow"] {
            // ui-label-lookup: The permission action belongs to SpringBoard.
            let button = springboard.alerts.buttons[label]
            if button.exists {
                button.tap()
                return
            }
        }
    }

    private func firstBootControl(in app: XCUIApplication, identifier: String) -> XCUIElement {
        let button = app.buttons[identifier]
        if button.exists { return button }
        let identifiedElement = app.descendants(matching: .any)[identifier]
        if identifiedElement.exists { return identifiedElement }
        return identifiedElement
    }

    private func tapElement(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}
#endif
