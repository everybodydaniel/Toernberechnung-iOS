import SwiftUI
import UIKit

// MARK: - MeasurementTextField

/// A settings row that lets the user type a decimal measurement value.
///
/// Design constraints:
/// - `.decimalPad` keyboard → no emoji key, no letters.
/// - A `UITextFieldDelegate` blocks any character that is not a digit,
///   comma, or dot at the UIKit level so nothing unwanted ever appears.
/// - On end-of-editing the value is normalised to a German-locale string
///   with exactly **one** fraction digit (e.g. "0.1" → "0,1").
/// - The backing `@AppStorage` string keeps the dot-decimal contract used
///   by the rest of the app (e.g. "10.5").

struct MeasurementTextField: View {
    let title: String
    @Binding var storage: String
    var unit: String = "m"
    let icon: String
    let identifier: String

    /// The display text shown in the text field (German locale, comma
    /// as separator, two fraction digits).
    @State private var displayText: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.appPrimary)
                .frame(width: 28, height: 28)
                .background(Color.appPrimary.opacity(0.12), in: Circle())

            Text(title)
                .font(.subheadline.weight(.semibold))

            Spacer(minLength: 8)

            // We wrap UIKit's UITextField so we can install a delegate that
            // rejects non-numeric characters *before* they reach the model.
            NumericUITextField(
                text: $displayText,
                onCommit: commitValue
            )
            .focused($isFocused)
            .frame(width: 80, height: 36)
            .multilineTextAlignment(.trailing)

            Text(unit)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.secondary)
        }
        .foregroundStyle(Color.primary)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityIdentifier(identifier)
        .onAppear { displayText = formatForDisplay(storage) }
        .onChange(of: storage) { _, newValue in
            if !isFocused {
                displayText = formatForDisplay(newValue)
            }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { commitValue() }
        }
    }

    // MARK: - Helpers

    /// Commit: parse whatever is in `displayText`, write the normalised
    /// dot-decimal string into `storage`, refresh `displayText`.
    private func commitValue() {
        let parsed = parseToDouble(displayText)
        let clamped = max(parsed, 0)
        // Dot-decimal for the data layer ("10.50")
        storage = String(format: "%.1f", clamped)
        // Comma-decimal for the UI ("10,50")
        displayText = formatForDisplay(storage)
    }

    /// Turn the stored dot-decimal string into a German-locale display
    /// string with exactly two fraction digits.
    private func formatForDisplay(_ dotDecimal: String) -> String {
        let value = parseToDouble(dotDecimal)
        // Build "X,XX" using the German number formatter.
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? "0,0"
    }

    /// Parse a string that may use dot *or* comma as decimal separator.
    private func parseToDouble(_ text: String) -> Double {
        let normalised = text
            .replacingOccurrences(of: ",", with: ".")
        return Double(normalised) ?? 0
    }
}

// MARK: - NumericUITextField (UIViewRepresentable)

/// Wraps a `UITextField` with a `.decimalPad` keyboard and a delegate
/// that rejects every character outside `0-9 , .`.
///
/// This gives us hard guarantees that no emoji, letter, or other
/// symbol can ever be entered — regardless of third-party keyboards.
private struct NumericUITextField: UIViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.keyboardType = .decimalPad
        field.textAlignment = .right
        field.font = .systemFont(ofSize: 17, weight: .semibold)
        field.textColor = UIColor.label
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.returnKeyType = .done
        // Add a "Fertig" (Done) button to the decimal pad
        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        let spacer = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let done = UIBarButtonItem(
            title: "Fertig",
            style: .done,
            target: context.coordinator,
            action: #selector(Coordinator.doneTapped)
        )
        toolbar.items = [spacer, done]
        field.inputAccessoryView = toolbar
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textChanged(_:)),
            for: .editingChanged
        )
        field.text = text
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        // Only update when the field is NOT first responder to avoid
        // fighting with the user's live edits.
        if !field.isFirstResponder {
            field.text = text
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NumericUITextField

        init(_ parent: NumericUITextField) {
            self.parent = parent
        }

        // Reject any character that is not a digit, comma, or dot.
        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            // Allow deletions
            if string.isEmpty { return true }

            let allowed = CharacterSet(charactersIn: "0123456789,.")
            let incoming = CharacterSet(string.unicodeScalars.map { $0 })
            guard incoming.isSubset(of: allowed) else { return false }

            // Prevent more than one decimal separator (comma or dot).
            let current = textField.text ?? ""
            if string.contains(",") || string.contains(".") {
                let hasSeparator = current.contains(",") || current.contains(".")
                if hasSeparator { return false }
            }
            return true
        }

        @objc func textChanged(_ sender: UITextField) {
            parent.text = sender.text ?? ""
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.text = textField.text ?? ""
            parent.onCommit()
        }

        @objc func doneTapped() {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
        }
    }
}
