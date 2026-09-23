import AVFAudio
import XCTest
@testable import Toernberechnung

/// Guards the fix for the microphone crash: the audio tap must run at the
/// hardware sample rate and be resampled to the analyzer format here, because
/// `AVAudioEngine.installTap` aborts the process on a format mismatch.
final class SpeechAudioFormatConverterTests: XCTestCase {

    private func format(_ sampleRate: Double, channels: AVAudioChannelCount = 1) throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
    }

    private func toneBuffer(format: AVAudioFormat, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<Int(frames) {
            channel[0][frame] = sinf(Float(frame) * 0.05)
        }
        return buffer
    }

    func testIdenticalFormatsCopyBufferForAsynchronousConsumption() throws {
        let hardware = try format(48_000)
        let converter = try XCTUnwrap(SpeechAudioFormatConverter(from: hardware, to: hardware))

        XCTAssertTrue(converter.isPassthrough)

        let input = try toneBuffer(format: hardware, frames: 1_024)
        let output = try XCTUnwrap(converter.convert(input))
        XCTAssertFalse(output === input)
        XCTAssertEqual(output.frameLength, input.frameLength)
        let original = output.floatChannelData![0][10]
        input.floatChannelData![0][10] = 0
        XCTAssertEqual(output.floatChannelData![0][10], original)
    }

    func testDownsamplesHardwareBufferToAnalyzerFormat() throws {
        let hardware = try format(48_000)
        let analyzer = try format(16_000)
        let converter = try XCTUnwrap(SpeechAudioFormatConverter(from: hardware, to: analyzer))

        XCTAssertFalse(converter.isPassthrough)

        // Enough buffers that the resampler's one-off priming delay (~950
        // frames on this filter) stays a small fraction of the total.
        let bufferCount = 25
        let framesPerBuffer: AVAudioFrameCount = 4_800
        var producedFrames: AVAudioFrameCount = 0
        for _ in 0..<bufferCount {
            let input = try toneBuffer(format: hardware, frames: framesPerBuffer)
            guard let output = converter.convert(input) else { continue }
            XCTAssertEqual(output.format.sampleRate, 16_000)
            XCTAssertEqual(output.format.channelCount, 1)
            producedFrames += output.frameLength
        }

        // 25 x 4800 frames at 48 kHz is 2.5 s, i.e. 40000 frames at 16 kHz.
        // The output must be duration-preserving: never more than the input
        // covers, and within a few percent of it once priming is amortised.
        let theoretical = AVAudioFrameCount(bufferCount) * framesPerBuffer / 3
        XCTAssertLessThanOrEqual(producedFrames, theoretical)
        XCTAssertGreaterThan(
            producedFrames,
            theoretical * 95 / 100,
            "Expected ~\(theoretical) frames at 16 kHz, got \(producedFrames)"
        )
    }

    func testProducesNonSilentAudio() throws {
        let hardware = try format(48_000)
        let analyzer = try format(16_000)
        let converter = try XCTUnwrap(SpeechAudioFormatConverter(from: hardware, to: analyzer))

        var peak: Float = 0
        for _ in 0..<4 {
            let input = try toneBuffer(format: hardware, frames: 4_800)
            guard let output = converter.convert(input),
                  let channel = output.floatChannelData else { continue }
            for frame in 0..<Int(output.frameLength) {
                peak = max(peak, abs(channel[0][frame]))
            }
        }
        XCTAssertGreaterThan(peak, 0.5, "Resampled audio must carry the input tone, not silence")
    }

    func testEmptyBufferProducesNoOutput() throws {
        let hardware = try format(48_000)
        let analyzer = try format(16_000)
        let converter = try XCTUnwrap(SpeechAudioFormatConverter(from: hardware, to: analyzer))

        let empty = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: hardware, frameCapacity: 1_024))
        empty.frameLength = 0

        XCTAssertNil(converter.convert(empty))
    }

    func testStereoHardwareInputIsDownmixedToMono() throws {
        let hardware = try format(44_100, channels: 2)
        let analyzer = try format(16_000)
        let converter = try XCTUnwrap(SpeechAudioFormatConverter(from: hardware, to: analyzer))

        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: hardware, frameCapacity: 4_410))
        input.frameLength = 4_410
        let channels = try XCTUnwrap(input.floatChannelData)
        for frame in 0..<4_410 {
            channels[0][frame] = sinf(Float(frame) * 0.05)
            channels[1][frame] = sinf(Float(frame) * 0.05)
        }

        var produced: AVAudioFrameCount = 0
        for _ in 0..<4 {
            guard let output = converter.convert(input) else { continue }
            XCTAssertEqual(output.format.channelCount, 1)
            produced += output.frameLength
        }
        XCTAssertGreaterThan(produced, 0)
    }
}
