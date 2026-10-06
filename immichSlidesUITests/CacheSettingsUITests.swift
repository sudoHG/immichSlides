import XCTest

// E2E-P2-02. iPad only runs a cache page smoke test.
final class CacheSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    #if os(iOS)
    @MainActor
    func testClearDiskCacheFromSettingsIOS() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("Runs on iPhone only; iPad is covered by testCacheSettingsPageSmokeIPad.")
        }
        XCUIDevice.shared.orientation = .portrait
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }
        try runCacheClearFlow(IOSDriver(app: app), input: input)
    }

    // Covers cache completion and rendered return; full P2-02 still requires the disk-usage review.
    @MainActor
    func testCacheSettingsPageSmokeIPad() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Runs on iPad only.")
        }
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }
        let driver = IOSDriver(app: app)
        driver.launchToPlayback(input: input)
        // Like the iPhone flow: a paused single photo keeps the returned frame classifiable.
        driver.applyPlaybackSettings([.displayMode(isSinglePhoto: true)])
        driver.pause()
        try driver.clearDiskCache(onCachePage: {})
        let evidence = Evidence()
        try evidence.capture("cache-page-smoke", from: app)
        driver.returnToPlayback()
        try evidence.capture("cache-returned", from: app) { $0.status == .match }
    }
    #endif

    #if os(tvOS)
    @MainActor
    func testClearDiskCacheFromSettingsTVOS() throws {
        guard UIDevice.current.userInterfaceIdiom == .tv else {
            XCTFail("The tvOS cache-clearing test must run on a tvOS Simulator.")
            return
        }
        let input = try requireStrictE2EInput()
        let app = try launchStrictE2EApp()
        defer { app.terminate() }
        try runCacheClearFlow(TVDriver(app: app), input: input)
    }
    #endif

    // Page screenshots let a separate human reviewer check that disk usage is above 0 before clearing, 0 after, and
    // that a success message is shown.
    @MainActor
    private func runCacheClearFlow(_ driver: some PlaybackDriver, input: StrictE2EInput) throws {
        let evidence = Evidence()
        driver.launchToPlayback(input: input)
        driver.applyPlaybackSettings([.interval30Seconds, .displayMode(isSinglePhoto: true)])
        driver.pause()
        guard driver.stableMark() != nil else {
            throw Failure("No recognizable public photo was shown before clearing.")
        }
        try driver.clearDiskCache(onCachePage: {
            try evidence.capture("cache-before-confirm", from: driver.app)
        })
        try evidence.capture("cache-cleared", from: driver.app)

        driver.returnToPlayback()
        try evidence.capture("cache-returned", from: driver.app) { $0.status == .match }
    }
}
