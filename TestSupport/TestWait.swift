import Foundation

/// Test-target-only budgets. Product deadlines and observation windows always use their base duration.
enum TestWait {
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
        let deadline = ProcessInfo.processInfo.systemUptime + seconds(budget)
        while true {
            if condition() { return true }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
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
        let deadline = ProcessInfo.processInfo.systemUptime + seconds(.product(duration))
        while true {
            guard condition() else { return false }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(min(pollIntervalSeconds, remaining)))
        }
    }
}
