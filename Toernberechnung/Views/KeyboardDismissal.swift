import SwiftUI
import UIKit

// MARK: - Tap anywhere to dismiss the keyboard
//
// SwiftUI only closes the keyboard on submit or on an interactive scroll
// dismiss. iPhone users expect a plain tap next to the field to work too, so
// we install a single tap recognizer on the app's UIWindow.
//
// Window level is deliberate: sheets (SettingsSheet, the planning sheet,
// CrewEventEditor) are presented into the same window, so one recognizer
// covers every text field in the app. The system keyboard itself lives in a
// separate UIRemoteKeyboardWindow and is therefore never affected.

/// Zero-sized view whose only job is to reach the hosting `UIWindow` once and
/// attach the dismiss recognizer to it.
struct KeyboardDismissGestureInstaller: UIViewRepresentable {

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let probe = UIView(frame: .zero)
        probe.isUserInteractionEnabled = false
        probe.isHidden = true
        // The view is not in a window yet while `makeUIView` runs.
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
            // Never consume the touch: buttons, list rows, map pans and every
            // SwiftUI gesture keep receiving it unchanged.
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

        /// Ignore taps that land on a text input or any other UIKit control.
        /// Without this, tapping straight from one field into the next would
        /// resign the first responder while the target field claims it.
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
