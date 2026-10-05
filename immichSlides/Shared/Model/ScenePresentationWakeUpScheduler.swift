import Foundation

/// Executes reducer deadlines without owning presentation policy or the session engine.
@MainActor
final class ScenePresentationWakeUpScheduler {
    private struct Key: Equatable {
        let generation: UUID
        let deadline: TimeInterval
    }

    private static let nanosecondsPerSecond: Double = 1_000_000_000
    private let now: @MainActor () -> TimeInterval
    private let sleep: @MainActor (UInt64) async throws -> Void
    private let deliver: @MainActor (PlaybackSessionEngine.ScenePresentationEvent, TimeInterval) -> Void
    private var wakeUpTask: Task<Void, Never>?
    private var wakeUpKey: Key?

    init(
        now: @escaping @MainActor () -> TimeInterval,
        sleep: @escaping @MainActor (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        deliver: @escaping @MainActor (PlaybackSessionEngine.ScenePresentationEvent, TimeInterval) -> Void
    ) {
        self.now = now
        self.sleep = sleep
        self.deliver = deliver
    }

    deinit {
        wakeUpTask?.cancel()
    }

    func schedule(generation: UUID, deadline: TimeInterval) {
        guard let key = replaceKey(generation: generation, deadline: deadline) else { return }
        let delay = max(0, deadline - now())
        wakeUpTask = Task { @MainActor [weak self, sleep] in
            try? await sleep(UInt64((delay * Self.nanosecondsPerSecond).rounded(.up)))
            guard let self, !Task.isCancelled, self.wakeUpKey == key else { return }
            self.wakeUpTask = nil
            self.wakeUpKey = nil
            self.deliver(.wakeUp(generation: generation, deadline: deadline), self.now())
        }
    }

    func cancel(generation: UUID) {
        guard wakeUpKey?.generation == generation else { return }
        reset()
    }

    func reset() {
        wakeUpTask?.cancel()
        wakeUpTask = nil
        wakeUpKey = nil
    }

    private func replaceKey(generation: UUID, deadline: TimeInterval) -> Key? {
        let key = Key(generation: generation, deadline: deadline)
        guard wakeUpKey != key else { return nil }
        reset()
        wakeUpKey = key
        return key
    }

    #if DEBUG
    func scheduleWithoutSleepingForTesting(generation: UUID, deadline: TimeInterval) {
        _ = replaceKey(generation: generation, deadline: deadline)
    }

    /// Preserves the existing virtual-time tests' explicit delivery at the scheduled deadline.
    func fireScheduledWakeUpForTesting() -> TimeInterval? {
        guard let key = wakeUpKey else { return nil }
        reset()
        deliver(.wakeUp(generation: key.generation, deadline: key.deadline), key.deadline)
        return key.deadline
    }
    #endif
}
