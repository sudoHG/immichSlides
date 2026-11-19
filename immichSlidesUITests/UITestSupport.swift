import ImageIO
import UIKit
import XCTest

/// Only public fixture runners enable this recorder. Its spool is private until the host validates it.
enum FirstFailureEvidence {
    private static let maximumReceiptBytes = 8192
    private static let maximumImageBytes = 1_048_576
    private static let maximumSnapshotNodes = 4096
    private static let thumbnailSides = [1536, 1024, 768, 512]
    private static let lock = NSLock()
    private static var recorded = Set<String>()

    static func preservingThrownFailure<T>(_ test: XCTestCase, _ operation: () throws -> T) rethrows -> T {
        do {
            return try operation()
        } catch {
            if !(error is XCTSkip) {
                record(
                    test,
                    issue: XCTIssue(
                        type: .thrownError, compactDescription: String(describing: error), associatedError: error))
            }
            // XCTest must still receive the exact original error after the caller's teardown.
            throw error
        }
    }

    static func record(_ test: XCTestCase, issue: XCTIssue) {
        guard issue.isFailure, FirstFailureContext.isEnabled else { return }
        let environment = ProcessInfo.processInfo.environment
        let server = environment["STRICT_E2E_INPUT_SERVER_URL"] ?? environment["IMMICH_TEST_SERVER_URL"] ?? ""
        let key = environment["STRICT_E2E_INPUT_PUBLIC_KEY"] ?? environment["IMMICH_TEST_API_KEY"] ?? ""
        guard let url = URL(string: server), url.scheme == "http", ["127.0.0.1", "localhost"].contains(url.host ?? ""),
            url.path == "/api", ["immichslides-public-e2e-key", "immichslides-public-e2e-wrong-key"].contains(key)
        else { return }
        guard let root = environment["STRICT_E2E_FIRST_FAILURE_DIR"],
            let testsData = environment["STRICT_E2E_FIRST_FAILURE_TESTS"]?.data(using: .utf8),
            let tests = try? JSONDecoder().decode([String: Int].self, from: testsData),
            let elementsData = environment["STRICT_E2E_FIRST_FAILURE_ELEMENTS"]?.data(using: .utf8),
            let elements = try? JSONDecoder().decode([String].self, from: elementsData)
        else { return }
        let method =
            test.name.split(separator: " ").last.map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "-[]()"))
            .split(separator: ".").last.map(String.init) ?? ""
        let testKey = "\(String(describing: type(of: test)))/\(method)"
        guard let index = tests[testKey], index >= 0 else { return }
        lock.lock()
        let isFirst = recorded.insert(testKey).inserted
        lock.unlock()
        guard isFirst else { return }
        let failedAt = ProcessInfo.processInfo.systemUptime
        let context = FirstFailureContext.snapshot()
        let vocabulary = Set(elements)
        var receipt: [String: Any] = [
            "schema_version": 1, "source": "xctest", "step": context.step,
            "element": vocabulary.contains(context.element) ? context.element : "unknown",
            "action": context.timeline.action, "timing": context.timeline.timing(at: failedAt),
            "state": [
                "app": "unknown", "surface": "unknown", "observation": "unavailable",
                "control_bar": "unknown", "focus": "unknown", "history_count": NSNull(),
                "autoplay": "unknown", "orientation": "unknown", "scene_status": "unknown", "query_error_code": NSNull()
            ],
            "validator": NSNull(), "screenshot": imageStatus("unavailable")
        ]
        let directory = URL(fileURLWithPath: root, isDirectory: true)
        // Persist the safe core before another XCTest query can fail or the runner can be stopped.
        do {
            let initial = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
            guard initial.count <= maximumReceiptBytes else { return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try initial.write(to: directory.appendingPathComponent("\(index).json"), options: .atomic)
        } catch { return }
        var png: Data?
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                let shouldContinueAfterFailure = test.continueAfterFailure
                test.continueAfterFailure = true
                defer { test.continueAfterFailure = shouldContinueAfterFailure }
                png = XCTExpectFailure("Optional first-failure evidence is unavailable.", options: .nonStrict()) {
                    capture(receipt: &receipt, failedAt: failedAt, vocabulary: vocabulary)
                }
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]),
            data.count <= maximumReceiptBytes
        else { return }
        do {
            if let png { try png.write(to: directory.appendingPathComponent("\(index).png"), options: .atomic) }
            try data.write(to: directory.appendingPathComponent("\(index).json"), options: .atomic)
        } catch {
            // Evidence availability must not replace the original XCTest failure.
        }
    }

    private static func imageStatus(_ status: String) -> [String: Any] {
        ["status": status, "width": NSNull(), "height": NSNull(), "bytes": NSNull()]
    }

    @MainActor
    private static func capture(receipt: inout [String: Any], failedAt: TimeInterval, vocabulary: Set<String>) -> Data?
    {
        let app = XCUIApplication()
        var state = receipt["state"] as! [String: Any]
        var timing = receipt["timing"] as! [String: Any]
        defer { receipt["state"] = state; receipt["timing"] = timing }
        switch app.state {
        case .runningForeground: state["app"] = "running-foreground"
        case .notRunning: state["app"] = "not-running"
        case .runningBackground, .runningBackgroundSuspended: state["app"] = "background"
        default: break
        }
        guard state["app"] as? String == "running-foreground" else { return nil }
        let window = app.windows.firstMatch
        let snapshot: XCUIElementSnapshot
        do { snapshot = try window.snapshot() } catch {
            let code = (error as NSError).code
            if (-2_147_483_648...2_147_483_647).contains(code) { state["query_error_code"] = code }
            return nil
        }
        state["observation"] = "failure-snapshot"
        let observedAt = ProcessInfo.processInfo.systemUptime
        var nodes: [String: XCUIElementSnapshot] = [:]
        var pending = [snapshot]
        var count = 0
        var hasPrivateSurface = false
        while count < maximumSnapshotNodes, let node = pending.popLast() {
            count += 1
            let identifier = node.identifier
            if node.elementType == .secureTextField || identifier.hasPrefix("firstboot.")
                || identifier.hasPrefix("settings.server") || identifier.hasPrefix("server.")
                || identifier.hasPrefix("pinEntry.") || identifier.hasPrefix("settings.pin.")
            {
                hasPrivateSurface = true
            }
            if !identifier.isEmpty { nodes[identifier] = node }
            if node.hasFocus, vocabulary.contains(identifier) { state["focus"] = identifier }
            pending.append(contentsOf: node.children)
        }
        let render = SharedSceneEvidenceManifest.parseKeyValueFields(
            nodes["slideshow.scenePresentation.contract.summary"]?.label ?? "")
        let runtime = SharedSceneEvidenceManifest.parseKeyValueFields(
            nodes["slideshow.smartfill.currentManifest.flag"]?.label ?? "")
        if let history = Int(render["historyCount"] ?? ""), (0...2_147_483_647).contains(history) {
            state["history_count"] = history
        }
        if let visible = runtime["controlBarVisible"], ["true", "false"].contains(visible) {
            state["control_bar"] = visible == "true" ? "visible" : "hidden"
        }
        if let value = nodes["settings.playback.autoPlay.toggle"]?.value {
            let setting = String(describing: value)
            if ["1", "0"].contains(setting) { state["autoplay"] = setting == "1" ? "on" : "off" }
        }
        #if os(iOS)
        switch XCUIDevice.shared.orientation {
        case .portrait, .portraitUpsideDown: state["orientation"] = "portrait"
        case .landscapeLeft, .landscapeRight: state["orientation"] = "landscape"
        default: break
        }
        #else
        state["orientation"] = "not_applicable"
        #endif
        if nodes["settings.cache.clearDisk.button"] != nil {
            state["surface"] = "cache"
        } else if nodes.keys.contains(where: { $0.hasPrefix("settings.playback.") }) {
            state["surface"] = "playback-settings"
        } else if nodes["slideshow.control.playPause.button"] != nil || nodes["slideshow.hiddenWakeReceiver"] != nil
            || nodes["slideshow.currentAssetId.flag"] != nil
        {
            state["surface"] = "playback"
        } else if nodes["mode.random.button"] != nil {
            state["surface"] = "mode"
        }
        let element = receipt["element"] as? String ?? "unknown"
        let focus = state["focus"] as? String ?? "unknown"
        guard !hasPrivateSurface, pending.isEmpty, state["surface"] as? String != "unknown",
            !element.hasPrefix("firstboot."), !focus.hasPrefix("firstboot.")
        else {
            receipt["screenshot"] = imageStatus("withheld-privacy")
            return nil
        }
        guard ProcessInfo.processInfo.environment["STRICT_E2E_FIRST_FAILURE_SCREENSHOT"] == "1" else { return nil }
        timing["state_age_seconds"] = ProcessInfo.processInfo.systemUptime - observedAt
        timing["capture_request_seconds"] = ProcessInfo.processInfo.systemUptime - failedAt
        let screen = XCUIScreen.main.screenshot().image
        timing["capture_return_seconds"] = ProcessInfo.processInfo.systemUptime - failedAt
        let frame = snapshot.frame
        guard !frame.isEmpty, !frame.isInfinite, !frame.isNull,
            CGRect(origin: .zero, size: screen.size).contains(frame)
        else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = screen.scale
        let screenshot = UIGraphicsImageRenderer(size: frame.size, format: format).pngData { _ in
            screen.draw(at: CGPoint(x: -frame.minX, y: -frame.minY))
        }
        var didExceedSizeLimit = false
        if let source = CGImageSourceCreateWithData(screenshot as CFData, nil) {
            for side in thumbnailSides {
                guard
                    let image = CGImageSourceCreateThumbnailAtIndex(
                        source, 0,
                        [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: side,
                            kCGImageSourceCreateThumbnailWithTransform: true
                        ] as CFDictionary), let png = UIImage(cgImage: image).pngData()
                else { continue }
                guard png.count <= maximumImageBytes else {
                    didExceedSizeLimit = true
                    continue
                }
                state["scene_status"] = StrictE2EPhotoIdentity.classify(png: png).status.rawValue
                receipt["screenshot"] = [
                    "status": "captured", "width": image.width, "height": image.height, "bytes": png.count
                ]
                return png
            }
        }
        receipt["screenshot"] = imageStatus(didExceedSizeLimit ? "size-limit" : "unavailable")
        return nil
    }
}

