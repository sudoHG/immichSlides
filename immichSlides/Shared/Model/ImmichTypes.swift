//
//  ImmichTypes.swift
//  immichSlides
//
//  Created by sudoHG on 2026/1/10.
//

import Foundation

enum ImmichError: Error {
    case serverNotConfigured
    case networkError(Error)
    case invalidAPIKey
    case insufficientAPIKeyPermissions
    case serverEndpointNotFound
    case internalServerError(Error)
    case apiEndpointConstructionFailed
    case unknownError(Error)
    case jsonRequestEncodingFailed(Error)
    case jsonResponseDecodingFailed(Error)
}

extension ImmichError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .serverNotConfigured:
            return String(localized: "Server not set")
        case .networkError(let error):
            return LocalizedText.format("Network error: %@", error.localizedDescription)
        case .invalidAPIKey:
            return String(localized: "Invalid API Key")
        case .insufficientAPIKeyPermissions:
            return String(localized: "API Key lacks required permissions")
        case .serverEndpointNotFound:
            return String(localized: "Server endpoint not found")
        case .internalServerError(let error):
            return LocalizedText.format("Server error: %@", error.localizedDescription)
        case .apiEndpointConstructionFailed:
            return String(localized: "Failed to build API endpoint URL")
        case .unknownError(let error):
            return LocalizedText.format("Unknown error: %@", error.localizedDescription)
        case .jsonRequestEncodingFailed(let error):
            return LocalizedText.format("Failed to encode JSON request body: %@", error.localizedDescription)
        case .jsonResponseDecodingFailed(let error):
            return LocalizedText.format("Failed to decode JSON response body: %@", error.localizedDescription)
        }
    }
}

enum ThumbnailSize: String {
    case fullsize
    case preview
    case thumbnail
}

enum SlideMode: String {
    case random
    case filtered
}
// Used for settings-page persistence; avoids storing PlaybackSource with its associated values directly.
enum DefaultPlaybackMode: String, Codable {
    case random
    case filtered
}
// Settings-page persisted display strategy, kept separate from the random/filtered source.
enum PlaybackDisplayMode: String, Codable, CaseIterable, Equatable {
    case smartFill
    case singlePhoto
}

enum AssetTypes: String {
    case IMAGE
    case VIDEO
    case AUDIO
    case OTHER
}

enum AssetVisibility: String {
    case archive
    case timeline
    case hidden
    case locked
}

enum AssetStates {
    case notStarted
    case loadingURL
    case urlReady
    case downloading
    case readyToPlay
    case failed
    case downloaded
    case failedToDownload
}

enum FilterType {
    case albums
    case people
}

enum PersonMatchMode: String, Codable {
    case normal = "normal"  // Any photo with this person passes; a single face is not required.
    case soloOnly = "soloOnly"  // Needs 1 person in metadata + 1 Vision face; album rules are not bound by solo.
}

enum PlaybackSource {
    case random
    case filtered(FilterSelection)
}
