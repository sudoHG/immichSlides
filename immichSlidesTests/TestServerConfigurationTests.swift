import Foundation
import Testing

@Suite
struct TestServerConfigurationTests {
    private static let validURL = "https://example.test/api"
    private static let validAPIKey = "test-api-key"

    @Test func `exif diagnostic album id comes from the plain environment key`() throws {
        let configuration = TestServerConfiguration.resolve(
            environment: [
                "IMMICH_TEST_SERVER_URL": Self.validURL,
                "IMMICH_TEST_API_KEY": Self.validAPIKey,
                "IMMICH_TEST_EXIF_DIAGNOSTIC_ALBUM_ID": "album-from-plain-env"
            ],
            sourceFilePath: try isolatedSourceFilePath()
        )

        #expect(configuration?.serverURL == Self.validURL)
        #expect(configuration?.apiKey == Self.validAPIKey)
        #expect(configuration?.exifDiagnosticAlbumID == "album-from-plain-env")
    }

    @Test func `exif diagnostic album id comes from the test runner environment key`() throws {
        let configuration = TestServerConfiguration.resolve(
            environment: [
                "IMMICH_TEST_SERVER_URL": Self.validURL,
                "IMMICH_TEST_API_KEY": Self.validAPIKey,
                "TEST_RUNNER_IMMICH_TEST_EXIF_DIAGNOSTIC_ALBUM_ID": "album-from-runner-env"
            ],
            sourceFilePath: try isolatedSourceFilePath()
        )

        #expect(configuration?.exifDiagnosticAlbumID == "album-from-runner-env")
    }

    @Test func `exif diagnostic album id comes from the local env xcconfig key`() throws {
        let configuration = TestServerConfiguration.resolve(
            environment: [:],
            sourceFilePath: try isolatedSourceFilePath(
                xcconfig: """
                    IMMICH_TEST_SERVER_URL = https:/$()/example.test/api
                    IMMICH_TEST_API_KEY = test-api-key
                    IMMICH_TEST_EXIF_DIAGNOSTIC_ALBUM_ID = album-from-xcconfig
                    """
            )
        )

        #expect(configuration?.serverURL == Self.validURL)
        #expect(configuration?.apiKey == Self.validAPIKey)
        #expect(configuration?.exifDiagnosticAlbumID == "album-from-xcconfig")
    }

    @Test func `exif diagnostic album id from the environment wins over env xcconfig`() throws {
        let configuration = TestServerConfiguration.resolve(
            environment: [
                "IMMICH_TEST_SERVER_URL": Self.validURL,
                "IMMICH_TEST_API_KEY": Self.validAPIKey,
                "IMMICH_TEST_EXIF_DIAGNOSTIC_ALBUM_ID": "album-from-env"
            ],
            sourceFilePath: try isolatedSourceFilePath(
                xcconfig: """
                    IMMICH_TEST_SERVER_URL = https:/$()/other.test/api
                    IMMICH_TEST_API_KEY = other-key
                    IMMICH_TEST_EXIF_DIAGNOSTIC_ALBUM_ID = album-from-xcconfig
                    """
            )
        )

        #expect(configuration?.exifDiagnosticAlbumID == "album-from-env")
    }

    @Test func `server configuration still resolves when the exif diagnostic album id is absent`() throws {
        let configuration = TestServerConfiguration.resolve(
            environment: [
                "IMMICH_TEST_SERVER_URL": Self.validURL,
                "IMMICH_TEST_API_KEY": Self.validAPIKey
            ],
            sourceFilePath: try isolatedSourceFilePath()
        )

        #expect(configuration?.serverURL == Self.validURL)
        #expect(configuration?.apiKey == Self.validAPIKey)
        #expect(configuration?.exifDiagnosticAlbumID == nil)
    }

    @Test func `empty exif diagnostic album id leaves the optional value unset`() throws {
        let fromEnvironment = TestServerConfiguration.resolve(
            environment: [
                "IMMICH_TEST_SERVER_URL": Self.validURL,
                "IMMICH_TEST_API_KEY": Self.validAPIKey,
                "IMMICH_TEST_EXIF_DIAGNOSTIC_ALBUM_ID": "   "
            ],
            sourceFilePath: try isolatedSourceFilePath()
        )
        let fromXCConfig = TestServerConfiguration.resolve(
            environment: [:],
            sourceFilePath: try isolatedSourceFilePath(
                xcconfig: """
                    IMMICH_TEST_SERVER_URL = https:/$()/example.test/api
                    IMMICH_TEST_API_KEY = test-api-key
                    IMMICH_TEST_EXIF_DIAGNOSTIC_ALBUM_ID =
                    """
            )
        )

        #expect(fromEnvironment?.exifDiagnosticAlbumID == nil)
        #expect(fromXCConfig?.exifDiagnosticAlbumID == nil)
    }

    @Test func `an album id alone does not produce a server configuration`() throws {
        let configuration = TestServerConfiguration.resolve(
            environment: [
                "IMMICH_TEST_EXIF_DIAGNOSTIC_ALBUM_ID": "album-only"
            ],
            sourceFilePath: try isolatedSourceFilePath()
        )

        #expect(configuration == nil)
    }

    @Test func `xcconfig album id is used when only the server keys are in the environment`() throws {
        let configuration = TestServerConfiguration.resolve(
            environment: [
                "IMMICH_TEST_SERVER_URL": Self.validURL,
                "IMMICH_TEST_API_KEY": Self.validAPIKey
            ],
            sourceFilePath: try isolatedSourceFilePath(
                xcconfig: """
                    IMMICH_TEST_EXIF_DIAGNOSTIC_ALBUM_ID = album-from-xcconfig-only
                    """
            )
        )

        #expect(configuration?.exifDiagnosticAlbumID == "album-from-xcconfig-only")
    }

    private func isolatedSourceFilePath(xcconfig: String? = nil) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestServerConfigurationTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let support = root.appendingPathComponent("TestSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        if let xcconfig {
            let configDir = root.appendingPathComponent("Config", isDirectory: true)
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            try xcconfig.write(
                to: configDir.appendingPathComponent("env.xcconfig"),
                atomically: true,
                encoding: .utf8
            )
        }
        return support.appendingPathComponent("TestServerConfiguration.swift").path
    }
}
