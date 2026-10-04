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

        var success: Bool {
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

    private struct ConnectionProbeAsset: Decodable {
        let id: String
    }

    private enum ConnectionProbeResponse {
        case success(data: Data, response: HTTPURLResponse)
        case failure(ConnectionTestResult)
    }

    // On waitsForConnectivity, tell the UI to wait for the system network permission first instead of showing a failure
    // right away.

    private final class ConnectionTestSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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

    private static let testAPIKeyDefaultsKey = "immichApiKey.xctestFallback"

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
        if result.success {

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
    func save(writeAPIKeyToKeychain: ((String) -> Bool)? = nil) -> Bool {
        guard let immichURL,
            let apiKey = immichApiKey,
            !immichURL.isEmpty,
            !apiKey.isEmpty
        else {
            return false
        }

        // Write the Keychain before the URL; if the Key fails, do not save a half-finished configuration.

        let keychainWriter = writeAPIKeyToKeychain ?? Self.writeAPIKeyToKeychain
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
            return uiTestInjectedServerFromEnvironment()
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

    static func testConnection(
        serverURL: String,
        apiKey: String,
        session: URLSession? = nil,
        progressHandler: (@Sendable (ConnectionTestEvent) -> Void)? = nil
    ) async -> ConnectionTestResult {
        let url = normalizeServerURL(serverURL)
        let server = ImmichServer(immichURL: url, immichApiKey: apiKey)
        guard let apiURLString = server.getAPIURL(endpoint: "search/random"),
            let apiURL = URL(string: apiURLString)
        else {
            return ConnectionTestResult(
                kind: .failure,
                message: String(localized: "Unknown error: unable to construct API endpoint URL")
            )
        }

        if shouldAssumeConnectionSuccessForUITest(serverURL: url, apiKey: apiKey) {
            return ConnectionTestResult(kind: .success, message: nil)
        }

        // Session only for connection tests: waitsForConnectivity, so a brief network loss does not fail at once.

        let activeSession: URLSession
        let transientSession: URLSession?
        if let session {
            activeSession = session
            transientSession = nil
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 20
            configuration.allowsCellularAccess = true
            configuration.allowsConstrainedNetworkAccess = true
            configuration.allowsExpensiveNetworkAccess = true

            if let progressHandler {
                let delegate = ConnectionTestSessionDelegate(onEvent: progressHandler)
                let probeSession = URLSession(
                    configuration: configuration,
                    delegate: delegate,
                    delegateQueue: nil
                )
                activeSession = probeSession
                transientSession = probeSession
            } else {
                let probeSession = URLSession(configuration: configuration)
                activeSession = probeSession
                transientSession = probeSession
            }
        }

        defer {
            transientSession?.finishTasksAndInvalidate()
        }

        do {
            progressHandler?(.checkingAssetRead)
            let randomAssetRequest = try makeRandomAssetProbeRequest(apiURL: apiURL, apiKey: apiKey)
            let randomAssetProbe = await sendConnectionProbeRequest(
                randomAssetRequest,
                session: activeSession,
                serverURL: serverURL,
                forbiddenMessage: missingAssetReadPermissionMessage()
            )

            let randomAssetData: Data
            let randomAssetResponse: HTTPURLResponse
            switch randomAssetProbe {
            case .success(let data, let response):
                randomAssetData = data
                randomAssetResponse = response
            case .failure(let result):
                return result
            }

            guard isJSONResponse(randomAssetResponse) else {
                return ConnectionTestResult(
                    kind: .failure,
                    message: String(
                        localized:
                            "Server did not return JSON. The Immich URL, port, or reverse proxy entry point may be incorrect"
                    )
                )
            }

            let assetID = try decodeConnectionProbeAssetID(from: randomAssetData)

            progressHandler?(.checkingImagePreview)
            guard
                let previewRequest = makeImageAccessProbeRequest(
                    server: server,
                    assetID: assetID,
                    size: .preview,
                    apiKey: apiKey
                )
            else {
                return ConnectionTestResult(
                    kind: .failure,
                    message: String(localized: "Unknown error: unable to build the photo preview URL")
                )
            }

            let previewProbe = await sendConnectionProbeRequest(
                previewRequest,
                session: activeSession,
                serverURL: serverURL,
                forbiddenMessage: missingAssetViewPermissionMessage()
            )
            switch previewProbe {
            case .success(_, let response):
                guard isImageResponse(response) else {
                    return ConnectionTestResult(
                        kind: .failure,
                        message: String(localized: "The server returned an unexpected photo preview response format")
                    )
                }
            case .failure(let result):
                return result
            }

            progressHandler?(.checkingFullsizeImage)
            guard
                let fullsizeRequest = makeImageAccessProbeRequest(
                    server: server,
                    assetID: assetID,
                    size: .fullsize,
                    apiKey: apiKey
                )
            else {
                return ConnectionTestResult(
                    kind: .failure,
                    message: String(localized: "Unknown error: unable to build the original image URL")
                )
            }

            let fullsizeProbe = await sendConnectionProbeRequest(
                fullsizeRequest,
                session: activeSession,
                serverURL: serverURL,
                forbiddenMessage: missingAssetDownloadPermissionMessage()
            )
            switch fullsizeProbe {
            case .success(_, let response):
                guard isImageResponse(response) else {
                    return ConnectionTestResult(
                        kind: .failure,
                        message: String(localized: "The server returned an unexpected original image response format")
                    )
                }
            case .failure(let result):
                return result
            }

            progressHandler?(.checkingOptionalFilters)
            let optionalPermissionResult = await runOptionalPermissionProbes(
                server: server,
                apiKey: apiKey,
                session: activeSession,
                serverURL: serverURL
            )
            if let blockingFailure = optionalPermissionResult.blockingFailure {
                return blockingFailure
            }

            let successMessage = optionalPermissionWarningMessage(optionalPermissionResult.warnings)
            return ConnectionTestResult(kind: .success, message: successMessage)
        } catch let error as ConnectionProbeDecodeError {
            return error.result
        } catch is DecodingError {
            return ConnectionTestResult(
                kind: .failure,
                message: String(localized: "Server did not return valid Immich JSON data")
            )
        } catch {
            return classifyConnectionTestError(error, serverURL: serverURL)
        }
    }

    private struct ConnectionProbeDecodeError: Error {
        let result: ConnectionTestResult
    }

    private struct OptionalPermissionProbeResult {
        var warnings: [String]
        var blockingFailure: ConnectionTestResult?
    }

    private struct APIKeyPermissionProbeResponse: Decodable {
        let permissions: [String]
    }

    // POST /search/random checks asset.read.

    private static func makeRandomAssetProbeRequest(apiURL: URL, apiKey: String) throws -> URLRequest {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        ImmichHTTPHeaders.applyAPIKey(apiKey, to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "size": 1,
            "isOffline": false,
            "visibility": AssetVisibility.timeline.rawValue,
            "withDeleted": false,
            "withExif": true,
            "withPeople": true,
            "withStacked": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // The image probe uses the same kind of thumbnail URL as real playback.

    private static func makeImageAccessProbeRequest(
        server: ImmichServer,
        assetID: String,
        size: ThumbnailSize,
        apiKey: String
    ) -> URLRequest? {
        guard let urlString = server.getAPIURL(endpoint: "assets/\(assetID)/thumbnail?size=\(size.rawValue)"),
            let url = URL(string: urlString)
        else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        ImmichHTTPHeaders.applyAPIKey(apiKey, to: &request)
        request.setValue("image/*,*/*", forHTTPHeaderField: "Accept")
        // Range asks for the first 1 KB; a server may ignore it and return a full 200, which the probe still consumes.

        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        request.timeoutInterval = 10
        return request
    }

    private static func sendConnectionProbeRequest(
        _ request: URLRequest,
        session: URLSession,
        serverURL: String,
        forbiddenMessage: String
    ) async -> ConnectionProbeResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(
                    ConnectionTestResult(
                        kind: .failure,
                        message: String(localized: "Unknown error: unable to parse server response")
                    )
                )
            }

            switch httpResponse.statusCode {
            case 200...299:
                return .success(data: data, response: httpResponse)
            case 401:
                if !isImmichJSONErrorResponse(data: data, response: httpResponse) {
                    return makeServerAccessBlockedResult(statusCode: httpResponse.statusCode)
                }

                return .failure(
                    ConnectionTestResult(
                        kind: .failure,
                        message: invalidAPIKeyMessage(),
                        alertTitle: String(localized: "Invalid API Key")
                    )
                )
            case 403:
                if !isImmichJSONErrorResponse(data: data, response: httpResponse) {
                    return makeServerAccessBlockedResult(statusCode: httpResponse.statusCode)
                }

                return .failure(
                    ConnectionTestResult(
                        kind: .failure,
                        message: forbiddenMessage,
                        alertTitle: String(localized: "API Key lacks required permissions")
                    )
                )
            case 404:
                return .failure(
                    ConnectionTestResult(kind: .failure, message: String(localized: "Server endpoint not found"))
                )
            case 405:
                return .failure(
                    ConnectionTestResult(
                        kind: .failure,
                        message: String(
                            localized:
                                "The server URL is not a valid Immich API entry point. It may be missing the correct port or reverse proxy path."
                        )
                    )
                )
            case 500...504:
                return .failure(
                    ConnectionTestResult(
                        kind: .failure,
                        message: LocalizedText.format(
                            "Internal server error, status code: %lld", Int64(httpResponse.statusCode))
                    )
                )
            default:
                return .failure(
                    ConnectionTestResult(
                        kind: .failure,
                        message: LocalizedText.format(
                            "Unknown error, status code: %lld", Int64(httpResponse.statusCode))
                    )
                )
            }
        } catch {
            return .failure(classifyConnectionTestError(error, serverURL: serverURL))
        }
    }

    // Tell Immich JSON apart from proxy HTML, so a gateway page is not reported as missing API Key permissions.

    private static func isImmichJSONErrorResponse(data: Data, response: HTTPURLResponse) -> Bool {
        if isJSONResponse(response) {
            return true
        }

        let bodyPrefix =
            String(data: data.prefix(128), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return bodyPrefix.hasPrefix("{") || bodyPrefix.hasPrefix("[")
    }

    private static func makeServerAccessBlockedResult(statusCode: Int) -> ConnectionProbeResponse {
        .failure(
            ConnectionTestResult(
                kind: .failure,
                message: serverAccessBlockedMessage(statusCode: statusCode),
                alertTitle: String(localized: "Server Access Blocked")
            )
        )
    }

    // Immich JSON endpoints should not return HTML.

    private static func isJSONResponse(_ response: HTTPURLResponse) -> Bool {
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        return contentType.contains("json")
    }

    // Image endpoints accept image/* or application/octet-stream.

    private static func isImageResponse(_ response: HTTPURLResponse) -> Bool {
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        return contentType.contains("image") || contentType.contains("octet-stream")
    }

    // With no photos, preview/fullsize cannot be checked, so prompt the user to upload first.

    private static func decodeConnectionProbeAssetID(from data: Data) throws -> String {
        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ConnectionProbeDecodeError(
                result: ConnectionTestResult(
                    kind: .failure,
                    message: String(localized: "Server did not return valid Immich JSON data")
                )
            )
        }

        guard jsonObject is [Any] else {
            throw ConnectionProbeDecodeError(
                result: ConnectionTestResult(
                    kind: .failure,
                    message: String(localized: "Server did not return an Immich asset list")
                )
            )
        }

        let assets: [ConnectionProbeAsset]
        do {
            assets = try JSONDecoder().decode([ConnectionProbeAsset].self, from: data)
        } catch {
            throw ConnectionProbeDecodeError(
                result: ConnectionTestResult(
                    kind: .failure,
                    message: String(localized: "Server did not return valid Immich JSON data")
                )
            )
        }

        guard let firstAssetID = assets.first?.id,
            !firstAssetID.isEmpty
        else {
            throw ConnectionProbeDecodeError(
                result: ConnectionTestResult(
                    kind: .failure,
                    message: String(
                        localized:
                            "No photo was found for testing. Upload at least one photo to Immich, then try again.")
                )
            )
        }

        return firstAssetID
    }

    // Missing album/person.read only warns; statistics affects filter counts.

    private static func runOptionalPermissionProbes(
        server: ImmichServer,
        apiKey: String,
        session: URLSession,
        serverURL: String
    ) async -> OptionalPermissionProbeResult {
        var warnings: [String] = []

        let missingStatisticsPermissions = await missingRequiredStatisticsPermissions(
            server: server,
            apiKey: apiKey,
            session: session,
            serverURL: serverURL
        )
        if !missingStatisticsPermissions.isEmpty {
            return OptionalPermissionProbeResult(
                warnings: warnings,
                blockingFailure: ConnectionTestResult(
                    kind: .failure,
                    message: missingStatisticsPermissionsMessage(missingStatisticsPermissions),
                    alertTitle: String(localized: "API Key lacks required permissions")
                )
            )
        }

        if let albumsRequest = makeSimpleGetProbeRequest(server: server, endpoint: "albums", apiKey: apiKey),
            let albumsStatus = await optionalProbeStatus(albumsRequest, session: session, serverURL: serverURL),
            albumsStatus == 403
        {
            warnings.append(String(localized: "Album filters are unavailable: missing album.read."))
        }

        var firstPersonID: String?
        if let peopleRequest = makeSimpleGetProbeRequest(server: server, endpoint: "people?size=1", apiKey: apiKey),
            let peopleProbe = await optionalProbeData(peopleRequest, session: session, serverURL: serverURL)
        {
            if peopleProbe.response.statusCode == 403 {
                warnings.append(String(localized: "People filters are unavailable: missing person.read."))
            } else if peopleProbe.response.statusCode == 200 {
                firstPersonID = decodeFirstPersonID(from: peopleProbe.data)
            }
        }

        if let firstPersonID,
            let statisticsRequest = makeSimpleGetProbeRequest(
                server: server,
                endpoint: "people/\(firstPersonID)/statistics",
                apiKey: apiKey
            ),
            let statisticsStatus = await optionalProbeStatus(statisticsRequest, session: session, serverURL: serverURL),
            statisticsStatus == 403
        {
            warnings.append(String(localized: "People photo counts are unavailable: missing person.statistics."))
        }

        return OptionalPermissionProbeResult(warnings: warnings, blockingFailure: nil)
    }

    private static func missingRequiredStatisticsPermissions(
        server: ImmichServer,
        apiKey: String,
        session: URLSession,
        serverURL: String
    ) async -> [String] {
        guard let request = makeSimpleGetProbeRequest(server: server, endpoint: "api-keys/me", apiKey: apiKey),
            let probe = await optionalProbeData(request, session: session, serverURL: serverURL),
            probe.response.statusCode == 200,
            let permissionResponse = try? JSONDecoder().decode(APIKeyPermissionProbeResponse.self, from: probe.data)
        else {
            return []
        }

        let permissions = Set(permissionResponse.permissions)
        if permissions.contains("all") {
            return []
        }

        let requiredStatisticsPermissions = ["album.statistics", "person.statistics"]
        return requiredStatisticsPermissions.filter { !permissions.contains($0) }
    }

    // Album and person checks only look for 403 and do not decode the full business model.

    private static func makeSimpleGetProbeRequest(
        server: ImmichServer,
        endpoint: String,
        apiKey: String
    ) -> URLRequest? {
        guard let urlString = server.getAPIURL(endpoint: endpoint),
            let url = URL(string: urlString)
        else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        ImmichHTTPHeaders.applyAPIKey(apiKey, to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        return request
    }

    // Extra permission checks return nil on network errors so they do not break the main connection test.

    private static func optionalProbeStatus(
        _ request: URLRequest,
        session: URLSession,
        serverURL: String
    ) async -> Int? {
        let probe = await optionalProbeData(request, session: session, serverURL: serverURL)
        return probe?.response.statusCode
    }

    private static func optionalProbeData(
        _ request: URLRequest,
        session: URLSession,
        serverURL: String
    ) async -> (data: Data, response: HTTPURLResponse)? {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }
            return (data, httpResponse)
        } catch {
            return nil
        }
    }

    // When there are no people, skip the statistics permission-error check.

    private static func decodeFirstPersonID(from data: Data) -> String? {
        struct PeopleProbeResponse: Decodable {
            struct Person: Decodable {
                let id: String
            }

            let people: [Person]
        }

        let response = try? JSONDecoder().decode(PeopleProbeResponse.self, from: data)
        return response?.people.first?.id
    }

    private static func optionalPermissionWarningMessage(_ warnings: [String]) -> String? {
        guard !warnings.isEmpty else { return nil }
        return LocalizedText.format(
            "Connection test passed, but some filters need extra permissions:\n%@",
            warnings.joined(separator: "\n")
        )
    }

    private static func missingStatisticsPermissionsMessage(_ permissions: [String]) -> String {
        LocalizedText.format(
            "Missing filter statistics permission: %@. Enable it for this Immich API Key and try again.",
            permissions.joined(separator: ", ")
        )
    }

    private static func invalidAPIKeyMessage() -> String {
        String(
            localized:
                "The server rejected this API Key. Make sure you copied the full new API Key, not the Key name or an old Key."
        )
    }

    private static func serverAccessBlockedMessage(statusCode: Int) -> String {
        LocalizedText.format(
            "Server returned %lld, but the response was not Immich JSON. Cloudflare, a reverse proxy, or access control may be blocking the request. Check the server URL, proxy rules, or allow this device to access the server, then try again.",
            Int64(statusCode)
        )
    }

    private static func missingAssetReadPermissionMessage() -> String {
        String(
            localized:
                "Missing asset.read. immichSlides cannot read the photo list. Enable asset.read for this Immich API Key and try again."
        )
    }

    private static func missingAssetViewPermissionMessage() -> String {
        String(
            localized:
                "The photo list can be read, but photo previews cannot load. Enable asset.view and asset.download for this Immich API Key and try again."
        )
    }

    private static func missingAssetDownloadPermissionMessage() -> String {
        String(
            localized:
                "Photo previews can load, but the original image required for playback cannot load. Enable asset.download for this Immich API Key and try again."
        )
    }

    static func debugTestServerFromInfoPlist() -> ImmichServer? {
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
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil {
            return true
        }

        // UI tests rely on UI_TEST_*, because XCTestConfigurationFilePath is not passed through reliably.

        return env.keys.contains { $0.hasPrefix("UI_TEST_") }
    }

    private static var isXCTestSupportEnabled: Bool {
        #if DEBUG
        return isRunningXCTest
        #else
        return false
        #endif
    }

    private static var shouldWriteTestAPIKeyFallback: Bool {
        isXCTestSupportEnabled
    }

    private static func readTestAPIKeyFallback() -> String? {
        guard isXCTestSupportEnabled else { return nil }
        return UserDefaults.standard.string(forKey: Self.testAPIKeyDefaultsKey)
    }

    // Bypass the connection test only when UI_TEST_ASSUME_CONNECTION_TEST_SUCCESS=1 and the input equals the injected
    // expected values.

    private static func shouldAssumeConnectionSuccessForUITest(serverURL: String, apiKey: String) -> Bool {
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

    static func uiTestInjectedServerFromEnvironment() -> ImmichServer? {
        uiTestInjectedServerFromEnvironment(
            ProcessInfo.processInfo.environment,
            xctestSupportEnabled: isXCTestSupportEnabled
        )
    }

    static func uiTestInjectedServerFromEnvironment(
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

    nonisolated private static func writeAPIKeyToKeychain(_ apiKey: String) -> Bool {

        guard let data = apiKey.data(using: .utf8) else { return false }
        let lookupQuery = apiKeyKeychainLookupQuery()

        var addQuery = lookupQuery
        addQuery[kSecValueData as String] = data
        // Delete first, then add; the delete query must not include kSecValueData, or the old Key cannot be deleted.

        SecItemDelete(lookupQuery as CFDictionary)
        let status = SecItemAdd(addQuery as CFDictionary, nil)

        return status == errSecSuccess
    }

    nonisolated private static func readAPIKeyFromKeychain() -> String? {

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

    nonisolated private static func deleteAPIKeyFromKeychain() {
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

    private static func classifyConnectionTestError(
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
