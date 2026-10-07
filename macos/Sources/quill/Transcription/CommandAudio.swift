@preconcurrency import AVFoundation
import Foundation

/// Streams a track through one converter into bounded 16 kHz mono PCM WAVs.
/// Chunk times derive from actual output frames, including the final short chunk.
enum CommandAudio {
    struct Chunk {
        let url: URL
        let start: TimeInterval
        let duration: TimeInterval
    }

    private final class Input: @unchecked Sendable {
        let file: AVAudioFile
        let buffer: AVAudioPCMBuffer
        var error: Error?

        init(file: AVAudioFile, buffer: AVAudioPCMBuffer) {
            self.file = file
            self.buffer = buffer
        }
    }

    static func chunks(from audio: URL, in directory: URL, maxDuration: TimeInterval) throws -> [Chunk] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: audio)
        } catch {
            throw UnreadableTranscriptionInput.classify(error, audio: audio)
        }
        return try convert(file, source: audio, in: directory, maxDuration: maxDuration)
    }

    private static func convert(_ file: AVAudioFile, source audio: URL, in directory: URL, maxDuration: TimeInterval) throws -> [Chunk] {
        guard file.length > 0 else { throw UnreadableTranscriptionInput(description: "empty audio") }
        guard maxDuration.isFinite, (1...300).contains(maxDuration) else {
            throw TranscriptionCommandError("invalid command chunk duration")
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
            let converter = AVAudioConverter(from: file.processingFormat, to: format)
        else { throw UnreadableTranscriptionInput(description: "unsupported audio format in \(audio.lastPathComponent)") }
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
            throw TranscriptionCommandError("can't allocate audio conversion buffer")
        }
        converter.downmix = true

        let input = Input(file: file, buffer: inputBuffer)
        let chunkFrames = AVAudioFramePosition(maxDuration * format.sampleRate)
        var chunks: [Chunk] = []
        var totalFrames: AVAudioFramePosition = 0
        var frames: AVAudioFramePosition = 0
        var output: AVAudioFile?
        var outputURL: URL?

        func finishChunk() {
            output = nil  // Finalize the WAV header before the provider opens it.
            if let outputURL, frames > 0 {
                chunks.append(
                    Chunk(
                        url: outputURL,
                        start: Double(totalFrames - frames) / format.sampleRate,
                        duration: Double(frames) / format.sampleRate
                    ))
            }
            outputURL = nil
            frames = 0
        }

        while true {
            let capacity = AVAudioFrameCount(min(4096, chunkFrames - frames))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw TranscriptionCommandError("can't allocate audio conversion buffer")
            }
            var conversionError: NSError?
            let status = converter.convert(to: buffer, error: &conversionError) { requested, status in
                guard input.file.framePosition < input.file.length else {
                    status.pointee = .endOfStream
                    return nil
                }
                do {
                    try input.file.read(into: input.buffer, frameCount: min(requested, input.buffer.frameCapacity))
                    status.pointee = input.buffer.frameLength == 0 ? .endOfStream : .haveData
                    return input.buffer.frameLength == 0 ? nil : input.buffer
                } catch {
                    input.error = UnreadableTranscriptionInput.classify(error, audio: audio)
                    status.pointee = .endOfStream
                    return nil
                }
            }
            if let error = input.error {
                throw error
            }
            if let conversionError {
                throw UnreadableTranscriptionInput.classify(conversionError, audio: audio)
            }
            guard status != .error else { throw TranscriptionCommandError("audio converter failed") }
            if buffer.frameLength > 0 {
                if output == nil {
                    let url = directory.appendingPathComponent("chunk-\(chunks.count).wav")
                    outputURL = url
                    output = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
                }
                try output?.write(from: buffer)
                frames += AVAudioFramePosition(buffer.frameLength)
                totalFrames += AVAudioFramePosition(buffer.frameLength)
                if frames == chunkFrames { finishChunk() }
            }
            if status == .endOfStream { break }
            guard buffer.frameLength > 0 else { throw TranscriptionCommandError("audio converter made no progress") }
        }
        finishChunk()
        guard !chunks.isEmpty else { throw UnreadableTranscriptionInput(description: "audio has no decodable frames") }
        return chunks
    }
}
