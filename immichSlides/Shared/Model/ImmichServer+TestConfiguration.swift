import Foundation
import Security

extension ImmichServer {
    static func testServerFromInfoPlistForTesting() -> ImmichServer? {
        #if DEBUG
        guard
            let rawURL = Bundle.main.object(forInfoDictionaryKey: "IMMICH_SERVER_URL") as? String,
            let apiKey = Bundle.main.object(forInfoDictionaryKey: "IMMICH_API_KEY") as? String
        else { return nil }

        let url = normalizeServerURL(rawURL.trimmingCharacters(in: .whitespacesAndNewlines))
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !url.isEmpty, !key.isEmpty else { return nil }
        return ImmichServer(immichURL: url, immichApiKey: key)
        #else
        return nil
        #endif
    }

    // Use XCTestConfigurationFilePath to tell test processes apart from normal Debug/Preview.

    static var isRunningXCTest: Bool {
        PlatformCompat.isRunningXCTest
    }

    private static var isXCTestSupportEnabled: Bool {
        #if DEBUG
        return isRunningXCTest
        #else
        return false
        #endif
    }

    static var shouldWriteTestAPIKeyFallback: Bool {
        isXCTestSupportEnabled
    }

    static func readTestAPIKeyFallback() -> String? {
        guard isXCTestSupportEnabled else { return nil }
        return UserDefaults.standard.string(forKey: Self.testAPIKeyDefaultsKey)
    }

    // Bypass the connection test only when UI_TEST_ASSUME_CONNECTION_TEST_SUCCESS=1 and the input equals the injected
    // expected values.

    static func shouldAssumeConnectionSuccessForUITest(serverURL: String, apiKey: String) -> Bool {
        guard isXCTestSupportEnabled else {
            return false
        }

        let env = ProcessInfo.processInfo.environment
        guard env["UI_TEST_ASSUME_CONNECTION_TEST_SUCCESS"] == "1" else {
            return false
        }

        let expectedURL =
            env["UI_TEST_EXPECTED_CONNECTION_SERVER_URL"] ?? env["IMMICH_TEST_SERVER_URL"] ?? env["IMMICH_TEST_URL"]
        let expectedAPIKey =
            env["UI_TEST_EXPECTED_CONNECTION_API_KEY"] ?? env["IMMICH_TEST_API_KEY"]

        guard let expectedURL, let expectedAPIKey else {
            return false
        }

        let normalizedExpectedURL = normalizeServerURL(expectedURL)
        let normalizedActualURL = normalizeServerURL(serverURL)
        let normalizedExpectedAPIKey = expectedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedActualAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        return normalizedExpectedURL == normalizedActualURL && normalizedExpectedAPIKey == normalizedActualAPIKey
    }

    // UI tests can read a temporary server configuration from the launch environment, without depending on whether the
    // Keychain takes effect in time.

    static func injectedServerFromEnvironmentForTesting() -> ImmichServer? {
        injectedServerFromEnvironmentForTesting(
            ProcessInfo.processInfo.environment,
            xctestSupportEnabled: isXCTestSupportEnabled
        )
    }

    static func injectedServerFromEnvironmentForTesting(
        _ env: [String: String],
        xctestSupportEnabled: Bool
    ) -> ImmichServer? {
        guard xctestSupportEnabled else { return nil }

        let rawURL =
            env["UI_TEST_SERVER_URL"] ?? env["IMMICH_TEST_SERVER_URL"] ?? env["IMMICH_TEST_URL"]
        let apiKey =
            env["UI_TEST_API_KEY"] ?? env["IMMICH_TEST_API_KEY"]

        guard let rawURL, let apiKey else { return nil }
        let normalizedURL = normalizeServerURL(rawURL.trimmingCharacters(in: .whitespacesAndNewlines))
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedURL.isEmpty, !trimmedKey.isEmpty else { return nil }
        return ImmichServer(immichURL: normalizedURL, immichApiKey: trimmedKey)
    }

    // MARK: - Keychain
}
