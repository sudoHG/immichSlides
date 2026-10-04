//
//  IOSServerConfigTextInput.swift
//  immichSlides
//

import SwiftUI
import UIKit

// Wraps only the system TextField/SecureField; a saved API Key shows system dots, with no custom-drawn mask.
struct IOSServerConfigTextInput<Field: Hashable>: View {
    let placeholder: LocalizedStringResource
    @Binding var text: String
    let isSecure: Bool
    let field: Field
    let focusedField: FocusState<Field?>.Binding
    let font: Font
    let textColor: Color
    let cornerRadius: CGFloat
    let brightness: Double
    let accessibilityIdentifier: String

    var body: some View {
        Group {
            if isSecure {
                SecureField(String(localized: placeholder), text: $text)
            } else {
                TextField(String(localized: placeholder), text: $text)
            }
        }
        .appFormTextInputBehavior()
        // API Key uses oneTimeCode to avoid iPad password autofill while still using secure system input.
        .textContentType(textContentType)
        .keyboardType(keyboardType)
        .focused(focusedField, equals: field)
        .font(font)
        .multilineTextAlignment(.leading)
        .foregroundStyle(textColor)
        .padding(.horizontal, 12)
        .submitLabel(.next)
        .accessibilityLabel(Text(String(localized: placeholder)))
        .accessibilityIdentifier(accessibilityIdentifier)
        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .brightness(brightness)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private var textContentType: UITextContentType? {
        isSecure ? .oneTimeCode : .URL
    }

    private var keyboardType: UIKeyboardType {
        isSecure ? .asciiCapable : .URL
    }
}
