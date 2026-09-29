import AppKit
import AVFoundation
import BigvoiceCore
import BigvoiceRuntime
import Combine
import Foundation
import OSLog
import ServiceManagement

enum AppPage: String, CaseIterable, Identifiable {
    case dictation = "Dictation", style = "Style", models = "Models", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .dictation: return "waveform"
        case .style: return "text.alignleft"
        case .models: return "square.stack.3d.up"
        case .settings: return "slider.horizontal.3"
        }
    }
}

extension PolishOutcome {
    /// One line for the capsule and the delivered moment: what was applied, and whether polish stepped back.
    var deliveredDetail: String {
        if requested.usesLanguageModel && applied == .clean { return "Clean · polish skipped" }
        return summary
    }
}

struct AppNotice: Identifiable, Equatable {
    enum Kind { case info, warning, error }
    /// Dictation notices also surface in the floating overlay; app notices stay in the window.
    enum Origin { case app, dictation }
    let id = UUID()
    let title: String
    let detail: String
    let kind: Kind
    var origin: Origin = .app

    static func == (lhs: AppNotice, rhs: AppNotice) -> Bool { lhs.id == rhs.id }
}

enum AudioCue {
    case start, stop
    var soundName: String { self == .start ? "Tink" : "Pop" }
}

struct InstallationProgress {
    let id = UUID()
    let presetID: String
    var fraction: Double
    var stage: String
}

struct Delivery: Equatable {
    let id = UUID()
    let title: String
    let detail: String
    let instruction: String
    static func == (lhs: Delivery, rhs: Delivery) -> Bool { lhs.id == rhs.id }
}

@MainActor
final class AppController: ObservableObject {
    let preferences: PreferencesStore
    let devices: AudioDevices
    let hotkeys = HotkeyManager()
    let meter = LevelMeter()
    private let capture = AudioCapture()
    private let transcriber = NativeTranscriber()
    let polisher = TextPolisher()
    let stylePreview = StylePreview()
    private let delivery = TextDelivery()
    private var lifecycle = CaptureLifecycle()
    private var sessionID = UUID()
    private var sessionTask: Task<Void, Never>?
    private var warmUpTask: Task<Void, Never>?
    private var installationTask: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?
    private var meterTimer: Timer?
    private var idleUnloadTask: Task<Void, Never>?
    private var destination: DictationDestination?
    private var mode: DictationMode = .handsFree
    private var sessionPreferences = Preferences()
    private var sessionContext: WritingContext = .other
    private var sessionAppName: String?
    private var sessionWarning: String?
    private var cancellables = Set<AnyCancellable>()
    private var retainedSound: NSSound?
    private var isShuttingDown = false
    private var accessibilityObserver: NSObjectProtocol?

    @Published var page: AppPage = .dictation
    @Published var notice: AppNotice?
    @Published private(set) var phase: DictationPhase = .idle
    @Published private(set) var sessionMode: DictationMode?
    @Published private(set) var models: [LocalModel] = []
    @Published private(set) var incompatibleModels: [IncompatibleModel] = []
    @Published private(set) var scanWarnings: [String] = []
    @Published private(set) var searchedFolders = 0
    @Published private(set) var isScanning = false
    @Published private(set) var installation: InstallationProgress?
    @Published private(set) var preparingModelID: String?
    @Published private(set) var readyModelPath: String?
    @Published private(set) var microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var shortcutError: String?
    @Published private(set) var lastTranscript = ""
    @Published private(set) var lastTranscriptDate: Date?
    @Published private(set) var lastDelivery = ""
    @Published var isRecordingShortcut = false
    @Published private(set) var loginEnabled = SMAppService.mainApp.status == .enabled
    /// Increments when a model becomes ready through a user action, driving the activation bloom.
    @Published private(set) var activationPulse = 0
    /// Words recognized so far in the current session; replaced by the final transcript.
    @Published private(set) var liveTranscript = ""

    /// The style the current dictation is being written in, for the capsule and stage.
    var sessionStyleLabel: String {
        let style = sessionPreferences.style
        return "\(style.tone(for: sessionContext).title) · on your Mac"
    }
    /// A brief "delivered" moment after words land: the mark closes into a check.
    @Published private(set) var delivered: Delivery?
    /// True while a local writing model turns the transcript into finished text.
    @Published private(set) var polishing = false
    /// What the speech model heard, before any cleaning, for the Heard view.
    @Published private(set) var lastHeard = ""
    @Published private(set) var lastOutcome: PolishOutcome?
    @Published private(set) var writingStatus = WritingEngineStatus(appleIntelligence: TextPolisher.appleIntelligenceState,
                                                                   ollama: OllamaState())
    private var liveTask: Task<Void, Never>?
    private var deliveredTask: Task<Void, Never>?
    private var streamActive = false
    private var streamedCount = 0
    var onStateChange: (() -> Void)?
    var onShowWindow: (() -> Void)?

