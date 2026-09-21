import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// A modifier that can be double-tapped to summon Blip.
///
/// Left and right variants are distinct because the right-hand modifiers are almost
/// never used in app shortcuts, which makes them safe to claim.
public enum TriggerModifier: String, Codable, CaseIterable, Sendable, Hashable {
    case leftCommand
    case rightCommand
    case leftOption
    case rightOption
    case leftControl
    case rightControl
    case leftShift
    case rightShift

    /// Virtual key code, from Carbon's `Events.h`.
    public var keyCode: UInt16 {
        switch self {
        case .leftCommand: return 0x37
        case .rightCommand: return 0x36
        case .leftOption: return 0x3A
        case .rightOption: return 0x3D
        case .leftControl: return 0x3B
        case .rightControl: return 0x3E
        case .leftShift: return 0x38
        case .rightShift: return 0x3C
        }
    }

    public init?(keyCode: UInt16) {
        guard let match = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = match
    }

    /// "Left" or "Right". Spelled out rather than symbolised because no glyph for
    /// handedness is any clearer than the word.
    public var sideName: String {
        switch self {
        case .leftCommand, .leftOption, .leftControl, .leftShift: return "Left"
        case .rightCommand, .rightOption, .rightControl, .rightShift: return "Right"
        }
    }

    public var symbol: String {
        switch self {
        case .leftCommand, .rightCommand: return "\u{2318}"
        case .leftOption, .rightOption: return "\u{2325}"
        case .leftControl, .rightControl: return "\u{2303}"
        case .leftShift, .rightShift: return "\u{21E7}"
        }
    }

    /// e.g. "Right Command" -- for menus and accessibility labels, where a bare glyph
    /// reads poorly.
    public var displayName: String {
        switch self {
        case .leftCommand, .rightCommand: return "\(sideName) Command"
        case .leftOption, .rightOption: return "\(sideName) Option"
        case .leftControl, .rightControl: return "\(sideName) Control"
        case .leftShift, .rightShift: return "\(sideName) Shift"
        }
    }

    /// e.g. "Right ⌘".
    public var shortName: String { "\(sideName) \(symbol)" }

    /// The flag this modifier sets while held. Left and right share one flag, which is
    /// why the key code is checked first wherever this is used.
    public var flag: CGEventFlags {
        switch self {
        case .leftCommand, .rightCommand: return .maskCommand
        case .leftOption, .rightOption: return .maskAlternate
        case .leftControl, .rightControl: return .maskControl
        case .leftShift, .rightShift: return .maskShift
        }
    }
}

/// An ordinary chord: one key plus zero or more modifiers.
public struct HotKey: Codable, Equatable, Sendable, Hashable {

    /// The four modifiers a shortcut can carry. Caps Lock and Fn are deliberately not
    /// here: neither is dependable as part of a chord.
    public struct Modifiers: OptionSet, Codable, Sendable, Hashable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)

        /// Canonical Apple order: ⌃⌥⇧⌘.
        static let ordered: [(Modifiers, String)] = [
            (.control, "\u{2303}"), (.option, "\u{2325}"),
            (.shift, "\u{21E7}"), (.command, "\u{2318}"),
        ]

        /// Keeps only the four flags that matter. Everything else an event carries --
        /// Caps Lock, Fn, the numeric-pad bit arrow keys set -- would otherwise make an
        /// otherwise-identical chord fail to match.
        public init(eventFlags: CGEventFlags) {
            var result: Modifiers = []
            if eventFlags.contains(.maskControl) { result.insert(.control) }
            if eventFlags.contains(.maskAlternate) { result.insert(.option) }
            if eventFlags.contains(.maskShift) { result.insert(.shift) }
            if eventFlags.contains(.maskCommand) { result.insert(.command) }
            self = result
        }

        public var symbols: String {
            Self.ordered.filter { contains($0.0) }.map(\.1).joined()
        }
    }

    public var keyCode: UInt16
    public var modifiers: Modifiers

    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Function keys and the like are safe to claim on their own; a bare letter would
    /// swallow that letter system-wide, so it is rejected at the point of recording.
    public var isUsableWithoutModifiers: Bool {
        KeyNames.isStandaloneSafe(keyCode)
    }

    public var displayString: String { modifiers.symbols + KeyNames.name(for: keyCode) }
}

/// What summons Blip.
public enum Trigger: Codable, Equatable, Sendable, Hashable {
    /// Two taps of one modifier, with nothing pressed in between.
    case doubleTapModifier(TriggerModifier)
    /// A plain chord, pressed once.
    case hotKey(HotKey)

