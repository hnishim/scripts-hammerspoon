import ApplicationServices
import Darwin
import Foundation

enum ReplacementOutcome: String, Codable, Equatable {
    case verifiedReplaced = "verified_replaced"
    case replacementDispatchedUnverified = "replacement_dispatched_unverified"
    case notReplaced = "not_replaced"
    case error
}

enum Strategy: String, Codable, Equatable {
    case paste = "clipboard_cmd_v"
}

enum TargetPolicyDecision: Equatable {
    case replacementEligible
    case displayOnly
    case notReplaced
}

enum ReplacementDispatchDecision: Equatable {
    case dispatch(String)
    case refuse
}

enum ProductionTargetPolicy {
    static func captureDecision(
        hasAppBundleID: Bool = true,
        hasPID: Bool = true,
        hasFocusedWindow: Bool,
        hasResolvedTarget: Bool,
        selectedRange: CFRange?
    ) -> TargetPolicyDecision {
        guard hasAppBundleID, hasPID, hasFocusedWindow, hasResolvedTarget,
              let selectedRange,
              selectedRange.location >= 0,
              selectedRange.length > 0 else {
            return .displayOnly
        }
        return .replacementEligible
    }

    static func revalidationDecision(
        appMatches: Bool,
        pidMatches: Bool,
        windowMatches: Bool,
        targetMatches: Bool,
        capturedRange: CFRange?,
        currentRange: CFRange?,
        capturedSelectedText: String?,
        currentSelectedText: String?
    ) -> TargetPolicyDecision {
        guard appMatches, pidMatches, windowMatches, targetMatches,
              let capturedRange,
              let currentRange,
              capturedRange.location >= 0,
              capturedRange.length > 0,
              capturedRange.location == currentRange.location,
              capturedRange.length == currentRange.length else {
            return .notReplaced
        }
        if let capturedSelectedText, currentSelectedText != capturedSelectedText {
            return .notReplaced
        }
        return .replacementEligible
    }
}

struct ProductionSession {
    private(set) var isTerminal = false
    private var replacementAccepted = false
    let replacementEligible: Bool
    let ineligibleReason: String

    init(replacementEligible: Bool, ineligibleReason: String) {
        self.replacementEligible = replacementEligible
        self.ineligibleReason = ineligibleReason
    }

    mutating func acceptReplacement(_ replacement: String) -> ReplacementDispatchDecision {
        guard !isTerminal, replacementEligible, !replacementAccepted else { return .refuse }
        replacementAccepted = true
        return .dispatch(replacement)
    }

    mutating func finish(_ outcome: ReplacementOutcome) {
        _ = outcome
        isTerminal = true
    }

    mutating func cancel() {
        isTerminal = true
    }
}

struct SessionCaptureEvent: Codable, Equatable {
    let event: String
    let selection: String
    let replacementEligible: Bool
    let reason: String

    init(selection: String, replacementEligible: Bool, reason: String) {
        self.event = "capture"
        self.selection = selection
        self.replacementEligible = replacementEligible
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case event
        case selection
        case replacementEligible = "replacement_eligible"
        case reason
    }
}

struct SessionReplacementCommand: Codable, Equatable {
    let replacement: String
}

struct SessionOutcomeEvent: Codable, Equatable {
    let event: String
    let outcome: ReplacementOutcome
    let strategy: Strategy?
    let reason: String

    init(outcome: ReplacementOutcome, strategy: Strategy?, reason: String) {
        self.event = "outcome"
        self.outcome = outcome
        self.strategy = strategy
        self.reason = reason
    }
}

enum EngineError: Error {
    case noFrontmostApplication
    case selectionUnavailable
    case clipboardUnavailable
    case eventCreationFailed
    case protocolFailure
}

struct ProductionTargetCapture {
    let appBundleID: String
    let pid: pid_t
    let focusedWindow: AXUIElement?
    let target: AXUIElement?
    let targetSnapshot: MagicFieldSnapshot?
    let selectedRange: CFRange?
    let selectedText: String?
    let selection: String
    let selectionSource: SelectionSourceKind
    let selectionEditabilityEvidence: EditabilityEvidenceKind
    let replacementEligible: Bool
    let reason: String
}

func writeJSONLine<T: Encodable>(_ value: T) throws {
    let data = try JSONEncoder().encode(value)
    guard var line = String(data: data, encoding: .utf8) else { throw EngineError.protocolFailure }
    line.append("\n")
    guard let encoded = line.data(using: .utf8) else { throw EngineError.protocolFailure }
    FileHandle.standardOutput.write(encoded)
}
