import Foundation
import Security

extension ImmichServer {
    static func testConnection(
        serverURL: String,
        apiKey: String,
        sessionForTesting: URLSession? = nil,
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
        if let sessionForTesting {
            activeSession = sessionForTesting
            transientSession = nil
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = requestTimeoutSeconds
            configuration.timeoutIntervalForResource = resourceTimeoutSeconds
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
                forbiddenMessage: missingAssetReadPermissionMessage(),
                maxBodyBytes: maxJSONProbeBodyBytes
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
                forbiddenMessage: missingAssetViewPermissionMessage(),
                maxBodyBytes: maxImageProbeBodyBytes
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
                forbiddenMessage: missingAssetDownloadPermissionMessage(),
                maxBodyBytes: maxImageProbeBodyBytes
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
        request.timeoutInterval = requestTimeoutSeconds

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
        // Range only asks for the first 1 KB; a server may ignore it and return a full 200, so the probe also stops
        // reading after maxImageProbeBodyBytes.

        request.setValue(imageProbeByteRange, forHTTPHeaderField: "Range")
        request.timeoutInterval = requestTimeoutSeconds
        return request
    }

    // Reads at most maxBodyBytes of the response and then cancels the transfer, so a server that ignores Range cannot
    // make the probe download a full image.
    private static func readProbeResponse(
        _ request: URLRequest,
        session: URLSession,
        maxBodyBytes: Int
    ) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= maxBodyBytes {
                bytes.task.cancel()
                break
            }
        }
        return (data, response)
    }

    private static func sendConnectionProbeRequest(
        _ request: URLRequest,
        session: URLSession,
        serverURL: String,
        forbiddenMessage: String,
        maxBodyBytes: Int
    ) async -> ConnectionProbeResponse {
        do {
            let (data, response) = try await readProbeResponse(request, session: session, maxBodyBytes: maxBodyBytes)
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
            String(data: data.prefix(inspectedResponsePrefixBytes), encoding: .utf8)?
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
        request.timeoutInterval = requestTimeoutSeconds
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
}
