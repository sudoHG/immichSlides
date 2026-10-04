//
//  SettingsServerViewModel.swift
//  immichSlides
//
//  Created by Codex on 2026/3/10.
//

import Foundation
import Combine

@MainActor
final class SettingsServerViewModel: ObservableObject {

    typealias ConnectionTestAction =
        @Sendable (
            _ serverURL: String,
            _ apiKey: String,
            _ progressHandler: (@Sendable (ImmichServer.ConnectionTestEvent) -> Void)?
        ) async -> ImmichServer.ConnectionTestResult

    typealias SaveServerConfigAction =
        @Sendable (
            _ serverURL: String,
            _ apiKey: String
        ) async -> (isSuccess: Bool, errorMessage: String?)

    typealias DelayAction = @Sendable (_ nanoseconds: UInt64) async -> Void

    private enum ErrorAlertContext {
        case connectionTest
        case saveConfig

        var title: String {
            switch self {
            case .connectionTest:
                return String(localized: "Connection test failed")
            case .saveConfig:
                return String(localized: "Save Failed")
            }
        }
    }

    // A connection test waiting on permission: remembered and retried automatically after 1s/2s/4s.

    private struct PendingConnectionRetry {
        let serverURL: String
        let apiKey: String
        let remainingAutomaticRetries: Int
    }

    @Published var serverURL: String = "" {
        didSet {
            if serverURL != oldValue { inputDidChange() }
        }
    }
    @Published var apiKey: String = "" {
        didSet {
            if apiKey != oldValue { inputDidChange() }
        }
    }
    @Published var isConnectionVerified: Bool = false
    @Published var isTestingConnection: Bool = false
    @Published var testingStatusMessage: String = String(localized: "Testing connection...")
    @Published var showErrorAlert: Bool = false
    @Published var errorAlertTitle: String = String(localized: "Save Failed")
    @Published var errorMessage: String = ""
    @Published var statusMessage: String = ""
    // Signal a successful save with a flag, not with the statusMessage text, which can change.

    @Published var didSaveConfig: Bool = false

    private var suppressAutoInvalidate: Bool = false
    private var inputRevision: UInt64 = 0
    private var invalidatedInputRevision: UInt64 = 0
    private var hasLoadedInitialConfig: Bool = false
    private var pendingConnectionRetry: PendingConnectionRetry?
    private var connectionTestTask: Task<Void, Never>?
    private var automaticRetryTask: Task<Void, Never>?

    private let connectionTestAction: ConnectionTestAction
    private let saveServerConfigAction: SaveServerConfigAction
    private let delayAction: DelayAction
    private let automaticRetryDelaySchedule: [UInt64]

    init(
        connectionTestAction: @escaping ConnectionTestAction = { serverURL, apiKey, progressHandler in
            await ImmichServer.testConnection(
                serverURL: serverURL,
                apiKey: apiKey,
                progressHandler: progressHandler
            )
        },
        saveServerConfigAction: @escaping SaveServerConfigAction = { serverURL, apiKey in
            await ImmichServer.tryToSaveServerConfig(serverURL: serverURL, apiKey: apiKey)
        },
        delayAction: @escaping DelayAction = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        automaticRetryDelaySchedule: [UInt64] = [
            1_000_000_000,
            2_000_000_000,
            4_000_000_000
        ]
    ) {
        self.connectionTestAction = connectionTestAction
        self.saveServerConfigAction = saveServerConfigAction
        self.delayAction = delayAction
        self.automaticRetryDelaySchedule = automaticRetryDelaySchedule
        applyUITestConnectionPrefillIfRequested()
    }

    deinit {
        connectionTestTask?.cancel()
        automaticRetryTask?.cancel()
    }

    func loadExistingServerConfigIfNeeded() {
        guard !hasLoadedInitialConfig else { return }
        hasLoadedInitialConfig = true

        if applyUITestConnectionPrefillIfRequested() {
            return
        }

        guard let server = ImmichServer.load(), server.isConfigured else {
            return
        }

        suppressAutoInvalidate = true
        serverURL = server.immichURL ?? ""
        apiKey = server.immichApiKey ?? ""
        isConnectionVerified = true
        statusMessage = String(localized: "Current settings loaded")
        suppressAutoInvalidate = false
    }

