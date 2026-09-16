import CoreGraphics
import Foundation
import XCTest
@testable import ReplacementEngine

final class EditabilityPolicyTests: XCTestCase {
    func testKnownEditableRoleWinsWithoutSettableValue() {
        XCTAssertEqual(
            EditabilityPolicy.classify(role: "AXTextArea", valueSettable: false),
            .role
        )
    }

    func testSettableValueMakesOddRoleEditable() {
        XCTAssertEqual(
            EditabilityPolicy.classify(role: "AXGroup", valueSettable: true),
            .valueSettable
        )
    }

    func testUnknownNonSettableRoleIsNotEditable() {
        XCTAssertEqual(
            EditabilityPolicy.classify(role: "AXGroup", valueSettable: false),
            .none
        )
    }
}

final class UTF16RangeCodecTests: XCTestCase {
    func testRangeAfterEmojiRecoversExactSubstring() {
        let value = "A😀BC"
        let selected = "BC"
        let nsRange = (value as NSString).range(of: selected)
        let range = CFRange(location: nsRange.location, length: nsRange.length)
        XCTAssertEqual(UTF16RangeCodec.substring(range, in: value), selected)
        XCTAssertEqual(UTF16RangeCodec.replacing(range, in: value, with: "Z"), "A😀Z")
    }

    func testRangeAfterZWJAndCombiningSequenceRecoversExactSubstring() {
        let value = "👨‍👩‍👧‍👦 e\u{301} target"
        let selected = "target"
        let nsRange = (value as NSString).range(of: selected)
        let range = CFRange(location: nsRange.location, length: nsRange.length)
        XCTAssertEqual(UTF16RangeCodec.substring(range, in: value), selected)
    }

    func testMidSurrogateRangeIsRejected() {
        let value = "😀x"
        XCTAssertNil(UTF16RangeCodec.substring(CFRange(location: 1, length: 1), in: value))
    }

    func testOutOfBoundsRangeIsRejected() {
        XCTAssertNil(UTF16RangeCodec.substring(CFRange(location: 99, length: 1), in: "short"))
    }
}

final class SelectionAcquisitionPolicyTests: XCTestCase {
    func testEditableDraftWithoutPositiveRangeNeverUsesCopyFallback() {
        XCTAssertFalse(SelectionAcquisitionPolicy.shouldUseCopyFallback(
            isEditable: true,
            selectedRange: CFRange(location: 4, length: 0),
            selectionRecovered: false
        ))
    }

    func testEditablePositiveRangeMayUseCopyFallback() {
        XCTAssertTrue(SelectionAcquisitionPolicy.shouldUseCopyFallback(
            isEditable: true,
            selectedRange: CFRange(location: 4, length: 3),
            selectionRecovered: false
        ))
    }

    func testNonEditableSurfaceMayUseCopyFallbackWithoutRange() {
        XCTAssertTrue(SelectionAcquisitionPolicy.shouldUseCopyFallback(
            isEditable: false,
            selectedRange: nil,
            selectionRecovered: false
        ))
    }

    func testRecoveredSelectionNeverUsesCopyFallback() {
        XCTAssertFalse(SelectionAcquisitionPolicy.shouldUseCopyFallback(
            isEditable: false,
            selectedRange: nil,
            selectionRecovered: true
        ))
    }
}

final class StructuralIdentityPolicyTests: XCTestCase {
    private func snapshot(
        role: String = "AXTextArea",
        subrole: String? = nil,
        frame: CGRect?
    ) -> MagicFieldSnapshot {
        MagicFieldSnapshot(
            role: role,
            subrole: subrole,
            frame: frame,
            value: "same text",
            selectedRange: CFRange(location: 0, length: 4),
            selectedText: "same",
            editabilityEvidence: .role,
            secure: false
        )
    }

    func testRoleSubroleAndNearEqualFrameAllowStructuralIdentity() {
        let captured = snapshot(frame: CGRect(x: 10, y: 20, width: 300, height: 40))
        let current = snapshot(frame: CGRect(x: 10.4, y: 20.4, width: 300.4, height: 40.4))
        XCTAssertTrue(StructuralIdentityPolicy.matches(captured: captured, current: current))
    }

