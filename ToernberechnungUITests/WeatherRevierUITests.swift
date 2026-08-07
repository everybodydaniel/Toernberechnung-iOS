import XCTest
import UIKit

final class WeatherRevierUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func makeApp(hasSeenOnboarding: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        if hasSeenOnboarding {
            app.launchArguments += ["-hasSeenOnboarding", "YES"]
        } else {
            app.launchEnvironment["UITEST_RESET_ONBOARDING"] = "1"
        }
        return app
    }

    func testFirstLaunchOnboardingCanBeSkipped() {
        let app = makeApp(hasSeenOnboarding: false)
        app.launch()

        XCTAssertTrue(app.staticTexts["Sicher planen. Klar navigieren."].waitForExistence(timeout: 5))
        app.buttons["Überspringen"].tap()
        XCTAssertTrue(app.staticTexts["Crew, Chats und Termine verbinden."].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Loslegen"].isEnabled)
        app.buttons["onboardingSafetyAcknowledgement"].tap()
        XCTAssertTrue(app.buttons["Loslegen"].isEnabled)
        app.buttons["Loslegen"].tap()
        XCTAssertTrue(app.tabBars.buttons["Karte"].waitForExistence(timeout: 5))
    }

    func testFirstLaunchOnboardingCompletesAllPages() {
        let app = makeApp(hasSeenOnboarding: false)
        app.launch()

        let continueButton = app.buttons["Fortfahren"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        continueButton.tap()
        XCTAssertTrue(app.staticTexts["Wind und Wetter vorausdenken."].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Norderney"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.staticTexts["Behalte Wind, Böen und Vorhersagen für dein Revier und deine Route kompakt im Blick."]
                .waitForExistence(timeout: 3)
        )
        continueButton.tap()
        XCTAssertTrue(app.staticTexts["Crew, Chats und Termine verbinden."].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Loslegen"].isEnabled)
        app.buttons["onboardingSafetyAcknowledgement"].tap()
        XCTAssertTrue(app.buttons["Loslegen"].isEnabled)
        app.buttons["Loslegen"].tap()
        XCTAssertTrue(app.tabBars.buttons["Karte"].waitForExistence(timeout: 5))
    }

    func testRevierWeatherScreenOpensAndRenders() {
        let app = makeApp()
        app.launch()

        let revierTab = app.tabBars.buttons["Revier"]
        XCTAssertTrue(revierTab.waitForExistence(timeout: 10))
        revierTab.tap()

        let forecast = app.staticTexts["48-STUNDEN-VORHERSAGE"]
        let capabilityError = app.staticTexts["WETTER NICHT VERFÜGBAR"]
        let rendered = capabilityError.waitForExistence(timeout: 5) || forecast.waitForExistence(timeout: 10)
        XCTAssertTrue(rendered, "Der Revier-Wetterbereich wurde nicht gerendert.")

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Revier-WeatherKit-iOS26"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testWeatherLocationPickerOpensAndClosesWithoutSystemMenu() {
        let app = makeApp()
        app.launch()

        let revierTab = app.tabBars.buttons["Revier"]
        XCTAssertTrue(revierTab.waitForExistence(timeout: 10))
        revierTab.tap()

        let locationSelector = app.buttons["weather-location-selector"]
        XCTAssertTrue(locationSelector.waitForExistence(timeout: 15))
        locationSelector.tap()

        XCTAssertTrue(app.staticTexts["Revier auswählen"].waitForExistence(timeout: 3))
        let closeButton = app.buttons["Standortauswahl schließen"]
        XCTAssertTrue(closeButton.exists)
        closeButton.tap()
        XCTAssertFalse(app.staticTexts["Revier auswählen"].waitForExistence(timeout: 1))
    }

    func testNautiShowsLocalModelAvailabilityWithoutServerFallback() {
        let app = makeApp()
        app.launch()

        let nautiButton = app.buttons["Nauti Chat öffnen"]
        XCTAssertTrue(nautiButton.waitForExistence(timeout: 12))
        nautiButton.tap()

        let skipperAI = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Skipper-KI")
        ).firstMatch
        XCTAssertTrue(skipperAI.waitForExistence(timeout: 5))
        let visibleOverlay = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: skipperAI
        )
        XCTAssertEqual(XCTWaiter.wait(for: [visibleOverlay], timeout: 5), .completed)

        let historyButton = app.buttons["Chat-Historie öffnen"]
        XCTAssertTrue(historyButton.exists)
        historyButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Verlauf"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["Chats suchen"].exists)
        XCTAssertFalse(app.otherElements["NautiSideDrawer"].exists)

        app.buttons["Zum Chat"].tap()

        let manualFallback = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "manuelle Planung")
        ).firstMatch

        let messageField = app.textFields["Nachricht"]
        XCTAssertTrue(messageField.waitForExistence(timeout: 5))
        if manualFallback.waitForExistence(timeout: 2) {
            XCTAssertFalse(messageField.isEnabled)
        } else {
            XCTAssertTrue(messageField.isEnabled)
        }
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Nauti-Server")
        ).firstMatch.exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Nauti-On-Device-Verfügbarkeit"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testNautiCollapseButtonReturnsToDashboardPill() {
        let app = makeApp()
        app.launch()

        let launcher = app.buttons["Nauti Chat öffnen"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 12))
        launcher.tap()

        let close = app.buttons["Nauti Chat einklappen"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: close
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 2), .completed)
        XCTAssertTrue(app.buttons["Nauti Chat öffnen"].waitForExistence(timeout: 2))
    }

    func testNautiDragHandleCollapsesInlinePanel() {
        let app = makeApp()
        app.launch()

        let launcher = app.buttons["Nauti Chat öffnen"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 12))
        launcher.tap()

        let panel = app.otherElements["NautiInlinePanel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))

        let handle = app.descendants(matching: .any)["NautiInlineDragHandle"]
        XCTAssertTrue(handle.waitForExistence(timeout: 3))
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: 150))
        start.press(forDuration: 0.1, thenDragTo: end)

        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: panel
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 2), .completed)
    }

    func testNautiUsesInlineHistoryOnIPad() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "Dieser Layout-Test ist ausschließlich für das iPad bestimmt."
        )

        let app = makeApp()
        app.launch()

        let launcher = app.buttons["Nauti Chat öffnen"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 12))
        launcher.tap()

        XCTAssertTrue(app.otherElements["NautiInlinePanel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Chat-Historie öffnen"].exists)
        XCTAssertFalse(app.textFields["Chats suchen"].exists)

        app.buttons["Chat-Historie öffnen"].tap()

        XCTAssertTrue(app.staticTexts["Verlauf"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["Chats suchen"].exists)
        XCTAssertTrue(app.buttons["Nauti Chat einklappen"].isHittable)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Nauti-iPad-Inline-History"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testNautiRendersInDarkMode() {
        let app = makeApp()
        app.launchArguments += ["-appearanceMode", "dark"]
        app.launch()

        let launcher = app.buttons["Nauti Chat öffnen"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 12))
        launcher.tap()

        let close = app.buttons["Nauti Chat einklappen"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(close.isHittable)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Skipper-KI")
        ).firstMatch.exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Nauti-Dark-Mode"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testCrewspaceUsesAvailableTabHeight() {
        let app = makeApp()
        app.launch()

        let crewspaceTab = app.tabBars.buttons["Crewspace"]
        XCTAssertTrue(crewspaceTab.waitForExistence(timeout: 10))
        crewspaceTab.tap()

        XCTAssertTrue(app.staticTexts["Crewspace"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Chats"].isHittable)
        XCTAssertTrue(app.buttons["Planung"].isHittable)
        XCTAssertTrue(app.buttons["Crew"].isHittable)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Crewspace-volle-Tabhoehe"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
