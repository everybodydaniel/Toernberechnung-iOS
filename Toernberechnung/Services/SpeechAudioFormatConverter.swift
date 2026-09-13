import AVFAudio
import Foundation

/// Converts microphone buffers into the format a speech recogniser asks for.
///
/// `AVAudioInputNode.installTap(onBus:bufferSize:format:)` only accepts the
/// bus's own hardware format — passing anything else raises an Objective-C
/// exception (`format.sampleRate == hwFormat.sampleRate`) that Swift cannot
/// catch, which crashes the process. So the tap runs at the hardware rate
/// (typically 48 kHz) and every buffer is resampled here to whatever the
/// analyzer wants (typically 16 kHz mono) before it is handed on.
///
/// `@unchecked Sendable`: an instance is built on the main actor and then used
/// exclusively from the single audio-tap thread. `AVAudioConverter` is not
/// thread-safe, but it is never touched concurrently.
final class SpeechAudioFormatConverter: @unchecked Sendable {
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat

    private let converter: AVAudioConverter?

    /// Returns `nil` when the two formats cannot be bridged at all — the
    /// caller should then surface a recoverable error instead of recording.
    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              outputFormat.sampleRate > 0, outputFormat.channelCount > 0 else {
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



    /// Resamples one capture buffer. Returns `nil` if the conversion fails or
    /// produced no frames; callers should simply drop that buffer.
    ///
    /// Must be called from a single thread — in practice the audio tap's
    /// realtime callback, which is already serialised.
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        guard let converter else { return buffer }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let scaled = (Double(buffer.frameLength) * ratio).rounded(.up)
        // A little headroom: resamplers may emit slightly more frames than the
        // plain ratio suggests while their filter delay line drains.
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
