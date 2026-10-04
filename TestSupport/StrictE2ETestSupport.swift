import Foundation
import XCTest

struct StrictE2EInput {
    let serverURL: String
    let publicKey: String
}

struct StrictE2EPrivatePINInput {
    static let requiredPINLength: Int = 6
    let correct: String
    let wrong: String
}

private enum StrictE2ETestSupportError: LocalizedError {
    case missingInput(String)
    case invalidServerURL
    case nonPublicKey
    case invalidPINFormat(String)
    case pinsNotDistinct

    var errorDescription: String? {
        switch self {
        case .missingInput(let key):
            return "strict E2E runner is missing input key: \(key)"
        case .invalidServerURL:
            return "strict E2E only allows a 127.0.0.1/localhost /api server address."
        case .nonPublicKey:
            return "strict E2E only allows the public synthetic server key."
        case .invalidPINFormat(let key):
            return "strict E2E private PIN input has an invalid format: \(key)"
        case .pinsNotDistinct:
            return "strict E2E correct PIN and wrong PIN must differ"
        }
    }
}

extension XCTestCase {
    func requireStrictE2EInput(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> StrictE2EInput {
        let urlKey = "STRICT_E2E_INPUT_SERVER_URL"
        let publicKeyKey = "STRICT_E2E_INPUT_PUBLIC_KEY"
        guard let serverURL = environment[urlKey], !serverURL.isEmpty else {
            throw StrictE2ETestSupportError.missingInput(urlKey)
        }
        guard let publicKey = environment[publicKeyKey], !publicKey.isEmpty else {
            throw StrictE2ETestSupportError.missingInput(publicKeyKey)
        }
        guard let url = URL(string: serverURL),
            url.scheme == "http",
            ["127.0.0.1", "localhost"].contains(url.host ?? ""),
            url.path == "/api"
        else {
            throw StrictE2ETestSupportError.invalidServerURL
        }
        let allowedPublicKeys = [
            "immichslides-public-e2e-key",
            "immichslides-public-e2e-wrong-key"
        ]
        guard allowedPublicKeys.contains(publicKey) else {
            throw StrictE2ETestSupportError.nonPublicKey
        }
        return StrictE2EInput(serverURL: serverURL, publicKey: publicKey)
    }

    func requireStrictE2EPeerServerURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        // Either environment key can provide the peer-server URL; both are accepted for compatibility.
        let tvKey = "STRICT_E2E_INPUT_SERVER_B_URL"
        let iosKey = "STRICT_E2E_INPUT_SERVER_URL_B"
        let serverURL: String
        if let value = environment[tvKey], !value.isEmpty {
            serverURL = value
        } else if let value = environment[iosKey], !value.isEmpty {
            serverURL = value
        } else {
            throw StrictE2ETestSupportError.missingInput("\(tvKey)|\(iosKey)")
        }
        guard let url = URL(string: serverURL),
            url.scheme == "http",
            ["127.0.0.1", "localhost"].contains(url.host ?? ""),
            url.path == "/api"
        else {
            throw StrictE2ETestSupportError.invalidServerURL
        }
        return serverURL
    }

    // PINs are read only from the runner environment outside Git; source constants are not accepted, and errors
    // report only key names.
    func requirePrivatePINInput(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> StrictE2EPrivatePINInput {
        let correctKey = "STRICT_E2E_INPUT_PIN"
        let wrongKey = "STRICT_E2E_INPUT_PIN_WRONG"
        guard let correct = firstEnvironmentValue(forKey: correctKey, environment: environment) else {
            throw StrictE2ETestSupportError.missingInput(correctKey)
        }
        guard let wrong = firstEnvironmentValue(forKey: wrongKey, environment: environment) else {
            throw StrictE2ETestSupportError.missingInput(wrongKey)
        }
        guard isPrivatePINFormat(correct) else {
            throw StrictE2ETestSupportError.invalidPINFormat(correctKey)
        }
        guard isPrivatePINFormat(wrong) else {
            throw StrictE2ETestSupportError.invalidPINFormat(wrongKey)
        }
        guard correct != wrong else {
            throw StrictE2ETestSupportError.pinsNotDistinct
        }
        return StrictE2EPrivatePINInput(correct: correct, wrong: wrong)
    }

    @MainActor
    func launchStrictE2EApp() throws -> XCUIApplication {
        let app = XCUIApplication()
        try prepareStrictE2ELaunch(app)
        app.launch()
        return app
    }

    // Cold relaunch reuses the same container and clears launchEnvironment so no UI_TEST_* / IMMICH_TEST_* keys linger.
    @MainActor
    func relaunchStrictE2EApp(_ app: XCUIApplication) throws {
        app.terminate()
        try prepareStrictE2ELaunch(app)
        app.launch()
    }

    @MainActor
    func attachStrictE2EScreenshot(app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func prepareStrictE2ELaunch(_ app: XCUIApplication) throws {
        app.launchEnvironment = [:]

        let audit = try JSONSerialization.data(
            withJSONObject: ["launch_environment_keys": app.launchEnvironment.keys.sorted()],
            options: [.prettyPrinted, .sortedKeys]
        )
        let attachment = XCTAttachment(data: audit, uniformTypeIdentifier: "public.json")
        attachment.name = "strict-e2e-app-launch-environment-audit"
        attachment.lifetime = XCTAttachment.Lifetime.keepAlways
        add(attachment)
    }

    private func firstEnvironmentValue(
        forKey key: String,
        environment: [String: String]
    ) -> String? {
        for candidate in [environment[key], environment["TEST_RUNNER_\(key)"]] {
            if let value = candidate, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func isPrivatePINFormat(_ pin: String) -> Bool {
        pin.count == StrictE2EPrivatePINInput.requiredPINLength && pin.allSatisfy(\.isNumber)
    }
}
