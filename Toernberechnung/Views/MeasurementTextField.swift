import SwiftUI
import UIKit

// MARK: - MeasurementTextField

/// Einstellungszeile zur direkten Eingabe eines Dezimalwerts.
///
/// Vorgaben:
/// - `.decimalPad` bietet Ziffern und Dezimaltrennzeichen.
/// - `UITextFieldDelegate` lässt nur Ziffern, Komma und Punkt zu.
/// - Nach dem Bearbeiten erscheint der Wert im deutschen Format mit
///   einer Nachkommastelle, z. B. "0.1" → "0,1".
/// - Die `@AppStorage`-Zeichenkette behält das interne Punktformat, z. B. "10.5".

struct MeasurementTextField: View {
    let title: String
    @Binding var storage: String
    var unit: String = "m"
    let icon: String
    let identifier: String

    /// Text im Eingabefeld: deutsches Format mit Komma
    /// und einer Nachkommastelle.
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

            // UIKit-UITextField einbinden, damit ein Delegate unzulässige
            // Zeichen ablehnt, bevor sie das Datenmodell erreichen.
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

    // MARK: - Hilfsfunktionen

    /// Liest `displayText`, speichert den normalisierten Wert mit Dezimalpunkt
    /// in `storage` und aktualisiert anschließend die Anzeige.
    private func commitValue() {
        let parsed = parseToDouble(displayText)
        let clamped = max(parsed, 0)
        // Dezimalpunkt für die Datenebene, z. B. "10.5"
        storage = String(format: "%.1f", clamped)
        // Dezimalkomma für die Oberfläche, z. B. "10,5"
        displayText = formatForDisplay(storage)
    }

    /// Wandelt den gespeicherten Wert mit Dezimalpunkt in eine deutsche
    /// Anzeige mit genau einer Nachkommastelle um.
    private func formatForDisplay(_ dotDecimal: String) -> String {
        let value = parseToDouble(dotDecimal)
        // "X,X" mit dem deutschen Zahlenformatierer erstellen.
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? "0,0"
    }

    /// Liest eine Zahl mit Punkt oder Komma als Dezimaltrennzeichen.
    private func parseToDouble(_ text: String) -> Double {
        let normalised = text
            .replacingOccurrences(of: ",", with: ".")
        return Double(normalised) ?? 0
    }
}

// MARK: - NumericUITextField (UIViewRepresentable)

/// Bindet ein `UITextField` mit `.decimalPad` und einem Delegate ein,
/// der nur Zeichen aus `0-9 , .` zulässt.
///
/// Damit werden Buchstaben, Emoji und andere Symbole auch bei
/// Tastaturen von Drittanbietern abgelehnt.
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
        // Schaltfläche "Fertig" zur Zahlentastatur hinzufügen
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
        // Nur ohne Eingabefokus aktualisieren, damit laufende
        // Eingaben des Nutzers nicht überschrieben werden.
        if !field.isFirstResponder {
            field.text = text
        }
    }

    // MARK: Koordinator

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NumericUITextField

        init(_ parent: NumericUITextField) {
            self.parent = parent
        }

        // Alle Zeichen außer Ziffern, Komma und Punkt ablehnen.
        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            // Löschen zulassen
            if string.isEmpty { return true }

            let allowed = CharacterSet(charactersIn: "0123456789,.")
            let incoming = CharacterSet(string.unicodeScalars.map { $0 })
            guard incoming.isSubset(of: allowed) else { return false }

            // Mehr als ein Dezimaltrennzeichen verhindern.
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
