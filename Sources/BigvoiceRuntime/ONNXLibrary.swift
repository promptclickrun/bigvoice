import Darwin
import Foundation

public enum ONNXInferenceError: LocalizedError {
    case unavailable, unsupportedHardware, privacySetup, missingSymbol(String)
    case runtime(String), invalidAudio, decoderLimit

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The native ONNX runtime is missing. Use the complete bigvoice app, or run python3 scripts/bootstrap-onnx.py for a development build."
        case .unsupportedHardware:
            return "This ONNX speech backend requires Apple Silicon. Whisper GGML models remain available on Intel Macs."
        case .privacySetup:
            return "ONNX telemetry could not be disabled. The runtime was not started."
        case let .missingSymbol(name):
            return "The installed ONNX runtime is incompatible (missing \(name)). Reinstall the complete bigvoice app."
        case let .runtime(message):
            return "ONNX speech failed: \(message)"
        case .invalidAudio:
            return "The recording is invalid or exceeds the ten-minute limit."
        case .decoderLimit:
            return "The ONNX decoder exceeded its safety limit. Try a shorter recording or another model."
        }
    }
}

// Signatures are pinned to ONNX Runtime GenAI v0.16.0's MIT-licensed ort_genai_c.h.
final class ONNXLibrary {
    typealias CreatePath = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<OpaquePointer?>) -> OpaquePointer?
    typealias CreateObject = @convention(c) (OpaquePointer, UnsafeMutablePointer<OpaquePointer?>) -> OpaquePointer?
    typealias Destroy = @convention(c) (OpaquePointer) -> Void
    typealias SetOption = @convention(c) (OpaquePointer, UnsafePointer<CChar>, UnsafePointer<CChar>) -> OpaquePointer?
    typealias SetInputs = @convention(c) (OpaquePointer, OpaquePointer) -> OpaquePointer?
    typealias Generate = @convention(c) (OpaquePointer) -> OpaquePointer?
    typealias IsDone = @convention(c) (OpaquePointer) -> Bool
    typealias GetTokens = @convention(c) (OpaquePointer, UnsafeMutablePointer<UnsafePointer<Int32>?>, UnsafeMutablePointer<Int>) -> OpaquePointer?
    typealias DecodeToken = @convention(c) (OpaquePointer, Int32, UnsafeMutablePointer<UnsafePointer<CChar>?>) -> OpaquePointer?
    typealias ProcessAudio = @convention(c) (OpaquePointer, UnsafePointer<Float>, Int, UnsafeMutablePointer<OpaquePointer?>) -> OpaquePointer?
    typealias CreateGenerator = @convention(c) (OpaquePointer, OpaquePointer, UnsafeMutablePointer<OpaquePointer?>) -> OpaquePointer?
    typealias SetTelemetry = @convention(c) (Bool) -> Void
    typealias SetLog = @convention(c) (UnsafePointer<CChar>, Bool) -> OpaquePointer?
    typealias Shutdown = @convention(c) () -> Void
    typealias GetError = @convention(c) (OpaquePointer) -> UnsafePointer<CChar>?

    let directory: URL
    private let handle: UnsafeMutableRawPointer
    let createConfig: CreatePath
    let destroyConfig: Destroy
    let createModel: CreateObject
    let destroyModel: Destroy
    let createProcessor: CreateObject
    let destroyProcessor: Destroy
    let setProcessorOption: SetOption
    let processAudio: ProcessAudio
    let flushAudio: CreateObject
    let destroyInputs: Destroy
    let createTokenizer: CreateObject
    let destroyTokenizer: Destroy
    let createTokenizerStream: CreateObject
    let destroyTokenizerStream: Destroy
    let createParams: CreateObject
    let destroyParams: Destroy
    let createGenerator: CreateGenerator
    let destroyGenerator: Destroy
    let setInputs: SetInputs
    let generate: Generate
    let isDone: IsDone
    let getTokens: GetTokens
    let decodeToken: DecodeToken
    let shutdown: Shutdown
    private let setTelemetry: SetTelemetry
    private let setLog: SetLog
    private let getError: GetError
    private let destroyError: Destroy

    init() throws {
        #if !arch(arm64)
        throw ONNXInferenceError.unsupportedHardware
        #else
        guard setenv("ORT_DISABLE_TELEMETRY", "1", 1) == 0 else { throw ONNXInferenceError.privacySetup }
        guard let directory = Self.runtimeDirectory() else { throw ONNXInferenceError.unavailable }
        let path = directory.appendingPathComponent("libonnxruntime-genai.dylib").path
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw ONNXInferenceError.runtime(dlerror().map { String(cString: $0) } ?? "The native library could not be loaded.")
        }
        self.directory = directory
        self.handle = handle
        func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let address = dlsym(handle, name) else { throw ONNXInferenceError.missingSymbol(name) }
            return unsafeBitCast(address, to: type)
        }
        do {
            createConfig = try symbol("OgaCreateConfig", CreatePath.self)
            destroyConfig = try symbol("OgaDestroyConfig", Destroy.self)
            createModel = try symbol("OgaCreateModelFromConfig", CreateObject.self)
            destroyModel = try symbol("OgaDestroyModel", Destroy.self)
            createProcessor = try symbol("OgaCreateStreamingProcessor", CreateObject.self)
            destroyProcessor = try symbol("OgaDestroyStreamingProcessor", Destroy.self)
            setProcessorOption = try symbol("OgaStreamingProcessorSetOption", SetOption.self)
            processAudio = try symbol("OgaStreamingProcessorProcess", ProcessAudio.self)
            flushAudio = try symbol("OgaStreamingProcessorFlush", CreateObject.self)
            destroyInputs = try symbol("OgaDestroyNamedTensors", Destroy.self)
            createTokenizer = try symbol("OgaCreateTokenizer", CreateObject.self)
            destroyTokenizer = try symbol("OgaDestroyTokenizer", Destroy.self)
            createTokenizerStream = try symbol("OgaCreateTokenizerStream", CreateObject.self)
            destroyTokenizerStream = try symbol("OgaDestroyTokenizerStream", Destroy.self)
            createParams = try symbol("OgaCreateGeneratorParams", CreateObject.self)
            destroyParams = try symbol("OgaDestroyGeneratorParams", Destroy.self)
            createGenerator = try symbol("OgaCreateGenerator", CreateGenerator.self)
            destroyGenerator = try symbol("OgaDestroyGenerator", Destroy.self)
            setInputs = try symbol("OgaGenerator_SetInputs", SetInputs.self)
            generate = try symbol("OgaGenerator_GenerateNextToken", Generate.self)
            isDone = try symbol("OgaGenerator_IsDone", IsDone.self)
            getTokens = try symbol("OgaGenerator_GetNextTokens", GetTokens.self)
            decodeToken = try symbol("OgaTokenizerStreamDecode", DecodeToken.self)
            shutdown = try symbol("OgaShutdown", Shutdown.self)
            setTelemetry = try symbol("OgaSetTelemetryEnabled", SetTelemetry.self)
            setLog = try symbol("OgaSetLogBool", SetLog.self)
            getError = try symbol("OgaResultGetError", GetError.self)
            destroyError = try symbol("OgaDestroyResult", Destroy.self)
        } catch {
            if let address = dlsym(handle, "OgaShutdown") {
                unsafeBitCast(address, to: Shutdown.self)()
            }
            dlclose(handle)
            throw error
        }
        #endif
    }

    func configurePrivacy() throws {
        guard getenv("ORT_DISABLE_TELEMETRY").map({ String(cString: $0) }) == "1" else {
            throw ONNXInferenceError.privacySetup
        }
        setTelemetry(false)
        try check(setLog("enabled", false))
    }

    func check(_ result: OpaquePointer?) throws {
        guard let result else { return }
        defer { destroyError(result) }
        let message = getError(result).map { String(cString: $0) } ?? "The runtime returned an unspecified error."
        throw ONNXInferenceError.runtime(message)
    }

    func create(_ function: CreateObject, from object: OpaquePointer) throws -> OpaquePointer {
        var result: OpaquePointer?
        try check(function(object, &result))
        guard let result else { throw ONNXInferenceError.runtime("The runtime returned no object.") }
        return result
    }

    private static func runtimeDirectory() -> URL? {
        let manager = FileManager.default
        func available(_ url: URL) -> Bool {
            manager.isReadableFile(atPath: url.appendingPathComponent("libonnxruntime-genai.dylib").path) &&
                manager.isReadableFile(atPath: url.appendingPathComponent("libonnxruntime.dylib").path)
        }
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let frameworks = Bundle.main.privateFrameworksURL, available(frameworks) else { return nil }
            return frameworks
        }
        if var directory = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
            for _ in 0..<6 {
                if directory.lastPathComponent == ".build" {
                    let runtime = directory.appendingPathComponent("onnx-runtime")
                    if available(runtime) { return runtime }
                }
                directory.deleteLastPathComponent()
            }
        }
        let development = URL(fileURLWithPath: manager.currentDirectoryPath).appendingPathComponent(".build/onnx-runtime")
        return available(development) ? development : nil
    }
}
