import XCTest

#if os(tvOS)
extension SmokeFlowTVOSUITests {
    struct Observation {
        var nodes: [String: XCUIElementSnapshot]
        var allNodes: [XCUIElementSnapshot]
    }

    private enum FlowError: Error {
        case failedStep(String)
    }

    @MainActor
    func tvSmokeRunFlow(
        shouldInjectConfiguration: Bool = false, shouldExposeSceneProbe: Bool = false,
        file: StaticString = #filePath, line: UInt = #line,
        _ flow: (XCUIApplication, TestWait.HangGuard) throws -> Void
    ) throws {
        let guardWait = TestWait.hangGuard()
        peerExifLabels = []
        didObservePeerPhoto = false
        let input = try requireStrictE2EInput()
        let app = XCUIApplication()
        app.launchEnvironment = [:]
        if shouldInjectConfiguration {
            app.launchEnvironment = [
                "UI_TEST_RESET_STATE": "1", "UI_TEST_SERVER_URL": input.serverURL,
                "UI_TEST_API_KEY": input.publicKey, "UI_TEST_FORCE_MODE_SELECTION": "1",
                "UI_TEST_DISABLE_PLAYBACK_ENTRY_HINT": "1"
            ]
        }
        if shouldExposeSceneProbe {
            app.launchEnvironment["UI_TEST_SCENE_PRESENTATION_CONTRACT_PROBE"] = "1"
        }
        try tvSmokePerform("launch", guardWait: guardWait, file: file, line: line) { app.launch() }
        defer { app.terminateForFailureEvidence() }
        if !shouldInjectConfiguration {
            try tvSmokeSaveServer(input, app: app, guardWait: guardWait, file: file, line: line)
        }
        try flow(app, guardWait)
    }

    @MainActor
    func tvSmokeObservation(_ app: XCUIApplication) -> Observation? {
        guard let root = try? app.snapshot() else { return nil }
        var nodes: [String: XCUIElementSnapshot] = [:]
        var allNodes: [XCUIElementSnapshot] = []
        var pending = [root]
        while let node = pending.popLast() {
            allNodes.append(node)
            if !node.identifier.isEmpty {
                let previous = nodes[node.identifier]
                // Native controls can wrap a same-identifier label; keep the actionable or focused snapshot.
                if previous == nil || node.hasFocus
                    || (previous?.hasFocus == false && previous?.elementType != .button && node.elementType == .button)
                {
                    nodes[node.identifier] = node
                }
            }
            pending.append(contentsOf: node.children)
        }
        let current = Observation(nodes: nodes, allNodes: allNodes)
        if !peerExifLabels.isEmpty, tvSmokeIsPlaybackSurface(current),
            allNodes.contains(where: { peerExifLabels.contains($0.label) })
        {
            didObservePeerPhoto = true
        }
        return current
    }

    @MainActor
    func tvSmokeExpect(
        _ app: XCUIApplication, guardWait: TestWait.HangGuard, file: StaticString = #filePath, line: UInt = #line,
        step: String,
        _ condition: (Observation) -> Bool
    ) throws {
        FirstFailureContext.mark("query-element", element: "app-window")
        let satisfied = guardWait.transaction().until {
            guard let current = tvSmokeObservation(app) else { return false }
            return condition(current)
        }
        XCTAssertTrue(satisfied, "Smoke flow: \(step).", file: file, line: line)
        if !satisfied { throw FlowError.failedStep(step) }
    }

    @MainActor
    func tvSmokePerform(
        _ name: String, guardWait: TestWait.HangGuard, file: StaticString = #filePath, line: UInt = #line,
        _ action: () -> Void
    ) throws {
        guard guardWait.transaction().perform(name, action) else { try tvSmokeFail(name, file: file, line: line) }
    }

    @MainActor
    func tvSmokePress(
        _ button: XCUIRemote.Button, guardWait: TestWait.HangGuard, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try tvSmokePerform("remote", guardWait: guardWait, file: file, line: line) { FirstFailureRemote.press(button) }
    }

