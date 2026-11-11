import Foundation
import Testing
@testable import immichSlides

@MainActor
struct PlaybackControlsStateTests {
    private let autoHideDelay: Duration = .seconds(12)

    @Test
    func `dismissing the entry hint hides the control bar only for the down action`() {
        for hidesControlBar in [false, true] {
            let state = PlaybackControlsState()
            state.isPlaybackEntryHintVisible = true

            state.dismissEntryHint(hidesControlBar: hidesControlBar)

            #expect(!state.isPlaybackEntryHintVisible)
            #expect(state.isControlBarVisible == !hidesControlBar)
        }
    }

    @Test
    func `the entry hint marker survives new stores using the same defaults`() throws {
        let suiteName = "PlaybackControlsStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PlaybackEntryHintStore(defaults: defaults)

        #expect(!store.hasShownPlaybackEntryHint)
        store.markPlaybackEntryHintShown()

        let reloadedDefaults = try #require(UserDefaults(suiteName: suiteName))
        #expect(PlaybackEntryHintStore(defaults: reloadedDefaults).hasShownPlaybackEntryHint)
    }

    @Test
    func `clearing the entry hint preserves other preferences and permits showing it again`() throws {
        let suiteName = "PlaybackControlsStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PlaybackEntryHintStore(defaults: defaults)
        defaults.set("saved preference", forKey: "unrelated.preference")
        store.markPlaybackEntryHintShown()

        store.clear()

        #expect(!PlaybackEntryHintStore(defaults: defaults).hasShownPlaybackEntryHint)
        #expect(defaults.string(forKey: "unrelated.preference") == "saved preference")
        store.markPlaybackEntryHintShown()
        #expect(store.hasShownPlaybackEntryHint)
    }

    @Test
    func `entry hint markers are isolated between defaults domains`() throws {
        let firstSuiteName = "PlaybackControlsStateTests.\(UUID().uuidString)"
        let secondSuiteName = "PlaybackControlsStateTests.\(UUID().uuidString)"
        let firstDefaults = try #require(UserDefaults(suiteName: firstSuiteName))
        let secondDefaults = try #require(UserDefaults(suiteName: secondSuiteName))
        defer {
            firstDefaults.removePersistentDomain(forName: firstSuiteName)
            secondDefaults.removePersistentDomain(forName: secondSuiteName)
        }
        let firstStore = PlaybackEntryHintStore(defaults: firstDefaults)
        let secondStore = PlaybackEntryHintStore(defaults: secondDefaults)

        firstStore.markPlaybackEntryHintShown()
        #expect(!secondStore.hasShownPlaybackEntryHint)
        secondStore.markPlaybackEntryHintShown()
        firstStore.clear()
        #expect(secondStore.hasShownPlaybackEntryHint)
        #expect(!firstStore.hasShownPlaybackEntryHint)
    }

    enum HintBlocker: CaseIterable {
        case none, notOnboarding, disabled, visible, shown, loading, noAssets, emptyMessage, recoveryMessage
    }

