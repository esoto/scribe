import Carbon.HIToolbox
import CoreGraphics

/// Which physical key types a character in the layout that is active right now. The synthetic ⌘V and ⌘Z need it:
/// apps match shortcuts by the character a key types, so ANSI keycodes 9 and 6 would press ⌘K and ⌘; on Dvorak,
/// and ⌘Y or ⌘W in place of ⌘Z on QWERTZ or AZERTY. Called per press (128 translations take microseconds), so a
/// layout switch needs no cache invalidation.
enum KeyboardLayout {
    /// The first keycode whose press with ⌘ held types `character`; nil when no key does or the layout data is
    /// unavailable.
    static func keycode(for character: Character) -> CGKeyCode? {
        guard let layout = currentLayoutData() else { return nil }
        return keycode(for: character, translating: { translate($0, in: layout) })
    }

    /// What the keycode types with ⌘ held in the active layout; nil when it types nothing or the data is unavailable.
    static func character(for keycode: CGKeyCode) -> String? {
        currentLayoutData().flatMap { translate(keycode, in: $0) }
    }

    /// The scan, split from the system lookup so the first-match rule runs against any layout.
    static func keycode(for character: Character, translating translate: (CGKeyCode) -> String?) -> CGKeyCode? {
        let wanted = String(character)
        return (0..<128).map { CGKeyCode($0) }.first { translate($0) == wanted }
    }

    /// HIToolbox has asserted the main queue inside these calls on some releases, and postKey runs on the pipeline
    /// worker.
    private static func currentLayoutData() -> Data? {
        Thread.isMainThread ? readCurrentLayoutData() : DispatchQueue.main.sync(execute: readCurrentLayoutData)
    }

    private static func readCurrentLayoutData() -> Data? {
        guard
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        return Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
    }

    /// With ⌘ held: apps match a shortcut by what its key types under ⌘, and Dvorak - QWERTY ⌘ and the non-Latin
    /// layouts switch layers while it is down.
    static func translate(_ keycode: CGKeyCode, in layout: Data) -> String? {
        layout.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                base.assumingMemoryBound(to: UCKeyboardLayout.self),
                keycode,
                UInt16(kUCKeyActionDisplay),
                UInt32((cmdKey >> 8) & 0xFF),
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                chars.count,
                &length,
                &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}
