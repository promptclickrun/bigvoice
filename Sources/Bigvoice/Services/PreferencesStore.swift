import BigvoiceCore
import Combine
import Foundation
import OSLog

@MainActor
final class PreferencesStore: ObservableObject {
    private let defaults: UserDefaults
    private let key = "bigvoice.preferences.v1"
    @Published var error: String?
    @Published var value: Preferences {
        didSet {
            do {
                defaults.set(try JSONEncoder().encode(value), forKey: key)
            } catch {
                self.error = "Your preferences could not be saved: \(error.localizedDescription)"
                Logger.preferences.error("Could not encode preferences: \(error.localizedDescription)")
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key) {
            do {
                let decoded = try JSONDecoder().decode(Preferences.self, from: data)
                try decoded.validateShortcuts()
                value = decoded
            } catch {
                value = Preferences()
                self.error = "Saved preferences could not be read. Safe defaults are in use. \(error.localizedDescription)"
                Logger.preferences.error("Could not read preferences: \(error.localizedDescription)")
            }
        } else {
            value = Preferences()
        }
    }
}

extension Logger {
    static let preferences = Logger(subsystem: "com.bigvoice.mac", category: "preferences")
    static let audio = Logger(subsystem: "com.bigvoice.mac", category: "audio")
    static let app = Logger(subsystem: "com.bigvoice.mac", category: "app")
}
