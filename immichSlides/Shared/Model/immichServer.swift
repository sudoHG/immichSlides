//
//  immichServer.swift
//  immichSlides
//
//  Created by sudoHG on 2026/1/6.
//

import Foundation
import Security

extension Notification.Name {
    static let serverConfigurationDidChange = Notification.Name("serverConfigurationDidChange")
}

struct ImmichServer {
    // Intermediate connection-test events, so the UI can show "what is being checked" and a permission wait is not
    // taken as a failure.

    enum ConnectionTestEvent: Equatable {
        case waitingForConnectivity
        case checkingAssetRead
        case checkingImagePreview
        case checkingFullsizeImage
        case checkingOptionalFilters
    }

    struct ConnectionTestResult: Equatable {
        enum Kind: Equatable {
            case success
            case waitingForPermission
            case failure
        }

        let kind: Kind
        let message: String?
        let alertTitle: String?

        init(kind: Kind, message: String?, alertTitle: String? = nil) {
            self.kind = kind
            self.message = message
            self.alertTitle = alertTitle
        }

        var isSuccess: Bool {
            kind == .success
        }

        var errorMessage: String? {
            kind == .failure ? message : nil
        }

        var statusMessage: String? {
            kind == .waitingForPermission ? message : nil
        }
    }

    // The probe decodes only the photo id, so a connection test does not load a full Asset.

    struct ConnectionProbeAsset: Decodable {
        let id: String
    }

    // Image probes only need the status and headers; JSON probes need one small asset record.
    static let requestTimeoutSeconds: TimeInterval = 10
    static let resourceTimeoutSeconds: TimeInterval = 20
    static let imageProbeByteRange: String = "bytes=0-1023"
    static let inspectedResponsePrefixBytes: Int = 128
    static let maxImageProbeBodyBytes = 1024
    static let maxJSONProbeBodyBytes = 4 * 1024 * 1024

    enum ConnectionProbeResponse {
        case success(data: Data, response: HTTPURLResponse)
        case failure(ConnectionTestResult)
    }

    // On waitsForConnectivity, tell the UI to wait for the system network permission first instead of showing a failure
    // right away.

    final class ConnectionTestSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let onEvent: @Sendable (ConnectionTestEvent) -> Void

        init(onEvent: @escaping @Sendable (ConnectionTestEvent) -> Void) {
            self.onEvent = onEvent
        }

