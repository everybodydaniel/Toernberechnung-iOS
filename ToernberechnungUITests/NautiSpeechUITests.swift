import XCTest

final class NautiSpeechUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func openChat(mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-hasSeenOnboarding", "YES"]
        if !mode.isEmpty { app.launchEnvironment["UITEST_NAUTI_SPEECH"] = mode }
        app.launch()
        let launcher = app.buttons["Nauti KI öffnen"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 12))
        launcher.tap()
        XCTAssertTrue(app.buttons["NautiSpeechButton"].waitForExistence(timeout: 5))
        app.buttons["Neuer Chat"].tap()
        return app
    }

    func testSpeechPreservesDraftAndRequiresManualSend() {
        let app = openChat(mode: "transcript")
        let draft = app.textViews["NautiMessageDraft"]
        let field = draft.exists ? draft : app.textFields["NautiMessageDraft"]
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.tap()
        field.typeText("Bitte:")
        app.buttons["NautiSpeechButton"].tap()
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Bitte: Plane einen Törn"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["NautiSendButton"].isEnabled)
        app.buttons["NautiSpeechButton"].tap()
        let finalText = "Bitte: Plane einen Törn nach Juist"
        let final = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@ AND enabled == true", finalText), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [final], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["NautiSendButton"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Nauti Spracheingabe vor dem Senden"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertFalse(app.staticTexts[finalText].exists)
        app.buttons["NautiSendButton"].tap()
        XCTAssertTrue(app.staticTexts[finalText].waitForExistence(timeout: 5))
    }

    func testDownloadErrorLeavesTextEntryAvailable() {
        let app = openChat(mode: "download-error")
        app.buttons["NautiSpeechButton"].tap()
        let error = app.staticTexts["NautiSpeechError"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("Internet"))
        XCTAssertTrue(app.buttons["NautiSpeechButton"].isEnabled)
        let draft = app.textViews["NautiMessageDraft"]
        let field = draft.exists ? draft : app.textFields["NautiMessageDraft"]
        XCTAssertTrue(field.isEnabled)
    }

    func testClosingChatStopsRecordingAndKeepsDraft() {
        let app = openChat(mode: "transcript")
        app.buttons["NautiSpeechButton"].tap()
        let status = app.descendants(matching: .any).matching(identifier: "NautiSpeechStatus").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        app.buttons["NautiInlineDragHandle"].tap()
        app.buttons["Nauti KI öffnen"].tap()
        XCTAssertTrue(app.buttons["Spracheingabe starten"].waitForExistence(timeout: 5))
        XCTAssertFalse(status.exists)
        let draft = app.textViews["NautiMessageDraft"]
        let field = draft.exists ? draft : app.textFields["NautiMessageDraft"]
        XCTAssertEqual(field.value as? String, "Plane einen Törn")
    }

    // Der Gerätetest benötigt eine echte Testphrase und wird nur ausdrücklich gestartet.
    func testLocalSpeechOnConnectedDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Eine echte Aufnahme benötigt ein iPhone.")
        #else
        guard ProcessInfo.processInfo.environment["RUN_NAUTI_SPEECH_HARDWARE"] == "1" else {
            throw XCTSkip("Der gemeinsame Mikrofontest wurde nicht angefordert.")
        }
        let app = openChat(mode: "")
        app.buttons["NautiSpeechButton"].tap()
        let recording = app.descendants(matching: .any).matching(identifier: "NautiSpeechStatus").firstMatch
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", "Sprachaufnahme läuft"),
            object: recording
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 150), .completed,
                       "Das lokale Sprachmodell konnte nicht vorbereitet werden.")
        let draft = app.textViews["NautiMessageDraft"]
        let field = draft.exists ? draft : app.textFields["NautiMessageDraft"]
        let recognized = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS[c] %@", "Juist"), object: field
        )
        XCTAssertEqual(XCTWaiter.wait(for: [recognized], timeout: 60), .completed,
                       "Die Testphrase wurde nicht lokal erkannt.")
        XCTAssertFalse(app.buttons["NautiSendButton"].isEnabled)
        app.buttons["NautiSpeechButton"].tap()
        let finished = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true AND value CONTAINS[c] %@", "Juist"), object: field
        )
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 8), .completed)
        XCTAssertFalse(app.staticTexts["NautiSpeechError"].exists)
        XCTAssertTrue((field.value as? String)?.contains("Törn") == true,
                      "Der nautische Begriff muss im Entwurf erhalten bleiben.")
        XCTAssertTrue(app.buttons["NautiSendButton"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Lokale Spracheingabe auf dem iPhone"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        #endif
    }
}
