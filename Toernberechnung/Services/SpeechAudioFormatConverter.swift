import AVFAudio
import Foundation

/// Wandelt Mikrofonpuffer in das benötigte Format der Spracherkennung um.
///
/// `AVAudioInputNode.installTap(onBus:bufferSize:format:)` akzeptiert nur das
/// Hardwareformat des Eingangs. Ein anderes Format kann eine Objective-C-Ausnahme
/// auslösen, die Swift nicht abfangen kann. Die Aufnahme verwendet deshalb die
/// Hardware-Abtastrate, meist 48 kHz. Hier wird jeder Puffer vor der Weitergabe
/// in das Analyseformat umgerechnet, meist 16 kHz mono.
///
/// `@unchecked Sendable`: Die Instanz entsteht auf dem MainActor und wird danach
/// nur vom einzelnen Aufnahme-Thread verwendet. `AVAudioConverter` wird nicht
/// gleichzeitig aus mehreren Threads aufgerufen.
final class SpeechAudioFormatConverter: @unchecked Sendable {
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat

    private let converter: AVAudioConverter?

    /// Gibt `nil` zurück, wenn die Formate nicht umgewandelt werden können.
    /// Der Aufrufer soll dann einen behandelbaren Fehler anzeigen statt aufzuzeichnen.
    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              outputFormat.sampleRate.isFinite, outputFormat.sampleRate > 0, outputFormat.channelCount > 0 else {
            return nil
        }

        self.inputFormat = inputFormat
        self.outputFormat = outputFormat

        if inputFormat == outputFormat {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                return nil
            }
            self.converter = converter
        }
    }

    var isPassthrough: Bool {
        converter == nil
    }

    /// Rechnet einen Aufnahmepuffer auf die gewünschte Abtastrate um. Gibt `nil`
    /// bei Fehlern oder fehlenden Ausgabeframes zurück; der Aufrufer verwirft den Puffer.
    ///
    /// Nur von einem einzelnen Thread aufrufen, üblicherweise vom bereits
    /// seriellen Echtzeit-Rückruf der Audioaufnahme.
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0, buffer.format == inputFormat else { return nil }
        guard let converter else {
            // Die Engine verwendet den Aufnahmespeicher nach dem Rückruf erneut.
            // Asynchrone Empfänger benötigen daher auch ohne Umrechnung einen eigenen Puffer.
            guard let copy = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: buffer.frameLength) else { return nil }
            copy.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
            let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for index in source.indices {
                guard let from = source[index].mData, let to = destination[index].mData else { return nil }
                memcpy(to, from, Int(source[index].mDataByteSize))
            }
            return copy
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let scaled = (Double(buffer.frameLength) * ratio).rounded(.up)
        guard scaled.isFinite, scaled < Double(UInt32.max - 1_024) else { return nil }
        // Zusätzlichen Platz vorsehen, da beim Leeren des Konverterfilters
        // etwas mehr Frames als nach dem reinen Abtastratenverhältnis entstehen können.
        let capacity = AVAudioFrameCount(max(scaled, 1)) + 1_024

        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, conversionError == nil, output.frameLength > 0 else {
            return nil
        }
        return output
    }
}
