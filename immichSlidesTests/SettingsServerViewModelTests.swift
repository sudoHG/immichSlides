import Foundation
import Testing
@testable import immichSlides

@Suite(.serialized, .sharedRuntimeIsolation)
struct SettingsServerViewModelTests {
    private let retryDelayNanoseconds: UInt64 = 1_000_000_000
    private let settlingYieldCount: Int = 6

    @Test
    @MainActor
    func `invalid input uses the connection test failed alert title`() {
        let viewModel = SettingsServerViewModel()
        viewModel.serverURL = "foo://invalid-host"
        viewModel.apiKey = "demo-key"

        viewModel.testConnection()

        #expect(viewModel.shouldShowErrorAlert)
        #expect(viewModel.errorAlertTitle == String(localized: "Connection test failed"))
        #expect(viewModel.errorMessage == String(localized: "Server URL must start with http or https"))
    }

    @Test
    @MainActor
    func `pending permission state resumes testing automatically when the app becomes active and eventually succeeds`()
        async
    {
        let attemptCounter = ConnectionAttemptCounter()
        let delayGate = RetryDelayGate()
        let waitingMessage = "正在等待系统网络权限；如果系统弹出权限提示，请选择允许，应用会自动继续测试。"
        let waitingForPermissionResult = ImmichServer.ConnectionTestResult(
            kind: .waitingForPermission,
            message: waitingMessage
        )
        let successfulResult = ImmichServer.ConnectionTestResult(kind: .success, message: nil)

        let viewModel = SettingsServerViewModel(
            connectionTestActionForTesting: { _, _, _ in
                let attempt = await attemptCounter.nextValue()
                if attempt == 1 {
                    return waitingForPermissionResult
                }

                return successfulResult
            },
            delayActionForTesting: { _ in
                await delayGate.wait()
            },
            automaticRetryDelayScheduleForTesting: [retryDelayNanoseconds]
        )

        viewModel.serverURL = "http://192.168.1.20:2283"
        viewModel.apiKey = "demo-key"

        viewModel.testConnection()
        await settleAsyncWork()

        #expect(viewModel.isTestingConnection)
        #expect(viewModel.testingStatusMessage == waitingMessage)
        #expect(!viewModel.shouldShowErrorAlert)
        #expect(await attemptCounter.currentValue() == 1)

        viewModel.resumePendingConnectionTestIfNeeded()
        await settleAsyncWork()
        await delayGate.releaseAll()
        await settleAsyncWork()

        #expect(await attemptCounter.currentValue() == 2)
        #expect(viewModel.isConnectionVerified)
        #expect(!viewModel.isTestingConnection)
        #expect(viewModel.statusMessage == String(localized: "Connection test passed"))
        #expect(!viewModel.shouldShowErrorAlert)
    }

    @Test
    @MainActor
    func `a late input notification from the parent page keeps the saved success state of the current revision`() async
    {
        let viewModel = SettingsServerViewModel(
            saveServerConfigActionForTesting: { _, _ in (true, nil) }
        )
        viewModel.serverURL = "https://demo.example.com"
        viewModel.apiKey = "fixture-a"
        await viewModel.saveServerConfig().value

        viewModel.invalidateVerification()

        #expect(viewModel.isConnectionVerified)
        #expect(viewModel.statusMessage == String(localized: "Configuration saved"))
    }