extension XCUIScreenshotProviding {
    func screenshotForFailureEvidence() -> XCUIScreenshot {
        FirstFailureContext.mark(
            "capture-frame", element: self is XCUIApplication || self is XCUIScreen ? "app-window" : "unknown")
        return screenshot()
    }
}

extension XCUIElement {
    #if os(iOS)
    func tapForFailureEvidence() {
        FirstFailureContext.mark("select", element: FirstFailureContext.snapshot().element)
        FirstFailureContext.action("tap") { tap() }
    }
    #endif

    func typeForFailureEvidence(_ text: String) {
        FirstFailureContext.mark("select", element: FirstFailureContext.snapshot().element)
        FirstFailureContext.action("type") { typeText(text) }
    }

    #if os(iOS)
    func swipeUpForFailureEvidence() { FirstFailureContext.action("unknown") { swipeUp() } }
    func swipeDownForFailureEvidence() { FirstFailureContext.action("unknown") { swipeDown() } }
    #endif

    func waitForPublicElement(_ identifier: String, timeout: TimeInterval) -> Bool {
        FirstFailureContext.mark("query-element", element: identifier)
        FirstFailureContext.beginWait(seconds: timeout)
        defer { FirstFailureContext.endWait() }
        return waitForExistence(timeout: timeout)
    }

    func waitForFailureEvidence(timeout: TimeInterval) -> Bool {
        waitForPublicElement("unknown", timeout: timeout)
    }
}

extension XCUIApplication {
    func launchForFailureEvidence() {
        FirstFailureContext.mark("launch-app", element: "app-window")
        FirstFailureContext.action("launch") { launch() }
    }

    func activateForFailureEvidence() {
        FirstFailureContext.action("activate") { activate() }
    }

    func terminateForFailureEvidence() {
        FirstFailureContext.action("terminate") { terminate() }
    }
}

#if os(iOS)
extension XCUICoordinate {
    func tapForFailureEvidence() {
        FirstFailureContext.mark("select", element: FirstFailureContext.snapshot().element)
        FirstFailureContext.action("tap") { tap() }
    }
}

enum FirstFailureOrientation {
    static func set(_ orientation: UIDeviceOrientation) {
        FirstFailureContext.mark("rotate", element: "app-window")
        FirstFailureContext.action("rotate") { XCUIDevice.shared.orientation = orientation }
    }
}
#endif

#if os(tvOS)
enum FirstFailureRemote {
    static func press(_ button: XCUIRemote.Button, forDuration duration: TimeInterval? = nil) {
        let action: String
        switch button {
        case .select: action = "select"
        case .up: action = "up"
        case .down: action = "down"
        case .left: action = "left"
        case .right: action = "right"
        case .menu: action = "back"
        case .home: action = "home"
        case .playPause: action = "play-pause"
        default: action = "unknown"
        }
        FirstFailureContext.mark(
            action == "select" ? "select" : "focus", element: FirstFailureContext.snapshot().element)
        FirstFailureContext.action(action) {
            if let duration {
                XCUIRemote.shared.press(button, forDuration: duration)
            } else {
                XCUIRemote.shared.press(button)
            }
        }
    }
}
#endif

