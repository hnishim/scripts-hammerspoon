import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

struct StrategyResult { let outcome: AttemptOutcome; let verification: String; let reason: String }

final class ReplacementEngine {
    private let options: Options
    private let replacement: String
    private let logger: StructuredLogger
    private var attempts: [AttemptLog] = []

    init(options: Options, replacement: String) { self.options = options; self.replacement = replacement; self.logger = StructuredLogger(path: options.logPath) }

    func run() -> ReplacementOutcome {
        let totalStart = DispatchTime.now()
        var bundle = "unknown"
        var final: ReplacementOutcome = .error
        var finalStrategy: Strategy?
        var reason = "unhandled_error"
        let order = strategyOrder()
        do {
            guard options.controlledFixture else { throw EngineError.uncontrolledMutationDenied }
            let capture = try TargetCapture.capture(controlledFixture: true); bundle = capture.appBundleID
            guard capture.hasSelectionContext else { throw EngineError.accessibilityUnavailable("no selected-text context") }
            if options.delayMilliseconds > 0 { Thread.sleep(forTimeInterval: Double(options.delayMilliseconds) / 1000.0) }
            try TargetCapture.revalidate(capture, controlledFixture: true)
            for strategy in order {
                let start = DispatchTime.now()
                let result: StrategyResult
                do { try TargetCapture.revalidate(capture, controlledFixture: true); result = try execute(strategy, capture: capture) }
                catch let error as EngineError { result = StrategyResult(outcome: .error, verification: "not_verified", reason: sanitize(error.description)) }
                catch { result = StrategyResult(outcome: .error, verification: "not_verified", reason: "unexpected_error") }
                attempts.append(AttemptLog(strategy: strategy, outcome: result.outcome, verification: result.verification, reason: result.reason, elapsedMilliseconds: elapsedMilliseconds(since: start)))
                switch result.outcome {
                case .verified: final = .verifiedReplaced; finalStrategy = strategy; reason = result.reason
                case .dispatchedUnverified: final = .replacementDispatchedUnverified; finalStrategy = strategy; reason = result.reason
                case .error: final = .error; finalStrategy = strategy; reason = result.reason
                case .noOp, .unavailable, .skipped: continue
                }
                finish(totalStart, bundle, order, final, finalStrategy, reason); emitOutcome(final, strategy: finalStrategy, reason: reason); return final
            }
            final = .notReplaced; reason = "all_strategies_exhausted_without_mutation"
        } catch let error as EngineError { final = .error; reason = sanitize(error.description) }
        catch { final = .error; reason = "unexpected_error" }
        finish(totalStart, bundle, order, final, finalStrategy, reason); emitOutcome(final, strategy: finalStrategy, reason: reason); return final
    }

    private func strategyOrder() -> [Strategy] {
        let all = Strategy.allCases
        switch options.mode {
        case .normal: return all
        case .single: return options.strategy.map { [$0] } ?? []
        case .from:
            guard let strategy = options.strategy, let index = all.firstIndex(of: strategy) else { return [] }
            return Array(all[index...])
        }
    }

    private func execute(_ strategy: Strategy, capture: AXSnapshot) throws -> StrategyResult {
        switch strategy {
        case .axSelectedText: return try axSelectedText(capture)
        case .axValueRange: return try axValueRange(capture)
        case .paste: return try paste(capture, matchStyle: false)
        case .pasteMatchStyle: return try paste(capture, matchStyle: true)
        case .unicodeInjection: return try unicode(capture, chunked: false)
        case .chunkedInjection: return try unicode(capture, chunked: true)
        }
    }

    private func axSelectedText(_ capture: AXSnapshot) throws -> StrategyResult {
        guard let element = capture.focusedElement, AX.isSettable(element, kAXSelectedTextAttribute as CFString), let expected = ExpectedState.from(capture, replacement: replacement) else { return StrategyResult(outcome: .unavailable, verification: "capability_gate", reason: "ax_selected_text_not_safely_verifiable") }
        let error = AX.setString(element, kAXSelectedTextAttribute as CFString, value: replacement)
        guard error == .success else { return StrategyResult(outcome: .error, verification: "ax_error", reason: "ax_selected_text_write_error_\(error.rawValue)") }
        return verifySync(element, expected, "exact_ax_value_match", "exact_unchanged_after_ax_write")
    }

