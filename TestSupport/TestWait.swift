import Foundation

/// A test-only timeline. Completed waits stop at return; action age continues until the failure.
struct FirstFailureTimeline {
    var action = "none"
    private var issuedAt: TimeInterval?
    private var returnedAt: TimeInterval?
    private var waitStartedAt: TimeInterval?
    private var waitReturnedAt: TimeInterval?
    private var waitDeadlineSeconds: TimeInterval?
    private var activeWaits: [(startedAt: TimeInterval, deadlineSeconds: TimeInterval)] = []

    mutating func actionIssued(_ action: String, at time: TimeInterval) {
        self.action = action
        issuedAt = time
        returnedAt = nil
        if waitReturnedAt != nil {
            waitStartedAt = nil
            waitReturnedAt = nil
            waitDeadlineSeconds = nil
        }
    }

    mutating func actionReturned(at time: TimeInterval) { returnedAt = time }

    mutating func waitStarted(seconds: TimeInterval, at time: TimeInterval) {
        activeWaits.append((time, seconds))
        waitStartedAt = time
        waitReturnedAt = nil
        waitDeadlineSeconds = seconds
    }

    mutating func waitReturned(at time: TimeInterval) {
        guard activeWaits.popLast() != nil else { return }
        if let outer = activeWaits.last {
            waitStartedAt = outer.startedAt
            waitDeadlineSeconds = outer.deadlineSeconds
            waitReturnedAt = nil
        } else {
            waitReturnedAt = time
        }
    }

    func timing(at time: TimeInterval) -> [String: Any] {
        func measured(_ value: TimeInterval?) -> Any {
            guard let value, value.isFinite, (0...86_400).contains(value) else { return NSNull() }
            return value
        }
        return [
            "since_action_issued_seconds": measured(issuedAt.map { time - $0 }),
            "since_action_returned_seconds": measured(returnedAt.map { time - $0 }),
            "action_duration_seconds": measured(issuedAt.flatMap { issued in returnedAt.map { $0 - issued } }),
            "wait_elapsed_seconds": measured(waitStartedAt.map { (waitReturnedAt ?? time) - $0 }),
            "deadline_seconds": measured(waitDeadlineSeconds),
            "capture_request_seconds": NSNull(), "capture_return_seconds": NSNull(), "state_age_seconds": NSNull()
        ]
    }
}

enum FirstFailureContext {
    struct AlbumCaptureGate {
        enum Phase: String {
            case unknown, empty, stablePhoto, grace, transition, loading, incomingFromLoading, paused, sourceError
        }

        let stable: Bool?
        let paused: Bool?
        let entryHintHidden: Bool?
        let advanced: Bool?
        let layersChanged: Bool?
        let manifestComplete: Bool?
        let phase: Phase

        var projection: [String: Any] {
            func observed(_ value: Bool?) -> Any { value.map { $0 as Any } ?? NSNull() }
            return [
                "kind": "album-capture", "stable": observed(stable), "paused": observed(paused),
                "entry_hint_hidden": observed(entryHintHidden), "advanced": observed(advanced),
                "layers_changed": observed(layersChanged), "manifest_complete": observed(manifestComplete),
                "phase": phase.rawValue
            ]
        }
    }

    static var isEnabled: Bool { ProcessInfo.processInfo.environment["STRICT_E2E_FIRST_FAILURE_ENABLED"] == "1" }
    private static let lock = NSLock()
    private static var timeline = FirstFailureTimeline()
    private static var step = "unknown"
    private static var element = "unknown"
    private static var gate: AlbumCaptureGate?

    static func reset() {
        guard isEnabled else { return }
        lock.lock()
        defer { lock.unlock() }
        timeline = FirstFailureTimeline()
        step = "unknown"
        element = "unknown"
        gate = nil
    }

    static func snapshot() -> (timeline: FirstFailureTimeline, step: String, element: String, gate: AlbumCaptureGate?) {
        lock.lock()
        defer { lock.unlock() }
        return (timeline, step, element, gate)
    }

    /// Attach timeout facts; per-test reset protects against XCTest aborts that skip the defer.
    static func withAlbumCaptureGate(_ gate: AlbumCaptureGate, _ failure: () -> Void) {
        guard isEnabled else { failure(); return }
        lock.lock()
        self.gate = gate
        lock.unlock()
        defer {
            lock.lock()
            self.gate = nil
            lock.unlock()
        }
        failure()
    }

    static func mark(_ step: String, element: String = "unknown") {
        guard isEnabled else { return }
        lock.lock()
        defer { lock.unlock() }
        self.step = step
        self.element = element
    }

    static func beginWait(seconds: TimeInterval) {
        guard isEnabled else { return }
        lock.lock()
        defer { lock.unlock() }
        timeline.waitStarted(seconds: seconds, at: ProcessInfo.processInfo.systemUptime)
    }

    static func endWait() {
        guard isEnabled else { return }
        lock.lock()
        defer { lock.unlock() }
        timeline.waitReturned(at: ProcessInfo.processInfo.systemUptime)
    }

    static func action<T>(_ name: String, _ operation: () throws -> T) rethrows -> T {
        guard isEnabled else { return try operation() }
        lock.lock()
        timeline.actionIssued(name, at: ProcessInfo.processInfo.systemUptime)
        lock.unlock()
        defer {
            lock.lock()
            timeline.actionReturned(at: ProcessInfo.processInfo.systemUptime)
            lock.unlock()
        }
        return try operation()
    }
}

