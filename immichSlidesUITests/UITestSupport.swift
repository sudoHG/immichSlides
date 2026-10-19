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
        FirstFailureContext.mark("capture-frame", element: self is XCUIApplication ? "app-window" : "unknown")
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

    func adjustForFailureEvidence(toNormalizedSliderPosition position: CGFloat) {
        FirstFailureContext.mark("select", element: FirstFailureContext.snapshot().element)
        FirstFailureContext.action("adjust") { adjust(toNormalizedSliderPosition: position) }
    }

    #if os(iOS)
    func swipeUpForFailureEvidence() { FirstFailureContext.action("unknown") { swipeUp() } }
    func swipeDownForFailureEvidence() { FirstFailureContext.action("unknown") { swipeDown() } }
    func swipeLeftForFailureEvidence() { FirstFailureContext.action("unknown") { swipeLeft() } }
    func swipeRightForFailureEvidence() { FirstFailureContext.action("unknown") { swipeRight() } }
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
    func evidenceSnapshotsByIdentifier(onSnapshotFailure: ((Error) -> Void)? = nil) -> [String: XCUIElementSnapshot] {
        FirstFailureContext.mark("query-element", element: "app-window")
        let root: XCUIElementSnapshot
        do {
            root = try snapshot()
        } catch {
            onSnapshotFailure?(error)
            return [:]
        }
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
                if snapshots[focusedIdentifier]?.isEnabled == false {
                    if waitForFocus({ $0["slideshow.control.playPause.button"]?.hasFocus == true }) { return true }
                    continue
                }
                FirstFailureRemote.press(direction == .left ? .right : .left)
                if waitForFocus({ $0[focusedIdentifier]?.hasFocus == true }) { return true }
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
struct IOSFirstBootNavigation {
    let app: XCUIApplication

    struct Observation {
        let window: XCUIElementSnapshot
        let nodes: [XCUIElementSnapshot]
        let decline: XCUIElementSnapshot?
        let hasPasswordPrompt: Bool
        let hasModalObstacle: Bool
        let promptHost: XCUIApplication
        let promptFrame: CGRect

        func button(_ identifier: String) -> XCUIElementSnapshot? {
            let matches = nodes.filter { $0.identifier == identifier && $0.elementType == .button }
            return matches.count == 1 ? matches[0] : nil
        }

        func isSelected(_ identifier: String) -> Bool {
            guard let button = button(identifier) else { return false }
            var pending = [button]
            while let node = pending.popLast() {
                if node.isSelected || (node.elementType == .image && node.identifier == "checkmark.circle.fill") {
                    return true
                }
                pending.append(contentsOf: node.children)
            }
            return false
        }

        var isModePage: Bool { nodes.contains { $0.identifier.hasPrefix("mode.") } }
        var hasDestination: Bool {
            nodes.contains {
                $0.identifier == "filterSummary.startPlayback.button"
                    || $0.identifier == "slideshow.currentAssetId.flag"
                    || $0.identifier == "slideshow.control.next.button"
                    || $0.identifier == "slideshow.entryHint.banner"
            }
        }
    }

    func observe() throws -> Observation {
        let window = try app.windows.firstMatch.snapshot()
        let own = observation(window: window, host: app)
        if own.hasPasswordPrompt { return own }
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // iOS can host the late credential sheet outside the app's accessibility tree.
        let systemWindow = try system.windows.firstMatch.snapshot()
        let prompt = observation(window: systemWindow, host: system)
        return Observation(
            window: own.window, nodes: own.nodes, decline: prompt.decline,
            hasPasswordPrompt: prompt.hasPasswordPrompt,
            hasModalObstacle: own.hasModalObstacle || prompt.hasModalObstacle,
            promptHost: system, promptFrame: systemWindow.frame)
    }

    private func observation(window: XCUIElementSnapshot, host: XCUIApplication) -> Observation {
        var pending = [window]
        var nodes: [XCUIElementSnapshot] = []
        while let node = pending.popLast() {
            nodes.append(node)
            pending.append(contentsOf: node.children)
        }
        // ui-label-lookup: The simulator-owned password prompt follows the system language.
        let titles = ["保存密码？", "保存密码?", "Save Password?"]
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
        return Observation(
            window: window, nodes: nodes,
            decline: hasTitle && !hasOtherModal && declines.count == 1 ? declines[0] : nil,
            hasPasswordPrompt: hasTitle,
            hasModalObstacle: hasTitle || nodes.contains { $0.elementType == .alert || $0.elementType == .sheet },
            promptHost: host, promptFrame: window.frame)
    }

    // Snapshot attributes are fallible; XCTest exposes hittability only on the live element.
    private func tap(
        _ node: XCUIElementSnapshot, observation: Observation, deadline: Date, step: String,
        willTap: () -> Void = {}
    ) -> Bool {
        let isDecline = step == "save-password-prompt"
        let host = isDecline ? observation.promptHost : app
        let frame = isDecline ? observation.promptFrame : observation.window.frame
        guard node.isEnabled, !node.frame.isEmpty, frame.contains(node.frame), Date() < deadline
        else { return false }
        let target: XCUIElement
        if node.identifier.isEmpty {
            // ui-label-lookup: Only the exact password prompt's unique decline action reaches this branch.
            target = host.windows.firstMatch.buttons.matching(NSPredicate(format: "label == %@", node.label)).firstMatch
        } else {
            target = host.windows.firstMatch.buttons.matching(identifier: node.identifier).firstMatch
        }
        let isHittable = target.isHittable
        guard Date() < deadline else { return false }
        // SwiftUI mode cards can report non-hittable despite an unobstructed, fully visible frame.
        guard isHittable || (step == "mode-card" && !observation.hasModalObstacle) else { return false }
        FirstFailureContext.mark(step, element: node.identifier.isEmpty ? "unknown" : node.identifier)
        willTap()
        if step == "save-password-prompt" { print("Exact Save Password prompt observed; Not Now issued") }
        FirstFailureContext.action("tap") {
            if isHittable {
                target.tap()
            } else {
                let origin = observation.window.frame.origin
                print("First-boot mode-card issued using its unique unobstructed snapshot frame")
                app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: node.frame.midX - origin.x, dy: node.frame.midY - origin.y)).tap()
            }
        }
        if step == "save-password-prompt" { print("Exact Save Password prompt: Not Now returned") }
        return true
    }

    /// One decline per observed prompt; no screenshot or unrelated alert query precedes the tap.
    @discardableResult
    func dismissPasswordPrompt(until deadline: Date) -> Bool {
        var didDecline = false
        repeat {
            if let observation = try? observe() {
                if !observation.hasPasswordPrompt {
                    if didDecline { print("Exact Save Password prompt disappearance confirmed") }
                    return Date() <= deadline
                }
                if !didDecline, let decline = observation.decline {
                    didDecline = tap(
                        decline, observation: observation, deadline: deadline, step: "save-password-prompt")
                }
            }
            poll(until: deadline)
        } while Date() < deadline
        return false
    }

    @discardableResult
    func selectModeAndContinue(
        _ identifier: String, selectionTimeout: TimeInterval, departureTimeout: TimeInterval,
        file: StaticString = #filePath, line: UInt = #line
    ) -> Date? {
        let selectionDeadline = Date().addingTimeInterval(selectionTimeout)
        var didSelect = false
        var didDecline = false
        var didSeePrompt = false
        var didIssueContinue = false
        var didReturnContinue = false
        var lastSnapshotError: Int?
        var lastModePage: Bool?
        var didReadLastSnapshot = false
        var didObserveAfterContinue = false
        var departureDeadline: Date?
        var step = "mode-card"
        FirstFailureContext.beginWait(seconds: selectionTimeout)
        defer { FirstFailureContext.endWait() }
        while Date() < (departureDeadline ?? selectionDeadline) {
            let deadline = departureDeadline ?? selectionDeadline
            FirstFailureContext.mark(step, element: didIssueContinue ? "mode.continue.button" : identifier)
            let observation: Observation
            do { observation = try observe() } catch {
                lastSnapshotError = (error as NSError).code
                didReadLastSnapshot = false
                poll(until: deadline)
                continue
            }
            guard Date() < deadline else { break }
            didReadLastSnapshot = true
            lastModePage = observation.isModePage
            if didIssueContinue { didObserveAfterContinue = true }
            if observation.hasPasswordPrompt {
                didSeePrompt = true
                if !didDecline, let decline = observation.decline {
                    didDecline = tap(
                        decline, observation: observation, deadline: deadline, step: "save-password-prompt")
                    if didDecline && !didIssueContinue { didSelect = false }
                }
                poll(until: deadline)
                continue
            }
            if didIssueContinue {
                if !observation.isModePage && observation.hasDestination {
                    print(
                        "First-boot mode departure confirmed; Continue issued=true returned=\(didReturnContinue); passwordPromptDismissed=\(didDecline)"
                    )
                    return departureDeadline
                }
            } else if observation.isSelected(identifier) {
                step = "mode-continue"
                if let button = observation.button("mode.continue.button") {
                    // The departure budget is absolute, including the real tap and any late prompt.
                    let end = Date().addingTimeInterval(departureTimeout)
                    if tap(
                        button, observation: observation, deadline: deadline, step: step,
                        willTap: {
                            didIssueContinue = true
                            print("First-boot Continue issued=true; targetModeSelected=true")
                        })
                    {
                        didReturnContinue = true
                        departureDeadline = end
                        step = "mode-departure"
                        FirstFailureContext.endWait()
                        FirstFailureContext.beginWait(seconds: max(0, end.timeIntervalSinceNow))
                        print("First-boot Continue issued=true returned=true; targetModeSelected=true")
                    }
                }
            } else if !didIssueContinue && !didSelect, let button = observation.button(identifier) {
                didSelect = tap(button, observation: observation, deadline: deadline, step: step)
            }
            poll(until: departureDeadline ?? selectionDeadline)
        }
        FirstFailureContext.mark(step, element: didIssueContinue ? "mode.continue.button" : identifier)
        let detail =
            "step=\(step), Continue issued=\(didIssueContinue) returned=\(didReturnContinue), passwordPromptObserved=\(didSeePrompt), passwordPromptDismissed=\(didDecline), modePage=\(lastModePage.map(String.init) ?? "unknown"), postContinueSnapshotObserved=\(didObserveAfterContinue), lastSnapshotSucceeded=\(didReadLastSnapshot), lastSnapshotError=\(lastSnapshotError.map(String.init) ?? "none")"
        if didIssueContinue && !didSeePrompt && didReadLastSnapshot && didObserveAfterContinue && lastModePage == true {
            XCTFail(
                "Mode departure failed after one hittable Continue without a password prompt; possible App navigation defect (\(detail))",
                file: file, line: line)
        } else {
            XCTFail(
                "First-boot mode navigation must dismiss the exact password prompt, select the target and leave mode within its deadline (\(detail))",
                file: file, line: line)
        }
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

struct SlideshowControlBarTiming {
    var snapshotSeconds: TimeInterval = .zero
    var revealSeconds: TimeInterval = .zero
    var tapSeconds: TimeInterval = .zero
    var verifySeconds: TimeInterval = .zero
    var iterations = 0
    var tapCount = 0
    var shouldVerifySettingsOutcome = false
    var hasSettingsOutcome = false
    var didObserveSettingsNavigation = false
    var snapshotErrors = 0
    var lastErrorCode: Int?
    var didReadLastSnapshot = false
    var lastObservation = "unknown"

    var diagnostic: String {
        let phases = String(
            format: "snapshot=%.3fs, reveal=%.3fs, tap=%.3fs, verify=%.3fs",
            snapshotSeconds, revealSeconds, tapSeconds, verifySeconds)
        return
            "\(lastObservation), lastSnapshotSucceeded=\(didReadLastSnapshot), snapshotErrors=\(snapshotErrors), lastError=\(lastErrorCode.map(String.init) ?? "none"), iterations=\(iterations), tapCount=\(tapCount), settingsOutcomeExpected=\(shouldVerifySettingsOutcome), settingsOutcomeObserved=\(hasSettingsOutcome), settingsNavigationObserved=\(didObserveSettingsNavigation), \(phases)"
    }

    mutating func reveal(app: XCUIApplication) {
        FirstFailureContext.mark("reveal-controls", element: "slideshow.control.playPause.button")
        let startedAt = Date()
        FirstFailureContext.action("tap") { app.tap() }
        revealSeconds += Date().timeIntervalSince(startedAt)
    }

    mutating func observe(app: XCUIApplication, identifier: String) -> SlideshowControlBarButtonObservation? {
        FirstFailureContext.mark("query-element", element: identifier)
        let startedAt = Date()
        defer { snapshotSeconds += Date().timeIntervalSince(startedAt) }
        iterations += 1
        do {
            let observation = try app.slideshowControlBarButtonObservation(identifier: identifier)
            lastObservation = observation.diagnostic
            didReadLastSnapshot = true
            return observation
        } catch {
            snapshotErrors += 1
            lastErrorCode = (error as NSError).code
            didReadLastSnapshot = false
            return nil
        }
    }
}

extension XCUIApplication {
    func slideshowControlBarButtonObservation(identifier: String) throws -> SlideshowControlBarButtonObservation {
        let window = try windows.firstMatch.snapshot()
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
            identifier: identifier, snapshots: snapshots, windowFrame: window.frame)
    }

    func waitForSlideshowSettingsSnapshot(
        timeout: TimeInterval, pollSeconds: TimeInterval, onTimeout: (String) -> Void
    ) -> Bool {
        FirstFailureContext.mark("reveal-controls", element: "slideshow.control.settings.button")
        FirstFailureContext.beginWait(seconds: timeout)
        defer { FirstFailureContext.endWait() }
        let deadline = Date().addingTimeInterval(timeout)
        var timing = SlideshowControlBarTiming()
        var hiddenSince: Date?
        var hiddenRevealCount = 0
        while Date() < deadline {
            let observation = timing.observe(app: self, identifier: "slideshow.control.settings.button")
            guard Date() < deadline else { break }
            if let observation {
                if observation.isReady {
                    timing.reveal(app: self)
                    guard Date() < deadline else { break }
                    return true
                }
                if observation.isInsideWindow {
                    hiddenSince = nil
                    hiddenRevealCount = 0
                } else if observation.hasPlaybackMarker {
                    let startedAt = hiddenSince ?? Date()
                    hiddenSince = startedAt
                    if hiddenRevealCount == 0
                        || (hiddenRevealCount == 1
                            && Date().timeIntervalSince(startedAt) > TestWait.seconds(.product(1)))
                    {
                        timing.reveal(app: self)
                        hiddenRevealCount += 1
                    }
                }
            }
            guard Date() < deadline else { break }
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(pollSeconds)))
        }
        onTimeout("The slideshow Settings waiter did not become ready before the deadline. (\(timing.diagnostic))")
        return false
    }

    // Use only for functional checks, never to verify control-bar visibility or auto-hide timing.
    func waitForSlideshowControlBarButton(identifier: String, timeout: TimeInterval) -> Bool {
        if descendants(matching: .any)["slideshow.currentAssetId.flag"].exists {
            FirstFailureContext.action("tap") { tap() }
        }
        return buttons[identifier].waitForPublicElement(identifier, timeout: timeout)
    }

    func tapSlideshowControlBarButton(
        identifier: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        var timing = SlideshowControlBarTiming()
        timing.shouldVerifySettingsOutcome = identifier == "slideshow.control.settings.button"
        // A playback-area tap only shows the bar and resets auto-hide; it never toggles it off.
        timing.reveal(app: self)
        let deadline = Date().addingTimeInterval(UITestSupportWaitTiming.controlAppearanceTimeoutSeconds)
        var isTapAttemptPrepared = true
        while Date() < deadline {
            let observation = timing.observe(app: self, identifier: identifier)
            if timing.tapCount > 0 {
                timing.didObserveSettingsNavigation =
                    timing.didObserveSettingsNavigation || observation?.hasSettingsNavigationEvidence == true
            }
            guard Date() < deadline else { break }
            if let observation {
                // Once navigation starts, the first Settings tap is delivered; never tap an incoming page.
                guard !timing.didObserveSettingsNavigation else { break }
                if observation.isInsideWindow,
                    let button = observation.button
                {
                    if isTapAttemptPrepared {
                        let frame = button.frame
                        let startedAt = Date()
                        timing.tapCount += 1
                        windows.firstMatch.coordinate(withNormalizedOffset: .zero)
                            .withOffset(
                                CGVector(
                                    dx: frame.midX - observation.windowFrame.minX,
                                    dy: frame.midY - observation.windowFrame.minY)
                            ).tapForFailureEvidence()
                        timing.tapSeconds += Date().timeIntervalSince(startedAt)
                        // Callers own scene-change, Play/Pause and EXIF budgets after one real tap.
                        if !timing.shouldVerifySettingsOutcome { return }
                        isTapAttemptPrepared = false
                        // XCTest's idle wait belongs to the tap, not the destination appearance window.
                        let didObserveOutcome = TestWait.until(
                            .product(UITestSupportWaitTiming.elementAppearanceTimeoutSeconds),
                            pollIntervalSeconds: UITestSupportWaitTiming.identityPollSeconds
                        ) {
                            let verifyStartedAt = Date()
                            let outcome = timing.observe(app: self, identifier: identifier)
                            timing.didObserveSettingsNavigation =
                                timing.didObserveSettingsNavigation || outcome?.hasSettingsNavigationEvidence == true
                            timing.verifySeconds += Date().timeIntervalSince(verifyStartedAt)
                            return outcome?.hasSettingsOutcome ?? false
                        }
                        timing.hasSettingsOutcome = didObserveOutcome
                        if didObserveOutcome { return }
                        guard timing.tapCount < 2 else { break }
                    } else if observation.hasPlaybackMarker {
                        // Confirm no navigation in this iteration before revealing for the one retry.
                        timing.reveal(app: self)
                        isTapAttemptPrepared = true
                        continue
                    }
                }
            }
            guard Date() < deadline else { break }
            RunLoop.current.run(
                until: min(deadline, Date().addingTimeInterval(UITestSupportWaitTiming.identityPollSeconds)))
        }
        if timing.tapCount == 0 {
            XCTFail(
                "The slideshow control never became tappable before the deadline. (\(timing.diagnostic))",
                file: file, line: line)
        } else {
            XCTFail(
                "The slideshow Settings tap had no observed outcome before the deadline. (\(timing.diagnostic))",
                file: file, line: line)
        }
    }
}
#endif