    func testSameTextWithoutGeometryDoesNotEstablishIdentity() {
        let captured = snapshot(frame: nil)
        let current = snapshot(frame: nil)
        XCTAssertFalse(StructuralIdentityPolicy.matches(captured: captured, current: current))
    }

    func testDifferentRoleFailsEvenWithSameFrame() {
        let frame = CGRect(x: 10, y: 20, width: 300, height: 40)
        let captured = snapshot(frame: frame)
        let current = snapshot(role: "AXTextField", frame: frame)
        XCTAssertFalse(StructuralIdentityPolicy.matches(captured: captured, current: current))
    }
}

final class FieldStatePolicyTests: XCTestCase {
    private let capturedRange = CFRange(location: 2, length: 4)

    func testSameValueAndRangeIsStable() {
        XCTAssertEqual(FieldStatePolicy.validate(
            capturedValue: "abcdefgh",
            currentValue: "abcdefgh",
            capturedRange: capturedRange,
            currentRange: CFRange(location: 2, length: 4)
        ), .stable)
    }

    func testTypingOrDeletionIsDrift() {
        XCTAssertEqual(FieldStatePolicy.validate(
            capturedValue: "abcdefgh",
            currentValue: "abcdefghi",
            capturedRange: capturedRange,
            currentRange: CFRange(location: 2, length: 4)
        ), .drift)
        XCTAssertEqual(FieldStatePolicy.validate(
            capturedValue: "abcdefgh",
            currentValue: "abcdefg",
            capturedRange: capturedRange,
            currentRange: CFRange(location: 2, length: 4)
        ), .drift)
    }

    func testDifferentLiveSelectionIsDriftEvenWithSameTextValue() {
        XCTAssertEqual(FieldStatePolicy.validate(
            capturedValue: "abcdefgh",
            currentValue: "abcdefgh",
            capturedRange: capturedRange,
            currentRange: CFRange(location: 3, length: 4)
        ), .drift)
    }

    func testCollapsedSelectionAtCapturedBoundaryIsDistinguished() {
        XCTAssertEqual(FieldStatePolicy.validate(
            capturedValue: "abcdefgh",
            currentValue: "abcdefgh",
            capturedRange: capturedRange,
            currentRange: CFRange(location: 6, length: 0)
        ), .selectionCollapsed)
    }

    func testUnreadableValueIsUnverifiableNotStable() {
        XCTAssertEqual(FieldStatePolicy.validate(
            capturedValue: nil,
            currentValue: nil,
            capturedRange: capturedRange,
            currentRange: capturedRange
        ), .unverifiable)
    }
}

final class SelectionReassertionPolicyTests: XCTestCase {
    func testCollapsedSelectionCanOnlyBeCandidateWithIdentityAndValidUTF16Range() {
        XCTAssertTrue(SelectionReassertionPolicy.canReassert(
            identity: .exact,
            fieldState: .selectionCollapsed,
            capturedValue: "A😀BC",
            selectedRange: CFRange(location: 3, length: 2)
        ))
        XCTAssertFalse(SelectionReassertionPolicy.canReassert(
            identity: .none,
            fieldState: .selectionCollapsed,
            capturedValue: "A😀BC",
            selectedRange: CFRange(location: 3, length: 2)
        ))
    }

    func testInvalidUTF16RangeCannotBeReasserted() {
        XCTAssertFalse(SelectionReassertionPolicy.canReassert(
            identity: .structural,
            fieldState: .selectionCollapsed,
            capturedValue: "😀x",
            selectedRange: CFRange(location: 1, length: 1)
        ))
    }
}

final class ReviewFindingRegressionTests: XCTestCase {
    private func snapshot(
        role: String = "AXTextArea",
        frame: CGRect = CGRect(x: 10, y: 20, width: 300, height: 40),
        value: String? = "alpha beta",
        selectedRange: CFRange? = CFRange(location: 6, length: 4),
        selectedText: String? = "beta",
        editabilityEvidence: EditabilityEvidenceKind = .role
    ) -> MagicFieldSnapshot {
        MagicFieldSnapshot(
            role: role,
            subrole: nil,
            frame: frame,
            value: value,
            selectedRange: selectedRange,
            selectedText: selectedText,
            editabilityEvidence: editabilityEvidence,
            secure: false
        )
    }

