//
//  FirstBootView.swift
//  immichSlides
//
//  Created by sudoHG on 2026/1/7.
//

import SwiftUI

struct FirstBootView: View {
    @Environment(\.scenePhase) private var scenePhase

    let onConfigure: () -> Void

    @StateObject private var serverVM = SettingsServerViewModel()

    init(onConfigure: @escaping () -> Void) {
        self.onConfigure = onConfigure
    }

    var body: some View {
        Group {
            #if os(tvOS)
            FirstBootViewTV(
                serverURL: $serverVM.serverURL,
                apiKey: $serverVM.apiKey,
                isConnectionVerified: serverVM.isConnectionVerified,
                isTestingConnection: serverVM.isTestingConnection,
                statusMessage: serverVM.statusMessage,
                onTestConnection: { serverVM.testConnection() },
                onSave: { serverVM.saveServerConfig() }
            )
            #else
            FirstBootViewIOS(
                serverURL: $serverVM.serverURL,
                apiKey: $serverVM.apiKey,
                isConnectionVerified: serverVM.isConnectionVerified,
                isTestingConnection: serverVM.isTestingConnection,
                testingStatusMessage: serverVM.testingStatusMessage,
                statusMessage: serverVM.statusMessage,
                onTestConnection: { serverVM.testConnection() },
                onSave: { serverVM.saveServerConfig() }
            )
            #endif
        }
        // Changing the URL/Key invalidates the verified state right away, so a stale result is not saved by mistake.
        .onChange(of: serverVM.serverURL) { _, _ in
            serverVM.invalidateVerification()
        }
        .onChange(of: serverVM.apiKey) { _, _ in
            serverVM.invalidateVerification()
        }
        .onChange(of: serverVM.didSaveConfig) { _, didSave in
            if didSave {
                onConfigure()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                serverVM.resumePendingConnectionTestIfNeeded()
            }
        }
        .alert(serverVM.errorAlertTitle, isPresented: $serverVM.showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(serverVM.errorMessage))
        }
    }
}

#Preview {
    FirstBootView(onConfigure: {})
}