    @discardableResult
    private func applyUITestConnectionPrefillIfRequested() -> Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard ImmichServer.isRunningXCTest,
            env["UI_TEST_APP_STORE_SCREENSHOT_PREFILL_CONNECTION"] == "1",
            let screenshotServerURL = env["UI_TEST_APP_STORE_SCREENSHOT_SERVER_URL"],
            let screenshotAPIKey = env["UI_TEST_APP_STORE_SCREENSHOT_API_KEY"],
            !screenshotServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !screenshotAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }

        // UI tests can prefill the form to avoid bringing up the system keyboard.

        serverURL = screenshotServerURL
        apiKey = screenshotAPIKey
        isConnectionVerified = true
        isTestingConnection = false
        statusMessage = ""
        showErrorAlert = false
        return true
        #else
        return false
        #endif
    }

    private func inputDidChange() {
        guard !suppressAutoInvalidate else { return }
        inputRevision &+= 1
        invalidateVerification()
    }

    func invalidateVerification() {
        guard !suppressAutoInvalidate,
            invalidatedInputRevision != inputRevision
        else { return }
        invalidatedInputRevision = inputRevision
        cancelPendingConnectionTestFlow()
        isConnectionVerified = false
        statusMessage = ""
    }

    // Resume the interrupted connection test when returning to the foreground from the permission prompt.

    func resumePendingConnectionTestIfNeeded() {
        guard let pendingConnectionRetry else {
            return
        }

        automaticRetryTask?.cancel()
        automaticRetryTask = nil

        runConnectionTestAttempt(
            serverURL: pendingConnectionRetry.serverURL,
            apiKey: pendingConnectionRetry.apiKey,
            remainingAutomaticRetries: pendingConnectionRetry.remainingAutomaticRetries,
            resetProgressMessage: false
        )
    }

    func testConnection() {
        let validateURLResult = ImmichServer.validateURL(serverURL)
        guard validateURLResult.isURLValid else {
            isConnectionVerified = false
            presentErrorAlert(
                context: .connectionTest,
                message: validateURLResult.errorMessage ?? String(localized: "Invalid server URL format")
            )
            return
        }

        let validateAPIKeyResult = ImmichServer.validateAPIKey(apiKey)
        guard validateAPIKeyResult.isAPIKeyValid else {
            isConnectionVerified = false
            presentErrorAlert(
                context: .connectionTest,
                message: validateAPIKeyResult.errorMessage ?? String(localized: "Invalid API Key")
            )
            return
        }

        cancelPendingConnectionTestFlow()
        showErrorAlert = false
        statusMessage = ""
        testingStatusMessage = String(localized: "Testing connection...")
        isTestingConnection = true

        runConnectionTestAttempt(
            serverURL: serverURL,
            apiKey: apiKey,
            remainingAutomaticRetries: automaticRetryDelaySchedule.count
        )
    }

    @discardableResult
    func saveServerConfig() -> Task<Void, Never> {

        didSaveConfig = false
        let previousServer = ImmichServer.load()
        let currentServerURL = serverURL
        let currentAPIKey = apiKey
        let saveInputRevision = inputRevision
        let saveServerConfigAction = self.saveServerConfigAction

        return Task { [weak self] in
            guard let self else { return }

            let result = await saveServerConfigAction(currentServerURL, currentAPIKey)
            if result.isSuccess {
                // Refresh the API singleton right after a successful save so this process stops calling the old server.

                ImmichAPIService.shared.reloadServerConfiguration()

                // Clear cross-server state only when the config really changed, so saving again does not wipe filters.

                let latestServer = ImmichServer.load()
                let serverChanged = !ImmichServer.isSameConfiguration(previousServer, latestServer)
                if serverChanged {
                    FilterSelectionStore().clear()
                    AssetsDownloadManager.shared.resetForServerConfigurationChange()
                    await SoloVisionPoolFilter.shared.resetForServerConfigurationChange()
                    NotificationCenter.default.post(name: .serverConfigurationDidChange, object: nil)
                }
            }

            guard self.inputRevision == saveInputRevision else { return }

            if result.isSuccess {
                self.isConnectionVerified = true
                self.statusMessage = String(localized: "Configuration saved")
                self.didSaveConfig = true
            } else {
                self.isConnectionVerified = false
                self.statusMessage = ""
                self.didSaveConfig = false
                self.presentErrorAlert(
                    context: .saveConfig,
                    message: result.errorMessage ?? String(localized: "Save Failed")
                )
            }
        }
    }

    private func runConnectionTestAttempt(
        serverURL: String,
        apiKey: String,
        remainingAutomaticRetries: Int,
        resetProgressMessage: Bool = true
    ) {
        connectionTestTask?.cancel()

        if resetProgressMessage {
            testingStatusMessage = String(localized: "Testing connection...")
        }

        isTestingConnection = true
        let connectionTestAction = self.connectionTestAction

        connectionTestTask = Task { [weak self] in
            guard let self else { return }

            let result = await connectionTestAction(serverURL, apiKey) { [weak self] event in
                guard let self else { return }
                Task { @MainActor in
                    self.handleConnectionTestProgressEvent(event)
                }
            }

            await self.applyConnectionTestResult(
                result,
                serverURL: serverURL,
                apiKey: apiKey,
                remainingAutomaticRetries: remainingAutomaticRetries
            )
        }
    }

    private func handleConnectionTestProgressEvent(_ event: ImmichServer.ConnectionTestEvent) {
        // Ignore late progress events once the test has finished.

        guard isTestingConnection else {
            return
        }

        switch event {
        case .waitingForConnectivity:
            testingStatusMessage = String(
                localized: "Waiting for network access. If the system shows a permission prompt, choose Allow.")
        case .checkingAssetRead:
            testingStatusMessage = String(localized: "Verifying photo list permission...")
        case .checkingImagePreview:
            testingStatusMessage = String(localized: "Verifying photo preview permission...")
        case .checkingFullsizeImage:
            testingStatusMessage = String(localized: "Verifying original image access...")
        case .checkingOptionalFilters:
            testingStatusMessage = String(localized: "Verifying album and people filter permissions...")
        }
    }

    private func applyConnectionTestResult(
        _ result: ImmichServer.ConnectionTestResult,
        serverURL: String,
        apiKey: String,
        remainingAutomaticRetries: Int
    ) async {
        guard !Task.isCancelled else {
            return
        }

        connectionTestTask = nil

        switch result.kind {
        case .success:
            automaticRetryTask?.cancel()
            automaticRetryTask = nil
            pendingConnectionRetry = nil
            isTestingConnection = false
            testingStatusMessage = String(localized: "Testing connection...")
            isConnectionVerified = true
            statusMessage = result.message ?? String(localized: "Connection test passed")

        case .waitingForPermission:
            let waitingMessage =
                result.statusMessage
                ?? String(
                    localized:
                        "Waiting for system network permission. If the system shows a permission prompt, choose Allow and the app will continue testing automatically."
                )

            isConnectionVerified = false
            statusMessage = ""
            testingStatusMessage = waitingMessage

            guard remainingAutomaticRetries > 0 else {
                automaticRetryTask?.cancel()
                automaticRetryTask = nil
                pendingConnectionRetry = nil
                isTestingConnection = false
                testingStatusMessage = String(localized: "Testing connection...")
                presentErrorAlert(
                    context: .connectionTest,
                    message: String(
                        localized:
                            "Network permission is not complete yet. Allow Wireless Data or Local Network access, then try again."
                    )
                )
                return
            }

            let nextRemainingAutomaticRetries = remainingAutomaticRetries - 1
            pendingConnectionRetry = PendingConnectionRetry(
                serverURL: serverURL,
                apiKey: apiKey,
                remainingAutomaticRetries: nextRemainingAutomaticRetries
            )
            scheduleAutomaticRetry(remainingAutomaticRetries: remainingAutomaticRetries)

        case .failure:
            automaticRetryTask?.cancel()
            automaticRetryTask = nil
            pendingConnectionRetry = nil
            isTestingConnection = false
            testingStatusMessage = String(localized: "Testing connection...")
            isConnectionVerified = false
            statusMessage = ""
            presentErrorAlert(
                context: .connectionTest,
                titleOverride: result.alertTitle,
                message: result.errorMessage ?? String(localized: "Connection test failed")
            )
        }
    }

    private func scheduleAutomaticRetry(remainingAutomaticRetries: Int) {
        automaticRetryTask?.cancel()

        let retryIndex = automaticRetryDelaySchedule.count - remainingAutomaticRetries
        guard automaticRetryDelaySchedule.indices.contains(retryIndex) else {
            return
        }

        let delay = automaticRetryDelaySchedule[retryIndex]
        let delayAction = self.delayAction

        automaticRetryTask = Task { [weak self] in
            await delayAction(delay)
            guard !Task.isCancelled else { return }
            self?.resumePendingConnectionTestIfNeeded()
        }
    }

    private func cancelPendingConnectionTestFlow() {
        connectionTestTask?.cancel()
        connectionTestTask = nil
        automaticRetryTask?.cancel()
        automaticRetryTask = nil
        pendingConnectionRetry = nil
        isTestingConnection = false
        testingStatusMessage = String(localized: "Testing connection...")
    }

    private func presentErrorAlert(
        context: ErrorAlertContext,
        titleOverride: String? = nil,
        message: String
    ) {
        errorAlertTitle = titleOverride ?? context.title
        errorMessage = message
        showErrorAlert = true
    }
}
