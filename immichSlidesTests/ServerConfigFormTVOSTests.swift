// Regression tests for the visual parameters of the tvOS first-launch configuration form.

import Foundation
import Testing
@testable import immichSlides

#if os(tvOS)
import SwiftUI
import UIKit

@Suite
struct ServerConfigFormTVOSTests {

    @Test
    func `input font size is larger than placeholder font size`() {
        #expect(TVOSServerConfigFormMetrics.inputFontSize > TVOSServerConfigFormMetrics.placeholderFontSize)
    }

    @Test
    func `input capsule height meets tvOS accessible tap target of >=44`() {
        #expect(TVOSServerConfigFormMetrics.inputCapsuleHeight >= 44)
    }

    @MainActor
    @Test
    func `plain text field commits final value to binding on end editing`() {
        var committedText = ""
        let binding = Binding<String>(
            get: { committedText },
            set: { committedText = $0 }
        )

        let coordinator = TVSystemCapsuleTextFieldCoordinator(text: binding, isSecure: false)
        let textField = UITextField()
        textField.text = "http://127.0.0.1:9"

        coordinator.textFieldDidEndEditing(textField)

        #expect(committedText == "http://127.0.0.1:9")
    }

    @MainActor
    @Test
    func `secure field commits final value to binding and restores secure entry on end editing`() {
        var committedText = ""
        let binding = Binding<String>(
            get: { committedText },
            set: { committedText = $0 }
        )

        let coordinator = TVSystemCapsuleTextFieldCoordinator(text: binding, isSecure: true)
        let textField = UITextField()
        textField.isSecureTextEntry = false
        textField.text = "fake-key"

        coordinator.textFieldDidEndEditing(textField)

        #expect(committedText == "fake-key")
        #expect(textField.isSecureTextEntry)
        #expect(textField.text == "fake-key")
    }
}
#endif
