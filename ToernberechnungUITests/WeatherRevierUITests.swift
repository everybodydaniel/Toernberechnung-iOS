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
        XCTAssertTrue(app.staticTexts["Crew und Termine im Blick behalten."].waitForExistence(timeout: 3))
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
        XCTAssertTrue(app.staticTexts["Crew und Termine im Blick behalten."].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Loslegen"].isEnabled)
        app.buttons["onboardingSafetyAcknowledgement"].tap()
        XCTAssertTrue(app.buttons["Loslegen"].isEnabled)
        app.buttons["Loslegen"].tap()
        XCTAssertTrue(app.tabBars.buttons["Karte"].waitForExistence(timeout: 5))
    }

    func testRevierWeatherScreenOpensAndRenders() {
        let app = makeApp()
        app.launch()

        let revierTab = app.tabBars.buttons["Wetter"]
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

        let revierTab = app.tabBars.buttons["Wetter"]
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
        XCTAssertTrue(app.buttons["CrewspaceSectionCrew"].isHittable)
        XCTAssertTrue(app.buttons["CrewspaceSectionPlanung"].isHittable)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Crewspace-volle-Tabhoehe"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testCrewCalendarSharingShowsInvitationAndCalendarAttachment() {
        let app = makeApp()
        app.launch()
        let crewspaceTab = app.tabBars.buttons["Crewspace"]
        XCTAssertTrue(crewspaceTab.waitForExistence(timeout: 10))
        crewspaceTab.tap()
        app.buttons["CrewspaceSectionPlanung"].tap()
        let addEvent = app.buttons["Termin"]
        for _ in 0..<4 where !addEvent.isHittable { app.swipeUp() }
        XCTAssertTrue(addEvent.isHittable)
        addEvent.tap()

        let titleField = app.textFields["z. B. Ablegen Norderney"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        app.buttons["Törnstart"].tap()
        titleField.tap()
        titleField.typeText(" Norderney")
        let editorScroll = app.scrollViews["CrewEventEditorScroll"]
        editorScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            .press(forDuration: 0.1, thenDragTo: editorScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        let saveEvent = app.buttons["Termin hinzufügen"]
        for _ in 0..<6 where !saveEvent.isHittable { editorScroll.swipeUp() }
        XCTAssertTrue(saveEvent.isHittable)
        saveEvent.tap()
        XCTAssertTrue(app.navigationBars["Neuer Termin"].waitForNonExistence(timeout: 5))

        let share = app.buttons["Termin teilen"].firstMatch
        for _ in 0..<4 where !share.isHittable { app.swipeUp() }
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        share.tap()
        XCTAssertTrue(app.buttons["Kalendereintrag teilen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["CREWSPACE · TERMIN"].exists)
        let invitation = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        invitation.name = "Crew-Kalendereinladung"
        invitation.lifetime = .keepAlways
        add(invitation)

        app.buttons["Zum Kalender hinzufügen"].tap()
        let nativeTitle = app.textFields.matching(NSPredicate(format: "value == %@", "Törnstart Norderney")).firstMatch
        XCTAssertTrue(nativeTitle.waitForExistence(timeout: 10))
        let calendarEditor = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        calendarEditor.name = "Crew-Apple-Kalenderdialog"
        calendarEditor.lifetime = .keepAlways
        add(calendarEditor)
        let cancel = app.buttons.matching(NSPredicate(format: "label == 'Abbrechen' OR label == 'Cancel'")).firstMatch
        XCTAssertTrue(cancel.exists)
        cancel.tap()
        XCTAssertTrue(app.buttons["Zum Kalender hinzufügen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Zum Kalender hinzufügen"].isEnabled)

        app.buttons["Kalendereintrag teilen"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Crew-iCalendar-Teilen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testGenerateReadmeScreenshots() throws {
        let app = makeApp()
        app.launch()

        let fileManager = FileManager.default
        let targetDir = "/tmp/tagnode_screenshots"
        try? fileManager.createDirectory(atPath: targetDir, withIntermediateDirectories: true)

        func saveScreenshot(name: String) {
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)

            let data = screenshot.pngRepresentation
            let path = "\(targetDir)/\(name).png"
            try? data.write(to: URL(fileURLWithPath: path))
        }

        // 1. Map Tab with calculated route
        let planPill = app.buttons["MapPlanningPill"]
        if planPill.waitForExistence(timeout: 8) {
            planPill.tap()

            let startPicker = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "START")).firstMatch
            if startPicker.waitForExistence(timeout: 3) {
                startPicker.tap()
                let borkumOption = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Borkum")).firstMatch
                if borkumOption.waitForExistence(timeout: 3) {
                    borkumOption.tap()
                }
            }

            let destPicker = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "ZIEL")).firstMatch
            if destPicker.waitForExistence(timeout: 3) {
                destPicker.tap()
                let norderneyOption = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Norderney")).firstMatch
                if norderneyOption.waitForExistence(timeout: 3) {
                    norderneyOption.tap()
                }
            }

            let calcBtn = app.buttons["CalculateVoyageButton"]
            if calcBtn.waitForExistence(timeout: 3) && calcBtn.isEnabled {
                calcBtn.tap()
            } else {
                let closeBtn = app.buttons["Törnplanung schließen"]
                if closeBtn.exists { closeBtn.tap() }
            }
        }

        Thread.sleep(forTimeInterval: 2.5)
        saveScreenshot(name: "01_map_tab")

        // 2. Weather Tab
        let weatherTab = app.tabBars.buttons["Wetter"]
        if weatherTab.waitForExistence(timeout: 5) {
            weatherTab.tap()
            Thread.sleep(forTimeInterval: 2.0)
            saveScreenshot(name: "02_weather_tab")

            // 3. Tides Sub-section
            let tidesButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Gezeiten")).firstMatch
            if tidesButton.waitForExistence(timeout: 5) {
                tidesButton.tap()
                Thread.sleep(forTimeInterval: 2.0)
                saveScreenshot(name: "03_tides_tab")
            }
        }

        // 4. Crew Tab
        let crewTab = app.tabBars.buttons["Crewspace"]
        if crewTab.waitForExistence(timeout: 5) {
            crewTab.tap()
            Thread.sleep(forTimeInterval: 2.0)
            saveScreenshot(name: "04_crew_tab")
        }

        // 5. Logbook Tab
        let logbookTab = app.tabBars.buttons["Logbuch"]
        if logbookTab.waitForExistence(timeout: 5) {
            logbookTab.tap()
            Thread.sleep(forTimeInterval: 2.0)
            saveScreenshot(name: "05_logbook_tab")
        }
    }

    func testMaritimeWarningsFlow() {
        let app = makeApp()
        app.launch()

        let fileManager = FileManager.default
        let targetDir = "/tmp/tagnode_screenshots"
        try? fileManager.createDirectory(atPath: targetDir, withIntermediateDirectories: true)

        func saveShot(name: String) {
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)

            let data = screenshot.pngRepresentation
            let path = "\(targetDir)/\(name).png"
            try? data.write(to: URL(fileURLWithPath: path))
        }

        let bell = app.buttons["AppHeaderWarningsButton"]
        XCTAssertTrue(bell.waitForExistence(timeout: 8))
        saveShot(name: "warnings_header_button")

        bell.tap()
        Thread.sleep(forTimeInterval: 2.0)
        saveShot(name: "warnings_sheet_open")

        let allReadButton = app.buttons["Gelesen"]
        if allReadButton.waitForExistence(timeout: 3) {
            allReadButton.tap()
            Thread.sleep(forTimeInterval: 1.0)
            saveShot(name: "warnings_sheet_after_read")
        }

        let doneButton = app.buttons["Fertig"]
        if doneButton.waitForExistence(timeout: 3) {
            doneButton.tap()
            Thread.sleep(forTimeInterval: 1.5)
            saveShot(name: "warnings_header_after_read")
        }
    }
}
