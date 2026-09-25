import Foundation
import Darwin

public enum ModelFamily: String, Codable, Sendable {
    case tiny, base, small, medium, large
}

public enum SpeechModelKind: Equatable, Sendable {
    case whisper(family: ModelFamily, multilingual: Bool)
    case nemotronONNX(ONNXSpeechConfiguration)
}

public struct ModelPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public let filename: String
    public let bytes: Int64
    public let sha256: String
    public let family: ModelFamily
    public let multilingual: Bool

    public var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(Self.revision)/\(filename)?download=true")!
    }

    public var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static let revision = "5359861c739e955e79d9a303bcbc70fb988958b1"

    public static let all: [ModelPreset] = [
        ModelPreset(
            id: "tiny-en", name: "Whisper Tiny", detail: "The lightest footprint. Quick notes and short messages.",
            filename: "ggml-tiny.en-q5_1.bin", bytes: 32_166_155,
            sha256: "c77c5766f1cef09b6b7d47f21b546cbddd4157886b3b5d6d4f709e91e66c7c2b",
            family: .tiny, multilingual: false
        ),
        ModelPreset(
            id: "base-en", name: "Whisper Base", detail: "A good starting point for everyday English dictation.",
            filename: "ggml-base.en-q5_1.bin", bytes: 59_721_011,
            sha256: "4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f",
            family: .base, multilingual: false
        ),
        ModelPreset(
            id: "tiny-multilingual", name: "Whisper Tiny", detail: "Small and multilingual. Automatically detects your language.",
            filename: "ggml-tiny.bin", bytes: 77_691_713,
            sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21",
            family: .tiny, multilingual: true
        ),
        ModelPreset(
            id: "base-multilingual", name: "Whisper Base", detail: "More capacity for multilingual notes and conversations.",
            filename: "ggml-base.bin", bytes: 147_951_465,
            sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
            family: .base, multilingual: true
        ),
        ModelPreset(
            id: "small-en", name: "Whisper Small", detail: "More accuracy for longer thoughts. Uses more memory and compute.",
            filename: "ggml-small.en-q5_1.bin", bytes: 190_098_681,
            sha256: "bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30",
            family: .small, multilingual: false
        )
    ]
}

public struct LocalModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let url: URL
    public let bytes: Int64
    public let kind: SpeechModelKind
    public let source: String
    public let isManaged: Bool

    public init(id: String, url: URL, bytes: Int64, family: ModelFamily,
                multilingual: Bool, source: String, isManaged: Bool) {
        self.id = id
        self.url = url
        self.bytes = bytes
        self.kind = .whisper(family: family, multilingual: multilingual)
        self.source = source
        self.isManaged = isManaged
    }

    public init(id: String, url: URL, bytes: Int64, onnx: ONNXSpeechConfiguration, source: String) {
        self.id = id
        self.url = url
        self.bytes = bytes
        self.kind = .nemotronONNX(onnx)
        self.source = source
        self.isManaged = false
    }

    public var family: ModelFamily? {
        if case let .whisper(family, _) = kind { return family }
        return nil
    }
    public var multilingual: Bool {
        if case let .whisper(_, multilingual) = kind { return multilingual }
        return false
    }
    public var name: String {
        switch kind {
        case let .whisper(family, _): return "Whisper \(family.rawValue.capitalized)"
        case .nemotronONNX: return "Nemotron Speech"
        }
    }
    public var formatLabel: String {
        switch kind {
        case .whisper: return "Whisper GGML"
        case .nemotronONNX: return "ONNX · CPU"
        }
    }
    public var languageLabel: String { multilingual ? "Multilingual" : "English" }
    public var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    public func canReplace(_ preset: ModelPreset) -> Bool {
        guard case let .whisper(family, multilingual) = kind else { return false }
        return family == preset.family && multilingual == preset.multilingual
    }
}

public enum ModelFileError: LocalizedError, Equatable {
    case notAFile, tooSmall, incompatible, invalidHeader, notDownloaded

    public var errorDescription: String? {
        switch self {
        case .notAFile: return "Choose a readable Whisper GGML file or a supported ONNX speech model folder."
        case .tooSmall: return "This file is incomplete or is a download pointer, not a speech model."
        case .incompatible: return "Choose a Whisper GGML file or a Nemotron ONNX folder containing genai_config.json. Standalone ONNX graphs, MLX, Core ML, GGUF, and PyTorch weights are not supported."
        case .invalidHeader: return "The Whisper model header is damaged or unsupported."
        case .notDownloaded: return "This model is a cloud-only placeholder. Download it in its original app before reusing it in bigvoice."
        }
    }
}

public enum ModelFileInspector {
    public static func inspect(_ url: URL, source: String, managedDirectory: URL) throws -> LocalModel {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return try ONNXBundleInspector.inspect(canonical, source: source)
        }
        if canonical.lastPathComponent == "genai_config.json" || canonical.pathExtension.lowercased() == "onnx" {
            return try ONNXBundleInspector.inspect(canonical.deletingLastPathComponent(), source: source)
        }
        var fileStatus = stat()
        let status = canonical.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &fileStatus)
        }
        if status == 0 && fileStatus.st_flags & UInt32(SF_DATALESS) != 0 { throw ModelFileError.notDownloaded }
        let attributes = try FileManager.default.attributesOfItem(atPath: canonical.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              FileManager.default.isReadableFile(atPath: canonical.path) else { throw ModelFileError.notAFile }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size >= 1_000_000 else { throw ModelFileError.tooSmall }
        let file = try FileHandle(forReadingFrom: canonical)
        defer { try? file.close() }
        let header = try file.read(upToCount: 48) ?? Data()
        let metadata = try parseHeader(header)
        let device = (attributes[.systemNumber] as? NSNumber)?.stringValue ?? ""
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? ""
        let identity = device.isEmpty || inode.isEmpty ? canonical.path : "\(device):\(inode)"
        return LocalModel(
            id: identity, url: canonical, bytes: size, family: metadata.family,
            multilingual: metadata.multilingual, source: source,
            isManaged: contains(canonical, in: managedDirectory)
        )
    }

    public static func parseHeader(_ data: Data) throws -> (family: ModelFamily, multilingual: Bool) {
        guard data.count >= 48 else { throw ModelFileError.invalidHeader }
        let bytes = Array(data.prefix(48))
        let values: [UInt32] = stride(from: 0, to: 48, by: 4).map { offset in
            let low = UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            let high = (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
            return low | high
        }
        guard values[0] == 0x67676d6c else { throw ModelFileError.incompatible }
        let families: [UInt32: ModelFamily] = [384: .tiny, 512: .base, 768: .small, 1024: .medium, 1280: .large]
        guard let family = families[values[3]],
              (51_864...51_866).contains(values[1]),
              values[2] == 1500, values[6] == 448,
              values[3] == values[7],
              values[4] > 0, values[3] % values[4] == 0,
              values[8] > 0, values[7] % values[8] == 0,
              (1...32).contains(values[5]), (1...32).contains(values[9]),
              [80, 128].contains(values[10]) else { throw ModelFileError.invalidHeader }
        return (family, values[1] != 51_864)
    }

    public static func contains(_ file: URL, in directory: URL) -> Bool {
        let parent = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let child = file.standardizedFileURL.resolvingSymlinksInPath().path
        return child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }
}
