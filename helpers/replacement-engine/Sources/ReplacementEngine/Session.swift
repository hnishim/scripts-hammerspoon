import Carbon.HIToolbox
import CoreGraphics
import Foundation

struct ProductionReplacementResult {
    let outcome: ReplacementOutcome
    let strategy: Strategy?
    let reason: String
}

enum ReplacementDiagnostic {
    private static let path = "/tmp/hir-235-replacement.log"
    private static let marker = "hir258-magic-model-poc-v1"

    static func recordCapture(_ capture: ProductionTargetCapture) {
        let line = "marker=\(marker) stage=capture app=\(capture.appBundleID) eligible=\(capture.replacementEligible) source=\(capture.selectionSource.rawValue) editability=\(capture.selectionEditabilityEvidence.rawValue) reason=\(capture.reason)\n"
        FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
    }

    static func recordOutcome(outcome: ReplacementOutcome, strategy: Strategy?, reason: String) {
        let strategyValue = strategy?.rawValue ?? "none"
        append("marker=\(marker) stage=outcome outcome=\(outcome.rawValue) strategy=\(strategyValue) reason=\(reason)\n")
    }

    private static func append(_ line: String) {
        let data = Data(line.utf8)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    }
}

enum ProductionReplacementEngine {
    static func mayDispatch(_ revalidation: TargetRevalidationResult) -> Bool {
        revalidation.decision == .replacementEligible
            && revalidation.identity != .none
            && revalidation.fieldState == .stable
    }

    static func replace(
        capture: ProductionTargetCapture,
        replacement: String,
        pasteHoldMilliseconds: Int = 150,
        confirmationMilliseconds: Int = 300
    ) -> ProductionReplacementResult {
        let revalidation = ProductionTargetCaptureEngine.revalidationResult(capture)
        guard capture.replacementEligible,
              mayDispatch(revalidation) else {
            return ProductionReplacementResult(
                outcome: .notReplaced,
                strategy: nil,
                reason: revalidation.reason
            )
        }

        do {
            let transaction = try ClipboardTransaction()
            let postSnapshotRevalidation = ProductionTargetCaptureEngine.revalidationResult(capture)
            guard mayDispatch(postSnapshotRevalidation) else {
                return ProductionReplacementResult(
                    outcome: .notReplaced,
                    strategy: nil,
                    reason: "post_snapshot_\(postSnapshotRevalidation.reason)"
                )
            }

            do {
                try transaction.writeReplacement(replacement)
                let prePasteRevalidation = ProductionTargetCaptureEngine.revalidationResult(capture)
                guard mayDispatch(prePasteRevalidation) else {
                    _ = transaction.restoreIfUntouched()
                    return ProductionReplacementResult(
                        outcome: .notReplaced,
                        strategy: nil,
                        reason: "pre_paste_\(prePasteRevalidation.reason)"
                    )
                }
                try KeyEvents.chord(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
            } catch {
                _ = transaction.restoreIfUntouched()
                return ProductionReplacementResult(
                    outcome: .error,
                    strategy: .paste,
                    reason: "paste_dispatch_failed"
                )
            }

            let dispatchTime = Date()
            let expectedValue = capture.targetSnapshot
                .flatMap { snapshot -> String? in
                    guard let value = snapshot.value, let range = snapshot.selectedRange else { return nil }
                    return UTF16RangeCodec.replacing(range, in: value, with: replacement)
                }
            let shouldConfirm = expectedValue != nil && expectedValue != capture.targetSnapshot?.value
            var confirmed = false
            if shouldConfirm, let expectedValue {
                let deadline = Date().addingTimeInterval(Double(max(0, confirmationMilliseconds)) / 1000.0)
                repeat {
                    if ProductionTargetCaptureEngine.currentValueIfSameTarget(capture) == expectedValue {
                        confirmed = true
                        break
                    }
                    if Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.02)
                    }
                } while Date() < deadline
            }

            let elapsed = Date().timeIntervalSince(dispatchTime)
            let minimumHold = Double(max(0, pasteHoldMilliseconds)) / 1000.0
            if elapsed < minimumHold {
                Thread.sleep(forTimeInterval: minimumHold - elapsed)
            }

            let restored = transaction.restoreIfUntouched()
            let outcome: ReplacementOutcome = confirmed
                ? .verifiedReplaced
                : .replacementDispatchedUnverified
            let baseReason = confirmed ? "paste_verified" : "paste_dispatched_unverified"
            return ProductionReplacementResult(
                outcome: outcome,
                strategy: .paste,
                reason: restored ? baseReason : "\(baseReason)_clipboard_changed"
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
        ReplacementDiagnostic.recordCapture(capture)
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
            ReplacementDiagnostic.recordOutcome(
                outcome: .error,
                strategy: nil,
                reason: "invalid_replacement_command"
            )
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
            let reason = capture.replacementEligible ? "duplicate_replacement_refused" : capture.reason
            ReplacementDiagnostic.recordOutcome(
                outcome: .notReplaced,
                strategy: nil,
                reason: reason
            )
            try writeJSONLine(SessionOutcomeEvent(
                outcome: .notReplaced,
                strategy: nil,
                reason: reason
            ))
        case .dispatch(let replacement):
            let result = ProductionReplacementEngine.replace(capture: capture, replacement: replacement)
            session.finish(result.outcome)
            ReplacementDiagnostic.recordOutcome(
                outcome: result.outcome,
                strategy: result.strategy,
                reason: result.reason
            )
            try writeJSONLine(SessionOutcomeEvent(
                outcome: result.outcome,
                strategy: result.strategy,
                reason: result.reason
            ))
        }
    }
}