extension XCUIApplication {
    // Keep evidence reads in one tree so auto-hidden controls cannot disappear between queries.
    func evidenceSnapshotsByIdentifier(
        onSnapshotFailure: ((Error) -> Void)? = nil,
        onRootSnapshot: ((XCUIElementSnapshot) -> Void)? = nil
    ) -> [String: XCUIElementSnapshot] {
        FirstFailureContext.mark("query-element", element: "app-window")
        let root: XCUIElementSnapshot
        do {
            root = try snapshot()
        } catch {
            onSnapshotFailure?(error)
            return [:]
        }
        onRootSnapshot?(root)
        var snapshots: [String: XCUIElementSnapshot] = [:]
        var pending: [XCUIElementSnapshot] = [root]
        while let node = pending.popLast() {
            if !node.identifier.isEmpty, snapshots[node.identifier] == nil {
                snapshots[node.identifier] = node
            }
            pending.append(contentsOf: node.children)
        }
        return snapshots
    }
}

#if os(tvOS)
extension XCUIApplication {
    func refreshTVOSSlideshowControlBar(timeout: TimeInterval) -> Bool {
        FirstFailureContext.mark("reveal-controls", element: "slideshow.control.playPause.button")
        FirstFailureContext.beginWait(seconds: timeout)
        defer {
            FirstFailureContext.endWait()
            FirstFailureContext.mark("reveal-controls", element: "slideshow.control.playPause.button")
        }
        let deadline = Date().addingTimeInterval(timeout)
        let controlIdentifiers = ["settings", "previous", "playPause", "next"].map {
            "slideshow.control.\($0).button"
        }
        func waitForFocus(_ condition: ([String: XCUIElementSnapshot]) -> Bool) -> Bool {
            let movementDeadline = min(
                deadline, Date().addingTimeInterval(UITestSupportWaitTiming.readbackTimeoutSeconds))
            while Date() < movementDeadline {
                let snapshots = evidenceSnapshotsByIdentifier()
                if condition(snapshots) { return Date() < movementDeadline }
                RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusSettle))
            }
            return false
        }
        while Date() < deadline {
            let snapshots = evidenceSnapshotsByIdentifier()
            if let focusedIdentifier = controlIdentifiers.first(where: { snapshots[$0]?.hasFocus == true }) {
                guard Date() < deadline else { return false }
                // Moving focus refreshes auto-hide; round trips restore the last attempt's enabled control. Callers verify focus.
                let direction: XCUIRemote.Button =
                    focusedIdentifier == "slideshow.control.next.button" ? .left : .right
                FirstFailureRemote.press(direction)
                // Auto-hide can consume a focus move as a wake; retry from a fresh snapshot in the same budget.
                guard
                    waitForFocus({ observation in
                        controlIdentifiers.contains {
                            $0 != focusedIdentifier && observation[$0]?.hasFocus == true
                        }
                    })
                else { continue }
                // Previous can retain focus just after Select disables it at the history boundary.
                let current = evidenceSnapshotsByIdentifier()
                if current[focusedIdentifier]?.isEnabled == false {
                    if waitForFocus({ $0["slideshow.control.playPause.button"]?.hasFocus == true }) { return true }
                    continue
                }
                FirstFailureRemote.press(direction == .left ? .right : .left)
                if waitForFocus({ observation in
                    if focusedIdentifier == "slideshow.control.previous.button",
                        observation[focusedIdentifier]?.isEnabled == false
                    {
                        return observation["slideshow.control.playPause.button"]?.hasFocus == true
                    }
                    return observation[focusedIdentifier]?.hasFocus == true
                }) {
                    return true
                }
                continue
            }
            if snapshots["slideshow.hiddenWakeReceiver"]?.hasFocus == true {
                guard Date() < deadline else { return false }
                FirstFailureRemote.press(.up)
                if waitForFocus({ $0["slideshow.control.playPause.button"] != nil }) { return true }
                continue
            }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.focusSettle))
        }
        return false
    }
}
#endif

#if os(iOS)
@MainActor
struct IOSFirstBootNavigation {
    let app: XCUIApplication