    @MainActor
    func tvSmokeFocus(
        _ identifier: String, app: XCUIApplication, guardWait: TestWait.HangGuard, file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try tvSmokeExpect(app, guardWait: guardWait, file: file, line: line, step: "control appears: \(identifier)") {
            $0.nodes[identifier]?.isEnabled == true
        }
        for _ in 0..<16 {
            var observation: Observation?
            var didAwaitInitialFocus = false
            try tvSmokeExpect(app, guardWait: guardWait, file: file, line: line, step: "focus observation") {
                guard $0.nodes[identifier] != nil else { return false }
                guard $0.allNodes.contains(where: { $0.hasFocus }) else {
                    didAwaitInitialFocus = true
                    return false
                }
                observation = $0
                return true
            }
            // Preserve the prior fresh read after the initial focus handoff, before issuing a direction.
            if didAwaitInitialFocus { continue }
            guard let current = observation, let target = current.nodes[identifier] else {
                try tvSmokeFail("focus observation", file: file, line: line)
            }
            if target.hasFocus { return }
            guard let focused = current.allNodes.first(where: { $0.hasFocus }) else {
                try tvSmokeExpect(app, guardWait: guardWait, file: file, line: line, step: "initial remote focus") {
                    $0.allNodes.contains { $0.hasFocus }
                }
                continue
            }
            let dx = target.frame.midX - focused.frame.midX
            let dy = target.frame.midY - focused.frame.midY
            let direction: XCUIRemote.Button =
                abs(dy) > target.frame.height / 2 ? (dy > 0 ? .down : .up) : (dx > 0 ? .right : .left)
            try tvSmokePress(direction, guardWait: guardWait, file: file, line: line)
            try tvSmokeExpect(
                app, guardWait: guardWait, file: file, line: line, step: "remote focus moves toward \(identifier)"
            ) {
                $0.nodes[identifier]?.hasFocus == true
                    || $0.allNodes.contains {
                        $0.hasFocus && ($0.identifier != focused.identifier || $0.label != focused.label)
                    }
            }
        }
        try tvSmokeFail("remote cannot focus \(identifier)", file: file, line: line)
    }

    @MainActor
    func tvSmokeSelect(
        _ identifier: String, app: XCUIApplication, guardWait: TestWait.HangGuard, file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        if identifier.hasPrefix("slideshow.control.") {
            try tvSmokeWakeControls(app, guardWait: guardWait, file: file, line: line)
        }
        try tvSmokeFocus(identifier, app: app, guardWait: guardWait, file: file, line: line)
        FirstFailureContext.mark("select", element: identifier)
        try tvSmokePress(.select, guardWait: guardWait, file: file, line: line)
        if identifier == "slideshow.control.next.button", !peerExifLabels.isEmpty {
            _ = try tvSmokeSwitchPhase("next-loop", guardWait: guardWait, didPressNext: true)
        }
    }

    @MainActor
    func tvSmokeSaveServer(
        _ input: StrictE2EInput, app: XCUIApplication, guardWait: TestWait.HangGuard, file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try tvSmokeReplaceText(
            "firstboot.serverURL.field", with: input.serverURL, app: app, guardWait: guardWait, file: file, line: line)
        try tvSmokeReplaceText(
            "firstboot.apiKey.field", with: input.publicKey, app: app, guardWait: guardWait, file: file, line: line)
        try tvSmokeExpect(app, guardWait: guardWait, file: file, line: line, step: "connection action is available") {
            $0.nodes["firstboot.testConnection.button"]?.isEnabled == true
        }
        // Follow the form's remote routing; its wrapped label is not a reliable native-focus observation.
        try tvSmokePress(.down, guardWait: guardWait, file: file, line: line)
        try tvSmokePress(.right, guardWait: guardWait, file: file, line: line)
        try tvSmokePress(.select, guardWait: guardWait, file: file, line: line)
        try tvSmokeExpect(app, guardWait: guardWait, file: file, line: line, step: "public fixture connection succeeds")
        {
            $0.nodes["firstboot.connection.success"] != nil
                || ($0.nodes["settings.server.hero.summary"] != nil
                    && $0.nodes["firstboot.saveConfig.button"]?.isEnabled == true)
        }
        try tvSmokeExpect(app, guardWait: guardWait, file: file, line: line, step: "verified connection enables Save") {
            $0.nodes["firstboot.saveConfig.button"]?.isEnabled == true
        }
        // Successful verification requests Save focus; Right also reaches it if the native handoff is pending.
        try tvSmokePress(.right, guardWait: guardWait, file: file, line: line)
        try tvSmokePress(.select, guardWait: guardWait, file: file, line: line)
    }