enum UITestSupportWaitTiming {
    static let briefElementTimeoutSeconds: TimeInterval = TestWait.seconds(.product(1))
    static let connectionTimeoutSeconds: TimeInterval = TestWait.seconds(.product(15))
    static let controlAppearanceTimeoutSeconds: TimeInterval = TestWait.seconds(.product(8))
    static let elementAppearanceTimeoutSeconds: TimeInterval = TestWait.seconds(.product(5))
    static let identityPollSeconds: TimeInterval = TestWait.seconds(.product(0.3))
    static let playbackStartupTimeoutSeconds: TimeInterval = TestWait.seconds(.product(30))
    static let readbackTimeoutSeconds: TimeInterval = TestWait.seconds(.product(2))
    static let sceneReadyTimeoutSeconds: TimeInterval = TestWait.seconds(.infrastructure(45))
    static let screenTransitionTimeoutSeconds: TimeInterval = TestWait.seconds(.product(12))
    static let settingsChangeTimeoutSeconds: TimeInterval = TestWait.seconds(.product(6))
    static let shortInteractionTimeoutSeconds: TimeInterval = TestWait.seconds(.product(3))
    static let stateChangeTimeoutSeconds: TimeInterval = TestWait.seconds(.product(4))
}

// Shared by the strict end-to-end UI tests: writing required PNGs / steps to disk, stable-frame waits, and real settings
// actions on both platforms.
// scripts/strict_e2e_p2_contract.py is the single source of truth for the p2-steps.json format.

