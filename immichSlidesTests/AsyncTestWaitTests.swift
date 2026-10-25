import Foundation
import Testing

@MainActor
@Suite
struct AsyncTestWaitTests {
    @Test(arguments: [
        "late-query", "expired-query", "late-action", "missing-outcome", "single-action", "shared-deadline", "probe"
    ])
    func `hang guards accept in flight success without starting expired work or repeating actions`(scenario: String) {
        var now = 10.0
        var queries = 0
        var actions = 0
        var pauses = 0
        let guardSeconds = TestWait.seconds(.product(2))
        let navigation = TestWait.hangGuard(
            timeoutSeconds: guardSeconds, nowForTesting: { now },
            pauseForTesting: { seconds in
                pauses += 1
                now += seconds
            })
        let transaction = navigation.transaction()
        switch scenario {
        case "late-query":
            #expect(
                transaction.until {
                    queries += 1; now = 13; return true
                })
            #expect(queries == 1)
        case "expired-query":
            now = 12
            #expect(
                !transaction.until {
                    queries += 1; return true
                })
            #expect(queries == 0)
        case "late-action", "missing-outcome":
            #expect(
                transaction.perform("tap") {
                    actions += 1; now = 13
                })
            #expect(!transaction.perform("tap") { actions += 1 })
            #expect(
                transaction.until {
                    queries += 1; return scenario == "late-action"
                } == (scenario == "late-action"))
            #expect(
                !transaction.probe {
                    queries += 1; return true
                })
            #expect(actions == 1)
            #expect(queries == 1)
        case "shared-deadline":
            now = 11.5
            let child = navigation.transaction()
            #expect(
                !child.until {
                    queries += 1; return false
                })
            #expect(!transaction.perform("tap") { actions += 1 })
            #expect(
                !transaction.probe {
                    queries += 1; return true
                })
            #expect(now == 12)
            #expect(actions == 0)
        case "single-action":
            #expect(transaction.perform("tap") { actions += 1 })
            #expect(!transaction.perform("tap") { actions += 1 })
            #expect(actions == 1)
        default:
            #expect(
                !transaction.probe {
                    queries += 1; return false
                })
            #expect(queries == 1)
            #expect(pauses == 0)
            #expect(now == 10)
        }
    }

    @Test(arguments: ["expired", "late", "timely"])
    func `product deadline accepts success only when polling finishes before expiry`(scenario: String) {
        var checks = 0
        let satisfied = TestWait.until(.product(scenario == "expired" ? 0 : (scenario == "late" ? 0.01 : 1))) {
            checks += 1
            // A synchronous UI predicate can finish after its budget even when it reports success.
            if scenario == "late" { Thread.sleep(forTimeInterval: TestWait.seconds(.product(0.03))) }
            return true
        }
        #expect(satisfied == (scenario == "timely"))
        #expect(checks == (scenario == "expired" ? 0 : 1))
    }

    @Test func `returns true as soon as the condition holds`() async {
        var checks = 0
        let satisfied = await waitUntil {
            checks += 1
            return checks >= 3
        }
        #expect(satisfied)
        #expect(checks == 3)
    }

    @Test(.timeLimit(.minutes(1)))
    func `returns false instead of hanging when the condition never holds`() async {
        let satisfied = await waitUntil(timeout: .milliseconds(200)) { false }
        #expect(!satisfied)
    }

    @Test func `sees state changed by another main actor task while yielding`() async {
        var isConditionSatisfied = false
        Task { @MainActor in isConditionSatisfied = true }
        let satisfied = await waitUntil { isConditionSatisfied }
        #expect(satisfied)
    }

    @Test func `polls with sleep when an interval is given`() async {
        var isConditionSatisfied = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            isConditionSatisfied = true
        }
        let satisfied = await waitUntil(pollInterval: .milliseconds(1)) { isConditionSatisfied }
        #expect(satisfied)
    }
}