    public static let `default` = Trigger.doubleTapModifier(.rightCommand)

    public var displayString: String {
        switch self {
        case .doubleTapModifier(let modifier): return "Double-tap \(modifier.shortName)"
        case .hotKey(let hotKey): return hotKey.displayString
        }
    }

    /// Wording for the menu bar, where there is room to spell things out.
    public var menuDescription: String {
        switch self {
        case .doubleTapModifier(let modifier): return "double-tap \(modifier.symbol)"
        case .hotKey(let hotKey): return hotKey.displayString
        }
    }

    public var isDoubleTap: Bool {
        if case .doubleTapModifier = self { return true }
        return false
    }

    // MARK: - Codable

    // Written by hand so the JSON stays legible and, more to the point, so a config
    // written by a future version with a case this one does not know falls back to the
    // default instead of failing the whole file to decode.

    private enum CodingKeys: String, CodingKey {
        case kind, modifier, keyCode, modifiers
    }

    private enum Kind: String, Codable {
        case doubleTapModifier, hotKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decodeIfPresent(Kind.self, forKey: .kind) {
        case .hotKey:
            self = .hotKey(HotKey(
                keyCode: try container.decode(UInt16.self, forKey: .keyCode),
                modifiers: try container.decode(HotKey.Modifiers.self, forKey: .modifiers)
            ))
        case .doubleTapModifier:
            self = .doubleTapModifier(try container.decode(TriggerModifier.self, forKey: .modifier))
        case nil:
            self = .default
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .doubleTapModifier(let modifier):
            try container.encode(Kind.doubleTapModifier, forKey: .kind)
            try container.encode(modifier, forKey: .modifier)
        case .hotKey(let hotKey):
            try container.encode(Kind.hotKey, forKey: .kind)
            try container.encode(hotKey.keyCode, forKey: .keyCode)
            try container.encode(hotKey.modifiers, forKey: .modifiers)
        }
    }
}

/// Turns a virtual key code into something printable.
///
/// Letters and punctuation are resolved through the *current keyboard layout* rather
/// than a hardcoded US table, because a key code names a physical position: key code 12
/// is Q on QWERTY and A on AZERTY, and showing the wrong one makes the shortcut field
/// look broken.
public enum KeyNames {

    /// Keys whose label is a name, not a character. These never reach the layout.
    private static let named: [UInt16: String] = [
        0x24: "\u{21A9}",           // Return
        0x4C: "\u{2305}",           // Keypad Enter
        0x30: "\u{21E5}",           // Tab
        0x31: "Space",
        0x33: "\u{232B}",           // Delete
        0x75: "\u{2326}",           // Forward Delete
        0x35: "\u{238B}",           // Escape
        0x72: "Help",
        0x73: "\u{2196}",           // Home
        0x77: "\u{2198}",           // End
        0x74: "\u{21DE}",           // Page Up
        0x79: "\u{21DF}",           // Page Down
        0x7B: "\u{2190}",
        0x7C: "\u{2192}",
        0x7E: "\u{2191}",
        0x7D: "\u{2193}",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x69: "F13", 0x6B: "F14", 0x71: "F15", 0x6A: "F16", 0x40: "F17", 0x4F: "F18",
        0x50: "F19", 0x5A: "F20",
    ]

    /// Keys that do not type anything, so claiming one on its own costs the user
    /// nothing.
    private static let standaloneSafe: Set<UInt16> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,
        0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
        0x72,                       // Help
        0x73, 0x77, 0x74, 0x79,     // Home / End / Page Up / Page Down
    ]

    public static func isStandaloneSafe(_ keyCode: UInt16) -> Bool {
        standaloneSafe.contains(keyCode)
    }

    public static func name(for keyCode: UInt16) -> String {
        if let named = named[keyCode] { return named }
        if let character = layoutCharacter(for: keyCode) { return character.uppercased() }
        return "Key \(keyCode)"
    }

    /// Asks the active keyboard layout what this key produces unmodified.
    private static func layoutCharacter(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
            .takeRetainedValue() else { return nil }
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }

        var deadKeyState: UInt32 = 0
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)

        let status = bytes.withMemoryRebound(
            to: UCKeyboardLayout.self, capacity: 1
        ) { layout in
            UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,                                      // no modifiers
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                buffer.count,
                &length,
                &buffer
            )
        }

        guard status == noErr, length > 0 else { return nil }
        let character = String(utf16CodeUnits: buffer, count: length)
        return character.trimmingCharacters(in: .whitespaces).isEmpty ? nil : character
    }
}
