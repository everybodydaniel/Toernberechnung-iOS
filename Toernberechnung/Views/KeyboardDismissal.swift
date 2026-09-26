import SwiftUI
import UIKit

// MARK: - Tastatur durch Tippen außerhalb schließen
//
// Ergänzt eine Tipp-Erkennung im UIWindow, damit ein Tipp neben ein Textfeld
// die Tastatur schließt. SwiftUI unterstützt dies sonst nur beim Bestätigen
// oder über passende Scrollgesten.
//
// Die Erkennung im Fenster gilt auch für modale Ansichten wie Einstellungen
// und CrewEventEditor. Die Systemtastatur liegt in einem separaten
// UIRemoteKeyboardWindow und ist davon nicht betroffen.

/// Ansicht ohne Größe, die einmal auf das übergeordnete `UIWindow` zugreift
/// und dort die Tipp-Erkennung zum Schließen der Tastatur anbringt.
struct KeyboardDismissGestureInstaller: UIViewRepresentable {

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let probe = UIView(frame: .zero)
        probe.isUserInteractionEnabled = false
        probe.isHidden = true
        // Während `makeUIView` ist die Ansicht noch keinem Fenster zugeordnet.
        DispatchQueue.main.async { [weak probe] in
            context.coordinator.install(in: probe?.window)
        }
        return probe
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.install(in: uiView.window)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var installedWindow: UIWindow?
        private var recognizer: UITapGestureRecognizer?

        func install(in window: UIWindow?) {
            guard let window, window !== installedWindow else { return }
            uninstall()

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            // Berührungen nicht abfangen. Buttons, Listenzeilen, Kartenbewegungen
            // und SwiftUI-Gesten erhalten sie weiterhin unverändert.
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            window.addGestureRecognizer(tap)

            recognizer = tap
            installedWindow = window
        }

        func uninstall() {
            if let recognizer, let installedWindow {
                installedWindow.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            installedWindow = nil
        }

        @objc
        private func handleTap() {
            installedWindow?.endEditing(true)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        /// Tipps auf Textfelder oder andere UIKit-Bedienelemente auslassen.
        /// So verliert beim direkten Wechsel zwischen Feldern nicht das bisherige
        /// Feld den Fokus, während das nächste ihn übernimmt.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UIControl || current is UITextField || current is UITextView {
                    return false
                }
                view = current.superview
            }
            return true
        }
    }
}
