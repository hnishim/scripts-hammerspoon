import AppKit
import Foundation
import XCTest
@testable import ReplacementEngine

final class ProductionTargetPolicyTests: XCTestCase {
    func testStrongIdentityIsEligible() {
        let decision = ProductionTargetPolicy.captureDecision(
            hasFocusedWindow: true,
            hasResolvedTarget: true,
            selectedRange: CFRange(location: 4, length: 3)
        )
        XCTAssertEqual(decision, .replacementEligible)
    }

    func testMissingSelectedRangeIsDisplayOnlyEvenWhenSelectionTextExistsElsewhere() {
        let decision = ProductionTargetPolicy.captureDecision(
            hasFocusedWindow: true,
            hasResolvedTarget: true,
            selectedRange: nil
        )
        guard case .displayOnly = decision else {
            return XCTFail("selected-range absence must fail closed to display_only")
        }
    }

    func testSameTextAtDifferentRangeIsNotTheSameTarget() {
        let decision = ProductionTargetPolicy.revalidationDecision(
            appMatches: true,
            pidMatches: true,
            windowMatches: true,
            targetMatches: true,
            capturedRange: CFRange(location: 2, length: 4),
            currentRange: CFRange(location: 20, length: 4),
            capturedSelectedText: "same",
            currentSelectedText: "same"
        )
        guard case .notReplaced = decision else {
            return XCTFail("same text at a different selected range must not authorize mutation")
        }
    }

    func testWindowOrTargetDriftIsNotReplaced() {
        let windowDrift = ProductionTargetPolicy.revalidationDecision(
            appMatches: true,
            pidMatches: true,
            windowMatches: false,
            targetMatches: true,
            capturedRange: CFRange(location: 2, length: 4),
            currentRange: CFRange(location: 2, length: 4),
            capturedSelectedText: "same",
            currentSelectedText: "same"
        )
        let targetDrift = ProductionTargetPolicy.revalidationDecision(
            appMatches: true,
            pidMatches: true,
            windowMatches: true,
            targetMatches: false,
            capturedRange: CFRange(location: 2, length: 4),
            currentRange: CFRange(location: 2, length: 4),
            capturedSelectedText: "same",
            currentSelectedText: "same"
        )
        guard case .notReplaced = windowDrift else { return XCTFail("window drift must fail closed") }
        guard case .notReplaced = targetDrift else { return XCTFail("target drift must fail closed") }
    }

    func testSelectedTextMismatchFailsWhenTextWasCaptured() {
        let decision = ProductionTargetPolicy.revalidationDecision(
            appMatches: true,
            pidMatches: true,
            windowMatches: true,
            targetMatches: true,
            capturedRange: CFRange(location: 2, length: 4),
            currentRange: CFRange(location: 2, length: 4),
            capturedSelectedText: "before",
            currentSelectedText: "after"
        )
        guard case .notReplaced = decision else {
            return XCTFail("captured selected text must still match when available")
        }
    }
}

final class ProductionSessionStateTests: XCTestCase {
    func testEligibleSessionDispatchesOnlyOnceAndUnverifiedDispatchIsTerminal() {
        var session = ProductionSession(replacementEligible: true, ineligibleReason: "")
        XCTAssertEqual(session.acceptReplacement("replacement"), .dispatch("replacement"))
        session.finish(.replacementDispatchedUnverified)
        XCTAssertTrue(session.isTerminal)
        guard case .refuse = session.acceptReplacement("duplicate") else {
            return XCTFail("terminal session must refuse duplicate mutation")
        }
    }

    func testIneligibleCaptureRefusesReplacement() {
        var session = ProductionSession(replacementEligible: false, ineligibleReason: "selected_range_unavailable")
        guard case .refuse = session.acceptReplacement("replacement") else {
            return XCTFail("weak identity must refuse mutation")
        }
    }

    func testCancellationRefusesLaterReplacement() {
        var session = ProductionSession(replacementEligible: true, ineligibleReason: "")
        session.cancel()
        XCTAssertTrue(session.isTerminal)
        guard case .refuse = session.acceptReplacement("stale") else {
            return XCTFail("cancelled session must refuse stale replacement")
        }
    }
}

final class SessionProtocolTests: XCTestCase {
    func testCaptureEventRoundTripsReplacementEligibility() throws {
        let event = SessionCaptureEvent(
            selection: "fixture selection",
            replacementEligible: true,
            reason: "strong_identity"
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(SessionCaptureEvent.self, from: data)
        XCTAssertEqual(decoded, event)
    }

    func testReplacementCommandRoundTripsWithoutProcessArguments() throws {
        let command = SessionReplacementCommand(replacement: "fixture replacement")
        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(SessionReplacementCommand.self, from: data)
        XCTAssertEqual(decoded, command)
    }

    func testTerminalOutcomeRoundTripsFourStateOutcome() throws {
        for outcome in [
            ReplacementOutcome.verifiedReplaced,
            .replacementDispatchedUnverified,
            .notReplaced,
            .error,
        ] {
            let event = SessionOutcomeEvent(outcome: outcome, strategy: .paste, reason: "fixture")
            let data = try JSONEncoder().encode(event)
            let decoded = try JSONDecoder().decode(SessionOutcomeEvent.self, from: data)
            XCTAssertEqual(decoded, event)
        }
    }
}

final class ClipboardTransactionTests: XCTestCase {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("hir235-tests-\(UUID().uuidString)"))
    }

    private func seedRichItem(_ pasteboard: NSPasteboard) -> (String, Data) {
        let text = "prior text"
        let rtf = Data("{\\rtf1 prior text}".utf8)
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(rtf, forType: .rtf)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        return (text, rtf)
    }

    func testRichClipboardRestoresWhenHelperWriteRemainsCurrent() throws {
        let pasteboard = makePasteboard()
        let (text, rtf) = seedRichItem(pasteboard)
        let transaction = try ClipboardTransaction(pasteboard: pasteboard)
        try transaction.writeReplacement("replacement")
        XCTAssertTrue(transaction.restoreIfUntouched())
        XCTAssertEqual(pasteboard.string(forType: .string), text)
        XCTAssertEqual(pasteboard.data(forType: .rtf), rtf)
    }

    func testExternalClipboardChangePreventsRestore() throws {
        let pasteboard = makePasteboard()
        _ = seedRichItem(pasteboard)
        let transaction = try ClipboardTransaction(pasteboard: pasteboard)
        try transaction.writeReplacement("replacement")
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("external change", forType: .string))
        XCTAssertFalse(transaction.restoreIfUntouched())
        XCTAssertEqual(pasteboard.string(forType: .string), "external change")
    }
}
