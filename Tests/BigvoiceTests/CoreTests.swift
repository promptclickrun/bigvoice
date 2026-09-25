import BigvoiceCore
import Foundation

let coreTests: [RegressionTest] = [
    RegressionTest(name: "Quick push-to-talk release never starts recording later") {
        var lifecycle = CaptureLifecycle()
        try expect(lifecycle.begin(.pushToTalk))
        try expect(!lifecycle.requestStop(pushToTalkRelease: true))
        try expect(lifecycle.stopRequested)
        try expect(!lifecycle.didArm())
        try expect(lifecycle.phase == .idle)
    },
    RegressionTest(name: "Push-to-talk release does not stop hands-free") {
        var lifecycle = CaptureLifecycle()
        try expect(lifecycle.begin(.handsFree))
        try expect(!lifecycle.requestStop(pushToTalkRelease: true))
        try expect(lifecycle.didArm())
        try expect(!lifecycle.requestStop(pushToTalkRelease: true))
        try expect(lifecycle.phase == .recording(.handsFree))
        try expect(lifecycle.requestStop())
        try expect(lifecycle.phase == .transcribing)
    },
    RegressionTest(name: "Duplicate begin and stop are ignored") {
        var lifecycle = CaptureLifecycle()
        try expect(lifecycle.begin(.pushToTalk))
        try expect(!lifecycle.begin(.handsFree))
        try expect(lifecycle.didArm())
        try expect(lifecycle.requestStop())
        try expect(!lifecycle.requestStop())
        try expect(!lifecycle.begin(.handsFree))
        lifecycle.willInsert()
        try expect(lifecycle.phase == .inserting)
        lifecycle.reset()
        try expect(lifecycle.phase == .idle)
    },
    RegressionTest(name: "Cancellation cannot resurrect an arming session") {
        var lifecycle = CaptureLifecycle()
        _ = lifecycle.begin(.handsFree)
        lifecycle.reset()
        try expect(!lifecycle.didArm())
        try expect(lifecycle.phase == .idle)
    },
    RegressionTest(name: "Hands-free stop during arming is deferred safely") {
        var lifecycle = CaptureLifecycle()
        try expect(lifecycle.begin(.handsFree))
        try expect(!lifecycle.requestStop())
        try expect(!lifecycle.didArm())
        try expect(lifecycle.phase == .idle)
    },
    RegressionTest(name: "Safe defaults survive preference round trip") {
        let preferences = Preferences()
        try expect(!preferences.autoSend)
        try expect(preferences.restoreClipboard)
        try expect(preferences.selectedModelPath == nil)
        try preferences.validateShortcuts()
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        try expect(decoded == preferences)
    },
    RegressionTest(name: "Shortcut validation uses physical bindings not display names") {
        var preferences = Preferences()
        preferences.pushToTalk = KeyShortcut(keyCode: 49, modifiers: .shift, keyLabel: "Space")
        try expectThrows { try preferences.validateShortcuts() }
        preferences.pushToTalk = .pushToTalk
        preferences.handsFree = KeyShortcut(keyCode: 49, modifiers: [.option, .control], keyLabel: "Different label")
        try expectThrows { try preferences.validateShortcuts() }
        try expect(!KeyShortcut(keyCode: 53, modifiers: .control, keyLabel: "Escape").isValid)
        try expect(!KeyShortcut(keyCode: 0, modifiers: ShortcutModifiers(rawValue: 128), keyLabel: "A").isValid)
    },
    RegressionTest(name: "Silence invalid samples and brief clicks are not speech") {
        try expect(!AudioAnalysis.hasAudibleContent(Array(repeating: 0, count: 32_000)))
        try expect(AudioAnalysis.meter(rms: .nan) == 0)
        try expect(AudioAnalysis.meter(rms: .infinity) == 0)
        try expect(AudioAnalysis.rms([.nan, .infinity]) == 0)
        try expect(!AudioAnalysis.hasAudibleContent(Array(repeating: 0.2, count: 100)))
        try expect(AudioAnalysis.hasAudibleContent(Array(repeating: 0.1, count: 16_000)))
        try expect(AudioAnalysis.maximumSamples == 9_600_000)
    },
    RegressionTest(name: "Audio level meter is bounded and reflects amplitude") {
        try expect(AudioAnalysis.meter(rms: 0) == 0)
        try expect(AudioAnalysis.meter(rms: 1) == 1)
        try expect(AudioAnalysis.meter(rms: 0.2) > AudioAnalysis.meter(rms: 0.01))
        try expect(abs(AudioAnalysis.rms([0.5, -0.5]) - 0.5) < 0.00001)
    },
    RegressionTest(name: "Focus and secure input gate text delivery") {
        try expect(DeliverySafety.mayDeliver(originalPID: 42, currentPID: 42, originalElementPresent: true,
                                             focusedElementMatches: true, secureInput: false))
        try expect(!DeliverySafety.mayDeliver(originalPID: 42, currentPID: 43, originalElementPresent: false,
                                              focusedElementMatches: true, secureInput: false))
        try expect(!DeliverySafety.mayDeliver(originalPID: 42, currentPID: 42, originalElementPresent: true,
                                              focusedElementMatches: false, secureInput: false))
        try expect(!DeliverySafety.mayDeliver(originalPID: 42, currentPID: 42, originalElementPresent: false,
                                              focusedElementMatches: true, secureInput: true))
    },
    RegressionTest(name: "Sending requires verified insertion unchanged focus and no cancellation") {
        try expect(DeliverySafety.maySend(autoSend: true, insertionConfirmed: true, focusStillMatches: true, cancelled: false))
        try expect(!DeliverySafety.maySend(autoSend: true, insertionConfirmed: false, focusStillMatches: true, cancelled: false))
        try expect(!DeliverySafety.maySend(autoSend: true, insertionConfirmed: true, focusStillMatches: false, cancelled: false))
        try expect(!DeliverySafety.maySend(autoSend: true, insertionConfirmed: true, focusStillMatches: true, cancelled: true))
        try expect(!DeliverySafety.maySend(autoSend: false, insertionConfirmed: true, focusStillMatches: true, cancelled: false))
    },
    RegressionTest(name: "Insertion confirmation handles UTF-16 selections and invalid ranges") {
        let replacement = DeliverySafety.expectedValue(original: "Hi 🌎!", selection: NSRange(location: 3, length: 2), inserting: "world")
        try expect(replacement == "Hi world!")
        try expect(DeliverySafety.expectedValue(original: "abc", selection: NSRange(location: 3, length: 0), inserting: "d") == "abcd")
        try expect(DeliverySafety.expectedValue(original: "abc", selection: NSRange(location: NSNotFound, length: 0), inserting: "x") == nil)
        try expect(DeliverySafety.expectedValue(original: "abc", selection: NSRange(location: 2, length: Int.max), inserting: "x") == nil)
        try expect(DeliverySafety.expectedValue(original: "abc", selection: NSRange(location: -1, length: 1), inserting: "x") == nil)
        try expect(DeliverySafety.expectedValue(original: "abc", selection: nil, inserting: "x") == nil)
    },
    RegressionTest(name: "Clipboard restoration never overwrites a newer user copy") {
        try expect(DeliverySafety.shouldRestoreClipboard(ownedChangeCount: 5, currentChangeCount: 5))
        try expect(!DeliverySafety.shouldRestoreClipboard(ownedChangeCount: 5, currentChangeCount: 6))
    },
    RegressionTest(name: "Catalog uses small pinned HTTPS models and complete SHA-256 digests") {
        try expect(ModelPreset.all.count == 5)
        try expect(Set(ModelPreset.all.map(\.id)).count == ModelPreset.all.count)
        for model in ModelPreset.all {
            try expect(model.downloadURL.scheme == "https")
            try expect(model.downloadURL.path.contains(ModelPreset.revision))
            try expect(model.sha256.count == 64)
            try expect(model.sha256.allSatisfy(\.isHexDigit))
            try expect(model.bytes < 200_000_000)
        }
    }
]