enum Timing {
    // Interval between two screenshots (seconds). Stable only when two consecutive frames show the same public
    // pattern, which rules out mid-transition frames.
    static let identityPoll: TimeInterval = TestWait.seconds(.product(0.3))
    static let stableIdentityTimeout: TimeInterval = TestWait.seconds(.product(8))
    static let exifSettleTimeout: TimeInterval = TestWait.seconds(.product(5))
    // Multi-photo scenes must hold for 1 second in a row, to avoid capturing a half-switched frame.
    static let multiPhotoWait: TimeInterval = TestWait.seconds(.product(4))
    static let multiPhotoHold: TimeInterval = TestWait.seconds(.product(1))
    static let clearCompletionTimeout: TimeInterval = TestWait.seconds(.product(15))
    static let focusSettle: TimeInterval = TestWait.seconds(.product(0.16))
    static let poll: TimeInterval = TestWait.seconds(.product(0.1))
    // Orientation steady state: capture only when two frames 0.5 seconds apart show no layout jump. Wait at most
    // 10 seconds per attempt; on timeout keep the scene as it is.
    static let stableFramePair: TimeInterval = TestWait.seconds(.product(0.5))
    static let stableFrameTimeout: TimeInterval = TestWait.seconds(.product(10))
}

// Values match the orientation field in p2-steps.json; notApplicable skips the orientation check.
enum StepOrientation: String {
    case portrait
    case landscape
    case notApplicable = "not_applicable"

