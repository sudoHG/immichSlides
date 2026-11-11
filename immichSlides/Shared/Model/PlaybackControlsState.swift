import Combine
import Foundation

@MainActor
final class PlaybackControlsState: ObservableObject {
    @Published var isControlBarVisible = true
    @Published var isPlaybackEntryHintVisible = false

    private var autoHideTask: Task<Void, Never>?
    private let sleep: @MainActor (Duration) async throws -> Void

    init(sleepForTesting: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleepForTesting
    }

    func canPresentEntryHint(
        isOnboarding: Bool,
        isDisabled: Bool,
        hasShown: Bool,
        isLoading: Bool,
        hasAssets: Bool,
        hasEmptyMessage: Bool,
        hasRecoveryMessage: Bool
    ) -> Bool {
        isOnboarding && !isDisabled && !isPlaybackEntryHintVisible && !hasShown
            && !isLoading && hasAssets && !hasEmptyMessage && !hasRecoveryMessage
    }

    func cancelAutoHideTimer() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    func dismissEntryHint(hidesControlBar: Bool = false) {
        isPlaybackEntryHintVisible = false
        if hidesControlBar {
            isControlBarVisible = false
        }
    }

    @discardableResult
    func resetAutoHideTimer(after delay: Duration) -> Task<Void, Never>? {
        cancelAutoHideTimer()
        guard !isPlaybackEntryHintVisible else { return nil }
        let task = Task {
            try? await sleep(delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.isControlBarVisible = false
            }
        }
        autoHideTask = task
        return task
    }
}
