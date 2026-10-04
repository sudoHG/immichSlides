//
//  UITestServerConfigurationSupport.swift
//  immichSlidesUITests
//
//  UI tests use the shared test server configuration; skip if none is configured.
//

import XCTest

private struct ServerAlbum: Decodable {
    let id: String
    let assetCount: Int
}

private struct ServerPeoplePage: Decodable {
    struct Person: Decodable {
        let id: String
    }

    let people: [Person]
}

extension XCTestCase {
    func requireTestServerConfig() throws -> (url: String, apiKey: String) {

        guard let configuration = TestServerConfiguration.current else {
            throw XCTSkip("No test server is configured in the environment or in Config/env.xcconfig.")
        }

        return (url: configuration.serverURL, apiKey: configuration.apiKey)
    }

    // The filter summary's UI-test preparation selects the first album and person the server lists.
    func requireServerAlbumAndPerson() throws {
        guard let firstAlbum = try serverAlbums().first, firstAlbum.assetCount > 0 else {
            throw XCTSkip("The first album on the configured server is missing or empty, and this test plays it.")
        }
        guard try serverHasPeople() else {
            throw XCTSkip("The configured server has no people, and this test selects the first one.")
        }
    }

    // The album page shows albums in the order the server lists them, row by row.
    func serverAlbumIDs(atLeast count: Int) throws -> [String] {
        let albumIDs = try serverAlbums().map(\.id)
        guard albumIDs.count >= count else {
            throw XCTSkip("The configured server lists fewer than \(count) albums, which this test needs.")
        }
        return albumIDs
    }

    func requireExifDiagnosticAlbumID() throws -> String {
        _ = try requireTestServerConfig()
        guard let albumID = TestServerConfiguration.current?.exifDiagnosticAlbumID, !albumID.isEmpty else {
            throw XCTSkip(
                "IMMICH_TEST_EXIF_DIAGNOSTIC_ALBUM_ID is not set in the environment or in Config/env.xcconfig."
            )
        }
        return albumID
    }

    // Returns the photo count so the screenshots cover each photo of the album once.
    func requireExifDiagnosticAlbumAssetCount() throws -> Int {
        let albumID = try requireExifDiagnosticAlbumID()
        guard let album = try serverAlbums().first(where: { $0.id == albumID }), album.assetCount > 0
        else {
            throw XCTSkip("The configured server does not have the EXIF diagnostic album with photos.")
        }
        return album.assetCount
    }

    // One run reads the server's lists once: UI tests run serially against one configured server
    // and never change its data.
    private func serverAlbums() throws -> [ServerAlbum] {
        if let albums = ServerListCache.albums { return albums }
        let albums = try fetchTestServerJSON([ServerAlbum].self, path: "albums")
        ServerListCache.albums = albums
        return albums
    }

    private func serverHasPeople() throws -> Bool {
        if let hasPeople = ServerListCache.hasPeople { return hasPeople }
        let hasPeople = try !fetchTestServerJSON(ServerPeoplePage.self, path: "people?size=1").people.isEmpty
        ServerListCache.hasPeople = hasPeople
        return hasPeople
    }

    // A configured server that does not answer fails the test: skipping would hide a broken setup.
    // Errors name only the path and error code, never the server address.
    private func fetchTestServerJSON<Value: Decodable>(_ type: Value.Type, path: String) throws -> Value {
        let config = try requireTestServerConfig()
        let baseURLString = config.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = baseURLString.hasSuffix("/") ? "" : "/"
        guard let url = URL(string: "\(baseURLString)\(separator)\(path)") else {
            throw ServerRequestError(message: "The configured server URL cannot form a request for \(path)")
        }
        var request = URLRequest(url: url)
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")

        let semaphore = DispatchSemaphore(value: 0)
        var requestResult: Result<Value, Error>?
        let task = URLSession.shared.dataTask(with: request) { responseBody, response, error in
            defer { semaphore.signal() }
            if let error {
                requestResult = .failure(error)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                requestResult = .failure(ServerRequestError(message: "No HTTP response for \(path)"))
                return
            }
            guard httpResponse.statusCode == 200, let responseBody else {
                requestResult = .failure(ServerRequestError(message: "HTTP \(httpResponse.statusCode) for \(path)"))
                return
            }
            requestResult = Result { try JSONDecoder().decode(Value.self, from: responseBody) }
        }
        task.resume()

        guard semaphore.wait(timeout: .now() + 15) == .success else {
            task.cancel()
            throw ServerRequestError(message: "The configured server did not answer \(path) within 15 seconds")
        }
        switch requestResult {
        case let .success(value)?:
            return value
        case let .failure(error)?:
            let nsError = error as NSError
            throw ServerRequestError(
                message: "The configured server could not return \(path) (\(nsError.domain) \(nsError.code))"
            )
        case nil:
            throw ServerRequestError(message: "The request for \(path) finished without a result")
        }
    }
}

private struct ServerRequestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private enum ServerListCache {
    static var albums: [ServerAlbum]?
    static var hasPeople: Bool?
}
