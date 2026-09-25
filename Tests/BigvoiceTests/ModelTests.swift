import BigvoiceCore
import Foundation

private func header(vocabulary: UInt32 = 51_864, state: UInt32 = 384) -> Data {
    let values: [UInt32] = [0x67676d6c, vocabulary, 1500, state, 6, 4, 448, state, 6, 4, 80, 9]
    var data = Data()
    for value in values {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    return data
}

private func model(in directory: URL, name: String, vocabulary: UInt32 = 51_864) throws -> URL {
    let file = directory.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    var data = header(vocabulary: vocabulary)
    data.append(Data(repeating: 0, count: 1_000_000 - data.count))
    try data.write(to: file)
    return file
}

private let nemotronComponents = ["encoder.onnx", "encoder.onnx.data", "decoder.onnx", "joint.onnx", "silero_vad.onnx", "tokenizer.json"]

private func nemotronConfig(_ overrides: [String: Any] = [:]) -> [String: Any] {
    var model: [String: Any] = [
        "type": "nemotron_speech", "sample_rate": 16_000, "chunk_samples": 8_960,
        "encoder": ["filename": "encoder.onnx", "session_options": ["session.intra_op.allow_spinning": "0"]],
        "decoder": ["filename": "decoder.onnx"], "joiner": ["filename": "joint.onnx"],
        "vad": ["filename": "silero_vad.onnx", "threshold": 0.3]
    ]
    for (key, value) in overrides { model[key] = value }
    return model
}

@discardableResult
private func nemotronBundle(at folder: URL, config: [String: Any] = nemotronConfig(), omitting: Set<String> = []) throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["model": config]).write(to: folder.appendingPathComponent("genai_config.json"))
    for name in nemotronComponents where !omitting.contains(name) {
        try Data(repeating: 7, count: 4_096).write(to: folder.appendingPathComponent(name))
    }
    return folder
}

private func snapshot(_ folder: URL) throws -> [String: Date] {
    var result: [String: Date] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
        result[name] = attributes[.modificationDate] as? Date
    }
    return result
}

