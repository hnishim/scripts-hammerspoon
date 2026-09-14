import AppKit
import ApplicationServices
import Foundation

enum AX {
    static func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }

    static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        copyAttribute(element, attribute) as? String
    }

    static func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
        }
        return (value as? NSNumber)?.boolValue
    }

    static func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    static func elementsAttribute(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement] {
        guard let values = copyAttribute(element, attribute) as? [Any] else { return [] }
        return values.map { unsafeBitCast($0, to: AXUIElement.self) }
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

    static func setString(_ element: AXUIElement, _ attribute: CFString, value: String) -> AXError {
        AXUIElementSetAttributeValue(element, attribute, value as CFString)
    }

    static func setRange(_ element: AXUIElement, _ attribute: CFString, value: CFRange) -> AXError {
        var mutable = value
        guard let axValue = AXValueCreate(.cfRange, &mutable) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(element, attribute, axValue)
    }
}

enum TargetResolver {
    private static let selectorBundles: Set<String> = [
        "sh.zoid.meru",
        "com.tinyspeck.slackmacgap",
    ]

    static func resolve(bundleID: String, appElement: AXUIElement, focusedWindow: AXUIElement?, systemFocused: AXUIElement?) -> AXUIElement? {
        guard selectorBundles.contains(bundleID) else { return systemFocused }

        let root = focusedWindow ?? appElement
        var candidates: [AXUIElement] = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0

        while let (element, depth) = stack.popLast(), visited < 600 {
            visited += 1
            if isTextAreaCandidate(element) { candidates.append(element) }
            guard depth < 14 else { continue }
            for child in AX.elementsAttribute(element, kAXChildrenAttribute as CFString).reversed() {
                stack.append((child, depth + 1))
            }
        }

        let focused = candidates.filter { AX.boolAttribute($0, kAXFocusedAttribute as CFString) == true }
        let focusedWithSelection = focused.filter(hasSelectionContext)
        if focusedWithSelection.count == 1 { return focusedWithSelection[0] }

        let withSelection = candidates.filter(hasSelectionContext)
        if withSelection.count == 1 { return withSelection[0] }

        if let systemFocused, isTextAreaCandidate(systemFocused), hasSelectionContext(systemFocused) {
            return systemFocused
        }

        return nil
    }

    private static func isTextAreaCandidate(_ element: AXUIElement) -> Bool {
        AX.stringAttribute(element, kAXRoleAttribute as CFString) == kAXTextAreaRole as String
    }

    private static func hasSelectionContext(_ element: AXUIElement) -> Bool {
        if let range = AX.rangeAttribute(element, kAXSelectedTextRangeAttribute as CFString), range.length > 0 { return true }
        if let text = AX.stringAttribute(element, kAXSelectedTextAttribute as CFString), !text.isEmpty { return true }
        return false
    }
}

struct TargetCapture {
    static func capture(controlledFixture: Bool) throws -> AXSnapshot {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier else {
            throw EngineError.noFrontmostApplication
        }

        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        let focusedWindow = AX.elementAttribute(appElement, kAXFocusedWindowAttribute as CFString)
        let systemFocused = AX.elementAttribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString)
        let target = TargetResolver.resolve(bundleID: bundleID, appElement: appElement, focusedWindow: focusedWindow, systemFocused: systemFocused)
        let selectedText = target.flatMap { AX.stringAttribute($0, kAXSelectedTextAttribute as CFString) }
        let selectedRange = target.flatMap { AX.rangeAttribute($0, kAXSelectedTextRangeAttribute as CFString) }
        let fullValue = target.flatMap { AX.stringAttribute($0, kAXValueAttribute as CFString) }
        let directSelection = (selectedRange?.length ?? 0) > 0 || !(selectedText ?? "").isEmpty
        let clipboardSelection = controlledFixture && !directSelection ? try SelectionProbe.captureByCopy() : nil

        return AXSnapshot(
            appBundleID: bundleID,
            pid: pid,
            focusedWindow: focusedWindow,
            focusedElement: target,
            selectedText: selectedText,
            selectedRange: selectedRange,
            fullValue: fullValue,
            clipboardSelection: clipboardSelection
        )
    }

    static func revalidate(_ capture: AXSnapshot, controlledFixture: Bool) throws {
        let current = try TargetCapture.capture(controlledFixture: false)
        guard current.appBundleID == capture.appBundleID, current.pid == capture.pid else {
            throw EngineError.targetDrift("frontmost application changed")
        }

        if let originalWindow = capture.focusedWindow {
            guard let currentWindow = current.focusedWindow, CFEqual(originalWindow, currentWindow) else {
                throw EngineError.targetDrift("focused window changed")
            }
        }

        if let originalElement = capture.focusedElement {
            guard let currentElement = current.focusedElement, CFEqual(originalElement, currentElement) else {
                throw EngineError.targetDrift("resolved target changed")
            }
        }

        if let originalRange = capture.selectedRange {
            guard let range = current.selectedRange,
                  originalRange.location == range.location,
                  originalRange.length == range.length else {
                throw EngineError.targetDrift("selected range changed")
            }
        }

        if let selected = capture.selectedText, current.selectedText != selected {
            throw EngineError.targetDrift("selected text changed")
        }

        if let copied = capture.clipboardSelection {
            guard controlledFixture else { throw EngineError.targetDrift("clipboard selection requires controlled fixture") }
            guard try SelectionProbe.captureByCopy() == copied else {
                throw EngineError.targetDrift("controlled selection changed")
            }
        }
    }
}

struct ExpectedState {
    let original: String
    let expected: String
    let range: CFRange

    static func from(_ capture: AXSnapshot, replacement: String) -> ExpectedState? {
        guard let original = capture.fullValue,
              let range = capture.selectedRange,
              range.location >= 0,
              range.length >= 0,
              range.location + range.length <= (original as NSString).length else {
            return nil
        }

        let expected = (original as NSString).replacingCharacters(
            in: NSRange(location: range.location, length: range.length),
            with: replacement
        )
        return ExpectedState(original: original, expected: expected, range: range)
    }
}
