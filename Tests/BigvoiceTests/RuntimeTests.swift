import BigvoiceCore
import BigvoiceRuntime
import AVFoundation
import CryptoKit
import Foundation

let runtimeTests: [RegressionTest] = [
    RegressionTest(name: "Audio conversion handles end-of-file and resamples stereo to mono") {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("stereo.wav")
            try writeAudioFixture(url, sampleRate: 44_100, channels: 2)
            let samples = try AudioFileReader.read(url)
            try expect(abs(samples.count - 32_000) <= 32, "Two seconds of audio must produce approximately 32,000 mono samples.")
            try expect(AudioAnalysis.rms(samples) > 0.03)
        }
    },
    RegressionTest(name: "Installer accepts exact checksum and rejects truncated or tampered files") {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("fixture")
            let data = Data("This is a checksum verification fixture.".utf8)
            try data.write(to: url)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try ModelInstaller.verify(url, expectedBytes: Int64(data.count), sha256: digest)
            try expectThrows { try ModelInstaller.verify(url, expectedBytes: 900, sha256: digest) }
            try expectThrows {
                try ModelInstaller.verify(url, expectedBytes: Int64(data.count), sha256: String(repeating: "0", count: 64))
            }
        }
    },
    RegressionTest(name: "Silent audio is rejected before loading any model") {
        let engine = NativeTranscriber(useGPU: false)
        let model = LocalModel(id: "missing", url: URL(fileURLWithPath: "/nonexistent/whisper.bin"),
                               bytes: 32_166_155, family: .tiny, multilingual: false, source: "Test", isManaged: false)
        do {
            _ = try await engine.transcribe(samples: Array(repeating: 0, count: 32_000), model: model)
            throw TestFailure(message: "Silence must not transcribe")
        } catch TranscriptionError.noSpeech {
        }
    },
    RegressionTest(name: "English-only models reject other languages before any weights load") {
        let whisperEnglish = LocalModel(id: "a", url: URL(fileURLWithPath: "/nonexistent/a.bin"), bytes: 1,
                                        family: .tiny, multilingual: false, source: "Test", isManaged: false)
        let whisperMulti = LocalModel(id: "b", url: URL(fileURLWithPath: "/nonexistent/b.bin"), bytes: 1,
                                      family: .base, multilingual: true, source: "Test", isManaged: false)
        try expectThrows { try NativeTranscriber.validate(language: "fr", for: whisperEnglish) }
        try NativeTranscriber.validate(language: "auto", for: whisperEnglish)
        try NativeTranscriber.validate(language: "fr", for: whisperMulti)
        try withTemporaryDirectory { directory in
            let folder = directory.appendingPathComponent("nemotron")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let config = #"{"model":{"type":"nemotron_speech","sample_rate":16000,"chunk_samples":8960,"encoder":{"filename":"e.onnx"},"decoder":{"filename":"d.onnx"},"joiner":{"filename":"j.onnx"}}}"#
            try Data(config.utf8).write(to: folder.appendingPathComponent("genai_config.json"))
            for name in ["e.onnx", "d.onnx", "j.onnx", "tokenizer.json"] { try Data([1]).write(to: folder.appendingPathComponent(name)) }
            let onnx = try ONNXBundleInspector.inspect(folder, source: "Test")
            try expectThrows { try NativeTranscriber.validate(language: "de", for: onnx) }
            try NativeTranscriber.validate(language: "en", for: onnx)
        }
    },
    RegressionTest(name: "Live Nemotron streaming produces the same words as the offline pass") {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["BIGVOICE_TEST_ONNX_MODEL"], let audioPath = environment["BIGVOICE_TEST_AUDIO"] else {
            throw TestSkip(reason: "Set BIGVOICE_TEST_ONNX_MODEL and BIGVOICE_TEST_AUDIO for the live streaming test.")
        }
        let model = try ModelFileInspector.inspect(URL(fileURLWithPath: modelPath), source: "Test", managedDirectory: ModelDiscovery.managedDirectory)
        let samples = try AudioFileReader.read(URL(fileURLWithPath: audioPath))
        let engine = NativeTranscriber()
        try await engine.beginStream(model: model)
        // Feed 240 ms slices exactly as the app does while recording, holding back a tail for the stop.
        let slice = AudioAnalysis.sampleRate * 24 / 100
        let tailStart = max(0, samples.count - slice / 2)
        var offset = 0
        var partials: [String] = []
        while offset < tailStart {
            let end = min(tailStart, offset + slice)
            partials.append(try await engine.feedStream(Array(samples[offset..<end])))
            offset = end
        }
        let streamed = try await engine.finishStream(Array(samples[offset...]))
        let growing = partials.filter { !$0.isEmpty }
        try expect(growing.count >= 3, "Words must arrive while audio is still being fed (got \(growing.count) partial updates).")
        try expect(zip(growing, growing.dropFirst()).allSatisfy { $1.count >= $0.count }, "Partial transcripts must only grow.")
        let offline = try await engine.transcribe(samples: samples, model: model)
        print("  streamed: \(streamed)")
        let normalize = { (text: String) in text.lowercased().filter { $0.isLetter || $0 == " " } }
        try expect(normalize(streamed) == normalize(offline), "Streaming and offline transcripts must match.")
        if let phrase = environment["BIGVOICE_TEST_PHRASE"] {
            try expect(streamed.lowercased().contains(phrase.lowercased()))
        }
        // A cancelled stream must release cleanly and never block the next session.
        try await engine.beginStream(model: model)
        _ = try await engine.feedStream(Array(samples.prefix(slice)))
        await engine.cancelStream()
        await engine.shutdown()
    },
    RegressionTest(name: "Real offline native transcription with supplied model and audio") {
        let environment = ProcessInfo.processInfo.environment
        let paths = ["BIGVOICE_TEST_MODEL", "BIGVOICE_TEST_ONNX_MODEL"].compactMap { environment[$0] }
        guard !paths.isEmpty, let audioPath = environment["BIGVOICE_TEST_AUDIO"] else {
            throw TestSkip(reason: "Set BIGVOICE_TEST_MODEL and/or BIGVOICE_TEST_ONNX_MODEL with BIGVOICE_TEST_AUDIO.")
        }
        let samples = try AudioFileReader.read(URL(fileURLWithPath: audioPath))
        let engine = NativeTranscriber()
        // Whisper → ONNX → Whisper exercises engine switching, unload, and ONNX runtime re-initialization.
        let sequence = paths.count > 1 ? paths + [paths[0]] : paths
        for path in sequence {
            let model = try ModelFileInspector.inspect(
                URL(fileURLWithPath: path), source: "Test", managedDirectory: ModelDiscovery.managedDirectory
            )
            let started = Date()
            let text = try await engine.transcribe(samples: samples, model: model)
            print("  \(model.name) [\(model.formatLabel)] \(String(format: "%.2f", Date().timeIntervalSince(started)))s: \(text)")
            try expect(!text.isEmpty)
            if let phrase = environment["BIGVOICE_TEST_PHRASE"] {
                try expect(text.lowercased().contains(phrase.lowercased()), "\(model.name) transcript missed the expected phrase")
            }
        }
        await engine.shutdown()
    }
]

private func writeAudioFixture(_ url: URL, sampleRate: Double, channels: AVAudioChannelCount) throws {
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate * 2)) else {
        throw TestFailure(message: "Could not create PCM fixture")
    }
    buffer.frameLength = buffer.frameCapacity
    guard let data = buffer.floatChannelData else { throw TestFailure(message: "No channel data") }
    for channel in 0..<Int(channels) {
        for frame in 0..<Int(buffer.frameLength) {
            data[channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / sampleRate) * 0.2)
        }
    }
    var settings = format.settings
    settings[AVLinearPCMIsNonInterleaved] = false
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
}
