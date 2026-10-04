//
//  ImmichModels.swift
//  immichSlides
//
//  Created by sudoHG on 2026/1/8.
//

import Foundation

struct Album: Codable, Identifiable {
    var id: String
    var albumName: String
    var albumThumbnailAssetId: String?
    var assetCount: Int
    var assets: [Asset]
}

struct Asset: Codable {
    var id: String
    var type: String
    var isFavorite: Bool
    var isTrashed: Bool
    var isArchived: Bool
    var exifInfo: ExifInfo?
    var people: [People]?
    var tags: [String]?
    var livePhotoVideoID: String?
    var width: Int? = nil
    var height: Int? = nil
    var thumbhash: String? = nil
    var unassignedFaces: [UnassignedFace]? = nil
}

enum ThumbHashGeometry {
    private nonisolated static let orientationByteIndex: Int = 4
    private nonisolated static let landscapeFlagMask: UInt8 = 0x80
    nonisolated static func isLandscape(_ thumbhash: String?) -> Bool? {
        guard let bytes = decodedBytes(from: thumbhash), bytes.count > orientationByteIndex else {
            return nil
        }
        return (bytes[orientationByteIndex] & landscapeFlagMask) != 0
    }

    private nonisolated static func decodedBytes(from thumbhash: String?) -> [UInt8]? {
        guard let thumbhash else { return nil }
        var normalized =
            thumbhash
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard !normalized.isEmpty else { return nil }

        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: normalized) else {
            return nil
        }
        return Array(data)
    }
}
// Unassigned faces are currently only checked for emptiness; the id is kept.
struct UnassignedFace: Codable {
    var id: String
}

struct ExifInfo: Codable {
    var make: String?
    var model: String?
    var dateTimeOriginal: String?
    var timeZone: String?
    var lensModel: String?
    var fNumber: Double?
    var focalLength: Double?
    var iso: Int?
    var exposureTime: String?
    var latitude: Double?
    var longitude: Double?
    var city: String?
    var state: String?
    var country: String?
    var rating: Int?
    var exifImageWidth: Int?
    var exifImageHeight: Int?
    var orientation: String?

    init(
        make: String? = nil,
        model: String? = nil,
        dateTimeOriginal: String? = nil,
        timeZone: String? = nil,
        lensModel: String? = nil,
        fNumber: Double? = nil,
        focalLength: Double? = nil,
        iso: Int? = nil,
        exposureTime: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        city: String? = nil,
        state: String? = nil,
        country: String? = nil,
        rating: Int? = nil,
        exifImageWidth: Int? = nil,
        exifImageHeight: Int? = nil,
        orientation: String? = nil
    ) {
        self.make = make
        self.model = model
        self.dateTimeOriginal = dateTimeOriginal
        self.timeZone = timeZone
        self.lensModel = lensModel
        self.fNumber = fNumber
        self.focalLength = focalLength
        self.iso = iso
        self.exposureTime = exposureTime
        self.latitude = latitude
        self.longitude = longitude
        self.city = city
        self.state = state
        self.country = country
        self.rating = rating
        self.exifImageWidth = exifImageWidth
        self.exifImageHeight = exifImageHeight
        self.orientation = orientation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        make = try container.decodeIfPresent(String.self, forKey: .make)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        dateTimeOriginal = try container.decodeIfPresent(String.self, forKey: .dateTimeOriginal)
        timeZone = try container.decodeIfPresent(String.self, forKey: .timeZone)
        lensModel = try container.decodeIfPresent(String.self, forKey: .lensModel)
        fNumber = try container.decodeIfPresent(Double.self, forKey: .fNumber)
        focalLength = try container.decodeIfPresent(Double.self, forKey: .focalLength)
        iso = try container.decodeIfPresent(Int.self, forKey: .iso)
        exposureTime = try container.decodeIfPresent(String.self, forKey: .exposureTime)
        latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
        city = try container.decodeIfPresent(String.self, forKey: .city)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        country = try container.decodeIfPresent(String.self, forKey: .country)
        rating = try container.decodeIfPresent(Int.self, forKey: .rating)
        exifImageWidth = try container.decodeIfPresent(Int.self, forKey: .exifImageWidth)
        exifImageHeight = try container.decodeIfPresent(Int.self, forKey: .exifImageHeight)

        // orientation may be a string or a number; always store a string so decoding does not fail.
        if let stringOrientation = try? container.decodeIfPresent(String.self, forKey: .orientation) {
            orientation = stringOrientation
        } else if let intOrientation = try? container.decodeIfPresent(Int.self, forKey: .orientation) {
            orientation = String(intOrientation)
        } else {
            orientation = nil
        }
    }
}

struct People: Codable, Identifiable {
    var id: String
    var name: String
    var isHidden: Bool
    var isFavorite: Bool
    var faces: [FaceBox]? = nil
}

struct FaceBox: Codable, Equatable {
    var id: String?
    var boundingBoxX1: Double?
    var boundingBoxX2: Double?
    var boundingBoxY1: Double?
    var boundingBoxY2: Double?
    var imageWidth: Int?
    var imageHeight: Int?
    var sourceType: String?
}

struct PeopleListResponse: Decodable {
    let people: [People]
}

struct PersonAssetsCount: Codable {
    var assets: Int
}

