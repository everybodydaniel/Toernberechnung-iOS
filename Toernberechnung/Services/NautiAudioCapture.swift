import AVFAudio
import Foundation

/// Führt alle blockierenden Sitzungs- und AudioEngine-Aufrufe im eigenen
/// Ausführungskontext aus. So blockieren sie nicht den MainActor,
/// und Start und Stopp laufen nicht gegeneinander.
actor NautiAudioCapture {
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var sessionActive = false

    func prepare() throws -> AVAudioFormat {
        try Task.checkCancellation()
        guard engine == nil else { throw NautiSpeechInputError.audioSessionUnavailable }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            sessionActive = true
            let engine = AVAudioEngine()
            self.engine = engine
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
                throw NautiSpeechInputError.audioSessionUnavailable
            }
            return format
        } catch {
            NautiSpeechDiagnostics.record(backend: "Mikrofon", phase: "Audiositzung vorbereiten", error: error)
            stop()
            throw NautiSpeechFailure(reason: .audioSessionUnavailable, underlying: error)
        }
    }

    func start(
        outputFormat: AVAudioFormat? = nil,
        receive: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        try Task.checkCancellation()
        guard let engine, sessionActive, !tapInstalled else {
            throw NautiSpeechInputError.audioSessionUnavailable
        }
        // Nach der asynchronen Vorbereitung Format erneut lesen, da sich der
        // Audioeingang geändert haben kann. Ein nil-Aufnahmeformat lässt die Engine
        // das aktuelle Hardwareformat wählen und vermeidet einen nicht abfangbaren Abbruch.
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0,
              let converter = SpeechAudioFormatConverter(from: format, to: outputFormat ?? format) else {
            throw NautiSpeechInputError.audioSessionUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 4_096, format: nil,
                         block: Self.makeTap(converter: converter, receive: receive))
        tapInstalled = true
        do {
            engine.prepare()
            try engine.start()
        } catch {
            NautiSpeechDiagnostics.record(backend: "Mikrofon", phase: "AudioEngine starten", error: error)
            stop()
            throw NautiSpeechFailure(reason: .audioSessionUnavailable, underlying: error)
        }
    }

    // Ausdrücklich nonisolated: Audio-Rückrufe dürfen den Ausführungskontext eines Actors nicht übernehmen.
    nonisolated private static func makeTap(
        converter: SpeechAudioFormatConverter,
        receive: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, time in
            guard let ownedBuffer = converter.convert(buffer) else { return }
            receive(ownedBuffer, time)
        }
    }

    func stop() {
        if let engine {
            if engine.isRunning { engine.stop() }
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        }
        tapInstalled = false
        engine = nil
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
    }
}