    private func axValueRange(_ capture: AXSnapshot) throws -> StrategyResult {
        guard let element = capture.focusedElement, AX.isSettable(element, kAXValueAttribute as CFString), let expected = ExpectedState.from(capture, replacement: replacement) else { return StrategyResult(outcome: .unavailable, verification: "capability_gate", reason: "ax_value_range_not_safely_available") }
        let error = AX.setString(element, kAXValueAttribute as CFString, value: expected.expected)
        guard error == .success else { return StrategyResult(outcome: .error, verification: "ax_error", reason: "ax_value_write_error_\(error.rawValue)") }
        let caret = CFRange(location: expected.range.location + (replacement as NSString).length, length: 0)
        if AX.isSettable(element, kAXSelectedTextRangeAttribute as CFString) { _ = AX.setRange(element, kAXSelectedTextRangeAttribute as CFString, value: caret) }
        return verifySync(element, expected, "exact_ax_value_match", "exact_unchanged_after_ax_value_write")
    }

    private func paste(_ capture: AXSnapshot, matchStyle: Bool) throws -> StrategyResult {
        let transaction = try ClipboardTransaction()
        defer { _ = transaction.restoreIfUntouched() }
        try transaction.writeReplacement(replacement)
        let flags: CGEventFlags = matchStyle ? [.maskCommand, .maskAlternate, .maskShift] : .maskCommand
        try KeyEvents.chord(keyCode: CGKeyCode(kVK_ANSI_V), flags: flags)
        return verifyEvent(capture, matchStyle ? "exact_postcondition_after_match_style" : "exact_postcondition_after_paste", matchStyle ? "match_style_dispatched_postcondition_unverified" : "paste_dispatched_postcondition_unverified")
    }

    private func unicode(_ capture: AXSnapshot, chunked: Bool) throws -> StrategyResult {
        if chunked {
            let characters = Array(replacement); var cursor = 0
            while cursor < characters.count {
                let end = min(cursor + options.chunkSize, characters.count); try KeyEvents.unicode(String(characters[cursor..<end])); cursor = end
                if cursor < characters.count && options.chunkDelayMilliseconds > 0 { Thread.sleep(forTimeInterval: Double(options.chunkDelayMilliseconds) / 1000.0) }
            }
        } else { try KeyEvents.unicode(replacement) }
        return verifyEvent(capture, chunked ? "exact_postcondition_after_chunked_injection" : "exact_postcondition_after_unicode_injection", chunked ? "chunked_injection_dispatched_postcondition_unverified" : "unicode_injection_dispatched_postcondition_unverified")
    }

    private func verifySync(_ element: AXUIElement, _ expected: ExpectedState, _ success: String, _ noOp: String) -> StrategyResult {
        let deadline = Date().addingTimeInterval(Double(options.verificationTimeoutMilliseconds) / 1000.0)
        while true {
            guard let observed = AX.stringAttribute(element, kAXValueAttribute as CFString) else { return StrategyResult(outcome: .dispatchedUnverified, verification: "mismatch_or_unreadable", reason: "ax_mutation_result_unverified") }
            if observed == expected.expected { return StrategyResult(outcome: .verified, verification: "exact_ax_value", reason: success) }
            if observed != expected.original { return StrategyResult(outcome: .dispatchedUnverified, verification: "mismatch_or_unreadable", reason: "ax_mutation_result_unverified") }
            if Date() >= deadline { return StrategyResult(outcome: .noOp, verification: "exact_unchanged_bounded_poll", reason: noOp) }
            Thread.sleep(forTimeInterval: Double(options.pollIntervalMilliseconds) / 1000.0)
        }
    }

    private func verifyEvent(_ capture: AXSnapshot, _ success: String, _ unverified: String) -> StrategyResult {
        guard let element = capture.focusedElement, let expected = ExpectedState.from(capture, replacement: replacement) else { return StrategyResult(outcome: .dispatchedUnverified, verification: "postcondition_unavailable", reason: unverified) }
        let deadline = Date().addingTimeInterval(Double(options.verificationTimeoutMilliseconds) / 1000.0)
        while Date() <= deadline {
            if AX.stringAttribute(element, kAXValueAttribute as CFString) == expected.expected { return StrategyResult(outcome: .verified, verification: "exact_ax_value", reason: success) }
            Thread.sleep(forTimeInterval: Double(options.pollIntervalMilliseconds) / 1000.0)
        }
        return StrategyResult(outcome: .dispatchedUnverified, verification: "bounded_poll_no_exact_match", reason: unverified)
    }

    private func finish(_ start: DispatchTime, _ bundle: String, _ order: [Strategy], _ outcome: ReplacementOutcome, _ strategy: Strategy?, _ reason: String) {
        do {
            try logger.append(RunLog(timestamp: ISO8601DateFormatter().string(from: Date()), appBundleID: bundle, attemptOrder: order, attempts: attempts, totalElapsedMilliseconds: elapsedMilliseconds(since: start), finalOutcome: outcome, finalStrategy: strategy, finalReason: reason))
        } catch {
            FileHandle.standardError.write(Data("structured_log_failed\n".utf8))
        }
    }
}
