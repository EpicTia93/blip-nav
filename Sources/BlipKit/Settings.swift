import Foundation

/// User-configurable behaviour, persisted as JSON.
///
/// A plain file rather than `UserDefaults` so it can be inspected and edited by hand
/// while developing, and diffed when something behaves unexpectedly.
public struct Configuration: Codable, Equatable, Sendable {
    /// What summons Blip: any chord, or a double-tapped modifier.
    public var trigger: Trigger = .default
    /// Maximum gap between the two taps of a double-tap trigger. Below ~250ms this is
    /// hard to hit reliably; above ~400ms ordinary modifier use starts triggering it by
    /// accident. Ignored when the trigger is a plain chord.
    public var doubleTapWindow: TimeInterval = 0.3
    public var ocrEnabled = true
    public var ocrLanguages: [String] = ["it-IT", "en-US"]
    public var hintFontSize: Double = 13
    /// How long an ambiguous digit prefix waits before firing its exact match.
    public var hintPrefixTimeout: TimeInterval = 0.4

    public init() {}

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case trigger, doubleTapWindow, ocrEnabled, ocrLanguages, hintFontSize, hintPrefixTimeout
        /// Blip 1.0 stored only a double-tap modifier, under this key.
        case triggerModifier
    }

    /// Every field is optional on the way in, so a config file written by an older or
    /// newer build loses at most the settings it disagrees about rather than being
    /// discarded whole.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Configuration()

        if let trigger = try container.decodeIfPresent(Trigger.self, forKey: .trigger) {
            self.trigger = trigger
        } else if let legacy = try container.decodeIfPresent(
            TriggerModifier.self, forKey: .triggerModifier
        ) {
            self.trigger = .doubleTapModifier(legacy)
        } else {
            self.trigger = defaults.trigger
        }

        doubleTapWindow = try container.decodeIfPresent(TimeInterval.self, forKey: .doubleTapWindow)
            ?? defaults.doubleTapWindow
        ocrEnabled = try container.decodeIfPresent(Bool.self, forKey: .ocrEnabled)
            ?? defaults.ocrEnabled
        ocrLanguages = try container.decodeIfPresent([String].self, forKey: .ocrLanguages)
            ?? defaults.ocrLanguages
        hintFontSize = try container.decodeIfPresent(Double.self, forKey: .hintFontSize)
            ?? defaults.hintFontSize
        hintPrefixTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .hintPrefixTimeout)
            ?? defaults.hintPrefixTimeout
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(doubleTapWindow, forKey: .doubleTapWindow)
        try container.encode(ocrEnabled, forKey: .ocrEnabled)
        try container.encode(ocrLanguages, forKey: .ocrLanguages)
        try container.encode(hintFontSize, forKey: .hintFontSize)
        try container.encode(hintPrefixTimeout, forKey: .hintPrefixTimeout)
    }
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