        func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
            onEvent(.waitingForConnectivity)
        }
    }

    let immichURL: String?
    // Holds the API Key at runtime; it is persisted in the Keychain, not in UserDefaults.

    let immichApiKey: String?
    private static let userDefaultsURLKey = "immichURL"
    // The Keychain may read empty in test processes, so UserDefaults is also written as a fallback; release builds
    // still use only the Keychain.

    static let testAPIKeyDefaultsKey = "immichApiKey.xctestFallback"

    init(immichURL: String? = nil, immichApiKey: String? = nil) {
        self.immichURL = immichURL
        self.immichApiKey = immichApiKey
    }

    var isConfigured: Bool {
        if immichURL != nil && immichApiKey != nil {
            if immichURL?.isEmpty == false && immichApiKey?.isEmpty == false {
                return true
            }
        }
        return false
    }

    static func tryToSaveServerConfig(serverURL: String, apiKey: String) async -> (
        isSuccess: Bool, errorMessage: String?
    ) {

        let validateURLResult = validateURL(serverURL)

        if !validateURLResult.isURLValid {
            return (false, validateURLResult.errorMessage)
        }

        let validateAPIKeyResult = validateAPIKey(apiKey)
        if !validateAPIKeyResult.isAPIKeyValid {
            return (false, validateAPIKeyResult.errorMessage)
        }

        let result = await testConnection(serverURL: serverURL, apiKey: apiKey)
        if result.isSuccess {

            let normalizedServerURL = normalizeServerURL(serverURL)

            let server = ImmichServer(immichURL: normalizedServerURL, immichApiKey: apiKey)

            let didSave = server.save()
            guard didSave else {
                return (false, String(localized: "Failed to read or write secure storage"))
            }

            return (true, nil)
        } else {
            return (false, result.errorMessage)
        }

    }

    // MARK: Utilities

    @discardableResult
    func save(writeAPIKeyToKeychainForTesting: ((String) -> Bool)? = nil) -> Bool {
        guard let immichURL,
            let apiKey = immichApiKey,
            !immichURL.isEmpty,
            !apiKey.isEmpty
        else {
            return false
        }

        // Write the Keychain before the URL; if the Key fails, do not save a half-finished configuration.

        let keychainWriter = writeAPIKeyToKeychainForTesting ?? Self.writeAPIKeyToKeychain
        let didWriteAPIKey = keychainWriter(apiKey)
        guard didWriteAPIKey else {
            return false
        }

        let userDefaults = UserDefaults.standard
        userDefaults.set(immichURL, forKey: Self.userDefaultsURLKey)

        if Self.shouldWriteTestAPIKeyFallback {
            userDefaults.set(apiKey, forKey: Self.testAPIKeyDefaultsKey)
        }

        return true
    }

    static func load() -> ImmichServer? {
        let userDefaults = UserDefaults.standard
        let immichURL = userDefaults.string(forKey: Self.userDefaultsURLKey)
        let keychainAPIKey = readAPIKeyFromKeychain() ?? readTestAPIKeyFallback()

        if let immichURL,
            let immichApiKey = keychainAPIKey
        {
            return ImmichServer(immichURL: immichURL, immichApiKey: immichApiKey)
        } else {
            return injectedServerFromEnvironmentForTesting()
        }
    }

    // For UI tests: clear the local server configuration and the API Key.
    static func clearSavedConfiguration() {
        let userDefaults = UserDefaults.standard
        userDefaults.removeObject(forKey: Self.userDefaultsURLKey)
        userDefaults.removeObject(forKey: Self.testAPIKeyDefaultsKey)
        deleteAPIKeyFromKeychain()
    }

    static func validateURL(_ urlString: String) -> (isURLValid: Bool, errorMessage: String?) {
        guard let url = URL(string: urlString) else {
            return (false, String(localized: "Server URL format is invalid"))
        }
        guard let scheme = url.scheme, (scheme.lowercased() == "http" || scheme.lowercased() == "https") else {
            return (false, String(localized: "Server URL must start with http or https"))
        }
        guard let host = url.host, !host.isEmpty else {
            return (false, String(localized: "Server URL must include a hostname"))
        }
        return (true, nil)
    }

    // Heuristic check for a LAN address, used to decide whether to handle it as a local-network permission wait.

    static func isLikelyLocalNetworkServerURL(_ urlString: String) -> Bool {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL),
            let rawHost = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawHost.isEmpty
        else {
            return false
        }

        let host = rawHost.lowercased()

        if host == "localhost" || host == "127.0.0.1" || host == "::1" {
            return true
        }

        if host.hasSuffix(".local") {
            return true
        }

        if isPrivateIPv4Address(host) || isLocalIPv6Address(host) {
            return true
        }

        if !host.contains(".") {
            return true
        }

        return false
    }

    static func normalizeServerURL(_ urlString: String) -> String {
        var url = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix("/") {
            url = String(url.dropLast())
        }
        if url.hasSuffix("/api") {
            url = String(url.dropLast(4))
        }
        return "\(url)/api"
    }

    // Compare business equivalence: URLs are normalized, API Keys are trimmed of leading/trailing whitespace.

    static func isSameConfiguration(_ lhs: ImmichServer?, _ rhs: ImmichServer?) -> Bool {
        func normalizedURL(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return normalizeServerURL(trimmed)
        }

        func normalizedAPIKey(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed
        }

        return normalizedURL(lhs?.immichURL) == normalizedURL(rhs?.immichURL)
            && normalizedAPIKey(lhs?.immichApiKey) == normalizedAPIKey(rhs?.immichApiKey)
    }

    func getAPIURL(endpoint: String) -> String? {
        guard let baseURL = immichURL else { return nil }
        return "\(baseURL)/\(endpoint)"
    }

    static func validateAPIKey(_ apiKey: String) -> (isAPIKeyValid: Bool, errorMessage: String?) {
        if apiKey.isEmpty {
            return (false, String(localized: "API Key is required"))
        }
        return (true, nil)
    }
    // Playability test: random -> preview -> fullsize, then check filter permissions.

    private nonisolated static func writeAPIKeyToKeychain(_ apiKey: String) -> Bool {

        guard let data = apiKey.data(using: .utf8) else { return false }
        let lookupQuery = apiKeyKeychainLookupQuery()

        var addQuery = lookupQuery
        addQuery[kSecValueData as String] = data
        // Delete first, then add; the delete query must not include kSecValueData, or the old Key cannot be deleted.

        SecItemDelete(lookupQuery as CFDictionary)
        let status = SecItemAdd(addQuery as CFDictionary, nil)

        return status == errSecSuccess
    }

    private nonisolated static func readAPIKeyFromKeychain() -> String? {

        var query = apiKeyKeychainLookupQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
            let data = result as? Data,
            let apiKey = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return apiKey
    }

    private nonisolated static func deleteAPIKeyFromKeychain() {
        SecItemDelete(apiKeyKeychainLookupQuery() as CFDictionary)
    }

    nonisolated private static func apiKeyKeychainLookupQuery() -> [String: Any] {

        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "immichSlides.server",
            kSecAttrAccount as String: "immichApiKey"
        ]
    }

    // Map URLError to a permission wait or a failure, so the local-network permission prompt is not treated as a
    // connection failure.

    static func classifyConnectionTestError(
        _ error: Error,
        serverURL: String
    ) -> ConnectionTestResult {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .dataNotAllowed:
                return ConnectionTestResult(
                    kind: .waitingForPermission,
                    message: String(
                        localized:
                            "Waiting for system network permission. If the system shows a permission prompt, choose Allow and the app will continue testing automatically."
                    )
                )
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                .dnsLookupFailed:
                if isLikelyLocalNetworkServerURL(serverURL) {
                    return ConnectionTestResult(
                        kind: .waitingForPermission,
                        message: String(
                            localized:
                                "Waiting for system network permission. If the system shows a permission prompt, choose Allow and the app will continue testing automatically."
                        )
                    )
                }
            default:
                break
            }
        }

        return ConnectionTestResult(
            kind: .failure,
            message: LocalizedText.format("Network request failed: %@", error.localizedDescription)
        )
    }

    private static func isPrivateIPv4Address(_ host: String) -> Bool {
        let segments = host.split(separator: ".")
        guard segments.count == 4 else { return false }

        let numbers = segments.compactMap { Int($0) }
        guard numbers.count == 4 else { return false }

        let first = numbers[0]
        let second = numbers[1]

        if first == 10 {
            return true
        }

        if first == 172 && (16...31).contains(second) {
            return true
        }

        if first == 192 && second == 168 {
            return true
        }

        if first == 169 && second == 254 {
            return true
        }

        return false
    }

    private static func isLocalIPv6Address(_ host: String) -> Bool {
        let normalizedHost = host.lowercased()

        if normalizedHost == "::1" {
            return true
        }

        if normalizedHost.hasPrefix("fe80:") {
            return true
        }

        if normalizedHost.hasPrefix("fc") || normalizedHost.hasPrefix("fd") {
            return true
        }

        return false
    }

}
