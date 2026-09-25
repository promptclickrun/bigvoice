import CryptoKit
import Darwin
import Foundation

public struct ONNXSpeechConfiguration: Equatable, Sendable {
    public let sampleRate: Int
    public let chunkSamples: Int
    public let revision: String
}

public enum ONNXModelError: LocalizedError, Equatable {
    case missingConfiguration
    case unsupportedArchitecture(String)
    case invalidConfiguration(String)
    case missingComponent(String)
    case unsafeReference(String)
    case bundleTooLargeToInspect

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Choose the complete ONNX model folder containing genai_config.json, not an isolated graph."
        case let .unsupportedArchitecture(type):
            return "The ONNX architecture '\(type)' is not supported. This version supports Nemotron Speech Streaming exports (nemotron_speech)."
        case let .invalidConfiguration(reason):
            return "The ONNX speech configuration cannot be used: \(reason)"
        case let .missingComponent(name):
            return "The ONNX bundle is missing a readable \(name). Restore the complete model in its original location."
        case let .unsafeReference(name):
            return "The ONNX configuration contains an invalid local file reference: \(name)."
        case .bundleTooLargeToInspect:
            return "This folder contains too many files to be a single model bundle. Choose the model's version folder."
        }
    }
}

public enum ONNXBundleInspector {
    private struct Envelope: Decodable {
        let model: Configuration
    }

    private struct Configuration: Decodable {
        let type: String
        let sampleRate: Int?
        let chunkSamples: Int?
        let encoder: Component?
        let decoder: Component?
        let joiner: Component?
        let vad: Component?

        enum CodingKeys: String, CodingKey {
            case type, encoder, decoder, joiner, vad
            case sampleRate = "sample_rate"
            case chunkSamples = "chunk_samples"
        }
    }

    private struct Component: Decodable {
        let filename: String
    }

    public static func inspect(_ directory: URL, source: String) throws -> LocalModel {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let configURL = root.appendingPathComponent("genai_config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else { throw ONNXModelError.missingConfiguration }
        let configInfo = try localFile(configURL)
        guard configInfo.bytes <= 1_048_576 else {
            throw ONNXModelError.invalidConfiguration("genai_config.json exceeds 1 MiB.")
        }
        let data = try Data(contentsOf: configURL)
        let config: Configuration
        do { config = try JSONDecoder().decode(Envelope.self, from: data).model }
        catch { throw ONNXModelError.invalidConfiguration("genai_config.json is malformed: \(error.localizedDescription)") }
        guard config.type == "nemotron_speech" else { throw ONNXModelError.unsupportedArchitecture(config.type) }
        guard let sampleRate = config.sampleRate, sampleRate == AudioAnalysis.sampleRate,
              let chunkSamples = config.chunkSamples, (160...160_000).contains(chunkSamples) else {
            throw ONNXModelError.invalidConfiguration("Nemotron requires 16 kHz audio and a valid chunk_samples value.")
        }
        try validateOptions(JSONSerialization.jsonObject(with: data))
        guard let encoder = config.encoder, let decoder = config.decoder, let joiner = config.joiner else {
            throw ONNXModelError.invalidConfiguration("encoder, decoder, and joiner components are required.")
        }
        var required = [encoder.filename, decoder.filename, joiner.filename, "tokenizer.json"]
        if let vad = config.vad { required.append(vad.filename) }
        for reference in required {
            let file = try resolve(reference, relativeTo: root)
            _ = try localFile(file)
        }

        var bytes: Int64 = 0
        var identities = Set<String>()
        var revisions: [String] = [SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else { throw ONNXModelError.missingComponent(root.lastPathComponent) }
        var entries = 0
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            entries += 1
            guard entries <= 2048, enumerator.level <= 8 else { throw ONNXModelError.bundleTooLargeToInspect }
            let values = try file.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true { continue }
            let info = try localFile(file)
            if identities.insert(info.id).inserted {
                let sum = bytes.addingReportingOverflow(info.bytes)
                guard !sum.overflow else { throw ONNXModelError.bundleTooLargeToInspect }
                bytes = sum.partialValue
            }
            revisions.append("\(file.path)|\(info.id)|\(info.bytes)|\(info.modified)")
        }
        if let enumerationError { throw enumerationError }
        let revision = SHA256.hash(data: Data(revisions.sorted().joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let device = (attributes[.systemNumber] as? NSNumber)?.stringValue ?? ""
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? ""
        let id = device.isEmpty || inode.isEmpty ? root.path : "\(device):\(inode)"
        return LocalModel(
            id: "onnx:\(id)", url: root, bytes: bytes,
            onnx: ONNXSpeechConfiguration(sampleRate: sampleRate, chunkSamples: chunkSamples, revision: revision),
            source: source
        )
    }

    public static func hasConfiguration(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("genai_config.json").path)
    }

    private static func resolve(_ reference: String, relativeTo root: URL) throws -> URL {
        let components = reference.split(separator: "/", omittingEmptySubsequences: false)
        guard !reference.isEmpty, !reference.hasPrefix("/"), !reference.contains("\\"),
              !reference.contains(":"), !reference.contains("\0"),
              !components.contains(".."), !components.contains("") else {
            throw ONNXModelError.unsafeReference(reference)
        }
        return root.appendingPathComponent(reference)
    }

    private static func localFile(_ url: URL) throws -> (bytes: Int64, id: String, modified: TimeInterval) {
        let file = url.resolvingSymlinksInPath()
        var status = stat()
        let result = file.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &status)
        }
        guard result == 0 else { throw ONNXModelError.missingComponent(url.lastPathComponent) }
        if status.st_flags & UInt32(SF_DATALESS) != 0 { throw ModelFileError.notDownloaded }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              FileManager.default.isReadableFile(atPath: file.path) else {
            throw ONNXModelError.missingComponent(url.lastPathComponent)
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw ONNXModelError.missingComponent(url.lastPathComponent) }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        return (size, "\(status.st_dev):\(status.st_ino)", modified)
    }

    private static func validateOptions(_ object: Any) throws {
        if let values = object as? [String: Any] {
            for (key, value) in values {
                if ["custom_ops_library", "custom_op_library", "custom_ops_library_path",
                    "optimized_model_filepath", "enable_profiling",
                    "ep_context_enable", "ep_context_file_path"].contains(key) {
                    throw ONNXModelError.invalidConfiguration("\(key) is not allowed in a read-only, private speech bundle.")
                }
                if key == "provider_options" {
                    guard let providers = value as? [[String: Any]],
                          providers.allSatisfy({ $0.isEmpty || Set($0.keys) == ["CPUExecutionProvider"] }) else {
                        throw ONNXModelError.invalidConfiguration("Use a CPU-compatible ONNX export on this Mac.")
                    }
                }
                try validateOptions(value)
            }
        } else if let array = object as? [Any] {
            for value in array { try validateOptions(value) }
        }
    }
}
