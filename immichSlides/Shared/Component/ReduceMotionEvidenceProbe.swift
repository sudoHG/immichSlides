#if DEBUG
import SwiftUI
import UIKit

/// Read-only system evidence; the playback reducer still receives only its existing SwiftUI environment value.
struct ReduceMotionEvidenceProbe: View {
    @Environment(\.accessibilityReduceMotion) private var isReduceMotionEnabled
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if PlatformCompat.reduceMotionEvidenceDirectoryForTesting != nil {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .task { record("initial") }
                .onChange(of: isReduceMotionEnabled) { _, _ in record("environment") }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { record("active") }
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: UIAccessibility.reduceMotionStatusDidChangeNotification)
                ) {
                    _ in record("notification")
                }
        }
    }

    private func record(_ reason: String) {
        ReduceMotionEvidenceRecorder.shared.record(reason, swiftUI: isReduceMotionEnabled)
    }
}

@MainActor
private final class ReduceMotionEvidenceRecorder {
    static let shared = ReduceMotionEvidenceRecorder()
    private let launchNonce = UUID().uuidString
    private var samples: [[String: Any]] = []
    private var notificationCount = 0

    func record(_ reason: String, swiftUI: Bool) {
        guard let directory = PlatformCompat.reduceMotionEvidenceDirectoryForTesting, samples.count <= 128 else {
            return
        }
        if reason == "notification" { notificationCount += 1 }
        let state: String
        switch UIApplication.shared.applicationState {
        case .active: state = "active"
        case .inactive: state = "inactive"
        case .background: state = "background"
        @unknown default: state = "unknown"
        }
        samples.append([
            "sequence": samples.count + 1, "wall_time": Date().timeIntervalSince1970,
            "uptime": ProcessInfo.processInfo.systemUptime, "reason": reason,
            "ui_kit": UIAccessibility.isReduceMotionEnabled, "swift_ui": swiftUI,
            "notification_count": notificationCount, "app_state": state
        ])
        guard
            let bytes = try? JSONSerialization.data(
                withJSONObject: ["schema": "strict-e2e-motion-app-v1", "launch_nonce": launchNonce, "samples": samples],
                options: [.sortedKeys])
        else { return }
        try? bytes.write(to: directory.appendingPathComponent("motion-app-evidence.json"), options: .atomic)
    }
}
#endif