    func matches(_ size: CGSize) -> Bool {
        switch self {
        case .portrait: return size.height > size.width
        case .landscape: return size.width > size.height
        case .notApplicable: return true
        }
    }
}

struct Failure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

enum Wait {
    @MainActor
    static func until(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        FirstFailureContext.beginWait(seconds: timeout)
        defer { FirstFailureContext.endWait() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.poll))
        }
        return condition()
    }

    // The condition must hold continuously for hold seconds within timeout; the timer restarts if it fails midway.
    @MainActor
    static func held(timeout: TimeInterval, hold: TimeInterval, _ condition: () -> Bool) -> Bool {
        FirstFailureContext.beginWait(seconds: timeout + hold)
        defer { FirstFailureContext.endWait() }
        let deadline = Date().addingTimeInterval(timeout + hold)
        var heldSince: Date?
        while Date() < deadline {
            if condition() {
                let start = heldSince ?? Date()
                heldSince = start
                if Date().timeIntervalSince(start) >= hold { return true }
            } else {
                heldSince = nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.poll))
        }
        return false
    }
}

@MainActor
final class Evidence {
    private var steps: [[String: Any]] = []

    // Write the required PNG and record a step only when accept passes. On timeout keep only a -rejected
    // diagnostic frame; the required file stays missing so the contract fails.
    @discardableResult
    func capture(
        _ name: String,
        from app: XCUIApplication,
        orientation: StepOrientation = .notApplicable,
        timeout: TimeInterval = Timing.stableIdentityTimeout,
        accept: (StrictE2EPhotoIdentity.Result) -> Bool = { _ in true }
    ) throws -> StrictE2EPhotoIdentity.Result {
        FirstFailureContext.mark("capture-frame", element: "app-window")
        FirstFailureContext.beginWait(seconds: timeout)
        defer { FirstFailureContext.endWait() }
        let deadline = Date().addingTimeInterval(timeout)
        var capturedAt = Date()
        var png = app.screenshotForFailureEvidence().pngRepresentation
        var identity = StrictE2EPhotoIdentity.classify(png: png)
        // No retakes past the deadline, so a last round cannot push later watermarks out of the contract window.
        while !accept(identity) {
            let retryAt = Date().addingTimeInterval(Timing.identityPoll)
            guard retryAt < deadline else { break }
            RunLoop.current.run(until: retryAt)
            capturedAt = Date()
            png = app.screenshotForFailureEvidence().pngRepresentation
            identity = StrictE2EPhotoIdentity.classify(png: png)
        }
        guard accept(identity) else {
            try reject(name, png: png)
            throw Failure("\(name) unmet at timeout: status=\(identity.status.rawValue) mark=\(identity.mark ?? "nil")")
        }
        try record(name, png: png, capturedAt: capturedAt, orientation: orientation)
        return identity
    }