    @Test
    @MainActor
    func `a connection test failure result can override the alert title`() async {
        let failureResult = ImmichServer.ConnectionTestResult(
            kind: .failure,
            message: "缺少 asset.read，immichSlides 无法读取照片列表。请在 Immich 的 API Key 权限中启用 asset.read 后重试。",
            alertTitle: "API Key 权限不足"
        )
        let viewModel = SettingsServerViewModel(
            connectionTestActionForTesting: { _, _, _ in failureResult }
        )

        viewModel.serverURL = "https://demo.example.com"
        viewModel.apiKey = "demo-key"

        viewModel.testConnection()
        await settleAsyncWork()

        #expect(viewModel.shouldShowErrorAlert)
        #expect(viewModel.errorAlertTitle == "API Key 权限不足")
        #expect(
            viewModel.errorMessage == "缺少 asset.read，immichSlides 无法读取照片列表。请在 Immich 的 API Key 权限中启用 asset.read 后重试。")
    }

    @Test
    @MainActor
    func `connection test stage events update the progress message`() async {
        let successfulResult = ImmichServer.ConnectionTestResult(
            kind: .success,
            message: "连接测试通过，但部分筛选功能需要额外权限：\n相册筛选不可用：缺少 album.read。"
        )
        let viewModel = SettingsServerViewModel(
            connectionTestActionForTesting: { _, _, progress in
                progress?(.checkingAssetRead)
                progress?(.checkingImagePreview)
                progress?(.checkingFullsizeImage)
                progress?(.checkingOptionalFilters)
                return successfulResult
            }
        )

        viewModel.serverURL = "https://demo.example.com"
        viewModel.apiKey = "demo-key"

        viewModel.testConnection()
        await settleAsyncWork()

        #expect(viewModel.isConnectionVerified)
        #expect(viewModel.statusMessage == "连接测试通过，但部分筛选功能需要额外权限：\n相册筛选不可用：缺少 album.read。")
        #expect(viewModel.testingStatusMessage == String(localized: "Testing connection..."))
    }

    @Test
    @MainActor
    func `save failure shows the save failed alert title and does not mark the save successful`() async {
        let viewModel = SettingsServerViewModel(
            saveServerConfigActionForTesting: { _, _ in
                (false, "x")
            }
        )
        viewModel.serverURL = "https://demo.example.com"
        viewModel.apiKey = "demo-key"

        let saveTask = viewModel.saveServerConfig()
        await saveTask.value

        #expect(viewModel.shouldShowErrorAlert)
        #expect(viewModel.errorAlertTitle == String(localized: "Save Failed"))
        #expect(viewModel.errorMessage == "x")
        #expect(viewModel.didSaveConfig == false)
    }

    @Test(arguments: SaveInputEdit.allCases)
    @MainActor
    func `editing input during an in flight save prevents its stale success from restoring the current form state`(
        _ edit: SaveInputEdit
    ) async {
        let saveGate = SaveCompletionGate()
        let viewModel = SettingsServerViewModel(
            saveServerConfigActionForTesting: { _, _ in
                await saveGate.waitForRelease()
                return (true, nil)
            }
        )
        viewModel.serverURL = "https://demo.example.com"
        viewModel.apiKey = "fixture-a"
        viewModel.isConnectionVerified = true

        let saveTask = viewModel.saveServerConfig()
        await saveGate.waitUntilStarted()
        edit.apply(to: viewModel)
        await saveGate.release()
        await saveTask.value

        #expect(!viewModel.isConnectionVerified)
        #expect(viewModel.statusMessage.isEmpty)
        #expect(!viewModel.didSaveConfig)
        #expect(!viewModel.shouldShowErrorAlert)
    }

    @Test(arguments: SaveInputEdit.allCases)
    @MainActor
    func `editing input during an in flight save prevents its stale failure from alerting the current form`(
        _ edit: SaveInputEdit
    ) async {
        let saveGate = SaveCompletionGate()
        let viewModel = SettingsServerViewModel(
            saveServerConfigActionForTesting: { _, _ in
                await saveGate.waitForRelease()
                return (false, "Save request failed")
            }
        )
        viewModel.serverURL = "https://demo.example.com"
        viewModel.apiKey = "fixture-a"
        viewModel.isConnectionVerified = true

        let saveTask = viewModel.saveServerConfig()
        await saveGate.waitUntilStarted()
        edit.apply(to: viewModel)
        await saveGate.release()
        await saveTask.value

        #expect(!viewModel.isConnectionVerified)
        #expect(viewModel.statusMessage.isEmpty)
        #expect(!viewModel.didSaveConfig)
        #expect(!viewModel.shouldShowErrorAlert)
    }

    @Test
    @MainActor
    func `save success updates the current form when input was not edited`() async {
        let viewModel = SettingsServerViewModel(
            saveServerConfigActionForTesting: { _, _ in (true, nil) }
        )
        viewModel.serverURL = "https://demo.example.com"
        viewModel.apiKey = "fixture-a"

        let saveTask = viewModel.saveServerConfig()
        await saveTask.value

        #expect(viewModel.isConnectionVerified)
        #expect(viewModel.statusMessage == String(localized: "Configuration saved"))
        #expect(viewModel.didSaveConfig)
        #expect(!viewModel.shouldShowErrorAlert)
    }

    // Yield repeatedly so already-created async tasks get a chance to run.

    @MainActor
    private func settleAsyncWork() async {
        for _ in 0..<settlingYieldCount {
            await Task.yield()
        }
    }
}

enum SaveInputEdit: CaseIterable, Sendable {
    case url
    case key
    case urlThenRestore
    case keyThenRestore

    @MainActor
    func apply(to viewModel: SettingsServerViewModel) {
        switch self {
        case .url, .urlThenRestore:
            let originalURL = viewModel.serverURL
            viewModel.serverURL = "https://changed.example.com"
            if self == .urlThenRestore {
                viewModel.serverURL = originalURL
            }
        case .key, .keyThenRestore:
            let originalKey = viewModel.apiKey
            viewModel.apiKey = "fixture-b"
            if self == .keyThenRestore {
                viewModel.apiKey = originalKey
            }
        }
    }
}

private actor SaveCompletionGate {
    private var hasStarted = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            hasStarted = true
            startContinuation?.resume()
            startContinuation = nil
        }
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

// Actor isolation keeps the attempt count consistent when the connection-test closure and the test overlap.

private actor ConnectionAttemptCounter {
    private var value = 0

    func nextValue() -> Int {
        value += 1
        return value
    }

    func currentValue() -> Int {
        value
    }
}

// Holds the automatic retry so we can verify that waiting does not alert right away and testing resumes on active.

private actor RetryDelayGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func releaseAll() {
        let pendingContinuations = continuations
        continuations.removeAll()

        for continuation in pendingContinuations {
            continuation.resume()
        }
    }
}