struct RandomAssetRequestBody: Codable {
    var size: Int
    var albumIds: [String]?
    var city: String?
    var state: String?
    var country: String?
    var createdAfter: String?
    var createdBefore: String?
    // A nil isFavorite is left out of the JSON; random playback includes both favorites and non-favorites.

    var isFavorite: Bool? = nil
    var isMotion: Bool?
    var isOffline: Bool = false
    var personIds: [String]?
    var type: String?
    var visibility: String?
    var withDeleted: Bool = false
    var withExif: Bool = true
    var withPeople: Bool = true
    var withStacked: Bool = true
}

struct FilterSelection: Codable, Equatable {
    var albumIds: [String] = []
    var personFilters: [PersonFilter] = []
    var tagIds: [String] = []
    var rating: Int? = nil
    var isFavorite: Bool? = nil
    // tag/rating/favorite count toward isEmpty so the start button can be enabled; the Resolver only uses albums
    // and people.
    var isEmpty: Bool {
        albumIds.isEmpty && personFilters.isEmpty && tagIds.isEmpty && rating == nil && isFavorite == nil
    }
}

struct PersonFilter: Codable, Equatable {
    var personId: String
    var matchMode: PersonMatchMode
}

struct PlaybackSettings: Codable, Equatable {
    var autoPlayEnabled: Bool = true
    var intervalSeconds: Double = 5
    var showExif: Bool = true
    var defaultPlaybackMode: DefaultPlaybackMode = .random
    var showDebugOverlay: Bool = false
    var displayMode: PlaybackDisplayMode = .smartFill

    init(
        autoPlayEnabled: Bool = true,
        intervalSeconds: Double = 5,
        showExif: Bool = true,
        defaultPlaybackMode: DefaultPlaybackMode = .random,
        showDebugOverlay: Bool = false,
        displayMode: PlaybackDisplayMode = .smartFill
    ) {
        self.autoPlayEnabled = autoPlayEnabled
        self.intervalSeconds = intervalSeconds
        self.showExif = showExif
        self.defaultPlaybackMode = defaultPlaybackMode
        self.showDebugOverlay = showDebugOverlay
        self.displayMode = displayMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PlaybackSettings()
        autoPlayEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoPlayEnabled) ?? defaults.autoPlayEnabled
        intervalSeconds =
            try container.decodeIfPresent(Double.self, forKey: .intervalSeconds) ?? defaults.intervalSeconds
        showExif = try container.decodeIfPresent(Bool.self, forKey: .showExif) ?? defaults.showExif
        defaultPlaybackMode =
            try container.decodeIfPresent(DefaultPlaybackMode.self, forKey: .defaultPlaybackMode)
            ?? defaults.defaultPlaybackMode
        showDebugOverlay =
            try container.decodeIfPresent(Bool.self, forKey: .showDebugOverlay) ?? defaults.showDebugOverlay
        displayMode =
            try container.decodeIfPresent(PlaybackDisplayMode.self, forKey: .displayMode) ?? defaults.displayMode
    }
}

extension Asset {
    static var previewAssets: [Asset] {
        [
            Asset(
                id: "preview-1",
                type: "IMAGE",
                isFavorite: false,
                isTrashed: false,
                isArchived: false,
                exifInfo: ExifInfo(
                    make: "Canon",
                    model: "EOS R5",
                    dateTimeOriginal: "2025-12-11T01:11:29.786+00:00",
                    timeZone: "UTC+8",
                    lensModel: "RF 24-70mm f/2.8L",
                    fNumber: 2.8,
                    focalLength: 50.0,
                    iso: 400,
                    exposureTime: "1/125",
                    latitude: 39.9042,
                    longitude: 116.4074,
                    city: "Beijing",
                    state: "Beijing",
                    country: "China",
                    rating: 5
                ),
                people: nil,
                tags: nil,
                livePhotoVideoID: nil
            ),
            Asset(
                id: "preview-2",
                type: "IMAGE",
                isFavorite: false,
                isTrashed: false,
                isArchived: false,
                exifInfo: ExifInfo(
                    make: "Apple",
                    model: "iPhone 15 Pro",
                    dateTimeOriginal: "2024-01-15T10:30:00",
                    timeZone: nil,
                    lensModel: nil,
                    fNumber: 1.8,
                    focalLength: 26.0,
                    iso: 200,
                    exposureTime: "1/60",
                    latitude: nil,
                    longitude: nil,
                    city: nil,
                    state: nil,
                    country: nil,
                    rating: nil
                ),
                people: nil,
                tags: nil,
                livePhotoVideoID: nil
            ),
            Asset(
                id: "04a59c76-1a09-447c-a5ac-0ae73f52dd4e",
                type: "IMAGE",
                isFavorite: false,
                isTrashed: false,
                isArchived: false,
                exifInfo: ExifInfo(
                    make: "Apple",
                    model: "iPhone 15 Pro Max",
                    dateTimeOriginal: "2025-12-11T01:11:29.786+00:00",
                    timeZone: "UTC+8",
                    lensModel: "iPhone 15 Pro Max back camera 6.765mm f/1.78",
                    fNumber: 1.78,
                    focalLength: 24.0,
                    iso: 125,
                    exposureTime: "1/120",
                    latitude: 39.9042,
                    longitude: 116.4074,
                    city: "Beijing",
                    state: "Beijing",
                    country: "China",
                    rating: 5
                ),
                people: nil,
                tags: nil,
                livePhotoVideoID: nil
            )
        ]
    }
}
