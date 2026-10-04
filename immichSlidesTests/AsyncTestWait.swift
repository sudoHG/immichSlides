import Foundation

/// Default deadline for `waitUntil`. It only has to stop a hang: parallel suites can hold the main actor for over 10 seconds.
let defaultAsyncTestWaitTimeout: Duration = .seconds(30)

/// Re-checks `condition` until it holds and returns `true`, or returns `false` once `timeout` has passed.
/// Without `pollInterval` it yields between checks, matching a plain `while !condition { await Task.yield() }` loop.
@MainActor
func waitUntil(
    timeout: Duration = defaultAsyncTestWaitTimeout,
    pollInterval: Duration? = nil,
    _ condition: () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { return condition() }
        if let pollInterval {
            try? await Task.sleep(for: pollInterval)
        } else {
            await Task.yield()
        }
    }
    return true
}
