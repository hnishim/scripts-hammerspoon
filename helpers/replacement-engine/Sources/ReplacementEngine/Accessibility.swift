import AppKit
import ApplicationServices
import Darwin
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

    static func isAttributeSettable(_ element: AXUIElement, _ attribute: CFString) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute, &settable) == .success else { return false }
        return settable.boolValue
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let positionRef = copyAttribute(element, kAXPositionAttribute as CFString),
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              let sizeRef = copyAttribute(element, kAXSizeAttribute as CFString),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        let position = unsafeBitCast(positionRef, to: AXValue.self)
        let size = unsafeBitCast(sizeRef, to: AXValue.self)
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetType(position) == .cgPoint,
              AXValueGetType(size) == .cgSize,
              AXValueGetValue(position, .cgPoint, &origin),
              AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }

    static func pid(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return pid
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
        appFocused: AXUIElement?,
        focusedWindow: AXUIElement?,
        systemFocused: AXUIElement?
    ) -> AXUIElement? {
        guard selectorBundles.contains(bundleID) else { return systemFocused }

        if let appFocused, isTextAreaCandidate(appFocused), hasSelectionContext(appFocused) {
            return appFocused
        }

        if let systemFocused, isTextAreaCandidate(systemFocused), hasSelectionContext(systemFocused) {
            return systemFocused
        }

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
    private struct Candidate {
        let element: AXUIElement
        let snapshot: MagicFieldSnapshot
    }

    static func capture() throws -> ProductionTargetCapture {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              !bundleID.isEmpty else {
            throw EngineError.noFrontmostApplication
        }

        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        let appFocused = AX.elementAttribute(appElement, kAXFocusedUIElementAttribute as CFString)
        let focusedWindow = AX.elementAttribute(appElement, kAXFocusedWindowAttribute as CFString)
        let systemFocused = AX.elementAttribute(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString
        )

        guard let selectionCandidate = selectionCandidate(
            pid: pid,
            appFocused: appFocused,
            systemFocused: systemFocused
        ), !selectionCandidate.snapshot.secure else {
            throw EngineError.selectionUnavailable
        }

        let mutation = mutationCandidate(
            bundleID: bundleID,
            pid: pid,
            appElement: appElement,
            appFocused: appFocused,
            focusedWindow: focusedWindow,
            systemFocused: systemFocused
        )

        let sourceCandidate = mutation ?? selectionCandidate
        let acquisition = try acquireSelection(from: sourceCandidate, pid: pid)
        let replacementEligible = mutation != nil && focusedWindow != nil
        let reason: String
        if replacementEligible {
            reason = "editable_selection"
        } else if sourceCandidate.snapshot.editabilityEvidence == .none {
            reason = "non_editable_selection"
        } else {
            reason = "editable_target_unverified"
        }

        return ProductionTargetCapture(
            appBundleID: bundleID,
            pid: pid,
            focusedWindow: focusedWindow,
            target: mutation?.element,
            targetSnapshot: mutation?.snapshot,
            selectedRange: mutation?.snapshot.selectedRange,
            selectedText: mutation?.snapshot.selectedText,
            selection: acquisition.text,
            selectionSource: acquisition.source,
            selectionEditabilityEvidence: sourceCandidate.snapshot.editabilityEvidence,
            replacementEligible: replacementEligible,
            reason: reason
        )
    }

    static func revalidate(_ capture: ProductionTargetCapture) -> TargetPolicyDecision {
        revalidationResult(capture).decision
    }

    static func revalidationResult(_ capture: ProductionTargetCapture) -> TargetRevalidationResult {
        guard capture.replacementEligible,
              let capturedTarget = capture.target,
              let capturedSnapshot = capture.targetSnapshot,
              let context = currentContext(for: capture) else {
            return TargetRevalidationResult(
                decision: .notReplaced,
                identity: .none,
                fieldState: .unverifiable,
                reason: "context_unavailable"
            )
        }

        guard context.bundleID == capture.appBundleID,
              context.pid == capture.pid,
              windowsMatch(capture.focusedWindow, context.focusedWindow) else {
            return TargetRevalidationResult(
                decision: .notReplaced,
                identity: .none,
                fieldState: .unverifiable,
                reason: "app_or_window_drift"
            )
        }

        let identity = identityKind(
            capturedTarget: capturedTarget,
            capturedSnapshot: capturedSnapshot,
            current: context.mutation
        )
        guard identity != .none, let current = context.mutation else {
            return TargetRevalidationResult(
                decision: .notReplaced,
                identity: .none,
                fieldState: .unverifiable,
                reason: "target_identity_unavailable"
            )
        }

        let fieldState = FieldStatePolicy.validate(
            capturedValue: capturedSnapshot.value,
            currentValue: current.snapshot.value,
            capturedRange: capturedSnapshot.selectedRange,
            currentRange: current.snapshot.selectedRange
        )
        guard fieldState == .stable else {
            let reason = fieldState == .selectionCollapsed
                ? "selection_collapsed_reassert_unverified"
                : "field_state_drift"
            return TargetRevalidationResult(
                decision: .notReplaced,
                identity: identity,
                fieldState: fieldState,
                reason: reason
            )
        }

        return TargetRevalidationResult(
            decision: .replacementEligible,
            identity: identity,
            fieldState: fieldState,
            reason: "stable_target"
        )
    }

    static func identityOnlyKind(_ capture: ProductionTargetCapture) -> TargetIdentityKind {
        guard capture.replacementEligible,
              let capturedTarget = capture.target,
              let capturedSnapshot = capture.targetSnapshot,
              let context = currentContext(for: capture),
              context.bundleID == capture.appBundleID,
              context.pid == capture.pid,
              windowsMatch(capture.focusedWindow, context.focusedWindow) else {
            return .none
        }
        return identityKind(
            capturedTarget: capturedTarget,
            capturedSnapshot: capturedSnapshot,
            current: context.mutation
        )
    }

    static func currentValueIfSameTarget(_ capture: ProductionTargetCapture) -> String? {
        guard capture.replacementEligible,
              let capturedTarget = capture.target,
              let capturedSnapshot = capture.targetSnapshot,
              let context = currentContext(for: capture),
              context.bundleID == capture.appBundleID,
              context.pid == capture.pid,
              windowsMatch(capture.focusedWindow, context.focusedWindow),
              identityKind(
                capturedTarget: capturedTarget,
                capturedSnapshot: capturedSnapshot,
                current: context.mutation
              ) != .none else { return nil }
        return context.mutation?.snapshot.value
    }

    private static func fieldSnapshot(_ element: AXUIElement) -> MagicFieldSnapshot? {
        guard let role = AX.stringAttribute(element, kAXRoleAttribute as CFString) else { return nil }
        let subrole = AX.stringAttribute(element, kAXSubroleAttribute as CFString)
        let secure = role == "AXSecureTextField" || subrole == "AXSecureTextField"
        if secure {
            return MagicFieldSnapshot(
                role: role,
                subrole: subrole,
                frame: AX.frame(element),
                value: nil,
                selectedRange: nil,
                selectedText: nil,
                editabilityEvidence: .none,
                secure: true
            )
        }

        let evidence = EditabilityPolicy.classify(
            role: role,
            valueSettable: AX.isAttributeSettable(element, kAXValueAttribute as CFString)
        )
        let value = AX.stringAttribute(element, kAXValueAttribute as CFString)
        let selectedRange = AX.rangeAttribute(element, kAXSelectedTextRangeAttribute as CFString)
        let selectedText = AX.stringAttribute(element, kAXSelectedTextAttribute as CFString)
            .flatMap { $0.isEmpty ? nil : $0 }

        return MagicFieldSnapshot(
            role: role,
            subrole: subrole,
            frame: AX.frame(element),
            value: value,
            selectedRange: selectedRange,
            selectedText: selectedText,
            editabilityEvidence: evidence,
            secure: false
        )
    }

    private static func selectionCandidate(
        pid: pid_t,
        appFocused: AXUIElement?,
        systemFocused: AXUIElement?
    ) -> Candidate? {
        if let appFocused, AX.pid(appFocused) == pid {
            guard let snapshot = fieldSnapshot(appFocused) else { return nil }
            return Candidate(element: appFocused, snapshot: snapshot)
        }
        if let systemFocused, AX.pid(systemFocused) == pid,
           let snapshot = fieldSnapshot(systemFocused) {
            return Candidate(element: systemFocused, snapshot: snapshot)
        }
        return nil
    }

    private static func mutationCandidate(
        bundleID: String,
        pid: pid_t,
        appElement: AXUIElement,
        appFocused: AXUIElement?,
        focusedWindow: AXUIElement?,
        systemFocused: AXUIElement?
    ) -> Candidate? {
        for element in [appFocused, systemFocused].compactMap({ $0 }) where AX.pid(element) == pid {
            guard let snapshot = fieldSnapshot(element), isMutationCandidate(snapshot) else { continue }
            return Candidate(element: element, snapshot: snapshot)
        }

        guard let resolved = TargetResolver.resolve(
            bundleID: bundleID,
            appElement: appElement,
            appFocused: appFocused,
            focusedWindow: focusedWindow,
            systemFocused: systemFocused
        ), AX.pid(resolved) == pid,
           let snapshot = fieldSnapshot(resolved),
           isMutationCandidate(snapshot) else { return nil }
        return Candidate(element: resolved, snapshot: snapshot)
    }

    private static func isMutationCandidate(_ snapshot: MagicFieldSnapshot) -> Bool {
        guard !snapshot.secure,
              snapshot.editable,
              let range = snapshot.selectedRange,
              range.location >= 0,
              range.length > 0 else { return false }
        return true
    }

    private static func acquireSelection(
        from candidate: Candidate,
        pid: pid_t
    ) throws -> (text: String, source: SelectionSourceKind) {
        if let selectedText = candidate.snapshot.selectedText, !selectedText.isEmpty {
            return (selectedText, .axSelectedText)
        }

        if let selectedRange = candidate.snapshot.selectedRange,
           let value = candidate.snapshot.value,
           let recovered = UTF16RangeCodec.substring(selectedRange, in: value),
           !recovered.isEmpty {
            return (recovered, .axRangeValue)
        }

        guard SelectionAcquisitionPolicy.shouldUseCopyFallback(
            isEditable: candidate.snapshot.editable,
            selectedRange: candidate.snapshot.selectedRange,
            selectionRecovered: false
        ), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw EngineError.selectionUnavailable
        }

        guard let copied = try SelectionProbe.captureByCopy(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              !copied.isEmpty else {
            throw EngineError.selectionUnavailable
        }
        return (copied, .clipboardCopy)
    }

    private static func currentContext(for capture: ProductionTargetCapture) -> (
        bundleID: String,
        pid: pid_t,
        focusedWindow: AXUIElement?,
        mutation: Candidate?
    )? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return nil }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        let appFocused = AX.elementAttribute(appElement, kAXFocusedUIElementAttribute as CFString)
        let focusedWindow = AX.elementAttribute(appElement, kAXFocusedWindowAttribute as CFString)
        let systemFocused = AX.elementAttribute(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString
        )
        let mutation = mutationCandidate(
            bundleID: bundleID,
            pid: pid,
            appElement: appElement,
            appFocused: appFocused,
            focusedWindow: focusedWindow,
            systemFocused: systemFocused
        )
        return (bundleID, pid, focusedWindow, mutation)
    }

    private static func windowsMatch(_ captured: AXUIElement?, _ current: AXUIElement?) -> Bool {
        guard let captured, let current else { return false }
        return CFEqual(captured, current)
    }

    private static func identityKind(
        capturedTarget: AXUIElement,
        capturedSnapshot: MagicFieldSnapshot,
        current: Candidate?
    ) -> TargetIdentityKind {
        guard let current else { return .none }
        if CFEqual(capturedTarget, current.element) { return .exact }
        return StructuralIdentityPolicy.matches(captured: capturedSnapshot, current: current.snapshot)
            ? .structural
            : .none
    }
}
