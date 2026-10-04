// Guards against the server connection test falsely reporting success.

import Foundation
import SDWebImage
import Testing
@testable import immichSlides

@MainActor
@Suite(.serialized, .sharedRuntimeIsolation)
struct ImmichServerConnectionTests {

    @Test
    func `connection test verifies access to a random photo, its preview and its full image`() async throws {
        let recorder = HTTPRequestRecorder()
        let session = makeMockedSession { request in
            await recorder.store(request)

            let url = try #require(request.url)
            let response: HTTPURLResponse
            let data: Data

            if url.path == "/api/search/random" {
                response = Self.response(for: url, statusCode: 200, contentType: "application/json; charset=utf-8")
                data = Data(#"[{"id":"asset-1"}]"#.utf8)
            } else if url.absoluteString.contains("/api/assets/asset-1/thumbnail?size=preview") {
                response = Self.response(for: url, statusCode: 206, contentType: "image/jpeg")
                data = Data([0xFF, 0xD8, 0xFF])
            } else if url.absoluteString.contains("/api/assets/asset-1/thumbnail?size=fullsize") {
                response = Self.response(for: url, statusCode: 206, contentType: "image/jpeg")
                data = Data([0xFF, 0xD8, 0xFF])
            } else if url.path == "/api/api-keys/me" {
                response = Self.response(for: url, statusCode: 200, contentType: "application/json")
                data = Data(#"{"permissions":["all"]}"#.utf8)
            } else if url.path == "/api/albums" {
                response = Self.response(for: url, statusCode: 200, contentType: "application/json")
                data = Data("[]".utf8)
            } else if url.path == "/api/people" {
                response = Self.response(for: url, statusCode: 200, contentType: "application/json")
                data = Data(#"{"people":[]}"#.utf8)
            } else {
                response = Self.response(for: url, statusCode: 404, contentType: "application/json")
                data = Data("{}".utf8)
            }

            return (response, data)
        }

        let result = await ImmichServer.testConnection(
            serverURL: "https://demo.example.com",
            apiKey: "fake-key",
            sessionForTesting: session
        )

        #expect(result.isSuccess)

        let requests = await recorder.values
        #expect(
            requests.map { $0.url?.absoluteString ?? "" } == [
                "https://demo.example.com/api/search/random",
                "https://demo.example.com/api/assets/asset-1/thumbnail?size=preview",
                "https://demo.example.com/api/assets/asset-1/thumbnail?size=fullsize",
                "https://demo.example.com/api/api-keys/me",
                "https://demo.example.com/api/albums",
                "https://demo.example.com/api/people?size=1"
            ])
        #expect(requests.first?.httpMethod == "POST")
        #expect(requests.first?.value(forHTTPHeaderField: "x-api-key") == "fake-key")
        #expect(requests.first?.value(forHTTPHeaderField: "User-Agent") == ImmichHTTPHeaders.userAgent)
        #expect(requests.first?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(requests.first?.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(requests[1].value(forHTTPHeaderField: "User-Agent") == ImmichHTTPHeaders.userAgent)
        #expect(requests[1].value(forHTTPHeaderField: "Range") == "bytes=0-1023")
        #expect(requests[2].value(forHTTPHeaderField: "User-Agent") == ImmichHTTPHeaders.userAgent)
        #expect(requests[2].value(forHTTPHeaderField: "Range") == "bytes=0-1023")
    }

    @Test
    func `image download request modifier attaches both the API key and the User-Agent`() throws {
        let modifier = try #require(ImmichRequestModifier.create(apiKey: "fake-key"))
        let originalRequest = URLRequest(url: try #require(URL(string: "https://demo.example.com/image.jpg")))

        let modifiedRequest = try #require(modifier.modifiedRequest(with: originalRequest))

        #expect(modifiedRequest.value(forHTTPHeaderField: "x-api-key") == "fake-key")
        #expect(modifiedRequest.value(forHTTPHeaderField: "User-Agent") == ImmichHTTPHeaders.userAgent)
    }

    @Test
    func `a 200 response with an HTML page is not reported as a successful connection`() async {
        let session = makeMockedSession { request in
            let response = HTTPURLResponse(
                url: try #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )!
            let html = Data("<html><body>redirect page</body></html>".utf8)
            return (response, html)
        }

        let result = await ImmichServer.testConnection(
            serverURL: "https://demo.example.com",
            apiKey: "fake-key",
            sessionForTesting: session
        )

        #expect(!result.isSuccess)
        #expect(
            result.errorMessage
                == String(
                    localized:
                        "Server did not return JSON. The Immich URL, port, or reverse proxy entry point may be incorrect"
                ))
    }

    @Test
    func `a 401 response clearly reports an invalid API key`() async {
        let session = makeMockedSession { request in
            let response = HTTPURLResponse(
                url: try #require(request.url),
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{}".utf8))
        }

        let result = await ImmichServer.testConnection(
            serverURL: "https://demo.example.com",
            apiKey: "fake-key",
            sessionForTesting: session
        )

        #expect(!result.isSuccess)
        #expect(result.alertTitle == String(localized: "Invalid API Key"))
        #expect(
            result.errorMessage
                == String(
                    localized:
                        "The server rejected this API Key. Make sure you copied the full new API Key, not the Key name or an old Key."
                ))
    }

    @Test
    func `a 403 response with an HTML page reports that server access is blocked`() async {
        let session = makeMockedSession { request in
            let response = HTTPURLResponse(
                url: try #require(request.url),
                statusCode: 403,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "text/html; charset=utf-8",
                    "Server": "cloudflare"
                ]
            )!
            return (response, Data("<html><body>Forbidden</body></html>".utf8))
        }

        let result = await ImmichServer.testConnection(
            serverURL: "https://demo.example.com",
            apiKey: "fake-key",
            sessionForTesting: session
        )

        #expect(!result.isSuccess)
        #expect(result.alertTitle == String(localized: "Server Access Blocked"))
        #expect(
            result.errorMessage
                == LocalizedText.format(
                    "Server returned %lld, but the response was not Immich JSON. Cloudflare, a reverse proxy, or access control may be blocking the request. Check the server URL, proxy rules, or allow this device to access the server, then try again.",
                    Int64(403)
                )
        )
    }

    @Test
    func `missing asset.read blocks saving and explains the required photo list permission`() async {
        let session = makeMockedSession { request in
            let url = try #require(request.url)
            let response = Self.response(for: url, statusCode: 403, contentType: "application/json")
            return (response, Data("{}".utf8))
        }

        let result = await ImmichServer.testConnection(
            serverURL: "https://demo.example.com",
            apiKey: "fake-key",
            sessionForTesting: session
        )

        #expect(!result.isSuccess)
        #expect(result.alertTitle == String(localized: "API Key lacks required permissions"))
        #expect(
            result.errorMessage
                == String(
                    localized:
                        "Missing asset.read. immichSlides cannot read the photo list. Enable asset.read for this Immich API Key and try again."
                ))
    }

