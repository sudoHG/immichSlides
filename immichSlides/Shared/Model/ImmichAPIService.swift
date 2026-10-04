//
//  ImmichAPIService.swift
//  immichSlides
//
//  Created by sudoHG on 2026/1/8.
//

import Foundation

class ImmichAPIService {
    // List items decode only lightweight fields and ignore assets, so full album assets are not loaded into memory.

    private struct AlbumListItem: Decodable {
        let id: String
        let albumName: String
        let albumThumbnailAssetId: String?
        let assetCount: Int

        var album: Album {
            Album(
                id: id,
                albumName: albumName,
                albumThumbnailAssetId: albumThumbnailAssetId,
                assetCount: assetCount,
                assets: []
            )
        }
    }

    static let shared = ImmichAPIService()

    private var server: ImmichServer

    private init() {

        server = Self.loadServerConfigFromStorage()
    }
    func getApiKey() -> String? {
        return server.immichApiKey
    }

    func reloadServerConfiguration() {
        server = Self.loadServerConfigFromStorage()
    }

    static func decodeAlbumList(from data: Data) throws -> [Album] {
        try JSONDecoder()
            .decode([AlbumListItem].self, from: data)
            .map(\.album)
    }

    func getAllAlbums(size: Int? = nil) async throws -> [Album] {

        let request = try makeRequest(endpoint: "albums", method: "GET")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {

                throw ImmichError.networkError(NSError(domain: "ImmichAPIService", code: 0, userInfo: nil))
            }
            switch httpResponse.statusCode {
            case 200:

                let albums = try Self.decodeAlbumList(from: data)
                if let size {
                    return Array(albums.prefix(size))
                }
                return albums
            case 401:
                throw ImmichError.invalidAPIKey
            case 403:
                throw ImmichError.insufficientAPIKeyPermissions
            case 404:
                throw ImmichError.serverEndpointNotFound
            case 500...504:
                throw ImmichError.internalServerError(
                    NSError(domain: "ImmichAPIService", code: httpResponse.statusCode, userInfo: nil))
            default:
                throw ImmichError.unknownError(
                    NSError(domain: "ImmichAPIService", code: httpResponse.statusCode, userInfo: nil))
            }
        } catch {
            if let immichError = error as? ImmichError {
                throw immichError
            }
            if error is DecodingError {
                throw ImmichError.jsonResponseDecodingFailed(error)
            } else {
                throw ImmichError.networkError(error)
            }
        }
    }

    func getAllPeople(size: Int? = nil) async throws -> [People] {
        var endpoint: String = "people"
        if let size {
            endpoint = "people?size=\(size)"
        }
        let request = try makeRequest(endpoint: endpoint, method: "GET")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ImmichError.networkError(NSError(domain: "ImmichAPIService", code: 0, userInfo: nil))
            }
            switch httpResponse.statusCode {
            case 200:
                let peopleResponse = try JSONDecoder().decode(PeopleListResponse.self, from: data)
                return peopleResponse.people
            case 401:
                throw ImmichError.invalidAPIKey
            case 403:
                throw ImmichError.insufficientAPIKeyPermissions
            case 404:
                throw ImmichError.serverEndpointNotFound
            case 500...504:
                throw ImmichError.internalServerError(
                    NSError(domain: "ImmichAPIService", code: httpResponse.statusCode, userInfo: nil))
            default:
                throw ImmichError.unknownError(
                    NSError(domain: "ImmichAPIService", code: httpResponse.statusCode, userInfo: nil))
            }
        } catch {
            if let immichError = error as? ImmichError {
                throw immichError
            }
            if error is DecodingError {
                throw ImmichError.jsonResponseDecodingFailed(error)
            } else {
                throw ImmichError.networkError(error)
            }
        }
    }

    func getPersonAssetsCount(id: String) async throws -> Int {
        let endpoint: String = "people/\(id)/statistics"
        let request = try makeRequest(endpoint: endpoint, method: "GET")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ImmichError.networkError(NSError(domain: "ImmichAPIService", code: 0, userInfo: nil))
            }
            switch httpResponse.statusCode {
            case 200:
                let personAssetsCountResponse = try JSONDecoder().decode(PersonAssetsCount.self, from: data)
                return personAssetsCountResponse.assets
            case 401:
                throw ImmichError.invalidAPIKey
            case 403:
                throw ImmichError.insufficientAPIKeyPermissions
            case 404:
                throw ImmichError.serverEndpointNotFound
            case 500...504:
                throw ImmichError.internalServerError(
                    NSError(domain: "ImmichAPIService", code: httpResponse.statusCode, userInfo: nil))
            default:
                throw ImmichError.unknownError(
                    NSError(domain: "ImmichAPIService", code: httpResponse.statusCode, userInfo: nil))
            }
        } catch {
            if error is CancellationError {
                throw error
            }
            if let urlError = error as? URLError, urlError.code == .cancelled {
                throw urlError
            }
            if let immichError = error as? ImmichError {
                throw immichError
            }
            if error is DecodingError {
                throw ImmichError.jsonResponseDecodingFailed(error)
            } else {
                throw ImmichError.networkError(error)
            }
        }
    }

    func getThumbnailURL(id: String, size: ThumbnailSize) async throws -> URL {
        let _ = try getServerConfig()
        guard let urlString = server.getAPIURL(endpoint: "assets/\(id)/thumbnail?size=\(size.rawValue)"),
            let url = URL(string: urlString)
        else {
            throw ImmichError.apiEndpointConstructionFailed
        }
        return url
    }

    func getPeopleThumbnailURL(id: String) async throws -> URL {
        let _ = try getServerConfig()
        guard let urlString = server.getAPIURL(endpoint: "people/\(id)/thumbnail"),
            let url = URL(string: urlString)
        else {
            throw ImmichError.apiEndpointConstructionFailed
        }
        return url
    }

    func getRandomAsset(size: Int, albumIds: [String]? = nil, personIds: [String]? = nil) async throws -> [Asset] {

        var request = try makeRequest(endpoint: "search/random", method: "POST")

        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let body = RandomAssetRequestBody(
                size: size,
                albumIds: albumIds,
                isOffline: false,
                personIds: personIds,
                visibility: AssetVisibility.timeline.rawValue,
                withDeleted: false,
                withExif: true,
                withPeople: true,
                withStacked: true
            )
            request.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {

                throw ImmichError.networkError(NSError(domain: "ImmichAPIService", code: 0, userInfo: nil))
            }
            switch httpResponse.statusCode {
            case 200:

                let randomAssets = try JSONDecoder().decode([Asset].self, from: data)
                return randomAssets
            case 401:
                throw ImmichError.invalidAPIKey
            case 403:
                throw ImmichError.insufficientAPIKeyPermissions
            case 404:
                throw ImmichError.serverEndpointNotFound
            case 500...504:
                throw ImmichError.internalServerError(
                    NSError(domain: "ImmichAPIService", code: httpResponse.statusCode, userInfo: nil))
            default:
                throw ImmichError.unknownError(
                    NSError(domain: "ImmichAPIService", code: httpResponse.statusCode, userInfo: nil))
            }
        } catch {
            if let immichError = error as? ImmichError {
                throw immichError
            }
            if error is EncodingError {
                throw ImmichError.jsonRequestEncodingFailed(error)
            } else if error is DecodingError {
                throw ImmichError.jsonResponseDecodingFailed(error)
            } else {
                throw ImmichError.networkError(error)
            }
        }

    }

    // Fetch details by a locked asset id for runtime-evidence replay; does not use the random endpoint.

    func getAsset(id: String) async throws -> Asset {
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let request = try makeRequest(endpoint: "assets/\(encodedID)", method: "GET")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ImmichError.networkError(NSError(domain: "ImmichAPIService", code: 0, userInfo: nil))
            }
            switch httpResponse.statusCode {
            case 200:
                return try JSONDecoder().decode(Asset.self, from: data)
            case 401:
                throw ImmichError.invalidAPIKey
            case 403:
                throw ImmichError.insufficientAPIKeyPermissions
            case 404:
                throw ImmichError.serverEndpointNotFound
            case 500...504:
                throw ImmichError.internalServerError(
                    NSError(domain: "ImmichAPIService", code: httpResponse.statusCode, userInfo: nil))
            default:
                throw ImmichError.unknownError(
                    NSError(domain: "ImmichAPIService", code: httpResponse.statusCode, userInfo: nil))
            }
        } catch {
            if let immichError = error as? ImmichError {
                throw immichError
            }
            if error is DecodingError {
                throw ImmichError.jsonResponseDecodingFailed(error)
            } else {
                throw ImmichError.networkError(error)
            }
        }
    }

    func getAssets(ids: [String]) async throws -> [Asset] {
        var assets: [Asset] = []
        assets.reserveCapacity(ids.count)
        for id in ids {
            assets.append(try await getAsset(id: id))
        }
        return assets
    }

    // MARK: Private methods

    private func getServerConfig() throws -> (baseURL: String, apiKey: String) {
        guard let baseURL = server.immichURL,
            let apiKey = server.immichApiKey,
            !baseURL.isEmpty,
            !apiKey.isEmpty
        else {
            throw ImmichError.serverNotConfigured
        }
        return (baseURL, apiKey)
    }

    private static func loadServerConfigFromStorage() -> ImmichServer {
        if let loaded = ImmichServer.load() {
            return loaded
        }

        // DEBUG previews may read the test server from Info.plist; XCTest must be excluded so they do not mix.

        if !ImmichServer.isRunningXCTest,
            let debugServer = ImmichServer.testServerFromInfoPlistForTesting()
        {
            return debugServer
        }

        return ImmichServer(immichURL: "", immichApiKey: "")
    }

    private static let requestTimeoutSeconds: TimeInterval = 10

    private func makeRequest(endpoint: String, method: String) throws -> URLRequest {

        let (_, apiKey) = try getServerConfig()

        guard let urlString = server.getAPIURL(endpoint: endpoint),
            let url = URL(string: urlString)
        else {
            throw ImmichError.apiEndpointConstructionFailed
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        ImmichHTTPHeaders.applyAPIKey(apiKey, to: &request)
        request.timeoutInterval = Self.requestTimeoutSeconds
        return request
    }

}
