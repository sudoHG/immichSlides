//
//  RequestModifier.swift
//  immichSlides
//
//  Created by sudoHG on 2026/1/10.
//

import Foundation
import SDWebImage

enum ImmichHTTPHeaders {
    // Use one User-Agent for every request, so a proxy does not allow API calls but block image downloads.
    nonisolated static let userAgent = "immichSlides"

    nonisolated static func applyAPIKey(_ apiKey: String, to request: inout URLRequest) {
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    }
}

struct ImmichRequestModifier {
    @MainActor
    static func create() -> SDWebImageDownloaderRequestModifier? {
        guard let apiKey = ImmichAPIService.shared.getApiKey() else {
            return nil
        }

        return create(apiKey: apiKey)
    }

    // Only takes an already-fetched API Key, so background threads never read the main-actor singleton.
    nonisolated static func create(apiKey: String?) -> SDWebImageDownloaderRequestModifier? {
        guard let apiKey, !apiKey.isEmpty else {
            return nil
        }

        return SDWebImageDownloaderRequestModifier { request in
            var modifiedRequest = request
            ImmichHTTPHeaders.applyAPIKey(apiKey, to: &modifiedRequest)
            return modifiedRequest
        }
    }
}
