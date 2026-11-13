import Combine
import Foundation

@MainActor
final class ContentPlaybackCoordinator: ObservableObject {
    @Published var flow = AppFlowStateMachine()
    let viewModel: SlideShowViewModel
    private var serverChangeObserver: NSObjectProtocol?
    private var restartTask: Task<Void, Never>?

    init(viewModel: SlideShowViewModel) {
        self.viewModel = viewModel
        serverChangeObserver = NotificationCenter.default.addObserver(
            forName: .serverConfigurationDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restartAfterServerChange()
            }
        }
    }

    deinit {
        if let serverChangeObserver {
            NotificationCenter.default.removeObserver(serverChangeObserver)
        }
        restartTask?.cancel()
    }

    private func restartAfterServerChange() {
        guard flow.route == .slideshow else { return }
        restartTask?.cancel()
        restartTask = Task { [viewModel] in
            await viewModel.firstPreload()
        }
    }

    func settingsDidDisappear() async {
        await viewModel.firstPreload()
        await viewModel.forceReloadCurrentAssetAfterCacheClear()
    }
}
