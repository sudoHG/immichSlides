import Testing

@MainActor
@Suite
struct AsyncTestWaitTests {
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
