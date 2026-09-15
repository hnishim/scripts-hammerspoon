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
}

enum TargetResolver {
    private static let selectorBundles: Set<String> = [
        "sh.zoid.meru",
        "com.tinyspeck.slackmacgap",
    ]

    static func resolve(
        bundleID: String,
        appElement: AXUIElement,
        focusedWindow: AXUIElement?,
        systemFocused: AXUIElement?
    ) -> AXUIElement? {
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
        if let range = AX.rangeAttribute(element, kAXSelectedTextRangeAttribute as CFString), range.length > 0 {
            return true
        }
        if let text = AX.stringAttribute(element, kAXSelectedTextAttribute as CFString), !text.isEmpty {
            return true
        }
        return false
    }
}

enum ProductionTargetCaptureEngine {
    static func capture() throws -> ProductionTargetCapture {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              !bundleID.isEmpty else {
            throw EngineError.noFrontmostApplication
        }

        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        let focusedWindow = AX.elementAttribute(appElement, kAXFocusedWindowAttribute as CFString)
        let systemFocused = AX.elementAttribute(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString
        )
        let target = TargetResolver.resolve(
            bundleID: bundleID,
            appElement: appElement,
            focusedWindow: focusedWindow,
            systemFocused: systemFocused
        )
        let selectedRange = target.flatMap { AX.rangeAttribute($0, kAXSelectedTextRangeAttribute as CFString) }
        let selectedText = target
            .flatMap { AX.stringAttribute($0, kAXSelectedTextAttribute as CFString) }
            .flatMap { $0.isEmpty ? nil : $0 }

        let decision = ProductionTargetPolicy.captureDecision(
            hasAppBundleID: !bundleID.isEmpty,
            hasPID: pid > 0,
            hasFocusedWindow: focusedWindow != nil,
            hasResolvedTarget: target != nil,
            selectedRange: selectedRange
        )
        let eligible = decision == .replacementEligible
        let reason = captureReason(
            pid: pid,
            focusedWindow: focusedWindow,
            target: target,
            selectedRange: selectedRange,
            eligible: eligible
        )

        let selection: String
        if let selectedText {
            selection = selectedText
        } else if let copied = try SelectionProbe.captureByCopy(), !copied.isEmpty {
            selection = copied
        } else {
            throw EngineError.selectionUnavailable
        }

        return ProductionTargetCapture(
            appBundleID: bundleID,
            pid: pid,
            focusedWindow: focusedWindow,
            target: target,
            selectedRange: selectedRange,
            selectedText: selectedText,
            selection: selection,
            replacementEligible: eligible,
            reason: reason
        )
    }

    static func revalidate(_ capture: ProductionTargetCapture) -> TargetPolicyDecision {
        guard capture.replacementEligible,
              let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            return .notReplaced
        }

        let currentPID = app.processIdentifier
        let appElement = AXUIElementCreateApplication(currentPID)
        let focusedWindow = AX.elementAttribute(appElement, kAXFocusedWindowAttribute as CFString)
        let systemFocused = AX.elementAttribute(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString
        )
        let target = TargetResolver.resolve(
            bundleID: bundleID,
            appElement: appElement,
            focusedWindow: focusedWindow,
            systemFocused: systemFocused
        )
        let currentRange = target.flatMap { AX.rangeAttribute($0, kAXSelectedTextRangeAttribute as CFString) }
        let currentSelectedText = target
            .flatMap { AX.stringAttribute($0, kAXSelectedTextAttribute as CFString) }
            .flatMap { $0.isEmpty ? nil : $0 }

        let windowMatches: Bool
        if let capturedWindow = capture.focusedWindow, let focusedWindow {
            windowMatches = CFEqual(capturedWindow, focusedWindow)
        } else {
            windowMatches = false
        }

        let targetMatches: Bool
        if let capturedTarget = capture.target, let target {
            targetMatches = CFEqual(capturedTarget, target)
        } else {
            targetMatches = false
        }

        return ProductionTargetPolicy.revalidationDecision(
            appMatches: bundleID == capture.appBundleID,
            pidMatches: currentPID == capture.pid,
            windowMatches: windowMatches,
            targetMatches: targetMatches,
            capturedRange: capture.selectedRange,
            currentRange: currentRange,
            capturedSelectedText: capture.selectedText,
            currentSelectedText: currentSelectedText
        )
    }

    private static func captureReason(
        pid: pid_t,
        focusedWindow: AXUIElement?,
        target: AXUIElement?,
        selectedRange: CFRange?,
        eligible: Bool
    ) -> String {
        if eligible { return "strong_identity" }
        if pid <= 0 { return "process_identity_unavailable" }
        if focusedWindow == nil { return "focused_window_unavailable" }
        if target == nil { return "resolved_target_unavailable" }
        guard let selectedRange, selectedRange.location >= 0, selectedRange.length > 0 else {
            return "selected_range_unavailable"
        }
        return "identity_unavailable"
    }
}
