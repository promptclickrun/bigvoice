import Foundation

public struct DiscoveryRoot: Sendable {
    public let url: URL
    public let label: String
    public let maxDepth: Int

    public init(url: URL, label: String, maxDepth: Int = 6) {
        self.url = url
        self.label = label
        self.maxDepth = maxDepth
    }
}

public struct IncompatibleModel: Identifiable, Equatable, Sendable {
    public let url: URL
    public let format: String
    public let source: String
    public let name: String
    public let reason: String?
    public var id: String { url.path }

    public init(url: URL, format: String, source: String, name: String? = nil, reason: String? = nil) {
        self.url = url.standardizedFileURL.resolvingSymlinksInPath()
        self.format = format
        self.source = source
        self.name = name ?? url.lastPathComponent
        self.reason = reason
    }
}

public struct DiscoveryReport: Sendable {
    public var models: [LocalModel] = []
    public var incompatible: [IncompatibleModel] = []
    public var warnings: [String] = []
    public var searchedFolders = 0
    public init() {}
}

public enum ModelDiscovery {
    public static var managedDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/bigvoice/Models", isDirectory: true)
    }

    public static func standardRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                     managed: URL = managedDirectory,
                                     environment: [String: String] = ProcessInfo.processInfo.environment) -> [DiscoveryRoot] {
        var roots = [
            DiscoveryRoot(url: managed, label: "bigvoice"),
            DiscoveryRoot(url: home.appendingPathComponent(".github-copilot-cli/cache/models"), label: "GitHub Copilot"),
            DiscoveryRoot(url: home.appendingPathComponent("Library/Application Support/MacWhisper"), label: "MacWhisper"),
            DiscoveryRoot(url: home.appendingPathComponent("Library/Application Support/com.goodsnooze.MacWhisper"), label: "MacWhisper"),
            DiscoveryRoot(url: home.appendingPathComponent("Library/Containers/com.goodsnooze.MacWhisper/Data/Library/Application Support"), label: "MacWhisper"),
            DiscoveryRoot(url: home.appendingPathComponent("Library/Application Support/superwhisper"), label: "superwhisper"),
            DiscoveryRoot(url: home.appendingPathComponent("Library/Application Support/VoiceInk"), label: "VoiceInk"),
            DiscoveryRoot(url: home.appendingPathComponent("Library/Application Support/com.prakashjoshipax.VoiceInk"), label: "VoiceInk"),
            DiscoveryRoot(url: home.appendingPathComponent("Library/Application Support/com.pais.handy"), label: "Handy"),
            DiscoveryRoot(url: home.appendingPathComponent("Library/Application Support/whisper.cpp"), label: "whisper.cpp"),
            DiscoveryRoot(url: home.appendingPathComponent("Library/Caches/whisper"), label: "Whisper cache"),
            DiscoveryRoot(url: home.appendingPathComponent("Library/Caches/huggingface/hub"), label: "Hugging Face", maxDepth: 8),
            DiscoveryRoot(url: home.appendingPathComponent(".cache/whisper"), label: "Whisper cache"),
            DiscoveryRoot(url: home.appendingPathComponent(".cache/huggingface/hub"), label: "Hugging Face", maxDepth: 8),
            DiscoveryRoot(url: home.appendingPathComponent("Models"), label: "Models"),
            DiscoveryRoot(url: home.appendingPathComponent("Downloads"), label: "Downloads", maxDepth: 2)
        ]
        for key in ["HF_HUB_CACHE", "HUGGINGFACE_HUB_CACHE", "WHISPER_CPP_MODEL_DIR"] {
            if let path = environment[key], path.hasPrefix("/") {
                roots.append(DiscoveryRoot(url: URL(fileURLWithPath: path), label: key, maxDepth: 8))
            }
        }
        if let path = environment["HF_HOME"], path.hasPrefix("/") {
            roots.append(DiscoveryRoot(url: URL(fileURLWithPath: path).appendingPathComponent("hub"), label: "Hugging Face", maxDepth: 8))
        }
        if let path = environment["XDG_CACHE_HOME"], path.hasPrefix("/") {
            let cache = URL(fileURLWithPath: path)
            roots.append(DiscoveryRoot(url: cache.appendingPathComponent("huggingface/hub"), label: "Hugging Face", maxDepth: 8))
            roots.append(DiscoveryRoot(url: cache.appendingPathComponent("whisper"), label: "Whisper cache"))
        }
        return roots
    }

    public static func scan(roots: [DiscoveryRoot], managedDirectory: URL,
                            explicitFiles: [URL] = [], indexedFiles: [URL] = [],
                            entryLimitPerRoot: Int = 12_000) throws -> DiscoveryReport {
        var report = DiscoveryReport()
        var seenFiles = Set<String>()
        var seenRoots = Set<String>()
        var seenIncompatible = Set<String>()
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]

        func inspect(_ url: URL, source: String, reportErrors: Bool = false) {
            do {
                let model = try ModelFileInspector.inspect(url, source: source, managedDirectory: managedDirectory)
                if seenFiles.insert(model.id).inserted { report.models.append(model) }
            } catch {
                if reportErrors {
                    report.warnings.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        func inspectBundle(_ url: URL, source: String) throws {
            do {
                let model = try ONNXBundleInspector.inspect(url, source: source)
                if seenFiles.insert(model.id).inserted { report.models.append(model) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let speechArchitecture: Bool
                if case let ONNXModelError.unsupportedArchitecture(type) = error {
                    speechArchitecture = ["whisper", "streaming_enc_dec_asr"].contains(type) || type.contains("speech")
                } else {
                    speechArchitecture = true
                }
                guard looksLikeSpeechModel(url) || speechArchitecture else { return }
                let entry = IncompatibleModel(
                    url: url, format: "ONNX speech bundle", source: source,
                    name: bundleName(url), reason: error.localizedDescription
                )
                if seenIncompatible.insert(entry.id).inserted { report.incompatible.append(entry) }
            }
        }

        for root in roots {
            try Task.checkCancellation()
            let canonical = root.url.standardizedFileURL.resolvingSymlinksInPath()
            guard seenRoots.insert(canonical.path).inserted else { continue }
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: root.url.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                inspect(root.url, source: root.label, reportErrors: true)
                continue
            }
            report.searchedFolders += 1
            if ONNXBundleInspector.hasConfiguration(root.url) {
                try inspectBundle(root.url, source: root.label)
                continue
            }
            guard let enumerator = manager.enumerator(
                at: root.url, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants],
                errorHandler: { url, error in
                    report.warnings.append("Could not search \(url.lastPathComponent): \(error.localizedDescription)")
                    return true
                }
            ) else {
                report.warnings.append("Could not search \(root.label). Add this folder manually if access is restricted.")
                continue
            }
            var entries = 0
            var reachedDepthLimit = false
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                entries += 1
                if entries > entryLimitPerRoot {
                    report.warnings.append("\(root.label) reached the search limit. Add a more specific folder to search deeper.")
                    break
                }
                let name = url.lastPathComponent.lowercased()
                let ext = url.pathExtension.lowercased()
                let values: URLResourceValues
                do { values = try url.resourceValues(forKeys: Set(keys)) }
                catch {
                    report.warnings.append("Could not inspect \(url.lastPathComponent): \(error.localizedDescription)")
                    continue
                }
                if values.isDirectory == true {
                    if enumerator.level > root.maxDepth {
                        reachedDepthLimit = true
                        enumerator.skipDescendants()
                        continue
                    } else if ["node_modules", ".git", ".locks", "venv", ".venv"].contains(name) {
                        enumerator.skipDescendants()
                        continue
                    }
                    if ONNXBundleInspector.hasConfiguration(url) {
                        try inspectBundle(url, source: root.label)
                        enumerator.skipDescendants()
                        continue
                    }
                    if ["mlmodelc", "mlpackage"].contains(ext) && looksLikeSpeechModel(url) {
                        let model = IncompatibleModel(url: url, format: "Core ML", source: root.label)
                        if seenIncompatible.insert(model.id).inserted {
                            report.incompatible.append(model)
                        }
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard enumerator.level <= root.maxDepth else { continue }
                if ["bin", "ggml"].contains(ext) {
                    inspect(url, source: root.label)
                } else if ["pt", "safetensors", "gguf", "onnx"].contains(ext) && looksLikeSpeechModel(url) {
                    let model = incompatibleModel(at: url, source: root.label)
                    if seenIncompatible.insert(model.id).inserted {
                        report.incompatible.append(model)
                    }
                }
            }
            if reachedDepthLimit {
                report.warnings.append("\(root.label) was searched up to \(root.maxDepth) levels deep. Add a specific subfolder to search further.")
            }
        }
        for url in indexedFiles {
            try Task.checkCancellation()
            inspect(url, source: "System file index")
        }
        for url in explicitFiles {
            try Task.checkCancellation()
            inspect(url, source: "Added by you", reportErrors: true)
        }
        try Task.checkCancellation()
        report.models.sort {
            if $0.isManaged != $1.isManaged { return $0.isManaged }
            if $0.bytes != $1.bytes { return $0.bytes < $1.bytes }
            return $0.url.path < $1.url.path
        }
        report.warnings = Array(Set(report.warnings)).sorted()
        return report
    }

    private static func looksLikeSpeechModel(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return ["whisper", "voiceink", "parakeet", "speech"].contains { path.contains($0) } ||
            ["tiny", "base", "small", "medium", "large"].contains(url.deletingPathExtension().lastPathComponent)
    }

    private static func incompatibleModel(at url: URL, source: String) -> IncompatibleModel {
        let ext = url.pathExtension.lowercased()
        let folder = url.deletingLastPathComponent()
        if ext == "onnx",
           FileManager.default.fileExists(atPath: folder.appendingPathComponent("genai_config.json").path) {
            return IncompatibleModel(url: folder, format: "ONNX speech bundle", source: source, name: bundleName(folder))
        }
        let format = ext == "pt" ? "PyTorch" : ext == "safetensors" ? "MLX / Safetensors" : ext == "gguf" ? "GGUF" : "ONNX"
        return IncompatibleModel(url: url, format: format, source: source)
    }

    private static func bundleName(_ folder: URL) -> String {
        let version = folder.lastPathComponent
        let isVersionDirectory = version.range(of: "^v[0-9]+$", options: .regularExpression) != nil
        return isVersionDirectory ? "\(folder.deletingLastPathComponent().lastPathComponent) (\(version))" : version
    }
}