    @MainActor
    func tvSmokeReplaceText(
        _ identifier: String, with value: String, app: XCUIApplication, guardWait: TestWait.HangGuard,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try tvSmokeFocus(identifier, app: app, guardWait: guardWait, file: file, line: line)
        let oldValue = tvSmokeObservation(app).map { Self.tvSmokeValue($0.nodes[identifier]) } ?? ""
        try tvSmokePress(.select, guardWait: guardWait, file: file, line: line)
        try tvSmokeExpect(app, guardWait: guardWait, file: file, line: line, step: "system keyboard opens") {
            $0.allNodes.contains { $0.elementType == .keyboard }
        }
        if !oldValue.isEmpty {
            try tvSmokePerform("type", guardWait: guardWait, file: file, line: line) {
                app.typeForFailureEvidence(
                    String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldValue.count + 8))
            }
        }
        try tvSmokePerform("type", guardWait: guardWait, file: file, line: line) { app.typeForFailureEvidence(value) }
        // ui-label-lookup: tvOS system keyboard submit keys use the simulator's English or Chinese locale.
        let submit = app.buttons.matching(NSPredicate(format: "label IN %@", ["下一项", "Next", "完成", "Done"])).firstMatch
        for _ in 0..<8 {
            guard let snapshot = try? submit.snapshot() else {
                try tvSmokeFail("system keyboard submit", file: file, line: line)
            }
            if snapshot.hasFocus { break }
            try tvSmokePress(.down, guardWait: guardWait, file: file, line: line)
        }
        XCTAssertTrue(
            try submit.snapshot().hasFocus, "Smoke flow: system keyboard submit has focus.", file: file, line: line)
        try tvSmokePress(.select, guardWait: guardWait, file: file, line: line)
        var shouldCloseKeyboard = false
        try tvSmokeExpect(app, guardWait: guardWait, file: file, line: line, step: "keyboard submission settles") {
            let keyboards = $0.allNodes.filter { $0.elementType == .keyboard }
            if keyboards.isEmpty { return $0.nodes[identifier]?.hasFocus == true }
            // Require active keyboard focus before treating an attached keyboard as needing Menu.
            guard keyboards.contains(where: Self.tvSmokeHasFocusedDescendant) else { return false }
            shouldCloseKeyboard = true
            return true
        }
        if shouldCloseKeyboard {
            try tvSmokePress(.menu, guardWait: guardWait, file: file, line: line)
        }
        try tvSmokeExpect(app, guardWait: guardWait, file: file, line: line, step: "keyboard returns focus to field") {
            $0.nodes[identifier]?.hasFocus == true && !$0.allNodes.contains { $0.elementType == .keyboard }
        }
    }

    @MainActor
    func tvSmokeChooseMode(
        _ mode: String, app: XCUIApplication, guardWait: TestWait.HangGuard, file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try tvSmokeSelect("mode.\(mode).button", app: app, guardWait: guardWait, file: file, line: line)
        try tvSmokeSelect("mode.continue.button", app: app, guardWait: guardWait, file: file, line: line)
    }

    @MainActor
    func tvSmokeExpectPlayback(
        _ app: XCUIApplication, guardWait: TestWait.HangGuard, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try tvSmokeExpect(app, guardWait: guardWait, file: file, line: line, step: "usable playback surface") {
            tvSmokeIsPlaybackSurface($0)
        }
    }

    @MainActor
    func tvSmokeWakeControls(
        _ app: XCUIApplication, guardWait: TestWait.HangGuard, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try tvSmokeExpectPlayback(app, guardWait: guardWait, file: file, line: line)
        if guardWait.transaction().probe({ tvSmokeObservation(app)?.nodes[wakeID] != nil }) {
            try tvSmokePress(.up, guardWait: guardWait, file: file, line: line)
        }
        try tvSmokeExpect(app, guardWait: guardWait, file: file, line: line, step: "playback controls visible") {
            $0.nodes[playPauseID] != nil
        }
    }

    @MainActor
    func tvSmokeExpectState(
        _ state: String, app: XCUIApplication, guardWait: TestWait.HangGuard, file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try tvSmokeExpect(app, guardWait: guardWait, file: file, line: line, step: "Play/Pause state is \(state)") {
            Self.tvSmokeValue($0.nodes[playPauseID]).lowercased() == state
        }
    }

    @MainActor
    func tvSmokePlaybackIndex(
        _ app: XCUIApplication, guardWait: TestWait.HangGuard, file: StaticString = #filePath, line: UInt = #line
    ) throws -> Int {
        try tvSmokeWakeControls(app, guardWait: guardWait, file: file, line: line)
        var observed: Int?
        try tvSmokeExpect(app, guardWait: guardWait, file: file, line: line, step: "playback has a current scene") {
            observed = Self.tvSmokeIndex($0.nodes[indexID])
            return observed != nil
        }
        guard let observed else { try tvSmokeFail("playback index", file: file, line: line) }
        return observed
    }

    @MainActor
    func tvSmokeSettledSceneReferences(
        _ app: XCUIApplication, guardWait: TestWait.HangGuard, file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        var observed: String?
        try tvSmokeExpect(
            app, guardWait: guardWait, file: file, line: line, step: "settled scene has observable references"
        ) {
            observed = Self.tvSmokeSceneReferences($0)
            return observed != nil && Self.tvSmokeIsSettledScene($0)
        }
        guard let observed else { try tvSmokeFail("settled scene references", file: file, line: line) }
        return observed
    }

    @MainActor
    func tvSmokeOpenSettingsGate(
        _ app: XCUIApplication, guardWait: TestWait.HangGuard, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try tvSmokeSelect("slideshow.control.settings.button", app: app, guardWait: guardWait, file: file, line: line)
        try tvSmokeExpect(app, guardWait: guardWait, file: file, line: line, step: "PIN gate appears") {
            $0.nodes["pinEntry.close.button"] != nil
        }
    }

    @MainActor
    func tvSmokeOpenSettings(
        _ app: XCUIApplication, guardWait: TestWait.HangGuard, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try tvSmokeSelect("slideshow.control.settings.button", app: app, guardWait: guardWait, file: file, line: line)
        try tvSmokeExpect(app, guardWait: guardWait, file: file, line: line, step: "Settings opens") {
            $0.nodes["settings.item.playback"] != nil
        }
    }

    @MainActor
    func tvSmokeReturnToPlayback(
        _ app: XCUIApplication, guardWait: TestWait.HangGuard, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for _ in 0..<6 {
            var isOnPlayback = false
            var previousPage = Set<String>()
            var previousFocus = Set<String>()
            try tvSmokeExpect(
                app, guardWait: guardWait, file: file, line: line, step: "Settings or playback is ready for Back"
            ) {
                isOnPlayback = tvSmokeIsPlaybackSurface($0)
                previousPage = Self.tvSmokeSettingsIdentifiers($0)
                previousFocus = Self.tvSmokeFocusSignatures($0)
                return isOnPlayback || (!previousPage.isEmpty && !previousFocus.isEmpty)
            }
            if isOnPlayback {
                try tvSmokeWakeControls(app, guardWait: guardWait, file: file, line: line)
                return
            }
            try tvSmokePress(.menu, guardWait: guardWait, file: file, line: line)
            try tvSmokeExpect(
                app, guardWait: guardWait, file: file, line: line, step: "Back completes its page and focus handoff"
            ) {
                tvSmokeIsPlaybackSurface($0)
                    || (!Self.tvSmokeSettingsIdentifiers($0).isEmpty
                        && Self.tvSmokeSettingsIdentifiers($0) != previousPage
                        && !Self.tvSmokeFocusSignatures($0).isEmpty && Self.tvSmokeFocusSignatures($0) != previousFocus)
            }
        }
        try tvSmokeFail("Back returns to playback", file: file, line: line)
    }

    @MainActor
    func tvSmokeSelectPlaybackOption(
        _ setting: String, option: String, app: XCUIApplication, guardWait: TestWait.HangGuard,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try tvSmokeSelect("settings.playback.\(setting).link", app: app, guardWait: guardWait, file: file, line: line)
        let optionID = "settings.playback.\(setting).\(option).button"
        try tvSmokeSelect(optionID, app: app, guardWait: guardWait, file: file, line: line)
        try tvSmokeExpect(app, guardWait: guardWait, file: file, line: line, step: "playback option saved: \(setting)")
        {
            Self.tvSmokeIsSelected($0.nodes[optionID])
        }
        try tvSmokePress(.menu, guardWait: guardWait, file: file, line: line)
        try tvSmokeExpect(
            app, guardWait: guardWait, file: file, line: line, step: "choice Back returns to playback settings"
        ) {
            $0.nodes["settings.playback.\(setting).link"] != nil && $0.nodes[optionID] == nil
        }
    }

    @MainActor
    func tvSmokeEnterPIN(
        digit: Int, app: XCUIApplication, guardWait: TestWait.HangGuard, file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try tvSmokeFocus("pinEntry.digit.\(digit).button", app: app, guardWait: guardWait, file: file, line: line)
        for _ in 0..<6 { try tvSmokePress(.select, guardWait: guardWait, file: file, line: line) }
    }

    @MainActor
    func tvSmokeConfirmFilterSetup(
        _ app: XCUIApplication, guardWait: TestWait.HangGuard, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        // ui-label-lookup: SwiftUI's empty-filter alert has no accessibility identifiers.
        let alertTitles = ["Can't Switch to Filtered Playback", "无法切换到筛选播放"]
        // ui-label-lookup: The native alert's Set Up Filters action has no accessibility identifier.
        let actionLabels = ["Set Up Filters", "去配置"]
        try tvSmokeExpect(app, guardWait: guardWait, file: file, line: line, step: "empty-filter alert appears") {
            $0.allNodes.contains { $0.elementType == .alert && alertTitles.contains($0.label) }
        }
        for _ in 0..<4 {
            var observation: Observation?
            try tvSmokeExpect(app, guardWait: guardWait, file: file, line: line, step: "empty-filter alert focus") {
                guard $0.allNodes.contains(where: { $0.elementType == .button && actionLabels.contains($0.label) }),
                    $0.allNodes.contains(where: { $0.hasFocus })
                else { return false }
                observation = $0
                return true
            }
            guard let current = observation,
                let target = current.allNodes.first(where: {
                    $0.elementType == .button && actionLabels.contains($0.label)
                }),
                let focused = current.allNodes.first(where: { $0.hasFocus })
            else { try tvSmokeFail("empty-filter alert focus", file: file, line: line) }
            if current.allNodes.contains(where: { $0.hasFocus && actionLabels.contains($0.label) }) { break }
            let dx = target.frame.midX - focused.frame.midX
            let dy = target.frame.midY - focused.frame.midY
            try tvSmokePress(
                abs(dy) > target.frame.height / 2 ? (dy > 0 ? .down : .up) : (dx > 0 ? .right : .left),
                guardWait: guardWait, file: file, line: line)
            try tvSmokeExpect(app, guardWait: guardWait, file: file, line: line, step: "empty-filter alert focus moves")
            {
                $0.allNodes.contains { $0.hasFocus && $0.label != focused.label }
            }
        }
        try tvSmokeExpect(app, guardWait: guardWait, file: file, line: line, step: "Set Up Filters has focus") {
            $0.allNodes.contains { $0.hasFocus && actionLabels.contains($0.label) }
        }
        try tvSmokePress(.select, guardWait: guardWait, file: file, line: line)
        try tvSmokeExpect(app, guardWait: guardWait, file: file, line: line, step: "real mode path opens filter editor")
        {
            $0.nodes["filter.editor.done.button"] != nil
        }
    }

    @MainActor
    func tvSmokeExpectFixtureBList(
        _ prefix: String, target: String, app: XCUIApplication, guardWait: TestWait.HangGuard,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try tvSmokeExpect(
            app, guardWait: guardWait, file: file, line: line, step: "B list has no A entries or stale selections"
        ) {
            let cards = $0.nodes.filter { $0.key.hasPrefix(prefix) }
            return cards[prefix + target + ".button"] != nil
                && !cards.contains { $0.key.contains("-a-") || Self.tvSmokeIsSelected($0.value) }
        }
    }

    static func tvSmokeHasFocusedDescendant(_ node: XCUIElementSnapshot) -> Bool {
        node.hasFocus || node.children.contains(where: tvSmokeHasFocusedDescendant)
    }

    @MainActor
    func tvSmokeNextPath(
        _ app: XCUIApplication, guardWait: TestWait.HangGuard, since startedAt: TimeInterval,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try tvSmokeReturnToPlayback(app, guardWait: guardWait, file: file, line: line)
        _ = try tvSmokeSwitchPhase("next-loop", guardWait: guardWait, startedAt: startedAt)
    }

    @MainActor
    func tvSmokeSwitchPhase(
        _ phase: String, guardWait: TestWait.HangGuard, startedAt: TimeInterval? = nil,
        didPressNext: Bool = false
    ) throws -> TimeInterval {
        let now = ProcessInfo.processInfo.systemUptime
        let write: Result<Void, Error>? = guardWait.transaction().query {
            Result {
                guard let directory = StrictE2EVisualEvidence.directory() else {
                    throw FlowError.failedStep("switch timing directory")
                }
                let path = directory.appendingPathComponent("smoke-tv-server-switch-timing.json")
                var fields =
                    startedAt == nil
                    ? (try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any] ?? [:]) : [:]
                let start = startedAt ?? fields["started_uptime_seconds"] as? TimeInterval ?? now
                let elapsed = now - start
                if startedAt != nil {
                    fields = [
                        "schema_version": 1, "started_uptime_seconds": start,
                        "next_loop_entered_seconds": elapsed, "next_presses": 0
                    ]
                }
                if didPressNext { fields["next_presses"] = (fields["next_presses"] as? Int ?? 0) + 1 }
                if phase == "filter-lists" { fields["direct_switch_seconds"] = elapsed }
                fields["phase"] = phase
                fields["elapsed_seconds"] = elapsed
                fields["remaining_guard_seconds"] = guardWait.remainingSeconds
                try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]).write(
                    to: path, options: .atomic)
            }
        }
        guard let write else { throw FlowError.failedStep("switch timing guard") }
        try write.get()
        return now
    }

    @MainActor
    func tvSmokeFail(_ step: String, file: StaticString, line: UInt) throws -> Never {
        XCTFail("Smoke flow: \(step).", file: file, line: line)
        throw FlowError.failedStep(step)
    }

    typealias SwitchFixtureMetadata = (photoCount: Int, uniqueExifLabels: Set<String>)

    @MainActor
    func tvSmokeSwitchFixtureMetadata(
        guardWait: TestWait.HangGuard, file: StaticString = #filePath, line: UInt = #line
    ) throws -> SwitchFixtureMetadata {
        let result: Result<SwitchFixtureMetadata, Error>? = guardWait.transaction().query {
            Result {
                guard let directory = StrictE2EVisualEvidence.directory() else {
                    throw FlowError.failedStep("fixture directory")
                }
                let fixtures = try ["fixture-manifest.json", "fixture-manifest-b.json"].map { name in
                    guard
                        let manifest = try JSONSerialization.jsonObject(
                            with: Data(contentsOf: directory.appendingPathComponent(name))) as? [String: Any]
                    else { throw FlowError.failedStep("fixture manifest") }
                    return manifest
                }
                guard fixtures[0]["fixture_set"] as? String == "a", fixtures[1]["fixture_set"] as? String == "b",
                    let photos = fixtures[1]["assets"] as? [[String: Any]], !photos.isEmpty
                else { throw FlowError.failedStep("fixture population") }
                let labels: ([String: Any]) -> Set<String> = { manifest in
                    Set(
                        (manifest["assets"] as? [[String: Any]] ?? []).compactMap { asset in
                            guard let exif = asset["exifInfo"] as? [String: Any],
                                let make = exif["make"] as? String, let model = exif["model"] as? String
                            else { return nil }
                            return "\(make) \(model)"
                        })
                }
                let uniqueLabels = labels(fixtures[1]).subtracting(labels(fixtures[0]))
                guard !uniqueLabels.isEmpty else { throw FlowError.failedStep("fixture identity") }
                return (photos.count, uniqueLabels)
            }
        }
        guard let result else { try tvSmokeFail("public switch fixture metadata is required", file: file, line: line) }
        do { return try result.get() } catch {
            try tvSmokeFail("public switch fixture metadata is required", file: file, line: line)
        }
    }

    func tvSmokeIsPlaybackSurface(_ current: Observation) -> Bool {
        let blockers = ["settings.", "firstboot.", "pinEntry.", "filter.editor.", "filterSummary.", "mode."]
        return (current.nodes[playPauseID]?.isEnabled == true || current.nodes[wakeID] != nil)
            && !current.nodes.keys.contains { id in blockers.contains { id.hasPrefix($0) } }
    }

    static func tvSmokeSettingsIdentifiers(_ current: Observation) -> Set<String> {
        Set(current.nodes.keys.filter { $0.hasPrefix("settings.") || $0.hasPrefix("firstboot.") })
    }

    static func tvSmokeFocusSignatures(_ current: Observation) -> Set<String> {
        Set(current.allNodes.filter(\.hasFocus).map { $0.identifier + ":" + $0.label })
    }

    static func tvSmokeValue(_ node: XCUIElementSnapshot?) -> String {
        node.map { String(describing: $0.value ?? "") } ?? ""
    }

    static func tvSmokeIndex(_ node: XCUIElementSnapshot?) -> Int? {
        guard let number = tvSmokeValue(node).split(separator: "/").first.flatMap({ Int($0) }), number > 0 else {
            return nil
        }
        return number
    }

    static func tvSmokeIsSettledScene(_ observation: Observation) -> Bool {
        let fields = SharedSceneEvidenceManifest.parseKeyValueFields(
            observation.nodes["slideshow.scenePresentation.contract.summary"]?.label ?? "")
        return fields["phase"] == "stablePhoto" && fields["layerRoles"] == "stable"
    }

    static func tvSmokeSceneReferences(_ observation: Observation) -> String? {
        let fields = SharedSceneEvidenceManifest.parseKeyValueFields(
            observation.nodes["slideshow.smartfill.currentManifest.flag"]?.label ?? "")
        guard let references = fields["ledgerSceneAssets"], !references.isEmpty, references != "none" else {
            return nil
        }
        return references
    }

    static func tvSmokePublicExifIndices(_ observation: Observation) -> [Int] {
        // Only fixed public-fixture model numbers enter switch diagnostics, never arbitrary EXIF text.
        (1...8).filter { index in
            observation.allNodes.contains { $0.label == "immichSlides Synthetic Fixture \(index)" }
        }
    }

    static func tvSmokeIsSelected(_ node: XCUIElementSnapshot?) -> Bool {
        guard let node else { return false }
        return node.isSelected
            || ["Selected", "已选中", "已選取", "已選中", "Seleccionado", "選択済み"].contains {
                tvSmokeValue(node).hasPrefix($0) || tvSmokeValue(node).hasPrefix("focused | \($0)")
            }
    }

    static func tvSmokeIsSolo(_ node: XCUIElementSnapshot?) -> Bool {
        ["Solo", "单人模式", "單人模式", "ソロモード"].contains { tvSmokeValue(node).contains($0) }
    }
}
#endif
