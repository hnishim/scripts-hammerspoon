import Carbon.HIToolbox
import CoreGraphics
import Foundation

struct ProductionReplacementResult {
    let outcome: ReplacementOutcome
    let strategy: Strategy?
    let reason: String
}

enum ProductionReplacementEngine {
    static func replace(
        capture: ProductionTargetCapture,
        replacement: String,
        pasteHoldMilliseconds: Int = 150
    ) -> ProductionReplacementResult {
        guard capture.replacementEligible,
              ProductionTargetCaptureEngine.revalidate(capture) == .replacementEligible else {
            return ProductionReplacementResult(
                outcome: .notReplaced,
                strategy: nil,
                reason: "target_revalidation_failed"
            )
        }

        do {
            let transaction = try ClipboardTransaction()
            do {
                try transaction.writeReplacement(replacement)
                try KeyEvents.chord(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
            } catch {
                _ = transaction.restoreIfUntouched()
                return ProductionReplacementResult(
                    outcome: .error,
                    strategy: .paste,
                    reason: "paste_dispatch_failed"
                )
            }

            if pasteHoldMilliseconds > 0 {
                Thread.sleep(forTimeInterval: Double(pasteHoldMilliseconds) / 1000.0)
            }
            let restored = transaction.restoreIfUntouched()
            return ProductionReplacementResult(
                outcome: .replacementDispatchedUnverified,
                strategy: .paste,
                reason: restored ? "paste_dispatched_unverified" : "paste_dispatched_clipboard_changed"
            )
        } catch {
            return ProductionReplacementResult(
                outcome: .error,
                strategy: .paste,
                reason: "clipboard_transaction_failed"
            )
        }
    }
}

struct ProductionReplacementSessionRunner {
    func run() throws {
        let capture = try ProductionTargetCaptureEngine.capture()
        try writeJSONLine(SessionCaptureEvent(
            selection: capture.selection,
            replacementEligible: capture.replacementEligible,
            reason: capture.reason
        ))

        var session = ProductionSession(
            replacementEligible: capture.replacementEligible,
            ineligibleReason: capture.reason
        )

        guard let line = readLine(),
              let data = line.data(using: .utf8),
              let command = try? JSONDecoder().decode(SessionReplacementCommand.self, from: data) else {
            session.finish(.error)
            try writeJSONLine(SessionOutcomeEvent(
                outcome: .error,
                strategy: nil,
                reason: "invalid_replacement_command"
            ))
            return
        }

        switch session.acceptReplacement(command.replacement) {
        case .refuse:
            session.finish(.notReplaced)
            try writeJSONLine(SessionOutcomeEvent(
                outcome: .notReplaced,
                strategy: nil,
                reason: capture.replacementEligible ? "duplicate_replacement_refused" : capture.reason
            ))
        case .dispatch(let replacement):
            let result = ProductionReplacementEngine.replace(capture: capture, replacement: replacement)
            session.finish(result.outcome)
            try writeJSONLine(SessionOutcomeEvent(
                outcome: result.outcome,
                strategy: result.strategy,
                reason: result.reason
            ))
        }
    }
}