    @Test(arguments: HintBlocker.allCases)
    func `the entry hint waits for ready playback and appears only for an eligible first entry`(
        _ blocker: HintBlocker
    ) {
        let state = PlaybackControlsState()
        state.isPlaybackEntryHintVisible = blocker == .visible

        #expect(
            state.canPresentEntryHint(
                isOnboarding: blocker != .notOnboarding,
                isDisabled: blocker == .disabled,
                hasShown: blocker == .shown,
                isLoading: blocker == .loading,
                hasAssets: blocker != .noAssets,
                hasEmptyMessage: blocker == .emptyMessage,
                hasRecoveryMessage: blocker == .recoveryMessage
            ) == (blocker == .none)
        )
    }

    @Test
    func `the control bar stays visible until its clock reaches the auto hide deadline`() async throws {
        let clock = ControlsClock()
        let state = PlaybackControlsState(sleep: clock.sleep)
        defer { state.cancelAutoHideTimer(); clock.finishAll() }
        let task = try #require(state.resetAutoHideTimer(after: autoHideDelay))
        try #require(await waitUntil { clock.waits.count == 1 })

        clock.advance(by: autoHideDelay / 2)
        #expect(state.isControlBarVisible)
        #expect(clock.waits[0].continuation != nil)
        clock.advance(by: autoHideDelay / 2)
        await task.value

        #expect(!state.isControlBarVisible)
    }

    @Test
    func `a renewed countdown ignores the cancelled clocks late completion`() async throws {
        let clock = ControlsClock()
        let state = PlaybackControlsState(sleep: clock.sleep)
        defer { state.cancelAutoHideTimer(); clock.finishAll() }
        let oldTask = try #require(state.resetAutoHideTimer(after: autoHideDelay))
        try #require(await waitUntil { clock.waits.count == 1 })
        clock.advance(by: autoHideDelay / 2)

        let newTask = try #require(state.resetAutoHideTimer(after: autoHideDelay))
        try #require(await waitUntil { clock.waits.count == 2 })
        clock.advance(by: autoHideDelay / 2)
        await oldTask.value
        #expect(state.isControlBarVisible)
        #expect(clock.waits[1].continuation != nil)

        clock.advance(by: autoHideDelay / 2)
        await newTask.value
        #expect(!state.isControlBarVisible)
    }

    @Test
    func `a visible entry hint prevents a countdown until it is dismissed`() async throws {
        let clock = ControlsClock()
        let state = PlaybackControlsState(sleep: clock.sleep)
        defer { state.cancelAutoHideTimer(); clock.finishAll() }
        let oldTask = try #require(state.resetAutoHideTimer(after: autoHideDelay))
        try #require(await waitUntil { clock.waits.count == 1 })
        state.isPlaybackEntryHintVisible = true

        let blockedTask = state.resetAutoHideTimer(after: autoHideDelay)
        #expect(blockedTask == nil)
        if let blockedTask {
            try #require(await waitUntil { clock.waits.count == 2 })
            clock.advance(by: autoHideDelay)
            await blockedTask.value
        }
        clock.advance(by: autoHideDelay)
        await oldTask.value
        #expect(state.isControlBarVisible)

        state.dismissEntryHint()
        let expectedWaitCount = clock.waits.count + 1
        let resumedTask = try #require(state.resetAutoHideTimer(after: autoHideDelay))
        try #require(await waitUntil { clock.waits.count == expectedWaitCount })
        clock.advance(by: autoHideDelay)
        await resumedTask.value
        #expect(!state.isControlBarVisible)
    }

    @Test
    func `cancelling on disappearance rejects a late clock completion`() async throws {
        let clock = ControlsClock()
        let state = PlaybackControlsState(sleep: clock.sleep)
        defer { state.cancelAutoHideTimer(); clock.finishAll() }
        let task = try #require(state.resetAutoHideTimer(after: autoHideDelay))
        try #require(await waitUntil { clock.waits.count == 1 })

        state.cancelAutoHideTimer()
        clock.advance(by: autoHideDelay)
        await task.value

        #expect(state.isControlBarVisible)
    }
}

@MainActor
private final class ControlsClock {
    struct Wait {
        let deadline: Duration
        var continuation: CheckedContinuation<Void, Never>?
    }

    private var now: Duration = .zero
    private(set) var waits: [Wait] = []

    // Deliberately complete cancelled sleeps too, so the App must reject late delivery itself.
    func sleep(for delay: Duration) async throws {
        await withCheckedContinuation { continuation in
            waits.append(Wait(deadline: now + delay, continuation: continuation))
        }
    }

    func advance(by duration: Duration) {
        now += duration
        for index in waits.indices where waits[index].deadline <= now {
            waits[index].continuation?.resume()
            waits[index].continuation = nil
        }
    }

    func finishAll() {
        for index in waits.indices {
            waits[index].continuation?.resume()
            waits[index].continuation = nil
        }
    }
}
