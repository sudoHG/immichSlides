import Foundation

enum PrivateEvidenceDirectory {
    enum ResolutionError: LocalizedError {
        case cannotPrepareDirectory
        case insideGitWorktree

        var errorDescription: String? {
            switch self {
            case .cannotPrepareDirectory:
                return "Cannot prepare raw run evidence directory; check the outside-Git path setting and permissions"
            case .insideGitWorktree:
                return "The raw run evidence directory must not be inside a Git worktree"
            }
        }
    }

    static func resolve(
        rootPath: String?,
        components: [String],
        fileManager: FileManager = .default
    ) throws -> URL? {
        guard let rawRootPath = rootPath?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawRootPath.isEmpty
        else {
            return nil
        }

        let root = URL(fileURLWithPath: rawRootPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        try rejectGitWorktreePath(root, fileManager: fileManager)

        let directory = components.reduce(root) { partialResult, component in
            partialResult.appendingPathComponent(component, isDirectory: true)
        }

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )

            let resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
            try rejectGitWorktreePath(resolvedDirectory, fileManager: fileManager)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: resolvedDirectory.path
            )
            return resolvedDirectory
        } catch let error as ResolutionError {
            throw error
        } catch {
            throw ResolutionError.cannotPrepareDirectory
        }
    }

    private static func rejectGitWorktreePath(
        _ directory: URL,
        fileManager: FileManager
    ) throws {
        var candidatePath = directory.standardizedFileURL.path
        while true {
            let candidate = URL(fileURLWithPath: candidatePath, isDirectory: true)
            let gitMarker = candidate.appendingPathComponent(".git")
            if fileManager.fileExists(atPath: gitMarker.path) {
                throw ResolutionError.insideGitWorktree
            }
            let parentPath = (candidatePath as NSString).deletingLastPathComponent
            if parentPath.isEmpty || parentPath == candidatePath {
                return
            }
            candidatePath = parentPath
        }
    }
}
