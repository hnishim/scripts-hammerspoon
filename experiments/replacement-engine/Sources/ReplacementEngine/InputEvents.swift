import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum KeyEvents {
    static func chord(keyCode: CGKeyCode, flags: CGEventFlags) throws {
        guard let source = CGEventSource(stateID: .hidSystemState), let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true), let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { throw EngineError.eventCreationFailed("keyboard chord") }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }

    static func unicode(_ text: String) throws {
        guard let source = CGEventSource(stateID: .hidSystemState), let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true), let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { throw EngineError.eventCreationFailed("unicode injection") }
        let units = Array(text.utf16)
        units.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
        }
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
}

enum SelectionProbe {
    static func captureByCopy() throws -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = try ClipboardSnapshot.capture(pasteboard)
        let before = pasteboard.changeCount
        try KeyEvents.chord(keyCode: CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
        let deadline = Date().addingTimeInterval(0.30)
        while Date() < deadline && pasteboard.changeCount == before { Thread.sleep(forTimeInterval: 0.01) }
        let after = pasteboard.changeCount
        guard after != before else { return nil }
        let selected = pasteboard.string(forType: .string)
        _ = snapshot.restoreIfUnchanged(since: after, pasteboard: pasteboard)
        return selected
    }
}
