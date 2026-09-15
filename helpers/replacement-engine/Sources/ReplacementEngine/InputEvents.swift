import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum KeyEvents {
    static func chord(keyCode: CGKeyCode, flags: CGEventFlags) throws {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw EngineError.eventCreationFailed
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

enum SelectionProbe {
    static func captureByCopy(
        pasteboard: NSPasteboard = .general,
        timeout: TimeInterval = 0.30,
        copyAction: () throws -> Void = {
            try KeyEvents.chord(keyCode: CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
        }
    ) throws -> String? {
        let snapshot = try ClipboardSnapshot.capture(pasteboard)
        let before = snapshot.changeCount

        do {
            try copyAction()
        } catch {
            throw error
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && pasteboard.changeCount == before {
            Thread.sleep(forTimeInterval: 0.01)
        }

        let after = pasteboard.changeCount
        guard after != before else { return nil }
        guard after == before + 1 else { throw EngineError.clipboardUnavailable }

        let selected = pasteboard.string(forType: .string)
        guard pasteboard.changeCount == after else { throw EngineError.clipboardUnavailable }
        guard snapshot.restoreIfUnchanged(since: after, pasteboard: pasteboard) else {
            throw EngineError.clipboardUnavailable
        }
        return selected
    }
}
