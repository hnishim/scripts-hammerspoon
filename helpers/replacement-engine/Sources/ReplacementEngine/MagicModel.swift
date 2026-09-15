import CoreGraphics
import Foundation

enum SelectionSourceKind: String, Equatable {
    case axSelectedText = "ax_selected_text"
    case axRangeValue = "ax_range_value"
    case clipboardCopy = "clipboard_copy"
}

enum EditabilityEvidenceKind: String, Equatable {
    case role
    case valueSettable = "value_settable"
    case none
}

enum TargetIdentityKind: String, Equatable {
    case exact
    case structural
    case none
}

enum FieldStateValidation: String, Equatable {
    case stable
    case selectionCollapsed = "selection_collapsed"
    case drift
    case unverifiable
}

struct MagicFieldSnapshot {
    let role: String
    let subrole: String?
    let frame: CGRect?
    let value: String?
    let selectedRange: CFRange?
    let selectedText: String?
    let editabilityEvidence: EditabilityEvidenceKind
    let secure: Bool

    var editable: Bool { editabilityEvidence != .none }
}

enum EditabilityPolicy {
    private static let editableRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXComboBox", "AXSearchField",
    ]

    static func classify(role: String, valueSettable: Bool) -> EditabilityEvidenceKind {
        if editableRoles.contains(role) { return .role }
        if valueSettable { return .valueSettable }
        return .none
    }
}

enum UTF16RangeCodec {
    static func stringRange(_ range: CFRange, in value: String) -> Range<String.Index>? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        return Range(NSRange(location: range.location, length: range.length), in: value)
    }

    static func substring(_ range: CFRange, in value: String) -> String? {
        guard range.length > 0, let stringRange = stringRange(range, in: value) else { return nil }
        return String(value[stringRange])
    }

    static func replacing(_ range: CFRange, in value: String, with replacement: String) -> String? {
        guard range.length > 0, let stringRange = stringRange(range, in: value) else { return nil }
        var result = value
        result.replaceSubrange(stringRange, with: replacement)
        return result
    }
}

enum SelectionAcquisitionPolicy {
    static func shouldUseCopyFallback(
        isEditable: Bool,
        selectedRange: CFRange?,
        selectionRecovered: Bool
    ) -> Bool {
        guard !selectionRecovered else { return false }
        if isEditable {
            return selectedRange.map { $0.location >= 0 && $0.length > 0 } ?? false
        }
        return true
    }
}

enum StructuralIdentityPolicy {
    static func framesAgree(_ lhs: CGRect?, _ rhs: CGRect?, tolerance: CGFloat = 1) -> Bool {
        guard let lhs, let rhs else { return false }
        return abs(lhs.minX - rhs.minX) < tolerance
            && abs(lhs.minY - rhs.minY) < tolerance
            && abs(lhs.width - rhs.width) < tolerance
            && abs(lhs.height - rhs.height) < tolerance
    }

    static func matches(captured: MagicFieldSnapshot, current: MagicFieldSnapshot) -> Bool {
        guard captured.role == current.role,
              captured.subrole == current.subrole else { return false }
        return framesAgree(captured.frame, current.frame)
    }
}

enum FieldStatePolicy {
    static func validate(
        capturedValue: String?,
        currentValue: String?,
        capturedRange: CFRange?,
        currentRange: CFRange?
    ) -> FieldStateValidation {
        guard let capturedValue, let currentValue,
              let capturedRange, let currentRange,
              capturedRange.location >= 0, capturedRange.length > 0,
              currentRange.location >= 0 else {
            return .unverifiable
        }
        guard capturedValue == currentValue else { return .drift }
        if capturedRange.location == currentRange.location,
           capturedRange.length == currentRange.length {
            return .stable
        }
        if currentRange.length == 0 {
            let lower = capturedRange.location
            let upper = capturedRange.location + capturedRange.length
            if currentRange.location == lower || currentRange.location == upper {
                return .selectionCollapsed
            }
        }
        return .drift
    }
}

enum SelectionReassertionPolicy {
    static func canReassert(
        identity: TargetIdentityKind,
        fieldState: FieldStateValidation,
        capturedValue: String?,
        selectedRange: CFRange?
    ) -> Bool {
        guard identity != .none,
              fieldState == .selectionCollapsed,
              let capturedValue,
              let selectedRange,
              selectedRange.location >= 0,
              selectedRange.length > 0 else { return false }
        return UTF16RangeCodec.stringRange(selectedRange, in: capturedValue) != nil
    }
}

struct TargetRevalidationResult: Equatable {
    let decision: TargetPolicyDecision
    let identity: TargetIdentityKind
    let fieldState: FieldStateValidation
    let reason: String
}