    // A frame the caller already accepted: write the required PNG and record a step.
    func record(_ name: String, png: Data, capturedAt: Date, orientation: StepOrientation) throws {
        try save(png, as: name)
        try appendStep(name, at: capturedAt, orientation: orientation, png: "\(name).png")
    }

    // A rejected frame leaves only a -rejected diagnostic; the required PNG stays missing so the contract fails.
    func reject(_ name: String, png: Data) throws {
        try save(png, as: "\(name)-rejected")
    }

    // Time marker without a PNG (rotation start, start of a recording segment). The contract uses it to convert
    // recording offsets.
    func markStep(_ name: String) throws {
        try appendStep(name, at: Date(), orientation: .notApplicable, png: nil)
    }

    private func save(_ png: Data, as fileName: String) throws {
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = fileName
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: fileName) { $0.add(attachment) }
        try StrictE2EVisualEvidence.writeRequiredPNG(png, name: fileName)
    }

    private func appendStep(_ name: String, at wallTime: Date, orientation: StepOrientation, png: String?) throws {
        var step: [String: Any] = [
            "index": steps.count + 1,
            "name": name,
            "wall_time": wallTime.timeIntervalSince1970,
            "orientation": orientation.rawValue
        ]
        if let png { step["png"] = png }
        steps.append(step)
        try StrictE2EVisualEvidence.writeRequiredJSON(
            ["schema": "strict-e2e-steps-v1", "steps": steps], name: "p2-steps.json")
    }

}