    func focusTextField(
        _ field: XCUIElement, identifier: String, file: StaticString? = nil, line: UInt? = nil
    ) -> XCUIElementSnapshot? {
        field.tapForFailureEvidence()
        // Tap delivery can be slow; focus arrival has its own window after the sole tap returns.
        let timeout = UITestSupportWaitTiming.elementAppearanceTimeoutSeconds
        let started = ProcessInfo.processInfo.systemUptime
        let readiness = TestWait.hangGuard(
            timeoutSeconds: UITestSupportWaitTiming.elementAppearanceTimeoutSeconds)
        FirstFailureContext.mark("focus", element: identifier)
        FirstFailureContext.beginWait(seconds: timeout)
        defer {
            FirstFailureContext.endWait()
            print(
                "First-boot focus readiness: element=\(identifier) elapsedSeconds=\(ProcessInfo.processInfo.systemUptime - started) timeoutSeconds=\(timeout)"
            )
        }
        // XCTest's keyboard focus also supports a connected hardware keyboard; UI hasFocus does not.
        let focusedField = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ AND hasKeyboardFocus == true", identifier)
        ).firstMatch
        var focusedSnapshot: XCUIElementSnapshot?
        // No guard action is issued: only queries admitted before expiry may return ready late.
        let isReady = readiness.transaction().until(pollIntervalSeconds: UITestSupportWaitTiming.identityPollSeconds) {
            guard let focused = try? focusedField.snapshot(), focused.isEnabled else { return false }
            focusedSnapshot = focused
            return true
        }
        if isReady { return focusedSnapshot }
        if let file, let line {
            XCTFail("First-boot input must have keyboard focus before typing.", file: file, line: line)
        } else {
            XCTFail("First-boot input must have keyboard focus before typing.")
        }
        return nil
    }

    enum ModeModalSource: String {
        case none
        case appAlert = "app-alert"
        case appSheet = "app-sheet"
        case appOtherWindow = "app-other-window"
        case springboardAlert = "springboard-alert"
        case springboardSheet = "springboard-sheet"
        case springboardOtherWindow = "springboard-other-window"
        case alertsQuery = "alerts-query"
    }

    final class ModeNavigationDiagnostics {
        enum Stage: String {
            case appWindows = "app-windows"
            case fastPath = "fast-path"
            case springboardWindows = "springboard-windows"
            case alertsQuery = "alerts-query"
            case complete
        }

        enum TapGuard: String {
            case notAttempted = "not-attempted"
            case modal, snapshot, deadline
            case alertCount = "alert-count"
            case liveCount = "live-count"
            case liveLabel = "live-label"
            case liveFrame = "live-frame"
            case notHittable = "not-hittable"
            case issued
        }

        let targetIdentifier: String
        var observations = 0
        var fastPathObservations = 0
        var earlyAlertHits = 0
        var terminalAlertHits = 0
        var lastObsSeconds: TimeInterval = .zero
        var maxObsSeconds: TimeInterval = .zero
        var observationSeconds: [TimeInterval] = []
        var nativeTapSeconds: [TimeInterval] = []
        var targetMatches: Int?
        var targetSelected: Bool?
        var descendantSelected: Bool?
        var continueMatches: Int?
        var continueEnabled: Bool?
        var continueHittable: Bool?
        var targetHittable: Bool?
        var modalObstacle: Bool?
        var modalSource = ModeModalSource.none
        var stage = Stage.appWindows
        var tapGuard = TapGuard.notAttempted
        var tapMatches: Int?

        init(targetIdentifier: String) { self.targetIdentifier = targetIdentifier }

        func beginModeDiagnosticObservation() {
            observations = min(4096, observations + 1)
            targetMatches = nil
            targetSelected = nil
            descendantSelected = nil
            continueMatches = nil
            continueEnabled = nil
            continueHittable = nil
            targetHittable = nil
            modalObstacle = nil
            modalSource = .none
            stage = .appWindows
            tapGuard = .notAttempted
            tapMatches = nil
        }

        func finishModeDiagnosticObservation(since start: TimeInterval) {
            lastObsSeconds = min(86_400, max(.zero, ProcessInfo.processInfo.systemUptime - start))
            maxObsSeconds = max(maxObsSeconds, lastObsSeconds)
            if observationSeconds.count < 4096 { observationSeconds.append(lastObsSeconds) }
        }

        func captureModeDiagnosticSnapshot(_ observation: Observation) {
            let targets = observation.nodes.filter { $0.identifier == targetIdentifier && $0.elementType == .button }
            let continues = observation.nodes.filter {
                $0.identifier == "mode.continue.button" && $0.elementType == .button
            }
            targetMatches = min(4096, targets.count)
            continueMatches = min(4096, continues.count)
            if targets.count == 1 {
                targetSelected = targets[0].isSelected
                var pending = targets[0].children
                var selected = false
                while let node = pending.popLast() {
                    selected = selected || node.isSelected
                    pending.append(contentsOf: node.children)
                }
                descendantSelected = selected
            }
            continueEnabled = continues.count == 1 ? continues[0].isEnabled : nil
            modalObstacle = observation.hasModalObstacle
            modalSource = observation.modalSource
        }

        func captureModeDiagnosticHittability(identifier: String, value: Bool) {
            if identifier == targetIdentifier { targetHittable = value }
            if identifier == "mode.continue.button" { continueHittable = value }
        }

        var modeDiagnosticMessage: String {
            func modeDiagnosticBoolean(_ value: Bool?) -> String { value.map(String.init) ?? "unknown" }
            func modeDiagnosticCount(_ value: Int?) -> String { value.map(String.init) ?? "unknown" }
            let last = String(format: "%.3f", lastObsSeconds)
            let maximum = String(format: "%.3f", maxObsSeconds)
            let durations = observationSeconds.map { String(format: "%.3f", $0) }.joined(separator: ",")
            let taps = nativeTapSeconds.map { String(format: "%.3f", $0) }.joined(separator: ",")
            return "observations=\(observations), fastPathObservations=\(fastPathObservations), "
                + "earlyAlertHits=\(earlyAlertHits), terminalAlertHits=\(terminalAlertHits), "
                + "observationSeconds=[\(durations)], "
                + "nativeTapSeconds=[\(taps)], "
                + "lastObsSeconds=\(last), maxObsSeconds=\(maximum), targetMatches=\(modeDiagnosticCount(targetMatches)), "
                + "targetSelected=\(modeDiagnosticBoolean(targetSelected)), descendantSelected=\(modeDiagnosticBoolean(descendantSelected)), "
                + "continueMatches=\(modeDiagnosticCount(continueMatches)), continueEnabled=\(modeDiagnosticBoolean(continueEnabled)), "
                + "continueHittable=\(modeDiagnosticBoolean(continueHittable)), targetHittable=\(modeDiagnosticBoolean(targetHittable)), "
                + "modalObstacle=\(modeDiagnosticBoolean(modalObstacle)), modalSource=\(modalSource.rawValue), "
                + "observationStage=\(stage.rawValue), tapGuard=\(tapGuard.rawValue), tapMatches=\(modeDiagnosticCount(tapMatches))"
        }
    }

    struct Observation {
        let window: XCUIElementSnapshot
        let windowElement: XCUIElement
        let windowIndex: Int
        let nodes: [XCUIElementSnapshot]
        let decline: XCUIElementSnapshot?
        let hasPasswordPrompt: Bool
        let hasPromptClue: Bool
        let hasModalObstacle: Bool
        let modalSource: ModeModalSource
        let promptHost: XCUIApplication
        let promptFrame: CGRect
        let isPromptAlert: Bool
        let promptContainer: XCUIElement
        let promptSource: String

        func button(_ identifier: String) -> XCUIElementSnapshot? {
            let matches = nodes.filter { $0.identifier == identifier && $0.elementType == .button }
            return matches.count == 1 ? matches[0] : nil
        }

        func isModeCardSelected(_ identifier: String) -> Bool {
            guard ["mode.random.button", "mode.filtered.button"].contains(identifier) else { return false }
            return button(identifier)?.isSelected == true
        }

        var isModePage: Bool { nodes.contains { $0.identifier.hasPrefix("mode.") } }
        func hasDestination(_ identifier: String) -> Bool {
            !identifier.isEmpty && nodes.contains { $0.identifier == identifier }
        }
    }

    func observe(
        modeIdentifier: String? = nil, destinationIdentifier: String? = nil,
        diagnostics: ModeNavigationDiagnostics? = nil,
        transaction: TestWait.HangGuard.Transaction? = nil
    ) throws -> Observation {
        let ownWindows = try windowObservations(host: app, transaction: transaction)
        let own =
            ownWindows.first(where: { window in
                window.isModePage || destinationIdentifier.map { window.hasDestination($0) } == true
            }) ?? ownWindows[0]
        diagnostics?.captureModeDiagnosticSnapshot(combine(own, prompts: [], windows: ownWindows))
        let ownPrompts = ownWindows.filter(\.hasPasswordPrompt)
        if !ownPrompts.isEmpty { return combine(own, prompts: ownPrompts, windows: ownWindows) }
        if let modeIdentifier, own.isModePage,
            !ownWindows.contains(where: { $0.hasPromptClue || $0.hasModalObstacle }),
            modeControlsAreHittable(
                own, modeIdentifier: modeIdentifier, diagnostics: diagnostics, transaction: transaction)
        {
            diagnostics?.fastPathObservations = min(4096, (diagnostics?.fastPathObservations ?? 0) + 1)
            return combine(own, prompts: [], windows: ownWindows)
        }
        var windows = ownWindows
        // Runner idiom limits this shortcut to the proven iPad alert host; iPhone keeps SpringBoard first.
        if UIDevice.current.userInterfaceIdiom == .pad {
            diagnostics?.stage = .alertsQuery
            if let modal = try appAlertObservation(transaction: transaction) {
                windows.append(modal)
                if modal.hasPasswordPrompt, modal.decline != nil {
                    diagnostics?.earlyAlertHits = min(4096, (diagnostics?.earlyAlertHits ?? 0) + 1)
                    return combine(own, prompts: [modal], windows: windows)
                }
            }
        }
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        diagnostics?.stage = .springboardWindows
        let systemWindows = try windowObservations(host: system, isSpringboard: true, transaction: transaction)
        windows.append(contentsOf: systemWindows)
        let systemPrompts = systemWindows.filter(\.hasPasswordPrompt)
        diagnostics?.captureModeDiagnosticSnapshot(combine(own, prompts: [], windows: windows))
        if !systemPrompts.isEmpty { return combine(own, prompts: systemPrompts, windows: windows) }
        // A late remote alert can become queryable only after the system-window observations.
        diagnostics?.stage = .alertsQuery
        if let modal = try appAlertObservation(transaction: transaction) {
            windows.append(modal)
            if modal.hasPasswordPrompt, modal.decline != nil {
                diagnostics?.terminalAlertHits = min(4096, (diagnostics?.terminalAlertHits ?? 0) + 1)
            }
            return combine(own, prompts: modal.hasPasswordPrompt ? [modal] : [], windows: windows)
        }
        return combine(own, prompts: [], windows: windows)
    }

    private func navigationQuery<Value>(
        _ transaction: TestWait.HangGuard.Transaction?, _ operation: () throws -> Value
    ) throws -> Value {
        guard let transaction else { return try operation() }
        guard let captured = transaction.query({ Result(catching: operation) }) else {
            throw NSError(domain: "IOSFirstBootNavigation", code: 3)
        }
        return try captured.get()
    }

    private func appAlertObservation(transaction: TestWait.HangGuard.Transaction? = nil) throws -> Observation? {
        let alerts = try navigationQuery(transaction) { app.alerts.allElementsBoundByIndex }
        guard alerts.count <= 1 else { throw NSError(domain: "IOSFirstBootNavigation", code: 2) }
        guard let alert = alerts.first else { return nil }
        return observation(
            window: try navigationQuery(transaction) { try alert.snapshot() }, element: alert, host: app,
            windowIndex: .zero, isPromptAlert: true)
    }

    private func combine(_ own: Observation, prompts: [Observation], windows: [Observation]) -> Observation {
        let prompt = prompts.count == 1 ? prompts[0] : nil
        return Observation(
            window: own.window, windowElement: own.windowElement, windowIndex: own.windowIndex, nodes: own.nodes,
            decline: prompt?.decline, hasPasswordPrompt: !prompts.isEmpty,
            hasPromptClue: windows.contains(where: \.hasPromptClue),
            hasModalObstacle: windows.contains(where: \.hasModalObstacle),
            modalSource: windows.first(where: \.hasModalObstacle)?.modalSource ?? .none,
            promptHost: prompt?.promptHost ?? app, promptFrame: prompt?.window.frame ?? .zero,
            isPromptAlert: prompt?.isPromptAlert ?? false,
            promptContainer: prompt?.promptContainer ?? own.windowElement,
            promptSource: prompt?.promptSource ?? (prompts.isEmpty ? "not-observed" : "ambiguous"))
    }

    private func modeControlsAreHittable(
        _ observation: Observation, modeIdentifier: String, diagnostics: ModeNavigationDiagnostics?,
        transaction: TestWait.HangGuard.Transaction? = nil
    ) -> Bool {
        diagnostics?.stage = .fastPath
        // A blocked mode surface still needs the complete remote credential-prompt search.
        for identifier in [modeIdentifier, "mode.continue.button"] {
            guard let button = observation.button(identifier), button.isEnabled, !button.frame.isEmpty,
                observation.window.frame.contains(button.frame)
            else { return false }
            // ui-label-lookup: Bind the live mode control to the same button in the captured window.
            let target = observation.windowElement.buttons.matching(
                NSPredicate(format: "identifier == %@ AND label == %@", button.identifier, button.label)
            ).firstMatch
            guard let isHittable = try? navigationQuery(transaction, { target.isHittable }) else { return false }
            diagnostics?.captureModeDiagnosticHittability(identifier: identifier, value: isHittable)
            guard isHittable else { return false }
        }
        return true
    }

    private func windowObservations(
        host: XCUIApplication, isSpringboard: Bool = false, transaction: TestWait.HangGuard.Transaction? = nil
    ) throws -> [Observation] {
        // App snapshots can omit the main window; keep each real window's title/action and tap index paired.
        let windows = try navigationQuery(transaction) { host.windows.allElementsBoundByIndex }
        guard !windows.isEmpty else { throw NSError(domain: "IOSFirstBootNavigation", code: 1) }
        return try windows.enumerated().map { index, window in
            observation(
                window: try navigationQuery(transaction) { try window.snapshot() }, element: window, host: host,
                windowIndex: index,
                isSpringboard: isSpringboard)
        }
    }

    private func observation(
        window: XCUIElementSnapshot, element: XCUIElement, host: XCUIApplication,
        windowIndex: Int, isPromptAlert: Bool = false, isSpringboard: Bool = false
    ) -> Observation {
        var pending = [window]
        var nodes: [XCUIElementSnapshot] = []
        while let node = pending.popLast() {
            nodes.append(node)
            pending.append(contentsOf: node.children)
        }
        // ui-label-lookup: The simulator-owned password prompt follows the system language.
        let titles = ["保存密码？", "Save Password?"]
        let hasTitle = nodes.contains {
            ($0.elementType == .staticText || $0.elementType == .sheet || $0.elementType == .alert)
                && (titles.contains($0.label) || titles.contains($0.identifier))
        }
        let hasOtherModal = nodes.contains { node in
            guard node.elementType == .alert || node.elementType == .sheet else { return false }
            var pending = [node]
            while let child = pending.popLast() {
                if titles.contains(child.label) || titles.contains(child.identifier) { return false }
                pending.append(contentsOf: child.children)
            }
            return true
        }
        // ui-label-lookup: Never act on a generic Not Now button without the exact password title.
        let declines = nodes.filter { $0.elementType == .button && ["以后", "Not Now"].contains($0.label) }
        let hasAlert = nodes.contains { $0.elementType == .alert }
        let hasSheet = nodes.contains { $0.elementType == .sheet }
        let modalSource: ModeModalSource
        if isPromptAlert {
            modalSource = .alertsQuery
        } else if hasAlert {
            modalSource = isSpringboard ? .springboardAlert : .appAlert
        } else if hasSheet {
            modalSource = isSpringboard ? .springboardSheet : .appSheet
        } else if hasTitle {
            modalSource = isSpringboard ? .springboardOtherWindow : .appOtherWindow
        } else {
            modalSource = .none
        }
        return Observation(
            window: window, windowElement: element, windowIndex: windowIndex, nodes: nodes,
            decline: hasTitle && !hasOtherModal && declines.count == 1 ? declines[0] : nil,
            hasPasswordPrompt: hasTitle, hasPromptClue: hasTitle || !declines.isEmpty,
            hasModalObstacle: hasTitle || nodes.contains { $0.elementType == .alert || $0.elementType == .sheet },
            modalSource: modalSource,
            promptHost: host, promptFrame: window.frame,
            isPromptAlert: isPromptAlert, promptContainer: element,
            promptSource: isPromptAlert ? "alert-snapshot" : "window-index-\(windowIndex)")
    }

    // Snapshot attributes are fallible; XCTest exposes hittability only on the live element.
    private func tap(
        _ node: XCUIElementSnapshot, observation: Observation, deadline: Date, step: String,
        diagnostics: ModeNavigationDiagnostics? = nil,
        transaction: TestWait.HangGuard.Transaction? = nil,
        willTap: () -> Void = {}, didTap: (TimeInterval) -> Void = { _ in }
    ) -> Bool {
        let isDecline = step == "save-password-prompt"
        let host = isDecline ? observation.promptHost : app
        let frame = isDecline ? observation.promptFrame : observation.window.frame
        guard isDecline || !observation.hasModalObstacle else {
            diagnostics?.tapGuard = .modal
            return false
        }
        guard node.isEnabled, !node.frame.isEmpty, frame.contains(node.frame) else {
            diagnostics?.tapGuard = .snapshot
            return false
        }
        guard Date() < deadline else {
            diagnostics?.tapGuard = .deadline
            return false
        }
        if isDecline && observation.isPromptAlert
            && (try? navigationQuery(transaction, { host.alerts.count })) != 1
        {
            diagnostics?.tapGuard = .alertCount
            return false
        }
        let container = isDecline ? observation.promptContainer : observation.windowElement
        // ui-label-lookup: Bind the live action to both attributes of the observed button, including an empty ID.
        let matches = container.buttons.matching(
            NSPredicate(format: "identifier == %@ AND label == %@", node.identifier, node.label))
        guard let matchCount = try? navigationQuery(transaction, { matches.count }) else { return false }
        diagnostics?.tapMatches = min(4096, matchCount)
        guard matchCount == 1 else {
            diagnostics?.tapGuard = .liveCount
            return false
        }
        let target = matches.element(boundBy: .zero)
        guard let liveLabel = try? navigationQuery(transaction, { target.label }) else { return false }
        guard liveLabel == node.label else {
            diagnostics?.tapGuard = .liveLabel
            return false
        }
        guard (try? navigationQuery(transaction, { target.frame })) == node.frame else {
            diagnostics?.tapGuard = .liveFrame
            return false
        }
        guard let isHittable = try? navigationQuery(transaction, { target.isHittable }) else { return false }
        diagnostics?.captureModeDiagnosticHittability(identifier: node.identifier, value: isHittable)
        if isDecline && observation.isPromptAlert
            && (try? navigationQuery(transaction, { host.alerts.count })) != 1
        {
            diagnostics?.tapGuard = .alertCount
            return false
        }
        guard isHittable else {
            diagnostics?.tapGuard = .notHittable
            return false
        }
        guard Date() < deadline else {
            diagnostics?.tapGuard = .deadline
            return false
        }
        let action = {
            diagnostics?.tapGuard = .issued
            FirstFailureContext.mark(step, element: node.identifier.isEmpty ? "unknown" : node.identifier)
            willTap()
            if step == "save-password-prompt" {
                print(
                    "Exact Save Password prompt observed; Not Now issued; source=\(observation.promptSource); liveLabel=\(liveLabel)"
                )
            }
            target.tap()
        }
        let actionStartedAt = ProcessInfo.processInfo.systemUptime
        if let transaction {
            guard transaction.perform("tap", action) else { return false }
        } else {
            FirstFailureContext.action("tap", action)
        }
        let actionSeconds = ProcessInfo.processInfo.systemUptime - actionStartedAt
        diagnostics?.nativeTapSeconds.append(actionSeconds)
        didTap(actionSeconds)
        print("First-boot mode action returned: step=\(step); actionSeconds=\(actionSeconds)")
        if step == "save-password-prompt" {
            print(
                "First-boot prompt receipt: source=\(observation.promptSource); liveLabel=\(liveLabel); Not Now returned=true"
            )
        }
        return true
    }

    /// Every decline needs a fresh exact prompt observation within the same absolute deadline.
    @discardableResult
    func dismissPasswordPrompt(until deadline: Date, onDecline: () -> Void = {}) -> Bool {
        var didDecline = false
        repeat {
            if let observation = try? observe() {
                if !observation.hasPasswordPrompt {
                    if didDecline { print("Exact Save Password prompt disappearance confirmed") }
                    return Date() <= deadline
                }
                if let decline = observation.decline {
                    let returned = tap(
                        decline, observation: observation, deadline: deadline, step: "save-password-prompt")
                    if returned { onDecline() }
                    didDecline = didDecline || returned
                }
            }
            poll(until: deadline)
        } while Date() < deadline
        return false
    }

    func isPasswordPromptVisible(until deadline: Date) -> Bool {
        repeat {
            if let observation = try? observe() { return observation.hasPasswordPrompt }
            poll(until: deadline)
        } while Date() < deadline
        // Unknown at the caller's deadline cannot authorize an unobstructed action.
        return true
    }

    func dismissPasswordPrompt(
        guardWait: TestWait.HangGuard, transaction: TestWait.HangGuard.Transaction
    ) -> Bool {
        var current: Observation?
        _ = transaction.probe {
            current = try? observe(transaction: transaction); return current != nil
        }
        guard let initial = current else { return false }
        if !initial.hasPasswordPrompt { return !initial.hasModalObstacle }
        guard let decline = initial.decline,
            tap(
                decline, observation: initial,
                deadline: Date().addingTimeInterval(guardWait.remainingSeconds), step: "save-password-prompt",
                transaction: transaction)
        else { return false }
        return transaction.until {
            // Preparation cannot authorize another action after expiry, even if decline returns late.
            guard guardWait.remainingSeconds > 0, let observed = try? observe(transaction: transaction) else {
                return false
            }
            return !observed.hasPasswordPrompt && !observed.hasModalObstacle
        }
    }

    @discardableResult
    func selectMode(
        _ identifier: String, timeout: TimeInterval, file: StaticString = #filePath, line: UInt = #line
    ) -> Bool {
        navigateMode(
            identifier, selectionTimeout: timeout,
            file: file, line: line) != nil
    }

    @discardableResult
    func selectModeAndContinue(
        _ identifier: String, destinationIdentifier: String,
        file: StaticString = #filePath, line: UInt = #line
    ) -> ModeDeparture? {
        let guardWait = TestWait.hangGuard()
        let deadline = Date().addingTimeInterval(guardWait.remainingSeconds)
        let card = guardWait.transaction()
        let proceed = guardWait.transaction()
        let declinePrompt = guardWait.transaction()
        var observing = card
        var lastObservation: Observation?
        var didSelect = false
        var didDecline = false
        var didConfirmPromptGone = false
        var didSeePromptAfterContinue = false
        var didIssueContinue = false
        var didReturnContinue = false
        var didReadLastSnapshot = false
        var step = "mode-card"
        var lastErrorCode: Int?
        let diagnostics = ModeNavigationDiagnostics(targetIdentifier: identifier)
        FirstFailureContext.beginWait(seconds: guardWait.remainingSeconds)
        defer {
            FirstFailureContext.endWait()
            print("First-boot mode observations: \(diagnostics.modeDiagnosticMessage)")
        }
        while let captured = observing.query({ () -> Result<Observation, Error> in
            FirstFailureContext.mark(step, element: didIssueContinue ? "mode.continue.button" : identifier)
            diagnostics.beginModeDiagnosticObservation()
            let startedAt = ProcessInfo.processInfo.systemUptime
            defer { diagnostics.finishModeDiagnosticObservation(since: startedAt) }
            return Result {
                if guardWait.remainingSeconds <= 0 {
                    // The action's one admitted follow-up is the same complete modal-aware observation.
                    return try observe(
                        destinationIdentifier: destinationIdentifier, diagnostics: diagnostics)
                }
                return try observe(
                    modeIdentifier: didReturnContinue ? nil : identifier,
                    destinationIdentifier: destinationIdentifier, diagnostics: diagnostics, transaction: observing)
            }
        }) {
            guard case .success(let current) = captured else {
                didReadLastSnapshot = false
                if case .failure(let error) = captured { lastErrorCode = (error as NSError).code }
                poll(until: deadline)
                continue
            }
            lastObservation = current
            didReadLastSnapshot = true
            diagnostics.captureModeDiagnosticSnapshot(current)
            diagnostics.stage = .complete
            if current.hasPasswordPrompt {
                step = "save-password-prompt"
                didSeePromptAfterContinue = didSeePromptAfterContinue || didReturnContinue
                didConfirmPromptGone = false
                if !didDecline, let decline = current.decline {
                    didDecline = tap(
                        decline, observation: current, deadline: deadline, step: "save-password-prompt",
                        diagnostics: diagnostics, transaction: declinePrompt)
                    if didDecline { observing = declinePrompt }
                }
            } else {
                if didDecline, !didConfirmPromptGone {
                    didConfirmPromptGone = true
                    print("Exact Save Password prompt disappearance confirmed")
                }
                if didReturnContinue {
                    step = "mode-departure"
                    if !current.hasModalObstacle, !current.isModePage, current.hasDestination(destinationIdentifier) {
                        FirstFailureContext.mark("unknown")
                        print(
                            "First-boot mode departure confirmed; Continue issued=true returned=true; passwordPromptDismissed=\(didConfirmPromptGone)"
                        )
                        return ModeDeparture(
                            guardWait: guardWait, deadline: deadline, observation: current,
                            passwordPromptTransaction: declinePrompt)
                    }
                } else if current.isModeCardSelected(identifier), !current.hasModalObstacle {
                    step = "mode-continue"
                    if let button = current.button("mode.continue.button") {
                        didReturnContinue = tap(
                            button, observation: current, deadline: deadline, step: "mode-continue",
                            diagnostics: diagnostics, transaction: proceed,
                            willTap: {
                                didIssueContinue = true
                                print("First-boot Continue issued=true; targetModeSelected=true")
                            })
                        if didReturnContinue {
                            observing = proceed
                            step = "mode-departure"
                        }
                    }
                } else if !didSelect, let button = current.button(identifier) {
                    step = "mode-card"
                    didSelect = tap(
                        button, observation: current, deadline: deadline, step: "mode-card",
                        diagnostics: diagnostics, transaction: card)
                }
            }
            poll(until: deadline)
        }
        FirstFailureContext.mark(step, element: didIssueContinue ? "mode.continue.button" : identifier)
        let detail =
            "Continue issued=\(didIssueContinue) returned=\(didReturnContinue), passwordDeclineReturned=\(didDecline), passwordPromptDismissed=\(didConfirmPromptGone), lastSnapshotSucceeded=\(didReadLastSnapshot), lastSnapshotError=\(lastErrorCode.map(String.init) ?? "none"), \(diagnostics.modeDiagnosticMessage)"
        if didReturnContinue, !didSeePromptAfterContinue, didReadLastSnapshot,
            lastObservation?.isModePage == true, lastObservation?.hasPasswordPrompt == false
        {
            XCTFail(
                "Mode departure failed after one hittable Continue without a password prompt; possible App navigation defect (\(detail))",
                file: file, line: line)
        } else {
            XCTFail(
                "First-boot mode navigation must dismiss the exact password prompt, select the target and finish within its deadline (\(detail))",
                file: file, line: line)
        }
        return nil
    }

    @MainActor
    struct ModeDeparture {
        let guardWait: TestWait.HangGuard
        let deadline: Date
        let observation: Observation
        let passwordPromptTransaction: TestWait.HangGuard.Transaction

        /// Reuse the successful observation; extra readiness checks share its deadline.
        func confirms(_ condition: ([XCUIElementSnapshot]) -> Bool) -> Bool {
            if condition(observation.nodes) { return true }
            return guardWait.transaction().until {
                guard let snapshot = try? observation.windowElement.snapshot() else { return false }
                var pending = [snapshot]
                var nodes: [XCUIElementSnapshot] = []
                while let node = pending.popLast() {
                    nodes.append(node)
                    pending.append(contentsOf: node.children)
                }
                return condition(nodes)
            }
        }
    }

    private func navigateMode(
        _ identifier: String, selectionTimeout: TimeInterval,
        file: StaticString, line: UInt
    ) -> Date? {
        var selectionDeadline = Date().addingTimeInterval(selectionTimeout)
        var didSelect = false
        var didDecline = false
        var didSeePrompt = false
        var didConfirmPromptGone = false
        var promptSource = "not-observed"
        var lastSnapshotError: Int?
        var lastModePage: Bool?
        var didReadLastSnapshot = false
        var step = "mode-card"
        let diagnostics = ModeNavigationDiagnostics(targetIdentifier: identifier)
        // Selection-only evidence keeps its existing budget; departure uses the separate shared guard.
        func accountForModeTap(_ seconds: TimeInterval) {
            selectionDeadline.addTimeInterval(seconds)
            FirstFailureContext.endWait()
            FirstFailureContext.beginWait(
                seconds: max(.zero, selectionDeadline.timeIntervalSinceNow))
        }
        defer { print("First-boot mode observations: \(diagnostics.modeDiagnosticMessage)") }
        FirstFailureContext.beginWait(seconds: selectionTimeout)
        defer { FirstFailureContext.endWait() }
        while Date() < selectionDeadline {
            let deadline = selectionDeadline
            FirstFailureContext.mark(step, element: identifier)
            let observation: Observation
            diagnostics.beginModeDiagnosticObservation()
            let observationStartedAt = ProcessInfo.processInfo.systemUptime
            do {
                observation = try observe(modeIdentifier: identifier, diagnostics: diagnostics)
            } catch {
                diagnostics.finishModeDiagnosticObservation(since: observationStartedAt)
                lastSnapshotError = (error as NSError).code
                didReadLastSnapshot = false
                poll(until: deadline)
                continue
            }
            diagnostics.finishModeDiagnosticObservation(since: observationStartedAt)
            diagnostics.captureModeDiagnosticSnapshot(observation)
            diagnostics.stage = .complete
            guard Date() < deadline else { break }
            didReadLastSnapshot = true
            lastModePage = observation.isModePage
            if observation.hasPasswordPrompt {
                didSeePrompt = true
                didConfirmPromptGone = false
                promptSource = observation.promptSource
                step = "save-password-prompt"
                if let decline = observation.decline {
                    let returned = tap(
                        decline, observation: observation, deadline: deadline, step: "save-password-prompt",
                        diagnostics: diagnostics, didTap: accountForModeTap)
                    didDecline = didDecline || returned
                    if returned { didSelect = false }
                }
                poll(until: selectionDeadline)
                continue
            }
            if didDecline && !didConfirmPromptGone {
                didConfirmPromptGone = true
                print("Exact Save Password prompt disappearance confirmed")
            }
            step = "mode-card"
            if observation.isModeCardSelected(identifier) && !observation.hasModalObstacle {
                FirstFailureContext.mark("unknown")
                print("First-boot target mode selection confirmed; Continue issued=false")
                return selectionDeadline
            } else if !didSelect, let button = observation.button(identifier) {
                didSelect = tap(
                    button, observation: observation, deadline: deadline, step: step, diagnostics: diagnostics,
                    didTap: accountForModeTap)
            }
            poll(until: selectionDeadline)
        }
        FirstFailureContext.mark(step, element: identifier)
        let detail =
            "step=\(step), Continue issued=false returned=false, passwordPromptObserved=\(didSeePrompt), passwordDeclineReturned=\(didDecline), passwordPromptDismissed=\(didConfirmPromptGone), promptSource=\(promptSource), modePage=\(lastModePage.map(String.init) ?? "unknown"), lastSnapshotSucceeded=\(didReadLastSnapshot), lastSnapshotError=\(lastSnapshotError.map(String.init) ?? "none"), \(diagnostics.modeDiagnosticMessage)"
        XCTFail(
            "First-boot mode navigation must dismiss the exact password prompt, select the target and finish within its deadline (\(detail))",
            file: file, line: line)
        return nil
    }

    private func poll(until deadline: Date) {
        guard Date() < deadline else { return }
        RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(TestWait.seconds(.product(0.1)))))
    }
}

