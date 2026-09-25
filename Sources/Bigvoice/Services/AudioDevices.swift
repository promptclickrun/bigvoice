import AudioToolbox
import Combine
import CoreAudio
import Foundation

struct InputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

struct AudioDeviceError: LocalizedError {
    let message: String
    let status: OSStatus
    var errorDescription: String? { "\(message) (audio error \(status))." }
}

@MainActor
final class AudioDevices: ObservableObject {
    @Published private(set) var devices: [InputDevice] = []
    @Published private(set) var error: String?
    private var listener: AudioObjectPropertyListenerBlock?

    init() {
        refresh()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        if status == noErr { listener = block }
        else { error = "Input devices could not be monitored automatically (error \(status)). Use Refresh." }
    }

    deinit {
        if let listener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
    }

    func refresh() {
        do {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var size: UInt32 = 0
            try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size),
                      "Could not enumerate input devices")
            var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids),
                      "Could not read input devices")
            var available: [InputDevice] = []
            for id in ids {
                var inputAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                    mElement: kAudioObjectPropertyElementMain
                )
                var inputSize: UInt32 = 0
                try check(AudioObjectGetPropertyDataSize(id, &inputAddress, 0, nil, &inputSize), "Could not inspect an audio device")
                guard inputSize > 0 else { continue }
                let name = try stringProperty(id, selector: kAudioObjectPropertyName)
                let uid = try stringProperty(id, selector: kAudioDevicePropertyDeviceUID)
                available.append(InputDevice(id: id, uid: uid, name: name))
            }
            devices = available.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func resolve(uid: String) throws -> AudioDeviceID {
        if uid != "system" {
            guard let device = devices.first(where: { $0.uid == uid }) else {
                throw AudioDeviceError(message: "The selected microphone is disconnected. Choose another input device", status: kAudioHardwareBadDeviceError)
            }
            return device.id
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id),
                  "Could not find the system microphone")
        guard id != kAudioObjectUnknown else {
            throw AudioDeviceError(message: "No microphone is connected", status: kAudioHardwareBadDeviceError)
        }
        return id
    }

    func name(for uid: String) -> String {
        if uid == "system" { return "System default" }
        return devices.first(where: { $0.uid == uid })?.name ?? "Disconnected microphone"
    }

    private func stringProperty(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value), "Could not read the microphone's details")
        guard let value else {
            throw AudioDeviceError(message: "The microphone returned no name or identifier", status: kAudioHardwareUnspecifiedError)
        }
        return value.takeRetainedValue() as String
    }

    private func check(_ status: OSStatus, _ message: String) throws {
        if status != noErr { throw AudioDeviceError(message: message, status: status) }
    }
}