struct StableFrame {
    // Upper limit of the mean per-pixel difference (0-1) between 64x64 grayscale thumbnails. On the public pattern
    // a slow 0.5-second zoom / pan is about <=0.02, while a 5% relayout or a crossfade is about >=0.032. A relayout
    // of a screen with little content may fall below it.
    static let layoutJumpLimit = 0.03
    private static let thumbnailSide = 64

    let png: Data
    let capturedAt: Date
    let isStable: Bool
    let detail: String

    // Stable only when window orientation, prepare (run before the screenshot, e.g. waking the control bar), pixel
    // orientation and accept all hold, and two frames 0.5 seconds apart differ by no more than the limit. On
    // timeout, returns the last frame for the record.
    @MainActor
    static func wait(
        in app: XCUIApplication,
        orientation: StepOrientation,
        timeout: TimeInterval = Timing.stableFrameTimeout,
        prepare: () -> Bool = { true },
        accept: (Data) -> Bool
    ) -> StableFrame {
        let deadline = Date().addingTimeInterval(timeout)
        var previous: Data?
        while true {
            let window = app.frame.size
            let isPrepared = orientation.matches(window) && prepare()
            let capturedAt = Date()
            let png = uprightScreenPNG()
            let pixels = pixelSize(png) ?? .zero
            var candidate: Data?
            let detail: String
            if !orientation.matches(window) {
                detail = "window \(window) not yet \(orientation.rawValue)"
            } else if !isPrepared {
                detail = "controls or scene not ready"
            } else if !orientation.matches(pixels) {
                detail = "screenshot pixels \(pixels) not yet \(orientation.rawValue)"
            } else if !accept(png) {
                detail = "screen not ready"
            } else if let previous {
                candidate = png
                if let difference = difference(previous, png) {
                    let formatted = String(format: "%.4f", difference)
                    if difference <= layoutJumpLimit {
                        return StableFrame(
                            png: png, capturedAt: capturedAt, isStable: true, detail: "frame diff \(formatted)")
                    }
                    detail = "frame diff \(formatted) exceeds \(layoutJumpLimit)"
                } else {
                    detail = "thumbnail decoding failed; cannot compare the two frames"
                }
            } else {
                candidate = png
                detail = "waiting for the second frame"
            }
            previous = candidate
            let nextAt = capturedAt.addingTimeInterval(Timing.stableFramePair)
            guard nextAt <= deadline else {
                return StableFrame(png: png, capturedAt: capturedAt, isStable: false, detail: detail)
            }
            RunLoop.current.run(until: nextAt)
        }
    }

