import Foundation

struct IndexedModels {
    let files: [URL]
    let warning: String?
}

@MainActor
final class SpotlightModelSearch {
    private let query = NSMetadataQuery()
    private var observer: NSObjectProtocol?
    private var timeout: Task<Void, Never>?
    private var continuation: CheckedContinuation<IndexedModels, Never>?

    func search() async -> IndexedModels {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                query.searchScopes = [NSMetadataQueryLocalComputerScope]
                query.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
                    NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "ggml-*.bin"),
                    NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*whisper*.bin")
                ])
                query.notificationBatchingInterval = 0.1
                observer = NotificationCenter.default.addObserver(
                    forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.finish(timedOut: false) }
                }
                guard query.start() else {
                    finish(warning: "The system file index could not be searched. Common model folders were still checked.")
                    return
                }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(3)) }
                    catch { return }
                    self?.finish(timedOut: true)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(warning: nil) }
        }
    }

    private func finish(timedOut: Bool) {
        var files: [URL] = []
        query.disableUpdates()
        let count = min(query.resultCount, 250)
        for index in 0..<count {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            files.append(URL(fileURLWithPath: path))
        }
        let warning: String?
        if query.resultCount > 250 {
            warning = "The system index found more than 250 candidates. Add a specific folder to search additional models."
        } else if timedOut {
            warning = "The system file index did not finish in time. Common folders and available indexed results were still checked."
        } else { warning = nil }
        finish(warning: warning, files: files)
    }

    private func finish(warning: String?, files: [URL] = []) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        query.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        continuation.resume(returning: IndexedModels(files: files, warning: warning))
    }
}
