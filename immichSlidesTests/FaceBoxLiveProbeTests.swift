//
//  FaceBoxLiveProbeTests.swift
//  immichSlidesTests
//
//  The live server probe only outputs redacted geometry summaries, never URLs, API keys, raw assetIds, person
//  names or image content.
//

import CryptoKit
import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite(.sharedRuntimeIsolation, .enabled(if: isEvidenceRun))
struct FaceBoxLiveProbeTests {
    private nonisolated static let liveConfiguration = TestServerConfiguration.current
    private nonisolated static let liveEnabled = liveConfiguration != nil

    @Test(.enabled(if: liveEnabled))
    func `random live sample produces a redacted face box geometry report`() async throws {
        try await ServerConfigurationTestIsolation.run {
            configureLiveServer()

            let sampleSize = 25
            let assets = try await ImmichAPIService.shared.getRandomAsset(size: sampleSize)
            let rows = makeReportRows(from: assets)
            let faceRows = rows.filter(\.hasFaces)
            let hasRotated90Or270 = rows.contains { $0.orientationCategory == .rotated90Or270 }

            var lines: [String] = [
                "FACE_BOX_LIVE_PROBE_REDACTED",
                "sampleCount=\(assets.count)",
                "assetsWithFaces=\(faceRows.count)"
            ]

            if !hasRotated90Or270 {
                lines.append("ROTATED_LIVE_SAMPLE_NOT_AVAILABLE")
            }
            if faceRows.isEmpty {
                lines.append("LIVE_FACE_SAMPLE_NOT_AVAILABLE")
            }

            lines += rows.map(\.redactedLine)

            let report = lines.joined(separator: "\n")
            try writeReport(report)
            print(report)

            #expect(assets.count <= sampleSize)
        }
    }

    private func configureLiveServer() {
        guard let configuration = Self.liveConfiguration else { return }
        let server = ImmichServer(
            immichURL: ImmichServer.normalizeServerURL(configuration.serverURL),
            immichApiKey: configuration.apiKey
        )
        server.save()
        ImmichAPIService.shared.reloadServerConfiguration()
    }

    private func makeReportRows(from assets: [Asset]) -> [ProbeRow] {
        assets.map { asset in
            let faces = FaceBoxGeometry.collectFaces(from: asset.people)
            let results = FaceBoxGeometry.validate(faces: faces, asset: asset)
            let orientationCategory = FaceBoxGeometry.orientationCategory(asset.exifInfo?.orientation)
            let summaries = zip(faces, results).map { face, result in
                let relation = FaceBoxGeometry.dimensionRelation(face: face, asset: asset)
                switch result {
                case .usable:
                    return "relation=\(relation.rawValue),result=usable"
                case let .unusable(reason, _):
                    return "relation=\(relation.rawValue),reason=\(reason.rawValue)"
                }
            }

            return ProbeRow(
                assetHashPrefix: shortStableHash(asset.id),
                hasFaces: !faces.isEmpty,
                faceCount: faces.count,
                orientationCategory: orientationCategory,
                faceSummaries: summaries
            )
        }
    }

    private func writeReport(_ report: String) throws {
        let directory = reportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try report.write(
            to: directory.appendingPathComponent("facebox-live-probe-redacted.txt"), atomically: true, encoding: .utf8)
    }

    private func reportDirectory() -> URL {
        let configuredPath = ProcessInfo.processInfo.environment["FACEBOX_LIVE_PROBE_EVIDENCE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configuredPath, !configuredPath.isEmpty else {
            return FileManager.default.temporaryDirectory.appendingPathComponent("FaceBoxLiveProbe", isDirectory: true)
        }
        return URL(fileURLWithPath: configuredPath, isDirectory: true)
    }

    private func shortStableHash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private struct ProbeRow {
        let assetHashPrefix: String
        let hasFaces: Bool
        let faceCount: Int
        let orientationCategory: FaceBoxGeometry.OrientationCategory
        let faceSummaries: [String]

        var redactedLine: String {
            let summary = faceSummaries.isEmpty ? "noFaceBoxes" : faceSummaries.joined(separator: ";")
            return
                "assetHashPrefix=\(assetHashPrefix),faceCount=\(faceCount),orientationCategory=\(orientationCategory.rawValue),\(summary)"
        }
    }
}