    init(preferences: PreferencesStore? = nil, devices: AudioDevices? = nil) {
        self.preferences = preferences ?? PreferencesStore()
        self.devices = devices ?? AudioDevices()
        self.preferences.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        self.devices.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        hotkeys.onAction = { [weak self] action in
            guard let self, !self.isRecordingShortcut else { return }
            switch action {
            case .pushDown: self.start(.pushToTalk)
            case .pushUp: self.stop(pushToTalkRelease: true)
            case .toggleHandsFree: self.toggleHandsFree()
            case .cancel: self.cancel()
            }
        }
        capture.onInterrupted = { [weak self] message in
            self?.sessionWarning = message
            self?.stop()
        }
        delivery.onWarning = { [weak self] message in
            self?.notice = AppNotice(title: "Clipboard needs attention", detail: message, kind: .warning)
        }
        stylePreview.polish = { [weak self] text, style, context in
            guard let self else { throw CancellationError() }
            return try await self.previewPolish(text, style: style, context: context)
        }
    }

    var selectedModel: LocalModel? {
        models.first { $0.url.path == preferences.value.selectedModelPath }
    }
    var busy: Bool { phase.isBusy }
    var canChangeModel: Bool { !busy && installation == nil && preparingModelID == nil }
    var ownedBytes: Int64 { models.filter(\.isManaged).reduce(0) { $0 + $1.bytes } }
    var reusedBytes: Int64 { models.filter { !$0.isManaged }.reduce(0) { $0 + $1.bytes } }
    var isReady: Bool { selectedModel != nil && microphoneGranted && accessibilityGranted }
    var isDelivered: Bool { phase == .idle && delivered != nil }

    /// The one state the sidebar mark, menu bar glyph, stage, and capsule all follow.
    var markState: MarkState {
        switch phase {
        case .idle: return delivered != nil ? .check : .idle
        case .arming: return .dots
        case .recording: return .listen
        case .transcribing: return .wave
        case .inserting: return .caret
        }
    }

    var stageTitle: String {
        if isDelivered { return "Done. Your words are in place." }
        switch phase {
        case .idle:
            if selectedModel == nil { return isScanning ? "Listening for voices on this Mac." : "A small model. A big voice." }
            if !microphoneGranted || !accessibilityGranted { return "A little setup. Then just speak." }
            return "Your voice, right where you need it."
        case .arming: return "Getting ready to listen"
        case .recording: return "Go ahead. You're being heard."
        case .transcribing: return polishing ? "Polishing your words" : "Turning your voice into words"
        case .inserting: return "Putting your words in place"
        }
    }

    var statusLabel: String {
        if isDelivered { return "Delivered" }
        switch phase {
        case .idle: return isReady ? "Ready when you are" : "A little setup first"
        case .arming, .recording: return "Listening on this Mac"
        case .transcribing, .inserting: return "Working locally"
        }
    }

    var modeTag: String {
        let preferences = preferences.value
        if busy {
            switch sessionMode {
            case .practice: return "PRACTICE · NOTHING IS PASTED"
            case .pushToTalk: return "PUSH TO TALK · " + preferences.pushToTalk.parts.joined(separator: " ").uppercased()
            case .handsFree: return "HANDS-FREE · " + preferences.handsFree.parts.joined(separator: " ").uppercased()
            case nil: break
            }
        }
        guard let model = selectedModel else { return "NO MODEL YET" }
        return "\(model.displayName.uppercased()) · OFFLINE"
    }

