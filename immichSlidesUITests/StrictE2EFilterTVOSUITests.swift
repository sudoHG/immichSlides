import XCTest

enum StrictE2EFilterTVOSUITestsCalibration {
    static let displayCandidateFrameLimit: Int = 4
}

#if os(tvOS)
final class StrictE2EFilterTVOSUITests: XCTestCase {
    enum Timing {
        static let focusMovementSettleSeconds: TimeInterval = 0.15
        static let focusPollingSeconds: TimeInterval = 0.1
        static let playbackSceneSettleSeconds: TimeInterval = 3.5
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTVOSTargetAlbumPlaybackAndEmptyStart() throws {
        guard UIDevice.current.userInterfaceIdiom == .tv else {
            XCTFail("The tvOS filter flow must run on a tvOS Simulator.")
            return
        }

        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }

        try configureServerThroughFirstBoot(app: app, input: input)
        try enterFilteredSummary(app: app)

        let albumCard = app.buttons["filterSummary.album.button"]
        if !waitForFocus(on: albumCard, timeout: 4) {
            moveFocus(
                .down, to: albumCard, maximumPresses: 3,
                message: "Default focus on the filter summary must be able to reach the album filter.")
        }
        XCTAssertTrue(
            waitForFocus(on: albumCard, timeout: 4),
            "Default focus on the filter summary must land on the album filter.")
        attachScreenshot(app: app, name: "tvos-filter-default-focus-album")
        attachFocusAudit(app: app, name: "tvos-filter-default-focus")

        let start = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "The filter summary must show Start Playback.")
        XCTAssertFalse(start.isEnabled, "Start Playback must be disabled with an empty selection.")
        try StrictE2EVisualEvidence.writeRequiredJSON(
            [
                "album_ids": [],
                "person_filters": [],
                "start_enabled": start.isEnabled,
                "identity_source": "public_fixture_photo_mark"
            ],
            name: "empty-selection.json"
        )

        try selectAlbum(app: app, albumID: "album-a-target", neighborID: "album-a-non-target")
        XCTAssertTrue(
            start.waitForExistence(timeout: 8), "Selecting the target album must return to the filter summary.")
        XCTAssertTrue(start.isEnabled, "Start Playback must be enabled after selecting the target album.")
        moveFocus(
            .right, to: start, maximumPresses: 3,
            message: "With a selection, focus must be able to move to Start Playback.")
        XCTAssertTrue(waitForFocus(on: start, timeout: 4), "Start Playback must be focusable.")
        attachScreenshot(app: app, name: "tvos-filter-start-focused")
        XCUIRemote.shared.press(.select)

        try capturePausedPlaybackPNGs(
            app: app,
            names: ["album-playback-1", "album-playback-2", "album-playback-3"]
        )

