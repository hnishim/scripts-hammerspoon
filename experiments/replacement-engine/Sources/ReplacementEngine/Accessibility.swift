import AppKit
import ApplicationServices
import Foundation

enum AX {
    static func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }
    static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? { copyAttribute(element, attribute) as? String }
    static func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    static func rangeAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFRange? {
        guard let value = copyAttribute(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }
    static func isSettable(_ element: AXUIElement, _ attribute: CFString) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success && settable.boolValue
    }
    static func setString(_ element: AXUIElement, _ attribute: CFString, value: String) -> AXError { AXUIElementSetAttributeValue(element, attribute, value as CFString) }
    static func setRange(_ element: AXUIElement, _ attribute: CFString, value: CFRange) -> AXError {
        var mutable = value
        guard let axValue = AXValueCreate(.cfRange, &mutable) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(element, attribute, axValue)
    }
}

struct TargetCapture {
    static func capture(controlledFixture: Bool) throws -> AXSnapshot {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier else { throw EngineError.noFrontmostApplication }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        let focusedWindow = AX.elementAttribute(appElement, kAXFocusedWindowAttribute as CFString)
        let focusedElement = AX.elementAttribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString)
        let selectedText = focusedElement.flatMap { AX.stringAttribute($0, kAXSelectedTextAttribute as CFString) }
        let selectedRange = focusedElement.flatMap { AX.rangeAttribute($0, kAXSelectedTextRangeAttribute as CFString) }
        let fullValue = focusedElement.flatMap { AX.stringAttribute($0, kAXValueAttribute as CFString) }
        let clipboardSelection = controlledFixture && selectedText == nil ? try SelectionProbe.captureByCopy() : nil
        return AXSnapshot(appBundleID: bundleID, pid: pid, focusedWindow: focusedWindow, focusedElement: focusedElement, selectedText: selectedText, selectedRange: selectedRange, fullValue: fullValue, clipboardSelection: clipboardSelection)
    }

    static func revalidate(_ capture: AXSnapshot, controlledFixture: Bool) throws {
        let current = try TargetCapture.capture(controlledFixture: false)
        guard current.appBundleID == capture.appBundleID, current.pid == capture.pid else { throw EngineError.targetDrift("frontmost application changed") }
        if let originalWindow = capture.focusedWindow {
            guard let currentWindow = current.focusedWindow, CFEqual(originalWindow, currentWindow) else { throw EngineError.targetDrift("focused window changed") }
        }
        if let originalElement = capture.focusedElement {
            guard let currentElement = current.focusedElement, CFEqual(originalElement, currentElement) else { throw EngineError.targetDrift("focused element changed") }
        }
        if let originalRange = capture.selectedRange {
            guard let range = current.selectedRange, originalRange.location == range.location, originalRange.length == range.length else { throw EngineError.targetDrift("selected range changed") }
        }
        if let selected = capture.selectedText, current.selectedText != selected { throw EngineError.targetDrift("selected text changed") }
        if let copied = capture.clipboardSelection {
            guard controlledFixture else { throw EngineError.targetDrift("clipboard selection requires controlled fixture") }
            guard try SelectionProbe.captureByCopy() == copied else { throw EngineError.targetDrift("controlled selection changed") }
        }
    }
}

struct ExpectedState {
    let original: String
    let expected: String
    let range: CFRange
    static func from(_ capture: AXSnapshot, replacement: String) -> ExpectedState? {
        guard let original = capture.fullValue, let range = capture.selectedRange, range.location >= 0, range.length >= 0, range.location + range.length <= (original as NSString).length else { return nil }
        let expected = (original as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: replacement)
        return ExpectedState(original: original, expected: expected, range: range)
    }
}