let modelTests: [RegressionTest] = [
    RegressionTest(name: "Complete Copilot Nemotron bundle is reused in place as a selectable model") {
        try withTemporaryDirectory { home in
            let folder = home.appendingPathComponent(
                ".github-copilot-cli/cache/models/Microsoft/nemotron-speech-streaming-en-0.6b-generic-cpu-3/v3"
            )
            try nemotronBundle(at: folder)
            let before = try snapshot(folder)
            let managed = home.appendingPathComponent("bigvoice-models")
            let report = try ModelDiscovery.scan(
                roots: ModelDiscovery.standardRoots(home: home, managed: managed, environment: [:]), managedDirectory: managed
            )
            try expect(report.incompatible.isEmpty, "A complete Nemotron bundle must not be listed as incompatible.")
            try expect(report.models.count == 1)
            let found = report.models[0]
            guard case let .nemotronONNX(settings) = found.kind else { throw TestFailure(message: "Expected an ONNX model") }
            try expect(settings.sampleRate == 16_000 && settings.chunkSamples == 8_960)
            try expect(found.name == "Nemotron Speech" && found.languageLabel == "English")
            try expect(found.source == "GitHub Copilot" && !found.isManaged)
            try expect(found.url.path == folder.resolvingSymlinksInPath().path)
            let configBytes = try Data(contentsOf: folder.appendingPathComponent("genai_config.json")).count
            try expect(found.bytes == Int64(nemotronComponents.count * 4_096 + configBytes), "Bundle size must count every file once.")
            try expect(!ModelPreset.all.contains { found.canReplace($0) }, "ONNX bundles never substitute for Whisper downloads.")
            try expect(try snapshot(folder) == before, "Discovery must not modify the original bundle.")
            try expect(!FileManager.default.fileExists(atPath: managed.path))
        }
    },
    RegressionTest(name: "Incomplete Nemotron bundles are explained with a reason and never offered") {
        try withTemporaryDirectory { home in
            let modelName = "nemotron-speech-streaming-en-0.6b-generic-cpu-3"
            let folder = home.appendingPathComponent(".github-copilot-cli/cache/models/Microsoft/\(modelName)/v3")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"model":{"type":"nemotron_speech"}}"#.utf8)
                .write(to: folder.appendingPathComponent("genai_config.json"))
            for name in ["model.onnx", "encoder.onnx", "decoder.onnx", "joint.onnx", "silero_vad.onnx", "encoder.onnx.data"] {
                try Data([1, 2, 3]).write(to: folder.appendingPathComponent(name))
            }
            let originalFiles = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            let managed = home.appendingPathComponent("bigvoice-models")
            let roots = ModelDiscovery.standardRoots(home: home, managed: managed, environment: [:]) +
                [DiscoveryRoot(url: folder, label: "Duplicate folder")]
            let report = try ModelDiscovery.scan(roots: roots, managedDirectory: managed)
            try expect(report.models.isEmpty, "An incomplete bundle must never be selectable.")
            try expect(report.incompatible.count == 1)
            let bundle = report.incompatible[0]
            try expect(bundle.source == "GitHub Copilot")
            try expect(bundle.format == "ONNX speech bundle")
            try expect(bundle.name == "\(modelName) (v3)")
            try expect(bundle.reason?.isEmpty == false, "Users need the specific reason a bundle cannot run.")
            try expect(bundle.url.path == folder.resolvingSymlinksInPath().path)
            try expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == originalFiles)
            try expect(!FileManager.default.fileExists(atPath: managed.path))
        }
    },
    RegressionTest(name: "Missing ONNX components block selection and name the missing file") {
        try withTemporaryDirectory { directory in
            let folder = try nemotronBundle(at: directory.appendingPathComponent("speech/nemotron"), omitting: ["joint.onnx"])
            try expectThrows { _ = try ONNXBundleInspector.inspect(folder, source: "Test") }
            let report = try ModelDiscovery.scan(roots: [DiscoveryRoot(url: directory, label: "Test")], managedDirectory: directory)
            try expect(report.models.isEmpty)
            try expect(report.incompatible.first?.reason?.contains("joint.onnx") == true)
        }
    },
    RegressionTest(name: "ONNX configurations cannot reference files outside the model folder") {
        try withTemporaryDirectory { directory in
            for reference in ["../outside.onnx", "/etc/hosts", "nested/../../escape.onnx", "", "C:model.onnx"] {
                let folder = try nemotronBundle(
                    at: directory.appendingPathComponent("case-\(UUID().uuidString)"),
                    config: nemotronConfig(["encoder": ["filename": reference]])
                )
                do {
                    _ = try ONNXBundleInspector.inspect(folder, source: "Test")
                    throw TestFailure(message: "Accepted unsafe reference '\(reference)'")
                } catch ONNXModelError.unsafeReference {
                }
            }
        }
    },
    RegressionTest(name: "ONNX configurations cannot load native code, write files, or require other hardware") {
        try withTemporaryDirectory { directory in
            let unsafe: [[String: Any]] = [
                ["session_options": ["custom_ops_library": "/tmp/evil.dylib"]],
                ["session_options": ["enable_profiling": "trace"]],
                ["session_options": ["ep_context_file_path": "/tmp/context.onnx"]],
                ["session_options": ["provider_options": [["CUDAExecutionProvider": [:]]]]]
            ]
            for options in unsafe {
                var encoder: [String: Any] = ["filename": "encoder.onnx"]
                for (key, value) in options { encoder[key] = value }
                let folder = try nemotronBundle(
                    at: directory.appendingPathComponent("case-\(UUID().uuidString)"), config: nemotronConfig(["encoder": encoder])
                )
                try expectThrows { _ = try ONNXBundleInspector.inspect(folder, source: "Test") }
            }
            let harmless = try nemotronBundle(
                at: directory.appendingPathComponent("harmless"),
                config: nemotronConfig(["encoder": ["filename": "encoder.onnx", "session_options": ["log_id": "speech"]]])
            )
            _ = try ONNXBundleInspector.inspect(harmless, source: "Test")
        }
    },
    RegressionTest(name: "Model folders, configs, and ONNX graphs all resolve to the same bundle") {
        try withTemporaryDirectory { directory in
            let folder = try nemotronBundle(at: directory.appendingPathComponent("nemotron"))
            let managed = directory.appendingPathComponent("managed")
            let candidates = [folder, folder.appendingPathComponent("genai_config.json"), folder.appendingPathComponent("encoder.onnx")]
            let ids = try candidates.map { try ModelFileInspector.inspect($0, source: "Added by you", managedDirectory: managed).id }
            try expect(Set(ids).count == 1)
            let report = try ModelDiscovery.scan(
                roots: [DiscoveryRoot(url: directory, label: "Folder")], managedDirectory: managed, explicitFiles: candidates
            )
            try expect(report.models.count == 1, "The same bundle must be listed once however it was added.")
        }
    },
    RegressionTest(name: "ONNX bundle revision changes when its weights change") {
        try withTemporaryDirectory { directory in
            let folder = try nemotronBundle(at: directory.appendingPathComponent("nemotron"))
            let first = try ONNXBundleInspector.inspect(folder, source: "Test")
            try Data(repeating: 9, count: 8_192).write(to: folder.appendingPathComponent("encoder.onnx.data"))
            let second = try ONNXBundleInspector.inspect(folder, source: "Test")
            guard case let .nemotronONNX(a) = first.kind, case let .nemotronONNX(b) = second.kind else {
                throw TestFailure(message: "Expected ONNX models")
            }
            try expect(a.revision != b.revision, "Changed weights must force a reload.")
            try expect(first.id == second.id, "The folder identity must stay stable across updates.")
        }
    },
    RegressionTest(name: "Copilot model cache is a built-in source and compatible files are reused in place") {
        try withTemporaryDirectory { home in
            let relativeCache = ".github-copilot-cli/cache/models"
            let original = try model(in: home, name: "\(relativeCache)/Microsoft/whisper/v1/ggml-tiny.en.bin")
            let originalData = try Data(contentsOf: original)
            let managed = home.appendingPathComponent("bigvoice-models")
            let roots = ModelDiscovery.standardRoots(home: home, managed: managed, environment: [:])
            try expect(roots.contains {
                $0.label == "GitHub Copilot" && $0.url.path == home.appendingPathComponent(relativeCache).path
            }, "GitHub Copilot's actual Foundry cache must be searched automatically.")
            let report = try ModelDiscovery.scan(roots: roots, managedDirectory: managed, explicitFiles: [original])
            try expect(report.models.count == 1)
            try expect(report.models[0].source == "GitHub Copilot")
            try expect(report.models[0].url == original.resolvingSymlinksInPath())
            try expect(!report.models[0].isManaged)
            try expect(try Data(contentsOf: original) == originalData)
            try expect(!FileManager.default.fileExists(atPath: managed.path))
        }
    },
    RegressionTest(name: "Copilot ONNX speech components surface as one incompatible bundle with their source") {
        try withTemporaryDirectory { home in
            let modelName = "nemotron-speech-streaming-en-0.6b-generic-cpu-3"
            let folder = home.appendingPathComponent(".github-copilot-cli/cache/models/Microsoft/\(modelName)/v3")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"model":{"type":"nemotron_speech"}}"#.utf8)
                .write(to: folder.appendingPathComponent("genai_config.json"))
            for name in ["model.onnx", "encoder.onnx", "decoder.onnx", "joint.onnx", "silero_vad.onnx", "encoder.onnx.data"] {
                try Data([1, 2, 3]).write(to: folder.appendingPathComponent(name))
            }
            let originalFiles = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
            let managed = home.appendingPathComponent("bigvoice-models")
            let roots = ModelDiscovery.standardRoots(home: home, managed: managed, environment: [:]) +
                [DiscoveryRoot(url: folder, label: "Duplicate folder")]
            let report = try ModelDiscovery.scan(roots: roots, managedDirectory: managed)
            try expect(report.models.isEmpty, "ONNX speech weights must never be offered to the Whisper engine.")
            try expect(report.incompatible.count == 1)
            let bundle = report.incompatible[0]
            try expect(bundle.source == "GitHub Copilot")
            try expect(bundle.format == "ONNX speech bundle")
            try expect(bundle.name == "\(modelName) (v3)")
            try expect(bundle.url.path == folder.resolvingSymlinksInPath().path)
            try expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == originalFiles)
            try expect(!FileManager.default.fileExists(atPath: managed.path))
        }
    },
    RegressionTest(name: "Copilot chat model ONNX files are not mistaken for dictation models") {
        try withTemporaryDirectory { home in
            let folder = home.appendingPathComponent(".github-copilot-cli/cache/models/Microsoft/phi-4-generic-cpu/v1")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"model":{"type":"phi"}}"#.utf8).write(to: folder.appendingPathComponent("genai_config.json"))
            try Data([1, 2, 3]).write(to: folder.appendingPathComponent("model.onnx"))
            let managed = home.appendingPathComponent("bigvoice-models")
            let report = try ModelDiscovery.scan(
                roots: ModelDiscovery.standardRoots(home: home, managed: managed, environment: [:]),
                managedDirectory: managed
            )
            try expect(report.models.isEmpty)
            try expect(report.incompatible.isEmpty)
        }
    },
    RegressionTest(name: "Standalone Copilot ONNX speech files retain their file reference") {
        try withTemporaryDirectory { home in
            let folder = home.appendingPathComponent(".github-copilot-cli/cache/models")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("whisper-tiny.onnx")
            try Data([1, 2, 3]).write(to: file)
            let managed = home.appendingPathComponent("bigvoice-models")
            let report = try ModelDiscovery.scan(
                roots: ModelDiscovery.standardRoots(home: home, managed: managed, environment: [:]),
                managedDirectory: managed
            )
            try expect(report.models.isEmpty)
            try expect(report.incompatible.count == 1)
            try expect(report.incompatible[0].url.path == file.resolvingSymlinksInPath().path)
            try expect(report.incompatible[0].format == "ONNX")
            try expect(report.incompatible[0].source == "GitHub Copilot")
        }
    },
    RegressionTest(name: "Model discovery respects relocated cache environment variables") {
        let roots = ModelDiscovery.standardRoots(
            home: URL(fileURLWithPath: "/test-home"), managed: URL(fileURLWithPath: "/managed"),
            environment: ["HF_HOME": "/external/hf", "XDG_CACHE_HOME": "/external/cache", "HF_HUB_CACHE": "/direct-hub"]
        )
        try expect(roots.contains { $0.url.path == "/external/hf/hub" })
        try expect(roots.contains { $0.url.path == "/external/cache/whisper" })
        try expect(roots.contains { $0.url.path == "/direct-hub" })
    },
    RegressionTest(name: "Headers distinguish English multilingual and unrelated GGML") {
        try expect(try ModelFileInspector.parseHeader(header()).family == .tiny)
        try expect(try !ModelFileInspector.parseHeader(header()).multilingual)
        try expect(try ModelFileInspector.parseHeader(header(vocabulary: 51_865)).multilingual)
        try expectThrows { _ = try ModelFileInspector.parseHeader(Data(repeating: 0, count: 48)) }
        try expectThrows { _ = try ModelFileInspector.parseHeader(header(state: 4096)) }
        try expectThrows { _ = try ModelFileInspector.parseHeader(header(vocabulary: 32_000)) }
        try expectThrows { _ = try ModelFileInspector.parseHeader(Data([1, 2, 3])) }
    },
    RegressionTest(name: "Discovery deduplicates symlinks hardlinks renamed files and repeated roots") {
        try withTemporaryDirectory { directory in
            let original = try model(in: directory, name: "cache/renamed-whisper.bin")
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("linked.bin"), withDestinationURL: original)
            try FileManager.default.linkItem(at: original, to: directory.appendingPathComponent("hardlink.bin"))
            let report = try ModelDiscovery.scan(
                roots: [DiscoveryRoot(url: directory, label: "Cache"), DiscoveryRoot(url: directory, label: "Duplicate")],
                managedDirectory: directory.appendingPathComponent("owned"), explicitFiles: [original]
            )
            try expect(report.models.count == 1)
            try expect(!report.models[0].isManaged)
            try expect(report.searchedFolders == 1)
            try expect(report.models[0].canReplace(ModelPreset.all[0]))
        }
    },
    RegressionTest(name: "Managed containment rejects sibling prefixes and external symlink targets") {
        try withTemporaryDirectory { directory in
            let managed = directory.appendingPathComponent("Models")
            let sibling = try model(in: directory, name: "Models-other/ggml.bin")
            try expect(!ModelFileInspector.contains(sibling, in: managed))
            try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
            let link = managed.appendingPathComponent("outside.bin")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sibling)
            let inspected = try ModelFileInspector.inspect(link, source: "External", managedDirectory: managed)
            try expect(!inspected.isManaged)
            try expect(FileManager.default.fileExists(atPath: sibling.path))
        }
    },
    RegressionTest(name: "Discovery respects depth and reports missing explicit model files") {
        try withTemporaryDirectory { directory in
            _ = try model(in: directory, name: "nested/deep/model.bin")
            let report = try ModelDiscovery.scan(
                roots: [DiscoveryRoot(url: directory, label: "Bounded", maxDepth: 1)],
                managedDirectory: directory, explicitFiles: [directory.appendingPathComponent("missing.bin")]
            )
            try expect(report.models.isEmpty)
            try expect(report.warnings.contains { $0.contains("missing.bin") })
            try expect(report.warnings.contains { $0.contains("levels deep") })
        }
    },
    RegressionTest(name: "Discovery entry limits are visible") {
        try withTemporaryDirectory { directory in
            for index in 0..<4 { try Data().write(to: directory.appendingPathComponent("\(index).txt")) }
            let report = try ModelDiscovery.scan(
                roots: [DiscoveryRoot(url: directory, label: "Bounded")], managedDirectory: directory, entryLimitPerRoot: 2
            )
            try expect(report.warnings.contains { $0.contains("search limit") })
        }
    },
    RegressionTest(name: "Other voice formats are explained and never imported") {
        try withTemporaryDirectory { directory in
            let folder = directory.appendingPathComponent("whisper-mlx")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: folder.appendingPathComponent("model.safetensors"))
            let report = try ModelDiscovery.scan(
                roots: [DiscoveryRoot(url: directory, label: "Cache")], managedDirectory: directory
            )
            try expect(report.models.isEmpty)
            try expect(report.incompatible.first?.format == "MLX / Safetensors")
        }
    },
    RegressionTest(name: "Download pointers and directories cannot be model files") {
        try withTemporaryDirectory { directory in
            let pointer = directory.appendingPathComponent("ggml-tiny.bin")
            try Data("version https://git-lfs.github.com/spec/v1".utf8).write(to: pointer)
            try expectThrows { _ = try ModelFileInspector.inspect(pointer, source: "Test", managedDirectory: directory) }
            try expectThrows { _ = try ModelFileInspector.inspect(directory, source: "Test", managedDirectory: directory) }
        }
    },
    RegressionTest(name: "Indexed files are reused without being copied") {
        try withTemporaryDirectory { directory in
            let original = try model(in: directory, name: "external/ggml-whisper.bin")
            let managed = directory.appendingPathComponent("managed")
            let report = try ModelDiscovery.scan(roots: [], managedDirectory: managed, indexedFiles: [original])
            try expect(report.models.count == 1)
            try expect(report.models[0].source == "System file index")
            try expect(!report.models[0].isManaged)
            try expect(!FileManager.default.fileExists(atPath: managed.path))
        }
    }
]