    @Test
    func `a 403 on the preview probe reports checking asset.view and asset.download`() async {
        let session = makeMockedSession { request in
            let url = try #require(request.url)
            if url.path == "/api/search/random" {
                let response = Self.response(for: url, statusCode: 200, contentType: "application/json")
                return (response, Data(#"[{"id":"asset-1"}]"#.utf8))
            }

            let response = Self.response(for: url, statusCode: 403, contentType: "application/json")
            return (response, Data("{}".utf8))
        }

        let result = await ImmichServer.testConnection(
            serverURL: "https://demo.example.com",
            apiKey: "fake-key",
            sessionForTesting: session
        )

        #expect(!result.isSuccess)
        #expect(result.alertTitle == String(localized: "API Key lacks required permissions"))
        #expect(
            result.errorMessage
                == String(
                    localized:
                        "The photo list can be read, but photo previews cannot load. Enable asset.view and asset.download for this Immich API Key and try again."
                ))
    }

    @Test
    func `missing asset.download blocks the full image probe`() async {
        let session = makeMockedSession { request in
            let url = try #require(request.url)
            if url.path == "/api/search/random" {
                let response = Self.response(for: url, statusCode: 200, contentType: "application/json")
                return (response, Data(#"[{"id":"asset-1"}]"#.utf8))
            }

            if url.absoluteString.contains("size=preview") {
                let response = Self.response(for: url, statusCode: 206, contentType: "image/jpeg")
                return (response, Data([0xFF, 0xD8, 0xFF]))
            }

            let response = Self.response(for: url, statusCode: 403, contentType: "application/json")
            return (response, Data("{}".utf8))
        }

        let result = await ImmichServer.testConnection(
            serverURL: "https://demo.example.com",
            apiKey: "fake-key",
            sessionForTesting: session
        )

        #expect(!result.isSuccess)
        #expect(result.alertTitle == String(localized: "API Key lacks required permissions"))
        #expect(
            result.errorMessage
                == String(
                    localized:
                        "Photo previews can load, but the original image required for playback cannot load. Enable asset.download for this Immich API Key and try again."
                ))
    }

    @Test
    func `connection succeeds with a warning when core playback permissions pass but filter permissions are missing`()
        async
    {
        let session = makeMockedSession { request in
            let url = try #require(request.url)
            if url.path == "/api/search/random" {
                let response = Self.response(for: url, statusCode: 200, contentType: "application/json")
                return (response, Data(#"[{"id":"asset-1"}]"#.utf8))
            }

            if url.absoluteString.contains("/api/assets/asset-1/thumbnail") {
                let response = Self.response(for: url, statusCode: 206, contentType: "image/jpeg")
                return (response, Data([0xFF, 0xD8, 0xFF]))
            }

            if url.path == "/api/api-keys/me" {
                let response = Self.response(for: url, statusCode: 200, contentType: "application/json")
                return (response, Data(#"{"permissions":["album.statistics","person.statistics"]}"#.utf8))
            }

            let response = Self.response(for: url, statusCode: 403, contentType: "application/json")
            return (response, Data("{}".utf8))
        }

        let result = await ImmichServer.testConnection(
            serverURL: "https://demo.example.com",
            apiKey: "fake-key",
            sessionForTesting: session
        )

        #expect(result.isSuccess)
        let expectedWarnings = [
            String(localized: "Album filters are unavailable: missing album.read."),
            String(localized: "People filters are unavailable: missing person.read.")
        ]
        #expect(
            result.message
                == LocalizedText.format(
                    "Connection test passed, but some filters need extra permissions:\n%@",
                    expectedWarnings.joined(separator: "\n")
                )
        )
    }

    @Test
    func `missing person.statistics blocks saving`() async {
        let session = makeMockedSession { request in
            let url = try #require(request.url)
            if url.path == "/api/search/random" {
                let response = Self.response(for: url, statusCode: 200, contentType: "application/json")
                return (response, Data(#"[{"id":"asset-1"}]"#.utf8))
            }

            if url.absoluteString.contains("/api/assets/asset-1/thumbnail") {
                let response = Self.response(for: url, statusCode: 206, contentType: "image/jpeg")
                return (response, Data([0xFF, 0xD8, 0xFF]))
            }

            if url.path == "/api/api-keys/me" {
                let response = Self.response(for: url, statusCode: 200, contentType: "application/json")
                return (response, Data(#"{"permissions":["album.statistics"]}"#.utf8))
            }

            let response = Self.response(for: url, statusCode: 404, contentType: "application/json")
            return (response, Data("{}".utf8))
        }

        let result = await ImmichServer.testConnection(
            serverURL: "https://demo.example.com",
            apiKey: "fake-key",
            sessionForTesting: session
        )

        #expect(!result.isSuccess)
        #expect(result.alertTitle == String(localized: "API Key lacks required permissions"))
        #expect(result.errorMessage == missingStatisticsPermissionMessage("person.statistics"))
    }

    @Test
    func `missing album.statistics blocks saving`() async {
        let session = makeMockedSession { request in
            let url = try #require(request.url)
            if url.path == "/api/search/random" {
                let response = Self.response(for: url, statusCode: 200, contentType: "application/json")
                return (response, Data(#"[{"id":"asset-1"}]"#.utf8))
            }

            if url.absoluteString.contains("/api/assets/asset-1/thumbnail") {
                let response = Self.response(for: url, statusCode: 206, contentType: "image/jpeg")
                return (response, Data([0xFF, 0xD8, 0xFF]))
            }

            if url.path == "/api/api-keys/me" {
                let response = Self.response(for: url, statusCode: 200, contentType: "application/json")
                return (response, Data(#"{"permissions":["person.statistics"]}"#.utf8))
            }

            let response = Self.response(for: url, statusCode: 404, contentType: "application/json")
            return (response, Data("{}".utf8))
        }

        let result = await ImmichServer.testConnection(
            serverURL: "https://demo.example.com",
            apiKey: "fake-key",
            sessionForTesting: session
        )

        #expect(!result.isSuccess)
        #expect(result.alertTitle == String(localized: "API Key lacks required permissions"))
        #expect(result.errorMessage == missingStatisticsPermissionMessage("album.statistics"))
    }

    @Test
    func `an empty photo list explains that photos must be uploaded first`() async {
        let session = makeMockedSession { request in
            let url = try #require(request.url)
            let response = Self.response(for: url, statusCode: 200, contentType: "application/json")
            return (response, Data("[]".utf8))
        }

        let result = await ImmichServer.testConnection(
            serverURL: "https://demo.example.com",
            apiKey: "fake-key",
            sessionForTesting: session
        )

        #expect(!result.isSuccess)
        #expect(
            result.errorMessage
                == String(
                    localized: "No photo was found for testing. Upload at least one photo to Immich, then try again."))
    }

    @Test
    func `a 405 response prompts checking the Immich entry address or port`() async {
        let session = makeMockedSession { request in
            let response = HTTPURLResponse(
                url: try #require(request.url),
                statusCode: 405,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )!
            return (response, Data("<html>not allowed</html>".utf8))
        }

        let result = await ImmichServer.testConnection(
            serverURL: "https://demo.example.com",
            apiKey: "fake-key",
            sessionForTesting: session
        )

        #expect(!result.isSuccess)
        #expect(
            result.errorMessage
                == String(
                    localized:
                        "The server URL is not a valid Immich API entry point. It may be missing the correct port or reverse proxy path."
                ))
    }

    @Test
    func `a local network address hitting a disconnect-style error first enters the permission waiting state`() async {
        let session = makeMockedSession { _ in
            throw URLError(.notConnectedToInternet)
        }

        let result = await ImmichServer.testConnection(
            serverURL: "http://192.168.1.20:2283",
            apiKey: "fake-key",
            sessionForTesting: session
        )

        #expect(!result.isSuccess)
        #expect(result.kind == .waitingForPermission)
        #expect(
            result.statusMessage
                == String(
                    localized:
                        "Waiting for system network permission. If the system shows a permission prompt, choose Allow and the app will continue testing automatically."
                )
        )
    }

    @Test
    func `a public host timeout reports failure, not permission waiting`() async {
        // Must use a public host + timedOut so a timeout is not classified as LAN permission waiting.

        let session = makeMockedSession { _ in
            throw URLError(.timedOut)
        }
        let permissionWaitingMessage = String(
            localized:
                "Waiting for system network permission. If the system shows a permission prompt, choose Allow and the app will continue testing automatically."
        )

        let result = await ImmichServer.testConnection(
            serverURL: "https://demo.example.com",
            apiKey: "fake-key",
            sessionForTesting: session
        )

        #expect(result.kind == .failure)
        #expect(result.message?.contains(permissionWaitingMessage) != true)
    }

    @Test
    func `a Keychain write failure leaves no server URL behind in UserDefaults`() async {
        await ServerConfigurationTestIsolation.run {
            ImmichServer.clearSavedConfiguration()
            let leftoverURL = "https://demo.example.com/api"
            let server = ImmichServer(
                immichURL: leftoverURL,
                immichApiKey: "key-that-cannot-be-saved"
            )

            let didSave = server.save { _ in false }

            #expect(didSave == false)
            #expect(UserDefaults.standard.string(forKey: "immichURL") == nil)
            #expect(ImmichServer.load() == nil)
        }
    }

    // Expected text is looked up the way the app builds it, so the tests pass in any simulator language.
    private func missingStatisticsPermissionMessage(_ permission: String) -> String {
        LocalizedText.format(
            "Missing filter statistics permission: %@. Enable it for this Immich API Key and try again.",
            permission
        )
    }

    // Intercepts URLSession with URLProtocol, so no real server is needed.

    private func makeMockedSession(
        handler: @escaping @Sendable (URLRequest) async throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        ImmichServerMockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImmichServerMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    nonisolated private static func response(
        for url: URL,
        statusCode: Int,
        contentType: String
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType]
        )!
    }
}

// Remembers the latest request in an actor so async reads and writes do not race.

private actor HTTPRequestRecorder {
    private(set) var values: [URLRequest] = []

    func store(_ request: URLRequest) {
        values.append(request)
    }
}

private final class ImmichServerMockURLProtocol: URLProtocol, @unchecked Sendable {
    static var requestHandler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let client else { return }
        guard let handler = Self.requestHandler else {
            client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        Task {
            do {
                let (response, data) = try await handler(request)
                client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(self, didLoad: data)
                client.urlProtocolDidFinishLoading(self)
            } catch {
                client.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {
    }
}
