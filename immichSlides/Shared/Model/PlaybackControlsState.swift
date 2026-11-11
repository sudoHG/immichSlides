import Combine
import Foundation

@MainActor
final class PlaybackControlsState: ObservableObject {
    nonisolated static let autoHideDelay: Duration = .seconds(8)

    @Published var isControlBarVisible = true
    @Published var isPlaybackEntryHintVisible = false

    private var autoHideTask: Task<Void, Never>?
    private let sleep: @MainActor (Duration) async throws -> Void

    init(sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
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
    func resetAutoHideTimer(after delay: Duration = autoHideDelay) -> Task<Void, Never>? {
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
