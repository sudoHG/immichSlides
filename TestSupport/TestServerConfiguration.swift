//
//  TestServerConfiguration.swift
//  TestSupport
//
//  Shared test server configuration for Tests and UITests; UI tests do not import the app module.
//

import Foundation

struct TestServerConfiguration {

    let serverURL: String
    let apiKey: String
    let exifDiagnosticAlbumID: String?

    static let current: TestServerConfiguration? = resolve()

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sourceFilePath: String = #filePath
    ) -> TestServerConfiguration? {
        // Process environment wins so a CI or xcodebuild injection overrides a leftover local env.xcconfig.
        guard
            let configuration = fromEnvironment(environment)
                ?? fromLocalEnvXCConfig(sourceFilePath: sourceFilePath)
        else {
            return nil
        }

        return TestServerConfiguration(
            serverURL: configuration.serverURL,
            apiKey: configuration.apiKey,
            exifDiagnosticAlbumID: resolvedExifDiagnosticAlbumID(
                environment: environment,
                sourceFilePath: sourceFilePath
            )
        )
    }

    private static func fromEnvironment(_ environment: [String: String]) -> TestServerConfiguration? {
        let rawURL = firstNonEmptyValue(
            for: [
                "IMMICH_TEST_SERVER_URL",
                "IMMICH_TEST_URL",
                "TEST_RUNNER_IMMICH_TEST_SERVER_URL",
                "TEST_RUNNER_IMMICH_TEST_URL",
                "IMMICH_SERVER_URL",
                "TEST_RUNNER_IMMICH_SERVER_URL"
            ],
            in: environment
        )

        let rawAPIKey = firstNonEmptyValue(
            for: [
                "IMMICH_TEST_API_KEY",
                "TEST_RUNNER_IMMICH_TEST_API_KEY",
                "IMMICH_API_KEY",
                "TEST_RUNNER_IMMICH_API_KEY"
            ],
            in: environment
        )

        return makeConfiguration(rawURL: rawURL, rawAPIKey: rawAPIKey)
    }

    private static func fromLocalEnvXCConfig(sourceFilePath: String) -> TestServerConfiguration? {
        guard let values = localEnvXCConfigValues(sourceFilePath: sourceFilePath) else { return nil }
        let rawURL = firstNonEmptyValue(
            for: ["IMMICH_TEST_SERVER_URL", "IMMICH_TEST_URL", "IMMICH_SERVER_URL"],
            in: values
        )
        let rawAPIKey = firstNonEmptyValue(
            for: ["IMMICH_TEST_API_KEY", "IMMICH_API_KEY"],
            in: values
        )

        return makeConfiguration(rawURL: rawURL, rawAPIKey: rawAPIKey)
    }

    private static func resolvedExifDiagnosticAlbumID(
        environment: [String: String],
        sourceFilePath: String
    ) -> String? {
        if let fromEnvironment = firstNonEmptyValue(
            for: [
                "IMMICH_TEST_EXIF_DIAGNOSTIC_ALBUM_ID",
                "TEST_RUNNER_IMMICH_TEST_EXIF_DIAGNOSTIC_ALBUM_ID"
            ],
            in: environment
        ) {
            return fromEnvironment
        }

        guard let values = localEnvXCConfigValues(sourceFilePath: sourceFilePath) else { return nil }
        return firstNonEmptyValue(
            for: ["IMMICH_TEST_EXIF_DIAGNOSTIC_ALBUM_ID"],
            in: values
        )
    }

    private static func localEnvXCConfigValues(sourceFilePath: String) -> [String: String]? {
        // This file is one level below the repository root, so go up two levels to reach it.

        let currentFileURL = URL(fileURLWithPath: sourceFilePath)
        let repositoryRootURL = currentFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let envFileURL = repositoryRootURL.appendingPathComponent("Config/env.xcconfig")

        guard FileManager.default.fileExists(atPath: envFileURL.path) else { return nil }
        guard let content = try? String(contentsOf: envFileURL, encoding: .utf8) else { return nil }
        return parseXCConfig(content)
    }

    private static func makeConfiguration(rawURL: String?, rawAPIKey: String?) -> TestServerConfiguration? {
        guard let rawURL, let rawAPIKey else { return nil }

        let normalizedURL = decodeXCConfigEscapes(in: rawURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = decodeXCConfigEscapes(in: rawAPIKey)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedURL.isEmpty, !trimmedAPIKey.isEmpty else { return nil }
        guard normalizedURL != "https://your-server.example.com/api" else { return nil }
        guard trimmedAPIKey != "YOUR_API_KEY" else { return nil }

        return TestServerConfiguration(
            serverURL: normalizedURL,
            apiKey: trimmedAPIKey,
            exifDiagnosticAlbumID: nil
        )
    }

    private static func firstNonEmptyValue(for keys: [String], in source: [String: String]) -> String? {
        for key in keys {
            guard let rawValue = source[key] else { continue }

            let trimmedValue = decodeXCConfigEscapes(in: rawValue)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedValue.isEmpty {
                return trimmedValue
            }
        }
        return nil
    }

    private static func parseXCConfig(_ content: String) -> [String: String] {
        var values: [String: String] = [:]

        for rawLine in content.components(separatedBy: .newlines) {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty, !trimmedLine.hasPrefix("//") else { continue }
            guard let equalIndex = trimmedLine.firstIndex(of: "=") else { continue }

            let key = String(trimmedLine[..<equalIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = String(trimmedLine[trimmedLine.index(after: equalIndex)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !key.isEmpty else { continue }
            values[key] = stripWrappingQuotes(from: rawValue)
        }

        return values
    }

    private static func stripWrappingQuotes(from rawValue: String) -> String {
        guard rawValue.count >= 2, rawValue.hasPrefix("\""), rawValue.hasSuffix("\"") else {
            return rawValue
        }
        return String(rawValue.dropFirst().dropLast())
    }

    private static func decodeXCConfigEscapes(in rawValue: String) -> String {
        rawValue.replacingOccurrences(of: "/$()/", with: "//")
    }
}
