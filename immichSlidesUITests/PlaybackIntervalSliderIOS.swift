import XCTest

#if os(iOS)
@MainActor
enum PlaybackIntervalSliderIOS {
    static let minimumSeconds = Int(TestWait.seconds(.product(5)))
    static let maximumSeconds = Int(TestWait.seconds(.product(30)))
    private static let adjustmentAttemptLimit = 5
    private static let readbackTimeoutSeconds = TestWait.seconds(.product(0.4))

    static func adjust(
        in app: XCUIApplication,
        targetSeconds: Int,
        accepting accepts: (Int) -> Bool
    ) -> Int? {
        let slider = app.sliders["settings.playback.interval.slider"]
        XCTAssertTrue(
            slider.waitForPublicElement("settings.playback.interval.slider", timeout: TestWait.seconds(.product(8))),
            "Playback settings must provide the interval slider.")
        XCTAssertTrue(slider.isEnabled, "The interval cannot be changed while autoplay is off.")
        let range = Double(maximumSeconds - minimumSeconds)
        var position = Double(targetSeconds - minimumSeconds) / range
        slider.adjustForFailureEvidence(toNormalizedSliderPosition: position)
        for attempt in 0..<adjustmentAttemptLimit {
            var observed: Int?
            if Wait.until(
                timeout: readbackTimeoutSeconds,
                {
                    observed = displayedSeconds(in: app)
                    return observed.map(accepts) ?? false
                })
            {
                return observed
            }
            guard let observed, attempt + 1 < adjustmentAttemptLimit else { return observed }
            if targetSeconds == minimumSeconds || targetSeconds == maximumSeconds {
                dragEndpoint(slider, observedSeconds: observed, targetSeconds: targetSeconds)
            } else {
                // Correct the last requested position using only the app's displayed seconds.
                position = min(max(position + Double(targetSeconds - observed) / range, 0), 1)
                slider.adjustForFailureEvidence(toNormalizedSliderPosition: position)
            }
        }
        return nil
    }

    static func readSeconds(in app: XCUIApplication) -> Int? {
        var observed: Int?
        _ = Wait.until(timeout: TestWait.seconds(.product(2))) {
            observed = displayedSeconds(in: app)
            return observed != nil
        }
        return observed
    }

    private static func displayedSeconds(in app: XCUIApplication) -> Int? {
        let interval = app.staticTexts["settings.playback.interval.value"]
        guard interval.exists else { return nil }
        let label = interval.label
        guard label.range(of: #"^[0-9]+ 秒$"#, options: .regularExpression) != nil else { return nil }
        return Int(label.split(separator: " ").first ?? "")
    }

    private static func dragEndpoint(_ slider: XCUIElement, observedSeconds: Int, targetSeconds: Int) {
        // Start on the measured thumb and finish beyond the track, as in the first-wake endpoint proof.
        let frame = slider.frame
        let thumbInset = frame.height / 2
        let trackWidth = max(frame.width - 2 * thumbInset, 0)
        let position = CGFloat(observedSeconds - minimumSeconds) / CGFloat(maximumSeconds - minimumSeconds)
        let origin = slider.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: thumbInset + position * trackWidth, dy: frame.height / 2))
        let endOffset = targetSeconds == minimumSeconds ? -thumbInset : frame.width + thumbInset
        let end = origin.withOffset(CGVector(dx: endOffset, dy: frame.height / 2))
        start.press(forDuration: TestWait.seconds(.product(0.05)), thenDragTo: end)
    }
}
#endif
