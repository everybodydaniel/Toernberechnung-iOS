import XCTest
@testable import Toernberechnung

final class NautiSpeechResourceTests: XCTestCase {
    @MainActor
    func testInstalledModelDoesNotRequireDownload() async throws {
        let assets = TestSpeechAssets(statuses: [.installed])
        try await NautiSpeechAssetPreparation.prepare(using: assets, backend: "Test") { _ in }
        XCTAssertEqual(assets.installCount, 0)
    }

    @MainActor
    func testDownloadMustFinishBeforePreparationSucceeds() async throws {
        for initial in [NautiSpeechAssetStatus.supported, .downloading] {
            let assets = TestSpeechAssets(statuses: [initial, .installed])
            var steps: [NautiSpeechPreparation] = []
            try await NautiSpeechAssetPreparation.prepare(using: assets, backend: "Test") { steps.append($0) }
            XCTAssertEqual(assets.installCount, 1)
            XCTAssertTrue(steps.contains(.downloading(0.5)))
        }
    }

    @MainActor
    func testUnsupportedModelDoesNotStartDownload() async {
        let assets = TestSpeechAssets(statuses: [.unsupported])
        do {
            try await NautiSpeechAssetPreparation.prepare(using: assets, backend: "Test") { _ in }
            XCTFail("Nicht unterstützte Ressourcen dürfen nicht gestartet werden.")
        } catch {
            XCTAssertEqual(error as? NautiSpeechInputError, .onDeviceRecognitionUnavailable)
        }
        XCTAssertEqual(assets.installCount, 0)
    }

    @MainActor
    func testFailedInstallationPreservesUnderlyingError() async {
        let assets = TestSpeechAssets(statuses: [.supported], error: NSError(domain: "OfflineTest", code: -1009))
        do {
            try await NautiSpeechAssetPreparation.prepare(using: assets, backend: "Test") { _ in }
            XCTFail("Der Download muss fehlschlagen.")
        } catch {
            XCTAssertEqual(NautiSpeechInputError.reason(for: error), .downloadFailed)
            XCTAssertEqual(((error as? NautiSpeechFailure)?.underlying as? NSError)?.code, -1009)
        }
    }

    @MainActor
    func testReservationFailureIsNotMisreportedAsOfflineDownload() async {
        let cause = NSError(domain: "SpeechReservationTest", code: 9)
        let assets = TestSpeechAssets(statuses: [.supported],
                                     error: NautiSpeechFailure(reason: .modelPreparationFailed, underlying: cause))
        do {
            try await NautiSpeechAssetPreparation.prepare(using: assets, backend: "Test") { _ in }
            XCTFail("Der Ressourcenfehler muss weitergegeben werden.")
        } catch {
            XCTAssertEqual(NautiSpeechInputError.reason(for: error), .modelPreparationFailed)
            XCTAssertEqual(((error as? NautiSpeechFailure)?.underlying as? NSError)?.domain, "SpeechReservationTest")
        }
    }

    @MainActor
    func testUninstalledAssetsCannotBeUsedAfterRequestReturns() async {
        let assets = TestSpeechAssets(statuses: [.supported, .supported])
        do {
            try await NautiSpeechAssetPreparation.prepare(using: assets, backend: "Test") { _ in }
            XCTFail("Ein beendeter Download allein reicht nicht aus.")
        } catch { XCTAssertEqual(error as? NautiSpeechInputError, .assetsUnavailable) }
    }

    @MainActor
    func testCancellationIsNotReportedAsDownloadFailure() async {
        let assets = TestSpeechAssets(statuses: [.supported], error: CancellationError())
        do {
            try await NautiSpeechAssetPreparation.prepare(using: assets, backend: "Test") { _ in }
            XCTFail("Der Abbruch muss weitergegeben werden.")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCorrectedSegmentsAndMultipleSentencesKeepAllFinalWords() {
        var transcript = NautiSpeechTranscriptAccumulator()
        XCTAssertEqual(transcript.update(start: 0, end: 2, text: "Plane einen Turn", isFinal: false), "Plane einen Turn")
        XCTAssertEqual(transcript.update(start: 0, end: 2, text: "Plane einen Törn.", isFinal: true), "Plane einen Törn.")
        XCTAssertEqual(transcript.update(start: 2, end: 4, text: "Nach Just", isFinal: false), "Plane einen Törn. Nach Just")
        XCTAssertEqual(transcript.update(start: 2, end: 4, text: "Nach Juist.", isFinal: true), "Plane einen Törn. Nach Juist.")
        XCTAssertEqual(transcript.update(start: 2, end: 4, text: "Nach Juist.", isFinal: true), "Plane einen Törn. Nach Juist.")
    }

    func testReplacingOverlappingVolatileRangesDoesNotDuplicateText() {
        var transcript = NautiSpeechTranscriptAccumulator()
        _ = transcript.update(start: 0, end: 2, text: "Plane", isFinal: false)
        XCTAssertEqual(transcript.update(start: 0, end: 3, text: "Plane einen Törn", isFinal: true), "Plane einen Törn")
        XCTAssertEqual(transcript.update(start: .nan, end: 3, text: "Falscher Abschnitt", isFinal: true), "Plane einen Törn")
    }

    func testDraftRetainsExistingWhitespaceAndPunctuation() {
        XCTAssertEqual(NautiSpeechDraft.appending("nach Juist", to: "Plane "), "Plane nach Juist")
        XCTAssertEqual(NautiSpeechDraft.appending(".", to: "Juist"), "Juist.")
        XCTAssertEqual(NautiSpeechDraft.appending("", to: "Meine Eingabe"), "Meine Eingabe")
    }

    func testNauticalSpeechCorrectionKeepsCompoundWordsIntact() {
        XCTAssertEqual(NautiSpeechVocabulary.correctedTranscript("Ein Turn, danach ein turn."), "Ein Törn, danach ein Törn.")
        let otherWords = "Turnhalle, Turnier und turnen bleiben unverändert."
        XCTAssertEqual(NautiSpeechVocabulary.correctedTranscript(otherWords), otherWords)
        XCTAssertEqual(NautiSpeechVocabulary.correctedTranscript("Ein Törn nach Juist"), "Ein Törn nach Juist")
    }
}

@MainActor
private final class TestSpeechAssets: NautiSpeechAssetClient {
    var statuses: [NautiSpeechAssetStatus]
    let error: Error?
    var installCount = 0
    init(statuses: [NautiSpeechAssetStatus], error: Error? = nil) { self.statuses = statuses; self.error = error }
    func status() async -> NautiSpeechAssetStatus {
        statuses.count > 1 ? statuses.removeFirst() : statuses[0]
    }
    func install(onProgress: @escaping @MainActor (Double?) -> Void) async throws {
        installCount += 1
        if let error { throw error }
        onProgress(0.5)
    }
}
