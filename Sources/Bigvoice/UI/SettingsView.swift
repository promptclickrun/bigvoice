import AppKit
import BigvoiceCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let languages: [(String, String)] = [
        ("Automatic", "auto"), ("English", "en"), ("Spanish", "es"), ("French", "fr"), ("German", "de"),
        ("Italian", "it"), ("Portuguese", "pt"), ("Dutch", "nl"), ("Polish", "pl"), ("Ukrainian", "uk"),
        ("Japanese", "ja"), ("Korean", "ko"), ("Chinese", "zh"), ("Hindi", "hi"), ("Arabic", "ar")
    ]

    private func binding<Value>(_ path: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(get: { controller.preferences.value[keyPath: path] },
                set: { controller.preferences.value[keyPath: path] = $0 })
    }

    private func cue(_ path: WritableKeyPath<Preferences, Bool>, _ cue: AudioCue) -> Binding<Bool> {
        Binding(get: { controller.preferences.value[keyPath: path] }, set: { enabled in
            controller.preferences.value[keyPath: path] = enabled
            if enabled { controller.previewCue(cue) }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            PageTitle(title: "Make it second nature.",
                      subtitle: "Your shortcuts, your microphone, your way of finishing a thought.")
            shortcuts
            input
            finishing
            cues
            background
            footer
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Shortcuts", detail: nil) {
                Button("Reset defaults", action: controller.resetShortcuts)
                    .buttonStyle(PillButtonStyle(kind: .text))
                    .disabled(controller.busy || controller.isRecordingShortcut)
            }
            Panel {
                SettingRow(title: "Push to talk", detail: "Hold to record; release to finish.") {
                    ShortcutRecorder(shortcut: controller.preferences.value.pushToTalk, controller: controller, pushToTalk: true)
                }
                RowDivider()
                SettingRow(title: "Hands-free", detail: "Press to start; press again to finish.") {
                    ShortcutRecorder(shortcut: controller.preferences.value.handsFree, controller: controller, pushToTalk: false)
                }
            }
            .disabled(controller.busy)
            Text("Use Control, Option, or Command with another key. Escape cancels an active dictation.")
                .font(BrandFont.ui(12)).foregroundStyle(Palette.stone)
            if let error = controller.shortcutError {
                Text(error).font(BrandFont.ui(12.5)).foregroundStyle(Palette.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Input", detail: nil) {
                Button("Refresh devices") { controller.devices.refresh() }
                    .buttonStyle(PillButtonStyle(kind: .text))
            }
            Panel {
                SettingRow(title: "Microphone", detail: "Uses this device without changing macOS settings.") {
                    BrandSelect(options: microphoneOptions, selection: binding(\.inputDeviceUID), width: 200,
                                accessibilityLabel: "Microphone")
                }
                RowDivider()
                SettingRow(title: "Language", detail: languageDetail) {
                    BrandSelect(options: languages.map { name, code in
                        .init(label: name, value: code,
                              enabled: controller.selectedModel?.multilingual != false || ["auto", "en"].contains(code))
                    }, selection: binding(\.language), width: 160, accessibilityLabel: "Language")
                }
            }
            .disabled(controller.busy)
            if let error = controller.devices.error {
                Text(error).font(BrandFont.ui(12.5)).foregroundStyle(Palette.caution)
            }
        }
    }

    private var microphoneOptions: [BrandSelect<String>.Option] {
        var options: [BrandSelect<String>.Option] = [.init(label: "System default", value: "system")]
        options += controller.devices.devices.map { .init(label: $0.name, value: $0.uid) }
        let selected = controller.preferences.value.inputDeviceUID
        if selected != "system" && !controller.devices.devices.contains(where: { $0.uid == selected }) {
            options.append(.init(label: "Disconnected microphone", value: selected))
        }
        return options
    }

    private var languageDetail: String {
        guard let model = controller.selectedModel else { return "Automatic detection needs a multilingual model." }
        return model.multilingual ? "Automatic detection needs a multilingual model." : "\(model.displayName) transcribes English."
    }

    private var finishing: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("When you're finished")
            Panel {
                SettingRow(title: "Automatically press Return", detail: "Off by default. Leave text ready for your review.") {
                    Toggle("Automatically press Return", isOn: binding(\.autoSend)).toggleStyle(BrandToggleStyle())
                }
                RowDivider()
                SettingRow(title: "Restore the clipboard", detail: "Keep your previous copy. Never overwrite a newer one.") {
                    Toggle("Restore the clipboard", isOn: binding(\.restoreClipboard)).toggleStyle(BrandToggleStyle())
                }
            }
            .disabled(controller.busy)
            if controller.preferences.value.autoSend {
                Text("Return can send messages or run terminal commands. bigvoice only presses it after confirmed insertion into the original field.")
                    .font(BrandFont.ui(12.5)).lineSpacing(3)
                    .foregroundStyle(Palette.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -6)))
            }
        }
        .animation(reduceMotion ? Motion.reduced : Motion.swell, value: controller.preferences.value.autoSend)
    }

    private var cues: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("Audio cues")
            Panel {
                SettingRow(title: "Play a sound when listening starts") {
                    Toggle("Play a sound when listening starts", isOn: cue(\.startSound, .start)).toggleStyle(BrandToggleStyle())
                }
                RowDivider()
                SettingRow(title: "Play a sound when listening stops") {
                    Toggle("Play a sound when listening stops", isOn: cue(\.stopSound, .stop)).toggleStyle(BrandToggleStyle())
                }
            }
        }
    }

    private var background: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("Out of the way")
            Panel {
                SettingRow(title: "Open at login", detail: "Keep your shortcuts ready after a restart. Move bigvoice to Applications first.") {
                    Toggle("Open at login", isOn: Binding(get: { controller.loginEnabled }, set: controller.setLoginEnabled))
                        .toggleStyle(BrandToggleStyle())
                }
                RowDivider()
                SettingRow(title: "Permissions", detail: controller.accessibilityGranted
                           ? "Microphone to hear you. Accessibility to insert your words."
                           : "Accessibility is off for this build. If System Settings already shows it on, press Repair.") {
                    HStack(spacing: 6) {
                        if !controller.accessibilityGranted {
                            Button("Repair", action: controller.repairAccessibility)
                                .buttonStyle(PillButtonStyle(kind: .quiet, height: 32))
                        }
                        Button("Microphone", action: controller.requestMicrophone)
                            .buttonStyle(PillButtonStyle(kind: .outline, height: 32))
                        Button("Accessibility", action: controller.requestAccessibility)
                            .buttonStyle(PillButtonStyle(kind: .outline, height: 32))
                    }
                }
            }
            Text("Audio is held in memory only and discarded after transcription. There are no accounts, analytics, or cloud transcription requests. Closing the window keeps bigvoice in the menu bar.")
                .font(BrandFont.ui(12)).lineSpacing(3).foregroundStyle(Palette.stone)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Text("bigvoice \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1")")
                .font(BrandFont.ui(12, weight: 500))
            Spacer()
            Button("Whisper · whisper.cpp · ONNX Runtime · MIT") {
                if let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(.plain)
            .font(BrandFont.ui(12))
            .help("Open third-party licenses")
        }
        .foregroundStyle(Palette.stone)
    }
}
