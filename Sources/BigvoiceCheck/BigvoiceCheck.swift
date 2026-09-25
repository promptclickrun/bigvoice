import BigvoiceCore
import BigvoiceRuntime
import Foundation

@main
struct BigvoiceCheck {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first else { printUsage(); return }
            switch command {
            case "scan":
                let roots = arguments.count > 1
                    ? arguments.dropFirst().map { DiscoveryRoot(url: URL(fileURLWithPath: $0), label: "Specified folder") }
                    : ModelDiscovery.standardRoots()
                let report = try ModelDiscovery.scan(roots: roots, managedDirectory: ModelDiscovery.managedDirectory)
                for model in report.models {
                    print("\(model.name) | \(model.formatLabel) | \(model.languageLabel) | \(model.sizeLabel) | \(model.source) | \(model.url.path)")
                }
                for model in report.incompatible {
                    print("Other format | \(model.name) | \(model.format) | \(model.source) | \(model.url.path)")
                    if let reason = model.reason { print("  Reason: \(reason)") }
                }
                print("\(report.models.count) compatible models; \(report.incompatible.count) other formats; \(report.searchedFolders) folders searched.")
                for warning in report.warnings { print("Warning: \(warning)") }
            case "inspect":
                guard arguments.count == 2 else { throw UsageError() }
                let model = try ModelFileInspector.inspect(
                    URL(fileURLWithPath: arguments[1]), source: "Specified model", managedDirectory: ModelDiscovery.managedDirectory
                )
                print("\(model.name) | \(model.formatLabel) | \(model.languageLabel) | \(model.sizeLabel)")
            case "transcribe":
                guard arguments.count >= 3 else { throw UsageError() }
                let model = try ModelFileInspector.inspect(
                    URL(fileURLWithPath: arguments[1]), source: "Specified model", managedDirectory: ModelDiscovery.managedDirectory
                )
                let samples = try AudioFileReader.read(URL(fileURLWithPath: arguments[2]))
                let engine = NativeTranscriber(useGPU: !arguments.contains("--cpu"))
                let text = try await engine.transcribe(samples: samples, model: model)
                print(text)
                await engine.shutdown()
            case "install":
                guard arguments.count == 3, let preset = ModelPreset.all.first(where: { $0.id == arguments[1] }) else {
                    throw UsageError()
                }
                let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
                let report = try ModelDiscovery.scan(
                    roots: [DiscoveryRoot(url: directory, label: "Destination")], managedDirectory: directory
                )
                if let existing = report.models.first(where: { $0.canReplace(preset) }) {
                    print("Reusing \(existing.url.path)")
                } else {
                    let model = try await ModelInstaller.install(preset, directory: directory)
                    print("Installed and verified \(model.url.path)")
                }
            default:
                throw UsageError()
            }
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        bigvoice-check scan [folder ...]
        bigvoice-check inspect <model.bin | onnx-model-folder>
        bigvoice-check transcribe <model.bin | onnx-model-folder> <audio.wav> [--cpu]
        bigvoice-check install <tiny-en|base-en|tiny-multilingual|base-multilingual|small-en> <directory>
        """)
    }

    struct UsageError: LocalizedError {
        var errorDescription: String? { "Invalid arguments. Run bigvoice-check without arguments for usage." }
    }
}