    private func source(named fileName: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("ReplacementEngine")
            .appendingPathComponent(fileName)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testNonEditableMessageSelectionCannotAdoptSeparateEditableFieldMutationTarget() {
        let messageSelection = snapshot(
            role: "AXStaticText",
            frame: CGRect(x: 10, y: 20, width: 300, height: 80),
            value: nil,
            selectedRange: nil,
            selectedText: "selected message",
            editabilityEvidence: .none
        )
        let staleEditableField = snapshot(
            frame: CGRect(x: 10, y: 120, width: 300, height: 40),
            value: "draft text",
            selectedRange: CFRange(location: 0, length: 5),
            selectedText: "draft"
        )

        XCTAssertFalse(ProductionTargetCaptureEngine.mutationMatchesSelectionSource(
            selection: messageSelection,
            mutation: staleEditableField,
            identity: .structural
        ))
    }

    func testCorroboratedEditableSelectionMayUseMutationTarget() {
        let selection = snapshot()
        let mutation = snapshot()
        XCTAssertTrue(ProductionTargetCaptureEngine.mutationMatchesSelectionSource(
            selection: selection,
            mutation: mutation,
            identity: .exact
        ))
    }

    func testDifferentEditableSelectionStateCannotBeCorroborated() {
        let selection = snapshot()
        let mutation = snapshot(
            value: "alpha gamma",
            selectedRange: CFRange(location: 6, length: 5),
            selectedText: "gamma"
        )
        XCTAssertFalse(ProductionTargetCaptureEngine.mutationMatchesSelectionSource(
            selection: selection,
            mutation: mutation,
            identity: .structural
        ))
    }

    func testSameFieldSelectionOrValueDriftBlocksFinalPasteGuard() {
        let selectionDrift = TargetRevalidationResult(
            decision: .notReplaced,
            identity: .exact,
            fieldState: .drift,
            reason: "field_state_drift"
        )
        let collapsedCaret = TargetRevalidationResult(
            decision: .notReplaced,
            identity: .exact,
            fieldState: .selectionCollapsed,
            reason: "selection_collapsed_reassert_unverified"
        )
        let stable = TargetRevalidationResult(
            decision: .replacementEligible,
            identity: .exact,
            fieldState: .stable,
            reason: "stable_target"
        )

        XCTAssertFalse(ProductionReplacementEngine.mayDispatch(selectionDrift))
        XCTAssertFalse(ProductionReplacementEngine.mayDispatch(collapsedCaret))
        XCTAssertTrue(ProductionReplacementEngine.mayDispatch(stable))
    }

    func testCaptureKeepsSelectionSourceIndependentFromMutationResolver() throws {
        let accessibility = try source(named: "Accessibility.swift")
        XCTAssertTrue(accessibility.contains(
            "let acquisition = try acquireSelection(from: selectionCandidate, pid: pid)"
        ))
        XCTAssertFalse(accessibility.contains("sourceCandidate = mutation ?? selectionCandidate"))
    }

    func testReplacementRevalidatesFieldStateAfterSnapshotAndImmediatelyBeforePaste() throws {
        let session = try source(named: "Session.swift")
        guard let transaction = session.range(of: "let transaction = try ClipboardTransaction()"),
              let write = session.range(
                of: "try transaction.writeReplacement(replacement)",
                range: transaction.upperBound..<session.endIndex
              ),
              let paste = session.range(
                of: "try KeyEvents.chord",
                range: write.upperBound..<session.endIndex
              ) else {
            XCTFail("replacement sequence not found")
            return
        }

        let postSnapshotGuard = session[transaction.upperBound..<write.lowerBound]
        let prePasteGuard = session[write.upperBound..<paste.lowerBound]
        XCTAssertTrue(postSnapshotGuard.contains(
            "ProductionTargetCaptureEngine.revalidationResult(capture)"
        ))
        XCTAssertTrue(prePasteGuard.contains(
            "ProductionTargetCaptureEngine.revalidationResult(capture)"
        ))
    }
}
