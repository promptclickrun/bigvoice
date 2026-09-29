import AppKit
import BigvoiceCore
import BigvoiceRuntime
import Darwin

@main
@MainActor
struct BigvoiceMain {
    static func main() {
        // Opt out of ONNX Runtime telemetry before any thread exists or the runtime can initialize.
        setenv("ORT_DISABLE_TELEMETRY", "1", 1)
        if CommandLine.arguments.contains("--version") {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
            print("bigvoice \(version)")
            return
        }
        let application = NSApplication.shared
        // Diagnostic: transcribe a file with the app's own bundled engines, fully offline.
        if let index = CommandLine.arguments.firstIndex(of: "--transcribe"), CommandLine.arguments.count > index + 2 {
            let model = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let audio = URL(fileURLWithPath: CommandLine.arguments[index + 2])
            runHeadless(application) {
                let local = try ModelFileInspector.inspect(model, source: "Command line", managedDirectory: ModelDiscovery.managedDirectory)
                let engine = NativeTranscriber()
                let text = try await engine.transcribe(samples: try AudioFileReader.read(audio), model: local)
                print(text)
                await engine.shutdown()
            }
            return
        }
        // Diagnostic: run text through the Style pipeline with the app's own engines, fully on this Mac.
        // Example: bigvoice --polish "um so the the build is green" --level refined --tone casual --context messages
        if let index = CommandLine.arguments.firstIndex(of: "--polish"), CommandLine.arguments.count > index + 1 {
            let text = CommandLine.arguments[index + 1]
            func option(_ name: String) -> String? {
                CommandLine.arguments.firstIndex(of: name).flatMap {
                    CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil
                }
            }
            var style = StylePreferences()
            if let level = option("--level").flatMap(PolishLevel.init(rawValue:)) { style.level = level }
            let context = option("--context").flatMap(WritingContext.init(rawValue:)) ?? .other
            if let tone = option("--tone").flatMap(WritingTone.init(rawValue:)) { style.setTone(tone, for: context) }
            runHeadless(application) {
                let outcome = try await TextPolisher().polish(text, style: style, context: context, appName: nil,
                                                              language: "auto", budget: .seconds(20))
                let engine = outcome.engine.map { " · \($0.label)" } ?? ""
                let note = outcome.note.map { " · \($0)" } ?? ""
                print("\(outcome.summary)\(engine) · \(outcome.milliseconds) ms\(note)")
                print(outcome.text)
            }
            return
        }
        #if DEBUG
        if CommandLine.arguments.contains("--check-native") {
            runHeadless(application) { try await NativeSmokeChecks.run() }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-previews"),
           CommandLine.arguments.indices.contains(index + 1) {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            runHeadless(application) { try await PreviewExporter.run(directory: directory) }
            return
        }
        #endif
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }

    private static func runHeadless(_ application: NSApplication, _ work: @escaping @MainActor () async throws -> Void) {
        application.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await work()
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        application.run()
    }
}
