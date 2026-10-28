import XCTest

#if os(iOS)
private enum AlbumCaptureTiming {
    // 5 s old target + 2.025 s transition + 1 s slope pair + 3.975 s scheduling margin; worst case
    // (old target committed just before the save) leaves about 1.95 s plus return navigation.
    static let intervalConfirmationSeconds = TestWait.seconds(.product(12))
    // One second separates the 1/5 and 1/30 progress-per-second rates well above probe rounding.
    static let progressSampleSeconds = TestWait.seconds(.product(1))
    // Half to twice 1/30 allows cadence jitter, rejecting frozen probes and the old 1/5 rate.
    static let longIntervalSlopeRange = (1.0 / 60)...(1.0 / 15)
    // Twice the 0.3 s toolbar fade separates pixel readbacks within the existing 4.8 s cap.
    static let minimumPixelPairSeconds = TestWait.seconds(.product(0.6))
}

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
            start.waitForFailureEvidence(timeout: TestWait.seconds(.product(8))),
            "Filter summary must show Start Playback")
        XCTAssertTrue(start.isEnabled, "Start Playback must be enabled once something is selected")
        tapElement(start)
        XCTAssertTrue(
            waitForPlaybackControls(app: app, timeout: TestWait.seconds(.product(30))),
            "Starting filtered playback must reach the playback page")
        dismissPlaybackEntryHintIfNeeded(app: app)
    }

    @MainActor
    func captureNamedPNG(app: XCUIApplication, name: String) -> Data {
        let png = app.screenshotForFailureEvidence().pngRepresentation
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
        let png = app.screenshotForFailureEvidence().pngRepresentation
        XCTAssertFalse(png.isEmpty, "Playback screenshot must not be empty: \(name)")
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        StrictE2EVisualEvidence.writePNG(png, name: name)
        return png
    }

    @MainActor
    func captureAlbumPlaybackPNG(app: XCUIApplication, name: String) throws -> Data {
        revealPlaybackControls(app: app)
        let settleDeadline = Date().addingTimeInterval(TestWait.seconds(.product(0.8)))
        let deadline = settleDeadline.addingTimeInterval(TestWait.seconds(.product(4)))
        RunLoop.current.run(until: settleDeadline)
        guard let capture = captureStableAlbumPixels(app: app, deadline: deadline) else { return Data() }
        XCTAssertFalse(capture.png.isEmpty, "Playback screenshot must not be empty: \(name)")
        let attachment = XCTAttachment(data: capture.png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try StrictE2EVisualEvidence.writeRequiredPNG(capture.png, name: name)
        return capture.png
    }

    @MainActor
    private func captureStableAlbumPixels(
        app: XCUIApplication, deadline: Date
    ) -> (png: Data, requestedAt: TimeInterval, returnedAt: TimeInterval)? {
        // Compare decoded, full-resolution color pixels; a logical stable probe can precede presentation.
        let minimumPairSeconds = AlbumCaptureTiming.minimumPixelPairSeconds
        var previousPixels: Data?
        var previousFormat: [Int] = []
        var previousReturnedAt: Date?
        var png = Data()
        var requestedAt: TimeInterval = .zero
        var returnedAt: TimeInterval = .zero
        var captureCount = 0
        var pairSeconds: TimeInterval = .zero
        FirstFailureContext.mark("capture-frame", element: "app-window")
        let isStable = TestWait.until(.product(max(.zero, deadline.timeIntervalSinceNow))) {
            guard Date() < deadline else { return false }
            if let previousReturnedAt, Date().timeIntervalSince(previousReturnedAt) < minimumPairSeconds {
                return false
            }
            requestedAt = Date().timeIntervalSince1970
            pairSeconds = previousReturnedAt.map { requestedAt - $0.timeIntervalSince1970 } ?? .zero
            let screenshot = app.screenshotForFailureEvidence()
            captureCount += 1
            returnedAt = Date().timeIntervalSince1970
            png = screenshot.pngRepresentation
            guard let image = screenshot.image.cgImage, let buffer = image.dataProvider?.data,
                Date() < deadline
            else { return false }
            let pixels = buffer as Data
            let format = [
                image.width, image.height, image.bytesPerRow, image.bitsPerComponent, image.bitsPerPixel,
                Int(image.bitmapInfo.rawValue)
            ]
            let matches = previousFormat == format && previousPixels == pixels
            previousPixels = pixels
            previousFormat = format
            previousReturnedAt = Date(timeIntervalSince1970: returnedAt)
            return matches && Date() < deadline
        }
        guard isStable else {
            XCTFail("Album capture pixels must match at least 0.6 seconds apart within the playback capture budget.")
            return nil
        }
        print(
            "Album pixel stability: captures=\(captureCount), pairSeconds=\(pairSeconds), remainingSeconds=\(deadline.timeIntervalSinceNow)"
        )
        return (png, requestedAt, returnedAt)
    }

    @MainActor
    func prepareAlbumCapturePlayback(app: XCUIApplication) -> Bool {
        let driver = IOSDriver(app: app)
        driver.applyPlaybackSettings([.interval30Seconds])
        #if DEBUG
        let timeout = AlbumCaptureTiming.intervalConfirmationSeconds
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var baseline: (layers: String, history: Int, progress: Double, sampledAt: TimeInterval)?
        var shortIntervalTarget: (layers: String, history: Int)?
        var before: [String: String] = [:]
        var after: [String: String] = [:]
        var hasValidProbe = false
        var isLastProbeValid = false
        var measuredSlope: Double?
        FirstFailureContext.mark("wait-scene", element: "slideshow.scenePresentation.contract.summary")
        let isConfirmed = TestWait.until(.product(timeout)) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            let requestedAt = ProcessInfo.processInfo.systemUptime
            var didSnapshotFail = false
            let snapshots = app.evidenceSnapshotsByIdentifier(onSnapshotFailure: { _ in didSnapshotFail = true })
            after = self.albumSceneObservation(snapshots: snapshots, didSnapshotFail: didSnapshotFail)
            // Root progress can remain cached between state changes; this existing leaf follows TimelineView.
            after["motionRender"] = snapshots["slideshow.scenePresentation.frameSynchronized.summary"]?.label ?? ""
            let returnedAt = ProcessInfo.processInfo.systemUptime
            let render = SharedSceneEvidenceManifest.parseKeyValueFields(after["motionRender"] ?? "")
            let progressFields = (render["motionRawProgress"] ?? "").split(separator: "|")
            let progressValues = progressFields.compactMap { Double($0) }
            isLastProbeValid =
                after["entryHintVisible"] != "unknown" && !render.isEmpty
                && render["layerIDs"].map { !$0.isEmpty && $0 != "none" } == true
                && Int(render["historyCount"] ?? "") != nil
                && !progressValues.isEmpty && progressValues.count == progressFields.count
                && progressValues.allSatisfy { $0.isFinite }
            hasValidProbe = hasValidProbe || isLastProbeValid
            guard isLastProbeValid, returnedAt < deadline,
                let layers = render["layerIDs"], !layers.isEmpty, layers != "none",
                let history = Int(render["historyCount"] ?? ""),
                let progress = Double(render["motionRawProgress"] ?? ""),
                render["playbackPaused"] == "false",
                StrictE2ESceneCapture.isStableWindow(
                    after.merging(["render": after["motionRender"] ?? ""]) { _, new in new })
            else {
                baseline = nil
                return false
            }
            if let shortIntervalTarget, shortIntervalTarget.layers == layers, shortIntervalTarget.history == history {
                return false
            }
            shortIntervalTarget = nil
            // This probe has no timestamp; monotonic snapshot midpoints include delayed read cadence.
            let sampledAt = (requestedAt + returnedAt) / 2
            guard let first = baseline, first.layers == layers, first.history == history else {
                before = after
                baseline = (layers, history, progress, sampledAt)
                return false
            }
            let elapsedSeconds = sampledAt - first.sampledAt
            guard elapsedSeconds >= AlbumCaptureTiming.progressSampleSeconds else { return false }
            let slope = (progress - first.progress) / elapsedSeconds
            measuredSlope = slope
            if AlbumCaptureTiming.longIntervalSlopeRange.contains(slope) { return true }
            if slope > AlbumCaptureTiming.longIntervalSlopeRange.upperBound {
                // A short target must naturally give way; never tap Next to force the interval.
                shortIntervalTarget = (layers, history)
            }
            before = after
            baseline = (layers, history, progress, sampledAt)
            return false
        }
        after["interval_progress_slope"] = measuredSlope.map { String($0) } ?? "unknown"
        attachStrictSceneObservation(before: before, after: after, name: "album-interval-confirmation")
        guard isConfirmed else {
            if !hasValidProbe || !isLastProbeValid {
                XCTFail("Album interval confirmation must read a valid non-empty scene progress probe before Pause.")
            } else if shortIntervalTarget != nil {
                XCTFail(
                    "Album interval confirmation must observe a new scene after measuring a short interval before Pause."
                )
            } else {
                XCTFail(
                    "Album interval confirmation must measure the current scene's 30-second progress slope before Pause."
                )
            }
            return false
        }
        print(
            "Album interval confirmation: slope=\(measuredSlope ?? .nan), remainingSeconds=\(deadline - ProcessInfo.processInfo.systemUptime)"
        )
        #endif
        return true
    }

    @MainActor
    func pauseStableAlbumPlaybackIfNeeded(app: XCUIApplication) -> Bool {
        #if DEBUG
        // Stability and the actionable target share the original 8 s Pause-preparation deadline.
        let identifier = "slideshow.control.playPause.button"
        let deadline = Date().addingTimeInterval(TestWait.seconds(.product(4)) + TestWait.seconds(.product(4)))
        var prepared: SlideshowControlBarButtonObservation?
        var before: [String: String] = [:]
        var didWake = false
        FirstFailureContext.mark("wait-scene", element: identifier)
        let isReady = TestWait.until(.product(max(.zero, deadline.timeIntervalSinceNow))) {
            guard let controls = try? app.slideshowControlBarButtonObservation(identifier: identifier) else {
                return false
            }
            before = self.albumSceneObservation(snapshots: controls.snapshots)
            guard Date() < deadline else { return false }
            guard controls.isReady else {
                if !didWake, !controls.hasSettingsNavigationEvidence {
                    didWake = true
                    FirstFailureContext.mark("reveal-controls", element: identifier)
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tapForFailureEvidence()
                }
                return false
            }
            guard controls.windowElement.buttons[identifier].isHittable, Date() < deadline else { return false }
            // The stable scene/target snapshot must be the last accessibility read before Pause.
            let snapshotRequestedAt = Date().timeIntervalSince1970
            guard let stableControls = try? app.slideshowControlBarButtonObservation(identifier: identifier) else {
                return false
            }
            let snapshotReturnedAt = Date().timeIntervalSince1970
            before = self.albumSceneObservation(snapshots: stableControls.snapshots)
            before["stable_snapshot_requested_unix"] = String(snapshotRequestedAt)
            before["stable_snapshot_returned_unix"] = String(snapshotReturnedAt)
            guard stableControls.isReady, StrictE2ESceneCapture.isStableWindow(before),
                before["entryHintVisible"] == "false",
                let value = stableControls.button?.value as? String, ["pause", "play"].contains(value.lowercased()),
                Date() < deadline
            else { return false }
            prepared = stableControls
            return true
        }
        FirstFailureContext.mark("wait-scene", element: identifier)
        guard isReady, Date() < deadline, let prepared, let button = prepared.button else {
            attachStrictSceneObservation(before: before, after: before, name: "album-before-pause")
            if rejectFrozenAlbumTransition(before) { return false }
            XCTFail("Album capture preparation must reach a stable scene before Pause.")
            return false
        }
        var pauseTapIssuedAt = "notIssued"
        var pauseTapReturnedAt = "notReturned"
        if (button.value as? String)?.lowercased() == "pause" {
            FirstFailureContext.mark("select", element: identifier)
            // Use the stable observation's target once; no re-resolution or Pause retry.
            let target = prepared.windowElement.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(
                    dx: button.frame.midX - prepared.windowFrame.minX,
                    dy: button.frame.midY - prepared.windowFrame.minY)
            )
            pauseTapIssuedAt = String(Date().timeIntervalSince1970)
            target.tapForFailureEvidence()
            pauseTapReturnedAt = String(Date().timeIntervalSince1970)
        }
        var after = before
        FirstFailureContext.mark("wait-scene", element: identifier)
        let isPaused = TestWait.until(.product(4)) {
            guard let controls = try? app.slideshowControlBarButtonObservation(identifier: identifier) else {
                return false
            }
            after = self.albumSceneObservation(snapshots: controls.snapshots)
            return SharedSceneEvidenceManifest.parseKeyValueFields(after["render"] ?? "")["playbackPaused"] == "true"
                && after["playPauseValue"] == "play"
        }
        after["pause_tap_issued_unix"] = pauseTapIssuedAt
        after["pause_tap_returned_unix"] = pauseTapReturnedAt
        attachStrictSceneObservation(before: before, after: after, name: "album-pause")
        guard isPaused else {
            if after["playPauseValue"] != "play" {
                XCTFail("After pausing, the control value must be play.")
                return false
            }
            XCTFail("Album capture preparation must observe paused playback after one Pause.")
            return false
        }
        return true
        #else
        pausePlaybackIfNeeded(app: app)
        return true
        #endif
    }

    @MainActor
    func captureStableAlbumPlaybackPNG(
        app: XCUIApplication, name: String, previousScene: [String: String]? = nil
    ) throws -> [String: String] {
        #if DEBUG
        // Retained EXIF can still fade after the scene probe settles; preserve the old minimum settle time.
        let settleDeadline = Date().addingTimeInterval(TestWait.seconds(.product(0.8)))
        let deadline = settleDeadline.addingTimeInterval(TestWait.seconds(.product(4)))
        var before: [String: String] = [:]
        let previousRender = SharedSceneEvidenceManifest.parseKeyValueFields(previousScene?["render"] ?? "")
        var didAdvanceHistory: Bool?
        var hasObservedHistoryAdvance = false
        var didChangeLayers = false
        FirstFailureContext.mark("wait-scene", element: "slideshow.scenePresentation.contract.summary")
        let isReady = TestWait.until(.product(max(.zero, deadline.timeIntervalSinceNow))) {
            guard Date() >= settleDeadline else { return false }
            before = self.albumSceneObservation(app: app)
            let render = SharedSceneEvidenceManifest.parseKeyValueFields(before["render"] ?? "")
            didAdvanceHistory =
                Int(previousRender["historyCount"] ?? "").flatMap { previousCount in
                    Int(render["historyCount"] ?? "").map { $0 == previousCount + 1 }
                }
            // Retain progress for timeout diagnostics; readiness still requires the current snapshot.
            hasObservedHistoryAdvance = hasObservedHistoryAdvance || didAdvanceHistory == true
            didChangeLayers =
                render["layerIDs"] != nil && previousRender["layerIDs"] != nil
                && render["layerIDs"] != previousRender["layerIDs"]
            guard self.isPausedStableAlbumScene(before), Date() < deadline else { return false }
            return previousScene == nil || didAdvanceHistory == true || didChangeLayers
        }
        FirstFailureContext.mark("wait-scene", element: "slideshow.scenePresentation.contract.summary")
        guard isReady else {
            attachStrictSceneObservation(before: before, after: before, name: "\(name)-scene")
            print("Album capture gate root: \(before["render"] ?? "missing")")
            print("Album capture gate frame: \(before["frameSynchronizedRender"] ?? "missing")")
            let render = SharedSceneEvidenceManifest.parseKeyValueFields(before["render"] ?? "")
            let isManifestComplete = SharedSceneEvidenceManifest.manifestObservation(from: before["manifest"] ?? "")?
                .isCompleteVisibleScene
            let facts =
                "historyAdvanced=\(hasObservedHistoryAdvance ? "true" : didAdvanceHistory.map { String($0) } ?? "unknown"), layersChanged=\(didChangeLayers), phase=\(render["phase"] ?? "unknown"), paused=\(render["playbackPaused"] ?? "unknown"), manifestComplete=\(isManifestComplete.map { String($0) } ?? "unknown")"
            let gate = FirstFailureContext.AlbumCaptureGate(
                stable: render.isEmpty ? nil : StrictE2ESceneCapture.isStableWindow(before),
                paused: render["playbackPaused"].flatMap(Bool.init),
                entryHintHidden: before["entryHintVisible"].flatMap(Bool.init).map { !$0 },
                // Advance means observed at any poll, not necessarily the last observation.
                advanced: previousScene == nil ? nil : (hasObservedHistoryAdvance ? true : didAdvanceHistory),
                layersChanged: previousScene == nil || render["layerIDs"] == nil || previousRender["layerIDs"] == nil
                    ? nil : didChangeLayers,
                manifestComplete: isManifestComplete,
                phase: .init(rawValue: render["phase"] ?? "") ?? .unknown)
            FirstFailureContext.withAlbumCaptureGate(gate) {
                if previousScene == nil, rejectFrozenAlbumTransition(before) { return }
                if previousScene != nil, !hasObservedHistoryAdvance, !didChangeLayers {
                    FirstFailureContext.mark("wait-scene", element: "slideshow.control.next.button")
                    XCTFail("Album Next must advance the paused scene within the playback capture budget. (\(facts))")
                } else {
                    XCTFail(
                        "Album capture preparation must reach a complete paused scene within the playback capture budget. (\(facts))"
                    )
                }
            }
            return [:]
        }
        guard let capture = captureStableAlbumPixels(app: app, deadline: deadline) else { return [:] }
        let captureRequestedAt = capture.requestedAt
        let png = capture.png
        let captureReturnedAt = capture.returnedAt
        let after = albumSceneObservation(app: app)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try StrictE2EVisualEvidence.writeRequiredPNG(png, name: name)
        attachStrictSceneObservation(before: before, after: after, name: "\(name)-scene")
        try StrictE2EVisualEvidence.writeRequiredJSON(
            [
                "before": before, "after": after, "deadline_unix": deadline.timeIntervalSince1970,
                "capture_requested_unix": captureRequestedAt, "capture_returned_unix": captureReturnedAt
            ], name: "\(name)-window.json")
        let beforeRender = SharedSceneEvidenceManifest.parseKeyValueFields(before["render"] ?? "")
        let afterRender = SharedSceneEvidenceManifest.parseKeyValueFields(after["render"] ?? "")
        let beforeManifest = SharedSceneEvidenceManifest.parseKeyValueFields(before["manifest"] ?? "")
        let afterManifest = SharedSceneEvidenceManifest.parseKeyValueFields(after["manifest"] ?? "")
        FirstFailureContext.mark("capture-frame", element: "app-window")
        if rejectFrozenAlbumTransition(after) { return [:] }
        XCTAssertTrue(
            !png.isEmpty && isPausedStableAlbumScene(after)
                && beforeRender["layerIDs"] == afterRender["layerIDs"]
                && beforeRender["historyCount"] == afterRender["historyCount"]
                && beforeManifest["ledgerSceneAssets"] == afterManifest["ledgerSceneAssets"]
                && beforeManifest["scenePublishTimestamp"] == afterManifest["scenePublishTimestamp"],
            "Visual ID failed \(name): the single capture must retain the complete paused scene")
        return before
        #else
        _ = try captureAlbumPlaybackPNG(app: app, name: name)
        return [:]
        #endif
    }

    private func isPausedStableAlbumScene(_ observation: [String: String]) -> Bool {
        StrictE2ESceneCapture.isStableWindow(observation)
            && SharedSceneEvidenceManifest.parseKeyValueFields(observation["render"] ?? "")["playbackPaused"] == "true"
            && observation["entryHintVisible"] == "false"
    }

    private func rejectFrozenAlbumTransition(_ observation: [String: String]) -> Bool {
        let render = SharedSceneEvidenceManifest.parseKeyValueFields(observation["render"] ?? "")
        guard render["phase"] == "transition", render["playbackPaused"] == "true" else { return false }
        XCTFail("Album capture preparation paused during a transition; Pause freezes the current layers.")
        return true
    }

    @MainActor
    private func albumSceneObservation(app: XCUIApplication) -> [String: String] {
        var didSnapshotFail = false
        let snapshots = app.evidenceSnapshotsByIdentifier(onSnapshotFailure: { _ in didSnapshotFail = true })
        return albumSceneObservation(snapshots: snapshots, didSnapshotFail: didSnapshotFail)
    }

    private func albumSceneObservation(
        snapshots: [String: XCUIElementSnapshot], didSnapshotFail: Bool = false
    ) -> [String: String] {
        return [
            "manifest": snapshots["slideshow.smartfill.currentManifest.flag"]?.label ?? "",
            "render": snapshots["slideshow.scenePresentation.contract.summary"]?.label ?? "",
            "frameSynchronizedRender": snapshots["slideshow.scenePresentation.frameSynchronized.summary"]?.label ?? "",
            "playPauseValue": (snapshots["slideshow.control.playPause.button"]?.value as? String)?.lowercased()
                ?? "unknown",
            "entryHintVisible": didSnapshotFail ? "unknown" : String(snapshots["slideshow.entryHint.banner"] != nil),
            "observed_unix": String(Date().timeIntervalSince1970)
        ]
    }

    @MainActor
    func tapNext(app: XCUIApplication) {
        revealPlaybackControls(app: app)
        let next = app.buttons["slideshow.control.next.button"]
        XCTAssertTrue(
            next.waitForPublicElement("slideshow.control.next.button", timeout: TestWait.seconds(.product(8))),
            "Playback page must have Next")
        tapElement(next)
    }

    // For B, the album list returns to the editor in settings: it has Done and no Start Playback.
    @MainActor
    func assertSettingsFilterEditorAfterServerSwitchAlbumSelection(app: XCUIApplication, expectedPhotoCount: Int) {
        XCTAssertTrue(
            app.staticTexts["filterEditor.page.title"].waitForFailureEvidence(timeout: TestWait.seconds(.product(8)))
                || app.descendants(matching: .any)["filterEditor.page.title"].waitForFailureEvidence(
                    timeout: TestWait.seconds(.product(2))),
            "After selecting the B album, the app must stay on the settings editor"
        )
        let albumEntry = app.buttons["filter.editor.album.entry"]
        XCTAssertTrue(
            albumEntry.waitForFailureEvidence(timeout: TestWait.seconds(.product(8))),
            "Editor must offer the album entry")
        XCTAssertTrue(app.staticTexts["filter.editor.summary.title"].exists, "Editor must show the filter summary")
        XCTAssertFalse(
            app.buttons["filterSummary.startPlayback.button"].exists,
            "The settings editor has no Start Playback; do not assert it like the first-boot summary"
        )
        let done = app.buttons["filter.editor.done.button"]
        let doneElement = app.descendants(matching: .any)["filter.editor.done.button"]
        XCTAssertTrue(done.exists || doneElement.exists, "Editor must have Done")
        XCTAssertTrue(
            editorAlbumCardShowsSelection(albumEntry, selectedAlbums: "1", pendingPhotos: String(expectedPhotoCount))
                || editorSummaryShowsSelection(app, selectedAlbums: "1", pendingPhotos: String(expectedPhotoCount)),
            "Editor album card must show the manifest-selected album and photo counts"
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
        if done.waitForFailureEvidence(timeout: TestWait.seconds(.product(4))) {
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
                backButton.tapForFailureEvidence()
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
            serverEntry.waitForFailureEvidence(timeout: TestWait.seconds(.product(8))),
            "Settings must offer the server entry")
        tapElement(serverEntry)
        let serverField = app.textFields["firstboot.serverURL.field"]
        XCTAssertTrue(
            serverField.waitForPublicElement("firstboot.serverURL.field", timeout: TestWait.seconds(.product(8))),
            "Server settings page should show the URL")
        replaceText(
            in: serverField, app: app, with: serverURL, evidenceName: "server-url-replace",
            shouldRequireExactValue: true)
        let apiKeyField = app.secureTextFields["firstboot.apiKey.field"]
        if apiKeyField.waitForPublicElement("firstboot.apiKey.field", timeout: TestWait.seconds(.product(4))) {
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
        if !playbackEntry.waitForFailureEvidence(timeout: TestWait.seconds(.product(2))) {
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
            playbackEntry.waitForFailureEvidence(timeout: TestWait.seconds(.product(8))),
            "After the server switch, settings must still offer the playback entry")
        tapElement(playbackEntry)
        let filterConfig = app.buttons["settings.playback.filterConfig.button"]
        if !filterConfig.waitForFailureEvidence(timeout: TestWait.seconds(.product(2))) {
            let modePicker = app.segmentedControls["settings.playback.mode.picker"]
            XCTAssertTrue(
                modePicker.waitForFailureEvidence(timeout: TestWait.seconds(.product(8))),
                "Playback settings must offer the default playback mode")
            let filteredMode = modePicker.buttons.element(boundBy: 1)
            XCTAssertTrue(
                filteredMode.waitForFailureEvidence(timeout: TestWait.seconds(.product(4))),
                "Playback settings must offer the filtered playback option")
            tapElement(filteredMode)
            // ui-label-lookup: SwiftUI alert content does not expose accessibility identifiers
            let configure = app.buttons["去配置"]
            XCTAssertTrue(
                configure.waitForFailureEvidence(timeout: TestWait.seconds(.product(8))),
                "After the server switch clears filters, reconfiguring must be allowed")
            tapElement(configure)
        } else {
            if !filterConfig.isHittable {
                app.swipeUpForFailureEvidence()
            }
            tapElement(filterConfig)
        }
        XCTAssertTrue(
            app.buttons["filter.editor.album.entry"].waitForFailureEvidence(timeout: TestWait.seconds(.product(12)))
                || app.staticTexts["filterEditor.page.title"].waitForFailureEvidence(
                    timeout: TestWait.seconds(.product(4))),
            "Filter editor must open after the server switch"
        )
    }

    @MainActor
    func isolateAlbumSelection(app: XCUIApplication, keeping albumID: String) {
        let clear = app.buttons["albumFilter.clear.button"]
        if clear.waitForFailureEvidence(timeout: TestWait.seconds(.product(4))) {
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
            app.descendants(matching: .any)["settings.item.server"].firstMatch.waitForFailureEvidence(
                timeout: TestWait.seconds(.product(8)))
                || app.descendants(matching: .any)["settings.item.playback"].firstMatch.waitForFailureEvidence(
                    timeout: TestWait.seconds(.product(2))),
            "Playback page must open settings"
        )
    }

    @MainActor
    func openPlaybackSettingsFromSlideshow(app: XCUIApplication) {
        openSettingsHomeFromPlayback(app: app)
        let playbackEntry = app.descendants(matching: .any)["settings.item.playback"].firstMatch
        XCTAssertTrue(
            playbackEntry.waitForFailureEvidence(timeout: TestWait.seconds(.product(8))),
            "Settings must offer the playback entry")
        tapElement(playbackEntry)
        XCTAssertTrue(
            app.segmentedControls["settings.playback.displayMode.picker"].waitForFailureEvidence(
                timeout: TestWait.seconds(.product(8))),
            "Playback settings must offer the display policy"
        )
    }

    @MainActor
    func selectSinglePhotoDisplayMode(app: XCUIApplication) {
        let picker = app.segmentedControls["settings.playback.displayMode.picker"]
        XCTAssertTrue(
            picker.waitForFailureEvidence(timeout: TestWait.seconds(.product(8))),
            "Playback settings must offer the display policy segmented control")
        let singlePhoto = picker.buttons["settings.playback.displayMode.singlePhoto.option"]
        XCTAssertTrue(
            singlePhoto.waitForFailureEvidence(timeout: TestWait.seconds(.product(3))),
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
            picker.waitForFailureEvidence(timeout: TestWait.seconds(.product(8))),
            "Playback settings must offer the display policy segmented control")
        let smartFill = picker.buttons["settings.playback.displayMode.smartFill.option"]
        XCTAssertTrue(
            smartFill.waitForFailureEvidence(timeout: TestWait.seconds(.product(3))),
            "Display policy must offer Smart Fill")
        tapElement(smartFill)
        XCTAssertTrue(
            waitUntil(timeout: TestWait.seconds(.product(6))) { smartFill.isSelected },
            "After choosing it on the real settings page, Smart Fill must read back as selected"
        )
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
