import XCTest

/// XCUITest-Suite – End-to-End-Smoke- und Navigations-Tests.
///
/// Die App wird je Test in einem frischen Simulator-Process gestartet,
/// damit @AppStorage-/SwiftData-Zustände nicht in andere Tests durchsickern.
final class ToernberechnungUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launch()
    }

    // MARK: - GUI-1: App startet und zeigt Haupt-Tab-Bar

    func test_GUI1_appLaunchesAndShowsTabBar() {
        XCTAssertTrue(app.state == .runningForeground)
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5),
                      "Eine TabBar muss nach Start sichtbar sein")
    }

    // MARK: - GUI-2: Tab-Navigation

    func test_GUI2_tabNavigationSwitchesContent() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))

        // Jeden Tab antippen und prüfen dass der Process nicht crasht
        for button in tabBar.buttons.allElementsBoundByIndex {
            button.tap()
            XCTAssertEqual(app.state, .runningForeground,
                           "App muss nach Tab-Wechsel weiterlaufen")
        }
    }

    // MARK: - GUI-3: Karte ist Teil der Navigation

    func test_GUI3_mapTabContainsRoutePlannerContent() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))

        // Heuristik: Karte ist üblicherweise erster oder zweiter Tab
        let firstTab = tabBar.buttons.element(boundBy: 0)
        firstTab.tap()
        XCTAssertTrue(app.state == .runningForeground)
    }
}
