import XCTest

final class PrivateEvidenceDirectoryTests: XCTestCase {
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
