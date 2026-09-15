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