/// Test-target-only budgets. Product deadlines and observation windows always use their base duration.
enum TestWait {
    /// Navigation has no product response limit. All steps share this unscaled monotonic deadline.
    @MainActor
    static func hangGuard(
        timeoutSeconds: TimeInterval = 60,
        nowForTesting: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pauseForTesting: @escaping (TimeInterval) -> Void = {
            RunLoop.current.run(until: Date().addingTimeInterval($0))
        }
    ) -> HangGuard {
        HangGuard(timeoutSeconds: timeoutSeconds, now: nowForTesting, pause: pauseForTesting)
    }

    @MainActor
    final class HangGuard {
        private let deadline: TimeInterval
        private let now: () -> TimeInterval
        private let pause: (TimeInterval) -> Void

        fileprivate init(
            timeoutSeconds: TimeInterval, now: @escaping () -> TimeInterval,
            pause: @escaping (TimeInterval) -> Void
        ) {
            precondition(timeoutSeconds.isFinite && timeoutSeconds >= 0)
            self.now = now
            self.pause = pause
            deadline = now() + timeoutSeconds
        }

        var remainingSeconds: TimeInterval { max(.zero, deadline - now()) }

        /// Child steps can issue different necessary actions, but cannot refresh the navigation deadline.
        func transaction() -> Transaction { Transaction(guardWait: self) }

        @MainActor
        final class Transaction {
            private let guardWait: HangGuard
            private var didIssueAction = false
            private var hasPostActionObservation = false

            fileprivate init(guardWait: HangGuard) { self.guardWait = guardWait }

            @discardableResult
            func perform(_ name: String, _ action: () -> Void) -> Bool {
                guard !didIssueAction, guardWait.remainingSeconds > 0 else { return false }
                didIssueAction = true
                FirstFailureContext.action(name, action)
                hasPostActionObservation = true
                return true
            }

            /// One fresh observation for optional branches; absence never consumes the full guard.
            func probe(_ condition: () -> Bool) -> Bool { query(condition) == true }

            /// A query started in time may return satisfied late. Only an issued action grants one extra read.
            func query<Value>(_ observation: () -> Value) -> Value? {
                guard guardWait.remainingSeconds > 0 || hasPostActionObservation else { return nil }
                hasPostActionObservation = false
                return observation()
            }

            func until(
                pollIntervalSeconds: TimeInterval = TestWait.defaultPollIntervalSeconds, _ condition: () -> Bool
            ) -> Bool {
                precondition(pollIntervalSeconds.isFinite && pollIntervalSeconds > 0)
                FirstFailureContext.beginWait(seconds: guardWait.remainingSeconds)
                defer { FirstFailureContext.endWait() }
                while let isSatisfied = query(condition) {
                    if isSatisfied { return true }
                    let remaining = guardWait.remainingSeconds
                    guard remaining > 0 else { return false }
                    guardWait.pause(min(pollIntervalSeconds, remaining))
                }
                return false
            }
        }
    }

    enum Budget {
        case infrastructure(TimeInterval)
        case product(TimeInterval)
    }

    static let factorEnvironmentKey = "IMMICHSLIDES_TEST_WAIT_FACTOR"
    private static let defaultPollIntervalSeconds = TestWait.seconds(.product(0.1))
    private static let infrastructureFactor: Double = {
        let raw = ProcessInfo.processInfo.environment[factorEnvironmentKey] ?? "1"
        guard let factor = Double(raw), factor.isFinite, (1...4).contains(factor) else {
            preconditionFailure("Test wait factor must be finite and between 1 and 4")
        }
        print("TestWait infrastructure_factor=\(factor) product_factor=1")
        return factor
    }()

    static func seconds(_ budget: Budget) -> TimeInterval {
        let base: TimeInterval
        let factor: Double
        switch budget {
        case .infrastructure(let duration):
            base = duration
            factor = infrastructureFactor
        case .product(let duration):
            base = duration
            factor = 1
        }
        precondition(base.isFinite && base >= 0 && (base * factor).isFinite)
        return base * factor
    }

    /// Poll cadence stays fixed; only the infrastructure deadline scales.
    @MainActor
    static func until(
        _ budget: Budget, pollIntervalSeconds: TimeInterval = defaultPollIntervalSeconds, _ condition: () -> Bool
    ) -> Bool {
        precondition(pollIntervalSeconds.isFinite && pollIntervalSeconds > 0)
        FirstFailureContext.beginWait(seconds: seconds(budget))
        defer { FirstFailureContext.endWait() }
        let deadline = ProcessInfo.processInfo.systemUptime + seconds(budget)
        while true {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            let isSatisfied = condition()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            if isSatisfied { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(min(pollIntervalSeconds, remaining)))
        }
    }

    /// Observe the complete product window, failing as soon as the invariant is violated.
    @MainActor
    static func observe(
        seconds duration: TimeInterval, pollIntervalSeconds: TimeInterval = defaultPollIntervalSeconds,
        _ condition: () -> Bool
    ) -> Bool {
        precondition(pollIntervalSeconds.isFinite && pollIntervalSeconds > 0)
        FirstFailureContext.beginWait(seconds: seconds(.product(duration)))
        defer { FirstFailureContext.endWait() }
        let deadline = ProcessInfo.processInfo.systemUptime + seconds(.product(duration))
        while true {
            guard condition() else { return false }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(min(pollIntervalSeconds, remaining)))
        }
    }
}
