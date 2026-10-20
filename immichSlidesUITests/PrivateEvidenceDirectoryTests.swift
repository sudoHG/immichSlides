import XCTest

final class PrivateEvidenceDirectoryTests: XCTestCase {
    override func invokeTest() {
        FirstFailureContext.reset()
        super.invokeTest()
    }

    override func record(_ issue: XCTIssue) {
        FirstFailureEvidence.record(self, issue: issue)
        super.record(issue)
    }

    @MainActor
    func testThrownBusinessFailureIsRecordedBeforeTeardown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var cases: [XCTestCase] = [self]
        var keys = ["PrivateEvidenceDirectoryTests/testThrownBusinessFailureIsRecordedBeforeTeardown"]
        #if os(iOS)
        let method = "testSyntheticThrownFailureIdentity"
        cases.append(immichSlidesUITests(selector: NSSelectorFromString(method)))
        keys.append("immichSlidesUITests/\(method)")
        #endif
        let skipped = PrivateEvidenceDirectoryTests(
            selector: NSSelectorFromString("testSyntheticSkippedFailureIdentity"))
        let skippedIndex = keys.count
        keys.append("PrivateEvidenceDirectoryTests/testSyntheticSkippedFailureIdentity")
        let map = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($0.element, $0.offset) })
        let tests = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: map), encoding: .utf8))
        let environment = [
            "STRICT_E2E_FIRST_FAILURE_ENABLED": "1",
            "STRICT_E2E_FIRST_FAILURE_DIR": root.path,
            "STRICT_E2E_FIRST_FAILURE_TESTS": tests,
            "STRICT_E2E_FIRST_FAILURE_ELEMENTS": "[\"unknown\",\"app-window\"]",
            "STRICT_E2E_FIRST_FAILURE_SCREENSHOT": "0",
            "STRICT_E2E_INPUT_SERVER_URL": "http://127.0.0.1/api",
            "STRICT_E2E_INPUT_PUBLIC_KEY": "immichslides-public-e2e-key"
        ]
        let original = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            setenv(key, value, 1)
        }
        defer {
            for key in environment.keys {
                if let value = original[key] { setenv(key, value, 1) } else { unsetenv(key) }
            }
            FirstFailureContext.reset()
        }
        FirstFailureContext.reset()
        func runBusinessFlow(_ test: XCTestCase) throws {
            defer { FirstFailureContext.action("terminate") {} }
            try FirstFailureEvidence.preservingThrownFailure(test) {
                FirstFailureContext.mark("wait-scene", element: "app-window")
                FirstFailureContext.action("play-pause") {}
                try AccessLifecycleContract.assertContinueEarlyStillSameScene(
                    continueMark: "A1", earlyMark: "A2", elapsedSeconds: 1, intervalSeconds: 30)
            }
        }
        for (index, test) in cases.enumerated() {
            XCTAssertThrowsError(try runBusinessFlow(test)) { error in
                XCTAssertEqual(
                    String(describing: error),
                    String(
                        describing: AccessLifecycleContract.AssertionError.message(
                            "The same public pattern must stay for the first half of T after Continue")))
            }
            let data = try Data(contentsOf: root.appendingPathComponent("\(index).json"))
            let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(receipt["action"] as? String, "play-pause")
            XCTAssertEqual(receipt["step"] as? String, "wait-scene")
            let timing = try XCTUnwrap(receipt["timing"] as? [String: Any])
            XCTAssertNotNil(timing["since_action_returned_seconds"] as? Double)
            XCTAssertEqual(FirstFailureContext.snapshot().timeline.action, "terminate")
        }
        XCTAssertThrowsError(
            try FirstFailureEvidence.preservingThrownFailure(skipped) { throw XCTSkip("Synthetic environment skip") }
        ) { error in
            XCTAssertTrue(error is XCTSkip)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(skippedIndex).json").path))
    }

    func testMissingRootDoesNotCreateImplicitRepositoryFallback() throws {
        let directory = try PrivateEvidenceDirectory.resolve(
            rootPath: nil,
            components: ["ui-runtime", "privacy-gate-test"]
        )

        XCTAssertNil(directory)
    }

    func testGitWorktreePathReturnsExactSanitizedError() throws {
        let fixture = try makeGitWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let requestedPath = fixture.repository.appendingPathComponent("ui-runtime")

        assertInsideGitWorktreeError(rootPath: requestedPath.path)
    }

    func testSymlinkIntoGitWorktreeReturnsExactSanitizedError() throws {
        let fixture = try makeGitWorktreeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let symlink = fixture.container.appendingPathComponent("repository-link")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: fixture.repository
        )

        assertInsideGitWorktreeError(
            rootPath: symlink.appendingPathComponent("motion-runtime").path
        )
    }

    func testLinkedWorktreeGitFileReturnsExactSanitizedError() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("immichSlides-linked-worktree-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        try "gitdir: synthetic-common-dir\n".write(
            to: repository.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )

        assertInsideGitWorktreeError(
            rootPath: repository.appendingPathComponent("ui-runtime").path
        )
    }

    func testOutsideGitDirectoryUsesOwnerOnlyPermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("immichSlides-private-evidence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = try XCTUnwrap(
            PrivateEvidenceDirectory.resolve(
                rootPath: root.path,
                components: ["ui-runtime", "privacy-gate-test"]
            )
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)

        XCTAssertEqual(permissions.intValue & 0o777, 0o700)
    }

    private func makeGitWorktreeFixture() throws -> (
        container: URL,
        repository: URL
    ) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("immichSlides-git-fixture-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        return (container, repository)
    }

    private func assertInsideGitWorktreeError(
        rootPath: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try PrivateEvidenceDirectory.resolve(
                rootPath: rootPath,
                components: ["privacy-gate-test"]
            )
            XCTFail("An evidence directory inside a Git worktree must be rejected", file: file, line: line)
        } catch PrivateEvidenceDirectory.ResolutionError.insideGitWorktree {
            XCTAssertFalse(
                PrivateEvidenceDirectory.ResolutionError.insideGitWorktree
                    .localizedDescription
                    .contains(rootPath),
                file: file,
                line: line
            )
        } catch {
            XCTFail(
                "Expected insideGitWorktree, got \(type(of: error))",
                file: file,
                line: line
            )
        }
    }
}