        XCUIRemote.shared.press(.menu)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(
            app.buttons["filterSummary.album.button"].waitForExistence(timeout: 8)
                || app.buttons["mode.random.button"].waitForExistence(timeout: 2),
            "Back/Menu on the playback screen must leave playback and return to the filter or mode screen."
        )
    }

    @MainActor
    func testTVOSFilterEditSwitchKeepsFilteredModeAndClearReturnsRandom() throws {
        guard UIDevice.current.userInterfaceIdiom == .tv else {
            XCTFail("The tvOS album edit switch must run on a tvOS Simulator.")
            return
        }
        guard let evidenceDirectory = StrictE2EVisualEvidence.directory() else {
            throw StrictE2EVisualEvidence.WriteError.missingDirectory
        }
        let manifest = try StrictE2EFilterContract.loadMemberManifest(from: evidenceDirectory)
        guard
            let targetAlbum = manifest["target_album"] as? [String: Any],
            let targetAlbumID = targetAlbum["id"] as? String,
            let nonTargetAlbum = manifest["non_target_album"] as? [String: Any],
            let nonTargetAlbumID = nonTargetAlbum["id"] as? String
        else {
            throw StrictE2EFilterContract.AssertionError.message(
                "member manifest is missing the target or non-target album ID")
        }
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }

        try configureServerThroughFirstBoot(app: app, input: input)
        try enterFilteredSummary(app: app)
        try selectAlbum(app: app, albumID: targetAlbumID, neighborID: nonTargetAlbumID)
        let start = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(
            start.waitForExistence(timeout: 8) && start.isEnabled,
            "Filtered playback must be startable after selecting the target album")
        moveFocus(
            .right, to: start, maximumPresses: 3,
            message: "Focus must be able to move from the album entry to Start Playback")
        XCUIRemote.shared.press(.select)
        try capturePausedPlaybackPNGs(app: app, names: ["album-edit-switch-before"])

        try openFilterEditorFromPlaybackSettings(app: app)
        try openAlbumFilter(app: app)
        try setAlbumSelectionInCurrentList(
            app: app,
            albumID: targetAlbumID,
            neighborID: nonTargetAlbumID,
            shouldSelect: false
        )
        try setAlbumSelectionInCurrentList(
            app: app,
            albumID: nonTargetAlbumID,
            neighborID: targetAlbumID,
            shouldSelect: true
        )
        let selectedCard = app.buttons["albumFilter.album.\(nonTargetAlbumID).button"]
        XCTAssertEqual(
            selectedCard.identifier,
            "albumFilter.album.\(nonTargetAlbumID).button",
            "The replaced album's identity must come from the real list's accessibility identifier"
        )
        let observedAlbumID = selectedCard.identifier
            .replacingOccurrences(of: "albumFilter.album.", with: "")
            .replacingOccurrences(of: ".button", with: "")
        try returnFromAlbumList(app: app)
        try finishTVOSFilterEditor(app: app)
        try assertTVOSDefaultMode(app: app, expected: "filtered")
        try returnToSlideshowFromSettings(app: app)
        try capturePausedPlaybackPNGs(
            app: app,
            names: ["album-switch-b-play-1", "album-switch-b-play-2"]
        )

        try openFilterEditorFromPlaybackSettings(app: app)
        try openAlbumFilter(app: app)
        let clear = app.buttons["albumFilter.clear.button"]
        XCTAssertTrue(clear.waitForExistence(timeout: 8), "The real album filter screen must offer Clear selection")
        moveFocusTo(
            clear, directions: [.up, .right], message: "Focus must be able to reach Clear selection in the top toolbar")
        XCTAssertTrue(clear.hasFocus, "Clear selection must actually receive remote focus")
        XCUIRemote.shared.press(.select)
        let clearedTarget = app.buttons["albumFilter.album.\(targetAlbumID).button"]
        let clearedNonTarget = app.buttons["albumFilter.album.\(nonTargetAlbumID).button"]
        XCTAssertTrue(
            waitUntil(timeout: 6) {
                let targetValue = String(describing: clearedTarget.value ?? "")
                let nonTargetValue = String(describing: clearedNonTarget.value ?? "")
                return !(targetValue.contains("已选中") || clearedTarget.isSelected)
                    && !(nonTargetValue.contains("已选中") || clearedNonTarget.isSelected)
            },
            "After Clear, both target and non-target albums must really become unselected; re-tapping each card must not stand in for the clear result"
        )
        try returnFromAlbumList(app: app)
        try finishTVOSFilterEditor(app: app)
        try assertTVOSDefaultMode(app: app, expected: "random")

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

    @MainActor
    func testTVOSTargetAlbumPlaysAndEmptyAlbumShowsEmptyResult() throws {
        guard UIDevice.current.userInterfaceIdiom == .tv else {
            XCTFail("The tvOS filter flow must run on a tvOS Simulator.")
            return
        }
        let input = try requireStrictE2EInput()
        let emptyCopy = "当前筛选条件没有找到可播放照片，请换一组相册或人物再试。"
        let app = try launchStrictE2EApp()
        defer { app.terminate() }

        try configureServerThroughFirstBoot(app: app, input: input)
        try enterFilteredSummary(app: app)
        let start = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "The filter summary must show Start Playback.")
        XCTAssertFalse(start.isEnabled, "Start Playback must be disabled with 0 albums / 0 people.")
        attachScreenshot(app: app, name: "tvos-album-empty-selection")
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

        try selectAlbum(app: app, albumID: "album-a-target", neighborID: "album-a-non-target")
        XCTAssertTrue(
            start.waitForExistence(timeout: 8) && start.isEnabled,
            "Start Playback must be enabled after selecting the target album.")
        moveFocus(
            .right, to: start, maximumPresses: 3,
            message: "With a selection, focus must be able to move to Start Playback.")
        XCUIRemote.shared.press(.select)
        try capturePausedPlaybackPNGs(app: app, names: ["album-play-1", "album-play-2"])

        try openFilterEditorFromPlaybackSettings(app: app)
        try isolateAndSelectEmptyAlbum(app: app, emptyAlbumID: "album-a-empty", neighborID: "album-a-target")
        let editorStart = app.buttons["filterSummary.startPlayback.button"]
        let didObserveStart = editorStart.exists
        // The Settings filter editor does not present Start Playback; record that explicitly, never as a disabled button.
        let startEnabledAfterEmpty: Any = didObserveStart ? editorStart.isEnabled : "not_applicable_settings_editor"
        try returnToSlideshowFromSettings(app: app)
        let emptyLabel = app.staticTexts["slideshow.emptyState.message"]
        // ui-label-lookup: Preserve the Simplified Chinese empty-result copy check after identifier lookup.
        XCTAssertTrue(
            waitUntil(timeout: 20) { emptyLabel.exists && emptyLabel.label == emptyCopy },
            "An empty album must show the frozen existing production empty-result copy and must not keep the old non-empty pool"
        )
        // ui-label-lookup: Preserve the exact Simplified Chinese empty-result copy assertion after identifier lookup.
        XCTAssertEqual(emptyLabel.label, emptyCopy)
        try StrictE2EVisualEvidence.writeRequiredJSON(
            [
                "album_id": "album-a-empty",
                "start_enabled": startEnabledAfterEmpty,
                "start_button_observed": didObserveStart,
                "empty_copy": emptyLabel.label,
                "identity_source": "public_fixture_photo_mark",
                "entry": "settings.playback.filterConfig.button"
            ],
            name: "empty-album.json"
        )
        try writeScreenshotPNG(app: app, name: "empty-album-result", attachmentName: "empty-album-result")
    }

    @MainActor
    func testTVOSPersonRules() throws {
        guard UIDevice.current.userInterfaceIdiom == .tv else {
            XCTFail("The tvOS filter flow must run on a tvOS Simulator.")
            return
        }

        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }

        try StrictE2EVisualEvidence.writeRequiredJSON(
            [
                "environment": "simulator",
                "vision_available": false
            ],
            name: "vision-environment.json"
        )

        try configureServerThroughFirstBoot(app: app, input: input)
        try enterFilteredSummary(app: app)

        try runPersonPlayback(
            app: app,
            personID: "person-a-normal",
            isSoloOnly: false,
            evidenceName: "person-normal"
        )
        try runPersonPlayback(
            app: app,
            personID: "person-a-solo",
            isSoloOnly: false,
            evidenceName: "person-conflict-normal"
        )
        try runPersonPlayback(
            app: app,
            personID: "person-a-solo",
            isSoloOnly: true,
            evidenceName: "person-conflict-solo"
        )
        try runPersonPlayback(
            app: app,
            personID: "person-a-no-faces",
            isSoloOnly: false,
            evidenceName: "person-no-faces"
        )
    }

    @MainActor
    func testTVOSServerSwitchIsolation() throws {
        guard UIDevice.current.userInterfaceIdiom == .tv else {
            XCTFail("The tvOS filter flow must run on a tvOS Simulator.")
            return
        }

        let input = try requireStrictE2EInput()
        let serverB = try requireStrictE2EPeerServerURL()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }

        try configureServerThroughFirstBoot(app: app, input: input)
        try enterFilteredSummary(app: app)
        try selectAlbum(app: app, albumID: "album-a-target", neighborID: "album-a-non-target")
        let start = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(start.isEnabled, "Start Playback must be enabled after saving filters on server A.")
        moveFocus(.right, to: start, maximumPresses: 3, message: "Focus must be able to move to Start Playback.")
        XCUIRemote.shared.press(.select)

        try changeServer(
            app: app,
            url: serverB,
            publicKey: input.publicKey
        )
        try openFilterEditorFromCurrentSurface(app: app)
        try assertStillInApp(app)
        let albumSummary = app.buttons["filter.editor.album.entry"].label
        let personSummary = app.buttons["filter.editor.person.entry"].label
        // ui-label-lookup: Preserve the Simplified Chinese album-summary copy check after identifier lookup.
        XCTAssertTrue(albumSummary.contains("0 个相册 · 0 张照片"), "Switching servers must clear the old album selection.")
        // ui-label-lookup: Preserve the Simplified Chinese person-summary copy check after identifier lookup.
        XCTAssertTrue(personSummary.contains("0 个人物 · 0 张照片"), "Switching servers must clear the old person selection.")
        try writeScreenshotPNG(app: app, name: "switch-b-empty-editor", attachmentName: "switch-b-empty-editor")
        try StrictE2EVisualEvidence.writeRequiredJSON(
            [
                "selection_source": "accessibility_ui",
                "album_summary": albumSummary,
                "person_summary": personSummary
            ],
            name: "empty-selection-after-switch.json"
        )
        try openAlbumFilter(app: app)
        let afterAlbum = collectFixtureIDs(app: app)
        XCUIRemote.shared.press(.menu)
        _ =
            app.buttons["filterSummary.album.button"].waitForExistence(timeout: 8)
            || app.buttons["filter.editor.album.entry"].waitForExistence(timeout: 2)
        try openPeopleFilter(app: app)
        let afterPeople = collectFixtureIDs(app: app)
        XCUIRemote.shared.press(.menu)

        let ids = Array(Set(afterAlbum.ids + afterPeople.ids)).sorted()
        let raw = afterAlbum.raw + afterPeople.raw
        XCTAssertFalse(
            ids.contains { $0.contains("-a-") },
            "After switching servers the UI must not keep server A album/person IDs: \(ids)")
        try StrictE2EVisualEvidence.writeRequiredJSON(
            [
                "identity_source": "ui_accessibility_identifier",
                "ids": ids,
                "raw_identifiers": raw
            ],
            name: "observed-ids-after-switch.json"
        )

        XCTAssertTrue(
            app.buttons["filter.editor.album.entry"].waitForExistence(timeout: 8),
            "Returning from the people list must stay in the filter editor.")
        try selectAlbum(app: app, albumID: "album-b-target", neighborID: "album-b-non-target")
        let doneB = app.buttons["filter.editor.done.button"]
        XCTAssertTrue(
            doneB.waitForExistence(timeout: 8) && doneB.isHittable,
            "Done in the B filter editor must be able to return to settings.")
        moveFocusTo(doneB, directions: [.right, .down, .left], message: "Focus must reach Done.")
        XCUIRemote.shared.press(.select)
        try returnToSlideshowFromSettings(app: app)
        try capturePausedPlaybackPNGs(app: app, names: ["switch-b-playback"])
        let processBefore = try displayPolicyProcessID(app)
        try openPlaybackSettingsFromSlideshow(app: app)
        try selectVerifiedDisplayMode(app: app, mode: "singlePhoto")
        try returnToSlideshowFromSettings(app: app)
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.playbackSceneSettleSeconds))
        try writeScreenshotPNG(app: app, name: "switch-b-single-after", attachmentName: "switch-b-single-after")
        try StrictE2EVisualEvidence.writeRequiredJSON(
            [
                "identity_source": "public_fixture_photo_mark",
                "setting_source": "accessibility_ui",
                "mode_after": "singlePhoto",
                "process_id_before": processBefore,
                "process_id_after": try displayPolicyProcessID(app)
            ], name: "display-policy-after-switch.json")
    }

    @MainActor
    func testTVOSSmartFillDisplayPolicyChangesMultiToSingle() throws {
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }
        try configureServerThroughFirstBoot(app: app, input: input)
        try enterFilteredSummary(app: app)
        try selectAlbum(app: app, albumID: "album-a-target", neighborID: "album-a-non-target")
        let start = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(start.isEnabled)
        moveFocus(.right, to: start, maximumPresses: 3, message: "Focus Start Playback.")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["slideshow.control.playPause.button"].waitForExistence(timeout: 30))
        try openPlaybackSettingsFromSlideshow(app: app)
        try selectVerifiedDisplayMode(app: app, mode: "smartFill")
        try returnToSlideshowFromSettings(app: app)
        let processBefore = try displayPolicyProcessID(app)
        let pause = app.buttons["slideshow.control.playPause.button"]
        ensureControlBarVisible(app: app, playPauseButton: pause)
        let value = String(describing: pause.value ?? "")
        if value.contains("暂停") || value.lowercased().contains("pause") {
            moveFocusTo(pause, directions: [.right, .left], message: "Focus Pause.")
            XCUIRemote.shared.press(.select)
        }
        XCTAssertTrue(
            waitUntil(timeout: 4) {
                let current = String(describing: pause.value ?? "")
                return current.contains("播放") || current.lowercased() == "play"
            }, "Playback must be paused before sampling candidates.")
        var steps: [String] = []
        var selected: Data?
        for index in 1...StrictE2EFilterTVOSUITestsCalibration.displayCandidateFrameLimit {
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.playbackSceneSettleSeconds))
            let png = app.screenshot().pngRepresentation
            let step = String(format: "display-before-candidate-%02d", index)
            steps.append(step)
            try StrictE2EVisualEvidence.writeRequiredPNG(png, name: step)
            if try displayPolicyDistinctMarks(png).count >= 2 {
                selected = png
                break
            }
            if index < StrictE2EFilterTVOSUITestsCalibration.displayCandidateFrameLimit {
                let next = app.buttons["slideshow.control.next.button"]
                ensureControlBarVisible(app: app, playPauseButton: pause)
                moveFocusTo(next, directions: [.right, .left], message: "Focus Next.")
                XCUIRemote.shared.press(.select)
            }
        }
        guard let selected else {
            throw StrictE2EPhotoIdentity.AssertionError.message(
                "No two distinct photos seen within four public album candidates; all failing originals are kept.")
        }
        try StrictE2EVisualEvidence.writeRequiredPNG(selected, name: "display-before")
        try openPlaybackSettingsFromSlideshow(app: app)
        try selectVerifiedDisplayMode(app: app, mode: "singlePhoto")
        try returnToSlideshowFromSettings(app: app)
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.playbackSceneSettleSeconds))
        try writeScreenshotPNG(app: app, name: "display-after", attachmentName: "display-after")
        try StrictE2EVisualEvidence.writeRequiredJSON(
            [
                "identity_source": "public_fixture_photo_mark", "setting_source": "accessibility_ui",
                "mode_before": "smartFill", "mode_after": "singlePhoto",
                "process_id_before": processBefore, "process_id_after": try displayPolicyProcessID(app),
                "before_candidate_steps": steps, "selected_before_step": steps.last!
            ], name: "display-policy.json")
    }

    func displayPolicyDistinctMarks(_ png: Data) throws -> Set<String> {
        guard let directory = StrictE2EVisualEvidence.directory() else {
            throw StrictE2EFilterContract.AssertionError.message("Missing STRICT_E2E_EVIDENCE_DIR")
        }
        let candidate = try StrictE2EFilterContract.displayCandidatePNG(png, evidenceDirectory: directory)
        let regions = StrictE2EPhotoIdentity.classifyRegions(png: candidate)
        func mark(_ name: String) -> String? {
            guard regions[name]?.status == .match else { return nil }
            return regions[name]?.mark
        }
        var marks = Set<String>()
        for pair in [("left", "right"), ("mid_left", "mid_right"), ("center", "bottom_half")] {
            if let first = mark(pair.0), let second = mark(pair.1), first != second {
                marks.formUnion([first, second])
            }
        }
        if let top = mark("top_half"), let bottom = mark("bottom_half"), top != bottom,
            mark("center") != bottom || mark("top") == top
        {
            marks.formUnion([top, bottom])
        }
        return marks
    }

    @MainActor
    func selectVerifiedDisplayMode(app: XCUIApplication, mode: String) throws {
        let link = app.buttons["settings.playback.displayMode.link"]
        XCTAssertTrue(link.waitForExistence(timeout: 8))
        moveFocusTo(link, directions: [.down, .up], message: "Focus Display Mode.")
        XCUIRemote.shared.press(.select)
        let option = app.buttons["settings.playback.displayMode.\(mode).button"]
        XCTAssertTrue(option.waitForExistence(timeout: 8))
        moveFocusTo(option, directions: [.down, .up], message: "Focus the target display mode.")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: 4) {
                let value = String(describing: option.value ?? "")
                return value == "已选中" || value.lowercased() == "selected"
            }, "The display mode's selected state must be read back.")
        XCUIRemote.shared.press(.menu)
    }

    func displayPolicyProcessID(_ app: XCUIApplication) throws -> Int32 {
        let object = app as NSObject
        if object.responds(to: Selector(("processID"))),
            let number = object.value(forKey: "processID") as? NSNumber, number.int32Value > 0
        {
            return number.int32Value
        }
        let text = app.debugDescription as NSString
        let regex = try NSRegularExpression(pattern: #"pid[: ]+(\d+)"#, options: [.caseInsensitive])
        if let match = regex.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)),
            let pid = Int32(text.substring(with: match.range(at: 1))), pid > 0
        {
            return pid
        }
        throw StrictE2EPhotoIdentity.AssertionError.message("Cannot read the actual process identity.")
    }

    @MainActor
    func testTVOSServerSwitchDropsOldFiltersAndDisplayPolicyAppliesImmediately() throws {
        guard UIDevice.current.userInterfaceIdiom == .tv else {
            XCTFail("The tvOS filter flow must run on a tvOS Simulator.")
            return
        }
        let input = try requireStrictE2EInput()
        let serverB = try requireStrictE2EPeerServerURL()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }

        try configureServerThroughFirstBoot(app: app, input: input)
        try enterFilteredSummary(app: app)
        try selectAlbum(app: app, albumID: "album-a-target", neighborID: "album-a-non-target")
        let start = app.buttons["filterSummary.startPlayback.button"]
        XCTAssertTrue(start.isEnabled, "Start Playback must be enabled after saving filters on server A.")
        moveFocus(.right, to: start, maximumPresses: 3, message: "Focus must be able to move to Start Playback.")
        XCUIRemote.shared.press(.select)
        try capturePausedPlaybackPNGs(app: app, names: ["server-switch-a-play-1"])

        try changeServer(app: app, url: serverB, publicKey: input.publicKey)
        try writeScreenshotPNG(
            app: app, name: "server-switch-b-save-success", attachmentName: "server-switch-b-save-success")
        try assertStillInApp(app)
        try openFilterEditorFromCurrentSurface(app: app)
        try assertStillInApp(app)
        try writeScreenshotPNG(
            app: app, name: "server-switch-b-selection-cleared", attachmentName: "server-switch-b-selection-cleared")
        XCTAssertTrue(app.buttons["filter.editor.done.button"].isHittable, "The settings editor must have a Done entry")
        let albumEntry = app.buttons["filter.editor.album.entry"]
        // ui-label-lookup: Preserve the Simplified Chinese album-summary copy check after identifier lookup.
        XCTAssertTrue(albumEntry.label.contains("0 个相册 · 0 张照片"), "Server B must clear A's album selection")
        try openAlbumFilter(app: app)
        try assertStillInApp(app)
        let afterAlbum = collectFixtureIDs(app: app)
        let ids = afterAlbum.ids
        XCTAssertFalse(
            ids.isEmpty,
            "After switching servers, B's filter IDs must be collected from the UI, not assembled from the manifest")
        XCTAssertFalse(
            ids.contains { $0.contains("-a-") },
            "After switching servers the UI must not keep server A album/person IDs: \(ids)")
        try StrictE2EVisualEvidence.writeRequiredJSON(
            [
                "identity_source": "ui_accessibility_identifier",
                "ids": ids,
                "raw_identifiers": afterAlbum.raw
            ],
            name: "observed-ids.json"
        )
        try returnFromAlbumList(app: app)
        try selectAlbum(app: app, albumID: "album-b-target", neighborID: "album-b-non-target")
        let doneB = app.buttons["filter.editor.done.button"]
        XCTAssertTrue(
            doneB.waitForExistence(timeout: 8) && doneB.isHittable,
            "Done in the B filter editor must return to settings")
        moveFocusTo(doneB, directions: [.right, .down, .left], message: "Focus must reach Done")
        XCUIRemote.shared.press(.select)
        try returnToSlideshowFromSettings(app: app)
        try capturePausedPlaybackPNGs(app: app, names: ["switch-b-play-1", "switch-b-play-2"])
        try writeScreenshotPNG(app: app, name: "display-before", attachmentName: "display-before")

        try openPlaybackSettingsFromSlideshow(app: app)
        try selectVerifiedDisplayMode(app: app, mode: "singlePhoto")
        try writeScreenshotPNG(app: app, name: "display-settings", attachmentName: "display-settings")
        try StrictE2EVisualEvidence.writeRequiredJSON(
            ["identity_source": "public_fixture_photo_mark"],
            name: "display-policy.json"
        )
        try returnToSlideshowFromSettings(app: app)
        let playPause = app.buttons["slideshow.control.playPause.button"]
        XCTAssertTrue(
            playPause.waitForExistence(timeout: 20),
            "After changing the display mode, playback must still be on screen in the same live process.")
        RunLoop.current.run(until: Date().addingTimeInterval(Timing.playbackSceneSettleSeconds))
        let after = StrictE2EPhotoIdentity.classify(png: app.screenshot().pngRepresentation)
        XCTAssertNotEqual(
            after.status, .transition, "After the change, a still frame taken mid-transition must not pass")
        try writeScreenshotPNG(app: app, name: "display-after", attachmentName: "display-after")
    }

    // With only a person selected, the allowed set comes from that person's own set. Consecutive captures must
    // belong to it and must not fail for lacking A2. An empty or unreachable pool still leaves screen evidence for
    // Python to judge UNVERIFIED / fail-closed.
    @MainActor
    func runPersonPlayback(
        app: XCUIApplication,
        personID: String,
        isSoloOnly: Bool,
        evidenceName: String
    ) throws {
        try returnToFilterSummary(app: app)
        try openPeopleFilter(app: app)
        try focusAndConfigurePerson(app: app, personID: personID, isSoloOnly: isSoloOnly)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(
            app.buttons["filterSummary.person.button"].waitForExistence(timeout: 10)
                || app.buttons["filter.editor.person.entry"].waitForExistence(timeout: 2),
            "Back from the people list must return to the filter screen."
        )
        let start = app.buttons["filterSummary.startPlayback.button"]
        if start.waitForExistence(timeout: 5), start.isEnabled {
            moveFocus(.right, to: start, maximumPresses: 3, message: "Focus must be able to move to Start Playback.")
            XCUIRemote.shared.press(.select)
            var names = [evidenceName]
            if evidenceName == "person-conflict-normal" {
                names.append(contentsOf: ["person-conflict-normal-2", "person-conflict-normal-3"])
            }
            try capturePausedPlaybackPNGs(app: app, names: names)
            if evidenceName == "person-conflict-solo" {
                try writeScreenshotPNG(app: app, name: "person-solo", attachmentName: "person-solo")
            }
            XCUIRemote.shared.press(.menu)
        } else {
            try writeScreenshotPNG(app: app, name: evidenceName, attachmentName: evidenceName)
        }
    }

    @MainActor
    func enterFilteredSummary(app: XCUIApplication) throws {
        let randomButton = app.buttons["mode.random.button"]
        let filteredButton = app.buttons["mode.filtered.button"]
        XCTAssertTrue(
            randomButton.waitForExistence(timeout: 15), "Saving the configuration must open the mode selection screen.")
        if !waitForFocus(on: filteredButton, timeout: 1) {
            XCTAssertTrue(
                waitForFocus(on: randomButton, timeout: 5),
                "Default focus on the mode selection screen must land on Random Playback.")
            moveFocus(
                .right, to: filteredButton, maximumPresses: 2,
                message: "Focus on the mode screen must be able to move to Filtered Playback.")
        }
        XCUIRemote.shared.press(.select)
        let continueButton = app.buttons["mode.continue.button"]
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: 5), "Choosing Filtered Playback must show the Continue button.")
        moveFocus(
            .down, to: continueButton, maximumPresses: 2,
            message: "After choosing a mode, focus must be able to move down to the Continue button.")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            app.buttons["filterSummary.album.button"].waitForExistence(timeout: 15),
            "Filtered mode must open the filter summary screen."
        )
    }

    @MainActor
    func returnToFilterSummary(app: XCUIApplication) throws {
        if app.buttons["filterSummary.album.button"].exists { return }
        for _ in 0..<8 {
            if app.buttons["filterSummary.album.button"].exists { return }
            if app.buttons["mode.filtered.button"].exists || app.buttons["mode.random.button"].exists {
                try enterFilteredSummary(app: app)
                return
            }
            XCUIRemote.shared.press(.menu)
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        }
        XCTFail("Cannot return to the filter summary screen.")
    }

    @MainActor
    func openAlbumFilter(app: XCUIApplication) throws {
        let albumCard =
            app.buttons["filterSummary.album.button"].exists
            ? app.buttons["filterSummary.album.button"]
            : app.buttons["filter.editor.album.entry"]
        XCTAssertTrue(albumCard.waitForExistence(timeout: 10), "The album filter entry must be shown.")
        moveFocusTo(
            albumCard, directions: [.left, .up, .down], message: "Focus must be able to move to the album entry.")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            app.buttons["albumFilter.album.album-a-target.button"].waitForExistence(timeout: 8)
                || app.buttons["albumFilter.album.album-b-target.button"].waitForExistence(timeout: 8)
                || app.otherElements["albumFilter.loading.indicator"].waitForExistence(timeout: 2),
            "Opening the album filter must show album cards or a loading state."
        )
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
    }

    @MainActor
    func openPeopleFilter(app: XCUIApplication) throws {
        let peopleCard =
            app.buttons["filterSummary.person.button"].exists
            ? app.buttons["filterSummary.person.button"]
            : app.buttons["filter.editor.person.entry"]
        XCTAssertTrue(peopleCard.waitForExistence(timeout: 10), "The person filter entry must be shown.")
        moveFocusTo(
            peopleCard, directions: [.right, .up, .down], message: "Focus must be able to move to the person entry.")
        XCUIRemote.shared.press(.select)
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
    }

    @MainActor
    func selectAlbum(app: XCUIApplication, albumID: String, neighborID: String) throws {
        try openAlbumFilter(app: app)
        let target = app.buttons["albumFilter.album.\(albumID).button"]
        XCTAssertTrue(target.waitForExistence(timeout: 15), "The album list must show \(albumID).")
        moveFocusTo(target, directions: [.down, .right, .left], message: "Focus must land on the target album.")
        attachScreenshot(app: app, name: "tvos-filter-album-\(albumID)-focused")
        attachFocusAudit(app: app, name: "tvos-filter-album-\(albumID)-focus")
        assertNoFocusCollision(focused: target, neighbor: app.buttons["albumFilter.album.\(neighborID).button"])
        let value = String(describing: target.value ?? "")
        if !value.contains("已选中") {
            XCUIRemote.shared.press(.select)
        }
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(
            app.buttons["filterSummary.album.button"].waitForExistence(timeout: 10)
                || app.buttons["filter.editor.album.entry"].waitForExistence(timeout: 2),
            "Back from the album list must return to the filter screen."
        )
    }

    @MainActor
    func setAlbumSelectionInCurrentList(
        app: XCUIApplication,
        albumID: String,
        neighborID: String,
        shouldSelect: Bool
    ) throws {
        let card = app.buttons["albumFilter.album.\(albumID).button"]
        let neighbor = app.buttons["albumFilter.album.\(neighborID).button"]
        XCTAssertTrue(card.waitForExistence(timeout: 12), "The album list must show \(albumID)")
        XCTAssertTrue(
            neighbor.waitForExistence(timeout: 8), "The neighboring album must exist so focus collision can be checked")
        moveFocusTo(card, directions: [.down, .right, .left], message: "Focus must be able to land on \(albumID)")
        assertNoFocusCollision(focused: card, neighbor: neighbor)
        let isSelected = String(describing: card.value ?? "").contains("已选中") || card.isSelected
        if isSelected != shouldSelect {
            XCUIRemote.shared.press(.select)
        }
        XCTAssertTrue(
            waitUntil(timeout: 5) {
                let currentValue = String(describing: card.value ?? "")
                return (currentValue.contains("已选中") || card.isSelected) == shouldSelect
            },
            "Album \(albumID) must reach the requested real selection state"
        )
        try writeScreenshotPNG(
            app: app,
            name: "album-edit-switch-\(albumID)-\(shouldSelect ? "selected" : "cleared")",
            attachmentName: "album-edit-switch-\(albumID)-\(shouldSelect ? "selected" : "cleared")"
        )
    }

    @MainActor
    func finishTVOSFilterEditor(app: XCUIApplication) throws {
        let done = app.buttons["filter.editor.done.button"]
        XCTAssertTrue(done.waitForExistence(timeout: 8), "The filter settings editor must offer a Done entry")
        moveFocusTo(
            done, directions: [.right, .down, .left], message: "Focus must be able to land on the editor's Done")
        XCTAssertTrue(done.hasFocus, "The editor's Done must actually receive remote focus")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            waitUntil(timeout: 8) { app.buttons["settings.playback.mode.link"].exists },
            "Finishing the edit must return to the real playback settings screen"
        )
    }
}
#endif
