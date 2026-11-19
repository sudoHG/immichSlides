import XCTest

extension XCTestCase {
    func requireTestServerConfig() throws -> (url: String, apiKey: String) {

        guard let configuration = TestServerConfiguration.current else {
            throw XCTSkip("No test server is configured in the environment or in Config/env.xcconfig.")
        }

        return (url: configuration.serverURL, apiKey: configuration.apiKey)
    }
}