    func launch() {
        configureShortcuts()
        Task { await rescan() }
        refreshWritingStatus()
        if let error = preferences.error {
            notice = AppNotice(title: "Preferences were reset", detail: error, kind: .warning)
        }
        // macOS posts this whenever any app's Accessibility trust changes; react at once instead of waiting to poll.
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                for delay in [0.2, 0.8, 2.0] {
                    try? await Task.sleep(for: .seconds(delay))
                    self?.refreshPermissions()
                }
            }
        }
    }

    func refreshPermissions() {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let accessibility = AXIsProcessTrusted()
        if microphoneGranted != microphone { microphoneGranted = microphone }
        if accessibilityGranted != accessibility { accessibilityGranted = accessibility }
        let login = SMAppService.mainApp.status == .enabled
        if loginEnabled != login { loginEnabled = login }
    }

    func requestMicrophone() {
        Task {
            microphoneGranted = await capture.requestPermission()
            if !microphoneGranted {
                notice = AppNotice(title: "Microphone access is off", detail: CaptureError.permissionDenied.localizedDescription, kind: .warning)
                openPrivacy("Privacy_Microphone")
            }
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        if !accessibilityGranted { openPrivacy("Privacy_Accessibility") }
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"),
           NSWorkspace.shared.open(url) { return }
        notice = AppNotice(title: "Open System Settings", detail: "Open Privacy & Security and allow bigvoice to access your microphone and Accessibility.", kind: .warning)
    }

    /// macOS binds Accessibility approval to a code signature. After a signature change (for example,
    /// replacing an ad-hoc build), System Settings still shows bigvoice switched on while macOS reports it
    /// untrusted. Clearing only bigvoice's own stale record lets a fresh approval attach to this build.
    func repairAccessibility() {
        guard let identifier = Bundle.main.bundleIdentifier else {
            notice = AppNotice(title: "Repair needs the installed app", detail: "Run bigvoice from Applications, then try again.", kind: .warning)
            return
        }
        Task {
            let status: Int32 = await Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                process.arguments = ["reset", "Accessibility", identifier]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    return process.terminationStatus
                } catch {
                    return -1
                }
            }.value
            if status == 0 {
                notice = AppNotice(title: "Old approval cleared",
                                   detail: "Switch bigvoice on in the Accessibility list. The approval now sticks across updates.", kind: .info)
                requestAccessibility()
            } else {
                notice = AppNotice(title: "Couldn't clear it automatically",
                                   detail: "In System Settings > Privacy & Security > Accessibility, select bigvoice, click −, then press Allow here again.",
                                   kind: .warning)
                openPrivacy("Privacy_Accessibility")
            }
        }
    }

    func configureShortcuts() {
        do {
            try hotkeys.configure(preferences.value)
            shortcutError = nil
        } catch {
            shortcutError = error.localizedDescription
        }
    }

    func updateShortcut(_ shortcut: KeyShortcut, pushToTalk: Bool) throws {
        var updated = preferences.value
        if pushToTalk { updated.pushToTalk = shortcut } else { updated.handsFree = shortcut }
        try updated.validateShortcuts()
        try hotkeys.configure(updated)
        preferences.value = updated
        shortcutError = nil
    }

    func setShortcutRecording(_ recording: Bool) {
        isRecordingShortcut = recording
        if recording { hotkeys.suspend() } else { configureShortcuts() }
    }

    func resetShortcuts() {
        var updated = preferences.value
        updated.pushToTalk = .pushToTalk
        updated.handsFree = .handsFree
        do {
            try hotkeys.configure(updated)
            preferences.value = updated
            shortcutError = nil
        } catch {
            shortcutError = error.localizedDescription
        }
    }

    func toggleHandsFree() {
        switch phase {
        case .idle: start(.handsFree)
        case .arming(.handsFree), .recording(.handsFree), .arming(.practice), .recording(.practice): stop()
        default: break
        }
    }

    func start(_ mode: DictationMode) {
        guard !busy, !isRecordingShortcut, !isShuttingDown else { return }
        guard installation == nil, preparingModelID == nil else {
            report("Model is being prepared", "Wait for the model operation to finish, then try again.", kind: .info)
            return
        }
        guard let model = selectedModel else {
            page = .models
            report("Choose a model first", "Reuse a model on this Mac or install a small one from the library.", kind: .warning)
            onShowWindow?()
            return
        }
        let target = mode == .practice ? nil : DictationDestination.capture()
        if mode != .practice && target == nil {
            report("Click a text field first", "Place the cursor in another app, then use your dictation shortcut. The practice button stays inside bigvoice.", kind: .info)
            return
        }
        refreshPermissions()
        guard mode == .practice || accessibilityGranted else {
            page = .dictation
            report("Allow Accessibility", "bigvoice needs Accessibility access to paste into other apps. Use the permission button in the main window.", kind: .warning)
            onShowWindow?()
            return
        }
        guard lifecycle.begin(mode) else { return }
        idleUnloadTask?.cancel()
        sessionID = UUID()
        let id = sessionID
        self.mode = mode
        sessionMode = mode
        destination = target
        sessionPreferences = preferences.value
        sessionContext = target?.context ?? .other
        sessionAppName = target?.name
        sessionWarning = nil
        meter.reset()
        notice = nil
        clearDelivered()
        liveTranscript = ""
        synchronizePhase()
        do { try hotkeys.enableCancel(true) }
        catch { shortcutError = error.localizedDescription }

        sessionTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard await self.capture.requestPermission() else { throw CaptureError.permissionDenied }
                self.refreshPermissions()
                try Task.checkCancellation()
                guard self.sessionID == id else { return }
                if self.lifecycle.stopRequested { self.finishEarlyRelease(); return }
                // Load weights while the microphone is live, so a cold model never delays speaking.
                self.warmUp(model, session: id)
                let style = self.sessionPreferences.style, context = self.sessionContext, appName = self.sessionAppName
                Task { [polisher = self.polisher] in await polisher.prewarm(style: style, context: context, appName: appName) }
                if self.sessionPreferences.startSound {
                    let wait = self.playSound(.start)
                    try await Task.sleep(for: .seconds(min(0.3, wait)))
                }
                try Task.checkCancellation()
                guard self.sessionID == id else { return }
                guard self.lifecycle.didArm() else { self.finishEarlyRelease(); return }
                let device = try self.devices.resolve(uid: self.sessionPreferences.inputDeviceUID)
                try self.capture.start(deviceID: device)
                self.meter.reset()
                self.synchronizePhase()
                self.startMeter()
                self.startLiveTranscription(model, session: id)
            } catch is CancellationError {
                if self.sessionID == id { self.finish() }
            } catch {
                guard self.sessionID == id else { return }
                self.finish()
                self.report("Couldn't start dictation", error.localizedDescription, kind: .error)
            }
        }
    }

    private func warmUp(_ model: LocalModel, session id: UUID) {
        warmUpTask?.cancel()
        warmUpTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transcriber.prepare(model: model)
                if self.selectedModel?.id == model.id { self.readyModelPath = model.url.path }
            } catch is CancellationError {
            } catch {
                // After the user stops, transcription reports the same failure; avoid a duplicate notice.
                guard self.sessionID == id, self.phase.isRecording || self.phase == .arming(self.mode) else { return }
                self.sessionID = UUID()
                self.sessionTask?.cancel()
                self.finish()
                self.report("This model couldn't be loaded", error.localizedDescription, kind: .error)
            }
        }
    }

    /// Words appear while you speak: Nemotron streams incrementally; Whisper re-transcribes the
    /// recording so far on a relaxed cadence. The final pass after stopping is always authoritative.
    private func startLiveTranscription(_ model: LocalModel, session id: UUID) {
        liveTask?.cancel()
        streamActive = false
        streamedCount = 0
        let language = sessionPreferences.language
        guard (try? NativeTranscriber.validate(language: language, for: model)) != nil else { return }
        liveTask = Task { [weak self] in
            guard let self else { return }
            if NativeTranscriber.supportsStreaming(model) {
                do {
                    try await self.transcriber.prepare(model: model)
                    guard self.sessionID == id, self.phase.isRecording, !Task.isCancelled else { return }
                    try await self.transcriber.beginStream(model: model)
                    guard self.sessionID == id, self.phase.isRecording, !Task.isCancelled else {
                        await self.transcriber.cancelStream()
                        return
                    }
                    self.streamActive = true
                    while !Task.isCancelled, self.sessionID == id, self.phase.isRecording {
                        let fresh = self.capture.samples(from: self.streamedCount)
                        if !fresh.isEmpty {
                            // Advance before awaiting so a concurrent stop never feeds these samples twice.
                            self.streamedCount += fresh.count
                            let text = try await self.transcriber.feedStream(fresh)
                            if self.sessionID == id, self.phase.isRecording {
                                self.liveTranscript = self.livePreview(text)
                            }
                        }
                        try await Task.sleep(for: .milliseconds(240))
                    }
                } catch is CancellationError {
                } catch {
                    self.streamActive = false
                    Logger.app.error("Live transcription stopped: \(error.localizedDescription)")
                }
            } else {
                var transcribedCount = 0
                var pause: Duration = .milliseconds(900)
                while !Task.isCancelled, self.sessionID == id, self.phase.isRecording {
                    try? await Task.sleep(for: pause)
                    guard !Task.isCancelled, self.sessionID == id, self.phase.isRecording else { break }
                    let count = self.capture.sampleCount
                    guard count - transcribedCount >= AudioAnalysis.sampleRate / 2 else { continue }
                    transcribedCount = count
                    let started = ContinuousClock.now
                    let text = try? await self.transcriber.transcribe(samples: self.capture.samples(from: 0), model: model, language: language)
                    let elapsed = ContinuousClock.now - started
                    pause = max(.milliseconds(900), elapsed * 1.5)
                    if let text, self.sessionID == id, self.phase.isRecording { self.liveTranscript = self.livePreview(text) }
                }
            }
        }
    }

    /// Live words are cleaned with the same rules as the final text (never a closing period mid-thought),
    /// so fillers vanish as you speak instead of flashing and disappearing at the end.
    private func livePreview(_ text: String) -> String {
        let style = sessionPreferences.style
        guard style.level >= .clean else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let english = TranscriptCleaner.isEnglish(text, language: sessionPreferences.language)
        return TranscriptCleaner.clean(text, options: CleanerOptions(style: style, context: sessionContext,
                                                                     english: english, closeSentence: false))
    }

    private func showDelivered(title: String, detail: String, instruction: String) {
        deliveredTask?.cancel()
        delivered = Delivery(title: title, detail: detail, instruction: instruction)
        onStateChange?()
        deliveredTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.delivered = nil
            self?.onStateChange?()
        }
    }

    private func clearDelivered() {
        deliveredTask?.cancel()
        if delivered != nil { delivered = nil }
    }

    func stop(pushToTalkRelease: Bool = false) {
        guard lifecycle.requestStop(pushToTalkRelease: pushToTalkRelease) else { return }
        meterTimer?.invalidate()
        meterTimer = nil
        liveTask?.cancel()
        let samples = capture.stop()
        if sessionPreferences.stopSound { _ = playSound(.stop) }
        synchronizePhase()
        let id = sessionID
        guard let model = selectedModel else {
            finish()
            report("Model is unavailable", "Select an available model and try again.", kind: .error)
            return
        }
        let selectedLanguage = sessionPreferences.language
        let streamedTo = streamActive && streamedCount <= samples.count ? streamedCount : nil
        streamActive = false
        sessionTask = Task { [weak self] in
            guard let self else { return }
            var producedTranscript = false
            do {
                let text: String
                if let streamedTo, AudioAnalysis.hasAudibleContent(samples) {
                    do {
                        text = try await self.transcriber.finishStream(Array(samples[streamedTo...]))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        await self.transcriber.cancelStream()
                        text = try await self.transcriber.transcribe(samples: samples, model: model, language: selectedLanguage)
                    }
                } else {
                    await self.transcriber.cancelStream()
                    text = try await self.transcriber.transcribe(samples: samples, model: model, language: selectedLanguage)
                }
                try Task.checkCancellation()
                guard self.sessionID == id else { return }
                let style = self.sessionPreferences.style
                self.lastHeard = text
                self.liveTranscript = self.livePreview(text)
                if style.level.usesLanguageModel {
                    self.polishing = true
                    self.onStateChange?()
                }
                let outcome = try await self.polisher.polish(text, style: style, context: self.sessionContext,
                                                             appName: self.sessionAppName, language: selectedLanguage)
                try Task.checkCancellation()
                guard self.sessionID == id else { return }
                self.polishing = false
                self.lastOutcome = outcome
                guard !outcome.text.isEmpty else {
                    self.finish()
                    self.report("Nothing to insert", "Only filler sounds were heard, so nothing was pasted or sent.", kind: .info)
                    return
                }
                self.liveTranscript = outcome.text
                self.lastTranscript = outcome.text
                self.lastTranscriptDate = Date()
                producedTranscript = true
                if self.mode == .practice {
                    self.lastDelivery = "Practice complete. Nothing was pasted or sent."
                    self.finish()
                    self.showDelivered(title: "Practice complete", detail: outcome.deliveredDetail,
                                       instruction: "Practice · nothing is pasted")
                } else if let destination = self.destination {
                    self.lifecycle.willInsert()
                    self.synchronizePhase()
                    let preferences = self.sessionPreferences
                    let result = try await self.delivery.deliver(
                        outcome.text, to: destination, autoSend: preferences.autoSend, restoreClipboard: preferences.restoreClipboard
                    )
                    guard self.sessionID == id else { return }
                    self.lastDelivery = result.message
                    let warning = self.sessionWarning
                    self.finish()
                    if result.needsAttention || warning != nil {
                        self.report("Your words are ready", [warning, result.message].compactMap { $0 }.joined(separator: " "), kind: .warning)
                    } else {
                        self.showDelivered(
                            title: result.sent ? "Sent in \(destination.name)" : "Inserted into \(destination.name)",
                            detail: outcome.deliveredDetail,
                            instruction: result.sent ? "Inserted · Return pressed" : "Inserted · you decide when to send"
                        )
                    }
                }
            } catch is CancellationError {
                if self.sessionID == id { self.finish() }
            } catch {
                guard self.sessionID == id else { return }
                self.finish()
                if producedTranscript { self.lastDelivery = error.localizedDescription }
                self.report("Dictation needs attention", error.localizedDescription, kind: .error)
            }
        }
    }

    func cancel() {
        guard busy else { return }
        let wasInserting = phase == .inserting
        sessionID = UUID()
        sessionTask?.cancel()
        finish()
        liveTranscript = ""
        Task { await transcriber.cancelStream() }
        // Cancel hushes the capsule away (spec: Hush, 180 ms); the explanation lives in the window only.
        notice = AppNotice(title: "Dictation cancelled",
                           detail: wasInserting ? "No further keys will be sent. Text already pasted remains in the other app." : "The recording was discarded. Nothing was inserted.",
                           kind: .info, origin: .app)
        onStateChange?()
    }

    private func finishEarlyRelease() {
        finish()
        report("Released a little early", "Hold the push-to-talk shortcut until you hear the cue, or use hands-free.", kind: .info)
    }

    private func finish() {
        meterTimer?.invalidate()
        meterTimer = nil
        liveTask?.cancel()
        streamActive = false
        if polishing { polishing = false }
        _ = capture.stop()
        lifecycle.reset()
        destination = nil
        sessionMode = nil
        do { try hotkeys.enableCancel(false) }
        catch { shortcutError = error.localizedDescription }
        synchronizePhase()
        scheduleModelUnload()
    }

    private func synchronizePhase() {
        phase = lifecycle.phase
        onStateChange?()
    }

    private func startMeter() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / LevelMeter.rate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase.isRecording else { return }
                let snapshot = self.capture.snapshot()
                self.meter.push(snapshot.level, duration: snapshot.duration)
                if snapshot.reachedLimit {
                    self.sessionWarning = "The ten-minute safety limit was reached."
                    self.stop()
                }
            }
        }
    }

    @discardableResult
    private func playSound(_ cue: AudioCue) -> TimeInterval {
        guard let sound = NSSound(named: NSSound.Name(cue.soundName)) else {
            Logger.audio.warning("A configured macOS sound is unavailable")
            notice = AppNotice(title: "Audio cue unavailable", detail: "macOS could not load the \(cue.soundName) cue. Dictation will continue without that sound.", kind: .warning)
            return 0
        }
        retainedSound = sound
        if !sound.play() { Logger.audio.warning("macOS could not play an audio cue") }
        return sound.duration
    }

    /// Plays a cue so people hear exactly what they are enabling.
    func previewCue(_ cue: AudioCue) {
        _ = playSound(cue)
    }

    private func report(_ title: String, _ detail: String, kind: AppNotice.Kind) {
        notice = AppNotice(title: title, detail: detail, kind: kind, origin: .dictation)
        onStateChange?()
    }

    private func showNotice(_ title: String, _ detail: String, kind: AppNotice.Kind) {
        notice = AppNotice(title: title, detail: detail, kind: kind)
        onStateChange?()
    }

    func rescan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            let report = try await scanSnapshot()
            apply(report)
            if preferences.value.selectedModelPath == nil, let model = preferredExistingModel {
                // Discovery already validated the files; defer loading weights to the first dictation.
                preferences.value.selectedModelPath = model.url.path
            }
        } catch is CancellationError {
        } catch {
            showNotice("Model search failed", error.localizedDescription, kind: .error)
        }
    }

    private var preferredExistingModel: LocalModel? {
        models.first { $0.family == .base && !$0.multilingual && $0.bytes < 200_000_000 } ?? models.first
    }

    private func scanSnapshot() async throws -> DiscoveryReport {
        var roots = ModelDiscovery.standardRoots() + preferences.value.searchFolders.map {
            DiscoveryRoot(url: URL(fileURLWithPath: $0), label: "Added folder", maxDepth: 8)
        }
        if let selected = preferences.value.selectedModelPath {
            roots.append(DiscoveryRoot(url: URL(fileURLWithPath: selected), label: "Selected model"))
        }
        let files = preferences.value.modelFiles.map { URL(fileURLWithPath: $0) }
        let indexed = await SpotlightModelSearch().search()
        let scanRoots = roots
        let task = Task.detached(priority: .utility) {
            var report = try ModelDiscovery.scan(
                roots: scanRoots, managedDirectory: ModelDiscovery.managedDirectory,
                explicitFiles: files, indexedFiles: indexed.files
            )
            if let warning = indexed.warning { report.warnings.append(warning) }
            return report
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func apply(_ report: DiscoveryReport) {
        models = report.models
        incompatibleModels = report.incompatible
        scanWarnings = report.warnings
        searchedFolders = report.searchedFolders
        if let path = preferences.value.selectedModelPath, !models.contains(where: { $0.url.path == path }) {
            readyModelPath = nil
            notice = AppNotice(title: "Your selected model moved", detail: "The original file is no longer available. Choose another local model or add its new location.", kind: .warning)
        }
    }

    func choose(_ model: LocalModel) {
        guard canChangeModel else { return }
        modelTask = Task { await activate(model) }
    }

    private func activate(_ model: LocalModel, announce: Bool = true) async {
        guard !busy else { return }
        idleUnloadTask?.cancel()
        preparingModelID = model.id
        readyModelPath = nil
        defer { preparingModelID = nil }
        do {
            try await transcriber.prepare(model: model)
            try Task.checkCancellation()
            preferences.value.selectedModelPath = model.url.path
            if !model.multilingual && !["en", "auto"].contains(preferences.value.language) {
                preferences.value.language = "auto"
            }
            readyModelPath = model.url.path
            if announce {
                activationPulse += 1
                let inPlace: String
                if case .nemotronONNX = model.kind { inPlace = "Using the original model folder in place. No copy was made." }
                else { inPlace = "Using the original file in place. No copy was made." }
                notice = AppNotice(
                    title: "\(model.name) is ready",
                    detail: model.isManaged ? "Configured for offline dictation." : inPlace,
                    kind: .info
                )
            }
            scheduleModelUnload()
        } catch is CancellationError {
        } catch {
            notice = AppNotice(title: "This model couldn't be prepared", detail: error.localizedDescription, kind: .error)
        }
    }

    func install(_ preset: ModelPreset) {
        guard canChangeModel, !isScanning else { return }
        let operation = InstallationProgress(presetID: preset.id, fraction: 0, stage: "Checking this Mac first")
        installation = operation
        installationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.installation = nil }
            do {
                let report = try await self.scanSnapshot()
                try Task.checkCancellation()
                self.apply(report)
                if let existing = self.models.first(where: { $0.canReplace(preset) }) {
                    await self.activate(existing)
                    return
                }
                self.installation?.stage = "Downloading"
                let model = try await ModelInstaller.install(
                    preset, directory: ModelDiscovery.managedDirectory,
                    progress: { [weak self] progress in
                        Task { @MainActor in
                            guard self?.installation?.id == operation.id else { return }
                            self?.installation?.fraction = progress.fraction
                        }
                    },
                    verifying: { [weak self] in
                        Task { @MainActor in
                            guard self?.installation?.id == operation.id else { return }
                            self?.installation?.stage = "Verifying SHA-256"
                        }
                    }
                )
                try Task.checkCancellation()
                self.models.removeAll { $0.id == model.id }
                self.models.append(model)
                self.installation?.stage = "Preparing for dictation"
                await self.activate(model)
            } catch is CancellationError {
                self.notice = AppNotice(title: "Installation cancelled", detail: "Partial downloads are discarded. Any fully verified model remains in your library.", kind: .info)
            } catch let error as URLError where error.code == .cancelled {
                self.notice = AppNotice(title: "Download cancelled", detail: "No partial model was installed.", kind: .info)
            } catch {
                self.notice = AppNotice(title: "Model installation failed", detail: error.localizedDescription, kind: .error)
            }
        }
    }

    func cancelInstallation() { installationTask?.cancel() }

    func addModelFile() {
        guard canChangeModel else { return }
        let panel = NSOpenPanel()
        panel.title = "Use a model already on this Mac"
        panel.message = "Choose a Whisper GGML .bin file, or a Nemotron ONNX folder containing genai_config.json. bigvoice uses it in place without copying."
        panel.prompt = "Use Model"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let model = try ModelFileInspector.inspect(url, source: "Added by you", managedDirectory: ModelDiscovery.managedDirectory)
            if !preferences.value.modelFiles.contains(model.url.path) { preferences.value.modelFiles.append(model.url.path) }
            if !models.contains(where: { $0.id == model.id }) { models.append(model) }
            choose(model)
        } catch {
            notice = AppNotice(title: "This model can't be used", detail: error.localizedDescription, kind: .error)
        }
    }

    func addSearchFolder() {
        guard canChangeModel else { return }
        let panel = NSOpenPanel()
        panel.title = "Search another model folder"
        panel.message = "Choose a folder containing local voice models. Files stay where they are."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if !preferences.value.searchFolders.contains(path) { preferences.value.searchFolders.append(path) }
        Task { await rescan() }
    }

    func removeManagedModel(_ model: LocalModel) {
        guard canChangeModel, model.isManaged,
              ModelFileInspector.contains(model.url, in: ModelDiscovery.managedDirectory) else { return }
        modelTask = Task {
            guard !busy else { return }
            preparingModelID = model.id
            defer { preparingModelID = nil }
            do {
                if preferences.value.selectedModelPath == model.url.path {
                    await transcriber.unload()
                    readyModelPath = nil
                    preferences.value.selectedModelPath = nil
                }
                try FileManager.default.removeItem(at: model.url)
                models.removeAll { $0.id == model.id }
                notice = AppNotice(title: "Download removed", detail: "Only bigvoice's own model file was deleted. Other apps' files were not changed.", kind: .info)
            } catch {
                notice = AppNotice(title: "The model couldn't be removed", detail: error.localizedDescription, kind: .error)
            }
        }
    }

    /// Returns whether the copy succeeded so the button can confirm in place.
    @discardableResult
    func copyTranscript(heard: Bool = false) -> Bool {
        let text = heard ? lastHeard : lastTranscript
        guard !text.isEmpty else { return false }
        delivery.restorePendingClipboard()
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            notice = AppNotice(title: "Couldn't copy the text", detail: DeliveryError.clipboardWrite.localizedDescription, kind: .error)
            return false
        }
        return true
    }

    func clearTranscript() {
        lastTranscript = ""
        lastHeard = ""
        lastOutcome = nil
        lastTranscriptDate = nil
        lastDelivery = ""
    }

    // MARK: - Style

    func refreshWritingStatus() {
        Task {
            let status = await polisher.status()
            if writingStatus != status { writingStatus = status }
        }
    }

    /// The engine Polished and Refined will use with the current settings, if any.
    var writingEngine: WritingEngine? { writingStatus.engine(for: preferences.value.style) }

    /// Runs the real pipeline on sample text for the Style page. Nothing is pasted.
    func previewPolish(_ text: String, style: StylePreferences, context: WritingContext) async throws -> PolishOutcome {
        try await polisher.polish(text, style: style, context: context, appName: nil,
                                  language: preferences.value.language, budget: .seconds(12))
    }

    @discardableResult
    func addVocabulary(term: String, heardAs: String) -> Bool {
        let entry = VocabularyTerm(term: term, heardAs: heardAs.split(separator: ",").map(String.init))
        guard !entry.term.isEmpty, entry.term.count <= 60 else { return false }
        var style = preferences.value.style
        guard style.vocabulary.count < StylePreferences.maximumVocabulary else {
            notice = AppNotice(title: "Your word list is full", detail: "Remove a word to add another. The limit keeps polishing fast.", kind: .info)
            return false
        }
        if let index = style.vocabulary.firstIndex(where: { $0.id == entry.id }) {
            style.vocabulary[index].heardAs = Array(Set(style.vocabulary[index].heardAs + entry.heardAs)).sorted()
        } else {
            style.vocabulary.append(entry)
        }
        preferences.value.style = style
        return true
    }

    func removeVocabulary(_ entry: VocabularyTerm) {
        preferences.value.style.vocabulary.removeAll { $0.id == entry.id }
    }

    func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                notice = AppNotice(title: "Login item needs approval", detail: "Allow bigvoice in System Settings > General > Login Items.", kind: .warning)
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            loginEnabled = SMAppService.mainApp.status == .enabled
            notice = AppNotice(title: "Login item couldn't be changed", detail: "Move bigvoice to Applications first. \(error.localizedDescription)", kind: .error)
        }
    }

    private func scheduleModelUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(300)) }
            catch { return }
            guard let self, !self.busy, self.preparingModelID == nil, self.installation == nil else { return }
            await self.transcriber.unload()
            self.readyModelPath = nil
        }
    }

    func dismissNotice(_ id: UUID) {
        if notice?.id == id { notice = nil }
    }

    /// Stops capture and releases every native engine; ONNX Runtime must shut down before process exit.
    func shutdown() async {
        isShuttingDown = true
        sessionID = UUID()
        sessionTask?.cancel()
        warmUpTask?.cancel()
        liveTask?.cancel()
        deliveredTask?.cancel()
        installationTask?.cancel()
        modelTask?.cancel()
        idleUnloadTask?.cancel()
        meterTimer?.invalidate()
        _ = capture.stop()
        delivery.restorePendingClipboard()
        hotkeys.suspend()
        await transcriber.shutdown()
    }

    #if DEBUG
    func applyPreview(phase: DictationPhase, mode: DictationMode?, levels: [Float] = [], seconds: Int = 0,
                      transcript: String? = nil, live: String = "", delivered: Delivery? = nil,
                      notice: AppNotice? = nil, permissions: (microphone: Bool, accessibility: Bool)? = nil,
                      heard: String? = nil, outcome: PolishOutcome? = nil, polishing: Bool = false) {
        self.phase = phase
        sessionMode = mode
        meter.loadPreview(levels, seconds: seconds)
        liveTranscript = live
        self.delivered = delivered
        self.polishing = polishing
        lastHeard = heard ?? transcript ?? ""
        lastOutcome = outcome
        if let transcript {
            lastTranscript = transcript
            lastTranscriptDate = Date()
            lastDelivery = "Practice complete. Nothing was pasted or sent."
        } else {
            lastTranscript = ""
            lastTranscriptDate = nil
        }
        if let permissions {
            microphoneGranted = permissions.microphone
            accessibilityGranted = permissions.accessibility
        }
        self.notice = notice
    }

    func loadPreviewModels() async {
        guard let report = try? await scanSnapshot() else { return }
        apply(report)
        if preferences.value.selectedModelPath == nil, let model = preferredExistingModel {
            preferences.value.selectedModelPath = model.url.path
        }
    }

    /// Real engine status and real specimen results, so the Style render shows what this Mac produces.
    func loadPreviewStyle() async {
        writingStatus = await polisher.status()
        stylePreview.update(style: preferences.value.style, engineKey: writingEngine?.label ?? "none", delay: .zero)
        await stylePreview.settle()
    }
    #endif
}
