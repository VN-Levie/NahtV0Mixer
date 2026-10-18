import AppKit
import Combine
import SwiftUI

enum MixerLanguage: String, CaseIterable, Identifiable {
    case system, english, vietnamese
    var id: String { rawValue }

    func languageCode(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        switch self {
        case .english: return "en"
        case .vietnamese: return "vi"
        case .system: return preferredLanguages.first?.lowercased().hasPrefix("vi") == true ? "vi" : "en"
        }
    }
}

enum MixerTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()
    private let defaults: UserDefaults
    @Published var language: MixerLanguage {
        didSet { defaults.set(language.rawValue, forKey: "interfaceLanguage") }
    }
    @Published var theme: MixerTheme {
        didSet { defaults.set(theme.rawValue, forKey: "interfaceTheme") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = defaults.string(forKey: "interfaceLanguage").flatMap(MixerLanguage.init(rawValue:)) ?? .system
        theme = defaults.string(forKey: "interfaceTheme").flatMap(MixerTheme.init(rawValue:)) ?? .system
    }

    func text(_ english: String) -> String {
        LocalText.text(english, languageCode: language.languageCode())
    }
}
