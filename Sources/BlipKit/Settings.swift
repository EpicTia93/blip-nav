import Foundation

/// A modifier that can be double-tapped to summon Blip.
///
/// Left and right variants are distinct because the right-hand modifiers are almost
/// never used in app shortcuts, which makes them safe to claim.
public enum TriggerModifier: String, Codable, CaseIterable, Sendable {
    case rightCommand
    case leftCommand
    case rightOption
    case leftOption
    case rightControl
    case rightShift

    /// Virtual key code, from Carbon's `Events.h`.
    public var keyCode: UInt16 {
        switch self {
        case .rightCommand: return 0x36
        case .leftCommand: return 0x37
        case .rightOption: return 0x3D
        case .leftOption: return 0x3A
        case .rightControl: return 0x3E
        case .rightShift: return 0x3C
        }
    }

    public var displayName: String {
        switch self {
        case .rightCommand: return "Right Command"
        case .leftCommand: return "Left Command"
        case .rightOption: return "Right Option"
        case .leftOption: return "Left Option"
        case .rightControl: return "Right Control"
        case .rightShift: return "Right Shift"
        }
    }

    public var symbol: String {
        switch self {
        case .rightCommand, .leftCommand: return "\u{2318}"
        case .rightOption, .leftOption: return "\u{2325}"
        case .rightControl: return "\u{2303}"
        case .rightShift: return "\u{21E7}"
        }
    }
}

/// User-configurable behaviour, persisted as JSON.
///
/// A plain file rather than `UserDefaults` so it can be inspected and edited by hand
/// while developing, and diffed when something behaves unexpectedly.
public struct Configuration: Codable, Equatable, Sendable {
    public var triggerModifier: TriggerModifier = .rightCommand
    /// Maximum gap between the two taps. Below ~250ms this is hard to hit reliably;
    /// above ~400ms ordinary modifier use starts triggering it by accident.
    public var doubleTapWindow: TimeInterval = 0.3
    public var ocrEnabled = true
    public var ocrLanguages: [String] = ["it-IT", "en-US"]
    public var hintFontSize: Double = 13
    /// How long an ambiguous digit prefix waits before firing its exact match.
    public var hintPrefixTimeout: TimeInterval = 0.4

    public init() {}
}

/// Loads and saves `Configuration`, and notifies observers on change.
@MainActor
public final class SettingsStore: ObservableObject {
    /// Posted after `configuration` changes, so the event tap and menu bar can pick
    /// up a new trigger key without a relaunch.
    public static let didChangeNotification = Notification.Name("BlipSettingsDidChange")

    @Published public var configuration: Configuration {
        didSet {
            guard configuration != oldValue else { return }
            save()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    public static let shared = SettingsStore()

    public static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Blip/config.json")
    }

    public init() {
        configuration = Self.load() ?? Configuration()
    }

    private static func load() -> Configuration? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Configuration.self, from: data)
    }

    public func save() {
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: url, options: .atomic)
        } catch {
            NSLog("Blip: could not save configuration: \(error)")
        }
    }

    public func reset() {
        configuration = Configuration()
    }
}
