import Foundation
import XCTest

struct StrictE2EInput {
    let serverURL: String
    let publicKey: String
}

private enum StrictE2ETestSupportError: LocalizedError {
    case missingInput(String)
    case invalidServerURL
    case nonPublicKey

    var errorDescription: String? {
        switch self {
        case .missingInput(let key):
            return "strict E2E runner is missing input key: \(key)"
        case .invalidServerURL:
            return "strict E2E only allows a 127.0.0.1/localhost /api server address."
        case .nonPublicKey:
            return "strict E2E only allows the public synthetic server key."
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
}
