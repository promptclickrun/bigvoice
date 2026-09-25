import BigvoiceCore
import CryptoKit
import Foundation

public enum InstallationError: LocalizedError {
    case httpStatus(Int), sizeMismatch, checksumMismatch, insufficientSpace, destinationExists

    public var errorDescription: String? {
        switch self {
        case let .httpStatus(status): return "The model server returned HTTP \(status). Check your connection and try again."
        case .sizeMismatch: return "The download is incomplete or has an unexpected size. No model was installed."
        case .checksumMismatch: return "The model's SHA-256 checksum did not match. The download was discarded."
        case .insufficientSpace: return "There is not enough free disk space for this model. Reuse a local model or free some space."
        case .destinationExists: return "A file already exists at this model's location. Rescan or choose that file before downloading another copy."
        }
    }
}

public struct DownloadProgress: Sendable {
    public let received: Int64
    public let expected: Int64
    public var fraction: Double {
        guard expected > 0 else { return 0 }
        return min(1, max(0, Double(received) / Double(expected)))
    }
}

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (DownloadProgress) -> Void
    let expectedBytes: Int64
    private let lock = NSLock()
    private var oversized = false
    var exceededExpectedSize: Bool { lock.withLock { oversized } }

    init(expectedBytes: Int64, progress: @escaping @Sendable (DownloadProgress) -> Void) {
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > expectedBytes {
            lock.withLock { oversized = true }
            downloadTask.cancel()
            return
        }
        progress(DownloadProgress(received: totalBytesWritten, expected: expectedBytes))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

public enum ModelInstaller {
    public static func verify(_ file: URL, expectedBytes: Int64, sha256: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == expectedBytes else { throw InstallationError.sizeMismatch }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == sha256.lowercased() else { throw InstallationError.checksumMismatch }
    }

    public static func install(
        _ preset: ModelPreset, directory: URL,
        progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in },
        verifying: @escaping @Sendable () -> Void = {}
    ) async throws -> LocalModel {
        try Task.checkCancellation()
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(preset.filename)
        guard !manager.fileExists(atPath: destination.path) else { throw InstallationError.destinationExists }
        let resources = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = resources.volumeAvailableCapacityForImportantUsage,
           capacity < preset.bytes + 32_000_000 { throw InstallationError.insufficientSpace }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 30
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let delegate = ModelDownloadDelegate(expectedBytes: preset.bytes, progress: progress)
        let temporaryFile: URL
        let response: URLResponse
        do {
            (temporaryFile, response) = try await session.download(from: preset.downloadURL, delegate: delegate)
        } catch {
            if delegate.exceededExpectedSize { throw InstallationError.sizeMismatch }
            throw error
        }
        defer {
            if manager.fileExists(atPath: temporaryFile.path) { try? manager.removeItem(at: temporaryFile) }
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw InstallationError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        verifying()
        try verify(temporaryFile, expectedBytes: preset.bytes, sha256: preset.sha256)
        try Task.checkCancellation()
        _ = try ModelFileInspector.inspect(temporaryFile, source: "bigvoice", managedDirectory: directory)

        // Stage on the destination volume before an atomic rename; never expose a partial .bin.
        let staging = directory.appendingPathComponent(".\(UUID().uuidString).download")
        defer {
            if manager.fileExists(atPath: staging.path) { try? manager.removeItem(at: staging) }
        }
        try manager.moveItem(at: temporaryFile, to: staging)
        try Task.checkCancellation()
        guard !manager.fileExists(atPath: destination.path) else { throw InstallationError.destinationExists }
        try manager.moveItem(at: staging, to: destination)
        return try ModelFileInspector.inspect(destination, source: "bigvoice", managedDirectory: directory)
    }
}
