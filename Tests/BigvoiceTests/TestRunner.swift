import Foundation

struct TestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct TestSkip: Error {
    let reason: String
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String = "Expectation failed",
            file: String = #fileID, line: Int = #line) throws {
    guard try condition() else { throw TestFailure(message: "\(file):\(line): \(message)") }
}

func expectThrows(_ operation: () throws -> Void, file: String = #fileID, line: Int = #line) throws {
    do { try operation() }
    catch { return }
    throw TestFailure(message: "\(file):\(line): Expected an error")
}

struct RegressionTest {
    let name: String
    let run: () async throws -> Void
}

@main
struct TestRunner {
    static func main() async {
        let filter = CommandLine.arguments.dropFirst().first
        let tests = (coreTests + modelTests + runtimeTests).filter {
            filter == nil || $0.name.localizedCaseInsensitiveContains(filter!)
        }
        guard !tests.isEmpty else {
            print("No tests matched.")
            exit(1)
        }
        var failures = 0
        var skipped = 0
        for test in tests {
            do {
                try await test.run()
                print("PASS \(test.name)")
            } catch let skip as TestSkip {
                skipped += 1
                print("SKIP \(test.name): \(skip.reason)")
            } catch {
                failures += 1
                print("FAIL \(test.name): \(error.localizedDescription)")
            }
        }
        print("\n\(tests.count - failures - skipped) passed, \(skipped) skipped, \(failures) failed.")
        if failures > 0 { exit(1) }
    }
}

func withTemporaryDirectory(_ operation: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bigvoice-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
        try operation(directory)
        try FileManager.default.removeItem(at: directory)
    } catch {
        do { try FileManager.default.removeItem(at: directory) }
        catch { FileHandle.standardError.write(Data("Test cleanup failed: \(error.localizedDescription)\n".utf8)) }
        throw error
    }
}