    // In landscape, an app-element screenshot is cropped at the wrong offset and a full-screen screenshot is the
    // native portrait framebuffer; redraw it using the system's imageOrientation to match what the user sees.
    static func uprightScreenPNG() -> Data {
        let screenshot = XCUIScreen.main.screenshotForFailureEvidence()
        let image = screenshot.image
        guard image.imageOrientation != .up else { return screenshot.pngRepresentation }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).pngData { _ in image.draw(at: .zero) }
    }

    // MATCH or TRANSITION both mean the public pattern is visible; mixed colors in multi-photo scenes usually
    // classify as TRANSITION.
    static func showsFixturePhoto(_ png: Data) -> Bool {
        [.match, .transition].contains(StrictE2EPhotoIdentity.classify(png: png).status)
    }

    static func pixelSize(_ png: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    static func difference(_ first: Data, _ second: Data) -> Double? {
        guard let lhs = thumbnail(first), let rhs = thumbnail(second) else { return nil }
        let total = zip(lhs, rhs).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(lhs.count * 255)
    }

    private static func thumbnail(_ png: Data) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        var pixels = [UInt8](repeating: 0, count: thumbnailSide * thumbnailSide)
        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                let context = CGContext(
                    data: base,
                    width: thumbnailSide,
                    height: thumbnailSide,
                    bitsPerComponent: 8,
                    bytesPerRow: thumbnailSide,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                )
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: thumbnailSide, height: thumbnailSide))
            return true
        }
        return didDraw ? pixels : nil
    }
}

enum PlaybackSetting {
    case interval30Seconds
    // Positive control for Reduce Motion: moves faster than 30 seconds and is easier to see, yet still leaves
    // enough time to observe the same scene after returning.
    case interval15Seconds
    case displayMode(isSinglePhoto: Bool)
    case showExif(Bool)
}

// The two platforms differ only in how they tap; photo identification, waiting and evidence checks are shared.
@MainActor
protocol PlaybackDriver {
    var app: XCUIApplication { get }
    func launchToPlayback(input: StrictE2EInput)
    func applyPlaybackSettings(_ settings: [PlaybackSetting])
    func pause()
    func next()
    func returnToPlayback()
    // On the cache page, capture the screen before clearing, then handle the confirm alert; ends on the cache page.
    func clearDiskCache(onCachePage: () throws -> Void) throws
}

extension PlaybackDriver {
    // Returns only after two consecutive frames show the same MATCH; previous skips the old screen left over
    // from before the switch.
    func stableMark(excluding previous: String? = nil, timeout: TimeInterval = Timing.stableIdentityTimeout) -> String?
    {
        stableMark(excluding: previous, timeout: timeout, checkEachPoll: {})
    }