struct SlideshowControlBarButtonObservation {
    let identifier: String
    let snapshots: [String: XCUIElementSnapshot]
    let windowFrame: CGRect
    let windowElement: XCUIElement

    var button: XCUIElementSnapshot? { snapshots[identifier] }
    var hasPlaybackMarker: Bool { snapshots["slideshow.currentAssetId.flag"] != nil }
    var isInsideWindow: Bool {
        guard let button else { return false }
        return !button.frame.isEmpty && windowFrame.contains(button.frame)
    }
    var isReady: Bool { button?.isEnabled == true && isInsideWindow }

    var hasSettingsOutcome: Bool {
        snapshots.keys.contains { $0.hasPrefix("settings.item.") }
            || snapshots["settings.playback.autoPlay.toggle"] != nil
    }

    var hasSettingsNavigationEvidence: Bool {
        snapshots["BackButton"] != nil || snapshots.keys.contains { $0.hasPrefix("settings.") }
    }

    var diagnostic: String {
        "playbackMarker.exists=\(hasPlaybackMarker), control.exists=\(button != nil), enabled=\(button.map { String($0.isEnabled) } ?? "unknown"), frame=\(button.map { String(describing: $0.frame) } ?? "unknown"), frameInsideWindow=\(isInsideWindow)"
    }
}

extension XCUIApplication {
    func slideshowControlBarButtonObservation(identifier: String) throws -> SlideshowControlBarButtonObservation {
        let windowElement = windows.firstMatch
        let window = try windowElement.snapshot()
        var pending = window.children
        var snapshots: [String: XCUIElementSnapshot] = [:]
        while let node = pending.popLast() {
            if !node.identifier.isEmpty, snapshots[node.identifier] == nil,
                node.identifier != identifier || node.elementType == .button
            {
                snapshots[node.identifier] = node
            }
            pending.append(contentsOf: node.children)
        }
        return SlideshowControlBarButtonObservation(
            identifier: identifier, snapshots: snapshots, windowFrame: window.frame, windowElement: windowElement)
    }

}
#endif

enum UITestSupportWaitTiming {
    static let elementAppearanceTimeoutSeconds: TimeInterval = TestWait.seconds(.product(5))
    static let identityPollSeconds: TimeInterval = TestWait.seconds(.product(0.3))
    static let readbackTimeoutSeconds: TimeInterval = TestWait.seconds(.product(2))
}

enum Timing {
    static let focusSettle: TimeInterval = TestWait.seconds(.product(0.16))
}