    // checkEachPoll runs before every screenshot and ends the wait by throwing.
    func stableMark(
        excluding previous: String? = nil, timeout: TimeInterval = Timing.stableIdentityTimeout,
        checkEachPoll: () throws -> Void
    ) rethrows -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: String?
        var unchanged: String?
        while Date() < deadline {
            try checkEachPoll()
            let identity = StrictE2EPhotoIdentity.classify(png: app.screenshotForFailureEvidence().pngRepresentation)
            let mark = identity.status == .match ? identity.mark : nil
            if let mark, mark == last {
                if mark != previous { return mark }
                unchanged = mark
            }
            last = mark
            RunLoop.current.run(until: Date().addingTimeInterval(Timing.identityPoll))
        }
        return unchanged
    }

    func advance(toAnyOf marks: Set<String>, maxNextPresses: Int = 6) throws -> String {
        var current = stableMark()
        for _ in 0..<maxNextPresses {
            if let current, marks.contains(current) { return current }
            next()
            current = stableMark(excluding: current)
        }
        if let current, marks.contains(current) { return current }
        throw Failure(
            "\(maxNextPresses) next presses never reached \(marks.sorted()); last was \(current ?? "unidentified").")
    }

    // Identify multi-photo screens by the public pattern; a missing probe must not veto a visible two-photo screen.
    func advanceToMultiPhotoScene(in orientation: StepOrientation = .notApplicable, maxNextPresses: Int = 6) throws {
        var observations: [[String: Any]] = []
        for press in 0...maxNextPresses {
            if press > 0 { next() }
            if Wait.held(
                timeout: Timing.multiPhotoWait, hold: Timing.multiPhotoHold,
                {
                    isShowingMultiPhotoScene(in: orientation)
                })
            {
                return
            }
            let current = snapshotNodes { $0.identifier == "slideshow.smartfill.currentManifest.flag" }
            let layers = snapshotNodes { $0.identifier == "slideshow.smartfill.manifest.flag" }
            observations.append([
                "next_presses": press,
                "current_probe_count": current.count,
                "current_scene_types": current.compactMap { manifestField("sceneType", in: $0.label) },
                "layer_probe_count": layers.count,
                "layer_scene_types": layers.compactMap { manifestField("sceneType", in: $0.label) }
            ])
        }
        try StrictE2EVisualEvidence.writeRequiredJSON(
            ["schema": "strict-e2e-multi-scene-search-v1", "observations": observations],
            name: "multi-scene-search-diagnostic.json"
        )
        try Evidence().reject("multi-scene-search", png: app.screenshotForFailureEvidence().pngRepresentation)
        throw Failure(
            "Public fixture: no 2/3-photo scene within \(maxNextPresses) next presses; too few multi-photo frames.")
    }

    private func manifestField(_ key: String, in label: String) -> String? {
        label.split(separator: ";").first { $0.hasPrefix("\(key)=") }.map { String($0.dropFirst(key.count + 1)) }
    }

    // Collect only visible EXIF Fixture text. Take one snapshot of the whole tree so elements cannot vanish while
    // labels are read one by one.
    func visibleOverlayText() -> String {
        snapshotNodes { $0.elementType == .staticText && $0.label.contains("Fixture") }
            .map(\.label)
            .joined(separator: " | ")
    }

    func waitForClearCompletion() {
        XCTAssertTrue(
            Wait.until(timeout: Timing.clearCompletionTimeout) {
                let identifiers = Set(snapshotNodes { $0.identifier.hasPrefix("settings.cache.") }.map(\.identifier))
                return identifiers.contains("settings.cache.status.message")
                    && !identifiers.contains("settings.cache.clearing.status")
            },
            "After confirming the clear, the completion message must appear and the clearing status must go away."
        )
    }

    // Confirm both orientation and two-photo identity from actual screen pixels.
    func isShowingMultiPhotoScene(in orientation: StepOrientation = .notApplicable) -> Bool {
        guard orientation.matches(app.frame.size) else { return false }
        let png = StableFrame.uprightScreenPNG()
        guard let pixels = StableFrame.pixelSize(png), orientation.matches(pixels) else { return false }
        let identity = StrictE2EPhotoIdentity.captureIdentity(png: png)
        return identity.status == .match && (identity.mark?.split(separator: "+").count ?? 0) >= 2
    }

    private func snapshotNodes(where include: (XCUIElementSnapshot) -> Bool) -> [XCUIElementSnapshot] {
        guard let root = try? app.snapshot() else { return [] }
        var matched: [XCUIElementSnapshot] = []
        var pending: [XCUIElementSnapshot] = [root]
        while let node = pending.popLast() {
            if include(node) { matched.append(node) }
            pending.append(contentsOf: node.children)
        }
        return matched
    }
}
